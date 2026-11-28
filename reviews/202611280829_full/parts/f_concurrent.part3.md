# f_concurrent 模块审查报告（第 3/3 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_concurrent`（34 个源文件；本部分覆盖 4 个：`exception/{RateLimiterException, ReadWriteSyncerException, TimeoutException}`、`imports.cj`）
- **基线**：工作区快照 `8c0ce643a`（`sts/1.3.x`，除 `docs/review/`、`reviews/` 外工作区干净，无 diff）⇒ 本部分全部发现记「存量」
- **审查重点**：异常类型设计（基类契约、命名冲突、孤儿类型）、导入完整性（`imports.cj` 包级导入的每条是否被使用、是否缺项）、死代码、重复逻辑、空实现、存量 BUG
- **报告版本**：v1（本部分为模块报告的 `part3`，最终由主 Agent 合并为 `docs/review/f_concurrent_review_20261128.md`）

## 发现

### [一般][存量] `TimeoutException` 与 `std.core.TimeoutException` 同名，且模块内没有任何抛出点

- **位置**：`f_concurrent/src/exception/TimeoutException.cj:20`（`public class TimeoutException <: BaseException`）
- **来源**：存量（`git log --diff-filter=A` → `d3ca87f00` 2024-11-10「增加限流器……还有一些并发相关的异常」创建；此后仅 `4be871f2f` 2026-10-02 换行符统一）
- **判据**：review-checklist §11（语义与命名 / 契约与实现不符）、§10（设计：对外 API 命名）、§14.1（声明了类型但无任何产生路径）
- **证据**：静态确定 —— `std.core` 的 `TimeoutException` 是隐式导入（`cangjie_docs/docs/dev-guide/source_zh_cn/package/import.md:143-145`：「编译器会自动为源码隐式的导入 core 包中所有的 public 修饰的声明」），定义在 `stdlib/libs/std/core/timeout_exception.cj:11`，并由 `std.core.Future.get(timeout)` 抛出（`stdlib/libs/std/core/future.cj:126`）。仓内既有代码捕获的都是 core 版本：`f_pool/src/KeyPool.cj:653`、`f_jsonrpc/src/server/JsonRpcServer.cj:293`、`f_net/src/test/f_net_tcp_test.cj:179`、`fprobe/src/collect/hw/CommandRunner.cj:77`（这四个文件都没有导入本模块的异常包，靠隐式导入解析）。本模块内 `grep "throw TimeoutException"` 命中 **0** 次，`imports.cj` 也没有导入它，即这个类型从定义起从未被使用。
- **描述**：模块对外导出了一个与语言预置类型完全同名、语义也相同（超时）的异常类，自己却从不抛出。下游一旦 `import fountain::f_concurrent.exception.TimeoutException`（或 `import ...exception.*`），就与隐式导入的 `core.TimeoutException` 同名：按 `import.md:219`（「如果没有对导入的存在冲突的名字进行重命名，在 import 语句处不报错；在使用处，会因为无法导入唯一的名字而报错」），使用处会编译失败；若编译器改为让显式导入遮盖 core，则同一文件里 `catch (e: TimeoutException)` 会静默捕获错类型——`Future.get(timeout)` 抛出的 core 版本反而漏捕。两种结果都让这个类型在它的本意用途（捕获超时）上不可用。冲突的编译期具体表现标 `待确认`（本轮按要求不跑构建）。
- **建议**：删除该类型，超时统一用 `std.core.TimeoutException`（`ExecutorFuture.get(timeout)` 当前返回 `None`，与 core 版本不冲突；将来若改成抛出，直接用 core 版本即可）。若确有模块专属语义（如带限流上下文的超时），改名 `ConcurrentTimeoutException` 并在 README 写明与 core 版本的捕获关系。该类型仓内零引用，删除零成本（对外可见性建议仍需用户拍板）。

### [轻微][存量] `ReadWriteSyncerException` 是孤儿类型：全仓无 `ReadWriteSyncer`、无抛出点，README 却把它列为模块异常

