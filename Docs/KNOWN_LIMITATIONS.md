# Known Limitations — Lifesaver Vision v1

An honest register. Items are grouped by whether they are inherent product boundaries
(by design), environment boundaries (couldn't be exercised in this build environment),
or open work.

## By design (permanent boundaries, communicated to learners in Module 0)
1. **No physical depth/force measurement.** Vision-based hand tracking cannot measure
   compression depth or force; the app scores sequence, hand-placement zone, rhythm,
   interruptions and posture heuristics only. Depth/force display requires a verified
   instrumented manikin via `CPRSensorProvider`; no such device is bundled.
2. **Not certification.** Completion records are internal; SRFAC accreditation and
   instructor-supervised practical/theory assessment are outside the app. The
   instructor sign-off workflow records competency decisions; it does not confer
   accreditation.
3. **Simulated emergency calls only.** The 995 flow never dials and is permanently
   badged as simulation.
4. **Not a medical device / no real-emergency use.** Training and rehearsal only.

## Environment boundaries (marked operator-pending, not claimed)
5. **No physical Apple Vision Pro testing.** All builds/tests ran on the visionOS 26.5
   simulator. Operator-pending: spatial-audio localisation, comfort validation, live
   hand-tracking behaviour and permission UX, VoiceOver traversal in immersion,
   frame pacing/thermals via Instruments (`Docs/PERFORMANCE_REPORT.md`),
   RCP Live Preview checklist (`Docs/RCP_LIVE_PREVIEW_CHECKLIST.md`).
6. **No Apple Immersive Video masters.** No compliant MV-HEVC 4320×4320@90 capture or
   render pipeline was available; the three planned immersive videos are unproduced.
   The AIVU workflow, requirements and QA register are complete and executable when a
   pipeline exists; the app is fully functional without the media
   (`Docs/AIVU_QA_REPORT.md`).
7. **Subjective audio review pending.** All 107 generated audio assets carry
   `approvalStatus: pending_operator_listening`; loudness/clarity were verified only
   by measurement (LUFS/STT round-trip). Singapore-English pronunciation review by a
   local reviewer is pending (tracked in the "Outstanding" section of
   `Docs/reports/VOICE_DESIGN_DECISION.md`).

## Clinical review state (fail-closed until resolved)
8. **Nothing is `clinically_approved` yet.** All active facts are `source_checked`
   against the SRFAC sources; 8 facts + the items in `Docs/MEDICAL_REVIEW_REQUIRED.md`
   need a qualified SRFAC instructor / clinical SME. Until then the content version
   cannot move to the approved lifecycle state, and Module 9 (child & infant AED
   awareness) remains locked and unscored. M2/M10 scored assessments run under a
   documented waiver (all their question facts are source-checked).
9. **Dispatcher and bystander voices unvoiced.** No approved dialogue text exists, so
   these roles are visual + captioned only (grounding rule: only approved course text
   is synthesised).

## Open work (not started or partial)
10. **Cloud backend.** `SyncService` is a CloudKit-shaped abstraction with an offline
    queue and a no-op backend; no server deployment, real CloudKit container, or
    server-side role enforcement exists (client contracts + threat-model entries R1/R2).
11. **Localisation.** Architecture is localisation-ready; en-SG is the only locale.
12. **Spaced-repetition notifications.** Due dates are computed and shown in-app; no
    push/local notifications are scheduled.
13. **Leaderboards/cohort comparison.** Deliberately absent (privacy defaults); cohort
    comparison would need the consent + pseudonym design in `Docs/PRIVACY.md` first.
14. **Xcode beta pairing.** The assignment names "Reality Composer Pro 3 Beta" and
    beta build configurations; this machine has release Xcode 26.6 + its bundled RCP.
    Config names (Debug-Beta etc.) are honoured; no beta-only API is used.
