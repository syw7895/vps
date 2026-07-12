#!/usr/bin/env bash
set -Eeuo pipefail

# ===== 基础配置 =====
APP_NAME="vps-proxy"
CONFIG_DIR="/root/proxy-info"
BACKUP_DIR="${CONFIG_DIR}/backups"
PUBLIC_IP=""
XRAY_PORT="443"
XRAY_SNI="${REALITY_SERVER_NAME:-www.cloudflare.com}"
XRAY_TARGET="${REALITY_DEST:-www.cloudflare.com:443}"
XRAY_UUID=""
XRAY_CONFIG="/usr/local/etc/xray/config.json"
XRAY_INFO_FILE="${CONFIG_DIR}/xray-reality.txt"
HY2_PORT=""
HY2_PASSWORD=""
HY2_DOMAIN=""
HY2_MASQUERADE="https://www.bing.com"
HY2_PORT_SET_BY_USER="0"
HY2_CONFIG="/etc/hysteria/config.yaml"
HY2_CERT_DIR="/etc/hysteria/certs"
HY2_INFO_FILE="${CONFIG_DIR}/hysteria2.txt"
XRAY_INSTALLER_URL="${XRAY_INSTALLER_URL:-https://raw.githubusercontent.com/XTLS/Xray-install/e741a4f56d368afbb9e5be3361b40c4552d3710d/install-release.sh}"
HY2_INSTALLER_URL="${HY2_INSTALLER_URL:-https://raw.githubusercontent.com/apernet/hysteria/d1cd1503d35d3cd3fbe176be634b805d560ec7e7/scripts/install_server.sh}"
XRAY_INSTALLER_SHA256="${XRAY_INSTALLER_SHA256:-7f70c95f6b418da8b4f4883343d602964915e28748993870fd554383afdbe555}"
HY2_INSTALLER_SHA256="${HY2_INSTALLER_SHA256:-e6b9023dcc0142f155546548b9d7a75ce288704d6dead0c2010d61663b90e217}"
# 默认下载独立 v2 快照；提交时由发布流程填入不可变提交与 SHA256。
V2_SCRIPT_URL="${V2_SCRIPT_URL:-https://raw.githubusercontent.com/syw7895/vps/5ae1b8594e2574dd06aacaeeae87c976c22dbf27/v2.sh}"
V2_SCRIPT_SHA256="${V2_SCRIPT_SHA256:-841caf0390bd1d53accdbb412e3b6a0aac95af3b53d6d838056365e7dba49fc2}"
V2_INSTALL_DIR="/usr/local/lib/vps-proxy"
V2_SCRIPT_PATH="${V2_INSTALL_DIR}/proxy.sh"
V2_COMMAND_PATH="/usr/local/bin/v2"
HY2_SERVICE_USER="hysteria"
BIG_TECH_DOMAINS=("www.bing.com" "www.microsoft.com" "www.apple.com" "www.amazon.com" "www.cloudflare.com")

