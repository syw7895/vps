#!/usr/bin/env bash
# 状态展示回归：VPS 警告行 / 代理节点页 / 流量状态页
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
  # 旧式圆点分隔线
  [[ "$s" == *"···············"* ]] && return 1
  return 0
}

# ===================== VPS entry_warning_line =====================
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

# 主菜单正常不显示模块就绪
PROXY_SH_LOCAL="$TMP/proxy-ok.sh"
TRAFFIC_SH_LOCAL="$TMP/traffic-ok.sh"
printf '#!/usr/bin/env bash\ntrue\n' >"$PROXY_SH_LOCAL"
printf '#!/usr/bin/env bash\ntrue\n' >"$TRAFFIC_SH_LOCAL"
mout=$(printf '0\n' | main_menu 2>&1) || true
assert "vps menu no 模块就绪" '[[ "$mout" != *"模块就绪"* ]]'
assert "vps menu has items" '[[ "$mout" == *"代理管理"* && "$mout" == *"流量管理"* ]]'
assert "vps menu prompt" '[[ "$mout" == *"请选择 [0-2]"* ]]'
assert "vps menu no box" 'no_box "$mout"'

# ===================== proxy status =====================
# shellcheck source=../proxy.sh
source "$ROOT/proxy.sh"

CONFIG_DIR="$TMP/proxy-cfg"
mkdir -p "$CONFIG_DIR"
REALITY_STATE="$CONFIG_DIR/reality.conf"
CDN_STATE="$CONFIG_DIR/cdn.conf"
HY2_STATE="$CONFIG_DIR/hy2.conf"
XRAY_INFO="$CONFIG_DIR/xray-reality.txt"
CDN_INFO="$CONFIG_DIR/xray-cdn.txt"
HY2_INFO="$CONFIG_DIR/hysteria2.txt"

# stub svc_state for deterministic tests
svc_state() {
  local unit=$1
  case ${MOCK_SVC[$unit]:-missing} in
    running|stopped|missing) printf '%s\n' "${MOCK_SVC[$unit]}" ;;
    *) printf 'missing\n' ;;
  esac
}
declare -A MOCK_SVC=()

# 无节点
rm -f "$REALITY_STATE" "$CDN_STATE" "$HY2_STATE" "$XRAY_INFO" "$CDN_INFO" "$HY2_INFO"
line=$(proxy_status_line)
assert "proxy none status" '[[ "$line" == *"暂无代理"* ]]'
out=$(show_info 2>&1)
assert "proxy none page" '[[ "$out" == *"暂无代理"* && "$out" == *"节点与状态"* ]]'
assert "proxy none no 未安装" '[[ "$out" != *"未安装"* ]]'
assert "proxy none no 服务状态" '[[ "$out" != *"服务状态"* ]]'
assert "proxy none no hr" 'no_box "$out"'

# 只有 REALITY 运行
printf 'REALITY_PORT=443\n' >"$REALITY_STATE"
printf '地址:      1.2.3.4\n端口:      443\nUUID:      u1\nSNI:       sni.example\n分享链接:\nvless://u1@1.2.3.4:443\n' >"$XRAY_INFO"
MOCK_SVC[xray]=running
line=$(proxy_status_line)
assert "proxy reality running status" '[[ "$line" == *"代理运行中"* ]]'
out=$(show_info 2>&1)
assert "proxy reality titled" '[[ "$out" == *"REALITY"* && "$out" == *"运行中"* && "$out" == *":443"* ]]'
assert "proxy reality fields" '[[ "$out" == *"1.2.3.4"* && "$out" == *"u1"* ]]'
assert "proxy reality no cdn block" '[[ "$out" != *"CDN"* || "$out" != *"未安装"* ]]'
assert "proxy reality no 未安装" '[[ "$out" != *"未安装"* ]]'

