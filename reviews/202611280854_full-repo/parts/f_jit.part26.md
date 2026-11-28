# f_jit 模块审查报告（第 26/38 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_jit/src/backend`、`f_jit/src/base`（本部分 20 个源文件；`files/f_jit.part26.txt` 全量）
- **基线**：工作区快照（master 与 sts/1.3.x 同一提交 `120fd2542`，`git diff` 为空）⇒ 全部问题来源为「存量」
- **审查重点**：动态调用/桥接正确性（typecode 分支表）、句柄与资源生命周期、并发安全、递归与栈溢出、死代码、重复逻辑
- **报告版本**：v1（分部分报告，供主 Agent 合并；不与 `docs/review/` 下的抽样版混用）

## 发现

### [严重][存量] x86 `NE_F`（0x59）NaN 语义与解释器相反：`NaN != x` 被判为 false

- **位置**：`f_jit/src/backend/X86Lower.cj:553`（`floatCmp` 的 `case 4u8` 分支）、调用点 `f_jit/src/backend/X86Lower.cj:970`（`case 0x59u8 => this.floatCmp(4u8)`）
- **来源**：存量（快照模式无基线；该函数由 `optimize-x86-cfg-depth` 系列提交引入，全仓无第二版）
- **判据**：review-checklist §11「契约与实现不符」+ 规范 I7「解释器语义是规范，JIT 是等价加速器」（`f_jit/doc/jit-bytecode-m1.md:31`）+ `:318`「`NE_F`：NaN ≠ 任意 → true」
- **证据**：静态确定 —— `floatCmp(4)` 发射 `0F 95 C0`（`setne al`）→ `0F 9B C2`（`setnp dl`）→ `20 D0`（`and al,dl`）。`ucomisd` 对无序操作数置 `ZF=PF=CF=1`，因此 `setne` 得 0，`and` 后仍为 0。而三处对照全部给出 1：
  1. `f_jit/src/runtime/Interp.cj:513-516`（0x59）`f.push(if (x != y) { 1 } else { 0 })`，注释「NaN ≠ 任意 ⇒ true」；
  2. `f_jit/src/backend/BackendSelector.cj:934` `emitCmpNeF()` → `fCmpOp(false, 4u8)`，`:905` 注释「无序语义：NE=true」，`cmpsd xmm0,xmm1,4`（NEQ_UQ）对 NaN 返回 1；
  3. `f_jit/src/backend/A64Lower.cj:884-895` 用 `fcmp + cset NE`，ARM64 `FCMP` 无序时 `Z=0`，`cset ne` 得 1。
- **描述**：生产路径 `JitCompiler.compileUnitWith`（`JitCompiler.cj:87`）在 x86_64 走 `X86Compiler` → `X86Lower`，即上表这段内联编码。任何 `if (nanVal != x)` 在 x86_64 上被编译成 false，与解释器/A64 结果相反（数据错误）；当前 CI 机器为 aarch64（`X86Frame_test.cj:24` 注释），字节级用例只断言 `emitCmpNeF`（未被生产路径调用的那份，见下一条），所以该分叉不会被现有测试发现。
- **建议**：把 `floatCmp` 的 NE 分支改成与 `fCmpOp` 同样的语义：`setne al; setp dl; or al,dl`（或直接复用 `BackendX86_64.fCmpOp` 的 `cmpsd imm8=4` 模板）。补一条 x86_64 差分用例（NaN != 1.0 应为 true），并放在真实执行路径而不是字节断言上。

### [一般][存量] 两套 x86 编码器并存：生产路径内联重写，单测只钉住未被调用的那一套（已发生漂移）

