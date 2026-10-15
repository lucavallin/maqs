import sqlite3

import pytest

from maqs.config import RowRange
from maqs.sqlite_out import (
    ATTRIBUTION,
    COUNT_TABLES,
    SCHEMA_VERSION,
    TABLES,
    Metadata,
    open_readonly,
    table_names,
    write_sqlite,
)
from maqs.validate import SqliteExpectation, ValidationError, validate_output

META = Metadata(
    layer="trails", region="test", data_date="2026-10-15", osm_timestamp="2026-10-06T20:21:06Z"
)


def fill_one_trail(conn: sqlite3.Connection) -> None:
    conn.execute(
        "INSERT INTO trails (id, source, source_id, length_m, geometry, geometry_status, "
        "name, ref, min_lon, min_lat, max_lon, max_lat) "
        "VALUES (1, 'osm', 'relation/100', 1234.5, 'abc', 'ordered', "
        "'Cimà Grànde', '501', 12.2, 46.0, 12.3, 46.1)"
    )
    conn.execute("INSERT INTO trails_rtree VALUES (1, 12.2, 12.3, 46.0, 46.1)")


def test_write_sqlite_creates_schema_metadata_and_indexes(tmp_path):
    path = tmp_path / "test-trails.sqlite"
    write_sqlite(path, "trails", META, fill_one_trail)
    assert not path.with_suffix(".sqlite.tmp").exists()
    conn = open_readonly(path)
    assert table_names(conn) >= TABLES["trails"]
    row = conn.execute(
        "SELECT schema_version, layer, region, data_date, osm_timestamp, attribution FROM metadata"
    ).fetchall()
    expected = (
        SCHEMA_VERSION["trails"],
        "trails",
        "test",
        "2026-10-15",
        "2026-10-06T20:21:06Z",
        ATTRIBUTION,
    )
    assert row == [expected]
    fts = "SELECT rowid FROM trails_fts WHERE trails_fts MATCH 'cima grande'"
    assert conn.execute(fts).fetchall() == [(1,)]
    box = (
        "SELECT id FROM trails_rtree "
        "WHERE min_lon <= 12.25 AND max_lon >= 12.25 AND min_lat <= 46.05 AND max_lat >= 46.05"
    )
    assert conn.execute(box).fetchall() == [(1,)]
    with pytest.raises(sqlite3.OperationalError):
        conn.execute(
            "INSERT INTO trails (id, source, source_id, length_m, geometry, geometry_status) "
            "VALUES (2, 'x', 'y', 1, 'g', 'ordered')"
        )


@pytest.mark.parametrize("layer", ["trails", "places", "curvature"])
def test_every_schema_creates_its_tables(tmp_path, layer):
    path = tmp_path / f"x-{layer}.sqlite"
    write_sqlite(path, layer, Metadata(layer, "x", "2026-10-15", None), lambda conn: None)
    conn = open_readonly(path)
    assert table_names(conn) >= TABLES[layer]
    for table in COUNT_TABLES[layer]:
        assert conn.execute(f"SELECT count(*) FROM {table}").fetchone() == (0,)


def expectation(**overrides):
    base = {
        "layer": "trails",
        "region": "test",
        "tables": TABLES["trails"],
        "count_tables": COUNT_TABLES["trails"],
    }
    base.update(overrides)
    return SqliteExpectation(**base)


def test_validate_sqlite_reports_rows_and_metadata(tmp_path):
    path = tmp_path / "test-trails.sqlite"
    write_sqlite(path, "trails", META, fill_one_trail)
    info = validate_output(path, expectation(row_ranges={"trails": RowRange(1, 10)}))
    assert info.rows == {"trails": 1} and info.tile_type is None and info.tiles is None
    assert info.attribution == ATTRIBUTION and info.source_data_date == "2026-10-06T20:21:06Z"
    assert info.file == "test-trails.sqlite" and info.bytes == path.stat().st_size


def test_validate_sqlite_fails_outside_the_expected_range(tmp_path):
    path = tmp_path / "test-trails.sqlite"
    write_sqlite(path, "trails", META, fill_one_trail)
    with pytest.raises(ValidationError, match="trails has 1 rows, expected 5..10"):
        validate_output(path, expectation(row_ranges={"trails": RowRange(5, 10)}))
    assert path.exists()  # kept for inspection


