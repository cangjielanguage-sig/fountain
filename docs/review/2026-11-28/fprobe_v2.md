# fprobe 模块审查报告

- **审查日期**：2026-11-28
- **模块路径**：`fprobe`（167 个文件：142 个 .cj + 25 个 .md）
- **基线**：工作区快照（sts/1.3.x 工作区，master 同提交 120fd2542，无分支差异）
- **审查重点**：见 scope.md（正确性、死代码、重复逻辑、空实现、栈溢出、OOM、热点、并发与锁、存量 BUG、内存/CPU 优化空间、local mode 可行性、README 覆盖）
- **报告版本**：v1（由 9 个分部分报告合并：`parts/fprobe.part1..9.md`）

## 发现

<!-- 第 1 部分 -->

### [一般][存量] 4 个已文档化的配置键在生产代码中零读取（静默无效）

- **位置**：`fprobe/doc/configuration.md:66`（`probe_channel_email_receiveLimit`）、`:75`（`probe_reportChannels`）、`:76`（`probe_reportTmpDir`）、`:90`（`probe_llmMaxTokens`）；`fprobe.sh:153,169,180` 的注释已把 `probe_reportChannels` / `probe_channel_email_receiveLimit` / `probe_llmMaxTokens` 标为「文档保留项，当前版本未接线」，`:152` 把 `probe_reportTmpDir` 标为「已废弃：保留兼容，报告不再读取」——启动脚本比配置参考更诚实
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §13（配置/默认值与源码不符）、§14.1（承诺了但没实现 / 接线缺失）、§1（配置读了不用）
- **证据**：静态确定 —— 把本部分文档中出现的 55 个 `probe_*` 记号（含少量文档片段，如 `probe_channel_`）逐个在 `fprobe/src` 非测试源码中反查，以下配置键命中 0 处：
  - `probe_channel_email_receiveLimit`：`EmailAlarmChannel` 只有构造参数默认值 20（`src/channel/EmailAlarmChannel.cj:33-41`、`:66`），生产装配只传 `subjectPrefix` 与 `defaultReceivers`（`src/runtime/SupervisorRuntime.cj:527-528`），从不读该键；文档却写「由 `EmailAlarmChannel` 读取」。
  - `probe_reportChannels`：报告固定走「已启用的告警渠道」——`ChannelReportSender.sendRich` 直接 `dispatcher.dispatchRich`（`src/report/ReportJob.cj:34-44`），`buildReportJob` 只读 `probe_reportCron` / `probe_reportReceivers`（`src/runtime/SupervisorRuntime.cj:302-313`），没有任何按渠道名过滤的逻辑。
  - `probe_llmMaxTokens`：`buildAdvisor` 读取的 LLM 键只有 Agent/Name/Trigger/IntervalMs/ReplyPollMs/MuteSeconds/replyStateFile（`src/runtime/SupervisorRuntime.cj:348-357`）；README 自己已声明未接线（`README.md:412`），但配置参考未同步标注。
  - `probe_reportTmpDir`：已声明废弃（`configuration.md:76`、`README.md:314-315`），全库确实零读取——「保留兼容旧配置」实际只是「接受但忽略」，可接受，但与「兼容」措辞不符。
- **描述**：四处都是「文档说可调、代码不读」，不报错、不打日志。`receiveLimit` 还被写成「由实现读取」，属于对实现方式的事实性错误；`probe_llmMaxTokens` 让读者以为生成上限已受控。
- **建议**：`receiveLimit` 在 `buildEmailChannel` 传入 `Config.getValue<Int64>(...) ?? 20`；`probe_reportChannels` 要么接线（按名过滤 `enabled`），要么从配置参考删除并注明「报告复用 `probe_alarmChannels`」；`probe_llmMaxTokens` 与 `probe_reportTmpDir` 在该行显式标「未接线 / 不读取」。

### [一般][存量] 图表类型文档三重错位：键名、默认值表、作用面

- **位置**：`fprobe/doc/alarm-rules.md:62-74`（「`probe_chart_<kind>` 决定报告与 TUI 使用的图表类型」+ 默认类型表）、`fprobe/doc/configuration.md:72-79`、`fprobe/README.md:321-322`；示例键另见 `fprobe.sh:143-146`
- **来源**：存量
- **判据**：review-checklist §13（配置键/默认值与源码不符）
- **证据**：静态确定 ——
  1. **键名**：实现只认「完整指标 id」：`ChartSelector.configKey(metric) = "probe_chart_" + metric.replace(".", "_")`（`src/report/ChartSelector.cj:56-58`），报告遍历的 id 来自 `ProjectionCatalog`（如 `disk.mountMaxUsedPercent`，`src/tui/RenderPlan.cj:84-100`），对应键是 `probe_chart_disk_mountMaxUsedPercent`；文档/脚本里的 `probe_chart_disk`、`probe_chart_disk_usedPercent`、`probe_chart_network_rxBps` 都不是任何被选中的 metric id，配了也不会命中。
  2. **默认值表**：`ChartSelector.defaultType` 只匹配 `cpu.usagePercent` / `memory.usedPercent` / `disk.usedPercent` / `network.rxBps` / `service.latencyMs`（`src/report/ChartSelector.cj:61-69`）；除 `cpu.usagePercent` 外，其余 id 在报告实际遍历的 22 个指标里都不存在（`src/tui/RenderPlan.cj:70-112`），因此 `disk.usedPercent → bar` 永不命中，**报告里的磁盘图实际是 `line`**，文档承诺的 `bar` 不成立。
  3. **作用面**：`SUPPORTED_TYPES = ["line","area","bar"]`，没有 `topology`（`src/report/ChartSelector.cj:27`）；拓扑由图外路径 `TopologyRenderer` 单独渲染（`src/report/ReportBuilder.cj:144-169`）。TUI 图表类型由 `MetricPage.chartType()` 固定（`src/tui/ViewModel.cj:55-62`），proposal 也写明「不开放 `probe_chart_*` 到 TUI」（`doc/spec/add-fprobe-tui-charts/proposal.md:56`），所以「决定报告与 TUI」也不成立。
- **描述**：按文档配置图表类型属于「静默无效」：键名对不上时报文不提示，默认值表又把 4/5 条分支写成永不命中的 id，读者无法通过文档得到柱状图。
- **建议**：以 `ChartSelector.configKey` / `ProjectionCatalog` 为唯一来源重写两张表：键写成 `probe_chart_<kind>_<metric>` 并给出真实 id；默认值按真实 id 列（`cpu.usagePercent=line`、`disk.mountMaxUsedPercent=bar`…）；删掉 `topology` 行；同步修正 `fprobe.sh` 的示例键。源码侧 `defaultType` 的失配分支交源码部分处理。

### [一般][存量] `alarm-rules.md` 的「缺数据」语义与实现不符（阈值只作用于节点不可达）

- **位置**：`fprobe/doc/alarm-rules.md:58`（「某监控项连续缺失达到 `probe_missingThreshold`，即使没有显式规则也会告警」）
- **来源**：存量
- **判据**：review-checklist §13（规格与实现漂移）、§11（语义与注释/文档不符）
- **证据**：静态确定 —— `probe_missingThreshold` 在告警侧唯一用途是「节点连续拉取失败」（`src/alarm/AlarmEngine.cj:98-111`，判断在 `:100`）；kind 缺失走 `MissingDataTracker.raise`，**首次缺失即返回 true 并发送**（`src/alarm/MissingDataTracker.cj:32-38`，调用点 `src/alarm/AlarmEngine.cj:118-135`），没有连续次数门槛。只有 `probe_expectKinds` 中的 kind 会走这条；未配置该列表时，只有「告警规则引用了不存在的 kind」才会产生缺失事件（`AlarmEngine.cj:164-173`）。
- **描述**：文档给出了不存在的去抖语义：运维会以为单帧缺失不告警（实际第一次就发），也会以为不配 `probe_expectKinds` 能自动发现缺失（实际不能）。README 的同类描述（`README.md:264-266`）是对的，两份文档互相矛盾。
- **建议**：改为「`probe_expectKinds` 中的 kind 缺失即告警（无去抖）；`probe_missingThreshold` 只用于节点连续拉取失败与不可达事件」，与 README 对齐；若确需去抖，应在 `MissingDataTracker` 增加计数（源码侧另立变更）。

### [一般][存量] fail-fast 与退出码契约只覆盖两个 Settings，规则 / CRON / 渠道 / LLM 键均绕过

- **位置**：`fprobe/README.md:35-36`（「启动期一次性读取并校验全部配置，非法值以退出码 2 终止，并一次打印所有问题」）、`:126-133`（退出码表，含「邮件渠道初始化异常 → 1」「配置校验失败 → 2」）、`:132`（「规则 JSON 非法、CRON 非法……不会只报第一条」）、`:269`；`fprobe/doc/configuration.md:6`；`fprobe/doc/alarm-rules.md:50-51`
- **来源**：存量
- **判据**：review-checklist §13（契约与实现不符）、§11（错误处理缺失 / 静默）
- **证据**：静态确定 ——
  - 聚合校验 + 退出 2 只发生在 `runAgent` / `runSupervisor` 对 `AgentSettings.validate()` / `SupervisorSettings.validate()` 的调用（`src/main.cj:103-111`、`:125-133`）；这两个类只校验端口、hostId、间隔、节点格式等数值/格式项，`src/config/` 中没有任何 `probe_alarmRules` / `probe_reportCron` / `probe_alarmChannels` / `probe_llm*` 的读取。
  - `probe_alarmRules` 在 `SupervisorRuntime` 构造期解析，遇到第一条非法规则就 `throw`（`src/runtime/SupervisorRuntime.cj:134` → `src/alarm/AlarmRule.cj:107-143`）；`probe_reportCron` 在 `ReportJob.register()` 编译 CRON 时抛（`src/runtime/SupervisorRuntime.cj:167-172` → `src/report/ReportJob.cj:84-99`）；两者都被 `runSupervisor` 的 catch 收敛为**返回 1、只打印第一条**（`src/main.cj:134-142`）。
  - 未知 `probe_alarmChannels` 由 `ChannelDispatcher` 构造期抛 `CONFIG`（`src/channel/ChannelDispatcher.cj:39-43`），同样走退出 1。
  - `probe_llmTrigger` 非法值被 `LlmTrigger.parse` 静默回退为 `alarm`（`src/llm/ProbeAdvisor.cj:35-40`）；`probe_alarmCooldownSeconds` 负数被夹成 0（`src/runtime/SupervisorRuntime.cj:446-455`）；`probe_chart_*` 未知类型只 WARN 回退（`src/report/ChartSelector.cj:48-52`）。
  - README 把「邮件渠道初始化异常」列为退出 1，但实现是 `catch` 后打日志并返回 `None`，进程继续运行（`src/runtime/SupervisorRuntime.cj:515-535`）。
- **描述**：systemd / 运维脚本按退出码 2 判「配置错误」会失效；「一次打印所有问题」对规则、CRON、渠道、LLM 键都不成立；部分非法值完全静默。这不是措辞问题，是对外契约级不一致。
- **建议**：把规则 JSON、CRON、渠道名、`probe_llmTrigger` / `probe_llmIntervalMs` 等纳入启动期聚合校验（`SupervisorSettings`），失败统一退出 2；或按现状改文档——明确「仅 agent/supervisor 基础数值项聚合校验并退出 2，规则/CRON/渠道非法退出 1 且只报第一条」，并删除「邮件渠道初始化异常」这个例子。

### [一般][存量] `probe_alarmCooldownSeconds` 承诺的冷却窗口恒不生效（死配置 + 恒不成立分支）

- **位置**：`fprobe/README.md:23-24`、`:261`、`fprobe/doc/alarm-rules.md:56`、`fprobe/doc/configuration.md:44`；实现 `src/alarm/AlarmEngine.cj:229-249`、`:262-267`
- **来源**：存量
- **判据**：review-checklist §1（读了不用的配置 / 恒不成立分支）、§13（文档承诺的行为不存在）、§11
- **证据**：静态确定 —— 发送分支要求 `!state.firing`（`:229`）；发送后 `firing = true`，条件仍成立时不再进入该分支；条件一旦不成立，**无条件**执行 `firing = false; since = None; lastSentAt = None`（`:239-243`）。因此进入 `cooldownElapsed` 时 `lastSentAt` 必为 `None`，`cooldownMs` 永远返回 true。全仓没有第二个写 `lastSentAt` 的地方。AlarmEngine 用例只断言「持续命中不重复发送」与「恢复后立即再发」（`src/alarm/AlarmEngine_test.cj:126-151`），没有覆盖「冷却窗口内的第二次触发」。
- **描述**：真实语义是「每次 firing 只发一次，恢复后立刻可再发」；冷却窗口靠 `firing` 标志而不是时间窗。把 `probe_alarmCooldownSeconds` 调到 3600 不会有任何变化，短抖动反复恢复/命中也不会被合并。文档与配置参考都在承诺一个不存在的抑制能力。
- **建议**：二选一并写清文档 ——（a）承认现状：删除 `cooldownMs` / `lastSentAt` / `probe_alarmCooldownSeconds`，文档改为「每次 firing 只通知一次」；（b）真正去抖：恢复分支保留 `lastSentAt`，命中分支按 `now - lastSentAt >= cooldownMs` 抑制并补用例。

### [一般][存量] 「探针报错告警」只覆盖 `ProbeAgentData.error`，硬件 / 拓扑的内部 error 不会告警

- **位置**：`fprobe/README.md:266`（「探针报错：任何监控项带非空 `error` 时告警（硬件工具缺失也会走这条）」）、`:144`（hardware 的 `ipmi[]`/`snmp[]`/`smart[]` 每项含 `available` 与 `error`）、`:510`（故障排查「`hardware` 项 `available=false`」）；`README_en.md:280-281`、`:151`、`:545`
- **来源**：存量
- **判据**：review-checklist §13（描述与实现不符）、§14.1（承诺的告警路径缺失）
- **证据**：静态确定 —— `PROBE_ERROR` 只遍历 `snapshot.agents` 并检查 **agent 级** `agent.error`（`src/alarm/AlarmEngine.cj:137-148`）；而该字段只在 `slot.agent.data` 抛异常时被赋值（`src/collect/ProbeRunner.cj:79-96`）。硬件探针不抛异常：`HardwareProbe.data` 只把三个子采集器的结果拼成 JSON（`src/collect/hw/HardwareProbe.cj:60-66`），工具缺失被 `IpmiProbe` 降级为 `available=false` + `error` 的**读数字段**（`src/collect/hw/IpmiProbe.cj:70-85`）；拓扑未配置时把 `error` 写在 `TopologySample` 里返回（`src/collect/topology/TopologyProbe.cj:109-110`）。两者都不会让 agent 级 `error` 非空。
- **描述**：README 把「监控项 JSON 内的 error」与「`ProbeAgentData.error`」混为一谈。实际后果：ipmitool / smartctl 缺失、SNMP 不可达、拓扑跳过都不会产生告警，只体现在数据里；而 `hardware` 也没有顶层 `available` 字段，故障排查表里的「`hardware` 项 `available=false`」在 TUI/告警层不可观测。
- **建议**：文档改为「`ProbeAgentData.error` 非空时告警；hardware/topology 的内部 error 只是数据字段，不触发告警」；若希望硬件降级也告警，需在 `AlarmEngine` 里解析这两类 JSON 的内部 `error`（源码侧变更），并同步故障排查表为「hardware 的 `ipmi[]`/`smart[]` 条目 `available=false`」。

### [一般][存量] 配置参考声称 SMTP 密码由 f_config 的 SM4 处理，fprobe 实际按明文读取

- **位置**：`fprobe/doc/configuration.md:94-97`（「`probe_channel_email_smtpPassword` 等敏感项由 `f_config` 的 SM4 机制处理；未指定 `sm4Key` 等参数时，密文在编译期嵌入产物，运行期不落盘」）
- **来源**：存量
- **判据**：review-checklist §13（描述与实现不符）、§10（安全性：敏感数据/凭据）
- **证据**：静态确定 ——
  1. fprobe 全库没有 `@EmbedSensitive`，也没有 `Config.registerSensitive` 调用（`grep -rn "EmbedSensitive|registerSensitive" fprobe/src` 零命中）；`FEmailTransport.fromConfig` 直接用 `Config.getString("probe_channel_email_smtpPassword")`（`src/channel/FEmailTransport.cj:61-67`）。
  2. `Config.getString` 先读 `ARGS`（环境变量 + 命令行），只有键不在 `ARGS` 时才查 `sensitiveMap`（`f_config/src/Config.cj:186-198`）；因此密码来自命令行/环境变量时是**明文**，SM4 分支根本不参与。
  3. 即使使用 `@EmbedSensitive`，未配 `sm4Key` 时嵌入的是 `v.toArray()`（UTF-8 明文），不是密文——只有 `Config.getSM4()` 存在时才 `encrypt`（`f_config/src/macros/EmbedSensitive.cj:26-38`）。
- **描述**：这是一条安全预期错误：读者会以为 SMTP 密码在产物里是密文、运行期不以明文出现；实际 `--probe_channel_email_smtpPassword=...` 会以明文出现在 `ps`（命令行）或 `/proc/<pid>/environ`（环境变量）中（README 自己在 LLM KEY 处提示了 `ps` 风险，邮件配置却给了相反暗示）。
- **建议**：该段改为「fprobe 不注册敏感项，SMTP 密码按普通配置从命令行/环境变量明文读取；如需避免出现在 `ps`，用环境变量或后续接入 `@EmbedSensitive`」；若决定接入 SM4，需在装配处使用该宏并说明「未配 `sm4Key` 时只是明文嵌入」。

### [一般][存量] `doc/rpc.md` 的最小客户端示例缺必填参数，照抄编译失败

- **位置**：`fprobe/doc/rpc.md:47-68`，关键行 `:53-55`（`Client<RPCMessage>.builder(address: ..., checkDuration: ...).build()`）
- **来源**：存量
- **判据**：review-checklist §13（示例代码不能用）
- **证据**：静态确定 —— `f_net` 的 `Client.builder` 三个重载都把 `checker!: () -> ?Message` 声明为必填命名参数、无默认值（`f_net/src/client/Client.cj:278-306`）；本模块生产实现也带 `checker: {=> Some(Message.ping())}`（`src/rpc/NodeRpcTransport.cj:178-183`）。示例缺 `checker`，无法编译。
- **描述**：`rpc.md` 开篇声明这份示例用于「非本仓客户端复现」，是隐式对外契约的一部分；示例编译不过会让第三方卡在第一步。另外示例用 `convert<ProbeSnapshot>(response.data)` 的写法与实现一致，这点没问题。
- **建议**：补 `checker: {=> Some(Message.ping())}`，并注明必须周期性发 ping 维持连接（`f_net` 注释原话「务必使用 … 传检查包」）。

### [一般][存量] README 声称自定义监控项可用于 TUI，TUI 实际是固定 8 页

- **位置**：`fprobe/README.md:442-443`（「自定义监控项会出现在快照里，TUI 与告警规则按 `kind` 使用」）；`README_en.md:473-474`
- **来源**：存量
- **判据**：review-checklist §14.1（承诺了但没实现 / 只做了一半）、§13
- **证据**：静态确定 —— TUI 页面是编译期固定枚举（`src/tui/ViewModel.cj:24-33`：CPU/MEMORY/DISK/NETWORK/SERVICE/HEALTH/TOPOLOGY/ALARMS），指标投影目录按页硬编码（`src/tui/RenderPlan.cj:67-116` 的 `ProjectionCatalog.specs(page)`），没有「按快照 kind 动态建页」的入口；`RenderPlanBuilder` 只按 `page.kind()` 取固定 kind（`:216-226`）。自定义 kind 只能被规则引用、出现在快照 JSON 里，TUI 与报告都不会展示。
- **描述**：扩展作者按 README 会以为注册一个 `ProbeAgent` 就能在控制台看到指标；实际必须改 `MetricPage` 与 `ProjectionCatalog` 才能展示。这是对扩展能力的过度承诺（告警规则部分是真的）。
- **建议**：改为「自定义监控项会出现在快照与 RPC 结果中，可用于告警规则；TUI/报告只展示内置指标，需要在宿主侧扩展 `MetricPage` 与 `ProjectionCatalog`」；若确实要动态页，另立变更设计。

### [轻微][存量] 文档称告警 `level` 写进邮件标题，实际只进正文

- **位置**：`fprobe/README.md:253`（字段表「`level`：告警级别，写入消息与邮件标题」）、`fprobe/doc/alarm-rules.md:47`；`README_en.md:262`
- **来源**：存量
- **判据**：review-checklist §13（描述与实现不符）
- **证据**：静态确定 —— `AlarmEvent.format()` 把 `级别: <level>` 写成正文的一行（`src/alarm/AlarmEvent.cj:96-98`）；邮件标题由 `EmailAlarmChannel.subjectOf` 取「首个非空行 + `节点:` 行」拼前缀（`src/channel/EmailAlarmChannel.cj:84-111`），全函数不引用 `level`。
- **描述**：想在邮箱列表按级别过滤/排序的运维拿不到该信息。
- **建议**：要么把 `level` 拼进 `subjectOf`，要么把两处文档改为「写入消息正文」。

### [轻微][存量] `rpc.md` 的线协议块 `weight` 与示例、实现不一致

- **位置**：`fprobe/doc/rpc.md:31-39`（`weight: 1.0`）对照同文件 `:56-57`（`0.0`）与 `src/rpc/NodeRpcTransport.cj:141`（`0.0`）
- **来源**：存量
- **判据**：review-checklist §13
- **证据**：静态确定 —— 实现构造 `ServiceMeta("*", "", SERVICE_TYPE, method, [], 0.0, exactlyVersion: true)`。
- **描述**：同一份文档两处取值不同。定向调用不参与全局负载均衡，`1.0` 一般也能命中，但契约描述自相矛盾。
- **建议**：统一为 `0.0`，并补一句「定向调用不参与全局负载均衡，`weight` 仅占位」。

### [轻微][存量] README / README_en 的「其他公开 API」附录字面量被清空、签名被截断

- **位置**：`fprobe/README.md:525`（`diskExcludeFs: Array<String> = [       ,           ,          ,           ]`）、`:535`（`SUPPORTED_TYPES = [      ,       ,      ]`）、`:581`（`PromptBuilder.build(... Array<AlarmEvent>` 括号未闭合）、`:567`（`NodeRpcTransport.SERVICE_TYPE =` 无值）；`fprobe/README_en.md:560`、`:570`、`:616`
- **来源**：存量
- **判据**：review-checklist §13（文档错误 / 关键信息缺失）
- **证据**：静态确定 —— 用 `sed -n '<n>p'` 直接读原文确认这些位置是**真的空格**（非终端截断）；真实默认值分别是 `["tmpfs","devtmpfs","overlay","squashfs"]`（`src/config/AgentSettings.cj:39`）与 `["line","area","bar"]`（`src/report/ChartSelector.cj:27`）。另外附录只列了 `ProbeSnapshot.agents`，遗漏了 `@DataAssist[props]` 生成的 `node` / `host` / `timestamp`（`src/snapshot/ProbeSnapshot.cj:51-61`），而 `rpc.md:63` 的示例正用到 `snapshot.node`。
- **描述**：这份附录是「未在上文展开的公开 API」的唯一索引；字面量丢失后既不可读也不可复制，缺属性会让读者以为示例引用了不存在的字段。中英两版在同一位置同样丢失，说明是生成器问题而非翻译不同步。
- **建议**：修正生成脚本的字符串字面量处理与签名截断，补齐生成属性（`node`/`host`/`timestamp` 等）。

### [轻微][存量] `add-fprobe-tui-charts` 设计/提案里的 `ChartPanel` 与 `chartRender` 签名与实现不一致

- **位置**：`fprobe/doc/spec/add-fprobe-tui-charts/design.md:60-62`（`render(series: Array<SparkSeries>, width, height, chartType)`）、`:156-159`（`chartRender!: (Array<SparkSeries>, Int64, Int64, String) -> ?Array<Array<String>>`）、`proposal.md:21`
- **来源**：存量
- **判据**：review-checklist §13（规格与实现漂移）
- **证据**：静态确定 —— 实现是 `ChartPanel.render(chartType: String, seriesName: String, values: Array<Float64>, width: Int64, height: Int64)`（`src/tui/ChartPanel.cj:77-78`），注入点同理为 `(String, String, Array<Float64>, Int64, Int64)`（`src/tui/FprobePainter.cj:104-108`、调用点 `:234`）。这不是「参数顺序不同」，而是「传序列对象 vs 传 name+values」的形态差异。
- **描述**：该变更的 tasks 全部已勾选、验收以 design 为口径；设计文档与实际接口不符会让后续维护者按错误签名改代码。其余契约（`TuiCellChart`、20×8、`TuiLayout` 的 5 行 chrome、`RenderPlan` 三字段、`Painter.viewportHeight`）已与实现核对一致。
- **建议**：把 design/proposal 的签名改成实现的 `(chartType, seriesName, values, width, height)`，或把实现改回「接收 `SparkSeries`」；二者择一，保持单一来源。

### [轻微][存量] `deployment.md` 多写了一条不存在的配置来源（`f_config` 嵌入配置）

- **位置**：`fprobe/doc/deployment.md:103-106`（「所有 `probe_*` 都可以通过命令行、环境变量或 `f_config` 的嵌入配置提供」）
- **来源**：存量
- **判据**：review-checklist §13
- **证据**：静态确定（本仓版本）—— `Config` 的静态初始化只装载环境变量与命令行参数（`f_config/src/Config.cj:62-98`），没有读取嵌入配置文件的分支；README 也明确「配置只来自两个地方」（`README.md:157`）。`f_config` 的「嵌入」只涉及**敏感值**的密文/明文嵌入（`Config.cj:37-44`），不是任意键的来源。
- **描述**：两处文档对配置来源表述相反，deployment 版多给的这条路不存在，会误导部署人员去找配置文件。
- **建议**：删除「或 `f_config` 的嵌入配置」，与 README 统一为「命令行 > 环境变量」；敏感项说明单列一段（并修正上一条 SM4 描述）。

<!-- 第 2 部分 -->

### [严重][存量] `AlarmEngine.mute` 在 LLM 回复线程写 `mutedUntil`，`evaluate` 在拉取线程读同一 `HashMap`，无任何同步

- **位置**：`fprobe/src/alarm/AlarmEngine.cj:46`（`private let mutedUntil = HashMap<String, Int64>()`）、`:62-70`（`mute` 做 `get` + `add` 写）、`:269-274`（`isMuted` 做 `get` 读）、`:230` / `:244`（`evaluate` 调用 `isMuted`）
- **来源**：存量（`git blame` → `f84982d31` "feat(fprobe): add alarm engine and email alarm channel"）
- **判据**：review-checklist §12.1（共享可变状态无保护）、§6.2（跨线程写同一容器）
- **证据**：静态确定 —— 两条线程路径都已定位到具体行：
  - 拉取线程：`fprobe/src/runtime/SupervisorRuntime.cj:196` `spawn {=> poll.run()}` → `:158` `alarm.evaluate(states)` → `AlarmEngine.cj:269` `mutedUntil.get(rule)`；
  - LLM/回复线程：`SupervisorRuntime.cj:203` `spawn {=> llmLoop(...)}` → `:240` `replies.pollOnce()` → `ActionWhitelist.cj:85` `mute(rule, nowMs() + muteSeconds*1000)` → `SupervisorRuntime.cj:361` 绑定的 `alarm.mute(...)` → `AlarmEngine.cj:63/68` 对同一 `mutedUntil` 做 `get`+`add`；
  - 文档判据：`std/collection/collection_package_overview.md:27` —— "collection 包提供的集合类型都不支持并发安全"。
- **描述**：`mute` 由运维回复（`同意 mute cpu-high`）触发，`evaluate` 按 `probe_pollIntervalMs`（默认 5 秒）执行；两者对同一个 `HashMap` 并发读/写，没有任何 `Mutex`、不可变快照或消息传递。标准库明确声明该容器不支持并发安全，因此这里的正确性没有依据可循：轻则 `mute` 丢失（运维以为已静音却继续告警）、`isMuted` 读到脏值，重则在表扩容与读取交错时读到不一致结构。该竞态不在 CPU profile 里可见，也不是"理论上可能"——两条路径都是生产默认装配下的常驻线程。
- **建议**：只保护这一个不变量，任选其一：(a) 给 `mutedUntil` 配一把 `Mutex`，`mute`/`isMuted` 全部进出锁（临界区只有一次 map 操作）；(b) 改成不可变快照 + 原子替换（`mute` 复制 map 后 `AtomicReference` 交换，`isMuted` 只读快照）；(c) `ConcurrentHashMap`。修完补一条"回复线程 mute 与 evaluate 并发跑 1000 轮，断言静音生效"的压力用例。

### [一般][存量] 规则引用的 `kind` 缺失时，`MissingDataTracker` 每 tick 交替产生「已恢复」+「缺监控项」，去重完全失效

- **位置**：`fprobe/src/alarm/AlarmEngine.cj:83-89`（`collectRecovered` 在规则评估**之前**执行）、`:91-95`（随后才跑 `evaluateRules`）、`:166-173`（`case None` 才把 `${node}|kind|${kind}` 写入 `currentMissing`）
- **来源**：存量（`git blame` 同上）
- **判据**：review-checklist §11（语义与契约不符）、§12.1（状态机跨 tick 不变量）；spec `fprobe/doc/spec/add-fprobe/specs/probe-supervisor/spec.md:96-113`（同类缺失只应告警一次）
- **证据**：静态确定 —— 推演两个 tick：
  - Tick N：`evaluateMissing`（`:98-149`）只登记 `expectKinds`、`agent.error`、节点离线三类键，不含"规则引用的 kind"；`collectRecovered` 无键可收；`evaluateRules` 的 `case None`（`:165-173`）写入键并 `raise` → 首发 `KIND_MISSING`，键进入 `active`。
  - Tick N+1：`collectRecovered`（`:83`）拿到的 `currentMissing` 仍不含该键（`probe_expectKinds` 为空或不含该 kind），而节点在 `batchNodes` 中 → 判为"已恢复"，发 `RECOVERY` 并 `active.remove`；紧接着 `evaluateRules` 再次 `raise` → 再发 `KIND_MISSING`。
- **描述**：触发条件是"规则里的 `kind` 在快照中不存在"（例如规则写了 `kind=rpc-health` 但该探针未启用，或扩展探针加载失败）。此后每个 tick 都发一条"已恢复"和一条"缺少监控项"，5 秒一封告警邮件，且恢复通知是假的。现有用例无法发现：`AlarmEngine_test.cj:221-233` 只测了 `probe_expectKinds` 路径，没有"规则 kind 缺失连续两 tick"的用例。
- **建议**：把 `collectRecovered` 移到规则评估之后（两阶段都填完 `currentMissing` 再统一结算），或在 `evaluateMissing` 里先把 `rules` 引用的 `kind` 也登记进 `currentMissing`；两条路径共用同一个 `key` 生成函数，避免再漂移。补用例：规则 kind 缺失连续 3 个 tick，断言事件数 == 1。

### [一般][存量] `probe_alarmCooldownSeconds` / `lastSentAt` / `cooldownElapsed` 实际恒真，冷却窗口从未生效

- **位置**：`fprobe/src/alarm/AlarmEngine.cj:262-267`（`cooldownElapsed`）、`:230`（唯一调用点）、`:243`（恢复分支把 `lastSentAt` 清成 `None`）、`:231-232`（只在已发告警时写 `lastSentAt`）
- **来源**：存量
- **判据**：review-checklist §1（读了不用的配置 / 恒真分支）、§11（配置与行为不符）；spec `probe-supervisor/spec.md:82-94`（冷却 300 秒内同一节点同一规则只发一次）与 `SupervisorRuntime.cj:446-455`（默认 300）
- **证据**：静态确定 —— 不变量推导：`lastSentAt` 只在 `state.firing = true` 的同一分支被赋值（`:231-232`），而唯一的清零点是 `else` 分支（`:241-243`，同时 `firing = false`）；因此"`lastSentAt` 有值 ⇒ `firing == true`"恒成立。调用点 `:230` 的前置条件正是 `!state.firing`，代入即 `lastSentAt == None`，`cooldownElapsed` 必然返回 `true`。
- **描述**：去重实际由 `firing` 闩锁完成（条件持续期间不再发），冷却参数没有任何影响。于是"恢复→再命中"的抖动场景（`firing` 被清、`lastSentAt` 被清）会在每个 tick 重新发告警，即使 `probe_alarmCooldownSeconds=300`。配置项与文档都在承诺一个不存在的抑制窗口，运维按文档调大冷却也不会有任何变化。
- **建议**：恢复分支保留 `lastSentAt`（只清 `firing`/`since`），发告警前用 `now - lastSentAt >= cooldownMs` 判定；若确认要"恢复后立即视为新告警"，就删掉 `cooldownMs`/`lastSentAt`/`cooldownElapsed` 与文档里的冷却承诺，二者取一。加用例：冷却 300s 内"命中→恢复→再命中"，断言只发 1 条 FIRING。

### [一般][存量] 规则的 `path` 启动期不校验，运行期 `DataPath.solid` 抛异常被吞 → 规则永久静默失效

- **位置**：`fprobe/src/alarm/AlarmRule.cj:167-169`（`validate` 只判 `path` 非空）、`fprobe/src/alarm/AlarmEngine.cj:192-210`（`DataPath.solid(rule.path)` 与取值整体包在 `try` 内，`catch (_: Exception) → None`）
- **来源**：存量
- **判据**：review-checklist §11（错误处理静默）、§14.1（半成品：校验只做了一半）；spec `probe-supervisor/spec.md:77-80`（非法规则 MUST 启动失败并指出第几条）
- **证据**：静态确定 —— `f_data/src/path/DataPath.cj:70-81`：`solid()` → `doCompile()`，路径不以 `$`/`@` 开头直接 `throw DataException(...)`；`AlarmEngine` 的 `catch (_: Exception)` 把这个异常变成 `None`，随后 `:176-179` 的 `case None => ()` 什么也不做，连 WARN 都没有。
- **描述**：`probe_alarmRules` 里写 `"path":"usagePercent"`（漏 `$.`）或 `"$.a[0"`（括号不配对）都能通过启动校验；运行期每次评估都抛异常、被吞掉，规则永远不触发，日志里没有任何痕迹。对监控系统来说这等价于"规则悄悄消失"，且比启动失败更难发现。
- **建议**：`AlarmRule.validate` 里执行一次 `DataPath.solid(rule.path)`（或调用 `DataPath.cache` 预编译并缓存到规则对象），异常转成 `invalid(position, "path 无法解析: ...")`；`AlarmEngine.valueOf` 的 `catch` 至少记一条带规则名的 WARN（配合下面的 CPU 方案，预编译后该异常分支可直接删除）。

### [一般][存量] `AlarmEngine.emit` 把 `onEvent` 的所有异常（含 `Error`）静默吞掉，告警丢失无痕迹

- **位置**：`fprobe/src/alarm/AlarmEngine.cj:276-284`
- **来源**：存量（同日 `docs/review/2026-11-28/fprobe.md` 已按抽样口径报过同一处，此处补全完整证据；两条请合并为一条）
- **判据**：review-checklist §3（`catch (_: Exception) {}` 静默吞异常）、§11（失败当成功）
- **证据**：静态确定 —— 4 行空 catch，连 `Error` 一起吞；`emit` 是 `FIRING`/`RECOVERY`/`KIND_MISSING`/`PROBE_ERROR`/`NODE_UNREACHABLE` 全部事件的唯一出口（`:85/106/131/144/171/233/245`）。
- **描述**：`onEvent`（`SupervisorRuntime.cj:135-148`）里做事件入队、`dispatcher.dispatch`（含 SMTP 发送、日志）和 `spawn` 分析；其中任何一步抛异常，事件既没发出去、也没进队列，引擎继续跑，运维只能看到"没有告警"。`catch (_: Error)` 更糟：`OutOfMemoryError` 一类错误也被吞掉，进程带着坏状态继续。
- **建议**：`emit` 只包 `Exception`；`Error` 分支先 `eprintln` 一行带 `eventType`/`node`/`rule` 的记录再重新抛出（或至少不要静默继续）。再加一个"告警投递失败计数"供 TUI/report 展示。若吞异常是为了"单条事件不影响后续规则"，把 try 放进循环体并保留日志即可。

### [轻微][存量] `AlarmRule.parse` 的 `DataObject.populate` 会抛 `DataException`，绕过 `invalid(position, …)`，启动错误丢失"第 N 条"与 CONFIG 码

- **位置**：`fprobe/src/alarm/AlarmRule.cj:135-138`
- **来源**：存量
- **判据**：review-checklist §11（错误路径与契约不符）；spec `probe-supervisor/spec.md:77-80`（必须指出第几条）
- **证据**：静态确定 —— `f_data/src/base/DataObject.cj:119-130` 的 `set` 在字段不可转换时 `throw DataException("source field … connot be converted")`，`populate`（`:194-206`）不捕获；`AlarmRule.parse` 只在 `fromStr`（`:109-113`）与"非数组/非对象/缺字段"（`:115-138`）路径上转成 `ProbeException(CONFIG)`。
- **描述**：`"threshold":"high"` 或 `"forSeconds":{}` 这类类型错配会让 `load()` 抛出裸 `DataException`，最终由 `main.cj:136-141` 打成 `fprobe supervisor: 启动失败: source field threshold …`——不带规则序号、不带 `CONFIG` 错误码，与同文件其它校验的错误形态不一致。
- **建议**：把 `populate` 包进 `try`，`catch (e: Exception) => throw invalid(position, e.message)`，保持单一错误契约。

