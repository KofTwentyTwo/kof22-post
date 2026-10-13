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

`api.kof22.com` is live and the client is generated from it (2026-10-11; no contract changes).
Blocked on the Authentik `kof22-post-ios` provider (discovery URL 404).

- ~~`make update-spec`; fix anything the compiler flags in the app and the mock.~~ Done.
- Sign in with the real account, post to Field Notes, verify on www.kof22.com.
- Contract test: run the mock-backed suite against recorded live responses (fixtures only).

## Phase 3: Distribution and CI (in progress 2026-10-12)

- Done: Apple team UC9R3P8ZUU; App Store Connect app "KoF22 Postr" (com.kof22.post);
  Xcode Cloud workflow "Default": on changes to `main`, Archive (iOS) with TestFlight
  (Internal Testing) and the TestFlight Internal Testing post-action to the "Owner"
  group (automatic distribution). GitHub Actions runs the full gates on every push/PR.
- Open: backend `SITE_API_IOS_APP_IDS=UC9R3P8ZUU.com.kof22.post` for the AASA
  universal-link callback; remove the redundant "Build - iOS" action from the
  Xcode Cloud workflow.

## Phase 4: Upload robustness

- Background `URLSession` for the presigned PUT so photo uploads survive suspension.
- Progress per byte in the outbox.
- HEIC passthrough once the server converter is enabled (automatic via limits).

## Phase 5: Site API v2 and post metadata (in progress 2026-10-13)

Requirements M16-M24, ADR-0009, ADR-0010.

- Done: v2 client from the filtered spec; v1 client and mock removed; v2 fake for tests and
  Mock mode; client-side duplicate (adoption) and conflict (`modifyDate`) checks; every post
  field sent (name, short name, slug, description, SEO, excerpt, read time, featured, featured
  image, author, schedule); on-device suggestions with rule fallback; Details & SEO and Publish
  sections; author picker; nearby place labels; post detail shows every stored field.
- Open: live sign-in and a real post on kof22.com checked end to end (name, slug, SEO, featured
  image, gallery, author, blog), then delete it; a new 1.0.0 build for App Review.

## Later (designed for, not built)

Short video, threads/replies, place picker, Watch dictation, iPad/Mac, cross-posting, comments
moderation.
