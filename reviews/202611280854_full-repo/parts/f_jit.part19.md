# f_jit 模块审查报告（第 19/38 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_jit`（本部分 20 个文件，全部为 `doc/spec/**` 变更规格：`optimize-helper-table`、`optimize-jitcontext-pool`、`optimize-loop-safepoint`、`optimize-marshal-rs`、`optimize-runtime-tls`、`optimize-signature-tables`）
- **基线**：工作区快照（sts/1.3.x 工作区，未对照远端目标分支；无 diff ⇒ 全部问题记「存量」）
- **审查重点**：动态调用/桥接正确性（typecode 分支表）、句柄与资源生命周期、并发安全、递归与栈溢出、死代码、重复逻辑、存量 BUG
- **报告版本**：v1（本部分分报告，最终由主 Agent 合并进 `docs/review/2026-11-28/f_jit.md`）
- **本部分性质**：20 个文件全为 `.md`（5 组「proposal / design / tasks / verify」四件套 + `optimize-helper-table` 的 verify 单件），无 `.cj`。故本部分的审查方法是「**规格声称 ↔ 代码事实双向取证**」：每条断言（落地的符号、发射序列、寄存器、判定数字、用例名、回退状态）都回到 `f_jit/src` 与同组其它文档现场核对。

## 发现

### [一般][存量] `optimize-loop-safepoint` 的 x86 侧把 ctx 寄存器写成 `rdi`，与代码、测试、同组 verify 全部相反

- **位置**：
  - 文档：`f_jit/doc/spec/optimize-loop-safepoint/design.md:75`（`mov rax, [rdi+48]      // ctx.flags（x86 侧 ctx 在 rdi）`）、`proposal.md:36`（`mov rax,[rdi+48]`）、`tasks.md:36`（`mov rax,[rdi+48] / mov rdx,8 / test rax,rdx / jz skip`）
  - 代码事实：`f_jit/src/backend/X86Lower.cj:29`（`约定：r15 = ctx、rbp = 帧指针、rsp = 操作数栈顶`）、`X86Lower.cj:1038-1041`（回边用 `noteMemBase(15)` + `emitCtxFlagsToRax()`）、`X86Lower.cj:412`（`movImm(7, hid)` —— `rdi` 在 x86 侧是 helper 的 hid 实参）
  - 同组反证：`f_jit/doc/spec/optimize-loop-safepoint/verify.md:10`（`mov rax,[r15+48] → test rax,8 → jz 跳过`）、`verify.md:27`（字节断言 `498B4730` = `mov rax,[r15+0x30]`）、`f_jit/src/backend/X86Lower_test.cj:65-66`、`f_jit/doc/optimize-call-path.md:435`
- **来源**：存量（快照模式无 diff；三处文本均为该变更 2026-11-27 归档时写入）
- **判据**：review-checklist §13（示例代码不能用 / 文档与实现相反）
- **证据**：静态确定 —— `0x30 = 48` 且 ModRM `47` 的 base 是 `r15`，`498B4730` 只可能是 `mov rax,[r15+48]`；`rdi`（`rdi` 编码 base=7）在该后端的约定是 helper 第一实参，`X86Lower.cj:412/450` 分别用它传 `hid` 与 ctx（`movReg(7, 15)`）。三份文档与代码、测试、同变更 verify 全部矛盾，不是编码歧义。
- **描述**：按 design/proposal/tasks 的序列实现，回边会读 `[hid+48]` 而不是 `ctx.flags`：hid 是小整数（`0x0100+` 量级），解引用会读到非法地址或无关内存，`test` 结果与 deadline 无关。两种后果都错：恒不置位则带 deadline 的循环**永不被中断**（安全点失效，无限循环无法取消）；偶发置位则无期限循环被误中断/误 deopt。同一变更的 verify 与字节断言却是对的，说明只有三份"设计侧"文本没跟着实现走。
- **建议**：三处统一改为 `mov rax,[r15+48]`；同时把 `design.md:10` 的 `X86Lower.cj:1032` 绝对行号改成符号引用（该行现在是 `movQwordCtx(0, -1)` 的 deopt 分支，回边 poll 已移到 `:1035-1045`），避免下次再按行号找不到位置。

### [一般][存量] `optimize-runtime-tls` 的 design 仍以「`ctx.flags` 开 ITER/FAULT 两位」为实现，实际落地方案已被同组 tasks 改成字段门控

