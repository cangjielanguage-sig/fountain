# f_jit 模块审查报告（模块第 38/38 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_jit/src/test/`、`f_jit/src/test/diff/`、`f_jit/src/userapi/UserApi_test.cj`（本部分 7 个源文件，全部 `.cj`）
- **基线**：工作区快照（master 与 sts/1.3.x 同一提交 `120fd2542`，`git diff` 为空）⇒ 所有问题来源记「存量」
- **审查重点**：动态调用/桥接正确性（typecode 分支表）、句柄与资源生命周期、并发安全、递归与栈溢出、死代码、重复逻辑
- **报告版本**：v1（分部分报告，只统计本部分；由主 Agent 合并进 `docs/review/2026-11-28/f_jit_v2.md`）

> 本部分审查单元：差分测试层（`DiffHarness.cj`、`RealRunners.cj`）、T 编号映射表（`TCoverage.cj`）、差分层自证用例（`diff_test.cj`）、T 标签工具（`TCase.cj`）、包根占位（`Test.cj`）、用户面冒烟（`UserApi_test.cj`）。
> 本部分不含生产 JIT 路径，但 `RealRunners.cj` 是**唯一的生产级 FFI 调用副本**（`CFunc` 直接跳机器码），因此「桥接正确性 / 原生资源生命周期」在此处按生产口径审。

## 发现

### [一般][存量] 三个 `run` 实现逐字节重复（72 行 × 3），且已与生产 `JitExecutor.invokeOff` 漂移

- **位置**：`f_jit/src/test/diff/RealRunners.cj:76-147`（`AArch64Runner.run`）、`:161-232`（`NativeRunner.run`，`@When[arch == 'aarch64' && os == 'Linux']`）、`:245-316`（`NativeRunner.run`，`@When[arch == 'x86_64' && os == 'Linux']`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2「换控制流 / 只改类型名」+ §12.1「跨线程资源与状态恢复」
- **证据**：静态确定 —— `diff <(sed -n '76,147p') <(sed -n '161,232p')` 与 `diff <(sed -n '161,232p') <(sed -n '245,316p')` 均为空，即三段 72 行完全一致，唯一差异是 `engine()` 的返回值；而生产同一动作 `JitExecutor.invokeOff`（`f_jit/src/backend/JitExecutor.cj:144-182`）比这三份多三件事：`try/finally` 包住调用并释放实参缓冲（`:172-181`）、进入前保存 `MachineEnv.fnTableBase` 退出后恢复（`:147-151`、`:178-180`）、`release()` 里回收常量句柄（`:185-207`）。
- **描述**：同一段 `FbcReader.load → ConstMirror.build → FnTable.alloc → compileUnitWith → CodeBuffer.alloc/write/seal → 逐目录写入口表 → CFunc 调用 → 收尾` 逻辑存在四份（三份测试副本 + 一份生产实现），且测试副本已经落后于生产副本。当前 `DiffSession` 只用 `NativeRunner`（`f_jit/src/compiler/DiffExec_test.cj:67`、`:134`、`f_jit/src/compiler/Acceptance_test.cj:423`、`f_jit/src/Q6DiffCoverage_test.cj:68`），`AArch64Runner` 是同一实现的第二份公开副本；在 Linux aarch64 上两者 `isAvailable()` 同时为真（`:72-74`、`:157-159`），若有人把两者都放进 `DiffSession`，同一台引擎会被跑两遍并计成「2 个证据」，四元组对拍退化为自比。
- **建议**：保留一个 `private static func runNative(c: DiffCase, engine: DiffEngine): DiffOutcome`，三个 `@When` 类只提供 `engine()`/`isAvailable()`；并把 `try/finally`、`MachineEnv` 保存-恢复、常量句柄回收按 `JitExecutor.invokeOff` 的口径补齐（或直接复用 `JitExecutor`，它已具备 `pinnedConstIds()` / `release()`）。

### [一般][存量] 常量句柄只 `pinConst` 不 `releaseConst`，每跑一个用例累积一份引用

- **位置**：`f_jit/src/test/diff/RealRunners.cj:82`（`ids[i] = interp.constHandle(i)`，`AArch64Runner`）、`:167`（同一循环，aarch64 `NativeRunner`）、`:251`（同一循环，x86_64 `NativeRunner`）、`:57`（`InterpRunner.run` 里 `interp.run(...)` 隐式登记）
- **来源**：存量
- **判据**：review-checklist §11「资源不对称」+ §7「注册表不注销」
- **证据**：静态确定 —— `Interp.pinnedConstIds()` 的注释写明「已登记的路径 A 句柄（值型常量为 0；**调用方负责 releaseConst**）」（`f_jit/src/runtime/Interp.cj:91-94`），`constHandle` 内部走 `HandleTable.pinConst`（`Interp.cj:161-169`），`pinConst` 对命中的槽做 `constRefs + 1`（`HandleTable.cj:622`）且只有 `releaseConst` 才归零回收（`HandleTable.cj:633-655`）。本文件 7 个函数体内全仓搜不到任何 `releaseConst` 调用；生产侧的正确写法在 `JitExecutor.release()`（`:185-207` → `releaseConsts` → `HandleTable.releaseConst`）与 `CompilePipeline.cj:154-158`、`:258`。
- **描述**：每个 `DiffCase` 新建 `Interp` 并对该单元**全部**常量登记句柄，跑完只 `JitContext.free` / `DbgDump.freeDump` / `table/mirror/buf.free`，常量句柄永久留在路径 A。等值常量会被 `pinConst` 的规范化键去重（`HandleTable.cj:613-627`），所以不是线性增长；但**每个用例的相异常量各占一个槽且永不回收**，同一进程内跑完整套差分后槽位只增不减（表上限 `capacityLimitAtomic = 1048576`，`HandleTable.cj:169`），且每个 `pinConst` 都要在全局 `mtx` 内线性扫全表（见「待验证假设」#1）。
- **建议**：`run()` 结束（含失败路径）统一 `for (id in interp.pinnedConstIds()) { if (id != 0) { HandleTable.releaseConst(id) } }`，或改成 `Interp(unit, constIds)`（`Interp.cj:96-99`）复用一份跨用例缓存并在套件收尾统一释放；返回值若是引用型句柄，也按生产口径回收。

