#!/usr/bin/env bash
# syw-vps-entrypoint — 入口：调度 proxy / traffic
# 安装: /usr/local/lib/syw-vps/{vps,proxy,traffic}.sh  +  /usr/local/bin/vps
set -Eeuo pipefail

APP_NAME="syw-vps"
VERSION="1.3.1"
LIB_DIR="/usr/local/lib/syw-vps"
BIN_VPS="/usr/local/bin/vps"
MARKER="syw-vps-entrypoint"
# 可选固定提交: export SYW_VPS_REF=<commit-sha>
SYW_VPS_REF="${SYW_VPS_REF:-main}"
SYW_VPS_REPO="${SYW_VPS_REPO:-syw7895/vps}"
SYW_VPS_BRANCH="${SYW_VPS_BRANCH:-main}"
SYW_VPS_UPDATE_API="${SYW_VPS_UPDATE_API:-https://api.github.com/repos/${SYW_VPS_REPO}/commits/${SYW_VPS_BRANCH}}"
SYW_VPS_UPDATE_STATE="${SYW_VPS_UPDATE_STATE:-${LIB_DIR}/update-state}"
SYW_VPS_UPDATE_SERVICE="${SYW_VPS_UPDATE_SERVICE:-/etc/systemd/system/syw-vps-update.service}"
SYW_VPS_UPDATE_TIMER="${SYW_VPS_UPDATE_TIMER:-/etc/systemd/system/syw-vps-update.timer}"
SYW_VPS_UPDATE_LOCK="${SYW_VPS_UPDATE_LOCK:-/run/lock/syw-vps-update.lock}"
SYW_VPS_BACKUP_DIR="${SYW_VPS_BACKUP_DIR:-${LIB_DIR}/backups}"
SYW_VPS_BACKUP_KEEP="${SYW_VPS_BACKUP_KEEP:-3}"
RAW_BASE="${SYW_VPS_RAW_BASE:-https://raw.githubusercontent.com/${SYW_VPS_REPO}/${SYW_VPS_REF}}"

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

warn() { printf '  %s!%s  %s\n' "$YEL" "$R" "$*"; }
fail() { printf '  %s×%s  %s\n' "$RED" "$R" "$*" >&2; exit 1; }
ok() { printf '  %s●%s  %s\n' "$GRN" "$R" "$*"; }

# ---------- UI ----------
ui_head() {
  printf '\n  %s%s%s  %s%s%s\n' "$B$CYN" "$1" "$R" "$D" "$2" "$R"
}
ui_status() { printf '  %s\n' "$1"; }
ui_gap() { printf '\n'; }
ui_item() {
  # $1 序号  $2 文案  $3 可选 danger|muted
  local num=$1 text=$2 style=${3:-} nc=$CYN tc=
  case $style in
    danger) nc=$RED; tc=$RED ;;
    muted)  nc=$D; tc=$D ;;
  esac
  printf '  %s%2s.%s  %s%s%s\n' "$nc" "$num" "$R" "$tc" "$text" "$R"
}

# 模块可用：文件存在且 bash -n 通过。正常时不输出（无状态行）。
module_usable() {
  local f=$1
  [[ -f $f && -s $f ]] && bash -n "$f" 2>/dev/null
}

entry_warning_line() {
  local okp=0 okt=0
  module_usable "$PROXY_SH_LOCAL" && okp=1 || true
  module_usable "$TRAFFIC_SH_LOCAL" && okt=1 || true
  if (( okp && okt )); then
    return 0
  fi
  if (( !okp && !okt )); then
    printf '%s×%s  功能模块不可用' "$RED" "$R"
  elif (( !okp )); then
    printf '%s!%s  代理模块不可用' "$YEL" "$R"
  else
    printf '%s!%s  流量模块不可用' "$YEL" "$R"
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

  if [[ -t 0 ]]; then
    read -r -p "$prompt" "$__var" || return 1
    return 0
  fi

  if { : </dev/tty; } 2>/dev/null; then
    read -r -p "$prompt" "$__var" </dev/tty || return 1
    return 0
  fi

  read -r -p "$prompt" "$__var" || return 1
}

