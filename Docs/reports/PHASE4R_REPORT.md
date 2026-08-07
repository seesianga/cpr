# Phase 4R — Remediation Report

Date: 8 August 2026

Product: `Lifesaver Vision: CPR + AED Spatial Academy`

Simulator: visionOS 26.5, `72F30C88-7E77-4710-BC36-4934D3F0809E`

## Result

Phase 4R is complete. The Debug-Beta app is **156,456,890 bytes (149.21 MiB)**,
well below the approximately 300 MB target and 78.51% smaller than the Phase 4
baseline. The final build succeeded, the complete `LifesaverVisionTests` target passed
76 tests with zero failures, the 13 composed scene contracts passed, and all 50 loose
USDZ resources loaded for an explicit 13 + 50 = 63-resource runtime audit.

The clinical traceability generator reports 698 mapped rows with zero unmapped. Moving
the two unresolved M2 ring questions to awareness-only use reduced the scored subset
from 460 to 456 rows without removing them from learning or review.

## Bundle-size result

Sizes are sums of regular files in the canonical Debug-Beta `.app`, not the UITest app.
The source USDZ files are compressed USDZ containers, while the old compiled RealityKit
archive expanded their payloads substantially.

| Measurement | Before Phase 4R | Final Phase 4R | Change |
|---|---:|---:|---:|
| Debug-Beta app regular-file bytes | 728,000,264 (694.28 MiB) | 156,456,890 (149.21 MiB) | −571,543,374 bytes (−78.51%) |
| Debug-Beta app allocated size | 710,992 KiB | 152,936 KiB | −558,056 KiB |
| `RealityKitContent.reality` | 716,251,834 bytes (683.07 MiB) | 2,351,118 bytes (2.24 MiB) | −713,900,716 bytes |
| Loose bundled USDZ resources | none | 50 files; 141,007,707 bytes (134.48 MiB) | lazy-loadable payloads |

The package catalogue now contains exactly 19 authored USDA layers: 13 scene skeletons
and six original model/helper layers. It contains zero USDZ payloads and no USDA file
hard-references a USDZ. The 50 approved delivery assets are copied into the app's
`USDZ/` resource directory.

`AssetRegistry` reads `spatial_asset_manifest_v1.json`, loads a skeleton from
`realityKitContentBundle`, asynchronously loads each mapped USDZ with
`Entity(contentsOf:)`, renames it to its semantic contract name, and attaches it to the
declared empty anchor. Its cache is per scene and explicit release removes the root from
its parent and evicts it. The learning-lab and simulation roots release the exact scene
they loaded when they exit.

## Adversarial-audit dispositions

| Finding | Disposition | Verification |
|---:|---|---|
| 1 — 995 dialogue exceeds cited fact | Chose the safer wording-only option. M3-B4 and M3-A2 now rehearse answering the simulated dispatcher's questions and hanging up only when told. The unsupported location, callback, incident and casualty-count beats were removed; no new clinical fact was invented. | Content-topic regression and full traceability pass. |
| 2 — module access evaluator has no production caller | Added the sole `CourseEngine` module-listing API, `presentableModules(for:)`. It reads the authoritative repository lifecycle and filters every module through `ModuleAccessEvaluator`; the raw `course` and `activeCourse` engine bypasses were removed. | Three engine-level tests cover missing prerequisites, missing instructor approval, review-required lifecycle and the approved unlock path. Phase 5 presentation UI must call this API. |
| 3 — nested scenario references skipped | The course now embeds each complete `ScenarioDefinition`. `ClinicalSafetyValidator` and `CourseStructureValidator` traverse the scenario, initial state, branches, conditions, all nested feedback, critical actions and critical errors. | An injected `requires_sme_review` fact on a critical error excludes the scenario and makes activation fail. |
| 4 — review-required containers can contain scored assessments | Added exact, documented `ScoredUseWaiver` metadata for M2 and M10. The validator requires full container/block coverage and a non-empty rationale, and a waiver can never override a blocked scored reference. `q-m2-01` and `q-m2-05` are awareness-only; scoring uses only `Question.isScored == true`. | Missing, invalid, exact and blocked-reference waiver regressions pass; changing an unscored response does not change the score. The generated medical-review register records both waivers and their boundaries. |
| 5 — no-shock path omits clear action | Added each scenario's `action-clear-for-aed` to every `noShockOutcome`, before resume CPR. | Swift and generator checks assert both `shockOutcome` and `noShockOutcome` require the clear action in all four scenarios. |
| 6 — clause-level echoes | Rephrased M3-B2 and the shoulder-response critical action in all four scenarios while preserving the cited meaning. | Authored sources were regenerated into `course_v1.json`; the old phrases no longer occur in learner content. |
| 7 — traceability conventions and S11 | Added the assessment-container/choice-ID convention and the explicit S11 exclusion for the four uncited ventilation facts. The generator enforces that the uncited-fact set is exactly those four IDs. | Matrix regeneration and Python regression pass at 698 mapped / 456 scored rows. |

