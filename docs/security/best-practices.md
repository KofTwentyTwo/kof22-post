# OpenSSF Best Practices assessment

## Project and ownership

KoF22 Post is an **Internal**-tier repository: private, single-user, with no public
releases. The OpenSSF Best Practices badge (K22-REPO-12) applies to public Product
repositories, so `badge.applicability` is `not-applicable` in `assurance.json`.

- Owner: James Maes.
- Reviewed: 2026-10-11. Next review: 2027-01-09, or before the repository becomes
  public, whichever comes first.

## Criterion evidence

Practices already in place that the passing criteria ask for:

- MIT `LICENSE`, `SECURITY.md` with private reporting, `CONTRIBUTING.md`.
- Automated tests (`make test`) and a 100% line-coverage gate on the core library
  (`make coverage`).
- Warnings as errors, swift-format and SwiftLint in CI and pre-commit.
- Secret scanning (gitleaks), dependency scanning (Trivy, OSV) and CodeQL through the
  standards' reusable workflows.
- Threat model in `docs/security/threat-model.md`.

## Maintenance

Reassess every 90 days and before the first public release. If the repository moves
to the Product tier, register it at <https://www.bestpractices.dev/en>, record the
project URL in `assurance.json` and add the real badge to the README.
