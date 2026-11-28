# f_jit 模块审查报告（第 4/38 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_jit`（本部分 1 个文件：`doc/jit-bytecode-m1.md`，2304 行全文读完）
- **基线**：工作区快照（`120fd2542`，`git diff` 为空）⇒ 全部问题记「存量」；本部分以「规范承诺 ↔ 实现取证」为落点，实现侧现场对照 `OpInfo` / `HelperId` / `LocalType` / `TypeToken` / `FbcReader` / `FbcRuleSet` / `JitContext` / `HandleTable` / `DbgDump` / `Helpers` / `Interp` / `X86Lower` / `A64Lower` / `A64Compiler` / `A64Emitter` / `Compiler` / `CompilePipeline` / `JitFunction` / `PredefinedFunction`
- **审查重点**：动态调用/桥接正确性（typecode 分支表、opcode/helper 编码）、句柄与资源生命周期、并发安全、递归与栈溢出、死代码、重复逻辑
- **报告版本**：v2（第 4/38 部分；在 v1 基础上补 3 条一般、3 条轻微并重排编号，全部结论重新取证，未沿用 v1 结论）

## 发现

### [严重][存量] #1 AArch64 的 `DUP2`（0x18）降低把顶两格顺序颠倒，与 §5 语义和解释器不一致

- **位置**：`src/backend/A64Lower.cj:208-212`（`x9=[x20]`、`x10=[x20+8]`，`pushX(9)` 再 `pushX(10)`）；规范同错：`doc/jit-bytecode-m1.md:2083`（A64 列 `stp x10,x9,[sp,#-16]!`）；定义侧 `doc:247`（`DUP2: a b → a b a b`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11「契约与实现不符」；§0 I7 / §12.7「三引擎逐位一致」
- **证据**：静态确定 —— 以栈底→栈顶 `1,2` 为例：
  - 解释器 `src/runtime/Interp.cj:286-290`：`b=顶=2`、`a=次顶=1`，`push(a)`、`push(b)` ⇒ `1,2,1,2` ✓
  - x86 `src/backend/X86Lower.cj:801-804`：两次 `pushMemRsp(8)`，第二次读到已被下移的 `[rsp+8]`(=b) ⇒ `1,2,1,2` ✓
  - aarch64：压 2 再压 1 ⇒ `1,2,2,1` ✗（等价「复制顶两格后交换」）；§12.4 的 `stp x10,x9,[sp,#-16]!` 把 `a` 放在更低地址（=新栈顶），同为 `a,b,b,a`
- **描述**：后端语义错误而非笔误。前端当前不发射 `DUP2`（`Op.DUP2` 仅见于 `src/compiler/Ops.cj:46` 与栈效应表），故现有 `compile(source)` 产物不受影响；但分发入口接受的任意 `.fbc` 若含 `0x18`，aarch64 结果与解释器/x86 不同，直接违反 I7。一旦前端启用 `DUP2`，影响面扩大到全部平台差异用例
- **建议**：A64 改为先压次顶再压顶（`pushX(10)`→`pushX(9)`），或 `stp x9,x10,[sp,#-16]!`（`x9`=顶时把顶放低地址）；同步修 §12.4 A64 列；补 T2 差分用例（`PUSH 1/2 + DUP2 + 4×POP/RET`，断言 `1,2,1,2`）

### [严重][存量] #2 文档承诺的分发入口 `compile(unit: SourceUnit)` 在公开 API 上不存在

- **位置**：规范 `doc:762`（`public func compile(unit: SourceUnit): JitFunction`）、`doc:1065`（§8.4 同名方法）；实现 `src/Compiler.cj:185`（只有 `compile(source: String)`）、`src/CompilePipeline.cj:51`（`protected class CompilePipeline`）、`:95`（`public static func runUnit(raw: Array<UInt8>, c: Compiler): JitFunction`，但类不可达）、`src/base/SourceUnit.cj`（唯一消费者是测试）
- **来源**：存量（快照）
- **判据**：review-checklist §14.1「承诺了但没实现」、§13「示例代码不能用」
- **证据**：静态确定 —— `grep "func compile("` 全仓只有 `Compiler.compile(source: String)` 与后端 `Backend.compile(unit: LoadedUnit, …)`，无接收 `SourceUnit` 的公开入口；承载分发管线的 `CompilePipeline` 为 `protected`（模块内可见），`public static runUnit` 随类一同不可达；`SourceUnit` 仅被测试构造；管线还忽略 `SourceUnit.entryFn`（改用容器头），即便公开也与文档语义不同。底层公开件只能拿到 `LoadedUnit`/`JitArtifacts`，`JitFunction` 的 public 构造只收闭包（`src/JitFunction.cj:117-134`），不构成 `unit → JitFunction` 统一入口
- **描述**：分发模型（T1 黄金字节码、共享管线与缓存、装载 user hid → 拒绝）是 §8/§8.4/§11.8 的核心承诺，但用户面能把 `.fbc` 变成 `LoadedUnit`，却没有公开途径变成可调用的 `JitFunction`——按文档写 `compiler.compile(unit)` 直接编译失败，只能自行复刻桥（ctx、常量镜像、句柄表、转储缓冲）。这是契约能力缺失，不是改名
- **建议**：二选一——补 `public func compile(unit: SourceUnit): JitFunction` 并明确 `entryFn` 取 `unit.entryFn` 还是容器头；或撤回 §8 ①b / §8.4 / §11.8 的「分发装载」与 `SourceUnit`。无论哪种都补一条公开面可达性用例