def test_validate_sqlite_rejects_missing_table_and_wrong_metadata(tmp_path):
    path = tmp_path / "test-trails.sqlite"
    write_sqlite(path, "trails", META, fill_one_trail)
    with pytest.raises(ValidationError, match="metadata layer 'trails', expected 'places'"):
        validate_output(path, expectation(layer="places"))
    conn = sqlite3.connect(path)
    conn.execute("DROP TABLE trails_rtree")
    conn.commit()
    conn.close()
    with pytest.raises(ValidationError, match="missing tables: trails_rtree"):
        validate_output(path, expectation())


@pytest.mark.parametrize("stored", [0, 2])
def test_validate_sqlite_rejects_a_schema_version_other_than_the_layers(tmp_path, stored):
    path = tmp_path / "test-trails.sqlite"
    write_sqlite(path, "trails", META, fill_one_trail)
    conn = sqlite3.connect(path)
    conn.execute("UPDATE metadata SET schema_version = ?", (stored,))
    conn.commit()
    conn.close()
    expected = SCHEMA_VERSION["trails"]
    with pytest.raises(
        ValidationError, match=f"metadata schema_version {stored}, expected {expected}"
    ):
        validate_output(path, expectation())


def test_validate_sqlite_rejects_garbage_and_truncation(tmp_path):
    garbage = tmp_path / "g.sqlite"
    garbage.write_bytes(b"not a database" * 100)
    with pytest.raises(ValidationError, match="not a database|integrity"):
        validate_output(garbage, expectation())
    path = tmp_path / "test-trails.sqlite"
    write_sqlite(path, "trails", META, fill_one_trail)
    path.write_bytes(path.read_bytes()[: path.stat().st_size // 2])
    with pytest.raises(ValidationError):
        validate_output(path, expectation())


def test_validate_sqlite_warns_but_passes_on_zero_rows_without_ranges(tmp_path, caplog):
    path = tmp_path / "x-trails.sqlite"
    write_sqlite(path, "trails", Metadata("trails", "x", "2026-10-15", None), lambda conn: None)
    with caplog.at_level("WARNING"):
        info = validate_output(path, expectation(region="x"))
    assert info.rows == {"trails": 0} and "zero rows" in caplog.text


def test_validate_sqlite_warns_on_zero_rows_even_inside_a_configured_range(tmp_path, caplog):
    path = tmp_path / "x-trails.sqlite"
    write_sqlite(path, "trails", Metadata("trails", "x", "2026-10-15", None), lambda conn: None)
    with caplog.at_level("WARNING"):
        info = validate_output(
            path, expectation(region="x", row_ranges={"trails": RowRange(0, 10)})
        )
    assert info.rows == {"trails": 0} and "zero rows" in caplog.text


def test_validate_sqlite_turns_a_wrong_metadata_schema_into_a_validation_error(tmp_path):
    path = tmp_path / "test-trails.sqlite"
    write_sqlite(path, "trails", META, fill_one_trail)
    conn = sqlite3.connect(path)
    conn.execute("DROP TABLE metadata")
    conn.execute("CREATE TABLE metadata (layer TEXT)")
    conn.commit()
    conn.close()
    with pytest.raises(ValidationError, match="no such column"):
        validate_output(path, expectation())


@pytest.mark.parametrize("dirname", ["C#dir", "pct%20dir", "q?dir"])
def test_open_readonly_handles_uri_special_characters_in_the_path(tmp_path, dirname):
    directory = tmp_path / dirname
    path = directory / "test-trails.sqlite"
    write_sqlite(path, "trails", META, fill_one_trail)
    before = sorted(p.name for p in tmp_path.iterdir())
    conn = open_readonly(path)
    assert table_names(conn) >= TABLES["trails"]
    with pytest.raises(sqlite3.OperationalError):
        conn.execute("DELETE FROM metadata")
    conn.close()
    assert sorted(p.name for p in tmp_path.iterdir()) == before
    assert sorted(p.name for p in directory.iterdir()) == ["test-trails.sqlite"]
