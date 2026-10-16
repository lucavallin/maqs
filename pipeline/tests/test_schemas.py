import copy
import json
from pathlib import Path

import pytest

from maqs.schemas import SCHEMAS_DIR, SchemaError, load_schema, validate

ROOT = Path(__file__).resolve().parents[2]
RELEASE_URL = "https://github.com/lucavallin/maqs/releases/download/data-2026-11"

ENTRY = {
    "layer_schema_version": 1,
    "file": "veneto-trails.v1.sqlite",
    "url": f"{RELEASE_URL}/veneto-trails.v1.sqlite",
    "bytes": 1234,
    "sha256": "a" * 64,
    "data_date": "2026-11-01",
    "osm_timestamp": "2026-10-31T20:21:00Z",
}
OVERLAY = {
    **ENTRY,
    "file": "veneto-trails.v1.pmtiles",
    "role": "overlay",
    "url": ENTRY["url"].replace(".sqlite", ".pmtiles"),
}


def tile_entry(layer: str, ts: str | None = "2026-06-07T23:59:58Z") -> dict:
    name = f"veneto-{layer}.v1.pmtiles"
    return {**ENTRY, "file": name, "osm_timestamp": ts, "url": f"{RELEASE_URL}/{name}"}


MANIFEST = {
    "manifest_version": 1,
    "created_at": "2026-11-01T03:12:44Z",
    "release": "data-2026-11",
    "shortbread_version": "1.0",
    "attribution": [
        {
            "text": "© OpenStreetMap contributors",
            "licence": "ODbL 1.0",
            "url": "https://www.openstreetmap.org/copyright",
            "layers": ["basemap", "trails", "places", "curvature"],
        },
    ],
    "regions": [
        {
            "id": "veneto",
            "name": {"it": "Veneto", "en": "Veneto"},
            "bbox": [10.6231, 44.7923, 13.1021, 46.6806],
            "layers": {
                "basemap": [tile_entry("basemap")],
                "terrain": [tile_entry("terrain", None)],
                "trails": [ENTRY, OVERLAY],
                "places": [
                    {
                        **ENTRY,
                        "file": "veneto-places.v1.sqlite",
                        "url": ENTRY["url"].replace("trails", "places"),
                    }
                ],
                "curvature": [
                    {
                        **ENTRY,
                        "file": "veneto-curvature.v1.sqlite",
                        "url": ENTRY["url"].replace("trails", "curvature"),
                    }
                ],
            },
        }
    ],
    "base": [
        {
            "id": "triveneto",
            "regions": ["triveneto"],
            "max_zoom": 10,
            "layers": {
                "basemap": [
                    {
                        **tile_entry("basemap"),
                        "file": "base-triveneto-basemap.v1.pmtiles",
                        "url": f"{RELEASE_URL}/base-triveneto-basemap.v1.pmtiles",
                    }
                ]
            },
        }
    ],
}

_SOURCES_FILE = ROOT / "config" / "sources.json"
SOURCES = (
    json.loads(_SOURCES_FILE.read_text())
    if _SOURCES_FILE.exists()
    else {
        "sources_version": 1,
        "layers": {
            "basemap": [
                {
                    "id": "versatiles-osm",
                    "provider": "VersaTiles",
                    "tiles": "https://tiles.versatiles.org/tiles/osm/{z}/{x}/{y}",
                    "tilejson": "https://tiles.versatiles.org/tiles/osm/tiles.json",
                    "schema": "shortbread-1.0",
                    "format": "mvt",
                    "min_zoom": 0,
                    "max_zoom": 14,
                    "attribution": [
                        "© OpenStreetMap contributors",
                        "CC BY 4.0 ESA WorldCover 2021",
                    ],
                }
            ],
            "terrain": [
                {
                    "id": "versatiles-elevation",
                    "provider": "VersaTiles",
                    "tiles": "https://tiles.versatiles.org/tiles/elevation/{z}/{x}/{y}",
                    "tilejson": "https://tiles.versatiles.org/tiles/elevation/tiles.json",
                    "schema": "terrarium",
                    "format": "webp",
                    "tile_size": 512,
                    "min_zoom": 0,
                    "max_zoom": 12,
                    "attribution": ["© Mapterhorn"],
                }
            ],
        },
    }
)


def test_schema_files_exist_and_are_draft_2020_12():
    for name in ("manifest", "sources"):
        schema = load_schema(name)
        assert schema["$schema"] == "https://json-schema.org/draft/2020-12/schema"
        assert (SCHEMAS_DIR / f"{name}.schema.json").exists()