### [一般][存量] #3 门面签名漂移：`unload`/`isUnloaded` 实为 `close`/`isClosed`，`Compiler.init` 与 `unregisterFunction` 形态亦不同

- **位置**：规范 `doc:785-786`（`unload(timeout!: ?Duration = None)` / `prop isUnloaded`）、`doc:1049-1057`（`init(name!: = "compiler", opts!: , maxPredefined!: = 256)`、`unregisterFunction(name): Unit`）、`doc:1228-1230`；实现 `src/JitFunction.cj:227`（`close(timeoutMs: Int64): Bool`）、`:471`（`isClosed()`）、`:523`（`close(): Unit`）、`src/Compiler.cj:61`（位置参数 `init`）、`:87`（`unregisterFunction(...): Bool`）
- **来源**：存量（快照）
- **判据**：review-checklist §13「API/默认值与源码不符」「示例不能用」
- **证据**：静态确定 —— ① 生命周期方法名、参数类型（`Duration` → `Int64` 毫秒）、默认值、`prop`→方法全变，§8.7 整节仍以 `unload` 命名；② `Compiler.init` 文档为带默认值的具名参数，实现为位置参数（另有 `init()`/`init(opts:)`）；`doc:1105` 的 `Compiler(name: "demo", …)` 因此不可编译；③ `unregisterFunction` 文档返回 `Unit` 且「未注册 → `CompileException`」，实现返回 `Bool`（未注册 `false`，不抛）；且 `CompileException` 这个类型在全文与全仓都不存在
- **描述**：门面改名后未回写规格：按 §8.4 示例/§8.7 编码的宿主一律编译失败，且错误处理写法（抛 vs 返回布尔）完全不同。另 §8.2「需要自定义 `CallContext` 时改用 `invoke`」亦失效——`invoke` 是 `private`，而实现已提供 `call<T>(args, options: CallContext)` 公共重载（`src/JitFunction.cj:159`，`src/base/CallContext.cj:34-45`）
- **建议**：以实现为准改文档（`close(timeoutMs)` / `isClosed()` / 位置参数 / `Bool`），或保留 `unload` 别名并标弃用；补 `call<T>(args, options)` 并删除「改用 invoke」句；`unregisterFunction` 的失败语义二者择一写死

### [一般][存量] #4 `CALL_HOST` 操作数编码两处口径冲突：规范 `u16 fid + u8 argc`（4 B） vs 实现 `u8 argc`（2 B）

- **位置**：规范 `doc:355`、`doc:1539`（`OpInfo(0x79, "OP_CALL_HOST", "u16 u8", 4, …)`）；实现 `src/bytecode/OpInfo.cj:255`（`'u8', 2`）、`src/backend/X86Lower.cj:1054`（`helper(63, u8(argc)+1, 0)`，只读 1 字节）
- **来源**：存量（快照）
- **判据**：review-checklist §13「格式与源码不符」、§2「同一张表多处 → 行为漂移」
- **证据**：静态确定 —— §5/§10.3 说 4 B 带 `fid`；实现与 `src/bytecode/OpInfo_test.cj:134-149`、`src/bytecode/FbcRuleSet.cj:88-102` 说明 2 B 无 `fid`；`OpInfo.selfCheckOk()` 只校验 `len == 1 + ΣoperandSize(fmt)`，两种口径都「自检通过」，不会暴露冲突
- **描述**：`0x79` 是 M2 起合法的线上操作码，长度决定解码步进：按 4 B 口径解码会越过下一条指令 2 B，整段 code 错位（反汇编、调试器、差分工具、第三方实现全受影响）。M1 汇编期禁用故仓内不炸，但规范自称「数值权威」
- **建议**：回改 §5/§10.3 为 `u8 argc` 并注明「M2 重定义，原 `u16 fid` 已废止」；步进长度由 `OpInfo.len` 单一来源提供，`FbcRuleSet` 不再各写一份

### [一般][存量] #5 `hs_len` 语义与实现相反（文档「UTF-8 字节数」，实现「码点数」），并与自身 String 迭代规范互斥

- **位置**：规范 `doc:1727`、`doc:1916`（`String——索引 + STR_AT`）、`doc:383`（`LEN` =「元素数」）；实现 `src/runtime/Helpers.cj:212-216`（`Int64(s.toRuneArray().size)`）、`src/runtime/Helpers_test.cj:157`（断言「hs_len 按码点」）、`src/compiler/Lowerer.cj:749-775`（`LEN` + `STR_AT` 组合）
- **来源**：存量（快照）
- **判据**：review-checklist §13「规格与实现漂移」、§11「语义与注释不符」
- **证据**：静态确定 —— `STR_AT`/`STR_SUB` 索引域为码点，`for-in` 以 `LEN` 作上界。若按文档（`LEN`=字节数）实现，非 ASCII 串迭代上界大于码点数，`STR_AT` 在越过最后一个码点后必报 `ERR_IDX_OOB(4)`
- **描述**：`LEN` 对 String 的口径是跨指令契约（循环上界、切片、诊断都依赖它）。文档错这一句会直接误导新后端/新语言移植（UTF-16 或字节两种直觉都不对），并让「按文档写的用例」与实现不一致（差分看起来像三引擎不一致，实际是规范错）
- **建议**：§11.4 改为「`hs_len` 返回 Unicode 码点数（与 `STR_AT`/`STR_SUB` 同域）；UTF-8 字节长度需另设 helper（当前无）」；§5 `LEN` 行补「String = 码点数」

