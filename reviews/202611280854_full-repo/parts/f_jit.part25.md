# f_jit 模块审查报告（模块第 25/38 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_jit/`（本部分 18 个源文件：`src/backend/**` 的编译器/发射器/码内存/缓存键 + 3 个 `src/*_test.cj`）
- **基线**：工作区快照（master 与 sts/1.3.x 同一提交 `120fd2542`，`git diff` 为空）⇒ 全部问题来源记「存量」
- **审查重点**：动态调用/桥接正确性（typecode 分支表、helper 路由）、句柄与资源生命周期、并发安全、递归与栈溢出、死代码、重复逻辑
- **报告版本**：v1（本文件只是分部分报告，模块报告由主 Agent 合并）

## 发现

### 1. [严重][存量] A64 帧尺寸与操作数栈基址按 imm12 裸编码，超过 4095 被静默截断

- **位置**：`f_jit/src/backend/A64Compiler.cj:75`、`f_jit/src/backend/A64Compiler.cj:77`（发射侧 `f_jit/src/backend/A64Emitter.cj:318-324`）
- **来源**：存量（快照模式无基线可比；这两行与 `addOff` 的分块逻辑同批存在，未被 `git blame` 到任何本次改动）
- **判据**：review-checklist §11（边界越界 / 静默错误）+ §6.4（已知规模却用受限编码）
- **证据**：静态确定 —— `A64Emitter.subImm` / `addImm` 只把立即数写进 imm12：`UInt32(imm & 0xFFF) << 10`，既不分块也不报错；而同文件 `addOff`（`A64Emitter.cj:522-541`）对内存偏移明确做了「按 4095 分块累加」并注明「`add/sub` 的 imm12 只有 4095」。`A64Compiler` 对帧尺寸与 x20 基址用的正是未分块的 `subImm`
- **描述**：`frame = align16(40 + 8*(nLocals + maxStack + 1))`（`A64Compiler.cj:37-40`），`nLocals` / `maxStack` 都是 `UInt16` 且**全链路没有上限校验**（`FbcReader` 只校验类型表长度、`Assembler` 只校验槽索引 < nLocals，均不限制槽数；README 也未记载局部槽上限）。触发条件与后果：
  - `nLocals >= 507` ⇒ `40 + 8*nLocals >= 4096` ⇒ `e.subImm(20, 29, 4096)` 的低 12 位为 0，`x20 = x29`，操作数栈基址落在帧指针上；随后 `pushX`（`A64Lower.cj:135-138`）第一次压栈就写 `[x29-8]`，覆盖 `prologue` 保存的 x19（`A64Emitter.cj:270`），helper 返回后寄存器状态即被破坏
  - `nLocals + maxStack >= 506` ⇒ `frame >= 4096` ⇒ `e.subImm(31, 31, frame)` 截断，真实 `sp` 只下移 `frame & 0xFFF`（如 4112 → 16），局部槽 `[x29-40-8i]` 全部落在已分配帧之外，写到调用者栈帧里
  - 两条都不会降级解释器（`compileOnce` 照样返回 `Some`），属于静默内存破坏：轻则错值，重则 SIGSEGV
- **建议**：`compileOnce` 在算完 `frame` 后加显式拒绝路径 —— `if (frame > 4095 || 40 + 8*nLocals > 4095) { return None }`（退回解释器，与 `A64Lower` 其余「不支持即降级」一致）；或改用 `movImm64 + subReg`（`A64Emitter.cj:299-312`、`330-332`）构造任意 64 位帧调整，彻底去掉 imm12 约束

### 2. [一般][存量] 引擎选择链（`BackendSelector` / `Backend` / `Engine`）不在生产路径上，`JitFallback` 诊断永不触发

- **位置**：`f_jit/src/backend/BackendSelector.cj:40-74`（选择器）、`:89-104`（`BackendX86_64.compile`）、`:1843-1858`（`BackendAArch64.compile`）
- **来源**：存量（快照模式）
- **判据**：review-checklist §14（接线缺失）+ §13（契约与实现不符）+ §3（`entryThunk*` 恒 0 的占位实现）
- **证据**：静态确定 —— 全仓 `grep` 结果：`BackendSelector.select` 唯一调用点是 `BackendSelector_test.cj:77`；`Backend.compile` / `abiSummary` 在 `f_jit/src` 内**零调用**（只有 `Backend.cj:26/29` 的接口声明与两个实现体）；`prepareThunks` / `entryThunkBase` / `entryThunkFor` / `thunkBytes` 只被 `X86Thunk_test.cj` 引用。生产路径是 `CompilePipeline.cj:236-241` → `JitExecutor.create(unit, entryFn)` → `JitCompiler.compileUnitWith`（`JitCompiler.cj:86-89` 走 `Arch.current.toString()` 的 arch 分支），与 `BackendSelector` 完全并行
- **描述**：三处后果（同一根因：一套契约层没人用，另一套在生产里另写一遍）：
  1. **诊断承诺未兑现**：`f_jit/src/base/Engine.cj:26-27` 写「用户要感知降级只能经 diagnostics 的 `(Warn, JitFallback)` 事件」，`DiagCode.cj:23` 也把它定义为「非 Linux / 架构不支持」的唯一出口；但生产门禁在 `JitExecutor.cj:55-60` 直接 `return None`，**不发任何 diag**。全仓 `DiagCode.JitFallback` 的发射点只有 `BackendSelector.cj:61/71` 两处，而它们不会被调用 ⇒ 非 Linux 平台静默降级，`(Warn, JitFallback)` 永远不会出现
  2. **契约层与生产实现漂移**：`BackendAArch64.compile`（`:1843`）调的是 `A64Compiler.compileFunction`（constBase/fnTableBase 恒 0），任何含 `PUSH_KH` / `CALL_FUNC` 的单元都会 `None`；生产用的 `JitCompiler.compileUnitWith` 却能传常量镜像与 fnTable 基址。`BackendAArch64.entryThunkBase/For`（`:1860-1866`）恒返回 0，而接口注释（`Backend.cj:31-35`）承诺「入口 thunk 区基址 / 某函数的入口 thunk 地址」，没有说明 0 是「无 thunk」哨兵
  3. `CompileCacheKey`（`CompileCacheKey.cj:24`，doc 注释指向 §8.7 / S5.13 的编译缓存键）在 `f_jit/src` 内零引用；实际存在的是 `CompileCache.cj:30`，它以源码 FNV-1a-128 为键（`CompilePipeline.cj:48`），既不带 arch 也不带 cpuFeatures ⇒ 该类当前是对外可达但无消费方的 API，不是死代码（硬原则一），但设计文档 `doc/design-m1.md:203`「`BackendSelector.select` 由桥管线第 3 步调用」与实现不符
