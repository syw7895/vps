#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="vps-proxy-v2"
DATA_DIR="/root/proxy-info"

XRAY_CONF="/usr/local/etc/xray/config.json"
XRAY_INFO="${DATA_DIR}/xray-reality.txt"
XRAY_PORT_FILE="${DATA_DIR}/.xray_port"

HY2_CONF="/etc/hysteria/config.yaml"
HY2_INFO="${DATA_DIR}/hysteria2.txt"
HY2_PORT_FILE="${DATA_DIR}/.hy2_port"
HY2_HOP_FILE="${DATA_DIR}/.hy2_hop"
HY2_STATE_FILE="${DATA_DIR}/hy2-state.env"
HY2_RULE_COMMENT="hy2-port-hop"

XRAY_PORT_DEFAULT="443"
XRAY_SNI_DEFAULT="www.microsoft.com"
XRAY_TARGET_DEFAULT="www.microsoft.com:443"

HY2_HOP_START_DEFAULT="20000"
HY2_HOP_END_DEFAULT="40000"
HY2_MASQ_DEFAULT="https://www.bing.com"

SHORTCUT_TARGET="/usr/local/bin/vps-proxy"
SHORTCUT_V2="/usr/local/bin/v2"

VENDOR_DOMAINS=(
  "www.microsoft.com"
  "www.apple.com"
  "www.cloudflare.com"
  "www.amazon.com"
  "www.google.com"
  "www.youtube.com"
  "www.github.com"
  "www.bing.com"
)

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'
  C_CYAN=$'\033[36m'
  C_GRAY=$'\033[90m'
else
  C_RESET=""
  C_BOLD=""
  C_RED=""
  C_GREEN=""
  C_YELLOW=""
  C_BLUE=""
  C_CYAN=""
  C_GRAY=""
fi

I_INFO="ℹ"
I_OK="✔"
I_WARN="⚠"
I_ERR="✖"
I_MENU="◆"
I_RUN="▶"
I_DOT="•"

hr() {
  printf '%s\n' "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

log() { printf '%s[%s] %s %s%s\n' "$C_CYAN" "$APP_NAME" "$I_INFO" "$*" "$C_RESET"; }
warn() { printf '%s[%s] %s %s%s\n' "$C_YELLOW" "$APP_NAME" "$I_WARN" "$*" "$C_RESET" >&2; }
die() { printf '%s[%s] %s %s%s\n' "$C_RED" "$APP_NAME" "$I_ERR" "$*" "$C_RESET" >&2; exit 1; }

on_err() {
  local line="$1"
  warn "脚本在第 ${line} 行失败。"
}
trap 'on_err "$LINENO"' ERR

has_cmd() { command -v "$1" >/dev/null 2>&1; }

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "请使用 root 运行脚本。"
}

require_systemd() {
  has_cmd systemctl || die "当前系统不支持 systemctl。"
}

detect_os() {
  [[ -r /etc/os-release ]] || die "无法读取 /etc/os-release。"
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}" in
    debian|ubuntu) log "检测到系统：${PRETTY_NAME:-$ID}" ;;
    *) die "仅支持 Debian / Ubuntu，当前是：${PRETTY_NAME:-unknown}" ;;
  esac
}

ensure_data_dir() {
  install -d -m 700 "${DATA_DIR}"
}

run_progress() {
  local title="$1"
  if [[ -t 1 ]]; then
    local p done left bar
    for p in 10 25 45 65 85 100; do
      done=$((p / 5))
      left=$((20 - done))
      bar="$(printf '%0.s█' $(seq 1 "$done"))$(printf '%0.s░' $(seq 1 "$left"))"
      printf '\r%s%s %s [%s] %3d%%%s' "$C_BLUE" "$I_RUN" "$title" "$bar" "$p" "$C_RESET"
      sleep 0.06
    done
    printf '\n'
  fi
}

