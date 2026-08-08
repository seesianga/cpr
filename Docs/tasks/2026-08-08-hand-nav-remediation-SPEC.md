# Phase: Hand-interaction & backward-navigation remediation

Assigned to: Sol (GPT-5.6), principal engineer. Manager: Claude Fable.
All AGENTS.md hard constraints apply — especially #5 (never claim compression
depth/force measurement), #3 (medical safety), #9 (Swift 6 strict concurrency).
**Do NOT git commit** — leave all changes in the working tree for manager review.
Write your completion report to `Docs/tasks/2026-08-08-hand-nav-remediation-REPORT.md`.

## User-reported symptoms (both reproduced by the user)

1. **Hand tracking never drives interaction.** The integrated scenario instructs the
   user to pump (hands-only CPR compressions); physically pumping does nothing.
   The user also saw the banner "Hand observations are temporarily unavailable.
   Continue with the accessible compression control"
   (emitted at `Features/CPRPractice/CPRPracticeSessionModel.swift:360`).
2. **No backward navigation anywhere in the immersive space.** From every scenario /
   practice, the only way out is the safety bar's Exit, which tears down the whole
   session.

## Verified root causes (multi-agent audit, adversarially verified — trust these anchors)

- **RC-1 (blocker):** Hand tracking is started ONLY when the loaded scene is
  `.cprPracticeRoom` (`App/SimulationSpaceRootView.swift:86-90`, feeding only
  `cprSession`). `IntegratedScenarioSessionModel` has zero hand-tracking references;
  its CPR stage can only advance via a gaze-pinch tap on `sternum_target` or the
  "Record a sternum compression beat" button (`performCPR` at
  `Features/Scenarios/IntegratedScenarioSessionModel.swift:378`). So pumping does
  nothing in scenarios even on a real Vision Pro.
- **RC-2 (major, on-device killer):** `HandTrackingService` creates a single
  `HandTrackingProvider` once (`let`, lines ~39-56) and re-runs the SAME instance
  after `session.stop()` (`Spatial/HandTracking/HandTrackingService.swift:100`;
  `pause()` stops at :132; `transitionToFallback` stops at :242). ARKit data
  providers can never be re-run once stopped — so after the first pause/resume or
  fallback-recovery, hand tracking dies permanently for the session. This is the
  most likely source of the "temporarily unavailable" banner on device.
- **RC-3 (platform fact):** In the visionOS Simulator, `HandTrackingProvider` never
  delivers anchors; the service lands in `.unavailable`. `SimulatedHandInput` is
  tests-only by its own documented contract — do NOT wire it into app targets.
  Simulator UX must instead rely on honest messaging + accessible controls.
- **RC-4 (blocker):** Immersive shell offers only Pause / Recentre / Exit
  (`App/SimulationSpaceRootView.swift:390-416`). No back edges exist anywhere:
  - Scenario stages are forward-only; the only backward assignment is
    `stage = stageBeforeCorrection` (`IntegratedScenarioSessionModel.swift:677`);
    no reset/replay API exists; `prepare()` is guarded off once a debrief exists
    (`SimulationSpaceRootView.swift:155`, `guard integratedScenarioSession.debrief == nil`).
  - Completion dead ends: CPR summary state renders a button-less `summaryView`
    (`.complete` renders `EmptyView`); AED `.complete` is label-only
    (`Features/AEDPractice/AEDPracticeImmersivePanel.swift:184-190`); DRSABC
    `.complete` likewise (`Features/Scenarios/DRSABCPracticeImmersivePanel.swift:102-108`).
  - AED two-room flow is one-way in the UI: nothing ever calls
    `moveAEDPractice(to: .aedPreparationRoom)` although AppModel supports it.
  - `AppModel.dismissSimulation` (`App/AppModel.swift:196-211`) never resets
    `selectedSimulationScene` / `selectedPracticeExperience` /
    `selectedIntegratedScenarioID`, so re-entering the space after a scenario
    lands in a stale `.debriefSpace` room with a fresh scene-safety session.
  - `hasUserOptedInToImmersion` is reset to false on every exit (`AppModel.swift:210`),
    adding re-entry friction.
  - `AppModel.selectPractice` refuses mode changes while immersion is open
    (`AppModel.swift:77`).
- **RC-5 (minor):** Dashboard detail `NavigationStack` has no bound path
  (`App/DashboardRootView.swift:65`): with a briefing pushed, sidebar selection
  swaps the hidden root and the sidebar appears unresponsive.
- **RC-6 (minor):** Scenario scenes decorate the AED prop set / pad zones /
  clear zone as hover-highlighting interactive targets
  (`Spatial/RealityKit/AssetRegistry.swift:651`, control_panel at :682), but the
  integrated-scenario tap branch (`SimulationSpaceRootView.swift:563-581`) ignores
  them — entities glow on gaze and do nothing when pinched.

## Tasks

### T1 — Fix HandTrackingProvider lifecycle (RC-2)
`Spatial/HandTracking/HandTrackingService.swift`
- Create a FRESH `HandTrackingProvider` (and fresh `ARKitSession` if required) on
  every `start()` / resume / recovery attempt. Never call `run` on a provider that
  has been stopped.
- Make pause → resume restore live hand tracking on device; make fallback state
  recoverable when availability returns.
- Preserve the existing public `HandTrackingServicing` surface so consumers don't churn.
- Unit-test: resume-after-pause produces a running state with a NEW provider
  instance (inject a provider factory to make this testable).

