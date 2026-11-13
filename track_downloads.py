#!/usr/bin/env python3
"""Snapshot the latest public ResolvGuard GitHub Release download counts.

Adapted from ExtremeFiretop/MerlinAutoUpdate-Router/track_downloads.py.
GitHub reports download events, NOT unique routers or installation IDs.
"""
from __future__ import annotations

import csv
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

ASSETS = {
    "ResolvGuard-install.sh": "install",
    "ResolvGuard-update.sh": "update",
}

OUTPUT_PATH = Path("metrics/release_downloads.csv")
FIELDNAMES = [
    "snapshot_date",
    "snapshot_time_utc",
    "tag",
    "published_at",
    "kind",
    "asset_name",
    "asset_id",
    "download_count",
]


def github_get(url: str, token: str | None):
    headers = {
        "Accept": "application/vnd.github+json",
        "User-Agent": "ResolvGuard-release-metrics",
    }
    if token:
        headers["Authorization"] = f"Bearer {token}"
    request = Request(url, headers=headers)
    try:
        with urlopen(request, timeout=30) as response:
            return json.load(response)
    except HTTPError as exc:
        if exc.code == 404:  # Empty/new repository with no Release yet.
            return None
        body = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(
            f"GitHub API request failed: HTTP {exc.code} for {url}\n{body}"
        ) from exc
    except URLError as exc:
        raise RuntimeError(f"GitHub API request failed for {url}: {exc}") from exc


def load_existing_rows(path: Path) -> dict:
    rows = {}
    if not path.exists():
        return rows
    with path.open("r", newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle)
        missing = [field for field in FIELDNAMES if field not in (reader.fieldnames or [])]
        if missing:
            raise RuntimeError(f"{path} is missing expected columns: {', '.join(missing)}")
        for row in reader:
            key = (row["snapshot_date"], row["tag"], row["asset_name"])
            rows[key] = {field: row.get(field, "") for field in FIELDNAMES}
    return rows


def write_rows(path: Path, rows: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temp_path = path.with_suffix(path.suffix + ".tmp")
    ordered_rows = sorted(
        rows.values(),
        key=lambda row: (
            row["snapshot_date"],
            row["published_at"],
            row["tag"],
            row["kind"],
            row["asset_name"],
        ),
    )
    with temp_path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=FIELDNAMES)
        writer.writeheader()
        writer.writerows(ordered_rows)
    temp_path.replace(path)


def main() -> int:
    repository = os.environ.get("GITHUB_REPOSITORY", "").strip()
    token = os.environ.get("GITHUB_TOKEN", "").strip() or None
    if not repository or repository.count("/") != 1:
        print("ERROR: GITHUB_REPOSITORY must be owner/repository.", file=sys.stderr)
        return 1

    now = datetime.now(timezone.utc).replace(microsecond=0)
    rows = load_existing_rows(OUTPUT_PATH)
    latest_url = f"https://api.github.com/repos/{repository}/releases/latest"
    release = github_get(latest_url, token)
    if release is None:
        write_rows(OUTPUT_PATH, rows)
        print("No published ResolvGuard Release yet; metrics history preserved.")
        return 0
    if not isinstance(release, dict):
        raise RuntimeError("Unexpected response while retrieving latest Release.")

    snapshot_date = now.date().isoformat()
    snapshot_time = now.isoformat().replace("+00:00", "Z")
    tag = str(release.get("tag_name") or "")
    published_at = str(release.get("published_at") or "")
    matched_assets = 0
    for asset in release.get("assets") or []:
        name = str(asset.get("name") or "")
        kind = ASSETS.get(name)
        if kind is None:
            continue
        row = {
            "snapshot_date": snapshot_date,
            "snapshot_time_utc": snapshot_time,
            "tag": tag,
            "published_at": published_at,
            "kind": kind,
            "asset_name": name,
            "asset_id": str(asset.get("id") or ""),
            "download_count": str(asset.get("download_count") or 0),
        }
        rows[(snapshot_date, tag, name)] = row
        matched_assets += 1

    if matched_assets != len(ASSETS):
        raise RuntimeError(
            f"Expected {len(ASSETS)} counted assets for {tag}, found {matched_assets}. "
            "Confirm ResolvGuard-install.sh and ResolvGuard-update.sh are published."
        )
    write_rows(OUTPUT_PATH, rows)
    print(f"Recorded {matched_assets} counted asset(s) for {tag} on {snapshot_date}.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (RuntimeError, OSError, ValueError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
