# R4: 复审 fmq 服务端 / CLI / 指标 / 配置

审查时间：2026-10-21
对象：HEAD `22c13ec4`（全树复审，非 diff）
角色：只读审查，未修改任何文件

### 审查范围

代码（`fmq/src/**`，R4 边界）：

- `fmq/src/main.cj`、`fmq/src/MQUsage.cj`、`fmq/src/Main_test.cj`
- `fmq/src/config/MQConfig.cj`、`MQConfig_test.cj`
- `fmq/src/server/MQServer.cj`、`MQServerOptions.cj`、`MQCommandExecutor.cj`、`ConsumeService.cj`、
  `SubscriberRegistry.cj`、`MQSubscriptionInfo.cj`、`BackupStore.cj` 及对应 `*_test.cj`
  （`MQManager_test.cj` 挂在 server 包下，也纳入本轮）
- `fmq/src/manager/MQManager.cj`、`MQManagerArgs.cj`、`MQManagerOutput.cj` 及对应 `*_test.cj`
- `fmq/src/metrics/MQMetrics.cj`（无独立 test 文件，由 `ConsumeService_test` / `GroupCursor_test` 覆盖）

文档：

- `fmq/README.md`、`fmq/README_en.md`
- `fmq/doc/详细设计.md`（§2–§7、§9 对应章节）、`fmq/doc/开发计划.md`（manager/server 相关条目）
- `openspec/specs/fmq/server-runtime/spec.md`、`manager-cli/spec.md`、`metrics/spec.md`
- 变更规格：`openspec/changes/archive/2026-10-21-fix-fmq-full-audit/specs/fmq/{server-runtime,manager-cli,metrics}/spec.md`
  与 `.../specs/docs/spec.md`
- 覆盖证据：`scripts/mq_e2e.sh`（SIGTERM、stats、删除主题等断言）

> 说明：任务书给出的 `fmq/doc/spec/fix-fmq-full-audit/specs/fmq/**` 在本 worktree 中不存在；
> 该变更已归档到 `openspec/changes/archive/2026-10-21-fix-fmq-full-audit/`，本轮按其内容核查。

### 一、结论摘要

服务端生命周期、命令分发、断链清理、指标口径、配置校验的主干实现与规格吻合，错误码与幂等语义处理得比较扎实（close 逐步隔离+重试、generation 防重订阅误删、stats 单趟扫描、配置严格解析不回落均有实现且有用例）。本轮问题集中在两类：

1. **A65（管理端错误分类）相关用例只断言退出码**，无法区分「正确分类」与「误报无法连接」——这正是该修复要防的回归，属于「勾选但无用例」；
2. **文档漂移**较集中：`详细设计.md` 的 §3/§5.1/§5.18/§5.19/§5.22/§6.1/§6.7/§7/§9 与实现签名、顺序、机制描述不一致；子命令数量「六/七」在文档与源码注释中并存。

### 二、发现

#### [严重] 管理端「服务端错误 / 载荷类型不符」两个场景的用例只断言退出码，A65 回归不可见

- **位置**：`fmq/src/server/MQManager_test.cj:104-121`（`serverErrorIsNotReportedAsConnectionFailure`）、
  `fmq/src/server/MQManager_test.cj:124-142`（`nonSnapshotResponseIsProtocolError`）
- **现象**：两个用例唯一断言是 `manager.run() == 1`。但「服务端回 `ERROR(INTERNAL)`」「回 RESP 但非快照」
  「真的连不上」三条路径的退出码都是 1（`MQManager.cj:227-280`）。用例既不检查 stdout，
  也不能区分实际渲染的是 `boom from server` / `响应不是 MQMetaSnapshot` 还是 `无法连接消息队列服务`。
- **影响**：`openspec/specs/fmq/manager-cli/spec.md:109-117` 的两条 Scenario 都写着
  「MUST NOT 输出『无法连接』」，而用例在「把 `printError` 改回 `connectionFailed`」时仍然全绿——
  A65 的修复没有任何回归保护；同时违反 `server-runtime/spec.md:388-391`
  「用例 SHALL NOT 仅断言退出码而不检查输出」。
- **建议**：给 `MQManager` 注入输出 sink（例如 `private let out: (String) -> Unit = {s => println(s)}`）
  或让 `withClient` 返回 `(code, text)`，用例直接断言文本含 `INTERNAL`/`META_SNAPSHOT` 且不含
  `无法连接消息队列服务`；同类 `MQManager_test.cj:216-222`、`249-252`、`MQServer_test.cj:314-318`
  一并改为断言文案。

#### [一般] 管理端把「响应格式异常」兜底成「无法连接」

- **位置**：`fmq/src/manager/MQManager.cj:214`（`catch (_: Exception) { connectionFailed() }`）、
  `fmq/src/manager/MQManagerOutput.cj:80`（`Int64.parse(fields[4])`）
- **现象**：`stats` 的 TSV 解析在渲染层完成；若服务端给出非数字的 `delaying`（版本漂移、串包），
  `Int64.parse` 抛 `IllegalArgumentException`，被 `withClient` 的兜底 catch 归为连接失败，
  打印「无法连接消息队列服务」。同理，任何 `body()` 内的非 `MQServiceFailure` 异常都会被误分类。
- **影响**：与 manager-cli 规格「服务端可达但返回 ERROR 时 MUST NOT 使用该文案」的意图相反，
  运维会误判为网络问题；且该路径无用例。
- **建议**：`MQManagerOutput.stats` 用 `Int64.tryParse` 并在失败时返回可诊断文本（或抛 `MQServiceFailure`），
  让 `withClient` 的 `MQServiceFailure` 分支（`MQManager.cj:211-213`）接管；兜底 catch 只用于真正的传输异常。

#### [一般] 启动顺序与规格「先定时器、后监听」相反，且端口在装配期即绑定

- **位置**：`fmq/src/server/MQServer.cj:114-115`（构造 `Server<DataAny>(bindAt: ...)`）、
  `MQServer.cj:170-180`（`spawn { server.start }` 在 `backup.start()` / `cleaner.start()` /
  `syncer.startAntiEntropy()` / 巡检 Timer 之前）
- **现象**：`f_net` 的 `Server.init` 内部 `newServerSocket(bindAt)`（`f_net/src/server/Server.cj:117`）
  在 `MQServer` 构造期就完成 bind/listen；`start()` 先起 accept 协程，再起备份/清理/反熵/巡检。
- **影响**：`server-runtime/spec.md:189-192` 要求「打开本机队列 → 启动清理/备份定时器 → 启动监听」的
  SHALL 顺序被违反；存在一个「已可接受请求、但备份/清理/反熵未运行」的窗口（单节点基本无害，
  但备份窗口内发布的消息不会被复制）；若构造后段（如 `LogCleaner`）抛错，端口已被占用到进程退出。
