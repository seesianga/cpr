# Phase 3 — LMS Core Report

Date: 7 August 2026

Platform: visionOS 26.5 simulator

Simulator: `72F30C88-7E77-4710-BC36-4934D3F0809E`

## Result

Phase 3 is implemented, generated, built and unit-tested. The final verification run completed 48 tests with no failures. All learner achievements and practical outcomes are described as internal completion records.

## What Was Built

### Local-first persistence

- A versioned SwiftData V1 schema and migration-plan stub covering learner profiles, progress, immutable versioned attempts, cohorts, enrolments, assessment results, badges, instructor feedback, practical sign-offs, course versions, offline events, consent, xAPI-shaped learning events and append-only audit entries.
- A local `ModelContainer` with CloudKit disabled. The UITest configuration uses an isolated in-memory container; normal configurations use the on-device store and fall back to memory if that store cannot open.
- SwiftData-backed course, progress, assessment, cohort, achievement, clinical-content, content-version and audit repositories. Existing in-memory preview/test repositories remain available.
- SHA-256 hash-chained audit entries with sequence numbers and integrity verification.
- A CloudKit-shaped sync boundary, durable offline queue, last-writer-wins-with-audit conflict handling and a simulator-safe `NoopCloudBackend`.

### Identity and roles

- Sign in with Apple through `AuthenticationServices`, with availability guards and no force-unwrapped authentication state.
- Complete guest mode and Keychain-backed session restoration.
- Learner, instructor and administrator roles. Production authorisation is documented as a server-side responsibility; local role checks are demonstration UI controls only.
- No embedded administrator credential. Administrator bootstrap exists only behind the `DEMO` compilation condition.

### Versioned and clinically gated content

- Versioned JSON loading and structural validation from `Resources/Courses`.
- Lifecycle states: draft, source checked, clinical review required, clinically approved, published, superseded and retired.
- Scored access only for clinically approved or published versions.
- Fail-closed `ClinicalSafetyValidator` handling missing facts, unknown facts/statuses, content-version mismatches and `requires_sme_review` facts.
- The authoritative extract contains 70 facts: 62 `source_checked` and 8 `requires_sme_review`. The latter are automatically excluded from scored activation.
- Publishing supersedes the prior published version without rewriting its course payload or historical attempts.

### Scoring, progression and assessments

- Safety-first scoring weights: scene safety 20%, recognition and activation 20%, CPR sequence and rhythm 25%, AED preparation and placement 20%, communication 10% and time 5%.
- Critical errors and safety-floor failures force scenario failure, mandatory remediation and zero XP eligibility. Speed cannot compensate for unsafe performance.
- Eight calm progression levels; level 8, Instructor-Verified Practitioner, requires an approved practical sign-off regardless of XP.
- Nine data-driven badge rules, practice streaks, computed spaced-repetition due dates, public leaderboard disabled by default, and no monetisation mechanics.
- Untimed single-choice, multiple-choice, ordering and hotspot-lite questions with stable choice identifiers.
- Explicit introduction, answer, review and submit states; accessible ordering controls; configurable pass thresholds; content-versioned attempt history; and per-question source references.

### Export, privacy and dashboards

- Typed xAPI-compatible JSON statements containing actor, verb, object, result and context, including a content-version IRI extension and opaque learner account identifier.
- Deterministic full learner JSON export, local deletion request/mark/purge flow and configurable retention enforcement. No learner payloads are sent to `os_log`.
- Role-scoped glass-material dashboards with semantic text and VoiceOver labels:
  - Learner: enrolments, resume position, progress, mastery-map placeholder, achievements, feedback, JSON export and account deletion.
  - Instructor: cohort CRUD, module and learner assignment, progress and versioned attempt review, critical errors, feedback, practical scheduling, qualitative manikin results, sign-off/rejection with remediation, and CSV/JSON reports.
  - Administrator: learner/instructor profile management, activation, instructor permissions, clinically gated publish/retire controls, threshold and badge configuration, aggregate-only analytics, audit viewer and retention controls.
