#!/usr/bin/env bash
# 命令行、BBR、自动更新、安装 / 自更新、卸载
source "$(dirname "$0")/lib.sh"

SHA1=1111111111111111111111111111111111111111
SHA2=2222222222222222222222222222222222222222
SHA3=3333333333333333333333333333333333333333
LIB=lib/vps
installed() { "$VPS_ROOT/usr/local/bin/vps" "$@" 2>&1; }

# 打包一份代码当作 GitHub 上的新版本：make_release 提交号 [版本号] [broken]
make_release() {
  local sha=$1 ver=${2:-9.9.9} d
  d=$(mktemp -d)
  mkdir -p "$d/vps-$sha"
  cp -R "$ROOT/vps" "$ROOT/lib" "$d/vps-$sha/"
  sed -i "s/^VPS_VERSION=.*/VPS_VERSION=\"$ver\"/" "$d/vps-$sha/lib/common.sh"
  [[ ${3:-} == broken ]] && echo 'if then' >>"$d/vps-$sha/lib/node.sh"
  tar -czf "$d/src.tgz" -C "$d" "vps-$sha"
  net_file "https://codeload.github.com/syw7895/vps/tar.gz/$sha" "$d/src.tgz"
  net_text "https://api.github.com/repos/syw7895/vps/commits/main" "$sha"
  rm -rf "$d"
}

echo "== 命令行"
setup
vps help
check "帮助" has "$OUT" "vps add reality"
vps version
check "版本号" has "$OUT" "vps 1.0.0"
vps nonsense
check "未知命令" has "$OUT" "未知命令"
vps add
check "缺少节点类型" has "$OUT" "reality / ws / hy2"
vps add reality --bogus
check "未知参数" has "$OUT" "未知参数: --bogus"
vps add reality --port
check "参数缺值" has "$OUT" "--port 需要一个值"
vps port reality 1234
check "节点不存在时提示添加" has "$OUT" "还没有添加"
vps show
check "没有节点时提示" has "$OUT" "还没有节点"
vps del ws
check "删除不存在的节点" has "$OUT" "不存在"

echo "== 安装与自更新"
setup
vps _install "$ROOT" "$SHA1"
check "安装成功" rc_is 0
check "current 指向该版本" [ "$(readlink "$VPS_ROOT/usr/local/$LIB/current")" = "releases/$SHA1" ]
check "vps 命令可用" has "$(installed version)" "vps 1.0.0 (1111111)"
check "默认开启每周自动更新" enabled vps-update.timer
check "自动更新调用 vps update --auto" file_has "$VPS_ROOT/etc/systemd/system/vps-update.service" "ExecStart=/usr/local/bin/vps update --auto"
check "节点参数目录 700" [ "$(stat -c %a "$VPS_ROOT/etc/vps/nodes")" = 700 ]
make_release "$SHA2" 1.1.0
OUT=$(installed update)
check "自更新成功" has "$OUT" "管理脚本已更新：1111111 → 2222222"
check "切换到新版本" has "$(installed version)" "vps 1.1.0 (2222222)"
make_release "$SHA2" 1.1.0
OUT=$(installed update)
check "已是最新" has "$OUT" "管理脚本已是最新（2222222）"
make_release "$SHA3" 1.2.0 broken
OUT=$(installed update)
check "新版本有语法错误时拒绝" has "$OUT" "继续使用当前版本"
check "保持原版本" has "$(installed version)" "vps 1.1.0 (2222222)"
make_release "$SHA3" 1.2.0
installed update >/dev/null
check "只保留当前和上一个版本" [ "$(ls "$VPS_ROOT/usr/local/$LIB/releases" | sort | tr '\n' ' ')" = "$SHA2 $SHA3 " ]
net_drop "https://api.github.com/repos/syw7895/vps/commits/main"
OUT=$(installed update)
check "连不上 GitHub 时报错" has "$OUT" "无法检查管理脚本更新"
vps _install /nonexistent "$SHA1"
check "拒绝不完整的代码" has "$OUT" "代码不完整"
vps _install "$ROOT" not-a-sha
check "拒绝非法提交号" has "$OUT" "提交号无效"

