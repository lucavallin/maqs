from pathlib import Path

from maqs.overlay import build_overlay
from tests.step_fixtures import stub_tippecanoe


def test_overlay_command_names_files_relative_to_the_output_folder(monkeypatch, tmp_path: Path):
    # tippecanoe stores its command line and the output path in the archive's metadata
    # (generator_options, name, description), so an absolute path would publish the build folder.
    calls = stub_tippecanoe(monkeypatch, min_zoom=6, max_zoom=14)
    out = tmp_path / "region" / "test-trails.v1.pmtiles"
    out.parent.mkdir()

    argv = build_overlay([], out, "trails", 6, 14)

    assert calls["cwd"] == out.parent
    assert argv[argv.index("-o") + 1] == "test-trails.v1.pmtiles"
    assert argv[-1] == "test-trails.v1.geojsonseq"
    assert not any(str(tmp_path) in a for a in argv[1:])
    assert out.exists()
    assert not out.with_suffix(".geojsonseq").exists()
