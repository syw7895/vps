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
  local output status
  expect_function_failure '--port 后面需要参数值。' parse_xray_args --port
  expect_function_failure '--domain 后面需要参数值。' parse_hy2_args --domain
  expect_function_failure '端口必须在 1-65535' validate_target www.cloudflare.com:70000

  set +e
  output="$(
    # shellcheck disable=SC1090
    source "$SCRIPT"
    PUBLIC_IP=not-an-ip
    resolve_public_ip
  2>&1)"
  status=$?
  set -e
  (( status != 0 )) || fail_test "expected invalid --public-ip to fail"
  assert_contains "$output" '--public-ip 必须是有效 IPv4'
}

test_port_reinstall_guard() {
  local output status

  output="$(bash -c '
    source "$1"
    port_reserved_by_forwarder() { return 1; }
    listener_uses_port() { return 0; }
    service_owns_port() { return 0; }
    ensure_port_available 443 xray Xray tcp
  ' bash "$SCRIPT")"
  assert_contains "$output" "允许更新"

  set +e
  output="$(bash -c '
    source "$1"
    port_reserved_by_forwarder() { return 1; }
    listener_uses_port() { return 0; }
    service_owns_port() { return 1; }
    ensure_port_available 443 xray Xray tcp
  ' bash "$SCRIPT" 2>&1)"
  status=$?
  set -e
  (( status != 0 )) || fail_test "expected occupied third-party port to fail"
  assert_contains "$output" "已被其他程序监听"

  set +e
  output="$(bash -c '
    source "$1"
    port_reserved_by_forwarder() { return 0; }
    ensure_port_available 443 xray Xray tcp
  ' bash "$SCRIPT" 2>&1)"
  status=$?
  set -e
  (( status != 0 )) || fail_test "expected NAT/forwarder reservation to fail"
  assert_contains "$output" "NAT 转发占用"
}

test_download_helpers() {
  local temp_file actual_sha output status
  temp_file="$(mktemp)"
  printf 'fixture' >"$temp_file"
  actual_sha="$(sha256sum "$temp_file" | awk '{print $1}')"

  set +e
  output="$(bash -c '
    source "$1"
    ! sha256_matches "$2" "" &&
      sha256_matches "$2" "$3" &&
      ! sha256_matches "$2" "$4"
  ' bash "$SCRIPT" "$temp_file" "$actual_sha" "0000000000000000000000000000000000000000000000000000000000000000" 2>&1)"
  status=$?
  set -e

  rm -f "$temp_file"
  (( status == 0 )) || fail_test "hash helper test failed: ${output}"
  assert_equals "$output" ""
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

test_v2_materialize_from_source() {
  local temp_dir output
  temp_dir="$(mktemp -d)"
  output="$(bash -c '
    source "$1"
    V2_INSTALL_DIR="$2/v2"
    V2_SCRIPT_PATH="$V2_INSTALL_DIR/proxy.sh"
    V2_COMMAND_PATH="$2/v2-command"
    download_v2_local_copy() { echo "should-not-download"; return 1; }
    install_v2_shortcut_files
    [[ -f "$V2_SCRIPT_PATH" ]]
    # Linux 上是符号链接；部分 Windows/Cygwin 环境会落成可执行副本
    [[ -e "$V2_COMMAND_PATH" ]]
    grep -q "^APP_NAME=\"vps-proxy\"\$" "$V2_SCRIPT_PATH"
  ' bash "$SCRIPT" "$temp_dir")"
  assert_equals "$output" ""
  rm -rf "$temp_dir"
}

test_firewall_and_status_helpers() {
  local output temp_file
  temp_file="$(mktemp)"

  # active UFW should open port
  bash -c '
    source "$1"
    output_file="$2"
    ufw() {
      if [[ $1 == status ]]; then
        printf "Status: active\n"
      else
        printf "%s\n" "$*" >"$output_file"
      fi
    }
    open_firewall_port 443 tcp
  ' bash "$SCRIPT" "$temp_file"
  output="$(<"$temp_file")"
  assert_equals "$output" "allow 443/tcp"
  rm -f "$temp_file"

  # inactive / missing ufw should not hard-fail
  output="$(bash -c '
    source "$1"
    command() {
      if [[ $1 == -v && $2 == ufw ]]; then return 1; fi
      if [[ $1 == -v && $2 == firewall-cmd ]]; then return 1; fi
      if [[ $1 == -v && $2 == nft ]]; then return 1; fi
      builtin command "$@"
    }
    open_firewall_port 8443 udp
  ' bash "$SCRIPT" 2>&1)"
  assert_contains "$output" "8443/udp"

  output="$(bash -c '
    source "$1"
    service_status_label() { printf "%s" "$1"; }
    print_service_statuses
  ' bash "$SCRIPT")"
  assert_contains "$output" "Xray"
  assert_contains "$output" "xray"
  assert_contains "$output" "Hysteria2"
  assert_contains "$output" "hysteria-server"
}

test_certificate_fingerprint() {
  local temp_dir fingerprint
  temp_dir="$(mktemp -d)"
  cat >"${temp_dir}/openssl.cnf" <<'EOF'
[req]
distinguished_name = subject
prompt = no

[subject]
CN = test.example.com
EOF
  openssl req -x509 -newkey rsa:2048 -sha256 -nodes \
    -keyout "${temp_dir}/key.pem" -out "${temp_dir}/cert.pem" \
    -days 1 -config "${temp_dir}/openssl.cnf" >/dev/null 2>&1

  fingerprint="$(bash -c 'source "$1"; hy2_certificate_sha256 "$2"' \
    bash "$SCRIPT" "${temp_dir}/cert.pem")"
  assert_matches "$fingerprint" '^[0-9a-f]{64}$'

  rm -f "${temp_dir}/key.pem" "${temp_dir}/cert.pem" "${temp_dir}/openssl.cnf"
  rmdir "$temp_dir"
}

test_hy2_link_pinning() {
  local source_text
  source_text="$(<"$SCRIPT")"
  assert_contains "$source_text" "pinSHA256=\${cert_sha}"
}

test_public_ip_resolution() {
  local output
  output="$(bash -c '
    source "$1"
    PUBLIC_IP=203.0.113.10
    resolve_public_ip
  ' bash "$SCRIPT")"
  assert_equals "$output" "203.0.113.10"
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
test_v2_materialize_from_source
test_firewall_and_status_helpers
test_certificate_fingerprint
test_hy2_link_pinning
test_public_ip_resolution
test_command_routing
printf 'All proxy.sh tests passed.\n'
