# fprobe 模块审查报告（第 7/9 部分）

- **审查日期**：2026-11-28
- **模块路径**：`fprobe`（本部分 20 个源文件：`src/report`、`src/rpc`、`src/runtime`、`src/snapshot`、`src/supervisor/HistoryRing.cj`）
- **基线**：工作区快照（master 与 sts/1.3.x 同提交 `120fd2542`，`git diff` 为空）⇒ 所有问题来源均为「存量」
- **审查重点**：采集正确性与低开销、句柄与缓冲区生命周期、并发安全、死代码、重复逻辑
- **报告版本**：分部分报告 v1（主 Agent 合并为 `docs/review/2026-11-28/fprobe_v2.md`，本文件不写入 `docs/review/`）

## 发现

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

## 优化可行性方案

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

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `ProbeSnapshot.agents` 的重复 JSON 解析是 supervisor 侧主要 CPU 开销之一 | `fprobe/src/snapshot/ProbeSnapshot.cj:77` | `decodeAgents` 自耗时占比、每 tick 分配量 | `cjprof record` 跑 10 节点 × 15 指标 × 200 tick，对照 `AlarmEngine.evaluate` 与 `decodeAgents` 的 self time |
| 2 | 告警邮件同步发送把 tick 周期拉长到远超 `pollIntervalMs` | `fprobe/src/runtime/SupervisorRuntime.cj:142` | 单次 SMTP 往返耗时（P50/P95）、tick 间隔分布 | 在 `dispatch` 前后打点，注入 5 节点 × 3 规则持续触发，统计 tick 间隔 P95；另用假渠道把发送耗时固定为 2000ms 做对照 |
| 3 | LLM 分析线程会随告警风暴累积 | `fprobe/src/runtime/SupervisorRuntime.cj:145`、`:250` | 并发在飞数、线程数曲线 | 用延迟 30s 的假 `LlmClient`，5 分钟内制造 100 条告警，采集线程数峰值与 LLM 调用完成数 |
| 4 | 渲染帧路径上 `RenderPlan` 构建（含 `agents` 解析）占 RenderLoop 单帧耗时的主要部分 | `fprobe/src/tui/RenderPlan.cj:391` | 单帧耗时分解 | 在 `RenderLoop.renderOnce` 内分段计时（取快照 / 构建 plan / 写终端），10 节点稳态跑 5 分钟取中位数 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `fprobe/src/report/ReportBuilder_test.cj` | .cj | ✅ | 用例覆盖摘要/内联/失败退化/转义/日志；辅助函数 `countOf` 有空串死循环隐患（见轻微 #三处测试用例） |
| 2 | `fprobe/src/report/ReportJob.cj` | .cj | ✅ | CRON 校验与发送异常处理；构建异常未兜住（见「ReportJob.runOnce 只兜住发送」） |
| 3 | `fprobe/src/report/ReportJob_test.cj` | .cj | ✅ | 覆盖空 CRON/非法 CRON/注册/发送/失败日志，与实现一致 |
| 4 | `fprobe/src/report/ReportTestSupport_test.cj` | .cj | ✅ | 测试替身（`FakeHistory`/`FixedChart`/`ThrowingChart`），无生产影响 |
| 5 | `fprobe/src/report/TopologyRenderer.cj` | .cj | ✅ | 确定性环形布局、链路去重；插入排序重复（见轻微 #插入排序） |
| 6 | `fprobe/src/report/TopologyRenderer_test.cj` | .cj | ✅ | 确定性与空拓扑用例，与实现一致 |
| 7 | `fprobe/src/rpc/NodeEndpoint.cj` | .cj | ✅ | `name@host:port` 解析含空串/端口范围校验，未见缺陷（IPv6 字面量 `[::1]:port` 不支持，属待确认规格） |
| 8 | `fprobe/src/rpc/NodeRpcTransport.cj` | .cj | ✅ | 定向 RPC、失败重连；锁内阻塞 I/O（见「NodeRpcTransport 持锁做阻塞传输」）、close 吞异常（见轻微） |
| 9 | `fprobe/src/rpc/ProbeRPC.cj` | .cj | ✅ | `@RPCStub` 契约，两个方法均为 `DataFields` 返回 |
| 10 | `fprobe/src/rpc/ProbeRPCImpl.cj` | .cj | ✅ | 快照仓库 + 注册表读取；`reset()` 仅测试引用（见轻微 #可见性建议） |
| 11 | `fprobe/src/rpc/RpcTestSetup_test.cj` | .cj | ✅ | 测试进程设置 `protocol_hostId`，仅测试生效 |
| 12 | `fprobe/src/rpc/Rpc_test.cj` | .cj | ✅ | 桩展开、DTO 往返、超时/ERROR/重连；测试内清空全局注册表，隔离性一般 |
| 13 | `fprobe/src/runtime/AgentRuntime.cj` | .cj | ✅ | 装配与 serve；初始化异常被吞（见「初始化链异常被 Future 吞掉」）、重复发布快照（见轻微） |
| 14 | `fprobe/src/runtime/RuntimeSupport.cj` | .cj | ✅ | `NullPainter` 为有注释的 Null Object；`MetricExtractor` 与目录口径重复（见「两套 kind→主指标口径」） |
| 15 | `fprobe/src/runtime/SupervisorBootstrap.cj` | .cj | ✅ | 终端对象单例、resident 分支，未见缺陷 |
| 16 | `fprobe/src/runtime/SupervisorRuntime.cj` | .cj | ✅ | 两个 `NodeStateStore` 实例（见严重 #1）、同步 I/O（见「告警渠道发送同步」）、无界 spawn（见「LLM 无上限 spawn」）、start 竞态（见「start 检查-然后-写入」） |
| 17 | `fprobe/src/runtime/SupervisorRuntime_test.cj` | .cj | ✅ | 纯函数与渠道构建用例；全局配置未还原原值（见轻微） |
| 18 | `fprobe/src/snapshot/ProbeSnapshot.cj` | .cj | ✅ | DTO + 快照仓库；`agents` 每次解析（见优化方案） |
| 19 | `fprobe/src/snapshot/SnapshotStore_test.cj` | .cj | ✅ | 一致性用例可能空转（见轻微） |
| 20 | `fprobe/src/supervisor/HistoryRing.cj` | .cj | ✅ | 定长窗口；`remove(at: 0)`（见轻微）、单写者约定由 `NodeHistoryStore` 的锁兜住 |

