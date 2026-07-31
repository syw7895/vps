#!/usr/bin/env bash
# syw-vps-entrypoint — 入口：调度 proxy / traffic
# 安装: /usr/local/lib/syw-vps/{vps,proxy,traffic}.sh  +  /usr/local/bin/vps
set -Eeuo pipefail

APP_NAME="syw-vps"
VERSION="1.1.5"
LIB_DIR="/usr/local/lib/syw-vps"
BIN_VPS="/usr/local/bin/vps"
MARKER="syw-vps-entrypoint"
# 可选固定提交: export SYW_VPS_REF=<commit-sha>
SYW_VPS_REF="${SYW_VPS_REF:-main}"
RAW_BASE="${SYW_VPS_RAW_BASE:-https://raw.githubusercontent.com/syw7895/vps/${SYW_VPS_REF}}"

VPS_SH_LOCAL="${LIB_DIR}/vps.sh"
PROXY_SH_LOCAL="${LIB_DIR}/proxy.sh"
TRAFFIC_SH_LOCAL="${LIB_DIR}/traffic.sh"

if [[ -t 1 ]]; then
  R=$'\033[0m' B=$'\033[1m'
  RED=$'\033[31m' GRN=$'\033[32m' YEL=$'\033[33m' CYN=$'\033[36m'
  D=$'\033[2m'
else
  R='' B='' RED='' GRN='' YEL='' CYN='' D=''
fi

warn() { printf '%s[%s]%s %s\n' "$YEL" "!" "$R" "$*"; }
fail() { printf '%s[%s]%s %s\n' "$RED" "ERR" "$R" "$*" >&2; exit 1; }

# ---------- UI（无重框线：标题 / 状态 / 列表） ----------
ui_init() { :; }
ui_head() {
  # $1 标题  $2 版本标签
  printf '\n  %s%s%s  %s%s%s\n' "$B$CYN" "$1" "$R" "$D" "$2" "$R"
}
ui_status() { printf '  %s\n' "$1"; }
ui_gap() { printf '\n'; }
ui_item() {
  # $1 序号  $2 主文案  $3 可选副文案
  printf '  %s%2s%s  %s\n' "$CYN" "$1" "$R" "$2"
  [[ -n ${3:-} ]] && printf '      %s%s%s\n' "$D" "$3" "$R"
}
ui_foot() { printf '\n'; }

entry_status_line() {
  local okp=0 okt=0
  [[ -f $PROXY_SH_LOCAL && -s $PROXY_SH_LOCAL ]] && okp=1
  [[ -f $TRAFFIC_SH_LOCAL && -s $TRAFFIC_SH_LOCAL ]] && okt=1
  if (( okp && okt )); then printf '%s●%s  模块就绪' "$GRN" "$R"
  elif (( okp || okt )); then printf '%s○%s  模块不完整' "$YEL" "$R"
  else printf '%s○%s  待安装模块' "$YEL" "$R"; fi
}

read_tty() {
  local prompt="" __var
  while [[ $# -gt 0 ]]; do
    case $1 in
      -p) prompt=$2; shift 2 ;;
      -r) shift ;;
      *) break ;;
    esac
  done
  __var=${1:-REPLY}
  read -r -p "$prompt" "${__var?}" || return 1
}

require_root() {
  [[ $EUID -eq 0 ]] || fail "请使用 root（curl -fsSL ... | sudo bash 或 sudo vps）"
}

owns_vps_bin() {
  [[ -f $1 ]] && grep -q "$MARKER" "$1" 2>/dev/null
}

http_get() {
  local url=$1 dest=$2
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --connect-timeout 20 --max-time 120 "$url" -o "$dest"
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O "$dest" "$url"
  else
    fail "需要 curl 或 wget"
  fi
}

# 下载：仅 bash -n 语法检查（本仓库模块不做哈希互校）
download_to() {
  local url=$1 dest=$2 tmp
  tmp=$(mktemp)
  if ! http_get "$url" "$tmp"; then
    rm -f "$tmp"
    fail "下载失败: $url"
  fi
  if [[ ! -s $tmp ]] || ! bash -n "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    fail "下载无效或语法错误: $url"
  fi
  install -m 0755 "$tmp" "$dest"
  rm -f "$tmp"
}

