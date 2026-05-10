# VPS 代理脚本

适用于 Ubuntu / Debian VPS 的一键代理安装脚本。

## 支持协议

- Xray VLESS + REALITY + Vision
- Hysteria2（支持 `v2` 快捷命令）

## 一键安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/syw7895/vps/main/proxy.sh)
```

## 常用命令

```bash
# 交互菜单
bash proxy.sh

# 安装 Xray
bash proxy.sh xray

# 安装 Hysteria2（等同于 hy2 / hysteria2）
bash proxy.sh hy2

# 安装快捷命令（只需执行一次）
bash proxy.sh install-shortcut

# 之后可直接输入 v2 进入菜单
v2

# 卸载
bash proxy.sh uninstall-xray
bash proxy.sh uninstall-v2
```

## 说明

- 请使用 `root` 用户运行。
- 支持 Debian 11+、Debian 12+、Ubuntu 22.04+、Ubuntu 24.04+。
- Xray Reality 使用 TCP。
- Hysteria2 使用 UDP，默认会随机生成端口。
- 如果 VPS 服务商有安全组或外部防火墙，请放行脚本显示的对应端口。
- 测试新节点前，请先不要关闭当前 SSH 连接。
- 脚本已改为“先下载远程安装器再执行”，并支持通过 `XRAY_INSTALLER_SHA256`、`HY2_INSTALLER_SHA256` 启用哈希校验（留空为不校验）。
