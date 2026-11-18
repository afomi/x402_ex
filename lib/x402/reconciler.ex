defmodule X402.Reconciler do
  @moduledoc """
  Finds settled payments with no Stripe PaymentIntent, and records them.

  `X402.handle/2` stores a `"tx:"` row right after settlement, then records
  the payment in Stripe through `:on_settled`. If that second step fails (a
  Stripe outage, a timeout, a crash), the row is left without a
  `payment_intent_id`. Run `record_unrecorded/3` on a schedule (an Oban
  cron, say, every 15 minutes) to finish those:

      X402.Reconciler.record_unrecorded({MyApp.X402Claims, []}, fn -> stripe_key() end)

  It is idempotent: Stripe's idempotency key is the transaction hash, so a
  payment recorded by the request but not yet marked returns the same
  PaymentIntent. Stripe keeps idempotency keys for 24 hours, so run it well
  within the day.

  ## What it does not cover

  An `"auth:"` row with no matching `"tx:"` row is an authorization that was
  claimed and sent to `/settle`, but whose settlement we never saw succeed:
  a settle that failed, timed out or came back `settlement_pending`. Most
  moved no money. To be sure, check the chain: on EVM, the token contract's
  `authorizationState(from, nonce)` is true, or an `AuthorizationUsed(from,
  nonce)` event was emitted, if the authorization was used. This library has
  no chain client, so that check is the app's.
  """

  require Logger

  @doc """
  Records up to `:limit` (default 100) unrecorded settlements in Stripe.

  Returns `{:ok, %{recorded: [{tx_hash, payment_intent_id}], failed: [{tx_hash, reason}]}}`,
  or `{:error, reason}` if the guard could not list them. `:stripe_opts`
  are passed to `X402.Stripe.record_payment/3`.
  """
  @spec record_unrecorded({module(), term()}, X402.Stripe.secret(), keyword()) ::
          {:ok, %{recorded: list(), failed: list()}} | {:error, term()}
  def record_unrecorded({guard, config}, secret, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    stripe_opts = Keyword.get(opts, :stripe_opts, [])

    case X402.Safe.call(fn -> guard.unrecorded(limit, config) end) do
      {:ok, {:ok, rows}} when is_list(rows) ->
        {:ok,
         Enum.reduce(
           rows,
           %{recorded: [], failed: []},
           &record(&1, &2, guard, config, secret, stripe_opts)
         )}

      _ ->
        Logger.error("x402 outcome=reconcile_list_failed")
        {:error, :replay_guard_unavailable}
    end
  end

  defp record(row, acc, guard, config, secret, stripe_opts) do
    tx = row[:tx_hash]

    with {:ok, {:ok, id}} <-
           X402.Safe.call(fn -> X402.Stripe.record_payment(secret, row, stripe_opts) end),
         {:ok, :ok} <- X402.Safe.call(fn -> guard.record_payment_intent(row.key, id, config) end) do
      Logger.info("x402 outcome=reconciled payment_intent=#{id} tx_hash=#{tx}")
      %{acc | recorded: [{tx, id} | acc.recorded]}
    else
      other ->
        reason = failure(other)
        Logger.error("x402 outcome=reconcile_failed tx_hash=#{tx} reason=#{inspect(reason)}")
        %{acc | failed: [{tx, reason} | acc.failed]}
    end
  end

  defp failure({:ok, {:error, reason}}), do: reason
  defp failure({:ok, _other}), do: :unexpected_return
  defp failure({:caught, kind}), do: {:caught, kind}
end
