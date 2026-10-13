# Threat model: KoF22 Post

- **Version reviewed:** 0.1.0 (unreleased) · **Last reviewed:** 2026-10-11

## 1. What the product is and does

KoF22 Post is a personal iPhone app (with a Share Extension, widgets and App
Intents) that its owner uses to publish posts and photos to kof22.com through the
KoF22 Site API v2. It signs in with the KoF22 Authentik identity provider, keeps a
local outbox of posts waiting to be sent, and can run against an in-process mock of
the API. It has access to the user's photo library (full access, on request), precise
location (when in use, on request), the camera, and an App Group container shared
with its extensions.

## 2. Actors and components

| Actor or component | Description | Trust level |
| --- | --- | --- |
| Owner | The single user, signed in with their KoF22 account | Trusted for their own data |
| App, Share Extension, widgets, App Intents | Same developer team, share an App Group and a Keychain access group | Trusted |
| Content shared into the extension | Text, URLs and images from other apps | Untrusted |
| KoF22 Site API (`api.kof22.com`) | Authoring endpoints, presigned upload URLs, link previews | Semi-trusted (TLS, owner-operated) |
| Authentik (`auth.kof22.com`) | OAuth2 authorization server | Semi-trusted (TLS, owner-operated) |
| Object storage (`s3.kof22.com`) | Receives photo uploads through presigned URLs | Semi-trusted |

## 3. Data flow and trust boundaries

```mermaid
flowchart LR
    owner([Owner]) --> app[App / Share Extension / Intents]
    other[Other apps] -- share sheet --> app
    app --> keychain[(Keychain: tokens)]
    app --> group[(App Group: outbox, photos, mock data)]
    app -- HTTPS + PKCE --> auth[(auth.kof22.com)]
    app -- HTTPS + bearer token --> api[(api.kof22.com)]
    app -- HTTPS presigned PUT --> s3[(s3.kof22.com)]
    subgraph device [Trust boundary: the owner's iPhone]
        app
        keychain
        group
    end
```

## 4. External interfaces

| Interface | Direction | Data | Authenticated? | Validated where? |
| --- | --- | --- | --- | --- |
| Authentik authorize/token/revoke | Out/In | PKCE code, tokens | Public client + PKCE; `state` checked | `OAuthClient` (state, error, missing code) |
| Site API v2 (`/v2/blogPost`, `/v2/blogTag`, `/v2/author`, `/v2/blog`, `/v2/media`, `/v2/me`, upload and link processes) | Out/In | Posts, tags, photo metadata, author and blog records | Bearer JWT (`kof22:publish`) on every request; the user's admin permissions apply | Generated client and hand-written process types decode JSON; `ErrorEnvelopeMiddleware` maps both error envelopes |
| Presigned upload URL | Out | Photo bytes (background `URLSession`, shared with the Share Extension) | Signature in URL (15 min); no bearer token | Server sniffs and sanitizes the file |
| On-device language model (Foundation Models) | In-process | Post text, tags, blog name, place label | Stays on the iPhone: only `SystemLanguageModel` is used, never Private Cloud Compute | Output is clipped to field limits and shown for review before posting |
| Diagnostics checks | Out/In | OIDC discovery, versions, one anonymous read | None | Status and `issuer` comparison only |
| Custom URL scheme `com.kof22.post://` | In | OAuth callback, `compose`/`outbox`/`posts`/`settings` routes | No | `AppModel.open(url:)` accepts only known hosts; compose text is placed in the editor, never sent automatically |
| Share Extension input | In | Text, URLs, images | No | Images copied as files; URLs must be http(s) to be previewed; nothing is sent without the owner tapping Post |
| App Intent "Post to Field Notes" | In | Text, link, photos, tags | Device unlock / Siri | `PostComposition.validationMessage` before queueing |
| Photo library, camera, location | In | Images (with metadata), place label | iOS permission prompts | GPS stripped unless the post opts in |
| Unified log (`os.Logger`) | Out | Diagnostics | n/a | No tokens or post content are logged |

## 5. Assets

