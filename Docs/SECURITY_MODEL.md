# Security Model — Lifesaver Vision

## Identity and authentication
- Sign in with Apple (AuthenticationServices) is the authenticated identity path;
  guest mode exists for demonstrations and stores no identity.
- Session state lives in the Keychain via `KeychainStore`; no force-unwrapped
  authentication state anywhere (enforced by code review + grep gate in CI checklist).
- Roles: `learner`, `instructor`, `admin`. Role checks in the client are a UX
  convenience only; the production deployment contract is that CloudKit/server-side
  permissions enforce authorization. The shipped build has no hard-coded admin
  credentials; admin bootstrap exists only in the Demo build configuration.

## Secrets
- No API keys in Swift sources, Info.plist, asset catalogues, the app bundle, or git
  history. The ElevenLabs key lives outside the repository (external credential file /
  environment variable) and is used by generation scripts only, never at app runtime.
- All core audio is pre-generated and cached; the app makes no ElevenLabs calls.
- A secret scan is part of build validation (Phase 8): pattern scan over the repo and
  the built .app for `sk_`, `xi-api-key`, `Authorization: Bearer`, key-shaped strings.
- `.gitignore` excludes `.env`, `*.xcconfig` with secrets, DerivedData and xcresult.

## Network
- v1 runtime performs no learner-data network traffic (local-first, no-op sync backend).
- When CloudKit sync is enabled: TLS is platform-enforced, CloudKit access follows
  least-privilege container scoping, and conflict handling never silently discards
  learner attempts (last-writer-wins with audit entries).
- No third-party network SDKs.

## Audit
- `AuditLogService` is append-only with hash-chained entries (each entry carries the
  previous entry's hash; chain integrity is unit-tested). Administrative actions
  (role changes, publish/retire, retention changes, deletion requests) are logged.
- Audit entries contain action metadata, never learner personal data payloads.

## Data protection
- SwiftData store relies on iOS/visionOS file-level Data Protection (device
  encryption at rest).
- Keychain items use default accessibility (device-unlocked) — no cloud-synced
  keychain classes for session tokens.
- Learner exports are generated on demand and handed to the system share/Files flow;
  the app keeps no extra export copies.

## Content integrity
- Course content is versioned; scored use requires `clinicallyApproved`/`published`
  lifecycle status (`ClinicalSafetyValidator` fail-closed, including nested scenario
  elements). Superseded versions preserve historical attempts (no retroactive edits).
- Asset integrity: copied 3D assets are SHA-256 verified against the Phase 1 inventory
  (`Scripts/validate_assets.py`); audio assets carry SHA-256 in the audio manifest.

## Platform permissions
- Minimal permission set: hand tracking only, with a graceful denied path (course
  completable via gaze+pinch). No microphone, no camera, no location, no contacts.

## Out of scope for v1 (documented, not claimed)
- Server-side LMS deployment hardening (rate limiting, server audit, SIEM) — the
  client is built against protocol abstractions; the hosted backend does not exist yet.
- MDM/enterprise distribution controls.
See `Docs/THREAT_MODEL.md` for the corresponding threat entries.
