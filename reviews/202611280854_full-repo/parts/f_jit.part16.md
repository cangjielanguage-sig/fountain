# f_jit 模块审查报告（模块第 16/38 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_jit`（全模块 305 个 `.cj` / 290 个 `.md`；本部分 20 个 `.md`、0 个 `.cj`）
- **基线**：工作区快照（sts/1.3.x 工作区，未对照远端目标分支；本部分无 diff，问题统一记「存量」）
- **审查重点**：动态调用/桥接正确性（typecode 分支表）、句柄与资源生命周期、并发安全、递归与栈溢出、死代码、重复逻辑、存量 BUG
- **本部分范围**：`f_jit/doc/spec/` 下 6 个变更的过程文档——`jit-closure-unload-cascade`(tasks)、`jit-function-resource-close`(4 件)、`optimize-arg-staging`(4 件)、`optimize-call-alloc`(4 件)、`optimize-call-alloc2`(3 件)、`optimize-call-path-phase1`(4 件)
- **报告版本**：v1

> 本部分是**纯文档部分**：20 个文件全部是 SDD 过程文档（proposal / design / tasks / verify / spec delta）。
> 因此缺陷面集中在「文档与实现一致」「同一变更内多份文档自洽」「测量数据能否支撑结论」三条，
> 代码侧缺陷只在**文档引用的实现点**上取证，不与第 15 部分重复计数（`JitFunction.close` 并发回退、
> 自旋超时、`close(): Unit` 丢弃返回值、归档规格 `unload` 旧名四条已在 part15 #1/#2/#3/#9 报出）。

## 发现

### [一般][存量] `optimize-call-alloc`：设计的「`pins` 残留 → `resetWindow` 误释放」与实现相反，且与同变更 `verify.md` 结论互相矛盾

- **位置**：`f_jit/doc/spec/optimize-call-alloc/design.md:45`、`f_jit/doc/spec/optimize-call-alloc/proposal.md:36`；对照 `f_jit/doc/spec/optimize-call-alloc/verify.md:42`
- **来源**：存量（快照模式无基线；`git log -1 -- f_jit/doc/spec/optimize-call-alloc` = 2026-11-27）
- **判据**：review-checklist §13（文档与实现不符）+ §2（同一变更内多处复述同一结论，结论本身错误）
- **证据**：静态确定 —— `resetWindow` 的释放循环只遍历 `w.appendIds`（`f_jit/src/runtime/HandleTable.cj:1064`），并在循环上方的注释里明确写「路径 B 的 pin 是桥侧资产，**窗口收尾不得动它**」（`HandleTable.cj:1062-1063`）；`w.pins` 只在 `HandleTable.cj:1083` 被 `clear()` 清记账，从未被用于释放槽。因此「`pins` 残留在 `resetWindow` 里误释放别的调用 pin 的槽」这条因果不成立。`verify.md:42-43` 自己也写「`pins` 残留不会造成功能错误……陈旧 ID 直接跳过（只是多扫一条）」，并据此判定「不清 `pins`」不是有效变异形态——与 `design.md:45` / `proposal.md:36` 的「必须清、否则误释放」直接对立。
- **描述**：同一个变更的三份文档对「`pins` 要不要清、为什么清」给出相反结论：design/proposal 说 `pins` 残留会造成跨调用误释放（把它列为 5 个字段里最危险的两个之一），verify 说 `pins` 残留无害、不是有效变异。实际实现里真正的风险字段只有 `appendIds` 与 `used`（`appendIds` 决定 `resetWindow` 释放哪些槽、`used` 决定 `hwTop` 镜像与容量），`pins` 只影响 `winPinSize` 的去重扫描长度（`HandleTable.cj:262-274`）。按错误因果读文档的维护者会做两件错事之一：把「清 `pins`」当成不可删的必要保护（保留冗余、掩盖真正的不变量），或在其它路径复用 `Win` 时以为「只要清了 `pins` 就安全」而漏清 `appendIds`。
- **建议**：把 `design.md:45` 与 `proposal.md:36` 的风险描述改成「残留 `appendIds` / `used` 会让新窗口继承上一次的释放清单与记账」，`pins` 标注为「仅为去重列表，残留只增加扫描、不影响正确性」；同时把 `recycleWin` / `acquireWin` 里清 `pins` 的注释写成防御性（或直接说明与 `resetWindow:1083` 冗余）。护栏用例无需新增（现 `reusedWindowStartsClean` 已覆盖 `used`/`appendIds` 口径）。

