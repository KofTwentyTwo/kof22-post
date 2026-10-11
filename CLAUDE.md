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
- Do not invent backend behaviour. Generate the API client from the live
  OpenAPI spec at `https://api.kof22.com/v1/openapi.json`. If the spec is not
  reachable, say so and stop rather than guessing endpoints.
- Push back on technical direction when there is a concrete reason, then
  follow the owner's decision.

## Technical constraints

- Swift 6 with strict concurrency, SwiftUI, latest stable Xcode.
- Deployment target: ask the owner (current iOS major).
- Dependencies: swift-openapi-generator and its runtime/transport are
  expected. Anything else needs a written justification in `docs/DESIGN.md`.
- No third-party analytics or tracking.
- Tests must not hit production. Use a mock server or recorded fixtures.

## Open decisions (ask the owner, do not assume)

- Apple Developer team and bundle ID prefix (suggested `com.kof22.post`).
- OAuth redirect URI (expected `com.kof22.post://oauth/callback`) and the
  exact client_id from the iOS client contract.
- CI provider: Xcode Cloud, GitHub Actions or CircleCI (other projects use
  CircleCI).
- Maximum photos per post.

## Build and test

Not yet applicable. Update this section when the Xcode project exists with
the exact `xcodebuild` commands CI uses.
