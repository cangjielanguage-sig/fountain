# f_base 模块审查报告（第 4/4 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_base`（全模块 52 个源文件；**本部分覆盖 7 个**：`native.cj`、`nextPowerOf2.cj`、`public_std_imports.cj`、`resource.cj`、`signal.cj`、`unsafeZeroValue.cj`、`zero_timer.cj`，共 319 行）
- **基线**：工作区快照（`git log -1` = `8c0ce643a` 2026-11-28 合并提交；`git status` 仅多出本轮 `reviews/`、`docs/review/` 未跟踪；快照模式无 diff，本部分发现**全部记为「存量」**）
- **审查重点**：native / 资源 / 信号 / 零值 / 定时器等底层实现、死代码、重复逻辑、空实现、栈溢出、OOM、存量 BUG、并发安全与锁粒度
- **报告版本**：v1（`f_base` 模块 4 个子轮中的第 4 部分，待主 Agent 合并为 `docs/review/f_base_review_20261128.md`）
- **说明**：本文件统计**只含第 4/4 部分**，合并时不要与其余三部分的数字直接相加覆盖。

## 发现

### [严重][存量] `ExitCallbacks.onExit` 无异常隔离：任一清理回调抛异常即中断后续清理，异常还会抛穿 `@C` 信号处理函数

- **位置**：`f_base/src/signal.cj:60-68`（`onExit` 的 `for` 循环内 `atexit()` 无 `try`）、调用点 `:42-46`
- **来源**：存量（`git blame -L 60,68` → `562abf068b` / `28d2e75be3` 2026-08-07，最初在 `f_app/src/signal.cj`，后随文件迁入 `f_base`；`4be871f2f` 仅换行符）
- **判据**：review-checklist §11（错误处理缺失 / 静默中断）、§3（异常被吞或穿透）
- **证据**：静态确定 —— `onExit` 两个 `for` 里直接 `atexit()`，没有任何 `catch`。std 侧同样不兜底：`cangjie_runtime/stdlib/libs/std/runtime/runtime_signal.cj:113-129` 的 `signalHandler` 是 `@C` 函数，`for (fn in slot) { let result = fn(sig) ... }` 也没有 `try`。而 `signal.cj:44` 的 `exit(0)` 在 `std.env` 中签名为 `func exit(code: Int64): Nothing`（`stdlib/libs/std/env/env.cj:154`），即 `:45` 的 `false` 是**不可达语句**（§1 死代码，计入本部分的死代码命中）。
- **描述**：触发条件是一次正常下线（SIGTERM / Ctrl-C）中，某个模块通过 `ExitCallbacks.atExit` 注册的回调抛异常（下游是 DB 关闭、日志 flush、池关停这类可能失败的清理）。后果按顺序：
  1. 后续优先级的回调**全部不执行**（`f_log` 的队列排空、`f_orm` 的连接释放等被跳过）——典型的数据丢失面；
  2. 异常从 `onExit` 传回 `f_base` 注册的 `() -> Bool` 处理器，再穿过 std 的 `@C` 信号分发函数，`exit(0)` 不会执行，进程以异常路径而非受控路径终止。

  现有 `f_bean` 的 `shutdown`（`f_bean/src/BeanFactory.cj:47` 注册）就是没有自兜底的实现，`docs/review/f_bean_review_20261128.md:43` 已记录同类风险，本函数是它唯一的上游保护层而该保护层缺失。
- **建议**：`onExit` 内对每个回调单独 `try { atexit() } catch (e: Exception) { 记录到 stderr }`，保证「一个失败不影响其余」；同时删掉 `:45` 不可达的 `false`（`exit(0)` 后无需返回值），或把 `false` 改成「回调全部成功才 `exit(0)`，否则 `exit(70)`」并让 `exit` 之后的返回值不存在。

### [一般][存量] `onExit` 在持有 `ExitCallbacks.mutex` 的临界区内执行全部用户回调：临界区无界，并与 std 信号锁构成反向锁序

