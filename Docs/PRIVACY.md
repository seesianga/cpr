# Privacy — Lifesaver Vision

Privacy-by-design commitments for the CPR + AED Spatial Academy. These bind every
current and future feature; changes require an update to this document and to
`App/PrivacyInfo.xcprivacy`.

## What the app NEVER collects
- Raw eye-tracking data (visionOS never exposes gaze to apps; we additionally never
  infer or log per-item gaze dwell).
- Raw hand-tracking recordings. `HandTrackingService` derives discrete practice events
  (cadence, zone classification, interruption timing, posture flags) and discards
  frames immediately; this is enforced in code review and documented in the service.
- Room scans beyond the active session's technical needs; nothing spatial is persisted.
- Health information unrelated to course administration.
- Real emergency-call audio (the 995 flow is simulation-only and never records).
- Continuous microphone audio. v1 uses no microphone at all; the Info.plist contains
  no microphone permission key.
- Learner video. Any future optional voice/video answer feature must implement the
  consent controls below before shipping.

## Optional recordings (future feature contract)
Any optional voice answer must have: explicit prior consent, a visible recording
indicator, an always-available stop control, learner review before upload, a delete
control, and a plain-language retention explanation. Absent all six, the feature
must not ship.

## What is stored, and where
| Data | Store | Purpose |
|---|---|---|
| Learner profile (display name, role, accessibility prefs, dominant hand) | SwiftData (on device) | Course operation |
| Progress, attempts, scores, badges | SwiftData | Learning record |
| Practical sign-off records | SwiftData | Instructor competency workflow |
| Consent records | SwiftData | Auditability of consent |
| Audit log (admin actions; hash-chained) | SwiftData | Accountability |
| Offline event queue | SwiftData | Sync when CloudKit available |
| Auth session token | Keychain (Apple secure storage) | Session continuity |

Local-first: the app is fully functional offline; CloudKit sync is an abstraction
(`SyncService`) with a no-op backend in this build. No third-party analytics SDK exists.

## Learner rights (implemented in Phase 3)
- **Export**: full personal-data export as JSON (xAPI-shaped learning events included).
- **Deletion**: account-deletion request flow purges local data and marks the deletion
  in the (personal-data-free) audit chain.
- **Retention**: administrator-configurable retention windows; expiry purges records.

## Logging rules
- `OSLog` diagnostic messages carry no learner-identifying data (enforced by redaction
  helpers; verified in tests).
- Crash/diagnostic exports contain no learner records.
- The AIVU production workflow never touches learner data (`Docs/AIVU_WORKFLOW.md` §6).

## Transparency to the learner (Module 0)
Module 0 teaches, in plain language: what is assessed and what is not, that 995 calls
are simulated, how hand tracking is used and discarded, how records are stored, the
difference between app completion records and accredited competency, and how to
exercise export/deletion.

## App privacy manifest
`App/PrivacyInfo.xcprivacy` declares no tracking, no tracking domains, and an **empty
collected-data list** (`NSPrivacyCollectedDataTypes: []`) — correct because all
learning records are stored locally on device and never transmitted in v1; nothing is
"collected" in the App Privacy sense. If a cloud backend ships, the manifest and this
document must be updated together as part of release review.
