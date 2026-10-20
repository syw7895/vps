# shellcheck shell=bash
# 流量：网卡用量统计、月额度、tc 限速；各节点流量统计；5 分钟定时任务

TRAFFIC_STATE=$VAR_DIR/traffic.state
STATS_STATE=$VAR_DIR/stats.state
TC_HANDLE=5650:

# ---------- 周期 ----------
# period_start 时间戳 重置日 → 本周期开始日期 YYYY-MM-DD
period_start() {
  local ts=$1 rd=$2 y m d
  read -r y m d < <(date -d "@$ts" '+%Y %-m %-d')
  if ((d < rd)); then
    m=$((m - 1))
    if ((m == 0)); then m=12; y=$((y - 1)); fi
  fi
  printf '%04d-%02d-%02d' "$y" "$m" "$rd"
}

period_next() { date -d "$1 +1 month" +%F; }

reset_day() {
  local rd
  rd=$(kv_get "$TRAFFIC_CONF" RESET_DAY 1)
  if ! [[ $rd =~ ^[0-9]+$ ]] || ((rd < 1 || rd > 28)); then rd=1; fi
  printf '%s' "$rd"
}

current_period() { period_start "$(now)" "$(reset_day)"; }

# ---------- 网卡 ----------
traffic_iface() {
  local ifc
  ifc=$(kv_get "$TRAFFIC_CONF" IFACE)
  if [[ -z $ifc ]]; then
    ifc=$(ip -o -4 route show default 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "dev") {print $(i + 1); exit}}')
    [[ -n $ifc ]] || ifc=$(ip -o -6 route show default 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "dev") {print $(i + 1); exit}}')
  fi
  [[ -n $ifc && -d $NET_DIR/$ifc ]] && printf '%s' "$ifc"
}

# counters 网卡 → "发送字节 接收字节"
counters() {
  local tx rx
  tx=$(cat "$NET_DIR/$1/statistics/tx_bytes" 2>/dev/null) || return 1
  rx=$(cat "$NET_DIR/$1/statistics/rx_bytes" 2>/dev/null) || return 1
  [[ $tx =~ ^[0-9]+$ && $rx =~ ^[0-9]+$ ]] || return 1
  printf '%s %s\n' "$tx" "$rx"
}

boot_id() { cat "$BOOT_ID_FILE" 2>/dev/null || echo unknown; }

traffic_configured() { [[ -n $(kv_get "$TRAFFIC_CONF" QUOTA_GB) ]]; }

# 把网卡计数器的增量累加进本周期用量（只改数组，不落盘）
traffic_accumulate() {
  local -n __st=$1
  local ifc tx rx boot period
  period=$(current_period)
  if [[ ${__st[PERIOD]:-} != "$period" ]]; then
    __st[PERIOD]=$period
    __st[USED_TX]=0
    __st[USED_RX]=0
    __st[SKIP]=""
  fi
  ifc=$(traffic_iface) || { __st[NOTE]=no_iface; return 0; }
  read -r tx rx < <(counters "$ifc") || { __st[NOTE]=no_iface; return 0; }
  boot=$(boot_id)
  if [[ ${__st[LAST_IF]:-} == "$ifc" && ${__st[BOOT]:-} == "$boot" ]] &&
    ((tx >= ${__st[LAST_TX]:-0} && rx >= ${__st[LAST_RX]:-0})); then
    __st[USED_TX]=$((${__st[USED_TX]:-0} + tx - ${__st[LAST_TX]:-0}))
    __st[USED_RX]=$((${__st[USED_RX]:-0} + rx - ${__st[LAST_RX]:-0}))
  elif [[ ${__st[LAST_IF]:-} == "$ifc" ]]; then
    # 重启过：计数器从 0 开始，开机以来的都算本周期
    __st[USED_TX]=$((${__st[USED_TX]:-0} + tx))
    __st[USED_RX]=$((${__st[USED_RX]:-0} + rx))
  fi
  __st[LAST_IF]=$ifc
  __st[LAST_TX]=$tx
  __st[LAST_RX]=$rx
  __st[BOOT]=$boot
}

# used_bytes 状态数组名 → 按统计方向计算的已用字节
used_bytes() {
  local -n __ub=$1
  case $(kv_get "$TRAFFIC_CONF" COUNT tx) in
    rx) printf '%s' "${__ub[USED_RX]:-0}" ;;
    both) printf '%s' "$((${__ub[USED_TX]:-0} + ${__ub[USED_RX]:-0}))" ;;
    *) printf '%s' "${__ub[USED_TX]:-0}" ;;
  esac
}

