# ADR-0005: Upload original photos, strip location on device, convert HEIC when needed

- **Status:** Accepted
- **Date:** 2026-10-11
- **Pull request:** none (initial build on `main`)

## Context

The owner chose to upload original photos (no downscale). The server strips EXIF
location unless asked to keep it, refuses HEIC when no converter is configured (415
`heic_conversion_unavailable`), and limits uploads to 25 MB. Location in a public
photo is personal data (K22-SEC-70).

## Options considered

### Option A: rely on the server to strip location

- Pros: no client work.
- Cons: the location still leaves the device.

### Option B: strip GPS on device (lossless metadata copy), convert only when required

- Pros: location never leaves the phone unless the post opts in; JPEG/PNG keep their
  original bytes; HEIC is converted to JPEG only while the server refuses it
  (decided from `limits.photoContentTypes`); oversize photos are re-encoded smaller.
- Cons: ImageIO metadata handling must be tested (orientation must survive).

## Decision

Option B, implemented in `MediaProcessor`.

## Consequences

- Full photo-library access is requested so originals and their metadata can be read
  (owner decision 2026-10-11); the picker's copy is used when access is limited.
- Tests cover GPS removal, orientation preservation, HEIC conversion and the size cap.
