# VPS 管理（代理 + 流量）

Debian / Ubuntu（需 **root**）。代理与流量两个独立模块，互不覆盖卸载。

## 安装

```bash
curl -fsSL https://raw.githubusercontent.com/syw7895/vps/main/vps.sh | sudo bash
sudo vps
```

可选固定版本：`export SYW_VPS_REF=<commit-sha>` 后再 curl。

| 路径 | 说明 |
|------|------|
| `/usr/local/lib/syw-vps/vps.sh` | 入口 |
| `/usr/local/lib/syw-vps/proxy.sh` | 代理 |
| `/usr/local/lib/syw-vps/traffic.sh` | 流量 |
| `/usr/local/bin/vps` | 日常命令 |

- 已有的 proxy/traffic **不会被入口覆盖**（缺了才下载）。
- 下载只做 `bash -n` 语法检查。
- 系统里已有同名且非本工具的 `vps` 时拒绝覆盖。

安装与菜单请分开：`curl|bash` 后新开终端执行 `sudo vps`。

## 菜单

```text
  VPS  v1.1.1
  ●  模块就绪

  1  代理管理
      REALITY · HY2 · CDN
  2  流量管理
      额度 · 限速 · 检查

  0  退出
  ›
```

1. 代理管理 — REALITY / Hysteria2 / VLESS+WS+TLS（或历史 `v2`）  
2. 流量管理 — 额度、限速、检查、卸载  

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
bash tests/traffic-mock-test.sh
```
