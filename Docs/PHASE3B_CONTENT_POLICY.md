# Phase 3B Content Policy

**Version:** 1.0  
**Date:** 2026-08-07  
**Scope:** Non-clinical product requirements and verified implementation boundaries for
`Lifesaver Vision: CPR + AED Spatial Academy` content version 1.0.0.

This file is not a clinical authority. Medical statements must map to a fact in
`Docs/CLINICAL_FACTS_EXTRACT.json`; unresolved facts retain their supplied status.

## Orientation content requirements

Module 0 covers comfort and clear-space checks, dominant hand and supported input,
accessibility setup, data handling, hand-tracking limits, exit from simulation, a
clearly simulated 995 flow, the difference between internal completion and external
accreditation, instructor assessment, and an untimed unscored pre-course check.
Device-level controls may be used where the app has no dedicated setting. Authored
activities do not by themselves prove that a corresponding interactive view exists.

## Simulation and completion boundaries

Every 995 interaction is labelled `SIMULATION` and cannot place a call. Completion is
an internal learning record, not SRFAC certification. Practical competency requires a
qualified instructor's recorded decision; self-completion cannot replace it.

## Medical and sensing boundaries

Hand tracking must never be described as measuring real compression depth or force.
Without a verified external `CPRSensorProvider`, both remain labelled `Not physically
assessed`. Any available feedback is limited to supported sequence, placement-zone,
rhythm, interruption and posture signals. Content must not imply that a planned
practice view, metronome, spatial model or hand-derived score is already implemented.

## Data handling

The local-first LMS can retain learner profiles, enrolments, progress, attempts,
assessment results, feedback, practical sign-offs, consent and learning events. The
learner dashboard can export local records and request local account deletion through
`PrivacyOperationsService`. `App/PrivacyInfo.xcprivacy` declares no tracking and no
collected-data categories. `App/Info.plist` states that optional hand data is processed
on device and is not stored.

## Verified runtime boundaries

The current immersive attachment provides a persistent `Exit Simulation` control.
Settings currently expose captions, narration/music/effect levels, increased contrast
and reduced motion. The app does not yet expose a stored comfort calibration, a
dominant-hand preference, a dedicated input-method selector, lesson repeat controls,
a learner-originated practical-assessment request, live CPR/AED practice, a CPR
metronome or integrated scenario views. Course copy must distinguish authored content
and future interaction requirements from working runtime features.

## Module 9 access and review gating

Module 9 is awareness-only and unscored. It stays locked until Modules 0–8 are complete,
instructor approval is recorded and the externally supplied content lifecycle is
`clinicallyApproved` or `published`. Its immutable authored lifecycle remains
`clinicalReviewRequired` until the paediatric review items are resolved in a new
content version.

## Post-incident authoring boundaries

Structured reflection may ask what the learner noticed, which actions were taken,
where interruptions occurred, which feedback helped and what to rehearse next. It is
not a clinical grade. The supplied fact extract contains no decompression protocol or
refresher interval, so those blocks remain `clinicalReviewRequired` and cannot be used
in scored assessment without new evidence and qualified approval.
