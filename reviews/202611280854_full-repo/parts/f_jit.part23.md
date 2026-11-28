# f_jit 模块审查报告（模块第 23/38 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_jit`（本部分 20 个文件：3 个源文件 + 17 个 `_test.cj`）
- **基线**：工作区快照（master 与 sts/1.3.x 同一提交 `120fd2542`，`git diff` 为空）⇒ 全部问题来源记为「存量」
- **审查重点**：动态调用/桥接正确性（typecode 分支表）、句柄与资源生命周期、并发安全、递归与栈溢出、死代码、重复逻辑
- **报告版本**：v1（分部分报告，由主 Agent 合并；本文件不含 `docs/review/` 下的模块报告）

## 发现

### [严重][存量] 并发 `close` 的超时回退无条件把状态写回 0，可让已卸载单元重新变为「可调用」

- **位置**：`f_jit/src/JitFunction.cj:246-251`（单元级）、`f_jit/src/JitFunction.cj:318-324`（闭包级，同一根因）
- **来源**：存量（快照模式无基线）
- **判据**：checklist §12.1（共享可变状态「检查-然后-写入」非原子）/ §11（并发正确性）；README:592-596 承诺「`close(timeoutMs)` 超时则回退到可用态」，回退必须只在「本次 close 仍是 Unloading 的持有者」时发生
- **证据**：静态确定 —— 超时分支是 `synchronized(this.mtx) { this.state = 0 }`，不校验当前状态是否仍为 1（Unloading）。两个线程并发 `close` 时存在如下交错：A 的 `spins >= limit` 成立后阻塞在 `mtx` 上；B 拿到 `mtx` 置 `state = 2` 并在锁外执行 `release()`（释放码内存，`JitFunction.cj:278-285`）；A 随后拿到 `mtx` 把 `state` 覆盖成 0 并返回 `false`。此后 `enterUnit`（`:198-206`）看到 `state == 0` 放行，调用方在**已释放的机器码**上执行 ⇒ 崩溃 / 未定义行为。闭包侧同理：`e.state = 0` 覆盖 `unloadClosure` 已置的终态 2（`:327-331` 已执行 `e.group.releaseAll()`），此时靠 `callLocked` 的 `HandleTable.isLiveHandle(this.closureId)`（`:559`）才降级为 19（句柄槽若被复用则仍不确定），属于偶然缓解而非同步
- **描述**：状态机 `0 Ready → 1 Unloading → 2 Unloaded` 的回退迁移缺少「来源校验/世代号」，因此「一次超时 close」与「一次成功 close」并发时可以把终态改写回 Ready。触发条件：同一 `JitFunction` 被两个线程以不同 `timeoutMs` 调用 `close`（例如 `Resource.close()` = `close(0)` 与运维侧 `close(5000)` 同时发生）。
- **建议**：回退前校验 `if (this.state == 1) { this.state = 0 }`（成功路径置 2 后不再回退），或给每次 close 分配递增 token，回退时比对 token；`unloadClosure` 同样对 `e.state` 加同一守卫。补一条并发用例：两线程分别 `close(0)` / `close(50)`，断言终态只能是 2 且之后调用一律 19。

### [一般][存量] `close(timeoutMs)` 用「自旋次数」代替毫秒超时，且纯自旋占满一核

- **位置**：`f_jit/src/JitFunction.cj:237-253`（`limit = timeoutMs * 100000`）、`f_jit/src/JitFunction.cj:309-326`（闭包侧同形）
- **来源**：存量
- **判据**：checklist §11（语义与命名/契约不符）、§6.2（临界区反复取锁形成争用）
- **证据**：静态确定（计量单位是循环次数，不是时间）+ 需实测（实际墙钟相对 `timeoutMs` 的放大倍数）
- **描述**：形参名与 README:595「超时则回退」都表示时间预算，实现却是「每 1 ms 折 100 000 次 `synchronized` 取锁 + 读 `active`」。单轮取锁/放锁在无争用时约数十纳秒，`timeoutMs = 5000` 实际可自旋数十秒；机器越慢、核越忙，同一 `timeoutMs` 的墙钟差异越大。在此期间该线程 100% 占用一个核，并持续与正在 `exitUnit` 的调用方抢同一把 `mtx`，把「等排空」变成「抢锁」。
- **建议**：用 `MonoTime.now() + Duration.millisecond * timeoutMs` 作真截止时间，循环里用 `sleep`（毫秒级退避）或条件变量等待 `active == 0`；`timeoutMs <= 0` 保留「只查一次」语义。

