# f_jit 模块审查报告（模块第 8/38 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_jit`（本部分：`doc/spec/` 下 5 个变更目录，共 20 个 `.md`：`align-jitfunction-close-naming`、`align-x86-loop-back-stack-guard`、`clarify-last-escaped-scope`、`close-f-jit-out-of-checklist-findings`、`f-jit-m1`）
- **基线**：工作区快照（无 diff 可比，本轮全部问题来源记「存量」）
- **审查重点**：动态调用/桥接正确性（typecode 分支表）、句柄与资源生命周期、并发安全、递归与栈溢出、死代码、重复逻辑、存量 BUG；本部分文件全为规格/设计文档，故以「文档承诺 ↔ 实现」逐条对拍为主线，涉及后端时现场核对指令编码
- **报告版本**：v1（分报告，供主 Agent 合并为 `docs/review/2026-11-28/f_jit.md`；与 part7 有 1 个文件重叠：`align-jitfunction-close-naming/specs/f-jit-facade-bridge/spec.md`，该文件的 `close(timeoutMs)` 计时缺陷已由 part7 报告，本条不重复计数）

## 发现

### [一般][存量] A64 回边守卫的「frame 语义」论证前提与 AArch64 编码事实相反，掩盖了守卫恒不触发的真实原因

- **位置**：`f_jit/doc/spec/align-x86-loop-back-stack-guard/design.md:8`（序言行）、`:9-11`、`proposal.md:16-19`、`specs/f-jit-backend/spec.md:5-6`
- **来源**：存量（工作区快照；该目录时间戳 2026-10-22，实现为 `A64Lower.cj:363-373`，`git log -L 363,381:A64Lower.cj` 显示守卫序列在本次变更之前就已存在，故其分析对象就是当前代码）
- **判据**：review-checklist §13（文档与实现/语言事实不符）、§12.1（判「安全」必须给对同步与余量路径）、§4（余量守卫失效）
- **证据**：静态确定 —— 文档写「aarch64：`sub sp, sp, frame`（**`x31` 上的减法在该编码中不落实**，真实 `sp` 仍在帧顶附近）」，据此推出回边 `(fp - frame) - sp` 为负值、守卫「退化为恒不触发」。核对编码：`A64Emitter.cj:322-324` 的 `subImm` 用 `0xD1000000`（Add/subtract **immediate**，Rd=31 即 **SP**），`A64Compiler.cj:75` 发射 `sub sp, sp, frame` 是**生效**的；`A64Emitter.cj:279-287` 的尾声用 `mov sp, x29` 复位（不是 `add sp, sp, frame`），只有帧真的被扣掉才需要这样复位。真正让守卫失效的是 `A64Lower.cj:368-373`：`subReg(11, 11, 31)` 走 `0xCB000000`（Add/subtract **shifted register**，Rm=31 是 **XZR**，`A64Emitter.cj:330-332`），等价于 `sub x11, x11, xzr`，于是 `r11 = fp - frame`（一个远大于 `frame` 的栈地址），比较恒不成立。同一序列还出现在 `A64Lower.cj:167-174`（opcode `0x07` 的 STACK_CHECK），同样是空操作。
- **描述**：① 文档把「守卫不触发」归因于序言不扣栈，这是错的；若后来者按此「修正」，会去改序言/尾声（真实扣栈一旦被改坏，helper 帧会覆盖 locals，变成真崩溃）。② 更关键的是，即便把 `subReg(...,31)` 改成正确的形式，A64 的操作数栈指针是 `x20` 而不是 `sp`，`(fp - frame) - sp` 在 A64 上恒为 0（正常帧已扣），仍会**每个回边都 deopt**；文档「两侧共同语义 = 操作数栈溢出保留区达一个全帧」的结论在 A64 上无法成立。因此规格 Scenario「两架构语义一致」（`specs/f-jit-backend/spec.md:35-38`）只对拍结果/错误码，永远无法证伪守卫是否存在。③ 本部分不重复 part5 已报的「重入链无深度守卫」（`part5.md` 发现 #9）——本条只说：**已有的回边守卫在 A64 上是空指令，且文档把原因写错**。
- **建议**：把 design §1 的 A64 行改成事实描述——「A64 的操作数栈指针是 `x20`，`sp` 只做帧分配；`sub (shifted register)` 的 Rm=31 是 XZR，当前 A64 守卫实际比较的是 `fp - frame` 与阈值，恒不触发」；并把 A64 守卫要么按 `x20` 重写（`sub x11, x11, x20` 需 extended-register 编码）、要么在 spec 里明确「A64 不发 STACK_GUARD，余量由 `x20` 静态上界 `maxStack` 保证」，去掉「两侧对齐」的措辞。

