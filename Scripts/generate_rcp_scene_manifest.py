#!/usr/bin/env python3
"""Generate the Phase 4 RCP scene manifest from authored USDA references."""

from __future__ import annotations

import argparse
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


def display_name(path: Path) -> str:
    relative = path.relative_to(RKASSETS)
    if relative.parts[0] == "Assets":
        return relative.with_suffix("").as_posix()
    return relative.stem


def generate() -> str:
    rows: list[str] = []
    for scene in SCENES:
        layer = RKASSETS / f"{scene.name}.usda"
        if not layer.is_file():
            raise RuntimeError(f"Missing required scene layer: {layer}")

        references = referenced_files(layer)
        source_assets = ", ".join(sorted(display_name(path) for path in references))
        referenced_bytes = layer.stat().st_size + sum(path.stat().st_size for path in references)
        rows.append(
            "| "
            + " | ".join(
                (
                    f"`{scene.name}`",
                    scene.purpose,
                    scene.entities,
                    source_assets or "Original primitives only",
                    f"{referenced_bytes / 1_000_000:.2f}",
                )
            )
            + " |"
        )

    return "\n".join(
        (
            "# RCP Scene Manifest",
            "",
            "Generated by `Scripts/generate_rcp_scene_manifest.py` from the 13 authored USDA",
            "layers and their recursive local references. Regenerate after any scene reference change.",
            "",
            "Each layer is independently requested with `Entity(named:in:)`; Xcode packages the whole",
            "catalogue into one `RealityKitContent.reality` archive. This supports lazy scene",
            "instantiation, but the table does not claim byte-range or network streaming. Imported",
            "resources are shared, so the referenced MB column is not additive across rows and is not",
            "the final compiled archive size.",
            "",
            "| Scene | Purpose | Key entities | Source assets/layers | Approx referenced MB (shared) |",
            "|---|---|---|---|---:|",
            *rows,
            "",
            "## Packaging and verification notes",
            "",
            "- Imported delivery assets are under `RealityKitContent.rkassets/Assets`; the four",
            "  hardware props are isolated under `Assets/ShowcaseOnly` and are absent from all",
            "  clinical-scene reference graphs.",
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
