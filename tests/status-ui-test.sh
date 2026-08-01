#!/usr/bin/env bash
# 状态展示回归：VPS 警告 / 代理节点识别（真实配置优先）/ 流量状态
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

no_box() {
  local s=$1 ch
  for ch in ╭ ╮ ╰ ╯ │ ├ ┤ ─ ▸; do
    [[ "$s" == *"$ch"* ]] && return 1
  done
  [[ "$s" == *"···············"* ]] && return 1
  return 0
}

write_xray_cfg() {
  local path=$1
  shift
  local tags=("$@") t parts=() ib
  for t in "${tags[@]}"; do
    case $t in
      reality)
        # 含协议语义 + 可选 tag（兼容新旧）
        parts+=('{ "tag": "vless-reality", "listen": "0.0.0.0", "port": 443, "protocol": "vless", "streamSettings": { "network": "tcp", "security": "reality" } }')
        ;;
      reality_notag)
        # 旧节点：无固定 tag，仅协议语义
        parts+=('{ "listen": "0.0.0.0", "port": 443, "protocol": "vless", "streamSettings": { "network": "tcp", "security": "reality" } }')
        ;;
      cdn)
        parts+=('{ "tag": "vless-ws-tls", "listen": "0.0.0.0", "port": 8443, "protocol": "vless", "streamSettings": { "network": "ws", "security": "tls" } }')
        ;;
      cdn_notag)
        parts+=('{ "listen": "0.0.0.0", "port": 8443, "protocol": "vless", "streamSettings": { "network": "ws", "security": "tls" } }')
        ;;
    esac
  done
  ib=$(IFS=,; echo "${parts[*]}")
  cat >"$path" <<EOF
{ "inbounds": [ ${ib} ], "outbounds": [] }
EOF
}

write_hy2_cfg() {
  local path=$1 port=${2:-55479}
  cat >"$path" <<EOF
listen: :${port}
tls:
  cert: /tmp/c.crt
  key: /tmp/c.key
auth:
  type: password
  password: secret
EOF
}

# ===================== VPS =====================
# shellcheck source=../vps.sh
source "$ROOT/vps.sh"

PROXY_SH_LOCAL="$TMP/proxy-ok.sh"
TRAFFIC_SH_LOCAL="$TMP/traffic-ok.sh"
printf '#!/usr/bin/env bash\ntrue\n' >"$PROXY_SH_LOCAL"
printf '#!/usr/bin/env bash\ntrue\n' >"$TRAFFIC_SH_LOCAL"

w=$(entry_warning_line || true)
assert "vps both ok empty" '[[ -z "$w" ]]'
assert "vps no 模块就绪" '[[ "$w" != *"模块就绪"* ]]'

printf '#!/usr/bin/env bash\nif [\n' >"$PROXY_SH_LOCAL"
w=$(entry_warning_line || true)
assert "vps proxy syntax warn" '[[ "$w" == *"代理模块不可用"* ]]'

printf '#!/usr/bin/env bash\ntrue\n' >"$PROXY_SH_LOCAL"
rm -f "$TRAFFIC_SH_LOCAL"
w=$(entry_warning_line || true)
assert "vps traffic missing warn" '[[ "$w" == *"流量模块不可用"* ]]'

rm -f "$PROXY_SH_LOCAL" "$TRAFFIC_SH_LOCAL"
w=$(entry_warning_line || true)
assert "vps both bad red" '[[ "$w" == *"功能模块不可用"* ]]'

PROXY_SH_LOCAL="$TMP/proxy-ok.sh"
TRAFFIC_SH_LOCAL="$TMP/traffic-ok.sh"
printf '#!/usr/bin/env bash\ntrue\n' >"$PROXY_SH_LOCAL"
printf '#!/usr/bin/env bash\ntrue\n' >"$TRAFFIC_SH_LOCAL"
mout=$(printf '0\n' | main_menu 2>&1) || true
assert "vps menu no 模块就绪" '[[ "$mout" != *"模块就绪"* ]]'
assert "vps menu has items" '[[ "$mout" == *"代理管理"* && "$mout" == *"流量管理"* ]]'
assert "vps menu no box" 'no_box "$mout"'

