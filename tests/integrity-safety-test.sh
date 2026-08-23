#!/usr/bin/env bash
# PR-0/1/2/3/5 完整性与安全回归（mock，不触碰真实 systemd/xray）
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

# ---------- PR-1: ensure_dirs 空目录无递归 ----------
export VPS_TRAFFIC_MOCK=1
export VPS_TRAFFIC_TEST_DIR="$TMP/empty-traffic"
export MOCK_IFACE=eth0
export MOCK_TX_BYTES=1000
export MOCK_YEAR=$(date +%Y)
export MOCK_MONTH=$(date +%m)
# shellcheck source=../traffic.sh
source "$ROOT/traffic.sh"
set +e
(
  set -Eeuo pipefail
  ensure_dirs
  init_config_if_missing
  init_state_if_missing
  [[ -f $CONFIG_FILE && -f $STATE_FILE ]]
)
rc_empty=$?
set -e
assert "empty ensure_dirs init ok" '[[ $rc_empty -eq 0 ]]'
assert "empty config created" '[[ -s $CONFIG_FILE ]]'
assert "empty state created" '[[ -s $STATE_FILE ]]'
# write_config 不得再调用会初始化的 ensure_dirs 链
set +e
(
  set -Eeuo pipefail
  write_config
  write_state
)
rc_w=$?
set -e
assert "write without recursion" '[[ $rc_w -eq 0 ]]'

# timer 状态提示（mock）
: >"$STATE_DIR/.installed"
rm -f "$STATE_DIR/.timer_enabled" "$STATE_DIR/.timer_active"
write_cfg_line() { :; }
MONTHLY_QUOTA_GB=100
PAUSED=false
LIMIT_ACTIVE=false
OWNED_BY_TOOL=false
line=$(menu_status_line)
assert "timer disabled warns" '[[ "$line" == *"定时器未启用"* ]]'
: >"$STATE_DIR/.timer_enabled"
line=$(menu_status_line)
assert "timer inactive warns" '[[ "$line" == *"定时器未运行"* ]]'
: >"$STATE_DIR/.timer_active"
line=$(menu_status_line)
assert "timer ok no warn" '[[ "$line" != *"定时器"* ]]'

# ---------- proxy scan / merge ----------
export VPS_PROXY_SKIP_XRAY_TEST=1
export VPS_PROXY_TEST_MODE=1
export VPS_PROXY_LOCK_LAYOUT=1
# shellcheck source=../proxy.sh
source "$ROOT/proxy.sh"

CFG_DIR="$TMP/xray"
mkdir -p "$CFG_DIR"
XRAY_CONFIG="$CFG_DIR/config.json"
XRAY_CONFIG_FILE="$XRAY_CONFIG"
XRAY_LAYOUT=file
CONFIG_DIR="$TMP/proxy-info"
mkdir -p "$CONFIG_DIR"
REALITY_STATE="$CONFIG_DIR/reality.conf"
CDN_STATE="$CONFIG_DIR/cdn.conf"
HY2_STATE="$CONFIG_DIR/hy2.conf"
XRAY_INFO="$CONFIG_DIR/xray-reality.txt"
CDN_INFO="$CONFIG_DIR/xray-cdn.txt"

# 合法伪装 URL 的查询参数应能安全保存，且不截断旧状态。
SPECIAL_STATE="$CONFIG_DIR/special.conf"
write_kv_file "$SPECIAL_STATE" "HY2_MASQUERADE=https://example.com/a?x=1&y=2"
assert "masquerade query chars survive state write" 'grep -q "HY2_MASQUERADE=https://example.com/a?x=1&y=2" "$SPECIAL_STATE"'

# WS+TLS 可在直连与 Cloudflare 之间选择，并支持单独指定分享链接地址。
parse_cdn_args --mode cloudflare --server 203.0.113.10
assert "ws mode parser" '[[ $CDN_MODE == cloudflare && $CDN_SERVER == 203.0.113.10 ]]'
validate_ws_mode direct
validate_server_host example.com

# 旧版 Hysteria2 没有 state/drop-in 标记时，专用配置 + 信息文件仍可安全识别。
HY2_CONFIG="$CONFIG_DIR/hysteria.yaml"
HY2_INFO="$CONFIG_DIR/hysteria2.txt"
HY2_DROPIN="$CONFIG_DIR/hy2-dropin"
cat >"$HY2_CONFIG" <<'EOF'
listen: :23456
tls:
  cert: /etc/hysteria/certs/server.crt
auth:
  password: test-password
EOF
: >"$HY2_INFO"
assert "legacy hy2 managed detection" 'managed_component_present hy2'

# 多 inbound：目标不是第一个
cat >"$XRAY_CONFIG" <<'EOF'
{
  "inbounds": [
    { "tag": "socks-in", "port": 1080, "protocol": "socks" },
    {
      "tag": "vless-reality",
      "port": 8443,
      "protocol": "vless",
      "streamSettings": { "security": "reality", "realitySettings": {} }
    }
  ],
  "outbounds": []
}
EOF
xray_scan_load
assert "multi inbound has reality" '[[ $HAS_REALITY == 1 ]]'
assert "multi inbound port is 8443 not 1080" '[[ $PORT_REALITY == 8443 ]]'

# state 缺失但真实节点存在
rm -f "$REALITY_STATE"
assert "no state has config" 'component_has_config reality'

# 自定义 confdir 布局
CONFDIR="$TMP/xray-confdir"
mkdir -p "$CONFDIR"
printf '%s\n' '{"inbounds":[{"tag":"vless-ws-tls","port":9443,"protocol":"vless","streamSettings":{"network":"ws","security":"tls"}}]}' \
  >"$CONFDIR/other.json"
