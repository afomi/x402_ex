defmodule X402.HTTPClientTest do
  # Not async: it changes application env that every other test reads.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias X402.{Facilitator, Fixtures, Payment}

  setup do
    Application.put_env(:x402_ex, :allow_req_options, false)
    on_exit(fn -> Application.put_env(:x402_ex, :allow_req_options, true) end)

    offer = Fixtures.offer()
    {:ok, payment} = Payment.decode(Fixtures.header(Fixtures.payment(offer)))
    %{request: Facilitator.request(payment, offer), offer: offer}
  end

  test "req_options are refused unless the app's test config allows them", %{request: request} do
    Req.Test.stub(__MODULE__, fn _ -> flunk("no request should be sent") end)
    config = [req_options: [plug: {Req.Test, __MODULE__}]]

    {result, log} = with_log(fn -> X402.Facilitator.X402Org.verify(request, config) end)
    assert result == {:error, :req_options_not_allowed}
    assert log =~ "allow_req_options"
  end

  test "and so are they for Stripe", %{offer: offer} do
    settlement = %X402.Settlement{transaction: Fixtures.tx(), network: "eip155:84532"}

    {result, _} =
      with_log(fn ->
        X402.Stripe.record("sk_test_x", %{settlement: settlement, offer: offer},
          req_options: [plug: {Req.Test, __MODULE__}]
        )
      end)

    assert result == {:error, :req_options_not_allowed}
  end
end
