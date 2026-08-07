# Reality Composer Pro Live Preview Checklist

Operator status: **not performed headlessly**. No Reality Composer Pro GUI action,
physical-device action, or Live Preview result is claimed complete by Phase 4. Every
unchecked item below remains **requires operator verification**. A green command-line
build or simulator test is necessary evidence, but it is not Live Preview evidence.

Use the Xcode 26.6-bundled Reality Composer Pro recorded in
`Docs/BUILD_ENVIRONMENT.md`. Record the operator, date/time, Apple Vision Pro model and
visionOS build, scene, result, and evidence location for each run.

## Device and toolchain preflight

- [ ] Confirm the Mac is using the recorded Xcode 26.6 (17F113) installation and its bundled Reality Composer Pro — requires operator verification.
- [ ] Confirm the physical Apple Vision Pro is supported by the installed Xcode/visionOS toolchain — requires operator verification.
- [ ] Connect or pair the intended Apple Vision Pro with Xcode, unlock it, and satisfy all device trust and Developer Mode prompts — requires operator verification.
- [ ] Confirm Xcode shows the intended physical device as an available run destination without pairing or preparation errors — requires operator verification.
- [ ] Confirm the device has a safe, unobstructed review area and that the operator can immediately stop the experience — requires operator verification.

## Open the project-local RCP catalogue

- [ ] Generate the Xcode project with the documented command, then open `LifesaverVision.xcodeproj` in Xcode 26.6 — requires operator verification.
- [ ] Expand the local `RealityKitContent` package in Xcode and locate `Sources/RealityKitContent/RealityKitContent.rkassets` — requires operator verification.
- [ ] Open that project-local `.rkassets` catalogue in the Xcode 26.6-bundled Reality Composer Pro — requires operator verification.
- [ ] Confirm the open catalogue path is inside `LifesaverVision`, not inside the read-only external asset-library root — requires operator verification.
- [ ] Confirm `Assets/ShowcaseOnly/` contains the four hardware props and that no clinical scene references them — requires operator verification.

## Start and stop Live Preview

- [ ] In Reality Composer Pro, choose the intended Apple Vision Pro as the Live Preview destination — requires operator verification.
- [ ] Start Live Preview from Reality Composer Pro and confirm the device receives and opens the preview without transfer, signing, or connection errors — requires operator verification.
- [ ] Confirm the operator can stop Live Preview immediately from RCP and can leave the immersive content safely on device — requires operator verification.
- [ ] After each scene review, stop Live Preview before selecting or editing the next scene — requires operator verification.

## Scene-by-scene load review

- [ ] Load and inspect `AcademyLobby`; verify the observatory setting, portals m01-m11, companion orb, and control panel appear without missing references — requires operator verification.
- [ ] Load and inspect `HeartAndLungsVolume`; verify the heart and lungs are correctly scaled, oriented, separated, and comfortably inspectable — requires operator verification.
- [ ] Load and inspect `ChainOfSurvivalVolume`; verify all seven named ring placeholders are visible and ordered as designed — requires operator verification.
- [ ] Load and inspect `DRSABCTrainingRoom`; verify the bystander, manikin, and hazard props are non-graphic, legible, and spatially separated — requires operator verification.
- [ ] Load and inspect `CPRPracticeRoom`; verify the manikin, clear floor area, and control panel appear at practical training scale — requires operator verification.
- [ ] Load and inspect `AEDPreparationRoom`; verify the manikin, AED trainer, electrode packet, cloth, scissors, training razor, and glove box are present and reachable — requires operator verification.
- [ ] Load and inspect `AEDPlacementRoom`; verify the right-pad zone is below the right collarbone and the left-pad zone is on the left side below the armpit-nipple line — requires operator verification.
- [ ] Load and inspect `Scenario_Home`; verify the environment, manikin, AED, bystander, and clear zone load without overlap or missing references — requires operator verification.
- [ ] Load and inspect `Scenario_ShoppingCentre`; verify the environment, manikin, AED, bystander, and clear zone load without overlap or missing references — requires operator verification.
- [ ] Load and inspect `Scenario_Workplace`; verify the environment, manikin, AED, bystander, and clear zone load without overlap or missing references — requires operator verification.
- [ ] Load and inspect `Scenario_CommunityFacility`; verify the environment, manikin, AED, bystander, and clear zone load without overlap or missing references — requires operator verification.
- [ ] Load and inspect `AchievementGallery`; verify the vault environment, badges m01-m14, pedestal, XP orb, and constellation stars load correctly — requires operator verification.
- [ ] Load and inspect `DebriefSpace`; verify the theatre environment loads at a calm, comfortable presentation scale — requires operator verification.

