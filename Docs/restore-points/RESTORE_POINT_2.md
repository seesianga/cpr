# Restore point 2 — tag `v-restore-2`

Created 2026-08-10, on branch `signing/device-install-personal-team`, after the pad
colour/size/seating work. **This tag is self-contained: every operator setting is baked
into source as a default, so checking out and installing reproduces the demo
configuration with no in-headset tuning.** Verified against the device's own placement
store on the same day (snapshot below).

## What this state is

- **342 unit tests green.** Build and install verified on KM's Apple Vision Pro.
- **Human overlay**: operator-tuned registration as shipped default — offset
  (0.00, 0.19, 0.80) m, roll 180°, yaw 180°, scale 0.43×, hide placeholder ON, crop
  OFF. First-attach solving off; "Align to manikin" is explicit.
- **AED unit**: the combined RCP export (`3Dassets_01.reality`) as `AED.reality`,
  loaded via authored-subtree selection. Pinned placement — offset
  (−0.247, 0.047, −0.072) m, rotations 0°, scale 1.047× (≈43 cm case). Storage key v5.
- **AED table declutter**: visible kit is the yellow unit and the two pads, nothing
  else; hidden props are inert (no tap, no pinch) with labelled panel controls
  carrying their steps.
- **Pads**: casualty's-left BLUE, right ORANGE, 0.085 × 0.135 m (guide-section
  footprint). A pad released in its own section seats on the section centre; a
  wrong-section release rests where it landed and records the error.
- **Signing**: personal team AAG5WTMX8G, Sign in with Apple gated out
  (`PERSONAL_TEAM`), guest mode is the entry path. Profiles expire 7 days after
  each build.

## How to restore

```
git checkout v-restore-2
xcodegen generate
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
xcodebuild build -project LifesaverVision.xcodeproj -scheme LifesaverVision \
  -configuration Debug-Beta -destination 'generic/platform=visionOS' \
  -derivedDataPath <scratch>/dd -allowProvisioningUpdates
xcrun devicectl device install app --device C4ED905C-BE31-522A-9C90-D1140567B80D \
  <scratch>/dd/Build/Products/Debug-Beta-xros/LifesaverVision.app
```

Then open the app from the Home View while wearing the headset (remote launch stalls
without a wearer). No further configuration: the defaults ARE the configuration. If
the device has since stored different in-headset tuning, tap **Reset Human** /
**Reset AED** in the developer panel to return to this restore point's values.

## Device placement store at creation time

Pulled from the headset (`devicectl device copy from … Library/Preferences/`) when
this point was created. Active keys — everything the app actually reads:

```json
"developer.visualModelPlacement.v5.AED": {
  "offsetMetres": [-0.247, 0.047, -0.072],
  "rollDegrees": 0, "pitchDegrees": 0, "yawDegrees": 0,
  "scale": 1.0469648,
  "hidesPlaceholder": true, "cropsToPhysicalEnvelope": true
}
```

`developer.visualModelPlacement.v3.Human`: absent — the human runs on the baked
default, which equals the operator's tuned registration. Retired keys (unversioned,
v2, v3.AED, v4.AED) still exist on the device but are ignored by this build.

## Earlier restore points

- `v-restore-tuned-defaults` (d27fd89) — tuned human defaults, pre-AED-asset-swap
- `v-fallback-working-baseline` (9836fb4) — pre-registration-rework baseline
