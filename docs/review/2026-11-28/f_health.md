# f_health 模块审查报告

- **审查日期**：2026-11-28
- **模块路径**：`f_health`（4 个 `.cj`，共 214 行；2 个 `.md`）
- **基线**：工作区快照（sts/1.3.x 工作区，未对照远端目标分支；`git status --porcelain f_health` 为空，本报告全部问题来源记为「存量」）
- **审查重点**：健康检查语义、死代码、重复逻辑、并发安全、存量 BUG、README 覆盖率（通用维度 + 全部专项扫）
- **报告版本**：v1

## 发现

### [严重][存量] `HealthData` 全字段是实时计算属性：无法反序列化，RPC 客户端读到的是本进程指标

- **位置**：`f_health/src/HealthData.cj:22`（`@DataAssist[fields]`）、`:24-78`（11 个只读计算属性）
- **来源**：存量（`git blame -L 22,51 -- f_health/src/HealthMonitor.cj` 与 `git log -- f_health` 显示全部文件由 `ded2987aba`（2026-08-17）引入，此后只有版本号提交；工作区无未提交改动）
- **判据**：review-checklist §11（契约与实现不符 / 静默数据错误）、§3（失败被丢弃）
- **证据**：静态确定 —— 四段代码串起来即可定论：
  1. 11 个字段全部写成 `prop x: Int64 { get(){ getAllocatedHeapSize() } }`，**没有 setter**；`@DataAssist[fields]` 对非 `mut` 属性一律生成 `ReadonlyField`（`f_data/src/macros/DataAssist.cj:557-565`、`:574`），`ObjectFields` 只把 `MutableField` 收进 `mutables`（`f_data/src/base/ObjectFields.cj:29-33`）→ `HealthData` 的可写字段集合为空；
  2. `DataObject.populate` 逐字段走 `set` → `mutableField(name)` 为 `None` → 默认 flag `DEFAULT_DATA_FLAG = SILENCE`（`f_data/src/base/global_objects.cj:42-51`）含 `IGNORE_FIELD_NOT_FOUND` → **静默跳过，不抛异常**（`f_data/src/base/DataObject.cj:119-129`）；
  3. 于是 `HealthData.tryFromData(远端 JSON)` 返回 `Some(HealthData())`：对象里没有任何被写入的值，getter 仍然调用本进程的 `getAllocatedHeapSize()` / `getGCCount()` 等；
  4. 消费链路确实存在：`@RPCStub` 生成 `RPCClient.call<HealthData>(...)`（`f_rpc/src/macros/RPCStub.cj:152`）→ `R.fromData(data)`（`f_rpc/src/client/RPCClient.cj:208`），而契约正是 `func health(): HealthData`（`f_rpc/src/health/HealthRPC.cj:24`）。
  旁证：`fprobe` 为绕开该限制单独复制了 11 个字段的 DTO，注释写明「`HealthData` 的字段是只读计算属性，无法从 RPC/HTTP 响应中回填（`ReadonlyField` 没有 setter）」（`fprobe/src/collect/health/HealthMetrics.cj:21-27`），并且定向调用后不再走 `HealthData`，改用 `HealthMetrics.tryFrom` 解析（`fprobe/src/collect/health/RpcHealthTransport.cj:98-99`）。
- **描述**：同一根因带来两个后果。① **反序列化静默失效**：任何按契约消费 `HealthData` 的一方（RPC 客户端、缓存、离线回放）拿到的都是一个"合法但全为本机实时值"的对象——调用不报错、字段不为 0 甚至看起来"正常"，实际数值与本进程无关，属于最难发现的错误数据；想读远端数据只能像 fprobe 那样另建 DTO。② **不是快照**：`toData()` 生成 `DataObject<HealthData>(this)`（`f_data/src/macros/DataAssist.cj:627-629`），序列化时逐个字段调用 getter，11 个指标分别在不同时刻采样，`gcCount`/`gcFreedSize`、`usedHeapSize`/`maxHeapSize` 可能来自不同瞬间；`HealthInitializer` 每 tick 只建一个实例分发给所有 monitor（`HealthInitializer.cj:40-43`），后一个 monitor 读到的值与前一个不同，把对象存下来留待后用则数值会继续变化。模块名为"健康数据"，实际是"进程指标的实时视图"。
- **建议**：把 `HealthData` 改成快照值对象：11 个 `private var` 字段 + 公有只读 `prop`（或直接 `public var`），新增 `public static func sample(): HealthData`，构造时一次性读完 11 个 runtime 函数；`HealthInitializer` 每 tick 调 `sample()`，monitor 拿到不可变快照，`@DataAssist[fields]` 同时因存在 `MutableField` 而让 `tryFromData` 真正可用。若要保持 `HealthData()` 零参可用，字段给默认值即可（`fprobe/src/collect/health/HealthMetrics.cj:29-41` 就是现成写法）。README「健康数据」段补一句"为采集快照，可直接序列化/反序列化"。

