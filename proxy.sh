#!/usr/bin/env bash
# VPS 代理一键脚本：Xray REALITY / Hysteria2 / VLESS-WS-TLS（直连）
set -Eeuo pipefail

APP_NAME="vps-proxy"
VERSION="1.7.6"
CONFIG_DIR="/root/proxy-info"
REALITY_STATE="${CONFIG_DIR}/reality.conf"
WS_STATE="${CONFIG_DIR}/ws.conf"
HY2_STATE="${CONFIG_DIR}/hy2.conf"
XRAY_INFO="${CONFIG_DIR}/xray-reality.txt"
WS_INFO="${CONFIG_DIR}/xray-ws.txt"
HY2_INFO="${CONFIG_DIR}/hysteria2.txt"
XRAY_CONFIG="${XRAY_CONFIG:-/usr/local/etc/xray/config.json}"
# 运行时由 xray_discover 填充：file|dir|unknown
XRAY_LAYOUT="${XRAY_LAYOUT:-unknown}"
XRAY_CONFIG_FILE="${XRAY_CONFIG_FILE:-}"
XRAY_CONF_DIR="${XRAY_CONF_DIR:-}"
# 本项目管理的 inbound tag / confdir 文件名
MANAGED_TAG_REALITY="vless-reality"
MANAGED_TAG_WS="vless-ws-tls"
MANAGED_FILE_REALITY="50-vps-reality.json"
MANAGED_FILE_WS="51-vps-cdn.json"
WS_IP_CERT_ID="ws-ip"
HY2_CONFIG="/etc/hysteria/config.yaml"
HY2_CERT_DIR="/etc/hysteria/certs"
HY2_DROPIN="/etc/systemd/system/hysteria-server.service.d/10-vps-proxy-user.conf"
HY2_USER="hysteria"
HY2_BIN="${HY2_BIN:-/usr/local/bin/hysteria}"
HY2_UPDATE_STATE="${CONFIG_DIR}/hy2-update.conf"
HY2_UPDATE_SERVICE="/etc/systemd/system/syw-hy2-update.service"
HY2_UPDATE_TIMER="/etc/systemd/system/syw-hy2-update.timer"
HY2_UPDATE_LOCK="/run/lock/syw-hy2-update.lock"
HY2_UPDATE_API="${HY2_UPDATE_API:-https://api.hy2.io/v1/update?cver=installscript&plat=linux&chan=release&side=server}"
HY2_RELEASE_BASE="${HY2_RELEASE_BASE:-https://github.com/HyNetworks/hysteria/releases/download/app}"
XRAY_CORE_BIN="${XRAY_CORE_BIN:-/usr/local/bin/xray}"
XRAY_UPDATE_API="${XRAY_UPDATE_API:-https://api.github.com/repos/XTLS/Xray-core/releases/latest}"
XRAY_RELEASE_BASE="${XRAY_RELEASE_BASE:-https://github.com/XTLS/Xray-core/releases/download}"
XRAY_UPDATE_STATE="${CONFIG_DIR}/xray-update.conf"
XRAY_UPDATE_LOCK="/run/lock/syw-xray-update.lock"
PUBLIC_IP=""
DEPS_INSTALLED=0

# 固定提交 + SHA256（可用环境变量覆盖）。勿使用未校验的浮动 main。
XRAY_INSTALLER_URL="${XRAY_INSTALLER_URL:-https://raw.githubusercontent.com/XTLS/Xray-install/e741a4f56d368afbb9e5be3361b40c4552d3710d/install-release.sh}"
XRAY_INSTALLER_SHA256="${XRAY_INSTALLER_SHA256:-7f70c95f6b418da8b4f4883343d602964915e28748993870fd554383afdbe555}"
HY2_INSTALLER_URL="${HY2_INSTALLER_URL:-https://raw.githubusercontent.com/apernet/hysteria/d1cd1503d35d3cd3fbe176be634b805d560ec7e7/scripts/install_server.sh}"
HY2_INSTALLER_SHA256="${HY2_INSTALLER_SHA256:-e6b9023dcc0142f155546548b9d7a75ce288704d6dead0c2010d61663b90e217}"
ACME_INSTALLER_URL="${ACME_INSTALLER_URL:-https://raw.githubusercontent.com/acmesh-official/acme.sh/3.1.0/acme.sh}"
ACME_INSTALLER_SHA256="${ACME_INSTALLER_SHA256:-5afa747a59a2dad83ac4775c6d67bb3152cef495bf5f2d59bd0b1bf51c2ffb92}"

SNI_PRESETS=(
  www.cloudflare.com
  www.microsoft.com
  www.apple.com
  www.amazon.com
  www.yahoo.com
)

if [[ -t 1 ]]; then
  R=$'\033[0m' B=$'\033[1m' D=$'\033[2m'
  RED=$'\033[31m' GRN=$'\033[32m' YEL=$'\033[33m' CYN=$'\033[36m'
else
  R='' B='' D='' RED='' GRN='' YEL='' CYN=''
fi

log()  { printf '  %s!%s  %s\n' "$D" "$R" "$*"; }
ok()   { printf '  %s●%s  %s\n' "$GRN" "$R" "$*"; }
warn() { printf '  %s!%s  %s\n' "$YEL" "$R" "$*"; }
fail() { printf '  %s×%s  %s\n' "$RED" "$R" "$*" >&2; exit 1; }
# UI（扁平，无边框）
ui_head() { printf '\n  %s%s%s  %s%s%s\n' "$B$CYN" "$1" "$R" "$D" "$2" "$R"; }
ui_status() { printf '  %s\n' "$1"; }
ui_gap() { printf '\n'; }
# $1 序号 $2 文案 $3 可选语义: danger|muted — 序号后带 .
ui_item() {
  local num=$1 text=$2 style=${3:-} nc=$CYN tc=
  case $style in
    danger) nc=$RED; tc=$RED ;;
    muted)  nc=$D; tc=$D ;;
  esac
  printf '  %s%2s.%s  %s%s%s\n' "$nc" "$num" "$R" "$tc" "$text" "$R"
}
ui_prompt() {
  local c max=${1:-3}
  printf '  请选择 [0-%s]: ' "$max" >&2
  read -r c || return 1
  printf '%s' "$c"
}
pause() { read -r -p $'\n  按回车返回…' _; }

usage() {
  cat <<EOF
用法 (v${VERSION}):
  bash proxy.sh                 进入菜单
  bash proxy.sh xray [参数]     安装/更新 REALITY（默认复用已有节点参数）
  bash proxy.sh hy2  [参数]     安装/更新 Hysteria2（默认复用）
  bash proxy.sh update-hy2      立即检查/更新 Hysteria2 核心
  bash proxy.sh update-cores    检查/更新 Xray 与 Hysteria2 核心
  bash proxy.sh ws   [参数]     安装/更新 VLESS+WS+TLS（域名或 IP 直连）
  bash proxy.sh show
  bash proxy.sh show --status-debug   排障：显示内部元数据提示
  bash proxy.sh uninstall-reality | uninstall-xray-core | uninstall-hy2 | uninstall-ws

公共:
  --public-ip IPv4     分享链接用的公网 IP

REALITY:  --port --sni --target --uuid
Hysteria2: --port --password --domain --masquerade
WS+TLS:   [--domain] [--port|--random-port] --path --uuid --email
          有 --domain：Let's Encrypt 证书，用域名连接。
          无 --domain：自签证书，分享链接用公网 IP（已固定证书指纹，客户端需新版支持）。
          更新同一身份（同域名，或同为 IP 直连）且未指定 --port 时保持原端口。
          --random-port 强制换端口。

环境变量可覆盖安装器 pin（见 README）。
EOF
}

# ---------- 校验 ----------
require_root() { [[ $EUID -eq 0 ]] || fail "请使用 root 运行"; }
require_systemd() { command -v systemctl >/dev/null || fail "需要 systemd"; }
require_arg() { [[ -n ${2:-} && $2 != --* ]] || fail "$1 需要参数值"; }

is_valid_sha256() { [[ $1 =~ ^[A-Fa-f0-9]{64}$ ]]; }
# 状态值不允许空白、引号、反斜杠和换行；URL 查询参数中的常见符号可安全保存。
SAFE_TOKEN_RE='^[A-Za-z0-9._:/@%+=~?!$&*(),;~-]+$'
is_safe_token() { [[ $1 =~ $SAFE_TOKEN_RE ]]; }

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

validate_ws_path() {
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

# 安全写 KEY=value（仅允许安全字符，读取时不执行）
write_kv_file() {
  local file=$1; shift
  local line k v tmp

  # 先完整校验，避免写到一半才失败；再使用同目录临时文件原子替换。
  for line in "$@"; do
    k=${line%%=*}
    v=${line#*=}
    [[ $k =~ ^[A-Z][A-Z0-9_]*$ ]] || fail "非法状态键: $k"
    [[ -z $v ]] || is_safe_token "$v" || fail "状态值含非法字符 ($k)，已拒绝写入"
  done

  tmp=$(mktemp "${file}.tmp.XXXXXX") || fail "无法创建状态临时文件: $file"
  if ! (umask 077; for line in "$@"; do printf '%s\n' "$line"; done) >"$tmp"; then
    rm -f -- "$tmp"
    fail "状态写入失败: $file"
  fi
  chmod 600 "$tmp" || { rm -f -- "$tmp"; fail "无法设置状态文件权限: $file"; }
  mv -f -- "$tmp" "$file" || { rm -f -- "$tmp"; fail "无法替换状态文件: $file"; }
}

state_get() {
  local file=$1 key=$2
  [[ -f $file ]] || return 0
  grep -E "^${key}=" "$file" 2>/dev/null | head -n1 | cut -d= -f2- || true
}

# 旧版状态文件为 cdn.conf / xray-cdn.txt，键为 CDN_*。
migrate_legacy_cdn_state() {
  local old_state="${CONFIG_DIR}/cdn.conf" old_info="${CONFIG_DIR}/xray-cdn.txt"
  local tmp line

  if [[ -f $old_state && ! -f $WS_STATE ]]; then
    tmp=$(mktemp "${old_state}.tmp.XXXXXX") || return 0
    while IFS= read -r line || [[ -n $line ]]; do
      case $line in
        CDN_*) printf 'WS_%s\n' "${line#CDN_}" ;;
        *) printf '%s\n' "$line" ;;
      esac
    done <"$old_state" >"$tmp" || { rm -f -- "$tmp"; return 0; }
    chmod 600 "$tmp" || { rm -f -- "$tmp"; return 0; }
    mv -f -- "$tmp" "$WS_STATE" || { rm -f -- "$tmp"; return 0; }
    rm -f -- "$old_state"
  elif [[ -f $old_state ]]; then
    rm -f -- "$old_state"
  fi

  if [[ -f $WS_STATE ]] && grep -qE '^CDN_[A-Z0-9_]+=' "$WS_STATE" 2>/dev/null; then
    tmp=$(mktemp "${WS_STATE}.tmp.XXXXXX") || return 0
    while IFS= read -r line || [[ -n $line ]]; do
      case $line in
        CDN_*) printf 'WS_%s\n' "${line#CDN_}" ;;
        *) printf '%s\n' "$line" ;;
      esac
    done <"$WS_STATE" >"$tmp" || { rm -f -- "$tmp"; return 0; }
    chmod 600 "$tmp" || { rm -f -- "$tmp"; return 0; }
    mv -f -- "$tmp" "$WS_STATE" || { rm -f -- "$tmp"; return 0; }
  fi

  if [[ -f $old_info && ! -f $WS_INFO ]]; then
    mv -f -- "$old_info" "$WS_INFO" || true
  elif [[ -f $old_info ]]; then
    rm -f -- "$old_info"
  fi
}