- OAuth refresh and access tokens (publish rights to kof22.com).
- Unpublished drafts and queued posts, including photos.
- Photo location metadata and the owner's current location.
- The integrity of what appears on kof22.com under the owner's name.

## 6. Threats (STRIDE)

| # | Boundary / component | Category | Threat | Likelihood | Impact | Mitigation | Status |
| --- | --- | --- | --- | --- | --- | --- | --- |
| T1 | OAuth redirect | Spoofing | Another app registers `com.kof22.post://` to capture the code | Low | High | PKCE (S256) makes a stolen code useless; `state` checked; `ASWebAuthenticationSession` delivers the callback only to this app | Mitigated |
| T2 | Tokens at rest | Information disclosure | Tokens read from disk or backups | Low | High | Keychain only, `AfterFirstUnlockThisDeviceOnly`, never logged (K22-SEC-71) | Mitigated |
| T3 | Outbox retries | Tampering / integrity | A retry after a lost response publishes twice | Medium | Medium | v2 has no idempotency keys: a create adopts the post an earlier attempt made (blog, author, slug family, body); the database keeps `(slug, blogId)` unique; tests cover lost responses (ADR-0009) | Mitigated |
| T4 | Edits | Tampering | An offline edit overwrites a newer web edit | Medium | Medium | v2 has no ETags: the post's `modifyDate` is compared before every edit and delete; a mismatch becomes an explicit overwrite decision. Read-then-write leaves a window of moments | Mitigated (best effort) |
| T5 | Photos | Information disclosure | GPS location published with a photo | Medium | High | GPS removed on device unless the post opts in; server strips EXIF again | Mitigated |
| T6 | Share Extension / URL scheme | Tampering | Shared or linked content triggers a post without consent | Low | Medium | Input only pre-fills the composer; posting needs an explicit tap or a user-run Shortcut | Mitigated |
| T7 | Link preview | Information disclosure / SSRF | A link makes something fetch an internal URL | Low | Medium | The server fetches previews with its SSRF guard (public IPs only); the app never fetches arbitrary URLs itself | Mitigated (server) |
| T8 | Network | Information disclosure | Traffic interception | Low | High | HTTPS only (ATS defaults, no exceptions) | Mitigated |
| T9 | Lost device | Elevation of privilege | Someone with the unlocked phone posts | Low | Medium | Device passcode; sign-out revokes tokens; tokens can be revoked in Authentik | Accepted |
| T11 | Token scope | Information disclosure | The bearer token reaches a host other than the API | Low | Medium | v2 expects the token on every request (it also returns drafts); the client only talks to `api.kof22.com` and the presigned upload URL, which gets no token (ADR-0009, superseding ADR-0008) | Mitigated |
| T13 | Generated text | Integrity | The on-device model invents facts in a title or description that gets published | Medium | Low | Suggestions only describe the post's own text (instructions), are shown in Details & SEO for review and edit, and a typed field is never overwritten automatically (ADR-0010) | Mitigated |
| T12 | Background uploads | Information disclosure | Prepared photos linger on disk after an upload | Low | Low | Files live in the App Group container and are removed once the media ID is recorded; GPS stripped unless the photo opts in | Mitigated |
| T10 | Dependencies | Tampering | A compromised Swift package | Low | High | Exact pins and `Package.resolved`; Dependabot with cooldown; Trivy/OSV in CI | Mitigated |

## 7. Accepted risks

- T9: a person with the unlocked phone can post as the owner. Accepted by James Maes
  (single-user personal app); mitigated by revocation in Authentik.
- Mock mode stores posts and photos unencrypted (beyond iOS data protection) in the
  App Group container; it never leaves the device.

## 8. Review log

| Date | Version | Reviewer | Changes |
| --- | --- | --- | --- |
| 2026-10-11 | 0.1.0 | James Maes (with Claude Opus 5.5) | Initial model |
| 2026-10-13 | 0.2.0 | James Maes (with Claude Opus 5.5) | Site API v2 (token on every request, client-side duplicate and conflict checks), on-device suggestions |
| 2026-10-12 | 0.1.0 | James Maes (with Claude Opus 5.5) | Background uploads, anonymous reads, bearer allow-list, diagnostics, per-photo location |
