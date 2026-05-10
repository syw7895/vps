#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="vps-proxy"

XRAY_PORT="443"
XRAY_SNI="www.microsoft.com"
XRAY_TARGET="www.microsoft.com:443"
XRAY_UUID=""

HY2_PORT="8443"
HY2_DOMAIN=""
HY2_EMAIL=""
HY2_PASSWORD=""
HY2_MASQUERADE="https://www.bing.com"

CONFIG_DIR="/root/proxy-info"

log() {
  printf '[%s] %s\n' "$APP_NAME" "$*"
}

die() {
  printf '[%s] ERROR: %s\n' "$APP_NAME" "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  bash proxy.sh
  bash proxy.sh menu
  bash proxy.sh xray [options]
  bash proxy.sh hy2 [options]
  bash proxy.sh show
  bash proxy.sh uninstall-xray
  bash proxy.sh uninstall-hy2

Xray VLESS + REALITY options:
  --port PORT          TCP listen port, default: 443
  --sni DOMAIN         REALITY server name, default: www.microsoft.com
  --target HOST:PORT   REALITY fallback target, default: www.microsoft.com:443
  --uuid UUID          Client UUID, generated automatically if omitted

Hysteria2 options:
  --port PORT          UDP listen port, default: 8443
  --password VALUE     Auth password, generated automatically if omitted
  --domain DOMAIN      Enable ACME certificate mode for this domain
  --email EMAIL        ACME email, used with --domain
  --masquerade URL     Masquerade URL, default: https://www.bing.com

Examples:
  bash proxy.sh xray
  bash proxy.sh xray --port 443 --sni www.microsoft.com --target www.microsoft.com:443
  bash proxy.sh hy2
  bash proxy.sh hy2 --port 443 --domain example.com --email admin@example.com
EOF
}

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "Please run as root."
}

require_systemd() {
  command -v systemctl >/dev/null 2>&1 || die "systemctl is required."
}

detect_os() {
  [[ -r /etc/os-release ]] || die "Cannot read /etc/os-release."
  # shellcheck disable=SC1091
  . /etc/os-release

  case "${ID:-}" in
    debian|ubuntu)
      log "Detected ${PRETTY_NAME:-$ID}."
      ;;
    *)
      die "Unsupported OS: ${PRETTY_NAME:-unknown}. Use Debian or Ubuntu."
      ;;
  esac
}

install_base_deps() {
  log "Installing base dependencies."
  apt-get update
  apt-get install -y curl ca-certificates openssl sed grep gawk coreutils unzip
}

ensure_dirs() {
  install -d -m 700 "$CONFIG_DIR"
}

validate_port() {
  local port="$1"
  [[ "$port" =~ ^[0-9]+$ ]] || die "Invalid port: $port"
  (( port >= 1 && port <= 65535 )) || die "Port must be between 1 and 65535: $port"
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

random_hex() {
  openssl rand -hex "$1"
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
    die "Cannot generate UUID."
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

parse_xray_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --port)
        XRAY_PORT="${2:-}"
        shift 2
        ;;
      --sni)
        XRAY_SNI="${2:-}"
        shift 2
        ;;
      --target)
        XRAY_TARGET="${2:-}"
        shift 2
        ;;
      --uuid)
        XRAY_UUID="${2:-}"
        shift 2
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        die "Unknown Xray option: $1"
        ;;
    esac
  done
}

parse_hy2_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --port)
        HY2_PORT="${2:-}"
        shift 2
        ;;
      --password)
        HY2_PASSWORD="${2:-}"
        shift 2
        ;;
      --domain)
        HY2_DOMAIN="${2:-}"
        shift 2
        ;;
      --email)
        HY2_EMAIL="${2:-}"
        shift 2
        ;;
      --masquerade)
        HY2_MASQUERADE="${2:-}"
        shift 2
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        die "Unknown Hysteria2 option: $1"
        ;;
    esac
  done
}

install_xray_core() {
  log "Installing or upgrading Xray."
  bash -c "$(curl -LfsS https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
  command -v xray >/dev/null 2>&1 || die "Xray install failed."
}

