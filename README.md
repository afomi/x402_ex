# x402_ex

x402 v2 payments for Plug and Phoenix apps.
It answers a request with a payable offer (HTTP 402 and a `PAYMENT-REQUIRED` header), and accepts a payment for that offer exactly once.

v0.1 speaks the `exact` scheme on EVM networks with EIP-3009 transfers: USDC on Base, and on Base Sepolia for testing.
Settled payments are recorded in Stripe as machine payments, and a reconciler finishes any record a failure cut short.

Every header and field is sourced in [docs/SPEC_NOTES.md](docs/SPEC_NOTES.md); what we could not confirm is marked there.

## Status

v0.1 is ready for sandbox use: Base Sepolia, the x402.org test facilitator and a Stripe sandbox.
It has not yet carried a live payment.
Coinbase Developer Platform authentication, needed for mainnet, is listed under "Unreleased" in the changelog: it waits on a security review before it is tagged.
The API may change before 1.0, as [CHANGELOG.md](CHANGELOG.md) records.

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
       scope: [app: "bitblocks", pay_to: deposit_address],
       facilitator: {X402.Facilitator.X402Org, []},
       replay_guard: {MyApp.X402Claims, []},
       on_settled: &X402.Stripe.record(fn -> stripe_secret_key() end, &1)
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

On a network whose USDC the library knows (Base, Base Sepolia), an offer must use that USDC's contract and EIP-712 domain; `allow_unknown_asset: true` opts out.
`X402.Stripe` refuses a live key with Base Sepolia and a test key with Base mainnet, so faucet USDC never shows up as live revenue.

## Base mainnet: the CDP facilitator

On Base mainnet (`eip155:8453`), payments go through Coinbase Developer Platform's facilitator, which takes a signed JWT on every request.
Create a Secret API Key in the CDP portal (Ed25519, the default, or ECDSA), keep its id and secret in your secret store, and pass both as functions:

```elixir
{:ok, usdc} = X402.Scheme.ExactEvm.usdc("eip155:8453")

X402.handle(conn,
  offer: offer,  # network: "eip155:8453", asset: usdc.asset, extra: usdc.extra
  scope: [app: "my-app", pay_to: deposit_address],
  facilitator:
    {X402.Facilitator.CDP,
     key_id: fn -> System.fetch_env!("CDP_API_KEY_ID") end,
     key_secret: fn -> System.fetch_env!("CDP_API_KEY_SECRET") end},
  replay_guard: {MyApp.X402Claims, []},
  on_settled: &X402.Stripe.record(fn -> stripe_live_secret_key() end, &1)
)
```

Each call to `/verify` and `/settle` gets its own token, signed with the key and bound to that one request (`"POST api.cdp.coinbase.com/platform/v2/x402/verify"`), lasting 120 seconds, as CDP's SDK builds it (`X402.Facilitator.CDP.JWT`).
The secret is read on each call and never stored, logged or printed; a secret given as a plain string is refused.
The URL is fixed, so a token can only go to `api.cdp.coinbase.com`.
A missing or unreadable key fails closed with `{:error, :invalid_config}` before any request, and a warning names the reason, never the key.
The token's `nbf` is the server's clock, so keep it synchronised (NTP): a clock running ahead of CDP's is refused.

Pass secrets (the Stripe key, the CDP key secret) as 0-arity functions, so they never sit in an argument or keyword list that a crash report could print.

`X402.handle/2`'s module docs explain the order of the steps, why the payment is claimed before it is settled, and what happens after the money moves.

A 503 after the settle wait (`:settle_await_ms`, 40 seconds by default) may still mean "paid".
The settlement carries on after the request gives up, and its `"tx:"` row and the reconciler record it.
The client's retry with the same header is refused as replayed, so it signs a new payment; it is never charged twice for one authorization.
A settle in flight also gets 30 seconds to finish when the app shuts down, so a deploy does not cut it short.

A facilitator that answers `settlement_pending` (broadcast, not yet confirmed) is asked once more, with the same request, inside the same settle task and under the same claim, as the reference server does.
Only a success naming the same hash is served; another hash is written as a disputed row and served nothing.
The retry gets what is left of the first call's `:settle_timeout`, never under 5 seconds, so the whole thing still fits the settle wait.

