# Reality Composer Pro Workflow

This is the authoring and validation workflow for Lifesaver Vision's local
`RealityKitContent` package. It covers scene layout and project-owned USDA content;
medical logic remains in the app's deterministic, testable services and state machines.

## Recorded environment

These values were recorded in `Docs/BUILD_ENVIRONMENT.md` on 2026-08-07. They are the
authoritative Phase 4 environment record; do not re-probe or silently substitute another
toolchain when following this workflow.

| Item | Recorded value |
|---|---|
| macOS | 26.5.2 (build 25F84), Apple Silicon |
| Xcode | 26.6 (build 17F113), `/Applications/Xcode.app` |
| Reality Composer Pro | The installation bundled with Xcode 26.6 at `/Applications/Xcode.app/Contents/Applications/Reality Composer Pro.app` |
| visionOS SDK | 26.5 (`xros26.5`); simulator SDK `xrsimulator26.5` |
| Primary simulator | Apple Vision Pro, visionOS 26.5, ID `72F30C88-7E77-4710-BC36-4934D3F0809E` |
| Secondary simulator | Apple Vision Pro, visionOS 27.0, ID `76642835-8A23-460F-8A18-567672004162` |
| XcodeGen | 2.46.0 at `/opt/homebrew/bin/xcodegen` |
| App deployment target | visionOS 26.0 |
| Package deployment target | `.visionOS(.v26)`; Swift tools 6.2 |

The installed Reality Composer Pro is identified by its Xcode 26.6 bundle and path in
the recorded environment. No separate standalone RCP marketing-version number was
recorded, so this document does not invent one.

## Authoritative project paths

- Project root: `.../My Drive/macbook/CPR/LifesaverVision`
- Package: `Packages/RealityKitContent/Package.swift`
- RCP content catalogue:
  `Packages/RealityKitContent/Sources/RealityKitContent/RealityKitContent.rkassets`
- Approved copied delivery assets: `RealityKitContent.rkassets/Assets/`
- Showcase-only hardware props: `RealityKitContent.rkassets/Assets/ShowcaseOnly/`
- Runtime bundle handle:
  `Packages/RealityKitContent/Sources/RealityKitContent/RealityKitContent.swift`

`Package.swift` processes the whole `RealityKitContent.rkassets` directory as a package
resource. `project.yml` links the local `RealityKitContent` product into the
`LifesaverVision` visionOS app. Keeping scenes and their referenced USDZ files in this
catalogue lets each top-level scene remain independently loadable through
`realityKitContentBundle`.

## Open the catalogue from Xcode 26.6

1. Generate `LifesaverVision.xcodeproj` with the canonical `xcodegen generate` command.
2. Open the generated project in Xcode 26.6 and wait for the local
   `RealityKitContent` package to resolve. This GUI action requires operator
   verification.
3. In Xcode's Project navigator, expand the local package through
   `Sources/RealityKitContent` and select `RealityKitContent.rkassets`. This GUI action
   requires operator verification.
4. Use Xcode's Reality Composer Pro/open-external-editor action for the `.rkassets`
   catalogue. If Xcode presents only an external-editor action, confirm that it opens
   the bundled app at the recorded path. This GUI action requires operator
   verification.
5. If the Xcode action is unavailable, launch the bundled Reality Composer Pro from
   Xcode's **Xcode > Open Developer Tool** menu (or from the recorded application path),
   choose **File > Open**, and select the project-local `RealityKitContent.rkassets`
   directory. These GUI actions require operator verification.
6. Before editing, confirm the opened catalogue path is inside `LifesaverVision` and is
   not under the read-only asset-library root. This GUI inspection requires operator
   verification.

Do not open or save edits into the external asset library. That source is read-only.
Only approved files already copied into this project's `Assets/` hierarchy may be
referenced by scenes.

## Per-scene editing workflow

The catalogue contains one top-level USDA document for each independently loadable
scene. Edit one scene at a time so a room does not acquire dependencies on unrelated
rooms and runtime instantiation remains scene-scoped.

1. Select the intended top-level scene document in RCP and inspect its hierarchy before
   changing transforms or materials. This GUI action requires operator verification.
