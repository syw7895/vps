#!/usr/bin/env bash
set -Eeuo pipefail

# ==========================================
# 全局防退出异常处理 (恢复光标与颜色)
# ==========================================
trap 'printf "\033[?25h\033[0m\n"' EXIT INT TERM

# ==========================================
# 颜色与图标语义定义 (Minimal Terminal UI)
# ==========================================
C_RESET='\033[0m'
C_BOLD='\033[1m'
C_DIM='\033[2m'
C_RED='\033[31m'
C_GREEN='\033[32m'
C_YELLOW='\033[33m'
C_CYAN='\033[36m'

I_INFO="➤"
I_SUCC="✔"
I_ERR="✘"
I_WARN="⚠"
I_RUN="▶"

# ==========================================
# 变量与大厂域名池
# ==========================================
CONFIG_DIR="/root/proxy-info"

BIG_TECH_DOMAINS=(
  "www.bing.com"
  "www.microsoft.com"
  "www.apple.com"
  "www.amazon.com"
  "www.cloudflare.com"
)

# ==========================================
# UI 原语函数 (核心美化)
# ==========================================
hr() {
  printf '%b━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%b\n' "${C_DIM}" "${C_RESET}"
}

msg_info() { printf "  %b%s%b  %s\n" "${C_CYAN}" "${I_INFO}" "${C_RESET}" "$*"; }
msg_succ() { printf "  %b%s%b  %s\n" "${C_GREEN}" "${I_SUCC}" "${C_RESET}" "$*"; }
msg_err()  { printf "  %b%s%b  %s\n" "${C_RED}" "${I_ERR}" "${C_RESET}" "$*" >&2; exit 1; }
msg_warn() { printf "  %b%s%b  %s\n" "${C_YELLOW}" "${I_WARN}" "${C_RESET}" "$*"; }

