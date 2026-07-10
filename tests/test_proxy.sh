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
test_command_routing
printf 'All proxy.sh tests passed.\n'