quota_bytes() { awk -v g="$(kv_get "$TRAFFIC_CONF" QUOTA_GB 0)" 'BEGIN {printf "%.0f", g * 1000000000}'; }

threshold_bytes() {
  awk -v q="$(quota_bytes)" -v p="$(kv_get "$TRAFFIC_CONF" PERCENT 90)" 'BEGIN {printf "%.0f", q * p / 100}'
}

# ---------- tc 限速 ----------
tc_root() { tc qdisc show dev "$1" root 2>/dev/null | head -n1; }

# tc_limit 网卡 速度(Mbit)：返回 0 成功，2 有别的限速规则（不覆盖），1 失败
tc_limit() {
  local ifc=$1 kbit burst line kind handle
  kbit=$(awk -v r="$2" 'BEGIN {printf "%d", r * 1000}')
  ((kbit >= 8)) || kbit=8
  burst=$((kbit * 1000 / 8 / 50))
  ((burst >= 16384)) || burst=16384
  line=$(tc_root "$ifc")
  kind=$(awk '{print $2}' <<<"$line")
  handle=$(awk '{print $3}' <<<"$line")
  if [[ $handle != "$TC_HANDLE" ]]; then
    case $kind in
      "" | pfifo_fast | fq_codel | fq | mq | noqueue | cake | sfq | pfifo | bfifo) ;;
      *) return 2 ;;
    esac
    TC_ORIG=$kind
  fi
  tc qdisc replace dev "$ifc" root handle "$TC_HANDLE" tbf rate "${kbit}kbit" burst "$burst" latency 100ms \
    >/dev/null 2>&1 || return 1
}

# tc_unlimit 网卡 原队列：删掉本工具的规则，恢复原来的队列类型
tc_unlimit() {
  local ifc=$1 orig=${2:-} kind
  [[ -n $ifc ]] || return 0
  if [[ $(awk '{print $3}' <<<"$(tc_root "$ifc")") == "$TC_HANDLE" ]]; then
    tc qdisc del dev "$ifc" root >/dev/null 2>&1 || return 1
  fi
  kind=$(awk '{print $2}' <<<"$(tc_root "$ifc")")
  case $orig in
    fq | fq_codel | cake | sfq)
      if [[ $kind != "$orig" ]]; then tc qdisc replace dev "$ifc" root "$orig" >/dev/null 2>&1 || true; fi
      ;;
  esac
  return 0
}

# ---------- 定时检查 ----------
# traffic_check：累加用量，按额度决定是否限速（由 vps-tick.timer 每 5 分钟调用）
traffic_check() {
  local -A S
  local ifc used limit=0 rate rc
  kv_load "$TRAFFIC_STATE" S
  S[NOTE]=""
  S[LIMITED]=${S[LIMITED]:-0}
  traffic_accumulate S
  S[CHECKED]=$(now)
  mkdir -p "$VAR_DIR"
  # 找不到出口网卡（比如网络还没起来）：维持现状，下次再查
  if [[ ${S[NOTE]} == no_iface ]]; then
    kv_save "$TRAFFIC_STATE" S 644
    return 0
  fi
  ifc=${S[LAST_IF]}
  if traffic_configured && [[ $(kv_get "$TRAFFIC_CONF" LIMIT 1) == 1 && ${S[SKIP]:-} != "${S[PERIOD]}" ]]; then
    used=$(used_bytes S)
    if ((used >= $(threshold_bytes))); then limit=1; fi
  fi
  # 出口网卡变了：先撤掉旧网卡上的限速
  if [[ ${S[LIMITED]:-0} == 1 && -n ${S[LIMIT_IF]:-} && ${S[LIMIT_IF]} != "$ifc" ]]; then
    tc_unlimit "${S[LIMIT_IF]}" "${S[ORIG_QDISC]:-}" || true
    S[LIMITED]=0
    S[LIMIT_IF]=""
  fi
  if ((limit)); then
    rate=$(kv_get "$TRAFFIC_CONF" RATE 1)
    TC_ORIG=${S[ORIG_QDISC]:-}
    rc=0
    tc_limit "$ifc" "$rate" || rc=$?
    case $rc in
      0)
        S[LIMITED]=1
        S[LIMIT_IF]=$ifc
        S[ORIG_QDISC]=$TC_ORIG
        S[NOTE]=limited
        ;;
      2) S[NOTE]=conflict ;;
      *) S[NOTE]=tc_failed ;;
    esac
  else
    if [[ ${S[LIMITED]:-0} == 1 ]]; then
      if tc_unlimit "${S[LIMIT_IF]:-$ifc}" "${S[ORIG_QDISC]:-}"; then
        S[LIMITED]=0
        S[LIMIT_IF]=""
      else
        S[NOTE]=tc_failed
      fi
    fi
    [[ -n ${S[NOTE]:-} ]] || S[NOTE]=ok
  fi
  kv_save "$TRAFFIC_STATE" S 644
}

