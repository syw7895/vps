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
# 一键安装并进入菜单（会自动添加 v2 快捷命令）
bash proxy.sh

# 安装 Xray
bash proxy.sh xray

# 安装 Hysteria2（等同于 hy2 / hysteria2）
bash proxy.sh hy2

# 之后可直接输入 v2 进入菜单
v2

# 卸载 Xray 服务
bash proxy.sh uninstall-xray

# 卸载 Hysteria2 服务
bash proxy.sh uninstall-hy2

# 只删除 v2 快捷命令，不会卸载任何代理服务
bash proxy.sh uninstall-v2
```

## Reality 伪装目标

- 默认使用 `www.cloudflare.com:443`，客户端 SNI 为 `www.cloudflare.com`。
- 菜单内可选择 Cloudflare、Yahoo、Microsoft 或自定义。
- `www.microsoft.com` 在部分 AWS 区域可能导致 TLS 握手不稳定；遇到 `Connection reset by peer` 或 `EOF` 时，优先切换到 Cloudflare。
- 也可以在执行前通过环境变量指定同一组目标和 SNI：

```bash
REALITY_DEST=www.cloudflare.com:443 \
REALITY_SERVER_NAME=www.cloudflare.com \
bash proxy.sh xray
```

## 使用说明

- 请使用 `root` 用户运行。
- 支持 Debian 11+、Debian 12+、Ubuntu 22.04+、Ubuntu 24.04+。
- Xray Reality 使用 TCP，默认伪装目标为 `www.cloudflare.com:443`。
- Hysteria2 使用 UDP，默认会随机生成端口。
- 如果 VPS 服务商有安全组或外部防火墙，请放行脚本显示的对应端口。
- 测试新节点前，请先不要关闭当前 SSH 连接。
- 安装 Xray 时可选择 Reality 伪装目标：Cloudflare、Yahoo、Microsoft 或自定义。
- 直接执行 `bash proxy.sh xray` 或 `bash proxy.sh hy2` 并成功安装后，也会自动添加 `v2` 快捷命令。
- 脚本已改为“先下载远程安装器再执行”，并支持通过 `XRAY_INSTALLER_SHA256`、`HY2_INSTALLER_SHA256` 启用哈希校验（留空为不校验）。
