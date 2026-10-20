# shellcheck shell=bash
# 系统：BBR、屏蔽规则、分享地址、自动更新、安装 / 更新 / 卸载

# 跟随的分支：安装时记录，之后自动更新都用它
update_branch() { printf '%s' "${VPS_BRANCH:-$(setting BRANCH main)}"; }

# ---------- BBR ----------
BBR_CONF=$SYSCTL_DIR/90-vps-bbr.conf

bbr_enabled() { [[ $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null) == bbr ]]; }

bbr_set() {
  case ${1:-} in
    on)
      local avail
      modprobe tcp_bbr >/dev/null 2>&1 || true
      avail=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)
      [[ " $avail " == *" bbr "* ]] || die "当前内核不支持 BBR（需要 4.9+；OpenVZ / LXC 容器通常不支持）"
      mkdir -p "$SYSCTL_DIR"
      printf '# vps: BBR\nnet.core.default_qdisc = fq\nnet.ipv4.tcp_congestion_control = bbr\n' >"$BBR_CONF"
      sysctl -q -p "$BBR_CONF" >/dev/null 2>&1 || die "应用 BBR 设置失败"
      ok "BBR 已开启"
      ;;
    off)
      rm -f "$BBR_CONF"
      sysctl -q -w net.ipv4.tcp_congestion_control=cubic >/dev/null 2>&1 || true
      sysctl -q -w net.core.default_qdisc=fq_codel >/dev/null 2>&1 || true
      ok "BBR 已关闭"
      ;;
    "")
      if bbr_enabled; then say "BBR：已开启"; else say "BBR：未开启（vps bbr on 开启）"; fi
      ;;
    *) die "用法: vps bbr [on|off]" ;;
  esac
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
  rm -f "$SYSCTL_DIR/90-vps-hy2.conf" "$BBR_CONF"
  if getent passwd "$SVC_USER" >/dev/null 2>&1; then userdel "$SVC_USER" >/dev/null 2>&1 || true; fi
  rm -rf "$ETC" "$VAR_DIR" "$LIB_DIR"
  rm -f "$BIN_LINK"
  ok "已卸载。BBR 设置会在下次重启后恢复系统默认"
}