- **位置**：
  - 文档：`f_jit/doc/spec/optimize-runtime-tls/design.md:43-55`（§D3 标题「`IterTable` / `HostFault` 用 `ctx.flags` 门控」，`:50` bit4=ITER、`:51` bit5=FAULT）、`design.md:113`（「3. `RuntimeStateFlags_test`：健康调用不置 `ITER/FAULT` 位…」）、`proposal.md:37`
  - 同组反证：`tasks.md:25-26`（T2.4「门控改为**字段检查**（`rs.iters` 为空 / `rs.faults` 为 None）而不是新增 ctx flags 位」）、`tasks.md:51`（T6.1「不新增 ctx flags 位」）、`verify.md:61-63`
  - 代码事实：`f_jit/src/runtime/JitContext.cj:72-86`（`CtxFlags` 只有 `STRICT_FP/TRACE/HAS_LOOP/DEADLINE` 四个常量，无 ITER/FAULT）、`f_jit/src/runtime/RuntimeState.cj:50`（`iters: IterState`）、`:53`（`faults: ?HashMap<...> = None`）；仓内无 `RuntimeStateFlags_test.cj`（`ls src` 无此文件，`grep -rn "RuntimeStateFlags_test" --include=*.cj` 0 命中，该名字只出现在 design.md 自己）
- **来源**：存量（归档时 design 未按 T2.4/T6.1 的决策变更回填）
- **判据**：review-checklist §13（文档承诺与实现相反）+ §14.1（承诺了但没实现）
- **证据**：静态确定 —— 位定义表、消费时机表、新增护栏用例三者都不存在；同组 tasks 与 verify 明确写了相反方案，且代码与 tasks/verify 一致。属"文档内部结论相反"，不是缺信息。同一份 design 的 D2 字段表（`design.md:21-28`）还漏了两个实际存在的字段：`freeWins`（`RuntimeState.cj:47`，池化空闲 `Win`）与 `freeHint`（`:56`，`popFree` 的提示），而 `tasks.md:30`（T3.1）的字段清单里明确有 `freeHint` —— 字段级同样停在实施前版本。
- **描述**：一处设计决策在实施中被替换（flags 位 → 判空字段），但 design 正文、位域表、D7 护栏清单、变异验证（`:119`「去掉 `ITER` 门控（恒清）⇒ …」）全部保留旧方案。后果是双重的：后续若照 D3 实现，会在冻结的 64 B ctx 上多开两位（`CtxFlags` 注释与 `jit-bytecode-m1.md` §1 都按位域冻结管理）；按 D7 去找 `RuntimeStateFlags_test` 的人会扑空，误以为护栏缺失。（同类偏差：`design.md:32` 写 `internal static func current()`，代码 `RuntimeEnv.cj:36` 是 `public static func current()`——按仓内「源码写 public、模块内按 protected 收口」约定等价，不单独计数。）
- **建议**：在 design §D3 顶部加一行决策变更横幅（「实施时改为字段门控：`rs.iters` 空 / `rs.faults` 为 None，不新增 flags 位，见 tasks T2.4/T6.1」），把位域表与 D7 第 3 条删除或标「未采用」，`:119` 的变异说明改指向 `IterLifecycle_test`/`HostFaultTls_test`（verify §5 已是这个口径）。

### [轻微][存量] `optimize-signature-tables` 的 design D2/D4 仍以 `byKey` 键索引写伪代码，与 D1 结论、实现、proposal 表格相反

- **位置**：
  - 文档：`f_jit/doc/spec/optimize-signature-tables/design.md:64-71`（`SigSnapshot { entries; let byKey: HashMap<String, Int32> }`）、`:84-112`（D4 的 `getOrBuild` 全程 `snap.byKey.get(k)` / `copy(s2.byKey)` / `PlanSnapshot(plans, byKey, builds)`）、`design.md:119`（风险表自己写「最终实现不含键，直接复用 `sameShape`」）、`proposal.md:1`（标题「不可变快照 + 结构键索引」）、`proposal.md:26`
  - 代码事实：`f_jit/src/base/HostSignature.cj:111-117`（`SigSnapshot` 只有 `entries`）、`f_jit/src/runtime/SignaturePlan.cj:119-127`（`PlanSnapshot` 只有 `plans`/`builds`）、`SignaturePlan.cj:145-152`（命中路径是 `while + sameShape` 线性扫）
  - 同组反证：`verify.md:8`（「`AtomicReference<PlanSnapshot>`（含 `builds`）」）、`verify.md:23-35`（键索引版 790/554 ns 被否决）