### [一般][存量] `parseFnType` 不跟踪括号/泛型深度，泛型与高阶闭包签名被错误拆分

- **位置**：`f_jit/src/JitFunction.cj:795-852`（关键：`:836` 仅按 `,` 切分；`:800-803` 前缀剥离；`:847` 返回类型取 `arrow + 2`）
- **来源**：存量
- **判据**：checklist §10（正确性/边界）、§11（边界解析）
- **证据**：静态确定
- **描述**：`callForFn<Fn>` 用 `TypeInfo.of<Fn>().name` 反解签名，解析器只找**第一个** `->`、只按裸逗号切形参、不跳过 `<>`/嵌套括号：
  1. `(HashMap<String, Int64>) -> Int64` 会被切成两个形参 `HashMap<String` 与 `Int64>`，`codeOfTypeName` 对前者返回 `MAP`、对后者落到兜底 `HOST_OBJECT` ⇒ 包装器认为该闭包有 2 个形参，`w.call<Int64>([m])` 恒报「实参个数不符」（`:564-566`）；
  2. `((Int64) -> Int64) -> Int64` 的第一个 `->` 属于内层闭包，`retName` 被取成 `Int64) -> Int64` ⇒ 返回码落到 `HOST_OBJECT`，`call<Int64>` 报「T 与返回类型不符」（`:571-577`）。
  两条路径都不会静默算错值，但对合法签名一律误判为契约错误，属「合法输入被拒」。
- **建议**：解析时维护 `<>`/`()` 深度，仅在深度 0 处按 `,` 与 `->` 切分；解析失败（含残留 `>`/`)`）直接返回 `None` 退化为动态签名（`:517-518` 已支持），不要让 `codeOfTypeName` 的兜底把坏串记成 `HOST_OBJECT`。

### [一般][存量] 名字 → `LocalType` 映射有两份实现且已漂移（`JitClosureId` 只在一份里）

- **位置**：`f_jit/src/JitFunction.cj:895-927`（`codeOfTypeName`）与 `f_jit/src/JitFunction.cj:945-1010`（`computeTypeCode`，`JitClosureId` 在 `:983`）
- **来源**：存量
- **判据**：checklist §2（重复逻辑：同一张码表两种写法，差异造成行为漂移）
- **证据**：静态确定 —— `:907` 的注释自称「与 `localTypeOf` 同表」，但 `codeOfTypeName` 缺 `JitClosureId → CLOSURE`，兜底把任意未知非空名字记成 `HOST_OBJECT`（`:922-924`），而 `computeTypeCode` 对非类/接口类型返回 `None`（`:1005-1009`）
- **描述**：同一份「类型名 → 码」知识存在两套判定，且判定结果不一致：闭包签名里出现 `JitClosureId`（返回嵌套闭包、或把闭包 id 当形参）时，`parseFnType` 记 14，而 `call<JitClosureId>` 的 `localTypeOf` 记 12 ⇒ 包装器一创建就注定在 `:573` 报「T 与返回类型不符」；`Int32`/`UInt8` 一类不可封送类型在签名侧被记成 14 而不是被拒。
- **建议**：合并为单点表（`name -> ?UInt16`），`codeOfTypeName` 与 `computeTypeCode` 都只做「取 simple name + 查表 + 类/接口兜底」，兜底逻辑只保留一处；补 `JitClosureId` 与「未知类型返回 None」两条断言。

### [一般][存量] 卸载逐出前的窗口：编译缓存仍返回已进入终态的单元

