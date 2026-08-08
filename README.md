# Lifesaver Vision — CPR + AED Spatial Academy

A premium Apple Vision Pro learning management system that turns hands-only CPR and
AED theory into guided, repeatable, measurable spatial practice — themed on the
Singapore Red Cross / SRFAC syllabus, with current SRFAC guidance controlling every
safety-critical instruction.

> **What this is not.** Not a medical device, not a substitute for emergency services
> or physical manikin practice, and completion records are **internal completion
> records — not SRFAC certification**. Practical competency requires the built-in
> instructor sign-off workflow with a qualified instructor.

## Experience
- **Dashboard (shared space)** — sign-in (Sign in with Apple / guest), course
  catalogue, progress, achievements, theory quizzes, settings; instructor and admin
  consoles behind roles.
- **Learning Laboratory (volumetric)** — interactive heart + lungs, the current
  7-ring Chain of Survival activity, AED component gallery, achievement cabinet.
- **Simulation Space (full immersion, always opt-in)** — DRSABC practice with a
  clearly-simulated 995 call, hands-only CPR practice with rhythm coaching, AED
  preparation/pad placement/shock flow with hard safety invariants, four integrated
  scenarios (home, shopping centre, workplace, community facility), and an
  after-action debrief with event replay. Exit and Pause are always visible.

## Quick start
Requirements: macOS 26+, Xcode 26.6 with the visionOS 26.5 SDK, XcodeGen
(`brew install xcodegen`). See `Docs/BUILD_ENVIRONMENT.md` for the audited versions.

```bash
cd LifesaverVision
xcodegen generate
xcodebuild -project LifesaverVision.xcodeproj -scheme LifesaverVision \
  -destination 'platform=visionOS Simulator,id=<your Vision Pro simulator UDID>' \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/LifesaverVision build
# run tests: replace `build` with `test`
# release gate:
Scripts/validate_build.sh
```
Open `Packages/RealityKitContent` in Reality Composer Pro from Xcode to edit scenes
(`Docs/REALITY_COMPOSER_PRO_WORKFLOW.md`).

## Medical-content governance (read before editing content)
- Ground truth: `Docs/CLINICAL_FACTS_EXTRACT.json` (every fact cited to source pages);
  precedence: current SRFAC guidance (2021/2022) over the 2018 manual —
  differences catalogued in `Docs/COURSE_SOURCE_DIFFERENCES.md`.
- Scored content is fail-closed gated by lifecycle + review status
  (`ClinicalSafetyValidator`); SME-pending items are listed in
  `Docs/MEDICAL_REVIEW_REQUIRED.md` with the sign-off template in
  `Docs/CLINICAL_APPROVAL_CHECKLIST.md`.
- Full mapping of objectives/lessons/questions/scenario actions to sources:
  `Docs/COURSE_TRACEABILITY_MATRIX.md` (script-generated).

## Key documents
| Topic | Document |
|---|---|
| Architecture and design decisions | `Docs/ARCHITECTURE.md` |
| Build environment (audited) | `Docs/BUILD_ENVIRONMENT.md` |
| Asset reuse + provenance (50 reused Tripo3D assets; no Tripo3D API use) | `Docs/ASSET_REUSE_REPORT.md`, `Docs/ASSET_PROVENANCE.md` |
| Reality Composer Pro workflow / scene manifest / Live Preview checklist | `Docs/REALITY_COMPOSER_PRO_WORKFLOW.md`, `Docs/RCP_SCENE_MANIFEST.md`, `Docs/RCP_LIVE_PREVIEW_CHECKLIST.md` |
| Apple Immersive Video workflow + QA (honest status) | `Docs/AIVU_WORKFLOW.md`, `Docs/AIVU_QA_REPORT.md` |
| Audio system + manifest (ElevenLabs, pre-generated, no runtime keys) | `Audio/ELEVENLABS_AUDIO_MANIFEST.json`, `Docs/reports/VOICE_DESIGN_DECISION.md` |
| Privacy / security / retention / threats | `Docs/PRIVACY.md`, `Docs/SECURITY_MODEL.md`, `Docs/DATA_RETENTION.md`, `Docs/THREAT_MODEL.md` |
| Accessibility audit | `Docs/ACCESSIBILITY_AUDIT.md` |
| Test + performance evidence | `Docs/TEST_REPORT.md`, `Docs/PERFORMANCE_REPORT.md`, per-phase reports in `Docs/reports/` |
| Known limitations (honest) | `Docs/KNOWN_LIMITATIONS.md` |

## Honesty principles baked into the product
- Compression **depth and force are never measured by vision** — labelled
  "Not physically assessed" unless a verified instrumented-manikin sensor
  (`CPRSensorProvider`) is connected; fabricated sensor values are structurally
  impossible and unit-tested.
- The 995 call is **always simulated** and marked as such; no real call can be placed.
- A simulated shock is **unreachable while anyone touches the casualty**; the clear
  check is interactive, never a button.
- Randomised scenario outcomes never alter clinical rules; speed never compensates
  for safety; unsafe completion earns zero XP.
