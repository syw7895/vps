#!/usr/bin/env bash
# 模拟测试：不触碰真实网络 / 真实 tc
set -Eeuo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TRAFFIC="$ROOT/traffic.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

export VPS_TRAFFIC_MOCK=1
export VPS_TRAFFIC_TEST_DIR="$TMP"
export MOCK_IFACE=eth0

pass=0
fail=0
assert() {
  local name=$1
  shift
  if eval "$*"; then
    echo "[PASS] $name"
    pass=$((pass + 1))
  else
    echo "[FAIL] $name"
    fail=$((fail + 1))
  fi
}

qdisc_file() {
  local iface=${1:-eth0}
  cat "$TMP/mock_tc/$iface" 2>/dev/null || true
}

reset_state() {
  cat >"$TMP/var/state" <<EOF
LIMIT_ACTIVE=${1:-false}
LIMIT_IFACE=${2:-}
LIMIT_HANDLE=${3:-}
LAST_REASON=
LAST_CHECK_TS=
LAST_TX_BYTES=
LAST_MONTH=
LAST_RATIO=
OWNED_BY_TOOL=${4:-false}
EOF
}

# shellcheck source=../traffic.sh
# 通过环境驱动 --check，不 interactive

# 准备配置：100GB 额度，90%
mkdir -p "$TMP/etc" "$TMP/var" "$TMP/mock_tc"
cat >"$TMP/etc/config" <<EOF
MONTHLY_QUOTA_GB=100
THRESHOLD_PERCENT=90
LIMIT_RATE=1mbit
IFACE=eth0
PAUSED=false
EOF
reset_state false "" "" false

run_check() {
  bash "$TRAFFIC" --check
}

# 1) 低于 90%：89GB < 90GB thr → 不限速
export MOCK_TX_BYTES=$((89 * 1000000000))
export MOCK_YEAR=$(date +%Y)
export MOCK_MONTH=$(date +%m)
unset MOCK_VNSTAT_FAIL
: >"$TMP/mock_tc/eth0"
run_check
# shellcheck disable=SC1091
source "$TMP/var/state"
assert "below 90% not limited" '[[ "${LIMIT_ACTIVE}" == "false" && "${OWNED_BY_TOOL}" == "false" ]]'

# 2) 达到 90%：90GB → 限速
export MOCK_TX_BYTES=$((90 * 1000000000))
: >"$TMP/mock_tc/eth0"
run_check
# shellcheck disable=SC1091
source "$TMP/var/state"
assert "at 90% apply limit" '[[ "${LIMIT_ACTIVE}" == "true" && "${OWNED_BY_TOOL}" == "true" ]]'
assert "qdisc mock set" '[[ "$(qdisc_file eth0)" == *"1abc:"* ]]'
assert "LIMIT_IFACE recorded" '[[ "${LIMIT_IFACE}" == "eth0" ]]'

# 3) 重复执行不叠加（已有我们的规则）
run_check
# shellcheck disable=SC1091
source "$TMP/var/state"
assert "repeat keeps limited" '[[ "${LIMIT_ACTIVE}" == "true" ]]'
assert "repeat qdisc still ours" '[[ "$(qdisc_file eth0)" == *"1abc:"* ]]'

# 4) 低于阈值解除
export MOCK_TX_BYTES=$((1 * 1000000000))
run_check
# shellcheck disable=SC1091
source "$TMP/var/state"
assert "below after over removes limit" '[[ "${LIMIT_ACTIVE}" == "false" && "${OWNED_BY_TOOL}" == "false" ]]'
assert "qdisc cleared" '[[ -z "$(qdisc_file eth0 | tr -d "[:space:]")" ]]'

# 5) 无数据不改 tc
export MOCK_TX_BYTES=$((95 * 1000000000))
run_check
# shellcheck disable=SC1091
source "$TMP/var/state"
assert "re-apply over threshold" '[[ "${LIMIT_ACTIVE}" == "true" ]]'
before_active=$LIMIT_ACTIVE
export MOCK_VNSTAT_FAIL=1
run_check
# shellcheck disable=SC1091
source "$TMP/var/state"
assert "vnstat fail keeps limit state" '[[ "${LIMIT_ACTIVE}" == "'"$before_active"'" ]]'
assert "vnstat fail reason recorded" '[[ "${LAST_REASON}" == "vnstat_unavailable_or_bad_month" ]]'
assert "vnstat fail qdisc still ours" '[[ "$(qdisc_file eth0)" == *"1abc:"* ]]'
unset MOCK_VNSTAT_FAIL

