# ADR-0001: Generate the Site API client and commit the generated code

- **Status:** Accepted
- **Date:** 2026-10-11
- **Pull request:** none (initial build on `main`, see README "Standards")

## Context

The app talks to the KoF22 Site API v1, which publishes an OpenAPI 3.0 document.
Hand-writing the client would drift from the server; the brief asked for Apple's
swift-openapi-generator. The generator can run as a SwiftPM build plugin or as a
command-line tool whose output is checked in.

## Options considered

### Option A: build plugin

- Pros: generated code never in the repository; always matches the spec file.
- Cons: Xcode asks to trust the plugin; CI needs `-skipPackagePluginValidation`;
  the spec must still be committed (the plugin cannot download it); every build
  pays for generation.

### Option B: CLI generation, output committed

- Pros: no plugin trust prompts; generated changes are visible in review; builds are
  faster; the generator version is pinned in `Tools/OpenAPIGen`.
- Cons: someone must run `make generate` after the spec changes.

## Decision

Option B. `make update-spec` downloads the live spec and regenerates, so the extra
step is one command, and spec changes show up as reviewable diffs.

## Consequences

- Generated code lives in `Packages/KoF22Kit/Sources/KoF22API/Generated` and is
  excluded from formatting, linting, coverage and warnings-as-errors by that path
  (K22-CODE-25).
- The generated schema types are used directly as domain models, so a contract change
  fails to compile wherever the app or the mock depends on it.
- No security impact; the client only talks to the configured API host.
