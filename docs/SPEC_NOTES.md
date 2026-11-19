# Spec notes

Every header name, JSON field and Stripe parameter this library uses, with the source it came from.
Anything we could not confirm is marked **UNCONFIRMED**.

Sources were read on 2026-11-18 at these commits:

- x402: https://github.com/coinbase/x402 at `0e6e8c55d86b4f14234fb6e49a4052074fb93e57`.
  Its README says the repo has moved to https://github.com/x402-foundation/x402 and `coinbase/x402` is now a development fork; the spec files are the same paths in both.
- Stripe sample: https://github.com/stripe-samples/machine-payments at `e535a061b6fb7184d2167884a91777cf6a65cb41`.
- Stripe docs: https://docs.stripe.com/payments/machine/x402 and https://docs.stripe.com/payments/machine.

Re-read for the v0.1.1 review, also on 2026-11-18, at https://github.com/x402-foundation/x402 `b00738784bfa78832f5a8caa3834fe1e28273369` (`main`), the Stripe sample at the same commit as above, and `STRIPE_X402` as served that day.
Where a note below cites the reference code by path, the path is the same in both repositories.

Short names used below:

- `SPEC` = https://github.com/coinbase/x402/blob/0e6e8c55d86b4f14234fb6e49a4052074fb93e57/specs/x402-specification-v2.md
- `HTTP` = https://github.com/coinbase/x402/blob/0e6e8c55d86b4f14234fb6e49a4052074fb93e57/specs/transports-v2/http.md
- `EVM` = https://github.com/coinbase/x402/blob/0e6e8c55d86b4f14234fb6e49a4052074fb93e57/specs/schemes/exact/scheme_exact_evm.md
- `SAMPLE_TS` = https://github.com/stripe-samples/machine-payments/blob/e535a061b6fb7184d2167884a91777cf6a65cb41/x402/server/node-typescript/main.ts
- `SAMPLE_PY` = https://github.com/stripe-samples/machine-payments/blob/e535a061b6fb7184d2167884a91777cf6a65cb41/x402/server/python/main.py
- `STRIPE_X402` = https://docs.stripe.com/payments/machine/x402

## Headers

`HTTP`, "Header Summary":

| Header | Direction | Description |
| ------ | --------- | ----------- |
| `PAYMENT-REQUIRED` | Server → Client | Base64-encoded `PaymentRequired` object |
| `PAYMENT-SIGNATURE` | Client → Server | Base64-encoded `PaymentPayload` object |
| `PAYMENT-RESPONSE` | Server → Client | Base64-encoded `SettlementResponse` object |

We read and write them lowercased (`payment-signature`, `payment-required`, `payment-response`), as Plug requires; HTTP header names are case-insensitive.
`STRIPE_X402` shows the same header lowercased in a real response: `< payment-required: eyJ4NDAyVmVyc2lvbiI6MiwiZXJyb3IiO...`.

Encoding: "Base64-encoded" JSON (`HTTP`).
The spec's own examples use the standard alphabet with `=` padding (the `PAYMENT-SIGNATURE` example ends in `fX0=`), and the reference client encodes with `btoa` or `Buffer.toString("base64")`, both standard and padded (`typescript/packages/core/src/utils/index.ts`, `safeBase64Encode`).
We encode standard and padded, and decode standard padded or unpadded.
URL-safe base64 is refused (`:invalid_base64`), as the reference does: its `Base64EncodedRegex` is `/^[A-Za-z0-9+/]*={0,2}$/` (same file), which admits neither `-` nor `_`.
The reference encodes the JSON as UTF-8 before base64 (`TextEncoder`, or `Buffer.from(data, "utf8")`) and decodes it back as UTF-8, so a non-ASCII `description` round-trips; we encode UTF-8 too (`Jason.encode!/1`).

