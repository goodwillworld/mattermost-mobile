#!/usr/bin/env bash
set -euo pipefail

# Expected env vars
MAIN_BUNDLE_ID="${MAIN_BUNDLE_ID:?}"
SHARE_BUNDLE_ID="${SHARE_BUNDLE_ID:?}"
NOTI_BUNDLE_ID="${NOTI_BUNDLE_ID:?}"
APP_GROUP_ID="${APP_GROUP_ID:?}"

ROOT="$(pwd)"
IOS_DIR="${ROOT}/ios"

APP_ENT="${IOS_DIR}/Mattermost/Mattermost.entitlements"
SHARE_ENT="${IOS_DIR}/MattermostShare/MattermostShare.entitlements"
NOTI_ENT="${IOS_DIR}/NotificationService/NotificationService.entitlements"

mkdir -p "$(dirname "$APP_ENT")" "$(dirname "$SHARE_ENT")" "$(dirname "$NOTI_ENT")"

create_min_plist () {
  local file="$1"
  cat > "$file" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict/>
</plist>
EOF
}

normalize_plist () {
  local file="$1"
  if [ ! -f "$file" ]; then
    create_min_plist "$file"
    return 0
  fi

  # Validate; if invalid, recreate
  if ! /usr/bin/plutil -lint "$file" >/dev/null 2>&1; then
    echo "WARN: $file is invalid, recreating minimal dict"
    create_min_plist "$file"
    return 0
  fi

  # Ensure top-level is a dict; if not, recreate
  local type
  type="$(/usr/bin/plutil -p "$file" 2>/dev/null | head -n1 || true)"
  if [[ "${type:-}" != \{* ]]; then
    echo "WARN: $file top-level is not a dict, recreating"
    create_min_plist "$file"
  fi
}

ensure_app_group () {
  local file="$1"
  normalize_plist "$file"

  # Remove wrong-typed existing key if needed, then create array and set string
  if /usr/libexec/PlistBuddy -c "Print :com.apple.security.application-groups" "$file" >/dev/null 2>&1; then
    if ! /usr/libexec/PlistBuddy -c "Print :com.apple.security.application-groups" "$file" 2>&1 | head -n1 | grep -q "Array {"; then
      /usr/libexec/PlistBuddy -c "Delete :com.apple.security.application-groups" "$file" || true
    fi
  fi

  /usr/libexec/PlistBuddy -c "Add :com.apple.security.application-groups array" "$file" 2>/dev/null || true

  # Clear existing items
  COUNT="$(/usr/libexec/PlistBuddy -c "Print :com.apple.security.application-groups" "$file" 2>/dev/null | grep -E '^\s*[0-9]+\s*=\s*' | wc -l | tr -d ' ')"
  if [[ "${COUNT:-0}" -gt 0 ]]; then
    for (( i=COUNT-1; i>=0; i-- )); do
      /usr/libexec/PlistBuddy -c "Delete :com.apple.security.application-groups:$i" "$file" || true
    done
  fi
  /usr/libexec/PlistBuddy -c "Add :com.apple.security.application-groups:0 string ${APP_GROUP_ID}" "$file"
  echo "OK: Set App Group in $(basename "$file")"
}

echo "==> Ensuring entitlements include App Group ${APP_GROUP_ID}"
ensure_app_group "$APP_ENT"
ensure_app_group "$SHARE_ENT"
ensure_app_group "$NOTI_ENT"

# Patch bundle identifiers best-effort
PBX="${IOS_DIR}/Mattermost.xcodeproj/project.pbxproj"
echo "==> Patching PRODUCT_BUNDLE_IDENTIFIER in ${PBX} (best-effort)"

python3 - "$PBX" "$MAIN_BUNDLE_ID" "$SHARE_BUNDLE_ID" "$NOTI_BUNDLE_ID" <<'PY'
import sys, re
pbx, main_bid, share_bid, noti_bid = sys.argv[1:5]
s = open(pbx, 'r', encoding='utf-8').read()

def patch_target(s, target, bid):
    patterns = [
        (re.compile(r'(/\* %s \*/[\\s\\S]*?PRODUCT_BUNDLE_IDENTIFIER\\s*=)\\s*[^;]+;' % re.escape(target)), r'\\1 ' + bid + ';'),
        (re.compile(r'(PRODUCT_BUNDLE_IDENTIFIER\\s*=)\\s*[^;]+(;\\s*\\n\\s*PRODUCT_NAME\\s*=\\s*"?' + re.escape(target) + r'"?\\s*;)'), r'\\1 ' + bid + r'\\2'),
    ]
    total = 0
    for pat, rep in patterns:
        s, n = pat.subn(rep, s)
        total += n
    return s, total

total = 0
for target, bid in [("Mattermost", main_bid), ("MattermostShare", share_bid), ("NotificationService", noti_bid)]:
    s, n = patch_target(s, target, bid)
    print(f"Updated {n} occurrence(s) for target {target}")
    total += n

open(pbx, 'w', encoding='utf-8').write(s)
print(f"Total updated: {total}")
PY

echo "Summary:"
echo "  App bundle id:        ${MAIN_BUNDLE_ID}"
echo "  Share bundle id:      ${SHARE_BUNDLE_ID}"
echo "  Notification bundle:  ${NOTI_BUNDLE_ID}"
echo "  App Group:            ${APP_GROUP_ID}"
