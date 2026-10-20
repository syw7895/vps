# shellcheck shell=bash
# 测试框架：每个用例一个沙盒目录，系统命令用 tests/stubs 里的假命令代替

set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PASS=0
FAIL=0
OUT=""
RC=0

XRAY_ARCH=64
HY2_ARCH=amd64
case $(uname -m) in
  aarch64 | arm64) XRAY_ARCH=arm64-v8a HY2_ARCH=arm64 ;;
esac

setup() {
  [[ -n ${VPS_ROOT:-} && -d $VPS_ROOT ]] && rm -rf "$VPS_ROOT"
  VPS_ROOT=$(mktemp -d)
  export VPS_ROOT VPS_TEST=1 VPS_NOW=1792454400 # 2026-10-20 00:00 UTC
  export TZ=UTC
  export PATH="$ROOT/tests/stubs:${PATH#"$ROOT/tests/stubs:"}"
  mkdir -p "$VPS_ROOT/.stub" "$VPS_ROOT/proc/sys/kernel/random"
  echo boot-1 >"$VPS_ROOT/proc/sys/kernel/random/boot_id"
  nic eth0 0 0
  net_text https://api.ipify.org 203.0.113.10
}

teardown() { [[ -n ${VPS_ROOT:-} ]] && rm -rf "$VPS_ROOT"; }

# nic 网卡 发送字节 接收字节
nic() {
  mkdir -p "$VPS_ROOT/sys/class/net/$1/statistics"
  echo "$2" >"$VPS_ROOT/sys/class/net/$1/statistics/tx_bytes"
  echo "$3" >"$VPS_ROOT/sys/class/net/$1/statistics/rx_bytes"
}

# 运行 vps，输出放在 OUT，退出码放在 RC
vps() {
  OUT=$(bash "$ROOT/vps" "$@" 2>&1)
  RC=$?
  scan_output "vps $*"
}

# 任何输出里出现脚本内部错误都算失败（不依赖具体断言）
scan_output() {
  local pat
  for pat in "unbound variable" "command not found" "syntax error" "No such file or directory"; do
    if [[ $OUT == *"$pat"* ]]; then fail "$1 的输出里有「$pat」" "$OUT"; fi
  done
  return 0
}

# 带标准输入运行（菜单测试）
vps_in() {
  local input=$1
  shift
  OUT=$(printf '%b' "$input" | bash "$ROOT/vps" "$@" 2>&1)
  RC=$?
  scan_output "菜单输入 $input"
}

# ---------- 假网络 ----------
net_key() { printf '%s' "$1" | sed 's/[^A-Za-z0-9]/_/g'; }
net_text() { mkdir -p "$VPS_ROOT/.stub/net"; printf '%s' "$2" >"$VPS_ROOT/.stub/net/$(net_key "$1")"; }
net_file() { mkdir -p "$VPS_ROOT/.stub/net"; cp "$2" "$VPS_ROOT/.stub/net/$(net_key "$1")"; }
net_redirect() { mkdir -p "$VPS_ROOT/.stub/redirect"; printf '%s' "$2" >"$VPS_ROOT/.stub/redirect/$(net_key "$1")"; }
net_drop() { rm -f "$VPS_ROOT/.stub/net/$(net_key "$1")" "$VPS_ROOT/.stub/redirect/$(net_key "$1")"; }