### [轻微][存量] 两个 public 成员仓内零引用，且恢复判定靠文案而非 `isRecovery()`

- **位置**：`fprobe/src/alarm/AlarmEvent.cj:75-77`（`isRecovery()`）、`fprobe/src/alarm/AlarmRule.cj:63-72`（`AlarmOp.toString()`）
- **来源**：存量
- **判据**：review-checklist §1（可见性建议，非死代码——两者都是公共顶层类型的 `public` 成员，但 `fprobe` 的 `cjpm.toml:36` 是 `output-type = "executable"`，不存在下游链接方）、§2（同一语义两处实现）
- **证据**：静态确定 —— 全仓（排除 `.worktrees/`、`target/`）`grep -rn "isRecovery|AlarmOp.*toString"` 只命中定义处；而 `EmailAlarmChannel.cj:130` 判恢复事件用的是 `title.startsWith("【已恢复】")`，即 `AlarmEvent.title()`（`:65-73`）的文案被当成协议。
- **描述**：`isRecovery()` 写好了却没人用，渠道改用字符串前缀判断横幅颜色；一旦标题文案（`【已恢复】`）调整，恢复邮件会变红色横幅，且编译器不会提示。`AlarmOp.toString()` 也无人调用（`AlarmRule` 只做 `parse`）。
- **建议**：`EmailAlarmChannel` 改为 `event.isRecovery` 语义（或让 `AlarmEvent` 自带 `bannerColor()`），删掉 `AlarmOp.toString()` 或补一条 round-trip 用例给它存在理由。因为模块是 executable，删除不涉及对外契约。

### [轻微][存量] `ChannelDispatcher` 用 `HashMap.add` 静默覆盖同名渠道，`enabled` 也不去重

- **位置**：`fprobe/src/channel/ChannelDispatcher.cj:36-38`（构造时 `this.channels.add(name, channel)`，返回值丢弃）、`:39-44`（`enabled` 原样保存）、`:50-58`/`:61-77`（按 `enabled` 逐个发）
- **来源**：存量
- **判据**：`fountain-baseline.md` §4（同名注册必须启动直接失败，不做隐式优先级）、review-checklist §11（静默覆盖）
- **证据**：静态确定 —— `HashMap.add` 语义为"已存在的键替换值并返回旧值"（`std/collection/collection_package_api/collection_package_class.md:4866`），代码丢弃返回值；`enabled` 未做 `HashSet` 去重。
- **描述**：两处后果：(a) 构造入参里出现同名渠道时后者静默替换前者（当前生产装配只放 `email`，属潜在路径）；(b) `probe_alarmChannels=email,email` 会把同一条告警发两遍、日志也打两遍（`SupervisorRuntime.buildChannels` 不去重）。
- **建议**：`add` 的返回值 `case Some(_) => throw ProbeException(CONFIG, "告警渠道重复: name")`；`enabled` 用 `HashSet` 过滤。两条都用现有 `ChannelDispatcher_test` 的表驱动风格补用例。

### [轻微][存量] 缺失键登记模板复制 4 份，`dispatch`/`dispatchRich` 与 `format`/`renderHtml` 各有一对同语义实现

- **位置**：`fprobe/src/alarm/AlarmEngine.cj:99-147`（`evaluateMissing` 里节点/缺 kind/采集错误三段形状一致）、`:164-173`（第四份）、`fprobe/src/channel/ChannelDispatcher.cj:50-58` vs `:61-77`、`fprobe/src/alarm/AlarmEvent.cj:80-101` vs `fprobe/src/channel/EmailAlarmChannel.cj:119-146`
- **来源**：存量
- **判据**：review-checklist §2（表现形式不同的重复逻辑：字面量复制 / 换控制流）
- **证据**：静态确定 —— 四处均为 `current.add(key)` + 构造 `AlarmEvent` + `if (missing.raise(key, event)) { emit(event) }`；`dispatchRich` 的 `for + match + try/catch` 与 `dispatch` 仅差调用哪个方法（`sendOne` 只覆盖了纯文本分支）；`AlarmEvent.format` 枚举"节点/规则/监控项/当前值/阈值/级别/时间"，`EmailAlarmChannel.renderHtml` 又按 `:` 拆分同一份文本重建这份字段表。
- **描述**：缺失键登记这一段重复是上面"kind 缺失抖动"的直接成因——同一个键空间在 `evaluateMissing` 与 `evaluateRules` 里各写一遍，登记时机却不同；`format`/`renderHtml` 的字段表重复则让"给 `AlarmEvent` 加字段"必须同时改两处，而且 HTML 表格是通过解析自己生成的文本得到的，`value` 里出现 `:` 就会被错误拆行。
- **建议**：抽 `private func raiseMissing(key: String, event: AlarmEvent, current: HashSet<String>)`（4 处归一）；`dispatchRich` 内联的 try/catch 与 `dispatch` 共用一个 `(AlarmMessageChannel) -> Unit` 包装；`EmailAlarmChannel` 改成接收结构化 `AlarmEvent` 生成表格（或让 `AlarmEvent` 提供 `fields(): Array<(String,String)>`，`format()` 与 HTML 共用同一份字段表）。

### [轻微][存量] 节点转 OFFLINE 的那一 tick，上一帧的 `PROBE_ERROR` / 缺项会各收到一条假「已恢复」

- **位置**：`fprobe/src/alarm/AlarmEngine.cj:98-111`（`OFFLINE` 早返回，不登记任何键）、`:113-116`（无快照直接 return）、`:83-89`（`collectRecovered` 随后把旧键判为恢复）
- **来源**：存量
- **判据**：review-checklist §11（语义与命名不符：条件并未恢复）
- **证据**：静态确定 —— 节点由 ONLINE 转 OFFLINE 时，`batchNodes` 仍含该节点，`currentMissing` 里没有任何 `node|kind|*` / `node|error|*` 键，于是 `MissingDataTracker.collectRecovered` 把它们全部当"已恢复"发出 `RECOVERY`。
- **描述**：一次断线会先收到若干条"监控项 X 已恢复"，紧接着才是"节点不可达"，顺序与语义都反了，收敛阶段还会多一轮邮件。只影响通知语义，不影响状态机主流程。
- **建议**：`OFFLINE` 分支先把上一帧属于该节点的键原样写入 `currentMissing`（保持"条件未恢复"），由"节点不可达"事件承担解释；或在 `collectRecovered` 里跳过非 `ONLINE` 节点的键。

### [轻微][存量] `AlarmEngine.cj` 导入的 `ArrayList` 未使用

- **位置**：`fprobe/src/alarm/AlarmEngine.cj:18`
- **来源**：存量
- **判据**：review-checklist §1（未使用的 import）
- **证据**：静态确定 —— 文件内 `grep ArrayList` 只命中第 18 行；实际只用 `HashMap`、`HashSet`、`Array`。
- **建议**：改为 `import std.collection.{HashMap, HashSet}`。

<!-- 第 3 部分 -->

### [严重][存量] 单个 `Email` 实例被 4 条线程并发 `send` / `list` / `body`，内部会话状态无任何同步

- **位置**：`fprobe/src/channel/FEmailTransport.cj:33`（`private let email: Email`）、`:89-110`（`email.send`）、`:112-127`（`email.list` + 每封 `email.body`）
- **来源**：存量（工作区快照，无 diff；`git blame` 落 `f84982d31` "feat(fprobe): add alarm engine and email alarm channel"）
- **判据**：review-checklist §12.1（共享可变状态无保护 / 跨线程共享资源）、§12.2（会话型资源必须串行化，不能靠"调用频率低"豁免）
- **证据**：静态确定 —— 共享路径与线程都可落到具体行：
  - 装配：`fprobe/src/runtime/SupervisorRuntime.cj:515-534`（构造点 `:527-528`）只构造**一个** `EmailAlarmChannel`，其内部是**一个** `FEmailTransport`；该实例同时进 `ChannelDispatcher`（`:124-126`）与 `ReplyMonitor`（`:375`）。
  - 线程 1（拉取）：`SupervisorRuntime.cj:196` `spawn {=> poll.run()}` → `:158` `alarm.evaluate` → `:142` `dispatcher.dispatch(event.format())` → `EmailAlarmChannel.send` → `transport.send`（`Email.send`，走 SMTP）。
  - 线程 2（LLM/回复）：`SupervisorRuntime.cj:203-204` `spawn {=> llmLoop(...)}` → `:240` `replies.pollOnce()` → `EmailAlarmChannel.receive` → `transport.list`（`Email.list`）→ `Email.body`（IMAP）。
  - 线程 3（告警触发后的异步分析）：`:145` `spawn {=> advisor.analyzeAlarm(...)}` → `:372` 的 `onAdvice` 回调 → `dispatcher.dispatch` → 又一次 `Email.send`。
  - 线程 4（报告）：`:167` 注册的 `ReportJob` → `report/ReportJob.cj:43` `dispatcher.dispatchRich` → 又一次 `Email.send`。
  - 被共享对象没有保护：`f_email/src/EmailFacade.cj:215-221` —— `smtpValue` / `imapValue` / `pop3Value` / `currentMailbox` / `selectedMailbox` / `closedFlag` 全是裸 `var`，`Email` 类没有任何 `Mutex`/`synchronized`；`list` 在 `:260` 写 `currentMailbox`，`fetch` 在 `:355` 再写一次。
- **描述**：两条以上线程可能同时对同一个 `Email` 发 SMTP 命令、或线程 1 发信时线程 2 正在 IMAP 取信。SMTP 会话是"连接上按序写 `MAIL FROM`/`RCPT TO`/`DATA`"的状态机，同一连接被两线程交错写就会串包（收件人错配、`DATA` 提前结束、会话被服务端判协议错）；懒连接字段 `smtpValue` 的检查-然后-写入也存在首连竞态（双连接、旧引用泄漏）。`currentMailbox` 的并发读写在多邮箱场景下会把正文取到错误邮箱。告警邮件发错人或丢信属于数据错误，且默认装配（`probe_channel_email_smtpHost` 配了）即命中。
- **建议**：在 `FEmailTransport` 内加一把 `Mutex`，`send` / `list` 整体进出锁（临界区是整次 SMTP/IMAP 往返，持锁时间长，但这是会话型资源的固有串行化）；或者在 `FEmailTransport` 之上做单写者队列（发信排队、取信单独一条会话）。注意 `EmailAlarmChannel` 目前是「无状态 + 共享 transport」，锁只能落在 transport。修完补并发用例：4 线程各跑 100 次 `send`/`list`，断言 `OutgoingMail.receivers` 不错配、`list` 不抛协议错。

### [严重][存量] `receive()` 永远返回同一封（最旧的）未读邮件，且从不标记已读 —— 第一封之后所有回复永久处理不到

- **位置**：`fprobe/src/channel/EmailAlarmChannel.cj:65-78`（`for (mail in transport.list(receiveLimit))` 里遇到第一封 `unread` 立即 `return`）
- **来源**：存量（工作区快照，无 diff；`git blame -L 65,78` → `f84982d31c` "feat(fprobe): add alarm engine and email alarm channel"）
- **判据**：review-checklist §11（逻辑错误 / 消息丢失）、§14.1（半成品：只支持"一封待处理"却没有任何推进机制）；`fountain-baseline.md` §5（先查 API 返回值语义再下结论）
- **证据**：静态确定 —— 四段事实串起来即可判定：
  1. `f_email` 的 `list` 返回的是「最近 limit 封」但**按序号升序**（旧→新）：`f_email/src/EmailFacade.cj:261-309` 用 `SequenceSet.range(total-limit+1, total)` 顺序 `out.add`；POP3 分支 `:316-341` 同样按 `infos` 升序。
  2. 取正文用 `BODY.PEEK[]`，不会点亮 `\Seen`：`f_email/src/imap/ImapFetch.cj:149-160`（`peek!: Bool = true`，注释明确"只读邮件不该因为取正文就把 `\Seen` 点亮"），`Email.body` → `fetch`（`EmailFacade.cj:367-373`、`:349`）。
  3. POP3 分支的 `flags` 恒为 `[]`（`EmailFacade.cj:339`），`isUnread()` = `!flags.contains("\\Seen")`（`:87-89`）⇒ POP3 下**所有**邮件永远"未读"。
  4. 消费方按 id 去重且只调一次：`fprobe/src/llm/ReplyMonitor.cj:56`（每个渠道只 `receive()` 一次）→ `:66-68` `store.isHandled(message.id)` 命中就 `continue`，不会向渠道要"下一封"。
- **描述**：`receive()` 取列表里**第一封未读**（即窗口内最旧的一封），而它永远不会变成已读，于是每个轮询周期都返回同一封：第一次被 `store.markHandled` 记账后，之后每轮都命中 `isHandled` 直接跳过，**其余任何未读邮件（包括新到的）都不会被返回**。POP3 配置下这是必然（flags 恒空）；IMAP 下只要运维没在邮件客户端里手动点开那封邮件，同样成立。后果是"回复指挥智能体"的能力在收到第一条回复后静默失效，且日志里只有"已处理/跳过"，看不出异常。现有用例掩盖了它：`EmailAlarmChannel_test.cj:132-162` 每次都构造全新的 `FakeMailTransport`，且只断言"能拿到消息"，没有"两封未读连续两轮"的场景。
- **建议**：把"推进游标"的责任放回渠道：(a) 让 `EmailAlarmChannel` 内部记 `已返回过的 id 集合`（有界，如最近 N 条）并在 `receive()` 里跳过，直到没有新未读；(b) 或给 `MailTransport` 增加 `markRead(id)`（`f_email` 已有 `STORE +FLAGS \Seen` 能力，见 `EmailFacade.cj` 的 remove/delete 同族实现），取到即回写；(c) 或把接口改成 `receiveAll(): Array<String>` 让调用方一次拿全。三种都要补"两封未读 + 连续两轮"的用例，POP3 与 IMAP 各一条。

### [一般][存量] `MailTransport.list` 契约写「最新在前」，实际实现是「窗口内最旧在前」

- **位置**：`fprobe/src/channel/MailTransport.cj:78`（接口注释：`最近 [limit] 封邮件，最新在前`）；`fprobe/src/channel/FEmailTransport.cj:112-127`（原样透传 `Email.list` 的顺序，未做反转）
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §11（契约与实现不符）、§2（同一语义的边界差异导致行为漂移）
- **证据**：静态确定 —— `f_email/src/EmailFacade.cj:261-309`（IMAP 升序）与 `:316-341`（POP3 升序）都返回旧→新；`FEmailTransport.list` 只做字段映射，没有 `reverse()`。`EmailAlarmChannel.receive`（`:66-77`）依赖这个顺序决定"先回哪一封"。
- **描述**：接口文档与实现方向相反，直接把上一条缺陷的"取最旧"行为伪装成"取最新"。任何按契约新写的 `MailTransport` 实现（例如测试替身或第二家邮件后端）会与 `f_email` 实现行为相反，`receive()` 的语义随之漂移；反之若按实现修文档，则 `receive()` 的"先回最新"预期落空。测试替身 `EmailAlarmChannel_test.cj:134-137` 恰好按"最新在前"摆数据，进一步掩盖了差异。
- **建议**：二者取一，并在接口注释里写死：(a) `FEmailTransport.list` 末尾 `reverse()`，兑现"最新在前"（当前 `receive()` 与测试都按这个假设写）；(b) 改接口契约与 `receive()` 的选择策略为"最旧优先"，同时修正测试替身的数据顺序。建议选 (a)，与 `receive()` 的既有预期一致，代价只是 20 条摘要的反转。

### [一般][存量] `HealthMetrics.tryParse` / `tryFrom` 接受任意 JSON 对象为"全 0 健康数据"，`MvcHealthProbe` 的错误分支基本不可达

- **位置**：`fprobe/src/collect/health/HealthMetrics.cj:59-78`（`tryParse` → `tryFrom` → `HealthMetrics.tryFromData(data)`）；`fprobe/src/collect/health/MvcHealthProbe.cj:63-67`（`case None => "响应不是合法 HealthData JSON"`）
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §11（与规格/注释冲突：注释承诺"响应非法都收敛为 error"）、§3（`case None` 兜底被上游语义掏空）
- **证据**：静态确定 —— `@DataAssist` 生成的 `tryFromData` 走 `f_data_tryFromData`（`f_data/src/macros/DataAssist.cj:631-636`）→ `DataObject.populate`（`f_data/src/base/DataObject.cj:194-206`）只**遍历源字段**赋值，从不校验"目标字段是否齐全"；默认 flag 是 `SILENCE` = `IGNORE_FIELD_NOT_FOUND | IGNORE_FIELD_TYPE_NOT_MATCH | IGNORE_FIELD_NOT_CONVERTABLE | IGNORE_NONE`（`f_data/src/base/global_objects.cj:42-51`）。因此 `{}`、`{"status":"UP"}`、`{"code":0,"data":{...}}` 一律返回 `Some(HealthMetrics())`（11 个字段全 0）。只有顶层不是 JSON 对象（数组/标量/非法文本）才走 `None`。
- **描述**：`MvcHealthProbe` 的文档与实现相反：`/health` 换了响应包装（网关统一包 `data`）、对端降级返回 `{"status":"UP"}`、或版本漂移改了字段名，探针都会报 `error=""` 且 `usedHeapSize=0`、`gcCount=0`，TUI/报告/告警看到的是"健康但全零"，而不是"响应非法"。`MvcHealthProbe_test.cj:80-85` 用 `"not-json"` 测非法响应，正好绕开了对象形态。
- **建议**：`tryFrom` 增加"至少命中一个已知字段"的校验（比较 `DataObject<HealthMetrics>` 的键集合与源键集合的交集；或先 `HealthMetrics.dataFields()` 求出字段名，逐个 `data.get(name).isSome()` 统计），命中 0 个就返回 `None`；需要严格时要求全部 11 个字段存在。补用例：`{}`、`{"status":"UP"}`、`{"data":{...}}` 都断言 `error` 含"不是合法 HealthData"。

### [一般][存量] `FHttpClientProbe.get` 无上限读入整个响应体，峰值内存由对端响应大小决定

- **位置**：`fprobe/src/collect/health/HttpProbe.cj:58-60`（`response.readEntire()`），随后 `body` 直接进 `HealthMetrics.tryParse`（`MvcHealthProbe.cj:63`）
- **来源**：存量（工作区快照，无 diff）
- **判据**：review-checklist §5（一次性物化、按不可信长度预分配、无拒绝路径）
- **证据**：静态确定 —— 代码中没有 `Content-Length` 检查、没有分段读、没有大小常量；`readTimeout` 只限制时间不限制字节数（`:56`）。更具体地，`f_httpclient/src/ExtendHttpResponse.cj:50-77` 的 `readToEnd()`：`bodySize`（即响应头 `Content-Length`）存在时直接 `Array<Byte>(size, repeat: 0)` 按声明长度一次性分配（`:52-55`），未知长度时用 `ArrayList` 无上限累积（`:69-76`）——两分支都没有上限。
- **描述**：量级可估：默认 `probe_httpTimeoutMs=2000`，千兆链路最坏 ≈ 250 MB/次，回环或 10G 环境更高；更糟的是"按声明长度预分配"——对端（或中间反代）只要回一个 `Content-Length: 4294967296` 的小响应头，就会先尝试 4 GB 分配。`JsonValue.fromStr` 再整份建树，峰值约为报文 2-3 倍。`probe_mvcHealthUrl` / `probe_serviceTargets` 指向的是"自己的服务"，但配置错指向大文件端点、或端点被反代成静态目录时就会直接放大到 OOM 风险；多个目标顺序执行时峰值不叠加，但单次足以触发容器 limit。
- **建议**：先按 `Content-Length` 拦一道（超过如 1 MB 直接返回 `error`），再改用 `f_httpclient` 的分段读取/带上限的读取接口；上限做成常量或 `probe_httpMaxBodyBytes`，超过时返回 `HttpProbeResult(..., error: "响应体超过 N 字节")`。同类透传点 `ServiceReachabilityProbe` 一并处理。

### [轻微][存量] 三处 `MonoTime` 耗时换算逐行相同，`RPC 调用失败` 文案也重复

- **位置**：`fprobe/src/collect/health/HttpProbe.cj:71-73`（`elapsedMs`）、`fprobe/src/collect/health/RpcHealthTransport.cj:103-105`（`elapsedMillis`）、`fprobe/src/collect/net/TcpProbe.cj:56-58`（`elapsedMillis`）；文案重复：`RpcHealthProbe.cj:108` 与 `RpcHealthTransport.cj:71` 的 `'RPC 调用失败: ${e.message}'`
- **来源**：存量
- **判据**：review-checklist §2（换算复制 / 字面量复制）
- **证据**：静态确定 —— 三个函数体都是 `Float64((MonoTime.now() - start).toNanoseconds()) / 1000000.0`，仅函数名不同（`Ms` vs `Millis`）；两处 catch 生成同一条错误文案。
- **描述**：改精度（如换成 `.toMicroseconds()` 或加纳秒小数）需要同时改三处，漏一处就会出现同一份快照里 `latencyMs` 精度不一致；命名不统一也让 grep 找不到全部实现。
- **建议**：收敛到 `fprobe/collect` 包内一个 `internal func elapsedMs(start: MonoTime): Float64`（`health` 与 `net` 都是它的子包，`internal` 在包及子包可见），三处改为 import；`RPC 调用失败` 文案抽成一个函数或统一在 transport 侧构造，探针侧不再重复拼。

### [轻微][存量] `HealthData` 的 11 个字段在 3 个 DTO 里各写一遍，且有三段逐字段拷贝

- **位置**：`fprobe/src/collect/health/HealthMetrics.cj:28-57`（字段 + 11 参构造）、`:83-116`（`HealthSample` 再把 11 个字段 + 3 个自有字段抄一遍）、`fprobe/src/collect/health/RpcHealthProbe.cj:26-63`（`RpcHealthTarget` 第三份 + `match (metrics)` 逐字段赋值）
- **来源**：存量
- **判据**：review-checklist §2（只改类型名的重复逻辑）、§11（下次加字段必然漂移）
- **证据**：静态确定 —— 三处字段集合与类型完全一致（`allocatedHeapSize`…`usedHeapSize`，共 11 个，与 `f_health/src/HealthData.cj:24-74` 的 `public prop` 一一对应），差异只在 `HealthSample` 多了 `latencyMs`/`statusCode`/`error`、`RpcHealthTarget` 多了 `name`；`HealthMetrics.cj:101-116` 与 `RpcHealthProbe.cj:48-62` 是同一段 11 行赋值。
- **描述**：`f_health` 新增一个指标（例如 `gcPauseMax`）时，这三份 DTO、三段拷贝、`MvcHealthProbe_test` 的逐字段断言都要改；漏改任意一处，RPC 路径就会静默丢字段（`@DataAssist` 缺字段按 0 处理，不报错——与上一条同源）。此外 `MvcHealthProbe.cj:72` 的 `healthJson` 与 `RpcHealthProbe.cj:112` 的 `JsonValue.from(...toData()).asObject()` 也是同一段"DTO→JsonObject"。
- **建议**：让 `HealthSample`/`RpcHealthTarget` **持有** `HealthMetrics` 字段（组合而非平铺），或抽出 `HealthSample(metrics: HealthMetrics, …)` 的单一转换函数（`HealthMetrics` 已有 `toData()`，序列化时展平一次即可）；若必须平铺以保证 JSON 形状不变，用一个 `private func flatten(metrics, extra…)` 生成 `DataObject`，三处共用。

### [轻微][存量] `ProbeRunner.tick` 内联重写了 `ProbeSnapshotBuilder.agentData` 的 host 回退与编码，后者生产路径零引用

- **位置**：`fprobe/src/collect/ProbeRunner.cj:90-95`（`resolvedHost` + `ProbeAgentData(...)`）；`fprobe/src/collect/ProbeSnapshotBuilder.cj:42-50`（`agentData`）
- **来源**：存量
- **判据**：review-checklist §2（同一语义两处实现）、§1（仅测试引用的 public 成员，作可见性建议而非死代码）
- **证据**：静态确定 —— 全仓 `grep -rn "agentData"` 只命中定义与 `ProbeRunner_test.cj:153/155/165/167`；生产装配（`AgentRuntime.cj:57/88/94`）只经 `tick()`。两处的 host 回退判定（`agent.host.isEmpty() ? defaultHost : agent.host`）与 `encode` 调用一致。
- **描述**：`agentData` 的语义是"再取一次 `agent.data` 并编码"，而 `tick()` 需要在失败时保留旧 `dataJson`，所以没有直接调用它——但这也让"host 回退 + 构造 `ProbeAgentData`"有了两份实现。当前没有行为差异（`agentData` 被用例覆盖），但改一处漏一处就会让测试与生产走不同路径（测试全绿、生产漂移）。
- **建议**：把 `agentData` 拆成 `resolveHost(agent, defaultHost): String` + `agentData(agent, encodedJson, collectedAt, error)` 两个入口，`tick()` 复用；或让 `tick()` 在成功后调用 `agentData(agent, …)`、失败时走保留旧值的新重载。因为 `fprobe` 是 `output-type = "executable"`（`fprobe/cjpm.toml:36`），也可直接把 `agentData` 收窄为 `internal` 并给"仅测试用"的注释。

### [轻微][存量] 快照发布职责重复：`tick()` 内部 `replace` 一次，调用方再 `replace` 一次

- **位置**：`fprobe/src/collect/ProbeRunner.cj:97-99`（`store.replace(snapshot)` 后 `return snapshot`）；`fprobe/src/runtime/AgentRuntime.cj:88-89`（`let first = runner.tick(); store.replace(first)`）、`:94`（`store.replace(runner.tick())`）
- **来源**：存量
- **判据**：review-checklist §2（同一副作用两处执行）、§11（注释与实际调用约定不一致）
- **证据**：静态确定 —— `tick()` 的文档写"执行一轮采集并整体替换快照；返回刚发布的快照"，已经承担发布；`AgentRuntime.serve` 又对返回值再发布一次，等于每轮多一次 `Mutex` + 一次写 `current`。
- **描述**：两份发布点意味着"谁负责发布"没有单一约定：新增调用方若只调 `tick()` 会意外发布，若在 `tick()` 外加事务（如"采集成功才发布"）则会被内部提前发布破坏。当前功能正确，只多一次无意义加锁。
- **建议**：保留 `tick()` 内部发布（返回值语义不变），删掉 `AgentRuntime.cj:89` 与 `:94` 外层 `store.replace`；若要让调用方决定何时发布，则把 `tick()` 改为纯采集并同步更新注释与 `ProbeRunner_test` 的"store 与返回值是同一批数据"断言。

### [轻微][存量] 邮件标题解析在 `subjectOf` 与 `renderHtml` 各写一遍（补 part2 #9 的同根项）

- **位置**：`fprobe/src/channel/EmailAlarmChannel.cj:84-111`（`subjectOf` 里 `for (line in message.split("\n"))` 找首个非空行 + 找 `节点:`）、`:119-146`（`renderHtml` 再循环一次，找首个非空行当 `title`，再按 `:` 切 `rows`）
- **来源**：存量
- **判据**：review-checklist §2（换控制流 / 同语义两处）
- **证据**：静态确定 —— 两份循环都做 `trimAscii()`→跳空行→首个非空行写入 `title`；`subjectOf` 额外取 `节点:`，`renderHtml` 额外按 `:` 切表格。part2 #9 已报 `AlarmEvent.format` ↔ `renderHtml` 的字段表重复，本条是同一根因在渠道内部的第二处。
- **描述**：`AlarmEvent.format()` 的格式一旦调整（例如标题行改为"级别 + 摘要"），主题、横幅、表格三处会分别漂移；两处都是"解析自己刚生成的文本"。
- **建议**：抽 `private func parseMessage(message: String): (String, String, Array<(String, String)>)`（title、node、rows），`subjectOf` / `renderHtml` 共用；更彻底的做法是让 `AlarmMessageChannel.send` 接收结构化 `AlarmEvent`（与 part2 #9 的建议合并）。

### [轻微][存量] `IntervalCounter` 全仓只被测试引用，生产探针各自实现差分

- **位置**：`fprobe/src/collect/IntervalCounter.cj:24-52`；唯一引用 `fprobe/src/collect/Collect_test.cj:23-57`
- **来源**：存量
- **判据**：review-checklist §1（仅测试使用 ⇒ 可见性建议，不是死代码）
- **证据**：静态确定 —— `grep -rn "IntervalCounter" --include=*.cj fprobe` 仅定义 + `Collect_test`；`CpuProbe.cj:54-93`、`DiskProbe.cj:217-242`、`NetworkProbe.cj:145-164` 都自带 `hasBaseline/last*` 字段与 `delta*1000/elapsed` 计算。
- **描述**：这个"单调计数器差分"工具是为采集写的，但没有任何探针用它：CPU 算的是占比（不是每秒速率）、Disk/Network 按设备分别记基线，接口不匹配，于是各自复制了一份差分逻辑。留着它会让下一位维护者以为"差分有统一实现"，实际改它不会影响任何采集结果。
- **建议**：二选一：(a) 把它改成按 `(key)` 分片的差分器（`update(key, value, nowMs)`），让 `DiskProbe`/`NetworkProbe` 复用，顺便统一"回绕按 0 计"的口径；(b) 确认不再需要就删掉（executable 模块无下游契约）。不要维持"仅测试覆盖的生产工具"状态。

### [轻微][存量] `JsonArrayData.parse` / `JsonObjectData.parse` 不校验顶层类型，且异常消息内嵌整份输入

- **位置**：`fprobe/src/collect/JsonData.cj:66-72`（`JsonObjectData.tryParse` 直接 `jsonToData(text)`，`parse` 失败时 `'${text} cannot be parsed as JSON object'`）、`:100-107`（`JsonArrayData` 同形）
- **来源**：存量
- **判据**：review-checklist §11（契约与实现不符）、§5（异常消息按输入长度物化）
- **证据**：静态确定 —— `jsonToData`（`:28-34`）对 `{...}` 与 `[...]` 都返回对应包装；`JsonArrayData.tryParse("[1]")` 与 `tryParse("{\"a\":1}")` 都成功，`parse` 的返回类型是 `Data` 而非数组；两个 `parse` 都把完整 `text` 拼进 `DataException.message`。
- **描述**：这两个静态方法只是 `DataParsable` 接口的实现（`f_data/src/base/DataParsable.cj:21-24`），仓内无调用，所以当前不触发；但一旦有人按名字使用，`JsonArrayData.parse("{}")` 会拿到 `JsonObjectData`，随后 `size`/`iterator` 语义全错。异常消息内嵌全文在报文为 KB 级时会把日志和异常对象一起放大。
- **建议**：`parse`/`tryParse` 里判一次顶层类型（`match (jsonToData(text)) { case Some(x: JsonArrayData) => … case _ => None }`），失败消息只保留前 N 字节（如 64 字符 + `…`）。

### [轻微][存量] `FEmailTransport` 从不释放 `Email`（不实现 `Resource`、无 `close`），媒体类型只识别 `.svg`

- **位置**：`fprobe/src/channel/FEmailTransport.cj:32-33`（持有 `Email <: Resource`，类本身无 `close`）、`:89-127`；`fprobe/src/channel/EmailAlarmChannel.cj:174-180`（`mediaType` 仅判 `.svg`）
- **来源**：存量
- **判据**：review-checklist §11（资源释放不对称）、§14.1（半成品：`MailTransport.cj:18` 承诺"媒体类型由扩展名推断"）
- **证据**：静态确定 —— `f_email/src/EmailFacade.cj:213` `public class Email <: Resource`；全仓 `grep "email.close\|FEmailTransport.*close"` 无命中，`SupervisorRuntime` 的关停路径只关 `transport.close()`（`:58`，那是节点 RPC 连接）与 `source.close()`（`:222`），不含邮件。`mediaType` 只对 `.svg` 返回 `image/svg+xml`，其余一律 `application/octet-stream`（`:174-180`），而注释写的是"由扩展名推断"。
- **描述**：SMTP/IMAP 会话在进程退出前不会主动 `close`：`Email` 的 `closedFlag` 与三个 client 字段一直持有 socket，进程被 signal 杀掉时靠 OS 回收（可接受），但优雅退出（`stop()` → `serve()` 返回）后 socket 仍在，若进程被 fboot 复用于重启会短暂积累；`.png/.pdf` 附件以 `octet-stream` 发出，客户端不内联预览——与"由扩展名推断"的注释不符。
- **建议**：`FEmailTransport` 实现 `Resource`（`close()` 转发 `email.close()`），在 `SupervisorRuntime` 的退出路径调用；`mediaType` 用一张小扩展名表（`.svg/.png/.jpg/.pdf/.csv/.txt/.json`）并补用例。

<!-- 第 4 部分 -->

> 编号索引（正文与「覆盖自检」用 F 编号引用）：F1 SMART 缺 `smart_status`→FAILED｜F2 `df -Pi` 的 `-` 导致整项失败｜F3 磁盘基线残留｜F4 TCP 域名/IPv6 恒不可达｜F5 connect 异常泄漏 socket｜F6 硬件采集串行｜F7 命令输出无上限｜F8 IPMI 单位/数值｜F9 参数白名单缺口｜F10 死代码｜F11 重复逻辑（跨包）｜F12 重复逻辑（DiskProbe 内）｜F13 静默吞 terminate 失败。

### [一般] SMART JSON 缺 `smart_status` 时被上报为 FAILED（假告警）

- **位置**：`fprobe/src/collect/hw/SmartProbe.cj:57`（`SmartctlSmartStatus.passed = false` 默认值）、`fprobe/src/collect/hw/SmartProbe.cj:166`（`fromJson` 把 `passed` 直接映射 PASSED/FAILED）
- **来源**：存量（快照模式，无 diff 可比）
- **判据**：review-checklist §11（语义与命名 / 注释不符、错误处理缺失）+ §13 契约一致性
- **证据**：静态确定 —— `DataObject.populate` 只按 **源 JSON 里出现的字段** 调用 `set`（`f_data/src/base/DataObject.cj:194-207`），缺失字段保留类型默认值 `false`；`fromJson` 不区分「字段不存在」与「字段为 false」，也不看 `available`。
- **描述**：`smartctl -A -j` 在设备不支持 SMART、USB/SATA 桥接、部分虚拟盘上不会输出 `smart_status`，但退出码为 0。此时 `parseJson` 成功、`available=true`、`error=""`，`health` 却是 `FAILED`，形成磁盘健康假告警。同一文件文本回退路径（`parseText`）在 health 缺失时留空串，两条路径对「未知」的表达不一致。
- **建议**：把 `SmartctlSmartStatus` 字段改为可空（`?SmartctlSmartStatus`，缺字段即 `None`），`fromJson` 在 `None` 时输出 `UNKNOWN` 并保持 `available=true`，或额外返回 `statusKnown: Bool`；同时与文本路径的「未知」表达统一。

### [一般] `df -Pi` 的 IUse% 为 `-` 时整个 `disk` 项采集失败，且排除过滤救不回来

- **位置**：`fprobe/src/collect/proc/DiskProbe.cj:302`（inode 行 `requireInt/requirePercent`）、`fprobe/src/collect/proc/DiskProbe.cj:315`（`requirePercent`）；排除过滤在解析之后才执行（`fprobe/src/collect/proc/DiskProbe.cj:186-189`）
- **来源**：存量
- **判据**：review-checklist §11（边界 / 空值未处理、错误处理缺失）
- **证据**：静态确定 —— `requirePercent` 只接受可被 `Float64.tryParse` 解析的串，`"-"` 直接抛 `ProbeException`；`parseInodeDf` 在 `mergeMounts` 之前调用，`probe_diskExcludeFs` 的过滤发生在解析之后，无法避免该行。触发面（哪些文件系统的 `df -i` 打印 `-`，如 vfat/exFAT 这类无 inode 统计的挂载）需实测确认。
- **描述**：一旦主机存在一个 inode 统计不可用的挂载点，`parseInodeDf` 抛 `COLLECT`，`disk` 监控项整项进 error（`ProbeRunner` 保留上一帧），mounts 与 devices 全部不再更新。这是「一行合法但特殊的输出 → 丢整项指标」，与同文件 `parseSpaceDf` 的 fail-fast 用例（针对垃圾输入）不是同一类。
- **建议**：把 `-`（以及空串）视为「该挂载点无 inode 信息」，`DfInodeRow` 用可空字段或 `inodes=0` 表示，`mergeMounts` 已有的 `case None` 分支（`:376-378`）可直接复用；仅对真正无法解析的行 fail-fast。

### [一般] 磁盘消失后 `previous` 基线残留，重新出现时 IOPS/await 按单区间放大