- **位置**：`f_concurrent/src/exception/ReadWriteSyncerException.cj:20`；承诺源 `f_concurrent/README.md:353-354`、`f_concurrent/README_en.md:353-354`
- **来源**：存量（`d3ca87f00` 2024-11-10 创建）
- **判据**：review-checklist §14.1（承诺源 + 缺失证据）、§13（文档与实现一致性）、§11（语义与能力不符）
- **证据**：静态确定 —— 全仓（排除 `.worktrees/`、`target/`）`grep -w ReadWriteSyncer` 只命中该定义与 README 两行；没有 `ReadWriteSyncer` 类型、没有 `throw ReadWriteSyncerException`、`imports.cj` 未导入、`grep -rn "f_concurrent.exception"` 显示外部模块只导入了 `LoadBalanceException`（`f_net/src/client/MultiClient.cj:20`、`f_rpc/src/client/ClientConfig.cj:19`）。README 原文：「**异常**（`exception/`）：`ConcurrentException`、`LoadBalanceException`、`RateLimiterException`、`ReadWriteSyncerException`、`TimeoutException`」——把 5 个类型并列为"模块异常"，其中实际有抛出路径的只有 `RateLimiterException`（4 处：`RateLimiter.cj:21`、`SlidingWindowRateLimiter.cj:33`、`TokenBucketRateLimiter.cj:32`、`LeakingBucketRateLimiter.cj:39`）与 `LoadBalanceException`（`LoadBalance.cj:101` 构造、`:109` 抛出）；`ConcurrentException` / `ReadWriteSyncerException` / `TimeoutException` 抛出点均为 0（前者 part2 已记）。
- **描述**：异常类本身对外可达（public 顶层声明），按硬原则一**不算死代码**；问题在于它承载的"读写同步"能力在模块里根本不存在，README 的并列写法会让读者以为模块提供读写同步器。这与本模块"限流器/容器/负载均衡"的实际能力范围不符。
- **建议**：能力已规划未实现 → README 标注"预留、尚未实现"或从异常清单移除并说明；已放弃 → 删类并同步 `README.md` / `README_en.md`（删除对外 public 类型属契约变更，需用户确认无下游依赖）。

### [轻微][存量] `imports.cj:22` 导入 `std.process.Process`，整个包零使用

- **位置**：`f_concurrent/src/imports.cj:22`
- **来源**：存量（`git log --diff-filter=A` → `8f93b4e11` 2025-05-02「跟随版本修改」）
- **判据**：review-checklist §1（未使用的 import）
- **证据**：静态确定 —— 在 `f_concurrent/src` 全目录 `grep -w Process` 只命中该 import 行；`eventbus/EventBus.cj:19` 用的是 `std.runtime.getProcessorCount`，与 `std.process.Process` 无关。`std.process.Process` 确实存在（`stdlib/libs/std/process/current_process.cj:38` 的 `CurrentProcess <: Process`），所以这是"能导入但没用到"，不是无效导入。
- **描述**：`imports.cj` 用的是 `internal import`，按 `import.md:294` 其内容对当前包**及全部子包**可见，等于把 `Process` 暴露给 `f_concurrent` / `f_concurrent.eventbus` / `f_concurrent.exception` 的所有文件，而没有任何文件使用。编译日志也印证这类包级导入不在 `-Wunused` 覆盖范围内：`f_concurrent/target/release/.build-logs/f_concurrent@fountain/f_concurrent@fountain.aarch64-unknown-linux-gnu..errlog` 共 7 条告警，没有一条指向 `imports.cj`（`MapEntryView` 只在文件私有的 `ConcDict.cj:18` 被点名）。
- **建议**：删除该行。另建议给 `std.sync.*` / `std.env.*` / `fountain::f_base.*` / `fountain::f_collection.*` 四个通配导入各加一行注释，写明"服务哪些未自带 import 的文件"（现状是 `RateLimiter.cj` / `DelayQueue.cj` / `LeakingBucketRateLimiter.cj` / `SlidingWindowRateLimiter.cj` / `SyncPriorityQueue.cj` 依赖它，而 `LoadBalance.cj` / `ConcurrentSkipListMap.cj` 自带 import），否则下次清理符号时同样查不出残留。与之相关的是 part1 已记的 `ConcDict.cj:18` 未使用 `MapEntryView`：本文件那份仍被 `ConcHashDict.cj:217` 使用，属"同一符号两处导入、其中一份冗余"，不重复计入。

### [轻微][存量] 异常类 4 个构造器在 6 个类型上逐字节复制（与前两部分同根因，合并后只保留一条）

- **位置**：本部分 `exception/RateLimiterException.cj:20-32`、`exception/ReadWriteSyncerException.cj:20-32`、`exception/TimeoutException.cj:20-32`；同形另有 `exception/ConcurrentException.cj:20-32`、`exception/LoadBalanceException.cj:20-32`、`eventbus/exception/EventBusException.cj:20-32`（part1 / part2 已列）
- **来源**：存量（同一创建提交 `d3ca87f00` / `4be871f2f`）
- **判据**：review-checklist §2（只改类型名）
- **证据**：静态确定 —— 除类名外四个构造器（`init()` / `init(String)` / `init(Exception)` / `init(String, Exception)`）逐行相同；基类 `f_base/src/BaseException.cj:44-57` 已提供同样 4 个构造器，但仓颉**构造函数不继承**，子类只能重写。
- **描述**：这属于语言约束造成的强制重复，不是可抽取的重复逻辑（泛型化会让 `catch (e: RateLimiterException)` 这类按类型捕获失效，宏化只为一个 4 行模板引入编译期复杂度，均不建议）。真实成本是"给异常加字段（如错误码）要同步改 6 个文件"。
- **建议**：保留现状；在 `exception/` 目录或 README 补一句"异常类统一沿用 4 构造器模板，改动需同步 6 个文件"。本条目与 part2「四个异常类同形」合并，不重复计入统计。