### T2 — Hand input for scenarios (RC-1)
`Features/Scenarios/IntegratedScenarioSessionModel.swift`, `App/SimulationSpaceRootView.swift`
- Give `IntegratedScenarioSessionModel` a `HandTrackingServicing` dependency
  mirroring `CPRPracticeSessionModel`'s consume loop
  (`startSignalConsumerIfNeeded` pattern).
- Map events during the hands-only-CPR stage(s):
  `compressionDetected` on sternum target → `performCPR(unsafeXiphoidPlacement: false)`;
  compression in the xiphoid avoid zone → `performCPR(unsafeXiphoidPlacement: true)`;
  `trackingAvailabilityChanged` → surface the existing fallback explanation string in
  the scenario panel. Only consume compression events while the active stage
  actually instructs compressions — hand events must not advance non-CPR stages.
- Update the `SimulationSpaceRootView` gating (currently `.cprPracticeRoom`-only,
  :86-90) so scenario scenes also configure/start/stop hand tracking with correct
  lifecycle (stop on scene change/disappear; coexist with T1).
- Check `Core/Services/DRSABCStateMachine.swift` for a compressions step: if DRSABC
  practice instructs compressions, wire the same mapping into
  `DRSABCPracticeSessionModel`; if it has no compression step, state that in the report.
- Keep every existing tap/button fallback working exactly as today — hand tracking
  is additive, never a replacement (accessibility requirement).
- Unit-test: a synthetic compression event stream during the CPR stage advances the
  scenario state machine; the same stream during a non-CPR stage does not.

### T3 — Honest availability messaging (RC-3)
- On simulator (or any environment where `HandTrackingProvider.isSupported` is
  false), the CPR practice AND scenario panels must show the existing
  `fallbackExplanation` banner immediately from session start — not the
  "temporarily unavailable" transition message — and the accessible compression
  control must be visible without scrolling/hunting.
- Do NOT instantiate `SimulatedHandInput` in app targets.
- Ensure the scenario CPR stage always shows its accessible "Record a sternum
  compression beat" control whenever hand tracking is not `.running`.

### T4 — Backward navigation package (RC-4, RC-5, RC-6)
1. `App/AppModel.swift`:
   - `dismissSimulation` (and/or `simulationSpaceDidDisappear`) must reset
     `selectedSimulationScene`, `selectedPracticeExperience`,
     `selectedIntegratedScenarioID` to their launch defaults.
   - PRESERVE `hasUserOptedInToImmersion` across exits within an app session
     (remove the reset at :210). The opt-in toggle still exists for first entry.
2. Safety bar (`SimulationSpaceRootView`): add a context-aware **Back** control
   alongside Pause/Recentre/Exit:
   - AED placement room → `moveAEDPractice(to: .aedPreparationRoom)`.
   - Everywhere else → behaves as "End session and return to dashboard" (same
     dismissal path as Exit; with T4.1 the user lands back on the screen they came
     from with clean state). Label it clearly; keep Exit as-is.
3. Restart/replay:
   - Add an explicit `reset()`/restart entry point to `IntegratedScenarioSessionModel`
     that clears debrief + stage and allows a fresh attempt in-session; replace the
     `debrief == nil` guard (`SimulationSpaceRootView.swift:155`) accordingly.
   - Scenario debrief panel: add "Restart scenario" and "Return to dashboard" actions.
   - CPR summary view: add "Practise again" + "Return to dashboard" actions
     (`CPRPracticeSessionModel.prepare()` already resets the machine).
   - AED `.complete` and DRSABC `.complete`: same two actions.
4. `App/DashboardRootView.swift`: bind the detail `NavigationStack` to a path that
   clears when the sidebar selection changes, so the sidebar never appears dead.
5. RC-6: in the integrated-scenario tap branch, wire taps on the decorated AED
   entities (case/pads/power button/clear zone) to the SAME actions as the
   corresponding phase buttons (only when that phase is active). If a clean mapping
   is not possible for some entity, remove its hover/interactive decoration in
   scenario scenes instead — no glowing dead affordances. Report which you did per entity.
6. Optional, only if low-risk: relax `selectPractice`'s closed-immersion guard to
   allow switching modes in-space with a clean room reset. Skip if it destabilises
   state; report the decision.

### T5 — Tests & verification (run yourself; never claim success without running)
- Add/extend unit tests: T1 provider recreation; T2 scenario hand-event mapping
  (incl. xiphoid-unsafe path and non-CPR-stage inertness); T4.1 AppModel reset on
  dismiss + opt-in preservation; T4.3 scenario reset clears debrief/stage.
- `xcodegen generate`, then build and test:
  `xcodebuild -project LifesaverVision.xcodeproj -scheme LifesaverVision
  -destination 'platform=visionOS Simulator,id=72F30C88-7E77-4710-BC36-4934D3F0809E'
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/LifesaverVision build` (+ `test`).
- Fix every error; report warnings honestly.

## Acceptance criteria
1. On a real Vision Pro: pumping motions register compressions in BOTH the CPR
   practice room and the integrated scenarios' CPR stage; pause → resume does not
   kill hand tracking.
2. On the simulator: every hand-instructed step is completable via visible
   accessible controls, with the honest "unavailable here" banner shown from the
   start (no misleading "temporarily unavailable").
3. From any scenario stage, debrief, or completed practice, the user can (a) restart
   the current experience in-place and (b) return to the dashboard — without force-
   exiting; re-entering the simulation afterwards starts clean (no stale debrief room).
4. AED placement room can go back to the preparation room.
5. No new claims of depth/force measurement anywhere; all new strings match the
   app's calm clinical tone.
6. Full build + test suite green on the visionOS 26.5 simulator destination.