- **建议**：二选一并写清：① 让 `JitExecutor.create` 复用 `BackendSelector`（拿到 `(Engine, ?Backend)` 并把 `JitFallback` diag 透出到 `CompileOptions.diag`），`Backend.compile` 作为唯一编译入口；② 明确废弃 `Backend`/`BackendSelector`/`CompileCacheKey`，同步删掉 README:241-242、`design-m1.md:203/776-784` 的描述。无论哪条，都要修 `JitExecutor.create` 的静默降级（至少补一次 `Warn/JitFallback`）

### 3. [一般][存量] `fRoundOp` 的 round-half-even 收尾在 |小数部分| < 0.5 时会多加减 1

- **位置**：`f_jit/src/backend/BackendSelector.cj:1175-1183`（`fRoundOp` 的 `kind == 3` 分支）
- **来源**：存量（快照模式）
- **判据**：review-checklist §11（逻辑错误）+ §2（与同语义实现 `roundsd` 漂移）
- **证据**：静态确定 —— 按字节序列推演（`rax = trunc(x)`、`xmm1 = double(t)`、`xmm2 = x - t`）：
  ```
  test rax,1 ; jz .store        ; t 偶数 → 直接存 t（正确）
  xorpd xmm3,xmm3 ; ucomisd xmm2,xmm3 ; ja .plus ; jmp .minus
  ```
  即 t 为奇数时**无条件**按小数部分的符号做 ±1，缺少「|frac| < 0.5 应保持 t」这一判定。结果：`round(3.0) = 2.0`、`round(3.3) = 4.0`、`round(-3.3) = -4.0`；只有 t 为偶数的输入才碰巧正确
- **描述**：`fRoundOp(3)` 是 `emitFRound`（`:1232`）的实现，doc 注释自称「取整族基线序列（§12.4）」。当前**尚未接线**：生产 lowering 的 `0x4D` 走 `X86Lower.cj:960 → floatRoundChecked → floatRound`（SSE4.1 `roundsd`，`:534-539`），而 README:269 明确「缺 SSE4.1 时含取整指令的单元整体退解释器」。所以现在不影响运行结果，但这一族（`emitFTrunc/FFloor/FCeil/FRound` + `fRoundOp`，`:1100-1234`）只被 `X86Lower_test.cj:576-590` 的字节级断言引用 —— 一旦有人按注释把它当基线接上，就是静默算错
- **建议**：要么删除这一族（与 README:269 的「退解释器」决策保持一致），要么补上 `|frac| == 0.5` 判定（`ucomisd` 与 ±0.5 比较，非等值即 `.store`）后再接线，并补一条 `round(3.0)/(3.3)/(2.5)/(-2.5)` 的差分用例（对拍解释器）

### 4. [一般][存量] `CodeBuffer.flushCounter` 是无同步的静态可变计数，并发 `seal()` 会丢失更新

- **位置**：`f_jit/src/backend/CodeBuffer.cj:156`（自增）、`f_jit/src/backend/CodeBuffer.cj:173-180`（读/清零）
- **来源**：存量（快照模式）
- **判据**：review-checklist §12.1（共享可变状态无保护 / 检查-然后-写入）+ §11（并发正确性）
- **证据**：静态确定 —— `private static var flushCounter: Int64 = 0`，`flushICache()` 里 `CodeBuffer.flushCounter = CodeBuffer.flushCounter + 1` 是读-改-写，无锁无原子；`flushICache` 是 `public` 且由 `seal()`（`:131-146`）调用，而 `seal` 的并发调用是本模块明确支持的场景（`A64AuditIsolation_test.cj:22-28` 的注释就在讨论「并发编译」）
- **描述**：两个线程同时 `seal()` 两个不同 `CodeBuffer` 时，计数可能只 +1；`resetFlushCount()` 也会把另一线程刚累加的值清零，`CodeBuffer_test.sealFlushesICache`（`:74-82`）在测试并行跑时因此可能间歇失败。后果只落在诊断计数上（无业务状态、无内存安全），故定一般
- **建议**：改成 `AtomicInt64`（`fetchAdd(1)` / `store(0)` / `load()`），或把计数设为 `@When[test]` 专供测试；不要把可变的进程级计数留在生产类里