- **来源**：存量（D1 在实施中反转后，D2/D3/D4 的代码块未改，只有「原 D1 草案」一节被标注为不采用）
- **判据**：review-checklist §13（示例/设计描述与实现相反）
- **证据**：静态确定 —— 两个快照类的实际字段与 D2/D4 伪代码逐字段对比即知；`byKey` 在全仓 0 处使用（`grep -rn "byKey" f_jit/src` 无命中）。
- **描述**：D1 用实测（`adapterOf` 349 → 790 ns）否决了键索引，并在 D2/D3 保留了旧 `SigSnapshot` 与 `byKey` 写时复制伪代码；D4 的 `getOrBuild` 也仍以 `byKey` 为第一判据。读者若按 D4 实现，会重现实测到的 −2.3 倍退化，并让 `MAX_ENTRIES` 之外的 `builds:+1` 语义与现状（不缓存但计数）分叉。proposal 的标题/总述句同样停留在被否决的方案上，只有正文 §实施中发现 一段纠正。
- **建议**：D2/D4 的代码块替换为与 `SignaturePlan.cj:141-182` 等价的线性扫版本（或整段加「已否决，仅存档」标记）；`proposal.md:1` 标题改「不可变快照（无键索引）」，`:26` 那句删掉「结构键 `HashMap`」。

### [轻微][存量] `optimize-marshal-rs` 的 verify 用例数与全量数与 tasks 不一致（verify 写于第 5 条用例加入之前）

- **位置**：
  - `f_jit/doc/spec/optimize-marshal-rs/verify.md:44`（「新增 `MarshalRs_test` **4 条**」）、`:46`（「全量 **1235/1235**」）
  - 同组反证：`tasks.md:13-14`（M2.1「`MarshalRs_test` **5 条**」）、`tasks.md:41`（M5.3「恢复后 5 条全绿」）、`tasks.md:45`（M6.1「全量 **1236/1236**」）、`tasks.md:47`（`[ ] M6.3 归档…提交并推送` 未勾选）
  - 代码事实：`f_jit/src/MarshalRs_test.cj:47/59/72/91/105` 五个 `@TestCase`（`valueCallsStayCorrect`、`stringArgRoundTrip`、`hostObjectRoundTrip`、`contractFailureLeavesNoResidue`、`droppedArgIsReleasedByCleanup`）；verify 自己在 `:53` 引用第 5 条 `droppedArgIsReleasedByCleanup`
- **来源**：存量（快照模式；verify 定稿早于 M5 补的第 5 条用例）
- **判据**：review-checklist §13（同一变更内记录互斥）
- **证据**：静态确定 —— 用例数可直接数 `@TestCase`；verify 同文件内 §4 说 4 条、§5 引用第 5 条，自相矛盾。
- **描述**：`MarshalRs_test` 的实际条目是 5 条（第 5 条是变异验证补的），verify §4 的「4 条 / 1235」是补测前的快照；tasks 的「5 条 / 1236」才对。另 M6.3（归档+提交）未勾选，而 `doc/spec/optimize-marshal-rs/` 已镜像存在——归档是否真的完成无法从仓内判定（`待确认`）。
- **建议**：verify §4 回填为 5 条、`:46` 改为 1236/1236；M6.3 补勾或写明当前状态（未归档则注明镜像目录为预放置）。

### [轻微][存量] `optimize-jitcontext-pool` 的 proposal 无「已回退」标记，且引用了不含该断言的测试文件作为口径依据

- **位置**：
  - `f_jit/doc/spec/optimize-jitcontext-pool/proposal.md:1-48`（全文仍以「What Changes / Impact / 预期收益 L1 −7~10%」陈述）
  - 同组反证：`tasks.md:1`（「（实验后 **revert**）」）、`:9-10`（T2.4 不 adopt、T2.5 代码全部回退）、`verify.md:5`（「**不 adopt。**」）、`verify.md:32-41`（回退清单）
  - 证据性错误：`proposal.md:29-36` 称「现有 `ParallelCall_test` / `T40Account_test` 等十余处「`outstanding() == base`」断言」；实际 `f_jit/src/runtime/T40Account_test.cj` 中 `NativeMem` / `outstanding` 出现 **0 次**（`grep -n "NativeMem\.\|outstanding" src/runtime/T40Account_test.cj` 无输出），全仓 `outstanding()` 共 13 处——其中 12 处落在 6 个测试文件（`Lifetime_test`、`ParallelCall_test`、`Q6Acceptance_test`、`runtime/DbgDump_test`、`runtime/HostCallTrampoline_test`、`runtime/JitContext_test`），另 1 处是 `JitContext.cj:61` 的定义）
  - 代码事实（回退已生效，与 tasks/verify 一致）：`f_jit/src/runtime/JitContext.cj:170`（`LibC.malloc<Int64>(count: WORD_COUNT)`）、`:194-203`（`free` 直接 `LibC.free`，无池）；`NativeMem`（同文件 `:1-64`）无 `realMallocCount` / `residentBlocks`（`grep` 0 命中）
