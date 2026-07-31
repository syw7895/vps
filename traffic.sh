#!/usr/bin/env bash
# vps-traffic — 独立流量监控与出口限速（与 proxy 完全隔离）
# tc root handle: 1abc: （十六进制 major，见 README）
set -Eeuo pipefail

APP_NAME="vps-traffic"
VERSION="1.3.2"
LIB_DIR="/usr/local/lib/syw-vps"
SELF_LOCAL="${LIB_DIR}/traffic.sh"
SYW_VPS_REF="${SYW_VPS_REF:-main}"
RAW_BASE="${SYW_VPS_RAW_BASE:-https://raw.githubusercontent.com/syw7895/vps/${SYW_VPS_REF}}"

VNSTAT_BIN="${VNSTAT_BIN:-vnstat}"
TC_BIN="${TC_BIN:-tc}"
IP_BIN="${IP_BIN:-ip}"
VPS_TRAFFIC_MOCK="${VPS_TRAFFIC_MOCK:-0}"

if [[ ${VPS_TRAFFIC_MOCK} == 1 ]]; then
  _MOCK_ROOT="${VPS_TRAFFIC_TEST_DIR:-/tmp/vps-traffic-mock-$$}"
  CONFIG_DIR="${_MOCK_ROOT}/etc"
  STATE_DIR="${_MOCK_ROOT}/var"
  LOCK_FILE="${_MOCK_ROOT}/vps-traffic.lock"
  MOCK_TC_DIR="${_MOCK_ROOT}/mock_tc"
  mkdir -p "$CONFIG_DIR" "$STATE_DIR" "$MOCK_TC_DIR"
else
  CONFIG_DIR="/etc/vps-traffic"
  STATE_DIR="/var/lib/vps-traffic"
  LOCK_FILE="/var/lock/vps-traffic.lock"
  MOCK_TC_DIR=""
fi
CONFIG_FILE="${CONFIG_DIR}/config"
STATE_FILE="${STATE_DIR}/state"

UNIT_SERVICE="/etc/systemd/system/vps-traffic-check.service"
UNIT_TIMER="/etc/systemd/system/vps-traffic-check.timer"

TC_HANDLE_MAJOR="1abc"
TC_ROOT_HANDLE="${TC_HANDLE_MAJOR}:"

# 常见默认 root qdisc：可替换，不当作「冲突限速」
# mq 为多队列网卡常见 root（如 AWS ens5）
HARMLESS_QDISC_RE='qdisc (fq_codel|fq|noqueue|pfifo_fast|cake|mq)[[:space:]]'

if [[ -t 1 ]]; then
  R=$'\033[0m' B=$'\033[1m'
  RED=$'\033[31m' GRN=$'\033[32m' YEL=$'\033[33m' CYN=$'\033[36m'
else
  R='' B='' RED='' GRN='' YEL='' CYN=''
fi

log()  { printf '%s[%s]%s %s\n' "$CYN" "$APP_NAME" "$R" "$*"; }
ok()   { printf '%s[%s]%s %s\n' "$GRN" "OK" "$R" "$*"; }
warn() { printf '%s[%s]%s %s\n' "$YEL" "!" "$R" "$*"; }
err()  { printf '%s[%s]%s %s\n' "$RED" "ERR" "$R" "$*" >&2; }
fail() { err "$*"; exit 1; }

read_tty() {
  local prompt="" __var
  while [[ $# -gt 0 ]]; do
    case $1 in
      -p) prompt=$2; shift 2 ;;
      *) break ;;
    esac
  done
  __var=${1:-REPLY}
  if [[ -r /dev/tty ]]; then
    read -r -p "$prompt" "${__var?}" </dev/tty || return 1
  else
    read -r -p "$prompt" "${__var?}" || return 1
  fi
}

require_root() {
  [[ $VPS_TRAFFIC_MOCK == 1 ]] && return 0
  [[ $EUID -eq 0 ]] || fail "请使用 root 运行"
}

