#!/usr/bin/env bash
set -euo pipefail

# Variables expected from codemagic.yaml env
MAIN_BUNDLE_ID="${MAIN_BUNDLE_ID:?}"
SHARE_BUNDLE_ID="${SHARE_BUNDLE_ID:?}"
NOTI_BUNDLE_ID="${NOTI_BUNDLE_ID:?}"
APP_GROUP_ID="${APP_GROUP_ID:?}"

ROOT="$(pwd)"
IOS_DIR="${ROOT}/ios"

echo "==> Ensuring entitlements include App Group ${APP_GROUP_ID}"

# Paths (adjust if your repo uses different folders)
APP_ENT="${IOS_DIR}/Mattermost/Mattermost.entitlements"
SHARE_ENT="${IOS_DIR}/MattermostShare/MattermostShare.entitlements"
NOTI_ENT="${IOS_DIR}/NotificationService/NotificationService.entitlements"

mkdir -p "$(dirname "$APP_ENT")" "$(dirname "$SHARE_ENT")" "$(dirname "$NOTI_ENT")"

ensure_entitlements () {
  local file="$1"
  if [ ! -f "$file" ]; then
    cat > "$file" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
</dict>
</plist>
EOF
  fi
  # Set application-groups array to contain our group id
  /usr/bin/plutil -replace 'com.apple.security.application-groups' -json "[\"${APP_GROUP_ID}\"]" "$file"
}

ensure_entitlements "$APP_ENT"
ensure_entitlements "$SHARE_ENT"
ensure_entitlements "$NOTI_ENT"

echo "==> Done entitlements"

# Try to set bundle identifiers in the pbxproj for three targets.
# We attempt a conservative in-place replacement for known targets.
PBX="${IOS_DIR}/Mattermost.xcodeproj/project.pbxproj"

echo "==> Setting PRODUCT_BUNDLE_IDENTIFIERs in ${PBX}"

set_bid () {
  local target="$1"
  local bid="$2"
  python3 - "$PBX" "$target" "$bid" <<'PY'
import sys, re
path, target, bid = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(path, 'r', encoding='utf-8').read()

# Heuristic: replace PRODUCT_BUNDLE_IDENTIFIER lines that are near a PRODUCT_NAME mentioning the target
pattern = re.compile(r'(PRODUCT_BUNDLE_IDENTIFIER\s*=)\s*[^;]+(;\s*\n\s*PRODUCT_NAME\s*=\s*"?' + re.escape(target) + r'"?\s*;)', re.M)
new_s, n = pattern.subn(r'\1 ' + bid + r'\2', s)
if n == 0:
    # Fallback: within blocks commented with /* TargetName */
    pattern2 = re.compile(r'(/\* ' + re.escape(target) + r' \*/[\s\S]*?PRODUCT_BUNDLE_IDENTIFIER\s*=)\s*[^;]+;', re.M)
    new_s, n = pattern2.subn(r'\1 ' + bid + r';', s)
if n:
    open(path, 'w', encoding='utf-8').write(new_s)
    print(f"Updated {n} occurrence(s) for target {target}")
else:
    print(f"WARNING: Could not locate PRODUCT_BUNDLE_IDENTIFIER for target {target}. Skipped.", file=sys.stderr)
PY
}

set_bid "Mattermost" "${MAIN_BUNDLE_ID}"
set_bid "MattermostShare" "${SHARE_BUNDLE_ID}"
set_bid "NotificationService" "${NOTI_BUNDLE_ID}"

echo "==> Bundle ID patching finished"

# Print summary
echo "Summary:"
echo "  App bundle id:        ${MAIN_BUNDLE_ID}"
echo "  Share bundle id:      ${SHARE_BUNDLE_ID}"
echo "  Notification bundle:  ${NOTI_BUNDLE_ID}"
echo "  App Group:            ${APP_GROUP_ID}"
