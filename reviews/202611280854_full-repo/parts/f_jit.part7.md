# f_jit 模块审查报告（模块第 7/38 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_jit`（本部分 20 个文件，全部 `.md`：`doc/plan-m1..3` + `doc/spec/` 四个归档变更目录的 17 份文档）
- **基线**：工作区快照（master 与 sts/1.3.x 同一提交 `120fd2542`，`git diff` 为空）⇒ 全部问题来源记「存量」
- **审查重点**：f_jit 专项（桥接正确性、句柄与资源生命周期、并发安全、递归与栈溢出、死代码、重复逻辑）在文档面的投影——§13 文档承诺（API/机制/路径/验收数字）与 `src/` 现状逐条对拍、§14 能力登记完备性、计划文档内部自洽（步骤编号/计数/状态）
- **报告版本**：v1（分报告，供主 Agent 合并进 `docs/review/2026-11-28/f_jit_v2.md`）

## 发现

### [一般][存量] `close(timeoutMs)` 的「超时」实为无时钟源的自旋次数预算，排空循环每轮都抢同一把单元锁

- **位置**：契约描述 `f_jit/doc/spec/align-jitfunction-close-naming/design.md:22-23`（「入口实例的 `close(timeoutMs)` 是**单元卸载**：排空全部在飞调用、进入终态、逐出缓存；超时回退可用并返回 `false`」）；实现对照 `f_jit/src/JitFunction.cj:237-253`（单元）与 `:309-326`（闭包包装）
- **来源**：存量（快照模式无 diff）
- **判据**：review-checklist §13「契约与实现不符」+ §11「语义与命名不符」+ §12.1（无时间源的忙等、与在飞调用退出路径争锁）
- **证据**：静态确定 —— 两处排空循环均为 `let limit = if (timeoutMs <= 0) { 0 } else { timeoutMs * 100000 }`，循环体只做 `synchronized(this.mtx) { active == 0 }` / `{ e.active == 0 }` 并把 `spins` 加一（`:238-252`、`:310-325`）；该文件内检索 `now()` / `Stopwatch` / `sleep` / `yield` 均为 0 命中，即**没有任何时钟源**，也没有让出 CPU 的动作
- **描述**：参数名与设计文档都表示毫秒级超时，实际等待时长 = 迭代预算 ÷（单轮「取锁 + 读计数」耗时）。机器越快、竞争越轻，等待越短；`close(5000)` 在快机上可能几十毫秒就返回 `false`（单元仍可用，语义安全），在慢机/高负载下则可能空转远超声明的毫秒数。空转期间该线程持续抢 `mtx`，而在飞调用退出时 `exitUnit`/`exitClosure`（`:197-212`）需要同一把锁，形成「关闭者越抢、调用者越难退」的互相拖慢。`close(0)` 只判一次即返回，与文档「不等待」一致，不受此条影响。
- **建议**：排空改为以单调时钟为基准（`Stopwatch` / `DateTime.now()` 差值），循环内 `sleep` 一小段或改用条件变量在 `active` 归零时唤醒；若确实要保留迭代预算，则把参数改名为 `spinBudget` 并在 design/spec 写明单位，避免下游按毫秒做超时预算。

### [轻微][存量] `plan-m1.md` 的实施记录仍称 x86_64 后端未完成、降级解释器，与现状相反

- **位置**：`f_jit/doc/plan-m1.md:276`
- **来源**：存量（该行属 2026-10-18 的「§5 实施记录」，此后未随 x86 后端落地更新）
- **判据**：review-checklist §13「文档过期——写着"暂不支持"其实已支持」；§11「契约与实现不符」
- **证据**：静态确定 —— `f_jit/src/backend/BackendSelector.cj:65-67` 对 Linux/x86_64 直接返回 `(Engine.Jit, Some(BackendX86_64()))`；`:89-104` 的 `BackendX86_64.compile` 逐函数调 `X86Compiler.compileFunction` 并把产物写入 `sink`（失败才 `false`）；`f_jit/src/compiler/X86Exec_test.cj:27-60` 有 `@When[arch == 'x86_64' && os == 'Linux']` 的原生执行用例（最小单元/算术/分支/常量折叠等）
- **描述**：原文为「**S5.4 未完成**：`BackendX86_64.compile` 仍降级解释器……待 x86_64 原生 CI 上补」。这是 §5 里唯一一条「剩余工作」，读者会据此认为 JIT 只在 aarch64 生效，做平台选型或性能预期都会得出相反结论。
- **建议**：改写为结项记录并注明补齐它的变更目录（`doc/spec/fix-f-jit-x86-*`、`align-x86-loop-back-stack-guard` 等），或在 §5 标题显式标注「截至 2026-10-18 的状态快照」。

