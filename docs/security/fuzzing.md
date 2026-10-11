# Parser fuzzing assessment

## Applicability

Reviewed 2026-10-11 by James Maes. `fuzzing.applicability` is `not-applicable`.

Untrusted input reaches the app through these boundaries, none of which is a complex
parser implemented here:

| Boundary | Parsed by | Hand-written logic |
| --- | --- | --- |
| Site API responses | Foundation `JSONDecoder` through generated Codable types | None beyond mapping |
| Error envelope | Same, with a fallback for undecodable bodies | Tested with malformed bodies |
| OAuth callback URL | `URLComponents` | `state`/`code`/`error` checks, negative tests |
| Images (library, share sheet, camera) | Apple ImageIO | Metadata options only |
| Share-sheet text and URLs | `NSItemProvider` | Type checks, file copy |
| App URL scheme routes | `URLComponents` | Known hosts only |

## Targets and properties

None. Negative unit tests cover malformed callbacks, undecodable error bodies,
invalid images and invalid links (K22-TEST-23).

## Run and replay

Not applicable while no target exists.

## Review

Owner: James Maes. Reassess within 90 days (next: 2027-01-09) and whenever a new
input boundary or a hand-written parser is added.
