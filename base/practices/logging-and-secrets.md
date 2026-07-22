# Logging and secrets

## Structured, correlated logs

- Prefer structured logging over ad-hoc prints in production code paths. Include
  a correlation id (a run id / request id) where the project has one, so a single
  operation's lines can be reconstructed after the fact.
- Every owner-visible mutation in an admin/privileged path emits **one** audit
  line with the actor and the key fields, so "who changed what" is answerable
  without re-running the code.

## Never log secrets

Never emit, in logs or error output:

- API keys, tokens, full JWTs, session cookies, passwords.
- Authorization headers or full request headers that may carry credentials.
- Full request/response bodies that may contain any of the above.

When logging an error that may wrap a fetch `Response` or a credential-bearing
object, log `{ err: err.message }` — not the whole object. Redact before you
print, not after someone finds it in a log.

## Why

Secrets in logs are a durable leak: logs get shipped, cached, and indexed. A
redaction-by-default posture and one clean audit line per mutation are the
portable minimum; a given project may tighten them further.
