# ADR-0002: Develop against an in-process mock of the Site API contract

- **Status:** Accepted
- **Date:** 2026-10-11
- **Pull request:** none (initial build on `main`)

## Context

`api.kof22.com` did not exist when the app was started, and the owner asked for the
app to be usable against a mock until it did. Tests must never hit production
(K22-TEST-20). The backend already defined the v1 authoring contract.

## Options considered

### Option A: external mock server (Prism or similar)

- Pros: exercises real networking.
- Cons: another process to run on the phone's network; extra tooling; nothing to
  test offline behaviour with.

### Option B: in-process mock behind the generated client's transport

- Pros: runs on the phone with no setup; the same code path (generated client,
  middlewares) is used in mock and live mode; tests are hermetic and fast; offline can
  be simulated.
- Cons: the mock must be kept faithful to the server's behaviour by hand.

## Decision

Option B: `MockBackend` implements the documented v1 rules on the generated types and
plugs in through `MockTransport`; the app has a Mock/Live switch.

## Consequences

- Mock fidelity is enforced by the compiler (generated types) and by the contract
  tests; when the live spec changes, the mock is updated in the same change.
- Mock data stays on the device in the App Group container.
- Live behaviour that the mock cannot reproduce (Authentik sign-in, presigned S3
  uploads) is verified manually until a staging API exists.
