"""What the SQLite data-layer steps share beyond the writer itself.

This lives here rather than in `sqlite_out`, which cannot import `osm.extract`: extract imports
the tile steps, whose runner imports `validate`, which imports `sqlite_out`.
"""

from __future__ import annotations

from maqs.context import BuildContext
from maqs.osm import extract
from maqs.sqlite_out import Metadata


def metadata_for(ctx: BuildContext, layer: str) -> Metadata:
    """The layer's metadata row: the run's UTC date and the extract's replication timestamp."""
    timestamp = extract.osm_timestamp(extract.geofabrik_pbf(ctx))
    return Metadata(layer, ctx.require_region().id, ctx.data_date, timestamp)
