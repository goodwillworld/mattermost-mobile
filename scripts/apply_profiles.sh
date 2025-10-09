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
  local want_bundle="$1" need_group="$2"
  local best_name="" best_uuid="" best_file=""

  shopt -s nullglob
  for f in "$PDIR"/*.mobileprovision "$PDIR"/*.provisionprofile; do
    PL=$(/usr/bin/security cms -D -i "$f" 2>/dev/null) || continue
    NAME=$(echo "$PL" | /usr/bin/plutil -extract Name raw -o - - 2>/dev/null)
    UUID=$(echo "$PL" | /usr/bin/plutil -extract UUID raw -o - - 2>/dev/null)
    APPID=$(echo "$PL" | /usr/bin/plutil -extract Entitlements.application-identifier raw -o - - 2>/dev/null || true)

    if [ -n "$TEAM_ID" ]; then
      [[ "$APPID" == "$TEAM_ID.$want_bundle" ]] || continue
    else
      [[ "$APPID" == *".$want_bundle" ]] || continue
    fi

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

  if [ -z "$best_uuid" ]; then return 1; fi
  echo "$best_name|$best_uuid|$best_file"
}

# 只替换已存在键；不存在就提示并跳过（避免破坏语法）
patch_existing_keys() {
  local target="$1" spec="$2" uuid="$3" team="$4"
  python3 - "$PBX" "$target" "$spec" "$uuid" "$team" <<'PY'
import sys,re,io
pbx,target,spec,uuid,team=sys.argv[1:6]
s=io.open(pbx,'r',encoding='utf-8').read()

def rep_exist(pat,rep):
  new,n=re.subn(pat,rep,s,flags=re.M|re.S)
  return new,n

def patch_key(key,value):
  global s
  # 目标注释块内
  s,n1=rep_exist(r'(\/\* %s \*\/[\s\S]*?%s\s*=)\s*[^;]+;'%(re.escape(target),re.escape(key)),
                 r'\g<1> %s;'%value)
  # 或者在 buildSettings 区域且 400 字符内能看到 PRODUCT_NAME=target
  s,n2=rep_exist(r'(%s\s*=)\s*[^;]+;([\s\S]{0,400}PRODUCT_NAME\s*=\s*"?%s"?;)'%(re.escape(key),re.escape(target)),
                 r'\g<1> %s;\2'%value)
  return (n1+n2)>0

changed=False
# 只在存在这些键时替换
for k,v in [
  ('CODE_SIGN_STYLE','Manual'),
  ('CODE_SIGN_IDENTITY','Apple Distribution'),
  ('CODE_SIGN_IDENTITY[sdk=iphoneos*]','Apple Distribution'),
  ('DEVELOPMENT_TEAM',team if team else None),
  ('PROVISIONING_PROFILE_SPECIFIER',spec),
  ('PROVISIONING_PROFILE_SPECIFIER[sdk=iphoneos*]',spec),
  ('PROVISIONING_PROFILE',uuid),
  ('PROVISIONING_PROFILE[sdk=iphoneos*]',uuid),
]:
  if v is None: 
    continue
  if patch_key(k,v):
    changed=True

if changed:
  io.open(pbx,'w',encoding='utf-8').write(s)
  print(f"Patched {target}: updated existing signing keys")
else:
  print(f"NOTE: No existing signing keys updated for {target}; rely on xcode-project use-profiles/Xcode defaults.")
PY
}

apply_one() {
  local target="$1" bundle="$2"
  local r
  if ! r=$(find_profile "$bundle" "yes"); then
    echo "ERROR: No provisioning profile found for $bundle (need App Groups)"
    exit 1
  fi
  local name="${r%%|*}"; r="${r#*|}"
  local uuid="${r%%|*}"; local file="${r##*|}"
  echo "Matched profile for $target ($bundle): $name ($uuid)"
  patch_existing_keys "$target" "$name" "$uuid" "${TEAM_ID}"
}

apply_one "Mattermost"          "$want_main"
apply_one "MattermostShare"     "$want_share"
apply_one "NotificationService" "$want_noti"

echo "==> Done updating existing signing keys."