### [一般][存量] x86 回边守卫的规格阈值与跳转助记符同实现（以及同仓 `jit-bytecode-m1.md`）都不一致，按规格写出的阈值使守卫恒不触发

- **位置**：`f_jit/doc/spec/align-x86-loop-back-stack-guard/specs/f-jit-backend/spec.md:14-17`、`20-21`；`design.md:9`、`22-33`、`48-49`；`tasks.md:5-7`、`11-13`
- **来源**：存量（工作区快照；`git log -L 1019,1035:X86Lower.cj` 显示 2026-10-22 的落地提交 `bc3718d38` 用的就是 `reserve + jbe`，即规格从第一天起就与代码不符，不是后续漂移）
- **判据**：review-checklist §13（规格与实现漂移）、§3（文档描述的分支实际不可达）、§14（机制护栏与规格脱节）
- **证据**：静态确定 —— 规格要求阈值 `frame = frameSize(nLocals, maxStack)`（**全帧**）且「`overflow < frame` ⇒ 继续」。实现 `X86Lower.cj:1026-1031`：`frame` 只用于算帧底，阈值另取 `reserve = 8 * (maxStack + 1)`，判定用 `jbe`（`0F 86`，`BackendSelector.cj:311-313`），即「`overflow <= reserve` ⇒ 继续」。同仓当前设计文档 `doc/jit-bytecode-m1.md:2045` 与 `doc/spec/f-jit-m1/verify.md:252-254` 写的都是 `reserve + jbe`，只有本变更的 spec/design/tasks 还写 `frame + jb`。按规格的阈值推：`frame = align16(40 + 8*(nLocals+maxStack))`，正常路径最大溢出 `8*maxStack`，恒小于 `frame` ⇒ 规格 Scenario「溢出超过全帧才 deopt」（`spec.md:29-33`）在实现里**不可能发生**；只有实现采用的 `reserve` 阈值才可能触发。字节级护栏也对不上：`design.md:48-49` 说断言 `0F 82`（`jb`）、把方向改回 `0F 8D`（`jge`）会红，实际 `X86Lower_test.cj:96-106` 断言的是 `0F 86`（`jbe`），且 `emitJb()`（`BackendSelector.cj:306-308`）已无调用者。
- **描述**：规格把「全帧」当阈值并写成硬要求，与实现（保留区）语义不同：按规格实现会让守卫永远不触发（等于删掉），按实现理解规格则会误判「守卫比实际更松」。当前唯一可执行的护栏（字节断言）也与文档描述的方向/助记符不一致，后续任何人「按规矩对齐」都会把 `jbe` 改回 `jb` 并改阈值，进而把守卫改成死分支。
- **建议**：以实现为准改三处——`spec.md` 阈值改 `8 * (maxStack + 1)`（操作数栈保留区）、判定改「`overflow <= reserve` ⇒ 继续」，Scenario 改「超出保留区才 deopt」并在 Purpose 里删掉「全帧」的共用语义；`design.md` §2 的伪码与 §4 的 `0F 82/0F 8D` 同步为 `jbe`/`0F 86`；`tasks.md` 1.1/2.1 的「`jb ok`」同步。

### [一般][存量] 「正常回边不退化」的验收证据不成立：引用的用例在首个安全点就被 deadline 中断，另两个「护栏」只断言字节或只打印

