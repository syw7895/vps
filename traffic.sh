#!/usr/bin/env bash
# vps-traffic — 独立流量监控与出口限速（与 proxy 完全隔离）
# tc root handle: 1abc: （十六进制 major，见 README）
set -Eeuo pipefail

APP_NAME="vps-traffic"
VERSION="1.0.0"
LIB_DIR="/usr/local/lib/syw-vps"
SELF_LOCAL="${LIB_DIR}/traffic.sh"
RAW_BASE="${SYW_VPS_RAW_BASE:-https://raw.githubusercontent.com/syw7895/vps/main}"

# mock / 可注入二进制（须先于路径展开）
VNSTAT_BIN="${VNSTAT_BIN:-vnstat}"
TC_BIN="${TC_BIN:-tc}"
IP_BIN="${IP_BIN:-ip}"
VPS_TRAFFIC_MOCK="${VPS_TRAFFIC_MOCK:-0}"

if [[ ${VPS_TRAFFIC_MOCK} == 1 ]]; then
  _MOCK_ROOT="${VPS_TRAFFIC_TEST_DIR:-/tmp/vps-traffic-mock-$$}"
  CONFIG_DIR="${_MOCK_ROOT}/etc"
  STATE_DIR="${_MOCK_ROOT}/var"
  LOCK_FILE="${_MOCK_ROOT}/vps-traffic.lock"
  MOCK_TC_FILE="${_MOCK_ROOT}/mock_tc_qdisc"
  mkdir -p "$CONFIG_DIR" "$STATE_DIR"
  # 允许测试预置 MOCK_TC_QDISC 环境变量作为初始值
  if [[ -n ${MOCK_TC_QDISC+x} && ! -f $MOCK_TC_FILE ]]; then
    printf '%s\n' "${MOCK_TC_QDISC}" >"$MOCK_TC_FILE"
  fi
  [[ -f $MOCK_TC_FILE ]] || : >"$MOCK_TC_FILE"
else
  CONFIG_DIR="/etc/vps-traffic"
  STATE_DIR="/var/lib/vps-traffic"
  LOCK_FILE="/var/lock/vps-traffic.lock"
  MOCK_TC_FILE=""
fi
CONFIG_FILE="${CONFIG_DIR}/config"
STATE_FILE="${STATE_DIR}/state"

UNIT_SERVICE="/etc/systemd/system/vps-traffic-check.service"
UNIT_TIMER="/etc/systemd/system/vps-traffic-check.timer"

# 本工具 tc 标识（固定，十六进制 major；见 README）
TC_HANDLE_MAJOR="1abc"
TC_ROOT_HANDLE="${TC_HANDLE_MAJOR}:"

if [[ -t 1 ]]; then
  R=$'\033[0m' B=$'\033[1m' D=$'\033[2m'
  RED=$'\033[31m' GRN=$'\033[32m' YEL=$'\033[33m' CYN=$'\033[36m'
else
  R='' B='' D='' RED='' GRN='' YEL='' CYN=''
fi

log()  { printf '%s[%s]%s %s\n' "$CYN" "$APP_NAME" "$R" "$*"; }
ok()   { printf '%s[%s]%s %s\n' "$GRN" "OK" "$R" "$*"; }
warn() { printf '%s[%s]%s %s\n' "$YEL" "!" "$R" "$*"; }
err()  { printf '%s[%s]%s %s\n' "$RED" "ERR" "$R" "$*" >&2; }
fail() { err "$*"; exit 1; }

read_tty() {
  local prompt="" 
  while [[ $# -gt 0 ]]; do
    case $1 in
      -p) prompt=$2; shift 2 ;;
      *) break ;;
    esac
  done
  local __var=${1:-REPLY}
  if [[ -r /dev/tty ]]; then
    # shellcheck disable=SC2162
    read -r -p "$prompt" "$__var" </dev/tty || return 1
  else
    # shellcheck disable=SC2162
    read -r -p "$prompt" "$__var" || return 1
  fi
}

require_root() {
  if [[ $VPS_TRAFFIC_MOCK == 1 ]]; then
    return 0
  fi
  [[ $EUID -eq 0 ]] || fail "请使用 root 运行"
}

# ---------- 配置 / 状态 ----------
default_config_body() {
  cat <<'EOF'
# vps-traffic 配置（十进制 GB：1 GB = 1000000000 bytes）
MONTHLY_QUOTA_GB=
THRESHOLD_PERCENT=90
LIMIT_RATE=1mbit
TRAFFIC_DIRECTION=tx
IFACE=auto
PAUSED=false
EOF
}

ensure_dirs() {
  mkdir -p "$CONFIG_DIR" "$STATE_DIR"
  chmod 755 "$CONFIG_DIR" "$STATE_DIR"
  if [[ ! -f $CONFIG_FILE ]]; then
    default_config_body >"$CONFIG_FILE"
    chmod 644 "$CONFIG_FILE"
  fi
  if [[ ! -f $STATE_FILE ]]; then
    cat >"$STATE_FILE" <<'EOF'
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
    chmod 644 "$STATE_FILE"
  fi
}