- **位置**：`f_base/src/signal.cj:61-67`（`synchronized(mutex)` 包住整个回调循环）；锁与表定义 `:37-38`
- **来源**：存量（`git blame -L 61,67` → `91978212cc` 2026-09-01；`onExit` 骨架见 `562abf068b`）
- **判据**：review-checklist §6.2（锁内做用户代码）、§12.2（临界区只保护不变量）、§12.1（多锁顺序）
- **证据**：静态确定 —— 临界区包含全部 `atexit()`，时长由回调决定（含 DB/日志/IO），无上界；`Mutex` 在仓颉中可重入（`stdlib/libs/std/sync/mutex_cjnative.cj:17-40` 注释 "Support reentrant"），故**同线程**回调里再 `atExit` 不会自锁，但跨线程锁序成立：
  - 信号线程：std `mtx`（`runtime_signal.cj:120`，包住用户 handler）→ `ExitCallbacks.mutex`（`onExit`）；
  - 清理线程：`ExitCallbacks.mutex` → 回调内若调 `registerSignalHandler` / `resetSignalHandler` 则取 std `mtx`。
  两条路径顺序相反，同时成立即死锁（触发条件：某个清理回调里注册/复位信号处理器，例如模块下线时撤销自己的 handler）。
- **描述**：即使不发生死锁，`atExit` 注册路径在关机期间也被所有回调的总耗时串行阻塞；`f_cache`（`HeapCache.cj:65`）、`f_pool` 等注册的回调里确实包含 `close()` 这类会等待内部线程退出的动作，会把其它线程的注册/退出流程一起拖住。
- **建议**：先在锁内把回调**快照**成 `Array<() -> Unit>`（按 `TreeMap` 升序 + 列表注册序展开），释放锁后再逐个执行；这样临界区只剩 O(n) 拷贝，也消除上述反向锁序。快照语义需写进 README（「执行期间新注册的回调本轮不执行」）。

### [一般][存量] `atExit` 只增不减且强持有闭包：按实例注册的清理项与进程同寿，下游只能靠 `WeakRef` 自救

- **位置**：`f_base/src/signal.cj:36-59`（`private static let callbacks = TreeMap<UInt16, ArrayList<() -> Unit>>()`，仅 `atExit` 追加，无 `remove` / 清空）
- **来源**：存量（`git blame -L 36,38` → `91978212cc` 2026-09-01）
- **判据**：review-checklist §5（无界容器 / 长期持有）、§7（缩短生命周期）、§12.1（共享可变状态）
- **证据**：静态确定 —— 整个 `ExitCallbacks` 只有 `toExitGracefully` / `atExit` / 私有 `onExit` 三个成员，没有注销入口；`callbacks` 是进程级静态表，`ArrayList<() -> Unit>` 里的闭包被强引用直到进程结束。下游已出现规避代码：`f_cache/src/HeapCache.cj:62-65` 注释明写「注册项只捕弱引用，避免 f_base 的全局注册表把实例钉住」，`f_pool` 的 `POOL-13` 同样改为弱引用（`.autocode/bugs/bug-pool-archived-20261006.md:496-519`）。
- **描述**：按「每个对象构造时注册一次」的用法（缓存、连接池、日志 facade 都是这样），注册表条目数随实例创建次数单调增长；闭包捕获的实例在 `close()` 之后仍不可回收。`f_base` 把「必须自己用弱引用」这一约束留给了每个调用方，任何新模块漏写就是一次常驻泄漏。
- **建议**：`atExit` 返回一个注销句柄（如 `ExitCallbackHandle`，内部持 `priority` + 唯一 id），提供 `remove(handle)`；或在文档与类型层面强制弱引用语义（例如 `atExit(priority, WeakRef` 版本）。保留现状时至少要：`atExit` 的 KDoc 与 README 写明「注册表无注销、闭包会被强持有到进程结束」，避免继续被当成普通注册表使用。

### [一般][存量] Windows 分支 `atExit` / `toExitGracefully` 为空实现且无注释，与 POSIX 行为静默不同

