"""Command-line entry point: build, regions, fetch, check-tools, check-config, manifest,
previous-manifest, release-check."""

from __future__ import annotations

import json
import logging
from collections.abc import Iterable
from pathlib import Path

import click

from maqs.config import DEFAULT_CONFIG_PATH, Config, ConfigError, load_config
from maqs.context import BASE_TARGET, BuildContext
from maqs.curvature.step import CurvatureStep
from maqs.manifest import CI_RELEASE, RELEASE_TAG, ManifestError, build_manifest, write_manifest
from maqs.osm import extract
from maqs.places.step import PlacesStep
from maqs.release import (
    ReleaseError,
    ReleaseStateError,
    carried_count,
    choose_previous,
    local_assets,
    release_notes,
)
from maqs.report import build_report, report_path, write_report
from maqs.schemas import SchemaError, validate
from maqs.steps.base import Step, run_step
from maqs.steps.terrain_hd import TerrainHDStep
from maqs.steps.tiles import TILE_STEPS, BasePackStep
from maqs.tools import check_tools
from maqs.trails.step import TrailsStep
from maqs.validate import TEST_REGION_WARN

LAYER_ORDER: tuple[str, ...] = (
    "basemap",
    "terrain",
    "terrain-hd",
    "trails",
    "places",
    "curvature",
)
LAYER_STEPS: dict[str, type] = {
    **TILE_STEPS,
    "terrain-hd": TerrainHDStep,
    "trails": TrailsStep,
    "places": PlacesStep,
    "curvature": CurvatureStep,
}
DEFAULT_LAYERS: tuple[str, ...] = ("basemap", "terrain", "trails", "places", "curvature")
LOG_FORMAT = "%(levelname)s %(name)s: %(message)s"


class _ClickStderrHandler(logging.Handler):
    """Writes log records to whatever stderr is current when the record is emitted.

    A plain StreamHandler binds the stream once; under click's CliRunner that stream is
    replaced per invocation, so a bound handler would write to a dead stream afterwards.
    """

    def emit(self, record: logging.LogRecord) -> None:
        try:
            click.echo(self.format(record), err=True)
        except Exception:  # a logging handler reports its own failures, never raises
            self.handleError(record)


def _configure_logging(verbose: bool) -> None:
    logger = logging.getLogger("maqs")
    logger.setLevel(logging.DEBUG if verbose else logging.INFO)
    if not any(isinstance(h, _ClickStderrHandler) for h in logger.handlers):
        handler = _ClickStderrHandler()
        handler.setFormatter(logging.Formatter(LOG_FORMAT))
        logger.addHandler(handler)


def _find_config(explicit: Path | None) -> Path:
    if explicit:
        return explicit
    here = Path.cwd().resolve()
    for candidate in (here, *here.parents):
        path = candidate / DEFAULT_CONFIG_PATH
        if path.exists():
            return path
    raise click.ClickException(
        f"{DEFAULT_CONFIG_PATH} not found in {here} or any parent; pass --config"
    )


@click.group()
@click.version_option(package_name="maqs")
@click.option(
    "--config",
    "config_path",
    type=click.Path(path_type=Path, exists=True, dir_okay=False),
    default=None,
    help="Path to regions.yaml.",
)
@click.option("-v", "--verbose", is_flag=True, help="Debug logging.")
@click.pass_context
def main(ctx: click.Context, config_path: Path | None, verbose: bool) -> None:
    """Build and inspect maqs data packs."""
    _configure_logging(verbose)
    ctx.obj = {"config_path": config_path}


def _config_path(ctx: click.Context) -> Path:
    return _find_config(ctx.obj["config_path"]).resolve()


def _load(config_path: Path) -> Config:
    try:
        return load_config(config_path)
    except ConfigError as exc:
        raise click.ClickException(f"invalid configuration: {exc}") from exc


