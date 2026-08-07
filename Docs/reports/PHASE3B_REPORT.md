# Phase 3B — Course Content Authoring Report

Date: 7 August 2026

Course: `Lifesaver Vision: CPR + AED Spatial Academy`

Content version: `1.0.0` (`en-SG`)

Platform: visionOS 26.5 simulator

Simulator: `72F30C88-7E77-4710-BC36-4934D3F0809E`

## Result

Phase 3B is authored, generated, decoded through `CourseEngine`, built and unit-tested. The final unit-test run completed 61 tests with no failures. The traceability generator mapped 698 items with zero unmapped items, and all 460 scored trace rows resolve only to facts whose supplied status permits scored use.

This result is a technical and source-traceability pass, not clinical sign-off. The supplied fact extract contains 62 `source_checked` facts, eight `requires_sme_review` facts and zero `clinically_approved` facts. No source status was upgraded without a named reviewer.

## What Was Built

### Versioned course

- Eleven ordered modules, M0 through M10, with 11 lessons, 32 learning objectives, 103 content blocks, 27 activities, 11 assessments, 66 embedded questions and four integrated scenarios.
- All requested orientation, recognition, Chain of Survival, DRSABC, hands-only CPR, AED, special-circumstance, integrated-scenario, paediatric-awareness and post-incident topics are represented.
- Seven guideline-update cards required by the course-source reconciliation, plus one separately labelled operational-review card for the unresolved AED battery cadence.
- Every medical learning objective, content block, activity, question, scenario action, error and feedback statement carries one or more `SourceReference` values. Product-authored behaviour is traced to `Docs/PHASE3B_CONTENT_POLICY.md` rather than presented as clinical guidance.
- Completion remains an internal learning record, not SRFAC certification. Practical competency requires instructor sign-off. Compression depth and force remain labelled `Not physically assessed`, and all 995 practice is explicitly `SIMULATION` and never places a call.

### Content-block clinical lifecycle

| Content-block status | Count |
|---|---:|
| `sourceChecked` | 92 |
| `clinicalReviewRequired` | 11 |
| **Total** | **103** |

The 11 review-required blocks are the disputed Chain of Survival items (`M2-B1`, `M2-B4`), six locked paediatric-awareness blocks (`M9-B1`, `M9-B4`, `M9-B5`, `M9-B8`, `M9-B9`, `M9-B10`), the unresolved AED battery-cadence card (`M10-B5A`), and the unsupported decompression/refresher blocks (`M10-B6`, `M10-B7`). Their containing modules M2, M9 and M10 carry aggregate `clinicalReviewRequired` lifecycle metadata. Only M9 has an access lock.

### Theory question bank

- `Resources/Questions/theory_questions_v1.json` contains exactly six questions for each of M0–M10: 66 questions across 11 module sets.
- M1–M8 and M10 are scored. M0 is an unscored pre-course check, and M9 is awareness-only and unscored.
- Every answer points to an existing fact ID and matching source citation. No scored question reaches a `requires_sme_review`, missing or unknown fact.
- Distractors are source-refutable and the bank contains no scored trick question about a review-flagged item.

### Scenario definitions

- `Resources/Courses/scenarios_v1.json` defines Home, Shopping centre, Workplace and Community facility scenarios.
- It contains 11 AED learning states, 12 transitions, all five approved three-analysis outcome pools, 52 critical actions, 48 critical errors and 192 feedback statements.
- Every scenario contains the six scoring categories used by `ScoringEngine`. Randomisation selects only a listed shock/no-shock pool and cannot alter DRSABC, CPR, clear-check, shock, resumption or stopping rules.
- All scenario medical references are `source_checked`; no flagged paediatric or seven-ring fact is reachable from scored scenarios.

### Schema and clinical gating

- Added explicit module access requirements, module/block lifecycle, scored-versus-unscored assessment metadata, question-bank and scenario-definition codecs, and a deterministic M9 access evaluator.
- M9 remains locked until M0–M8 are complete, instructor approval is recorded, and the external course lifecycle is `clinicallyApproved` or `published`.
- `ClinicalSafetyValidator` now checks questions individually, cannot let an assessment-level citation mask a missing question citation, and omits unscored M0/M9 assessments from the scored catalogue.
- Legacy Phase 3 content continues to decode through defaulted fields.

### Generated review and traceability records

- `Scripts/build_course_content.py` reproducibly emits the course from the approved fact extract, external question bank and scenario definitions.
- `Scripts/generate_traceability_matrix.py` generates `COURSE_TRACEABILITY_MATRIX.md`, `MEDICAL_REVIEW_REQUIRED.md` and `CLINICAL_APPROVAL_CHECKLIST.md` and fails on unmapped content, citation/status drift, blocked scored facts, incomplete scenario mapping or incorrect M9 access rules.
- The medical-review register lists every explicit or inherited review-required item and all S1–S12 reconciliation decisions. The checklist leaves reviewer, date and decision fields blank for a qualified SRFAC instructor or clinical SME.
- A read-only wording review found no material manual-sentence copying; learner copy is paraphrased in British/Singapore English.

## Verification Commands and Verbatim Results

Commands were run from the project root. DerivedData remained outside the Google Drive checkout.

### Content and traceability generation

```sh
python3 Scripts/build_course_content.py
python3 Scripts/generate_traceability_matrix.py
python3 -m unittest Tests/test_traceability_generator.py
```

Verbatim result:

```text
Wrote Resources/Courses/course_v1.json: 11 modules, 103 content blocks
PASS: 698 mapped trace rows, 0 unmapped; wrote Docs/COURSE_TRACEABILITY_MATRIX.md, Docs/MEDICAL_REVIEW_REQUIRED.md and Docs/CLINICAL_APPROVAL_CHECKLIST.md
.
----------------------------------------------------------------------
Ran 1 test in 0.676s

OK
```

