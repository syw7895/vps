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

HY2_PORT=""
HY2_PASSWORD=""
HY2_MASQUERADE="https://www.bing.com"
HY2_SNI="www.bing.com"
HY2_HOP_START="20000"
HY2_HOP_END="40000"
HY2_RULE_COMMENT="hy2-port-hop"

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

Xray VLESS + REALITY 参数：
  --port PORT          TCP 监听端口，默认：443
  --sni DOMAIN         REALITY 伪装域名，默认：www.microsoft.com
  --target HOST:PORT   REALITY 回落目标，默认：www.microsoft.com:443
  --uuid UUID          客户端 UUID，不填则自动生成

Hysteria2 参数：
  --port PORT          UDP 监听端口，不填则随机生成
  --password VALUE     认证密码，不填则自动生成
  --sni DOMAIN         证书 CN / SNI，默认：www.bing.com
  --hop-start PORT     端口跳跃起始端口，默认：20000
  --hop-end PORT       端口跳跃结束端口，默认：40000
  --masquerade URL     伪装网站，默认：https://www.bing.com

示例：
  bash proxy.sh xray
  bash proxy.sh xray --port 443 --sni www.microsoft.com --target www.microsoft.com:443
  bash proxy.sh hy2
  bash proxy.sh hy2 --port 443 --sni www.bing.com --hop-start 20000 --hop-end 40000
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
  # shellcheck disable=SC1091
  . /etc/os-release

  case "${ID:-}" in
    debian|ubuntu)
      log "检测到系统：${PRETTY_NAME:-$ID}。"
      ;;
    *)
      die "不支持的系统：${PRETTY_NAME:-unknown}。请使用 Debian 或 Ubuntu。"
      ;;
  esac
}

install_base_deps() {
  log "正在安装基础依赖。"
  apt-get update
  apt-get install -y curl ca-certificates openssl sed grep gawk coreutils unzip iproute2 iptables
}

ensure_dirs() {
  install -d -m 700 "$CONFIG_DIR"
}

validate_port() {
  local port="$1"
  [[ "$port" =~ ^[0-9]+$ ]] || die "端口无效：$port"
  (( port >= 1 && port <= 65535 )) || die "端口必须在 1 到 65535 之间：$port"
}

validate_port_range() {
  local start="$1"
  local end="$2"
  local listen_port="$3"
  validate_port "$start"
  validate_port "$end"
  (( start < end )) || die "端口跳跃范围无效：起始端口必须小于结束端口。"
  if (( listen_port >= start && listen_port <= end )); then
    die "端口跳跃范围不能包含主监听端口：${listen_port}"
  fi
}

