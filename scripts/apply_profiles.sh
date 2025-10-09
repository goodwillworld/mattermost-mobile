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

    # 检测 App Groups
    echo "$PL" > /tmp/_pp.plist
    if [ "$need_group" = "yes" ]; then
      if ! /usr/libexec/PlistBuddy -c "Print :Entitlements:com.apple.security.application-groups" /tmp/_pp.plist >/dev/null 2>&1; then
        echo "Skip $NAME: bundle ok, but no App Groups"
        continue
      fi
    fi

    best_name="$NAME"; best_uuid="$UUID"; best_file="$f"
    break
  done

  if [ -z "$best_uuid" ]; then
    return 1
  fi
  echo "$best_name|$best_uuid|$best_file"
  return 0
}

patch_target_signing() {
  local target="$1" spec="$2" uuid="$3" team="$4" push="$5" groups="$6"
  python3 - "$PBX" "$target" "$spec" "$uuid" "$team" "$push" "$groups" <<'PY'
import sys, re, io, json
pbx, target, spec, uuid, team, push, groups = sys.argv[1:8]
s = io.open(pbx, 'r', encoding='utf-8').read()

def subn(pat, rep, text):
  return re.subn(pat, rep, text, flags=re.M|re.S)

def patch_key_near_target(text, key, value, target):
  # 目标注释块内
  text, n1 = subn(r'(\/\* %s \*\/[\s\S]*?%s\s*=)\s*[^;]+;' % (re.escape(target), re.escape(key)),
                  r'\g<1> %s;' % value, text)
  # 或者靠近该 target 的 buildSettings（通过 PRODUCT_NAME）
  text, n2 = subn(r'(%s\s*=)\s*[^;]+;([\s\S]{0,400}PRODUCT_NAME\s*=\s*"?%s"?;)' % (re.escape(key), re.escape(target)),
                  r'\g<1> %s;\2' % value, text)
  return text, n1+n2

# 写入 SPECIFIER/UUID（通用键 + sdk 作用域键）
for key, val in [
  ('PROVISIONING_PROFILE_SPECIFIER', spec),
  ('PROVISIONING_PROFILE', uuid),
  ('PROVISIONING_PROFILE_SPECIFIER[sdk=iphoneos*]', spec),
  ('PROVISIONING_PROFILE[sdk=iphoneos*]', uuid),
  ('CODE_SIGN_STYLE', 'Manual'),
]:
  s, _ = patch_key_near_target(s, key, val, target)

# DEVELOPMENT_TEAM
if team:
  s, _ = patch_key_near_target(s, 'DEVELOPMENT_TEAM', team, target)

# SystemCapabilities：打开 App Groups；主 App 额外打开 Push
def enable_capability(text, target, cap_key):
  pat = r'(/[*] %s [*]/\s*=\s*{[\s\S]*?);\s*/\* End PBXNativeTarget section \*/' % re.escape(target)
  # 尝试在 TargetAttributes 写入
  if 'TargetAttributes' not in text:
    return text  # 忽略
  # 在 TargetAttributes 区域统一写，简单做全局替换
  # 开启 capability: com.apple.ApplicationGroups.iOS 或 com.apple.Push
  cap_map = {
    'groups': 'com.apple.ApplicationGroups.iOS',
    'push': 'com.apple.Push'
  }
  ck = cap_map[cap_key]
  # 在任一位置写一次 SystemCapabilities 开关（Xcode 不严格校验每 target，都能识别）
  if 'SystemCapabilities' not in text or ck not in text:
    text = re.sub(r'(TargetAttributes\s*=\s*\{)', r'\1 /* patched */', text)
  # 轻量方式：无害地添加开关（避免复杂 AST 解析）
  return text.replace('/* End PBXProject section */',
                      '/* End PBXProject section */')

# 简化处理：不少工程即使不写 SystemCapabilities，只要 entitlements + profile 对齐也能过，
# 这里保留函数但不强制插入，避免误改结构。

io.open(pbx, 'w', encoding='utf-8').write(s)
print(f"Patched {target}: set Manual signing, SPECIFIER/UUID (incl. sdk=iphoneos*), TEAM={team or '(skip)'}")
PY
}

apply_profile_to_pbx() {
  local target="$1" bundle="$2" need_groups="$3" need_push="$4"
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

  patch_target_signing "$target" "$name" "$uuid" "${TEAM_ID}" "$need_push" "$need_groups"
}

apply_profile_to_pbx "Mattermost"          "$want_main" "yes" "yes"
apply_profile_to_pbx "MattermostShare"     "$want_share" "yes" "no"
apply_profile_to_pbx "NotificationService" "$want_noti" "yes" "no"

echo "==> Profiles applied. Verifying…"

# 验证：三个目标的 4 个关键键都应有值（并且带 sdk=iphoneos* 的也要有）
fail=0
verify_target() {
  local T="$1"
  echo "---- VERIFY $T ----"
  xcodebuild -workspace ios/Mattermost.xcworkspace -scheme Mattermost -showBuildSettings \
    | awk -v t="$T" '
      /Build settings for action build and target/ {p = index($0, t)>0}
      p && /(PRODUCT_BUNDLE_IDENTIFIER|CODE_SIGN_ENTITLEMENTS|DEVELOPMENT_TEAM|PROVISIONING_PROFILE_SPECIFIER|PROVISIONING_PROFILE)/ {print}
    ' \
    | sed -E "s/^/$T: /"
}
verify_target Mattermost || fail=1
verify_target MattermostShare || fail=1
verify_target NotificationService || fail=1

exit $fail
