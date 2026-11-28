# f_aspect 模块审查报告（第 2/2 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_aspect`（模块共 20 个 `.cj` + 2 个 `.md`；本部分 2 个 `.cj`，共 2 个文件）
- **基线**：工作区快照（sts/1.3.x 工作区，无 diff 可比；本部分全部问题来源均为「存量」）
- **审查重点**：切面织入正确性、代理链与递归、死代码、重复逻辑、并发安全、存量 BUG、README 覆盖率 —— 本部分只含 2 个测试文件，落点是「这些用例**是否真的钉住了**上述语义」，而不是重新审一遍实现
- **报告版本**：v1（模块第 2/2 部分；第 1 部分为 `reviews/202611280854_full-repo/parts/f_aspect.part1.md`，由主 Agent 合并；本文件只统计本部分文件）

## 发现

### [一般][存量] 两个测试文件的版权头年份 2025 与文件新建年 2026 不符

- **位置**：`f_aspect/src/test/qualified_func_info_key_test.cj:2`、`f_aspect/src/test/recursion_guard_test.cj:2`
- **来源**：存量 —— 快照模式无基线；`git blame -L 1,3` 显示两份文件各自只有一个提交（`d69d2ce832` / `ba4288006d`，2026-10-05），版权行由该提交同年写入、此后未改
- **判据**：fountain-baseline §3「缺头、头在 `package` 之后、年份与新建年不符，都按『一般』报」
- **证据**：静态确定 —— `git log --diff-filter=A --format=%ad --date=short -- <file>` 得 `2026-10-05`；对照仓内同为 2026 年新增的文件（`f_a2a/src/A2a.cj`、`f_a2a/src/model/A2aJson.cj` 等，新增于 2026-11-10）头写 `Copyright (c) 2026`，说明约定是「版权年 = 文件创建年」
- **描述**：两份文件的头都是 `Copyright (c) 2025`，而内容是 2026-10 的 ASP-L4 / ASP-L8 修复配套用例。同模块另外 8 个测试文件（`arg_prefix_suffix_route_test.cj`、`aspect_args_race_test.cj`、…）也全部是「2026 新建 + 2025 头」，属模块级漂移，本部分只统计这 2 个。
- **建议**：改成 `Copyright (c) 2026`。若团队约定「版权年份固定写项目起始年 2025」，请把该约定写进 `fountain-baseline.md` §3，避免每轮审查重复报同一件事。

### [轻微][存量] `recursion_guard_test` 只验证「切面进入一次」，不验证状态复位，也未覆盖 README 的「A 调 B 不织入」

- **位置**：`f_aspect/src/test/recursion_guard_test.cj:56-63`（`:59` 只调一次 `bean.r(3)`，`:61` 只断言 `entries.size == 1`）；实现 `f_aspect/src/Aspects.cj:112-128`（复位在 `:120-122` 的 `finally { st.state = false }`）；承诺源 `f_aspect/README.md:98-102`、`README_en.md:104-106`
- **来源**：存量（`ba4288006d`，2026-10-05，文件唯一提交）
- **判据**：review-checklist §11（语义与用例注释不符：注释说「改动前后都必须成立」，断言覆盖不到复位路径）；§14.1（README 承诺的两条语义只钉住一条）
- **证据**：静态确定 ——
  1. **复位路径无断言**：若 `finally` 里的 `st.state = false` 被删掉或写错，`r(3)` 的返回值仍是 6、`entries` 里仍只有 1 条 3，本用例照样全绿；而该线程上此后所有切面会永久失效（`Aspects.cj:124-125` 直接 `fn(funcInfo.args)`）。
  2. **A→B 语义无用例**：README `:98-101` 明确写「切点函数 A 的织入方法内部再调用切点函数 B … 内层调用直接执行原函数体，不再执行切面 … 因此 A 调 B 时 B 的切面**不会**执行」。本用例只覆盖自递归：`RecursionTarget` 是 `f_aspect/src/test/*.cj` 里唯一被 `@WeavedBean` 修饰的类（`grep -rn "@WeavedBean" f_aspect/src/test` 共 4 处命中，分属 4 个互不调用的目标类），没有任何用例让一个被织入类去调用另一个被织入类。