validate_sni() {
  local value="$1"
  [[ ${#value} -le 253 ]] || return 1
  [[ "$value" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]]
}

yaml_single_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/''/g")"
}

server_ip() {
  local ip=""
  ip="$(curl -4fsSL --max-time 5 https://api.ipify.org || curl -6fsSL --max-time 5 https://api64.ipify.org || true)"
  if [[ -z "$ip" ]]; then
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  fi
  [[ -n "$ip" ]] || ip="YOUR_SERVER_IP"
  printf '%s' "$ip"
}

format_host_for_uri() {
  local host="$1"
  if [[ "$host" == *:* && "$host" != \[*\] ]]; then
    printf '[%s]' "$host"
  else
    printf '%s' "$host"
  fi
}

random_hex() {
  openssl rand -hex "$1"
}

random_password() {
  openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 18
}

random_port() {
  local port
  while true; do
    port="$(shuf -i 10000-65535 -n 1 2>/dev/null || awk 'BEGIN{srand(); print int(10000+rand()*55536)}')"
    if ! ss -H -lntu 2>/dev/null | awk '{print $5}' | grep -Eq "[:.]${port}$"; then
      printf '%s' "$port"
      return 0
    fi
  done
}

get_default_nic() {
  local nic
  nic="$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i==\"dev\") print $(i+1)}' | head -n 1)"
  printf '%s' "${nic:-eth0}"
}

cleanup_hy2_iptables_rules() {
  local line
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    iptables -t nat -D PREROUTING "$line" >/dev/null 2>&1 || true
  done < <(
    iptables -t nat -L PREROUTING --line-numbers -n -v 2>/dev/null |
      awk -v comment="$HY2_RULE_COMMENT" '$0 ~ comment {print $1}' |
      sort -rn
  )
}

add_hy2_iptables_rule() {
  local nic="$1"
  local hop_start="$2"
  local hop_end="$3"
  local port="$4"

  cleanup_hy2_iptables_rules
  iptables -t nat -A PREROUTING \
    -i "$nic" \
    -p udp \
    --dport "${hop_start}:${hop_end}" \
    -m comment --comment "$HY2_RULE_COMMENT" \
    -j REDIRECT --to-ports "$port"
}

save_iptables_rules() {
  if command -v netfilter-persistent >/dev/null 2>&1; then
    netfilter-persistent save >/dev/null 2>&1 || true
    return 0
  fi
  if command -v apt-get >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent >/dev/null 2>&1 || true
    command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save >/dev/null 2>&1 || true
  fi
}

write_hy2_state() {
  local port="$1"
  local hop_start="$2"
  local hop_end="$3"
  local password="$4"
  local sni="$5"
  local nic="$6"
  local state_file="${CONFIG_DIR}/hy2-state.env"
  {
    printf 'PORT=%q\n' "$port"
    printf 'HOP_START=%q\n' "$hop_start"
    printf 'HOP_END=%q\n' "$hop_end"
    printf 'PASSWORD=%q\n' "$password"
    printf 'SNI=%q\n' "$sni"
    printf 'NIC=%q\n' "$nic"
  } > "$state_file"
  chmod 600 "$state_file"
}

load_hy2_state() {
  local state_file="${CONFIG_DIR}/hy2-state.env"
  if [[ -f "$state_file" ]]; then
    # shellcheck disable=SC1090
    source "$state_file"
  fi
}

random_uuid() {
  if command -v xray >/dev/null 2>&1; then
    xray uuid
  elif command -v uuidgen >/dev/null 2>&1; then
    uuidgen
  elif [[ -r /proc/sys/kernel/random/uuid ]]; then
    cat /proc/sys/kernel/random/uuid
  else
    die "无法生成 UUID。"
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
        die "未知的 Xray 参数：$1"
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
      --sni)
        HY2_SNI="${2:-}"
        shift 2
        ;;
      --domain)
        HY2_SNI="${2:-}"
        shift 2
        ;;
      --email)
        shift 2
        ;;
      --hop-start)
        HY2_HOP_START="${2:-}"
        shift 2
        ;;
      --hop-end)
        HY2_HOP_END="${2:-}"
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
        die "未知的 Hysteria2 参数：$1"
        ;;
    esac
  done
}

install_xray_core() {
  log "正在安装或更新 Xray。"
  bash -c "$(curl -LfsS https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
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
  require_root
  require_systemd
  detect_os
  validate_port "$XRAY_PORT"
  install_base_deps
  ensure_dirs
  install_xray_core

  [[ -n "$XRAY_UUID" ]] || XRAY_UUID="$(random_uuid)"
  local short_id keys private_key public_key ip uri_host link info_file
  short_id="$(random_hex 8)"
  keys="$(generate_reality_keys)"
  private_key="$(printf '%s\n' "$keys" | sed -n '1p')"
  public_key="$(printf '%s\n' "$keys" | sed -n '2p')"
  ip="$(server_ip)"
  uri_host="$(format_host_for_uri "$ip")"

  print_title "Xray VLESS + REALITY"
  log "正在写入 Xray REALITY 配置。"
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
        "network": "raw",
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
  printf '%s\n' "$XRAY_PORT" > "${CONFIG_DIR}/.xray_port"

  link="vless://${XRAY_UUID}@${uri_host}:${XRAY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${XRAY_SNI}&fp=chrome&pbk=${public_key}&sid=${short_id}&type=tcp&headerType=none#Xray-Reality"
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
Password:   ${public_key}
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
  local installer
  log "正在安装或更新 Hysteria2。"
  installer="$(mktemp)"
  curl -fsSL https://get.hy2.sh/ -o "$installer"
  bash "$installer"
  rm -f "$installer"
  command -v hysteria >/dev/null 2>&1 || die "Hysteria2 安装失败。"
}

write_hy2_self_signed_cert() {
  local cert_dir="$1"
  local cn="$2"
  install -d -m 700 "$cert_dir"
  openssl req -x509 -nodes -newkey ec \
    -pkeyopt ec_paramgen_curve:P-256 \
    -keyout "${cert_dir}/server.key" \
    -out "${cert_dir}/server.crt" \
    -days 3650 \
    -subj "/CN=${cn}" >/dev/null 2>&1
  chmod 600 "${cert_dir}/server.key"
  chmod 644 "${cert_dir}/server.crt"
}

