#!/usr/bin/env python3
"""Validate the Phase 4 delivery USDZ copies against the recorded inventory."""

from __future__ import annotations

import hashlib
import json
import re
import sys
from pathlib import Path, PurePosixPath
from typing import Any


PROJECT_ROOT = Path(__file__).resolve().parents[1]
INVENTORY_PATH = PROJECT_ROOT / "Docs" / "asset_inventory_raw.json"
ASSET_DESTINATION = (
    PROJECT_ROOT
    / "Packages"
    / "RealityKitContent"
    / "Sources"
    / "RealityKitContent"
    / "RealityKitContent.rkassets"
    / "Assets"
)
DELIVERY_DIRECTORY = "SpatialMastery/Media/3D/USDZ_Delivery"
EXPECTED_ASSET_COUNT = 50
SHOWCASE_ONLY = frozenset(
    {
        "battery-prop.usdz",
        "headband.usdz",
        "headset-mockup.usdz",
        "light-seal-cushion.usdz",
    }
)
SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as asset_file:
        for chunk in iter(lambda: asset_file.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def destination_relative_path(filename: str) -> PurePosixPath:
    if filename in SHOWCASE_ONLY:
        return PurePosixPath("ShowcaseOnly") / filename
    return PurePosixPath(filename)


def load_expected_assets() -> tuple[dict[PurePosixPath, dict[str, Any]], list[str]]:
    errors: list[str] = []
    try:
        inventory = json.loads(INVENTORY_PATH.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        return {}, [f"Could not read inventory {INVENTORY_PATH}: {error}"]

    inventory_files = inventory.get("files")
    if not isinstance(inventory_files, list):
        return {}, ["Inventory field 'files' must be an array"]

    expected: dict[PurePosixPath, dict[str, Any]] = {}
    for record in inventory_files:
        if not isinstance(record, dict):
            continue

        source_path_value = record.get("path")
        if not isinstance(source_path_value, str):
            continue

        source_path = PurePosixPath(source_path_value)
        if (
            source_path.parent.as_posix() != DELIVERY_DIRECTORY
            or source_path.suffix.lower() != ".usdz"
        ):
            continue

        byte_count = record.get("bytes")
        recorded_sha256 = record.get("sha256")
        if not isinstance(byte_count, int) or byte_count < 0:
            errors.append(f"Invalid byte count for inventory path: {source_path_value}")
            continue
        if not isinstance(recorded_sha256, str) or not SHA256_PATTERN.fullmatch(
            recorded_sha256
        ):
            errors.append(f"Invalid SHA-256 for inventory path: {source_path_value}")
            continue

        relative_path = destination_relative_path(source_path.name)
        if relative_path in expected:
            errors.append(f"Duplicate delivery asset in inventory: {source_path.name}")
            continue

        expected[relative_path] = {
            "bytes": byte_count,
            "sha256": recorded_sha256,
            "source_path": source_path_value,
        }

    if len(expected) != EXPECTED_ASSET_COUNT:
        errors.append(
            "Expected "
            f"{EXPECTED_ASSET_COUNT} delivery USDZ records, found {len(expected)}"
        )

    discovered_showcase = {
        path.name for path in expected if path.parent == PurePosixPath("ShowcaseOnly")
    }
    if discovered_showcase != SHOWCASE_ONLY:
        errors.append(
            "Showcase-only inventory set differs from the required four hardware props"
        )

    return expected, errors


def validate() -> int:
    expected, errors = load_expected_assets()

    if not ASSET_DESTINATION.is_dir():
        errors.append(f"Asset destination is missing: {ASSET_DESTINATION}")
        actual_paths: set[PurePosixPath] = set()
    else:
        actual_paths = {
            PurePosixPath(path.relative_to(ASSET_DESTINATION).as_posix())
            for path in ASSET_DESTINATION.rglob("*")
            if path.is_file() and path.suffix.lower() == ".usdz"
        }

    expected_paths = set(expected)
    for missing_path in sorted(expected_paths - actual_paths, key=str):
        errors.append(f"Missing USDZ: {missing_path}")
    for unexpected_path in sorted(actual_paths - expected_paths, key=str):
        errors.append(f"Unexpected USDZ: {unexpected_path}")

    verified_count = 0
    total_bytes = 0
    for relative_path in sorted(expected_paths & actual_paths, key=str):
        asset_path = ASSET_DESTINATION / Path(relative_path.as_posix())
        if asset_path.is_symlink():
            errors.append(f"Asset must be a copied file, not a symlink: {relative_path}")
            continue

        recorded = expected[relative_path]
        actual_bytes = asset_path.stat().st_size
        total_bytes += actual_bytes
        if actual_bytes != recorded["bytes"]:
            errors.append(
                f"Byte-count mismatch for {relative_path}: "
                f"expected {recorded['bytes']}, found {actual_bytes}"
            )
            continue

        actual_sha256 = sha256(asset_path)
        if actual_sha256 != recorded["sha256"]:
            errors.append(
                f"SHA-256 mismatch for {relative_path}: "
                f"expected {recorded['sha256']}, found {actual_sha256}"
            )
            continue

        verified_count += 1

    status = "PASSED" if not errors else "FAILED"
    print(f"Asset validation {status}")
    print(f"Inventory: {INVENTORY_PATH.relative_to(PROJECT_ROOT)}")
    print(f"Destination: {ASSET_DESTINATION.relative_to(PROJECT_ROOT)}")
    print(f"Expected delivery assets: {len(expected)}")
    print(f"Copied assets verified: {verified_count}")
    print(f"Showcase-only assets: {len(SHOWCASE_ONLY)}")
    print(
        f"Total bundle size: {total_bytes} bytes "
        f"({total_bytes / 1_000_000:.2f} MB; {total_bytes / (1024 * 1024):.2f} MiB)"
    )

    if errors:
        print("Errors:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(validate())