The 402 status: `HTTP`, "Payment Required Signaling": "HTTP 402 status code with `PAYMENT-REQUIRED` header".
Status mapping (`HTTP`, "Error Handling"): Payment Required 402, Invalid Payment 400 ("Malformed payment payload or requirements"), Payment Failed 402, Server Error 500, Success 200.

The challenge's `error` text `"PAYMENT-SIGNATURE header is required"` is the spec's example value (`SPEC` 5.1.1).

## PaymentRequired

`SPEC` 5.1.2.
Fields we write: `x402Version` (2), `error` (optional), `resource`, `accepts`.
We do not write `extensions` (optional).

`resource` is a `ResourceInfo`: `url` (required), `description`, `mimeType` (optional).
We do not write `serviceName`, `tags` or `iconUrl`.

Each `accepts` entry is a `PaymentRequirements`: `scheme`, `network` (CAIP-2), `amount` ("in atomic token units", a string), `asset`, `payTo`, `maxTimeoutSeconds` (number), `extra` (optional object).
We write exactly one entry.

## PaymentPayload

`SPEC` 5.2.2: `x402Version` (required), `resource` (optional), `accepted` (required, a `PaymentRequirements`), `payload` (required, scheme-specific), `extensions` (optional).

We require `resource`, although the spec marks it optional, so a payment for one URL is not spent on another.
The reference client always sends it: `typescript/packages/core/src/client/x402Client.ts` builds the payload with `resource: paymentRequired.resource`.

## Matching a payment to the offer

The reference server's rule (`typescript/packages/core/src/server/x402ResourceServer.ts`, `paymentRequirementsMatchAccepted`): "Core payment terms and all server-declared `extra` fields must match exactly, but clients may include additive scheme-specific metadata under `accepted.extra`."
It compares the core fields with `deepEqual` and `extra` with `objectContainsSubset`.
We do the same, field by field, so each refusal has its own reason.
The reference server never reads the payload's `resource` when matching (`findMatchingRequirements`); our `resource.url` check is our own rule, stricter than the reference, and the reference client always sends the field.

What goes to the facilitator is the server's own `PaymentRequirements`, never the client's `accepted` (`verifyPayment` and `settleWithPendingRetry` in the same file); we do the same (`X402.Facilitator.request/2`), so a client cannot add keys to what the facilitator checks.

Addresses: the spec does not state a case rule.
The reference EVM facilitator normalises with viem's `getAddress` before comparing (`typescript/packages/mechanisms/evm/src/exact/facilitator/eip3009.ts`: `getAddress(eip3009Payload.authorization.to) !== getAddress(requirements.payTo)`), which makes the comparison case-insensitive.
`STRIPE_X402` lowercases its deposit address before using it as `payTo`.
So on `eip155:*` we compare `asset`, `payTo` and `authorization.to` case-insensitively; every other field is compared exactly.

## exact on EVM

