# Report — Anatomical grid + finger-node interaction + guided AED/CPR sequence

Spec: `Docs/tasks/2026-08-08-grid-gesture-SPEC.md`. Status: **complete**; all suites
green (264 tests total: 262 unit + 2 UI, 0 failures), canonical simulator build passing.
No git commits were made.

Starting point: the working tree already carried partial D3/D4 edits (AEDStateMachine
physical-pad event, AEDPracticeSessionModel guided-CPR wiring, ScoringEngine/Debrief
changes) referencing a `TorsoRegionID` type that did not exist — the tree did not
compile. This phase built the missing D1/D2/D5 foundations, completed and fixed the
in-flight D3/D4 work, added D6 tests, and verified everything end to end.

## D1 — Scale-invariant torso grid (`Spatial/BodyGrid/`)

`TorsoGridMap.swift` (new):

- `TorsoRegionID`: `padSiteRightClavicle`, `padSiteLeftLateral`,
  `sternumCompressionSite`, `xiphoidAvoidZone`.
- `NormalizedRegionRect` — regions as center/size rects in normalized coordinates:
  u ∈ [0,1] patient-right → patient-left, v ∈ [0,1] head → feet, w depth. No metres in
  region definitions; two bodies of different physical size resolve identical
  normalized placement (unit-tested).
- `BodyGridDescriptor` — 8×10 default grid, the asset's anatomical axis convention
  (`lateralAxisTowardPatientLeft` etc.; the placeholder manikin is authored supine,
  head −Z, patient-right −X), the region rects, and `SourceReference`s. Region rects
  were derived from `CA-Manual-REV-1-2022.pdf` §2.2(C) p.20 (compression site) and
  §3.4 p.34 (pad placement) via the authored placeholder zones; because prose → rect
  is interpretive, both references carry `reviewStatus: "requires_sme_review"`.
- Landmark override: `landmark_sternum` / `landmark_xiphoid` /
  `landmark_right_clavicle` / `landmark_left_lower_ribs` entities recentre their
  region when present (clavicle landmark shifts its pad region caudally by half the
  region height, since the region belongs BELOW the clavicle). Landmarks beat
  proportional defaults; unit-tested.
- `worldVolume(for:)` bridges regions to the existing `HandTrackingTargetVolume`
  math in metres (the volume's local frame is orthonormalized so detector margins
  keep physical meaning even for non-uniformly scaled torso transforms).
  `snapResolution(forWorld:)` returns region, region-normalized error (1.0 = region
  boundary — matching `PhysicalPerformancePolicy.padErrorAtZeroScore = 1`), and the
  anterior-surface snap position.
- Debug overlay (`TorsoGridDebugOverlay.swift`): DEBUG-only, gated by the
  `developer.showTorsoGridOverlay` user default (off by default; the single call site
  is `#if DEBUG`-compiled out of release). Documented in `Docs/asset-swap-guide.md`.

`sternum_target` / `xiphoid_avoid_zone` entities remain visual affordances; when a
torso grid derives successfully, detection volumes come from the grid
(`AssetRegistry.handTrackingTargets`), with the authored-entity volumes as fallback.

## D2 — Finger-node reduction + new detectors (`Spatial/HandTracking/`)

- Anchor reduction now produces `TrackedHandReducedFrame` = legacy palm centroid +
  `TrackedHandNodesObservation` (thumbTip, indexTip, middleMetacarpal palm proxy,
  wrist required; middle/ring/little tips optional — ARKit loses them often). The
  reduction still happens synchronously inside the detached task; no anchor,
  skeleton, or joint stream crosses the boundary, and feature views still see only
  derived events.
- **`FingerContactCompressionDetector`** — a compression is a contact cycle: the
  stacked pair's LOWER palm proxy descends into the surface entry band (compression
  at entry, grid region of the contact point = placement), then re-arms when it rises
  `releaseHysteresisMetres` (12 mm, configuration) above the DEEPEST point of that
  contact. *Deviation from the spec's fixed release plane, flagged for review:* a
  resistance-free virtual chest lets hands bottom out below the surface, where a
  fixed plane misses exactly the 1.5–3 cm device-failure bounces; trough-relative
  release catches them while descent-gated entry keeps hover/jitter at zero. The
  acceptance replay (2.5 cm bounces bottoming −5 mm, 110/min, 60 Hz, 40 s) registers
  ≥ 90 % of cycles (unit-tested; actual ≈ 100 %).
- **`PinchGrabTracker`** — pure value-type state machine: pinch begins at
  thumb-index gap ≤ 22 mm near a registered `PinchGrabItem`, follows the pinch
  midpoint, releases at gap ≥ 45 mm (hysteresis, no flapping), cancels on hand loss.
  Emits `GrabInteractionSample` via one new derived-event case
  `.grabInteractionChanged` (unavoidable: no existing case can carry item + midpoint;
  all other consumers ignore it explicitly).
