# Phase: Anatomical grid + finger-node interaction + guided AED/CPR sequence

Assigned to: Sol (GPT-5.6), principal engineer. Manager: Claude Fable.
All AGENTS.md hard constraints apply — especially #5 (no depth/force/recoil measurement
claims; sequence, placement zone, rhythm, interruptions only), #3 (medical safety,
SRFAC-sourced), #9 (Swift 6 strict concurrency).
**Do NOT git commit.** Report to `Docs/tasks/2026-08-08-grid-gesture-REPORT.md`.
Build/test with `-derivedDataPath .build/DerivedData` (workspace sandbox). The manager
runs the canonical build after review. NOTE: `xcodegen` is NOT installed on this machine
— maintain `LifesaverVision.xcodeproj` membership manually for any new files (as done
for Tests/HandNavigationRemediationTests.swift) AND keep `project.yml` in sync for
future regeneration.

## Field evidence (device test, screen recording, 2026-08-08 ~17:00)

On a real Vision Pro, in the CPR practice room, with hand tracking RUNNING and the
user performing genuine two-handed stacked CPR compressions on the virtual manikin
for ~40 seconds: only 2 compressions registered; panel read "11/min" against the
100–120 band and interruption timer climbed to 12.8 s. The pipeline (T1/T2 from the
previous phase) works — the DETECTOR's model of a compression is wrong.

## Root cause (verified in source — `Spatial/HandTracking/HandSignalDetector.swift`)

The detector requires a free-space palm-centroid oscillation: descend ≥
`oscillationHysteresisMetres`, then ascend ≥ same, inside a corridor
(`maximumTrackingRadiusMetres` around `sternum_target`, height-bounded), with
`resetMotion()` wiping phase state on every corridor exit (line ~157-162). Real CPR
posture breaks all of it:
- stacked hands ⇒ tracked palm centroid sits high/offset; `contactPalm()` may pick
  the top hand;
- a virtual manikin offers no chest resistance ⇒ users bounce 1–3 cm, far below a
  realistic hysteresis, so full oscillations rarely complete;
- natural drift exits the corridor mid-cycle and resets the phase machine.

## Deliverables

### D1 — Scale-invariant torso grid (`Spatial/BodyGrid/`)

New `TorsoGridMap` value type:
- Derived at scene load from the manikin's torso geometry (root entity +
  `visualBounds`), expressed in NORMALIZED coordinates (u,v ∈ [0,1] over the torso's
  frontal plane, w for depth) so ANY body scale/size produces correct region
  placement. No absolute metres in region definitions.
- A `BodyGridDescriptor` declares a grid (default 8 columns × 10 rows) and named
  region assignments as normalized rects. Required regions:
  - `padSiteRightClavicle` — upper right chest, below right clavicle
    (patient's right = viewer's left; get anatomy right and add a unit test for it);
  - `padSiteLeftLateral` — patient's left lower lateral chest;
  - `sternumCompressionSite` — lower half of sternum, centre chest;
  - `xiphoidAvoidZone` — immediately caudal to the compression site.
  Region defaults MUST carry a SourceReference to the SRFAC/AHA pad-placement and
  hand-placement guidance already in `Docs/sources/` (follow the existing
  ClinicalContentModels pattern; mark "requires SME review" where the mapping from
  guidance to normalized rects is interpretive).
- If the loaded body asset provides explicit landmark entities
  (`landmark_sternum`, `landmark_xiphoid`, `landmark_right_clavicle`,
  `landmark_left_lower_ribs`), those override the proportional defaults.
- `TorsoGridMap.worldVolume(for: RegionID) -> HandTrackingTargetVolume` bridges to
  the existing target-volume math. Existing `sternum_target` / `xiphoid_avoid_zone`
  entities remain as visual affordances; detection volumes now come from the grid.
- Debug: an instructor/debug-gated overlay that renders the grid + regions as
  translucent tiles on the torso (off by default; toggle in Settings > developer or
  compile-flag-gated — your call, document it).

### D2 — Finger-node hand reduction + gesture pipeline (`Spatial/HandTracking/`)

Extend the anchor reduction (currently palm centroid only) to a
`TrackedHandNodesObservation`: per hand, world positions for thumbTip, indexTip,
middleTip, ringTip, littleTip, middleMetacarpal (palm proxy) and wrist. Keep the
existing privacy contract — reduce inside the detached task, never retain
anchors/skeletons, never expose joints to feature views.

Two new detectors composed with (not replacing) the existing stream:

1. **`FingerContactCompressionDetector`** — a compression is a CONTACT CYCLE, not a
   free-space oscillation: any tracked node (prefer palm proxy / middle of the
   stacked pair) ENTERS the `sternumCompressionSite` world volume (small entry
   tolerance above the surface), then EXITS above a release plane (hysteresis
   ~10–15 mm — configuration, not hard-code), then re-enters ⇒ one compression per
   re-entry, timestamped at entry. Placement zone = grid region containing the
   contact point (sternum vs xiphoid vs outside). Rhythm/cadence and interruption
   logic reuse the existing rolling-median code. Refractory interval: keep
   `minimumCompressionIntervalSeconds`. Emit the SAME `HandTrackingDerivedEvent`
   vocabulary so `CPRPracticeSessionModel` / `IntegratedScenarioSessionModel`
   consumers keep working unchanged; add new event cases only if unavoidable.
   ALSO retune the legacy oscillation detector (smaller hysteresis ~15 mm, corridor
   radius that tolerates stacked-hand offset, no full state reset on transient
   corridor exit) and keep it as a secondary trigger — fire on EITHER signal,
   deduplicated within the refractory window.

