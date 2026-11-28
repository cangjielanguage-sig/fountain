# f_jit 模块审查报告（模块第 13/38 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_jit`（模块共 305 个 `.cj` + 290 个 `.md`；本部分 20 个文件，**全部为 `.md`**，均为 `doc/spec/**` 下 4 个变更的归档产物）
- **基线**：工作区快照（sts/1.3.x，无 diff 基线，本轮所有问题来源记为「存量」）
- **审查重点**：动态调用/桥接正确性（typecode 分支表）、句柄与资源生命周期、并发安全、递归/栈溢出、死代码、重复逻辑、存量 BUG —— 在本部分（纯规格文档）中，这些专项以「文档承诺 ↔ 实现落点 ↔ 验收记录」三方对拍的方式落地
- **报告版本**：v1
- **与同模块其他部分的关系**：第 1–12 部分覆盖 `doc/spec/f-jit-m1`、`f-jit-m2.x`、`f-jit-m3`、`feat-*` 等既有能力镜像；本部分只含四个**缺陷修复类**变更：`fix-da-diagnostic-classification`（1 个文件）、`fix-f-jit-audit-defects`（11 个）、`fix-f-jit-strictfp-deadline-x86`（4 个）、`fix-f-jit-x86-stack-align`（4 个）。四者均已归档，按 review-checklist §13 误报边界「`doc/spec/<已归档变更>/` 按当时结论是否自洽核对，不要求与当前实现一致」，本报告报两类：**① 同一变更内文档互相矛盾 / 记录算不平；② 文档把机制或验收写成结论，但与本仓代码、本变更自身 spec 或 tasks 记录相悖**。纯历史行号（如 `X86Lower.cj:472-487`、`AnyHelpers.cj:143` 这类变更前位置）不计问题，只在文件覆盖表说明。

## 发现

### [一般][存量] 缺陷→用例登记表在三处重复维护且已漂移：条数 27 vs「26 条」，6 组用例名与 tasks/verify 不一致，`p1_4_` 前缀被两组不同缺陷共用

- **位置**：`f_jit/doc/spec/fix-f-jit-audit-defects/test-plan.md:1`（标题「26 条」）、`:8-34`（实际 27 行）；`tasks.md:12`（A0.2 注「`test-plan.md`，26 行」）；`tasks.md:38-52` 与 `verify.md:27-51`（实际用例名）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2「字面量复制 / 近似重复：两块内容相似但已漂移」、§13「规格与实现漂移」、§14.1「验收矩阵口径」
- **证据**：静态确定 —— `grep -c "^| P" test-plan.md` = 27（P0-1a、P0-1b 拆行，P2-2a/2b 合并），而 design.md / proposal.md / tasks.md 均称 26 条；逐条比对三份清单，6 组用例名不一致：P0-2（`p0_2_callAnyAndJsonAreReachable` ↔ `p0_2_callAnyIsReachable` + `p0_2_callJsonReturnsAreReachable`）、P0-6（`p0_6_nestedInvokeRestoresDeadline` ↔ `p0_6_deadlineRestoredAfterCall`）、P1-7（`p1_7_constMapFloatDecimalKeysHit` ↔ `p1_7_constMapFloatKeysHit` + `p1_7_constMapDecimalKeysHit`）、P2-2（`p2_2_iterTableClearedPerCall` ↔ `p2_2_bridgeClearsIterTableAtCallEnd` + `p2_2_iterTableClearInvalidatesCursor`）、P2-5（`p2_5_a64Imm9SlowPath`，此名全仓不存在）、P3-3（`p3_3_jsonSetFloat64Domain` ↔ `p3_3_jsonSetFloat64RejectedAtCompileTime` + `p3_3_jsonSetAcceptsValueDomain`）；另 `p1_4_` 前缀同时被 `f_jit/src/compiler/AnyCastAux_test.cj:42`（`p1_4_auxCarriesAsHelperId`，aux 承载 helper id，属 P0-1 面）与 `f_jit/src/compiler/A4Frontend_test.cj`（`p1_4_elseIfParses`，才是 P1-4）占用
- **描述**：`test-plan.md` 是本变更自我规定的「A0.2 唯一缺陷清单」，但同一份事实在 `tasks.md`（每任务括注真实用例名）与 `verify.md`（落点表）各存一份副本，三份已经不同步。后果是**清单不能用作检索入口**：按 `test-plan.md` 的 `p2_5_a64Imm9SlowPath` 搜不到任何用例，按 `p0_2_callAnyAndJsonAreReachable` 也搜不到；`p1_4_` 前缀冲突则让「每条缺陷有唯一用例名」这条自定纪律失效（P1-4 是 `else if` 语法，aux 是 P0-1）。同一次审查在 P3-4 里刚把「矩阵虚报」列为必须消灭的形态，本表自身却复现了轻量版本
- **建议**：把 `test-plan.md` 定为唯一登记源（用例名列写**最终**名字），`tasks.md` / `verify.md` 只引缺陷 ID、不复制用例名；`p1_4_aux*` 三条重命名为 `p0_1_aux*`；把 26/27 的口径写清（「26 个缺陷 ID，P0-1 拆 1a/1b 展开为 27 行」）