- **建议**：把 `Server` 的构造与 `start()` 一起推迟到所有定时器就绪之后（例如 `start()` 内再 new），
  或至少在 `start()` 中先起 `backup/cleaner/antiEntropy/cleanupTimer` 再 `spawn { server.start }`；
  同时把 `详细设计.md:678-681` 的顺序描述与实现对齐。

#### [一般] `BackupStore` 关闭后写入完全静默，与规格「记 DEBUG/WARN（限流）」冲突

- **位置**：`fmq/src/server/BackupStore.cj:53-55`（`append` 早退）、`BackupStore.cj:106-108`（`saveCursor` 早退）
- **现象**：`closed.load()` 为真时直接 `return`，无任何日志；`append` 内的 `LogClosedException` 也只是
  静默丢弃（`BackupStore.cj:79-81`）。
- **影响**：`server-runtime/spec.md:349-354` 的 Requirement 明确要求「关闭后到达的写入 SHALL 被安全丢弃
  并记 DEBUG/WARN（限流）」，实现不满足；而 `README.md:129-130` 写的是「静默丢弃」，规格与 README 互相矛盾，
  验收时无法判断以哪个为准。丢副本这件事在关闭期可能涉及数据可恢复性，静默会让排障失去线索。
- **建议**：实现限流 WARN（可复用 `BackupReplicator.warnRateLimited` 的做法），或在规格中明确改为静默，
  并同步 README；两者择一，不要保留矛盾描述。

#### [一般] `MQMetrics.bump` 的「addIfAbsent + get」非原子，与删除并发时抛异常

- **位置**：`fmq/src/metrics/MQMetrics.cj:35-39`
- **现象**：
  ```
  counters.addIfAbsent(key, AtomicInt64(0))
  counters.get(key).getOrThrow().fetchAdd(1)
  ```
  两步之间若 `removeTopic` / `removeGroup`（`MQMetrics.cj:49-74`）删掉该键，`get` 返回 `None`，
  `getOrThrow` 抛异常。调用点是 `GroupCursor.next` 的投递路径（`fmq/src/queue/GroupCursor.cj:182-193`），
  此时 `entry.owner/delivered` 已更新。
- **影响**：删除主题/组与在途消费并发时，消费者会随机收到一次 `ERROR(INTERNAL)`；记录停留在「已分配给旧订阅」
  状态，要等 `ackTimeout` 后才会重投。`metrics/spec.md:99-118` 要求「清理 SHALL 与读取并发安全，
  不得因遍历删除抛异常」，且「并发读取」Scenario 没有用例（见覆盖矩阵）。
- **建议**：改为「取不到就重建」的原子循环，或使用 `ConcurrentHashMap` 的 get-or-create 语义；
  另补一个「清理与 stats/投递并发」的用例（可用多线程 + `@Expect` 不抛）。

#### [一般] 断链清理：实现是「代次 + 释放」，文档写的是 `removeByBuffer` 与「与 LogCleaner 同一批定时器」

- **位置**：`fmq/doc/详细设计.md:819-820`、`fmq/src/server/MQServer.cj:177-180`、`MQServer.cj:285-301`、
  `fmq/src/server/SubscriberRegistry.cj:137`
- **现象**：文档称「在 `MQServer` 的巡检（与 `LogCleaner` 同一批定时器）里对 `buffer.isClosed()` 的订阅做清理
  （`removeByBuffer`）」。实际是独立的 2s `Timer.repeat`（`CLEANUP_INTERVAL`）调用 `cleanupSubscribers()`，
  按「订阅 id + generation」摘除并 `consume.releaseSubscription`；`removeByBuffer` 在生产路径上没有调用方
  （仅 `MQServer_test.cj:497` 使用）。
- **影响**：文档会误导后续维护者把 `removeByBuffer` 当成生产入口（它没有释放已分配记录，也没有代次保护，
  直接接回生产会退化为 A55/A60 的缺陷）；巡检周期（2s vs LogCleaner 5min）也与文档不符。
- **建议**：更新 `详细设计.md` §6.7 为真实机制并删除对 `removeByBuffer` 的生产性描述；`removeByBuffer`
  要么删除（仅测试用的旧路径），要么明确标注为测试辅助。

#### [一般] 关闭顺序：README / 详细设计 的「完整列表」缺订阅表与 `queues.sync`

- **位置**：`fmq/README.md:44-46`、`fmq/README_en.md:48-51`、`fmq/doc/详细设计.md:682-684`；
  实现 `fmq/src/server/MQServer.cj:197-213`
- **现象**：实现 `closeSteps` 为 server → cleanupTimer → antiEntropy → backup → cleaner → consume →
  **subscribers.clear()** → backupStore → **queues.sync()** → queues → deadLetter → meta → registry。
  文档列表在 consume 之后直接跳到 backup store，漏掉订阅表，也没有体现 `queues.sync` 是独立步骤。
- **影响**：`fix-fmq-full-audit` 的 docs 规格要求「含退出钩子注册点与『相反顺序释放』的**完整**列表」
  （`.../specs/docs/spec.md:35-38`），当前列表不完整；排查关闭问题时容易漏看订阅释放。
- **建议**：三处同步补上 `subscribers` 与 `queues.sync`，并注明 `consume.close()` 内含游标落盘。

#### [一般] 详细设计 §5 的签名与实现不符（main / onPublish / SubscriberRegistry / MQManagerOutput）

- **位置**：`fmq/doc/详细设计.md:159-168`（main）、`:564`（onPublish）、`:581-590`（SubscriberRegistry）、
  `:657-660`（MQManagerOutput）
- **现象**：
  - `main` 只写 `server → MQServer(MQConfig).run()`；实际是 `MQServer()` + `installExitHooks` + 注入式
    `dispatch/dispatchWith`（`main.cj:37-118`），文档也未列出 `dispatch`/`dispatchWith`/`installExitHooks`。
  - `onPublish(buffer: SocketBuffer, request: Message): ?Message`；实际 `onPublish(request): Message`
    （`MQCommandExecutor.cj:237`）。
  - `register(subscription, buffer)`、`byGroup(topic, group)`；实际 `register(info)`、`byGroupOf`，
    且未列 `activeIds`/`infos`/`count`/`generations`（`SubscriberRegistry.cj:41,99,186,208`）。
  - `MQManagerOutput` 只列 `table`/`error`；实际另有 `registeredTopic`/`topicList`/`stats`/`assignments`/
    `width` 与 4 个公开常量（`MQManagerOutput.cj:25-110`）。
- **影响**：docs 规格要求「签名可对照」；按文档写调用会编译失败，测试/评审对照失真。
- **建议**：按当前源码重写这四段签名清单（可只列公开/受保护成员并注明测试钩子）。