install_self_from_running() {
  mkdir -p "$LIB_DIR"
  local src=${BASH_SOURCE[0]:-} tmp
  tmp=$(mktemp)
  if [[ -n $src && -f $src && $src != /dev/fd/* && $src != /proc/self/fd/* && $src != - ]]; then
    cp -f "$src" "$tmp"
  else
    command -v curl >/dev/null || fail "管道安装需要 curl"
    http_get "${RAW_BASE}/vps.sh" "$tmp" || { rm -f "$tmp"; fail "无法下载 vps.sh"; }
  fi
  if [[ ! -s $tmp ]] || ! bash -n "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    fail "vps.sh 无效"
  fi
  install -m 0755 "$tmp" "$VPS_SH_LOCAL"
  rm -f "$tmp"
}

# 本地已有则保留；缺了才下载
ensure_module() {
  local dest=$1 url=$2
  if [[ -f $dest && -s $dest ]]; then
    bash -n "$dest" 2>/dev/null || warn "$dest 语法检查失败"
    return 0
  fi
  download_to "$url" "$dest"
}

install_bin_vps() {
  if [[ -e $BIN_VPS ]] && ! owns_vps_bin "$BIN_VPS"; then
    fail "已存在 $BIN_VPS 且不属于本工具，拒绝覆盖"
  fi
  cat >"$BIN_VPS" <<EOF
#!/usr/bin/env bash
# ${MARKER}
set -Eeuo pipefail
exec bash "${VPS_SH_LOCAL}" --menu-only "\$@"
EOF
  chmod 0755 "$BIN_VPS"
}

do_install() {
  require_root
  install_self_from_running
  ensure_module "$PROXY_SH_LOCAL" "${RAW_BASE}/proxy.sh"
  ensure_module "$TRAFFIC_SH_LOCAL" "${RAW_BASE}/traffic.sh"
  install_bin_vps
}

run_module() {
  local path=$1
  if [[ ! -f $path ]]; then
    warn "未找到模块: $path（可重新 curl|bash 安装入口）"
    return 1
  fi
  bash -n "$path" 2>/dev/null || {
    warn "模块语法错误: $path"
    return 1
  }
  # curl|bash 后 stdin 为 EOF，交互模块须绑到 /dev/tty
  set +e
  local rc=0
  if [[ -e /dev/tty ]]; then
    bash -c 'exec </dev/tty >/dev/tty 2>/dev/tty || exit 125; exec bash "$@"' _ "$path"
    rc=$?
    if [[ $rc -eq 125 ]]; then
      if command -v script >/dev/null 2>&1; then
        script -q -e -c "bash $(printf '%q' "$path")" /dev/null
        rc=$?
      else
        bash "$path"
        rc=$?
      fi
    fi
  else
    bash "$path"
    rc=$?
  fi
  set -e
  return 0
}

main_menu() {
  local c st
  ui_init
  while true; do
    st=$(entry_status_line)
    ui_head "VPS" "v${VERSION}"
    ui_status "$st"
    ui_gap
    ui_item 1 "代理管理" "REALITY · HY2 · CDN"
    ui_item 2 "流量管理" "额度 · 限速 · 检查"
    ui_gap
    ui_item 0 "退出"
    ui_foot
    c=""
    if ! read_tty -p "  请选择 [0-2]: " c; then
      warn "读取输入失败"
      return 1
    fi
    c=${c//[[:space:]]/}
    case $c in
      1) run_module "$PROXY_SH_LOCAL" || true ;;
      2) run_module "$TRAFFIC_SH_LOCAL" || true ;;
      0) return 0 ;;
      "") continue ;;
      *) warn "无效选项" ;;
    esac
  done
}

# curl|bash 时 stdin 是管道，装完后绑到真实终端再进菜单
enter_menu() {
  if [[ ! -t 0 ]] && [[ -r /dev/tty && -w /dev/tty && -f $VPS_SH_LOCAL ]]; then
    exec bash "$VPS_SH_LOCAL" --menu-only </dev/tty >/dev/tty 2>/dev/tty
  fi
  main_menu
}

usage() {
  cat <<EOF
${APP_NAME} v${VERSION}
  curl -fsSL ${RAW_BASE}/vps.sh | sudo bash
  sudo vps
EOF
}

main() {
  case ${1:-} in
    -h|--help|help) usage; exit 0 ;;
    --menu-only|menu) require_root; main_menu ;;
    --install|install) do_install; enter_menu ;;
    *) do_install; enter_menu ;;
  esac
}

if [[ -z ${BASH_SOURCE[0]:-} || ${BASH_SOURCE[0]} == "$0" || ${BASH_SOURCE[0]} == /dev/fd/* || ${BASH_SOURCE[0]} == /proc/self/fd/* ]]; then
  main "$@"
fi
