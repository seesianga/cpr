# Phase 5A — Spatial Practice Core Report

Date: 8 August 2026

Product: `Lifesaver Vision: CPR + AED Spatial Academy`

Simulator: visionOS 26.5, `72F30C88-7E77-4710-BC36-4934D3F0809E`

## Result

Phase 5A is complete. The project was regenerated with XcodeGen, the full
`LifesaverVision` app built successfully, and the complete `LifesaverVisionTests`
bundle passed 149 tests with zero failures, zero skips and zero expected failures on
the required Apple Vision Pro simulator.

The delivered practice core keeps clinical transitions in replayable reducers rather
than views. It provides private hand-derived CPR coaching, simulator and
gaze-and-pinch fallbacks, source-backed DRSABC guidance, CPR and AED immersive room
flows, deterministic scoring and remediation, and fail-closed content/access checks.

## Milestone delivery

### M5A.1 — Event-sourced practice state machines

- Added a generic event-sourced state-machine boundary plus deterministic DRSABC, CPR
  and AED reducers.
- Every accepted or rejected event is logged with replay validation and a rejection
  reason. Non-contiguous or divergent logs fail replay.
- AED invariants prevent analysis or shock while anyone is touching, require the
  interactive clear-check path, and require resumed compressions after both shock and
  no-shock outcomes.
- Unsafe DRSABC choices and invalid CPR/AED transitions produce deterministic,
  testable remediation rather than view-local state changes.

### M5A.2 — Private hand-derived practice signals

- Added a protocol-backed `ARKitSession` + `HandTrackingProvider` implementation and
  an injectable `SimulatedHandInput` driver.
- Authorization denial is a supported state with a clear explanation; the course
  remains completable through gaze-and-pinch and tap-cadence input.
- Hand anchor frames are reduced immediately to transient observations. Raw streams,
  joints and images are not retained or persisted.
- Derived output is limited to cadence, interruption timing, sternum/xiphoid placement
  classification and a two-hand stacking heuristic.
- Vision never produces compression depth, force or recoil measurements. Those fields
  remain `Not physically assessed` unless a verified external `CPRSensorProvider`
  supplies them.
- The authorization lifecycle uses generation/cancellation guards so a late permission
  result cannot restart a stopped or paused provider.

### M5A.3 — CPR practice experience

- Added the authored CPR practice room through `AssetRegistry`, including semantic
  `sternum_target` and `xiphoid_avoid_zone` entities.
- Added state-machine-led coaching, placement feedback, a visual metronome pulse at
  110/min, an injectable `AudioDirector` hook for `sfx.metronome`, a 100–120/min live
  rate band, tap-cadence fallback and interruption timing.
- A complete source-backed 100-compression cycle is required before an internal
  completion record or XP-eligible summary can be created.
- Paused time is excluded from cadence and interruption calculations. A terminal gap
  over 10 seconds is recorded before scoring.
- Session completion passes through `ScoringEngine` and existing gamification rules;
  badge-policy load failure does not discard an already-created score summary.

### M5A.4 — AED practice experience

- Added `AEDPreparationRoom` and `AEDPlacementRoom` with authored semantic objects,
  collisions, input targets, hover effects and accessibility descriptions.
- Added all required preparation predicates: pacemaker/implant, medicine patch, wet
  chest, excessive chest hair and jewellery/metal near a pad site.
- Pad dragging is evaluated against authored zones: right pad below the right
  collarbone and left pad on the left side below armpit level. Correct and incorrect
  placements produce distinct feedback.
- Clear-check is an interactive ring sweep plus explicit bystander confirmations. It
  is not a single clear button.
- Analysis and simulated shock use the reducer's touch-safety gates. Both outcome paths
  start the resume-compressions coaching timer, and pause/resume cancels and safely
  restarts that timer.
- No real AED operation or electrical shock is performed.

### M5A.5 — DRSABC room experience

- Added the `DRSABCTrainingRoom` scene and an immersive guided session covering scene
  danger, response, simulated help activation, AED distance/bystander availability,
  breathing and gasping/uncertain-breathing branches.
- The simulated call sheet is permanently badged exactly
  `SIMULATION — no real call is made`; no dialing or external-call path exists.
- The AED branch sends a bystander only when the AED is within about a 60-second walk.
  A farther AED keeps the learner in the response and simulated-dispatcher flow, while
  an alone learner stays with the casualty.
- Unsafe decisions stop progression and show a corrective overlay with document,
  edition, section and page references before a guided retry.
- Dispatcher guidance and every required DRSABC fact/block fail closed when blocked,
  unreviewed or unreferenced.

The interrupted course-catalogue work was also preserved and completed as a separate
commit. Its presentation model obtains module availability from the authoritative
`CourseEngine`, fails closed on unavailable content, and only unlocks M9 when its
prerequisites, instructor approval and clinical lifecycle permit it.

### M5A.6 — Medical fixture and integration matrix

The final test matrix explicitly covers:

- shock-advised and no-shock AED paths, premature-finish rejection and mandatory CPR
  resumption;
- incorrect pads, touch during analysis, touch during shock, and fresh clear-check
  requirements;
- failure to call, gasping mistaken for normal breathing, uncertain breathing, unsafe
  scene fail-fast and source-cited retry;
- interruption longer than 10 seconds and missed resume windows after both AED
  outcomes;