#### [一般] 详细设计 §3 描述的配置读取方式与实现不符

- **位置**：`fmq/doc/详细设计.md:69-73`
- **现象**：文档写「`Config.getValue<UInt16>(...) ?? 2350u16`」「`port` 用 `MQHost.parseHost` 解析」。
  实现全部走 `Config.getString` + `strictPort()`（`UInt16.tryParse`）/`strictInt64`/`strictDuration`
  （`MQConfig.cj:147-178`），只有 `nodes` 项的校验才用 `MQHost.parseHost`（`MQConfig.cj:315-339`）。
- **影响**：文档描述的正是 A63 修复前的旧实现（`?? default` 会静默回落），与「非法值不回落」的规格
  直接矛盾；按文档评审会误判实现没有落地 A63。
- **建议**：§3 的「读取方式」改为严格解析三件套，并说明 `port` 用 `UInt16.tryParse`、
  `host:port` 才用 `MQHost.parseHost`；同时删掉包依赖表里的 `f_util`/`f_data`（`详细设计.md:24`，
  实现明确不用 `f_util.computeBytes`，见 `MQConfig.cj:180-185`）。

#### [一般] 子命令数量「六 / 七」在文档与源码注释中并存

- **位置**：`fmq/doc/详细设计.md:946`（「manager 六个子命令」）、`fmq/src/manager/MQManager.cj:29`、
  `fmq/src/server/MQManager_test.cj:34`、`fmq/doc/开发计划.md:127,443,500,520`、
  `openspec/specs/fmq/server-runtime/spec.md:129`；对照 `fmq/doc/详细设计.md:149,647`、
  `MQUsage.cj:48`、`openspec/specs/fmq/manager-cli/spec.md:39`（均为七）
- **现象**：`stats` 加入后总数是 7，但上述位置仍写「六」。`server-runtime` 的「管理端帮助」Scenario 还要求
  「输出含六个子命令」，与 `manager-cli` 的「7 个子命令」自相矛盾。
- **影响**：docs 规格 `.../specs/docs/spec.md:51-54` 明确要求「README 与管理端 `--help` 均为 7 个子命令，
  名称一致」；现有表述会让验收脚本与人工核对结论打架。
- **建议**：统一改为「七个子命令（含 `stats`）」，并修正 `server-runtime/spec.md:126-129` 的 Scenario 文本。

#### [一般] 详细设计 §7 的 `registerTopic` 参数与输出格式与实现不符

- **位置**：`fmq/doc/详细设计.md:880`；实现 `fmq/src/manager/MQManager.cj:56-72`、`MQManagerOutput.cj:43-47`
- **现象**：文档参数写 `[delayingMs]`，输出写「队列 0..N-1，延迟：<dur>，分配：0→A 1→B …」；
  实际第三个操作数是 `delaying=<DurationString>`（`delaying=1m1s`），输出为
  「队列 0..3（共 4 个），延迟：0s，分配：0→0,1→1」（逗号分隔 + 「共 N 个」）。
- **影响**：与 `MQUsage.managerHelp`、README 示例、`MQManagerOutput_test` 均不一致；用户按设计文档写
  `registerTopic /t 2 1m1s` 会得到「第三个参数必须是 delaying=<时长>」并返回 2。
- **建议**：§7 表格按 CLI 实际语法与输出模板重写。

#### [一般] 「默认值」「帮助文本完整」两个 Scenario 属弱覆盖

- **位置**：`fmq/src/config/MQConfig_test.cj:31-55`、`:246-251`；规格 `server-runtime/spec.md:31-44`
- **现象**：名为「默认值」的段落先用 `Config.set` 把 11 个键全部**显式写成**默认值，再断言解析结果，
  `Config.getString` 的 `None` 分支（真正的「未设置 → 取默认值」）完全没有执行；`helpText` 只断言了
  10 个键名，`mqServer_tombstoneTTL`、`mqServer_antiEntropyInterval` 未断言，也没有断言任何默认值文本
  （如 `2350`、`10s`、`1G`）。
- **影响**：若把某个 `DEFAULT_*` 常量改错、或把 `?? fallback` 分支删掉，用例仍全绿；Scenario
  「帮助文本完整 … 含全部配置项名与默认值」实际未验证。
- **建议**：用可清空配置的入口（或 `Config.set` 后提供 `reset`/子进程）覆盖「未设置」路径；
  `helpText` 改为遍历「键名 + 默认值字符串」成对断言，并补上缺失的两项。

#### [一般] 「配置缺失」路径无用例

- **位置**：`fmq/src/manager/MQManager.cj:42-45`；规格 `manager-cli/spec.md:104-107`
- **现象**：`args.server.isEmpty()` 分支（打印「无法连接消息队列服务」返回 1）没有任何用例覆盖；
  `MQManagerArgs.parse` 在 `mqServer_port` 缺失时返回 `Some` 且 `server == ""`（`MQManagerArgs.cj:83-87`），
  这条组合路径未被测试。
- **影响**：该分支若被误改为抛异常/返回 0，或用例无法发现；与「端口不可达」混淆后覆盖矩阵看起来是满的。
- **建议**：新增一个 `MQManagerArgs` 手工构造（包内可见 `init`）或临时清空 `mqServer_port` 的用例，
  断言退出码 1 且文案为「无法连接」。

#### [一般] 「发布触发备份」场景无用例

- **位置**：规格 `server-runtime/spec.md:398-401`；相关实现 `MQCommandExecutor.cj:280`、测试
  `MQCommandExecutor_test.cj:402-415`
- **现象**：现有用例只测「收到 `PUBLISH(backup)` 后副本落盘、不进本队列」（接收侧）；
  「`backup = 1` 时发布一条 → 备份复制器收到一次入队（用替身断言）」没有对应用例——fixture 里
  `BackupReplicator(registry, 0)`，且没有可注入的 replicator 替身（`ExecutorFixture` 私有字段）。
- **影响**：`onPublish` 里 `backup.record(...)` 若被删/被条件包住，发布仍返回成功，用例全绿，
  副本静默丢失。
- **建议**：为 `BackupReplicator` 抽一个记录型接口（或在 `MQCommandExecutor` 注入 `record` 回调），
  断言发布一次即入队一次且携带 `(topic, queueIndex, position)`。

#### [一般] 退出钩子：「manager 不安装」无用例，`toExitGracefully()` 调用点无覆盖

- **位置**：`fmq/src/main.cj:115-116`；规格 `server-runtime/spec.md:316-331`
- **现象**：`installExitHooks` 做了注入测试（`MQServer_test.cj:386-401`），但
  (a) `runServer()` 里 `ExitCallbacks.toExitGracefully()` 这半步没有被任何用例观察；
  (b) 「执行 `fmq manager listTopics` 不注册 MQ 退出钩子」没有用例（`runManager` 为 private，
  也没有钩子计数入口）。