### [一般][存量] `optimize-call-alloc2` 的验证表把快/慢两种模式混在一行，`+2.3%` 没有基线，两轮相差 1.85× 却被判为「噪声内」

- **位置**：`f_jit/doc/spec/optimize-call-alloc2/verify.md:5-12`（对照 `f_jit/doc/spec/optimize-call-alloc2/tasks.md:3`、`f_jit/doc/spec/optimize-call-path-phase1/design.md:56-60`）
- **来源**：存量（目录最后提交 2026-11-27）
- **判据**：review-checklist §13（文档结论与所列数据不符）+ §6.1（判定必须给对照与离散度，中位数而非单次最好值；无数据的结论只能进「待验证假设」）
- **证据**：静态确定 —— 表里 `改前` 只有一组 `3036 ns / 329k calls/s`，`改后（两轮）` 是 `2975 / 5516` 与 `336k / 181k`；结论段写「快模式 3036 → 2975（−2.0%），**慢模式 +2.3%**，均在噪声内且低于 MOV(3%)」。慢模式的改前值在表里不存在（按 +2.3% 反推应约 5392 ns，文档未给）；而同一臂的两轮值 2975 与 5516 相差 **85%**，按项目自己在 `optimize-call-path-phase1/design.md:56-60` 定的口径（`MOV = max(3%, 2d)`；`d ≥ 10%` ⇒ 工具不稳定，**先修工具，不进入任何优化**），这组数据连「工具稳定」都不成立，无法支撑「在噪声内」的判断。
- **描述**：`−2.0%` 与 `+2.3%` 分别取自两个不同模式的值，却与同一行基线比较；慢模式基线缺失，`+2.3%` 不可复核。文档随后以「本轮不宣称加速」收尾，结论方向没问题，但「均在噪声内」的措辞掩盖了真实情况：**两轮之间差 85%，属于模式/环境切换，不是噪声**。这类记录会被下一轮优化当作「已有基线」，把不同机器状态的数据并到一条序列上。另有一处口径不一致：`proposal.md:27` 与 `tasks.md:7`（K3.2）写「同进程 5 万次 × **3 轮**取最小」，`verify.md:5` 写「**5 轮**取最小」，轮数无法互证。
- **建议**：拆成两行两列（快模式 / 慢模式各自给改前与改后），慢模式补基线值与环境行（`uname -a`、`load average`、`taskset`）；结论改成「快模式 −2.0%，低于 MOV；慢模式因缺改前基线，本轮不判定」。若坚持「两轮同模式」，则按 `d ≥ 10%` 规则宣布工具不稳定、不作任何结论。

### [轻微][存量] `optimize-call-alloc` 验证表样本不对称，且「`L1` 约 −300~370 ns」与表中数据算不出来