### [一般][存量] #6 §9.16 转储头协议写 `[dbgBase]=fnId`，实现写 `fnId+1`（`fnId=0` 与哨兵冲突）

- **位置**：规范 `doc:1348`；实现 `src/runtime/DbgDump.cj:30-35`（首格 `fnId+1`、0 为哨兵）、`:95-110`（`writeOnceStackRaw` 写 `fnId+1`）、报告组装处读出时减 1
- **来源**：存量（快照）
- **判据**：review-checklist §13「文档与实现相反」、§11「契约与实现不符」
- **证据**：静态确定 —— 转储以「首格 == 0」判定未填；入口函数 `fnId` 合法值为 0，若按文档写 0，缓冲永远「看起来未填」，外层传播帧会覆盖它，报告里的 `fnId` 与变量清单来自错误帧（「最深失败帧获胜」失效）
- **描述**：这是「文档协议对合法输入不可实现」，不是措辞问题；实现已订正但只写在代码注释（「§9.16 的实现订正，见 `design-m1.md` §E」），规范读者拿不到
- **建议**：§9.16 改为「`[dbgBase] = fnId + 1`（0 为哨兵，读出减 1）」，并在 T50 验收口径写「入口 `fnId=0` 的转储必须可与未填区分」

### [一般][存量] #7 §12.4「0x90–0xBF 全量路由表」缺 A5–A8 与 H58/H59/H72；`LOOP_BACK` 行仍写无条件 `H22`（与 §5 及实现相反）

- **位置**：`doc:2180-2188`（标题即「**全量** `CALL_HELPER` 路由表」）、`doc:2147`（`LOOP_BACK` = `STACK_GUARD` + `call H22` + `jmp`）、`doc:500`（§5「v0.19 起安全点按需执行…读 `ctx.flags` 的 `DEADLINE` 位」）、`doc:52`（§1 `flags` 位表只有 bit0/bit1/bit2）
- **来源**：存量；其中 `LOOP_BACK` 属**改一处漏一处** —— `git show 51866c43d -- f_jit/doc/jit-bytecode-m1.md` 只改了 §5 两个 hunk（`@@ -488`、`@@ -497`），§12.4 与 §1 未同步
- **判据**：review-checklist §13（自相矛盾）、§14.1（指令有 ISA 行却无降低路由）
- **证据**：静态确定 —— `src/backend/X86Lower.cj:1167-1170` `0xA5→helper(24)`…`0xA8→helper(27)` 有实现，路由表无 A5–A8；`src/compiler/Lowerer.cj:3071-3081` 以 `callHelper(58/59/72)` 直呼正则替换，路由表亦无；`src/backend/X86Lower.cj:1039`、`src/backend/A64Lower.cj:376`、`src/runtime/JitContext.cj:85`（`DEADLINE = 8`）证明按需安全点已落地
- **描述**：① 四条 DEC 指令与三个替换 helper 在「全量」表里缺席——照表实现的第三方/新后端会得到无路由或误判 `ERR_NOT_IMPL`；② §12.4 要求每条回边无条件 `call H22`，与 §5 的 v0.19 语义、与两后端实现都相反，照表实现会重新引入 44× 的循环退化（§5 引 `optimize-call-path.md` §14：662→15 ns/轮）；③ §1 `flags` 位表未含 `DEADLINE`（bit3），§5 却直接依赖它，而 §1 又把 bit0 标为「历史位，运行期不读」——位分配成为单一真相缺口；④ §5 写「v0.19 起」，文档头版本是 v0.18.39，读者无法判断该行为是否已生效
- **建议**：路由表补 A5–A8（H24–H27）与 H58/H59/H72；`LOOP_BACK` 行改为「`STACK_GUARD` → `flags & DEADLINE ? H22 : nop` → `jmp`」；§1 `flags` 补 `bit3=DEADLINE（桥按本次调用 deadline 写入）`；把「v0.19 起」改为当前版本或标注「已实现（`CtxFlags.DEADLINE`）」

### [一般][存量] #8 §12.4 模板 B（`CALL_FUNC`）的收参写法会丢返回值并破坏栈平衡

- **位置**：`doc:2195-2198`（「返回后：`CHECK_ERR`、重写 `fnId`、**结果压栈**、`add rsp,8*argc` 收参」）
- **来源**：存量（快照）
- **判据**：review-checklist §11「语义与实现不符」、§13
- **证据**：静态确定 —— 与同节模板 A（`doc:2192`：结果写回 `args[0]` 槽再 `add rsp,8*(argc-1)`）不一致；实现 `src/backend/X86Lower.cj:437-466`：`movQwordCtx(40, fnId)` → `moveRaxToMemRsp(disp)`（`disp = 8*(argc-1)`，写回 `args[0]` 槽）→ `addRsp(disp)`；`argc=0` 时改为 `pushReg(0)`
- **描述**：按文档字面「先 push 结果、再 `add rsp,8*argc`」，结果格在 `args[0]` 之下，`add` 会把它与全部实参一起弹掉：内部调用返回值丢失、栈净深少 1（`RET` 取到的是实参）。argc=1 时最直观
- **建议**：模板 B 收参改为「`mov [rsp+8*(argc-1)],rax`；`add rsp,8*(argc-1)`；`argc=0` 时 `push rax`」，并注明「结果占用 `args[0]` 槽，与模板 A 同构」

