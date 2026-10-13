# KoF22 Postr

KoF22 Postr is a native iPhone app for posting to [kof22.com](https://kof22.com). Built for one
user, mainly for fast short-form posts to the Field Notes blog (`quick-bits`:
text, photos, links), with longer posts to the other blogs as a secondary use.

[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/KofTwentyTwo/kof22-post/badge)](https://scorecard.dev/viewer/?uri=github.com/KofTwentyTwo/kof22-post)

**Tier:** Internal ([scope](https://github.com/KofTwentyTwo/standards/blob/main/policies/README.md#scope)).
**Standards:** adopting [KofTwentyTwo standards](https://github.com/KofTwentyTwo/standards)
v1.0.0. Conformance status, open items and owner-approved deviations are in
[docs/standards-conformance.md](docs/standards-conformance.md).
See [SECURITY.md](SECURITY.md) to report a vulnerability and
[CONTRIBUTING.md](CONTRIBUTING.md) for how changes are made.

## Status

The app talks to KoF22 Site API v2 at `api.kof22.com` (client generated from the live spec,
filtered to the operations the app uses). Mock mode runs an in-process fake of the same
operations, used by App Review and the tests. See `docs/PLAN.md`.

## Install

Builds reach the owner's iPhone through **TestFlight**: Xcode Cloud archives `main`
with cloud signing and uploads to App Store Connect (app "KoF22 Postr"), and the
TestFlight app installs it. `ci_scripts/ci_post_clone.sh` prepares the Xcode Cloud
build. You can also build from source onto a connected iPhone (below).

App Store submission: metadata, screenshots, privacy answers and review notes are in
[docs/app-store/metadata.md](docs/app-store/metadata.md); the
[privacy policy](docs/privacy-policy.md) and [support page](docs/support.md) are the
URLs App Store Connect links to.

## Usage

1. Open **KoF22 Post** and sign in (**Sign in (mock)** in mock mode, or **Sign in with
   KoF22** against `api.kof22.com`).
2. Write in the composer (Markdown works), choose the blog, add photos with alt text,
   tags, a link or your current location, then **Post**, **Save as draft** or
   **Schedule**.
3. Queued posts wait in the **Outbox** until they are sent; **Posts** lists your posts
   with edit, delete and open on kof22.com.
4. Share from Photos or Safari with the **KoF22 Post** share extension, or use the
   **Post to Field Notes** Shortcut, the Control or the widget.

## Build from source

Toolchain: macOS with Xcode 27 (Swift 6.4, iOS 27 SDK), XcodeGen, SwiftLint.
Dependencies are Swift packages resolved by Xcode from `Packages/KoF22Kit/Package.resolved`.

1. `brew install xcodegen swiftlint pre-commit gitleaks`
2. `make project`. The Apple Developer team (UC9R3P8ZUU) is set in
   `Config/Base.xcconfig`; to sign with another team, put `DEVELOPMENT_TEAM = <id>` in
   `Config/Local.xcconfig` (git-ignored).
3. Open `KoF22Post.xcodeproj` and run the `KoF22Post` scheme on your phone, or
   `make build` for the simulator.
4. `pre-commit install --hook-type pre-commit --hook-type commit-msg` once per clone.

## Commands

| Command | What it does |
|---|---|
| `make project` | Regenerate `KoF22Post.xcodeproj` from `project.yml` |
| `make build` | Build for the iPhone 18 Pro simulator |
| `make test-kit` | Core unit tests (`swift test`, macOS, about 1 s) |
| `make test-ui` | XCUITests on the simulator against the mock |
| `make test` | Both |
| `make coverage` | Unit tests plus the 100% line-coverage gate on KoF22Kit |
| `make format` / `make format-check` | swift-format rewrite / check |
| `make lint` | SwiftLint `--strict` |
| `make build-ci` | Unsigned simulator build used by CI and CodeQL |
| `make generate` | Regenerate the API client from `openapi/openapi.yaml` |
| `make update-spec` | Download the live spec from api.kof22.com and regenerate |

## Repository layout

```
App/              app target (entry point, App Intents)
ShareExtension/   share sheet composer
Widgets/          Control and widget
Shared/           code compiled into app and widget (OpenComposeIntent)
Packages/KoF22Kit KoF22API (generated client), KoF22Kit (core), KoF22UI (screens)
openapi/          pinned Site API spec + generator config
scripts/          spec assembly/update, icon renderer
Tools/OpenAPIGen  pins the swift-openapi-generator CLI
UITests/          XCUITests
Config/           shared xcconfig (Local.xcconfig for your team is git-ignored)
.github/          CI workflows, Dependabot, CODEOWNERS, PR template
docs/             brief, requirements, design, plan, standards conformance
docs/adr/         architecture decision records
docs/security/    threat model, assurance record
```

## Secrets

None are committed. OAuth uses the public native client `kof22-post-ios` with
PKCE, so there is no client secret. Your team ID lives only in the git-ignored
`Config/Local.xcconfig`.