- **描述**：这条守卫同时承担两件事——避免递归重复执行切面、避免「切面里再调织入函数」无限递归。前者被钉住了一半（只钉「不重复」，没钉「结束后恢复」），后者完全没被钉住。跨 bean 抑制是最容易被后续改动（例如「让嵌套调用也织入」这种看似合理的调整）破坏的语义，也是最难从失败现象反推的语义：一旦被破坏，切面会在同一请求里重复执行，事务/日志类切面会静默重复提交。
- **建议**：① 在 `:63` 之后补第二次顶层调用：`@Assert(bean.r(1), 1)`、`@Assert(RecursionCountAspect.entries.size, 2)`、`@Assert(RecursionCountAspect.entries[1], 1)`，把 `finally` 复位钉死；② 新增第二个 `@WeavedBean` 目标类（如 `class SecondaryTarget { public func s(): Int64 { 1 } }`）与配套的 `FuncNameRouteRule("s")` 计数切面，在 `RecursionTarget.r` 的 `n <= 0` 分支里调一次 `s()`：断言最外层 `r(3)` 返回后 `s` 的计数为 0，再单独调 `s()` 后计数为 1。

### [轻微][存量] `recursion_guard_test` 的静态可变状态与全局注册没有清理，用例默认「本进程尚未启动 BeanFactory、每条只跑一次」

- **位置**：`f_aspect/src/test/recursion_guard_test.cj:41`（`public static let entries = ArrayList<Int64>()`）、`:44`（`entries.add`）、`:57`（`BeanFactory.instance.register`）、`:38`（注释「不读 args 做判断，无状态、不加锁」）
- **来源**：存量（`ba4288006d`）
- **判据**：review-checklist §12.1（共享可变状态无保护、未声明线程封闭）；§11（注释与实现不符）
- **证据**：静态确定（注册语义）+ 待确认（是否会出现同进程二次执行/启动）——
  1. `entries` 永不 `clear()`，`:61` 的 `size == 1` 依赖「本进程内这条用例只执行一次且没有别的调用者」。`before` 里的 `ArrayList.add` 无任何同步，注释却写「无状态」——实际是跨调用共享的可变静态状态；一旦按 `@Test[parallel]` 并行跑、或有人在同进程里再调一次 `r`，`size` 断言会直接失败且 `ArrayList` 本身不保证安全。
  2. `BeanFactory.instance.register`（`f_bean/src/BeanFactory.cj:142`）→ `doRegister`：`registered.load()` 为真时抛 `BeanException('To register bean to a registered BeanFactory is forbidden')`（`:58-59`），同名重复注册抛 `duplicate bean name`（`:73-74`）。当前 `f_aspect/src/test/*.cj` 里无一处调用 `afterRegistered()`，所以能过；只要后续有人在同包用例里补一次「模拟框架启动」，这条用例就会随执行顺序偶发失败，而失败信息指向 `BeanFactory` 而非本条用例。
- **描述**：测试的可重复性建立在两个未写明的进程级前提上；`entries` 既是对外 `public` 的静态容器（同包其他用例可写），又是唯一断言来源，任何一处污染都会变成「随机红」。
- **建议**：把计数改成 `AtomicInt64`（`enterCount.fetchAdd(1)`）或保留 `entries` 但在用例开头 `entries.clear()`、结尾清理；注释改成「静态计数、单线程使用」；若同包还要加启动模拟，用 `@BeforeAll/@AfterAll` 或把该用例放到独立测试类并注明顺序依赖。

### [轻微][存量] `qualified_func_info_key_test.cj` 注释里的两处引用已失效（文档改名、行号漂移）