### [一般][存量] #9 句柄槽回收契约四处表述互相矛盾；按 §9.6 字面实现会让槽位单调增长至上限

- **位置**：`doc:903-908`（§8.1 保活矩阵：B「`pin` 至调用结束」、D「`call<T>` 至解包完成自动回收」）、`doc:899`（规则 6①「A/B 的 ID 不在回收之列…`gen` +1 允许复用」）、`doc:936`（§8.2「`finally` 释放本次调用登记的**非常量槽**」）、`doc:1327`（§9.6 末句「**逃逸槽占用的表项不参与任何后续分配重用**」）
- **来源**：存量（快照）
- **判据**：review-checklist §2（同规则多副本导致漂移）、§11（资源不对称）、§5（无界增长的拒绝路径）
- **证据**：静态确定 —— 四处文本对「B 槽是否在调用结束释放」「D 槽释放后能否复用」给出三种答案；实现取「窗口记账 + 代数归还」：`src/runtime/HandleTable.cj:104-131`（`Win.pins` 注释：不占窗口、不随窗口重置释放，由 `CallMarshal.cleanup`/宿主释放）、`:194-200`（`gen` 上限 `0x7FFF`，触顶退休）、`:452-470`（`pin` 走窗口内去重）
- **描述**：① 按规则 6① 「A/B 不回收」，每次调用的参数槽永不复用 → 稳态槽数 = 调用次数 × 参数个数，必然触顶 `capacityLimit`（默认 2^20）→ 16，而 §9.6 又把 16 定性为「峰值容量错误、不是泄漏」，会掩盖真实泄漏；② 按 §9.6「逃逸槽不参与重用」，每次返回一个对象永久占一槽，同样单调增长；③ 按 §8.2 释放 B 槽，则必须写明「宿主已持有对象引用」这一前提由谁保证（当前由 `CallMarshal.cleanup` 承担，规格未写）
- **建议**：§8.1 立单一「槽归属与释放点」表（A=单元卸载；B=调用 cleanup；C=窗口重置；D=解包后自动回收且 `gen`+1 可复用），§8.2/§9.6 只引用；删掉 §9.6 与规则 6① 直接冲突的那句

### [一般][存量] #10 AArch64 帧与 ABI 有三处未入规范：`locals` 偏移 −40、`x20`、`FPCR`；`frameSize` 末项 `+8` 亦无语义定义

- **位置**：规范 `doc:2053`（「`locals[i]` = `[rbp-32-8i]`（a64 `[x29,#-32-8i]`）」）、`doc:116`（`frameSize = 32 + 8*nLocals + 8*maxStack + 8`）、`doc:141`（「帧布局本身两后端共享」）、`doc:1980-1996`（§12.2 ABI 表无 `x20`/`FPCR`）、`doc:2019-2032`（§12.3 a64 序言只保存 `x19`）、`doc:2056`（「a64 依赖 FPCR.DN=1（**引擎初始化**显式置位）」）
- **来源**：存量（快照）
- **判据**：review-checklist §13（规格与实现漂移）、§12.1（寄存器具名与保存义务）
- **证据**：静态确定 —— `src/backend/A64Lower.cj:140-146` `ldr/str [x29, #-40-8i]`（同一文件 `:29` 注释仍写 −32）；`src/backend/A64Compiler.cj:37-45` `FRAME = align16(40 + 8*(nLocals+maxStack+1))`（x86 为 32，`src/backend/BackendSelector.cj:1731-1737`）；`src/backend/A64Emitter.cj:265-285` 保存/恢复 `x20`（`[x29,-16]`）与 `FPCR`（`[x29,-24]`，置 DN=1）
- **描述**：① 规范把 `x29-32` 给 `locals[0]`，实现用 −40：a64 的 `x29-32` 保留给 `CALL_CLOSURE` 的 fnId 暂存（`A64Lower.cj:657-658`），照规范布局会被暂存覆盖闭包句柄 `locals[0]`；② `x20` 是 a64 的操作数栈指针（`A64Compiler.cj:76`）且 callee-saved，规范 §12.2/§12.3 完全没提，照规范实现会破坏调用方 `x20`；③ `FPCR` 是**线程**状态，规范写「引擎初始化置位」，实现是**每次调用**保存/恢复——按规范全局置 DN=1 会污染宿主浮点环境（宿主 NaN 从带 payload 变 canonical，属可观察变化），且违反 §11.3「payload 不参与可观察语义」只对 JIT 内部成立的隐含前提；④ `frameSize` 末项 `+8` 未说明。实现注释给出原因：helper 模板把 `TO_STR` 标签等静态操作数压栈，物理峰值 = `maxStack+1`，并记载「缺少这一格时该槽落在 `sp` 之下被 helper 帧覆盖（实测：插值串 `TO_STR` 标签读回垃圾 ⇒ 14）」
- **建议**：§12.4 通用约定改为「x86 `locals[0]@rbp-32`、a64 `@x29-40`（`x29-32` 保留 `CALL_CLOSURE` fnId 暂存）；`FRAME` 基址 32/40，末项 `+8` = 转瞬实参槽（`maxStack` 不含它）」；§12.2 增 `OPSTACK=x20`、`FPCR` 行并写「序言/尾声成对保存恢复，禁止全局置位」；修 `A64Lower.cj:29` 注释