### [一般][存量] 本变更自身 spec 要求「用例名 SHALL 含缺陷编号」，P2-5 的三个落点用例名全都不含

- **位置**：`f_jit/doc/spec/fix-f-jit-audit-defects/specs/f-jit-differential-acceptance/spec.md:7`（`用例名 SHALL 含缺陷编号（P0-1 … P3-5）`）；落点 `tasks.md:64`、`verify.md:45`（`imm9OverflowUsesScratchRegister` / `largeOffsetIsChunked` / `deepFrameExceedsImm9`）
- **来源**：存量
- **判据**：review-checklist §14.1「承诺了但没实现」、§13「规格与实现漂移」
- **证据**：静态确定 —— `grep -rn "func p2_5_" f_jit/src` 零命中；三个用例实际定义在 `f_jit/src/backend/A64Emitter_test.cj:225` / `:248`（前两条）与 `f_jit/src/compiler/A64Exec_test.cj:221`（第三条），名字均不含 `P2-5`；同型反例还有 P0-3 的 `bnotInvertsAndPopsOperand`（`f_jit/src/runtime/Interp_test.cj:390`）与 P2-3 的 `releaseReclaimsEscapedSlot`（`f_jit/src/runtime/HandleTableM2_test.cj:201`），即 26 条里至少 5 条落点用例无可检索的编号
- **描述**：这是「本变更自己的验收规格未被自己的交付满足」的完整双证（承诺源 `spec.md:7`，缺失证据是 0 命中的函数名搜索）。危害不在编译期，而在于按编号追溯：「P2-5 是否有语义断言用例」这个问题，从用例名无法回答，只能靠 `verify.md` 的人工映射；而 `verify.md:45` 与 `test-plan.md:28` 又给了不同名字，追溯链断在两处
- **建议**：把三条改名为 `p2_5_imm9OverflowUsesScratch` / `p2_5_largeOffsetIsChunked` / `p2_5_deepFrameExceedsImm9`（保持 diff 最小），或把 `spec.md:7` 的要求改为「登记表须能按 ID 检索到用例」（弱化到清单层）；二者选一，不要让规格与实现各说一套

### [一般][存量] 零回归门槛的数字自相矛盾：`tasks.md` 写「1076 用例 / 1075 通过 / 0 失败 / 0 error」，`verify.md` 写 1076/1076

- **位置**：`f_jit/doc/spec/fix-f-jit-audit-defects/tasks.md:74`（A7.6）；对照 `verify.md:8`（「1076 用例 / 1076 通过 / 0 失败 / 0 error / 0 skipped」）、`verify.md:7`（基线 1026/1026）、`verify.md:9`（新增 50 条 = 4+14+7+10+6+5+4）
- **来源**：存量
- **判据**：review-checklist §13「文档过期 / 记录与结论不符」、§11「契约与实现不符」；本变更的门槛条款见 `specs/f-jit-differential-acceptance/spec.md:9`（用例数与失败数 SHALL 与基线对照留档）
- **证据**：静态确定 —— 算术上 1076 − 1075 = 1，而同一行又写「0 失败 / 0 error」，`verify.md:8` 还显式写「0 skipped」，三者不能同时成立；`tasks.md:74` 括注「`PerfOverride_test` 负载下假失败，单跑通过」与「0 失败」也互斥
- **描述**：A7.6 是本变更的唯一总验收口，也是「零回归」这一硬门槛的唯一证据。1075 与 1076 差的那一条要么是漏跑、要么是假失败未计入，两种解释都意味着**门槛当时是带缺口通过的**；读者无法从这两份记录判断到底是哪一种。由于本变更的核心主张是「26 条缺陷全部收口且零回归」，这条数字矛盾直接影响结论可信度
- **建议**：二选一并写清口径 —— 若 `PerfOverride_test` 计入失败，则记「1076 / 1075 通过 / 1 失败（负载敏感，单独复跑通过）」；若不计入，则 `verify.md:8` 与 `tasks.md:74` 统一为 1076/1076 并删掉「1075」，同时在 `verify.md` 注明该用例的处置方式（排除 / 重跑通过）

### [一般][存量] `fix-f-jit-x86-stack-align` 的 `design.md` 未随实现调整回写：手写栈效应表、字节级断言、1091 绿判据三项都与最终实现相反