合计：`.cj` 20 个 / `.md` 0 个 / 共 20 个，全部读完。

## 覆盖自检

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

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 1 |
| 一般 | 8 |
| 轻微 | 7 |
| 优化方案（堆内存 / CPU） | 0 / 2 |

存量 16 条（1 严重 + 8 一般 + 7 轻微）；是否纳入修复待用户决定，本报告不替用户拍板。

## 总评

本部分的代码分层清晰、职责单一：`report` 只做 HTML/SVG 组装，`rpc` 把「定向连接」与「RPC 契约」拆成两层，`runtime` 只做接线，`snapshot` 用「单写者整体替换」把并发模型压到一把只保护引用的锁上，`HistoryRing` 的语义（旧→新、不伪造 0 值）也写得很明确。测试对可观测行为（转义、XML 声明剥离、单图失败退化、确定性布局、失败重连）覆盖得比较扎实。

阻塞项只有一个，但影响直接：`SupervisorRuntime.cj` 构造期创建了两个 `NodeStateStore`，`llmLoop` 拿到的是那个永远为空的实例，导致 `probe_llmTrigger=interval` 的周期分析在无节点数据的情况下照样调用模型并对外发建议——属于「看起来在工作、实际输入是空」的静默失效，建议排在最前修，并补一条断言 `states` 非空的用例。

其次是三处结构性风险，可排期但不是阻塞：告警邮件与报告发送同步跑在采集/定时线程上（SMTP 抖动会直接拉长 tick）、LLM 调用无并发闸门（告警风暴下线程会累积）、`NodeRpcTransport` 把阻塞 `transfer` 放进临界区（退出时最长多等一个 `nodeTimeoutMs`）。三者都不是实测热点，属于「先改结构、再谈收益」的类型。

其余问题以维护性为主：`MetricExtractor` 与 `ProjectionCatalog` 两套指标口径并存且已漂移（生产只用后者）、`ReportJob` 的构建异常没走自己的日志契约、`HistoryRing` 的 `remove(at: 0)` 与三处插入排序属于实现落后于数据结构的典型，收益需测量后再决定。两处优化方案（`agents` 重复 JSON 解析、拓扑排序）都缺基线数据，本轮只作为下一轮补数据的清单，不进修复任务。
