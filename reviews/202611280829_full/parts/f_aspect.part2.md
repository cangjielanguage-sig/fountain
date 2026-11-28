# f_aspect 模块审查报告（第 2/2 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_aspect`（20 个源文件；本部分 `src/test/` 5 个）
- **基线**：工作区快照（`scope.md`：当前检出 `sts/1.3.x`、未对照远端目标分支；`git status` 仅见未跟踪的 `docs/review/` 与 `reviews/`，被审源码无改动）
- **审查重点**：测试覆盖反向验证（空断言 / 漏断言 / 竞态测试有效性）、死代码、存量 BUG
- **报告版本**：v1（第 2/2 部分，待与 part1 合并为 `docs/review/f_aspect_review_20261128.md`）

> 范围声明：本部分只审任务列出的 5 个测试文件，文中出现的 `src/Aspects.cj`、`src/macros/PointCut.cj`、`src/QualifiedFuncInfo.cj`、`cjpm.toml`、`src/test/` 其余用例均只作取证上下文，不展开审查、不占用本部分统计。
> 编号约定：本部分用 `P2-*` 独立编号，合并时由主 Agent 统一重排。
> 边界提示（供合并裁决，不计入本部分缺陷）：第 1 部分声明「README 归第 2 部分」，但本部分任务清单只含 5 个 `.cj`；`f_aspect/README.md`、`README_en.md` 不在 `modules.md` 的 20 个源文件计数内，两部分均未完整审计（part1 只以 README 行号做契约对照）。合并时需确认是否另派 README 审查。

## 发现

### P2-1 [一般][存量] `pointcut_meta_cost_test` 是「永远绿」的伪基准：唯一断言与所测行为无关，且时钟、优化级别、对照组三处都不满足性能取证要求

- **位置**：`f_aspect/src/test/pointcut_meta_cost_test.cj:48-70`（关键 `55-59` / `61-65` / `67-68` / `69`）；构建配置 `f_aspect/cjpm.toml:11-12`、`29-30`
- **来源**：存量（`git blame` 2026-10-05 `ad8cc477c`「perf(f_aspect): ASP-3 类级织入改用静态元信息」）
- **判据**：review-checklist §11（测试有效性）、§6.1（热点/开销结论的证据要求：函数级定位 + 输入规模 + 对照 + 排除法）；`fountain-baseline.md` §8（基准必须 `-O2`，要绝对值 / 中位数 / 离散程度）；§13（注释与实现不符）
- **证据**：静态确定 ——
  1. 全用例只有一条真实断言 `@Assert(bean.c(7), 7)`（`69`），与耗时无关；`woven` / `plain` 只被 `println` 打印（`67-68`），没有断言、没有阈值、没有失败路径；无论织入开销是 2 ns 还是 2 µs，用例都通过。
  2. 计时用 `DateTime.now()`（`55`、`61`），是墙钟：std 文档明确 `MonoTime` 是单调时间且「常用于性能测试」（`std/time/time_package_api/time_package_structs.md:3101`），`DateTime` 会受系统校时/时区调整影响，且 `toNanoseconds()` 的分辨率不保证。
  3. `cjpm.toml:11-12` 的 `compile-option` 只有 `--dy-std`，`[profile.build]` 只有 `incremental`（`29-30`），测试默认 `-O0` 运行；基准文档要求 `-O2` 前后对照。
  4. 对照组不同构：`bean.c(i)` 是实例方法且经 `Aspects.proceed`（`ThreadLocal.getOrCompute` + `ConcurrentHashMap` 命中 + 空链分支，`Aspects.cj:114-128`、`101-103`），`MetaCostTarget.cStatic(i)` 是静态直调；差值里混着分派方式与三次容器/线程本地访问，无法归因到某一项。
  5. 只跑一轮（无重复、无中位数、无 P95），1e6 次的中途 GC 与预热（仅各 1 次冷调用，`52-53`）都未处理。
  6. 注释声称该用例把「`getInstanceFunction` 与分配成本」量化（`39-44`），但 ASP-3 之后类级织入已在编译期生成 `private static let __pOIntcUt_*`（`PointCut.cj:93-96`、`203-222`），每次调用**不再**经过 `getInstanceFunction`、也不再构造 `QualifiedFuncInfo`；这条测量在生产代码里已无对应路径，注释停留在改造前。
