# shellcheck shell=bash
# 内核：Xray / Hysteria2 的下载、校验、安装、更新与回滚；屏蔽规则数据文件

core_bin()  { case $1 in xray) echo "$BIN_DIR/xray" ;; hy2) echo "$BIN_DIR/hysteria" ;; esac; }
core_unit() { case $1 in xray) echo vps-xray ;; hy2) echo vps-hy2 ;; esac; }
core_name() { case $1 in xray) echo Xray ;; hy2) echo Hysteria2 ;; esac; }

core_arch() {
  local m
  m=$(uname -m)
  case $1:$m in
    xray:x86_64) echo 64 ;;
    xray:aarch64 | xray:arm64) echo arm64-v8a ;;
    xray:armv7*) echo arm32-v7a ;;
    xray:i?86) echo 32 ;;
    xray:loongarch64) echo loong64 ;;
    xray:s390x | xray:riscv64) echo "$m" ;;
    hy2:x86_64) echo amd64 ;;
    hy2:aarch64 | hy2:arm64) echo arm64 ;;
    hy2:armv7*) echo arm ;;
    hy2:i?86) echo 386 ;;
    hy2:loongarch64) echo loong64 ;;
    hy2:s390x | hy2:riscv64) echo "$m" ;;
    *) return 1 ;;
  esac
}