echo "== 自动更新开关"
vps autoupdate off
check "关闭" test ! -e "$VPS_ROOT/etc/systemd/system/vps-update.timer"
vps autoupdate
check "显示已关闭" has "$OUT" "已关闭"
vps autoupdate on
check "开启" enabled vps-update.timer

NETCONF=etc/sysctl.d/99-zz-vps-net.conf
sysv() { cat "$VPS_ROOT/.stub/sysctl/$1" 2>/dev/null; }

echo "== BBR"
setup
vps bbr on
check "开启" has "$OUT" "BBR 已开启"
check "写入 sysctl" file_has "$VPS_ROOT/$NETCONF" "net.ipv4.tcp_congestion_control = bbr"
check "队列 fq" file_has "$VPS_ROOT/$NETCONF" "net.core.default_qdisc = fq"
check "立即生效" [ "$(sysv net.ipv4.tcp_congestion_control)" = bbr ]
vps bbr
check "状态" has "$OUT" "已开启"
vps bbr off
check "关闭" test ! -e "$VPS_ROOT/$NETCONF"
check "恢复原值" [ "$(sysv net.ipv4.tcp_congestion_control)" = cubic ]
check "删掉原值记录" test ! -e "$VPS_ROOT/var/lib/vps/net.orig"
vps bbr
check "关闭后状态" has "$OUT" "未开启"
echo "reno cubic" >"$VPS_ROOT/.stub/cc-available"
vps bbr on
check "内核不支持时提示" has "$OUT" "不支持 BBR"
check "不支持时不写文件" test ! -e "$VPS_ROOT/$NETCONF"

echo "== 网络加速"
setup
vps net
check "查看" rc_is 0
check "显示拥塞算法" has "$OUT" "拥塞算法  cubic"
check "显示来源" has "$OUT" "内核默认"
check "列出可用算法（bbr 在前）" has "$OUT" "可用拥塞算法：bbr cubic reno"
vps net cc hybla
check "不支持的算法" has "$OUT" "不支持 hybla"
vps net cc 'bad;name'
check "非法算法名" rc_is 1
vps net qdisc cake
check "设置队列" [ "$(sysv net.core.default_qdisc)" = cake ]
check "重建网卡队列" called "tc qdisc del dev eth0 root"
echo cake >"$VPS_ROOT/.stub/qdisc-unsupported"
vps net qdisc fq_codel
check "换队列" [ "$(sysv net.core.default_qdisc)" = fq_codel ]
vps net qdisc cake
check "内核不支持的队列" has "$OUT" "不支持 cake"
check "不支持时保持原设置" [ "$(state "$VPS_ROOT/etc/vps/settings.env" NET_QDISC)" = fq_codel ]
vps net tune on
check "开启调优" file_has "$VPS_ROOT/$NETCONF" "net.ipv4.tcp_rmem = 4096 131072 16777216"
check "缓冲区生效" [ "$(sysv net.core.rmem_max)" = 16777216 ]
mkdir -p "$VPS_ROOT/proc"
printf 'MemTotal:        4030000 kB\n' >"$VPS_ROOT/proc/meminfo"
vps net tune on
check "大内存用 32 MB" [ "$(sysv net.core.rmem_max)" = 33554432 ]
vps net tune off
check "关闭调优后恢复" [ "$(sysv net.core.rmem_max)" = 212992 ]
check "关闭调优后保留队列设置" file_has "$VPS_ROOT/$NETCONF" "net.core.default_qdisc = fq_codel"
vps net reset
check "全部恢复" test ! -e "$VPS_ROOT/$NETCONF"
check "队列恢复原值" [ "$(sysv net.core.default_qdisc)" = fq_codel ]
vps net recommend
check "一键推荐" bash -c 'grep -q "= bbr" "$0" && grep -q "default_qdisc = fq$" "$0" && grep -q rmem_max "$0"' "$VPS_ROOT/$NETCONF"
vps net cc default
check "拥塞算法恢复默认" has "$OUT" "恢复系统默认：cubic"

