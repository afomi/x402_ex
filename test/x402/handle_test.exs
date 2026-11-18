defmodule X402.HandleTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias X402.{Codec, Fixtures, Settlement}
  alias X402.ReplayGuard.Memory

  defmodule FunFacilitator do
    @moduledoc false
    @behaviour X402.Facilitator
    @impl true
    def verify(request, config), do: config[:verify].(request)
    @impl true
    def settle(request, config), do: config[:settle].(request)
  end

  defmodule BrokenGuard do
    @moduledoc false
    @behaviour X402.ReplayGuard
    @impl true
    def claim(_key, _meta, _config), do: {:error, :db_down}
  end

  setup do
    offer = Fixtures.offer()
    {:ok, guard} = Memory.start_link()
    test = self()

    stub(fn conn ->
      send(test, {:facilitator, conn.request_path})

      case conn.request_path do
        "/facilitator/verify" -> Req.Test.json(conn, Fixtures.verify_ok())
        "/facilitator/settle" -> Req.Test.json(conn, Fixtures.settle_ok())
      end
    end)

    opts = [
      offer: offer,
      facilitator: {X402.Facilitator.X402Org, req_options: [plug: {Req.Test, __MODULE__}]},
      replay_guard: {Memory, guard}
    ]

    %{offer: offer, guard: guard, opts: opts, header: Fixtures.header(Fixtures.payment(offer))}
  end

  defp stub(fun), do: Req.Test.stub(__MODULE__, fun)

  defp conn(header) do
    conn = Plug.Test.conn(:get, "/data")
    if header, do: Plug.Conn.put_req_header(conn, "payment-signature", header), else: conn
  end

  defp handle(header, opts) do
    {result, _log} = with_log(fn -> X402.handle(conn(header), opts) end)
    result
  end

  defp challenge_error(challenge) do
    {:ok, decoded} = Codec.decode(challenge)
    decoded["error"]
  end

  test "no payment header: the challenge", %{opts: opts, offer: offer} do
    assert {:payment_required, challenge} = handle(nil, opts)
    assert {:ok, decoded} = Codec.decode(challenge)
    assert decoded["accepts"] == [X402.Offer.requirements(offer)]
    assert decoded["error"] == "PAYMENT-SIGNATURE header is required"
    refute_received {:facilitator, _}
  end

  test "a valid paid retry: ok, with a PAYMENT-RESPONSE header", %{
    opts: opts,
    header: header,
    guard: guard
  } do
    assert {:ok, conn, %Settlement{} = s} = handle(header, opts)

    assert s.transaction == Fixtures.tx()
    assert s.payer == Fixtures.payer()
    assert_received {:facilitator, "/facilitator/verify"}
    assert_received {:facilitator, "/facilitator/settle"}

    assert [response] = Plug.Conn.get_resp_header(conn, "payment-response")

    assert Codec.decode(response) ==
             {:ok,
              %{
                "success" => true,
                "transaction" => Fixtures.tx(),
                "network" => "eip155:84532",
                "payer" => Fixtures.payer()
              }}

    claims = Memory.claims(guard)
    assert Enum.count(claims) == 2
    assert Map.has_key?(claims, "tx:eip155:84532:" <> Fixtures.tx())
    assert %{kind: :authorization, payer: _, amount: "10000"} = claims["auth:" <> s.payment_id]
  end

  test "the log names only the outcome, payer and tx hash", %{opts: opts, header: header} do
    log = capture_log(fn -> X402.handle(conn(header), opts) end)

    assert log =~ "outcome=paid"
    assert log =~ Fixtures.payer()
    assert log =~ Fixtures.tx()
    refute log =~ header
    refute log =~ String.duplicate("ab", 65)
  end

  describe "a mismatch is refused before the facilitator is asked" do
    for {name, path, value, reason} <- [
          {"wrong amount", ["accepted", "amount"], "1", :amount_mismatch},
          {"wrong pay_to", ["accepted", "payTo"], "0x" <> String.duplicate("1", 40),
           :pay_to_mismatch},
          {"wrong network", ["accepted", "network"], "eip155:8453", :network_mismatch},
          {"wrong asset", ["accepted", "asset"], "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
           :asset_mismatch},
          {"wrong resource", ["resource", "url"], "https://example.org/other", :resource_mismatch}
        ] do
      test name, %{opts: opts, offer: offer} do
        header =
          offer
          |> Fixtures.payment()
          |> put_in(unquote(path), unquote(value))
          |> Fixtures.header()

        assert {:payment_required, challenge, unquote(reason)} = handle(header, opts)
        assert challenge_error(challenge) == unquote(Atom.to_string(reason))
        refute_received {:facilitator, _}
      end
    end
  end

  describe "a malformed header is refused" do
    test "oversized", %{opts: opts} do
      assert {:payment_required, _, :header_too_large} =
               handle(String.duplicate("A", 8_193), opts)
    end

    test "invalid base64", %{opts: opts} do
      assert {:payment_required, _, :invalid_base64} = handle("%%%", opts)
    end

    test "invalid JSON", %{opts: opts} do
      assert {:payment_required, _, :invalid_json} = handle(Base.encode64("{"), opts)
    end

    test "two payment headers", %{opts: opts, header: header} do
      conn = %{
        conn(header)
        | req_headers: [{"payment-signature", header}, {"payment-signature", header}]
      }

      {result, _} = with_log(fn -> X402.handle(conn, opts) end)
      assert {:payment_required, _, :multiple_payment_headers} = result
    end

    test "a smaller configured cap", %{opts: opts, header: header} do
      assert {:payment_required, _, :header_too_large} =
               handle(header, opts ++ [max_header_bytes: 64])
    end
  end

  test "a replay: the same payment twice is accepted once", %{opts: opts, header: header} do
    assert {:ok, _, _} = handle(header, opts)
    assert {:payment_required, _, :replayed} = handle(header, opts)

    # The second attempt was refused before settling.
    assert_received {:facilitator, "/facilitator/settle"}
    refute_received {:facilitator, "/facilitator/settle"}
  end

  test "a replay with the payer's address in another case is the same payment", %{
    opts: opts,
    offer: offer
  } do
    assert {:ok, _, _} = handle(Fixtures.header(Fixtures.payment(offer)), opts)
    lower = Fixtures.payment(offer, from: String.downcase(Fixtures.payer()))
    assert {:payment_required, _, :replayed} = handle(Fixtures.header(lower), opts)
  end

  test "a new authorization from the same payer is a new payment", %{opts: opts, offer: offer} do
    stub(fn conn ->
      case conn.request_path do
        "/facilitator/verify" ->
          Req.Test.json(conn, Fixtures.verify_ok())

        "/facilitator/settle" ->
          Req.Test.json(conn, Fixtures.settle_ok("0x" <> String.duplicate("e", 64)))
      end
    end)

    assert {:ok, _, _} =
             handle(Fixtures.header(Fixtures.payment(offer, nonce: Fixtures.nonce(2))), opts)
  end

  test "concurrent retries of one payment: exactly one is accepted", %{
    offer: offer,
    guard: guard,
    header: header
  } do
    test = self()

    facilitator =
      {FunFacilitator,
       verify: fn _ -> {:ok, %{payer: Fixtures.payer()}} end,
       settle: fn _ ->
         send(test, :settled)
         {:ok, %Settlement{transaction: Fixtures.tx(), network: "eip155:84532"}}
       end}

    opts = [offer: offer, facilitator: facilitator, replay_guard: {Memory, guard}]

    {results, _} =
      with_log(fn ->
        1..25
        |> Task.async_stream(fn _ -> X402.handle(conn(header), opts) end, max_concurrency: 25)
        |> Enum.map(fn {:ok, r} -> r end)
      end)

    assert Enum.count(results, &match?({:ok, _, _}, &1)) == 1
    assert Enum.count(results, &match?({:payment_required, _, :replayed}, &1)) == 24
    assert_received :settled
    refute_received :settled
  end

  test "a facilitator outage fails closed", %{opts: opts, header: header} do
    stub(&Req.Test.transport_error(&1, :econnrefused))
    assert handle(header, opts) == {:error, :facilitator_unavailable}
  end

  test "a facilitator timeout fails closed", %{opts: opts, header: header} do
    stub(&Req.Test.transport_error(&1, :timeout))
    assert handle(header, opts) == {:error, :facilitator_unavailable}
  end

  test "a non-2xx from verify fails closed", %{opts: opts, header: header} do
    stub(fn conn ->
      send(self(), {:facilitator, conn.request_path})
      conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"error" => "internal"})
    end)

    assert handle(header, opts) == {:error, :facilitator_unavailable}
  end

  test "a failed verification is refused, and nothing is claimed", %{
    opts: opts,
    header: header,
    guard: guard
  } do
    stub(
      &Req.Test.json(&1, %{
        "isValid" => false,
        "invalidReason" => "invalid_exact_evm_payload_signature"
      })
    )

    assert {:payment_required, _, :verification_failed} = handle(header, opts)
    assert Memory.claims(guard) == %{}
  end

  test "verify ok but settle failed: refused, and the payment stays claimed",
       %{opts: opts, header: header, guard: guard} do
    stub(fn conn ->
      case conn.request_path do
        "/facilitator/verify" ->
          Req.Test.json(conn, Fixtures.verify_ok())

        "/facilitator/settle" ->
          Req.Test.json(conn, %{
            "success" => false,
            "errorReason" => "insufficient_funds",
            "transaction" => "",
            "network" => "eip155:84532"
          })
      end
    end)

    assert {:payment_required, _, :settlement_failed} = handle(header, opts)
    assert [_auth_claim] = Map.keys(Memory.claims(guard))
    assert {:payment_required, _, :replayed} = handle(header, opts)
  end

  test "verify ok but settle times out: fails closed", %{opts: opts, header: header} do
    stub(fn conn ->
      case conn.request_path do
        "/facilitator/verify" -> Req.Test.json(conn, Fixtures.verify_ok())
        "/facilitator/settle" -> Req.Test.transport_error(conn, :timeout)
      end
    end)

    assert handle(header, opts) == {:error, :facilitator_unavailable}
  end

  test "settlement_pending is refused and logged with the tx hash", %{opts: opts, header: header} do
    stub(fn conn ->
      case conn.request_path do
        "/facilitator/verify" ->
          Req.Test.json(conn, Fixtures.verify_ok())

        "/facilitator/settle" ->
          Req.Test.json(conn, %{
            "success" => false,
            "errorReason" => "settlement_pending",
            "transaction" => Fixtures.tx(),
            "network" => "eip155:84532"
          })
      end
    end)

    {result, log} = with_log(fn -> X402.handle(conn(header), opts) end)
    assert {:payment_required, _, :settlement_pending} = result
    assert log =~ "outcome=settlement_pending"
    assert log =~ Fixtures.tx()
  end

  test "a transaction hash reported for a second authorization is refused", %{
    opts: opts,
    offer: offer
  } do
    assert {:ok, _, _} = handle(Fixtures.header(Fixtures.payment(offer)), opts)

    other = Fixtures.header(Fixtures.payment(offer, nonce: Fixtures.nonce(2)))
    assert {:payment_required, _, :replayed} = handle(other, opts)
  end

  test "a replay guard that cannot claim fails closed", %{opts: opts, header: header} do
    opts = Keyword.put(opts, :replay_guard, {BrokenGuard, []})
    assert handle(header, opts) == {:error, :replay_guard_unavailable}
    refute_received {:facilitator, "/facilitator/settle"}
  end

  test "on_settled is called with the settlement and offer", %{
    opts: opts,
    header: header,
    offer: offer
  } do
    test = self()
    opts = opts ++ [on_settled: &send(test, {:on_settled, &1})]

    assert {:ok, _, s} = handle(header, opts)
    assert_received {:on_settled, %{settlement: ^s, offer: ^offer, payer: _}}
  end

  test "an on_settled failure or raise does not take back a paid response", %{
    opts: opts,
    offer: offer
  } do
    assert {:ok, _, _} =
             handle(
               Fixtures.header(Fixtures.payment(offer)),
               opts ++ [on_settled: fn _ -> {:error, :stripe_down} end]
             )

    stub(fn conn ->
      case conn.request_path do
        "/facilitator/verify" ->
          Req.Test.json(conn, Fixtures.verify_ok())

        "/facilitator/settle" ->
          Req.Test.json(conn, Fixtures.settle_ok("0x" <> String.duplicate("f", 64)))
      end
    end)

    {result, log} =
      with_log(fn ->
        X402.handle(
          conn(Fixtures.header(Fixtures.payment(offer, nonce: Fixtures.nonce(3)))),
          opts ++ [on_settled: fn _ -> raise "boom" end]
        )
      end)

    assert {:ok, _, _} = result
    assert log =~ "outcome=on_settled_raised"
  end
end
