# Contributing

[`README.md`](README.md) explains what this repository does. [`CLAUDE.md`](CLAUDE.md), under Commands, lists every command with a one-line description.

## Pipeline

Install the pinned tools and build the `test` region, which runs every layer in a few minutes:

```sh
pipeline/bootstrap.sh            # versatiles, pmtiles, osmium-tool, tippecanoe (macOS or Ubuntu 24.04)
cd pipeline && uv sync
uv run maqs build --region test  # outputs in dist/test/ at the repository root
uv run pytest -q                 # unit tests, no network
uv run ruff check . && uv run ruff format --check .
```

A new region is one entry in `config/regions.yaml`; the README says when the release workflow needs an edit as well. A new map provider or trail source needs an ADR in `docs/decisions.md` first.

## Swift package

```sh
swift build
swift test                       # macOS; reads the committed fixtures, no network, no Python
xcodebuild -scheme Maqs -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation test
```

Any installed simulator works for the last command (`xcrun simctl list devices available`). The scheme is `Maqs` while the package has one library product and `Maqs-Package` once it has several; `xcodebuild -list` shows which. Swift Testing also prints an XCTest summary that says "Executed 0 tests"; the real count is on the `Test run with N tests` line.

The tests read the `test` region's outputs from `Tests/MaqsTestSupport/Fixtures/`. When the pipeline's outputs or `config/sources.json` change, regenerate them with `scripts/update-fixtures.sh`, which needs the pipeline tools and takes a few minutes, and commit the result. The script fails when the fixtures exceed 8 MB, and so does `swift.yml`. Never edit a fixture by hand.

## Pull requests

Every change ships with its tests. Documentation that the change makes wrong is updated in the same pull request, and a decision that is expensive to reverse gets an ADR. Commit messages follow `type(scope): summary`, for example `fix(core): reject a manifest with a foreign host`.
