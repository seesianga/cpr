# Phase 4 — RealityKit Content and Scenes Report

Date: 8 August 2026

Product: `Lifesaver Vision: CPR + AED Spatial Academy`

Platform: visionOS 26.5 simulator

Simulator: `72F30C88-7E77-4710-BC36-4934D3F0809E`

## Result

Phase 4 is implemented, compiled, and simulator-tested. All 50 approved delivery USDZ
files were copied into the project without changing the read-only source library and
match the recorded SHA-256 values. Five original, non-graphic clinical USDA model layers
and 13 independently loadable scenes now compile into the RealityKit package. The app
loads the cardiopulmonary learning volume and a selected immersive simulation through a
graceful `AssetRegistry` path, with semantic lookup and runtime input, simplified
collision, hover, and accessibility decoration.

The final canonical build succeeded. The complete `LifesaverVisionTests` target executed
66 tests with zero failures, including five Phase 4 tests that load all 50 imported
resources and all 13 scenes from the compiled catalogue on the specified visionOS
simulator. Headless runtime probes also resolved the independent semantic contract for
all 13 scenes and confirmed that replacement ring, clear-zone, and scissors geometry has
non-empty RealityKit bounds.

This is a technical package, simulator-runtime, and source-integrity pass. It is not
Reality Composer Pro Live Preview evidence, physical-device usability evidence, or
clinical sign-off. All GUI and on-device steps remain explicitly marked **requires
operator verification**.

## What Was Built

### Milestone 4.1 — asset import

- Copied all 50 approved `USDZ_Delivery` files into
  `Packages/RealityKitContent/Sources/RealityKitContent/RealityKitContent.rkassets/Assets`.
- Kept 46 general-use assets at `Assets/` and isolated the four Vision Pro hardware
  props under `Assets/ShowcaseOnly/`. No clinical scene references that subgroup.
- Chose the package `.rkassets` catalogue instead of an app-level `Media/3D/USDZ` copy.
  Xcode processes this catalogue into the package's `RealityKitContent.reality`, and
  scene references remain local to the content package.
- Added `Scripts/validate_assets.py`. It derives the expected delivery path from
  `Docs/asset_inventory_raw.json`, rejects symlinks, missing or extra files, and checks
  every byte count and SHA-256 digest.
- Updated `Docs/ASSET_REUSE_REPORT.md` with 46 `copied`, four `showcase-only`, and zero
  `excluded` statuses.

The source asset root remained read-only. No external 3D generation API, SDK, or CLI was
called or installed.

### Milestone 4.2 — original clinical models

Hand-authored metre-scale, Y-up USDA layers use primitive geometry and PBR
`UsdPreviewSurface` materials:

- `TrainingManikin.usda`: `training_manikin`, lower-half `sternum_target`,
  `xiphoid_avoid_zone`, `aed_right_pad_zone`, and `aed_left_pad_zone`. Anatomical right
  is the manikin's right; the right pad zone is below the right collarbone, while the
  left zone is below and lateral to the left nipple/armpit-nipple line.
- `AEDTrainer.usda`: `aed_case`, `aed_unit`, power button, status light, connector,
  training-pad parents and mesh aliases, packet, cloth, scissors, razor, and glove box.
- `HeartAndLungs.usda`: selectable right/left atria, right/left ventricles, and left/right
  lungs under `heart_model` and `lungs_model`.
- `Bystander.usda`: abstract, non-graphic `bystander_01` silhouette; scenes may create a
  second referenced instance named `bystander_02`.
- `ClearZone.usda`: segmented floor ring under `clear_zone`.

Interactive runtime collision dimensions are clamped to at least 4 cm. Only generated
box or capsule shapes are used; rendered meshes are never used as collision geometry.

### Milestone 4.3 — Reality Composer Pro scenes

The catalogue contains the 13 requested top-level scenes:

- `AcademyLobby`
- `HeartAndLungsVolume`
- `ChainOfSurvivalVolume`
- `DRSABCTrainingRoom`
- `CPRPracticeRoom`
- `AEDPreparationRoom`
- `AEDPlacementRoom`
- `Scenario_Home`
- `Scenario_ShoppingCentre`
- `Scenario_Workplace`
- `Scenario_CommunityFacility`
- `AchievementGallery`
- `DebriefSpace`