# 动态 Spinner 动画 (过滤一切杂乱输出，兼容 set -e)
run_cmd() {
  local text="$1"
  shift
  "$@" >/dev/null 2>&1 &
  local pid=$!
  local frames=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
  local i=0
  printf "\033[?25l" # 隐藏光标
  while kill -0 $pid 2>/dev/null; do
    printf "\r  %b%s%b  %s" "${C_CYAN}" "${frames[i]}" "${C_RESET}" "$text"
    i=$(( (i + 1) % ${#frames[@]} ))
    sleep 0.1
  done
  printf "\033[?25h\r\033[K" # 恢复光标并清空当前行
  
  if wait "$pid" 2>/dev/null; then
    msg_succ "$text"
  else
    printf "  %b%s%b  %s (Failed)\n" "${C_RED}" "${I_ERR}" "${C_RESET}" "$text" >&2
    exit 1
  fi
}

prompt_default() {
  local label="$1"
  local default_value="$2"
  local value
  # 提示文字和 read 均绑定 /dev/tty，防止被变量捕获
  printf "  %b%s%b %s [%b%s%b]: " "${C_CYAN}" "${I_INFO}" "${C_RESET}" "$label" "${C_DIM}" "$default_value" "${C_RESET}" >/dev/tty
  read -r value </dev/tty
  printf '%s' "${value:-$default_value}"
}

# ==========================================
# 核心网络与辅助函数
# ==========================================
require_root() {
  [[ "${EUID}" -eq 0 ]] || msg_err "请使用 root 用户运行。"
}

install_base_deps() {
  run_cmd "更新软件包列表" apt-get update
  run_cmd "安装必要组件 (curl, openssl, iproute2等)" \
    env DEBIAN_FRONTEND=noninteractive apt-get install -y \
    curl ca-certificates openssl sed grep gawk coreutils unzip iproute2
}

ensure_dirs() {
  install -d -m 700 "$CONFIG_DIR"
}

install_prelude() {
  require_root
  install_base_deps
  ensure_dirs
}

server_ip() {
  local ip=""
  ip="$(curl -4fsSL --max-time 3 https://api.ipify.org || curl -6fsSL --max-time 3 https://api64.ipify.org || true)"
  if [[ -z "$ip" ]]; then
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  fi
  [[ -n "$ip" ]] || ip="YOUR_SERVER_IP"
  printf '%s' "$ip"
}

format_ip() {
  local ip="$1"
  [[ "$ip" =~ ":" ]] && printf '[%s]' "$ip" || printf '%s' "$ip"
}

check_port_in_use() {
  ss -tuln 2>/dev/null | grep -qE ":${1}\b"
}

validate_domain() {
  [[ "$1" =~ ^([a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]
}

generate_safe_port() {
  local rand_port
  while true; do
    rand_port=$(shuf -i 10000-65535 -n 1)
    if ! check_port_in_use "$rand_port"; then
      printf '%s\n' "$rand_port"
      break
    fi
  done
}

ufw_update_port() {
  local old_file="$1" new_port="$2" proto="$3"
  command -v ufw >/dev/null 2>&1 || return 0
  [[ -f "$old_file" ]] && ufw delete allow "$(<"$old_file")/${proto}" >/dev/null 2>&1 || true
  ufw allow "${new_port}/${proto}" >/dev/null 2>&1 || true
}

# ==========================================
# 日志与状态工具函数 (内联探针核心)
# ==========================================

service_state() {
  local service="$1" binary="$2"
  if systemctl is-active --quiet "$service" 2>/dev/null; then
    printf 'running'
  elif systemctl is-failed --quiet "$service" 2>/dev/null; then
    printf 'failed'
  elif command -v "$binary" >/dev/null 2>&1; then
    printf 'stopped'
  else
    printf 'missing'
  fi
}

service_status_label() {
  local service="$1" binary="$2"
  case "$(service_state "$service" "$binary")" in
    running) printf '%s✔ 运行中%s'   "$C_GREEN"  "$C_RESET" ;;
    failed)  printf '%s✘ 异常退出%s' "$C_RED"    "$C_RESET" ;;
    stopped) printf '%s✘ 已停止%s'   "$C_YELLOW" "$C_RESET" ;;
    missing) printf '%s- 未安装%s'   "$C_DIM"    "$C_RESET" ;;
  esac
}

print_service_errors() {
  local service="$1"
  local n="${2:-5}"
  command -v journalctl >/dev/null 2>&1 || return 0
  local errors
  errors="$(journalctl -u "$service" -n "$n" --no-pager -p err..emerg -o short-iso 2>/dev/null || true)"
  [[ -z "$errors" ]] && return 0
  while IFS= read -r line; do
    printf "      %b│%b %b%s%b\n" "${C_RED}" "${C_RESET}" "${C_DIM}" "$line" "${C_RESET}"
  done <<< "$errors"
}

# ==========================================
# 安装逻辑: Xray VLESS + REALITY
# ==========================================
install_xray_reality() {
  printf '\n'
  hr
  printf '  %b安装 Xray VLESS + REALITY%b\n' "${C_BOLD}" "${C_RESET}"
  hr
  
  install_prelude

  local port
  port=$(generate_safe_port)
  port=$(prompt_default '设置 Xray TCP 端口' "$port")
  if check_port_in_use "$port"; then msg_err "端口 $port 已被占用，请更换。"; fi

  local sni target
  sni=$(prompt_default 'REALITY 伪装域名 SNI' "www.microsoft.com")
  target=$(prompt_default 'REALITY 回落目标' "${sni}:443")

  run_cmd "下载并部署 Xray Core" bash -c "$(curl -LfsS https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
  
  local uuid short_id keys private_key public_key ip link info_file ip_format
  uuid="$(cat /proc/sys/kernel/random/uuid)"
  short_id="$(openssl rand -hex 8)"
  keys="$(xray x25519)"
  private_key="$(printf '%s\n' "$keys" | awk -F': ' '/PrivateKey|Private key/ {print $2; exit}')"
  public_key="$(printf '%s\n' "$keys" | awk -F': ' '/Password \(PublicKey\)|Public key/ {print $2; exit}')"
  ip="$(server_ip)"

  cat >/usr/local/etc/xray/config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [{
    "listen": "0.0.0.0",
    "port": ${port},
    "protocol": "vless",
    "settings": {
      "clients": [{ "id": "${uuid}", "flow": "xtls-rprx-vision" }],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "raw",
      "security": "reality",
      "realitySettings": {
        "show": false,
        "dest": "${target}",
        "xver": 0,
        "serverNames": [ "${sni}" ],
        "privateKey": "${private_key}",
        "shortIds": [ "${short_id}" ]
      }
    },
    "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] }
  }],
  "outbounds": [{ "protocol": "freedom" }]
}
EOF

  run_cmd "测试 Xray 配置文件" xray run -test -config /usr/local/etc/xray/config.json
  run_cmd "重启并应用 Xray 服务" systemctl restart xray
  systemctl enable xray >/dev/null 2>&1

  ufw_update_port "${CONFIG_DIR}/.xray_port" "${port}" "tcp"
  printf '%s\n' "$port" > "${CONFIG_DIR}/.xray_port"

  ip_format="$(format_ip "$ip")"
  link="vless://${uuid}@${ip_format}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=chrome&pbk=${public_key}&sid=${short_id}&type=tcp&headerType=none#Xray-Reality"
  info_file="${CONFIG_DIR}/xray-reality.txt"
  
  cat >"$info_file" <<EOF
  地址      : ${ip}
  端口      : ${port}
  UUID      : ${uuid}
  SNI       : ${sni}
  目标      : ${target}
  PublicKey : ${public_key}
  ShortId   : ${short_id}

  分享链接:
  ${link}
EOF
  printf '\n'
  msg_succ "Xray 部署完毕！配置如下："
  hr
  cat "$info_file"
  hr
}

# ==========================================
# 安装逻辑: Hysteria2 (单端口直连版)
# ==========================================
install_hysteria2() {
  printf '\n'
  hr
  printf '  %b安装 Hysteria2%b\n' "${C_BOLD}" "${C_RESET}"
  hr

  install_prelude

  # 1. 生成安全主端口
  local safe_port port
  safe_port=$(generate_safe_port)
  port=$(prompt_default "设置 Hysteria2 UDP 主端口" "$safe_port")
  
  if check_port_in_use "$port"; then msg_err "端口 $port 已占用"; fi

  # 2. 域名设置
  local custom_domain domain masquerade
  printf "  %b%s%b 伪装域名/SNI (留空将随机使用大厂域名): " "${C_CYAN}" "${I_INFO}" "${C_RESET}" >/dev/tty
  read -r custom_domain </dev/tty
  
  if [[ -z "$custom_domain" ]]; then
    domain=${BIG_TECH_DOMAINS[$RANDOM % ${#BIG_TECH_DOMAINS[@]}]}
    msg_info "未填写域名，已随机分配大厂域名: ${C_GREEN}${domain}${C_RESET}"
  else
    if ! validate_domain "$custom_domain"; then
      msg_err "自定义域名格式不合法: $custom_domain"
    fi
    domain=$custom_domain
  fi
  masquerade="https://${domain}"

  run_cmd "下载并部署 Hysteria2 Core" bash -c "$(curl -fsSL https://get.hy2.sh/)"
  
  local pass ip config_file cert_dir link info_file ip_format
  pass="$(openssl rand -hex 16)"
  ip="$(server_ip)"
  config_file="/etc/hysteria/config.yaml"
  cert_dir="/etc/hysteria/certs"

  install -d -m 755 /etc/hysteria
  install -d -m 755 "$cert_dir"
  
  run_cmd "生成 [${domain}] 伪装自签证书" \
    openssl req -x509 -newkey rsa:2048 \
      -keyout "${cert_dir}/server.key" -out "${cert_dir}/server.crt" \
      -days 3650 -nodes -subj "/CN=${domain}"
  
  chmod 600 "${cert_dir}/server.key"
  chmod 644 "${cert_dir}/server.crt"
  
  cat >"$config_file" <<EOF
listen: :${port}
tls:
  cert: ${cert_dir}/server.crt
  key: ${cert_dir}/server.key
auth:
  type: password
  password: ${pass}
masquerade:
  type: proxy
  proxy:
    url: ${masquerade}
    rewriteHost: true
EOF

  chown -R hysteria:hysteria /etc/hysteria 2>/dev/null || true

  run_cmd "重启并应用 Hysteria2 服务" systemctl restart hysteria-server.service
  systemctl enable hysteria-server.service >/dev/null 2>&1

  ufw_update_port "${CONFIG_DIR}/.hy2_port" "$port" "udp"
  printf '%s\n' "$port" > "${CONFIG_DIR}/.hy2_port"

  ip_format="$(format_ip "$ip")"
  link="hysteria2://${pass}@${ip_format}:${port}/?insecure=1&sni=${domain}#Hysteria2"
  info_file="${CONFIG_DIR}/hysteria2.txt"

  cat >"$info_file" <<EOF
  地址      : ${ip}
  端口      : ${port}
  密码      : ${pass}
  SNI       : ${domain}
  伪装网站  : ${masquerade}
  
  分享链接:
  ${link}
EOF
  printf '\n'
  msg_succ "Hysteria2 部署完毕！配置如下："
  hr
  cat "$info_file"
  hr
}

# ==========================================
# 卸载与清理
# ==========================================
uninstall_xray() {
  printf '\n'
  hr
  printf '  %b彻底卸载 Xray%b\n' "${C_BOLD}" "${C_RESET}"
  hr
  if [[ -f "${CONFIG_DIR}/.xray_port" ]] && command -v ufw >/dev/null 2>&1; then
    ufw delete allow "$(<"${CONFIG_DIR}/.xray_port")/tcp" >/dev/null 2>&1 || true
    rm -f "${CONFIG_DIR}/.xray_port"
  fi
  run_cmd "清理 Xray 服务及文件" bash -c "$(curl -LfsS https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove --purge
  rm -f "${CONFIG_DIR}/xray-reality.txt"
}

uninstall_hy2() {
  printf '\n'
  hr
  printf '  %b彻底卸载 Hysteria2%b\n' "${C_BOLD}" "${C_RESET}"
  hr
  if [[ -f "${CONFIG_DIR}/.hy2_port" ]] && command -v ufw >/dev/null 2>&1; then
    ufw delete allow "$(<"${CONFIG_DIR}/.hy2_port")/udp" >/dev/null 2>&1 || true
    rm -f "${CONFIG_DIR}/.hy2_port"
  fi
  
  run_cmd "清理 Hysteria2 服务及文件" bash <(curl -fsSL https://get.hy2.sh/) --remove
  rm -f "${CONFIG_DIR}/hysteria2.txt"
}

# ==========================================
# 状态展示与菜单框架
# ==========================================
show_info() {
  printf '\n'
  hr
  printf '  %b已保存的节点信息%b\n' "${C_BOLD}" "${C_RESET}"
  hr
  if [[ -f "${CONFIG_DIR}/xray-reality.txt" ]]; then
    printf "  %b[Xray VLESS+REALITY]%b\n" "${C_CYAN}" "${C_RESET}"
    cat "${CONFIG_DIR}/xray-reality.txt"
    printf '\n'
  fi
  if [[ -f "${CONFIG_DIR}/hysteria2.txt" ]]; then
    printf "  %b[Hysteria2]%b\n" "${C_CYAN}" "${C_RESET}"
    cat "${CONFIG_DIR}/hysteria2.txt"
    printf '\n'
  fi
  if [[ ! -f "${CONFIG_DIR}/xray-reality.txt" && ! -f "${CONFIG_DIR}/hysteria2.txt" ]]; then
    msg_warn "没有找到已保存的节点信息。"
  fi
  hr
}

show_protocol_status() {
  local title="$1" service="$2" binary="$3" port_file="$4" proto="$5"
  
  printf '\n'
  hr
  printf '  %b%s 深度运行探针%b\n' "${C_BOLD}" "${title}" "${C_RESET}"
  hr
  printf '  服务状态:   %b\n' "$(service_status_label "$service" "$binary")"

  if systemctl is-enabled --quiet "$service" 2>/dev/null; then
    printf '  开机自启:   %s\n' "已启用"
  else
    printf '  开机自启:   %s\n' "未启用"
  fi

  if [[ -f "$port_file" ]]; then
    printf '  监听端口:   %s/%s\n' "$(<"$port_file")" "$proto"
  else
    printf '  监听端口:   %s\n' "未知"
  fi

  if systemctl is-active --quiet "$service" 2>/dev/null; then
    printf '  进程检查:   %s\n' "正常"
  else
    printf '  进程检查:   %s\n' "异常或未启动"
  fi

  hr
  printf '  %b最近日志（20 行）%b\n' "${C_DIM}" "${C_RESET}"
  if command -v journalctl >/dev/null 2>&1; then
    journalctl --no-pager -n 20 -u "$service" 2>/dev/null | sed 's/^/    /' || printf '    暂无日志。\n'
  else
    printf '    暂无日志。\n'
  fi
  printf '\n'
}

pause_menu() {
  local ignored
  printf '\n'
  read -r -p "  按回车返回菜单..." ignored
}

# ==========================================
# 二级子菜单
# ==========================================
menu_xray() {
  local choice
  while true; do
    clear 2>/dev/null || true
    printf '\n'
    printf '  %b%s%b\n' "${C_BOLD}${C_CYAN}" "X R A Y   M E N U" "${C_RESET}"
    hr
    printf '  %b1.%b 安装/重装 Xray (VLESS+REALITY)\n' "${C_BOLD}" "${C_RESET}"
    printf '  %b2.%b 深度探针：查看运行状态与日志\n' "${C_CYAN}" "${C_RESET}"
    printf '  %b3.%b 彻底卸载 Xray\n' "${C_YELLOW}" "${C_RESET}"
    printf '  %b0.%b 返回上一级\n' "${C_DIM}" "${C_RESET}"
    hr
    
    local xray_state
    xray_state="$(service_state xray xray)"
    printf '  当前状态: %b\n' "$(service_status_label xray xray)"
    if [[ "$xray_state" == "failed" || "$xray_state" == "stopped" ]]; then
      print_service_errors xray 5
    fi
    printf '\n'

    printf "  %b%s%b " "${C_CYAN}" "${I_INFO}" "${C_RESET}"
    read -r -p "请选择操作 [0-3]: " choice
    case "$choice" in
      1) install_xray_reality; pause_menu ;;
      2) show_protocol_status "Xray" "xray" "xray" "${CONFIG_DIR}/.xray_port" "tcp"; pause_menu ;;
      3) uninstall_xray; pause_menu ;;
      0) return 0 ;;
      *) msg_warn "无效选项：$choice"; sleep 1 ;;
    esac
  done
}

