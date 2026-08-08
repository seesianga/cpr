# AIVU Operator Checklist

Per-media-item checklist for the human operator running Apple Immersive Video Utility
review sessions. Every box is a manual step; the build system never checks these boxes.

## Session setup
- [ ] AIVU launched; record exact version from About window into `AIVU_QA_REPORT.md`
- [ ] Review machine is on a trusted, ISOLATED network (or Developer Strap/USB-C in use)
- [ ] Confirm no learner data, tokens, or personal files on the review machine profile
- [ ] Apple Vision Pro paired; visionOS version recorded

## Per media item
- [ ] Import the media file into AIVU
- [ ] Filename contains no personal data; `TEST_` prefix present if not a master
- [ ] Inspector check: MV-HEVC, per-eye resolution, fps, P3-D65 PQ, AIME status,
      ASAF audio, presentation track — record ALL values in the QA report row
- [ ] Provenance: AIME originates from the capture/render pipeline (reject transplants)
- [ ] Add to the module review playlist
- [ ] Device playback: watch END TO END
  - [ ] Depth comfort (no window violations, no eye strain)
  - [ ] Horizon stable; no forced camera movement
  - [ ] Essential content within comfortable FOV
  - [ ] No rapid peripheral motion / spinning / sudden depth changes
  - [ ] Transitions are fades, not cuts that jar
  - [ ] Narration intelligible; loudness comfortable; nothing startling
  - [ ] Content is calm, non-graphic, brand-clean
- [ ] Record presentation notes in AIVU (no personal data)
- [ ] Fill the QA report row: playback result, problems, approval, operator name + date

## Session teardown
- [ ] Export/record notes to `Media/AIVU/Notes/`
- [ ] Remove any temporary media from the device
- [ ] QA report committed

Operator: ______________________  Date: ____________  Signature: ____________