- **影响**：若把 `installExitHooks`/`toExitGracefully` 移到 `dispatch` 之前（对所有子命令生效），
  现有用例仍全绿；manager 短命令可能被异常的信号处理行为影响。
- **建议**：把「安装钩子」抽成与 `dispatchWith` 同级的可注入函数（返回是否安装/已注册回调数），
  在 `Main_test` 中对 `server` 与 `manager` 两条路径分别断言。

#### [一般] 管理端「非绝对路径主题」无用例

- **位置**：规格 `manager-cli/spec.md:129-132`；对照 `MQCommandExecutor_test.cj:202-211`（executor 层有）
- **现象**：`MQManager.registerTopic("order", ...)` 会走网络由服务端拒绝并打印 `INVALID_TOPIC` 文案，
  但 manager 包/CLI 层没有对应用例；`MQManager` 也没有像组名那样的本地前置校验
  （`MQManager.cj:117-122` 只校验 group）。
- **影响**：该 Scenario 只能靠 executor 用例间接等价，且「退出码非 0 + 打印主题非法」的渲染路径未验证。
- **建议**：补一条 `MQManagerTest` 用例（或与组名一致地加本地 `MQTopic.isValid` 前置校验并测「不发请求」）。

#### [一般] `stats` 三个 CLI 场景只断言退出码

- **位置**：`fmq/src/server/MQManager_test.cj:224-235`、`:248-252`；规格 `manager-cli/spec.md:184-197`
- **现象**：「查询全部主题 → 输出包含两个主题」「按主题 → 只输出该主题」「未知主题 → 输出（空）」
  在 CLI 层都只断言 `run() == 0`；输出断言只存在于渲染层的 `MQManagerOutput_test.cj:107-137`
  和 `ConsumeService_test` 的 TSV 层，没有贯通「请求 → 渲染」。
- **影响**：服务端返回空串、manager 渲染成空行、或 `stats("")` 误传给服务端 `/` 等组合缺陷不可见。
- **建议**：与 S1 同一改造（输出 sink），断言实际表格行数与主题名。

#### [一般] 「非法组名不发请求」的断言无法区分行为

- **位置**：`fmq/src/server/MQManager_test.cj:144-157`
- **现象**：注释写「指向不存在的地址也应当先被本地校验挡下（否则会打印『无法连接』）」，
  但断言只有 `offline.run() == 1`——本地拒绝、连接失败、服务端拒绝三者都是 1。
  `deleteSubscribeGroup /t "g/1"` 同样只断言 1。
- **影响**：若删掉 `MQManager.cj:119-122` / `130-133` 的本地校验，用例仍然通过（只是文案从
  `INVALID_GROUP` 变成「无法连接」），A05 的「不发请求」承诺失去保护。
- **建议**：断言输出文案为「主题/组名非法」且**不是**「无法连接」，或用可计数的 client 工厂断言未建连。

#### [一般] 「关闭释放」未断言队列已 `sync`

- **位置**：`fmq/src/server/MQServer_test.cj:518-539`；规格 `server-runtime/spec.md:403-406`
- **现象**：用例断言了订阅表清空与端口可再绑定，但没有断言 `queues.sync()` 执行（无注入点/观测点）；
  `closeSteps` 里 `queues.sync` 与 `queues.close` 是两个独立步骤，前者失败会被记为失败步骤但不会体现在
  任何用例里。
- **影响**：`queues.sync` 被误删时，用例仍全绿，重启可能丢最后一段未 fsync 的数据（配置为
  `syncInterval=1` 时风险较小，但语义上仍属「关闭完整释放」）。
- **建议**：让 `QueueManager` 暴露 `syncCount`（或注入 `sync` 回调），在关闭用例中断言 ≥1。

#### [一般] 测试共享进程级 `Config`，缺少隔离手段，存在并行串扰

- **位置**：`fmq/src/config/MQConfig_test.cj:25-30`、`fmq/src/Main_test.cj:110-122`、
  `fmq/src/manager/MQManagerArgs_test.cj:36-41`
- **现象**：`MQConfig` 全部静态读取进程级 `Config`；`MQConfig_test` 在注释里承认「用例必须串行读写」，
  但没有任何强制串行/恢复机制，且它结束时把配置留在
  `PORT=2350, hosts=h1:2350,h2:2351,h3:2352, BACKUP=2, THRESHOLD=1`；
  `Main_test`/`MQManagerArgs_test` 也各自 `Config.set`。
- **影响**：一旦测试框架并行调度同进程用例（或新增用例按包并行），会出现「端口不在节点表」「阈值非法」
  之类的随机失败；`Main_test.serverStartupValidationFailureReturnsTwo` 只恢复 `mqServer_backup`，
  也会把残留配置带给后续用例。
- **建议**：提供 `Config` 的快照/恢复 helper（`beforeEach` 记录、`afterEach` 还原），或把配置相关用例
  收拢到一个串行 test suite；至少在所有写配置的用例结束时完整还原。

#### [一般] 命令处理矩阵存在成组的分支缺口

- **位置**：`fmq/src/server/MQCommandExecutor.cj:315-317`（tags 非法）、`:326-329`（订阅时本机无队列
  `NOT_OWNER`）、`:131-135`（`REGISTER` 意外载荷）、`:150-152`（未知 internal kind）、
  `:260`（`PUBLISH` 收到非 backup 的内部信封）、`:168-180`（未知 metaSync 子载荷）
- **现象**：上述 6 条错误分支都没有用例；`server-runtime/spec.md:136-152` 的命令矩阵虽未逐条列举这些
  错误码，但「未知命令或无法解析的载荷 SHALL 回 ERROR(INTERNAL)」的兜底语义只覆盖了
  `PUBLISH` 垃圾载荷与 `PING`。
- **影响**：这些分支属于「安全兜底」——误改成 `throw`、返回 `None`（不回包导致客户端挂起）或落到错误的
  删除分支，都不会被发现；其中 `SUBSCRIBE` 的 `NOT_OWNER` 与「客户端连到非 owner 节点」的运维场景直接相关。
- **建议**：按矩阵逐行补用例（构造 `MQSubscribePayload` + 非 owner 装配、`REGISTER` 装
  `MQSubscribePayload`、internal kind 设为未知枚举、`PUBLISH` 装 `MQTopicAssignment` 等）。

#### [一般] `mqServer_port = 0` 的校验分支无用例