- **位置**：`f_base/src/signal.cj:70-74`（`@When[os == "Windows"] public struct ExitCallbacks { ... {} ... }`）；同类空桩还有 `:109-125` 的 `registerSignalHandler` / `resetAndRegisterSignalHandler` / `resetSignalHandler`
- **来源**：存量（`git blame -L 70,74` → `3a350f62f` / `1677ac48a` / `39d7cccce`，2026-09 为 Windows 补编译）
- **判据**：review-checklist §3（有意的 Null Object 必须有注释说明为什么可以空）、§11（契约与实现不符）、§14（跨平台能力差异未声明）
- **证据**：静态确定 —— Windows 分支两个方法都是 `{}`，文件内没有任何注释解释；而 POSIX 分支是「登记 → 信号触发 → 按权重执行」。下游把它当唯一销毁路径：`f_bean/src/BeanFactory.cj:47` 只通过 `ExitCallbacks.atExit(253, this.shutdown)` 注册 `shutdown`，全包无第二条 `doDestroy` 调用点（已由 `docs/review/f_bean_review_20261128.md:29-36` 取证）。
- **描述**：Windows 上 bean 的 `destroy`/`close`、池的关停、日志的排空都不会执行，且不报错、不告警，属于静默能力缺失。`f_dbd/doc/spec/.../design.md:109` 已把「`ExitCallbacks` 在 Windows 为空实现」写成规格，但 `f_base` 自身的 README（`:735-745`）没有这句，使用者按 README 用会踩空。
- **建议**：Windows 分支用 `std.env.atExit`（仓颉 std 在 Windows 可用）承接 `atExit` 注册表，使语义对齐；若确定不做，至少在结构体与 README 上标注「Windows 无优雅退出，注册项永不执行」，并让 `f_bean` 等模块在 Windows 走显式关闭。

### [一般][存量] `MEM_PAGE_SIZE` 在非 Linux 平台固定 4096，macOS arm64 实际 16 KiB，`msync` 偏移因此不对齐

- **位置**：`f_base/src/native.cj:28-31`（`@When[os != "Linux"] public let MEM_PAGE_SIZE: Int64 = 4096`）
- **来源**：存量（`git blame -L 28,31` → `a927b5937`「添加 Linux 系统内存页大小获取功能」，2026 早期；`4be871f2f` 换行）
- **判据**：review-checklist §11（边界 / 平台常量错误）、§13（注释与实现不符）
- **证据**：静态确定（代码侧）+ 平台事实 —— 注释写「当前系统内存页大小」，但只有 `os == "Linux"` 调 `getpagesize()`，其余平台一律 4096；Apple Silicon macOS 的 `getpagesize()` 返回 16384，`getpagesize` 本身在 macOS / 各 POSIX 平台都可用。下游把它当页对齐基准：`f_io/src/MMapFile.cj:154-155` 用 `(dirtyStart / MEM_PAGE_SIZE) * MEM_PAGE_SIZE` 算 `msync` 起始地址，而 POSIX 要求 `msync` 的 `addr` 按**真实页大小**对齐。
- **描述**：macOS arm64 上 `dirtyStart` 不是 16384 的倍数时，`syncStart` 只是 4096 对齐，`msync` 返回 `EINVAL`；`MMapFile.sync` 未检查返回值（范围外提示：`f_io/src/MMapFile.cj:155` 丢弃了 `msync` 的返回），于是**同步失败被静默忽略**，映射文件数据可能不落盘。Linux / OpenHarmony（4 KiB）不受影响，Windows 不适用。
- **建议**：把 `getpagesize` 的声明与 `MEM_PAGE_SIZE` 的取值放宽到 `@When[os != "Windows"]`（macOS 同样有该符号），或改用 `sysconf(_SC_PAGESIZE)`；`@When[os == "Windows"]` 再保留 4096 常量。README 需注明各平台来源。

### [一般][存量] `nextPowerOf2` 未校验入参：`n > 2^62` 时 `x + 1` 溢出返回负数，`default ≤ 0` 被静默换成 128