- **位置**：`f_jit/doc/spec/align-x86-loop-back-stack-guard/design.md:50-51`、`tasks.md:21-22`、`proposal.md:42-43`；`specs/f-jit-backend/spec.md:23-27`
- **来源**：存量（快照；实现与用例均未变）
- **判据**：review-checklist §6.1（热点/退化结论必须有可复核数据）、§13（验收口径与证据不符）、§14（门禁形同虚设）
- **证据**：静态确定 —— ① 被判据引用的 `p0_6_deadlineInterruptsLoop`（`AnyBridgeCall_test.cj:118-134`）以 `deadline = DateTime.UnixEpoch`（已过期）调 `n = 100000000` 的循环，回边安全点第一时间返回 −2，循环体远未跑完；即使守卫每回边 deopt，桥也会透明重放解释器并照样抛 `InterruptedException`，用例仍然绿。「1.3 ms / 毫秒级完成」只证明「中断很快」，不证明「未退化」。② `PerfCompare_test.jitVsInterpVsCjnative`（`src/compiler/PerfCompare_test.cj:96-104`）只 `println` 比值，没有任何阈值断言。③ `X86Lower_test.loopBackStackGuard`（`X86Lower_test.cj:96-106`）只断言指令字节；A64 侧没有任何守卫相关用例（`grep STACK_GUARD|deopt src/backend/A64*_test.cj` 为 0 命中）。
- **描述**：该变更的风险表写「方向写反 ⇒ `p0_6`/`PerfCompare` 立刻暴露」，实际两条路径都不会红：`p0_6` 在首回边即退出，`PerfCompare` 无断言，字节断言只能证明「发了几条指令」，不能证明「正常路径不 deopt」。于是一个「每回边 deopt」的回归（循环全落解释器，结果仍正确）在 CI 里完全静默——这正是本次改动声称要防的那类事故。
- **建议**：补一条真正的行为护栏：不带 deadline 调 `{ n => while (i < n) {...} }`（如 `n = 2_000_000`），断言端到端耗时低于解释器的某个宽松倍数（例如 < 1/4），或直接埋点比较「JIT 调用次数 / deopt 次数」（`ctx.errCode` 不落盘，可在桥侧计 `-1` 次数，断言为 0）；A64 侧同样加一条「守卫不因正常回边触发」的计数断言。`p0_6` 只保留为中断语义用例，不再引用为性能证据。

### [一般][存量] 规格承诺的「值型键承载形态无关、异值必异键」在实现上不成立：跨类型同形 + 未覆盖类型的装箱键塌成空串

- **位置**：规格 `f_jit/doc/spec/close-f-jit-out-of-checklist-findings/specs/f-jit-bytecode-format/spec.md:7`（另见 `design.md:26-32` 的 D3 不变式）；实现对照 `f_jit/src/bytecode/CanonKey.cj:30-43`、`52-54`，`f_jit/src/runtime/HandleTable.cj:371-384`，`f_jit/src/runtime/IterTable.cj:240-251`，`f_jit/src/bytecode/ConstRegistry.cj:412-414`
- **来源**：存量
- **判据**：review-checklist §11（契约与实现不符、静默错值）、§13（规格与实现漂移）、§2（同一格式两处各写一份）
- **证据**：静态确定（键生成）+ 待确认（触发面）—— 规格写「同值必同键、异值必异键；同一个 `Float64` 无论裸 cell 还是 `Any` 盒承载，键文本 SHALL 相同」。实现里 `CanonKey.i64(v)` 与 `CanonKey.cell(v)` 都是 `i:${v}`（两函数体逐字相同），`f64(bits)` 也落到 `cell(bitsAsI64(bits))`：于是 `Int64 4609434218613702656` 与 `Float64 1.5`（位模式即该整数）得到同一 token。另一面，`HandleTable.canonKeyOf`（`:374-383`）只列了 String/Float64/Decimal/DateTime/Duration/Range/JitRegex，`Int64`、`Bool`、`List`、`Map` 全落 `case _ => ''`；`IterTable.mapKeyOf`（`:245-249`）解开 `JitAnyBox` 后正是把内层值交给它。而 `ConstMapKey` 的相等与哈希**只按 token**（`ConstRegistry.cj:408-414`），token 相同即同键。
- **描述**：两条可判定的后果。① 跨类型撞键：`Map<Any, V>` 里同时存在 `1.5f64` 与 `Int64(0x3FF8000000000000)` 时，后写覆盖前写、两者互查命中同一条目，静默返回错值（规格的「异值必异键」不成立）。② 装箱键塌成空串：`Any` 盒里的 `Int64`/`Bool`/`List`/`Map` 键全部得到 `''`，任意两个这样的键互相覆盖——这与 X2 修掉的「`JitAnyBox` 未解包导致装箱键塌成一个键」（`verify.md:34`）是同一类缺陷，只是解包之后仍未覆盖内层类型。规格里「List/Map → 递归 `l[...]`/`m[...]`」的分支在运行期键路径上也没有对应实现。触发面待确认的点：前端是否会在 `Map<Any, …>` 里把值型键装箱（若总是直传裸 cell，则 ② 只在宿主手工 `pinAnyBox` 作键时可达）。
- **建议**：把键域补成满射且单射——`canonKeyOf` 补 `Int64`(`cell`)、`Bool`、`List`/`Map`（递归）分支，`case _` 改为返回带类型名的兜底键（如 `?<runtimeType>:${hash}`）或直接抛契约错，不要返回 `''`；若要保留「承载无关」，则要求 token 至少带类型段（`i:`/`f:` 的取舍需重新裁定：真正需要统一的是「同一值两条承载路径」，而不是「不同值同键」）。同时把 `i64` 合并进 `cell`（两者函数体已逐字相同，见证据），避免同一格式三处维护。

