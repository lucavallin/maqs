#!/usr/bin/env bash
# Regenerates the Swift test fixtures from the pipeline and refreshes the bundled sources.json copy.
# Run from the repository root. Needs the pipeline toolchain (pipeline/bootstrap.sh) and about 5 minutes.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
fixtures="$root/Tests/MaqsTestSupport/Fixtures"
cap_kb=8192

(
  cd "$root/pipeline"
  uv run maqs build --region test
  uv run maqs build --region base
  uv run maqs manifest --release data-ci --regions test
)

rm -rf "$fixtures/test" "$fixtures/base"
mkdir -p "$fixtures/test"
# Data files only: build reports hold absolute local paths. The base pack (~13 MB) would break the
# cap, so tests serve the test basemap under the base pack's name.
cp "$root"/dist/test/*.pmtiles "$root"/dist/test/*.sqlite "$fixtures/test/"
cp "$root/dist/manifest.json" "$fixtures/manifest.json"
cp "$root/config/sources.json" "$root/Sources/MaqsCore/Resources/sources.json"
"$root/scripts/update-terrain-golden.sh"
"$root/scripts/update-data-golden.sh"

size_kb=$(du -sk "$fixtures" | cut -f1)
if [ "$size_kb" -gt "$cap_kb" ]; then
  echo "fixtures are ${size_kb} KB, over the ${cap_kb} KB cap" >&2
  exit 1
fi
echo "fixtures: ${size_kb} KB"