- **位置**：`fprobe/src/collect/proc/DiskProbe.cj:163`（`previous` 只增不减）、`fprobe/src/collect/proc/DiskProbe.cj:228-251`（差分与写回）
- **来源**：存量
- **判据**：review-checklist §11（边界 / 语义与命名不符）、§5（无界容器，长期持有）
- **证据**：静态确定 —— 每帧只遍历 `counters`，从不删除 `previous` 中不在本帧的键；`elapsed` 取全局 `lastNowMs`（`:217-221`），不含设备缺席时长。
- **描述**：设备（USB 盘、`loopN`、容器 `dm-*`）消失若干帧后重新出现时，`current - last` 累积了缺席期间的全部计数，却除以本帧的 `elapsed`（默认 5s）⇒ `readIops/writeIops/utilPercent` 被放大数倍到数十倍，`awaitMs` 也失真，容易触发磁盘 IO 告警。同时这些残留条目永不清理，属于慢速无界增长（每条约 100–200 字节，设备频繁增删的宿主机长期运行会积累）。
- **建议**：每帧结束后剔除本帧未出现的键（或给 `DeviceCounters` 加 `seenAt`，间隔超过 2×`intervalMs` 时按首帧处理）；写回 `previous` 时同时记录该设备自己的采样时刻。

### [一般] TCP 探针不做域名解析，域名/IPv6 目标恒报「不可达」

- **位置**：`fprobe/src/collect/net/TcpProbe.cj:46`（`IPSocketAddress(host, port)`）、`fprobe/src/collect/net/ServiceReachabilityProbe.cj:116`（把 `parseTarget` 解析出的 host 原样传入）
- **来源**：存量
- **判据**：review-checklist §11（契约与实现不符）、§10（边界 / 外部输入）
- **证据**：静态确定 —— `std.net` 文档 `net_package_api/net_package_classes.md:1602-1617`：`IPSocketAddress(address: String, port)` 的 `address` 必须是 **IP 地址字符串**，非法即抛 `IllegalFormatException`；`TcpSocket` 不做名称解析。`parseTarget`（`ServiceReachabilityProbe.cj:138-185`）对 host 不做任何 IP 校验。
- **描述**：`probe_serviceTargets='db@tcp://db.internal:3306'` 这类配置会稳定得到 `reachable=false, error="连接失败: ..."`，把「服务不可达」误报为故障；`[::1]:8080` 形式（`splitAuthority` 用 `lastIndexOf(':')`，host 带方括号）同样解析失败。README 示例用的是 `127.0.0.1`，所以问题只在用域名/IPv6 时暴露（触发面待确认，机制静态确定）。
- **建议**：先用 `IPAddress.resolve(domain)`（`net_package_api/net_package_classes.md:210-238`）解析出地址再建 `IPSocketAddress`，或在 `parseTarget` 阶段就把 host 归一化为 IP 并给出明确错误；IPv6 去掉方括号后传入。

### [一般] `connect` 抛异常时 socket 未关闭（异常路径资源不释放）

- **位置**：`fprobe/src/collect/net/TcpProbe.cj:45-52`
- **来源**：存量
- **判据**：review-checklist §11（资源不对称：打开未关）
- **证据**：静态确定 —— `socket` 在 `try` 块内构造，`close()` 只在成功路径（`:48`）执行；`catch` 分支（`:50-52`）无法访问该局部变量。`Resource` 接口只在 `try-with-resource` 上下文自动释放（`core_package_interfaces.md:1343-1354`），这里没有使用。
- **描述**：连接被拒绝、超时、地址非法时每次探测泄漏一个 fd，直到 GC 回收（文档不保证 GC 关闭）。`probe_serviceTargets` 里被墙/宕机的 TCP 目标每轮都会走到异常分支，长跑会持续抬高 fd 占用。
- **建议**：改用 `try (socket = TcpSocket(...)) { ... }`（`Resource` + try-with-resource），或在 `catch` 前把 socket 提到块外并在 `finally` 关闭。

### [一般] 硬件探针串行执行外部命令，单轮耗时随设备数×超时线性叠加

- **位置**：`fprobe/src/collect/hw/HardwareProbe.cj:55-61`（三个子采集器顺序调用）、`fprobe/src/collect/hw/SmartProbe.cj:100-106`（逐设备 `collectDevice`）、`fprobe/src/collect/hw/SnmpProbe.cj:79-101`（逐设备 `runner.run`）
- **来源**：存量
- **判据**：review-checklist §6.3（并发串行：批内逐个等待）、§5（有界性）
- **证据**：静态确定 —— 三处都是普通 `for` 循环里同步 `run(...)`，每次最多阻塞 `timeoutMs`（默认 `commandTimeoutMs=3000`，README:151/525）。最坏一轮 = `(1 + N_smart + M_snmp) × 3000ms`；10 块盘 + 5 台 SNMP 设备即 48s，而默认 `intervalMs=5000`。
- **描述**：`ProbeRunner.tick()` 是单线程串行遍历探针（`fprobe/src/collect/ProbeRunner.cj:77-100`），`AgentRuntime` 的采集循环是 `tick()` 之后才 `clock.wait(intervalMs)`（`fprobe/src/runtime/AgentRuntime.cj:92-95`）。因此一台工具卡住会把整轮采集（含 cpu/memory 等快探针）推到 3s 的整数倍，快照间隔被拉长、告警窗口被吃掉；`smartctl` 在坏盘上卡满超时是常见现象。
- **建议**：对 `SmartProbe`/`SnmpProbe` 内设备级采集使用有界并发（固定窗口 + 先提交后统一 `get`，窗口 = 核数或配置项），或在 `HardwareProbe` 层把 ipmi/snmp/smart 三路并发；同时给单轮总预算（超预算即返回已完成部分并标 `error`）。

### [一般] 外部命令输出全量读入且无上限，SNMP 对端可放大内存

- **位置**：`fprobe/src/collect/hw/CommandRunner.cj:71-76`（`waitOutput()` 一次性返回 stdout/stderr）、`fprobe/src/collect/hw/SnmpProbe.cj:123-146`（`split("\n")` + 每条建 `SnmpReading`）
- **来源**：存量
- **判据**：review-checklist §5（一次性物化、无拒绝路径）
- **证据**：静态确定 —— 读取侧没有任何字节上限；`String.fromUtf8(stdout)` 再复制一份，`split` 生成整行数组，`parseWalk` 再为每行建对象，峰值约为原始输出的 2–3 倍。触发规模需实测（受 3s 超时约束）。
- **描述**：`ipmitool`/`df`/`smartctl` 是本机可信工具，但 `snmpbulkwalk` 的输出由远端设备决定：恶意/异常 agent 返回超大 OID 表时，3s 内即可读入数十 MB 并放大数倍，fprobe 常驻进程（还会跑 TUI/告警）可能 OOM。
- **建议**：给 `CommandRunner` 增加输出上限（如 4 MiB，超限截断并置 `error`/`timedOut=false` 的显式错误位），或改为分块读取 + 边读边解析；`parseWalk` 亦可对行数设上限。

### [一般] IPMI 读数单位与数值语义错误：华氏被标成摄氏、离散量填 0

- **位置**：`fprobe/src/collect/hw/IpmiProbe.cj:127`（`normalizeUnit` 把任何含 `degree` 的单位映射为 `C`）、`fprobe/src/collect/hw/IpmiProbe.cj:113-122`（非数字读数按 `0.0` 保留）
- **来源**：存量
- **判据**：review-checklist §11（语义与命名 / 注释不符、数值错误）、§13（单位契约）
- **证据**：静态确定 —— `lower.contains("degree")` 同时命中 `degrees C` 与 `degrees F`，返回值恒为 `"C"`，数值原样保留；`classifySensor` 因此把华氏传感器归为 `Temperature`。`tryFloat("0x01")` 为 `None` 时，`Power Supply` 分支写入 `0.0` 且 `available=true`。
- **描述**：某传感器输出 `150 degrees F`（≈65.6°C）时上报 `value=150, unit="C"`，直接触发过温告警；`PS1 Status | 0x01` 这类离散量上报 `value=0`，若告警规则含「电源值 ≤0」则误报。规格要求包含电源传感器（`IpmiProbe.cj:47-52`），但离散量没有「无连续值」的表达。
- **建议**：`normalizeUnit` 区分 `degree(s) c` 与 `degree(s) f`，华氏按 `(v-32)*5/9` 换算后统一为 `C`（或保留 `F` 并在字段上体现）；离散量用 `value` 可空 / `unit="discrete"` 表示，不要用 0 冒充读数。

### [轻微] 外部命令参数白名单有缺口：`-` 开头可当选项、`..` 可逃出 `/dev`

- **位置**：`fprobe/src/collect/hw/SnmpProbe.cj:110-121`（只拒空白与 shell 元字符）、`fprobe/src/collect/hw/SmartProbe.cj:221-238`（`..` 与 `/` 都在允许集合内）、同源校验 `fprobe/src/config/Validation.cj:188-190`、`:216-234`
- **来源**：存量
- **判据**：review-checklist §10（安全性：外部输入未校验）、§11（注释承诺 A、实现做 B）
- **证据**：静态确定 —— `unsafeReason` 未检查首字符 `-`，`argv[4]` 会被 `snmpbulkwalk` 当选项解析（如 `host="-V"`、`community="-m"`）；`isSafeDevice` 允许 `.` 与 `/` 的任意组合，注释与 README/错误文案却写「只允许 /dev/ 下的字母、数字与 ._-/」。
- **描述**：两处都不会造成 shell 注入（参数数组直传、无空白），但选项注入能改变工具行为（输出格式、协议版本、甚至 `-e` 引擎 ID），`/dev/../../etc/xxx` 也会被当成「合法设备路径」交给 `smartctl`。
- **建议**：拒绝首字符 `-`（或统一加 `--` 结束符）；`isSafeDevice` 额外拒绝包含 `..` 的路径段（按 `/` 切段后判 `..`/`.`），并让注释与实现一致。

### [轻微] 死代码：`SmartctlDeviceInfo` / `SmartctlReport.device` 从未读取，`DiskProbe` 有未使用 import

- **位置**：`fprobe/src/collect/hw/SmartProbe.cj:49-54`（`SmartctlDeviceInfo`）、`fprobe/src/collect/hw/SmartProbe.cj:72`（`SmartctlReport.device`）、`fprobe/src/collect/proc/DiskProbe.cj:23`（`import ... {CommandRunner, CommandResult}`）
- **来源**：存量
- **判据**：review-checklist §1（读了不用 / 未使用的 import；非公共顶级声明里的成员无使用）
- **证据**：静态确定 —— 全仓 `grep SmartctlDeviceInfo` 只命中定义与 `SmartctlReport.device` 的字段声明；`report.device` 在 `fromJson`/`collectDevice` 中无任何读取（`device` 参数来自配置）。`CommandResult` 在 `DiskProbe.cj` 只出现在 import 行，函数体内类型由 `runner.run` 推断。
- **描述**：`DataAssist` 的 `SILENCE` 策略会忽略未声明字段，删除这两个声明不影响 JSON 解析与上报；`device` 字段的 JSON 子结构本来就没被使用（模型/健康/温度都在顶层的 `model_name`/`smart_status`/`temperature`）。
- **建议**：删除 `SmartctlDeviceInfo` 与 `SmartctlReport.device`（保留 `model_name/smart_status/temperature`），删除 `CommandResult` import。

### [轻微] 重复逻辑（1）：同一套文本/校验工具在 `collect/hw`、`collect/proc`、`config` 各写一遍

- **位置**：`fprobe/src/collect/hw/HardwareParsing.cj:22` ≡ `fprobe/src/collect/proc/ProbeParsing.cj:26`（`splitTokens` / `splitWhitespace`）；`HardwareParsing.cj:34` ≡ `ProbeParsing.cj:38`（`joinTokens` / `joinFrom`）；`HardwareParsing.cj:52` ≡ `fprobe/src/config/Validation.cj:271`（`hasWhitespace`）；`HardwareParsing.cj:57` ≡ `Validation.cj:276`（`hasShellMeta`）；`fprobe/src/collect/hw/SmartProbe.cj:221-238` ≡ `Validation.cj:216-234`（`isSafeDevice` / `isSafeDevicePath`）；`TcpProbe.cj:56-58` ≡ `fprobe/src/collect/health/RpcHealthTransport.cj:103-105`（`elapsedMillis`）
- **来源**：存量
- **判据**：review-checklist §2（跨文件/跨层复制，只改类型名或文件位置）
- **证据**：静态确定 —— 逐行比对 6 组函数体，唯一差异是函数名与包名；`splitTokens` 与 `splitWhitespace` 连「按 `" "` 切分 + `trimAscii` + 丢空」的实现与注释都一致，`hasShellMeta` 的字符集合完全一致。
- **描述**：同一规则已有 2–3 份副本，任一处收紧（例如补 `-` 前导校验、补 `..` 判断）都会漂移：`Validation.cj` 与 `SmartProbe.cj` 现在就各自漏了同一类路径校验，`hasShellMeta` 在两个包里的字符集合同步维护。
- **建议**：把 `splitTokens`/`joinTokens`/`hasWhitespace`/`hasShellMeta`/`isSafeDevicePath`/`elapsedMillis` 收敛到模块内共享包（建议 `fprobe/src/collect/TextParsing.cj`，`package fountain::fprobe.collect`，`proc`/`hw` 均已是其子包），`config` 与 `health` 改为引用；合并时保留现有签名，行为不变（需附「含空格挂载点」「含 `\t` 参数」两类等价用例）。

### [轻微] 重复逻辑（2）：`DiskProbe` 内 `df -Pk`/`df -Pi` 行解析与整数校验各写一份

- **位置**：`fprobe/src/collect/proc/DiskProbe.cj:260-282`（`parseSpaceDf`）vs `:284-306`（`parseInodeDf`）；`:308-313`（`requireInt`）vs `:403-409`（`requireStat`）
- **来源**：存量
- **判据**：review-checklist §2（同文件内输入-输出-副作用相同的实现）
- **证据**：静态确定 —— 两个 `parse*Df` 的「跳过空行 → 首行 `Filesystem` 表头判断 → `splitWhitespace` → `size < 6` 抛错 → 列解析」逐句一致，差异只有结构体类型、`source` 列是否保留与错误文案里的 `-Pk`/`-Pi`；`requireInt` 与 `requireStat` 都是「`tryInt64` 成功取值、失败抛 `COLLECT`」，只差消息前缀。
- **描述**：列索引与表头判定被复制两份，`df` 输出格式变化（例如新增列、`-` 占位）需要同步改两处；本次 F2 的 `-` 处理缺失也出现在其中一份里（`df -Pi`），另一份（`df -Pk`）没有同类占位符，属于「近似重复导致边界漂移」。
- **建议**：抽一个 `parseDfRows(text, label, withSource) -> Array<DfRow>`（`DfRow` 已具备 `source`，inode 行可置空串），两个调用点只传 `-Pk`/`-Pi`；`requireStat` 合并进 `requireInt(token, label)`，消息由调用方拼。

### [轻微] 超时路径静默忽略 `terminate` 失败，可能残留子进程与等待线程

- **位置**：`fprobe/src/collect/hw/CommandRunner.cj:77-84`（`catch (_: Exception) { () }`）
- **来源**：存量
- **判据**：review-checklist §3（`catch {}` 静默吞异常）
- **证据**：静态确定 —— `process.terminate(force: true)` 失败被完全丢弃，函数直接返回 `timedOut=true`，`spawn {=> process.waitOutput() }` 的线程与子进程没有任何后续处置。
- **描述**：`terminate` 失败（权限、进程已进入不可中断状态）时，子进程继续运行、等待线程被占用，下一轮又起新进程；`hardware` 每轮固定起 3 个以上进程，长时间会积累。
- **建议**：`terminate` 失败时写入 `CommandResult.error`（供上层标记降级），并记录一次告警日志；或对 `pending` 增加超时后的补偿等待/取消路径。

> 存量 13 条（严重 0 / 一般 8 / 轻微 5），是否纳入修复待用户决定。

<!-- 第 5 部分 -->

### [一般][存量] Topology 采集串行且超时可叠加，拖住唯一采集线程

- **位置**：`fprobe/src/collect/topology/TopologyProbe.cj:118`（设备循环）、`:179`（`runWalk` 调用）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §6.3（并发串行）/ §12.1（采集主路径阻塞）
- **证据**：静态确定 —— `data` 对每台设备顺序执行 2 次 `snmpbulkwalk`，每次最长 `timeoutMs`（默认 3000，`ProbeFactory.cj:70-72` 传入 `settings.commandTimeoutMs`；IF-MIB 与 LLDP-MIB 各一次，`TopologyProbe.cj:119,134`）。结合 `AgentRuntime.cj:92-97` 的单采集线程，单轮最坏耗时 ≈ `2 × N × commandTimeoutMs`（N=10 且全部超时 → 60s，而 `probe_intervalMs` 默认 5s）。
- **描述**：拓扑是慢变量，却按采集主频全量 walk。任一设备不可达就整轮变慢：其余探针的差分窗口被一起拉长（CPU/网络速率按 60s 而不是 5s 求差），快照时间戳与实际采样时刻脱节，且没有总预算、没有并发上限。
- **建议**：给 topology 独立采集周期（或给 walk 结果加 TTL 缓存）；设备间改成“先提交全部 `spawn` 再统一 `get`”并按核数限流；同时把单设备超时收敛到 `总预算/N`。

### [一般][存量] walk 未加 `-On`：装有 MIB 时输出符号 OID，拓扑解析静默丢弃全部条目

- **位置**：`fprobe/src/collect/topology/TopologyProbe.cj:179`；`IfMibParser.cj:76`；`LldpParser.cj:52,57`
- **来源**：存量
- **判据**：review-checklist §11（契约与实现不符）/ §3（静默失效）
- **证据**：待确认 —— 需确认目标机是否安装 net-snmp MIB：装了则输出 `IF-MIB::ifDescr.1 = STRING: eth0`，不装则是 `.1.3.6.1.2.1.2.2.1.2.1`。代码侧静态确定：`parseIfMib` 只接受以 `1.3.6.1.2.1.2.2.1.2.` 开头的 OID，`parseLldp` 只接受以 `1.0.8802...` 开头。
- **描述**：MIB 可用时两个解析器都返回空数组，`TopologySample` 的 `devices`/`links` 为空且 `error` 仍是空串（`TopologyProbe.cj:173`），监控侧看不到任何异常；同一份 walk 文本在 `hw/SnmpProbe.cj:123-147` 却因为不过滤前缀能正常解析，行为不一致。
- **建议**：`snmpbulkwalk` 参数补 `-On`（强制数字 OID）；或在 `parseIfMib`/`parseLldp` 里同时接受符号前缀并归一化；并把“walk 成功但解析出 0 条”写进 `error`。

### [一般][存量] 网卡白名单全部未命中时静默返回空列表

- **位置**：`fprobe/src/collect/proc/NetworkProbe.cj:152-157`
- **来源**：存量
- **判据**：review-checklist §3（静默失效）/ §11（错误处理缺失）
- **证据**：静态确定 —— 白名单非空且 `contains` 永假时，循环只执行 `previous[current.name] = current; continue`，`interfaces` 为空；`data` 正常返回 JSON，`ProbeRunner.tick` 只在抛异常时写 `slot.error`（`ProbeRunner.cj:82-89`），因此快照里 `error` 为空串。
- **描述**：`probe_networkInterfaces` 写错一个字符、或容器内网卡改名后，`network` 监控项永久为空数组且无错误、无日志，属于“采集到了 0 条但看起来一切正常”。
- **建议**：白名单非空且本轮命中数为 0 时抛 `ProbeException(ProbeErrorCode.COLLECT, ...)`；或在 `NetworkSample` 增加 `matched` 字段并在采集日志里打命中数。

### [一般][存量] `probe_snmpDevices` 不查重名，TopologyProbe 静默丢弃后一个设备的端口表

- **位置**：`fprobe/src/config/Validation.cj:179-200`（对比同文件 `:160-176` 的 `parseRpcHealthTargets` 有查重）；`fprobe/src/collect/topology/TopologyProbe.cj:142-145`
- **来源**：存量
- **判据**：review-checklist §2（同类校验不一致）/ §11（静默丢弃）
- **证据**：静态确定 —— `parseSnmpDevices` 只校验 `parts.size == 3` 与字符集，不查重名；`TopologyProbe` 用 `known` 按 `device.name` 去重，第二台同名设备的 `host`/`ports` 不进 `discovered`，但它的 LLDP 观察仍进入 `neighbours` 并参与建链（`:146`）。
- **描述**：复制粘贴配置出重名时，输出的设备条目 host/端口来自第一条，链路却可能来自第二条，拓扑自相矛盾且启动不报错（对比：`probe_rpcHealthTargets` 重名会让启动退出 2）。
- **建议**：`parseSnmpDevices` 内用 `HashSet<String>` 查重名并 `errors.add`，与 `parseRpcHealthTargets` 对齐。

### [一般][存量] 远端设备的 `ports` 只保留首个观察到的端口

- **位置**：`fprobe/src/collect/topology/TopologyProbe.cj:165-169`
- **来源**：存量
- **判据**：review-checklist §11（契约与实现不符）
- **证据**：静态确定 —— 首次发现远端设备时构造 `TopologyDevice(name, name, [observation.remotePort])`，之后 `known.contains` 直接跳过，后续同设备的其它远端端口既不进 `ports` 也不更新；`TopologyDevice` 的字段语义是“设备及其端口”（`TopologyProbe.cj:24`）。
- **描述**：一台交换机在本端 8 个端口被看到时，拓扑里它只有 1 个端口，端口级展示/告警会漏；且 `host` 直接填设备名（不是可解析地址），与配置设备条目形态不同。
- **建议**：先用 `HashMap<String, ArrayList<String>>` 聚合远端设备端口，循环结束后统一构造 `TopologyDevice`；`host` 至少留空或标注来源。

### [一般][存量] Windows 分支引用 `std.env` 但未 import

- **位置**：`fprobe/src/config/AgentSettings.cj:160-166`（`:162 std.env.getVariable("COMPUTERNAME")`）
- **来源**：存量
- **判据**：review-checklist §11（编译期正确性；条件编译分支）
- **证据**：待确认 —— 需在 `os == "Windows"` 目标上 `cjpm build` 验证。旁证：仓内其它使用 `std.env` 的文件全部显式 import（`f_config/src/Config.cj:20`、`fprobe/src/llm/LlmTestSupport_test.cj:19`、`f_base/src/Console.cj:18`），本文件 import 列表（`:18-23`）没有 `std.env`，且该分支在 Linux 目标下从不参与编译，CI 不会暴露。
- **描述**：若未 import 时全限定名不可解析，fprobe 在 Windows 目标上直接编译失败（Linux 目标不受影响）。
- **建议**：补 `import std.env.getVariable`（与既有文件风格一致），顺便消除“同一函数两套条件编译实现”的维护面。

### [一般][存量] SNMP walk 文本解析两份实现且已漂移

- **位置**：`fprobe/src/collect/topology/IfMibParser.cj:46-69`（`parseWalk`）vs `fprobe/src/collect/hw/SnmpProbe.cj:123-147`（同名 `parseWalk`）；`IfMibParser.cj:96-102`（`unquote`）vs `fprobe/src/collect/hw/HardwareParsing.cj:63-72`（`stripQuotes`）
- **来源**：存量
- **判据**：review-checklist §2（近似重复 + 已出现行为漂移）
- **证据**：静态确定 —— 两边流程相同（按 `\n` 切行 → `trimAscii` → 找 `" = "` → 找 `": "` → 去引号）。差异：hw 版保留前导点、拓扑版 `trimLeadingDots`；`stripQuotes` 同时去 `"` 与 `'`，`unquote` 只去 `"`。
- **描述**：同一种 `snmpwalk` 文本两处解析，引号/点号规则不一致：拓扑侧遇到单引号包裹的值会带着引号进 `ports`/`remotePort`，进而影响 `edgeKey` 去重与 TUI 展示；今后改一处必漂移。
- **建议**：把“OID = TYPE: value”的 token 化抽到 `hw/HardwareParsing.cj`（拓扑包已依赖 `hw.CommandRunner`/`SnmpDevice`，不会引入反向依赖），两边共用同一实现 + `stripQuotes`。

### [轻微][存量] `Settings_test.cj` 两个 import 未使用

- **位置**：`fprobe/src/config/Settings_test.cj:22`（`import ...hw.SnmpDevice`）、`:23`（`import ...rpc.NodeEndpoint`）
- **来源**：存量
- **判据**：review-checklist §1（未使用的 import）
- **证据**：静态确定 —— 全文件搜 `SnmpDevice`/`NodeEndpoint` 只命中这两行 import 与函数名 `invalidSnmpDeviceIsRejected`（`:353`，标识符不是类型引用）；断言只用到 `settings.snmpDevices[0].name`、`settings.rpcHealthTargets[0].port` 等成员访问，不需要类型名在作用域内。
- **描述**：无用导入会掩盖“断言是否真的用到了该类型”的意图，也会让后续重构误判依赖关系，属可维护性噪音。
- **建议**：删除这两行 import。

### [轻微][存量] `NetworkProbe.previous` 网卡基线表没有淘汰

- **位置**：`fprobe/src/collect/proc/NetworkProbe.cj:113`（定义）、`:154`（白名单分支写入）、`:183`（正常分支写入）
- **来源**：存量
- **判据**：review-checklist §5（无界容器）/ §7（缩短生命周期）
- **证据**：静态确定 —— key 取自 `/proc/net/dev` 的网卡名，只写不删；网卡消失后条目常驻（每项 `String + 8×Int64`，约 100–150B，量级小，短期不构成 OOM）。
- **描述**：在 veth/网桥频繁增删的主机上，表会按“历史出现过的网卡名”单调增长；同名网卡重建时沿用旧基线（`nonNegativeDelta` 会把负差钳成 0，不产生错误数值，但首帧速率为 0）。
- **建议**：每轮记录本轮出现的名字集合，循环结束后 `previous.remove(name)` 掉未出现的 key。

### [轻微][存量] `parseMeminfo` 假定所有值都是 kB，且任一非数字字段让整个探针失败

- **位置**：`fprobe/src/collect/proc/MemoryProbe.cj:97-120`（`:115 value * 1024`、`:116` 抛 `COLLECT`）
- **来源**：存量
- **判据**：review-checklist §11（边界/单位假设）
- **证据**：静态确定 —— `/proc/meminfo` 中 `HugePages_Total`/`HugePages_Free`/`HugePages_Rsvd`/`HugePages_Surp` 是页数（无 `kB` 后缀），同样被乘 1024；当前只消费 MemTotal/MemAvailable/MemFree/Cached/Buffers/Swap*（均为 kB），故暂无错误输出。
- **描述**：单位被当常量写进解析层；将来消费 HugePages 字段会得到放大 1024 倍的错值；反过来，内核新增一行非数字格式会让 `memory` 探针整条失败（每轮都是 error）。
- **建议**：解析时保留第二列单位（`kB` 才乘 1024，页数原样保留），非数字行 `continue`，必须字段再用 `requireValue` 单独校验。

### [轻微][存量] `parseSnmp` 对缺失表返回 `(0,0)` 并据此建立基线

- **位置**：`fprobe/src/collect/proc/NetworkProbe.cj:279-301`（`:297-299` 返回 `SnmpCounters(0, 0)`）；`retransPercent` 在 `:219-232`
- **来源**：存量
- **判据**：review-checklist §11（空值/缺失处理）
- **证据**：静态确定 —— `readOptional`（`:239-244`）把缺失文件变成空串，`parseSnmp` 解析失败即返回 `(0,0)`；`retransPercent` 第一个样本就把 `hasSnmpBaseline=true` 且 `previousSnmp=(0,0)`。
- **描述**：`/proc/net/snmp` 暂时不可读（容器 mask、权限）时，恢复后的第一帧用“自开机累计”当增量，输出的是生命周期平均重传率而不是区间值，且数值落在合理区间，很难被发现。
- **建议**：`parseSnmp` 返回 `?SnmpCounters`，缺失时**不**建立/更新基线；把“表缺失”计入 `error` 或额外字段。

### [轻微][存量] `splitWhitespace` 只按空格切分，与“按空白切分”的注释不符

- **位置**：`fprobe/src/collect/proc/ProbeParsing.cj:26-35`（`:28 line.split(" ")`）
- **来源**：存量
- **判据**：review-checklist §13（注释与实现不符）/ §11
- **证据**：静态确定 —— 只用 `' '` 分割再 `trimAscii`，不含 `\t`；现有 `/proc/*` 与 `df -P` 均为空格分隔，所以当前用例都通过。
- **描述**：遇到 tab 分隔输入（某些 `df` 变体、手工 fixture、后续新增的 `/proc` 类文件）整行只会得到一个 token，列号错位 → `requireNetInt` 抛错或解析出错误值。
- **建议**：同时按 `' '` 与 `'\t'` 切分，并把函数注释改成“按空格与制表符切分”。

### [轻微][存量] SNMP community 通过命令行参数传递

- **位置**：`fprobe/src/collect/topology/TopologyProbe.cj:179`
- **来源**：存量
- **判据**：安全性（凭据暴露面）/ `fountain-baseline.md` §6
- **证据**：静态确定 —— `snmpbulkwalk ... -c <community>` 使 community 进入子进程 argv，同机任意用户可读 `/proc/<pid>/cmdline`；`hw/SnmpProbe.cj:85` 同源（本部分范围外，一并提示）。
- **描述**：community 等价于 SNMP 读（部分设备可写）口令，fprobe 通常以 root 运行，暴露面比必要的大。
- **建议**：改用 net-snmp 配置文件（`snmp.conf` 的 `defCommunity` + `SNMPCONFPATH`）或进程内实现 GETBULK；至少确保 community 不进错误日志/`CommandResult.error`。

### [轻微][存量] 同包内 `readOptional` 两份实现

- **位置**：`fprobe/src/collect/proc/NetworkProbe.cj:239-244`（私有自由函数）vs `fprobe/src/collect/proc/DiskProbe.cj:196-201`（私有成员方法）
- **来源**：存量
- **判据**：review-checklist §2（只改位置不改语义）
- **证据**：静态确定 —— 函数体逐行相同（`reader.read` → `Some` 取值 / `None` 返回 `""`），同属 `fountain::fprobe.collect.proc`。
- **描述**：同一语义两处拷贝，未来调整“读失败是否记录原因”会漏改一处。
- **建议**：下沉到 `ProbeParsing.cj` 作为包内函数，`DiskProbe` 的成员方法改为调用它。

### [轻微][存量] 安全字符校验、时间换算与默认端口在多处重复

- **位置**：`config/Validation.cj:271-280` 与 `collect/hw/HardwareParsing.cj:52-61`（`hasWhitespace`/`hasShellMeta` **逐字相同**）；`config/Validation.cj:82-93`、`:216-234`、`:250-268` 与 `collect/proc/SystemProbe.cj:139-150`（4 份 rune 白名单循环）；`collect/Clock.cj:38`、`collect/proc/DiskProbe.cj:257`、`collect/proc/NetworkProbe.cj:236`（`DateTime.now().toUnixTimeStamp().toMilliseconds()` 3 份）；`config/AgentSettings.cj:32` 与 `config/SupervisorSettings.cj:84`（默认端口 `12323` 两处）
- **来源**：存量
- **判据**：review-checklist §2（字面量复制 / 换算复制）
- **证据**：静态确定 —— 逐条比对函数体：`hasWhitespace`/`hasShellMeta` 完全一致；4 个字符校验函数只有“允许字符集 + 前缀”不同；时间换算表达式一字不差；端口默认值两处同为 12323（agent 监听端口与 supervisor 默认节点端口必须保持一致，改一处会断）。
- **描述**：安全字符集扩充时（`hasShellMeta` 加字符）两处会漂移，配置校验与执行前校验的边界不再一致；端口常量漂移会让 supervisor 默认连不上本机 agent。
- **建议**：`hasWhitespace`/`hasShellMeta` 收进共享 util（或 `hw/HardwareParsing.cj` 供两包使用）；字符白名单抽成 `isSafeChars(name, extra: Array<Rune>)`；时间统一走 `SystemClock.nowMs()`；默认端口提成 `DEFAULT_AGENT_PORT` 常量（`AgentSettings` 引用、`SupervisorSettings` 引用）。

### [轻微][存量] `ActionWhitelist.apply` 对 ack/mute 不校验 rule 非空

- **位置**：`fprobe/src/llm/ActionWhitelist.cj:76-93`（`:80-86`）
- **来源**：存量
- **判据**：review-checklist §11（契约：返回值承诺“已执行”）
- **证据**：静态确定 —— 调用方 `runtime/SupervisorRuntime.cj:424-429` 在操作员只发“同意 mute”时把 `rule` 置为 `""`；`apply` 仍调用 `mute("", until)` 并返回 `MUTED`，`ack("")` 同理。
- **描述**：回执显示 `MUTED`/`ACKED`，实际 `AlarmEngine.mute("")` 匹配不到任何规则，属于“报告成功但无副作用”的静默失败；`muteSeconds` 也没有正负校验（配置 `probe_llmMuteSeconds` 直接传入）。
- **建议**：`ack`/`mute` 分支在 `rule.isEmpty()` 时返回 `UNSUPPORTED`（或新增 `INVALID`）；`muteSeconds <= 0` 时退化为 `NONE` 或报错。

<!-- 第 6 部分 -->

### [一般][存量] `truncate` 用字节下标截断，非 ASCII 回复必抛 `IllegalArgumentException`，整轮轮询中断

- **位置**：`fprobe/src/llm/ReplyMonitor.cj:128-134`（调用点 `:63`）
- **来源**：存量（快照模式无基线可比；文件自 16.4 任务引入，未改动）
- **判据**：review-checklist §11（边界 / 越界）+ 仓颉 `String` 语义文档
- **证据**：静态确定 —— `String` 的 `size`、下标、切片均按 UTF-8 **字节**计；`operator func [](Range<Int64>)` 明确「起止点必须位于字符边界上，否则抛出 `IllegalArgumentException`」（`cangjie_runtime/stdlib/doc/libs/std/core/core_package_api/core_package_structs.md:9383`，异常条目见 `:9403`）。`raw[0..120]` 的右端点 120 由常量写死，与字符边界无关。
- **描述**：非法回复日志路径 `logWarning('渠道 ${name} 收到非法回复: ${truncate(raw)}')` 在 `pollOnce` 的渠道循环里、且不在任何 `try` 内。只要某条非 JSON 回复的前 120 字节末落在某个多字节字符（中文/emoji）中间，`truncate` 抛异常 → 本轮 `for ((name, channel) in channels)` 直接中断，后续渠道本轮不再轮询；异常由 `SupervisorRuntime.llmLoop` 的 `catch (e: Exception)`（`SupervisorRuntime.cj:239-245`）吞成一条「回复轮询失败」。该消息也走不到 `store.markHandled`，若渠道不标已读（设计文档 `doc/spec/add-fprobe/design.md:605` 明确提到 IMAP 可能重复投递），每轮都会再次命中同一条坏消息，形成「每轮都失败一次」的稳定退化。
- **建议**：按字符边界截断，例如 `if (raw.size > 120) { let runes = raw.toRuneArray(); String(Array<Rune>(min(120, runes.size)) {i => runes[i]}) + "..." }`；或退化为按 `\u{FFFD}` 安全替换（`String.fromUtf8` 前用 `String.checkUtf8Encoding` 校验）。同时把 `truncate` 调用挪进渠道级 `try`，使单条坏消息不影响其余渠道。

### [一般][存量] `PromptBuilder.build` 无规模上限：全节点 × 22 指标 × 20 历史点一次性拼进单个提示词

- **位置**：`fprobe/src/llm/PromptBuilder.cj:30-106`（节点循环 `:39`，历史循环 `:93-103`）
- **来源**：存量
- **判据**：review-checklist §5（一次性物化 / 无界容器）+ §14.1（只处理部分输入规模的半成品）
- **证据**：静态确定（无任何上限判断）+ 需实测（触发规模取决于 `probe_nodes` 条数）
- **描述**：`build` 对 `states` 全量展开：每个节点先按 `ProjectionCatalog.all()`（22 个指标，`src/tui/RenderPlan.cj:66-115`）逐 agent 求值，再对 22 个指标各输出最多 `historyPoints`（生产写死 20，`SupervisorRuntime.cj:373`）个历史点。单节点约 22 行指标 + 22 行历史（每行 ≈150-200 字节）≈ 3.5 KB；1000 个节点即 ≈3.5 MB 提示词，远超常见上下文窗口与请求体上限，且按 token 计费会线性放大成本。`PromptBuilder` 是 `public` API，`states` 由调用方任意传入，内部没有任何长度/条数上限，也没有截断或摘要策略，失败只表现为上游 4xx 或截断，而不是本地拒绝。
- **建议**：在 `build` 内加两级上限：节点数上限（如 50，超出按告警相关度/状态取前 N）与字符预算（如 32 KB，超出停止追加并写「…已省略 N 个节点」）；`historyPoints` 由 `probe_historyPoints` 或新配置项派生，而不是硬编码 20。上限值写常量或配置，超限走「省略」而不是抛异常。

