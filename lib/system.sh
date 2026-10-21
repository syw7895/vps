# shellcheck shell=bash
# 系统：网络加速、屏蔽规则、分享地址、自动更新、安装 / 更新 / 卸载

# 跟随的分支：安装时记录，之后自动更新都用它
update_branch() { printf '%s' "${VPS_BRANCH:-$(setting BRANCH main)}"; }

# ---------- 网络加速：拥塞算法 / 队列算法 / 线路调优 ----------
# 设置存在 settings.env（NET_CC / NET_QDISC / NET_TUNE），空 = 不管，用系统原来的值
NET_CONF=$SYSCTL_DIR/99-zz-vps-net.conf # 排在其他 99-*.conf 之后：同一项以本工具为准
NET_ORIG=$VAR_DIR/net.orig              # 第一次改动前的原值（sysctl 输出格式，恢复时 sysctl -p）
OLD_BBR_CONF=$SYSCTL_DIR/90-vps-bbr.conf # 旧版只管 BBR 的文件，升级时迁移
NET_KEYS=(net.ipv4.tcp_congestion_control net.core.default_qdisc net.core.rmem_max net.core.wmem_max
  net.ipv4.tcp_rmem net.ipv4.tcp_wmem net.ipv4.tcp_notsent_lowat net.ipv4.tcp_mtu_probing
  net.ipv4.tcp_slow_start_after_idle net.ipv4.tcp_fastopen)
NET_QDISCS=(fq fq_codel cake)

cc_desc() {
  case $1 in
    bbr) echo "按带宽和延迟估算发送速度，丢包多的跨国线路效果最好（推荐）" ;;
    cubic) echo "Linux 默认，丢包时降速明显" ;;
    hybla) echo "为高延迟链路设计" ;;
    westwood) echo "适合无线 / 随机丢包" ;;
    htcp | illinois | highspeed | scalable | yeah) echo "高带宽长距离链路" ;;
    vegas | veno | nv | lp | cdg | dctcp | bic | reno) echo "" ;;
  esac
}

qdisc_desc() {
  case $1 in
    fq) echo "公平队列，BBR 推荐搭配" ;;
    fq_codel) echo "控制排队延迟，多数发行版默认" ;;
    cake) echo "功能最全的队列，CPU 占用稍高" ;;
  esac
}

