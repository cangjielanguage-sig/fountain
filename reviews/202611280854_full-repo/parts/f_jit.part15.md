# f_jit 模块审查报告（第 15/38 部分）

> **模块第 15/38 部分**。本部分只覆盖 `files/f_jit.part15.txt` 列出的 **20 个 `.md`**：
> `doc/spec/` 下 5 个变更（`fix-x86-audit-isolation`、`flip-f-jit-strictfp-default`、
> `harden-f-jit-object-lifetime`、`harden-x86-audit-and-futil-tests`、`jit-closure-unload-cascade`）
> 的 proposal / design / spec delta / tasks / verify / test-plan。
> 同模块其余文件见 `parts/f_jit.part{1..14,16..38}.md`，最终模块报告由主 Agent 合并。
> 本部分为**文档轮**：主体是核对文档承诺与其指到的实现是否一致，因此「位置」多为文档行号 +
> 被承诺的代码行号；文中代码结论均已重读源码取证，未沿用历史报告。

- **审查日期**：2026-11-28
- **模块路径**：`f_jit`（本部分 20 个 `.md`）
- **基线**：工作区快照（`git status --porcelain` 仅 2 个未跟踪的审查目录，`git diff` 为空）⇒ 全部按「存量」计
- **审查重点**：f_jit 专项（动态调用/桥接正确性、句柄与资源生命周期、并发安全、递归与栈溢出、死代码、重复逻辑）；本部分因文件全为规格文档，重点落在「规格 ↔ 实现」的一致性，以及规格承诺的生命周期/并发不变量是否真的成立
- **报告版本**：v1

## 发现

### [严重][存量] 关闭状态机缺「卸载者仲裁」：排空判定与置终态分处两个临界区，并发 `close()` 的回退可让新调用在已释放的机器码上继续执行

- **位置**：
  - 单元路径 `f_jit/src/JitFunction.cj:227-286`：`:231-236` 置 `state=1`（只判 `==2`）、`:237-253` 自旋排空、`:246-251` 超时回退置 `state=0`、`:254-286` 置终态 + 级联 + 取 `release`；
  - 闭包路径 `f_jit/src/JitFunction.cj:302-333`：`:303-308` 置 `e.state=1`、`:311-326` 排空、`:318-323` 回退置 `e.state=0`、`:327-331` 置 `e.state=2` 并 `releaseAll()`；
  - 放行侧 `f_jit/src/JitFunction.cj:198-206`（`enterUnit`）、`:336-349`（`enterClosure`）
  - 承诺源：`f_jit/doc/spec/jit-closure-unload-cascade/design.md:88-113`（D5「卸载中 → 排空 → 已释放」）、`:152-159`（§5「同一闭包：调用 vs 释放」「锁序：全流程只有单元 `mtx` 一把锁，无嵌套」）、`specs/f-jit-facade-bridge/spec.md:39`（「释放 SHALL 先排空该闭包自身的在飞调用再归还提升组」）、`:63`（「超时回退路径 SHALL NOT 释放任何闭包」）
- **来源**：存量（快照模式无 diff）
- **判据**：review-checklist §12.1「检查-然后-写入」「可见性」、§11「并发正确性：检查后写入非原子」；严重度表「数据竞争 / 死锁 / 同步缺失」
- **证据**：静态确定 —— `state` 只是共享标记，没有「本次卸载者」身份；任一 `close()` 都能把 `state` 复位成 `0`（`:247-249`、`:320-322`），而「观测 `active==0`」(`:240-242`、`:312-314`) 与「置终态」(`:256-277`、`:327-330`) 是两个独立临界区，中间**不复检** `active`/`e.active`
- **描述**：可构造的交错（单元路径）：
  1. 线程 A `close(t)`：`:235` 置 `state=1`，进入排空循环；
  2. 线程 B `close(0)`：`:232` 见 `state!=2` ⇒ `:235` 再次置 `state=1`；`limit=0` ⇒ `:246-250` 把 `state` 回退成 `0` 并返回 `false`；
  3. 线程 C 此刻 `call()`：`enterUnit`（`:200`）见 `state==0` ⇒ `active+1` 开始执行；
  4. 线程 A 在「已读过 `active==0`、尚未进入 `:256`」的窗口内恢复执行：`:257` 置 `state=2`，`:275-276` 取出 `release`，`:282-285` 调用它。
  `release` 即 `JitExecutor.release()`（`CompilePipeline.cj:255-258` → `JitExecutor.cj:185-193`），会 `table.free()` / `mirror.free()` / `buf.free()` —— **释放 C 正在执行的机器码**。闭包路径同理，`:331` 的 `releaseAll()` 会归还 C 正在读的句柄槽。规格 §5 声称「置 `state=1` 后新调用一律 19」，但回退无条件复位使该保证失效；`UnloadConcurrency_test` 只覆盖「单卸载者 + 在飞调用」，没有「两个并发 `close()` + 一次回退」的用例（`src/UnloadConcurrency_test.cj:45-90`、`:91-111`）
