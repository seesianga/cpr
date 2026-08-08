# Data Retention — Lifesaver Vision

Retention is administrator-configurable within the bounds below; the defaults are the
shipped values. All periods apply to on-device SwiftData records (and, once a cloud
backend is enabled, to synced replicas — same schedule, enforced server-side).

| Record type | Default retention | Bounds | Notes |
|---|---|---|---|
| Learner profile | Life of account | — | Deleted on account deletion |
| Progress / attempt records | 24 months after last activity | 6–60 months | Historical attempts keep their content version id |
| Assessment results | 24 months after last activity | 6–60 months | Needed for refresher scheduling |
| Practical sign-off records | 60 months | 12–120 months | Competency evidence for instructors |
| Instructor feedback | 24 months | 6–60 months | |
| Consent records | Life of account + 12 months | fixed | Evidence of consent |
| Audit log | 60 months | 24–120 months | Hash-chained; personal-data-free |
| Offline event queue | Until synced + 30 days | fixed | Purged after confirmed sync |
| Diagnostic logs (OSLog) | System-managed | — | No learner data present |
| Generated audio/media | Not personal data | — | Content assets, not records |

## Rules
1. Expiry runs on app launch and daily while active; expired records are purged, and a
   personal-data-free purge event is appended to the audit chain.
2. Account deletion overrides all retention: personal records purge immediately;
   the audit chain records a deletion marker (no personal payload).
3. Retention configuration changes are admin actions → audit-logged, effective
   prospectively, and never extend already-expired data.
4. Exports are generated on demand and not retained by the app.
5. Refresher reminders derive from attempt recency; if records expire, reminders
   simply restart from the next activity — no shadow copies are kept.