### [一般][存量] `FnTable.alloc` 失败分支漏 `mirror.free()`（三处同源）

- **位置**：`f_jit/src/test/diff/RealRunners.cj:85-89`、`:170-174`、`:254-258`
- **来源**：存量
- **判据**：review-checklist §11「资源不对称（异常跳过释放）」
- **证据**：静态确定 —— `ConstMirror.build` 成功即 `LibC.malloc` 一块非托管内存并 `NativeAssets.onAlloc()`（`f_jit/src/backend/NativeAssets.cj:154-170`），必须在 `free()` 归还（`:201-210`）。三个 `run` 的顺序都是「先 `build` 后 `alloc`」，而 `FnTable.alloc` 返回 `None` 的分支直接 `return DiffOutcome('JIT_ALLOC_FAILED', ...)`，既不 `mirror.free()` 也不 `NativeMem`/`NativeAssets` 记账回收；同文件后面两个失败分支（`compileUnitWith` → `:90-96`、`CodeBuffer.alloc` → `:97-103`）都成对写了 `table.free()` + `mirror.free()`，可见是遗漏而非设计。
- **描述**：一旦入口表分配失败（`unit.dir.size == 0` 或 malloc 失败），每次调用泄漏一块 `8 × consts.size` 非托管内存，`NativeAssets.liveCount()` 也永久偏移 —— 这类泄漏恰好会污染「原生资产零泄漏」类断言（`NativeAssets_test`）。`unit.dir.size == 0` 是可由**畸形 `.fbc`** 触发的路径（`FnTable.alloc` 在 `n <= 0` 时返回 `None`），不是纯理论分支。
- **建议**：`match (FnTable.alloc(...))` 的 `None` 分支补 `mirror.free()`；更彻底的做法是用 `try/finally` 或统一「资源束」结构，让所有失败出口走同一条清理路径（`JitExecutor.release()` 已把顺序固定为「码内存最后释放」）。

### [一般][存量] `CodeBuffer.write/seal` 与 `FnTable.set` 的 `false` 被静默丢弃，失败后仍跳进不可执行内存

- **位置**：`f_jit/src/test/diff/RealRunners.cj:104-106`、`:189-191`、`:273-275`（`let unused0 = buf.write(...)` / `let unused1 = buf.seal()`）；`:111`、`:196`、`:280`（`table.set(...)` 返回值当语句丢弃）
- **来源**：存量
- **判据**：review-checklist §3「`catch`/返回值被静默丢弃」+ §11「错误处理缺失」
- **证据**：静态确定 —— `CodeBuffer.write` 在 `freed || sealed || off < 0 || 越界` 时返回 `false`（`f_jit/src/backend/CodeBuffer.cj:99-109`），`seal()` 在 `mprotect` 失败时返回 `false`（`:131-147`），`FnTable.set` 在 `freed || fid >= n` 时返回 `false`（`f_jit/src/backend/NativeAssets.cj:107-114`）。三处调用点把返回值命名成 `unused0`/`unused1`（正是「读了不用」的形态），`table.set` 连绑定都不做，随后无条件 `flushICache()` 并用 `CFunc(CPointer<Unit>(buf.rawPointer() + entryOff))` 调用（`:127-134`）。
- **描述**：`seal()` 失败 ⇒ 页仍为 `PROT_READ|PROT_WRITE`（未 `PROT_EXEC`），`f()` 直接触发段错误；`write()` 失败 ⇒ 码内存是未初始化内容，跑出任意结果并进入四元组对拍（比崩溃更难查）。三条都是「失败即静默」而非「失败即报告」，与同文件对 `FnTable.alloc` / `compileUnitWith` / `CodeBuffer.alloc` 都做了 `match` 检查的口径不一致。
- **建议**：`match (buf.write(...))` / `match (buf.seal())` → `false` 时按 `DiffOutcome('JIT_SEAL_FAILED', ...)`（或抛 `DiffMismatchException`）返回并释放 `buf/table/mirror`；`table.set` 的 `false` 同样要报（它意味着该 `fnId` 的跨函数调用会跳到地址 0）。

### [一般][存量] `cells()` 对未支持的实参类型静默填 0，可造成两引擎「同时看到 0」的假绿

