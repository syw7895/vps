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
menu_uninstall() { echo "__CALL_menu_uninstall__"; }
menu_install() { echo "__CALL_menu_install__"; }
update_proxy_cores() { echo "__CALL_update_proxy_cores__"; }
out=$(printf '0\n' | main_menu 2>&1) || true
assert "has 安装代理" '[[ "$out" == *"安装代理"* ]]'
assert "has 节点与状态" '[[ "$out" == *"节点与状态"* ]]'
assert "item3 is proxy core update" '[[ "$out" == *"更新代理核心"* ]]'
assert "item4 is 卸载" '[[ "$out" == *"卸载"* ]]'
assert "no v2 menu" '[[ "$out" != *"安装 / 更新 v2"* && "$out" != *"更新 v2"* ]]'
assert "ws tls menu label" 'grep -q "VLESS + WS + TLS" "$PROXY"'
assert "ws direct menu item" 'grep -q "VLESS + WS + TLS（直连）" "$PROXY"'
assert "no cloudflare mode code" '! grep -qE "Cloudflare (CDN|模式)|cloudflare\\)|cdn\\|cf|--mode" "$PROXY"'
assert "install menu range stops at 3" 'grep -q "请选择 \[0-3\]" "$PROXY"'
assert "ws random port prompt" 'grep -q "输入 random=随机" "$PROXY"'
assert "direct port keep or random" 'grep -q "TLS 端口（空=保持或随机；输入 random=随机）" "$PROXY"'
assert "ws pick port helper" 'grep -q "^ws_pick_port()" "$PROXY"'
assert "domain prompt has no old default" 'grep -q "域名（空=IP 直连" "$PROXY"'
assert "direct uses domain without address prompt" '! grep -q "直连地址（空=域名）" "$PROXY" && grep -q "@\${WS_DOMAIN}:" "$PROXY"'
assert "ip direct allowInsecure" 'grep -q "allowInsecure=1" "$PROXY"'
assert "ip direct selfsigned helper" 'grep -q "^issue_selfsigned_ws_cert()" "$PROXY"'
assert "xray temp keeps json suffix" 'grep -q "mktemp \"\${dest}.tmp.XXXXXX.json\"" "$PROXY"'
assert "ws random port cli" 'grep -q -- "--random-port" "$PROXY"'
assert "no ws mode flag" '! grep -q -- "--mode" "$PROXY"'
assert "uninstall no persistent archive" '! grep -qE "backup_paths (reality-rm|cdn-rm|hy2-rm)" "$PROXY"'
assert "no node tar backup" '! grep -q "^backup_paths()" "$PROXY" && ! grep -q "已备份" "$PROXY"'
assert "legacy cdn state migrator" 'grep -q "^migrate_legacy_cdn_state()" "$PROXY"'
assert "no CDN_ state keys" '! grep -qE "CDN_(PORT|UUID|DOMAIN|PATH|STATE|INFO|CERT|KEY|SNI|ADDR|EMAIL)=" "$PROXY"'
assert "no parse_cdn_args" '! grep -q "^parse_cdn_args()" "$PROXY"'
assert "no group 管理" '! grep -qE "^[[:space:]]*管理[[:space:]]*$" <<<"$out"'
assert "no group 系统" '! grep -qE "^[[:space:]]*系统[[:space:]]*$" <<<"$out"'
has_box=0
for ch in ╭ ╮ ╰ ╯ │ ├ ┤ ─ ▸; do
  [[ "$out" == *"$ch"* ]] && has_box=1 && break
done
assert "no box chars" '[[ $has_box -eq 0 ]]'
assert "prompt present" '[[ "$out" == *"请选择 [0-4]"* ]]'

out3=$(printf '3\n0\n' | main_menu 2>&1) || true
assert "case 3 update proxy cores" '[[ "$out3" == *"__CALL_update_proxy_cores__"* ]]'

out4=$(printf '4\n0\n' | main_menu 2>&1) || true
assert "case 4 menu_uninstall" '[[ "$out4" == *"__CALL_menu_uninstall__"* ]]'
assert "case 4 not install" '[[ "$out4" != *"__CALL_menu_install__"* ]]'

out1=$(printf '1\n0\n' | main_menu 2>&1) || true
assert "case 1 menu_install" '[[ "$out1" == *"__CALL_menu_install__"* ]]'

outb=$(printf '9\n0\n' | main_menu 2>&1) || true
assert "invalid keeps running" '[[ "$outb" == *"安装代理"* ]]'

# 无 v2 CLI 路由
assert "no install-shortcut route" '! grep -qE "install-shortcut|uninstall-v2|install_v2|auto_v2" "$PROXY" || ! grep -qE "^\s*(install-shortcut|uninstall-v2)\|" "$PROXY"'
assert "no V2_ vars" '! grep -qE "^V2_(DIR|SCRIPT|BIN|SCRIPT_URL|SCRIPT_SHA256)=" "$PROXY"'
assert "no cleanup_legacy_v2" '! grep -q "cleanup_legacy_v2" "$PROXY"'
assert "no legacy v2 paths" '! grep -q "_LEGACY_V2_" "$PROXY"'

echo ""
echo "PASS=$pass FAIL=$fail"
[[ $fail -eq 0 ]]