## One deposit address per app

The exactly-once boundary is one app's guard table.
Two apps with separate tables that shared a deposit address could each accept the same signed authorization, if a facilitator answered a repeated settle with the original transaction.
So each app must have its own deposit address, even on a shared Stripe account: create one per app with `POST /v1/crypto/deposit_addresses`.

`:scope` makes this explicit in each app's code.
It names the app and its one deposit address, and `X402.handle/2` raises `ArgumentError` for an offer that pays any other address.
Each claim row carries the app's name.
Record each app's deposit address in its PLAN.md, so the rule stays visible across both apps.

## Rate limiting

Rate-limit the paid path per client before calling `X402.handle/2`.
Every well-formed `PAYMENT-SIGNATURE` header costs a facilitator `/verify` call of up to 5 seconds, whether or not its signature is genuine.
The library does no rate limiting of its own.

## Browser clients

The protocol lives in headers, so a browser client can only read `PAYMENT-RESPONSE` if the server names it in `Access-Control-Expose-Headers` (transports-v2/http.md, "Browser Clients").
The library sets no CORS headers; add that one in your CORS plug if browsers will pay.

## Modules

- `X402`: `handle/2`, the whole flow for one request; header names.
- `X402.Offer`: an offer and its `PAYMENT-REQUIRED` header.
- `X402.Payment`: decodes the client's `PAYMENT-SIGNATURE` header and matches it to an offer.
- `X402.Scheme`: picks the rules for a scheme on a network; `X402.Scheme.ExactEvm` is the one in v0.1.
- `X402.Facilitator`: the verify and settle behaviour; `X402.Facilitator.X402Org` and `X402.Facilitator.CDP` adapters over `X402.Facilitator.HTTP`; `X402.Facilitator.CDP.JWT` signs CDP's per-request token.
- `X402.Settlement`: a checked settlement and its `PAYMENT-RESPONSE` header.
- `X402.ReplayGuard`: the claim and record behaviour; `X402.ReplayGuard.Memory` for tests.
- `X402.Stripe`: records a settlement as a Stripe PaymentIntent.
- `X402.Reconciler`: records settlements that have no PaymentIntent yet.
- `X402.HTTPClient`: the one place requests are made (no redirects, no decompression, a 64 KB body cap, a whole-response deadline).
- `X402.Codec`: base64 JSON with a size cap.

## Replay guard

Each app keeps its own claims, in its own database, behind a unique index.
The index is what makes a claim atomic across concurrent requests and across nodes.
`X402.ReplayGuard.Memory` is for tests only: it forgets on restart and knows nothing of other nodes.
It refuses every call with `{:error, :memory_guard_not_allowed}` unless `config :x402_ex, allow_memory_guard: true` is set, which belongs in `config/test.exs` only; `X402.handle/2` then fails closed before any settle.

Migration:

```elixir
defmodule MyApp.Repo.Migrations.CreateX402Claims do
  use Ecto.Migration

  def change do
    create table(:x402_claims) do
      # "auth:<payment id>" before settling, "tx:<network>:<tx hash>" after.
      add :key, :text, null: false
      # "authorization", "transaction", or "transaction_disputed" (a settle that
      # reported success but contradicted the signed payment; see :dispute).
      add :kind, :text, null: false
      # On "transaction_disputed" rows: "payer_mismatch", "amount_mismatch" or
      # "pending_hash_changed" (the retry after settlement_pending named another hash).
      add :dispute, :text
      # The app this claim belongs to (the :scope app name).
      add :app, :text, null: false
      add :network, :text, null: false
      add :asset, :text, null: false
      add :pay_to, :text, null: false
      add :payer, :text
      add :amount, :text, null: false
      add :resource, :text, null: false
      # On "transaction" rows: the on-chain hash (also Stripe's idempotency key),
      # the "auth:" key it settled, and the Stripe PaymentIntent once recorded.
      add :tx_hash, :text
      add :auth_key, :text
      add :payment_intent_id, :text

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:x402_claims, [:key])
    create index(:x402_claims, [:tx_hash])
    create index(:x402_claims, [:auth_key])

    # The reconciler's query: settled, not yet in Stripe.
    create index(:x402_claims, [:inserted_at],
             where: "kind = 'transaction' AND payment_intent_id IS NULL",
             name: :x402_claims_unrecorded_index
           )
  end
end
```

