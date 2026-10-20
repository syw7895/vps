#!/usr/bin/env bash
# 公共函数：校验、配置读写、格式化
source "$(dirname "$0")/lib.sh"
setup
source "$ROOT/lib/common.sh"
set +e

echo "== 校验"
check "端口 1" is_port 1
check "端口 65535" is_port 65535
for bad in 0 65536 -1 abc 1e3 ''; do check "端口 '$bad' 无效" eval "! is_port '$bad'"; done
check "IPv4" is_ipv4 203.0.113.10
for bad in 256.1.1.1 1.2.3 1.2.3.4.5 a.b.c.d; do check "IPv4 '$bad' 无效" eval "! is_ipv4 '$bad'"; done
check "IPv6" is_ipv6 2001:db8::1
check "域名" is_domain www.example.co.uk
for bad in example -bad.com 'a b.com' 'x;rm.com' example.c; do check "域名 '$bad' 无效" eval "! is_domain '$bad'"; done
check "UUID" is_uuid 3e7270e6-cc4d-4b20-8176-a47333139d62
check "随机 UUID 合法" is_uuid "$(rand_uuid)"
check "邮箱" is_email me@example.com
check "WS 路径" is_ws_path /chat
for bad in chat / '/a b' '/a"b' /a/b; do check "WS 路径 '$bad' 无效" eval "! is_ws_path '$bad'"; done
check "伪装网址" is_url https://www.bing.com/path
for bad in ftp://x.com 'https://x.com/"' javascript:alert; do check "网址 '$bad' 无效" eval "! is_url '$bad'"; done

echo "== 配置读写"
f=$VPS_ROOT/kv.env
declare -A M=([PORT]=443 [MASQ]='https://a.com/x?y=1&z=2' [EMPTY]='')
kv_save "$f" M
check "权限默认 600" [ "$(stat -c %a "$f")" = 600 ]
declare -A R
kv_load "$f" R
check "读回端口" [ "${R[PORT]}" = 443 ]
check "读回带 ? & 的网址" [ "${R[MASQ]}" = 'https://a.com/x?y=1&z=2' ]
check "读回空值" [ "${R[EMPTY]+set}" = set ]
check "kv_get 默认值" [ "$(kv_get "$f" NOPE fallback)" = fallback ]
kv_set "$f" PORT 8443
check "kv_set 改单个值" [ "$(kv_get "$f" PORT)" = 8443 ]
printf 'X=$(touch %s/pwned)\nlower=1\nY=ok\n' "$VPS_ROOT" >"$f"
kv_load "$f" R
check "读取时不执行内容" test ! -e "$VPS_ROOT/pwned"
check "忽略小写键" [ "${R[lower]+set}" != set ]
declare -A B=([X]='a b')
OUT=$( (kv_save "$f" B) 2>&1 )
check "拒绝写入带空格的值" has "$OUT" "非法配置项"
B=([X]='a"b')
OUT=$( (kv_save "$f" B) 2>&1 )
check "拒绝写入带引号的值" has "$OUT" "非法配置项"

echo "== 格式化"
check "字节" [ "$(human 999)" = "999 B" ]
check "GB 十进制" [ "$(human 1500000000)" = "1.50 GB" ]
check "TB" [ "$(human 2000000000000)" = "2.00 TB" ]
check "中文宽度" [ "$(dwidth 本期流量)" = 8 ]
check "混合宽度" [ "$(dwidth 'BBR 加速')" = 8 ]
check "补齐到宽度" [ "$(pad 地址 8)" = "地址    " ]
check "IPv6 链接加括号" [ "$(url_host 2001:db8::1)" = "[2001:db8::1]" ]

summary
