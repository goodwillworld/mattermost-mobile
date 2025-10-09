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
  s, n1 = subn(pat,  r'\g<1> %s;' % ent, s)
  pat2 = r'(CODE_SIGN_ENTITLEMENTS\s*=)\s*[^;]+;([\s\S]{0,400}PRODUCT_NAME\s*=\s*"?%s"?;)' % re.escape(name)
  s, n2 = subn(pat2, r'\g<1> %s;\2' % ent, s)
  pat3 = r'(\/\* %s \*\/[\s\S]*?PRODUCT_BUNDLE_IDENTIFIER\s*=)\s*[^;]+;' % re.escape(name)
  s, n3 = subn(pat3, r'\g<1> %s;' % mapping_bids[name], s)
  pat4 = r'(PRODUCT_BUNDLE_IDENTIFIER\s*=)\s*[^;]+;([\s\S]{0,400}PRODUCT_NAME\s*=\s*"?%s"?;)' % re.escape(name)
  s, n4 = subn(pat4, r'\g<1> %s;\2' % mapping_bids[name], s)
  print(f"{name}: entitlements patched {n1+n2} time(s), bundle id patched {n3+n4} time(s)")

io.open(pbx, 'w', encoding='utf-8').write(s)
print("PBXProject patch complete")
PY

  if [ -n "${TEAM_ID}" ]; then
    python3 - "$pbx" "$TEAM_ID" <<'PY'
import sys, re, io
pbx, team = sys.argv[1:3]
s = io.open(pbx, 'r', encoding='utf-8').read()
s = re.sub(r'(DEVELOPMENT_TEAM\s*=\s*)[^;]+;', fr'\g<1>{team};', s)
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

echo "==> Resolving provisioning profiles for targets"

find_profile() {
  local want_bundle="$1"      # 例如 com.jboth.mine.MattermostShare
  local need_push="$2"        # "yes"/"no"（主 App yes，扩展 no）
  local need_group="$3"       # "yes"（三者都要 group）
  local best_name="" best_uuid=""

  shopt -s nullglob
  for f in "$HOME/Library/MobileDevice/Provisioning Profiles/"*.mobileprovision \
           "$HOME/Library/MobileDevice/Provisioning Profiles/"*.provisionprofile; do
    # 解包成 plist
    PL=$(/usr/bin/security cms -D -i "$f" 2>/dev/null) || continue

    # 取 Profile 名称与 UUID
    NAME=$(echo "$PL" | /usr/bin/plutil -extract Name raw -o - - 2>/dev/null)
    UUID=$(echo "$PL" | /usr/bin/plutil -extract UUID raw -o - - 2>/dev/null)

    # 解析 application-identifier 与 entitlements
    APPID=$(echo "$PL" | /usr/bin/plutil -extract Entitlements.application-identifier raw -o - - 2>/dev/null || true)
    APS=$(echo "$PL" | /usr/bin/plutil -extract Entitlements.aps-environment raw -o - - 2>/dev/null || true)
    # App Groups（有些 profile 没有这个 key，raw 会报错，忽略即可）
    GROUPS=$(echo "$PL" | /usr/bin/plutil -p - 2>/dev/null | /usr/bin/grep -E '"com\.apple\.security\.application-groups"' -q && echo "yes" || echo "no")

    # APPID 通常是 TEAMID.BUNDLEID；允许 TEAM_ID 未设置时仅匹配后缀
    if [ -n "$TEAM_ID" ]; then
      [[ "$APPID" == "$TEAM_ID.$want_bundle" ]] || continue
    else
      [[ "$APPID" == *".$want_bundle" ]] || continue
    fi

    # 校验能力
    if [ "$need_push" = "yes" ] && [ -z "$APS" ]; then
      continue
    fi
    if [ "$need_group" = "yes" ] && [ "$GROUPS" != "yes" ]; then
      continue
    fi

    best_name="$NAME"
    best_uuid="$UUID"
    break
  done

  if [ -z "$best_uuid" ]; then
    return 1
  fi
  echo "$best_name|$best_uuid"
  return 0
}

apply_profile_to_pbx() {
  local target="$1" bundle="$2" need_push="$3"
  local r
  if ! r=$(find_profile "$bundle" "$need_push" "yes"); then
    echo "ERROR: No provisioning profile found for $bundle (push=$need_push, groups=yes)"
    return 1
  fi
  local name="${r%%|*}"
  local uuid="${r##*|}"
  echo "Matched profile for $target ($bundle): $name ($uuid)"

  # 写入 PROVISIONING_PROFILE_SPECIFIER / PROVISIONING_PROFILE 到 pbxproj
  python3 - "$PBX" "$target" "$name" "$uuid" <<'PY'
import sys, re, io
pbx, target, spec, uuid = sys.argv[1:5]
s = io.open(pbx, 'r', encoding='utf-8').read()

def subn(pat, rep):
  nonlocal_s = globals().setdefault('_s', None)
  return re.subn(pat, rep, s, flags=re.M|re.S)

# 为目标块内写入/替换两个键
def patch_key_near_target(s, key, value, target):
  # 1) 限定在目标注释块内
  pat1 = re.compile(r'(\/\* %s \*\/[\s\S]*?%s\s*=)\s*[^;]+;' % (re.escape(target), re.escape(key)))
  s, n1 = pat1.subn(r'\1 %s;' % value, s)
  # 2) 或者在靠近该 target 的 buildSettings 中（通过 PRODUCT_NAME 匹配）
  pat2 = re.compile(r'(%s\s*=)\s*[^;]+;([\s\S]{0,400}PRODUCT_NAME\s*=\s*"?%s"?;)' % (re.escape(key), re.escape(target)))
  s, n2 = pat2.subn(r'\1 %s;\2' % value, s)
  return s, (n1+n2)

# 写 specifier（用名称）
s, nA = patch_key_near_target(s, 'PROVISIONING_PROFILE_SPECIFIER', spec, target)
# 也写 UUID（兼容老字段）
s, nB = patch_key_near_target(s, 'PROVISIONING_PROFILE', uuid, target)
io.open(pbx, 'w', encoding='utf-8').write(s)
print(f"Patched {target}: SPECIFIER {nA}x, UUID {nB}x")
PY
}

PBX="${IOS_DIR}/Mattermost.xcodeproj/project.pbxproj"
apply_profile_to_pbx "Mattermost"          "$MAIN_BUNDLE_ID"          "yes"
apply_profile_to_pbx "MattermostShare"     "$SHARE_BUNDLE_ID"         "no"
apply_profile_to_pbx "NotificationService" "$NOTI_BUNDLE_ID"          "no"