load_state_safe() {
  local file=$1 line k v
  [[ $file == "$WS_STATE" ]] && migrate_legacy_cdn_state
  [[ -f $file ]] || return 0
  while IFS= read -r line || [[ -n $line ]]; do
    [[ -z $line || $line == \#* ]] && continue
    [[ $line == *=* ]] || continue
    k=${line%%=*}; v=${line#*=}
    [[ $k =~ ^[A-Z][A-Z0-9_]*$ ]] || continue
    [[ -z $v ]] || is_safe_token "$v" || continue
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
  if ((DEPS_INSTALLED)); then
    return 0
  fi
  log "安装依赖..."
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    curl ca-certificates openssl coreutils iproute2 python3 util-linux unzip >/dev/null
  DEPS_INSTALLED=1
}

ensure_dirs() {
  install -d -m 700 "$CONFIG_DIR"
  # 搭节点不再做 tar 备份；清掉旧归档目录
  [[ -e $CONFIG_DIR/backups ]] && rm -rf -- "$CONFIG_DIR/backups"
  migrate_legacy_cdn_state
}

prepare_env() {
  require_root
  require_systemd
  detect_os
  install_deps
  ensure_dirs
}

hint_restore() {
  local unit=${1:-} name=${2:-服务}
  warn "${name} 启动失败。"
  if [[ -n $unit ]]; then
    warn "  systemctl restart ${unit}"
    warn "  journalctl -u ${unit} -n 40 --no-pager"
  fi
}

curl_download() {
  [[ $1 == https://* ]] || return 1
  curl --proto '=https' --proto-redir '=https' -fsSL --retry 3 --connect-timeout 10 --max-time 180 -o "$2" "$1" && [[ -s $2 ]]
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

random_ws_port() {
  random_free_port tcp
}

# 更新同一身份（同域名，或同为 IP 直连/两边都空）时保持原端口。
# 新装/换身份或 --random-port：由调用方随机。
ws_pick_port() {
  local want_domain=$1 old_domain=$2 old_port=$3 arg_port=$4 arg_random=$5
  if [[ $arg_random == 1 ]]; then
    return 0
  fi
  if [[ -n $arg_port ]]; then
    printf '%s' "$arg_port"
    return 0
  fi
  if [[ $old_domain == "$want_domain" && -n $old_port ]]; then
    printf '%s' "$old_port"
    return 0
  fi
  return 0
}

resolve_public_ip() {
  local ip ep
  if [[ -n $PUBLIC_IP ]]; then
    is_ipv4 "$PUBLIC_IP" || fail "--public-ip 必须是有效 IPv4: $PUBLIC_IP"
    printf %s "$PUBLIC_IP"
    return
  fi
  for ep in https://api.ipify.org https://ipv4.icanhazip.com https://ifconfig.me/ip; do
    ip=$(curl --proto '=https' --proto-redir '=https' -4fsS --connect-timeout 5 --max-time 10 "$ep" 2>/dev/null | tr -d '[:space:]' || true)
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
  elif command -v firewall-cmd >/dev/null && [[ $(firewall-cmd --state 2>/dev/null || true) == running ]]; then
    firewall-cmd --permanent --add-port="${port}/${proto}" >/dev/null 2>&1 ||
      fail "firewalld 放行失败: ${port}/${proto}"
    firewall-cmd --reload >/dev/null 2>&1 ||
      fail "firewalld 重载失败: ${port}/${proto}"
    ok "firewalld 已放行 ${port}/${proto}"
  else
    warn "请自行放行 ${port}/${proto}（nftables/iptables/云安全组等）"
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

# ---------- 只读节点检测 / Xray 布局发现（不修改配置） ----------
# 证据：真实服务配置 > systemd 运行态(仅展示) > state 元数据 > info 缓存

port_is_valid() {
  [[ ${1:-} =~ ^[0-9]+$ ]] && ((1 <= 10#$1 && 10#$1 <= 65535))
}

# 解析 ExecStart：输出 file:/path 或 dir:/path（禁止 unquoted 分词 / eval）
parse_execstart_config_specs() {
  local exec_line=$1
  exec_line=${exec_line#path=}
  if command -v python3 >/dev/null 2>&1; then
    EXEC_LINE="$exec_line" python3 - <<'PY'
import os, shlex
line = os.environ.get("EXEC_LINE", "")
try:
    tokens = shlex.split(line, posix=True)
except Exception:
    tokens = line.split()
i = 0
while i < len(tokens):
    t = tokens[i].strip('"').strip("'")
    if t.startswith("-config=") or t.startswith("--config=") or t.startswith("-c="):
        print("file:" + t.split("=", 1)[1].strip('"').strip("'"))
    elif t.startswith("-confdir="):
        print("dir:" + t.split("=", 1)[1].strip('"').strip("'"))
    elif t in ("-config", "--config", "-c") and i + 1 < len(tokens):
        i += 1
        print("file:" + tokens[i].strip('"').strip("'"))
    elif t == "-confdir" and i + 1 < len(tokens):
        i += 1
        print("dir:" + tokens[i].strip('"').strip("'"))
    i += 1
PY
    return 0
  fi
  # 无 python 时用正则逐个剥离（保守）
  local rest=$exec_line key val
  while [[ $rest =~ (-confdir|-config|--config|-c)(=|[[:space:]]+)([^[:space:]]+)(.*) ]]; do
    key=${BASH_REMATCH[1]}
    val=${BASH_REMATCH[3]}
    val=${val//\"/}
    val=${val//\'/}
    rest=${BASH_REMATCH[4]}
    case $key in
      -confdir) printf 'dir:%s\n' "$val" ;;
      *) printf 'file:%s\n' "$val" ;;
    esac
  done
}

# 发现 Xray 实际配置布局（写入 XRAY_LAYOUT / XRAY_CONFIG_FILE / XRAY_CONF_DIR）
# VPS_PROXY_LOCK_LAYOUT=1 时保留调用方已设置的路径（测试用）
xray_discover() {
  local exec_line spec path
  if [[ ${VPS_PROXY_LOCK_LAYOUT:-0} == 1 ]]; then
    return 0
  fi
  XRAY_LAYOUT=unknown
  XRAY_CONFIG_FILE=
  XRAY_CONF_DIR=
  exec_line=$(systemctl show -p ExecStart --value xray 2>/dev/null || true)
  # 合并 drop-in 后的有效 ExecStart 已由 systemctl show 给出
  if [[ -n $exec_line ]]; then
    while IFS= read -r spec; do
      [[ -n $spec ]] || continue
      path=${spec#*:}
      case $spec in
        file:*)
          # 允许首次安装时配置文件尚不存在，但拒绝相对路径和空路径。
          if [[ -n $path && $path == /* ]]; then
            XRAY_LAYOUT=file
            XRAY_CONFIG_FILE=$path
            XRAY_CONFIG=$path
          fi
          ;;
        dir:*)
          if [[ -n $path && $path == /* ]]; then
            XRAY_LAYOUT=dir
            XRAY_CONF_DIR=$path
          fi
          ;;
      esac
    done < <(parse_execstart_config_specs "$exec_line")
  fi
  if [[ $XRAY_LAYOUT == unknown ]]; then
    if [[ -d ${XRAY_CONFIG%/*}/conf.d ]]; then
      : # 可选 conf.d 不自动采用
    fi
    if [[ -n ${XRAY_CONFIG:-} && $XRAY_CONFIG == /* ]]; then
      XRAY_LAYOUT=file
      XRAY_CONFIG_FILE=$XRAY_CONFIG
    else
      XRAY_LAYOUT=file
      XRAY_CONFIG=/usr/local/etc/xray/config.json
      XRAY_CONFIG_FILE=$XRAY_CONFIG
    fi
  fi
  if [[ $XRAY_LAYOUT == file && -z $XRAY_CONFIG_FILE ]]; then
    XRAY_CONFIG_FILE=${XRAY_CONFIG:-/usr/local/etc/xray/config.json}
  fi
}

# 统一扫描：输出 key=value 行
# has_reality=0|1  has_ws=0|1  port_reality=  port_ws=  source=
# 端口无法可靠解析时留空（禁止用文件中第一个 port 冒充）
xray_scan() {
  xray_discover
  local has_r=0 has_c=0 port_r="" port_c="" source="none"
  local f files=()

  if [[ $XRAY_LAYOUT == dir && -n $XRAY_CONF_DIR && -d $XRAY_CONF_DIR ]]; then
    source="confdir:$XRAY_CONF_DIR"
    while IFS= read -r f; do
      [[ -r $f ]] && files+=("$f")
    done < <(find "$XRAY_CONF_DIR" -type f -name '*.json' 2>/dev/null || true)
  elif [[ $XRAY_LAYOUT == file && -n $XRAY_CONFIG_FILE && -r $XRAY_CONFIG_FILE ]]; then
    source="file:$XRAY_CONFIG_FILE"
    files+=("$XRAY_CONFIG_FILE")
  elif [[ -r ${XRAY_CONFIG:-} ]]; then
    source="file:$XRAY_CONFIG"
    files+=("$XRAY_CONFIG")
  fi

  if ((${#files[@]} == 0)); then
    printf 'has_reality=0\nhas_ws=0\nport_reality=\nport_ws=\nsource=none\n'
    return 0
  fi

  if command -v python3 >/dev/null 2>&1; then
    local out prc
    set +e
    out=$(SRC="$source" FILES="$(printf '%s\n' "${files[@]}")" TAG_R="$MANAGED_TAG_REALITY" TAG_C="$MANAGED_TAG_WS" python3 - <<'PY'
import json, os, sys
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(newline="\n")
files = [x for x in os.environ.get("FILES", "").splitlines() if x]
tag_r = os.environ.get("TAG_R", "vless-reality")
tag_c = os.environ.get("TAG_C", "vless-ws-tls")
src = os.environ.get("SRC", "none")
has_r = has_c = False
port_r = port_c = ""
opened = 0

def inbounds_of(data):
    if isinstance(data, dict):
        ib = data.get("inbounds")
        if isinstance(ib, list):
            return ib
    if isinstance(data, list):
        return data
    return []

def is_reality(ib):
    if not isinstance(ib, dict):
        return False
    if ib.get("tag") == tag_r:
        return True
    ss = ib.get("streamSettings") or {}
    return ib.get("protocol") == "vless" and ss.get("security") == "reality"

def is_ws(ib):
    if not isinstance(ib, dict):
        return False
    if ib.get("tag") == tag_c:
        return True
    ss = ib.get("streamSettings") or {}
    return ib.get("protocol") == "vless" and ss.get("network") == "ws" and ss.get("security") == "tls"

for path in files:
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
        opened += 1
    except Exception:
        continue
    for ib in inbounds_of(data):
        if is_reality(ib):
            has_r = True
            p = ib.get("port")
            if p is not None and str(p).isdigit() and 1 <= int(p) <= 65535:
                port_r = str(int(p))
        if is_ws(ib):
            has_c = True
            p = ib.get("port")
            if p is not None and str(p).isdigit() and 1 <= int(p) <= 65535:
                port_c = str(int(p))
if not opened:
    sys.exit(2)
print(f"has_reality={1 if has_r else 0}")
print(f"has_ws={1 if has_c else 0}")
print(f"port_reality={port_r}")
print(f"port_ws={port_c}")
print(f"source={src}")
PY
)
    prc=$?
    set -e
    if [[ $prc -eq 0 ]]; then
      printf '%s\n' "$out"
      return 0
    fi
  fi

  # bash 回退：tag/语义确认后，仅从匹配 inbound 块取 port（不取文件首个无关 port）
  _port_for_tag() {
    local file=$1 tag=$2
    awk -v tag="$tag" '
      $0 ~ "\"tag\"" && $0 ~ "\"" tag "\"" { grab=1 }
      grab && /"port"/ {
        if (match($0, /[0-9]+/)) { print substr($0, RSTART, RLENGTH); exit }
      }
      grab && /"tag"/ && $0 !~ tag { grab=0 }
    ' "$file" 2>/dev/null
  }
  for f in "${files[@]}"; do
    if grep -qE "\"tag\"[[:space:]]*:[[:space:]]*\"${MANAGED_TAG_REALITY}\"" "$f" 2>/dev/null \
      || { grep -qE "\"security\"[[:space:]]*:[[:space:]]*\"reality\"" "$f" 2>/dev/null \
        && grep -qE "\"protocol\"[[:space:]]*:[[:space:]]*\"vless\"" "$f" 2>/dev/null; }; then
      has_r=1
      port_r=$(_port_for_tag "$f" "$MANAGED_TAG_REALITY")
      if [[ -z $port_r ]]; then
        # 语义块：在 security reality 前若干行找 port
        port_r=$(awk '
          /"port"/ { lastport=$0 }
          /"security"/ && /reality/ {
            if (match(lastport, /[0-9]+/)) { print substr(lastport, RSTART, RLENGTH); exit }
          }
        ' "$f" 2>/dev/null || true)
      fi
    fi
    if grep -qE "\"tag\"[[:space:]]*:[[:space:]]*\"${MANAGED_TAG_WS}\"" "$f" 2>/dev/null \
      || { grep -qE "\"network\"[[:space:]]*:[[:space:]]*\"ws\"" "$f" 2>/dev/null \
        && grep -qE "\"security\"[[:space:]]*:[[:space:]]*\"tls\"" "$f" 2>/dev/null \
        && grep -qE "\"protocol\"[[:space:]]*:[[:space:]]*\"vless\"" "$f" 2>/dev/null; }; then
      has_c=1
      port_c=$(_port_for_tag "$f" "$MANAGED_TAG_WS")
    fi
  done
  printf 'has_reality=%s\nhas_ws=%s\nport_reality=%s\nport_ws=%s\nsource=%s\n' \
    "$has_r" "$has_c" "$port_r" "$port_c" "$source"
}

# 解析 xray_scan 输出到变量
xray_scan_load() {
  local k v
  HAS_REALITY=0 HAS_WS=0 PORT_REALITY= PORT_WS= SCAN_SOURCE=none
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%$'\r'}
    [[ $line == *=* ]] || continue
    k=${line%%=*}; v=${line#*=}
    v=${v%$'\r'}
    case $k in
      has_reality) HAS_REALITY=$v ;;
      has_ws) HAS_WS=$v ;;
      port_reality) PORT_REALITY=$v ;;
      port_ws) PORT_WS=$v ;;
      source) SCAN_SOURCE=$v ;;
    esac
  done < <(xray_scan)
}

xray_has_component() {
  local kind=$1
  xray_scan_load
  case $kind in
    reality) [[ ${HAS_REALITY:-0} == 1 ]] ;;
    ws) [[ ${HAS_WS:-0} == 1 ]] ;;
    *) return 1 ;;
  esac
}

xray_inbound_port() {
  local kind=$1
  xray_scan_load
  case $kind in
    reality) [[ -n ${PORT_REALITY:-} ]] && printf '%s\n' "$PORT_REALITY" ;;
    ws) [[ -n ${PORT_WS:-} ]] && printf '%s\n' "$PORT_WS" ;;
  esac
  return 0
}

xray_list_config_files() {
  xray_discover
  if [[ $XRAY_LAYOUT == dir && -n $XRAY_CONF_DIR ]]; then
    find "$XRAY_CONF_DIR" -type f -name '*.json' 2>/dev/null || true
  elif [[ -n ${XRAY_CONFIG_FILE:-} && -r $XRAY_CONFIG_FILE ]]; then
    printf '%s\n' "$XRAY_CONFIG_FILE"
  elif [[ -r ${XRAY_CONFIG:-} ]]; then
    printf '%s\n' "$XRAY_CONFIG"
  fi
}



hy2_resolve_config_path() {
  local exec_line spec path
  exec_line=$(systemctl show -p ExecStart --value hysteria-server 2>/dev/null || true)
  if [[ -n $exec_line ]]; then
    while IFS= read -r spec; do
      [[ $spec == file:* ]] || continue
      path=${spec#file:}
      if [[ -r $path ]]; then
        printf '%s\n' "$path"
        return 0
      fi
    done < <(parse_execstart_config_specs "$exec_line")
  fi
  if [[ -r ${HY2_CONFIG:-} ]]; then
    printf '%s\n' "$HY2_CONFIG"
    return 0
  fi
  return 1
}

hy2_config_present() {
  local cfg
  cfg=$(hy2_resolve_config_path 2>/dev/null || true)
  [[ -n ${cfg:-} && -r $cfg ]] || return 1
  grep -qE '^[[:space:]]*listen:' "$cfg" 2>/dev/null || return 1
  grep -qE '^[[:space:]]*tls:|^[[:space:]]*cert:' "$cfg" 2>/dev/null || return 1
  grep -qE '^[[:space:]]*auth:|^[[:space:]]*password:' "$cfg" 2>/dev/null || return 1
  return 0
}

hy2_config_port() {
  local cfg
  cfg=$(hy2_resolve_config_path 2>/dev/null || true)
  [[ -n ${cfg:-} && -r $cfg ]] || return 0
  sed -nE 's/^[[:space:]]*listen:[[:space:]]*:([0-9]+).*/\1/p' "$cfg" 2>/dev/null | head -n1
}

info_get_port() {
  local file=$1 line
  [[ -f $file ]] || return 0
  while IFS= read -r line || [[ -n $line ]]; do
    if [[ $line =~ 端口[[:space:]]*[:：][[:space:]]*([0-9]+) ]]; then
      printf '%s\n' "${BASH_REMATCH[1]}"
      return 0
    fi
  done <"$file"
}

resolve_component_port() {
  local state_file=$1 port_key=$2 info_file=$3 comp=$4
  local p
  p=$(state_get "$state_file" "$port_key")
  if port_is_valid "$p"; then printf '%s\n' "$p"; return 0; fi
  p=$(info_get_port "$info_file")
  if port_is_valid "$p"; then printf '%s\n' "$p"; return 0; fi
  case $comp in
    reality|ws) p=$(xray_inbound_port "$comp") ;;
    hy2) p=$(hy2_config_port) ;;
  esac
  if port_is_valid "$p"; then printf '%s\n' "$p"; return 0; fi
}

component_has_config() {
  local comp=$1
  case $comp in
    reality) xray_has_component reality ;;
    ws) xray_has_component ws ;;
    hy2) hy2_config_present ;;
    *) return 1 ;;
  esac
}

# 破坏性操作只认本项目明确写入的 tag/state；协议语义检测仍可用于只读展示。
xray_has_managed_tag() {
  local comp=$1 tag f
  case $comp in
    reality) tag=$MANAGED_TAG_REALITY ;;
    ws) tag=$MANAGED_TAG_WS ;;
    *) return 1 ;;
  esac
  while IFS= read -r f; do
    [[ -r $f ]] || continue
    grep -qE "\"tag\"[[:space:]]*:[[:space:]]*\"${tag}\"" "$f" 2>/dev/null && return 0
  done < <(xray_list_config_files 2>/dev/null || true)
  return 1
}

# 兼容旧版本项目安装：旧版本没有写入 state/drop-in 标记，但会使用专用配置、服务和信息文件。
hy2_legacy_layout_present() {
  local unit
  hy2_config_present || return 1
  [[ -f $HY2_INFO ]] && return 0
  unit=$(systemctl cat hysteria-server 2>/dev/null || true)
  grep -qE '/usr/local/bin/hysteria([[:space:]]|$)' <<<"$unit" && return 0
  return 1
}

managed_component_present() {
  local comp=$1
  case $comp in
    reality) [[ -f $REALITY_STATE ]] || xray_has_managed_tag reality ;;
    ws) migrate_legacy_cdn_state; [[ -f $WS_STATE ]] || xray_has_managed_tag ws ;;
    hy2) [[ -f $HY2_STATE ]] ||
      { [[ -r $HY2_DROPIN ]] && grep -q '^# syw-vps-managed=vps-proxy$' "$HY2_DROPIN" 2>/dev/null; } ||
      hy2_legacy_layout_present ;;
    *) return 1 ;;
  esac
}

