# VPS 管理（代理 + 流量）

Debian / Ubuntu（需 **root**）。代理与流量为**两个独立模块**，互不安装、互不更新、互不卸载。

## 首次安装

```bash
curl -fsSL https://raw.githubusercontent.com/syw7895/vps/main/vps.sh | sudo bash
```

**推荐（不可变提交 + 完整性校验）：**

```bash
export SYW_VPS_REF=<git-commit-or-tag>
curl -fsSL "https://raw.githubusercontent.com/syw7895/vps/${SYW_VPS_REF}/vps.sh" | sudo bash
```

入口内置 `proxy.sh` / `traffic.sh` 的 SHA-256；下载后校验，不符则拒绝安装。仓库根目录 `checksums.sha256` 由 `scripts/update-checksums.sh` 生成，安装时写入 `/usr/local/lib/syw-vps/checksums.sha256`。开发可临时 `SYW_VPS_ALLOW_UNVERIFIED=1`（**勿用于生产**）。

会安装到：

| 路径 | 说明 |
|------|------|
| `/usr/local/lib/syw-vps/vps.sh` | 统一入口 |
| `/usr/local/lib/syw-vps/proxy.sh` | 代理模块 |
| `/usr/local/lib/syw-vps/traffic.sh` | 流量模块 |
| `/usr/local/lib/syw-vps/checksums.sha256` | 模块完整性清单 |
| `/usr/local/bin/vps` | 日常快捷命令 |

本地模块与入口期望哈希不一致时会**重新下载**。跨版本升级请重新执行入口安装。

若系统里已有同名 `vps` 且不属于本工具，安装会中止，避免误覆盖。

## 日常使用

```bash
sudo vps
```

安装与使用请**分开两条命令**：`curl|bash` 装完后新开 `sudo vps`，避免管道会话里交互异常。

菜单：

```text
VPS 管理
1. 代理管理
2. 流量管理
0. 退出
```

- **代理管理**：REALITY / Hysteria2 / VLESS+WS+TLS 等，均在代理模块内完成。
- **流量管理**：额度、限速、检查与卸载，均在流量模块内完成。

原有 **`v2`** 快捷命令（由代理模块安装）仍然可用，与 `vps` 入口互不影响。

## 流量模块说明

### 设置额度与默认策略

1. `sudo vps` → `2` 流量管理  
2. `1` 安装流量监控（vnStat 2.6+、systemd timer）  
3. `2` 设置每月流量额度（**十进制 GB**，`1 GB = 1_000_000_000` 字节）  

默认：

- 用量达到月额度的 **90%** 时，将公网出口限速为 **1 Mbit/s**（`tc`）
- **只限速**，不关机、不停止或修改代理
- 每 **5 分钟**自动检查；开机后也会检查
- **每月 1 日**起进入新统计周期；新月流量低于阈值会**自动解除**本工具限速

### 手动解除与再次限速

- 菜单 **7** 可解除当前由本工具创建的限速。  
- 若**未暂停**自动检查，且当月流量仍 ≥ 阈值，**下次 timer 会再次限速**。  
- 若需持续不限速：先 **8 暂停自动检查**，再 **7 解除限速**。

### 暂停 / 恢复 / 更新 / 卸载

| 菜单 | 作用 |
|------|------|
| 8 暂停自动检查 | 停止 timer，**不**停 vnStat 统计 |
| 9 恢复自动检查 | 启用 timer 并立即检查一次 |
| 10 更新流量模块 | 只更新 `traffic.sh` 与流量 unit，不碰 proxy/vps 入口 |
| 11 卸载流量模块 | 删除流量配置/状态/unit/本工具 tc；**不**删代理、节点、证书、`v2`、`vps` |

### tc 标识与冲突

- 本工具使用固定 root handle：**`1abc:`**（十六进制 major）。  
- 若网卡上已有 **其它** qdisc / 限速（HTB、WARP、VPN 等），本工具**只报告冲突，不修改网络**。  
- 重复检查不会叠加本工具规则。  
- 卸载或解除时，**只删除 handle/状态均匹配的本工具规则**。

### 重要提示

- **1 Mbit/s 持续约一天仍可能产生约 10.8 GB 流量**，不能绝对保证额度不会用完。  
- vnStat 与云厂商后台统计可能存在误差。  
- 默认统计默认 IPv4 出口网卡的 **TX**（`ip -4 route get 1.1.1.1`）；可在 `/etc/vps-traffic/config` 用 `IFACE=` 覆盖。  
- 默认出口网卡变更时，会先按状态中的 `LIMIT_IFACE` 清理旧网卡上的本工具限速，再按当前网卡决策，避免遗留或双限速。  
- 依赖：**vnStat 2.6+、python3、iproute2**（安装流量监控时会 apt 安装）。  
- 默认 `fq` / `fq_codel` / `noqueue` 等系统 qdisc 不视为冲突；HTB/其它限速会跳过以免覆盖。

配置：`/etc/vps-traffic/config`（安全 KV，不执行任意 shell）  
状态：`/var/lib/vps-traffic/state`  
Timer：`vps-traffic-check.timer`

## 代理模块说明

支持：

- **REALITY** — 直连  
- **Hysteria2** — UDP（降权 `hysteria` 用户；特权端口如 443 通过 `CAP_NET_BIND_SERVICE`）  

- **VLESS + WS + TLS** — 可走 Cloudflare  

安装、状态、更新、卸载均在 **代理管理** 菜单（或历史 `v2` / `proxy.sh` 流程）中完成。默认端口：REALITY `443`，CDN `8443`，HY2 随机 UDP。CDN 申请证书需域名解析到本机且 **80** 可访问。

## 高级排障

模块脚本位置（一般无需直接运行）：

```text
/usr/local/lib/syw-vps/vps.sh
/usr/local/lib/syw-vps/proxy.sh
/usr/local/lib/syw-vps/traffic.sh
```

模拟测试（开发用，不改真实网络）：

```bash
bash tests/traffic-mock-test.sh
```

环境变量（可选）：`SYW_VPS_RAW_BASE`、`VPS_TRAFFIC_MOCK=1`、`VNSTAT_BIN`、`TC_BIN`。
