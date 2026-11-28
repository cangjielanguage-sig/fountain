# fprobe 模块审查报告（模块第 1/9 部分）

- **审查日期**：2026-11-28
- **模块路径**：`fprobe`（本部分 14 个文件，全部为 `.md`：README ×2、`doc/*.md` ×4、`doc/spec/**` ×8；模块总计 142 个 `.cj` + 25 个 `.md`，其余文件由第 2–9 部分覆盖）
- **基线**：工作区快照（`120fd2542`，无 diff 可比），本部分所有问题来源统一记为「存量」
- **审查重点**：本部分是文档面，但按任务重点核对「文档承诺的采集正确性、缓冲区/句柄生命周期、并发语义、死配置与重复契约」，所有「文档 vs 实现」判断均以 `fprobe/src` 现场取证
- **报告版本**：v1.1（同路径重写：14:15 的同部分草稿为上一轮执行产物；本轮全量重读 14 个文件后重写，补充「探针 error 层级」与「敏感配置」两条发现，并修正草稿中「tui-charts 设计与实现一致」的结论）
- **审查方式**：`files/fprobe.part1.txt` 14 行逐个读完；配置键用脚本抽取后逐个反查生产源码读取点；文档相对链接逐个做存在性检查；README 与 README_en 的标题数 / 表格行数做结构比对

## 发现

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

## 优化可行性方案

本部分 14 个文件全部是文档，没有可测量的代码路径，因此不产出堆内存 / CPU 优化方案（0 条）。文档层面唯一可执行的改进是「契约单一来源」，已作为 #2 / #3 的根因在「描述」中说明，不重复计入优化统计。

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | README 关于 `llm_metaStore` 覆盖 `llm_confSource` 的结论（`f_llm` 1.3 行为）是否与本仓 `f_llm` 版本一致 | `fprobe/README.md:391-401` | `f_llm` 侧 `LLMConfs.holder()` 的实际分支与版本 | 读 `f_llm` 对应源文件；再配 `--llm_confSource=env` 起一次 `probe_llmTrigger=interval`，看日志是否 `source: store` |
| 2 | `cjpm install` 是否真的产出 `/usr/local/bin/fprobe`（README 说产物是 `target/release/bin/main`） | `fprobe/doc/deployment.md:11` | 实际安装产物名 | 在 WSL 里 `cjpm install --path <tmp>` 后列目录 |
| 3 | TUI 每帧 `W×H` 字符串矩阵（设计标注「可忽略」）是否在低配终端上构成可测开销 | `doc/spec/add-fprobe-tui-charts/design.md:207` | 帧耗时占比 | 80×24 终端下 `cjprof` 采样 10 分钟，看 `ChartPanel.render` / `drawCells` 自耗时 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `fprobe/README.md` | .md | ✅ | 主文档；见 #1 #2 #4 #5 #6 #9 #10 #12 |
| 2 | `fprobe/README_en.md` | .md | ✅ | 30 个标题、86 行表格与中文版一致；同样带 #4 #5 #6 #9 #10 #12 |
| 3 | `fprobe/doc/alarm-rules.md` | .md | ✅ | 见 #2 #3 #5 #10 |
| 4 | `fprobe/doc/configuration.md` | .md | ✅ | 见 #1 #2 #4 #5 #7 |
| 5 | `fprobe/doc/deployment.md` | .md | ✅ | systemd / 权限 / 扩展目录与实现一致；见 #14 |
| 6 | `fprobe/doc/rpc.md` | .md | ✅ | 契约与 `ProbeRPCImpl` / `NodeRpcTransport` 一致；见 #8 #11 |
| 7 | `fprobe/doc/spec/add-fprobe-tui-charts/design.md` | .md | ✅ | 主体已落地；`ChartPanel` 签名漂移见 #13 |
| 8 | `fprobe/doc/spec/add-fprobe-tui-charts/proposal.md` | .md | ✅ | 与 design/tasks 自洽；`:56` 明确 `probe_chart_*` 不作用于 TUI，反证 #2 |
| 9 | `fprobe/doc/spec/add-fprobe-tui-charts/specs/chart-tui/spec.md` | .md | ✅ | 与 `TuiCellChart.drawCells` 现状一致 |
| 10 | `fprobe/doc/spec/add-fprobe-tui-charts/specs/probe-supervisor/spec.md` | .md | ✅ | 与 `MetricPage.chartType`、`MIN_CHART_HEIGHT=8`、`ChartPanel.MIN_WIDTH=20` 一致 |
| 11 | `fprobe/doc/spec/add-fprobe-tui-charts/tasks.md` | .md | ✅ | 全部 `[x]`；抽查 1.3/2.1/3.3/4.1 的产物文件均存在 |
| 12 | `fprobe/doc/spec/add-fprobe/design.md` | .md | ✅ | 历史设计（D7 的 `system` 聚合 hardware、D12 的 SVG 附件落盘已被后续变更取代）；按 §13 误报边界只核自洽性，未计缺陷 |
| 13 | `fprobe/doc/spec/add-fprobe/proposal.md` | .md | ✅ | 与 design 的四处修正同口径（`ProbeKinds` DTO、`sendRich`、RPC 放 fprobe、自研 `f_tui`），自洽 |
| 14 | `fprobe/doc/spec/add-fprobe/specs/probe-advisor/spec.md` | .md | ✅ | 已核对：历史点数 20、状态文件 1000 条上限（`ReplyStateStore.cj:34`）、未授权固定文案（`ReplyMonitor.cj:30`）、白名单四动作均与实现一致 |