### [一般][存量] 监控器分发无异常隔离且完全串行：一个 monitor 出错或阻塞会连带其余监控

- **位置**：`f_health/src/HealthInitializer.cj:39-44`（定时回调内 `for ... emit`）、`f_health/src/HealthMonitor.cj:33-35`（`emit` 同步调用用户实现）
- **来源**：存量（`ded2987aba`）
- **判据**：review-checklist §12.1（异步语义 / 失败隔离）、§6.3（单线程串行段）、§3（异常静默）
- **证据**：静态确定（同 tick 中断、串行阻塞）+ 待确认（`Timer.repeat` 对 action 抛异常的处置：本机无 SDK 文档可查，未核实异常是否终止周期任务）
- **描述**：`Timer.repeat` 的回调里没有任何 `try`，`HealthMonitorHub.emit` 直接 `monitors.get(name)?.emit(data)` 同步调用 `HealthMonitor` 的用户实现。① 任一 monitor 抛异常 → 本 tick 里排在它后面的 monitor 全部不执行，且没有任何日志说明"这次采集缺了谁"；② 该异常穿出回调后，若 `std.sync` 不在定时线程内兜底，注册的周期任务会整体停止，健康监控从此静默消失（待确认）；③ 任一 monitor 阻塞（例如把 emit 实现成同步 HTTP/RPC 推送）→ 后续 monitor 与下一 tick 一起顺延，采集出现空档，而 `Timer.repeat(period, period, ...)` 未显式指定 `style`，下一轮与上一轮耗时的关系也未在代码里说明（待确认）；④ 分发是单定时线程串行，monitor 越多单 tick 越长。
- **建议**：逐个 monitor 包 `try { ... } catch (e: Exception) { log.warn(...) }` 并带上 monitor 名；在 `HealthMonitor` 接口注释里写明"`emit` 必须快速返回、不得阻塞"；如需推送型 monitor，提供可选的有界异步分发（固定线程数 + 丢弃计数）而不是让使用方在 emit 里阻塞；给 tick 加耗时埋点便于后续定位。

### [一般][存量] 注册与分发两端均无校验与可观测：同名覆盖、未知名丢弃、注册名不在 enabled 时永不触发

- **位置**：`f_health/src/HealthMonitor.cj:30-31`（覆盖写）、`:33-35`（未命中静默）；`f_health/src/HealthInitializer.cj:37-43`（`enabled` 启动时读一次）
- **来源**：存量（`ded2987aba`）
- **判据**：review-checklist §1（注册了但永不触发）、§3（静默失效）；`fountain-baseline.md` §4（同名注册应启动直接失败，不做隐式优先级）
- **证据**：静态确定 —— `monitors[monitor.name] = monitor` 是普通 `put`，无返回值、无日志；`emit` 用 `?.` 把"名字不存在"折叠成 no-op；`enabled` 只在 `initialize()` 读一次并被闭包捕获。
- **描述**：三种失败都表现为"配置打开了但没有任何健康日志"，无任何可观测信号：① 两个 monitor 同名 → 后注册者静默覆盖先注册者（与基线要求的"启动直接失败"相反）；② `health_enabled=logs` 这类拼写错误 → 每次 tick 都丢弃，不告警；③ 某个 monitor 注册了但名字没写进 `enabled`（或注册发生在定时器启动之后）→ 它永远不会被调用，也无人提示。另外 `'log'` 这个唯一内置名字只硬编码在 `HealthLogMonitor.name`（`HealthMonitor.cj:43-47`），没有公开常量，用户只能从源码或 README 抄字符串。
- **建议**：`register` 改为 `putIfAbsent` 语义，冲突时抛异常或打 error 并保留先注册者；`emit` 未命中时 `log.warn`（同名仅报一次或用计数器）；`initialize()` 里对 `enabled` 逐名做一次存在性检查并 warn；导出 `public static const NAME = 'log'` 供配置引用。