- **位置**：`f_jit/src/JitFunction.cj:256-265`（`state = 2` 之后才 `CompileCache.remove(k)`，同一临界区内）；读取侧 `f_jit/src/CompilePipeline.cj:61-62`、`:97-98`（命中即返回，不校验 `isClosed()`）
- **来源**：存量
- **判据**：checklist §11（并发正确性：陈旧引用发布）、§12.1
- **证据**：静态确定（窗口存在）；发生频率需实测
- **描述**：`close` 先置终态再从缓存删除，而缓存查找只取缓存锁、不与单元锁互斥。窗口内另一线程 `Compiler.compile(同源)` 命中 `ready[key]` 拿到该单元并直接返回（`CompilePipeline.cj:62`），随后每次 `call` 都以 19 失败，且该调用方没有任何「已卸载则重编」的重试路径。窗口只有几条指令，但在「编译 + 卸载」交替的负载下会产生可观测的偶发 19。
- **建议**：查找侧拿到单元后校验 `isClosed()`，已关闭则按未命中重走管线；或让 `close` 先从缓存摘除再置终态（摘除后不可能再被发布），并把 `state` 读取纳入同一同步点。

### [轻微] `callLocked` 的 `options` 形参从未被读取

- **位置**：`f_jit/src/JitFunction.cj:555-556`（形参），全函数体内零引用（`options` 仅出现在 `:159/:164/:171` 与签名处）
- **来源**：存量
- **判据**：checklist §1（死参数 / 读了不用）
- **证据**：静态确定（`grep -n "options" JitFunction.cj` 只有 4 处，`callLocked` 内无 `options.`）
- **描述**：deadline 实际由 `call` 写入 `rs.deadlineNanos`，`callLocked` 只读 `rs`。因此 `callForFn` 传 `DEFAULT_CONTEXT`（`deadline = None`）**并不**表示「无期限」，而是继承线程当前 deadline——读者按形参推断会得出相反结论。
- **建议**：删除该形参，或在 `callLocked` 内自行应用 `options.deadline` 并让 `call` 不再改 `rs`；同时在 `callForFn` 处注释「沿用线程 deadline」。

### [轻微] 两处注释与声明错位（复制粘贴残留）

- **位置**：`f_jit/src/JitFunction.cj:91-94`（「本单元的 user helper 表…」注释挂在 `EMPTY_CELLS` 上，真正的 `helperEntries` 在 `:94` 无注释）、`f_jit/src/JitFunction.cj:390-392`（「便捷重载（默认为不等待活跃调用）」挂在 `isJitBacked()` 上）
- **来源**：存量
- **判据**：checklist §10（可读性/可维护性）
- **证据**：静态确定
- **描述**：`isJitBacked` 上方两条相邻注释，第一条描述的是已不存在的重载；字段区同理。按文档读代码会把 `EMPTY_CELLS` 误认成 helper 表。
- **建议**：把 helper 表注释移回 `helperEntries`，删除「便捷重载」这行残留注释。

### [轻微] 宿主异常路径直接 `printStackTrace()` 到标准输出，不走 `f_log`、不可关闭

- **位置**：`f_jit/src/JitReport.cj:44-48`
- **来源**：存量
- **判据**：`fountain-baseline.md` §6（日志走 `f_log`，热点/库内不直接打印）
- **证据**：静态确定
- **描述**：每个 `HOST_EXCEPTION`（21）都会打印一次完整仓颉栈，输出目标由运行时决定、调用方无法重定向或关闭；库被嵌入服务端后表现为进程 stdout 污染，且栈里可能含业务数据。
- **建议**：把原始异常交给上层报告构造器（`JitException.cause` 已有字符串通道），或注入可配置的 sink；至少加一个开关，默认关闭。

### [轻微] 基准与门禁用墙钟计时，易受 NTP/负载影响

- **位置**：`f_jit/src/PerfAdapter_test.cj:82`、`:91`（`DateTime.now()`）、`:102-105`（3× 时序门禁）；`f_jit/src/ParallelThroughput_test.cj:36-38`（`DateTime.nowUTC()` 计算 wall）
- **来源**：存量
- **判据**：checklist §6.1（基准口径：同环境、可复核）；同仓 `LoopSafepoint_test.cj:82` 已用 `MonoTime` 作正例
- **证据**：需实测（共享 VM 上的抖动幅度）
- **描述**：墙钟可被校时跳变，且 `DateTime` 分辨率/开销高于 `MonoTime`；`PerfAdapter_test` 还把「类型化 adapter 至少快 3×」写成单测硬门禁，共享构建机负载高时属于假失败源（文件注释自己也承认只在 release 实测过 36×）。
- **建议**：统一用 `MonoTime.now()`；把 3× 门禁移到 `cjpm bench` 或加环境变量开关（默认只打印不失败）。