`EVM`, section 1 (`EIP-3009`).
`payload` = `signature` plus `authorization` with `from`, `to`, `value`, `validAfter`, `validBefore`, `nonce`, all strings.
`extra.name` and `extra.version` are required (the token's EIP-712 domain).
`extra.assetTransferMethod` is optional and "if present, MUST be `\"eip3009\"`"; clients "should default to `\"eip3009\"`" when it is absent.
We refuse `permit2` and ERC-7710 in v0.1.

Amount: `EVM` Phase 2 says only that the "Amount" must "meet the `PaymentRequirements`".
The reference facilitator is strict: `BigInt(eip3009Payload.authorization.value) !== BigInt(requirements.amount)` is `invalid_exact_evm_payload_authorization_value` (`typescript/packages/mechanisms/evm/src/exact/facilitator/eip3009.ts`).
We require `authorization.value` to equal the offer's amount as a string, which is the same for every value the reference client sends (it copies `amount` verbatim); a numerically equal spelling such as `"010000"` is refused by us and would pass the reference.

Validity window, same file: `validBefore < now + 6` is expired (a six-second buffer for block time) and `validAfter > now` is not yet valid.
We do not check the window; the facilitator's `/verify` does.

Signature: `EVM` says "the 65-byte signature".
The reference facilitator has no length check; it hashes the typed data and verifies with ecrecover for an account without code, strict EIP-1271 for one with code, and ERC-6492 for a counterfactual account whose factory is allow-listed, and it rejects a non-canonical ECDSA `s`.
We require at least 65 bytes of hex before the facilitator is asked.
**UNCONFIRMED:** whether any client sends a 64-byte compact (EIP-2098) signature; we would refuse it as `:invalid_payload`.

USDC addresses and domains, from `typescript/packages/mechanisms/evm/src/defaultAssets.ts`:

- `eip155:8453` (Base): `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`, name `USD Coin`, version `2`, 6 decimals.
- `eip155:84532` (Base Sepolia): `0x036CbD53842c5426634e7929541eC2318f3dCF7e`, name `USDC`, version `2`, 6 decimals.

`STRIPE_X402`, "Token and network support", lists the same Base contract.

Replay: `SPEC` 10.1, "EIP-3009 contracts inherently prevent nonce reuse at the smart contract level".
EIP-3009 nonces are per authorizer on each token contract, so network, asset, `from` and `nonce` together name one authorization; that is our pre-settlement replay key.

## Facilitator

`/verify`: `SPEC` 7.1.
Request: `{"x402Version": 2, "paymentPayload": ..., "paymentRequirements": ...}`.
Response: `VerifyResponse` (`SPEC` 5.4.2): `isValid` (required), `invalidReason`, `payer`.
`/verify` "is **read-only**".

`/settle`: `SPEC` 7.2, same request body.
Response: `SettleResponse` (`SPEC` 5.3.2): `success`, `errorReason`, `payer`, `transaction` (required; "empty string if no transaction was broadcast"), `network` (required), `amount` (optional, "the actual amount settled in atomic units").
The reference EVM facilitator does not return `amount`; when one is present we require it to equal the offer's.

`settlement_pending` (`SPEC` 9): "broadcast but its confirmation could not be established"; "**non-terminal**"; carries a non-empty `transaction`.
The reference server retries `/settle` once with the same payload (`settleWithPendingRetry`, `x402ResourceServer.ts`), and the reference facilitator keeps a store keyed by the signature so the retry reconciles against the hash it already broadcast.
We do the same from v0.1.2: one retry with the same request body, under the same `"auth:"` claim, given what is left of the settle budget (floor 5 s).
We go one step further than the reference and serve only a success whose hash equals the pending one; a success naming another hash is written as a disputed row and served nothing, since Stripe would otherwise verify the second hash while the money moved in the first.
A second `settlement_pending` is refused, the payment stays claimed and the hash is logged.

Non-2xx handling follows the reference client (`typescript/packages/core/src/http/httpFacilitatorClient.ts`): a non-2xx body with `isValid` (or `success`) is raised as a structured `VerifyError` or `SettleError` carrying that body, that is, a verdict; anything else is a plain error.
The reference follows redirects (`redirect: "follow"`) and waits up to 90 seconds (`DEFAULT_TIMEOUT_MS`); we follow none and wait 5 seconds for `/verify` and 15 for `/settle` by default.

## Facilitators

- x402.org: `https://x402.org/facilitator`, the reference `DEFAULT_FACILITATOR_URL` (`httpFacilitatorClient.ts`), named by `STRIPE_X402` "Test in a Stripe sandbox" for Base Sepolia.
- CDP: `https://api.cdp.coinbase.com/platform/v2/x402` (`go/legacy/pkg/coinbasefacilitator/facilitator.go`, `CoinbaseFacilitatorBaseURL` + `CoinbaseFacilitatorV2Route`; `SAMPLE_PY`, `CDP_FACILITATOR_URL`).
  Auth is `Authorization: Bearer <JWT>` per request, minted by the CDP SDK from the key id and secret for `POST api.cdp.coinbase.com/platform/v2/x402/verify` (or `/settle`) (`go/legacy/pkg/coinbasefacilitator/cdp.go`, `auth.GenerateJWT`; `SAMPLE_PY`, `cdp.auth.get_auth_headers`).
  The Go client also sends a `Correlation-Context` header.
  **UNCONFIRMED / NOT IMPLEMENTED:** the JWT's claims, algorithm and key format; v0.1 returns `{:error, :not_implemented}` unless the app passes an `:auth_headers` function. We send no `Correlation-Context`.

## Stripe

The PaymentIntent create call, from `SAMPLE_TS` (and the identical `SAMPLE_PY` and `STRIPE_X402` "Create a PaymentIntent"):

```ts
stripe.paymentIntents.create(
  {
    amount: amountInCents,
    currency: "usd",
    confirm: true,
    payment_method_data: { type: "crypto" },
    allowed_payment_method_types: ["crypto"],
    payment_method_options: {
      crypto: {
        mode: "transaction_verification",
        transaction_verification_options: {
          network: "base",
          transaction_hash: txHash,
        },
      },
    },
  },
  { idempotencyKey: txHash },
);
```

We send it as `POST https://api.stripe.com/v1/payment_intents`, form-encoded, with these keys:
`amount`, `currency=usd`, `confirm=true`, `payment_method_data[type]=crypto`, `allowed_payment_method_types[0]=crypto`, `payment_method_options[crypto][mode]=transaction_verification`, `payment_method_options[crypto][transaction_verification_options][network]=base`, `payment_method_options[crypto][transaction_verification_options][transaction_hash]=<tx>`.
Headers: `Authorization: Bearer <secret key>`, `Stripe-Version`, `Idempotency-Key: <tx hash>`.
The bracketed form keys and the `[0]` array index are how Stripe's server SDKs encode nested params; **UNCONFIRMED** against a live Stripe call in this repo.
Re-checked on 2026-11-18: `STRIPE_X402` "Create a PaymentIntent" still shows exactly these parameters and `{ idempotencyKey: txHash }`, and its "Token and network support" table now also lists USDC on Tempo and Solana, which this library does not offer.

The parameter is `allowed_payment_method_types`, not `payment_method_types`: that is what the sample and the docs use.
`payment_method_data[type]=crypto` and `confirm=true` are also in both.

`Stripe-Version`: we default to `2026-05-27.preview`, which `STRIPE_X402` requires ("This feature requires the `2026-05-27.preview` API version").
The sources disagree: the sample sets `2026-10-28.preview` (`SAMPLE_TS` `apiVersion`, `SAMPLE_PY` `stripe.api_version`), and the docs' sandbox section creates its deposit address with `2026-07-29.preview`.
The sandbox version is for deposit-address creation, not this call.
The sample's version is its Stripe client's, so the sample does send `2026-10-28.preview` on its PaymentIntent create.
The docs name `2026-05-27.preview` for this call explicitly, so that stays the default (the jurisdictional review of v0.1 agreed).
**UNCONFIRMED** whether Stripe also accepts the newer preview for it; pass `stripe_version:` to choose.

Amount: "requirements.amount is in atomic USDC units (6 decimals). $0.01 = 10000 atomic units. Convert to cents for Stripe." (`SAMPLE_TS`).
The sample rounds and skips under one cent; we refuse anything that is not a whole number of cents.
Minimum: "the minimum amount is 0.01 USDC" for stablecoin payments (https://docs.stripe.com/payments/machine, "Microtransactions").

`network: "base"` is from the sample, for Base mainnet.
**UNCONFIRMED:** the value for a Base Sepolia transaction in a Stripe sandbox. `STRIPE_X402` creates the sandbox deposit address with `network=base`, so we map `eip155:84532` to `base` too; pass `stripe_network:` to override.

Deposit address (not used by this library, the app creates it ahead of time): `POST /v1/crypto/deposit_addresses` with `network=base` (`STRIPE_X402`, "Create a Stripe deposit address").
