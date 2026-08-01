#!/usr/bin/env bash
# vps-traffic — 独立流量监控与出口限速（与 proxy 完全隔离）
# tc root handle: 1abc: （十六进制 major，见 README）
set -Eeuo pipefail

APP_NAME="vps-traffic"
VERSION="1.4.1"
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
  R=$'\033[0m' B=$'\033[1m' D=$'\033[2m'
  RED=$'\033[31m' GRN=$'\033[32m' YEL=$'\033[33m' CYN=$'\033[36m'
else
  R='' B='' D='' RED='' GRN='' YEL='' CYN=''
fi

log()  { printf '  %s!%s  %s\n' "$D" "$R" "$*"; }
ok()   { printf '  %s●%s  %s\n' "$GRN" "$R" "$*"; }
warn() { printf '  %s!%s  %s\n' "$YEL" "$R" "$*"; }
err()  { printf '  %s×%s  %s\n' "$RED" "$R" "$*" >&2; }
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
  # 管道启动时 stdin 非终端，交互走 /dev/tty
  if [[ -r /dev/tty ]]; then
    printf '%s' "$prompt" >/dev/tty 2>/dev/null || printf '%s' "$prompt"
    read -r "${__var?}" </dev/tty || return 1
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

# 仅创建目录，禁止调用 write_*（避免与 write_* 递归）
ensure_dirs() {
  mkdir -p "$CONFIG_DIR" "$STATE_DIR"
  chmod 755 "$CONFIG_DIR" "$STATE_DIR" 2>/dev/null || true
}

# 原子写：临时文件 → 校验非空 → mv 替换（只保证父目录存在）
atomic_write_file() {
  local dest=$1 mode=${2:-644} tmp dir
  dir=$(dirname "$dest")
  mkdir -p "$dir"
  tmp=$(mktemp "${dest}.XXXXXX")
  cat >"$tmp" || { rm -f "$tmp"; return 1; }
  [[ -s $tmp ]] || { rm -f "$tmp"; return 1; }
  chmod "$mode" "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$dest"
}

write_config() {
  # 禁止调用 ensure_dirs 的初始化逻辑
  mkdir -p "$CONFIG_DIR"
  atomic_write_file "$CONFIG_FILE" 644 <<EOF
# vps-traffic 配置（十进制 GB：1 GB = 1000000000 bytes；仅统计 TX）
MONTHLY_QUOTA_GB=${MONTHLY_QUOTA_GB:-}
THRESHOLD_PERCENT=${THRESHOLD_PERCENT:-90}
LIMIT_RATE=${LIMIT_RATE:-1mbit}
IFACE=${IFACE:-auto}
PAUSED=${PAUSED:-false}
EOF
}

write_state() {
  mkdir -p "$STATE_DIR"
  atomic_write_file "$STATE_FILE" 644 <<EOF
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
}

init_config_if_missing() {
  ensure_dirs
  if [[ ! -f $CONFIG_FILE ]]; then
    MONTHLY_QUOTA_GB=${MONTHLY_QUOTA_GB:-}
    THRESHOLD_PERCENT=${THRESHOLD_PERCENT:-90}
    LIMIT_RATE=${LIMIT_RATE:-1mbit}
    IFACE=${IFACE:-auto}
    PAUSED=${PAUSED:-false}
    write_config
  fi
}

