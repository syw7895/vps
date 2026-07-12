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

# 远程安装器固定到经过审查的提交，默认强制 SHA256 校验。
# 更新安装器时，必须同时更新 URL 和对应哈希。
XRAY_INSTALLER_URL="${XRAY_INSTALLER_URL:-https://raw.githubusercontent.com/XTLS/Xray-install/e741a4f56d368afbb9e5be3361b40c4552d3710d/install-release.sh}"
HY2_INSTALLER_URL="${HY2_INSTALLER_URL:-https://raw.githubusercontent.com/apernet/hysteria/d1cd1503d35d3cd3fbe176be634b805d560ec7e7/scripts/install_server.sh}"
XRAY_INSTALLER_SHA256="${XRAY_INSTALLER_SHA256:-7f70c95f6b418da8b4f4883343d602964915e28748993870fd554383afdbe555}"
HY2_INSTALLER_SHA256="${HY2_INSTALLER_SHA256:-e6b9023dcc0142f155546548b9d7a75ce288704d6dead0c2010d61663b90e217}"

# 在线执行时，v2 副本必须提供来自独立可信渠道的 SHA256。
V2_SCRIPT_URL="${V2_SCRIPT_URL:-https://raw.githubusercontent.com/syw7895/vps/main/proxy.sh}"
V2_SCRIPT_SHA256="${V2_SCRIPT_SHA256:-}"
V2_INSTALL_DIR="/usr/local/lib/vps-proxy"
V2_SCRIPT_PATH="${V2_INSTALL_DIR}/proxy.sh"
V2_COMMAND_PATH="/usr/local/bin/v2"
HY2_SERVICE_USER="hysteria"

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
  bash proxy.sh uninstall-v2       # 仅删除 v2 快捷命令

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

curl_download() {
  local url="$1" out="$2"
  curl -fL --retry 3 --connect-timeout 10 --max-time 120 -o "$out" "$url" &&
    [[ -s "$out" ]]
}

is_valid_sha256() {
  [[ "$1" =~ ^[A-Fa-f0-9]{64}$ ]]
}

require_sha256() {
  local expected="$1" label="$2"
  is_valid_sha256 "$expected" ||
    fail "${label} 缺少或格式错误的 SHA256；拒绝执行未校验的远程脚本。"
}

sha256_matches() {
  local file="$1" expected="$2" actual
  is_valid_sha256 "$expected" || return 1

  actual="$(sha256sum "$file" | awk '{print $1}')"
  [[ "${actual,,}" == "${expected,,}" ]]
}

download_remote_script() {
  local url="$1" out="$2"
  curl_download "$url" "$out" || fail "下载安装脚本失败：${url}"
}

verify_script_sha256() {
  require_sha256 "$2" "安装脚本"
  sha256_matches "$1" "$2" || fail "安装脚本哈希校验失败。"
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

is_ipv4_address() {
  local ip="$1" octet
  local -a octets
  local IFS=.

  [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  read -r -a octets <<<"$ip"
  for octet in "${octets[@]}"; do
    (( 10#$octet <= 255 )) || return 1
  done
}

validate_target() {
  local target="$1" host port
  [[ "$target" =~ ^[^:[:space:]]+:[0-9]+$ ]] ||
    fail "target 格式错误，应为 host:port，例如 www.cloudflare.com:443"

  host="${target%:*}"
  port="${target##*:}"
  if ! [[ "$host" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,}$ ]] &&
    ! is_ipv4_address "$host"; then
    fail "target 主机名或 IPv4 地址无效：${host}"
  fi
  validate_port "$port"
}

validate_domain() {
  local domain="$1"
  [[ "$domain" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,}$ ]] ||
    fail "域名格式错误：${domain}"
}

validate_uuid() {
  local uuid="$1"
  [[ "$uuid" =~ ^[A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[1-5][A-Fa-f0-9]{3}-[89ABab][A-Fa-f0-9]{3}-[A-Fa-f0-9]{12}$ ]] ||
    fail "UUID 格式错误：${uuid}"
}

validate_hy2_password() {
  local password="$1"
  [[ "$password" =~ ^[-A-Za-z0-9._~]{1,128}$ ]] ||
    fail "Hysteria2 密码只能包含字母、数字和 - . _ ~，长度为 1-128。"
}

validate_hy2_masquerade() {
  local url="$1"
  local url_pattern='^https?://[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{1,5})?(/[A-Za-z0-9._~:/?@!$&()*+,;=%-]*)?$'
  [[ "$url" =~ $url_pattern ]] ||
    fail "伪装 URL 格式错误：仅支持不含空白或引号的 http(s) URL。"
}

is_port_in_use() {
  local port="$1"
  ss -tuln 2>/dev/null | grep -qE ":${port}[[:space:]]"
}

service_owns_port() {
  local service="$1" port="$2"

  # Only recognize the standard configuration files written by this script.
  systemctl is-active --quiet "$service" 2>/dev/null || return 1
  case "$service" in
    xray)
      [[ -r "$XRAY_CONFIG" ]] &&
        grep -qE "\"port\"[[:space:]]*:[[:space:]]*${port}([[:space:]]*,|[[:space:]]*$)" "$XRAY_CONFIG"
      ;;
    hysteria-server)
      [[ -r "$HY2_CONFIG" ]] &&
        grep -qE "^[[:space:]]*listen:[[:space:]]*:${port}[[:space:]]*(#.*)?$" "$HY2_CONFIG"
      ;;
    *) return 1 ;;
  esac
}

