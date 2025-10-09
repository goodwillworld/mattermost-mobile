#!/usr/bin/env bash
set -euo pipefail

MAIN_BUNDLE_ID="${MAIN_BUNDLE_ID:?}"
SHARE_BUNDLE_ID="${SHARE_BUNDLE_ID:?}"
NOTI_BUNDLE_ID="${NOTI_BUNDLE_ID:?}"
APP_GROUP_ID="${APP_GROUP_ID:?}"
TEAM_ID="${TEAM_ID:-}"

ROOT="$(pwd)"
IOS_DIR="${ROOT}/ios"

APP_ENT="${IOS_DIR}/Mattermost/Mattermost.entitlements"
SHARE_ENT="${IOS_DIR}/MattermostShare/MattermostShare.entitlements"
NOTI_ENT="${IOS_DIR}/NotificationService/NotificationService.entitlements"

ensure_dirs () {
  mkdir -p "$(dirname "$APP_ENT")" "$(dirname "$SHARE_ENT")" "$(dirname "$NOTI_ENT")"
}

create_min_plist () {
  local file="$1"
  cat > "$file" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict/>
</plist>
PL
}

normalize_plist () {
  local file="$1"
  if [ ! -f "$file" ]; then
    create_min_plist "$file"
    return 0
  fi
  if ! /usr/bin/plutil -lint "$file" >/dev/null 2>&1; then
    echo "WARN: $file invalid, recreating"
    create_min_plist "$file"
    return 0
  fi
  local type
  type="$(/usr/bin/plutil -p "$file" 2>/dev/null | head -n1 || true)"
  if [[ "${type:-}" != \{* ]]; then
    echo "WARN: $file top-level not dict, recreating"
    create_min_plist "$file"
  fi
}

ensure_app_group () {
  local file="$1"
  normalize_plist "$file"
  if /usr/libexec/PlistBuddy -c "Print :com.apple.security.application-groups" "$file" >/dev/null 2>&1; then
    if ! /usr/libexec/PlistBuddy -c "Print :com.apple.security.application-groups" "$file" 2>&1 | head -n1 | grep -q "Array {"; then
      /usr/libexec/PlistBuddy -c "Delete :com.apple.security.application-groups" "$file" || true
    fi
  fi
  /usr/libexec/PlistBuddy -c "Add :com.apple.security.application-groups array" "$file" 2>/dev/null || true
  local COUNT="$(/usr/libexec/PlistBuddy -c "Print :com.apple.security.application-groups" "$file" 2>/dev/null | grep -E '^\s*[0-9]+\s*=' | wc -l | tr -d ' ')"
  if [[ "${COUNT:-0}" -gt 0 ]]; then
    for (( i=COUNT-1; i>=0; i-- )); do
      /usr/libexec/PlistBuddy -c "Delete :com.apple.security.application-groups:$i" "$file" || true
    done
  fi
  /usr/libexec/PlistBuddy -c "Add :com.apple.security.application-groups:0 string ${APP_GROUP_ID}" "$file"
  echo "OK: Set App Group in $(basename "$file")"
}

ensure_push_for_main () {
  /usr/libexec/PlistBuddy -c "Delete :aps-environment" "$APP_ENT" >/dev/null 2>&1 || true
  /usr/libexec/PlistBuddy -c "Add :aps-environment string production" "$APP_ENT"
  echo "OK: Set aps-environment=production for main app"
}

patch_pbxproj () {
  local pbx="${IOS_DIR}/Mattermost.xcodeproj/project.pbxproj"
  echo "==> Patching ${pbx}"
  python3 - "$pbx" "$MAIN_BUNDLE_ID" "$SHARE_BUNDLE_ID" "$NOTI_BUNDLE_ID" <<'PY'
import sys, re, io
pbx, main_bid, share_bid, noti_bid = sys.argv[1:5]
s = io.open(pbx, 'r', encoding='utf-8').read()

def subn(pat, rep, s):
  new, n = re.subn(pat, rep, s, flags=re.M|re.S)
  return new, n

mapping_ents = {
  "Mattermost": "Mattermost/Mattermost.entitlements",
  "MattermostShare": "MattermostShare/MattermostShare.entitlements",
  "NotificationService": "NotificationService/NotificationService.entitlements",
}
mapping_bids = {
  "Mattermost": main_bid,
  "MattermostShare": share_bid,
  "NotificationService": noti_bid,
}

for name, ent in mapping_ents.items():
  pat = r'(\/\* %s \*\/[\s\S]*?CODE_SIGN_ENTITLEMENTS\s*=)\s*[^;]+;' % re.escape(name)
  s, n1 = subn(pat, r'\1 %s;' % ent, s)
  pat2 = r'(CODE_SIGN_ENTITLEMENTS\s*=)\s*[^;]+;([\s\S]{0,400}PRODUCT_NAME\s*=\s*"?%s"?;)' % re.escape(name)
  s, n2 = subn(pat2, r'\1 %s;\2' % ent, s)
  pat3 = r'(\/\* %s \*\/[\s\S]*?PRODUCT_BUNDLE_IDENTIFIER\s*=)\s*[^;]+;' % re.escape(name)
  s, n3 = subn(pat3, r'\1 %s;' % mapping_bids[name], s)
  pat4 = r'(PRODUCT_BUNDLE_IDENTIFIER\s*=)\s*[^;]+;([\s\S]{0,400}PRODUCT_NAME\s*=\s*"?%s"?;)' % re.escape(name)
  s, n4 = subn(pat4, r'\1 %s;\2' % mapping_bids[name], s)
  print(f"{name}: entitlements patched {n1+n2} time(s), bundle id patched {n3+n4} time(s)")

io.open(pbx, 'w', encoding='utf-8').write(s)
print("PBXProject patch complete")
PY

  if [ -n "${TEAM_ID}" ]; then
    python3 - "$pbx" "$TEAM_ID" <<'PY'
import sys, re, io
pbx, team = sys.argv[1:3]
s = io.open(pbx, 'r', encoding='utf-8').read()
s = re.sub(r'(DEVELOPMENT_TEAM\s*=\s*)[^;]+;', r'\1%s;' % team, s)
io.open(pbx, 'w', encoding='utf-8').write(s)
print("Set DEVELOPMENT_TEAM to", team)
PY
  fi
}

echo "==> Ensuring directories"
ensure_dirs

echo "==> Ensuring entitlements include App Group ${APP_GROUP_ID}"
ensure_app_group "$APP_ENT"
ensure_app_group "$SHARE_ENT"
ensure_app_group "$NOTI_ENT"
ensure_push_for_main

patch_pbxproj

echo "Summary:"
echo "  App bundle id:        ${MAIN_BUNDLE_ID}"
echo "  Share bundle id:      ${SHARE_BUNDLE_ID}"
echo "  Notification bundle:  ${NOTI_BUNDLE_ID}"
echo "  App Group:            ${APP_GROUP_ID}"
