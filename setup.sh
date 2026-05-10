#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="vps-setup"
DEFAULT_TIMEZONE="Asia/Shanghai"
DEFAULT_SSH_PORT="22"

USERNAME=""
SSH_PORT="$DEFAULT_SSH_PORT"
TIMEZONE="$DEFAULT_TIMEZONE"
SWAP_SIZE=""
SSH_PUBLIC_KEY=""
INSTALL_DOCKER="false"
ENABLE_FIREWALL="true"
ENABLE_FAIL2BAN="true"
DISABLE_PASSWORD_LOGIN="false"
DRY_RUN="false"

log() {
  printf '[%s] %s\n' "$APP_NAME" "$*"
}

die() {
  printf '[%s] ERROR: %s\n' "$APP_NAME" "$*" >&2
  exit 1
}

run() {
  if [[ "$DRY_RUN" == "true" ]]; then
    printf '[dry-run] %q' "$1"
    shift || true
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi

  "$@"
}

usage() {
  cat <<'EOF'
Usage:
  bash setup.sh --user NAME [options]

Options:
  --user NAME          Create or configure a sudo user
  --ssh-port PORT      Set SSH port, default: 22
  --timezone ZONE      Set server timezone, default: Asia/Shanghai
  --ssh-public-key KEY  Add an SSH public key for the new user
  --disable-password-login
                       Disable SSH password login after a key is configured
  --swap SIZE          Create swap file, example: 1G, 2G
  --docker             Install Docker Engine
  --no-firewall        Skip UFW firewall setup
  --no-fail2ban        Skip Fail2ban setup
  --dry-run            Print actions without executing them
  --help               Show this help
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --user)
        USERNAME="${2:-}"
        shift 2
        ;;
      --ssh-port)
        SSH_PORT="${2:-}"
        shift 2
        ;;
      --timezone)
        TIMEZONE="${2:-}"
        shift 2
        ;;
      --ssh-public-key)
        SSH_PUBLIC_KEY="${2:-}"
        shift 2
        ;;
      --disable-password-login)
        DISABLE_PASSWORD_LOGIN="true"
        shift
        ;;
      --swap)
        SWAP_SIZE="${2:-}"
        shift 2
        ;;
      --docker)
        INSTALL_DOCKER="true"
        shift
        ;;
      --no-firewall)
        ENABLE_FIREWALL="false"
        shift
        ;;
      --no-fail2ban)
        ENABLE_FAIL2BAN="false"
        shift
        ;;
      --dry-run)
        DRY_RUN="true"
        shift
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        die "Unknown option: $1"
        ;;
    esac
  done
}

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "Run this script as root."
}

validate_args() {
  [[ -n "$USERNAME" ]] || die "--user is required."
  [[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] || die "Invalid username: $USERNAME"
  [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || die "SSH port must be a number."
  (( SSH_PORT >= 1 && SSH_PORT <= 65535 )) || die "SSH port must be between 1 and 65535."

  if [[ -n "$SWAP_SIZE" ]]; then
    [[ "$SWAP_SIZE" =~ ^[0-9]+[MGT]$ ]] || die "Swap size must look like 512M, 1G, or 2G."
  fi
}

detect_os() {
  [[ -r /etc/os-release ]] || die "Cannot detect operating system."
  # shellcheck disable=SC1091
  . /etc/os-release

  case "${ID:-}" in
    ubuntu|debian)
      log "Detected ${PRETTY_NAME:-$ID}."
      ;;
    *)
      die "Unsupported OS: ${PRETTY_NAME:-unknown}. Use Ubuntu or Debian."
      ;;
  esac
}

install_base_packages() {
  log "Updating packages and installing base tools."
  run apt-get update
  run apt-get upgrade -y
  run apt-get install -y ca-certificates curl gnupg lsb-release sudo ufw fail2ban vim htop unzip tar
}

set_timezone() {
  log "Setting timezone to $TIMEZONE."
  run timedatectl set-timezone "$TIMEZONE"
}

ensure_user() {
  if id "$USERNAME" >/dev/null 2>&1; then
    log "User $USERNAME already exists."
  else
    log "Creating user $USERNAME."
    run adduser --disabled-password --gecos "" "$USERNAME"
  fi

  log "Adding $USERNAME to sudo group."
  run usermod -aG sudo "$USERNAME"
  configure_user_ssh_key
}

configure_user_ssh_key() {
  local home_dir
  home_dir="$(getent passwd "$USERNAME" | cut -d: -f6)"
  local ssh_dir="$home_dir/.ssh"
  local authorized_keys="$ssh_dir/authorized_keys"

  if [[ "$DRY_RUN" == "true" ]]; then
    log "Would configure SSH keys for $USERNAME if a key is available."
    return 0
  fi

  install -d -m 700 -o "$USERNAME" -g "$USERNAME" "$ssh_dir"

  if [[ -n "$SSH_PUBLIC_KEY" ]]; then
    printf '%s\n' "$SSH_PUBLIC_KEY" >> "$authorized_keys"
    log "Added provided SSH public key for $USERNAME."
  elif [[ -f /root/.ssh/authorized_keys ]]; then
    cp /root/.ssh/authorized_keys "$authorized_keys"
    log "Copied root authorized_keys to $USERNAME."
  else
    log "No SSH key found. Password login will stay enabled unless you add a key first."
  fi

  chown "$USERNAME:$USERNAME" "$authorized_keys" 2>/dev/null || true
  chmod 600 "$authorized_keys" 2>/dev/null || true
}