ensure_port_available() {
  local port="$1" service="$2" label="$3"

  is_port_in_use "$port" || return 0
  if service_owns_port "$service" "$port"; then
    warn "${label} 正在使用端口 ${port}，允许原端口更新。"
    return 0
  fi
  fail "端口已被其他程序占用：${port}"
}

random_free_port() {
  local port attempt
  for ((attempt = 1; attempt <= 128; attempt++)); do
    port="$(shuf -i 10000-65535 -n 1)"
    if ! is_port_in_use "$port"; then
      printf '%s' "$port"
      return 0
    fi
  done
  fail "连续 128 次未找到可用随机端口，请手动通过 --port 指定端口。"
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

require_arg_value() {
  local option="$1" value="${2:-}"
  [[ -n "$value" && "$value" != --* ]] || fail "${option} 后面需要填写参数值。"
}

open_firewall_port() {
  local port="$1" protocol="$2"
  if command -v ufw >/dev/null 2>&1; then
    ufw allow "${port}/${protocol}" >/dev/null || true
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

print_service_statuses() {
  printf '%-10s: %b\n' "Xray" "$(service_status_label xray xray)"
  printf '%-10s: %b\n' "Hysteria2" "$(service_status_label hysteria-server hysteria)"
}

show_journal() {
  local service="$1" label="$2" lines="${3:-25}"
  command -v journalctl >/dev/null 2>&1 || return 0
  printf '\n%s[%s 最近日志]%s\n' "$C_CYAN" "$label" "$C_RESET"
  journalctl -u "$service" -n "$lines" --no-pager -o short-iso 2>/dev/null || true
}

restart_and_verify_service() {
  local service="$1" label="$2" attempt

  if ! systemctl restart "$service"; then
    show_journal "$service" "$label"
    fail "${label} 重启失败。"
  fi

  for ((attempt = 1; attempt <= 5; attempt++)); do
    if systemctl is-active --quiet "$service"; then
      return 0
    fi
    sleep 1
  done

  show_journal "$service" "$label"
  fail "${label} 重启后未保持运行状态。"
}

# ===== 参数解析 =====
parse_xray_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --port) require_arg_value "$1" "${2:-}"; XRAY_PORT="$2"; shift 2 ;;
      --sni) require_arg_value "$1" "${2:-}"; XRAY_SNI="$2"; shift 2 ;;
      --target) require_arg_value "$1" "${2:-}"; XRAY_TARGET="$2"; shift 2 ;;
      --uuid) require_arg_value "$1" "${2:-}"; XRAY_UUID="$2"; shift 2 ;;
      --help|-h) usage; exit 0 ;;
      *) fail "未知 Xray 参数：$1" ;;
    esac
  done
}

