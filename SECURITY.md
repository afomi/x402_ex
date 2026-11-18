# Security

x402_ex verifies payments, so we treat any flaw in it as serious.

## Reporting a vulnerability

Please report it privately through GitHub: open the repository's **Security** tab and choose **Report a vulnerability**.
Please don't open a public issue for it.
We aim to reply within three working days, and to agree a disclosure date with you.

## Supported versions

Only the latest release gets security fixes before 1.0.

## Scope

In scope: anything that lets a request be served without a matching, settled payment, lets one payment be accepted twice, or leaks a key or a credential.
That includes how the library parses headers and facilitator responses, and how it calls Stripe.

Out of scope: the facilitator and Stripe themselves, and how an app sets its rate limits or stores its replay rows, although we welcome notes on our guidance for those.

## How the library is meant to be deployed

- Each app has its own deposit address (`scope: [pay_to: …]`); never share one between apps.
- The replay guard's table has a unique index on its key.
- The paid path is rate-limited per client before `X402.handle/2`.
- Keys are passed as functions, so they stay out of crash reports.
- `allow_req_options` is set only in test config.