Each scene is independently requested by name. The package compiles the full catalogue
into one `.reality` archive, so this is lazy scene instantiation, not a claim of
byte-range, network, or literal USD payload streaming. The authored scenes use local USD
references. `Docs/RCP_SCENE_MANIFEST.md` records each scene's purpose, key entities,
recursive sources, and approximate shared source size.

An important runtime correction was made after archive inspection: RealityKit accepted
authored `Torus` prims during compilation but dropped them from the loaded hierarchy.
`RingPlaceholder.usda`, the clear-zone ring, and scissors handles now use supported
capsule-composed geometry. Simulator probes verify those replacements survive loading
and have non-empty bounds.

### Milestone 4.4 — Swift integration

- Added `SpatialSceneName` with all 13 exact resource names and a default simulation
  choice of `CPRPracticeRoom` in `AppModel`.
- Added an async, main-actor `AssetRegistry` using `realityKitContentBundle` with typed,
  learner-safe missing-resource errors and cancellation preservation.
- Added recursive first/all/required semantic-entity lookup helpers.
- Added preflighted runtime decoration with `InputTargetComponent`, box/capsule-only
  `CollisionComponent`, `HoverEffectComponent`, and `AccessibilityComponent` labels and
  descriptions.
- Replaced the learning-lab placeholder with a `RealityView` that loads and decorates
  `HeartAndLungsVolume`, with progress and calm error states.
- Replaced the immersive placeholder with a selected-scene `RealityView`, keeping the
  head-anchored SIMULATION, Pause/Resume, and Exit controls visible. Exit remains
  available if scene loading fails; Pause/Resume is disabled until loading succeeds.

### Milestone 4.5 — documentation

Added or completed:

- `Docs/REALITY_COMPOSER_PRO_WORKFLOW.md`
- `Docs/RCP_SCENE_MANIFEST.md`
- `Docs/RCP_LIVE_PREVIEW_CHECKLIST.md`
- `Docs/ASSET_REUSE_REPORT.md`
- `Docs/ASSET_PROVENANCE.md`
- `Docs/BUILD_ENVIRONMENT.md`
- `Scripts/generate_rcp_scene_manifest.py`

The workflow records macOS 26.5.2, Xcode 26.6, the Reality Composer Pro installation
bundled with Xcode 26.6, visionOS SDK 26.5, XcodeGen 2.46.0, and the canonical simulator.
It does not invent a separate RCP marketing version. Every one of the 52 GUI checklist
items contains the literal `requires operator verification`.

### Milestone 4.6 — tests and build integration

- Wired `Scripts/validate_assets.py` as an always-run pre-build phase in `project.yml`
  and regenerated `LifesaverVision.xcodeproj`.
- Added a compiled-archive presence test.
- Added injected and real-catalogue missing-resource tests for the graceful error path.
- Added runtime loading and independent semantic-contract validation for all 13 scenes.
- Decorated every registry target during the scene test and asserted input, non-empty
  simplified collision, hover, and accessibility components.
- Loaded all 50 delivery resources by their canonical compiled catalogue paths, including
  the four `Assets/ShowcaseOnly/...` resources.

Reality Composer Pro compiles catalogue inputs into `RealityKitContent.reality`; raw
`.usdz` files are not independently copied into the final app bundle. Therefore the
asset-presence test performs real `Entity(named:in:)` loads for all 50 canonical
catalogue names, while the pre-build validator proves the source-copy hashes.

## Verification Commands and Verbatim Results

All project commands were run from the repository root. DerivedData remained outside
the Google Drive checkout.

### Imported-asset integrity

```sh
/usr/bin/python3 Scripts/validate_assets.py
```

Verbatim result:

```text
Asset validation PASSED
Inventory: Docs/asset_inventory_raw.json
Destination: Packages/RealityKitContent/Sources/RealityKitContent/RealityKitContent.rkassets/Assets
Expected delivery assets: 50
Copied assets verified: 50
Showcase-only assets: 4
Total bundle size: 141007707 bytes (141.01 MB; 134.48 MiB)
```