parse_hy2_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --port) require_arg_value "$1" "${2:-}"; HY2_PORT="$2"; HY2_PORT_SET_BY_USER="1"; shift 2 ;;
      --password) require_arg_value "$1" "${2:-}"; HY2_PASSWORD="$2"; shift 2 ;;
      --domain) require_arg_value "$1" "${2:-}"; HY2_DOMAIN="$2"; shift 2 ;;
      --masquerade) require_arg_value "$1" "${2:-}"; HY2_MASQUERADE="$2"; shift 2 ;;
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
  [[ -z "$XRAY_UUID" ]] || validate_uuid "$XRAY_UUID"
  ensure_port_available "$XRAY_PORT" xray "Xray"

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
  restart_and_verify_service xray "Xray"
  open_firewall_port "$XRAY_PORT" tcp

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
  warn "请确认 VPS 安全组和防火墙已放行 ${XRAY_PORT}/tcp。"
  printf '\n'
  cat "$XRAY_INFO_FILE"
}

# ===== Hysteria2 安装 =====
install_hysteria_core() {
  log "安装或更新 Hysteria2..."
  # 官方安装器会创建该专用系统用户，并将服务改为以其身份运行。
  HYSTERIA_USER="$HY2_SERVICE_USER" run_remote_script "$HY2_INSTALLER_URL" "$HY2_INSTALLER_SHA256"
  command -v hysteria >/dev/null 2>&1 || fail "Hysteria2 安装失败。"
  getent passwd "$HY2_SERVICE_USER" >/dev/null ||
    fail "Hysteria2 服务用户 ${HY2_SERVICE_USER} 创建失败。"
}

write_hy2_self_signed_cert() {
  local cert_dir="$1" cn="$2"
  install -d -m 700 "$cert_dir"
  openssl req -x509 -newkey rsa:2048 -sha256 \
    -keyout "${cert_dir}/server.key" \
    -out "${cert_dir}/server.crt" \
    -days 3650 \
    -nodes \
    -subj "/CN=${cn}" \
    -addext "subjectAltName=DNS:${cn}" >/dev/null 2>&1
  chmod 600 "${cert_dir}/server.key"
  chmod 644 "${cert_dir}/server.crt"
}

configure_hy2_cert_permissions() {
  local cert_dir="$1"
  getent passwd "$HY2_SERVICE_USER" >/dev/null ||
    fail "Hysteria2 服务用户不存在：${HY2_SERVICE_USER}"

  install -d -o root -g "$HY2_SERVICE_USER" -m 750 "$cert_dir"
  chown root:"$HY2_SERVICE_USER" "${cert_dir}/server.key" "${cert_dir}/server.crt"
  chmod 640 "${cert_dir}/server.key"
  chmod 644 "${cert_dir}/server.crt"
}

check_hy2_config() {
  local test_port test_config test_output rc=0
  command -v runuser >/dev/null 2>&1 ||
    fail "缺少 runuser，无法以 Hysteria2 服务用户验证配置。"

  test_port="$(random_free_port)"
  test_config="$(mktemp /tmp/${APP_NAME}.hy2-config.XXXXXX.yaml)"
  test_output="$(mktemp /tmp/${APP_NAME}.hy2-check.XXXXXX.log)"
  sed -E "s|^listen:.*$|listen: 127.0.0.1:${test_port}|" "$HY2_CONFIG" >"$test_config"
  chown root:"$HY2_SERVICE_USER" "$test_config"
  chmod 640 "$test_config"

  runuser -u "$HY2_SERVICE_USER" -- \
    timeout --signal=TERM 3s hysteria --disable-update-check --log-level error server -c "$test_config" \
    >"$test_output" 2>&1 || rc=$?

  if (( rc != 124 )); then
    cat "$test_output" >&2 || true
    rm -f "$test_config" "$test_output"
    fail "Hysteria2 配置预检失败（退出码：${rc}）。"
  fi

  rm -f "$test_config" "$test_output"
}

