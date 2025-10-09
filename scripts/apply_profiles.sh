#!/usr/bin/env bash
set -euo pipefail

IOS_DIR="ios"
PBX="${IOS_DIR}/Mattermost.xcodeproj/project.pbxproj"
TEAM_ID="${TEAM_ID:-}"

want_main="${MAIN_BUNDLE_ID:?}"
want_share="${SHARE_BUNDLE_ID:?}"
want_noti="${NOTI_BUNDLE_ID:?}"

echo "==> Checking installed provisioning profiles"
ls -l "$HOME/Library/MobileDevice/Provisioning Profiles" || true

find_profile() {
  local want_bundle="$1"      # e.g. com.jboth.mine.MattermostShare
  local need_push="$2"        # yes/no
  local need_group="$3"       # yes/no
  local best_name="" best_uuid=""

  shopt -s nullglob
  for f in "$HOME/Library/MobileDevice/Provisioning Profiles/"*.mobileprovision \
           "$HOME/Library/MobileDevice/Provisioning Profiles/"*.provisionprofile; do
    PL=$(/usr/bin/security cms -D -i "$f" 2>/dev/null) || continue
    NAME=$(echo "$PL" | /usr/bin/plutil -extract Name raw -o - - 2>/dev/null)
    UUID=$(echo "$PL" | /usr/bin/plutil -extract UUID raw -o - - 2>/dev/null)
    APPID=$(echo "$PL" | /usr/bin/plutil -extract Entitlements.application-identifier raw -o - - 2>/dev/null || true)
    APS=$(echo "$PL" | /usr/bin/plutil -extract Entitlements.aps-environment raw -o - - 2>/dev/null || true)
    GROUPS=$(echo "$PL" | /usr/bin/plutil -p - 2>/dev/null | /usr/bin/grep -E '"com\.apple\.security\.application-groups"' -q && echo "yes" || echo "no")

    if [ -n "$TEAM_ID" ]; then
      [[ "$APPID" == "$TEAM_ID.$want_bundle" ]] || continue
    else
      [[ "$APPID" == *".$want_bundle" ]] || continue
    fi
    if [ "$need_push" = "yes" ] && [ -z "$APS" ]; then continue; fi
    if [ "$need_group" = "yes" ] && [ "$GROUPS" != "yes" ]; then continue; fi

    best_name="$NAME"; best_uuid="$UUID"; break
  done

  if [ -z "$best_uuid" ]; then return 1; fi
  echo "$best_name|$best_uuid"
}

apply_profile_to_pbx() {
  local target="$1" bundle="$2" need_push="$3"
  local r
  if ! r=$(find_profile "$bundle" "$need_push" "yes"); then
    echo "ERROR: No provisioning profile found for $bundle (push=$need_push, groups=yes)"
    exit 1
  fi
  local name="${r%%|*}"
  local uuid="${r##*|}"
  echo "Matched profile for $target ($bundle): $name ($uuid)"

  python3 - "$PBX" "$target" "$name" "$uuid" <<'PY'
import sys, re, io
pbx, target, spec, uuid = sys.argv[1:5]
s = io.open(pbx, 'r', encoding='utf-8').read()

def patch_key_near_target(s, key, value, target):
  # 限定在目标注释块内
  s, n1 = re.subn(r'(\/\* %s \*\/[\s\S]*?%s\s*=)\s*[^;]+;' % (re.escape(target), re.escape(key)),
                  r'\g<1> %s;' % value, s, flags=re.M|re.S)
  # 或者在靠近该 target 的 buildSettings 中（通过 PRODUCT_NAME 匹配）
  s, n2 = re.subn(r'(%s\s*=)\s*[^;]+;([\s\S]{0,400}PRODUCT_NAME\s*=\s*"?%s"?;)' % (re.escape(key), re.escape(target)),
                  r'\g<1> %s;\2' % value, s, flags=re.M|re.S)
  return s, (n1+n2)

s, nA = patch_key_near_target(s, 'PROVISIONING_PROFILE_SPECIFIER', spec, target)
s, nB = patch_key_near_target(s, 'PROVISIONING_PROFILE', uuid, target)
io.open(pbx, 'w', encoding='utf-8').write(s)
print(f"Patched {target}: SPECIFIER {nA}x, UUID {nB}x")
PY
}

apply_profile_to_pbx "Mattermost"          "$want_main" "yes"
apply_profile_to_pbx "MattermostShare"     "$want_share" "no"
apply_profile_to_pbx "NotificationService" "$want_noti" "no"

echo "==> Profiles applied."
