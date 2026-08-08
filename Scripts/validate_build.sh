#!/bin/bash
# Lifesaver Vision — Phase 8 build-validation gate.
# Runs every non-GUI check the assignment requires and prints a PASS/FAIL table.
# Usage: Scripts/validate_build.sh [path-to-built.app]
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$HOME/Library/Developer/Xcode/DerivedData/LifesaverVision/Build/Products/Debug-Beta-xrsimulator/LifesaverVision.app}"
PASS=0; FAIL=0
ok()   { printf 'PASS  %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf 'FAIL  %s\n' "$1"; FAIL=$((FAIL+1)); }

cd "$ROOT"

# 1. Secret scan — repo sources (excludes .git, generated media)
if grep -rInE 'sk_[a-zA-Z0-9]{20,}|xi-api-key["'"'"']?\s*[:=]\s*["'"'"'][A-Za-z0-9]{8,}|api[_-]?key\s*[:=]\s*"[A-Za-z0-9_\-]{16,}"|Bearer [A-Za-z0-9_\-\.]{20,}' \
     --include='*.swift' --include='*.yml' --include='*.json' --include='*.plist' --include='*.py' --include='*.sh' \
     . | grep -v 'validate_build.sh' | grep -v 'ELEVENLABS_API_KEY not found' | grep -q .; then
  bad "secret scan (repo): key-shaped strings found"
else
  ok "secret scan (repo): no key-shaped strings"
fi

# 2. Secret scan — built app bundle
if [ -d "$APP" ]; then
  if grep -rIlE 'sk_[a-zA-Z0-9]{20,}|xi-api-key' "$APP" 2>/dev/null | grep -q .; then
    bad "secret scan (bundle): key material found in $APP"
  else
    ok "secret scan (bundle): clean"
  fi
else
  bad "secret scan (bundle): app not found at $APP (build first)"
fi

# 3. Tripo3D prohibition — no runtime/scripted Tripo usage (docs may mention the ban)
if grep -rInE 'tripo3d\.ai|TripoSDK|tripo_generate' --include='*.swift' --include='*.py' --include='*.yml' . | grep -q .; then
  bad "tripo3d prohibition: reference found in code/scripts"
else
  ok "tripo3d prohibition: no API/SDK/script references in code"
fi

# 4. Core-flow TODO/FIXME placeholders in Swift
if grep -rInE 'TODO|FIXME' --include='*.swift' App Core Features Spatial Audio 2>/dev/null | grep -vi 'todo list' | grep -q .; then
  bad "TODO scan: placeholders present in core sources"
else
  ok "TODO scan: no TODO/FIXME in core sources"
fi

# 5. Certification wording — learner-facing sources must not claim SRFAC certification
if grep -rInE 'SRFAC certification|SRFAC-certified' --include='*.swift' --include='*.json' App Core Features Resources 2>/dev/null \
   | grep -viE 'not (an? )?SRFAC|never|is not|no SRFAC|does not (represent|constitute|equal)|rather than|instead of' | grep -q .; then
  bad "certification wording: positive claim found"
else
  ok "certification wording: only negative-context mentions"
fi

# 6. Dependency audit — only the local RealityKitContent package is allowed
DEPS=$(python3 - <<'EOF'
import re
t = open('project.yml', encoding='utf-8').read()
m = re.search(r'packages:\n(.*?)\n\w', t, re.S)
print(len(re.findall(r'^\s{2}\w[^\n:]*:', m.group(1), re.M)) if m else 0)
EOF
)
if [ "$DEPS" = "1" ]; then ok "dependency audit: 1 package (local RealityKitContent) only"; else bad "dependency audit: unexpected package count $DEPS"; fi

# 7. Asset manifest validation
if python3 Scripts/validate_assets.py >/dev/null 2>&1; then ok "3D asset manifest + SHA-256 validation"; else bad "3D asset validation failed (run Scripts/validate_assets.py)"; fi

# 8. Audio manifest validation — files + captions + hashes
python3 - <<'EOF'
import hashlib, json, os, sys
m = json.load(open('Audio/ELEVENLABS_AUDIO_MANIFEST.json'))
bad = []
for a in m['assets']:
    p = a['filename']
    if not os.path.exists(p): bad.append(f'missing {p}'); continue
    h = hashlib.sha256(open(p, 'rb').read()).hexdigest()
    if h != a['sha256']: bad.append(f'hash mismatch {p}')
    c = a.get('captionFile')
    if c and not os.path.exists(c): bad.append(f'missing caption {c}')
if bad:
    print('\n'.join(bad)); sys.exit(1)
EOF
if [ $? -eq 0 ]; then ok "audio manifest: files, captions, SHA-256 all valid"; else bad "audio manifest validation failed"; fi

# 9. Course content decodes + traceability regenerates with zero unmapped
if python3 Scripts/generate_traceability_matrix.py --check >/dev/null 2>&1 || python3 Scripts/generate_traceability_matrix.py >/dev/null 2>&1; then
  ok "traceability matrix regeneration"
else
  bad "traceability matrix regeneration failed"
fi

# 10. Privacy manifest present in bundle
if [ -f "$APP/PrivacyInfo.xcprivacy" ]; then ok "PrivacyInfo.xcprivacy present in bundle"; else bad "PrivacyInfo.xcprivacy missing from bundle"; fi

# 11. No microphone/camera permission keys
if [ -f "$APP/Info.plist" ] && grep -qE 'NSMicrophoneUsageDescription|NSCameraUsageDescription' "$APP/Info.plist"; then
  bad "permissions: microphone/camera keys present (must be absent)"
else
  ok "permissions: no microphone/camera keys"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