### [轻微][存量] 三份计划的「阶段总览」步骤数与步骤清单行数不符，且 S2.16 行序倒置

- **位置**：`f_jit/doc/plan-m1.md:68`（P2 记 15 步）、`f_jit/doc/plan-m2.md:26`（Q3 记 8 步）、`f_jit/doc/plan-m3.md:26`（R3 记 9 步）；行序问题在 `f_jit/doc/plan-m1.md:123-124`
- **来源**：存量
- **判据**：review-checklist §13（文档内部自洽）+ §14.1（计划承诺与实际产物对不上）
- **证据**：静态确定 —— 机械计数（去重后按阶段分组）：S0=3、S1=11、**S2=16**、S3=22、S4=22、S5=14、S6=12、S7=8；Q0=3、Q1=6、Q2=4、**Q3=10**、Q4=12、Q5=12、Q6=7；R0=3、R1=3、R2=5、**R3=10**、R4=12、R5=5、R6=7。`plan-m2.md:138` 自写「54/54 全部完成」，而 3+6+4+**10**+12+12+7=54——只有按 10 步才成立，反证总览表的 8 是追加 Q3.9/Q3.10 后漏更新；P2 同理（S2.15/S2.16 后补）。另 `plan-m1.md:123` 是 S2.16、`:124` 才是 S2.15，与 §0.5「步骤号稳定，便于引用」冲突。
- **描述**：数字对不上会让「还剩几步 / 是否全部完成」失真；行序倒置让按编号顺序阅读/勾兑的人多跳一次。
- **建议**：三处改为 16 / 10 / 10（或总览只写范围 `S2.1–S2.16`，把计数交给脚本）；S2.16 与 S2.15 两行互换。建议在 `f_jit/scripts/` 增加与 `check_tmap.sh` 同风格的「总览计数 vs 步骤行数」自检。

### [轻微][存量] `plan-m1.md` 的模块骨架与依赖清单缺 `macros` / `surface` / `userapi` 三包与 `f_macros` 依赖

- **位置**：`f_jit/doc/plan-m1.md:39-53`（§0.4「模块骨架与构建（P0 产物）」+ 依赖声明列表）
- **来源**：存量
- **判据**：review-checklist §14.1「能力未接入 / 新模块没进模块索引」+ §13「关键段落缺失」
- **证据**：静态确定 —— §0.4 只列 `Root.cj` + `base/` `bytecode/` `compiler/` `runtime/` `backend/` `test/diff/` 六个包，依赖只列 `f_base` / `f_regex` / `f_util`（+「M3 追加 `f_data`」）；实际 `f_jit/src/` 另有 `macros/`（`JitBind.cj`、`JitSignature.cj`、`IgnoreJitBinding.cj`）、`surface/`、`userapi/`，且 `f_jit/cjpm.toml` 的 `[dependencies]` 含 `"fountain::f_macros"`。三份计划全文检索 `JitBind|macros|宏`，只有 S1.3 的「无宏，硬编码映射」一处，与宏包无关
- **描述**：§0.4 被写成可执行的 P0 产物（「按 §0.4 建目录与 package 声明」），照此建模块会漏掉宏包；`S6.11`「再导出与用户面冒烟 / 用户面 API 冻结」也没覆盖 `@JitBind` / `@JitSignature` / `@IgnoreJitBinding` 这三个对外注解入口，读者无法从计划判断它们是否属于用户面契约。
- **建议**：§0.4 补三行包目录与 `f_macros` 依赖，并在 S6.11 的导出一览里点名宏入口；若宏包由后续变更引入，注明对应 `doc/spec/<change>/`。