### 5. [一般][存量] `emitSetSite` 用 `C7 /0 imm32` 写 64 位 site，注释与编码自相矛盾

- **位置**：`f_jit/src/backend/BackendSelector.cj:1694-1702`
- **来源**：存量（快照模式）
- **判据**：review-checklist §11（语义与注释不符 / 截断）
- **证据**：静态确定（截断）—— `49 C7 4F 08 imm32` 是 `mov qword [r15+8], imm32`，立即数按 32 位符号扩展；`BackendX86_64.w32(out, i32bits(site))` 只写低 32 位。注释却写「site 是 Int64，不能只写低 32 位」
- **描述**：`site >= 2^31` 时实际写入 `site - 2^32`（负数），`ctx.site` 被写成非法偏移；`site` 在 `JitContext` 里是 Int64（`OFF_SITE`），字节码偏移与 site 表索引当前都远小于 2^31，所以是潜在问题而非现网故障（可达性待确认：需确认 site 是否会取 `Int64` 级的值）
- **建议**：改成 `movabs rcx, imm64; mov [r15+8], rcx`（4+11 字节），或把断言写进注释「site 由 siteTable 索引限定 < 2^31」，并在生成侧加钳制

### 6. [轻微][存量] 死代码：4 个函数 + 6 个条件码常量全仓零引用

- **位置**：`f_jit/src/backend/A64Emitter.cj:255-257`（`ret`）、`f_jit/src/backend/A64Emitter.cj:362-364`（`neg`）、`f_jit/src/backend/A64Lower.cj:68-71`（`bailLabel`）、`f_jit/src/backend/A64Lower.cj:121-123`（`u32`）、`f_jit/src/backend/A64Emitter.cj:645-658`（`A64Cond.HS/MI/PL/VC/HI/LS`）
- **来源**：存量（快照模式）
- **判据**：review-checklist §1（`private` 全仓搜、`internal` 本包及子包搜）
- **证据**：静态确定 —— 搜索范围与命中：
  - `\.ret()` 全仓只命中 `Assembler.ret` / `Builder.ret`（`src/compiler/Lowering*.cj`、`Assembler_test.cj`），无一处是 `A64Emitter.ret`
  - `\.neg(` 全仓 0 命中；`bailLabel` 仅在定义处 `A64Lower.cj:68` 命中；`A64Lower.u32` 0 命中（`u8/i8/u16/i32/i64` 均有调用）
  - `A64Cond.<cond>` 计数：EQ 13、NE 6、LO 2、VS 5、GE 5、LT 8、GT 5、LE 2；`HS/MI/PL/VC/HI/LS` 各 0
- **描述**：`A64Cond` 是 `internal class`，其 `static const` 对外不可达，未使用的 6 个条件码按硬原则二属死代码；不过「条件码枚举保持与 ISA 一一对应」也可能是有意为之（待确认）。`ret`/`neg` 是可被 `word(0xD65F03C0)` / `word(0xCB0003E0)` 直接替代的遗留原语
- **建议**：删掉 `ret`/`neg`/`bailLabel`/`u32`；`A64Cond` 若不打算补全为完整条件码表，就删掉未用项，否则在类注释里写明「完整枚举，非按需添加」

### 7. [轻微][存量] 重复逻辑 6 处：同一语义在一份文件里写了两三遍

- **位置与形态**：
  1. 错误收敛序列（`ldr err; cbz ok; dump; ret0; b epilogue; ok:`）三份：`A64Lower.cj:542-551`（`helperCall` variant 0）、`:563-570`（`helperCall0`）、`:574-583`（`checkErr`）
  2. 栈护栏序列（`movReg(11,29); subImm(11,11,frame); subReg(11,11,31); movImm64(12,need); cmpReg; bCond(LO,'deopt')`）两份：`A64Lower.cj:167-174`（0x07）、`:367-373`（0x74）
  3. 条件码取反表（14 case 的 `cond^1`）两份：`A64Emitter.cj:225-243`（`invert`）、`:410-429`（`cset` 内联 match）
  4. `emitDump` 序列（`subImm(4,29,40); ldr [x19+56]; ldr [x19]; fnId; nLocals; movImm64 dump; blr`）两份：`A64Compiler.cj:133-141`、`A64Lower.cj:79-87`
  5. x86 位运算三对完全同体：`emitBAnd/emitBOr/emitBXor`（`BackendSelector.cj:407-417`）与 `emitAndB/emitOrB/emitXorB`（`:1518-1528`）逐字节相同
  6. `bitBin(kind)`（`A64Lower.cj:821-823`）是 `boolBin` 的纯别名，`translate` 里 `0x5F-0x61`（bool）与 `0x62-0x64`（bit）因此走两条完全相同的路径