# ---------- 安全 KV（禁止 source 任意内容） ----------
# 仅接受 KEY=value；键白名单
load_kv_file() {
  local file=$1
  local line k v
  [[ -f $file ]] || return 0
  while IFS= read -r line || [[ -n $line ]]; do
    [[ $line =~ ^[[:space:]]*# ]] && continue
    [[ $line =~ ^[[:space:]]*$ ]] && continue
    [[ $line =~ ^([A-Z][A-Z0-9_]*)=(.*)$ ]] || continue
    k=${BASH_REMATCH[1]}
    v=${BASH_REMATCH[2]}
    # 去掉可选引号
    if [[ $v =~ ^\"(.*)\"$ ]]; then v=${BASH_REMATCH[1]}; fi
    if [[ $v =~ ^\'(.*)\'$ ]]; then v=${BASH_REMATCH[1]}; fi
    case $k in
      MONTHLY_QUOTA_GB|THRESHOLD_PERCENT|LIMIT_RATE|IFACE|PAUSED|\
      LIMIT_ACTIVE|LIMIT_IFACE|LIMIT_HANDLE|LAST_REASON|LAST_CHECK_TS|LAST_TX_BYTES|\
      LAST_MONTH|LAST_RATIO|OWNED_BY_TOOL)
        printf -v "$k" '%s' "$v"
        ;;
    esac
  done <"$file"
}

ensure_dirs() {
  mkdir -p "$CONFIG_DIR" "$STATE_DIR"
  chmod 755 "$CONFIG_DIR" "$STATE_DIR" 2>/dev/null || true
  if [[ ! -f $CONFIG_FILE ]]; then
    write_config
  fi
  if [[ ! -f $STATE_FILE ]]; then
    LIMIT_ACTIVE=false
    LIMIT_IFACE=
    LIMIT_HANDLE=
    LAST_REASON=
    LAST_CHECK_TS=
    LAST_TX_BYTES=
    LAST_MONTH=
    LAST_RATIO=
    OWNED_BY_TOOL=false
    write_state
  fi
}

load_config() {
  ensure_dirs
  MONTHLY_QUOTA_GB=
  THRESHOLD_PERCENT=90
  LIMIT_RATE=1mbit
  IFACE=auto
  PAUSED=false
  load_kv_file "$CONFIG_FILE"
  THRESHOLD_PERCENT="${THRESHOLD_PERCENT:-90}"
  LIMIT_RATE="${LIMIT_RATE:-1mbit}"
  IFACE="${IFACE:-auto}"
  PAUSED="${PAUSED:-false}"
}

write_config() {
  ensure_dirs
  cat >"$CONFIG_FILE" <<EOF
# vps-traffic 配置（十进制 GB：1 GB = 1000000000 bytes；仅统计 TX）
MONTHLY_QUOTA_GB=${MONTHLY_QUOTA_GB:-}
THRESHOLD_PERCENT=${THRESHOLD_PERCENT:-90}
LIMIT_RATE=${LIMIT_RATE:-1mbit}
IFACE=${IFACE:-auto}
PAUSED=${PAUSED:-false}
EOF
  chmod 644 "$CONFIG_FILE" 2>/dev/null || true
}

load_state() {
  ensure_dirs
  LIMIT_ACTIVE=false
  LIMIT_IFACE=
  LIMIT_HANDLE=
  LAST_REASON=
  LAST_CHECK_TS=
  LAST_TX_BYTES=
  LAST_MONTH=
  LAST_RATIO=
  OWNED_BY_TOOL=false
  load_kv_file "$STATE_FILE"
  LIMIT_ACTIVE="${LIMIT_ACTIVE:-false}"
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
  chmod 644 "$STATE_FILE" 2>/dev/null || true
}

# ---------- 网卡 ----------
detect_default_iface() {
  local out
  if [[ $VPS_TRAFFIC_MOCK == 1 ]]; then
    echo "${MOCK_IFACE:-eth0}"
    return 0
  fi
  out=$($IP_BIN -4 route get 1.1.1.1 2>/dev/null || true)
  if [[ $out =~ [[:space:]]dev[[:space:]]+([^[:space:]]+) ]]; then
    echo "${BASH_REMATCH[1]}"
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
  if [[ -n $iface && $iface != auto ]]; then
    echo "$iface"
    return 0
  fi
  if iface=$(detect_default_iface); then
    echo "$iface"
    return 0
  fi
  warn "无法唯一判断默认出口网卡"
  local -a ifs=()
  mapfile -t ifs < <(list_ifaces)
  [[ ${#ifs[@]} -gt 0 ]] || fail "未找到可用网卡"
  if [[ ${#ifs[@]} -eq 1 ]]; then
    echo "${ifs[0]}"
    return 0
  fi
  local i c
  printf '可选网卡:\n'
  for i in "${!ifs[@]}"; do
    printf '  %s) %s\n' "$((i + 1))" "${ifs[$i]}"
  done
  read_tty -p "请选择网卡编号: " c
  [[ $c =~ ^[0-9]+$ ]] || fail "无效选择"
  i=$((c - 1))
  [[ $i -ge 0 && $i -lt ${#ifs[@]} ]] || fail "无效选择"
  echo "${ifs[$i]}"
}

# ---------- vnStat ----------
require_vnstat_version() {
  [[ $VPS_TRAFFIC_MOCK == 1 ]] && return 0
  command -v "$VNSTAT_BIN" >/dev/null || fail "未安装 vnStat。请先执行菜单「安装流量监控」"
  local ver major minor
  ver=$($VNSTAT_BIN --version 2>&1 | head -n1 || true)
  if [[ $ver =~ ([0-9]+)\.([0-9]+) ]]; then
    major=${BASH_REMATCH[1]}
    minor=${BASH_REMATCH[2]}
  else
    fail "无法解析 vnStat 版本: $ver"
  fi
  if (( major < 2 || (major == 2 && minor < 6) )); then
    fail "需要 vnStat 2.6+，当前: $ver"
  fi
}

# 输出本月 TX 字节；失败非 0
read_monthly_tx_bytes() {
  local iface=$1 json year month_num out rc
  year=$(date +%Y)
  month_num=$((10#$(date +%m)))

  if [[ $VPS_TRAFFIC_MOCK == 1 ]]; then
    [[ -z ${MOCK_VNSTAT_FAIL:-} ]] || return 1
    if [[ -n ${MOCK_YEAR:-} && -n ${MOCK_MONTH:-} ]]; then
      if [[ ${MOCK_YEAR} != "$year" || $((10#${MOCK_MONTH})) -ne $month_num ]]; then
        return 2
      fi
    fi
    [[ -n ${MOCK_TX_BYTES:-} ]] || return 1
    echo "${MOCK_TX_BYTES}"
    return 0
  fi

  json=$($VNSTAT_BIN -i "$iface" --json m 2>/dev/null || true)
  [[ -n $json ]] || return 1
  command -v python3 >/dev/null 2>&1 || return 1

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
for iface in data.get("interfaces") or []:
    months = (iface.get("traffic") or {}).get("month") or (iface.get("traffic") or {}).get("months") or []
    for m in months:
        d = m.get("date") or {}
        if int(d.get("year") or 0) == year and int(d.get("month") or 0) == month:
            tx = m.get("tx")
            if tx is None:
                sys.exit(1)
            print(int(tx))
            sys.exit(0)
sys.exit(2)
')
  rc=$?
  set -e
  [[ $rc -eq 0 && -n $out ]] || return "$rc"
  echo "$out"
}

# ---------- tc ----------
# mock：按网卡分文件，便于模拟默认出口变更
mock_tc_path() {
  local iface=$1
  [[ $iface =~ ^[A-Za-z0-9._-]+$ ]] || iface="invalid"
  printf '%s/%s' "${MOCK_TC_DIR}" "$iface"
}

tc_qdisc_show() {
  local iface=$1
  if [[ $VPS_TRAFFIC_MOCK == 1 ]]; then
    cat "$(mock_tc_path "$iface")" 2>/dev/null || true
    return 0
  fi
  $TC_BIN qdisc show dev "$iface" 2>/dev/null || true
}

has_our_qdisc() {
  local show
  show=$(tc_qdisc_show "$1")
  [[ $show == *"${TC_HANDLE_MAJOR}:"* ]]
}

# 是否存在「会妨碍我们挂 root」的非本工具限速/整形
has_blocking_qdisc() {
  local iface=$1 show line
  show=$(tc_qdisc_show "$iface")
  [[ -n $show ]] || return 1
  has_our_qdisc "$iface" && return 1

  while IFS= read -r line; do
    [[ $line == *root* ]] || continue
    # 无害默认
    if [[ $line =~ $HARMLESS_QDISC_RE ]]; then
      continue
    fi
    # 其它 root（htb/tbf/hfsc/自定义等）视为阻塞
    if [[ $line =~ qdisc[[:space:]]+[^[:space:]]+[[:space:]]+.*root ]]; then
      return 0
    fi
  done <<<"$show"
  return 1
}

# 0 成功；3 冲突；1 失败
apply_limit() {
  local iface=$1 rate=${2:-1mbit}

  if has_our_qdisc "$iface"; then
    log "已存在本工具限速，跳过叠加"
    return 0
  fi
  if has_blocking_qdisc "$iface"; then
    err "检测到非本工具限速/整形 qdisc，跳过以免覆盖"
    LAST_REASON="conflict_foreign_qdisc"
    return 3
  fi

  if [[ $VPS_TRAFFIC_MOCK == 1 ]]; then
    # mock：若存在非无害 root 已在 has_blocking 处理；此处可替换默认 qdisc
    printf 'qdisc tbf %s root refcnt 2 rate %s\n' "${TC_ROOT_HANDLE}" "$rate" >"$(mock_tc_path "$iface")"
    return 0
  fi

  # 无害默认 root（含 mq/fq）：先删再挂本工具 tbf
  local show
  show=$(tc_qdisc_show "$iface")
  if [[ $show == *root* ]] && ! has_our_qdisc "$iface" && ! has_blocking_qdisc "$iface"; then
    $TC_BIN qdisc del dev "$iface" root 2>/dev/null || true
  fi

  if ! $TC_BIN qdisc add dev "$iface" root handle "${TC_ROOT_HANDLE}" tbf \
      rate "$rate" burst 32kbit latency 400ms 2>/tmp/vps-traffic-tc.err; then
    err "tc 添加失败: $(cat /tmp/vps-traffic-tc.err 2>/dev/null || true)"
    LAST_REASON="tc_add_failed"
    return 1
  fi
  has_our_qdisc "$iface" || { LAST_REASON="tc_verify_failed"; return 1; }
  return 0
}

remove_limit() {
  local iface=$1
  load_state

  if ! has_our_qdisc "$iface"; then
    LIMIT_ACTIVE=false
    OWNED_BY_TOOL=false
    LIMIT_HANDLE=
    LIMIT_IFACE=
    write_state
    return 0
  fi

  if [[ $VPS_TRAFFIC_MOCK == 1 ]]; then
    : >"$(mock_tc_path "$iface")"
    LIMIT_ACTIVE=false
    OWNED_BY_TOOL=false
    LIMIT_HANDLE=
    LIMIT_IFACE=
    write_state
    return 0
  fi

  if ! $TC_BIN qdisc del dev "$iface" root handle "${TC_ROOT_HANDLE}" 2>/tmp/vps-traffic-tc.err; then
    err "tc 删除失败: $(cat /tmp/vps-traffic-tc.err 2>/dev/null || true)"
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

# ---------- 检查 ----------
quota_bytes() {
  load_config
  [[ -n ${MONTHLY_QUOTA_GB:-} ]] || return 1
  awk -v g="$MONTHLY_QUOTA_GB" 'BEGIN{printf "%.0f", g * 1000000000}'
}

# 默认出口变更时：先清状态记录的 LIMIT_IFACE 上本工具规则，再按当前网卡决策
reconcile_limit_iface() {
  local current=$1
  local old=${LIMIT_IFACE:-}

  [[ -n $old ]] || return 0
  [[ $old == "$current" ]] && return 0

  log "网卡变更: 记录=${old} → 当前=${current}，清理旧网卡本工具限速"
  if has_our_qdisc "$old"; then
    if ! remove_limit "$old"; then
      warn "清理旧网卡 ${old} 限速失败"
      return 1
    fi
  else
    LIMIT_ACTIVE=false
    OWNED_BY_TOOL=false
    LIMIT_HANDLE=
    LIMIT_IFACE=
    write_state
  fi
  load_state
  return 0
}

run_check() {
  load_config
  load_state

  local iface tx thr_bytes quota ratio_x100 now_ts month_key remove_on
  now_ts=$(date +%s)
  month_key=$(date +%Y-%m)

  if [[ $PAUSED == true || $PAUSED == 1 ]]; then
    LAST_REASON=paused
    LAST_CHECK_TS=$now_ts
    write_state
    log "已暂停，跳过"
    return 0
  fi

  if ! iface=$(resolve_iface 2>/dev/null); then
    LAST_REASON=iface_unresolved
    LAST_CHECK_TS=$now_ts
    write_state
    warn "网卡未解析，不修改 tc"
    return 0
  fi

  # 优先清理记录中的旧网卡，避免遗留 / 双限速
  if ! reconcile_limit_iface "$iface"; then
    LAST_REASON=stale_iface_cleanup_failed
    LAST_CHECK_TS=$now_ts
    write_state
    return 1
  fi

  if ! quota=$(quota_bytes); then
    LAST_REASON=quota_unset
    LAST_CHECK_TS=$now_ts
    write_state
    warn "未设置月额度，不修改 tc"
    return 0
  fi

  set +e
  tx=$(read_monthly_tx_bytes "$iface")
  local trc=$?
  set -e
  if [[ $trc -ne 0 || -z $tx || ! $tx =~ ^[0-9]+$ ]]; then
    LAST_REASON=vnstat_unavailable_or_bad_month
    LAST_CHECK_TS=$now_ts
    write_state
    warn "vnStat 无数据/解析失败 (rc=$trc)，不修改 tc"
    return 0
  fi

  thr_bytes=$(awk -v q="$quota" -v p="$THRESHOLD_PERCENT" 'BEGIN{printf "%.0f", q * p / 100}')
  ratio_x100=$(awk -v t="$tx" -v q="$quota" 'BEGIN{ if(q<=0){print 0; exit} printf "%.2f", t*100/q }')
  LAST_TX_BYTES=$tx
  LAST_MONTH=$month_key
  LAST_RATIO=$ratio_x100
  LAST_CHECK_TS=$now_ts
  log "iface=$iface tx=$tx thr=$thr_bytes ratio=${ratio_x100}% rate=$LIMIT_RATE"

  if (( tx < thr_bytes )); then
    remove_on=${LIMIT_IFACE:-$iface}
    if [[ $LIMIT_ACTIVE == true || $OWNED_BY_TOOL == true ]] || has_our_qdisc "$remove_on" || has_our_qdisc "$iface"; then
      log "低于阈值，解除限速 (iface=${remove_on})"
      if remove_limit "$remove_on"; then
        if [[ $remove_on != "$iface" ]] && has_our_qdisc "$iface"; then
          remove_limit "$iface" || true
        fi
        LAST_REASON=removed_below_threshold
        ok "已解除限速"
      else
        LAST_REASON=remove_failed
        write_state
        return 1
      fi
    else
      LAST_REASON=ok_below_threshold
    fi
    write_state
    return 0
  fi

  if has_our_qdisc "$iface"; then
    LIMIT_ACTIVE=true
    OWNED_BY_TOOL=true
    LIMIT_HANDLE=$TC_ROOT_HANDLE
    LIMIT_IFACE=$iface
    LAST_REASON=already_limited
    write_state
    log "已在限速中"
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
    LAST_REASON=applied_limit
    write_state
    ok "已限速 $LIMIT_RATE on $iface"
    return 0
  fi
  if [[ $arc -eq 3 ]]; then
    LIMIT_ACTIVE=false
    OWNED_BY_TOOL=false
    write_state
    return 0
  fi
  write_state
  return 1
}

with_lock() {
  mkdir -p "$(dirname "$LOCK_FILE")"
  if [[ $VPS_TRAFFIC_MOCK == 1 ]]; then
    "$@"
    return $?
  fi
  exec 9>"$LOCK_FILE"
  if ! flock -n 9; then
    warn "另一检查仍在运行，跳过"
    return 0
  fi
  "$@"
}

# ---------- 安装 / systemd ----------
install_packages() {
  require_root
  command -v apt-get >/dev/null || fail "目前支持 apt 系（Debian/Ubuntu）"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y vnstat iproute2 python3
  require_vnstat_version
  local iface
  iface=$(resolve_iface)
  systemctl enable --now vnstat 2>/dev/null || true
  $VNSTAT_BIN -i "$iface" --add 2>/dev/null || true
  ok "vnStat 就绪，示例网卡: $iface"
}

write_systemd_units() {
  require_root
  local script=$SELF_LOCAL
  [[ -f $script ]] || script=$(readlink -f "${BASH_SOURCE[0]}")
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
  install_packages
  mkdir -p "$LIB_DIR"
  local src
  src=$(readlink -f "${BASH_SOURCE[0]}")
  [[ -f $src ]] && install -m 0755 "$src" "$SELF_LOCAL"
  write_systemd_units
  load_config
  [[ -n $MONTHLY_QUOTA_GB ]] || warn "尚未设置月额度，请执行菜单 2"
  ok "流量监控安装完成"
}

cmd_set_quota() {
  require_root
  load_config
  local g
  read_tty -p "每月流量额度（十进制 GB，如 500）: " g
  [[ $g =~ ^[0-9]+([.][0-9]+)?$ ]] || fail "额度必须是数字"
  MONTHLY_QUOTA_GB=$g
  write_config
  ok "月额度 ${g} GB"
}

cmd_set_threshold() {
  require_root
  load_config
  local p
  read_tty -p "触发比例 %（当前 ${THRESHOLD_PERCENT}）: " p
  if ! [[ $p =~ ^[0-9]+$ ]] || (( p <= 0 || p > 100 )); then
    fail "比例须为 1-100 整数"
  fi
  THRESHOLD_PERCENT=$p
  write_config
  ok "触发比例 ${p}%"
}

cmd_set_rate() {
  require_root
  load_config
  local r
  read_tty -p "限速（如 1mbit，当前 ${LIMIT_RATE}）: " r
  [[ $r =~ ^[0-9]+([.][0-9]+)?[kKmMgG]?bit$ ]] || fail "格式示例: 1mbit"
  LIMIT_RATE=$r
  write_config
  ok "限速 ${r}"
}

# 进度条：pct 0-100；可选 thr（阈值%）决定前景色：<80 绿 / 逼近黄 / ≥阈值 红
progress_bar() {
  local pct=$1 width=${2:-24} thr=${3:-90} fill empty i n col
  if (( pct < 0 )); then pct=0; fi
  if (( pct > 100 )); then pct=100; fi
  n=$((pct * width / 100))
  fill=""
  empty=""
  for ((i = 0; i < n; i++)); do fill+="█"; done
  for ((i = n; i < width; i++)); do empty+="░"; done
  if (( pct >= thr )); then
    col=$RED
  elif (( pct >= 80 )); then
    col=$YEL
  else
    col=$GRN
  fi
  printf '%s%s%s' "$col" "${fill}${empty}" "$R"
}

fmt_reason() {
  case ${1:-} in
    quota_unset) echo "未设置月额度" ;;
    paused) echo "自动检查已暂停" ;;
    ok_below_threshold) echo "低于阈值 · 正常" ;;
    applied_limit) echo "已触发限速" ;;
    already_limited) echo "保持限速" ;;
    removed_below_threshold) echo "已自动解除限速" ;;
    manual_remove) echo "已手动解除" ;;
    conflict_foreign_qdisc) echo "网卡存在其它限速，已跳过" ;;
    vnstat_unavailable_or_bad_month) echo "流量数据暂不可用" ;;
    iface_unresolved) echo "网卡未识别" ;;
    "") echo "—" ;;
    *) echo "$1" ;;
  esac
}

fmt_time() {
  local ts=${1:-}
  if [[ $ts =~ ^[0-9]+$ ]] && (( ts > 1000000000 )); then
    date -d "@$ts" '+%Y-%m-%d %H:%M:%S' 2>/dev/null \
      || date -r "$ts" '+%Y-%m-%d %H:%M:%S' 2>/dev/null \
      || echo "$ts"
  else
    echo "${ts:-—}"
  fi
}

# ---------- UI（无重框线） ----------
ui_init() {
  if [[ -z ${D:-} ]]; then
    if [[ -t 1 ]]; then D=$'\033[2m'; else D=''; fi
  fi
}
ui_head() { printf '\n  %s%s%s  %s%s%s\n' "$B$CYN" "$1" "$R" "$D" "$2" "$R"; }
ui_status() { printf '  %s\n' "$1"; }
ui_gap() { printf '\n'; }
ui_group() { printf '  %s%s%s\n' "$D" "$1" "$R"; }
ui_item() {
  printf '  %s%2s%s  %s\n' "$CYN" "$1" "$R" "$2"
  [[ -n ${3:-} ]] && printf '      %s%s%s\n' "$D" "$3" "$R"
}
ui_kv() { printf '  %s%-8s%s  %s\n' "$D" "$1" "$R" "$2"; }
ui_note() { printf '  %s%s%s\n' "$D" "$1" "$R"; }
ui_foot() { printf '\n'; }
# 状态图例（一行弱化）
ui_legend() {
  printf '  %s%s●%s 正常  %s●%s 接近阈值  %s●%s 限速/超限%s\n' \
    "$D" "$GRN" "$D" "$YEL" "$D" "$RED" "$D" "$R"
}

menu_status_line() {
  load_config
  load_state
  if [[ $LIMIT_ACTIVE == true || $OWNED_BY_TOOL == true ]]; then
    printf '%s●%s  限速中 · %s' "$RED" "$R" "$LIMIT_RATE"
  elif [[ $PAUSED == true ]]; then
    printf '%s○%s  检查已暂停' "$YEL" "$R"
  elif [[ -z ${MONTHLY_QUOTA_GB:-} ]]; then
    printf '%s○%s  待设置额度' "$YEL" "$R"
  else
    printf '%s●%s  正常放行' "$GRN" "$R"
  fi
}

cmd_status() {
  load_config
  load_state
  ui_init
  local iface tx= gb="—" pct=0 bar thr_gb="—" status_txt status_col
  local qdisc_brief paused_txt limit_txt thr=${THRESHOLD_PERCENT:-90}

  set +e
  iface=$(resolve_iface 2>/dev/null)
  set -e
  iface=${iface:-—}

  set +e
  tx=$(read_monthly_tx_bytes "$iface" 2>/dev/null)
  set -e
  if [[ -n ${tx:-} && $tx =~ ^[0-9]+$ ]]; then
    gb=$(awk -v t="$tx" 'BEGIN{printf "%.3f", t/1000000000}')
    if [[ -n ${MONTHLY_QUOTA_GB:-} ]]; then
      pct=$(awk -v t="$tx" -v g="$MONTHLY_QUOTA_GB" 'BEGIN{
        if(g<=0){print 0; exit}
        p=t*100/(g*1000000000)
        if(p>100)p=100
        printf "%.0f", p
      }')
      thr_gb=$(awk -v g="$MONTHLY_QUOTA_GB" -v p="$THRESHOLD_PERCENT" 'BEGIN{printf "%.1f", g*p/100}')
    fi
  else
    gb="—"
    pct=0
  fi

  bar=$(progress_bar "$pct" 24 "$thr")

  if [[ $LIMIT_ACTIVE == true || $OWNED_BY_TOOL == true ]]; then
    status_col=$RED
    status_txt="限速中 · ${LIMIT_RATE}"
  elif [[ $PAUSED == true ]]; then
    status_col=$YEL
    status_txt="检查已暂停"
  elif [[ -z ${MONTHLY_QUOTA_GB:-} ]]; then
    status_col=$YEL
    status_txt="待设置额度"
  elif [[ -n ${tx:-} && -n ${MONTHLY_QUOTA_GB:-} ]] && (( pct >= thr )); then
    status_col=$RED
    status_txt="已达阈值 ${thr}%"
  else
    status_col=$GRN
    status_txt="正常放行"
  fi

  paused_txt=$([[ $PAUSED == true ]] && echo "是" || echo "否")
  limit_txt=$([[ $LIMIT_ACTIVE == true ]] && echo "是" || echo "否")

  qdisc_brief=$(tc_qdisc_show "$iface" 2>/dev/null | head -n1 | sed 's/^[[:space:]]*//' || true)
  [[ -n $qdisc_brief ]] || qdisc_brief="—"
  if (( ${#qdisc_brief} > 42 )); then
    qdisc_brief="${qdisc_brief:0:39}..."
  fi

  ui_head "流量" "v${VERSION}"
  ui_status "${status_col}●${R}  ${B}${status_txt}${R}"
  ui_legend
  ui_gap
  if [[ -n ${MONTHLY_QUOTA_GB:-} ]]; then
    printf '  %s  %s%s%%%s\n' "$bar" "$B" "$pct" "$R"
    ui_kv "用量" "${B}${gb}${R} / ${MONTHLY_QUOTA_GB} GB"
    ui_kv "阈值" "${thr_gb} GB @ ${thr}%"
  else
    ui_kv "用量" "${B}${gb}${R} GB"
    ui_note "月额度未设置 → 菜单选 2"
  fi
  ui_gap
  ui_kv "网卡" "$iface"
  ui_kv "限速" "${LIMIT_RATE} · 自动检查 ${paused_txt} · 当前 ${limit_txt}"
  ui_kv "规则" "$([[ $OWNED_BY_TOOL == true ]] && echo 本工具 || echo 无) · ${LIMIT_HANDLE:-—}"
  ui_kv "检查" "$(fmt_time "${LAST_CHECK_TS:-}") · $(fmt_reason "${LAST_REASON:-}")"
  ui_kv "队列" "$qdisc_brief"
  ui_gap
  ui_note "说明: ${LIMIT_RATE} 约 10.8 GB/天量级；vnStat 与云厂商可能有误差"
  ui_foot
}

cmd_check_now() { require_root; with_lock run_check; }

cmd_remove_limit() {
  require_root
  load_config
  load_state
  local iface=${LIMIT_IFACE:-}
  [[ -n $iface ]] || iface=$(resolve_iface)
  with_lock remove_limit "$iface"
  LAST_REASON=manual_remove
  write_state
  if [[ $PAUSED != true ]]; then
    warn "自动检查仍开：超阈值时下次 timer 会再限速。持续解除请先暂停自动检查。"
  fi
  ok "已尝试解除本工具限速"
}

cmd_pause() {
  require_root
  load_config
  PAUSED=true
  write_config
  if [[ $VPS_TRAFFIC_MOCK != 1 ]]; then
    systemctl stop vps-traffic-check.timer 2>/dev/null || true
    systemctl disable vps-traffic-check.timer 2>/dev/null || true
  fi
  ok "已暂停自动检查"
}

cmd_resume() {
  require_root
  load_config
  PAUSED=false
  write_config
  if [[ $VPS_TRAFFIC_MOCK != 1 ]]; then
    write_systemd_units
    systemctl start vps-traffic-check.timer 2>/dev/null || true
  fi
  ok "已恢复，立即检查"
  with_lock run_check
}

cmd_update_module() {
  require_root
  local url="${RAW_BASE}/traffic.sh" tmp bak
  tmp=$(mktemp)
  bak="${SELF_LOCAL}.bak.$(date +%s)"
  curl -fsSL --connect-timeout 20 --max-time 120 "$url" -o "$tmp" || {
    rm -f "$tmp"
    fail "下载失败: $url"
  }
  [[ -s $tmp ]] || { rm -f "$tmp"; fail "下载为空"; }
  bash -n "$tmp" || { rm -f "$tmp"; fail "bash -n 失败，保留旧版"; }
  mkdir -p "$LIB_DIR"
  [[ -f $SELF_LOCAL ]] && cp -a "$SELF_LOCAL" "$bak"
  install -m 0755 "$tmp" "$SELF_LOCAL"
  rm -f "$tmp"
  write_systemd_units
  ok "流量模块已更新"
}

cmd_uninstall() {
  require_root
  local ans keep_vnstat iface
  read_tty -p "确认卸载流量模块？不影响代理/v2/vps [y/N]: " ans
  [[ $ans == y || $ans == Y ]] || { log "已取消"; return 0; }

  load_state
  iface=${LIMIT_IFACE:-}
  [[ -n $iface ]] || { set +e; iface=$(resolve_iface 2>/dev/null); set -e; }
  [[ -n ${iface:-} ]] && remove_limit "$iface" || true

  if [[ $VPS_TRAFFIC_MOCK != 1 ]]; then
    systemctl disable --now vps-traffic-check.timer 2>/dev/null || true
    systemctl disable --now vps-traffic-check.service 2>/dev/null || true
    rm -f "$UNIT_SERVICE" "$UNIT_TIMER"
    systemctl daemon-reload || true
  fi
  rm -rf "$CONFIG_DIR" "$STATE_DIR"
  rm -f "$LOCK_FILE"

  read_tty -p "是否保留 vnStat 软件包？[Y/n]: " keep_vnstat
  if [[ $keep_vnstat == n || $keep_vnstat == N ]]; then
    command -v apt-get >/dev/null && apt-get remove -y vnstat || true
  fi
  read_tty -p "删除 ${SELF_LOCAL}？[y/N]: " ans
  [[ $ans == y || $ans == Y ]] && rm -f "$SELF_LOCAL"
  ok "流量模块已卸载"
}

main_menu() {
  local c st
  ui_init
  while true; do
    st=$(menu_status_line)
    ui_head "流量" "v${VERSION}"
    ui_status "$st"
    ui_gap
    ui_group "监控"
    ui_item 1 "安装流量监控"
    ui_item 2 "设置每月流量额度"
    ui_item 3 "查看状态"
    ui_gap
    ui_group "策略"
    ui_item 4 "修改触发比例"
    ui_item 5 "修改限速速度"
    ui_gap
    ui_group "运维"
    ui_item 6 "立即检查"
    ui_item 7 "解除当前限速"
    ui_item 8 "暂停自动检查"
    ui_item 9 "恢复自动检查"
    ui_gap
    ui_group "系统"
    ui_item 10 "更新流量模块"
    ui_item 11 "卸载流量模块"
    ui_item 0 "返回"
    ui_foot
    c=""
    read_tty -p "  › " c || c=0
    case $c in
      1) cmd_install ;;
      2) cmd_set_quota ;;
      3) cmd_status ;;
      4) cmd_set_threshold ;;
      5) cmd_set_rate ;;
      6) cmd_check_now ;;
      7) cmd_remove_limit ;;
      8) cmd_pause ;;
      9) cmd_resume ;;
      10) cmd_update_module ;;
      11) cmd_uninstall; return 0 ;;
      0) return 0 ;;
      *) warn "无效选项"; continue ;;
    esac
    [[ $c == 0 || $c == 11 ]] || read_tty -p "  按回车继续…" _ || true
  done
}

usage() {
  cat <<EOF
${APP_NAME} v${VERSION}
  bash traffic.sh           菜单
  bash traffic.sh --check   检查一轮（systemd）
依赖: vnStat 2.6+、python3、iproute2
tc handle: ${TC_ROOT_HANDLE}
EOF
}

main() {
  case ${1:-menu} in
    -h|--help|help) usage ;;
    --check|check) require_root; with_lock run_check ;;
    --status|status) cmd_status ;;
    menu|"") main_menu ;;
    *) fail "未知命令: $1" ;;
  esac
}

if [[ -z ${BASH_SOURCE[0]:-} || ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