# 内核里能用的拥塞算法：已加载的 + 能加载的模块
cc_list() {
  local f n
  {
    tr ' ' '\n' <<<"$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null)"
    for f in "$RT/lib/modules/$(uname -r)/kernel/net/ipv4"/tcp_*.ko*; do
      [[ -e $f ]] || continue
      n=${f##*/tcp_}
      n=${n%%.ko*}
      [[ $n == diag ]] || echo "$n"
    done
  } | awk 'NF' | sort -u | awk '$0 == "bbr" {print; next} {rest = rest $0 "\n"} END {printf "%s", rest}'
}

net_buf_max() {
  local kb
  kb=$(awk '/^MemTotal:/ {print $2}' "$RT/proc/meminfo" 2>/dev/null || true)
  if [[ -n $kb ]] && ((kb >= 2000000)); then echo 33554432; else echo 16777216; fi
}

net_conf_text() {
  local cc qd max
  cc=$(setting NET_CC)
  qd=$(setting NET_QDISC)
  if [[ -n $qd ]]; then printf 'net.core.default_qdisc = %s\n' "$qd"; fi
  if [[ -n $cc ]]; then printf 'net.ipv4.tcp_congestion_control = %s\n' "$cc"; fi
  if [[ $(setting NET_TUNE 0) == 1 ]]; then
    max=$(net_buf_max)
    printf 'net.core.rmem_max = %s\nnet.core.wmem_max = %s\n' "$max" "$max"
    printf 'net.ipv4.tcp_rmem = 4096 131072 %s\nnet.ipv4.tcp_wmem = 4096 16384 %s\n' "$max" "$max"
    printf 'net.ipv4.tcp_notsent_lowat = 131072\nnet.ipv4.tcp_mtu_probing = 1\n'
    printf 'net.ipv4.tcp_slow_start_after_idle = 0\nnet.ipv4.tcp_fastopen = 3\n'
  fi
}

# 按设置写 sysctl 文件并立即生效：先恢复原值，再按系统全部配置重新应用（本工具的文件最后生效）
net_apply() {
  local text
  text=$(net_conf_text)
  if [[ -z $text ]]; then
    net_restore
    return 0
  fi
  mkdir -p "$SYSCTL_DIR" "$VAR_DIR"
  if [[ ! -f $NET_ORIG ]]; then sysctl "${NET_KEYS[@]}" >"$NET_ORIG" 2>/dev/null || true; fi
  printf '# vps: 网络加速（用 vps net 修改，不要手改）\n%s\n' "$text" >"$NET_CONF"
  net_reload
}

# 删掉本工具的设置，各项回到原值或系统配置的值（卸载时也用）
net_restore() {
  [[ -f $NET_CONF || -f $NET_ORIG ]] || return 0
  rm -f "$NET_CONF"
  net_reload
  rm -f "$NET_ORIG"
}

net_reload() {
  if [[ -f $NET_ORIG ]]; then sysctl -q -p "$NET_ORIG" >/dev/null 2>&1 || true; fi
  sysctl -q --system >/dev/null 2>&1 || true
  net_qdisc_refresh
}

# 默认队列只影响新建的队列：重建出口网卡的队列让它马上生效
# 正在限速（本工具的 tbf）或网卡上是别人设置的队列时不动
net_qdisc_refresh() {
  local ifc line kind want
  want=$(sysctl -n net.core.default_qdisc 2>/dev/null || true)
  [[ -n $want ]] || return 0
  ifc=$(traffic_iface) || return 0
  line=$(tc_root "$ifc")
  [[ $(awk '{print $3}' <<<"$line") != "$TC_HANDLE" ]] || return 0
  kind=$(awk '{print $2}' <<<"$line")
  case $kind in
    mq)
      if ! tc qdisc show dev "$ifc" 2>/dev/null | awk -v w="$want" '/ parent / && $2 != w {bad = 1} END {exit !bad}'; then
        return 0
      fi
      # 默认队列（句柄 0:）删不掉，换成新的 mq；新 mq 的子队列按新默认值创建
      tc qdisc del dev "$ifc" root >/dev/null 2>&1 || tc qdisc replace dev "$ifc" root mq >/dev/null 2>&1 || true
      ;;
    "$want") ;;
    "" | pfifo_fast | fq | fq_codel | cake | sfq)
      tc qdisc del dev "$ifc" root >/dev/null 2>&1 || tc qdisc replace dev "$ifc" root "$want" >/dev/null 2>&1 || true
      ;;
  esac
  return 0
}

# 某项当前值来自哪个配置文件（同名文件 /etc 优先，按文件名顺序后者覆盖前者）
sysctl_source() {
  local key=$1 d f b src=""
  local -A files=()
  for d in /etc/sysctl.d /run/sysctl.d /usr/local/lib/sysctl.d /usr/lib/sysctl.d /lib/sysctl.d; do
    for f in "$RT$d"/*.conf; do
      [[ -f $f ]] || continue
      b=${f##*/}
      [[ -n ${files[$b]:-} ]] || files[$b]=$f
    done
  done
  while IFS= read -r b; do
    [[ -n $b ]] || continue
    if awk -F= -v k="$key" '{x = $1; gsub(/[ \t-]/, "", x)} x == k {f = 1} END {exit !f}' "${files[$b]}"; then src=$b; fi
  done < <(printf '%s\n' "${!files[@]}" | sort)
  printf '%s' "$src"
}

# 当前值后面的说明：谁设置的
net_origin() {
  local src
  src=$(sysctl_source "$1")
  if [[ $src == "${NET_CONF##*/}" ]]; then
    echo "本工具设置"
  elif [[ -n $src ]]; then
    echo "系统配置 $src"
  else
    echo "内核默认"
  fi
}

net_tuned() { [[ $(setting NET_TUNE 0) == 1 ]]; }

# 一行概览（系统菜单用）
net_brief() {
  printf '%s · %s' "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" "$(sysctl -n net.core.default_qdisc 2>/dev/null)"
  if net_tuned; then printf ' · 已调优'; fi
}