### [一般][存量] README「健康数据」字段注释整体错位，9/11 个字段语义标错（中英两版）

- **位置**：`f_health/README.md:29-49`、`f_health/README_en.md:29-49`；对照实现 `f_health/src/HealthData.cj:24-78`
- **来源**：存量（`ded2987aba`；README 与源码同一次提交，无后续修正）
- **判据**：review-checklist §13（文档与实现不符）
- **证据**：静态确定 —— 11 个声明配 10 条注释，且每条注释都写在**声明下方**（`README.md:30` 的 `// 已分配的堆` 紧跟在 `:29 allocatedHeapSize` 之后），而仓颉文档注释与读者习惯是**前置**。按前置读法：`heapPhysicalMemory`（`:31`）被注释成"阻塞状态的线程数"（`:32`）、`blockingThreadCount` 被注释成"gc次数"（`:34`）、…… 一路错位到 `threadCount`，只有末尾 `usedHeapSize`（`:49`）恰好对；按"注释描述上一行"读，`heapPhysicalMemory` 之后的 9 个字段同样错位。真实语义见 `HealthData.cj:29-33`（`heapPhysicalMemory` = `MemoryInfo.heapPhysicalMemory`）、`:39-53`（`gcCount`/`gcFreedSize`/`gcTime`）等。`README_en.md:29-49` 结构相同、错误一致。
- **描述**：这是模块唯一的字段级文档（源码 11 个 prop 一条注释都没有）。按 README 读，读者会把物理内存当成阻塞线程数、把 GC 次数当成回收字节数——所有与容量/GC 相关的判断都会建立在错误的字段上；`fprobe` 这类消费方恰好最依赖这些字段。
- **建议**：注释移到声明上方并逐条对齐；更稳的做法是删掉重复的整段源码，改成「字段名 | 含义 | 单位」表格，从根上避免"源码改了 README 没跟上"。

### [一般][存量] README 配置段只有类型声明：没有取值说明、默认行为与最小可运行示例

- **位置**：`f_health/README.md:4-19`、`f_health/README_en.md:4-19`；对照 `HealthConfig.cj:20-41`、`HealthMonitor.cj:30-35`、`HealthInitializer.cj:37-44`
- **来源**：存量（`ded2987aba`）
- **判据**：review-checklist §14.2（关键配置完全无文档 / 缺关键段落）
- **证据**：静态确定 —— 全仓 `.md` 搜 `health_enabled` / `health_logMonitorPeriod`，只在两版 README 的代码块里出现（`f_health/README.md:8-9`、`README_en.md:8-9`），无任何赋值示例；`docs/` 下也没有（`docs/LocalMode.md:489` 只有一句"f_health 低频，不做"）。而实现要求：`health_enabled` 的值必须等于 `HealthMonitorHub.register` 时的 `name`（当前仅 `'log'`），多值以 `,` 分隔（`Config.getStringArray` 默认分隔符，`f_config/src/Config.cj:210-217`），不配置即空数组 → `HealthInitializer.cj:41` 的 `for` 一次都不执行；`health_logMonitorPeriod` 走 `Duration.parse`（`f_config/src/Config.cj:238-246`），小于 1s 被抬到 1s（`HealthConfig.cj:33-41`）。
- **描述**：读者无法从文档得知"要写哪个键、填什么值、默认是什么"。最糟的组合是：`cjpm` 里加了依赖、启动后一条日志都没有，也没有任何提示指向"`health_enabled` 没配"。同时缺依赖引入片段与最小示例，`README.md:10-12` 还给 `enabled` 写了一条源码里并不存在的文档注释（源码 `HealthConfig.cj:25-29` 无注释），属反向漂移，读者会以为源码里有更多约束。
- **建议**：补一张配置表（键 / 类型 / 默认值 / 分隔符 / 说明），给出 `health_enabled=log`、`health_logMonitorPeriod=5s` 的示例、`[dependencies] "fountain::f_health"` 片段，以及"未配置任何 monitor 时定时器仍在跑但不产出"这一现状说明（或按下一条修掉空转）。

