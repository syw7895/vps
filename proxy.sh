#!/usr/bin/env bash
# VPS 代理一键脚本：Xray REALITY / Hysteria2 / VLESS-WS-TLS(可走 CF)
set -Eeuo pipefail

APP_NAME="vps-proxy"
VERSION="1.3.2"
CONFIG_DIR="/root/proxy-info"
BACKUP_DIR="${CONFIG_DIR}/backups"
BACKUP_KEEP="${BACKUP_KEEP:-15}"
LAST_BACKUP=""
REALITY_STATE="${CONFIG_DIR}/reality.conf"
CDN_STATE="${CONFIG_DIR}/cdn.conf"
HY2_STATE="${CONFIG_DIR}/hy2.conf"
XRAY_INFO="${CONFIG_DIR}/xray-reality.txt"
CDN_INFO="${CONFIG_DIR}/xray-cdn.txt"
HY2_INFO="${CONFIG_DIR}/hysteria2.txt"
XRAY_CONFIG="/usr/local/etc/xray/config.json"
HY2_CONFIG="/etc/hysteria/config.yaml"
HY2_CERT_DIR="/etc/hysteria/certs"
HY2_DROPIN="/etc/systemd/system/hysteria-server.service.d/10-vps-proxy-user.conf"
HY2_USER="hysteria"
V2_DIR="/usr/local/lib/vps-proxy"
V2_SCRIPT="${V2_DIR}/proxy.sh"
V2_BIN="/usr/local/bin/v2"
PUBLIC_IP=""
DEPS_INSTALLED=0

# 固定提交 + SHA256（可用环境变量覆盖）。勿使用未校验的浮动 main。
XRAY_INSTALLER_URL="${XRAY_INSTALLER_URL:-https://raw.githubusercontent.com/XTLS/Xray-install/e741a4f56d368afbb9e5be3361b40c4552d3710d/install-release.sh}"
XRAY_INSTALLER_SHA256="${XRAY_INSTALLER_SHA256:-7f70c95f6b418da8b4f4883343d602964915e28748993870fd554383afdbe555}"
HY2_INSTALLER_URL="${HY2_INSTALLER_URL:-https://raw.githubusercontent.com/apernet/hysteria/d1cd1503d35d3cd3fbe176be634b805d560ec7e7/scripts/install_server.sh}"
HY2_INSTALLER_SHA256="${HY2_INSTALLER_SHA256:-e6b9023dcc0142f155546548b9d7a75ce288704d6dead0c2010d61663b90e217}"
ACME_INSTALLER_URL="${ACME_INSTALLER_URL:-https://raw.githubusercontent.com/acmesh-official/acme.sh/3.1.0/acme.sh}"
ACME_INSTALLER_SHA256="${ACME_INSTALLER_SHA256:-5afa747a59a2dad83ac4775c6d67bb3152cef495bf5f2d59bd0b1bf51c2ffb92}"
# 在线执行时使用独立、不可变的 v2.sh 快照。
V2_SCRIPT_URL="${V2_SCRIPT_URL:-https://raw.githubusercontent.com/syw7895/vps/d0e30b398be59913c807d9c1d451af05eb3361cc/v2.sh}"
V2_SCRIPT_SHA256="${V2_SCRIPT_SHA256:-0a313a834aaad064c1adee2cf2449defa2660837785b80043a3240b3d5ea6d62}"

SNI_PRESETS=(
  www.cloudflare.com
  www.microsoft.com
  www.apple.com
  www.amazon.com
  www.yahoo.com
)

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
# UI 宽 48；窄终端降级无边框
UI_W=48
UI_RULE="────────────────────────────────────────────────"
UI_BOX=1
ui_init() {
  local cols=${COLUMNS:-}
  if [[ -z $cols && -t 1 ]]; then cols=$(tput cols 2>/dev/null || echo 80); fi
  cols=${cols:-80}
  UI_BOX=1
  (( cols < UI_W + 6 )) && UI_BOX=0
}
hr() {
  if (( UI_BOX )); then
    printf '  %s├%s┤%s\n' "$D" "$UI_RULE" "$R"
  else
    printf '  %s%s%s\n' "$D" "$UI_RULE" "$R"
  fi
}
ui_box_top() { (( UI_BOX )) && printf '  %s╭%s╮%s\n' "$D" "$UI_RULE" "$R" || true; }
ui_box_bot() { (( UI_BOX )) && printf '  %s╰%s╯%s\n' "$D" "$UI_RULE" "$R" || true; }
ui_box_row() {
  if (( UI_BOX )); then printf '  %s│%s %s\n' "$D" "$R" "$1"
  else printf '  %s\n' "$1"; fi
}
ui_box_section() {
  if (( UI_BOX )); then
    printf '  %s├%s %s %s┤%s\n' "$D" "──" "$1" "──────────────────────────────" "$R"
  else
    printf '  %s── %s ──%s\n' "$D" "$1" "$R"
  fi
}
ui_hint() { printf '  %s提示%s：%s\n' "$D" "$R" "$1"; }
pause() { read -r -p $'\n  按回车返回…' _; }

usage() {
  cat <<EOF
用法 (v${VERSION}):
  bash proxy.sh                 进入菜单
  bash proxy.sh xray [参数]     安装/更新 REALITY（默认复用已有节点参数）
  bash proxy.sh hy2  [参数]     安装/更新 Hysteria2（默认复用）
  bash proxy.sh cdn  [参数]     安装/更新 VLESS+WS+TLS
  bash proxy.sh show
  bash proxy.sh install-shortcut|shortcut
  bash proxy.sh uninstall-xray | uninstall-hy2 | uninstall-cdn
  bash proxy.sh uninstall-v2|uninstall-shortcut

公共:
  --public-ip IPv4     分享链接用的公网 IP

REALITY:  --port --sni --target --uuid
Hysteria2: --port --password --domain --masquerade
CDN:      --domain --port --path --uuid --email

环境变量可覆盖安装器 pin（见 README）。
EOF
}

# ---------- 校验 ----------
require_root() { [[ $EUID -eq 0 ]] || fail "请使用 root 运行"; }
require_systemd() { command -v systemctl >/dev/null || fail "需要 systemd"; }
require_arg() { [[ -n ${2:-} && $2 != --* ]] || fail "$1 需要参数值"; }

is_valid_sha256() { [[ $1 =~ ^[A-Fa-f0-9]{64}$ ]]; }
is_safe_token() { [[ $1 =~ ^[A-Za-z0-9._:/@%+=~-]+$ ]]; }