- **位置**：`f_jit/src/backend/X86Lower.cj:351-374`（`binOp`/`cmpOp`）、`:542-563`（`floatCmp`）、`:376-383`（`bail`）对照 `f_jit/src/backend/BackendSelector.cj:395`（`emitIAdd`）、`:930-938`（`emitCmpEqF`/`emitCmpNeF`）、`:1710`（`emitBail`）；断言侧 `f_jit/src/backend/X86Lower_test.cj:78`、`:236-237`
- **来源**：存量
- **判据**：review-checklist §2「表现形式不同的重复逻辑：只改类型名 / 近似重复，其中一块少了边界判断」+ §14.1「接线缺失」
- **证据**：静态确定 —— `BackendX86_64` 共 141 个 `internal static func emit*`，被非测试代码引用的只有 11 个（`emitPrologue`/`emitEpilogue`/`emitCmpI`/`emitIPopcnt`/`emitJz`/`emitJbe`/`emitLoopBackGuardPrefix`/`emitCtxFlagsToRax`/`emitDeadlineMaskToRdx`/`emitTestRaxRdx` 等），其余约 130 个只被 `X86Lower_test.cj` 引用；`X86Lower.translate` 对同一批指令（IADD/ISUB/IMUL/IDIV/IMOD/FADD…FROUND/CMPS/CMP_NE_F/CAST/TO_I64…）逐条内联重编码。
- **描述**：两套实现已经不同步，且差异不是等价改写：
  1. `emitIAdd` 用 `jo <bail:3>`（`0F 80`），`X86Lower.binOp` 用 `jno ok; bail(3)`（`0F 81`）——语义等价、字节不同；
  2. `floatCmp(NE)` 与 `emitCmpNeF` 语义不等价（见上一条），说明"测试断言的那份"和"实际跑的那份"已经分叉；
  3. `X86Lower_test.cj` 23 个字节级用例断言的都是 `BackendX86_64.emit*`，生产编码器 `X86Lower.translate` 只有 `f_jit/src/compiler/X86Compile_test.cj` 的少数端到端用例覆盖。
- **建议**：二选一并写进注释——(a) `X86Lower` 改为调用 `BackendX86_64.emit*`（模板方法保持无分配需先解决 `Array<UInt8>` 返回值分配），或 (b) 删除仅测试使用的 `emit*` 集合，把字节断言改为对 `X86Lower` 产物的断言。无论哪种，NE_F 的差异必须由真实执行用例兜住。

### [一般][存量] `JitExecutor.invokeOff` 对 `LibC.malloc` 返回值未判空，内存不足时空指针写入

- **位置**：`f_jit/src/backend/JitExecutor.cj:157`（`let raw = LibC.malloc<Int64>(count: n)`）→ `:160`（`unsafe { raw.write(i, cells[n - 1 - i]) }`）
- **来源**：存量
- **判据**：review-checklist §11「空值 / 资源」「崩溃」+ 类注释 `JitExecutor.cj:30`「任何一步失败都返回 `None`，调用方静默退回解释器」
- **证据**：静态确定 —— 同文件 `FnTable.alloc`（`NativeAssets.cj:76`）与 `ConstMirror.build`（`NativeAssets.cj:160`）都用 `p.isNull()` 做了检查并降级，唯独热路径这次 `malloc` 直接解引用。
- **描述**：`n = cells.size > 0` 且 `malloc` 返回空指针时，`raw.write(...)` 立即段错误（不是可捕获异常），进程崩溃；这与模块"分配失败即退回解释器"的整体约定不一致。触发条件是宿主内存压力（大实参个数或 OOM 边缘），概率低但后果是崩溃而非降级。
- **建议**：`if (raw.isNull()) { return 0 }` 并置 `ctx.errCode`（或抛出桥侧约定的资源错误），由桥决定重放/报错；更彻底的做法见「优化可行性方案 · CPU-2」（去掉每次调用的 malloc）。

### [一般][存量] `DEC_TO_I64`（0x9D）的错误收敛路径 x86 与 A64 不一致（一边转储、一边不转储）