def _repo_root(config_path: Path) -> Path:
    """The parent of the `config/` directory holding regions.yaml; defaults live under it."""
    return config_path.parent.parent


def _join(values: Iterable[object]) -> str:
    return ",".join(str(v) for v in values)


def regions_json(cfg: Config) -> dict:
    """The machine-readable region list the release workflow builds its matrix from."""
    return {
        "regions": [
            {
                "id": r.id,
                "fixture": r.fixture,
                "name": {"it": r.name["it"], "en": r.name["en"]},
                "bbox": list(r.bbox),
                "geofabrik": (r.osm or {}).get("geofabrik"),
            }
            for r in cfg.regions
        ],
        "base_packs": [
            {"id": p.id, "regions": list(p.regions), "max_zoom": p.max_zoom} for p in cfg.base_packs
        ],
        "geofabrik_extracts": cfg.geofabrik_extracts(),
    }


@main.command()
@click.option("--json", "as_json", is_flag=True, help="Machine-readable output for the workflows.")
@click.pass_context
def regions(ctx: click.Context, as_json: bool) -> None:
    """List configured regions, their OSM extracts, and the base packs."""
    cfg = _load(_config_path(ctx))
    if as_json:
        click.echo(json.dumps(regions_json(cfg), ensure_ascii=False))
        return
    for r in cfg.regions:
        extract = r.osm.get("geofabrik", "-") if r.osm else "-"
        flag = " (fixture)" if r.fixture else ""
        click.echo(
            f"{r.id}{flag}: {r.name['en']} / {r.name['it']}  bbox={_join(r.bbox)}  osm={extract}"
        )
    for p in cfg.base_packs:
        click.echo(
            f"base-{p.id}: regions={_join(p.regions)} max_zoom={p.max_zoom}"
            f" bbox={_join(cfg.base_pack_bbox(p))}"
        )
    click.echo(f"geofabrik extracts: {', '.join(cfg.geofabrik_extracts()) or '-'}")


@main.command()
@click.option(
    "--extract",
    "extract_id",
    required=True,
    help="Geofabrik extract, e.g. europe/italy/nord-est.",
)
@click.option(
    "--cache",
    type=click.Path(path_type=Path),
    default=None,
    show_default=".cache/ under the repo root",
    help="Download cache; a given path is relative to the current directory.",
)
@click.pass_context
def fetch(ctx: click.Context, extract_id: str, cache: Path | None) -> None:
    """Download one Geofabrik extract into the cache (md5-verified); reuse it when present."""
    config_path = _config_path(ctx)
    known = _load(config_path).geofabrik_extracts()
    if extract_id not in known:
        raise click.UsageError(f"unknown extract '{extract_id}'; configured: {', '.join(known)}")
    if cache is None:
        cache = _repo_root(config_path) / ".cache"
    try:
        path = extract.fetch_extract(cache, extract_id)
    except extract.FetchError as exc:
        raise click.ClickException(str(exc)) from exc
    click.echo(f"ok: {path} ({path.stat().st_size} bytes)")


def _checked_tool_versions() -> dict[str, str | None]:
    """Print every pinned tool's status; exit 1 unless all match their pins."""
    statuses = check_tools()
    for s in statuses:
        click.echo(f"{s.name:<11} pinned {s.pinned:<8} found {s.found or '-':<8} {s.note}")
    if not all(s.ok for s in statuses):
        raise click.ClickException("tool check failed; run pipeline/bootstrap.sh")
    return {s.name: s.found for s in statuses}


@main.command("check-tools")
def check_tools_command() -> None:
    """Verify the pinned external tools are installed at the pinned versions."""
    _checked_tool_versions()


def _parse_layers(raw: str | None) -> list[str]:
    """The requested layers in build order, duplicates removed; None means the defaults."""
    if raw is None:
        return list(DEFAULT_LAYERS)
    layers = [s.strip() for s in raw.split(",") if s.strip()]
    if not layers:
        raise click.UsageError("--layers must name at least one layer")
    for layer in layers:
        if layer not in LAYER_STEPS:
            raise click.UsageError(f"unknown layer '{layer}'; valid: {', '.join(LAYER_ORDER)}")
    return [layer for layer in LAYER_ORDER if layer in layers]


