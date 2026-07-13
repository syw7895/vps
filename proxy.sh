#!/usr/bin/env bash
# VPS 代理一键脚本：Xray REALITY / Hysteria2 / VLESS-WS-TLS(可走 CF)
set -Eeuo pipefail

APP_NAME="vps-proxy"
CONFIG_DIR="/root/proxy-info"
REALITY_STATE="${CONFIG_DIR}/reality.conf"
CDN_STATE="${CONFIG_DIR}/cdn.conf"
XRAY_INFO="${CONFIG_DIR}/xray-reality.txt"
CDN_INFO="${CONFIG_DIR}/xray-cdn.txt"
HY2_INFO="${CONFIG_DIR}/hysteria2.txt"
XRAY_CONFIG="/usr/local/etc/xray/config.json"
HY2_CONFIG="/etc/hysteria/config.yaml"
HY2_CERT_DIR="/etc/hysteria/certs"
HY2_USER="hysteria"
V2_DIR="/usr/local/lib/vps-proxy"
V2_SCRIPT="${V2_DIR}/proxy.sh"
V2_BIN="/usr/local/bin/v2"
XRAY_INSTALLER_URL="${XRAY_INSTALLER_URL:-https://github.com/XTLS/Xray-install/raw/main/install-release.sh}"
HY2_INSTALLER_URL="${HY2_INSTALLER_URL:-https://get.hy2.sh/}"

# 颜色
if [[ -t 1 ]]; then
  R=$'\033[0m' B=$'\033[1m' D=$'\033[2m'
  RED=$'\033[31m' GRN=$'\033[32m' YEL=$'\033[33m' CYN=$'\033[36m' MAG=$'\033[35m' BLU=$'\033[34m'
else
  R='' B='' D='' RED='' GRN='' YEL='' CYN='' MAG='' BLU=''
fi

log()  { printf '%s[%s]%s %s\n' "$CYN" "$APP_NAME" "$R" "$*"; }
ok()   { printf '%s[%s]%s %s\n' "$GRN" "OK" "$R" "$*"; }
warn() { printf '%s[%s]%s %s\n' "$YEL" "!" "$R" "$*"; }
fail() { printf '%s[%s]%s %s\n' "$RED" "ERR" "$R" "$*" >&2; exit 1; }
hr()   { printf '%s────────────────────────────────────────%s\n' "$D" "$R"; }

usage() {
  cat <<'EOF'
用法:
  bash proxy.sh                 进入菜单
  bash proxy.sh menu|v2         进入菜单
  bash proxy.sh xray [参数]     安装 Xray VLESS + REALITY
  bash proxy.sh hy2  [参数]     安装 Hysteria2
  bash proxy.sh cdn  [参数]     安装 VLESS + WS + TLS（可走 Cloudflare）
  bash proxy.sh show            查看节点与状态
  bash proxy.sh install-shortcut  安装 v2 快捷命令
  bash proxy.sh uninstall-xray | uninstall-hy2 | uninstall-cdn | uninstall-v2

Xray REALITY:
  --port PORT   --sni DOMAIN   --target HOST:PORT   --uuid UUID

Hysteria2:
  --port PORT   --password PASS   --domain SNI   --masquerade URL

CDN (WS+TLS):
  --domain DOMAIN   --port PORT   --path /uri   --uuid UUID   --email EMAIL
EOF
}

# ---------- 基础 ----------
require_root() { [[ $EUID -eq 0 ]] || fail "请使用 root 运行"; }
require_systemd() { command -v systemctl >/dev/null || fail "需要 systemd"; }

detect_os() {
  [[ -r /etc/os-release ]] || fail "无法读取 /etc/os-release"
  # shellcheck source=/dev/null
  . /etc/os-release
  [[ ${ID:-} =~ ^(debian|ubuntu)$ ]] || fail "仅支持 Debian / Ubuntu"
  log "系统: ${PRETTY_NAME:-$ID}"
}

install_deps() {
  log "安装依赖..."
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    curl ca-certificates openssl sed grep gawk coreutils unzip iproute2 socat cron >/dev/null
}

ensure_dirs() { install -d -m 700 "$CONFIG_DIR"; }

require_arg() { [[ -n ${2:-} && $2 != --* ]] || fail "$1 需要参数值"; }

validate_port() {
  [[ $1 =~ ^[0-9]+$ ]] || fail "端口无效: $1"
  ((1 <= $1 && $1 <= 65535)) || fail "端口范围 1-65535: $1"
}

validate_domain() {
  [[ $1 =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,}$ ]] || fail "域名无效: $1"
}

