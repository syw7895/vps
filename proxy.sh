#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="vps-proxy"

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_CYAN=$'\033[36m'
else
  C_RESET=""
  C_BOLD=""
  C_DIM=""
  C_RED=""
  C_GREEN=""
  C_YELLOW=""
  C_CYAN=""
fi

XRAY_PORT="443"
XRAY_SNI="www.microsoft.com"
XRAY_TARGET="www.microsoft.com:443"
XRAY_UUID=""

HY2_PORT="8443"
HY2_DOMAIN=""
HY2_EMAIL=""
HY2_PASSWORD=""

# 大厂域名池
BIG_TECH_DOMAINS=(
  "www.bing.com"
  "www.microsoft.com"
  "www.apple.com"
  "www.amazon.com"
  "www.cloudflare.com"
)

CONFIG_DIR="/root/proxy-info"

log() {
  printf '%s[%s]%s %s\n' "$C_CYAN" "$APP_NAME" "$C_RESET" "$*"
}

die() {
  printf '%s[%s] 错误：%s%s\n' "$C_RED" "$APP_NAME" "$*" "$C_RESET" >&2
  exit 1
}

success() {
  printf '%s[%s] 完成：%s%s\n' "$C_GREEN" "$APP_NAME" "$*" "$C_RESET"
}

warn() {
  printf '%s[%s] 提醒：%s%s\n' "$C_YELLOW" "$APP_NAME" "$*" "$C_RESET"
}

hr() {
  printf '%s\n' "------------------------------------------------------------"
}

print_title() {
  printf '\n%s%s%s\n' "$C_BOLD" "$1" "$C_RESET"
  hr
}

# ==========================================
# 运行状态与错误日志探针功能
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
    printf "      %s│%s %s%s%s\n" "$C_RED" "$C_RESET" "$C_DIM" "$line" "$C_RESET"
  done <<< "$errors"
}

show_service_journal() {
  local service="$1"
  local label="$2"
  local n="${3:-40}"

  printf '\n%s[%s 最近日志]%s\n' "$C_CYAN" "$label" "$C_RESET"

  if ! command -v journalctl >/dev/null 2>&1; then
    warn "journalctl 不可用，无法读取日志"
    return
  fi

  local log_content
  log_content="$(journalctl -u "$service" -n "$n" --no-pager -o short-iso 2>/dev/null || true)"

  if [[ -z "$log_content" ]]; then
    warn "${label} 暂无日志记录"
    return
  fi

  while IFS= read -r line; do
    if [[ "$line" =~ [Ee]rr(or)?|[Ff]ail(ed)?|[Cc]rit(ical)?|CRIT|ERR ]]; then
      printf '  %s%s%s\n' "$C_RED"    "$line" "$C_RESET"
    elif [[ "$line" =~ [Ww]arn(ing)? ]]; then
      printf '  %s%s%s\n' "$C_YELLOW" "$line" "$C_RESET"
    else
      printf '  %s%s%s\n' "$C_DIM"   "$line" "$C_RESET"
    fi
  done <<< "$log_content"
}

# ==========================================
# 端口检测与随机生成
# ==========================================
check_port_in_use() {
  ss -tuln 2>/dev/null | grep -qE ":${1}\b"
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

usage() {
  cat <<'EOF'
用法：
  bash proxy.sh
  bash proxy.sh menu
  bash proxy.sh xray [参数]
  bash proxy.sh hy2 [参数]
  bash proxy.sh show
  bash proxy.sh uninstall-xray
  bash proxy.sh uninstall-hy2

示例：
  bash proxy.sh xray
  bash proxy.sh hy2
EOF
}

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "请使用 root 用户运行。"
}

require_systemd() {
  command -v systemctl >/dev/null 2>&1 || die "需要 systemctl，当前系统不支持。"
}

detect_os() {
  [[ -r /etc/os-release ]] || die "无法读取 /etc/os-release。"
  . /etc/os-release
  case "${ID:-}" in
    debian|ubuntu) log "检测到系统：${PRETTY_NAME:-$ID}。" ;;
    *) die "不支持的系统：${PRETTY_NAME:-unknown}。请使用 Debian 或 Ubuntu。" ;;
  esac
}

install_base_deps() {
  log "正在安装基础依赖。"
  apt-get update
  apt-get install -y curl ca-certificates openssl sed grep gawk coreutils unzip iproute2
}

ensure_dirs() {
  install -d -m 700 "$CONFIG_DIR"
}

validate_port() {
  local port="$1"
  [[ "$port" =~ ^[0-9]+$ ]] || die "端口无效：$port"
  (( port >= 1 && port <= 65535 )) || die "端口必须在 1 到 65535 之间：$port"
}