### [轻微][存量] #11 helper hid 值域与 `MAX_FIXED` 过期：文档「1–62、69–72，73–255 保留」，实现已用到 84

- **位置**：规范 `doc:351`、`doc:1094`；实现 `src/runtime/HelperId.cj:92-121`（63 `host_call_trampoline`、64/65 字段读写、69–72、73–76 时间构造、77 `cast_fail`、78–83 Any/JSON、84 `ipow`）、`:124-125`（`MAX_FIXED = 72` 且注释称「`CALL_HELPER` 的 hid 合法值域」）
- **来源**：存量（快照）
- **判据**：review-checklist §13「文档过期」、§14.1「值域漂移」
- **证据**：静态确定 —— `MAX_FIXED` 全仓仅定义处命中、无引用；但注释把它定义为合法上界，一旦被校验代码采用，73–84 的已实现 helper 会被判非法
- **描述**：M2/M3 并入同模块后 hid 已扩到 84，m1 文档与 `MAX_FIXED` 停在 72；对读规范写加载器/汇编器的人是错误值域
- **建议**：§5/§8.4 改为「固定 helper 1–62、63–84（按 m2/m3 登记）、用户 helper `[0x0100,0xFFFF]`」；`MAX_FIXED` 删除或改为按 `HelperId.isFixed` 判定

### [轻微][存量] #12 规范声明的若干机制在实现中不存在（4 个伪指令、token 加载期校验、`HAS_LOOP`、H10/H21/H23、`RET_NULL`）

- **位置**：规范 `doc:663-668`（`GUARD_HANDLE`/`PUSH_KH_HINT`/`CHECK_ERR_OFF`/`BAIL_SITE`）、`doc:618`（「加载器遇未知 token 拒绝」）、`doc:52`（bit2=hasLoop）、`doc:554/565/567`（`H10 h_ref_eq`、`H21 err_raise`、`H23 hw_check`）、`doc:360`（`RET_NULL` 与 `RET_VOID` 同为 `rax=0`）
- **来源**：存量（快照）
- **判据**：review-checklist §1（无调用者 / 注册了但永不触发）、§14.1（承诺未实现）
- **证据**：静态确定 —— 四个伪指令全仓符号搜索 0 命中；`src/bytecode/FbcReader.cj` 对 `CAST/IS_TYPE/GUARD_TYPE/TO_STR/DT_FIELD` **零命中**（不校验 token 操作数），只做容器/目录/类型表/站点/名字与 `CALL_HOST` 门禁；`CtxFlags.HAS_LOOP` 只定义（`src/runtime/JitContext.cj:77-78`），写入点 `create` 只写 `DEADLINE`（`:178`），无后端读取；`grep "H_REF_EQ|ERR_RAISE|HW_CHECK" src --include=*.cj | grep -v HelperId.cj` **零命中**（`EQ_H` 走内联 `cmp`，`src/backend/X86Lower.cj:999-1000`）
- **描述**：① §7 把四个语法糖写成汇编器能力，本实现没有汇编源层（`BytecodeBuilder` 直接产字节码）；② token 不校验 ⇒ 含未知 token 的 `.fbc` 能通过加载、到执行期才以 7/8 失败，与「加载期拒绝」契约相反，失败 site 也漂到运行期；③ `hasLoop` 是死位却被列为 ctx 固定位语义；④ `H10/H21/H23` 无任何发射点（属 M2 预留但未标注），`RET_NULL` 与 `RET_VOID` 无任何可观察差异，只多一条 lowering 分支
- **建议**：§7 四项标「未实现（预留语法糖）」或删除；§6 token 校验在 `FbcReader` 落地（v1 0–9 / v2 0–11 / v3 0–12）或改文档为「运行期 helper 判 8」；§1 bit2 标「未使用」；H10/H21/H23 标「M2 预留」或删，`RET_NULL` 合并进 `RET_VOID`

### [轻微][存量] #13 §5 的 0xA0–0xAF 表混入 0xBE `MAP_ITER_STEP`，与 §10.3 和实现不一致

- **位置**：规范 `doc:420`（`BE MAP_ITER_STEP` 紧接 `AF` 之后，仍在「0xA0–0xAF 分配/变更区」标题下）；对照 `doc:1615`（§10.3 放在 0xB8–0xBF 段）与 `src/bytecode/OpInfo.cj:331`
- **来源**：存量（快照）
- **判据**：review-checklist §13「文档自相矛盾」、§10「可读性」
- **证据**：静态确定 —— 表头区段与行内 Hex 直接冲突；同时 0xB0–0xBF 表缺 `BE`
- **描述**：按章节读的人会认为 0xAF 之后还有一条 `u8 mode` 指令，误判区段边界（0xB0–0xBF 实际还含 `BE`/`BF`）
- **建议**：该行移入 0xB0–0xBF 表（`BF` 前），节标题补「Map 迭代步进 / 串建 Regex」

