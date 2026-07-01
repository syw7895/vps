#!/usr/bin/env bash
set -Eeuo pipefail

# ===== 基础配置 =====
APP_NAME="vps-proxy"
CONFIG_DIR="/root/proxy-info"

# Xray 默认参数
XRAY_PORT="443"
XRAY_SNI="${REALITY_SERVER_NAME:-www.cloudflare.com}"
XRAY_TARGET="${REALITY_DEST:-www.cloudflare.com:443}"
XRAY_UUID=""
XRAY_CONFIG="/usr/local/etc/xray/config.json"
XRAY_INFO_FILE="${CONFIG_DIR}/xray-reality.txt"

# Hysteria2 默认参数
HY2_PORT=""
HY2_PASSWORD=""
HY2_DOMAIN=""
HY2_MASQUERADE="https://www.bing.com"
HY2_PORT_SET_BY_USER="0"
HY2_CONFIG="/etc/hysteria/config.yaml"
HY2_CERT_DIR="/etc/hysteria/certs"
HY2_INFO_FILE="${CONFIG_DIR}/hysteria2.txt"

# 远程安装脚本地址（可按需固定版本）
XRAY_INSTALLER_URL="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"
HY2_INSTALLER_URL="https://get.hy2.sh/"

# 可选：固定脚本哈希，留空表示仅下载后执行
# 例如：XRAY_INSTALLER_SHA256="<sha256>"
XRAY_INSTALLER_SHA256=""
HY2_INSTALLER_SHA256=""

# 默认大厂域名池（HY2 留空时随机）
BIG_TECH_DOMAINS=(
  "www.bing.com"
  "www.microsoft.com"
  "www.apple.com"
  "www.amazon.com"
  "www.cloudflare.com"
)

# ===== 终端颜色 =====
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

# ===== 输出函数 =====
log()   { printf '%s[%s]%s %s\n' "$C_CYAN" "$APP_NAME" "$C_RESET" "$*"; }
ok()    { printf '%s[%s] 完成:%s %s\n' "$C_GREEN" "$APP_NAME" "$C_RESET" "$*"; }
warn()  { printf '%s[%s] 提醒:%s %s\n' "$C_YELLOW" "$APP_NAME" "$C_RESET" "$*"; }
fail()  { printf '%s[%s] 错误:%s %s\n' "$C_RED" "$APP_NAME" "$C_RESET" "$*" >&2; exit 1; }
hr()    { printf '%s\n' "------------------------------------------------------------"; }
title() { printf '\n%s%s%s\n' "$C_BOLD" "$1" "$C_RESET"; hr; }

on_error() {
  local line="$1" code="$2"
  fail "脚本在第 ${line} 行失败，退出码：${code}"
}
trap 'on_error "$LINENO" "$?"' ERR

usage() {
  cat <<'EOF'
用法:
  bash proxy.sh
  bash proxy.sh menu
  bash proxy.sh xray [参数]
  bash proxy.sh hy2 [参数]
  bash proxy.sh v2
  bash proxy.sh install-shortcut
  bash proxy.sh show
  bash proxy.sh uninstall-xray
  bash proxy.sh uninstall-hy2
  bash proxy.sh uninstall-v2

Xray VLESS + REALITY 参数:
  --port PORT          TCP 监听端口（默认: 443）
  --sni DOMAIN         REALITY 伪装域名（默认: www.cloudflare.com）
  --target HOST:PORT   REALITY 回落目标（默认: www.cloudflare.com:443）
  --uuid UUID          客户端 UUID（不填自动生成）

Hysteria2 参数:
  --port PORT          UDP 监听端口（不填自动随机）
  --password VALUE     认证密码（不填自动生成）
  --domain DOMAIN      证书/SNI 域名（不填默认随机大厂域名）
  --masquerade URL     伪装网站（默认: https://www.bing.com）

示例:
  bash proxy.sh xray
  bash proxy.sh xray --port 443 --sni www.cloudflare.com --target www.cloudflare.com:443
  bash proxy.sh hy2
  bash proxy.sh hy2 --domain example.com
  bash proxy.sh install-shortcut
  v2
EOF
}