- **来源**：存量（proposal 为实验前文档，回退结论只写在 tasks/verify）
- **判据**：review-checklist §13（文档过期 / 与结论相反）、§11（决策依据与事实不符）
- **证据**：静态确定 —— 回退状态、代码现状、`T40Account_test` 内容均可直接核对。
- **描述**：三份文档同目录、proposal 排在最前，读者先看到的是「收益 13.7% 的 malloc/free 占比、预期端到端 −7~10%」，没有任何「已实测否决」的提示；实际结论是池化让 L1 变慢 6–15%。这类"只有结论页纠正、动机页照旧"的目录，最容易被后续复用为「已评估可做」的依据。另外，proposal 用「十余处 `outstanding()==base` 断言」支撑「借出口径」这一关键决策，但点名的 `T40Account_test` 里一条都没有（该文件断言的是 `HandleTable.windowUsed()` 与 T40 账目），决策依据被夸大。
- **建议**：标题改「`JitContext` 线程私有池化（实验后回退，未采纳）」，并在 Why 首段加一行「结论见 `verify.md`：C1 降 14% 无法传导到 L1，两个版本均变慢，代码已回退」；把 `T40Account_test` 换成实际含该断言的文件（`ParallelCall_test` / `Lifetime_test` / `Q6Acceptance_test`）。

### [轻微][存量] `optimize-signature-tables` 的 tasks 点名 `SignatureRegistryVerification` 测试类，仓内不存在

- **位置**：
  - 文档：`f_jit/doc/spec/optimize-signature-tables/tasks.md:15`（S2.1「`SignatureRegistryVerification` 六条」）、`:24`（S2.3 又写「`JitHost_test` / `Signature*`」，口径不同）
  - 代码事实：六条用例实际在 `f_jit/src/SignatureTableConcurrency_test.cj`（类 `@Test` 于 `:35`，用例 `registerIsIdempotent:49`、`idsAreDistinctAndOrdered:58`、`classNameDistinguishes:71`、`lookupsAgree:85`、`concurrentRegisterAndFind:100`），加 S2.2 的 `planIsBuiltOnce:155`、`planRespectsSwitch:169` 共 7 条
  - 同组反证：`verify.md:9`（新增文件写的是 `src/SignatureTableConcurrency_test.cj`）、`verify.md:39-47`（7 条用例名与该文件逐一对应）
- **来源**：存量（任务清单按设计时的假想类名写，落地时合并成一个测试类后未回填）
- **判据**：review-checklist §13（名称与源码不符）
- **证据**：静态确定 —— 全仓 `grep SignatureRegistryVerification` 在 `.cj` 中 0 命中，该名字只出现在 `tasks.md` 自己。
- **描述**：按 tasks 去检索「六条护栏」会得到「文件不存在」，从而误判 S2.1 未落地；实际六条全在，只是与 `SignatureTable` 的四条合并在同一个测试类里。同一页的 S2.3 又换成通配 `Signature*`，同一文档内三种口径。
- **建议**：S2.1 改为「`SignatureTableConcurrency_test` 前六条」，S2.3 的名册改为实际存在的 `JitHost_test` / `HostSignature_test` / `SignatureTableConcurrency_test`，与 verify 的文件名口径统一。

## 优化可行性方案

> 本部分 20 个文件均为变更规格与验证记录，不含可改造的实现代码；本轮不产出堆内存 / CPU 方案（0 / 0）。文档内部已记录的残留项（`optimize-marshal-rs/verify.md:68-70`：`escape + getAs + releaseEscaped` 约 0.5 µs、`append` 仍需一次 `current()`、编译 25–48 ms 未分段）都没有改前/改后对照，按铁律只能进「待验证假设」，不列为方案。

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 编译段（25–48 ms）仍占端到端大头，且未定位到具体阶段 | `f_jit/doc/spec/optimize-marshal-rs/verify.md:70` | 前端扫描 / AST 分配 / 降低 / 发射各段自耗时占比 | 对 `JitFunction` 首次编译路径分段计时或 `cjprof record`，输入 200 个不同源码单元，取 5 次中位数；与同机 `L1` 对照 |
| 2 | x86 回边「按需 poll」只在字节层验证过，实机收益与语义均未测 | `f_jit/doc/spec/optimize-loop-safepoint/verify.md:53` | x86_64 实机的空循环 ns/轮与有期限中断行为 | x86_64 机器上跑 `LoopSafepoint_test`（3 条）与 `X86Lower_test.loopBackPollGate`，`-O2`、`taskset` 绑核，记录改前/改后每轮 ns 与 `InterruptedException` 命中 |
| 3 | 各组记录的全量用例数（1214 / 1221 / 1224 / 1235 / 1246）与仓内 `@TestCase` 计数对不上（`057097229` 时 1259、HEAD 1278），疑为计数口径差异而非数据错误 | `optimize-helper-table/verify.md:43`、`optimize-loop-safepoint/verify.md:45`、`optimize-signature-tables/verify.md:53`、`optimize-runtime-tls/verify.md:46`、`optimize-marshal-rs/verify.md:46` | `cjpm test` 的计数口径（是否含 `@Disabled` / 是否按 `@Test` 类聚合 / 是否只统计被编译目标） | 同 SDK 跑一次 `cjpm test --parallel 1`，把报告 total 与 `grep -c '@TestCase'` 逐文件对齐，差值定位到具体类；确认后在各 verify 注明口径 |