### [轻微][存量] #14 比较类 helper 的失败码列列入不可能产生的码（`CMP_DT`→11、`CMP_DUR`→12）

- **位置**：规范 `doc:338-339`、`doc:557`、`doc:559`；实现 `src/runtime/Helpers.cj:254-258`（`htCmp`）、`:280-284`（`hdurCmp`）
- **来源**：存量（快照）
- **判据**：review-checklist §13「规格与实现漂移」、§2「状态码表复制漂移」
- **证据**：静态确定 —— 两 helper 只做 `fetchDateTime`/`fetchDuration` + `compare`，无时间/时长算术，11/12 不可达；`DT_FIELD` 的 11 是可达的（`Helpers.cj:276` `case _ => failWith(ErrCode.DT_RANGE)`），故不在本条
- **描述**：错误码是宿主分派依据；写入不可达码会诱导宿主写永不执行的 `case 11/12`，并掩盖真正会出现的 8
- **建议**：改为 `6, 8`；若要保留「公共项略写」，在表头统一注明并删 11/12

### [轻微][存量] #15 §8.1 的 `pin` 契约（「同表内同对象复用同 ID」）与规则 4 及实现三方不符

- **位置**：规范 `doc:878` vs `doc:897`（规则 4「跨调用仅常量句柄保证同 ID」）；实现 `src/runtime/HandleTable.cj:452-495`（只在 `currentWinOf(rs)` 的 pin 列表内去重，非容器用 `canonKeyOf` **值键**比较；`HOST_CLOSURE`/`ANY` 才走 `refEq`）
- **来源**：存量（快照）
- **判据**：review-checklist §13（自相矛盾）、§11（契约与语言语义）
- **证据**：静态确定 —— `pinWith` 的去重上界是本调用窗口而非全表，且以值相等合并（两个等值 String 会合并；容器则每次新槽，因为仓颉无引用相等运算符）
- **描述**：一句话同时承诺「同表」（跨调用）与「同对象」（身份），实现两个都不满足。按文档推理会得出「同一对象跨调用 `pin` 得到稳定 ID」，而这正是规则 4 与 §8.3 禁止表明令禁止的用法；对可变容器若真按值合并，还会把 `f([], [])` 的两个实参变成同一对象（写入互相可见）
- **建议**：§8.1 改为「`pin` 在**本次调用窗口内**按类型去重（不可变值按键、容器每次新槽）；跨调用不保证同 ID（见规则 4）」

### [轻微][存量] #16 §8.4 预定义函数的类型面与 T23「全 LocalType 组合」冲突

- **位置**：规范 `doc:1068`（「0–8 与 10–11；9=Regex、12=Closure 非法」）、`doc:2280`（T23「参数/返回 marshal × 全 LocalType 组合」）、与 `doc:172`/`doc:1801`（Regex「LocalType 9 全位置合法」）
- **来源**：存量（快照）
- **判据**：review-checklist §13（文档内部矛盾 / 测试项不可落地）、§14
- **证据**：静态确定 —— `src/base/PredefinedFunction.cj:64-80` 构造期校验明确排除 9 与 12（注释「9 Regex 沿 M1 预定义面不加入」），且非法类型抛 `JitException(CALL_CONTRACT)` 而非文档 §8.4 暗示的编译期 `SourceCompileException`
- **描述**：同一文档「9 全位置合法」与「预定义函数 9 非法」并存，T23 又要求覆盖「全 LocalType」——测试项无法落地（漏 9/12 或与 §8.4 冲突）；注册期异常类型也没有统一
- **建议**：§8.4 明写「user helper 签名面 = 0–8、10–11（M1）/13、14（M2），不含 9 与 12；跨桥 Regex 只走 `call<T>` 与 `CALL_FUNC` 链」；T23 的「全 LocalType」改为「各通道合法类型集」，并写死注册期异常类型

### [轻微][存量] #17 同一规范规则被复制 3–5 处，已产生实际漂移

- **位置**：分配型 helper 集合 5 份（`doc:15`、`doc:58`、`doc:612`、`doc:870`、`doc:2186`）；变更型三规则 4 份（`doc:614`、`doc:1343`、`doc:2187`、`doc:2224`）；`hwCap` 默认 128 / 倍增 / 无分配=0 共 5 份（`doc:49`、`doc:58`、`doc:885`、`doc:1327`、`doc:2208`）；常量同 ID 与「单元存活期」4 份（`doc:897`、`doc:912`、`doc:1267`、`doc:1327`）
- **来源**：存量（快照）
- **判据**：review-checklist §2（跨节复制 / 字面量复制，且已出现差异）
- **证据**：静态确定 —— 本报告 #7（路由表漏 A5–A8、`LOOP_BACK` 只改一处）、#9（槽回收三种说法）、#10（帧公式两份）都是复制漂移的产物；集合本身也已有形态差异（§0/§1/§6/§8.1 用区间写法，§12.4 逐项列名并漏项）
- **描述**：每版演进要同改 5 处，而 `51866c43d` 已经证明会漏改。这不是可读性偏好，是缺陷来源
- **建议**：各收敛为「一张表 + 一处定义」，其余章节改「见 §X」；§12.4 路由表与 §6 表做装配期一致性自检（参照 §10.3 的 256 项自检）

