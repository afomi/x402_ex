# Changelog

This project follows [Semantic Versioning](https://semver.org).
Before 1.0, a minor version may change the API; each change is listed here.

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
