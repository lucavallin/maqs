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
mkdir -p "$fixtures/test" "$fixtures/base"
cp "$root"/dist/test/* "$fixtures/test/"
# The base pack itself is ~13 MB and would break the cap; tests use the test basemap under its name.
cp "$root/dist/base/build-report.json" "$fixtures/base/build-report.json"
cp "$root/dist/manifest.json" "$fixtures/manifest.json"
cp "$root/config/sources.json" "$root/Sources/MaqsCore/Resources/sources.json"

size_kb=$(du -sk "$fixtures" | cut -f1)
if [ "$size_kb" -gt "$cap_kb" ]; then
  echo "fixtures are ${size_kb} KB, over the ${cap_kb} KB cap" >&2
  exit 1
fi
echo "fixtures: ${size_kb} KB"