- **位置**：`f_jit/doc/spec/optimize-call-alloc/verify.md:15-25`
- **来源**：存量（目录最后提交 2026-11-27）
- **判据**：review-checklist §13（文档数据与结论不符）+ §6.1（对照必须同环境、同口径）
- **证据**：静态确定 —— A/B 表两臂样本数是 3 vs 2（`复用 241 / 236 / 430`，`每次 new 632 / 333`），配对关系（哪一对是同轮）没有写；结论「慢峰 632 → 430（−32%）」「快峰 333 → 236（−29%）」只用掉其中两对，`241` 未被使用。随后一句「`L1` 约 **−300~370 ns**」与表内数据不符：以历史基线 601 ns 计，对 430 是 −171 ns、对 241 是 −360 ns、对 236 是 −365 ns，任何配对都得不到 −300 的下界（若按配对 632→430 则是 −202 ns）。`−32%` / `−29%` 本身算得对（631.96 / 29.1）。
- **描述**：`keep` 判定成立（远超 MOV），但收益区间写大了约 1.8 倍，且 3 个复用值里有一个未参与任何对比，读者无法重现「−300~370」。这类区间会被后续汇总当成窗口池的真实收益上界。除数值外，判定判据本身也缺数据：`tasks.md:24`（W4.1）要求「5 次 + `Q4` 回退 ≤2% + `windowRs` ≤300 ns」，而 `verify.md` 全篇没有 `Q4`，慢峰 430 ns 也超过自定的 300 ns 上限且未作说明 ⇒ 三条判据里有两条没有数据支撑。
- **建议**：A/B 表改成「同轮配对」两列（第 1/2 轮各自的复用值 vs new 值），删掉未配对样本；收益区间按实际配对重算，或直接写「−171 ~ −365 ns（相对历史 601 ns 基线）」；并补 `Q4` 的改前/改后值，把 W4.1 的「≤300 ns」改成可判定形式（或注明慢峰 430 ns 未达标、判定只依据相对 MOV）。

### [轻微][存量] `WindowPool_test` 实际 3 条用例，tasks/verify 两处记 2 条，且 verify 的护栏清单漏掉变异验证所依赖的那一条

- **位置**：`f_jit/doc/spec/optimize-call-alloc/tasks.md:13`、`f_jit/doc/spec/optimize-call-alloc/verify.md:29-32`（对照 `tasks.md:29`、`verify.md:40`）
- **来源**：存量
- **判据**：review-checklist §13（文档与实现数量不一致）+ §14（验收记录与实际护栏不匹配）
- **证据**：静态确定 —— `f_jit/src/WindowPool_test.cj` 有 3 个 `@TestCase`：`repeatedOpenResetKeepsState`(`:36`)、`liveCountReturnsToBaseline`(`:53`)、`reusedWindowStartsClean`(`:68`)。`tasks.md:13` 记「新增 `WindowPool_test` 2 条」并只列「连续 1000 次开合」「`append` 残留不串」；`verify.md:29` 记「新增 2 条」，`verify.md:31-32` 列的 2 条是 `repeatedOpenResetKeepsState` 与 `liveCountReturnsToBaseline`——**漏掉 `reusedWindowStartsClean`**，而 `tasks.md:29` 的变异项（W5.1）正是以「`reusedWindowStartsClean` 变红」为验收，`verify.md:40` 的变异表也引用了它。
- **描述**：同一变更里「用例数」有三处口径（2 / 2 / 隐含 3），而 verify 的「护栏」小节把唯一的变异靶子漏在清单外，读起来像变异验证打在一条不存在的用例上。
- **建议**：三处统一为 3 条并补全用例名与断言要点（`reusedWindowStartsClean` = 复用窗口从 `used==0` 开始、`append` 残留不串）；`verify.md:31-33` 的清单与 §4 变异表对齐。

### [轻微][存量] `optimize-arg-staging` 的「394 ns 拆解」四项合计 411–489 ns，比被拆解的总量还大

- **位置**：`f_jit/doc/spec/optimize-arg-staging/design.md:5-14`、`f_jit/doc/spec/optimize-arg-staging/tasks.md:10-11`、`f_jit/doc/spec/optimize-arg-staging/verify.md:14-19`
- **来源**：存量（目录最后提交 2026-11-27）
- **判据**：review-checklist §13（数据核算错误）+ §6.1（拆解必须闭合，否则不能作为判定依据）
- **证据**：静态确定 —— 四段估算为 `~170` + `50–100` + `~170` + `21–49`，合计 **411–489 ns**；被拆解的端到端差值是 394 ns（`f_jit/doc/optimize-call-path.md:329` 原文 `+394（实参路径）`）。下界已超出 17 ns，上界超出 95 ns（4%–24%）。同一份 verify 还用「单参调用约 3.5–6 µs」作分母（`verify.md:23`），而 `optimize-call-path.md:329` 的单参单元是 8977 ns，两个分母相差近一倍。
- **描述**：判定结论（`invokeOff` 自身 21–49 ns < MOV，**不做**）不受影响——错误方向是把小项估大，不会把小项变成大项。但「拆解」不闭合意味着四段的归属占比（`<1.5%`）不可复核，而这正是本变更唯一的交付物（纯测量/判定）。
- **建议**：把四段改成「其中可归因段 + 未归因残差」的形式（例如列出 411–489 的估算区间并注明与 394 的差额为估算误差/未测量段），或按实测把 `Array<Any>` 构造与 `cells` 分配两段的 170 ns 重新标定；分母统一取 `optimize-call-path.md:329` 的同一场景值。