- **位置**：`fmq/src/config/MQConfig.cj:288-290`；规格 `server-runtime/spec.md:51-63`
- **现象**：`validate()` 对 `port == 0` 有专门报错，但 `MQConfig_test` 的「零值」用例集
  （`MQConfig_test.cj:166-193`）只覆盖 ack/maxSize/logTTL/deadTTL/tombstone/antiEntropy，没有 `PORT=0`。
- **影响**：`UInt16.tryParse("0")` 合法，若删掉该判断，服务端会尝试绑定 0（随机端口）并「成功启动」，
  与节点表定位语义冲突，且用例不会报错。
- **建议**：在零值用例集中加入 `(MQConfig.PORT, "0")` 并断言报错文案。

#### [建议] `main.cj` 存在不可达的 `--help` 分支

- **位置**：`fmq/src/main.cj:70-73`
- **现象**：`command` 取自「第一个不以 `-` 开头的参数」（`main.cj:54-59`），因此
  `command == "--help" || command == "-h"` 恒为假；显式帮助实际由 `commandIndex < 0` + `wantsHelp`
  分支处理。
- **影响**：死分支会让读者误以为支持 `fmq x --help` 之外的形式，也增加后续改动误判。
- **建议**：删除该分支（或改为在 `commandIndex < 0` 分支内先判 help，语义更直白）。

#### [建议] `MQSubscriptionInfo.isConnected` 与 `connectionKey`/`hasBuffer`/`removeByBuffer` 链路仅测试可达

- **位置**：`fmq/src/server/MQSubscriptionInfo.cj:65-70`（`isConnected` 无调用方）、
  `MQSubscriptionInfo.cj:34-36,83-85`、`fmq/src/server/SubscriberRegistry.cj:137-152`
- **现象**：`isConnected` 全仓无引用；`hasBuffer` 只被 `removeByBuffer` 调用，而 `removeByBuffer`
  只被 `MQServer_test.cj:497` 调用；`connectionKey` 只服务于这条链。
- **影响**：~30 行「生产看起来存在、实际不参与运行」的代码，会误导断链清理的实现判断（见上文文档漂移）。
- **建议**：删除 `isConnected`；`removeByBuffer` 若不再接回生产则连同 `hasBuffer`/`connectionKey` 一并移除，
  测试改用 `cleanupSubscribers` 路径。

#### [建议] `MQCommandExecutor.execute(request)` 仅测试使用，注释称「内部调用」不实

- **位置**：`fmq/src/server/MQCommandExecutor.cj:71-74`
- **现象**：注释「仅供单测与内部调用」，但全仓只有测试（`ExecutorFixture.call`）调用；生产只走
  `execute(buffer, request)`。
- **影响**：小；但「内部调用」的措辞会让人以为存在生产内部路径，弱化对 `EMPTY_SOCKET_BUFFER` 哨兵值的警惕。
- **建议**：注释改为「仅测试使用（订阅不绑定连接）」，或把测试入口改为包内测试辅助函数。

#### [建议] 未使用 import

- **位置**：`fmq/src/manager/MQManager.cj:20`（`import fountain::f_data.*`，仅 `DataAny` 被用且已在 21 行
  单独导入）；`fmq/src/server/MQManager_test.cj:27`（`SocketBuffer` 未使用）；
  `fmq/src/server/ConsumeService_test.cj:27`（`MQResult` 未使用）
- **现象**：三处 import 无对应符号引用。
- **影响**：编译告警噪音；`f_data.*` 的星号导入还会让「本包依赖 f_data」的架构结论看起来成立
  （实际只依赖 `DataAny`）。
- **建议**：删除；并在 CI 打开未使用 import 告警。

#### [建议] `MQUsage.managerHelp` 与 `MQManagerArgs.helpText` 是两份完全相同的文本

- **位置**：`fmq/src/MQUsage.cj:48-68`、`fmq/src/manager/MQManagerArgs.cj:91-110`
- **现象**：两处逐字重复（仅注释不同 `七个子命令` / 无）。
- **影响**：本次已出现「六/七」注释漂移；文本双份维护，后续加子命令极易只改一处，导致
  `fmq manager --help` 与解析失败时的帮助不一致。
- **建议**：`MQUsage.managerHelp()` 直接返回 `MQManagerArgs.helpText()`（或将文本收敛到一个常量），
  并让 `Main_test` 断言两者相等。

#### [建议] `MQCommandExecutor_test.cj:188-191` 的空断言

- **位置**：`fmq/src/server/MQCommandExecutor_test.cj:188-191`
- **现象**：`case RESP(_) => @Assert(true)`；虽然紧随其后有真实断言（载荷可解码、owners、queueNum），
  但该 match 本身不提供任何信息。
- **影响**：形式上属「仅 `@Assert(true)`」的残留片段，容易被后续复制成真正的空测试。
- **建议**：改为 `@Assert(response.command is RESP)`（或直接删掉 match，仅保留载荷断言）。

#### [建议] `parseByteSize` 乘法溢出未处理

- **位置**：`fmq/src/config/MQConfig.cj:231`（`n * (1024 ** UInt64(shift))`）
- **现象**：`9999999999999999E` 之类输入会让 `Int64` 回绕为负，随后 `validate()` 报
  「must be positive, got -…」，提示的是截断后的值。
- **影响**：错误信息误导（用户看到的是负数而不是「过大」）；极端情况下若回绕为正数会接受一个错误配置。
- **建议**：用 `Int64` 溢出检查（或先比较 `n > Int64.Max / factor`）并报「too large」。

#### [建议] `MQServer.start()` 中 `cleanupTimer` 赋值与 `close()` 存在窗口

- **位置**：`fmq/src/server/MQServer.cj:164-181`、`:220-244`、`:265-272`
- **现象**：`started` CAS 成功后到 `cleanupTimer = Some(...)` 之间，若另一线程调用 `close()`，
  `cancelCleanupTimer()` 看到 `None`，随后 `start()` 写入 Timer，定时器在 `closed` 之后继续运行
  （每 2s 调 `cleanupSubscribers` / `sweepTombstones`）。
- **影响**：低（进程通常随即退出），但在「测试内 close 后再断言日志/状态」或嵌入式复用时会出现
  关闭后仍打日志/扫已关闭 MetaStore 的情况。
- **建议**：在 `start()` 赋值后检查 `closed`，若已关闭则立即 cancel；或把 `cleanupTimer` 的创建
  纳入 `started` 的同一临界区。

#### [建议] 测试目录清理不一致

- **位置**：`fmq/src/server/MQServer_test.cj:323-341,344-369,372-383,386-401,406-451,454-474,477-516,519-539`
- **现象**：多数 `finally` 只 `server.close()`，没有 `remove(root, recursive: true)`；
  同一文件的 `bindAccept.../onlyLocal.../restart...` 会清理。
- **影响**：反复本地跑测试会在 `TestDirs` 下累积段文件/备份目录，也可能让「目录已存在」类断言在
  调试时表现不一致。
