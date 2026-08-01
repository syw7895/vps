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
- 旧版 `v2` 快捷命令会在确认归属后自动清理（不再提供 v2）。

## 菜单

正常时主菜单不显示状态行（模块文件存在且 `bash -n` 通过）：

```text
  VPS  v1.1.8

   1  代理管理
   2  流量管理

   0  退出

  请选择 [0-2] ›
```

异常时才黄/红提示，例如：`! 代理模块不可用`、`× 功能模块不可用`。

### 代理菜单（proxy v1.4.4）

```text
  代理管理  v1.4.4
  ● 代理运行中

   1  安装代理
   2  节点与状态
   3  卸载

   0  返回
```

### 流量菜单（traffic v1.3.8）

未安装：

```text
  流量  v1.3.8
  ○ 尚未安装

   1  安装流量监控

   0  返回
```

已安装：

```text
  流量  v1.3.8
  ● 正常运行  本月 38 / 100 GB

   1  查看状态
   2  修改流量设置
   3  立即检查
   4  暂停自动检查
   5  更多操作

   0  返回
```

「更多操作」含更新 / 卸载；正在限速时增加「解除当前限速」。

## 代理：节点与状态

- **证据优先级**：`systemctl` ExecStart 实际配置 > 固定路径回退；协议语义识别 REALITY（vless+reality）/ CDN（vless+ws+tls）；tag 仅快路径。
- systemd 只表示「运行中/已停止」，不能单独证明 inbound 存在。
- state / info 仅为元数据与连接缓存。
- 旧版无 state 仍正常显示，并提示「状态元数据缺失」；仅 info 残留不追加「暂无代理」。
- 查看状态时**只读**，不修改配置 / 端口 / 证书 / 凭据。

## 流量

1. `sudo vps` → `2` → 安装监控
2. 「修改流量设置」一次改额度 / 触发比例 / 限速（回车保持，确认后原子写入）

默认：达到额度 **90%** 时出口限速 **1 Mbit/s**；每 5 分钟检查。

配置 `/etc/vps-traffic/config` · 状态 `/var/lib/vps-traffic/state` · timer `vps-traffic-check.timer`

## 测试

```bash
bash -n vps.sh proxy.sh traffic.sh
bash -n tests/*.sh
bash tests/vps-menu-test.sh
bash tests/proxy-menu-test.sh
bash tests/traffic-mock-test.sh
bash tests/traffic-menu-test.sh
bash tests/menu-ui-test.sh
bash tests/status-ui-test.sh
```
