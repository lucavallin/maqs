import hashlib
import io

import pytest

from maqs.cache import FetchError, download, md5_of, parse_md5_sidecar


class FakeResponse(io.BytesIO):
    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()


def test_md5_of_and_sidecar(tmp_path):
    p = tmp_path / "f.pbf"
    p.write_bytes(b"maqs" * 100)
    digest = hashlib.md5(b"maqs" * 100).hexdigest()
    assert md5_of(p) == digest
    assert parse_md5_sidecar(f"{digest}  nord-est-latest.osm.pbf\n") == digest
    with pytest.raises(FetchError, match="malformed md5"):
        parse_md5_sidecar("not a digest")


def test_download_streams_to_part_file_then_renames(tmp_path):
    seen = {}

    def opener(request):
        seen["ua"] = request.get_header("User-agent")
        return FakeResponse(b"payload")

    dest = tmp_path / "x.pbf"
    download("https://example.test/x.pbf", dest, user_agent="maqs-test/1", opener=opener)
    assert dest.read_bytes() == b"payload" and not dest.with_suffix(".pbf.part").exists()
    assert seen["ua"] == "maqs-test/1"


def test_download_failure_leaves_no_file(tmp_path):
    def opener(request):
        raise OSError("connection reset")

    dest = tmp_path / "x.pbf"
    with pytest.raises(FetchError, match="connection reset"):
        download("https://example.test/x.pbf", dest, user_agent="t", opener=opener)
    assert not dest.exists() and not list(tmp_path.iterdir())


def test_unit_tests_cannot_reach_the_network(tmp_path):
    with pytest.raises(RuntimeError, match="network disabled"):
        download("https://example.test/x.pbf", tmp_path / "x.pbf")