### [一般][存量] 每条告警 `spawn` 一次完整 LLM 分析，无 single-flight / 并发上限，告警风暴会放大成 N×R 次全量提示词请求

- **位置**：`fprobe/src/llm/ProbeAdvisor.cj:77-82`（`analyzeAlarm`）、`:92-107`（`analyze`）
- **来源**：存量
- **判据**：review-checklist §12.1（有界性 / 异步语义）+ §6.3（并发串行与并行度上限）
- **证据**：静态确定（`ProbeAdvisor` 无在途标记、无队列、无去重；调用方每事件一个 `spawn`）
- **描述**：`SupervisorRuntime.cj:143-146` 对**每个** `AlarmEvent` 执行 `spawn {=> advisor.analyzeAlarm(event, stateStore.all(), historyStore)}`，`ProbeAdvisor` 侧没有任何「已在分析中则跳过/合并」的逻辑，也没有并发度限制。一次 `alarm.evaluate(states)` 若命中 N 个节点 × R 条规则，即刻产生 N×R 个并发 `analyze`，每个都调用上一节的 `PromptBuilder.build`（全量节点 × 22 指标）并各自发一次 HTTP。后果是：上游 429/超时（每条错误只记一条 ERROR，用户看到的是「建议变少」而非「被限流」）、瞬时线程与内存放大、token 成本按 N×R 倍增长。`LlmTrigger.ALARM` 是本模块默认触发方式（`SupervisorRuntime.cj:354` 默认 `"alarm"`），该路径是主路径。
- **建议**：在 `ProbeAdvisor` 内加单飞标记（`AtomicBool.compareAndSwap`，分析中直接 return 并记一次 INFO），或改为「事件入有界队列（容量 1-4）+ 单消费者」；如需保留多事件语义，把同批次事件合并成一次 `events` 数组传入（`analyzeInterval` 已支持 `events:` 参数）。补充并发压力用例：20 线程同时 `analyzeAlarm`，断言实际 `client.chat` 调用次数 ≤ 1。

### [一般][存量] 报告把「节点 × 22 指标」张 SVG 全量物化后再整串复制一次，无图表上限

- **位置**：`fprobe/src/report/ReportBuilder.cj:97-133`（图表循环）、`:172-173`（`joinLines` + `toArray()`）
- **来源**：存量
- **判据**：review-checklist §5（一次性物化 / 无界容器）、§7（去副本）
- **证据**：静态确定（无图表数量/总字节上限，全部驻留 `html` 数组后一次拼成 `String`，再 `toArray()` 复制一份同尺寸字节数组）；单张 SVG 尺寸需实测
- **描述**：`build` 对每个 `state` 遍历 22 个投影，凡有历史就渲染一张内联 SVG 并追加进 `html`（`Array<ChartSpec>` 与 `String` 同时存活）。节点数 N 时图表数 = 22×N，且没有任何上限或抽样；随后 `joinLines(html, "")` 以 `+=` 逐行拼接（O(total²) 前缀复制），最后 `htmlText.toArray().size` 为了打印字节数又把整份 HTML 复制成一个 `Array<Byte>`。按 100 节点、每张 SVG 3 KB 估算，正文 ≈6.6 MB，峰值同时存在「各行字符串 + 拼接中间串 + 完整 HTML + 完整字节副本」四份形态。
- **建议**：改为 `StringBuilder` 单次构造（消除 O(n²) 与中间串），日志改用 `htmlText.size`（`String.size` 即 UTF-8 字节数，`core_package_structs.md` prop size）；对图表数/总字节设上限（如每节点最多 6 张、正文 ≤8 MB），超出退化为纯文本行并记一条 WARN。若必须全量，考虑把图表分页或改为可下载附件（当前 `ReportJob.runOnce` 明确 `attachments: []`）。

### [轻微][存量] `stripFence` 只认首行围栏，模型带前导说明时结构化建议整体丢失

- **位置**：`fprobe/src/llm/AdviceParser.cj:50-65`
- **来源**：存量
- **判据**：review-checklist §11（语义与承诺不符 / 边界未覆盖）、§14.1（只处理部分输入）
- **证据**：静态确定 —— 只有 `lines[0].trimAscii().startsWith("```")` 才剥离；`"以下是分析：\n```json\n{...}\n```"` 这类输出直接走 `JsonValue.fromStr` 失败分支
- **描述**：失败后按类注释的既定契约把整段原文当 `summary` 返回（`AdviceParser.cj:47`），因此不会崩溃，但 `solutions` 为空 → `ActionWhitelist` 无动作可执行、`formatAdvice` 只发出一大段含 Markdown 围栏的原文。提示词已要求「只输出 JSON」，但模型不遵守时的退化路径比预期窄（剥围栏只覆盖严格格式）。
- **建议**：改为在整段文本里找第一个 ` ``` ` 与最后一个 ` ``` `（`indexOf` / `lastIndexOf`），取其间内容；或在解析失败时再尝试「截取第一个 `{` 到最后一个 `}`」作为二次兜底。补一条用例：前导说明 + 围栏 + JSON。

### [轻微][存量] 拓扑渲染成功的分支里 `case None => text.add("拓扑不可用")` 逻辑不可达

- **位置**：`fprobe/src/report/ReportBuilder.cj:158-169`（`:164`）
- **来源**：存量
- **判据**：review-checklist §1（恒假分支）
- **证据**：静态确定 —— `topologySvg` 只在 `match (topology) { case Some(sample) => ... }` 分支里被赋成 `Some`（`:145-157`），故进入 `case Some(svg)` 时 `topology` 必为 `Some`，内层 `case None` 永不执行
- **描述**：死分支，且它与外层 `case None`（`:166-168`）文案相同，读代码时容易误以为存在两种「拓扑不可用」来源。
- **建议**：把 `Some(sample)` 直接与外层 match 合并（`case Some(sample) => match (topologyRender(sample)) { ... }`），删掉内层对 `topology` 的二次匹配；或在 `Some(svg)` 分支用 `sample.devices.size` 时改为携带 `sample` 的元组。

### [轻微][存量] `parse` 只校验 `id` 非空，`from` 为空时仍向空地址回信

- **位置**：`fprobe/src/llm/ReplyMonitor.cj:107-126`（校验）、`:70-72`（回信）
- **来源**：存量
- **判据**：review-checklist §11（空值未处理）
- **证据**：静态确定 —— `ChannelMessage.from` 默认 `""`（`src/channel/ChannelMessage.cj:22`），`{"id":"x"}` 也能 `populate` 成功并通过 `message.id.isEmpty()` 检查
- **描述**：随后 `isAuthorized(conf, "")` 为 false，走未授权分支 `channel.send(UNAUTHORIZED_REPLY, [""])`，把空字符串当收件人交给渠道（邮件渠道可能抛异常并被 catch 成 WARN，也可能发给空地址失败）。同时该 `id` 被标记已处理，看不出异常。
- **建议**：`parse` 里同时要求 `id` 与 `from` 非空（`body` 允许为空），否则按「非法回复」记 WARN 并跳过，不进入授权/回信分支。

### [轻微][存量] `ChartSelector.SUPPORTED_TYPES` 是 public 可变数组，外部可改写全局类型表

- **位置**：`fprobe/src/report/ChartSelector.cj:27`
- **来源**：存量
- **判据**：review-checklist §10（封装 / 共享可变状态）
- **证据**：静态确定 —— `public static let SUPPORTED_TYPES = ["line", "area", "bar"]`，`let` 只禁止重新赋值，`Array` 元素仍可写
- **描述**：任何下游代码 `ChartSelector.SUPPORTED_TYPES[0] = "sankey"` 都会改变本进程内所有 `select` 的判定与 `supports` 的返回值，且无任何日志。README 把它列为公开常量（`fprobe/README.md:535`），却无法保证不变。
- **建议**：改为 `public static let SUPPORTED_TYPES: Array<String> = [...]` 的内部只读封装：私有数组 + `public static func supportedTypes(): Array<String>` 返回副本，`supports` 内部用私有数组。

### [轻微][存量] 测试替身 `FakeLlm.prompts` 只写不读

- **位置**：`fprobe/src/llm/LlmTestSupport_test.cj:29`（声明）、`:39`（`prompts.add`）
- **来源**：存量
- **判据**：review-checklist §1（读了不用）
- **证据**：静态确定 —— 全仓 `grep "\.prompts\b"` 在 `fprobe` 内零命中（唯一命中都在 `f_llm`/`f_mcp`，与 `FakeLlm` 无关），`prompts` 只被 `add` 追加、从未读取；每次 `chat` 都会多留一条提示词副本
- **描述**：注释写「记录每次提示词」，但没有任何用例断言提示词内容；属于写而不读的残留状态（同文件 `LlmFakeHistory` / `FakeReplyChannel` 的字段都有读取点，可排除误报）。
- **建议**：要么在 `PromptBuilder` 相关用例里断言 `prompts[0].contains(...)`（顺带替代 `PromptBuilder_test` 的重复断言），要么删除该字段。

### [轻微][存量] `analyze` 只把 `client.chat`/`onAdvice` 包进 `try`，`PromptBuilder.build` 的异常会逸出到无 `try` 的 `spawn`

- **位置**：`fprobe/src/llm/ProbeAdvisor.cj:92-107`（`:94` 在 `:95` 的 `try` 之外）
- **来源**：存量
- **判据**：review-checklist §11（错误处理缺失 / 与类注释契约不符）
- **证据**：待确认 —— 类注释承诺「模型异常/空响应只记录 ERROR，不影响调用方的拉取、告警与报告」，但提示词构造失败（`ProjectionCatalog`/`history.values`/`spawn` 内未捕获异常）不在该 `try` 内；仓颉 `spawn` 内未捕获异常的具体后果（线程静默结束还是打印）本轮未实测
- **描述**：`SupervisorRuntime.cj:145`/`:250` 的 `spawn` 内没有 `try`，`build` 抛出的异常不会被 `logError` 记录，失败原因不可见；好在每轮重新 `spawn`，不会永久停摆。
- **建议**：把 `PromptBuilder.build` 移入 `try`（错误文案改为「提示词构造失败」），或在 `spawn` 侧统一 `try/catch` 并 `logError`。

### [轻微][存量] 回复状态直接覆盖写文件，非原子落盘；每条消息全量重写一次

- **位置**：`fprobe/src/llm/ReplyStateStore.cj:96-112`（`persist`）、`:51-58`（`markHandled` 每次落盘）
- **来源**：存量
- **判据**：review-checklist §11（资源/持久化对称性）、§13 契约（类注释承诺「重启不重复」）
- **证据**：静态确定 —— `File.writeTo(path, array.toString().toArray())` 直接覆盖目标文件，没有临时文件 + rename
- **描述**：写入中途崩溃/断电会留下截断的 JSON，下次 `load` 走 `catch` 分支 `ids.clear()` 按空集合启动（`:81-87`），此前所有已处理 id 丢失 → 渠道重投的旧回复会被再执行一次（例如重复 mute、重复触发报告）。窗口很小（≤1000 条 id，约 20 KB），但后果是「已授权的动作重复执行」。
- **建议**：写 `path + ".tmp"` 后 rename 覆盖；`markHandled` 可改为「内存累加 + 定时/批量落盘」以减少整文件重写次数（回复频率低，此项优先级低于原子性）。

### [轻微][存量] 4 处语义相同的「分隔符拼接」循环重复实现

- **位置**：`fprobe/src/llm/AdviceParser.cj:67-78`（`join`）、`fprobe/src/llm/PromptBuilder.cj:119-130`（`joinNumbers`）、`fprobe/src/llm/PromptBuilder.cj:132-143`（`joinLines`）、`fprobe/src/report/ReportBuilder.cj:205-216`（`joinLines`）
- **来源**：存量
- **判据**：review-checklist §2（跨文件 / 只改类型名）
- **证据**：静态确定 —— 四个函数体逐行对齐：`var result = ""; var first = true; for (x in xs) { if (!first) { result += sep }; result += x; first = false }`，差异只有集合类型（`ArrayList<String>` / `Array<Float64>`）与元素是否先 `toString()`
- **描述**：语义完全一致（首元素前不加分隔符、空集合得空串），但分散在两个包（`fprobe.llm` / `fprobe.report`）。std 已提供 `String.join(Array<String>, delimiter!)`（`core_package_structs.md:6454`）；同模块 `src/tui/FprobePainter.cj:314` 还有第 5 份（范围外提示）。这类实现漂移会表现为「某处改了分隔符规则，其余没改」。
- **建议**：`fprobe.llm` / `fprobe.report` 共用一份工具函数（放模块内 util，或直接用 `StringBuilder` + `String.join`），`joinNumbers` 保留但改为内部调用同一实现。注意差异点：`ReportBuilder` 传的分隔符是 `""`，`PromptBuilder` 是 `"\n"`/`", "`，参数化即可，不改变行为。

### [轻微][存量] 3 处「JSON 文本 → `DataObject.populate`」样板重复

- **位置**：`fprobe/src/llm/AdviceParser.cj:31-46`、`fprobe/src/llm/ReplyMonitor.cj:107-126`
- **来源**：存量
- **判据**：review-checklist §2（跨层复制 / 换控制流）
- **证据**：静态确定 —— 三处（含范围外的 `src/runtime/SupervisorRuntime.cj:330-338`）都是同一串：`JsonValue.fromStr` → 判 `case object: JsonObject` → `DataObject<T>.populate(object.toData())` → `case None` 兜底 + `catch Exception/Error`；本包已有 `jsonToData(text): ?Data`（`src/collect/JsonData.cj:28`）做前半段，但两处都绕过它直接调 `JsonValue`
- **描述**：同一套「容错解析」写了三遍，兜底策略已经出现漂移：`AdviceParser` 静默吞掉、`ReplyMonitor` 转成 `None` 让调用方写 WARN、`SupervisorRuntime` 转成 `continue` 不记日志。判据差异属于业务要求，但「解析 + 转 DTO」不需要各写一份。
- **建议**：在 `fprobe.collect` 补一个 `parseDataObject<T>(text: String): ?T`（内部复用 `jsonToData` + `DataObject.populate`），三处改为调用它并保留各自的兜底文案；`AdviceParser` 的「退回原文 summary」与 `ReplyMonitor` 的「记 WARN」作为调用方策略保留。

### [轻微][存量] 两份 HTML 转义表重复，转义字符集完全一致

- **位置**：`fprobe/src/report/ReportBuilder.cj:218-220`（`escape`）
- **来源**：存量
- **判据**：review-checklist §2（字面量复制）
- **证据**：静态确定 —— 与 `src/channel/EmailAlarmChannel.cj:182-188` 的 `escapeHtml` 转义序列相同（`&`→`&amp;`、`<`→`&lt;`、`>`→`&gt;`、`"`→`&quot;`，顺序也一致），只是一处链式 `replace`、一处逐步赋值（后者为范围外文件，仅作证据）
- **描述**：报告正文与邮件正文各有一套转义，任一新增字符（如 `'`）时容易只改一处，导致两处输出不一致。
- **建议**：抽到模块内 `util`（如 `fprobe/channel/HtmlText.cj` 的 `escapeHtml`）供两处共用，并补一条「`'` 与 `&amp;` 双转义」的用例防回归。

### [轻微][存量] README 的 `ChartSpec` 条目漏掉 `fromValues`

- **位置**：`fprobe/src/report/ChartSpec.cj:75`（`public static func fromValues`）；承诺源 `fprobe/README.md:536`（条目只列 `jsonObject`）
- **来源**：存量
- **判据**：review-checklist §14.2（公开 API 未文档化）
- **证据**：静态确定 —— `grep -n "fromValues" fprobe/README.md fprobe/README_en.md` 零命中；`ReportBuilder` 生成图表的唯一入口就是它（`ReportBuilder.cj:116`）
- **描述**：README「其他公开 API」是索引式清单，`ChartSpec` 只列了序列化方法，使用者按文档无法知道「如何从一组数值构造图表描述」，只能去读源码。
- **建议**：补 `fromValues`（func）到 `README.md:536` 与 `README_en.md` 对应条目；若要更完整，补一句参数含义（标签自动为 1..N）。

<!-- 第 7 部分 -->

### [严重][存量] 两个 `NodeStateStore` 实例：LLM 周期分析永远读到空节点状态

- **位置**：`fprobe/src/runtime/SupervisorRuntime.cj:93`（字段 `store`）、`:110`（局部 `stateStore`）、`:204`（把字段传给 `llmLoop`）、`:250`（`store.all()`）
- **来源**：存量（`git blame -L 105,112` → `1878dd0f2d`，2026-11-09；快照无 diff）
- **判据**：review-checklist §11（契约与实现不符 / 逻辑错误）、§1（读了不用）
- **证据**：静态确定 —— 构造期创建了两个独立实例：字段 `store`（:93）与局部 `stateStore`（:110）。`PollLoop`（:154）、`ReportJob` 的 builder（:310）、`RenderLoop`（:184-185）、告警回调（:145）全部使用**局部** `stateStore`；只有 `start()` 把**字段** `store` 传给 `llmLoop`（:204），而字段实例从未被 `update()` 过（全文件 `store` 只在 :93 与 :204/:250 出现）。
- **描述**：`probe_llmTrigger` 含 `interval` 时，`llmLoop` 每 `probe_llmIntervalMs` 调 `advisor.analyzeInterval(store.all(), ...)`（:250），传入的 `states` 恒为 `[]`。`PromptBuilder.build` 只在 `for (state in states)` 里拼节点摘要（`fprobe/src/llm/PromptBuilder.cj:39`），于是提示词只剩「节点摘要：」一行空内容。README 承诺「告警触发或周期到达时，把节点状态、告警事件与历史点组装成提示词」（`fprobe/README.md:416`）在 period 路径上不成立：模型看不到任何节点数据，周期分析退化为无输入推理，且无任何报错或日志。
- **建议**：删除 :93 的字段 `store`，把 :204 改为传 `stateStore`（或把 :110 改为 `this.store = NodeStateStore()` 并统一用字段），并补一条用例：注入非空 `NodeStateStore`，断言 `analyzeInterval` 收到的 `states` 非空。

### [一般][存量] 告警渠道发送同步跑在采集线程与定时任务线程上

- **位置**：`fprobe/src/runtime/SupervisorRuntime.cj:142`（`dispatcher.dispatch(event.format())`）、`fprobe/src/report/ReportJob.cj:106`（`sender.sendRich(...)`）
- **来源**：存量
- **判据**：review-checklist §12.2 / §6.2（主路径上的阻塞 I/O）、§11（资源与延迟）
- **证据**：静态确定 —— `PollLoop.tick()` 采集完成后在**同一线程**调 `evaluator`（`fprobe/src/supervisor/PollLoop.cj:156`），该 lambda 里 `alarm.evaluate(states)`（:158）→ `AlarmEngine.emit`（`AlarmEngine.cj:276`，直接 `onEvent(event)`，无 `spawn`）→ 回调内 :142 `dispatcher.dispatch`；`ChannelDispatcher.dispatch` 对每个启用渠道同步调 `channel.send`（`ChannelDispatcher.cj:50-58`、`79-88`）。`ReportJob.runOnce` 同理运行在 Ticktock 的 tick 线程上（`Ticktock.cj:270-289`）。
- **描述**：一次告警的 SMTP 往返（连接、鉴权、投递，最坏到超时）会把整个拉取 tick 卡住，期间所有节点都不采集、不评估；报告发送期间 Ticktock 线程上的其它任务（当前只有本任务）一起排队。业务上「告警不影响采集」的隔离只对异常生效（`AlarmEngine.emit` 吞异常），对**耗时**不生效。
- **建议**：把渠道发送移到独立的有界队列消费者（或 `spawn` + 有并发上限的发送池），回调只做入队；报告发送同样交给同一发送池，Ticktock 任务只负责生成与入队。若坚持同步发送，至少给渠道设置连接/写超时，并在 `dispatch` 前后各打一条耗时日志作为基线。

### [一般][存量] LLM 调用按事件与间隔无上限 `spawn`，无并发闸门

- **位置**：`fprobe/src/runtime/SupervisorRuntime.cj:145`（每个告警一个 `spawn`）、`:250`（每个间隔一个 `spawn`）
- **来源**：存量
- **判据**：review-checklist §5（一次提交全量任务 / 无界增长）、§6.3（并发节流失控）、§12.1（异步语义）
- **证据**：静态确定 —— 两处都是「来一个事件就 `spawn` 一个长阻塞调用」，没有在飞计数、没有信号量、没有去重（同一节点同一规则在 cooldown 窗口内会由 `AlarmEngine` 抑制，但不同规则/不同节点的告警会并行累加）。`ProbeAdvisor.analyze` 内部是同步 `client.chat(prompt)`（`ProbeAdvisor.cj:92-108`），单次可长达 HTTP 超时。
- **描述**：LLM 端点变慢或不可达时，线程数随告警条数线性增长；`probe_llmIntervalMs` 小于单次调用耗时（默认 300000ms，但可配成 60000，见 README:410 的排查建议）时，间隔任务也会持续叠加。没有上限就没有背压，最坏情况表现为线程暴涨与内存增长。
- **建议**：加一个容量为 1（或可配）的信号量/在飞标记：`if (!llmBusy.swap(true)) { spawn { try {...} finally { llmBusy.store(false) } } }`；间隔任务与告警任务共用同一个闸门，超出直接丢弃并记一条 WARN（丢弃比排队更符合「分析是尽力而为」的定位）。

### [一般][存量] agent 初始化链的异常被 `Future` 吞掉，启动失败无日志

- **位置**：`fprobe/src/runtime/AgentRuntime.cj:99-105`
- **来源**：存量
- **判据**：review-checklist §3（静默吞异常）、§12.1（`Future` 异常被吞）
- **证据**：静态确定 —— `spawn {=> current().start() }` 的 `Future` 既没有 `get()` 也没有 `try/catch`，`serve()` 只 `get()` 了采集线程的 `collector`（:110）。
- **描述**：任一 initializer 的 `start()` 抛异常（RPC 端口被占、配置缺失等），异常只存在于无人观察的 `Future` 里：进程继续以「已启动」状态运行，RPC 服务器没起来，agent 端口不可达，而 stderr 一行提示都没有。这与 `main.cj:113-121` 里「启动失败: …」的兜底期望矛盾——异常根本回不到 `runAgent()`。
- **建议**：`spawn` 里包 `try { current().start() } catch (e) { eprintln('fprobe agent: 初始化失败: ${e.message}') ; running.store(false) }`，让主循环退出并返回非 0；或改成「先 `spawn` 全部、再统一 `get()` 汇总」，但注意 RPC server 是阻塞的，只能取「首个失败即退出」的语义。

### [一般][存量] `NodeRpcTransport` 在持锁期间做阻塞网络传输

- **位置**：`fprobe/src/rpc/NodeRpcTransport.cj:110-137`（`synchronized(lock)` 包住 `active.transfer(message, timeout)`，:116）
- **来源**：存量
- **判据**：review-checklist §12.2（锁内 I/O）、§6.2（临界区含阻塞动作）
- **证据**：静态确定 —— 临界区包含 `buildRequest`、`requireClient`（可能建连）与 `transfer`（最长 `timeout`，默认 3000ms）；`close()`（:103-107）也要拿同一把锁。
- **描述**：这把锁同时保护「连接引用」和「一次完整 RPC」。生产上每节点只有一个拉取线程，锁竞争不严重；但 `close()`（`SupervisorRuntime.close()` → `TransportSource.close()`）会被一次进行中的 `collect()` 阻塞到超时，退出流程因此最长多等一个 `nodeTimeoutMs`；若将来有第二个调用者（如手动刷新、健康检查）接进来，两者会完全串行。属于结构性风险，不是实测热点。
- **建议**：把「取/建连接」放进临界区，`transfer` 在锁外执行；连接身份用版本号或 `AtomicOptionReference` 校验（传输失败时用 CAS 只丢弃自己那一代连接，避免误关别的线程刚建好的连接）。

### [一般][存量] `ReportJob.runOnce` 只兜住发送异常，构建异常冒泡到调用方

- **位置**：`fprobe/src/report/ReportJob.cj:103-112`（`let draft = builder()` 在 `try` 之外）
- **来源**：存量
- **判据**：review-checklist §11（错误处理不完整）、§3（失败路径不记录）
- **证据**：静态确定 —— `try` 从 :105 开始，`builder()` 在 :104。
- **描述**：类注释承诺「发送失败只记录 ERROR，下一周期继续尝试」。构建失败（如 `ReportBuilder.build` 里历史/拓扑解析抛错）则绕过 `logError`：cron 路径上异常被 `Ticktock.executeOne` 的 `catch (e: Exception)` 记成一条与报告无关的 WARN（`f_ticktock/src/Ticktock.cj:286-289`）；LLM 的 `report` 动作路径上异常抛进 `ReplyMonitor.pollOnce` 的 catch，最终只留下「回复轮询失败」一条日志，报告没生成这件事被掩盖。
- **建议**：把 `builder()` 一并纳入 `try`，错误文案区分「报告生成失败」与「报告发送失败」；或让 `builder` 返回 `Result`/`?ReportDraft`，`None` 时记 INFO 跳过。

### [一般][存量] 两套「kind → 主指标」提取口径并存且不一致，`MetricExtractor` 生产代码零引用

- **位置**：`fprobe/src/runtime/RuntimeSupport.cj:46-106`（`MetricExtractor`）vs `fprobe/src/tui/RenderPlan.cj:67-116`（`ProjectionCatalog`）
- **来源**：存量
- **判据**：review-checklist §2（跨文件重复逻辑 + 行为漂移）、§1（对外可达 public，仅记「仓内仅测试引用」）
- **证据**：静态确定 —— 全仓搜 `MetricExtractor` 只命中定义处与 `fprobe/src/runtime/SupervisorRuntime_test.cj:70-73`；生产链路的 TUI/报告/告警/提示词都走 `ProjectionCatalog.all()`（`NodeHistoryStore.cj:62`、`ReportBuilder.cj:97`、`PromptBuilder.cj:49`、`AlarmEngine` 的 kind 判定）。两边语义已经漂移：`disk` 取 `mounts[0].usedPercent` vs 目录里的 `mounts[*].usedPercent` 取 Max；`network` 取 `interfaces[0].rxBytesPerSec` vs 目录里的 Sum；`service` 返回 `targets` 条数 vs 目录里的 `maxLatencyMs`。
- **描述**：README 把 `MetricExtractor.primary` 列为公开 API（`fprobe/README.md:558`），但同一「每个监控项一个主数值」的职责已有 `ProjectionCatalog` + `MetricProjection.evaluate` 实现。后续任何一处指标路径调整都会让另一处静默失真；而当前唯一消费者是测试，等于测试在守护一份生产不用的口径。
- **建议**：二选一——(a) 删除 `MetricExtractor` 并同步删 README:558（破坏性变更，需用户拍板）；(b) 让它内部转调 `ProjectionCatalog`（`kind` → `MetricSpec` → `evaluate`），把「取首元素」这类差异显式做成参数。无论哪种，都要先确认没有下游项目引用（对外可达 public）。

### [一般][存量] `SupervisorRuntime.start()` 检查-然后-写入，可能重复启动轮询/渲染线程

- **位置**：`fprobe/src/runtime/SupervisorRuntime.cj:191-196`
- **来源**：存量
- **判据**：review-checklist §12.1（检查-然后-写入非原子）
- **证据**：静态确定 —— `if (running.load()) { return }` 与 `running.store(true)` 之间没有同步；两次并发 `start()` 都能读到 `false`，随后各 spawn 一份 `poll.run()` / `loop.run()` / `llmLoop`。仓内 `AtomicBool.swap` 已在别处使用（如 `fdbm/src/server/FdbmServer.cj:151`），方案可行。
- **描述**：当前只有 `SupervisorApp.start()` 一处调用，实际触发概率低；但一旦重复进入（重连/信号钩子重入/未来加「重新开始」），`PollLoop` 会有两条 tick 循环同时 `store.update`，`llmLoop` 双份分析，且 `stop()` 只能停其中一份（`running` 是共享的，反而都会停，但线程已多出来）。
- **建议**：改 `if (running.swap(true)) { return }`。

### [一般][存量] README 未覆盖本部分两个对外入口的主方法

- **位置**：`fprobe/README.md:567`（`NodeRpcTransport` 只列 `SERVICE_TYPE`、`close`）、`fprobe/README.md:524`（`AgentRuntime` 只列 `prepare`/`serve`/`snapshot`/`stop`）；对应代码 `fprobe/src/rpc/NodeRpcTransport.cj:85-100`、`fprobe/src/runtime/AgentRuntime.cj:69-71`
- **来源**：存量（README 属其它分部分文件，本部分只做符号级交叉核对）
- **判据**：review-checklist §14.2（公开 API 未文档化，须点名符号）
- **证据**：静态确定 —— 全文检索 `README.md` 只有 :567 一处提到 `NodeRpcTransport`，`collect`/`kinds` 未出现；`AgentRuntime.kinds()` 在 :524 的成员列表里缺失（同节其它成员均在列）；:453 的 `kinds()` 指的是 RPC 契约 `ProbeRPC.kinds`，不是这两个类的方法。
- **描述**：`NodeRpcTransport.collect()`/`kinds()` 是该类存在的唯一用途（supervisor 拉取入口），README 只写了常量和 `close`，按文档用不起来；`AgentRuntime.kinds()` 则是导出但既无文档也无生产调用（见下一条可见性建议）。
- **建议**：把 `collect`、`kinds`、三个构造重载补进 :567 条目；`AgentRuntime.kinds` 补进 :524 或收窄可见性。若其它分部分已就 README 整体提过同类问题，合并时去重。

### [轻微][存量] `HistoryRing.append` 用 `remove(at: 0)` 当队列头，每次追加 O(capacity)

- **位置**：`fprobe/src/supervisor/HistoryRing.cj:42-47`
- **来源**：存量
- **判据**：review-checklist §6.4（`remove(at: 0)` 当队列头）
- **证据**：静态确定 —— 容量满时 `points.remove(at: 0)` 触发整段搬移。
- **描述**：容量来自 `SupervisorSettings.historyPoints`（默认 60，`SupervisorRuntime.cj:111`），每节点每指标每次 tick 搬移 ≤60 个 `Float64`；节点×指标量级为「10 节点 × 15 指标 × 每 5s 一次」，绝对开销很小，不构成缺陷，只是实现方式落后于「环形下标」。无基线数据，收益未量化。
- **建议**：改为固定 `Array<Float64>(capacity, repeat: 0.0)` + 写指针 + `count`，`values()` 按写指针拼接返回；注意 `values()` 仍需返回副本，语义不变。与 `NodeHistoryStore` 的锁配合方式不变。

### [轻微][存量] 插入排序在三处重复实现（同文件两处几乎逐行相同）

- **位置**：`fprobe/src/report/TopologyRenderer.cj:74-92`（按 `name`）与 `:94-118`（按 `linkKey`）；同类实现另见 `fprobe/src/supervisor/NodeStateStore.cj:64-78`（按 `node`）
- **来源**：存量
- **判据**：review-checklist §2（只换比较表达式的重复逻辑）
- **证据**：静态确定 —— 三段函数体的 `while (i < result.size) { current = result[i]; j = i-1; while (j>=0 && key(result[j]) > key(current)) {...} }` 完全对齐，只有比较键与元素类型不同。
- **描述**：这是「同一种排序手写三遍」，任一处改成不稳定排序或改比较键（如忽略大小写）都不会同步到另一处。`TopologyRenderer` 两处还额外做了 `ArrayList → toArray()` 的无谓中转（复制两次）。
- **建议**：抽一个模块内 `func sortedBy<T>(values: Array<T>, key: (T) -> String): Array<T>`（比较键返回 `String` 即可覆盖三处），或用 `std.sort` 的比较器版本；抽取后补一条「重复设备名 / 重复链路」的等价性用例，保证输出字节不变（`TopologyRenderer_test.sameInputProducesSameSvg` 已覆盖确定性）。

### [轻微][存量] `AgentRuntime` 每轮都重复发布一次快照

- **位置**：`fprobe/src/runtime/AgentRuntime.cj:88-89`、`:92-97`
- **来源**：存量
- **判据**：review-checklist §2（重复逻辑）、§11（无效操作）
- **证据**：静态确定 —— `ProbeRunner.tick()` 内部已经 `store.replace(snapshot)` 并返回同一快照（`fprobe/src/collect/ProbeRunner.cj:98-99`），而 `AgentRuntime` 拿到返回值后又 `store.replace(first)`；循环体里 `store.replace(runner.tick())` 同理。
- **描述**：同一快照被写两次（两次拿同一把 `SnapshotStore` 锁），功能无影响，但会让人误以为 `tick()` 只返回不发布，后续改动容易踩空。
- **建议**：删掉 `AgentRuntime` 的两处 `store.replace`，只保留 `runner.tick()`；若要保留「tick 不发布」的语义，则反过来改 `ProbeRunner.tick`。

### [轻微][存量] cron 空值判断在装配层与任务层各写一遍

- **位置**：`fprobe/src/runtime/SupervisorRuntime.cj:302-305` 与 `fprobe/src/report/ReportJob.cj:85-88`
- **来源**：存量
- **判据**：review-checklist §2（字面量/校验复制）
- **证据**：静态确定 —— 两边都是 `Config.getString("probe_reportCron") ?? ""` + `trimAscii()` + `isEmpty()`；装配层返回 `None` 不创建任务，任务层 `register()` 返回 `false`。
- **描述**：生产路径上 `ReportJob.register()` 的空 cron 分支永远走不到（只有测试 `emptyCronDoesNotRegister` 覆盖）。两处默认值独立演进时会出现「装配层认为关闭、任务层认为非法」之类的错位。
- **建议**：保留任务层的守卫（它是 public 契约），装配层改为「只要拿到 cron 就构造并 `register()`，由 `register()` 的返回值决定是否记录 INFO」；或抽一个 `ReportCron.normalize()` 供两边共用。

### [轻微][存量] `dropClient` 静默吞掉 close 异常

- **位置**：`fprobe/src/rpc/NodeRpcTransport.cj:164-175`（:167-171 `catch (_: Exception) { () }`）
- **来源**：存量
- **判据**：review-checklist §3（静默吞异常）
- **证据**：静态确定 —— 关闭失败既不上报也不记录；`NetClientTransport.close()` 直接转 `Client.close()`（:50-52）。
- **描述**：清理路径吞异常本身可接受（避免二次失败掩盖原因），但完全无痕会让「句柄泄漏」类问题无法定位：反复重连时若 `close()` 一直失败，fd 只增不减却没有任何信号。
- **建议**：保留吞异常，但加一条 `eprintln`/`logWarning`（带节点名与方法名），或统计一个「关闭失败次数」计数暴露到健康项。

### [轻微][存量] 仅测试引用的内部/公开入口（可见性建议，不作死代码）

- **位置**：`fprobe/src/runtime/SupervisorRuntime.cj:509-513`（`static func buildDispatcher()`，无修饰符＝包内可见）、`fprobe/src/rpc/ProbeRPCImpl.cj:50-53`（`public static func reset()`，注释自述「仅供测试使用」）
- **来源**：存量
- **判据**：review-checklist §1（「非 public 符号只在 `*_test.cj` 命中」→ 可见性建议；对外可达 public 不算死代码，只记录引用情况）
- **证据**：静态确定 —— 全仓 grep：`buildDispatcher` 仅 `SupervisorRuntime_test.cj:81`；`ProbeRPCImpl.reset` 仅 `Rpc_test.cj:116`，生产 `AgentRuntime.serve()` 只调 `install`。
- **描述**：`buildDispatcher` 是包内符号，本包内只有测试在用，主线走的是 `buildChannels()` + 直接构造 `ChannelDispatcher`（:123-126）；`reset()` 是对外可达 public，但语义是测试夹具，留在公开契约里会让下游误用（清掉全局绑定后 `collect()` 直接抛 CONFIG）。
- **建议**：`buildDispatcher` 加 `@TestOnly`（若语言/框架支持）或改成测试文件里的本地装配；`reset()` 至少在 KDoc 里写明「仅测试」，并评估是否收窄（收窄属破坏性变更，需用户确认下游无引用）。

### [轻微][存量] 三处测试用例可能空转或污染全局状态

- **位置**：`fprobe/src/snapshot/SnapshotStore_test.cj:69-84`、`fprobe/src/runtime/SupervisorRuntime_test.cj:77-88`、`fprobe/src/report/ReportBuilder_test.cj:45-58`
- **来源**：存量
- **判据**：review-checklist §11（测试有效性属实现证据的一部分）、§2（辅助函数复制）
- **证据**：静态确定 —— (a) 并发读用例里 `if (snapshot.node.isEmpty()) { continue }` 且没有任何计数断言，reader 完全可能在 writer 第一次 `replace` 之前跑完 100 轮，最终 `inconsistent == 0` 是空转通过；(b) `unknownChannelFailsDispatcherConstruction` 直接 `Config.set` 全局键，结尾写死恢复成 `"email"` 而非原值，断言失败时配置泄漏到同进程其它用例；(c) `countOf` 用 `needle.toArray().size` 作为步长，`needle` 为空串时 `indexOf("")` 恒返回 `Some(0)`，`while(true)` 死循环（当前调用点都是非空字面量，属潜在陷阱）。
- **描述**：这三处不影响生产代码，但会给出虚假的绿色信号（尤其 (a)：`SnapshotStore` 的「整批一致」正是本模块最需要证明的不变量）。
- **建议**：(a) 加 `readCount` 并在结尾断言「至少读到过一次非空快照」；(b) 先保存旧值、`finally` 还原；(c) `if (needle.isEmpty()) { return 0 }` 或改用 `text.split(needle).size - 1`。