init_state_if_missing() {
  ensure_dirs
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
  init_config_if_missing
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

load_state() {
  ensure_dirs
  init_state_if_missing
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
  if [[ ${VPS_TRAFFIC_MOCK:-0} == 1 ]]; then
    : >"${STATE_DIR}/.installed"
    : >"${STATE_DIR}/.timer_enabled"
    : >"${STATE_DIR}/.timer_active"
  fi
  load_config
  [[ -n $MONTHLY_QUOTA_GB ]] || warn "尚未设置月额度，请使用「修改流量设置」"
  ok "流量监控安装完成"
}

# 合并额度 / 触发比例 / 限速：回车保持当前值，最后统一确认并原子写入
cmd_settings() {
  require_root
  load_config
  local g p r ans
  local cur_g=${MONTHLY_QUOTA_GB:-} cur_p=${THRESHOLD_PERCENT:-90} cur_r=${LIMIT_RATE:-1mbit}
  local show_g

  if [[ -n $cur_g ]]; then
    show_g="${cur_g} GB"
  else
    show_g="未设置"
  fi

  ui_head "修改流量设置" ""
  ui_gap
  read_tty -p "  每月额度 [${show_g}]: " g || true
  g=${g//[[:space:]]/}
  if [[ -z $g ]]; then
    g=$cur_g
  else
    g=${g%GB}
    g=${g%gb}
    g=${g//[[:space:]]/}
    [[ $g =~ ^[0-9]+([.][0-9]+)?$ ]] || fail "额度必须是数字"
  fi

  read_tty -p "  触发比例 [${cur_p}%]: " p || true
  p=${p//[[:space:]]/}
  p=${p%%%}
  if [[ -z $p ]]; then
    p=$cur_p
  else
    if ! [[ $p =~ ^[0-9]+$ ]] || (( p <= 0 || p > 100 )); then
      fail "比例须为 1-100 整数"
    fi
  fi

  # 展示用 1 Mbit/s，内部仍存 1mbit
  local show_r=$cur_r
  if [[ $cur_r =~ ^([0-9]+([.][0-9]+)?)mbit$ ]]; then
    show_r="${BASH_REMATCH[1]} Mbit/s"
  fi
  read_tty -p "  限速速度 [${show_r}]: " r || true
  r=${r//[[:space:]]/}
  if [[ -z $r ]]; then
    r=$cur_r
  else
    r=${r//Mbit\/s/mbit}
    r=${r//mbit\/s/mbit}
    r=${r// /}
    [[ $r =~ ^[0-9]+([.][0-9]+)?[kKmMgG]?bit$ ]] || fail "格式示例: 1mbit 或 1 Mbit/s"
  fi

  read_tty -p "  保存修改？[Y/n]: " ans || true
  ans=${ans//[[:space:]]/}
  if [[ $ans == n || $ans == N ]]; then
    warn "已取消"
    return 0
  fi
  MONTHLY_QUOTA_GB=$g
  THRESHOLD_PERCENT=$p
  LIMIT_RATE=$r
  write_config
  ok "设置已保存"
}

# 是否已安装流量监控（timer/unit；mock 用 .installed 标记）
# 模块脚本/标记已落地
traffic_is_installed() {
  if [[ ${VPS_TRAFFIC_MOCK:-0} == 1 ]]; then
    [[ -f ${STATE_DIR}/.installed ]]
    return
  fi
  [[ -f $UNIT_TIMER || -f $UNIT_SERVICE || -f $SELF_LOCAL ]]
}

# timer 单元是否 enabled
traffic_timer_enabled() {
  if [[ ${VPS_TRAFFIC_MOCK:-0} == 1 ]]; then
    [[ -f ${STATE_DIR}/.timer_enabled ]]
    return
  fi
  systemctl is-enabled --quiet vps-traffic-check.timer 2>/dev/null
}

# timer 是否 active（running/waiting）
traffic_timer_active() {
  if [[ ${VPS_TRAFFIC_MOCK:-0} == 1 ]]; then
    [[ -f ${STATE_DIR}/.timer_active ]]
    return
  fi
  systemctl is-active --quiet vps-traffic-check.timer 2>/dev/null
}

# 是否存在本工具限速（state 或 qdisc，只读）
traffic_is_limiting() {
  load_config
  load_state
  local iface=""
  if [[ $LIMIT_ACTIVE == true || $OWNED_BY_TOOL == true ]]; then
    return 0
  fi
  set +e
  iface=$(resolve_iface 2>/dev/null)
  set -e
  [[ -n ${iface:-} ]] && has_our_qdisc "$iface" && return 0
  [[ -n ${LIMIT_IFACE:-} ]] && has_our_qdisc "$LIMIT_IFACE" && return 0
  return 1
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

# ---------- UI（无重框线） ----------
ui_init() {
  if [[ -z ${D:-} ]]; then
    if [[ -t 1 ]]; then D=$'\033[2m'; else D=''; fi
  fi
}
ui_head() { printf '\n  %s%s%s  %s%s%s\n' "$B$CYN" "$1" "$R" "$D" "$2" "$R"; }
ui_status() { printf '  %s\n' "$1"; }
ui_gap() { printf '\n'; }
# $1 序号 $2 文案 $3 可选 danger|muted — 序号后带 .
ui_item() {
  local num=$1 text=$2 style=${3:-} nc=$CYN tc=
  case $style in
    danger) nc=$RED; tc=$RED ;;
    muted)  nc=$D; tc=$D ;;
  esac
  printf '  %s%2s.%s  %s%s%s\n' "$nc" "$num" "$R" "$tc" "$text" "$R"
}
ui_kv() { printf '  %s%-8s%s  %s\n' "$D" "$1" "$R" "$2"; }
ui_note() { printf '  %s%s%s\n' "$D" "$1" "$R"; }
ui_foot() { printf '\n'; }
# 状态图例（一行弱化）
# 本工具限速 qdisc 是否在网卡上（只读，不改 tc）
limit_qdisc_present() {
  local iface=$1
  [[ -n $iface && $iface != — ]] || return 1
  has_our_qdisc "$iface" && return 0
  if [[ -n ${LIMIT_IFACE:-} && $LIMIT_IFACE != "$iface" ]]; then
    has_our_qdisc "$LIMIT_IFACE" && return 0
  fi
  return 1
}

# 菜单顶栏：未安装 / 限速 / 暂停 / 用量摘要（只读，不改 tc）
menu_status_line() {
  load_config
  load_state
  local iface="" thr=${THRESHOLD_PERCENT:-90} tx= gb="—"

  if ! traffic_is_installed; then
    printf '%s○%s  尚未安装' "$D" "$R"
    return 0
  fi

  # timer 未启用/未激活：仅状态警告，不改菜单与限速算法
  local timer_note=""
  if ! traffic_timer_enabled; then
    timer_note=" · 定时器未启用"
  elif ! traffic_timer_active; then
    timer_note=" · 定时器未运行"
  fi

  set +e
  iface=$(resolve_iface 2>/dev/null)
  set -e

  if [[ $LIMIT_ACTIVE == true || $OWNED_BY_TOOL == true ]]; then
    if limit_qdisc_present "${iface:-}"; then
      printf '%s●%s  限速中 · %s%s' "$RED" "$R" "$LIMIT_RATE" "$timer_note"
      return 0
    fi
    printf '%s!%s  状态需检查%s' "$YEL" "$R" "$timer_note"
    return 0
  fi

  if [[ $PAUSED == true ]]; then
    printf '%s○%s  检查已暂停%s' "$YEL" "$R" "$timer_note"
    return 0
  fi

  if [[ -z ${MONTHLY_QUOTA_GB:-} ]]; then
    printf '%s○%s  待设置额度%s' "$YEL" "$R" "$timer_note"
    return 0
  fi

  set +e
  tx=$(read_monthly_tx_bytes "${iface:-}" 2>/dev/null)
  set -e
  if [[ -n ${tx:-} && $tx =~ ^[0-9]+$ ]]; then
    gb=$(awk -v t="$tx" 'BEGIN{printf "%.1f", t/1000000000}')
  fi
  if [[ -n $timer_note ]]; then
    printf '%s!%s  正常  %s / %s GB%s' "$YEL" "$R" "$gb" "$MONTHLY_QUOTA_GB" "$timer_note"
  else
    printf '%s●%s  正常  %s / %s GB' "$GRN" "$R" "$gb" "$MONTHLY_QUOTA_GB"
  fi
}

# 友好时间：今天 HH:MM 或完整日期
fmt_time_friendly() {
  local ts=${1:-} today full hm
  [[ -n $ts && $ts =~ ^[0-9]+$ ]] || { echo "—"; return; }
  today=$(date '+%Y-%m-%d' 2>/dev/null || true)
  full=$(date -d "@$ts" '+%Y-%m-%d %H:%M' 2>/dev/null \
    || date -r "$ts" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "$ts")
  hm=$(date -d "@$ts" '+%H:%M' 2>/dev/null || date -r "$ts" '+%H:%M' 2>/dev/null || true)
  if [[ $full == ${today}* && -n $hm ]]; then
    echo "今天 $hm"
  else
    echo "$full"
  fi
}

cmd_status() {
  load_config
  load_state
  ui_init
  local iface tx= gb="—" pct=0 thr=${THRESHOLD_PERCENT:-90}
  local paused_txt rate_show
  local show_debug=${TRAFFIC_STATUS_VERBOSE:-0}
  local qdisc_brief="" limit_ok=0 data_ok=0
  local status_txt status_col status_mark bar

  set +e
  iface=$(resolve_iface 2>/dev/null)
  set -e
  iface=${iface:-—}

  set +e
  tx=$(read_monthly_tx_bytes "$iface" 2>/dev/null)
  set -e
  if [[ -n ${tx:-} && $tx =~ ^[0-9]+$ ]]; then
    data_ok=1
    gb=$(awk -v t="$tx" 'BEGIN{printf "%.1f", t/1000000000}')
    if [[ -n ${MONTHLY_QUOTA_GB:-} ]]; then
      pct=$(awk -v t="$tx" -v g="$MONTHLY_QUOTA_GB" 'BEGIN{
        if(g<=0){print 0; exit}
        p=t*100/(g*1000000000)
        if(p>100)p=100
        printf "%.0f", p
      }')
    fi
  fi

  if limit_qdisc_present "$iface"; then
    limit_ok=1
  fi

  rate_show=$LIMIT_RATE
  if [[ $LIMIT_RATE =~ ^([0-9]+([.][0-9]+)?)mbit$ ]]; then
    rate_show="${BASH_REMATCH[1]} Mbit/s"
  fi

  if [[ $LIMIT_ACTIVE == true || $OWNED_BY_TOOL == true ]]; then
    if (( limit_ok )); then
      status_col=$RED
      status_mark="!"
      status_txt="正在限速"
    else
      status_col=$YEL
      status_mark="!"
      status_txt="状态需检查"
      show_debug=1
    fi
  elif [[ $PAUSED == true ]]; then
    status_col=$YEL
    status_mark="○"
    status_txt="检查已暂停"
  elif [[ -z ${MONTHLY_QUOTA_GB:-} ]]; then
    status_col=$YEL
    status_mark="○"
    status_txt="待设置额度"
  elif (( !data_ok )); then
    status_col=$YEL
    status_mark="!"
    status_txt="用量数据暂不可用"
  elif (( pct >= thr )); then
    status_col=$YEL
    status_mark="!"
    status_txt="接近阈值"
  else
    status_col=$GRN
    status_mark="●"
    status_txt="正常"
  fi

  if [[ $iface != — ]] && has_blocking_qdisc "$iface" 2>/dev/null; then
    show_debug=1
  fi

  if [[ $PAUSED == true ]]; then
    paused_txt="已暂停"
  else
    paused_txt="已开启"
  fi

  ui_head "流量状态" ""
  ui_status "${status_col}${status_mark}${R}  ${status_txt}"
  ui_gap

  if (( data_ok )) && [[ -n ${MONTHLY_QUOTA_GB:-} ]]; then
    ui_kv "本月用量" "${gb} / ${MONTHLY_QUOTA_GB} GB"
    bar=$(progress_bar "$pct" 16 "$thr")
    printf '  %s  %s%%\n' "$bar" "$pct"
    ui_gap
  elif (( !data_ok )); then
    ui_note "! 无法读取本月用量（不会按 0 处理）"
    ui_gap
  elif [[ -z ${MONTHLY_QUOTA_GB:-} ]]; then
    ui_kv "本月用量" "${gb} GB"
    ui_note "提示：请先设置每月流量额度"
    ui_gap
  fi

  if [[ $status_txt == "正在限速" ]]; then
    ui_kv "当前速度" "$rate_show"
  else
    ui_kv "触发限速" "${thr}%"
    ui_kv "限速速度" "$rate_show"
  fi
  ui_kv "统计范围" "出站 TX"
  ui_kv "自动检查" "$paused_txt"
  ui_kv "最后检查" "$(fmt_time_friendly "${LAST_CHECK_TS:-}")"

  if (( show_debug )); then
    ui_gap
    ui_kv "网卡" "$iface"
    ui_kv "规则" "$([[ $OWNED_BY_TOOL == true ]] && echo 本工具 || echo 无) · ${LIMIT_HANDLE:-—}"
    qdisc_brief=$(tc_qdisc_show "$iface" 2>/dev/null | head -n1 | sed 's/^[[:space:]]*//' || true)
    [[ -n $qdisc_brief ]] || qdisc_brief="—"
    if (( ${#qdisc_brief} > 56 )); then
      qdisc_brief="${qdisc_brief:0:53}..."
    fi
    ui_kv "队列" "$qdisc_brief"
  fi
  ui_foot
}

cmd_check_now() { require_root; with_lock run_check; }

cmd_remove_limit() {
  require_root
  load_config
  load_state
  local iface=${LIMIT_IFACE:-} show
  [[ -n $iface ]] || iface=$(resolve_iface)
  [[ -n $iface ]] || fail "无法确定网卡，拒绝解除限速"

  # 解除前确认：网卡上确有本工具 handle 的 qdisc
  show=$(tc_qdisc_show "$iface" 2>/dev/null || true)
  if [[ $show != *"${TC_HANDLE_MAJOR}:"* ]]; then
    if [[ -n ${LIMIT_IFACE:-} && $LIMIT_IFACE != "$iface" ]]; then
      show=$(tc_qdisc_show "$LIMIT_IFACE" 2>/dev/null || true)
      if [[ $show == *"${TC_HANDLE_MAJOR}:"* ]]; then
        iface=$LIMIT_IFACE
      else
        warn "网卡 ${iface} 上未发现本工具限速规则 (${TC_ROOT_HANDLE})，仅清理状态"
        LIMIT_ACTIVE=false
        LIMIT_IFACE=
        LIMIT_HANDLE=
        OWNED_BY_TOOL=false
        LAST_REASON=manual_remove
        write_state
        return 0
      fi
    else
      warn "网卡 ${iface} 上未发现本工具限速规则 (${TC_ROOT_HANDLE})，仅清理状态"
      LIMIT_ACTIVE=false
      LIMIT_IFACE=
      LIMIT_HANDLE=
      OWNED_BY_TOOL=false
      LAST_REASON=manual_remove
      write_state
      return 0
    fi
  fi

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
  read_tty -p "确认卸载流量模块？不影响代理/vps [y/N]: " ans
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

# 动态菜单：编号仅展示，路由走 action 映射
# 更多：限速时首项「解除」；始终含更新 / 卸载（卸载红色置底）
menu_more() {
  local c actions=() labels=() styles=() i n act
  while true; do
    actions=()
    labels=()
    styles=()
    load_config
    load_state
    if traffic_is_limiting; then
      actions+=(remove_limit)
      labels+=("解除当前限速")
      styles+=("")
    fi
    actions+=(update)
    labels+=("更新流量模块")
    styles+=("")
    actions+=(uninstall)
    labels+=("卸载流量模块")
    styles+=("danger")

    ui_head "更多操作" ""
    ui_gap
    n=${#actions[@]}
    for ((i = 0; i < n; i++)); do
      ui_item "$((i + 1))" "${labels[i]}" "${styles[i]}"
    done
    ui_gap
    ui_item 0 "返回" muted
    ui_gap
    printf '  请选择 [0-%s]: ' "$n"
    c=""
    if ! read_tty c; then
      warn "读取输入失败"
      return 1
    fi
    c=${c//[[:space:]]/}
    if [[ $c == 0 || -z $c ]]; then
      return 0
    fi
    if ! [[ $c =~ ^[0-9]+$ ]] || (( c < 1 || c > n )); then
      warn "无效选项"
      continue
    fi
    act=${actions[c - 1]}
    case $act in
      remove_limit) cmd_remove_limit ;;
      update) cmd_update_module ;;
      uninstall) cmd_uninstall; return 0 ;;
    esac
    [[ $act == uninstall ]] || read_tty -p "  按回车继续…" _ || true
  done
}

main_menu() {
  local c st i n act
  local actions labels styles
  ui_init
  while true; do
    load_config
    load_state
    st=$(menu_status_line)
    ui_head "流量管理" "v${VERSION}"
    ui_status "$st"
    ui_gap

    actions=()
    labels=()
    styles=()

    if ! traffic_is_installed; then
      actions=(install)
      labels=("安装流量监控")
      styles=("")
    else
      actions+=(status)
      labels+=("查看状态")
      styles+=("")
      actions+=(settings)
      labels+=("修改流量设置")
      styles+=("")
      actions+=(check)
      labels+=("立即检查")
      styles+=("")
      if [[ $PAUSED == true ]]; then
        actions+=(resume)
        labels+=("恢复自动检查")
        styles+=("")
      else
        actions+=(pause)
        labels+=("暂停自动检查")
        styles+=("")
      fi
      actions+=(more)
      labels+=("更多操作")
      styles+=("")
    fi

    n=${#actions[@]}
    for ((i = 0; i < n; i++)); do
      ui_item "$((i + 1))" "${labels[i]}" "${styles[i]}"
    done
    ui_gap
    ui_item 0 "返回" muted
    ui_gap
    printf '  请选择 [0-%s]: ' "$n"
    c=""
    if ! read_tty c; then
      warn "读取输入失败，返回上级"
      return 1
    fi
    c=${c//[[:space:]]/}
    if [[ $c == 0 || -z $c ]]; then
      return 0
    fi
    if ! [[ $c =~ ^[0-9]+$ ]] || (( c < 1 || c > n )); then
      warn "无效选项"
      continue
    fi
    act=${actions[c - 1]}
    case $act in
      install) cmd_install ;;
      status) cmd_status ;;
      settings) cmd_settings ;;
      check) cmd_check_now ;;
      pause) cmd_pause ;;
      resume) cmd_resume ;;
      more) menu_more ;;
      *) warn "无效选项"; continue ;;
    esac
    [[ $act == more ]] || read_tty -p "  按回车继续…" _ || true
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
    --verbose|status-debug|--status-debug)
      TRAFFIC_STATUS_VERBOSE=1
      cmd_status
      ;;
    menu|"") main_menu ;;
    *) fail "未知命令: $1" ;;
  esac
}

if [[ -z ${BASH_SOURCE[0]:-} || ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