### [轻微] 测试内的死局部变量与无意义重复谓词

- **位置**：`f_jit/src/JitClosureLifecycle_test.cj:172`（`let box = ArrayList<JitFunction>()`）、`:180`（只 `add`，全用例无读取）；`:197`、`:199`、`:203`（`x.isClosed() && x.isClosed()` 同一谓词连写两次）
- **来源**：存量
- **判据**：checklist §1（读了不用）、§2（无差异重复）
- **证据**：静态确定
- **描述**：`box` 是从另一个用例（`:111-120`）复制过来的残留；`isClosed() && isClosed()` 让 `wrapperStatePredicatesAgree` 的「状态谓词一致」看起来在比较两个来源，实际只有一个来源。
- **建议**：删除 `box`；重复谓词改为对「自释放」与「级联释放」两条真实不同路径各取一次。

### [轻微] `HOST_EXCEPTION`(21) 的异常旁路分支无任何用例覆盖

- **位置**：`f_jit/src/JitReport.cj:43-53`（`exceptionOf` + `takeCause` 分支）对照 `f_jit/src/JitReport_test.cj:124-154`（1–23 逐码用例）
- **来源**：存量
- **判据**：checklist §10（异常路径未覆盖）；`fullPositiveCodeRangeMapsToJitException` 走 21 时没有 `HostFault` 记录，只覆盖了「无 cause」的退化分支
- **证据**：静态确定（用例未构造 `HostFault.record` + 未断言 `cause.isSome()`）
- **描述**：`throwJit` 里唯一「打印栈 + 通过 cause 带出原文」的分支恰好没有被测；该分支正是 M2 桥接最易回归的地方（异常类型、`cause` 是否被取走、重复打印）。
- **建议**：补一条用例：先 `HostFault.record(ctx, ex)` 再以 21 收尾，断言 `e.cause.isSome()`、`takeCause` 只生效一次。

## 优化可行性方案

> 以下均不是缺陷；无改前/改后对照数据的项只作为下一轮补数据的方向。

### [CPU] `callForFn` 每次调用重新解析 `Fn` 的类型名

- **现状**：`callForFn` 每次执行 `TypeInfo.of<Fn>().name`（字符串）+ `parseFnType`（字节扫描 + `ArrayList<UInt8>` + `toArray` + `String.fromUtf8`，`JitFunction.cj:498`、`:795-865`），而 `Fn` 在单态化后是编译期常量，解析结果恒定；返回闭包的循环（每次迭代 `callForFn` + `close`）里这部分是纯重复工作
- **方案**：以 `TypeInfo` 为键缓存 `?JitFnSig`（含 `None` 的负极缓存），挂在 `RuntimeState` 或模块级 `HashMap<TypeInfo, ?JitFnSig>`（键集合 = 程序里出现的闭包类型数，天然有界）
- **预期**：每次 `callForFn` 省 3–4 个临时对象与一次 O(签名长度) 扫描；对含闭包返回的循环有效，对普通 `call` 无影响
- **代价**：多一张有界缓存表；`Fn` 参数化的包装实例仍需在 miss 时解析
- **验证**：`cjpm bench -O2`，场景「JIT 单元每次返回新闭包、循环 1e6 次」，改前/改后各 5 轮取中位数与离散度
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `dropEscaped` 的线性扫描在批量释放时退化为 O(m·n)

- **现状**：`escaped` 是 `ArrayList<EscapedClosure>`，`dropEscaped`（`JitFunction.cj:379-388`）按 `seq` 线性查找并在单元锁内 `remove(at:)`；一个单元持有 n 个在册逃逸闭包时，逐个 `close()` 释放 m 个是 O(m·n)，且每次都在单元 `mtx` 内
- **方案**：加 `seq -> 下标` 的 `HashMap`（或把条目改为 `HashMap<Int64, EscapedClosure>`，`close` 时遍历值集），删除从 O(n) 降到 O(1)
- **预期**：n 较大（数百以上）时 `close` 单次耗时下降；n 小时收益在噪声内
- **代价**：多一份索引，需与 `escaped` 同步维护（`registerEscaped` / `dropEscaped` / `clear` 三处）
- **验证**：构造 n = 1k/10k 在册闭包，测连续 `close()` 的总耗时与 `mtx` 持有时间分布
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] 每次 `call` 的固定分配（cells 数组 + `CallMarshal`）

