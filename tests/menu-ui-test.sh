#!/usr/bin/env bash
# 跨模块扁平菜单 UI 回归：vps / proxy / traffic 的 ui_item 与 traffic 主菜单
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

# ---------- 1) 三模块 ui_item 无副标题 / style 在 set -e 下返回 0 ----------
assert_ui_item_ok() {
  local label=$1 file=$2
  # shellcheck disable=SC1090
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

# traffic 需 mock 环境再 source
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

assert_ui_item_ok "traffic" "$ROOT/traffic.sh"

# ---------- 2) traffic 主菜单扁平化与路由 ----------
# shellcheck source=../traffic.sh
source "$ROOT/traffic.sh"

cmd_install() { echo "__CALL_cmd_install__"; }
cmd_set_quota() { echo "__CALL_cmd_set_quota__"; }
cmd_status() { echo "__CALL_cmd_status__"; }
cmd_set_threshold() { echo "__CALL_cmd_set_threshold__"; }
cmd_set_rate() { echo "__CALL_cmd_set_rate__"; }
cmd_check_now() { echo "__CALL_cmd_check_now__"; }
cmd_remove_limit() { echo "__CALL_cmd_remove_limit__"; }
cmd_pause() { echo "__CALL_cmd_pause__"; }
cmd_resume() { echo "__CALL_cmd_resume__"; }
cmd_update_module() { echo "__CALL_cmd_update_module__"; }
cmd_uninstall() { echo "__CALL_cmd_uninstall__"; }
read_tty() {
  local prompt="" __var
  while [[ $# -gt 0 ]]; do
    case $1 in
      -p) prompt=$2; shift 2 ;;
      -r) shift ;;
      *) break ;;
    esac
  done
  __var=${1:-REPLY}
  # shellcheck disable=SC2034
  read -r "$__var" || return 1
}

# set -e 下 main_menu 完整渲染（选 0 退出）
set +e
menu_out=$(printf '0\n' | main_menu 2>&1)
menu_rc=$?
set -e
assert "traffic menu exit 0" '[[ $menu_rc -eq 0 ]]'
assert "traffic menu has 1..11" '
  [[ "$menu_out" == *"安装流量监控"* ]] &&
  [[ "$menu_out" == *"设置每月流量额度"* ]] &&
  [[ "$menu_out" == *"查看状态"* ]] &&
  [[ "$menu_out" == *"修改触发比例"* ]] &&
  [[ "$menu_out" == *"修改限速速度"* ]] &&
  [[ "$menu_out" == *"立即检查"* ]] &&
  [[ "$menu_out" == *"解除当前限速"* ]] &&
  [[ "$menu_out" == *"暂停自动检查"* ]] &&
  [[ "$menu_out" == *"恢复自动检查"* ]] &&
  [[ "$menu_out" == *"更新流量模块"* ]] &&
  [[ "$menu_out" == *"卸载流量模块"* ]] &&
  [[ "$menu_out" == *"返回"* ]]
'
assert "traffic menu numbers present" '
  [[ "$menu_out" == *" 1 "* ]] && [[ "$menu_out" == *" 2 "* ]] &&
  [[ "$menu_out" == *" 3 "* ]] && [[ "$menu_out" == *"10"* ]] &&
  [[ "$menu_out" == *"11"* ]] && [[ "$menu_out" == *" 0 "* ]]
'
assert "no group 监控" '! grep -qE "^[[:space:]]*监控[[:space:]]*$" <<<"$menu_out"'
assert "no group 策略" '! grep -qE "^[[:space:]]*策略[[:space:]]*$" <<<"$menu_out"'
assert "no group 运维" '! grep -qE "^[[:space:]]*运维[[:space:]]*$" <<<"$menu_out"'
assert "no group 系统" '! grep -qE "^[[:space:]]*系统[[:space:]]*$" <<<"$menu_out"'
has_box=0
for ch in ╭ ╮ ╰ ╯ │ ├ ┤ ─ ▸; do
  [[ "$menu_out" == *"$ch"* ]] && has_box=1 && break
done
assert "no box chars" '[[ $has_box -eq 0 ]]'
assert "prompt [0-11]" '[[ "$menu_out" == *"请选择 [0-11]"* ]]'
assert "version head" '[[ "$menu_out" == *"v${VERSION}"* ]]'

out10=$(printf '10\n\n0\n' | main_menu 2>&1) || true
assert "case 10 update" '[[ "$out10" == *"__CALL_cmd_update_module__"* ]]'
assert "case 10 not uninstall" '[[ "$out10" != *"__CALL_cmd_uninstall__"* ]]'

out11=$(printf '11\n' | main_menu 2>&1) || true
assert "case 11 uninstall" '[[ "$out11" == *"__CALL_cmd_uninstall__"* ]]'
assert "case 11 not update" '[[ "$out11" != *"__CALL_cmd_update_module__"* ]]'

out0=$(printf '0\n' | main_menu 2>&1) || true
assert "case 0 return" '[[ "$out0" != *__CALL_* ]]'

set +e
out_empty=$(printf '\n' | main_menu 2>&1)
rc_empty=$?
set -e
assert "empty input no crash" '[[ $rc_empty -eq 0 ]]'
assert "empty input no cmd" '[[ "$out_empty" != *__CALL_* ]]'

# 确认 ui_group 已从 traffic.sh 删除
assert "no ui_group def" '! grep -qE "^ui_group\\(\\)" "$ROOT/traffic.sh"'
assert "no ui_group call" '! grep -qE "ui_group " "$ROOT/traffic.sh"'

echo ""
echo "PASS=$pass FAIL=$fail"
[[ $fail -eq 0 ]]
