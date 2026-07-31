#!/usr/bin/env bash
# vps 主菜单 / read_tty 回归（无 root、不写系统路径）
set -Eeuo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
VPS="$ROOT/vps.sh"

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
source "$VPS"

# 1) 管道 stdin：read_tty 回退读管道
got=$(printf '2\n' | { read_tty -p "" REPLY; printf '%s' "$REPLY"; })
assert "read_tty pipe input" '[[ "$got" == "2" ]]'

# 2) 管道驱动 main_menu，选 0 退出
out=$(printf '0\n' | main_menu 2>&1) || true
assert "menu shows 代理管理" '[[ "$out" == *"代理管理"* ]]'
assert "menu shows 流量管理" '[[ "$out" == *"流量管理"* ]]'
assert "no REALITY subtitle" '[[ "$out" != *"REALITY · HY2 · CDN"* ]]'
assert "no traffic subtitle" '[[ "$out" != *"额度 · 限速 · 检查"* ]]'
assert "shows exit" '[[ "$out" == *"退出"* ]]'

echo ""
echo "PASS=$pass FAIL=$fail"
[[ $fail -eq 0 ]]