## 优化可行性方案

本部分无。4 个文件全是声明式样板（3 个无状态异常类 + 1 个包级导入汇总文件）：没有循环、没有分配热点、没有锁、没有常驻集合，`§7` / `§8` / `§9` 均无可用改动面，也不存在可量化的优化对象。

## 待验证假设

（无）—— 本部分不含执行路径，没有性能假设可提；`scope.md`「已有性能资料」为空，也不具备任何 profile 依据。

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_concurrent/src/exception/RateLimiterException.cj` | .cj | ✅ | 32 行；4 构造器，仅 `message` 版本被 4 处限流器使用（`RateLimiter.cj:21` 等）；类名无冲突 |
| 2 | `f_concurrent/src/exception/ReadWriteSyncerException.cj` | .cj | ✅ | 32 行；孤儿类型（见轻微项）；README 列为模块异常 |
| 3 | `f_concurrent/src/exception/TimeoutException.cj` | .cj | ✅ | 32 行；与 `std.core.TimeoutException` 同名、零抛出（见一般项） |
| 4 | `f_concurrent/src/imports.cj` | .cj | ✅ | 28 行；`internal import` 包级导入 12 条，11 条有使用、`std.process.Process` 无使用 |

合计：`.cj` 4 个 / `.md` 0 个 / 共 4 个，全部读完。本部分不含模块 `README.md` / `README_en.md` / `doc/**`（不在本部分 4 个文件内，§13 的逐项文档比对由合并后的模块报告统一完成）；为取证据另读了 `f_concurrent/README.md:353-355`、`README_en.md:353-355`、`f_base/src/BaseException.cj`、`f_exception/src/imports.cj`、`f_concurrent/cjpm.toml`、`stdlib` 的 `core/timeout_exception.cj` / `core/future.cj` / `process/current_process.cj`、`cangjie_docs/.../package/import.md`，以及 `f_concurrent/target/release/.build-logs` 的编译告警，均只作证据，不计入覆盖统计。模块总数核对：15（part1）+ 15（part2）+ 4（本部分）= 34，与 `modules.md` 一致。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 2 | 正确性 1（`TimeoutException` 与 core 同名 → 下游无法唯一解析，模块内零抛出）；设计 1（`imports.cj` 作为"包级导入源"只覆盖部分文件，`LoadBalance.cj` / `ConcurrentSkipListMap.cj` 又各自 import，职责不统一）；语言特性上 4 个类均为无状态 `public class`，无值/引用语义坑；无外部输入、无凭据、无注入面，安全性不适用；可读性未见问题（文件均为 30 行模板） |
| §1 死代码 | 1 | ①`imports.cj:22` `std.process.Process` 全包零引用（`grep -w Process` 仅命中定义行）；其余 11 条导入逐个溯源到使用点：`Mutex/Condition/Timer/SyncCounter/AtomicOptionReference/AtomicInt64`（`DelayQueue.cj` / 限流器）、`Set/ReadOnlySet`（`ConcurrentHashSet.cj:73,78`）、`ArrayList`（`ConcurrentSkipListMap_conc_test.cj:29` 等）、`MapEntryView`（`ConcHashDict.cj:217`）、`Queue`（`DelayQueue.cj:30`、`SyncPriorityQueue.cj:18`）、`atExit/Console`（限流器）、`TypeInfo`（`Constants.cj:23`）、`MonoTime`（`LeakingBucketRateLimiter.cj:22`）、`f_base.OverSizePolicy/DiscardOverSizePolicy`（`SyncPriorityQueue.cj:24`）、`f_collection.PriorityQueue`（`SyncPriorityQueue.cj:20`）、`RateLimiterException`（4 处 throw）、`TypeNotMatchException`（`Constants.cj:26`）。三个异常类对外可达（public 顶层），按硬原则一**不判死代码**，只记"仓内引用：`ReadWriteSyncerException`/`TimeoutException` 0 次、`RateLimiterException` 4 次"。无 `return/throw/break/continue` 之后的同层语句，无恒真分支，无读了不用的局部变量 |
| §2 重复逻辑 | 1 | 6 个异常类 4 构造器逐字节同形（本部分 3 个 + `ConcurrentException` / `LoadBalanceException` / `EventBusException`）；判为**语言约束下的强制重复**（构造函数不继承），不建议泛型/宏化，只提注释与同步改动点。已两两比对 4 个文件的全部函数体（共 12 个构造器），无其他同语义实现 |
| §3 空实现 | 0 | 三个 `public init() {}` 是转调 `BaseException.init()` 的默认构造（`BaseException.cj:47` 同样为空），不承诺任何行为，非缺陷；无 `TODO`/`FIXME`/`UnsupportedException`，无 `catch {}`，无接口默认空实现 |
| §4 栈溢出 | 0 | 4 个文件无函数调用、无递归、无自引用结构 |
| §5 OOM | 0 | 无容器、无预分配、无缓存、无静态可变集合（异常类零字段），无长期持有路径 |
| §6.1 热点瓶颈 | 0 | 4 个文件无执行路径（只有类型声明与 import），`scope.md` 未提供任何 profile / bench 数据，热点不成立，无需列入待验证假设 |
| §6.2 大粒度锁 | 0 | 无锁、无同步块 |
| §6.3 并发串行 | 0 | 无线程、无 `spawn`、无 `get()` |
| §6.4 低效算法 | 0 | 无算法（无循环、无查找） |
| §7 降堆内存方案 | 0 | 异常类无字段、无静态成员；`imports.cj` 不产生运行期对象，无堆占用可降 |
| §8 降 CPU 方案 | 0 | 无执行代码可优化 |
| §9 local mode 可行性 | 0 | 无函数内临时对象；异常对象只在抛出点分配且必须逃逸到 catch 方，不满足 local region 约束 |
| §11 现有代码的 BUG（存量） | 3 | 本部分 3 条代码侧存量问题（同名冲突、孤儿类型、未使用导入）；已逐项核对：4 个构造器的 `super(...)` 转发与 `BaseException`（`message` / `causedBy` / `suppressed` / `toString`）契约一致、异常类均无 `override` 需求、导入完整性用"符号 → 使用点"逐条溯源（含 4 处外部调用点的解析来源）、README 异常清单与抛出点逐项对照。源头上均属存量（快照无 diff，`git blame` 指向 `d3ca87f00` / `8f93b4e11` / `4be871f2f`） |
| §12 并发安全与锁粒度 | 0 | 无共享可变状态：三个异常类无字段；`BaseException.suppressed_`（`ArrayList`，非线程安全）位于 `f_base`，不在本部分范围，且本模块从不构造共享异常实例跨线程传递。不存在锁对象、发布逸出、可见性问题 |
| §14 功能完备性与 README 覆盖 | 1 | README:353-354 把 `ReadWriteSyncerException` 列为模块异常，但无 `ReadWriteSyncer` 实现、零抛出（双证见轻微项）；README 未遗漏任何本部分 public 符号（`RateLimiterException` / `TimeoutException` 均在清单内），中英文清单一致（`README_en.md:353-354`） |
| 文件覆盖（§13 等） | 4/4 | 4 个文件全部读完（见文件覆盖表）；模块 `README.md` / `README_en.md` / `doc/**` 不在本部分的 4 个文件内，只作证据引用，§13 全量文档比对留给合并后的模块报告 |

## 模块统计（第 3/3 部分）

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 1 |
| 轻微 | 3 |
| 优化方案（堆内存 / CPU） | 0 / 0 |

存量缺陷 4 条（0 严重 / 1 一般 / 3 轻微），是否纳入修复待用户决定；本部分无优化方案与待验证假设。

## 总评

这 4 个文件是模块的"声明层尾巴"：三个异常类 + 一个包级导入汇总，体量小、无并发与生命周期问题，不存在栈溢出 / OOM / 锁 / 性能面。真正值得处理的只有两类问题：

1. **异常类型清单与实现脱节**。模块对外导出 5 个异常，只有 `RateLimiterException`（4 处）和 `LoadBalanceException`（1 处）有抛出路径；`TimeoutException` 与语言预置的 `std.core.TimeoutException` **完全同名**却从不抛出——下游一旦导入就与隐式 core 名冲突（要么使用处编译失败，要么 `catch` 捕错类型），这是本部分唯一建议排期的一项，修法就是删掉、统一用 core 版本（零引用，零风险）。`ReadWriteSyncerException` 则指向一个全仓不存在的 `ReadWriteSyncer` 能力，属文档误导，建议连同 README 清单一起清理或标注"预留"。
2. **`imports.cj` 的包级导入有一处残留**（`std.process.Process`），且因为 `internal import` 不受 `-Wunused` 检查，这类残留只能靠人工核对；建议顺手删掉，并给四个通配导入补"服务哪些文件"的注释，降低后续清理时的漏检成本。

异常类的 4 构造器复制是仓颉"构造函数不继承"的必然结果，不建议为它引入泛型或宏；本部分无阻塞项，整体代码质量良好，问题集中在对外 API 的命名与文档准确性上。
