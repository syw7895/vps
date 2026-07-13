# VPS 代理脚本

一键在 Debian / Ubuntu 上安装代理节点。

## 支持协议

| 协议 | 说明 |
|------|------|
| **Xray VLESS + REALITY** | 直连，无需自己的域名 |
| **Hysteria2** | UDP，适合弱网 |
| **VLESS + WS + TLS** | 可走 Cloudflare；客户端地址可填 CF 优选 IP，SNI/Host 仍用域名 |

## 一键安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/syw7895/vps/main/proxy.sh)
```

需要 **root**。进入菜单后可安装协议、查看节点、卸载，并自动添加 `v2` 快捷命令。

## 常用命令

```bash
v2                          # 打开菜单
bash proxy.sh xray          # 安装 REALITY
bash proxy.sh hy2           # 安装 Hysteria2
bash proxy.sh cdn --domain example.com   # 安装可走 CF 的 WS+TLS 节点
bash proxy.sh show          # 查看节点与状态
```

## 说明

- REALITY 默认 TCP 443；CDN 节点默认 TCP **8443**（避免与 REALITY 冲突）；Hysteria2 默认随机 UDP 端口。
- CDN 安装会用 acme.sh 申请证书，请保证域名已解析到 VPS，且 **80** 端口可访问。
- 若使用 Cloudflare：DNS 可开橙云，SSL 建议 Full / Full strict。优选 IP 在**本地网络**测速后填入客户端即可，搭建脚本不包含优选工具。
- 请在云安全组放行对应端口。