# core_version_of 内核 二进制 → vX.Y.Z
core_version_of() {
  local out
  out=$("$2" version 2>/dev/null) || return 1
  case $1 in
    xray) out=$(awk 'NR == 1 {print $2}' <<<"$out") ;;
    hy2) out=$(awk '$1 == "Version:" {print $2}' <<<"$out") ;;
  esac
  out=v${out#v}
  [[ $out =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] && printf '%s' "$out"
}

core_version() {
  local bin
  bin=$(core_bin "$1")
  [[ -x $bin ]] && core_version_of "$1" "$bin"
}

core_latest() {
  local tag
  case $1 in
    xray) tag=$(latest_tag XTLS/Xray-core) || return 1 ;;
    hy2) tag=$(latest_tag apernet/hysteria) || return 1; tag=${tag#app/} ;;
  esac
  [[ $tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] && printf '%s' "$tag"
}

ver_lt() {
  [[ $1 != "$2" && $(printf '%s\n%s\n' "${1#v}" "${2#v}" | sort -V | head -n1) == "${1#v}" ]]
}

# core_fetch 内核 版本 目标文件：下载官方发布包，核对 SHA256 和版本号
core_fetch() {
  local core=$1 ver=$2 out=$3 arch work base want got
  arch=$(core_arch "$core") || { warn "不支持的 CPU 架构: $(uname -m)"; return 1; }
  work=$(mktemp -d)
  case $core in
    xray)
      base=https://github.com/XTLS/Xray-core/releases/download/$ver/Xray-linux-$arch.zip
      if ! fetch "$base" "$work/pkg" || ! fetch "$base.dgst" "$work/sum"; then
        rm -rf "$work"; warn "下载 Xray $ver 失败"; return 1
      fi
      want=$(sed -nE 's/^SHA(2-)?256= *([0-9a-fA-F]{64})[[:space:]]*$/\2/p' "$work/sum" | head -n1)
      ;;
    hy2)
      base=https://github.com/apernet/hysteria/releases/download/app/$ver
      if ! fetch "$base/hysteria-linux-$arch" "$work/pkg" || ! fetch "$base/hashes.txt" "$work/sum"; then
        rm -rf "$work"; warn "下载 Hysteria2 $ver 失败"; return 1
      fi
      want=$(awk -v f="hysteria-linux-$arch" '{n = $2; sub(/.*\//, "", n)} n == f {print $1; exit}' "$work/sum")
      ;;
  esac
  got=$(sha256_of "$work/pkg")
  if [[ ${#want} -ne 64 || ${got,,} != "${want,,}" ]]; then
    rm -rf "$work"; warn "$(core_name "$core") $ver 校验失败（SHA256 不匹配）"; return 1
  fi
  if [[ $core == xray ]]; then
    unzip -p "$work/pkg" xray >"$out" 2>/dev/null || { rm -rf "$work"; warn "解压 Xray 失败"; return 1; }
  else
    cp "$work/pkg" "$out"
  fi
  rm -rf "$work"
  chmod 755 "$out"
  if [[ $(core_version_of "$core" "$out" || true) != "$ver" ]]; then
    warn "$(core_name "$core") 新版本无法运行或版本号不符"
    return 1
  fi
}

# 没装才装，装最新正式版
core_install() {
  local core=$1 bin ver tmp
  bin=$(core_bin "$core")
  [[ -x $bin ]] && return 0
  [[ $core == xray ]] && need_pkg unzip unzip
  ver=$(core_latest "$core") || die "无法获取 $(core_name "$core") 最新版本，请检查网络"
  say "安装 $(core_name "$core") $ver ..."
  mkdir -p "$BIN_DIR"
  tmp=$(mktemp "$bin.XXXXXX")
  core_fetch "$core" "$ver" "$tmp" || { rm -f "$tmp"; die "$(core_name "$core") 安装失败"; }
  mv -f "$tmp" "$bin"
}

core_remove() { rm -f "$(core_bin "$1")" "$(core_bin "$1").old"; }

# Xray 配置校验（规则文件路径通过环境变量传入）
xray_test() {
  XRAY_LOCATION_ASSET=$SHARE_DIR "$1" run -test -confdir "$2" 2>&1
}

# core_update 内核：有新版就下载、校验、替换、重启，失败回滚到旧版
core_update() {
  local core=$1 name bin cur latest tmp unit out
  name=$(core_name "$core")
  bin=$(core_bin "$core")
  [[ -x $bin ]] || return 0
  cur=$(core_version "$core") || cur=v0.0.0
  latest=$(core_latest "$core") || { warn "无法获取 $name 最新版本"; return 1; }
  if ! ver_lt "$cur" "$latest"; then
    say "$name 已是最新（$cur）"
    return 0
  fi
  [[ $core == xray ]] && need_pkg unzip unzip
  tmp=$(mktemp "$bin.XXXXXX")
  core_fetch "$core" "$latest" "$tmp" || { rm -f "$tmp"; return 1; }
  if [[ $core == xray && -d $XRAY_DIR ]] && ! out=$(xray_test "$tmp" "$XRAY_DIR"); then
    rm -f "$tmp"
    warn "Xray $latest 不接受当前配置，保留 $cur"
    printf '%s\n' "$out" | tail -n 3 >&2
    return 1
  fi
  cp -p "$bin" "$bin.old"
  mv -f "$tmp" "$bin"
  unit=$(core_unit "$core")
  if svc_active "$unit"; then
    stats_sample || true
    if ! svc_restart "$unit"; then
      mv -f "$bin.old" "$bin"
      svc_restart "$unit" || true
      warn "$name $latest 启动失败，已回滚到 $cur"
      return 1
    fi
  fi
  rm -f "$bin.old"
  ok "$name 已更新：$cur → $latest"
}

# ---------- 屏蔽规则数据（Loyalsoldier/v2ray-rules-dat） ----------
GEO_CHANGED=0

geo_ready() { [[ -s $SHARE_DIR/geoip.dat && -s $SHARE_DIR/geosite.dat ]]; }

# 下载最新规则文件并核对 SHA256；有变化时 GEO_CHANGED=1
geo_update() {
  local tag work f base want got
  GEO_CHANGED=0
  tag=$(latest_tag Loyalsoldier/v2ray-rules-dat) || { warn "无法获取规则文件版本"; return 1; }
  [[ $tag =~ ^[A-Za-z0-9._-]+$ ]] || { warn "规则文件版本号异常"; return 1; }
  work=$(mktemp -d)
  for f in geoip.dat geosite.dat; do
    base=https://github.com/Loyalsoldier/v2ray-rules-dat/releases/download/$tag/$f
    if ! fetch "$base" "$work/$f" || ! fetch "$base.sha256sum" "$work/$f.sum"; then
      rm -rf "$work"; warn "下载规则文件 $f 失败"; return 1
    fi
    want=$(awk '{print $1; exit}' "$work/$f.sum")
    got=$(sha256_of "$work/$f")
    if [[ ${#want} -ne 64 || ${got,,} != "${want,,}" ]]; then
      rm -rf "$work"; warn "规则文件 $f 校验失败"; return 1
    fi
  done
  mkdir -p "$SHARE_DIR"
  for f in geoip.dat geosite.dat; do
    if ! cmp -s "$work/$f" "$SHARE_DIR/$f"; then
      install -m 644 "$work/$f" "$SHARE_DIR/$f"
      GEO_CHANGED=1
    fi
  done
  rm -rf "$work"
}