# ===================== proxy =====================
# shellcheck source=../proxy.sh
source "$ROOT/proxy.sh"

CONFIG_DIR="$TMP/proxy-cfg"
mkdir -p "$CONFIG_DIR" "$TMP/xray" "$TMP/hy2"
REALITY_STATE="$CONFIG_DIR/reality.conf"
CDN_STATE="$CONFIG_DIR/cdn.conf"
HY2_STATE="$CONFIG_DIR/hy2.conf"
XRAY_INFO="$CONFIG_DIR/xray-reality.txt"
CDN_INFO="$CONFIG_DIR/xray-cdn.txt"
HY2_INFO="$CONFIG_DIR/hysteria2.txt"
XRAY_CONFIG="$TMP/xray/config.json"
HY2_CONFIG="$TMP/hy2/config.yaml"

svc_state() {
  local unit=$1
  case ${MOCK_SVC[$unit]:-missing} in
    running|stopped|missing) printf '%s\n' "${MOCK_SVC[$unit]}" ;;
    *) printf 'missing\n' ;;
  esac
}
declare -A MOCK_SVC=()

clear_proxy() {
  rm -f "$REALITY_STATE" "$CDN_STATE" "$HY2_STATE" "$XRAY_INFO" "$CDN_INFO" "$HY2_INFO" \
    "$XRAY_CONFIG" "$HY2_CONFIG"
  MOCK_SVC=()
}

# 9) 完全没有节点
clear_proxy
line=$(proxy_status_line)
assert "proxy none status" '[[ "$line" == *"暂无代理"* ]]'
out=$(show_info 2>&1)
assert "proxy none page" '[[ "$out" == *"暂无代理"* && "$out" == *"节点与状态"* ]]'
assert "proxy none no 未安装" '[[ "$out" != *"未安装"* ]]'
assert "proxy none no 服务状态" '[[ "$out" != *"服务状态"* ]]'
assert "proxy none no hr" 'no_box "$out"'

# 1) REALITY 配置 + info，无 state（旧版兼容）
clear_proxy
write_xray_cfg "$XRAY_CONFIG" reality
printf '地址:      1.2.3.4\n端口:      443\nUUID:      u1\nSNI:       sni.example\n分享链接:\nvless://u1@1.2.3.4:443\n' >"$XRAY_INFO"
MOCK_SVC[xray]=running
out=$(show_info 2>&1)
assert "legacy reality shown" '[[ "$out" == *"REALITY"* && "$out" == *"运行中"* && "$out" == *":443"* ]]'
assert "legacy reality meta warn" '[[ "$out" == *"状态元数据缺失"* ]]'
assert "legacy reality not residual" '[[ "$out" != *"残留信息文件"* ]]'
assert "legacy reality not 暂无" '[[ "$out" != *"暂无代理"* ]]'
assert "legacy reality not 未安装" '[[ "$out" != *"未安装"* ]]'
assert "legacy reality fields" '[[ "$out" == *"1.2.3.4"* && "$out" == *"u1"* ]]'
line=$(proxy_status_line)
assert "legacy reality status run" '[[ "$line" == *"代理运行中"* ]]'

# 2) Hysteria2 配置 + info，无 state
clear_proxy
write_hy2_cfg "$HY2_CONFIG" 55479
printf '地址:     9.9.9.9\n端口:     55479\n密码:     p\nSNI:      hy.example\n分享链接:\nhysteria2://p@9.9.9.9:55479\n' >"$HY2_INFO"
MOCK_SVC[hysteria-server]=running
out=$(show_info 2>&1)
assert "legacy hy2 shown" '[[ "$out" == *"Hysteria2"* && "$out" == *"运行中"* && "$out" == *":55479"* ]]'
assert "legacy hy2 meta warn" '[[ "$out" == *"状态元数据缺失"* ]]'
assert "legacy hy2 not residual" '[[ "$out" != *"残留信息文件"* ]]'
assert "legacy hy2 not 暂无" '[[ "$out" != *"暂无代理"* ]]'

