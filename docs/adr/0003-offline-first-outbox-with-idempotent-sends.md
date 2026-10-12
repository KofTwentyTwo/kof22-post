# ADR-0003: Send every write through an offline-first outbox

- **Status:** Accepted
- **Date:** 2026-10-11
- **Pull request:** none (initial build on `main`)

## Context

Posts are written on a phone, often with poor connectivity, and must never be lost or
published twice. The API supports idempotency keys on creates and uploads, and ETags
on updates.

## Options considered

### Option A: send directly from the composer, retry on failure

- Pros: simple.
- Cons: a post written offline is lost or blocks the UI; a lost response risks a
  double post.

### Option B: persistent outbox (SwiftData) drained by a processor

- Pros: survives app restarts and the Share Extension handing off; retries are safe
  with per-item idempotency keys; uploaded photo IDs are written back before the post
  call so a retry never re-uploads.
- Cons: more state to test (queued, sending, failed, sent, conflict).

## Decision

Option B. Creates, edits and deletes all go through `OutboxStore`/`OutboxProcessor`;
edits carry `If-Match` and a 412 becomes a user decision instead of an overwrite.

## Consequences

- The store lives in the App Group so the Share Extension and App Intents share it.
- Photo bytes upload on a background `URLSession` since 2026-10-12 (ADR-0007).
- Security: queued photos stay in the App Group container until sent; GPS is removed
  before upload unless the photo opts in (ADR-0005).
