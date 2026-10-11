# KoF22 Post: plan

Each phase ends with something that runs on the iPhone (Mock mode until `api.kof22.com` is live).

## Phase 1: Working app on the mock API (done 2026-10-11)

- Site API client generated from the backend's v1 contract; mock backend implementing it.
- Auth (PKCE, Keychain, refresh, revoke), with mock sign-in.
- Compose with photos, alt text, reorder, tags, link preview, markdown preview, blog choice,
  post / draft / schedule.
- Outbox with idempotent retries, offline queueing, conflict handling, notifications.
- My posts: list, filter, detail, edit, delete, open on kof22.com.
- Share Extension, Post to Field Notes and New Field Note intents, Control, widget.
- Tests: 47 Swift Testing unit tests, 5 XCUITests.

**Try it:** set your team in `Config/Local.xcconfig`, `make project`, run on the phone, "Sign in (mock)".

## Phase 2: Live API

Blocked on `api.kof22.com` DNS/ingress and the Authentik `kof22-post-ios` provider.

- `make update-spec`; fix anything the compiler flags in the app and the mock.
- Sign in with the real account, post to Field Notes, verify on www.kof22.com.
- Contract test: run the mock-backed suite against recorded live responses (fixtures only).

## Phase 3: Distribution and CI

- New Apple ID / team, App Group and keychain group registered, TestFlight build.
- Xcode Cloud workflow running `make test-kit` + UI tests on PRs; archive to TestFlight on `main`.
- Backend: `SITE_API_IOS_APP_IDS` for the AASA universal-link callback.

## Phase 4: Upload robustness

- Background `URLSession` for the presigned PUT so photo uploads survive suspension.
- Progress per byte in the outbox.
- HEIC passthrough once the server converter is enabled (automatic via limits).

## Later (designed for, not built)

Short video, threads/replies, place picker, Watch dictation, iPad/Mac, cross-posting, comments
moderation.
