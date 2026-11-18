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
    @impl true
    def record_payment_intent(_key, _id, _config), do: {:error, :db_down}
    @impl true
    def unrecorded(_limit, _config), do: {:error, :db_down}
  end

  # Memory, except that "tx:" claims fail in the way `mode` says.
  defmodule TxFailGuard do
    @moduledoc false
    @behaviour X402.ReplayGuard
    @impl true
    def claim("tx:" <> _, _meta, {_agent, :error}), do: {:error, :db_down}
    def claim("tx:" <> _, _meta, {_agent, :raise}), do: raise("db connection lost")
    def claim("tx:" <> _, _meta, {_agent, :exit}), do: exit(:db_pool_timeout)
    def claim(key, meta, {agent, _}), do: Memory.claim(key, meta, agent)
    @impl true
    def record_payment_intent(key, id, {agent, _}),
      do: Memory.record_payment_intent(key, id, agent)

    @impl true
    def unrecorded(limit, {agent, _}), do: Memory.unrecorded(limit, agent)
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
      scope: [app: "test-app", pay_to: Fixtures.pay_to()],
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

    opts = [
      offer: offer,
      scope: [app: "test-app", pay_to: Fixtures.pay_to()],
      facilitator: facilitator,
      replay_guard: {Memory, guard}
    ]

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
    assert log =~ "outcome=on_settled_crashed"
  end

  ## M1: after settlement, nothing may leave a payment without a record.

  defp fun_opts(ctx, settle, extra \\ []) do
    facilitator =
      {FunFacilitator, verify: fn _ -> {:ok, %{payer: Fixtures.payer()}} end, settle: settle}

    Keyword.merge(ctx.opts, [facilitator: facilitator] ++ extra)
  end

  defp settled_ok(_request),
    do: {:ok, %Settlement{transaction: Fixtures.tx(), network: "eip155:84532"}}

  for mode <- [:error, :raise, :exit] do
    test "a tx claim that fails (#{mode}) after settle still serves, calls on_settled and logs",
         %{opts: opts, guard: guard, header: header} do
      test = self()

      opts =
        opts
        |> Keyword.put(:replay_guard, {TxFailGuard, {guard, unquote(mode)}})
        |> Keyword.put(:on_settled, &send(test, {:on_settled, &1.settlement.transaction}))

      {result, log} = with_log(fn -> X402.handle(conn(header), opts) end)

      assert {:ok, _conn, %Settlement{}} = result
      assert log =~ "outcome=tx_claim_failed"
      assert log =~ Fixtures.tx()
      refute log =~ "transaction_already_claimed"
      assert_received {:on_settled, tx} when tx == unquote(Fixtures.tx())
    end
  end

  for {kind, fun} <- [
        exit: quote(do: fn _ -> exit(:finch_pool_timeout) end),
        throw: quote(do: fn _ -> throw(:nope) end),
        raise: quote(do: fn _ -> raise "boom" end)
      ] do
    test "an on_settled that #{kind}s still serves, and leaves the row for the reconciler",
         %{opts: opts, guard: guard, header: header} do
      {result, log} =
        with_log(fn ->
          X402.handle(conn(header), Keyword.put(opts, :on_settled, unquote(fun)))
        end)

      assert {:ok, _, _} = result
      assert log =~ "outcome=on_settled_crashed"
      assert {:ok, [%{tx_hash: tx}]} = Memory.unrecorded(10, guard)
      assert tx == Fixtures.tx()
    end
  end

  for {kind, fun} <- [
        raise: quote(do: fn _ -> raise "finch exploded" end),
        exit: quote(do: fn _ -> exit(:killed) end),
        throw: quote(do: fn _ -> throw(:oops) end)
      ] do
    test "a facilitator adapter that #{kind}s in settle fails closed, with the reconcile line",
         ctx do
      {result, log} =
        with_log(fn -> X402.handle(conn(ctx.header), fun_opts(ctx, unquote(fun))) end)

      assert result == {:error, :facilitator_unavailable}
      assert log =~ "outcome=settle_unavailable"
      assert log =~ "reconcile=check_payer_on_chain"
      assert [auth_key] = Map.keys(Memory.claims(ctx.guard))
      assert String.starts_with?(auth_key, "auth:")
    end
  end

  test "a facilitator adapter that raises in verify fails closed, with nothing claimed", ctx do
    facilitator =
      {FunFacilitator, verify: fn _ -> raise "boom" end, settle: &settled_ok/1}

    {result, _} =
      with_log(fn ->
        X402.handle(conn(ctx.header), Keyword.put(ctx.opts, :facilitator, facilitator))
      end)

    assert result == {:error, :facilitator_unavailable}
    assert Memory.claims(ctx.guard) == %{}
  end

  test "a request process killed mid-settle: the settlement is still recorded", ctx do
    test = self()

    settle = fn request ->
      send(test, {:settling, self()})

      receive do
        :go -> settled_ok(request)
      end
    end

    opts =
      fun_opts(ctx, settle, on_settled: fn _ -> send(test, :on_settled) && {:ok, "pi_late"} end)

    request_pid =
      spawn(fn ->
        Logger.disable(self())
        X402.handle(conn(ctx.header), opts)
      end)

    assert_receive {:settling, settle_pid}
    Process.exit(request_pid, :kill)
    refute Process.alive?(request_pid)

    send(settle_pid, :go)
    assert_receive :on_settled

    tx_key = "tx:eip155:84532:" <> Fixtures.tx()

    wait_until(fn ->
      match?(%{payment_intent_id: "pi_late"}, Memory.claims(ctx.guard)[tx_key])
    end)
  end

  test "past settle_await_ms the request fails closed, and the work still completes", ctx do
    test = self()

    settle = fn request ->
      receive do
        :go -> settled_ok(request)
      end
    end

    opts =
      fun_opts(ctx, settle,
        settle_await_ms: 50,
        on_settled: fn _ -> send(test, :recorded) && {:ok, "pi_slow"} end
      )

    {result, log} = with_log(fn -> X402.handle(conn(ctx.header), opts) end)
    assert result == {:error, :facilitator_unavailable}
    assert log =~ "outcome=settle_still_running"

    [settle_pid] =
      Task.Supervisor.children(X402.TaskSupervisor)
      |> Enum.filter(
        &(Process.info(&1, :dictionary) |> elem(1) |> Keyword.get(:"$callers") == [test])
      )

    send(settle_pid, :go)
    assert_receive :recorded
  end

  test "the PaymentIntent id from on_settled is stored on the tx row", ctx do
    opts = Keyword.put(ctx.opts, :on_settled, fn _ -> {:ok, "pi_123"} end)
    assert {:ok, _, _} = handle(ctx.header, opts)

    assert %{payment_intent_id: "pi_123", auth_key: "auth:" <> _, app: "test-app"} =
             Memory.claims(ctx.guard)["tx:eip155:84532:" <> Fixtures.tx()]

    assert Memory.unrecorded(10, ctx.guard) == {:ok, []}
  end

  test "the reconciler records a settlement whose Stripe call failed, once", ctx do
    opts = Keyword.put(ctx.opts, :on_settled, fn _ -> {:error, :stripe_unavailable} end)
    assert {:ok, _, _} = handle(ctx.header, opts)
    assert {:ok, [_]} = Memory.unrecorded(10, ctx.guard)

    test = self()

    stub(fn conn ->
      send(test, {:stripe, Plug.Conn.get_req_header(conn, "idempotency-key")})
      Req.Test.json(conn, %{"id" => "pi_reconciled"})
    end)

    stripe_opts = [req_options: [plug: {Req.Test, __MODULE__}]]

    {result, _} =
      with_log(fn ->
        X402.Reconciler.record_unrecorded({Memory, ctx.guard}, "sk_test_x",
          stripe_opts: stripe_opts
        )
      end)

    assert result == {:ok, %{recorded: [{Fixtures.tx(), "pi_reconciled"}], failed: []}}
    assert_received {:stripe, [tx]} when tx == unquote(Fixtures.tx())
    assert Memory.unrecorded(10, ctx.guard) == {:ok, []}

    assert X402.Reconciler.record_unrecorded({Memory, ctx.guard}, "sk_test_x",
             stripe_opts: stripe_opts
           ) ==
             {:ok, %{recorded: [], failed: []}}
  end

  test "the reconciler reports a Stripe failure and leaves the row", ctx do
    opts = Keyword.put(ctx.opts, :on_settled, fn _ -> {:error, :stripe_unavailable} end)
    assert {:ok, _, _} = handle(ctx.header, opts)

    stub(&Req.Test.transport_error(&1, :econnrefused))

    {result, _} =
      with_log(fn ->
        X402.Reconciler.record_unrecorded({Memory, ctx.guard}, "sk_test_x",
          stripe_opts: [req_options: [plug: {Req.Test, __MODULE__}]]
        )
      end)

    assert result == {:ok, %{recorded: [], failed: [{Fixtures.tx(), :stripe_unavailable}]}}
    assert {:ok, [_]} = Memory.unrecorded(10, ctx.guard)
  end

  ## L1: the facilitator's report must agree with what was signed.

  test "a settle reporting another payer fails closed", ctx do
    stub(fn conn ->
      case conn.request_path do
        "/facilitator/verify" ->
          Req.Test.json(conn, Fixtures.verify_ok())

        "/facilitator/settle" ->
          Req.Test.json(
            conn,
            Map.put(Fixtures.settle_ok(), "payer", "0x" <> String.duplicate("9", 40))
          )
      end
    end)

    {result, log} = with_log(fn -> X402.handle(conn(ctx.header), ctx.opts) end)
    assert result == {:error, :facilitator_unavailable}
    assert log =~ "reason=payer_mismatch"
  end

  test "a settle reporting another amount fails closed", ctx do
    stub(fn conn ->
      case conn.request_path do
        "/facilitator/verify" -> Req.Test.json(conn, Fixtures.verify_ok())
        "/facilitator/settle" -> Req.Test.json(conn, Map.put(Fixtures.settle_ok(), "amount", "1"))
      end
    end)

    assert handle(ctx.header, ctx.opts) == {:error, :facilitator_unavailable}
  end

  test "a verify reporting another payer fails closed, with nothing claimed", ctx do
    stub(&Req.Test.json(&1, %{"isValid" => true, "payer" => "0x" <> String.duplicate("9", 40)}))
    assert handle(ctx.header, ctx.opts) == {:error, :facilitator_unavailable}
    assert Memory.claims(ctx.guard) == %{}
  end

  test "the PAYMENT-RESPONSE payer is the signed payer, in the facilitator's case or not", ctx do
    stub(fn conn ->
      case conn.request_path do
        "/facilitator/verify" ->
          Req.Test.json(conn, Fixtures.verify_ok())

        "/facilitator/settle" ->
          Req.Test.json(
            conn,
            Map.put(Fixtures.settle_ok(), "payer", String.downcase(Fixtures.payer()))
          )
      end
    end)

    assert {:ok, _, %Settlement{payer: payer}} = handle(ctx.header, ctx.opts)
    assert payer == Fixtures.payer()
  end

  ## M2 and L4: options.

  test "an offer to an address other than the app's deposit address raises", ctx do
    opts =
      Keyword.put(ctx.opts, :scope, app: "test-app", pay_to: "0x" <> String.duplicate("3", 40))

    assert_raise ArgumentError, ~r/not the deposit address of app "test-app"/, fn ->
      X402.handle(conn(ctx.header), opts)
    end
  end

  test "the scope's address compares case-insensitively", ctx do
    opts =
      Keyword.put(ctx.opts, :scope, app: "test-app", pay_to: String.downcase(Fixtures.pay_to()))

    assert {:payment_required, _} = handle(nil, opts)
  end

  for key <- [:offer, :scope, :facilitator, :replay_guard] do
    test "a missing #{key} raises naming it, and prints no other option", ctx do
      secret = "cdp-secret-#{System.unique_integer([:positive])}"
      opts = ctx.opts |> Keyword.delete(unquote(key)) |> Keyword.put(:extra_secret, secret)

      error = assert_raise ArgumentError, fn -> X402.handle(conn(nil), opts) end
      assert Exception.message(error) == "X402.handle/2: missing #{inspect(unquote(key))}"
      refute Exception.message(error) =~ secret
    end
  end

  test "an invalid facilitator option raises without printing it", ctx do
    opts = Keyword.put(ctx.opts, :facilitator, key_secret: "s3cret")
    error = assert_raise ArgumentError, fn -> X402.handle(conn(nil), opts) end
    refute Exception.message(error) =~ "s3cret"
  end

  defp wait_until(fun, tries \\ 50) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition never held")
      true -> Process.sleep(10) && wait_until(fun, tries - 1)
    end
  end
end
