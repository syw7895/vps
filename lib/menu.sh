# shellcheck shell=bash
# 交互菜单

menu_head() {
  printf '\n  %s%s%s%s' "$C1" "$CC" "$1" "$C0"
  if [[ -n ${2:-} ]]; then printf '  %s%s%s' "$CD" "$2" "$C0"; fi
  printf '\n'
}

pause() {
  printf '\n  %s按回车继续%s' "$CD" "$C0"
  IFS= read -r _ || true
}

# 在子 shell 里执行一个操作：出错只结束这一步，回到菜单
run() {
  (
    lock
    "$@"
  ) || true
}

# menu_pick 结果变量 "动作|文字[|danger]" ...
# 打印编号菜单并读取选择；0 → back，无效 → 空；读到输入结束返回 1
menu_pick() {
  local -n __pick=$1
  shift
  local __i=1 __item __act __label __style __in
  local __acts=()
  for __item in "$@"; do
    IFS='|' read -r __act __label __style <<<"$__item"
    __acts+=("$__act")
    if [[ $__style == danger ]]; then
      printf '  %s%2s  %s%s\n' "$CR" "$__i" "$__label" "$C0"
    else
      printf '  %s%2s%s  %s\n' "$CC" "$__i" "$C0" "$__label"
    fi
    __i=$((__i + 1))
  done
  printf '  %s%2s  返回%s\n' "$CD" 0 "$C0"
  printf '\n  请选择: '
  IFS= read -r __in || return 1
  __in=${__in//[[:space:]]/}
  __pick=""
  if [[ $__in == 0 ]]; then
    __pick=back
  elif [[ $__in =~ ^[0-9]+$ ]] && ((__in >= 1 && __in <= ${#__acts[@]})); then
    __pick=${__acts[__in - 1]}
  elif [[ -n $__in ]]; then
    warn "无效选项"
  fi
  return 0
}

# 选择一个已有节点（只有一个时直接返回它）
pick_node() {
  local nodes=() i c
  mapfile -t nodes < <(nodes_all)
  if ((${#nodes[@]} == 0)); then
    say "还没有节点" >&2
    return 1
  fi
  if ((${#nodes[@]} == 1)); then
    echo "${nodes[0]}"
    return 0
  fi
  printf '\n' >&2
  for i in "${!nodes[@]}"; do
    printf '  %s%2s%s  %s\n' "$CC" $((i + 1)) "$C0" "$(node_label "${nodes[i]}")" >&2
  done
  printf '\n  选择节点: ' >&2
  IFS= read -r c || return 1
  if [[ $c =~ ^[0-9]+$ ]] && ((c >= 1 && c <= ${#nodes[@]})); then
    echo "${nodes[c - 1]}"
  else
    warn "无效选项"
    return 1
  fi
}

nodes_brief() {
  local total=0 running=0 n
  for n in $(nodes_all); do
    total=$((total + 1))
    if svc_active "$(core_unit "$(node_core "$n")")"; then running=$((running + 1)); fi
  done
  if ((total == 0)); then
    printf '%s还没有节点%s' "$CD" "$C0"
  elif ((running == total)); then
    printf '%s● %s 个运行中%s' "$CG" "$total" "$C0"
  else
    printf '%s! %s 个节点中 %s 个已停止%s' "$CY" "$total" $((total - running)) "$C0"
  fi
}

# ---------- 主菜单 ----------
menu_main() {
  local act ref
  ref=$(installed_ref)
  while true; do
    menu_head "VPS 管理" "v$VPS_VERSION${ref:+ (${ref:0:7})}"
    printf '  节点  %s\n' "$(nodes_brief)"
    printf '  流量  %s\n\n' "$(traffic_brief)"
    menu_pick act "nodes|节点管理" "traffic|流量限额" "system|系统设置" \
      "update|立即更新（脚本 / 内核 / 规则）" || return 0
    case $act in
      nodes) menu_nodes || return 0 ;;
      traffic) menu_traffic || return 0 ;;
      system) menu_system || return 0 ;;
      update)
        run cmd_update
        pause
        # 管理脚本更新了：换成新版本的菜单
        if [[ $(installed_ref) != "$ref" && -x $BIN_LINK ]]; then exec "$BIN_LINK"; fi
        ;;
      back) return 0 ;;
    esac
  done
}

# ---------- 节点 ----------
add_label() {
  if node_exists "$1"; then echo "修改 $(node_label "$1")"; else echo "添加 $(node_label "$1")"; fi
}

menu_nodes() {
  local act n port
  while true; do
    menu_head 节点管理
    printf '\n'
    node_summary
    printf '\n'
    menu_pick act "reality|$(add_label reality)" "ws|$(add_label ws)" "hy2|$(add_label hy2)" \
      "show|查看分享链接" "port|换端口" "reset|重置密码 / UUID（旧链接失效）" \
      "service|启动 / 停止 / 重启 / 日志" "del|删除节点|danger" || return 1
    case $act in
      reality) menu_add_reality; pause ;;
      ws) menu_add_ws; pause ;;
      hy2) menu_add_hy2; pause ;;
      show) run node_show; pause ;;
      port)
        if n=$(pick_node); then
          port=$(ask "新端口（random = 随机）")
          if [[ -n $port ]]; then run node_port "$n" "$port"; fi
          pause
        fi
        ;;
      reset)
        if n=$(pick_node) && confirm "重置 $(node_label "$n") 后旧链接立即失效，继续？"; then
          run node_reset "$n"
          pause
        fi
        ;;
      service) menu_service || return 1 ;;
      del)
        if n=$(pick_node) && confirm "确定删除 $(node_label "$n")？"; then
          run node_del "$n"
          pause
        fi
        ;;
      back) return 0 ;;
    esac
  done
}