- **建议**：给卸载加**仲裁**而非仅状态位：进入时以令牌/代际（`closerId`、`epoch`）认领卸载权，第二个并发 `close()` 直接返回 `false` 或等待前者结论；回退只允许令牌持有者复位。更稳的做法是把「复检 `active==0` + 置终态 + 取 `release`」合成**同一个** `synchronized` 块（置终态时 `active!=0` 即回退），锁外只做真正的 `releaseAll()`/`release()`。补 ≥4 线程、每线程 ≥1k 次 `close` 与一次超时回退的压力用例，断言「终态后无在飞调用、无 `isJitBacked()` 单元被释放后又执行」

### [一般][存量] `timeoutMs` 用「自旋次数 × 100000」冒充毫秒：函数内无任何时钟，等待既可能提前也可能迟到，且纯自旋与在飞调用抢同一把锁

- **位置**：`f_jit/src/JitFunction.cj:238`（`let limit = if (timeoutMs <= 0) { 0 } else { timeoutMs * 100000 }`）、`:309-310`（同构）
- **来源**：存量（快照）
- **判据**：review-checklist §11「契约与实现不符」、§6.3「高竞争自旋」、§12.2（自旋抢锁）；承诺源 `f_jit/doc/spec/jit-closure-unload-cascade/specs/f-jit-facade-bridge/spec.md:39`（「`timeoutMs` 内未排空 SHALL 回退为可用并返回 `false`」）、`design.md:100-103`
- **证据**：静态确定 —— `close`/`unloadClosure` 内无 `MonoTime`/`DateTime`/`sleep` 调用，只有 `spins = spins + 1` 与整数比较；`100000` 与「毫秒」无换算依据（A64 侧的审计注释给的是另一种量级）。具体偏差幅度需实测（见待验证假设 #3）
- **描述**：三点后果：
  1. **提前超时**：无竞争时一次取锁约数十至数百纳秒，`1 ms` 只够约 10⁴ 次迭代，`close(1000)` 可能在十几毫秒内就返回 `false`，按「等 1 秒」写的重试逻辑全部落空；
  2. **迟到超时**：竞争激烈时单次取锁可达微秒级，`timeoutMs=10000`（`UnloadConcurrency_test.cj:67` 的真实用法）意味着上限 10⁹ 次取锁，实际可能以分钟计；
  3. **溢出**：`timeoutMs > 9.2e13` 时 `*100000` 溢出为负 ⇒ `spins >= limit` 首轮即真，超长等待参数变成立刻失败。
  另外排空每轮都要 `synchronized(this.mtx)`，而在飞调用收尾（`exitUnit`/`exitClosure`）也需要这把锁，自旋持续抢占会拉长被等待者的收尾时间；`CompileCache.awaitReady` 已因同类问题从「每轮取全局锁」改成指数退避（`src/CompileCache.cj:124-127` 注释），本处未同步
- **建议**：改为基于时钟的截止时间（进入前取 `now() + timeoutMs`，每轮比较），等待期间让出而非满速自旋；`timeoutMs` 先做上限判定或饱和运算。修改后补计时用例（`close(0)` 立即返回、`close(50)` 落在 40–60 ms），否则同类偏差无法回归

### [一般][存量] `Resource.close(): Unit` 丢弃 `close(0)` 的 `Bool`：有在飞调用时静默不释放，`try (f) {}` 的调用方无从得知

- **位置**：`f_jit/src/JitFunction.cj:523-525`（`public func close(): Unit { let _ = this.close(0) }`；`JitFunction <: Resource` 见 `:59`）
- **来源**：存量（快照）
- **判据**：review-checklist §3（返回值被丢弃）、§11「错误处理缺失或静默」；承诺源 `jit-closure-unload-cascade/specs/f-jit-facade-bridge/spec.md:39`（`false` 表示「未释放」）、`:63`（级联只在进入终态时发生）
- **证据**：静态确定 —— `close(0)` 在 `active>0` 时按 `:238`/`:246-251` 必然走立即回退分支并返回 `false`，而 `let _ =` 把它丢掉
- **描述**：`Resource.close()` 是 `try (res = f) { ... }` 唯一能自动调用的入口。并发调用存在时，自动关闭既不置终态、不级联释放逃逸闭包、也不逐出编译缓存，但调用方拿到 `Unit`。注释已写明「不等待在飞调用（等价 `close(0)`，丢弃排空结果）」，即这是有意为之；但与 `Resource` 的「释放资源」契约相反，后果是句柄/提升组继续驻留、缓存继续命中一个本应死亡的单元
- **建议**：在 `close(): Unit` 内对 `false` 做可观测处理（`f_log` 一条 `warn`，带单元 id/在飞计数），或额外提供 `tryClose(): Bool` 供显式路径使用；README 的释放协议段补一句「`try` 自动关闭不等待在飞调用，生产代码应显式 `close(timeoutMs)` 并检查返回值」

### [一般][存量] G5 规格写「记录**每条**内存访问的基址」，实现是抽样：`CALL_CLOSURE` 的 4 条访存（含 H57 返回的 `fnTable` 基址）与 A64 的 `ldrD/strD/ldrReg` 完全不登记