<!-- 第 8 部分 -->

### #1 [一般][存量] `r` 键承诺「立即刷新一帧」，实现为空分支

- **位置**：`fprobe/src/tui/SupervisorApp.cj:200-201`（`handle()` 的 `case UiAction.Refresh => true`）
- **来源**：存量（工作区快照，`git diff` 为空）
- **判据**：review-checklist §3（空实现：公开契约承诺有行为，实现为空）/ §14.1（承诺了但没实现）
- **证据**：静态确定 —— `handle()` 在 `Refresh` 分支只 `return true`，既不调用 `painter.draw`，也没有通知 `RenderLoop`（`RenderLoop` 只暴露 `run` / `stop` / `renderOnce`，无外部触发入口）；`KeyMap.action(UiKey.Refresh)` 与 `TtyKeySource` 的 `'r'` 映射都正常，链路断在最后一跳。
- **描述**：承诺源有三处——`fprobe/README.md:291`（`| r | 立即刷新一帧 |`）、`fprobe/doc/tui.md:49`（同）、`fprobe/doc/spec/add-fprobe/specs/probe-supervisor/spec.md:151`（「`r` 立即刷新」）。实际按下 `r` 无任何可见效果；画面仍每 500ms 自动刷（`SupervisorRuntime.cj:186`），因此不会「卡死」，但按键语义与文档不符，且 TUI 全链路（终端→`UiKey`→`UiAction`）只差这一步。
- **建议**：给 `Painter`/`RenderLoop` 加一个「请求立即渲染」的入口（例如 `RenderLoop.renderOnce()` 直接在 key 线程调用，或用一个 `AtomicBool` 唤醒 `run()` 的 `clock.wait`）；`handle()` 的 `Refresh` 分支调用它，并补一条用例断言 `draw` 次数 +1。

### #2 [一般][存量] 退出恢复存在窗口期：`shutdown()` 以 `runningState` 为门槛，`start()` 中途失败会跳过 `restore()`

- **位置**：`fprobe/src/tui/SupervisorApp.cj:133-141`（`shutdown()` 的早退）、`:100-117`（`start()` 设置 `tuiActive` 与 `runningState` 的区间）
- **来源**：存量（工作区快照）
- **判据**：review-checklist §11（错误处理缺失 / 资源释放不对称）、§3（静默失效）
- **证据**：静态确定 —— `start()` 顺序是 `hooks.toExitGracefully()` → `atExit(0, shutdown)` → `painter.start()` → `tuiActive = true` → `components.start()` → `runningState = true`；`shutdown()` 第一行读 `runningState`，为 `false` 时直接 `return`，此时不会走到 `painter.restore()`。
- **描述**：两条触发路径都会命中该窗口。
  1. `components.start()` 抛异常（探针工厂 / 连接建立失败）：异常从 `start()` 直接抛出，`runningState` 仍是 `false`；进程退出时 `atExit` 注册的 `shutdown()` 早退 ⇒ **终端停留在 raw mode + 备用屏**，用户 shell 花屏，只能 `reset` 恢复。
  2. 信号落在 `painter.start()` 与 `runningState = true` 之间：`f_base` 的信号处理器调用 `shutdown()`，同样早退 ⇒ 终端不恢复、`components.stop()/close()` 不执行。
- **建议**：把「是否需要恢复终端」与「是否处于运行态」解耦——`shutdown()` 的早退条件改为「`runningState` 与 `tuiActive` 都为 false」，或直接让 `restore()` 幂等（`Terminal.restore()` 本身已幂等，见 `f_tui/src/render/Terminal.cj:132-135`）而无条件调用；同时把 `components.start()` 纳入 `try`，失败时先走 `shutdown()` 再返回错误码。

### #3 [一般][存量] 生产装配未使用 `PassiveExitHook`：`systemPainter()` 无调用者，`SupervisorBootstrap` 复制的装配行为不同

- **位置**：`fprobe/src/tui/FprobePainter.cj:328-337`（`PassiveExitHook` 及其注释）、`:340-345`（`systemPainter()`）；对照 `fprobe/src/runtime/SupervisorBootstrap.cj:57-61`（`createPainter()`）
- **来源**：存量（工作区快照）
- **判据**：review-checklist §2（近似重复、其中一块少了边界处理 —— 同时是缺陷）、§14.1（接线缺失）
- **证据**：静态确定 —— 全仓搜索 `systemPainter` 只有定义处命中（README:521 只把它列进「其他公开 API」），生产入口走的是 `SupervisorBootstrap.createPainter()`；两处装配差三点：`PassiveExitHook` vs 默认 `SystemExitHook`、`TERM_STDOUT_FILENO` vs 字面量 `1`、`IoctlSizeProvider(ffi, TERM_STDOUT_FILENO)` vs `IoctlSizeProvider(ffi, 1)`。`registerSignalHandler` 是否真的覆盖 `f_base.ExitCallbacks` 的处理器 → **待确认**（`f_base` 另提供 `resetSignalHandler`，说明 `std.runtime.registerSignalHandler` 可能是追加语义）。
- **描述**：`FprobePainter.cj:329-331` 的注释明确写着「生产装配改用被动钩子，让 `SupervisorApp.shutdown()` 成为唯一退出路径」，但真正的生产装配（`SupervisorBootstrap`）用的是默认 `SystemExitHook`。`f_tui/src/render/Terminal.cj:52-59` 会注册 `SIGINT`/`SIGTERM` 处理器，其回调只做 `restore()`（`fTuiDispatchExit` 只遍历 `F_TUI_EXIT_CALLBACKS`）。若该注册覆盖了 `f_base` 的处理器，则 `doc/tui.md:55-56` 承诺的「`q`、`Ctrl+C`、`SIGTERM` 走同一套钩子；退出时按顺序停止拉取线程、关闭节点连接」不成立：信号路径下 `components.stop()/close()` 不会执行。现有用例 `SupervisorApp_test.signalStopsPollLoopAndClosesConnections`（`:188-205`）用的是 `RecordingHooks` 假实现，覆盖不到真实装配。
- **建议**：二选一，不要留两份装配——(a) 让 `SupervisorBootstrap.createPainter()` 改为 `FprobePainter(TerminalFrameRenderer(Terminal(ffi, StdoutTerminalWriter(ffi, TERM_STDOUT_FILENO), IoctlSizeProvider(ffi, TERM_STDOUT_FILENO), exitHook: PassiveExitHook())))`，即直接复用 `systemPainter()`（需把 `PassiveExitHook` 改为 internal 可见以便同模块外复用，或把 `systemPainter()` 保留为唯一入口并删掉 `createPainter()`）；(b) 若确认要保留 `SystemExitHook`，则删除 `PassiveExitHook` 与注释，并改 `doc/tui.md` 的退出语义承诺。补一条装配级用例断言「信号 → stop/close 被调用」。

### #4 [一般][存量] `PollLoop.tick()` 每 tick 为每个节点 `spawn` 一个线程，无并发上限

- **位置**：`fprobe/src/supervisor/PollLoop.cj:108-111`（`Array<Future<CollectOutcome>>(sources.size) {i => spawn {...}}`）
- **来源**：存量（工作区快照）
- **判据**：review-checklist §12.1（有界性：无界任务/线程堆积）、§5（一次提交全量任务）
- **证据**：静态确定（结构无上限）；影响程度随节点数增长，具体阈值 **需实测**。
- **描述**：`tick()` 一次性按 `sources.size` 生成 `N` 个 `Future`，即每个 tick 创建 `N` 个线程，随后逐个 `get()` 汇合。`N` 由配置的节点数决定，没有窗口/上限；`sources` 为空时无影响，但节点数上千时会瞬时创建上千线程（栈内存 + 调度开销），并在 `future.get()` 处形成 `N` 次阻塞等待。`tick()` 由 `run()` 单线程调用，`N` 个线程不会跨 tick 累积，因此不是「只增不减」，但单 tick 的并发峰值无界。
- **建议**：改为固定并发度的工作队列（`min(N, K)` 个 worker 或分批 `spawn` + 窗口），或按配置项暴露 `probe_pollConcurrency`；补一条「节点数 1000 时线程峰值」的观测用例。

### #5 [轻微][存量] `collectOne` 的 `at` 形参未使用

- **位置**：`fprobe/src/supervisor/PollLoop.cj:110`（传入 `now`）、`:164-172`（`collectOne(source:at:)` 函数体）
- **来源**：存量（工作区快照）
- **判据**：review-checklist §1（读了不用 / 未使用形参）
- **证据**：静态确定 —— 函数体只读 `source.name` 与 `source.collect()` 返回值，`at` 一次都没读；`tick()` 却特意把 `now` 传进来。
- **描述**：形参名与传参位置暗示「用 tick 起点时间戳给快照打时间」，实际时间戳来自 `source.collect()` 内部（`ProbeSnapshot.timestamp`），`NodeState.updatedAt` 用的是 `now`。误导后续维护者以为此处有统一时间基准。
- **建议**：删掉 `at` 形参并同步 `tick()` 的调用，或真正用它给 `CollectOutcome` 补一个 `startedAt` 字段（若将来要统计单节点拉取耗时）。

### #6 [轻微][存量] `renderer.flush()` 的 `Bool` 返回值被丢弃

- **位置**：`fprobe/src/tui/FprobePainter.cj:139-140`（`draw()` 尾部）
- **来源**：存量（工作区快照）
- **判据**：review-checklist §11（错误处理缺失：返回值被忽略）
- **证据**：静态确定 —— `FrameRenderer.flush(): Bool` 语义是「刷新失败返回 `false`」（`f_tui/src/term/TerminalWriter.cj:23-24`），`TerminalFrameRenderer.flush()` 直接转发 `terminal.bufferRenderer().flush()`（`FprobePainter.cj:84-86`），调用点未接返回值。`BufferRenderer.flush` 的返回值来自底层 `write`（`f_tui/src/render/BufferRenderer.cj:120-123`）。
- **描述**：终端写失败（管道关闭、stdout 被重定向到已断开的 FIFO）时渲染线程继续按帧绘制，既不记录也不降级，问题只能表现为「画面不动」。
- **建议**：`draw()` 里 `if (!renderer.flush()) { throw ProbeException(ProbeErrorCode.IO, "...") }`（由 `RenderLoop.renderOnce` 的 `catch` 统一记录），或至少在失败时 `onError` 一次并做限频，避免每帧刷日志。

### #7 [轻微][存量] 状态栏把 epoch 毫秒直接当「刷新时间」显示

- **位置**：`fprobe/src/tui/RenderPlan.cj:235`
- **来源**：存量（工作区快照）
- **判据**：review-checklist §11（语义与呈现不符）、§13（示例与实现不一致）
- **证据**：静态确定 —— 标题模板是 `"fprobe  节点 ${nodeCount}  告警 ${view.alarmCount}  刷新 ${nowMs}ms"`，`nowMs` 由 `RenderLoop.renderOnce` 传入 `clock.nowMs()`（`RenderLoop.cj:72-73`），是 13 位 epoch 毫秒；而测试替身 `FprobePainter_test.cj:95,116` 用的样例是 `刷新 1000ms`，读起来像「刷新间隔」。
- **描述**：spec 要求状态栏含「最后刷新时间」（`doc/spec/add-fprobe/specs/probe-supervisor/spec.md:149`），取值没错，但呈现为裸 epoch 数字对用户无意义；同一个位置在不同测试里出现的数值语义也不一致。
- **建议**：按 `HH:mm:ss` 格式化（`nowMs` 已是毫秒，转时分秒即可），或改标签为「上次刷新」并保留相对时间；同时把 `RenderPlan_test` 的标题断言补上该字段，避免再次漂移。

### #8 [轻微][存量] 最小图表高度 8 在两处各写一遍

- **位置**：`fprobe/src/tui/ChartPanel.cj:31`（`MIN_HEIGHT = 8`）与 `fprobe/src/tui/TuiLayout.cj:26`（`MIN_CHART_HEIGHT = 8`）
- **来源**：存量（工作区快照）
- **判据**：review-checklist §2（字面量复制：同一常量散落多处）
- **证据**：静态确定 —— 两处注释都写着「`f_chart.tui` 的最小高度」，值都是 8；`TuiLayout.chartHeight` 用它决定「画图还是回退 sparkline」，`ChartPanel.chartJson` 用它决定「返回 `Some` 还是 `None`」。
- **描述**：两个常量分属「布局预算」与「图表适配」两层，目前一致纯属同步维护；一旦 `f_chart.tui` 调整最小高度，只改一处会出现「布局认为能画、`ChartPanel` 返回 None」的静默回退（功能不坏，但排查成本高）。
- **建议**：保留一处（建议 `TuiLayout.MIN_CHART_HEIGHT`）并让 `ChartPanel` 引用它；`ChartPanel` 若要独立于布局层，则在其注释里写明「必须与 `TuiLayout.MIN_CHART_HEIGHT` 同步」并加一条断言两值相等的用例。

### #9 [轻微][存量] 手写 `join` 重复标准库 `String.join`

- **位置**：`fprobe/src/tui/FprobePainter.cj:314-325`（`private func join`）
- **来源**：存量（工作区快照）
- **判据**：review-checklist §2（重复逻辑：已有标准库能力）
- **证据**：静态确定 —— `join(values, separator)` 用 `StringBuilder` 拼接，语义与 `String.join(values, delimiter:)` 完全一致；同仓 `RenderPlan.cj:366` 已在用 `String.join(names.toArray(), delimiter: ",")`。
- **描述**：两套拼接实现共存，`paintFooter` 里还出现「先 `join(alarmRows)`、再把结果放进 `parts` 二次 `join`」的双层拼接，读起来比实际逻辑复杂。
- **建议**：删掉私有 `join`，改用 `String.join`；`paintFooter` 可先把 `note` 与告警串准备好再一次拼接。

### #10 [轻微][存量] `topologyRows` 里 devices / links 两段结构完全同构

- **位置**：`fprobe/src/tui/RenderPlan.cj:294-313`（devices）与 `:314-334`（links）
- **来源**：存量（工作区快照）
- **判据**：review-checklist §2（近似重复：同一套「取键 → `asArray` → 逐项 `asObject` → 取字段 → 加行」）
- **证据**：静态确定 —— 两段的差异只有键名（`devices`/`links`）、字段组合与行首文案；异常处理逐行对齐（`asArray` 失败返回空 `JsonArray`、`asObject` 失败 `continue`、`textOf` 缺字段返回 `""`）。
- **描述**：这是「同一套解析骨架写两遍」，后续加第三种拓扑数组（例如 `vlans`）会复制第三遍；两段目前唯一实质差异是 `listOf` 参与 devices 但不参与 links，属于业务差异，需要显式参数化而不是继续复制。
- **建议**：抽 `topologyArray(root, key, rowBuilder)`：由调用方传键名与「对象 → `Array<String>`」的构造闭包，把 `asArray`/`asObject` 的容错骨架收敛到一处；差异点（字段组合、`listOf`）留在闭包里。

### #11 [轻微][存量] `catch (e: Exception)` + `catch (e: Error)` 同体样板重复 5 处

