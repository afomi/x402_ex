# Changelog

This project follows [Semantic Versioning](https://semver.org).
Before 1.0, a minor version may change the API; each change is listed here.

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