- **建议**：统一 `finally { server.close(); if (exists(root)) remove(root, recursive: true) }`。

#### [建议] `SubscriberRegistry.generations` 永不清理

- **位置**：`fmq/src/server/SubscriberRegistry.cj:34,50-55,85-87`
- **现象**：`generations` 只增不删（注释说明了理由：避免代次回退），但订阅注销后条目永久保留。
- **影响**：长时间运行、`subscribedId` 生成策略包含随机/uuid 时，该 map 会随历史订阅数线性增长
  （内存占用小但无界）。
- **建议**：为已注销 id 的代次记录加 TTL/LRU（例如保留最近 N 个或按时间清理），或改用「单调计数 + 定期压缩」。

#### [建议] `MQManager.registerTopic` 的回显用入参而非服务端返回

- **位置**：`fmq/src/manager/MQManager.cj:104`、`MQManagerOutput.cj:43-47`
- **现象**：输出中的 `queueNum`/`delayingMs` 来自 CLI 入参，`assignment` 只用了 `owners`。
- **影响**：若服务端对未来请求做归一化（如延迟取整、队列数上限），管理端会显示与元数据不一致的值。
- **建议**：以 `assignment.queueNum` / `assignment.delayingMs` 渲染，或在二者不一致时提示。

#### [建议] 关闭失败对调用方不可见

- **位置**：`fmq/src/server/MQServer.cj:220-244`、`:184-190`
- **现象**：`close()` 返回 `Unit`，`run()` 恒返回 0；关闭步骤失败只体现在 ERROR 日志。
- **影响**：`SIGTERM` 的退出码永远是 0（符合规格 `server-runtime/spec.md:320`），运维无法从退出码
  发现「未完整关闭」。
- **建议**：保留规格要求的 0 退出码，但把 `close()` 结果（失败步骤名）暴露为 `isCloseCompleted()`，
  供测试与运维探针使用。

### 三、文档/规格 ↔ 实现一致性逐项回答

| 项目 | 结论 | 证据 |
|---|---|---|
| 启动顺序 | **不一致**（一般）：端口在装配期绑定、accept 先于备份/清理/反熵/巡检；规格要求「队列 → 定时器 → 监听」 | `MQServer.cj:114-115,170-180` vs `server-runtime/spec.md:189-192`、`详细设计.md:678-681` |
| 关闭顺序 | **基本一致，文档不完整**（一般）：实现顺序与「相反顺序」相符，且含订阅表清理与 `queues.sync`；README/设计缺这两项 | `MQServer.cj:197-213` vs `README.md:44-46`、`README_en.md:48-51`、`详细设计.md:682-684` |
| 退出钩子 | **一致**：只在 `server` 分支装，`toExitGracefully` + `atExit(0, close)`，`close()` 幂等可重试；e2e 断言 SIGTERM 退出码 0 | `main.cj:102-118`、`MQServer.cj:220-244`、`scripts/mq_e2e.sh:256-273`；覆盖缺口见 G14 |
| 命令分发 | **一致**：`server`/`manager`/`--help`/未知/无参/配置前置；有一处不可达分支 | `main.cj:37-90`（死分支 `:70-73`）、`Main_test.cj:28-108` |
| 断链清理 | **行为一致、文档不符**（一般）：实现为 2s 巡检 + 代次 + 释放记录，文档写 `removeByBuffer` 且称与 LogCleaner 同定时器 | `MQServer.cj:177-180,285-301`、`SubscriberRegistry.cj:77-91` vs `详细设计.md:819-820` |
| 管理端 7 子命令与输出 | **实现一致**：7 个子命令齐全，输出统一由 `MQManagerOutput` 生成（表格对齐、错误前缀、空结果占位）；文档数量表述与 §7 参数/格式有漂移 | `MQManager.cj:41-194`、`MQManagerOutput.cj`、`MQUsage.cj:48-68` vs `详细设计.md:880,946`、`MQManager.cj:29` |
| 指标口径 | **一致**：`backlog` 从 `committed`（下一条待消费位置）起算、含未确认；`lagMs` 取最早积压记录发布时间且负值钳 0；autoAck 计入 `acked`；删除主题/组清计数器；`stats` 单趟扫描、失败回 INTERNAL | `ConsumeService.cj:149-261`、`GroupCursor.cj:182-193,563`、`MQMetrics.cj`；并发缺陷见 G4 |
| 配置校验 | **一致**：11 项 `mqServer_*` + `mqClient_hosts` 严格解析、范围/唯一性/`selfIndex` 校验齐全，帮助文本齐全；「默认值」场景弱覆盖、`port=0` 无用例 | `MQConfig.cj:275-345,348-363` vs `server-runtime/spec.md:8-63` |

补充：`fmq/src/**` 非测试源码确实没有 `fountain::f_mq.client` 引用（已 grep 确认），
`NodeRegistry` 使用 `f_mq.base.MQHost`，满足 `server-runtime/spec.md:280-294` 的架构要求，但没有自动化守卫。

### 四、Requirement → 用例矩阵

图例：✅ 直接覆盖；◐ 间接/等价覆盖；⚠ 弱断言（无法区分目标行为）；✗ 缺口。

#### server-runtime（15 Requirement / 55 Scenario）