server_ip() {
  local ip=""
  ip="$(curl -4fsSL --max-time 5 https://api.ipify.org || true)"
  if [[ -z "$ip" ]]; then
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  fi
  [[ -n "$ip" ]] || ip="YOUR_SERVER_IP"
  printf '%s' "$ip"
}

random_hex() { openssl rand -hex "$1"; }
random_password() { openssl rand -hex 16; }
random_uuid() {
  if command -v xray >/dev/null 2>&1; then xray uuid
  elif command -v uuidgen >/dev/null 2>&1; then uuidgen
  elif [[ -r /proc/sys/kernel/random/uuid ]]; then cat /proc/sys/kernel/random/uuid
  else die "无法生成 UUID。"; fi
}

open_firewall_tcp() {
  local port="$1"
  if command -v ufw >/dev/null 2>&1; then ufw allow "${port}/tcp" >/dev/null || true; fi
}
open_firewall_udp() {
  local port="$1"
  if command -v ufw >/dev/null 2>&1; then ufw allow "${port}/udp" >/dev/null || true; fi
}

parse_xray_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --port) XRAY_PORT="${2:-}"; shift 2 ;;
      --sni) XRAY_SNI="${2:-}"; shift 2 ;;
      --target) XRAY_TARGET="${2:-}"; shift 2 ;;
      --uuid) XRAY_UUID="${2:-}"; shift 2 ;;
      --help|-h) usage; exit 0 ;;
      *) die "未知的 Xray 参数：$1" ;;
    esac
  done
}

parse_hy2_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --port) HY2_PORT="${2:-}"; shift 2 ;;
      --domain) HY2_DOMAIN="${2:-}"; shift 2 ;;
      --help|-h) usage; exit 0 ;;
      *) die "未知的 Hysteria2 参数：$1" ;;
    esac
  done
}

install_xray_core() {
  log "正在安装或更新 Xray。"
  bash -c "$(curl -LfsS https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null 2>&1
  command -v xray >/dev/null 2>&1 || die "Xray 安装失败。"
}

generate_reality_keys() {
  local key_output private_key public_key
  key_output="$(xray x25519)"
  private_key="$(printf '%s\n' "$key_output" | awk -F': ' '/PrivateKey|Private key/ {print $2; exit}')"
  public_key="$(printf '%s\n' "$key_output" | awk -F': ' '/Password \(PublicKey\)|Public key/ {print $2; exit}')"
  [[ -n "$private_key" && -n "$public_key" ]] || die "无法生成 REALITY 密钥。"
  printf '%s\n%s\n' "$private_key" "$public_key"
}

install_xray_reality() {
  parse_xray_args "$@"
  require_root; require_systemd; detect_os; validate_port "$XRAY_PORT"; install_base_deps; ensure_dirs; install_xray_core

  [[ -n "$XRAY_UUID" ]] || XRAY_UUID="$(random_uuid)"
  local short_id keys private_key public_key ip link info_file
  short_id="$(random_hex 8)"
  keys="$(generate_reality_keys)"
  private_key="$(printf '%s\n' "$keys" | sed -n '1p')"
  public_key="$(printf '%s\n' "$keys" | sed -n '2p')"
  ip="$(server_ip)"

  print_title "Xray VLESS + REALITY"
  log "正在写入 Xray REALITY 配置。"
  cat >/usr/local/etc/xray/config.json <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [{
    "tag": "vless-reality", "listen": "0.0.0.0", "port": ${XRAY_PORT}, "protocol": "vless",
    "settings": {"clients": [{"id": "${XRAY_UUID}", "flow": "xtls-rprx-vision", "email": "user"}], "decryption": "none"},
    "streamSettings": {
      "network": "raw", "security": "reality",
      "realitySettings": {"show": false, "target": "${XRAY_TARGET}", "xver": 0, "serverNames": ["${XRAY_SNI}"], "privateKey": "${private_key}", "shortIds": ["${short_id}"]}
    },
    "sniffing": {"enabled": true, "destOverride": ["http", "tls", "quic"]}
  }],
  "outbounds": [{"protocol": "freedom", "tag": "direct"}, {"protocol": "blackhole", "tag": "block"}]
}
EOF

  xray run -test -config /usr/local/etc/xray/config.json >/dev/null 2>&1 || die "Xray 配置文件测试失败！"
  systemctl enable xray
  systemctl restart xray
  open_firewall_tcp "$XRAY_PORT"

  link="vless://${XRAY_UUID}@${ip}:${XRAY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${XRAY_SNI}&fp=chrome&pbk=${public_key}&sid=${short_id}&type=tcp&headerType=none#Xray-Reality-${ip}"
  info_file="${CONFIG_DIR}/xray-reality.txt"
  cat >"$info_file" <<EOF