- **来源**：存量（快照模式）
- **判据**：review-checklist §2（换控制流 / 只改类型名 / 字面量复制）
- **证据**：静态确定 —— 上述各对逐行比对：指令序列与操作数完全相同，仅插入位置/函数名不同，无边界、错误文案或精度差异
- **描述**：重复本身不改变行为，但已有可见漂移：(1) 的三份里只有 `checkErr` 被 `callFunc`/`callClosure` 复用，(2) 的两份 `need` 取值不同（一处 `u16` 立即数、一处 `this.frame`），(6) 让「按位与/或/异或」与「布尔与/或/异或」在编码层面无法分别优化
- **建议**：把 (1) 抽成 `emitErrCheck()`（`helperCall`/`helperCall0` 直接调用 `checkErr`）；(2) 抽成 `emitStackGuard(need)`；(3) 让 `cset` 调 `invert`；(4) 让 `A64Compiler.emitDump` 调 `A64Lower.emitDump` 的公共静态版（或反过来下沉到 `A64Emitter`）；(5) 保留一对、另一对改为转调；(6) 删掉 `bitBin`，`0x62-0x64` 直接 `boolBin`

### 8. [轻微][存量] ctx 布局偏移以魔数 40/56/0 硬编码，与 `JitContext.OFF_*` 常量并存

- **位置**：`f_jit/src/backend/A64Compiler.cj:135-136`、`f_jit/src/backend/A64Lower.cj:81-82`（`56`/`0`）、`A64Lower.cj:637`、`A64Lower.cj:676`（`40`）
- **来源**：存量（快照模式）
- **判据**：review-checklist §2（字面量复制）+ §10（可维护性）
- **证据**：静态确定 —— `JitContext.cj:115-122` 已定义 `OFF_ERR_CODE=0 / OFF_SITE=8 / OFF_HW_BASE=16 / OFF_HW_CAP=24 / OFF_HW_TOP=32 / OFF_FN_ID=40 / OFF_FLAGS=48 / OFF_DBG_BASE=56`；同文件 `A64Lower.cj:375` 用的是具名常量 `JitContext.OFF_FLAGS`，其余 5 处仍是魔数
- **描述**：ctx 布局一旦调整（例如在 fnId 前插字段），只有 `OFF_FLAGS` 那处会跟着改，`dbgBase` 与 `errCode` 的读取会静默读错字段 —— 表现为 dump 内容错位而不是编译失败
- **建议**：5 处改用 `JitContext.OFF_DBG_BASE / OFF_ERR_CODE / OFF_FN_ID`；`A64Compiler.emitDump` 与 `A64Lower.emitDump` 合并时一并替换

### 9. [轻微][存量] `emitCallHelperNC` 用 `full.size - 10` 硬编码尾长，与 CHECK_ERR 字节序列隐式耦合

- **位置**：`f_jit/src/backend/BackendSelector.cj:1572-1575`（配合 `:1801-1806` `appendCheckErr`、`:1705-1707` `emitCheckErr`）
- **来源**：存量（快照模式）
- **判据**：review-checklist §2（字面量复制）+ §10（可维护性）
- **证据**：静态确定 —— `emitCallHelperNC` 返回 `full[0..(full.size - 10)]` 来「去掉尾随 CHECK_ERR」，10 是 `49 83 3F 00 0F 85 rel32` 的长度；两个 CHECK_ERR 发射点各写一遍同样的 10 字节字面量，无共享常量
- **描述**：任一侧字节顺序变化（例如把 `cmp [r15],0` 换成 `test`），切片长度就不再对齐，结果是**半条指令**被截断、机器码错位且测试仍只断言长度 10 的旧序列
- **建议**：抽 `const CHECK_ERR_LEN: Int64 = 10`（或 `emitCheckErr()` 直接返回该数组长度），`emitCallHelper` 单独提供「不带尾」变体而不是切片；`appendCheckErr` 复用 `emitCheckErr` 的字节数组

### 10. [轻微][存量] `strD`/`ldrD` 不做偏移校验也不走慢路径，与 `strOff`/`ldrOff` 不对称

- **位置**：`f_jit/src/backend/A64Emitter.cj:543-549`
- **来源**：存量（快照模式）
- **判据**：review-checklist §11（边界未处理）+ §10（API 对称性）
- **证据**：静态确定 —— `strOff`/`ldrOff` 有 `off % 8 == 0 && off <= 32760` 的 scaled-imm12 判定、`-256..255` 的 imm9 判定、以及 scratch 慢路径；`strD`/`ldrD` 直接 `UInt32(off / 8) << 10`，负偏移或非 8 倍数会得到错误 imm12（`off = -8` ⇒ `UInt32(-1) << 10` 污染整个高字段）。另外两者都不调 `noteMemBase`，G5 审计看不到浮点槽访问
- **描述**：当前调用点只有 `off = 0/8`（`A64Lower.cj:188-311`、`404`、`685`、`840-890`），所以未造成故障；一旦浮点局部槽偏移变大（`nLocals` 增大后的 `[x29-40-8i]` 走 `ldrD`），就会静默编码错
- **建议**：给 `strD`/`ldrD` 加与 `emitLdr` 同构的范围判定（含 scratch 慢路径）与 `noteMemBase`，或把它们改成 `strOff`/`ldrOff` 的浮点重载，明确注释「仅支持 8 字节对齐、scaled imm12 范围」，调用侧加断言

### 11. [轻微][存量] `finish()` 在范围校验失败后静默返回部分回填的字节