### [轻微][存量] #18 非尾递归的栈溢出未纳入 §8.2.3 的异常面

- **位置**：`doc:213`（§4「非尾位置递归深度受宿主线程栈限制…不插深度检查」）、`doc:704`（§8.0 同）、`doc:971`（§8.2.3「`call` 绝不让非 `JitException`/非 `InterruptedException` 的底层异常逃逸」）
- **来源**：存量（快照）
- **判据**：review-checklist §4（无界递归）、§11（契约不符）
- **证据**：静态确定 —— 深度由源程序实参决定（`f(n-1)`，n 来自入参），规格无深度计数、无上限、互递归同样逐层压栈；栈耗尽时表现为 SIGSEGV 或宿主 `StackOverflowError`，二者都不在 §8.2.3 列举的两类异常内
- **描述**：规格有意不加防护（与仓颉原生一致），但没把该边界写进调用契约，宿主无法据此处理；`§9.16` 的单次转储在栈溢出路径上也可能二次失败
- **建议**：二选一——插显式深度计数并给可捕获码；或 §8.2.3 增一行「栈溢出属宿主级错误，不转码」，并在 §8.3 调用契约边界里点名

## 优化可行性方案

本部分唯一文件是规范文档，没有可测的堆内存 / CPU 改动面，`§7`、`§8`、`§9` 三维度记 0 条（见「覆盖自检」）。

