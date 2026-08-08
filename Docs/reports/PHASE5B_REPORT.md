# Phase 5B + 6B — Learning Experiences and Audio Integration Report

Date: 8 August 2026

Product: `Lifesaver Vision: CPR + AED Spatial Academy`

Baseline: `576715a` (`Phase 5a: spatial practice core`)

Simulator: visionOS 26.5, `72F30C88-7E77-4710-BC36-4934D3F0809E`

## Result

Phase 5B + 6B is implemented and verified on the required Apple Vision Pro
simulator. XcodeGen regenerated the project, the complete app built successfully,
the full `LifesaverVisionTests` bundle passed 215 tests with zero failures and zero
skips, and the focused M9 navigation UI test passed with zero failures.

The delivery adds the source-backed lesson player, three volumetric laboratory modes,
four integrated scenarios and event-log-derived debrief, Module 0 onboarding,
dashboard/gamification surfaces, the achievement gallery, persistent practice
evidence, and production audio/caption wiring. Clinical transitions remain in the
Phase 5A reducers. Completion remains an internal learning record, not SRFAC
certification, and compression depth/force remain explicitly not physically assessed.

## Milestone delivery

### M5B.1 / 6B — Production audio and captions

- Added `Audio/Delivery` and `Resources/Captions` to the generated app target. The
  source and built bundles each contain all 107 manifest delivery files and 86 speech
  VTT files.
- Replaced the placeholder director with bundle asset-ID resolution, graceful missing
  media handling, independent narration/dialogue/SFX/music channels and shared
  persisted settings. Captions default on; narration speed supports 0.8, 1.0 and 1.2.
- Music ducks under speech and is hard-stopped for AED analysing, charging,
  clear-confirmation and simulated-shock states and during safety-critical correction.
  Teardown clears safety state, while immersive reactivation reconstructs the current
  clinical hard-stop before deciding whether music may resume.
- AED voice/effects attach to `aed_unit`, lobby guidance attaches gently to the
  companion orb, lesson narration is non-positional, room beds use ambient routing,
  and responder arrival uses a plausible door-direction source.
- Speech captions and meaningful-SFX equivalents share a persistent visual overlay.
  Caption state is kept independent from concurrent music/SFX, narration speed is
  reflected in spatial caption/duck timing, and every wired meaningful cue has a
  corresponding visual state.
- Immersive playback starts only after the scene is active and open, pauses with the
  simulation, survives internal room transitions, and restarts safely after app
  reactivation.

### M5B.2 — Source-backed lesson player

- Renders all authored block presentations, including body text, callouts,
  guideline-update cards with “What changed since 2018” styling, activity links and
  media placeholders.
- `clinicalReviewRequired` blocks show the awaiting-clinical-approval chip and remain
  text/transcript only. `sourceChecked` blocks request `nar.<blockID>` and fall back to
  readable content if audio is absent.
- Adds play/pause/replay, captions, transcript, 0.8/1.0/1.2 playback, on-demand source
  footnotes, quiz launch and closed activity routing.
- Persists version-scoped resume position and exact learner/course/version lesson
  completion. The untimed final-block action merges legacy progress safely, updates
  course completion and emits module-complete audio only once.
- All module routes are derived from a `CourseEngine.presentableModules` snapshot.
  M9 remains locked with its reason and cannot construct a lesson-player route.

### M5B.3 — Volumetric laboratory

- Heart and Lungs mode exposes `heart_ra`, `heart_rv`, `heart_la`, `heart_lv`,
  `lungs_left` and `lungs_right` with labels, source-backed M1 narration reuse,
  circulation flow, normal/simplified-VF states and a static Reduce Motion variant.
- Chain of Survival mode uses all seven `chain_ring` elements for reorder and
  purpose-matching practice with gaze/pinch, drag and accessible controls. It remains
  gentle and unscored while M2 carries its authored waiver.
- AED Explorer labels the trainer case, controls, pads and connector and provides
  preparation-step callouts.
- Laboratory narration mounts the same caption overlay as other speech. Access is
  gated per mode through the authoritative presented module IDs: M1 unlocks
  Heart/Lungs, M2 unlocks Chain, and M5 unlocks AED exploration without requiring all
  three modules at once.

### M5B.4 — Integrated scenarios and debrief

- Loads Scenarios A–D from `scenarios_v1.json`, validates approved pattern pools and
  clinical invariants, selects through an injected random/deterministic selector, and
  advances an explicit definition-backed branch cursor.
- Orchestrates the Phase 5A DRSABC, CPR and AED reducers. Gaze/pinch bystander
  delegation and the accessible alternative produce equivalent evidence; Scenario B
  distractions are recorded but do not penalise accessibility needs.
- Integrated CPR now requires 100 accepted compression events and derives cadence and
  interruption evidence from the reducer. AED analysis, decision, charge, clear,
  simulated shock and resume are separate learner-visible stages.
- Every occurrence of a critical error produces immediate `sys.*` guidance, a visual
  marker/replay anchor from the immutable event log, and a guided retry. Repeated
  errors cannot deadlock correction. Far-AED branches record the authored
  minimise-delay action only after reducer-accepted delegation.