# ===== 基础检查 =====
require_root() {
  [[ "${EUID}" -eq 0 ]] || fail "请使用 root 用户运行。"
}

require_systemd() {
  command -v systemctl >/dev/null 2>&1 || fail "当前系统不支持 systemctl。"
}

detect_os() {
  [[ -r /etc/os-release ]] || fail "无法读取 /etc/os-release。"
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}" in
    debian|ubuntu) log "检测到系统：${PRETTY_NAME:-$ID}" ;;
    *) fail "不支持的系统：${PRETTY_NAME:-unknown}（仅支持 Debian/Ubuntu）" ;;
  esac
}

install_base_deps() {
  log "安装基础依赖..."
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    curl ca-certificates openssl sed grep gawk coreutils unzip iproute2
}

ensure_dirs() {
  install -d -m 700 "$CONFIG_DIR"
}

download_remote_script() {
  local url="$1" out="$2"
  curl -fL --retry 3 --connect-timeout 10 --max-time 120 -o "$out" "$url"
  [[ -s "$out" ]] || fail "下载安装脚本失败：${url}"
}

verify_script_sha256() {
  local file="$1" expected="$2"
  [[ -z "$expected" ]] && return 0

  local actual
  actual="$(sha256sum "$file" | awk '{print $1}')"
  [[ "$actual" == "$expected" ]] || fail "安装脚本哈希校验失败。"
}

run_remote_script() {
  local url="$1" expected_sha="$2"
  shift 2

  local script_file rc=0
  script_file="$(mktemp /tmp/${APP_NAME}.installer.XXXXXX.sh)"
  download_remote_script "$url" "$script_file"
  verify_script_sha256 "$script_file" "$expected_sha"
  chmod 700 "$script_file"

  bash "$script_file" "$@" || rc=$?
  rm -f "$script_file"
  (( rc == 0 )) || return "$rc"
}

# ===== 校验与工具函数 =====
validate_port() {
  local port="$1"
  [[ "$port" =~ ^[0-9]+$ ]] || fail "端口无效：${port}"
  (( port >= 1 && port <= 65535 )) || fail "端口必须在 1-65535：${port}"
}

validate_target() {
  local target="$1"
  [[ "$target" =~ ^[^:]+:[0-9]+$ ]] || fail "target 格式错误，应为 host:port，例如 www.microsoft.com:443"
}

validate_domain() {
  local domain="$1"
  [[ "$domain" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,}$ ]] || \
    fail "域名格式错误：${domain}"
}

is_port_in_use() {
  local port="$1"
  ss -tuln 2>/dev/null | grep -qE "[\.\:]{1}${port}[[:space:]]"
}

random_free_port() {
  local port
  while true; do
    port="$(shuf -i 10000-65535 -n 1)"
    if ! is_port_in_use "$port"; then
      printf '%s' "$port"
      return 0
    fi
  done
}

random_big_tech_domain() {
  local idx=$((RANDOM % ${#BIG_TECH_DOMAINS[@]}))
  printf '%s' "${BIG_TECH_DOMAINS[$idx]}"
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

random_password() {
  openssl rand -hex 16
}

random_uuid() {
  if command -v xray >/dev/null 2>&1; then
    xray uuid
  elif command -v uuidgen >/dev/null 2>&1; then
    uuidgen
  elif [[ -r /proc/sys/kernel/random/uuid ]]; then
    cat /proc/sys/kernel/random/uuid
  else
    fail "无法生成 UUID。"
  fi
}

open_firewall_tcp() {
  local port="$1"
  if command -v ufw >/dev/null 2>&1; then
    ufw allow "${port}/tcp" >/dev/null || true
  fi
}

open_firewall_udp() {
  local port="$1"
  if command -v ufw >/dev/null 2>&1; then
    ufw allow "${port}/udp" >/dev/null || true
  fi
}

# ===== 服务状态显示 =====
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
    running) printf '%s✓ 运行中%s' "$C_GREEN" "$C_RESET" ;;
    failed)  printf '%s✗ 异常%s' "$C_RED" "$C_RESET" ;;
    stopped) printf '%s• 已停止%s' "$C_YELLOW" "$C_RESET" ;;
    missing) printf '%s- 未安装%s' "$C_DIM" "$C_RESET" ;;
  esac
}

