#!/usr/bin/env bash
# 跨模块扁平菜单 UI 回归
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

assert_ui_item_ok() {
  local label=$1 file=$2
  set +e
  out=$(
    set -Eeuo pipefail
    # shellcheck source=/dev/null
    source "$file"
    ui_item 1 "普通项"
    ui_item 2 "危险项" danger
    ui_item 0 "返回" muted
    printf 'SURVIVED\n'
  ) 2>&1
  rc=$?
  set -e
  assert "$label ui_item set -e ok" '[[ $rc -eq 0 && "$out" == *SURVIVED* ]]'
  assert "$label ui_item printed" '[[ "$out" == *"普通项"* && "$out" == *"返回"* ]]'
}

assert_ui_item_ok "vps" "$ROOT/vps.sh"
assert_ui_item_ok "proxy" "$ROOT/proxy.sh"

export VPS_TRAFFIC_MOCK=1
export VPS_TRAFFIC_TEST_DIR="$TMP/traffic-ui"
export MOCK_IFACE=eth0
export MOCK_TX_BYTES=1000
export MOCK_YEAR=$(date +%Y)
export MOCK_MONTH=$(date +%m)
mkdir -p "$VPS_TRAFFIC_TEST_DIR/etc" "$VPS_TRAFFIC_TEST_DIR/var" "$VPS_TRAFFIC_TEST_DIR/mock_tc"
cat >"$VPS_TRAFFIC_TEST_DIR/etc/config" <<EOF
MONTHLY_QUOTA_GB=
THRESHOLD_PERCENT=90
LIMIT_RATE=1mbit
IFACE=eth0
PAUSED=false
EOF
cat >"$VPS_TRAFFIC_TEST_DIR/var/state" <<EOF
LIMIT_ACTIVE=false
LIMIT_IFACE=
LIMIT_HANDLE=
LAST_REASON=
LAST_CHECK_TS=
LAST_TX_BYTES=
LAST_MONTH=
LAST_RATIO=
OWNED_BY_TOOL=false
EOF
: >"$VPS_TRAFFIC_TEST_DIR/var/.installed"

assert_ui_item_ok "traffic" "$ROOT/traffic.sh"

# shellcheck source=../traffic.sh
source "$ROOT/traffic.sh"

cmd_install() { echo "__CALL_cmd_install__"; }
cmd_status() { echo "__CALL_cmd_status__"; }
cmd_settings() { echo "__CALL_cmd_settings__"; }
cmd_check_now() { echo "__CALL_cmd_check_now__"; }
cmd_remove_limit() { echo "__CALL_cmd_remove_limit__"; }
cmd_pause() { echo "__CALL_cmd_pause__"; }
cmd_resume() { echo "__CALL_cmd_resume__"; }
cmd_update_module() { echo "__CALL_cmd_update_module__"; }
cmd_uninstall() { echo "__CALL_cmd_uninstall__"; }
read_tty() {
  local __var
  while [[ $# -gt 0 ]]; do
    case $1 in -p) shift 2 ;; -r) shift ;; *) break ;; esac
  done
  __var=${1:-REPLY}
  # shellcheck disable=SC2034
  read -r "$__var" || return 1
}

set +e
menu_out=$(printf '0\n' | main_menu 2>&1)
menu_rc=$?
set -e
assert "traffic menu exit 0" '[[ $menu_rc -eq 0 ]]'
assert "traffic flat items" '
  [[ "$menu_out" == *"查看状态"* ]] &&
  [[ "$menu_out" == *"修改流量设置"* ]] &&
  [[ "$menu_out" == *"立即检查"* ]] &&
  [[ "$menu_out" == *"更多操作"* ]] &&
  [[ "$menu_out" == *"返回"* ]]
'
assert "no install when installed" '[[ "$menu_out" != *"安装流量监控"* ]]'
assert "no group titles" '
  ! grep -qE "^[[:space:]]*监控[[:space:]]*$" <<<"$menu_out" &&
  ! grep -qE "^[[:space:]]*策略[[:space:]]*$" <<<"$menu_out" &&
  ! grep -qE "^[[:space:]]*运维[[:space:]]*$" <<<"$menu_out" &&
  ! grep -qE "^[[:space:]]*系统[[:space:]]*$" <<<"$menu_out"
'
has_box=0
for ch in ╭ ╮ ╰ ╯ │ ├ ┤ ─ ▸; do
  [[ "$menu_out" == *"$ch"* ]] && has_box=1 && break
done
assert "no box chars" '[[ $has_box -eq 0 ]]'
assert "version head" '[[ "$menu_out" == *"v${VERSION}"* ]]'

out2=$(printf '2\n\n0\n' | main_menu 2>&1) || true
assert "case settings" '[[ "$out2" == *"__CALL_cmd_settings__"* ]]'

out0=$(printf '0\n' | main_menu 2>&1) || true
assert "case 0 return" '[[ "$out0" != *__CALL_* ]]'

set +e
out_empty=$(printf '\n' | main_menu 2>&1)
rc_empty=$?
set -e
assert "empty input no crash" '[[ $rc_empty -eq 0 ]]'

assert "no ui_group def" '! grep -qE "^ui_group\\(\\)" "$ROOT/traffic.sh"'
assert "VERSION traffic 1.4.0" 'grep -q VERSION=\"1.4.0\" "$ROOT/traffic.sh"'
assert "VERSION proxy 1.5.0" 'grep -q VERSION=\"1.5.0\" "$ROOT/proxy.sh"'
assert "VERSION vps 1.2.0" 'grep -q VERSION=\"1.2.0\" "$ROOT/vps.sh"'

echo ""
echo "PASS=$pass FAIL=$fail"
[[ $fail -eq 0 ]]