require_root() {
  [[ $EUID -eq 0 ]] || fail "请使用 root（curl -fsSL ... | sudo bash 或 sudo vps）"
}

owns_vps_bin() {
  [[ -f $1 ]] && grep -q "$MARKER" "$1" 2>/dev/null
}

http_get() {
  local url=$1 dest=$2
  [[ $url == https://* ]] || fail "拒绝使用非 HTTPS 更新地址: $url"
  if command -v curl >/dev/null 2>&1; then
    curl --proto '=https' --proto-redir '=https' -fsSL --connect-timeout 20 --max-time 120 "$url" -o "$dest"
  elif command -v wget >/dev/null 2>&1; then
    wget --https-only -q -O "$dest" "$url"
  else
    fail "需要 curl 或 wget"
  fi
}

github_api_get() {
  local url=$1 dest=$2
  command -v curl >/dev/null 2>&1 || fail "自动更新需要 curl"
  [[ $url == https://* ]] || fail "拒绝使用非 HTTPS 更新地址: $url"
  curl --proto '=https' --proto-redir '=https' -fsSL --retry 3 --connect-timeout 20 --max-time 120 \
    -H 'Accept: application/vnd.github+json' \
    -H 'User-Agent: syw-vps-updater' "$url" -o "$dest"
}

# 下载：仅 bash -n
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

# 安装时拉取最新模块脚本（只覆盖 .sh，不动节点/证书配置）
ensure_module() {
  local dest=$1 url=$2
  download_to "$url" "$dest"
}

read_update_ref() {
  [[ -r $SYW_VPS_UPDATE_STATE ]] || return 0
  sed -nE 's/^REF=([0-9a-fA-F]{40})$/\1/p' "$SYW_VPS_UPDATE_STATE" | head -n1
}

write_update_state() {
  local ref=$1 result=${2:-ok} tmp
  mkdir -p "$(dirname "$SYW_VPS_UPDATE_STATE")"
  tmp=$(mktemp "${SYW_VPS_UPDATE_STATE}.XXXXXX")
  printf 'REF=%s\nLAST_CHECK=%s\nRESULT=%s\n' \
    "$ref" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$result" >"$tmp"
  chmod 644 "$tmp"
  mv -f "$tmp" "$SYW_VPS_UPDATE_STATE"
}

resolve_latest_ref() {
  local data ref tmp
  tmp=$(mktemp)
  if ! github_api_get "$SYW_VPS_UPDATE_API" "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  data=$(cat "$tmp")
  rm -f "$tmp"
  ref=$(sed -nE 's/.*"sha"[[:space:]]*:[[:space:]]*"([0-9a-fA-F]{40})".*/\1/p' <<<"$data" | head -n1)
  [[ $ref =~ ^[0-9a-fA-F]{40}$ ]] || return 1
  printf '%s\n' "${ref,,}"
}

module_marker_ok() {
  local name=$1 file=$2
  case $name in
    vps.sh) grep -q '^APP_NAME="syw-vps"$' "$file" ;;
    proxy.sh) grep -q '^APP_NAME="vps-proxy"$' "$file" ;;
    traffic.sh) grep -q '^APP_NAME="vps-traffic"$' "$file" ;;
    *) return 1 ;;
  esac
}

download_module_candidate() {
  local name=$1 ref=$2 dest=$3 url
  url="https://raw.githubusercontent.com/${SYW_VPS_REPO}/${ref}/${name}"
  http_get "$url" "$dest" || fail "自动更新下载失败: $url"
  [[ -s $dest ]] || fail "自动更新脚本为空: $name"
  bash -n "$dest" 2>/dev/null || fail "自动更新脚本语法错误: $name"
  module_marker_ok "$name" "$dest" || fail "自动更新脚本标识不匹配: $name"
}