validate_uuid() {
  [[ $1 =~ ^[A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[1-5][A-Fa-f0-9]{3}-[89ABab][A-Fa-f0-9]{3}-[A-Fa-f0-9]{12}$ ]] \
    || fail "UUID 无效: $1"
}

is_ipv4() {
  local ip=$1
  local -a o
  local x
  [[ $ip =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  IFS=. read -r -a o <<<"$ip"
  for x in "${o[@]}"; do
    ((10#$x <= 255)) || return 1
  done
  return 0
}

validate_target() {
  local t=$1 h p
  [[ $t =~ ^[^:[:space:]]+:[0-9]+$ ]] || fail "target 格式应为 host:port"
  h=${t%:*}; p=${t##*:}
  # 不可调用 validate_domain：失败会 exit，导致 IPv4 target 永远无法通过
  if [[ $h =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,}$ ]] || is_ipv4 "$h"; then
    :
  else
    fail "target 主机无效: $h"
  fi
  validate_port "$p"
}

random_uuid() {
  if command -v xray >/dev/null; then xray uuid
  elif [[ -r /proc/sys/kernel/random/uuid ]]; then cat /proc/sys/kernel/random/uuid
  else openssl rand -hex 16 | sed 's/\(........\)\(....\)\(....\)\(....\)\(............\)/\1-\2-\3-\4-\5/'
  fi
}

random_password() { openssl rand -hex 16; }

random_path() { printf '/%s' "$(openssl rand -hex 8)"; }

random_port() {
  local p i
  for ((i = 0; i < 64; i++)); do
    p=$(shuf -i 10000-60000 -n1)
    ss -H -lun 2>/dev/null | grep -qE ":${p}[[:space:]]" && continue
    printf %s "$p"
    return
  done
  fail "找不到空闲 UDP 端口，请用 --port 指定"
}

server_ip() {
  local ip
  ip=$(curl -4fsS --connect-timeout 5 --max-time 8 https://api.ipify.org 2>/dev/null || true)
  [[ -z $ip ]] && ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  printf %s "${ip:-YOUR_SERVER_IP}"
}

open_port() {
  local port=$1 proto=$2
  if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q 'Status: active'; then
    ufw allow "${port}/${proto}" >/dev/null 2>&1 || true
    ok "UFW 已放行 ${port}/${proto}"
  else
    warn "请自行放行 ${port}/${proto}（本机防火墙 + 云安全组）"
  fi
}

svc_state() {
  local unit=$1 bin=$2
  if systemctl is-active --quiet "$unit" 2>/dev/null; then echo running
  elif command -v "$bin" >/dev/null 2>&1; then echo stopped
  else echo missing
  fi
}

svc_label() {
  case $(svc_state "$1" "$2") in
    running) printf '%s● 运行中%s' "$GRN" "$R" ;;
    stopped) printf '%s○ 已停止%s' "$YEL" "$R" ;;
    missing) printf '%s- 未安装%s' "$D" "$R" ;;
  esac
}

restart_svc() {
  local unit=$1 name=$2
  systemctl enable "$unit" >/dev/null 2>&1 || true
  systemctl restart "$unit" || fail "$name 启动失败，请检查: journalctl -u $unit -n 30"
  sleep 1
  systemctl is-active --quiet "$unit" || fail "$name 未保持运行"
  ok "$name 运行中"
}

# ---------- Xray 安装与配置合并 ----------
install_xray_core() {
  if command -v xray >/dev/null; then
    log "Xray 已安装: $(xray version 2>/dev/null | head -n1 || echo ok)"
    return
  fi
  log "安装 Xray..."
  bash -c "$(curl -fsSL "$XRAY_INSTALLER_URL")" @ install
  command -v xray >/dev/null || fail "Xray 安装失败"
}

write_state() {
  local file=$1
  shift
  umask 077
  printf '%s\n' "$@" >"$file"
  chmod 600 "$file"
}

# shellcheck disable=SC1090
load_state() { [[ -f $1 ]] && . "$1" || true; }

build_xray_config() {
  local reality_json="" cdn_json="" xu xg xd
  # shellcheck disable=SC1090
  [[ -f $REALITY_STATE ]] && . "$REALITY_STATE"
  # shellcheck disable=SC1090
  [[ -f $CDN_STATE ]] && . "$CDN_STATE"

  if [[ -f $REALITY_STATE ]]; then
    reality_json=$(cat <<EOF
    {
      "tag": "vless-reality",
      "listen": "0.0.0.0",
      "port": ${REALITY_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [{ "id": "${REALITY_UUID}", "flow": "xtls-rprx-vision", "email": "reality" }],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${REALITY_TARGET}",
          "xver": 0,
          "serverNames": ["${REALITY_SNI}"],
          "privateKey": "${REALITY_PRIV}",
          "shortIds": ["${REALITY_SHORT}"]
        }
      },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] }
    }
EOF
)
  fi

  if [[ -f $CDN_STATE ]]; then
    cdn_json=$(cat <<EOF
    {
      "tag": "vless-ws-tls",
      "listen": "0.0.0.0",
      "port": ${CDN_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [{ "id": "${CDN_UUID}", "email": "cdn" }],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "security": "tls",
        "tlsSettings": {
          "certificates": [{
            "certificateFile": "${CDN_CERT}",
            "keyFile": "${CDN_KEY}"
          }]
        },
        "wsSettings": { "path": "${CDN_PATH}" }
      },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] }
    }