- **位置**：`f_jit/src/test/diff/RealRunners.cj:357-376`（兜底分支 `:371` `case _ => out[i] = 0`）
- **来源**：存量
- **判据**：review-checklist §3「`case None => ()` 当兜底把错误吃掉」+ §11「错误处理缺失」
- **证据**：静态确定 —— 只有 `Int64` / `Float64` / `Bool` 三个分支（`:361-372`），其余一律写 0；`DiffCase.args` 的类型是 `Array<Any>` 且注释写「入参（宿主侧封送前的原始形态）」（`DiffHarness.cj:60-61`），并没有约束「必须是已 pin 的 Int64」。仓内确实存在「先手工 pin 再传 Int64」的用法（`f_jit/src/Q6DiffCoverage_test.cj:139-147`），说明调用方需要自己知道这条隐式约定。
- **描述**：若某个用例直接传 `String` / `Decimal` / `DateTime` / 宿主对象实例，两侧引擎都收到 cell `0`，四元组完全一致 ⇒ 对拍「通过」，但实际什么都没验。这是差分 harness 最怕的失效形态（假绿），且不会留下任何日志。
- **建议**：兜底分支改成抛 `DiffMismatchException('${c.id}: 不支持的实参类型 ...')`（或 `DiffOutcome` 的错误码），把隐式约定变成显式失败；若确实要支持「裸 String」，在此处按 `HandleTable.pin` 登记并纳入回收范围。

### [一般][存量] 可用引擎不足 2 个时直接抛异常，与「非原生架构 ⇒ 跳过而不判失败」的契约冲突

- **位置**：`f_jit/src/test/diff/DiffHarness.cj:124-127`（`outcomes.size < 2` 抛 `DiffMismatchException`）、`:187-189`（`DiffSession.assertTripleEqual`）；`:33-34`、`:145-149` 的文档承诺「记入非原生跳过统计而**不判失败**」
- **来源**：存量
- **判据**：review-checklist §11「契约与实现不符」+ §14「承诺了但没实现」
- **证据**：静态确定 —— `runAll` 只把 `isAvailable()` 为真的 runner 放进 `outcomes`（`:173-185`），`assertTripleEqual` 在只剩 1 个时抛异常；而非 Linux 的 `NativeRunner`（`RealRunners.cj:319-332`）与「Linux 但非 aarch64/x86_64」的 `NativeRunner`（`:335-348`）都硬编码 `isAvailable() == false`。调用方 `f_jit/src/compiler/DiffExec_test.cj:67-69`、`f_jit/src/compiler/Acceptance_test.cj:423-425`、`f_jit/src/Q6DiffCoverage_test.cj:68`、`:144` 都是 `DiffSession([InterpRunner(), NativeRunner()])` + 直接 `assertTripleEqual`，其后紧跟的 `@Assert(session.ran() >= 1, true)` 在这些平台上根本执行不到。
- **描述**：在 Windows / macOS / RISC-V 等平台跑 `cjpm test`，这批差分用例会以「可用引擎不足 2 个」失败，而不是像注释与 `TCase` 设计意图那样记为「无证据、跳过」。`DiffExec_test.cj:31` 甚至明写「非 Linux-aarch64 环境下 AArch64Runner 记入「跳过」而非失败（证据由 CI 矩阵补齐）」——实现与该句相反。现有 `diff_test.unavailableEngineIsSkippedNotFailed`（`:86-97`）用三个桩（含一个 `available: false`）验证了「跳过」，恰好绕开了「只剩 1 个」的真实平台情形。
- **建议**：给 `DiffSession` 加一个显式入口 `assertDiffOrSkip(c)`（返回 `DiffVerdict`：`Compared` / `InsufficientEvidence`），调用方断言 `ran() + skipped() == 2` 且在 `skipped > 0` 时记「无证据」而非失败；至少让调用方在 `ran() == 1` 时改断言 `skipped() == 1`，并给 `diff_test` 补一条 `DiffSession([InterpRunner(), unavailable])` 的用例钉住该语义。

### [轻微][存量] `maxNLocals` / `typesOf` / `reportOf` 是 `CompilePipeline` 同名私有函数的逐行副本

- **位置**：`f_jit/src/test/diff/RealRunners.cj:412-423`（`maxNLocals`）、`:426-435`（`typesOf`）、`:443-451`（`reportOf`）
- **来源**：存量
- **判据**：review-checklist §2「跨层复制」
- **证据**：静态确定 —— `CompilePipeline.cj:332-341` 与 `RealRunners.cj:412-423` 逐行相同；`CompilePipeline.cj:354-364` 与 `RealRunners.cj:426-435` 逐行相同（含同样的 `unit.types[0]` 回落）；`CompilePipeline.cj:346-352` 与 `RealRunners.cj:443-451` 只差一行前置守卫（本文件多了 `if (ctx.errCode <= 0) return ''`）。
- **描述**：三个「目录/类型表/报告」辅助函数在测试层被整体复制一遍，两边的回落语义（`types[0]`）与越界假设完全绑定；任一侧修边界（见下一条），另一侧会静默分叉。这不是业务必需的独立演进，属于跨层复制。
- **建议**：把三者提升为 `f_jit` 内部（`internal`）公共工具，例如 `runtime/DumpSupport.cj`（或直接让 `CompilePipeline` 暴露 `internal static`），测试层只调用。落点须在同层或下层，不能反向依赖 `CompilePipeline`（它依赖 `SourceCompiler`，层次更高）。

### [轻微][存量] F64 ↔ Int64 位型重解释在本文件重复两份，仓内共 5 份