- **位置**：`fprobe/src/supervisor/PollLoop.cj:155-161`、`:165-171`、`:174-181`；`fprobe/src/tui/ChartPanel.cj:83-96`；`fprobe/src/tui/RenderLoop.cj:71-79`
- **来源**：存量（工作区快照）
- **判据**：review-checklist §2（重复逻辑：换控制流/换消息文案的同一套隔离策略）
- **证据**：静态确定 —— 5 处的形状都是「`try { 业务 } catch (Exception) { 记录 } catch (Error) { 同一条记录 }」，差异仅在日志文案与 sink（`eprintln` vs `onError`）。
- **描述**：「隔离任意 throwable 并继续」是本模块的统一策略（`PollLoop` 的评估器隔离、节点事件发布隔离、单节点采集隔离，`RenderLoop` 的整帧隔离，`ChartPanel` 的图表实现隔离），但实现散在三个文件；其中 `PollLoop.publish` 与 `collectOne` 的文案只差一个前缀。
- **建议**：抽一个模块内 `safe(message: String, body: () -> Unit)`（或 `guard` 风格）辅助函数，5 处改为调用它；文案与 sink 作为参数传入，保留现有日志级别与措辞。

<!-- 第 9 部分 -->

### [一般][存量] Sparkline 用整段序列的最大值归一化，离屏点会长期压平可见窗口

- **位置**：`fprobe/src/tui/widgets/Sparkline.cj:36-44`（max 计算）、`:49-54`（可见窗口裁剪）、`:57`（比值）
- **来源**：存量（工作区快照无基线；`git log` 该文件最后修改在 2026-11-09 的 TUI 装配提交）
- **判据**：review-checklist §11（边界 / 非有限值未处理；归一化口径与「窗口」语义不符）
- **证据**：静态确定 —— 只读代码即可确定 `maximum` 在裁剪之前对全部 `values` 求，且 `visible`/`start` 在之后才计算
- **描述**：`values` 是 `probe_historyPoints` 窗口（默认 60 点），实际可画宽度由调用方给出：80 列终端下右栏 inner 宽约 52（`FprobePainter.cj:143-159`），`paintSeries` 再预留 8 列标签 + 1 列间隔（`FprobePainter.cj:273-290`），sparkline 只剩约 43 格，即约 17 个点被裁掉。若被裁掉的旧点里有一个尖峰，`maximum` 仍按它归一化，之后每个可见帧的所有方块都贴近 `▁`，直到该尖峰滚出 60 点环形缓冲。这让「当前窗口的趋势」被判读为「几乎为零」。
  次要边界：全 NaN 时 `maximum` 保持 0 → 改成 1.0，`ratio` 为 NaN，`Int64(ratio * 7.0 + 0.5)`（`:64`）对 NaN 的转换结果仓颉文档未定义（本地文档 `cangjie-doc/md/doc/core.md:16` 只说明 Float 含 `NaN`，未定义 Float→Int 的 NaN 语义）；`+Inf` 时 `ratio = Inf/Inf = NaN`。作为对照，`fprobe/src/tui/ChartPanel.cj:44-53` 至少会剔除全 NaN 序列，Sparkline 完全没有非有限值判断。
- **建议**：先算 `start`/`visible`，只在 `[start, values.size)` 上求 max；用标准库的 `isNaN()` / `isInf()`（`cangjie-doc/.../core_package_intrinsics.md:1384`、`:1425`）过滤非有限值点（或整段跳过后按 0 绘制）；与 `ChartPanel` 的 NaN 策略保持一致。

### [一般][存量] usage 文本声称支持「配置文件」不存在，agent 帮助又漏列多节点必需的 `probe_hostId`

- **位置**：`fprobe/src/usage.cj:35`（配置文件）、`:46-52`（agent 关键配置项）
- **来源**：存量
- **判据**：review-checklist §13（配置源与源码不符）、§14.2（帮助文本未覆盖关键配置）
- **证据**：静态确定 —— `f_config` 的 `static init()` 只读环境变量与命令行（`f_config/src/Config.cj:62-89`），没有任何配置文件入口；`README.md:157` 明写「配置只来自两个地方」，`doc/configuration.md:3` 也只列 `--key=value` / `-key value` / 环境变量
- **描述**：`Usage.root()` 的「可通过配置文件、环境变量或 `--key=value` 传入」把不存在的配置源写进了帮助，用户会去找配置文件。另外 `probe_hostId` 要求集群内唯一、`0` 会被 `f_protocol` 拒绝（`README.md:180`、`doc/configuration.md:13`），`fprobe.sh` 会默认注入，但 `fprobe agent --help` / `fprobe supervisor --help` 都没列这一项；按帮助部署多节点时所有进程都会沿用默认值 1。
- **建议**：删除「配置文件」表述（或实现后再写）；agent / supervisor 两段帮助各加一行 `probe_hostId`（默认 1，多节点必须各不相同）。

### [轻微][存量] TTY 前置校验与 `f_tui` 的终端契约重复且不一致

- **位置**：`fprobe/src/tui/TtyDetector.cj:26-27`（`STDOUT_FILENO`）、`:34`（`isatty(1)`）、`:44-49`（`requireTty`）
- **来源**：存量
- **判据**：review-checklist §2（同一策略两处实现）、§10（绕过既有抽象层）、§11（错误路径文案不一致）
- **证据**：静态确定
- **描述**：
  1. `requireTty` 只检查 stdout（fd 1），而 `f_tui` 的 `Terminal.start()` 要求 stdin 与 stdout **都**是 TTY（`f_tui/src/render/Terminal.cj:111-112`），raw mode 与按键都走 stdin（同文件 `:95`、`:98`；`fprobe/src/tui/TtyKeySource.cj:90` 用 `STDIN_FILENO`）。`stdout` 是 TTY、stdin 被重定向（如 `fprobe supervisor < /dev/null`）时前置校验放行，随后抛 `standard input/output is not a tty`，日志变成 `TUI 初始化失败: ...`，既没有 `doc/tui.md:14` 承诺的「标准输出不是 TTY」，也没有 resident 指引。
  2. `TtyDetector.cj:27` 重新声明 `STDOUT_FILENO = 1`，而 `f_tui/src/term/PosixFfi.cj:21` 已公开同名常量（`FprobePainter.cj:22` 就是 import 用的）；同时直接调 `std.posix.isatty`，绕过 `doc/tui.md:62` 声明的「`isatty` 唯一出口」`PosixFfi.isTty`（`PosixFfi.cj:221-223`）。
- **建议**：`requireTty` 改为同时检查 in/out（或直接复用 `Terminal.start()` 的前置判断并把 `TuiException` 翻译成带 resident 指引的 `ProbeException`）；常量改为 import `f_tui` 的 `STDOUT_FILENO`；TTY 判定走 `PosixFfi.isTty`。

### [轻微][存量] 图表最小高度 8 在同包与 `f_chart` 各写一份

- **位置**：`fprobe/src/tui/TuiLayout.cj:26`（`MIN_CHART_HEIGHT = 8`）vs `fprobe/src/tui/ChartPanel.cj:31`（`MIN_HEIGHT = 8`）；`f_chart/src/tui/TuiFrame.cj:71` 又硬编码 `height < 8.0 || width < 20.0`
- **来源**：存量
- **判据**：review-checklist §2（字面量复制 / 换算复制）
- **证据**：静态确定 —— 同包两个类各声明一份「图表最小高度」，`ChartPanel.chartJson`（`:41`）还独立用 `MIN_WIDTH`、`MIN_HEIGHT` 再判一次
- **描述**：回退策略（高度 < 8 不画多行图）由 `TuiLayout.chartHeight` 与 `ChartPanel` 各自判定。任一处调阈值，另一处不会跟随：把 `TuiLayout` 降到 6 会让 6/7 行的预算交给 `ChartPanel`，后者仍返回 `None` 走回退；把 `ChartPanel` 升到 10 则 8/9 行预算一定回退。`doc/tui.md:42` 的「20 列 × 8 行」实际分散在三处（`TuiLayout` 只有高度，宽度只在 `ChartPanel` / `f_chart`）。
- **建议**：`TuiLayout` 直接引用同包 `ChartPanel.MIN_HEIGHT` / `MIN_WIDTH`（或抽出 `TuiLimits`），`f_chart` 的下限如需独立，提取为 `f_chart` 公共常量供引用。

### [轻微][存量] `MetricPage.kind()` 的 TOPOLOGY / ALARMS 分支在实际调用点不可达，且与 `RenderPlan` 的 `"topology"` 字面量重复

- **位置**：`fprobe/src/tui/ViewModel.cj:65-76`；调用点 `fprobe/src/tui/RenderPlan.cj:206-220`
- **来源**：存量
- **判据**：review-checklist §2（重复映射，只改控制流/字面量）
- **证据**：静态确定 —— `RenderPlanBuilder` 先处理 `ALARMS`、再 `else if (page == MetricPage.TOPOLOGY)` 并硬编码 `"topology"`，只有剩余页才调用 `page.kind()`；`kind()` 是 public 方法（不判死代码），但这两个分支生产路径取不到
- **描述**：`kind()` 的注释称「与 `ProbeAgent.kind` 对应的键」，可拓扑页并不用它，改 `kind()` 的命名对拓扑页无效；告警页的 `""` 也无调用者。外观上是「唯一映射」，实际有两份真相。
- **建议**：拓扑分支改成 `page.kind()`（或把 `kind()` 收窄为只管有 `kind` 的页，`RenderPlan` 显式用常量），并在 `kind()` 注释里写明哪几页有值。

### [轻微][存量] `ViewModel` 的四个导航方法两两同构，`selectNext` 多出的空判断不改变结果

- **位置**：`fprobe/src/tui/ViewModel.cj:138-155`
- **来源**：存量
- **判据**：review-checklist §2（重复逻辑，差异只有 ±1 与一个无效果分支）
- **证据**：静态确定 —— `selectNext` / `selectPrevious` 只差 `selection ± 1`，`nextPage` / `previousPage` 只差 `pageIndex ± 1`；`selectNext` 的 `nodes.isEmpty() → this` 去掉后构造器 `clampSelection(1, 0)` 返回 0，`selectedNode()` 仍是 `None`，可观察结果不变（`selectPrevious` 就没有该判断）
- **描述**：四份几乎相同的「构造新实例」代码，加上一个只在一侧存在的空判断，会让读者以为空列表下两个方向的语义不同；后续加「首尾不循环」之类规则时要改四处。
- **建议**：合并为 `moveSelection(delta)` / `movePage(delta)`（内部走构造器夹取），空判断要么两处都留、要么都删。

### [轻微][存量] README 公开 API 索引漏 `MetricPage.kind` / `Usage.agent` / `Usage.supervisor`

- **位置**：`README.md:559`（`MetricPage` 只列 `chartType`、`title`）、`README.md:612`（`Usage` 只列 `root`）；源码 `fprobe/src/tui/ViewModel.cj:65`、`fprobe/src/usage.cj:39`、`:55`
- **来源**：存量
- **判据**：review-checklist §14.2（公开 API 未文档化；`README.md:519` 自称未展开的 public 声明都在此列出）
- **证据**：静态确定 —— 在 README / `doc/**` 检索 `MetricPage.kind`、`Usage.agent`、`Usage.supervisor` 均无命中（`grep -rn` 空结果）
- **描述**：三个 public 成员在正文与索引里都不存在；`kind()` 还是 `RenderPlan` 取监控项键的入口，读者无法从文档知道页面与 `ProbeAgent.kind` 的对应关系。
- **建议**：补进索引（`kind` 加一句「页面 → `ProbeAgent.kind`，拓扑/告警页为空」），或把 `kind` 收窄为包内可见后从对外契约中移除。

### [轻微][存量] `Table` 在 2 列极窄区域会以 0 宽度写到区域右边界之外一列

- **位置**：`fprobe/src/tui/widgets/Table.cj:64-67`（值列写入），宽度推导见 `:36-46`
- **来源**：存量
- **判据**：review-checklist §11（边界差一）
- **证据**：待确认 —— 需确认 `ratatui_buffer.Buffer.setStringn` 在 `maxWidth == 0` 且 `x == area.right()` 时是否先做范围裁剪（依赖包只有 `.cjo`，仓内无源码）
- **描述**：`width = totalWidth / 2`，`totalWidth = 2` 时 `width = 1`，`start = area.x + 2`（正好等于 `area.right()`），`maxWidth = totalWidth - width - 1 = 0`。`FprobePainter.paintMetrics`（`:212`）只要右栏 inner 宽落到 2（约 12 列终端：left 8 + 边框 2 + 右栏 4）就会走到这里。若 `Buffer` 未在写入前裁剪，这是越界写；若已裁剪则只是一次无效调用。
- **建议**：把条件收紧为 `width + 1 < totalWidth` 再画值列（或先判 `totalWidth - width - 1 >= 1`）。

## 优化可行性方案

> 不是缺陷，是「还能更好」；无基线的方案只作待验证假设，不进 tasks。

<!-- 第 1 部分 -->

本部分 14 个文件全部是文档，没有可测量的代码路径，因此不产出堆内存 / CPU 优化方案（0 条）。文档层面唯一可执行的改进是「契约单一来源」，已作为 #2 / #3 的根因在「描述」中说明，不重复计入优化统计。

<!-- 第 2 部分 -->

### [CPU] 每条规则重复做一次 JSON 全量解析 + 路径编译 + 运算符解析

- **现状**：`AlarmEngine.evaluate` 每个 tick、每个节点、每条规则都调用 `jsonToData(data.dataJson)`（`:186`）、`DataPath.solid(rule.path)`（`:193`）、`AlarmOp.parse(rule.op)`（`:215`）。同一 `kind` 下 N 条规则会把同一份 `dataJson` 解析 N 次；`dataJson` 是探针整棵树（磁盘 mounts、网络 interfaces 数组），单份量级为百字节到数 KB。默认 5 秒 tick、10 节点 × 20 规则 ⇒ 每秒约 40 次解析 + 40 次路径编译，全部落在拉取线程的 `evaluate` 里，与 `onEvent` 的同步发送串在一起。
- **方案**：(a) 加载期把 `path` 预编译成 `DataPath`、`op` 解析成 `AlarmOp`，随 `AlarmRule` 持有（`DataPath.cache` 亦可，但要注意其全局缓存的并发语义）；(b) `evaluate` 内按节点先建 `kind → Data` 的一次性映射（每 tick 每 kind 解析一次），规则只做取值比较。
- **预期**：解析/编译次数从 `规则数 × 节点数` 降到 `用到的 kind 数 × 节点数`（本仓库默认配置下约 5-10 倍），单次成本不变；端到端收益取决于 `valueOf` 在 tick 里的占比（未知）。
- **代价**：`AlarmRule` 多两个字段、加载期多一次校验（正好补上面第 4 条缺陷）；`DataPath.cache` 有全局状态，优先用规则对象自带实例；无接口变更。
- **验证**：`cjpm bench -O2`，同输入（10 节点 × 20 规则 × 60 tick，fixture `dataJson` 固定）；`cjprof record` 看 `valueOf`/`jsonToData` 自耗时占比与 GC 分配量（每 tick 生成的 `DataObject` 树）。
- **证据状态**：`无基线（待验证，不进 tasks）`

<!-- 第 3 部分 -->

### [CPU] TUI 每帧每格都重新解析同一份 `dataJson`

- **现状**：`fprobe/src/tui/RenderPlan.cj:425-436` 每个单元格调用 `projection.evaluate(value.dataJson)`；`MetricProjection.evaluate`（`collect/MetricProjection.cj:102-104`）每次都会 `jsonToData` 全量解析（`JsonData.cj:28-34` → `JsonValue.fromStr` + 递归包装）再 `DataPath.solid(path)` 编译一次（`MetricProjection.cj:112`）。`RenderPlan.cj` 定义了 22 个 `MetricSpec`，按 kind 分派；一个节点一帧要解析同一份 `dataJson` 最多 6 次（cpu），N 个节点 ≈ 22N 次解析 + 22N 次路径编译，`RenderLoop` 每 `intervalMs` 一帧。
- **方案**：`RenderPlan.renderValue` 改为"每帧每 (node, kind) 解析一次 `?Data` + 缓存 `MetricProjection → DataPath`"，`evaluate` 增加接受 `Data` 的重载；`MetricProjection` 在构造期或首次使用时缓存编译后的 `DataPath`（路径是配置常量，无失效问题）。
- **预期**：解析次数从 22N/帧降到 ≤6N/帧（按用到的 kind 数），路径编译降到每投影一次；端到端收益取决于 TUI 帧耗时中解析占比（未知）。
- **代价**：`MetricProjection` 多一个可变缓存字段（需保证 `evaluate` 仍可并发调用，建议构造期编译、字段 `let`）；`RenderPlan` 需要按 kind 分组，代码量 +30 行左右。
- **验证**：`cjprof record` 跑 TUI 稳态 60 帧（10 节点、真实快照），对比 `MetricProjection.evaluate` 自耗时占比与分配量；`cjpm bench -O2` 用固定 `dataJson` 做 `evaluate × 22 × 1000` 对照。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `ProbeRunner.tick` 串行执行全部探针，一轮耗时 = 各探针耗时之和

- **现状**：`collect/ProbeRunner.cj:79-96` 用 `Array(...) {i => ...}` 顺序调用 `ProbeSnapshotBuilder.encode(slot.agent)`；探针内部会做 shell 命令（`DiskProbe`/`SmartProbe`/`SnmpProbe`，`timeoutMs` 默认 3s 级）、HTTP（2s）、RPC 定向调用（3s × 目标数）。`AgentRuntime.cj:92-97` 的采集线程因此是单线程串行，`intervalMs` 从 tick 结束后才开始计。
- **方案**：把"独立探针"改成有界并行（例如 `spawn` 每探针、并发度 4 或按 `probe_parallelism` 配置），每探针的错误仍各自收敛到自己的 `ProbeSlot`；或按"快速探针（读 /proc）先跑、慢探针（shell/网络）并行"分两组。
- **预期**：最坏 tick 时长从 `Σ timeout` 降到 `max timeout`（数量级取决于启用的慢探针数），采集新鲜度提升；CPU 本身不降，降的是 wall-clock。
- **代价**：`ProbeSlot` 的写要从"单线程"改为"每探针一个槽 + 汇合"，否则出现数据竞争；探针实现需确认可并发（`ProcReader` 读文件无状态，`CommandRunner` 每次 spawn 进程，OK；`CpuProbe` 等有 `last*` 基线的探针**不能**并行跑两次同一实例——并行粒度只能是"不同探针之间"）。
- **验证**：分段计时（每个 `slot.agent.data` 前后打时间戳，记录 P50/P95）跑 1 小时，对比并行前后 tick 时长与 `intervalMs` 漂移；确认快照内容逐字段等价。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] `FEmailTransport.list` 为窗口内每封未读邮件各取一次整封正文

- **现状**：`FEmailTransport.cj:112-127` 对 `email.list(limit)` 的**每一封**未读邮件调用 `email.body(summary)`；`Email.body` 会 `uidFetchMessage` 整封（含附件，`EmailFacade.cj:367-373`），附件超过阈值还会落临时文件。默认 `receiveLimit=20` ⇒ 单轮最多 20 次完整取信，而 `EmailAlarmChannel.receive` 只用第一封（`EmailAlarmChannel.cj:66-77`）。
- **方案**：先按 `MailSummary`（已有 subject/from/date/size/flags）选出"要回的那一封"再取正文（把 `MailTransport` 拆成 `listSummaries` + `body(id)`）；或把 `receiveLimit` 降到 3-5 并把 `probe_channel_email_receiveLimit` 真正接线（part1 #1）。
- **预期**：单轮 IMAP 往返从 ≤20 次降到 1 次，正文对象峰值从 20 份降到 1 份；邮件多、正文大（附件落盘）时收益更明显。
- **代价**：接口变更（`MailTransport` 增加摘要/正文两段式），`EmailAlarmChannel_test` 的假传输要跟着改；语义不变。
- **验证**：`getAllocatedHeapSize()` + RSS（多轮轮询稳态）+ IMAP 命令计数（服务端日志或 `f_email` 埋点），对比改前改后的单轮往返次数与峰值。
- **证据状态**：`无基线（待验证，不进 tasks）`

<!-- 第 4 部分 -->

### [CPU] 硬件探针设备级采集有界并发化

- **现状**：`SmartProbe.collect` 与 `SnmpProbe.collect` 对每个设备同步 `runner.run`，最坏 `(1+N+M)×3s`；设备数由 `probe_smartDevices`/`probe_snmpDevices` 配置决定（默认 0–数块盘）。
- **方案**：固定窗口并发（窗口 = `min(设备数, 4)`），先提交全部任务再统一 `get`，总预算 = `commandTimeoutMs`；单个失败仍按现有 `available=false` 语义记录。
- **预期**：最坏单轮从 `(1+N+M)×3s` 降到约 `3s × ceil((1+N+M)/4)`；不改变单设备结果。
- **代价**：同时最多 4 个子进程（fd/内存小幅上升），需要线程池或 `spawn` + 有界信号量；顺序不再稳定（结果按设备索引回填即可保持输出顺序）。
- **验证**：`cjpm bench` 无法覆盖外部命令，用分段计时：固定 8 个设备（其中 2 个注入 3s 超时），对比改前/改后单轮耗时的中位数与 P95，`-O2`。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `RpcHealthTransport` 每次探测重建 `f_net.Client`

- **现状**：每个目标每次采集都 `Client.builder(...).build()`（带 30s 检查周期与 ping 检查器线程），用完 `close()`；`probe_rpcHealthTargets` 有几个目标就建几条连接。
- **方案**：按 `NodeEndpoint` 缓存长连接（含 `close` 时的统一回收），失败时重建；或把健康调用改走已有的 `RPCClient` 但显式指定目标。
- **预期**：省掉握手 + 每轮线程创建/销毁；具体收益需分段计时（建链 vs `transfer`）。
- **代价**：长连接需要失效检测与重连（现有 `checkDuration` 可复用），并新增「agent 停止时关闭全部缓存连接」的清理点。
- **验证**：5 个目标、5s 间隔跑 10 分钟，对比每轮 `call` 耗时中位数与线程数峰值。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `CpuProbe` 对 `/proc/stat` 两次全量切分

- **现状**：`data` 里 `parseAggregate(stat)` 与 `countCores(stat)` 各 `split("\n")` 一次并逐行 `splitWhitespace`（`CpuProbe.cj:71-75`、`:109-172`），每 tick 两遍 O(行数)。
- **方案**：单趟遍历同时累计汇总行与核数，返回 `(total, idle, iowait, cores)`。
- **预期**：字符串切分与临时 `ArrayList` 分配减半（每 tick 少一次整文件 split + N 次行 split）；绝对收益取决于 `/proc/stat` 行数（核数×1 行）。
- **代价**：低（一个函数合并，语义不变）。
- **验证**：`cjprof record` 跑 1s 间隔 10 分钟，看 `parseAggregate`/`countCores` 自耗时占比；若合计 <1% 则不做。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] 给外部命令输出加硬上限并复用读取缓冲

- **现状**：每次 `run` 由 `waitOutput()` 返回完整 stdout/stderr 字节数组，随后 `String.fromUtf8` 复制、`split("\n")` 再物化整行数组（`CommandRunner.cj:71-76`、`SnmpProbe.cj:125`）；上限只受 3s 超时约束。
- **方案**：`CommandRunner` 增加 `maxOutputBytes`（默认 4 MiB）：读取到上限即截断并返回 `error="输出超过上限"`；`SnmpProbe`/`SmartProbe` 对截断结果降级为 `available=false`，不解析半行。
- **预期**：把单次命令的峰值内存从「对端可控」变为常量级（≤2×4 MiB + 行数组）。
- **代价**：极端情况下（合法的超大 `snmpbulkwalk` 表）会截断数据，需要配置项与文档说明。
- **验证**：构造 8 MiB 假输出各跑 100 次，对比 `getAllocatedHeapSize()` 峰值与 RSS；同时确认 4 MiB 内的正常输出结果不变。
- **证据状态**：`无基线（待验证，不进 tasks）`

<!-- 第 5 部分 -->

> 不是缺陷，是“还能更好”。本节全部**无基线**，只能作为下一轮补数据的候选，不进 `todo.md` / `tasks.md`。

### [CPU] topology 采集与主采集周期解耦

- **现状**：`TopologyProbe.data`（`TopologyProbe.cj:107-175`）每轮对每台设备跑 2 次完整 walk，无缓存；调用频率 = `probe_intervalMs`（默认 5000ms）。
- **方案**：给 `TopologyProbe` 增加内部结果 TTL（如 60s）或独立采集线程/周期；`data` 在 TTL 内直接返回上次结果。同时把 walk 改成“先提交全部设备、再按 `commandTimeoutMs` 汇合”的有界并发。
- **预期**：拓扑类设备数量 N 越大，采集线程占用越低；端到端收益取决于 N 与设备可达性，需实测。
- **代价**：拓扑新鲜度下降；并发 walk 会同时占用更多子进程与网络带宽，需要并发上限。
- **验证**：`cjprof record/report` 对比改前改后采集线程 self time；分段计时 `tick()` 总耗时（N=10/50，设备全可达与全超时两种分布）；`cjpm bench -O2` 不可行，改用运行时埋点中位数。
- **证据状态**：无基线（待验证，不进 tasks）

### [堆内存] 解析中间容器改为复用/预分配

- **现状**：`splitWhitespace`（`ProbeParsing.cj:26-35`）每行 `new ArrayList()` + `toArray()`；`parseNetDev`/`parseSnmp`/`parseMeminfo` 每轮各建若干 `ArrayList`/`HashMap`，生命周期 = 单次 `data()` 调用，规模为几十~几百个短字符串。
- **方案**：`splitWhitespace` 改为两趟扫描直接填 `Array<String>`（先计数再填充），或返回 `ArrayList` 视图避免 `toArray()` 复制；`parseMeminfo` 复用成员级 `HashMap` 并 `clear()`（注意 `clear()` 不还内存）。
- **预期**：每轮减少 O(行数) 次容器分配与一次数组复制；峰值收益量级为 KB，需测。
- **代价**：可读性下降；复用的 map 必须保证线程封闭（当前成立）。
- **验证**：10 分钟稳态负载下 `getAllocatedHeapSize()` 增量、GC 次数、`RSS` 中位数对照（改前/改后，同 SDK、`-O2`、同输入）。
- **证据状态**：无基线（待验证，不进 tasks）

<!-- 第 6 部分 -->

> 全部为「还能更好」，不进修复清单；均无改前/改后对照数据。

### [CPU] 用 `StringBuilder` / `String.join` 替换手写拼接

- **现状**：`PromptBuilder.joinLines` / `joinNumbers`、`ReportBuilder.joinLines`、`AdviceParser.join` 都是 `result += ...` 循环；报告场景单次拼接的 `html` 行数 ≈ 22×N，单行可达数 KB（内联 SVG），累计前缀复制量约 O(total²/2)
- **方案**：四处统一改为 `StringBuilder.append`（或 `String.join`），`ReportBuilder` 直接以 `StringBuilder` 累积正文
- **预期**：拼接阶段的临时字符串分配从 O(n²) 降到 O(n)，按 100 节点 / 6.6 MB 正文估算可省去数倍于正文的中间串拷贝（精确收益待测）
- **代价**：改动集中、行为不变；`String.join` 要求 `Array<String>`，`ArrayList` 需 `toArray()`，因此 `StringBuilder` 更合适
- **验证**：`cjpm bench -O2`，同一份 `NodeState[]`（100/1000 节点）跑 `ReportBuilder.build` 100 轮取中位数，同时记录 `getAllocatedHeapSize()` 增量
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 提示词构造里按 agent 只解析一次 JSON

- **现状**：`PromptBuilder` 的 `for (spec in ProjectionCatalog.all()) { for (agent in snapshot.agents) { spec.projection.evaluate(agent.dataJson) } }`（`:49-67`）对每个 (指标 × agent) 组合各解析一次 JSON；`MetricProjection.evaluate` 内部走 `collectValues` → `jsonToData`（`src/collect/MetricProjection.cj:102-104`、`:107-124`），22 指标 × 约 6 个 agent ≈ 132 次解析/节点
- **方案**：每个 agent 解析一次为 `Data`，再对 22 个投影求值（`MetricProjection` 增加接收 `Data` 的重载，`evaluate(String)` 保留为薄封装）
- **预期**：解析次数 132 → 6（每节点），1000 节点单次提示词构造减少 ≈12.6 万次 JSON 解析（单次耗时需实测）
- **代价**：`MetricProjection` 需新增重载；需保证 `Data` 复用期间的只读语义（`DataPath.get` 不修改树）
- **验证**：`cjprof record` 对比 `PromptBuilder.build` 自耗时占比；输入 100 节点 × 22 指标 × 20 点
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 指标目录 `ProjectionCatalog.all()` 提到循环外

- **现状**：`ReportBuilder.build` 在**每个节点**循环内调用 `ProjectionCatalog.all()`（`ReportBuilder.cj:97`），而该函数每次都用嵌套循环 + 线性去重重建 22 条 `MetricSpec`（`src/tui/RenderPlan.cj:119-136`，O(n²) 且每次新分配），节点数 N 时重复 N 次；`PromptBuilder` 同样在节点循环内调用两次（`:49`、`:94`）
- **方案**：在建报告/提示词的作用域内只取一次（`let specs = ProjectionCatalog.all()`），或让 `ProjectionCatalog` 缓存为 `static let`
- **预期**：N 次重建降为 1 次；N=1000 时省去约 1000×(22² 次比较 + 22 个对象分配)
- **代价**：缓存需保证不可变（与上一条 `SUPPORTED_TYPES` 同类问题，建议只读快照）；`ProjectionCatalog` 属于 `fprobe.tui`，改动跨包但不改变分层
- **验证**：`cjprof record` 看 `RenderPlan.all` 的累计耗时占比；输入 1000 节点
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] 报告字节数改用 `String.size`，去掉整份 HTML 的字节副本

- **现状**：`ReportBuilder.cj:173` 的 `htmlText.toArray().size` 把整份 HTML 复制成 `Array<Byte>` 只为取长度；报告正文规模 ≈ 22×N 张内联 SVG
- **方案**：改为 `htmlText.size`（`String` 的 `size` 即 UTF-8 字节长度，`core_package_structs.md` prop size）
- **预期**：省去一份与正文等大的临时数组（按 6.6 MB 正文估算，单次峰值降 ≈6.6 MB）
- **代价**：无，语义相同
- **验证**：`getUsedHeapSize()` 在 `build` 前后差值；100 节点固定输入跑 20 轮
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] 回复去重集合换 `HashSet` + 环形队列

- **现状**：`ReplyStateStore` 用 `ArrayList<String>` 同时承担「查找」与「保持顺序」：`isHandled`/`markHandled` 各一次 O(n) `contains`，`trim` 用 `remove(at: 0)` 每次 O(n)（`ReplyStateStore.cj:42-58`、`:90-94`），n 上限 1000
- **方案**：`HashSet<String>` 判重 + 定长环形数组（或 `ArrayDeque`）维护淘汰顺序，`persist` 时按环形顺序序列化
- **预期**：单条消息处理从 O(1000) 降到 O(1)；1000 条稳态下每轮省 ~1000 次字符串比较（回复频率低，绝对值很小）
- **代价**：两处结构需保持一致（同一把「已处理」语义），`persist` 顺序语义不变；实现复杂度略升
- **验证**：`cjpm bench` 对 1000 条 `markHandled` 采样；真实场景观察 `pollOnce` 单轮耗时
- **证据状态**：`无基线（待验证，不进 tasks）`；按当前 30 s 轮询频率，收益大概率低于噪声，除非回复量级上升

<!-- 第 7 部分 -->

> 不是缺陷，是「还能更好」。以下均无改前/改后对照数据，`证据状态` 一律为「无基线（待验证）」，不进修复清单。

### [CPU] `ProbeSnapshot.agents` 每次读取都重新解析整段 JSON

- **现状**：`agents` 是计算属性，getter 每次都 `decodeAgents(agentsJson)`（`fprobe/src/snapshot/ProbeSnapshot.cj:77-81`），内部做 `JsonValue.fromStr` + 逐项 `DataObject.populate`（:91-113）。同一份快照在**同一 tick** 内会被反复读取：`AlarmEngine` 每个节点 2 次（`AlarmEngine.cj:120`、`:137`）+ 每条规则 1 次（`:159`）；`PromptBuilder` 每个 `MetricSpec` 1 次（`PromptBuilder.cj:51`，目录约 15 个 spec）；`RenderPlan` 每帧 1 次以上（`RenderPlan.cj:391`）。快照对象数 = 节点数 × 监控项数（含各监控项 JSON 本体）。
- **方案**：在 `ProbeSnapshot` 内加一个惰性缓存字段（首次 `agents` 访问后保存 `Array<ProbeAgentData>`，`agentsJson` 不可变所以缓存安全），或让热路径调用方在循环外先 `let agents = snapshot.agents` 取一次再复用。
- **预期**：把每节点每 tick 的 JSON 解析次数从「2 + 规则数」降到 1；渲染帧与提示词构建同理。具体降幅取决于监控项 JSON 大小与节点数，未测。
- **代价**：多持有一份 `Array<ProbeAgentData>`（与 JSON 文本双份表示，节点数 × 监控项数 量级）；缓存字段使对象不再严格「不可变」，多线程首次并发访问需用 `AtomicOptionReference` 或容忍重复解析（幂等，无正确性影响）。
- **验证**：`cjprof record` 跑「10 节点 × 15 指标 × 200 tick」，对照 `decodeAgents` 自耗时占比与 `getAllocatedHeapSize()`；`cjpm bench -O2` 同输入前后对照，取中位数。
- **证据状态**：无基线（待验证，不进 tasks）

### [CPU] `TopologyRenderer` 的插入排序与两次数组复制

- **现状**：`sortedDevices` 先 `ArrayList` 追加再 `toArray()`，然后手写 O(n²) 插入排序（`TopologyRenderer.cj:74-92`）；`sortedLinks` 同样（:94-118）。拓扑规模通常为几十到几百设备/链路，且只在生成报告/拓扑帧时调用。
- **方案**：直接用 `std.sort` 的比较器版本（或 `ArrayList.sortBy`）按 `name` / `linkKey` 排序，去掉 `ArrayList` 中转；`linkKey` 每次比较都会重新拼字符串（:110），可预先算一次 key 再排序。
- **预期**：排序复杂度从 O(n²) 降到 O(n log n)，并省掉 n 次字符串拼接与两次数组复制；n ≤ 100 时收益可能在噪声内。
- **代价**：需确认排序稳定性不影响「同输入同输出」的既有测试（当前插入排序稳定，`sort` 若不稳需用「key + 原下标」做次级比较）。
- **验证**：`TopologyRenderer_test.sameInputProducesSameSvg` 必须逐字节一致；`cjpm bench -O2` 用 n=500 设备/2000 链路的合成样本对照中位数。
- **证据状态**：无基线（待验证，不进 tasks）

<!-- 第 8 部分 -->

> 不是缺陷，是「还能更好」。以下四条均无改前/改后对照数据，`证据状态` 一律为「无基线（待验证，不进 tasks）」。

### [CPU] 同一 `dataJson` 按指标重复解析（每节点每 tick 22 次、每帧再 22 次）

- **现状**：`NodeHistoryStore.observe()` 对 `ProjectionCatalog.all()` 的每条 spec 调 `spec.projection.evaluate(agent.dataJson)`（`fprobe/src/tui/NodeHistoryStore.cj:62-71`）；`MetricProjection.evaluate` → `collectValues` → `jsonToData(dataJson)`（`fprobe/src/collect/MetricProjection.cj:102-109`、`fprobe/src/collect/JsonData.cj:28-34`），即**每次调用都完整解析一遍 JSON 并适配成 `Data` 树**。同一份 `dataJson` 在当前页被解析 22 次/节点/tick（CPU 6 + 内存 4 + 磁盘 3 + 网络 4 + 服务 2 + 健康 3），`RenderPlanBuilder.renderValue()`（`RenderPlan.cj:431`）渲染时再按指标各解析一次。
- **方案**：给 `MetricProjection` 增加接受已解析 `Data` 的 `evaluate(data: Data)` 重载（或 `collectValues(path, data)`），在 `observe()` 里对每个 agent 解析一次、按 spec 复用；`RenderPlanBuilder` 同理。`DataPath.solid(path)` 也可按 spec 预先编译并缓存（路径是常量）。
- **预期**：解析次数从 22 降到 1（同一 agent），按 spec 数线性下降；具体自耗时占比未知。
- **代价**：`MetricProjection` 增加重载，`collectValues` 需保留字符串入口以兼容 `AlarmEngine` 等其他调用方；解析结果的生命周期从「一次求值」变成「一次 observe / 一次渲染」。
- **验证**：`cjprof record` 跑 supervisor（10 节点、`pollIntervalMs=5000`）10 分钟，对比改前/改后 `evaluate` 自耗时与总 CPU；同输入同 `-O2`，取中位数。
- **证据状态**：无基线（待验证，不进 tasks）

### [CPU] `ProjectionCatalog.all()` 每次调用重建整份目录

- **现状**：`all()`（`RenderPlan.cj:119-136`）每次都新建 `ArrayList<MetricSpec>`、22 个 `MetricSpec` + `MetricProjection`，并对已收集项做 O(k²) 的 `key()` 字符串比较（每次比较都重新拼 `${kind}.${metric}`）。调用点在 `NodeHistoryStore.observe()`（`NodeHistoryStore.cj:62`），即**每节点每 tick 一次**。
- **方案**：把结果提升为 `private static let` 常量（页面目录本身是编译期常量），或在首次调用后缓存 `Array<MetricSpec>`；`key()` 的拼接结果也可随 `MetricProjection` 一起预计算。
- **预期**：每节点每 tick 省去约 44 次堆分配与约 484 次字符串比较（k=22），数量级可算、收益未测。
- **代价**：`MetricSpec`/`MetricProjection` 变成进程级常驻（22 个对象，可忽略）；若将来支持运行时改指标目录，需要提供失效入口。
- **验证**：`cjprof` 对照 `ProjectionCatalog.all` 自耗时占比；或加分配计数埋点。
- **证据状态**：无基线（待验证，不进 tasks）

### [CPU] 每帧两次 `store.all()`，且排序在锁内

- **现状**：`RenderLoop.renderOnce()` 调 `RenderPlanBuilder.build(viewProvider(), store.all(), ...)`（`fprobe/src/tui/RenderLoop.cj:72`），而 `viewProvider` 是 `SupervisorRuntime.viewOf`，内部又调 `store.all()`（`SupervisorRuntime.cj:264,277-283`）⇒ **同一帧做两次 HashMap 全量复制 + 排序**。`NodeStateStore.all()` 的插入排序 `sortByNode`（`NodeStateStore.cj:48-72`）复杂度 O(n²)，且整个排序在 `synchronized(lock)` 内执行，期间写者（拉取线程 `update`）被阻塞。
- **方案**：一帧只取一次快照，把 `Array<NodeState>` 同时喂给 `viewProvider` 与 `build`（改 `viewOf` 接受 `states` 参数）；`all()` 改为「锁内只复制引用数组 → 锁外排序」，或改用更优排序。
- **预期**：每帧快照次数 2→1；持锁时长与节点数从 O(n²) 比较降到 O(n) 复制 + 锁外排序。
- **代价**：`viewOf` 签名变化（内部方法，影响面小）；排序移出锁后 `all()` 返回的仍是快照，不破坏语义。
- **验证**：节点数 10/100/1000 三档，测 500ms 帧周期下 `NodeStateStore.lock` 等待时长（线程状态或分段计时）。
- **证据状态**：无基线（待验证，不进 tasks）

### [堆内存] 每帧 `Buffer` + 图表单元格矩阵 + `metricRows` 的重复分配

- **现状**：`FprobePainter.draw` 每帧 `Buffer.empty(W×H)`（`FprobePainter.cj:137`）；`ChartPanel.render` 每帧让 `f_chart.tui` 生成 `W×H` 个字符串（`ChartPanel.cj:89`）；`RenderPlanBuilder` 每帧新建 `metricRows` / `series` / 每行临时数组（`RenderPlan.cj:202-226`）。`fprobe/doc/spec/add-fprobe-tui-charts/design.md:207` 已记录「可按 `(series 引用, width, height, type)` 做一帧缓存，本次不做」。
- **方案**：按设计文档的建议给 `ChartPanel` 加一层单帧缓存（键 = 序列引用 + 宽高 + 类型），命中时直接复用上一帧单元格矩阵；`Buffer` 若 `ratatui_buffer` 支持原地清屏也可复用同一实例。
- **预期**：稳态下（数据每 tick 才变）每帧可省一次 `W×H` 字符串矩阵分配，典型 50×13 ≈ 650 个对象/帧、2 帧/秒。
- **代价**：缓存键持有 `values` 数组引用（生命周期到下一帧），需要明确的失效规则（尺寸变化、切页、数据 tick）。
- **验证**：多轮负载下 `getAllocatedHeapSize()` 与 RSS 对照 + 业务计数（帧数），观察是否进入有界稳态。
- **证据状态**：无基线（待验证，不进 tasks）

<!-- 第 9 部分 -->

> 不是缺陷，是「还能更好」。本部分只有 1 条，且无改前基线。

### [CPU] 面板/表格/sparkline 每帧逐格 `setString` 与标题插值

- **现状**：每帧每个 panel 构造一次 `" ${title} "` 字符串（`Panel.cj:56`），边框与竖线逐格 `setString`（`Panel.cj:36-52`）；`Table` 每行 2 次 `setStringn`（`Table.cj:62-66`）；`Sparkline` 每格 1 次 `setString`（`Sparkline.cj:71`）。80×24 终端、500 ms 一帧，单帧约 2×(80+24) 次边框写 + 每序列 ≤ 43 次写。
- **方案**：panel 的上/下边框用一次 `setStringn` 批量写（横向整行串），标题串随 `RenderPlan.pageTitle` 预拼好；sparkline 可按相同档位合并连续单元格后一次写。
- **预期**：无法量化（无基线）。
- **代价**：批量写依赖 `Buffer` 对超宽字符串的裁剪语义；标题缓存需处理 title 变化。
- **验证**：`cjprof record` 跑 TUI 稳态 5 分钟（同 80×24、500 ms 帧间隔），对比 `FprobePainter.paint`/`Panel.draw` 的 self time 与分配量。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

<!-- 第 1 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | README 关于 `llm_metaStore` 覆盖 `llm_confSource` 的结论（`f_llm` 1.3 行为）是否与本仓 `f_llm` 版本一致 | `fprobe/README.md:391-401` | `f_llm` 侧 `LLMConfs.holder()` 的实际分支与版本 | 读 `f_llm` 对应源文件；再配 `--llm_confSource=env` 起一次 `probe_llmTrigger=interval`，看日志是否 `source: store` |
| 2 | `cjpm install` 是否真的产出 `/usr/local/bin/fprobe`（README 说产物是 `target/release/bin/main`） | `fprobe/doc/deployment.md:11` | 实际安装产物名 | 在 WSL 里 `cjpm install --path <tmp>` 后列目录 |
| 3 | TUI 每帧 `W×H` 字符串矩阵（设计标注「可忽略」）是否在低配终端上构成可测开销 | `doc/spec/add-fprobe-tui-charts/design.md:207` | 帧耗时占比 | 80×24 终端下 `cjprof` 采样 10 分钟，看 `ChartPanel.render` / `drawCells` 自耗时 |

<!-- 第 2 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `valueOf` 的 JSON 解析 + `DataPath.solid` 编译占单 tick 的显著比例 | `fprobe/src/alarm/AlarmEngine.cj:185-212` | 自耗时占比、每 tick 分配字节 | `cjprof record`，10 节点 × 20 规则 × 60 tick；对照预编译版本 |
| 2 | `onEvent` 同步做 SMTP 发送，把拉取 tick 串行化（锁竞争之外的第二类阻塞） | `AlarmEngine.cj:233/245` → `SupervisorRuntime.cj:142` → `ChannelDispatcher.cj:68` | tick 实际间隔 P95、SMTP 单次耗时 | 分段计时：`evaluate` 前后、`dispatch` 前后各打时间戳；线程状态采样看 WAITING（CPU profile 看不到） |
| 3 | 抖动场景下的事件量（每 tick 2 条）是否已构成邮件/日志放大 | `AlarmEngine.cj:83-95`、`:166-173` | 每节点每小时事件条数 | 在 `emit` 处加计数器，跑 1 小时"kind 缺失"稳态场景 |

<!-- 第 3 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | TUI 每帧的 `JsonValue.fromStr` + `DataPath.solid` 占帧耗时显著比例（22 指标 × 节点数） | `fprobe/src/tui/RenderPlan.cj:425-436` → `collect/MetricProjection.cj:102-124` | 自耗时占比、每帧分配字节 | `cjprof record` 跑 TUI 稳态 60 帧（10 节点、真实快照），对照"每 kind 解析一次"的改造版 |
| 2 | 串行 tick 的实际时长已接近或超过 `probe_intervalMs`，导致采集漂移 | `collect/ProbeRunner.cj:77-100`、`runtime/AgentRuntime.cj:92-97` | 单轮 tick P50/P95、各探针分段耗时 | 在 `slot.agent.data` 前后打时间戳，跑 1 小时含 snmp/smart/ipmi 的配置；线程状态采样看阻塞占比（CPU profile 看不到） |
| 3 | `FEmailTransport.list` 的 20 次 `uidFetchMessage` 是回复轮询的主要成本 | `channel/FEmailTransport.cj:112-127` | 单次 IMAP 往返耗时、单轮总耗时 | 在 `email.body` 前后计时 + 服务端 IMAP 日志计命令数，跑 10 分钟轮询 |
| 4 | 每 tick 全量 `JsonValue.from(agent.data).toString()` 的分配量在 GC 中占比可观 | `collect/ProbeSnapshotBuilder.cj:32-34`、`ProbeRunner.cj:82` | 每 tick 分配字节、GC 次数 | `cjprof heap` / `getAllocatedHeapSize()` 对比 7 个与 20 个探针两种配置 |

<!-- 第 4 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 硬件探针单轮耗时被外部命令主导（串行），是采集间隔拉长的主因 | `SmartProbe.cj:100-106` / `SnmpProbe.cj:79-101` | 单轮 `ipmi/snmp/smart` 各自耗时与占比 | 分段计时（每设备起止时间戳），配 8 块盘 + 2 个 SNMP 设备跑 30 分钟，给中位数/P95 |
| 2 | 每目标重建 `Client` 的建链开销占 `rpc-health` 主要耗时 | `RpcHealthTransport.cj:57-62` | 建链 vs `transfer` 分段耗时 | 在 `build()` 前后与 `transfer` 前后打点，5 目标 × 10 分钟 |
| 3 | `CpuProbe` 双次解析 `/proc/stat` 的 CPU 占比可忽略 | `CpuProbe.cj:71-75` | `cjprof` self time 占比 | `cjprof record` 1s 间隔 10 分钟，看 `parseAggregate`/`countCores` |
| 4 | 首帧 200ms 差分窗口使 `disk` IOPS 抖动明显大于稳态 | `DiskProbe.cj:216-221` + `ProbeRunner.cj:63-74` | 首帧与稳态 IOPS 分布 | 同一负载下连跑 20 轮，对比首帧与后续帧的 IOPS 均值/方差 |
| 5 | 每 tick 两次 `df`（`-Pk`/`-Pi`）的 fork/exec 开销可被单次 `df` + 解析合并抵消 | `DiskProbe.cj:184-185` | 两次命令耗时与比例 | 分段计时，统计 `df` 占 `disk` 项耗时比例；注意 `df -Pk`/`-Pi` 列不同，合并需 `-P` 一次取全字段并实测兼容性 |

<!-- 第 5 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | topology walk 占采集线程自耗时的主要部分（N≥10 时） | `topology/TopologyProbe.cj:118-147` | 单轮 `tick()` 内 topology 段耗时占比 | 在 `data` 前后打时间戳，N=10 与 N=50、可达/全超时各跑 100 轮取中位数；`cjprof record` 交叉验证 |
| 2 | `splitWhitespace`/`parse*` 的容器分配是 network 探针的主要分配源 | `proc/ProbeParsing.cj:26-35`、`proc/NetworkProbe.cj:246-270` | 每轮分配字节数占比 | 埋点统计每轮分配量，或用 `cjprof heap` 采样对比 |
| 3 | `NetworkProbe` 每帧 `HashMap.get` + `readSpeed` 文件读取是大头 | `proc/NetworkProbe.cj:191-217` | 单帧 `readSpeed` 的 syscall 次数与耗时占比 | 网卡数 2/16 两种场景下分段计时；`strace -c` 统计 `/sys/class/net/*/speed` 打开次数 |
| 4 | 拓扑 `error` 字符串（含 stderr 全文）在设备多、异常多时放大快照体积 | `topology/TopologyProbe.cj:187-189`、`:212-221` | 单帧快照 JSON 字节数随 N 的变化 | 构造 N=50 且全部 exitCode!=0 的 fixture，测量 `error` 字段长度与快照大小 |

<!-- 第 6 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 报告生成是 supervisor 的 CPU 热点（22×N 张 SVG 渲染 + 拼接） | `fprobe/src/report/ReportBuilder.cj:97-133` | `build` 自耗时占比、单张 SVG 平均字节数 | `cjprof record` 跑 `ReportJob.runOnce`，输入 100/1000 节点、每指标 60 历史点 |
| 2 | 提示词构造中重复 JSON 解析占比可观（132 次/节点） | `fprobe/src/llm/PromptBuilder.cj:49-67` | `build` 自耗时、`jsonToData` 累计占比 | `cjprof record` 单次 `PromptBuilder.build`，1000 节点 |
| 3 | 报告正文规模已接近邮件/HTTP 体积上限 | `fprobe/src/report/ReportBuilder.cj:172-173` | 生产节点数与 `draft.html.size` 分布 | 在 `runOnce` 打点记录 `size`，跑一周 CRON |
| 4 | 告警风暴确实产生并发 LLM 请求峰值 | `fprobe/src/llm/ProbeAdvisor.cj:77-82` | 单轮 `analyzeAlarm` 实际并发数、上游 429 次数 | 在 `analyze` 入口计数（进入/退出）并统计 `client.chat` 失败码 |

<!-- 第 7 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `ProbeSnapshot.agents` 的重复 JSON 解析是 supervisor 侧主要 CPU 开销之一 | `fprobe/src/snapshot/ProbeSnapshot.cj:77` | `decodeAgents` 自耗时占比、每 tick 分配量 | `cjprof record` 跑 10 节点 × 15 指标 × 200 tick，对照 `AlarmEngine.evaluate` 与 `decodeAgents` 的 self time |
| 2 | 告警邮件同步发送把 tick 周期拉长到远超 `pollIntervalMs` | `fprobe/src/runtime/SupervisorRuntime.cj:142` | 单次 SMTP 往返耗时（P50/P95）、tick 间隔分布 | 在 `dispatch` 前后打点，注入 5 节点 × 3 规则持续触发，统计 tick 间隔 P95；另用假渠道把发送耗时固定为 2000ms 做对照 |
| 3 | LLM 分析线程会随告警风暴累积 | `fprobe/src/runtime/SupervisorRuntime.cj:145`、`:250` | 并发在飞数、线程数曲线 | 用延迟 30s 的假 `LlmClient`，5 分钟内制造 100 条告警，采集线程数峰值与 LLM 调用完成数 |
| 4 | 渲染帧路径上 `RenderPlan` 构建（含 `agents` 解析）占 RenderLoop 单帧耗时的主要部分 | `fprobe/src/tui/RenderPlan.cj:391` | 单帧耗时分解 | 在 `RenderLoop.renderOnce` 内分段计时（取快照 / 构建 plan / 写终端），10 节点稳态跑 5 分钟取中位数 |

<!-- 第 8 部分 -->

> 没有性能测试数据支撑的猜测，**不进 `todo.md` / `tasks.md`**。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 每节点每 tick 22 次 JSON 解析是拉取线程的主要自耗时 | `NodeHistoryStore.cj:62-71`、`MetricProjection.cj:102` | `evaluate`/`jsonToData` 自耗时占比 | `cjprof record` 跑 supervisor，10 节点、5s tick、10 分钟稳态 |
| 2 | `NodeStateStore.all()` 锁内 O(n²) 插入排序会拖慢拉取线程 | `NodeStateStore.cj:48-72` | 单次持锁时长、写者等待时长 | 节点数 10/100/1000，分段计时 + 线程状态采样 |
| 3 | 每 tick 起 N 个线程的创建/回收开销不可忽略 | `PollLoop.cj:108-111` | 线程峰值、每 tick 线程创建耗时 | 压测 N=10/100/1000，统计 tick 耗时分布（P50/P95） |
| 4 | 每帧 `W×H` 字符串矩阵造成 GC 抖动 | `ChartPanel.cj:89`、`FprobePainter.cj:137` | 每帧分配量、GC 次数 | 加分配计数器，跑 10 分钟，对比有无一帧缓存 |

<!-- 第 9 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 面板边框逐格写 + 标题插值是渲染线程的主要分配/CPU 来源之一 | `fprobe/src/tui/widgets/Panel.cj:36-57` | self time 占比、每帧分配字节数 | `cjprof record` 跑 TUI 5 分钟（80×24，500 ms 帧），按函数聚合 |
| 2 | Sparkline 每帧 O(n) 归一化 + 逐格写在 60 点窗口下可忽略 | `fprobe/src/tui/widgets/Sparkline.cj:36-73` | 单帧耗时与占比 | 在 `RenderLoop.renderOnce` 分段计时（build / draw），稳态 10 分钟取中位数 |

## 文件覆盖

> 与 `files/fprobe.txt` 一一对应；分部分报告逐文件确认已读。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `fprobe/README.md` | .md | ✅ | — |
| 2 | `fprobe/README_en.md` | .md | ✅ | — |
| 3 | `fprobe/doc/alarm-rules.md` | .md | ✅ | — |
| 4 | `fprobe/doc/configuration.md` | .md | ✅ | — |
| 5 | `fprobe/doc/deployment.md` | .md | ✅ | — |
| 6 | `fprobe/doc/rpc.md` | .md | ✅ | — |
| 7 | `fprobe/doc/spec/add-fprobe-tui-charts/design.md` | .md | ✅ | — |
| 8 | `fprobe/doc/spec/add-fprobe-tui-charts/proposal.md` | .md | ✅ | — |
| 9 | `fprobe/doc/spec/add-fprobe-tui-charts/specs/chart-tui/spec.md` | .md | ✅ | — |
| 10 | `fprobe/doc/spec/add-fprobe-tui-charts/specs/probe-supervisor/spec.md` | .md | ✅ | — |
| 11 | `fprobe/doc/spec/add-fprobe-tui-charts/tasks.md` | .md | ✅ | — |
| 12 | `fprobe/doc/spec/add-fprobe/design.md` | .md | ✅ | — |
| 13 | `fprobe/doc/spec/add-fprobe/proposal.md` | .md | ✅ | — |
| 14 | `fprobe/doc/spec/add-fprobe/specs/probe-advisor/spec.md` | .md | ✅ | — |
| 15 | `fprobe/doc/spec/add-fprobe/specs/probe-agent/spec.md` | .md | ✅ | — |
| 16 | `fprobe/doc/spec/add-fprobe/specs/probe-contract/spec.md` | .md | ✅ | — |
| 17 | `fprobe/doc/spec/add-fprobe/specs/probe-reporting/spec.md` | .md | ✅ | — |
| 18 | `fprobe/doc/spec/add-fprobe/specs/probe-supervisor/spec.md` | .md | ✅ | — |
| 19 | `fprobe/doc/spec/add-fprobe/specs/tui-backend/spec.md` | .md | ✅ | — |
| 20 | `fprobe/doc/spec/add-fprobe/tasks.md` | .md | ✅ | — |
| 21 | `fprobe/doc/spec/inline-report-charts/design.md` | .md | ✅ | — |
| 22 | `fprobe/doc/spec/inline-report-charts/proposal.md` | .md | ✅ | — |
| 23 | `fprobe/doc/spec/inline-report-charts/specs/probe-reporting/spec.md` | .md | ✅ | — |
| 24 | `fprobe/doc/spec/inline-report-charts/tasks.md` | .md | ✅ | — |
| 25 | `fprobe/doc/tui.md` | .md | ✅ | — |
| 26 | `fprobe/src/Main_test.cj` | .cj | ✅ | — |
| 27 | `fprobe/src/alarm/AlarmEngine.cj` | .cj | ✅ | — |
| 28 | `fprobe/src/alarm/AlarmEngine_test.cj` | .cj | ✅ | — |
| 29 | `fprobe/src/alarm/AlarmEvent.cj` | .cj | ✅ | — |
| 30 | `fprobe/src/alarm/AlarmRule.cj` | .cj | ✅ | — |
| 31 | `fprobe/src/alarm/AlarmRule_test.cj` | .cj | ✅ | — |
| 32 | `fprobe/src/alarm/MissingDataTracker.cj` | .cj | ✅ | — |
| 33 | `fprobe/src/channel/ChannelDispatcher.cj` | .cj | ✅ | — |
| 34 | `fprobe/src/channel/ChannelDispatcher_test.cj` | .cj | ✅ | — |
| 35 | `fprobe/src/channel/ChannelMessage.cj` | .cj | ✅ | — |
| 36 | `fprobe/src/channel/EmailAlarmChannel.cj` | .cj | ✅ | — |
| 37 | `fprobe/src/channel/EmailAlarmChannel_test.cj` | .cj | ✅ | — |
| 38 | `fprobe/src/channel/FEmailTransport.cj` | .cj | ✅ | — |
| 39 | `fprobe/src/channel/MailTransport.cj` | .cj | ✅ | — |
| 40 | `fprobe/src/collect/Clock.cj` | .cj | ✅ | — |
| 41 | `fprobe/src/collect/Collect_test.cj` | .cj | ✅ | — |
| 42 | `fprobe/src/collect/IntervalCounter.cj` | .cj | ✅ | — |
| 43 | `fprobe/src/collect/JsonData.cj` | .cj | ✅ | — |
| 44 | `fprobe/src/collect/MetricProjection.cj` | .cj | ✅ | — |
| 45 | `fprobe/src/collect/ProbeFactory.cj` | .cj | ✅ | — |
| 46 | `fprobe/src/collect/ProbeFactory_test.cj` | .cj | ✅ | — |
| 47 | `fprobe/src/collect/ProbeRunner.cj` | .cj | ✅ | — |
| 48 | `fprobe/src/collect/ProbeRunner_test.cj` | .cj | ✅ | — |
| 49 | `fprobe/src/collect/ProbeSnapshotBuilder.cj` | .cj | ✅ | — |
| 50 | `fprobe/src/collect/health/HealthMetrics.cj` | .cj | ✅ | — |
| 51 | `fprobe/src/collect/health/HttpProbe.cj` | .cj | ✅ | — |
| 52 | `fprobe/src/collect/health/MvcHealthProbe.cj` | .cj | ✅ | — |
| 53 | `fprobe/src/collect/health/MvcHealthProbe_test.cj` | .cj | ✅ | — |
| 54 | `fprobe/src/collect/health/RpcHealthProbe.cj` | .cj | ✅ | — |
| 55 | `fprobe/src/collect/health/RpcHealthProbe_test.cj` | .cj | ✅ | — |
| 56 | `fprobe/src/collect/health/RpcHealthTransport.cj` | .cj | ✅ | — |
| 57 | `fprobe/src/collect/hw/CommandRunner.cj` | .cj | ✅ | — |
| 58 | `fprobe/src/collect/hw/CommandRunner_test.cj` | .cj | ✅ | — |
| 59 | `fprobe/src/collect/hw/HardwareParsing.cj` | .cj | ✅ | — |
| 60 | `fprobe/src/collect/hw/HardwareProbe.cj` | .cj | ✅ | — |
| 61 | `fprobe/src/collect/hw/HardwareProbe_test.cj` | .cj | ✅ | — |
| 62 | `fprobe/src/collect/hw/IpmiProbe.cj` | .cj | ✅ | — |
| 63 | `fprobe/src/collect/hw/IpmiProbe_test.cj` | .cj | ✅ | — |
| 64 | `fprobe/src/collect/hw/SmartProbe.cj` | .cj | ✅ | — |
| 65 | `fprobe/src/collect/hw/SmartProbe_test.cj` | .cj | ✅ | — |
| 66 | `fprobe/src/collect/hw/SnmpProbe.cj` | .cj | ✅ | — |
| 67 | `fprobe/src/collect/hw/SnmpProbe_test.cj` | .cj | ✅ | — |
| 68 | `fprobe/src/collect/net/ServiceReachabilityProbe.cj` | .cj | ✅ | — |
| 69 | `fprobe/src/collect/net/ServiceReachabilityProbe_test.cj` | .cj | ✅ | — |
| 70 | `fprobe/src/collect/net/TcpProbe.cj` | .cj | ✅ | — |
| 71 | `fprobe/src/collect/proc/CpuProbe.cj` | .cj | ✅ | — |
| 72 | `fprobe/src/collect/proc/CpuProbe_test.cj` | .cj | ✅ | — |
| 73 | `fprobe/src/collect/proc/DiskProbe.cj` | .cj | ✅ | — |
| 74 | `fprobe/src/collect/proc/DiskProbe_test.cj` | .cj | ✅ | — |
| 75 | `fprobe/src/collect/proc/MemoryProbe.cj` | .cj | ✅ | — |
| 76 | `fprobe/src/collect/proc/MemoryProbe_test.cj` | .cj | ✅ | — |
| 77 | `fprobe/src/collect/proc/NetworkProbe.cj` | .cj | ✅ | — |
| 78 | `fprobe/src/collect/proc/NetworkProbe_test.cj` | .cj | ✅ | — |
| 79 | `fprobe/src/collect/proc/ProbeParsing.cj` | .cj | ✅ | — |
| 80 | `fprobe/src/collect/proc/ProcReader.cj` | .cj | ✅ | — |
| 81 | `fprobe/src/collect/proc/ProcReader_test.cj` | .cj | ✅ | — |
| 82 | `fprobe/src/collect/proc/SystemProbe.cj` | .cj | ✅ | — |
| 83 | `fprobe/src/collect/proc/SystemProbe_test.cj` | .cj | ✅ | — |
| 84 | `fprobe/src/collect/topology/IfMibParser.cj` | .cj | ✅ | — |
| 85 | `fprobe/src/collect/topology/LldpParser.cj` | .cj | ✅ | — |
| 86 | `fprobe/src/collect/topology/TopologyProbe.cj` | .cj | ✅ | — |
| 87 | `fprobe/src/collect/topology/TopologyProbe_test.cj` | .cj | ✅ | — |
| 88 | `fprobe/src/config/AgentSettings.cj` | .cj | ✅ | — |
| 89 | `fprobe/src/config/Settings_test.cj` | .cj | ✅ | — |
| 90 | `fprobe/src/config/SupervisorSettings.cj` | .cj | ✅ | — |
| 91 | `fprobe/src/config/Validation.cj` | .cj | ✅ | — |
| 92 | `fprobe/src/custom/CustomLoader.cj` | .cj | ✅ | — |
| 93 | `fprobe/src/custom/CustomLoader_test.cj` | .cj | ✅ | — |
| 94 | `fprobe/src/llm/ActionWhitelist.cj` | .cj | ✅ | — |
| 95 | `fprobe/src/llm/ActionWhitelist_test.cj` | .cj | ✅ | — |
| 96 | `fprobe/src/llm/AdviceParser.cj` | .cj | ✅ | — |
| 97 | `fprobe/src/llm/AdviceParser_test.cj` | .cj | ✅ | — |
| 98 | `fprobe/src/llm/LlmAdvice.cj` | .cj | ✅ | — |
| 99 | `fprobe/src/llm/LlmClient.cj` | .cj | ✅ | — |
| 100 | `fprobe/src/llm/LlmTestSupport_test.cj` | .cj | ✅ | — |
| 101 | `fprobe/src/llm/ProbeAdvisor.cj` | .cj | ✅ | — |
| 102 | `fprobe/src/llm/ProbeAdvisor_test.cj` | .cj | ✅ | — |
| 103 | `fprobe/src/llm/PromptBuilder.cj` | .cj | ✅ | — |
| 104 | `fprobe/src/llm/PromptBuilder_test.cj` | .cj | ✅ | — |
| 105 | `fprobe/src/llm/ReplyMonitor.cj` | .cj | ✅ | — |
| 106 | `fprobe/src/llm/ReplyMonitor_test.cj` | .cj | ✅ | — |
| 107 | `fprobe/src/llm/ReplyStateStore.cj` | .cj | ✅ | — |
| 108 | `fprobe/src/llm/ReplyStateStore_test.cj` | .cj | ✅ | — |
| 109 | `fprobe/src/main.cj` | .cj | ✅ | — |
| 110 | `fprobe/src/report/ChartSelector.cj` | .cj | ✅ | — |
| 111 | `fprobe/src/report/ChartSelector_test.cj` | .cj | ✅ | — |
| 112 | `fprobe/src/report/ChartSpec.cj` | .cj | ✅ | — |
| 113 | `fprobe/src/report/ChartSpec_test.cj` | .cj | ✅ | — |
| 114 | `fprobe/src/report/ReportBuilder.cj` | .cj | ✅ | — |
| 115 | `fprobe/src/report/ReportBuilder_test.cj` | .cj | ✅ | — |
| 116 | `fprobe/src/report/ReportJob.cj` | .cj | ✅ | — |
| 117 | `fprobe/src/report/ReportJob_test.cj` | .cj | ✅ | — |
| 118 | `fprobe/src/report/ReportTestSupport_test.cj` | .cj | ✅ | — |
| 119 | `fprobe/src/report/TopologyRenderer.cj` | .cj | ✅ | — |
| 120 | `fprobe/src/report/TopologyRenderer_test.cj` | .cj | ✅ | — |
| 121 | `fprobe/src/rpc/NodeEndpoint.cj` | .cj | ✅ | — |
| 122 | `fprobe/src/rpc/NodeRpcTransport.cj` | .cj | ✅ | — |
| 123 | `fprobe/src/rpc/ProbeRPC.cj` | .cj | ✅ | — |
| 124 | `fprobe/src/rpc/ProbeRPCImpl.cj` | .cj | ✅ | — |
| 125 | `fprobe/src/rpc/RpcTestSetup_test.cj` | .cj | ✅ | — |
| 126 | `fprobe/src/rpc/Rpc_test.cj` | .cj | ✅ | — |
| 127 | `fprobe/src/runtime/AgentRuntime.cj` | .cj | ✅ | — |
| 128 | `fprobe/src/runtime/RuntimeSupport.cj` | .cj | ✅ | — |
| 129 | `fprobe/src/runtime/SupervisorBootstrap.cj` | .cj | ✅ | — |
| 130 | `fprobe/src/runtime/SupervisorRuntime.cj` | .cj | ✅ | — |
| 131 | `fprobe/src/runtime/SupervisorRuntime_test.cj` | .cj | ✅ | — |
| 132 | `fprobe/src/snapshot/ProbeSnapshot.cj` | .cj | ✅ | — |
| 133 | `fprobe/src/snapshot/SnapshotStore_test.cj` | .cj | ✅ | — |
| 134 | `fprobe/src/supervisor/HistoryRing.cj` | .cj | ✅ | — |
| 135 | `fprobe/src/supervisor/HistoryRing_test.cj` | .cj | ✅ | — |
| 136 | `fprobe/src/supervisor/NodeState.cj` | .cj | ✅ | — |
| 137 | `fprobe/src/supervisor/NodeStateStore.cj` | .cj | ✅ | — |
| 138 | `fprobe/src/supervisor/NodeStateStore_test.cj` | .cj | ✅ | — |
| 139 | `fprobe/src/supervisor/PollLoop.cj` | .cj | ✅ | — |
| 140 | `fprobe/src/supervisor/PollLoop_test.cj` | .cj | ✅ | — |
| 141 | `fprobe/src/tui/ChartPanel.cj` | .cj | ✅ | — |
| 142 | `fprobe/src/tui/ChartPanel_test.cj` | .cj | ✅ | — |
| 143 | `fprobe/src/tui/FprobePainter.cj` | .cj | ✅ | — |
| 144 | `fprobe/src/tui/FprobePainter_test.cj` | .cj | ✅ | — |
| 145 | `fprobe/src/tui/KeyMap.cj` | .cj | ✅ | — |
| 146 | `fprobe/src/tui/KeyMap_test.cj` | .cj | ✅ | — |
| 147 | `fprobe/src/tui/NodeHistoryStore.cj` | .cj | ✅ | — |
| 148 | `fprobe/src/tui/NodeHistoryStore_test.cj` | .cj | ✅ | — |
| 149 | `fprobe/src/tui/Painter.cj` | .cj | ✅ | — |
| 150 | `fprobe/src/tui/RenderLoop.cj` | .cj | ✅ | — |
| 151 | `fprobe/src/tui/RenderLoop_test.cj` | .cj | ✅ | — |
| 152 | `fprobe/src/tui/RenderPlan.cj` | .cj | ✅ | — |
| 153 | `fprobe/src/tui/RenderPlan_test.cj` | .cj | ✅ | — |
| 154 | `fprobe/src/tui/SupervisorApp.cj` | .cj | ✅ | — |
| 155 | `fprobe/src/tui/SupervisorApp_test.cj` | .cj | ✅ | — |
| 156 | `fprobe/src/tui/TtyDetector.cj` | .cj | ✅ | — |
| 157 | `fprobe/src/tui/TtyDetector_test.cj` | .cj | ✅ | — |
| 158 | `fprobe/src/tui/TtyKeySource.cj` | .cj | ✅ | — |
| 159 | `fprobe/src/tui/TtyKeySource_test.cj` | .cj | ✅ | — |
| 160 | `fprobe/src/tui/TuiLayout.cj` | .cj | ✅ | — |
| 161 | `fprobe/src/tui/TuiLayout_test.cj` | .cj | ✅ | — |
| 162 | `fprobe/src/tui/ViewModel.cj` | .cj | ✅ | — |
| 163 | `fprobe/src/tui/ViewModel_test.cj` | .cj | ✅ | — |
| 164 | `fprobe/src/tui/widgets/Panel.cj` | .cj | ✅ | — |
| 165 | `fprobe/src/tui/widgets/Sparkline.cj` | .cj | ✅ | — |
| 166 | `fprobe/src/tui/widgets/Table.cj` | .cj | ✅ | — |
| 167 | `fprobe/src/usage.cj` | .cj | ✅ | — |

合计：`.cj` 142 个 / `.md` 25 个 / 共 167 个，全部读完。

## 覆盖自检

### 第 1 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 3 | 文档承诺的正确性 2 条（#4 退出码契约、#6 告警覆盖范围）+ 安全预期 1 条（#7 SM4）；语言特性与可读性无文档主张需要核对 |
| §1 死代码 | 2 | 生产源码零读取的配置键 4 个（#1）；恒不生效的冷却分支（#5）。`private`/`internal` 符号引用面不在本部分文件内，留源码部分 |
| §2 重复逻辑 | 0 | 已逐条比对 14 份文档中的告警字段表（README:245-253 / alarm-rules:39-47）、状态机（README:258-267 / alarm-rules:53-60）、图表默认表（alarm-rules:62-74 / configuration:78-79）三组重复维护；漂移已分别计入 #2 / #3，按「同根因合并」不另立发现 |
| §3 空实现 | 1 | `probe_llmMaxTokens` 承诺有行为、代码无实现，与 #1 同根因不重复计数 |
| §4 栈溢出 | 0 | 本部分无代码；文档未描述递归结构 |
| §5 OOM | 0 | 文档未承诺无界增长能力；`probe_historyPoints`、回复状态 1000 条上限已核对为有界 |
| §6.1 热点瓶颈 | 0 | 无 profile / bench 数据；文档未给出任何耗时数字，热点不成立（`design.md:207` 的自评已列入待验证假设 #3） |
| §6.2 大粒度锁 | 0 | 本部分无锁相关承诺；`README.md:17-18` 的「一次 RPC 拉全量」已与 `PollLoop.tick` 的一次 `collect` 核对一致 |
| §6.3 并发串行 | 0 | 同上；`PollLoop` 对每节点 `spawn` 后统一 `get()` 属「先提交后汇合」，与文档一致 |
| §6.4 低效算法 | 0 | 本部分无代码 |
| §7 降堆内存方案 | 0 | 文档层面无可量化收益项 |
| §8 降 CPU 方案 | 0 | 同上；无基线，不产出方案 |
| §9 local mode 可行性 | 0 | 本部分无函数内临时对象 |
| §11 现有代码的 BUG（存量） | 3 | 取证过程中核实并已计入：规则/CRON 校验走错退出码路径（#4）、冷却恒不生效（#5）、硬件/拓扑内部 error 不告警（#6） |
| §12 并发安全与锁粒度 | 0 | 文档未做线程安全承诺；顺带核对了 `SnapshotStore` 的引用整体替换语义（`ProbeSnapshot.cj:128-152`），与「collect 只读快照」一致；线程级审查留给源码部分 |
| §14 功能完备性与 README 覆盖 | 4 | #1（4 个配置键未接线）、#2（`probe_chart_*` 键与默认表）、#6（承诺的硬件降级告警路径缺失）、#9（自定义 kind 的 TUI 能力）；其余 public API 已按附录逐项抽查存在 |
| 文件覆盖（§13 等） | 14/14 | 无缺失；`files/fprobe.part1.txt` 14 行全部对应；文档相对链接逐个检查无死链 |

### 第 2 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 3 | 发现 #2（缺 kind 抖动）、#10（假恢复）、#6（错误契约）；分层与依赖方向正常（`alarm` 只依赖 `f_data`/`fprobe.snapshot`/`collect.Clock`），无注入面（`AlarmEvent.format` 只输出到文本/HTML，HTML 侧由 `EmailAlarmChannel.escapeHtml` 转义） |
| §1 死代码 | 2 | 发现 #11（unused import）；`isRecovery`/`AlarmOp.toString` 归入 #7 的可见性建议（executable 模块无下游）。机械核对过：`RuleState`、`ALARM_RULE_FIELDS`、`invalid`、`validate`、`sendOne`、`number`、`stateOf`、`isMuted`、`cooldownElapsed`、`emit` 均有调用者；`evaluateRules` 的 `case None => ()` 与 `dispatch` 的 `case None => ()` 是构造期校验后的防御分支，不判死代码 |
| §2 重复逻辑 | 3 | 发现 #9（三处同语义实现）；另比对了本部分 2 个 enum 的手写 `operator ==`（`AlarmEventType:26-32`、`AlarmOp:33-38`，同模块还有 `NodeStatus`/`ReplyDecision`/`WhitelistResult`/`UiKey` 同形），语言文档未提供枚举自动派生 `Equatable` 的依据，不据此判重复；测试里的 `dispatchWith` 样板属测试准备代码，不计 |
| §3 空实现 | 1 | 发现 #5（`emit` 空 catch）；无空函数体、无 TODO/占位实现 |
| §4 栈溢出 | 0 | 本部分无自递归/间接递归：`evaluate → evaluateMissing/evaluateRules → applyRule → emit → onEvent` 是单向调用链，`onEvent` 不回调引擎；`DataPath` 的递归遍历在 `f_data`，深度由 `rule.path`（配置常量）决定 |
| §5 OOM | 0 | `states`/`mutedUntil`/`active` 三个容器键空间分别上界为 节点×规则名、规则名、节点×(kind+error)，均来自启动配置与授权回复；无按报文长度预分配、无全量物化 |
| §6.1 热点瓶颈 | 0 | 无 profile/bench 数据；`valueOf` 的重复解析只作为线索，已进「待验证假设 #1」与优化方案（无基线） |
| §6.2 大粒度锁 | 0 | 本部分未使用锁；真正的跨线程问题按 §12.1 记为严重（发现 #1），不重复计为锁粒度问题 |
| §6.3 并发串行 | 0 | 无 `spawn`/`get`；`onEvent` 同步发送导致 tick 与 SMTP 串行，属性能假设（待验证 #2），无测量数据不定性 |
| §6.4 低效算法 | 0 | `evaluateRules` 的 `rules × agents` 双层扫描规模为配置量级（≤ 数十），`valueOf` 的重复解析已按"无基线"处理，未写成缺陷 |
| §7 降堆内存方案 | 0 | 每 tick 的临时对象（2 个 `HashSet`、`DataObject` 树、事件对象）生命周期都在单次 `evaluate` 内，无长期持有；未取得分配量数据，不提方案 |
| §8 降 CPU 方案 | 1 | 优化方案 1（预编译 path/op + 每 kind 解析一次），证据状态「无基线」 |
| §9 local mode 可行性 | 0 | `AlarmEvent` 经 `onEvent`（`AlarmEngine.cj:276-284`）逃逸到 `SupervisorRuntime` 的事件表与告警渠道，直接违反 local mode 的逃逸约束；`DataObject` 树虽在函数内构建，但没有改前改后的峰值内存对照，收益无法证明 |
| §11 现有代码的 BUG（存量） | 5 | 发现 #2/#3/#4/#6/#10 |
| §12 并发安全与锁粒度 | 1 | 发现 #1（`mutedUntil` 跨线程无同步）；判定给出具体两条线程路径与缺失的同步手段 |
| §13 文档一致性 | 0 | `doc/tui.md` 逐条核对通过（见覆盖表 #11）。归档 spec 按「当时自洽」口径核对：默认值、依赖清单、错误码与任务勾选均自洽。两点说明不计缺陷：(a) `probe-reporting` 的附件模型被 `inline-report-charts` 取代，两份并存且无 superseded 指针；(b) `add-fprobe/tasks.md:170` 要求与 `openspec/changes/add-fprobe/` 保持镜像，而该目录已不存在（`ls openspec/changes` 仅 `add-f-a2a/`、`archive/`），属失效路径，建议合并时改成"本目录为唯一副本" |
| §14 功能完备性与 README 覆盖 | 1 | 发现 #3（`probe_alarmCooldownSeconds` 承诺的冷却窗口在实现中不存在）。README 不在本部分（属其它分部分），未做公开 API 对照 |
| 文件覆盖（§13 等） | 20/20 | 无缺文件 |

### 第 3 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 4 | 发现 #2（回复饥饿）、#3（顺序契约）、#4（全 0 健康数据）、#13（未释放资源）；分层正常（`channel` 只依赖 `f_email`/`f_probe`/`f_data`，`collect` 不反向依赖 `runtime`）；HTML 侧 `escapeHtml`（`EmailAlarmChannel.cj:182-188`）覆盖 `& < > "`，告警文本进 HTML 前已转义，无注入；`Sql`/命令拼接不在本部分 |
| §1 死代码 | 2 | 机械核对过本部分全部 `private`/`internal` 符号：`subjectOf`/`renderHtml`/`fileName`/`mediaType`/`escapeHtml`（`EmailAlarmChannel.cj` 内互调）、`adapt`/`JsonObjectData`/`JsonArrayData`/`JsonArrayDataIterator`（`adapt` 与迭代器互引）、`healthJson`、`registerIfAbsent`、`collectValues`、`elapsedMs`、`ProbeSlot`（`ProbeRunner.cj:41/50` 使用）均有调用者；`DataParsable.parse/tryParse` 为接口实现不判。仅测试引用两项按可见性建议处理：`IntervalCounter`（发现 #11）、`ProbeSnapshotBuilder.agentData`（发现 #8）。`import` 逐个核对，无未使用导入 |
| §2 重复逻辑 | 5 | 发现 #6（耗时换算 ×3 + 文案 ×2）、#7（11 字段 ×3 + DTO→JsonObject ×2）、#8（host 回退/编码 ×2）、#9（发布职责 ×2）、#10（标题解析 ×2）；同文件内两两比对了 `EmailAlarmChannel` 的 5 个私有函数、`HealthMetrics`/`HealthSample` 的构造块、`MetricProjection.collectValues`，差异均为语义差异（错误文案、可空性） |
| §3 空实现 | 0 | 无空函数体、无 `TODO`/`FIXME`（`grep` 空）、无 `throw UnsupportedException`；`catch (_: Exception)` 均有返回值或日志（`jsonToData`→None、`tryParse`→None、`collectValues`→空数组）属注释声明的降级语义；`HealthSample.init(){}`/`ChannelMessage.init(){}` 是 `@DataAssist` 生成所需 |
| §4 栈溢出 | 0 | 本部分无自递归/间接递归：`adapt` 每次只包一层（深层走 `get`/迭代器，不递归整棵树），`jsonToData` 的解析深度由 `f_data` 的 `JsonValue.fromStr` 决定（远端 HTTP 响应），不在本部分；`renderHtml`/`subjectOf` 都是单层循环 |
| §5 OOM | 1 | 发现 #5（`readEntire` 无上限，量级 = 带宽 × 2s）。其余容器有界：`slots`（探针数）、`readings`（目标数）、`rows`（消息行数）、`specs`（附件数）、`list(20)` |
| §6.1 热点瓶颈 | 0 | 无 profile/bench 数据；`evaluate` 重复解析、串行 tick、IMAP 逐封取信都只作线索，已进「优化方案（无基线）」与「待验证假设」表 1-3 行，未写成缺陷 |
| §6.2 大粒度锁 | 0 | 本部分无锁；`SnapshotStore` 的锁在 `snapshot/ProbeSnapshot.cj:135-152`（范围外），临界区只做引用交换；发现 #1 是"缺少同步"而非"锁太大" |
| §6.3 并发串行 | 0 | `RpcHealthProbe` 逐目标串行、`ProbeRunner` 逐探针串行属结构性串行，但无测量数据，按 §6.3 要求放进优化方案 2 与待验证假设表第 2 行，不计缺陷 |
| §6.4 低效算法 | 0 | `subjectOf` 的 `split` 与 `renderHtml` 的 `indexOf(':')` 都是 O(行长)，消息行数为个位数；`Aggregation` 的 4 个分支均为单趟 O(n)；无嵌套循环匹配 |
| §7 降堆内存方案 | 1 | 优化方案 3（IMAP 逐封正文 → 摘要+按需正文），证据状态「无基线」 |
| §8 降 CPU 方案 | 2 | 优化方案 1（TUI 每格重解析）、2（串行 tick），均「无基线」 |
| §9 local mode 可行性 | 0 | 本部分没有"函数内创建、函数内释放"的大对象：`HealthSample`/`RpcHealthTarget` 经 `toData()` 变成 `JsonObject` 返回给 `ProbeAgent.data`，`OutgoingMail` 交给 transport，`renderHtml` 的字符串进 `OutgoingMail` —— 全部逃逸；且无改前/改后峰值内存对照，收益不可证 |
| §11 现有代码的 BUG（存量） | 7 | 发现 #1（并发竞争）、#2（回复饥饿）、#3（顺序契约）、#4（全 0 健康数据）、#5（无上限读响应体）、#12（`parse` 返回类型不符）、#13（未释放 `Email` 会话 / 媒体类型承诺） |
| §12 并发安全与锁粒度 | 1 | 发现 #1（`Email` 跨 4 条线程，给出线程路径与被共享字段）；`ProbeRunner` 的 `slots` 经核对为采集线程封闭（`AgentRuntime.cj:92-97` 单线程 tick，发布走 `SnapshotStore` 的锁），未判问题；`MetricProjection`/`Aggregation` 是只读值对象 |
| §13 文档一致性 | 0 | 本部分不含 `.md`（20 个文件全为 `.cj`）；`.cj` 内的接口注释与实现不一致已按 §11 报（#3 `list` 顺序、#13 媒体类型、#4 "非法响应"） |
| §14 功能完备性与 README 覆盖 | 0 | 本部分不含 `.md`，README 覆盖由其它部分核对。`probe_channel_email_receiveLimit` 未接线的承诺源在 part1（`doc/configuration.md:66`），源码落点 `EmailAlarmChannel.cj:35-41` 在本部分——已在跨部分提示里指明与 part1 #1 合并，不重复计数 |
| 文件覆盖（§13 等） | 20/20 | 无缺文件 |