proxy_status_line() {
  local n_total=0 n_run=0 n_stop=0 n_bad=0
  local st

  if component_has_config reality; then
    ((n_total++)) || true
    st=$(svc_state xray xray)
    case $st in running) ((n_run++)) || true ;; stopped) ((n_stop++)) || true ;; *) ((n_bad++)) || true ;; esac
  fi
  if component_has_config ws; then
    ((n_total++)) || true
    st=$(svc_state xray xray)
    case $st in running) ((n_run++)) || true ;; stopped) ((n_stop++)) || true ;; *) ((n_bad++)) || true ;; esac
  fi
  if component_has_config hy2; then
    ((n_total++)) || true
    st=$(svc_state hysteria-server hysteria)
    case $st in running) ((n_run++)) || true ;; stopped) ((n_stop++)) || true ;; *) ((n_bad++)) || true ;; esac
  fi

  if (( n_total == 0 )); then
    if [[ -f $REALITY_STATE || -f $WS_STATE || -f $HY2_STATE ]]; then
      printf '%s×%s  配置异常' "$RED" "$R"
    else
      printf '%s○%s  暂无代理' "$D" "$R"
    fi
    return 0
  fi

  if (( n_bad > 0 && n_run == 0 )); then
    printf '%s×%s  配置异常' "$RED" "$R"
  elif (( n_run == n_total )); then
    printf '%s●%s  %s 个节点运行中' "$GRN" "$R" "$n_run"
  elif (( n_run == 0 )); then
    printf '%s○%s  代理已停止' "$YEL" "$R"
  else
    printf '%s!%s  %s 个节点已停止' "$YEL" "$R" "$n_stop"
  fi
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

# 字段名本地化；跳过端口（标题已含）
info_label_zh() {
  case $1 in
    地址|Address) echo "地址" ;;
    端口|Port) echo "" ;; # 跳过
    UUID|uuid) echo "UUID" ;;
    Flow|流控) echo "流控" ;;
    SNI|sni) echo "SNI" ;;
    目标|Target|dest) echo "目标" ;;
    PublicKey|公钥|pbk) echo "公钥" ;;
    ShortId|短\ ID|短ID|sid) echo "短 ID" ;;
    域名|Domain) echo "域名" ;;
    密码|Password) echo "密码" ;;
    证书指纹|指纹) echo "证书指纹" ;;
    协议|Protocol) echo "" ;; # 标题已含协议/端口
    传输|TLS|Path|Host) echo "$1" ;;
    分享链接) echo "" ;; # 单独成块
    *) echo "$1" ;;
  esac
}