# 颜色
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m' C_BOLD=$'\033[1m' C_DIM=$'\033[2m'
  C_RED=$'\033[31m' C_GREEN=$'\033[32m' C_YELLOW=$'\033[33m' C_CYAN=$'\033[36m'
else
  C_RESET='' C_BOLD='' C_DIM='' C_RED='' C_GREEN='' C_YELLOW='' C_CYAN=''
fi

log()  { printf '%s[%s]%s %s\n' "$C_CYAN" "$APP_NAME" "$C_RESET" "$*"; }
ok()   { printf '%s[%s] 完成:%s %s\n' "$C_GREEN" "$APP_NAME" "$C_RESET" "$*"; }
warn() { printf '%s[%s] 提醒:%s %s\n' "$C_YELLOW" "$APP_NAME" "$C_RESET" "$*"; }
fail() { printf '%s[%s] 错误:%s %s\n' "$C_RED" "$APP_NAME" "$C_RESET" "$*" >&2; exit 1; }
hr()   { printf '%s\n' "------------------------------------------------------------"; }
title(){ printf '\n%s%s%s\n' "$C_BOLD" "$1" "$C_RESET"; hr; }
trap 'fail "脚本在第 $LINENO 行失败，退出码：$?"' ERR

usage() {
  cat <<'EOF'
用法:
  bash proxy.sh                 # 进入交互菜单
  bash proxy.sh xray [参数]      # 安装/更新 Xray VLESS + REALITY
  bash proxy.sh hy2 [参数]       # 安装/更新 Hysteria2
  bash proxy.sh v2               进入菜单（同 menu）
  bash proxy.sh install-shortcut  安装 v2 快捷命令
  bash proxy.sh show              查看节点信息与服务状态
  bash proxy.sh uninstall-xray | uninstall-hy2 | uninstall-v2

Xray 参数:
  --port PORT          TCP 监听端口（默认: 443）
  --sni DOMAIN         REALITY 伪装域名（默认: www.cloudflare.com）
  --target HOST:PORT   REALITY 回落目标（默认: www.cloudflare.com:443）
  --uuid UUID          客户端 UUID（不填自动生成）
  --public-ip IPv4     分享链接使用的公网 IPv4（自动检测失败时必填）

Hysteria2 参数:
  --port PORT          UDP 监听端口（不填自动随机）
  --password VALUE     认证密码（不填自动生成）
  --domain DOMAIN      证书/SNI 域名（不填默认随机大厂域名）
  --masquerade URL     伪装网站（默认: https://www.bing.com）
  --public-ip IPv4     分享链接使用的公网 IPv4（自动检测失败时必填）

示例:
  bash proxy.sh xray --port 443 --sni www.cloudflare.com --target www.cloudflare.com:443
  bash proxy.sh hy2 --domain example.com
EOF
}

require_root() { [[ $EUID -eq 0 ]] || fail "请使用 root 用户运行。"; }
require_systemd() { command -v systemctl >/dev/null || fail "不支持 systemctl。"; }
detect_os() {
  [[ -r /etc/os-release ]] || fail "无法读取 /etc/os-release。"
  . /etc/os-release
  [[ ${ID:-} =~ ^(debian|ubuntu)$ ]] || fail "仅支持 Debian/Ubuntu"
  log "检测到系统：${PRETTY_NAME:-$ID}"
}
install_base_deps() {
  log "安装基础依赖..."
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates openssl sed grep gawk coreutils unzip iproute2
}
ensure_dirs() { install -d -m 700 "$CONFIG_DIR" "$BACKUP_DIR"; }

backup_managed_state() {
  local label=$1 stamp archive path
  shift
  local -a paths=() existing=()
  paths=("$@")
  for path in "${paths[@]}"; do
    [[ -e "$path" || -L "$path" ]] && existing+=("$path")
  done
  ((${#existing[@]})) || return 0

  stamp=$(date -u +%Y%m%dT%H%M%SZ)-$RANDOM
  archive="$BACKUP_DIR/${label}-${stamp}.tar.gz"
  (umask 077; tar -C / -czf "$archive" "${existing[@]#/}")
  chmod 600 "$archive"
  ok "已备份原有 ${label} 配置：${archive}"
}

curl_download() { curl -fL --retry 3 --connect-timeout 10 --max-time 120 -o "$2" "$1" && [[ -s $2 ]]; }
is_valid_sha256() { [[ $1 =~ ^[A-Fa-f0-9]{64}$ ]]; }
require_sha256() { is_valid_sha256 "$1" || fail "$2 缺少或格式错误的 SHA256；拒绝执行未校验的远程脚本。"; }
sha256_matches() {
  is_valid_sha256 "$2" || return 1
  local actual; actual=$(sha256sum "$1" | awk '{print $1}')
  [[ ${actual,,} == "${2,,}" ]]
}
download_remote_script() { curl_download "$1" "$2" || fail "下载失败：$1"; }
verify_script_sha256() { require_sha256 "$2" "安装脚本"; sha256_matches "$1" "$2" || fail "哈希校验失败。"; }
run_remote_script() {
  local url=$1 expected_sha=$2; shift 2
  local script_file rc=0
  script_file=$(mktemp /tmp/${APP_NAME}.installer.XXXXXX.sh)
  download_remote_script "$url" "$script_file"
  verify_script_sha256 "$script_file" "$expected_sha"
  chmod 700 "$script_file"
  bash "$script_file" "$@" || rc=$?
  rm -f "$script_file"
  ((rc==0)) || return $rc
}

validate_port() {
  [[ $1 =~ ^[0-9]+$ ]] || fail "端口无效：$1"
  ((1<=$1 && $1<=65535)) || fail "端口必须在 1-65535：$1"
}
is_ipv4_address() {
  local ip=$1; local -a o; local IFS=. x
  [[ $ip =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  read -ra o <<<"$ip"
  for x in "${o[@]}"; do ((10#$x<=255)) || return 1; done
}
validate_target() {
  local t=$1 h p
  [[ $t =~ ^[^:[:space:]]+:[0-9]+$ ]] || fail "target 格式错误，应为 host:port"
  h=${t%:*}; p=${t##*:}
  { [[ $h =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,}$ ]] || is_ipv4_address "$h"; } || fail "target 主机无效：$h"
  validate_port "$p"
}
validate_domain() { [[ $1 =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,}$ ]] || fail "域名格式错误：$1"; }
validate_uuid() { [[ $1 =~ ^[A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[1-5][A-Fa-f0-9]{3}-[89ABab][A-Fa-f0-9]{3}-[A-Fa-f0-9]{12}$ ]] || fail "UUID 格式错误：$1"; }
validate_hy2_password() { [[ $1 =~ ^[-A-Za-z0-9._~]{1,128}$ ]] || fail "密码只能包含字母数字-._~，长度1-128。"; }
validate_hy2_masquerade() {
  local p='^https?://[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{1,5})?(/[A-Za-z0-9._~:/?@!$&()*+,;=%-]*)?$'
  [[ $1 =~ $p ]] || fail "伪装 URL 格式错误。"
}

listener_uses_port() {
  local port=$1 proto=$2 flags
  case $proto in
    tcp) flags='-H -ltn' ;;
    udp) flags='-H -lun' ;;
    *) fail "未知端口协议：$proto" ;;
  esac
  ss $flags 2>/dev/null | awk -v suffix=":${port}" '$4 ~ (suffix "$") {found=1} END {exit !found}'
}

port_reserved_by_forwarder() {
  local port=$1 proto=$2
  if command -v docker >/dev/null 2>&1 &&
    docker ps --format '{{.Ports}}' 2>/dev/null | grep -qE ":${port}->[^,]*/${proto}"; then
    return 0
  fi
  if command -v podman >/dev/null 2>&1 &&
    podman ps --format '{{.Ports}}' 2>/dev/null | grep -qE ":${port}->[^,]*/${proto}"; then
    return 0
  fi
  if command -v iptables-save >/dev/null 2>&1 &&
    iptables-save -t nat 2>/dev/null | grep -qE "(--dport|dport)[[:space:]]+${port}.*(DNAT|REDIRECT)"; then
    return 0
  fi
  if command -v nft >/dev/null 2>&1 &&
    nft list ruleset 2>/dev/null | grep -qE "dport[[:space:]]+${port}.*(dnat|redirect)"; then
    return 0
  fi
  return 1
}

is_port_in_use() {
  listener_uses_port "$1" "$2" || port_reserved_by_forwarder "$1" "$2"
}

service_owns_port() {
  local s=$1 p=$2
  systemctl is-active --quiet "$s" 2>/dev/null || return 1
  case $s in
    xray) [[ -r $XRAY_CONFIG ]] && grep -qE "\"port\"[[:space:]]*:[[:space:]]*${p}([[:space:]]*,|[[:space:]]*$)" "$XRAY_CONFIG" ;;
    hysteria-server) [[ -r $HY2_CONFIG ]] && grep -qE "^[[:space:]]*listen:[[:space:]]*:${p}[[:space:]]*(#.*)?$" "$HY2_CONFIG" ;;
    *) return 1 ;;
  esac
}

ensure_port_available() {
  local p=$1 s=$2 l=$3 proto=$4
  port_reserved_by_forwarder "$p" "$proto" &&
    fail "端口 ${p}/${proto} 已被容器或 NAT 转发占用。"
  listener_uses_port "$p" "$proto" || return 0
  service_owns_port "$s" "$p" && { warn "$l 正在使用端口 $p，允许更新。"; return 0; }
  fail "端口 ${p}/${proto} 已被其他程序监听。"
}

random_free_port() {
  local proto=$1 p a
  for ((a=1;a<=128;a++)); do
    p=$(shuf -i 10000-65535 -n1)
    is_port_in_use "$p" "$proto" || { printf %s "$p"; return; }
  done
  fail "连续 128 次未找到可用 ${proto} 端口，请手动 --port。"
}
random_big_tech_domain() { printf %s "${BIG_TECH_DOMAINS[RANDOM%${#BIG_TECH_DOMAINS[@]}]}"; }
resolve_public_ip() {
  local ip endpoint
  if [[ -n "$PUBLIC_IP" ]]; then
    is_ipv4_address "$PUBLIC_IP" || fail "--public-ip 必须是有效 IPv4 地址：${PUBLIC_IP}"
    printf %s "$PUBLIC_IP"
    return
  fi

  for endpoint in https://api.ipify.org https://ipv4.icanhazip.com https://ifconfig.me/ip; do
    ip=$(curl -4fsSL --connect-timeout 5 --max-time 10 "$endpoint" 2>/dev/null | tr -d '[:space:]' || true)
    if is_ipv4_address "$ip"; then
      printf %s "$ip"
      return
    fi
  done
  fail "无法可靠获取公网 IPv4；请通过 --public-ip 明确指定。"
}
random_password() { openssl rand -hex 16; }
random_uuid() {
  if command -v xray >/dev/null; then xray uuid
  elif command -v uuidgen >/dev/null; then uuidgen
  elif [[ -r /proc/sys/kernel/random/uuid ]]; then cat /proc/sys/kernel/random/uuid
  else fail "无法生成 UUID。"
  fi
}
require_arg_value() { [[ -n ${2:-} && $2 != --* ]] || fail "$1 后面需要参数值。"; }
open_firewall_port() {
  local port=$1 proto=$2
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw allow "${port}/${proto}" >/dev/null && ok "已通过 UFW 放行 ${port}/${proto}。"
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="${port}/${proto}" >/dev/null
    firewall-cmd --reload >/dev/null
    ok "已通过 firewalld 放行 ${port}/${proto}。"
  elif command -v nft >/dev/null 2>&1; then
    warn "检测到 nftables；未自动修改规则。请确认 input 链允许 ${port}/${proto}。"
  else
    warn "未检测到活动的 UFW/firewalld；请自行确认主机防火墙允许 ${port}/${proto}。"
  fi
  warn "还需在云安全组/网络 ACL 放行入站 ${port}/${proto}，建议仅允许你的客户端 IP/CIDR。"
}

service_state() {
  local s=$1 b=$2
  if systemctl is-active --quiet "$s" 2>/dev/null; then printf running
  elif systemctl is-failed --quiet "$s" 2>/dev/null; then printf failed
  elif command -v "$b" >/dev/null; then printf stopped
  else printf missing
  fi
}
service_status_label() {
  case $(service_state "$1" "$2") in
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
  command -v journalctl >/dev/null || return
  printf '\n%s[%s 最近日志]%s\n' "$C_CYAN" "$2" "$C_RESET"
  journalctl -u "$1" -n "${3:-25}" --no-pager -o short-iso 2>/dev/null || true
}
restart_and_verify_service() {
  local s=$1 l=$2 a
  systemctl restart "$s" || { show_journal "$s" "$l"; fail "$l 重启失败。"; }
  for ((a=1;a<=5;a++)); do systemctl is-active --quiet "$s" && return; sleep 1; done
  show_journal "$s" "$l"; fail "$l 重启后未保持运行。"
}

parse_xray_args() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      --port) require_arg_value "$1" "${2:-}"; XRAY_PORT=$2; shift 2 ;;
      --sni) require_arg_value "$1" "${2:-}"; XRAY_SNI=$2; shift 2 ;;
      --target) require_arg_value "$1" "${2:-}"; XRAY_TARGET=$2; shift 2 ;;
      --uuid) require_arg_value "$1" "${2:-}"; XRAY_UUID=$2; shift 2 ;;
      --public-ip) require_arg_value "$1" "${2:-}"; PUBLIC_IP=$2; shift 2 ;;
      --help|-h) usage; exit 0 ;;
      *) fail "未知 Xray 参数：$1" ;;
    esac
  done
}
parse_hy2_args() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      --port) require_arg_value "$1" "${2:-}"; HY2_PORT=$2; HY2_PORT_SET_BY_USER=1; shift 2 ;;
      --password) require_arg_value "$1" "${2:-}"; HY2_PASSWORD=$2; shift 2 ;;
      --domain) require_arg_value "$1" "${2:-}"; HY2_DOMAIN=$2; shift 2 ;;
      --masquerade) require_arg_value "$1" "${2:-}"; HY2_MASQUERADE=$2; shift 2 ;;
      --public-ip) require_arg_value "$1" "${2:-}"; PUBLIC_IP=$2; shift 2 ;;
      --help|-h) usage; exit 0 ;;
      *) fail "未知 Hysteria2 参数：$1" ;;
    esac
  done
}