hy2_certificate_sha256() {
  local cert_file="$1" fingerprint
  fingerprint="$(openssl x509 -in "$cert_file" -noout -fingerprint -sha256 |
    awk -F= 'NF > 1 {print $2; exit}' |
    tr -d ':' |
    tr '[:upper:]' '[:lower:]')"
  [[ "$fingerprint" =~ ^[0-9a-f]{64}$ ]] || fail "无法读取 Hysteria2 证书 SHA256 指纹。"
  printf '%s' "$fingerprint"
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
    ensure_port_available "$HY2_PORT" hysteria-server "Hysteria2"
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

  validate_domain "$HY2_DOMAIN"
  validate_hy2_masquerade "$HY2_MASQUERADE"
  [[ -n "$HY2_PASSWORD" ]] || HY2_PASSWORD="$(random_password)"
  validate_hy2_password "$HY2_PASSWORD"
  install_hysteria_core

  local ip sni link cert_sha256
  ip="$(server_ip)"
  sni="${HY2_DOMAIN}"

  install -d -o root -g "$HY2_SERVICE_USER" -m 750 /etc/hysteria
  title "Hysteria2"
  log "写入 Hysteria2 自签证书配置..."
  write_hy2_self_signed_cert "$HY2_CERT_DIR" "$HY2_DOMAIN"
  configure_hy2_cert_permissions "$HY2_CERT_DIR"
  cert_sha256="$(hy2_certificate_sha256 "${HY2_CERT_DIR}/server.crt")"

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

  chown root:"$HY2_SERVICE_USER" "$HY2_CONFIG"
  chmod 640 "$HY2_CONFIG"
  check_hy2_config
  systemctl enable hysteria-server.service >/dev/null 2>&1
  restart_and_verify_service hysteria-server "Hysteria2"
  open_firewall_port "$HY2_PORT" udp

  link="hysteria2://${HY2_PASSWORD}@${ip}:${HY2_PORT}/?sni=${sni}&insecure=1&pinSHA256=${cert_sha256}#Hysteria2-${ip}"
  cat >"$HY2_INFO_FILE" <<EOF
Hysteria2

地址:       ${ip}
端口:       ${HY2_PORT}
密码:       ${HY2_PASSWORD}
SNI:        ${sni}
TLS 模式:   自签证书 + SHA256 指纹校验
证书指纹:   ${cert_sha256}
协议:       UDP

分享链接:
${link}
EOF

  ok "Hysteria2 已安装并启动。"
  warn "请确认 VPS 安全组和防火墙已放行 ${HY2_PORT}/udp。"
  printf '\n'
  cat "$HY2_INFO_FILE"
}

# ===== 信息展示与卸载 =====
show_info() {
  title "已保存的节点信息"
  local found="0"

  local info_file
  for info_file in "$XRAY_INFO_FILE" "$HY2_INFO_FILE"; do
    if [[ -f "$info_file" ]]; then
      found="1"
      cat "$info_file"
      printf '\n'
    fi
  done
  [[ "$found" == "1" ]] || log "暂无已保存节点信息。"

  title "服务状态"
  print_service_statuses

  show_journal xray "Xray"
  show_journal hysteria-server "Hysteria2"
}

cleanup_info_dir() {
  rmdir -- "$CONFIG_DIR" 2>/dev/null || true
}

remove_hy2_managed_files() {
  rm -f "$HY2_INFO_FILE"
  rm -rf -- "$HY2_CERT_DIR"

  if [[ -f "$HY2_CONFIG" ]] &&
    grep -qF "cert: ${HY2_CERT_DIR}/server.crt" "$HY2_CONFIG" &&
    grep -qF "key: ${HY2_CERT_DIR}/server.key" "$HY2_CONFIG"; then
    rm -f "$HY2_CONFIG"
  fi

  rmdir -- /etc/hysteria 2>/dev/null || true
  cleanup_info_dir
}

uninstall_xray() {
  require_root
  log "卸载 Xray..."
  if run_remote_script "$XRAY_INSTALLER_URL" "$XRAY_INSTALLER_SHA256" remove --purge; then
    rm -f "$XRAY_INFO_FILE"
    cleanup_info_dir
    ok "Xray 已卸载。"
  else
    fail "Xray 卸载失败，请检查日志后重试。"
  fi
}

uninstall_hy2() {
  require_root
  log "卸载 Hysteria2..."
  if run_remote_script "$HY2_INSTALLER_URL" "$HY2_INSTALLER_SHA256" --remove; then
    remove_hy2_managed_files
    ok "Hysteria2 已卸载。"
  else
    fail "Hysteria2 卸载失败，请检查日志后重试。"
  fi
}

uninstall_v2_shortcut() {
  require_root

  if [[ -e "$V2_COMMAND_PATH" || -L "$V2_COMMAND_PATH" || -e "$V2_SCRIPT_PATH" ]]; then
    rm -f "$V2_COMMAND_PATH" "$V2_SCRIPT_PATH"
    rmdir "$V2_INSTALL_DIR" 2>/dev/null || true
    ok "已删除 v2 快捷命令。"
  else
    warn "v2 快捷命令不存在，无需删除。"
  fi
}