- **位置**：`f_base/src/nextPowerOf2.cj:18-32`（`x |= x >> ...` 之后 `return x + 1`；`:19-21` 的 `default` 分支）
- **来源**：存量（`git blame -L 18,32` → `4be871f2fd` 2026-10-02）
- **判据**：review-checklist §11（边界 / 溢出）、§10（正确性）
- **证据**：静态确定 —— 对 `n = 2^62 + 1`，`x |= x >> 1/2/4/8/16/32` 把低 63 位全部置 1，得 `Int64.MaxValue`，`+1` 回绕成 `Int64.MinValue` 并返回。函数是 `public`（README `:722` 列为公开 API），无任何范围检查。`default` 路径：`n <= 0` 时递归 `nextPowerOf2(default)`，而该递归调用的 `default` 形参重新取默认值 128，故 `nextPowerOf2(0, default: 0)` 返回 128 而不是调用方给的值。
- **描述**：仓内两处调用都传 `concurrencyLevel`：`f_cache/src/ConcHashMap.cj:210-211` 无守卫，`f_cache/src/HeapCache.cj:86-92` 则在调用前判 `> (1 << 62)` 抛 `IllegalArgumentException`——同一份算术，一个调用点显式防了溢出、另一个没防，说明阈值问题是已知的，只是防护写在了调用方而不是函数内。`HeapCache.cj:55-59` 先用 `roundUpToPowerOf2` 收口，所以仓内当前不会触发；但 `nextPowerOf2` 是对外 API，外部按 `concurrencyLevel` 直接调用会拿到负的分段数，随后 `Array(负数)` 抛异常（而不是一个可解释的错误）。`default ≤ 0` 的静默替换则会让「关闭兜底」的配置失效。
- **建议**：函数入口校验：`n > (Int64(1) << 62)` 或 `default <= 0` 时抛 `IllegalArgumentException`（文案与 `HeapCache.cj:88` 对齐）；把 `HeapCache` 的调用前守卫删掉，统一收口到 `nextPowerOf2`。README 补一行「有效范围 `(0, 2^62]`，非正值走 `default`」。

### [一般][存量] 零点公开 API 缺少风险约束：`unsafeZeroValue<T>` 对引用类型返回 null，`ZERO_TIMER` 就是一个不可用的 null `Timer`

- **位置**：`f_base/src/unsafeZeroValue.cj:18-22`（无任何注释说明 T 的约束）、`f_base/src/zero_timer.cj:18-20`（`public let ZERO_TIMER: Timer = unsafeZeroValue<Timer>()`）
- **来源**：存量（`git blame` → `4be871f2fd` 2026-10-02）
- **判据**：review-checklist §11（契约与实现不符 / 空引用）、§14（公开 API 风险未文档化）
- **证据**：静态确定 —— std 的 `zeroValue<T>()` 文档明确写「通过该函数获取到的实例一定要赋值为正常初始化的值再使用，否则将引发程序崩溃」（`stdlib/doc/libs/std/core/core_package_api/core_package_funcs.md:1719-1740`）；`Timer` 是 `public class Timer <: Equatable<Timer> & Hashable`（`stdlib/libs/std/sync/timer.cj:36`），零值即空引用，`cancel()`（`timer.cj:196` 起，读 `isEnabled` 字段）等方法都要求非空接收者。`ZERO_TIMER` 全仓零引用（`grep -rn ZERO_TIMER` 仅命中定义与 README `:506`），README 只贴了代码，没有「不可调用、仅可作占位」的说明。
- **描述**：`ZERO_TIMER` 作为「零 Timer 常量」对外暴露，但它的任何使用方式（`cancel()`、`after` 之外的比较、`hashCode`）都作用在空引用上；`unsafeZeroValue` 本身是别名包装，名字里的 `unsafe` 被「不必使用 unsafe 关键词」的描述弱化，下游已有把 class 零值当真值用的实例（`f_http/src/MultipartFormData.cj:47`、`f_io/src/MMapFile.cj:33`、`f_llm/src/agents/AgentTask.cj:423`），其中 `f_rpc` 的历史段错误根因之一就是零值 `MessageID`（`.autocode/bugs/bug-archived-on-20261004.md:755`）。
- **建议**：`unsafeZeroValue` 的 KDoc 补上「T 必须是有确定零值语义的类型；引用类型得到的是空引用，直接使用会崩溃」，并考虑加 `where T <: CType` 之类的受限重载；`ZERO_TIMER` 若只是为了「与某个 Timer 比较」而存在，应改成 `?Timer` 或直接删除（对外可达，删前需确认下游）；README 同段补风险说明。