install_xray_core() {
  log "安装或更新 Xray..."
  run_remote_script "$XRAY_INSTALLER_URL" "$XRAY_INSTALLER_SHA256" install
  command -v xray >/dev/null || fail "Xray 安装失败。"
}
generate_reality_keys() {
  local out priv pub
  out=$(xray x25519)
  priv=$(printf '%s\n' "$out" | awk -F': ' '/PrivateKey|Private key/ {print $2; exit}')
  pub=$(printf '%s\n' "$out" | awk -F': ' '/Password \(PublicKey\)|Public key/ {print $2; exit}')
  [[ -n $priv && -n $pub ]] || fail "REALITY 密钥生成失败。"
  printf '%s\n%s\n' "$priv" "$pub"
}

xray_config_value() {
  local key=$1
  [[ -r "$XRAY_CONFIG" ]] || return 0
  sed -nE "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"([^\"]+)\".*/\\1/p" "$XRAY_CONFIG" | head -n1
}

existing_xray_short_id() {
  [[ -r "$XRAY_CONFIG" ]] || return 0
  sed -nE 's/.*"shortIds"[[:space:]]*:[[:space:]]*\\[[[:space:]]*"([A-Fa-f0-9]+)".*/\\1/p' "$XRAY_CONFIG" | head -n1
}

existing_xray_public_key() {
  [[ -r "$XRAY_INFO_FILE" ]] || return 0
  sed -nE 's/^PublicKey:[[:space:]]*([^[:space:]]+).*/\\1/p' "$XRAY_INFO_FILE" | head -n1
}

derive_reality_public_key() {
  local private_key=$1 out
  out=$(xray x25519 -i "$private_key" 2>/dev/null || true)
  printf '%s\n' "$out" | awk -F': ' '/Password \\(PublicKey\\)|Public key/ {print $2; exit}'
}

install_xray_reality() {
  parse_xray_args "$@"
  require_root; require_systemd; detect_os; install_base_deps; ensure_dirs
  validate_port "$XRAY_PORT"; validate_target "$XRAY_TARGET"; validate_domain "$XRAY_SNI"
  [[ -z $XRAY_UUID ]] || validate_uuid "$XRAY_UUID"
  ensure_port_available "$XRAY_PORT" xray "Xray" tcp
  ip=$(resolve_public_ip)
  backup_managed_state xray "$XRAY_CONFIG" "$XRAY_INFO_FILE"
  install_xray_core
  local short_id keys priv pub link existing_uuid existing_priv existing_pub existing_short
  existing_uuid=$(xray_config_value id)
  existing_priv=$(xray_config_value privateKey)
  existing_pub=$(existing_xray_public_key)
  existing_short=$(existing_xray_short_id)

  if [[ -z $XRAY_UUID && $existing_uuid =~ ^[A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[1-5][A-Fa-f0-9]{3}-[89ABab][A-Fa-f0-9]{3}-[A-Fa-f0-9]{12}$ ]]; then
    XRAY_UUID=$existing_uuid
    log "复用已有 Xray UUID。"
  fi
  [[ -n $XRAY_UUID ]] || XRAY_UUID=$(random_uuid)

  if [[ $existing_priv =~ ^[A-Za-z0-9_-]{20,}$ && $existing_short =~ ^[A-Fa-f0-9]{16}$ ]]; then
    [[ $existing_pub =~ ^[A-Za-z0-9_-]{20,}$ ]] || existing_pub=$(derive_reality_public_key "$existing_priv")
    if [[ $existing_pub =~ ^[A-Za-z0-9_-]{20,}$ ]]; then
      priv=$existing_priv
      pub=$existing_pub
      short_id=$existing_short
      log "复用已有 REALITY 密钥和 ShortId。"
    fi
  fi

  if [[ -z ${priv:-} || -z ${pub:-} || -z ${short_id:-} ]]; then
    short_id=$(openssl rand -hex 8)
    keys=$(generate_reality_keys)
    priv=$(printf '%s\n' "$keys" | sed -n '1p')
    pub=$(printf '%s\n' "$keys" | sed -n '2p')
  fi
  title "Xray VLESS + REALITY"
  log "写入 Xray 配置..."
  cat >"$XRAY_CONFIG" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [{
    "tag": "vless-reality", "listen": "0.0.0.0", "port": ${XRAY_PORT},
    "protocol": "vless",
    "settings": { "clients": [{ "id": "${XRAY_UUID}", "flow": "xtls-rprx-vision", "email": "user" }], "decryption": "none" },
    "streamSettings": {
      "network": "tcp", "security": "reality",
      "realitySettings": { "show": false, "dest": "${XRAY_TARGET}", "xver": 0, "serverNames": ["${XRAY_SNI}"], "privateKey": "${priv}", "shortIds": ["${short_id}"] }
    },
    "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] }
  }],
  "outbounds": [ { "protocol": "freedom", "tag": "direct" }, { "protocol": "blackhole", "tag": "block" } ]
}
EOF
  # 收紧权限：Debian/Ubuntu 的 nobody 用户主组是 nogroup，不能假设组名等于用户名
  local xu xg xd
  xu=$(systemctl show -p User --value xray 2>/dev/null || true)
  [[ -z $xu || $xu == - ]] && xu=nobody
  getent passwd "$xu" >/dev/null || xu=nobody
  xg=$(id -gn "$xu")
  xd=$(dirname "$XRAY_CONFIG")
  install -d -o root -g "$xg" -m 750 "$xd"
  chown "root:$xg" "$XRAY_CONFIG"; chmod 640 "$XRAY_CONFIG"
  xray run -test -config "$XRAY_CONFIG"
  systemctl enable xray >/dev/null 2>&1
  restart_and_verify_service xray "Xray"
  open_firewall_port "$XRAY_PORT" tcp
  link="vless://${XRAY_UUID}@${ip}:${XRAY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${XRAY_SNI}&fp=chrome&pbk=${pub}&sid=${short_id}&type=tcp&headerType=none#Xray-Reality-${ip}"
  cat >"$XRAY_INFO_FILE" <<EOF
Xray VLESS + REALITY

地址:       ${ip}
端口:       ${XRAY_PORT}
UUID:       ${XRAY_UUID}
Flow:       xtls-rprx-vision
SNI:        ${XRAY_SNI}
目标:       ${XRAY_TARGET}
PublicKey:  ${pub}
ShortId:    ${short_id}

分享链接:
${link}
EOF
  chmod 600 "$XRAY_INFO_FILE"
  ok "Xray Reality 已安装并启动。"
  printf '\n'; cat "$XRAY_INFO_FILE"
}

install_hysteria_core() {
  log "安装或更新 Hysteria2..."
  HYSTERIA_USER=$HY2_SERVICE_USER run_remote_script "$HY2_INSTALLER_URL" "$HY2_INSTALLER_SHA256"
  command -v hysteria >/dev/null || fail "Hysteria2 安装失败。"
  getent passwd "$HY2_SERVICE_USER" >/dev/null || fail "服务用户创建失败。"
}
write_hy2_self_signed_cert() {
  local d=$1 cn=$2
  install -d -m 700 "$d"
  openssl req -x509 -newkey rsa:2048 -sha256 -keyout "$d/server.key" -out "$d/server.crt" \
    -days 3650 -nodes -subj "/CN=$cn" -addext "subjectAltName=DNS:$cn" >/dev/null 2>&1
  chmod 600 "$d/server.key"; chmod 644 "$d/server.crt"
}
configure_hy2_cert_permissions() {
  local d=$1
  getent passwd "$HY2_SERVICE_USER" >/dev/null || fail "用户不存在：$HY2_SERVICE_USER"
  install -d -o root -g "$HY2_SERVICE_USER" -m 750 "$d"
  chown root:"$HY2_SERVICE_USER" "$d/server.key" "$d/server.crt"
  chmod 640 "$d/server.key"; chmod 644 "$d/server.crt"
}
check_hy2_config() {
  local tp tc to rc=0
  command -v runuser >/dev/null || fail "缺少 runuser。"
  tp=$(random_free_port udp)
  tc=$(mktemp /tmp/${APP_NAME}.hy2.XXXXXX.yaml)
  to=$(mktemp /tmp/${APP_NAME}.hy2.XXXXXX.log)
  sed -E "s|^listen:.*$|listen: 127.0.0.1:${tp}|" "$HY2_CONFIG" >"$tc"
  chown root:"$HY2_SERVICE_USER" "$tc"; chmod 640 "$tc"
  runuser -u "$HY2_SERVICE_USER" -- timeout --signal=TERM 3s hysteria --disable-update-check --log-level error server -c "$tc" >"$to" 2>&1 || rc=$?
  if ((rc != 124)); then cat "$to" >&2; rm -f "$tc" "$to"; fail "配置预检失败（$rc）。"; fi
  rm -f "$tc" "$to"
}
hy2_certificate_sha256() {
  local f=$1 fp
  fp=$(openssl x509 -in "$f" -noout -fingerprint -sha256 | awk -F= 'NF>1{print $2;exit}' | tr -d ':' | tr '[:upper:]' '[:lower:]')
  [[ $fp =~ ^[0-9a-f]{64}$ ]] || fail "无法读取证书指纹。"
  printf %s "$fp"
}

existing_hy2_port() {
  [[ -r "$HY2_CONFIG" ]] || return 0
  sed -nE 's/^[[:space:]]*listen:[[:space:]]*:[[:space:]]*([0-9]+).*/\\1/p' "$HY2_CONFIG" | head -n1
}

existing_hy2_password() {
  [[ -r "$HY2_CONFIG" ]] || return 0
  sed -nE 's/^[[:space:]]*password:[[:space:]]*([^[:space:]]+).*/\\1/p' "$HY2_CONFIG" | head -n1
}

existing_hy2_domain() {
  [[ -r "$HY2_INFO_FILE" ]] || return 0
  sed -nE 's/^SNI:[[:space:]]*([^[:space:]]+).*/\\1/p' "$HY2_INFO_FILE" | head -n1
}

valid_hy2_certificate() {
  [[ -r "$HY2_CERT_DIR/server.crt" && -r "$HY2_CERT_DIR/server.key" ]] &&
    openssl x509 -in "$HY2_CERT_DIR/server.crt" -checkend 86400 -noout >/dev/null 2>&1
}

install_hysteria2() {
  parse_hy2_args "$@"
  require_root; require_systemd; detect_os; install_base_deps; ensure_dirs
  local existing_port existing_domain existing_password reuse_cert=0
  existing_port=$(existing_hy2_port)
  existing_domain=$(existing_hy2_domain)
  existing_password=$(existing_hy2_password)

  if [[ $HY2_PORT_SET_BY_USER == 1 ]]; then
    validate_port "$HY2_PORT"
  elif [[ $existing_port =~ ^[0-9]+$ ]] && ((existing_port >= 1 && existing_port <= 65535)); then
    HY2_PORT=$existing_port
    log "复用已有 Hysteria2 端口：$HY2_PORT"
  else
    HY2_PORT=$(random_free_port udp)
    log "未指定端口，已随机：$HY2_PORT"
  fi
  ensure_port_available "$HY2_PORT" hysteria-server "Hysteria2" udp

  if [[ -z $HY2_DOMAIN && $existing_domain =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\\.)+[A-Za-z]{2,}$ ]]; then
    HY2_DOMAIN=$existing_domain
    if valid_hy2_certificate; then
      reuse_cert=1
      log "复用已有 Hysteria2 域名和证书：$HY2_DOMAIN"
    else
      log "复用已有 Hysteria2 域名；证书即将过期或不完整，将重新生成。"
    fi
  elif [[ -z $HY2_DOMAIN ]]; then
    HY2_DOMAIN=$(random_big_tech_domain)
    log "默认大厂域名：$HY2_DOMAIN"
  else
    validate_domain "$HY2_DOMAIN"
    log "自定义域名：$HY2_DOMAIN"
  fi
  validate_domain "$HY2_DOMAIN"
  validate_hy2_masquerade "$HY2_MASQUERADE"

  if [[ -z $HY2_PASSWORD && $existing_password =~ ^[-A-Za-z0-9._~]{1,128}$ ]]; then
    HY2_PASSWORD=$existing_password
    log "复用已有 Hysteria2 密码。"
  fi
  [[ -n $HY2_PASSWORD ]] || HY2_PASSWORD=$(random_password)
  validate_hy2_password "$HY2_PASSWORD"
  ip=$(resolve_public_ip)
  backup_managed_state hysteria2 "$HY2_CONFIG" "$HY2_CERT_DIR" "$HY2_INFO_FILE"
  install_hysteria_core
  local sni link cert_sha
  sni=$HY2_DOMAIN
  install -d -o root -g "$HY2_SERVICE_USER" -m 750 /etc/hysteria
  title "Hysteria2"
  if ((reuse_cert)); then
    log "复用已有自签证书。"
  else
    log "生成新的自签证书..."
    write_hy2_self_signed_cert "$HY2_CERT_DIR" "$HY2_DOMAIN"
  fi
  configure_hy2_cert_permissions "$HY2_CERT_DIR"
  cert_sha=$(hy2_certificate_sha256 "$HY2_CERT_DIR/server.crt")
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
  chown root:"$HY2_SERVICE_USER" "$HY2_CONFIG"; chmod 640 "$HY2_CONFIG"
  check_hy2_config
  systemctl enable hysteria-server.service >/dev/null 2>&1
  restart_and_verify_service hysteria-server "Hysteria2"
  open_firewall_port "$HY2_PORT" udp
  link="hysteria2://${HY2_PASSWORD}@${ip}:${HY2_PORT}/?sni=${sni}&insecure=1&pinSHA256=${cert_sha}#Hysteria2-${ip}"
  cat >"$HY2_INFO_FILE" <<EOF
Hysteria2

地址:       ${ip}
端口:       ${HY2_PORT}
密码:       ${HY2_PASSWORD}
SNI:        ${sni}
TLS 模式:   自签证书 + SHA256 指纹校验
证书指纹:   ${cert_sha}
协议:       UDP

分享链接:
${link}
EOF
  chmod 600 "$HY2_INFO_FILE"
  ok "Hysteria2 已安装并启动。"
  printf '\n'; cat "$HY2_INFO_FILE"
}

show_info() {
  title "已保存的节点信息"
  local f found=0
  for f in "$XRAY_INFO_FILE" "$HY2_INFO_FILE"; do
    if [[ -f $f ]]; then found=1; cat "$f"; printf '\n'; fi
  done
  [[ $found == 1 ]] || log "暂无已保存节点信息。"
  title "服务状态"; print_service_statuses
  show_journal xray "Xray"; show_journal hysteria-server "Hysteria2"
}
cleanup_info_dir() { rmdir -- "$CONFIG_DIR" 2>/dev/null || true; }
remove_hy2_managed_files() {
  rm -f "$HY2_INFO_FILE"; rm -rf -- "$HY2_CERT_DIR"
  if [[ -f $HY2_CONFIG ]] && grep -qF "cert: ${HY2_CERT_DIR}/server.crt" "$HY2_CONFIG" && grep -qF "key: ${HY2_CERT_DIR}/server.key" "$HY2_CONFIG"; then
    rm -f "$HY2_CONFIG"
  fi
  rmdir -- /etc/hysteria 2>/dev/null || true
  cleanup_info_dir
}
uninstall_xray() {
  require_root; log "卸载 Xray..."
  run_remote_script "$XRAY_INSTALLER_URL" "$XRAY_INSTALLER_SHA256" remove --purge && {
    rm -f "$XRAY_INFO_FILE"; cleanup_info_dir; ok "Xray 已卸载。"
  } || fail "Xray 卸载失败。"
}
uninstall_hy2() {
  require_root; log "卸载 Hysteria2..."
  run_remote_script "$HY2_INSTALLER_URL" "$HY2_INSTALLER_SHA256" --remove && {
    remove_hy2_managed_files; ok "Hysteria2 已卸载。"
  } || fail "Hysteria2 卸载失败。"
}
uninstall_v2_shortcut() {
  require_root
  if [[ -e $V2_COMMAND_PATH || -L $V2_COMMAND_PATH || -e $V2_SCRIPT_PATH ]]; then
    rm -f "$V2_COMMAND_PATH" "$V2_SCRIPT_PATH"; rmdir "$V2_INSTALL_DIR" 2>/dev/null || true
    ok "已删除 v2 快捷命令。"
  else warn "v2 快捷命令不存在。"; fi
}
install_v2_local_copy() {
  local src=$1 rs rt
  install -d -m 755 "$V2_INSTALL_DIR"
  rs=$(readlink -f "$src"); rt=$(readlink -f "$V2_SCRIPT_PATH" 2>/dev/null || true)
  if [[ $rs != "$rt" ]]; then install -m 755 "$src" "$V2_SCRIPT_PATH"; else chmod 755 "$V2_SCRIPT_PATH"; fi
  ln -sfn "$V2_SCRIPT_PATH" "$V2_COMMAND_PATH"
}
download_v2_local_copy() {
  local tf rc=0
  is_valid_sha256 "$V2_SCRIPT_SHA256" || { warn "在线安装 v2 需要 V2_SCRIPT_SHA256。"; return 1; }
  tf=$(mktemp /tmp/${APP_NAME}.v2.XXXXXX.sh)
  if ! curl_download "$V2_SCRIPT_URL" "$tf" || ! sha256_matches "$tf" "$V2_SCRIPT_SHA256"; then rm -f "$tf"; return 1; fi
  install_v2_local_copy "$tf" || rc=$?; rm -f "$tf"; return $rc
}
install_v2_shortcut_files() {
  local source_path=""
  if [[ "${BASH_SOURCE[0]:-}" != bash && "${BASH_SOURCE[0]:-}" != -bash ]]; then
    source_path=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || true)
  fi

  if [[ -n $source_path && -f $source_path && $source_path != /dev/fd/* ]] &&
    grep -q '^APP_NAME="vps-proxy"$' "$source_path"; then
    install_v2_local_copy "$source_path"
  else
    log "在线执行模式，下载并校验 v2 快照..."
    download_v2_local_copy
  fi
}
install_v2_shortcut() {
  require_root
  install_v2_shortcut_files || fail "安装 v2 失败。"
  ok "已安装快捷命令：v2"; log "现在可直接输入：v2"
}

prompt_default() { local l=$1 d=$2 v; read -r -p "$l [$d]: " v; printf %s "${v:-$d}"; }
select_reality_target() {
  local c
  printf '\n请选择 REALITY 伪装目标:\n  1  www.cloudflare.com（推荐）\n  2  www.yahoo.com\n  3  www.microsoft.com\n  4  自定义\n'
  read -r -p "请选择 [1]: " c
  case ${c:-1} in
    1) XRAY_SNI=www.cloudflare.com; XRAY_TARGET=www.cloudflare.com:443 ;;
    2) XRAY_SNI=www.yahoo.com; XRAY_TARGET=www.yahoo.com:443 ;;
    3) XRAY_SNI=www.microsoft.com; XRAY_TARGET=www.microsoft.com:443 ;;
    4) XRAY_SNI=$(prompt_default '自定义 SNI' "$XRAY_SNI"); XRAY_TARGET=$(prompt_default '自定义 target host:port' "${XRAY_SNI}:443") ;;
    *) warn "无效，使用默认 Cloudflare。"; XRAY_SNI=www.cloudflare.com; XRAY_TARGET=www.cloudflare.com:443 ;;
  esac
}
menu_install_xray() {
  XRAY_PORT=$(prompt_default 'Xray TCP 端口' "$XRAY_PORT")
  select_reality_target
  install_xray_reality --port "$XRAY_PORT" --sni "$XRAY_SNI" --target "$XRAY_TARGET"
}
menu_install_hy2() {
  read -r -p "Hysteria2 UDP 端口（留空随机）: " HY2_PORT
  read -r -p "证书/SNI 域名（留空随机大厂域名）: " HY2_DOMAIN
  local -a a=()
  [[ -n $HY2_PORT ]] && a+=(--port "$HY2_PORT")
  [[ -n $HY2_DOMAIN ]] && a+=(--domain "$HY2_DOMAIN")
  install_hysteria2 "${a[@]}"
}
main_menu() {
  clear 2>/dev/null || true
  printf '\n%sVPS 代理控制面板%s\n' "$C_BOLD" "$C_RESET"
  printf '%sXray Reality · Hysteria2 · 输入 v2 进入此菜单%s\n' "$C_DIM" "$C_RESET"
  hr
  printf '  %s1%s  安装 Xray VLESS + REALITY\n' "$C_GREEN" "$C_RESET"
  printf '  %s2%s  安装 Hysteria2\n' "$C_GREEN" "$C_RESET"
  printf '  %s3%s  查看节点信息与服务状态\n' "$C_CYAN" "$C_RESET"
  printf '  %s4%s  卸载 Xray\n' "$C_YELLOW" "$C_RESET"
  printf '  %s5%s  卸载 Hysteria2\n' "$C_YELLOW" "$C_RESET"
  printf '  %s0%s  退出\n' "$C_DIM" "$C_RESET"
  hr; print_service_statuses; hr
  warn "安装前请确认安全组已放行对应端口。"
  local c; read -r -p "请选择: " c
  case $c in
    1) menu_install_xray ;; 2) menu_install_hy2 ;; 3) show_info ;;
    4) uninstall_xray ;; 5) uninstall_hy2 ;; 0) exit 0 ;;
    *) fail "无效选项：$c" ;;
  esac
}
ensure_v2_shortcut_auto() {
  [[ $EUID -ne 0 ]] && { warn "非 root，跳过自动安装 v2。"; return; }
  install_v2_shortcut_files || { warn "自动安装 v2 失败，现有服务不受影响。"; return; }
  ok "已自动安装快捷命令：v2"
}
main() {
  local cmd=${1:-menu}; [[ $# -gt 0 ]] && shift
  case $cmd in
    menu|v2) ensure_v2_shortcut_auto; main_menu ;;
    xray) install_xray_reality "$@"; ensure_v2_shortcut_auto ;;
    hy2|hysteria2) install_hysteria2 "$@"; ensure_v2_shortcut_auto ;;
    install-shortcut|shortcut) install_v2_shortcut ;;
    show) show_info ;;
    uninstall-xray) uninstall_xray ;;
    uninstall-hy2|uninstall-hysteria2) uninstall_hy2 ;;
    uninstall-v2|uninstall-shortcut|uninstall-v2-shortcut) uninstall_v2_shortcut ;;
    --help|-h|help) usage ;;
    *) fail "未知命令：$cmd" ;;
  esac
}
[[ ${BASH_SOURCE[0]} == "$0" ]] && main "$@"