install_hysteria2() {
  parse_hy2_args "$@"
  require_root
  require_systemd
  detect_os

  [[ -n "$HY2_PORT" ]] || HY2_PORT="$(random_port)"
  [[ -n "$HY2_SNI" ]] || HY2_SNI="www.bing.com"
  validate_port "$HY2_PORT"
  validate_port_range "$HY2_HOP_START" "$HY2_HOP_END" "$HY2_PORT"
  validate_sni "$HY2_SNI" || die "SNI 域名格式无效：${HY2_SNI}"

  install_base_deps
  ensure_dirs
  install_hysteria_core

  [[ -n "$HY2_PASSWORD" ]] || HY2_PASSWORD="$(random_password)"
  local ip uri_host config_file cert_dir link info_file password_yaml nic
  ip="$(server_ip)"
  uri_host="$(format_host_for_uri "$ip")"
  config_file="/etc/hysteria/config.yaml"
  cert_dir="/etc/hysteria/certs"
  password_yaml="$(yaml_single_quote "$HY2_PASSWORD")"

  install -d -m 755 /etc/hysteria
  print_title "Hysteria2"
  log "正在写入 Hysteria2 配置。"
  write_hy2_self_signed_cert "$cert_dir" "$HY2_SNI"
  cat >"$config_file" <<EOF
listen: :${HY2_PORT}

tls:
  cert: ${cert_dir}/server.crt
  key: ${cert_dir}/server.key

auth:
  type: password
  password: ${password_yaml}

masquerade:
  type: proxy
  proxy:
    url: ${HY2_MASQUERADE}
    rewriteHost: true

quic:
  initStreamReceiveWindow: 26843545
  maxStreamReceiveWindow: 26843545
  initConnReceiveWindow: 67108864
  maxConnReceiveWindow: 67108864
EOF
  chown hysteria:hysteria "$config_file" "${cert_dir}/server.crt" "${cert_dir}/server.key" 2>/dev/null || true
  chmod 640 "$config_file"

  configure_hy2_firewall "$HY2_PORT" "$HY2_HOP_START" "$HY2_HOP_END"
  nic="$(get_default_nic)"
  add_hy2_iptables_rule "$nic" "$HY2_HOP_START" "$HY2_HOP_END" "$HY2_PORT"
  save_iptables_rules
  write_hy2_state "$HY2_PORT" "$HY2_HOP_START" "$HY2_HOP_END" "$HY2_PASSWORD" "$HY2_SNI" "$nic"

  systemctl enable hysteria-server.service
  systemctl restart hysteria-server.service
  sleep 2
  if ! systemctl is-active --quiet hysteria-server.service; then
    journalctl --no-pager -n 30 -u hysteria-server.service >&2 || true
    die "Hysteria2 启动失败，请查看上方日志。"
  fi
  printf '%s\n' "$HY2_PORT" > "${CONFIG_DIR}/.hy2_port"
  printf '%s-%s\n' "$HY2_HOP_START" "$HY2_HOP_END" > "${CONFIG_DIR}/.hy2_hop_range"

  link="hysteria2://${HY2_PASSWORD}@${uri_host}:${HY2_PORT}/?mport=${HY2_HOP_START}-${HY2_HOP_END}&insecure=1&sni=${HY2_SNI}#Hysteria2"
  info_file="${CONFIG_DIR}/hysteria2.txt"
  cat >"$info_file" <<EOF
Hysteria2

地址:       ${ip}
端口:       ${HY2_PORT}
跳跃范围:   ${HY2_HOP_START}-${HY2_HOP_END}
密码:       ${HY2_PASSWORD}
SNI:        ${HY2_SNI}
TLS 模式:   自签证书
协议:       UDP
提醒:       请在 VPS 安全组/外部防火墙放行 ${HY2_PORT}/UDP 和 ${HY2_HOP_START}-${HY2_HOP_END}/UDP

分享链接:
${link}
EOF

  success "Hysteria2 已安装并启动。"
  printf '\n'
  cat "$info_file"
}

configure_hy2_firewall() {
  local port="$1"
  local hop_start="$2"
  local hop_end="$3"
  if command -v ufw >/dev/null 2>&1; then
    ufw allow "${port}/udp" >/dev/null 2>&1 || true
    ufw allow "${hop_start}:${hop_end}/udp" >/dev/null 2>&1 || true
    ufw reload >/dev/null 2>&1 || true
  elif command -v firewall-cmd >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="${port}/udp" >/dev/null 2>&1 || true
    firewall-cmd --permanent --add-port="${hop_start}-${hop_end}/udp" >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
  fi
}

show_info() {
  print_title "已保存的节点信息"

  if [[ -f "${CONFIG_DIR}/xray-reality.txt" ]]; then
    cat "${CONFIG_DIR}/xray-reality.txt"
    printf '\n'
  fi

  if [[ -f "${CONFIG_DIR}/hysteria2.txt" ]]; then
    cat "${CONFIG_DIR}/hysteria2.txt"
    printf '\n'
  fi

  if [[ ! -f "${CONFIG_DIR}/xray-reality.txt" && ! -f "${CONFIG_DIR}/hysteria2.txt" ]]; then
    log "没有找到已保存的节点信息。"
  fi
}