show_journal() {
  local service="$1" label="$2" lines="${3:-25}"
  command -v journalctl >/dev/null 2>&1 || return 0
  printf '\n%s[%s 最近日志]%s\n' "$C_CYAN" "$label" "$C_RESET"
  journalctl -u "$service" -n "$lines" --no-pager -o short-iso 2>/dev/null || true
}

# ===== 参数解析 =====
parse_xray_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --port) XRAY_PORT="${2:-}"; shift 2 ;;
      --sni) XRAY_SNI="${2:-}"; shift 2 ;;
      --target) XRAY_TARGET="${2:-}"; shift 2 ;;
      --uuid) XRAY_UUID="${2:-}"; shift 2 ;;
      --help|-h) usage; exit 0 ;;
      *) fail "未知 Xray 参数：$1" ;;
    esac
  done
}

parse_hy2_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --port) HY2_PORT="${2:-}"; HY2_PORT_SET_BY_USER="1"; shift 2 ;;
      --password) HY2_PASSWORD="${2:-}"; shift 2 ;;
      --domain) HY2_DOMAIN="${2:-}"; shift 2 ;;
      --masquerade) HY2_MASQUERADE="${2:-}"; shift 2 ;;
      --help|-h) usage; exit 0 ;;
      *) fail "未知 Hysteria2 参数：$1" ;;
    esac
  done
}

# ===== Xray 安装 =====
install_xray_core() {
  log "安装或更新 Xray..."
  run_remote_script "$XRAY_INSTALLER_URL" "$XRAY_INSTALLER_SHA256" install
  command -v xray >/dev/null 2>&1 || fail "Xray 安装失败。"
}

generate_reality_keys() {
  local out private_key public_key
  out="$(xray x25519)"
  private_key="$(printf '%s\n' "$out" | awk -F': ' '/PrivateKey|Private key/ {print $2; exit}')"
  public_key="$(printf '%s\n' "$out" | awk -F': ' '/Password \(PublicKey\)|Public key/ {print $2; exit}')"
  [[ -n "$private_key" && -n "$public_key" ]] || fail "REALITY 密钥生成失败。"
  printf '%s\n%s\n' "$private_key" "$public_key"
}

install_xray_reality() {
  parse_xray_args "$@"
  require_root
  require_systemd
  detect_os
  install_base_deps
  ensure_dirs

  validate_port "$XRAY_PORT"
  validate_target "$XRAY_TARGET"
  validate_domain "$XRAY_SNI"
  if is_port_in_use "$XRAY_PORT"; then
    fail "Xray 端口已被占用：${XRAY_PORT}"
  fi

  install_xray_core
  [[ -n "$XRAY_UUID" ]] || XRAY_UUID="$(random_uuid)"

  local short_id keys private_key public_key ip link
  short_id="$(openssl rand -hex 8)"
  keys="$(generate_reality_keys)"
  private_key="$(printf '%s\n' "$keys" | sed -n '1p')"
  public_key="$(printf '%s\n' "$keys" | sed -n '2p')"
  ip="$(server_ip)"

  title "Xray VLESS + REALITY"
  log "写入 Xray 配置..."
  cat >"$XRAY_CONFIG" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "tag": "vless-reality",
      "listen": "0.0.0.0",
      "port": ${XRAY_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${XRAY_UUID}",
            "flow": "xtls-rprx-vision",
            "email": "user"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${XRAY_TARGET}",
          "xver": 0,
          "serverNames": ["${XRAY_SNI}"],
          "privateKey": "${private_key}",
          "shortIds": ["${short_id}"]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "block" }
  ]
}
EOF

  xray run -test -config "$XRAY_CONFIG"
  systemctl enable xray >/dev/null 2>&1
  systemctl restart xray
  open_firewall_tcp "$XRAY_PORT"

  link="vless://${XRAY_UUID}@${ip}:${XRAY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${XRAY_SNI}&fp=chrome&pbk=${public_key}&sid=${short_id}&type=tcp&headerType=none#Xray-Reality-${ip}"
  cat >"$XRAY_INFO_FILE" <<EOF