# 3) 仅 info 残留
clear_proxy
printf '地址: 1.2.3.4\n' >"$XRAY_INFO"
out=$(show_info 2>&1)
assert "residual reality warn" '[[ "$out" == *"REALITY 残留信息文件"* || "$out" == *"残留信息文件"* ]]'
assert "residual no 暂无" '[[ "$out" != *"暂无代理"* ]]'
assert "residual no 运行中" '[[ "$out" != *"运行中"* ]]'
assert "residual no 未安装" '[[ "$out" != *"未安装"* ]]'

# 4) state 存在、真实配置缺失
clear_proxy
printf 'REALITY_PORT=443\n' >"$REALITY_STATE"
MOCK_SVC[xray]=running
out=$(show_info 2>&1)
assert "state no cfg 配置缺失" '[[ "$out" == *"配置缺失"* && "$out" == *"REALITY"* ]]'
assert "state no cfg 未找到" '[[ "$out" == *"服务配置中未找到该节点"* ]]'
assert "state no cfg not 运行中" '[[ "$out" != *"运行中"* ]]'
assert "state no cfg not 暂无" '[[ "$out" != *"暂无代理"* ]]'
assert "state no cfg no link" '[[ "$out" != *"vless://"* && "$out" != *"分享链接"* ]]'
line=$(proxy_status_line)
assert "state no cfg status bad" '[[ "$line" == *"配置异常"* || "$line" == *"代理已停止"* || "$line" == *"暂无"* || "$line" == *"配置"* ]]'

# 5) 配置 + state + info 完整
clear_proxy
write_xray_cfg "$XRAY_CONFIG" reality
printf 'REALITY_PORT=443\n' >"$REALITY_STATE"
printf '地址:      1.2.3.4\n端口:      443\nUUID:      u1\n' >"$XRAY_INFO"
MOCK_SVC[xray]=running
out=$(show_info 2>&1)
assert "full reality ok" '[[ "$out" == *"运行中"* && "$out" == *"u1"* ]]'
assert "full no meta warn" '[[ "$out" != *"状态元数据缺失"* ]]'
assert "full no residual" '[[ "$out" != *"残留"* ]]'
assert "full no 暂无" '[[ "$out" != *"暂无代理"* ]]'

# 6) 配置存在、info 缺失
clear_proxy
write_xray_cfg "$XRAY_CONFIG" reality
printf 'REALITY_PORT=443\n' >"$REALITY_STATE"
MOCK_SVC[xray]=running
out=$(show_info 2>&1)
assert "no info warn" '[[ "$out" == *"节点信息缺失"* && "$out" == *"REALITY"* ]]'
assert "no info still port" '[[ "$out" == *":443"* ]]'

# 7) 运行 / 停止 / 程序缺失
clear_proxy
write_xray_cfg "$XRAY_CONFIG" reality
printf 'REALITY_PORT=443\n' >"$REALITY_STATE"
printf '地址: 1.1.1.1\n' >"$XRAY_INFO"
MOCK_SVC[xray]=stopped
out=$(show_info 2>&1)
assert "stopped title" '[[ "$out" == *"已停止"* ]]'
MOCK_SVC[xray]=missing
out=$(show_info 2>&1)
assert "missing bin 异常" '[[ "$out" == *"异常"* ]]'

# 8) REALITY + CDN 共用 xray
clear_proxy
write_xray_cfg "$XRAY_CONFIG" reality cdn
printf 'REALITY_PORT=443\n' >"$REALITY_STATE"
printf 'CDN_PORT=8443\n' >"$CDN_STATE"
printf '地址: 1.2.3.4\n' >"$XRAY_INFO"
printf '域名: example.com\n' >"$CDN_INFO"
MOCK_SVC[xray]=running
line=$(proxy_status_line)
assert "reality+cdn one xray" '[[ "$line" == *"代理运行中"* ]]'
assert "not partial single xray" '[[ "$line" != *"部分服务停止"* ]]'
out=$(show_info 2>&1)
assert "both components" '[[ "$out" == *"REALITY"* && "$out" == *"CDN"* ]]'
assert "no 未安装 list" '[[ "$out" != *"未安装"* ]]'
assert "no 服务状态 section" '[[ "$out" != *"服务状态"* ]]'