run_spin() {
  local title="$1"
  shift
  if ! [[ -t 1 ]]; then "$@"; return; fi
  local spin=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  "$@" >/dev/null 2>&1 &
  local pid=$!
  local i=0
  while kill -0 "$pid" 2>/dev/null; do
    printf '\r%s%s %s %s%s' "$C_CYAN" "${spin[$i]}" "$title" "..." "$C_RESET"
    i=$(( (i + 1) % ${#spin[@]} ))
    sleep 0.08
  done
  wait "$pid"
  local rc=$?
  if [[ $rc -eq 0 ]]; then
    printf '\r%s%s %s 完成%s\n' "$C_GREEN" "$I_OK" "$title" "$C_RESET"
  else
    printf '\r%s%s %s 失败%s\n' "$C_RED" "$I_ERR" "$title" "$C_RESET"
  fi
  return "$rc"
}

ui_title() {
  local text="$1"
  printf '\n%s' "$C_BOLD$C_BLUE"
  hr
  printf '%s %s\n' "$I_MENU" "$text"
  hr
  printf '%s' "$C_RESET"
}

ui_note() {
  local text="$1"
  printf '%s%s %s%s\n' "$C_GRAY" "$I_DOT" "$text" "$C_RESET"
}

ui_ok() {
  local text="$1"
  printf '%s%s %s%s\n' "$C_GREEN" "$I_OK" "$text" "$C_RESET"
}

ask_input() {
  local prompt="$1"
  local default_value="${2:-}"
  local v=""
  read -r -p "${prompt} [${default_value}]: " v
  v="${v:-$default_value}"
  printf '%s' "$v"
}

ask_password() {
  local prompt="$1"
  local v=""
  read -r -s -p "${prompt}: " v
  printf '\n'
  printf '%s' "$v"
}

ask_confirm() {
  local text="$1"
  local c=""
  read -r -p "${text} [y/N]: " c
  [[ "$c" == "y" || "$c" == "Y" ]]
}

choose_one() {
  local header="$1"
  shift
  local i=1
  local choices=("$@")
  printf '%s%s%s\n' "$C_CYAN" "$header" "$C_RESET"
  hr
  for item in "${choices[@]}"; do
    printf '  %s%2d%s) %s %s\n' "$C_BLUE" "$i" "$C_RESET" "$I_DOT" "$item"
    ((i++))
  done
  hr
  local idx
  read -r -p "请选择序号: " idx
  [[ "$idx" =~ ^[0-9]+$ ]] || return 1
  (( idx >= 1 && idx <= ${#choices[@]} )) || return 1
  printf '%s' "${choices[$((idx-1))]}"
}

install_base_deps() {
  run_progress "准备系统依赖"
  run_spin "安装系统依赖..." bash -lc 'apt-get update >/dev/null && apt-get install -y curl ca-certificates openssl sed grep gawk coreutils unzip uuid-runtime iproute2 iptables >/dev/null'
}

install_shortcut_v2() {
  local src
  src="$(readlink -f "$0" 2>/dev/null || true)"
  [[ -n "$src" ]] || return 0
  [[ "$src" == /dev/* ]] && return 0
  [[ -f "$src" ]] || return 0

  install -m 755 "$src" "$SHORTCUT_TARGET"
  ln -sf "$SHORTCUT_TARGET" "$SHORTCUT_V2"
}

validate_port() {
  local p="$1"
  [[ "$p" =~ ^[0-9]+$ ]] || return 1
  (( p >= 1 && p <= 65535 ))
}

validate_domain() {
  local d="$1"
  [[ ${#d} -le 253 ]] || return 1
  [[ "$d" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]]
}

is_port_used() {
  local p="$1"
  ss -H -lntu 2>/dev/null | awk '{print $5}' | grep -Eq "[:.]${p}$"
}

random_password() {
  openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 20
}

random_hex8() {
  openssl rand -hex 8
}

random_uuid() {
  if has_cmd xray; then
    xray uuid
  elif has_cmd uuidgen; then
    uuidgen
  else
    cat /proc/sys/kernel/random/uuid
  fi
}

server_ip() {
  local ip=""
  ip="$(curl -4fsSL --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  [[ -n "$ip" ]] || ip="$(curl -6fsSL --max-time 5 https://api64.ipify.org 2>/dev/null || true)"
  [[ -n "$ip" ]] || ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  [[ -n "$ip" ]] || ip="YOUR_SERVER_IP"
  printf '%s' "$ip"
}

uri_host() {
  local host="$1"
  if [[ "$host" == *:* && "$host" != \[*\] ]]; then
    printf '[%s]' "$host"
  else
    printf '%s' "$host"
  fi
}

random_vendor_domain() {
  local n="${#VENDOR_DOMAINS[@]}"
  local i=$((RANDOM % n))
  printf '%s' "${VENDOR_DOMAINS[$i]}"
}

random_unused_port() {
  local min="$1"
  local max="$2"
  local avoid_start="${3:-0}"
  local avoid_end="${4:-0}"
  local p
  while true; do
    p="$(shuf -i "${min}-${max}" -n 1 2>/dev/null || awk -v a="$min" -v b="$max" 'BEGIN{srand(); print int(a+rand()*(b-a+1))}')"
    if (( avoid_start > 0 && avoid_end > 0 )) && (( p >= avoid_start && p <= avoid_end )); then
      continue
    fi
    if ! is_port_used "$p"; then
      printf '%s' "$p"
      return 0
    fi
  done
}

open_tcp() {
  local p="$1"
  if has_cmd ufw; then
    ufw allow "${p}/tcp" >/dev/null 2>&1 || true
  elif has_cmd firewall-cmd; then
    firewall-cmd --permanent --add-port="${p}/tcp" >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
  fi
}

open_udp() {
  local p="$1"
  if has_cmd ufw; then
    ufw allow "${p}/udp" >/dev/null 2>&1 || true
  elif has_cmd firewall-cmd; then
    firewall-cmd --permanent --add-port="${p}/udp" >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
  fi
}

open_udp_range() {
  local s="$1"
  local e="$2"
  if has_cmd ufw; then
    ufw allow "${s}:${e}/udp" >/dev/null 2>&1 || true
  elif has_cmd firewall-cmd; then
    firewall-cmd --permanent --add-port="${s}-${e}/udp" >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
  fi
}

remove_udp() {
  local p="$1"
  if has_cmd ufw; then
    ufw delete allow "${p}/udp" >/dev/null 2>&1 || true
  fi
}

remove_udp_range() {
  local s="$1"
  local e="$2"
  if has_cmd ufw; then
    ufw delete allow "${s}:${e}/udp" >/dev/null 2>&1 || true
  fi
}

remove_tcp() {
  local p="$1"
  if has_cmd ufw; then
    ufw delete allow "${p}/tcp" >/dev/null 2>&1 || true
  fi
}

default_nic() {
  local nic
  nic="$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -n 1)"
  printf '%s' "${nic:-eth0}"
}

cleanup_hop_rules() {
  local ln
  while IFS= read -r ln; do
    [[ -n "$ln" ]] || continue
    iptables -t nat -D PREROUTING "$ln" >/dev/null 2>&1 || true
  done < <(
    iptables -t nat -L PREROUTING --line-numbers -n -v 2>/dev/null |
      awk -v c="$HY2_RULE_COMMENT" '$0 ~ c {print $1}' |
      sort -rn
  )
}

apply_hop_rule() {
  local nic="$1"
  local start="$2"
  local end="$3"
  local port="$4"
  cleanup_hop_rules
  iptables -t nat -A PREROUTING \
    -i "$nic" \
    -p udp \
    --dport "${start}:${end}" \
    -m comment --comment "$HY2_RULE_COMMENT" \
    -j REDIRECT --to-ports "$port"
}

save_iptables() {
  if has_cmd netfilter-persistent; then
    netfilter-persistent save >/dev/null 2>&1 || true
  elif has_cmd apt-get; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent >/dev/null 2>&1 || true
    has_cmd netfilter-persistent && netfilter-persistent save >/dev/null 2>&1 || true
  fi
}

install_xray_core() {
  run_spin "安装 Xray Core..." bash -lc 'bash -c "$(curl -LfsS https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install'
  has_cmd xray || die "Xray 安装失败。"
}

generate_reality_keys() {
  local out private_key public_key
  out="$(xray x25519)"
  private_key="$(printf '%s\n' "$out" | awk -F': ' '/PrivateKey|Private key/ {print $2; exit}')"
  public_key="$(printf '%s\n' "$out" | awk -F': ' '/Password \(PublicKey\)|Public key/ {print $2; exit}')"
  [[ -n "$private_key" && -n "$public_key" ]] || die "REALITY 密钥生成失败。"
  printf '%s\n%s\n' "$private_key" "$public_key"
}

install_xray_reality() {
  local port="$1"
  local sni="$2"
  local target="$3"

  validate_port "$port" || die "Xray 端口无效：${port}"
  is_port_used "$port" && warn "Xray 端口 ${port} 当前已被占用，稍后可能启动失败。"

  ensure_data_dir
  install_base_deps
  install_xray_core
  run_progress "生成 REALITY 参数"

  local uuid short_id keys private_key public_key ip uhost link
  uuid="$(random_uuid)"
  short_id="$(random_hex8)"
  keys="$(generate_reality_keys)"
  private_key="$(printf '%s\n' "$keys" | sed -n '1p')"
  public_key="$(printf '%s\n' "$keys" | sed -n '2p')"
  ip="$(server_ip)"
  uhost="$(uri_host "$ip")"

  cat >"$XRAY_CONF" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "tag": "vless-reality",
      "listen": "0.0.0.0",
      "port": ${port},
      "protocol": "vless",
      "settings": {
        "clients": [
          { "id": "${uuid}", "flow": "xtls-rprx-vision", "email": "user" }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "raw",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "target": "${target}",
          "xver": 0,
          "serverNames": ["${sni}"],
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

  run_spin "校验 Xray 配置..." xray run -test -config "$XRAY_CONF"
  run_spin "启动 Xray 服务..." systemctl restart xray
  systemctl enable xray >/dev/null 2>&1 || true
  open_tcp "$port"
  printf '%s\n' "$port" >"$XRAY_PORT_FILE"

  link="vless://${uuid}@${uhost}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=chrome&pbk=${public_key}&sid=${short_id}&type=tcp&headerType=none#Xray-Reality"
  cat >"$XRAY_INFO" <<EOF
VLESS + REALITY

地址:       ${ip}
端口:       ${port}
UUID:       ${uuid}
Flow:       xtls-rprx-vision
SNI:        ${sni}
Target:     ${target}
PublicKey:  ${public_key}
ShortId:    ${short_id}

分享链接:
${link}
EOF

  ui_ok "Xray 安装完成。"
  cat "$XRAY_INFO"
}

uninstall_xray() {
  run_spin "卸载 Xray..." bash -lc 'bash -c "$(curl -LfsS https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove --purge'
  if [[ -f "$XRAY_PORT_FILE" ]]; then
    remove_tcp "$(<"$XRAY_PORT_FILE")"
  fi
  rm -f "$XRAY_INFO" "$XRAY_PORT_FILE"
  ui_ok "Xray 已卸载。"
}

write_hy2_state() {
  local port="$1"
  local hop_start="$2"
  local hop_end="$3"
  local password="$4"
  local sni="$5"
  local mode="$6"
  local email="$7"
  {
    printf 'PORT=%q\n' "$port"
    printf 'HOP_START=%q\n' "$hop_start"
    printf 'HOP_END=%q\n' "$hop_end"
    printf 'PASSWORD=%q\n' "$password"
    printf 'SNI=%q\n' "$sni"
    printf 'TLS_MODE=%q\n' "$mode"
    printf 'ACME_EMAIL=%q\n' "$email"
  } >"$HY2_STATE_FILE"
  chmod 600 "$HY2_STATE_FILE"
}

load_hy2_state() {
  if [[ -f "$HY2_STATE_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$HY2_STATE_FILE"
  fi
}

install_hy2_core() {
  run_spin "安装 Hysteria2 Core..." bash -lc 'bash <(curl -fsSL https://get.hy2.sh/)'
  has_cmd hysteria || die "Hysteria2 安装失败。"
}

write_hy2_self_signed() {
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
  local domain_input="$1"
  local hop_start="$2"
  local hop_end="$3"
  local port="$4"
  local password="$5"
  local masquerade="$6"

  validate_port "$hop_start" || die "跳跃起始端口无效。"
  validate_port "$hop_end" || die "跳跃结束端口无效。"
  (( hop_start < hop_end )) || die "跳跃端口范围必须满足 起始 < 结束。"

  if [[ -z "$port" ]]; then
    port="$(random_unused_port 10000 65535 "$hop_start" "$hop_end")"
  fi
  validate_port "$port" || die "HY2 监听端口无效。"
  (( port < hop_start || port > hop_end )) || die "HY2 监听端口不能位于跳跃范围内。"
  is_port_used "$port" && die "HY2 监听端口已被占用：${port}"

  [[ -n "$password" ]] || password="$(random_password)"

  local tls_mode sni acme_email insecure_query cert_dir ip uhost link nic
  cert_dir="/etc/hysteria/certs"
  acme_email=""
  insecure_query="&insecure=1"

  if [[ -n "$domain_input" ]]; then
    validate_domain "$domain_input" || die "你填写的域名格式无效：${domain_input}"
    tls_mode="acme"
    sni="$domain_input"
    acme_email="$(ask_input "ACME 邮箱" "admin@${domain_input}")"
    insecure_query=""
  else
    tls_mode="self-signed"
    sni="$(random_vendor_domain)"
  fi

  ensure_data_dir
  install_base_deps
  install_hy2_core
  run_progress "写入 Hysteria2 配置"

  install -d -m 755 /etc/hysteria
  if [[ "$tls_mode" == "acme" ]]; then
    cat >"$HY2_CONF" <<EOF
listen: :${port}

acme:
  domains:
    - ${sni}
  email: ${acme_email}

auth:
  type: password
  password: ${password}

masquerade:
  type: proxy
  proxy:
    url: ${masquerade}
    rewriteHost: true

quic:
  initStreamReceiveWindow: 26843545
  maxStreamReceiveWindow: 26843545
  initConnReceiveWindow: 67108864
  maxConnReceiveWindow: 67108864
EOF
  else
    write_hy2_self_signed "$cert_dir" "$sni"
    cat >"$HY2_CONF" <<EOF
listen: :${port}

tls:
  cert: ${cert_dir}/server.crt
  key: ${cert_dir}/server.key

auth:
  type: password
  password: ${password}

masquerade:
  type: proxy
  proxy:
    url: ${masquerade}
    rewriteHost: true

quic:
  initStreamReceiveWindow: 26843545
  maxStreamReceiveWindow: 26843545
  initConnReceiveWindow: 67108864
  maxConnReceiveWindow: 67108864
EOF
  fi

  chown -R hysteria:hysteria /etc/hysteria 2>/dev/null || true
  chmod 640 "$HY2_CONF" 2>/dev/null || true

  open_udp "$port"
  open_udp_range "$hop_start" "$hop_end"
  nic="$(default_nic)"
  apply_hop_rule "$nic" "$hop_start" "$hop_end" "$port"
  save_iptables

  run_spin "启动 Hysteria2 服务..." systemctl restart hysteria-server.service
  systemctl enable hysteria-server.service >/dev/null 2>&1 || true
  systemctl is-active --quiet hysteria-server.service || {
    journalctl --no-pager -n 40 -u hysteria-server.service >&2 || true
    die "Hysteria2 启动失败。"
  }

  printf '%s\n' "$port" >"$HY2_PORT_FILE"
  printf '%s-%s\n' "$hop_start" "$hop_end" >"$HY2_HOP_FILE"
  write_hy2_state "$port" "$hop_start" "$hop_end" "$password" "$sni" "$tls_mode" "$acme_email"

  ip="$(server_ip)"
  uhost="$(uri_host "$ip")"
  link="hysteria2://${password}@${uhost}:${port}/?mport=${hop_start}-${hop_end}${insecure_query}&sni=${sni}#Hysteria2"
  cat >"$HY2_INFO" <<EOF
Hysteria2

地址:       ${ip}
端口:       ${port}
跳跃范围:   ${hop_start}-${hop_end}
密码:       ${password}
SNI:        ${sni}
TLS 模式:   ${tls_mode}
伪装站点:   ${masquerade}

分享链接:
${link}
EOF

  ui_ok "Hysteria2 安装完成。"
  cat "$HY2_INFO"
}

uninstall_hy2() {
  load_hy2_state
  cleanup_hop_rules
  save_iptables

  if [[ -n "${PORT:-}" ]]; then
    remove_udp "$PORT"
  elif [[ -f "$HY2_PORT_FILE" ]]; then
    remove_udp "$(<"$HY2_PORT_FILE")"
  fi

  if [[ -n "${HOP_START:-}" && -n "${HOP_END:-}" ]]; then
    remove_udp_range "$HOP_START" "$HOP_END"
  elif [[ -f "$HY2_HOP_FILE" ]]; then
    local_range="$(<"$HY2_HOP_FILE")"
    start="${local_range%-*}"
    end="${local_range#*-}"
    remove_udp_range "$start" "$end"
  fi

  run_spin "卸载 Hysteria2..." bash -lc 'bash <(curl -fsSL https://get.hy2.sh/) --remove'
  rm -f "$HY2_INFO" "$HY2_PORT_FILE" "$HY2_HOP_FILE" "$HY2_STATE_FILE"
  ui_ok "Hysteria2 已卸载。"
}

show_xray_status() {
  ui_title "Xray 运行状态"
  printf '服务状态: %s\n' "$(systemctl is-active xray 2>/dev/null || echo unknown)"
  printf '开机自启: %s\n' "$(systemctl is-enabled xray 2>/dev/null || echo unknown)"
  if [[ -f "$XRAY_PORT_FILE" ]]; then
    printf '监听端口: %s/tcp\n' "$(<"$XRAY_PORT_FILE")"
  fi
  printf '\n最近日志:\n'
  journalctl --no-pager -n 20 -u xray 2>/dev/null || true
}

show_hy2_status() {
  ui_title "Hysteria2 运行状态"
  printf '服务状态: %s\n' "$(systemctl is-active hysteria-server 2>/dev/null || echo unknown)"
  printf '开机自启: %s\n' "$(systemctl is-enabled hysteria-server 2>/dev/null || echo unknown)"
  if [[ -f "$HY2_PORT_FILE" ]]; then
    printf '监听端口: %s/udp\n' "$(<"$HY2_PORT_FILE")"
  fi
  if [[ -f "$HY2_HOP_FILE" ]]; then
    printf '跳跃范围: %s/udp\n' "$(<"$HY2_HOP_FILE")"
  fi
  printf '\n监听信息:\n'
  ss -lunp 2>/dev/null | grep hysteria || printf '未检测到 hysteria 监听。\n'
  printf '\n最近日志:\n'
  journalctl --no-pager -n 20 -u hysteria-server 2>/dev/null || true
}

show_nodes() {
  ui_title "节点信息"
  if [[ -f "$XRAY_INFO" ]]; then
    cat "$XRAY_INFO"
    printf '\n'
  fi
  if [[ -f "$HY2_INFO" ]]; then
    cat "$HY2_INFO"
    printf '\n'
  fi
  if [[ ! -f "$XRAY_INFO" && ! -f "$HY2_INFO" ]]; then
    ui_note "暂无节点信息。"
  fi
}

xray_menu() {
  while true; do
    local action
    action="$(choose_one "Xray 菜单" \
      "安装/重装 VLESS+REALITY" \
      "查看运行状态" \
      "查看节点信息" \
      "卸载 Xray" \
      "返回上级")" || return 0
    case "$action" in
      "安装/重装 VLESS+REALITY")
        local port sni target
        port="$(ask_input "Xray 监听端口" "$XRAY_PORT_DEFAULT")"
        sni="$(ask_input "REALITY SNI" "$XRAY_SNI_DEFAULT")"
        target="$(ask_input "REALITY Target" "$XRAY_TARGET_DEFAULT")"
        install_xray_reality "$port" "$sni" "$target"
        ;;
      "查看运行状态") show_xray_status ;;
      "查看节点信息") [[ -f "$XRAY_INFO" ]] && cat "$XRAY_INFO" || ui_note "暂无 Xray 节点信息。" ;;
      "卸载 Xray")
        ask_confirm "确认卸载 Xray？" && uninstall_xray
        ;;
      "返回上级") return 0 ;;
    esac
  done
}

hy2_menu() {
  while true; do
    local action
    action="$(choose_one "Hysteria2 菜单" \
      "安装/重装 Hysteria2" \
      "查看运行状态" \
      "查看节点信息" \
      "卸载 Hysteria2" \
      "返回上级")" || return 0
    case "$action" in
      "安装/重装 Hysteria2")
        local hop_start hop_end port domain password masq
        hop_start="$(ask_input "跳跃端口起始" "$HY2_HOP_START_DEFAULT")"
        hop_end="$(ask_input "跳跃端口结束" "$HY2_HOP_END_DEFAULT")"
        validate_port "$hop_start" || die "跳跃起始端口无效。"
        validate_port "$hop_end" || die "跳跃结束端口无效。"
        (( hop_start < hop_end )) || die "跳跃端口必须 起始 < 结束。"
        local default_port
        default_port="$(random_unused_port 10000 65535 "$hop_start" "$hop_end")"
        port="$(ask_input "HY2 监听端口（留空自动随机）" "$default_port")"
        domain="$(ask_input "域名（留空=随机大厂域名；填写=你自己的域名）" "")"
        password="$(ask_password "HY2 密码（留空自动随机）")"
        masq="$(ask_input "伪装网站 URL" "$HY2_MASQ_DEFAULT")"
        install_hysteria2 "$domain" "$hop_start" "$hop_end" "$port" "$password" "$masq"
        ;;
      "查看运行状态") show_hy2_status ;;
      "查看节点信息") [[ -f "$HY2_INFO" ]] && cat "$HY2_INFO" || ui_note "暂无 Hysteria2 节点信息。" ;;
      "卸载 Hysteria2")
        ask_confirm "确认卸载 Hysteria2？" && uninstall_hy2
        ;;
      "返回上级") return 0 ;;
    esac
  done
}

status_menu() {
  local choice
  choice="$(choose_one "运行状态" "Xray" "Hysteria2" "全部" "返回")" || return 0
  case "$choice" in
    "Xray") show_xray_status ;;
    "Hysteria2") show_hy2_status ;;
    "全部") show_xray_status; printf '\n'; show_hy2_status ;;
    "返回") return 0 ;;
  esac
}

main_menu() {
  install_shortcut_v2 || true
  while true; do
    ui_title "VPS 代理脚本 v2 (ANSI UI)"
    local choice
    choice="$(choose_one "请选择功能" \
      "VLESS+REALITY" \
      "Hysteria2" \
      "查看运行状态" \
      "查看节点信息" \
      "安装/修复快捷指令 v2" \
      "退出")" || exit 0
    case "$choice" in
      "VLESS+REALITY") xray_menu ;;
      "Hysteria2") hy2_menu ;;
      "查看运行状态") status_menu ;;
      "查看节点信息") show_nodes ;;
      "安装/修复快捷指令 v2")
        install_shortcut_v2
        ui_ok "快捷指令已就绪：v2"
        ;;
      "退出") exit 0 ;;
    esac
  done
}

usage() {
  cat <<'EOF'
用法:
  bash proxy.sh                 # 交互菜单
  bash proxy.sh menu            # 交互菜单
  bash proxy.sh v2              # 交互菜单（快捷入口）
  bash proxy.sh status          # 查看全部状态
  bash proxy.sh nodes           # 查看节点信息
  bash proxy.sh xray-uninstall  # 卸载 Xray
  bash proxy.sh hy2-uninstall   # 卸载 Hysteria2
  bash proxy.sh install-shortcut# 安装快捷指令 v2

说明:
  - UI 风格: ANSI 颜色 + Unicode 图标 + 分隔线
  - Hysteria2:
    * 域名留空 -> 自动随机大厂域名（自签证书）
    * 填写域名 -> 使用你的域名（ACME）
    * 监听端口随机且避开已占用端口，且不落入跳跃端口范围
EOF
}

main() {
  require_root
  require_systemd
  detect_os
  install_base_deps
  ensure_data_dir

  local cmd="${1:-menu}"
  case "$cmd" in
    menu|v2) main_menu ;;
    status) show_xray_status; printf '\n'; show_hy2_status ;;
    nodes) show_nodes ;;
    xray-uninstall) uninstall_xray ;;
    hy2-uninstall) uninstall_hy2 ;;
    install-shortcut) install_shortcut_v2; ui_ok "快捷指令已就绪：v2" ;;
    -h|--help|help) usage ;;
    *) usage; die "未知命令: ${cmd}" ;;
  esac
}

main "$@"
