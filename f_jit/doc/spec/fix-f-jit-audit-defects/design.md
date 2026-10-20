# Design

> 依据：`reviews/202610202219_f-jit-completeness/`（`summary.md` / `todo.md` / `verify_r4.md` / `verify_r3r5.md` / `verify_r1r2r6.md`）与本仓库 `f_jit/doc/{jit-bytecode-m3.md, design-m3.md, plan-m3.md}`。
> 行号以审查当时的 `f_jit` 工作树为准；实施时以符号名为准（行号可能漂移）。

## 1 总则

1. **只纠正已宣称能力的实现，不扩能力面**：任何修复都不得改变 `.fbc` 格式、v1/v2/v3 规则集、公开错误码集合、既有 helper 编号区间（H1–H83）。
2. **先红后绿**：每条缺陷先落一个**当前必红**的用例。审查里大量「已绿」的用例是**结构断言**（断言产物里出现某指令 / 某 helper），不是语义断言；修复时同时把这类假绿用例升级为「执行结果断言」。
3. **零回归门槛**：每批次跑 M1 + M2 + M3 全量（含差分），数字与前一批次对照，任何差异按阻塞缺陷处理。
4. **单点修，不做顺手重构**：每个任务只碰它对应的函数；绕不开的共用函数（如 `HandleTable`）改动必须由多条缺陷共同需要时才做。
5. **前置假设**：M3（R0–R6）实现与归档均已落地，delta 已并入 `openspec/specs/`（2026-10-20 归档）。因此本变更对 H78–H80 的收紧以 **`MODIFIED`** 登记：保留原 5 条 scenario，补 2 条（14 类界、aux 编码）；窗口记账另立 `ADDED` 契约，避免把两条不同性质的行为塞进一个 requirement。

## 2 缺陷目录与修法

### P0（不可用，6 条）

| ID | 位置 | 现状与根因 | 修法 |
| --- | --- | --- | --- |
| P0-1a | `runtime/AnyHelpers.cj:143` | H79/H80 的 14 只判「是 `Object` 且非 `JsonValue`」，`as 某个注册类` 对**任意**宿主对象都命中 ⇒ 类界形同虚设 | 14 目标改为「按 `aux` 指向的 `$as$<C>` 判定」；`aux == 0xFFFF` 时保留「任意宿主对象」的旧口径（仅前端拿不到类名时出现，当前不产生） |
| P0-1b | `runtime/AnyHelpers.cj:92-99` | 14 落到 `case _` → `HandleTable.pin(v)`；`tokenOf` 对非白名单类返回 `RESERVED` ⇒ `failWith(CALL_CONTRACT)`，`as C` 恒失败；即便 pin 成功也是 tag 12（Any）而非 11（HostObject） | 新增 `HandleTable.appendHostObject(ctx, o)`（tag `HOST_OBJECT`、走 `append` 计窗口、同对象去重），14 分支改调它 |
| P0-2 | `JitFunction.cj:631-678` | `localTypeOf<T>` 无 `Any` / JSON 行 ⇒ `call<Any>`、`call<JsonObject>` 在 `callLocked` 第 5 步报「T 不是可解包类型」；`CallMarshal` 的 15/16–19 行**永不可达** | 补 `Any → 15`、`JsonValue/JsonObject/JsonArray/JsonNull → 16/17/18/19`（按 `TypeInfo` 名判定，先于 `ClassTypeInfo` 兜底）；与 `CallMarshal.makeRetUnboxer` 的行一一对表 |
| P0-3 | `runtime/Interp.cj:492-494, 538` | `cmpOp` 把 `0x65`（BNOT_I）当成「一元且无需弹栈」：`b = 0`、`a = 0`，结果恒 `-1`，操作数留在栈上（后续指令全错位） | 一元算子的判定拆开：`0x5E`（NOT）弹 1 个；`0x65`（BNOT_I）弹 1 个后压 `0 - a - 1`；与 `A64Lower` 的 `MVN` 语义逐位对拍 |
| P0-4 | `JitReport.cj:64-66` | DEOPT 分支直接 `return replay()`，重放前未 `ctx.errCode = 0`；`Interp` 用 `errCode != 0` 作停机条件 ⇒ 重放一开始就被判「已失败」 | 重放前复位错误槽（`errCode = 0`），并清 `site`/失败帧残留（只清被 DEOPT 占用的字段） |
| P0-5 | `JitReport.cj:66` | 重放返回后不复查 `errCode`：重放里抛的 3/4/22 被当成成功值返回给宿主 | 重放后按三态重新分派：`0` → 值路径；`<0` 且 `-2` → `InterruptedException`；`>0` → `throwJit`；重放自身抛非仓颉异常仍兜底 99 |
| P0-6 | `base/CallContext.cj:41`；`JitFunction.cj:377-405` | `deadline` 字段存在但**没有任何调用入口**：`JitFunction` 只有 `call<T>(args)`，`RuntimeEnv.setDeadline` 仅测试调用 ⇒ `interrupt_poll` 的 −2 路径不可达 | 新增 `invoke<T>(args, options)`（**不引入 `tryInvoke`**）：`call` 委托 `invoke(args, CallContext())`；`options.deadline` 换算为纳秒写入 `RuntimeEnv`，`finally` 恢复外层值（重入安全） |

