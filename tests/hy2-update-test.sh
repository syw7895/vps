#!/usr/bin/env bash
# Hysteria2 稳定版更新、校验、回滚与定时器回归（全 mock）
set -Eeuo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0
failed=0
assert() {
  local name=$1
  shift
  if eval "$*"; then
    echo "[PASS] $name"
    pass=$((pass + 1))
  else
    echo "[FAIL] $name"
    failed=$((failed + 1))
  fi
}

# shellcheck source=../proxy.sh
source "$ROOT/proxy.sh"

require_root() { :; }
require_systemd() { :; }
ensure_dirs() { mkdir -p "$CONFIG_DIR"; }
sleep() { :; }
flock() { :; }

make_bin() {
  local path=$1 version=$2
  printf '#!/usr/bin/env bash\necho "Version %s"\n' "$version" >"$path"
  chmod 755 "$path"
}

HY2_BIN="$TMP/hysteria"
HY2_UPDATE_LOCK="$TMP/update.lock"
CONFIG_DIR="$TMP/state"
HY2_UPDATE_STATE="$CONFIG_DIR/hy2-update.conf"
mkdir -p "$CONFIG_DIR"

make_bin "$HY2_BIN" v2.10.0
assert "parse installed version" '[[ $(hy2_version_of "$HY2_BIN") == v2.10.0 ]]'
assert "older version compares true" 'hy2_version_lt v2.10.0 v2.12.1'
assert "same version compares false" '! hy2_version_lt v2.12.1 v2.12.1'
assert "newer version compares false" '! hy2_version_lt v2.13.0 v2.12.1'

recorded=""
downloaded=0
hy2_latest_version() { echo v2.12.1; }
hy2_record_update() { recorded="$*"; }
hy2_download_verified() {
  downloaded=$((downloaded + 1))
  make_bin "$3" "$1"
}
systemctl() {
  case ${1:-} in
    is-active) return 0 ;;
    restart) return 0 ;;
    *) return 0 ;;
  esac
}

update_hy2_core manual >/dev/null
assert "update installs latest" '[[ $(hy2_version_of "$HY2_BIN") == v2.12.1 ]]'
assert "update records success" '[[ "$recorded" == "updated v2.10.0 v2.12.1" ]]'

downloaded=0
recorded=""
update_hy2_core --auto >/dev/null
assert "current version skips download" '[[ $downloaded -eq 0 ]]'
assert "current version records check" '[[ "$recorded" == "current v2.12.1 v2.12.1" ]]'

make_bin "$HY2_BIN" v2.10.0
recorded=""
systemctl() {
  case ${1:-} in
    is-active)
      [[ $(hy2_version_of "$HY2_BIN") == v2.10.0 ]]
      ;;
    restart) return 0 ;;
    *) return 0 ;;
  esac
}
set +e
(update_hy2_core manual >/dev/null 2>&1)
rc=$?
set -e
assert "failed health check returns nonzero" '[[ $rc -ne 0 ]]'
assert "failed health check rolls back binary" '[[ $(hy2_version_of "$HY2_BIN") == v2.10.0 ]]'

HY2_UPDATE_SERVICE="$TMP/syw-hy2-update.service"
HY2_UPDATE_TIMER="$TMP/syw-hy2-update.timer"
systemctl() { :; }
enable_hy2_auto_update
assert "timer is weekly and persistent" 'grep -q "OnCalendar=Mon" "$HY2_UPDATE_TIMER" && grep -q "Persistent=true" "$HY2_UPDATE_TIMER"'
assert "service invokes proxy core auto update" 'grep -q "proxy.sh update-cores --auto" "$HY2_UPDATE_SERVICE"'

manual_updated=0
timer_enabled=0
update_hy2_core() { [[ $1 == manual ]] && manual_updated=1; }
enable_hy2_auto_update() { timer_enabled=1; }
update_hy2_manual >/dev/null
assert "manual update enables timer" '[[ $manual_updated -eq 1 && $timer_enabled -eq 1 ]]'

echo ""
echo "PASS=$pass FAIL=$failed"
[[ $failed -eq 0 ]]
