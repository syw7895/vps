#!/usr/bin/env bash
# 内核更新与回滚、各节点流量统计
source "$(dirname "$0")/lib.sh"

XBIN() { echo "$VPS_ROOT/usr/local/lib/vps/bin/xray"; }
HBIN() { echo "$VPS_ROOT/usr/local/lib/vps/bin/hysteria"; }
sstate() { state "$VPS_ROOT/var/lib/vps/stats.state" "$1"; }

echo "== 安装校验"
setup
release_xray v25.9.11 bad-sum
vps add reality
check "SHA256 不匹配拒绝安装" has "$OUT" "校验失败"
check "没有留下内核" test ! -e "$(XBIN)"
check "没有留下节点参数" test ! -e "$VPS_ROOT/etc/vps/nodes/reality.env"
net_drop https://github.com/XTLS/Xray-core/releases/latest
vps add reality
check "拿不到版本时提示网络" has "$OUT" "请检查网络"

echo "== Xray 更新"
setup
release_xray v25.9.11
vps add reality
release_xray v25.10.15
vps update --no-self
check "更新成功" has "$OUT" "Xray 已更新：v25.9.11 → v25.10.15"
check "新版本已替换" has "$("$(XBIN)" version)" "25.10.15"
check "更新后服务在运行" active vps-xray
check "没有残留旧文件" test ! -e "$(XBIN).old"
vps update --no-self
check "已是最新时跳过" has "$OUT" "Xray 已是最新（v25.10.15）"

echo "== 更新失败回滚"
release_xray v25.11.1
touch "$VPS_ROOT/.stub/fail-vps-xray"
vps update --no-self
check "新版起不来返回失败" rc_is 1
check "提示已回滚" has "$OUT" "已回滚到 v25.10.15"
check "旧版本已恢复" has "$("$(XBIN)" version)" "25.10.15"
rm -f "$VPS_ROOT/.stub/fail-vps-xray"
touch "$VPS_ROOT/.stub/xray-test-fail"
vps update --no-self
check "新版不接受配置时不替换" has "$OUT" "不接受当前配置"
check "版本不变" has "$("$(XBIN)" version)" "25.10.15"
rm -f "$VPS_ROOT/.stub/xray-test-fail"
release_xray v25.11.2 bad-sum
vps update --no-self
check "校验失败不替换" has "$("$(XBIN)" version)" "25.10.15"

echo "== Hysteria2 更新"
setup
release_hy2 v2.6.4
vps add hy2
release_hy2 v2.7.0
vps update --no-self
check "更新成功" has "$OUT" "Hysteria2 已更新：v2.6.4 → v2.7.0"
check "新版本已替换" has "$("$(HBIN)" version)" "v2.7.0"
check "Xray 没装就不更新" lacks "$OUT" "Xray"

