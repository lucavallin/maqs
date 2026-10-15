import math

import pytest

from maqs.geometry import (
    bbox_of,
    circumradius,
    cumulative_m,
    decode_polyline,
    encode_polyline,
    haversine_m,
    line_length_m,
    merge_close,
    resample,
)

# Google's published precision-5 example (lat/lon pairs in their doc; we store lon/lat).
GOOGLE_POINTS = [(-120.2, 38.5), (-120.95, 40.7), (-126.453, 43.252)]
GOOGLE_ENCODED = "_p~iF~ps|U_ulLnnqC_mqNvxq`@"


def test_polyline_matches_the_reference_vector_at_precision_5():
    assert encode_polyline(GOOGLE_POINTS, precision=5) == GOOGLE_ENCODED
    assert decode_polyline(GOOGLE_ENCODED, precision=5) == pytest.approx(GOOGLE_POINTS)


def test_polyline_precision_6_round_trips_to_a_tenth_of_a_metre():
    pts = [(12.2534567, 46.1012345), (12.2601234, 46.1109876), (-73.9857, 40.7484)]
    out = decode_polyline(encode_polyline(pts))
    for (lon, lat), (olon, olat) in zip(pts, out, strict=True):
        assert abs(lon - olon) < 1e-6 and abs(lat - olat) < 1e-6


def test_empty_polyline():
    assert encode_polyline([]) == "" and decode_polyline("") == []


def test_haversine_and_length():
    a, b = (12.25, 46.10), (12.26, 46.10)
    assert haversine_m(a, b) == pytest.approx(771.8, abs=1.0)  # 0.01° lon at 46.1° N
    assert line_length_m([a, b, a]) == pytest.approx(2 * haversine_m(a, b))
    assert cumulative_m([a, b]) == pytest.approx([0.0, haversine_m(a, b)])
    assert line_length_m([a]) == 0.0


def test_bbox_of():
    assert bbox_of([(12.3, 46.2), (12.1, 46.4), (12.2, 46.1)]) == (12.1, 46.1, 12.3, 46.4)


def test_resample_keeps_endpoints_and_spacing():
    a, b = (12.25, 46.10), (12.26, 46.10)  # ~772 m
    pts = resample([a, b], 100.0)
    assert pts[0] == a and pts[-1] == b
    assert len(pts) == 9  # 0,100,...,700 and the endpoint
    gaps = [haversine_m(p, q) for p, q in zip(pts, pts[1:], strict=False)]
    assert all(abs(g - 100.0) < 1.0 for g in gaps[:-1]) and gaps[-1] < 100.0
    assert resample([a], 100.0) == [a]


def test_circumradius_on_a_known_circle():
    # three points on a circle of radius 50 m around (12.25, 46.10), counter-clockwise (left turn)
    cx, cy = 12.25, 46.10
    m_per_deg_lon = 111_320 * math.cos(math.radians(cy))
    m_per_deg_lat = 110_574

    def on_circle(angle_deg):
        return (
            cx + 50 * math.cos(math.radians(angle_deg)) / m_per_deg_lon,
            cy + 50 * math.sin(math.radians(angle_deg)) / m_per_deg_lat,
        )

    r, sign = circumradius(on_circle(200), on_circle(270), on_circle(340))
    assert r == pytest.approx(50.0, rel=0.02) and sign == 1
    r2, sign2 = circumradius(on_circle(340), on_circle(270), on_circle(200))
    assert r2 == pytest.approx(50.0, rel=0.02) and sign2 == -1


def test_circumradius_collinear_is_infinite():
    r, sign = circumradius((12.25, 46.10), (12.26, 46.10), (12.27, 46.10))
    assert r == math.inf and sign == 0


def test_merge_close_drops_vertices_under_the_threshold():
    a = (12.25, 46.10)
    near = (12.25001, 46.10)  # ~0.8 m
    far = (12.26, 46.10)
    assert merge_close([a, near, far], 5.0) == [a, far]
    assert merge_close([a, near], 5.0) == [a, near]  # the last vertex is always kept
    assert merge_close([a], 5.0) == [a]
