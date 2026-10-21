#!/usr/bin/env bash
# 菜单：用标准输入模拟按键
source "$(dirname "$0")/lib.sh"

echo "== 主菜单"
setup
vps_in '0\n'
check "正常退出" rc_is 0
check "标题" has "$OUT" "VPS 管理"
check "节点状态行" has "$OUT" "还没有节点"
check "流量状态行" has "$OUT" "未设置额度"
check "四个入口" bash -c '[[ $0 == *"节点管理"*"流量限额"*"系统设置"*"立即更新"* ]]' "$OUT"
check "主菜单 0 是退出" has "$OUT" " 0  退出"
vps_in ''
check "输入结束时退出" rc_is 0
vps_in '9\nabc\n0\n'
check "无效选项提示" has "$OUT" "无效选项"
check "无效选项后继续" rc_is 0

echo "== 添加节点"
setup
release_xray v25.9.11
vps_in '1\n1\n\n\n\n0\n0\n'
check "菜单添加 REALITY" [ "$(node_val reality SNI)" = www.nvidia.com ]
check "显示分享链接" has "$OUT" "vless://"
check "子菜单 0 是返回" has "$OUT" " 0  返回"
check "添加后菜单显示修改" has "$OUT" "修改 REALITY"
vps_in '1\n1\n\n3\n\n0\n0\n'
check "按序号选 SNI" [ "$(node_val reality SNI)" = www.tesla.com ]
vps_in '1\n1\n\nwww.example.org\n\n0\n0\n'
check "直接输入 SNI" [ "$(node_val reality SNI)" = www.example.org ]
vps_in '1\n2\n\n\n\n\n0\n0\n'
check "菜单添加 WS（不填域名）" [ -n "$(node_val ws PIN)" ]
vps_in '1\n5\n1\n2087\n\n0\n0\n'
check "菜单换端口（多个节点先选节点）" [ "$(node_val reality PORT)" = 2087 ]
old=$(node_val ws UUID)
vps_in '1\n6\n2\ny\n\n0\n0\n'
check "菜单重置" [ "$(node_val ws UUID)" != "$old" ]
vps_in '1\n8\n2\nn\n0\n0\n'
check "删除时回答否则保留" [ -n "$(node_val ws UUID)" ]
vps_in '1\n8\n2\ny\n\n0\n0\n'
check "菜单删除" test ! -e "$VPS_ROOT/etc/vps/nodes/ws.env"
vps_in '1\n7\n2\n\n0\n0\n0\n'
check "菜单停止服务" bash -c '! [ -f "$VPS_ROOT/.stub/systemd/vps-xray.active" ]'
vps_in '1\n7\n3\n\n0\n0\n0\n'
check "菜单启动服务" active vps-xray
touch "$VPS_ROOT/.stub/fail-vps-xray"
vps_in '1\n5\n2096\n\n0\n0\n'
check "操作失败后回到菜单" has "$OUT" "未能生效"
check "失败后菜单仍能退出" rc_is 0

echo "== 流量菜单"
setup
vps_in '2\n1\n200\n80\n2\n3\n10\n\n0\n0\n'
check "设置额度" [ "$(state "$VPS_ROOT/etc/vps/traffic.env" QUOTA_GB)" = 200 ]
check "设置比例" [ "$(state "$VPS_ROOT/etc/vps/traffic.env" PERCENT)" = 80 ]
check "设置速度" [ "$(state "$VPS_ROOT/etc/vps/traffic.env" RATE)" = 2 ]
check "统计方向选双向" [ "$(state "$VPS_ROOT/etc/vps/traffic.env" COUNT)" = both ]
check "重置日" [ "$(state "$VPS_ROOT/etc/vps/traffic.env" RESET_DAY)" = 10 ]
vps_in '2\n2\n190\n\n0\n0\n'
check "校准已用后限速" [ "$(state "$VPS_ROOT/var/lib/vps/traffic.state" LIMITED)" = 1 ]
vps_in '2\n0\n0\n'
check "限速时显示解除选项" has "$OUT" "本期解除限速"
vps_in '2\n4\n\n0\n0\n'
check "菜单解除限速" [ "$(state "$VPS_ROOT/var/lib/vps/traffic.state" LIMITED)" = 0 ]
vps_in '2\n3\n\n0\n0\n'
check "关闭自动限速" [ "$(state "$VPS_ROOT/etc/vps/traffic.env" LIMIT)" = 0 ]
vps_in '2\n4\ny\n\n0\n0\n'
check "删除流量限额" test ! -e "$VPS_ROOT/etc/vps/traffic.env"

echo "== 系统菜单"
setup
vps_in '3\n1\n1\n\n0\n0\n0\n'
check "网络加速一键推荐" file_has "$VPS_ROOT/etc/sysctl.d/99-zz-vps-net.conf" "net.ipv4.tcp_congestion_control = bbr"
check "系统菜单显示网络概览" has "$OUT" "bbr · fq · 已调优"
vps_in '3\n1\n3\n2\n\n0\n0\n0\n'
check "菜单选队列算法" [ "$(state "$VPS_ROOT/etc/vps/settings.env" NET_QDISC)" = fq_codel ]
check "队列选项带说明" has "$OUT" "BBR 推荐搭配"
vps_in '3\n1\n2\n0\n0\n0\n0\n'
check "拥塞算法列表 bbr 在第一个" has "$OUT" " 1  bbr"
vps_in '3\n1\n4\n\n0\n0\n0\n'
check "菜单关闭线路调优" [ "$(state "$VPS_ROOT/etc/vps/settings.env" NET_TUNE)" = 0 ]
vps_in '3\n1\n5\n\n0\n0\n0\n'
check "菜单全部恢复默认" test ! -e "$VPS_ROOT/etc/sysctl.d/99-zz-vps-net.conf"
vps_in '3\n5\n198.51.100.7\n\n0\n0\n'
check "设置分享地址" [ "$(state "$VPS_ROOT/etc/vps/settings.env" HOST)" = 198.51.100.7 ]
check "菜单显示分享地址" has "$OUT" "198.51.100.7"
vps_in '3\n4\n\n0\n0\n'
check "关闭自动更新" [ "$(state "$VPS_ROOT/etc/vps/settings.env" AUTO_UPDATE)" = 0 ]
vps_in '3\n6\ny\n'
check "菜单卸载" test ! -e "$VPS_ROOT/etc/vps"

summary
