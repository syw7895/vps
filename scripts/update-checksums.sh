#!/usr/bin/env bash
# 计算 proxy/traffic/vps 的 SHA-256，写入 checksums.sha256，并回写 vps.sh 内置期望哈希。
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# 将 VAR="${ENV:-old}" 中的 old 替换为 new（只改第一处）
patch_default_hash() {
  local file=$1 var=$2 new=$3
  local tmp line done=0
  tmp=$(mktemp)
  while IFS= read -r line || [[ -n $line ]]; do
    if ((done == 0)) && [[ $line =~ ^(${var}=\"\$\{[^:]+:-)([^}]*)(\}\")$ ]]; then
      printf '%s%s%s\n' "${BASH_REMATCH[1]}" "$new" "${BASH_REMATCH[3]}"
      done=1
      continue
    fi
    printf '%s\n' "$line"
  done <"$file" >"$tmp"
  if ((done == 0)); then
    rm -f "$tmp"
    echo "failed to patch $var in $file" >&2
    exit 1
  fi
  cat "$tmp" >"$file"
  rm -f "$tmp"
  echo "patched $var -> ${new:0:12}…"
}

ph=$(sha256_file proxy.sh)
th=$(sha256_file traffic.sh)
vh=$(sha256_file vps.sh)

{
  printf '%s  %s\n' "$ph" proxy.sh
  printf '%s  %s\n' "$th" traffic.sh
  printf '%s  %s\n' "$vh" vps.sh
} >checksums.sha256

patch_default_hash vps.sh PROXY_SHA256 "$ph"
patch_default_hash vps.sh TRAFFIC_SHA256 "$th"

# vps.sh 因写入哈希而变化；checksums 中的 vps 行仅供参考
vh=$(sha256_file vps.sh)
{
  printf '%s  %s\n' "$ph" proxy.sh
  printf '%s  %s\n' "$th" traffic.sh
  printf '%s  %s\n' "$vh" vps.sh
} >checksums.sha256

echo "checksums.sha256:"
cat checksums.sha256
