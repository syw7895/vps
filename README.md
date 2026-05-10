# VPS Setup

Ubuntu/Debian VPS initialization script.

## What It Does

- Updates system packages
- Installs common server tools
- Creates a non-root sudo user
- Hardens basic SSH settings
- Enables UFW firewall
- Installs and enables Fail2ban
- Optionally creates swap
- Optionally installs Docker

## Quick Start

Run as root on a fresh Ubuntu or Debian VPS:

```bash
bash setup.sh --user deploy
```

With Docker and 2 GB swap:

```bash
bash setup.sh --user deploy --docker --swap 2G
```

With an SSH key and password login disabled:

```bash
bash setup.sh --user deploy --ssh-public-key "ssh-ed25519 AAAA..." --disable-password-login
```

Preview actions without changing the server:

```bash
bash setup.sh --user deploy --docker --swap 2G --dry-run
```

## Options

```text
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
--help               Show help
```

## Notes

- Use this on a fresh server when possible.
- Keep another SSH session open while changing SSH settings.
- If you change the SSH port, make sure your VPS provider firewall allows that port.
- Password login is not disabled unless you explicitly pass `--disable-password-login`.
