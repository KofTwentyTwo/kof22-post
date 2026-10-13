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

## Post metadata and publishing controls (v1.1, draft 2026-10-12)

Status: in build (2026-10-13) on Site API v2, which exposes every post field (ADR-0009). The owner
decided v2 only: the v1 client and mock are removed.

**Must**

- M16. Every post gets a good name, short name, title and description, suggested on the
  device and editable before posting. Lengths follow the contract; SEO targets are
  title at most 60 characters and description at most 160.
- M17. The slug is generated in code from the title: ASCII, lower case, words joined by
  hyphens, no leading or trailing hyphen, at most 80 characters (the backend's
  `slugify` rule). It is editable; the server keeps it unique.
- M18. SEO fields (meta title, meta description, meta keywords) are filled and editable.
- M19. All photos are attached to the post in order, the featured image is set (first
  photo unless I choose another), and alt text is suggested for each photo.
- M20. Blog, author and media agree: the composer shows the blog and "Posting as" the
  author, and the post detail shows what the server stored.
- M21. Publishing is explicit: Draft, Publish now (as soon as uploaded) or Schedule with
  a date and time for the publish-at field. An "is featured" toggle is visible.
- M22. Location is better populated: a richer label from the nearest place and the town
  ("Smith's Diner, Chester, IL"), with nearby alternatives to pick (owner, 2026-10-13). v2 has no
  coordinate fields on a post.
- M24. The author is shown ("Posting as") and can be chosen from the authors the account may see,
  defaulting to the account's own author (owner, 2026-10-13).
- M23. Suggestions come from the on-device model (Apple Foundation Models); no post
  content leaves the phone for them. Without Apple Intelligence the fields fall back
  to rules (first sentence, trimmed body, tags as keywords).

**Decided**

- Read time stays a word count (server-side, shown live in the composer), not a model
  output: counting is exact in code and unreliable in a language model. Owner may
  revisit.

**Answers (2026-10-13)**

1. Location: richer label (above).
2. Author: picker, default the account's author (above).
3. Site: a blog belongs to a site (`blog.siteId`); uploaded media belong to the public site and the
   server refuses a featured image from another site, so blog, site and media agree.
4. Phone model: not confirmed; without Apple Intelligence the rules fill the same fields (ADR-0010).

## Non-goals (v1)

Video, threads and replies, place picker, Apple Watch, Mac/iPad apps, cross-posting, comment moderation, analytics of any kind, multiple accounts.

## Constraints

- Swift 6 strict concurrency, SwiftUI, iOS 27, latest Xcode.
- No secrets in the app (public PKCE client); tokens in the Keychain only.
- No third-party analytics. Dependencies are justified in `DESIGN.md`.
- Tests never hit production.