### Scene manifest and USDA source checks

```sh
/usr/bin/python3 Scripts/generate_rcp_scene_manifest.py --check

set -e
for scene_file in \
  Packages/RealityKitContent/Sources/RealityKitContent/RealityKitContent.rkassets/*.usda
do
  /usr/bin/usdchecker "$scene_file" >/dev/null
done

/usr/bin/python3 - <<'PY'
from pathlib import Path
root = Path("Packages/RealityKitContent/Sources/RealityKitContent/RealityKitContent.rkassets")
files = sorted(root.glob("*.usda"))
unsupported = [path.name for path in files if "def Torus" in path.read_text()]
print(f"usdchecker_files={len(files)}")
print(f"unsupported_torus_files={len(unsupported)}")
raise SystemExit(bool(unsupported))
PY

/usr/bin/python3 - <<'PY'
from pathlib import Path
path = Path("Docs/RCP_LIVE_PREVIEW_CHECKLIST.md")
items = [line for line in path.read_text().splitlines() if line.lstrip().startswith("- [")]
missing = [line for line in items if "requires operator verification" not in line]
print(f"checklist_items={len(items)}")
print(f"missing_required_literal={len(missing)}")
raise SystemExit(bool(missing))
PY
```

Verbatim summaries:

```text
Scene manifest check PASSED: 13 scenes
usdchecker_files=20
unsupported_torus_files=0
checklist_items=52
missing_required_literal=0
```

All 20 `usdchecker` invocations exited successfully. The command emitted Apple USD
plug-in registration diagnostics described under Warnings.

### Project generation

```sh
/opt/homebrew/bin/xcodegen generate
```

Verbatim result:

```text
⚙️  Generating plists...
⚙️  Generating project...
⚙️  Writing project...
Created project at /Users/angseesiang/Library/CloudStorage/GoogleDrive-ang.see.siang@gmail.com/My Drive/macbook/CPR/LifesaverVision/LifesaverVision.xcodeproj
```

### Full canonical build

```sh
xcodebuild -project LifesaverVision.xcodeproj -scheme LifesaverVision \
  -destination 'platform=visionOS Simulator,id=72F30C88-7E77-4710-BC36-4934D3F0809E' \
  -derivedDataPath "$HOME/Library/Developer/Xcode/DerivedData/LifesaverVision" build
```

Verbatim result lines:

```text
Asset validation PASSED
Expected delivery assets: 50
Copied assets verified: 50
Showcase-only assets: 4
Total bundle size: 141007707 bytes (141.01 MB; 134.48 MiB)
warning: Metadata extraction skipped. No AppIntents.framework dependency found.
note: Run script build phase 'Validate imported RealityKit delivery assets' will be run during every build because the option to run the script phase "Based on dependency analysis" is unchecked.
** BUILD SUCCEEDED **
```

### Focused Phase 4 simulator tests

```sh
xcodebuild -project LifesaverVision.xcodeproj -scheme LifesaverVision \
  -destination 'platform=visionOS Simulator,id=72F30C88-7E77-4710-BC36-4934D3F0809E' \
  -derivedDataPath "$HOME/Library/Developer/Xcode/DerivedData/LifesaverVision" \
  test -only-testing:LifesaverVisionTests/RealityKitAssetTests
```

Verbatim result lines:

```text
Test Suite 'RealityKitAssetTests' passed at 2026-08-08 00:12:43.870.
     Executed 5 tests, with 0 failures (0 unexpected) in 25.958 (25.981) seconds
** TEST SUCCEEDED **
```

### Complete LifesaverVisionTests target

```sh
xcodebuild -project LifesaverVision.xcodeproj -scheme LifesaverVision \
  -destination 'platform=visionOS Simulator,id=72F30C88-7E77-4710-BC36-4934D3F0809E' \
  -derivedDataPath "$HOME/Library/Developer/Xcode/DerivedData/LifesaverVision" \
  test -only-testing:LifesaverVisionTests
```

Verbatim result lines:

```text
Test Suite 'LifesaverVisionTests.xctest' passed at 2026-08-08 00:14:40.980.
     Executed 66 tests, with 0 failures (0 unexpected) in 34.242 (34.397) seconds
Test Suite 'All tests' passed at 2026-08-08 00:14:40.981.
     Executed 66 tests, with 0 failures (0 unexpected) in 34.242 (34.401) seconds
** TEST SUCCEEDED **
```

Result bundle:

```text
/Users/angseesiang/Library/Developer/Xcode/DerivedData/LifesaverVision/Logs/Test/Test-LifesaverVision-2026.08.08_00-13-14-+0800.xcresult
```

### Supplemental compiled-catalogue runtime audit

The final Phase 4 Debug-Beta package bundle was additionally inspected and loaded by an
actual visionOS Simulator process. A one-off probe compiled with `xcrun --sdk
xrsimulator swiftc` for `arm64-apple-xros26.0-simulator` and ran with `xcrun simctl
spawn` on the canonical simulator. Its source was temporary, so this is supplemental
audit evidence; the committed `RealityKitAssetTests.swift` suite above is the durable,
reproducible acceptance test.

Verbatim summaries:

```text
XR_ASYNC_ENTITY_NAMED_RESULT passed=63 failed=0 total=63
XR_SEMANTIC_CONTRACT_RESULT scenes=13 failures=0
XR_REPLACEMENT_GEOMETRY_RESULT pass
```

The 63 loads comprise 13 top-level scenes and 50 canonical imported-resource names.
Static archive inspection also found all 50 imported entries, all 13 required scenes,
70 compiled scenes/layers in total, and zero differences between `assetMap.json` and the
compiled scene entries. The final archive reports RealityKit `403.120.2`, origin
`VisionOS`, and target `All`.

### Isolated Phase 3B size baseline

Commit `868b595` was checked out in a detached temporary worktree, generated, and built
with a separate temporary DerivedData directory. The main worktree and its DerivedData
were not used for the baseline build.

```sh
git worktree add --detach /tmp/lifesavervision-phase3b.wN3Uvf/worktree 868b595
cd /tmp/lifesavervision-phase3b.wN3Uvf/worktree
/opt/homebrew/bin/xcodegen generate
/usr/bin/xcodebuild -project LifesaverVision.xcodeproj -scheme LifesaverVision \
  -configuration Debug-Beta \
  -destination 'platform=visionOS Simulator,id=72F30C88-7E77-4710-BC36-4934D3F0809E' \
  -derivedDataPath /tmp/lifesavervision-phase3b.wN3Uvf/DerivedData build
```

Verbatim build result lines and measured sizes:

```text
warning: Metadata extraction skipped. No AppIntents.framework dependency found.
** BUILD SUCCEEDED **
phase3b_archive_bytes=4511
phase3b_app_regular_file_bytes=11397357
phase3b_app_allocated_kib=11184
```

The detached worktree was then removed and the remaining temporary root moved to Trash.
`git worktree list` contained only the main worktree afterward.

## Bundle Size and Delta

The source catalogue contains 70 files: 50 USDZs and 20 USDA scene/model/helper layers.
The Phase 3B baseline at commit `868b595` contained only the 102-byte template
`Scene.usda`. Source-catalogue growth is therefore 141,068,860 bytes.

| Measurement | Phase 3B (`868b595`) | Phase 4 | Delta |
|---|---:|---:|---:|
| `.rkassets` source regular-file bytes | 102 | 141,068,962 | +141,068,860 |
| Compiled `RealityKitContent.reality` bytes | 4,511 | 716,251,834 | +716,247,323 |
| Built Debug-Beta simulator app, regular-file bytes | 11,397,357 | 728,000,264 | +716,602,907 |
| Built Debug-Beta simulator app, allocated KiB (`du -sk`) | 11,184 | 710,992 | +699,808 |

The copied delivery inputs account for 141,007,707 source bytes (141.01 decimal MB,
134.48 MiB). The compiled `.reality` archive is larger because RealityKit transforms the
catalogue into its runtime representation; it is not a byte-for-byte USDZ copy. This is
a Debug-Beta simulator measurement, not a Release-Stable/device download-size claim.
The compiled archive delta is approximately 683.067 MiB, while the app regular-file
payload delta is approximately 683.406 MiB.