- **位置**：`f_jit/src/test/diff/RealRunners.cj:363-369`（`Float64` → cell）、`:400-406`（cell → `Float64`）
- **来源**：存量
- **判据**：review-checklist §2「换算复制」
- **证据**：静态确定 —— 同形实现在 `f_jit/src/CallMarshal.cj:398-416`（`bitsOf` / `bitsOfCell2` / `bitsOfCell`，`private`）、`f_jit/src/runtime/Interp.cj:153-157`、`:444`、`f_jit/src/bytecode/ByteCodec.cj:58-72`、`f_jit/src/bytecode/CanonKey.cj:66` 各自存在；其中 `CanonKey.cj:58` 的注释已指明「`Int64(bits)` 是检查型转换，负浮点/NaN 会抛出」，正是这五份代码都在手写同一套绕行写法。
- **描述**：同一「无溢出位型转换」在本仓有 5 份实现，任何一份写错（少一个 `+ Int64.Min`）都会让 F64 用例在特定符号位上崩；测试层的两份必须与运行时严格一致，却没有任何共享断言。
- **建议**：抽到 `f_jit.base` 的 `internal` 工具（如 `Bits.f64ToCell` / `Bits.cellToF64`），`RealRunners` / `Interp` / `CallMarshal` 全部改调；`ByteCodec`/`CanonKey` 的变体（带 `9223372036854775807` 形式）保留但加一句「语义等价于 Bits.*」的交叉引用。

### [轻微][存量] `text()` 只解码 `STRING` / `F64`，引用型返回会按「句柄 ID」参与对拍

- **位置**：`f_jit/src/test/diff/RealRunners.cj:392-409`（`:394-399` 只处理 `LocalType.STRING`，`:400-407` 只处理 `F64`，其余落 `:408` `TextFormat.i64(cell)`）
- **来源**：存量
- **判据**：review-checklist §11「契约与实现不符」
- **证据**：静态确定 —— `DiffOutcome.result` 的注释是「结果的文本化形态（与 `TO_STR` 同源，见 S4.12）」（`DiffHarness.cj:37-38`），实现只对两类做了文本化；`List`/`Map`/`JsonObject`/13/14 型返回会走到 `TextFormat.i64`，输出的是**句柄 ID**。句柄 ID 在同一进程内由 `pin` 分配（`HandleTable.cj:452-470` 的窗口去重只保证「同一窗口内同对象同 ID」），两个引擎先后运行、各自 pin，ID 不保证相同。
- **描述**：当前差分用例的返回类型只有 Int64 / F64 / String（`DiffExec_test.cj:37-99` 全部如此），所以尚未暴露；一旦给 `List`/`Map`/宿主对象 加入差分用例，两侧会因 ID 不同而报假不一致（或因为 ID 恰好被槽复用而复用而碰巧通过），形成随机红/假绿。
- **建议**：`text()` 增加「引用型走 `TO_STR` helper（`runtime/Helpers.cj` 的 `to_str`）」的分支，或把 `result` 字段改成 `Option<String>` 并在引用型返回时置 `None` + 记「该维度不可对拍」，由 `diffFour` 显式跳过该维度。

### [轻微][存量] 合成失败码用 `-1`（= DEOPT）表示分配/编译失败，语义与 `DiffOutcome` 契约冲突

- **位置**：`f_jit/src/test/diff/RealRunners.cj:88`、`:95`、`:102`（`AArch64Runner`）与 `:173`、`:180`、`:187`（aarch64 `NativeRunner`）与 `:257`、`:264`、`:271`（x86_64 `NativeRunner`）
- **来源**：存量
- **判据**：review-checklist §11「语义与命名/注释不符」
- **证据**：静态确定 —— `DiffOutcome.errCode` 的注释定义「`0` 成功、`-1` DEOPT、`-2` INTERRUPT、`>0` 见 `ErrCode`」（`DiffHarness.cj:39-40`），而 `JIT_ALLOC_FAILED` / `JIT_COMPILE_FAILED` 都返回 `-1`；`reportOf` 又按 `errCode <= 0` 归零报告（`:444-446`），于是「引擎没跑起来」在四元组里表现为「DEOPT 且无报告」，只能靠 `result` 字符串区分。
- **描述**：若未来某用例的解释器侧正常返回 `-1`（DEOPT 是合法语义结果），它与「JIT 根本没编译成功」在错误码维度上相同，对拍能否区分完全依赖 `result` 文案；同时 CI 汇总会把「环境分配失败」统计成 DEOPT。
- **建议**：改用 `ErrCode` 之外的正值保留码（如 `9001`/`9002`）或把这两类改成抛 `DiffMismatchException`，让「引擎不可用」与「引擎给出语义结果」在四元组里天然不同。

### [轻微][存量] `art.entry` 缺失时回落偏移 `0`，语义是「执行别的函数」而不是报错

- **位置**：`f_jit/src/test/diff/RealRunners.cj:117-120`、`:202-205`、`:286-289`（`case None => 0`）；同源 `:112`、`:197`、`:281`（`case None => ()` 跳过写入口表）
- **来源**：存量
- **判据**：review-checklist §1「恒假分支」+ §11「错误处理缺失」
- **证据**：静态确定 —— `JitCompiler.compileUnitWith` 对 `unit.dir` 的每个函数都编译，任一失败整批返回 `None`（`f_jit/src/backend/JitCompiler.cj:84-113`），因此走到本文件时 `art.entry(任一 fnId)` 必为 `Some`；这两个 `None` 分支在构造上不可达。真正的问题是它们的兜底值：`0` 是码缓冲首函数的入口。
- **描述**：分支虽不可达，但一旦未来 `compileUnitWith` 引入「按需编译/裁剪」，`entryOff = 0` 会把入口函数悄悄换成目录首函数，四元组仍能产出结果并参与对拍 —— 排查成本极高。
- **建议**：`case None =>` 改为返回 `DiffOutcome('JIT_ENTRY_MISSING', ...)`（或抛异常），并删掉「跳过一个入口」的 `case None => ()`（改成失败），让不可达分支以「显式失败」而不是「静默降级」收尾。

