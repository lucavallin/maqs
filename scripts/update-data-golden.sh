#!/usr/bin/env bash
# Regenerates the golden corner analyses the Swift MaqsData tests compare against, from the
# committed curvature fixture and the pipeline's curvature code. Run from the repository root.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
fixtures="$root/Tests/MaqsTestSupport/Fixtures"

(
  cd "$root/pipeline"
  uv run python -m maqs.data_golden \
    "$fixtures/test/test-curvature.v1.sqlite" \
    "$fixtures/test/data-golden.json"
)
