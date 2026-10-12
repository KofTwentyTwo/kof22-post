#!/usr/bin/env bash
# Downloads the live Site API spec and shows how it differs from the committed copy.
# Nothing changes unless APPLY=1 is set, so updating the contract is deliberate:
#   make update-spec            # download and show the diff
#   make update-spec APPLY=1    # replace openapi/openapi.yaml, then run make generate
# Exits 2 (leaving the committed copy untouched) when the API is not reachable.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
url="${SITE_API_SPEC_URL:-https://api.kof22.com/v1/openapi.yaml}"
target="$root/openapi/openapi.yaml"
download="$(mktemp)"
candidate="$(mktemp)"
trap 'rm -f "$download" "$candidate"' EXIT

if ! curl -fsS -m 30 -o "$download" "$url"
then
   echo "spec not reachable at $url; keeping openapi/openapi.yaml" >&2
   exit 2
fi
if ! grep -q '^openapi:' "$download"
then
   echo "response from $url is not an OpenAPI document" >&2
   exit 1
fi

# The first line of the committed copy records where and when it came from.
{
   echo "# Downloaded from $url on $(date -u +%Y-%m-%dT%H:%M:%SZ)"
   cat "$download"
} > "$candidate"

if diff -q <(tail -n +2 "$target") "$download" > /dev/null
then
   echo "openapi/openapi.yaml is up to date with $url"
   exit 0
fi

diff -u <(tail -n +2 "$target") "$download" || true
if [[ "${APPLY:-0}" == "1" ]]
then
   cp "$candidate" "$target"
   echo "updated openapi/openapi.yaml from $url"
else
   echo "spec differs; rerun with APPLY=1 to update openapi/openapi.yaml"
fi
