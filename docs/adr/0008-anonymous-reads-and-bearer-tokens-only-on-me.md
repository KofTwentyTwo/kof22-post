# ADR-0008: Read published content anonymously; send tokens only to /me

- **Status:** Superseded by ADR-0009 (Site API v2 sends the token on every request)
- **Date:** 2026-10-12
- **Pull request:** none (work on `main` until the first published version)

## Context

The Site API serves published content anonymously (`/v1/post`, `/v1/blog`, `/v1/tag`,
…) and requires a bearer token only for the authoring endpoints under `/v1/me`. The
API documentation (1.1.0) states that tokens must not be attached to other requests.
Rate limits are shared per host.

## Options considered

### Option A: one client that authenticates every request

- Pros: no routing rule.
- Cons: leaks tokens to endpoints that never need them; a failed refresh would break
  anonymous reading; contradicts the API documentation.

### Option B: path allow-list for the bearer token, cached anonymous reads

- Pros: tokens reach only `/v1/me` and `/v1/me/...`; reads work signed out and in
  mock mode; a small time-limited cache keeps read traffic low without polling.
- Cons: the allow-list must follow if the API adds authenticated paths elsewhere.

## Decision

Option B. `AuthMiddleware` attaches `Authorization` only to `/v1/me` paths, and the
app reads published posts, blogs and tags through generated anonymous operations with
an in-memory cache.

## Consequences

- Contract tests decode recorded anonymous responses and spec-based `/me` examples.
- A spec change that adds authenticated paths outside `/v1/me` must update the
  allow-list in the same change.