- **位置**：
  - 规格 `f_jit/doc/spec/harden-f-jit-object-lifetime/specs/f-jit-backend/spec.md:32-39`（「降低期 SHALL 记录每条内存访问的基址寄存器」）、`design.md:31-38`（采集点清单，只列 8 个 x86 发射器与 `A64Emitter.ldrOff/strOff`）
  - x86 实现 `f_jit/src/backend/X86Lower.cj:633-661`：`:645` `mov [rbp-16],rax`、`:655` `mov [rbp-24],rax`、`:657-659` `mov rax,[rbp-16]; mov rcx,[rbp-24]; rax=[rcx+rax*8]` 都是裸字节发射，无 `noteMemBase`/`noteAbsMem`（对照 `:452` 的 `callFunc` 有 `noteAbsMem()`、`:793` 的 `PUSH_KH` 有 `noteAbsMem()`）
  - a64 实现 `f_jit/src/backend/A64Emitter.cj:543-549`（`ldrD`/`strD` 不 `note`）、`:638-640`（`ldrReg` 不 `note`）；使用点 `f_jit/src/backend/A64Lower.cj:670`（`ldrReg(10, 12, 9)`，基址 `x12` 来自 H57）
  - 允许集表述冲突：`harden-f-jit-object-lifetime/.../spec.md:36-39` 规定「x86 基址 ∈ {rsp,rbp,r15}，集合外一律放弃 JIT」；`harden-x86-audit-and-futil-tests/.../spec.md:10-24` 以 **ADDED**（而非 MODIFIED）形式追加「哨兵 `-1` 视为合规」
- **来源**：存量（快照）
- **判据**：review-checklist §13「规格与实现漂移」、§11「契约与实现不符」、§14.1「只做了一半的分支」；§2「字面量复制导致行为漂移」（同一允许集在 4 份文档各写一遍）
- **证据**：静态确定 —— `auditAllows([])` 为真（`src/backend/EmitAudit_test.cj:37` 断言），因此**未登记即视为合规**；`callClosure:657-659` 的解引用基址是 `rcx`（H57 返回值），不在 `{4,5,15,-1}`，若补登记会直接判违规。`X86Lower.lower` 只在结束时对快照做一次 `auditAllows`（`:150-154`），抽样漏项不会被发现
- **描述**：G5 的威胁模型原文是「机器码不得把 helper 返回的 `cell` 当指针解引用」，而 `CALL_CLOSURE` 恰恰是「H57 返回 `fnTable` → 寄存器偏移解引用」——它没走任何登记点，所以审计对它恒为真。`harden-x86-audit-and-futil-tests` 专门为 `CALL_FUNC`/`PUSH_KH` 补过同类缺口，却漏了 `CALL_CLOSURE`；A64 的浮点访存与 `ldrReg` 同理。两份 delta 对允许集的表述也互相否定（前者「集合外一律拒绝」，后者接受 `-1`），因为后者用了 ADDED 而非 MODIFIED。审计只在降低期生效、不影响产物，所以不是生产缺陷；但文档给出的结论「审计通过 ⇒ 机器码只碰受控基址」目前是**抽样结论**，不是全覆盖
- **建议**：二选一并写进规格——(a) 补全采集：`callClosure` 的 `fnTable` 解引用按 `noteAbsMem()`（或新增「表基址」类别，语义比「绝对地址」准确）登记，`:645`/`:655`/`:657-658` 补 `noteMemBase(5)`，`A64Emitter.ldrD/strD/ldrReg` 补 `noteMemBase`；(b) 把 Requirement 改成可执行口径「采集点 = `{movQwordCtx, movRaxMemRsp, leaRdxRsp, pushMemRsp, moveRaxToMemRsp, ucomisdRM, pushMemRbp, popMemRbp}` + 显式绝对地址，其余路径不采集」。同时把允许集的追加改成 MODIFIED 条款，避免两份规格字面冲突。选 (a) 需先跑 `JitBacked_test`/`X86Lower_test`，确认补登记后没有整单元回退

### [轻微][存量] `jit-closure-unload-cascade/proposal.md` 的生命周期结论与同变更 design/实现相反：单元**不**强引用包装实例，却被写成「持强引用」

- **位置**：`f_jit/doc/spec/jit-closure-unload-cascade/proposal.md:33`（「单元对登记在册的包装实例持强引用，直到该闭包被释放或单元卸载」）；对照 `design.md:35`（「条目只引用组与计数，不引用包装实例 ⇒ 单元不再强引用包装对象」）、`design.md:166-168`（§6 差异表「单元 → 包装强引用：上一版有 / 本版无」）；实现 `f_jit/src/JitFunction.cj:106`（`private let escaped = ArrayList<EscapedClosure>()`）、`f_jit/src/EscapedClosure.cj:29-42`（只有 `seq`/`group`/`state`/`active`）
- **来源**：存量（快照）
- **判据**：review-checklist §13「同一变更内文档自相矛盾」、§11「语义与注释不符」；本条直接关系 f_jit 专项「句柄与资源生命周期」
- **证据**：静态确定 —— 三处文本与实现的字段集合互斥：proposal 说单元钉住包装对象，design 与代码都表明只钉住提升组
- **描述**：B3 修复的目的就是「宿主丢弃包装后包装对象可被 GC」，proposal 的 Impact 段却把被修复的旧行为当作结果写出来。只读 proposal 的调用方会误以为包装实例不会被回收，从而错误评估内存驻留
- **建议**：把该句改为「单元持有的是条目（组 + 计数），**不**引用包装实例；包装对象随宿主引用消失可回收，提升组按契约驻留到闭包释放或单元卸载」

### [轻微][存量] `harden-f-jit-object-lifetime` 同一变更内对 G1 的定性相反：proposal/design 称「真缺陷、每次泄漏 1 槽」，tasks/verify 称「RED 不可得、防御性加固」