mb() { awk -v b="$1" 'BEGIN {printf "%d MB", b / 1048576}'; }

net_status() {
  local cc qd rmax
  cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)
  qd=$(sysctl -n net.core.default_qdisc 2>/dev/null || true)
  rmax=$(sysctl -n net.core.rmem_max 2>/dev/null || echo 0)
  kv_line 拥塞算法 "$(pad "${cc:-未知}" 10)$CD$(net_origin net.ipv4.tcp_congestion_control)$C0"
  kv_line 队列算法 "$(pad "${qd:-未知}" 10)$CD$(net_origin net.core.default_qdisc)$C0"
  if net_tuned; then
    kv_line 线路调优 "$(pad 已开启 10)${CD}缓冲区上限 $(mb "$rmax")$C0"
  else
    kv_line 线路调优 "$(pad 未开启 10)${CD}缓冲区上限 $(mb "$rmax")（$(net_origin net.core.rmem_max)）$C0"
  fi
}

# cc_check 算法：内核不支持就报错退出
cc_check() {
  [[ $1 =~ ^[a-z0-9_]{1,16}$ ]] || die "算法名不正确: $1"
  modprobe "tcp_$1" >/dev/null 2>&1 || true
  if [[ " $(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null) " != *" $1 "* ]]; then
    if [[ $1 == bbr ]]; then die "当前内核不支持 BBR（需要 4.9+；OpenVZ / LXC 容器通常不支持）"; fi
    die "当前内核不支持 $1"
  fi
}

net_set_cc() {
  local cc=${1:-}
  case $cc in
    "") die "用法: vps net cc <算法|default>（vps net 查看可用算法）" ;;
    default) setting_set NET_CC "" ;;
    *) cc_check "$cc"; setting_set NET_CC "$cc" ;;
  esac
  net_apply
  if [[ $cc == default ]]; then
    ok "拥塞算法已恢复系统默认：$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)（$(net_origin net.ipv4.tcp_congestion_control)）"
  else
    ok "拥塞算法：$cc"
  fi
}

net_set_qdisc() {
  local q=${1:-} old
  case $q in
    default) setting_set NET_QDISC "" ;;
    fq | fq_codel | cake)
      modprobe "sch_$q" >/dev/null 2>&1 || true
      old=$(sysctl -n net.core.default_qdisc 2>/dev/null || true)
      sysctl -q -w "net.core.default_qdisc=$q" >/dev/null 2>&1 || die "当前内核不支持 $q 队列"
      [[ -z $old ]] || sysctl -q -w "net.core.default_qdisc=$old" >/dev/null 2>&1 || true
      setting_set NET_QDISC "$q"
      ;;
    *) die "用法: vps net qdisc fq|fq_codel|cake|default" ;;
  esac
  net_apply
  if [[ $q == default ]]; then
    ok "队列算法已恢复系统默认：$(sysctl -n net.core.default_qdisc 2>/dev/null)（$(net_origin net.core.default_qdisc)）"
  else
    ok "队列算法：$q（已对出口网卡生效）"
  fi
}

net_set_tune() {
  case ${1:-} in
    on) setting_set NET_TUNE 1; net_apply; ok "线路调优已开启（TCP 缓冲区上限 $(mb "$(net_buf_max)")）" ;;
    off) setting_set NET_TUNE 0; net_apply; ok "线路调优已关闭，相关参数已恢复" ;;
    *) die "用法: vps net tune on|off" ;;
  esac
}

# vps net [cc|qdisc|tune|recommend|reset] ...
net_cmd() {
  local sub=${1:-}
  shift || true
  case $sub in
    "")
      title_bar 网络加速
      net_status
      printf '\n'
      note "可用拥塞算法：$(cc_list | tr '\n' ' ')"
      printf '\n'
      ;;
    cc) net_set_cc "$@" ;;
    qdisc) net_set_qdisc "$@" ;;
    tune) net_set_tune "$@" ;;
    recommend)
      cc_check bbr
      setting_set NET_CC bbr
      setting_set NET_QDISC fq
      setting_set NET_TUNE 1
      net_apply
      ok "已应用推荐设置：BBR + fq + 线路调优"
      ;;
    reset)
      setting_set NET_CC ""
      setting_set NET_QDISC ""
      setting_set NET_TUNE 0
      net_apply
      ok "网络设置已全部恢复系统默认"
      ;;
    *) die "用法: vps net [cc <算法>|qdisc <队列>|tune on|off|recommend|reset]" ;;
  esac
}

