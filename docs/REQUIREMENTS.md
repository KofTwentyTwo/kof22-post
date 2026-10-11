# KoF22 Post: requirements

Status: draft for owner review (2026-10-11). Supersedes `BRIEF.md` where they differ.

## Decisions taken from the kickoff Q&A

| # | Question | Decision |
|---|----------|----------|
| 1-4 | Backend shape, idempotency/ETag, upload flow, mock | Follow the real Site API v1 in Website-Backend (`siteapi/authoring/*`, `openapi-extensions.yaml`). It already defines everything the brief expected: idempotency keys, ETag/If-Match, cursor pagination, error envelope, presigned S3 uploads. Mock = in-process implementation of that contract, used until `api.kof22.com` is live. |
| 5 | OAuth client | Use the values the backend documents: public client `kof22-post-ios`, issuer `https://auth.kof22.com/application/o/kof22-post-ios/`, redirect `com.kof22.post://oauth/callback`. Owner still to confirm the Authentik provider exists. |
| 6 | Apple team / bundle IDs | New Apple ID later. Bundle IDs `com.kof22.post` (+ `.share`, `.widgets`), App Group `group.com.kof22.post`. Team set locally in `Config/Local.xcconfig`. |
| 7 | Deployment target | iOS 27 only (Xcode 27). |
| 8 | CI | Recommendation: Xcode Cloud once the Apple ID exists (signing + TestFlight built in, 25 free hours a month). The repo is private and personal, where GitHub Actions macOS minutes count 10×. Until then `make test` locally. |
| 9 | Generator mode | Generated client committed to the repo; `make generate` regenerates. No build-plugin trust prompts in Xcode or CI. |
| 10 | Markdown preview | Textual 0.5.0 (MIT, successor of MarkdownUI). |
| 11 | Max photos | No app limit; the server's `limits.maxPhotosPerPost` (20) applies. |
| 12 | Photo processing | Upload originals. Exceptions: GPS removed unless opted in, HEIC converted to JPEG while the server refuses HEIC (415 `heic_conversion_unavailable`), re-encoded only if over the 25 MB limit. |
| 13 | Character counter | None. The server limit (10,000) is enforced at submit. |
| 14 | Drafts | Local autosave while writing; "Save as draft" sends `status: draft` to the server. |
| 15 | Location | Free-text location label in v1; photo GPS kept only with the per-post toggle. Place picker later. |
| 16 | Share Extension | Yes, with an inline composer. |
| 17 | Shortcuts/widgets | All: Post to Field Notes intent, New Field Note intent, Control (Control Center, Lock Screen, Action Button), Home/Lock Screen widget. |
| 18 | Type | SF Pro for body text (Dynamic Type), SF Mono for accents. |
| 19 | Icon | Matches the site: `$_` prompt in emerald on zinc-950 with window dots. |
| 20 | Notifications | Local notification when a queued post is published and when one fails. |

## User stories

**Must (v1)**

- M1. As James, I sign in once with my KoF22 (Authentik) account and stay signed in (silent refresh).
- M2. I see which blogs I can post to and Field Notes (`quick-bits`) is the default.
- M3. The app opens on a ready text field; I write markdown, optionally a title, and post.
- M4. I attach photos from the library or the camera, reorder them, and add alt text (with a visible prompt when it is missing).
- M5. I add tags with autocomplete from my existing tags.
- M6. I add a link and see the server's preview before posting.
- M7. I choose post now, save as draft, or schedule for later.
- M8. Posting works offline: posts queue in an outbox and send when the network returns. Retries never double-post.
- M9. The outbox shows queued, sending, failed (with reason and retry) and sent items.
- M10. I see my recent posts with status, open them on kof22.com, edit and delete them.
- M11. If an edit conflicts with a change made elsewhere, I am told and can overwrite deliberately.
- M12. I can post from the share sheet (Photos, Safari, other apps).
- M13. "Post to Field Notes" works from Shortcuts and Siri.
- M14. GPS is stripped from photos unless I opt in for that post.
- M15. Until the API is published I can use the whole app against a mock of the real contract.

**Should**

- S1. A Control and widget open the composer (Action Button via the Control).
- S2. Notifications when a queued post is published or fails.
- S3. Markdown preview while writing.
- S4. Recent posts are cached for offline viewing.
- S5. Dark terminal styling that matches kof22.com, light mode supported.

**Could**

- C1. Background URLSession uploads that continue after the app is suspended (v1 uses background task time plus background refresh).
- C2. iPad layout.
- C3. Draft sync back from the server into the composer for drafts written on the web.

## Non-goals (v1)

Video, threads and replies, place picker, Apple Watch, Mac/iPad apps, cross-posting, comment moderation, analytics of any kind, multiple accounts.

## Constraints

- Swift 6 strict concurrency, SwiftUI, iOS 27, latest Xcode.
- No secrets in the app (public PKCE client); tokens in the Keychain only.
- No third-party analytics. Dependencies are justified in `DESIGN.md`.
- Tests never hit production.