### [轻微][存量] `enabled` 为空时定时器仍每秒分配并空转，且 `Timer` 句柄被丢弃无法取消

- **位置**：`f_health/src/HealthInitializer.cj:36-44`
- **来源**：存量（`ded2987aba`）
- **判据**：review-checklist §1（无用周期任务）、§11（资源句柄对称性）
- **证据**：静态确定（返回值未接收 ⇒ 无法 `cancel`；空数组 ⇒ 循环体不执行）；待确认（`Timer` 是否要求保持强引用才持续调度，本机无 SDK 文档）
- **描述**：① `enabled` 为空时不提前返回，仍然每秒 `HealthData()` 分配 + 一次空 `for`，等于为一个未启用的功能常驻一个定时任务；② `Timer.repeat(...)` 的返回值没有保存，全仓其他调用点都保留句柄（`f_mvc/src/WSMeta.cj:96` 存入 `let timer: ?Timer`、`f_net/src/server/server.cj:47` 存字段、`fleet/src/server/FleetStore.cj:33` 存 `static let`），本处既不能随停机取消，也无法在测试里关掉。
- **建议**：`if (enabled.isEmpty()) { return }`；`private static var timer: ?Timer` 保存句柄并提供 `stop()`（或挂到 f_app 的退出回调），顺带把"未启用即不起定时器"写进 README。

### [轻微][存量] `logMonitorPeriod` 解析失败与"未配置"不可区分，静默回退 1s

- **位置**：`f_health/src/HealthConfig.cj:33-41`
- **来源**：存量（`ded2987aba`）
- **判据**：review-checklist §11（错误处理静默 / 配置错误当默认值）
- **证据**：静态确定 —— `Config.getDuration` → `getData<Duration>` → `getValue` → `tryParse`（`f_config/src/Config.cj:238-246`），非法字符串返回 `None`，与"键不存在"合并进同一个 `else` 分支，无日志。
- **描述**：`health_logMonitorPeriod=10`（漏单位）或 `=10 秒` 都得到 1s：实际采集频率比预期高/低一个数量级，且没有任何提示。运维侧只能通过"日志条数不对"倒推。
- **建议**：区分 `None`（未配置，静默用默认）与"有值但解析失败"（打一次 warn 并带原值），或改用能返回 `Result` 的读取方式。

### [轻微][存量] `HealthInitializer.name` 返回空串，与仓库其他 initializer 的命名约定不一致

- **位置**：`f_health/src/HealthInitializer.cj:26-30`；对比 `f_rule/src/RuleInitializer.cj:36-39`、`f_egraph/src/egraph.cj:27-31`、`f_mvc/src/MVCInitializer.cj:23-27`、`f_orm/src/base/ORMInitializer.cj:25-29`、`f_ticktock/src/TicktockInitializer.cj:25-29`、`f_rpc/src/server/RPCServerInitializer.cj:25-29`（均为 `fountain::*`）
- **来源**：存量（`ded2987aba`）
- **判据**：review-checklist §10（命名 / 一致性）、§14（契约表达力）
- **证据**：静态确定 —— `InitializerCollection` 用 `name` 作依赖图键（`f_app/src/Initializer.cj:52`、`:66`、`:83`、`:91`），空名使其他模块无法声明依赖 f_health 的初始化项，日志里也无法识别这个节点。本轮不存在启动顺序缺陷（`Config` 的配置在库加载期的 `static init` 就绪，`f_config/src/Config.cj:62-66`，早于 `InitializerCollection.initialize()`，`f_app/src/funcs.cj:59-61`），所以只按一致性报。
- **描述**：`f_rule` 的测试注释把 `name`/`dependencies` 明确称为"契约而非装饰"（`f_rule/src/RuleInitializer_test.cj:26`）；f_health 用一个无名节点参与同一套机制，且 README:76 把"空字符串"写成了规格，等于把临时实现固化成契约。
- **建议**：改为 `'fountain::f_health'`，同步 `README.md:76` 与 `README_en.md:76`。

### [轻微][存量] 模块名为"健康检查"，实际只有指标采集与分发，没有可用作判定语义的健康状态

