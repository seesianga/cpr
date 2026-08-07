#!/usr/bin/env python3
"""Generate the Phase 4R scene manifest from USDA skeletons and lazy-load mapping."""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
RKASSETS = (
    PROJECT_ROOT
    / "Packages"
    / "RealityKitContent"
    / "Sources"
    / "RealityKitContent"
    / "RealityKitContent.rkassets"
)
OUTPUT = PROJECT_ROOT / "Docs" / "RCP_SCENE_MANIFEST.md"
COMPOSITION_MANIFEST = (
    PROJECT_ROOT / "Resources" / "Configuration" / "spatial_asset_manifest_v1.json"
)
LOOSE_ASSETS = PROJECT_ROOT / "Media" / "3D" / "USDZ"
REFERENCE_PATTERN = re.compile(r"@([^@]+)@")


@dataclass(frozen=True)
class SceneRecord:
    name: str
    purpose: str
    entities: str


SCENES = (
    SceneRecord(
        "AcademyLobby",
        "Shared-space academy arrival and module navigation",
        "observatory_environment; portal_m01-m11; companion_orb_bot; control_panel",
    ),
    SceneRecord(
        "HeartAndLungsVolume",
        "Volumetric cardiopulmonary learning laboratory",
        "heart_model with four chambers; lungs_model with left/right lungs",
    ),
    SceneRecord(
        "ChainOfSurvivalVolume",
        "Seven-step spatial learning placeholder pending reviewed lesson copy",
        "chain_ring_1-7",
    ),
    SceneRecord(
        "DRSABCTrainingRoom",
        "Non-graphic danger/response sequence staging",
        "safety_hazards; bystander_01; training_manikin and landmark zones",
    ),
    SceneRecord(
        "CPRPracticeRoom",
        "Hands-only CPR placement and rhythm practice",
        "training_manikin; sternum_target; xiphoid_avoid_zone; clear_zone; control_panel",
    ),
    SceneRecord(
        "AEDPreparationRoom",
        "AED preparation and training-prop familiarisation",
        "training_manikin; aed_trainer; electrode packet; cloth; scissors; razor; glove box",
    ),
    SceneRecord(
        "AEDPlacementRoom",
        "Adult AED pad-placement sequence practice",
        "training_manikin pad zones; AED controls/connectors/pads; clear_zone",
    ),
    SceneRecord(
        "Scenario_Home",
        "Integrated home-response scenario",
        "capstone_environment; manikin; AED trainer; two bystanders; clear_zone",
    ),
    SceneRecord(
        "Scenario_ShoppingCentre",
        "Integrated shopping-centre response scenario",
        "theatre_environment; manikin; AED trainer; two bystanders; clear_zone",
    ),
    SceneRecord(
        "Scenario_Workplace",
        "Integrated workplace response scenario",
        "capstone_environment; manikin; AED trainer; two bystanders; clear_zone",
    ),
    SceneRecord(
        "Scenario_CommunityFacility",
        "Integrated community-facility response scenario",
        "theatre_environment; manikin; AED trainer; two bystanders; clear_zone",
    ),
    SceneRecord(
        "AchievementGallery",
        "Internal progress, achievement, and instructor sign-off display",
        "badge_m01-m14; certificate_pedestal; xp_orb; constellation_star_01-07",
    ),
    SceneRecord(
        "DebriefSpace",
        "Calm immersive review and exit setting",
        "theatre_environment; control_panel",
    ),
)


def referenced_files(layer: Path, visited: set[Path] | None = None) -> set[Path]:
    """Return the unique local USDA/USDZ reference graph rooted at layer."""
    resolved_layer = layer.resolve()
    if visited is None:
        visited = set()
    if resolved_layer in visited:
        return set()
    visited.add(resolved_layer)

    try:
        text = resolved_layer.read_text(encoding="utf-8")
    except OSError as error:
        raise RuntimeError(f"Could not read scene layer {resolved_layer}: {error}") from error

    references: set[Path] = set()
    for value in REFERENCE_PATTERN.findall(text):
        if value.startswith("/"):
            raise RuntimeError(f"Absolute asset reference is prohibited: {value}")
        reference = (resolved_layer.parent / value).resolve()
        try:
            reference.relative_to(RKASSETS.resolve())
        except ValueError as error:
            raise RuntimeError(f"Reference leaves the rkassets catalogue: {value}") from error
        if not reference.is_file():
            raise RuntimeError(f"Missing reference from {resolved_layer.name}: {value}")
        references.add(reference)
        if reference.suffix.lower() == ".usda":
            references.update(referenced_files(reference, visited))

    return references