# 假 Xray 发布：release_xray 版本 [bad-sum]
release_xray() {
  local v=$1 d
  d=$(mktemp -d)
  cat >"$d/xray" <<EOF
#!/usr/bin/env bash
case \$1 in
  version) echo "Xray ${v#v} (Xray, Penetrates Everything.) 0000000 (go1.25 linux/amd64)" ;;
  x25519) echo "PrivateKey: priv\$RANDOM\$RANDOM"; echo "Password (PublicKey): pub\$RANDOM\$RANDOM"; echo "Hash32: h" ;;
  run)
    [[ -f \$VPS_ROOT/.stub/xray-test-fail ]] && { echo "Failed to start: bad config"; exit 1; }
    dir=\${*: -1}
    for f in "\$dir"/*.json; do python3 -m json.tool "\$f" >/dev/null 2>&1 || { echo "invalid json: \$f"; exit 1; }; done
    echo "Configuration OK."
    ;;
  api)
    f=\$VPS_ROOT/.stub/xray-stats.json
    [[ -f \$f ]] && cat "\$f"
    [[ " \$* " == *" -reset "* ]] && rm -f "\$f"
    ;;
esac
exit 0
EOF
  chmod +x "$d/xray"
  python3 -c 'import sys, zipfile
z = zipfile.ZipFile(sys.argv[1], "w"); z.write(sys.argv[2], "xray"); z.close()' "$d/pkg.zip" "$d/xray"
  local base=https://github.com/XTLS/Xray-core/releases/download/$v/Xray-linux-$XRAY_ARCH.zip sum
  sum=$(sha256sum "$d/pkg.zip" | awk '{print $1}')
  [[ ${2:-} == bad-sum ]] && sum=$(printf '0%.0s' {1..64})
  net_file "$base" "$d/pkg.zip"
  net_text "$base.dgst" "MD5= 00
SHA2-256= $sum
"
  net_redirect https://github.com/XTLS/Xray-core/releases/latest "https://github.com/XTLS/Xray-core/releases/tag/$v"
  rm -rf "$d"
}

release_hy2() {
  local v=$1 d base sum
  d=$(mktemp -d)
  printf '#!/usr/bin/env bash\n[[ $1 == version ]] && printf "Hysteria 2\\n\\nVersion:\\t%s\\nBuildDate:\\tx\\n"\nexit 0\n' "$v" >"$d/hy"
  chmod +x "$d/hy"
  base=https://github.com/apernet/hysteria/releases/download/app/$v
  sum=$(sha256sum "$d/hy" | awk '{print $1}')
  net_file "$base/hysteria-linux-$HY2_ARCH" "$d/hy"
  net_text "$base/hashes.txt" "$(printf '%s  build/hysteria-linux-arm\n%s  build/hysteria-linux-%s\n' "$(printf 'a%.0s' {1..64})" "$sum" "$HY2_ARCH")"
  net_redirect https://github.com/apernet/hysteria/releases/latest "https://github.com/apernet/hysteria/releases/tag/app/$v"
  rm -rf "$d"
}

release_geo() {
  local tag=$1 f d
  d=$(mktemp -d)
  for f in geoip.dat geosite.dat; do
    printf '%s-%s' "$f" "$tag" >"$d/$f"
    net_file "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/download/$tag/$f" "$d/$f"
    net_text "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/download/$tag/$f.sha256sum" \
      "$(sha256sum "$d/$f" | awk '{print $1}')  $f"
  done
  net_redirect https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest \
    "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/tag/$tag"
  rm -rf "$d"
}

# ---------- 断言 ----------
pass() { PASS=$((PASS + 1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() {
  FAIL=$((FAIL + 1))
  printf '  \033[31mFAIL\033[0m %s\n' "$1"
  if [[ -n ${2:-} ]]; then printf '%s\n' "$2" | tail -n 15 | sed 's/^/         /'; fi
}

# check 名称 命令...
check() {
  local name=$1
  shift
  if "$@"; then pass "$name"; else fail "$name" "$OUT"; fi
}

has() { [[ $1 == *"$2"* ]]; }
json_ok() { python3 -m json.tool "$1" >/dev/null 2>&1; }
lacks() { [[ $1 != *"$2"* ]]; }
rc_is() { [[ $RC == "$1" ]]; }
file_has() { [[ -f $1 ]] && grep -qF -- "$2" "$1"; }
active() { [[ -f $VPS_ROOT/.stub/systemd/$1.active ]]; }
enabled() { [[ -f $VPS_ROOT/.stub/systemd/$1.enabled ]]; }
called() { grep -qF -- "$1" "$VPS_ROOT/.stub/calls.log" 2>/dev/null; }
state() { grep -E "^$2=" "$1" 2>/dev/null | head -n1 | cut -d= -f2-; }
node_val() { state "$VPS_ROOT/etc/vps/nodes/$1.env" "$2"; }
qdisc() { cat "$VPS_ROOT/.stub/tc/$1" 2>/dev/null || echo default; }

summary() {
  teardown
  printf '\n  %s: %d 通过, %d 失败\n' "${0##*/}" "$PASS" "$FAIL"
  ((FAIL == 0))
}
