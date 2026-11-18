# x402_ex

x402 v2 payments for Plug and Phoenix apps.
It answers a request with a payable offer (HTTP 402 and a `PAYMENT-REQUIRED` header), and accepts a payment for that offer exactly once.

v0.1 speaks the `exact` scheme on EVM networks with EIP-3009 transfers: USDC on Base, and on Base Sepolia for testing.
Settled payments can be recorded in Stripe as machine payments.

Every header and field is sourced in [docs/SPEC_NOTES.md](docs/SPEC_NOTES.md); what we could not confirm is marked there.

## Installation

```elixir
def deps do
  [
    {:x402_ex, git: "https://github.com/afomi/x402_ex.git", tag: "v0.1.0"}
  ]
end
```

## Use

```elixir
{:ok, usdc} = X402.Scheme.ExactEvm.usdc("eip155:84532")

offer =
  X402.Offer.new!(%{
    amount: 10_000,
    network: "eip155:84532",
    asset: usdc.asset,
    extra: usdc.extra,
    pay_to: deposit_address,
    resource: "https://example.org" <> conn.request_path,
    description: "One page over the crawl budget",
    max_timeout_seconds: 60
  })

case X402.handle(conn,
       offer: offer,
       facilitator: {X402.Facilitator.X402Org, []},
       replay_guard: {MyApp.X402Claims, []},
       on_settled: &X402.Stripe.record(stripe_secret_key, &1)
     ) do
  {:ok, conn, _settlement} ->
    serve_page(conn)

  {:payment_required, challenge} ->
    conn |> X402.put_challenge(challenge) |> send_resp(402, "{}")

  {:payment_required, challenge, _reason} ->
    conn |> X402.put_challenge(challenge) |> send_resp(402, "{}")

  {:error, _facilitator_or_guard_unavailable} ->
    send_resp(conn, 503, "")
end
```

On Base mainnet, use `{X402.Facilitator.CDP, key_id: id, key_secret: secret}`.
Its JWT auth is not built in v0.1 (see the module docs), so on its own it fails closed with `{:error, :not_implemented}`.

`X402.handle/2`'s module docs explain the order of the steps and why the payment is claimed before it is settled.

## Modules

- `X402`: `handle/2`, the whole flow for one request; header names.
- `X402.Offer`: an offer and its `PAYMENT-REQUIRED` header.
- `X402.Payment`: decodes the client's `PAYMENT-SIGNATURE` header and matches it to an offer.
- `X402.Scheme`: picks the rules for a scheme on a network; `X402.Scheme.ExactEvm` is the one in v0.1.
- `X402.Facilitator`: the verify and settle behaviour; `X402.Facilitator.X402Org` and `X402.Facilitator.CDP` adapters over `X402.Facilitator.HTTP`.
- `X402.Settlement`: a checked settlement and its `PAYMENT-RESPONSE` header.
- `X402.ReplayGuard`: the claim behaviour; `X402.ReplayGuard.Memory` for tests.
- `X402.Stripe`: records a settlement as a Stripe PaymentIntent.
- `X402.Codec`: base64 JSON with a size cap.

## Replay guard

Each app keeps its own claims, in its own database, behind a unique index.
The index is what makes a claim atomic across concurrent requests and across nodes.
`X402.ReplayGuard.Memory` is for tests only: it forgets on restart and knows nothing of other nodes.

Migration:

```elixir
defmodule MyApp.Repo.Migrations.CreateX402Claims do
  use Ecto.Migration

  def change do
    create table(:x402_claims) do
      # "auth:<payment id>" before settling, "tx:<network>:<tx hash>" after.
      add :key, :text, null: false
      # "authorization" or "transaction".
      add :kind, :text, null: false
      add :network, :text, null: false
      add :payer, :text
      add :amount, :text, null: false
      add :resource, :text, null: false
      # Set on "transaction" claims: the on-chain hash, also Stripe's idempotency key.
      add :tx_hash, :text

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:x402_claims, [:key])
    create index(:x402_claims, [:tx_hash])
  end
end
```

Guard:

```elixir
defmodule MyApp.X402Claims do
  @behaviour X402.ReplayGuard

  require Logger

  @impl true
  def claim(key, meta, _config) do
    row = %{
      key: key,
      kind: Atom.to_string(meta.kind),
      network: meta.network,
      payer: meta.payer,
      amount: meta.amount,
      resource: meta.resource,
      tx_hash: meta.tx_hash,
      inserted_at: DateTime.utc_now()
    }

    case MyApp.Repo.insert_all("x402_claims", [row], on_conflict: :nothing, conflict_target: [:key]) do
      {1, _} -> :ok
      {0, _} -> {:error, :replayed}
    end
  rescue
    e ->
      Logger.error("x402 claim failed: #{inspect(e.__struct__)}")
      {:error, :unavailable}
  end
end
```

Any return but `:ok` refuses the payment, so a database outage fails closed.
Claims are never deleted: a failed settlement leaves its authorization claimed, and the client signs a new one.

## Logging

The library logs the outcome, the payer address and the transaction hash.
It never logs a payment header, a signature or a key.

## Tests

```bash
mix test
mix format --check-formatted
mix compile --warnings-as-errors
```

The tests make no network calls; facilitators and Stripe are stubbed with `Req.Test`.
