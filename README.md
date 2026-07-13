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

# 查看节点信息与服务状态
bash proxy.sh show

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

## 进阶参数

```bash
# 公网 IP 自动检测失败时手动指定（分享链接会使用该地址）
bash proxy.sh xray --public-ip 203.0.113.10
bash proxy.sh hy2 --public-ip 203.0.113.10 --port 36712

# 固定客户端 UUID / 密码 / 域名
bash proxy.sh xray --uuid 11111111-1111-4111-8111-111111111111
bash proxy.sh hy2 --domain www.bing.com --password 'my-pass'
```

## 使用说明

- 请使用 `root` 用户运行。
- 支持 Debian 11+、Debian 12+、Ubuntu 22.04+、Ubuntu 24.04+。
- Xray Reality 使用 TCP，默认伪装目标为 `www.cloudflare.com:443`。
- **重装会复用**已有 UUID、REALITY 私钥/公钥与 ShortId，避免客户端配置失效。
- 安装/更新前会把旧配置备份到 `/root/proxy-info/backups/`。
- Hysteria2 使用 UDP，默认会随机生成端口；自签证书分享链接会附带 `pinSHA256` 指纹，客户端仍显示 `insecure=1` 属于正常配置。
- 防火墙：检测到 **活动的 UFW** 或 **firewalld** 时自动放行端口；nftables 仅提示；云厂商安全组需手动放行。
- 会尽量检测 Docker/Podman 端口映射与 NAT 转发占用，降低端口冲突。
- 重装并更换端口后，旧的 UFW 或云安全组规则不会自动删除，请确认新节点可用后再手动清理旧规则。
- 测试新节点前，请先不要关闭当前 SSH 连接。
- 直接执行 `bash proxy.sh xray` 或 `bash proxy.sh hy2` 并成功安装后，也会自动添加 `v2` 快捷命令。
- 脚本会先下载远程安装器再执行，并支持通过环境变量覆盖安装器 URL 与 SHA256。固定版本时必须同时设置 URL 和对应哈希。
- `v2` 的脚本副本保存在 `/usr/local/lib/vps-proxy/proxy.sh`，快捷命令位于 `/usr/local/bin/v2`。
  - 本地文件或 `bash <(curl ...)` 会优先安装当前脚本副本。
  - 无法物化当前脚本时，回退下载带 SHA256 校验的 `v2.sh` 快照。
- 如需固定 `v2` 来源，可同时设置 `V2_SCRIPT_URL` 和 `V2_SCRIPT_SHA256`。

## 开发与测试

```bash
bash -n proxy.sh tests/test_proxy.sh
shellcheck -x proxy.sh tests/test_proxy.sh
bash tests/test_proxy.sh
```

CI 在每次 push / PR 上运行上述检查。