## Final verification

Commands were run from the project root with DerivedData outside the Google Drive
checkout:

```text
python3 Scripts/build_course_content.py
python3 Scripts/generate_traceability_matrix.py
python3 -m unittest Tests/test_traceability_generator.py
python3 Scripts/validate_assets.py
/opt/homebrew/bin/xcodegen generate
xcodebuild -project LifesaverVision.xcodeproj -scheme LifesaverVision \
  -destination 'platform=visionOS Simulator,id=72F30C88-7E77-4710-BC36-4934D3F0809E' \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/LifesaverVision build
xcodebuild -project LifesaverVision.xcodeproj -scheme LifesaverVision \
  -destination 'platform=visionOS Simulator,id=72F30C88-7E77-4710-BC36-4934D3F0809E' \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/LifesaverVision \
  test -only-testing:LifesaverVisionTests
```

Traceability output, verbatim:

```text
PASS: 698 mapped trace rows, 0 unmapped; wrote Docs/COURSE_TRACEABILITY_MATRIX.md, Docs/MEDICAL_REVIEW_REQUIRED.md and Docs/CLINICAL_APPROVAL_CHECKLIST.md
```

Asset-validator output, verbatim:

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

Build result, verbatim:

```text
** BUILD SUCCEEDED **
```

Complete unit-test result, verbatim:

```text
Test Suite 'RealityKitAssetTests' passed at 2026-08-08 01:10:40.640.
Test Suite 'LifesaverVisionTests.xctest' passed at 2026-08-08 01:10:42.739.
	 Executed 76 tests, with 0 failures (0 unexpected) in 71.214 (71.338) seconds
Test Suite 'All tests' passed at 2026-08-08 01:10:42.740.
	 Executed 76 tests, with 0 failures (0 unexpected) in 71.214 (71.346) seconds
** TEST SUCCEEDED **
```

The result bundle is:

```text
/Users/angseesiang/Library/Developer/Xcode/DerivedData/LifesaverVision/Logs/Test/Test-LifesaverVision-2026.08.08_01-08-14-+0800.xcresult
```

## Diagnostics and remaining boundary

Xcode emitted the existing App Intents metadata warning because the target has no
`AppIntents.framework` dependency. During successful raw-USDZ and composed-scene tests,
the simulator also emitted RealityKit `NetworkAssetManager` dependency diagnostics.
They did not produce load, contract or test failures.

Phase 5 still owns the learner-facing catalogue UI and scenario presentation. That UI
must use `CourseEngine.presentableModules(for:)` and keep the existing engines
authoritative; Phase 4R supplies and tests the enforced API but does not claim an
unimplemented UI path is runtime-demonstrated.

## Milestone commits

- `ae111c1` — `Phase 4R.1: restructure assets for lazy loading`
- `7fe570d` — `Phase 4R.2: remediate adversarial audit findings`
- Final report and regenerated project: `Phase 4R: audit remediation + lazy asset loading`