- **位置**：`f_jit/src/backend/X86Lower.cj:1143-1160`（mode≠1 走 `helper(30,1,0)` ⇒ `CHECK_ERR` ⇒ `checkfail` 转储）对照 `f_jit/src/backend/A64Lower.cj:458-476`（恒 `helperCall(30,1,1)`，失败直接 `mov x0,0; b epilogue`，不转储）
- **来源**：存量
- **判据**：规范 I7（`jit-bytecode-m1.md:31`：结果、错误码、site 与**错误报告文本**必须逐位一致）+ review-checklist §2「近似重复：一块少了边界判断」
- **证据**：静态确定（两侧发射路径可逐行对照）；转储是否真的产生文本取决于 `ctx.dbgBase≠0`，该条件属待确认项。
- **描述**：mode=0（普通 DEC_TO_I64）且 helper 写错误码时，x86 经 `helper` variant 0 → `cmp [r15],0; jne checkfail` → `jit_dump` → 返回 0；A64 走 variant 1（NC）后手工判定，只要 `errCode != 0` 就 `mov x0,0; b epilogue`，不调用 `emitDump`。mode=1 且 `errCode∉{0,9}` 时同样是一边 `checkfail`、一边裸返回。桥拿到的错误码相同，但源位置 + 变量清单（§9.16 报告面）只有 x86 有。
- **建议**：A64 侧 0x9D 的失败分支改为跳 `checkfail` 等价块（写槽后先 `emitDump` 再返回 0），与 x86/`CHECK_ERR` 的统一收敛路径对齐；若确认 mode 0 不该转储，则反过来在文档与 x86 侧同步。

### [一般][存量] GAP-05 字段签名四元组全仓无消费点，与「CALL_HOST 走精确签名」的承诺不符

- **位置**：`f_jit/src/base/ClassRegistration.cj:55-71`（`sigParams`/`sigParamNames`/`sigRet`/`sigRetName` 字段与注释）、`:97-99`（`hasSignature`）
- **来源**：存量
- **判据**：review-checklist §14.1「承诺了但没实现 / 接线缺失」；功能缺失双证要求
- **证据**：静态确定 —— 承诺源 `ClassRegistration.cj:56-62`「手工注册可显式给出，`CALL_HOST` 因此能带 `sigId` 走精确签名」；缺失证据：全仓（排除 `.worktrees`）`grep -E "sigParams|sigParamNames|sigRetName|hasSignature"` 除定义文件与 `ClassRegistration_test.cj` 外**零命中**，`CALL_HOST`（`f_jit/src/compiler/Ops.cj`，0x79 `u16 fid, u8 argc`）编码里也没有 `sigId` 字段。
- **描述**：注册面允许填一套函数签名并通过构造期校验（长度不一致即抛 `CALL_CONTRACT`），但没有任何读取方：编译期 `LowererM2` 不读，运行期 `CALL_HOST` 降低（`X86Lower.cj:1054` / `A64Lower.cj:386` 的 `helper(63, argc+1, 0)`）也不读。使用者按注释填了签名不会产生任何效果，属"静默无效的公开契约"。
- **建议**：要么把签名接进 `CALL_HOST` 的解析/分派（需要 opcode 或旁路表承载 `sigId`，属格式变更），要么在字段注释里明确标注「M2 预留、当前无消费点」，并考虑不再对它做构造期强校验以免误导；`hasSignature` 是仅测试使用的公开方法，见「可见性建议」。

## 优化可行性方案

> 全部无改前/改后基线，故只作为方案，不进修复清单。

### [CPU] 消除每个 helper 调用点的第二份 `CHECK_ERR`

