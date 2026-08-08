# Architecture — Lifesaver Vision

## System shape
A local-first visionOS app with three presentation modes and a strict separation
between clinical logic (pure, tested Swift) and presentation (SwiftUI/RealityKit).

```
┌────────────────────────────── SwiftUI scenes ──────────────────────────────┐
│ WindowGroup "Dashboard"      Volumetric "LearningLab"    ImmersiveSpace     │
│ (LMS: learner/instructor/    (heart+lungs, chain rings,  "SimulationSpace"  │
│  admin, lessons, quizzes)     AED gallery, achievements)  (DRSABC/CPR/AED/  │
│                                                           scenarios+debrief)│
└───────────────┬─────────────────────┬──────────────────────────┬───────────┘
                │                     │                          │
        Feature view models   AssetRegistry (scene compose,      │
                │             semantic decoration, lazy USDZ)    │
                ▼                     ▼                          ▼
┌──────────────────────────── Core engines (pure Swift) ─────────────────────┐
│ CourseEngine · ContentVersionService · ClinicalSafetyValidator (fail-closed)│
│ ScenarioEngine · DRSABC/CPR/AED state machines (event-sourced, replayable)  │
│ ScoringEngine (safety-first weights) · GamificationEngine (levels/badges)   │
│ AudioDirector (channels, ducking, AED hard-stops) · HandTrackingService     │
│ CPRSensorProvider (verified-only measurements)                              │
└───────────────┬────────────────────────────────────────────────────────────┘
                ▼
┌────────────── Persistence & services (protocol-injected) ──────────────────┐
│ SwiftData repositories (Course/Progress/Assessment/Cohort/Achievement/      │
│ ClinicalContent) · AuditLogService (hash-chained) · SyncService             │
│ (offline queue → CloudKit abstraction; NoopCloudBackend in v1)              │
│ AuthenticationService (Sign in with Apple + guest) · KeychainStore          │
└────────────────────────────────────────────────────────────────────────────┘
```

## Load-bearing design decisions
1. **Content is data, never code.** The whole course (Modules 0–10, questions,
   scenarios) is versioned JSON in `Resources/Courses` + `Resources/Questions`. Every
   medical statement carries `SourceReference` rows (document/edition/section/page/
   reviewStatus/reviewer/date/contentVersion) tied to `Docs/CLINICAL_FACTS_EXTRACT.json`.
   `Scripts/generate_traceability_matrix.py` regenerates the full mapping and fails on
   unmapped items.
2. **Fail-closed clinical gating.** `ClinicalSafetyValidator` refuses scored use of any
   content whose facts are not clinically approved / carry `requires_sme_review`,
   including nested scenario sub-elements. Module presentation flows exclusively
   through `CourseEngine.presentableModules(for:)` (Module 9 locked until instructor
   approval + approved lifecycle).
3. **Event-sourced practice machines.** DRSABC/CPR/AED machines reject invalid
   transitions, log every event, and replay deterministically — debrief timelines and
   critical-error replays derive purely from the logged events. AED hard invariants
   (no shock while touching; interactive clear-check; mandatory resume-compressions)
   live in the machine, not the UI.
4. **Honest measurement boundary.** Vision-derived hand tracking yields only cadence,
   zone classification, interruption timing and posture heuristics. Depth/force can
   only ever come from a verified `CPRSensorProvider`; unverified sources are
   structurally unable to surface measurements (unit-tested), and UI labels them
   "Not physically assessed".
5. **Runtime scene composition.** `.rkassets` holds only scene skeletons + original
   hand-authored clinical models; the 50 Tripo USDZs ship as loose bundle resources
   attached lazily at named anchors (694→149 MiB lesson learned), cached with eviction.
6. **Local-first, sync-optional.** Everything works offline; `OfflineFirstSyncService`
   queues events for a CloudKit-shaped backend (no-op in v1) with
   last-writer-wins-plus-audit conflict policy.
7. **Pre-generated audio only.** All speech/SFX/music is generated at build time via
   `Scripts/ElevenLabs/generate_audio.py` (manifest + SHA-256 + VTT captions); the app
   makes zero ElevenLabs calls and contains no keys. Only text present in approved
   course data is voiced.

## Build system
XcodeGen (`project.yml`) generates `LifesaverVision.xcodeproj`. Targets:
app + `LifesaverVisionTests` + `LifesaverVisionUITests`; configurations Debug-Beta /
Release-Stable / UITest / Demo (admin bootstrap exists only in Demo). Local package
`Packages/RealityKitContent`. Swift 6, strict concurrency, zero third-party runtime
dependencies. Canonical commands: `Docs/BUILD_ENVIRONMENT.md`.

## Directory map
See AGENTS.md §Architecture for the folder layout; every feature area lives in
`Features/<Name>` with views + observable session models, spatial services under
`Spatial/`, engines under `Core/Services`, models under `Core/Models`.

## Verification chain (how we know it works)
Phase reports in `Docs/reports/` record verbatim build/test output per phase; the
adversarial clinical audit and its remediation are `AUDIT_FINDINGS_CONTENT_V1.md` +
`PHASE4R_REPORT.md`; `Scripts/validate_build.sh` is the release gate (secret scan,
Tripo prohibition, manifests, wording safety, dependency audit); `Docs/TEST_REPORT.md`
aggregates the final state.