# 部分停止：xray 运行 + hy2 停
write_hy2_cfg "$HY2_CONFIG" 40000
printf 'HY2_PORT=40000\n' >"$HY2_STATE"
printf '密码: x\n' >"$HY2_INFO"
MOCK_SVC[hysteria-server]=stopped
line=$(proxy_status_line)
assert "partial stop" '[[ "$line" == *"部分服务停止"* ]]'

# 全部停止
MOCK_SVC[xray]=stopped
MOCK_SVC[hysteria-server]=stopped
line=$(proxy_status_line)
assert "all stopped" '[[ "$line" == *"代理已停止"* ]]'
assert "stopped not 暂无" '[[ "$line" != *"暂无代理"* ]]'

# 只有 CDN 配置
clear_proxy
write_xray_cfg "$XRAY_CONFIG" cdn
printf 'CDN_PORT=8443\n' >"$CDN_STATE"
printf '域名: d.com\n' >"$CDN_INFO"
MOCK_SVC[xray]=running
out=$(show_info 2>&1)
assert "only cdn" '[[ "$out" == *"CDN"* && "$out" != *"REALITY"* && "$out" != *"Hysteria2"* ]]'

# 有真实配置时绝不暂无（即使无 state）
clear_proxy
write_xray_cfg "$XRAY_CONFIG" reality
MOCK_SVC[xray]=running
out=$(show_info 2>&1)
assert "cfg only not 暂无" '[[ "$out" != *"暂无代理"* && "$out" == *"REALITY"* ]]'

# 无固定 tag、仅协议语义的旧 REALITY
clear_proxy
write_xray_cfg "$XRAY_CONFIG" reality_notag
printf '地址:      8.8.8.8\n端口:      443\n' >"$XRAY_INFO"
MOCK_SVC[xray]=running
out=$(show_info 2>&1)
assert "semantic reality no tag" '[[ "$out" == *"REALITY"* && "$out" == *"运行中"* && "$out" != *"残留"* && "$out" != *"暂无代理"* ]]'
assert "semantic reality port" '[[ "$out" == *":443"* ]]'

# 无固定 tag 的 CDN 语义
clear_proxy
write_xray_cfg "$XRAY_CONFIG" cdn_notag
printf '域名: d.com\n端口: 8443\n' >"$CDN_INFO"
MOCK_SVC[xray]=running
out=$(show_info 2>&1)
assert "semantic cdn no tag" '[[ "$out" == *"CDN"* && "$out" == *"运行中"* && "$out" != *"REALITY"* ]]'
assert "semantic cdn not 暂无" '[[ "$out" != *"暂无代理"* ]]'

# 仅 Xray 运行但无匹配 inbound → 不因 systemd 判为有节点
clear_proxy
printf '{ "inbounds": [ { "protocol": "socks", "port": 1080 } ], "outbounds": [] }\n' >"$XRAY_CONFIG"
MOCK_SVC[xray]=running
out=$(show_info 2>&1)
assert "running xray no inbound 暂无" '[[ "$out" == *"暂无代理"* ]]'
assert "running xray no reality block" '[[ "$out" != *"REALITY"* || "$out" == *"残留"* ]]'

# ---------- show_info 返回码 / 缺组件不中断（set -Eeuo + ERR trap）----------
run_show_info_with_err_trap() {
  # 在子 shell 中启用与正式脚本相同的 ERR 语义
  (
    set -Eeuo pipefail
    trap 'rc=$?; printf "[ERR] 脚本第 %s 行失败 (exit %s)\n" "$LINENO" "$rc" >&2; exit "$rc"' ERR
    show_info
  ) 2>&1
}

# 只有 REALITY、没有 CDN
clear_proxy
write_xray_cfg "$XRAY_CONFIG" reality
printf '地址: 1.1.1.1\n端口: 443\n' >"$XRAY_INFO"
MOCK_SVC[xray]=running
out=$(run_show_info_with_err_trap) || true
assert "only reality no ERR" '[[ "$out" != *"[ERR]"* ]]'
assert "only reality shown" '[[ "$out" == *"REALITY"* && "$out" == *"运行中"* ]]'
assert "only reality no CDN" '[[ "$out" != *"CDN"* ]]'
assert "only reality no HY2" '[[ "$out" != *"Hysteria2"* ]]'
assert "only reality not 暂无" '[[ "$out" != *"暂无代理"* ]]'