def _targets(
    cfg: Config, target: str, *, dist: Path, cache: Path, force: bool
) -> list[BuildContext]:
    """Resolve --region into build contexts; anything unknown is a usage error (exit 2).

    `base` is one context with no region: every base pack is a step of it, so all packs share
    `dist/base/` and one build report.
    """
    if target == BASE_TARGET:
        if not cfg.base_packs:
            raise click.UsageError("--region base: no base_packs are configured")
        return [BuildContext(cfg, dist, cache, force)]
    if target == "all":
        return [
            BuildContext(cfg, dist, cache, force, region=cfg.region(rid))
            for rid in cfg.region_ids(include_fixtures=True)
        ]
    try:
        region = cfg.region(target)
    except KeyError:
        valid = ", ".join([*cfg.region_ids(include_fixtures=True), "all", "base"])
        if any(target == f"base-{p.id}" for p in cfg.base_packs):
            raise click.UsageError(
                f"'{target}' is a base pack; base packs are built with --region base"
                f" (valid: {valid})"
            ) from None
        raise click.UsageError(f"unknown region '{target}'; valid: {valid}") from None
    return [BuildContext(cfg, dist, cache, force, region=region)]


def run_build(
    cfg: Config,
    *,
    target: str,
    layers: list[str],
    dist: Path,
    cache: Path,
    force: bool,
    tool_versions: dict[str, str | None] | None = None,
) -> list[tuple[str, dict]]:
    """Run the steps for every context `target` names and write one report per context.

    Returns (label, report) pairs; a failed step shows as `validation.ok == False`.
    `tool_versions` is recorded in each report; when omitted the tools are probed here.
    """
    reports: list[tuple[str, dict]] = []
    if tool_versions is None:
        tool_versions = {s.name: s.found for s in check_tools()}
    for ctx in _targets(cfg, target, dist=dist, cache=cache, force=force):
        steps: list[Step] = (
            [BasePackStep(p) for p in cfg.base_packs]
            if ctx.region is None
            else [LAYER_STEPS[name]() for name in layers]
        )
        results = [run_step(step, ctx) for step in steps]
        for r in results:
            detail = f" — {r.error}" if r.error else ""
            click.echo(f"{ctx.label}: {r.name} {r.status} in {r.seconds:.1f}s{detail}")
        if ctx.region and ctx.region.fixture:
            total = sum(
                o.bytes for r in results for o in r.outputs if o.layer in ("basemap", "terrain")
            )
            if total > TEST_REGION_WARN:
                click.echo(
                    f"warning: {ctx.label} basemap+terrain is {total} bytes,"
                    f" over {TEST_REGION_WARN}; shrink its bbox or set bbox_border: 0"
                )
        report = build_report(ctx.label, results, tool_versions)
        write_report(report_path(ctx.out_dir), report)
        reports.append((ctx.label, report))
    return reports