### P1（静默错算，9 条）

| ID | 位置 | 现状与根因 | 修法 |
| --- | --- | --- | --- |
| P1-1 | `compiler/Lexer.cj:766-767` | 词法算出了 `regexFlags`，构造 `Token` 时**没传** `flags:`，`Token.flags` 恒 0 ⇒ `r"..."i` 的 `i/m/s` 全部失效，`Lowerer.cj:1169` 读到的是 0 | 构造处补 `flags: this.regexFlags`；用例断言「同一 pattern 的 `i` 与非 `i` 行为不同」 |
| P1-2 | `compiler/Lowerer.cj:1253-1256, 1518` | `-` 恒发射 `ISUB/FSUB/DEC_SUB`；`+` 对两 String 走 `STR_CAT`。于是 `"a"-"b"` 变成数值减法（把句柄当整数）、`"a"*"b"` 同理 | `+` 保持 `STR_CAT`；`-`/`*`/`/`/`%` 在两侧或任一侧为 String 时 `diagFail`（类型不匹配，含字符位置）；一次判定集中在 `lowerBinary` 入口 |
| P1-3 | `compiler/Lowerer.cj:790-794` | 尾调用实参**逆序**直接写回形参槽：`rec(b, a)` 先把 `b` 写进 `p0`，再读 `a` 时已被覆盖 | 实参全部求值到临时槽（`allocSlot`），再按序 `STOREL` 到形参槽；临时槽随作用域释放 |
| P1-4 | `compiler/Parser.cj:1301-1308` | `else` 后无条件 `parseBracedExpr()`（要求 `{`），`else if` 在 `KwIf` 判定之前就语法错误 | 先判 `KwIf` → 递归解析 `if`；否则按块解析；`else` 后接表达式（非块）仍按既有拒绝面报错 |
| P1-5 | `compiler/Lowerer.cj:996-1000` | IIFE 调用后静态类型硬编码 `LocalType.I64`，忽略被调闭包的真实返回类型 ⇒ 返回 String/Any/Unit 的 IIFE 后续全错算 | 取 `closureRetType(this.lastClosureFnId)`（闭包字面量的已知签名）作为结果类型；未知时保守 `NONE` 并保持既有诊断 |
| P1-6 | `compiler/ClassRegistryView.cj:117-128` | `methodOf` 按名返回**首个**重载，`Lowerer` 随后按 arity/类型校验失败 ⇒ 同名不同参的方法不可用 | `methodOf` 增加 `argTypes` 形参（静态类型 + HostClosure 签名），按「元数 → 逐参精确 → 子类可上行」顺序选；多义 → 编译错误（消息列出候选）；无名匹配 → 既有「未注册方法」错误 |
| P1-7 | `bytecode/ConstRegistry.cj:181-201` | 常量键前缀 `f:` / `d…` / `t…` / `u…` / `r…` / `x…` 与运行期 `canonKeyOf` 的 `i:` / `s:` / `d:` / `t:` / `u:` / `r:` / `x:` 不同构 ⇒ 常量 Map 的 F64/Decimal/DateTime/Duration/Range/Regex 键**永不命中** | `tokenOf` 与 `canonKeyOf` 收敛到同一份前缀表（建议抽 `CanonKey.of(cell/obj)` 单点），并加「同值必同键、异值必异键」对拍用例 |
| P1-8 | `compiler/Lowerer.cj:883-909` | `lowerExprAs` 处理完 F64←I64 与 JSON 后**静默接受**任意 `expected ≠ actual`，既不转换也不报错 ⇒ 静态类型与运行期值不一致 | 末段补完备性判定：同型 / 已定义上行 / 已定义转换之外一律 `diagFail`（消息含 `期望 → 实际`）；新增用例覆盖每类被拒组合 |
| P1-9 | `compiler/Lowerer.cj:814-830, 3283-3289`；赋值路径 `lowerAssign` 同源 | 仅**声明初始化**走 `lowerInit` 装箱。两条路径漏箱：① 调用实参走 `lowerExprAs`，无「expected == 15 且实参是容器字面值」分支；② 赋值 `x = [ … ]`（`x` 已声明为 `List<Any>` / `Map<…,Any>`）走 `lowerAssign`，同样只按码 10/11 传递、丢失元素类型 ⇒ 裸元素直接进容器 | 抽出「按目标 TypeRef 装箱容器字面值」的单一函数：`lowerExprAs` 与 `lowerAssign` 都调用它；赋值路径需从 `VarSym` 保留声明的元素/键值类型（声明时写入，赋值时读取），验收断言「元素是 Any 盒 + 整盒一次」 |