- **位置**：`f_aspect/src/test/qualified_func_info_key_test.cj:33`（`bug-aspect.md` §3.2）、`:60`（`PointCut.cj:115`）
- **来源**：存量（`d69d2ce832`，2026-10-05）
- **判据**：review-checklist §11（注释与实现不符）；§13（引用不存在的文档 / 失效路径）
- **证据**：静态确定 ——
  1. 全仓 `grep -rn "bug-aspect.md"`（排除 `.worktrees`）只有这一处命中；`.autocode/bugs/` 下只有 `bug-aspect-archived-20261006.md`。该文件 `:210`「ASP-L8 从本模块待修清单移除」、`:214`「ASP-L8 前提…建议加一条『同一函数多次调用命中同一链』的测试把该假设钉死」，正是本用例的依据。
  2. `f_aspect/src/macros/PointCut.cj:115` 是 `var ord = HashMap<String, Int64>()`（静态元信息命名的序号表），与键构造无关；真正生成 `InvocationFuncInfo` 的是 `:94-95`（静态元信息分支 / 每调用构造分支），生成 `QualifiedFuncInfo` 静态元信息的是 `:220`（`metaTokens`）。
- **描述**：`recursion_guard_test.cj:49-51` 同样引用了「README『嵌套调用与递归（设计）』」，该章节存在但实现描述已过期（`recursiveInvocationFlag` 已不存在，见第 1 部分 #8）——两处引用叠起来的效果是：读者沿着注释去核对时，既找不到 bug 文档，也会被 README 里不存在的符号带偏。
- **建议**：`:33` 改为 `.autocode/bugs/bug-aspect-archived-20261006.md §3.2`；`:60` 改为 `PointCut.cj:94-95,220`；`recursion_guard_test.cj:49-51` 的 README 引用等第 1 部分 #8 修完后再保留（或直接指向 `src/Aspects.cj:112-128`）。

### [轻微][存量] 两个文件都 `import fountain::f_base.*`，但没有任何 f_base 符号被使用

- **位置**：`f_aspect/src/test/qualified_func_info_key_test.cj:22`、`f_aspect/src/test/recursion_guard_test.cj:21`
- **来源**：存量（两份文件均为单次提交，`d69d2ce832` / `ba4288006d`）
- **判据**：review-checklist §1（机制动作 7：未使用的 `import`）
- **证据**：静态确定 —— 两个文件用到的外部符号只有 `TypeInfo`、`QualifiedFuncInfo`、`HashMap`、`ArrayList`、`Int64`、`Aspect`、`InvocationFuncInfo`、`AspectRoute`、`FuncNameRouteRule`、`Aspects`、`@WeavedBean`、`BeanFactory`、`@Test/@TestCase/@Assert`；其中 `TypeInfo` 由 `std.reflect`（qualified `:21`）与 `f_aspect` 的 `public import std.reflect.TypeInfo`（`src/imports.cj:27`）提供，其余分别来自 `fountain::f_aspect.*`、`fountain::f_aspect.macros.*`、`fountain::f_bean.BeanFactory`、`std.collection`。宏展开产物（`PointCut.cj:94-95`、`:220`）只用到 `TypeInfo` / `QualifiedFuncInfo` / `Aspects` / `InvocationFuncInfo`，同样不来自 `f_base`。
- **建议**：删除这两行 import（顺带删掉 `qualified_func_info_key_test.cj:21` 的 `std.reflect.*` 也可——`TypeInfo` 已由 `f_aspect` 的 public import 透出；保留则至少删 `f_base`）。

## 优化可行性方案

> 本部分只有测试代码，没有长期驻留的堆结构、没有可测量的热点路径。无「堆内存」「CPU」方案。

## 待验证假设

> 本部分没有性能测量需求，也没有热点/瓶颈猜测。以下仅登记一个「用例可重复性」的待确认项，不进 `todo.md` / `tasks.md`。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 是否存在「同进程二次执行同一条 `@TestCase`」或「同包用例里有人调用 `BeanFactory.instance.afterRegistered()`」的路径（前者会让 `entries.size == 1` 必然失败，后者会让 `register` 抛 `BeanException`） | `f_aspect/src/test/recursion_guard_test.cj:41,57,61` | CI / IDE 测试运行器的调度方式（是否复用进程、是否并发） | 在 `cjpm test` 与 IDE 单测运行器下各跑一次整包，观察是否重复执行；`grep -rn "afterRegistered" f_aspect/src/test` 定期复查 |

## 文件覆盖

