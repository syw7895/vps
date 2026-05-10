# VPS Proxy Scripts

One-click proxy setup scripts for Ubuntu and Debian VPS servers.

## Supported Protocols

- Xray VLESS + REALITY + Vision
- Hysteria2

## Quick Start

Run the menu:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/syw7895/vps/main/proxy.sh)
```

Or install directly:

```bash
# Xray VLESS + REALITY, TCP 443
bash <(curl -fsSL https://raw.githubusercontent.com/syw7895/vps/main/proxy.sh) xray

# Hysteria2, UDP 8443 with self-signed certificate
bash <(curl -fsSL https://raw.githubusercontent.com/syw7895/vps/main/proxy.sh) hy2
```

## Direct Options

```bash
# Xray Reality
bash proxy.sh xray --port 443 --sni www.microsoft.com --target www.microsoft.com:443

# Hysteria2 self-signed mode
bash proxy.sh hy2 --port 8443

# Hysteria2 ACME mode, requires a domain pointed to this VPS
bash proxy.sh hy2 --port 443 --domain example.com --email admin@example.com
```

## Notes

- Run as `root` on Debian 11+, Debian 12+, Ubuntu 22.04+, or Ubuntu 24.04+.
- Xray Reality uses TCP.
- Hysteria2 uses UDP.
- Hysteria2 ACME mode should use port `443`; self-signed mode can use `8443`.
- The script installs the Hysteria2 service as `root` so it can read certificates and bind low ports reliably.
- If your VPS provider has an external firewall, open the selected ports there too.
- Keep your SSH session open while testing new services.
