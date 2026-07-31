#!/usr/bin/env bash
# traffic 扁平主菜单显示与 case 映射 / ui_item set -e 回归（mock，不触碰真实 tc）
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

# 1) set -e：连续打印全部菜单项（含 danger/muted）不得退出
set +e
ui_out=$(
  set -Eeuo pipefail
  ui_item 1 "安装流量监控"
  ui_item 2 "设置每月流量额度"
  ui_item 3 "查看状态"
  ui_item 4 "修改触发比例"
  ui_item 5 "修改限速速度"
  ui_item 6 "立即检查"
  ui_item 7 "解除当前限速"
  ui_item 8 "暂停自动检查"
  ui_item 9 "恢复自动检查"
  ui_item 10 "更新流量模块"
  ui_item 11 "卸载流量模块" danger
  ui_item 0 "返回" muted
  printf 'SURVIVED\n'
) 2>&1
ui_rc=$?
set -e
assert "ui_item multi exit 0" '[[ $ui_rc -eq 0 ]]'
assert "ui_item multi survived" '[[ "$ui_out" == *SURVIVED* ]]'

# stub 业务，只验证菜单路由
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

# 2) 完整扁平菜单 1–11 与 0
out=$(printf '0\n' | main_menu 2>&1) || true
assert "menu has item1" '[[ "$out" == *"安装流量监控"* ]]'
assert "menu has item2" '[[ "$out" == *"设置每月流量额度"* ]]'
assert "menu has item3" '[[ "$out" == *"查看状态"* ]]'
assert "menu has item4" '[[ "$out" == *"修改触发比例"* ]]'
assert "menu has item5" '[[ "$out" == *"修改限速速度"* ]]'
assert "menu has item6" '[[ "$out" == *"立即检查"* ]]'
assert "menu has item7" '[[ "$out" == *"解除当前限速"* ]]'
assert "menu has item8" '[[ "$out" == *"暂停自动检查"* ]]'
assert "menu has item9" '[[ "$out" == *"恢复自动检查"* ]]'
assert "menu has item10" '[[ "$out" == *"更新流量模块"* ]]'
assert "menu has item11" '[[ "$out" == *"卸载流量模块"* ]]'
assert "menu has item0" '[[ "$out" == *"返回"* ]]'
assert "menu shows all numbers" '[[ "$out" == *" 1 "* && "$out" == *" 11 "* && "$out" == *" 0 "* ]]'
assert "prompt 0-11" '[[ "$out" == *"请选择 [0-11]"* ]]'
assert "no group 监控" '! grep -qE "^[[:space:]]*监控[[:space:]]*$" <<<"$out"'
assert "no group 策略" '! grep -qE "^[[:space:]]*策略[[:space:]]*$" <<<"$out"'
assert "no group 运维" '! grep -qE "^[[:space:]]*运维[[:space:]]*$" <<<"$out"'
assert "no group 系统" '! grep -qE "^[[:space:]]*系统[[:space:]]*$" <<<"$out"'
has_box=0
for ch in ╭ ╮ ╰ ╯ │ ├ ┤ ─ ▸; do
  [[ "$out" == *"$ch"* ]] && has_box=1 && break
done
assert "no box chars" '[[ $has_box -eq 0 ]]'

# 3) 输入 1–11 进入对应操作；0 干净返回
for n in 1 2 3 4 5 6 7 8 9 10 11; do
  case $n in
    1) expect=__CALL_cmd_install__ ;;
    2) expect=__CALL_cmd_set_quota__ ;;
    3) expect=__CALL_cmd_status__ ;;
    4) expect=__CALL_cmd_set_threshold__ ;;
    5) expect=__CALL_cmd_set_rate__ ;;
    6) expect=__CALL_cmd_check_now__ ;;
    7) expect=__CALL_cmd_remove_limit__ ;;
    8) expect=__CALL_cmd_pause__ ;;
    9) expect=__CALL_cmd_resume__ ;;
    10) expect=__CALL_cmd_update_module__ ;;
    11) expect=__CALL_cmd_uninstall__ ;;
  esac
  if [[ $n == 11 ]]; then
    mout=$(printf '%s\n' "$n" | main_menu 2>&1) || true
  else
    mout=$(printf '%s\n\n0\n' "$n" | main_menu 2>&1) || true
  fi
  assert "case $n routes" '[[ "$mout" == *"$expect"* ]]'
done

out0=$(printf '0\n' | main_menu 2>&1) || true
assert "case 0 no cmd call" '[[ "$out0" != *__CALL_* ]]'

# 4) 空输入：与 0 一致返回，不异常退出
set +e
out_empty=$(printf '\n' | main_menu 2>&1)
rc_empty=$?
set -e
assert "empty input exit 0" '[[ $rc_empty -eq 0 ]]'
assert "empty input no cmd call" '[[ "$out_empty" != *__CALL_* ]]'

echo ""
echo "PASS=$pass FAIL=$fail"
[[ $fail -eq 0 ]]