- **现状**：`X86Lower.helper` 的 variant 0 在调用后内联发射 `cmp qword [r15],0; jne checkfail`（`X86Lower.cj:432-434`，7 字节 + 一次 errCode 读），而字节码生成器**保证**每条 `CALL_HELPER`/`CALL_HELPER_V` 后面紧跟一条 `CHECK_ERR` 指令（`f_jit/src/compiler/BytecodeBuilder.cj:34-35,434`，并受 `f_jit/src/compiler/Assembler.cj:193-197` 校验）。因此同一检查在每个 helper 调用点执行两遍。A64 侧同构（`A64Lower.cj:542-551`）。
- **方案**：helper 降低只保留结果写回与深度记账，检查交给紧随其后的 0x04 指令；或反之让 0x04 在 lowering 层识别前一条是 CALL_HELPER 时合并。需保留 `_NC`（0x76）不检查的语义。
- **预期**：每个 helper 调用点少约 10 字节机器码、少一次 `[r15]` 读 + 比较 + 条件跳转；`LEN`/`TO_STR` 这类每迭代多次调用的热点收益最大。具体百分比需实测。
- **代价**：对手写/`asm-inline` 且未经 Assembler 校验的字节流失去兜底检查（可用编译期断言恢复）；改动集中在一个函数。
- **验证**：`cjpm bench -O2` 同输入对照（解释器 vs JIT 的 helper 密集用例，如字符串插值/正则循环），并用 `cjprof` 看 `jit_dispatch` 调用次数是否不变、机器码体积统计。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `JitExecutor.invokeOff` 每次调用 `malloc`/`free` 一次实参数组

- **现状**：`JitExecutor.cj:153-177` 每次 `invoke`/`invokeFn` 都 `LibC.malloc(n*8)`、倒序拷贝、调用、`finally` 里 `free`；`JitFunction.call` 的每次调用都会走这里（`f_jit/src/CompilePipeline.cj:243-250` 的 `body` 闭包）。
- **方案**：线程私有可复用缓冲（与 `MachineEnv` 的 TLS 同寿命）按需增长到 `max(n)`，或在上限内用 `alloca` 等价的栈缓冲；超过上限再退回 `malloc`。注意保留「最深实参在高地址」的倒序布局与 `finally` 恢复语义。
- **预期**：每次调用省 1 次 `malloc` + 1 次 `free`（glibc 快路径约数十纳秒），减少堆碎片与分配计数；对短小函数（JIT 的主要目标）占比可能可观。
- **代价**：新增一块按线程常驻的缓冲（峰值 = 该线程见过的最大实参数 × 8B）；TLS 需要在调用结束时复位以避免长生命周期线程持有大缓冲。
- **验证**：`cjpm bench -O2`（同输入、同并发）测 `call<T>` 吞吐中位数与 P99；`cjprof heap` 看分配次数下降；RSS 对照确认常驻缓冲不成为新峰值。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] 编译期同一份机器码峰值存在三份副本

