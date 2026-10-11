#!/usr/bin/env bash
# Runs the KoF22Kit unit tests with coverage and fails unless every line of the
# UI-free core (Sources/KoF22Kit) is covered (K22-TEST-10). Generated client code
# (Sources/KoF22API) and SwiftUI screens (Sources/KoF22UI) are not part of the gate.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
minimum="${COVERAGE_MINIMUM:-100}"
cd "$root/Packages/KoF22Kit"

swift test --enable-code-coverage
codecov="$(dirname "$(swift test --show-codecov-path)")"
profile="$codecov/default.profdata"
binary="$(find "$(dirname "$codecov")" -path '*KoF22KitTests.xctest/Contents/MacOS/KoF22KitTests' -type f | head -n 1)"

sources=()
while IFS= read -r file
do
   sources+=("$file")
done < <(find Sources/KoF22Kit -name '*.swift' | sort)

report="$(xcrun llvm-cov report "$binary" -instr-profile "$profile" "${sources[@]}")"
printf '%s\n' "$report"
covered="$(printf '%s\n' "$report" | awk '/^TOTAL/ { print $(NF-3) }' | tr -d '%')"

if awk -v covered="$covered" -v minimum="$minimum" 'BEGIN { exit !(covered + 0 >= minimum + 0) }'
then
   echo "KoF22Kit line coverage ${covered}% (minimum ${minimum}%)"
else
   echo "::error::KoF22Kit line coverage ${covered}% is below the ${minimum}% gate"
   exit 1
fi
