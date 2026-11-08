# Design

## Context

需求输入底稿：`.workbuddy/fprobe-requirements.md`；动机与范围见 `proposal.md`，行为契约见 `specs/**/spec.md`。本节只记录**已在本工作区核实过的事实**，以及由此产生的设计约束。

### 已核实的现状

| 事实 | 出处 | 对设计的影响 |
| --- | --- | --- |
| `@RPCStub` 生成的桩调用 `RPCClient.call<R>(message)`，要求 `R: DataFields<R>` | `f_rpc/src/macros/RPCStub.cj:142-153`、`f_rpc/src/client/RPCClient.cj:178` | RPC 方法**不能**返回裸 `Array<String>`，`kinds()` 必须用 DTO 包装 |
| 服务端 `@RPCSkeleton` 把方法注册进 `ServiceHub`，同时登记实际版本与 `'*'` 版本 | `f_rpc/src/macros/RPCSkeleton.cj:87`、`f_rpc/src/server/ServiceHub.cj:58-75` | 定向客户端可用 `version='*'` 命中，无需与 agent 的版本号对齐 |
| 定向调用可绕过全局负载均衡：每个节点建一个 `Client<RPCMessage>`，发 `Message.consume<RPCMessage>(once: true, qos: AtMostOnce, data: rpcMessage)` | `f_rpc/src/client/RPCClient.cj:200-217`、`fmq/src/cluster/NodeRegistry.cj:73-77,138-151` | `NodeRpcTransport` 按此实现；全局 `RPCClient` 不能把调用固定到节点 |
| RPC 服务端端口读 `rpcServer_port`（默认 1203），`rpcServer_baseAddresses` 默认空 | `f_rpc/src/server/ServerConfig.cj:21-56`、`RPCServer.cj:44-92` | agent 启动前用 `Config.set` 把 `probe_port` 映射为 `rpcServer_port`；不配置 baseAddresses 以免注册线程空转 |
| RPC 服务端由 `RPCServerInitializer.start()` 阻塞启动，实例由 `InitializerCollection.initialize()` 返回的 provider 提供 | `f_rpc/src/server/RPCServerInitializer.cj:20-43`、`f_app/src/Initializer.cj:97-104` | agent 先做完全部初始化，最后再调用 `start()` |
| `HealthRPC.health(): HealthData` 已存在；`MVCHealthController` 暴露 `GET /health` 返回 `HealthData` | `f_rpc/src/health/HealthRPC.cj:22-25`、`f_mvc/src/health/MVCHealthMonitor.cj:26-29` | 两个健康探针直接复用，不重复实现 |
| `Config` 自动收集环境变量与 `--key=value` / `-key value` 命令行参数 | `f_config/src/Config.cj:62-98` | 所有 `probe_*` 配置无需手写解析；`fprobe supervisor resident` 不会被误当配置 |
| `f_chart.Chart.draw(JsonObject): String` 输出完整 SVG | `f_chart/src/Chart.cj:27-36` | 报告图表复用；TUI 图表不用它（终端里用 ratatui 的 Sparkline/Chart） |
| `f_email.Email.builder()` 支持 SMTP + IMAP/POP3，`MailMessage.builder().html().text().attach(name, FileBodySource(path), mediaType)`，`SendReport.isCompleteSuccess()` | `f_email/src/EmailFacade.cj:227-249,367`、`model/MailMessage.cj:229-243`、`smtp/SendReport.cj:64-87` | 邮件渠道与报告附件直接复用；IMAP 用 EXAMINE，不置已读 |
| `Ticktock.instance.addOrReplaceTask(taskName!, taskCron!, executor!)` | `f_ticktock/src/Ticktock.cj:172-205` | 周期报告注册 |
| `LLM.chatByName(llmName, LLMParams(model, messages))` | `f_llm/src/llm/LLM.cj:90-128`、`LLMByName_test.cj:77` | 智能体调用入口 |
| `SvgBuilder(width, height)` 提供 `rect/circle/line/path/text/group/end/attr/toSvgString/save` | `f_svg/src/SvgAuthoringBuilder.cj:31-260` | 拓扑图生成，且可做确定性布局 |
| `String.exec()` 按空格切参数、不经过 shell | `f_process/src/Process.cj:116-125` | 外部命令必须用固定模板 + 校验后的参数；含空白的值要拒绝或改走 `launch` 参数数组 |
| `CustomLoader` 的既有模式：目录扫描 → 排序 → `PackageInfo.load` → 收集注册 | `fdbm/src/server/CustomLoader.cj:65-150` | `fprobe` 的 `CustomLoader` 照此实现，但注册表在 `f_probe` |
| 可执行模块结构：`output-type="executable"`、`src-dir=""`、`src/main.cj` 分发子命令 | `fmq/cjpm.toml`、`fmq/src/main.cj:26-90` | `fprobe` 照此实现 |
| 接口可以带属性/函数的默认实现 | `f_app/src/Initializer.cj:21-46` | `ProbeAgent.host` 与 `AlarmMessageChannel.sendRich` 的默认实现成立 |
| `@DataAssist` DTO 可通过 `JsonValue.from(dto).toString()` / `JsonValue.fromStr(text).toData()` 与 JSON 互转 | `f_data/src/json/ExtendJson.cj:46-69`、`f_rpc/src/base/RPCMessage.cj:20-27` | 探针数据、图表描述、告警规则、回复消息全部用固定结构 DTO，禁止手写 JSON 取值 |

