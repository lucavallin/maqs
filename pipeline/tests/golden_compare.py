"""Compares a freshly built golden structure with the committed golden file."""

from __future__ import annotations

import math

# The golden files are written on macOS and checked on Linux as well; the two libm implementations
# round sin, cos, log and tan differently in the last digits (1e-12 relative at most on the test
# fixtures). A formula or input change moves values far more than this.
GOLDEN_REL_TOL = 1e-9
GOLDEN_ABS_TOL = 1e-9


def golden_mismatch(actual: object, expected: object, path: str = "$") -> str | None:
    """The first place where `actual` differs from `expected`, or None when they match.

    Floats match within the tolerances above; everything else (ids, digests, counts, key sets,
    lengths) must be equal and of the same type.
    """
    if isinstance(expected, dict) and isinstance(actual, dict):
        if actual.keys() != expected.keys():
            return f"{path}: keys {sorted(actual)} != {sorted(expected)}"
        for key, value in expected.items():
            found = golden_mismatch(actual[key], value, f"{path}.{key}")
            if found:
                return found
        return None
    if isinstance(expected, list) and isinstance(actual, list):
        if len(actual) != len(expected):
            return f"{path}: {len(actual)} items != {len(expected)} items"
        for index, (item, value) in enumerate(zip(actual, expected, strict=True)):
            found = golden_mismatch(item, value, f"{path}[{index}]")
            if found:
                return found
        return None
    if isinstance(expected, float) and type(actual) is float:
        close = math.isclose(actual, expected, rel_tol=GOLDEN_REL_TOL, abs_tol=GOLDEN_ABS_TOL)
        return None if close else f"{path}: {actual!r} != {expected!r}"
    if type(actual) is not type(expected) or actual != expected:
        return f"{path}: {actual!r} != {expected!r}"
    return None
