# Changelog

This project follows [Semantic Versioning](https://semver.org).
Before 1.0, a minor version may change the API; each change is listed here.

## Unreleased

- `X402.Facilitator.CDP` signs its own requests, so Base mainnet payments go through Coinbase Developer Platform's facilitator.
  Before, it failed closed with `{:error, :not_implemented}` unless the app minted the token itself.
  Each `/verify` and `/settle` call carries `Authorization: Bearer <JWT>`, a new token per request, built as CDP's SDK builds it (`coinbase/cdp-sdk` `go/auth/jwt.go`, `GenerateJWT`, which the x402 reference's CDP client calls): header `alg`, `kid`, `nonce` (16 random bytes, hex) and `typ`; claims `sub` the key id (the header's `kid` too), `iss` `"cdp"`, `iat` and `nbf` now, `exp` now plus 120 seconds, and `uris` `["POST api.cdp.coinbase.com/platform/v2/x402/<verify|settle>"]`.
- Configure it with `key_id:` (a string or a 0-arity function) and `key_secret:` (a 0-arity function only), read on every call.
  `X402.Facilitator.CDP.JWT` reads both CDP key formats: Ed25519 (base64 of seed and public key, `EdDSA`), with the public half checked against the seed, and ECDSA P-256 PEM, SEC1 or PKCS #8 (`ES256`); a literal `\n` in the secret reads as a newline.
- A missing, unreadable or unrecognised key is now `{:error, :invalid_config}`, sent nothing, with a warning naming the reason as an atom, never the key; so is a key given alongside `:auth_headers`.
  `:not_implemented` stays in the `X402.Facilitator` error type, but no adapter returns it.
- The parsed key holds the private key only inside a signing closure, so neither `inspect/1` nor a raw crash report prints it.
- Tests check the token's exact bytes against a fixed key and clock, round-trip generated keys of each format, sign RFC 8037's Ed25519 vector exactly and read RFC 7515's ES256 vector, and show no secret or token in logs or `inspect`.
  Coinbase publishes no fixed JWT vector: its SDK tests generate keys at run time.
  No test calls CDP.

## v0.1.2 (2026-11-19)

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
