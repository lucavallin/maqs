"""What every step needs to know about the current build."""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import UTC, datetime
from pathlib import Path

from maqs.config import Config, Region

# The label and output directory of the base-pack target; reserved as a region id.
BASE_TARGET = "base"


def _today() -> str:
    return datetime.now(UTC).strftime("%Y-%m-%d")


@dataclass
class BuildContext:
    """One build target: a region, or, with `region` None, every base pack together.

    `data_date` is the UTC date of the build run, read once when the context is made, so every
    output of the run carries the same date even when the run crosses midnight.
    """

    config: Config
    dist: Path
    cache: Path
    force: bool
    region: Region | None = None
    data_date: str = field(default_factory=_today)

    @property
    def label(self) -> str:
        return BASE_TARGET if self.region is None else self.region.id

    @property
    def out_dir(self) -> Path:
        return self.dist / self.label

    def require_region(self) -> Region:
        """The region of a region-scoped step; the base-pack target has none."""
        if self.region is None:
            raise ValueError("this step needs a region")
        return self.region