# 6) 外国 qdisc 冲突
export MOCK_TX_BYTES=$((95 * 1000000000))
printf '%s\n' "qdisc htb 1: root refcnt 2" >"$TMP/mock_tc/eth0"
reset_state false "" "" false
run_check
# shellcheck disable=SC1091
source "$TMP/var/state"
assert "foreign qdisc not owned" '[[ "${OWNED_BY_TOOL}" == "false" ]]'
assert "foreign qdisc unchanged" '[[ "$(qdisc_file eth0)" == "qdisc htb 1: root refcnt 2" ]]'

# 7) 无害默认 fq_codel 可被替换为本工具限速
printf '%s\n' "qdisc fq_codel 0: root refcnt 2 limit 10240p" >"$TMP/mock_tc/eth0"
reset_state false "" "" false
export MOCK_TX_BYTES=$((95 * 1000000000))
run_check
# shellcheck disable=SC1091
source "$TMP/var/state"
assert "harmless fq_codel allows limit" '[[ "${OWNED_BY_TOOL}" == "true" ]]'
assert "replaced with our handle" '[[ "$(qdisc_file eth0)" == *"1abc:"* ]]'
assert "orig qdisc saved" '[[ "${ORIG_QDISC_KIND}" == "fq_codel" ]]'

# 7b) 次月：vnStat 本月 TX 回落（新月从低用量开始），解除限速并恢复原队列
export MOCK_TX_BYTES=$((1 * 1000000000))
run_check
# shellcheck disable=SC1091
source "$TMP/var/state"
assert "next month lifts limit" '[[ "${LIMIT_ACTIVE}" == "false" && "${OWNED_BY_TOOL}" == "false" ]]'
assert "next month restores fq_codel" '[[ "$(qdisc_file eth0)" == *"qdisc fq_codel"* ]]'
assert "next month not empty default" '[[ "$(qdisc_file eth0)" != *"1abc:"* ]]'
assert "next month keeps orig kind" '[[ "${ORIG_QDISC_KIND}" == "fq_codel" ]]'

# 8) 网卡变更 + 低于阈值：清理旧网卡规则，不在新网卡限速
cat >"$TMP/etc/config" <<EOF
MONTHLY_QUOTA_GB=100
THRESHOLD_PERCENT=90
LIMIT_RATE=1mbit
IFACE=auto
PAUSED=false
EOF
printf 'qdisc tbf 1abc: root refcnt 2 rate 1mbit\n' >"$TMP/mock_tc/eth0"
: >"$TMP/mock_tc/eth1"
reset_state true eth0 "1abc:" true
export MOCK_IFACE=eth1
export MOCK_TX_BYTES=$((1 * 1000000000))
run_check
# shellcheck disable=SC1091
source "$TMP/var/state"
assert "nic switch below: old eth0 cleared" '[[ -z "$(qdisc_file eth0 | tr -d "[:space:]")" ]]'
assert "nic switch below: eth1 not limited" '[[ -z "$(qdisc_file eth1 | tr -d "[:space:]")" ]]'
assert "nic switch below: state inactive" '[[ "${LIMIT_ACTIVE}" == "false" && "${OWNED_BY_TOOL}" == "false" ]]'
assert "nic switch below: LIMIT_IFACE empty" '[[ -z "${LIMIT_IFACE}" ]]'

# 9) 网卡变更 + 仍超额：清理旧网卡，仅在新网卡限速
printf 'qdisc tbf 1abc: root refcnt 2 rate 1mbit\n' >"$TMP/mock_tc/eth0"
: >"$TMP/mock_tc/eth1"
reset_state true eth0 "1abc:" true
export MOCK_IFACE=eth1
export MOCK_TX_BYTES=$((95 * 1000000000))
run_check
# shellcheck disable=SC1091
source "$TMP/var/state"
assert "nic switch over: old eth0 cleared" '[[ -z "$(qdisc_file eth0 | tr -d "[:space:]")" ]]'
assert "nic switch over: eth1 limited" '[[ "$(qdisc_file eth1)" == *"1abc:"* ]]'
assert "nic switch over: LIMIT_IFACE=eth1" '[[ "${LIMIT_IFACE}" == "eth1" && "${LIMIT_ACTIVE}" == "true" ]]'

echo ""
echo "PASS=$pass FAIL=$fail"
[[ $fail -eq 0 ]]