- **位置**：`f_health/src/`（全模块）；`f_health/README.md:1`；根 `README.md:464-466`
- **来源**：存量（`ded2987aba`）
- **判据**：review-checklist §10（命名与能力一致）、§14（契约表达力）
- **证据**：静态确定 —— 模块内搜不到 `healthy` / 阈值 / 状态判定相关符号（`f_health/src` 下无命中），`HealthData` 只有 11 个原始指标；对外端点恒返回指标（`f_mvc/src/health/MVCHealthMonitor.cj:26-29`，无状态码分支）。
- **描述**："健康检查"通常指可判定的 up/down（liveness / readiness）；本模块提供的是"可观测数据 + 定时分发"，判定权在使用方。README 首行只有"进程健康检查"六个字，没写这个边界，容易被当成开箱即用的健康端点。这是能力边界未说明，不是"承诺了没实现"。
- **建议**：README 首段明确"只做指标采集与分发，不做健康判定；判定阈值由使用方定义"；若确实需要，再补一个可选的判定型 `HealthMonitor` 实现（阈值来自配置），不要在本模块内硬编码。

## 优化可行性方案

> 本轮不提出堆内存 / CPU 优化方案。理由是采集频率被 `HealthConfig.logMonitorPeriod` 硬性限制在 ≥ 1 次/秒（`f_health/src/HealthConfig.cj:33-41`），单 tick 的固定成本是 11 次 runtime 指标读取 + 1 次 JSON 序列化 + 1 条日志，量级远低于噪声；没有改前基线就无法给出可验证收益，不编造百分比。可省的那部分（未启用时不启动定时器）已按缺陷记入「轻微」第 6 条。

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `HealthLogMonitor.emit` 的 JSON 序列化 + 日志格式化占单 tick 成本的主要部分 | `f_health/src/HealthMonitor.cj:48-50` | 各段自耗时占比 | `cjprof record` 跑 10 分钟稳态（period=1s、`health_enabled=log`），看 `JsonValue.tryFromData` / `Logger` 的 self time 占比；同时用 `getAllocatedHeapSize()` 差分算每 tick 分配量 |
| 2 | monitor 阻塞会把采集周期拉长到 `period + monitor 耗时`，形成数据空档 | `f_health/src/HealthInitializer.cj:39-44` | tick 实际间隔分布、线程状态 | 注入一个故意 `sleep(500ms)` 的 monitor，记录相邻 tick 时间戳 P50/P99，并对定时线程抓线程栈确认阻塞点 |
| 3 | `MemoryInfo.heapPhysicalMemory` 与其他 runtime 指标读取存在显著单次开销（可能是系统调用 / FFI） | `f_health/src/HealthData.cj:29-33` | 单次调用耗时 | 循环 1e6 次分别计时 11 个 runtime 函数，对比各函数中位数；若某函数明显偏贵，再评估是否只在该 monitor 需要时读取 |

## 文件覆盖

