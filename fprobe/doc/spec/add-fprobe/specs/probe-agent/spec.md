# Spec Delta

## Purpose

在每台服务器上提供一个可部署的监控代理：按固定周期采集主机与服务水平指标，把最近一次结果保存在进程内，并让监督端通过一次 RPC 调用取回该节点的全部数据。采集失败必须局部化，不能让单个探针或缺失的外部工具拖垮整个 agent。

## ADDED Requirements

### Requirement: 启动与配置

系统 SHALL 提供 `fprobe agent` 子命令；RPC 监听端口默认 `12323`，可用 `probe_port` 覆盖；主机标识默认取本机名，可用 `probe_host` 覆盖；采集间隔默认 `5000` 毫秒，可用 `probe_intervalMs` 覆盖。

启动 MUST 按「解析配置 → 校验 → 注册内置探针 → 加载 `custom/` → 启动采集 → 启动 RPC 服务」的顺序执行；配置非法时 MUST 在监听端口之前以非零码退出并打印原因。

#### Scenario: 默认启动

- **WHEN** 未配置任何 `probe_*` 且执行 `fprobe agent`
- **THEN** 进程在 `12323` 端口提供 RPC 服务，主机标识为本机名，每 5 秒采集一次

#### Scenario: 端口非法

- **WHEN** `probe_port=70000` 或非数字
- **THEN** 进程在启动 RPC 前退出并给出明确的配置错误

#### Scenario: 帮助

- **WHEN** 执行 `fprobe --help` 或 `fprobe agent --help`
- **THEN** 打印子命令与关键配置项，返回 0

### Requirement: 周期采集与局部失败

系统 SHALL 以 `probe_intervalMs` 为周期对每个已注册监控项采样，保存最近一次成功数据、采集时间戳与错误信息。单个监控项抛错或返回非法数据 MUST 只影响该项，其它监控项继续采样；RPC 读取 MUST NOT 触发即时采集。

#### Scenario: 单探针失败

- **WHEN** 磁盘探针因 `df` 不可用而失败，CPU 探针正常
- **THEN** 快照中 `disk.error` 非空，`cpu.dataJson` 仍是本次采集的成功数据

#### Scenario: 首次采样

- **WHEN** agent 启动后第一次采样 CPU
- **THEN** CPU 使用率基于启动预热期内的两次 `/proc/stat` 差分计算，而不是恒为 0

#### Scenario: RPC 只读

- **WHEN** 监督端在两次采样之间调用 `collect()`
- **THEN** 返回上一次采样结果，不额外执行采集，也不阻塞采样线程超过读取快照的时间

### Requirement: RPC 数据契约

系统 SHALL 通过 `f_rpc` 暴露 `ProbeRPC`，至少包含 `collect(): ProbeSnapshot` 与 `kinds(): ProbeKinds`。`ProbeSnapshot` MUST 包含节点名、主机、时间戳与 `ProbeAgentData` 数组；每条 `ProbeAgentData` MUST 包含 `kind`、`host`、`dataJson`（JSON 文本）、`collectedAt`（epoch 毫秒）与 `error`。`ProbeAgentData.host` MUST 在监控项 `host` 为空时用 `probe_host` 或本机名填充。

`kinds()` MUST 返回一个包含字符串数组的对象（而不是裸数组），以满足 `f_rpc` 对返回类型必须是 `DataFields` 的约束。

#### Scenario: 一次拉回全部数据

- **WHEN** 监督端对某节点调用一次 `collect()`
- **THEN** 返回该节点当前全部已注册监控项的快照，不需要按监控项逐个调用

#### Scenario: 编解码往返

- **WHEN** 把 `ProbeSnapshot` 编码为 RPC 消息再解码
- **THEN** 所有字段（含 `dataJson` 文本与数组顺序）保持一致

#### Scenario: 标准客户端可调用

- **WHEN** 一个持有相同 `ProbeRPC` 接口声明的 RPC 客户端连接 agent
- **THEN** 可以调用 `collect()` / `kinds()`，服务端不需要为客户端做特殊适配

#### Scenario: 主机补全