- **位置**：`f_jit/doc/spec/fix-f-jit-x86-stack-align/design.md:57-67`（§3.1 声明 `public struct StackEffect`、`stackEffect(op, operands)`、`analyzeDepth(code, codeOff, codeLen)`）、`:75`（§5 缓解列「表完整性用例守护」）、`:103-105`（§4.1③ 要求 `48 83 EC 08` 字节级断言）、`:113`（§4.3「全量 1091/1091」）；对照 `tasks.md:10-12`（1.3「原计划的字节级对齐断言改为 `X86Depth` 的 5 个单测」）、`tasks.md:16-20`（2.1「**（实现方式调整）** 不维护手写栈效应表：改由探针遍采集 `delta[off]`」）、`tasks.md:33`（4.1 实测 1098 例 / 1094 过）；代码 `f_jit/src/backend/X86Depth.cj:28-29`、`:57-65`
- **来源**：存量
- **判据**：review-checklist §13「规格与实现漂移」「文档过期」
- **证据**：静态确定 —— `X86Depth.cj:28-29` 注释明写「指令的栈增量由 `X86Lower` 的探针遍采集（`delta[off]`），因此**不维护第二份手写栈效应表**」；实际签名 `analyze(code, codeOff, codeLen, delta: HashMap<Int64, Int64>)`（`X86Depth.cj:64-65`），`f_jit/src/backend` 下 `grep "stackEffect\|analyzeDepth"` 零命中；**同名的 `StackEffect` 只存在于前端** `f_jit/src/compiler/Ops.cj:305`（`BytecodeBuilder` 用），与后端无关，因此按 design 去 backend 找这张表会先撞上这个同名类
- **描述**：`tasks.md` 用「（实现方式调整）」如实记了三次偏离（表→探针遍、字节断言→单测、1091→1098），但 `design.md` 一字未改，仍以「新方案 A：CFG 前扫 + 逐指令深度表 + 栈效应表」叙述，并把「表完整性用例」写成风险缓解手段。读到 design 的人会以为存在一张需要维护的 opcode 栈效应表、以及一条字节级对齐断言；两者都不存在。§4.3 的绿判据「1091/1091」也与最终 1098 例不符（1091+2 同型 +5 单测 = 1098，说明是 design 未跟上新增用例）
- **建议**：`design.md` §3.1 改为「`internal class X86Depth` + `analyze(code, codeOff, codeLen, delta)`，增量由 `X86Lower` 探针遍采集」；§5 风险行改为「探针遍与发射遍同源，不会漂移；未识别指令 ⇒ 放弃 JIT」；§4.1③ 改为「`X86Depth_test` 五形态单测」；§4.3 数字改为终态实测值

### [一般][存量] 常量键规格写 `Float64 → f:<位模式>`，与本变更自己的修复结论（`i:<bits>`）相反

- **位置**：`f_jit/doc/spec/fix-f-jit-audit-defects/specs/f-jit-bytecode-format/spec.md:7`；对照 `tasks.md:57`（A5.1 括注）、`f_jit/src/bytecode/CanonKey.cj:45-58`、`:80-96`
- **来源**：存量
- **判据**：review-checklist §13「规格与实现漂移」；§2「字面量复制：同一张表散落多处」
- **证据**：静态确定 —— spec:7 把 `Float64 → f:<位模式>` 写成 SHALL；tasks A5.1 却记「**Float64 的真正根因**：常量表用 `f:<bits>`、运行期裸 cell 走 `i:<cell>` —— 值型键统一为 `CanonKey.cell`（Float64 常量键 ⇒ `i:<bits>`）」；`CanonKey.f64` 实现为 `return cell(bitsAsI64(bits))`（`CanonKey.cj:56-58`），其注释明写「若这里另立 `f:` 前缀，同一个 `Float64` 在裸 cell 与 Any 盒两条路径上会得到两个键，装箱键永远查不到常量条目」。Decimal 亦不同形：规格写 `d:<规范化文本>`，实现是 `d:<sign>|<scale>|<coeff 去尾零>`（`CanonKey.cj:96`）
- **描述**：规格条款复述的正是本变更判定为「P1-7 根因」的旧格式。任何按 spec:7 重写 `tokenOf` 的实现都会原样重现「`Map<Float64,…>` 常量键永不命中」，而按实现写的 `p1_7_canonKeyIsSingleSource` 会红——规格与自己的验收用例互相排斥。这也是「同一契约多副本」在本次唯一造成实质错误的一条
- **建议**：`spec.md:7` 改为「`Float64 → i:<位模式按补码重解释为 Int64>`（与裸 cell 同键，**不另立 `f:` 前缀**）」、`Decimal → d:<sign>|<scale>|<coefficient（去尾零）>`；并在小节里点明「值型键一律 `i:`」，避免下一个常量类型再分叉

### [一般][存量] `fix-f-jit-strictfp-deadline-x86` 勾选了 STACK_GUARD，同模块回归记录却写「本变更未做」，且其判据被次日变更推翻

