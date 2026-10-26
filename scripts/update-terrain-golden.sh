#!/usr/bin/env bash
# Regenerates the golden terrain values the Swift tests compare against, from the committed
# terrain fixture and the pipeline's reader and sampler. Run from the repository root.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
fixtures="$root/Tests/MaqsTestSupport/Fixtures"

(
  cd "$root/pipeline"
  uv run python -m maqs.terrain_golden \
    "$fixtures/test/test-terrain.v1.pmtiles" \
    "$fixtures/test/terrain-golden.json"
)