- Debrief is built only from the recorded log. It shows the timeline, replay anchors,
  category weights and weighted contributions, source-referenced feedback, XP/badge
  outcome, completion sting and spaced-repetition recommendation.
- Scenario and dedicated CPR/AED/DRSABC practice attempts persist against the active
  learner. Badge metrics are emitted only when matching evidence exists, so a
  normal-breathing branch cannot earn unsupported CPR or AED badges.

### M5B.5 — Module 0 onboarding

- Drives first-run orientation from the authored M0 blocks: product limits and “Not
  physically assessed”, simulated-call-only behavior, persistent safety controls,
  comfort/accessibility setup, data handling and non-certification boundaries.
- Collects seated/standing posture, dominant-hand preference and input method for the
  current app session without contradicting the authored promise not to store a
  separate long-lived hand/calibration profile.
- Requires the learner to use both Pause and Exit in the safe immersive practice space
  before orientation can complete.
- Launches the existing unscored M0 diagnostic without pass/fail, XP or course-gating
  semantics, persists onboarding completion, and requires explicit immersion opt-in
  for each session.

### M5B.6 — Gamification surfaces

- Replaced dashboard placeholders with a modules-by-skills mastery map derived from
  learner-bound lesson and practice evidence, achievements, practice streak,
  spaced-repetition due dates and personal bests.
- Added an Achievement Gallery volume using `badge_mXX` assets, visually muted
  placeholders and a certificate pedestal. Its status is exactly
  `Instructor-verified` or `Internal completion record — not SRFAC certification`.
- Practice persistence and idempotent award handling keep dashboard, debrief and
  gallery outcomes aligned. No public leaderboard exists or is exposed.

### M5B.7 — Comfort and accessibility

- Persistent visible Pause and Exit controls remain available throughout immersive
  content. Internal scene changes no longer masquerade as an immersive dismissal.
- A dismissible break suggestion appears after 12 minutes of continuous immersion and
  never auto-exits; its clock survives internal room transitions.
- App and system Reduce Motion settings are combined. Pulsing guidance becomes a
  discrete counter, and no clinical control disappears on a timer.
- New controls support Dynamic Type and expose VoiceOver labels/traits. RealityKit
  entities have distinct descriptions and advertise activation only when a real action
  is implemented.
- Safety and progress states use text/icons as well as colour. CPR interruption
  feedback, in particular, is not colour-only.

### M5B.8 — Verification matrix

The expanded suite covers:

- all 107 manifest-to-bundle audio resolutions and all 86 required speech captions;
- persisted/clamped audio preferences, independent volumes, ducking, active-player
  hard stops, cross-session safety reset and speed-adjusted spatial ducking;
- every lesson presentation policy, clinical-review no-narration behavior, source
  disclosure, missing-media fallback, versioned resume/completion and route refusal for
  modules omitted by `presentableModules`;
- M9 locked/no-route behavior at unit and UI level;
- laboratory asset contracts, mode-specific authorization and spatial accessibility;
- approved scenario patterns, invariant preservation, strict branch advancement,
  repeated remediation, 100-compression evidence, AED stage safety and source cue
  mapping;
- debrief reconstruction solely from the event log, branch-specific requirements,
  evidence-backed badge metrics and persisted XP/attempt outcomes; and
- onboarding Pause-plus-Exit gating, session calibration, comfort clock continuity,
  dedicated practice persistence and non-colour-only feedback.

## Audio and final bundle inventory

```text
Audio/Delivery:                 107 .m4a files, 42M on disk
Resources/Captions:             86 .vtt files, 348K on disk
Built app audio:               107 .m4a files
Built app captions:             86 .vtt files
Built app regular files:       264
Built app file-byte total:     213556060 bytes (203.66 MiB)
Built app allocated size:      209244 KiB (`du -sh`: 204M)
```

The measured product is the unsigned Debug-Beta visionOS simulator `.app`, not a
stripped device archive or App Store package:

```text
/Users/angseesiang/Library/Developer/Xcode/DerivedData/LifesaverVision/Build/Products/Debug-Beta-xrsimulator/LifesaverVision.app
```

The largest non-code contribution remains the validated loose USDZ delivery set
(141,007,707 bytes before bundle packaging); audio delivery is approximately 42M.

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
  test -only-testing:LifesaverVisionTests
xcodebuild -project LifesaverVision.xcodeproj -scheme LifesaverVision \
  -destination 'platform=visionOS Simulator,id=72F30C88-7E77-4710-BC36-4934D3F0809E' \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/LifesaverVision \
  test -only-testing:LifesaverVisionUITests/LifesaverVisionUITests/testM9RendersLockedAndHasNoLessonPlayerRoute
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
Test Suite 'LifesaverVisionTests.xctest' passed at 2026-08-08 10:38:26.770.
    Executed 215 tests, with 0 failures (0 unexpected) in 62.380 (62.620) seconds
Test Suite 'All tests' passed at 2026-08-08 10:38:26.791.
    Executed 215 tests, with 0 failures (0 unexpected) in 62.380 (62.641) seconds
