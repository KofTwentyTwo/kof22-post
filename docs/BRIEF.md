# Project brief: KoF22 Post

Native iPhone app for posting to kof22.com. Captured verbatim from the kickoff
brief on 2026-10-11. This is the source of truth for scope until
REQUIREMENTS.md and DESIGN.md supersede it.

---

You are the lead iOS engineer and product designer for a personal iPhone app I'll use to post to my website, kof22.com. The main use is the short-form "quick things" blog (Field Notes, slug quick-bits): fast, Twitter/Instagram-style posts with text, photos and links. Longer posts on my other blogs are a secondary use. I'm developing on my Mac with Xcode and will run it on my own iPhone first.

## How I want you to work

Do NOT write code yet. First read this brief, then ask me your clarifying questions in one batch (multiple choice where possible, with your recommendation first).
Then write docs/REQUIREMENTS.md (user stories, must/should/could, non-goals) and docs/DESIGN.md (architecture, data flow, screens, offline/sync model, auth, error handling, testing). Wait for my approval.
Then produce a phased plan (docs/PLAN.md) where each phase ends with something I can run on my phone, and build phase by phase. Small commits, tests with every phase.

## Backend (already exists / in progress — don't invent it)

Public, versioned API at https://api.kof22.com/v1. OpenAPI 3 spec at https://api.kof22.com/v1/openapi.json (also .yaml), docs at https://api.kof22.com/, available versions at versions.json. Path major version (/v1) plus semver in info.version.
Reads are anonymous. Writes need an OAuth2 bearer token from my Authentik instance (https://auth.kof22.com), using Authorization Code + PKCE with a public native client. Scopes: openid profile email offline_access kof22:publish. Refresh tokens are supported (short access, long refresh).
Authoring endpoints: create/update/delete quick posts (markdown body, optional title, tags, blog, status draft|published|scheduled, publishAt, optional location label, link URL with a server-side link preview); multi-photo upload (HEIC/JPEG/PNG; the server converts formats, makes sizes, and strips EXIF GPS by default; alt text; ordering); tags autocomplete; me (who am I, which blogs I can post to); my recent posts with status. Expect idempotency keys on creates, ETag/If-Match on updates, cursor pagination, and a consistent JSON error envelope (401/403/409/413/422/429).
I'll paste an "iOS client contract" with the exact client_id, redirect URIs, endpoint list and upload flow when you ask. Until then, generate the client from the live OpenAPI spec and don't hard-code guesses.

## Technical direction (push back if you disagree)

Latest stable Xcode, Swift 6 with strict concurrency, SwiftUI, deployment target on the current iOS major (ask me).
API client generated with Apple's swift-openapi-generator (build plugin) from the spec, with a thin hand-written layer on top for auth, retries and idempotency.
Auth: ASWebAuthenticationSession + PKCE, tokens in the Keychain, silent refresh, sign-out with token revocation. No secrets in the app.
Local persistence with SwiftData: drafts, an outbox queue for posts and uploads, cached recent posts.
Offline-first posting: compose anywhere, queue, and sync when online. Background uploads via a background URLSession that survives app suspension. Idempotency keys so retries never double-post.
Media: PhotosPicker for multi-select and camera capture; on-device downscale before upload; strip location from EXIF on device as well unless I opt in per post; alt text prompt.
Share Extension so I can post from Photos, Safari and other apps (shares the Keychain and SwiftData store through an App Group).
App Intents and Shortcuts ("Post to Field Notes"), plus a Home Screen / Lock Screen widget or Control for quick compose. Siri and Action Button through those intents.
Accessibility (Dynamic Type, VoiceOver), light and dark mode. Visual style should echo kof22.com: dark terminal look, monospace accents, green prompt cursor.
Swift Testing for unit tests, XCUITest for the main flows, and a mock API server or recorded fixtures so tests don't hit production.
No third-party analytics or tracking. Minimal dependencies; justify each one.

## Core features (v1)

Sign in with my KoF22 account. Show which blogs I can post to.
Fast compose: open to a ready text field, character count, markdown preview, tags with autocomplete, up to N photos with reorder and alt text, link with preview, choose blog (default Field Notes), post now / save draft / schedule.
Outbox showing queued, uploading, failed (with retry) and posted items.
My recent posts with status; edit and delete; open on kof22.com.
Share Extension and the "Post to Field Notes" Shortcut.

## Later (design for, don't build in v1)

Short video, threads/replies, location tagging with a place picker, Apple Watch dictation quick post, iPad/Mac Catalyst, cross-posting to other networks, comments moderation.

## Distribution and repo

Personal use first: run from Xcode on my device, then TestFlight. Ask me for the Apple Developer team and bundle ID prefix (I'd suggest com.kof22.post). The OAuth redirect scheme must match what the backend registers (expected com.kof22.post://oauth/callback).
Git repo with a README, a CLAUDE.md for future sessions, and CI (ask me whether to use Xcode Cloud, GitHub Actions or CircleCI; my other projects use CircleCI).
Commit as me and keep secrets out of the repo.

## Start now

Fetch and read https://api.kof22.com/v1/openapi.json if it is reachable (tell me if it isn't yet), then send me your clarifying questions.