- **描述**：这是本模块唯一自称量化 ASP-3 收益的用例，但产出的是与构建配置、机器、GC 时序强耦合的裸数字，且永远不会失败。若被引用为「改前/改后」证据（part1「优化可行性方案」引用的存量数据 1867–2443 ns/次正是本用例的输出格式），会把 `-O0` 下的解释执行开销当成 AOP 织入开销。
- **建议**：①改用 `MonoTime.now()`；②固定 `-O2` 的独立 bench 入口（`@Bench`/`@Measure` 或单独 `cjpm bench` 目标），或至少在注释里写明「本用例数值不可用于结论」；③对照组换成「同一实例方法但不织入」（同类型加一个 `@Pointcut` 排除/静态元信息关闭的同体方法），消除分派方式差异；④≥5 轮取中位数 + P95，先 `cjprof record/report` 再谈占比；⑤删除或改写 `39-44` 的注释，使其与实际测量对象（空链入口固定开销）一致。

### P2-2 [一般][存量] 测试用切面把结果写进无同步的全局静态 `ArrayList`，且向全局 `BeanFactory` 注册后不注销：既让断言对象漂移到别的函数，也能在两个线程上并发写同一列表

- **位置**：`f_aspect/src/test/pointcut_meta_reuse_test.cj:37`（`public static let metas = ArrayList<QualifiedFuncInfo>()`）、`40`（`metas.add`）、`53`（`register`）、`59-60`（断言）；与 `f_aspect/src/test/aspect_args_race_test.cj:38`（同样匹配函数名 `m`）、`81-93`（两线程并发 `Aspects.proceed`）交叉；缓存与注册语义见 `src/Aspects.cj:51`、`61-68`
- **来源**：存量（`git blame` 2026-10-05 `ad8cc477c`；用例间共享状态与 part1 #14 同源，本条补充「数据竞争」与「断言漂移」两个后果）
- **判据**：review-checklist §11（测试隔离 / 断言与目标不符）、§12.1（共享可变状态无保护）、§1（注册了不注销）
- **证据**：静态确定（结构）+ 需实测（是否真的重叠）——
  1. `metas` 是 `public static let`，用例内不清空、`tearDown` 不清理；`BeanFactory.instance.register` 无对应注销（`f_bean` 侧无卸载入口，part1 #14 已检索）。
  2. `MetaIdentityAspect` 的规则是 `FuncNameRouteRule("m")`，`ArgsRaceAspect` 也是 `m`；同进程内 `RaceTarget.m` 的调用同样进入 `MetaIdentityAspect.before` 并写入 `metas`，且写入的 `qualifiedFuncInfo` 是**链缓存里同一个对象**（`Aspects.cj:60-61`、`95`），因此 `refEq(metas[0], metas[1])` 即使取自 `RaceTarget.m` 也成立。
  3. 于是若 `AspectArgsRace_test` 先执行，本用例的 `metas[0]/metas[1]` 是 `RaceTarget.m` 的元数据，断言仍绿，却没有验证 `MetaReuseTarget.m` 的静态元复用；`size >= 2`（`59`）还允许一条调用写两次（重复织入）通过。
  4. 并发面：若两个切面同时在 `m` 的链上（两侧都已注册，则 `RaceTarget.m` 的链里同时有 `ArgsRaceAspect` 与 `MetaIdentityAspect`，层序由 `BeanFactory` 迭代顺序决定），`ArgsRaceAspect.before` 会在 T1 上阻塞至多 5 s（`aspect_args_race_test.cj:50-53`），T2 在另一线程继续；`metas` 是 `ArrayList`，`add` 无同步 —— 只有 `MetaIdentityAspect` 位于外层时两个 `add` 才可能重叠（`Aspects.cj:63-96`），故标 `需实测`。