### P2（资源与并发，6 条）

| ID | 位置 | 现状与根因 | 修法 |
| --- | --- | --- | --- |
| P2-1 | `runtime/HandleTable.cj:1004` | `fetchAnyBox` 只查 `alive` + `tag`，缺 `gens[i] != genOf(id)`；槽复用后**旧 ID 读到新盒** | 补 gen 校验，与 `fetchHostObject` 同构；用例：释放 → 复用 → 旧 ID 必 8 |
| P2-2a | `JitFunction.cj:429-439` | `IterTable.clearAll()` 只在测试里被调；调用结束不清理 ⇒ 条目与游标跨调用泄漏、陈旧游标仍可用 | 桥的 `finally` 增加 `IterTable.clearAll()`；位置在 `marshal.cleanup()` 之前 |
| P2-2b | `runtime/IterTable.cj:38-90` | `entries` / `gens` 是静态 `ArrayList`，无同步；并发调用（不同线程，`callMtx` 之外的重入路径）会撕裂 | 与 `HandleTable` 一致：静态 `mtx` + 每次读写加锁；`clearAll` 在锁内 |
| P2-3 | `JitFunction.cj:408-420`（主因）+ `runtime/HandleTable.cj:755-761`（配套） | 归还条件写死 `unboxCode >= STRING && <= HOST_OBJECT && != CLOSURE`（4–14）⇒ **15 与 16–19 落在条件外，逃逸槽永不归还**；`release` 对逃逸槽也不复位 `escapeFlags`/不归还 `freeSlots`，即使同槽被复用也会残留 | 条件改为「按 `makeRetUnboxer` 的句柄型集合判定」（4–11、13–14、15、16–19，排除 12）；`release` 尾段补 `escapeFlags[i] = false` 与 `freeSlots.add(i)`；`resetWindow` 的逃逸保留语义不变 |
| P2-4 | `JitFunction.cj:278-297` | `callForFn` 直接读 `this.lastClosureGroup` 并新建包装，**没进** `callMtx`；与另一线程的 `call` 竞争同一 `lastClosureGroup` | `callForFn` 整体进 `synchronized(JitFunction.callMtx)`；`lastClosureGroup` 改为「本次调用返回、取完即清」，避免跨调用残留 |
| P2-5 | `backend/A64Emitter.cj:411, 419` | `ldrOff` / `strOff` 直接用 `off & 0x1FF` 编码，不检查 `-256..255` ⇒ 越界偏移静默回绕，读写错地址 | 入口处判范围：界内走原 immediate 形式；越界走慢路径（`movImm64` 算地址 + 0 偏移形式），复用 emitter 既有 scratch 寄存器 |
| P2-6 | `runtime/AnyHelpers.cj:64-66, 93` | H80 的分配分支不走窗口（`ctx` 被 `let _ = unused` 丢掉），`hwTop` 记账失真、容量触顶永不触发 | 14 与容器/字符串等句柄型分支统一走 `append*`（计入 `windowSlots`）；H79 保持纯读零分配 |

