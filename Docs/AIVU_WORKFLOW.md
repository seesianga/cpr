# Apple Immersive Video Utility — Production Workflow

Tool: `/Applications/Apple Immersive Video Utility.app` (installed; availability verified
in Phase 1 — see `Docs/BUILD_ENVIRONMENT.md`). AIVU is used for importing, organising,
reviewing and validating Apple Immersive Video media on Apple Vision Pro. It is not an
in-app SDK; nothing in the app links against it.

## 1. Media production targets (full-quality master)
| Property | Target |
|---|---|
| Codec | MV-HEVC (stereoscopic) |
| Delivery resolution | 4320 × 4320 per eye |
| Frame rate | 90 fps |
| Dynamic range / colour | HDR, P3-D65 PQ |
| Metadata | Valid AIME (from a compliant camera/render pipeline — **never fabricated**) |
| Audio | MP4 with Apple Spatial Audio Format; 5th-order ambisonics and/or object-based |
| Presentation track | Camera changes and transitions authored where applicable |
| Package | Final `.aivu` |

Anti-fraud rules (binding): do not rename ordinary stereo/mono media as Apple Immersive
Video; do not fake AIME metadata; lower-quality development media is labelled test media
and used for workflow testing only.

## 2. Content plan
Three short, calm, non-graphic candidates (scripts derive from approved course content
only): Chain of Survival Opening (20–40 s), Recognise and Respond (30–60 s), AED Clear
Sequence (30–60 s). Essential interaction stays in RealityKit; video is supporting media.

## 3. AIVU workflow (per media item)
1. Import candidate media into AIVU (File → Import).
2. Organise into the review playlist for its module (Playlists/).
3. Verify technical properties in the inspector (codec, per-eye resolution, frame rate,
   colour space, AIME status, audio format, presentation track).
4. Connect Apple Vision Pro: prefer Developer Strap over USB-C; otherwise pair over a
   trusted, isolated local Wi-Fi network (AIVU transport may be unencrypted — see §6).
5. Review stereoscopic playback on device: depth comfort, window violations, horizon
   stability, edge sharpness, loudness/intelligibility of narration.
6. Record presentation notes in AIVU (no personal data).
7. Log results in `Docs/AIVU_QA_REPORT.md`.

Every step above is GUI/device work: **requires operator verification** — the automated
build cannot and does not claim to have performed it. The per-item checklist is
`Docs/AIVU_OPERATOR_CHECKLIST.md`.

## 4. Streaming validation (when available)
When an approved remote HLS stream of an `.aivu` master exists, validate segment
integrity and startup latency through AIVU's playlist review on device. Not applicable
until a master exists.

## 5. Runtime playback and fallback (what the app actually does)
The app remains fully usable with zero AIVU media present:
- `Features/ImmersiveTheatre` (Phase 5+) plays available media via AVKit/AVFoundation
  (standard spatial/stereoscopic media where supported).
- Every video, when produced, must ship with captions and an audio-description track
  (none exist yet — no video media has been produced; speech captions for generated
  audio are already in Resources/Captions).
- Each of the three candidates has an interactive RealityKit recreation that teaches
  the same objective (Chain rings volume, DRSABC room observation beat, AED clear-check
  sequence) — these are the primary teaching surfaces regardless.
- Missing-media path: the player view falls back to the RealityKit recreation with a
  notice; no crash, no dead lesson (covered by the missing-resource tests).

## 6. Security (binding, from the assignment)
- Trusted and isolated local network only; prefer Developer Strap + USB-C.
- Never transmit learner records or authentication tokens through the AIVU session.
- No personal data in filenames, playlists, or notes.
- AIVU machines hold production media only.

## 7. Evidence discipline
Claims about device playback appear ONLY in `Docs/AIVU_QA_REPORT.md` rows whose
`Verified by` column names a human operator and date. Rows without an operator are
`PENDING — requires operator verification`. The build pipeline never auto-fills them.
