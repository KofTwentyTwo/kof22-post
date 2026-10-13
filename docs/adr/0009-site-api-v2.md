# ADR-0009: Build on Site API v2 and make its missing guarantees client-side

- **Status:** Accepted
- **Date:** 2026-10-13
- **Pull request:** none (work on `main` until the first published version)
- **Supersedes:** ADR-0008; changes how ADR-0003 avoids double posts

## Context

Site API v2 (2.0.0 on 2026-10-12, 2.1.0 on 2026-10-13) replaced v1 and removed it. v2 publishes the
CMS model itself: every admin table with all its fields (name, short name, slug, description, SEO
fields, featured image, author, featured flag, schedule), so the app can finally set everything a
post has, which the owner asked for. The owner decided the app supports v2 only and the v1 client
and mock are removed.

v2 differs from v1 in ways that matter to an offline outbox: no idempotency keys, no ETags or
`If-Match`, untyped process endpoints (`/me`, uploads, link preview), a 2 MB spec, and the
bearer token on every request (a token also shows drafts).

## Options considered

### Option A: generate the whole v2 client and rely on the server

- Pros: least code.
- Cons: a 2 MB spec and ten thousand lines of generated code for tables the app never uses;
  retries could double-post; edits could silently overwrite changes made in the admin.

### Option B: filtered client, app-owned models, guarantees rebuilt in `SiteService`

- Pros: only the used operations are generated (93 KB spec); screens and the outbox keep one
  stable model; no double posts (adopt the post a lost attempt created, matched by blog, author,
  slug family and body, else a free slug against the database's unique `(slug, blogId)`); edit and
  delete conflicts detected by comparing `modifyDate` before writing.
- Cons: the conflict check is read-then-write, not atomic; a change in the same instant can slip
  through. Process payload types are hand-written from the documentation.

## Decision

Option B. `make update-spec` filters the live spec with the generator's `filter` command;
`APIMapping` converts records; `ProcessClient` calls the untyped processes through the same
middlewares; `AuthMiddleware` sends the token on every request; the in-process fake follows v2
(ADR-0002 still holds for its purpose).

## Consequences

- Every post field is settable from the app.
- The outbox keeps its no-double-post promise without server idempotency.
- Edit conflicts are best effort (seconds-wide window) until the API offers a precondition.
- Revisit when v2 adds idempotency keys or ETags: switch to them and drop the client-side checks.
