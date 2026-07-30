#!/usr/bin/env bash
# syw-vps-entrypoint — 极简 VPS 管理入口（仅调度 proxy / traffic）
# /usr/local/lib/syw-vps/{vps,proxy,traffic}.sh  +  /usr/local/bin/vps
set -Eeuo pipefail

APP_NAME="syw-vps"
VERSION="1.0.2"
LIB_DIR="/usr/local/lib/syw-vps"
BIN_VPS="/usr/local/bin/vps"
MARKER="syw-vps-entrypoint"
RAW_BASE="${SYW_VPS_RAW_BASE:-https://raw.githubusercontent.com/syw7895/vps/main}"

VPS_SH_LOCAL="${LIB_DIR}/vps.sh"
PROXY_SH_LOCAL="${LIB_DIR}/proxy.sh"
TRAFFIC_SH_LOCAL="${LIB_DIR}/traffic.sh"

if [[ -t 1 ]]; then
  R=$'\033[0m' B=$'\033[1m'
  RED=$'\033[31m' YEL=$'\033[33m' CYN=$'\033[36m'
else
  R='' B='' RED='' YEL='' CYN=''
fi

warn() { printf '%s[%s]%s %s\n' "$YEL" "!" "$R" "$*"; }
fail() { printf '%s[%s]%s %s\n' "$RED" "ERR" "$R" "$*" >&2; exit 1; }

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
  if [[ -r /dev/tty ]]; then
    read -r -p "$prompt" "${__var?}" </dev/tty || return 1
  else
    read -r -p "$prompt" "${__var?}" || return 1
  fi
}

require_root() {
  [[ $EUID -eq 0 ]] || fail "请使用 root（curl -fsSL ... | sudo bash 或 sudo vps）"
}

owns_vps_bin() {
  [[ -f $1 ]] && grep -q "$MARKER" "$1" 2>/dev/null
}

download_to() {
  local url=$1 dest=$2 tmp
  tmp=$(mktemp)
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --connect-timeout 20 --max-time 120 "$url" -o "$tmp" || {
      rm -f "$tmp"
      fail "下载失败: $url"
    }
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O "$tmp" "$url" || {
      rm -f "$tmp"
      fail "下载失败: $url"
    }
  else
    rm -f "$tmp"
    fail "需要 curl 或 wget"
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
    curl -fsSL --connect-timeout 20 --max-time 120 "${RAW_BASE}/vps.sh" -o "$tmp" \
      || {
        rm -f "$tmp"
        fail "无法下载 vps.sh"
      }
  fi
  if [[ ! -s $tmp ]] || ! bash -n "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    fail "vps.sh 无效"
  fi
  install -m 0755 "$tmp" "$VPS_SH_LOCAL"
  rm -f "$tmp"
}

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
    warn "未找到模块: $path（可重新 curl|bash 安装入口以下载缺失文件）"
    return 1
  fi
  bash -n "$path" 2>/dev/null || {
    warn "模块语法错误: $path"
    return 1
  }
  # proxy 用 stdin 的 read；curl|bash 后 stdin 为 EOF，须绑到 /dev/tty
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
  local c D
  if [[ -t 1 ]]; then D=$'\033[2m'; else D=''; fi
  while true; do
    printf '\n'
    printf '  %s╭──────────────────────────────╮%s\n' "$D" "$R"
    printf '  %s│%s  %sVPS 管理%s  %sv%s%s\n' "$D" "$R" "$B$CYN" "$R" "$D" "$VERSION" "$R"
    printf '  %s├──────────────────────────────┤%s\n' "$D" "$R"
    printf '  %s│%s   1  代理管理\n' "$D" "$R"
    printf '  %s│%s   2  流量管理\n' "$D" "$R"
    printf '  %s│%s   0  退出\n' "$D" "$R"
    printf '  %s╰──────────────────────────────╯%s\n' "$D" "$R"
    c=""
    read_tty -p "  请选择 › " c || c=0
    case $c in
      1) run_module "$PROXY_SH_LOCAL" || true ;;
      2) run_module "$TRAFFIC_SH_LOCAL" || true ;;
      0) return 0 ;;
      *) warn "无效选项" ;;
    esac
  done
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
    --install|install) do_install; main_menu ;;
    *) do_install; main_menu ;;
  esac
}

if [[ -z ${BASH_SOURCE[0]:-} || ${BASH_SOURCE[0]} == "$0" || ${BASH_SOURCE[0]} == /dev/fd/* || ${BASH_SOURCE[0]} == /proc/self/fd/* ]]; then
  main "$@"
fi