## 文件覆盖

> 与 `files/f_jit.part19.txt` 一一对应。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_jit/doc/spec/optimize-helper-table/verify.md` | .md | ✅ | 核心声称已核：`pushTable` 只入栈不建表（`src/runtime/UserHelper.cj:82-85`）、`helperTableCache` 在 `bindUserHelpers` 建一次（`src/JitFunction.cj:401-406`）、3 条护栏用例存在（`src/HelperTableScope_test.cj:53/66/83`）；A/B 算式自洽（(103−11.7)/204 ≈ 447 ns/项；204 项时 103→3.97 µs）。`design.md` 不在本部分，`§3 TDD 例外` 的引用未展开 |
| 2 | `f_jit/doc/spec/optimize-jitcontext-pool/proposal.md` | .md | ✅ | 方案与回退状态相反，见发现 #5；`T40Account_test` 依据不成立，同见 #5 |
| 3 | `f_jit/doc/spec/optimize-jitcontext-pool/tasks.md` | .md | ✅ | 全 [x]，明确「不 adopt + 代码全部回退」；与代码一致（`JitContext.cj:170/194-203` 无池、无 `realMallocCount`） |
| 4 | `f_jit/doc/spec/optimize-jitcontext-pool/verify.md` | .md | ✅ | 三组数据与 `concurrency-audit.md:118` 的「已尝试且无收益」记录一致；回退清单里的 `JitContextPool_test.cj` 确已不存在（`ls src` 无此文件） |
| 5 | `f_jit/doc/spec/optimize-loop-safepoint/design.md` | .md | ✅ | A64 序列与 `A64Lower.cj:363-381` 逐条一致（`ldrOff(0,19,OFF_FLAGS)` / `movImm64(1,DEADLINE)` / `andReg` / `cbz`）；x86 寄存器写错见发现 #1；`:10` 的 `X86Lower.cj:1032` 行号已失效 |
| 6 | `f_jit/doc/spec/optimize-loop-safepoint/proposal.md` | .md | ✅ | 动机数据（658/665/662 vs 15 ns）与 `doc/optimize-call-path.md:406-411` 一致；x86 序列 `rdi` 见发现 #1 |
| 7 | `f_jit/doc/spec/optimize-loop-safepoint/tasks.md` | .md | ✅ | L2.1/L2.2 与代码一致（`CtxFlags.DEADLINE`、`A64Lower` 标签 `sl${next}`）；L4.1 的 `rdi` 见发现 #1；L5.1 只部分落地，见「范围外提示」 |
| 8 | `f_jit/doc/spec/optimize-loop-safepoint/verify.md` | .md | ✅ | 665→15 ns（44×）算式自洽；x86 字节断言与 `X86Lower_test.cj:64-73` 完全一致（`498B4730`/`BA08000000`/`4885D0`/`0F8400000000`）；§7 PerfM2/PerfOverride 改造已核实（`median3` + `rounds` 4000/6000） |
| 9 | `f_jit/doc/spec/optimize-marshal-rs/design.md` | .md | ✅ | D1-D4 与实现一致：`CallMarshal(rs)`（`src/CallMarshal.cj:50`）、`pinned/escaped` 惰性（`:45-46`、`:59-78`）、`HandleTable` 的 `With` 重载与薄包装（`HandleTable.cj:407/453/457/511/575/694/740`）均存在 |
| 10 | `f_jit/doc/spec/optimize-marshal-rs/proposal.md` | .md | ✅ | 数据（3127 ns / 3 次 TLS ≈1.2 µs）与 verify 一致；目标 −0.9 µs / −340 ns 与实测 −7~9% / −13~18% 同量级 |
| 11 | `f_jit/doc/spec/optimize-marshal-rs/tasks.md` | .md | ✅ | M6.3 未勾选，用例数/全量数与 verify 冲突，见发现 #4 |
| 12 | `f_jit/doc/spec/optimize-marshal-rs/verify.md` | .md | ✅ | 用例数 4 vs 5、1235 vs 1236，见发现 #4；§5 对 `droppedArgIsReleasedByCleanup` 的解释与用例语义相符 |
| 13 | `f_jit/doc/spec/optimize-runtime-tls/design.md` | .md | ✅ | D1/D2/D4/D5/D6 与代码一致（`RuntimeEnv.cj:33-46`、`JitFunction.cj:163-178`、`JitExecutor.cj:147-179`）；D3/D7 与落地相反，见发现 #2 |
| 14 | `f_jit/doc/spec/optimize-runtime-tls/proposal.md` | .md | ✅ | 14→2 次 TLS 的分解与 verify §7 的残留口径一致（每次调用 `current()` 1 + `fnTableBase` 1）；`:37` flags 门控见发现 #2 |
| 15 | `f_jit/doc/spec/optimize-runtime-tls/tasks.md` | .md | ✅ | T2.4/T6.1 是「不新增 flags 位」的决策源；T10.4 归档已勾选，`doc/spec` 目录存在，自洽 |
| 16 | `f_jit/doc/spec/optimize-runtime-tls/verify.md` | .md | ✅ | 双峰数据与判定算式自洽（6299/9751 = −35%）；3 条隔离用例存在（`src/RuntimeStateIsolation_test.cj:42/65/100`）；§7 残留与代码一致 |
| 17 | `f_jit/doc/spec/optimize-signature-tables/design.md` | .md | ✅ | D1/D5/D6 与实现一致（无键、`enabled` 仍 `public static var`、`get(id)` 数组索引）；D2/D4 的 `byKey` 伪代码见发现 #3 |
| 18 | `f_jit/doc/spec/optimize-signature-tables/proposal.md` | .md | ✅ | 改动表（两表快照化、`MAX_ENTRIES=128`、语义不变四条）与代码一致；标题与 `:26` 的键索引表述见发现 #3 |
| 19 | `f_jit/doc/spec/optimize-signature-tables/tasks.md` | .md | ✅ | S3.1「不用键索引」与实现一致；S5.1 数据（456/252、484/360、0.94×/0.70×）与 verify 一致；S2.1 的 `SignatureRegistryVerification` 不存在，见发现 #6 |
| 20 | `f_jit/doc/spec/optimize-signature-tables/verify.md` | .md | ✅ | 7 条护栏与 `src/SignatureTableConcurrency_test.cj:49-169` 逐条对应；`probeType` 惰性化已核实（`src/runtime/Signature.cj:388-391`、`:402-408`）；4 线程 1008→159（−84%）算式自洽 |

合计：`.cj` 0 个 / `.md` 20 个 / 共 20 个，全部读完。

> 注：`optimize-helper-table` 在本部分只有 `verify.md`（proposal/design/tasks 不在 `files/f_jit.part19.txt` 内），本文只在覆盖表中记录该件，不把它当整组核对。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 2 | 本部分无 `.cj`，无可执行逻辑；按「文档承诺即契约」把每条可言伪的声称回到源码核对，命中发现 #1（发射序列寄存器）与 #2（门控实现）。typecode 分支表专项：20 个文件里只有 `optimize-runtime-tls` 涉及 ctx 位域，`CtxFlags` 实际 4 个常量已逐个核对（`JitContext.cj:72-86`），无 typecode/`TypeToken` 分支表描述，未命中。语言特性一项：`AtomicReference` 的 `load/store` 语义、`ThreadLocal` 成本均按项目内实测文档引用，未凭记忆断言 |
| §1 死代码 | 0 | 本部分无代码。已机械核对文档点名的全部符号：`CtxFlags.DEADLINE`（`A64Lower.cj:376`、`JitContext.cj:178` 均有读者）、`BackendX86_64.emitCtxFlagsToRax/emitDeadlineMaskToRdx/emitTestRaxRdx/emitJz`（`X86Lower.cj:1039-1042` 调用）、`HandleTable.*With` 8 个新入口与 `openWindow`/`pin` 等 5 个旧薄包装（旧入口只被测试引用——按硬原则属可见性建议，不是死代码）、`SignatureTable.buildCount/entryCount`、`UserHelperTable.pushTable/pop`、`RuntimeState.typeCodeOf` 均有引用；`realMallocCount/residentBlocks/JitContextPool_test` 确认已随回退删除（0 命中），与 tasks T1.1/T2.5 自述一致；文档点名的测试用例名 19 个全部在 `src/**` 命中（`HelperTableScope_test` 3、`LoopSafepoint_test` 3、`MarshalRs_test` 5、`RuntimeStateIsolation_test` 3、`SignatureTableConcurrency_test` 7、`X86Lower_test.loopBackPollGate`、`AnyBridgeCall_test.p0_6_deadlineInterruptsLoop`），唯一落空的是 `tasks.md:15` 的类名 `SignatureRegistryVerification`（记入发现 #6，属命名漂移不是死代码） |
| §2 重复逻辑 | 0 | 已两两比对 6 组规格的「文件角色 → 内容 → 结论」：proposal/design/tasks/verify 是模板分工（动机/方案/步骤/结果），不是同语义复写；`optimize-loop-safepoint` 与 `optimize-runtime-tls` 都改 `JitFunction.call` 的 TLS 访问，但前者是回边 poll 门控、后者是状态合并，改动面不重叠。唯一实质重复是同一组数字（665/15 ns、L1 3502–3758）在 proposal 与 verify 各写一遍，属归档惯例，不建议合并 |
| §3 空实现 | 0 | 本部分描述的改动都有实现：回边门控（`A64Lower.cj:363-381`、`X86Lower.cj:1035-1045`）、ctx flags 写入（`JitContext.cj:174-188`）、`rs` 下传（`JitContext.cj:199`、`CallMarshal.cj:43-56`）、两表快照（`HostSignature.cj:111-202`、`SignaturePlan.cj:119-199`）、helper 表预建（`JitFunction.cj:401-406`）。唯一「做了又撤」的是 ctx 池，已在 tasks/verify 明确标注 revert 且代码确无残留，不算空实现 |
| §4 栈溢出 | 0 | 本部分无代码、无递归结构描述；文档涉及的递归只有 `RuntimeState` 字段链（无自引用）与 helper 栈（`UserHelperTable` 的 `ArrayList` 入栈/出栈，深度=嵌套调用深度，与既有调用栈同阶）。未在本部分文件内命中无界递归承诺 |
| §5 OOM | 0 | 文档承诺的容量面均有界且已在代码核对：`SignatureTable.MAX_ENTRIES=128`（超限不缓存）、`SignatureRegistry` 只增但条目来自启动期注册（个位数）、`ctx` 池的「每线程 ≤4×64 B」方案已回退（不存在常驻）、helper 表按单元缓存（`JitFunction.helperTableCache`）。未命中「只增不减」的承诺 |
| §6.1 热点瓶颈 | 0 | 本部分只有历史测量记录，无本轮 profile；文档中的热点结论（回边 poll 97.7%、TLS 14 次≈4.4 µs、`HostCallback` 构造）都带基线但非本轮同机复测，故不新增热点结论，只把未测项列入待验证假设 #1/#2 |
| §6.2 大粒度锁 | 0 | 文档描述的锁收缩已落地并核对：`SignatureRegistry`/`SignatureTable` 读路径 0 锁（`HostSignature.cj:155-194`、`SignaturePlan.cj:141-152`），`writeMtx` 只在注册/未命中建计划内；`JitExecutor.invokeOff` 稳态 1 次 get 0 次 set（`JitExecutor.cj:147-179`）。剩余写锁为冷路径，无持有时间数据，不判热点 |
| §6.3 并发串行 | 0 | 本部分无 `spawn().get()` 形态；`optimize-jitcontext-pool` 讨论的正是「去掉每线程串行池化」，结论是不采纳 |
| §6.4 低效算法 | 0 | 文档点名的线性扫（`sameShape`）已用「表个位数条目」论证并保留，且有 349→233 ns 的对照；`optimize-signature-tables` 还记录了「加索引反而更慢」的反例。无「已知 n 大仍线性扫」的承诺 |
| §7 降堆内存方案 | 0 | 归档件不产生新代码；`optimize-jitcontext-pool` 的方案已被实测否决并回退，`optimize-marshal-rs` 的惰性容器已落地（值型调用 0 个 `ArrayList`）。无新的、有基线的堆方案 |
| §8 降 CPU 方案 | 0 | 同上；文档遗留线索（编译 25–48 ms、`append` 的一次 TLS）无分段数据，进待验证假设 #1，不作方案 |
| §9 local mode 可行性 | 0 | 本部分无函数级改造对象（规格里没有 local mode 相关段落）；`scope.md` 提到的 `docs/LocalMode*.md` 属全局方案，不在本部分可判范围 |
| §11 现有代码的 BUG（存量） | 0 | 本轮读到的存量缺陷均为「文档与实现不一致」，已按 §13 归类（发现 #1-#6）；未在本部分触及的代码里发现新的逻辑/BUG（交叉取证的 `X86Lower`/`A64Lower`/`JitContext`/`SignaturePlan`/`HandleTable` 关键行均与规格自洽）。故 §11 单列 0 条，不重复计数 |
| §12 并发安全与锁粒度 | 0 | 文档声明的线程模型已逐条核对：`RuntimeState` 线程私有（`RuntimeEnv.cj:33-46`，`stateTls`）、`RuntimeStateIsolation_test` 3 条存在、helper 栈 TLS（`UserHelper.cj:53`）、两表快照用 `AtomicReference` + 写锁「先填满再 store」（`HostSignature.cj:141-149`、`SignaturePlan.cj:167-175`）。未发现「文档声称线程安全而实现无线程隔离」的情形 |
| §14 功能完备性与 README 覆盖 | 1 | 发现 #2 的 `RuntimeStateFlags_test` 属「承诺了但不存在」（双证：`design.md:113` + `.cj` 0 命中）。`optimize-helper-table` 的 `design.md` 不在本部分，无法判其护栏清单完整性（`待确认`）。README 不在本部分清单内，未展开 |
| 文件覆盖（§13 等） | 20/20 | 无缺漏，全部 20 个 `.md` 逐个读完；`.cj` 只作交叉取证，不计入本部分覆盖 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 2 |
| 轻微 | 4 |
| 优化方案（堆内存 / CPU） | 0 / 0 |

存量 6 条（发现全部为存量；快照模式无 diff 基线），是否纳入修复待用户决定。

## 总评

本部分是 `f_jit` 六个「调用路径 / 发射侧」优化的变更规格。就工程记录本身看，质量明显高于平均线：每组都有改前基线、护栏用例、变异验证与回滚条件，且**绝大多数声称落地的实现都能在代码里逐条对上**——`CtxFlags.DEADLINE` 与 A64 `ldr/and/cbz` 序列（`A64Lower.cj:363-381`）、`CallMarshal(rs)` 与 8 个 `With` 重载、`RuntimeState` 合并后的 2 次 TLS、两表 `AtomicReference` 快照 + 无键线性扫、helper 表预建后只入栈、`probeType` 惰性化，全部真实存在且语义与文档一致；被否决的两项（ctx 池、键索引）也留下了带数字的反例，是有价值的负结果。

问题集中在**决策变更后的文档回填**，而不是代码：

1. **x86 ctx 寄存器写错（发现 #1，一般）**：`design/proposal/tasks` 三处写 `rdi`，代码与字节断言是 `r15`。这是本部分唯一"照文档实现就会写出错误机器码"的错误，建议优先修——它是唯一可能被下游（x86 移植、审计）直接照抄的片段。
2. **`ITER/FAULT` flags 位与 `RuntimeStateFlags_test` 从未存在（发现 #2，一般）**：design 描述的是被 T2.4/T6.1 替换掉的方案。风险在于 ctx 是 64 B 冻结 ABI，照 design 补位会动布局；按 D7 找护栏会误判覆盖缺口。
3. 其余四条（`byKey` 伪代码、`MarshalRs_test` 用例数/全量数、`jitcontext-pool` proposal 缺回退标记且引用错文件、`SignatureRegistryVerification` 类名不存在）都是记录层面的陈旧，顺手改即可；其中第 3 条会实质性误导「借出口径」这一设计决策的读者，第 6 条会让「六条护栏是否落地」的复核直接扑空。
4. 附带一点：五组记录的全量用例数与仓内 `@TestCase` 计数差 13–32 条，已列入待验证假设 #3 —— 在确认 `cjpm test` 计数口径前，不宜用这些总数反推「有没有漏跑用例」。

整体判断：本部分无阻塞项（不含代码），发现 #1 建议进修复清单，#2 建议进修复清单（文档 + 一次全仓确认），四条轻微可在下次触碰这些目录时一并改掉。另有一条**范围外提示**（不占用本部分统计）：`doc/spec/optimize-loop-safepoint/tasks.md:43` 声称已更新 `doc/jit-bytecode-m1.md` 的回边描述，实际只有 §5（`:492`、`:500`）改成了「按需」，降低对照表 `jit-bytecode-m1.md:664`、`:2147` 与 §12.6 附近的 `:995` 仍写「无条件 `call H22`」，该文件的审查归其它分轮。第二、第三条范围外提示：`src/SignatureTableConcurrency_test.cj:28` 的文件头注释仍称实现改成「结构键 `HashMap` + 不可变快照」（与发现 #3 同源，源码注释不在本部分）；`doc/spec/optimize-helper-table/design.md:60-67` 列了 4 条护栏，其中 `buildTableKeepsHidOrder`、`pushTableDoesNotCopy` 在全仓 `.cj` 中 0 命中（实际 3 条，与本部分 `verify.md:26-32` 一致），该 design 不在本部分清单。
