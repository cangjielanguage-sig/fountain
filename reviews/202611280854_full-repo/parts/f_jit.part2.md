# f_jit 模块审查报告（模块第 2/38 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_jit`（本部分 1 个 `.md`、0 个 `.cj`；模块共 305 个 `.cj` + 290 个 `.md`，本部分为 M1 详细设计 `doc/design-m1.md`）
- **基线**：工作区快照（sts/1.3.x，未对照远端分支，无 diff 基线；本部分全部记为「存量」）
- **审查重点**：动态调用/桥接正确性（typecode 分支表）、句柄与资源生命周期、并发安全、递归与栈溢出、死代码、重复逻辑、存量 BUG——本部分文件是设计文档，因此逐条把文档承诺与 `src/` 实现对照取证（§13 / §14 / §11）
- **报告版本**：v1.1（v1 的 18 条保留；补入栈防护能力、编译期递归、`pin` 身份、容量配置并发、卸载顺序矛盾、Decimal/HDR 口径、helper 73–76 编号共 8 条）

## 发现

### [严重][存量] `STACK_GUARD` 的能力被设计夸大：只护帧内操作数栈，错误码 15 全仓无生产者

- **位置**：`f_jit/doc/design-m1.md:1146`（附 A.7「栈防守与安全点｜隐式（回边/**进入**）」）、`f_jit/doc/design-m1.md:1465`（C.4 `STACK_GUARD` 行「解释器余量亦不足 → **桥写 15**」）、`f_jit/doc/design-m1.md:1437`（C.2 入口序列没有该指令）、`f_jit/doc/design-m1.md:267`（§2.3.10 错误码 15）；代码 `f_jit/src/backend/A64Lower.cj:364-370`、`f_jit/src/backend/X86Lower.cj:1020`、`f_jit/src/runtime/Interp.cj:212`、`f_jit/src/base/ErrCode.cj:61`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §4「无界递归 / 深度由输入决定」、§11「契约与实现不符」、§13「文档内部不一致」
- **证据**：静态确定 —— `STACK_GUARD` 的判据是 `(rbp − FRAME) − rsp`，只检查**本帧操作数栈**是否越过帧底；`CALL_FUNC`/`CALL_CLOSURE` 压入的新机器栈帧位于 `rsp` 之下，这个比较看不到调用深度。设计 A.7 声称「进入」也发 `STACK_GUARD`，但 C.2 入口序列（`:1437`）没有它，编译器也从不发射 0x07（`f_jit/src/compiler/Ops.cj:35` 只有常量；`grep -rn "Ops.STACK_GUARD"` 在编译器内零命中），唯一发射点是 `LOOP_BACK` 的 lowering。解释器把 0x07 当空操作（`Interp.cj:212`），而它的 `CALL_FUNC` 是仓颉原生递归（`Interp.cj:614` → `run` → `exec`）。错误码 15 没有任何写入者：`grep -rn "ErrCode.STACK_GUARD"` 只命中定义与测试断言，`DiagCode`/桥/引擎均不写 15
- **描述**：设计用 A.7/C.4 建立了一个「回边与进入都有栈防守、最坏退回解释器、解释器不够就写 15」的安全论证；这条论证在实现里不成立：进入无守卫、解释器无检查、15 无生产者。非尾 `recursive` 的深度由运行期数据决定，两条引擎都以宿主 `StackOverflowError`（灾难性 `Error`，按 D1 不捕不吞）终止，而不是 15。递归深度本身已在 part1 #5 记录（同根因，合并时保留一条即可）；本条针对的是**设计文档把 `STACK_GUARD` 当作通用递归防护**这一错误论断
- **建议**：二选一——① 删掉 A.7「进入」与 C.4「桥写 15」，把 `STACK_GUARD` 明确限定为「帧内操作数栈余量」；② 补真正的调用深度预算（ctx/线程态 depth，`CALL_FUNC`/`CALL_CLOSURE` 入口增减，超限写 15，解释器同一上限），并把上限写进 §8.4 契约

### [一般][存量] 生命周期 API 写成 `unload` / `isUnloaded`，实现只有 `close` / `isClosed`

- **位置**：`f_jit/doc/design-m1.md:894-895`（`func unload(timeout!: ?Duration = None): Bool`、`prop isUnloaded: Bool`）、`f_jit/doc/design-m1.md:981-985`（§8.6 的 `Ready --CAS--> Unloading --activeCalls==0--> Unloaded` 状态机）、`f_jit/doc/design-m1.md:968`（§8.4 第 0 步「Ready（未卸载）」）；代码 `f_jit/src/JitFunction.cj:227`（`close(timeoutMs: Int64): Bool`）、`:471`（`isClosed(): Bool`）、`:523`（`close(): Unit`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「API / 配置 / 默认值与源码不符」、§14.1「承诺了但没实现」；本部分审查重点「句柄与资源生命周期」
- **证据**：静态确定 —— `f_jit/src` 全仓 `grep -n "func unload"` 只命中私有 `unloadClosure`（`JitFunction.cj:302`），公开成员只有 `close` / `close(timeoutMs)` / `isClosed`；`JitFunction <: Resource`（`:59`）决定了 `close` 是契约名。`design-m2.md:383` 还明确写「`unload` 保持单元级不变」，说明后续设计也认为它仍存在
- **描述**：按设计写 `f.unload()` 或读 `f.isUnloaded` 的宿主代码无法编译；§8.6 的卸载状态机、§8.4 的入口断言都以 `unload` 命名，读设计去核对 `JitFunction` 会找不到落点。生命周期是宿主最容易误用的一块（漏关闭 → 代码内存/提升组常驻），文档名与实际 API 不一致会直接放大这个风险
- **建议**：§7.3.3 与 §8.6 统一改为 `close(timeoutMs): Bool` / `close(): Unit` / `isClosed()`，并注明「`Resource` 契约；入口实例 = 单元卸载，包装实例 = 释放本闭包」；若要保留 `unload` 兼容别名，需在设计中单列并说明与 `close` 的关系

### [一般][存量] `Compiler.compile(unit: SourceUnit)` 分发入口未实现，`SourceUnit` 在生产路径无消费方

- **位置**：`f_jit/doc/design-m1.md:880`（`func compile(unit: SourceUnit): JitFunction`）、`f_jit/doc/design-m1.md:950-952`（§8.2 分发入口「替换 ② 为 `FbcReader.load(raw)`，去重键 = 字节码指纹」）、`f_jit/doc/design-m1.md:181-182`（`SourceUnit.entryFn` 须与容器头一致，否则加载期拒绝）；代码 `f_jit/src/Compiler.cj:185`（只有 `compile(source: String)`）、`f_jit/src/CompilePipeline.cj:95`（`runUnit(raw: Array<UInt8>, c: Compiler)`，入口号取容器头 `unit.header.entryFn`，不接受期望值）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §14.1「承诺了但没实现」、§13「API 与源码不符」、§1「非 public 无引用 / public 无使用」的取证要求
- **证据**：静态确定 —— `grep -rn "compile(unit" f_jit/src` 零命中；`SourceUnit` 只出现在自身定义、`src/base/SourceUnit_test.cj` 与 `src/BaseVisibility_test.cj`，无生产消费方；`Root.cj:23-46` 也未再导出它。设计承诺的「`entryFn` 与容器头不一致→加载期拒绝」在 `runUnit` 路径不存在（它直接用容器头的值）
- **描述**：设计把「分发已编译字节码」列为与源入口并列的公开能力，实现只提供 `CompilePipeline.runUnit(raw, c)`——参数少一个期望入口号、语义也不同（不能用 `SourceUnit` 指定入口）。`SourceUnit` 因此是一个「对外 public、仓内只被测试引用」的悬空契约类型；宿主按 §8.2 无法把「我想要 entryFn=N」表达出来
- **建议**：二选一并写进设计：① 在 `Compiler` 上补 `compile(unit: SourceUnit): JitFunction`，在 `runUnit` 前校验 `unit.entryFn == header.entryFn`；② 承认分发入口只有 `runUnit`，删除 `SourceUnit` 或把它降为 `internal`，并同步 §2.3.5 / §7.3.1 / §8.2

### [一般][存量] `CallContext.args` 已被删除，设计仍把它当作 Marshal 载体与 `rawEntry` 实参来源

- **位置**：`f_jit/doc/design-m1.md:172-173`（`var args: Array<Int64>`、`var deadline: ?DateTime`）、`f_jit/doc/design-m1.md:958`（§8.3 第 2 步「逐参 Marshal → CallContext.args」）、`f_jit/doc/design-m1.md:970`（`rawEntry(ctx, &args[0], nargs)`）；代码 `f_jit/src/base/CallContext.cj:44-47`（只有 `public let deadline!: ?DateTime = None`，注释明确「为何删掉 `args`：从未被任何执行路径读取」）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「API 与源码不符」、§1「读了不用 / 兼容残留」
- **证据**：静态确定 —— `CallContext` 现在是无字段（除 `deadline`）的单行 struct；`JitFunction.callLocked` 的封送走 `call<T>(args: Array<Any>)` + `CallMarshal`（`JitFunction.cj:617-635`），再用 `JitContext.create(hwBase, …)` 建 ctx，实参数组是局部 `cells`，与 `CallContext` 无关
- **描述**：设计把 `CallContext` 描述成「桥侧调用参数（args + deadline）」，并把它画进三态收尾第 2 步。宿主若按设计构造 `CallContext(args: ...)` 会编译失败；读设计排查「实参怎么进 ctx」会被引到一个不存在的字段。更实际的后果是：`CallContext` 的语义边界（只装调用级选项）在文档里没有一处写清
- **建议**：§2.3.4 改成「`CallContext` 只装调用级选项（`deadline`）；实参走 `call<T>(args: Array<Any>)` 并由 `CallMarshal` 封送」；§8.3 第 2 步把 `CallContext.args` 换成局部 `cells`，并说明 `args` 曾存在但从未被消费

### [一般][存量] 去重缓存与 D4 / §3.3.8 的契约不符：键含配置项、命中无原字节二次校验、`DedupGuard` 无调用者

- **位置**：`f_jit/doc/design-m1.md:914`（`lookupOrClaim(sourceCode)`「内部以 `FNV-1a-128(规范化源码)` 为键」）、`f_jit/doc/design-m1.md:1014`（D4「一份源码只出一份字节码与 JIT 产物」）、`f_jit/doc/design-m1.md:417`（「缓存条目保存原始输入字节，命中后做长度 + 字节二次校验（不符按 Miss 重编）」）；代码 `f_jit/src/CompilePipeline.cj:59-60`（`'src/<jit>/v<verMajor>/fp<strictFp>/<fnv1a128(source)>'`）、`:96`（`'fbc/<jit>/<fnv1a128(raw)>'`）、`f_jit/src/CompileCache.cj:53-58`（`lookup` 只返回 `?JitFunction`，不持有原始字节）、`f_jit/src/bytecode/Fingerprint.cj:119`（`DedupGuard` 全仓无生产引用）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「规格与实现漂移」、§14.1「接线缺失」、§1「注册了但永不触发」
- **证据**：静态确定 —— 缓存键由「jit 模式 / verMajor / strictFp / 指纹」四段拼成，注释写明「同源不同配置必须各自成键」，因此同一份源码在 `Auto` 与 `Off`、`strictFp=true/false`、v1/v3 下会各出一份产物，D4 的绝对表述不成立；`lookup` 的签名无法做二次校验（没有第二份字节可对比），`CompileCache.cj:28` 注释把责任推给 Pipeline，但 `runSource` / `runUnit` 命中即 `return f`（`CompilePipeline.cj:57-60`、`:97-100`），全仓也搜不到字节比较；`DedupGuard` 是为该契约准备的类型，却只被定义
- **描述**：这组偏差有三个可观察后果：① D4 的「一份源码只出一份产物」在宿主切换 `jit`/`strictFp`/`verMajor` 时不成立，缓存条目数按配置组合增长，「close 后同源再编」也不再是唯一入口；② §3.3.8 把「碰撞 = 语义错误」定为必须靠二次校验兜底，实现的 128 位指纹命中后直接复用，安全论证缺了最后一环（理论上仍是可碰撞的，虽然概率极低）；③ `DedupGuard` 成为「为契约而生、从未接线」的类型，后续读者会以为校验已存在
- **建议**：三处对齐——① 文档把 D4 改成「同一 (源码, jit, strictFp, verMajor) 只出一份产物」，并说明关闭/重编语义按该键；② 要么在 `CompileCache` 条目里保存 `(key, rawBytes)` 并在 `lookup` 命中时用 `DedupGuard.matches` 复核，要么删掉 §3.3.8 的二次校验承诺与 `DedupGuard`（明确接受 128 位碰撞概率）；③ 不要让注释把「调用方负责」写成事实而不给调用方留接口

### [一般][存量] 桥内执行结果机制已被内联重构：`invoke` / `tryInvoke` / `JitValue` / `AdapterRegistry` 在生产路径均不存在

- **位置**：`f_jit/doc/design-m1.md:207-213`（§2.3.6 `JitValue`「产生点唯一：`invoke`/`tryInvoke` 三态收尾第 3 步」）、`f_jit/doc/design-m1.md:896-897`（私有 `invoke(ctx): JitValue` / `tryInvoke(ctx): Result<JitValue, JitException>`）、`f_jit/doc/design-m1.md:915`（`AdapterRegistry.register/lookup/removeUnit`「call 第 5 步；卸载」）、`f_jit/doc/design-m1.md:961`（§8.3 第 5 步「跨模块/动态 → `AdapterRegistry` 运行期校验 → 19」）；代码 `f_jit/src/base/JitValue.cj:42`（`protected enum JitValue`，全仓生产代码零构造/零读取）、`f_jit/src/AdapterRegistry.cj:27`（`protected class`，只被自身与 `AdapterRegistry_test.cj` 引用）、`f_jit/src/JitFunction.cj:555-577`（`call<T>` 内联完成 T 校验，未经过任何注册表）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §1（顶层 `protected` 类型无引用 = 死代码；接口/父类覆盖除外）、§3「接口默认空实现 / 承诺但实现为空」、§13
- **证据**：静态确定 —— `grep -rn "JitValue" f_jit/src` 只命中定义文件与 `Root.cj:21` 的一句注释（该注释还把 `JitValue` 列为「执行期内部类型」）；`AdapterRegistry` 的全部调用点在 `AdapterRegistry_test.cj`。T 一致性校验实际由 `localTypeOf<T>` 与 `retType` 比较完成（`JitFunction.cj:568-577`），命中失败仍返回 19，功能在、机制不在
- **描述**：设计用整整一节描述「用户意图 `JitMode` → 实际事实 `Engine` → 桥内结果 `JitValue`」这条链路，并用 `Result<JitValue, JitException>` 定义「不抛变体」。实现把这三态直接内联进 `call<T>`，`JitValue` 从此没有任何生产者/消费者，`AdapterRegistry`（含两张 static 表与卸载清理）也整体悬空。读者会按设计去找 `invoke`/`tryInvoke` 与适配器注册时机，实际都不存在；这也让「D3 结案：`JitValue` 为 protected 因唯一消费者是私有 invoke」的论证失效
- **建议**：§2.3.6 / §7.3.3 / §7.3.5 / §8.3 收敛为「`call<T>` 单一路径：Marshal → 执行 → `unboxRet` → T 校验（`localTypeOf<T>`）」，删除 `invoke`/`tryInvoke`/`JitValue` 或明确标注为已撤销；`AdapterRegistry` 与 `JitValue` 若确认不再需要，按死代码清理（`protected` 顶层类型，`Root.cj` 已声明不对外）

### [一般][存量] §6.3 后端产物与引擎选择的实现形态已重构，`JitArtifacts` / `JitCompiler` / `BackendSelector` 的描述全部失配

- **位置**：`f_jit/doc/design-m1.md:816-822`（`JitArtifacts` 持 `code: CodeBuffer` / `fnTable: FnTable` / `mirror: ConstMirror`，有 `rawEntry(fnId)` 与 `free()`）、`f_jit/doc/design-m1.md:811-814`（`JitCompiler.init(backend, diagnostics)` + `compileUnit(unit, handleIds)`）、`f_jit/doc/design-m1.md:843`（`BackendSelector.select` 由桥管线第 3 步调用）、`f_jit/doc/design-m1.md:985`（卸载顺序依赖 `JitArtifacts.free()`）；代码 `f_jit/src/backend/JitCompiler.cj:23-56`（`JitArtifacts` 是 `code: Array<UInt8>` + `fnIds/offsets/lengths`，只有 `entry/codeOf`，无 `free()`）、`:63-80`（`JitCompiler` 全 static，无 `init`）、`f_jit/src/backend/JitExecutor.cj:53-70`（`JitExecutor.create(unit, entryFn)` 自行建 `CodeBuffer/FnTable/ConstMirror` 并选路）、`f_jit/src/backend/BackendSelector.cj:40`（`select` 仅被自身与测试调用）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「API / 结构与源码不符」、§14.1「接线缺失」、§3（承诺的 `free()` 与选路入口无实现）
- **证据**：静态确定 —— `grep -rn "BackendSelector\." f_jit/src` 的生产命中只有 `BackendSelector.cj` 自身；`JitArtifacts` 的三件原生资产改由 `JitExecutor` 私有字段持有（`JitExecutor.cj:34-37`），`release()` 在 `:185`；`JitArtifacts` 不再拥有可释放资源，`free()` 无从谈起
- **描述**：这是设计里「JIT 产物束 = 三块非 GC 资产 + 入口表」的核心结构，§8.7 的卸载顺序（「code buffer + fnTable 最后释放」）完全建立在它之上。实际结构是「纯字节束（可 GC）+ 独立的 `JitExecutor` 持有三块原生资产」，所以按设计核对资源释放会找不到 `JitArtifacts.free()`，也无法解释 `BackendSelector` 为何存在却不在管线里。资源生命周期的描述因此失真（真正的释放点在 `JitExecutor.release` 与 `JitFunction.close` 的 `rel` 闭包）
- **建议**：§6.3.2–6.3.4 按现实现重写：`JitArtifacts` = 字节束 + `entry/codeOf`；`JitExecutor` = 资产所有者 + 引擎门禁（非 Linux/非 x86_64/aarch64 → `None`）；`BackendSelector` 标注为「仅诊断/测试用，生产管线不经过」或直接删除；§8.7 的释放顺序改为按 `JitExecutor.release` 与 `JitFunction.close` 的实际次序描述

### [一般][存量] 诊断接线缺失：`JitFallback` / `MmapFailed` 永不送达宿主 sink，编译阶段固定使用 `DummyDiagnosticsSink`

- **位置**：`f_jit/doc/design-m1.md:196-197`（`JitMode` 不可用「只记 diagnostics」）、`f_jit/doc/design-m1.md:843`（`BackendSelector.select` 否则 `(Interp, None)` 并记 diagnostics）、`f_jit/doc/design-m1.md:945`（§8.1 第 ③ 步「diagnostics 记 `(Warn, JitFallback)`」）；代码 `f_jit/src/backend/JitExecutor.cj:53-70`（不支持即 `return None`，不接收也不调用 `DiagnosticsSink`）、`f_jit/src/CompilePipeline.cj:239`（`JitExecutor.create(unit, entryFn)`，未传 `opts.diagnostics`）、`f_jit/src/CompilePipeline.cj:72`（`SourceCompiler(snap, DummyDiagnosticsSink(), …)` 硬编码）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §14.1「接线缺失」、§3「开关打开后走进空分支」、§13「承诺与实现相反」；本部分审查重点「动态调用/桥接正确性」
- **证据**：静态确定 —— `grep -rn "diag(" f_jit/src` 的非测试命中只有 `BackendSelector.cj:61/71`（未被管线调用）与 `ReflectRegistrar.cj:908`（注册期）；`DiagCode.MmapFailed` 无任何发射点；`JitMode.Force` 在非 Linux 上能观察到的唯一差异是 `JitFunction.isJitBacked()`，而不是设计承诺的 `(Warn, JitFallback)` 事件
- **描述**：T7 的可观测定义是「存在 `(Warn, JitFallback)` 事件」，而宿主通过 `Compiler.compile()` 走的生产路径永远不会产生该事件；编译期的 sink 也被替换成 `DummyDiagnosticsSink`，宿主传入的 `opts.diagnostics` 只在 `registerType/registerInterface` 时被用到。结果是：设计里的「静默降级、只记 diagnostics」实际变成「静默降级、什么都不记」，宿主无法在自己的日志里区分「JIT 生效」与「悄悄退解释器」
- **建议**：把 `opts.diagnostics` 传进 `SourceCompiler` 与 `JitExecutor.create`（或由 `CompilePipeline` 在 `create` 返回 `None` 时按门禁原因发 `(Warn, JitFallback)` / `MmapFailed`）；删除 `BackendSelector` 或让它重新成为唯一选路入口；在 `DiagCode` 注释里写清每个码的发射点

### [一般][存量] `unregisterFunction` 契约不符：设计为 `Unit` + 未注册抛编译期错误，实现为 `Bool` + 返回 false

- **位置**：`f_jit/doc/design-m1.md:876`（`func unregisterFunction(name: String): Unit`｜「注销（未注册 → 编译期错误）」）；代码 `f_jit/src/Compiler.cj:87-99`（`public func unregisterFunction(name: String): Bool`，未命中 `return false`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「API 与源码不符」、§11「错误处理缺失或静默」「契约与实现不符」
- **证据**：静态确定 —— 返回类型与失败路径都与设计相反；`design-m2.md` / `design-m3.md` 未记录该变更（`grep` 零命中），README 也未说明「未注册返回 false」
- **描述**：注销一个拼错的名字在实现里是静默 `false`，在设计里是编译期错误。宿主若按设计用 `catch (SourceCompileException)` 检测注册表拼写问题，会完全失效；反之若按实现忽略返回值，也无法知道注销是否真的发生。注册表是与编译器共享的可变状态，「静默无操作」比「抛错」更难排查
- **建议**：确定一种语义并同步三处（设计 / README / 实现）：要么保留 `Bool` 并在 §7.3.1 写明「未注册 → false，不抛」，要么恢复抛 `SourceCompileException(UndefinedIdentifier)`；不建议两者并存

### [一般][存量] 同键编译失败只共享文本、不共享异常类型：等待方拿到 `kind=CompileFailed`，首个调用方拿到真实 kind

- **位置**：`f_jit/doc/design-m1.md:914`（`CompileCache`「失败共享异常」）；代码 `f_jit/src/CompilePipeline.cj:82` / `:110`（`CompileCache.fail(key, e.message)` 只存文本）、`f_jit/src/CompileCache.cj:98-107`（`failures: HashMap<String, String>`）、`f_jit/src/CompilePipeline.cj:129-137`（`missingResult` 一律返回 `('CompileFailed', m)`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11「错误处理缺失或静默」、§12.1「`Future` 异常被吞 / 异步语义」、§13「契约与实现不符」
- **证据**：静态确定 —— 首个线程抛原始 `SourceCompileException`（如 `kind=UnregisteredFunction`）；同键的后续线程经 `awaitReady → None → missingResult` 得到 `SourceCompileException('CompileFailed', 原文本)`。`kind` 是测试与宿主分支的依据（`design-m1.md:152` 明写「测试断言 kind」），文本相同不能替代
- **描述**：并发首次编译同一份坏源码时，先到的线程能拿到精确诊断（未注册函数 / 未定义标识符 / 类型不符），后到的线程只拿到 `CompileFailed`。宿主若按 `kind` 提示「该注册哪个函数」，只有第一个请求能得到正确提示；同一份源码的失败语义随线程时序变化
- **建议**：失败条目保存 `(kind, position, line, column, lineText, hint)`（或直接保存异常对象的克隆），`missingResult` 按原 kind 重建；或者文档明确写「缓存失败只保证文本等价，kind 统一为 `CompileFailed`」

### [一般][存量] `compile()` 可能返回正在 `close` 的单元：`Ready` 复用语义在 `Unloading` 窗口内不成立

- **位置**：`f_jit/doc/design-m1.md:1014`（D4「命中 Ready 复用」）、`f_jit/doc/design-m1.md:982`（§8.6「Unloading（拒绝新调用）」）、`f_jit/doc/design-m1.md:968`（§8.4 第 0 步「入口断言 Ready，否则 19」）；代码 `f_jit/src/CompileCache.cj:53-58`（`lookup` 只按 key 取 `JitFunction`，不检查状态）、`f_jit/src/JitFunction.cj:235`（`close` 先把 `state=1`）、`:263`（排空后才 `CompileCache.remove(k)`）、`:198-206`（`enterUnit` 在 `state != 0` 时抛 19）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §12.1「发布逸出 / 检查-然后-写入」「异步语义：取消后仍改状态」、§11「并发正确性」；本部分审查重点「并发安全、句柄与资源生命周期」
- **证据**：静态确定（机制成立）/ 待确认（是否属可接受语义）—— `close` 从 `state=1` 到 `remove` 之间有一个跨排空的窗口（`active` 不为 0 时可长达整个 timeout），此窗口内 `CompileCache.lookup(key)` 仍能取到该单元；`runSource` / `runUnit` 命中即返回，随后 `call` 在 `enterUnit` 得 `CALL_CONTRACT(19)`。`UnloadConcurrency_test.cj:26-90` 只验证「close 期间已有句柄的新调用得 19」，没有覆盖「close 期间 compile 命中同一 key」
- **描述**：宿主并发做「编译同一源码」与「关闭旧单元」时，`compile` 可能成功返回一个已经进入卸载态的句柄，紧接着第一次 `call` 就抛 19；若宿主不重试，表现为「刚编译出来就不能用」。设计只承诺「Unloading 拒绝新调用」，没有规定此时 `compile` 的可见性，属于契约空白
- **建议**：`CompileCache.lookup` 命中后过滤 `state != 0` 的条目（返回 `None` 并允许重新 `claim`），或在 `close` 开始时就把条目从 `ready` 摘除（排空失败再放回）；同时在 §8.6 补一句「compile 与 close 并发时 compile 要么返回可用单元、要么重新编译」，并加一条并发用例

### [一般][存量] §7.3.6 的再导出清单未落地：根包没有 `public import base.*` / `bytecode.*` / `runtime.*`，`CallContext` / `SourceUnit` / `TypeToken` / `Version` / `HandleTable` 均不在用户面

- **位置**：`f_jit/doc/design-m1.md:923-926`（`public import fountain::f_jit.base.*`、`...bytecode.*`、`...runtime.*`（`HandleTable`））；代码 `f_jit/src/Root.cj:23-46`（逐符号导入 19 项，无 `base.*`、无 `bytecode.*`、无 `runtime.*`；`CallContext`、`SourceUnit`、`TypeToken`、`Version`、`HandleTable` 都不在其中）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「API / 配置与源码不符」、§14.2「公开 API 未文档化 / 索引未登记」、§1「对外可达 ≠ 用户面可达」
- **证据**：静态确定 —— `grep -n "^public import" Root.cj` 只有 19 条 base 单符号；`BaseVisibility_test.cj:20` 用的是 `import fountain::f_jit.base.*`，因此它并不能证明「根包再导出清单不缺项」（测试注释与实际导入口径不一致）
- **描述**：按设计写 `import fountain::f_jit.*` 后使用 `CallContext()`、`HandleTable.pin()`、`TypeToken.LIST`、`Version.MINOR` 会编译失败，必须改写成 `fountain::f_jit.base.CallContext` / `fountain::f_jit.runtime.HandleTable`。§2.3.6 还写「宿主经 `HandleTable.get(id)` 取回对象」，进一步暗示这些类型在用户面；README §2 也把 `CallContext` 列为公开 API。再导出清单是「用户面冻结」的唯一定义（`Root.cj:20` 注释自称按 S6.11 只导出清单内声明），清单与实现不一致会让「什么算对外契约」失去判据
- **建议**：按 `design-m2/m3` 的实际用户面重写 §7.3.6：把 `CallContext`、`TypeToken`、`Version`（若确实要给宿主）补进 `Root.cj`，或从设计/README 的用户面清单删除；`BaseVisibility_test` 改为从根包 `import fountain::f_jit.*` 断言，才能真正测到再导出

### [一般][存量] 编译期递归下降没有嵌套上限，深嵌套源码在 `compile(source)` 内栈溢出

- **位置**：`f_jit/doc/design-m1.md:493-505`（§4.3.2 `AstExpr`/`AstStmt` 递归定义）、`f_jit/doc/design-m1.md:429`（§4.1 前端管线）、`f_jit/doc/design-m1.md:519`（`DefiniteAssignment.analyze` 数据流）；代码 `f_jit/src/compiler/Parser.cj:767`（`parseExpr`）、`:983`（`parseUnary`）、`:1002`（实参递归）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §4「无界递归：深度由输入决定」、§14.1「半成品 / 只处理部分输入」
- **证据**：静态确定 —— `parseExpr` 经一元/括号/调用实参回到自身，形成递归下降；`Parser.cj` 里的 `depth` 变量只用于括号/元组配平（`:516`、`:546`、`:616`），全文件没有递归深度计数器或拒绝阈值；设计正文对 Lexer/Parser/DA 也没有任何嵌套上限
- **描述**：`compile(source)` 是公开入口，源码长度与嵌套深度不受约束；`((((…1…))))`、连续一元运算或深层 `if` 表达式会线性消耗宿主栈，数千至上万层即可触顶（阈值需实测，不在本报告断言字节数）。后果是编译期崩溃（`StackOverflowError`）而不是 `SourceCompileException`，宿主无法按 §8.4 的统一错误通道捕获
- **建议**：Parser（以及同样递归的 `DefiniteAssignment`/`Lowerer`）加统一 depth 计数，超限抛 `SourceCompileException`（新增 `TooDeep` kind 或明确复用现有 kind）；上限与诊断码写入 §4.3/§8.4，并在 README 的「已知限制」同步

### [一般][存量] `pin` 的「同表同对象复用同 ID」与实现的「窗口内去重」不一致

- **位置**：`f_jit/doc/design-m1.md:700`（§5.3.2 `pin<T>`｜路径 B「同表同对象复用同 ID；tag 按类型 token 写」）；代码 `f_jit/src/runtime/HandleTable.cj:462-498`（只在当前窗口 `appendIds + pins` 内线性查重，注释明写「不再在全局锁内做全表线性扫描」）、`:488`（List/Map 显式排除）、`:611-629`（`pinConst` 才做全表去重）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「契约与实现不符」、§12.1「跨线程身份 / 状态共享」、§11「语义与命名不符」
- **证据**：静态确定 —— 实现只在**本调用窗口**已登记的 ID 里按规范键/对象身份查重；窗口外或跨调用的同一对象一律新开槽。可变容器每次 `pin` 都取新槽（`:488`），设计未写这个例外
- **描述**：设计把「同对象 ⇒ 同 ID」写成 `pin` 的契约，桥/宿主可能据此缓存 ID 或做身份比较；实际跨调用、跨窗口都不保证，第二次调用后可能拿到不同 ID，旧 ID 还会随窗口重置失效。`JitValue.Handle`「只能显式 release」的论证也建立在这个身份假设上，假设不成立时释放责任更难界定
- **建议**：把契约改写为「**同一调用窗口内**同值（不可变类型）/同对象（闭包、Any 盒、宿主对象）复用同 ID；跨调用不保证；List/Map 每次新槽」；若宿主确实需要跨调用稳定身份，另设 `pinStable` 并说明生命周期与释放责任

### [一般][存量] `initialCapacity` / `capacityLimit` 设计为无同步 `static var`，却允许运行中调整

- **位置**：`f_jit/doc/design-m1.md:703-704`（§5.3.2 两个 `static var`：「调用前可调」「运行中调大即时生效、调小不追溯」）、`f_jit/doc/design-m1.md:706`（`append` 扩容读这两个值）；代码 `f_jit/src/runtime/HandleTable.cj:149-169`（`AtomicInt64` + `mut prop`，注释 H4 明说「不再有数据竞争」）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §12.1「共享可变状态无保护 / 可见性」、§10 设计合理性
- **证据**：静态确定 —— 设计只给普通 `static var`，未指定 `Atomic`、锁或发布方式；`append`（读 cap/limit）与宿主赋值（写）并发时构成数据竞争，扩容判定可能读到撕裂/过期值。实现已改成原子属性，反证设计原文的写法不安全
- **描述**：按设计直接实现会出现「调大容量不生效」「读到旧上限提前报 16」这类不可复现问题，并行调用下更明显。文档没有写「配置只在无并发时改」或「必须原子」
- **建议**：§5.3.2 明确「两字段必须是原子读写的配置；每次开窗取一次快照（`openWindowWith` 已如此），窗口生命周期内不再重读全局值」，并把「即时生效」限定为「对**新开窗口**生效」

### [一般][存量] §8.6 卸载状态机与「code buffer 最后释放、可能仍有活跃调用」自相矛盾

- **位置**：`f_jit/doc/design-m1.md:982-985`（§8.6：`activeCalls==0 → Unloaded` 与「code buffer+fnTable（最后，**可能仍有活跃调用在执行**）」同段）、`f_jit/doc/design-m1.md:894`（§7.3.3 `unload`「超时恢复 Ready 可重试；幂等返回 true」）；代码 `f_jit/src/JitFunction.cj:239-286`（排空 `active==0` 后才 `state=2`，再在锁外 `release()`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §12.1「并发正确性」、§11「语义与注释不符」
- **证据**：静态确定 —— 状态机规定只有活跃调用归零才进入终态，此时不可能还有调用在执行；实现也把 `state=2` 放在 `active==0` 之后、`release()` 之前。同段两句只能有一句成立
- **描述**：这是卸载/释放的唯一权威描述。实现者若照括号里的「可能仍有活跃调用」去做，会把 `munmap`/`free` 提前到排空之前，直接 use-after-free；反之照状态机做，就该删掉该括号。`unload` 的「幂等返回 true」与「超时返回 false 可重试」也需要分开表述（重复卸载 true、超时 false）
- **建议**：改写为「进入 Unloading 后拒绝新调用；`active==0` 是释放的**前置条件**；资产在终态后、单线程内释放」；`unload` 契约拆成「已卸载 → true；本次成功 → true；超时 → false 且状态回 Ready」

### [轻微][存量] `DiagKind` 清单缺 4 个实际存在的 kind，文档却称「清单见 §4.3.9」

- **位置**：`f_jit/doc/design-m1.md:152`、`f_jit/doc/design-m1.md:564`（词法族 9 + 解析/名字/校验族 6）；代码 `f_jit/src/compiler/Token.cj:273-320`（另有 `NOT_ASSIGNED=:308`、`TYPE_MISMATCH=:310`、`SYNTAX_ERROR=:312`、`CODE_GEN=:319`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「文档过期」、§14.1「只做了一半的分支」
- **证据**：静态确定 —— 4 个 kind 都在 `DiagKind` 内、被 `DefiniteAssignment` / `ClassRegistryView` / `Diag.cj` 实际抛出，且不属于「M2/M3 增量」（设计把增量限定为 m3 的 JSON 段错误）
- **描述**：`kind` 是测试断言与宿主分支的稳定标识（§4.3.9 明写「测试按 kind 断言」）。清单少 4 项会让读者以为 `NotAssigned`/`TypeMismatch`/`SyntaxError`/`CodeGen` 是非法值，也会让「词法族逐 kind 一条用例」的覆盖要求漏掉 4 个分支
- **建议**：§4.3.9 补齐 4 个 kind 并各给一句触发条件；`CodeGen` 标明「内部不变量，不可由用户源码构造」

### [轻微][存量] 附录 B 把 `0xBE MAP_ITER_STEP` 放在「0xA0–0xAF」节，`0xB0–0xBF` 节又缺它

- **位置**：`f_jit/doc/design-m1.md:1368`（节标题「0xA0–0xAF 分配/变更区」）、`f_jit/doc/design-m1.md:1388`（`BE MAP_ITER_STEP` 行）、`f_jit/doc/design-m1.md:1390`（节标题「0xB0–0xBF …」但无 0xBE）；代码 `f_jit/src/bytecode/OpInfo.cj:331`（0xBE 归在「0xB8–0xBF」注释段）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「文档过期 / 结构错误」、§2「字面量复制导致漂移」
- **证据**：静态确定 —— 标题声明的区间与行内 opcode 不匹配；`0xBE` 在 B.11 中检索不到
- **描述**：这是 ISA 全表，读者按区间查 `0xBE`（Map for-in 的 STEP）会漏掉，而它恰好是 `for-in` 语义（迭代器推进/取键/取值/close）的关键指令；同时 `0xBE` 与 `0xAF` 的配对关系（BEGIN/STEP）被区间拆散
- **建议**：把 0xBE 行移到 B.11（`0xB0–0xBF`），或把 B.10 标题改成「0xA0–0xAF + 0xBE」并在 B.11 交叉引用

### [轻微][存量] `HW_CLOSE`（0x7B）在 B.7 未标 M1 `ERR_NOT_IMPL`，与 §4.3.7 校验⑧及汇编器实现相反

- **位置**：`f_jit/doc/design-m1.md:1325`（`7B HW_CLOSE`｜语义「关闭区块」、失败码「—」，无 M1 注记）、`f_jit/doc/design-m1.md:547`（校验⑧「`CALL_HOST`/`HW_OPEN`/`HW_CLOSE` M1 一律 `ERR_NOT_IMPL`」）；代码 `f_jit/src/compiler/Assembler.cj:185-186`（`HW_OPEN || HW_CLOSE` 恒拒）、`f_jit/src/backend/A64Lower.cj:388` / `X86Lower.cj:1056`（把 0x7B 降成 nop）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「文档内部不一致」、§3「开关打开后走进空分支」
- **证据**：静态确定 —— 汇编器对两条都拒绝，因此后端的 nop 分支在 M1 不可达；B.7 的 `HW_OPEN` 行写了 M1 注记（`1324`），`HW_CLOSE` 行漏写
- **描述**：附录 B 是「哪些指令能用」的判据；漏标会让人以为 `HW_CLOSE` 在 M1 可装载（而它实际连汇编都过不了）。同时后端/解释器为它保留的 no-op 分支是死分支，容易被误读成「M1 已支持关闭区块」
- **建议**：给 `HW_CLOSE` 补「M1 汇编期 `ERR_NOT_IMPL`」，与 B.7 的 `HW_OPEN` 行、§4.3.7 校验⑧保持一致；若后端分支只是为 M2 预留，加注释说明

### [轻微][存量] `CompiledSourceUnit.fingerprint: UInt64` 与 §3.3.8 的 FNV-1a-128 冲突，且该字段全仓无读取

- **位置**：`f_jit/doc/design-m1.md:563`（`fingerprint: UInt64`（源码指纹），并称「根包：`FbcReader.load(raw)` 加载校验 + 缓存键（§8.1）」）、`f_jit/doc/design-m1.md:414`（源码指纹 = **FNV-1a-128**）；代码 `f_jit/src/compiler/SourceCompiler.cj:55`（`public let fingerprint: UInt64`）、`:130-132`（`Fnv128.fnv1a(src)` 后 `h.left` 截断低 64 位）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §1「读了不用」、§2「同一事实两处定义漂移」、§13
- **证据**：静态确定 —— 128 位指纹无法装进 `UInt64`；实现显式截断，注释「缓存键只需稳定、不要求抗碰撞到 128 位」；`grep -rn "\.fingerprint"` 在 `CompiledSourceUnit` 上零读取（缓存键由 `CompilePipeline.cj:60` 重新对源码算 `fnv1a128`）
- **描述**：设计把该字段定为缓存键的来源，实现里它既不是 128 位、也没人读；真正的键在管线层重算。读者若按设计认为「去重靠这个字段」会低估碰撞面，也解释不了为什么 `SourceCompiler` 还要取一次 FNV-128（重复计算）
- **建议**：把字段改成 `UInt128` 并由管线直接使用（删掉重算），或删除该字段、§4.3.9 注明「指纹由 `CompilePipeline` 计算，`CompiledSourceUnit` 不携带」

### [轻微][存量] 「ctx / 转储是全过程仅有的两块 GC 管辖外内存」与 CodeBuffer / FnTable / ConstMirror 矛盾

- **位置**：`f_jit/doc/design-m1.md:689`（「ctx 与转储缓冲是全过程仅有的两块 GC 管辖外内存」）、`f_jit/doc/design-m1.md:689`（释放机制「只保留一种收尾机制」）；代码 `f_jit/src/backend/CodeBuffer.cj:53-64`（`mmap` 代码内存）、`f_jit/src/backend/NativeAssets.cj:71-83`（`FnTable` = `LibC.malloc`）、`:155`（`ConstMirror.build`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「文档内部矛盾」、§11「资源不对称」；本部分审查重点「句柄与资源生命周期」
- **证据**：静态确定 —— 三块资产都由 `JitExecutor` 持有、`release()` 释放（`JitExecutor.cj:34-37`、`:185`），既不在仓颉堆，也不经 `JitFunction` 的 `finally` 释放
- **描述**：这句话的本意应是「桥自己 `malloc/free` 的只有 ctx 与 dump」，但写成「全过程仅有两块」会让资源审计只盯这两块，漏掉代码内存、fnTable、常量镜像（三者恰是最容易泄漏的原生资产）。`f_jit` 已有 `NativeAssets.liveCount` 之类的计数设施，文档口径应与之一致
- **建议**：改成「桥以 `malloc/free` 直接管理的是 ctx 与转储缓冲；代码内存/入口表/常量镜像由 `JitExecutor` 管理（mmap/malloc），生命周期见 §6.3 / §8.7」

### [轻微][存量] 设计层面的失败缓存无淘汰（按源码无界），实现以 256 条上限兜底但文档未记载

- **位置**：`f_jit/doc/design-m1.md:914`（状态机 `Idle→Compiling→Ready/Failed`，未写 `Failed` 的清理/上限）；代码 `f_jit/src/CompileCache.cj:95`（`FAILURES_MAX = 256`）、`:98-107`（到上限整表清空）、`:167-174`（`remove` 才清理）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §5「无界容器 / 缓存键无界」、§13「文档缺关键限制」
- **证据**：静态确定 —— 设计只描述状态迁移，没有容量、TTL 或淘汰；实现承认「按源码指纹累积，长期运行会无限增长」并用 256 条上限兜底（`CompileFailureCache_test.cj:38-66` 断言 ≤256）
- **描述**：按设计实现会得到一个「持续喂坏源码就无界增长」的进程级表；虽然当前实现已加界，文档没写这条界，读者无法从设计得知「失败缓存是冷路径、会被整表清空」这一重要行为（也解释不了为什么注册表变更要 `invalidateFailures`）
- **建议**：§7.3.5 补「失败条目有界（当前 256，触顶整表清空）；注册/注销/类注册变更时整体失效」，并说明这不是 LRU 而是「冷路径可重编」的取舍

### [轻微][存量] 附录 E 第 58 条仍写「x86_64 整单元 lowering 未补齐、`BackendX86_64.compile` 保持降级解释器」，实现已接通

- **位置**：`f_jit/doc/design-m1.md:1680`（「仍待补齐：x86_64 的整单元 lowering（P5.8）。`BackendX86_64.compile` 保持『降级解释器』…」）；代码 `f_jit/src/backend/X86Compiler.cj:35-60`（真实 lowering：prologue + `X86Lower` + 收敛块）、`f_jit/src/backend/JitCompiler.cj:87`（`'x86_64' => X86Compiler.compileFunctionWith(...)`）、`f_jit/src/backend/BackendSelector.cj:89-101`（`BackendX86_64.compile` 逐函数调用 `X86Compiler`，失败才 `false`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「文档过期：写着『暂不支持』其实已支持」
- **证据**：静态确定 —— `BackendX86_64.compile` 不再是 stub；`JitExecutor.create` 在 x86_64 上直接走 `JitCompiler.compileUnitWith`（`JitExecutor.cj:77`）
- **描述**：读者会据此认为 x86_64 永远只能解释执行，从而误判性能与部署面（README 与测试都按「JIT 可用」写）；这条过期结论还留在「实施偏差与修正记录」里，看起来像最新状态
- **建议**：把该条改成「x86_64 单函数 lowering 已接通（`X86Compiler`），剩余风险是部分指令返回 `None` 导致整单元降级」；若仍有个别片段未实现，逐条列出指令名而不是整体判死

### [轻微][存量] `3e2` 的 Decimal scale 示例写错（-3 应为 -2）

- **位置**：`f_jit/doc/design-m1.md:1052`（附 A.1「`3e2` → scale=-3」）；代码 `f_jit/src/compiler/Lowerer.cj:3879`（`scale = 小数位数 − 指数`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「文档与实现不一致」、§11「与规格 / README 冲突」
- **证据**：静态确定 —— `3e2` 无小数位、指数 +2 ⇒ `0 − 2 = -2`；`1e-3` ⇒ `+3`。文档把 `3e2` 写成 -3 是符号/位数错位
- **描述**：这是 Decimal 字面量构造的数值口径示例，实现者按文档写会得到 `3×10^3 = 3000` 而不是 `300`，影响常量值、常量指纹与差分黄金值
- **建议**：改为「`3e2` → scale=-2、`1e-3` → scale=3」，并补 `1.5e-2` 把「小数位 + 指数」公式写全

### [轻微][存量] `Version.HDR_SIZE = 36` 缺「magic 之后」限定，与 40 B payload 冲突

- **位置**：`f_jit/doc/design-m1.md:279`（§2.3.11「新布局头长度（旧单元 32）」）、`f_jit/doc/design-m1.md:402`（§3.3.8「容器头（40 B payload 起点）」）、`f_jit/doc/design-m1.md:403`（字段偏移 0…36）；代码 `f_jit/src/base/Version.cj:96-99`、`f_jit/src/bytecode/FbcHeader.cj:79-81`（`payload = 4 + HDR_SIZE = 40`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「文档内部不一致」
- **证据**：静态确定 —— 实现明确 `hdrSize` 是「magic 之后的部分」；设计只写「新布局头长度 36」，与 §3.3.8 的 40 B 起点字面冲突
- **描述**：按 §2.3.11 字面理解「头长度 36」会与 §3.3.8 的 40 B 起点差 4 字节，`.fbc` 读写偏移容易错位
- **建议**：§2.3.11 补「= magic 之后的头长度；payload = 4 + 36 = 40」，旧布局写「4 + 32 = 36」

### [轻微][存量] helper 73–76 已登记，但 §5.3.4 / B.7 / C.4 三张编号表未回填

- **位置**：`f_jit/doc/design-m1.md:724-725`（§5.3.4「H01–H62 对应 1–62；63–68 保留；69–72 增量」）、`f_jit/doc/design-m1.md:1319`（B.7 `CALL_HELPER` 的 hid 范围「1–62、69–72」）、`f_jit/doc/design-m1.md:1575-1583`（C.4 路由表）、`f_jit/doc/design-m1.md:1623-1627`（附录 D 新增 73–76）；代码 `f_jit/src/runtime/HelperId.cj:115-118`（`DATETIME_NOW=73 / DATETIME_PARSE=74 / DATETIME_OF=75 / DURATION_PARSE=76`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2「同一张表散落多处导致行为漂移」、§13「文档过期」
- **证据**：静态确定 —— 正文三张表都停在 72，附录 D 才出现 73–76；`HelperId` 实际已登记到 84（78–84 为 M3 的 Any/JSON/`ipow`），`MAX_FIXED` 仍是 72（`HelperId.cj:125`），正文与代码的编号面不一致
- **描述**：同一事实维护四份（§5.3.4 族表、B.7 操作数说明、C.4 路由表、D 段增量）。读者按正文查 73–76 会得到「未分配」，按 `HelperId` 查又会发现 73–76 已用于 DateTime/Duration 构造；后续再加 helper 必然重复出错
- **建议**：数值只保留一处权威（`HelperId` + 一张表），其余章节改为引用；至少把 73–76 回填 §5.3.4 / B.7 / C.4，并注明 `MAX_FIXED` 随增量更新

## 优化可行性方案

本部分只有一份设计文档，没有可测量的堆内存 / CPU 改造对象，也没有改前基线；不提出优化方案（`0 / 0`）。文档层面的可维护性改进（消除第二份事实、把行号锚点改成符号锚点）已作为缺陷与建议计入发现，不重复计为优化方案。

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 同键编译等待用「忙等 + 指数退避」，多 waiter 时 CPU 空转可能成为编译期热点 | `f_jit/src/CompileCache.cj:128-151` | waiter 数量与 CPU 占用占比；等待期间的自耗时 | 4/8 线程同时编译同一份大源码，`cjprof record` 看 `awaitReady` 自耗时；记录 P50/P95 等待时长 |
| 2 | `Compiler.registerType` 在全局 `mtx` 内做反射扫描与 `diag` 回调，注册并发度可能被压到 1 | `f_jit/src/Compiler.cj:134-158` | 单类注册耗时、临界区占比、并发注册吞吐 | 100 个类 × 8 线程并发 `registerType`，分段计时锁内/锁外；对比把 `diag` 移出锁后的吞吐 |
| 3 | 失败缓存触顶「整表清空」会在坏源码密集场景造成重编抖动 | `f_jit/src/CompileCache.cj:95-107` | 失败率、清空频率、重编次数放大比 | 持续注入 300+ 种坏源码，统计 `failureCount` 曲线与 `pipelineRuns` 增量；对比 LRU/单条淘汰 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_jit/doc/design-m1.md` | .md | ✅ | 1680 行全文读完；与 `src/` 逐节对照：§2 契约类型、§3 字节码表、§4 前端、§5 运行时、§6 后端、§7 门面、§8 调用链、§9 决策、附录 A/B/C 与 E。发现 #1–#26；typecode 表（`TypeToken` 1–9、`LocalType` 0–12）与 `LocalType.isLegal(..., verMajor=1)` / `fromToken` 一致，typecode/helper 路由表（§C.4 的 H02/H04/H09/H11/H12/H13/H14/H15/H16/H17/H18/H30 等）逐个核对一致，ctx 偏移（0/8/16/24/32/40/48/56）与 `JitContext.cj:115-122` 一致，`Version`（1/14/36/FBC1）与 `FuncEntry.SIZE=26`、`SiteEntry.SIZE=12` 一致（`HDR_SIZE` 的语义限定见 #25） |

合计：`.cj` 0 个 / `.md` 1 个 / 共 1 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 12 | 文档承诺与实现不一致的契约类问题：#2 生命周期名、#3 分发入口、#4 `CallContext`、#6 桥内机制、#7 后端结构、#9 注销语义、#10 失败 kind、#11 卸载窗口、#13 编译期递归、#14 pin 身份、#15 容量配置并发、#16 卸载顺序矛盾。安全性方面核对了 §2.3.7 sink 异常、§5.3.1 非托管内存、§6.3.2 W^X/IBT 表述，未发现夸大；未发现注入/越权面 |
| §1 死代码 | 3 | 文档描述、生产中无消费者的 3 个非对外符号：`JitValue`（顶层 `protected`，只定义 + `Root.cj:21` 注释，#6）、`AdapterRegistry`（顶层 `protected`，仅测试引用，#6）、`CompiledSourceUnit.fingerprint`（`protected struct` 的 `public` 字段，全仓无读取，#20）。`SourceUnit` 虽然仓内只被测试引用，但它是**对外可达的 `public`**（`base` 包的 `public struct`），按硬原则一**不判死代码**，其问题只作为 #3 的契约缺口记录 |
| §2 重复逻辑 | 3 | ① 同一指纹口径在 §3.3.8（FNV-128 + 二次校验）与 §4.3.9（`UInt64`）两处定义且漂移（#20、#5）；② ISA 路由表在 §B.9/B.10 与 §C.4 各写一份，已出现 0xBE 归组不一致（#18）与 HW_CLOSE 注记缺失（#19）；③ helper 编号表在 §5.3.4 / B.7 / C.4 / 附录 D 四处维护，73–76 未回填（#26）。文档头部自承「同源摘录自规格」，属有意复制，但未建立同步机制 |
| §3 空实现 | 2 | 文档承诺、实现为空的机制：二次字节校验（`DedupGuard` 无调用者，#5）与诊断事件（`JitFallback`/`MmapFailed` 无发射点，#8）。`.md` 本身无空函数体 |
| §4 栈溢出 | 2 | ① `STACK_GUARD` 只护帧内操作数栈、错误码 15 无生产者，设计 A.7/C.4 的「进入/回退解释器写 15」安全论证不成立（#1/严重；递归深度本体与 part1 #5 同根因，合并时保留一条）；② 编译期递归下降没有嵌套上限（#13/一般） |
| §5 OOM | 1 | §7.3.5 的失败缓存无淘汰（#22/轻微）：按源码无界，实现以 256 条兜底但文档未记。句柄表/常量镜像/代码内存在设计里都是有界或与单元同生命周期，未发现第二处无界承诺 |
| §6.1 热点瓶颈 | 0 | 本部分无 profile / bench / 分段计时数据；3 条疑似热点已进「待验证假设」，不写成发现 |
| §6.2 大粒度锁 | 0 | 文档未把 `diag` 回调画成锁内路径；实现 `Compiler.registerType` 在 `mtx` 内调 `diag`（`Compiler.cj:138/153`），但已现场核对仓颉 `std.sync.Mutex` 为**可重入**锁（1.3.0 `sync_package_api`「提供可重入互斥锁…可再次获得该锁」），同线程回调不会自锁，缺跨线程阻塞证据，故不成立 |
| §6.3 并发串行 | 0 | 文档无 `spawn` 后立即 `get()`、批大小=1 或单消费者描述；同键等待是忙等退避而非串行提交，已进待验证假设 1 |
| §6.4 低效算法 | 0 | 附录 B/C 是 O(1) 分派表，无嵌套循环 / `contains` / `remove(at:0)` 类描述；`CompilePipeline` 的重复指纹计算已计入 #20，不重复 |
| §7 降堆内存方案 | 0 | 无堆占用数据（对象数/字节量/生命周期），按要求不提案；`DedupGuard`/`SourceUnit` 的删除属死代码清理，不是内存优化 |
| §8 降 CPU 方案 | 0 | 无改前基线；候选（失败缓存淘汰、注册锁外化）只进待验证假设 |
| §9 local mode 可行性 | 0 | design-m1 未涉及 local mode，也无峰值内存数据；不满足「改前/改后峰值对照」的前置条件 |
| §11 现有代码的 BUG（存量） | 5 | #10（同键失败丢失异常 kind）、#11（`compile` 返回 `Unloading` 单元）、#14（`pin` 身份契约与实现相反）、#15（容量配置的读写竞争）、#16（卸载顺序注释与状态机互斥）；均为读文档追到代码时确认的现有逻辑/契约问题，非纯措辞 |
| §12 并发安全与锁粒度 | 3 | #11：`CompileCache.ready` 与 `JitFunction.state` 属两个同步域，`lookup` 不检查状态即发布句柄（共享路径：cache ready 表 → 返回的 `JitFunction` → `enterUnit` 的 19）；#15：`initialCapacity`/`capacityLimit` 设计为无同步 `static var` 却允许运行中调整；#16：卸载释放的前置条件自相矛盾，照注释实现会提前释放代码内存。`CompileCache.finish` 的 H1 锁序与 `close` 的「单元锁 → 缓存锁」方向已核对，无 ABBA |
| §13 文档一致性 | 26 | 本部分主体结论：#1–#26 全部为文档与实现/文档内部的对照 |
| §14 功能完备性与 README 覆盖 | 4 | #3（分发入口未实现）、#5（二次校验未接线）、#8（诊断接线缺失）、#12（再导出清单未落地）。`SourceUnit` 同时是「public 但无消费路径」的索引缺口 |
| 文件覆盖（§13 等） | 1/1 | 本部分清单 1 个文件全部读完，无缺失 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 1 |
| 一般 | 15 |
| 轻微 | 10 |
| 优化方案（堆内存 / CPU） | 0 / 0 |

## 总评

`design-m1.md` 是一份「规格落地稿」，前半部分（§0 分层、§1 DAG、§2 契约类型、§3 格式、§5 ctx/句柄/helper、附录 A/B 的 ISA 表）与实现贴合度很高：ctx 偏移、`Version`、`FuncEntry/SiteEntry` 尺寸、附录 B 抽查的 opcode 类别与长度、helper 编号（含 H69–H72）逐项核对均一致，说明作者当时确实对着代码写过。问题集中在**模块演进后没有回头改设计**：`unload→close`、`compile(unit)`、`CallContext.args`、`invoke/tryInvoke/JitValue/AdapterRegistry`、`JitArtifacts/JitCompiler/BackendSelector` 这五组机制在 M1/M2 实施中被内联或替换，设计却仍按原结构描述；同时 §7.3.6 的再导出清单与 `Root.cj` 的实际导出面对不上，使「哪些声明算对外契约」失去唯一判据。这类漂移不是风格问题：它会让读者按设计去找不存在的 API、按错误的产物束核对资源释放、以为 `JitFallback` 会被记录而实际上永远不会。

按影响排序，建议优先处理五条：① #2/#3/#4/#9/#12 的公开面契约（照设计写会编译失败或行为不同）；② #1 的栈防护论证（设计声称的「进入守卫 + 回退解释器写 15」不存在，非尾递归仍是进程崩溃；与 part1 #5 一并处理）；③ #8 的诊断接线（T7 的可观测承诺目前不成立）；④ #5 的去重契约（D4 的绝对表述与实现不符，且缺少它自己要求的二次校验）；⑤ #10/#11/#14/#15/#16 五条存量并发/错误通道/句柄契约问题（同键失败 kind 漂移、`compile` 可能返回卸载中的单元、`pin` 身份不跨调用、容量配置竞争、卸载顺序自相矛盾）。其余 §B/§C 表格与清单类问题（#17–#26）成本低，适合与上述修复一起做一次「设计与实现对账」。

需要说明的口径：本文档开头明确「签名以草图给出（个别类型随后续设计微调）」，因此**仅名字/参数顺序/返回类型**的差异（如 `HandleTable.get<T>` → `getAny/getAs`、`Interp.run` 多一个 `args`、`CodeBuffer.write` 返回 `Bool`、`marshalArg` 参数顺序）未计入发现；计入的是**字段被删、机制被替换、语义/边界相反、内部自相矛盾**这几类会误导实现或使用的问题。若需要把「草图免责」收窄，建议在设计里给每个声明标注「已实现 / 已改名 / 已撤销」。

本部分没有运行期代码，也没有需要立即阻塞发布的实现缺陷（文档不参与构建）；但 #1 的栈防护论证若不修，会让实现者误以为递归已被 `STACK_GUARD` 保护，这是本部分唯一的严重项。存量 26 条（严重 1 / 一般 15 / 轻微 10），是否纳入修复待用户决定。

**范围外提示**（不计入本部分统计，留待对应 `.cj` 分部分确认）：① `DedupGuard`（`bytecode/Fingerprint.cj:119`）是 `public` 但仓内无引用（对外可达，不判死代码，属可见性/接线信息）；② `BaseVisibility_test.cj:20` 用 `import fountain::f_jit.base.*` 断言「根包再导出不缺项」，测试口径与注释不符；③ `HelperId.MAX_FIXED = 72`（`runtime/HelperId.cj:125`）与已登记的 73–84 矛盾且全仓零引用（part1 已提示）。