@main.command()
@click.option("--region", "target", required=True, help="A region id, 'all', or 'base'.")
@click.option(
    "--layers",
    default=",".join(DEFAULT_LAYERS),
    show_default=True,
    help=(
        "Comma-separated layer names, built in this order: basemap, terrain, terrain-hd,"
        " trails, places, curvature. terrain-hd is opt-in."
    ),
)
@click.option("--force", is_flag=True, help="Rebuild even when outputs exist.")
@click.option(
    "--dist",
    type=click.Path(path_type=Path),
    default=None,
    show_default="dist/ under the repo root",
    help="Output directory; a given path is relative to the current directory.",
)
@click.option(
    "--cache",
    type=click.Path(path_type=Path),
    default=None,
    show_default=".cache/ under the repo root",
    help="Download cache; a given path is relative to the current directory.",
)
@click.pass_context
def build(
    ctx: click.Context,
    target: str,
    layers: str,
    force: bool,
    dist: Path | None,
    cache: Path | None,
) -> None:
    """Build layers for a region (or all regions, or the base packs)."""
    config_path = _config_path(ctx)
    cfg = _load(config_path)
    if dist is None:
        dist = _repo_root(config_path) / "dist"
    if cache is None:
        cache = _repo_root(config_path) / ".cache"
    layer_names = _parse_layers(layers)
    _targets(cfg, target, dist=dist, cache=cache, force=force)  # validate before touching tools
    versions = _checked_tool_versions()
    reports = run_build(
        cfg,
        target=target,
        layers=layer_names,
        dist=dist,
        cache=cache,
        force=force,
        tool_versions=versions,
    )
    failed = [label for label, report in reports if not report["validation"]["ok"]]
    if failed:
        raise click.ClickException(f"build failed for: {', '.join(failed)} (see build-report.json)")
    click.echo("ok")


def _validate_json_file(path: Path, schema: str) -> None:
    try:
        doc = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise click.UsageError(f"{path.name}: {exc}") from exc
    try:
        validate(doc, schema)
    except SchemaError as exc:
        raise click.UsageError(f"{path.name}: {exc.path}: {exc.message}") from exc
    click.echo(f"ok: {path.name}")


@main.command("check-config")
@click.option(
    "--manifest",
    "manifest_file",
    type=click.Path(path_type=Path, exists=True, dir_okay=False),
    default=None,
    help="Also validate this manifest.json against config/schemas/manifest.schema.json.",
)
@click.pass_context
def check_config(ctx: click.Context, manifest_file: Path | None) -> None:
    """Validate regions.yaml, config/sources.json and, optionally, a manifest."""
    config_path = _config_path(ctx)
    _load(config_path)
    click.echo(f"ok: {config_path.name}")
    _validate_json_file(config_path.parent / "sources.json", "sources")
    if manifest_file is not None:
        _validate_json_file(manifest_file, "manifest")


@main.command()
@click.option(
    "--release",
    required=True,
    help="Release tag, data-YYYY-MM (data-ci with --regions).",
)
@click.option(
    "--dist",
    type=click.Path(path_type=Path),
    default=None,
    show_default="dist/ under the repo root",
)
@click.option(
    "--out",
    type=click.Path(path_type=Path),
    default=None,
    show_default="<dist>/manifest.json",
)
@click.option(
    "--previous",
    type=click.Path(path_type=Path, exists=True, dir_okay=False),
    default=None,
    help="The latest published manifest; its lower schema versions are carried over.",
)
@click.option(
    "--regions",
    "region_list",
    default=None,
    help="Comma-separated region ids; required with data-ci, refused for a data-YYYY-MM release.",
)
@click.pass_context
def manifest(
    ctx: click.Context,
    release: str,
    dist: Path | None,
    out: Path | None,
    previous: Path | None,
    region_list: str | None,
) -> None:
    """Assemble and validate manifest.json from every region's build report."""
    config_path = _config_path(ctx)
    cfg = _load(config_path)
    if release == CI_RELEASE:
        if region_list is None:
            raise click.UsageError(f"--release {CI_RELEASE} requires --regions")
    elif not RELEASE_TAG.fullmatch(release):
        raise click.UsageError(f"--release must look like data-YYYY-MM, got '{release}'")
    elif region_list is not None:
        raise click.UsageError("--regions is only valid with --release data-ci")
    region_ids = [r.strip() for r in region_list.split(",") if r.strip()] if region_list else None
    if region_list is not None and not region_ids:
        raise click.UsageError("--regions must name at least one region")
    if dist is None:
        dist = _repo_root(config_path) / "dist"
    if out is None:
        out = dist / "manifest.json"
    previous_doc = None
    if previous is not None:
        try:
            previous_doc = json.loads(previous.read_text(encoding="utf-8"))
        except (OSError, ValueError) as exc:
            raise click.ClickException(f"--previous {previous}: {exc}") from exc
        try:
            validate(previous_doc, "manifest")
        except SchemaError as exc:
            raise click.ClickException(f"--previous {previous}: {exc.path}: {exc.message}") from exc
    try:
        doc = build_manifest(cfg, dist, release, regions=region_ids, previous=previous_doc)
    except (ManifestError, SchemaError) as exc:
        raise click.ClickException(str(exc)) from exc
    write_manifest(out, doc)
    click.echo(f"wrote {out} ({len(doc['regions'])} regions, {len(doc['base'])} base packs)")


