# Changelog

This project follows [Semantic Versioning](https://semver.org).
Before 1.0, a minor version may change the API; each change is listed here.

## Unreleased

- `X402.handle/2` retries `/settle` once after `settlement_pending`, with the same request body, inside the same settle task and under the same `"auth:"` claim, as the reference server does; the chain spends an EIP-3009 nonce once, so the money cannot move twice.
  The retry gets what is left of the first call's `:settle_timeout` (floor 5 s), so settle, retry and the Stripe record fit `:settle_await_ms`.
  Only a success naming the pending hash is served.
  Another hash writes a `transaction_disputed` row keyed on the pending hash with `dispute: :pending_hash_changed`, logged `outcome=pending_hash_changed` with both hashes, and serves nothing.
  A second pending answer, or a refusal after the broadcast, is refused as `:settlement_pending` with the hash logged; a retry that times out, crashes or cannot be read fails closed as `outcome=settle_retry_unavailable`.
  A pending answer with no well-formed hash is not retried.
  Before, one pending answer was refused outright and the client signed a second authorization while the first could still confirm.
- `X402.ReplayGuard.Memory` refuses every call with `{:error, :memory_guard_not_allowed}` unless `config :x402_ex, allow_memory_guard: true` is set, which belongs in `config/test.exs` only, so a copied test config cannot ship a guard that forgets on restart; `X402.handle/2` then fails closed before any settle.
- `X402.Facilitator.HTTP.default_settle_timeout/0` names the 15 s default.

## v0.1.1 (2026-11-19)

- `X402.handle/2` checks every settlement an adapter returns before serving, not only `X402.Facilitator.HTTP`'s: the transaction hash must be well formed for the scheme and the network must be the offer's.
  One that is not is not served (`{:error, :facilitator_unavailable}`), and is logged as `outcome=settle_unavailable` with `reason=invalid_transaction` or `reason=settlement_network_mismatch` and `reconcile=check_payer_on_chain`.
  A hash in mixed case is lowercased once, so the `"tx:"` key, the row's `tx_hash`, Stripe's idempotency key and `PAYMENT-RESPONSE` agree; before, the key was lowercased and the row and the header were not.
- CI also checks the lockfile (`mix deps.get --check-locked`), builds the docs with warnings as errors and builds the Hex package; `CONTRIBUTING.md` ships in the package.
- `docs/SPEC_NOTES.md` re-read against the x402 Foundation repository: standard base64 only and strict `value == amount` are confirmed from the reference code, and the reference server's retry of `settlement_pending` is noted.
- README: browser clients need `PAYMENT-RESPONSE` in `Access-Control-Expose-Headers`; a reconciler run that overlaps a request's Stripe call gets a 409 and finishes next time.
- Elixir 1.18 minimum (was 1.15), tested on 1.19; CI runs 1.19 only.

## v0.1.0 (2026-11-18)

The first release.
It was reviewed for security by a second team before it was tagged.

- `X402.Offer` builds the `PAYMENT-REQUIRED` challenge for the x402 v2 `exact` scheme on EVM networks.
- `X402.Payment` decodes and matches a `PAYMENT-SIGNATURE` header, treating all of it as untrusted.
- `X402.Facilitator` is a behaviour, with adapters for the public x402.org test facilitator and for Coinbase Developer Platform.
  CDP authentication is not implemented yet and fails closed.
- `X402.ReplayGuard` is a behaviour, so each payment is accepted exactly once.
  `X402.ReplayGuard.Memory` is for tests only.
- `X402.Stripe` records a settled payment as a Stripe machine payment.
- `X402.Reconciler` records settled payments a failure left without a Stripe record.
- `X402.handle/2` runs the whole paid retry and fails closed.

Known limits:
- Only USDC on Base and Base Sepolia.
- No local check of the EIP-712 signature: the facilitator's `/verify` does it.
- No end-to-end run against Base Sepolia and a Stripe sandbox yet.