合计：`.cj` 0 个 / `.md` 14 个 / 共 14 个，全部读完（与 `files/fprobe.part1.txt` 逐行对应）。

## 覆盖自检

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

## 模块统计

（仅统计本部分，即第 1/9 部分）

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 9 |
| 轻微 | 5 |
| 优化方案（堆内存 / CPU） | 0 / 0 |

## 总评

本部分是文档面，结构与覆盖面很好：README 中英两版标题数（30/30）、表格行数（86/86）一致，配置/告警/RPC/部署四份 `doc/` 都有实现对应，两组 OpenSpec 产物与代码大体对得上，相对链接无死链；`doc/spec/add-fprobe/design.md` 属历史设计，被后续变更取代的部分按误报边界不计缺陷。

主要风险集中在「文档承诺的配置与行为没有实现」这一类，且都是**静默失效**，用户不会收到任何错误：

- 四个配置键（`probe_channel_email_receiveLimit` / `probe_reportChannels` / `probe_reportTmpDir` / `probe_llmMaxTokens`）改了没反应；
- `probe_chart_*` 的示例键与默认类型表双双对不上真实 metric id，磁盘柱状图与「图表类型可覆盖」实际都不成立；
- `probe_alarmCooldownSeconds` 恒不生效，告警文档描述的冷却窗口靠的是 `firing` 标志；
- fail-fast 只覆盖两个 Settings，规则/CRON/渠道/LLM 键或退出 1、或静默回退，与 README 的「全部配置一次校验、退出 2」相反；
- hardware/topology 的内部 `error` 不会触发「探针报错」告警，与 README 的覆盖面描述不符；
- SMTP 密码被描述为 SM4 保护，实际是命令行/环境变量明文。

以上 9 条一般问题建议进修复清单：前三条改文档或接线即可，#4/#5/#6 需要动源码（配置校验前移、冷却语义、错误层级），#7 需要安全口径与实现对齐，#8 是示例修正，#9 是扩展能力口径修正。5 条轻微（级别进标题、`weight` 不一致、附录字面量丢失、`ChartPanel` 签名漂移、部署文档多写配置来源）可随手修。

存量 14 条（9 一般 + 5 轻微），是否纳入修复待用户决定；本部分未做任何源码修改，也未跑构建。