# REALITY + Hysteria2，没有 CDN（关键：CDN 缺失不得跳过 HY2）
clear_proxy
write_xray_cfg "$XRAY_CONFIG" reality
write_hy2_cfg "$HY2_CONFIG" 55479
printf '地址: 1.1.1.1\n端口: 443\n' >"$XRAY_INFO"
printf '地址: 1.1.1.1\n端口: 55479\n' >"$HY2_INFO"
MOCK_SVC[xray]=running
MOCK_SVC[hysteria-server]=running
out=$(run_show_info_with_err_trap) || true
assert "reality+hy2 no ERR" '[[ "$out" != *"[ERR]"* ]]'
assert "reality+hy2 both" '[[ "$out" == *"REALITY"* && "$out" == *"Hysteria2"* ]]'
assert "reality+hy2 no CDN block" '[[ "$out" != *"CDN / WS"* && "$out" != *"未安装"* ]]'
assert "reality+hy2 not 暂无" '[[ "$out" != *"暂无代理"* ]]'
assert "reality+hy2 hy2 not skipped" '[[ "$out" == *"Hysteria2"* && "$out" == *"运行中"* ]]'

# 只有 Hysteria2
clear_proxy
write_hy2_cfg "$HY2_CONFIG" 40000
printf '地址: 2.2.2.2\n端口: 40000\n' >"$HY2_INFO"
MOCK_SVC[hysteria-server]=running
out=$(run_show_info_with_err_trap) || true
assert "only hy2 no ERR" '[[ "$out" != *"[ERR]"* ]]'
assert "only hy2 shown" '[[ "$out" == *"Hysteria2"* && "$out" != *"REALITY"* && "$out" != *"CDN"* ]]'

# 只有 CDN（已有 only cdn，再加 ERR trap）
clear_proxy
write_xray_cfg "$XRAY_CONFIG" cdn
printf '域名: d.com\n端口: 8443\n' >"$CDN_INFO"
MOCK_SVC[xray]=running
out=$(run_show_info_with_err_trap) || true
assert "only cdn no ERR" '[[ "$out" != *"[ERR]"* ]]'
assert "only cdn trap ok" '[[ "$out" == *"CDN"* && "$out" != *"REALITY"* && "$out" != *"Hysteria2"* ]]'

# 三个组件都不存在
clear_proxy
out=$(run_show_info_with_err_trap) || true
assert "none no ERR" '[[ "$out" != *"[ERR]"* ]]'
assert "none 暂无代理" '[[ "$out" == *"暂无代理"* ]]'

# 只有残留 info（REALITY）
clear_proxy
printf '地址: 9.9.9.9\n' >"$XRAY_INFO"
out=$(run_show_info_with_err_trap) || true
assert "residual no ERR" '[[ "$out" != *"[ERR]"* ]]'
assert "residual warn" '[[ "$out" == *"残留信息文件"* ]]'
assert "residual no 暂无" '[[ "$out" != *"暂无代理"* ]]'

# 未知返回码仍触发错误（mock show_component）
(
  set -Eeuo pipefail
  show_component() { return 99; }
  set +e
  out=$(_show_info_handle_component "X" a b c d e reality 2>&1)
  rc=$?
  set -e
  assert "unknown rc propagates" '[[ $rc -eq 99 ]]'
)

# show_info 在 set -Eeuo 下整页可完成（组合场景）
clear_proxy
write_xray_cfg "$XRAY_CONFIG" reality
write_hy2_cfg "$HY2_CONFIG" 11111
MOCK_SVC[xray]=running
MOCK_SVC[hysteria-server]=running
set +e
(
  set -Eeuo pipefail
  trap 'rc=$?; printf "[ERR] line=%s exit=%s\n" "$LINENO" "$rc" >&2; exit "$rc"' ERR
  show_info >/dev/null
)
rc_full=$?
set -e
assert "show_info under set -e exit 0" '[[ $rc_full -eq 0 ]]'