bbr_enabled() { [[ $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null) == bbr ]]; }

# 兼容旧命令：vps bbr on = 拥塞算法 bbr + 队列 fq；off = 两项都恢复系统默认
bbr_set() {
  case ${1:-} in
    on)
      cc_check bbr
      setting_set NET_CC bbr
      setting_set NET_QDISC fq
      net_apply
      ok "BBR 已开启"
      ;;
    off)
      setting_set NET_CC ""
      setting_set NET_QDISC ""
      net_apply
      if bbr_enabled; then
        ok "已不再由本工具设置 BBR；系统配置（$(sysctl_source net.ipv4.tcp_congestion_control)）仍开着 BBR"
      else
        ok "BBR 已关闭"
      fi
      ;;
    "")
      if bbr_enabled; then say "BBR：已开启"; else say "BBR：未开启（vps bbr on 开启）"; fi
      ;;
    *) die "用法: vps bbr [on|off]" ;;
  esac
}

# 旧版的 90-vps-bbr.conf 迁移成新的设置
net_migrate() {
  [[ -f $OLD_BBR_CONF ]] || return 0
  rm -f "$OLD_BBR_CONF"
  [[ -n $(setting NET_CC) ]] || setting_set NET_CC bbr
  [[ -n $(setting NET_QDISC) ]] || setting_set NET_QDISC fq
  net_apply
}

# ---------- 屏蔽规则 ----------
block_key() {
  case ${1:-} in
    cn) echo BLOCK_CN ;;
    ads) echo BLOCK_ADS ;;
    *) die "可选：cn（回国 IP 和域名）/ ads（广告域名）" ;;
  esac
}

block_label() { case $1 in cn) echo "屏蔽回国 IP / 域名" ;; ads) echo "屏蔽广告域名" ;; esac; }

block_set() {
  local what=${1:-} val key old
  if [[ -z $what ]]; then
    for what in cn ads; do
      if [[ $(setting "$(block_key "$what")" 0) == 1 ]]; then val=已开启; else val=已关闭; fi
      say "$(block_label "$what")：$val"
    done
    return 0
  fi
  key=$(block_key "$what")
  case ${2:-} in
    on) val=1 ;;
    off) val=0 ;;
    *) die "用法: vps block $what on|off" ;;
  esac
  old=$(setting "$key" 0)
  if [[ $val == 1 ]] && ! geo_ready; then
    say "下载规则文件 ..."
    geo_update || die "规则文件下载失败，未开启"
  fi
  setting_set "$key" "$val"
  if ! apply_all; then
    setting_set "$key" "$old"
    apply_all >/dev/null 2>&1 || true
    die "应用失败，已恢复原设置"
  fi
  if ! blocking_on; then rm -f "$SHARE_DIR/geoip.dat" "$SHARE_DIR/geosite.dat"; fi
  if [[ $val == 1 ]]; then ok "已开启：$(block_label "$what")"; else ok "已关闭：$(block_label "$what")"; fi
}

# ---------- 分享地址 ----------
host_set() {
  local h=${1:-}
  if [[ -z $h ]]; then
    say "分享地址：$(share_host)"
    return 0
  fi
  if [[ $h == auto ]]; then
    h=$(detect_ip) || die "无法获取公网 IP"
  else
    h=${h#[}
    h=${h%]}
    is_host "$h" || die "地址格式不正确: $h"
  fi
  setting_set HOST "$h"
  ok "分享地址：$h"
  if [[ -n $(nodes_all) ]]; then note "分享链接已随之更新，用 vps show 查看"; fi
}

# ---------- 自动更新 ----------
unit_update_service() {
  cat <<'EOF'
[Unit]
Description=vps: 更新管理脚本、内核和规则
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/vps update --auto
TimeoutStartSec=30min
EOF
}

