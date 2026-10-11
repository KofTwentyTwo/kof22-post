#!/usr/bin/env bash
# Downloads the live Site API spec. Exits 2 (leaving the pinned copy untouched)
# when the API is not reachable yet.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
url="${SITE_API_SPEC_URL:-https://api.kof22.com/v1/openapi.yaml}"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
if ! curl -fsS -m 30 -o "$tmp" "$url"; then
  echo "spec not reachable at $url; keeping openapi/openapi.yaml" >&2
  exit 2
fi
grep -q '^openapi:' "$tmp" || { echo "response from $url is not an OpenAPI document" >&2; exit 1; }
{ echo "# Downloaded from $url on $(date -u +%Y-%m-%dT%H:%M:%SZ)"; cat "$tmp"; } > "$root/openapi/openapi.yaml"
echo "updated openapi/openapi.yaml from $url"
