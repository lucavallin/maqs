"""JSON Schema validation for manifest.json and sources.json.

The schemas in config/schemas/ are the single source of truth. One rule they cannot state,
min_zoom <= max_zoom on a tile source, is checked here after schema validation, for sources
and for nothing else.
"""

from __future__ import annotations

import json
import re
from collections.abc import Iterable
from functools import cache
from pathlib import Path
from typing import Any, cast

from jsonschema import Draft202012Validator, ValidationError
from jsonschema.validators import extend

SCHEMAS_DIR = Path(__file__).resolve().parents[3] / "config" / "schemas"
SIZE_CAP_BYTES = 2_040_109_465  # 1.9 GiB, the same cap validate.py enforces per file


class SchemaError(ValueError):
    """A document violates its schema; `path` locates the offending value."""

    def __init__(self, path: str, message: str) -> None:
        super().__init__(f"{path}: {message}")
        self.path = path
        self.message = message


@cache
def load_schema(name: str) -> dict[str, Any]:
    """Load `config/schemas/<name>.schema.json` (`manifest` or `sources`)."""
    path = SCHEMAS_DIR / f"{name}.schema.json"
    schema: dict[str, Any] = json.loads(path.read_text(encoding="utf-8"))
    return schema


def _pointer(parts: Iterable[object]) -> str:
    joined = "/".join(str(part) for part in parts)
    return f"/{joined}" if joined else "/"


def _ecma_pattern(validator: Any, pattern: str, instance: Any, schema: Any) -> Iterable[Any]:
    """`pattern` with ECMA-262 anchoring, the JSON Schema default, instead of Python's looser one.

    Python's `$` also matches before a trailing newline; a final `$` becomes `\\Z`. Only the
    last character is rewritten, so a `$` inside a character class is never touched (none of
    our patterns has one). Digits are spelled `[0-9]` in the schemas because `\\d` is Unicode
    in Python.
    """
    if validator.is_type(instance, "string"):
        anchored = (
            pattern[:-1] + r"\Z"
            if pattern.endswith("$") and not pattern.endswith(r"\$")
            else pattern
        )
        if not re.search(anchored, instance):
            yield ValidationError(f"{instance!r} does not match {pattern!r}")


_Validator = extend(Draft202012Validator, {"pattern": _ecma_pattern})


def validate(instance: object, name: str) -> None:
    """Raise SchemaError for the first violation (deepest path first, then alphabetical)."""
    validator = _Validator(load_schema(name))
    errors = sorted(
        validator.iter_errors(instance),
        key=lambda e: (-len(e.absolute_path), str(list(e.absolute_path)), e.message),
    )
    if errors:
        first = errors[0]
        raise SchemaError(_pointer(first.absolute_path), first.message)
    if name == "sources":
        document = cast(dict[str, Any], instance)  # the schema guarantees an object
        for layer, sources in document["layers"].items():
            for index, source in enumerate(sources):
                if source["min_zoom"] > source["max_zoom"]:
                    raise SchemaError(
                        f"/layers/{layer}/{index}/min_zoom", "min_zoom exceeds max_zoom"
                    )