Xray VLESS + REALITY

地址:       ${ip}
端口:       ${XRAY_PORT}
UUID:       ${XRAY_UUID}
Flow:       xtls-rprx-vision
SNI:        ${XRAY_SNI}
目标:       ${XRAY_TARGET}
PublicKey:  ${public_key}
ShortId:    ${short_id}

分享链接:
${link}
EOF

  ok "Xray Reality 已安装并启动。"
  printf '\n'
  cat "$XRAY_INFO_FILE"
}

# ===== Hysteria2 安装 =====
install_hysteria_core() {
  log "安装或更新 Hysteria2..."
  HYSTERIA_USER=root run_remote_script "$HY2_INSTALLER_URL" "$HY2_INSTALLER_SHA256"
  command -v hysteria >/dev/null 2>&1 || fail "Hysteria2 安装失败。"
}

write_hy2_self_signed_cert() {
  local cert_dir="$1" cn="$2"
  install -d -m 700 "$cert_dir"
  openssl req -x509 -newkey rsa:2048 \
    -keyout "${cert_dir}/server.key" \
    -out "${cert_dir}/server.crt" \
    -days 3650 \
    -nodes \
    -subj "/CN=${cn}" >/dev/null 2>&1
  chmod 600 "${cert_dir}/server.key"
  chmod 644 "${cert_dir}/server.crt"
}

install_hysteria2() {
  parse_hy2_args "$@"
  require_root
  require_systemd
  detect_os
  install_base_deps
  ensure_dirs

  if [[ "$HY2_PORT_SET_BY_USER" == "1" ]]; then
    validate_port "$HY2_PORT"
    if is_port_in_use "$HY2_PORT"; then
      fail "Hysteria2 端口已被占用：${HY2_PORT}"
    fi
  else
    HY2_PORT="$(random_free_port)"
    log "未指定 Hysteria2 端口，已随机分配：${HY2_PORT}"
  fi

  if [[ -z "$HY2_DOMAIN" ]]; then
    HY2_DOMAIN="$(random_big_tech_domain)"
    log "未填写域名，默认使用大厂域名：${HY2_DOMAIN}"
  else
    validate_domain "$HY2_DOMAIN"
    log "使用自定义域名：${HY2_DOMAIN}"
  fi

  [[ -n "$HY2_PASSWORD" ]] || HY2_PASSWORD="$(random_password)"
  install_hysteria_core

  local ip sni link
  ip="$(server_ip)"
  sni="${HY2_DOMAIN}"

  install -d -m 755 /etc/hysteria
  title "Hysteria2"
  log "写入 Hysteria2 自签证书配置..."
  write_hy2_self_signed_cert "$HY2_CERT_DIR" "$HY2_DOMAIN"

  cat >"$HY2_CONFIG" <<EOF
listen: :${HY2_PORT}

tls:
  cert: ${HY2_CERT_DIR}/server.crt
  key: ${HY2_CERT_DIR}/server.key

auth:
  type: password
  password: ${HY2_PASSWORD}

masquerade:
  type: proxy
  proxy:
    url: ${HY2_MASQUERADE}
    rewriteHost: true
EOF

  systemctl enable hysteria-server.service >/dev/null 2>&1
  systemctl restart hysteria-server.service
  open_firewall_udp "$HY2_PORT"

  link="hysteria2://${HY2_PASSWORD}@${ip}:${HY2_PORT}/?sni=${sni}&insecure=1#Hysteria2-${ip}"
  cat >"$HY2_INFO_FILE" <<EOF
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

  ok "Hysteria2 已安装并启动。"
  printf '\n'
  cat "$HY2_INFO_FILE"
}

