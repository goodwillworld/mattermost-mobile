#!/usr/bin/env bash
set -euo pipefail

IOS_DIR="ios"
PBX="${IOS_DIR}/Mattermost.xcodeproj/project.pbxproj"
TEAM_ID="${TEAM_ID:-}"

want_main="${MAIN_BUNDLE_ID:?}"
want_share="${SHARE_BUNDLE_ID:?}"
want_noti="${NOTI_BUNDLE_ID:?}"

PDIR="$HOME/Library/MobileDevice/Provisioning Profiles"

echo "==> Scanning $PDIR"
ls -l "$PDIR" || true

find_profile() {
  local want_bundle="$1"      # e.g. com.jboth.mine or com.jboth.mine.MattermostShare
  local need_group="$2"       # "yes" or "no"
  local best_name="" best_uuid="" best_file=""

  shopt -s nullglob
  for f in "$PDIR"/*.mobileprovision "$PDIR"/*.provisionprofile; do
    PL=$(/usr/bin/security cms -D -i "$f" 2>/dev/null) || continue

    NAME=$(echo "$PL" | /usr/bin/plutil -extract Name raw -o - - 2>/dev/null)
    UUID=$(echo "$PL" | /usr/bin/plutil -extract UUID raw -o - - 2>/dev/null)
    APPID=$(echo "$PL" | /usr/bin/plutil -extract Entitlements.application-identifier raw -o - - 2>/dev/null || true)

    # Bundle 匹配：带 Team ID 时精确匹配；否则后缀匹配
    if [ -n "$TEAM_ID" ]; then
      [[ "$APPID" == "$TEAM_ID.$want_bundle" ]] || continue
    else
      [[ "$APPID" == *".$want_bundle" ]] || continue
    fi

    # 检测 App Groups（用 PlistBuddy 更稳）
    HAS_GROUPS=$(
      echo "$PL" > /tmp/_pp.plist
      if /usr/libexec/PlistBuddy -c "Print :Entitlements:com.apple.security.application-groups" /tmp/_pp.plist >/dev/null 2>&1; then
        echo yes
      else
        echo no
      fi
    )

    if [ "$need_group" = "yes" ] && [ "$HAS_GROUPS" != "yes" ]; then
      echo "Skip $NAME: bundle ok, but no App Groups"
      continue
    fi

    best_name="$NAME"; best_uuid="$UUID"; best_file="$f"
    # 命中即取（一个 bundle 通常只会装 1 个同分发类型的 profile）
    break
  done

  if [ -z "$best_uuid" ]; then
    return 1
  fi
  echo "$best_name|$best_uuid|$best_file"
  return 0
}

apply_profile_to_pbx() {
  local target="$1" bundle="$2" need_groups="$3"
  local r
  if ! r=$(find_profile "$bundle" "$need_groups"); then
    echo "ERROR: No provisioning profile found for $bundle (groups=$need_groups)"
    exit 1
  fi
  local name="${r%%|*}"; r="${r#*|}"
  local uuid="${r%%|*}"; local file="${r##*|}"
  echo "Matched profile for $target ($bundle):"
  echo "  Name: $name"
  echo "  UUID: $uuid"
  echo "  File: $file"

  python3 - "$PBX" "$target" "$name" "$uuid" <<'PY'
import sys, re, io
pbx, target, spec, uuid = sys.argv[1:5]
s = io.open(pbx, 'r', encoding='utf-8').read()

def patch_key_near_target(s, key, value, target):
  s, n1 = re.subn(r'(\/\* %s \*\/[\s\S]*?%s\s*=)\s*[^;]+;' % (re.escape(target), re.escape(key)),
                  r'\g<1> %s;' % value, s, flags=re.M|re.S)
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
apply_profile_to_pbx "MattermostShare"     "$want_share" "yes"
apply_profile_to_pbx "NotificationService" "$want_noti" "yes"

echo "==> Profiles applied."