EOF
)
  fi

  if [[ -z $reality_json && -z $cdn_json ]]; then
    return 0
  fi

  local inbounds=""
  if [[ -n $reality_json && -n $cdn_json ]]; then
    inbounds="${reality_json},${cdn_json}"
  else
    inbounds="${reality_json}${cdn_json}"
  fi

  install -d -m 755 "$(dirname "$XRAY_CONFIG")"
  cat >"$XRAY_CONFIG" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
${inbounds}
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "block" }
  ]
}
EOF

  xu=$(systemctl show -p User --value xray 2>/dev/null || true)
  [[ -z $xu || $xu == - ]] && xu=nobody
  getent passwd "$xu" >/dev/null || xu=nobody
  xg=$(id -gn "$xu" 2>/dev/null || echo nogroup)
  xd=$(dirname "$XRAY_CONFIG")
  install -d -o root -g "$xg" -m 750 "$xd"
  chown "root:$xg" "$XRAY_CONFIG"
  chmod 640 "$XRAY_CONFIG"
  xray run -test -config "$XRAY_CONFIG" >/dev/null
}

# ---------- REALITY ----------
parse_reality_args() {
  REALITY_PORT="${REALITY_PORT:-443}"
  REALITY_SNI="${REALITY_SERVER_NAME:-${REALITY_SNI:-www.cloudflare.com}}"
  REALITY_TARGET="${REALITY_DEST:-${REALITY_TARGET:-www.cloudflare.com:443}}"
  REALITY_UUID="${REALITY_UUID:-}"
  while [[ $# -gt 0 ]]; do
    case $1 in
      --port) require_arg "$1" "${2:-}"; REALITY_PORT=$2; shift 2 ;;
      --sni) require_arg "$1" "${2:-}"; REALITY_SNI=$2; shift 2 ;;
      --target) require_arg "$1" "${2:-}"; REALITY_TARGET=$2; shift 2 ;;
      --uuid) require_arg "$1" "${2:-}"; REALITY_UUID=$2; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) fail "未知 REALITY 参数: $1" ;;
    esac
  done
}

generate_reality_keys() {
  local out priv pub
  out=$(xray x25519)
  priv=$(printf '%s\n' "$out" | awk -F': ' '/Private[Kk]ey|Private key/ {print $2; exit}')
  pub=$(printf '%s\n' "$out" | awk -F': ' '/Password \(PublicKey\)|Public key|PublicKey/ {print $2; exit}')
  [[ -n $priv && -n $pub ]] || fail "生成 REALITY 密钥失败"
  printf '%s\n%s\n' "$priv" "$pub"
}

install_reality() {
  parse_reality_args "$@"
  require_root; require_systemd; detect_os; install_deps; ensure_dirs
  validate_port "$REALITY_PORT"
  validate_domain "$REALITY_SNI"
  validate_target "$REALITY_TARGET"
  [[ -z $REALITY_UUID ]] || validate_uuid "$REALITY_UUID"
  [[ -n $REALITY_UUID ]] || REALITY_UUID=$(random_uuid)

  install_xray_core
  local keys priv pub short ip link
  keys=$(generate_reality_keys)
  priv=$(printf '%s\n' "$keys" | sed -n '1p')
  pub=$(printf '%s\n' "$keys" | sed -n '2p')
  short=$(openssl rand -hex 8)
  ip=$(server_ip)

  write_state "$REALITY_STATE" \
    "REALITY_PORT=${REALITY_PORT}" \
    "REALITY_UUID=${REALITY_UUID}" \
    "REALITY_SNI=${REALITY_SNI}" \
    "REALITY_TARGET=${REALITY_TARGET}" \
    "REALITY_PRIV=${priv}" \
    "REALITY_PUB=${pub}" \
    "REALITY_SHORT=${short}"

  build_xray_config
  restart_svc xray "Xray"
  open_port "$REALITY_PORT" tcp

  link="vless://${REALITY_UUID}@${ip}:${REALITY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${pub}&sid=${short}&type=tcp&headerType=none#Reality-${ip}"

  cat >"$XRAY_INFO" <<EOF
Xray VLESS + REALITY（直连）

地址:      ${ip}
端口:      ${REALITY_PORT}
UUID:      ${REALITY_UUID}
Flow:      xtls-rprx-vision
SNI:       ${REALITY_SNI}
目标:      ${REALITY_TARGET}
PublicKey: ${pub}
ShortId:   ${short}

分享链接:
${link}
EOF
  chmod 600 "$XRAY_INFO"
  ok "REALITY 安装完成"
  printf '\n'; cat "$XRAY_INFO"
}