# 定时任务：有节点或配置了流量额度时启用
tick_sync() {
  if traffic_configured || [[ -n $(nodes_all) ]]; then
    write_unit vps-tick.service "$(unit_tick_service)"
    write_unit vps-tick.timer "$(unit_tick_timer)"
    units_reload
    if ! systemctl is-enabled --quiet vps-tick.timer 2>/dev/null; then
      systemctl enable --now vps-tick.timer >/dev/null 2>&1 || warn "启用定时任务失败"
    fi
  else
    remove_unit vps-tick.timer
    remove_unit vps-tick.service
    units_reload
  fi
}

unit_tick_service() {
  cat <<'EOF'
[Unit]
Description=vps: 流量统计与限额检查

[Service]
Type=oneshot
ExecStart=/usr/local/bin/vps _tick
Nice=10
EOF
}

unit_tick_timer() {
  cat <<'EOF'
[Unit]
Description=vps: 每 5 分钟统计流量

[Timer]
OnBootSec=1min
OnUnitActiveSec=5min
AccuracySec=30s

[Install]
WantedBy=timers.target
EOF
}

cmd_tick() {
  lock --nowait
  if traffic_configured || [[ -f $TRAFFIC_STATE ]]; then traffic_check; fi
  stats_sample || true
  cert_sync_ws || true
}

# ---------- 命令 ----------
traffic_set() {
  local -A C
  local k v used=""
  kv_load "$TRAFFIC_CONF" C
  while (($#)); do
    k=$1 v=${2:-}
    need_value "$k" "$v"
    case $k in
      --quota)
        v=${v%[Gg][Bb]}
        if ! [[ $v =~ ^[0-9]+([.][0-9]+)?$ ]] || ! awk -v x="$v" 'BEGIN {exit !(x > 0)}'; then
          die "额度要大于 0（单位 GB）"
        fi
        C[QUOTA_GB]=$v ;;
      --percent)
        v=${v%\%}
        if ! [[ $v =~ ^[0-9]+$ ]] || ((v < 1 || v > 100)); then die "触发比例是 1-100 的整数"; fi
        C[PERCENT]=$v ;;
      --rate)
        v=${v%[Mm]bit*}
        if ! [[ $v =~ ^[0-9]+([.][0-9]+)?$ ]] || ! awk -v x="$v" 'BEGIN {exit !(x >= 0.01)}'; then
          die "限速单位是 Mbit/s，例如 1 或 0.5"
        fi
        C[RATE]=$v ;;
      --count)
        [[ $v == tx || $v == rx || $v == both ]] || die "统计方向只能是 tx（出站）/ rx（入站）/ both（双向）"
        C[COUNT]=$v ;;
      --reset-day)
        if ! [[ $v =~ ^[0-9]+$ ]] || ((10#$v < 1 || 10#$v > 28)); then die "重置日是 1-28"; fi
        C[RESET_DAY]=$((10#$v)) ;;
      --iface)
        if [[ $v == auto ]]; then C[IFACE]=""
        else
          [[ $v =~ ^[A-Za-z0-9._@-]+$ && -d $NET_DIR/$v ]] || die "网卡不存在: $v"
          C[IFACE]=$v
        fi ;;
      --used)
        v=${v%[Gg][Bb]}
        [[ $v =~ ^[0-9]+([.][0-9]+)?$ ]] || die "已用流量单位是 GB，例如 120.5"
        used=$v ;;
      *) die "未知参数: $k" ;;
    esac
    shift 2
  done
  [[ -n ${C[QUOTA_GB]:-} ]] || die "请先设置每月额度：vps traffic set --quota <GB>"
  C[PERCENT]=${C[PERCENT]:-90}
  C[RATE]=${C[RATE]:-1}
  C[COUNT]=${C[COUNT]:-tx}
  C[RESET_DAY]=${C[RESET_DAY]:-1}
  C[LIMIT]=${C[LIMIT]:-1}
  C[IFACE]=${C[IFACE]:-}
  kv_save "$TRAFFIC_CONF" C 644
  if [[ -n $used ]]; then traffic_set_used "$used"; fi
  tick_sync
  traffic_check
  ok "流量限额已保存"
  traffic_status
}