### [轻微][存量] `resource()` 与 `ResourceManager.call()` 是同一段 `try/finally close` 的两份实现

- **位置**：`f_base/src/resource.cj:18-24`（顶级函数）、`:31-38`（`ResourceManager.call`）
- **来源**：存量（`git blame -L 18,38` → `4be871f2fd`）
- **判据**：review-checklist §2（同文件内同语义实现）
- **证据**：静态确定 —— 两个函数体逐行对应：「取资源 → 在 `try` 里 `fn(res)` → `finally` 里 `res.close()`」，唯一差别是资源来源（参数 vs 字段）。`call` 里的 `resource.getOrThrow()` 也完全可以换成 `resource(res, fn)`。
- **描述**：两份实现目前行为一致，但 `close` 的调用时机、异常传播策略（`close` 异常覆盖 `fn` 异常、未做 suppressed）将来只要改一处就会漂移。README `:384-392` 把两者的差异定义为「资源来源不同」，没有语义差异，属于可合并的重复。
- **建议**：`call` 改为 `resource(resource.getOrThrow(), fn)`；若要保留两份，至少把 `try/finally` 抽成一个私有辅助，避免 `close` 语义分叉。

### [轻微][存量] `resetAndRegisterSignalHandler` 三个重载各自内联「reset + 注册」，未复用同文件已有的注册重载

- **位置**：`f_base/src/signal.cj:92-95`、`:97-102`、`:104-107`（对照 `:77-89` 的三个 `registerSignalHandler`）
- **来源**：存量（`git blame -L 91,107` → `91978212cc` / `562abf068b`）
- **判据**：review-checklist §2（换控制流的重复逻辑）
- **证据**：静态确定 —— `:97-102` 的 `for(signal in signals){ registerSignalHandler(signal, handler) }` 与 `:81-85` 逐字相同；`:92-95` 的 `resetSignalHandler(signals); registerSignalHandler(signals){_ => handler()}` 与 `:77-79` + reset 的组合相同；`:104-107` 同理。三处都可以退化为「`resetSignalHandler(...)` + 调对应的 `registerSignalHandler` 重载」。
- **描述**：当前三份副本行为一致，但包装闭包 `{_ => handler()}` 的写法有 4 份（`:78`、`:88`、`:94`、`:106`），后续若调整返回 `false` 的语义或去重策略，容易漏改。
- **建议**：`resetAndRegisterSignalHandler` 统一实现为「reset 后转调对应的 `registerSignalHandler` 重载」，把 `{_ => handler()}` 收敛到一处；若担心多一层间接，至少在注释里说明「保持与 register 重载同步」。

### [轻微][存量] `ResourceManager` 的 `Option<R>` 字段在 `init` 后恒为 `Some`，且 `struct` 可复制会带来同一资源被多个副本 `close`

- **位置**：`f_base/src/resource.cj:25-39`（`private var resource = None<R>` + `init` 里直接赋值 + `call` 里 `getOrThrow()`）
- **来源**：存量（`git blame -L 25,39` → `4be871f2fd`）
- **判据**：review-checklist §1（恒真分支）、§10（值 / 引用语义、可读性）
- **证据**：静态确定 —— `resource` 只有 `init` 一处写入（`resource = new()`），构造成功后不可能是 `None`，`call` 的 `getOrThrow()` 的 `None` 分支不可达；`ResourceManager` 是 `struct`，按值复制后两个副本持有同一个 `R` 引用，各自 `call` 一次即对同一资源 `close()` 两次（README `:389-390` 只声明「同一个实例第二次 call 会拿到已关闭的资源」，未覆盖「复制出第二个实例」）。
- **描述**：`Option` 包装没有换来任何状态能力（既不支持重置，也不支持懒初始化），只增加了一层不可达分支；复制语义则把「一次性使用」的错误从「第二次 call」扩大到了「两个变量各 call 一次」，`close` 非幂等时（如 `File`/`InputStream` 之外的资源）会二次关闭。
- **建议**：改成 `private let resource: R`（去掉 `Option` 与 `getOrThrow`）；如果确实需要一次性语义，可加 `closed: Bool` 或在 `call` 末尾置空并让第二次调用抛 `IllegalStateException`，把契约从文档搬到运行时。

