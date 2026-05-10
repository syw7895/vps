# VPS Proxy Scripts

One-click proxy setup scripts for Ubuntu and Debian VPS servers.

## Supported Protocols

- Xray VLESS + REALITY + Vision
- Hysteria2

## Quick Start

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/syw7895/vps/main/proxy.sh)
```

## Notes

- Run as `root` on Debian 11+, Debian 12+, Ubuntu 22.04+, or Ubuntu 24.04+.
- Xray Reality uses TCP.
- Hysteria2 uses UDP.
- Hysteria2 ACME mode should use port `443`; self-signed mode can use `8443`.
- The script installs the Hysteria2 service as `root` so it can read certificates and bind low ports reliably.
- If your VPS provider has an external firewall, open the selected ports there too.
- Keep your SSH session open while testing new services.
