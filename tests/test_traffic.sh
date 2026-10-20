#!/usr/bin/env bash
# 流量：周期计算、用量累加、重启 / 换网卡、限速与解除、冲突、校准
source "$(dirname "$0")/lib.sh"

G=1000000000
tstate() { state "$VPS_ROOT/var/lib/vps/traffic.state" "$1"; }
at() { VPS_NOW=$(date -u -d "$1" +%s); export VPS_NOW; }

echo "== 周期计算"
setup
p() { (
  source "$ROOT/lib/common.sh"
  source "$ROOT/lib/traffic.sh"
  period_start "$(date -u -d "$1" +%s)" "$2"
); }
check "1 号重置" [ "$(p 2026-10-20 1)" = 2026-10-01 ]
check "重置日还没到算上个月" [ "$(p 2026-10-20 25)" = 2026-09-25 ]
check "当天就是重置日" [ "$(p 2026-10-20 20)" = 2026-10-20 ]
check "跨年" [ "$(p 2026-01-10 15)" = 2025-12-15 ]
check "下个周期" [ "$( (source "$ROOT/lib/common.sh"; source "$ROOT/lib/traffic.sh"; period_next 2026-01-28) )" = 2026-02-28 ]

echo "== 设置与统计"
setup
nic eth0 1000 2000
vps traffic set --quota 100
check "设置成功" rc_is 0
check "默认 90% 触发" [ "$(state "$VPS_ROOT/etc/vps/traffic.env" PERCENT)" = 90 ]
check "默认限速 1 Mbit/s" [ "$(state "$VPS_ROOT/etc/vps/traffic.env" RATE)" = 1 ]
check "启用定时统计" enabled vps-tick.timer
check "设置之前的流量不算" [ "$(tstate USED_TX)" = 0 ]
nic eth0 $((50 * G + 1000)) $((3 * G + 2000))
vps _tick
check "累加出站" [ "$(tstate USED_TX)" = $((50 * G)) ]
check "累加入站" [ "$(tstate USED_RX)" = $((3 * G)) ]
vps traffic
check "状态页显示用量" has "$OUT" "50.00 GB / 100 GB（出站）"
check "状态页显示周期" has "$OUT" "2026-10-01 → 2026-11-01"
check "状态正常" has "$OUT" "● 正常"
echo boot-2 >"$VPS_ROOT/proc/sys/kernel/random/boot_id"
nic eth0 $((2 * G)) 0
vps _tick
check "重启后计数器归零也能接着累加" [ "$(tstate USED_TX)" = $((52 * G)) ]

echo "== 超额限速与解除"
nic eth0 $((40 * G)) 0
vps _tick
check "超过 90% 限速" [ "$(tstate LIMITED)" = 1 ]
check "网卡上挂了限速队列" has "$(qdisc eth0)" "tbf 5650: root"
check "限速 1000kbit" has "$(qdisc eth0)" "rate 1000kbit"
check "记住原队列" [ "$(tstate ORIG_QDISC)" = fq_codel ]
vps traffic
check "状态页显示已限速" has "$OUT" "已限速到 1 Mbit/s"
vps _tick
check "重复检查保持限速" [ "$(tstate LIMITED)" = 1 ]
vps traffic set --rate 5
check "改限速速度立即生效" has "$(qdisc eth0)" "rate 5000kbit"
vps traffic set --percent 100
check "调高比例后解除" [ "$(tstate LIMITED)" = 0 ]
check "队列恢复默认" [ "$(qdisc eth0)" = default ]
vps traffic set --percent 90
vps traffic unlimit
check "手动解除" [ "$(tstate LIMITED)" = 0 ]
vps _tick
check "本周期不再限速" [ "$(tstate LIMITED)" = 0 ]
at 2026-11-01T00:10:00
vps _tick
check "新周期用量清零" [ "$(tstate USED_TX)" = 0 ]
check "新周期恢复自动限速" [ -z "$(tstate SKIP)" ]
nic eth0 $((136 * G)) 0
vps _tick
check "新周期超额再次限速" [ "$(tstate LIMITED)" = 1 ]
at 2026-12-01T00:10:00
vps _tick
check "下个周期自动解除" [ "$(tstate LIMITED)" = 0 ]

