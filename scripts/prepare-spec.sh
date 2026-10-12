#!/usr/bin/env bash
# Writes a copy of openapi/openapi.yaml for the generator with the parameter
# `examples:` blocks removed. The committed spec stays exactly as downloaded.
#
# Why: swift-openapi-generator 1.14.0 drops components/examples when it filters the
# document down to the operations we generate, then fails to resolve the parameter
# examples that still point at them. Examples do not affect generated code.
# Usage: scripts/prepare-spec.sh <output.yaml>
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
output="$1"

awk '
   /^components:/ { inPaths = 0 }
   /^paths:/ { inPaths = 1 }
   {
      if (skipping) {
         match($0, /^ */)
         if (RLENGTH > 8 || $0 ~ /^ *$/) { next }
         skipping = 0
      }
      if (inPaths && $0 ~ /^        examples:$/) { skipping = 1; next }
      print
   }
' "$root/openapi/openapi.yaml" > "$output"