2. **`PinchGrabTracker`** — thumbTip–indexTip distance < grab threshold ⇒ pinch
   begin at midpoint; entity association, drag following, and release (distance >
   release threshold, hysteresis so it doesn't flap). Pure value-type state machine
   like HandSignalDetector, unit-testable with synthetic node frames.

### D3 — Guided physical AED sequence (`Features/AEDPractice/` + `Core/Services/`)

Wire a physical interaction path through the EXISTING `AEDStateMachine` (do not fork
clinical logic; extend its event vocabulary only if a step has no equivalent event):
1. Pick up each patch with a pinch (D2.2) — patches become grabbed entities that
   follow the pinch midpoint.
2. Release over the torso ⇒ patch snaps to the nearest grid region if within a snap
   tolerance; records normalized placement error (distance from region centre in
   region-normalized units). Wrong-region placement is remediated per existing
   state-machine rules (correct-region enforcement stays in the state machine).
3. Pinch/press the defibrillator's `aed_power_button` ⇒ machine's power-on event;
   existing AudioDirector instruction prompts play as today.
4. Guided CPR segment: compressions via D2.1 contact cycles on
   `sternumCompressionSite`, tempo target 100–120/min with the existing visual
   metronome.
All current button/gaze-pinch fallbacks REMAIN (accessibility requirement) — the
physical path is additive, exactly like the previous phase's hand wiring.
Also route D2.1 into the CPR practice room and the integrated scenarios' CPR stage,
replacing oscillation-only detection there (same event stream, so this is mostly the
composed-detector change).

### D4 — Composite performance score (`Core/Services/ScoringEngine` + models)

Extend the existing scoring/debrief path (reuse `ScoringEngine`, `DebriefBuilder`,
existing XP gating — no new parallel scoring system) with a
`PhysicalPerformanceBreakdown`:
- CPR location accuracy: fraction of compressions whose contact point fell in
  `sternumCompressionSite` (xiphoid contacts weighted as safety-critical per
  existing critical-failure handling);
- Pad placement accuracy: per-pad normalized placement error mapped to a 0–100
  sub-score;
- Tempo accuracy: fraction of inter-compression intervals inside the supported
  band (reuse existing cadence maths);
- Composite: weighted blend — weights are POLICY data with SourceReference, not
  magic numbers in code (follow CPRPracticePolicy.sourceBacked pattern).
Depth/force/recoil remain "Not physically assessed" everywhere; the debrief shows
the three sub-scores + composite with the existing calm clinical presentation.

### D5 — Swappable asset abstraction (`Spatial/RealityKit/`)

- `PracticeAssetDescriptor` (Codable): declares semantic slot → entity-name mapping
  for `body` (torso root, optional landmarks), `defibrillator` (unit, power button,
  connector, status light), `patches` (left/right), plus optional per-asset grid
  descriptor override. Current procedural/USDA assets become the
  `placeholderDescriptor` — behaviour today is unchanged.
- `AssetRegistry` resolves semantic entities THROUGH the descriptor (single seam)
  instead of scattered hard-coded name strings; keep the current names inside the
  placeholder descriptor so nothing visual changes this phase.
- Swapping in a new manikin/defib/patch asset = new USDZ + a descriptor JSON
  (document the shape in the report + a `Docs/asset-swap-guide.md`); the grid
  auto-rescales from the new body bounds. Include a unit test proving two different
  body scales yield identical normalized region placement (D1 scale invariance).

### D6 — Tests (extend, run, keep 245 green)

- Grid: scale invariance across ≥2 body sizes; anatomical sidedness (patient-right
  pad on viewer-left); landmark override beats proportional default.
- Contact detector: small-amplitude bounce cycles (the device failure case —
  1.5–3 cm) all count; hover without contact counts nothing; xiphoid contact
  classifies as avoid-zone; refractory dedup between contact + retuned oscillation
  signals; interruption emission preserved.
- PinchGrab: grab/release hysteresis, mid-drag hand loss, snap-to-region and
  placement-error math.
- Sequence: full pick→place→power→CPR happy path through AEDStateMachine; wrong-pad
  region remediation; score composition (all three sub-scores).
- All existing suites must stay green. Run the full suite yourself with the
  workspace derivedDataPath and report real results.

## Acceptance criteria

1. Real stacked-hand pumping with 1.5–3 cm bounces on the manikin registers ≥90% of
   compression cycles in unit-level synthetic replays (build the synthetic frames
   from realistic amplitudes/rates, 30–90 Hz).
2. Patches can be pinch-picked, dragged, and snapped to the correct grid regions;
   misplacement is detected and remediated via existing clinical rules.
3. Grid regions land correctly on bodies of different scales without code changes.
4. Composite score reflects location + placement + tempo, each sourced-referenced,
   with depth/force still explicitly "Not physically assessed".
5. Existing button/gaze fallbacks untouched and functional; all suites green.
6. No new entity-name literals outside the placeholder descriptor.