### [轻微][存量] `RealRunners.nativeRunner()` 全仓零引用（`internal` 类成员 ⇒ 死代码）

- **位置**：`f_jit/src/test/diff/RealRunners.cj:350-354`
- **来源**：存量
- **判据**：review-checklist §1（所属顶层声明 `internal class RealRunners`，成员缺省修饰符即「本包及子包可见」，对外不可达）
- **证据**：静态确定 —— 全仓（排除 `.worktrees`、`target`）`grep -rn "nativeRunner"` 只命中定义处 `:352`；文档注释说它是「当前平台的原生 JIT runner（同名顶级声明按 `@When` 条件编译）」，但所有调用方都直接 `NativeRunner()`（`DiffExec_test.cj:67`、`Acceptance_test.cj:423`、`Q6DiffCoverage_test.cj:68`）。同类的其余成员（`cells` `:357`、`arrayPointer` `:378`、`text` `:392`、`maxNLocals` `:412`、`typesOf` `:426`、`reportOf` `:443`）均有调用者。
- **描述**：这层间接（`internal` 类 + 无条件编译的工厂函数）本来是要「屏蔽 `@When` 差异」，但调用方都写死了 `NativeRunner`，工厂成了空壳；它还会误导读者以为存在统一入口。
- **建议**：删除 `nativeRunner()`；若要保留统一入口，则把全部调用方改为 `RealRunners.nativeRunner()`（此时 `RealRunners` 应改为调用方可见的可见性）。

### [轻微][存量] `TMapping` 类注释与三张表的当前语义矛盾（`inScope` / `owner` 说法过期）

- **位置**：`f_jit/src/test/diff/TCoverage.cj:20-29`（类注释，尤其 `:27-28`）
- **来源**：存量
- **判据**：review-checklist §13「文档过期」/ §11「语义与注释不符」
- **证据**：静态确定 —— 注释写「范围外编号（T30–T41、T49）归属 M2/M3：`owner` 标注为 `M2/M3`、`inScope=false`，**不计入本次完成判据**」；实际三张表里 `T_MAP_M2`（`:102-132`）14 条全部 `inScope=true`、`owner='M2'`，`T_MAP_M3`（`:140-156`）7 条全部 `inScope=true`、`owner='M3'`，且 `diff_test.m2ScopeIsFullyCovered`（`:172-188`）/`m3ScopeIsFullyCovered`（`:150-164`）正是断言「必须 `inScope`」。全表不存在任何 `owner='M2/M3'` 或 `inScope=false` 的条目。
- **描述**：这条注释会让人误以为 M2/M3 仍是「登记但不算完成」，与紧随其后的两张表和两条 `@Fail` 断言直接冲突；后续维护者按注释改表会把 M2/M3 判据打掉。
- **建议**：改写为「M1 = `T_MAP_IN_SCOPE`；M2/M3 各自成表且都是对应里程碑的完成判据；`inScope` 恒为 true，保留该字段只为与 `check_tmap.sh` 的读取口径一致」。

### [轻微][存量] `tMappingHasNoDanglingEntries` 名不符实：只校验非空与 M1，M2 缺 `caseName` 断言

- **位置**：`f_jit/src/test/diff/diff_test.cj:107-125`（只遍历 `T_MAP_IN_SCOPE`）、`:172-188`（`m2ScopeIsFullyCovered` 未断言 `caseName` 非空）
- **来源**：存量
- **判据**：review-checklist §14「用例承诺与实现不符」/ §11「语义与命名不符」
- **证据**：静态确定 —— 用例注释写「每项都能定位到具体步骤 + 用例名，**无悬空项**」（`:107`），但循环只对 `m.steps.isEmpty()` / `m.caseName.isEmpty()` / `owner`/`inScope` 判空，**不检查 `caseName` 对应的测试函数是否存在**；`caseName` 写错成任意非空串也照样通过（真正的存在性校验在 `scripts/check_tmap.sh`）。`m2ScopeIsFullyCovered` 只断言 `steps.size > 0`（`:184`），`m3ScopeIsFullyCovered` 则同时断言了 `caseName` 非空（`:160`），三处口径不一致。
- **描述**：本用例被当作「映射表自证」，实际只自证了「非空」。已人工核对本部分覆盖的 61 条映射：`T1..T29、T42..T48、T50..T53`（M1 40 条）、`T30..T36、T49、T54、T55、T57..T60`（M2 14 条）、`T37..T41、T56、T61`（M3 7 条）的 `caseName` 全部能在 `src/**/*_test.cj` 中 `grep "func <name>("` 命中，且 61 个 `'T<id>/` 标签都在可执行语句里出现 ⇒ **当前数据是干净的**，问题在于用例守不住将来。
- **建议**：要么把用例改名/改注释为「映射项字段非空校验」，要么在测试内做真实存在性校验（仓颉侧可用 `std.reflect` 枚举 `*_test` 类的成员名），或明确写「存在性由 `check_tmap.sh` 负责」；同时给 M2 补 `caseName` 非空断言，与 M3 对齐。