# ===== 信息展示与卸载 =====
show_info() {
  title "已保存的节点信息"
  local found="0"

  if [[ -f "$XRAY_INFO_FILE" ]]; then
    found="1"
    cat "$XRAY_INFO_FILE"
    printf '\n'
  fi
  if [[ -f "$HY2_INFO_FILE" ]]; then
    found="1"
    cat "$HY2_INFO_FILE"
    printf '\n'
  fi
  [[ "$found" == "1" ]] || log "暂无已保存节点信息。"

  title "服务状态"
  printf 'Xray      : %b\n' "$(service_status_label xray xray)"
  printf 'Hysteria2 : %b\n' "$(service_status_label hysteria-server hysteria)"

  show_journal xray "Xray"
  show_journal hysteria-server "Hysteria2"
}

uninstall_xray() {
  require_root
  log "卸载 Xray..."
  if run_remote_script "$XRAY_INSTALLER_URL" "$XRAY_INSTALLER_SHA256" remove --purge; then
    rm -f "$XRAY_INFO_FILE"
    ok "Xray 已卸载。"
  else
    fail "Xray 卸载失败，请检查日志后重试。"
  fi
}

uninstall_hy2() {
  require_root
  log "卸载 Hysteria2..."
  if run_remote_script "$HY2_INSTALLER_URL" "$HY2_INSTALLER_SHA256" --remove; then
    rm -f "$HY2_INFO_FILE"
    ok "Hysteria2 已卸载。"
  else
    fail "Hysteria2 卸载失败，请检查日志后重试。"
  fi
}