- **位置**：`f_jit/src/backend/A64Emitter.cj:166-171`（配合 `:131-163` `resolve`）
- **来源**：存量（快照模式）
- **判据**：review-checklist §3（`Option` 被静默丢弃）
- **证据**：静态确定 —— `resolve` 在 `checkRange` 中途 `return None` 时，**已经回填过的 reloc 保持已写状态**、未处理的保持 0；`finish()` 的 `case None => this.bytes()` 把这个 `None` 吞掉，返回一份「部分回填 + 越界截断」的码流
- **描述**：生产路径只用 `finishOrNull()`（`A64Compiler.cj:112`），所以现网不受影响；`finish()` 只被测试（`A64Emitter_test.cj:33` 等）当「宽松版」使用。但同名 API 一个返回校验结果、一个吞结果，后续若有人用 `finish()` 拿机器码，会拿到越界截断的分支（与 `optimize-emit-fixup` 想防的 `off & 0x1FF` 截断是同一类事故）
- **建议**：`finish()` 改成返回 `?Array<UInt8>`，或在文档里明确「仅供不校验的测试/诊断，越界分支会静默截断」并把名字改成 `finishUnchecked()`

### 12. [轻微][存量] `A64Lower.bail` 与 `A64Compiler.bindBail` 对 k>0 的转储行为不一致

- **位置**：`f_jit/src/backend/A64Lower.cj:61-66`（不转储）vs `f_jit/src/backend/A64Compiler.cj:121-130`（k>0 转储）
- **来源**：存量（快照模式）
- **判据**：review-checklist §11（语义与注释不符 / 同类路径行为不一致）
- **证据**：静态确定 —— `bindBail` 的注释（`:115-120`）声明「写错误槽 → （`k > 0` 时）单次转储 → 返回 0」，实现里 `if (k > 0) { emitDump(e, fn) }`；`A64Lower.bail(k)` 写同样的错误槽但**没有** dump，用于 `bail(18)`（HW_OPEN）、`bail(13)`（TO_I64）、`bail(7)`（CAST）、`bail(17)`、`bail(6)`、`bail(u8)`（ASSERT/THROW）
- **描述**：同一个错误码走「跳到 `bail1/2/3`」还是「内联 `bail(k)`」决定了失败帧是否进 `DbgDump` 报告 —— 例如 CAST 失败（7）不产生 dump，而 DIV_ZERO（1）产生。`DbgDump` 的「首个收敛点获胜」规则（`DbgDump.cj:33`）会让报告内容依赖 lowering 的实现选择，用户看到的诊断与被调指令无关（需确认这是有意为之：`DbgDump` 内部是否还有别的补偿规则）
- **建议**：`A64Lower.bail(k)` 在 `k > 0` 时也调 `emitDump()`（与 `bindBail` 对齐），或在两处注释里写明「内联 bail 不参与 dump」的理由

## 优化可行性方案

> 不是缺陷，是「还能更好」。三条都缺改前/改后对照数据，只作下一轮补数据的方向。

### [CPU] 标签表键从格式化字符串改成整数偏移

- **现状**：`A64Lower.lower` 对**每个字节码偏移**都执行 `this.e.bind('L${off}')`（`A64Lower.cj:94`），`bCond/cbz/cbnz/b` 的跳转目标也是 `'L${next + rel}'`（`:352-381`）；`A64Emitter.labels` 是 `HashMap<String, Int64>`（`A64Emitter.cj:54`）。单函数 2411 条指令 ⇒ 约 2400 次字符串插值 + 哈希（注释里已有「9432 B 机器码」的实测规模）
- **方案**：`labels` 改成 `HashMap<Int64, Int64>`，字节码偏移直接做键；`bail1..3/deopt/epilogue` 这类固定标签改用小的负整数或独立字段（`private var bailSlot: Int64`）；`bind/b/labelOffset` 增加 `Int64` 重载，`A64Compiler` 的 `e.bind('epilogue')` 换成枚举
- **预期**：消除每指令一次短字符串分配与一次字符串哈希；编译期分配量按「指令数」线性下降（数量级可估，收益比例待测）
- **代价**：`A64Lower` 全部 `'L${...}'` 拼接点要改；`A64Emitter` 的测试（`A64EmitterFixup_test.cj:44/50`、`A64EmitterSize_test.cj:39`）要用整数标签重写
- **验证**：`cjpm bench -O2` 编译同一批源码 N 轮取中位数；`cjprof record` 看 `String` 分配与 `bind` 自耗时占比
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `helperDispatch` 地址常驻寄存器，去掉每次 helper 调用的 4 条 movz/movk