# REALITY + CDN 共用 xray 运行 → 仍「运行中」不是部分停止
printf 'CDN_PORT=8443\n' >"$CDN_STATE"
printf '域名:   example.com\n端口:   8443\n' >"$CDN_INFO"
MOCK_SVC[xray]=running
line=$(proxy_status_line)
assert "proxy reality+cdn one xray running" '[[ "$line" == *"代理运行中"* ]]'
assert "proxy not partial when only xray" '[[ "$line" != *"部分服务停止"* ]]'

# 全部停止
MOCK_SVC[xray]=stopped
line=$(proxy_status_line)
assert "proxy all stopped" '[[ "$line" == *"代理已停止"* ]]'
assert "proxy stopped not 暂无" '[[ "$line" != *"暂无代理"* ]]'
out=$(show_info 2>&1)
assert "proxy stopped in title" '[[ "$out" == *"已停止"* ]]'

# 部分停止：xray 运行 + hy2 停止
printf 'HY2_PORT=40000\n' >"$HY2_STATE"
printf '地址:     1.2.3.4\n端口:     40000\n密码:     p\n' >"$HY2_INFO"
MOCK_SVC[xray]=running
MOCK_SVC[hysteria-server]=stopped
line=$(proxy_status_line)
assert "proxy partial stop" '[[ "$line" == *"部分服务停止"* ]]'

# 配置异常
MOCK_SVC[xray]=missing
MOCK_SVC[hysteria-server]=missing
line=$(proxy_status_line)
assert "proxy config bad" '[[ "$line" == *"配置异常"* ]]'

# state 有、info 无
rm -f "$CDN_STATE" "$CDN_INFO" "$HY2_STATE" "$HY2_INFO" "$XRAY_INFO"
printf 'REALITY_PORT=443\n' >"$REALITY_STATE"
MOCK_SVC[xray]=running
out=$(show_info 2>&1)
assert "proxy missing info warn" '[[ "$out" == *"节点信息缺失"* && "$out" == *"REALITY"* ]]'
assert "proxy missing info still port" '[[ "$out" == *":443"* || "$out" == *"443"* ]]'

# info 有、state 无
rm -f "$REALITY_STATE"
printf '地址: 1.2.3.4\n' >"$XRAY_INFO"
out=$(show_info 2>&1)
assert "proxy residual info warn" '[[ "$out" == *"残留信息文件"* ]]'
assert "proxy residual 暂无代理" '[[ "$out" == *"暂无代理"* ]]'
assert "proxy residual no 运行中" '[[ "$out" != *"运行中"* ]]'
assert "proxy residual no 未安装" '[[ "$out" != *"未安装"* ]]'

# 只有 CDN
rm -f "$XRAY_INFO" "$REALITY_STATE" "$HY2_STATE" "$HY2_INFO"
printf 'CDN_PORT=8443\n' >"$CDN_STATE"
printf '域名:   d.com\n' >"$CDN_INFO"
MOCK_SVC[xray]=running
out=$(show_info 2>&1)
assert "proxy only cdn" '[[ "$out" == *"CDN"* && "$out" != *"REALITY"* && "$out" != *"Hysteria2"* ]]'
assert "proxy only cdn no 未安装" '[[ "$out" != *"未安装"* ]]'

# 只有 HY2
rm -f "$CDN_STATE" "$CDN_INFO"
printf 'HY2_PORT=1\n' >"$HY2_STATE"
printf '密码:     x\n' >"$HY2_INFO"
MOCK_SVC[hysteria-server]=running
out=$(show_info 2>&1)
assert "proxy only hy2" '[[ "$out" == *"Hysteria2"* && "$out" != *"未安装"* ]]'

# ===================== traffic status =====================
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

