# KoF22 Post

Native iPhone app for posting to [kof22.com](https://kof22.com). Built for one
user, mainly for fast short-form posts to the Field Notes blog (`quick-bits`:
text, photos, links), with longer posts to the other blogs as a secondary use.

## Status

Phase 1 is done: the whole app runs against an in-process **mock of the Site API
v1 contract**, because `api.kof22.com` is not published yet. Switch to the live
API in Settings once it is. See `docs/PLAN.md`.

## Run it on your iPhone

1. `brew install xcodegen`
2. Create `Config/Local.xcconfig` with `DEVELOPMENT_TEAM = <your team id>`
   (git-ignored), then `make project`.
3. Open `KoF22Post.xcodeproj` and run the `KoF22Post` scheme on your phone.
   Xcode registers the App Group and keychain group with automatic signing.
4. Tap **Sign in (mock)**. Posts stay on the device in mock mode.

## Commands

| Command | What it does |
|---|---|
| `make project` | Regenerate `KoF22Post.xcodeproj` from `project.yml` |
| `make build` | Build for the iPhone 18 Pro simulator |
| `make test-kit` | Core unit tests (`swift test`, macOS, about 1 s) |
| `make test-ui` | XCUITests on the simulator against the mock |
| `make test` | Both |
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
docs/             brief, requirements, design, plan
```

## Secrets

None are committed. OAuth uses the public native client `kof22-post-ios` with
PKCE, so there is no client secret. Your team ID lives only in the git-ignored
`Config/Local.xcconfig`.
