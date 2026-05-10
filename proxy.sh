  local binary="$2"

  if systemctl is-active --quiet "$service" 2>/dev/null; then
    printf '%s运行中%s' "$C_GREEN" "$C_RESET"
  elif command -v "$binary" >/dev/null 2>&1; then
    printf '%s已停止%s' "$C_RED" "$C_RESET"
  else
    printf '%s未安装%s' "$C_DIM" "$C_RESET"
  fi
}

show_protocol_status() {
  local title="$1"
  local service="$2"
  local binary="$3"
  local port_file="$4"
  local proto="$5"

  print_title "${title} 运行状态"
  printf '服务状态:   %b\n' "$(service_status_label "$service" "$binary")"

  if systemctl is-enabled --quiet "$service" 2>/dev/null; then
    printf '开机自启:   %s\n' "已启用"
  else
    printf '开机自启:   %s\n' "未启用"
  fi

  if [[ -f "$port_file" ]]; then
    printf '监听端口:   %s/%s\n' "$(<"$port_file")" "$proto"
  else
    printf '监听端口:   %s\n' "未知"
  fi

  if systemctl is-active --quiet "$service" 2>/dev/null; then
    printf '进程检查:   %s\n' "正常"
  else
    printf '进程检查:   %s\n' "异常或未启动"
  fi

  hr
  printf '最近日志（20 行）\n'
  journalctl --no-pager -n 20 -u "$service" 2>/dev/null || printf '暂无日志。\n'
}

pause_menu() {
  local ignored
  printf '\n'
  read -r -p "按回车返回菜单..." ignored
}

menu_xray() {
  local choice
  while true; do
    clear 2>/dev/null || true
    printf '\n%sXray 菜单%s\n' "$C_BOLD" "$C_RESET"
    hr
    printf '  %s1%s  安装/重装 Xray VLESS + REALITY\n' "$C_GREEN" "$C_RESET"
    printf '  %s2%s  查看运行状态\n' "$C_CYAN" "$C_RESET"
    printf '  %s3%s  卸载 Xray\n' "$C_YELLOW" "$C_RESET"
    printf '  %s0%s  返回上级菜单\n' "$C_DIM" "$C_RESET"
    hr
    printf '当前状态: %b\n' "$(service_status_label xray xray)"
    printf '\n'

    read -r -p "请选择: " choice
    case "$choice" in
      1) menu_install_xray; pause_menu ;;
      2) show_protocol_status "Xray" "xray" "xray" "${CONFIG_DIR}/.xray_port" "tcp"; pause_menu ;;
      3) uninstall_xray; pause_menu ;;
      0) return 0 ;;
      *) warn "无效选项：$choice"; sleep 1 ;;
    esac
  done
}

menu_hy2() {
  local choice
  while true; do
    clear 2>/dev/null || true
    printf '\n%sHysteria2 菜单%s\n' "$C_BOLD" "$C_RESET"
    hr
    printf '  %s1%s  安装/重装 Hysteria2\n' "$C_GREEN" "$C_RESET"
    printf '  %s2%s  查看运行状态\n' "$C_CYAN" "$C_RESET"
    printf '  %s3%s  卸载 Hysteria2\n' "$C_YELLOW" "$C_RESET"
    printf '  %s0%s  返回上级菜单\n' "$C_DIM" "$C_RESET"
    hr
    printf '当前状态: %b\n' "$(service_status_label hysteria-server hysteria)"
    printf '\n'

    read -r -p "请选择: " choice
    case "$choice" in
      1) menu_install_hy2; pause_menu ;;
      2) show_protocol_status "Hysteria2" "hysteria-server" "hysteria" "${CONFIG_DIR}/.hy2_port" "udp"; pause_menu ;;
      3) uninstall_hy2; pause_menu ;;
      0) return 0 ;;
      *) warn "无效选项：$choice"; sleep 1 ;;
    esac
  done
}

main_menu() {
  while true; do
    clear 2>/dev/null || true
    printf '\n%sVPS 代理脚本%s\n' "$C_BOLD" "$C_RESET"
    printf '%sXray / Hysteria2 二级菜单%s\n' "$C_DIM" "$C_RESET"
    hr
    printf '  %s1%s  进入 Xray 菜单\n' "$C_GREEN" "$C_RESET"
    printf '  %s2%s  进入 Hysteria2 菜单\n' "$C_GREEN" "$C_RESET"
    printf '  %s3%s  查看已保存的节点信息\n' "$C_CYAN" "$C_RESET"
    printf '  %s0%s  退出\n' "$C_DIM" "$C_RESET"
    hr
    printf '当前状态\n'
    printf '  Xray      : %b\n' "$(service_status_label xray xray)"
    printf '  Hysteria2 : %b\n' "$(service_status_label hysteria-server hysteria)"
    hr
    warn "安装前请确认 VPS 安全组已放行对应端口。"
    printf '\n'

    local choice
    read -r -p "请选择: " choice
    case "$choice" in
      1) menu_xray ;;
      2) menu_hy2 ;;
      3) show_info; pause_menu ;;
      0) printf '\n再见。\n'; exit 0 ;;
      *) warn "无效选项：$choice"; sleep 1 ;;
    esac
  done
}

main() {
  local command="${1:-menu}"
  if [[ $# -gt 0 ]]; then
    shift
  fi

  case "$command" in
    menu) main_menu ;;
    xray) install_xray_reality "$@" ;;
    hy2|hysteria2) install_hysteria2 "$@" ;;
    show) show_info ;;
    uninstall-xray) uninstall_xray ;;
    uninstall-hy2|uninstall-hysteria2) uninstall_hy2 ;;
    --help|-h|help) usage ;;
    *) die "未知命令：$command" ;;
  esac
}

main "$@"