# 未设置额度
write_cfg ""
write_st false "" "" "" false
: >"$VPS_TRAFFIC_TEST_DIR/mock_tc/eth0"
line=$(menu_status_line)
assert "traffic unset quota menu" '[[ "$line" == *"待设置额度"* ]]'
out=$(cmd_status 2>&1)
assert "traffic no legend phrase" '[[ "$out" != *"限速/超限"* ]]'
assert "traffic no handle default" '[[ "$out" != *"1abc"* && "$out" != *"规则"* ]]'
assert "traffic no qdisc default" '[[ "$out" != *"队列"* ]]'
assert "traffic has 未设置" '[[ "$out" == *"未设置"* ]]'
assert "traffic tip quota" '[[ "$out" == *"请先设置每月流量额度"* ]]'
assert "traffic no box" 'no_box "$out"'

# 正常放行
write_cfg 100
write_st false "" "" ok_below_threshold false
export MOCK_TX_BYTES=$((10 * 1000000000))
line=$(menu_status_line)
assert "traffic normal menu" '[[ "$line" == *"正常放行"* ]]'
out=$(cmd_status 2>&1)
assert "traffic normal page" '[[ "$out" == *"正常放行"* && "$out" == *"限速策略"* ]]'

# 接近阈值（用量高但未限速）
export MOCK_TX_BYTES=$((95 * 1000000000))
write_st false "" "" "" false
out=$(cmd_status 2>&1)
assert "traffic near thr" '[[ "$out" == *"接近阈值"* || "$out" == *"95"* ]]'

# 限速中 + qdisc 存在
export MOCK_TX_BYTES=$((95 * 1000000000))
printf 'qdisc tbf 1abc: root refcnt 2 rate 1mbit\n' >"$VPS_TRAFFIC_TEST_DIR/mock_tc/eth0"
write_st true eth0 "1abc:" applied_limit true
line=$(menu_status_line)
assert "traffic limited menu" '[[ "$line" == *"限速中"* ]]'
out=$(cmd_status 2>&1)
assert "traffic limited page" '[[ "$out" == *"限速中"* ]]'
assert "traffic limited no legend" '[[ "$out" != *"限速/超限"* ]]'

# 暂停
write_cfg 100 90 1mbit true
write_st false "" "" paused false
: >"$VPS_TRAFFIC_TEST_DIR/mock_tc/eth0"
line=$(menu_status_line)
assert "traffic paused menu" '[[ "$line" == *"检查已暂停"* ]]'
out=$(cmd_status 2>&1)
assert "traffic paused page" '[[ "$out" == *"检查已暂停"* && "$out" == *"已暂停"* ]]'

# state 限速但 qdisc 不存在 → 状态需检查
write_cfg 100
write_st true eth0 "1abc:" applied_limit true
: >"$VPS_TRAFFIC_TEST_DIR/mock_tc/eth0"
line=$(menu_status_line)
assert "traffic mismatch menu" '[[ "$line" == *"状态需检查"* ]]'
out=$(cmd_status 2>&1)
assert "traffic mismatch page" '[[ "$out" == *"状态需检查"* ]]'
assert "traffic mismatch shows debug" '[[ "$out" == *"规则"* || "$out" == *"队列"* ]]'

# verbose 强制排障
write_st false "" "" "" false
export TRAFFIC_STATUS_VERBOSE=1
out=$(cmd_status 2>&1)
assert "traffic verbose shows 规则" '[[ "$out" == *"规则"* ]]'
unset TRAFFIC_STATUS_VERBOSE

# ui_item set -e 安全（三模块）
for f in vps.sh proxy.sh traffic.sh; do
  set +e
  uout=$(
    set -Eeuo pipefail
    # shellcheck source=/dev/null
    if [[ $f == traffic.sh ]]; then
      export VPS_TRAFFIC_MOCK=1 VPS_TRAFFIC_TEST_DIR="$TMP/t2"
      mkdir -p "$VPS_TRAFFIC_TEST_DIR/etc" "$VPS_TRAFFIC_TEST_DIR/var" "$VPS_TRAFFIC_TEST_DIR/mock_tc"
    fi
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
