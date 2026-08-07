#!/usr/bin/env python3
"""Validate lazy-loaded spatial assets, scene skeletons, and composition contracts."""

from __future__ import annotations

import hashlib
import json
import re
import sys
from pathlib import Path, PurePosixPath
from typing import Any


PROJECT_ROOT = Path(__file__).resolve().parents[1]
INVENTORY_PATH = PROJECT_ROOT / "Docs" / "asset_inventory_raw.json"
MANIFEST_PATH = (
    PROJECT_ROOT / "Resources" / "Configuration" / "spatial_asset_manifest_v1.json"
)
LOOSE_ASSET_DESTINATION = PROJECT_ROOT / "Media" / "3D" / "USDZ"
RKASSETS_ROOT = (
    PROJECT_ROOT
    / "Packages"
    / "RealityKitContent"
    / "Sources"
    / "RealityKitContent"
    / "RealityKitContent.rkassets"
)
DELIVERY_DIRECTORY = "SpatialMastery/Media/3D/USDZ_Delivery"
EXPECTED_ASSET_COUNT = 50
EXPECTED_SCENES = frozenset(
    {
        "AcademyLobby",
        "HeartAndLungsVolume",
        "ChainOfSurvivalVolume",
        "DRSABCTrainingRoom",
        "CPRPracticeRoom",
        "AEDPreparationRoom",
        "AEDPlacementRoom",
        "Scenario_Home",
        "Scenario_ShoppingCentre",
        "Scenario_Workplace",
        "Scenario_CommunityFacility",
        "AchievementGallery",
        "DebriefSpace",
    }
)
EXPECTED_AUTHORED_HELPERS = frozenset(
    {
        "AEDTrainer",
        "Bystander",
        "ClearZone",
        "HeartAndLungs",
        "RingPlaceholder",
        "TrainingManikin",
    }
)
SHOWCASE_ONLY = frozenset(
    {
        "battery-prop.usdz",
        "headband.usdz",
        "headset-mockup.usdz",
        "light-seal-cushion.usdz",
    }
)
SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
ANCHOR_PATTERN = re.compile(r'\bdef(?:\s+\w+)?\s+"(anchor_[^"]+)"')


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as asset_file:
        for chunk in iter(lambda: asset_file.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


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

        relative_path = PurePosixPath(source_path.name)
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
            f"Expected {EXPECTED_ASSET_COUNT} delivery USDZ records, found {len(expected)}"
        )

    discovered_showcase = {path.name for path in expected if path.name in SHOWCASE_ONLY}
    if discovered_showcase != SHOWCASE_ONLY:
        errors.append("Inventory differs from the required four showcase-only hardware props")

    return expected, errors


def load_composition_manifest() -> tuple[dict[str, Any], list[str]]:
    try:
        manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        return {}, [f"Could not read composition manifest {MANIFEST_PATH}: {error}"]
    if not isinstance(manifest, dict):
        return {}, ["Composition manifest root must be an object"]
    return manifest, []


def validate_manifest(
    manifest: dict[str, Any], expected_asset_stems: set[str]
) -> tuple[list[str], int]:
    errors: list[str] = []
    if manifest.get("schemaVersion") != 1:
        errors.append("Composition manifest schemaVersion must equal 1")
    if manifest.get("bundleSubdirectory") != "USDZ":
        errors.append("Composition manifest bundleSubdirectory must equal 'USDZ'")

    resources = manifest.get("resources")
    if not isinstance(resources, list) or not all(
        isinstance(resource, str) and resource for resource in resources
    ):
        errors.append("Composition manifest resources must be non-empty strings")
        resources = []
    resource_set = set(resources)
    if len(resources) != len(resource_set):
        errors.append("Composition manifest resources must be unique")
    if resource_set != expected_asset_stems:
        missing = sorted(expected_asset_stems - resource_set)
        unexpected = sorted(resource_set - expected_asset_stems)
        errors.append(
            f"Composition resources differ from inventory; missing={missing}, unexpected={unexpected}"
        )

    scenes = manifest.get("scenes")
    if not isinstance(scenes, list):
        errors.append("Composition manifest scenes must be an array")
        return errors, 0

    scene_names: list[str] = []
    placement_count = 0
    for scene in scenes:
        if not isinstance(scene, dict):
            errors.append("Every composition scene entry must be an object")
            continue
        scene_name = scene.get("sceneName")
        placements = scene.get("placements")
        if not isinstance(scene_name, str) or not scene_name:
            errors.append("Every composition scene must have a non-empty sceneName")
            continue
        scene_names.append(scene_name)
        if not isinstance(placements, list):
            errors.append(f"Composition placements for {scene_name} must be an array")
            continue

        anchors: list[str] = []
        semantic_names: list[str] = []
        for placement in placements:
            placement_count += 1
            if not isinstance(placement, dict):
                errors.append(f"Every {scene_name} placement must be an object")
                continue
            anchor_name = placement.get("anchorName")
            resource_name = placement.get("resourceName")
            semantic_name = placement.get("semanticName")
            if not isinstance(anchor_name, str) or not anchor_name.startswith("anchor_"):
                errors.append(f"Invalid composition anchor in {scene_name}: {anchor_name!r}")
            else:
                anchors.append(anchor_name)
            if resource_name not in expected_asset_stems:
                errors.append(
                    f"Unknown loose resource in {scene_name}: {resource_name!r}"
                )
            if not isinstance(semantic_name, str) or not semantic_name:
                errors.append(f"Invalid semanticName in {scene_name}: {semantic_name!r}")
            else:
                semantic_names.append(semantic_name)

        if len(anchors) != len(set(anchors)):
            errors.append(f"Composition anchors must be unique within {scene_name}")
        if len(semantic_names) != len(set(semantic_names)):
            errors.append(f"Composed semantic names must be unique within {scene_name}")

        scene_path = RKASSETS_ROOT / f"{scene_name}.usda"
        if scene_path.is_file():
            authored_anchors = set(
                ANCHOR_PATTERN.findall(scene_path.read_text(encoding="utf-8"))
            )
            declared_anchors = set(anchors)
            if authored_anchors != declared_anchors:
                errors.append(
                    f"Anchor contract mismatch for {scene_name}; "
                    f"authored_only={sorted(authored_anchors - declared_anchors)}, "
                    f"manifest_only={sorted(declared_anchors - authored_anchors)}"
                )

    if len(scene_names) != len(set(scene_names)):
        errors.append("Composition manifest sceneName values must be unique")
    if set(scene_names) != EXPECTED_SCENES:
        errors.append(
            "Composition manifest scenes differ from the required 13 scene contracts"
        )

    return errors, placement_count