> 与 `reviews/202611280854_full-repo/files/f_health.txt` 一一对应。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_health/README.md` | .md | ✅ | 98 行全读；与实现比对：字段注释错位（§13 问题 #4）、配置段无取值说明（#5）、`enabled` 文档注释源码中不存在 |
| 2 | `f_health/README_en.md` | .md | ✅ | 99 行全读；与中文版章节、示例一一对应，同样的字段注释错位与配置缺口，无整节缺失 |
| 3 | `f_health/src/HealthConfig.cj` | .cj | ✅ | 41 行全读；3 个 public const + 2 个 prop 全部对外可达且被使用；周期下限 1s 正确；解析失败静默回退（#7） |
| 4 | `f_health/src/HealthData.cj` | .cj | ✅ | 78 行全读；11 个只读计算属性 → 不可反序列化 / 非快照（#1，严重） |
| 5 | `f_health/src/HealthInitializer.cj` | .cj | ✅ | 45 行全读；`static init` 注册（与 f_mvc/f_orm/f_rule 同型）、Timer 回调无异常隔离（#2）、空名（#8）、空转与句柄丢弃（#6） |
| 6 | `f_health/src/HealthMonitor.cj` | .cj | ✅ | 50 行全读；`ConcurrentHashMap` 使用正确，`register` 覆盖写与 `emit` 静默丢弃（#3）；`log.info{}` 为惰性求值，级别未开时不构造 JSON |

合计：`.cj` 4 个 / `.md` 2 个 / 共 6 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 9 | 严重 1（数据对象不可反序列化 / 非快照）+ 一般 4（分发无隔离、注册分发无校验、README 字段错位、README 配置缺口）+ 轻微 4（空转与句柄、配置解析静默、空名、健康判定语义缺失）。无外部输入拼接、无凭据、无敏感数据入日志（日志只含 11 个进程指标） |
| §1 死代码 | 0 | 已逐个过：`HealthConfig` 3 个 const（`HEALTH_PREFIX`/`HEALTH_ENABLED`/`HEALTH_LOG_MONITOR_PERIOD`）与 2 个 prop 均为 public struct 的对外可达成员，且仓内均有引用；`HealthData` 11 个 prop 经 `@DataAssist[fields]` 生成 `ReadonlyField` 的 getter 闭包引用（`f_data/src/macros/DataAssist.cj:557-565`），并被 f_mvc/f_rpc 消费；`HealthMonitorHub.monitors`（private，用于 `register`/`emit`）、`HealthMonitorHub.emit`（包内可见，`HealthInitializer.cj:42` 使用）、`HealthLogMonitor.log`（`emit` 使用）均有用；`name`/`emit` 为接口实现，`initialize`/`name`/`dependencies` 为 `Initializer` 实现，`static init` 由运行时调用；4 个文件的 import 全部有用。无 `return`/`throw`/`break` 之后的同层语句，无恒真恒假分支 |
| §2 重复逻辑 | 0 | 已两两比对 4 个文件的全部函数体摘要：11 个 prop getter 形状相同但委托的 runtime 函数各不相同（语义不同），抽取只能靠宏或反射、反而增加间接层，按「只改被调函数」不判重复；`HealthMonitorHub.emit` 与 `HealthLogMonitor.emit` 一为分发一为输出，不重复；两版 README 互为翻译。README 里整段复制源码的问题按文档漂移记入 §13（#4）而非本节 |
| §3 空实现 | 1 | 无空函数体、无 TODO/FIXME、无 `catch {}`；`HealthInitializer.dependencies` 返回空数组是接口默认语义，`name` 空串另按 #8 记。命中项：`HealthMonitorHub.emit` 对未注册名字 `?.` 静默 no-op（#3） |
| §4 栈溢出 | 0 | 全模块无递归（无自调用、无相互调用、无树/图遍历）；唯一的重复执行是定时器周期回调，不是递归 |
| §5 OOM | 0 | 每 tick 只分配 1 个 `HealthData`（11 个 Int64）+ 1 棵树 + 1 个字符串，频率 ≤1/s，无累积容器；`HealthMonitorHub.monitors` 只增不减但 key 来自代码常量，`register` 是显式 API，无按请求增长的路径 |
| §6.1 热点瓶颈 | 0 | 未提供 profile / bench 数据；单 tick 成本固定且频率被限制在 ≥1s，不存在结构性热点。相关猜测已列入「待验证假设」#1-#3，不计入统计 |
| §6.2 大粒度锁 | 0 | 本模块无 `Mutex` / `synchronized` / 自定义锁；`ConcurrentHashMap` 内部锁只保护单次 `get`/`put`，临界区不含 I/O 或解析 |
| §6.3 并发串行 | 1 | 命中并并入 #2：所有 monitor 在同一个定时线程里串行 `emit`，任一实现阻塞即拉长整轮；无 `spawn`、无 `Future`、无任务队列 |
| §6.4 低效算法 | 0 | `enabled` 遍历为 O(monitor 数)、`monitors.get` 为 O(1)；无嵌套循环、无 `contains` 扫描、无循环字符串拼接（日志只在 INFO 开启时构造一次，≤1/s） |
| §7 降堆内存方案 | 0 | 生命周期最长的是 `monitors`（几个常量键）与 `TypeInfo`/`ObjectFields` 静态缓存，都是一次性；每 tick 对象即刻死亡。未启用时不起定时器属缺陷（#6），不作为"优化方案"重复计数 |
| §8 降 CPU 方案 | 0 | 唯一可省的是 `enabled` 为空时的每秒空转（已按 #6 报缺陷）；其余为固定 11 次指标读取，没有基线不宣称收益 |
| §9 local mode 可行性 | 0 | `HealthData` 在定时回调内创建，但随即作为参数传给 `HealthMonitor.emit`（接口调用，可能被任意实现持有），并进入 `toData()` 的 `Data` 树与日志字符串，属逃逸；`docs/LocalMode.md:489` 也已把 f_health 标为"低频；不做" |
| §11 现有代码的 BUG（存量） | 4 | 已核对全部 4 个文件的可执行路径：`HealthData` 11 个 getter（#1 严重）、定时回调与分发（#2）、`register`/`emit`（#3）、`logMonitorPeriod` 解析（#7）；`HealthConfig.enabled` 的缺失键返回空数组（`f_config/src/Config.cj:210-217`）、`Duration` 比较、空数组遍历、`ConcurrentHashMap` 单键读写均已逐条推导无缺陷 |
| §12 并发安全与锁粒度 | 1 | 共享状态只有 `HealthMonitorHub.monitors`（`ConcurrentHashMap`，`put`/`get` 均单键原子，`register` 无"检查-然后-写入"复合操作）与 `HealthLogMonitor.log`（不可变静态句柄）→ 无数据竞争；命中项是分发侧：单线程串行 + 无异常隔离 + monitor 阻塞会外溢（#2）。`enabled` 数组在 `initialize()` 捕获后不再变化，闭包读安全 |
| §14 功能完备性与 README 覆盖 | 1 | 以 `src/` 公开声明为基准逐项对照 README：`HealthConfig` 3 个 const/2 个 prop、`HealthData` 11 个 prop、`HealthMonitor`、`HealthMonitorHub.register`、`HealthInitializer`、`HealthLogMonitor` 均有对应段落；根 `README.md:464` 已登记本模块，无"承诺但未实现"的能力。命中项：关键配置（`health_enabled` / `health_logMonitorPeriod`）只有类型声明，无取值说明、默认行为与示例（#5） |
| 文件覆盖（§13 等） | 6/6 | 无缺失文件；§13 命中 1 条（README 字段注释错位 = 一般），两版 README 之间无整节缺失 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 1 |
| 一般 | 4 |
| 轻微 | 4 |
| 优化方案（堆内存 / CPU） | 0 / 0 |

存量缺陷合计 9 条（严重 1 / 一般 4 / 轻微 4），全部为存量；是否纳入修复待用户决定。

## 总评

四个文件、214 行的规模，结构与职责划分是清晰的：`HealthConfig` 管配置并做了周期下限保护，`HealthData` 只做指标映射，`HealthMonitorHub` 用 `ConcurrentHashMap` 做注册表，`HealthInitializer` 用 `f_app` 的 `Initializer` + `Timer.repeat` 驱动采集，`HealthLogMonitor` 作为内置实现——与 f_mvc / f_orm / f_rule 的初始化器写法同型，没有引入额外机制，也没有锁、递归与无界容器。并发面本身是安全的：共享状态只有那张并发 map，注册期写入、读取期单键取，不存在检查-然后-写入。

阻塞项只有一条，但影响面最大：`HealthData` 把 11 个字段做成实时计算属性，导致它既不能被反序列化（`ReadonlyField` + `SILENCE` flag → 静默跳过），也不是快照。后果是 `HealthRPC.health(): HealthData` 这条公开契约在客户端方向上等于坏的——拿到的对象"看起来正常"却全是本机数值，且不报错；`fprobe` 已经因此单独复制了一份 DTO 并在注释里写明原因，这已经是代码库自己在指认这个问题。建议优先把 `HealthData` 改成"一次性采样的值对象"（私有可变字段 + `sample()` 工厂），一处改动同时解决反序列化、快照一致性与 monitor 间数据漂移。

一般项集中在"静默"上：分发不隔离异常、注册/分发两端不校验、README 把 9 个字段的语义标注错位、配置段没有任何取值说明。前三条的修法可以合并成一次"注册校验 + 分发隔离 + 未命中告警"的小改动；README 的两条是纯文档工作，改完就能让"装了模块却什么都没发生"这类问题有一个明确指向。

轻微项（未启用时空转并丢弃 Timer 句柄、周期配置解析失败静默回退、初始化器空名、健康判定语义未说明）都是可排期的清理项，不影响正确性。本轮不提出性能优化方案：采集频率被限制在 ≥1 次/秒，单 tick 成本固定且很小，三条待验证假设只是为下一轮补数据准备，不进 `todo.md` / `tasks.md`。