menu_hy2() {
  local choice
  while true; do
    clear 2>/dev/null || true
    printf '\n'
    printf '  %b%s%b\n' "${C_BOLD}${C_CYAN}" "H Y S T E R I A 2   M E N U" "${C_RESET}"
    hr
    printf '  %b1.%b 安装/重装 Hysteria2\n' "${C_BOLD}" "${C_RESET}"
    printf '  %b2.%b 深度探针：查看运行状态与日志\n' "${C_CYAN}" "${C_RESET}"
    printf '  %b3.%b 彻底卸载 Hysteria2\n' "${C_YELLOW}" "${C_RESET}"
    printf '  %b0.%b 返回上一级\n' "${C_DIM}" "${C_RESET}"
    hr
    
    local hy2_state
    hy2_state="$(service_state hysteria-server hysteria)"
    printf '  当前状态: %b\n' "$(service_status_label hysteria-server hysteria)"
    if [[ "$hy2_state" == "failed" || "$hy2_state" == "stopped" ]]; then
      print_service_errors hysteria-server 5
    fi
    printf '\n'

    printf "  %b%s%b " "${C_CYAN}" "${I_INFO}" "${C_RESET}"
    read -r -p "请选择操作 [0-3]: " choice
    case "$choice" in
      1) install_hysteria2; pause_menu ;;
      2) show_protocol_status "Hysteria2" "hysteria-server" "hysteria" "${CONFIG_DIR}/.hy2_port" "udp"; pause_menu ;;
      3) uninstall_hy2; pause_menu ;;
      0) return 0 ;;
      *) msg_warn "无效选项：$choice"; sleep 1 ;;
    esac
  done
}