def validate() -> int:
    expected, errors = load_expected_assets()
    manifest, manifest_read_errors = load_composition_manifest()
    errors.extend(manifest_read_errors)

    if not LOOSE_ASSET_DESTINATION.is_dir():
        errors.append(f"Loose asset destination is missing: {LOOSE_ASSET_DESTINATION}")
        actual_paths: set[PurePosixPath] = set()
    else:
        actual_paths = {
            PurePosixPath(path.relative_to(LOOSE_ASSET_DESTINATION).as_posix())
            for path in LOOSE_ASSET_DESTINATION.rglob("*")
            if path.is_file() and path.suffix.lower() == ".usdz"
        }

    expected_paths = set(expected)
    for missing_path in sorted(expected_paths - actual_paths, key=str):
        errors.append(f"Missing loose USDZ: {missing_path}")
    for unexpected_path in sorted(actual_paths - expected_paths, key=str):
        errors.append(f"Unexpected loose USDZ: {unexpected_path}")

    verified_count = 0
    total_bytes = 0
    for relative_path in sorted(expected_paths & actual_paths, key=str):
        asset_path = LOOSE_ASSET_DESTINATION / Path(relative_path.as_posix())
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

    catalog_files = [path for path in RKASSETS_ROOT.rglob("*") if path.is_file()]
    catalog_usdz = [path for path in catalog_files if path.suffix.lower() == ".usdz"]
    if catalog_usdz:
        errors.append(
            f"RealityKit catalogue must contain zero USDZ payloads; found {len(catalog_usdz)}"
        )
    non_usda_catalog_files = [
        path for path in catalog_files if path.suffix.lower() != ".usda"
    ]
    if non_usda_catalog_files:
        errors.append(
            "RealityKit catalogue contains non-USDA files: "
            + ", ".join(
                str(path.relative_to(RKASSETS_ROOT)) for path in non_usda_catalog_files
            )
        )

    expected_usda = {f"{name}.usda" for name in EXPECTED_SCENES | EXPECTED_AUTHORED_HELPERS}
    actual_usda = {path.name for path in catalog_files if path.suffix.lower() == ".usda"}
    if actual_usda != expected_usda:
        errors.append(
            f"RealityKit USDA set mismatch; missing={sorted(expected_usda - actual_usda)}, "
            f"unexpected={sorted(actual_usda - expected_usda)}"
        )

    for usda_path in sorted(RKASSETS_ROOT.glob("*.usda")):
        source = usda_path.read_text(encoding="utf-8")
        if ".usdz" in source.lower():
            errors.append(f"USDA must not hard-reference USDZ payloads: {usda_path.name}")

    placement_count = 0
    if manifest:
        manifest_errors, placement_count = validate_manifest(
            manifest, {path.stem for path in expected_paths}
        )
        errors.extend(manifest_errors)

    status = "PASSED" if not errors else "FAILED"
    print(f"Asset validation {status}")
    print(f"Inventory: {INVENTORY_PATH.relative_to(PROJECT_ROOT)}")
    print(f"Loose destination: {LOOSE_ASSET_DESTINATION.relative_to(PROJECT_ROOT)}")
    print(f"Composition manifest: {MANIFEST_PATH.relative_to(PROJECT_ROOT)}")
    print(f"Expected delivery assets: {len(expected)}")
    print(f"Loose USDZ assets verified: {verified_count}")
    print(f"Showcase-only assets: {len(SHOWCASE_ONLY)}")
    print(
        f"Total loose USDZ size: {total_bytes} bytes "
        f"({total_bytes / 1_000_000:.2f} MB; {total_bytes / (1024 * 1024):.2f} MiB)"
    )
    print(f"RealityKit catalogue USDZ payloads: {len(catalog_usdz)}")
    print(
        f"Authored USDA layers: {len(actual_usda)} "
        f"({len(EXPECTED_SCENES)} scene skeletons + "
        f"{len(EXPECTED_AUTHORED_HELPERS)} model/helper layers)"
    )
    print(f"Manifest scene contracts: {len(manifest.get('scenes', [])) if manifest else 0}")
    print(f"Lazy composition placements: {placement_count}")

    if errors:
        print("Errors:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(validate())
