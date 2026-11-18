defmodule X402.ReplayGuard.Memory do
  @moduledoc """
  An in-memory replay guard, FOR TESTS ONLY.

  It forgets every claim when its process stops and knows nothing of other
  nodes, so in production it would let a payment be replayed after a restart
  or on another instance. Use a database table with a unique index instead
  (README, "Replay guard").

      {:ok, guard} = X402.ReplayGuard.Memory.start_link()
      replay_guard: {X402.ReplayGuard.Memory, guard}

  `config` is the Agent's pid or name.
  """

  @behaviour X402.ReplayGuard

  use Agent

  def start_link(opts \\ []) do
    Agent.start_link(fn -> %{} end, Keyword.take(opts, [:name]))
  end

  @impl true
  def claim(key, meta, agent) when is_binary(key) do
    Agent.get_and_update(agent, fn claims ->
      if Map.has_key?(claims, key) do
        {{:error, :replayed}, claims}
      else
        {:ok, Map.put(claims, key, meta)}
      end
    end)
  end

  @doc "Every claim so far, `%{key => meta}` (for assertions)."
  def claims(agent), do: Agent.get(agent, & &1)
end