uninstall_xray() {
  require_root
  if [[ -f "${CONFIG_DIR}/.xray_port" ]] && command -v ufw >/dev/null 2>&1; then
    ufw delete allow "$(<"${CONFIG_DIR}/.xray_port")/tcp" >/dev/null 2>&1 || true
    rm -f "${CONFIG_DIR}/.xray_port"
  fi
  log "正在卸载 Xray。"
  bash -c "$(curl -LfsS https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove --purge || true
  rm -f "${CONFIG_DIR}/xray-reality.txt"
  success "Xray 已卸载。"
}

uninstall_hy2() {
  require_root
  load_hy2_state

  cleanup_hy2_iptables_rules
  save_iptables_rules

  if command -v ufw >/dev/null 2>&1; then
    [[ -n "${PORT:-}" ]] && ufw delete allow "${PORT}/udp" >/dev/null 2>&1 || true
    if [[ -n "${HOP_START:-}" && -n "${HOP_END:-}" ]]; then
      ufw delete allow "${HOP_START}:${HOP_END}/udp" >/dev/null 2>&1 || true
    fi
  fi
  log "正在卸载 Hysteria2。"
  bash <(curl -fsSL https://get.hy2.sh/) --remove || true
  rm -f "${CONFIG_DIR}/hysteria2.txt" "${CONFIG_DIR}/.hy2_port" "${CONFIG_DIR}/.hy2_hop_range" "${CONFIG_DIR}/hy2-state.env"
  success "Hysteria2 已卸载。"
}

prompt_default() {
  local label="$1"
  local default_value="$2"
  local value
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
  [[ -n "$HY2_PORT" ]] || HY2_PORT="$(random_port)"
  HY2_PORT="$(prompt_default 'Hysteria2 UDP 端口' "$HY2_PORT")"
  HY2_HOP_START="$(prompt_default '端口跳跃起始端口' "$HY2_HOP_START")"
  HY2_HOP_END="$(prompt_default '端口跳跃结束端口' "$HY2_HOP_END")"
  HY2_SNI="$(prompt_default 'SNI/证书域名' "$HY2_SNI")"
  local -a args
  args=(--port "$HY2_PORT" --hop-start "$HY2_HOP_START" --hop-end "$HY2_HOP_END" --sni "$HY2_SNI")
  install_hysteria2 "${args[@]}"
}

service_status_label() {
  local service="$1"
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

show_hy2_status() {
  local active_status enabled_status listen_info
  print_title "Hysteria2 运行状态"
  active_status="$(systemctl is-active hysteria-server 2>/dev/null || true)"
  enabled_status="$(systemctl is-enabled hysteria-server 2>/dev/null || true)"
  listen_info="$(ss -lunp 2>/dev/null | grep 'hysteria' || true)"

  printf '服务状态:   %s\n' "${active_status:-unknown}"
  printf '开机自启:   %s\n' "${enabled_status:-unknown}"
  if [[ -f /etc/hysteria/config.yaml ]]; then
    printf '配置文件:   %s\n' "/etc/hysteria/config.yaml"
  else
    printf '配置文件:   未找到\n'
  fi
  if [[ -f "${CONFIG_DIR}/.hy2_hop_range" ]]; then
    printf '跳跃范围:   %s\n' "$(<"${CONFIG_DIR}/.hy2_hop_range")"
  fi
  hr
  printf '监听信息\n'
  if [[ -n "$listen_info" ]]; then
    printf '%s\n' "$listen_info"
  else
    printf '未检测到 hysteria 监听端口。\n'
  fi
  hr
  printf '最近日志（20 行）\n'
  journalctl --no-pager -n 20 -u hysteria-server 2>/dev/null || printf '暂无日志。\n'
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
    printf '  %s2%s  查看节点信息\n' "$C_CYAN" "$C_RESET"
    printf '  %s3%s  查看运行状态\n' "$C_CYAN" "$C_RESET"
    printf '  %s4%s  卸载 Hysteria2\n' "$C_YELLOW" "$C_RESET"
    printf '  %s0%s  返回上级菜单\n' "$C_DIM" "$C_RESET"
    hr
    printf '当前状态: %b\n' "$(service_status_label hysteria-server hysteria)"
    printf '\n'

    read -r -p "请选择: " choice
    case "$choice" in
      1) menu_install_hy2; pause_menu ;;
      2) [[ -f "${CONFIG_DIR}/hysteria2.txt" ]] && cat "${CONFIG_DIR}/hysteria2.txt" || warn "暂无节点信息。"; pause_menu ;;
      3) show_hy2_status; pause_menu ;;
      4) uninstall_hy2; pause_menu ;;
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
