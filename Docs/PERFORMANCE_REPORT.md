# Performance Report — Lifesaver Vision

**Scope statement (honest):** all measurements below were taken on the visionOS 26.5
**simulator** on an Apple Silicon Mac. Physical Apple Vision Pro profiling (frame
pacing, GPU, thermals, real asset-load latency, audio startup on device) has NOT been
performed and is required before any performance claim about the headset — see the
operator checklist at the end. No hardware performance is claimed.

## Measured (simulator / build machine, 2026-08-08)
| Metric | Value | Evidence |
|---|---|---|
| App bundle size (Debug-Beta, simulator) | 204 MiB (213,556,060 bytes) | Phase 5b final build |
| — of which audio (AAC delivery + captions) | 44.3 MB (44,271,303 B audio + 25,796 B captions) | `Audio/Delivery`, remeasured 2026-08-08 |
| — of which 3D USDZ assets (loose, lazy-loaded) | ~135 MB | `Media/3D/USDZ` |
| Compiled RealityKit archive (.reality) | 2.24 MiB (was 683 MiB before restructure) | PHASE4R_REPORT |
| Full unit-test suite wall time | 62.4 s (215 tests, PHASE5B verbatim log); 95.1 s for the earlier 149-test Phase 5a run | phase report logs |
| Runtime asset audit (13 scenes + 50 USDZs composed) | 63/63 resources load | Phase 4R/5b test evidence |
| Clean build (incremental cold-ish, Google-Drive-hosted sources, local DerivedData) | minutes-scale; acceptable for CI | Phase reports |

## Optimisation measures implemented (per assignment §18)
- **Lazy scene composition** — `.rkassets` holds skeletons only; Tripo USDZs attach at
  named anchors on demand and are **released on scene exit** (AssetRegistry cache with
  eviction). App-size impact measured: 694 → 149 MiB at Phase 4R (grew to 204 MiB only
  by adding the audio tier).
- **Simplified collision meshes** (boxes/capsules), never visual-mesh collision.
- **Instanced repeated assets** (portals, badges) and shared materials.
- **Pre-cached audio** — zero runtime synthesis; AAC delivery tier (47 MB) instead of
  WAV masters (224 MB, kept out of the bundle).
- **No network calls during simulation**; core modules fully offline.
- **Delivery-tier textures** capped at 2048 px (inherited from the optimized asset tier).
- NOT yet implemented (corrected 2026-08-08 after verification audit): a next-lesson
  asset-preloading hook. `AssetRegistry` loads on demand only; preloading is future work.

## Not yet measured (device-only; operator checklist)
| Item | How to measure |
|---|---|
| Frame pacing in each of the 13 scenes | Instruments → RealityKit/Metal System Trace on device |
| CPU/GPU per scenario scene | Instruments Time Profiler / GPU trace |
| Memory high-water incl. composed scenes | Instruments Allocations; verify eviction on exit |
| Asset-load latency on device storage | signposts already in AssetRegistry load path |
| Audio startup latency + spatial localisation | on-head listening + signpost timestamps |
| Immersive-space transition time | signpost around openImmersiveSpace |
| Thermal behaviour over a full lesson | Instruments Thermal State + 15-min session |
| Battery per 30-min session | device battery telemetry |

Acceptance gates for device sign-off: sustained native frame rate without drops in
practice scenes; no thermal throttling within a 15-minute lesson; scene transition
under ~2 s; audio cue onset under ~150 ms from trigger.