# 把本周期已用量校准成服务商面板上的数字
traffic_set_used() {
  local -A S
  local bytes
  bytes=$(awk -v g="$1" 'BEGIN {printf "%.0f", g * 1000000000}')
  kv_load "$TRAFFIC_STATE" S
  traffic_accumulate S
  case $(kv_get "$TRAFFIC_CONF" COUNT tx) in
    rx) S[USED_RX]=$bytes ;;
    both) S[USED_TX]=$bytes; S[USED_RX]=0 ;;
    *) S[USED_TX]=$bytes ;;
  esac
  mkdir -p "$VAR_DIR"
  kv_save "$TRAFFIC_STATE" S 644
}

traffic_limit_toggle() {
  traffic_configured || die "还没有设置流量额度"
  case ${1:-} in
    on) kv_set "$TRAFFIC_CONF" LIMIT 1 644; traffic_check; ok "已开启自动限速" ;;
    off) kv_set "$TRAFFIC_CONF" LIMIT 0 644; traffic_check; ok "已关闭自动限速（仍会统计用量）" ;;
    *) die "用法: vps traffic limit on|off" ;;
  esac
}

# 本周期内不再限速，下个周期自动恢复
traffic_unlimit() {
  local -A S
  kv_load "$TRAFFIC_STATE" S
  traffic_accumulate S
  S[SKIP]=${S[PERIOD]}
  kv_save "$TRAFFIC_STATE" S 644
  traffic_check
  ok "已解除限速，本周期内不再限速（$(period_next "${S[PERIOD]}") 起恢复）"
}

traffic_remove() {
  local -A S
  kv_load "$TRAFFIC_STATE" S
  if [[ ${S[LIMITED]:-0} == 1 ]]; then tc_unlimit "${S[LIMIT_IF]:-}" "${S[ORIG_QDISC]:-}" || true; fi
  rm -f "$TRAFFIC_CONF" "$TRAFFIC_STATE"
  tick_sync
  ok "已删除流量限额"
}

bar() {
  local pct=$1 width=24 fill color=$CG
  ((pct > 100)) && pct=100
  fill=$((pct * width / 100))
  ((pct >= 80)) && color=$CY
  ((pct >= 100)) && color=$CR
  printf '%s%s%s%s%s' "$color" "$(printf '%*s' "$fill" '' | tr ' ' '#')" "$CD" \
    "$(printf '%*s' $((width - fill)) '' | tr ' ' '.')" "$C0"
}

count_label() {
  case $(kv_get "$TRAFFIC_CONF" COUNT tx) in
    rx) echo 入站 ;;
    both) echo 双向 ;;
    *) echo 出站 ;;
  esac
}

# 一行状态（菜单顶部用）
traffic_brief() {
  local -A S
  local used quota pct
  if ! traffic_configured; then
    printf '%s未设置额度%s' "$CD" "$C0"
    return 0
  fi
  kv_load "$TRAFFIC_STATE" S
  traffic_accumulate S
  used=$(used_bytes S)
  quota=$(quota_bytes)
  pct=$((used * 100 / quota))
  if [[ ${S[LIMITED]:-0} == 1 ]]; then
    printf '%s● 已限速%s  %s / %s GB' "$CR" "$C0" "$(human "$used")" "$(kv_get "$TRAFFIC_CONF" QUOTA_GB)"
  else
    printf '%s / %s GB（%s%%）' "$(human "$used")" "$(kv_get "$TRAFFIC_CONF" QUOTA_GB)" "$pct"
  fi
}

traffic_status() {
  local -A S
  local used quota thr pct period next days state ifc
  printf '\n  %s流量限额%s\n' "$C1" "$C0"
  if ! traffic_configured; then
    say "还没有设置。示例：vps traffic set --quota 1000"
    return 0
  fi
  kv_load "$TRAFFIC_STATE" S
  traffic_accumulate S
  used=$(used_bytes S)
  quota=$(quota_bytes)
  thr=$(threshold_bytes)
  pct=$((used * 100 / quota))
  period=${S[PERIOD]}
  next=$(period_next "$period")
  days=$((($(date -d "$next" +%s) - $(now)) / 86400 + 1))
  ifc=${S[LAST_IF]:-$(traffic_iface || true)}
  if [[ ${S[LIMITED]:-0} == 1 ]]; then
    state="${CR}● 已限速到 $(kv_get "$TRAFFIC_CONF" RATE 1) Mbit/s${C0}"
  elif [[ ${S[NOTE]:-} == conflict ]]; then
    state="${CY}! 网卡上已有别的限速规则，未覆盖${C0}"
  elif [[ ${S[NOTE]:-} == tc_failed ]]; then
    state="${CY}! 设置限速失败${C0}"
  elif [[ ${S[NOTE]:-} == no_iface ]]; then
    state="${CY}! 找不到出口网卡${C0}"
  elif [[ $(kv_get "$TRAFFIC_CONF" LIMIT 1) != 1 ]]; then
    state="${CD}○ 自动限速已关闭（只统计）${C0}"
  elif [[ ${S[SKIP]:-} == "$period" ]]; then
    state="${CD}○ 本周期已手动解除限速${C0}"
  else
    state="${CG}● 正常${C0}"
  fi
  say "$state"
  printf '\n'
  kv_line 本期 "$period → $next（还剩 $days 天）"
  kv_line 已用 "$(human "$used") / $(kv_get "$TRAFFIC_CONF" QUOTA_GB) GB（$(count_label)）"
  printf '  %-8s %s %s%%\n' "" "$(bar "$pct")" "$pct"
  kv_line 限速 "用到 $(kv_get "$TRAFFIC_CONF" PERCENT 90)%（$(human "$thr")）后限速到 $(kv_get "$TRAFFIC_CONF" RATE 1) Mbit/s"
  kv_line 明细 "出站 $(human "${S[USED_TX]:-0}")  入站 $(human "${S[USED_RX]:-0}")"
  kv_line 网卡 "${ifc:-未知}"
  printf '\n'
}

