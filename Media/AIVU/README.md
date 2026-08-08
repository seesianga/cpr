# Apple Immersive Video (AIVU) Media Directory

This directory holds Apple Immersive Video production media for Lifesaver Vision.
AIVU (Apple Immersive Video Utility, installed at `/Applications/Apple Immersive
Video Utility.app`) is a **production and review tool**, not an in-app framework —
there is no AIVU runtime SDK and this project does not pretend otherwise. In-app
playback of any final immersive media uses AVKit/AVFoundation with runtime fallbacks
(see `Docs/AIVU_WORKFLOW.md` §5).

## Planned contents
| Subfolder | Purpose |
|---|---|
| `Masters/` | Final `.aivu` packages (MV-HEVC 4320×4320 @ 90 fps, AIME metadata, ASAF audio) — none exist yet |
| `TestMedia/` | Lower-quality development/workflow-test media — **clearly labelled test media, never represented as AIVU masters** |
| `Playlists/` | AIVU playlist definitions used for device review sessions |
| `Notes/` | Presentation/review notes exported from AIVU (no personal data — see security rules) |

## The three planned immersive-media candidates
1. **Chain of Survival Opening** — calm, non-graphic spatial introduction (20–40 s)
2. **Recognise and Respond** — environmental observation of a simulated collapse; learner identifies danger and responsiveness (30–60 s)
3. **AED Clear Sequence** — analysis, clearing the casualty, resuming CPR (30–60 s)

These support learning; they never replace interactive RealityKit practice.

## Current status (honest)
No compliant Apple Immersive Video camera or 4320×4320@90 fps stereoscopic rendering
pipeline is available in this build environment. Therefore:
- No `.aivu` master has been produced, and none is claimed.
- The app ships with RealityKit interactive recreations + captioned 2D/spatial
  fallbacks for all three candidates (see `Docs/AIVU_WORKFLOW.md` §5).
- The full capture→package→review workflow is specified and operator-checklisted in
  `Docs/AIVU_OPERATOR_CHECKLIST.md`; every GUI/device step is marked
  **requires operator verification**.

## Security rules for this directory (binding)
- Trusted, isolated local network only for AIVU device sessions; prefer Developer
  Strap / USB-C.
- Never place learner records, authentication tokens, or personal data in AIVU
  media, filenames, playlists, or notes.
- AIVU is a production-review environment, not a learner-data environment.
