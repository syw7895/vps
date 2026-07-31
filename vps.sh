#!/usr/bin/env bash
# syw-vps-entrypoint — 极简 VPS 管理入口（仅调度 proxy / traffic）
# /usr/local/lib/syw-vps/{vps,proxy,traffic}.sh  +  /usr/local/bin/vps
set -Eeuo pipefail

APP_NAME="syw-vps"
VERSION="1.0.3"
LIB_DIR="/usr/local/lib/syw-vps"
BIN_VPS="/usr/local/bin/vps"
MARKER="syw-vps-entrypoint"
# 默认 main；生产建议 SYW_VPS_REF=<commit|tag> 使用不可变 URL
SYW_VPS_REF="${SYW_VPS_REF:-main}"
RAW_BASE="${SYW_VPS_RAW_BASE:-https://raw.githubusercontent.com/syw7895/vps/${SYW_VPS_REF}}"
# 模块期望 SHA-256（scripts/update-checksums.sh 维护；环境变量可覆盖）
PROXY_SHA256="${SYW_VPS_PROXY_SHA256:-bedf0dcd4fcd9cfaf0f4ab19f5cda40fa22ce4a1d497f887bc5b556316dd4cc9}"
TRAFFIC_SHA256="${SYW_VPS_TRAFFIC_SHA256:-acd959d2f63646f3951a1399e7089116b3d71955ffddef7d3d981009462ef454}"
INTEGRITY_FILE="${LIB_DIR}/checksums.sha256"

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

is_valid_sha256() { [[ $1 =~ ^[A-Fa-f0-9]{64}$ ]]; }

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    fail "需要 sha256sum 或 shasum"
  fi
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

# 下载：bash -n + SHA-256（除非 SYW_VPS_ALLOW_UNVERIFIED=1）
download_to() {
  local url=$1 dest=$2 expected=${3:-} tmp actual
  tmp=$(mktemp)
  if ! http_get "$url" "$tmp"; then
    rm -f "$tmp"
    fail "下载失败: $url"
  fi
  if [[ ! -s $tmp ]] || ! bash -n "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    fail "下载无效或语法错误: $url"
  fi
  if is_valid_sha256 "$expected"; then
    actual=$(sha256_file "$tmp")
    if [[ ${actual,,} != "${expected,,}" ]]; then
      rm -f "$tmp"
      fail "哈希不匹配: $url (expect=${expected:0:12}… got=${actual:0:12}…)"
    fi
  elif [[ ${SYW_VPS_ALLOW_UNVERIFIED:-0} == 1 ]]; then
    warn "SYW_VPS_ALLOW_UNVERIFIED=1：跳过哈希校验 $url（不安全）"
  else
    rm -f "$tmp"
    fail "拒绝未校验下载: $url（内置/清单哈希无效；开发可用 SYW_VPS_ALLOW_UNVERIFIED=1）"
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
    # 管道安装：当前 stdin 内容即根信任；仅做语法检查
    http_get "${RAW_BASE}/vps.sh" "$tmp" || {
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
  local dest=$1 url=$2 expected=$3 actual
  if [[ -f $dest && -s $dest ]]; then
    if is_valid_sha256 "$expected"; then
      actual=$(sha256_file "$dest")
      if [[ ${actual,,} == "${expected,,}" ]]; then
        return 0
      fi
      warn "本地模块哈希与期望不符，重新下载: $dest"
    else
      bash -n "$dest" 2>/dev/null || warn "$dest 语法检查失败"
      if [[ ${SYW_VPS_ALLOW_UNVERIFIED:-0} == 1 ]]; then
        return 0
      fi
    fi
  fi
  download_to "$url" "$dest" "$expected"
}

resolve_module_hashes() {
  local sums p_hash t_hash
  if is_valid_sha256 "$PROXY_SHA256" && is_valid_sha256 "$TRAFFIC_SHA256"; then
    return 0
  fi
  sums=$(mktemp)
  if ! http_get "${RAW_BASE}/checksums.sha256" "$sums" 2>/dev/null; then
    rm -f "$sums"
    [[ ${SYW_VPS_ALLOW_UNVERIFIED:-0} == 1 ]] && return 0
    fail "内置模块哈希无效且无法下载 checksums.sha256（ref=${SYW_VPS_REF}）"
  fi
  p_hash=$(awk '$2=="proxy.sh"{print $1; exit}' "$sums" || true)
  t_hash=$(awk '$2=="traffic.sh"{print $1; exit}' "$sums" || true)
  is_valid_sha256 "$p_hash" && PROXY_SHA256=$p_hash
  is_valid_sha256 "$t_hash" && TRAFFIC_SHA256=$t_hash
  if ! is_valid_sha256 "$PROXY_SHA256" || ! is_valid_sha256 "$TRAFFIC_SHA256"; then
    rm -f "$sums"
    fail "checksums.sha256 缺少有效 proxy/traffic 哈希"
  fi
  warn "使用 ${SYW_VPS_REF}/checksums.sha256 校验模块（发布时应内置哈希）"
  install -m 0644 "$sums" "$INTEGRITY_FILE"
  rm -f "$sums"
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
  resolve_module_hashes
  ensure_module "$PROXY_SH_LOCAL" "${RAW_BASE}/proxy.sh" "$PROXY_SHA256"
  ensure_module "$TRAFFIC_SH_LOCAL" "${RAW_BASE}/traffic.sh" "$TRAFFIC_SHA256"
  # 写入 integrity 清单供 traffic 在线更新比对
  {
    printf '%s  %s\n' "$PROXY_SHA256" proxy.sh
    printf '%s  %s\n' "$TRAFFIC_SHA256" traffic.sh
  } >"$INTEGRITY_FILE"
  chmod 644 "$INTEGRITY_FILE" 2>/dev/null || true
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

固定版本:
  export SYW_VPS_REF=<git-commit-or-tag>
  curl -fsSL https://raw.githubusercontent.com/syw7895/vps/\${SYW_VPS_REF}/vps.sh | sudo bash

完整性: 下载 proxy/traffic 时校验内置或 checksums.sha256 中的 SHA-256。
开发跳过: SYW_VPS_ALLOW_UNVERIFIED=1（勿用于生产）
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
