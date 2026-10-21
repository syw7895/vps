# shellcheck shell=bash
# 公共函数：路径、输出、输入、校验、配置存储、下载、systemd、防火墙

VPS_VERSION="1.0.0"
VPS_REPO=${VPS_REPO:-syw7895/vps}

# 测试模式下所有系统路径都加沙盒前缀
if [[ ${VPS_TEST:-0} == 1 ]]; then RT=${VPS_ROOT:?VPS_TEST=1 需要 VPS_ROOT}; else RT=""; fi

ETC=$RT/etc/vps
NODE_DIR=$ETC/nodes
XRAY_DIR=$ETC/xray
HY2_DIR=$ETC/hy2
CERT_DIR=$ETC/certs
SETTINGS=$ETC/settings.env
TRAFFIC_CONF=$ETC/traffic.env
VAR_DIR=$RT/var/lib/vps
LIB_DIR=$RT/usr/local/lib/vps
BIN_DIR=$LIB_DIR/bin
SHARE_DIR=$LIB_DIR/share
BIN_LINK=$RT/usr/local/bin/vps
UNIT_DIR=$RT/etc/systemd/system
SYSCTL_DIR=$RT/etc/sysctl.d
LE_DIR=$RT/etc/letsencrypt
NET_DIR=$RT/sys/class/net
BOOT_ID_FILE=$RT/proc/sys/kernel/random/boot_id
LOCK_FILE=$RT/run/lock/vps.lock
SVC_USER=vps-proxy

# ---------- 输出 ----------
if [[ -t 1 ]]; then
  C0=$'\e[0m' C1=$'\e[1m' CD=$'\e[2m' CR=$'\e[31m' CG=$'\e[32m' CY=$'\e[33m' CC=$'\e[36m'
  CLS=$'\e[H\e[2J' # 清屏但保留回滚记录
else
  C0='' C1='' CD='' CR='' CG='' CY='' CC='' CLS=''
fi
UI_W=48 # 标题栏和分隔线的宽度

say()  { printf '  %s\n' "$*"; }
note() { printf '  %s%s%s\n' "$CD" "$*" "$C0"; }
ok()   { printf '  %s✓%s %s\n' "$CG" "$C0" "$*"; }
warn() { printf '  %s!%s %s\n' "$CY" "$C0" "$*" >&2; }
die()  { printf '  %s✗%s %s\n' "$CR" "$C0" "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

need_root() {
  [[ $EUID -eq 0 || ${VPS_TEST:-0} == 1 ]] || die "请用 root 运行（sudo vps ...）"
}

# 字节数 → 人类可读（十进制：1 GB = 10^9 字节，与额度一致）
human() {
  awk -v b="${1:-0}" 'BEGIN {
    split("B KB MB GB TB PB", u, " "); i = 1
    while (b >= 1000 && i < 6) { b /= 1000; i++ }
    if (i == 1) printf "%d B", b; else printf "%.2f %s", b, u[i]
  }'
}

now() { printf '%s' "${VPS_NOW:-$(date +%s)}"; }

