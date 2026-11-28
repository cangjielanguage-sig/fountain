# fprobe 模块审查报告（第 8/9 部分）

- **审查日期**：2026-11-28
- **模块路径**：`fprobe/src/supervisor`（本部分 6 个文件）+ `fprobe/src/tui`（本部分 14 个文件），共 20 个源文件
- **基线**：工作区快照（`git diff` 为空，HEAD `f309f0b55`）⇒ 所有问题来源均为「存量」
- **审查重点**：采集正确性与低开销、句柄与缓冲区生命周期、并发安全、死代码、重复逻辑（fprobe 专项）+ 通用维度 + 全部专项扫
- **报告版本**：分部分报告（`parts/fprobe.part8.md`），由主 Agent 合并进 `docs/review/2026-11-28/fprobe_v2.md`

## 发现

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

## 优化可行性方案

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

## 待验证假设

> 没有性能测试数据支撑的猜测，**不进 `todo.md` / `tasks.md`**。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 每节点每 tick 22 次 JSON 解析是拉取线程的主要自耗时 | `NodeHistoryStore.cj:62-71`、`MetricProjection.cj:102` | `evaluate`/`jsonToData` 自耗时占比 | `cjprof record` 跑 supervisor，10 节点、5s tick、10 分钟稳态 |
| 2 | `NodeStateStore.all()` 锁内 O(n²) 插入排序会拖慢拉取线程 | `NodeStateStore.cj:48-72` | 单次持锁时长、写者等待时长 | 节点数 10/100/1000，分段计时 + 线程状态采样 |
| 3 | 每 tick 起 N 个线程的创建/回收开销不可忽略 | `PollLoop.cj:108-111` | 线程峰值、每 tick 线程创建耗时 | 压测 N=10/100/1000，统计 tick 耗时分布（P50/P95） |
| 4 | 每帧 `W×H` 字符串矩阵造成 GC 抖动 | `ChartPanel.cj:89`、`FprobePainter.cj:137` | 每帧分配量、GC 次数 | 加分配计数器，跑 10 分钟，对比有无一帧缓存 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `fprobe/src/supervisor/HistoryRing_test.cj` | .cj | ✅ | 3 个用例，覆盖容量丢弃最旧点/空窗口/非法容量；断言与 `HistoryRing` 实现一致 |
| 2 | `fprobe/src/supervisor/NodeState.cj` | .cj | ✅ | 纯数据模型，无缺陷 |
| 3 | `fprobe/src/supervisor/NodeStateStore.cj` | .cj | ✅ | 锁覆盖单次 HashMap 操作；`all()` 排序在锁内（见优化方案 3） |
| 4 | `fprobe/src/supervisor/NodeStateStore_test.cj` | .cj | ✅ | 含 3 线程并发用例，读路径经 `store.all()`；替身 `onlineState` 私有且被引用 |
| 5 | `fprobe/src/supervisor/PollLoop.cj` | .cj | ✅ | 见发现 #4、#5 |
| 6 | `fprobe/src/supervisor/PollLoop_test.cj` | .cj | ✅ | 三个用例覆盖 tick 次数/阈值事件/评估器隔离；`ScriptedSource.index` 非原子但每 tick 单线程使用 |
| 7 | `fprobe/src/tui/ChartPanel.cj` | .cj | ✅ | 见发现 #8；`supports` 只放行 line/bar（与 `report/ChartSelector` 的 line/area/bar 有意不同） |
| 8 | `fprobe/src/tui/ChartPanel_test.cj` | .cj | ✅ | 5 个用例，覆盖 None 分支与单元格形状 |
| 9 | `fprobe/src/tui/FprobePainter.cj` | .cj | ✅ | 见发现 #3、#6、#9 |
| 10 | `fprobe/src/tui/FprobePainter_test.cj` | .cj | ✅ | 9 个用例，覆盖 start/draw/restore、尺寸未知、图表回退、续格不左移 |
| 11 | `fprobe/src/tui/KeyMap.cj` | .cj | ✅ | 8 值枚举全映射，无遗漏 case |
| 12 | `fprobe/src/tui/KeyMap_test.cj` | .cj | ✅ | 表驱动，覆盖全部 8 个映射 |
| 13 | `fprobe/src/tui/NodeHistoryStore.cj` | .cj | ✅ | 见优化方案 1、2 |
| 14 | `fprobe/src/tui/NodeHistoryStore_test.cj` | .cj | ✅ | 3 个用例，覆盖容量/目录投影/未知节点 |
| 15 | `fprobe/src/tui/Painter.cj` | .cj | ✅ | 两个接口，无实现，无缺陷 |
| 16 | `fprobe/src/tui/RenderLoop.cj` | .cj | ✅ | 见发现 #11、优化方案 3 |
| 17 | `fprobe/src/tui/RenderLoop_test.cj` | .cj | ✅ | 2 个用例；`slowRenderingDoesNotThrottlePolling` 依赖真实时钟与 sleep，属需实测型用例（未跑） |
| 18 | `fprobe/src/tui/RenderPlan.cj` | .cj | ✅ | 见发现 #7、#10、优化方案 2 |
| 19 | `fprobe/src/tui/RenderPlan_test.cj` | .cj | ✅ | 9 个用例，覆盖节点行/缺失项/告警页/拓扑页/图表字段 |
| 20 | `fprobe/src/tui/SupervisorApp.cj` | .cj | ✅ | 见发现 #1、#2 |

合计：`.cj` 20 个 / `.md` 0 个 / 共 20 个，全部读完（清单无 `.md`）。

## 覆盖自检

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

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 4 |
| 轻微 | 7 |
| 优化方案（堆内存 / CPU） | 1 / 3 |

## 总评

本部分（supervisor 状态层 + tui 视图层）质量偏高：状态与视图彻底分离，`NodeState` 整体替换、失败保留旧快照、历史环定长、渲染计划是纯数据，测试覆盖到并发写入、阈值事件、图表回退与宽字符续格这些容易漏的点，没有发现数据竞争、无界增长型 OOM 或栈溢出。主要风险集中在**装配与生命周期**而不是算法：`r` 键的链路在最后一跳断掉（#1）、`shutdown()` 的 `runningState` 门槛会在 `start()` 中途失败时把终端留在 raw mode（#2）、以及 `systemPainter` 与 `SupervisorBootstrap.createPainter` 两套装配行为不一致、使「信号退出走同一套钩子」的文档承诺存疑（#3）。这三条都建议排期修复，且都只需改十行以内。`PollLoop` 的每 tick N 线程（#4）在节点数上量时才需要处理，可先加并发上限再谈优化。优化方案与待验证假设全部缺基线，本轮不作为缺陷、不进 tasks。

存量 11 条（4 一般 + 7 轻微），是否纳入修复待用户决定。
