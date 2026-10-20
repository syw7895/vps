#!/usr/bin/env bash
# 一键安装：curl -fsSL https://raw.githubusercontent.com/syw7895/vps/main/install.sh | sudo bash
set -Eeuo pipefail

REPO=${VPS_REPO:-syw7895/vps}
BRANCH=${VPS_BRANCH:-main}

die() { printf '  ✗ %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "请用 root 运行：curl -fsSL ... | sudo bash"
command -v systemctl >/dev/null 2>&1 || die "需要 systemd"
if [[ -r /etc/os-release ]]; then
  # shellcheck source=/dev/null
  . /etc/os-release
fi
[[ ${ID:-} == debian || ${ID:-} == ubuntu || ${ID_LIKE:-} == *debian* ]] || die "只支持 Debian / Ubuntu"

missing=()
for cmd in curl tar openssl ss flock; do
  command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
done
if ((${#missing[@]})); then
  echo "  安装依赖：${missing[*]} ..."
  apt-get update -qq >/dev/null 2>&1 || true
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl ca-certificates tar openssl iproute2 util-linux \
    >/dev/null 2>&1 || die "安装依赖失败"
fi

sha=$(curl -fsSL --proto '=https' --max-time 30 -H 'Accept: application/vnd.github.sha' \
  "https://api.github.com/repos/$REPO/commits/$BRANCH") || die "无法连接 GitHub"
[[ $sha =~ ^[0-9a-f]{40}$ ]] || die "获取版本失败"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
curl -fsSL --proto '=https' --max-time 120 "https://codeload.github.com/$REPO/tar.gz/$sha" |
  tar -xz -C "$tmp" --strip-components=1 || die "下载失败"

VPS_BRANCH=$BRANCH bash "$tmp/vps" _install "$tmp" "$sha"
echo
echo "  ✓ 安装完成（${sha:0:7}）。以后输入 vps 打开菜单"

if { : </dev/tty; } 2>/dev/null; then
  exec /usr/local/bin/vps </dev/tty
fi
