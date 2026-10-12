# Standards conformance

KoF22 Post adopts the [KofTwentyTwo standards](https://github.com/KofTwentyTwo/standards)
**v1.0.0** (commit `7c69368`) at the **Internal** tier: every MUST in `SEC` and `AI`
plus `K22-REPO-01`–`05` is mandatory, the rest is SHOULD. The owner asked for the full
standards, so SHOULD items are implemented too unless listed below.

The repository is public since 2026-10-12 (owner decision, so CI gets GitHub-hosted
macOS runners without the private-repository minute multiplier). It has no releases
yet; it moves to the Product tier before its first public release, which brings the
OpenSSF Best Practices badge (K22-REPO-12) and Scorecard (K22-CI-24, K22-REPO-11).

Last reviewed: 2026-10-11, by James Maes with Claude Opus 5.5. Checked with
`tools/Test-RepoConformance.ps1` from the standards repository and the local gates.

## How it is enforced here

| Area | Requirements | Where |
| --- | --- | --- |
| Formatting | K22-CODE-03, -07, K22-CODE-SW-01 | `.swift-format`, `.editorconfig`, `.gitattributes`; `make format-check` in CI and pre-commit |
| Lint | K22-CODE-SW-03, -09, -12, -19 | `.swiftlint.yml` with `--strict`; `make lint` in CI and pre-commit |
| Warnings as errors | K22-CODE-02, K22-CODE-SW-04 | `project.yml` and `Package.swift` (`strictSettings`); generated client excluded by target |
| Header comments, flower boxes, license headers | K22-CODE-09, -10, -24 | Every hand-written Swift file |
| Errors and logging | K22-CODE-19, -20 | `Log` (os.Logger); remaining `try?` carry a comment saying why |
| Tests and coverage | K22-TEST-01, -02, -10, -20, -22, -24 | `make test`, `make coverage` (100% lines of `Sources/KoF22Kit`), `KOF22_DATA_DIR` override for tests |
| Secrets | K22-REPO-04, K22-CI-20 | gitleaks in pre-commit and CI; reviewed false positive in `.gitleaksignore` |
| Dependencies | K22-REPO-09, K22-DEP-01, -11, -20 | `Package.resolved` committed, exact/tight pins, Dependabot with cooldown, ADR-0004 |
| CI | K22-CI-01–23 | `.github/workflows/` (pr-gates, security, codeql via the standards' reusable workflows pinned by SHA; ci for Swift) |
| Decisions and threat model | K22-SDLC-02, -03 | `docs/adr/`, `docs/security/threat-model.md` |
| Repository files | K22-REPO-01–08 | `LICENSE`, `README.md`, `SECURITY.md`, `CONTRIBUTING.md`, `.github/CODEOWNERS` |
| AI provenance | K22-AI-02, K22-AGENT-40 | Commits signed (`-S`), signed off (`-s`) and carry `Co-Authored-By` for AI-assisted work |

## Owner-approved deviations

| Requirement | Deviation | Decision | Ends |
| --- | --- | --- | --- |
| K22-AI-10, K22-SDLC-10, -12, -16 | Work is committed directly to `main` (locally) instead of topic branches and pull requests; `no-commit-to-branch` is not in the pre-commit hooks | James Maes, 2026-10-11 | At the first published version; then GitHub Flow with pull requests |
| K22-REPO-20, -21 (rulesets) | `protect-main` is not enabled yet because it would block the agreed direct work on `main` | Follows from the row above | Same |

These rows are not in the standards' exception register yet. A Product-tier move or an
audit needs them recorded there (`K22-AGENT-04`).

## Open items

| Requirement | Item | Who |
| --- | --- | --- |
| K22-REPO-22, -30, -31, -32, -40, -41 | GitHub settings: squash-only merging with PR title/body, delete head branches, Dependabot alerts and security updates, secret scanning with push protection, private vulnerability reporting, immutable releases, read-only `GITHUB_TOKEN`, Actions cannot approve PRs, allowed actions restricted, wiki off, description/topics | Owner (repository settings are reserved to a person, K22-AI-10) |
| K22-REPO-42 | List `kof22-post` in `MAINTAINERS.md` of KofTwentyTwo/standards | Owner, via a pull request to the standards repository |
| K22-SEC-60 | Off-GitHub backup: confirm the weekly backup includes this repository now that it is on GitHub | Owner |
| K22-CI-01 (runner) | `ci.yml` and `codeql.yml` run on the `xcode-27` runner image (a GitHub preview image); move to the GA label when it ships | First CI run |
| Upstream | Two fixes to the standards' Swift configuration: SwiftLint `unused_declaration`/`unused_import` belong in `analyzer_rules`, and `statement_position` needs `uncuddled_else` to agree with swift-format | Owner, issue or PR to KofTwentyTwo/standards |

## Narrow suppressions

Each is one line, with the reason in a comment next to it (K22-CODE-02):

- `typealias Me` and `AppModel.me` (`identifier_name`, `type_name`): names fixed by the
  API schema and used across the app.
- `Log.ui` (`identifier_name`): the conventional category name.
- `makeMockService` in tests (`large_tuple`): a test helper used by many suites.

## Review

Re-run `pwsh <standards>/tools/Test-RepoConformance.ps1 -Repository KofTwentyTwo/kof22-post -LocalPath .`
and the local gates before the first published version and at least every six months.