- **位置**：`f_jit/doc/spec/fix-f-jit-strictfp-deadline-x86/tasks.md:17-18`（3.1 `[x]`「`case 0x74u8` 增 STACK_GUARD（`(rbp-frame)-rsp < frame ⇒ errCode=-1 + jmp epilogue`）」）、`design.md:38-62`（§2.2 汇编 `cmp rax, rdx; jge ok`，rdx = `frame`）、`specs/f-jit-backend/spec.md:31`（`(rbp - frameSize) - rsp < frameSize` ⇒ deopt）；对照 `f_jit/doc/spec/f-jit-m1/verify.md:245-247`（「**遗留（本变更未做）**：x86 `LOOP_BACK` 的 **STACK_GUARD** … 尚未补」）与 `:249-258`（第三轮 `align-x86-loop-back-stack-guard` 改按「溢出量 ≤ 操作数栈保留区 `8*(maxStack+1)`」用 `jbe` 放行）；实现 `f_jit/src/backend/X86Lower.cj:1019-1034`
- **来源**：存量
- **判据**：review-checklist §14.1「承诺了但没实现」、§13「规格与实现漂移」、§4（守卫判据反了会让每次正常回边都 deopt）
- **证据**：静态确定 —— 同模块 `verify.md` 明确把 STACK_GUARD 列为该变更未做项（只做了 H22），次日由 `align-x86-loop-back-stack-guard` 补齐；实现比较的是 `rbp - frameSize - rsp`（溢出量）与**保留区** `8*(maxStack+1)`，判据为 `jbe ok`（`X86Lower.cj:1026-1031`），注释写明「x86 帧是预分配的 ⇒ 正常路径 overflow == 8*depth <= 保留区，恒不 deopt」（`:1023-1025`）——与 spec:31 / design:49-50 的「阈值 = frameSize、`jge` 放行」方向相反
- **描述**：这是本部分最实质的一处记录失真。`tasks.md` 的勾选与 design 的汇编片段都表示「安全点已完整落地」，而当时的回归记录承认只做了 H22；更关键的是 design/spec 给出的守卫判据在 x86 预分配帧上会把**正常回边**判成溢出，从而每轮 deopt——次日的变更正是因为这点改成了「阈值 = 保留区 + `jbe`」。按归档 design 复刻这段代码会得到一个恒 deopt 的循环，这正是「文档把未验证的机制写成结论」的代价
- **建议**：`tasks.md:17-18` 拆成 3.1a（H22 已完成）与 3.1b（STACK_GUARD 移交 `align-x86-loop-back-stack-guard`，附原因「阈值须按保留区而非 frameSize」）；`design.md` §2.2 汇编与 `spec.md:31` 的判据按次轮更正后的口径回写，并注明「首轮按 frameSize 比较是错的，会恒 deopt」

### [轻微][存量] 同一变更里新增调用入口有两个名字：`proposal.md` 写 `call<T>(args, options)` 与 `tryInvoke`，`design/spec/tasks/verify` 写 `invoke<T>` 且明令「SHALL NOT 引入 tryInvoke」

- **位置**：`f_jit/doc/spec/fix-f-jit-audit-defects/proposal.md:21`（「新增 `JitFunction.call<T>(args, options: CallContext)`」）、`:38`（「`invoke/tryInvoke` 与 deadline 接线」）、`:46`（Impact「新增 `JitFunction.call<T>(args: Array<Any>, options: CallContext)`」）；对照 `design.md:26`（P0-6 修法「新增 `invoke<T>(args, options)`（**不引入 `tryInvoke`**）」）、`design.md:81`（D3 同结论）、`specs/f-jit-facade-bridge/spec.md:113`（`SHALL NOT 引入 tryInvoke`）、`tasks.md:40-41`、`verify.md:31`
- **来源**：存量
- **判据**：review-checklist §13「文档自相矛盾」、§10「契约与实现不符」
- **证据**：静态确定 —— 同一份变更的 proposal 与 design/spec 对「新增几个入口、叫什么」给出相反答案；当前代码只有重载形态 `public func call<T>(args: Array<Any>, options: CallContext)`（`f_jit/src/JitFunction.cj:159`），且 `f_jit/src/base/JitValue.cj:25` 注释「原 `invoke` / `tryInvoke` 已并入同名重载」可证 `invoke` 已不存在
- **描述**：最终形态与 proposal 一致、与 design/spec/tasks/verify 相反，说明「proposal 里的两种写法（`call` 重载、`tryInvoke`）当时被当成笔误忽略，真正实施的是 `invoke`，随后又被并入 `call`」。归档记录因此留下三处失效引用：`tasks.md:41` 的 `a3_4_invokeMatchesCall`、`tasks.md:42` 的 `a3_5_strictFpDoesNotChangeFdivChk` 在仓内均不存在（现名 `a3_4_callOverloadsAgree`、`a3_5_bridgeKeepsDivisionSemantics`，见 `f_jit/src/AnyBridgeCall_test.cj`）。按编号检索验收证据的人会在这一步断掉
- **建议**：在 `design.md` D3 与 `spec.md:113` 加一行「后续变更将 `invoke` 并入 `call` 重载（见 `align-call-entry-spec`），本条保留原裁定」，并把 proposal 的 `tryInvoke` 一句改为「不引入独立入口」；`tasks.md` / `verify.md` 的旧用例名保留但加「现名」括注

### [轻微][存量] `verify.md` 的归档与主规格结论在当前工作区不可复核（归档路径、9 个 capability、镜像 diff 一致三项均无对应物）

