#!/usr/bin/env bash
# traffic 动态主菜单 / action 映射 / set -e 回归
set -Eeuo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TRAFFIC="$ROOT/traffic.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

export VPS_TRAFFIC_MOCK=1
export VPS_TRAFFIC_TEST_DIR="$TMP"
export MOCK_IFACE=eth0
export MOCK_TX_BYTES=$((1 * 1000000000))
export MOCK_YEAR=$(date +%Y)
export MOCK_MONTH=$(date +%m)

mkdir -p "$TMP/etc" "$TMP/var" "$TMP/mock_tc"
cat >"$TMP/etc/config" <<EOF
MONTHLY_QUOTA_GB=100
THRESHOLD_PERCENT=90
LIMIT_RATE=1mbit
IFACE=eth0
PAUSED=false
EOF
cat >"$TMP/var/state" <<EOF
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

# shellcheck source=../traffic.sh
source "$TRAFFIC"

set +e
ui_out=$(
  set -Eeuo pipefail
  ui_item 1 "a"
  ui_item 2 "b" danger
  ui_item 0 "c" muted
  printf 'SURVIVED\n'
) 2>&1
ui_rc=$?
set -e
assert "ui_item multi exit 0" '[[ $ui_rc -eq 0 ]]'
assert "ui_item multi survived" '[[ "$ui_out" == *SURVIVED* ]]'

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

# 未安装
rm -f "$TMP/var/.installed"
out=$(printf '0\n' | main_menu 2>&1) || true
assert "uninst has install" '[[ "$out" == *"安装流量监控"* ]]'
assert "uninst status 尚未安装" '[[ "$out" == *"尚未安装"* ]]'
assert "uninst no settings" '[[ "$out" != *"修改流量设置"* ]]'
assert "uninst prompt 0-1" '[[ "$out" == *"请选择 [0-1]"* ]]'
out1=$(printf '1\n\n0\n' | main_menu 2>&1) || true
assert "uninst case install" '[[ "$out1" == *"__CALL_cmd_install__"* ]]'

# 已安装
: >"$TMP/var/.installed"
out=$(printf '0\n' | main_menu 2>&1) || true
assert "inst no install item" '[[ "$out" != *"安装流量监控"* ]]'
assert "inst has core items" '[[ "$out" == *"查看状态"* && "$out" == *"修改流量设置"* && "$out" == *"立即检查"* && "$out" == *"更多操作"* ]]'
assert "inst has pause only" '[[ "$out" == *"暂停自动检查"* && "$out" != *"恢复自动检查"* ]]'
assert "inst no remove on main" '[[ "$out" != *"解除当前限速"* ]]'
assert "inst no groups" '[[ "$out" != *"运维"* && "$out" != *"策略"* && "$out" != *"系统"* ]]'
assert "inst prompt" '[[ "$out" == *"请选择 [0-5]"* ]]'

out1=$(printf '1\n\n0\n' | main_menu 2>&1) || true
assert "case1 status" '[[ "$out1" == *"__CALL_cmd_status__"* ]]'
out2=$(printf '2\n\n0\n' | main_menu 2>&1) || true
assert "case2 settings" '[[ "$out2" == *"__CALL_cmd_settings__"* ]]'
out3=$(printf '3\n\n0\n' | main_menu 2>&1) || true
assert "case3 check" '[[ "$out3" == *"__CALL_cmd_check_now__"* ]]'
out4=$(printf '4\n\n0\n' | main_menu 2>&1) || true
assert "case4 pause" '[[ "$out4" == *"__CALL_cmd_pause__"* ]]'

# 限速：解除在更多第 1 项；主菜单仍是暂停
cat >"$TMP/var/state" <<EOF
LIMIT_ACTIVE=true
LIMIT_IFACE=eth0
LIMIT_HANDLE=1abc:
LAST_REASON=
LAST_CHECK_TS=
LAST_TX_BYTES=
LAST_MONTH=
LAST_RATIO=
OWNED_BY_TOOL=true
EOF
printf 'qdisc tbf 1abc: root\n' >"$TMP/mock_tc/eth0"
out=$(printf '0\n' | main_menu 2>&1) || true
assert "limit no remove on main" '[[ "$out" != *"解除当前限速"* ]]'
assert "limit still pause on main" '[[ "$out" == *"暂停自动检查"* ]]'
outrm=$(printf '5\n1\n\n0\n0\n' | main_menu 2>&1) || true
assert "more remove when limited" '[[ "$outrm" == *"__CALL_cmd_remove_limit__"* ]]'

# 更多 → 卸载（非限速时：1 更新 2 卸载）
cat >"$TMP/var/state" <<EOF
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
: >"$TMP/mock_tc/eth0"
outu=$(printf '5\n2\n' | main_menu 2>&1) || true
assert "more uninstall" '[[ "$outu" == *"__CALL_cmd_uninstall__"* ]]'
outup=$(printf '5\n1\n\n0\n0\n' | main_menu 2>&1) || true
assert "more update" '[[ "$outup" == *"__CALL_cmd_update_module__"* ]]'
assert "update delegates to vps" 'grep -q "bash \"\$entry\" update" "$ROOT/traffic.sh"'
assert "no floating traffic self curl" '! grep -q "RAW_BASE}/traffic.sh" "$ROOT/traffic.sh"'

# 暂停状态：第 4 项恢复
cat >"$TMP/etc/config" <<EOF
MONTHLY_QUOTA_GB=100
THRESHOLD_PERCENT=90
LIMIT_RATE=1mbit
IFACE=eth0
PAUSED=true
EOF
out=$(printf '0\n' | main_menu 2>&1) || true
assert "paused shows resume" '[[ "$out" == *"恢复自动检查"* && "$out" != *"暂停自动检查"* ]]'
out4=$(printf '4\n\n0\n' | main_menu 2>&1) || true
assert "case4 resume" '[[ "$out4" == *"__CALL_cmd_resume__"* ]]'

out0=$(printf '0\n' | main_menu 2>&1) || true
assert "case0 clean" '[[ "$out0" != *__CALL_* ]]'
set +e
out_empty=$(printf '\n' | main_menu 2>&1)
rc_empty=$?
set -e
assert "empty exit 0" '[[ $rc_empty -eq 0 ]]'

# 设置合并保存（重新 source 拿真实 cmd_settings）
# shellcheck source=../traffic.sh
source "$TRAFFIC"
require_root() { return 0; }
read_tty() {
  local __var
  while [[ $# -gt 0 ]]; do
    case $1 in -p) shift 2 ;; -r) shift ;; *) break ;; esac
  done
  __var=${1:-REPLY}
  # shellcheck disable=SC2034
  read -r "$__var" || return 1
}
cat >"$TMP/etc/config" <<EOF
MONTHLY_QUOTA_GB=100
THRESHOLD_PERCENT=90
LIMIT_RATE=1mbit
IFACE=eth0
PAUSED=false
EOF
# 空=保持 空=保持 2mbit Y
printf '\n\n2mbit\nY\n' | cmd_settings >/dev/null
# shellcheck disable=SC1091
source "$TMP/etc/config"
assert "settings keep quota" '[[ "$MONTHLY_QUOTA_GB" == "100" ]]'
assert "settings keep thr" '[[ "$THRESHOLD_PERCENT" == "90" ]]'
assert "settings rate 2mbit" '[[ "$LIMIT_RATE" == "2mbit" ]]'

echo ""
echo "PASS=$pass FAIL=$fail"
[[ $fail -eq 0 ]]
