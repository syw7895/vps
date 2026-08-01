# VPS 管理（代理 + 流量）

Debian / Ubuntu（需 **root**）。代理与流量两个独立模块。

## 安装

```bash
curl -fsSL https://raw.githubusercontent.com/syw7895/vps/main/vps.sh | sudo bash
```

| 路径 | 说明 |
|------|------|
| `/usr/local/lib/syw-vps/vps.sh` | 入口 |
| `/usr/local/lib/syw-vps/proxy.sh` | 代理 |
| `/usr/local/lib/syw-vps/traffic.sh` | 流量 |
| `/usr/local/bin/vps` | 日常命令 |

安装会重新下载覆盖模块脚本（不动节点配置与证书）。旧版 `v2` 会在确认归属后清理。

## 界面原则

- 正常安静，异常才醒目；每事实只显示一次
- 无边框 / 横线 / Logo / 分类标题
- 每页最多 5 个主要操作；序号形如 `1.`
- 提示：`请选择 [0-N]:`（无 ›）
- 危险操作置底，确认默认 `N`

## 菜单示例

```text
  VPS  v1.2.0

   1.  代理管理
   2.  流量管理

   0.  退出

  请选择 [0-2]:
```

```text
  代理管理  v1.5.0
  ● 2 个节点运行中

   1.  安装代理
   2.  节点与状态
   3.  卸载

   0.  返回

  请选择 [0-3]:
```

```text
  流量管理  v1.4.0
  ● 正常  38.2 / 100 GB

   1.  查看状态
   2.  修改流量设置
   3.  立即检查
   4.  暂停自动检查
   5.  更多操作

   0.  返回
```

## 代理节点

- 状态依据：真实服务配置（ExecStart + 协议语义）
- 正常页不显示 state / 元数据提示（`--status-debug` 可开）
- 节点标题含端口协议，如 `443/TCP`；分享链接单独成块

## 流量

- vnStat 出站 TX；systemd timer + flock
- 状态页含进度条；qdisc/handle 仅 debug
- 「修改流量设置」一次改额度 / 比例 / 速度

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