### 与需求底稿的三处必要修正

1. **`kinds()` 返回 DTO**：底稿写 `func kinds(): Array<String>`，但 `Array<String>` 不满足 `DataFields`，`@RPCStub` 无法展开。改为 `ProbeKinds { kinds: Array<String> }`。这是 f_rpc 的硬约束，不是偏好。
2. **`AlarmMessageChannel` 增加 `sendRich`**：原三方法原样保留；报告需要 HTML + 多个 SVG 附件，而 `send(String, Array<String>)` 无法承载附件。新增带默认实现的 `sendRich`，默认退化为 `send`，既有/第三方实现不必改。
3. **`f_probe` 不承载 `ProbeRPC`**：底稿要求 `f_probe` 只依赖 `f_base`、`f_data`。若把 `@RPCStub` 接口放进 `f_probe`，所有扩展作者都会被拖入 `f_rpc`/`f_net`/`f_codec`。因此 `ProbeRPC` 与 DTO 放在 `fprobe` 的 `fountain::fprobe.rpc` 包，`f_probe` 只保留 `ProbeAgent` 与 `AlarmMessageChannel` 契约。定向客户端由 `NodeRpcTransport` 实现；若将来要求外部仓颉客户端直接依赖，应新增轻量库 `f_probe_rpc`（本期不做，避免第三个模块）。

## Goals / Non-Goals

**Goals**

- 单节点 agent 一条命令可起，默认配置即可工作。
- 一次 `collect()` 取回该节点全部监控项，supervisor 不为每个指标单独建连。
- 单个探针、单个节点、单条规则、单个渠道的失败都被局部化。
- 扩展只依赖 `f_probe`，不依赖宿主可执行文件。
- 全部单测离线：fixture、假传输、临时目录、假终端。
- TUI 视图模型与终端绘制分离，视图逻辑可在无 TTY 的 CI 中测试。

**Non-Goals**

- 不做 Web UI、不做时序数据库；历史只在内存环形窗口。
- 不做告警规则热加载。
- 不做 LLM 自由命令执行。
- 不实现 IM 渠道。
- 不保证非 Linux 采集。

## Decisions

### D1. 两个模块，依赖单向

```
f_probe (dynamic, deps: f_base, f_data)
   ▲
   │
fprobe (executable, deps: f_probe + 采集/传输/邮件/图表/LLM/TUI)
```

`f_probe` 不引用 `fprobe`，也不引用 `f_rpc`/`f_email`/`f_llm`。扩展作者编译自己的 `.so` 时只需 `f_probe` 的路径依赖。

**替代**：把契约与默认实现都放进 `fprobe`。否决——可执行模块的包不能被外部作为库导入，扩展无从实现接口。

### D2. 注册表保存工厂，不保存实例

```cangjie
public class ProbeRegistry {
    public static func registerAgent(kind: String, factory: () -> ProbeAgent): Unit
    public static func agents(): Array<String>
    public static func agent(kind: String): ?(() -> ProbeAgent)
    public static func clear(): Unit   // 仅供测试
}
```

- 工厂而不是实例：实例需要读取运行期配置，注册发生在包加载期，配置可能尚未校验。
- 注册表内部用一把 `Mutex` 保护 `HashMap`；`agents()` 返回快照数组，避免调用方持锁遍历。
- 重名一律抛 `ProbeException(DUPLICATE)`；**内置先注册，扩展后加载**，所以扩展无法覆盖 `cpu` 等内置 `kind`。
- `clear()` 标 `@TestOnly` 语义（文档注明仅测试用），避免测试之间互相污染。

`AlarmChannelRegistry` 同构，键为渠道名（`email`）。

### D3. RPC DTO：JSON 文本承载探针数据

```cangjie
@DataAssist[fields props]
public class ProbeAgentData {
    public var kind: String = ""
    public var host: String = ""
    public var dataJson: String = "{}"
    public var collectedAt: Int64 = 0
    public var error: String = ""
    public init() {}
}

@DataAssist[fields props]
public class ProbeSnapshot {
    public var node: String = ""
    public var host: String = ""
    public var timestamp: Int64 = 0
    public var agents: Array<ProbeAgentData> = []
    public init() {}
}

@DataAssist[fields props]
public class ProbeKinds {
    public var kinds: Array<String> = []
    public init() {}
}
```