- **位置**：`f_jit/doc/spec/harden-f-jit-object-lifetime/proposal.md:9`（表格「**G1** … **真缺陷**」）、`design.md:5-15`（「每次契约失败泄漏 1 槽」）；对照同变更 `tasks.md:7-8`（「**RED 不可得**（unbox 前的静态契约检查先拦下 ⇒ 泄漏路径不可达……该用例保留为回归护栏）」）与 `f_jit/doc/spec/f-jit-m1/verify.md:265`（「RED 不可得……本条属**防御性加固**，用例修前修后皆绿」）
- **来源**：存量（快照）
- **判据**：review-checklist §13「同一变更内文档自相矛盾」、§11「语义与注释不符」
- **证据**：静态确定 —— 实现先按 `T` 与 `retType` 定 `unboxCode`（`f_jit/src/JitFunction.cj:578`，静态契约检查之后），再做解包（`:649-654`）；`try/catch` 只覆盖 `unboxRet` 自身抛错的残余分支，与「声明类型不符即泄漏」不是同一条路径
- **描述**：读者若只看 proposal/design，会以为这是已复现的泄漏并按高优先级排期；tasks/verify 说明它只是防御性加固。归档文档按「当时结论是否自洽」核对，此处不自洽
- **建议**：proposal/design 补一句「静态契约检查已拦下声明不符路径；本修复覆盖 `unboxRet` 因无效句柄抛出的残余分支，RED 构造不出来」；或把 G1 从「真缺陷」降为「加固项」，与 tasks/verify 统一

### [轻微][存量] `fix-x86-audit-isolation` 把 aarch64 现状写成 ThreadLocal，实际是实例字段；`A64Emitter` 内还留着互斥的旧注释

- **位置**：`f_jit/doc/spec/fix-x86-audit-isolation/proposal.md:16-17`（「A64 侧……已经修过同一个缺陷（改 `ThreadLocal`）」）、`:33`（「与 A64 侧同一设计（每内存操作一次 TLS get）」）、`verify.md:28-30`、`:48-50`（「与 aarch64 侧长期使用的设计一致……该成本低于本机测量分辨率」）；对照 `f_jit/src/backend/A64Emitter.cj:456-458`（「用**实例字段**而不是 ThreadLocal……ThreadLocal 只是把成本摊到每次内存操作上（实测 598 次/编译，约 180 µs）」）、`:463`（`private let audit`）、`:452`（「放在 ThreadLocal 里零锁、零共享」旧注释）
- **来源**：存量（快照）
- **判据**：review-checklist §13「文档过期 / 与实现不符」；本条是选型依据，依据错则结论适用性存疑
- **证据**：静态确定 —— 文档与 `A64Emitter.cj:456-458` 直接对立；`grep ThreadLocal src/backend/A64Emitter.cj` 只命中注释，无字段
- **描述**：x86 选 `ThreadLocal` 的理由是「与 A64 同一设计、A64 实测无显著成本」，但 A64 现行实现是实例字段，且其注释明确说 ThreadLocal 因每访存一次 TLS `get`（598 次/编译、约 180 µs）被放弃。这不影响 x86 修复本身的正确性（`BackendSelector.cj:258-268` 的线程隔离有 `X86AuditIsolation_test` 佐证），但论证不成立；后续若照此把 A64 回改成 ThreadLocal 会白付 180 µs/编译。`A64Emitter.cj:452` 的旧注释与 `:456-458` 并存，读者无法判断哪个是现状
- **建议**：proposal/verify 改为「A64 用实例字段（生命周期 = 一次 `compileOnce`）；x86 的发射助手是静态函数且 `EmitAudit_test` 依赖静态 API，只能用 ThreadLocal，代价为每访存一次 TLS `get`，本机未测出显著差异」；同时删掉 `A64Emitter.cj:452` 的「放在 ThreadLocal 里零锁、零共享」

### [轻微][存量] `harden-x86-audit-and-futil-tests/design.md` 用不存在的行号作为「方言支持 `recursive`」的证据

- **位置**：`f_jit/doc/spec/harden-x86-audit-and-futil-tests/design.md:49`（「方言**支持** `recursive`（`Lowerer.cj:805/2492/2542/3242`）」）
- **来源**：存量（快照）
- **判据**：review-checklist §13「关键证据失准」；该条正是文档自我纠正「检索漏 `-Recurse`」后的**订正结论**，证据本身却不可复核
- **证据**：静态确定 —— `grep -n "recursive" f_jit/src/compiler/Lowerer.cj` 只命中 `:804`（文档注释），`:2492/:2542/:3242` 与 `recursive` 无关（文件共 3923 行）。真实支持点：`f_jit/src/compiler/Lexer.cj:310`（`case 'recursive'`）、`PredefinedSnapshot.cj:146`（`if (name == 'recursive')`）、`Lowerer.cj:804`（尾位置 `recursive(args)` 降低）
- **描述**：结论（支持 `recursive`）正确且有 `JitBacked_test.recursiveUnitStaysJitBacked`（`src/JitBacked_test.cj:51-59`）佐证，但引用的 4 个行号有 3 个不存在、第 1 个也不是代码实现点
- **建议**：改为 `Lexer.cj:310` / `PredefinedSnapshot.cj:146` / `Lowerer.cj:804`，并注明「行号随重构漂移，以符号检索为准」