### P3（文档与矩阵失真，5 条）

| ID | 失真点 | 回写动作 |
| --- | --- | --- |
| P3-1 | **helper 编号整表错位**：`design-m3.md`、`jit-bytecode-m3.md`、`plan-m3.md` 与 m1 镜像仍写 H66–H68 / H73–H75；代码与最终规格是 H78–H80 / H81–H83（73–76 已是 datetime/duration） | 三份文档 + m1 镜像统一替换为 H78–H83；补一节「编号为何顺延」（66–68 保留位、73–76 被占用、77 = cast_fail）；验收：`doc/*.md` 中 `H66–H68|H73–H75` 零命中 |
| P3-2 | **三条已被推翻的表述仍写在「当前规则」里**：① 二次装箱 = 编译错误（D12 改为同型零动作直传）；② `{ "a" : 1 }` = 语法错误（D15 改为 M1 映射字面量）；③ `jit-bytecode-m3.md` §2 同文写「16–255 仍拒绝」又写「0–19 合法」 | 三条逐处改写，并在原文位置加「（D12/D15 已推翻）」锚点；验收：三条表述在「当前规则」章节零命中，只在历史/裁定记录里出现 |
| P3-3 | **`json_set` 值域不一致**：规格写「值型 0–3（Unit 除外）/ String / JSON 节点」，前端把 Float64 变量放行，运行期以 **8** 拒绝；字面量 `1.5` 是 Decimal，编译期先报「不在值域」 | 二选一并统一：① 值域收窄为 Int64/Bool/String/JSON（Float64 编译期拒绝）；② 运行期接受 Float64。建议 ①（与 JSON 数字模型一致）；验收：Float64 变量路径有用例，错误码/诊断与规格一致 |
| P3-4 | **验收矩阵虚报**：T48/T51 空容器用例恒 `errCode=4` 却记 `full`；「四类插入点」③返回位置无正向用例（同名用例断言的是零装箱）；只读字段写实现/用例是 **20**，规格与注释写 **19**；M3 三引擎全等**零证据**（15 处 `DiffSession` 无一用 `M3_MAJOR`） | 四件事分别处置：T48/T51 降 `partial` 或补成功路径；③ 补 `returnPositionBoxesIntoAny` 或修订规格；只读字段口径定为 20 并回写规格/注释；补 `m3AnyJsonIsTripleEqual`（Interp × Native 四元组） |
| P3-5 | **`doc/spec/` 产物缺件（自检发现，非审查项）**：`f-jit-m3` 与 `f-jit-m2.1–m2.3` 只有 `specs/`，缺 `proposal.md` / `design.md` / `tasks.md` | 按既有 `jit-bytecode-mN.md` / `design-mN.md` / `plan-mN.md` 反写三件套（只写已发生事实，不补造过程） |

## 3 关键决策

> 2026-10-21 用户批准：D1 按「aux 承载 `$as$<C>` id」实施（补一条 helper 重入红用例）；D3 **只新增 `invoke`，不引入 `tryInvoke`**；D6 按「String 算术编译错误」实施。

### D1 14 目标的类界：`aux` 承载 `$as$<C>` 的 helper id（采纳）

