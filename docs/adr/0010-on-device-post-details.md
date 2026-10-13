# ADR-0010: Suggest post details with the on-device model, rules for everything exact

- **Status:** Accepted
- **Date:** 2026-10-13
- **Pull request:** none (work on `main` until the first published version)

## Context

Every post needs a good title, name (40), short name (20), description, SEO title, SEO
description and keywords, plus a correct slug, excerpt and read time. The owner asked whether the
iPhone's local model can help. Post text must not go to an outside AI service (K22-AI-20), and the
app has no server of its own.

## Options considered

### Option A: rules only

- Pros: exact, offline, free, testable.
- Cons: a first line makes a poor title or description.

### Option B: Apple Foundation Models on device, rules as fallback and for exact values

- Pros: good wording; nothing leaves the phone (`SystemLanguageModel` only, never Private Cloud
  Compute); no dependency; suggestions are editable.
- Cons: needs Apple Intelligence (iPhone 15 Pro or newer, turned on); output is not deterministic,
  so it must be clipped and checked.

### Option C: a cloud model

- Rejected: sends post content to a third party.

## Decision

Option B. `OnDevicePostSuggester` asks the on-device model for title, name, short name, summary,
SEO title, SEO description and keywords (`@Generable` with guides), then `PostDetails.clipped()`
cuts everything to the field limits and SEO targets. Without the model, `RulePostSuggester` fills
the same fields. The slug, excerpt and read time always come from `PostText` rules: counting and
URL rules are exact in code and unreliable in a language model (the owner asked for read time from
the model; this was pushed back on and recorded in REQUIREMENTS.md). Automatic suggestions only
fill fields the user has not typed in; Suggest rewrites them all.

## Consequences

- Better metadata on capable iPhones, the same fields everywhere else.
- The model's text is a suggestion: the user can see and edit every field before posting, and the
  post detail shows what the server stored.
- Model behaviour is not unit-tested (it is not deterministic and not available on CI); the
  clipping, fallback and rules are.
