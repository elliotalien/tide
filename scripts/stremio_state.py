#!/usr/bin/env python3
"""Read Stremio's saved playback state for the currently playing title.

Stremio's MPRIS implementation omits ``mpris:length``, always reports
``Position`` as 0 and sets ``CanSeek`` to false, so MPRIS alone cannot drive a
progress display. Stremio does persist the real duration and the last saved
position in its LocalStorage database. This helper exposes that state as JSON
so the Tide popup can show an interpolated timeline.

Usage:
    stremio_state.py --imdb tt2085059 --season 4 --episode 1
    stremio_state.py --imdb tt1375666

Output (stdout, exit 0) for a match::

    {"imdb":"tt2085059","videoId":"tt2085059:4:1","title":"Black Mirror",
     "duration":4610720,"position":2894000,"savedAt":1793111154591,
     "savedAtIso":"2026-10-27T14:25:54.591Z"}

``duration`` and ``position`` are in milliseconds, ``savedAt`` is epoch
milliseconds. Exit 1 when no matching saved state exists. Diagnostics go to
stderr only.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import sqlite3
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

IMDB_RE = re.compile(r"^tt\d{6,}$")
STORAGE_KEYS = ("library_recent", "library")


def storage_roots() -> list[Path]:
    home = Path.home()
    roots: list[Path] = []
    xdg_data = os.environ.get("XDG_DATA_HOME")
    if xdg_data:
        roots.append(Path(xdg_data) / "stremio" / "storage")
    roots.extend(
        [
            home / ".local" / "share" / "stremio" / "storage",
            home
            / ".var"
            / "app"
            / "com.stremio.Stremio"
            / "data"
            / "stremio"
            / "storage",
            home / ".stremio" / "storage",
        ]
    )
    return roots


def find_databases() -> list[Path]:
    """All Stremio LocalStorage databases, newest file first."""
    seen: dict[str, float] = {}
    for root in storage_roots():
        try:
            for path in root.glob("*/*/LocalStorage/localstorage.sqlite3"):
                try:
                    seen[str(path)] = path.stat().st_mtime
                except OSError:
                    continue
        except OSError:
            continue
    return [Path(path) for path, _ in sorted(seen.items(), key=lambda kv: kv[1], reverse=True)]


def decode_value(raw: bytes) -> str:
    # Stremio serialises LocalStorage strings as UTF-16LE without a BOM.
    if raw.startswith(b"\xff\xfe"):
        return raw[2:].decode("utf-16-le", "replace")
    if raw.startswith(b"\xef\xbb\xbf"):
        return raw[3:].decode("utf-8", "replace")
    if len(raw) >= 2 and raw[1] == 0 and raw[0] < 0x80:
        try:
            return raw.decode("utf-16-le")
        except UnicodeDecodeError:
            pass
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError:
        return raw.decode("utf-16-le", "replace")


def read_storage(db_path: Path) -> dict[str, dict]:
    """Return {storage_key: items} for the keys Tide understands."""
    con = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True, timeout=1.0)
    try:
        con.execute("PRAGMA query_only = ON")
        placeholders = ",".join("?" for _ in STORAGE_KEYS)
        rows = dict(
            con.execute(
                f"SELECT key, value FROM ItemTable WHERE key IN ({placeholders})",
                STORAGE_KEYS,
            )
        )
    finally:
        con.close()

    result: dict[str, dict] = {}
    for key, raw in rows.items():
        try:
            data = json.loads(decode_value(raw))
        except (ValueError, TypeError):
            continue
        items = data.get("items") if isinstance(data, dict) else None
        if isinstance(items, dict):
            result[key] = items
    return result


def read_with_copy(db_path: Path) -> dict[str, dict]:
    """Read a snapshot copy, for when the live WAL cannot be opened read-only."""
    with tempfile.TemporaryDirectory(prefix="tide-stremio-") as tmp:
        target = Path(tmp) / "localstorage.sqlite3"
        shutil.copy2(db_path, target)
        for suffix in ("-wal", "-shm"):
            sidecar = Path(str(db_path) + suffix)
            if sidecar.exists():
                try:
                    shutil.copy2(sidecar, Path(str(target) + suffix))
                except OSError:
                    pass
        return read_storage(target)


def parse_saved_at(value) -> int:
    if not isinstance(value, str) or not value.strip():
        return 0
    text = value.strip()
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        stamp = datetime.fromisoformat(text)
    except (ValueError, OverflowError):
        return 0
    if stamp.tzinfo is None:
        stamp = stamp.replace(tzinfo=timezone.utc)
    try:
        return int(stamp.timestamp() * 1000)
    except (OverflowError, OSError, ValueError):
        return 0


def as_number(value) -> float:
    try:
        number = float(value)
    except (TypeError, ValueError):
        return 0.0
    if number != number or number in (float("inf"), float("-inf")):
        return 0.0
    return number


def video_matches(video_id, imdb: str, season: int | None, episode: int | None) -> bool:
    video_id = str(video_id or "").strip()
    if season is not None and episode is not None:
        return video_id == f"{imdb}:{season}:{episode}"
    # Movies (and other single videos) store the meta id itself. Never accept
    # an episode id here: its timeline belongs to a different video.
    return video_id in ("", imdb)


def find_state(
    imdb: str, season: int | None, episode: int | None
) -> dict | None:
    best: dict | None = None

    for db_path in find_databases():
        try:
            storage = read_storage(db_path)
        except sqlite3.Error:
            try:
                storage = read_with_copy(db_path)
            except (sqlite3.Error, OSError) as error:
                print(f"stremio_state: cannot read {db_path}: {error}", file=sys.stderr)
                continue

        for key in STORAGE_KEYS:
            item = storage.get(key, {}).get(imdb)
            if not isinstance(item, dict):
                continue
            state = item.get("state")
            if not isinstance(state, dict):
                continue
            if not video_matches(state.get("video_id"), imdb, season, episode):
                continue

            duration = as_number(state.get("duration"))
            position = as_number(state.get("timeOffset"))
            if duration <= 0:
                continue
            position = max(0.0, min(position, duration))
            saved_at = parse_saved_at(state.get("lastWatched"))
            if best is not None and saved_at <= best["savedAt"]:
                continue

            best = {
                "imdb": imdb,
                "videoId": str(state.get("video_id") or ""),
                "title": str(item.get("name") or ""),
                "duration": int(round(duration)),
                "position": int(round(position)),
                "savedAt": saved_at,
                "savedAtIso": str(state.get("lastWatched") or ""),
            }

    return best


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--imdb", required=True, help="IMDb id, e.g. tt2085059")
    parser.add_argument("--season", type=int, default=None)
    parser.add_argument("--episode", type=int, default=None)
    args = parser.parse_args(argv)

    imdb = args.imdb.strip()
    if not IMDB_RE.match(imdb):
        print("stremio_state: invalid IMDb id", file=sys.stderr)
        return 2
    if (args.season is None) != (args.episode is None):
        print("stremio_state: --season and --episode must be given together", file=sys.stderr)
        return 2

    state = find_state(imdb, args.season, args.episode)
    if state is None:
        return 1

    print(json.dumps(state, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