`JsonObject` 不是 `DataFields`，因此 `data` 以 JSON 文本进入 RPC。agent 侧 `dataJson = JsonValue.from(agent.data).toString()`；supervisor 侧直接对文本做 `JsonValue.fromStr` 后交给 `DataPath`，或解析为具体 DTO。`ProbeSnapshot.node` 只作展示；supervisor 的节点键以 `probe_nodes` 中配置的 `name` 为准，避免 agent 改名导致历史窗口错位。

**替代**：为每个探针定义 RPC 专用 DTO。否决——每加一个扩展探针就要改 RPC 契约，违背扩展点目标。

### D4. `ProbeRPC` 与定向传输

```cangjie
@RPCStub
public interface ProbeRPC {
    func collect(): ProbeSnapshot
    func kinds(): ProbeKinds
}

@RPCSkeleton
public class ProbeRPCImpl <: ProbeRPC { ... }
```

supervisor 不用生成的桩（全局负载均衡无法定向），而用 `NodeRpcTransport`：

```cangjie
let meta = ServiceMeta('*', '', 'fountain::fprobe.rpc.ProbeRPC', 'collect', [], 0.0, exactlyVersion: true)
let message = Message.consume<RPCMessage>(once: true, qos: AtMostOnce, data: RPCMessage(meta, []))
let response = client.transfer(message, timeout) ?? throw ProbeException(...)
match (response.command) {
    case Command.RESP(_) => ProbeSnapshot.fromData(response.data)
    case Command.ERROR => throw ProbeException(COLLECT, response.data.toString())
    case _ => throw ProbeException(COLLECT, 'unexpected command')
}
```

- 每个节点一个 `Client<RPCMessage>`，失败后关闭并在下次重建；`probe_nodeTimeoutMs` 控制单次等待。
- 连接心跳用 `Message.ping()`（与 fmq `NodeRegistry` 一致）。
- 服务端 hub 同时登记 `'*'`，所以版本号不参与运维负担。
- 为可测性，`NodeRpcTransport` 依赖一个 `ClientTransport` 小接口（`transfer(msg, timeout): ?Message` 与 `close()`）；生产实现包 `f_net.Client`，用例注入假实现，从而覆盖超时、ERROR、重连而不开真实端口。

**替代**：给 `RPCClient` 增加「按地址调用」。否决——要改公共模块，且会引入新的全局状态；本变更坚持不修改既有模块。

### D5. agent 采集：单写者 + 只读快照

```
[采集线程] --每 interval--> 对每个 ProbeAgent 调 data，成功/失败都写入 Slot
                                   │
                                   ▼
                         SnapshotStore（Mutex 保护的不可变快照）
                                   ▲
                                   │ 只读
                            [RPC 线程] collect()
```

- `ProbeRunner` 持 `HashMap<String, ProbeSlot>`，每个 slot 保存最后一次成功 JSON、时间戳、错误。
- 每次 tick 先构造新的 `ProbeSnapshot`，再在锁内整体替换引用；`collect()` 只做一次引用读取，不复制大对象、不触发采集。
- CPU/磁盘/网络需要差分：探针内部保存上一次原始计数；启动时做一次 200ms 预热采样，保证首个快照不是 0。
- 每个探针的异常被 `try/catch` 收敛为 `ProbeException(COLLECT)` → `error` 字段；`Error`/`Exception` 都不能逃出 tick。

### D6. 读取器与执行器抽象（可测试性的核心）

| 抽象 | 生产实现 | 测试替身 |
| --- | --- | --- |
| `ProcReader` | `RealProcReader`（读 `/proc`、`/sys`） | `FixtureProcReader`（内存 map） |
| `CommandRunner` | `FProcessRunner`（`f_process` + 超时） | `FakeCommandRunner`（固定 stdout/exit） |
| `HttpProbe` | `FHttpClientProbe` | `FakeHttpProbe` |
| `TcpProbe` | `StdTcpProbe` | `FakeTcpProbe` |
| `Clock` | `SystemClock`（`DateTime.now().toUnixTimeStamp()`） | `FakeClock`（可推进） |

探针只依赖抽象，不直接读文件/起进程。这样 `/proc` 解析、`df` 解析、超时、工具缺失都能用 fixture 覆盖，不需要真实的 Linux 环境或外部工具。

### D7. 内置探针的 kind 与数据形状