## Warnings and Operational Notes

- Xcode emitted `warning: Metadata extraction skipped. No AppIntents.framework
  dependency found.` The app does not use App Intents, so a dependency was not added
  merely to suppress this tooling warning.
- The complete test build retained one pre-existing Swift warning at
  `Tests/AuthenticationAndReportTests.swift:50:29`: `no calls to throwing functions
  occur within 'try' expression`.
- Headless RealityKit loads logged repeated `[Assets] Failed to set dependencies ...
  NetworkAssetManager...` diagnostics. All requested entities still completed loading,
  all semantic/component assertions passed, and the test action exited successfully.
  These remain unresolved simulator diagnostics: their visual/material impact was not
  assessed and requires operator verification.
- `/usr/bin/usdchecker` emitted repeated `UsdShade Connectable behavior already
  registered` coding-error diagnostics while returning success for all 20 files. The
  independent Xcode RealityKit compile and simulator runtime loads are the stronger
  acceptance evidence.
- Imported delivery layers report Z-up. Authored scene instances carry a `-90` degree
  X-axis correction; final visual orientation and scale still require RCP/device review.
- The intentionally unrelated untracked file
  `Docs/reports/AUDIT_FINDINGS_CONTENT_V1.md` was not edited or included in Phase 4
  commits.

## Honest Limitations and Required Operator Work

- Reality Composer Pro Live Preview was not run, and no Apple Vision Pro physical-device
  session was performed. All GUI, spatial-comfort, readability, occlusion, material,
  scale, reach, and performance checks in `Docs/RCP_LIVE_PREVIEW_CHECKLIST.md` remain
  **requires operator verification**.
- Simulator entity loading proves that named hierarchies and components resolve; it does
  not prove comfortable gaze/pinch selection. Several decorated parents and children
  have overlapping collision proxies, and the `clear_zone` parent receives a bounding
  box around its segmented ring. Selection priority and accessibility traversal require
  operator testing.
- The Pause control records app state and enables/disables the app-owned scene root. No
  complete `ScenarioEngine`, timer, audio, or animation pipeline exists in this phase,
  so this report does not claim that every future simulation subsystem is frozen.
- The catalogue supports independent `Entity(named:in:)` instantiation from one compiled
  `.reality` archive. It does not prove byte-range/network streaming or literal USD
  payload-arc loading.
- Imported USDZ files remain untouched and Z-up. Their authored USDA scene instances
  receive the `-90` degree X-axis rotation; final orientation, metre-scale plausibility,
  and device comfort require visual review.
- The app UI and `RealityView` presentation were not launched or visually exercised on
  the simulator. Unit tests and supplemental probes loaded catalogue entities directly;
  actual view presentation and control behaviour require operator verification.
- Original models are respectful stylised training aids, not diagnostic anatomy. The
  seven chain rings are named geometry placeholders; reviewed learner-facing ring copy
  remains subject to the existing clinical content lifecycle.
- There is no clinical sign-off in this phase. Completion remains an internal learning
  record, never SRFAC certification; practical competency still requires instructor
  sign-off.
- No hand-tracking path measures physical compression depth or force. Those remain `Not
  physically assessed` unless a verified external `CPRSensorProvider` supplies data.
- Any 995 experience remains a labelled `SIMULATION` and never places a call.
- The Debug-Beta simulator archive is approximately 716 MB. Release/device optimisation,
  memory residency, frame rate, thermal behaviour, and App Store download size were not
  measured.

## Milestone Commits

```text
0323d7e Phase 4.1: import approved RealityKit assets
8d5be59 Phase 4.2: author original clinical models
b83118b Phase 4.3: compose RealityKit academy scenes
299bab5 Phase 4.4: integrate spatial scene loading
2e7fb3b Phase 4.3: preserve runtime scene geometry
2e8b8d0 Phase 4.5: document Reality Composer Pro workflow
ac0a456 Phase 4.4: complete AED semantic decoration
4038463 Phase 4.6: validate RealityKit assets and scenes
```

The final report handoff is committed separately with the required message
`Phase 4: RealityKit content + scenes`.

## Phase 4R.1 Addendum — Loose, Scene-Scoped Asset Loading