# 显示宽度：ASCII 算 1 列，中文（UTF-8 三字节）算 2 列，与系统 locale 无关
dwidth() {
  local LC_ALL=C s=$1 ascii wide
  ascii=${s//[^ -~]/}
  wide=$(((${#s} - ${#ascii}) / 3))
  printf '%s' $((${#ascii} + wide * 2))
}

# pad 文字 宽度：右侧补空格到指定显示宽度
pad() {
  local w
  w=$(dwidth "$1")
  printf '%s%*s' "$1" $(($2 > w ? $2 - w : 0)) ''
}

# repeat 字符 次数
repeat() {
  local s
  printf -v s '%*s' "$2" ''
  printf '%s' "${s// /$1}"
}

rule() { printf '  %s%s%s\n' "$CD" "$(repeat ─ "$UI_W")" "$C0"; }

# title_bar 标题 [右侧小字]：标题 + 分隔线（右侧小字只用 ASCII，才能算准宽度）
title_bar() {
  local sub=${2:-} gap
  printf '\n  %s%s%s%s' "$C1" "$CC" "$1" "$C0"
  if [[ -n $sub ]]; then
    gap=$((UI_W - $(dwidth "$1") - ${#sub}))
    printf '%*s%s%s%s' $((gap > 2 ? gap : 2)) '' "$CD" "$sub" "$C0"
  fi
  printf '\n'
  rule
  printf '\n'
}

# ---------- 输入 ----------
# ask 提示 [默认值]：读一行，去掉首尾空白，空则返回默认值（提示写到 stderr）
ask() {
  local prompt=$1 def=${2:-} ans=""
  if [[ -n $def ]]; then
    printf '  %s [%s]: ' "$prompt" "$def" >&2
  else
    printf '  %s: ' "$prompt" >&2
  fi
  IFS= read -r ans || true
  ans=${ans#"${ans%%[![:space:]]*}"}
  ans=${ans%"${ans##*[![:space:]]}"}
  printf '%s' "${ans:-$def}"
}

# confirm 提示：默认否
confirm() {
  local ans=""
  printf '  %s [y/N]: ' "$1" >&2
  IFS= read -r ans || return 1
  [[ $ans == [yY] || $ans == [yY][eE][sS] ]]
}

# ---------- 校验 ----------
is_port()   { [[ $1 =~ ^[0-9]{1,5}$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535)); }
is_ipv6()   { [[ $1 == *:* && $1 =~ ^[0-9A-Fa-f:.]+$ ]]; }
is_domain() { [[ ${#1} -le 253 && $1 =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]; }
is_email()  { [[ $1 =~ ^[A-Za-z0-9._%+-]+@([A-Za-z0-9-]+\.)+[A-Za-z]{2,63}$ ]]; }
is_uuid()   { [[ $1 =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; }
is_ws_path() { [[ $1 =~ ^/[A-Za-z0-9._~-]{1,64}$ ]]; }
is_url()    { [[ $1 =~ ^https?://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~%/-]*)?$ ]]; }
is_ipv4() {
  local IFS=. part
  [[ $1 =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  for part in $1; do ((10#$part <= 255)) || return 1; done
}
is_host() { is_ipv4 "$1" || is_ipv6 "$1" || is_domain "$1"; }

# ---------- 配置存储（KEY=value，只解析不执行） ----------
SAFE_VALUE_RE='^[A-Za-z0-9._:/@%+=,~?&-]*$'

# kv_load 文件 关联数组名
kv_load() {
  local -n __kv_map=$2
  local __kv_line
  __kv_map=()
  [[ -r $1 ]] || return 0
  while IFS= read -r __kv_line || [[ -n $__kv_line ]]; do
    if [[ $__kv_line =~ ^([A-Z][A-Z0-9_]*)=(.*)$ ]]; then
      __kv_map[${BASH_REMATCH[1]}]=${BASH_REMATCH[2]}
    fi
  done <"$1"
  return 0
}

# kv_save 文件 关联数组名 [权限]：先校验再原子替换
kv_save() {
  local __kv_file=$1 __kv_mode=${3:-600} __kv_key __kv_tmp
  local -n __kv_src=$2
  for __kv_key in "${!__kv_src[@]}"; do
    [[ $__kv_key =~ ^[A-Z][A-Z0-9_]*$ && ${__kv_src[$__kv_key]} =~ $SAFE_VALUE_RE ]] ||
      die "内部错误：非法配置项 $__kv_key"
  done
  mkdir -p "${__kv_file%/*}"
  __kv_tmp=$(mktemp "$__kv_file.XXXXXX")
  for __kv_key in "${!__kv_src[@]}"; do
    printf '%s=%s\n' "$__kv_key" "${__kv_src[$__kv_key]}"
  done | sort >"$__kv_tmp"
  chmod "$__kv_mode" "$__kv_tmp"
  mv -f "$__kv_tmp" "$__kv_file"
}

kv_get() {
  local -A __kv_one
  kv_load "$1" __kv_one
  printf '%s' "${__kv_one[$2]:-${3:-}}"
}

kv_set() {
  local -A __kv_upd
  kv_load "$1" __kv_upd
  __kv_upd[$2]=$3
  kv_save "$1" __kv_upd "${4:-600}"
}

setting()     { kv_get "$SETTINGS" "$1" "${2:-}"; }
setting_set() { kv_set "$SETTINGS" "$1" "$2" 644; }

# ---------- 随机值 ----------
rand_hex()  { openssl rand -hex "$1"; }
rand_port() { shuf -i 20000-60000 -n 1; }
rand_uuid() {
  if [[ -r /proc/sys/kernel/random/uuid ]]; then
    cat /proc/sys/kernel/random/uuid
  else
    local h
    h=$(openssl rand -hex 16)
    printf '%s-%s-4%s-%x%s-%s\n' "${h:0:8}" "${h:8:4}" "${h:13:3}" \
      $(((16#${h:16:1} & 3) | 8)) "${h:17:3}" "${h:20:12}"
  fi
}

# ---------- 网络 ----------
# port_busy 端口 tcp|udp：本机是否已有程序监听
port_busy() {
  local flags=-Hnlt out
  [[ $2 == udp ]] && flags=-Hnlu
  out=$(ss "$flags" "sport = :$1" 2>/dev/null || true)
  [[ -n $out ]]
}

detect_ip() {
  local url ip
  for url in https://api.ipify.org https://ipv4.icanhazip.com https://ifconfig.me/ip; do
    ip=$(curl -4 -fsS --max-time 8 "$url" 2>/dev/null | tr -d '[:space:]') || true
    if is_ipv4 "$ip"; then printf '%s' "$ip"; return 0; fi
  done
  for url in https://api64.ipify.org https://ipv6.icanhazip.com; do
    ip=$(curl -6 -fsS --max-time 8 "$url" 2>/dev/null | tr -d '[:space:]') || true
    if is_ipv6 "$ip"; then printf '%s' "$ip"; return 0; fi
  done
  return 1
}

# 分享链接里填的服务器地址：优先用设置，没有则自动检测并记住
share_host() {
  local host
  host=$(setting HOST)
  if [[ -z $host ]]; then
    host=$(detect_ip) || die "无法获取公网 IP，请先运行: vps host <IP或域名>"
    setting_set HOST "$host"
  fi
  printf '%s' "$host"
}

# IPv6 地址在链接里要加方括号
url_host() {
  if [[ $1 == *:* ]]; then printf '[%s]' "$1"; else printf '%s' "$1"; fi
}

# ---------- 下载 ----------
CURL_SAFE=(--proto '=https' --proto-redir '=https' -fsSL --retry 2 --connect-timeout 15)

fetch() { curl "${CURL_SAFE[@]}" --max-time 600 -o "$2" "$1"; }

# GitHub 仓库最新正式版 tag（跟随 releases/latest 跳转，不占用 API 额度）
latest_tag() {
  local url
  url=$(curl "${CURL_SAFE[@]}" --max-time 60 -o /dev/null -w '%{url_effective}' \
    "https://github.com/$1/releases/latest") || return 1
  [[ $url == */releases/tag/* ]] || return 1
  printf '%s' "${url#*/releases/tag/}"
}

sha256_of() { sha256sum "$1" | awk '{print $1}'; }

APT_UPDATED=0
# need_pkg 命令 包名：缺命令时用 apt 安装
need_pkg() {
  have "$1" && return 0
  have apt-get || die "缺少 $1，请先安装 $2"
  say "安装 $2 ..."
  if ((APT_UPDATED == 0)); then
    apt-get update -qq >/dev/null 2>&1 || true
    APT_UPDATED=1
  fi
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$2" >/dev/null 2>&1 || die "安装 $2 失败"
  have "$1" || die "安装 $2 后仍找不到 $1"
}

# ---------- systemd ----------
UNITS_CHANGED=0

# write_unit 文件名 内容：内容有变化才写入
write_unit() {
  local file=$UNIT_DIR/$1
  if [[ -f $file && $(<"$file") == "$2" ]]; then return 0; fi
  mkdir -p "$UNIT_DIR"
  printf '%s\n' "$2" >"$file"
  chmod 644 "$file"
  UNITS_CHANGED=1
}

remove_unit() {
  if [[ -f $UNIT_DIR/$1 ]]; then
    systemctl disable --now "$1" >/dev/null 2>&1 || true
    rm -f "$UNIT_DIR/$1"
    UNITS_CHANGED=1
  fi
}

units_reload() {
  if ((UNITS_CHANGED)); then
    systemctl daemon-reload
    UNITS_CHANGED=0
  fi
}

svc_active() { systemctl is-active --quiet "$1" 2>/dev/null; }

# svc_restart 单元：设为开机自启并重启，3 秒内一直存活才算成功
svc_restart() {
  local i
  systemctl enable "$1" >/dev/null 2>&1 || true
  systemctl restart "$1" >/dev/null 2>&1 || return 1
  for i in 1 2 3; do
    sleep 1
    svc_active "$1" || return 1
  done
}

# ---------- 防火墙（只处理已启用的 ufw / firewalld，云安全组需自行放行） ----------
fw_kind() {
  if have ufw && [[ $(ufw status 2>/dev/null) == *"Status: active"* ]]; then
    echo ufw
  elif have firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
    echo firewalld
  fi
}

fw_open() {
  case $(fw_kind) in
    ufw) ufw allow "$1/$2" >/dev/null 2>&1 || warn "ufw 放行 $1/$2 失败" ;;
    firewalld)
      { firewall-cmd -q --permanent --add-port="$1/$2" && firewall-cmd -q --reload; } ||
        warn "firewalld 放行 $1/$2 失败" ;;
  esac
  return 0
}

fw_close() {
  case $(fw_kind) in
    ufw) ufw delete allow "$1/$2" >/dev/null 2>&1 || true ;;
    firewalld) { firewall-cmd -q --permanent --remove-port="$1/$2" && firewall-cmd -q --reload; } >/dev/null 2>&1 || true ;;
  esac
  return 0
}

# ---------- 互斥锁 ----------
lock() {
  mkdir -p "${LOCK_FILE%/*}"
  exec 9>"$LOCK_FILE"
  if [[ ${1:-} == --nowait ]]; then
    flock -n 9 || exit 0
  else
    flock -w 120 9 || die "另一个 vps 操作正在进行，请稍后再试"
  fi
}
