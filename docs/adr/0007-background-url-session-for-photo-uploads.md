# ADR-0007: Upload photo bytes with a background URLSession

- **Status:** Accepted
- **Date:** 2026-10-12
- **Pull request:** none (work on `main` until the first published version)

## Context

Photo uploads go to a presigned storage URL that is valid for 15 minutes and needs no
`Authorization` header. Uploads of original photos can take longer than the time iOS
grants a backgrounded app, and the Share Extension can be terminated right after the
owner taps Post. The integration brief requires uploads to survive suspension.

## Options considered

### Option A: foreground URLSession plus background-task time

- Pros: simple; results always arrive in the calling task.
- Cons: uploads stop when the app is suspended or the extension exits.

### Option B: background URLSession for the PUT only

- Pros: the system finishes the transfer even after suspension or termination; the
  presigned URL needs no token, so nothing has to refresh in the background; the
  App Group container lets the app and the extension share the session.
- Cons: results can arrive in a later process; files must stay on disk until the
  transfer ends; the delegate bridging needs its own tests.

## Decision

Option B for the presigned PUT. Creating the upload ticket and completing it stay on
the regular session through the generated client. When a result arrives with no
caller waiting, it is dropped and the outbox simply re-PUTs (re-PUT is safe per the
API contract), so correctness never depends on delivering a late result.

## Consequences

- The app delegate forwards `handleEventsForBackgroundURLSession` to the uploader.
- An expired presigned URL restarts the photo from the ticket step.
- Security: unchanged trust boundaries; storage URLs are short-lived and carry no
  bearer token. The threat model lists the background session.