menu_add_reality() {
  local -A N
  local port sni i args=()
  kv_load "$(node_file reality)" N
  menu_head "$(add_label reality)"
  note "不需要域名。SNI 是伪装的目标网站，选一个常见的大站即可"
  port=$(ask "端口（auto = 自动，random = 随机）" "${N[PORT]:-auto}")
  printf '\n'
  for i in "${!REALITY_SNIS[@]}"; do
    printf '  %s%2s%s  %s\n' "$CC" $((i + 1)) "$C0" "${REALITY_SNIS[i]}"
  done
  sni=$(ask "SNI（序号或直接输入域名）" "${N[SNI]:-1}")
  if [[ $sni =~ ^[0-9]+$ ]] && ((sni >= 1 && sni <= ${#REALITY_SNIS[@]})); then
    sni=${REALITY_SNIS[sni - 1]}
  fi
  [[ $port == auto ]] || args+=(--port "$port")
  args+=(--sni "$sni")
  run node_add_reality "${args[@]}"
}

menu_add_ws() {
  local -A N
  local domain port path email args=()
  kv_load "$(node_file ws)" N
  menu_head "$(add_label ws)"
  if [[ -n ${N[DOMAIN]:-} ]]; then
    domain=$(ask "域名（输入 none 改为不用域名）" "${N[DOMAIN]}")
  else
    note "有域名：自动申请 Let's Encrypt 证书（域名要先解析到本机）"
    note "没域名：直接留空，用 IP + 自签证书，证书指纹写进链接"
    domain=$(ask "域名")
  fi
  if [[ -z $domain || $domain == none ]]; then
    args+=(--no-domain)
  else
    args+=(--domain "$domain")
    email=$(ask "邮箱（证书到期提醒，可留空）" "${N[EMAIL]:-}")
    [[ -z $email ]] || args+=(--email "$email")
  fi
  port=$(ask "端口（auto = 自动，random = 随机）" "${N[PORT]:-auto}")
  [[ $port == auto ]] || args+=(--port "$port")
  path=$(ask "WebSocket 路径（auto = 随机）" "${N[WSPATH]:-auto}")
  [[ $path == auto ]] || args+=(--path "$path")
  run node_add_ws "${args[@]}"
}

menu_add_hy2() {
  local -A N
  local port sni masq args=()
  kv_load "$(node_file hy2)" N
  menu_head "$(add_label hy2)"
  note "不需要域名。使用自签证书，证书指纹写进链接"
  port=$(ask "UDP 端口（auto = 自动，random = 随机）" "${N[PORT]:-auto}")
  sni=$(ask "SNI" "${N[SNI]:-$HY2_DEFAULT_SNI}")
  masq=$(ask "伪装网站（浏览器直接访问时看到的内容）" "${N[MASQ]:-https://$HY2_DEFAULT_SNI}")
  [[ $port == auto ]] || args+=(--port "$port")
  args+=(--sni "$sni" --masq "$masq")
  run node_add_hy2 "${args[@]}"
}

menu_service() {
  local act
  while true; do
    menu_head "启动 / 停止 / 重启 / 日志"
    printf '\n'
    node_summary
    printf '\n'
    menu_pick act "restart|重启" "stop|停止" "start|启动" "log|查看日志" || return 1
    case $act in
      restart | stop | start) run svc_cmd "$act"; pause ;;
      log) svc_cmd log; pause ;;
      back) return 0 ;;
    esac
  done
}