### [轻微][存量] `jit-closure-unload-cascade/tasks.md` 的归档项未勾选，但四件套镜像已落盘（且该变更已被后续 `close` 改名取代）

- **位置**：`f_jit/doc/spec/jit-closure-unload-cascade/tasks.md:36`（C4.5）
- **来源**：存量（目录最后提交 2026-10-27）
- **判据**：review-checklist §13（文档过期 / 状态与事实不符）
- **证据**：待确认 —— `ls -R f_jit/doc/spec/jit-closure-unload-cascade` 显示 `design.md` / `proposal.md` / `specs/f-jit-facade-bridge/spec.md` / `tasks.md` 四件齐全，即 C3.4「四件套落盘」与 C4.5「归档后用最终版覆盖」在效果上已完成；但 `openspec/changes/archive/` 下只有 5 个非 jit 条目，仓内也没有其它 jit 变更的归档记录，因此「归档」在本仓到底指 `openspec archive` 还是「镜像到 `doc/spec/`」无法从文档判定。缺的是归档落点的定义。
- **描述**：这是本变更唯一未勾选项。下一轮若按「存在未完成项」回看，会误以为该变更是半成品；实际它已被 `jit-function-resource-close`（`close` / `isClosed` 改名）整体取代（对照 `tasks.md:21` 的 `unloadFn` 与现源码 `JitFunction.cj:294` 的 `closeClosure`）。旧名残留的检索面已由 part15 #9 报出，此处只记状态不一致。
- **建议**：勾选 C4.5 并在文件头加一行「已被 `jit-function-resource-close` 取代（`unload*` → `close*`），仅作历史记录」；若确未执行 `openspec archive`，把该项改为「不适用」并说明本仓归档口径。

### [一般][存量] `jit-function-resource-close` 的 delta spec 把 `close()` 写成无条件卸载，缺「存在在飞调用时静默不关闭」这一分支

- **位置**：`f_jit/doc/spec/jit-function-resource-close/specs/f-jit-facade-bridge/spec.md:5`（Requirement）、`:7-10`（Scenario「入口实例关闭」）
- **来源**：存量（spec 与实现同属 `5c5dfb6ec`）
- **判据**：review-checklist §13（文档承诺与实现相反）+ §3（公开契约承诺有行为、实现可空转）
- **证据**：静态确定 —— spec 写「入口实例的 `close` SHALL 卸载单元（终态、逐出缓存、级联释放逃逸闭包）」，Scenario 写「WHEN 调用 `close()` 或 `close(timeoutMs)` THEN 单元进入终态」；实现 `close()` 体为 `let _ = this.close(0)`（`JitFunction.cj:523-525`），`close(0)` 在 `active != 0` 时第一次判空失败即 `state = 0` 回退并 `return false`（`JitFunction.cj:234-243`），返回值被丢弃。
- **描述**：代码侧后果（`try-with-resource` 下漏释放、调用方拿不到任何信号）已由 part15 #1/#3 记录，此处只记**文档面**：Requirement 与 Scenario 都没有「存在在飞调用」这一分支，而 `design.md:32` 却把它写成「已知边界」。按 spec 编写测试的人会写出「并发调用未返回时 `close()` 后 `isClosed()` 为真」这类必然失败的用例；按 spec 写调用方的人会以为 `Resource.close()` 一定完成释放。
- **建议**：Requirement 补条件句「无在飞调用时 SHALL 进入终态；存在在飞调用时 SHALL 保持可用（`isClosed()` 为 false、后续调用仍成功），该情形由 `close(timeoutMs)` 显式表达」；Scenario 增加一条「一次调用未返回时 `close()` → 单元仍可用、`isClosed()` 为 false」。