Guard:

```elixir
defmodule MyApp.X402Claims do
  @behaviour X402.ReplayGuard

  import Ecto.Query

  require Logger

  @impl true
  def claim(key, meta, _config) do
    row = %{
      key: key,
      kind: Atom.to_string(meta.kind),
      app: meta.app,
      network: meta.network,
      asset: meta.asset,
      pay_to: meta.pay_to,
      payer: meta.payer,
      amount: meta.amount,
      resource: meta.resource,
      tx_hash: meta.tx_hash,
      auth_key: meta.auth_key,
      dispute: meta.dispute && Atom.to_string(meta.dispute),
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

  @impl true
  def record_payment_intent(tx_key, payment_intent_id, _config) do
    case MyApp.Repo.update_all(
           from(c in "x402_claims", where: c.key == ^tx_key),
           set: [payment_intent_id: payment_intent_id]
         ) do
      {1, _} -> :ok
      _ -> {:error, :not_found}
    end
  end

  @impl true
  def unrecorded(limit, _config) do
    rows =
      MyApp.Repo.all(
        from c in "x402_claims",
          where: c.kind == "transaction" and is_nil(c.payment_intent_id),
          order_by: c.inserted_at,
          limit: ^limit,
          select: %{key: c.key, tx_hash: c.tx_hash, network: c.network, asset: c.asset, amount: c.amount}
      )

    {:ok, rows}
  end
end
```

Any `claim` return but `:ok` refuses the payment before settlement, so a database outage fails closed.
After settlement, a failed `"tx:"` claim no longer refuses: the client has paid, so it is served and the failure is logged at error level with the transaction hash (`outcome=tx_claim_failed`).
Claims are never deleted: a failed settlement leaves its authorization claimed, and the client signs a new one.

## Reconciling with Stripe

`X402.handle/2` writes the `"tx:"` row right after settlement, then records the payment in Stripe and stores the PaymentIntent id on that row.
If the Stripe step fails, the row is left without one.
Run the reconciler on a schedule, well within Stripe's 24-hour idempotency window:

```elixir
X402.Reconciler.record_unrecorded({MyApp.X402Claims, []}, fn -> stripe_secret_key() end)
```

It is safe to repeat: the idempotency key is the transaction hash, so Stripe returns the same PaymentIntent.
If a run overlaps a request's own Stripe call for the same hash, Stripe answers the second with a 409 (`idempotency_key_in_use`); that row is reported as failed and the next run finishes it.
It books only `kind = 'transaction'` rows.
A `transaction_disputed` row is a settlement whose report contradicted the signed payment, or a retry after `settlement_pending` that named another hash (`dispute = 'pending_hash_changed'`, keyed on the pending hash): the client was not served, the money may have moved, and it needs a person and a check on chain.
An `"auth:"` row with no `"tx:"` row whose `auth_key` points to it needs a check on chain first (`X402.Reconciler` docs).

## Configuration

```elixir
# config/test.exs, and only there: lets tests pass `req_options: [plug: {Req.Test, MyStub}]`
# and use `X402.ReplayGuard.Memory` as the replay guard.
config :x402_ex, allow_req_options: true, allow_memory_guard: true
```

Outside those settings, any `:req_options` is refused, because a `plug:` could stand in for the facilitator and forge its verdicts, and `X402.ReplayGuard.Memory` refuses every claim, because it would let a payment be replayed after a restart.

## Logging

The library logs the outcome, the payer address and the transaction hash.
It never logs a payment header, a signature, a key or a CDP token, and `X402.Payment` does not show the signed authorization when inspected.
Refusals of malformed headers log at debug level.

## Tests

```bash
mix test
mix format --check-formatted
mix compile --warnings-as-errors
```

The tests make no network calls; facilitators and Stripe are stubbed with `Req.Test`.
A live run against Base Sepolia, the public test facilitator and a Stripe sandbox is still owed before either app goes live.

## Contributing and security

See [CONTRIBUTING.md](CONTRIBUTING.md).
Please report vulnerabilities privately, as [SECURITY.md](SECURITY.md) describes.

## License

Copyright 2026 Afomi.
Licensed under the [Apache License, Version 2.0](LICENSE).