install_v2_shortcut() {
  require_root

  local source_path target_path script_url
  source_path="$(readlink -f "$0" 2>/dev/null || true)"
  target_path="/usr/local/bin/v2"
  script_url="https://raw.githubusercontent.com/syw7895/vps/main/proxy.sh"

  if [[ -n "$source_path" && -f "$source_path" && "$source_path" != /dev/fd/* ]]; then
    chmod +x "$source_path"
    ln -sf "$source_path" "$target_path"
  else
    log "检测到在线执行模式，改为下载最新脚本安装快捷命令..."
    curl -fL --retry 3 --connect-timeout 10 --max-time 120 -o "$target_path" "$script_url"
    chmod 755 "$target_path"
  fi

  ok "已安装快捷命令：v2"
  log "现在可直接输入：v2"
}

# ===== 菜单 =====
prompt_default() {
  local label="$1" default_value="$2" value
  read -r -p "${label} [${default_value}]: " value
  printf '%s' "${value:-$default_value}"
}

select_reality_target() {
  local choice custom_sni custom_target

  printf '\n请选择 REALITY 伪装目标:\n'
  printf '  1  www.cloudflare.com（推荐）\n'
  printf '  2  www.yahoo.com\n'
  printf '  3  www.microsoft.com\n'
  printf '  4  自定义\n'
  read -r -p "请选择 [1]: " choice

  case "${choice:-1}" in
    1) XRAY_SNI="www.cloudflare.com"; XRAY_TARGET="www.cloudflare.com:443" ;;
    2) XRAY_SNI="www.yahoo.com"; XRAY_TARGET="www.yahoo.com:443" ;;
    3) XRAY_SNI="www.microsoft.com"; XRAY_TARGET="www.microsoft.com:443" ;;
    4)
      custom_sni="$(prompt_default '自定义 REALITY SNI' "$XRAY_SNI")"
      custom_target="$(prompt_default '自定义 REALITY 回落目标 host:port' "${custom_sni}:443")"
      XRAY_SNI="$custom_sni"
      XRAY_TARGET="$custom_target"
      ;;
    *)
      warn "无效选择，使用默认 Cloudflare。"
      XRAY_SNI="www.cloudflare.com"
      XRAY_TARGET="www.cloudflare.com:443"
      ;;
  esac
}

menu_install_xray() {
  XRAY_PORT="$(prompt_default 'Xray TCP 端口' "$XRAY_PORT")"
  select_reality_target
  install_xray_reality --port "$XRAY_PORT" --sni "$XRAY_SNI" --target "$XRAY_TARGET"
}

menu_install_hy2() {
  read -r -p "Hysteria2 UDP 端口（留空随机）: " HY2_PORT
  read -r -p "证书/SNI 域名（留空随机大厂域名）: " HY2_DOMAIN
  local -a args=()
  [[ -n "$HY2_PORT" ]] && args+=(--port "$HY2_PORT")
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
  printf '  %s3%s  查看节点信息与状态\n' "$C_CYAN" "$C_RESET"
  printf '  %s4%s  卸载 Xray\n' "$C_YELLOW" "$C_RESET"
  printf '  %s5%s  卸载 Hysteria2\n' "$C_YELLOW" "$C_RESET"
  printf '  %s0%s  退出\n' "$C_DIM" "$C_RESET"
  hr
  printf 'Xray      : %b\n' "$(service_status_label xray xray)"
  printf 'Hysteria2 : %b\n' "$(service_status_label hysteria-server hysteria)"
  hr
  warn "安装前请确认安全组已放行对应端口。"

  local choice
  read -r -p "请选择: " choice
  case "$choice" in
    1) menu_install_xray ;;
    2) menu_install_hy2 ;;
    3) show_info ;;
    4) uninstall_xray ;;
    5) uninstall_hy2 ;;
    0) exit 0 ;;
    *) fail "无效选项：${choice}" ;;
  esac
}

ensure_v2_shortcut_auto() {
  local target_path script_url source_path
  target_path="/usr/local/bin/v2"
  script_url="https://raw.githubusercontent.com/syw7895/vps/main/proxy.sh"

  if [[ "${EUID}" -ne 0 ]]; then
    warn "当前非 root，已跳过自动安装 v2 快捷命令。"
    return 0
  fi

  source_path="$(readlink -f "$0" 2>/dev/null || true)"
  if [[ -n "$source_path" && -f "$source_path" && "$source_path" != /dev/fd/* ]]; then
    chmod +x "$source_path" || { warn "自动安装 v2 失败：无法设置执行权限。"; return 0; }
    ln -sf "$source_path" "$target_path" || { warn "自动安装 v2 失败：无法创建快捷命令。"; return 0; }
  else
    curl -fL --retry 3 --connect-timeout 10 --max-time 120 -o "$target_path" "$script_url" || {
      warn "自动安装 v2 失败：下载脚本失败。"
      return 0
    }
    chmod 755 "$target_path" || { warn "自动安装 v2 失败：无法设置执行权限。"; return 0; }
  fi

  ok "已自动安装快捷命令：v2"
}

main() {
  local cmd="${1:-menu}"
  if [[ $# -gt 0 ]]; then shift; fi

  case "$cmd" in
    menu|v2) ensure_v2_shortcut_auto; main_menu ;;
    xray) install_xray_reality "$@" ;;
    hy2|hysteria2) install_hysteria2 "$@" ;;
    install-shortcut|shortcut) install_v2_shortcut ;;
    show) show_info ;;
    uninstall-xray) uninstall_xray ;;
    uninstall-hy2|uninstall-hysteria2|uninstall-v2) uninstall_hy2 ;;
    --help|-h|help) usage ;;
    *) fail "未知命令：${cmd}" ;;
  esac
}

main "$@"
