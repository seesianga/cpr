# AIVU QA Report — Lifesaver Vision

Live register of Apple Immersive Video media QA. A row is only marked PASS when a named
human operator performed the device review; the automated build never fills these fields.

## Tool versions (recorded at report creation, 2026-08-08)
| Tool | Version |
|---|---|
| Apple Immersive Video Utility | Installed at `/Applications/Apple Immersive Video Utility.app` — exact version string: PENDING — requires operator verification (About window) |
| macOS | 26.5.2 (25F84) |
| Xcode | 26.6 (17F113) |
| visionOS (review device) | PENDING — requires operator verification |
| Device connection method | Planned: Developer Strap / USB-C preferred; isolated Wi-Fi otherwise |

## Media register
| Item | File | Codec | Resolution | FPS | Colour | AIME | Audio | Presentation track | Playback result | Problems | Approval |
|---|---|---|---|---|---|---|---|---|---|---|---|
| Chain of Survival Opening | — not produced — | — | — | — | — | — | — | — | — | — | NOT STARTED — no compliant capture pipeline in build environment |
| Recognise and Respond | — not produced — | — | — | — | — | — | — | — | — | — | NOT STARTED — no compliant capture pipeline in build environment |
| AED Clear Sequence | — not produced — | — | — | — | — | — | — | — | — | — | NOT STARTED — no compliant capture pipeline in build environment |

## Runtime fallback QA (what ships today)
| Check | Status |
|---|---|
| App fully usable with zero AIVU media | Covered by missing-resource tests (see TEST_REPORT) |
| RealityKit recreations for all three candidates | Chain rings volume + DRSABC observation + AED clear-check (Phases 4–5) |
| Captions for speech audio | 86 VTT files authored with the audio pipeline (Phase 6) |
| Audio-description tracks for video media | NOT authored — no video media exists yet; to be produced alongside the immersive media itself |

## Honest summary
No Apple Immersive Video master exists and none is claimed. The workflow, requirements,
and operator checklist are complete and executable the day a compliant camera or
4320×4320@90 stereoscopic render pipeline becomes available. All in-app learning
functions without this media.

## Final approval status
**NOT APPLICABLE for v1 ship — no masters produced. Fallback experience approved via
automated tests; device-review rows remain PENDING — requires operator verification.**