echo "== 网络加速：和系统已有配置共存"
setup
printf 'net.ipv4.tcp_congestion_control = bbr\nnet.core.rmem_max = 16777216\n' >"$VPS_ROOT/.stub/own.conf"
mkdir -p "$VPS_ROOT/etc/sysctl.d"
cp "$VPS_ROOT/.stub/own.conf" "$VPS_ROOT/etc/sysctl.d/99-network-tuning.conf"
sysctl -p "$VPS_ROOT/etc/sysctl.d/99-network-tuning.conf"
vps net
check "显示系统配置来源" has "$OUT" "系统配置 99-network-tuning.conf"
vps net cc cubic
check "本工具的设置优先" [ "$(sysv net.ipv4.tcp_congestion_control)" = cubic ]
vps net
check "显示本工具设置" has "$OUT" "本工具设置"
vps bbr off
check "关掉后回到系统配置的值" [ "$(sysv net.ipv4.tcp_congestion_control)" = bbr ]
check "提示仍由系统配置开着" has "$OUT" "99-network-tuning.conf"

echo "== 网络加速：限速时不动网卡队列"
setup
vps traffic set --quota 1 --used 5
: >"$VPS_ROOT/.stub/calls.log"
vps net qdisc cake
check "限速中不重建队列" bash -c '! grep -q "tc qdisc del" "$0"' "$VPS_ROOT/.stub/calls.log"
check "限速规则还在" bash -c '[[ $(cat "$0") == *5650:* ]]' "$VPS_ROOT/.stub/tc/eth0"

echo "== 旧版 BBR 设置迁移"
setup
mkdir -p "$VPS_ROOT/etc/sysctl.d"
printf '# vps: BBR\nnet.core.default_qdisc = fq\nnet.ipv4.tcp_congestion_control = bbr\n' >"$VPS_ROOT/etc/sysctl.d/90-vps-bbr.conf"
vps _post-install
check "删除旧文件" test ! -e "$VPS_ROOT/etc/sysctl.d/90-vps-bbr.conf"
check "迁移成新设置" file_has "$VPS_ROOT/$NETCONF" "net.ipv4.tcp_congestion_control = bbr"
check "记录在设置里" [ "$(state "$VPS_ROOT/etc/vps/settings.env" NET_CC)" = bbr ]

echo "== 卸载"
setup
release_xray v25.9.11
release_hy2 v2.6.4
vps _install "$ROOT" "$SHA1"
vps add reality
vps add hy2
vps traffic set --quota 1 --used 5
rmem_before=$(sysv net.core.rmem_max)
vps net recommend
vps uninstall --yes
check "卸载成功" rc_is 0
check "删除配置" test ! -e "$VPS_ROOT/etc/vps"
check "删除状态" test ! -e "$VPS_ROOT/var/lib/vps"
check "删除程序" test ! -e "$VPS_ROOT/usr/local/$LIB"
check "删除 vps 命令" test ! -e "$VPS_ROOT/usr/local/bin/vps"
check "删除服务" bash -c 'ls "$VPS_ROOT/etc/systemd/system" | grep -q vps && exit 1 || exit 0'
check "删除系统用户" test ! -e "$VPS_ROOT/.stub/user-vps-proxy"
check "解除限速" [ "$(qdisc eth0)" = default ]
check "删除 sysctl 文件" test ! -e "$VPS_ROOT/$NETCONF"
check "网络设置恢复原值" [ "$(sysv net.ipv4.tcp_congestion_control)" = cubic ]
check "缓冲区恢复原值" [ "$(sysv net.core.rmem_max)" = "$rmem_before" ]
setup
vps_in 'n\n' uninstall
check "确认默认是否" has "$OUT" "已取消"

summary