echo "== 屏蔽规则"
setup
release_xray v25.9.11
release_hy2 v2.6.4
release_geo 202610190000
vps add reality
vps add hy2
vps block cn on
check "开启成功" rc_is 0
check "下载规则文件" test -s "$VPS_ROOT/usr/local/lib/vps/share/geoip.dat"
check "Xray 屏蔽回国 IP" file_has "$VPS_ROOT/etc/vps/xray/00-base.json" '"ip": ["geoip:cn"]'
check "Xray 屏蔽回国域名" file_has "$VPS_ROOT/etc/vps/xray/00-base.json" 'geosite:cn'
check "按 IP 匹配需要解析域名" file_has "$VPS_ROOT/etc/vps/xray/00-base.json" '"domainStrategy": "IPIfNonMatch"'
check "Hysteria2 屏蔽回国" file_has "$VPS_ROOT/etc/vps/hy2/config.yaml" "reject(geoip:cn)"
check "Hysteria2 指定规则文件" file_has "$VPS_ROOT/etc/vps/hy2/config.yaml" "geoip: /usr/local/lib/vps/share/geoip.dat"
check "Xray 配置合法" json_ok "$VPS_ROOT/etc/vps/xray/00-base.json"
vps block ads on
check "屏蔽广告" file_has "$VPS_ROOT/etc/vps/xray/00-base.json" "geosite:category-ads-all"
check "两条规则都在" json_ok "$VPS_ROOT/etc/vps/xray/00-base.json"
release_geo 202610200000
vps update --no-self
check "规则文件每周更新" has "$OUT" "屏蔽规则已更新"
check "文件已替换" grep -q 202610200000 "$VPS_ROOT/usr/local/lib/vps/share/geosite.dat"
vps update --no-self
check "没变化时不重启" has "$OUT" "屏蔽规则已是最新"
vps block cn off
vps block ads off
check "全部关闭后删掉规则文件" test ! -e "$VPS_ROOT/usr/local/lib/vps/share/geoip.dat"
check "Xray 规则已清空" bash -c '! grep -q geosite "$VPS_ROOT/etc/vps/xray/00-base.json"'
check "Hysteria2 规则已清空" bash -c '! grep -q geoip "$VPS_ROOT/etc/vps/hy2/config.yaml"'
net_drop https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest
vps block cn on
check "下载失败时不开启" bash -c '[ "$(grep ^BLOCK_CN= "$VPS_ROOT/etc/vps/settings.env" | cut -d= -f2)" = 0 ]'
vps block xx on
check "拒绝未知规则" rc_is 1

echo "== 各节点流量统计"
setup
release_xray v25.9.11
release_hy2 v2.6.4
vps add reality
vps add ws
vps add hy2
cat >"$VPS_ROOT/.stub/xray-stats.json" <<'EOF'
{
    "stat": [
        {
            "name": "inbound>>>reality>>>traffic>>>uplink",
            "value": 1000
        },
        {
            "name": "inbound>>>reality>>>traffic>>>downlink",
            "value": "5000"
        },
        {
            "name": "inbound>>>ws>>>traffic>>>uplink"
        },
        {
            "name": "inbound>>>ws>>>traffic>>>downlink",
            "value": 700
        },
        {
            "name": "inbound>>>api>>>traffic>>>downlink",
            "value": 99
        }
    ]
}
EOF
net_text "http://127.0.0.1:$(node_val hy2 STATS_PORT)/traffic?clear=1" '{"user":{"tx":300,"rx":4000}}'
vps _tick
check "REALITY 上传" [ "$(sstate REALITY_UP)" = 1000 ]
check "REALITY 下载（值是字符串也能读）" [ "$(sstate REALITY_DOWN)" = 5000 ]
check "缺省值当 0" [ "$(sstate WS_UP)" = 0 ]
check "WS 下载" [ "$(sstate WS_DOWN)" = 700 ]
check "忽略内部 api 统计" bash -c '! grep -q API "$VPS_ROOT/var/lib/vps/stats.state"'
check "Hysteria2 上传" [ "$(sstate HY2_UP)" = 300 ]
check "Hysteria2 下载" [ "$(sstate HY2_DOWN)" = 4000 ]
check "读取时清零计数器" test ! -e "$VPS_ROOT/.stub/xray-stats.json"
echo '{"stat":[{"name":"inbound>>>reality>>>traffic>>>downlink","value":5}]}' >"$VPS_ROOT/.stub/xray-stats.json"
vps _tick
check "继续累加" [ "$(sstate REALITY_DOWN)" = 5005 ]
vps status
check "概览显示节点流量" has "$OUT" "↓ 5.00 KB"
vps show reality
check "节点页显示本期流量" has "$OUT" "↑ 1.00 KB  ↓ 5.00 KB"
VPS_NOW=$(date -u -d 2026-11-02 +%s) vps _tick
check "新周期清零" [ -z "$(sstate REALITY_DOWN)" ]
check "记录新周期" [ "$(sstate PERIOD)" = 2026-11-01 ]
vps del ws
check "删除节点后清掉它的统计" bash -c '! grep -q ^WS_ "$VPS_ROOT/var/lib/vps/stats.state"'

summary