### [轻微][存量][待确认] `plan-m2.md` §4.3「`cjpm test` 必须带 `--parallel 1`」的成因可能已从注册面消除

- **位置**：`f_jit/doc/plan-m2.md:166-171`
- **来源**：存量
- **判据**：review-checklist §13「文档过期」（约束的理由已不成立，但约束仍被写成强制）
- **证据**：待确认 —— 静态可确认：该段理由是「反射 `InstanceFunctionInfo.apply` 的 MCC 路径在引用型参数上触发 SIGSEGV（GAP-13）」；而 `f_jit/src/ReflectRegistrar.cj:265-276` 现在对「引用型参数/返回且无 overrides」的方法**默认跳过**（`skip(..., '引用型参数/返回在反射 apply 上会 SIGSEGV（GAP-13）...')`），即默认不再生成这条绑定。缺的信息：① 走 `overrides` 的用例是否仍会触碰 MCC 路径；② 去掉 `--parallel 1` 后并发 GC 是否引入其他不稳定（`f_jit/doc/spec/f-jit-m2/verify.md:295` 另记「测试口径另加 `--parallel 1`（降低并发 GC 干扰）」）。
- **描述**：现状下这条约束更像"稳定性保险"而非"必须"，但文档用「**必须**」并给出已失效的技术理由，后续维护者无法判断能否放开并行。
- **建议**：补一句「GAP-13 已在注册面拦下；`--parallel 1` 仅作稳定性保险（待复测）」；有条件时补一次默认并发的全量结果。

> 存量缺陷共 5 条（一般 1、轻微 4），是否纳入修复待用户决定。

## 优化可行性方案

本部分 20 个文件均为文档，没有独立的堆 / CPU 可量化改造对象：