- **位置**：`f_jit/doc/spec/fix-f-jit-audit-defects/verify.md:69-72`（归档路径 `openspec/changes/archive/2026-10-21-fix-f-jit-audit-defects/`、`openspec list` 无活动变更、主规格 9 个 capability、镜像逐文件 `diff` 一致）、`:74-88`（`validate --all --strict` 4 passed / 5 failed 的既有债务表）
- **来源**：存量
- **判据**：review-checklist §13「链接 / 路径失效」
- **证据**：待确认 —— 当前 `openspec/changes/archive/` 仅有 5 个 2026-11-20 的目录（`fix-dataassist-local-mode` 等），`openspec/specs/` 仅有 `data-assist-compare` / `jwt-signature` / `orm-result-type-mapping` / `uring-async-io` / `data-assist-supertypes` 五个，无任何 `f-jit-*`；`git log --all -- "openspec/changes/archive/2026-10-21-fix-f-jit-audit-defects"` 与 `-- "openspec/specs/f-jit-backend"` 均为空。缺的信息：`verify.md:15` 提到「复现命令（融合侧）」，若该归档落在另一套工作树/分支，需要写明路径
- **描述**：本变更最有力的两条结论（「18 条 delta 全量落地」「镜像与归档逐文件一致」）依赖一个本仓不存在的目录树。若它确实在「融合侧」工作树，则本仓的 `f_jit/doc/spec/` 只是单向镜像，「diff 一致」这句话在本仓永远无法验证；若归档曾在本仓而后被清理，则 §74-88 的 lint 债务表也失去对照锚点。两种情况下读者都会卡在同一处
- **建议**：在该段补一句来源路径（「归档位于融合侧仓库 `<path>`，本仓仅保留镜像」），或把结论改为「本仓镜像自洽；openspec 归档见外部工作树」；若本仓 `openspec/` 已重新初始化（当前 `openspec/changes/` 只有 `add-f-a2a`），建议在 `f_jit/doc/spec/README` 级别说明「本目录为历史归档镜像，不再与 `openspec/specs` 对应」

### [轻微][存量] proposal 未登记 A2 实施中的附带修复（默认产物 `verMajor` M2 → M3）

- **位置**：`f_jit/doc/spec/fix-f-jit-audit-defects/proposal.md:45-48`（Impact / 格式与兼容）；记录在 `design.md:134-137`、`tasks.md:24-26`
- **来源**：存量
- **判据**：review-checklist §13「变更说明与实施不一致」；§14.1「接线缺失——能力变化未进变更说明」
- **证据**：静态确定 —— design 的「A2 实施中新增的必要修复」与 tasks 的「本批附带修复」都写明 `CompilePipeline.runSource` 的 `verMajor` 由 `M2_MAJOR` 改为 `M3_MAJOR`（此前公开 `Compiler.compile` 完全编不了 `Any`，报「局部槽类型码非法: 15」）；proposal 的 What Changes 与 Impact 全篇未提，且 Impact 仍写「`.fbc` verMajor 1/2/3 及规则集校验**零变化**」
- **描述**：这是本变更里唯一改变「公开入口默认产出什么版本产物」的行为——格式没变，但同一源码产出的 `verMajor` 从 2 变 3。下游按 proposal 评估兼容性时会漏掉这一项；按 tasks/design 才知道「加载器要能吃 3」。记录分散在设计与任务里，恰好是 proposal（对外变更说明）最该写的地方
- **建议**：proposal Impact 增一行「默认产物 verMajor：2 → 3（`.fbc` 结构不变；消费方需支持 3）」，或在 What Changes 里把该附带修复单列

## 优化可行性方案

> 本部分无 `.cj` 代码，不产生堆内存 / CPU 方案。三份 design 里已有的性能自述（`fix-f-jit-strictfp-deadline-x86/design.md:81` 的「回边新增约 12 条指令」、`fix-f-jit-x86-stack-align/tasks.md:37` 的 `native=5,807,847ns / jit=3,435,226ns`）都缺改前对照或占比数据，按铁律只能进「待验证假设」。

