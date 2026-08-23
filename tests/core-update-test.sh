#!/usr/bin/env bash
# Xray 核心更新逻辑测试：不触碰真实二进制、网络或 systemd。
set -Eeuo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

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

# shellcheck source=../proxy.sh
source "$ROOT/proxy.sh"

require_root() { :; }
require_systemd() { :; }
ensure_dirs() { mkdir -p "$CONFIG_DIR"; }
sleep() { :; }
flock() { :; }

XRAY_CORE_BIN="$TMP/xray"
CONFIG_DIR="$TMP/config"
XRAY_UPDATE_STATE="$CONFIG_DIR/xray-update.conf"
XRAY_UPDATE_LOCK="$TMP/xray-update.lock"
mkdir -p "$CONFIG_DIR"

make_bin() {
  local path=$1 version=$2
  cat >"$path" <<'EOF'
#!/usr/bin/env bash
if [[ ${1:-} == version ]]; then
  printf 'Xray __VERSION__\n'
else
  exit 0
fi
EOF
  sed -i "s/__VERSION__/${version}/" "$path"
  chmod 755 "$path"
}

make_bin "$XRAY_CORE_BIN" 26.3.27
assert "parse xray version" '[[ $(xray_version_of "$XRAY_CORE_BIN") == 26.3.27 ]]'
assert "x86/arm asset mapping is nonempty" '[[ -n $(xray_release_asset) ]]'

# Stub only the external operations used by update_xray_core.
xray_binary_path() { printf '%s\n' "$XRAY_CORE_BIN"; }
xray_latest_version() { printf 'v26.4.0\n'; }
xray_download_verified() {
  make_bin "$2" 26.4.0
}
xray_validate_candidate() {
  "$1" version >/dev/null
}
MOCK_ACTIVE=0
MOCK_ACTIVE_CALLS=0
systemctl() {
  case ${1:-} in
    is-active)
      if ((MOCK_ACTIVE)); then
        MOCK_ACTIVE_CALLS=$((MOCK_ACTIVE_CALLS + 1))
        ((MOCK_ACTIVE_CALLS == 1))
      else
        return 1
      fi
      ;;
    restart|enable|daemon-reload) return 0 ;;
    *) return 0 ;;
  esac
}

update_xray_core manual >/dev/null
assert "inactive service update installs candidate" '[[ $(xray_version_of "$XRAY_CORE_BIN") == 26.4.0 ]]'
assert "inactive update records success" 'grep -q "RESULT=updated" "$XRAY_UPDATE_STATE"'

make_bin "$XRAY_CORE_BIN" 26.3.27
MOCK_ACTIVE=1
MOCK_ACTIVE_CALLS=0
set +e
(update_xray_core manual >/dev/null 2>&1)
rc=$?
set -e
assert "failed health check returns nonzero" '[[ $rc -ne 0 ]]'
assert "failed health check restores old binary" '[[ $(xray_version_of "$XRAY_CORE_BIN") == 26.3.27 ]]'
assert "rollback state recorded" 'grep -q "RESULT=rolled-back" "$XRAY_UPDATE_STATE"'

timer_enabled=0
update_xray_core() { :; }
enable_proxy_auto_update() { timer_enabled=1; }
update_proxy_cores manual >/dev/null
assert "manual proxy update enables timer" '[[ $timer_enabled -eq 1 ]]'

echo ""
echo "PASS=$pass FAIL=$fail"
[[ $fail -eq 0 ]]
