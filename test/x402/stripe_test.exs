defmodule X402.StripeTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias X402.{Fixtures, Settlement}

  @key "sk_test_" <> String.duplicate("k", 24)

  setup do
    %{
      offer: Fixtures.offer(),
      settlement: %Settlement{
        transaction: Fixtures.tx(),
        network: "eip155:84532",
        payer: Fixtures.payer()
      },
      opts: [req_options: [plug: {Req.Test, __MODULE__}]]
    }
  end

  defp stub(fun), do: Req.Test.stub(__MODULE__, fun)

  defp record(ctx, opts \\ []) do
    X402.Stripe.record(@key, %{settlement: ctx.settlement, offer: ctx.offer}, ctx.opts ++ opts)
  end

  test "creates the PaymentIntent as the Stripe sample does", ctx do
    test = self()

    stub(fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      send(
        test,
        {:stripe, conn.method, conn.host, conn.request_path, Map.new(conn.req_headers), body}
      )

      Req.Test.json(conn, %{
        "id" => "pi_123",
        "object" => "payment_intent",
        "status" => "succeeded"
      })
    end)

    assert record(ctx) == {:ok, "pi_123"}

    assert_received {:stripe, "POST", "api.stripe.com", "/v1/payment_intents", headers, body}
    assert headers["authorization"] == "Bearer " <> @key
    assert headers["stripe-version"] == "2026-05-27.preview"
    assert headers["idempotency-key"] == Fixtures.tx()
    assert headers["content-type"] == "application/x-www-form-urlencoded"

    assert URI.decode_query(body) == %{
             "amount" => "1",
             "currency" => "usd",
             "confirm" => "true",
             "payment_method_data[type]" => "crypto",
             "allowed_payment_method_types[0]" => "crypto",
             "payment_method_options[crypto][mode]" => "transaction_verification",
             "payment_method_options[crypto][transaction_verification_options][network]" =>
               "base",
             "payment_method_options[crypto][transaction_verification_options][transaction_hash]" =>
               Fixtures.tx()
           }
  end

  test "the version can be set per call", ctx do
    test = self()

    stub(fn conn ->
      send(test, {:version, Plug.Conn.get_req_header(conn, "stripe-version")})
      Req.Test.json(conn, %{"id" => "pi_1"})
    end)

    assert {:ok, "pi_1"} = record(ctx, stripe_version: "2026-10-28.preview")
    assert_received {:version, ["2026-10-28.preview"]}
  end

  test "converts USDC atomic units to cents", ctx do
    test = self()

    stub(fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:amount, URI.decode_query(body)["amount"]})
      Req.Test.json(conn, %{"id" => "pi_2"})
    end)

    ctx = %{ctx | offer: Fixtures.offer(%{amount: 1_250_000})}
    assert {:ok, "pi_2"} = record(ctx)
    assert_received {:amount, "125"}
  end

  test "a Stripe error returns status, type and code, and never the key or message", ctx do
    stub(fn conn ->
      conn
      |> Plug.Conn.put_status(401)
      |> Req.Test.json(%{
        "error" => %{
          "type" => "invalid_request_error",
          "code" => "api_key_expired",
          "message" => "Expired API Key provided: " <> @key
        }
      })
    end)

    {result, log} = with_log(fn -> record(ctx) end)

    assert result == {:error, {:stripe_error, 401, "invalid_request_error", "api_key_expired"}}
    refute inspect(result) =~ @key
    refute log =~ @key
  end

  test "a Stripe outage or timeout is an error", ctx do
    stub(&Req.Test.transport_error(&1, :econnrefused))
    assert record(ctx) == {:error, :stripe_unavailable}

    stub(&Req.Test.transport_error(&1, :timeout))
    assert record(ctx) == {:error, :timeout}
  end

  test "a 2xx without a PaymentIntent id is an error", ctx do
    stub(&Req.Test.json(&1, %{"object" => "list"}))
    assert record(ctx) == {:error, :invalid_response}
  end

  describe "refuses before calling Stripe" do
    setup do
      stub(fn _ -> flunk("Stripe should not be called") end)
      :ok
    end

    test "an amount that is not whole cents", ctx do
      assert record(%{ctx | offer: Fixtures.offer(%{amount: 15_000})}) ==
               {:error, :amount_not_whole_cents}

      assert record(%{ctx | offer: Fixtures.offer(%{amount: 5_000})}) ==
               {:error, :amount_not_whole_cents}
    end

    test "an asset that is not USDC", ctx do
      offer = Fixtures.offer(%{asset: "0x" <> String.duplicate("2", 40)})
      assert record(%{ctx | offer: offer}) == {:error, :unsupported_asset}
    end

    test "a key that is not a secret key", ctx do
      assert X402.Stripe.record(
               "pk_test_x",
               %{settlement: ctx.settlement, offer: ctx.offer},
               ctx.opts
             ) ==
               {:error, :invalid_secret_key}
    end

    test "a malformed transaction hash", ctx do
      ctx = %{ctx | settlement: %{ctx.settlement | transaction: "0xnot"}}
      assert record(ctx) == {:error, :invalid_transaction}
    end
  end

  test "plugs into X402.handle/2 as on_settled", ctx do
    test = self()

    stub(fn conn ->
      send(test, :stripe_called)
      Req.Test.json(conn, %{"id" => "pi_3"})
    end)

    on_settled = &X402.Stripe.record(@key, &1, ctx.opts)

    assert {:ok, "pi_3"} =
             on_settled.(%{settlement: ctx.settlement, offer: ctx.offer, payer: Fixtures.payer()})

    assert_received :stripe_called
  end
end
