# Release workflow (Phase 3) — design

**Date:** 2026-10-16 · **Status:** approved in conversation; spec under review
**Brief:** `docs/BRIEF.md` § Phase 3 · **Builds on:** ADR 0004 (one provider), ADR 0007/0009 (base pack, fixtures), ADR 0012 (manifest, carry-over, `maqs manifest`)

## Goal

Add `build-maps.yml`: a GitHub Actions workflow that, monthly or on demand, downloads the Geofabrik extract once, builds every configured region and the base pack in parallel, assembles and validates `manifest.json`, and publishes the month's `data-YYYY-MM` release with every asset, marked latest — with no partial "latest" ever, safe same-month re-runs, pinned actions and only the default `GITHUB_TOKEN`.

## Decisions (approved 2026-10-16)

1. **`swift.yml` moves to Phase 4.** There is no `Package.swift` to build yet; the deviation from the brief's phase list is recorded in ADR 0013.
2. **Subset runs never publish.** A dispatch with a `region` or `layers` input builds and uploads artifacts for inspection and skips the release job. Only a full run (cron, or dispatch with both inputs empty) publishes.
3. **Three jobs, matrix per region** (`prepare` → `build` matrix → `release`), as the brief describes; one sequential job was rejected (no isolation, no parallelism).
4. **Disk space is checked, not freed.** The runner has about 14 GB free and a full run needs about 3 GB; a `df` step fails early under 6 GB instead of adding a third-party "free disk space" action.
5. **The first real publish** (`data-2026-10`) happens as the plan's last step, after a subset dispatch has proven the build jobs, and only on the owner's explicit go at that moment.

## Success criteria

- A cron or empty dispatch on `main` produces a release `data-YYYY-MM` holding every non-fixture region's files (`.v<N>.` names), the base pack, and `manifest.json`, marked latest; `https://github.com/lucavallin/maqs/releases/latest/download/manifest.json` returns the manifest and `maqs check-config --manifest` accepts it.
- Re-running the workflow in the same month replaces same-named assets and `manifest.json` on the same release, deletes nothing a manifest still names, and leaves the release latest.
- A dispatch with `region: test` builds only that region, uploads `dist-test`, and the release job is skipped.
- A failing region fails its matrix job; the release job does not run (`needs`), so no partial latest exists.
- Every action is pinned to a major tag already used in `pipeline.yml` (`actions/checkout@v7`, `actions/cache@v6`, `actions/upload-artifact@v7`, `actions/download-artifact@v7`, `astral-sh/setup-uv@v7`); the workflow uses only `GITHUB_TOKEN`; `permissions: contents: write` on the release job only.
- The Geofabrik extract is downloaded at most once per run (md5-keyed `actions/cache`, as `pipeline.yml`).
- Unit tests cover the new CLI pieces; the workflow YAML parses; one live subset run and one live full run are recorded in ADR 0013 with their timings and the artifact and asset sizes.

## Workflow: `.github/workflows/build-maps.yml`

### Triggers, inputs, concurrency

```yaml
on:
  schedule: [{ cron: "0 3 1 * *" }]        # 03:00 UTC on the 1st
  workflow_dispatch:
    inputs:
      region: { description: "One region id; empty = every region", default: "", type: string }
      layers: { description: "Comma-separated layers; empty = the default layers", default: "", type: string }
permissions: { contents: read }
concurrency: { group: build-maps, cancel-in-progress: false }
```

`full = (inputs.region == '' && inputs.layers == '')` (a cron run has no inputs → full).

### Job `prepare` (`ubuntu-24.04`, 10 min)

