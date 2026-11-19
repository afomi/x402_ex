defmodule X402.ReplayGuard do
  @moduledoc """
  Claims a payment once, so it buys exactly one response, and keeps the
  record that links the money to Stripe.

  `claim(key, meta, config)` must be atomic: of any number of concurrent
  claims of one key, exactly one returns `:ok` and the rest
  `{:error, :replayed}`, across every node that serves the app. A database
  unique index gives this; an in-process map does not across nodes.

  `X402.handle/2` claims two keys per payment (see its moduledoc):

    * `"auth:" <> payment_id` before settling, which names the signed
      authorization (for EVM: network, asset, payer and EIP-3009 nonce);
    * `"tx:" <> network <> ":" <> tx_hash` right after settling, before
      anything else runs. This row is the durable record of the settlement.

  `meta` is a map with `:kind` (`:authorization`, `:transaction`, or
  `:transaction_disputed` for a settlement whose report contradicted the
  signed payment, with `:dispute` naming why: `:payer_mismatch`,
  `:amount_mismatch`, or `:pending_hash_changed` when the retry after
  `settlement_pending` named another hash), `:app`,
  `:network`, `:asset`, `:pay_to`, `:payer`, `:amount`, `:resource`, and
  for `:transaction` also `:tx_hash` and `:auth_key` (the `"auth:"` key it
  settled). Claims are never released: a payment whose settlement failed
  stays claimed, and the client signs a new one.

  `record_payment_intent(tx_key, payment_intent_id, config)` stores the
  Stripe PaymentIntent id on the `"tx:"` row once it is recorded.
  `unrecorded(limit, config)` lists `:transaction` rows (not disputed ones) that have none yet, oldest
  first, as maps with `:key`, `:tx_hash`, `:network`, `:asset` and
  `:amount`; `X402.Reconciler` records them.

  Any `claim` return but `:ok` is treated as a refusal before settlement. An
  implementation that cannot reach its store should return an error, not `:ok`.

  One guard table serves one app with one deposit address (README, "One
  deposit address per app"): the table is the exactly-once boundary.

  `X402.ReplayGuard.Memory` is for tests. See the README for an Ecto version.
  """

  @type kind :: :authorization | :transaction | :transaction_disputed

  @type unrecorded_row :: %{
          key: String.t(),
          tx_hash: String.t(),
          network: String.t(),
          asset: String.t(),
          amount: String.t()
        }

  @callback claim(key :: String.t(), meta :: map(), config :: term()) ::
              :ok | {:error, :replayed} | {:error, term()}

  @callback record_payment_intent(
              tx_key :: String.t(),
              payment_intent_id :: String.t(),
              config :: term()
            ) :: :ok | {:error, term()}

  @callback unrecorded(limit :: pos_integer(), config :: term()) ::
              {:ok, [unrecorded_row()]} | {:error, term()}
end
