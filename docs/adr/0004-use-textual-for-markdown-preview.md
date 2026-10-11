# ADR-0004: Use Textual for the Markdown preview

- **Status:** Accepted
- **Date:** 2026-10-11
- **Pull request:** none (initial build on `main`)

## Context

Posts are Markdown. Apple's `AttributedString(markdown:)` renders inline styles only
(no lists, quotes or code blocks). A block-level preview needs a renderer. The
dependency standard (K22-DEP-01) requires a written justification.

## Options considered

### Option A: inline-only preview with Foundation

- Pros: no dependency.
- Cons: lists, quotes and code blocks preview as raw text.

### Option B: swift-markdown-ui (MarkdownUI)

- Pros: mature.
- Cons: in maintenance mode; its author directs new work to Textual.

### Option C: Textual 0.5.0 (gonzalezreal/textual)

- Pros: actively maintained successor of MarkdownUI by the same author, MIT license,
  SwiftUI-native, supports iOS 18+.
- Cons: pre-1.0; pulls in swift-concurrency-extras and swiftui-math (both MIT).

## Decision

Option C, pinned to an exact version, used only in the KoF22UI target on iOS.

## Consequences

- Dependabot proposes updates after a 7-day cooldown; a pre-1.0 API change is
  absorbed in the preview views only.
- No network or data access; no security impact beyond parsing the user's own text.