- **[堆内存]** 无适用对象——文档不持有运行时对象；`CompileCache` / 句柄表 / 窗口的内存面在对应源码部分评审。
- **[CPU]** 无独立方案——唯一实质性 CPU 面（`close` 排空自旋空转 + 每轮取锁）已作为上面第 1 条缺陷的修法，不另立优化项，避免同一根因重复计数。

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `close(timeoutMs)` 的自旋排空在在飞调用未退出时占满一个核，且与 `exitUnit`/`exitClosure` 抢同一把 `mtx`，是关闭路径的主要 CPU 来源 | `f_jit/src/JitFunction.cj:237-253`、`:309-326` | 单次 `close` 的 CPU 时间占比、线程状态（RUNNABLE vs BLOCKED/WATING）分布 | 一线程持长调用，另一线程 `close(5000)`；分段计时 + `cjprof record`；锁等待另取线程状态证据（CPU profile 看不到） |
| 2 | `plan-m1.md:275` 的 43.8×（Interp 1,759,793,327 ns vs AArch64 40,221,815 ns，200000 次循环）不能外推到 x86_64 | `f_jit/doc/plan-m1.md:275` | x86_64 同结构、同副作用、`-O2`、同输入的对照 | 同一循环用例在 x86_64 上跑 Interp 与 JIT 两路径，≥5 轮取中位数与离散度 |
| 3 | 并发矩阵 5 例（并发度 6、合计约 70 ms）覆盖不到更高竞争下的竞态 | `f_jit/doc/spec/add-concurrency-matrix-tests/verify.md:88-96` | 8–32 线程下的失败率 / 变异存活率 | 沿用该变更的变异手法（M1/M2/M2b）在更高并发下重跑，统计红/绿 |
| 4 | `PerfM2_test` 的阈值型断言在高负载下假失败，说明门槛余量不足 | `f_jit/doc/plan-m2.md:162`、`f_jit/doc/spec/align-call-entry-spec/verify.md:8` | 失败率与阈值余量 | 连续 20 轮全量，记录失败次数与当轮机器负载 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `doc/plan-m1.md` | .md | ✅ | 见发现 #2 #3 #4；S1.4 版本常量（1/14/36/"FBC1"）、S1.10 `DiagCode` 六值与 `DiagnosticLevel` 仅 `Info｜Warn`、S1.8 三个异常均 `<: BaseException`、S2.4 `FuncEntry.SIZE=26`、S2.1 `0xA9/0xAA=CAT_FORBID` 均与代码一致 |
| 2 | `doc/plan-m2.md` | .md | ✅ | 见发现 #3 #5；§4.2 九项落点路径逐条核对全部存在（`src/surface/FacadeSurface_test.cj`、`src/test/diff/TCoverage.cj`、`doc/spec/f-jit-m2/`、`src/runtime/Signature.cj`、`src/runtime/SignatureDescriptor_test.cj:107` 内的 `ReflectiveVerify_test`、`src/Q6DiffCoverage_test.cj`、`src/PerfM2_test.cj`、`doc/perf-m2.md`）；`RegistrationRejectKind` 六值、`SignatureVerifier.cached`、`callForFn<Fn>` 签名均与代码一致 |
| 3 | `doc/plan-m3.md` | .md | ✅ | 见发现 #3；R1.3 `ErrCode.ANY_CAST=22`、R2 的 kind 11、R4 H81–H83、LocalType 15–19、`PromotionGroup` 均存在 |
| 4 | `doc/spec/add-concurrency-matrix-tests/proposal.md` | .md | ✅ | 5 个场景与 `src/ConcurrencyMatrix_test.cj:62/113/157/215/269` 逐条对应（线程数 6、20 次/8 源） |
| 5 | `doc/spec/add-concurrency-matrix-tests/tasks.md` | .md | ✅ | 勾选项与 verify 结论（1253/1253）自洽 |
| 6 | `doc/spec/add-concurrency-matrix-tests/verify.md` | .md | ✅ | 引用两段变异 diff 与 `src/CompileCache.cj:60-69`、`src/runtime/UserHelper.cj:53-63` 逐字一致；`X86Exec_test` 存在；基线 1+1247=1248 与「全量 1248」自洽 |
| 7 | `doc/spec/align-base-contracts-callcontext/design.md` | .md | ✅ | 「只写现状 + 保留 Scenario 名」的决策成立 |
| 8 | `doc/spec/align-base-contracts-callcontext/proposal.md` | .md | ✅ | `CallContext` 收窄描述与 `src/base/CallContext.cj:34-45` 一致（唯一字段 `deadline`，构造后只读） |
| 9 | `doc/spec/align-base-contracts-callcontext/specs/f-jit-base-contracts/spec.md` | .md | ✅ | `Engine`/`JitValue` 用户面不可见成立（`src/base/Engine.cj:29`、`src/base/JitValue.cj:42` 均 `protected`，`src/Root.cj` 未再导出） |
| 10 | `doc/spec/align-base-contracts-callcontext/tasks.md` | .md | ✅ | — |
| 11 | `doc/spec/align-base-contracts-callcontext/test-plan.md` | .md | ✅ | `CallContext_test` 3 例与文件内用例一致 |
| 12 | `doc/spec/align-base-contracts-callcontext/verify.md` | .md | ✅ | 1127/1127 与后续 1115/1248/1253 属不同时点，不判冲突 |
| 13 | `doc/spec/align-call-entry-spec/design.md` | .md | ✅ | 重载决策与 `src/JitFunction.cj:147/159`（双载重、`DEFAULT_CONTEXT`）一致 |
| 14 | `doc/spec/align-call-entry-spec/proposal.md` | .md | ✅ | `invoke` 入口已不存在（全 `src/` 仅剩 `JitExecutor.invoke` 这一无关 API），双载重成立 |
| 15 | `doc/spec/align-call-entry-spec/specs/f-jit-facade-bridge/spec.md` | .md | ✅ | `call(args)` 等价 `call(args, CallContext())` 成立；`deadline` 栈式保存/恢复与 `src/JitFunction.cj:159-181` 一致；`callForFn` 串行化条款已被 `feat-f-jit-parallel-call` 取代（归档 delta 按"当时结论自洽"核对，见覆盖自检） |
| 16 | `doc/spec/align-call-entry-spec/tasks.md` | .md | ✅ | 用例 `a3_4_callOverloadsAgree`、`defaultCtorAndCallOverload` 均存在 |
| 17 | `doc/spec/align-call-entry-spec/test-plan.md` | .md | ✅ | 两条门槛用例可定位（`AnyBridgeCall_test` 7 例、`JitBacked_test` 4 例） |
| 18 | `doc/spec/align-call-entry-spec/verify.md` | .md | ✅ | 记录 `PerfM2_test` 负载假失败（假设 #4） |
| 19 | `doc/spec/align-jitfunction-close-naming/design.md` | .md | ✅ | 见发现 #1；`close`/`isClosed` 的入口/包装两义与 `src/JitFunction.cj:227-299`、`:471-484` 一致，`JitFunction <: Resource`（`:59`）一致 |
| 20 | `doc/spec/align-jitfunction-close-naming/proposal.md` | .md | ✅ | `close(): Unit` = `close(0)`、`isClosed()` 为方法，均与代码一致；仓内 `unloadFn(` 调用 0 处 |

