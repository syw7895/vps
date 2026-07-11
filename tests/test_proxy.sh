#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT_DIR}/proxy.sh"

fail_test() {
  printf 'TEST FAILED: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local text="$1" expected="$2"
  [[ "$text" == *"$expected"* ]] || fail_test "expected output to contain: ${expected}"
}

assert_equals() {
  local actual="$1" expected="$2"
  [[ "$actual" == "$expected" ]] || fail_test "unexpected output: ${actual}"
}

assert_matches() {
  local actual="$1" pattern="$2"
  [[ "$actual" =~ $pattern ]] || fail_test "output did not match ${pattern}: ${actual}"
}

expect_function_failure() {
  local expected="$1"
  shift

  local output status
  set +e
  output="$(bash -c 'source "$1"; shift; "$@"' bash "$SCRIPT" "$@" 2>&1)"
  status=$?
  set -e

  (( status != 0 )) || fail_test "expected command to fail: $*"
  assert_contains "$output" "$expected"
}

test_argument_errors() {
  expect_function_failure '--port 后面需要填写参数值。' parse_xray_args --port
  expect_function_failure '--domain 后面需要填写参数值。' parse_hy2_args --domain
  expect_function_failure '端口必须在 1-65535' validate_target www.cloudflare.com:70000
}

test_port_reinstall_guard() {
  local output status

  output="$(bash -c '
    source "$1"
    is_port_in_use() { return 0; }
    service_owns_port() { return 0; }
    ensure_port_available 443 xray Xray
  ' bash "$SCRIPT")"
  assert_contains "$output" "允许原端口更新"

  set +e
  output="$(bash -c '
    source "$1"
    is_port_in_use() { return 0; }
    service_owns_port() { return 1; }
    ensure_port_available 443 xray Xray
  ' bash "$SCRIPT" 2>&1)"
  status=$?
  set -e
  (( status != 0 )) || fail_test "expected occupied third-party port to fail"
  assert_contains "$output" "端口已被其他程序占用：443"
}

test_download_helpers() {
  local temp_file actual_sha
  temp_file="$(mktemp)"
  printf 'fixture' >"$temp_file"
  actual_sha="$(sha256sum "$temp_file" | awk '{print $1}')"

  sha256_matches "$temp_file" "" || fail_test "empty hash should allow the file"
  sha256_matches "$temp_file" "$actual_sha" || fail_test "matching hash was rejected"
  if sha256_matches "$temp_file" "0000000000000000000000000000000000000000000000000000000000000000"; then
    fail_test "mismatched hash was accepted"
  fi
  rm -f "$temp_file"
}

test_v2_download_failure_is_soft() {
  local temp_dir output
  temp_dir="$(mktemp -d)"
  output="$(bash -c '
    source "$1"
    V2_INSTALL_DIR="$2/v2"
    V2_SCRIPT_PATH="$V2_INSTALL_DIR/proxy.sh"
    V2_COMMAND_PATH="$2/v2-command"
    curl_download() { return 1; }
    if download_v2_local_copy; then
      exit 1
    fi
    [[ ! -e "$V2_SCRIPT_PATH" ]]
  ' bash "$SCRIPT" "$temp_dir")"
  assert_equals "$output" ""

  rmdir "$temp_dir"
}

test_firewall_and_status_helpers() {
  local output temp_file
  temp_file="$(mktemp)"

  bash -c '
    source "$1"
    ufw() { printf "%s\n" "$*" >"$2"; }
    open_firewall_port 443 tcp
  ' bash "$SCRIPT" "$temp_file"
  output="$(<"$temp_file")"
  assert_equals "$output" "allow 443/tcp"
  rm -f "$temp_file"

  output="$(bash -c '
    source "$1"
    service_status_label() { printf "%s" "$1"; }
    print_service_statuses
  ' bash "$SCRIPT")"
  assert_contains "$output" "Xray      : xray"
  assert_contains "$output" "Hysteria2 : hysteria-server"
}

test_certificate_fingerprint() {
  local temp_dir fingerprint
  temp_dir="$(mktemp -d)"
  openssl req -x509 -newkey rsa:2048 -sha256 -nodes \
    -keyout "${temp_dir}/key.pem" -out "${temp_dir}/cert.pem" \
    -days 1 -subj "/CN=test.example.com" >/dev/null 2>&1

  fingerprint="$(bash -c 'source "$1"; hy2_certificate_sha256 "$2"' \
    bash "$SCRIPT" "${temp_dir}/cert.pem")"
  assert_matches "$fingerprint" '^[0-9a-f]{64}$'

  rm -f "${temp_dir}/key.pem" "${temp_dir}/cert.pem"
  rmdir "$temp_dir"
}

test_hy2_link_pinning() {
  local source_text
  source_text="$(<"$SCRIPT")"
  assert_contains "$source_text" "pinSHA256=\${cert_sha256}"
}

test_command_routing() {
  local output expected

  output="$(bash -c '
    source "$1"
    uninstall_hy2() { printf "hy2\n"; }
    uninstall_v2_shortcut() { printf "v2\n"; }
    main uninstall-v2
  ' bash "$SCRIPT")"
  assert_equals "$output" "v2"

  output="$(bash -c '
    source "$1"
    install_xray_reality() { printf "xray\n"; }
    ensure_v2_shortcut_auto() { printf "shortcut\n"; }
    main xray
  ' bash "$SCRIPT")"
  expected="$(printf 'xray\nshortcut')"
  assert_equals "$output" "$expected"

  output="$(bash -c '
    source "$1"
    install_hysteria2() { printf "hy2\n"; }
    ensure_v2_shortcut_auto() { printf "shortcut\n"; }
    main hy2
  ' bash "$SCRIPT")"
  expected="$(printf 'hy2\nshortcut')"
  assert_equals "$output" "$expected"

  output="$(bash -c '
    source "$1"
    uninstall_hy2() { printf "hy2\n"; }
    uninstall_v2_shortcut() { printf "v2\n"; }
    main uninstall-hy2
  ' bash "$SCRIPT")"
  assert_equals "$output" "hy2"
}

test_argument_errors
test_port_reinstall_guard
test_download_helpers
test_v2_download_failure_is_soft
test_firewall_and_status_helpers
test_certificate_fingerprint
test_hy2_link_pinning
test_command_routing
printf 'All proxy.sh tests passed.\n'