- **做法**：`lowerAnyIs` / `lowerAnyCast` 在目标类型为 14 时，把 `aux` 从恒 `0xFFFF` 改为「`$as$<C>` 的用户 helper id」（`HelperCodec.hidOfSlot(slot)`，16 位）。H79/H80 读到非 `0xFFFF` 的 aux 时，先 `fetchHostObject` 取对象再调该 helper 判类；`$as$<C>` 由 `ReflectRegistrar` 在注册期合成（`ReflectRegistrar.cj:357-365`），子类实例命中。
- **为什么**：`$as$<C>` 已是 14 型 `is`/`as` 的既有判定通道（`Lowerer.cj:2508-2515`），复用它不引入新的执行机制、不破坏「执行路径零反射」的既有约束（判定体在注册期绑定），且 `aux` 的 14 编码本来就未使用。
- **备选（否决）**：① 在 H80 之后追加 `$as$<C>` + 分支跳转 —— 需要在字节码里发 `DUP/JZ/err_raise`，`is` 侧还要再改一遍，产物形态变复杂且难对拍；② 把类名做成运行期 typeRef 表 —— 需要新增每单元类型表 + 加载期装配，等于改格式。
- **拒绝面**：`aux` 指向的 `$as$` 槽不存在 → 编译错误（与 `is` 现有行为一致），不进运行期。

### D2 15/16–19 的宿侧可达：只在 `localTypeOf` 补行，不动 `CallMarshal` 表

`CallMarshal` 的行已是正确的（12/13/14/15/4–11/16–19），缺的是 `T` 侧映射。补 `localTypeOf` 即可让 8 行全部可达；`makeRetUnboxer` 不改，避免同一语义两处实现。

### D3 deadline：`RuntimeEnv` 的栈式保存/恢复，而不是「每次调用前覆盖」

`callMtx` 只串行化顶层调用，同一线程的重入（闭包内再调 JIT）不受锁约束；直接 `setDeadline` 会把外层 deadline 覆盖掉。因此 `invoke` 取「保存旧值 → 写入 → `finally` 恢复」。`deadline = None` 写入 `-1`（既有「无期限」约定）。**不新增 `tryInvoke`**：错误语义与 `call` 完全一致（>0 抛 `JitException`、−2 抛中断），避免多一套「吞错」API。

**A3.5 补充裁定（`strictFp` / `literalCopy`）**：实测前端对 `Float64` 的 `/` 恒发射 `FDIV`（0x43），
**从不发射 `FDIV_CHK`（0x44）**；`strictFp` 只写 `ctx.flags` bit0，无任何运行期读取点。两者统一
登记为**未接线**（`strictFp` 保留 flags 写入、`literalCopy` 无消费点），不新增「看起来已接线」的
第三态；`CallContext` 类注释与 `a3_5_strictFpDoesNotChangeFdivChk`（`÷0 → +Inf`，与开关无关）为准。

### D4 重放的三态：把 `finish` 改成两段式

`finish` 内部顺序固定为：判 `DEOPT` → 复位错误槽 → 重放 → **重新读** `ctx.errCode` → 按三态分派。重放抛出的 `JitException`/`InterruptedException` 原样透传（既有契约），其余异常兜底 99。

### D5 常量键：抽单点而不是两边各改一遍

`ConstRegistry.tokenOf` 与 `HandleTable.canonKeyOf` 是同一契约的两处实现，本轮抽 `CanonKey`（bytecode 侧只依赖字符串规范化，不引入 runtime 依赖），两边都调它。这样 P1-7 的「同值同键」有单一事实来源，后续新增常量类型不会再漂移。

### D6 P1 里唯一的「拒绝而非修复」：String 算术

`-` / `*` / `/` / `%` 对 String 没有语义定义，本方言也不打算定义；静默当数值算是**最坏的错**。改为编译错误，并把该组合登记进禁止面用例集（与 M3 §3 的「15 型禁止面」同一清单风格）。

## 4 分批与顺序

| 批次 | 内容 | 依赖 | 目的 |
| --- | --- | --- | --- |
| A0 | 基线：跑 M1+M2+M3 全量，留档用例数/通过数/耗时 | — | 后续对照 |
| A1 | P0-3 / P0-4 / P0-5（栈纪律 + 重放三态） | A0 | 最独立，先让「错算」变「报错」 |
| A2 | P0-1（H80 14 + tag + 窗口）→ P2-6 / P2-1 / P2-3（同一文件的资源面） | A1 | 一个文件一次改到位，减少来回 |
| A3 | P0-2 → P0-6（桥的入参/出参与调用入口） | A2 | 桥侧一次改完再跑全量 |
| A4 | P1-1 / P1-4 / P1-3 / P1-5 / P1-6 / P1-8 / P1-9 / P1-2（前端逐条） | A1 | 每条独立可回退，顺序按「词法 → 语法 → 类型 → 降低」 |
| A5 | P1-7（常量键）+ P2-2（IterTable） | A1 | 互不相干，可并行 |
| A6 | P2-4 / P2-5（并发与后端） | A3 | 后端慢路径要单独跑机器码对拍 |
| A7 | P3 五条回写 + 全量三档回归 | A1–A6 | 文档必须落在实现之后，否则又是失真 |