user_has_ssh_key() {
  local home_dir
  home_dir="$(getent passwd "$USERNAME" | cut -d: -f6)"
  [[ -s "$home_dir/.ssh/authorized_keys" ]]
}

configure_ssh() {
  local sshd_config="/etc/ssh/sshd_config"
  local backup="/etc/ssh/sshd_config.${APP_NAME}.bak"

  log "Configuring SSH."
  if [[ "$DRY_RUN" == "false" && ! -f "$backup" ]]; then
    cp "$sshd_config" "$backup"
  fi

  set_sshd_option "Port" "$SSH_PORT"
  set_sshd_option "PubkeyAuthentication" "yes"

  if [[ "$DISABLE_PASSWORD_LOGIN" == "true" ]]; then
    if [[ "$DRY_RUN" == "false" ]] && ! user_has_ssh_key; then
      die "Cannot disable password login before $USERNAME has an SSH key."
    fi

    set_sshd_option "PermitRootLogin" "prohibit-password"
    set_sshd_option "PasswordAuthentication" "no"
  else
    log "Leaving SSH password login unchanged. Use --disable-password-login after key login works."
  fi

  if command -v sshd >/dev/null 2>&1; then
    run sshd -t
  fi

  run systemctl restart ssh || run systemctl restart sshd
}

set_sshd_option() {
  local key="$1"
  local value="$2"
  local file="/etc/ssh/sshd_config"

  if [[ "$DRY_RUN" == "true" ]]; then
    log "Would set SSH option: $key $value"
    return 0
  fi

  if grep -Eq "^[#[:space:]]*${key}[[:space:]]+" "$file"; then
    sed -i -E "s|^[#[:space:]]*${key}[[:space:]]+.*|${key} ${value}|" "$file"
  else
    printf '\n%s %s\n' "$key" "$value" >> "$file"
  fi
}

configure_firewall() {
  [[ "$ENABLE_FIREWALL" == "true" ]] || return 0

  log "Configuring UFW firewall."
  run ufw allow "$SSH_PORT/tcp"
  run ufw allow 80/tcp
  run ufw allow 443/tcp
  run ufw --force enable
  run ufw status verbose
}

configure_fail2ban() {
  [[ "$ENABLE_FAIL2BAN" == "true" ]] || return 0

  log "Configuring Fail2ban."
  if [[ "$DRY_RUN" == "false" ]]; then
    cat >/etc/fail2ban/jail.d/sshd.local <<EOF
[sshd]
enabled = true
port = $SSH_PORT
maxretry = 5
findtime = 10m
bantime = 1h
EOF
  else
    log "Would write /etc/fail2ban/jail.d/sshd.local"
  fi

  run systemctl enable fail2ban
  run systemctl restart fail2ban
}

create_swap() {
  [[ -n "$SWAP_SIZE" ]] || return 0

  if swapon --show | grep -q '/swapfile'; then
    log "Swap file already active."
    return 0
  fi

  log "Creating $SWAP_SIZE swap file."
  run fallocate -l "$SWAP_SIZE" /swapfile
  run chmod 600 /swapfile
  run mkswap /swapfile
  run swapon /swapfile

  if [[ "$DRY_RUN" == "false" ]] && ! grep -q '^/swapfile ' /etc/fstab; then
    printf '/swapfile none swap sw 0 0\n' >> /etc/fstab
  fi
}

install_docker() {
  [[ "$INSTALL_DOCKER" == "true" ]] || return 0

  log "Installing Docker."
  run install -m 0755 -d /etc/apt/keyrings

  if [[ "$DRY_RUN" == "false" ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    local repo_id="$ID"
    local codename="${VERSION_CODENAME:-}"

    curl -fsSL "https://download.docker.com/linux/${repo_id}/gpg" |
      gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/%s %s stable\n' \
      "$(dpkg --print-architecture)" "$repo_id" "$codename" \
      >/etc/apt/sources.list.d/docker.list
  else
    log "Would add Docker apt repository."
  fi

  run apt-get update
  run apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  run usermod -aG docker "$USERNAME"
  run systemctl enable docker
  run systemctl start docker
}

print_summary() {
  cat <<EOF

Done.

User:       $USERNAME
SSH port:   $SSH_PORT
Timezone:   $TIMEZONE
Firewall:   $ENABLE_FIREWALL
Fail2ban:   $ENABLE_FAIL2BAN
Docker:     $INSTALL_DOCKER
Swap:       ${SWAP_SIZE:-none}

Keep your current SSH session open and test a new login before closing it:
  ssh -p $SSH_PORT $USERNAME@YOUR_SERVER_IP

EOF
}

main() {
  parse_args "$@"
  require_root
  validate_args
  detect_os
  install_base_packages
  set_timezone
  ensure_user
  create_swap
  configure_ssh
  configure_firewall
  configure_fail2ban
  install_docker
  print_summary
}

main "$@"