# ---------- 流量 ----------
menu_traffic() {
  local act limited items=()
  while true; do
    traffic_status
    items=()
    if traffic_configured; then
      items+=("set|修改额度与限速" "used|校准本期已用流量（与服务商面板对齐）")
      if [[ $(kv_get "$TRAFFIC_CONF" LIMIT 1) == 1 ]]; then
        items+=("limit_off|关闭自动限速（只统计）")
      else
        items+=("limit_on|开启自动限速")
      fi
      limited=$(kv_get "$TRAFFIC_STATE" LIMITED 0)
      if [[ $limited == 1 ]]; then items+=("unlimit|本期解除限速"); fi
      items+=("remove|删除流量限额|danger")
    else
      items+=("set|设置额度与限速")
    fi
    menu_pick act "${items[@]}" || return 1
    case $act in
      set) menu_traffic_set; pause ;;
      used)
        local used
        used=$(ask "本期已用多少 GB")
        if [[ -n $used ]]; then run traffic_set --used "$used"; pause; fi
        ;;
      limit_on) run traffic_limit_toggle on; pause ;;
      limit_off) run traffic_limit_toggle off; pause ;;
      unlimit) run traffic_unlimit; pause ;;
      remove) if confirm "确定删除流量限额？"; then run traffic_remove; pause; fi ;;
      back) return 0 ;;
    esac
  done
}

menu_traffic_set() {
  local -A C
  local q p r cnt rd def
  kv_load "$TRAFFIC_CONF" C
  menu_head "流量额度与限速"
  q=$(ask "每月额度（GB）" "${C[QUOTA_GB]:-}")
  [[ -n $q ]] || { warn "没有填写额度"; return 0; }
  p=$(ask "用到额度的百分之多少开始限速" "${C[PERCENT]:-90}")
  r=$(ask "限速到多少 Mbit/s" "${C[RATE]:-1}")
  case ${C[COUNT]:-tx} in rx) def=2 ;; both) def=3 ;; *) def=1 ;; esac
  printf '\n  %s统计方向：1 只算出站（多数服务商）  2 只算入站  3 双向都算%s\n' "$CD" "$C0"
  cnt=$(ask "统计方向" "$def")
  case $cnt in 2) cnt=rx ;; 3) cnt=both ;; *) cnt=tx ;; esac
  rd=$(ask "每月几号重置（1-28，按服务商的账单日）" "${C[RESET_DAY]:-1}")
  run traffic_set --quota "$q" --percent "$p" --rate "$r" --count "$cnt" --reset-day "$rd"
}

# ---------- 系统 ----------
onoff() { if [[ $1 == 1 ]]; then printf '%s已开启%s' "$CG" "$C0"; else printf '%s已关闭%s' "$CD" "$C0"; fi; }

menu_system() {
  local act bbr host
  while true; do
    menu_head 系统设置
    printf '\n'
    if bbr_enabled; then bbr=1; else bbr=0; fi
    host=$(setting HOST)
    menu_pick act \
      "bbr|$(pad "BBR 加速" 20)$(onoff "$bbr")" \
      "cn|$(pad "屏蔽回国 IP / 域名" 20)$(onoff "$(setting BLOCK_CN 0)")" \
      "ads|$(pad "屏蔽广告域名" 20)$(onoff "$(setting BLOCK_ADS 0)")" \
      "auto|$(pad "每周自动更新" 20)$(onoff "$(setting AUTO_UPDATE 1)")" \
      "host|$(pad "分享地址" 20)${host:-自动检测}" \
      "uninstall|卸载全部|danger" || return 1
    case $act in
      bbr) if ((bbr)); then run bbr_set off; else run bbr_set on; fi; pause ;;
      cn | ads)
        if [[ $(setting "$(block_key "$act")" 0) == 1 ]]; then run block_set "$act" off; else run block_set "$act" on; fi
        pause
        ;;
      auto) if [[ $(setting AUTO_UPDATE 1) == 1 ]]; then run autoupdate_set off; else run autoupdate_set on; fi; pause ;;
      host)
        note "填 IP 或域名；auto = 重新检测公网 IP"
        host=$(ask "分享地址" "${host:-auto}")
        run host_set "$host"
        pause
        ;;
      uninstall)
        if confirm "确定卸载？会删除所有节点、证书、流量限额和本工具"; then
          run cmd_uninstall --yes
          exit 0
        fi
        ;;
      back) return 0 ;;
    esac
  done
}
