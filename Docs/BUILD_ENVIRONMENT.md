# Build Environment

Recorded 2026-08-07 during Phase 1 (environment and source audit). All versions were
probed on the build machine, not assumed.

## Machine and OS
| Item | Value |
|---|---|
| Platform | Apple Silicon Mac (darwin arm64) |
| macOS | 26.5.2 (build 25F84) |

## Apple toolchain
| Tool | Version / detail |
|---|---|
| Xcode | 26.6 (build 17F113), `/Applications/Xcode.app` |
| visionOS SDK | 26.5 (`xros26.5`), simulator SDK `xrsimulator26.5` |
| Reality Composer Pro | Bundled with Xcode 26.6 (`Xcode.app/Contents/Applications/Reality Composer Pro.app`) — this installation's current RCP; used for the `.rkassets` authoring workflow in `Docs/REALITY_COMPOSER_PRO_WORKFLOW.md` |
| Apple Immersive Video Utility | Installed at `/Applications/Apple Immersive Video Utility.app` (production/review workflow only — see `Docs/AIVU_WORKFLOW.md`) |
| visionOS simulators | Apple Vision Pro — visionOS 26.5 (`72F30C88-7E77-4710-BC36-4934D3F0809E`, primary CI target) and visionOS 27.0 (`76642835-8A23-460F-8A18-567672004162`) |

## Supporting tools
| Tool | Version |
|---|---|
| XcodeGen | 2.46.0 (`/opt/homebrew/bin/xcodegen`) — generates `LifesaverVision.xcodeproj` from `project.yml` |
| Python | `/usr/bin/python3` (asset inventory, manifest and validation scripts) |
| Git | System git; repository initialised at project root |

## Build commands (canonical)
```bash
cd "<project root>"
xcodegen generate
xcodebuild -project LifesaverVision.xcodeproj -scheme LifesaverVision \
  -destination 'platform=visionOS Simulator,id=72F30C88-7E77-4710-BC36-4934D3F0809E' \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/LifesaverVision build   # or `test`
```
DerivedData is deliberately kept on the local disk (`~/Library/Developer/...`) because the
project root lives on Google Drive File Provider storage; building into cloud-synced
storage is slow and can corrupt incremental state.

## Source inputs resolved in Phase 1
| Input | Resolution |
|---|---|
| ASSET_ROOT | `…/My Drive/macbook/Apple Vision Pro user guide` — resolved, read-only; contains `SpatialMastery/` with 50 Tripo3D-generated assets (see `ASSET_PROVENANCE.md`) |
| 2018 course manual | `Docs/sources/SRFAC-CPRHOAED-Manual-2018-2.pdf` (2,735,924 bytes, downloaded from redcross.sg) |
| Current provider manual | `Docs/sources/CA-Manual-REV-1-2022.pdf` (3,577,026 bytes, downloaded from srfac.sg) |
| Current guidelines | `Docs/sources/03-SG-BCLSAED-Guidelines-2021.pdf` (3,461,436 bytes, downloaded from srfac.sg) |

## Known environment constraints
- Tripo3D is prohibited for any new generation (see AGENTS.md hard constraints); only
  pre-existing on-disk assets are reused.
- `Reality Composer Pro 3 Beta` as named in the assignment: the installed RCP is the
  version bundled with Xcode 26.6 on this machine. All RCP work uses this installation;
  the exact app version is recorded in `Docs/REALITY_COMPOSER_PRO_WORKFLOW.md`.
- GUI-only steps (RCP Live Preview on device, AIVU device review) cannot be executed
  headlessly; they are documented as operator checklists and marked
  "requires operator verification" rather than claimed as done.
