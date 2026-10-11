# CLAUDE.md

Guidance for agent sessions in this repository.

## What this is

KoF22 Post: a personal native iPhone app for posting to kof22.com. The owner
is James Maes. Read `docs/BRIEF.md` first. When `docs/REQUIREMENTS.md`,
`docs/DESIGN.md` and `docs/PLAN.md` exist they take precedence over the brief.

## Working agreement

- Follow the phase order in the brief: questions, requirements and design
  (wait for approval), plan, then build phase by phase.
- Every phase ends with something that runs on a real iPhone.
- Small commits, conventional commit messages, tests with every phase.
- Commit as the repo owner. No AI attribution trailers.
- Never commit secrets, signing assets, or tokens. The OAuth client is public
  (PKCE), so there is no client secret to begin with.
- Do not invent backend behaviour. The contract is the KoF22 Site API v1 in
  Website-Backend (`siteapi/`, `src/main/resources/site-api/openapi-extensions.yaml`).
  Until `https://api.kof22.com/v1/openapi.yaml` is reachable, `openapi/openapi.yaml`
  is assembled from that fragment (`scripts/assemble-spec.sh`, owner-approved
  2026-10-11). When the live spec responds, run `make update-spec` and make the
  mock (`Packages/KoF22Kit/Sources/KoF22Kit/Mock`) follow any change.
- Push back on technical direction when there is a concrete reason, then
  follow the owner's decision.

## Technical constraints

- Swift 6 with strict concurrency, SwiftUI, latest stable Xcode.
- Deployment target: iOS 27 only (owner decision, 2026-10-11).
- Dependencies: swift-openapi-generator and its runtime/transport are
  expected. Anything else needs a written justification in `docs/DESIGN.md`.
- No third-party analytics or tracking.
- Tests must not hit production. Use a mock server or recorded fixtures.

## Open decisions (ask the owner, do not assume)

- Apple Developer team: a new Apple ID will be created before release. Bundle
  IDs are `com.kof22.post`, `.share`, `.widgets`; App Group `group.com.kof22.post`.
- Authentik provider `kof22-post-ios` (redirect `com.kof22.post://oauth/callback`)
  is documented by the backend but not yet confirmed to exist.
- CI provider: Xcode Cloud recommended (see `docs/REQUIREMENTS.md`), not set up.

Settled decisions are in the table at the top of `docs/REQUIREMENTS.md`.

## Build and test

- `project.yml` is the source of truth; run `make project` (XcodeGen) after
  adding files or targets. The generated `KoF22Post.xcodeproj` is committed.
- `make test-kit`: `cd Packages/KoF22Kit && swift test` (macOS, no simulator).
- `make test-ui`: `xcodebuild -project KoF22Post.xcodeproj -scheme KoF22Post
  -skipPackagePluginValidation -destination 'platform=iOS Simulator,name=iPhone 18 Pro'
  -only-testing:KoF22PostUITests test`. The app runs with `-uitest`: fresh mock,
  in-memory store.
- `make generate` regenerates `Packages/KoF22Kit/Sources/KoF22API/Generated`
  (committed) from `openapi/openapi.yaml`. Never edit generated files.
- UI code in KoF22UI is wrapped in `#if os(iOS)` so the package still builds
  and tests on macOS.