1. Checkout, `setup-uv`, `uv sync --frozen` in `pipeline/`.
2. `uv run maqs check-config` (regions.yaml and sources.json must validate before anything is built).
3. Outputs: `regions` = `uv run maqs regions --json | jq -c '[.regions[] | select(.fixture|not) | .id]'` (or, for a dispatch with `region`, `["<region>"]` after validating it is a configured id, fixtures allowed); `targets` = `regions` plus `"base"` on a full run (the base pack is built only on full runs — it is a release asset, not a per-region debug artifact — unless `region == base`); `release` = `data-$(date -u +%Y-%m)`; `full`; `layers` (the input or empty).
4. Geofabrik md5 step and `actions/cache` on `.cache/geofabrik` keyed `geofabrik-<extract>-<md5>` (one key per extract in `maqs regions --json`'s `geofabrik_extracts` list; today one). On a cache miss the job downloads the extract with the pipeline's own md5-verified code through a new small command, `uv run maqs fetch --extract europe/italy/nord-est --cache .cache`, so the cache saved at the end of `prepare` holds the file for every matrix job; on a hit the command finds the file and does nothing.
5. `df -BG --output=avail /` must be ≥ 6 GB, else fail with a message naming the measured need.

### Job `build` (`ubuntu-24.04`, 45 min, `needs: prepare`, `strategy: { fail-fast: false, matrix: { target: ${{ fromJSON(needs.prepare.outputs.targets) }} } }`)

1. Checkout, `setup-uv`, tool-binary cache and bootstrap exactly as `pipeline.yml` (same `TOOLS_KEY`), `bootstrap.sh --check`, `uv sync --frozen`, `maqs check-tools`.
2. Restore the Geofabrik cache with the same key (hit after `prepare`).
3. `uv run maqs build --region ${{ matrix.target }} [--layers <layers>] --dist "$GITHUB_WORKSPACE/dist" --cache "$GITHUB_WORKSPACE/.cache"` (`base` is a valid `--region`).
4. `cat dist/<target>/build-report.json`.
5. `actions/upload-artifact@v7` name `dist-<target>`, path `dist/<target>`, `retention-days: 7`, `if-no-files-found: error`.

### Job `release` (`ubuntu-24.04`, 20 min, `needs: [prepare, build]`, `if: needs.prepare.outputs.full == 'true'`, `permissions: { contents: write }`)

1. Checkout, `setup-uv`, `uv sync --frozen`.
2. `actions/download-artifact@v7` with `pattern: dist-*`, `path: dist`, `merge-multiple: false` → `dist/dist-<target>/…`; a step moves each `dist/dist-<t>` to `dist/<t>` (or the manifest command is given the artifact layout — simpler: rename).
3. Previous manifest: `gh release download --pattern manifest.json --dir previous || true` (no release yet → skip `--previous`); if a file was downloaded, pass `--previous previous/manifest.json`.
4. `uv run maqs manifest --release <tag> --dist "$GITHUB_WORKSPACE/dist" [--previous …]` (validates; fails closed on a missing region or base pack).
5. `uv run maqs release-check --dist "$GITHUB_WORKSPACE/dist" --manifest dist/manifest.json`: every entry whose `url` tag equals this release must exist in `dist/` with the manifest's `bytes` and `sha256`; entries carried from an older tag are not required locally; prints the asset list and total bytes.
6. `gh release view <tag>` → if absent: `gh release create <tag> --target "$GITHUB_SHA" --title "Map data <YYYY-MM>" --notes-file notes.md` where notes.md lists each region with its layers' `osm_timestamp`s and the base pack, generated by `maqs release-check --notes notes.md`.
7. Upload every local asset the manifest names for this tag: `gh release upload <tag> <files…> --clobber`; then `gh release upload <tag> dist/manifest.json --clobber` last, so a reader never sees a manifest naming assets that are not yet there.
8. `gh release edit <tag> --latest`.
9. Summary step: `$GITHUB_STEP_SUMMARY` gets the asset table (name, bytes) and the carried count from the manifest step's log.

### Re-run and failure semantics

- Same month, second run: same tag; `gh release create` is skipped; assets with the same name are replaced (`--clobber` deletes then re-uploads — the window between delete and upload is accepted and noted in the ADR); `manifest.json` is replaced last. Carried entries keep their old-tag URLs; nothing is deleted on older releases.
- Any `build` job fails → `release` does not run (`needs`); the month's existing release, if any, stays as it was.
- `maqs manifest` or `release-check` fails → nothing is uploaded.
- An upload fails midway → the release may hold a mix of old and new assets while the old `manifest.json` still names the old sha256s; a client verifying SHA-256 refuses the mismatched file and keeps its installed data (Phase 4 contract); the next run repairs it. Recorded in the ADR as the accepted failure mode.
- "Latest" is explicit (`gh release edit --latest`) because GitHub orders by the tagged commit's date; two months tagging the same `main` commit would otherwise tie.

## CLI and pipeline changes

- `maqs regions --json`: prints `{"regions": [{"id", "fixture", "name": {"it","en"}, "bbox", "geofabrik": "<extract>"}], "base_packs": [{"id", "regions", "max_zoom"}], "geofabrik_extracts": [...]}`; the human-readable output stays the default.
- `maqs fetch --extract <name> [--cache DIR]`: downloads and md5-verifies one Geofabrik extract into the cache (reuses `osm.extract.geofabrik_pbf` through a minimal context); exits 1 on `FetchError`.
- `maqs release-check --dist DIR --manifest PATH [--notes PATH]`: the asset existence/size/sha check and the notes file; exit 1 on any mismatch, message naming the file.
- `maqs manifest` unchanged.

## Docs

- ADR 0013 — Release workflow: job design, subset runs never publish, disk check instead of a free-space action (measurements), `--clobber` semantics and the accepted mid-upload failure mode, the "latest" rule by commit date (verified 2026-10-16 against the GitHub REST docs) and why `--latest` is explicit, the gh facts verified (`gh release download` without a tag reads the latest release; `gh release create` creates the tag from the default branch head unless `--target`), the first-release procedure, `swift.yml` deferred to Phase 4 (`CONTRADICTS BRIEF`, minor).
- `docs/architecture.md`: the release flow (prepare → build → release), artifact and cache layout, re-run semantics, what Phase 4 may assume (manifest uploaded last; SHA mismatch → re-fetch manifest).
- `README.md`: "Data releases" paragraph (where, when, how to re-run).
- `CLAUDE.md` §1: Commands (`maqs regions --json`, `maqs fetch`, `maqs release-check`), the workflow in the repository map and Environments, traps: "`gh release upload --clobber` deletes before it uploads"; "`gh release create` tags the default branch head — pass `--target $GITHUB_SHA`"; "subset dispatches never publish".

## Tests

- `tests/test_cli.py`: `regions --json` shape and fixture flag; `fetch` success/failure with stubbed download; `release-check` passes on a matching dist, fails on a missing file, a wrong size, a wrong sha256, ignores carried (old-tag) entries, writes the notes file.
- Workflow YAML parses; a unit test asserts every `uses:` in both workflows is pinned to `@v<major>` and that `build-maps.yml` has no `permissions: write` outside the release job (cheap YAML assertions).
- Live: one `region: test` dispatch (build-only path, artifact `dist-test`, release skipped); one full run publishing `data-2026-10` on explicit go; `curl -sIL …/releases/latest/download/manifest.json` returns 200 and the file validates.

## Out of scope

`swift.yml` and anything Swift (Phase 4); release notes beyond the generated list; deleting old releases or assets; a second provider; signing assets.

## Risks

- A tag created by `gh release create` points at the run's commit; the schedule runs on `main`, so that is the published pipeline version.
- `--clobber`'s delete-then-upload window; accepted, documented.
- Artifact size: about 1 GB per full run for 7 days — within GitHub's free allowance for a public repo.
- The first full run is a real publish; staged after a subset run and an explicit go.