合计：`.cj` 0 个 / `.md` 20 个 / 共 20 个，全部读完（与 `files/f_jit.part7.txt` 逐行对应）。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 1 | 发现 #1（契约与实现不符）。语言特性面逐项核对：`CallContext` 唯一字段 `deadline` + 构造后只读、`call` 同名双载重、`Resource` 的 `close`/`isClosed`、`protected` 枚举不外泄——均与文档一致；本部分无外部输入，无注入/凭据面 |
| §1 死代码 | 0 | 文档无代码，做等价机械检查：以反引号引用的 30+ 路径/符号逐个解析，`design-m1/m2/m3.md`、`jit-bytecode-m1/m2/m3.md`、`doc/perf-m2.md`、`doc/spec/f-jit-m2/`、`src/surface/FacadeSurface_test.cj`、`src/test/diff/TCoverage.cj`、`src/runtime/ReflectiveCall.cj`、`src/runtime/Signature.cj`、`src/Q6DiffCoverage_test.cj`、`src/PerfM2_test.cj`、`src/compiler/X86Exec_test.cj`、`scripts/check_tmap.sh`、`scripts/check_scenarios.sh` 全部存在；`.md` 中无 `](...)` 超链接，故无死链；唯一「文中出现但全仓无此符号」的 `lastClosureGroup` 落在归档 delta，见下方第 13 行说明 |
| §2 重复逻辑 | 0 | 两件机械比对：① 四份归档 delta 的 spec 文本互相比对——`align-call-entry-spec/.../spec.md:7` 与 `close-f-jit-out-of-checklist-findings/.../spec.md:53` 同文，属 OpenSpec MODIFIED 需求必须整段重述的格式要求，不是可合并重复；② 三份计划的总则——`plan-m2.md:15`、`plan-m3.md:15` 写「其余总则同 plan-m1.md §0」而非复制，无大段复制。两份「纯规格对齐」变更（align-base-contracts / align-call-entry-spec）目标不同，不构成合并候选 |
| §3 空实现 | 0 | 文档层等价检查：各 `tasks.md` 的勾选项都能在 `verify.md` 找到数值结论（5 例并发用例、1115、1127、1253），无"勾了但无验证依据"项；plan-m1 S7.8「文档同步」如实未勾 |
| §4 栈溢出 | 0 | 文档不承载递归实现；plan-m1 S3.16 的尾位置降低只描述发射规则，未承诺无界深度 |
| §5 OOM | 0 | 本部分未承诺任何容器/缓存规模；窗口与句柄表容量语义在源码部分 |
| §6.1 热点瓶颈 | 0 | 本部分无 profile/bench 数据；plan-m1 §5 的 43.8× 是单机型单次记录（含编译），不足以支撑热点结论，已入待验证假设 #2 |
| §6.2 大粒度锁 | 0 | 无「临界区内做 I/O / 解析 / 回调」的文档描述可判；发现 #1 的"每轮自旋取锁"按缺陷计（§12.1），其性能影响入待验证假设 #1 |
| §6.3 并发串行 | 0 | 文档未承诺批大小/并发度；归档 delta 里「`callForFn` 整段串行」已被后续并行化变更取代（见第 13 行） |
| §6.4 低效算法 | 0 | 本部分不描述算法实现；`timeoutMs*100000` 的自旋复杂度已在发现 #1 说明 |
| §7 降堆内存方案 | 0 | 纯文档部分，无持有对象/生命周期可评 |
| §8 降 CPU 方案 | 0 | 唯一候选（自旋排空）已作为发现 #1 的修法，避免同根因重复计数 |
| §9 local mode 可行性 | 0 | 无函数级临时大对象描述，也无峰值内存数据 |
| §11 现有代码的 BUG（存量） | 1 | 发现 #1（`timeoutMs` 语义与实现不符）；#2–#5 为文档缺陷，计入 §13/§14 |
| §12 并发安全与锁粒度 | 1 | 发现 #1（无时钟源的忙等 + 每轮取同一 `mtx`，与在飞调用退出路径争锁）。正向核对：`CompileCache.claim` 三集合去重（`src/CompileCache.cj:60-69`）、`UserHelperTable` 的 `ThreadLocal` 栈（`src/runtime/UserHelper.cj:53-63`）与文档描述一致 |
| §13 文档一致性（专项） | 4 | 发现 #1 #2 #4 #5；另核对并**排除**一条：`align-call-entry-spec/.../spec.md:7` 的「`callForFn` 整段持单元锁 + `lastClosureGroup` 不残留」已被 `feat-f-jit-parallel-call` 的 P3（删 `callMtx`，改按调用 `CallOut`）取代，但该文件是已归档变更的 delta，按 checklist §13 误报边界「按当时结论是否自洽核对」判定不构成当前缺陷，仅记一句提示 |
| §14 功能完备性与 README 覆盖 | 2 | 发现 #3（计划总览与步骤清单不符）、#4（骨架/依赖/宏入口未登记）；本部分不含 `README.md` / `README_en.md`，public API 的 README 覆盖留给对应部分 |
| 文件覆盖（§13 等） | 20/20 | 无缺文件；命中问题的文件 4 个：`plan-m1.md`、`plan-m2.md`、`plan-m3.md`、`align-jitfunction-close-naming/design.md` |