**硬顺序**：A0 必须先跑；A7 必须最后；A2 内部 P0-1 先于 P2-6（同一函数的两次改动合并成一个提交）。

## 5 测试策略

1. **每条缺陷一个红用例**：命名 `缺陷<ID>_<现象>`（如 `p0_1_asHostClassReturnsTag11`），放在被测文件的同目录 `*_test.cj`。
2. **对拍优先**：涉及双引擎的（P0-3、P0-6、P2-5）一律「解释器 ≡ 机器码」逐位对拍；机器码不可用按既有条件跳过但必须留 `hit` 记录。
3. **假绿升级**：凡审查标记为「结构断言」的既有用例（T40/deopt-replay 等），改为断言返回值/错误码，不再只断言 `TCase.hit`。
4. **资源类断言**：P2 全部要 `windowUsed()` / `IterTable.liveCount()` / `freeSlots` 长度的前后对账，避免「看起来没漏」。
5. **每批末**：M1+M2+M3 全量 + 差分最小集；数字写入 `verify.md`。

## 6 风险与回退

| 风险 | 影响 | 处置 |
| --- | --- | --- |
| `aux` 语义扩展被外部产物依赖 | 旧产物里 14 的 `aux` 恒 `0xFFFF`，新读法向下兼容；反向（新产物在旧加载器）不成立 → **必须同版本更新**，在变更说明里写明 | 加载器不校验 aux，仅运行期解释；文档标注「同版本自洽」 |
| `release` 归还逃逸槽后旧 ID 复用 | 若某处依赖「逃逸槽永不复用」，会读到别人的对象 | gen 校验（P2-1）保证旧 ID 必 8；用例覆盖「释放→复用→旧 ID」 |
| `lowerExprAs` 收紧后大量既有单元编译失败 | 表面是回归，实为暴露既有错算 | 先在全量里统计失败面，逐条判「该修调用点」还是「该放松判定」；不得为刷绿而回退判定 |
| `invoke` 新增公开 API | 用户面扩大 | `call` 保持原签名与语义；`invoke` 只做参数透传，不改变封送/解包 |
| A64 慢路径寄存器压力 | 编码序列变长，跳转偏移需重算 | 慢路径只在越界时触发；两遍布局已支持变长序列 |

**A2 实施中新增的必要修复（记录，不属于原 26 条）**：`CompilePipeline.runSource` 把 `verMajor`
硬编码为 `M2_MAJOR`（LocalType 合法集 0–14），因此公开 `Compiler.compile` **完全编不了 `Any`**
（报「局部槽类型码非法: 15」）——M3 的 Any 通道只在测试直连 `SourceCompiler` 时可用。A2 的
端到端验收必须走公开入口，故改为 `M3_MAJOR`（M3 是 M2 的超集，既有 M2 用例全量通过）。

## 7 文档回写清单

- `f_jit/doc/jit-bytecode-m3.md`：§5 类型描述符（14 的 aux）、§8 兼容矩阵、§11 helper 表（H78–H80 的 tag / 窗口 / 失败码）。
- `f_jit/doc/design-m3.md`：H80 的 14 判定、窗口记账、deadline 接线口径、`strictFp`/`literalCopy` 的真实状态。
- `f_jit/doc/plan-m3.md`：R4.1–R4.3 的验收判据改为语义断言；新增本次 26 条的登记。
- `f_jit/doc/spec/f-jit-m3/**`、`f_jit/doc/spec/f-jit-m2.1–m2.3/**`：补 `proposal.md` / `design.md` / `tasks.md`（P3-5）。
- 根 `README` / `docs/`：若含 f_jit 能力矩阵，按本变更订正。