- **描述**：这是本部分唯一涉及「多线程共享状态」的路径，且恰好落在审查重点「竞态测试有效性」上：用例自身的断言可能通过，但通过的理由与它声称验证的行为无关；同时测试进程内存在一个未被承认的数据竞争（最坏后果是 `ArrayList` 内部数组损坏、条目丢失、偶发失败，且失败点与真实原因相距很远）。
- **建议**：①每个用例 `beforeEach`/`tearDown` 清空静态容器（或在用例内改用局部收集器，注册一个持有该收集器的切面实例）；②断言收紧为 `metas.size == 2` + `metas[i].typeInfo == TypeInfo.of<MetaReuseTarget>()` + `metas[i].funcInfo.name == 'm'`；③测试用切面里不要用裸 `ArrayList` 收集跨线程数据，改用 `AtomicInt64` 计数或加锁；④给 `Aspects` 提供测试用缓存清理入口（part1 #14 的同一建议），并在用例注释写明「先注册再首调用」的约束。

### P2-3 [一般][存量] `recursion_guard_test` 只覆盖「单线程、只调一次最外层」：守卫不复位、退化为全局标志、切面重入这三种失效都能通过

- **位置**：`f_aspect/src/test/recursion_guard_test.cj:56-63`（断言 `61-62`）；被测逻辑 `src/Aspects.cj:112-129`
- **来源**：存量（`git blame` 2026-10-05 `ba4288006`「perf(f_aspect): ASP-L4 织入状态改按线程对象」+「ASP-L5 默认模板不丢异常」）
- **判据**：review-checklist §11（漏断言）、§12.1（线程封闭只被声明、未被用例验证）
- **证据**：静态确定 ——
  1. 用例只有一次顶层调用 `bean.r(3)`（`59`），断言 `entries.size == 1`、`entries[0] == 3`（`61-62`）。若把 `finally { st.state = false }`（`Aspects.cj:120-122`）删掉，`state` 永久为 `true`：第二次顶层调用仍不织入，本用例照样通过 —— 而这正是「守卫卡死、之后所有调用都跳过切面」的严重退化。
  2. 若把 `ThreadLocal<RecursionState>`（`Aspects.cj:112`）换成 `private static var state = false`：单线程下行为完全相同，本用例仍通过；多线程下会互相屏蔽切面。用例没有任何并发断言，这个改动无法被发现。
  3. 守卫的真实防护目标是「切面里再调用被织入函数 / 递归调用」导致的无限递归（README `f_aspect/README.md:96-99` 的设计说明），但用例只覆盖自递归 `n + r(n-1)`，未覆盖「切面 `around` 里回调同一 bean」这一无限递归入口；`r(3)` 的深度是 4，也不构成对深递归的验证。
- **描述**：`RecursionState` 是「正确性 + 线程安全」双重关键点（part1 §12 依赖它成立线程封闭结论），但唯一用例对「复位」「线程隔离」「重入」三个失效模式全部不敏感，属于典型的「正向路径通过、反向语义未验证」。
- **建议**：①连续两次顶层调用（`bean.r(1)` 再 `bean.r(1)`），断言 `entries.size == 2`，锁死 `finally` 复位；②`spawn` 两个线程各调一次，断言每个线程各进入一次切面（`entries` 总数 2），锁死线程封闭；③新增一个 `around` 内回调目标 bean 的切面，断言不无限递归且内层不织入；④`entries` 每次用例前清空，避免与其它用例的顺序耦合。

### P2-4 [轻微][存量] `qualified_func_info_key_test` 全为正例，缺「不同键必须不相等 / 不命中」的负例；`HashMap` 用例只断言 `isSome`