- **现状**：`JitCompiler.compileUnitWith`（`JitCompiler.cj:72-113`）先按函数收集 `bodies`（第一份），再汇总到 `out`（第二份），`JitExecutor.create` 再 `CodeBuffer.alloc(art.code.size+16)` 并把 `art.code` 拷进去（第三份）；`JitArtifacts` 在 `create` 返回后即被丢弃。`X86Compiler.compileFunctionWith` 另外用 `ArrayList<UInt8>` 逐字节 `add` 两次 `toArray()`（`X86Compiler.cj:63-70`），与 `JitCompiler` 已做的「两遍写、避免两倍搬运」优化口径不一致（`JitCompiler.cj:74-76` 注释）。
- **方案**：让 `compileUnitWith` 接受一个目标缓冲/回调（先算总长 → `CodeBuffer.alloc` → 直接写入），省掉 `bodies` 与 `out` 两份；`X86Compiler` 预先 `ArrayList<UInt8>(pre.size + body.size)` 或用数组直写。
- **预期**：编译峰值从约 3× 机器码降到约 1×（单元机器码 10 KB 量级时省 20 KB/次）；`JitArtifacts.code` 的生命周期缩短到 `create` 内部。收益与单元规模线性相关，需实测。
- **代价**：接口形状变化（`JitArtifacts` 仍是差分层 `RealRunners` 的公共产物），需要保留旧入口或同步 3 处调用点。
- **验证**：编译 1000 个中等单元，采 `getAllocatedHeapSize()` 峰值与 RSS；对照 `JitArtifacts` 是否仍被差分层引用（`f_jit/src/test/diff/RealRunners.cj:90,175,259`）。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `X86Lower.lower` 的「探针遍 + CFG 数据流 + 发射遍」使单函数编译成本约为 A64 的 2–3 倍（每指令一次 `translate` + 一次 `HashMap` 读写 + 一次 `InsnDecoder.decode` 分配） | `X86Lower.cj:105-155`、`X86Depth.cj:91` | 编译期自耗时占比、单函数耗时分布 | `cjprof record` 跑「编译 10k 次同一单元」（`CompilePipeline` warm cache 关掉），看 `lower`/`analyze`/`decode` 的 self time；与 `A64Compiler.compileFunctionWith` 同输入对照 |
| 2 | `invokeOff` 的 malloc/free 在短函数调用中占端到端 10% 以上 | `JitExecutor.cj:153-177` | 每次调用耗时分解 | 分段计时（进入 `invokeOff` 前后 / malloc 前后）跑 1e7 次 `call<Int64>([x])`，取中位数；或 `cjprof` 看 `malloc`/`free` 符号占比 |
| 3 | helper 调用点的双 `CHECK_ERR` 使 helper 密集函数的机器码体积增加 5–10%，并对 I-Cache 有可测影响 | `X86Lower.cj:432-434` | 机器码体积统计 + 吞吐对照 | 统计 `LEN`/`TO_STR`/`STR_CAT` 密集单元在改前/改后的 `art.code.size`，再跑 `cjpm bench -O2` 对照中位数 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_jit/src/backend/EmitAudit_test.cj` | .cj | ✅ | 与 `X86Lower` 的审计采集对照，见发现 §11 第 9 条 |
| 2 | `f_jit/src/backend/JitCompiler.cj` | .cj | ✅ | 三份码流副本，见优化方案 |
| 3 | `f_jit/src/backend/JitExecutor.cj` | .cj | ✅ | 资源释放路径对称；`malloc` 未判空（发现 3） |
| 4 | `f_jit/src/backend/NativeAssets.cj` | .cj | ✅ | 原子计数、幂等释放，未见泄漏/重复释放 |
| 5 | `f_jit/src/backend/NativeAssetsConcurrency_test.cj` | .cj | ✅ | 全局计数复位与 `NativeAssets_test` 互斥性存疑（发现 14） |
| 6 | `f_jit/src/backend/NativeAssets_test.cj` | .cj | ✅ | 同上 |
| 7 | `f_jit/src/backend/X86AuditIsolation_test.cj` | .cj | ✅ | 线程隔离用例成立 |
| 8 | `f_jit/src/backend/X86Compiler.cj` | .cj | ✅ | 收敛块字节内联（与 `X86Lower.leaR8Rbp` 重复，发现 10） |
| 9 | `f_jit/src/backend/X86Depth.cj` | .cj | ✅ | CFG 深度分析；`decode` 抛异常路径（发现 8） |
| 10 | `f_jit/src/backend/X86Depth_test.cj` | .cj | ✅ | 5 个用例覆盖直链/汇合/越界，未覆盖 `LOOP_BACK` 与「跳到函数尾」 |
| 11 | `f_jit/src/backend/X86Frame_test.cj` | .cj | ✅ | 帧序字节冻结；公式与 `frameSize` 一致 |
| 12 | `f_jit/src/backend/X86Lower.cj` | .cj | ✅ | 主要发现集中处（发现 1/2/5/6/7/8/9/10） |
| 13 | `f_jit/src/backend/X86Lower_test.cj` | .cj | ✅ | 断言对象是未被生产调用的 `emit*`（发现 2） |
| 14 | `f_jit/src/backend/X86Thunk_test.cj` | .cj | ✅ | 16B thunk 槽与远跳编码断言 |
| 15 | `f_jit/src/base/Base.cj` | .cj | ✅ | 仅一条注释、无声明（发现 12） |
| 16 | `f_jit/src/base/CallContext.cj` | .cj | ✅ | KDoc 仍列已删的 `args`（发现 11） |
| 17 | `f_jit/src/base/CallContext_test.cj` | .cj | ✅ | 头注释与用例不符（发现 11） |
| 18 | `f_jit/src/base/ClassRegistration.cj` | .cj | ✅ | 签名四元组无消费点（发现 5） |
| 19 | `f_jit/src/base/ClassRegistration_test.cj` | .cj | ✅ | 快照语义、类型码合法集用例与实现一致 |
| 20 | `f_jit/src/base/DiagCode.cj` | .cj | ✅ | `==` 6×6 嵌套 match（发现 13） |

合计：`.cj` 20 个 / `.md` 0 个 / 共 20 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 4 | 正确性：NE_F NaN、invokeOff 空指针；设计：双编码器；可读性：DiagCode/注释漂移。语言特性已核对 `struct` 值语义、尾表达式返回、`AtomicInt64`、`Equatable` 语义；无外部输入、无 SQL/注入面 |
| §1 死代码 | 1 | 逐个 `private` 符号在文件内计次：`movqRaxXmm`、`leaR8Rbp` 仅定义处命中（各 1 次）⇒ 死代码。`internal`/`internal class` 成员（`NativeAssets.onAlloc/onFree`、`X86Depth.*`、`JitArtifacts.*`）均有调用者；`public` 顶层可达者（`FnTable.size`、`ConstMirror.size`、`JitArtifacts.codeOf`、`NativeAssets.liveCount/resetCounters`、`PublicField.hasSignature`）按硬原则一**不判死代码**，只记「仓内仅测试使用」并入可见性建议 |
| §2 重复逻辑 | 3 | 已把 `X86Lower` 30 个函数体压成「输入→输出→副作用」两两比对：命中 (a) `X86Lower` 内联编码 vs `BackendX86_64.emit*`（跨文件、141 vs 11 引用）；(b) `helper`/`helperReg`/`callClosure`/`callFunc` 四处重复「设 rdi/rsi/rdx/rcx/rax + 对齐 + call」模板（差异仅在 checkErr 与深度记账）；(c) `bail` 与 `BackendX86_64.emitBail` 同一收敛序列两份。测试里的 `hex`/`nib`（`X86Frame_test.cj:71-102` 与 `X86Lower_test.cj:597-624` 逐字相同）按清单「测试准备代码」误报边界**不计入** |
| §3 空实现 | 1 | 无空函数体、无 `TODO/FIXME`、无 `catch {}`；`Base.cj` 整文件只有注释、无任何声明（骨架残留）。`0x02/0x06/0x7B` 的 `()` 与解释器 `Interp.cj:211-212` 的 no-op 一致，不是空实现 |
| §4 栈溢出 | 0 | 本部分无递归函数：`X86Lower.translate` 是单层 `match`，`X86Depth.analyze` 用扁平工作数组迭代（`work` 数组模拟栈），`JitCompiler`/`JitExecutor` 全是循环。深度上界由 `codeLen` 与 CFG 边数决定，无自引用结构 |
| §5 OOM | 0 | 分配量都由单元规模界定：`Array<UInt8>(total)`（机器码总长）、`Array<Int64>(consts.size)`、`FnTable.alloc(dir.size)`。无按不可信长度预分配、无无界容器。实参缓冲虽有 malloc 未判空（见发现 3），但容量由调用实参个数决定，不构成 OOM 面 |
| §6.1 热点瓶颈 | 0 | 未提供本部分的 profile/bench 数据（`scope.md` 只给 `docs/LocalMode*.md`），编译期与调用期热点均未成立，已写入「待验证假设」1–3 |
| §6.2 大粒度锁 | 0 | 本部分无锁：`X86Lower` 每次编译新建实例（线程封闭），`NativeAssets` 用 `AtomicInt64`，审计表是线程本地（`X86AuditIsolation_test` 锁定） |
| §6.3 并发串行 | 0 | 无 `spawn`（`NativeAssetsConcurrency_test` 的 4 线程是测试自身）；无「提交后立即 get」形态 |
| §6.4 低效算法 | 0 | `JitArtifacts.entry` 线性扫描 + `create` 逐函数查找是 O(n²)，但 n = 单元函数数、仅编译期一次，无测量数据，故不列为缺陷（并入「优化方案 · 堆内存」的编译期开销讨论） |
| §7 降堆内存方案 | 1 | 编译期三份码流副本（见优化方案 3），`无基线（待验证）` |
| §8 降 CPU 方案 | 2 | 双 `CHECK_ERR`、每次 invoke 的 malloc/free（均 `无基线`） |
| §9 local mode 可行性 | 0 | 候选只有 `X86Lower.add([...])` 的数组字面量（编译期、一次性、非峰值驱动），改用 `put` 直写即可，收益无法用峰值内存证明；且引入实验特性会锁 SDK 版本，判定不适用 |
| §11 现有代码的 BUG（存量） | 14 | 本轮读到的边界/空值/资源/契约项逐条核对：`FnTable.set/entry/at` 的越界与已释放分支、`create` 五条失败路径的释放对称性、`finish()` 缺标签返回 None、`invokeFn` 的 `off<0` 判据均已核对正确；命中项见上（1 严重 + 4 一般 + 9 轻微） |
| §12 并发安全与锁粒度 | 0 | 共享点逐一列举：`NativeAssets.allocs/frees`（原子）、`MachineEnv.fnTableBase`（`RuntimeEnv.current()` 线程私有，`RuntimeEnv.cj:104-126`）、x86 审计表（线程本地）。`JitExecutor.release()` 的 `released` 是非原子布尔，但 `JitFunction.unload` 契约要求排空活跃调用后才释放，未发现第二条共享路径，故不判不安全；`invoke` 路径只读实例字段 |
| §14 功能完备性与 README 覆盖 | 1 | 本部分不含 `.md`，无 README 面；唯一「承诺 vs 实现」缺口是 GAP-05 字段签名无消费点（发现 5） |
| 文件覆盖（§13 等） | 20/20 | 无 `.md` 文件；20 个 `.cj` 全部读完，无抽样 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 1 |
| 一般 | 4 |
| 轻微 | 9 |
| 优化方案（堆内存 / CPU） | 1 / 2 |

## 总评

这一部分的核心风险是**x86_64 后端的正确性没有被真实执行兜住**：生产 lowering 把指令编码内联重写了一遍，而 23 个字节级用例断言的却是另一套（未参与生产的）`BackendX86_64.emit*` 模板，结果 `NE_F` 的 NaN 语义已经与解释器/A64 相反却无人发现——这是本轮唯一的严重项，且只在 x86_64 Linux 上暴露（当前 CI 为 aarch64，属"发布即带病"的风险面）。同一根因还派生出 0x9D 错误收敛路径的跨引擎报告差异。

资源与并发面整体是健康的：`JitExecutor.create` 五条失败路径都按「码内存最后释放」的顺序对称回收，`NativeAssets` 的计数改成原子，`fnTableBase` 走线程私有 TLS，审计表做了线程隔离，`X86Depth` 用迭代而非递归、单函数深度上界明确。可以排期的项是 `invokeOff` 的 malloc 未判空与两处编译期重复（双 `CHECK_ERR`、三份码流副本），都属于"改动小、可验证"。

存量 14 条（含 1 严重、4 一般、9 轻微），是否纳入修复待用户决定；性能类结论全部无基线，仅作方案与待验证假设，不进 `todo.md` / `tasks.md`。

范围外提示：`BackendSelector.cj` 里约 130 个仅测试使用的 `emit*` 是否保留属可见性/存废决策；`A64Lower.bail` 对 `BAIL k>0` 不转储而 x86 转储，与 §7 伪指令表「k>0 时单次转储」不一致（`A64Lower.cj` 不在本部分清单，留待其所属部分核实）。