- **`ComposedHandSignalDetector`** — runs contact (primary) + retuned oscillation
  (secondary) + pinch over the same frames; compressions fire on EITHER signal and
  are deduplicated inside the refractory window (`minimumCompressionIntervalSeconds`
  kept at 0.25 s); interruption and cadence are re-derived from the deduplicated
  stream via the extracted `RollingCadenceEstimator` (same rolling-median maths).
  Consumers keep the existing event vocabulary unchanged.
- Legacy oscillation retune (`HandSignalDetectorConfiguration.contactComposedRetuned`):
  hysteresis 12 → 8 mm, smoothing 0.45 → 0.6 (small bounces survive filtering),
  corridor radius 0.42 → 0.55 m and stacked-palm separation 0.16 → 0.20 m (stacked
  centroid offset), and a new `corridorExitGraceSeconds` (0.75 s) so transient drift
  out of the corridor no longer wipes oscillation phase state. `practiceDefault`
  (grace 0) is byte-identical in behaviour, so every existing detector test still
  passes unchanged.
- `HandTrackingService` drives the composed detector; the new protocol requirement
  `updateGrabbableItems(_:)` has a no-op default so existing fakes/conformers compile.
  `SimulatedHandInput` gains a test-only `emit(_:)` hook.

## D3 — Guided physical AED sequence

- `AEDStateMachine` (in-flight work completed/fixed): typed
  `.placePhysicalPad(AEDPhysicalPadPlacement)` event — side, optional region,
  optional region-normalized error; evidence-consistency validation; correct-region
  enforcement stays in the reducer; `retryPadPlacement` clears physical evidence;
  pad regions/errors logged in event-log evidence. (Fixed a type-checker blowup in
  the evidence dictionary by hoisting the two formatted strings.)
- `AEDPracticeSessionModel`: consumes grab samples — power-button pinch routes
  through the same `pressPowerButton()` reducer path; pad grabs track an
  `activePadGrab`, releases resolve through `TorsoGridMap.snapResolution`
  (snap within tolerance → region + error; outside → nil/nil evidence, remediated by
  existing rules) and submit `placePhysicalPad`; re-registers the pad's new resting
  position for re-grabbing. Guided CPR segment (from the in-flight work): contact
  compressions during `noShockAdvised`/`simulatedShock`/`resumeCompressions` drive
  resume + tempo tracking against the source-backed 100–120/min band with the visual
  metronome.
- `SimulationSpaceRootView`: AED rooms now configure/start the AED session's hand
  tracking with grid targets and descriptor-resolved grab items; the `update:` pass
  renders grabbed-pad follow + one-shot snap placement; grid debug overlay hookup.
  Every existing tap/drag/button fallback is untouched (the physical path is additive).
- CPR practice room and integrated-scenario CPR stages get contact-cycle detection
  automatically — the composed detector lives inside the shared service, and the
  event stream is unchanged; their models only add the new case to ignore lists.

## D4 — Composite physical performance score

Completed in-flight work, verified: `PhysicalPerformanceEvidence/Policy/Breakdown`
(policy weights ⅓/⅓/⅓ as source-referenced data, `padErrorAtZeroScore = 1`),
`ScoringEngine.physicalPerformanceBreakdown` (location / pad placement / tempo
sub-scores; missing dimensions drop out of the weighted denominator — an accessible
attempt is never scored as a fabricated zero), `DebriefBuilder` (physical pad events
are the provenance marker; caps CPR + AED dimension scores), `ScenarioDebrief.
physicalPerformance`, and the debrief UI block with depth/force/recoil explicitly
"Not physically assessed" everywhere.

Scope boundary (deliberate, matching the in-flight provenance design): integrated
scenarios do not yet SUBMIT `.placePhysicalPad` — their AED stage still collapses pad
work into `prepareAndApplyAED()`. The reducer, engine (`ScenarioEngine.submit` accepts
any `AEDPracticeEvent`), scoring, and debrief path are ready; wiring a physical pad
step into the scenario stage flow is follow-on UX work. Until then scenario debriefs
show the honest "no physical evidence" state; the standalone AED room has the full
physical path.

## D5 — Swappable asset abstraction

`PracticeAssetDescriptor` (Codable; body/defibrillator/patches slots + optional grid
override) with `placeholderDescriptor` holding today's entity names — behaviour
unchanged. `AssetRegistry` resolves grid, targets, and grab items through
`practiceAssetDescriptor`; no new entity-name literals outside the placeholder
descriptor (landmark names live in the spec-defined `TorsoLandmark` contract the
descriptor references). Guide: `Docs/asset-swap-guide.md`. Scale-invariance proven by
test across 1.0× and 1.6× bodies.

