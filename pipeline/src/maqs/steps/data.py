"""What the SQLite data-layer steps share beyond the writer itself.

This lives here rather than in `sqlite_out`, which cannot import `osm.extract`: extract imports
the tile steps, whose runner imports `validate`, which imports `sqlite_out`.
"""

from __future__ import annotations

from datetime import UTC, datetime

from maqs.context import BuildContext
from maqs.osm import extract
from maqs.sqlite_out import Metadata


def metadata_for(ctx: BuildContext, layer: str) -> Metadata:
    """The layer's metadata row: today's UTC build date and the extract's replication timestamp."""
    timestamp = extract.osm_timestamp(extract.geofabrik_pbf(ctx))
    today = datetime.now(UTC).strftime("%Y-%m-%d")
    return Metadata(layer, ctx.require_region().id, today, timestamp)