（0 条：堆内存 0 / CPU 0）

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 回边安全点（STACK_GUARD + H22 `interrupt_poll`）在热循环里的开销可忽略 | `f_jit/doc/spec/fix-f-jit-strictfp-deadline-x86/design.md:81`（自称「约 12 条指令」）；实现 `f_jit/src/backend/X86Lower.cj:1019-1049` | 回边开销占循环体自耗时的比例；改前（无检查）与改后同输入对照 | `cjpm bench -O2` 跑「空循环 1e8 次」与「每轮 1 次整数加」两档，同机同 SDK，各 5 轮取中位数；再用 `cjprof record` 看 `X86Lower` 产物的热点分布 |
| 2 | CFG 深度预扫的 O(指令数) 一次性开销不构成 JIT 编译期退化 | `f_jit/doc/spec/fix-f-jit-x86-stack-align/design.md:115`（「预扫为 O(n) 一次性开销，波动在噪声内」）、`tasks.md:37`（只有修复后的三个数字，无改前对照） | 同一单元「修复前 vs 修复后」的 JIT 编译耗时分段计时；大函数（>2k 指令）下的绝对增量 | 对 20 个不同规模的样例单元各编译 50 次，`Instant` 分段计时 probe 遍 / 数据流 / 发射遍，报中位数与 P95 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_jit/doc/spec/fix-da-diagnostic-classification/verify.md` | .md | ✅ | 五段实验（A–E）改前/改后 kind 对照自洽（1261→1265，+4 条）；`DaDiagnostic_test.cj` 四条用例名与 `:69-73` 逐条对上；该目录只有 proposal/tasks/verify 三件，缺 design/specs（同类变更 `fix-await-timeout-semantics` 亦然，按仓内惯例不算缺陷） |
| 2 | `f_jit/doc/spec/fix-f-jit-audit-defects/design.md` | .md | ✅ | P0/P1/P2 共 22 行缺陷目录与代码落点大体可核（H78–H80 aux 类界、`appendHostObject`、`fetchAnyBox` gen、`IterTable.clearAll`、`CanonKey` 均在）；条数「26」的口径与 test-plan 27 行不符（#1）；`invoke` 命名见 #7 |
| 3 | `f_jit/doc/spec/fix-f-jit-audit-defects/proposal.md` | .md | ✅ | 与 design 的缺陷清单一致；新增入口命名自相矛盾（#7） |
| 4 | `f_jit/doc/spec/fix-f-jit-audit-defects/specs/f-jit-backend/spec.md` | .md | ✅ | imm9 −256/255 立即数、−257/256 慢路径四条边界与 `f_jit/src/backend/A64Emitter.cj:440`（越界先 `scratch = rn + off` 再访问）、`:484` / `:496`（`strOff` / `ldrOff` 分支）一致；`imm9OverflowUsesScratchRegister` / `largeOffsetIsChunked` 两条用例覆盖边界与分块；无问题（用例命名问题见 #2） |
| 5 | `f_jit/doc/spec/fix-f-jit-audit-defects/specs/f-jit-bytecode-format/spec.md` | .md | ✅ | 前缀表**未**与 `f_jit/src/bytecode/CanonKey.cj` 对上：规格写 `Float64 → f:<位模式>`、`Decimal → d:<规范化文本>`，实现是 `f64 → cell`（`i:<bits>`，`:45-58`）与 `d:<sign>|<scale>|<coeff>`（`:96`）；见 #5 |
| 6 | `f_jit/doc/spec/fix-f-jit-audit-defects/specs/f-jit-compiler-frontend/spec.md` | .md | ✅ | 正则 flags、`else if`、尾调用实参临时槽、IIFE 返回类型、重载解析、String 算术拒绝面、容器装箱七条与 `compiler/` 下 `A4Frontend_test` / `AnyCastAux_test` 的断言面对得上；P1-4 前缀冲突见 #1 |
| 7 | `f_jit/doc/spec/fix-f-jit-audit-defects/specs/f-jit-differential-acceptance/spec.md` | .md | ✅ | 「用例名含缺陷编号」未被 P2-5 满足（#2）；四件套要求限定在 `f-jit-m3`/`m2.1–m2.3`，本变更自身不在其约束内 |
| 8 | `f_jit/doc/spec/fix-f-jit-audit-defects/specs/f-jit-facade-bridge/spec.md` | .md | ✅ | 解包 0–19 全行、15/16–19 逃逸归还、DEOPT 三态、`invoke` 与 `call` 等价、`callForFn` 串行化均与 `JitFunction.cj` 现状一致（入口名见 #7） |
| 9 | `f_jit/doc/spec/fix-f-jit-audit-defects/specs/f-jit-runtime/spec.md` | .md | ✅ | typecode 分支表逐项核过：14 目标 `aux != 0xFFFF` 委托 `$as$<C>`、命中按 `HOST_OBJECT`(11) 登记、未命中 22、`aux == 0xFFFF` 保留兼容口径 —— 与 `f_jit/src/runtime/AnyHelpers.cj:92-95`、`:159-161`、`:218` 一致；H79 纯读零分配亦成立 |
| 10 | `f_jit/doc/spec/fix-f-jit-audit-defects/tasks.md` | .md | ✅ | 39/39 任务自洽；A0.2「26 行」（#1）、A7.6「1075 通过」（#3）、旧用例名（#7） |
| 11 | `f_jit/doc/spec/fix-f-jit-audit-defects/test-plan.md` | .md | ✅ | 缺陷→用例清单，27 行与标题「26 条」不符，6 组名字与 tasks/verify 漂移（#1） |
| 12 | `f_jit/doc/spec/fix-f-jit-audit-defects/verify.md` | .md | ✅ | 全量数字与 tasks 冲突（#3）；归档/主规格不可复核（#8）；`:27` 把 `p1_4_auxCarriesAsHelperId` 记为 P0-1 证据，是 #1 的前缀冲突来源 |
| 13 | `f_jit/doc/spec/fix-f-jit-strictfp-deadline-x86/design.md` | .md | ✅ | 根因与修法正确：`jnp`(0x8B)→`jp`(0x8A) 与实现一致（`X86Lower.cj:488-495`），字节序列 `48 29 D0`/`48 29 E0`/`48 39 D0`/`0F 8D` 逐条核对无误；`:72` 的 1098/1098 与 tasks 4.1 一致。说明本变更的 design 是**已回写**的（与 #4 形成对照） |
| 14 | `f_jit/doc/spec/fix-f-jit-strictfp-deadline-x86/proposal.md` | .md | ✅ | 4 个 FAILED 的归属与 stack-align `tasks.md:34` 记录一致；「与栈对齐修复无关、修复前即存在」可对上 `f_jit/doc/spec/f-jit-m1/verify.md:234` |
| 15 | `f_jit/doc/spec/fix-f-jit-strictfp-deadline-x86/specs/f-jit-backend/spec.md` | .md | ✅ | ÷0 → 1 一条与实现一致；回边 Requirement 的第 1 项（栈余量判据按 `frameSize` 比较）与最终实现相反，见 #6；此目录无独立 `verify.md`，tasks 5.2 所指记录确在 `f_jit/doc/spec/f-jit-m1/verify.md:238`，但同段 `:245` 又写「STACK_GUARD 本变更未做」 |
| 16 | `f_jit/doc/spec/fix-f-jit-strictfp-deadline-x86/tasks.md` | .md | ✅ | 5 组任务全勾选；3.1 的 STACK_GUARD 勾选与回归记录冲突（#6）；`X86Lower_test` 的 `0F 8A` 字节断言确实存在（`X86Lower_test.cj:225-228`） |
| 17 | `f_jit/doc/spec/fix-f-jit-x86-stack-align/design.md` | .md | ✅ | 根因分析（线性 depth ↔ CFG depth、`alignBeforeCall` 奇偶）成立且 `BytecodeBuilder.emitRel/place` 侧的对照引用准确；但 §3.1/§4.1③/§4.3/§5 未随实现回写（#4） |
| 18 | `f_jit/doc/spec/fix-f-jit-x86-stack-align/proposal.md` | .md | ✅ | 3 例 SIGSEGV 的输入/期望/实际三列表与本变更 verify 一致；「New Capabilities：f-jit-backend …（仓库尚无既有主规格）」与 audit-defects 已于前一日归档 9 个 capability 的说法冲突，但本仓 `openspec/specs` 确无 f-jit-*，按 #8 同一不确定处理，未单列 |
| 19 | `f_jit/doc/spec/fix-f-jit-x86-stack-align/specs/f-jit-backend/spec.md` | .md | ✅ | 两条 Requirement（深度由控制流推导、16 字节对齐同源且对称撤销）与 `X86Depth` + `X86Lower.lower` 三遍结构一致；「汇合不一致 ⇒ 退回解释器」在 `X86Depth.cj:83-86` 有对应分支 |
| 20 | `f_jit/doc/spec/fix-f-jit-x86-stack-align/tasks.md` | .md | ✅ | 三次「实现方式调整」如实记录，是 #4 的对照面；4.1 的 1098/1094/0 ERROR/4 FAILED 与 strictfp 变更的起点衔接正确 |

合计：`.cj` 0 个 / `.md` 20 个 / 共 20 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 3 | 正确性 #3（验收数字不自洽）、#6（完成声明与同模块回归记录相反）；设计 #1（同一事实三处维护）；语言特性 0（本部分无代码，文档所述 typecode/aux/escape 语义已逐条与 `AnyHelpers.cj`、`JitFunction.cj` 对拍一致）；可读性 0；安全性 0（无凭据、无外部输入、无注入面） |
| §1 死代码 | 0 | 本部分无 `.cj`，无 `return` 后语句 / 恒假分支 / 无调用者符号可判。文档侧「指向不存在符号」的引用共 4 类（`stackEffect`/`analyzeDepth`、`p2_5_a64Imm9SlowPath`、`p3_3_jsonSetFloat64Domain`、`a3_4_invokeMatchesCall`），按 §13 失效引用归入 #1/#4/#7，不重复计数 |
| §2 重复逻辑 | 1 | #1：缺陷→用例清单在 `test-plan.md` / `tasks.md` / `verify.md` 三处各存一份，语义相同而名字、条数已漂移（27 vs 26、6 组名字、`p1_4_` 前缀复用）；#5 同源（常量键表在 spec 与 `CanonKey` 各写一份并已分叉）。其余重复均为 OpenSpec 归档模型的镜像（同一 delta 落 `doc/spec` 与历史归档），按误报边界豁免 |
| §3 空实现 | 0 | 本部分无函数体。逐个核对「声称产出但可能为空」的产物：strictfp 的 verify 记录确在 `f-jit-m1/verify.md:238`，`DaDiagnostic_test` 四条用例有实体，`X86Lower_test` 的字节断言有实体；无占位 TODO、无「勾选但空」。`fix-da` 缺 design/specs 见文件覆盖表说明（仓内另有同类先例，不判） |
| §4 栈溢出 | 0 | 文档述及的深度风险点（深帧回边、`deepFrameExceedsImm9`、`STACK_GUARD ⇒ deopt`）与实现一致，未发现「文档承诺有保护而代码没有」或相反。本部分不含递归代码，递归专项在 `.cj` 部分 |
| §5 OOM | 0 | 无「按不可信长度预分配」「全局容器只增不减」类承诺；`IterTable` 调用级清空、逃逸槽归还两条生命周期承诺在 `JitFunction.cj:687` 与 `HandleTable.release` 侧有落点 |
| §6.1 热点瓶颈 | 0 | 本部分无 profile / bench 对照：`strictfp` 只有「约 12 条指令」的估数，`stack-align` 只有修复后的三个绝对值（无改前对照），`audit-defects` 只有用例数。两条自述已进「待验证假设」，不构成发现 |
| §6.2 大粒度锁 | 0 | 文档涉及的临界区只有 `callMtx`（`callForFn` 串行化）与 `IterTable` 静态锁，均属正确性修复而非热点；无「锁内 I/O / 解析 / 回调」的描述 |
| §6.3 并发串行 | 0 | `callForFn` 串行化是有意设计（提升组归属），文档已给理由；无 `spawn().get()`、无并发度=1 的批处理描述 |
| §6.4 低效算法 | 0 | 无嵌套循环 / `contains` 热点 / `remove(at:0)` 类描述；`X86Depth` 的工作列表数据流为 O(指令数) |
| §7 降堆内存方案 | 0 | 本部分无可改的生命周期/副本/容器上限对象（无代码）；文档所述「逃逸槽归还」「`IterTable` 清空」已是既有实现 |
| §8 降 CPU 方案 | 0 | 无基线数据，未提方案（见 §6.1 与待验证假设） |
| §9 local mode 可行性 | 0 | 文档不涉及 local mode；被描述的路径（JIT 降低、桥封送）产物均逃逸到机器码缓冲与句柄表，不满足「函数内创建、函数内用完」 |
| §11 现有代码的 BUG（存量） | 9 | 本部分 9 条全部为存量（快照模式无基线），按「存量文档/验收记录缺陷」计：#1–#9。无代码可审，故不含运行时缺陷 |
| §12 并发安全与锁粒度 | 0 | 无并发代码。文档承诺的并发契约（`callForFn` 整段入锁、`lastClosureGroup` 取完即清、`IterTable` 静态锁 + `close` 越界防御）与 `JitFunction.cj` / `IterTable.cj` 现状一致，未发现「文档声称线程安全而实现无同步」 |
| §14 功能完备性与 README 覆盖 | 3 | #2（自身 spec 的用例命名要求未落实）、#3（零回归门槛数字不可复核）、#6（spec 的回边安全点要求当时只在 tasks 勾选、实现与回归记录均未跟上）；本部分不含 README，公开 API 是否进 README 的检查在 `.cj`/README 部分 |
| 文件覆盖（§13 等） | 20/20 | 本部分清单 20 个文件全部读完，无缺失、无跳过 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 6 |
| 轻微 | 3 |
| 优化方案（堆内存 / CPU） | 0 / 0 |

## 总评

这 20 份文档是 `f_jit` 三次 x86/AArch64/桥接缺陷收口的完整记录，质量明显高于一般归档：`fix-f-jit-audit-defects/design.md` 的 22 行缺陷目录几乎每行都给了「根因 + 修法 + 为何不选备选」，`fix-f-jit-strictfp-deadline-x86/design.md` 把 `jnp → jp` 的谓词反向错误连同汇编序列一起写清（我逐条核了 `0x8A`、`48 29 D0`、`0F 8D` 的编码，均正确），`fix-f-jit-x86-stack-align/design.md` 用「线性 depth 与 CFG depth 的奇偶差」解释 SIGSEGV 并给出四种方案对比 —— 这类根因叙述的可复核性很高。文档承诺的实现落点也经得起抽查：typecode 14 的 `aux` 类界判定与 tag 11（`AnyHelpers.cj:92-95/159-161/218`）、`appendHostObject`、`fetchAnyBox` 的 gen 校验、`IterTable.clearAll` 进 `finally`、`FDIV_CHK` 的 `0F 8A` 字节断言，全部对得上（`CanonKey` 是唯一例外：规格的前缀表与实现相反，见 #5）。

本部分的问题集中在**记账层**，而不是技术判断层：同一份「缺陷 → 用例」事实被复制到 `test-plan.md` / `tasks.md` / `verify.md` 三处，随后各自漂移 —— 条数 27 与「26」并存、6 组用例名互不相同、`p1_4_` 前缀被两组缺陷共用、P2-5 的用例名干脆不含编号（违反本变更自己写的 spec）。这类漂移不会让代码出错，但会让「26 条是否真的都有语义断言」这个问题失去可检索的答案，也与本变更自己刚立的「矩阵不许虚报」纪律相悖。第二处值得排期的是 `stack-align/design.md`：`tasks.md` 用三次「实现方式调整」如实记录了偏离，`design.md` 却仍以「手写栈效应表 + 字节级断言 + 1091/1091」叙述，且后端确实没有那张表（同名的 `StackEffect` 只在前端 `compiler/Ops.cj`），后来者按 design 找符号会先撞错地方。零回归数字（1075 vs 1076）单列一条，是因为它是本变更唯一的总验收证据，差一条就应当写清是漏跑还是假失败。

无严重项、无阻塞项。但其中两条不只是「记录不准」，而是**文档会教出错误实现**：#5 让 `Float64` 常量键回到已被判定为 P1-7 根因的 `f:` 前缀（照做即重现「常量键永不命中」）；#6 让 x86 回边守卫按 `frameSize` 比较（照做即每次正常回边 deopt），且它的 `[x]` 与本模块 `f-jit-m1/verify.md` 的「本变更未做」直接冲突。这两条建议与 #4（design 未回写的 `X86Depth`）一起作为文档收口的第一批，其余记账类（#1 #2 #3 #7 #8 #9）可以第二批。

存量 9 条（一般 6 / 轻微 3），是否纳入修复待用户决定。