| kind | 关键字段 |
| --- | --- |
| `cpu` | `usagePercent`、`iowaitPercent`、`load1/5/15`、`cores` |
| `memory` | `totalBytes`、`usedBytes`、`availableBytes`、`freeBytes`、`cachedBytes`、`buffersBytes`、`swapTotalBytes`、`swapUsedBytes`、`swapFreeBytes` |
| `disk` | `mounts[]`、`devices[]`（字段见 spec） |
| `system` | `uptimeSeconds`、`processCount`、`tcpConnections`、`ipmi[]`、`snmp[]`、`smart[]` |
| `service` | `targets[]` |
| `network` | `interfaces[]` |
| `mvc-health` | `HealthData` 全字段 + `latencyMs`、`statusCode` |
| `rpc-health` | `HealthData` 全字段 + `latencyMs` |
| `topology` | `devices[]`、`links[]`、`error` |

每个探针定义一个 `@DataAssist` DTO（如 `CpuSample`、`DiskSample`），`data` getter 返回 `JsonValue.from(dto).asObject()`。禁止在探针里手写 JSON 字符串或 `JsonValue` 动态拼装。

`cpu`/`disk`/`network` 的差分统一用 `IntervalCounter` 小工具：保存上次原始值，`delta(current)` 返回增量与间隔秒数；间隔为 0 时返回 `None` 而不是除零。

### D8. 外部命令：固定模板 + 参数校验 + 超时

- `df -Pk` / `df -Pi`：无用户输入。
- `ipmitool sdr type Temperature|Fan|"Power Supply"`：无用户输入。
- `snmpbulkwalk -v2c -c <community> <host> <oid>`：`host` 必须是主机名/IP，`community` 不得含空白与 shell 元字符。
- `smartctl -A -j <device>`：`device` 必须匹配 `^/dev/[A-Za-z0-9/_.-]+$`。

`CommandRunner` 以**参数数组**为输入（内部用 `std.process.launch` 或 `String.exec` 的受控拼接），不调用 shell。超时由 `probe_commandTimeoutMs` 控制；超时 kill 子进程并按 `COLLECT` 失败处理。工具缺失（`ENOENT`）不等于采集失败：`system` 探针把对应条目置 `available=false` + `error`。

### D9. supervisor 视图模型与渲染分离

```
PollLoop ──更新──> NodeStateStore (Mutex)
                        │
                 ┌──────┴──────┐
                 ▼             ▼
            ViewModel       ReportJob
                 │
                 ▼
            RenderPlan  （纯数据：行、列、序列、颜色语义）
                 │
                 ▼
          RatatuiPainter（唯一接触 ratatui/crossterm 的类）
```

- `ViewModel` 不依赖终端：节点选择、分页、历史窗口、告警列表都是纯函数，可直接单测。
- `RenderPlan` 是普通结构（标题、左右分栏、表格行、Sparkline 数据数组、状态色），`RatatuiPainter` 只做「Plan → widget」的机械映射。这样即使 ratatui-cj 的 API 与预期有差异，也只影响一个薄层。
- TTY 检测收敛在 `TtyDetector` 接口；生产实现用 `std.posix.isatty`（实现期以仓颉文档核实确切 API），测试注入假实现。
- 渲染线程与拉取线程分离；共享状态用 `Mutex` + 快照替换，渲染持锁时间只覆盖复制引用。

**替代**：直接在 `ViewModel` 里调用 ratatui。否决——视图逻辑无法在 CI 测试，且库 API 变更会扩散。

### D10. 告警引擎：状态机而非每次全量重算

每条 `(node, rule)` 维护：

```
{ since: ?Int64, firing: Bool, lastSentAt: Int64, mutedUntil: Int64 }
```

每个 tick：

1. 取该规则的 `kind` 数据；取不到（节点失败 / 探针 error / kind 缺失）→ 走「数据缺失」分支。
2. 用 `DataPath` 取值并按规则聚合；满足条件：
   - `since` 为空则设为当前时间；
   - `now - since >= forSeconds*1000` 且未 firing → 触发；
   - 触发时若 `now - lastSentAt >= cooldown` 且未静音 → 生成 `AlarmEvent`，更新 `lastSentAt`。
3. 不满足条件：若 `firing` → 生成恢复事件（受 `recoverNotify` 控制），清空状态。

规则用 `@DataAssist` 固定结构解析（`Array<AlarmRule>` via `JsonValue.fromStr(...).toData()`），非法配置在启动期失败。

**替代**：每次遍历整个历史窗口判断 `forSeconds`。否决——历史点可能缺失或不均匀，且 O(rules × points) 在节点多时浪费；状态机只依赖当前值与时间。

### D11. 邮件渠道与「只读收件」

`EmailAlarmChannel` 实现：