generate_reality_keys() {
  local key_output private_key public_key
  key_output="$(xray x25519)"
  private_key="$(printf '%s\n' "$key_output" | awk -F': ' '/Private key/ {print $2}')"
  public_key="$(printf '%s\n' "$key_output" | awk -F': ' '/Public key/ {print $2}')"

  [[ -n "$private_key" && -n "$public_key" ]] || die "Cannot generate REALITY keys."
  printf '%s\n%s\n' "$private_key" "$public_key"
}

install_xray_reality() {
  parse_xray_args "$@"
  require_root
  require_systemd
  detect_os
  validate_port "$XRAY_PORT"
  install_base_deps
  ensure_dirs
  install_xray_core

  [[ -n "$XRAY_UUID" ]] || XRAY_UUID="$(random_uuid)"
  local short_id keys private_key public_key ip link info_file
  short_id="$(random_hex 8)"
  keys="$(generate_reality_keys)"
  private_key="$(printf '%s\n' "$keys" | sed -n '1p')"
  public_key="$(printf '%s\n' "$keys" | sed -n '2p')"
  ip="$(server_ip)"

  log "Writing Xray REALITY config."
  cat >/usr/local/etc/xray/config.json <<EOF
{
  "log": {
    "loglevel": "warning"
  },
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
          "target": "${XRAY_TARGET}",
          "xver": 0,
          "serverNames": [
            "${XRAY_SNI}"
          ],
          "privateKey": "${private_key}",
          "shortIds": [
            "${short_id}"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ]
}
EOF

  xray run -test -config /usr/local/etc/xray/config.json
  systemctl enable xray
  systemctl restart xray
  open_firewall_tcp "$XRAY_PORT"

  link="vless://${XRAY_UUID}@${ip}:${XRAY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${XRAY_SNI}&fp=chrome&pbk=${public_key}&sid=${short_id}&type=tcp&headerType=none#Xray-Reality-${ip}"
  info_file="${CONFIG_DIR}/xray-reality.txt"
  cat >"$info_file" <<EOF
Xray VLESS + REALITY

Address:    ${ip}
Port:       ${XRAY_PORT}
UUID:       ${XRAY_UUID}
Flow:       xtls-rprx-vision
Security:   reality
SNI:        ${XRAY_SNI}
Target:     ${XRAY_TARGET}
PublicKey:  ${public_key}
ShortId:    ${short_id}
Fingerprint: chrome

URL:
${link}
EOF

  cat "$info_file"
}