### [一般][存量] 用例登记表与任务表两张表各自维护、内容已漂移：一个承诺的用例不存在，另一批用例名/落点全不对

- **位置**：`f_jit/doc/spec/close-f-jit-out-of-checklist-findings/test-plan.md:9-19` 与 `tasks.md:7-27`、`verify.md:21-26`；规格 `specs/f-jit-differential-acceptance/spec.md:5`
- **来源**：存量
- **判据**：review-checklist §2（同一张表跨文件复制后漂移）、§13（文档与实现不符）、§14（承诺的用例缺失）
- **证据**：静态确定 —— ① `test-plan.md:18` 登记 X2-c `constMapFloatKeyHitWithBoxedKey`（落点 `A5MapKey_test`），全仓 grep 只有这一行文档命中，用例不存在；`verify.md:22` 却写「新增「装箱键命中常量条目」用例」。② `test-plan.md:12` 写 `strictFpEmitsFdivChk` / `strictFpChangesDivisionByZero` 在 `StrictFp_test`，实际发射级用例在 `src/compiler/StrictFpCodegen_test.cj:43`（`strictEmitsFdivChk`）、`:62`、`:70`，行为级是 `src/StrictFp_test.cj:51/61/76`；`test-plan.md:15` 的 `callContextHasOnlyCallLevelOptions` 实际叫 `CallContext_test.cj:33 defaultsFollowSpec`；`test-plan.md:16-17` 的 `f64KeyEqualsCellKey` / `boxedAndRawFloatKeyAgree` 实际带 `x2_` 前缀（`CanonKey_test.cj:68/82`）。③ 规格要求「用例名 SHALL 含缺陷编号」，但 X1 的 5 条（`CompileOptions_test.cj:34/43`、`CompilePipelineVersion_test.cj:37/52/64`）与 X3 的 6 条都没有 `x1_`/`x3_` 前缀，只有 X2 加了。
- **描述**：`tasks.md` 的用例名是对的，`test-plan.md` 是自己另写的一张表，两表并行维护后各自漂移；对外说「每条缺陷都有用例」时，按 test-plan 去点验会点不到（最典型是 X2-c 根本不存在）。这直接削弱该变更自己立的「清单外发现同等留痕」门槛。
- **建议**：删掉 `test-plan.md` 的用例名副本，改为指向 `tasks.md` 的条目号（单一事实来源）；若保留，按实际符号名重写并补 `x1_`/`x3_` 前缀；X2-c 要么补一条 `A5MapKey_test` 的端到端用例（装箱键命中常量 Map 条目），要么在 `verify.md` 里把「已新增」改成「由 `x2_*` 覆盖键层、未覆盖端到端」。

### [轻微][存量] `align-x86-loop-back-stack-guard` 缺 `verify.md`，而 tasks 4.2 已勾选「verify.md 追加记录」

- **位置**：`f_jit/doc/spec/align-x86-loop-back-stack-guard/tasks.md:32-33`；目录清单 `f_jit/doc/spec/align-x86-loop-back-stack-guard/`（无 `verify.md`）
- **来源**：存量
- **判据**：review-checklist §14（半成品 / 勾选与产物不符）、§13（审计链断裂）
- **证据**：静态确定 —— 该目录只有 `design.md`、`proposal.md`、`tasks.md`、`specs/`；`ls` 无 `verify.md`。同批其他四个变更目录都有 `verify.md`。
- **描述**：项目自己的规矩是「不允许出现任务已勾选但没有对应产物」（`doc/spec/f-jit-m1/design.md:171`），这里恰好相反：勾了「verify.md 追加 2026-10-22 第三轮记录」，产物不存在，于是这轮唯一的文字证据（方向教训、回归数字）只剩 design/proposal 里的转述。
- **建议**：补 `verify.md`（哪怕只有「回归 1099/1099、`p0_6` 毫秒级、方向教训」三行），或把 4.2 改为未完成并注明「记录并入 design §5」。