2. Confirm the scene's `defaultPrim`, metres scale, Y-up orientation, and referenced
   project-local assets. Do not flatten USDZ references into a monolithic scene. This
   GUI inspection requires operator verification.
3. Preserve every semantic prim name used by runtime lookup and contract tests. Examples
   include `training_manikin`, `sternum_target`, `xiphoid_avoid_zone`,
   `aed_right_pad_zone`, `aed_left_pad_zone`, `aed_case`, `aed_power_button`,
   `aed_connector`, `heart_model`, `lungs_model`, and `clear_zone`.
4. Position content at plausible metre-scale proportions with a calm, non-graphic,
   stylised training aesthetic. Interactive targets must retain comfortable selection
   areas of approximately 4 cm or greater.
5. Keep source visuals and runtime interaction concerns separate. RCP owns authored
   transforms, hierarchy, references, and PBR presentation. The Swift runtime decorator
   owns `InputTargetComponent`, simplified box/capsule collision, hover treatment, and
   localised accessibility labels; never use rendered mesh geometry as collision.
6. Save the scene, close and reopen it, then check that the hierarchy, materials, and
   external references resolve. These GUI actions require operator verification.
7. Validate the package through the canonical Xcode build before moving to another
   scene. A successful package compile validates catalogue/USD syntax but does not prove
   device rendering, interaction, accessibility, or Live Preview.

The Phase 4 scene set is:

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

Use `Docs/RCP_SCENE_MANIFEST.md` as the source-to-scene inventory and semantic-entity
contract. A scene rename is an app API change and must be updated in the manifest,
`AssetRegistry`, app routing, and tests together.

## Content and safety boundaries

- The external asset-library root is read-only. Never modify, rename, delete, re-export,
  or save metadata beside its files; work only with copies inside this repository.
- Do not invoke any external 3D generation service. Original clinical models are
  project-owned USDA or procedural RealityKit geometry authored in this repository.
- Do not add the Red Cross emblem, SRFAC logo, copied manual illustrations, or other
  protected branding. Use the original deep-crimson, warm-white, charcoal, and
  clinical-blue identity.
- Do not turn authored geometry into new medical instructions. Safety-critical text and
  placement must trace to the current approved clinical sources; unresolved decisions
  are marked `requires SME review`.
- The four Vision Pro hardware props remain under `Assets/ShowcaseOnly/` and must not
  appear in clinical lessons or simulations.
- Scenes must not imply physical compression depth or force measurement. Those values
  are `Not physically assessed` unless a verified external `CPRSensorProvider` supplies
  them.
- Any 995 call representation must remain clearly labelled `SIMULATION` and must never
  dial. Completion records are internal records, not SRFAC certification.

## Headless validation

Run asset-integrity validation from the project root before the build:

```bash
/usr/bin/python3 Scripts/validate_assets.py
```

Generate the project and build against the recorded primary simulator. DerivedData must
stay on local storage rather than in the Google Drive project root:

```bash
cd "<project root>"
xcodegen generate
xcodebuild -project LifesaverVision.xcodeproj -scheme LifesaverVision \
  -destination 'platform=visionOS Simulator,id=72F30C88-7E77-4710-BC36-4934D3F0809E' \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/LifesaverVision build
```

Run the test action with the same project, scheme, destination, and DerivedData path:

```bash
xcodebuild -project LifesaverVision.xcodeproj -scheme LifesaverVision \
  -destination 'platform=visionOS Simulator,id=72F30C88-7E77-4710-BC36-4934D3F0809E' \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/LifesaverVision test
```

Record command output and warnings verbatim in the phase report. Do not claim that a
successful build or simulator test proves RCP Live Preview on Apple Vision Pro.

## Live Preview boundary

Reality Composer Pro Live Preview and physical-device review are GUI-only operations.
None was performed by the headless Phase 4 workflow. Complete and retain evidence for
every item in `Docs/RCP_LIVE_PREVIEW_CHECKLIST.md`; each remains **requires operator
verification** until an operator checks it on the intended device.