- **WHEN** 某扩展监控项的 `host` 返回空字符串
- **THEN** 快照中该项 `host` 为 `probe_host` 的值；未配置时为该节点本机名

### Requirement: CPU 监控

系统 SHALL 采集 CPU 总使用率、`iowait` 占比、1/5/15 分钟 Load Average 与逻辑核数，数据字段为 `usagePercent`、`iowaitPercent`、`load1`、`load5`、`load15`、`cores`。

#### Scenario: CPU 差分

- **WHEN** 两次采样之间总时间片增加 100，空闲与 iowait 合计增加 40
- **THEN** `usagePercent` 约为 60，`iowaitPercent` 等于 iowait 增量占总增量的比例

### Requirement: 内存监控

系统 SHALL 采集 `totalBytes`、`usedBytes`、`availableBytes`、`freeBytes`、`cachedBytes`、`buffersBytes`、`swapTotalBytes`、`swapUsedBytes`、`swapFreeBytes`。`usedBytes` MUST 按 `total - available` 计算，而不是只看 `free`。

#### Scenario: 可用内存口径

- **WHEN** `/proc/meminfo` 给出 `MemTotal`、`MemAvailable`、`MemFree`
- **THEN** `usedBytes = MemTotal - MemAvailable`，且 `availableBytes` 原样呈现

### Requirement: 磁盘监控

系统 SHALL 采集每个挂载点的空间与 inode 使用情况（`path/fs/totalBytes/usedBytes/availableBytes/usedPercent/inodesTotal/inodesUsed/inodesUsedPercent`），以及每个块设备的 I/O 指标（`device/readBytes/writeBytes/readIops/writeIops/awaitMs/utilPercent`）。

#### Scenario: 空间与 inode

- **WHEN** `df -Pk` 与 `df -Pi` 返回同一挂载点
- **THEN** 空间与 inode 指标按挂载点合并到同一条记录

#### Scenario: 坏输出

- **WHEN** `df` 输出缺少列或不是数字
- **THEN** 该探针返回 `COLLECT` 错误，不产生半截数据

#### Scenario: I/O 差分

- **WHEN** 两次采样之间设备完成 200 次读、100 次写，累计 I/O 时间增加 300ms
- **THEN** `readIops` 与 `writeIops` 按间隔换算，`utilPercent` 为 I/O 时间占间隔的比例

### Requirement: 系统与硬件健康

系统 SHALL 采集 `uptimeSeconds`、`processCount`、`tcpConnections`，并采集 IPMI 温度/风扇/电源、SNMP 传感器、硬盘 SMART 健康。硬件数据以 `ipmi[]`、`snmp[]`、`smart[]` 呈现；外部工具缺失或执行失败时，对应条目 MUST 为 `available=false` 并携带 `error`，系统探针整体 MUST 仍然成功。

#### Scenario: 工具缺失

- **WHEN** 系统没有安装 `ipmitool`
- **THEN** `ipmi` 中对应条目 `available=false`，`error` 说明命令不可用，`uptimeSeconds` 等字段照常返回

#### Scenario: SMART 文本兜底

- **WHEN** `smartctl` 版本不支持 `-j` JSON 输出
- **THEN** 使用文本输出解析关键属性，并在 `error` 中标注降级解析

### Requirement: 服务可达性

系统 SHALL 按 `probe_serviceTargets`（`name@url`）探测 HTTP/HTTPS/TCP 目标，返回 `targets[]`，每条包含 `name/url/reachable/latencyMs/statusCode/error`。HTTP 目标以 2xx/3xx 视为可达；TCP 目标以连接成功视为可达；超时或拒绝 MUST 记录为不可达而不是抛异常中断整次采集。

#### Scenario: HTTP 500

- **WHEN** 目标返回 500
- **THEN** `reachable=false`，`statusCode=500`，`error` 说明状态码

#### Scenario: TCP 拒绝

- **WHEN** TCP 目标端口没有监听
- **THEN** `reachable=false`，`latencyMs` 为本次尝试耗时，`error` 记录连接失败原因

### Requirement: 网络质量

系统 SHALL 按网卡采集 `name/rxBytes/txBytes/rxBytesPerSec/txBytesPerSec/bandwidthPercent/dropPercent/errorPercent/tcpRetransPercent`。速率 MUST 基于相邻两次采样的差分；`probe_networkInterfaces` 非空时只采集白名单网卡。

