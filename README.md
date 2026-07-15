# VPS 代理脚本

Debian / Ubuntu 一键安装（需 root）。

## 协议

- **REALITY** — 直连
- **Hysteria2** — UDP
- **VLESS + WS + TLS** — 可走 Cloudflare（客户端可把地址改成优选 IP）

## 安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/syw7895/vps/main/proxy.sh)
```

之后可用 `v2` 打开菜单。

## 命令

```bash
v2
bash proxy.sh xray
bash proxy.sh hy2
bash proxy.sh cdn --domain example.com
bash proxy.sh show
```

## 说明

- 默认端口：REALITY `443`，CDN `8443`，HY2 随机 UDP
- 重装默认复用已有节点参数；请放行对应端口与安全组
- CDN 申请证书需要域名解析到本机且 **80** 可访问