** TEST SUCCEEDED **
```

The unit-test result bundle is:

```text
/Users/angseesiang/Library/Developer/Xcode/DerivedData/LifesaverVision/Logs/Test/Test-LifesaverVision-2026.08.08_10-36-55-+0800.xcresult
```

`xcresulttool` independently reports `Passed`: 215 passed, zero failed, zero skipped
and zero expected failures on the requested visionOS 26.5 simulator.

Focused M9 UI-test result, verbatim:

```text
Test Case '-[LifesaverVisionUITests.LifesaverVisionUITests testM9RendersLockedAndHasNoLessonPlayerRoute]' passed (52.500 seconds).
Test Suite 'LifesaverVisionUITests' passed at 2026-08-08 10:43:15.873.
    Executed 1 test, with 0 failures (0 unexpected) in 52.500 (52.506) seconds
** TEST SUCCEEDED **
```

The focused UI-test result bundle is:

```text
/Users/angseesiang/Library/Developer/Xcode/DerivedData/LifesaverVision/Logs/Test/Test-LifesaverVision-2026.08.08_10-41-31-+0800.xcresult
```

`xcresulttool` independently reports `Passed`: one passed, zero failed, zero skipped
and zero expected failures. The other UI smoke test was not included in this focused
navigation run.

The first expanded 215-test run exposed four assertions for the same safety-voice
mapping precedence defect across Scenarios A–D. The generic AED code match was taking
precedence over the explicit lone-rescuer guidance. The mapping was corrected, its
focused regression passed, and the complete 215-test bundle was rerun to the green
result above.

## Diagnostics and warnings

No warning invalidated the build or either final test result. The following were
observed and are retained here rather than hidden:

- Xcode emitted `DVTDeviceOperation: Encountered a build number "" that is
  incompatible with DVTBuildVersion` during simulator test startup.
- One build emitted `Metadata extraction skipped. No AppIntents.framework dependency
  found`; the app does not define App Intents.
- RealityKit simulator scene tests logged `NetworkAssetManager does not have an asset
  entity` dependency diagnostics even though all 50 delivery USDZ files, 13 scene
  contracts and their tests passed.
- The simulator emitted AudioComponent factory, unsupported `TCP_INFO`, TBB TLS and
  accessibility-bundle diagnostics. The UI run also reported missing simulator
  `SpringBoardUIServices.axbundle` metadata and no debugger version. The test continued
  and passed.
- Xcode notes that the asset-validation build phase runs on every build because it has
  no declared outputs. It completed with `Asset validation PASSED`.

## Honest limitations and required operator verification

- Verification was performed on visionOS Simulator, not physical Apple Vision Pro
  hardware. AED-unit localisation, companion-orb anchoring, ambient room balance,
  responder door direction and 10–12 dB perceptual ducking require on-device listening.
- System-volume interaction, pitch quality at 0.8/1.2 speed, subjective caption sync
  and transitions between simultaneous speech/SFX/music require a human audio and
  accessibility pass on-device.
- Seated/standing placement, dominant-hand interaction comfort, the 12-minute break
  experience and persistent Pause/Exit reachability require operator comfort testing
  across body sizes and room layouts.
- VoiceOver traversal order, activation of RealityKit entities, Dynamic Type clipping,
  colour-filter legibility and Reduce Motion behavior in immersion require on-device
  accessibility verification. Simulator tests cover labels, traits and policies, not
  the complete human traversal experience.
- Live ARKit hand tracking and gaze/pinch ergonomics remain simulator-unverified.
  Placement and rhythm are training heuristics; depth, force and recoil remain
  `Not physically assessed` without a verified external `CPRSensorProvider`.
- The 995 interaction is permanently simulated and makes no real call. The AED performs
  no real analysis or shock.
- Eleven `clinicalReviewRequired` blocks intentionally remain visible text-only with
  an awaiting-approval chip and no narration. They are not promoted to source-checked
  content by this phase.
- Nine configured badge rules occupy the applicable gallery slots; the remaining
  `badge_mXX` models remain muted placeholders until a governed rule is authored.
- The measured 204M `.app` is an unstripped Debug-Beta simulator product. A signed
  device/archive size must be measured separately for release distribution.
- Badge, XP and completion evidence are internal records. Practical competency is
  `Instructor-verified` only after explicit sign-off and is never represented as SRFAC
  certification. No public leaderboard is implemented.

## Milestone commits

- `ff17a8c` — `Phase 5b.1: wire production audio and captions`
- `391f1a7` — `Phase 5b.2: add source-backed lesson player`
- `bfe1766` — `Phase 5b.3: build volumetric learning laboratory`
- `a1ed462` — `Phase 5b.4: add integrated scenarios and debrief`
- `6d83918` — `Phase 5b.5: add source-backed learner onboarding`
- `128aa09` — `Phase 5b.6: surface learner progress and achievements`
- `35a4913` — `Phase 5b.7: harden comfort accessibility and audio feedback`
- `5ce5a40` — `Phase 5b.8: complete integration verification`
- Final regenerated project and this report: `Phase 5b: learning experiences + audio integration`
