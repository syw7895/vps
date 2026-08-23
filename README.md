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

安装后会创建两个独立的 systemd timer：每周更新管理脚本；每周检查 Xray / Hysteria2 稳定版核心。更新使用不可变 Git 提交或发布资产，先校验、再替换；服务启动失败会回滚。

## 界面原则

- 正常安静，异常才醒目；每事实只显示一次
- 无边框 / 横线 / Logo / 分类标题
- 每页最多 5 个主要操作；序号形如 `1.`
- 提示：`请选择 [0-N]:`（无 ›）
- 危险操作置底，确认默认 `N`

## 菜单示例

```text
  VPS  v1.3.0

   1.  代理管理
   2.  流量管理

   0.  退出

  请选择 [0-2]:
```

```text
  代理管理  v1.6.0
  ● 2 个节点运行中

   1.  安装代理
   2.  节点与状态
   3.  更新代理核心
   4.  卸载

   0.  返回

  请选择 [0-4]:
```

```text
  流量管理  v1.4.1
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
- Xray / Hysteria2 每周检查稳定版更新；发布资产校验 SHA256，配置检查和服务启动失败自动回滚
- 可在代理菜单立即更新，或运行 `sudo bash /usr/local/lib/syw-vps/proxy.sh update-cores`
- 管理脚本每周从 GitHub 当前分支对应的不可变提交更新；可运行 `sudo vps update`
- 修复 Xray `ExecStart` 配置路径解析，并兼容非 root 的只读测试环境

## 流量

- vnStat 出站 TX；systemd timer + flock
- 状态页含进度条；qdisc/handle 仅 debug
- 「修改流量设置」一次改额度 / 比例 / 速度
- 达到设定额度/阈值后，会在当前默认出口网卡启用本工具的限速规则；这会影响该网卡上的所有出口服务，是预期的自动保护行为。

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
bash tests/integrity-safety-test.sh
bash tests/hy2-update-test.sh
bash tests/core-update-test.sh
bash tests/entrypoint-update-test.sh
```
