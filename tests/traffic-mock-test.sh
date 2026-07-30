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

# shellcheck source=../traffic.sh
# 通过环境驱动 --check，不 interactive

# 准备配置：100GB 额度，90%
mkdir -p "$TMP/etc" "$TMP/var"
cat >"$TMP/etc/config" <<EOF
MONTHLY_QUOTA_GB=100
THRESHOLD_PERCENT=90
LIMIT_RATE=1mbit
TRAFFIC_DIRECTION=tx
IFACE=eth0
PAUSED=false
EOF
cat >"$TMP/var/state" <<EOF
LIMIT_ACTIVE=false
LIMIT_IFACE=
LIMIT_HANDLE=
LAST_REASON=
LAST_CHECK_TS=
LAST_TX_BYTES=
LAST_MONTH=
LAST_RATIO=
OWNED_BY_TOOL=false
EOF

run_check() {
  bash "$TRAFFIC" --check
}

qdisc_file() { cat "$TMP/mock_tc_qdisc" 2>/dev/null || true; }

# 1) 低于 90%：89GB < 90GB thr → 不限速
export MOCK_TX_BYTES=$((89 * 1000000000))
export MOCK_YEAR=$(date +%Y)
export MOCK_MONTH=$(date +%m)
unset MOCK_VNSTAT_FAIL
: >"$TMP/mock_tc_qdisc"
run_check
# shellcheck disable=SC1091
source "$TMP/var/state"
assert "below 90% not limited" '[[ "${LIMIT_ACTIVE}" == "false" && "${OWNED_BY_TOOL}" == "false" ]]'

# 2) 达到 90%：90GB → 限速
export MOCK_TX_BYTES=$((90 * 1000000000))
: >"$TMP/mock_tc_qdisc"
run_check
# shellcheck disable=SC1091
source "$TMP/var/state"
assert "at 90% apply limit" '[[ "${LIMIT_ACTIVE}" == "true" && "${OWNED_BY_TOOL}" == "true" ]]'
assert "qdisc mock set" '[[ "$(qdisc_file)" == *"1abc:"* ]]'

# 3) 重复执行不叠加（已有我们的规则）
run_check
# shellcheck disable=SC1091
source "$TMP/var/state"
assert "repeat keeps limited" '[[ "${LIMIT_ACTIVE}" == "true" ]]'
assert "repeat qdisc still ours" '[[ "$(qdisc_file)" == *"1abc:"* ]]'

# 4) 低于阈值解除
export MOCK_TX_BYTES=$((1 * 1000000000))
run_check
# shellcheck disable=SC1091
source "$TMP/var/state"
assert "below after over removes limit" '[[ "${LIMIT_ACTIVE}" == "false" && "${OWNED_BY_TOOL}" == "false" ]]'
assert "qdisc cleared" '[[ -z "$(qdisc_file | tr -d "[:space:]")" ]]'

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
assert "vnstat fail qdisc still ours" '[[ "$(qdisc_file)" == *"1abc:"* ]]'
unset MOCK_VNSTAT_FAIL

# 6) 外国 qdisc 冲突
export MOCK_TX_BYTES=$((95 * 1000000000))
printf '%s\n' "qdisc htb 1: root refcnt 2" >"$TMP/mock_tc_qdisc"
cat >"$TMP/var/state" <<EOF
LIMIT_ACTIVE=false
LIMIT_IFACE=
LIMIT_HANDLE=
LAST_REASON=
LAST_CHECK_TS=
LAST_TX_BYTES=
LAST_MONTH=
LAST_RATIO=
OWNED_BY_TOOL=false
EOF
run_check
# shellcheck disable=SC1091
source "$TMP/var/state"
assert "foreign qdisc not owned" '[[ "${OWNED_BY_TOOL}" == "false" ]]'
assert "foreign qdisc unchanged" '[[ "$(qdisc_file)" == "qdisc htb 1: root refcnt 2" ]]'

# 7) 无害默认 fq_codel 可被替换为本工具限速
printf '%s\n' "qdisc fq_codel 0: root refcnt 2 limit 10240p" >"$TMP/mock_tc_qdisc"
cat >"$TMP/var/state" <<EOF
LIMIT_ACTIVE=false
LIMIT_IFACE=
LIMIT_HANDLE=
LAST_REASON=
LAST_CHECK_TS=
LAST_TX_BYTES=
LAST_MONTH=
LAST_RATIO=
OWNED_BY_TOOL=false
EOF
export MOCK_TX_BYTES=$((95 * 1000000000))
run_check
# shellcheck disable=SC1091
source "$TMP/var/state"
assert "harmless fq_codel allows limit" '[[ "${OWNED_BY_TOOL}" == "true" ]]'
assert "replaced with our handle" '[[ "$(qdisc_file)" == *"1abc:"* ]]'

echo ""
echo "PASS=$pass FAIL=$fail"
[[ $fail -eq 0 ]]