- `send(message, receiver)`：纯文本 + 纯文本兜底 HTML。
- `sendRich(message, html, attachments, receiver)`：`MailMessage.builder().from(...).to(...).subject(prefix + subject).text(message).html(html).attach(...)`；`SendReport` 不完整成功时抛 `ProbeException`，由 dispatcher 记录并继续其它渠道。
- `receive()`：`Email.list(limit: probe_channel_email_receiveLimit)`，取最新一封带 `isUnread()` 的邮件，`Email.body(summary)` 取 `text`/`html`，返回 `ChannelMessage` 的 JSON；没有则返回 `""`。IMAP 是 EXAMINE，**不标已读**。
- `replyConf()`：返回 `probe_channel_email_replyAccount`。

配置前缀统一 `probe_channel_<name>_`；`email` 的键见配置表。第三方渠道自行读取自己的前缀，注册表只负责按名取工厂。

### D12. 报告：DTO → JSON → SVG → 附件

- `ChartSelector` 把 `metric id`（如 `cpu.usagePercent`）映射为配置键（点换下划线）→ 图表类型。
- `ChartSpec` 是 `@DataAssist` DTO，覆盖 `type/title/xAxis/series/width/height` 等实际用到的字段；`Chart.draw(JsonValue.from(spec).asObject())`。
- 报告批次在临时目录 `probe_reportTmpDir`（默认系统临时目录下 `fprobe-report-<pid>-<epoch>`）生成 `<node>-<metric>.svg`；发送完成后递归删除。
- `ReportJob` 只依赖 `NodeStateStore`、`ChartSelector`、`ChannelDispatcher`、`Clock`，因此可用假时钟直接调用 `runOnce()` 测试，不必等 CRON。
- 拓扑图：`TopologyRenderer` 按设备名排序后均匀分布在圆上（固定半径与角度步长），保证同输入同输出；`SvgBuilder` 画圆/线/文字。

### D13. LLM 智能体：结构化、可授权、可审计