# ---------- 各节点流量统计 ----------
node_key() { case $1 in reality) echo REALITY ;; ws) echo WS ;; hy2) echo HY2 ;; esac; }

# 从 Xray / Hysteria2 读取并清零计数器，累加到本周期
stats_sample() {
  local -A T
  local period out k v total
  [[ -n $(nodes_all) ]] || return 0
  kv_load "$STATS_STATE" T
  period=$(current_period)
  if [[ ${T[PERIOD]:-} != "$period" ]]; then
    T=([PERIOD]=$period)
  fi
  if [[ -x $(core_bin xray) ]] && svc_active vps-xray; then
    out=$("$(core_bin xray)" api statsquery -s "127.0.0.1:$(setting XRAY_API_PORT)" -pattern 'inbound>>>' -reset 2>/dev/null) || out=""
    while read -r k v; do
      [[ -n $k && $v =~ ^[0-9]+$ ]] || continue
      T[$k]=$((${T[$k]:-0} + v))
    done < <(awk '
      function emit() { if (name != "") print name, (val == "" ? 0 : val); name = ""; val = "" }
      /"name"/ { emit(); s = $0; sub(/.*"name"[^"]*"/, "", s); sub(/".*/, "", s)
                 n = split(s, p, ">>>"); if (n == 4 && p[1] == "inbound") {
                   tag = toupper(p[2]); dir = (p[4] == "uplink") ? "UP" : "DOWN"
                   if (tag == "REALITY" || tag == "WS") name = tag "_" dir } }
      /"value"/ { s = $0; gsub(/[^0-9]/, "", s); val = s }
      END { emit() }' <<<"$out")
  fi
  if node_exists hy2 && svc_active vps-hy2; then
    local -A H
    kv_load "$(node_file hy2)" H
    out=$(curl -fsS --max-time 5 -H "Authorization: ${H[STATS_SECRET]}" \
      "http://127.0.0.1:${H[STATS_PORT]}/traffic?clear=1" 2>/dev/null) || out=""
    # Hysteria2: tx = 客户端上传，rx = 客户端下载
    total=$(grep -oE '"tx": *[0-9]+' <<<"$out" | grep -oE '[0-9]+$' | awk '{s += $1} END {print s + 0}')
    T[HY2_UP]=$((${T[HY2_UP]:-0} + total))
    total=$(grep -oE '"rx": *[0-9]+' <<<"$out" | grep -oE '[0-9]+$' | awk '{s += $1} END {print s + 0}')
    T[HY2_DOWN]=$((${T[HY2_DOWN]:-0} + total))
  fi
  mkdir -p "$VAR_DIR"
  kv_save "$STATS_STATE" T 644
}

# stats_get 节点 → "上传 下载"（本周期）
stats_get() {
  local -A T
  local k
  kv_load "$STATS_STATE" T
  k=$(node_key "$1")
  if [[ ${T[PERIOD]:-} != "$(current_period)" ]]; then
    echo "0 0"
  else
    echo "${T[${k}_UP]:-0} ${T[${k}_DOWN]:-0}"
  fi
}

stats_forget() {
  local -A T
  local k
  [[ -f $STATS_STATE ]] || return 0
  kv_load "$STATS_STATE" T
  k=$(node_key "$1")
  unset "T[${k}_UP]" "T[${k}_DOWN]"
  kv_save "$STATS_STATE" T 644
}