### [轻微][存量] `Version.LATEST` 以字面量 `3` 复制 `M3_MAJOR`，与设计文档「`LATEST = M3_MAJOR`」不符

- **位置**：`f_jit/doc/spec/close-f-jit-out-of-checklist-findings/design.md:11`；实现 `f_jit/src/base/Version.cj:59-62`
- **来源**：存量
- **判据**：review-checklist §2（字面量复制）、§13（文档与实现不符）
- **证据**：静态确定 —— 文档写「新增 `Version.LATEST = M3_MAJOR`」，代码是 `public static const LATEST: UInt16 = 3u16`，与 `M3_MAJOR: UInt16 = 3u16` 各写一遍；`supportedMajors()`（`:70-72`）用的又是 `M3_MAJOR`，两处将来扩版本会分叉。
- **建议**：`LATEST` 直接引用 `M3_MAJOR`（常量引用常量），保持文档口径；若刻意用字面量表达「对外承诺值」，就在注释里写明并要求同步检查。

### [一般][存量] 设计把 `JitContext` 记为「已结案 `protected`」，实现是 `public`：机器码 ABI 类型对外可达

- **位置**：`f_jit/doc/spec/f-jit-m1/design.md:54`（D2：「`JitContext` / `Engine` / `JitValue` … 用户面无消费路径（`protected`）」）、`:81`（D6：「`JitContext` 是 `protected` 访问器类」）；实现 `f_jit/src/runtime/JitContext.cj:114`（`public class JitContext`）、`:147`（`public static func wrap`）、`:304`/`:309`（`public readAt` / `writeAt`），同文件 `:27`（`public class NativeMem`）、`:72`（`public class CtxFlags`）
- **来源**：存量（`git log -S "public class JitContext" -- f_jit/src/runtime/JitContext.cj` 只命中建模块提交 `8d1b1900a`，自 M1 起即为 `public`，之后无改判提交）
- **判据**：review-checklist §11（契约与实现不符）、§13（文档与实现不符）、§12.1（ABI 契约的可见性边界）
- **证据**：静态确定 —— 修饰符与设计文本直接冲突；「跨模块不可见」的可判定性在 `BaseVisibility_test.cj:35-41` 有明文：「本文件位于本模块内，`protected` 在模块内必然可见，因此「跨模块不可见」无法用运行期用例表达」——即 `public` 就等于对外可达，`protected` 才是模块内可见。同类设计声明里 `CompileCache`/`AdapterRegistry`/`CompilePipeline` 至今仍是 `protected`（`CompileCache.cj:30`、`AdapterRegistry.cj:27`、`CompilePipeline.cj:51`），说明该档位可用，不是被迫公开。`doc/design-m1.md:1017`/`:1026` 把这条写成「**已结案 2026-10-11 裁定：`protected`**」，与实现相反。
- **描述**：`JitContext` 承载 64 B 非托管 ctx，设计、字节码规格与类注释三处都写明「机器码按固定偏移直接读写，用户写坏即破坏不变量」。现在它是 `public` 且带 `public wrap/readAt/writeAt`，下游 `import fountain::f_jit.runtime.JitContext` 即可绕过桥直接改错误槽、窗口基址、`hwCap` 等字段——设计宣称的「用户能管句柄 ≠ 能碰 ctx」在可见性层面不成立。旁证显示放宽可能并非有意：后续 `feat-f-jit-parallel-call/design.md:73` 把 `JitContext.mallocCount/freeCount` 当 `public static var` 使用，但没有任何一份设计记录了「`protected` → `public`」的改判，因此这更可能是落地时的疏漏而非裁定变更。
- **建议**：二选一并留痕——① 收窄为 `protected`（与 `Engine`/`JitValue`/`CompileCache` 一致；测试在模块内不受影响，`BaseVisibility_test` 已验证 `protected` 在模块内可用）；② 若确为计数/测试需要而有意公开，在 `doc/design-m1.md` D2 结案条目与 `f-jit-m1/design.md` D2/D6 写明改判理由与暴露边界，并至少把 `wrap/readAt/writeAt` 收窄为 `protected`，只留计数器公开。

> 存量缺陷共 8 条（一般 6、轻微 2），是否纳入修复待用户决定。

## 范围外提示（不计入本部分统计）

