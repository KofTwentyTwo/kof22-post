# Contributing to KoF22 Post

Use professional wording in code comments, documentation, commit/PR messages,
release notes and automation output. No emojis, joke copy or bot sound effects.

This project follows the
[KofTwentyTwo standards](https://github.com/KofTwentyTwo/standards) v1.0.0; this page
is the short version of what they ask of a contribution. KoF22 Post is a personal app
and does not accept outside contributions; this guide is for the maintainer and the
AI agents working with him.

## Setup

Prerequisites: macOS with Xcode 27 (Swift 6.4, iOS 27 SDK and simulator), plus
`brew install xcodegen swiftlint pre-commit gitleaks`.

```sh
make project        # generate KoF22Post.xcodeproj from project.yml
make build          # build the app for the iPhone 18 Pro simulator
make test-kit       # unit tests (swift test, macOS, no simulator)
make coverage       # unit tests plus the 100% line-coverage gate on KoF22Kit
make test-ui        # XCUITests against the in-process mock API
make format         # rewrite Swift files with swift-format
make format-check   # fail on unformatted Swift files
make lint           # SwiftLint --strict
```

These are the same commands CI runs (`.github/workflows/ci.yml`).

Install the git hooks once per clone. They run the same secret, workflow, format,
lint and commit-message checks CI does:

```sh
pre-commit install --hook-type pre-commit --hook-type commit-msg
```

## Workflow

Until the first published version, work happens directly on `main` (owner decision,
2026-10-11; see the README). After that, the standard GitHub Flow applies:

1. Branch from `main` with a short-lived topic branch named `<type>/<short-description>`,
   for example `feat/export-csv` or `fix/42-crash-on-empty-folder`.
2. Commit with [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/)
   (`feat: ...`, `fix(scope): ...`). Every commit is **signed** and **signed off**:
   `git commit -S -s` (see *Sign-off* below).
3. Open a pull request against `main`. Its title must itself be a Conventional Commit
   header: pull requests are **squash-merged**, so the title becomes the commit
   message on `main`.
4. Every required check must pass, and every review thread must be resolved, before
   the pull request merges.

## What makes a contribution acceptable

- The build has **zero warnings** (warnings are errors), and `make format-check` and
  `make lint` are clean.
- Every type and function has a `///` header comment; comments inside bodies use the
  flower-box shape (Kingsrook style, see the standards' Swift profile).
- New behavior has tests; a bug fix has a test that fails without the fix.
- `make coverage` stays at 100% line coverage for `Sources/KoF22Kit`.
- User-visible changes update the docs in the same change; architecture decisions get
  an ADR in `docs/adr/`; attack-surface changes update `docs/security/threat-model.md`.
- No secrets, credentials, or personal data, ever.
- New dependencies are justified (an ADR or the pull request description).
- Generated code (`Packages/KoF22Kit/Sources/KoF22API/Generated`) is never edited by
  hand: run `make generate` or `make update-spec`.

## Checks that gate a merge

| Check | What it verifies |
| --- | --- |
| `pr / title` | The PR title is a Conventional Commit header |
| `pr / dco` | Every commit is signed off |
| `pr / dependency-review` | Added dependencies have no known vulnerabilities and an allowed license |
| `security / secrets`, `security / sca`, `security / workflows` | No secrets, no vulnerable dependencies, safe workflows |
| `codeql / analyze (swift)`, `codeql / analyze (actions)` | No high-severity static analysis findings |
| `ci / build-test` | Format, lint, unit tests with the coverage gate, warning-free build, UI tests |

## Sign-off (Developer Certificate of Origin)

By signing off a commit you certify the
[Developer Certificate of Origin 1.1](https://developercertificate.org/): that you
wrote the change, or otherwise have the right to submit it under the project's
license. `git commit -s` appends the sign-off:

```text
Signed-off-by: Your Name <your.email@example.com>
```

The name and email must match the commit author.

## AI-assisted contributions

AI coding tools are welcome. You remain the author: you must understand, test, and be
able to explain every line you submit, and you sign it off as your own. Substantial AI
assistance carries a `Co-Authored-By:` trailer naming the model (K22-AI-02) and is
noted in the pull request description.

## License

By contributing, you agree that your contributions are licensed under the project's
[MIT License](LICENSE).