### [轻微][存量] `makeRetUnboxer` 只剩测试引用却保留 `public`，而 `optimize-call-alloc2` 以「测试在用」作为保留理由

- **位置**：`f_jit/doc/spec/optimize-call-alloc2/verify.md:14`、`proposal.md:17`；符号 `f_jit/src/CallMarshal.cj:41`（`protected class CallMarshal`）、`:187-190`
- **来源**：存量（`a05c5df7f`）
- **判据**：review-checklist §1「仅测试使用 → 可见性建议（不算死代码）」
- **证据**：静态确定 —— `CallMarshal` 是顶层 `protected` 类，其 `public` 成员对外不可达；`makeRetUnboxer` 的 8 处引用全在 `*_test.cj`（`CallMarshal_test.cj:97/101/105/133/169/187`、`CallMarshalAny_test.cj:90`、`JsonBridge_test.cj:93`），生产路径走 `unboxRet`（`JitFunction.cj:650`）。
- **描述**：验证记录把「测试在用」当成保留一个已被判定为纯开销形态（现建闭包 + 一次间接调用）的理由，等于让产品类为测试便利背一个 `public` 入口；后续读者会把 `makeRetUnboxer` 误认成对外契约。
- **建议**：把 `{ cell => this.unboxRet(t, cell) }` 下沉到测试侧（或测试直接调 `unboxRet`）后删除；若必须保留，收窄为 `internal` 并注明「测试辅助，非契约」。

## 优化可行性方案

> 本部分无 `.cj`，不产生新的堆内存 / CPU 方案。文档中已有的「不做」判定（`optimize-arg-staging`、`optimize-call-alloc2`、`optimize-call-path-phase1` P1.3）均带数据或明确回滚，本轮不推翻、不新增方案。

## 待验证假设

> 本部分为文档部分，未提出新的热点主张。下列三条是「文档数据不足以复核其自身结论」的补测项，**不进 `todo.md` / `tasks.md`**。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 窗口池复用收益（601 → 236–430 ns）在同一构建机上可复现，且不会因 `Win` 复用引入抖动 | `f_jit/doc/spec/optimize-call-alloc/verify.md:9-25` | 5 次中位数与离散度 `d`；复用 vs new 的同轮配对 | 同一 commit、`-O2`、`cjpm test --filter 'CallPathBench_test*' --parallel 1` 跑 5 轮，按 `MOV = max(3%, 2d)` 重算 |
| 2 | `optimize-call-alloc2` 的「快模式 / 慢模式」由 VM 负载决定，而非代码路径差异 | `f_jit/doc/spec/optimize-call-alloc2/verify.md:5-12` | 慢模式改前基线、`uname -a` / `load average` / 是否 `taskset` | 同机同场景 5 次，逐轮记录 load 与 L1，看 2975 ↔ 5516 是否与 load 同步 |
| 3 | `RuntimeEnv.current()` 单次 TLS 成本确为 ~300 ns（`optimize-arg-staging` 否决实参暂存区的唯一硬依据） | `f_jit/doc/spec/optimize-arg-staging/design.md:18`、`verify.md:26` | 同 SDK 同机 `-O2` 下单次 TLS 的中位数与离散度 | 微基准：循环 1e7 次 `RuntimeEnv.current()`（`RuntimeEnv.cj:36-44`），5 轮取中位数；同法测 `MachineEnv.fnTableBase` getter 作对照 |

## 文件覆盖