- `A64Emitter.subImm` 用 `imm & 0xFFF` 截断，而 `A64Compiler.cj:75` 的 `sub sp, sp, frame` 直接吃 `frameSize`：`nLocals + maxStack + 1 > 505` 时 `frame > 4095` 会被截断，帧分配不足（helper 帧将覆盖 locals），建议在 `A64Compiler` 里加 `frame > 4095` 的降级分支（另见 `A64Emitter.cj:522-537` 已有分块 `addOff` 可复用）。
- `f_jit/src/base/CallContext.cj:22-25` 的类注释表格仍列已删除的 `args` 字段，与新口径矛盾（该文件属 base 部分）。

## 优化可行性方案

本部分 20 个文件均为规格/设计文档，没有独立的堆 / CPU 改造对象：唯一实质性能面（回边守卫的指令开销）已由 `doc/optimize-call-path.md:411` 给出 662→15 ns/轮 的既有基线，但「剩余 15 ns/轮」中守卫占比没有 profile 数据，只能进下方「待验证假设」，不立优化项，也不写成结论。堆内存方向无对象持有描述可评。

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | aarch64 空循环「665→15 ns/轮」修复后，回边守卫的 4 条指令（`mov/sub/sub/mov+cmp+b.lo`）可能已占剩余开销的主要部分，修好守卫后还会再涨 | `f_jit/src/backend/A64Lower.cj:367-373`、基线 `doc/optimize-call-path.md:411` | 守卫序列的自耗时占比 | `cjprof record` 跑空 `while(true)`（n=1e8，单线程，`-O2`），与「删掉守卫」的临时产物对照，5 轮中位数 |
| 2 | x86 端 `overflow` 只有在「违背 `maxStack` 保留区」时才非零，真实前端产物里 deopt 恒为 0，守卫是纯防御分支 | `f_jit/src/backend/X86Lower.cj:1023-1031` | 真实负载上的 `-1` deopt 次数 | 桥侧按 `ctx.errCode == -1` 计数，跑全量用例 + 3 个真实业务单元，统计命中数 |
| 3 | 装箱值型键（`Int64`/`Bool`）在 M3 `Any` 容器路径上的实际出现频率低到「塌成 `''`」不会被业务触发 | `f_jit/src/runtime/HandleTable.cj:374-383` | 装箱键调用次数与类型分布 | 在 `mapKeyOf` 的 `case Some` 分支加类型计数埋点，跑含 `Map<Any, …>` 的 M3 用例与差分集 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `doc/spec/align-jitfunction-close-naming/specs/f-jit-facade-bridge/spec.md` | .md | ✅ | `close(timeoutMs)` / `close()` / `isClosed()` 三者与 `JitFunction.cj:227/471/523` 逐条对应；超时计时缺陷见 part7（不重复计数） |
| 2 | `doc/spec/align-jitfunction-close-naming/tasks.md` | .md | ✅ | T1–T5 均有对应落点（`JitFunction.cj` 与 README/docs）；`unloadFn` 仅存于历史归档，符合 T4 |
| 3 | `doc/spec/align-jitfunction-close-naming/verify.md` | .md | ✅ | 一致性表可复核；「9 passed」无法在本轮重跑（只读审查），结论留档自洽 |
| 4 | `doc/spec/align-x86-loop-back-stack-guard/design.md` | .md | ✅ | A64 前提错误、x86 阈值/助记符漂移 → 发现 #1 #2；缺 verify.md → #6 |
| 5 | `doc/spec/align-x86-loop-back-stack-guard/proposal.md` | .md | ✅ | 同上（A64 `frame` 语义表）；「全量 1098 例」为当时口径 |
| 6 | `doc/spec/align-x86-loop-back-stack-guard/specs/f-jit-backend/spec.md` | .md | ✅ | 阈值「全帧」使守卫不可达、`jb` 与实现 `jbe` 不符 → #2；「两架构语义一致」场景不可证伪 → #1 |
| 7 | `doc/spec/align-x86-loop-back-stack-guard/tasks.md` | .md | ✅ | 1.1/2.1 的 `jb`/`0F 82` 与测试 `0F 86` 不符 → #2；4.2 产物缺失 → #6 |
| 8 | `doc/spec/clarify-last-escaped-scope/proposal.md` | .md | ✅ | 与实现一致：`lastEscaped` 写在锁内（`JitFunction.cj:662-673`）、读经 `lastEscapedClosure` 加锁（`:539-545`） |
| 9 | `doc/spec/clarify-last-escaped-scope/tasks.md` | .md | ✅ | T1.1–T3.3 与代码/用例一一对应，无缺口 |
| 10 | `doc/spec/clarify-last-escaped-scope/verify.md` | .md | ✅ | diff 片段与 `JitFunction.cj` 现文逐行一致；「没有可测行为差异」的自评诚实 |
| 11 | `doc/spec/close-f-jit-out-of-checklist-findings/design.md` | .md | ✅ | D3 不变式与实现冲突 → #4；D1「`LATEST = M3_MAJOR`」与代码不符 → #7 |
| 12 | `doc/spec/close-f-jit-out-of-checklist-findings/proposal.md` | .md | ✅ | X1–X4 四项在代码里均能定位；「默认产物 `strictFp=false`」为当时口径（后由 `flip-f-jit-strictfp-default` 改为 true，见总评） |
| 13 | `doc/spec/close-f-jit-out-of-checklist-findings/specs/f-jit-bytecode-format/spec.md` | .md | ✅ | 「承载形态无关/异值必异键」不成立 → #4；List/Map 递归键在运行期无实现 |
| 14 | `doc/spec/close-f-jit-out-of-checklist-findings/specs/f-jit-compiler-frontend/spec.md` | .md | ✅ | 「先判 `if` 再取块」与 `A4Frontend_test.p1_4_elseIfParses` 覆盖一致 |
| 15 | `doc/spec/close-f-jit-out-of-checklist-findings/specs/f-jit-differential-acceptance/spec.md` | .md | ✅ | 「用例名含缺陷编号」被本变更自身的 X1/X3 用例违反 → #5 |
| 16 | `doc/spec/close-f-jit-out-of-checklist-findings/specs/f-jit-facade-bridge/spec.md` | .md | ✅ | 「`invoke` 为唯一带选项入口」已被后续 `align-call-entry-spec` 改为 `call` 重载（历史口径，不报）；`callForFn` 串行化条款见 part7 |
| 17 | `doc/spec/close-f-jit-out-of-checklist-findings/tasks.md` | .md | ✅ | 与 test-plan 两表漂移 → #5；B1–B6 勾选与代码/用例基本对应 |
| 18 | `doc/spec/close-f-jit-out-of-checklist-findings/test-plan.md` | .md | ✅ | 用例名/落点与实物不符、X2-c 不存在 → #5 |
| 19 | `doc/spec/close-f-jit-out-of-checklist-findings/verify.md` | .md | ✅ | 红→绿证据具体；「新增装箱键命中用例」与实物不符 → #5 |
| 20 | `doc/spec/f-jit-m1/design.md` | .md | ✅ | 历史设计；D1–D16 与当前实现的主体结构一致（六包、ctx 非托管、句柄 ID 形态）；D2/D6 的 `JitContext` 可见性未落实 → #8；实施注意 §1 的 AST 枚举坑仍有 `AstShape.cj` 佐证 |