- **位置**：`f_aspect/src/test/qualified_func_info_key_test.cj:41-75`（关键 `59-65`、`68-75`）
- **来源**：存量（`git blame` 2026-10-05 `d69d2ce83`「test(f_aspect): ASP-L8 前提不成立（键按值稳定）」）
- **判据**：review-checklist §11（断言不完整：只有 `==`，没有 `!=`）
- **证据**：静态确定 —— 4 个用例全部断言「相等」（`t1 == t2`、`f1 == f2`、`k1 == k2`、`hash` 相等、`m.get(...).isSome()`）。若 `QualifiedFuncInfo.==` 恒返回 `true`（`QualifiedFuncInfo.cj:78-80` 的 `refEq || 结构比较` 退化为无条件 `true`），或 `hashCode()` 返回常量（`66` 的 `hash` 计算失效），本文件全部通过；而 `==` 过度宽松会让所有切点函数塌缩到同一条链（不同函数共用一个 `aspects` 条目），是比 ASP-L8 更严重的问题。另外 `m.get(...)` 只断言 `isSome()`（`73`），若返回了别的值（哈希/相等实现错位）也通过。
- **建议**：补 3 条负例 —— 不同 `funcName`、不同 `argTypes`、不同 `typeInfo` 的键分别 `!=` 且 `m.get(...).isNone()`；`testKeyUsedAsMapKeyHitsAcrossCalls` 增加 `@Assert(hit.getOrThrow(), 1)`。不要断言「哈希必不相等」（碰撞合法）。

### P2-5 [轻微][存量] `empty_chain_fastpath_test` 的判据依赖「没有切面匹配 `who`」这一未断言的隐性前提，且注释里的规则集已经过期

- **位置**：`f_aspect/src/test/empty_chain_fastpath_test.cj:32`（注释「现有规则只匹配函数名 n/p/m」）、`41-48`（用例）
- **来源**：存量（`git blame` 2026-10-05 `2c285e93b`「perf(f_aspect): ASP-L7 空链快路径」）
- **判据**：review-checklist §13（注释与实现不符）、§11（测试前提未固定）
- **证据**：静态确定 —— 同包测试注册的规则至少还有 `t`、`u`（`aspect_template_suppress_test.cj:49`、`61`）与 `r`（`recursion_guard_test.cj:39`），注释只列 `n/p/m`；用例本身没有任何「链为空」的观测或守卫。一旦有人新增一条宽匹配规则（如 `FuncTypeRouteRule("**", "*")`）或把某个切面改成匹配全部函数，`b.who()` 会因「链尾固化首实例」返回 1（part1 #4），用例失败，但失败原因与它想验证的「空链在当前接收者上执行」无关，排查成本高。
- **描述**：这是本模块唯一覆盖「空链 + 多实例」的用例，其断言本身是有效的（修前 `b.who()==1` 会失败），但前提靠「恰好没有匹配规则」维持，注释又已经不准，属于可维护性隐患。
- **建议**：①注释改为「本模块测试注册的规则函数名为 n/p/m/t/u/r，均不匹配 `who`」，或在用例开头显式断言 `Aspects` 里该键为空链（需内部可见性入口）；②补一句注释说明「空链按当前接收者、非空链固化首实例」是有意差异（非空链的行为见 part1 #4），避免后来者把它当 bug 修掉或误判。

### P2-6 [轻微][待确认] 4 个用例都用 `new` 创建 `@WeavedBean` 目标，与 `Aspects` 注释「手工 new 出来的实例不在支持范围内」冲突；该限制也未写进 README