## Visual, semantic, and safety review

- [ ] Inspect every scene for missing-reference placeholders, unintended substitutions, broken materials, texture errors, clipping, z-fighting, and extreme scale — requires operator verification.
- [ ] Confirm the presentation is calm, medically serious, respectful, stylised, and non-graphic, with no arcade treatment — requires operator verification.
- [ ] Confirm no Red Cross emblem, SRFAC logo, copied manual illustration, or other protected branding appears — requires operator verification.
- [ ] Confirm the four Vision Pro hardware props appear only in an explicitly designated credits or asset-showcase context, never in clinical scenes — requires operator verification.
- [ ] Inspect the hierarchy for required semantic names, including manikin landmarks, AED controls and pads, heart chambers, lung lobes, chain rings, bystanders, and `clear_zone` — requires operator verification.
- [ ] Confirm the sternum target covers the intended lower-half-of-sternum training area and that the xiphoid avoid zone is distinct and not presented as a target — requires operator verification.
- [ ] Confirm authored models use plausible metre-scale proportions and all intended interactive targets have comfortable hit areas of approximately 4 cm or greater — requires operator verification.
- [ ] Confirm scene content does not claim to measure physical compression depth or force and does not display fabricated sensor values — requires operator verification.
- [ ] Confirm any 995-call representation is conspicuously labelled `SIMULATION` and cannot initiate a call — requires operator verification.
- [ ] Confirm no scene describes an internal completion record as SRFAC certification — requires operator verification.
- [ ] Escalate any medical placement, wording, or sequence that is not traceable to approved content as `requires SME review` before approval — requires operator verification.

## In-app device integration review

- [ ] Build and run the Lifesaver Vision app on the paired physical device using the intended Phase 4 code and content revision — requires operator verification.
- [ ] Open Learning Lab and confirm `HeartAndLungsVolume` renders as RealityKit content rather than placeholder text — requires operator verification.
- [ ] Enter the simulation with no alternate choice and confirm the default scene is `CPRPracticeRoom` — requires operator verification.
- [ ] Select each available simulation scene through the app and confirm the requested scene, not a stale prior scene, is loaded — requires operator verification.
- [ ] Confirm missing-content handling presents a graceful, readable error state and does not crash the app — requires operator verification.
- [ ] Confirm `Exit` and `Pause` controls remain visible, legible, reachable, and functional throughout the immersive simulation — requires operator verification.
- [ ] Confirm semantic targets show the intended hover response and are selectable without using visual-mesh collision — requires operator verification.
- [ ] Confirm VoiceOver/accessibility focus exposes a localised name and description for each decorated semantic target — requires operator verification.
- [ ] Confirm exiting, pausing, resuming, and re-entering do not duplicate entities or leave a stale immersive scene — requires operator verification.

## Evidence and sign-off

- [ ] Capture a screenshot or screen recording for each reviewed scene without exposing personal or sensitive information — requires operator verification.
- [ ] Save RCP, Xcode, device, and app logs for every failed load, broken reference, crash, or interaction fault — requires operator verification.
- [ ] Record each finding with scene name, semantic entity when applicable, reproduction steps, expected result, actual result, and evidence path — requires operator verification.
- [ ] Re-run affected scenes after fixes and attach new evidence rather than overwriting the original failure evidence — requires operator verification.
- [ ] Have the designated operator sign and date the completed checklist, with unresolved medical issues routed to an SME and technical issues routed to engineering — requires operator verification.

Completion of this checklist is device/GUI evidence only. It supplements, and does not
replace, asset SHA-256 validation, Xcode compilation, simulator tests, semantic-contract
tests, clinical approval, accessibility review, or instructor competency sign-off.