validate_port() {
  [[ $1 =~ ^[0-9]+$ ]] || fail "端口无效: $1"
  ((1 <= 10#$1 && 10#$1 <= 65535)) || fail "端口范围 1-65535: $1"
}

validate_domain() {
  [[ $1 =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,}$ ]] || fail "域名无效: $1"
}

validate_uuid() {
  [[ $1 =~ ^[A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[1-5][A-Fa-f0-9]{3}-[89ABab][A-Fa-f0-9]{3}-[A-Fa-f0-9]{12}$ ]] \
    || fail "UUID 无效: $1"
}

is_ipv4() {
  local ip=$1 x; local -a o
  [[ $ip =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  IFS=. read -r -a o <<<"$ip"
  for x in "${o[@]}"; do ((10#$x <= 255)) || return 1; done
  return 0
}

validate_target() {
  local t=$1 h p
  [[ $t =~ ^[^:[:space:]]+:[0-9]+$ ]] || fail "target 格式应为 host:port"
  h=${t%:*}; p=${t##*:}
  if [[ $h =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,}$ ]] || is_ipv4 "$h"; then
    :
  else
    fail "target 主机无效: $h"
  fi
  validate_port "$p"
}

validate_cdn_path() {
  [[ $1 =~ ^/[A-Za-z0-9._~/-]{1,128}$ ]] || fail "path 仅允许 / 与字母数字 ._-~，长度 1-128"
  [[ $1 != *..* ]] || fail "path 不能包含 .."
}

validate_hy2_password() {
  [[ $1 =~ ^[-A-Za-z0-9._~]{8,128}$ ]] || fail "密码仅允许字母数字 -._~，长度 8-128"
}

validate_masquerade() {
  local p='^https?://[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{1,5})?(/[-A-Za-z0-9._~:/?@!$&()*+,;=%]*)?$'
  [[ $1 =~ $p ]] || fail "伪装 URL 格式错误"
}

# 安全写 KEY=value（仅允许安全字符，再 source）
write_kv_file() {
  local file=$1; shift
  local line k v
  umask 077
  : >"$file"
  for line in "$@"; do
    k=${line%%=*}
    v=${line#*=}
    [[ $k =~ ^[A-Z][A-Z0-9_]*$ ]] || fail "非法状态键: $k"
    is_safe_token "$v" || fail "状态值含非法字符 ($k)，已拒绝写入"
    printf '%s=%s\n' "$k" "$v" >>"$file"
  done
  chmod 600 "$file"
}

state_get() {
  local file=$1 key=$2
  [[ -f $file ]] || return 0
  grep -E "^${key}=" "$file" 2>/dev/null | head -n1 | cut -d= -f2- || true
}

load_state_safe() {
  local file=$1 line k v
  [[ -f $file ]] || return 0
  while IFS= read -r line || [[ -n $line ]]; do
    [[ -z $line || $line == \#* ]] && continue
    [[ $line == *=* ]] || continue
    k=${line%%=*}; v=${line#*=}
    [[ $k =~ ^[A-Z][A-Z0-9_]*$ ]] || continue
    is_safe_token "$v" || continue
    printf -v "$k" '%s' "$v"
  done <"$file"
}

# ---------- 环境 / 下载校验 ----------
detect_os() {
  [[ -r /etc/os-release ]] || fail "无法读取 /etc/os-release"
  # shellcheck source=/dev/null
  . /etc/os-release
  [[ ${ID:-} =~ ^(debian|ubuntu)$ ]] || fail "仅支持 Debian / Ubuntu"
  log "系统: ${PRETTY_NAME:-$ID}"
}

install_deps() {
  ((DEPS_INSTALLED)) && return 0
  log "安装依赖..."
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    curl ca-certificates openssl coreutils iproute2 >/dev/null
  DEPS_INSTALLED=1
}

ensure_dirs() {
  install -d -m 700 "$CONFIG_DIR" "$BACKUP_DIR"
}

prepare_env() {
  require_root
  require_systemd
  detect_os
  install_deps
  ensure_dirs
}

# 成功备份后只保留最近 BACKUP_KEEP 份（默认 15）
prune_backups() {
  local keep=${BACKUP_KEEP:-15} i
  local -a files=()
  [[ $keep =~ ^[0-9]+$ ]] && ((keep >= 1)) || keep=15
  [[ -d $BACKUP_DIR ]] || return 0
  mapfile -t files < <(ls -1t "$BACKUP_DIR"/*.tar.gz 2>/dev/null || true)
  for ((i = keep; i < ${#files[@]}; i++)); do
    rm -f -- "${files[i]}"
  done
}

hint_restore() {
  local unit=${1:-} name=${2:-服务}
  warn "${name} 启动失败。配置可能已写入；可用最近备份手动恢复。"
  if [[ -n ${LAST_BACKUP:-} && -f $LAST_BACKUP ]]; then
    warn "最近备份: ${LAST_BACKUP}"
    warn "恢复示例（确认内容后再执行）:"
    warn "  tar -tzf ${LAST_BACKUP}"
    warn "  tar -C / -xzf ${LAST_BACKUP}"
  else
    warn "备份目录: ${BACKUP_DIR}"
    warn "  ls -lt ${BACKUP_DIR}"
  fi
  if [[ -n $unit ]]; then
    warn "  systemctl restart ${unit}"
    warn "  journalctl -u ${unit} -n 40 --no-pager"
  fi
}

backup_paths() {
  local label=$1 stamp archive
  shift
  local -a existing=()
  local p
  for p in "$@"; do
    [[ -e $p || -L $p ]] && existing+=("$p")
  done
  ((${#existing[@]})) || return 0
  stamp=$(date -u +%Y%m%dT%H%M%SZ)-$RANDOM
  archive="${BACKUP_DIR}/${label}-${stamp}.tar.gz"
  if ! (umask 077; tar -C / -czf "$archive" "${existing[@]#/}" 2>/dev/null); then
    rm -f "$archive"
    fail "备份失败，已停止覆盖: $label"
  fi
  chmod 600 "$archive" || fail "无法收紧备份权限: $archive"
  LAST_BACKUP=$archive
  prune_backups
  ok "已备份: $archive"
}

curl_download() {
  curl -fsSL --retry 3 --connect-timeout 10 --max-time 180 -o "$2" "$1" && [[ -s $2 ]]
}

sha256_file() { sha256sum "$1" | awk '{print $1}'; }

run_verified_script() {
  local url=$1 expect=$2
  shift 2
  local tf actual
  is_valid_sha256 "$expect" || fail "缺少有效 SHA256，拒绝执行远程脚本: $url"
  tf=$(mktemp /tmp/${APP_NAME}.remote.XXXXXX.sh)
  curl_download "$url" "$tf" || { rm -f "$tf"; fail "下载失败: $url"; }
  actual=$(sha256_file "$tf")
  if [[ ${actual,,} != "${expect,,}" ]]; then
    rm -f "$tf"
    fail "远程脚本哈希不匹配: $url"
  fi
  chmod 700 "$tf"
  local rc=0
  bash "$tf" "$@" || rc=$?
  rm -f "$tf"
  return "$rc"
}

random_uuid() {
  if command -v xray >/dev/null; then xray uuid
  elif [[ -r /proc/sys/kernel/random/uuid ]]; then cat /proc/sys/kernel/random/uuid
  else openssl rand -hex 16 | sed 's/\(........\)\(....\)\(....\)\(....\)\(............\)/\1-\2-\3-\4-\5/'
  fi
}
random_password() { openssl rand -hex 16; }
random_path() { printf '/%s' "$(openssl rand -hex 8)"; }

# ---------- 端口 / IP ----------
listener_uses_port() {
  local port=$1 proto=$2
  case $proto in
    tcp) ss -H -ltn 2>/dev/null | grep -qE ":${port}[[:space:]]" ;;
    udp) ss -H -lun 2>/dev/null | grep -qE ":${port}[[:space:]]" ;;
    *) return 1 ;;
  esac
}

port_forwarded() {
  local port=$1 proto=$2
  if command -v docker >/dev/null 2>&1; then
    docker ps --format '{{.Ports}}' 2>/dev/null | grep -qE ":${port}->[^,]*/${proto}" && return 0
  fi
  if command -v podman >/dev/null 2>&1; then
    podman ps --format '{{.Ports}}' 2>/dev/null | grep -qE ":${port}->[^,]*/${proto}" && return 0
  fi
  return 1
}

service_owns_port() {
  local unit=$1 port=$2
  systemctl is-active --quiet "$unit" 2>/dev/null || return 1
  case $unit in
    xray)
      [[ -r $XRAY_CONFIG ]] && grep -qE "\"port\"[[:space:]]*:[[:space:]]*${port}([[:space:]]*,|[[:space:]]*})" "$XRAY_CONFIG"
      ;;
    hysteria-server)
      [[ -r $HY2_CONFIG ]] && grep -qE "^[[:space:]]*listen:[[:space:]]*:${port}[[:space:]]*(#.*)?$" "$HY2_CONFIG"
      ;;
    *) return 1 ;;
  esac
}

ensure_port_available() {
  local port=$1 proto=$2 unit=$3 label=$4
  local own_state=${5:-} own_key=${6:-} other_state=${7:-} other_key=${8:-}
  local own_port="" other_port=""

  if [[ -n $other_state && -n $other_key ]]; then
    other_port=$(state_get "$other_state" "$other_key")
    [[ $other_port == "$port" ]] && fail "端口 ${port}/${proto} 已被另一代理组件使用"
  fi
  port_forwarded "$port" "$proto" && fail "端口 ${port}/${proto} 疑似被 Docker/Podman 转发占用"
  listener_uses_port "$port" "$proto" || return 0

  [[ -n $own_state && -n $own_key ]] && own_port=$(state_get "$own_state" "$own_key")
  if [[ $own_port == "$port" ]] && systemctl is-active --quiet "$unit" 2>/dev/null; then
    warn "$label 正在使用 ${port}/${proto}，允许原位更新"
    return 0
  fi
  if [[ $unit != xray ]] && service_owns_port "$unit" "$port"; then
    warn "$label 正在使用 ${port}/${proto}，允许原位更新"
    return 0
  fi
  fail "端口 ${port}/${proto} 已被其他程序监听，请换端口或先释放"
}

random_free_port() {
  local proto=$1 p i
  for ((i = 0; i < 128; i++)); do
    p=$(shuf -i 10000-60000 -n1)
    listener_uses_port "$p" "$proto" && continue
    port_forwarded "$p" "$proto" && continue
    printf %s "$p"
    return
  done
  fail "找不到空闲 ${proto} 端口，请 --port 指定"
}

resolve_public_ip() {
  local ip ep
  if [[ -n $PUBLIC_IP ]]; then
    is_ipv4 "$PUBLIC_IP" || fail "--public-ip 必须是有效 IPv4: $PUBLIC_IP"
    printf %s "$PUBLIC_IP"
    return
  fi
  for ep in https://api.ipify.org https://ipv4.icanhazip.com https://ifconfig.me/ip; do
    ip=$(curl -4fsS --connect-timeout 5 --max-time 10 "$ep" 2>/dev/null | tr -d '[:space:]' || true)
    if is_ipv4 "$ip"; then
      printf %s "$ip"
      return
    fi
  done
  fail "无法获取公网 IPv4，请使用 --public-ip"
}

open_port() {
  local port=$1 proto=$2
  if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q 'Status: active'; then
    ufw allow "${port}/${proto}" >/dev/null 2>&1 ||
      fail "UFW 放行失败: ${port}/${proto}"
    ok "UFW 已放行 ${port}/${proto}"
  else
    warn "请自行放行 ${port}/${proto}（本机防火墙 + 云安全组）"
  fi
}

# ---------- 服务 ----------
svc_state() {
  local unit=$1 bin=$2
  if systemctl is-active --quiet "$unit" 2>/dev/null; then echo running
  elif command -v "$bin" >/dev/null 2>&1; then echo stopped
  else echo missing
  fi
}

component_line() {
  local name=$1 state_file=$2 unit=$3 bin=$4 port_key=$5
  local st port=""
  if [[ ! -f $state_file ]]; then
    printf '  %s- %-10s 未安装%s\n' "$D" "$name" "$R"
    return
  fi
  port=$(state_get "$state_file" "$port_key")
  st=$(svc_state "$unit" "$bin")
  case $st in
    running) printf '  %s● %-10s 运行中%s' "$GRN" "$name" "$R" ;;
    stopped) printf '  %s○ %-10s 已停止%s' "$YEL" "$name" "$R" ;;
    *)       printf '  %s○ %-10s 异常%s' "$YEL" "$name" "$R" ;;
  esac
  [[ -n $port ]] && printf '  %s:%s%s' "$D" "$port" "$R"
  printf '\n'
}

print_component_statuses() {
  component_line "REALITY" "$REALITY_STATE" xray xray REALITY_PORT
  component_line "CDN/WS" "$CDN_STATE" xray xray CDN_PORT
  component_line "Hysteria2" "$HY2_STATE" hysteria-server hysteria HY2_PORT
}

restart_svc() {
  local unit=$1 name=$2
  systemctl enable "$unit" >/dev/null 2>&1 || true
  if ! systemctl restart "$unit"; then
    hint_restore "$unit" "$name"
    fail "$name 启动失败: journalctl -u $unit -n 30 --no-pager"
  fi
  local i
  for ((i = 1; i <= 8; i++)); do
    sleep 1
    systemctl is-active --quiet "$unit" && { ok "$name 运行中"; return; }
  done
  hint_restore "$unit" "$name"
  fail "$name 未保持运行: journalctl -u $unit -n 40 --no-pager"
}

save_info() {
  local file=$1; shift
  umask 077
  printf '%s\n' "$@" >"$file"
  chmod 600 "$file"
}

print_block() {
  printf '\n%s%s%s\n' "$B$CYN" "$1" "$R"
  hr
  cat "$2"
  printf '\n'
}

# ---------- Xray / 证书 ----------
install_xray_core() {
  if command -v xray >/dev/null; then
    log "Xray 已安装: $(xray version 2>/dev/null | head -n1 || echo ok)"
    return
  fi
  log "安装 Xray（校验远程安装脚本）..."
  run_verified_script "$XRAY_INSTALLER_URL" "$XRAY_INSTALLER_SHA256" install
  command -v xray >/dev/null || fail "Xray 安装失败"
}

xray_run_user() {
  local xu
  xu=$(systemctl show -p User --value xray 2>/dev/null || true)
  [[ -z $xu || $xu == - ]] && xu=nobody
  getent passwd "$xu" >/dev/null || xu=nobody
  printf %s "$xu"
}
xray_run_group() { id -gn "$(xray_run_user)" 2>/dev/null || echo nogroup; }
xray_cert_dir() { printf '%s/certs/%s' "$(dirname "$XRAY_CONFIG")" "$1"; }

fix_cert_permissions() {
  local certdir=$1 cert=$2 key=$3 xg
  xg=$(xray_run_group)
  install -d -o root -g "$xg" -m 750 "$(dirname "$certdir")"
  install -d -o root -g "$xg" -m 750 "$certdir"
  [[ -f $cert ]] && chown "root:$xg" "$cert" && chmod 644 "$cert"
  [[ -f $key ]] && chown "root:$xg" "$key" && chmod 640 "$key"
}

harden_xray_config() {
  local config=${1:-$XRAY_CONFIG} xg
  xg=$(xray_run_group)
  install -d -o root -g "$xg" -m 750 "$(dirname "$XRAY_CONFIG")"
  chown "root:$xg" "$config"; chmod 640 "$config"
  [[ -z ${CDN_CERT:-} || ! -f ${CDN_CERT:-} ]] ||
    fix_cert_permissions "$(dirname "$CDN_CERT")" "$CDN_CERT" "${CDN_KEY:-}"
  xray run -test -config "$config" >/dev/null
}

migrate_cdn_certs_if_needed() {
  [[ -f $CDN_STATE ]] || return 0
  [[ -n ${CDN_DOMAIN:-} && -n ${CDN_CERT:-} && -f ${CDN_CERT:-} ]] || return 0
  case $CDN_CERT in
    /root/*|"${CONFIG_DIR}"/*) ;;
    *)
      fix_cert_permissions "$(dirname "$CDN_CERT")" "$CDN_CERT" "${CDN_KEY:-}"
      return 0
      ;;
  esac
  local newdir cert key
  newdir=$(xray_cert_dir "$CDN_DOMAIN")
  install -d -m 750 "$newdir"
  cert="$newdir/fullchain.pem"; key="$newdir/privkey.pem"
  cp -a "$CDN_CERT" "$cert"
  [[ -f ${CDN_KEY:-} ]] && cp -a "$CDN_KEY" "$key"
  fix_cert_permissions "$newdir" "$cert" "$key"
  CDN_CERT=$cert; CDN_KEY=$key
  write_kv_file "$CDN_STATE" \
    "CDN_PORT=${CDN_PORT}" "CDN_UUID=${CDN_UUID}" "CDN_DOMAIN=${CDN_DOMAIN}" \
    "CDN_PATH=${CDN_PATH}" "CDN_CERT=${CDN_CERT}" "CDN_KEY=${CDN_KEY}"
  log "CDN 证书已迁移: $newdir"
}

build_xray_config() {
  local reality="" cdn="" inbounds tmp
  load_state_safe "$REALITY_STATE"
  load_state_safe "$CDN_STATE"
  migrate_cdn_certs_if_needed

  if [[ -f $REALITY_STATE ]]; then
    reality=$(cat <<EOF
    {
      "tag": "vless-reality", "listen": "0.0.0.0", "port": ${REALITY_PORT},
      "protocol": "vless",
      "settings": { "clients": [{ "id": "${REALITY_UUID}", "flow": "xtls-rprx-vision", "email": "reality" }], "decryption": "none" },
      "streamSettings": {
        "network": "tcp", "security": "reality",
        "realitySettings": { "show": false, "dest": "${REALITY_TARGET}", "xver": 0, "serverNames": ["${REALITY_SNI}"], "privateKey": "${REALITY_PRIV}", "shortIds": ["${REALITY_SHORT}"] }
      },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] }
    }
EOF
)
  fi
  if [[ -f $CDN_STATE ]]; then
    cdn=$(cat <<EOF
    {
      "tag": "vless-ws-tls", "listen": "0.0.0.0", "port": ${CDN_PORT},
      "protocol": "vless",
      "settings": { "clients": [{ "id": "${CDN_UUID}", "email": "cdn" }], "decryption": "none" },
      "streamSettings": {
        "network": "ws", "security": "tls",
        "tlsSettings": { "certificates": [{ "certificateFile": "${CDN_CERT}", "keyFile": "${CDN_KEY}" }] },
        "wsSettings": { "path": "${CDN_PATH}" }
      },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] }
    }
EOF
)
  fi
  [[ -n $reality || -n $cdn ]] || return 0
  [[ -z $reality || -z $cdn ]] && inbounds="${reality}${cdn}" || inbounds="${reality},${cdn}"

  install -d -m 755 "$(dirname "$XRAY_CONFIG")"
  tmp=$(mktemp "$(dirname "$XRAY_CONFIG")/.config.XXXXXX.json")
  cat >"$tmp" <<EOF
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
  harden_xray_config "$tmp" || { rm -f "$tmp"; fail "Xray 配置预检失败"; }
  mv -f "$tmp" "$XRAY_CONFIG"
}

# ---------- REALITY ----------
parse_reality_args() {
  REALITY_PORT="${REALITY_PORT:-}"
  REALITY_SNI="${REALITY_SNI:-}"
  REALITY_TARGET="${REALITY_TARGET:-}"
  REALITY_UUID="${REALITY_UUID:-}"
  while [[ $# -gt 0 ]]; do
    case $1 in
      --port) require_arg "$1" "${2:-}"; REALITY_PORT=$2; shift 2 ;;
      --sni) require_arg "$1" "${2:-}"; REALITY_SNI=$2; shift 2 ;;
      --target) require_arg "$1" "${2:-}"; REALITY_TARGET=$2; shift 2 ;;
      --uuid) require_arg "$1" "${2:-}"; REALITY_UUID=$2; shift 2 ;;
      --public-ip) require_arg "$1" "${2:-}"; PUBLIC_IP=$2; shift 2 ;;
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
  prepare_env

  local priv pub short ip link reused=0
  local arg_port=$REALITY_PORT arg_sni=$REALITY_SNI arg_target=$REALITY_TARGET arg_uuid=$REALITY_UUID

  # 默认完整复用已有节点（端口/SNI/target/密钥），仅 CLI 显式参数覆盖
  if [[ -f $REALITY_STATE ]]; then
    load_state_safe "$REALITY_STATE"
    if [[ -n ${REALITY_PRIV:-} && -n ${REALITY_PUB:-} && -n ${REALITY_SHORT:-} ]]; then
      priv=$REALITY_PRIV; pub=$REALITY_PUB; short=$REALITY_SHORT
      reused=1
      # load_state 已填充 REALITY_*；用 CLI 显式参数覆盖
      [[ -n $arg_port ]] && REALITY_PORT=$arg_port
      [[ -n $arg_sni ]] && REALITY_SNI=$arg_sni
      [[ -n $arg_target ]] && REALITY_TARGET=$arg_target
      [[ -n $arg_uuid ]] && REALITY_UUID=$arg_uuid
      log "复用已有 REALITY 配置（密钥/参数）；CLI 指定项优先"
    fi
  fi

  REALITY_PORT=${REALITY_PORT:-443}
  REALITY_SNI=${REALITY_SNI:-www.cloudflare.com}
  REALITY_TARGET=${REALITY_TARGET:-${REALITY_SNI}:443}

  validate_port "$REALITY_PORT"
  validate_domain "$REALITY_SNI"
  validate_target "$REALITY_TARGET"
  [[ -z ${REALITY_UUID:-} ]] || validate_uuid "$REALITY_UUID"

  ensure_port_available "$REALITY_PORT" tcp xray "Xray/REALITY" \
    "$REALITY_STATE" REALITY_PORT "$CDN_STATE" CDN_PORT
  install_xray_core

  backup_paths reality "$REALITY_STATE" "$XRAY_INFO" "$XRAY_CONFIG"

  if ((reused == 0)); then
    local keys
    keys=$(generate_reality_keys)
    priv=$(printf '%s\n' "$keys" | sed -n '1p')
    pub=$(printf '%s\n' "$keys" | sed -n '2p')
    short=$(openssl rand -hex 8)
  fi
  [[ -n ${REALITY_UUID:-} ]] || REALITY_UUID=$(random_uuid)
  ip=$(resolve_public_ip)

  write_kv_file "$REALITY_STATE" \
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
  save_info "$XRAY_INFO" \
    "Xray VLESS + REALITY（直连）" "" \
    "地址:      ${ip}" "端口:      ${REALITY_PORT}" "UUID:      ${REALITY_UUID}" \
    "Flow:      xtls-rprx-vision" "SNI:       ${REALITY_SNI}" "目标:      ${REALITY_TARGET}" \
    "PublicKey: ${pub}" "ShortId:   ${short}" "" "分享链接:" "${link}"
  if ((reused)); then ok "REALITY 更新完成（已复用密钥）"; else ok "REALITY 安装完成"; fi
  print_block "节点信息" "$XRAY_INFO"
}

# ---------- CDN ----------
parse_cdn_args() {
  CDN_PORT="${CDN_PORT:-}"; CDN_DOMAIN="${CDN_DOMAIN:-}"; CDN_PATH="${CDN_PATH:-}"
  CDN_UUID="${CDN_UUID:-}"; CDN_EMAIL="${CDN_EMAIL:-}"
  while [[ $# -gt 0 ]]; do
    case $1 in
      --port) require_arg "$1" "${2:-}"; CDN_PORT=$2; shift 2 ;;
      --domain) require_arg "$1" "${2:-}"; CDN_DOMAIN=$2; shift 2 ;;
      --path) require_arg "$1" "${2:-}"; CDN_PATH=$2; shift 2 ;;
      --uuid) require_arg "$1" "${2:-}"; CDN_UUID=$2; shift 2 ;;
      --email) require_arg "$1" "${2:-}"; CDN_EMAIL=$2; shift 2 ;;
      --public-ip) require_arg "$1" "${2:-}"; PUBLIC_IP=$2; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) fail "未知 CDN 参数: $1" ;;
    esac
  done
}

install_acme_sh() {
  local acme="/root/.acme.sh/acme.sh"
  [[ -x $acme ]] && return 0
  log "安装 acme.sh..."
  local tf
  tf=$(mktemp /tmp/${APP_NAME}.acme.XXXXXX.sh)
  curl_download "$ACME_INSTALLER_URL" "$tf" || { rm -f "$tf"; fail "下载 acme.sh 失败"; }
  is_valid_sha256 "$ACME_INSTALLER_SHA256" ||
    { rm -f "$tf"; fail "缺少有效的 acme.sh SHA256"; }
  local actual
  actual=$(sha256_file "$tf")
  [[ ${actual,,} == "${ACME_INSTALLER_SHA256,,}" ]] ||
    { rm -f "$tf"; fail "acme.sh 哈希不匹配"; }
  chmod 700 "$tf"
  bash "$tf" --install --home /root/.acme.sh --accountemail "${1:-admin@localhost}" >/dev/null
  rm -f "$tf"
  [[ -x $acme ]] || fail "acme.sh 安装失败"
}

issue_cert() {
  local domain=$1 email=$2 certdir olddir
  certdir=$(xray_cert_dir "$domain")
  olddir="${CONFIG_DIR}/certs/${domain}"
  install -d -m 755 "$(dirname "$certdir")"
  install -d -m 750 "$certdir"

  if [[ ! -f $certdir/fullchain.pem && -f $olddir/fullchain.pem ]]; then
    cp -a "$olddir/fullchain.pem" "$certdir/fullchain.pem"
    [[ -f $olddir/privkey.pem ]] && cp -a "$olddir/privkey.pem" "$certdir/privkey.pem"
    log "已迁移旧证书: $olddir -> $certdir"
  fi

  if [[ -f $certdir/fullchain.pem && -f $certdir/privkey.pem ]]; then
    if openssl x509 -in "$certdir/fullchain.pem" -checkend 604800 -noout 2>/dev/null; then
      log "使用已有证书: $certdir"
      CDN_CERT="$certdir/fullchain.pem"; CDN_KEY="$certdir/privkey.pem"
      fix_cert_permissions "$certdir" "$CDN_CERT" "$CDN_KEY"
      return
    fi
  fi

  # 证书申请前先放行 80（活动 UFW 否则会失败）
  open_port 80 tcp
  install_acme_sh "$email"
  local acme="/root/.acme.sh/acme.sh"

  local restarted_xray=0
  if systemctl is-active --quiet xray 2>/dev/null && listener_uses_port 80 tcp; then
    if service_owns_port xray 80; then
      systemctl stop xray || true
      restarted_xray=1
    else
      fail "80/tcp 被其他程序占用，无法申请证书"
    fi
  fi

  log "申请 Let's Encrypt 证书..."
  "$acme" --set-default-ca --server letsencrypt >/dev/null
  if ! "$acme" --issue -d "$domain" --standalone --keylength ec-256 --force; then
    ((restarted_xray)) && systemctl start xray || true
    fail "证书申请失败（域名解析/80 端口/防火墙）"
  fi
  "$acme" --install-cert -d "$domain" --ecc \
    --fullchain-file "$certdir/fullchain.pem" \
    --key-file "$certdir/privkey.pem" \
    --reloadcmd "systemctl restart xray 2>/dev/null || true"
  CDN_CERT="$certdir/fullchain.pem"; CDN_KEY="$certdir/privkey.pem"
  fix_cert_permissions "$certdir" "$CDN_CERT" "$CDN_KEY"
  ((restarted_xray)) && systemctl start xray 2>/dev/null || true
  ok "证书已就绪: $certdir"
}

install_cdn() {
  parse_cdn_args "$@"
  [[ -n ${CDN_DOMAIN:-} ]] || fail "CDN 需要 --domain"
  prepare_env

  local arg_port=$CDN_PORT arg_path=$CDN_PATH arg_uuid=$CDN_UUID
  local want_domain=$CDN_DOMAIN
  local old_domain old_port old_path old_uuid
  old_domain=$(state_get "$CDN_STATE" CDN_DOMAIN)
  old_port=$(state_get "$CDN_STATE" CDN_PORT)
  old_path=$(state_get "$CDN_STATE" CDN_PATH)
  old_uuid=$(state_get "$CDN_STATE" CDN_UUID)
  if [[ -n $old_domain && $old_domain == "$want_domain" ]]; then
    [[ -n $arg_port ]] || CDN_PORT=$old_port
    [[ -n $arg_path ]] || CDN_PATH=$old_path
    [[ -n $arg_uuid ]] || CDN_UUID=$old_uuid
    log "复用已有 CDN 节点参数（同域名）"
  fi

  CDN_PORT=${CDN_PORT:-8443}
  validate_domain "$CDN_DOMAIN"
  validate_port "$CDN_PORT"
  [[ -z ${CDN_UUID:-} ]] || validate_uuid "$CDN_UUID"
  [[ -n ${CDN_UUID:-} ]] || CDN_UUID=$(random_uuid)
  [[ -n ${CDN_PATH:-} ]] || CDN_PATH=$(random_path)
  [[ $CDN_PATH == /* ]] || CDN_PATH="/$CDN_PATH"
  validate_cdn_path "$CDN_PATH"
  [[ -n ${CDN_EMAIL:-} ]] || CDN_EMAIL="admin@${CDN_DOMAIN}"
  is_safe_token "$CDN_EMAIL" || fail "邮箱含非法字符"

  ensure_port_available "$CDN_PORT" tcp xray "Xray/CDN" \
    "$CDN_STATE" CDN_PORT "$REALITY_STATE" REALITY_PORT
  install_xray_core
  backup_paths cdn "$CDN_STATE" "$CDN_INFO" "$XRAY_CONFIG" "$(xray_cert_dir "$CDN_DOMAIN")"

  issue_cert "$CDN_DOMAIN" "$CDN_EMAIL"

  write_kv_file "$CDN_STATE" \
    "CDN_PORT=${CDN_PORT}" "CDN_UUID=${CDN_UUID}" "CDN_DOMAIN=${CDN_DOMAIN}" \
    "CDN_PATH=${CDN_PATH}" "CDN_CERT=${CDN_CERT}" "CDN_KEY=${CDN_KEY}"

  build_xray_config
  restart_svc xray "Xray"
  open_port "$CDN_PORT" tcp

  local link path_enc
  path_enc=$(printf %s "$CDN_PATH" | sed 's|/|%2F|g')
  link="vless://${CDN_UUID}@${CDN_DOMAIN}:${CDN_PORT}?encryption=none&security=tls&type=ws&host=${CDN_DOMAIN}&sni=${CDN_DOMAIN}&path=${path_enc}#CDN-${CDN_DOMAIN}"
  save_info "$CDN_INFO" \
    "Xray VLESS + WS + TLS（可走 Cloudflare）" "" \
    "域名:   ${CDN_DOMAIN}" "端口:   ${CDN_PORT}" "UUID:   ${CDN_UUID}" \
    "传输:   WebSocket" "TLS:    开启" "Host:   ${CDN_DOMAIN}" "SNI:    ${CDN_DOMAIN}" "Path:   ${CDN_PATH}" \
    "" "分享链接:" "${link}" "" "说明: 地址可改为 CF 优选 IP，SNI/Host 保持域名。"
  ok "CDN 节点安装完成"
  print_block "节点信息" "$CDN_INFO"
}

# ---------- Hysteria2 ----------
parse_hy2_args() {
  HY2_PORT="${HY2_PORT:-}"; HY2_PASSWORD="${HY2_PASSWORD:-}"
  HY2_DOMAIN="${HY2_DOMAIN:-}"; HY2_MASQUERADE="${HY2_MASQUERADE:-}"
  while [[ $# -gt 0 ]]; do
    case $1 in
      --port) require_arg "$1" "${2:-}"; HY2_PORT=$2; shift 2 ;;
      --password) require_arg "$1" "${2:-}"; HY2_PASSWORD=$2; shift 2 ;;
      --domain) require_arg "$1" "${2:-}"; HY2_DOMAIN=$2; shift 2 ;;
      --masquerade) require_arg "$1" "${2:-}"; HY2_MASQUERADE=$2; shift 2 ;;
      --public-ip) require_arg "$1" "${2:-}"; PUBLIC_IP=$2; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) fail "未知 Hysteria2 参数: $1" ;;
    esac
  done
}

ensure_hy2_account() {
  getent group "$HY2_USER" >/dev/null 2>&1 || groupadd --system "$HY2_USER"
  getent passwd "$HY2_USER" >/dev/null 2>&1 ||
    useradd --system --gid "$HY2_USER" --no-create-home --shell /usr/sbin/nologin "$HY2_USER"
}

install_hy2_core() {
  if ! command -v hysteria >/dev/null; then
    log "安装 Hysteria2（校验远程安装脚本）..."
    HYSTERIA_USER=$HY2_USER run_verified_script "$HY2_INSTALLER_URL" "$HY2_INSTALLER_SHA256"
  else
    log "Hysteria2 已安装"
  fi
  command -v hysteria >/dev/null || fail "Hysteria2 安装失败"
}

configure_hy2_service() {
  install -d -m 755 "$(dirname "$HY2_DROPIN")"
  # 降权为 hysteria 用户；UDP/443 等特权端口需 CAP_NET_BIND_SERVICE
  cat >"$HY2_DROPIN" <<EOF
[Service]
User=${HY2_USER}
Group=${HY2_USER}
WorkingDirectory=/etc/hysteria
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
EOF
  chmod 644 "$HY2_DROPIN"
  systemctl daemon-reload
}

hy2_cert_valid() {
  local domain=$1 cert="$HY2_CERT_DIR/server.crt" key="$HY2_CERT_DIR/server.key"
  local cert_pub key_pub
  [[ -r $cert && -r $key ]] || return 1
  openssl x509 -in "$cert" -checkend 86400 -checkhost "$domain" -noout >/dev/null 2>&1 ||
    return 1
  cert_pub=$(openssl x509 -in "$cert" -pubkey -noout 2>/dev/null |
    openssl pkey -pubin -outform DER 2>/dev/null | sha256sum) || return 1
  key_pub=$(openssl pkey -in "$key" -pubout -outform DER 2>/dev/null | sha256sum) ||
    return 1
  [[ ${cert_pub%% *} == "${key_pub%% *}" ]]
}

install_hy2() {
  parse_hy2_args "$@"
  prepare_env

  local arg_port=$HY2_PORT arg_pass=$HY2_PASSWORD arg_dom=$HY2_DOMAIN arg_masq=$HY2_MASQUERADE
  local old_port="" old_pass="" old_dom="" old_masq="" reuse_cert=0
  old_port=$(state_get "$HY2_STATE" HY2_PORT)
  old_dom=$(state_get "$HY2_STATE" HY2_DOMAIN)
  old_masq=$(state_get "$HY2_STATE" HY2_MASQUERADE)
  if [[ -r $HY2_CONFIG ]]; then
    old_pass=$(awk '/^[[:space:]]*password:/{print $2; exit}' "$HY2_CONFIG" | tr -d '"' || true)
    [[ -n $old_port ]] ||
      old_port=$(sed -nE 's/^[[:space:]]*listen:[[:space:]]*:([0-9]+).*/\1/p' "$HY2_CONFIG" | head -n1)
    [[ -n $old_masq ]] ||
      old_masq=$(awk '/^[[:space:]]*url:/{print $2; exit}' "$HY2_CONFIG" || true)
  fi
  if [[ -z $old_dom && -r $HY2_INFO ]]; then
    old_dom=$(sed -nE 's/^SNI:[[:space:]]*([^[:space:]]+).*/\1/p' "$HY2_INFO" | head -n1)
  fi

  HY2_PORT=${arg_port:-$old_port}
  HY2_PASSWORD=${arg_pass:-$old_pass}
  HY2_DOMAIN=${arg_dom:-$old_dom}
  HY2_MASQUERADE=${arg_masq:-$old_masq}
  HY2_MASQUERADE=${HY2_MASQUERADE:-https://www.bing.com}

  if [[ -n $HY2_PORT ]]; then
    validate_port "$HY2_PORT"
    if ((10#$HY2_PORT < 1024)); then
      log "Hysteria2 使用特权端口 ${HY2_PORT}/udp（systemd drop-in 授予 CAP_NET_BIND_SERVICE）"
    fi
    ensure_port_available "$HY2_PORT" udp hysteria-server "Hysteria2" "$HY2_STATE" HY2_PORT
  else
    HY2_PORT=$(random_free_port udp)
    log "随机 UDP 端口: $HY2_PORT"
  fi
  [[ -n $HY2_PASSWORD ]] || HY2_PASSWORD=$(random_password)
  validate_hy2_password "$HY2_PASSWORD"
  [[ -n $HY2_DOMAIN ]] || HY2_DOMAIN=${SNI_PRESETS[RANDOM % ${#SNI_PRESETS[@]}]}
  validate_domain "$HY2_DOMAIN"
  validate_masquerade "$HY2_MASQUERADE"

  if hy2_cert_valid "$HY2_DOMAIN"; then
    reuse_cert=1
    log "复用已有 Hysteria2 参数与证书"
  fi

  ensure_hy2_account
  install_hy2_core
  backup_paths hy2 "$HY2_STATE" "$HY2_INFO" "$HY2_CONFIG" "$HY2_CERT_DIR" "$HY2_DROPIN"

  install -d -o root -g "$HY2_USER" -m 750 "$HY2_CERT_DIR" /etc/hysteria
  if ((reuse_cert == 0)); then
    openssl req -x509 -newkey rsa:2048 -sha256 -nodes       -keyout "$HY2_CERT_DIR/server.key" -out "$HY2_CERT_DIR/server.crt"       -days 3650 -subj "/CN=${HY2_DOMAIN}" -addext "subjectAltName=DNS:${HY2_DOMAIN}" >/dev/null 2>&1
  fi
  chown "root:${HY2_USER}" "$HY2_CERT_DIR/server.key" "$HY2_CERT_DIR/server.crt"
  chmod 640 "$HY2_CERT_DIR/server.key"; chmod 644 "$HY2_CERT_DIR/server.crt"

  local cert_sha ip link config_tmp
  cert_sha=$(openssl x509 -in "$HY2_CERT_DIR/server.crt" -noout -fingerprint -sha256 |
    awk -F= 'NF>1{print $2}' | tr -d ':' | tr '[:upper:]' '[:lower:]')
  is_valid_sha256 "$cert_sha" || fail "无法读取证书指纹"
  ip=$(resolve_public_ip)

  config_tmp=$(mktemp /etc/hysteria/.config.XXXXXX)
  cat >"$config_tmp" <<EOF
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
  chown "root:${HY2_USER}" "$config_tmp"; chmod 640 "$config_tmp"
  mv -f "$config_tmp" "$HY2_CONFIG"
  write_kv_file "$HY2_STATE"     "HY2_PORT=${HY2_PORT}" "HY2_DOMAIN=${HY2_DOMAIN}" "HY2_MASQUERADE=${HY2_MASQUERADE}"

  configure_hy2_service
  restart_svc hysteria-server "Hysteria2"
  open_port "$HY2_PORT" udp

  link="hysteria2://${HY2_PASSWORD}@${ip}:${HY2_PORT}/?sni=${HY2_DOMAIN}&insecure=1&pinSHA256=${cert_sha}#HY2-${ip}"
  save_info "$HY2_INFO"     "Hysteria2" ""     "地址:     ${ip}" "端口:     ${HY2_PORT}" "密码:     ${HY2_PASSWORD}"     "SNI:      ${HY2_DOMAIN}" "证书指纹: ${cert_sha}" "协议:     UDP" "" "分享链接:" "${link}"
  ok "Hysteria2 安装完成"
  print_block "节点信息" "$HY2_INFO"
}

# ---------- 展示 / 卸载 ----------
show_info() {
  local found=0
  [[ -f $XRAY_INFO ]] && { print_block "REALITY" "$XRAY_INFO"; found=1; }
  [[ -f $CDN_INFO ]] && { print_block "CDN / WS+TLS" "$CDN_INFO"; found=1; }
  [[ -f $HY2_INFO ]] && { print_block "Hysteria2" "$HY2_INFO"; found=1; }
  ((found)) || { printf '\n'; log "暂无已保存节点"; }
  printf '\n%s服务状态%s\n' "$B" "$R"; hr
  print_component_statuses
  printf '\n'
}

uninstall_xray_core() {
  if command -v xray >/dev/null; then
    run_verified_script "$XRAY_INSTALLER_URL" "$XRAY_INSTALLER_SHA256" remove --purge ||
      fail "Xray 卸载器执行失败"
  fi
  rm -f "$XRAY_CONFIG"
}

uninstall_reality() {
  require_root
  backup_paths reality-rm "$REALITY_STATE" "$XRAY_INFO" "$XRAY_CONFIG"
  rm -f "$REALITY_STATE" "$XRAY_INFO"
  if [[ -f $CDN_STATE ]]; then
    build_xray_config
    restart_svc xray "Xray"
    ok "已移除 REALITY，保留 CDN"
  else
    uninstall_xray_core
    ok "已卸载 Xray / REALITY"
  fi
}

uninstall_cdn() {
  require_root
  local dom certdir="" acme="/root/.acme.sh/acme.sh"
  dom=$(state_get "$CDN_STATE" CDN_DOMAIN)
  if [[ -n $dom ]]; then
    validate_domain "$dom"
    certdir=$(xray_cert_dir "$dom")
  fi
  backup_paths cdn-rm "$CDN_STATE" "$CDN_INFO" "$XRAY_CONFIG" "$certdir"
  [[ -n $dom && -x $acme ]] &&
    "$acme" --remove -d "$dom" --ecc >/dev/null 2>&1 || true
  rm -f "$CDN_STATE" "$CDN_INFO"
  [[ -n $certdir ]] && rm -rf "$certdir"
  if [[ -f $REALITY_STATE ]]; then
    build_xray_config
    restart_svc xray "Xray"
    ok "已移除 CDN，保留 REALITY"
  else
    uninstall_xray_core
    ok "已卸载 CDN"
  fi
}

uninstall_hy2() {
  require_root
  backup_paths hy2-rm "$HY2_STATE" "$HY2_INFO" "$HY2_CONFIG" "$HY2_CERT_DIR"
  if command -v hysteria >/dev/null || systemctl cat hysteria-server >/dev/null 2>&1; then
    run_verified_script "$HY2_INSTALLER_URL" "$HY2_INSTALLER_SHA256" --remove ||
      fail "Hysteria2 卸载器执行失败"
  fi
  systemctl disable hysteria-server 2>/dev/null || true
  rm -f "$HY2_INFO" "$HY2_CONFIG" "$HY2_STATE" "$HY2_DROPIN"
  rm -rf "$HY2_CERT_DIR"
  rmdir "$(dirname "$HY2_DROPIN")" /etc/hysteria 2>/dev/null || true
  userdel -r "$HY2_USER" 2>/dev/null || true
  ok "已卸载 Hysteria2"
}

uninstall_v2() {
  require_root
  if [[ -e $V2_BIN || -e $V2_SCRIPT ]]; then
    rm -f "$V2_BIN" "$V2_SCRIPT"; rmdir "$V2_DIR" 2>/dev/null || true
    ok "已删除 v2 快捷命令"
  else
    warn "v2 未安装"
  fi
}

# ---------- v2 ----------
is_vps_proxy_blob() {
  local f=$1
  [[ -s $f ]] || return 1
  (( $(wc -c <"$f") > 2000 )) || return 1
  head -n1 "$f" | grep -q '^#!/usr/bin/env bash' &&
    grep -q '^APP_NAME="vps-proxy"$' "$f" &&
    grep -q 'install_reality' "$f"
}

install_v2_from_file() {
  local src=$1 rs rt tmp
  is_vps_proxy_blob "$src" || fail "脚本内容校验失败，拒绝落盘 v2"
  install -d -m 755 "$V2_DIR"
  rs=$(readlink -f "$src" 2>/dev/null || true)
  rt=$(readlink -f "$V2_SCRIPT" 2>/dev/null || true)
  if [[ -n $rs && $rs == "$rt" ]]; then
    chmod 755 "$V2_SCRIPT"
  else
    tmp=$(mktemp "${V2_DIR}/.proxy.XXXXXX")
    cp -f "$src" "$tmp"
    is_vps_proxy_blob "$tmp" || { rm -f "$tmp"; fail "落盘校验失败"; }
    chmod 755 "$tmp"
    mv -f "$tmp" "$V2_SCRIPT"
  fi
  ln -sfn "$V2_SCRIPT" "$V2_BIN" 2>/dev/null ||
    install -m 755 "$V2_SCRIPT" "$V2_BIN"
  ok "已安装快捷命令: v2"
}

download_v2_snapshot() {
  local tf actual
  [[ $V2_SCRIPT_URL == https://* ]] || fail "在线安装 v2 缺少固定快照 URL"
  is_valid_sha256 "$V2_SCRIPT_SHA256" || fail "在线安装 v2 缺少有效 SHA256"
  tf=$(mktemp /tmp/${APP_NAME}.v2.XXXXXX.sh)
  curl_download "$V2_SCRIPT_URL" "$tf" ||
    { rm -f "$tf"; fail "下载 v2 快照失败"; }
  actual=$(sha256_file "$tf")
  [[ ${actual,,} == "${V2_SCRIPT_SHA256,,}" ]] ||
    { rm -f "$tf"; fail "v2 快照哈希不匹配"; }
  install_v2_from_file "$tf"
  rm -f "$tf"
}

install_v2_files() {
  local src=${BASH_SOURCE[0]:-}
  if [[ -n $src && -f $src && $src != /dev/fd/* && $src != /proc/self/fd/* ]]; then
    install_v2_from_file "$src"
  else
    download_v2_snapshot
  fi
}

install_v2() { require_root; install_v2_files; log "之后可直接输入: v2"; }
auto_v2() {
  [[ $EUID -eq 0 ]] || return 0
  install_v2_files 2>/dev/null || warn "自动安装 v2 跳过（不影响代理服务）"
}

# ---------- 菜单 ----------
prompt() {
  local label=$1 default=$2 val
  if [[ -n $default ]]; then
    read -r -p "  ${label} [${default}]: " val
    printf %s "${val:-$default}"
  else
    read -r -p "  ${label}: " val
    printf %s "$val"
  fi
}

# 若已有配置：默认 0=保持；否则 0=随机
pick_sni() {
  local title=$1 default_sni=${2:-} i n c
  n=${#SNI_PRESETS[@]}
  printf '\n  %s%s%s\n' "$B" "$title" "$R"
  hr
  if [[ -n $default_sni ]]; then
    printf '  %s0%s  保持当前: %s（默认）\n' "$CYN" "$R" "$default_sni"
  else
    printf '  %s0%s  随机（默认）\n' "$CYN" "$R"
  fi
  for ((i = 0; i < n; i++)); do
    printf '  %s%d%s  %s\n' "$GRN" "$((i + 1))" "$R" "${SNI_PRESETS[i]}"
  done
  hr
  read -r -p "  请选择 [0]: " c
  c=${c:-0}
  if [[ $c == 0 ]]; then
    if [[ -n $default_sni ]]; then _SNI_CHOSEN=$default_sni
    else _SNI_CHOSEN=${SNI_PRESETS[RANDOM % n]}; fi
  elif [[ $c =~ ^[1-5]$ ]] && ((c <= n)); then
    _SNI_CHOSEN=${SNI_PRESETS[c - 1]}
  else
    warn "无效选项"; _SNI_CHOSEN=${default_sni:-${SNI_PRESETS[RANDOM % n]}}
  fi
  ok "已选 SNI: ${_SNI_CHOSEN}"
}

print_banner() {
  clear 2>/dev/null || true
  ui_init
  printf '\n'
  ui_box_top
  ui_box_row "${B}${CYN}代理管理${R}  ${D}v${VERSION}${R}"
  ui_box_row "${D}REALITY · HY2 · CF/WS${R}"
  ui_box_bot
  print_component_statuses
  printf '\n'
}

menu_install() {
  while true; do
    print_banner
    ui_box_top
    ui_box_row "${B}安装代理${R}"
    ui_box_section "协议"
    ui_box_row " 1  ▸ Xray VLESS + REALITY"
    ui_box_row " 2  ▸ Hysteria2"
    ui_box_row " 3  ▸ VLESS + WS + TLS（CF）"
    ui_box_section "操作"
    ui_box_row " 0  返回"
    ui_box_bot
    ui_hint "选择后按回车确认"
    local c; read -r -p "  请选择 › " c
    case $c in
      1)
        local port sni cur_port cur_sni
        cur_port=$(state_get "$REALITY_STATE" REALITY_PORT)
        cur_sni=$(state_get "$REALITY_STATE" REALITY_SNI)
        port=$(prompt "TCP 端口" "${cur_port:-443}")
        pick_sni "REALITY 伪装 / SNI" "$cur_sni"
        sni=$_SNI_CHOSEN
        install_reality --port "$port" --sni "$sni" --target "${sni}:443"
        auto_v2; pause
        ;;
      2)
        local hp cur_port
        cur_port=$(state_get "$HY2_STATE" HY2_PORT)
        hp=$(prompt "UDP 端口（空=保持或随机）" "${cur_port:-}")
        pick_sni "Hysteria2 证书 SNI" "$(state_get "$HY2_STATE" HY2_DOMAIN)"
        local args=(--domain "$_SNI_CHOSEN")
        [[ -n $hp ]] && args+=(--port "$hp")
        install_hy2 "${args[@]}"
        auto_v2; pause
        ;;
      3)
        local domain port path email
        domain=$(prompt "域名（已解析到本机）" "$(state_get "$CDN_STATE" CDN_DOMAIN)")
        [[ -n $domain ]] || { warn "域名不能为空"; sleep 1; continue; }
        port=$(prompt "TLS 端口" "$(state_get "$CDN_STATE" CDN_PORT)")
        port=${port:-8443}
        path=$(prompt "WebSocket path（空=保持或随机）" "$(state_get "$CDN_STATE" CDN_PATH)")
        email=$(prompt "证书邮箱" "admin@${domain}")
        local args=(--domain "$domain" --port "$port" --email "$email")
        [[ -n $path ]] && args+=(--path "$path")
        install_cdn "${args[@]}"
        auto_v2; pause
        ;;
      0) return ;;
      *) warn "无效选项"; sleep 1 ;;
    esac
  done
}

menu_uninstall() {
  while true; do
    print_banner
    ui_box_top
    ui_box_row "${B}${YEL}卸载${R}"
    ui_box_section "组件"
    ui_box_row " 1  ▸ 卸载 REALITY"
    ui_box_row " 2  ▸ 卸载 CDN"
    ui_box_row " 3  ▸ 卸载 Hysteria2"
    ui_box_row " 4  ▸ 卸载 v2"
    ui_box_section "操作"
    ui_box_row " 0  返回"
    ui_box_bot
    ui_hint "卸载不可自动恢复，请确认后再选"
    local c; read -r -p "  请选择 › " c
    case $c in
      1) uninstall_reality; pause ;;
      2) uninstall_cdn; pause ;;
      3) uninstall_hy2; pause ;;
      4) uninstall_v2; pause ;;
      0) return ;;
      *) warn "无效选项"; sleep 1 ;;
    esac
  done
}

main_menu() {
  while true; do
    print_banner
    ui_box_top
    ui_box_row "${B}${CYN}代理管理${R}  ${D}v${VERSION}${R}"
    ui_box_section "管理"
    ui_box_row " 1  ▸ 安装代理          REALITY / HY2 / CDN"
    ui_box_row " 2  ▸ 查看节点 / 状态"
    ui_box_section "系统"
    ui_box_row " 3  ▸ 卸载"
    ui_box_row " 4  ▸ 安装 / 更新 v2"
    ui_box_section "操作"
    ui_box_row " 0  退出"
    ui_box_bot
    ui_hint "选择后按回车确认"
    local c; read -r -p "  请选择 › " c
    case $c in
      1) menu_install ;;
      2) show_info; pause ;;
      3) menu_uninstall ;;
      4) install_v2; pause ;;
      0) printf '\n  %s再见%s\n\n' "$D" "$R"; exit 0 ;;
      *) warn "无效选项"; sleep 1 ;;
    esac
  done
}

elevate_if_needed() {
  [[ $EUID -eq 0 ]] && return 0
  case ${1:-} in -h|--help|help) return 0 ;; esac
  command -v sudo >/dev/null 2>&1 || fail "请使用 root 运行"
  local self=${BASH_SOURCE[0]:-}
  if [[ -n $self && -f $self && $self != /dev/fd/* && $self != /proc/self/fd/* ]]; then
    exec sudo -- bash "$(readlink -f "$self")" "$@"
  fi
  fail "在线非 root 执行请使用: curl -fsSL URL | sudo bash"
}

main() {
  local cmd=${1:-menu}
  [[ $# -gt 0 ]] && shift
  case $cmd in
    menu|v2|"") auto_v2 2>/dev/null || true; main_menu ;;
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
    *) fail "未知命令: $cmd" ;;
  esac
}

if [[ -z ${BASH_SOURCE[0]:-} || ${BASH_SOURCE[0]} == "$0" ]]; then
  elevate_if_needed "$@"
  trap 'fail "脚本第 $LINENO 行失败 (exit $?) "' ERR
  main "$@"
fi
