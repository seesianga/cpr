# Asset Reuse Report

Decision record for every reusable 3D asset found under ASSET_ROOT. Source files are
never modified; the approved delivery assets are copied into the app bundle.

Phase 4 packaging choice: all delivery USDZ files live in
`Packages/RealityKitContent/Sources/RealityKitContent/RealityKitContent.rkassets/Assets/`.
That resource catalogue is already processed by the `RealityKitContent` Swift package,
keeps referenced USDZs beside the RCP scenes, and avoids a second app-target resource
copy path. The 46 general-use assets are at the `Assets/` root. The four hardware props
are isolated under `Assets/ShowcaseOnly/` so clinical scenes cannot reference them by
accident. `Scripts/validate_assets.py` verifies this exact mapping against the recorded
SHA-256 and byte count for every delivery asset.

Status values: `copied` = packaged at the `Assets/` root; `showcase-only` = packaged in
the restricted subgroup and excluded from clinical lessons; `excluded` = not packaged.
Current counts are 46 copied, 4 showcase-only, and 0 excluded.

- Assets inventoried: 50 logical assets (221 files hashed incl. all tiers)
- Tiers per asset: Source GLB (master, not shipped) -> Optimized GLB -> USDZ -> USDZ_Delivery (shipped)
- Cross-tier duplicate hash groups: 51 (expected: many Optimized GLBs are byte-identical to Source because the original pipeline recorded "provider optimization unavailable" fallbacks; delivery USDZ files are distinct)
- Excluded from clinical lessons: the 4 Vision-Pro-hardware props (headset-mockup, headband, light-seal-cushion, battery-prop) — clinically irrelevant; restricted to a credits/asset showcase context. All 50 delivery files pass the recorded integrity checks; reuse approval and provenance come from the prior-project handoff.
- No manikin / AED / heart / lungs / casualty models exist in the library. Clinical training models are therefore ORIGINAL hand-authored USDA / procedural RealityKit geometry (Tripo3D prohibited). This is deliberate: forcing non-clinical assets into lessons would be misleading.

| Asset | Reuse class | Status | Planned use in Lifesaver Vision |
|---|---|---|---|
| accessibility-audio-beacon | interactive | copied | Accessibility setup: spatial audio check (Module 0) |
| accessibility-switch-puck | interactive | copied | Accessibility setup: alternate input demo (Module 0) |
| accessibility-text-block | interactive | copied | Accessibility setup: caption/Dynamic Type demo (Module 0) |
| achievement-vault-environment | environment | copied | AchievementGallery environment |
| badge_m01 | badge | copied | AchievementGallery badge visual (mapped to badge set; spares reserved) |
| badge_m02 | badge | copied | AchievementGallery badge visual (mapped to badge set; spares reserved) |
| badge_m03 | badge | copied | AchievementGallery badge visual (mapped to badge set; spares reserved) |
| badge_m04 | badge | copied | AchievementGallery badge visual (mapped to badge set; spares reserved) |
| badge_m05 | badge | copied | AchievementGallery badge visual (mapped to badge set; spares reserved) |
| badge_m06 | badge | copied | AchievementGallery badge visual (mapped to badge set; spares reserved) |
| badge_m07 | badge | copied | AchievementGallery badge visual (mapped to badge set; spares reserved) |
| badge_m08 | badge | copied | AchievementGallery badge visual (mapped to badge set; spares reserved) |
| badge_m09 | badge | copied | AchievementGallery badge visual (mapped to badge set; spares reserved) |
| badge_m10 | badge | copied | AchievementGallery badge visual (mapped to badge set; spares reserved) |
| badge_m11 | badge | copied | AchievementGallery badge visual (mapped to badge set; spares reserved) |
| badge_m12 | badge | copied | AchievementGallery badge visual (mapped to badge set; spares reserved) |
| badge_m13 | badge | copied | AchievementGallery badge visual (mapped to badge set; spares reserved) |
| badge_m14 | badge | copied | AchievementGallery badge visual (mapped to badge set; spares reserved) |
| battery-prop | showcase-only | showcase-only | Credits/asset showcase ONLY - not clinically relevant |
| capstone-environment | environment | copied | Integrated scenario staging environment (Scenario rooms) |
| certificate-pedestal | prop | copied | Instructor sign-off / completion record pedestal in AchievementGallery |
| companion-orb-bot | guide | copied | Academy guide avatar; spatial-audio anchor for narrator |
| constellation-star | gamification | copied | Mastery-map star markers |
| control-panel | prop | copied | Simulation control console in practice rooms |
| gesture-practice-cube | interactive | copied | Module 0 interaction calibration |
| gesture-practice-orb | interactive | copied | Module 0 interaction calibration |
| gesture-practice-ring | interactive | copied | Module 0 interaction calibration |
| headband | showcase-only | showcase-only | Credits/asset showcase ONLY - not clinically relevant |
| headset-mockup | showcase-only | showcase-only | Credits/asset showcase ONLY - not clinically relevant |
| light-seal-cushion | showcase-only | showcase-only | Credits/asset showcase ONLY - not clinically relevant |
| observatory-environment | environment | copied | AcademyLobby base environment dressing |
| portal_m01 | portal | copied | AcademyLobby module portal (mapped to Module 0 of 0-10; m12-m14 reserved/decorative) |
| portal_m02 | portal | copied | AcademyLobby module portal (mapped to Module 1 of 0-10; m12-m14 reserved/decorative) |
| portal_m03 | portal | copied | AcademyLobby module portal (mapped to Module 2 of 0-10; m12-m14 reserved/decorative) |
| portal_m04 | portal | copied | AcademyLobby module portal (mapped to Module 3 of 0-10; m12-m14 reserved/decorative) |
| portal_m05 | portal | copied | AcademyLobby module portal (mapped to Module 4 of 0-10; m12-m14 reserved/decorative) |
| portal_m06 | portal | copied | AcademyLobby module portal (mapped to Module 5 of 0-10; m12-m14 reserved/decorative) |
| portal_m07 | portal | copied | AcademyLobby module portal (mapped to Module 6 of 0-10; m12-m14 reserved/decorative) |
| portal_m08 | portal | copied | AcademyLobby module portal (mapped to Module 7 of 0-10; m12-m14 reserved/decorative) |
| portal_m09 | portal | copied | AcademyLobby module portal (mapped to Module 8 of 0-10; m12-m14 reserved/decorative) |
| portal_m10 | portal | copied | AcademyLobby module portal (mapped to Module 9 of 0-10; m12-m14 reserved/decorative) |
| portal_m11 | portal | copied | AcademyLobby module portal (mapped to Module 10 of 0-10; m12-m14 reserved/decorative) |
| portal_m12 | portal | copied | AcademyLobby decorative portal (reserved) |
| portal_m13 | portal | copied | AcademyLobby decorative portal (reserved) |
| portal_m14 | portal | copied | AcademyLobby decorative portal (reserved) |
| practice-window-frame | prop | copied | Framing element for volumetric learning lab |
| privacy-shield | prop | copied | Casualty-dignity screen prop + privacy lesson visual (Module 0) |
| safety-props-set | prop | copied | DRSABC danger-assessment scene hazards (Module 3) |
| theatre-environment | environment | copied | DebriefSpace / immersive theory theatre |
| xp-orb | gamification | copied | XP award visual in scoring/debrief |