This addendum, verified 2026-08-08 on the recorded visionOS 26.5 simulator, supersedes
the Phase 4 packaging and size statements above while retaining them as historical
baseline evidence. The 50 approved delivery USDZs are now flat source resources under
`Media/3D/USDZ` and are copied into app-bundle subdirectory `USDZ/`. The compiled
RealityKit catalogue contains zero USDZs: only the 13 scene skeletons and six original
hand-authored model/helper USDA layers remain.

The 13 skeletons contain no USDZ reference arcs. Forty-seven original transforms now
live on empty, named `anchor_*` prims. `spatial_asset_manifest_v1.json` maps those
placements to 36 unique loose payloads. `AssetRegistry` loads the skeleton, asynchronously
decodes only the scene's mapped USDZs with `Entity(contentsOf:)`, renames payload roots to
preserve semantic contracts, attaches them to the anchors, and caches the composed root.
The volumetric and immersive views explicitly evict and detach that root on exit. The 14
currently unmapped resources remain packaged and independently runtime-audited.

This is scene-scoped runtime decoding and memory release. It is not an on-demand download,
byte-range streaming claim, or removal of the 141,007,707 source USDZ bytes from the app.

### Before/after Debug-Beta simulator package

Both app measurements use the same canonical DerivedData path and the Debug-Beta product.

| Measurement | Phase 4 before | Phase 4R.1 after | Delta |
|---|---:|---:|---:|
| App regular-file bytes | 728,000,264 (694.28 MiB) | 155,255,729 (148.06 MiB) | -572,744,535 (-546.21 MiB) |
| App allocated KiB (`du -sk`) | 710,992 | 151,764 | -559,228 |
| `RealityKitContent.reality` bytes | 716,251,834 (683.07 MiB) | 2,351,118 (2.24 MiB) | -713,900,716 |
| Loose bundled USDZ files | 0 | 50 / 141,007,707 bytes | +50 / +141,007,707 bytes |

The app regular-file payload fell 78.67% and is below the requested approximate 300 MB
target.

### Verification evidence

`Scripts/validate_assets.py` result:

```text
Asset validation PASSED
Expected delivery assets: 50
Loose USDZ assets verified: 50
Total loose USDZ size: 141007707 bytes (141.01 MB; 134.48 MiB)
RealityKit catalogue USDZ payloads: 0
Authored USDA layers: 19 (13 scene skeletons + 6 model/helper layers)
Manifest scene contracts: 13
Lazy composition placements: 47
```

Canonical build result:

```text
warning: Metadata extraction skipped. No AppIntents.framework dependency found.
** BUILD SUCCEEDED **
```

The simulator runtime asset suite loaded all 50 loose resources plus all 13 composed
scenes (63 resource contracts total), validated all authored semantic targets and runtime
interaction/accessibility decorations, and exercised missing-anchor handling plus explicit
cache eviction:

```text
Test Suite 'RealityKitAssetTests' passed at 2026-08-08 00:48:52.567.
     Executed 8 tests, with 0 failures (0 unexpected) in 87.333 (87.357) seconds
Test Suite 'Selected tests' passed at 2026-08-08 00:48:52.569.
     Executed 8 tests, with 0 failures (0 unexpected) in 87.333 (87.363) seconds
** TEST SUCCEEDED **
```

The simulator continued to log RealityKit `NetworkAssetManager` dependency diagnostics
during successful loads. No RCP Live Preview or physical-device visual, comfort, memory,
frame-rate, or thermal verification was performed; those operator gates remain open.

### Phase 4R.3 final measurement note

After Phase 4R.2 embedded the complete scenario definitions for fail-closed runtime
clinical validation, the final Debug-Beta app measures 156,456,890 regular-file bytes
(149.21 MiB) and 152,936 allocated KiB. The RealityKit archive remains 2,351,118 bytes,
all 50 loose USDZs remain present, and the overall reduction from the Phase 4 baseline is
78.51%. The final complete `LifesaverVisionTests` run executed 76 tests with zero
failures, including the eight-test 63-resource audit. The audit findings document that
was intentionally outside the historical Phase 4 commits is now tracked in the Phase
4R.2 remediation commit.