def test_valid_manifest_and_sources_pass():
    validate(MANIFEST, "manifest")
    validate(SOURCES, "sources")


def broken(doc: dict, path: list, value) -> dict:
    out = copy.deepcopy(doc)
    node = out
    for key in path[:-1]:
        node = node[key]
    if value is ...:
        del node[path[-1]]
    else:
        node[path[-1]] = value
    return out


TRAIL = ["regions", 0, "layers", "trails", 0]
TRAIL_PATH = "/regions/0/layers/trails/0"


@pytest.mark.parametrize(
    ("path", "value", "where"),
    [
        (["manifest_version"], 2, "/manifest_version"),
        (["shortbread_version"], "1.1", "/shortbread_version"),
        (["release"], "latest", "/release"),
        (["created_at"], "2026-11-01", "/created_at"),
        (["attribution"], [], "/attribution"),
        (["regions", 0, "name", "en"], ..., "/regions/0/name"),
        (["regions", 0, "id"], "Veneto", "/regions/0/id"),
        (["regions", 0, "bbox"], [1, 2, 3], "/regions/0/bbox"),
        ([*TRAIL, "sha256"], "xyz", f"{TRAIL_PATH}/sha256"),
        ([*TRAIL, "bytes"], 2_040_109_466, f"{TRAIL_PATH}/bytes"),
        ([*TRAIL, "bytes"], 0, f"{TRAIL_PATH}/bytes"),
        (
            [*TRAIL, "url"],
            "https://github.com/lucavallin/maqs/releases/latest/download/veneto-trails.v1.sqlite",
            f"{TRAIL_PATH}/url",
        ),
        (
            [*TRAIL, "url"],
            "http://github.com/lucavallin/maqs/releases/download/data-2026-11/veneto-trails.v1.sqlite",
            f"{TRAIL_PATH}/url",
        ),
        ([*TRAIL, "file"], "veneto-trails.sqlite", f"{TRAIL_PATH}/file"),
        (["regions", 0, "layers", "trails", 1, "role"], "tiles", "/regions/0/layers/trails/1/role"),
        (["regions", 0, "layers", "roads"], [ENTRY], "/regions/0/layers"),
        (["regions", 0, "extra"], 1, "/regions/0"),
        (["base", 0, "layers", "terrain"], [tile_entry("terrain")], "/base/0/layers"),
        (["regions"], [], "/regions"),
    ],
)
def test_invalid_manifests_name_the_offending_path(path, value, where):
    with pytest.raises(SchemaError) as exc:
        validate(broken(MANIFEST, path, value), "manifest")
    assert exc.value.path == where, exc.value.message


BASEMAP_TILES = "https://tiles.versatiles.org/tiles/osm"


@pytest.mark.parametrize(
    ("path", "value", "where"),
    [
        (["sources_version"], 2, "/sources_version"),
        (
            ["layers", "basemap", 0, "tiles"],
            f"{BASEMAP_TILES}/{{z}}/{{x}}",
            "/layers/basemap/0/tiles",
        ),
        (
            ["layers", "basemap", 0, "tiles"],
            "http://tiles.versatiles.org/tiles/osm/{z}/{x}/{y}",
            "/layers/basemap/0/tiles",
        ),
        (["layers", "basemap", 0, "schema"], "terrarium", "/layers/basemap/0/schema"),
        (["layers", "terrain", 0, "schema"], "shortbread-1.0", "/layers/terrain/0/schema"),
        (["layers", "terrain", 0, "tile_size"], ..., "/layers/terrain/0"),
        (["layers", "terrain", 0, "max_zoom"], 23, "/layers/terrain/0/max_zoom"),
        (["layers", "basemap", 0, "attribution"], [], "/layers/basemap/0/attribution"),
        (["layers", "basemap"], [], "/layers/basemap"),
        (["layers", "hillshade"], [], "/layers"),
        (["layers", "basemap", 0, "extra"], 1, "/layers/basemap/0"),
    ],
)
def test_invalid_sources_name_the_offending_path(path, value, where):
    with pytest.raises(SchemaError) as exc:
        validate(broken(SOURCES, path, value), "sources")
    assert exc.value.path == where, exc.value.message


def test_min_zoom_above_max_zoom_is_rejected():
    doc = broken(SOURCES, ["layers", "basemap", 0, "min_zoom"], 15)
    with pytest.raises(SchemaError) as exc:
        validate(doc, "sources")
    assert exc.value.path.startswith("/layers/basemap/0")