### 第 4 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 7 | 正确性：F1（健康状态映射）、F2（`-` 占位符）、F3（差分基线）、F4（地址解析）、F5（异常路径资源）、F8（单位/数值）；安全性：F9。设计/可读性无独立命中（`requireFile` 放在 `CpuProbe.cj` 但被 4 个探针共用，属共享 helper 落点问题，收益低，记此一句不作发现） |
| §1 死代码 | 1 | 已对 20 个文件逐个扫：每个 `private` 符号全仓搜、每个 `internal` 符号搜本包及子包、`public` 先判对外可达性（`HardwareProbe`/`DiskProbe`/`CpuProbe`/`SnmpDevice`/`CommandRunner` 等对外可达不判）；仅 F10 命中。`FixtureCommandRunner`/`Stub`/`Fake*` 属测试辅助，按硬原则一不作死代码 |
| §2 重复逻辑 | 2 | F11（6 组跨文件/跨包副本，逐行比对函数体后确认）、F12（同文件 2 组）。另两两比对了 `parseMountTypes`/`splitAuthority`/`authorityOf`/`valueAfterColon`/`oidName`/`stripQuotes`/`firstNumber`，输入-输出语义不同，不合并 |
| §3 空实现 | 1 | F13（`catch { () }` 吞掉 terminate 失败）。`SmartProbe.parseJson` 的 `catch → None` 有文本回退兜底，`IpmiProbe`/`SnmpProbe` 的 `case None => ()` 属可选分支，未计 |
| §4 栈溢出 | 0 | 本部分无递归：`parseSdr`/`parseWalk`/`parseMountTypes`/`parseDiskstats` 均为单层 `for`；唯一按结构深度递归的路径在 `f_data` 的 JSON 解析/转换，深度由 `smartctl -j` 的固定子结构决定（`SmartctlReport` ≤3 层），不成立 |
| §5 OOM | 1 | F7（命令输出无上限）；F3 的 `previous` 残留已在描述里量化（每条约 100–200 字节），不单列 |
| §6.1 热点瓶颈 | 0 | 本模块无 `cjprof`/`cjpm bench` 数据，按铁律不把「串行/重复解析」写成热点，全部进「待验证假设」#1–#5 |
| §6.2 大粒度锁 | 0 | 本部分无 `synchronized`/`Mutex`/锁对象，临界区讨论不适用 |
| §6.3 并发串行 | 1 | F6（设备级串行 + 单轮预算缺失），已给计算式 `(1+N+M)×timeout` |
| §6.4 低效算法 | 0 | 逐函数看了复杂度：解析均为单趟 O(行数)；`HashMap` 查找 O(1)；无 `remove(at: 0)`/循环内 `contains`/平方级拼接。`joinTokens` 的 `+=` 在 ≤10 元素规模上不构成 O(n²) 热点 |
| §7 降堆内存方案 | 1 | O4（命令输出上限 + 缓冲复用）；`clear()` 不还内存、`gc()` 不保证归还的口径已排除，不作为方案依据 |
| §8 降 CPU 方案 | 3 | O1（设备级有界并发）、O2（复用 Client）、O3（单趟解析 `/proc/stat`）；均为 `无基线` |
| §9 local mode 可行性 | 0 | 本部分热点函数（`parse*`/`collect*`）的临时对象随 `data` 返回值逃逸（`JsonObject`/`Array<Reading>` 直接返回或写入快照），不满足逃逸检查；且无峰值内存数据，无法证明收益 |
| §11 现有代码的 BUG（存量） | 8 | 逐函数核对了边界/空值/错误处理/资源/契约：F1、F2、F3（边界与基线）、F4（API 语义）、F5（资源）、F8（单位）、F9（校验缺口）、F13（静默吞异常）。`parseTarget` 的端口上下界、`authorityOf` 的 `/?#` 截断、`splitAuthority` 空端口默认值均核对无缺陷 |
| §12 并发安全与锁粒度 | 0 | 已定位唯一采集路径：`AgentRuntime.serve` 在主线程 `warmup()`+首帧 `tick()`，随后单线程 `spawn` 循环调用 `runner.tick()`（`AgentRuntime.cj:84-101`），`ProbeRunner.tick` 串行遍历探针（`ProbeRunner.cj:77-100`）⇒ `CpuProbe`/`DiskProbe` 的跨帧状态（`hasBaseline`/`last*`/`previous`）为线程封闭，无共享写者。注意：`ProbeAgent.data` 契约未声明非线程安全，若将来外部并发调用同一实例会产生数据竞争，建议在接口注释补一句（不单列发现） |
| §14 功能完备性与 README 覆盖 | 0 | 本部分无 README/doc 文件；按 `fprobe/README.md:139-151` 的监控项表逐字段核对：`disk`/`cpu`/`hardware`/`service` 的字段名、来源、差分语义与实现一致；`ipmiEnabled`/`smartDevices`/`snmpDevices`/`serviceTargets` 均已在 `ProbeFactory.cj:44-67` 接线，无「注册但未使用」的配置项 |
| 文件覆盖（§13 等） | 20/20 | 清单 20 个文件全部读完；本部分不含 `.md`，§13 文档一致性无对象（相关承诺在 README，已在上行按需核对） |

### 第 5 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 4 | 正确性 2（远端端口聚合、snmp 重名）、设计 1（topology 周期与主采集耦合）、安全性 1（community 进 argv）；语言特性上 `@When` 两分支、`?T` 用法与仓内惯例一致，未见误用 |
| §1 死代码 | 1 | 逐个搜索：`parseMeminfo/requireValue/networkNowMs/readOptional/parseNetDev/requireNetInt/parseSnmp/snmpValue/parseUptime/countSocketRows/startsWithDigit/isNumericName/observationKey/localPortIndex/edgeKey/joinErrors/defaultHost/isLibrary/withoutExtension/validServiceTarget/isValidFsName/isSafeDevicePath/isSafeInterfaceName/hasWhitespace/hasShellMeta` 在 `fprobe`+`f_probe` 内均有调用者；`splitWhitespace/joinFrom/tryInt64/tryFloat64/clampPercent/nonNegativeDelta/parseWalk/parseIfMib/trimLeadingDots/unquote` 为包内 internal 且有跨文件使用；`WalkEntry/WalkResult/NetCounters/SnmpCounters/LldpObservation/IfPort` 均在包内被实例化或读取；`IF_MIB_WALK_OID/LLDP_MIB_WALK_OID/ProcReader 及三个实现/CustomLoader/MemoryProbe 等` 顶层 public 对外可达，按硬原则一不判；命中 1 条：`Settings_test.cj:22-23` 两个未使用 import；无 `return/throw/break/continue` 之后的同层语句 |
| §2 重复逻辑 | 3 | 已两两比对 20 个文件内全部函数体摘要，命中 3 条合并项：walk 解析（含 `unquote`/`stripQuotes` 漂移）、`readOptional`×2、零散复制（`hasWhitespace/hasShellMeta`、4 份字符白名单、时间换算×3、默认端口×2）；其余（`MemoryProbe.data`/`SystemProbe.data`/`NetworkProbe.data` 的 “读→解析→建模” 骨架）差异在解析对象与错误消息，不合并 |
| §3 空实现 | 1 | 唯一疑似：`NetworkProbe` 白名单全不命中时返回空集合且无 error（已计入发现）；`ProcReader.list` 默认 `None`、`ActionWhitelist` 默认空回调都有文档说明，属有意的 Null Object，不判 |
| §4 栈溢出 | 0 | 无递归：`parseMeminfo/parseNetDev/parseSnmp/parseWalk/parseLldp/countSocketRows` 全为单层循环；`CustomLoader.librariesOf` 用 `Directory.walk` 回调（非自递归）；无自引用结构 |
| §5 OOM | 1 | `NetworkProbe.previous` 无淘汰（量级小，已按轻微报）；`TopologyProbe` 每轮缓冲单台设备的 walk 输出，规模随端口数线性，未见按不可信长度预分配 |
| §6.1 热点瓶颈 | 0 | 无 profile / bench 数据；所有疑似热点（topology 串行、`splitWhitespace` 分配、`readSpeed` 每帧读文件）已写入「待验证假设」 |
| §6.2 大粒度锁 | 0 | 本部分无锁（全模块只读代码，无 `synchronized`/`Mutex`）；采集线程串行问题记在 §6.3 |
| §6.3 并发串行 | 1 | `TopologyProbe` 串行 walk + 单采集线程（发现 1）；未发现 `spawn` 后立刻 `get` 的伪并发 |
| §6.4 低效算法 | 0 | `snmpValue` 线性查表（列数 ~15）、`trimLeadingDots` 循环去点（≤2 次）、`CustomLoader.sort` 插入排序（扩展库个数为个位数）均未达需优化规模；`previous` 的 `HashMap` 查找为 O(1) |
| §7 降堆内存方案 | 1 | 解析中间容器复用（优化方案，无基线） |
| §8 降 CPU 方案 | 1 | topology 周期解耦 / 有界并发（优化方案，无基线） |
| §9 local mode 可行性 | 0 | `fprobe/cjpm.toml` 为 `-O2 --dy-std`，未启用 local mode；本部分临时对象都是几十~几百个小字符串，无“函数内大对象 + 峰值内存”证据，收益无法证明，写不出前后峰值对照 |
| §11 现有代码的 BUG（存量） | 12 | 16 条发现中 12 条为存量逻辑/边界/契约缺陷（另 3 条重复逻辑记 §2、1 条未使用 import 记 §1）。逐函数核对：`NetworkProbe` 计数下标（0..3 / 8..11）与 `/proc/net/dev` 布局一致，`SystemProbe` 表头判定、`LldpParser` OID 列号（.7/.9）与 LLDP-MIB 一致，未误判 |
| §12 并发安全与锁粒度 | 1 | 已列出共享点：`NetworkProbe` 的 `previous/hasBaseline/lastNowMs` 与 `previousSnmp` 是实例可变状态，唯一调用方为 `AgentRuntime` 的单个采集线程（线程封闭），无同步但当前安全；若将来并行化 `ProbeRunner.tick` 会立刻退化为数据竞争，建议在类注释里写明“非线程安全” |
| §14 功能完备性与 README 覆盖 | 0 | 本部分无 `.md`；`TopologyProbe` 的 `error` 字段、`MemoryProbe` 的 `usedBytes` 口径、`ActionWhitelist` 的白名单动作均已接线（`ProbeFactory.cj:44-72`、`SupervisorRuntime.cj:358-373`），未见“注册未使用/开关只判一处”；README 覆盖核对归同模块其它部分 |
| 文件覆盖（§13 等） | 20/20 | 无缺文件；本部分无文档文件，§13 文档一致性留待模块 README 所在部分 |

