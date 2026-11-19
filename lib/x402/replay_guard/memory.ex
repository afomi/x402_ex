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

  So that a copied test config cannot ship it, every callback answers
  `{:error, :memory_guard_not_allowed}` unless the application sets
  `config :x402_ex, allow_memory_guard: true`, which belongs in
  `config/test.exs` only (the same pattern as `allow_req_options`, see
  `X402.HTTPClient`). `X402.handle/2` then refuses the payment before any
  settle call (`{:error, :replay_guard_unavailable}`), so it fails closed.
  """

  @behaviour X402.ReplayGuard

  use Agent

  require Logger

  def start_link(opts \\ []) do
    Agent.start_link(fn -> %{} end, Keyword.take(opts, [:name]))
  end

  @impl true
  def claim(key, meta, agent) when is_binary(key) do
    with :ok <- allowed() do
      Agent.get_and_update(agent, fn claims ->
        if Map.has_key?(claims, key) do
          {{:error, :replayed}, claims}
        else
          row = meta |> Map.put(:key, key) |> Map.put(:payment_intent_id, nil)
          {:ok, Map.put(claims, key, row)}
        end
      end)
    end
  end

  @impl true
  def record_payment_intent(tx_key, payment_intent_id, agent) do
    with :ok <- allowed() do
      Agent.get_and_update(agent, fn claims ->
        case claims do
          %{^tx_key => row} ->
            {:ok, Map.put(claims, tx_key, %{row | payment_intent_id: payment_intent_id})}

          _ ->
            {{:error, :not_found}, claims}
        end
      end)
    end
  end

  @impl true
  def unrecorded(limit, agent) do
    with :ok <- allowed() do
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
  end

  defp allowed do
    if Application.get_env(:x402_ex, :allow_memory_guard, false) do
      :ok
    else
      Logger.error(
        "x402 X402.ReplayGuard.Memory used but not allowed; set allow_memory_guard in test config only"
      )

      {:error, :memory_guard_not_allowed}
    end
  end

  @doc "Every claim so far, `%{key => row}` (for assertions)."
  def claims(agent), do: Agent.get(agent, & &1)
end