install_hysteria_core() {
  log "Installing or upgrading Hysteria2."
  HYSTERIA_USER=root bash <(curl -fsSL https://get.hy2.sh/)
  command -v hysteria >/dev/null 2>&1 || die "Hysteria install failed."
}

write_hy2_self_signed_cert() {
  local cert_dir="$1"
  local cn="$2"
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
  validate_port "$HY2_PORT"
  if [[ -n "$HY2_DOMAIN" && "$HY2_PORT" != "443" ]]; then
    die "Hysteria2 ACME mode requires UDP/TCP port 443. Use --port 443 or omit --domain for self-signed mode."
  fi
  install_base_deps
  ensure_dirs
  install_hysteria_core

  [[ -n "$HY2_PASSWORD" ]] || HY2_PASSWORD="$(random_password)"
  local ip config_file cert_dir link info_file sni insecure_query
  ip="$(server_ip)"
  config_file="/etc/hysteria/config.yaml"
  cert_dir="/etc/hysteria/certs"
  sni="${HY2_DOMAIN:-$ip}"
  insecure_query="&insecure=1"

  install -d -m 755 /etc/hysteria

  if [[ -n "$HY2_DOMAIN" ]]; then
    [[ -n "$HY2_EMAIL" ]] || HY2_EMAIL="admin@${HY2_DOMAIN}"
    insecure_query=""
    log "Writing Hysteria2 ACME config for ${HY2_DOMAIN}."
    cat >"$config_file" <<EOF
listen: :${HY2_PORT}

acme:
  domains:
    - ${HY2_DOMAIN}
  email: ${HY2_EMAIL}

auth:
  type: password
  password: ${HY2_PASSWORD}

masquerade:
  type: proxy
  proxy:
    url: ${HY2_MASQUERADE}
    rewriteHost: true
EOF
  else
    log "Writing Hysteria2 self-signed config."
    write_hy2_self_signed_cert "$cert_dir" "$ip"
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
    url: ${HY2_MASQUERADE}
    rewriteHost: true
EOF
  fi

  systemctl enable hysteria-server.service
  systemctl restart hysteria-server.service
  open_firewall_udp "$HY2_PORT"

  link="hysteria2://${HY2_PASSWORD}@${ip}:${HY2_PORT}/?sni=${sni}${insecure_query}#Hysteria2-${ip}"
  info_file="${CONFIG_DIR}/hysteria2.txt"
  cat >"$info_file" <<EOF
Hysteria2

Address:    ${ip}
Port:       ${HY2_PORT}
Password:   ${HY2_PASSWORD}
SNI:        ${sni}
TLS mode:   $(if [[ -n "$HY2_DOMAIN" ]]; then printf 'ACME'; else printf 'self-signed'; fi)
Protocol:   UDP

URL:
${link}
EOF

  cat "$info_file"
}

show_info() {
  if [[ -f "${CONFIG_DIR}/xray-reality.txt" ]]; then
    cat "${CONFIG_DIR}/xray-reality.txt"
    printf '\n'
  fi

  if [[ -f "${CONFIG_DIR}/hysteria2.txt" ]]; then
    cat "${CONFIG_DIR}/hysteria2.txt"
    printf '\n'
  fi

  if [[ ! -f "${CONFIG_DIR}/xray-reality.txt" && ! -f "${CONFIG_DIR}/hysteria2.txt" ]]; then
    log "No saved proxy info found."
  fi
}

uninstall_xray() {
  require_root
  log "Uninstalling Xray."
  bash -c "$(curl -LfsS https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove --purge || true
  rm -f "${CONFIG_DIR}/xray-reality.txt"
}

uninstall_hy2() {
  require_root
  log "Uninstalling Hysteria2."
  bash <(curl -fsSL https://get.hy2.sh/) --remove || true
  rm -f "${CONFIG_DIR}/hysteria2.txt"
}

prompt_default() {
  local label="$1"
  local default_value="$2"
  local value
  read -r -p "${label} [${default_value}]: " value
  printf '%s' "${value:-$default_value}"
}

menu_install_xray() {
  XRAY_PORT="$(prompt_default 'Xray TCP port' "$XRAY_PORT")"
  XRAY_SNI="$(prompt_default 'REALITY SNI' "$XRAY_SNI")"
  XRAY_TARGET="$(prompt_default 'REALITY target' "$XRAY_TARGET")"
  install_xray_reality --port "$XRAY_PORT" --sni "$XRAY_SNI" --target "$XRAY_TARGET"
}

menu_install_hy2() {
  HY2_PORT="$(prompt_default 'Hysteria2 UDP port' "$HY2_PORT")"
  read -r -p "Domain for ACME certificate, leave empty for self-signed: " HY2_DOMAIN
  local -a args
  args=(--port "$HY2_PORT")
  if [[ -n "$HY2_DOMAIN" ]]; then
    HY2_EMAIL="$(prompt_default 'ACME email' "admin@${HY2_DOMAIN}")"
    args+=(--domain "$HY2_DOMAIN" --email "$HY2_EMAIL")
  fi
  install_hysteria2 "${args[@]}"
}

main_menu() {
  cat <<'EOF'

VPS Proxy Menu

1) Install Xray VLESS + REALITY
2) Install Hysteria2
3) Show saved connection info
4) Uninstall Xray
5) Uninstall Hysteria2
0) Exit

EOF
  local choice
  read -r -p "Choose: " choice
  case "$choice" in
    1) menu_install_xray ;;
    2) menu_install_hy2 ;;
    3) show_info ;;
    4) uninstall_xray ;;
    5) uninstall_hy2 ;;
    0) exit 0 ;;
    *) die "Invalid choice: $choice" ;;
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
    *) die "Unknown command: $command" ;;
  esac
}

main "$@"