- **位置**：`empty_chain_fastpath_test.cj:42`、`44`；`pointcut_meta_cost_test.cj:50`；`pointcut_meta_reuse_test.cj:54`；`recursion_guard_test.cj:58`；契约注释 `src/Aspects.cj:48`
- **来源**：存量（测试与 `Aspects` 注释均为快照现状）
- **判据**：review-checklist §11（契约与实现/用例前提不符）、§14.1（限制未文档化）
- **证据**：静态确定（代码事实）+ 待确认（该限制的真实适用范围）—— `Aspects.cj:48` 写「被织入的对象必须是 IoC 管理的 bean（singleton 或 prototype 均可），手工 new 出来的实例不在支持范围内」，而 5 个测试文件里 4 个手工 `new`（`MetaCostTarget` 亦同）；`README.md` 全文检索「手工 / 手动 / 支持范围」零命中（唯一的「不支持」出现在 `README.md:142`，讲的是「类型全限定名不支持反射尚不支持的类型」，与 IoC bean 限制无关），限制只存在于代码注释。空链修复（ASP-L7）恰恰让手工实例的多实例语义变正确，说明该限制实际只对「非空链固化首实例」成立。
- **建议**：把注释收窄为「非空链的链尾固化首次调用的接收者，因此手工 new 的多实例行为未定义；空链路径按本次接收者执行」，并在 README「并发与线程安全 / 多实例」小节写明；或改用 `BeanFactory` 取实例，使用例与文档口径一致。

### P2-7 [轻微][待确认] 复制粘贴的 import 头里有未使用项（`std.reflect.*` 与 5 处 `fountain::f_base.*`）

- **位置**：`qualified_func_info_key_test.cj:21`（`import std.reflect.*`）；`empty_chain_fastpath_test.cj:20`、`pointcut_meta_cost_test.cj:21`、`pointcut_meta_reuse_test.cj:21`、`qualified_func_info_key_test.cj:22`、`recursion_guard_test.cj:21`（`import fountain::f_base.*`）
- **来源**：存量
- **判据**：review-checklist §1（未使用的 import）
- **证据**：待确认 —— 按符号逐个核对：5 个文件只用到 `@Test`/`@TestCase`/`@Assert`（`std.unittest`）、`InvocationFuncInfo`/`QualifiedFuncInfo`/`Aspects`（`f_aspect`）、`BeanFactory`（`f_bean`）、`@WeavedBean`（`f_aspect.macros`）与 `ArrayList`/`HashMap`（`std.collection`），没有 `f_base` 的符号；`TypeInfo` 已由 `f_aspect` 的 `public import std.reflect.*`（`AspectRoute.cj:18`）转出——同包 `aspect_args_race_test.cj:22-23` 在无 `std.reflect` import 的情况下就使用了 `TypeInfo.of`，可作旁证。未编译验证，故标待确认。
- **建议**：删除后编译确认；若 `f_base` 是为宏展开隐式需要，则在 import 行加注释说明用途，避免下一轮重复误报。

## 优化可行性方案