restore_module_backup() {
  local backup=$1 name dest
  for name in vps.sh proxy.sh traffic.sh; do
    case $name in
      vps.sh) dest=$VPS_SH_LOCAL ;;
      proxy.sh) dest=$PROXY_SH_LOCAL ;;
      traffic.sh) dest=$TRAFFIC_SH_LOCAL ;;
    esac
    if [[ -f ${backup}/${name} ]]; then
      install -m 0755 "${backup}/${name}" "$dest"
    else
      rm -f -- "$dest"
    fi
  done
}

prune_module_backups() {
  local keep=${SYW_VPS_BACKUP_KEEP:-3} i
  local -a dirs=()
  [[ $keep =~ ^[0-9]+$ ]] && ((keep >= 1)) || keep=3
  [[ -d $SYW_VPS_BACKUP_DIR ]] || return 0
  mapfile -t dirs < <(ls -1dt "$SYW_VPS_BACKUP_DIR"/modules.* 2>/dev/null || true)
  for ((i = keep; i < ${#dirs[@]}; i++)); do
    [[ -d ${dirs[i]} ]] && rm -rf -- "${dirs[i]}"
  done
}

refresh_proxy_auto_update() {
  if { [[ -f /etc/systemd/system/syw-hy2-update.timer ]] ||
       command -v xray >/dev/null 2>&1 ||
       [[ -x /usr/local/bin/hysteria ]]; }; then
    bash "$PROXY_SH_LOCAL" configure-auto-update >/dev/null 2>&1
  fi
}

update_modules() (
  local mode=${1:-manual} ref current tmp backup name dest new rc keep_backup=0
  mode=${mode#--}
  tmp=""
  backup=""
  trap '[[ -n "${tmp:-}" ]] && rm -rf -- "$tmp"; [[ -n "${backup:-}" && ${keep_backup:-0} -eq 0 ]] && rm -rf -- "$backup"' EXIT
  require_root
  mkdir -p "$LIB_DIR"
  current=$(read_update_ref || true)
  ref=$(resolve_latest_ref) || {
    write_update_state "${current:-unknown}" check-failed
    fail "无法获取 syw-vps 最新提交"
  }
  if [[ $ref == "$current" ]]; then
    write_update_state "$ref" current
    if ! refresh_proxy_auto_update; then
      warn "代理核心更新定时器刷新失败（脚本已是最新）"
    fi
    [[ $mode == auto ]] || ok "syw-vps 脚本已是最新: $ref"
    return 0
  fi

  tmp=$(mktemp -d /tmp/${APP_NAME}.modules.XXXXXX)
  for name in vps.sh proxy.sh traffic.sh; do
    download_module_candidate "$name" "$ref" "$tmp/$name"
  done

  mkdir -p "$SYW_VPS_BACKUP_DIR"
  chmod 700 "$SYW_VPS_BACKUP_DIR" 2>/dev/null || true
  backup=$(mktemp -d "${SYW_VPS_BACKUP_DIR}/modules.XXXXXX")
  for name in vps.sh proxy.sh traffic.sh; do
    case $name in
      vps.sh) dest=$VPS_SH_LOCAL ;;
      proxy.sh) dest=$PROXY_SH_LOCAL ;;
      traffic.sh) dest=$TRAFFIC_SH_LOCAL ;;
    esac
    [[ -f $dest ]] && cp -p "$dest" "$backup/$name"
  done

  set +e
  for name in vps.sh proxy.sh traffic.sh; do
    case $name in
      vps.sh) dest=$VPS_SH_LOCAL ;;
      proxy.sh) dest=$PROXY_SH_LOCAL ;;
      traffic.sh) dest=$TRAFFIC_SH_LOCAL ;;
    esac
    new=$(mktemp "${dest}.new.XXXXXX")
    install -m 0755 "$tmp/$name" "$new" && mv -f "$new" "$dest"
    rc=$?
    ((rc == 0)) || break
  done
  set -e
  if ((rc != 0)); then
    restore_module_backup "$backup"
    fail "syw-vps 脚本替换失败，已恢复旧版"
  fi
  if ! refresh_proxy_auto_update; then
    warn "代理核心更新定时器刷新失败（脚本已更新）"
  fi
  keep_backup=1
  write_update_state "$ref" updated
  prune_module_backups
  [[ $mode == auto ]] || ok "syw-vps 脚本已更新: ${current:-unknown} → $ref"
)

