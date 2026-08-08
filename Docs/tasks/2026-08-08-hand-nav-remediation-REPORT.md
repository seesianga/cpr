# Hand-interaction & backward-navigation remediation — completion report

Date: 2026-08-08  
Engineer: Sol (GPT-5.6)

## Outcome

T1 through T5 are implemented in the working tree. Hand tracking now uses a fresh
ARKit session/provider pair for every run, integrated scenarios consume derived hand
compressions only during their CPR stage, simulator/fallback presentation is honest,
and the immersive experiences have contextual Back, restart, and dashboard-return
paths. No commit was created.

The source and full unit-test targets type-check successfully with Swift 6 strict
concurrency against the installed Xcode beta visionOS SDK. The mandated XcodeGen and
simulator build/test executions could not complete because the sandbox's installed
tooling differs from the recorded AGENTS.md environment; details are under
Verification.

## T1 — HandTrackingProvider lifecycle

- Reworked `HandTrackingService` to allocate and retain a fresh `ARKitSession` and
  `HandTrackingProvider` for each `start()` attempt. Paused, failed, denied,
  unsupported, canceled, stopped, and explicitly retried runs release their captured
  resources before another run can begin.
- Preserved `HandTrackingServicing` and its single stable `signals` stream, so existing
  consumers do not lose their subscription across provider replacement.
- Bound authorization, provider events, anchor processing, and event publication to a
  lifecycle generation plus the exact session/provider identities. Final batch
  publication is main-actor atomic, preventing an old provider from emitting after a
  pause, stop, or newer start.
- Provider-originated `.paused` now publishes loss of observation availability while
  retaining the session/provider solely so its event monitor can observe recovery. A
  later `.running` signal stops that old run and creates a fresh pair. A subsequent
  `.stopped` signal enters a recoverable fallback.
- Added cancellation checks after both asynchronous authorization and run operations.
- Added an injected `HandTrackingRuntime` and lifecycle adapter seam. Simulator tests
  can fake support/authorization/run/stop without reading real ARKit event or anchor
  streams.

## T2 — Integrated-scenario hand input

- Added `HandTrackingServicing` injection, stable signal consumption, lifecycle state,
  target configuration, start/pause/resume/stop, and fallback presentation to
  `IntegratedScenarioSessionModel`.
- During `.cpr` only:
  - sternum compression → `performCPR(unsafeXiphoidPlacement: false)`;
  - xiphoid compression → `performCPR(unsafeXiphoidPlacement: true)`;
  - outside/unavailable placement → no clinical transition.
- Preserved the detector's actual hand-stacking heuristic. Hand and button timestamps
  share a pause-aware active clock, so paused time cannot distort cadence or debrief
  evidence.
- Buffered/stale events are rejected when paused, outside `.cpr`, after the hand-aware
  scene stops, or while the provider is not running.
- `SimulationSpaceRootView` now obtains scene-specific hand targets and configures /
  starts tracking for all four authored integrated scenario rooms. Tracking stops for
  debrief, room changes, full disappearance, and exit. Pause/resume affects only the
  selected hand-aware experience.
- Gaze-and-pinch and labelled controls remain intact and submit the same model actions.
- DRSABC inspection decision: `DRSABCStep.compressions` is a terminal routing handoff
  whose guidance says to move to guided compression practice. Its reducer accepts only
  `.completeStep` and has no compression-event/counting path. Mapping one detected beat
  to completion would be clinically misleading, so no hand input was added there.

## T3 — Honest availability and accessible fallback

- Unsupported/denied/failed starts immediately expose
  `HandTrackingState.fallbackExplanation`; the simulator therefore says hand tracking
  is “unavailable here,” not “temporarily unavailable.”
- Temporary loss is shown only when a running/paused provider loses observations. The
  message clears on an actual availability-return event and cannot reappear after scene
  teardown.
- CPR and scenario fallback banners are above long content. Their prominent compression
  controls appear before metrics/stage detail whenever tracking is not `.running`.
- The scenario CPR stage always retains its accessible sternum-compression control.
- `SimulatedHandInput` remains test-only; no production target instantiates it.
- No compression depth, force, or recoil measurement claim was added.

## T4 — Backward navigation

### Shell and clean re-entry

- Successful app dismissal and system disappearance share one tested cleanup path:
  practice resets to CPR, scene resets to `CPRPracticeRoom`, and both integrated
  scenario identifiers are cleared.
- `hasUserOptedInToImmersion` is preserved after a successful/system exit. It is still
  cleared for canceled or failed entry.
- Safety controls now include a contextual Back action:
  - AED placement → AED preparation, retaining the current AED session;
  - every other room → the same clean end-session/dashboard path as Exit.
- Exit remains independently available and does not wait for canceled restart work.

### Restart and completion paths

- CPR, AED, DRSABC, and integrated-scenario completion views now provide restart and
  dashboard-return actions.
- Integrated scenarios expose Restart from every non-debrief stage as well as the
  required two-action debrief row.