> 与 `reviews/202611280854_full-repo/files/f_jit.part16.txt` 一一对应（20 行）。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_jit/doc/spec/jit-closure-unload-cascade/tasks.md` | .md | ✅ | 9 条用例名全部在源码命中；C4.5 状态见发现 #6；`unload*` 旧名见 part15 #9 |
| 2 | `f_jit/doc/spec/jit-function-resource-close/design.md` | .md | ✅ | `Resource` 免 import 与 `f_store` 一致；`close()` / `isClosed()` 签名与 `JitFunction.cj:523/471` 一致 |
| 3 | `f_jit/doc/spec/jit-function-resource-close/proposal.md` | .md | ✅ | BREAKING 三项均已落地（`unload*` 已无 public 定义） |
| 4 | `f_jit/doc/spec/jit-function-resource-close/specs/f-jit-facade-bridge/spec.md` | .md | ✅ | 4 条 Requirement 与 `close`/`isClosed`/`closeClosure` 实现一致；`close()` 承诺范围过宽见发现 #7，代码侧语义见 part15 #1/#3 |
| 5 | `f_jit/doc/spec/jit-function-resource-close/tasks.md` | .md | ✅ | R1–R8 均有代码落点；R6 用例数 1153 与 design §4 一致 |
| 6 | `f_jit/doc/spec/optimize-arg-staging/design.md` | .md | ✅ | 拆解合计不闭合，见发现 #5 |
| 7 | `f_jit/doc/spec/optimize-arg-staging/proposal.md` | .md | ✅ | 「不做」的判定规则与 design 一致 |
| 8 | `f_jit/doc/spec/optimize-arg-staging/tasks.md` | .md | ✅ | A1–A3 与 verify 数据同源（同一条核算错误，见 #5） |
| 9 | `f_jit/doc/spec/optimize-arg-staging/verify.md` | .md | ✅ | 见发现 #5（分母口径 3.5–6 µs vs 8977 ns） |
| 10 | `f_jit/doc/spec/optimize-call-alloc/design.md` | .md | ✅ | `freeWins` / `acquireWin` / `recycleWin` 均已落地；`pins` 因果错误见发现 #1 |
| 11 | `f_jit/doc/spec/optimize-call-alloc/proposal.md` | .md | ✅ | 风险段复述了同一错误因果（发现 #1） |
| 12 | `f_jit/doc/spec/optimize-call-alloc/tasks.md` | .md | ✅ | 用例数与变异靶子不一致，见发现 #4 |
| 13 | `f_jit/doc/spec/optimize-call-alloc/verify.md` | .md | ✅ | 样本不对称与收益区间，见发现 #3；`pins` 结论见 #1 |
| 14 | `f_jit/doc/spec/optimize-call-alloc2/proposal.md` | .md | ✅ | `CallMarshal.cj:188` / `EMPTY_CELLS`（`JitFunction.cj:93`、`:617-620`）均对得上；`makeRetUnboxer` 保留理由见发现 #8 |
| 15 | `f_jit/doc/spec/optimize-call-alloc2/tasks.md` | .md | ✅ | K1–K4 与 verify 对应；K1.1 只记 L1/Q1，缺慢模式基线（发现 #2） |
| 16 | `f_jit/doc/spec/optimize-call-alloc2/verify.md` | .md | ✅ | 见发现 #2 |
| 17 | `f_jit/doc/spec/optimize-call-path-phase1/design.md` | .md | ✅ | D1 `HostFault`、D2 `FieldSnapshot` 与实现一致；D3 已声明回滚（`enterPauseHook` 全仓 0 命中） |
| 18 | `f_jit/doc/spec/optimize-call-path-phase1/proposal.md` | .md | ✅ | 百分比复核通过（+127.4% / −40.2% / −87.2%）；gen 缺陷已在 `HandleTable.cj:1148-1150` 以退休处置修复 |
| 19 | `f_jit/doc/spec/optimize-call-path-phase1/specs/f-jit-runtime/spec.md` | .md | ✅ | 不可变快照 / 线程本地 cause 两条 SHALL 均与 `HostField.cj:70-138`、`HostCall.cj:229-266` 一致 |
| 20 | `f_jit/doc/spec/optimize-call-path-phase1/tasks.md` | .md | ✅ | P0–P5 与 design 的 keep/revert 结论一致；A4 已由 `fix-handle-gen-exhaustion` + phase2 接手 |

合计：`.cj` 0 个 / `.md` 20 个 / 共 20 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 0 | 本部分无源码，无逻辑/边界/注入面可判。文档侧的正确性问题按 §13 计（#1/#2/#3/#5/#7）；`Resource` 免 import、`AtomicReference` 发布、`ThreadLocal` 用法三处语言特性已对照 `f_store` 与本地 std 签名核过 |
| §1 死代码 | 1 | 本部分 0 个 `.cj`，无声明面。反向核对文档引用的符号是否已删：`freeWins`/`acquireWin`/`recycleWin`（`HandleTable.cj:225/239`、`RuntimeState.cj:47`）、`unboxRet`（`CallMarshal.cj:198`）、`FieldSnapshot`（`HostField.cj:70`）、`closeClosure`（`JitFunction.cj:294`）全部存在；命中 1 条为 `makeRetUnboxer` 仅测试引用（#8，可见性建议，不计死代码）；`unload`/`unloadFn`/`isUnloaded` 的旧名残留归 §13，已由 part15 #9 记录，不重复计 |
| §2 重复逻辑 | 0 | 逐份比对 6 个变更的 design↔proposal↔tasks↔verify 复述段：同一数据在 3–4 份文档各写一遍属 SDD 结构（提案→设计→任务→验证），差异是读者层次不是语义漂移，不判重复。复述带出的**口径不一致**已按 §13 报（#1/#4/#5），不重复计 |
| §3 空实现 | 0 | 逐份检查无空章节 / `TODO` / 「暂不处理」。`optimize-arg-staging` 与 P1.3 是「测了、判不做」的完整记录（有测量项、判定规则、重做条件），不是占位 |
| §4 栈溢出 | 0 | 6 个变更均未新增递归结构；文档唯一涉及的递归点（闭包图提升）不在本部分文件内，已在 part15 核过有 `visited` 防环 |
| §5 OOM | 0 | 本部分唯一涉及容器上限的承诺是 `freeWins ≤ 8`，实现为有界池（`HandleTable.cj:240` + `RuntimeState.cj:47`），无无界缓存/无界登记表承诺 |
| §6.1 热点瓶颈 | 0 | 本部分提供的都是历史测量记录，不是本轮 profile 结论；我对这些数据只做**自洽性**核对（#2/#3/#5），未提出任何新热点主张。缺 `cjprof` / 同环境 5 次对照的部分已转「待验证假设」#1/#2 |
| §6.2 大粒度锁 | 0 | 文档描述的锁改造均有落点且与实现一致：`HostFieldTable` 读写分离为「写锁内 COW + `AtomicReference` 发布」（`HostField.cj:86-118`）、`HostFault` 改为线程状态内表（`HostCall.cj:229-266`）。无锁内 I/O / 序列化 / 回调的承诺 |
| §6.3 并发串行 | 0 | 6 个变更均无 `spawn` + 立即 `get()` 或单消费者队列的设计；`optimize-call-path-phase1` 明确把并行度问题放在 `Q4/Q1` 指标上，未承诺串行段消除 |
| §6.4 低效算法 | 0 | 文档提到的 `Win` 池取用是 `remove(at: size-1)`（O(1) 尾删，`HandleTable.cj:227`），不是 `remove(at: 0)`；无嵌套循环/热点 `contains` 主张 |
| §7 降堆内存方案 | 0 | 本部分为测量/判定记录，无新的「还能省多少」主张；`freeWins ≤ 8` 已是既定优化，收益在 CPU 侧（GC 分配），不在堆峰值 |
| §8 降 CPU 方案 | 0 | 三项候选都已给出判定：窗口池 keep、`CallMarshal` 两表与 `cells` 明确「留待单独评估」（`optimize-call-alloc/verify.md:53-56`）、实参暂存区「不做」。三者均已有决策记录，不重复提方案 |
| §9 local mode 可行性 | 0 | 本部分无函数级临时大对象；`Win` 池、`FaultEntry`、`FieldSnapshot` 都是跨调用存活/跨线程发布的结构，逃逸检查不成立 |
| §11 现有代码的 BUG（存量） | 0 | 本部分 0 个 `.cj`，缺陷只在文档引用的实现点上取证：`close` 竞态、自旋超时、`close(): Unit` 丢结果已在 part15 #1–#3，其**文档面**（spec 无条件承诺卸载）记在 #7；`HostFault`/`HostField`/`Win` 池三处实现与规格逐条对齐，未发现新缺陷 |
| §12 并发安全与锁粒度 | 0 | 已核对的共享点：`HostFault`（改为 `RuntimeState.faults`，线程封闭，delta 规格 `spec.md:43` 的「跨线程读得到无记录」成立）、`HostFieldTable.current`（`AtomicReference` 整对象发布，读方无锁无拷贝）、`Win`/`freeWins`（`RuntimeState` 字段，线程私有）。本部分文档侧未见新增共享可变状态承诺 |
| §14 功能完备性与 README 覆盖 | 0 | README 不在本部分文件清单内。spec delta 的 4 条 Requirement（资源生命周期 / 统一调用包装 / H64-H65 / 宿主异常）与实现逐项对齐，未发现「承诺但未实现」；语义收窄项已由 part15 记录，不重复计 |
| 文件覆盖（§13 等） | 20/20 | 20 个 `.md` 全部读完；无跳过、无抽样 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 3 |
| 轻微 | 5 |
| 优化方案（堆内存 / CPU） | 0 / 0 |

## 总评

这 20 份文件是 `f_jit` 的 SDD 过程文档（proposal / design / spec delta / tasks / verify），不是使用文档，因此风险不在「用错 API」，而在**数据与因果的可信度**：下一轮性能工作会把这里的 `verify.md` 当基线读。

- **必须订正的（一般 3 条）**：`optimize-call-alloc` 的 `pins` 因果错误（design/proposal 与 verify 结论相反，且与 `resetWindow` 只释放 `appendIds` 的实现相反）；`optimize-call-alloc2` 的快/慢模式混表——`+2.3%` 无基线、两轮相差 85% 却称「噪声内」，按项目自己的 `d ≥ 10%` 规则这组数据不足以支撑任何判定；`jit-function-resource-close` 的 delta spec 把 `close()` 写成无条件卸载，缺「在飞调用时静默不关闭」分支（代码侧已由 part15 记录）。
- **可排期的（轻微 5 条）**：收益区间写大（−300~370 vs 实际 −171~−365）且 W4.1 的 `Q4` / ≤300 ns 判据无数据、`WindowPool_test` 用例数与变异靶子对不上、394 ns 拆解不闭合、`jit-closure-unload-cascade` 归档项未勾选、`makeRetUnboxer` 仅测试引用仍为 `public`。
- **代码侧**：本部分无源码，未新增代码缺陷；文档引用的三处实现（`HostFault` 线程本地、`HostField` 不可变快照、`Win` 池有界复用）与规格一致，`HandleTable` 的 16 位 gen 阻断也已按退休处置修复（`HandleTable.cj:1148-1150`），文档中「需单独立项修复」的表述属历史记录，不算漂移。

存量 8 条，是否纳入修复待用户决定。整体质量：决策记录的可读性与「为什么不做」的留痕做得好，短板集中在**同一变更内多份文档的数字/结论没有在收口时对齐**，以及**契约文本比实现宽**（`close()` 那条会被当成测试与用法的依据）——建议归档前把 design 与 verify 的数值表逐项对账，并把 spec 的 `close()` 条件补全。另：`optimize-arg-staging` 的「不做」全部押在「TLS ≈300 ns」这一条无基线数据上（待验证假设 #3），若实测 <30 ns，该判定需按 `design.md:23-29` 的重做条件重审。

**范围外提示**：`f_jit/doc/design-m2.md:398`（M2-8 裁定行）与 `f_jit/doc/jit-bytecode-m2.md:518-521`（§14.3 括号注）仍写「非闭包包装实例：`close` → 19、`isClosed` = false；`unload` 仍为单元级」，与现行 `JitFunction.close()`（入口即卸载单元）相反，不在本部分文件清单内，留给对应部分处理。