### [轻微][存量] `jit-closure-unload-cascade/design.md` §5 的「全流程只有单元 `mtx` 一把锁，无嵌套」与同文 D7 及实现矛盾（锁内取缓存锁）

- **位置**：`f_jit/doc/spec/jit-closure-unload-cascade/design.md:159`（「锁序 | 全流程只有单元 `mtx` 一把锁，无嵌套」）；对照 `design.md:131-148`（D7 伪码在 `synchronized(this.mtx)` 内「… 逐出缓存 …」）、实现 `f_jit/src/JitFunction.cj:256-277`（`:260-265` 在锁内 `CompileCache.remove(k)`）、`f_jit/src/CompileCache.cj:71-84`（`finish` 明确把 `bindCacheKey` 移到缓存锁外以避开 ABBA）
- **来源**：存量（快照）
- **判据**：review-checklist §12.2「锁序」、§13「规格与实现漂移」；不变量写错会让后来者按「单锁」假设改代码
- **证据**：静态确定 —— `close` 持 `this.mtx` 期间调用 `CompileCache.remove`（取全局缓存锁），构成 unit.mtx → cache.mtx 的嵌套；反向路径已被 `CompileCache.finish` 的锁外 `bindCacheKey` 规避，但该规避只写在缓存侧注释里，规格未记
- **描述**：实际不变量是「两把锁，固定顺序 unit.mtx → cache.mtx，且 cache 侧不得在持锁时回调单元」，不是「单锁无嵌套」。当前实现安全（`CompileCache.finish` 的注释与 `:74-84` 的顺序保证），但规格把安全前提写没了
- **建议**：把 §5「锁序」改为「两把锁：单元 `mtx` 与 `CompileCache.mtx`，只允许 unit.mtx → cache.mtx；`CompileCache.finish` 必须在缓存锁外调用 `bindCacheKey`」，并在 `spec.md:61-63` 的卸载状态机 Requirement 补一句锁序约束

### [轻微][存量] 归档规格的 `unload()` / `unloadFn()` / `isUnloaded()` 已整体改名 `close(timeoutMs)` / `closeClosure` / `isClosed`，规格未回填

- **位置**：`f_jit/doc/spec/jit-closure-unload-cascade/specs/f-jit-facade-bridge/spec.md:39`（「唯一释放入口 SHALL 为 `unload()`」「`unloadFn()` SHALL 为内部私有实现」）、`:22-25`（「卸载弱语义」Scenario）、`design.md:8`、`:72-86`（D4 `unload()` 分派）、`:175-182`（§8 API 影响）；现状 `f_jit/src/JitFunction.cj:227`（`close(timeoutMs)`）、`:294`（`closeClosure`）、`:471`（`isClosed`）、`:523`（`close(): Unit`）
- **来源**：存量（快照）
- **判据**：review-checklist §13「文档过期：描述的功能已改名」；`reviewer.md` 对归档 `doc/spec/` 的豁免只要求「当时结论自洽」，故只记轻微
- **证据**：静态确定 —— `grep -rn "isUnloaded\|\.unload(" f_jit/src` 零命中；现行公开 API 与 README 统一使用 `close`
- **描述**：后续变更把 `unload` 改名为 `close`（与 `Resource` 对齐，合理），但本规格未回填。按规格写代码或按名检索会找不到入口；规格里「`unload()` 在包装实例上释放本闭包」的语义现在挂在 `close(timeoutMs)` 上，读者无从对应
- **建议**：在规格顶部加一行「**后续变更**：`unload()`/`unloadFn()` 已更名为 `close(timeoutMs)`/`closeClosure`，`isUnloaded()` 并入 `isClosed()`；语义不变」，或由主 Agent 合并时统一记一条「归档 spec 的 API 名称未随重命名更新」

### [轻微][存量] 规格的多条验收 Scenario 没有对应用例：越界基址「整单元回退」、G6 的「中断」出口、运行期错误路径的 `NativeMem.outstanding()`

- **位置**：
  - `f_jit/doc/spec/harden-f-jit-object-lifetime/specs/f-jit-backend/spec.md:48-51`（「越界基址被拒绝 … 单元降低失败并退回解释器，结果/错误码/site 与纯解释一致」）—— `src/backend/EmitAudit_test.cj` 只测 `auditAllows` 纯函数与采集/重置，无用例驱动 `X86Lower`/`A64Lower` 真正失败
  - 同文件 `:53-62`（四个出口都要满足三项归零）—— `src/Lifetime_test.cj:82-99`（运行期错误）只断言 `liveCount` 与 `windowUsed`，缺 `NativeMem.outstanding()`（`:69`/`:77` 只出现在成功路径）；全文件无「中断 / deadline」出口用例（`grep deadline src/Lifetime_test.cj` 零命中）