## Duplicate-hash detail (first 10 groups)
- `138c7e3ffb5794dc…`: `SpatialMastery/Media/3D/Source/portal_m03/model_1.glb` == `SpatialMastery/Media/3D/Optimized/portal_m03/portal_m03.glb`
- `13cd22e90a7ebfb5…`: `SpatialMastery/Media/3D/Source/control-panel/model_1.glb` == `SpatialMastery/Media/3D/Optimized/control-panel/control-panel.glb`
- `14729f80d8876958…`: `SpatialMastery/Media/3D/Source/portal_m02/model_1.glb` == `SpatialMastery/Media/3D/Optimized/portal_m02/portal_m02.glb`
- `241ade6907591d5f…`: `SpatialMastery/Media/3D/Source/portal_m08/model_1.glb` == `SpatialMastery/Media/3D/Optimized/portal_m08/portal_m08.glb`
- `272fa51a21cc6f18…`: `SpatialMastery/Media/3D/Source/portal_m05/model_1.glb` == `SpatialMastery/Media/3D/Optimized/portal_m05/portal_m05.glb`
- `2d795b0566a093ff…`: `SpatialMastery/Media/3D/Source/privacy-shield/model_1.glb` == `SpatialMastery/Media/3D/Optimized/privacy-shield/privacy-shield.glb`
- `366ff91d8d3278c3…`: `SpatialMastery/Media/3D/Source/accessibility-switch-puck/model_1.glb` == `SpatialMastery/Media/3D/Optimized/accessibility-switch-puck/accessibility-switch-puck.glb`
- `3b49cac76ae4ec02…`: `SpatialMastery/Media/3D/Source/badge_m04/model_1.glb` == `SpatialMastery/Media/3D/Optimized/badge_m04/badge_m04.glb`
- `49205da157ffd78f…`: `SpatialMastery/Media/3D/Source/portal_m13/model_1.glb` == `SpatialMastery/Media/3D/Optimized/portal_m13/portal_m13.glb`
- `4da5f3318271ac32…`: `SpatialMastery/Media/3D/Source/portal_m01/model_1.glb` == `SpatialMastery/Media/3D/Optimized/portal_m01/portal_m01.glb`

Unmapped assets: none — all 50 assets have a mapped use or an explicit exclusion.