# ===================== traffic =====================
export VPS_TRAFFIC_MOCK=1
export VPS_TRAFFIC_TEST_DIR="$TMP/traffic"
export MOCK_IFACE=eth0
export MOCK_TX_BYTES=$((10 * 1000000000))
export MOCK_YEAR=$(date +%Y)
export MOCK_MONTH=$(date +%m)
mkdir -p "$VPS_TRAFFIC_TEST_DIR/etc" "$VPS_TRAFFIC_TEST_DIR/var" "$VPS_TRAFFIC_TEST_DIR/mock_tc"

# shellcheck source=../traffic.sh
source "$ROOT/traffic.sh"

write_cfg() {
  cat >"$VPS_TRAFFIC_TEST_DIR/etc/config" <<EOF
MONTHLY_QUOTA_GB=${1:-}
THRESHOLD_PERCENT=${2:-90}
LIMIT_RATE=${3:-1mbit}
IFACE=eth0
PAUSED=${4:-false}
EOF
}
write_st() {
  cat >"$VPS_TRAFFIC_TEST_DIR/var/state" <<EOF
LIMIT_ACTIVE=${1:-false}
LIMIT_IFACE=${2:-}
LIMIT_HANDLE=${3:-}
LAST_REASON=${4:-}
LAST_CHECK_TS=
LAST_TX_BYTES=
LAST_MONTH=
LAST_RATIO=
OWNED_BY_TOOL=${5:-false}
EOF
}

# 状态行用例先标记已安装
: >"$VPS_TRAFFIC_TEST_DIR/var/.installed"
write_cfg ""
write_st false "" "" "" false
: >"$VPS_TRAFFIC_TEST_DIR/mock_tc/eth0"
line=$(menu_status_line)
assert "traffic unset quota menu" '[[ "$line" == *"待设置额度"* ]]'
out=$(cmd_status 2>&1)
assert "traffic no legend phrase" '[[ "$out" != *"限速/超限"* ]]'
assert "traffic no handle default" '[[ "$out" != *"1abc"* && "$out" != *"规则"* ]]'
assert "traffic TX scope" '[[ "$out" == *"出站 TX"* ]]'
assert "traffic tip quota" '[[ "$out" == *"请先设置每月流量额度"* ]]'
assert "traffic no box" 'no_box "$out"'

write_cfg 100
write_st false "" "" ok_below_threshold false
line=$(menu_status_line)
assert "traffic normal menu" '[[ "$line" == *"正常运行"* || "$line" == *"正常放行"* ]]'

printf 'qdisc tbf 1abc: root refcnt 2 rate 1mbit\n' >"$VPS_TRAFFIC_TEST_DIR/mock_tc/eth0"
write_st true eth0 "1abc:" applied_limit true
line=$(menu_status_line)
assert "traffic limited menu" '[[ "$line" == *"限速中"* ]]'

write_st true eth0 "1abc:" applied_limit true
: >"$VPS_TRAFFIC_TEST_DIR/mock_tc/eth0"
line=$(menu_status_line)
assert "traffic mismatch menu" '[[ "$line" == *"状态需检查"* ]]'

# 菜单动态：未安装
rm -f "$VPS_TRAFFIC_TEST_DIR/var/.installed"
cmd_install() { echo "__CALL_install__"; }
cmd_status() { echo "__CALL_status__"; }
cmd_settings() { echo "__CALL_settings__"; }
cmd_check_now() { echo "__CALL_check__"; }
cmd_remove_limit() { echo "__CALL_remove__"; }
cmd_pause() { echo "__CALL_pause__"; }
cmd_resume() { echo "__CALL_resume__"; }
cmd_update_module() { echo "__CALL_update__"; }
cmd_uninstall() { echo "__CALL_uninstall__"; }
read_tty() {
  local __var
  while [[ $# -gt 0 ]]; do
    case $1 in -p) shift 2 ;; -r) shift ;; *) break ;; esac
  done
  __var=${1:-REPLY}
  # shellcheck disable=SC2034
  read -r "$__var" || return 1
}