> 本部分为测试代码，不涉及生产路径的堆内存 / CPU 改进；本部分不产出优化方案（0 / 0）。测试基础设施的改进（基准时钟、优化级别、对照方式）已并入 P2-1 的「建议」，按缺陷处理，不重复计入本节。

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `pointcut_meta_cost_test` 打印的 `woven - plain` 差值中，`ThreadLocal.getOrCompute`、`ConcurrentHashMap` 命中、空链闭包调用各占多少；`-O0` 与 `-O2` 下该差值差几个量级 | `src/test/pointcut_meta_cost_test.cj:55-65`、`src/Aspects.cj:101-128` | 分段自耗时占比；两种优化级别的中位数 | 用例内用 `MonoTime` 分段计时（进入 `proceed` 前 / map 命中后 / 返回前），`-O0` 与 `-O2` 各 5 轮取中位数，或用 `cjprof record` 跑 1e6 次 |
| 2 | 用例执行顺序（`aspect_args_race_test` 先于 `pointcut_meta_reuse_test`）是否真的让 `metas` 的 `add` 在两线程重叠 | `src/test/pointcut_meta_reuse_test.cj:37/40/53`、`src/test/aspect_args_race_test.cj:81-93`、`src/Aspects.cj:61-96` | 实际用例顺序、链层序、`add` 的并发重叠 | 在 `MetaIdentityAspect.before` 里记录线程 id + 时间戳，`cjpm test` 全量跑 20 次；再用 `--filter` 固定「先 race 后 meta」单独复跑，看是否出现条目丢失/断言漂移 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_aspect/src/test/empty_chain_fastpath_test.cj` | .cj | ✅ | 断言对修前缺陷有效；前提与注释问题见 P2-5，`new` 与契约冲突见 P2-6，未用 import 见 P2-7 |
| 2 | `f_aspect/src/test/pointcut_meta_cost_test.cj` | .cj | ✅ | 伪基准，见 P2-1；`-O2` 缺失依据 `cjpm.toml:11-12` |
| 3 | `f_aspect/src/test/pointcut_meta_reuse_test.cj` | .cj | ✅ | 元信息复用断言本身有效；全局状态导致断言漂移与数据竞争，见 P2-2 |
| 4 | `f_aspect/src/test/qualified_func_info_key_test.cj` | .cj | ✅ | 4 个正例与 `QualifiedFuncInfo` 实现一致；缺负例见 P2-4，未用 import 见 P2-7 |
| 5 | `f_aspect/src/test/recursion_guard_test.cj` | .cj | ✅ | 单次最外层语义正确；复位/线程隔离/重入未覆盖，见 P2-3 |

合计：`.cj` 5 个 / `.md` 0 个 / 共 5 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 5 | 测试有效性 3 条（P2-1/P2-2/P2-3）、断言完整性与前提 2 条（P2-4/P2-5）；测试代码无并发外部输入与凭据，安全性 0 |
| §1 死代码 | 1 | 逐个符号核对：5 个文件里的 `@TestCase`/`@Test` 类与函数、目标类方法（`who`/`c`/`cStatic`/`m`/`r`/`probe`）、静态容器 `metas`/`entries`、切面 `before` 均被宏或用例引用；`cStatic` 是刻意的未织入基线，非死代码；无 `return` 后语句、无尽真分支。命中 P2-7（未使用 import） |
| §2 重复逻辑 | 0 | 已把 5 个文件的每个函数体压成「输入→输出→副作用」两两比对：`MetaIdentityAspect.before`（`metas.add`）与 `RecursionCountAspect.before`（`entries.add`）形状相近，但分别属于两套用例的准备代码、且 `recursion` 版本还解析 `args[0]`，属于 checklist §2 明列的「测试里的准备代码」误报边界，不计重复；两处 `public init() {}` 为 `$register` 闭包所需，是接口实现 |
| §3 空实现 | 0 | `public init() {}` 是切面实例化的必要构造；`before` 均有实际写入；无 `TODO`/`FIXME`/空 `catch`/占位 `None` |
| §4 栈溢出 | 0 | 用例自身递归深度为 4（`r(3)`），无输入驱动的递归；框架侧递归由 `RecursionState` 截断（`Aspects.cj:124-128`）。该守卫的「失效不可见」不是栈溢出风险本身，记在 P2-3 |
| §5 OOM | 0 | 静态容器 `metas`/`entries` 无界，但增长量 = 用例调用次数（每次 1 个对象引用，总数个位数），不构成 OOM；无全量物化、无按不可信长度预分配 |
| §6.1 热点瓶颈 | 1 | P2-1：用例自称量化织入开销，但缺 `-O2`、单调时钟、对照组与重复轮次，数据不可用于热点结论；缺口已另列「待验证假设」#1 |
| §6.2 大粒度锁 | 0 | 5 个文件无锁；被测路径唯一的建链临界区（`Aspects.cj:61-100`）归 part1 |
| §6.3 并发串行 | 0 | 本部分无 `spawn` 后立即 `get`、无固定并发度 1 的批处理；`aspect_args_race_test` 的握手属 part1 |
| §6.4 低效算法 | 0 | 仅 1e6 次循环计时与线性 `ArrayList.add`，规模个位数或刻意基准循环，无嵌套扫描、无 `remove(at:0)`、无循环拼接 |
| §7 降堆内存方案 | 0 | 测试代码无常驻内存问题；静态容器上界 = 用例调用数，降无可降，无基线 |
| §8 降 CPU 方案 | 0 | 生产侧方案归 part1「优化可行性方案 [CPU]」；本部分只有基准设施问题，已按缺陷记 P2-1，不重复计优化方案 |
| §9 local mode 可行性 | 0 | 测试代码无大临时对象；收益只能用峰值内存证明，本部分无此类对象可测 |
| §11 现有代码的 BUG（存量） | 6 | P2-1…P2-6，全部为存量（5 个文件均于 2026-10-05 由 `2c285e93b`/`ad8cc477c`/`d69d2ce83`/`ba4288006` 引入，快照模式无 diff 基线）；其中 P2-6 为待确认 |
| §12 并发安全与锁粒度 | 1 | P2-2 的并发写 `ArrayList`（结构静态确定、重叠需实测）；其余文件无线程共享路径（测试代码本身单线程），`RecursionState` 的线程封闭结论归 part1，本部分只指出用例未验证它 |
| §14 功能完备性与 README 覆盖 | 0 | 本部分不含 `src/` 公开声明与 README，README 覆盖归合并方（见范围声明）；已核对 5 个用例覆盖了各自注释声称的行为，无「承诺未测」的新增项（P2-1 属「测了但无效」，已在 §11 计） |
| 文件覆盖（§13 等） | 5/5 | 任务列出的 5 个文件全部读完；本模块 README 不在本部分任务清单内，未计入 |

## 模块统计

> 仅统计本部分（5 个测试文件）。

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 3 |
| 轻微 | 4 |
| 优化方案（堆内存 / CPU） | 0 / 0 |

存量缺陷 7 条（全部为存量，本部分无本次改动）；是否纳入修复待用户决定。

## 总评

这 5 个用例的**断言方向基本正确**：`empty_chain_fastpath_test` 对 ASP-L7 的修前缺陷（`b.who()` 读到 1）确实敏感，`qualified_func_info_key_test` 的 4 个正例与 `QualifiedFuncInfo` 的 `refEq || 结构相等` + 结构哈希实现一致，`pointcut_meta_reuse_test` 用 `refEq` 观测「元信息只建一次」也是对 ASP-3 的合理黑盒观测。也就是说，这几条修复的**正向证据是有的**。

问题集中在三处「反向不敏感」：

1. `pointcut_meta_cost_test` 是本部分最需要处理的（P2-1，一般）——它不是测试而是伪基准，唯一断言与计时无关，`DateTime` 墙钟 + `-O0` + 异构对照组 + 单轮，使它产出的 ns/次数字不能作为 ASP-3 的改前/改后证据；而它是模块里唯一的量化手段，容易被误引用。
2. 全局静态状态（P2-2，一般）——静态 `ArrayList` + 不注销的 `BeanFactory` 注册，使断言可能落在别的函数上，并把一个未承认的数据竞争带进并发用例；这是「竞态测试有效性」的直接命中项，与 part1 #14 同源、建议合并成一条处置。
3. 守卫用例（P2-3，一般）——`RecursionState` 的复位、线程封闭、切面重入三条失效都能通过现用例，而它是模块防无限递归的唯一机制。

4 条轻微项（负例缺失、空链用例的隐性前提与过期注释、`new` 与「必须 IoC bean」的口径冲突、未用 import）不阻塞，建议随上述修复一并处理。

**跨部分依赖**：P2-2 与 part1 #14、P2-6 与 part1 #4 是同一根因的不同侧面，合并时请各保留一条、位置合并；P2-1 与 part1「优化可行性方案 [CPU]」引用的存量 1867–2443 ns/次数据同源，合并后该数据的证据等级应降为「仅 `-O0` 单轮打印值，不可引用」。