## 优化可行性方案

### [CPU] 每用例重建常量句柄与编译产物

- **现状**：`runAll` 对每个 `DiffCase` 重新 `FbcReader.load`（`RealRunners.cj:51`、`:77`、`:162`、`:246`）→ 对 `unit.consts.size` 逐个 `constHandle`（`:79-84` 等）→ `ConstMirror.build` → `compileUnitWith` → `CodeBuffer.alloc`。同一份 raw 字节在 `T2/*`、`T33/*`、`Q6/*` 等用例里被重复处理；`pinConst` 每次都要在全局 `mtx` 内线性扫表（`HandleTable.cj:611-629`），表越用越大。
- **方案**：在差分层加一个按 `DiffCase.unit`（同一份 raw 字节）索引的有界缓存，缓存 `(ConstMirror, FnTable, CodeBuffer, entryOff)`，每次用例结束只回收句柄引用；或至少复用 `Interp(unit, constIds)`（`Interp.cj:96-99`）把常量句柄提到套件级。
- **预期**：减少每用例一次的 `malloc/mprotect/__clear_cache` 与 `O(n_slots × n_consts)` 的扫表；套件级耗时降幅未测（不改变单用例语义）。
- **代价**：缓存需有容量上限与失效策略（字节码 → 机器码的映射不可跨进程复用）；共享 `ConstMirror` 后「常量句柄生命周期」从「每用例」变「每套件」，回收点集中，写错会变成更隐蔽的泄漏。
- **验证**：`cjpm bench -O2` 跑同一组 ~50 个用例，比较总耗时中位数（≥5 轮）；`cjprof record` 看 `HandleTable.pinConst` 与 `CodeBuffer` 相关符号自耗时占比；`NativeAssets.liveCount()` 在套件结束时必须回到基线。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 差分跳过判定前置，避免「先编译再发现引擎不足」

- **现状**：`DiffSession.assertTripleEqual` 先 `runAll`（每个可用 runner 都会完整编译并执行单元），再在 `outcomes.size < 2` 时抛异常（`DiffHarness.cj:124-127`、`:187-189`）。单引擎平台（非 Linux / 非 x86_64 / 非 aarch64）上，唯一可用的 `InterpRunner` 仍会完整跑一遍，然后整例判失败。
- **方案**：`DiffSession` 增加 `availableCount()`（只调 `isAvailable()`，零编译），在 `assertTripleEqual` 入口先判「可用引擎数」，不足时走「无证据」返回；同时把 `ran/skipped` 计数的语义从「引擎执行次数」改成「本次证据判定」。
- **预期**：单引擎平台上跳过 N 个差分用例的全部编译与执行成本（N 为用例数）；对多引擎平台零影响。
- **代价**：`DiffSession` 的 API 需要加返回值类型（`DiffVerdict`），调用方要改断言；`ran()/skipped()` 的既有断言（`diff_test.cj:42-43`、`:94-96`）需同步调整。
- **验证**：在 Windows（`os != 'Linux'` 分支）跑 `cjpm test`，记录差分用例耗时与失败数（应从「失败」变「跳过」）；Linux aarch64 上重跑确认 `ran()==2` 且四元组对拍结果不变。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `pinConst` 的全表线性扫描 + 全局锁成为差分套件的隐性瓶颈（每用例每常量 O(表槽数)） | `f_jit/src/test/diff/RealRunners.cj:79-84`（调用方）/ `f_jit/src/runtime/HandleTable.cj:611-629`（实现） | `pinConst` 自耗时占比、调用次数、表槽数随用例数增长曲线 | `cjprof record` 跑 `cjpm test` 全量差分；另加埋点记录每次 `pinConst` 前的 `totalSlots` 与耗时，跑 100/500/1000 个用例对比 |
| 2 | 每个 `DiffCase` 的 `FbcReader.load + compileUnitWith + CodeBuffer.alloc` 占套件总耗时的主要部分 | `RealRunners.cj:51-106`、`:162-191`、`:246-275` | 编译阶段耗时占比（对比解释执行阶段） | 分段计时：在 `run()` 内打 `load` / `compile` / `invoke` / `report` 四个时间戳，跑 200 个用例取中位数 |
| 3 | 每用例的 `LibC.malloc/free`（args + dump + mirror + table + ctx）在长套件里表现为分配抖动而非泄漏 | `RealRunners.cj:123`、`:126`、`:138`、`:208`、`:211`、`:223` | `NativeAssets.liveCount()` 与 `NativeMem` 计数在套件结束时的稳态 | 套件前后打印 `NativeAssets.liveCount()`；若不为 0 则按「发现」#2/#3 的路径定位 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_jit/src/test/TCase.cj` | .cj | ✅ | `hit(id, ok)` 单函数；空 `id` 返回 `false`，与 `check_tmap.sh` 口径一致，无问题 |
| 2 | `f_jit/src/test/Test.cj` | .cj | ✅ | 只有版权头与包根注释（为让 `test/diff` 子包被 cjpm 收集），符合注释说明，无声明 |
| 3 | `f_jit/src/test/diff/DiffHarness.cj` | .cj | ✅ | 四元组与 `DiffSession`；发现 #6（<2 引擎抛异常）、`result`/`errCode` 契约（#9、#10 的判据来源） |
| 4 | `f_jit/src/test/diff/RealRunners.cj` | .cj | ✅ | 本部分风险集中地：发现 #1–#5、#7–#12（重复三份 `run`、句柄不回收、错误路径漏释放、返回值丢弃、`cells` 静默 0、跨层复制辅助函数、位型转换重复、`text` 只解码两类、错误码 -1、`entry` 回落 0、`nativeRunner` 死代码） |
| 5 | `f_jit/src/test/diff/TCoverage.cj` | .cj | ✅ | 61 条映射（M1 40 / M2 14 / M3 7）；类注释过期（发现 #13），数据本身已人工核对无悬空 |
| 6 | `f_jit/src/test/diff/diff_test.cj` | .cj | ✅ | 11 个用例；`tMappingHasNoDanglingEntries` 名不符实（发现 #14），其余断言与实现一致 |
| 7 | `f_jit/src/userapi/UserApi_test.cj` | .cj | ✅ | 用户面冒烟两例（编译→调用→卸载、19 契约错误），与 `Compiler`/`JitFunction` 公开 API 一致，无问题 |