XRAY_LAYOUT=dir
XRAY_CONF_DIR=$CONFDIR
xray_scan_load
assert "confdir detects cdn" '[[ $HAS_CDN == 1 ]]'
assert "confdir port 9443" '[[ $PORT_CDN == 9443 ]]'

# ExecStart 解析（不依赖 systemctl）
specs=$(parse_execstart_config_specs 'path=/usr/local/bin/xray run -config /etc/xray/a.json')
assert "parse -config" '[[ "$specs" == *file:/etc/xray/a.json* ]]'
specs=$(parse_execstart_config_specs '/usr/bin/xray -c /tmp/c.json')
assert "parse -c" '[[ "$specs" == *file:/tmp/c.json* ]]'
specs=$(parse_execstart_config_specs 'xray run -confdir /etc/xray/conf.d')
assert "parse -confdir" '[[ "$specs" == *dir:/etc/xray/conf.d* ]]'

# 合并/卸载（需要 python3）
if command -v python3 >/dev/null 2>&1; then
  XRAY_LAYOUT=file
  XRAY_CONFIG_FILE="$CFG_DIR/merge.json"
  XRAY_CONFIG="$XRAY_CONFIG_FILE"
  cat >"$XRAY_CONFIG_FILE" <<'EOF'
{
  "inbounds": [
    { "tag": "keep-me", "port": 10000, "protocol": "dokodemo-door" }
  ],
  "outbounds": [{ "protocol": "freedom", "tag": "direct" }]
}
EOF
  REALITY_PORT=443 REALITY_UUID=11111111-1111-1111-1111-111111111111
  REALITY_SNI=www.example.com REALITY_TARGET=www.example.com:443
  REALITY_PRIV=privkey REALITY_SHORT=abcd1234
  printf 'REALITY_PORT=443\nREALITY_UUID=%s\nREALITY_SNI=%s\nREALITY_TARGET=%s\nREALITY_PRIV=%s\nREALITY_SHORT=%s\nREALITY_PUB=pub\n' \
    "$REALITY_UUID" "$REALITY_SNI" "$REALITY_TARGET" "$REALITY_PRIV" "$REALITY_SHORT" >"$REALITY_STATE"
  build_xray_config
  assert "merge keeps foreign" 'grep -q keep-me "$XRAY_CONFIG_FILE"'
  assert "merge adds reality tag" 'grep -q vless-reality "$XRAY_CONFIG_FILE"'

  rm -f "$REALITY_STATE"
  CDN_PORT=8443 CDN_UUID=22222222-2222-2222-2222-222222222222
  CDN_DOMAIN=ex.com CDN_PATH=/p CDN_CERT=/tmp/c.pem CDN_KEY=/tmp/k.pem
  printf 'CDN_PORT=8443\nCDN_UUID=%s\nCDN_DOMAIN=ex.com\nCDN_PATH=/p\nCDN_CERT=/tmp/c.pem\nCDN_KEY=/tmp/k.pem\n' \
    "$CDN_UUID" >"$CDN_STATE"
  build_xray_config
  assert "after reality gone still keep-me" 'grep -q keep-me "$XRAY_CONFIG_FILE"'
  assert "after reality gone has cdn" 'grep -q vless-ws-tls "$XRAY_CONFIG_FILE"'
  assert "after reality gone no reality tag" '! grep -q vless-reality "$XRAY_CONFIG_FILE"'

  rm -f "$CDN_STATE"
  build_xray_config
  assert "cdn removed keeps keep-me" 'grep -q keep-me "$XRAY_CONFIG_FILE"'
  assert "cdn removed no cdn tag" '! grep -q vless-ws-tls "$XRAY_CONFIG_FILE"'

  XRAY_LAYOUT=dir
  XRAY_CONF_DIR=$CONFDIR
  printf 'REALITY_PORT=443\nREALITY_UUID=%s\nREALITY_SNI=s.com\nREALITY_TARGET=s.com:443\nREALITY_PRIV=p\nREALITY_SHORT=s\nREALITY_PUB=u\n' \
    "$REALITY_UUID" >"$REALITY_STATE"
  rm -f "$CDN_STATE"
  build_xray_config
  assert "confdir reality file" '[[ -f $XRAY_CONF_DIR/$MANAGED_FILE_REALITY ]]'
  assert "confdir other untouched" '[[ -f $XRAY_CONF_DIR/other.json ]]'
else
  assert "merge tests skipped (no python3)" 'true'
fi

# 死代码已删除
assert "no xray_has_inbound_tag" '! grep -q "^xray_has_inbound_tag" "$ROOT/proxy.sh"'
assert "no cmd_set_quota" '! grep -q "^cmd_set_quota" "$ROOT/traffic.sh"'
assert "no vps ui_init" '! grep -q "ui_init" "$ROOT/vps.sh"'
assert "no tokens= unquoted pattern" '! grep -qE "tokens=\(\\\$exec_line\)" "$ROOT/proxy.sh"'
assert "no eval in proxy" '! grep -nE "(^|[[:space:]])eval[[:space:]/]" "$ROOT/proxy.sh" | grep -v "禁止"'

# run_module 返回真实 rc
# shellcheck source=../vps.sh
source "$ROOT/vps.sh"
set +e
run_module /nonexistent/path >/dev/null 2>&1
rc_rm=$?
set -e
assert "run_module missing returns nonzero" '[[ $rc_rm -ne 0 ]]'

echo ""
echo "PASS=$pass FAIL=$fail"
[[ $fail -eq 0 ]]