out=$(printf '0\n' | main_menu 2>&1) || true
assert "traffic uninst only install" '[[ "$out" == *"安装流量监控"* && "$out" != *"修改流量设置"* && "$out" != *"更多操作"* ]]'
assert "traffic uninst 尚未安装" '[[ "$out" == *"尚未安装"* ]]'
assert "traffic menu no box" 'no_box "$out"'

# 菜单动态：已安装
: >"$VPS_TRAFFIC_TEST_DIR/var/.installed"
write_cfg 100
write_st false "" "" "" false
: >"$VPS_TRAFFIC_TEST_DIR/mock_tc/eth0"
out=$(printf '0\n' | main_menu 2>&1) || true
assert "traffic inst hide install" '[[ "$out" != *"安装流量监控"* ]]'
assert "traffic inst has settings" '[[ "$out" == *"修改流量设置"* && "$out" == *"查看状态"* && "$out" == *"立即检查"* && "$out" == *"更多操作"* ]]'
assert "traffic inst has pause" '[[ "$out" == *"暂停自动检查"* ]]'
assert "traffic inst no dual pause resume" '[[ "$out" != *"恢复自动检查"* ]]'
assert "traffic inst no remove on main" '[[ "$out" != *"解除当前限速"* ]]'
assert "traffic max ~5 items" '[[ $(echo "$out" | grep -cE "^[[:space:]]*[1-5][[:space:]]") -le 5 ]]'

out1=$(printf '1\n\n0\n' | main_menu 2>&1) || true
assert "traffic act status" '[[ "$out1" == *"__CALL_status__"* ]]'
out2=$(printf '2\n\n0\n' | main_menu 2>&1) || true
assert "traffic act settings" '[[ "$out2" == *"__CALL_settings__"* ]]'
out3=$(printf '3\n\n0\n' | main_menu 2>&1) || true
assert "traffic act check" '[[ "$out3" == *"__CALL_check__"* ]]'
out4=$(printf '4\n\n0\n' | main_menu 2>&1) || true
assert "traffic act pause" '[[ "$out4" == *"__CALL_pause__"* ]]'

# 限速中：解除在更多
write_st true eth0 "1abc:" applied_limit true
printf 'qdisc tbf 1abc: root\n' >"$VPS_TRAFFIC_TEST_DIR/mock_tc/eth0"
out=$(printf '0\n' | main_menu 2>&1) || true
assert "traffic limited pause still main" '[[ "$out" == *"暂停自动检查"* && "$out" != *"解除当前限速"* ]]'
outrm=$(printf '5\n1\n\n0\n0\n' | main_menu 2>&1) || true
assert "traffic more remove" '[[ "$outrm" == *"__CALL_remove__"* ]]'

# 更多 → 更新（非限速：1 更新 2 卸载）
write_st false "" "" "" false
: >"$VPS_TRAFFIC_TEST_DIR/mock_tc/eth0"
outm=$(printf '5\n1\n\n0\n0\n' | main_menu 2>&1) || true
assert "traffic more update" '[[ "$outm" == *"__CALL_update__"* ]]'
outu=$(printf '5\n2\n0\n' | main_menu 2>&1) || true
assert "traffic more uninstall" '[[ "$outu" == *"__CALL_uninstall__"* ]]'

# ui_item set -e
for f in vps.sh proxy.sh traffic.sh; do
  set +e
  uout=$(
    set -Eeuo pipefail
    if [[ $f == traffic.sh ]]; then
      export VPS_TRAFFIC_MOCK=1 VPS_TRAFFIC_TEST_DIR="$TMP/t2"
      mkdir -p "$VPS_TRAFFIC_TEST_DIR/etc" "$VPS_TRAFFIC_TEST_DIR/var" "$VPS_TRAFFIC_TEST_DIR/mock_tc"
    fi
    # shellcheck source=/dev/null
    source "$ROOT/$f"
    ui_item 1 "a"
    ui_item 0 "b" muted 2>/dev/null || ui_item 0 "b"
    printf SURVIVED
  ) 2>&1
  urc=$?
  set -e
  assert "$f ui_item set-e" '[[ $urc -eq 0 && "$uout" == *SURVIVED* ]]'
done

echo ""
echo "PASS=$pass FAIL=$fail"
[[ $fail -eq 0 ]]
