"""Downloads into .cache/ with an identifying User-Agent, streamed, verified, atomic."""

from __future__ import annotations

import hashlib
import re
import urllib.request
from collections.abc import Callable
from pathlib import Path

from maqs import __version__

USER_AGENT = f"maqs-pipeline/{__version__} (+https://github.com/lucavallin/maqs)"
_MD5_RE = re.compile(r"^([0-9a-fA-F]{32})\b")


class FetchError(OSError):
    """A download or an input cut failed; the message says which file and why."""


def md5_of(path: Path) -> str:
    digest = hashlib.md5()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def parse_md5_sidecar(text: str) -> str:
    match = _MD5_RE.match(text.strip())
    if not match:
        raise FetchError(f"malformed md5 sidecar: {text.strip()[:60]!r}")
    return match.group(1).lower()


def download(
    url: str,
    dest: Path,
    *,
    user_agent: str = USER_AGENT,
    opener: Callable | None = None,
) -> None:
    """Stream url into dest via a .part file; on any failure leave nothing behind."""
    # Resolved per call, not bound at definition, so tests can stub urllib.request.urlopen.
    opener = opener or urllib.request.urlopen
    dest.parent.mkdir(parents=True, exist_ok=True)
    part = dest.with_suffix(dest.suffix + ".part")
    request = urllib.request.Request(url, headers={"User-Agent": user_agent})
    try:
        with opener(request) as response, part.open("wb") as out:
            for chunk in iter(lambda: response.read(1 << 20), b""):
                out.write(chunk)
        part.replace(dest)
    except OSError as exc:
        part.unlink(missing_ok=True)
        raise FetchError(f"download of {url} failed: {exc}") from exc
