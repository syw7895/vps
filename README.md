# VPS 管理（代理 + 流量）

Debian / Ubuntu（需 **root**）。代理与流量两个独立模块，互不覆盖卸载。

## 安装

```bash
curl -fsSL https://raw.githubusercontent.com/syw7895/vps/main/vps.sh | sudo bash
```

一条命令：安装并进入菜单。也可 `sudo vps`。

| 路径 | 说明 |
|------|------|
| `/usr/local/lib/syw-vps/vps.sh` | 入口 |
| `/usr/local/lib/syw-vps/proxy.sh` | 代理 |
| `/usr/local/lib/syw-vps/traffic.sh` | 流量 |
| `/usr/local/bin/vps` | 日常命令 |

- 安装 / 重装入口时会 **重新下载覆盖** `proxy.sh` / `traffic.sh`（只覆盖模块脚本，不动节点配置与证书）。
- 下载只做 `bash -n` 语法检查。
- 系统里已有同名且非本工具的 `vps` 时拒绝覆盖。

## 菜单

正常时主菜单不显示状态行（模块文件存在且 `bash -n` 通过）：

```text
  VPS  v1.1.8

   1  代理管理
   2  流量管理

   0  退出

  请选择 [0-2] ›
```

异常时才黄/红提示，例如：`! 代理模块不可用`、`! 流量模块不可用`、`× 功能模块不可用`。

1. 代理管理 — REALITY / Hysteria2 / VLESS+WS+TLS（或历史 `v2`）  
2. 流量管理 — 额度、限速、检查、卸载  

### 代理：节点与状态

- **仅显示已配置组件**（以 state 文件为准：`reality.conf` / `cdn.conf` / `hy2.conf`）。
- 未配置的组件不出现「未安装」列表。
- 运行状态合并在节点标题行（如 `REALITY  ● 运行中  :443`）。
- 信息文件仅用于连接详情；无 state 的残留 info 只警告，不当作有效节点。

### 流量：状态页

默认显示用量、额度、阈值、网卡、限速策略、自动检查、上次检查。  
不显示颜色图例、tc handle、qdisc 全文；排障时用 `bash traffic.sh --status-debug` 或状态异常时自动展开。

## 流量

1. `sudo vps` → `2` → `1` 安装监控（vnStat 2.6+、timer）  
2. `2` 设置月额度（**十进制 GB**，`1 GB = 1_000_000_000` 字节）  

默认：达到额度 **90%** 时出口限速 **1 Mbit/s**（只限速，不动代理）；每 5 分钟检查；新月低于阈值自动解除。

| 菜单 | 作用 |
|------|------|
| 7 解除限速 | 去掉本工具 tc；未暂停时超阈值会再限 |
| 8 / 9 | 暂停 / 恢复自动检查 |
| 10 | 更新 `traffic.sh`（curl + 语法检查） |
| 11 | 卸载流量模块（不动代理 / v2 / vps） |

- tc handle：`1abc:`；外站 qdisc（HTB 等）只报冲突不覆盖  
- 默认统计 IPv4 出口 **TX**；`IFACE=` 可写在 `/etc/vps-traffic/config`  
- 出口网卡变更时会先清状态里的 `LIMIT_IFACE` 再决策  
- 依赖：vnStat 2.6+、python3、iproute2  

配置 `/etc/vps-traffic/config` · 状态 `/var/lib/vps-traffic/state` · timer `vps-traffic-check.timer`

## 代理

REALITY / Hysteria2（特权端口靠 `CAP_NET_BIND_SERVICE`）/ VLESS+WS+TLS（CF）。  
第三方安装脚本仍固定 URL + SHA-256。默认端口：REALITY `443`，CDN `8443`，HY2 随机 UDP。

## 测试

```bash
bash -n vps.sh proxy.sh traffic.sh
bash -n tests/*.sh
bash tests/traffic-mock-test.sh
bash tests/menu-ui-test.sh
bash tests/status-ui-test.sh
```
