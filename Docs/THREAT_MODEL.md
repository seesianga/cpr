# Threat Model — Lifesaver Vision

Scope: the visionOS client, its local data, the generation-time tooling, and the
declared (not yet deployed) cloud sync contract. Method: STRIDE over the data-flow
surfaces, plus domain-specific abuse cases for a medical-training product.

## Assets worth protecting
A1 learner personal data and learning records; A2 instructor sign-off integrity;
A3 clinical content integrity (the thing that keeps instruction safe); A4 audit chain;
A5 ElevenLabs API key (generation-time only); A6 app binary/asset integrity.

## Trust boundaries
B1 device ↔ future CloudKit backend; B2 repo/build machine ↔ external credential file;
B3 app ↔ copied media assets; B4 production AIVU review network; B5 roles inside the app
(learner/instructor/admin).

## Threats and mitigations
| # | Threat (STRIDE) | Surface | Mitigation | Status |
|---|---|---|---|---|
| T1 | Spoofing learner identity | B5 | Sign in with Apple; Keychain session; guest mode carries no identity | Implemented |
| T2 | Elevation to admin (client tampering) | B5 | No hard-coded admin; Demo-only bootstrap; production contract = server-side role enforcement | Implemented client-side; server pending |
| T3 | Tampering with clinical content to teach unsafe instruction | A3 | Versioned content; lifecycle gating (`ClinicalSafetyValidator`, fail-closed incl. nested scenario elements); traceability matrix regeneration in CI; SHA-256 asset checks | Implemented |
| T4 | Repudiation of admin actions | A4 | Append-only hash-chained audit log; integrity unit tests | Implemented |
| T5 | Information disclosure of learner records via logs/exports | A1 | Redacted OSLog; exports on demand only; no analytics SDK | Implemented |
| T6 | Information disclosure via AIVU review sessions | B4 | Isolated network / Developer Strap; no learner data on review machines; naming rules | Procedural (documented, operator-enforced) |
| T7 | API key leakage | A5, B2 | Key never in repo/bundle; env/external file only; secret scan in build validation | Implemented |
| T8 | Denial of service — CloudKit unavailable | B1 | Local-first; offline queue; no data loss on sync failure (tested) | Implemented |
| T9 | Sync conflict data loss | B1 | Last-writer-wins with audit entries; attempts never silently discarded | Implemented (client contract); server pending |
| T10 | Tampered media assets (malicious USDZ/audio swap) | B3, A6 | SHA-256 manifests for 3D and audio; validation scripts; code-signed bundle | Implemented |
| T11 | Fabricated competency (badge/sign-off forgery) | A2 | Level 8 unreachable without `PracticalSignOff`; sign-off records retained 60 months; "internal completion record" wording — never certification | Implemented |
| T12 | Fabricated sensor data (fake depth/force) | A3 | `CPRSensorProvider` verified-source contract; unverified sources can never surface measurements (unit-tested) | Implemented |
| T13 | Privacy regression via future voice/video features | A1 | Six-control consent contract in PRIVACY.md is a shipping gate | Procedural |
| T14 | Supply-chain: third-party packages | A6 | Zero third-party runtime packages; XcodeGen is build-time only (2.46.0 recorded in BUILD_ENVIRONMENT; not brew-pinned — version drift possible, accepted for a build-time tool) | Implemented with accepted residual |

## Abuse cases specific to this product
- Learner grinding unsafe speed-runs for XP → scoring gives zero XP on critical error;
  speed weight 5% and cannot offset safety floors (tested).
- Instructor bypassing practical assessment → sign-off requires explicit recorded
  manikin-based results; audit-logged.
- Content editor inserting SME-pending paediatric guidance into scored flow →
  validator fail-closed (regression-tested after audit finding 3).

## Residual risks (accepted, documented)
- R1 The production server/backend does not exist yet; all server-side enforcements
  are contracts, not deployments (tracked in KNOWN_LIMITATIONS).
- R2 Client-side role UX gating can be bypassed on a jailbroken device; harm is limited
  to the local device's own data because there is no shared backend in v1.
- R3 AIVU transport security is procedural, not technical.
