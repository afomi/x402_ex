defmodule X402.ReplayGuard.MemoryTest do
  use ExUnit.Case, async: true

  alias X402.ReplayGuard.Memory

  test "a key is claimed once" do
    {:ok, guard} = Memory.start_link()
    assert Memory.claim("tx:1", %{}, guard) == :ok
    assert Memory.claim("tx:1", %{}, guard) == {:error, :replayed}
    assert Memory.claim("tx:2", %{}, guard) == :ok
  end

  test "of concurrent claims of one key, exactly one wins" do
    {:ok, guard} = Memory.start_link()

    results =
      1..100
      |> Task.async_stream(fn _ -> Memory.claim("same", %{}, guard) end, max_concurrency: 100)
      |> Enum.map(fn {:ok, r} -> r end)

    assert Enum.count(results, &(&1 == :ok)) == 1
    assert Enum.count(results, &(&1 == {:error, :replayed})) == 99
  end
end