# ---------- CDN WS+TLS ----------
parse_cdn_args() {
  CDN_PORT="${CDN_PORT:-8443}"
  CDN_DOMAIN="${CDN_DOMAIN:-}"
  CDN_PATH="${CDN_PATH:-}"
  CDN_UUID="${CDN_UUID:-}"
  CDN_EMAIL="${CDN_EMAIL:-}"
  while [[ $# -gt 0 ]]; do
    case $1 in
      --port) require_arg "$1" "${2:-}"; CDN_PORT=$2; shift 2 ;;
      --domain) require_arg "$1" "${2:-}"; CDN_DOMAIN=$2; shift 2 ;;
      --path) require_arg "$1" "${2:-}"; CDN_PATH=$2; shift 2 ;;
      --uuid) require_arg "$1" "${2:-}"; CDN_UUID=$2; shift 2 ;;
      --email) require_arg "$1" "${2:-}"; CDN_EMAIL=$2; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) fail "未知 CDN 参数: $1" ;;
    esac
  done
}

issue_cert() {
  local domain=$1 email=$2 certdir="${CONFIG_DIR}/certs/${domain}"
  install -d -m 700 "$certdir"

  if [[ -f $certdir/fullchain.pem && -f $certdir/privkey.pem ]]; then
    if openssl x509 -in "$certdir/fullchain.pem" -checkend 604800 -noout 2>/dev/null; then
      log "使用已有证书: $certdir"
      CDN_CERT="$certdir/fullchain.pem"
      CDN_KEY="$certdir/privkey.pem"
      return
    fi
  fi

  log "申请 Let's Encrypt 证书（需 80 端口可达）..."
  local acme="/root/.acme.sh/acme.sh"
  if [[ ! -x $acme ]]; then
    curl -fsSL https://get.acme.sh | sh -s email="${email}"
  fi
  [[ -x $acme ]] || fail "acme.sh 安装失败"

  # 临时停占 80 的服务（如有）
  local restarted_xray=0
  if systemctl is-active --quiet xray 2>/dev/null && ss -H -ltn 2>/dev/null | grep -qE ':80[[:space:]]'; then
    systemctl stop xray || true
    restarted_xray=1
  fi

  "$acme" --set-default-ca --server letsencrypt >/dev/null
  if ! "$acme" --issue -d "$domain" --standalone --keylength ec-256 --force; then
    ((restarted_xray)) && systemctl start xray || true
    fail "证书申请失败。请确认域名已解析到本机，且 80 端口未被占用/已放行"
  fi

  "$acme" --install-cert -d "$domain" --ecc \
    --fullchain-file "$certdir/fullchain.pem" \
    --key-file "$certdir/privkey.pem" \
    --reloadcmd "systemctl restart xray 2>/dev/null || true"

  chmod 600 "$certdir/privkey.pem"
  chmod 644 "$certdir/fullchain.pem"
  CDN_CERT="$certdir/fullchain.pem"
  CDN_KEY="$certdir/privkey.pem"
  ((restarted_xray)) && systemctl start xray 2>/dev/null || true
  ok "证书已就绪: $domain"
}