unit_update_timer() {
  cat <<'EOF'
[Unit]
Description=vps: 每周自动更新

[Timer]
OnCalendar=Sun *-*-* 04:00:00
RandomizedDelaySec=2h
Persistent=true

[Install]
WantedBy=timers.target
EOF
}

update_timer_sync() {
  if [[ $(setting AUTO_UPDATE 1) == 1 ]]; then
    write_unit vps-update.service "$(unit_update_service)"
    write_unit vps-update.timer "$(unit_update_timer)"
    units_reload
    if ! systemctl is-enabled --quiet vps-update.timer 2>/dev/null; then
      systemctl enable --now vps-update.timer >/dev/null 2>&1 || warn "启用自动更新失败"
    fi
  else
    remove_unit vps-update.timer
    remove_unit vps-update.service
    units_reload
  fi
}

autoupdate_set() {
  case ${1:-} in
    on) setting_set AUTO_UPDATE 1; update_timer_sync; ok "已开启每周自动更新" ;;
    off) setting_set AUTO_UPDATE 0; update_timer_sync; ok "已关闭自动更新" ;;
    "") if [[ $(setting AUTO_UPDATE 1) == 1 ]]; then say "自动更新：每周一次"; else say "自动更新：已关闭"; fi ;;
    *) die "用法: vps autoupdate on|off" ;;
  esac
}

# ---------- 安装 / 更新 ----------
installed_ref() { cat "$LIB_DIR/current/.ref" 2>/dev/null || true; }

# 校验一份代码：文件齐全且没有语法错误
verify_tree() {
  local f
  [[ -f $1/vps && -f $1/lib/common.sh ]] || return 1
  for f in "$1/vps" "$1"/lib/*.sh; do
    bash -n "$f" 2>/dev/null || return 1
  done
}

prune_releases() {
  local keep=$1 d n=0
  while IFS= read -r d; do
    [[ ${d##*/} == "$keep" ]] && continue
    n=$((n + 1))
    if ((n > 1)); then rm -rf "$d"; fi
  done < <(find "$LIB_DIR/releases" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' 2>/dev/null | sort -rn | cut -d' ' -f2-)
}

# vps _install 源目录 提交号：装到 releases/<提交号>，原子切换 current
cmd_install_from() {
  local src=${1:-} sha=${2:-} dest
  need_root
  [[ $sha =~ ^[0-9a-f]{40}$ ]] || die "提交号无效"
  verify_tree "$src" || die "代码不完整或有语法错误，已停止"
  dest=$LIB_DIR/releases/$sha
  mkdir -p "$LIB_DIR/releases"
  rm -rf "$dest.tmp"
  mkdir -p "$dest.tmp"
  cp -R "$src/vps" "$src/lib" "$dest.tmp/"
  printf '%s\n' "$sha" >"$dest.tmp/.ref"
  chmod -R u=rwX,go=rX "$dest.tmp"
  chmod 755 "$dest.tmp/vps"
  rm -rf "$dest"
  mv "$dest.tmp" "$dest"
  ln -sfn "releases/$sha" "$LIB_DIR/current.tmp"
  mv -Tf "$LIB_DIR/current.tmp" "$LIB_DIR/current"
  mkdir -p "${BIN_LINK%/*}"
  ln -sfn "$LIB_DIR/current/vps" "$BIN_LINK"
  prune_releases "$sha"
  "$LIB_DIR/current/vps" _post-install
}

# 新版本接手后的收尾：目录、定时任务、按新模板重新生成配置
cmd_post_install() {
  need_root
  mkdir -p "$ETC" "$NODE_DIR" "$VAR_DIR"
  chmod 755 "$ETC"
  chmod 700 "$NODE_DIR"
  [[ -n $(setting AUTO_UPDATE) ]] || setting_set AUTO_UPDATE 1
  if [[ -n ${VPS_BRANCH:-} && ${VPS_BRANCH} =~ ^[A-Za-z0-9._/-]+$ ]]; then setting_set BRANCH "$VPS_BRANCH"; fi
  update_timer_sync
  net_migrate
  if [[ -n $(nodes_all) ]]; then apply_all || warn "部分节点重新生成配置失败"; fi
  tick_sync
}