#### Scenario: 速率差分

- **WHEN** 两次采样间隔 5 秒，某网卡接收字节增加 5MB
- **THEN** `rxBytesPerSec` 约为 1MB/s

#### Scenario: 未知链路速率

- **WHEN** `/sys/class/net/<if>/speed` 不存在或为 0
- **THEN** `bandwidthPercent` 为 0，其它网络指标照常返回

### Requirement: MVC 与 RPC 健康探针

系统 SHALL 提供两个独立监控项：`mvc-health` 探测 `probe_mvcHealthUrl` 的 `/health` HTTP 端点，返回 `HealthData` 全字段加 `latencyMs`、`statusCode`；`rpc-health` 探测 `probe_rpcHealthTargets`（`name@host:port`），调用 `f_rpc.health.HealthRPC.health()`，返回 `HealthData` 全字段加 `latencyMs`。

#### Scenario: MVC 健康

- **WHEN** `/health` 返回 200 与合法 JSON
- **THEN** 监控项数据包含健康字段、`latencyMs` 与 `statusCode=200`

#### Scenario: RPC 健康

- **WHEN** 目标 RPC 服务可达
- **THEN** 监控项数据包含 `HealthData` 字段与本次调用耗时，不经过全局负载均衡客户端

### Requirement: 网络拓扑

系统 SHALL 通过 SNMP（IF-MIB + LLDP-MIB）发现网络设备、端口与邻接关系，输出 `devices[]`（`name/host/ports[]`）与 `links[]`（`from/to/localPort/remotePort`）。没有可用设备凭据或工具时 MUST 返回 `error`，agent 其它能力不受影响。

#### Scenario: 邻接去重

- **WHEN** 两台设备互相报告同一条链路
- **THEN** `links` 中只保留一条无向边，不重复计数

#### Scenario: 无凭据

- **WHEN** `probe_snmpDevices` 为空
- **THEN** 拓扑监控项返回空设备列表与说明性 `error`，不使采集失败

### Requirement: 非 Linux 平台

非 Linux 平台上，依赖 `/proc`、`/sys` 或 Linux 外部工具的监控项 MUST 返回明确的 unsupported 错误；agent MUST 仍能启动、RPC MUST 仍可调用，`kinds()` 仍列出已注册监控项。

#### Scenario: 非 Linux 启动

- **WHEN** 在非 Linux 平台执行 `fprobe agent`
- **THEN** 进程启动成功，`collect()` 返回的快照中相关监控项 `error` 含有 unsupported 说明

### Requirement: 自定义动态库加载

系统 SHALL 在启动时扫描 `probe_customDir`（默认 `./custom`）下的 `.so/.dll/.dylib`，按文件名排序后以去扩展名的路径调用 `std.reflect.PackageInfo.load`。加载失败或扩展注册与内置重名时 MUST 默认使启动失败；`probe_customFailFast=false` 时 MUST 记录 ERROR 后继续启动，并保持内置实现优先。

#### Scenario: 目录不存在

- **WHEN** `custom/` 不存在
- **THEN** 视为没有扩展，agent 正常启动

#### Scenario: 非库文件

- **WHEN** 目录中存在 README 或 `.txt` 文件
- **THEN** 忽略该文件，不尝试加载

#### Scenario: 重名

- **WHEN** 扩展注册的 `kind` 与内置 `cpu` 相同
- **THEN** 默认启动失败并指出冲突的 `kind`

### Requirement: 外部命令安全

系统调用 `df`、`ipmitool`、`snmpbulkwalk`、`smartctl` 时 MUST NOT 经过 shell；参数 MUST 由固定模板与经过校验的配置值组成（设备路径、主机、community），含空白或 shell 元字符的配置值 MUST 被拒绝。每次命令 MUST 有超时，超时按采集失败处理。

#### Scenario: 拒绝危险参数

- **WHEN** `probe_smartDevices` 中存在 `"/dev/sda; rm -rf /"`
- **THEN** 配置校验失败，启动退出并指出非法设备路径
