#!/usr/bin/env bash
# proxy 主菜单显示与 case 映射回归（不触碰真实服务）
set -Eeuo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
PROXY="$ROOT/proxy.sh"

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

# shellcheck source=../proxy.sh
source "$PROXY"

clear() { :; }
show_info() { :; }
pause() { :; }
install_v2() { echo "__CALL_install_v2__"; }
menu_uninstall() { echo "__CALL_menu_uninstall__"; }
menu_install() { echo "__CALL_menu_install__"; }

out=$(printf '0\n' | main_menu 2>&1) || true
assert "has 安装代理" '[[ "$out" == *"安装代理"* ]]'
assert "has 节点与状态" '[[ "$out" == *"节点与状态"* ]]'
assert "item3 is v2" '[[ "$out" == *"安装 / 更新 v2"* ]]'
assert "item4 is 卸载" '[[ "$out" == *"卸载"* ]]'
assert "no group 管理" '! grep -qE "^[[:space:]]*管理[[:space:]]*$" <<<"$out"'
assert "no group 系统" '! grep -qE "^[[:space:]]*系统[[:space:]]*$" <<<"$out"'
has_box=0
for ch in ╭ ╮ ╰ ╯ │ ├ ┤ ─ ▸; do
  [[ "$out" == *"$ch"* ]] && has_box=1 && break
done
assert "no box chars" '[[ $has_box -eq 0 ]]'
assert "prompt present" '[[ "$out" == *"请选择 [0-4]"* ]]'

out3=$(printf '3\n0\n' | main_menu 2>&1) || true
assert "case 3 install_v2" '[[ "$out3" == *"__CALL_install_v2__"* ]]'
assert "case 3 not uninstall" '[[ "$out3" != *"__CALL_menu_uninstall__"* ]]'

out4=$(printf '4\n0\n' | main_menu 2>&1) || true
assert "case 4 menu_uninstall" '[[ "$out4" == *"__CALL_menu_uninstall__"* ]]'
assert "case 4 not install_v2" '[[ "$out4" != *"__CALL_install_v2__"* ]]'

outb=$(printf '9\n0\n' | main_menu 2>&1) || true
assert "invalid keeps running" '[[ "$outb" == *"安装代理"* ]]'

echo ""
echo "PASS=$pass FAIL=$fail"
[[ $fail -eq 0 ]]