## 模块统计（仅本部分）

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 1 |
| 轻微 | 4 |
| 优化方案（堆内存 / CPU） | 0 / 0 |

## 总评

本部分是 f_jit 的计划与变更归档文档，不含源码。整体质量高于一般文档：数字有出处（43.8× 的两次耗时与比值自洽）、用例名与真实方法名逐个对得上、变更 delta 与代码的命名（`close`/`isClosed`、`CallContext.deadline`、LocalType 15–19、HelperId 78–83、`ErrCode` 21/22/23/99）基本同步，`plan-m2` §4.2 的十个落点文件也都能在仓内定位——没有"编造的验收"。

风险主要在两类：

1. **一处契约与实现不符**（发现 #1）：`close(timeoutMs)` 的「超时」是没有时钟源的自旋预算，且每轮抢同一把单元锁。这既是命名/文档与实现的口径差，也让关闭路径在真并发下空转抢锁；修法是换成单调时钟 + 让出 CPU（或改参数名并在规格写清单位），属可排期的一般项，不影响数据正确性。
2. **计划文档的状态与计数漂移**（发现 #2 #3 #4 #5）：x86 后端已落地却仍记「未完成」，三处阶段总览少记一步，骨架漏了 `macros`/`surface`/`userapi` 三个包与 `f_macros` 依赖，`--parallel 1` 的理由可能已失效。这些都会误导排期与"还剩多少工作"的判断，建议一次批量回写，并加一个计数自检脚本长期钉住。

存量 5 条（1 一般 + 4 轻微）默认只报不修，是否纳入修复由用户决定；「待验证假设」4 条不进 `todo.md` / `tasks.md`，留给下一轮补数据。

> 范围外提示（不计入本部分统计，供对应部分复核）：① `f_jit/src/backend/BackendSelector.cj:77` 类注释「（P5.4–P5.8 落地；当前为契约占位）」与其 `:89-104` 的实现相反；② `f_jit/src/base/CallContext.cj:25` 的成员表仍列 `args: Array<Int64>`、`f_jit/src/base/CallContext_test.cj:27` 仍写「只钉住……`args` 与 `deadline`」，与 `align-base-contracts-callcontext` 的「`args` SHALL NOT 出现」相反；③ `f_jit/src/AnyBridgeCall_test.cj:189/200` 仍以 `invoke` 指代已并入 `call` 重载的入口（局部变量 `viaInvoke`）。