install_cdn() {
  parse_cdn_args "$@"
  [[ -n $CDN_DOMAIN ]] || fail "CDN 需要 --domain（例: bash proxy.sh cdn --domain example.com）"
  require_root; require_systemd; detect_os; install_deps; ensure_dirs
  validate_domain "$CDN_DOMAIN"
  validate_port "$CDN_PORT"
  [[ -z $CDN_UUID ]] || validate_uuid "$CDN_UUID"
  [[ -n $CDN_UUID ]] || CDN_UUID=$(random_uuid)
  [[ -n $CDN_PATH ]] || CDN_PATH=$(random_path)
  [[ $CDN_PATH == /* ]] || CDN_PATH="/$CDN_PATH"
  [[ -n $CDN_EMAIL ]] || CDN_EMAIL="admin@${CDN_DOMAIN}"

  install_xray_core
  issue_cert "$CDN_DOMAIN" "$CDN_EMAIL"

  write_state "$CDN_STATE" \
    "CDN_PORT=${CDN_PORT}" \
    "CDN_UUID=${CDN_UUID}" \
    "CDN_DOMAIN=${CDN_DOMAIN}" \
    "CDN_PATH=${CDN_PATH}" \
    "CDN_CERT=${CDN_CERT}" \
    "CDN_KEY=${CDN_KEY}"

  build_xray_config
  restart_svc xray "Xray"
  open_port "$CDN_PORT" tcp
  open_port 80 tcp

  local link
  link="vless://${CDN_UUID}@${CDN_DOMAIN}:${CDN_PORT}?encryption=none&security=tls&type=ws&host=${CDN_DOMAIN}&sni=${CDN_DOMAIN}&path=$(printf %s "$CDN_PATH" | sed 's|/|%2F|g')#CDN-${CDN_DOMAIN}"

  cat >"$CDN_INFO" <<EOF
Xray VLESS + WS + TLS（可走 Cloudflare CDN）

域名:   ${CDN_DOMAIN}
端口:   ${CDN_PORT}
UUID:   ${CDN_UUID}
传输:   WebSocket
TLS:    开启
Host:   ${CDN_DOMAIN}
SNI:    ${CDN_DOMAIN}
Path:   ${CDN_PATH}

分享链接:
${link}

说明:
- 域名请解析到本机；若使用 Cloudflare，可开启代理（橙云），SSL 建议 Full / Full strict。
- 客户端「地址」可改为自己测得的 CF 优选 IP，SNI 与 Host 保持域名不变。
EOF
  chmod 600 "$CDN_INFO"
  ok "CDN 节点安装完成"
  printf '\n'; cat "$CDN_INFO"
}

# ---------- Hysteria2 ----------
parse_hy2_args() {
  HY2_PORT="${HY2_PORT:-}"
  HY2_PASSWORD="${HY2_PASSWORD:-}"
  HY2_DOMAIN="${HY2_DOMAIN:-}"
  HY2_MASQUERADE="${HY2_MASQUERADE:-https://www.bing.com}"
  while [[ $# -gt 0 ]]; do
    case $1 in
      --port) require_arg "$1" "${2:-}"; HY2_PORT=$2; shift 2 ;;
      --password) require_arg "$1" "${2:-}"; HY2_PASSWORD=$2; shift 2 ;;
      --domain) require_arg "$1" "${2:-}"; HY2_DOMAIN=$2; shift 2 ;;
      --masquerade) require_arg "$1" "${2:-}"; HY2_MASQUERADE=$2; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) fail "未知 Hysteria2 参数: $1" ;;
    esac
  done
}

install_hy2_core() {
  if command -v hysteria >/dev/null; then
    log "Hysteria2 已安装"
    return
  fi
  log "安装 Hysteria2..."
  bash <(curl -fsSL "$HY2_INSTALLER_URL")
  command -v hysteria >/dev/null || fail "Hysteria2 安装失败"
}

install_hy2() {
  parse_hy2_args "$@"
  require_root; require_systemd; detect_os; install_deps; ensure_dirs
  [[ -n $HY2_PORT ]] && validate_port "$HY2_PORT" || HY2_PORT=$(random_port)
  [[ -n $HY2_PASSWORD ]] || HY2_PASSWORD=$(random_password)
  [[ -n $HY2_DOMAIN ]] || HY2_DOMAIN=${SNI_PRESETS[RANDOM % ${#SNI_PRESETS[@]}]}
  validate_domain "$HY2_DOMAIN"

  install_hy2_core
  getent passwd "$HY2_USER" >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin "$HY2_USER" 2>/dev/null || true

  install -d -o root -g "$HY2_USER" -m 750 "$HY2_CERT_DIR" /etc/hysteria
  openssl req -x509 -newkey rsa:2048 -sha256 -nodes \
    -keyout "$HY2_CERT_DIR/server.key" -out "$HY2_CERT_DIR/server.crt" \
    -days 3650 -subj "/CN=${HY2_DOMAIN}" -addext "subjectAltName=DNS:${HY2_DOMAIN}" >/dev/null 2>&1
  chown "root:${HY2_USER}" "$HY2_CERT_DIR/server.key" "$HY2_CERT_DIR/server.crt"
  chmod 640 "$HY2_CERT_DIR/server.key"
  chmod 644 "$HY2_CERT_DIR/server.crt"

  local cert_sha ip link
  cert_sha=$(openssl x509 -in "$HY2_CERT_DIR/server.crt" -noout -fingerprint -sha256 \
    | awk -F= 'NF>1{print $2}' | tr -d ':' | tr '[:upper:]' '[:lower:]')
  ip=$(server_ip)

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
  chown "root:${HY2_USER}" "$HY2_CONFIG"
  chmod 640 "$HY2_CONFIG"

  restart_svc hysteria-server "Hysteria2"
  open_port "$HY2_PORT" udp

  link="hysteria2://${HY2_PASSWORD}@${ip}:${HY2_PORT}/?sni=${HY2_DOMAIN}&insecure=1&pinSHA256=${cert_sha}#HY2-${ip}"

  cat >"$HY2_INFO" <<EOF
Hysteria2

地址:     ${ip}
端口:     ${HY2_PORT}
密码:     ${HY2_PASSWORD}
SNI:      ${HY2_DOMAIN}
证书指纹: ${cert_sha}
协议:     UDP

分享链接:
${link}
EOF
  chmod 600 "$HY2_INFO"
  ok "Hysteria2 安装完成"
  printf '\n'; cat "$HY2_INFO"
}

# ---------- 展示 / 卸载 ----------
show_info() {
  printf '\n%s%s 节点信息 %s\n' "$B" "$CYN" "$R"
  hr
  local f found=0
  for f in "$XRAY_INFO" "$CDN_INFO" "$HY2_INFO"; do
    if [[ -f $f ]]; then
      found=1
      cat "$f"
      printf '\n'
      hr
    fi
  done
  ((found)) || log "暂无已保存节点"
  printf '\n%s服务状态%s\n' "$B" "$R"
  printf '  REALITY/CDN (xray) : %b\n' "$(svc_label xray xray)"
  printf '  Hysteria2          : %b\n' "$(svc_label hysteria-server hysteria)"
  printf '\n'
}

uninstall_reality() {
  require_root
  rm -f "$REALITY_STATE" "$XRAY_INFO"
  if [[ -f $CDN_STATE ]]; then
    build_xray_config
    restart_svc xray "Xray"
    ok "已移除 REALITY，保留 CDN 入站"
  else
    if command -v xray >/dev/null; then
      bash -c "$(curl -fsSL "$XRAY_INSTALLER_URL")" @ remove --purge 2>/dev/null || true
    fi
    rm -f "$XRAY_CONFIG"
    ok "已卸载 Xray / REALITY"
  fi
}

uninstall_cdn() {
  require_root
  rm -f "$CDN_STATE" "$CDN_INFO"
  if [[ -f $REALITY_STATE ]]; then
    build_xray_config
    restart_svc xray "Xray"
    ok "已移除 CDN 入站，保留 REALITY"
  else
    if command -v xray >/dev/null && [[ ! -f $REALITY_STATE ]]; then
      bash -c "$(curl -fsSL "$XRAY_INSTALLER_URL")" @ remove --purge 2>/dev/null || true
      rm -f "$XRAY_CONFIG"
    fi
    ok "已卸载 CDN 节点"
  fi
}

uninstall_hy2() {
  require_root
  systemctl stop hysteria-server 2>/dev/null || true
  systemctl disable hysteria-server 2>/dev/null || true
  bash <(curl -fsSL "$HY2_INSTALLER_URL") --remove 2>/dev/null || true
  rm -f "$HY2_INFO" "$HY2_CONFIG"
  rm -rf "$HY2_CERT_DIR"
  rmdir /etc/hysteria 2>/dev/null || true
  ok "已卸载 Hysteria2"
}

uninstall_v2() {
  require_root
  if [[ -e $V2_BIN || -e $V2_SCRIPT ]]; then
    rm -f "$V2_BIN" "$V2_SCRIPT"
    rmdir "$V2_DIR" 2>/dev/null || true
    ok "已删除 v2 快捷命令"
  else
    warn "v2 未安装"
  fi
}

# ---------- v2 快捷命令 ----------
install_v2_files() {
  local src=${BASH_SOURCE[0]:-} tmp
  install -d -m 755 "$V2_DIR"
  if [[ -n $src && -r $src && $src != /dev/fd/* && $src != /proc/self/fd/* ]]; then
    install -m 755 "$src" "$V2_SCRIPT"
  elif [[ -n $src && -r $src ]]; then
    tmp=$(mktemp)
    cat "$src" >"$tmp"
    install -m 755 "$tmp" "$V2_SCRIPT"
    rm -f "$tmp"
  else
    fail "无法定位当前脚本，请下载后执行: bash proxy.sh install-shortcut"
  fi
  ln -sfn "$V2_SCRIPT" "$V2_BIN" 2>/dev/null || install -m 755 "$V2_SCRIPT" "$V2_BIN"
  ok "已安装快捷命令: v2"
}

install_v2() {
  require_root
  install_v2_files
  log "之后可直接输入: v2"
}

auto_v2() {
  [[ $EUID -eq 0 ]] || return 0
  install_v2_files 2>/dev/null || warn "自动安装 v2 跳过"
}

# ---------- 交互菜单 ----------
# REALITY / HY2 常用 SNI（多样选择，避免大家都挤同一个）
SNI_PRESETS=(
  www.cloudflare.com
  www.microsoft.com
  www.apple.com
  www.amazon.com
  www.yahoo.com
  www.bing.com
  www.nvidia.com
  www.samsung.com
  www.intel.com
  www.cisco.com
  gateway.icloud.com
  addons.mozilla.org
  www.speedtest.net
  dl.google.com
)

prompt() {
  local label=$1 default=$2 val
  if [[ -n $default ]]; then
    read -r -p "${label} [${default}]: " val
    printf %s "${val:-$default}"
  else
    read -r -p "${label}: " val
    printf %s "$val"
  fi
}

# 打印 SNI 列表；选中后设置全局 _SNI_CHOSEN
pick_sni() {
  local title=${1:-请选择 SNI / 伪装域名} i n c custom
  n=${#SNI_PRESETS[@]}
  printf '\n  %s%s%s\n' "$B" "$title" "$R"
  hr
  for ((i = 0; i < n; i++)); do
    printf '  %s%2d%s  %s\n' "$GRN" "$((i + 1))" "$R" "${SNI_PRESETS[i]}"
  done
  printf '  %s%2d%s  随机选择（推荐，降低特征）\n' "$CYN" "$((n + 1))" "$R"
  printf '  %s%2d%s  自定义\n' "$YEL" "$((n + 2))" "$R"
  hr
  read -r -p "  请选择 [$((n + 1))]: " c
  c=${c:-$((n + 1))}
  if [[ $c =~ ^[0-9]+$ ]] && ((c >= 1 && c <= n)); then
    _SNI_CHOSEN=${SNI_PRESETS[c - 1]}
  elif [[ $c == "$((n + 1))" ]]; then
    _SNI_CHOSEN=${SNI_PRESETS[RANDOM % n]}
    log "随机 SNI: ${_SNI_CHOSEN}"
  elif [[ $c == "$((n + 2))" ]]; then
    custom=$(prompt "自定义域名" "www.cloudflare.com")
    _SNI_CHOSEN=$custom
  else
    warn "无效选项，改为随机"
    _SNI_CHOSEN=${SNI_PRESETS[RANDOM % n]}
    log "随机 SNI: ${_SNI_CHOSEN}"
  fi
}

print_banner() {
  clear 2>/dev/null || true
  printf '\n'
  printf '%s╔══════════════════════════════════════════╗%s\n' "$CYN" "$R"
  printf '%s║%s  %sVPS 代理控制面板%s                        %s║%s\n' "$CYN" "$R" "$B" "$R" "$CYN" "$R"
  printf '%s║%s  %sREALITY · Hysteria2 · CF/WS-TLS%s         %s║%s\n' "$CYN" "$R" "$D" "$R" "$CYN" "$R"
  printf '%s╚══════════════════════════════════════════╝%s\n' "$CYN" "$R"
  printf '\n'
  printf '  %s状态%s\n' "$B" "$R"
  printf '  ├─ REALITY     %b\n' "$( [[ -f $REALITY_STATE ]] && svc_label xray xray || printf '%s- 未安装%s' "$D" "$R" )"
  printf '  ├─ CDN/WS-TLS  %b\n' "$( [[ -f $CDN_STATE ]] && svc_label xray xray || printf '%s- 未安装%s' "$D" "$R" )"
  printf '  └─ Hysteria2   %b\n' "$(svc_label hysteria-server hysteria)"
  printf '\n'
}

menu_install() {
  while true; do
    print_banner
    printf '  %s【安装代理】%s\n' "$B$MAG" "$R"
    hr
    printf '  %s1%s  Xray VLESS + REALITY（直连）\n' "$GRN" "$R"
    printf '  %s2%s  Hysteria2（UDP）\n' "$GRN" "$R"
    printf '  %s3%s  VLESS + WS + TLS（可走 Cloudflare）\n' "$GRN" "$R"
    printf '  %s0%s  返回主菜单\n' "$D" "$R"
    hr
    local c
    read -r -p "  请选择: " c
    case $c in
      1)
        local port sni target
        port=$(prompt "TCP 端口" "443")
        pick_sni "REALITY 伪装目标 / SNI（dest 默认与 SNI 相同）"
        sni=$_SNI_CHOSEN
        target=$(prompt "回落 target host:port" "${sni}:443")
        install_reality --port "$port" --sni "$sni" --target "$target"
        auto_v2
        read -r -p $'\n按回车返回...' _
        ;;
      2)
        local hp hd
        hp=$(prompt "UDP 端口（空=随机）" "")
        pick_sni "Hysteria2 证书 SNI"
        hd=$_SNI_CHOSEN
        local args=(--domain "$hd")
        [[ -n $hp ]] && args+=(--port "$hp")
        install_hy2 "${args[@]}"
        auto_v2
        read -r -p $'\n按回车返回...' _
        ;;
      3)
        local domain port path email
        domain=$(prompt "域名（已解析到本机）" "")
        [[ -n $domain ]] || { warn "域名不能为空"; sleep 1; continue; }
        port=$(prompt "TLS 端口" "8443")
        path=$(prompt "WebSocket path（空=随机）" "")
        email=$(prompt "证书邮箱" "admin@${domain}")
        local args=(--domain "$domain" --port "$port" --email "$email")
        [[ -n $path ]] && args+=(--path "$path")
        install_cdn "${args[@]}"
        auto_v2
        read -r -p $'\n按回车返回...' _
        ;;
      0) return ;;
      *) warn "无效选项"; sleep 1 ;;
    esac
  done
}

menu_uninstall() {
  while true; do
    print_banner
    printf '  %s【卸载】%s\n' "$B$YEL" "$R"
    hr
    printf '  %s1%s  卸载 REALITY\n' "$YEL" "$R"
    printf '  %s2%s  卸载 CDN (WS+TLS)\n' "$YEL" "$R"
    printf '  %s3%s  卸载 Hysteria2\n' "$YEL" "$R"
    printf '  %s4%s  卸载 v2 快捷命令\n' "$YEL" "$R"
    printf '  %s0%s  返回主菜单\n' "$D" "$R"
    hr
    local c
    read -r -p "  请选择: " c
    case $c in
      1) uninstall_reality; read -r -p $'\n按回车返回...' _ ;;
      2) uninstall_cdn; read -r -p $'\n按回车返回...' _ ;;
      3) uninstall_hy2; read -r -p $'\n按回车返回...' _ ;;
      4) uninstall_v2; read -r -p $'\n按回车返回...' _ ;;
      0) return ;;
      *) warn "无效选项"; sleep 1 ;;
    esac
  done
}

main_menu() {
  while true; do
    print_banner
    printf '  %s1%s  安装代理\n' "$GRN" "$R"
    printf '  %s2%s  查看节点 / 服务状态\n' "$CYN" "$R"
    printf '  %s3%s  卸载\n' "$YEL" "$R"
    printf '  %s4%s  安装 / 更新 v2 快捷命令\n' "$BLU" "$R"
    printf '  %s0%s  退出\n' "$D" "$R"
    hr
    local c
    read -r -p "  请选择: " c
    case $c in
      1) menu_install ;;
      2) show_info; read -r -p $'按回车返回...' _ ;;
      3) menu_uninstall ;;
      4) install_v2; read -r -p $'\n按回车返回...' _ ;;
      0) printf '\n%s再见%s\n\n' "$D" "$R"; exit 0 ;;
      *) warn "无效选项"; sleep 1 ;;
    esac
  done
}

# ---------- 入口 ----------
# 节点信息保存在 /root/proxy-info（仅 root 可读）。
# 用 admin 直接跑 v2 会看不到节点，这里自动提权。
elevate_if_needed() {
  [[ $EUID -eq 0 ]] && return 0
  case ${1:-} in
    -h|--help|help) return 0 ;;
  esac
  command -v sudo >/dev/null 2>&1 || fail "请使用 root 运行，或安装 sudo 后执行: sudo $0 $*"
  local self
  self=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || true)
  [[ -n $self && -r $self ]] || self=$0
  # 用 bash 显式执行，避免 /tmp noexec 或权限导致 sudo 直接跑脚本失败
  exec sudo -- bash "$self" "$@"
}

main() {
  local cmd=${1:-menu}
  [[ $# -gt 0 ]] && shift
  case $cmd in
    menu|v2|"")
      auto_v2 2>/dev/null || true
      main_menu
      ;;
    xray|reality) install_reality "$@"; auto_v2 ;;
    hy2|hysteria2) install_hy2 "$@"; auto_v2 ;;
    cdn|cf|ws) install_cdn "$@"; auto_v2 ;;
    show|status) show_info ;;
    install-shortcut|shortcut) install_v2 ;;
    uninstall-xray|uninstall-reality) uninstall_reality ;;
    uninstall-cdn|uninstall-cf|uninstall-ws) uninstall_cdn ;;
    uninstall-hy2|uninstall-hysteria2) uninstall_hy2 ;;
    uninstall-v2|uninstall-shortcut) uninstall_v2 ;;
    -h|--help|help) usage ;;
    *) fail "未知命令: $cmd（--help 查看用法）" ;;
  esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  elevate_if_needed "$@"
  trap 'fail "脚本第 $LINENO 行失败 (exit $?) "' ERR
  main "$@"
fi