唯一有量级数据的项（回边 `interrupt_poll` 占空循环 97.7%，`optimize-call-path.md` §14：662→15 ns/轮、44×）**已实现**（`CtxFlags.DEADLINE` + 两后端条件调用），因此不构成待做的优化方案，剩余工作只是文档回写——已并入 #7 的建议列。文档层面的"降成本"（opcode/helper 表单一来源、加载期校验前移）同样并入各条建议，不重复计入。

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | x86_64 侧回边 `H22` 的自耗时占比远低于 aarch64（97.7% 仅 aarch64 实测） | `doc:500`、`doc:2147` | x86 同场景 ns/轮与占比 | 同一空循环单元在有/无 deadline 两组下 `cjpm bench -O2`，10 轮取中位数与 P95 |
| 2 | `DUP2`（#1）在真实产物中的可达性：前端不发射，但仓外/历史 `.fbc` 可能含 0x18 | `src/backend/A64Lower.cj:208-212` | 现有 `.fbc` 语料里 0x18 的出现次数 | 扫 `**/*.fbc` 与 T1 黄金夹具，统计 opcode 直方图；aarch64 上跑含 `DUP2` 的最小单元做三引擎差分 |
| 3 | 句柄槽在长跑下是否真有「不复用 → 触顶 16」风险（文档 #9 的字面读法） | `doc:1327` vs `doc:899` | 10^6 次调用的槽计数曲线 | 长跑 `call<T>`（含容器返回）采样 `HandleTable` 槽数与 RSS，与「不复用」模拟基线对照 |
| 4 | 每帧末项 `+8` 与 16B 对齐在深递归下显著降低可用深度 | `doc:116` | 实际可用递归层数 | 非尾 `recursive` 压到栈溢出记层数，与去掉 `+8` 的对照分支比较 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_jit/doc/jit-bytecode-m1.md` | .md | ✅ | 2304 行全文（1–600 / 601–1100 / 1101–1600 / 1601–2304 四段读完，§0–§13 全章节）；与 19 个实现文件逐条比对，见 #1–#18 |

合计：`.cj` 0 个 / `.md` 1 个 / 共 1 个，全部读完。

> 附注：`doc:3` 的版本历史是单行 12096 字符的 blockquote，读取工具按行截断（`v0.18.36` 之后条目未能完整读到）。不影响结论——正文各章节均完整读取；该版式问题已作为维护性提示写在 #17 的建议列。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 18 | 正确性：#1/#4/#5/#6/#7/#8；设计/契约：#2/#3/#9/#10/#16/#18；语言特性：#15（仓颉无引用相等 ⇒ 文档 pin 契约不可实现）；可读性：#13/#17；安全性：文档不涉凭据/注入/越权，无命中 |
| §1 死代码 | 1 | 文档无代码符号，"死"按「声明的机制是否有实现/消费」判：4 个伪指令 0 命中、`CtxFlags.HAS_LOOP` 只定义不写不读、`H10/H21/H23` 全仓零调用、`RET_NULL` 与 `RET_VOID` 同效、`MAX_FIXED` 无引用且过期——合并为 #12 与 #11 |
| §2 重复逻辑 | 1 | 逐组比对 6 组副本：opcode 表（§10.3 ↔ `OpInfo.cj`，`CALL_HOST` 编码冲突 → #4）、helper 表（§6 ↔ `HelperId.cj`，值域过期 → #11）、失败码表（§5/§6 ↔ `Helpers.cj`，11/12 不可达 → #14）、规范正文 4 组多副本（→ #17）。`LocalType`/`TypeToken`/容器头/站点表/名字表逐项核对一致，未计 |
| §3 空实现 | 1 | §7 伪指令是纯文档声明（实现无汇编源层）；`HW_CLOSE`（0x7B）在 `src/backend/X86Lower.cj:1056` 为 `case 0x7Bu8 => ()` 而 0x7A 走 `bail(18)`，属静默空实现且加载期不拦——并入 #12 |
| §4 栈溢出 | 1 | 非尾递归无深度检查、互递归同（#18）；尾位置由帧复用回边覆盖（实现与 §8.0 一致） |
| §5 OOM | 1 | 句柄表 2^20 上限 +「逃逸槽不重用」的字面读法 ⇒ 单调增长至 16（#9）；无「按不可信长度预分配」（`nLocals/maxStack` 均编译期常量） |
| §6.1 热点瓶颈 | 0 | 唯一热点有数据（97.7%/44×）且已实现，不重复计为缺陷；x86 侧无数据 → 待验证假设 #1 |
| §6.2 大粒度锁 | 0 | 本部分无代码；文档唯一锁面是句柄槽追加/逃逸登记，实现已分片（`HandleTable` 64 分片 + 冷路径锁），无大锁证据 |
| §6.3 并发串行 | 0 | 无 `spawn + get` / 单消费者模型；并发调用各自独立 ctx 与窗口 |
| §6.4 低效算法 | 0 | 规范层无循环内 `contains`/`remove(at:0)`/重复解析；`PUSH_KH` 常量化与正则「加载期一次编译」已是预计算形态 |
| §7 降堆内存方案 | 0 | 无代码可改；对象生命周期已由 §8.1 矩阵限定，唯一可量化收益是槽归属收敛，已并入 #9 建议 |
| §8 降 CPU 方案 | 0 | 唯一有基线的项（回边安全点）已实现，见「优化可行性方案」说明 |
| §9 local mode 可行性 | 0 | 文档未涉及 local mode，本部分无函数级临时对象可评 |
| §11 现有代码的 BUG（存量） | 18 | 本部分 18 条全部为存量（快照模式无基线），证据均来自本轮逐条读取 + 实现比对；其中 #1/#4/#5/#6/#9/#10/#14/#15 是「契约与实现不符」，#2 是「承诺的公开入口不存在」，其余为文档过期/结构错/内部矛盾 |
| §12 并发安全与锁粒度 | 1 | 命中 #9（句柄槽跨线程归属、`gen` 复用规则）；另有一句说明：#8.7 未写「状态断言与 `activeCalls` 递增必须在同一临界区」，实现已在同一把锁内完成（`src/JitFunction.cj:198-206`），故不单列为缺陷 |
| §14 功能完备性与 README 覆盖 | 3 | #2（分发入口不存在于公开面）、#3（`unload`/`isUnloaded`/`init`/`unregisterFunction` 漂移）、#12（伪指令与加载期 token 校验未落地）。README/public 声明覆盖由第 1 部分审 |
| 文件覆盖（§13 等） | 1/1 | 无缺文件；`doc:3` 单行超限已注明 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 2 |
| 一般 | 8 |
| 轻微 | 8 |
| 优化方案（堆内存 / CPU） | 0 / 0 |

存量缺陷 18 条（本部分全部为存量），是否纳入修复待用户决定。

## 总评

这份规范的底子很好：错误码表、容器头、函数目录、站点表/名字表、ctx 布局、`LocalType`/`TypeToken`、`TO_STR` 格式、`FDIV_CHK` 谓词、`STACK_GUARD` 方向、`MAP_ITER_STEP` 相位等绝大多数数值与实现逐项对得上，实现侧文件普遍以它为「数值权威」，说明作者长期维护过一致性。

本部分的风险集中在三类，且都不是笔误级别：

1. **后端语义错误（#1，阻塞项）**：AArch64 `DUP2` 栈序颠倒，规范 §12.4 同错。当前前端不发射它，所以没炸；但分发入口装载的 `.fbc` 一旦含 `0x18`，aarch64 就与解释器不一致（I7 违反）。修 A64 lowering + 修规范 + 补三引擎差分，最小可验证闭环。
2. **分发入口不存在（#2，阻塞项）**：`Compiler.compile(unit: SourceUnit)` 不在公开面（`CompilePipeline` 为 `protected`，`SourceUnit` 无生产消费方）。这不是改名，是「分发模型对用户不可用」——补公开入口或撤回文档，不能停在「文档里有一个不存在的方法」。
3. **规范与实现的系统性漂移（#3–#17）**：门面签名（`close`/`isClosed`）、线上编码（`CALL_HOST` 2 B vs 4 B）、`LEN` 语义、转储首格协议、a64 帧/`x20`/`FPCR`、helper 值域、路由表漏项、`LOOP_BACK` 只改一处——共同特征是「文档落后实现一个版本」或「同一规则多副本只改了一份」。它们对当前 `compile(source)` 主路径多数不致命，但对「按规范实现的第三方后端/工具/新平台」是直接错误，而且 `51866c43d` 已证明这种结构必然再漏。

排期建议：**先修两条阻塞项**（#1 代码 + 规范；#2 公开入口）；**再批量同步契约面**（#3/#4/#5/#6/#9/#10，均可在同一次文档回写里完成，配 §10.3 式的装配期一致性自检）；**最后清结构性问题**（#12/#13/#17：把 opcode/helper/失败码/正文规则各收敛为单一权威表，删掉无实现的伪指令与死 helper）。优化项本部分为 0：唯一有基线的性能项已实现，剩余只是文档回写，已并入 #7。
