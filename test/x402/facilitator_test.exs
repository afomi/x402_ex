defmodule X402.FacilitatorTest do
  use ExUnit.Case, async: true

  alias X402.{Facilitator, Fixtures, Payment, Settlement}
  alias X402.Facilitator.{CDP, X402Org}

  setup do
    offer = Fixtures.offer()
    {:ok, payment} = Payment.decode(Fixtures.header(Fixtures.payment(offer)))
    {:ok, payment} = Payment.match(payment, offer)

    %{
      request: Facilitator.request(payment, offer),
      config: [req_options: [plug: {Req.Test, __MODULE__}]]
    }
  end

  defp stub(fun), do: Req.Test.stub(__MODULE__, fun)

  defp json(conn, status, body) do
    conn |> Plug.Conn.put_status(status) |> Req.Test.json(body)
  end

  test "posts the spec's request body to <url>/verify", %{request: request, config: config} do
    test = self()

    stub(fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:request, conn.method, conn.request_path, Jason.decode!(body)})
      json(conn, 200, Fixtures.verify_ok())
    end)

    assert {:ok, %{payer: payer}} = X402Org.verify(request, config)
    assert payer == Fixtures.payer()

    assert_received {:request, "POST", "/facilitator/verify", body}
    assert body["x402Version"] == 2
    assert body["paymentRequirements"]["payTo"] == Fixtures.pay_to()
    assert body["paymentPayload"]["payload"]["signature"] =~ "0xab"
  end

  test "verify: isValid false is a refusal", %{request: request, config: config} do
    stub(&json(&1, 200, %{"isValid" => false, "invalidReason" => "insufficient_funds"}))
    assert X402Org.verify(request, config) == {:error, {:rejected, "insufficient_funds"}}
  end

  test "verify: a non-2xx with a verdict is a refusal", %{request: request, config: config} do
    stub(&json(&1, 400, %{"isValid" => false, "invalidReason" => "invalid_payload"}))
    assert X402Org.verify(request, config) == {:error, {:rejected, "invalid_payload"}}
  end

  test "verify: a non-2xx without one is an HTTP error", %{request: request, config: config} do
    stub(&json(&1, 500, %{"error" => "boom"}))
    assert X402Org.verify(request, config) == {:error, {:http_status, 500}}

    stub(&Plug.Conn.send_resp(&1, 502, "<html>bad gateway</html>"))
    assert X402Org.verify(request, config) == {:error, {:http_status, 502}}
  end

  test "verify: a 2xx we cannot read is an error", %{request: request, config: config} do
    stub(&Plug.Conn.send_resp(&1, 200, "ok"))
    assert X402Org.verify(request, config) == {:error, :invalid_response}

    stub(&json(&1, 200, %{"isValid" => "true"}))
    assert X402Org.verify(request, config) == {:error, :invalid_response}
  end

  test "verify: a reason that is not a reason code is reported as unknown",
       %{request: request, config: config} do
    stub(&json(&1, 200, %{"isValid" => false, "invalidReason" => "<script>"}))
    assert X402Org.verify(request, config) == {:error, {:rejected, "unknown"}}
  end

  test "a timeout is an error", %{request: request, config: config} do
    stub(&Req.Test.transport_error(&1, :timeout))
    assert X402Org.verify(request, config) == {:error, :timeout}
    assert X402Org.settle(request, config) == {:error, :timeout}
  end

  test "a refused connection is an error", %{request: request, config: config} do
    stub(&Req.Test.transport_error(&1, :econnrefused))
    assert X402Org.verify(request, config) == {:error, :unavailable}
  end

  test "a redirect is not followed", %{request: request, config: config} do
    stub(fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", "https://elsewhere.example/verify")
      |> Plug.Conn.send_resp(307, "")
    end)

    assert X402Org.verify(request, config) == {:error, {:http_status, 307}}
  end

  test "settle: success", %{request: request, config: config} do
    stub(fn conn ->
      assert conn.request_path == "/facilitator/settle"
      json(conn, 200, Fixtures.settle_ok())
    end)

    assert {:ok, %Settlement{transaction: tx, network: "eip155:84532", payer: payer}} =
             X402Org.settle(request, config)

    assert tx == Fixtures.tx()
    assert payer == Fixtures.payer()
  end

  test "settle: success false is a refusal", %{request: request, config: config} do
    stub(
      &json(&1, 200, %{
        "success" => false,
        "errorReason" => "invalid_transaction_state",
        "transaction" => "",
        "network" => "eip155:84532"
      })
    )

    assert X402Org.settle(request, config) == {:error, {:rejected, "invalid_transaction_state"}}
  end

  test "settle: settlement_pending is not a success", %{request: request, config: config} do
    stub(
      &json(&1, 200, %{
        "success" => false,
        "errorReason" => "settlement_pending",
        "transaction" => Fixtures.tx(),
        "network" => "eip155:84532"
      })
    )

    assert X402Org.settle(request, config) == {:error, {:pending, Fixtures.tx()}}
  end

  test "settle: settlement_pending with a malformed hash is an error",
       %{request: request, config: config} do
    stub(
      &json(&1, 200, %{
        "success" => false,
        "errorReason" => "settlement_pending",
        "transaction" => "0xabc\nforged log line",
        "network" => "eip155:84532"
      })
    )

    assert X402Org.settle(request, config) == {:error, :invalid_response}
  end

  test "settle: success with a malformed transaction or another network is an error",
       %{request: request, config: config} do
    for body <- [
          Fixtures.settle_ok(""),
          Fixtures.settle_ok("0x1234"),
          Map.put(Fixtures.settle_ok(), "network", "eip155:8453"),
          Map.delete(Fixtures.settle_ok(), "network"),
          Map.put(Fixtures.settle_ok(), "payer", "<script>"),
          Map.put(Fixtures.settle_ok(), "amount", "1.5")
        ] do
      stub(&json(&1, 200, body))
      assert X402Org.settle(request, config) == {:error, :invalid_response}
    end
  end

  test "settle: a non-2xx is an error", %{request: request, config: config} do
    stub(&json(&1, 503, %{"error" => "maintenance"}))
    assert X402Org.settle(request, config) == {:error, {:http_status, 503}}
  end

  test "a response body over 64 KB is refused", %{request: request, config: config} do
    stub(&json(&1, 200, %{"isValid" => true, "padding" => String.duplicate("x", 70_000)}))
    assert X402Org.verify(request, config) == {:error, :invalid_response}
  end

  test "a gzip body is not decompressed", %{request: request, config: config} do
    stub(fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-encoding", "gzip")
      |> Plug.Conn.send_resp(200, :zlib.gzip(Jason.encode!(Fixtures.verify_ok())))
    end)

    assert X402Org.verify(request, config) == {:error, :invalid_response}
  end

  test "a body that trickles past the deadline is a timeout", %{request: request, config: config} do
    stub(fn conn ->
      conn = Plug.Conn.send_chunked(conn, 200)
      {:ok, conn} = Plug.Conn.chunk(conn, "{")
      Process.sleep(60)
      {:ok, conn} = Plug.Conn.chunk(conn, "}")
      conn
    end)

    assert X402Org.verify(request, config ++ [verify_timeout: 20]) == {:error, :timeout}
  end

  test "the default URL is x402.org" do
    assert X402Org.default_url() == "https://x402.org/facilitator"
  end

  describe "CDP" do
    test "with only a key id and secret, sends nothing and is not implemented",
         %{request: request, config: config} do
      stub(fn _ -> flunk("no request should be sent") end)
      config = config ++ [key_id: "id", key_secret: fn -> "secret" end]

      assert CDP.verify(request, config) == {:error, :not_implemented}
      assert CDP.settle(request, config) == {:error, :not_implemented}
    end

    test "a secret given as a bare string is refused", %{request: request, config: config} do
      stub(fn _ -> flunk("no request should be sent") end)
      config = config ++ [key_id: "id", key_secret: "secret"]
      assert CDP.verify(request, config) == {:error, :invalid_config}
    end

    test "a :url in config cannot send the JWT elsewhere", %{request: request, config: config} do
      test = self()

      stub(fn conn ->
        send(test, {:host, conn.host})
        json(conn, 200, Fixtures.verify_ok())
      end)

      auth = fn _, _, _ -> {:ok, [{"authorization", "Bearer jwt"}]} end
      config = config ++ [url: "https://evil.example/x402", auth_headers: auth]

      assert {:ok, _} = CDP.verify(request, config)
      assert_received {:host, "api.cdp.coinbase.com"}
    end

    test "with an auth_headers function, calls CDP's paths with its headers",
         %{request: request, config: config} do
      test = self()

      stub(fn conn ->
        send(
          test,
          {:cdp, conn.host, conn.request_path, Plug.Conn.get_req_header(conn, "authorization")}
        )

        json(conn, 200, Fixtures.verify_ok())
      end)

      auth = fn "POST", "api.cdp.coinbase.com", path ->
        {:ok, [{"authorization", "Bearer jwt-for-" <> path}]}
      end

      assert {:ok, _} = CDP.verify(request, config ++ [auth_headers: auth])

      assert_received {:cdp, "api.cdp.coinbase.com", "/platform/v2/x402/verify",
                       ["Bearer jwt-for-/platform/v2/x402/verify"]}
    end

    test "an auth_headers failure is an error", %{request: request, config: config} do
      stub(fn _ -> flunk("no request should be sent") end)

      assert CDP.settle(request, config ++ [auth_headers: fn _, _, _ -> :error end]) ==
               {:error, :unavailable}
    end
  end
end