### 第 6 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 4 | 正确性 #1/#7；设计 #3（副作用无隔离）；语言特性 #8（可变数组当常量）；安全性 0 —— 报告 HTML 对 `node`/`label`/`valueText`/`message` 均走 `escape`，SVG 内联依赖 `f_xml` 写出时的文本转义（`f_xml/src/XmlWriter.cj:436` → `Escaper.escapeText`），未发现未转义拼接 |
| §1 死代码 | 2 | 逐个 private/internal 符号搜引用：`stripFence`/`join`/`tail`/`joinNumbers`/`joinLines`/`isAuthorized`/`parse`/`truncate`/`load`/`trim`/`persist`/`inlineSvg`/`countAlarms`/`escape`/`configKey`/`defaultType`/`supports`/`wantsHelp`/`isResident`/`runAgent`/`runSupervisor`/`dispatch` 均有调用者；`dispatchWith` 仅 `Main_test` 引用（可见性建议，不算死代码）；命中 2 条为 #6（恒假分支）与 #9（只写不读字段）。`protected` 本部分无；`public` 成员所属顶层声明均为 `public`，按硬原则一不判死代码 |
| §2 重复逻辑 | 3 | 4 处拼接循环、3 处 JSON→DTO 样板、2 份 HTML 转义表（#12/#13/#15）；另比对过 `LlmAdvice`/`LlmSolution`、`ChartAxisSpec`/`ChartSeriesSpec` 的 DTO 样板（`@DataAssist` 生成，非重复逻辑）与两处 `catch (Exception)+catch (Error)` 成对捕获（仓颉 `Exception` 与 `Error` 互不继承，两分支都需要，不算重复） |
| §3 空实现 | 0 | `AdviceParser.cj:43-45` 的空 `catch` 有类注释与用例（`plainTextFallsBackToSummary`）承诺的兜底语义，非静默失效；`ProbeAdvisor` 的 `onAdvice: {_ => ()}` 是具名默认参数（测试专用），生产由 `SupervisorRuntime` 注入；本部分无 `TODO`/`FIXME`/`UnsupportedException` |
| §4 栈溢出 | 0 | 本部分无递归：`stripFence`/`tail`/`join*`/`countAlarms`/`inlineSvg` 均为单层循环；`match` 无自引用结构，`LlmAdvice`↔`LlmSolution` 不互指 |
| §5 OOM | 2 | #2（提示词无规模上限）、#4（报告全量物化 + 字节副本）；`ReplyStateStore` 有 1000 条上限，`ReplyMonitor` 每轮只取一条，无累积 |
| §6.1 热点瓶颈 | 0 | 无 `cjprof`/`bench` 数据，热点未成立；候选写入「待验证假设」#1/#2 |
| §6.2 大粒度锁 | 0 | 本部分无锁（`ProbeAdvisor`/`ReportBuilder`/`ChartSelector` 无可变字段，`ReplyStateStore` 无线程共享） |
| §6.3 并发串行 | 1 | #3：调用方逐事件 `spawn` 且 advisor 侧无合并/限流，实际并行度不受控（不是「串行」，是「无界并行」）；本部分内无 `spawn().get()` |
| §6.4 低效算法 | 3 | `remove(at:0)`+`contains`（优化方案 5）、22×agent 重复 JSON 解析（方案 2）、每节点重建指标目录（方案 3）；均无基线，只列方案 |
| §7 降堆内存方案 | 2 | 优化方案 4（`toArray` 副本）、5（去重集合结构）；#4 已作为缺陷记录规模风险，不重复计数 |
| §8 降 CPU 方案 | 3 | 优化方案 1（StringBuilder）、2（少解析 JSON）、3（少重建目录） |
| §9 local mode 可行性 | 0 | 本部分临时对象（`ArrayList<String> lines/html`、SVG 中间串）最终作为 `String` 返回值逃逸（`ReportDraft`/`prompt`/`svg` 都返回给调用方），`ReportBuilder.build` 的产出还要跨线程发送；逃逸检查不通过，收益无法用峰值内存证明，故不立项 |
| §11 现有代码的 BUG（存量） | 3 | #1（字节切片抛异常）、#7（`from` 空值）、#11（非原子落盘）；另核对了 `ReportBuilder` 的 `stats[0..3]`（长度固定 4）、`values[size-1]`（有 `isEmpty` 前置）、`ChartSpec.jsonObject` 的 `type` 重复判断（有 `isNone` 守卫），均无越界 |
| §12 并发安全与锁粒度 | 1 | #3（有界性）。共享路径已逐一核对：`ProbeAdvisor` 字段全 `let`、`client` 无状态（`FLlmClient` 只持 `model`）；`ChartSelector`/`ChartRenderer`/`ReportBuilder` 无状态，可被报告线程与回复线程并发调用；`ReplyMonitor`/`ReplyStateStore` 仅由 `SupervisorRuntime.llmLoop` 单线程调用（`SupervisorRuntime.cj:237-246`），无第二访问者；`LlmTestSupport_test` 的可变状态只在单线程用例内使用 |
| §14 功能完备性与 README 覆盖 | 1 | #14（`ChartSpec.fromValues` 未进 README）；其余 public 符号逐个对照 `README.md:521-590` 均有条目（`ChartRenderer.render`、`ChartSelector.*`、`LlmTrigger.*`、`ProbeAdvisor.*`、`PromptBuilder.build`、`ReplyMonitor.*`、`ReplyStateStore.*`、`ReportBuilder.build`、`ReportDraft.*`、`AdviceParser.parse`） |
| 文件覆盖（§13 等） | 20/20 | 无缺失；本部分清单不含 `.md`，§13 的文档一致性仅按需取证（`README.md:536`），完整文档核对归并到含 README 的部分 |

### 第 7 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 4 | 严重 #1（逻辑错误）、一般「ReportJob 构建异常」（错误处理）、一般「两套指标口径」（职责重复）、轻微 #测试有效性；安全性方面核对了两处外部输入（拓扑设备名经 `SvgWriter` 转义、`NodeEndpoint.parse` 有范围校验），告警回复的发送者授权由上游 `ReplyMonitor.isAuthorized` 承担（`fprobe/src/llm/ReplyMonitor.cj:97-107`），故 `handleReply` 不校验 `from` 不算越权缺陷 |
| §1 死代码 | 0 | 已逐个核对：`ReportBuilder_test` 的 4 个 private 函数均有调用；`TopologyRenderer` 的 6 个 private 常量与 3 个 `private static` 函数（`sortedDevices`/`sortedLinks`/`linkKey`）全部被调用；`NodeRpcTransport` 的 `buildRequest`/`requireClient`/`dropClient` 与包内 `createNetClient` 均有调用；`SupervisorRuntime` 的 private class（`AdvisorRef`/`AdvisorParts`）与 8 个 private static 函数均有调用；`TransportSource.close` 由 `SupervisorRuntime.close` 调用；`AgentRuntime` 的 `running`/`clock` 均使用。无 `return`/`throw` 之后的同层语句、无恒真恒假分支。仅测试引用的 `buildDispatcher`、`reset` 记为可见性建议（轻微 #可见性建议），不算死代码 |
| §2 重复逻辑 | 2 | 已把本部分 20 个文件的函数体逐个压成「输入→输出→副作用」比对：命中插入排序三处逐行相同（轻微 #插入排序）、cron 空判断两处（轻微 #cron）；另记 `MetricExtractor` vs `ProjectionCatalog`（见「两套 kind→主指标口径」）与 `store.replace` 重复发布（轻微）。报告/图表/渠道相关函数体差异均在业务语义（错误文案、边界、单位），不作为重复 |
| §3 空实现 | 2 | `NullPainter`（`RuntimeSupport.cj:27-39`）是有注释说明的 Null Object，不算问题；命中 `AlarmEngine.emit` 之外的 `dropClient` 静默吞异常（轻微）与 `AgentRuntime` 初始化异常无处理（见「初始化链异常被 Future 吞掉」）。无 TODO/FIXME/`UnsupportedException` 占位 |
| §4 栈溢出 | 0 | 本部分无递归：`decodeAgents`/`build`/`render`/`primary` 均为单层循环，无自引用结构遍历，`TopologyRenderer` 无嵌套递归；深度由设备/链路数量线性决定 |
| §5 OOM | 1 | 事件列表有 50 条上限（`SupervisorRuntime.cj:138-140`）、历史窗格由 `historyPoints` 有界、快照仓库只保留一帧；唯一无界面是 LLM 任务按事件 `spawn`（见「LLM 无上限 spawn」）。未发现按不可信长度预分配或全量物化 |
| §6.1 热点瓶颈 | 0 | 未提供 `cjprof`/`cjpm bench` 数据；`agents` 重复解析与渲染帧成本只能进「待验证假设」#1/#4 与优化方案 |
| §6.2 大粒度锁 | 2 | 命中 `NodeRpcTransport.call` 临界区含建连与 `transfer`（见「NodeRpcTransport 持锁做阻塞传输」）、告警/报告发送在主路径同步（见「告警渠道发送同步」）；`SnapshotStore`/`NodeStateStore`/`NodeHistoryStore` 的临界区仅为一次 map 操作或一次复制，判定合理 |
| §6.3 并发串行 | 0 | `PollLoop` 是「全部 spawn 后统一 get」的批式并发（`PollLoop.cj:107-115`），不是逐个 `get`；`llmLoop` 单线程串行属设计（LLM 分析本就串行） |
| §6.4 低效算法 | 1 | `HistoryRing.append` 的 `remove(at: 0)`（轻微）；`TopologyRenderer` 插入排序列入优化方案；未发现双层循环匹配或循环内字符串 `+` 的实质热点（`formatAdvice` 的 `+=` 在 ≤10 条建议量级） |
| §7 降堆内存方案 | 1 | `ProbeSnapshot` 的 JSON+数组双表示（优化方案，无基线）；其余容器均已定长或有界 |
| §8 降 CPU 方案 | 2 | `agents` 重复解析、拓扑插入排序（均为无基线优化方案） |
| §9 local mode 可行性 | 0 | 本部分热点函数（`build`/`decodeAgents`/`render`）都有返回值逃逸（报告文本、快照、SVG 字符串），`agents` 数组会作为返回值离开函数，逃逸检查不通过；无前后峰值内存数据，不成立 |
| §11 现有代码的 BUG（存量） | 10 | 严重 #1 与一般「告警渠道发送同步」「初始化链异常被吞」「NodeRpcTransport 持锁做阻塞传输」「ReportJob 构建异常」「start 检查-然后-写入」、轻微 #重复发布/#cron/#吞异常/#测试有效性，均为存量；`NodeEndpoint.parse` 的 `@`/`:` 边界、`decodeAgents` 的空串与非法 JSON、`ReportJob` 的 `catch (Exception)` + `catch (Error)` 双分支已逐条核对，未发现越界/空值/除零 |
| §12 并发安全与锁粒度 | 4 | `SupervisorRuntime.start` 检查-然后-写入（见「start 检查-然后-写入」）；字段/局部两份 `NodeStateStore` 同时说明共享路径（严重 #1）；`ProbeRPCImpl.installedStore` 为静态可变但写入发生在 `spawn` 之前（`AgentRuntime.serve:86` 先 `install` 再 spawn），按线程启动次序视为安全，`reset()` 仅测试；`AppHolder.app` 在 `build` 内赋值后才交给渲染线程，未发现发布逸出。锁粒度结论见 §6.2 |
| §14 功能完备性与 README 覆盖 | 2 | README 缺 `NodeRpcTransport.collect/kinds` 与 `AgentRuntime.kinds`（见「README 未覆盖对外入口」）；严重 #1 属「承诺了但输入为空」的功能失效，已按缺陷计。`AgentRuntime.stop()`（`AgentRuntime.cj:115-117`）仓内无调用方、`serve()` 只靠进程被信号终止退出，未计入缺陷：它是给嵌入方/测试的公开 API，是否要接信号钩子做优雅退出属需求问题（待确认）。其余对外入口（`ReportJob`/`TopologyRenderer`/`HistoryRing`/`SnapshotStore`）与 README 逐项对得上 |
| 文件覆盖（§13 等） | 20/20 | 本部分清单 20 个文件全部是 `.cj`，无 `.md`（README/`doc/**` 属其它分部分），故 §13 的文档一致性只做了 §14 所需的符号级交叉核对 |

### 第 8 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 2 | 发现 #1、#2；其余逻辑核对通过：`PollLoop` 阈值计数、失败保留旧快照、`RenderPlanBuilder` 各页分支、`leftPanelWidth` 边界（width 8–15 走 `width/2` 后夹到 8，rightWidth≥0）、`paintMetrics` 的 `remaining<=0` 提前返回均正确；无外部输入拼接 SQL/命令，无凭据 |
| §1 死代码 | 1 | 逐个 `private` / `internal` 符号全仓搜引用：`sortByNode`、`ringKey`、`leftPanelWidth`、`collectOne`、`updateView`、`keyLoop`、`displayRow`、`chartPlan`、`samplePlan` 均有 ≥2 处命中（定义+调用）；`PassiveExitHook` 被 `systemPainter` 引用，其 `register` 为接口实现豁免；其余顶层声明均为 `public` 且对外可达不判。命中 1 条：`collectOne` 的 `at` 形参未使用（#5）；另记信息：`SparkSeries.unit`、`RenderPlan.selectedNode`、`NodeEvent.failures` 仓内无生产读取，`systemPainter` 仓内无调用（对外可达，不作死代码） |
| §2 重复逻辑 | 5 | 同文件两两比对函数体（`paint*`、`topologyRows`、`textOf`/`listOf`、`statusOf`/`findAgent`/`describeMissing`）：命中 `topologyRows` 的 devices/links 两段同构（#10）、`FprobePainter.join` 与 `String.join` 重复（#9）、最小图表高度 8 两处字面量（#8）；另有跨文件近似重复 `systemPainter` vs `SupervisorBootstrap.createPainter`（#3，行为漂移）与 5 处 `catch(Exception)/catch(Error)` 同体样板（#11）。判定为**非**重复：`ChartPanel.supports`（line/bar）vs `ChartSelector.supports`（line/area/bar，TUI 画不了 area）；`PollLoop.run/stop` vs `RenderLoop.run/stop`（唯一共同点是「循环 + 退出标志」，抽层只会增加间接层） |
| §3 空实现 | 1 | 命中 #1（`UiAction.Refresh` 分支空）；`PassiveExitHook.register` 是有注释说明的 Null Object，不算问题；`EmptyHistorySource.values` 返回空数组属契约内的空实现 |
| §4 栈溢出 | 0 | 本部分无自递归/互递归；`topologyRows`、`all()`、`observe` 均为定长双层循环，深度由数据层级（≤3）限制；`RenderPlanBuilder` 无深度遍历 |
| §5 OOM | 1 | 命中 #4（每 tick N 线程，结构无上限）；其余容器均有界：`NodeHistoryStore.rings` ≤ 节点数×22 且每环容量固定，`NodeStateStore.states` 只随节点集合变化，`Buffer` 为 W×H 单帧 |
| §6.1 热点瓶颈 | 0 | 无 profile / bench 数据，四条候选全部写入「待验证假设」与优化方案，未当缺陷 |
| §6.2 大粒度锁 | 0 | `NodeStateStore.all()` 锁内含 O(n²) 排序，但缺「单次持锁时长 + 竞争线程数」数据，降级为优化方案 3 / 假设 #2 |
| §6.3 并发串行 | 0 | `PollLoop` 先全部 `spawn` 再逐个 `get()`，属并行非串行；`evaluator`（含 22 次解析/节点）单线程串行执行，缺耗时占比数据，见假设 #1 |
| §6.4 低效算法 | 0 | `ProjectionCatalog.all()` 的 O(k²) 去重（k=22）、`statusOf` 每行 O(n) 扫描（整帧 O(n²)）、`HistoryRing.append` 的 `remove(at:0)`（范围外文件）均已记录，但无规模/耗时数据，按铁律只进优化方案与假设 |
| §7 降堆内存方案 | 1 | 优化方案「每帧 Buffer/单元格/行数组」；已说明 `clear()` 不还物理内存、缓存键需失效规则 |
| §8 降 CPU 方案 | 3 | 优化方案 1–3（重复解析、目录重建、双快照+锁内排序），均无基线 |
| §9 local mode 可行性 | 0 | 本部分临时对象集中在 `RenderPlanBuilder` 与 `ChartPanel`，但对象会经 `RenderPlan` 返回、`Buffer`/单元格矩阵逃逸到 `f_chart` 与 `ratatui_buffer`（依赖包无 local mode 重载，需逐个核对），且收益只能用峰值内存证明，当前无数据 ⇒ 不成立 |
| §11 现有代码的 BUG（存量） | 4 | #2（退出恢复窗口）、#6（`flush()` 返回值丢弃）、#7（状态栏 epoch ms）、#5（未使用形参）；另核对 `ChartPanel` 的 NaN 判定（`value == value` 只要求存在一个有效点，全 NaN 返回 None）、`leftPanelWidth` 越界、`ScriptedSource` 脚本越界（`script[size-1]` 在空脚本上越界，仅测试注入，未报） |
| §12 并发安全与锁粒度 | 1 | `NodeStateStore`/`NodeHistoryStore` 均有 Mutex 且临界区只含容器操作；`PollLoop` 的 `running`/`ticks` 用原子量；`tick()` 对外是 `public` 且未声明线程安全（生产仅 `run()` 单线程调用，未判）。命中 #4（线程无界） |
| §14 功能完备性与 README 覆盖 | 2 | #1（`r` 键承诺未实现）、#3（`systemPainter` 未接线）；README「其他公开 API」清单已逐项核对，本部分 public 类型/函数（`ChartPanel`、`EmptyHistorySource`、`ExitHooks`、`FprobePainter`、`FrameRenderer`、`HistorySource`、`KeyMap`、`KeySource`、`MetricSpec`、`NodeEvent(Type)`、`NodeHistoryStore`、`NodeSource`、`NodeState(Store)`、`NodeStatus`、`Painter`、`PollLoop`、`ProjectionCatalog`、`RenderLoop`、`RenderPlan(Builder)`、`SparkSeries`、`SupervisorApp`、`SupervisorComponents`、`SystemExitHooks`、`TerminalFrameRenderer`、`UiAction`、`UiKey`、`systemPainter`）均已登记，无遗漏 |
| 文件覆盖（§13 等） | 20/20 | 本部分清单无 `.md`，§13 无适用对象 |

### 第 9 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 2 | Sparkline 归一化（#1）；usage 与实现不符（#2）。无外部输入拼 SQL、无凭据、无注入面 |
| §1 死代码 | 0 | 逐个核查本部分符号：`STDOUT_FILENO`/`CHROME_HEIGHT`/`BLOCKS`/`clampSelection`/`normalizePage`/`alarmPageIndex`/`Panel.put` 均有引用；测试替身的 `public` 成员全为接口实现（豁免）；本部分没有 `internal`/`protected` 顶层声明。对外可达 public 不判：`TuiLayout.MIN_CHART_HEIGHT`、`ViewModel.pageNumber/pageCount` 仓内仅自用/仅测试用，列入「可见性建议」 |
| §2 重复逻辑 | 4 | TTY 校验与 fd 常量（#3）、图表最小高度（#4）、`kind()` 与 `"topology"` 字面量（#5）、四组导航方法（#6）。另已排查：测试替身重复（`FalseTtyDetector`/`FakeTtyDetector`）属测试准备代码，按误报边界不报；`MetricPage/UiKey/UiAction` 三处手写 `==` 是仓内既定做法（`Equatable` 成员需显式实现，见 `.autocode/tmp/probe_equatable/p1.cj`），不计为重复逻辑 |
| §3 空实现 | 0 | 本部分无空函数体、无 TODO/占位、无 `catch {}`；`Panel`/`Table`/`Sparkline` 的早返回都是显式的尺寸保护，返回值语义与调用方一致 |
| §4 栈溢出 | 0 | 本部分无递归（`ViewModel`/`TuiLayout`/widgets 全为单层循环），无自引用结构 |
| §5 OOM | 0 | 无按不可信长度预分配；`ViewModel.nodes` 来自配置且长度有界；`PAGES`/`BLOCKS` 为固定常量 |
| §6.1 热点瓶颈 | 0 | 无 `cjprof`/bench 数据，逐格写与插值只作为「待验证假设」与「优化方案（无基线）」 |
| §6.2 大粒度锁 | 0 | 本部分不含锁；`SupervisorApp` 的锁在另一部分 |
| §6.3 并发串行 | 0 | 无 `spawn`/`get`；渲染与按键线程职责分离在 `SupervisorApp`/`RenderLoop` |
| §6.4 低效算法 | 0 | `Sparkline` 的 O(n) 归一化 n ≤ 60，`alarmPageIndex` 扫 8 项；均无测量数据，不判低效 |
| §7 降堆内存方案 | 0 | 单帧对象仅为行/列规模的临时 String 与 `Rect`，随帧结束释放；无可量化收敛目标 |
| §8 降 CPU 方案 | 1 | 面板/表格/sparkline 批量写（无基线，见优化方案） |
| §9 local mode 可行性 | 0 | 函数内临时对象都很小且会进入 `Buffer`（跨对象存储），不满足「函数内用完」，改造成本高于收益 |
| §11 现有代码的 BUG（存量） | 2 | Sparkline 归一化边界（#1）、`Table` 极窄宽度写入（#8，待确认） |
| §12 并发安全与锁粒度 | 0 | `ViewModel` 字段全为 `let`，每次迁移构造新实例，经 `SupervisorApp.viewLock` 发布；`TuiLayout`/widgets 无状态，`Buffer` 由渲染线程独占；`PAGES` 无写入者（可变数组暴露面列入「可见性建议」） |
| §14 功能完备性与 README 覆盖 | 2 | help 漏 `probe_hostId`（#2）、README API 索引漏 3 个 public 成员（#7）；本部分 public 声明与文档已逐项对照，`requireTty`/`systemKeySource`/`Panel`/`Table`/`Sparkline`/`TuiLayout` 均已接线 |
| 文件覆盖（§13 等） | 13/13 | 无缺失；本部分无 `.md` 文件，文档一致性以 README / `doc/tui.md` / `doc/configuration.md` 为参照取证 |

### 可见性建议

- `ViewModel.pageNumber()` / `pageCount()`（`ViewModel.cj:130-136`）：仅 `ViewModel_test.cj:30-31` 使用，状态栏/标题（`RenderPlan.cj:235`）没有展示页码；若近期不接页码，建议收窄为包内可见或删除，并同步移除 `README.md:613` 的条目。
- `TuiLayout.MIN_CHART_HEIGHT`（`TuiLayout.cj:26`）：仓内只有 `chartHeight` 自用；与 #4 合并处理，收敛为单一常量后不必对外。
- `ViewModel.PAGES`（`ViewModel.cj:86`）：`public static let` 只固定了绑定，`Array` 元素仍可被外部改写；一旦被改，`normalizePage`/`page()` 的下标假设失效。建议改为包内可见 + 只读访问器（或每次返回副本）。当前仓内无写入者。

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 4 |
| 一般 | 45 |
| 轻微 | 57 |
| 其中存量 | 93 |
| 优化方案 | 见「优化可行性方案」各条 |

## 总评

**第 1 部分**：本部分是文档面，结构与覆盖面很好：README 中英两版标题数（30/30）、表格行数（86/86）一致，配置/告警/RPC/部署四份 `doc/` 都有实现对应，两组 OpenSpec 产物与代码大体对得上，相对链接无死链；`doc/spec/add-fprobe/design.md` 属历史设计，被后续变更取代的部分按误报边界不计缺陷。

主要风险集中在「文档承诺的配置与行为没有实现」这一类，且都是**静默失效**，用户不会收到任何错误：

- 四个配置键（`probe_channel_email_receiveLimit` / `probe_reportChannels` / `probe_reportTmpDir` / `probe_llmMaxTokens`）改了没反应；
- `probe_chart_*` 的示例键与默认类型表双双对不上真实 metric id，磁盘柱状图与「图表类型可覆盖」实际都不成立；
- `probe_alarmCooldownSeconds` 恒不生效，告警文档描述的冷却窗口靠的是 `firing` 标志；
- fail-fast 只覆盖两个 Settings，规则/CRON/渠道/LLM 键或退出 1、或静默回退，与 README 的「全部配置一次校验、退出 2」相反；
- hardware/topology 的内部 `error` 不会触发「探针报错」告警，与 README 的覆盖面描述不符；
- SMTP 密码被描述为 SM4 保护，实际是命令行/环境变量明文。

以上 9 条一般问题建议进修复清单：前三条改文档或接线即可，#4/#5/#6 需要动源码（配置校验前移、冷却语义、错误层级），#7 需要安全口径与实现对齐，#8 是示例修正，#9 是扩展能力口径修正。5 条轻微（级别进标题、`weight` 不一致、附录字面量丢失、`ChartPanel` 签名漂移、部署文档多写配置来源）可随手修。

存量 14 条（9 一般 + 5 轻微），是否纳入修复待用户决定；本部分未做任何源码修改，也未跑构建。

**第 2 部分**：本部分的 5 个生产源文件（告警引擎、事件、规则、缺失追踪、渠道分发）结构清楚、职责单一，`AlarmRule` 的"配置阶段一次校验、运行期只按 `DataPath` 取值"这个方向是对的，`MissingDataTracker`、`RuleState` 的意图也都能从注释读出来。**主要风险集中在"告警可信度"而不是性能**：

1. **必须先修的阻塞项是发现 #1**——`mute` 与 `evaluate` 分属两条常驻线程，却共享一个未同步的 `HashMap`。这是唯一一条严重项，属于"默认按多线程审"下无法自证安全的情形；修法很小（一把锁或原子快照），但需要并发压测用例兜底。
2. **第二梯队是三条"告警会骗人"的缺陷**：#2（kind 缺失每 tick 伪造恢复+重复告警）、#3（冷却参数从未生效）、#4（`path` 写错则规则永久静默失效）。三者都直接损害监控系统最核心的价值，且都缺用例——现有 `AlarmEngine_test` 只覆盖了 happy path 与 `probe_expectKinds` 分支。
3. **可排期的是 #5 与 #6-#11**：静默吞异常、错误消息契约、同名渠道静默覆盖、四处缺失键模板与两对同语义实现、离线时的假恢复、未使用的 import 与两个零引用 public 成员。它们不影响主流程，但会让下一次改动继续踩同一类坑。
4. **性能结论一律没有资格下判断**：`valueOf` 的重复解析是明显的结构性浪费，但本轮没有基线，只能留在「优化方案（无基线）」与「待验证假设」里，不进修复清单。

范围外提示（不计入本部分统计，供合并时转给相应分部分）：(a) `SupervisorRuntime.cj:498-503` 对已注册的扩展渠道只做 `AlarmChannelRegistry.channel(...).isSome()` 判断并打印"已注册但未配置，已跳过"，从不实例化工厂——`probe_alarmChannels` 里的扩展渠道永远收不到告警，与 spec「多渠道分发」不符；(b) `SupervisorRuntime.cj:142` 在拉取线程内同步做 `dispatch`（含 SMTP），一次网络超时就会推迟整个 tick；(c) `tui/RenderPlan.cj:235` 把 `SystemClock().nowMs()` 原样拼成"刷新 1764…ms"，状态栏展示的是 epoch 毫秒而非时间。

存量合计 11 条（严重 1 / 一般 4 / 轻微 6），是否纳入修复待用户决定。

**第 3 部分**：本部分的生产代码（邮件渠道 + 采集装配 + 健康探针 + 指标投影）整体结构清楚：渠道与传输用接口隔开、探针装配集中在 `ProbeFactory`、快照编码只有一个入口，失败都收敛成 `error` 字段而不是抛给调用方，注释也基本能对上实现。问题集中在两处：

1. **阻塞项是发现 #1**——同一个 `Email` 被拉取线程、回复线程、异步分析线程、报告线程同时使用，而 `f_email` 明确是"有会话状态、无锁"的对象。这是默认装配下就会命中的数据竞争，后果是告警邮件串包/错发，必须先加串行化再谈其它。
2. **第二梯队是发现 #2 + #3**——`receive()` 取窗口内第一封未读且永不推进，POP3 下 flags 恒空、IMAP 下 `BODY.PEEK` 永不打 `\Seen`，于是第一封回复之后渠道就"卡住"了，而消费方按 id 去重让这个卡住完全静默。修法不大（返回游标或标记已读），但要先把 `list` 的顺序契约写清，否则改了还是错方向。

其余是防御性与一致性问题：#4 的"任意 JSON 对象都当全 0 健康数据"会把对端异常包装成"健康但为零"，#5 的无上限读响应体是 OOM 面；#6-#13 是重复实现、双层发布、仅测试引用的工具类与未释放会话资源，可排期。性能方面本轮没有任何基线，`evaluate` 的重复解析、串行 tick、逐封取正文都只能留在优化方案与待验证假设里，不进修复清单。

跨部分提示（供合并去重，不计入本部分统计）：(a) part1 #1 的 `probe_channel_email_receiveLimit` 未接线，源码侧落点是 `EmailAlarmChannel.cj:35-41`，合并时与 part1 归一条；(b) part2 #9 已报 `AlarmEvent.format` ↔ `renderHtml` 的字段表重复与 `title.startsWith("【已恢复】")` 判恢复，本部分 #10 只补 `subjectOf` ↔ `renderHtml` 这一处，三处应合成一条；(c) `SupervisorRuntime.cj:142` 在拉取线程内同步做 `dispatch`（含 SMTP）会把一次网络超时带进 tick——与发现 #1 同源但属性能面，已并入待验证假设表第 2 行。

存量合计 13 条（严重 2 / 一般 3 / 轻微 8），是否纳入修复待用户决定。

**第 4 部分**：本部分代码整体结构清晰：探针「一个 kind 一个类」、失败按项降级（`available=false` + `error`）、外部命令参数数组直传并做空白/元字符过滤、每个 `.cj` 均带版权头，`FProcessRunner` 的超时与退出码语义也和测试对齐。没有发现严重级缺陷，也没有锁、共享可变集合或递归热路径。

主要风险集中在「外部输入形状假设过强」与「有状态采集的边界」两类：

1. **阻塞项（建议本轮就定级）**：F2 —— `df -Pi` 出现 `IUse%="-"`（vfat/exFAT 等无 inode 统计的挂载）时 `disk` 整项永久进 error。机制是静态确定的，但触发面需要在真实主机上确认；若确认常见，应升级为严重。F1（缺 `smart_status` → FAILED）同样会直接制造假告警，属于告警可信度问题。
2. **可排期**：F3（设备重插后 IOPS 放大）、F4/F5（域名目标恒不可达 + 失败即泄漏 fd）、F6（串行超时叠加拖长整轮采集）、F7（远端 SNMP 输出无上限）。这些都不会让进程崩溃，但会在长跑中累积成「数据不可信」或「句柄/内存缓慢上涨」。
3. **清理项**：F10 死代码、F11/F12 重复逻辑（6 组跨包副本 + 2 组同文件副本）成本低、风险低，建议与上述修复同批处理，避免下次修 `-`/`..` 校验时再漏一处。

所有性能类结论（设备级并发、复用 `Client`、单趟解析、输出上限）都缺改前基线，只写入「优化可行性方案 / 待验证假设」，未当作缺陷；`disk` 首帧 200ms 差分窗口导致的速率噪声也未定性，留待假设 #4 补数据。

**第 5 部分**：本部分代码的整体质量偏上：解析函数短小、错误统一收敛为 `ProbeException(COLLECT/LOAD)`、每个探针都有对应 `_test.cj` 且覆盖了差分首帧、缺表、畸形行等关键路径；采样口径（`usedBytes=MemTotal-MemAvailable`、`drop/error` 以包数比、`nonNegativeDelta` 处理计数器回绕）注释与实现一致。

主要风险集中在 **topology 子系统**，且都是“可用性/静默失效”类而非崩溃类：

1. 阻塞项（建议排期优先）：topology 每轮串行 2N 次 walk、超时可叠加，直接拖慢唯一采集线程（发现 1）；`-On` 缺失导致装有 MIB 的环境下拓扑静默为空（发现 2）。这两条决定 topology 监控项在生产是否可信。
2. 次优先：网卡白名单全不命中静默返回空（发现 3）、`probe_snmpDevices` 重名不报错（发现 4）、远端设备端口只留首个（发现 5）——都是“没数据也不报错”，排查成本高。
3. 编译面：`AgentSettings` 的 Windows 分支缺 `std.env` import（发现 6，待 Windows 目标确认），Linux 侧不受影响。
4. 维护面：SNMP walk 解析两份实现已出现引号/前导点漂移（发现 7），加上 `hasWhitespace/hasShellMeta`、字符白名单、时间换算、默认端口的多处复制，是本模块后续最容易产生行为分歧的地方。

本部分**无严重问题**；发现均为存量，默认只报不修，是否纳入修复请用户决定。性能与内存部分无任何基线数据，优化方案全部标为“无基线”，不得进 `tasks.md`。

**第 6 部分**：本部分代码结构清晰、职责切分干净：`LlmClient` 端口化让用例可以完全脱离 `f_llm`，`ProbeAdvisor` 把「开关 / 触发 / 故障隔离」收敛在一处，`ChartSelector`/`ChartSpec`/`ChartRenderer` 三段式让报告用真实 SVG 而不必自己拼图，`ReplyStateStore` 的「损坏按空集合启动」也确实是可用的容错。没有发现崩溃级缺陷、数据损坏或死锁。

主要风险集中在**规模**而不是逻辑：`PromptBuilder` 与 `ReportBuilder` 都以「节点 × 22 指标」全量展开且无任何上限（#2/#4），`ProbeAdvisor` 又在每个告警事件上无界 `spawn`（#3）——三者叠加意味着「节点多 + 告警多」时内存、token 与上游配额会同时被放大，而失败表现是「建议变少 / 报告变慢」而不是明确报错，运维很难归因。建议把这四条（含 #1）排进最近的迭代：其中 #1 修法明确、成本极低，可立即做；#2/#4 需要定「上限值」，属于产品口径，建议由用户拍板后落地；#3 建议先加单飞标记，改动最小。

其余 11 条轻微项是健壮性与可维护性改进（截断边界、`from` 校验、原子落盘、四处拼接与两处转义的合并、README 补一条 API），可以排在功能迭代之后。所有性能类结论本轮都没有改前/改后数据，已按铁律只写入「优化可行性方案 / 待验证假设」，未进缺陷清单。

**第 7 部分**：本部分的代码分层清晰、职责单一：`report` 只做 HTML/SVG 组装，`rpc` 把「定向连接」与「RPC 契约」拆成两层，`runtime` 只做接线，`snapshot` 用「单写者整体替换」把并发模型压到一把只保护引用的锁上，`HistoryRing` 的语义（旧→新、不伪造 0 值）也写得很明确。测试对可观测行为（转义、XML 声明剥离、单图失败退化、确定性布局、失败重连）覆盖得比较扎实。

阻塞项只有一个，但影响直接：`SupervisorRuntime.cj` 构造期创建了两个 `NodeStateStore`，`llmLoop` 拿到的是那个永远为空的实例，导致 `probe_llmTrigger=interval` 的周期分析在无节点数据的情况下照样调用模型并对外发建议——属于「看起来在工作、实际输入是空」的静默失效，建议排在最前修，并补一条断言 `states` 非空的用例。

其次是三处结构性风险，可排期但不是阻塞：告警邮件与报告发送同步跑在采集/定时线程上（SMTP 抖动会直接拉长 tick）、LLM 调用无并发闸门（告警风暴下线程会累积）、`NodeRpcTransport` 把阻塞 `transfer` 放进临界区（退出时最长多等一个 `nodeTimeoutMs`）。三者都不是实测热点，属于「先改结构、再谈收益」的类型。

其余问题以维护性为主：`MetricExtractor` 与 `ProjectionCatalog` 两套指标口径并存且已漂移（生产只用后者）、`ReportJob` 的构建异常没走自己的日志契约、`HistoryRing` 的 `remove(at: 0)` 与三处插入排序属于实现落后于数据结构的典型，收益需测量后再决定。两处优化方案（`agents` 重复 JSON 解析、拓扑排序）都缺基线数据，本轮只作为下一轮补数据的清单，不进修复任务。

**第 8 部分**：本部分（supervisor 状态层 + tui 视图层）质量偏高：状态与视图彻底分离，`NodeState` 整体替换、失败保留旧快照、历史环定长、渲染计划是纯数据，测试覆盖到并发写入、阈值事件、图表回退与宽字符续格这些容易漏的点，没有发现数据竞争、无界增长型 OOM 或栈溢出。主要风险集中在**装配与生命周期**而不是算法：`r` 键的链路在最后一跳断掉（#1）、`shutdown()` 的 `runningState` 门槛会在 `start()` 中途失败时把终端留在 raw mode（#2）、以及 `systemPainter` 与 `SupervisorBootstrap.createPainter` 两套装配行为不一致、使「信号退出走同一套钩子」的文档承诺存疑（#3）。这三条都建议排期修复，且都只需改十行以内。`PollLoop` 的每 tick N 线程（#4）在节点数上量时才需要处理，可先加并发上限再谈优化。优化方案与待验证假设全部缺基线，本轮不作为缺陷、不进 tasks。

存量 11 条（4 一般 + 7 轻微），是否纳入修复待用户决定。

**第 9 部分**：本部分是一层小而清晰的 TUI 支撑代码：`ViewModel` 做成纯函数式迁移、TTY/按键/布局都用接口隔离、widgets 只碰 `Buffer` 不承担业务语义，测试对按键映射、分页回绕、布局预算、TTY 报错都有分支级断言；没有递归、无界容器、共享可变状态的写入，也没有锁与 I/O 混在热路径里，整体质量良好。

真正值得排期的是两条：`Sparkline` 的归一化窗口（会让运维把「有尖峰刚滚出窗口」误读成「指标接近 0」，属于会误导判断的显示逻辑错误）与 `usage` 文本失真（把不存在的配置文件写进帮助，同时漏掉多节点必需的 `probe_hostId`）。其余为重复常量/重复映射、极窄窗格边界与 README 索引遗漏，可按维护窗口顺手处理；`r` 键无动作与 `systemPainter` 未接线已在「范围外提示」标注，交对应部分确认。

存量 8 条（2 一般 + 6 轻微），是否纳入修复待用户决定。
