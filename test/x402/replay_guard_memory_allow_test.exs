defmodule X402.ReplayGuard.MemoryAllowTest do
  # Not async: it changes application env that every other test reads.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias X402.Fixtures
  alias X402.ReplayGuard.Memory

  setup do
    Application.put_env(:x402_ex, :allow_memory_guard, false)
    on_exit(fn -> Application.put_env(:x402_ex, :allow_memory_guard, true) end)

    {:ok, guard} = Memory.start_link()
    %{guard: guard}
  end

  test "every callback refuses unless the app's test config allows the guard", %{guard: guard} do
    {results, log} =
      with_log(fn ->
        {
          Memory.claim("auth:x", %{kind: :authorization}, guard),
          Memory.record_payment_intent("tx:x", "pi_1", guard),
          Memory.unrecorded(10, guard)
        }
      end)

    assert results ==
             {{:error, :memory_guard_not_allowed}, {:error, :memory_guard_not_allowed},
              {:error, :memory_guard_not_allowed}}

    assert log =~ "allow_memory_guard"
    assert Memory.claims(guard) == %{}
  end

  test "X402.handle/2 then fails closed before any settle", %{guard: guard} do
    offer = Fixtures.offer()
    test = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(test, {:facilitator, conn.request_path})
      Req.Test.json(conn, Fixtures.verify_ok())
    end)

    opts = [
      offer: offer,
      scope: [app: "test-app", pay_to: Fixtures.pay_to()],
      facilitator: {X402.Facilitator.X402Org, req_options: [plug: {Req.Test, __MODULE__}]},
      replay_guard: {Memory, guard}
    ]

    conn =
      Plug.Test.conn(:get, "/data")
      |> Plug.Conn.put_req_header("payment-signature", Fixtures.header(Fixtures.payment(offer)))

    {result, log} = with_log(fn -> X402.handle(conn, opts) end)

    assert result == {:error, :replay_guard_unavailable}
    assert log =~ "outcome=replay_guard_unavailable"
    assert_received {:facilitator, "/facilitator/verify"}
    refute_received {:facilitator, "/facilitator/settle"}
  end
end
