#!/usr/bin/env bash
# syw-vps-entrypoint — 极简 VPS 管理入口（仅调度 proxy / traffic 模块）
# 安装布局：
#   /usr/local/lib/syw-vps/{vps,proxy,traffic}.sh
#   /usr/local/bin/vps
set -Eeuo pipefail

APP_NAME="syw-vps"
VERSION="1.0.1"
LIB_DIR="/usr/local/lib/syw-vps"
BIN_VPS="/usr/local/bin/vps"
MARKER="syw-vps-entrypoint"
# 可用环境变量覆盖（测试/私有 fork）
RAW_BASE="${SYW_VPS_RAW_BASE:-https://raw.githubusercontent.com/syw7895/vps/main}"

VPS_SH_LOCAL="${LIB_DIR}/vps.sh"
PROXY_SH_LOCAL="${LIB_DIR}/proxy.sh"
TRAFFIC_SH_LOCAL="${LIB_DIR}/traffic.sh"

if [[ -t 1 ]]; then
  R=$'\033[0m' B=$'\033[1m'
  RED=$'\033[31m' GRN=$'\033[32m' YEL=$'\033[33m' CYN=$'\033[36m'
else
  R='' B='' RED='' GRN='' YEL='' CYN=''
fi

log()  { printf '%s[%s]%s %s\n' "$CYN" "$APP_NAME" "$R" "$*"; }
ok()   { printf '%s[%s]%s %s\n' "$GRN" "OK" "$R" "$*"; }
warn() { printf '%s[%s]%s %s\n' "$YEL" "!" "$R" "$*"; }
fail() { printf '%s[%s]%s %s\n' "$RED" "ERR" "$R" "$*" >&2; exit 1; }

# 管道安装时 stdin 非终端，交互一律走 /dev/tty
read_tty() {
  # usage: read_tty [-p prompt] var
  local prompt=""
  while [[ $# -gt 0 ]]; do
    case $1 in
      -p) prompt=$2; shift 2 ;;
      -r) shift ;; # ignore -r for simplicity; always raw-ish
      *) break ;;
    esac
  done
  local __var=${1:-REPLY}
  if [[ -r /dev/tty ]]; then
    # shellcheck disable=SC2162
    read -r -p "$prompt" "${__var?}" </dev/tty || return 1
  else
    # shellcheck disable=SC2162
    read -r -p "$prompt" "${__var?}" || return 1
  fi
}

require_root() {
  [[ $EUID -eq 0 ]] || fail "请使用 root 运行（例如: curl -fsSL ... | sudo bash）"
}

owns_vps_bin() {
  local f=$1
  [[ -f $f ]] || return 1
  grep -q "$MARKER" "$f" 2>/dev/null
}

download_to() {
  local url=$1 dest=$2
  local tmp
  tmp=$(mktemp)
  # shellcheck disable=SC2064
  trap 'rm -f "'"$tmp"'"' RETURN
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --connect-timeout 20 --max-time 120 "$url" -o "$tmp" \
      || fail "下载失败: $url"
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O "$tmp" "$url" || fail "下载失败: $url"
  else
    fail "需要 curl 或 wget"
  fi
  [[ -s $tmp ]] || fail "下载文件为空: $url"
  if ! bash -n "$tmp" 2>/dev/null; then
    fail "bash -n 语法检查失败: $url"
  fi
  install -m 0755 "$tmp" "$dest"
  ok "已安装 $(basename "$dest")"
}