- Scenario reset clears engine, stage, correction, debrief, event evidence, selection,
  counts, timing, AED round state, queued audio, and safety-audio state. Restart then
  explicitly prepares the same authored scenario/pattern and returns from debrief to
  its scene.
- Restart tasks are single-flight, cancellation-aware, pause-reconciled, and generation
  guarded. Exit/disappearance cancels them without blocking the safety exit. Stale
  persistence may finish its record but cannot navigate a later immersive session.
- Persisted attempt IDs are cleared before each corresponding fresh attempt.

### Dashboard and spatial affordances

- Dashboard detail navigation now binds a `NavigationPath`, clears it when sidebar
  selection changes, and resets stack identity so closure-based links cannot leave a
  hidden pushed screen.
- Integrated-scenario semantic mappings are phase-gated as follows:
  - `training_manikin` → responsiveness check;
  - `bystander_01`, `bystander_02` → selected delegation;
  - `sternum_target`, `xiphoid_avoid_zone` → CPR placement actions;
  - `aed_case`, `aed_unit`, `aed_power_button`, `aed_connector`, both pads, and both
    pad zones → the existing composite AED preparation/application action;
  - `clear_zone` → the current analysis or pre-shock clear action;
  - `aed_unit` / `aed_status_light` → analysis decision or charging completion;
  - `aed_shock_button` → simulated shock;
  - `sternum_target` during AED resume → resume compressions.
- Confirmation SFX plays only when a phase/entity pair was handled.
- Debrief's decorative `control_panel` lost hover/input decoration because Restart and
  Return are two distinct actions with no safe single spatial default.
- Optional in-space practice switching was deliberately skipped. Relaxing the closed-
  immersion selection guard would require cross-feature teardown and target/audio
  rebinding and was not low risk.

## T5 — Tests added

`Tests/HandNavigationRemediationTests.swift` covers:

- pause/resume uses new session/provider identities and runs the matching new objects;
- failed-run and unsupported-environment recovery;
- provider-event pause→running fresh-run recovery and pause→stopped cleanup/fallback;
- integrated scenario CPR completion from a synthetic stream;
- FIFO-proven inertness of the same compression before the CPR stage;
- post-landmark xiphoid compression correction;
- pause time exclusion from integrated CPR timestamps;
- honest scenario and CPR unavailable-at-start messaging;
- full scenario reset/debrief cleanup and fresh prepare;
- successful-dismissal selection cleanup with opt-in preservation;
- AED placement→preparation reverse navigation.

`RealityKitAssetTests` now asserts the complete actionable integrated-scenario entity
set. The new test source was also added to the existing Xcode project manually so the
checked-in project remains usable despite XcodeGen being unavailable; `project.yml`
already includes the entire `Tests` directory and will regenerate this membership.

## Verification

### Passed

- Swift syntax parse for every modified Swift file: passed.
- Direct Swift 6 strict-concurrency type-check of the complete app target against the
  installed Xcode 27 visionOS SDK: passed.
- Emission of a testable app module for `arm64-apple-xros26.0-simulator` with the
  scheme's `DEBUG UITEST` compilation conditions: passed.
- Direct type-check of every source in the unit-test target against that module and the
  visionOS Simulator SDK: passed. One existing warning remains at
  `Tests/AuthenticationAndReportTests.swift:50` for an unnecessary `try`.
- `PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 Scripts/validate_assets.py`: passed
  (50 delivery assets, 13 scene contracts, 47 placements).
- `plutil -lint LifesaverVision.xcodeproj/project.pbxproj`: passed.
- `git diff --check`: passed.
- `.build/` was already ignored by `.gitignore`; all compiler/cache artifacts stayed
  inside it.

### Environment-blocked mandated commands

- `xcodegen generate`: exit 127, because `xcodegen` and the documented
  `/opt/homebrew/bin/xcodegen` are absent. A workspace-local Homebrew fetch was also
  attempted, but sandbox network DNS is unavailable and Homebrew cannot modify its
  external prefix.
- Required `xcodebuild ... -derivedDataPath .build/DerivedData build`: attempted with
  the only installed Xcode, `/Applications/Xcode-beta.app` (Xcode 27.0). It exited 74
  before source compilation because CoreSimulatorService is unavailable and SwiftPM
  manifest cache/sandbox operations are denied by the workspace sandbox.
- Required matching `xcodebuild ... test`: attempted and exited 74 at the same
  environment layer before tests could launch.
- A generic visionOS Xcode build was also attempted with package/module caches redirected
  into `.build`; local-package manifest evaluation was still rejected by nested
  `sandbox-exec`.

The recorded Xcode 26.6 installation and visionOS 26.5 simulator from AGENTS.md are not
present/accessible in this execution environment. Consequently, an actual simulator
build and test run—and physical Vision Pro anchor validation—remain to be rerun in that
environment. No source compiler error remains in the direct app or unit-test target
checks performed here.
