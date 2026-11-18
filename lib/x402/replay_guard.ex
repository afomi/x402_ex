defmodule X402.ReplayGuard do
  @moduledoc """
  Claims a payment once, so it buys exactly one response.

  `claim(key, meta, config)` must be atomic: of any number of concurrent
  claims of one key, exactly one returns `:ok` and the rest
  `{:error, :replayed}`, across every node that serves the app. A database
  unique index gives this; an in-process map does not across nodes.

  `X402.handle/2` claims two keys per payment (see its moduledoc):

    * `"auth:" <> payment_id` before settling, which names the signed
      authorization (for EVM: network, asset, payer and EIP-3009 nonce);
    * `"tx:" <> network <> ":" <> tx_hash` after settling, the on-chain transaction.

  `meta` is a map with `:kind` (`:authorization` or `:transaction`),
  `:network`, `:payer`, `:amount`, `:resource` and, for `:transaction`,
  `:tx_hash`. Claims are never released: a payment whose settlement failed
  stays claimed, and the client signs a new one.

  Any return but `:ok` is treated as a refusal. An implementation that cannot
  reach its store should return an error, not `:ok`.

  `X402.ReplayGuard.Memory` is for tests. See the README for an Ecto version.
  """

  @type kind :: :authorization | :transaction

  @callback claim(key :: String.t(), meta :: map(), config :: term()) ::
              :ok | {:error, :replayed} | {:error, term()}
end