合计：`.cj` 0 个 / `.md` 20 个 / 共 20 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 5 | #1（设计前提与 ISA 不符）、#3（验收证据无效）、#4（键域不单射，正确性）、#5（登记表漂移）、#8（可见性契约与实现不符，设计/安全性）；本部分无外部输入与凭据面 |
| §1 死代码 | 1 | 文档层面的「死分支」：#2 按规格阈值推得的 deopt 分支不可达，已并入 #2；另逐个核对文档引用的符号是否仍存在（`unloadFn`/`unload` 只存于历史归档、`invoke` 已被 `call` 重载取代、`constMapFloatKeyHitWithBoxedKey` 不存在），除 #5 外无「文档引用已删除符号」 |
| §2 重复逻辑 | 1 | `tasks.md` 与 `test-plan.md` 两张用例表复制后漂移（#5）；另核对 `CanonKey.i64` 与 `cell` 函数体逐字相同、`Version.LATEST` 字面量复制 `M3_MAJOR`（#4/#7 已列） |
| §3 空实现 | 0 | 本部分无函数体；「承诺有行为但实现为空」的唯一候选是 A64 回边守卫（形式上发了指令，语义为空），已按 §13/§4 记入 #1，不重复计 §3 |
| §4 栈溢出 | 1 | #1：A64 侧余量守卫恒不触发，等于没有守卫（重入链缺深度守卫已由 part1/part5 统计，不重复） |
| §5 OOM | 0 | 本部分无容器/预分配/缓存持有描述；键域塌陷是错值不是增长，已归 #4 |
| §6.1 热点瓶颈 | 0 | 无本轮 profile/bench 数据；`doc/optimize-call-path.md:411` 的 662→15 ns/轮 是既有基线，只能支撑「待验证假设 #1」，不足以支撑热点结论 |
| §6.2 大粒度锁 | 0 | 文档未引入新的锁结构；`close` 自旋取锁已由 part7 报告 |
| §6.3 并发串行 | 0 | `callForFn` 的串行化条款属 part7；`clarify-last-escaped-scope` 反而消除了「锁外写单元字段」的竞争点（已核对代码），无新增串行段 |
| §6.4 低效算法 | 0 | 无算法描述；回边守卫是固定 4–6 条指令，未测占比，不判 |
| §7 降堆内存方案 | 0 | 文档无对象持有/生命周期可量化描述 |
| §8 降 CPU 方案 | 0 | 唯一候选（回边守卫指令）缺占比数据，列入待验证假设 #1 |
| §9 local mode 可行性 | 0 | 本部分无函数内临时对象描述；`f-jit-m1/design.md` 的 D6 已选择「非托管 malloc + 访问器」，与 local mode 方向不冲突也不收益 |
| §11 现有代码的 BUG（存量） | 2 | #1（A64 守卫空操作 + 文档错误归因，含 `0x07` 同型）、#4（键域塌陷导致错值）；均按文档承诺面报，代码侧定级留给对应部分 |
| §12 并发安全与锁粒度 | 0 | 已核对 `clarify-last-escaped-scope` 声称的三处改动全部落地（写锁内、读加锁、注释口径），未发现新的共享可变状态；`close` 自旋排空属 part7 |
| §14 功能完备性与 README 覆盖 | 2 | #5（X2-c 用例承诺但不存在）、#6（`verify.md` 承诺但不存在）；本部分不涉及 README |
| 文件覆盖（§13 等） | 20/20 | 无缺失 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 6 |
| 轻微 | 2 |
| 优化方案（堆内存 / CPU） | 0 / 0 |