@main.command("previous-manifest")
@click.option(
    "--releases",
    "releases_file",
    type=click.Path(path_type=Path, exists=True, dir_okay=False),
    required=True,
    help="The JSON array of `gh api repos/<owner>/<repo>/releases --paginate | jq -s add`.",
)
@click.option("--release", required=True, help="This run's tag, data-YYYY-MM.")
def previous_manifest(releases_file: Path, release: str) -> None:
    """Print the data release whose manifest.json this run carries over from, or `none`.

    Warnings go to stderr as GitHub Actions `::warning::` lines; a release state the owner
    has to resolve exits 1.
    """
    if not RELEASE_TAG.fullmatch(release):
        raise click.UsageError(f"--release must look like data-YYYY-MM, got '{release}'")
    try:
        releases = json.loads(releases_file.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise click.ClickException(f"{releases_file}: {exc}") from exc
    try:
        tag, warnings = choose_previous(releases, release)
    except ReleaseStateError as exc:
        raise click.ClickException(str(exc)) from exc
    for warning in warnings:
        click.echo(f"::warning::{warning}", err=True)
    click.echo(tag or "none")


def _read_manifest(path: Path) -> dict:
    """A manifest file that parses and passes the schema; anything else exits 1."""
    try:
        doc = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise click.ClickException(f"{path}: {exc}") from exc
    try:
        validate(doc, "manifest")
    except SchemaError as exc:
        raise click.ClickException(f"{path}: {exc.path}: {exc.message}") from exc
    return doc


@main.command("release-check")
@click.option(
    "--dist", type=click.Path(path_type=Path, exists=True, file_okay=False), required=True
)
@click.option(
    "--manifest",
    "manifest_file",
    type=click.Path(path_type=Path, exists=True, dir_okay=False),
    required=True,
)
@click.option(
    "--previous",
    type=click.Path(path_type=Path, exists=True, dir_okay=False),
    default=None,
    help="The manifest passed to `maqs manifest --previous`; files it already names under"
    " this release with the same sha256 need not be in dist and are not uploaded.",
)
@click.option(
    "--notes", type=click.Path(path_type=Path), default=None, help="Write the release notes here."
)
def release_check(
    dist: Path, manifest_file: Path, previous: Path | None, notes: Path | None
) -> None:
    """Assert every asset the manifest names for its release is in dist with the right bytes.

    Prints one `<label>/<file> <bytes>` line per file to upload (relative to dist), a total
    line, and how many entries were carried from earlier releases.
    """
    doc = _read_manifest(manifest_file)
    previous_doc = None if previous is None else _read_manifest(previous)
    try:
        assets = local_assets(doc, dist, previous=previous_doc)
    except ReleaseError as exc:
        raise click.ClickException(str(exc)) from exc
    for asset in assets:
        click.echo(f"{asset.label}/{asset.file} {asset.bytes}")
    click.echo(f"total {len(assets)} assets, {sum(a.bytes for a in assets)} bytes")
    click.echo(f"carried {carried_count(doc)} entries from earlier releases")
    if notes is not None:
        notes.write_text(release_notes(doc, carried_count(doc)), encoding="utf-8")
        click.echo(f"wrote {notes}")
