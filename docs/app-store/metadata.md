# App Store submission: KoF22 Postr

Everything App Store Connect asks for, ready to paste. App Store Connect app ID
`6821970291`, bundle ID `com.kof22.post`, team `UC9R3P8ZUU`. Character limits are
Apple's; every text below fits.

## Recommended distribution

**Unlisted App Distribution.** KoF22 Postr publishes to one website for its owner.
App Review often rejects single-purpose personal tools on the public store under
guideline 4.2 (minimum functionality). An unlisted app goes through the same review but
is only reachable by direct link. Request it at
<https://developer.apple.com/contact/request/unlisted-app/> (give the app ID above), then
submit normally. TestFlight keeps working either way.

## App information

| Field | Value |
| --- | --- |
| Name (30) | `KoF22 Postr` |
| Subtitle (30) | `Quick posts for kof22.com` |
| Primary category | Social Networking |
| Secondary category | Productivity |
| Content rights | Does not contain, show, or access third-party content |
| Age rating | 4+ (answer "None" / "No" to every questionnaire item; see below) |
| Privacy policy URL | `https://github.com/KofTwentyTwo/kof22-post/blob/main/docs/privacy-policy.md` |
| Support URL | `https://github.com/KofTwentyTwo/kof22-post/blob/main/docs/support.md` |
| Marketing URL | `https://www.kof22.com` |
| Copyright | `2026 James Maes` |
| Version | `1.0.0` (`MARKETING_VERSION`); build numbers come from Xcode Cloud |

## Version 1.0.0 text

**Promotional text (170)**

```text
Write a quick post, add photos and a link, and publish to kof22.com from anywhere. Offline? It waits in the outbox and sends itself when you are back online.
```

**Description (4000)**

```text
KoF22 Postr is the posting app for kof22.com. It is built for fast, short posts to the Field Notes blog: a thought, a few photos, a link, done.

WRITE FAST
- Opens straight to a ready text field
- Markdown with a live preview
- Choose the blog, add tags with autocomplete, a link with a server-side preview, and a place name
- Post now, save a draft, or schedule for later

PHOTOS DONE RIGHT
- Pick several photos, reorder them, and add alt text for accessibility
- Location is removed from photos on your device unless you turn it on for a photo
- Uploads continue in the background, even when you leave the app

WORKS OFFLINE
- Everything goes through an outbox: write on a plane, it sends when you land
- Retries never post twice; edits made elsewhere are detected before anything is overwritten

POST FROM ANYWHERE
- Share sheet: post from Photos, Safari and other apps
- Shortcuts and Siri: "Post to Field Notes"
- Control Center, Lock Screen and Action Button: start a new post in one tap
- Home and Lock Screen widget

YOUR POSTS
- See your recent posts with their status, edit or delete them, and open them on kof22.com
- Browse what is published on kof22.com

PRIVATE BY DESIGN
- No analytics, no ads, no tracking
- Sign-in tokens stay in the iOS Keychain
- Mock mode lets you try everything without an account; nothing leaves your device

Publishing requires a KoF22 account with publish rights.
```

**Keywords (100)**

```text
blog,post,microblog,markdown,photos,publish,notes,writing,offline,share,shortcuts,kof22
```

**What's New (4000)**

```text
First release.
```

## Screenshots

App Store Connect asks for the "iPhone with Dynamic Island (medium display)" set: 6.3"
(1206 x 2622), in `docs/app-store/screenshots/iphone-6.3/`. A 6.9" set (1320 x 2868) is in
`docs/app-store/screenshots/iphone-6.9/` for the large-display slot. The app is
iPhone-only, so no iPad screenshots are needed. Upload in this order:

1. `2-compose.png`: writing a post
2. `3-preview.png`: Markdown preview
3. `4-outbox.png`: the outbox, sent and queued posts
4. `5-posts.png`: your posts with status
5. `6-detail.png`: a post, with edit, share and open on kof22.com
6. `7-site.png`: published posts on kof22.com
7. `1-sign-in.png`: sign-in (mock or kof22.com)
8. `8-settings.png`: settings and privacy

Regenerate them with the `ScreenshotTests` UI test on the iPhone 18 Pro (6.3") and
iPhone 18 Pro Max (6.9") simulators in dark mode (`xcrun simctl ui <device> appearance dark`, status bar overridden to 9:41),
then export the attachments from the result bundle.

## App Review information

| Field | Value |
| --- | --- |
| Sign-in required | No for review: the app opens in Mock mode |
| Demo account | Not needed (see notes) |
| Contact | James Maes, email and phone of the account holder |

**Notes (4000)**

```text
KoF22 Postr is the publishing app for the owner's website, kof22.com.

How to review without an account:
1. Launch the app. It starts in "Mock API" mode (selected at the bottom of the sign-in screen).
2. Tap "Sign in (mock)". The mock runs the real API contract on the device; nothing is sent to any server.
3. Write a post and tap Post. It appears in the Outbox, then under Posts. The globe button on Posts shows published posts.
4. Settings > Mock tools > "Simulate offline" demonstrates the offline outbox.

Live mode ("api.kof22.com") signs in with the owner's KoF22 account (OAuth with PKCE) and publishes to kof22.com, so it needs an account with publish rights.

Permissions: Photos (attach originals, optional), Camera (optional), Location when in use (optional place name), Notifications (post published or failed). The app has no analytics, advertising or tracking.
```

## App Privacy ("nutrition label")

Matches `App/PrivacyInfo.xcprivacy`. Data is collected only when the user publishes to
kof22.com. None of it is used for tracking.

| Data type | Collected | Linked to user | Used for tracking | Purpose |
| --- | --- | --- | --- | --- |
| Contact info: Email address | Yes | Yes | No | App functionality (account identity) |
| Identifiers: User ID | Yes | Yes | No | App functionality |
| User content: Photos or videos | Yes | Yes | No | App functionality (published photos) |
| User content: Other user content | Yes | Yes | No | App functionality (posts) |
| Location: Precise location | Yes, only when the user keeps a photo's location | Yes | No | App functionality |

Everything else (health, financial, contacts, browsing, search, usage data, diagnostics,
purchases, sensitive info): **not collected**.

## Age rating questionnaire

Answer **None** to every content description (violence, profanity, mature themes,
gambling, horror, medical, alcohol and drugs, sexual content, contests). Answer **No** to:
unrestricted web access (links open in Safari), user-generated content shared with other
users of the app, messaging, and in-app purchases. Result: 4+.

## Export compliance

The app uses only Apple's standard HTTPS. `ITSAppUsesNonExemptEncryption` is `NO` in
`Info.plist`, so App Store Connect does not ask.

## Pricing and availability

Free, all territories (or only where you want it). No in-app purchases.

## Already done in the build

- App icon: 1024 px opaque, plus dark and tinted variants (`scripts/make-icon.swift`).
- Privacy manifests for the app, Share Extension and widgets.
- All four interface orientations (ITMS-90474).
- Usage descriptions for Photos, Camera and Location.
- Privacy policy and support links in Settings.
- Version 1.0.0 shared by the app and both extensions.
- Signing: Xcode Cloud cloud-managed App Store distribution; no local profiles needed.
- iPhone only (`TARGETED_DEVICE_FAMILY` 1 on every target).

## Build for submission

A build archived with "TestFlight (Internal Testing Only)" cannot be attached to an App
Store version (App Store Connect: "The specified pre-release build could not be added").
The Xcode Cloud workflow's Archive action must use the distribution preparation
"TestFlight and App Store". Then pick that build under the version's Build section.
- Zero build warnings; tests and coverage gates green.
