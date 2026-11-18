# Contributing

Thank you for helping.

## Before a pull request

```bash
mix deps.get --check-locked
mix format --check-formatted
mix compile --warnings-as-errors
mix test
mix docs --warnings-as-errors
mix hex.build
```

CI runs the same six steps.

## What we ask

- Cite the spec: any header, field or Stripe parameter you add gets its source in `docs/SPEC_NOTES.md`.
  Mark what you can't confirm as UNCONFIRMED rather than guessing.
- Fail closed: a new error path must never serve content without a settled, matching payment.
- Test the refusals as well as the happy path.
- Never log a key, a signature or a full payment header.
- Add a line to `CHANGELOG.md` under an "Unreleased" heading.

Security problems go through [SECURITY.md](SECURITY.md), not a public issue.
