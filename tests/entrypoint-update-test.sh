#!/usr/bin/env bash
# syw-vps 管理脚本更新测试：下载、语法/标识校验、提交记录与失败保护。
set -Eeuo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
assert() {
  local name=$1
  shift
  if eval "$*"; then
    echo "[PASS] $name"
    pass=$((pass + 1))
  else
    echo "[FAIL] $name"
    fail=$((fail + 1))
  fi
}

# shellcheck source=../vps.sh
source "$ROOT/vps.sh"

require_root() { :; }
LIB_DIR="$TMP/lib"
VPS_SH_LOCAL="$LIB_DIR/vps.sh"
PROXY_SH_LOCAL="$LIB_DIR/proxy.sh"
TRAFFIC_SH_LOCAL="$LIB_DIR/traffic.sh"
SYW_VPS_UPDATE_STATE="$TMP/update-state"
SYW_VPS_BACKUP_DIR="$TMP/backups"
mkdir -p "$LIB_DIR"
cp "$ROOT/vps.sh" "$VPS_SH_LOCAL"
cp "$ROOT/proxy.sh" "$PROXY_SH_LOCAL"
cp "$ROOT/traffic.sh" "$TRAFFIC_SH_LOCAL"
printf 'REF=%040d\n' 1 >"$SYW_VPS_UPDATE_STATE"

resolve_latest_ref() { printf '%040d\n' 2; }
http_get() {
  case $1 in
    */vps.sh) cp "$ROOT/vps.sh" "$2" ;;
    */proxy.sh) cp "$ROOT/proxy.sh" "$2" ;;
    */traffic.sh) cp "$ROOT/traffic.sh" "$2" ;;
    *) return 1 ;;
  esac
}

update_modules manual >/dev/null
assert "all modules updated" 'bash -n "$VPS_SH_LOCAL" && bash -n "$PROXY_SH_LOCAL" && bash -n "$TRAFFIC_SH_LOCAL"'
assert "new commit recorded" 'grep -q "REF=$(printf "%040d" 2)" "$SYW_VPS_UPDATE_STATE"'
assert "backup retained" 'find "$SYW_VPS_BACKUP_DIR" -type f -name "vps.sh" | grep -q .'

old_hash=$(sha256sum "$TRAFFIC_SH_LOCAL" | awk '{print $1}')
http_get() {
  case $1 in
    */vps.sh) cp "$ROOT/vps.sh" "$2" ;;
    */proxy.sh) cp "$ROOT/proxy.sh" "$2" ;;
    */traffic.sh) printf 'not a shell script\n' >"$2" ;;
    *) return 1 ;;
  esac
}
resolve_latest_ref() { printf '%040d\n' 3; }
set +e
(update_modules auto >/dev/null 2>&1)
rc=$?
set -e
new_hash=$(sha256sum "$TRAFFIC_SH_LOCAL" | awk '{print $1}')
assert "invalid candidate fails" '[[ $rc -ne 0 ]]'
assert "invalid candidate leaves old module" '[[ "$new_hash" == "$old_hash" ]]'

echo ""
echo "PASS=$pass FAIL=$fail"
[[ $fail -eq 0 ]]