echo "== 恢复原队列 fq"
setup
mkdir -p "$VPS_ROOT/.stub/tc"
echo "qdisc fq 8001: root refcnt 2 limit 10000p" >"$VPS_ROOT/.stub/tc/eth0"
vps traffic set --quota 10 --used 20
check "--used 校准后立即限速" [ "$(tstate LIMITED)" = 1 ]
check "原队列是 fq" [ "$(tstate ORIG_QDISC)" = fq ]
vps traffic limit off
check "关闭自动限速后解除" [ "$(tstate LIMITED)" = 0 ]
check "恢复成 fq" has "$(qdisc eth0)" "qdisc fq "
vps traffic
check "状态显示只统计" has "$OUT" "自动限速已关闭"
vps traffic limit on
check "重新开启后限速" [ "$(tstate LIMITED)" = 1 ]

echo "== 不覆盖别人的限速"
setup
mkdir -p "$VPS_ROOT/.stub/tc"
echo "qdisc htb 1: root refcnt 2 r2q 10 default 0x10" >"$VPS_ROOT/.stub/tc/eth0"
vps traffic set --quota 10 --used 20
check "检测到冲突不限速" [ "$(tstate LIMITED)" = 0 ]
check "原规则保留" has "$(qdisc eth0)" "htb 1:"
vps traffic
check "状态页提示冲突" has "$OUT" "已有别的限速规则"

echo "== tc 失败"
setup
mkdir -p "$VPS_ROOT/.stub/tc"
touch "$VPS_ROOT/.stub/tc/fail"
vps traffic set --quota 10 --used 20
check "记录失败" [ "$(tstate NOTE)" = tc_failed ]
vps traffic
check "状态页提示失败" has "$OUT" "设置限速失败"

echo "== 换网卡"
setup
nic eth1 5000 0
vps traffic set --quota 10 --used 20
check "eth0 限速" [ "$(tstate LIMIT_IF)" = eth0 ]
echo eth1 >"$VPS_ROOT/.stub/iface"
vps _tick
check "旧网卡解除" [ "$(qdisc eth0)" = default ]
check "新网卡限速" has "$(qdisc eth1)" "tbf 5650:"
check "记录新网卡" [ "$(tstate LIMIT_IF)" = eth1 ]
check "换网卡不重复计数" [ "$(tstate USED_TX)" = $((20 * G)) ]
touch "$VPS_ROOT/.stub/no-route"
vps _tick
check "找不到网卡时记录" [ "$(tstate NOTE)" = no_iface ]
vps traffic set --iface eth1
check "手动指定网卡" [ "$(tstate NOTE)" = limited ]
vps traffic set --iface wlan9
check "拒绝不存在的网卡" has "$OUT" "网卡不存在"

echo "== 统计方向与重置日"
setup
vps traffic set --quota 100 --count both --reset-day 15
nic eth0 $((30 * G)) $((40 * G))
vps _tick
vps traffic
check "双向相加" has "$OUT" "70.00 GB / 100 GB（双向）"
check "15 号重置" has "$OUT" "2026-10-15 → 2026-11-15"
vps traffic set --count rx
vps traffic
check "只算入站" has "$OUT" "40.00 GB / 100 GB（入站）"

echo "== 参数校验"
setup
vps traffic set --percent 80
check "必须先有额度" has "$OUT" "每月额度"
vps traffic set --quota 0
check "额度要大于 0" rc_is 1
vps traffic set --quota 100 --percent 101
check "比例 1-100" rc_is 1
vps traffic set --quota 100 --reset-day 31
check "重置日 1-28" rc_is 1
vps traffic set --quota 100 --rate abc
check "限速要是数字" rc_is 1
vps traffic set --quota 100 --count up
check "统计方向只能三选一" rc_is 1
vps traffic set --quota 1.5GB --rate 0.5Mbit
check "接受带单位的写法" [ "$(state "$VPS_ROOT/etc/vps/traffic.env" QUOTA_GB)/$(state "$VPS_ROOT/etc/vps/traffic.env" RATE)" = 1.5/0.5 ]

echo "== 删除"
vps traffic set --used 5
check "删除前已限速" [ "$(tstate LIMITED)" = 1 ]
vps traffic remove
check "删除后解除限速" [ "$(qdisc eth0)" = default ]
check "配置已删" test ! -e "$VPS_ROOT/etc/vps/traffic.env"
check "没有节点时停掉定时任务" test ! -e "$VPS_ROOT/etc/systemd/system/vps-tick.timer"
vps traffic
check "删除后提示怎么设置" has "$OUT" "还没有设置"

summary