### Focused Phase 3B simulator validation

```sh
xcodebuild -project LifesaverVision.xcodeproj -scheme LifesaverVision \
  -destination 'platform=visionOS Simulator,id=72F30C88-7E77-4710-BC36-4934D3F0809E' \
  -derivedDataPath "$HOME/Library/Developer/Xcode/DerivedData/LifesaverVision" \
  test -only-testing:LifesaverVisionTests/CourseContentValidationTests
```

Verbatim result lines:

```text
Test Suite 'CourseContentValidationTests' passed at 2026-08-07 22:43:59.698.
	 Executed 7 tests, with 0 failures (0 unexpected) in 0.567 (0.582) seconds
Test Suite 'Selected tests' passed at 2026-08-07 22:43:59.773.
	 Executed 7 tests, with 0 failures (0 unexpected) in 0.567 (0.659) seconds
** TEST SUCCEEDED **
```

### Project generation

```sh
/opt/homebrew/bin/xcodegen generate
```

Verbatim result:

```text
⚙️  Generating plists...
⚙️  Generating project...
⚙️  Writing project...
Created project at /Users/angseesiang/Library/CloudStorage/GoogleDrive-ang.see.siang@gmail.com/My Drive/macbook/CPR/LifesaverVision/LifesaverVision.xcodeproj
```

### Full build

```sh
xcodebuild -project LifesaverVision.xcodeproj -scheme LifesaverVision \
  -destination 'platform=visionOS Simulator,id=72F30C88-7E77-4710-BC36-4934D3F0809E' \
  -derivedDataPath "$HOME/Library/Developer/Xcode/DerivedData/LifesaverVision" build
```

Verbatim result:

```text
** BUILD SUCCEEDED **
```

### Complete LifesaverVisionTests target

```sh
xcodebuild -project LifesaverVision.xcodeproj -scheme LifesaverVision \
  -destination 'platform=visionOS Simulator,id=72F30C88-7E77-4710-BC36-4934D3F0809E' \
  -derivedDataPath "$HOME/Library/Developer/Xcode/DerivedData/LifesaverVision" \
  test -only-testing:LifesaverVisionTests
```

Verbatim result lines:

```text
Test Suite 'LifesaverVisionTests.xctest' passed at 2026-08-07 22:47:21.949.
	 Executed 61 tests, with 0 failures (0 unexpected) in 3.089 (3.190) seconds
Test Suite 'All tests' passed at 2026-08-07 22:47:21.949.
	 Executed 61 tests, with 0 failures (0 unexpected) in 3.089 (3.215) seconds
** TEST SUCCEEDED **
```

Result bundle:

```text
/Users/angseesiang/Library/Developer/Xcode/DerivedData/LifesaverVision/Logs/Test/Test-LifesaverVision-2026.08.07_22-45-54-+0800.xcresult
```

## Warnings and Operational Notes

- The final build emitted this Xcode tooling warning:

```text
warning: Metadata extraction skipped. No AppIntents.framework dependency found.
```

  The app does not use App Intents, so no framework was added only to suppress the metadata-tool notice.
- The simulator test process also logged a missing audio plug-in factory and unsupported `TCP_INFO` queries. They did not produce a test failure or affect the content validation.
- One preliminary temporary-project run was stopped after a simulator test attempted to read the source-tree traceability Markdown through FileProvider and stalled. That unsuitable device-side check was removed. Traceability generation is instead executed and asserted by the host-side `Tests/test_traceability_generator.py`; the final real-project simulator runs passed normally.
- The three pre-existing untracked documentation files in the working tree were not edited, staged or committed.

## Honest Limitations and Required Clinical Work

- There is no clinical approval in the supplied ground truth. `source_checked` means citation-checked, not approved by an SME. The `.clinicallyApproved` lifecycle used in one test is an in-memory fixture that proves the gate; it is not a real sign-off or release decision.
- M2's seven-ring presentation is provisionally based on the 2022 manual but remains review-required and unscored because the supplied 2021 and 2022 sources disagree on ring count.
- M9 is locked and unscored. It deliberately withholds an inferred paediatric technique until all cited paediatric conflicts are resolved, adult-core completion is recorded, an instructor approves access and a new course lifecycle is clinically approved.
- M10 does not prescribe a decompression protocol or refresher interval because neither exists in the approved extract. The AED battery cadence also awaits site/SME confirmation.
- No local product-brief file containing section 6.4, an exact critical-error list or an authoritative 11-state AED taxonomy could be recovered. The scenario document records this provenance. Apart from the existing `unsafe.contact_during_aed_analysis` code, state labels and error identifiers are project-authored organisation of source-backed positive rules and their direct unsafe inverses; they are not represented as recovered brief wording.
- This phase delivers versioned content, codecs, safety gating and definitions. It does not add a complete runtime `ScenarioEngine`, scenario UI, metronome, hand-derived CPR quality feedback or physical sensor integration. Current UI copy explicitly avoids claiming those placeholders are operational.
- Hand tracking cannot measure compression depth or force. No fabricated sensor values are present.
- The course has `releasedAt: null` and must not be published or represented as SRFAC-accredited until the qualified review checklist is completed and a new reviewed version passes the same generators and tests.

## Milestone Commits

```text
eb243b2 Phase 3b.1: add safe content schemas and question bank
a4f64b1 Phase 3b.2: add integrated scenario definitions
ccf2734 Phase 3b.3: author course modules 0-10
d4679c3 Phase 3b.4: generate clinical traceability documents
fea450e Phase 3b.5: validate clinical course content
```

The final report handoff is committed separately with the required message `Phase 3b: course content v1`.
