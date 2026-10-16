import json
from pathlib import Path

from maqs.schemas import validate

ROOT = Path(__file__).resolve().parents[2]
SOURCES = ROOT / "config" / "sources.json"
LICENCE = (ROOT / "DATA_LICENSE.md").read_text(encoding="utf-8")


def test_sources_json_validates_and_names_one_versatiles_source_per_layer():
    doc = json.loads(SOURCES.read_text(encoding="utf-8"))
    validate(doc, "sources")
    assert [s["id"] for s in doc["layers"]["basemap"]] == ["versatiles-osm"]
    assert [s["id"] for s in doc["layers"]["terrain"]] == ["versatiles-elevation"]
    basemap, terrain = doc["layers"]["basemap"][0], doc["layers"]["terrain"][0]
    assert basemap["tiles"] == "https://tiles.versatiles.org/tiles/osm/{z}/{x}/{y}"
    assert basemap["tilejson"] == "https://tiles.versatiles.org/tiles/osm/tiles.json"
    assert (basemap["min_zoom"], basemap["max_zoom"]) == (0, 14)
    assert terrain["tiles"] == "https://tiles.versatiles.org/tiles/elevation/{z}/{x}/{y}"
    assert (terrain["min_zoom"], terrain["max_zoom"], terrain["tile_size"]) == (0, 12, 512)


def test_every_attribution_string_in_sources_json_is_in_data_license():
    doc = json.loads(SOURCES.read_text(encoding="utf-8"))
    for layer in doc["layers"].values():
        for src in layer:
            for text in src["attribution"]:
                assert text in LICENCE, text