install_self_from_running() {
  # 将当前入口脚本内容安装到 LIB（刷新 vps.sh）
  mkdir -p "$LIB_DIR"
  local src=${BASH_SOURCE[0]:-}
  local tmp
  tmp=$(mktemp)
  if [[ -n $src && -f $src && $src != /dev/fd/* && $src != /proc/self/fd/* && $src != - ]]; then
    cp -f "$src" "$tmp"
  else
    # 管道执行：从 RAW 再拉一次正式 vps.sh，保证落盘完整
    if command -v curl >/dev/null 2>&1; then
      curl -fsSL --connect-timeout 20 --max-time 120 "${RAW_BASE}/vps.sh" -o "$tmp" \
        || fail "无法下载 vps.sh: ${RAW_BASE}/vps.sh"
    else
      fail "管道安装需要 curl，且无法定位本地脚本源"
    fi
  fi
  [[ -s $tmp ]] || fail "vps.sh 内容为空"
  bash -n "$tmp" || fail "vps.sh bash -n 失败"
  install -m 0755 "$tmp" "$VPS_SH_LOCAL"
  rm -f "$tmp"
  ok "已刷新 $VPS_SH_LOCAL"
}

ensure_module() {
  local name=$1 url=$2 dest=$3
  if [[ -f $dest && -s $dest ]]; then
    log "已存在模块，跳过下载: $dest"
    if ! bash -n "$dest" 2>/dev/null; then
      warn "$dest 语法检查失败，请手动修复或删除后重装"
    fi
    return 0
  fi
  log "下载缺失模块: $name"
  download_to "$url" "$dest"
}

install_bin_vps() {
  if [[ -e $BIN_VPS ]] && ! owns_vps_bin "$BIN_VPS"; then
    fail "已存在 $BIN_VPS 且不属于本工具（缺少标记 $MARKER）。请手动处理后再安装。"
  fi
  cat >"$BIN_VPS" <<EOF
#!/usr/bin/env bash
# ${MARKER}
# wrapper → ${VPS_SH_LOCAL}
set -Eeuo pipefail
exec bash "${VPS_SH_LOCAL}" --menu-only "\$@"
EOF
  chmod 0755 "$BIN_VPS"
  ok "快捷命令: $BIN_VPS"
}

do_install() {
  require_root
  log "安装 / 刷新统一入口 (${VERSION})"
  install_self_from_running
  ensure_module "proxy.sh" "${RAW_BASE}/proxy.sh" "$PROXY_SH_LOCAL"
  ensure_module "traffic.sh" "${RAW_BASE}/traffic.sh" "$TRAFFIC_SH_LOCAL"
  install_bin_vps
  ok "安装完成。日常使用: vps"
}

run_module() {
  local path=$1 label=$2
  if [[ ! -f $path ]]; then
    warn "未找到 $label: $path"
    warn "请重新执行首次安装命令以下载缺失模块（不会覆盖已有模块）。"
    return 1
  fi
  if ! bash -n "$path" 2>/dev/null; then
    warn "$label 语法检查失败，已中止调用（不影响另一模块）"
    return 1
  fi
  # 模块失败不拖垮入口。
  # 重要：curl|bash / 非交互 sudo 后，stdin 常是管道 EOF。
  # proxy.sh 用 read 读 stdin（非 /dev/tty），且 set -e + ERR trap，
  # 读失败会报「脚本第 1237 行失败」。不修改 proxy.sh，在此强制把
  # stdin/stdout/stderr 绑到真实终端后再 exec 模块。
  set +e
  local rc=0
  if [[ -e /dev/tty ]]; then
    # 子 shell 内 exec 重定向，避免仅 </dev/tty 在部分环境下无效
    bash -c 'exec </dev/tty >/dev/tty 2>/dev/tty || exit 125; exec bash "$@"' _ "$path"
    rc=$?
    if [[ $rc -eq 125 ]]; then
      warn "无法绑定 /dev/tty，尝试 script 伪终端…"
      if command -v script >/dev/null 2>&1; then
        # Debian/Ubuntu: util-linux script
        script -q -e -c "bash $(printf '%q' "$path")" /dev/null
        rc=$?
      else
        bash "$path"
        rc=$?
      fi
    fi
  else
    warn "当前无 /dev/tty。请用 SSH 交互登录后执行: sudo vps"
    warn "或直接: sudo bash ${path}"
    bash "$path"
    rc=$?
  fi
  set -e
  if [[ $rc -ne 0 ]]; then
    warn "$label 退出码: $rc"
    if [[ $rc -eq 1 ]]; then
      warn "若刚用 curl|bash 安装：请先退出，再执行 sudo vps（不要用管道挂着交互）。"
      warn "也可直接: sudo v2   或   sudo bash ${PROXY_SH_LOCAL}"
    fi
  fi
  return 0
}

main_menu() {
  local c
  while true; do
    printf '\n%s%sVPS 管理%s\n' "$B" "$CYN" "$R"
    printf '  1. 代理管理\n'
    printf '  2. 流量管理\n'
    printf '  0. 退出\n'
    c=""
    read_tty -p "请选择: " c || c=0
    case $c in
      1) run_module "$PROXY_SH_LOCAL" "代理模块" || true ;;
      2) run_module "$TRAFFIC_SH_LOCAL" "流量模块" || true ;;
      0) printf '再见\n'; return 0 ;;
      *) warn "无效选项" ;;
    esac
  done
}

usage() {
  cat <<EOF
${APP_NAME} v${VERSION} — 统一入口（不含代理/流量业务逻辑）

首次安装:
  curl -fsSL ${RAW_BASE}/vps.sh | sudo bash

日常:
  vps

环境变量:
  SYW_VPS_RAW_BASE  覆盖 raw 基址（默认 GitHub main）
EOF
}

main() {
  local mode=${1:-}
  case $mode in
    -h|--help|help) usage; exit 0 ;;
    --menu-only|menu)
      require_root
      shift || true
      main_menu
      ;;
    --install|install)
      do_install
      main_menu
      ;;
    *)
      # 默认：安装/刷新入口后进菜单（适配 curl|bash）
      do_install
      main_menu
      ;;
  esac
}

if [[ -z ${BASH_SOURCE[0]:-} || ${BASH_SOURCE[0]} == "$0" || ${BASH_SOURCE[0]} == /dev/fd/* || ${BASH_SOURCE[0]} == /proc/self/fd/* ]]; then
  main "$@"
fi
