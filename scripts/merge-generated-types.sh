#!/usr/bin/env bash
# Merges swift-openapi-generator's split type files (Types+*.swift) into Types.swift.
#
# Why: the generator repeats the same `public import` lines in every split file; a
# file that does not use one of those types makes Swift warn "public import ... was
# not used" (about 25 warnings per build). Merged, every import is declared once and
# used. The generated code itself is not changed, only concatenated.
# Usage: scripts/merge-generated-types.sh <generated directory>
set -euo pipefail

dir="$1"
target="$dir/Types.swift"
merged="$(mktemp)"
trap 'rm -f "$merged"' EXIT

cp "$target" "$merged"
for part in "$dir"/Types+*.swift
do
   [[ -e "$part" ]] || continue
   {
      printf '\n// Merged from %s\n' "$(basename "$part")"
      # Everything after the import block, which ends at the first #endif.
      awk 'body { print } /^#endif$/ && !body { body = 1 }' "$part"
   } >> "$merged"
   rm "$part"
done
mv "$merged" "$target"
trap - EXIT
