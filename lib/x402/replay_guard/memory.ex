defmodule X402.ReplayGuard.Memory do
  @moduledoc """
  An in-memory replay guard, FOR TESTS ONLY.

  It forgets every claim when its process stops and knows nothing of other
  nodes, so in production it would let a payment be replayed after a restart
  or on another instance, and would lose the record of settled payments.
  Use a database table with a unique index instead (README, "Replay guard").

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
        row = meta |> Map.put(:key, key) |> Map.put(:payment_intent_id, nil)
        {:ok, Map.put(claims, key, row)}
      end
    end)
  end

  @impl true
  def record_payment_intent(tx_key, payment_intent_id, agent) do
    Agent.get_and_update(agent, fn claims ->
      case claims do
        %{^tx_key => row} ->
          {:ok, Map.put(claims, tx_key, %{row | payment_intent_id: payment_intent_id})}

        _ ->
          {{:error, :not_found}, claims}
      end
    end)
  end

  @impl true
  def unrecorded(limit, agent) do
    rows =
      agent
      |> claims()
      |> Map.values()
      |> Enum.filter(&(&1.kind == :transaction and is_nil(&1.payment_intent_id)))
      |> Enum.sort_by(& &1.key)
      |> Enum.take(limit)
      |> Enum.map(&Map.take(&1, [:key, :tx_hash, :network, :asset, :amount]))

    {:ok, rows}
  end

  @doc "Every claim so far, `%{key => row}` (for assertions)."
  def claims(agent), do: Agent.get(agent, & &1)
end