SELF_UPDATED=0

self_update() {
  local cur sha tmp
  SELF_UPDATED=0
  cur=$(installed_ref)
  if [[ -z $cur ]]; then
    note "不是通过安装器安装的，跳过脚本更新"
    return 0
  fi
  sha=$(curl "${CURL_SAFE[@]}" --max-time 30 -H 'Accept: application/vnd.github.sha' \
    "https://api.github.com/repos/$VPS_REPO/commits/$(update_branch)") || { warn "无法检查管理脚本更新"; return 1; }
  [[ $sha =~ ^[0-9a-f]{40}$ ]] || { warn "管理脚本版本号异常"; return 1; }
  if [[ $sha == "$cur" ]]; then
    say "管理脚本已是最新（${cur:0:7}）"
    return 0
  fi
  tmp=$(mktemp -d)
  if ! curl "${CURL_SAFE[@]}" --max-time 120 "https://codeload.github.com/$VPS_REPO/tar.gz/$sha" |
    tar -xz -C "$tmp" --strip-components=1 2>/dev/null; then
    rm -rf "$tmp"
    warn "下载管理脚本失败"
    return 1
  fi
  if ! bash "$tmp/vps" _install "$tmp" "$sha"; then
    rm -rf "$tmp"
    warn "新版管理脚本安装失败，继续使用当前版本"
    return 1
  fi
  rm -rf "$tmp"
  ok "管理脚本已更新：${cur:0:7} → ${sha:0:7}"
  SELF_UPDATED=1
}

# vps update [--auto] [--no-self]：脚本 → 内核 → 规则文件
cmd_update() {
  local auto=0 self=1 rc=0 c
  while (($#)); do
    case $1 in
      --auto) auto=1 ;;
      --no-self) self=0 ;;
      *) die "未知参数: $1" ;;
    esac
    shift
  done
  if ((self)); then
    self_update || rc=1
    if ((SELF_UPDATED)); then
      local args=(update --no-self)
      ((auto)) && args+=(--auto)
      exec "$BIN_LINK" "${args[@]}"
    fi
  fi
  core_update xray || rc=1
  core_update hy2 || rc=1
  if blocking_on; then
    if geo_update; then
      if ((GEO_CHANGED)); then
        stats_sample || true
        for c in xray hy2; do
          if svc_active "$(core_unit "$c")"; then svc_restart "$(core_unit "$c")" || rc=1; fi
        done
        ok "屏蔽规则已更新"
      else
        say "屏蔽规则已是最新"
      fi
    else
      rc=1
    fi
  fi
  return "$rc"
}

# ---------- 卸载 ----------
cmd_uninstall() {
  local -A N S
  local n u
  if [[ ${1:-} != --yes ]]; then
    confirm "确定卸载？会删除所有节点、证书、流量限额和本工具" || { say "已取消"; return 0; }
  fi
  for u in vps-xray.service vps-hy2.service vps-tick.timer vps-tick.service vps-update.timer vps-update.service; do
    remove_unit "$u"
  done
  units_reload
  kv_load "$TRAFFIC_STATE" S
  if [[ ${S[LIMITED]:-0} == 1 ]]; then tc_unlimit "${S[LIMIT_IF]:-}" "${S[ORIG_QDISC]:-}" || true; fi
  for n in "${NODE_TYPES[@]}"; do
    node_exists "$n" || continue
    kv_load "$(node_file "$n")" N
    fw_close "${N[PORT]}" "$(node_proto "$n")"
    if [[ $n == ws ]]; then cert_acme_delete "${N[DOMAIN]:-}"; fi
  done
  rm -f "$SYSCTL_DIR/90-vps-hy2.conf" "$OLD_BBR_CONF"
  net_restore
  if getent passwd "$SVC_USER" >/dev/null 2>&1; then userdel "$SVC_USER" >/dev/null 2>&1 || true; fi
  rm -rf "$ETC" "$VAR_DIR" "$LIB_DIR"
  rm -f "$BIN_LINK"
  ok "已卸载，网络设置已恢复原样"
}