- **现状**：`helperCall` 每次都 `movImm64(9, this.helperDispatch)`（`A64Lower.cj:530`），同一模式还出现在 `helperCall0`（`:561`）、`helperCallHidReg`（`:595`）、`callClosure`（`:655/665`）。`movImm64` 对 64 位地址是 1 条 `movz` + 最多 3 条 `movk`（`A64Emitter.cj:299-312`），而 `helperCall` 在 lowering 里出现频次与指令数同阶（0x90-0xBF 几乎每条都走 helper）
- **方案**：序言把 `HelperAddresses.dispatch()` 物化到 callee-saved 的 `x21`（`prologue` 增 1 条 `stur`、`epilogue` 增 1 条 `ldur`，与 x19/x20 同套路，`A64Emitter.cj:267-287`）；所有 `blr(9)` 改成 `blr(21)`
- **预期**：每处 helper 调用少 1-4 个字（地址低位为 0 时通常 2-3 字），机器码体积与发射指令数同步下降；对 9432 B 量级的函数是可观测的码体积收缩（具体比例待统计）
- **代价**：`x21` 进入保存集（帧布局注释要改）；若 helper 内部破坏 x21（ABI 上不应发生，但 `@C` 入口需核对）会引入极难查的错值
- **验证**：统计 `emit` 字数（编译同一单元前后对比 `art.code.size`），`cjpm bench` 看编译耗时与执行耗时是否同向；`A64Exec_test` 全量回归
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] 发射审计只记录非法基址