> 与 `{workdir}/files/f_aspect.part2.txt` 一一对应（2 行）。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_aspect/src/test/qualified_func_info_key_test.cj` | .cj | ✅ | 见 #4（`bug-aspect.md` 死引用、`PointCut.cj:115` 行号漂移）、#5（未用 import）、#1（头年份）。4 条用例的前提核对通过：`TypeInfo` / `InstanceFunctionInfo` 均 `<: Equatable & Hashable`（`reflect_package_classes.md:4615`、`:12999`），`TypeInfo.hashCode` 为限定名哈希（同文件 `:14174` 段），`getInstanceFunction` 未命中抛 `InfoNotFoundException`（`:13836` 段），`@Assert(a, b)` 为相等断言（`unittest_samples/unittest_basics.md:144-147`）。后两条用例是前两条在 `HashMap`（`hashCode` + `==`）上的推论，属刻意分层 |
| 2 | `f_aspect/src/test/recursion_guard_test.cj` | .cj | ✅ | 见 #2（复位与 A→B 无断言）、#3（静态状态 + 全局注册无清理、注释「无状态」不符）、#5（未用 import）、#1（头年份）。`r(3)` = 6 的推导与 `Aspects.cj:112-128` 的守卫路径核对一致；`@AspectRoute` 只是 `@Annotation[target: [Type]]`（`AspectRoute.cj:49-50`），不含 `@Bean`，因此用例手工 `register` 是必要且正确的 |

合计：`.cj` 2 个 / `.md` 0 个 / 共 2 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 2 | #2（断言覆盖不足，属正确性保障缺口）、#3（共享状态与注释不符）。两文件均为单线程测试代码、无外部输入、无 SQL/注入面、无凭据与敏感日志，安全性 0 |
| §1 死代码 | 1 | #5（两处未用 import）。机械核对：`KeyProbeBean` / `RecursionTarget` / `RecursionCountAspect` 均在用例内被构造或注册；`@Test` / `@TestCase` 成员由框架反射发现，按误报边界不判；无 `return`/`throw`/`break`/`continue` 后续语句；局部量 `t1`/`t2`/`f1`/`f2`/`k1`/`k2`/`m`/`hit`/`r`/`bean` 全部被读取；`entries` 被 `before` 写入、被断言读取 |
| §2 重复逻辑 | 0 | 两文件共 5 个 `@TestCase` 函数体两两比对：`qualified…` 的 4 条分别是「`TypeInfo` 值稳定」「成员值稳定」「键值稳定」「容器查找命中」，后两条是前两条在 `hashCode` + `==` 上的推论，属刻意分层断言（checklist §2 误报边界：测试准备/分层断言）；与 `recursion…` 的用例无同语义实现 |
| §3 空实现 | 0 | 无空函数体、无 `TODO`/`FIXME`、无 `catch {}`；每条用例至少 1 个有效 `@Assert`；`RecursionCountAspect.before` 有真实副作用（写 `entries`） |
| §4 栈溢出 | 0 | 只有 `RecursionTarget.r` 一处递归，深度由入参决定，用例固定 `n = 3`（`recursion_guard_test.cj:59`），可达深度 4；测试内无自引用结构遍历、无深拷贝 |
| §5 OOM | 0 | `entries` 只增不减，但每次运行仅 1 条 `Int64`；无用例按输入规模物化数组、无 `spawn` 全量提交 |
| §6.1 热点瓶颈 | 0 | 本部分无 `cjprof` / `cjpm bench` 数据；`recursion_guard_test` 不测时间，`qualified…` 只做常量次数的反射调用，热点结论不成立 |
| §6.2 大粒度锁 | 0 | 两文件无锁、无 `synchronized`；相关锁面（`BeanFactory.mutex`）不在本部分 |
| §6.3 并发串行 | 0 | 本部分无 `spawn` / `Future` / `get()`（并发用例 `aspect_args_race_test.cj` 属第 1 部分） |
| §6.4 低效算法 | 0 | 无循环嵌套、无 `contains` 热路径、无重复编译正则；命名字面量无跨文件重复 |
| §7 降堆内存方案 | 0 | 仅 `entries` 与两个探针类，生命周期为整个测试进程、体量可忽略；无可量化收益 |
| §8 降 CPU 方案 | 0 | 无被测热路径（反射调用次数为个位数），优化无意义 |
| §9 local mode 可行性 | 0 | 用例内无「函数内创建、函数内释放」的大临时对象；峰值内存无可测差异 |
| §11 现有代码的 BUG（存量） | 5 | #1 头年份、#2 断言缺口、#3 静态状态与注册、#4 失效引用、#5 未用 import。另以文档核对了 5 处 API 语义（`@Assert` 两种形式、`InstanceFunctionInfo`/`TypeInfo` 的 `Equatable & Hashable`、`TypeInfo.hashCode` 实现、`getInstanceFunction` 抛 `InfoNotFoundException`、`BeanFactory.doRegister` 的两条抛异常路径），未发现断言与实现冲突，也未发现会误报的 `@Assert` 用法 |
| §12 并发安全与锁粒度 | 1 | #3：`entries` 是无同步的静态 `ArrayList`，`before` 在切面线程写、用例线程读；当前单线程不构成竞争，但注释宣称「无状态」、且无 `clear()`，属未声明的共享可变状态。`RecursionTarget` 只被本用例单线程调用，其余无共享路径 |
| §14 功能完备性与 README 覆盖 | 1 | #2：README `:98-101` 承诺的「A 调 B 不织入」无用例；README 与 `src/` 的 public 声明对照属第 1 部分（本部分不含 `.md`，也未新增 public API） |
| 文件覆盖（§13 等） | 2/2 | 2 行全部读完；§13 只涉及测试注释里的引用（#4），未发现示例代码不可用 |

## 模块统计

> 仅统计本部分 2 个文件；模块级统计由主 Agent 合并两部分后得出。

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 1 |
| 轻微 | 4 |
| 优化方案（堆内存 / CPU） | 0 / 0 |

> 存量 5 条（0 条严重），是否纳入修复待用户决定。本部分没有「本次改动」类问题（快照模式无基线）。

## 总评

本部分两个文件是「把结论钉死在用例里」的类型：`qualified_func_info_key_test.cj` 用来排除 ASP-L8（链缓存键不稳定 ⇒ 缓存永不命中、静态表无界增长）这条概率性假设，`recursion_guard_test.cj` 用来守住 ASP-L4（按线程状态对象替代 `ThreadLocal<Bool>`）的语义。两份用例的前提都核对得住——`TypeInfo` / `InstanceFunctionInfo` 确实实现了 `Equatable & Hashable`、`TypeInfo.hashCode` 是限定名哈希、`@Assert` 的相等/布尔两种形式用法正确，`@WeavedBean` + 手工 `register` 的组合也是必要条件（`@AspectRoute` 不含 `@Bean`）。**没有缺陷级问题**，这一部分不需要阻塞。

真正值得注意的是覆盖形状：

- `recursion_guard_test` 只钉住了「进入一次」，没钉「结束后恢复」，也没钉 README 明写的「A 调 B 不织入」。前者是「切面永久失效」的静默故障，后者是「切面重复执行」的静默故障，两者都不会被现有断言发现，而它们恰好是这条守卫存在的理由（第 1 部分 #8 已指出 README 对实现的描述过期，注释又把读者指向那段过期描述）。
- 用例的可重复性依赖两个进程级前提（`BeanFactory` 未启动、`entries` 未被污染），而 `entries` 的注释还宣称「无状态」。这在本仓库大量复用全局 `BeanFactory` 的测试风格下迟早会咬人。
- 第 1 部分报的两条严重问题（链尾固化首个接收者、`TargetAnnotationRouteRule` 读错数据源）在本部分两个用例里也覆盖不到：`recursion_guard_test` 只用一个实例、`qualified…` 只碰键。模块级用例缺口已在第 1 部分的文件覆盖表里记录，这里不重复计数。

**范围外提示**：两个用例都依赖 `std.reflect`，而官方文档对 `TypeInfo` / `InstanceFunctionInfo` / `getInstanceFunction` 均标注「不支持平台：macOS、iOS」（`reflect_package_classes.md:12999` 等），`f_aspect/cjpm.toml` 却声明了 `x86_64-apple-darwin` / `aarch64-apple-darwin` 两个 target —— 这是模块级平台约束，`cjpm.toml` 不在本部分文件清单内，只记一句，不计入统计。
