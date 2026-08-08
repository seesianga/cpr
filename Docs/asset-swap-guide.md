# Swapping practice assets (manikin, defibrillator, patches)

The spatial practice experiences resolve every semantic entity through one seam:
`PracticeAssetDescriptor` (`Spatial/RealityKit/PracticeAssetDescriptor.swift`), held by
`AssetRegistry.practiceAssetDescriptor`. The current procedural/USDA assets are described
by `PracticeAssetDescriptor.placeholderDescriptor` — the only place their entity-name
literals live.

## What a new asset set needs

1. **USDZ / USDA content** exposing named entities for the semantic slots below.
2. **A descriptor JSON** (decoded with `PracticeAssetDescriptor.decode(from:)`) mapping
   slot → entity name for that asset set.
3. Nothing else: the torso grid re-derives itself from the new body's bounds at scene
   load, so anatomical regions land correctly on ANY body scale without code changes
   (verified by `GridGestureTests.testGridRegionsAreScaleInvariantAcrossBodySizes`).

## Descriptor JSON shape

```json
{
  "body": {
    "torsoRootEntityName": "torso_shell",
    "figureEntityName": "training_manikin",
    "sternumTargetEntityName": "sternum_target",
    "xiphoidAvoidZoneEntityName": "xiphoid_avoid_zone",
    "landmarkEntityNames": [
      "landmark_sternum", "landmark_xiphoid",
      "landmark_right_clavicle", "landmark_left_lower_ribs"
    ]
  },
  "defibrillator": {
    "unitEntityName": "aed_unit",
    "powerButtonEntityName": "aed_power_button",
    "shockButtonEntityName": "aed_shock_button",
    "connectorEntityName": "aed_connector",
    "statusLightEntityName": "aed_status_light"
  },
  "patches": {
    "rightPadEntityName": "aed_right_pad",
    "leftPadEntityName": "aed_left_pad",
    "rightPadZoneEntityName": "aed_right_pad_zone",
    "leftPadZoneEntityName": "aed_left_pad_zone"
  },
  "gridDescriptorOverride": null
}
```

## The body slot and the torso grid

- `torsoRootEntityName` must name the TORSO geometry, not the whole figure — limbs,
  head, or a base mat would skew the grid bounds.
- The grid is expressed in normalized coordinates over the torso's frontal plane:
  u ∈ [0,1] patient-right → patient-left, v ∈ [0,1] head → feet, w depth. Region
  definitions contain no metres (`BodyGridDescriptor`).
- The default grid (`BodyGridDescriptor.placeholderDefault`, 8 columns × 10 rows)
  assumes the placeholder axis convention: supine, head toward local −Z, patient's
  anatomical right toward −X, chest up +Y. An asset authored differently must ship a
  `gridDescriptorOverride` declaring its own
  `lateralAxisTowardPatientLeft` / `longitudinalAxisTowardFeet` / `anteriorAxis` and,
  if needed, adjusted region rectangles. Region source references are policy data;
  keep them source-backed and flag interpretive mappings `requires_sme_review`.
- **Landmarks beat proportions.** If the asset provides `landmark_sternum`,
  `landmark_xiphoid`, `landmark_right_clavicle`, or `landmark_left_lower_ribs`
  entities, the matching region recentres on the landmark at load
  (the right-clavicle pad region shifts caudally by half its height so it sits below
  the clavicle). Proportional defaults apply otherwise.
- `sternumTargetEntityName` / `xiphoidAvoidZoneEntityName` remain VISUAL affordances
  and the detection fallback when no torso grid can be derived; with a grid, detection
  volumes come from the grid.

## Defibrillator and patches

- The power button and both patches are pinch-grabbable; `AssetRegistry.pinchGrabItems`
  resolves their world positions through the descriptor.
- Patch release snapping, placement-error math, and correct-region enforcement are
  asset-independent (grid regions + `AEDStateMachine`); pad zones stay as visual guides.

## Developer aids

- DEBUG builds can render the derived grid over the torso: set the
  `developer.showTorsoGridOverlay` user default (off by default; compiled out of
  release). See `TorsoGridDebugOverlay`.
