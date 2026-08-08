# AIVU Media Requirements — Lifesaver Vision

Requirements for any media item admitted to `Media/AIVU/Masters/`. Items failing any
MUST row are rejected or reclassified as `TestMedia/`.

## Technical requirements (MUST)
| # | Requirement | Verification method |
|---|---|---|
| T1 | MV-HEVC stereoscopic encoding | AIVU inspector / `avmediainfo` |
| T2 | 4320 × 4320 per-eye delivery resolution | AIVU inspector |
| T3 | 90 fps delivery frame rate | AIVU inspector |
| T4 | HDR P3-D65 PQ colour | AIVU inspector |
| T5 | Valid AIME metadata originating from a compliant camera/render pipeline — fabricated or transplanted AIME is prohibited | Pipeline provenance record + AIVU validation |
| T6 | Audio: MP4 ASAF; 5th-order ambisonics and/or object-based as designed | AIVU inspector + listening check |
| T7 | Presentation track present where camera changes/transitions exist | AIVU inspector |
| T8 | Packaged as `.aivu` | File inspection |

## Content requirements (MUST)
| # | Requirement |
|---|---|
| C1 | Calm, non-graphic, non-sensational; no distressing casualty realism |
| C2 | Script text derives from approved course content blocks only (traceability id recorded) |
| C3 | Medically consistent with current SRFAC guidance (facts extract ids recorded) |
| C4 | No protected branding (Red Cross emblem, SRFAC logo, commercial AED trade dress) |
| C5 | Captions file + audio-description script exist in `Resources/Captions/` |
| C6 | Duration within its plan window (Opening 20–40 s; others 30–60 s) |
| C7 | No real emergency audio; any 995 dialogue is scripted and marked simulation |

## Comfort requirements (MUST, device review)
| # | Requirement |
|---|---|
| F1 | No forced camera movement; stable horizon |
| F2 | Essential content within comfortable field of view |
| F3 | No rapid peripheral motion, spinning, or sudden depth changes |
| F4 | Fades rather than hard camera transitions |
| F5 | Loudness: narration ≈ −16 LUFS integrated, true peak ≤ −1 dBTP; non-startling |

## Labelling rules
- `Masters/` — meets ALL rows above, device-reviewed with named operator in the QA report.
- `TestMedia/` — any development media; filename must carry the `TEST_` prefix; never
  represented as Apple Immersive Video masters in any report or marketing text.

## Current inventory status
No items in `Masters/` (no compliant capture/render pipeline in this environment).
See `Docs/AIVU_QA_REPORT.md` for the live register.
