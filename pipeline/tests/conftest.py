import urllib.request
from pathlib import Path

import pytest

from maqs.context import BuildContext
from tests.step_fixtures import region_ctx


def pytest_addoption(parser: pytest.Parser) -> None:
    parser.addoption(
        "--run-network",
        action="store_true",
        default=False,
        help="run tests that hit live sources",
    )


def pytest_collection_modifyitems(config: pytest.Config, items: list[pytest.Item]) -> None:
    if config.getoption("--run-network"):
        return
    skip = pytest.mark.skip(reason="needs --run-network")
    for item in items:
        if "network" in item.keywords:
            item.add_marker(skip)


@pytest.fixture(autouse=True)
def _no_network_in_unit_tests(request: pytest.FixtureRequest, monkeypatch: pytest.MonkeyPatch):
    """Unit tests never reach the network; only tests marked `network` may."""
    if "network" in request.keywords:
        return

    def refuse(*args, **kwargs):
        raise RuntimeError("network disabled in unit tests")

    monkeypatch.setattr(urllib.request, "urlopen", refuse)


@pytest.fixture
def ctx(tmp_path: Path) -> BuildContext:
    """The `test` region's build context, writing under tmp_path; a module may override it."""
    return region_ctx(tmp_path)
