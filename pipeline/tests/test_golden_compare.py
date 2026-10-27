from tests.golden_compare import golden_mismatch


def test_floats_that_differ_in_the_last_digits_match():
    # A corner radius as macOS and Linux compute it from the same fixture.
    assert golden_mismatch({"r": [228.4784934392092]}, {"r": [228.4784934392088]}) is None


def test_a_float_beyond_the_tolerance_is_reported_with_its_path():
    built, committed = {"points": [{"elevation": 901.7144}]}, {"points": [{"elevation": 901.7145}]}
    found = golden_mismatch(built, committed)
    assert found == "$.points[0].elevation: 901.7144 != 901.7145"


def test_everything_but_floats_must_be_equal():
    assert golden_mismatch({"sha256": "ab"}, {"sha256": "ac"}) == "$.sha256: 'ab' != 'ac'"
    assert golden_mismatch({"id": 7}, {"id": 8}) == "$.id: 7 != 8"
    assert golden_mismatch({"id": 7}, {"id": 7.0}) == "$.id: 7 != 7.0"


def test_a_changed_shape_is_reported():
    assert golden_mismatch({"a": 1}, {"a": 1, "b": 2}) == "$: keys ['a'] != ['a', 'b']"
    assert golden_mismatch({"a": [1, 2]}, {"a": [1]}) == "$.a: 2 items != 1 items"
    assert golden_mismatch({"a": [1]}, {"a": {"x": 1}}) == "$.a: [1] != {'x': 1}"