## D6 — Tests

`Tests/GridGestureTests.swift`, 19 tests: grid scale invariance; anatomical sidedness
(patient-right pad at −X/viewer-left, cranial of the left-lateral site); landmark
override beats proportional default; ≥90 % capture of small-amplitude stacked bounce
replays; hover counts nothing; xiphoid contact classifies as avoid-zone;
contact+oscillation dedup inside the refractory window with interruption emission
preserved; pinch grab/release hysteresis, distant-item rejection, mid-drag hand loss;
snap-to-region + placement-error math; full power→pads→analysis→shock→CPR happy path
through `AEDStateMachine`; wrong-region and outside-tolerance remediation;
inconsistent evidence rejection; three-sub-score composition + composite; missing
evidence never scored as zero; descriptor JSON round-trip; SME-review flags present.
`ScenarioScoringGateTests` updated for the new `ScenarioDebrief` field.

## Verification (real results)

Environment note: the AGENTS.md-recorded Xcode 26.6 / visionOS 26.5 simulator
(`72F30C88…`) is not present on this machine; the only usable toolchain is
`/Applications/Xcode-beta.app` (Xcode 27.0) with the visionOS 27.0 simulator
`1F0F4B3B-71B2-4AE0-A3E8-FA933FFC90AF`, which is what all commands below used.
`xcodegen` remains uninstalled — `project.pbxproj` was maintained by hand (7 new file
entries; `project.yml` needs no change, its sources are directory-globbed).

- `xcodebuild … -scheme LifesaverVision -destination 'platform=visionOS Simulator,
  id=1F0F4B3B…' -derivedDataPath ~/Library/Developer/Xcode/DerivedData/LifesaverVision
  build` → **BUILD SUCCEEDED** (one pre-existing benign appintentsmetadataprocessor
  warning). Note: building into the repo-local `.build/DerivedData` fails at CodeSign
  ("resource fork/Finder information") because the repo lives under an
  iCloud-synced Desktop and the file provider stamps xattrs onto fresh build
  products; the canonical `~/Library` derived-data path avoids it.
- Same + `test` → **TEST SUCCEEDED**: 262 unit tests 0 failures (243 pre-existing +
  19 new), 2 UI tests 0 failures.
- `PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 Scripts/validate_assets.py` → passed
  (13 scene contracts, 47 placements).
- `plutil -lint LifesaverVision.xcodeproj/project.pbxproj` → OK.
  `git diff --check` → clean.

## Files

New: `Spatial/BodyGrid/TorsoGridMap.swift`, `Spatial/BodyGrid/TorsoGridDebugOverlay.swift`,
`Spatial/HandTracking/FingerContactCompressionDetector.swift`,
`Spatial/HandTracking/PinchGrabTracker.swift`,
`Spatial/HandTracking/ComposedHandSignalDetector.swift`,
`Spatial/RealityKit/PracticeAssetDescriptor.swift`, `Tests/GridGestureTests.swift`,
`Docs/asset-swap-guide.md`.
Modified: `Spatial/HandTracking/{HandTrackingModels,HandSignalDetector,
HandTrackingService,SimulatedHandInput}.swift`, `Spatial/RealityKit/{AssetRegistry,
AssetRegistry+HandTrackingTargets}.swift`, `Core/Models/{ScoringModels,
IntegratedScenarioModels}.swift`, `Core/Services/{AEDStateMachine,ScoringEngine,
DebriefBuilder}.swift`, `Features/AEDPractice/{AEDPracticeSessionModel,
AEDPracticeImmersivePanel}.swift`, `Features/CPRPractice/CPRPracticeSessionModel.swift`,
`Features/Scenarios/IntegratedScenarioSessionModel.swift`,
`Features/Debrief/DebriefView.swift`, `App/SimulationSpaceRootView.swift`,
`Tests/ScenarioScoringGateTests.swift`, `LifesaverVision.xcodeproj/project.pbxproj`.

## Open items

1. **SME review** of the normalized region rects (flagged `requires_sme_review`) and
   of the trough-relative release deviation described under D2.
2. **On-device validation** of the contact detector against the original failing
   screen recording scenario (unit replays pass; real Vision Pro confirmation
   outstanding), and of pinch-grab ergonomics/thresholds.
3. **Scenario physical-pad step** (see D4 scope boundary) to light up the composite
   score inside integrated-scenario debriefs.
4. AGENTS.md records a simulator/toolchain that no longer exists on this machine;
   worth updating (built/tested on Xcode 27.0 beta, visionOS 27.0 simulator).