- 触发：`AlarmBus` 发布 `AlarmEvent` 时，若开启且 trigger 匹配，投递到 `AdvisorQueue`；`interval` 由 `Ticktock` 注册。
- 提示词：`PromptBuilder.build(snapshotSummary, events, historyWindow)`；要求模型只输出一个 JSON object。
- 解析：去掉 ```json 围栏 → `JsonValue.fromStr` → `LlmAdvice.tryFromData`；失败则 `summary=原文`。
- 发送：`AdvisorMessage` DTO（含 advice、回复说明、授权账号提示）经 dispatcher 发送。
- 回复：`ReplyMonitor` 逐渠道 `receive()`；`ReplyMessage` DTO；`id` 查 `ReplyStateStore`；`from` 与 `channel.replyConf()` 指向的配置比对。
- 决策：`ActionWhitelist` 只认 `ack/mute/report/none`；`mute` 写入 `AlarmEngine.mute(rule, until)` 并持久化在内存（重启失效，符合「临时静音」）。
- 未授权固定回复：`本账号没有权限指挥智能体`。

**替代**：让模型直接返回可执行命令。否决——安全边界不可控，且与「不执行任意 shell」冲突。

### D14. 自定义扩展加载

`CustomLoader.load(dir, failFast)`：

1. `Directory.walk` 收集 `.so/.dll/.dylib`，按路径排序；
2. 对每个文件 `PackageInfo.load(stem)`；
3. 扩展在包初始化时调用 `ProbeRegistry.registerAgent` / `AlarmChannelRegistry.registerChannel`；
4. 任一加载/注册失败：`failFast=true` → `ProbeException(LOAD)` 终止启动；`false` → ERROR 日志后继续，内置实现保持优先。

目录不存在 = 无扩展；非库文件忽略。测试不加载真实 `.so`：直接向注册表注册重复项，验证拒绝逻辑；`librariesOf` 用临时目录验证过滤与排序。

### D15. 配置集中与校验

每个子命令一个 `Settings` 类（`AgentSettings`、`SupervisorSettings`、`ReportSettings`、`LlmSettings`），提供 `load(): Settings` 与 `validate(): Array<String>`。校验失败在启动期打印全部错误并退出 2。

- agent 启动前：`Config.set([("rpcServer_port", probe_port.toString())])`。
- supervisor 的 `probe_nodes` 在 `Settings` 内解析为 `NodeEndpoint`（name/host/port），非法项立即失败。
- 所有时间/数量型配置做范围校验（端口 1..65535，间隔 > 0，历史点数 >= 1，阈值有限数）。

### D16. 非 Linux 与降级

`@When[os == "Linux"]` 选择真实 `ProcReader`；其它平台注入 `UnsupportedProcReader`，每个读取方法抛 `ProbeException(COLLECT, "unsupported on <os>")`。agent 不因探针不可用而拒绝启动。

## Module Layout

```
f_probe/
  cjpm.toml                 # dynamic, deps f_base/f_data
  src/ProbeAgent.cj
  src/AlarmMessageChannel.cj
  src/ProbeRegistry.cj
  src/AlarmChannelRegistry.cj
  src/ProbeException.cj
  src/*_test.cj

fprobe/
  cjpm.toml                 # executable, deps 见下
  src/main.cj
  src/usage.cj
  src/config/{AgentSettings,SupervisorSettings,ReportSettings,LlmSettings,Validation}.cj
  src/collect/{ProbeRunner,ProbeSnapshotBuilder,ProbeSlot,MetricProjection,IntervalCounter}.cj
  src/collect/proc/{ProcReader,RealProcReader,FixtureProcReader,CpuProbe,MemoryProbe,DiskProbe,SystemProbe,NetworkProbe}.cj
  src/collect/health/{MvcHealthProbe,RpcHealthProbe,RpcCall}.cj
  src/collect/net/{ServiceReachabilityProbe,TcpProbe,HttpProbe}.cj
  src/collect/hw/{CommandRunner,FProcessRunner,IpmiProbe,SnmpProbe,SmartProbe}.cj
  src/collect/topology/{TopologyProbe,TopologyRenderer,IfMibParser,LldpParser}.cj
  src/rpc/{ProbeRPC,ProbeRPCImpl,NodeRpcTransport,NodeEndpoint}.cj
  src/custom/CustomLoader.cj
  src/supervisor/{Supervisor,PollLoop,NodeStateStore,NodeState,HistoryRing}.cj
  src/alarm/{AlarmRule,AlarmEngine,AlarmEvent,AlarmDispatcher,MissingDataTracker}.cj
  src/channel/{EmailAlarmChannel,ChannelMessage,ChannelDispatcher}.cj
  src/report/{ChartSelector,ChartSpec,ReportBuilder,ReportJob,Attachment}.cj
  src/llm/{ProbeAdvisor,PromptBuilder,AdviceParser,LlmAdvice,ReplyMonitor,ReplyStateStore,ActionWhitelist}.cj
  src/tui/{App,ViewModel,UiState,RenderPlan,RatatuiPainter,TtyDetector,KeyMap}.cj
  doc/
```

## RPC Wire Contract

| 项 | 值 |
| --- | --- |
| 服务类型名 | `fountain::fprobe.rpc.ProbeRPC` |
| 版本 | `*`（服务端同时登记实际版本与 `*`） |
| 方法 | `collect`（无参）、`kinds`（无参） |
| 命令 | `f_protocol` CONSUME，`QoS=AtMostOnce` |
| 请求载荷 | `RPCMessage(meta, [])` |
| 成功响应 | `Command.RESP`，`data` 为 `ProbeSnapshot` / `ProbeKinds` |
| 失败响应 | `Command.ERROR`，`data` 为错误文本 |

文档在 `fprobe/doc/` 中给出该表与一个最小客户端示例（便于非本仓客户端复现），避免「只有本仓能调」的隐式契约。

## Concurrency & Lifecycle

**agent**

```
main
 ├─ 解析 + 校验配置（失败→退出 2）
 ├─ Config.set(rpcServer_port)
 ├─ 注册内置探针
 ├─ CustomLoader.load()
 ├─ spawn 采集线程（while running: tick; sleep interval）
 └─ InitializerCollection.initialize() → 找到 RPCServerInitializer.start()（阻塞）
      └─ atExit: running=false；关闭采集线程；快照释放
```

**supervisor**

```
main
 ├─ 解析 + 校验配置
 ├─ 注册内置渠道 email
 ├─ CustomLoader.load()
 ├─ 构造 NodeStateStore / AlarmEngine / Dispatcher / ReportJob / Advisor
 ├─ spawn PollLoop（每 tick：并行拉取各节点 → 更新 store → 评估告警 → 发布事件）
 ├─ 注册 Ticktock 报告/周期分析任务
 ├─ mode == resident ? 等待信号退出
 │                   : TUI 事件循环（渲染线程 + 按键线程）
 └─ 退出：停止 PollLoop、关闭节点连接、恢复终端、flush 状态文件
```

`PollLoop` 对每个节点用 `spawn` 并发拉取，`Future.get()` 收敛结果；节点数很大时可改为固定大小线程池，本期不做（节点规模预期为个位数到几十）。

## Config Reference

> `+` 表示本设计新增、需求底稿未列出的配置项。

### agent

| 键 | 默认 | 说明 |
| --- | --- | --- |
| `probe_port` | `12323` | RPC 端口 |
| `probe_host` | 本机名 | 主机标识 |
| `probe_intervalMs` | `5000` | 采集间隔 |
| `probe_customDir` | `./custom` | 扩展目录 |
| `probe_customFailFast` | `true` | 扩展失败是否退出 |
| `probe_serviceTargets` | 空 | `name@url`，http/https/tcp |
| `probe_mvcHealthUrl` | 空 | MVC `/health` 地址 |
| `probe_rpcHealthTargets` | 空 | `name@host:port` |
| `probe_snmpDevices` | 空 | `name@host@community` |
| `probe_ipmiEnabled` | `false` | 是否采集 IPMI |
| `probe_smartDevices` | 空 | `/dev/sdX` 列表 |
| `probe_networkInterfaces` | 空=全部 | 网卡白名单 |
| `probe_diskExcludeFs` + | `tmpfs,devtmpfs,overlay,squashfs` | 不纳入磁盘指标的伪文件系统 |
| `probe_httpTimeoutMs` + | `2000` | HTTP 探测超时 |
| `probe_commandTimeoutMs` + | `3000` | 外部命令超时 |

### supervisor

| 键 | 默认 | 说明 |
| --- | --- | --- |
| `probe_nodes` | 空 | `name@host:port` 列表 |
| `probe_pollIntervalMs` | `5000` | 拉取间隔 |
| `probe_nodeTimeoutMs` + | `3000` | 单节点单次拉取超时 |
| `probe_missingThreshold` | `2` | 连续失败告警阈值 |
| `probe_historyPoints` | `60` | 历史点数 |
| `probe_alarmRules` | `[]` | 规则 JSON 数组 |
| `probe_alarmCooldownSeconds` | `300` | 去重窗口 |
| `probe_alarmRecoverNotify` | `true` | 恢复通知 |
| `probe_expectKinds` | 空 | 期望 kind 列表 |
| `probe_alarmChannels` | `email` | 启用渠道 |

### 渠道 / 图表 / 报告

| 键 | 默认 | 说明 |
| --- | --- | --- |
| `probe_channel_email_enabled` | `true` | 是否启用 |
| `probe_channel_email_smtpHost` / `_smtpPort` | — / `465` | SMTP |
| `probe_channel_email_smtpUser` / `_smtpPassword` | 空 | 凭据 |
| `probe_channel_email_smtpTls` | `true` | TLS |
| `probe_channel_email_from` | 空 | 发件人 |
| `probe_channel_email_receivers` | 空 | 默认收件人 |
| `probe_channel_email_replyAccount` | 空 | 可指挥智能体的账号 |
| `probe_channel_email_subjectPrefix` | `[fprobe]` | 主题前缀 |
| `probe_channel_email_imapHost` / `_imapPort` | 空 / `993` | 收信 |
| `probe_channel_email_receiveLimit` + | `20` | 每次收信条数 |
| `probe_chart_<metric>` | 见 spec | 图表类型 |
| `probe_reportCron` | 空 | CRON，空=关闭 |
| `probe_reportReceivers` | 空 | 收件人 |
| `probe_reportChannels` | `email` | 渠道 |
| `probe_reportTmpDir` + | 系统临时目录 | 附件临时目录 |

### LLM

| 键 | 默认 | 说明 |
| --- | --- | --- |
| `probe_llmAgent` | `false` | 开关 |
| `probe_llmName` | `deepseek-flash` | 模型名 |
| `probe_llmTrigger` | `alarm` | `alarm` / `interval` / `both` |
| `probe_llmReplyPollMs` | `30000` | 回复轮询 |
| `probe_llmIntervalMs` + | `300000` | 周期分析间隔 |
| `probe_llmMaxTokens` | 空 | 生成上限 |
| `probe_llmMuteSeconds` + | `600` | `mute` 动作时长 |
| `probe_replyStateFile` | `./data/reply-state.json` | 去重状态 |

## Security

- 外部命令不接受 shell 字符串；参数白名单与格式校验在 `Settings.validate` 完成。
- 邮件凭据只从配置读取，日志中不打印密码；`ToString` 不暴露密钥。
- 报告附件写入专用临时目录，文件名由节点名与指标名清洗（仅 `[A-Za-z0-9_.-]`），发送后删除。
- LLM 输出只作为文本展示与白名单动作输入；不 `eval`、不拼命令、不反射调用任意方法。
- 回复授权按渠道配置的账号列表判定；未授权固定回复，不泄露内部状态。
- TUI 只读共享状态，不执行用户输入的命令；按键映射固定。

## Error Handling

| 场景 | 行为 |
| --- | --- |
| 配置非法 | 启动期聚合打印，退出 2 |
| 单个探针失败 | 快照中该项 `error`，其余正常 |
| 单节点拉取失败 | 计数 + 超时；达阈值告警；不影响其它节点 |
| 单渠道发送失败 | ERROR 日志；继续其它渠道 |
| 动态库加载失败 | 默认退出；可配置降级 |
| 报告生成失败 | ERROR 日志；清理临时文件；下周期重试 |
| LLM 失败 | ERROR 日志；不影响拉取/告警/报告 |
| 状态文件损坏 | WARN；按空集合启动 |

## Testing Strategy

- **契约层**：接口默认值、注册/查找/重名/并发、错误码。
- **纯解析层**：`/proc/stat`、`/proc/meminfo`、`/proc/loadavg`、`/proc/diskstats`、`/proc/net/dev`、`/proc/net/snmp` 的 fixture；`df -Pk`/`df -Pi` 正常与坏输出；`ipmitool`/`smartctl` 文本与 JSON；LLDP/IF-MIB walk 文本。
- **时间与差分**：`FakeClock` 推进，断言速率、IOPS、await、util、`forSeconds`。
- **网络探针**：本地临时监听端口测 TCP 连通/拒绝/超时；HTTP 用假 `HttpProbe`，不连外网。
- **RPC**：`ProbeSnapshot`/`ProbeAgentData`/`ProbeKinds` 的 `@DataAssist` 往返；`NodeRpcTransport` 注入假传输测一次 collect、超时、ERROR 映射；真实的 `ProbeRPCImpl` 用内存快照直接调用。
- **告警**：gt/gte/lt/lte/eq/ne、`forSeconds`、冷却、恢复、缺数据、缺 kind、静音。
- **邮件**：HTML 断言红色/橙色横幅、节点/指标/阈值表格；恢复绿色；纯文本兜底；`sendRich` 附件名。
- **图表/报告**：`ChartSelector` 默认与回退；SVG 非空且含数据点；附件命名；临时目录清理；CRON 空不注册。
- **扩展**：目录不存在、非库文件忽略、重复注册拒绝、失败降级（不加载真实 `.so`）。
- **TUI**：`ViewModel` 的节点/页切换、历史窗口、告警列表；`RenderPlan` 的行与序列断言；`TtyDetector` 假实现覆盖非 TTY 分支。
- **LLM**：提示词包含节点/阈值/历史；围栏剥离；解析失败兜底；未授权文案；白名单动作；消息去重与状态文件损坏。
- **回归**：`f_probe`、`fprobe` 各自 `cjpm test`；至少对 `f_rpc`、`f_email`、`f_chart`、`f_ticktock` 跑回归（本变更不改它们，但依赖其行为）。
- 全部用例不依赖外网、真实 SMTP/IMAP/LLM/IPMI/SNMP。

## Risks / Trade-offs

| 风险 | 缓解 |
| --- | --- |
| `ratatui-cj` 系列包在中心仓的可用性与 API 与预期有差异 | 版本按需求钉死；绘制收敛在 `RatatuiPainter`；实现首任务先做最小可编译的 `RenderPlan → 一帧` 冒烟；不可用时停下报告，不静默换库 |
| `f_llm` 处于根 `.modules` 的 `[detention]`，且传递依赖 DB 驱动 | 实现期先验证 `fprobe` 能构建；若驱动/版本冲突，将 LLM 适配层收敛到 `src/llm/`，仅此处依赖 `f_llm`，并在文档记录所需环境 |
| 外部工具缺失/版本差异 | 统一 `available=false` + `error`；`smartctl` 文本兜底；fixture 覆盖 |
| `/proc`/`/sys` 字段随内核变化 | 解析器容忍未知字段，缺字段返回明确错误；fixture 覆盖主流格式 |
| IMAP 不能标已读导致重复处理 | `ReplyStateStore` 持久化 `id`；状态文件损坏按空集合启动 |
| 历史只在内存，重启丢失 | 明确非目标；报告与告警只依赖当前进程生命周期 |
| 多节点串行拉取导致 tick 漂移 | 每节点并发 `spawn` + 超时；节点规模大时再引入线程池 |
| TUI 渲染阻塞拉取 | 读写锁粒度只覆盖快照引用；渲染异常捕获后继续 |

## Migration Plan

纯新增：不改既有模块 API 与行为。落地顺序建议：`f_probe` → `fprobe` 骨架/配置 → 采集与 RPC → supervisor 拉取/告警 → 渠道/报告 → TUI → LLM。回退只需从 `.modules` 移除两个模块并删除目录；配置项全部有默认值，不配置即回到旧行为（旧行为本来没有这两个模块）。

## Open Questions

1. `fprobe` 是否需要在 agent 侧也提供 `/metrics` HTTP 端点（Prometheus 抓取）？本期不做，RPC 已满足 supervisor。
2. 报告是否需要保留历史批次文件？本期发送后删除，避免磁盘增长。
3. 拓扑发现是否需要多 community / SNMPv3？本期只支持 v2c community。