- Compression depth and force remain `Not physically assessed` unless a verified external `CPRSensorProvider` supplies those measurements.

## Test Coverage Added

The 48-test target covers:

- exact score weights, invalid scores, critical-error failure, speed/safety interaction and zero XP;
- badge rules, streaks, spaced review dates and practical-sign-off gating of level 8;
- all four theory question types, threshold boundaries, explicit submission flow and source-backed review;
- clinical-fact and lifecycle gating, safe publishing and superseded-version preservation;
- xAPI statement shape and validation;
- guest/Apple session restoration, revocation and sign-out;
- every SwiftData repository, versioned attempt history and cohort membership history;
- audit-chain creation, concurrent appends and tamper detection;
- no-op, accepted and conflicting offline sync passes;
- full privacy export, account deletion and exact retention cut-offs; and
- deterministic JSON and correctly escaped CSV cohort reports.

## Verification Commands and Results

Commands were run from the project root.

### Project generation

```sh
xcodegen generate
```

Verbatim result:

```text
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

### LifesaverVisionTests

```sh
xcodebuild -project LifesaverVision.xcodeproj -scheme LifesaverVision \
  -destination 'platform=visionOS Simulator,id=72F30C88-7E77-4710-BC36-4934D3F0809E' \
  -derivedDataPath "$HOME/Library/Developer/Xcode/DerivedData/LifesaverVision" \
  test -only-testing:LifesaverVisionTests
```

Verbatim result lines:

```text
Test Suite 'LifesaverVisionTests.xctest' passed at 2026-08-07 21:22:34.504.
	 Executed 48 tests, with 0 failures (0 unexpected) in 1.827 (1.948) seconds
Test Suite 'All tests' passed at 2026-08-07 21:22:34.504.
	 Executed 48 tests, with 0 failures (0 unexpected) in 1.827 (1.953) seconds
** TEST SUCCEEDED **
```

## Warnings and Operational Notes

- The final build emitted one Xcode tooling warning:

```text
warning: Metadata extraction skipped. No AppIntents.framework dependency found.
```

  The app does not use App Intents, so no framework was added solely to suppress this metadata-tool notice.
- Two preliminary test launches were stopped while the simulator launch bridge was stale: the device had returned to Shutdown during one attempt, and an interrupted run left `SWBBuildService` waiting during another. The exact simulator was booted to terminal `Finished` status, the stale build service was restarted, the full test bundle rebuilt successfully, and the final normal `xcodebuild ... test` command passed.
- No compiler warnings or test failures were present in the final test invocation.

## Honest Limitations and Open Work

- Course lesson/assessment authoring remains Phase 3b. The bundled seed course intentionally contains review placeholders and is not available for scored use while its references remain flagged.
- `NoopCloudBackend` deliberately performs no remote transfer. A production CloudKit or server backend, authenticated server-side role enforcement and remote deletion propagation remain integration work.
- xAPI statements are exported locally; no Learning Record Store transport is included.
- The migration plan contains only V1 and an empty stage list. A future schema version must add an explicit migration stage.
- Practical sign-off supports qualitative manikin observations. Physical compression depth and force are not measured without a verified external sensor integration.
- Spaced-repetition due dates are computed, but notification delivery was intentionally outside scope.
- Aggregate analytics are local-device aggregates; they are not organisation-wide until a production backend is connected.

## Milestone Commits

```text
c05448e Phase 3.1: add versioned SwiftData LMS schema
9f8963a Phase 3.2: add local-first repositories and sync
3f2a804 Phase 3.3: add secure local authentication
dae8f57 Phase 3.4: add clinically gated course lifecycle
2dd2791 Phase 3.5: add safety-first scoring and progression
35c8c83 Phase 3.6: add accessible theory assessment flow
4794a07 Phase 3.7: add xAPI export and privacy operations
d4826a4 Phase 3.8: add role-based LMS dashboards
5ab6f3e Phase 3.9: add LMS core test coverage
```