Xray VLESS + REALITY

地址:       ${ip}
端口:       ${XRAY_PORT}
UUID:       ${XRAY_UUID}
Flow:       xtls-rprx-vision
加密:       reality
SNI:        ${XRAY_SNI}
目标:       ${XRAY_TARGET}
PublicKey:  ${public_key}
ShortId:    ${short_id}
Fingerprint: chrome

分享链接:
${link}
EOF

  success "Xray Reality 已安装并启动。"
  printf '\n'
  cat "$info_file"
}

install_hysteria_core() {
  log "正在安装或更新 Hysteria2。"
  HYSTERIA_USER=root bash <(curl -fsSL https://get.hy2.sh/) >/dev/null 2>&1
  command -v hysteria >/dev/null 2>&1 || die "Hysteria2 安装失败。"
}

write_hy2_self_signed_cert() {
  local cert_dir="$1" cn="$2"
  install -d -m 700 "$cert_dir"
  openssl req -x509 -newkey rsa:2048 -keyout "${cert_dir}/server.key" -out "${cert_dir}/server.crt" -days 3650 -nodes -subj "/CN=${cn}" >/dev/null 2>&1
  chmod 600 "${cert_dir}/server.key"
  chmod 644 "${cert_dir}/server.crt"
}

install_hysteria2() {
  parse_hy2_args "$@"
  require_root; require_systemd; detect_os; validate_port "$HY2_PORT"; install_base_deps; ensure_dirs; install_hysteria_core

  local ip config_file cert_dir link info_file sni
  ip="$(server_ip)"
  HY2_PASSWORD="$(random_password)"
  config_file="/etc/hysteria/config.yaml"
  cert_dir="/etc/hysteria/certs"
  
  install -d -m 755 /etc/hysteria

  print_title "Hysteria2"
  
  # 域名与 SNI 处理逻辑
  if [[ -z "$HY2_DOMAIN" ]]; then
    sni=${BIG_TECH_DOMAINS[$RANDOM % ${#BIG_TECH_DOMAINS[@]}]}
    log "未输入域名，已分配随机大厂域名: $sni"
  else
    sni="$HY2_DOMAIN"
    log "使用自定义域名: $sni"
  fi

  log "正在生成 ${sni} 的自签证书。"
  write_hy2_self_signed_cert "$cert_dir" "$sni"

  cat >"$config_file" <<EOF
listen: :${HY2_PORT}

tls:
  cert: ${cert_dir}/server.crt
  key: ${cert_dir}/server.key

auth:
  type: password
  password: ${HY2_PASSWORD}

masquerade:
  type: proxy
  proxy:
    url: https://${sni}
    rewriteHost: true
EOF

  systemctl enable hysteria-server.service
  systemctl restart hysteria-server.service
  open_firewall_udp "$HY2_PORT"

  link="hysteria2://${HY2_PASSWORD}@${ip}:${HY2_PORT}/?sni=${sni}&insecure=1#Hysteria2-${ip}"
  info_file="${CONFIG_DIR}/hysteria2.txt"
  cat >"$info_file" <<EOF
Hysteria2

地址:       ${ip}
端口:       ${HY2_PORT}
密码:       ${HY2_PASSWORD}
SNI:        ${sni}
TLS 模式:   自签证书
协议:       UDP

分享链接:
${link}
EOF

  success "Hysteria2 已安装并启动。"
  printf '\n'
  cat "$info_file"
}

show_info() {
  print_title "已保存的节点信息"

  local found=false
  if [[ -f "${CONFIG_DIR}/xray-reality.txt" ]]; then
    found=true
    cat "${CONFIG_DIR}/xray-reality.txt"
    printf '\n'
  fi

  if [[ -f "${CONFIG_DIR}/hysteria2.txt" ]]; then
    found=true
    cat "${CONFIG_DIR}/hysteria2.txt"
    printf '\n'
  fi

  if ! $found; then
    log "没有找到已保存的节点信息。"
  fi

  print_title "服务运行日志"

  if command -v xray >/dev/null 2>&1; then
    printf '【Xray 状态: %b】\n' "$(service_status_label xray xray)"
    show_service_journal xray "Xray"
  fi

  if command -v hysteria >/dev/null 2>&1; then
    printf '\n【Hysteria2 状态: %b】\n' "$(service_status_label hysteria-server hysteria)"
    show_service_journal hysteria-server "Hysteria2"
  fi
}

uninstall_xray() {
  require_root
  log "正在卸载 Xray。"
  if [[ -f "/usr/local/etc/xray/config.json" ]] && command -v ufw >/dev/null 2>&1; then
    local old_port
    old_port=$(grep '"port"' /usr/local/etc/xray/config.json | grep -o '[0-9]\+' | head -1)
    [[ -n "$old_port" ]] && ufw delete allow "${old_port}/tcp" >/dev/null 2>&1 || true
  fi
  bash -c "$(curl -LfsS https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove --purge >/dev/null 2>&1 || true
  rm -f "${CONFIG_DIR}/xray-reality.txt"
  success "Xray 已卸载。"
}

uninstall_hy2() {
  require_root
  log "正在卸载 Hysteria2。"
  if [[ -f "/etc/hysteria/config.yaml" ]] && command -v ufw >/dev/null 2>&1; then
    local old_port
    old_port=$(grep '^listen:' /etc/hysteria/config.yaml | grep -o '[0-9]\+' | head -1)
    [[ -n "$old_port" ]] && ufw delete allow "${old_port}/udp" >/dev/null 2>&1 || true
  fi
  bash <(curl -fsSL https://get.hy2.sh/) --remove >/dev/null 2>&1 || true
  rm -f "${CONFIG_DIR}/hysteria2.txt"
  success "Hysteria2 已卸载。"
}

prompt_default() {
  local label="$1" default_value="$2" value
  read -r -p "${label} [${default_value}]: " value
  printf '%s' "${value:-$default_value}"
}

menu_install_xray() {
  XRAY_PORT="$(prompt_default 'Xray TCP 端口' "$XRAY_PORT")"
  XRAY_SNI="$(prompt_default 'REALITY 伪装域名 SNI' "$XRAY_SNI")"
  XRAY_TARGET="$(prompt_default 'REALITY 回落目标' "$XRAY_TARGET")"
  install_xray_reality --port "$XRAY_PORT" --sni "$XRAY_SNI" --target "$XRAY_TARGET"
}

menu_install_hy2() {
  local safe_port
  safe_port=$(generate_safe_port)
  HY2_PORT="$(prompt_default 'Hysteria2 UDP 端口' "$safe_port")"
  read -r -p "请输入伪装域名 (留空则随机使用大厂域名): " HY2_DOMAIN
  local -a args
  args=(--port "$HY2_PORT")
  [[ -n "$HY2_DOMAIN" ]] && args+=(--domain "$HY2_DOMAIN")
  install_hysteria2 "${args[@]}"
}

main_menu() {
  clear 2>/dev/null || true
  printf '\n%sVPS 代理脚本%s\n' "$C_BOLD" "$C_RESET"
  printf '%s一键安装 Xray Reality / Hysteria2%s\n' "$C_DIM" "$C_RESET"
  hr
  printf '  %s1%s  安装 Xray VLESS + REALITY\n' "$C_GREEN" "$C_RESET"
  printf '  %s2%s  安装 Hysteria2\n' "$C_GREEN" "$C_RESET"
  printf '  %s3%s  查看已保存的节点信息与日志\n' "$C_CYAN" "$C_RESET"
  printf '  %s4%s  卸载 Xray\n' "$C_YELLOW" "$C_RESET"
  printf '  %s5%s  卸载 Hysteria2\n' "$C_YELLOW" "$C_RESET"
  printf '  %s0%s  退出\n' "$C_DIM" "$C_RESET"
  hr
  printf '%s当前运行状态%s\n' "$C_BOLD" "$C_RESET"
  
  local xray_state hy2_state
  xray_state="$(service_state xray xray)"
  hy2_state="$(service_state hysteria-server hysteria)"

  printf '  Xray      : %b\n' "$(service_status_label xray xray)"
  if [[ "$xray_state" == "failed" || "$xray_state" == "stopped" ]]; then
    print_service_errors xray 5
  fi

  printf '  Hysteria2 : %b\n' "$(service_status_label hysteria-server hysteria)"
  if [[ "$hy2_state" == "failed" || "$hy2_state" == "stopped" ]]; then
    print_service_errors hysteria-server 5
  fi
  
  hr
  warn "安装前请确认 VPS 安全组已放行对应端口。"
  printf '\n'
  local choice
  read -r -p "请选择: " choice
  case "$choice" in
    1) menu_install_xray ;;
    2) menu_install_hy2 ;;
    3) show_info ;;
    4) uninstall_xray ;;
    5) uninstall_hy2 ;;
    0) exit 0 ;;
    *) die "无效选项：$choice" ;;
  esac
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
