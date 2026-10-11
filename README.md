# KoF22 Post

Native iPhone app for posting to [kof22.com](https://kof22.com). Built for one
user, mainly for fast short-form posts to the Field Notes blog (text, photos,
links), with longer posts to the other blogs as a secondary use.

## Status

Pre-code. The kickoff brief is in `docs/BRIEF.md`. Next steps, in order:

1. Clarifying questions and answers.
2. `docs/REQUIREMENTS.md` and `docs/DESIGN.md`, approved by the owner.
3. `docs/PLAN.md`, then phase-by-phase build where every phase runs on a phone.

## Stack (intended)

- Swift 6, strict concurrency, SwiftUI, latest stable Xcode.
- API client generated from the live OpenAPI spec at
  `https://api.kof22.com/v1/openapi.json` with swift-openapi-generator.
- OAuth2 Authorization Code + PKCE against Authentik, tokens in the Keychain.
- SwiftData for drafts, outbox and cached posts. Offline-first with background
  uploads and idempotency keys.
- Share Extension, App Intents / Shortcuts, widget or Control for quick compose.
- Swift Testing and XCUITest with a mock server or recorded fixtures.
- No analytics, no tracking, minimal dependencies.

## Repository layout

```
docs/   brief, requirements, design, plan
```

The Xcode project will live at the repo root once created.

## Secrets

None are committed. OAuth uses a public native client with PKCE, so the app
needs no client secret. Signing and TestFlight credentials stay in Xcode and
the CI secret store.