合计：`.cj` 7 个 / `.md` 0 个 / 共 7 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 6 | 正确性 4 条（`cells` 静默 0、`text` 引用型按句柄 ID、`<2` 引擎抛异常、错误码 -1 复用）；设计 1 条（三份 `run` + 跨层复制辅助函数）；可读性 1 条（`TMapping` 类注释过期）。安全性未命中：本部分不解析外部输入、不拼 SQL/命令、无凭据；`unsafe` 只用于已分配的本地缓冲 |
| §1 死代码 | 1 | 逐符号机械搜索：`RealRunners`（`internal` 类）7 个成员有 6 个存在调用者，`nativeRunner` 全仓（排除 `.worktrees`/`target`）零引用 ⇒ 死代码；`DiffSession` 的 4 个 private 字段、`StubRunner` 的 3 个 private 字段均在类内被读；`TCase`/`DiffOutcome`/`DiffCase`/`DiffEngine`/`DiffRunner`/`DiffMismatchException`/`TMapping`/`T_MAP_*`/`allTMappings`/`okOutcome`/`diffFour`/`assertTripleEqual` 对外可达（顶层 `public`），按硬原则一不判；每个 `return` 后无同层语句；每个局部 `let/var` 均被读取（`unused0/unused1` 已单列为发现 #4，属「读了不用」的显式抑制写法的缺陷面） |
| §2 重复逻辑 | 3 | 两两比对 7 个文件的函数体：① 三个 `run` 逐字节相同（`sed` 切片 `diff` 为空）；② `maxNLocals`/`typesOf`/`reportOf` 与 `CompilePipeline.cj:331-364` 逐行相同/近同；③ F64↔I64 位型转换本文件两份、全仓五份。其余（`TCase.hit`、`StubRunner`、`okOutcome`、`allTMappings`）无同语义实现；`setup/teardown` 类模板不计 |
| §3 空实现 | 2 | `cells` 的 `case _ => out[i] = 0`（发现 #5）、`text` 的 `case _ => return ''`（`RealRunners.cj:396-397`，失败被吞成空串，已并入发现 #9）；未发现 `TODO`/`FIXME`/`catch {}`/空函数体 |
| §4 栈溢出 | 0 | 本部分无递归：`cells`/`arrayPointer`/`maxNLocals`/`typesOf`/`reportOf` 全为单层 `while`；`CFunc` 调用是尾调用式跳转，栈深度由被调机器码决定（已由 `X86Depth`/深度保护在其它部分审）；`DbgDump.report` 不在本部分 |
| §5 OOM | 0 | 分配规模都由单元规模决定且有上界：`Array<Int64>(consts.size)`、`Array<Int64>(args.size)`、`CodeBuffer.alloc(code.size + 16)`、`DbgDump.allocateDump(maxNLocals ≤ 65535)`；无按报文长度预分配、无全量物化、无全局集合只增不减（句柄表累积属「资源不对称」，已按 §11 报在发现 #2，不重复计） |
| §6.1 热点瓶颈 | 0 | 未提供 profile / bench 数据，`pinConst` 扫表与每用例编译均转「待验证假设」#1–#3，未写成缺陷 |
| §6.2 大粒度锁 | 0 | 本部分不持锁：`DiffSession` 无锁、`RealRunners` 无锁；`pinConst` 的全局 `mtx` 在 `HandleTable.cj`（范围外），其竞争面按「待验证假设」#1 记录 |
| §6.3 并发串行 | 0 | 无 `spawn`、无 `Future.get()`、无批处理窗口；`DiffSession.runAll` 是顺序 for 循环，语义上就是「逐引擎顺序跑」（同进程逐位对拍的前提），不算并发串行热点 |
| §6.4 低效算法 | 1 | 每个用例对全部常量做 `constHandle`（含全表线性去重）+ 全量重编译，归入「优化可行性方案」#1 与待验证假设 #1/#2；未发现嵌套循环 contains / `remove(at: 0)` / 循环内字符串拼接 |
| §7 降堆内存方案 | 0 | 本部分堆对象都是 O(单元规模) 的短命数组，无可量化收益；句柄表累积是「未回收」而非「表示冗余」，已按 §11 报。未提 local mode 方案（见下行） |
| §8 降 CPU 方案 | 2 | 常量句柄/编译产物缓存、跳过判定前置（两条均 `无基线`） |
| §9 local mode 可行性 | 0 | 本部分临时对象（`cells` 的 `Array<Int64>`、`typeOf` 的 `ArrayList<String>`）都小且短命、只在本函数内使用，没有可作为收益证据的峰值内存数据；local mode 需 `--experimental` + 逐模块 `compile-option`，收益不足以抵工具链风险 ⇒ 不建议改造 |
| §11 现有代码的 BUG（存量） | 6 | 发现 #2（句柄不回收）、#3（失败路径漏 `mirror.free`）、#4（`write/seal/set` 结果丢弃）、#5（`cells` 静默 0）、#6（<2 引擎抛异常）、#11（`entry` 缺失回落到 0）；均为存量（快照模式无基线） |
| §12 并发安全与锁粒度 | 1 | 线程封闭论证：`DiffSession`/`RealRunners` 均为每用例新建实例、由 `@TestCase` 串行调用（`diff_test` 与各 `*_test` 无并发入口）；`MachineEnv` 是线程私有（`RuntimeEnv.cj:111-126`），本文件 `setFnTableBase`/`reset` 不会跨线程可见。唯一并发面是「`run()` 不保存/恢复上一基址」（`RealRunners.cj:116`、`:140`），在宿主闭包重入场景下会清掉外层基址，已并入发现 #1 的「与 `JitExecutor.invokeOff` 漂移」 |
| §14 功能完备性与 README 覆盖 | 2 | ① 「非原生 ⇒ 跳过而非失败」承诺未实现（发现 #6）；② `tMappingHasNoDanglingEntries` 承诺「无悬空项」但只查非空（发现 #14）。README 覆盖：本部分 7 个文件全部在 `src/test` 与 `src/userapi/*_test.cj`，其公开符号（`TCase`、`TMapping`、`T_MAP_IN_SCOPE`/`M2`/`M3`、`allTMappings`、`DiffOutcome`、`DiffCase`、`DiffEngine`、`DiffRunner`、`DiffSession`、`InterpRunner`、`NativeRunner`、`StubRunner`、`okOutcome`、`diffFour`、`assertTripleEqual`、`DiffMismatchException`）在 `f_jit/README.md:619` 的公开清单里全部可检索到（`AArch64Runner` 逐成员说明在 `:621`、`TCase` 在 `:702`）⇒ 无遗漏 |
| 文件覆盖（§13 等） | 7/7 | 全部 7 个 `.cj` 已读完；本部分无 `.md`（README 归其它部分） |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 6 |
| 轻微 | 8 |
| 优化方案（堆内存 / CPU） | 0 / 2 |