| Requirement | Scenario | 用例 | 判定 |
|---|---|---|---|
| 配置项与默认值 | 默认值 | `MQConfig_test.cj:30`（显式写入默认值） | ⚠ |
| | 环境变量覆盖 | `MQConfig_test.cj:30`（`Config.set` 等价路径） | ◐ |
| | 帮助文本完整 | `MQConfig_test.cj:246`（10/12 键）、`Main_test.cj:94`（仅退出码） | ⚠ |
| | 非法值不回落 | `MQConfig_test.cj:85-103`、`Main_test.cj:111` | ✅ |
| 启动期校验 | 负数备份 | `MQConfig_test.cj:106` | ✅ |
| | 备份超过节点数 | `MQConfig_test.cj:215` | ✅ |
| | 缺少节点表 | `MQConfig_test.cj:115` | ✅ |
| | 自身端口缺失 | `MQConfig_test.cj:125` | ✅ |
| | 非本机端口重复 | `MQConfig_test.cj:145` | ✅ |
| | 阈值为 0 | `MQConfig_test.cj:155` | ✅ |
| | 零超时 | `MQConfig_test.cj:166` | ✅ |
| | 端口 0 的节点项 | `MQConfig_test.cj:196` | ✅ |
| | （Requirement 条款）`mqServer_port=0` | — | ✗ |
| 备份副本并发安全 | 并发备份同一队列 | `BackupStore_test.cj:35` | ✅ |
| 子命令分发 | 顶层帮助 | `Main_test.cj:28` | ✅ |
| | 管理端帮助 | `Main_test.cj:94`、`MQManagerArgs_test.cj:70` | ⚠（规格写「六个」） |
| | 未知子命令 | `Main_test.cj:88` | ✅ |
| 命令处理矩阵 | 注册返回分配 | `MQCommandExecutor_test.cj:184` | ✅ |
| | 非法主题 | `:202` | ✅ |
| | 发布原样落盘 | `:238`、`:254` | ✅ |
| | 未注册组 | `:377` | ✅ |
| | 空消费不是错误 | `:330` | ✅ |
| | 内部同步与备份分派 | `:389`、`:403`、`:434` | ✅ |
| | 垃圾载荷 | `:418`、`:535` | ✅ |
| | （矩阵外错误分支：tags/NOT_OWNER/意外载荷/未知 kind） | — | ✗（G20） |
| 启动装配与关闭 | 只打开本机队列 | `MQServer_test.cj:144` | ✅ |
| | 关闭后可重新绑定 | `MQServer_test.cj:94` | ✅ |
| | 无法连接任何 peer 仍可启动 | `MQServer_test.cj:144`（peer `127.0.0.1:1` 不可达） | ◐ |
| | 重启恢复消费 | `MQServer_test.cj:198` | ✅ |
| | 收到 SIGTERM 完整关闭 | `scripts/mq_e2e.sh:256-273` | ◐（进程级） |
| | 关闭中途失败 | `MQServer_test.cj:323` | ✅ |
| | run 可返回 | `MQServer_test.cj:372` | ✅ |
| 断链清理 | 连接关闭后订阅消失 | `MQServer_test.cj:407` | ✅ |
| | 重订阅不被误删 | `MQServer_test.cj:455` | ✅ |
| | 可注入触发 | `MQServer_test.cj:436` | ✅ |
| 端到端可用性 | 100 条不重不漏 | `scripts/mq_e2e.sh` | ◐ |
| | 单节点停机 | `scripts/mq_e2e.sh` | ◐ |
| | 重投与死信 | `GroupCursor_test.cj` + e2e | ◐ |
| | 自动确认组 | `ConsumeService_test.cj:243`、`:408` | ✅ |
| host 解析归属 | 服务端不依赖客户端包 | — （人工 grep 通过） | ✗（弱，可加 lint） |
| | 解析语义不变 | `f_mq` `MQHost` 用例（R1） | ◐ |
| 备份存储关闭并发安全 | 关闭与写入并发 | `BackupStore_test.cj:124` | ✅ |
| | 关闭前写入可读回 | `BackupStore_test.cj:93` | ✅ |
| | 关闭后写入 | `BackupStore_test.cj:124`、`:160` | ✅ |
| 退出钩子 | server 安装钩子 | `MQServer_test.cj:386`（未覆盖 `toExitGracefully`） | ⚠ |
| | manager 不安装 | — | ✗ |
| 关闭异常隔离 | 单步失败仍完成其余 | `MQServer_test.cj:323` | ✅ |
| | 重试收敛 | `MQServer_test.cj:344` | ✅ |
| 备份存储生命周期 | 枚举备份队列 | `BackupStore_test.cj:260` | ✅ |
| | 备份段被清理 | `BackupStore_test.cj:178` | ✅ |
| | 关闭后写入 | 同上 | ✅ |
| 可注入的启动装配 | 分发到服务端 | `Main_test.cj:35` | ✅ |
| | 分发到管理端 | `Main_test.cj:35` | ✅ |
| 服务端测试资产 | 内部变更落地 | `MQCommandExecutor_test.cj:434` | ✅ |
| | 发布触发备份 | — | ✗（G13） |
| | 关闭释放 | `MQServer_test.cj:520`（未断言 `sync`） | ⚠ |

#### manager-cli（9 Requirement / 37 Scenario）

| Requirement | Scenario | 用例 | 判定 |
|---|---|---|---|
| 参数解析 | 前置与后置 | `MQManagerArgs_test.cj:25` | ✅ |
| | 默认服务端 | `MQManagerArgs_test.cj:37` | ✅ |
| | 参数校验 | `MQManagerArgs_test.cj:44`、`Main_test.cj:101` | ✅ |
| | 配置参数前置 | `MQManager_test.cj:256`、`Main_test.cj:35` | ✅ |
| | 帮助 | `MQManagerArgs_test.cj:70`（7 个命令名） | ◐ |
| 六个管理子命令 | 注册主题并显示分配 | `MQManager_test.cj:160` + `MQManagerOutput_test.cj:60` | ✅ |
| | 注册后被列出 | `MQManager_test.cj:160`、`MQServer_test.cj:252` | ◐（退出码） |
| | 删除主题生效 | `MQManager_test.cj:160`、`MQServer_test.cj:292-305` | ✅ |
| | 删除订阅组生效 | `MQManager_test.cj:160`、`MQServer_test.cj:274-290` | ✅ |
| | 列表空结果 | `MQManager_test.cj:192` + `MQManagerOutput_test.cj:101` | ◐ |
| 输出渲染 | 中英文混排对齐 | `MQManagerOutput_test.cj:37` | ✅ |
| | 错误前缀 | `MQManagerOutput_test.cj:48` | ✅ |
| 连接失败语义 | 端口不可达 | `MQManager_test.cj:216`、`MQServer_test.cj:315` | ◐ |
| | 配置缺失 | — | ✗（G12） |
| | 服务端内部错误 | `MQManager_test.cj:104` | ⚠（严重） |
| | 载荷类型不符 | `MQManager_test.cj:125` | ⚠（严重） |
| 与服务端语义一致 | 重复注册 | `MQManager_test.cj:169` | ✅ |
| | 非绝对路径主题 | — （仅 executor 层 `MQCommandExecutor_test.cj:202`） | ✗（G15） |
| | 非法组名 | `MQManager_test.cj:145` | ⚠ |
| 子命令错误路径稳定契约 | 注册主题成功 | `MQManager_test.cj:163` | ✅ |
| | 主题重复 | `MQManager_test.cj:169` | ✅ |
| | 删除不存在的主题或订阅组 | `MQManager_test.cj:173-175` | ✅ |
| | 订阅组依赖主题 | `MQManager_test.cj:182` | ✅ |
| | 空列表 | `MQManager_test.cj:192` | ✅ |
| | 连接失败 | `MQManager_test.cj:216` | ✅ |
| 统计查询子命令 | 查询全部主题 | `MQManager_test.cj:229` | ⚠（G16） |
| | 按主题查询 | `MQManager_test.cj:230` | ⚠ |
| | 未知主题 | `MQManager_test.cj:231` + `MQManagerOutput_test.cj:135` | ⚠ |
| | 连接失败 | `MQManager_test.cj:249` | ✅ |
| 主题延迟定义参数 | 带延迟注册 | `MQManager_test.cj:227`、`MQManagerOutput_test.cj:73` | ◐ |
| | 默认无延迟 | `MQManagerOutput_test.cj:73`（`/audit` 0s） | ◐ |
| | 非法延迟 | `MQManager_test.cj:238` | ✅ |
| | 参数个数 | `MQManagerArgs_test.cj:44-51` | ✅ |
| 输出可断言 | 注册主题输出 | `MQManagerOutput_test.cj:60` | ✅（渲染层） |
| | 列表输出 | `MQManagerOutput_test.cj:73` | ✅（渲染层） |
| | 统计输出 | `MQManagerOutput_test.cj:107` | ✅（渲染层） |
| | 空列表 | `MQManagerOutput_test.cj:101` | ✅（渲染层） |

