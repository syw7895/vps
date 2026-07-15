# VPS 代理脚本

一键在 **Debian / Ubuntu**（root）上安装代理节点。

当前脚本版本见 `proxy.sh` 内 `VERSION`（菜单标题也会显示）。

## 支持协议

| 协议 | 说明 |
|------|------|
| **Xray VLESS + REALITY** | 直连，无需自己的域名 |
| **Hysteria2** | UDP，适合弱网 |
| **VLESS + WS + TLS** | 可走 Cloudflare；客户端地址可填 CF 优选 IP，SNI/Host 仍用域名 |

## 推荐安装方式

**方式 A（推荐，可复查文件后再执行）：**

```bash
curl -fsSL https://raw.githubusercontent.com/syw7895/vps/main/proxy.sh -o proxy.sh
# 可选: less proxy.sh
bash proxy.sh
```

**方式 B（一行进菜单）：**

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/syw7895/vps/main/proxy.sh)
```

需要 **root**（或 `sudo`）。首次成功安装后会安装快捷命令 **`v2`**。

### 关于 `v2` 与在线快照

- 菜单里「安装 / 更新 v2」：若当前是**本地文件**执行，会把这份 `proxy.sh` 拷到 `/usr/local/lib/vps-proxy/proxy.sh`。
- 若是 **`bash <(curl …)`** 这类进程替换、无法可靠读到自身文件时，会下载脚本内 **固定 commit** 的独立快照（`V2_SCRIPT_URL` + `V2_SCRIPT_SHA256`），**不是**未校验的 `main` 浮动文件。
- 快照 URL 指向 Git **历史提交**中的文件；即使 `main` 上删了同名文件，该 commit 仍可下载。

## 常用命令

```bash
v2                              # 打开菜单（自动 sudo）
bash proxy.sh xray              # 安装/更新 REALITY（默认复用已有参数与密钥）
bash proxy.sh hy2               # 安装/更新 Hysteria2（默认复用）
bash proxy.sh cdn --domain a.com
bash proxy.sh show
bash proxy.sh xray --public-ip 1.2.3.4   # 公网 IP 探测失败时指定
```

## 重装与参数复用

- **默认复用**已有端口、SNI、UUID/密钥、HY2 密码、CDN path 等；命令行显式传入的参数优先。
- 菜单里 SNI：若已有配置，默认 **0 = 保持当前**（不是强制随机改掉）。
- 覆盖配置前会备份到 `/root/proxy-info/backups/`，成功后**只保留最近约 15 份**（可用环境变量 `BACKUP_KEEP` 调整）。

## 备份恢复

安装/更新失败或服务起不来时，脚本会打印最近备份路径。手动恢复示例：

```bash
ls -lt /root/proxy-info/backups/
tar -tzf /root/proxy-info/backups/某文件.tar.gz    # 先看内容
tar -C / -xzf /root/proxy-info/backups/某文件.tar.gz
systemctl restart xray            # 或 hysteria-server
journalctl -u xray -n 40 --no-pager
```

## 网络与防火墙

| 用途 | 端口 |
|------|------|
| REALITY | 默认 **TCP 443**（可改） |
| CDN WS+TLS | 默认 **TCP 8443**（少与 REALITY 抢 443） |
| CDN 申请证书 | 申请时需要 **TCP 80** 可达（脚本会尝试 UFW 放行） |
| Hysteria2 | 默认随机 **UDP**（可指定） |

请在**云安全组**与本机防火墙放行对应端口。活动 UFW 时脚本会尝试 `ufw allow`。

Cloudflare：DNS 可开橙云，SSL 建议 **Full / Full (strict)**。优选 IP 在**你本机网络**测速后写入客户端地址即可；脚本不做优选。

## 环境变量（安装器 / 快照 pin）

脚本对远程安装器使用**固定 commit + SHA256**，避免执行未校验的浮动 `main`。可用环境变量覆盖：

| 变量 | 含义 |
|------|------|
| `XRAY_INSTALLER_URL` / `XRAY_INSTALLER_SHA256` | Xray 官方 install 脚本 |
| `HY2_INSTALLER_URL` / `HY2_INSTALLER_SHA256` | Hysteria2 install 脚本 |
| `ACME_INSTALLER_URL` / `ACME_INSTALLER_SHA256` | acme.sh |
| `V2_SCRIPT_URL` / `V2_SCRIPT_SHA256` | 在线落盘 v2 时的不可变快照 |
| `BACKUP_KEEP` | 备份保留份数（默认 15） |

更新 pin 示例：下载新脚本 → `sha256sum file` → 导出 URL 与哈希后再安装。

## 说明

- 请使用 root / sudo。
- CDN 证书落在 `/usr/local/etc/xray/certs/`（供默认 `nobody` 的 Xray 读取）。
- 节点信息在 `/root/proxy-info/`（权限收紧，需 root 查看）。