### [轻微][存量] 关机窗口内新注册的 `atExit` 永远不会执行，且无「已关机」标记

- **位置**：`f_base/src/signal.cj:48-59`（`atExit` 只登记）与 `:60-68`（`onExit` 执行完即返回，随后 `:44` `exit(0)`）
- **来源**：存量（`git blame` → `91978212cc` / `562abf068b`）
- **判据**：review-checklist §11（检查-然后-写入 / 时序缺口）、§12.1
- **证据**：静态确定 —— `onExit` 迭代 `callbacks` 时持锁，其它线程的 `atExit` 会阻塞到迭代结束；迭代结束后 `onExit` 返回、`exit(0)` 立即终止进程，刚登记进 `TreeMap` 的条目不会再被遍历，也不会有任何提示。
- **描述**：典型触发场景是某个清理回调里间接触发了另一个组件的注册（例如关闭顺序中后者才被创建/初始化）；该组件会以为「已经登记，退出时会收尾」，实际永远不会被调用，属静默丢失。
- **建议**：加 `private static var closed = false`，`onExit` 开始时置位，`atExit` 在 `closed` 时直接执行回调（或抛 `IllegalStateException`），把行为显式化；配合「锁外执行回调」的快照方案，窗口会缩到最小。

## 优化可行性方案

### [CPU] `mcopy` 在小块写入路径上逐次跨 CFFI 边界，可评估按批合并

- **现状**：`mcopy`（`f_base/src/native.cj:40-43`）是对 `memcpy` 的薄封装，已加 `@FastNative`；下游按「每条记录一次」调用（`f_io/src/BytePointerStream.cj:103` 的 `access`、`f_io/src/SegmentedLog.cj:767` 的追加写）。每次调用的固定成本 = 一次 FFI 边界 + `memcpy` 本身（小 size 时以边界成本为主）。
- **方案**：在写入侧把同一批小记录聚合到连续缓冲区后一次 `mcopy`（`SegmentedLog` 按段批量提交），或对固定小 size 用仓颉侧 `Array` 拷贝 + 一次 `mcopy` 替代多次调用。
- **预期**：若单次 FFI 开销在 10~30ns 量级、每批 16 条，理论可省 90% 边界调用；但端到端收益取决于写入频率与 `memcpy` 自身占比，**当前无数据**。
- **代价**：写入延迟上升（需要攒批）、崩溃时丢失未提交批次、`SegmentedLog` 的「写前拒绝超长记录」逻辑需要跟着改。
- **验证**：`cjpm bench -O2` 对照「逐条 mcopy vs 批量 mcopy」，同机器同输入（如 1 KiB 记录 × 100 万条、单线程/4 线程各一组），取中位数与 P95；`cjprof` 确认 `mcopy` 的 self time 占比。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