load_config() {
  ensure_dirs
  # shellcheck disable=SC1090,SC1091
  source "$CONFIG_FILE"
  # shellcheck disable=SC2154
  MONTHLY_QUOTA_GB="${MONTHLY_QUOTA_GB:-}"
  # shellcheck disable=SC2154
  THRESHOLD_PERCENT="${THRESHOLD_PERCENT:-90}"
  # shellcheck disable=SC2154
  LIMIT_RATE="${LIMIT_RATE:-1mbit}"
  # shellcheck disable=SC2154
  TRAFFIC_DIRECTION="${TRAFFIC_DIRECTION:-tx}"
  # shellcheck disable=SC2154
  IFACE="${IFACE:-auto}"
  # shellcheck disable=SC2154
  PAUSED="${PAUSED:-false}"
}

save_config_kv() {
  ensure_dirs
  local tmp
  tmp=$(mktemp)
  default_config_body >"$tmp"
  # 覆盖已知键
  load_config
  {
    echo "# vps-traffic 配置（十进制 GB：1 GB = 1000000000 bytes）"
    echo "MONTHLY_QUOTA_GB=${MONTHLY_QUOTA_GB}"
    echo "THRESHOLD_PERCENT=${THRESHOLD_PERCENT}"
    echo "LIMIT_RATE=${LIMIT_RATE}"
    echo "TRAFFIC_DIRECTION=${TRAFFIC_DIRECTION}"
    echo "IFACE=${IFACE}"
    echo "PAUSED=${PAUSED}"
  } >"$CONFIG_FILE"
  chmod 644 "$CONFIG_FILE"
  rm -f "$tmp"
}

load_state() {
  ensure_dirs
  # shellcheck disable=SC1090,SC1091
  source "$STATE_FILE"
  # shellcheck disable=SC2154
  LIMIT_ACTIVE="${LIMIT_ACTIVE:-false}"
  # shellcheck disable=SC2154
  LIMIT_IFACE="${LIMIT_IFACE:-}"
  # shellcheck disable=SC2154
  LIMIT_HANDLE="${LIMIT_HANDLE:-}"
  # shellcheck disable=SC2154
  LAST_REASON="${LAST_REASON:-}"
  # shellcheck disable=SC2154
  LAST_CHECK_TS="${LAST_CHECK_TS:-}"
  # shellcheck disable=SC2154
  LAST_TX_BYTES="${LAST_TX_BYTES:-}"
  # shellcheck disable=SC2154
  LAST_MONTH="${LAST_MONTH:-}"
  # shellcheck disable=SC2154
  LAST_RATIO="${LAST_RATIO:-}"
  # shellcheck disable=SC2154
  OWNED_BY_TOOL="${OWNED_BY_TOOL:-false}"
}

write_state() {
  ensure_dirs
  cat >"$STATE_FILE" <<EOF
LIMIT_ACTIVE=${LIMIT_ACTIVE:-false}
LIMIT_IFACE=${LIMIT_IFACE:-}
LIMIT_HANDLE=${LIMIT_HANDLE:-}
LAST_REASON=${LAST_REASON:-}
LAST_CHECK_TS=${LAST_CHECK_TS:-}
LAST_TX_BYTES=${LAST_TX_BYTES:-}
LAST_MONTH=${LAST_MONTH:-}
LAST_RATIO=${LAST_RATIO:-}
OWNED_BY_TOOL=${OWNED_BY_TOOL:-false}
EOF
  chmod 644 "$STATE_FILE"
}

# ---------- 网卡 ----------
detect_default_iface() {
  local out dev
  if [[ $VPS_TRAFFIC_MOCK == 1 ]]; then
    echo "${MOCK_IFACE:-eth0}"
    return 0
  fi
  out=$($IP_BIN -4 route get 1.1.1.1 2>/dev/null || true)
  # 典型: 1.1.1.1 via x.x.x.x dev eth0 src ...
  if [[ $out =~ [[:space:]]dev[[:space:]]+([^[:space:]]+) ]]; then
    dev=${BASH_REMATCH[1]}
    echo "$dev"
    return 0
  fi
  return 1
}

list_ifaces() {
  if [[ $VPS_TRAFFIC_MOCK == 1 ]]; then
    printf '%s\n' eth0 eth1
    return 0
  fi
  $IP_BIN -o link show 2>/dev/null | awk -F': ' '{print $2}' | cut -d'@' -f1 | grep -v '^lo$' || true
}

