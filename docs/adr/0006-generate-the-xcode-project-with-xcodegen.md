# ADR-0006: Generate the Xcode project with XcodeGen

- **Status:** Accepted
- **Date:** 2026-10-11
- **Pull request:** none (initial build on `main`)

## Context

The app has four targets (app, Share Extension, widgets, UI tests) with entitlements,
Info.plist keys and a local package. Hand-edited `project.pbxproj` files are hard to
review and merge.

## Options considered

### Option A: hand-maintained Xcode project

- Pros: no tool.
- Cons: unreviewable diffs; settings drift between targets.

### Option B: XcodeGen from `project.yml`, generated project committed

- Pros: the project is described in a short, reviewable YAML file; Xcode Cloud and
  a fresh clone open the committed project without installing anything.
- Cons: contributors must run `make project` after editing `project.yml`.

## Decision

Option B. XcodeGen is a build-only tool and does not ship in the app.

## Consequences

- `project.yml` is the source of truth; never edit `KoF22Post.xcodeproj` by hand.
