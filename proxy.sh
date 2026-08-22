#!/usr/bin/env bash
# VPS 代理一键脚本：Xray REALITY / Hysteria2 / VLESS-WS-TLS(可走 CF)
set -Eeuo pipefail

APP_NAME="vps-proxy"
VERSION="1.6.0"
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
XRAY_CONFIG="${XRAY_CONFIG:-/usr/local/etc/xray/config.json}"
# 运行时由 xray_discover 填充：file|dir|unknown
XRAY_LAYOUT="${XRAY_LAYOUT:-unknown}"
XRAY_CONFIG_FILE="${XRAY_CONFIG_FILE:-}"
XRAY_CONF_DIR="${XRAY_CONF_DIR:-}"
# 本项目管理的 inbound tag / confdir 文件名
MANAGED_TAG_REALITY="vless-reality"
MANAGED_TAG_CDN="vless-ws-tls"
MANAGED_FILE_REALITY="50-vps-reality.json"
MANAGED_FILE_CDN="51-vps-cdn.json"
HY2_CONFIG="/etc/hysteria/config.yaml"
HY2_CERT_DIR="/etc/hysteria/certs"
HY2_DROPIN="/etc/systemd/system/hysteria-server.service.d/10-vps-proxy-user.conf"
HY2_USER="hysteria"
HY2_BIN="${HY2_BIN:-/usr/local/bin/hysteria}"
HY2_UPDATE_STATE="${CONFIG_DIR}/hy2-update.conf"
HY2_UPDATE_SERVICE="/etc/systemd/system/syw-hy2-update.service"
HY2_UPDATE_TIMER="/etc/systemd/system/syw-hy2-update.timer"
HY2_UPDATE_LOCK="/run/lock/syw-hy2-update.lock"
HY2_UPDATE_API="${HY2_UPDATE_API:-https://api.hy2.io/v1/update?cver=installscript&plat=linux&arch=amd64&chan=release&side=server}"
HY2_RELEASE_BASE="${HY2_RELEASE_BASE:-https://github.com/HyNetworks/hysteria/releases/download/app}"
PUBLIC_IP=""
DEPS_INSTALLED=0
# 旧版 v2 快捷命令路径（仅用于安全清理，不再安装）
_LEGACY_V2_DIR="/usr/local/lib/vps-proxy"
_LEGACY_V2_BIN="/usr/local/bin/v2"
_LEGACY_V2_CLEANED=0

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
  bash proxy.sh cdn  [参数]     安装/更新 VLESS+WS+TLS
  bash proxy.sh show
  bash proxy.sh show --status-debug   排障：显示内部元数据提示
  bash proxy.sh uninstall-xray | uninstall-hy2 | uninstall-cdn

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
  if ((DEPS_INSTALLED)); then
    return 0
  fi
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
          if [[ -r $path || -e $path || ! -e $path ]]; then
            XRAY_LAYOUT=file
            XRAY_CONFIG_FILE=$path
            XRAY_CONFIG=$path
          fi
          ;;
        dir:*)
          XRAY_LAYOUT=dir
          XRAY_CONF_DIR=$path
          ;;
      esac
    done < <(parse_execstart_config_specs "$exec_line")
  fi
  if [[ $XRAY_LAYOUT == unknown ]]; then
    if [[ -d ${XRAY_CONFIG%/*}/conf.d ]]; then
      : # 可选 conf.d 不自动采用
    fi
    if [[ -n ${XRAY_CONFIG:-} ]]; then
      XRAY_LAYOUT=file
      XRAY_CONFIG_FILE=$XRAY_CONFIG
    fi
  fi
  if [[ $XRAY_LAYOUT == file && -z $XRAY_CONFIG_FILE ]]; then
    XRAY_CONFIG_FILE=${XRAY_CONFIG:-/usr/local/etc/xray/config.json}
  fi
}

# 统一扫描：输出 key=value 行
# has_reality=0|1  has_cdn=0|1  port_reality=  port_cdn=  source=
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
    printf 'has_reality=0\nhas_cdn=0\nport_reality=\nport_cdn=\nsource=none\n'
    return 0
  fi

  if command -v python3 >/dev/null 2>&1; then
    local out
    out=$(SRC="$source" FILES="$(printf '%s\n' "${files[@]}")" TAG_R="$MANAGED_TAG_REALITY" TAG_C="$MANAGED_TAG_CDN" python3 - <<'PY'
import json, os
files = [x for x in os.environ.get("FILES", "").splitlines() if x]
tag_r = os.environ.get("TAG_R", "vless-reality")
tag_c = os.environ.get("TAG_C", "vless-ws-tls")
src = os.environ.get("SRC", "none")
has_r = has_c = False
port_r = port_c = ""

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

def is_cdn(ib):
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
    except Exception:
        continue
    for ib in inbounds_of(data):
        if is_reality(ib):
            has_r = True
            p = ib.get("port")
            if p is not None and str(p).isdigit() and 1 <= int(p) <= 65535:
                port_r = str(int(p))
        if is_cdn(ib):
            has_c = True
            p = ib.get("port")
            if p is not None and str(p).isdigit() and 1 <= int(p) <= 65535:
                port_c = str(int(p))
print(f"has_reality={1 if has_r else 0}")
print(f"has_cdn={1 if has_c else 0}")
print(f"port_reality={port_r}")
print(f"port_cdn={port_c}")
print(f"source={src}")
PY
)
    printf '%s\n' "$out"
    return 0
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
    if grep -qE "\"tag\"[[:space:]]*:[[:space:]]*\"${MANAGED_TAG_CDN}\"" "$f" 2>/dev/null \
      || { grep -qE "\"network\"[[:space:]]*:[[:space:]]*\"ws\"" "$f" 2>/dev/null \
        && grep -qE "\"security\"[[:space:]]*:[[:space:]]*\"tls\"" "$f" 2>/dev/null \
        && grep -qE "\"protocol\"[[:space:]]*:[[:space:]]*\"vless\"" "$f" 2>/dev/null; }; then
      has_c=1
      port_c=$(_port_for_tag "$f" "$MANAGED_TAG_CDN")
    fi
  done
  printf 'has_reality=%s\nhas_cdn=%s\nport_reality=%s\nport_cdn=%s\nsource=%s\n' \
    "$has_r" "$has_c" "$port_r" "$port_c" "$source"
}

# 解析 xray_scan 输出到变量
xray_scan_load() {
  local k v
  HAS_REALITY=0 HAS_CDN=0 PORT_REALITY= PORT_CDN= SCAN_SOURCE=none
  while IFS= read -r line; do
    [[ $line == *=* ]] || continue
    k=${line%%=*}; v=${line#*=}
    case $k in
      has_reality) HAS_REALITY=$v ;;
      has_cdn) HAS_CDN=$v ;;
      port_reality) PORT_REALITY=$v ;;
      port_cdn) PORT_CDN=$v ;;
      source) SCAN_SOURCE=$v ;;
    esac
  done < <(xray_scan)
}

xray_has_component() {
  local kind=$1
  xray_scan_load
  case $kind in
    reality) [[ ${HAS_REALITY:-0} == 1 ]] ;;
    cdn) [[ ${HAS_CDN:-0} == 1 ]] ;;
    *) return 1 ;;
  esac
}

xray_inbound_port() {
  local kind=$1
  xray_scan_load
  case $kind in
    reality) [[ -n ${PORT_REALITY:-} ]] && printf '%s\n' "$PORT_REALITY" ;;
    cdn) [[ -n ${PORT_CDN:-} ]] && printf '%s\n' "$PORT_CDN" ;;
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
    reality|cdn) p=$(xray_inbound_port "$comp") ;;
    hy2) p=$(hy2_config_port) ;;
  esac
  if port_is_valid "$p"; then printf '%s\n' "$p"; return 0; fi
}

component_has_config() {
  local comp=$1
  case $comp in
    reality) xray_has_component reality ;;
    cdn) xray_has_component cdn ;;
    hy2) hy2_config_present ;;
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
  if component_has_config cdn; then
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
    if [[ -f $REALITY_STATE || -f $CDN_STATE || -f $HY2_STATE ]]; then
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

# 节点页：comp=reality|cdn|hy2
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

xray_run_user() {
  local xu
  xu=$(systemctl show -p User --value xray 2>/dev/null || true)
  [[ -z $xu || $xu == - ]] && xu=nobody
  getent passwd "$xu" >/dev/null || xu=nobody
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

# 校验配置；VPS_PROXY_SKIP_XRAY_TEST=1 或无 xray 时仅做 JSON 语法检查
xray_validate_path() {
  local path=$1 mode=${2:-file}
  if [[ ${VPS_PROXY_SKIP_XRAY_TEST:-0} == 1 ]] || ! command -v xray >/dev/null 2>&1; then
    if command -v python3 >/dev/null 2>&1; then
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
    fi
    return 0
  fi
  if [[ $mode == dir ]]; then
    xray run -test -confdir "$path" >/dev/null 2>&1
  else
    xray run -test -config "$path" >/dev/null 2>&1
  fi
}

xray_apply_perms() {
  local path=$1 xg
  xg=$(xray_run_group)
  if ((EUID == 0)); then
    install -d -o root -g "$xg" -m 750 "$(dirname "$path")"
    chown "root:$xg" "$path" 2>/dev/null || true
  else
    install -d -m 750 "$(dirname "$path")"
  fi
  chmod 640 "$path" 2>/dev/null || true
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

_xray_cdn_inbound_json() {
  cat <<EOF
{
  "tag": "${MANAGED_TAG_CDN}", "listen": "0.0.0.0", "port": ${CDN_PORT},
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
}

# 单文件：结构化增删本管理 tag，保留其余 inbound
_xray_merge_file() {
  local dest=$1 want_reality=$2 want_cdn=$3
  local tmp bak rf cf
  command -v python3 >/dev/null 2>&1 || fail "写入 Xray 配置需要 python3"
  [[ -f $dest ]] || printf '%s\n' '{"log":{"loglevel":"warning"},"inbounds":[],"outbounds":[{"protocol":"freedom","tag":"direct"},{"protocol":"blackhole","tag":"block"}]}' >"$dest"
  bak=$(mktemp "${dest}.bak.XXXXXX")
  cp -a "$dest" "$bak"
  tmp=$(mktemp "${dest}.XXXXXX")
  rf=$(mktemp); cf=$(mktemp)
  [[ $want_reality == 1 ]] && _xray_reality_inbound_json >"$rf" || : >"$rf"
  [[ $want_cdn == 1 ]] && _xray_cdn_inbound_json >"$cf" || : >"$cf"
  if ! WANT_R=$want_reality WANT_C=$want_cdn TAG_R=$MANAGED_TAG_REALITY TAG_C=$MANAGED_TAG_CDN \
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
    cfg = {"inbounds": [], "outbounds": []}
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
  local dir=$1 want_reality=$2 want_cdn=$3
  local fr fc bak_r bak_c
  install -d -m 755 "$dir"
  fr="$dir/$MANAGED_FILE_REALITY"
  fc="$dir/$MANAGED_FILE_CDN"
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
    python3 - <<PY || { rollback_confdir; fail "写入 REALITY confdir 失败"; }
import json
ib=json.load(open("$fr.tmp",encoding="utf-8"))
json.dump({"inbounds":[ib]}, open("$fr","w",encoding="utf-8"), indent=2)
open("$fr","a",encoding="utf-8").write("\n")
PY
    rm -f "$fr.tmp"
    xray_apply_perms "$fr"
  else
    rm -f "$fr"
  fi
  if [[ $want_cdn == 1 ]]; then
    _xray_cdn_inbound_json >"$fc.tmp"
    python3 - <<PY || { rollback_confdir; fail "写入 CDN confdir 失败"; }
import json
ib=json.load(open("$fc.tmp",encoding="utf-8"))
json.dump({"inbounds":[ib]}, open("$fc","w",encoding="utf-8"), indent=2)
open("$fc","a",encoding="utf-8").write("\n")
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
  local want_reality=0 want_cdn=0
  xray_discover
  load_state_safe "$REALITY_STATE"
  load_state_safe "$CDN_STATE"
  migrate_cdn_certs_if_needed

  [[ -f $REALITY_STATE ]] && want_reality=1
  [[ -f $CDN_STATE ]] && want_cdn=1

  if [[ $XRAY_LAYOUT == dir && -n $XRAY_CONF_DIR ]]; then
    _xray_write_confdir "$XRAY_CONF_DIR" "$want_reality" "$want_cdn"
  else
    local dest=${XRAY_CONFIG_FILE:-$XRAY_CONFIG}
    install -d -m 755 "$(dirname "$dest")"
    _xray_merge_file "$dest" "$want_reality" "$want_cdn"
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

# 从真实 Xray 配置恢复 REALITY 参数（更新/重装时用，show 路径不调用）
# 成功时设置 REALITY_PORT/UUID/SNI/TARGET/PRIV/PUB/SHORT 并 return 0
recover_reality_from_live() {
  local f raw
  while IFS= read -r f; do
    [[ -r $f ]] || continue
    if command -v jq >/dev/null 2>&1; then
      raw=$(jq -c '
        [.inbounds[]? // empty | select(type=="object")
          | select((.protocol=="vless" and .streamSettings.security=="reality")
                   or .tag=="vless-reality")] | .[0] // empty
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
    if ib.get("protocol") == "vless" and ss.get("security") == "reality" or ib.get("tag") == "vless-reality":
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

  component_has_config reality && live_exists=1

  # 1) 优先 state 管理缓存  2) 再从真实服务配置恢复  3) 全新安装
  if [[ -f $REALITY_STATE ]]; then
    load_state_safe "$REALITY_STATE"
    if [[ -n ${REALITY_PRIV:-} && -n ${REALITY_PUB:-} && -n ${REALITY_SHORT:-} ]]; then
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
      # 无私钥对应公钥时，仍写入 state 用 privateKey；分享链接需要 pub
      if [[ -z $pub ]]; then
        warn "无法从缓存读取 PublicKey，更新后将重新生成分享链接字段"
        # 尝试 xray 无法从 priv 直接得 pub 时保持空，save_info 仍写出
        pub="unknown"
      fi
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
    if ((restarted_xray)); then
      systemctl start xray || true
    fi
    fail "证书申请失败（域名解析/80 端口/防火墙）"
  fi
  "$acme" --install-cert -d "$domain" --ecc \
    --fullchain-file "$certdir/fullchain.pem" \
    --key-file "$certdir/privkey.pem" \
    --reloadcmd "systemctl restart xray 2>/dev/null || true"
  CDN_CERT="$certdir/fullchain.pem"; CDN_KEY="$certdir/privkey.pem"
  fix_cert_permissions "$certdir" "$CDN_CERT" "$CDN_KEY"
  if ((restarted_xray)); then
    systemctl start xray 2>/dev/null || true
  fi
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
  local data version
  data=$(curl -fsSL --retry 3 --connect-timeout 10 --max-time 60 "$HY2_UPDATE_API") || return 1
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
  systemctl is-active --quiet hysteria-server 2>/dev/null && was_active=1
  install -m 755 "$candidate" "${HY2_BIN}.new"
  mv -f "${HY2_BIN}.new" "$HY2_BIN"
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
  fi
  rm -f -- "$backup"
  hy2_record_update updated "$latest" "$latest"
  ok "Hysteria2 已更新: ${current} → ${latest}"
}

enable_hy2_auto_update() {
  cat >"$HY2_UPDATE_SERVICE" <<EOF
[Unit]
Description=syw-vps Hysteria2 stable update
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash /usr/local/lib/syw-vps/proxy.sh update-hy2 --auto
EOF
  cat >"$HY2_UPDATE_TIMER" <<'EOF'
[Unit]
Description=Weekly Hysteria2 stable update check

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
  # 从而在「有 REALITY、无 CDN」时仍能继续展示 Hysteria2
  _show_info_handle_component "REALITY" "$REALITY_STATE" "$XRAY_INFO" xray xray REALITY_PORT reality
  _show_info_handle_component "CDN / WS+TLS" "$CDN_STATE" "$CDN_INFO" xray xray CDN_PORT cdn
  _show_info_handle_component "Hysteria2" "$HY2_STATE" "$HY2_INFO" hysteria-server hysteria HY2_PORT hy2

  # 有真实节点/异常组件时不显示「暂无」；仅残留时也不追加「暂无」
  if (( found == 0 && residual == 0 )); then
    printf '  %s○%s  暂无代理\n' "$D" "$R"
  fi
  printf '\n'
}

uninstall_xray_core() {
  # 仅当现网已无任何 inbound（含第三方）时才允许 purge
  xray_discover
  local dest=${XRAY_CONFIG_FILE:-$XRAY_CONFIG} n=0
  if [[ -r $dest ]] && command -v python3 >/dev/null 2>&1; then
    n=$(python3 -c "import json; d=json.load(open(r'''$dest''',encoding='utf-8')); print(len(d.get('inbounds') or []))" 2>/dev/null || echo 1)
  fi
  if (( n > 0 )); then
    fail "无法确认归属或仍有其他 inbound，拒绝删除 Xray 主程序（请手动处理）"
  fi
  if command -v xray >/dev/null; then
    run_verified_script "$XRAY_INSTALLER_URL" "$XRAY_INSTALLER_SHA256" remove --purge ||
      fail "Xray 卸载器执行失败"
  fi
  rm -f "$dest"
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

uninstall_reality() {
  require_root
  xray_discover
  local dest=${XRAY_CONFIG_FILE:-$XRAY_CONFIG}
  backup_paths reality-rm "$REALITY_STATE" "$XRAY_INFO" "$dest"
  [[ -f $dest ]] && cp -a "$dest" "${dest}.pre-uninstall-reality" || true
  rm -f "$REALITY_STATE" "$XRAY_INFO"
  # 按剩余 state 重建，精确去掉本管理 REALITY inbound，保留 CDN/第三方
  if ! build_xray_config; then
    [[ -f ${dest}.pre-uninstall-reality ]] && mv -f "${dest}.pre-uninstall-reality" "$dest"
    fail "移除 REALITY 配置失败，已回滚"
  fi
  if systemctl is-enabled xray >/dev/null 2>&1 || systemctl is-active xray >/dev/null 2>&1; then
    if ! restart_svc_or_fail xray "Xray"; then
      [[ -f ${dest}.pre-uninstall-reality ]] && mv -f "${dest}.pre-uninstall-reality" "$dest"
      systemctl restart xray 2>/dev/null || true
      fail "Xray 重启失败，已回滚配置"
    fi
  fi
  rm -f "${dest}.pre-uninstall-reality"
  if [[ -f $CDN_STATE ]] || component_has_config cdn; then
    ok "已移除 REALITY，保留其他配置"
  else
    ok "已移除 REALITY"
  fi
}

uninstall_cdn() {
  require_root
  xray_discover
  local dest=${XRAY_CONFIG_FILE:-$XRAY_CONFIG}
  local dom certdir="" acme="/root/.acme.sh/acme.sh"
  dom=$(state_get "$CDN_STATE" CDN_DOMAIN)
  if [[ -n $dom ]]; then
    validate_domain "$dom"
    certdir=$(xray_cert_dir "$dom")
  fi
  backup_paths cdn-rm "$CDN_STATE" "$CDN_INFO" "$dest" "$certdir"
  [[ -f $dest ]] && cp -a "$dest" "${dest}.pre-uninstall-cdn" || true
  [[ -n $dom && -x $acme ]] &&
    "$acme" --remove -d "$dom" --ecc >/dev/null 2>&1 || true
  rm -f "$CDN_STATE" "$CDN_INFO"
  [[ -n $certdir ]] && rm -rf "$certdir"
  if ! build_xray_config; then
    [[ -f ${dest}.pre-uninstall-cdn ]] && mv -f "${dest}.pre-uninstall-cdn" "$dest"
    fail "移除 CDN 配置失败，已回滚"
  fi
  if systemctl is-enabled xray >/dev/null 2>&1 || systemctl is-active xray >/dev/null 2>&1; then
    if ! restart_svc_or_fail xray "Xray"; then
      [[ -f ${dest}.pre-uninstall-cdn ]] && mv -f "${dest}.pre-uninstall-cdn" "$dest"
      systemctl restart xray 2>/dev/null || true
      fail "Xray 重启失败，已回滚配置"
    fi
  fi
  rm -f "${dest}.pre-uninstall-cdn"
  if [[ -f $REALITY_STATE ]] || component_has_config reality; then
    ok "已移除 CDN，保留其他配置"
  else
    ok "已移除 CDN"
  fi
}

uninstall_hy2() {
  require_root
  backup_paths hy2-rm "$HY2_STATE" "$HY2_INFO" "$HY2_CONFIG" "$HY2_CERT_DIR"
  if command -v hysteria >/dev/null || systemctl cat hysteria-server >/dev/null 2>&1; then
    run_verified_script "$HY2_INSTALLER_URL" "$HY2_INSTALLER_SHA256" --remove ||
      fail "Hysteria2 卸载器执行失败"
  fi
  systemctl disable --now syw-hy2-update.timer 2>/dev/null || true
  rm -f "$HY2_UPDATE_SERVICE" "$HY2_UPDATE_TIMER" "$HY2_UPDATE_STATE"
  systemctl disable hysteria-server 2>/dev/null || true
  rm -f "$HY2_INFO" "$HY2_CONFIG" "$HY2_STATE" "$HY2_DROPIN"
  rm -rf "$HY2_CERT_DIR"
  rmdir "$(dirname "$HY2_DROPIN")" /etc/hysteria 2>/dev/null || true
  userdel -r "$HY2_USER" 2>/dev/null || true
  systemctl daemon-reload
  ok "已卸载 Hysteria2"
}

# 安全清理旧版 v2 快捷命令（仅本项目文件；全程只提示一次）
# 计划：v1.6+ 移除本函数与 _LEGACY_V2_* 变量
cleanup_legacy_v2() {
  (( _LEGACY_V2_CLEANED )) && return 0
  _LEGACY_V2_CLEANED=1
  [[ $EUID -eq 0 ]] || return 0

  local bin=${_LEGACY_V2_BIN} dir=${_LEGACY_V2_DIR} script="${_LEGACY_V2_DIR}/proxy.sh"
  local target="" did=0 own=0

  if [[ -L $bin ]]; then
    target=$(readlink -f "$bin" 2>/dev/null || true)
    if [[ -n $target && $target == ${dir}/* ]]; then
      own=1
    fi
  elif [[ -f $bin ]]; then
    if grep -q '^APP_NAME="vps-proxy"$' "$bin" 2>/dev/null; then
      own=1
    fi
  fi
  if [[ -f $script ]] && grep -q '^APP_NAME="vps-proxy"$' "$script" 2>/dev/null; then
    own=1
  fi

  if (( own )); then
    if [[ -e $bin || -L $bin ]]; then
      rm -f "$bin" && did=1
    fi
    if [[ -f $script ]]; then
      rm -f "$script" && did=1
    fi
    rmdir "$dir" 2>/dev/null || true
  fi

  if (( did )); then
    ok "已清理旧版 v2 快捷命令"
  fi
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

menu_install() {
  while true; do
    clear 2>/dev/null || true
    ui_head "安装代理" ""
    ui_gap
    ui_item 1 "安装 / 更新 REALITY"
    ui_item 2 "安装 / 更新 Hysteria2"
    ui_item 3 "安装 / 更新 CDN"
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
        pause
        ;;
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
    if component_has_config reality || [[ -f $REALITY_STATE ]]; then
      actions+=(reality)
      labels+=("卸载 REALITY")
    fi
    if component_has_config cdn || [[ -f $CDN_STATE ]]; then
      actions+=(cdn)
      labels+=("卸载 CDN")
    fi
    if component_has_config hy2 || [[ -f $HY2_STATE ]]; then
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
      cdn)
        confirm_yes "确定卸载 CDN？" || { warn "已取消"; continue; }
        uninstall_cdn
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
    ui_item 3 "更新 Hysteria2 核心"
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
      3) update_hy2_manual; pause ;;
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
  cleanup_legacy_v2 2>/dev/null || true
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
    cdn|cf|ws) install_cdn "$@" ;;
    show|status) show_info ;;
    status-debug|--status-debug) PROXY_STATUS_DEBUG=1; show_info ;;
    uninstall-xray|uninstall-reality) uninstall_reality ;;
    uninstall-cdn|uninstall-cf|uninstall-ws) uninstall_cdn ;;
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