# ==========================================
# 主界面
# ==========================================
main_menu() {
  while true; do
    clear 2>/dev/null || true
    printf '\n'
    printf '  %b%s%b\n' "${C_BOLD}${C_CYAN}" "V P S   P R O X Y   P A N E L" "${C_RESET}"
    printf '  %bMinimal Terminal UI & Advanced Probes%b\n' "${C_DIM}" "${C_RESET}"
    hr
    printf '  %b1.%b ⚡ 管理 Xray (VLESS+REALITY)\n' "${C_GREEN}" "${C_RESET}"
    printf '  %b2.%b 🚀 管理 Hysteria2\n' "${C_GREEN}" "${C_RESET}"
    printf '  %b3.%b 📋 查看已保存的所有节点信息\n' "${C_CYAN}" "${C_RESET}"
    printf '  %b0.%b 🚪 退出\n' "${C_DIM}" "${C_RESET}"
    hr
    
    printf '  %b%s 实时运行大盘%b\n' "${C_BOLD}" "${I_RUN}" "${C_RESET}"
    
    local xray_state hy2_state
    xray_state="$(service_state xray xray)"
    hy2_state="$(service_state hysteria-server hysteria)"

    printf '    Xray      : %b\n' "$(service_status_label xray xray)"
    if [[ "$xray_state" == "failed" || "$xray_state" == "stopped" ]]; then
      print_service_errors xray 5
    fi

    printf '    Hysteria2 : %b\n' "$(service_status_label hysteria-server hysteria)"
    if [[ "$hy2_state" == "failed" || "$hy2_state" == "stopped" ]]; then
      print_service_errors hysteria-server 5
    fi
    printf '\n'

    printf "  %b%s%b " "${C_CYAN}" "${I_INFO}" "${C_RESET}"
    read -r -p "请选择操作 [0-3]: " choice
    case "$choice" in
      1) menu_xray ;;
      2) menu_hy2 ;;
      3) show_info; pause_menu ;;
      0) printf '\n  %bGoodbye!%b\n\n' "${C_CYAN}" "${C_RESET}"; exit 0 ;;
      *) msg_warn "无效选项"; sleep 1 ;;
    esac
  done
}

main_menu