- **现状**：`A64Emitter.noteMemBase` 对**每次** `ldr/str` 都 `audit.add(reg)`（`A64Emitter.cj:462-464`），注释给出「598 次/编译」的实测频次；`audit` 是每次编译新建的 `ArrayList<Int64>`（`:460`），随函数规模扩容，结束后整体丢弃
- **方案**：把判定下推到发射点 —— `noteMemBase` 只在 `reg ∉ {19,20,29,31}` 时记录；`A64Compiler` 改成「快照非空即拒绝」（`auditAllows` 语义等价），或用一个 `Bool` + 首个非法基址。若仍需保留完整轨迹供诊断，用固定容量环形数组（容量 = 常量）替代 `ArrayList`
- **预期**：每次编译少 ~600 次 `add` 与一次容量翻倍拷贝；峰值只多一个固定小数组（对象数从 O(指令数) 降到 O(1)）
- **代价**：审计语义从「记录全部基址」变成「只记违规」，`A64AuditIsolation_test`/`EmitAudit_test` 里断言 `size == 1/2` 的用例要改；诊断能力下降（看不到合法路径）
- **验证**：`getAllocatedHeapSize()` 在「编译 1000 次」场景的前后对照 + RSS；`cjprof heap` 看 `ArrayList` 扩容占比
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 每指令一次 `'L${off}'` 插值是编译期 CPU/GC 的可见成本 | `A64Lower.cj:94`、`A64Emitter.cj:54/82-88` | `bind` 自耗时占比、每秒分配字节数 | `cjprof record` 编译同一 2411 条指令单元 100 次，取 self time；`cjprof heap` 看 `String` 分配 |
| 2 | `helperDispatch` 地址物化占机器码体积的可观比例 | `A64Lower.cj:530/561/595/655` | 每次编译的 `movz/movk` 条数与总字数比 | 在 `word()` 里按 opcode 分类计数，跑 10 个真实单元统计中位数 |
| 3 | `A64Emitter.audit` 的 `ArrayList` 扩容是编译期堆峰值的一部分 | `A64Emitter.cj:460-472` | 单次编译的峰值分配与 `audit` 占比 | 编译前后 `getAllocatedHeapSize()` 差值 + 关闭审计（改 `noteMemBase` 为 no-op）对照 |
| 4 | A64 `resolve` 的 `String` 标签查表在高分支密度单元上变成热点 | `A64Emitter.cj:131-163` | `resolve` 自耗时占比 | 对含大量 `if/while` 的单元跑 `cjprof`，与 `optimize-emit-fixup` 记录的 78-92% 对比 |
| 5 | `BackendX86_64.compile` 的逐字节 `out.add` + `toArray` 双拷贝（若该路径被接线） | `BackendSelector.cj:89-104` | 该路径启用后的编译耗时 | 接线后用 `cjpm bench` 对照 `JitCompiler.compileUnitWith` 的数组下标写入（`JitCompiler.cj:101-112`） |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_jit/src/TypeCodeCache_test.cj` | .cj | ✅ | 类型缓存护栏；3 个用例与 `Compiler`/`CompileCache` 契约一致，未见缺陷 |
| 2 | `f_jit/src/UnloadConcurrency_test.cj` | .cj | ✅ | `close(timeout)` 并发语义；`while (started.load() < 4) {}` 自旋无让出（测试内可接受，未计问题） |
| 3 | `f_jit/src/WindowPool_test.cj` | .cj | ✅ | 窗口复用护栏；`try/finally` 释放 ctx 正确 |
| 4 | `f_jit/src/backend/A64AuditIsolation_test.cj` | .cj | ✅ | 审计按实例隔离；用例本身无线程共享写入 |
| 5 | `f_jit/src/backend/A64Compiler.cj` | .cj | ✅ | 见发现 #1（frame/x20 imm12 截断）、#7（emitDump 重复）、#8（ctx 魔数）、#12（bail 转储不对称） |
| 6 | `f_jit/src/backend/A64Emitter.cj` | .cj | ✅ | 见发现 #1（subImm 不分块）、#6（死代码）、#7（invert 重复）、#10（strD/ldrD）、#11（finish 吞 None） |
| 7 | `f_jit/src/backend/A64EmitterFixup_test.cj` | .cj | ✅ | 回填/幂等护栏；`finishIsIdempotent` 依赖发现 #11 的宽松 `finish` |
| 8 | `f_jit/src/backend/A64EmitterSize_test.cj` | .cj | ✅ | 字节口径护栏，与实现一致 |
| 9 | `f_jit/src/backend/A64Emitter_test.cj` | .cj | ✅ | 编码期望字来自 `as`/`objdump`；`imm9OverflowUsesScratchRegister` 覆盖了「截断」类事故（但未覆盖 imm12 的帧调整，见 #1） |
| 10 | `f_jit/src/backend/A64Lower.cj` | .cj | ✅ | 300 个 opcode 分支逐个核对；见发现 #6、#7、#12 |
| 11 | `f_jit/src/backend/A64NotBEncoding_test.cj` | .cj | ✅ | 结构断言，手工装配最小单元；与 `eorImm1` 编码一致 |
| 12 | `f_jit/src/backend/Backend.cj` | .cj | ✅ | 契约声明；`compile/abiSummary` 全仓零调用（见 #2） |
| 13 | `f_jit/src/backend/BackendSelector.cj` | .cj | ✅ | 见发现 #2、#3、#5、#7、#9 |
| 14 | `f_jit/src/backend/BackendSelector_test.cj` | .cj | ✅ | 矩阵/降级用例；`currentPlatformSelectsExpected` 断言「本机 Linux/aarch64」，在 x86 宿主上会失败（平台耦合，未计入本部分缺陷） |
| 15 | `f_jit/src/backend/CodeBuffer.cj` | .cj | ✅ | 见发现 #4；`alloc(1<<62)` 的页对齐运算不溢出（2^62 已对齐），`free` 幂等、`seal` 幂等均核对 |
| 16 | `f_jit/src/backend/CodeBuffer_test.cj` | .cj | ✅ | W^X/越界/幂等覆盖完整；`sealFlushesICache` 受 #4 影响可能并行抖动 |
| 17 | `f_jit/src/backend/CompileCacheKey.cj` | .cj | ✅ | 三元组语义自洽；仓内零引用（对外可达，按硬原则一不计死代码，见 #2 第 3 点） |
| 18 | `f_jit/src/backend/CompileCacheKey_test.cj` | .cj | ✅ | 键等价/哈希/无路径耦合用例，与实现一致 |

合计：`.cj` 18 个 / `.md` 0 个 / 共 18 个，全部读完（本部分清单无 `.md`）。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 2 | 设计：两套并行的引擎选择/编译入口（#2）；可读性：`A64Compiler.cj:70` 语句与函数签名同行、`A64Lower.cj:232-235` 用 `;` 连接的单行 case。安全性：本部分不解析外部输入，唯一外部接口是 `mmap/mprotect/munmap`（`CodeBuffer.cj:185-194`），参数均经页对齐与 `size <= 0` 校验，未发现注入/越权面；未发现硬编码凭据 |
| §1 死代码 | 1 | 逐个 `private`/`internal` 符号全仓搜过：`A64Emitter.ret/neg`、`A64Lower.bailLabel/u32`、`A64Cond` 的 6 个条件码常量零引用（#6）。`public` 且对外可达的 `A64Compiler.compileFunction(Far)`、`CodeBuffer.flushCount/pageSize`、`CompileCacheKey` 按硬原则一不判；`BackendX86_64/AArch64` 的 `public` 成员因所属类型 `internal` 而不可达，其零引用事实并入 #2（同一根因：整层未接线），不重复计数 |
| §2 重复逻辑 | 1 | 已把本部分 40 余个函数的「输入-输出-副作用」压平两两比对，外加跨文件搜同语义序列：命中 6 组（#7）。`emitPushI8/emitPushI32`→`emitPushI64`、`emitEqH/emitNeH`→`emitCmpEq/Ne` 属有意转调（语义即同一 opcode），不计；`0x7D/0x7E` 两个 case 同体属 opcode 表驱动，不计 |
| §3 空实现 | 1 | `BackendAArch64.entryThunkBase/For` 恒返回 0（`BackendSelector.cj:1860-1866`），接口注释未定义 0 的语义（并入 #2）。`emitCheckErrNc()` 返回空数组、`emitBreakpoint()` 返回 nop 均有注释说明是发布版 no-op，不算问题 |
| §4 栈溢出 | 0 | 本部分无递归：`A64Compiler`/`A64Lower`/`A64Emitter` 全为 `while`/`for` 迭代，`translate` 是 300 分支 `match` 无自调用；`fRoundOp`/`emitDump` 等只做线性发射。递归风险在 `f_svg`/`f_xml` 一类模块 |
| §5 OOM | 0 | 输出的三个容器（`out`/`labels`/`relocs`）规模由 `fn.codeLen` 与指令数线性界定，无跨请求/全局无界容器；`CodeBuffer.alloc` 按编译产物大小分配且失败返回 `None`（`CodeBuffer.cj:53-65`）；`audit` 每次编译新建、结束即弃（其分配成本见优化方案 §堆内存） |
| §6.1 热点瓶颈 | 0 | 无可复核 profile：本部分只有代码注释里引用的历史测量（`translate` 1.4-1.65 ms、`finish` 占 78-92%、598 次审计/编译），无本轮同环境对照。相关猜测全部进「待验证假设」，不写成缺陷 |
| §6.2 大粒度锁 | 0 | 本部分无锁：`BackendSelector` 的审计表在 aarch64 侧用实例字段（`A64Emitter.cj:460`），x86 侧用 `ThreadLocal`（`BackendSelector.cj:258-268`），临界区为空 |
| §6.3 并发串行 | 0 | 本部分无 `spawn`、无线程池、无批处理；`A64AuditIsolation_test.cj:38-42` 的 `spawn` 是测试同步手段（`writer.get()` 只为观察顺序） |
| §6.4 低效算法 | 0 | 已核：`labels` 是哈希索引（避免旧线性扫的 O(重定位×标签)）、`out` 按字存（避免每字 4 次 add）、`resolve` 单遍回填；未发现嵌套循环、`contains` 热点、`remove(at:0)` 或循环内字符串拼接（`hex32/hexBytes` 是测试辅助） |
| §7 降堆内存方案 | 1 | 发射审计只记非法基址（见优化方案） |
| §8 降 CPU 方案 | 2 | 整数标签键、`helperDispatch` 常驻 x21（见优化方案） |
| §9 local mode 可行性 | 0 | 本部分的临时对象是 `ArrayList<UInt32>`/`HashMap`/短字符串，均为编译期一次性产物且会逃逸成返回值（`Array<UInt8>`）或留在发射器实例上，不满足「函数内创建、函数内销毁」；且缺改前/改后峰值数据，无法成立 |
| §11 现有代码的 BUG（存量） | 5 | #1（frame imm12 截断）、#2（诊断承诺未兑现）、#3（`fRoundOp` 取整逻辑）、#4（`flushCounter` 竞态）、#5（`emitSetSite` 截断）。其余读到的边界均已核对：`A64Emitter.addOff` 分块、`strOff/ldrOff` 的 imm9/imm12/scratch 三档、`resolve` 的 ±128MB/±1MB 校验、`intDiv` 的 `INT_MIN/-1`、`floatCmp` 的 NaN 语义、`DUP2/SWAP` 的字序与 x86 侧一致 |
| §12 并发安全与锁粒度 | 1 | 唯一共享可变状态是 `CodeBuffer.flushCounter`（#4）；`A64Emitter` 的审计表按实例隔离（注释与 `A64AuditIsolation_test` 一致），`BackendX86_64` 的审计用 `ThreadLocal`。`BackendX86_64.thunkBuf/thunkCount` 是实例字段、无并发约定，未计入 |
| §13 文档一致性（.md） | 0 | 本部分文件清单无 `.md`（README/doc 属其他部分）；文中引用 `README.md:269`、`doc/design-m1.md:203` 仅作 #2/#3 的承诺源 |
| §14 功能完备性与 README 覆盖 | 1 | `BackendSelector`/`Backend`/`CompileCacheKey` 未接线且 `JitFallback` 诊断不发出（#2）；README:241-242 仍把 `BackendX86_64/BackendAArch64` 列为后端实现 |
| 文件覆盖（§13 等） | 18/18 | 无遗漏；本部分清单不含 `.md` |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 1 |
| 一般 | 4 |
| 轻微 | 7 |
| 优化方案（堆内存 / CPU） | 1 / 2 |

## 总评

本部分（AArch64 发射器/降低/编排 + x86 模板库 + 码内存 + 缓存键）的编码层质量整体偏高：指令编码有 `as`/`objdump` 期望字护栏，字节口径与字存储的错位有专门用例，回填从线性扫改哈希索引并保留「首个绑定优先」的旧语义，G5 内存基址审计做了按实例隔离 —— 这些都是踩过坑之后的正确修法。

真正的阻塞项只有一个但很硬：`A64Compiler` 用 `subImm` 直接写帧尺寸与 `x20` 基址，而 `subImm` 只取 imm12 低 12 位、`nLocals/maxStack` 又全链路无上限。`nLocals >= 507` 的函数会静默错位并覆盖保存寄存器，且不降级解释器 —— 这是「看得见代码就能定」的内存破坏面，建议立刻加拒绝路径或改 `movImm64+subReg`。

其次值得排期的是结构性的一件：`BackendSelector`/`Backend`/`Engine`/`CompileCacheKey` 这一层契约没有任何生产消费方，生产走的是 `JitExecutor.create → JitCompiler.compileUnitWith` 的另一条 arch 分支；后果不是抽象的「分层不清」，而是 `base/Engine.cj:26-27` 承诺的 `(Warn, JitFallback)` 诊断在生产上永远不会出现，非 Linux 用户无法感知降级。`fRoundOp` 那一族 SSE2 取整模板同样是「写了、测了、没接」的第三份实现，且其中 round-half-even 的收尾逻辑本身是错的（`round(3.0)=2`），一旦有人按注释接线就会静默算错 —— 建议要么删、要么修好再接。

其余为轻微：4 个零引用原语与 6 个未用条件码、6 组同语义重复序列（错误收敛 3 份、栈护栏 2 份、取反表 2 份、`emitDump` 2 份、x86 位运算 3 对、`bitBin` 纯别名）、ctx 偏移魔数与 `JitContext.OFF_*` 并存、`emitCallHelperNC` 的 `size-10` 耦合、`strD/ldrD` 缺校验、`finish()` 吞 `None`、`bail` 与 `bindBail` 转储不对称。均不影响当前运行结果，可随后端接线一并清理。

存量缺陷共 12 条（含 5 条 §11），是否纳入修复待用户决定；本报告不改源码、未运行构建。