resolve_iface() {
  load_config
  local iface=$IFACE
  if [[ -z $iface || $iface == auto ]]; then
    if iface=$(detect_default_iface); then
      echo "$iface"
      return 0
    fi
    warn "无法唯一判断默认出口网卡"
    local -a ifs=()
    mapfile -t ifs < <(list_ifaces)
    if [[ ${#ifs[@]} -eq 0 ]]; then
      fail "未找到可用网卡"
    fi
    if [[ ${#ifs[@]} -eq 1 ]]; then
      echo "${ifs[0]}"
      return 0
    fi
    printf '可选网卡:\n'
    local i
    for i in "${!ifs[@]}"; do
      printf '  %s) %s\n' "$((i + 1))" "${ifs[$i]}"
    done
    local c
    read_tty -p "请选择网卡编号: " c
    [[ $c =~ ^[0-9]+$ ]] || fail "无效选择"
    i=$((c - 1))
    [[ $i -ge 0 && $i -lt ${#ifs[@]} ]] || fail "无效选择"
    echo "${ifs[$i]}"
    return 0
  fi
  echo "$iface"
}

# ---------- vnStat ----------
require_vnstat_version() {
  if [[ $VPS_TRAFFIC_MOCK == 1 ]]; then
    return 0
  fi
  command -v "$VNSTAT_BIN" >/dev/null || fail "未安装 vnStat。请先执行菜单「安装流量监控」"
  local ver major minor
  ver=$($VNSTAT_BIN --version 2>&1 | head -n1 || true)
  # vnStat 2.10 ... or vnstat 2.6
  if [[ $ver =~ ([0-9]+)\.([0-9]+) ]]; then
    major=${BASH_REMATCH[1]}
    minor=${BASH_REMATCH[2]}
  else
    fail "无法解析 vnStat 版本: $ver"
  fi
  if (( major < 2 || (major == 2 && minor < 6) )); then
    fail "需要 vnStat 2.6+，当前: $ver。请升级（Debian: apt install vnstat）"
  fi
}

# 返回当前日历月 TX 字节数到 stdout；失败返回非 0
# 可测试入口
read_monthly_tx_bytes() {
  local iface=$1
  local json year month
  year=$(date +%Y)
  month=$(date +%-m) # 1-12 无前导零便于数值比较；JSON 里可能是 7 或 07
  month=$(date +%m)
  # 规范化去掉前导零用于比较
  local month_num=$((10#$month))

  if [[ $VPS_TRAFFIC_MOCK == 1 ]]; then
    # MOCK_TX_BYTES / MOCK_YEAR / MOCK_MONTH
    if [[ -n ${MOCK_VNSTAT_FAIL:-} ]]; then
      return 1
    fi
    if [[ -n ${MOCK_YEAR:-} && -n ${MOCK_MONTH:-} ]]; then
      if [[ ${MOCK_YEAR} != "$year" || $((10#${MOCK_MONTH})) -ne $month_num ]]; then
        # 模拟「月份不符」无本月数据
        return 2
      fi
    fi
    if [[ -z ${MOCK_TX_BYTES:-} ]]; then
      return 1
    fi
    echo "${MOCK_TX_BYTES}"
    return 0
  fi

  json=$($VNSTAT_BIN -i "$iface" --json m 2>/dev/null || true)
  if [[ -z $json ]]; then
    return 1
  fi

  if command -v python3 >/dev/null 2>&1; then
    local out rc
    set +e
    out=$(printf '%s' "$json" | YEAR=$year MONTH=$month_num python3 -c '
import json, os, sys
raw = sys.stdin.read()
try:
    data = json.loads(raw)
except Exception:
    sys.exit(1)
year = int(os.environ["YEAR"])
month = int(os.environ["MONTH"])
ifaces = data.get("interfaces") or []
for iface in ifaces:
    traffic = (iface.get("traffic") or {})
    months = traffic.get("month") or traffic.get("months") or []
    for m in months:
        d = m.get("date") or {}
        y = int(d.get("year") or 0)
        mo = int(d.get("month") or 0)
        if y == year and mo == month:
            tx = m.get("tx")
            if tx is None:
                sys.exit(1)
            print(int(tx))
            sys.exit(0)
sys.exit(2)
')
    rc=$?
    set -e
    if [[ $rc -eq 0 && -n $out ]]; then
      echo "$out"
      return 0
    fi
    return "$rc"
  fi

  # 无 python3 时拒绝猜测，避免误限速
  return 1
}

# ---------- tc（可测试） ----------
# 列出网卡 root qdisc 行
tc_qdisc_show() {
  local iface=$1
  if [[ $VPS_TRAFFIC_MOCK == 1 ]]; then
    cat "${MOCK_TC_FILE:-/dev/null}" 2>/dev/null || true
    return 0
  fi
  $TC_BIN qdisc show dev "$iface" 2>/dev/null || true
}

# 是否已有本工具 root handle
has_our_qdisc() {
  local iface=$1
  local show
  show=$(tc_qdisc_show "$iface")
  [[ $show =~ handle[[:space:]]+${TC_HANDLE_MAJOR}: ]] || [[ $show =~ ${TC_HANDLE_MAJOR}: ]]
}

# 是否存在其它 root qdisc（冲突）
has_foreign_root_qdisc() {
  local iface=$1
  local show
  show=$(tc_qdisc_show "$iface")
  [[ -z $show ]] && return 1
  # 无 qdisc 或仅 fq_codel/默认 noqueue 有时也有 — 看是否含 root
  if ! grep -q 'qdisc' <<<"$show"; then
    return 1
  fi
  # 若只有我们的 handle，不算 foreign
  if has_our_qdisc "$iface"; then
    # 若还有其它 root？简单：多行 root 且不全是我们的
    if grep -E 'qdisc .+ root' <<<"$show" | grep -vq "${TC_HANDLE_MAJOR}:"; then
      return 0
    fi
    return 1
  fi
  # 存在 root 但不是我们的
  if grep -qE 'qdisc .+ root' <<<"$show"; then
    return 0
  fi
  return 1
}

# 应用限速；成功 0；冲突 3；失败 1
# 可测试入口
apply_limit() {
  local iface=$1
  local rate=${2:-1mbit}

  if has_our_qdisc "$iface"; then
    log "已存在本工具限速规则，跳过叠加"
    return 0
  fi

  if has_foreign_root_qdisc "$iface"; then
    err "检测到非本工具的 tc/qdisc 规则，跳过限速以免覆盖。请手动处理冲突。"
    LAST_REASON="conflict_foreign_qdisc"
    return 3
  fi

  # 创建前确认 handle 未被占用（再次检查 show）
  local show
  show=$(tc_qdisc_show "$iface")
  if [[ $show == *"${TC_HANDLE_MAJOR}:"* ]]; then
    err "handle ${TC_ROOT_HANDLE} 已被占用"
    LAST_REASON="handle_busy"
    return 3
  fi

  if [[ $VPS_TRAFFIC_MOCK == 1 ]]; then
    printf 'qdisc tbf %s root refcnt 2 rate %s\n' "${TC_ROOT_HANDLE}" "$rate" >"$MOCK_TC_FILE"
    return 0
  fi

  if ! $TC_BIN qdisc add dev "$iface" root handle "${TC_ROOT_HANDLE}" tbf rate "$rate" burst 32kbit latency 400ms 2>/tmp/vps-traffic-tc.err; then
    err "tc 添加失败: $(cat /tmp/vps-traffic-tc.err 2>/dev/null || true)"
    LAST_REASON="tc_add_failed"
    return 1
  fi
  if ! has_our_qdisc "$iface"; then
    err "tc 添加后未检测到本工具规则"
    LAST_REASON="tc_verify_failed"
    return 1
  fi
  return 0
}

# 删除本工具限速；仅当状态与 handle 匹配
# 可测试入口
remove_limit() {
  local iface=$1
  load_state

  if [[ $OWNED_BY_TOOL != true && $LIMIT_ACTIVE != true ]]; then
    # 若线上仍有我们的 handle，也允许按 handle 清理（自愈）
    if ! has_our_qdisc "$iface"; then
      log "无需解除：未持有本工具限速"
      return 0
    fi
  fi

  if has_foreign_root_qdisc "$iface" && ! has_our_qdisc "$iface"; then
    warn "存在非本工具规则且无本工具 handle，不修改 tc"
    return 0
  fi

  if ! has_our_qdisc "$iface"; then
    log "设备上无本工具 qdisc，仅更新状态"
    LIMIT_ACTIVE=false
    OWNED_BY_TOOL=false
    LIMIT_HANDLE=
    LIMIT_IFACE=
    write_state
    return 0
  fi

  if [[ $VPS_TRAFFIC_MOCK == 1 ]]; then
    : >"$MOCK_TC_FILE"
    LIMIT_ACTIVE=false
    OWNED_BY_TOOL=false
    LIMIT_HANDLE=
    LIMIT_IFACE=
    write_state
    return 0
  fi

  # 仅删除本工具 root handle
  if ! $TC_BIN qdisc del dev "$iface" root handle "${TC_ROOT_HANDLE}" 2>/tmp/vps-traffic-tc.err; then
    err "tc 删除失败（不会强行 del 其它 root）: $(cat /tmp/vps-traffic-tc.err 2>/dev/null || true)"
    LAST_REASON="tc_del_failed"
    return 1
  fi

  if has_our_qdisc "$iface"; then
    err "删除后仍检测到本工具规则"
    return 1
  fi

  LIMIT_ACTIVE=false
  OWNED_BY_TOOL=false
  LIMIT_HANDLE=
  LIMIT_IFACE=
  write_state
  return 0
}

# ---------- 检查逻辑 ----------
quota_bytes() {
  load_config
  [[ -n $MONTHLY_QUOTA_GB ]] || return 1
  # 十进制 GB
  awk -v g="$MONTHLY_QUOTA_GB" 'BEGIN{printf "%.0f", g * 1000000000}'
}

# 执行一轮检查；异常时不改 tc
# 可测试入口
run_check() {
  load_config
  load_state

  local iface tx thr_bytes quota ratio_x100 action
  local now_ts month_key

  now_ts=$(date +%s)
  month_key=$(date +%Y-%m)

  if [[ $PAUSED == true || $PAUSED == 1 ]]; then
    LAST_REASON="paused"
    LAST_CHECK_TS=$now_ts
    write_state
    log "已暂停自动检查，跳过"
    return 0
  fi

  if ! iface=$(resolve_iface 2>/dev/null); then
    LAST_REASON="iface_unresolved"
    LAST_CHECK_TS=$now_ts
    write_state
    warn "网卡未解析，不修改 tc"
    return 0
  fi

  if ! quota=$(quota_bytes); then
    LAST_REASON="quota_unset"
    LAST_CHECK_TS=$now_ts
    write_state
    warn "未设置月额度，不修改 tc"
    return 0
  fi

  set +e
  tx=$(read_monthly_tx_bytes "$iface")
  local trc=$?
  set -e
  if [[ $trc -ne 0 || -z $tx ]]; then
    LAST_REASON="vnstat_unavailable_or_bad_month"
    LAST_CHECK_TS=$now_ts
    write_state
    warn "vnStat 无数据/解析失败/月份异常 (rc=$trc)，不修改 tc"
    return 0
  fi
  if ! [[ $tx =~ ^[0-9]+$ ]]; then
    LAST_REASON="tx_not_numeric"
    LAST_CHECK_TS=$now_ts
    write_state
    warn "TX 非数字，不修改 tc"
    return 0
  fi

  thr_bytes=$(awk -v q="$quota" -v p="$THRESHOLD_PERCENT" 'BEGIN{printf "%.0f", q * p / 100}')
  ratio_x100=$(awk -v t="$tx" -v q="$quota" 'BEGIN{ if(q<=0){print 0; exit} printf "%.2f", t*100/q }')

  LAST_TX_BYTES=$tx
  LAST_MONTH=$month_key
  LAST_RATIO=$ratio_x100
  LAST_CHECK_TS=$now_ts

  log "iface=$iface tx=$tx bytes quota=$quota thr=$thr_bytes ratio=${ratio_x100}% rate=$LIMIT_RATE"

  if (( tx < thr_bytes )); then
    action="below_threshold"
    if [[ $LIMIT_ACTIVE == true || $OWNED_BY_TOOL == true ]] || has_our_qdisc "$iface"; then
      log "低于阈值，解除本工具限速"
      if remove_limit "$iface"; then
        LAST_REASON="removed_below_threshold"
        ok "已解除限速"
      else
        LAST_REASON="remove_failed"
        write_state
        return 1
      fi
    else
      LAST_REASON="ok_below_threshold"
    fi
    write_state
    return 0
  fi

  # 达到或超过阈值
  action="over_threshold"
  if has_our_qdisc "$iface"; then
    LIMIT_ACTIVE=true
    OWNED_BY_TOOL=true
    LIMIT_HANDLE=$TC_ROOT_HANDLE
    LIMIT_IFACE=$iface
    LAST_REASON="already_limited"
    write_state
    log "已在限速中，保持"
    return 0
  fi

  set +e
  apply_limit "$iface" "$LIMIT_RATE"
  local arc=$?
  set -e
  if [[ $arc -eq 0 ]]; then
    LIMIT_ACTIVE=true
    OWNED_BY_TOOL=true
    LIMIT_HANDLE=$TC_ROOT_HANDLE
    LIMIT_IFACE=$iface
    LAST_REASON="applied_limit"
    write_state
    ok "已应用限速 $LIMIT_RATE on $iface"
    return 0
  elif [[ $arc -eq 3 ]]; then
    # 冲突：不标记成功持有
    LIMIT_ACTIVE=false
    OWNED_BY_TOOL=false
    write_state
    return 0
  else
    write_state
    return 1
  fi
}

with_lock() {
  mkdir -p "$(dirname "$LOCK_FILE")"
  if [[ $VPS_TRAFFIC_MOCK == 1 ]]; then
    "$@"
    return $?
  fi
  exec 9>"$LOCK_FILE"
  if ! flock -n 9; then
    warn "另一检查仍在运行，跳过本轮"
    return 0
  fi
  "$@"
}

# ---------- 安装 / systemd ----------
install_vnstat_packages() {
  require_root
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y vnstat iproute2
  else
    fail "目前支持 apt 系（Debian/Ubuntu）"
  fi
  require_vnstat_version
  local iface
  iface=$(resolve_iface)
  # 确保接口在 vnstat 中
  systemctl enable --now vnstat 2>/dev/null || true
  if ! $VNSTAT_BIN -i "$iface" --add 2>/dev/null; then
    log "vnstat --add 可能已存在，继续"
  fi
  # 写回 IFACE 具体值（可选保留 auto）
  load_config
  if [[ $IFACE == auto ]]; then
    # 保留 auto，运行时解析
    :
  fi
  ok "vnStat 已安装，监控网卡示例: $iface"
}

write_systemd_units() {
  require_root
  local script=$SELF_LOCAL
  if [[ ! -f $script ]]; then
    script=$(readlink -f "${BASH_SOURCE[0]}")
  fi
  cat >"$UNIT_SERVICE" <<EOF
[Unit]
Description=VPS traffic quota check (one-shot)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/env bash ${script} --check
Nice=10

[Install]
WantedBy=multi-user.target
EOF

  cat >"$UNIT_TIMER" <<EOF
[Unit]
Description=Run VPS traffic check every 5 minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec=5min
AccuracySec=30s
Persistent=true
Unit=vps-traffic-check.service

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now vps-traffic-check.timer
  ok "已启用 timer: vps-traffic-check.timer"
}

cmd_install() {
  require_root
  ensure_dirs
  install_vnstat_packages
  # 安装脚本副本到 lib（若从别处运行）
  mkdir -p "$LIB_DIR"
  local src
  src=$(readlink -f "${BASH_SOURCE[0]}")
  if [[ -f $src ]]; then
    install -m 0755 "$src" "$SELF_LOCAL"
  fi
  write_systemd_units
  load_config
  if [[ -z $MONTHLY_QUOTA_GB ]]; then
    warn "尚未设置月额度，请执行菜单项 2"
  fi
  ok "流量监控安装完成"
}

cmd_set_quota() {
  require_root
  load_config
  local g
  read_tty -p "请输入每月流量额度（十进制 GB，例如 500）: " g
  [[ $g =~ ^[0-9]+([.][0-9]+)?$ ]] || fail "额度必须是数字"
  MONTHLY_QUOTA_GB=$g
  save_config_kv
  # 重新 source 写入
  {
    echo "# vps-traffic 配置（十进制 GB：1 GB = 1000000000 bytes）"
    echo "MONTHLY_QUOTA_GB=${g}"
    echo "THRESHOLD_PERCENT=${THRESHOLD_PERCENT:-90}"
    echo "LIMIT_RATE=${LIMIT_RATE:-1mbit}"
    echo "TRAFFIC_DIRECTION=${TRAFFIC_DIRECTION:-tx}"
    echo "IFACE=${IFACE:-auto}"
    echo "PAUSED=${PAUSED:-false}"
  } >"$CONFIG_FILE"
  ok "已设置月额度 ${g} GB"
}

cmd_set_threshold() {
  require_root
  load_config
  local p
  read_tty -p "触发比例 %（当前 ${THRESHOLD_PERCENT}）: " p
  [[ $p =~ ^[0-9]+$ ]] && (( p > 0 && p <= 100 )) || fail "比例须为 1-100 整数"
  {
    echo "# vps-traffic 配置（十进制 GB：1 GB = 1000000000 bytes）"
    echo "MONTHLY_QUOTA_GB=${MONTHLY_QUOTA_GB}"
    echo "THRESHOLD_PERCENT=${p}"
    echo "LIMIT_RATE=${LIMIT_RATE:-1mbit}"
    echo "TRAFFIC_DIRECTION=${TRAFFIC_DIRECTION:-tx}"
    echo "IFACE=${IFACE:-auto}"
    echo "PAUSED=${PAUSED:-false}"
  } >"$CONFIG_FILE"
  ok "触发比例已设为 ${p}%"
}

cmd_set_rate() {
  require_root
  load_config
  local r
  read_tty -p "限速速度（tc rate，如 1mbit / 500kbit，当前 ${LIMIT_RATE}）: " r
  [[ $r =~ ^[0-9]+([.][0-9]+)?[kKmMgG]?bit$ ]] || fail "格式示例: 1mbit"
  {
    echo "# vps-traffic 配置（十进制 GB：1 GB = 1000000000 bytes）"
    echo "MONTHLY_QUOTA_GB=${MONTHLY_QUOTA_GB}"
    echo "THRESHOLD_PERCENT=${THRESHOLD_PERCENT:-90}"
    echo "LIMIT_RATE=${r}"
    echo "TRAFFIC_DIRECTION=${TRAFFIC_DIRECTION:-tx}"
    echo "IFACE=${IFACE:-auto}"
    echo "PAUSED=${PAUSED:-false}"
  } >"$CONFIG_FILE"
  ok "限速速度已设为 ${r}"
}

cmd_status() {
  load_config
  load_state
  local iface tx="" 
  set +e
  iface=$(resolve_iface 2>/dev/null)
  set -e
  printf '\n%s流量与限速状态%s\n' "$B" "$R"
  printf '  配置文件: %s\n' "$CONFIG_FILE"
  printf '  月额度: %s GB (十进制)\n' "${MONTHLY_QUOTA_GB:-未设置}"
  printf '  触发比例: %s%%\n' "${THRESHOLD_PERCENT}"
  printf '  限速速度: %s\n' "${LIMIT_RATE}"
  printf '  网卡: %s (配置 IFACE=%s)\n' "${iface:-未知}" "$IFACE"
  printf '  暂停自动检查: %s\n' "$PAUSED"
  printf '  本工具限速中: %s\n' "$LIMIT_ACTIVE"
  printf '  持有规则: %s handle=%s\n' "$OWNED_BY_TOOL" "${LIMIT_HANDLE:-}"
  printf '  上次检查: %s\n' "${LAST_CHECK_TS:-}"
  printf '  上次月份: %s\n' "${LAST_MONTH:-}"
  printf '  上次 TX: %s bytes\n' "${LAST_TX_BYTES:-}"
  printf '  上次比例: %s%%\n' "${LAST_RATIO:-}"
  printf '  上次原因: %s\n' "${LAST_REASON:-}"
  if [[ -n ${iface:-} ]]; then
    set +e
    tx=$(read_monthly_tx_bytes "$iface" 2>/dev/null)
    set -e
    if [[ -n $tx ]]; then
      local gb
      gb=$(awk -v t="$tx" 'BEGIN{printf "%.3f", t/1000000000}')
      printf '  本月 TX(实时): %s bytes (~%s GB)\n' "$tx" "$gb"
    else
      printf '  本月 TX(实时): 暂无数据\n'
    fi
    printf '  当前 qdisc:\n'
    tc_qdisc_show "$iface" | sed 's/^/    /' || true
  fi
  printf '\n%s注意:%s 限速为 %s 时，持续运行一天仍可能产生约 10.8 GB 流量，不能绝对保证额度不会耗尽。\n' "$YEL" "$R" "$LIMIT_RATE"
  printf 'vnStat 与云厂商后台统计可能存在误差。\n'
}

cmd_check_now() {
  require_root
  with_lock run_check
}

cmd_remove_limit() {
  require_root
  load_config
  load_state
  local iface
  iface=${LIMIT_IFACE:-}
  if [[ -z $iface ]]; then
    iface=$(resolve_iface)
  fi
  with_lock remove_limit "$iface"
  LAST_REASON="manual_remove"
  write_state
  if [[ $PAUSED != true ]]; then
    warn "自动检查仍开启：若本月流量仍≥阈值，下次 timer 会重新限速。"
    warn "如需持续解除：请先「暂停自动检查」，再解除限速。"
  fi
  ok "已尝试解除本工具限速"
}

cmd_pause() {
  require_root
  load_config
  PAUSED=true
  {
    echo "# vps-traffic 配置（十进制 GB：1 GB = 1000000000 bytes）"
    echo "MONTHLY_QUOTA_GB=${MONTHLY_QUOTA_GB}"
    echo "THRESHOLD_PERCENT=${THRESHOLD_PERCENT:-90}"
    echo "LIMIT_RATE=${LIMIT_RATE:-1mbit}"
    echo "TRAFFIC_DIRECTION=${TRAFFIC_DIRECTION:-tx}"
    echo "IFACE=${IFACE:-auto}"
    echo "PAUSED=true"
  } >"$CONFIG_FILE"
  if [[ $VPS_TRAFFIC_MOCK != 1 ]]; then
    systemctl stop vps-traffic-check.timer 2>/dev/null || true
    systemctl disable vps-traffic-check.timer 2>/dev/null || true
  fi
  ok "已暂停自动检查（vnStat 统计仍继续）"
}

cmd_resume() {
  require_root
  load_config
  PAUSED=false
  {
    echo "# vps-traffic 配置（十进制 GB：1 GB = 1000000000 bytes）"
    echo "MONTHLY_QUOTA_GB=${MONTHLY_QUOTA_GB}"
    echo "THRESHOLD_PERCENT=${THRESHOLD_PERCENT:-90}"
    echo "LIMIT_RATE=${LIMIT_RATE:-1mbit}"
    echo "TRAFFIC_DIRECTION=${TRAFFIC_DIRECTION:-tx}"
    echo "IFACE=${IFACE:-auto}"
    echo "PAUSED=false"
  } >"$CONFIG_FILE"
  if [[ $VPS_TRAFFIC_MOCK != 1 ]]; then
    write_systemd_units
    systemctl start vps-traffic-check.timer 2>/dev/null || true
  fi
  ok "已恢复自动检查，立即执行一轮"
  with_lock run_check
}

cmd_update_module() {
  require_root
  local url="${RAW_BASE}/traffic.sh"
  local tmp bak
  tmp=$(mktemp)
  bak="${SELF_LOCAL}.bak.$(date +%s)"
  log "下载 $url"
  curl -fsSL --connect-timeout 20 --max-time 120 "$url" -o "$tmp" || fail "下载失败"
  [[ -s $tmp ]] || fail "下载为空"
  bash -n "$tmp" || fail "bash -n 失败，保留旧版本"
  mkdir -p "$LIB_DIR"
  if [[ -f $SELF_LOCAL ]]; then
    cp -a "$SELF_LOCAL" "$bak"
    ok "已备份旧版: $bak"
  fi
  install -m 0755 "$tmp" "$SELF_LOCAL"
  rm -f "$tmp"
  # 刷新 unit 模板（仍指向本地 traffic.sh）
  write_systemd_units
  ok "流量模块已更新（未改动 proxy/vps 入口）"
}

cmd_uninstall() {
  require_root
  local ans keep_vnstat
  read_tty -p "确认卸载流量模块？不影响代理/v2/vps 入口 [y/N]: " ans
  [[ $ans == y || $ans == Y ]] || { log "已取消"; return 0; }

  load_state
  local iface=${LIMIT_IFACE:-}
  if [[ -z $iface ]]; then
    set +e
    iface=$(resolve_iface 2>/dev/null)
    set -e
  fi
  if [[ -n ${iface:-} ]]; then
    remove_limit "$iface" || true
  fi

  if [[ $VPS_TRAFFIC_MOCK != 1 ]]; then
    systemctl disable --now vps-traffic-check.timer 2>/dev/null || true
    systemctl disable --now vps-traffic-check.service 2>/dev/null || true
    rm -f "$UNIT_SERVICE" "$UNIT_TIMER"
    systemctl daemon-reload || true
  fi

  rm -rf "$CONFIG_DIR" "$STATE_DIR"
  rm -f "$LOCK_FILE"

  read_tty -p "是否保留 vnStat 数据库与软件包？[Y/n]: " keep_vnstat
  if [[ $keep_vnstat == n || $keep_vnstat == N ]]; then
    if command -v apt-get >/dev/null 2>&1; then
      apt-get remove -y vnstat || true
    fi
  else
    ok "已保留 vnStat"
  fi

  # 不删除 /usr/local/lib/syw-vps/traffic.sh 可由用户选
  read_tty -p "删除 ${SELF_LOCAL}？[y/N]: " ans
  if [[ $ans == y || $ans == Y ]]; then
    rm -f "$SELF_LOCAL"
  fi

  ok "流量模块已卸载（未触碰代理、证书、v2、vps 入口）"
}

main_menu() {
  local c
  while true; do
    printf '\n%s%s流量管理%s\n' "$B" "$CYN" "$R"
    printf '  1. 安装流量监控\n'
    printf '  2. 设置每月流量额度\n'
    printf '  3. 查看本月流量和限速状态\n'
    printf '  4. 修改触发比例\n'
    printf '  5. 修改限速速度\n'
    printf '  6. 立即检查\n'
    printf '  7. 解除当前限速\n'
    printf '  8. 暂停自动检查\n'
    printf '  9. 恢复自动检查\n'
    printf '  10. 更新流量模块\n'
    printf '  11. 卸载流量模块\n'
    printf '  0. 返回\n'
    c=""
    read_tty -p "请选择: " c || c=0
    case $c in
      1) cmd_install; read_tty -p "按回车继续..." _ || true ;;
      2) cmd_set_quota; read_tty -p "按回车继续..." _ || true ;;
      3) cmd_status; read_tty -p "按回车继续..." _ || true ;;
      4) cmd_set_threshold; read_tty -p "按回车继续..." _ || true ;;
      5) cmd_set_rate; read_tty -p "按回车继续..." _ || true ;;
      6) cmd_check_now; read_tty -p "按回车继续..." _ || true ;;
      7) cmd_remove_limit; read_tty -p "按回车继续..." _ || true ;;
      8) cmd_pause; read_tty -p "按回车继续..." _ || true ;;
      9) cmd_resume; read_tty -p "按回车继续..." _ || true ;;
      10) cmd_update_module; read_tty -p "按回车继续..." _ || true ;;
      11) cmd_uninstall; return 0 ;;
      0) return 0 ;;
      *) warn "无效选项" ;;
    esac
  done
}

usage() {
  cat <<EOF
${APP_NAME} v${VERSION}

  bash traffic.sh              菜单
  bash traffic.sh --check      检查一轮（供 systemd）
  bash traffic.sh --help

环境变量（测试）:
  VPS_TRAFFIC_MOCK=1
  VNSTAT_BIN=...  TC_BIN=...  IP_BIN=...
  MOCK_TX_BYTES MOCK_YEAR MOCK_MONTH MOCK_TC_QDISC MOCK_IFACE

tc handle: ${TC_ROOT_HANDLE}
EOF
}

main() {
  local cmd=${1:-menu}
  case $cmd in
    -h|--help|help) usage ;;
    --check|check)
      require_root
      with_lock run_check
      ;;
    --status|status) cmd_status ;;
    menu|"") main_menu ;;
    *) fail "未知命令: $cmd" ;;
  esac
}

if [[ "${1:-}" == "--self-test-functions" ]]; then
  # 仅供测试脚本 source 时不执行 main
  return 0 2>/dev/null || true
fi

if [[ -z ${BASH_SOURCE[0]:-} || ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