#### metrics（3 Requirement / 14 Scenario）

| Requirement | Scenario | 用例 | 判定 |
|---|---|---|---|
| 指标口径 | 积压与延迟 | `ConsumeService_test.cj:371` | ✅ |
| | 无积压 | `ConsumeService_test.cj:371`（后半段） | ✅ |
| | 计数器 | `GroupCursor_test.cj:690,712` | ◐（`stats` 层未断言 redelivered/deadLettered） |
| | 自动确认计数 | `ConsumeService_test.cj:408` | ✅ |
| | 删除后计数清零 | `ConsumeService_test.cj:428` | ◐（组外隔离未断言） |
| | 未来发布时间 | `ConsumeService_test.cj:542` | ✅ |
| 统计查询 | 查询全部 | `ConsumeService_test.cj:580`、`MQCommandExecutor_test.cj:584` | ✅ |
| | 按主题过滤 | `ConsumeService_test.cj:580` | ✅ |
| | 未知主题 | `ConsumeService_test.cj:554` | ✅ |
| | 查询无副作用 | `ConsumeService_test.cj:608` | ✅ |
| | 扫描失败不伪造 0 | `ConsumeService_test.cj:482`、`:512` | ✅ |
| 指标清理入口 | 删除主题 | `ConsumeService_test.cj:428`（`metrics.size == 0`） | ✅ |
| | 删除组 | `ConsumeService_test.cj:428` | ◐（未断言其他组不受影响） |
| | 并发读取 | — | ✗（且实现有 G4 竞态） |

### 五、空测试 / 空函数 / 禁用用例

- 未发现空 `@TestCase`、`@Ignore`/`@Disabled`、`throw NotImplemented`、只有 `return` 的空函数。
- 唯一「空断言」片段：`MQCommandExecutor_test.cj:188-191` 的 `case RESP(_) => @Assert(true)`
  （同一用例后续有真实断言，见建议项）。
- 覆盖「勾选但无用例」：`发布触发备份`（G13）、`manager 不安装退出钩子`（G14）、
  `配置缺失`（G12）、管理端 `非绝对路径主题`（G15）、`并发读取`（G19/G4）。
- 弱断言集中区：`MQManager_test` 系列（仅退出码）、`MQConfig_test` 的「默认值」段、
  `MQServer_test.managerCommandsAgainstRunningServer` 的列表类断言。

### 六、死代码

| 类别 | 位置 | 说明 |
|---|---|---|
| 未使用符号 | `fmq/src/server/MQSubscriptionInfo.cj:65-70` | `isConnected()` 全仓无调用方 |
| 仅测试使用 | `fmq/src/server/SubscriberRegistry.cj:137-152` | `removeByBuffer()` 仅 `MQServer_test.cj:497` 调用 |
| 仅测试使用 | `SubscriberRegistry.cj:218-222`、`BackupStore.cj:227-233`、`MQMetrics.cj:77-81`、`ConsumeService.cj:336-340` | `count()` / `instanceCount` / `size` / `statsScans` 为测试观测点（有注释说明，可保留） |
| 仅测试使用 | `MQServer.cj:247-256`、`MQCommandExecutor.cj:71-74` | `subscriptionRegistry`、`setCloseStepsOverride`、无连接 `execute(request)` 为测试钩子 |
| 死链路 | `MQSubscriptionInfo.cj:34-36,83-85` + `SubscriberRegistry.cj:137-152` | `connectionKey` → `hasBuffer` → `removeByBuffer` 整条链只在测试中闭合 |
| 不可达分支 | `fmq/src/main.cj:70-73` | `command` 必不以 `-` 开头，`--help` 判断恒假 |
| 不可达分支 | `fmq/src/manager/MQManager.cj:85-88` | `parse` 已拒绝未知子命令，`case _` 不可达（防御性保留，可删） |
| 未使用 import | `fmq/src/manager/MQManager.cj:20` | `fountain::f_data.*`（`DataAny` 已单独导入） |
| 未使用 import | `fmq/src/server/MQManager_test.cj:27`、`ConsumeService_test.cj:27` | `SocketBuffer`、`MQResult` |
| 注释代码 | — | 未发现被注释掉的代码块 |
| `@Deprecated` | — | 未发现 |

### 本轮统计

| 严重程度 | 数量 |
|---------|------|
| 严重 | 1 |
| 一般 | 21 |
| 建议 | 12 |

### 总评

R4 范围内的生产代码质量总体良好：生命周期装配/关闭的幂等与逐步容错、断链清理的代次保护、
`stats` 的单趟扫描与失败不伪造 0、配置的严格解析这几处都是「问题驱动 + 用例跟随」的写法，
规格承诺基本都能在代码中对应到具体行，闭包捕获、锁粒度、错误分类也处理得比常见实现更细致。

主要短板集中在**验收可信度**与**文档同步**：

1. 最需要先修的是 A65 两个用例（严重）——它们的退出码断言与错误实现完全同码，等于没有保护；
   建议连同 `MQManager` 的输出路径一起重构为可注入 sink，顺带解决 `stats` 文案与「格式异常误报无法连接」。
2. 其次是文档漂移：`详细设计.md` 的 §3/§5/§6.1/§6.7/§7 描述的仍是修复前的实现（`?? default`、
   `removeByBuffer`、`onPublish(buffer, ...)`、`delayingMs` 参数），加上「六/七子命令」并存，
   会让下一轮审计继续误判。建议以源码为准一次性回写，并把「关闭顺序」「断链机制」两段做成
   与 `closeSteps` / `cleanupSubscribers` 一一对应的清单。
3. 代码侧唯一的真实运行期缺陷是 `MQMetrics.bump` 与删除的竞态（并发删除主题时消费路径偶发 INTERNAL）；
   其余为死代码与可观测性改进。删除 `isConnected`/`removeByBuffer` 链路后，
   断链机制只剩一条实现路径，也能消除文档误读的根源。
