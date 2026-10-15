"""What every step needs to know about the current build."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from maqs.config import BasePack, Config, Region


@dataclass
class BuildContext:
    config: Config
    dist: Path
    cache: Path
    force: bool
    region: Region | None = None
    base_pack: BasePack | None = None

    @property
    def out_dir(self) -> Path:
        if self.base_pack is not None:
            return self.dist / "base"
        return self.dist / self._region().id

    @property
    def label(self) -> str:
        if self.base_pack is not None:
            return f"base-{self.base_pack.id}"
        return self._region().id

    def _region(self) -> Region:
        if self.region is None:
            raise ValueError("BuildContext needs a region or a base_pack")
        return self.region