install_v2_local_copy() {
  local source_path="$1" resolved_source resolved_target
  install -d -m 755 "$V2_INSTALL_DIR"
  resolved_source="$(readlink -f "$source_path")"
  resolved_target="$(readlink -f "$V2_SCRIPT_PATH" 2>/dev/null || true)"

  if [[ "$resolved_source" != "$resolved_target" ]]; then
    install -m 755 "$source_path" "$V2_SCRIPT_PATH"
  else
    chmod 755 "$V2_SCRIPT_PATH"
  fi
  ln -sfn "$V2_SCRIPT_PATH" "$V2_COMMAND_PATH"
}

download_v2_local_copy() {
  local temp_file rc=0
  is_valid_sha256 "$V2_SCRIPT_SHA256" || {
    warn "在线安装 v2 需要通过 V2_SCRIPT_SHA256 提供可信的 64 位 SHA256。"
    return 1
  }

  temp_file="$(mktemp /tmp/${APP_NAME}.v2.XXXXXX.sh)"

  if ! curl_download "$V2_SCRIPT_URL" "$temp_file" ||
    ! sha256_matches "$temp_file" "$V2_SCRIPT_SHA256"; then
    rm -f "$temp_file"
    return 1
  fi

  install_v2_local_copy "$temp_file" || rc=$?
  rm -f "$temp_file"
  return "$rc"
}

install_v2_shortcut_files() {
  local source_path
  source_path="$(readlink -f "$0" 2>/dev/null || true)"

  if [[ -n "$source_path" && -f "$source_path" && "$source_path" != /dev/fd/* ]]; then
    install_v2_local_copy "$source_path"
  else
    log "检测到在线执行模式，下载脚本到固定本地路径..."
    download_v2_local_copy
  fi
}

install_v2_shortcut() {
  require_root
  install_v2_shortcut_files || fail "安装 v2 快捷命令失败。"

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
  printf '  3  www.microsoft.com（部分地区可能不稳定）\n'
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
  printf '\n%sVPS 代理控制面板%s\n' "$C_BOLD" "$C_RESET"
  printf '%sXray Reality · Hysteria2 · 输入 v2 随时进入此菜单%s\n' "$C_DIM" "$C_RESET"
  hr
  printf '  %s1%s  安装 Xray VLESS + REALITY\n' "$C_GREEN" "$C_RESET"
  printf '  %s2%s  安装 Hysteria2\n' "$C_GREEN" "$C_RESET"
  printf '  %s3%s  查看节点信息与服务状态\n' "$C_CYAN" "$C_RESET"
  printf '  %s4%s  卸载 Xray\n' "$C_YELLOW" "$C_RESET"
  printf '  %s5%s  卸载 Hysteria2\n' "$C_YELLOW" "$C_RESET"
  printf '  %s0%s  退出\n' "$C_DIM" "$C_RESET"
  hr
  print_service_statuses
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
  if [[ "${EUID}" -ne 0 ]]; then
    warn "当前非 root，已跳过自动安装 v2 快捷命令。"
    return 0
  fi

  if ! install_v2_shortcut_files; then
    warn "自动安装 v2 失败，现有代理服务不受影响。"
    return 0
  fi
  ok "已自动安装快捷命令：v2"
}

main() {
  local cmd="${1:-menu}"
  if [[ $# -gt 0 ]]; then shift; fi

  case "$cmd" in
    menu|v2) ensure_v2_shortcut_auto; main_menu ;;
    xray) install_xray_reality "$@"; ensure_v2_shortcut_auto ;;
    hy2|hysteria2) install_hysteria2 "$@"; ensure_v2_shortcut_auto ;;
    install-shortcut|shortcut) install_v2_shortcut ;;
    show) show_info ;;
    uninstall-xray) uninstall_xray ;;
    uninstall-hy2|uninstall-hysteria2) uninstall_hy2 ;;
    uninstall-v2|uninstall-shortcut|uninstall-v2-shortcut) uninstall_v2_shortcut ;;
    --help|-h|help) usage ;;
    *) fail "未知命令：${cmd}" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