- **来源**：存量（快照）
- **判据**：review-checklist §14.1「只做了一半的分支」「接线缺失」、§13「验收口径与实现不一致」
- **证据**：静态确定 —— 上述两处函数体内无相应调用；`Lifetime_test` 的出口集合只有「成功 / `DIV_ZERO` / 契约失败」三类
- **描述**：`DIV_ZERO` 这类运行期错误会经过 `JitReport.finish` 的 replay/诊断分支，是最可能产生原生内存不对称的出口，恰恰没有断言原生内存；「中断」出口完全无覆盖。G5 的「越界即回退」只有纯函数级断言，无法证明整单元真的退回解释器且结果与解释一致
- **建议**：`runtimeErrorCallsKeepResourcesFlat` 增加 `NativeMem.outstanding()` 基线与收尾断言；补一条以过去 `deadline` 触发 `−2` 的用例并断言三项；补一条构造性用例（让 `noteMemBase(0)` 参与一次 lowering，断言 `success()` 为假且调用结果/错误码与解释器一致）

## 优化可行性方案

### [CPU] 逃逸闭包登记表按设计用 `HashMap`，把 `dropEscaped` 的线性扫描降为 O(1)

- **现状**：`escaped` 是 `ArrayList<EscapedClosure>`（`f_jit/src/JitFunction.cj:106`、`:359-366` 追加、`:379-388` 线性扫描 + `remove(at: i)` 搬移尾部）；每次关闭一个包装实例走 `unloadClosure → dropEscaped`，代价 O(n)，逐个关闭 n 个逃逸闭包累计 O(n²)。设计 `design.md:41` 本来就写的是 `HashMap<Int64, EscapedClosure>`（`key = 条目序号`），实现退化成了数组
- **方案**：`escaped` 改 `HashMap<Int64, EscapedClosure>`（`seq` 已是唯一键）；`dropEscaped(e)` 改 `escaped.remove(e.seq)`；`:267-273` 的级联改为遍历 `values()`。`lastEscaped` 语义不变
- **预期**：单次 `close` 从 O(n) 降到 O(1)，逐次关闭 n 个闭包从 O(n²) 降到 O(n)。绝对收益取决于 n（单单元未释放的逃逸闭包数），n 较小时应在噪声内
- **代价**：级联释放顺序由插入序变为哈希序（`releaseAll` 幂等、释放顺序无外显语义，但断言顺序的用例需调整）；`HashMap` 桶内存略高于数组
- **验证**：`cjpm bench -O2`，n = 100 / 1 000 / 10 000 个已登记条目，跑「全部 `close()`」与「单条 `close()`」两场景，取中位数与 P95/P99 与现实现对照；同时跑 `Lifetime_test` / `JitClosureLifecycle_test` / `UnloadConcurrency_test`
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

> 无性能数据支撑，均不作为缺陷，只用于下一轮补数据。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | x86 审计「每次访存一次 TLS `get` + 结束时 `toArray`」在编译期占比可忽略（A64 注释给的是 598 次/编译、约 180 µs，x86 量级未知） | `f_jit/src/backend/X86Lower.cj:108`、`:150-154`；`BackendSelector.cj:258-280` | 单次编译的审计分配字节数与自耗时占比 | `cjprof record` 编译 1k 个单元，与临时关闭审计的空实现对照耗时与 `getAllocatedHeapSize()` |
| 2 | 逃逸闭包登记表 + 提升组随 `call<JitClosureId>` 次数无界增长（B4 声明为契约），长跑抬 RSS | `f_jit/src/JitFunction.cj:656-674`、`:359-366`、`:106` | 条目数 / `liveCount` / RSS 随调用次数的曲线 | 循环 `call<JitClosureId>` 10 万次不承接，每万次打印 `liveCount`、登记表规模与 RSS |
| 3 | 排空自旋的实际墙钟误差与 CPU 占用（发现 #2 的量化面） | `f_jit/src/JitFunction.cj:237-253`、`:309-326` | 每次 `close` 的墙钟时间、CPU 时间、自旋次数、失败率 | 1/4/16 线程并发 `close(1)` + 一个 200 ms 长调用，统计墙钟分布与线程 RUNNABLE 占比 |
| 4 | `escaped` 改 `HashMap` 的实际收益量级 | `f_jit/src/JitFunction.cj:379-388` | n = 100/1k/10k 时单次与批量 `close` 的耗时 | 按优化方案的 bench 场景采中位数与 P95/P99 |

## 文件覆盖