def load_composition_scenes() -> dict[str, list[dict[str, str]]]:
    try:
        manifest = json.loads(COMPOSITION_MANIFEST.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise RuntimeError(f"Could not read {COMPOSITION_MANIFEST}: {error}") from error

    if manifest.get("schemaVersion") != 1:
        raise RuntimeError("Unsupported spatial composition manifest schema")
    scenes = manifest.get("scenes")
    if not isinstance(scenes, list):
        raise RuntimeError("Spatial composition manifest scenes must be an array")

    result: dict[str, list[dict[str, str]]] = {}
    for scene in scenes:
        if not isinstance(scene, dict):
            raise RuntimeError("Spatial composition scene entries must be objects")
        name = scene.get("sceneName")
        placements = scene.get("placements")
        if not isinstance(name, str) or not isinstance(placements, list):
            raise RuntimeError("Spatial composition scene entry is malformed")
        if name in result:
            raise RuntimeError(f"Duplicate spatial composition scene: {name}")
        result[name] = placements
    return result


def generate() -> str:
    composition_scenes = load_composition_scenes()
    expected_scene_names = {scene.name for scene in SCENES}
    if set(composition_scenes) != expected_scene_names:
        raise RuntimeError("Spatial composition manifest does not cover the required 13 scenes")

    rows: list[str] = []
    for scene in SCENES:
        layer = RKASSETS / f"{scene.name}.usda"
        if not layer.is_file():
            raise RuntimeError(f"Missing required scene layer: {layer}")

        references = referenced_files(layer)
        if any(path.suffix.lower() == ".usdz" for path in references):
            raise RuntimeError(f"{scene.name} still hard-references a USDZ payload")
        authored_layers = ", ".join(sorted(path.stem for path in references))

        placements = composition_scenes[scene.name]
        resource_names = sorted({placement["resourceName"] for placement in placements})
        loose_assets: list[Path] = []
        for resource_name in resource_names:
            asset_path = LOOSE_ASSETS / f"{resource_name}.usdz"
            if not asset_path.is_file():
                raise RuntimeError(f"Missing loose payload for {scene.name}: {asset_path}")
            loose_assets.append(asset_path)
        lazy_resources = ", ".join(resource_names)
        loose_bytes = sum(path.stat().st_size for path in loose_assets)
        rows.append(
            "| "
            + " | ".join(
                (
                    f"`{scene.name}`",
                    scene.purpose,
                    scene.entities,
                    authored_layers or "Original primitives only",
                    lazy_resources or "None",
                    f"{loose_bytes / 1_000_000:.2f}",
                )
            )
            + " |"
        )

    return "\n".join(
        (
            "# RCP Scene Manifest",
            "",
            "Generated by `Scripts/generate_rcp_scene_manifest.py` from the 13 authored USDA scene",
            "skeletons, their recursive authored USDA references, and `spatial_asset_manifest_v1.json`.",
            "Regenerate after a scene, anchor, or lazy-load mapping change.",
            "",
            "`AssetRegistry` first requests each lightweight skeleton with `Entity(named:in:)`, then",
            "loads only that scene's mapped loose USDZ payloads from `Bundle.main` with",
            "`Entity(contentsOf:)` and attaches them to named `anchor_*` entities. The composed root is",
            "cached only for the active scene and explicitly evicted on exit. Loose resources are",
            "shared across rows, so the MB column is not additive and is not a memory-residency claim.",
            "",
            "| Scene | Purpose | Key entities | Authored USDA dependencies | Lazy USDZ payloads | Approx loose MB (shared) |",
            "|---|---|---|---|---|---:|",
            *rows,
            "",
            "## Packaging and verification notes",
            "",
            "- The package catalogue contains 13 scene skeletons and six hand-authored model/helper",
            "  layers, with no USDZ payloads or USDZ reference arcs.",
            "- All 50 approved delivery files are loose app resources under source path",
            "  `Media/3D/USDZ` and bundle subdirectory `USDZ`. Thirty-six unique payloads are mapped",
            "  into 47 scene placements; the other 14 remain independently runtime-audited.",
            "- The four hardware props remain showcase-only and are absent from every scene mapping.",
            "- Imported assets were authored Z-up. Scene instances carry an initial `-90` degree",
            "  X-axis correction; final orientation, scale, occlusion, and comfort require operator",
            "  verification in RCP Live Preview and on Apple Vision Pro.",
            "- Original clinical layers use metres, Y-up, brand-neutral PBR materials, and named",
            "  semantic prims. Geometry is non-graphic and does not assess physical compression",
            "  depth or force.",
            "- `AchievementGallery` displays internal completion records only; it does not represent",
            "  SRFAC certification.",
            "",
        )
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--check",
        action="store_true",
        help="Fail when Docs/RCP_SCENE_MANIFEST.md is not current.",
    )
    arguments = parser.parse_args()

    try:
        generated = generate()
    except RuntimeError as error:
        print(f"Scene manifest generation FAILED: {error}", file=sys.stderr)
        return 1

    if arguments.check:
        try:
            existing = OUTPUT.read_text(encoding="utf-8")
        except OSError as error:
            print(f"Scene manifest check FAILED: {error}", file=sys.stderr)
            return 1
        if existing != generated:
            print("Scene manifest check FAILED: regenerate the manifest", file=sys.stderr)
            return 1
        print(f"Scene manifest check PASSED: {len(SCENES)} scenes")
        return 0

    OUTPUT.write_text(generated, encoding="utf-8")
    print(f"Wrote {OUTPUT.relative_to(PROJECT_ROOT)} for {len(SCENES)} scenes")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