存量缺陷 14 条（全部为存量，快照模式无基线），是否纳入修复待用户决定。本部分未命中「严重」的原因：所有缺陷都落在**测试基建**（差分 harness / 映射表 / 自证用例）上，不影响生产 JIT 语义；其中最接近严重的是 `cells()` 静默 0（可造成假绿）与 `<2` 引擎抛异常（让非原生平台必红），但两者都需要特定调用方式/平台才触发，故按后果定级为「一般」。

## 总评

这 7 个文件的定位很清楚：一层「四元组对拍」的测试基建 + 一张 61 条的 T 编号映射表 + 一套自证用例。**数据与断言当前是干净的**——我逐条核对了 61 条映射的 `caseName`（全部能在 `src/**/*_test.cj` 中找到同名 `func`）与 61 个 `T<id>/` 标签（全部出现在可执行语句里，非注释），`diff_test` 的 11 个用例、`UserApi_test` 的 2 个用例也与实现一致，这部分不需要返工。

真正的风险在两处「看起来能跑」的地方：

- **`RealRunners.cj` 是一份已经落后于生产实现的 FFI 副本**。同一段「编译 → 映射 → 执行 → 收尾」在仓内有 4 份，测试层这三份缺少 `JitExecutor.invokeOff` 的 `try/finally`、`MachineEnv` 保存-恢复与常量句柄回收，并且 `write/seal/set` 的失败、`FnTable.alloc` 之后的 `mirror` 都未处理。现在用例只覆盖 Int64/F64/String 返回与 0~2 个实参，所以这些缺口没暴露；一旦有人用这套 harness 做「宿主对象 / 容器返回」的差分，会先遇到句柄 ID 假不一致，再遇到句柄表只增不减。
- **差分的「跳过」语义只写在注释里**。`DiffSession` 在只剩一个可用引擎时抛异常，而所有调用方（`Acceptance_test`、`DiffExec_test`、`Q6DiffCoverage_test`）都按「非原生平台应跳过」来写断言，结果是非 Linux / 非 x86_64-aarch64 平台这批用例必红。修这一条的成本很低（前置 `availableCount()` + 返回判定），收益是让「无证据」与「失败」在 CI 里不再混为一谈——这恰好是本模块最需要的信号质量。

建议排期：先修 `<2` 引擎的跳过语义与 `cells()` 的静默兜底（两者都会直接污染证据），再按 `JitExecutor.invokeOff` 收敛三份 `run`（顺带把常量句柄回收、`mirror.free`、`write/seal` 检查补齐），最后清死代码（`nativeRunner`）、过期注释（`TMapping`）与映射自证用例的名实不符。性能相关的两条（常量句柄缓存、编译产物缓存）都缺基线，先按「待验证假设」采数据，不进修复清单。