- **现状**：`callLocked` 每次调用构造 `CallMarshal(rs)`（`JitFunction.cj:595`）与非零实参时的 `Array<Int64>(args.size, repeat: 0)`（`:617-621`）；`JitContext` 已由 `create/free` 池化，cells 与 marshal 没有
- **方案**：按线程复用一块 `Int64` 暂存区（容量 = 最大 nargs，超出则扩容），`CallMarshal` 改为可重置的线程本地对象；前提是确认执行器不把 `cells` 引用存进闭包/提升组（`registerEscaped` 只存 `PromotionGroup`，看起来不持有 cells，但需用执行器侧确认）
- **预期**：每次调用少 1–2 次分配；对高频小实参调用（业务侧表达式求值）有效
- **代价**：DEOPT 重放共用同一块缓冲要求它在一次调用内不被复用；需要 `finally` 归还，语义复杂度上升
- **验证**：`getAllocatedHeapSize()` 前后对照 + 分配计数埋点，同输入 1e6 次调用
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `close(timeoutMs)` 的自旋实际墙钟远超 `timeoutMs`（慢机/高竞争下放大数倍到数十倍） | `f_jit/src/JitFunction.cj:237-253` | 自旋 1e5 次的墙钟耗时、不同 `timeoutMs` 下的实际返回时间 | 注入一个长期在飞调用（`HOST_SRC` + 阻塞回调），测 `close(1/10/100/1000)` 的实际等待时间与 CPU 占用 |
| 2 | `call<T>` 每次调用的 `CallMarshal` + cells 分配是可观测的 GC 压力来源 | `f_jit/src/JitFunction.cj:595-621` | 每秒分配字节数、GC 次数、与调用次数的比例 | 1e6 次 `call<Int64>([n])`，`cjprof heap` + `getAllocatedHeapSize()` 前后差 |
| 3 | `PerfAdapter_test` 的 3× 门禁在共享构建机上会偶发假失败 | `f_jit/src/PerfAdapter_test.cj:102-105` | 同一提交多轮 MR 的 ratio 分布 | 连续跑 20 轮，记录 `applied/typed` 比值的最小值/中位数/P95 |
| 4 | 编译缓存命中已卸载单元的窗口在「编译+卸载」交替负载下可观测 | `f_jit/src/JitFunction.cj:256-265` | 命中旧单元导致 19 的频次 | 两线程循环 `compile(同源)` 与 `close()`，统计 `call` 返回 19 的次数（应接近 0） |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_jit/src/JitClosureId.cj` | .cj | ✅ | 41 行，值类型 + 两个比较运算符；运算符仓内仅测试使用（对外可达，不判死代码） |
| 2 | `f_jit/src/JitClosureId_test.cj` | .cj | ✅ | 构造/拷贝/比较断言，无问题 |
| 3 | `f_jit/src/JitClosureLifecycle_test.cj` | .cj | ✅ | 生命周期与级联释放用例；见轻微（未读 `box`、重复谓词） |
| 4 | `f_jit/src/JitFunction.cj` | .cj | ✅ | 本部分核心，1026 行；见严重 1 条、一般 4 条、轻微 3 条 |
| 5 | `f_jit/src/JitFunctionClosure_test.cj` | .cj | ✅ | 包装调用/错误码对齐；`catchCall(-1)` 用哨兵表示零实参（可读性，未计入） |
| 6 | `f_jit/src/JitFunction_test.cj` | .cj | ✅ | 六步调用 + 卸载状态机用例，无问题 |
| 7 | `f_jit/src/JitHost.cj` | .cj | ✅ | 注册门面；泛型 `F` 仅作类型令牌（注释已说明） |
| 8 | `f_jit/src/JitMemberAccess_test.cj` | .cj | ✅ | `isJitBacked()` 守卫用例，与实现一致 |
| 9 | `f_jit/src/JitReport.cj` | .cj | ✅ | 三态收尾；见轻微（`printStackTrace`）、一般（与 `JitFunction` 的调用契约） |
| 10 | `f_jit/src/JitReport_test.cj` | .cj | ✅ | 1–23/99 逐码用例；21 的异常旁路分支未覆盖（轻微） |
| 11 | `f_jit/src/JitSignature_test.cj` | .cj | ✅ | 宏登记 + 反射回退；用例间共享进程级 `SignatureRegistry`，已用 `resetForTest` 隔离 |
| 12 | `f_jit/src/JsonBridge_test.cj` | .cj | ✅ | JSON 16–19 封送/解包；`unboxJsonReturnEscapes` 名不副实（未跨窗口），未计入统计 |
| 13 | `f_jit/src/LastEscapedScope_test.cj` | .cj | ✅ | 并发写 `lastEscaped` 不污染 `callForFn`，与 H3 注释一致 |
| 14 | `f_jit/src/Lifetime_test.cj` | .cj | ✅ | G1/G4/G6 资源归零用例，覆盖到位 |
| 15 | `f_jit/src/LoopSafepoint_test.cj` | .cj | ✅ | 按需安全点；`loopPerIterCost` 只打印不设门槛（有意），用 `MonoTime`（正例） |
| 16 | `f_jit/src/MarshalRs_test.cj` | .cj | ✅ | 值/String/14 透传与清理，无问题 |
| 17 | `f_jit/src/OverrideBinding_test.cj` | .cj | ✅ | 两处 `catch (_: Exception)` 只看「是否抛」，断言偏宽（未计入） |
| 18 | `f_jit/src/ParallelCall_test.cj` | .cj | ✅ | 并发语义回归网，覆盖错误码/句柄/跨线程关闭，无问题 |
| 19 | `f_jit/src/ParallelThroughput_test.cj` | .cj | ✅ | 只打印 `PAR-BENCH`；墙钟计时见轻微 |
| 20 | `f_jit/src/PerfAdapter_test.cj` | .cj | ✅ | 反射 vs 类型化 adapter；3× 时序门禁见轻微 |

合计：`.cj` 20 个 / `.md` 0 个 / 共 20 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 3 | 正确性 2（`parseFnType` 解析、typecode 表漂移）、可读性 1（注释错位）；设计上 `JitReport` 的三态分派与 `JitFunction` 状态机分层清晰；语言特性无问题（`struct` 值语义、`?T` 均为惯用写法）；安全性仅日志面（`printStackTrace`，已计入轻微） |
| §1 死代码 | 2 | 已逐个 private / internal 符号全仓搜引用：`JitFnSig`、`CallOut`、`DEFAULT_CONTEXT`、`EMPTY_CELLS`、`escapedSeq`、`entryOrFail`、`classAt`/`sigAt`、`dropEscaped` 均有引用；`newEscapedClosure` / `lastPromotionGroup` / `classSnapshotOf` / `isReturnedHandle` 仅测试引用（`internal`，作可见性建议，不判死代码）；命中 2：`callLocked` 的 `options` 死参数、测试内 `box` 未读。`JitHost.private init()` 是防实例化守卫，有语义，不判 |
| §2 重复逻辑 | 2 | 已把 6 个非测试函数体压成「输入→输出→副作用」两两比对：`codeOfTypeName` 与 `computeTypeCode` 同表两写且已漂移（命中）；`closed` 状态查询重复谓词（测试，命中）；`catchCall`/`catchCallAny`、`greetOverride`/`jitOnlyOverride` 差异是业务差异（错误文案、参数个数），不算重复 |
| §3 空实现 | 0 | 无空函数体；`match` 的 `case None => ()` 均为「无可选值」的正常路径（`escaped` 无组、`entry` 无条目时另有显式 `throw`）；`JitReport` 的 `case None => ()` 是「无 cause」退化，不是吞异常 |
| §4 栈溢出 | 0 | 无递归：`parseFnType`/`typeNameOf`/`simpleTypeName` 均为循环实现；打印/比较不递归对象图；JIT 侧递归由机器码栈承担，不在本部分判 |
| §5 OOM | 1 | `escaped` 列表随「返回闭包但宿主不 close」增长，但 README:538 明确「单元存活期间不释放 = 契约」，且 `close` 会 `clear`；已作为契约记录，未升为缺陷。按不可信长度预分配点（`Array<Int64>(args.size)`、`allocateDump(diagMaxLocals)`）均由单元签名/装载期常量限定 |
| §6.1 热点瓶颈 | 0 | 本部分无 profile / bench 数据（`PerfAdapter_test` 只测反射 vs adapter 单点，不代表 `call` 热路径）；`callForFn` 重复解析、`cells` 分配已降级为「待验证假设」 |
| §6.2 大粒度锁 | 1 | `close`/`unloadClosure` 的自旋每轮取 `mtx`，与 `exitUnit` 争用（并入「自旋超时」一般项）；`CompileCache.remove` 在单元锁内调用，但锁序已在 `CompileCache.cj:71-79` 声明为「单元 → 缓存」且反向不存在，不判死锁 |
| §6.3 并发串行 | 0 | 无 `spawn` 后立即 `get()`、无单 writer 热点；`call` 路径已去进程级锁（`ParallelCall_test` 可证） |
| §6.4 低效算法 | 1 | `dropEscaped` 线性扫描（优化方案，无基线）；`escaped` 遍历仅在 `close` 出现一次 |
| §7 降堆内存方案 | 1 | 每调用 cells + `CallMarshal`（无基线，见优化方案） |
| §8 降 CPU 方案 | 2 | `callForFn` 类型名重复解析；`dropEscaped` 索引化 |
| §9 local mode 可行性 | 0 | `docs/LocalMode.md:451` 明示 f_jit「待采样」；本部分函数内临时对象均为短字符串/小数组，无峰值内存证据，收益无法证明 |
| §11 现有代码的 BUG（存量） | 6 | 并发 close 回退（严重）、自旋超时、`parseFnType`、缓存窗口、注释与声明错位、测试墙钟/门禁；本轮读到的 7 个非测试函数（`close`/`closeClosure`/`unloadClosure`/`enter*`/`exit*`/`callLocked`/`callForFn`/`parseFnType`）的边界与空值路径均已核对 |
| §12 并发安全与锁粒度 | 3 | 已列出共享点：`state`/`active`/`escaped`/`cacheKey`/`lastEscaped` 均在 `mtx` 内；装载层 `bind*` 写发生在 `CompileCache.finish` 发布之前，发布/查找同锁，happens-before 成立；唯一无锁写是 `helperTableRef` 的惰性兜底（仅测试直造实例，幂等）。命中 3：回退跨状态竞态、自旋抢锁、缓存窗口 |
| §14 功能完备性与 README 覆盖 | 0 | 本部分无 `.md`；已用 README 作契约对照（`close(timeoutMs)`、`callForFn`、并发调用三点），无「承诺未实现」；`JitHost` 的三条 public API 在 `HostSignature_test` 有端到端用例 |
| 文件覆盖（§13 等） | 20/20 | 无缺失；本部分不含 README/doc，§13 的文档一致性留给含 `.md` 的部分 |

## 模块统计（仅本部分）

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 1 |
| 一般 | 4 |
| 轻微 | 6 |
| 优化方案（堆内存 / CPU） | 1 / 2 |

存量 11 条（全部），是否纳入修复待用户决定。

## 总评

本部分代码整体质量偏高：`JitFunction` 的状态机、句柄窗口记账与三态收尾的设计意图都用注释写清了「为什么」，测试密度也高（并发、生命周期、错误码逐码覆盖都有专门用例），死代码与重复逻辑经机械排查后只剩两处低风险项。

风险集中在**卸载路径的并发性**：

1. `close` 的超时回退是无条件写状态，与「另一个线程已成功 close」交错时可以把已释放的单元恢复成可调用态（严重，崩溃面）；
2. 同一段代码用自旋次数冒充毫秒超时，慢机/高竞争下等待时间不可控且占满一核（一般）；
3. 卸载逐出与缓存查找之间存在「拿到已终结单元」的窗口（一般）。

按「阻塞项」看待第 1 条（崩溃 + 可用性），第 2、3 条建议排期；其余为可读性与测试口径问题。`parseFnType` 的解析缺陷（一般）只影响「返回泛型/高阶闭包」的 `callForFn` 场景，但一旦命中就是必然的契约错误，建议与本轮 typecode 表合并一起修。