## 总评

本部分 20 个文件都是「已经实施完的变更留档」，整体质量偏上：`clarify-last-escaped-scope` 与 `align-jitfunction-close-naming` 两份的改动范围、落点、自评（「没有可测行为差异，只主张语义明确」）都与代码逐条对得上，属于可信的审计记录。

风险集中在两处。**第一处是后端守卫这条链**：x86 规格写的阈值（全帧）与实现（保留区）从落地第一天起就不一致，按规格写出来守卫恒不触发；A64 侧更严重——设计文档用一句「`x31` 的减法在该编码中不落实」解释「守卫恒不触发」，与 AArch64 编码事实相反，真实原因是 `subReg(...,31)` 读的是 XZR；两处叠加后，「回边栈余量守卫」在两个后端上一个是死分支、一个是空指令，而验收证据（`p0_6` 毫秒级、`PerfCompare` 打印）都无法证伪。这条不构成可复现崩溃（`maxStack` 静态分配仍兜住正常路径），但它是「以为有防线、其实没有」的典型，且文档给出的解释会把后来者引向改序言这种危险动作，建议优先修正文档与护栏。**第二处是键规范**：X2 把 `f:` 前缀合并掉之后，键域既不是单射（`Int64` 与同 bit 的 `Float64` 撞键）也不是满射（`Int64`/`Bool`/`List`/`Map` 的装箱键落到 `''`），`ConstMapKey` 又只按 token 比较，`Map<Any, …>` 场景会静默错值；该缺陷是本次修复「修而未净」的延续，值得单开一条变更。

其余 2 条轻微项（缺失的 `verify.md`、`LATEST` 字面量复制）成本低，可与上述文档修正一起批量处理；#5（两张用例表漂移）虽定为一般，改动也只是删一份重复表。**第三处是可见性契约**：`JitContext` 被设计写死为「已结案 `protected`」，实现却是带 `public wrap/readAt/writeAt` 的 `public class`，与仍保持 `protected` 的 `CompileCache`/`AdapterRegistry`/`CompilePipeline` 不一致；它不产生运行期错误，但把 ABI 契约的边界让掉了一截，建议与上面两处一并收口。另注一条历史口径，不计入发现：`close-f-jit-out-of-checklist-findings` 的 proposal/design/verify 三处写「默认产物逐字节不变（`strictFp=false`）」，其后 `flip-f-jit-strictfp-default` 已把缺省改为 `true`（`CompileOptions.cj:45`、`doc/design-m1.md:175`）；按归档文档「当时自洽」的判据不算缺陷，但读这三份文件的人需要知道默认值已翻转。