# 打印 info 连接字段；分享链接单独成块；不重复端口
print_info_fields() {
  local file=$1 line k v label share=0
  local -a links=()
  [[ -f $file ]] || return 0
  while IFS= read -r line || [[ -n $line ]]; do
    [[ -z ${line//[[:space:]]/} ]] && continue
    if [[ $line == *://* ]]; then
      links+=("$line")
      continue
    fi
    if [[ $line != *:* ]]; then
      continue
    fi
    k=${line%%:*}
    v=${line#*:}
    v=${v#"${v%%[![:space:]]*}"}
    k=${k%"${k##*[![:space:]]}"}
    # 跳过纯「分享链接:」标题行
    if [[ $k == 分享链接 || $k == 分享 ]]; then
      continue
    fi
    label=$(info_label_zh "$k")
    [[ -n $label ]] || continue
    if [[ -z $v ]]; then
      continue
    fi
    printf '  %s%-8s%s %s\n' "$D" "$label" "$R" "$v"
  done <"$file"
  if ((${#links[@]})); then
    printf '\n  %s分享链接%s\n' "$D" "$R"
    local L
    for L in "${links[@]}"; do
      printf '  %s\n' "$L"
    done
  fi
}

# 安装完成后展示节点字段
print_block() {
  printf '\n  %s%s%s\n' "$B$CYN" "$1" "$R"
  print_info_fields "$2"
  printf '\n'
}

# 节点页：comp=reality|ws|hy2
# 返回：0=展示有效/异常组件  1=无此组件  2=仅残留 info
# 正常模式：真实配置为唯一依据，不向用户暴露 state 概念
# PROXY_STATUS_DEBUG=1 / --status-debug：才显示「状态元数据缺失」等排障信息
# 查看状态只读，不创建或修改 state
show_component() {
  local name=$1 state_file=$2 info_file=$3 unit=$4 bin=$5 port_key=$6 comp=$7
  local has_cfg=0 has_state=0 has_info=0
  local st port="" sc stxt
  local debug=${PROXY_STATUS_DEBUG:-0}

  if component_has_config "$comp"; then
    has_cfg=1
  fi
  [[ -f $state_file ]] && has_state=1
  [[ -f $info_file ]] && has_info=1

  # 仅 info 残留（无真实配置）
  if (( !has_cfg && has_info )); then
    # 有 state 无配置：更像配置丢失，而非「残留」
    if (( has_state )); then
      port=$(resolve_component_port "$state_file" "$port_key" "$info_file" "$comp")
      printf '\n  %s%s%s  %s× 配置缺失%s' "$B" "$name" "$R" "$RED" "$R"
      [[ -n $port ]] && printf '  %s:%s%s' "$D" "$port" "$R"
      printf '\n'
      printf '  %s!%s  服务配置中未找到该节点\n' "$YEL" "$R"
      return 0
    fi
    printf '  %s!%s  %s 残留信息文件\n' "$YEL" "$R" "$name"
    return 2
  fi

  # state 有、真实配置无、无 info
  if (( !has_cfg && has_state )); then
    port=$(resolve_component_port "$state_file" "$port_key" "$info_file" "$comp")
    printf '\n  %s%s%s  %s× 配置缺失%s' "$B" "$name" "$R" "$RED" "$R"
    [[ -n $port ]] && printf '  %s:%s%s' "$D" "$port" "$R"
    printf '\n'
    printf '  %s!%s  服务配置中未找到该节点\n' "$YEL" "$R"
    return 0
  fi

  # 完全无此组件
  if (( !has_cfg && !has_state && !has_info )); then
    return 1
  fi

  # 真实配置存在（state 可选，正常页不提示缺失）
  port=$(resolve_component_port "$state_file" "$port_key" "$info_file" "$comp")
  st=$(svc_state "$unit" "$bin")
  case $st in
    running) sc=$GRN; stxt="● 运行中" ;;
    stopped) sc=$YEL; stxt="○ 已停止" ;;
    *)       sc=$RED; stxt="× 异常" ;;
  esac

  # 标题：名称 + 状态 + 端口/协议（不重复打印端口字段）
  local proto_tag="TCP"
  [[ $comp == hy2 ]] && proto_tag="UDP"
  printf '\n  %s%s%s  %s%s%s' "$B" "$name" "$R" "$sc" "$stxt" "$R"
  if [[ -n $port ]]; then
    printf '  %s%s/%s%s' "$D" "$port" "$proto_tag" "$R"
  fi
  printf '\n'

  if (( debug && !has_state )); then
    printf '  %s!%s  状态元数据缺失\n' "$YEL" "$R"
  fi

  if (( has_info )); then
    print_info_fields "$info_file"
  else
    printf '  %s!%s  节点信息缺失\n' "$YEL" "$R"
  fi
  return 0
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

xray_service_binary_path() {
  local exec_line path
  exec_line=$(systemctl show -p ExecStart --value xray 2>/dev/null || true)
  if [[ $exec_line =~ path=([^[:space:];]+) ]]; then
    path=${BASH_REMATCH[1]}
    [[ $path == /* && -x $path ]] && printf '%s\n' "$path"
  fi
}

xray_binary_path() {
  local service_bin
  service_bin=$(xray_service_binary_path || true)
  if [[ -n $service_bin ]]; then
    printf '%s\n' "$service_bin"
  elif [[ -x $XRAY_CORE_BIN ]]; then
    printf '%s\n' "$XRAY_CORE_BIN"
  elif command -v xray >/dev/null 2>&1; then
    command -v xray
  else
    return 1
  fi
}

xray_arch() {
  case $(uname -m) in
    x86_64|amd64) echo 64 ;;
    i386|i486|i586|i686) echo 32 ;;
    aarch64|arm64) echo arm64-v8a ;;
    armv7l|armv7) echo arm32-v7a ;;
    armv6l|armv6) echo arm32-v6 ;;
    armv5*|armv5) echo arm32-v5 ;;
    loongarch64) echo loong64 ;;
    ppc64le) echo ppc64le ;;
    ppc64) echo ppc64 ;;
    riscv64) echo riscv64 ;;
    s390x) echo s390x ;;
    mips64) echo mips64 ;;
    mips64el|mips64le) echo mips64le ;;
    mips) echo mips32 ;;
    mipsel) echo mips32le ;;
    *) return 1 ;;
  esac
}

xray_version_of() {
  local bin=${1:-}
  [[ -n $bin ]] || bin=$(xray_binary_path) || return 1
  "$bin" version 2>/dev/null |
    grep -Eo 'v?[0-9]+\.[0-9]+\.[0-9]+' | head -n1
}

xray_latest_version() {
  local data version
  [[ $XRAY_UPDATE_API == https://* ]] || return 1
  data=$(curl --proto '=https' --proto-redir '=https' -fsSL --retry 3 --connect-timeout 10 --max-time 60 \
    -H 'Accept: application/vnd.github+json' -H 'User-Agent: syw-vps-updater' \
    "$XRAY_UPDATE_API") || return 1
  version=$(sed -nE 's/.*"tag_name"[[:space:]]*:[[:space:]]*"(v[0-9]+\.[0-9]+\.[0-9]+)".*/\1/p' <<<"$data" | head -n1)
  [[ $version =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  printf '%s\n' "$version"
}

xray_release_asset() {
  local arch
  arch=$(xray_arch) || return 1
  printf 'Xray-linux-%s.zip\n' "$arch"
}

xray_download_verified() {
  local version=$1 dest=$2 asset work zip dgst expected actual
  asset=$(xray_release_asset) || return 1
  work=$(mktemp -d /tmp/${APP_NAME}.xray.XXXXXX)
  zip="$work/$asset"
  dgst="$work/$asset.dgst"
  if ! curl_download "${XRAY_RELEASE_BASE}/${version}/${asset}" "$zip" ||
     ! curl_download "${XRAY_RELEASE_BASE}/${version}/${asset}.dgst" "$dgst"; then
    rm -rf -- "$work"
    return 1
  fi
  expected=$(sed -nE 's/^SHA2-256=[[:space:]]*([A-Fa-f0-9]{64})$/\1/p' "$dgst" | head -n1)
  actual=$(sha256_file "$zip")
  if ! is_valid_sha256 "$expected" || [[ ${actual,,} != "${expected,,}" ]]; then
    rm -rf -- "$work"
    return 2
  fi
  command -v unzip >/dev/null 2>&1 || {
    rm -rf -- "$work"
    return 3
  }
  if ! unzip -p "$zip" xray >"$dest" 2>/dev/null || [[ ! -s $dest ]]; then
    rm -rf -- "$work"
    return 1
  fi
  chmod 755 "$dest"
  rm -rf -- "$work"
}

xray_validate_candidate() {
  local bin=$1 cfg
  "$bin" version >/dev/null 2>&1 || return 1
  xray_discover
  if [[ $XRAY_LAYOUT == dir && -n $XRAY_CONF_DIR && -d $XRAY_CONF_DIR ]]; then
    "$bin" run -test -confdir "$XRAY_CONF_DIR" >/dev/null 2>&1
  else
    cfg=${XRAY_CONFIG_FILE:-$XRAY_CONFIG}
    [[ -r $cfg ]] || return 0
    "$bin" run -test -config "$cfg" >/dev/null 2>&1
  fi
}

hy2_validate_candidate() {
  local bin=$1 mode=${2:-manual} cfg
  "$bin" version >/dev/null 2>&1 || return 1
  # 已有配置时至少确认关键结构完整；服务停止时由调用方做一次真实启动检查。
  cfg=$(hy2_resolve_config_path 2>/dev/null || true)
  if [[ $mode != install && -n $cfg && -r $cfg ]]; then
    hy2_config_present || return 1
  fi
  return 0
}

xray_record_update() {
  local result=$1 current=${2:-unknown} latest=${3:-unknown}
  ensure_dirs
  write_kv_file "$XRAY_UPDATE_STATE" \
    "LAST_CHECK=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "RESULT=${result}" "CURRENT=${current}" "LATEST=${latest}"
}

update_xray_core() {
  local mode=${1:-manual} current latest candidate backup candidate_version was_active=0 bin
  mode=${mode#--}
  require_root
  require_systemd
  command -v curl >/dev/null 2>&1 || fail "更新 Xray 缺少命令: curl"
  command -v sha256sum >/dev/null 2>&1 || fail "更新 Xray 缺少命令: sha256sum"
  command -v sort >/dev/null 2>&1 || fail "更新 Xray 缺少命令: sort"
  command -v flock >/dev/null 2>&1 || fail "更新 Xray 缺少命令: flock"
  bin=$(xray_binary_path) || { [[ $mode == auto ]] || warn "Xray 尚未安装，跳过更新"; return 0; }
  install -d -m 755 "$(dirname "$XRAY_UPDATE_LOCK")"
  exec 8>"$XRAY_UPDATE_LOCK"
  if ! flock -n 8; then
    [[ $mode == auto ]] || warn "已有 Xray 更新任务运行中"
    return 0
  fi
  current=$(xray_version_of "$bin") || true
  [[ -n $current ]] || { xray_record_update invalid-version; fail "无法识别当前 Xray 版本"; }
  [[ $current == v* ]] || current="v${current}"
  latest=$(xray_latest_version) || { xray_record_update check-failed "$current"; fail "无法获取 Xray 最新稳定版"; }
  if ! hy2_version_lt "$current" "$latest"; then
    xray_record_update current "$current" "$latest"
    [[ $mode == auto ]] || ok "Xray 已是最新稳定版: $current"
    return 0
  fi
  if ! command -v unzip >/dev/null 2>&1; then
    command -v apt-get >/dev/null 2>&1 || fail "更新 Xray 需要 unzip"
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq unzip >/dev/null
  fi
  candidate=$(mktemp /tmp/${APP_NAME}.xray-bin.XXXXXX)
  backup=$(mktemp /tmp/${APP_NAME}.xray-old.XXXXXX)
  if ! xray_download_verified "$latest" "$candidate"; then
    rm -f -- "$candidate" "$backup"
    xray_record_update verify-failed "$current" "$latest"
    fail "Xray 下载或 SHA256 校验失败"
  fi
  candidate_version=$(xray_version_of "$candidate") || true
  [[ -n $candidate_version ]] || {
    rm -f -- "$candidate" "$backup"
    xray_record_update invalid-candidate "$current" "$latest"
    fail "Xray 新版二进制无法运行，保留旧版"
  }
  candidate_version=${candidate_version#v}
  [[ $candidate_version == ${latest#v} ]] || {
    rm -f -- "$candidate" "$backup"
    xray_record_update version-mismatch "$current" "$latest"
    fail "Xray 下载版本与发布版本不一致，保留旧版"
  }
  if ! xray_validate_candidate "$candidate"; then
    rm -f -- "$candidate" "$backup"
    xray_record_update config-failed "$current" "$latest"
    fail "新版 Xray 配置验证失败，保留旧版"
  fi
  cp -p "$bin" "$backup"
  systemctl is-active --quiet xray 2>/dev/null && was_active=1
  if ! install -m 755 "$candidate" "${bin}.new" || ! mv -f "${bin}.new" "$bin"; then
    rm -f -- "$candidate" "${bin}.new" "$backup"
    xray_record_update replace-failed "$current" "$latest"
    fail "Xray 替换失败，保留旧版"
  fi
  rm -f -- "$candidate"
  if [[ $mode != install && $was_active -eq 1 ]]; then
    systemctl restart xray || true
    local i
    for ((i = 1; i <= 8; i++)); do
      sleep 1
      if systemctl is-active --quiet xray; then
        rm -f -- "$backup"
        xray_record_update updated "$current" "$latest"
        [[ $mode == auto ]] || ok "Xray 已更新: ${current} → ${latest}"
        return 0
      fi
    done
    install -m 755 "$backup" "$bin"
    systemctl restart xray || true
    rm -f -- "$backup"
    xray_record_update rolled-back "$current" "$latest"
    fail "新版 Xray 启动失败，已恢复 ${current}"
  elif [[ $mode != install ]] && systemctl cat xray >/dev/null 2>&1; then
    if ! systemctl start xray; then
      install -m 755 "$backup" "$bin"
      rm -f -- "$backup"
      xray_record_update rolled-back "$current" "$latest"
      fail "新版 Xray 启动验证失败，已恢复 ${current}"
    fi
    local i
    for ((i = 1; i <= 8; i++)); do
      sleep 1
      if systemctl is-active --quiet xray; then
        systemctl stop xray 2>/dev/null || true
        rm -f -- "$backup"
        xray_record_update updated "$current" "$latest"
        [[ $mode == auto ]] || ok "Xray 已更新: ${current} → ${latest}"
        return 0
      fi
    done
    systemctl stop xray 2>/dev/null || true
    install -m 755 "$backup" "$bin"
    rm -f -- "$backup"
    xray_record_update rolled-back "$current" "$latest"
    fail "新版 Xray 启动验证失败，已恢复 ${current}"
  fi
  rm -f -- "$backup"
  xray_record_update updated "$current" "$latest"
  [[ $mode == auto ]] || ok "Xray 已更新: ${current} → ${latest}"
}

update_proxy_cores() {
  local mode=${1:-manual} found=0
  mode=${mode#--}
  if xray_binary_path >/dev/null 2>&1; then
    update_xray_core "$mode"
    found=1
  fi
  if [[ -x $HY2_BIN ]]; then
    update_hy2_core "$mode"
    found=1
  fi
  if ((found)) && [[ $mode == manual ]]; then
    enable_proxy_auto_update
    ok "代理核心每周自动更新已启用"
  fi
  ((found)) || { [[ $mode == auto ]] || warn "未找到可更新的 Xray/Hysteria2 核心"; }
}

xray_run_user() {
  local xu
  xu=$(systemctl show -p User --value xray 2>/dev/null || true)
  [[ -z $xu || $xu == - ]] && xu=nobody
  if command -v getent >/dev/null 2>&1; then
    getent passwd "$xu" >/dev/null 2>&1 || xu=nobody
  fi
  printf %s "$xu"
}
xray_run_group() { id -gn "$(xray_run_user)" 2>/dev/null || echo nogroup; }
xray_cert_dir() {
  local base=${XRAY_CONFIG_FILE:-$XRAY_CONFIG}
  [[ $XRAY_LAYOUT == dir && -n $XRAY_CONF_DIR ]] && base="$XRAY_CONF_DIR/x.json"
  printf '%s/certs/%s' "$(dirname "$base")" "$1"
}

fix_cert_permissions() {
  local certdir=$1 cert=$2 key=$3 xg
  xg=$(xray_run_group)
  install -d -o root -g "$xg" -m 750 "$(dirname "$certdir")"
  install -d -o root -g "$xg" -m 750 "$certdir"
  [[ -f $cert ]] && chown "root:$xg" "$cert" && chmod 644 "$cert"
  [[ -f $key ]] && chown "root:$xg" "$key" && chmod 640 "$key"
}

# 校验配置；测试环境可设置 VPS_PROXY_SKIP_XRAY_TEST=1，仅跳过 Xray 语义校验。
xray_validate_path() {
  local path=$1 mode=${2:-file} bin output
  local skip_test=${VPS_PROXY_SKIP_XRAY_TEST:-0}
  # 跳过语义校验只接受测试标记，避免生产环境误继承该环境变量。
  if [[ $skip_test == 1 && ${VPS_PROXY_TEST_MODE:-0} != 1 ]]; then
    skip_test=0
  fi
  if [[ $skip_test == 1 ]] || ! command -v xray >/dev/null 2>&1; then
    command -v python3 >/dev/null 2>&1 || return 1
    python3 - "$path" "$mode" <<'PY' 2>/dev/null || return 1
import glob, json, os, sys
path, mode = sys.argv[1:3]
files = sorted(glob.glob(os.path.join(path, "*.json"))) if mode == "dir" else [path]
if not files:
    raise SystemExit(1)
for file in files:
    with open(file, encoding="utf-8") as stream:
        json.load(stream)
PY
    return 0
  fi
  bin=$(xray_binary_path 2>/dev/null || command -v xray 2>/dev/null || true)
  [[ -x $bin ]] || return 1
  if [[ $mode == dir ]]; then
    output=$("$bin" run -test -confdir="$path" 2>&1) || {
      printf '  Xray 配置校验输出: %s\n' "${output:-无输出}" >&2
      return 1
    }
  else
    output=$("$bin" run -test -config="$path" 2>&1) || {
      printf '  Xray 配置校验输出: %s\n' "${output:-无输出}" >&2
      return 1
    }
  fi
}

xray_apply_perms() {
  local path=$1 xg
  xg=$(xray_run_group)
  if ((EUID == 0)); then
    install -d -o root -g "$xg" -m 750 "$(dirname "$path")"
    chown "root:$xg" "$path" 2>/dev/null || true
  else
    install -d -m 750 "$(dirname "$path")" 2>/dev/null || mkdir -p "$(dirname "$path")"
  fi
  chmod 640 "$path" 2>/dev/null || true
}

write_ws_state() {
  write_kv_file "$WS_STATE" \
    "WS_PORT=${WS_PORT}" "WS_UUID=${WS_UUID}" "WS_DOMAIN=${WS_DOMAIN}" \
    "WS_PATH=${WS_PATH}" "WS_CERT=${WS_CERT}" "WS_KEY=${WS_KEY}" \
    "WS_SNI=${WS_SNI}" "WS_ADDR=${WS_ADDR}" "WS_PIN=${WS_PIN}"
}

migrate_ws_certs_if_needed() {
  [[ -f $WS_STATE ]] || return 0
  [[ -n ${WS_CERT:-} && -f ${WS_CERT:-} ]] || return 0
  case $WS_CERT in
    /root/*|"${CONFIG_DIR}"/*) ;;
    *)
      fix_cert_permissions "$(dirname "$WS_CERT")" "$WS_CERT" "${WS_KEY:-}"
      return 0
      ;;
  esac
  local newdir cert key id
  id=${WS_DOMAIN:-$WS_IP_CERT_ID}
  newdir=$(xray_cert_dir "$id")
  install -d -m 750 "$newdir"
  cert="$newdir/fullchain.pem"; key="$newdir/privkey.pem"
  cp -a "$WS_CERT" "$cert"
  [[ -f ${WS_KEY:-} ]] && cp -a "$WS_KEY" "$key"
  fix_cert_permissions "$newdir" "$cert" "$key"
  WS_CERT=$cert; WS_KEY=$key
  write_ws_state
  log "WS+TLS 证书已迁移: $newdir"
}

# 证书 SHA-256 指纹（十六进制，小写，无冒号）；新版 Xray 用它替代 allowInsecure
ws_cert_sha256() {
  openssl x509 -in "$1" -outform der 2>/dev/null | sha256sum | awk '{print $1}'
}

issue_selfsigned_ws_cert() {
  local ip=$1 certdir
  is_ipv4 "$ip" || fail "自签证书需要公网 IP"
  certdir=$(xray_cert_dir "$WS_IP_CERT_ID")
  install -d -m 750 "$certdir"
  WS_CERT="$certdir/fullchain.pem"
  WS_KEY="$certdir/privkey.pem"
  if [[ -f $WS_CERT && -f $WS_KEY ]] &&
     openssl x509 -in "$WS_CERT" -checkend 86400 -noout >/dev/null 2>&1 &&
     openssl x509 -in "$WS_CERT" -noout -ext subjectAltName 2>/dev/null | grep -q "IP Address:${ip}"; then
    log "复用已有自签证书"
  else
    openssl req -x509 -newkey rsa:2048 -sha256 -nodes \
      -keyout "$WS_KEY" -out "$WS_CERT" \
      -days 3650 -subj "/CN=${ip}" -addext "subjectAltName=IP:${ip}" >/dev/null 2>&1 ||
      fail "生成自签证书失败"
    log "已生成自签证书: $certdir"
  fi
  fix_cert_permissions "$certdir" "$WS_CERT" "$WS_KEY" || fail "证书权限修复失败: $certdir"
}

# 生成本管理 inbound JSON 对象（单行/多行均可）
_xray_reality_inbound_json() {
  cat <<EOF
{
  "tag": "${MANAGED_TAG_REALITY}", "listen": "0.0.0.0", "port": ${REALITY_PORT},
  "protocol": "vless",
  "settings": { "clients": [{ "id": "${REALITY_UUID}", "flow": "xtls-rprx-vision", "email": "reality" }], "decryption": "none" },
  "streamSettings": {
    "network": "tcp", "security": "reality",
    "realitySettings": { "show": false, "dest": "${REALITY_TARGET}", "xver": 0, "serverNames": ["${REALITY_SNI}"], "privateKey": "${REALITY_PRIV}", "shortIds": ["${REALITY_SHORT}"] }
  },
  "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] }
}
EOF
}

_xray_ws_inbound_json() {
  cat <<EOF
{
  "tag": "${MANAGED_TAG_WS}", "listen": "0.0.0.0", "port": ${WS_PORT},
  "protocol": "vless",
  "settings": { "clients": [{ "id": "${WS_UUID}", "email": "ws" }], "decryption": "none" },
  "streamSettings": {
    "network": "ws", "security": "tls",
    "tlsSettings": { "certificates": [{ "certificateFile": "${WS_CERT}", "keyFile": "${WS_KEY}" }] },
    "wsSettings": { "path": "${WS_PATH}" }
  },
  "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] }
}
EOF
}

# 单文件：结构化增删本管理 tag，保留其余 inbound
_xray_merge_file() {
  local dest=$1 want_reality=$2 want_ws=$3
  local tmp bak rf cf
  command -v python3 >/dev/null 2>&1 || fail "写入 Xray 配置需要 python3"
  [[ -f $dest ]] || printf '%s\n' '{"log":{"loglevel":"warning"},"inbounds":[],"outbounds":[{"protocol":"freedom","tag":"direct"},{"protocol":"blackhole","tag":"block"}]}' >"$dest"
  bak=$(mktemp "${dest}.bak.XXXXXX")
  cp -a "$dest" "$bak"
  # Xray 根据文件扩展名判断配置格式；临时文件也必须保留 .json 后缀。
  tmp=$(mktemp "${dest}.tmp.XXXXXX.json")
  rf=$(mktemp); cf=$(mktemp)
  [[ $want_reality == 1 ]] && _xray_reality_inbound_json >"$rf" || : >"$rf"
  [[ $want_ws == 1 ]] && _xray_ws_inbound_json >"$cf" || : >"$cf"
  if ! WANT_R=$want_reality WANT_C=$want_ws TAG_R=$MANAGED_TAG_REALITY TAG_C=$MANAGED_TAG_WS \
    DEST="$dest" OUT="$tmp" RF="$rf" CF="$cf" python3 - <<'PY'
import json, os
path = os.environ["DEST"]
out = os.environ["OUT"]
tag_r = os.environ["TAG_R"]
tag_c = os.environ["TAG_C"]
want_r = os.environ.get("WANT_R") == "1"
want_c = os.environ.get("WANT_C") == "1"
with open(path, encoding="utf-8") as f:
    cfg = json.load(f)
if not isinstance(cfg, dict):
    raise ValueError("Xray 配置顶层必须是对象，拒绝覆盖未知结构")
ibs = [ib for ib in (cfg.get("inbounds") or []) if not (isinstance(ib, dict) and ib.get("tag") in (tag_r, tag_c))]
if want_r:
    with open(os.environ["RF"], encoding="utf-8") as f:
        ibs.append(json.load(f))
if want_c:
    with open(os.environ["CF"], encoding="utf-8") as f:
        ibs.append(json.load(f))
cfg["inbounds"] = ibs
if "outbounds" not in cfg or not cfg["outbounds"]:
    cfg["outbounds"] = [
        {"protocol": "freedom", "tag": "direct"},
        {"protocol": "blackhole", "tag": "block"},
    ]
if "log" not in cfg:
    cfg["log"] = {"loglevel": "warning"}
with open(out, "w", encoding="utf-8") as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY
  then
    rm -f "$tmp" "$rf" "$cf"
    mv -f "$bak" "$dest"
    fail "Xray 配置合并失败，已回滚"
  fi
  rm -f "$rf" "$cf"
  if ! xray_validate_path "$tmp" file; then
    rm -f "$tmp"
    mv -f "$bak" "$dest"
    fail "Xray 配置验证失败，已回滚"
  fi
  xray_apply_perms "$tmp"
  mv -f "$tmp" "$dest"
  rm -f "$bak"
}

_xray_write_confdir() {
  local dir=$1 want_reality=$2 want_ws=$3
  local fr fc bak_r bak_c
  install -d -m 755 "$dir"
  fr="$dir/$MANAGED_FILE_REALITY"
  fc="$dir/$MANAGED_FILE_WS"
  bak_r=""; bak_c=""
  [[ -f $fr ]] && { bak_r=$(mktemp); cp -a "$fr" "$bak_r"; }
  [[ -f $fc ]] && { bak_c=$(mktemp); cp -a "$fc" "$bak_c"; }

  rollback_confdir() {
    [[ -n $bak_r ]] && mv -f "$bak_r" "$fr" || rm -f "$fr"
    [[ -n $bak_c ]] && mv -f "$bak_c" "$fc" || rm -f "$fc"
  }

  if [[ $want_reality == 1 ]]; then
    _xray_reality_inbound_json >"$fr.tmp"
    # confdir 文件通常是完整 config 片段或仅 inbound 数组——使用含 inbounds 的小文件
    FR_TMP="$fr.tmp" FR="$fr" python3 - <<'PY' || { rollback_confdir; fail "写入 REALITY confdir 失败"; }
import json, os
with open(os.environ["FR_TMP"], encoding="utf-8") as src:
    ib = json.load(src)
with open(os.environ["FR"], "w", encoding="utf-8") as dst:
    json.dump({"inbounds": [ib]}, dst, indent=2)
with open(os.environ["FR"], "a", encoding="utf-8") as dst:
    dst.write("\n")
PY
    rm -f "$fr.tmp"
    xray_apply_perms "$fr"
  else
    rm -f "$fr"
  fi
  if [[ $want_ws == 1 ]]; then
    _xray_ws_inbound_json >"$fc.tmp"
    FC_TMP="$fc.tmp" FC="$fc" python3 - <<'PY' || { rollback_confdir; fail "写入 WS confdir 失败"; }
import json, os
with open(os.environ["FC_TMP"], encoding="utf-8") as src:
    ib = json.load(src)
with open(os.environ["FC"], "w", encoding="utf-8") as dst:
    json.dump({"inbounds": [ib]}, dst, indent=2)
with open(os.environ["FC"], "a", encoding="utf-8") as dst:
    dst.write("\n")
PY
    rm -f "$fc.tmp"
    xray_apply_perms "$fc"
  else
    rm -f "$fc"
  fi
  if ! xray_validate_path "$dir" dir; then
    rollback_confdir
    fail "Xray confdir 验证失败，已回滚"
  fi
  rm -f "$bak_r" "$bak_c"
}

# 写入/更新本管理 inbound；意图以 state 文件为准；保留非本项目配置
build_xray_config() {
  local want_reality=0 want_ws=0
  xray_discover
  load_state_safe "$REALITY_STATE"
  load_state_safe "$WS_STATE"
  migrate_ws_certs_if_needed

  [[ -f $REALITY_STATE ]] && want_reality=1
  [[ -f $WS_STATE ]] && want_ws=1

  if [[ $XRAY_LAYOUT == dir && -n $XRAY_CONF_DIR ]]; then
    _xray_write_confdir "$XRAY_CONF_DIR" "$want_reality" "$want_ws"
  else
    local dest=${XRAY_CONFIG_FILE:-$XRAY_CONFIG}
    install -d -m 755 "$(dirname "$dest")"
    _xray_merge_file "$dest" "$want_reality" "$want_ws"
    XRAY_CONFIG=$dest
  fi
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

reality_public_from_private() {
  local priv=$1 bin out
  bin=$(xray_binary_path) || return 1
  out=$("$bin" x25519 -i "$priv" 2>/dev/null) || return 1
  printf '%s\n' "$out" | awk -F': ' '/Password \(PublicKey\)|Public key|PublicKey/ {print $2; exit}'
}

# 从真实 Xray 配置恢复 REALITY 参数（更新/重装时用，show 路径不调用）
# 成功时设置 REALITY_PORT/UUID/SNI/TARGET/PRIV/PUB/SHORT 并 return 0
recover_reality_from_live() {
  local f raw
  while IFS= read -r f; do
    [[ -r $f ]] || continue
    if command -v jq >/dev/null 2>&1; then
      raw=$(jq -c '
        [.inbounds[]? // empty | select(type=="object")
          | select(.tag=="vless-reality")] | .[0] // empty
      ' "$f" 2>/dev/null || true)
      [[ -n $raw && $raw != null ]] || continue
      REALITY_PORT=$(printf '%s' "$raw" | jq -r '.port // empty')
      REALITY_UUID=$(printf '%s' "$raw" | jq -r '.settings.clients[0].id // empty')
      REALITY_SNI=$(printf '%s' "$raw" | jq -r '.streamSettings.realitySettings.serverNames[0] // empty')
      REALITY_TARGET=$(printf '%s' "$raw" | jq -r '.streamSettings.realitySettings.dest // empty')
      REALITY_PRIV=$(printf '%s' "$raw" | jq -r '.streamSettings.realitySettings.privateKey // empty')
      REALITY_SHORT=$(printf '%s' "$raw" | jq -r '.streamSettings.realitySettings.shortIds[0] // empty')
    elif command -v python3 >/dev/null 2>&1; then
      raw=$(FILE=$f python3 - <<'PY' 2>/dev/null || true
import json, os
with open(os.environ["FILE"], encoding="utf-8") as fh:
    data = json.load(fh)
ibs = data.get("inbounds") or []
for ib in ibs:
    if not isinstance(ib, dict):
        continue
    ss = ib.get("streamSettings") or {}
    if ib.get("tag") == "vless-reality":
        rs = ss.get("realitySettings") or {}
        clients = ((ib.get("settings") or {}).get("clients") or [{}])
        print(ib.get("port") or "")
        print((clients[0] or {}).get("id") or "")
        names = rs.get("serverNames") or [""]
        print(names[0] if names else "")
        print(rs.get("dest") or "")
        print(rs.get("privateKey") or "")
        sids = rs.get("shortIds") or [""]
        print(sids[0] if sids else "")
        break
PY
)
      [[ -n $raw ]] || continue
      REALITY_PORT=$(printf '%s\n' "$raw" | sed -n '1p')
      REALITY_UUID=$(printf '%s\n' "$raw" | sed -n '2p')
      REALITY_SNI=$(printf '%s\n' "$raw" | sed -n '3p')
      REALITY_TARGET=$(printf '%s\n' "$raw" | sed -n '4p')
      REALITY_PRIV=$(printf '%s\n' "$raw" | sed -n '5p')
      REALITY_SHORT=$(printf '%s\n' "$raw" | sed -n '6p')
    else
      continue
    fi
    # 公钥：优先 info 缓存，否则尝试 xray x25519 派生（若支持）
    REALITY_PUB=$(info_get_field "$XRAY_INFO" "PublicKey" 2>/dev/null || true)
    [[ -n $REALITY_PUB ]] || REALITY_PUB=$(info_get_field "$XRAY_INFO" "公钥" 2>/dev/null || true)
    [[ -n $REALITY_PUB ]] || REALITY_PUB=$(reality_public_from_private "${REALITY_PRIV:-}" 2>/dev/null || true)
    if [[ -n ${REALITY_PRIV:-} && -n ${REALITY_SHORT:-} && -n ${REALITY_UUID:-} ]]; then
      return 0
    fi
  done < <(xray_list_config_files 2>/dev/null || true)
  return 1
}

info_get_field() {
  local file=$1 key=$2 line
  [[ -f $file ]] || return 0
  while IFS= read -r line || [[ -n $line ]]; do
    if [[ $line =~ ^[[:space:]]*${key}[[:space:]]*[:：][[:space:]]*(.*)$ ]]; then
      printf '%s\n' "${BASH_REMATCH[1]}"
      return 0
    fi
  done <"$file"
}

install_reality() {
  parse_reality_args "$@"
  prepare_env

  local priv pub short ip link reused=0
  local arg_port=$REALITY_PORT arg_sni=$REALITY_SNI arg_target=$REALITY_TARGET arg_uuid=$REALITY_UUID
  local live_exists=0

  managed_component_present reality && live_exists=1

  # 1) 优先 state 管理缓存  2) 再从真实服务配置恢复  3) 全新安装
  if [[ -f $REALITY_STATE ]]; then
    load_state_safe "$REALITY_STATE"
    if [[ -n ${REALITY_PRIV:-} && -n ${REALITY_PUB:-} && ${REALITY_PUB:-} != unknown && -n ${REALITY_SHORT:-} ]]; then
      priv=$REALITY_PRIV; pub=$REALITY_PUB; short=$REALITY_SHORT
      reused=1
      [[ -n $arg_port ]] && REALITY_PORT=$arg_port
      [[ -n $arg_sni ]] && REALITY_SNI=$arg_sni
      [[ -n $arg_target ]] && REALITY_TARGET=$arg_target
      [[ -n $arg_uuid ]] && REALITY_UUID=$arg_uuid
      log "复用已有 REALITY 配置（密钥/参数）；CLI 指定项优先"
    fi
  fi

  if (( reused == 0 && live_exists )); then
    if recover_reality_from_live; then
      priv=$REALITY_PRIV
      short=$REALITY_SHORT
      pub=${REALITY_PUB:-}
      reused=1
      [[ -n $arg_port ]] && REALITY_PORT=$arg_port
      [[ -n $arg_sni ]] && REALITY_SNI=$arg_sni
      [[ -n $arg_target ]] && REALITY_TARGET=$arg_target
      [[ -n $arg_uuid ]] && REALITY_UUID=$arg_uuid
      log "从真实服务配置恢复 REALITY 参数"
      # 无法得到对应公钥时停止，避免生成 pbk=unknown 的无效分享链接。
      [[ -n $pub && $pub != unknown ]] || fail "无法从旧私钥生成 PublicKey，已停止写入无效链接"
    else
      fail "无法读取旧节点参数，请先修复配置"
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
    "$REALITY_STATE" REALITY_PORT "$WS_STATE" WS_PORT
  install_xray_core
  xray_discover

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
  enable_proxy_auto_update
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

# ---------- VLESS + WS + TLS ----------
parse_ws_args() {
  WS_PORT=; WS_DOMAIN=; WS_PATH=
  WS_UUID=; WS_EMAIL=; WS_SNI=; WS_ADDR=
  WS_RANDOM_PORT=0
  while [[ $# -gt 0 ]]; do
    case $1 in
      --port) require_arg "$1" "${2:-}"; WS_PORT=$2; shift 2 ;;
      --random-port) WS_RANDOM_PORT=1; WS_PORT=; shift ;;
      --domain) require_arg "$1" "${2:-}"; WS_DOMAIN=$2; shift 2 ;;
      --path) require_arg "$1" "${2:-}"; WS_PATH=$2; shift 2 ;;
      --uuid) require_arg "$1" "${2:-}"; WS_UUID=$2; shift 2 ;;
      --email) require_arg "$1" "${2:-}"; WS_EMAIL=$2; shift 2 ;;
      --public-ip) require_arg "$1" "${2:-}"; PUBLIC_IP=$2; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) fail "未知 WS+TLS 参数: $1" ;;
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
    if openssl x509 -in "$certdir/fullchain.pem" -checkend 604800 -checkhost "$domain" -noout 2>/dev/null; then
      log "使用已有证书: $certdir"
      WS_CERT="$certdir/fullchain.pem"; WS_KEY="$certdir/privkey.pem"
      if ! fix_cert_permissions "$certdir" "$WS_CERT" "$WS_KEY"; then
        fail "已有证书权限修复失败: $certdir"
      fi
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
  if ! "$acme" --set-default-ca --server letsencrypt >/dev/null; then
    if ((restarted_xray)); then systemctl start xray || true; fi
    fail "无法设置 Let's Encrypt CA"
  fi
  if ! "$acme" --issue -d "$domain" --standalone --keylength ec-256; then
    if ((restarted_xray)); then
      systemctl start xray || true
    fi
    fail "证书申请失败（域名解析/80 端口/防火墙）"
  fi
  if ! "$acme" --install-cert -d "$domain" --ecc \
      --fullchain-file "$certdir/fullchain.pem" \
      --key-file "$certdir/privkey.pem" \
      --reloadcmd "systemctl restart xray 2>/dev/null || true"; then
    if ((restarted_xray)); then systemctl start xray || true; fi
    fail "证书安装失败: $certdir"
  fi
  WS_CERT="$certdir/fullchain.pem"; WS_KEY="$certdir/privkey.pem"
  if ! fix_cert_permissions "$certdir" "$WS_CERT" "$WS_KEY"; then
    if ((restarted_xray)); then systemctl start xray || true; fi
    fail "证书权限修复失败: $certdir"
  fi
  if ((restarted_xray)); then
    systemctl start xray 2>/dev/null || true
  fi
  ok "证书已就绪: $certdir"
}

install_ws() {
  parse_ws_args "$@"
  prepare_env

  local arg_port=$WS_PORT arg_path=$WS_PATH arg_uuid=$WS_UUID
  local arg_random=$WS_RANDOM_PORT
  local want_domain=$WS_DOMAIN
  local old_domain old_path old_uuid old_port
  local ip_mode=0 cert_id link path_enc addr
  old_domain=$(state_get "$WS_STATE" WS_DOMAIN)
  old_path=$(state_get "$WS_STATE" WS_PATH)
  old_uuid=$(state_get "$WS_STATE" WS_UUID)
  old_port=$(state_get "$WS_STATE" WS_PORT)
  [[ -z $want_domain ]] && ip_mode=1
  if [[ -f $WS_STATE && $old_domain == "$want_domain" ]]; then
    [[ -n $arg_path ]] || WS_PATH=$old_path
    [[ -n $arg_uuid ]] || WS_UUID=$old_uuid
    if ((ip_mode)); then
      log "复用已有 WS+TLS 节点参数（IP 直连）"
    else
      log "复用已有 WS+TLS 节点参数（同域名）"
    fi
  fi

  WS_PORT=$(ws_pick_port "$want_domain" "$old_domain" "$old_port" "$arg_port" "$arg_random")
  if [[ -z ${WS_PORT:-} ]]; then
    WS_PORT=$(random_ws_port)
    log "随机 TCP 端口: $WS_PORT"
  elif [[ -n $old_port && $WS_PORT == "$old_port" && $arg_random != 1 && -z $arg_port ]]; then
    log "保持已有 TLS 端口: $WS_PORT"
  fi
  validate_port "$WS_PORT"
  [[ -z ${WS_UUID:-} ]] || validate_uuid "$WS_UUID"
  [[ -n ${WS_UUID:-} ]] || WS_UUID=$(random_uuid)
  [[ -n ${WS_PATH:-} ]] || WS_PATH=$(random_path)
  [[ $WS_PATH == /* ]] || WS_PATH="/$WS_PATH"
  validate_ws_path "$WS_PATH"

  if ((ip_mode)); then
    WS_ADDR=$(resolve_public_ip)
    WS_SNI=
    cert_id=$WS_IP_CERT_ID
    log "未指定域名，使用公网 IP 直连 + 自签 TLS"
  else
    validate_domain "$WS_DOMAIN"
    WS_SNI=$WS_DOMAIN
    WS_ADDR=$WS_DOMAIN
    cert_id=$WS_DOMAIN
    [[ -n ${WS_EMAIL:-} ]] || WS_EMAIL="admin@${WS_DOMAIN}"
    is_safe_token "$WS_EMAIL" || fail "邮箱含非法字符"
  fi

  ensure_port_available "$WS_PORT" tcp xray "Xray/WS+TLS" \
    "$WS_STATE" WS_PORT "$REALITY_STATE" REALITY_PORT
  install_xray_core
  xray_discover

  if ((ip_mode)); then
    issue_selfsigned_ws_cert "$WS_ADDR"
    WS_PIN=$(ws_cert_sha256 "$WS_CERT")
    [[ $WS_PIN =~ ^[A-Fa-f0-9]{64}$ ]] || fail "无法计算自签证书指纹"
  else
    issue_cert "$WS_DOMAIN" "$WS_EMAIL"
    WS_PIN=
  fi

  write_ws_state

  build_xray_config
  restart_svc xray "Xray"
  enable_proxy_auto_update
  open_port "$WS_PORT" tcp

  path_enc=$(printf %s "$WS_PATH" | sed 's|/|%2F|g')
  addr=$WS_ADDR
  if ((ip_mode)); then
    link="vless://${WS_UUID}@${addr}:${WS_PORT}?encryption=none&security=tls&type=ws&pinnedPeerCertSha256=${WS_PIN}&path=${path_enc}#WS-IP"
    save_info "$WS_INFO" \
      "Xray VLESS + WS + TLS（IP 直连）" "" \
      "连接地址: ${addr}" "端口:   ${WS_PORT}" "UUID:   ${WS_UUID}" \
      "传输:   WebSocket" "TLS:    自签（证书已固定）" \
      "证书指纹: ${WS_PIN}" "Path:   ${WS_PATH}" \
      "" "分享链接:" "${link}" "" \
      "说明: 不用自己的域名；客户端填写 VPS IP。链接已带证书指纹，新版客户端自动信任该证书。"
    ok "VLESS + WS + TLS 节点安装完成（IP 直连）"
  else
    link="vless://${WS_UUID}@${WS_DOMAIN}:${WS_PORT}?encryption=none&security=tls&type=ws&host=${WS_DOMAIN}&sni=${WS_DOMAIN}&path=${path_enc}#WS-${WS_DOMAIN}"
    save_info "$WS_INFO" \
      "Xray VLESS + WS + TLS（直连）" "" \
      "连接地址: ${WS_DOMAIN}" "域名/SNI: ${WS_DOMAIN}" "端口:   ${WS_PORT}" "UUID:   ${WS_UUID}" \
      "传输:   WebSocket" "TLS:    开启" "Host:   ${WS_DOMAIN}" "SNI:    ${WS_DOMAIN}" "Path:   ${WS_PATH}" \
      "" "分享链接:" "${link}" "" "说明: 直连模式使用域名连接本机 WS+TLS。"
    ok "VLESS + WS + TLS 节点安装完成（直连）"
  fi
  print_block "节点信息" "$WS_INFO"
}

# ---------- Hysteria2 ----------
hy2_arch() {
  case $(uname -m) in
    x86_64|amd64) echo amd64 ;;
    i386|i486|i586|i686) echo 386 ;;
    aarch64|arm64) echo arm64 ;;
    armv7l|armv7) echo armv7 ;;
    s390x|ppc64le|mips64le|riscv64|loongarch64) uname -m ;;
    *) return 1 ;;
  esac
}

hy2_version_of() {
  "$1" version 2>/dev/null | grep -Eo 'v[0-9]+\.[0-9]+\.[0-9]+' | head -n1
}

hy2_latest_version() {
  local data version api=$HY2_UPDATE_API
  [[ $api == https://* ]] || return 1
  if [[ $api != *'arch='* ]]; then
    if [[ $api == *'?'* ]]; then
      api="${api}&arch=$(hy2_arch)" || return 1
    else
      api="${api}?arch=$(hy2_arch)" || return 1
    fi
  fi
  data=$(curl --proto '=https' --proto-redir '=https' -fsSL --retry 3 --connect-timeout 10 --max-time 60 "$api") || return 1
  version=$(sed -nE 's/.*"lver"[[:space:]]*:[[:space:]]*"(v[0-9]+\.[0-9]+\.[0-9]+)".*/\1/p' <<<"$data" | head -n1)
  [[ $version =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  printf '%s\n' "$version"
}

hy2_version_lt() {
  [[ $1 != "$2" && $(printf '%s\n%s\n' "${1#v}" "${2#v}" | sort -V | tail -n1) == "${2#v}" ]]
}

hy2_record_update() {
  local result=$1 current=${2:-unknown} latest=${3:-unknown}
  ensure_dirs
  write_kv_file "$HY2_UPDATE_STATE" \
    "LAST_CHECK=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "RESULT=${result}" "CURRENT=${current}" "LATEST=${latest}"
}

hy2_download_verified() {
  local version=$1 arch=$2 dest=$3 work hashes asset expected actual
  asset="hysteria-linux-${arch}"
  work=$(mktemp -d /tmp/${APP_NAME}.hy2.XXXXXX)
  hashes="$work/hashes.txt"
  if ! curl_download "${HY2_RELEASE_BASE}/${version}/hashes.txt" "$hashes" ||
     ! curl_download "${HY2_RELEASE_BASE}/${version}/${asset}" "$work/$asset"; then
    rm -rf -- "$work"
    return 1
  fi
  expected=$(awk -v name="build/${asset}" '$2 == name {print $1; exit}' "$hashes")
  actual=$(sha256_file "$work/$asset")
  if ! is_valid_sha256 "$expected" || [[ ${actual,,} != "${expected,,}" ]]; then
    rm -rf -- "$work"
    return 2
  fi
  install -m 755 "$work/$asset" "$dest"
  rm -rf -- "$work"
}

update_hy2_core() {
  local mode=${1:-manual} current latest arch candidate backup was_active=0
  mode=${mode#--}
  require_root
  require_systemd
  ensure_dirs
  for cmd in curl sha256sum sort flock; do
    command -v "$cmd" >/dev/null || fail "更新 Hysteria2 缺少命令: $cmd"
  done
  [[ -x $HY2_BIN ]] || fail "Hysteria2 尚未安装"
  install -d -m 755 "$(dirname "$HY2_UPDATE_LOCK")"
  exec 9>"$HY2_UPDATE_LOCK"
  if ! flock -n 9; then
    [[ $mode == auto ]] || warn "已有 Hysteria2 更新任务运行中"
    return 0
  fi

  current=$(hy2_version_of "$HY2_BIN") || true
  [[ -n $current ]] || { hy2_record_update invalid-version; fail "无法识别当前 Hysteria2 版本"; }
  latest=$(hy2_latest_version) || { hy2_record_update check-failed "$current"; fail "无法获取 Hysteria2 最新稳定版"; }
  if ! hy2_version_lt "$current" "$latest"; then
    hy2_record_update current "$current" "$latest"
    [[ $mode == auto ]] || ok "Hysteria2 已是最新稳定版: ${current}"
    return 0
  fi
  arch=$(hy2_arch) || { hy2_record_update unsupported-arch "$current" "$latest"; fail "不支持的 CPU 架构: $(uname -m)"; }
  candidate=$(mktemp /tmp/${APP_NAME}.hy2-bin.XXXXXX)
  backup=$(mktemp /tmp/${APP_NAME}.hy2-old.XXXXXX)
  cp -p "$HY2_BIN" "$backup"
  if ! hy2_download_verified "$latest" "$arch" "$candidate"; then
    rm -f -- "$candidate" "$backup"
    hy2_record_update verify-failed "$current" "$latest"
    fail "Hysteria2 下载或 SHA256 校验失败"
  fi
  if ! hy2_validate_candidate "$candidate" "$mode"; then
    rm -f -- "$candidate" "$backup"
    hy2_record_update invalid-candidate "$current" "$latest"
    fail "Hysteria2 新版二进制无法运行，保留旧版"
  fi
  systemctl is-active --quiet hysteria-server 2>/dev/null && was_active=1
  if ! install -m 755 "$candidate" "${HY2_BIN}.new" || ! mv -f "${HY2_BIN}.new" "$HY2_BIN"; then
    rm -f -- "$candidate" "${HY2_BIN}.new" "$backup"
    hy2_record_update replace-failed "$current" "$latest"
    fail "Hysteria2 替换失败，保留旧版"
  fi
  rm -f -- "$candidate"
  if ((was_active)); then
    systemctl restart hysteria-server || true
    sleep 2
    if ! systemctl is-active --quiet hysteria-server; then
      install -m 755 "$backup" "$HY2_BIN"
      systemctl restart hysteria-server || true
      rm -f -- "$backup"
      hy2_record_update rolled-back "$current" "$latest"
      fail "新版启动失败，已恢复 ${current}"
    fi
  elif [[ $mode != install ]] && systemctl cat hysteria-server >/dev/null 2>&1; then
    # 原服务未运行时也做一次短暂启动验证，验证后恢复原来的停止状态。
    if ! systemctl start hysteria-server; then
      install -m 755 "$backup" "$HY2_BIN"
      rm -f -- "$backup"
      hy2_record_update rolled-back "$current" "$latest"
      fail "新版启动验证失败，已恢复 ${current}"
    fi
    sleep 2
    if ! systemctl is-active --quiet hysteria-server; then
      systemctl stop hysteria-server 2>/dev/null || true
      install -m 755 "$backup" "$HY2_BIN"
      rm -f -- "$backup"
      hy2_record_update rolled-back "$current" "$latest"
      fail "新版启动验证失败，已恢复 ${current}"
    fi
    systemctl stop hysteria-server 2>/dev/null || true
  fi
  rm -f -- "$backup"
  hy2_record_update updated "$current" "$latest"
  ok "Hysteria2 已更新: ${current} → ${latest}"
}

enable_hy2_auto_update() {
  cat >"$HY2_UPDATE_SERVICE" <<EOF
[Unit]
Description=syw-vps proxy core stable update
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
TimeoutStartSec=15min
ExecStart=/bin/bash /usr/local/lib/syw-vps/proxy.sh update-cores --auto
EOF
  cat >"$HY2_UPDATE_TIMER" <<'EOF'
[Unit]
Description=Weekly Xray and Hysteria2 stable update check

[Timer]
OnCalendar=Mon *-*-* 04:00:00
RandomizedDelaySec=6h
Persistent=true
Unit=syw-hy2-update.service

[Install]
WantedBy=timers.target
EOF
  chmod 644 "$HY2_UPDATE_SERVICE" "$HY2_UPDATE_TIMER"
  systemctl daemon-reload
  systemctl enable --now syw-hy2-update.timer >/dev/null
}

enable_proxy_auto_update() {
  enable_hy2_auto_update
}

update_hy2_manual() {
  update_hy2_core manual
  enable_hy2_auto_update
  ok "Hysteria2 每周自动更新已启用"
}

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
    log "检查 Hysteria2 核心更新..."
    update_hy2_core install
  fi
  command -v hysteria >/dev/null || fail "Hysteria2 安装失败"
}

configure_hy2_service() {
  install -d -m 755 "$(dirname "$HY2_DROPIN")"
  # 降权为 hysteria 用户；UDP/443 等特权端口需 CAP_NET_BIND_SERVICE
  cat >"$HY2_DROPIN" <<EOF
# syw-vps-managed=vps-proxy
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
  enable_hy2_auto_update
  open_port "$HY2_PORT" udp

  link="hysteria2://${HY2_PASSWORD}@${ip}:${HY2_PORT}/?sni=${HY2_DOMAIN}&insecure=1&pinSHA256=${cert_sha}#HY2-${ip}"
  save_info "$HY2_INFO"     "Hysteria2" ""     "地址:     ${ip}" "端口:     ${HY2_PORT}" "密码:     ${HY2_PASSWORD}"     "SNI:      ${HY2_DOMAIN}" "证书指纹: ${cert_sha}" "协议:     UDP" "" "分享链接:" "${link}"
  ok "Hysteria2 安装完成"
  print_block "节点信息" "$HY2_INFO"
}

# ---------- 展示 / 卸载 ----------
# show_component 返回码协议：
#   0  已显示真实节点或配置异常组件
#   1  完全没有该组件（正常，不触发 ERR）
#   2  只有残留信息文件（正常，不触发 ERR）
#   其他  真正执行错误，上抛
_show_info_handle_component() {
  # $1=显示名 $2=state $3=info $4=unit $5=bin $6=port_key $7=comp
  # 通过 nameref 更新 found/residual；未知 rc 则 return 该值
  local name=$1 state_file=$2 info_file=$3 unit=$4 bin=$5 port_key=$6 comp=$7
  local rc=0
  if show_component "$name" "$state_file" "$info_file" "$unit" "$bin" "$port_key" "$comp"; then
    rc=0
  else
    rc=$?
  fi
  case $rc in
    0) found=1 ;;
    1) ;; # 无此组件，静默跳过
    2) residual=1 ;;
    *) return "$rc" ;;
  esac
  return 0
}

show_info() {
  local found=0 residual=0
  printf '\n  %s节点与状态%s\n' "$B$CYN" "$R"

  # 用 if/else 接返回码，避免 set -e / ERR trap 把 rc=1（无组件）当致命错误
  # 从而在「有 REALITY、无 WS+TLS」时仍能继续展示 Hysteria2
  migrate_legacy_cdn_state
  _show_info_handle_component "REALITY" "$REALITY_STATE" "$XRAY_INFO" xray xray REALITY_PORT reality
  _show_info_handle_component "VLESS / WS+TLS" "$WS_STATE" "$WS_INFO" xray xray WS_PORT ws
  _show_info_handle_component "Hysteria2" "$HY2_STATE" "$HY2_INFO" hysteria-server hysteria HY2_PORT hy2

  # 有真实节点/异常组件时不显示「暂无」；仅残留时也不追加「暂无」
  if (( found == 0 && residual == 0 )); then
    printf '  %s○%s  暂无代理\n' "$D" "$R"
  fi
  printf '\n'
}

uninstall_xray_core() {
  # 仅当现网已无任何 inbound（含第三方、confdir）时才允许 purge。
  require_root
  require_systemd
  xray_discover
  command -v python3 >/dev/null 2>&1 || fail "卸载 Xray 核心需要 python3 来确认现有 inbound"
  local f n=0 count
  while IFS= read -r f; do
    [[ -r $f ]] || continue
    count=$(FILE="$f" python3 - <<'PY'
import json, os
try:
    with open(os.environ["FILE"], encoding="utf-8") as stream:
        data = json.load(stream)
    if isinstance(data, dict):
        print(len(data.get("inbounds") or []))
    elif isinstance(data, list):
        print(len(data))
    else:
        print(1)
except Exception:
    print(1)
PY
    ) || fail "无法确认 Xray 配置归属: $f"
    n=$((n + count))
  done < <(xray_list_config_files 2>/dev/null || true)
  if (( n > 0 )); then
    fail "无法确认归属或仍有其他 inbound，拒绝删除 Xray 主程序（请先移除配置）"
  fi
  if xray_binary_path >/dev/null 2>&1; then
    run_verified_script "$XRAY_INSTALLER_URL" "$XRAY_INSTALLER_SHA256" remove --purge ||
      fail "Xray 卸载器执行失败"
  fi
  if [[ $XRAY_LAYOUT == file && -n ${XRAY_CONFIG_FILE:-} ]]; then
    rm -f -- "$XRAY_CONFIG_FILE"
  fi
}

# 安全重启；失败时提示并返回非 0（调用方可回滚配置）
restart_svc_or_fail() {
  local unit=$1 name=$2
  systemctl enable "$unit" >/dev/null 2>&1 || true
  if ! systemctl restart "$unit"; then
    hint_restore "$unit" "$name"
    return 1
  fi
  local i
  for ((i = 1; i <= 8; i++)); do
    sleep 1
    systemctl is-active --quiet "$unit" && { ok "$name 运行中"; return 0; }
  done
  hint_restore "$unit" "$name"
  return 1
}

# 卸载期间仅保留同目录临时快照，成功后立即删除。
uninstall_snapshot_file() {
  local src=$1 snap
  [[ -f $src ]] || return 0
  snap=$(mktemp "$src.uninstall.XXXXXX") || return 1
  cp -p -- "$src" "$snap" || { rm -f -- "$snap"; return 1; }
  printf '%s\n' "$snap"
}

uninstall_restore_snapshot() {
  local dst=$1 snap=$2
  [[ -n $snap && -f $snap ]] || return 0
  cp -p -- "$snap" "$dst"
}

uninstall_reality() {
  require_root
  managed_component_present reality || { warn "未找到本项目管理的 REALITY，未执行卸载"; return 0; }
  xray_discover
  local dest=${XRAY_CONFIG_FILE:-$XRAY_CONFIG} state_snap="" info_snap=""
  state_snap=$(uninstall_snapshot_file "$REALITY_STATE") || fail "无法创建临时回滚快照"
  info_snap=$(uninstall_snapshot_file "$XRAY_INFO") || { rm -f -- "$state_snap"; fail "无法创建临时回滚快照"; }
  [[ -f $dest ]] && cp -a "$dest" "$dest.pre-uninstall-reality" || true
  rm -f "$REALITY_STATE" "$XRAY_INFO"
  # 按剩余 state 重建，精确去掉本管理 REALITY inbound，保留 WS+TLS/第三方
  if ! build_xray_config; then
    uninstall_restore_snapshot "$REALITY_STATE" "$state_snap"
    uninstall_restore_snapshot "$XRAY_INFO" "$info_snap"
    [[ -f "$dest.pre-uninstall-reality" ]] && mv -f "$dest.pre-uninstall-reality" "$dest"
    rm -f -- "$state_snap" "$info_snap"
    fail "移除 REALITY 配置失败，已回滚"
  fi
  if systemctl is-enabled xray >/dev/null 2>&1 || systemctl is-active xray >/dev/null 2>&1; then
    if ! restart_svc_or_fail xray "Xray"; then
      uninstall_restore_snapshot "$REALITY_STATE" "$state_snap"
      uninstall_restore_snapshot "$XRAY_INFO" "$info_snap"
      [[ -f "$dest.pre-uninstall-reality" ]] && mv -f "$dest.pre-uninstall-reality" "$dest"
      rm -f -- "$state_snap" "$info_snap"
      systemctl restart xray 2>/dev/null || true
      fail "Xray 重启失败，已回滚配置"
    fi
  fi
  rm -f "$dest.pre-uninstall-reality" "$state_snap" "$info_snap"
  if [[ -f $WS_STATE ]] || component_has_config ws; then
    ok "已移除 REALITY，保留其他配置"
  else
    ok "已移除 REALITY"
  fi
}

uninstall_ws() {
  require_root
  managed_component_present ws || { warn "未找到本项目管理的 WS+TLS，未执行卸载"; return 0; }
  xray_discover
  local dest=${XRAY_CONFIG_FILE:-$XRAY_CONFIG}
  local dom certdir="" acme="/root/.acme.sh/acme.sh" state_snap="" info_snap=""
  dom=$(state_get "$WS_STATE" WS_DOMAIN)
  if [[ -n $dom ]]; then
    validate_domain "$dom"
    certdir=$(xray_cert_dir "$dom")
  else
    certdir=$(xray_cert_dir "$WS_IP_CERT_ID")
  fi
  state_snap=$(uninstall_snapshot_file "$WS_STATE") || fail "无法创建临时回滚快照"
  info_snap=$(uninstall_snapshot_file "$WS_INFO") || { rm -f -- "$state_snap"; fail "无法创建临时回滚快照"; }
  [[ -f $dest ]] && cp -a "$dest" "$dest.pre-uninstall-ws" || true
  rm -f "$WS_STATE" "$WS_INFO"
  if ! build_xray_config; then
    uninstall_restore_snapshot "$WS_STATE" "$state_snap"
    uninstall_restore_snapshot "$WS_INFO" "$info_snap"
    [[ -f "$dest.pre-uninstall-ws" ]] && mv -f "$dest.pre-uninstall-ws" "$dest"
    rm -f -- "$state_snap" "$info_snap"
    fail "移除 WS+TLS 配置失败，已回滚"
  fi
  if systemctl is-enabled xray >/dev/null 2>&1 || systemctl is-active xray >/dev/null 2>&1; then
    if ! restart_svc_or_fail xray "Xray"; then
      uninstall_restore_snapshot "$WS_STATE" "$state_snap"
      uninstall_restore_snapshot "$WS_INFO" "$info_snap"
      [[ -f "$dest.pre-uninstall-ws" ]] && mv -f "$dest.pre-uninstall-ws" "$dest"
      rm -f -- "$state_snap" "$info_snap"
      systemctl restart xray 2>/dev/null || true
      fail "Xray 重启失败，已回滚配置"
    fi
  fi
  [[ -n $dom && -x $acme ]] &&
    "$acme" --remove -d "$dom" --ecc >/dev/null 2>&1 || true
  [[ -n $certdir ]] && rm -rf -- "$certdir"
  rm -f "$dest.pre-uninstall-ws" "$state_snap" "$info_snap"
  if [[ -f $REALITY_STATE ]] || component_has_config reality; then
    ok "已移除 WS+TLS，保留其他配置"
  else
    ok "已移除 WS+TLS"
  fi
}

uninstall_hy2() {
  require_root
  managed_component_present hy2 || { warn "未找到本项目管理的 Hysteria2，未执行卸载"; return 0; }
  if command -v hysteria >/dev/null || systemctl cat hysteria-server >/dev/null 2>&1; then
    run_verified_script "$HY2_INSTALLER_URL" "$HY2_INSTALLER_SHA256" --remove ||
      fail "Hysteria2 卸载器执行失败"
  fi
  if xray_binary_path >/dev/null 2>&1; then
    enable_proxy_auto_update
  else
    systemctl disable --now syw-hy2-update.timer 2>/dev/null || true
    rm -f "$HY2_UPDATE_SERVICE" "$HY2_UPDATE_TIMER"
  fi
  rm -f "$HY2_UPDATE_STATE"
  systemctl disable hysteria-server 2>/dev/null || true
  rm -f "$HY2_INFO" "$HY2_CONFIG" "$HY2_STATE" "$HY2_DROPIN"
  rm -rf "$HY2_CERT_DIR"
  rmdir "$(dirname "$HY2_DROPIN")" /etc/hysteria 2>/dev/null || true
  userdel -r "$HY2_USER" 2>/dev/null || true
  systemctl daemon-reload
  ok "已卸载 Hysteria2"
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
  ui_gap
  if [[ -n $default_sni ]]; then
    ui_item 0 "保持当前: $default_sni（默认）"
  else
    ui_item 0 "随机（默认）"
  fi
  for ((i = 0; i < n; i++)); do
    ui_item "$((i + 1))" "${SNI_PRESETS[i]}"
  done
  ui_gap
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
  ui_head "代理管理" "v${VERSION}"
  ui_status "$(proxy_status_line)"
  ui_gap
}

confirm_yes() {
  # 默认拒绝：仅 y/Y 通过
  local prompt=$1 ans
  read -r -p "  ${prompt}[y/N]: " ans || return 1
  [[ $ans == y || $ans == Y ]]
}

menu_install_ws() {
  local domain port path email random_port=0 cur_port=""
  # 域名不从旧配置预填，避免误用旧节点并在提示符中回显域名。
  domain=$(prompt "域名（空=IP 直连，自签证书）" "")
  if [[ $domain == "$(state_get "$WS_STATE" WS_DOMAIN)" ]]; then
    cur_port=$(state_get "$WS_STATE" WS_PORT)
  fi
  port=$(prompt "TLS 端口（空=保持或随机；输入 random=随机）" "$cur_port")
  if [[ ${port,,} == random ]]; then
    port=
    random_port=1
  fi
  path=$(prompt "WebSocket path（空=保持或随机）" "$(state_get "$WS_STATE" WS_PATH)")

  local args=()
  if [[ -n $domain ]]; then
    email=$(prompt "证书邮箱" "admin@${domain}")
    args+=(--domain "$domain" --email "$email")
  fi
  (( random_port )) && args+=(--random-port)
  [[ -n $port ]] && args+=(--port "$port")
  [[ -n $path ]] && args+=(--path "$path")
  install_ws "${args[@]}"
  pause
}

menu_install() {
  while true; do
    clear 2>/dev/null || true
    ui_head "安装代理" ""
    ui_gap
    ui_item 1 "安装 / 更新 REALITY"
    ui_item 2 "安装 / 更新 Hysteria2"
    ui_item 3 "安装 / 更新 VLESS + WS + TLS（直连）"
    ui_gap
    ui_item 0 "返回" muted
    ui_gap
    local c
    printf '  请选择 [0-3]: '
    read -r c || { warn "读取输入失败"; return 1; }
    c=${c//[[:space:]]/}
    case $c in
      1)
        local port sni cur_port cur_sni
        cur_port=$(state_get "$REALITY_STATE" REALITY_PORT)
        cur_sni=$(state_get "$REALITY_STATE" REALITY_SNI)
        port=$(prompt "TCP 端口" "${cur_port:-443}")
        pick_sni "REALITY 伪装 / SNI" "$cur_sni"
        sni=$_SNI_CHOSEN
        install_reality --port "$port" --sni "$sni" --target "${sni}:443"
        pause
        ;;
      2)
        local hp cur_port
        cur_port=$(state_get "$HY2_STATE" HY2_PORT)
        hp=$(prompt "UDP 端口（空=保持或随机）" "${cur_port:-}")
        pick_sni "Hysteria2 证书 SNI" "$(state_get "$HY2_STATE" HY2_DOMAIN)"
        local args=(--domain "$_SNI_CHOSEN")
        [[ -n $hp ]] && args+=(--port "$hp")
        install_hy2 "${args[@]}"
        pause
        ;;
      3) menu_install_ws ;;
      0|"") return ;;
      *) warn "无效选项"; sleep 1 ;;
    esac
  done
}

menu_uninstall() {
  while true; do
    local actions=() labels=() i n c act
    actions=()
    labels=()
    if managed_component_present reality; then
      actions+=(reality)
      labels+=("卸载 REALITY")
    fi
    if managed_component_present ws; then
      actions+=(ws)
      labels+=("卸载 WS+TLS")
    fi
    if managed_component_present hy2; then
      actions+=(hy2)
      labels+=("卸载 Hysteria2")
    fi
    clear 2>/dev/null || true
    ui_head "卸载代理" ""
    ui_gap
    n=${#actions[@]}
    if (( n == 0 )); then
      ui_status "${D}○${R}  暂无可卸载的节点"
      ui_gap
      ui_item 0 "返回" muted
      ui_gap
      printf '  请选择 [0-0]: '
      read -r c || return 1
      return 0
    fi
    for ((i = 0; i < n; i++)); do
      ui_item "$((i + 1))" "${labels[i]}" danger
    done
    ui_gap
    ui_item 0 "返回" muted
    ui_gap
    printf '  请选择 [0-%s]: ' "$n"
    read -r c || { warn "读取输入失败"; return 1; }
    c=${c//[[:space:]]/}
    if [[ $c == 0 || -z $c ]]; then
      return 0
    fi
    if ! [[ $c =~ ^[0-9]+$ ]] || (( c < 1 || c > n )); then
      warn "无效选项"
      continue
    fi
    act=${actions[c - 1]}
    case $act in
      reality)
        confirm_yes "确定卸载 REALITY？" || { warn "已取消"; continue; }
        uninstall_reality
        ;;
      ws)
        confirm_yes "确定卸载 WS+TLS？" || { warn "已取消"; continue; }
        uninstall_ws
        ;;
      hy2)
        confirm_yes "确定卸载 Hysteria2？" || { warn "已取消"; continue; }
        uninstall_hy2
        ;;
    esac
    pause
  done
}

main_menu() {
  while true; do
    print_banner
    ui_item 1 "安装代理"
    ui_item 2 "节点与状态"
    ui_item 3 "更新代理核心"
    ui_item 4 "卸载" danger
    ui_gap
    ui_item 0 "返回" muted
    ui_gap
    local c
    c=$(ui_prompt 4) || {
      warn "读取输入失败"
      return 1
    }
    c=${c//[[:space:]]/}
    case $c in
      1) menu_install ;;
      2) show_info; pause ;;
      3) update_proxy_cores manual; pause ;;
      4) menu_uninstall ;;
      0) return 0 ;;
      "") continue ;;
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
  # show --status-debug / status-debug
  if [[ $cmd == show || $cmd == status ]]; then
    if [[ ${1:-} == --status-debug || ${1:-} == status-debug ]]; then
      PROXY_STATUS_DEBUG=1
      shift || true
    fi
  fi
  case $cmd in
    menu|"") main_menu ;;
    xray|reality) install_reality "$@" ;;
    hy2|hysteria2) install_hy2 "$@" ;;
    update-hy2|update-hysteria2)
      if [[ ${1:-} == --auto ]]; then update_hy2_core --auto
      else update_hy2_manual
      fi
      ;;
    update-cores|update-proxy|update-all)
      if [[ ${1:-} == --auto ]]; then update_proxy_cores --auto
      else update_proxy_cores manual
      fi
      ;;
    enable-auto-update|configure-auto-update)
      require_root
      enable_proxy_auto_update
      ;;
    ws|vless-ws|vless-ws-tls) install_ws "$@" ;;
    show|status) show_info ;;
    status-debug|--status-debug) PROXY_STATUS_DEBUG=1; show_info ;;
    uninstall-reality) uninstall_reality ;;
    uninstall-xray|uninstall-xray-core) uninstall_xray_core ;;
    uninstall-ws) uninstall_ws ;;
    uninstall-hy2|uninstall-hysteria2) uninstall_hy2 ;;
    -h|--help|help) usage ;;
    *) fail "未知命令: $cmd" ;;
  esac
}

on_error() {
  local rc=$1 line=$2
  printf '%s[%s]%s 脚本第 %s 行失败 (exit %s)\n' "$RED" "ERR" "$R" "$line" "$rc" >&2
  exit "$rc"
}

if [[ -z ${BASH_SOURCE[0]:-} || ${BASH_SOURCE[0]} == "$0" ]]; then
  elevate_if_needed "$@"
  trap 'rc=$?; on_error "$rc" "$LINENO"' ERR
  main "$@"
fi
