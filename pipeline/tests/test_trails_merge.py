import pytest

from maqs.trails.merge import merge, normalise_ref, overlap_share
from maqs.trails.model import TrailRecord


def record(source, ref, legs, name=None):
    return TrailRecord(
        source=source,
        source_id=f"{source}/{ref or name}",
        source_licence=None,
        source_date=None,
        osm_type=None,
        osm_id=None,
        ref=ref,
        ref_rei=None,
        name=name,
        difficulty=None,
        difficulty_scheme=None,
        difficulty_value=None,
        network=None,
        operator=None,
        osmc_symbol=None,
        from_name=None,
        to_name=None,
        roundtrip=None,
        survey_date=None,
        website=None,
        legs=legs,
        geometry_status="ordered",
    )


A = [[(12.25, 46.10), (12.26, 46.10), (12.27, 46.10)]]  # ~1.5 km, E-W
A_SHIFTED = [[(12.25, 46.1002), (12.27, 46.1002)]]  # 22 m north of A
FAR = [[(12.25, 46.20), (12.27, 46.20)]]


def test_normalise_ref():
    assert normalise_ref(" 501 ") == "501"
    assert normalise_ref("cai 501") == "CAI 501"
    assert normalise_ref(None) is None


def test_overlap_share():
    assert overlap_share(A_SHIFTED[0], A[0], overlap_m=50.0, step_m=25.0) == pytest.approx(1.0)
    assert overlap_share(FAR[0], A[0], overlap_m=50.0, step_m=25.0) == 0.0


def test_same_ref_overlapping_becomes_secondary_of_the_higher_priority_source():
    out = merge(
        [
            ("osm", [record("osm", "501", A)]),
            ("synthetic", [record("synthetic", "501", A_SHIFTED)]),
        ]
    )
    assert [r.source for r in out] == ["osm", "synthetic"]
    assert out[0].secondary_of is None
    assert out[1].secondary_of == 0


def test_priority_order_decides_the_winner():
    out = merge(
        [
            ("synthetic", [record("synthetic", "501", A_SHIFTED)]),
            ("osm", [record("osm", "501", A)]),
        ]
    )
    assert out[0].source == "synthetic"
    assert out[1].secondary_of == 0


def test_secondary_of_indexes_the_winner_after_reordering():
    out = merge(
        [
            ("osm", [record("osm", "501", A), record("osm", "502", FAR)]),
            ("synthetic", [record("synthetic", "502", FAR)]),
        ]
    )
    assert [(r.source, r.ref) for r in out] == [
        ("osm", "501"),
        ("osm", "502"),
        ("synthetic", "502"),
    ]
    assert out[2].secondary_of == 1


def test_same_source_duplicates_both_stay_primary():
    out = merge([("osm", [record("osm", "501", A), record("osm", "501", A)])])
    assert len(out) == 2
    assert all(r.secondary_of is None for r in out)


def test_same_ref_far_apart_stays_separate():
    out = merge(
        [
            ("osm", [record("osm", "501", A)]),
            ("synthetic", [record("synthetic", "501", FAR)]),
        ]
    )
    assert len(out) == 2
    assert all(r.secondary_of is None for r in out)


def test_different_ref_or_no_ref_never_merges():
    out = merge(
        [
            ("osm", [record("osm", "501", A), record("osm", None, A, name="x")]),
            (
                "synthetic",
                [
                    record("synthetic", "502", A_SHIFTED),
                    record("synthetic", None, A_SHIFTED, name="y"),
                ],
            ),
        ]
    )
    assert len(out) == 4
    assert all(r.secondary_of is None for r in out)


def test_single_source_is_unchanged():
    records = [record("osm", "501", A), record("osm", "502", FAR)]
    assert merge([("osm", records)]) == records
