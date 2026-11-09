# 部署

## 构建

```bash
cd fprobe
cjpm build --release
# 产物：target/release/bin/fprobe
```

`cjpm install` 后可把 `fprobe` 放到 `/usr/local/bin`。

## 节点代理

每个受监控节点运行一个 `fprobe agent`，默认监听 `12323`：

```bash
fprobe agent --probe_port=12323 --probe_intervalMs=5000
```

最小 systemd 单元 `/etc/systemd/system/fprobe-agent.service`：

```ini
[Unit]
Description=fprobe agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/fprobe agent --probe_port=12323
Restart=always
RestartSec=5
# 采集 /proc、执行 ipmitool/smartctl/snmpbulkwalk 需要相应权限
User=root
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
```

## 监督端

常驻模式（无终端，日志是唯一输出）：

```bash
fprobe supervisor resident --probe_nodes='node-a@10.0.0.11:12323,node-b@10.0.0.12:12323'
```

systemd 单元 `/etc/systemd/system/fprobe-supervisor.service`：

```ini
[Unit]
Description=fprobe supervisor
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
# 告警规则通过 --probe_alarmRules='[...]' 或同名环境变量提供
ExecStart=/usr/local/bin/fprobe supervisor resident \
  --probe_nodes='node-a@10.0.0.11:12323,node-b@10.0.0.12:12323' \
  --probe_channel_email_smtpHost=smtp.example.com \
  --probe_channel_email_from=fprobe@example.com \
  --probe_channel_email_receivers=ops@example.com \
  --probe_alarmRules='[{"name":"cpu-high","kind":"cpu","path":"$.usagePercent","op":"gt","threshold":85,"forSeconds":60,"level":"warning"}]'
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
```

控制台模式直接在前台运行 `fprobe supervisor`，适合临时排查。

## 权限

| 采集项 | 需要的权限 |
| --- | --- |
| `/proc` 指标 | 普通用户 |
| `ipmitool` | root 或 `ipmi` 组 |
| `smartctl` | root（或对应设备的读权限） |
| `snmpbulkwalk` | 能访问设备的 community 即可 |
| 监听 `12323` | 无需特权端口 |

工具缺失不会导致启动失败：对应监控项会以 `available=false` 上报，其余指标照常采集。

## 扩展目录

把扩展动态库放进 `probe_customDir`（默认 `./custom`），`fprobe agent` 启动时用
`std.reflect.PackageInfo.load` 逐个加载。`probe_customFailFast=true` 时任一库加载失败
即终止启动；设为 `false` 则记录错误后继续。

## 配置来源

所有 `probe_*` 都可以通过命令行、环境变量或 `f_config` 的嵌入配置提供。命令行优先级
最高，适合在 systemd 单元里覆盖单机差异。