enable_script_auto_update() {
  command -v systemctl >/dev/null 2>&1 || {
    warn "未检测到 systemd，跳过 syw-vps 自动更新定时器"
    return 0
  }
  install -d -m 755 "$(dirname "$SYW_VPS_UPDATE_LOCK")"
  cat >"$SYW_VPS_UPDATE_SERVICE" <<EOF
[Unit]
Description=syw-vps management scripts update
After=network-online.target
Wants=network-online.target
ConditionPathExists=${VPS_SH_LOCAL}

[Service]
Type=oneshot
TimeoutStartSec=15min
ExecStart=/bin/bash ${VPS_SH_LOCAL} --update-all --auto
EOF
  cat >"$SYW_VPS_UPDATE_TIMER" <<'EOF'
[Unit]
Description=Weekly syw-vps management scripts update

[Timer]
OnCalendar=Sun *-*-* 03:00:00
RandomizedDelaySec=6h
Persistent=true
Unit=syw-vps-update.service

[Install]
WantedBy=timers.target
EOF
  chmod 644 "$SYW_VPS_UPDATE_SERVICE" "$SYW_VPS_UPDATE_TIMER"
  systemctl daemon-reload
  systemctl enable --now syw-vps-update.timer >/dev/null
}

update_all() {
  local mode=${1:-manual}
  mode=${mode#--}
  require_root
  command -v flock >/dev/null 2>&1 || fail "自动更新需要 flock（util-linux）"
  install -d -m 755 "$(dirname "$SYW_VPS_UPDATE_LOCK")"
  exec 9>"$SYW_VPS_UPDATE_LOCK"
  if ! flock -n 9 2>/dev/null; then
    [[ $mode == auto ]] || warn "已有 syw-vps 更新任务运行中"
    return 0
  fi
  update_modules "$mode"
  enable_script_auto_update
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
  enable_script_auto_update
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
  return "$rc"
}

main_menu() {
  local c st
  while true; do
    st=$(entry_warning_line || true)
    ui_head "VPS" "v${VERSION}"
    if [[ -n ${st:-} ]]; then
      ui_status "$st"
    fi
    ui_gap
    ui_item 1 "代理管理"
    ui_item 2 "流量管理"
    ui_gap
    ui_item 0 "退出" muted
    ui_gap
    printf '  请选择 [0-2]: '
    c=""
    if ! read_tty c; then
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

# 非 TTY stdin：能打开 /dev/tty 则 re-exec 绑定后进菜单（避免无限递归：绑定后 -t 0 为真）
enter_menu() {
  if [[ ! -t 0 && -f $VPS_SH_LOCAL ]] &&
     { : </dev/tty >/dev/tty; } 2>/dev/null; then
    exec bash "$VPS_SH_LOCAL" --menu-only \
      </dev/tty >/dev/tty 2>/dev/tty
  fi
  main_menu
}

usage() {
  cat <<EOF
${APP_NAME} v${VERSION}
  curl -fsSL ${RAW_BASE}/vps.sh | sudo bash
  sudo vps
  sudo vps update                 检查并更新管理脚本
EOF
}

main() {
  case ${1:-} in
    -h|--help|help) usage; exit 0 ;;
    --menu-only|menu) require_root; enter_menu ;;
    --install|install) do_install; enter_menu ;;
    --update-all|update|update-all)
      shift || true
      update_all "${1:-manual}"
      ;;
    *) do_install; enter_menu ;;
  esac
}

if [[ -z ${BASH_SOURCE[0]:-} || ${BASH_SOURCE[0]} == "$0" || ${BASH_SOURCE[0]} == /dev/fd/* || ${BASH_SOURCE[0]} == /proc/self/fd/* ]]; then
  main "$@"
fi
