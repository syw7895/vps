# VPS 代理脚本

适用于 Ubuntu / Debian VPS 的一键代理安装脚本。

## 支持协议

- Xray VLESS + REALITY + Vision
- Hysteria2

## 一键安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/syw7895/vps/main/proxy.sh)
```

## 说明

- 请使用 `root` 用户运行。
- 支持 Debian 11+、Debian 12+、Ubuntu 22.04+、Ubuntu 24.04+。
- Xray Reality 使用 TCP。
- Hysteria2 使用 UDP。
- 如果 VPS 服务商有安全组或外部防火墙，请放行对应端口。
- 测试新节点前，请先不要关闭当前 SSH 连接。