> 与 `reviews/202611280854_full-repo/files/f_jit.part15.txt` 一一对应（20 行）。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_jit/doc/spec/fix-x86-audit-isolation/proposal.md` | .md | ✅ | ThreadLocal 修复已落地；A64 现状描述见发现 #7 |
| 2 | `f_jit/doc/spec/fix-x86-audit-isolation/tasks.md` | .md | ✅ | 任务与实现对应（`src/backend/X86AuditIsolation_test.cj` 存在，2 例） |
| 3 | `f_jit/doc/spec/fix-x86-audit-isolation/verify.md` | .md | ✅ | §3/§5 的 A64 表述见发现 #7；1248 总数未复核（未跑构建） |
| 4 | `f_jit/doc/spec/flip-f-jit-strictfp-default/design.md` | .md | ✅ | 三层默认 `true` 与 `CompileOptions.cj:45`、`SourceCompiler.cj:104`、`Lowerer.cj:166` 一致；缓存键 `fp0|1` 与 `CompilePipeline.cj:60` 一致 |
| 5 | `f_jit/doc/spec/flip-f-jit-strictfp-default/proposal.md` | .md | ✅ | 7 处显式关闭与用例一致 |
| 6 | `f_jit/doc/spec/flip-f-jit-strictfp-default/specs/f-jit-facade-bridge/spec.md` | .md | ✅ | 「缺省即严格」已落地（`Lowerer.cj:1411`）；`CallContext` 无 `literalCopy`（`base/CallContext.cj:30`） |
| 7 | `f_jit/doc/spec/flip-f-jit-strictfp-default/tasks.md` | .md | ✅ | `defaultIsStrict` / `defaultEmitsFdivChk` 均存在（`StrictFp_test.cj:37`、`compiler/StrictFpCodegen_test.cj:51`） |
| 8 | `f_jit/doc/spec/flip-f-jit-strictfp-default/test-plan.md` | .md | ✅ | 用例清单可逐条对上 |
| 9 | `f_jit/doc/spec/flip-f-jit-strictfp-default/verify.md` | .md | ✅ | 7 处落点与实现一致；用例计数无法复核（未跑构建） |
| 10 | `f_jit/doc/spec/harden-f-jit-object-lifetime/design.md` | .md | ✅ | G4 等价性成立；G1 定性见发现 #6；G5 采集口径见发现 #4 |
| 11 | `f_jit/doc/spec/harden-f-jit-object-lifetime/proposal.md` | .md | ✅ | G1「真缺陷」表述见发现 #6 |
| 12 | `f_jit/doc/spec/harden-f-jit-object-lifetime/specs/f-jit-backend/spec.md` | .md | ✅ | 码表完备性成立（`LocalType.cj:125-127` + `JitFunction.cj:722-724`）；G5/G6 见发现 #4、#11 |
| 13 | `f_jit/doc/spec/harden-f-jit-object-lifetime/tasks.md` | .md | ✅ | 1.2「RED 不可得」与 proposal 冲突（发现 #6）；6.2 的 verify 记录在 `doc/spec/f-jit-m1/verify.md:261-265` |
| 14 | `f_jit/doc/spec/harden-x86-audit-and-futil-tests/design.md` | .md | ✅ | `recursive` 证据行号错误（发现 #8）；`JitBacked_test` 实为 4 例（文档列 2+1） |
| 15 | `f_jit/doc/spec/harden-x86-audit-and-futil-tests/proposal.md` | .md | ✅ | 哨兵 `-1` 已落地（`BackendSelector.cj:288-303`） |
| 16 | `f_jit/doc/spec/harden-x86-audit-and-futil-tests/specs/f-jit-backend/spec.md` | .md | ✅ | 与 `auditAllows` 一致；以 ADDED 追加导致与前一规格字面冲突（发现 #4） |
| 17 | `f_jit/doc/spec/harden-x86-audit-and-futil-tests/tasks.md` | .md | ✅ | 任务与实现对应 |
| 18 | `f_jit/doc/spec/jit-closure-unload-cascade/design.md` | .md | ✅ | 状态机已落地；并发回退见发现 #1；锁序表述见发现 #9；`HashMap` 见优化方案 |
| 19 | `f_jit/doc/spec/jit-closure-unload-cascade/proposal.md` | .md | ✅ | B1/B2/B3 已落地；生命周期表述见发现 #5 |
| 20 | `f_jit/doc/spec/jit-closure-unload-cascade/specs/f-jit-facade-bridge/spec.md` | .md | ✅ | 释放协议/级联条款与实现基本相符；`timeoutMs` 见发现 #2、`close(): Unit` 见发现 #3、命名见发现 #10 |

合计：`.cj` 0 个 / `.md` 20 个 / 共 20 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 3 | 发现 #1（并发正确性）、#2（契约/超时语义）、#3（返回值丢弃）。文档无外部输入、无敏感数据、无注入面；语言特性侧核对了 `Option`、`ThreadLocal`、`synchronized`、`Resource.close` 与 `Map.remove` 语义 |
| §1 死代码 | 0 | 本部分无 `.cj`。文档中 `unload()`/`unloadFn()`/`isUnloaded()` 在 `f_jit/src` 零命中，属「改名未回填」按 §13 记（发现 #10），不按死代码计；`EscapedClosure.seq` 有实际读取（`dropEscaped`），`newEscapedClosure` 有测试调用 |
| §2 重复逻辑 | 1 | 同一 G5 允许集/采集口径在 `harden-f-jit-object-lifetime` 的 design+spec 与 `harden-x86-audit-and-futil-tests` 的 spec 各写一遍，且已漂移成字面冲突（并入发现 #4）。其余重复是 SDD「提案→设计→规格→任务→验证」的固有分层，差异点是读者层次，不判 |
| §3 空实现 | 0 | 未发现空函数体 / 占位 `TODO` / 静默吞异常。G1 的 `try/catch`（`JitFunction.cj:649-654`）有实际归还动作；`case None => ()`（`:672`）是「无提升组」的正常缺失 |
| §4 栈溢出 | 0 | 本部分文档未新增递归。顺带核到 `CallMarshal.promoteClosureGraph` 对嵌套闭包递归，但有 visited 防环（范围外提示，不计入本部分） |
| §5 OOM | 0 | 登记表无界增长被 `design.md:170-173`（B4）明确写为既有契约，不判缺陷；量化面进待验证假设 #2 |
| §6.1 热点瓶颈 | 0 | 本部分无 profile / bench 数据（verify 只有用例计数），审计开销与自旋成本不成立为热点，已列入待验证假设 #1/#3 |
| §6.2 大粒度锁 | 0 | `close` 锁内的 `CompileCache.remove` 是内存操作，无 I/O/解析；自旋抢锁并入发现 #2 |
| §6.3 并发串行 | 0 | 无 `spawn` + 立即 `get()`、无单消费者队列；文档未承诺并行调用路径 |
| §6.4 低效算法 | 0 | `dropEscaped` 的 O(n)/累计 O(n²) 属实，但无 n 与耗时数据，只进优化方案 + 假设 #4 |
| §7 降堆内存方案 | 0 | 未发现可量化的多余副本；改 `HashMap` 会增加少量桶内存，收益在 CPU 侧，故不列堆方案 |
| §8 降 CPU 方案 | 1 | 登记表改 `HashMap`（`dropEscaped` O(n)→O(1)），证据状态「无基线（待验证）」 |
| §9 local mode 可行性 | 0 | 本部分无函数内临时大对象；审计表/登记表都跨调用存活，逃逸分析不成立 |
| §11 现有代码的 BUG（存量） | 3 | 逐个核对了 `close`/`unloadClosure`/`close(): Unit`/`enterClosure`/`enterUnit` 的边界与空值：#1（并发回退）、#2（自旋超时）、#3（返回值丢弃）。`entryOrFail` 的 `None` 分支、`isClosed` 三态、`close` 的 `state==2` 幂等分支无缺陷 |
| §12 并发安全与锁粒度 | 3 | #1（共享 `state` 无卸载者仲裁 ⇒ 检查后写入非原子，可释放正在执行的代码内存）、#2（自旋持锁抢锁）、#9（规格锁序不变量写错，实际为两把锁固定顺序）。已核对 `enter/exit`、`registerEscaped`、`closureReleased`、`lastEscaped` 的读写都在同一 `mtx` 内 |
| §14 功能完备性与 README 覆盖 | 2 | #4（G5「每条」只兑现抽样，且 `CALL_CLOSURE` 未登记）、#11（三条验收 Scenario 无用例）。README 本体不在本部分清单内，其与 `public` 声明的逐项覆盖由其他部分统计 |
| 文件覆盖（§13 等） | 20/20 | 20 个 `.md` 全部读完；§13 文档一致性命中 6 条（#5 #6 #7 #8 #9 #10），另 1 条属 §13/§14 交叉（#4） |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 1 |
| 一般 | 3 |
| 轻微 | 7 |
| 优化方案（堆内存 / CPU） | 0 / 1 |

存量 11 条（严重 1 / 一般 3 / 轻微 7），是否纳入修复待用户决定。

## 总评

这 20 份文件是 5 个已归档变更的完整记录（提案 → 设计 → 规格 → 任务 → 验证），文档质量总体在平均线以上：`strictFp` 三层缺省同步（`CompileOptions.cj:45`、`SourceCompiler.cj:104`、`Lowerer.cj:166`）、`isReturnedHandle` 由 `LocalType.isHandle` 单点派生（`JitFunction.cj:722-724`）、x86 审计的 `ThreadLocal` 隔离（`BackendSelector.cj:258-303`）、`-1` 绝对地址哨兵、B1/B2/B3 三条生命周期缺陷的落点，都能与现行实现逐条对上；`verify.md` 还如实记下「G1 的 RED 构造不出来」，没有把防御性加固包装成已复现缺陷。

**阻塞项只有一处**：`jit-closure-unload-cascade` 落地后的关闭状态机。`state` 是共享标记而非卸载者令牌，任一并发 `close()` 的超时回退都能把它复位成 `0` 并重新放行调用；而「排空判定」与「置终态 + 取 `release`」分处两个临界区，中间不复检 `active`。交错成立时会在在飞调用期间 `releaseAll()` 提升组，单元路径更进一步——`JitExecutor.release()` 直接释放正在执行的机器码。触发需要「两个线程同时 `close` + 至少一次超时回退 + 新调用落进微秒级窗口」，概率低但后果不可恢复，建议优先修并补多线程压力用例。

**可排期的一般项**：`timeoutMs` 用「自旋次数 × 100000」近似毫秒且无时钟（既可能提前也可能迟到，批量等待还会被自旋拖长）；`Resource.close(): Unit` 把 `close(0)` 的 `Bool` 丢掉，`try (f) {}` 在有并发调用时静默不释放；G5 的「记录每条内存访问」只覆盖了一半，漏掉的 `CALL_CLOSURE` 恰好是唯一一处 helper 返回表基址的解引用，两份 delta 对允许集的表述还以 ADDED 方式互相否定——护栏目前只能算抽样。

**文档偏差都很轻**：proposal 把「单元不强引用包装实例」写反、G1 在同一变更内前后定性相反、A64 现状（实例字段 vs ThreadLocal）描述与实现相反且源码里留着互斥旧注释、`recursive` 的 4 个引用行号有 3 个不存在、§5 的「单锁无嵌套」与 D7 和实现矛盾、`unload` 家族改名未回填。这些是「照文档检索会落空或误判」的成本，不影响行为。

性能方面本部分没有任何可复核的测量数据（verify 只有用例计数），因此审计开销、登记表增长、自旋 CPU 占用全部只列为待验证假设与一条无基线的 CPU 方案，没有写进缺陷。