- pacemaker/implant, medicine patch, wet, hairy and jewellery/metal preparation
  predicates;
- replay determinism, malformed replay rejection and invalid-transition reasons;
- denied hand tracking with a completable, scored tap-cadence fallback; and
- a combined `SimulatedHandInput` asynchronous stream through the CPR session reducer
  and `ScoringEngine`, ending in a passed summary while depth, force and recoil remain
  absent and `Not physically assessed`.

## Final verification

Commands were run from the project root. DerivedData remained outside the Google Drive
checkout.

```text
/opt/homebrew/bin/xcodegen generate
xcodebuild -project LifesaverVision.xcodeproj -scheme LifesaverVision \
  -destination 'platform=visionOS Simulator,id=72F30C88-7E77-4710-BC36-4934D3F0809E' \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/LifesaverVision build
xcodebuild -project LifesaverVision.xcodeproj -scheme LifesaverVision \
  -destination 'platform=visionOS Simulator,id=72F30C88-7E77-4710-BC36-4934D3F0809E' \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/LifesaverVision \
  -parallel-testing-enabled NO test -only-testing:LifesaverVisionTests
```

XcodeGen output, verbatim:

```text
⚙️  Generating plists...
⚙️  Generating project...
⚙️  Writing project...
Created project at /Users/angseesiang/Library/CloudStorage/GoogleDrive-ang.see.siang@gmail.com/My Drive/macbook/CPR/LifesaverVision/LifesaverVision.xcodeproj
```

Asset validation emitted during the final build, verbatim:

```text
Asset validation PASSED
Inventory: Docs/asset_inventory_raw.json
Loose destination: Media/3D/USDZ
Composition manifest: Resources/Configuration/spatial_asset_manifest_v1.json
Expected delivery assets: 50
Loose USDZ assets verified: 50
Showcase-only assets: 4
Total loose USDZ size: 141007707 bytes (141.01 MB; 134.48 MiB)
RealityKit catalogue USDZ payloads: 0
Authored USDA layers: 19 (13 scene skeletons + 6 model/helper layers)
Manifest scene contracts: 13
Lazy composition placements: 47
```

Build result, verbatim:

```text
** BUILD SUCCEEDED **
```

Complete unit-test result, verbatim:

```text
Test Suite 'LifesaverVisionTests.xctest' passed at 2026-08-08 07:33:53.103.
	 Executed 149 tests, with 0 failures (0 unexpected) in 79.258 (79.431) seconds
Test Suite 'All tests' passed at 2026-08-08 07:33:53.103.
	 Executed 149 tests, with 0 failures (0 unexpected) in 79.258 (79.455) seconds
** TEST SUCCEEDED **
```

The result bundle is:

```text
/Users/angseesiang/Library/Developer/Xcode/DerivedData/LifesaverVision/Logs/Test/Test-LifesaverVision-2026.08.08_07-29-48-+0800.xcresult
```

`xcresulttool` independently reports `Passed`, 149 passed, zero failed, zero skipped
and zero expected failures on the requested simulator. The final captured XcodeGen,
build and test logs contain no `warning:` or `error:` diagnostics.

The generated project contains no Phase 6 delivery/generated/mastered/voice-design
audio, ElevenLabs manifest, caption directory or VTT resource reference. Phase 5A links
only `Audio/AudioDirector.swift`; the existing Phase 6 media remains untracked and
reserved for its dedicated Phase 5B/6B resource wiring.

## Honest limitations and safety boundary

- ARKit hand tracking compiles and its lifecycle/derived-signal behavior is unit-tested
  on the simulator; live hand-anchor quality and spatial ergonomics have not been
  validated on physical Apple Vision Pro hardware.
- Hand placement, cadence and stacking are coaching heuristics, not clinical-grade
  measurements. Depth, force and recoil are not physically assessed without a verified
  external sensor.
- The AED resume timer is a project-authored coaching/scoring hook. It is not presented
  as a medical timing threshold; learner guidance continues to say to resume
  compressions immediately.
- The simulated 995 sheet never calls emergency services, the AED never delivers a real
  shock, and completion is an internal app record rather than SRFAC certification.
  Practical competency still requires instructor sign-off.
- Some AED preparation predicates use labelled accessible controls alongside the
  spatial razor/cloth interactions; the complete flow is testable without assuming
  precise hand tracking.
- Spatial gestures, room scale, legibility, audio audibility and comfort still require
  physical-device and human accessibility/clinical review.
- The course catalogue presents authoritative access state but does not yet launch
  every module from its cards.
- Phase 6 audio/caption assets and manager-authored privacy/security/AIVU documents were
  deliberately left untracked and untouched, as requested.

## Milestone commits

- `49f1d6b` — `Phase 5a.1: event-sourced practice state machines`
- `de8b104` — `Phase 5a.2: private hand-derived practice signals`
- `d8568f4` — `Phase 5a.3: CPR practice scoring and coaching`
- `182e04d` — `Phase 5a.4: interactive AED practice rooms`
- `883461b` — `Phase 5a.5: source-backed DRSABC practice room`
- `117c1f3` — `Phase 5a: source-backed course catalogue access`
- `2985656` — `Phase 5a.6: complete medical practice fixture matrix`
- Final regenerated project and this report: `Phase 5a: spatial practice core`