> 没有性能测试数据支撑，只用于下一轮补数据；不进 `todo.md` / `tasks.md`。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `mcopy` 的 FFI 边界成本在 `SegmentedLog` 追加路径上占比可观 | `f_base/src/native.cj:40`、`f_io/src/SegmentedLog.cj:767` | `mcopy` 的 self time 占比、单次调用次数 | `cjprof record` 跑 100 万条 1 KiB 追加，`cjprof report` 看 `mcopy` 与 `memcpy` 的 self 占比；同场景用分段计时统计调用次数 |
| 2 | 关机时 `onExit` 的总耗时随注册条目线性增长，长尾可能超过容器 `terminationGracePeriod` | `f_base/src/signal.cj:60-68` | 条目数 × 单回调耗时的分布 | 在 `onExit` 前后打点（`MonoTime.now()`），跑真实应用 `kill -15`，统计 P95 退出耗时与条目数 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_base/src/native.cj` | .cj | ✅ | 43 行；见 #5、优化方案、待验证假设 #1 |
| 2 | `f_base/src/nextPowerOf2.cj` | .cj | ✅ | 33 行；见 #6；递归深度 ≤ 3，无栈溢出 |
| 3 | `f_base/src/public_std_imports.cj` | .cj | ✅ | 23 行；5 个 `public import` 均为重导出，无同名冲突证据 |
| 4 | `f_base/src/resource.cj` | .cj | ✅ | 40 行；见 #8、#10 |
| 5 | `f_base/src/signal.cj` | .cj | ✅ | 138 行；见 #1、#2、#3、#4、#9、#11；已对照 std `runtime_signal.cj` / `env.cj` 源码 |
| 6 | `f_base/src/unsafeZeroValue.cj` | .cj | ✅ | 22 行；见 #7；已对照 std `zeroValue` 文档 |
| 7 | `f_base/src/zero_timer.cj` | .cj | ✅ | 20 行；见 #7；`ZERO_TIMER` 全仓零引用（public，按硬原则一不判死代码） |

合计：`.cj` 7 个 / `.md` 0 个 / 共 7 个，全部读完（本部分只分到 `.cj`；模块 README 归其它部分）。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 6 | #1（异常路径）、#5（平台常量）、#6（溢出）、#7（空引用）、#10（值语义）、#11（时序）；安全性无外部输入、无凭据，未命中 |
| §1 死代码 | 1 | 已逐符号机械搜引用：`getpagesize`/`memcpy`/`mcopy`/`MEM_PAGE_SIZE`/`nullptr`（f_io 使用）、`nextPowerOf2`（f_cache ×2）、`unsafeZeroValue`（4 个模块）、`ExitCallbacks`/`registerSignalHandler`/`SIGIOT`/`SIGSEGV`（f_app/f_bean/f_cache/f_pool）、`onExit`（同文件 `:43`）均有调用者；`resource`/`ResourceManager`/`resetAndRegisterSignalHandler`/`ZERO_TIMER` 对外可达且仓内零引用，按硬原则一**不判死代码**，仅记录；唯一命中是 `signal.cj:45` 的 `false`（`exit` 返回 `Nothing`，不可达），已并入 #1 |
| §2 重复逻辑 | 2 | #8（`resource` vs `call`）、#9（三个 reset+register 重载逐字重复）；`native.mcopy` 与 `memcpy` 是包装不重复；`public_std_imports` 无逻辑 |
| §3 空实现 | 1 | #4（Windows `atExit`/`toExitGracefully` 空体、无注释）；`registerSignalHandler` 的 Windows 空桩同属 #4；其余函数均有实体 |
| §4 栈溢出 | 0 | `nextPowerOf2` 的递归最多 2 层（`n<=0` → `nextPowerOf2(default)`，递归调用的 `default` 恒为 128，若仍 ≤0 再进一层即返回 128），不存在无界递归；其余文件无递归、无自引用结构 |
| §5 OOM | 1 | #3（`callbacks` 只增不减、强持有闭包）；本部分无一次性物化、无按不可信长度预分配（`Array` 分配在调用方） |
| §6.1 热点瓶颈 | 0 | scope 未提供 profile / bench，`mcopy` 与 `onExit` 两条线索均无 self time，已降级到「待验证假设」#1/#2，不作缺陷 |
| §6.2 大粒度锁 | 1 | #2（`onExit` 锁内跑全部用户回调） |
| §6.3 并发串行 | 0 | 本部分无 `spawn`、无批处理、无任务提交 |
| §6.4 低效算法 | 0 | `nextPowerOf2` 为 O(1) 位运算；`TreeMap` 注册/遍历 O(log n)/O(n)，注册为启动期一次、非热点；无嵌套循环、无 `remove(at:0)` |
| §7 降堆内存方案 | 0 | 唯一可降项是 `atExit` 注册表，已作为缺陷 #3 报，按「缺陷与优化分开」不重复计入；其余为全局常量与静态结构，无可压缩堆对象 |
| §8 降 CPU 方案 | 1 | 优化方案 [CPU] `mcopy` 批量化；**无基线**，标注待验证，不进修复清单 |
| §9 local mode 可行性 | 0 | 本部分函数内几乎无临时堆对象（`resource`/`call` 零分配、`nextPowerOf2` 零分配、`toExitGracefully` 仅一个 2 元素 `Array`），峰值内存收益无法成立，且无前后峰值数据 |
| §11 现有代码的 BUG（存量） | 9 | 本部分 11 条发现全部为存量（快照无 diff），其中 #1/#5/#6/#7/#10/#11 为逻辑/边界/契约类，#2/#3/#4/#8/#9 为并发/资源/重复类；相关函数边界（`n<=0`、`n=2^62±1`、空 `default`）与空值（零点、`Option`）均已逐个核对 |
| §12 并发安全与锁粒度 | 3 | #2（锁内回调 + 与 std 信号锁反向锁序）、#3（静态表并发读写靠 `mutex` 保护，但生命周期无界）、#11（关机窗口的检查-然后-写入）；共享路径：`ExitCallbacks.callbacks` 为进程级 `static`，经 `f_app`/`f_bean`/`f_cache`/`f_pool` 多模块、多线程访问，同步手段仅 `:37` 的 `Mutex` |
| §14 功能完备性与 README 覆盖 | 1 | #7（`unsafeZeroValue` / `ZERO_TIMER` 的风险未文档化）；其余公开符号（`ExitCallbacks`、`registerSignalHandler` 系列、`resource`、`ResourceManager`、`nextPowerOf2`、`MEM_PAGE_SIZE`/`nullptr`/`mcopy`）在 README 均有条目；#4 的 Windows 差异属承诺与实现不符，已计入 §3；README 本体归其它部分，未在本部分审计 |
| 文件覆盖（§13 等） | 7/7 | 本部分无 `.md`，无文档一致性可审；7 个 `.cj` 全部读完 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 1 |
| 一般 | 6 |
| 轻微 | 4 |
| 优化方案（堆内存 / CPU） | 0 / 1（CPU 项无基线） |

存量 11 条（本部分无本次改动），**是否纳入修复待用户决定**；优化方案与「待验证假设」不进修复清单。

## 总评

这 7 个文件是 `f_base` 的「薄底层」：`native` / `unsafeZeroValue` / `ZERO_TIMER` 提供 unsafe 能力，`signal` 提供进程级退出编排，`resource` 提供 RAII 包装，`nextPowerOf2` 是一个公开位运算工具。代码量小，但**唯一一处进程级共享状态（`ExitCallbacks` 注册表）承担了所有模块的收尾职责**，本部分的风险几乎都集中在这里：清理回调没有异常隔离（严重，一次失败即跳过后续所有清理，且异常会穿出 `@C` 信号处理函数）、执行时持锁且与 std 信号锁可形成反向锁序、注册表无注销且强持有闭包（下游已被迫用 `WeakRef` 绕过）、Windows 上空实现无任何提示。

其余问题属边界与契约层面：`MEM_PAGE_SIZE` 在 macOS 上用了错误常量（若把 macOS arm64 当目标平台，应从「一般」升级为「严重」，因为 `msync` 会静默不同步）、`nextPowerOf2` 缺少上界校验（仓内调用点已各自加守卫，对外 API 仍暴露）、零点 API 把「会崩的零值」当成普通常量对外提供。`resource` / `signal` 的重复实现与 `ResourceManager` 的 `Option`/复制语义属可维护性问题，不影响当前行为。

建议排期：先修 #1（异常隔离，改动小、收益直接），再评估 #2 的「快照后锁外执行」与 #3 的注销接口（两者一起做可以同时解决关机阻塞与常驻泄漏）；#4 / #5 是平台正确性问题，按目标平台决定优先级；其余可作为清理项随下次改动一并处理。
