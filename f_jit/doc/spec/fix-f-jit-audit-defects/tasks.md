# Tasks

> 编号前缀 `A`（Audit），与 M1（S）/ M2（Q）/ M3（R）不复用。
> **每条任务按 TDD 执行**：先写会失败的用例（红）→ 最小实现（绿）→ 重构；用例由红转绿才勾选。
> **每批末验收**：对应目录 `cjpm build` 通过、`cjpm test` 新增用例全绿、M1 + M2 + M3 全量零回归、失败数 0。
> **构建口径**：沿用既有结论，在 `f_jit` 模块内独立 `cjpm build` / `cjpm test`；不登记根 `cjpm.toml`。
> **假绿禁令**：审查标记为「结构断言」的既有用例必须就地升级为返回值/错误码断言，不得新增只断言产物形态的用例来「覆盖」缺陷。

## A0 基线

- [x] A0.1 三档回归基线：跑 M1（plan-m1 §7）+ M2（Q6）+ M3（R6）全量含差分，记录用例数 / 通过数 / 失败数 / 耗时；验收：数字留档，作为后续每批对照。**（2026-10-21：1026 / 1026 / 0，53 s）**
- [x] A0.2 缺陷用例清单化：把 26 条逐条落成「用例名 → 断言语义」清单（先只登记，不写实现）；验收：26 条每条有唯一用例名，且清单里不存在只断言 `TCase.hit` 的条目。**（`test-plan.md`，26 行）**

## A1 栈纪律与重放三态（P0-3 / P0-4 / P0-5）

- [x] A1.1 `BNOT_I` 栈纪律：先写失败用例——`~0` = `-1`、`~(-1)` = `0`、`~7` = `-8`；执行前后栈深度差 = −1（弹 1 压 1 净零）；再修 `Interp.cmpOp` 的一元分支；验收：解释器结果与 `A64Lower` 逐位一致，栈不残留。**（`bnotInvertsAndPopsOperand`：`~5=-6`、`~(-1)=0`、`~7=-8`、`~5+1=-5`）**
- [x] A1.2 一元 `NOT` 与二元位运算不受影响：先写失败用例——`NOT`（0x5E）仍弹 1 压 1、`AND/OR/XOR/SHL/SHR/USHR` 仍弹 2 压 1；再确认 `one` 判定拆分后无回归；验收：0x50–0x6E 全表栈纪律不变
- [x] A1.3 DEOPT 重放前复位错误槽：先写失败用例——构造 `errCode = DEOPT` 后重放一个只做 `PUSH_I64 42; RET` 的函数，断言返回 42 且 `ctx.errCode == 0`；再在 `JitReport.finish` 的 DEOPT 分支复位 `errCode`（含 `site` 残留）；验收：重放不再被解释器判为「已失败」。**（红→绿：`p0_4_replayResetsErrorSlot`；实现见 `JitReport.finish` 两段式）**
- [x] A1.4 重放失败复查：先写失败用例——重放体内 `DIV_ZERO`，断言宿主收到 `JitException(4)` 而不是把 cell 当返回值；重放体内 `interrupt_poll` 到期，断言 `InterruptedException`；再补重放后的三态分派；验收：0 / −2 / >0 三条出口均可构造到。**（`p0_5_replayErrorIsRethrown` / `p0_5_replayInterruptThrows`）**
- [x] A1.5 重放异常兜底不回退：先写失败用例——重放抛出非 `JitException` 的宿主异常，仍为 99 且 `cause` 保留；再确认既有 `replayFailureBecomes99` 语义不变；验收：99 与 4/22 严格区分

## A2 H80 的 14 目标与句柄表资源（P0-1 / P2-6 / P2-1 / P2-3）

> **本批附带修复（A2 验收时暴露）**：`CompilePipeline.runSource` 原固定 `verMajor = M2`（合法集 0–14），
> 公开 `Compiler.compile` 因此完全编不了 `Any`（`局部槽类型码非法: 15`）——M3 的 Any 通道只在
> 测试直连 `SourceCompiler` 时可用。已改为 `M3_MAJOR`（`CompilePipeline.cj`，附注释）。

- [x] A2.1 `HandleTable.appendHostObject`：先写失败用例——同一对象两次 append 返回同 ID；tag 为 `HOST_OBJECT`；`windowUsed()` 递增 1；`resetWindow` 后非逃逸槽释放；再写 append 系实现（复用 `append` + 同对象去重）；验收：与 `pinHostObject`（桥侧）行为差异只在窗口记账，且有对拍用例**（`appendHostObjectSharesWindowAccounting` / `appendHostObjectDiffersOnlyInWindow`；实现抽出 `appendLocked` 以避开 `Mutex` 不可重入）**
- [x] A2.2 H80 的 14 分支换 tag：先写失败用例——`as C` 命中返回的句柄 `tagOf == HOST_OBJECT`（当前为 `CALL_CONTRACT(8)` 或 tag 12）；未命中仍 22；再改 `AnyHelpers.anyAs` 的 `case _` 到显式 `case 14u16`；验收：tag 11 且 `getAs(id, HOST_OBJECT)` 可取回同一对象**（`p0_1_asHostClassReturnsTag11`：红态 errCode=19 → 绿态 tag=11、`getAs` 同对象、窗口 +1）**
- [x] A2.3 H79/H80 的类界判定（D1）：先写失败用例——盒装类 A 实例，`as B`（无关类）必 22、`as A` 命中、`as A父类` 命中、`as A子类` 必 22；`is` 侧同构；再按 `aux` 承载 `$as$<C>` helper id 实现；验收：类界与 `is C`（非 Any 路径）逐例一致**（runtime `p0_1_asHostClassRespectsClassBoundary` 覆盖委托契约；根包 `p0_1_asHostClassRespectsClassBoundary` / `p0_1_anyIsMatchesNonAnyIs` 用真实注册类；红态 `is ReflectAdmin` 对 `ReflectUser` 误答 true）**
- [x] A2.4 前端发射 `aux`：先写失败用例——`as C` / `is C`（左为 15）的产物里 `aux` = `$as$C` 的 helper id，而非 `0xFFFF`；目标非 14 时 `aux` 不变；`$as$` 槽缺失 → 编译错误；再改 `Lowerer.auxOf` / `lowerAnyCast` / `lowerAnyIs`；验收：产物逐指令可断言，且三引擎执行结果一致**（`p1_4_auxCarriesAsHelperId` / `p1_4_nonHostTargetsKeepMaxAux` / `p1_4_missingAsHelperIsCompileError`；`auxOf` 改为实例方法并接收 `pos`/`opName` 以给出可定位诊断）**
- [x] A2.5 H80 窗口记账（P2-6）：先写失败用例——循环 `as List<Any>` 触顶（`hwCap`）第 N 次必报 16；`windowUsed()` 与命中次数一致；再让 14 与句柄型分支统一走 `append*`；验收：`hwTop` 记账与 H78 一致，H79 仍零分配**（`p2_6_anyAsCountsWindow`：capacityLimit 卡到基线+2，第 3 次报 16；H79 ×1000 表长与 `windowUsed` 均不变）**
- [x] A2.6 `fetchAnyBox` gen 校验（P2-1）：先写失败用例——释放盒 → 复用同槽 → 旧 ID 必 8（`HANDLE_TYPE`）；再补 `gens[i] != genOf(id)`；验收：与 `fetchHostObject` 同构**（`p2_1_fetchAnyBoxChecksGeneration`：红态 errCode=0（读到新盒）→ 绿态 8）**
- [x] A2.7 逃逸槽归还（P2-3）：先写失败用例——分别返回 15 与 16–19，各 1000 次调用后 `windowUsed()`/表长不增长（当前 15/16–19 落在 `JitFunction.cj:408` 的 4–14 条件外，必泄漏）；再扩归还条件为句柄型集合，并让 `release` 尾段复位 `escapeFlags` 且归还 `freeSlots`；验收：4–14 既有行为不变，`resetWindow` 仍保留未释放的逃逸槽**（`releaseReturnHandle` / `isReturnedHandle` 抽出为可测函数；`p2_3_escapedAnyJsonSlotsReleased` 五种返回码各 1000 轮后表长 = 基线+1；`releaseReclaimsEscapedSlot` 断言槽位复用与世代 +1）**

## A3 桥的入参、出参与调用入口（P0-2 / P0-6）

- [x] A3.1 `localTypeOf` 补 15/16–19：先写失败用例——`call<Any>`、`call<JsonValue/JsonObject/JsonArray/JsonNull>` 不再抛「T 不是可解包类型」；`T=Int64` 等既有行不变；再补四行映射；验收：与 `CallMarshal.makeRetUnboxer` 的行一一对表（逐个 T 断言 `unboxCode`）**（`localTypeOf` 补 5 行（15 + 16–19），`codeOfTypeName` 同步以免闭包签名把 Any 误记 14；红态 6 条新用例全报「T 不是可解包类型」）**
- [x] A3.2 `retType=15` 端到端：先写失败用例——函数返回 `Any`，宿主 `call<Any>` 拿回原生对象（不是盒句柄）；`retType=16–19` 返回 JSON 节点时同上且 tag 走 11 例外行；再确认逃逸/拆盒/归还顺序；验收：同一对象身份往返、无泄漏**（`p0_2_callAnyIsReachable`：Int64 原生值 + 同一 ReflectUser 对象；`p0_2_callJsonReturnsAreReachable`：Object/Array/Value 三型；两者各 200 次调用后 `liveCount` 不变）**
- [x] A3.3 `invoke` 接线 deadline（D3）：先写失败用例——`invoke(args, CallContext(deadline = 过去时刻))` 在 `LOOP_BACK` 处返回 −2 → `InterruptedException`（当前不可达）；`deadline = None` 不受影响；重入时外层 deadline 在返回后恢复；再写入口 + `RuntimeEnv` 栈式保存/恢复；验收：`call` 等价 `invoke(args, CallContext())`，既有调用零变化**（`p0_6_deadlineInterruptsLoop` / `p0_6_deadlineRestoredAfterCall`；`RuntimeEnv.deadlineNanosOf` 做 `?DateTime → 纳秒`，极端值退化 ±哨兵）**
- [x] A3.4 `invoke` 三态与 `call` 逐位一致：先写失败用例——正常值、`>0` 错误码、`−2` 三条出口各一例，断言 `invoke(args, CallContext())` 与 `call(args)` 的结果/错误码/site 完全相同；再确认 `call` 是薄委托（无重复逻辑）；验收：两入口对拍零差异**（`a3_4_invokeMatchesCall`：结果相等 + `DIV_ZERO` 的 code/site 逐位相等；`call` 已改为单行委托）**
- [x] A3.5 `strictFp` / `literalCopy` 口径确认：先写失败用例——`options.strictFp = true` 是否影响 `FDIV_CHK`（当前实现）；再决定「接线」或「文档标注未接线」；验收：文档口径与实现一致（不留下第三态）**（实测：前端对 Float64 的 `/` **恒发 `FDIV`（0x43）**、从不发 `FDIV_CHK`；`strictFp` 只写 `ctx.flags` bit0 且无读取点 ⇒ `÷0` 恒 `+Inf`。裁定「未接线」：`strictFp` / `literalCopy` 均登记为无消费点占位，`CallContext` 类注释与 `a3_5_strictFpDoesNotChangeFdivChk` 双双落定）**

## A4 前端逐条纠偏（P1-1 … P1-9）

- [x] A4.1 正则 flags（P1-1）：先写失败用例——`r"AbC"i` 命中 `"abc"`，无 `i` 不命中；`m` / `s` 各一例；`Token.flags` 逐位断言；再补词法构造的 `flags:`；验收：`Lowerer.cj:1169` 读到的 flags 与源码一致**（根因：`Lexer.scanRegex` 构造 Token 时漏传 `flags: bits` ⇒ 恒 0。用例：`p1_1_regexFlagsSurviveLexing`（i/m/u/imu 四位逐位）+ `p1_1_regexFlagsAffectMatching`（`/AbC/i ~ "abc"`=1、无 i=0、`/^b/m` 多行命中）；注意操作数序是 `/re/ ~ s`）**
- [x] A4.2 `else if`（P1-4）：先写失败用例——`if (a) {} else if (b) {} else {}` 编译通过，三臂语义与嵌套 `if` 逐位等价；`else` 后接非块表达式仍报错；再改 `Parser` 的 else 分支；验收：AST 形态与「嵌套 if 等价物」一致**（`Parser.parseIfExpr` 原先无条件先 `parseBracedExpr`，`while` 死代码；改为先判 `KwIf` 再取块、递归下降。`p1_4_elseIfParses` 覆盖语句/值用法 × 三臂）**
- [x] A4.3 尾递归实参（P1-3）：先写失败用例——`fn rec(a, b) { if ... rec(b, a) }` 与手写循环结果一致；`rec(b, a)` 中 `a`/`b` 的实参不互相覆盖（构造 `a` 与 `b` 值不同且实参顺序反转的用例）；再改临时槽求值；验收：实参求值顺序为左→右，且形参槽写入在全部求值之后**（`p1_3_tailRecursionSwappedArgs`：`return recursive(b, a-1)` 的 `(2,7)→5`、`(4,3)→0`；红态为 0。注意必须用 `return` 语句，尾表达式不走该优化）**
- [x] A4.4 IIFE 返回类型（P1-5）：先写失败用例——`(fn() { "x" })()` 静态类型为 String 并可继续 `.size`；返回 `Any` / JSON / Unit 的 IIFE 各一例；再取真实闭包返回类型；验收：未知签名时保守 `NONE` 且报错不静默**（`lowerExpr` 的 IIFE 分支改取 `closureRetOf(fnId)`，未登记即 `diagFail`；同时把「返回位置」的期望类型改为不校验、以实际产物回填 `retType`（`staticTypeOfTop` 的浅层推断会把 `{ => s }` 误判 I64）。`p1_5_iifeUsesClosureReturnType` 用带注解绑定断言 String/Int64/Bool 三型）**
- [x] A4.5 实例方法重载（P1-6）：先写失败用例——同一类 `f(Int64)` 与 `f(String)` 按实参类型各命中；元数不同各命中；多义 → 编译错误（消息含候选）；子类实参上行到父类形参命中；再改 `methodOf`/`requireMethod` 签名与选择顺序；验收：与 `ctorsOf` 的重载解析口径一致**（新增 `ClassRegistryView.methodsOf` + `Lowerer.resolveMethod`：名字→元数→实参码三重过滤；0 候选/多候选都 `diagFail` 并列出候选签名。用例断言 hid 256/257/258；歧义/无匹配/元数三态各一条。14 位置按码相等放行——快照只带码，具体类由运行期封送校验）**
- [x] A4.6 `lowerExprAs` 完备性（P1-8）：先写失败用例——`Int64 → String`、`String → Int64`、`Bool → Int64`、`List<Int64> → List<Any>`（未装箱路径）、`14 → 值型` 等组合逐个 `diagFail`（消息含「期望 → 实际」）；既有 F64←I64 与 JSON 收窄仍通过；再补末段判定；验收：每类被拒组合一条用例**（末段 `actual != expected` 即 `diagFail`；补齐 JSON 17/18/19→16 的码级上行（零动作），避免误伤既有 `let v: JsonValue = \`{...}\`` 用例。`p1_8_lowerExprAsRejectsUnconvertible` 覆盖 4 个拒绝面 + 2 个合法面）**
- [x] A4.7 `List<Any>` 装箱三路径（P1-9）：先写失败用例——① 实参 `f(xs: List<Any>)` 以列表字面值调用；② 赋值 `x = [1,2]`（`x` 已声明 `List<Any>`）；③ `f(a: Any)` 传 `List<Int64>` 整体装箱；断言盒内元素是 Any 盒（`any_is(元素, …)` 命中）、装箱次数 = 元素数 + 1、无重复求值；再抽「按目标 TypeRef 装箱容器字面值」单一函数，`lowerExprAs` 与 `lowerAssign` 共用，`VarSym` 保留元素/键值类型；验收：三路径产物与 `lowerInit` 逐位同构**（复用既有 `lowerInit`：`lowerAssign` 的 Var 分支改传 `sym.elemTy/keyTy`；IIFE 实参改按 `lambda.params[i].typeAnn` 走 `lowerInit`。`p1_9_listAnyBoxesOnAssignAndArg`：赋值 2 次 H78、IIFE 实参 2 次、整体 Any 1 次。边界：**注册函数（user helper）形参只带类型码**，其 `List<Any>` 实参无法识别元素类型 → 不装箱；已在 design 记为已知边界）**
- [x] A4.8 String 算术拒绝面（P1-2 / D6）：先写失败用例——`"a"-"b"`、`"a"*"b"`、`"a"/"b"`、`"a"%"b"`、`"a"-1` 逐个编译错误（含位置）；`"a"+"b"` 仍走 `STR_CAT` 且结果正确；再改 `lowerBinary` 入口判定；验收：拒绝面清单并入 M3 §3 的禁止面用例集**（`rejectStringArithmetic`：`- / %` 见 String 即拒；`*` 仅两侧都 String 拒（`s*n` 仍是 STR_REPEAT）。`p1_2_stringArithmeticIsCompileError` 五条拒绝 + `+`/`*n` 两条合法）**

## A5 常量键与迭代器表（P1-7 / P2-2）

- [x] A5.1 规范键单点（D5）：先写失败用例——`Map<Float64, Any>` / `Map<Decimal, …>` / `Map<DateTime, …>` / `Map<Duration, …>` / `Map<Range<Int64>, …>` / `Map<Regex, …>` 的常量键在运行期 `get` 必命中；同值不同写法必同键、异值必异键；再抽 `CanonKey` 并让 `tokenOf` 与 `canonKeyOf` 都调它；验收：跨类型键全部命中，且 `i:`/`s:` 既有行为不变**（新增 `bytecode/CanonKey`：`i64/cell/f64/str/dec/decFromText/dateTime/duration/range/regex`；`ConstRegistry.tokenOf` 与 `HandleTable.canonKeyOf` 全部改调它。**Float64 的真正根因**：常量表用 `f:<bits>`、运行期裸 cell 走 `i:<cell>` —— 值型键统一为 `CanonKey.cell`（Float64 常量键 ⇒ `i:<bits>`）。Decimal 走「去尾零 + 调 scale」归一（`1.5` ≡ `1.50`）。用例：`p1_7_constMapFloatKeysHit` / `p1_7_constMapDecimalKeysHit` / `p1_7_canonKeyIsSingleSource`（六类键两侧对拍 + 异值异键）。DateTime/Duration/Range/Regex 无字面量语法 ⇒ 只做键对拍，不做常量 Map 取数）**
- [x] A5.2 `IterTable` 生命周期（P2-2a）：先写失败用例——一次调用结束后 `IterTable.liveCount() == 0`；跨调用的陈旧游标用它必 99；再在桥 `finally` 加 `clearAll()`；验收：异常路径（抛错/中断/重放）也清零**（`JitFunction.callLocked` 的 `finally` 在 `marshal.cleanup()` 之后 `IterTable.clearAll()`，四条出口共用。用例：`p2_2_bridgeClearsIterTableAtCallEnd`（桥外开游标 → 跑一次无关调用 → liveCount=0 且旧游标 99）、`p2_2_iterTableClearInvalidatesCursor`）**
- [x] A5.3 `IterTable` 同步（P2-2b）：先写失败用例——多线程并发 `open/next/close` 不自增丢失、不越界；`clearAll` 与 `open` 竞争不死锁；再补静态锁；验收：并发用例在 `--repeat` 下稳定**（静态 `Mutex` 覆盖 open/next/key/value/close/clearAll/liveCount；`close` 补 idx 越界防御。`p2_2_iterTableConcurrentSafe`：4 线程 × 100 轮各自 open→遍历 8 项→close，结束后 liveCount=0）**

## A6 并发与后端（P2-4 / P2-5）

- [x] A6.1 `callForFn` 串行化（P2-4）：`callForFn` 整体移入 `callMtx`（改用锁内的 `callLocked`，避免重入死锁），取到 `lastClosureGroup` 后**立即置 None**。用例：`p2_4_lastClosureGroupIsCleared`（取完即清）、`p2_4_callForFnSerialized`（2 线程 × 20 轮各自取包装/调用/close，互不串组）
- [x] A6.2 A64 `imm9` 范围（P2-5）：`strOff/ldrOff` 增加 imm9 边界分支，越界改走 scratch（x16）慢路径并修正 `off & 0x1FF` 回绕。用例：`imm9OverflowUsesScratchRegister`（257/−257 两条、−256/255 单条、慢路径访问 imm12=0 且基址=x16）、`largeOffsetIsChunked`（8193 ⇒ 3 条 add + 访问）。注：8 字节对齐的 256 走 scaled imm12，不属缺陷面
- [x] A6.3 慢路径寄存器与跳转：scratch 取 x16（寄存器分配只用 x0–x15）；含条件分支的深帧函数端到端对拍。用例：`deepFrameExceedsImm9`（30 局部 + 前后向分支，机器码 495/435 与解释器一致）

## A7 文档回写与总验收（P3-1 … P3-5）

- [x] A7.1 helper 编号全表替换（P3-1）：先写「文档位置 → 正确编号」清单（design-m3 / jit-bytecode-m3 / plan-m3 / m1 镜像，逐行）；再统一替换 H66–H68→H78–H80、H73–H75→H81–H83，并补「编号顺延」说明；验收：`grep -rn "H66–H68\|H73–H75" f_jit/doc` 零命中**（替换 27 处：design-m3 / jit-bytecode-m3 / plan-m3 / plan-m1 / `doc/spec/f-jit-m1/design.md`；design-m3 新增 §5.0「编号为何顺延到 H78–H83」。验收口径限定为**规则文档**：变更自身文档（proposal/design/tasks/test-plan）必须保留旧编号以描述缺陷）**
- [x] A7.2 三条被推翻表述回写（P3-2）：二次装箱（改为同型零动作直传 + 盒不套盒）、`{ "a" : 1 }`（改为 M1 映射字面量）、`jit-bytecode-m3.md` §2 LocalType（16–255 与 0–19 二选一，统一为 0–19）；验收：三条在「当前规则」章节零命中，历史处标注 D12/D15**（design-m3:88/84、jit-bytecode-m3:47/85/58/192、plan-m3:71 逐处改写并标 D12/D15；`grep "16–255 仍拒绝\|→ 语法错误"` 仅余带「已作废/已推翻」的历史句）**
- [x] A7.3 `json_set` 值域收口（P3-3）：**已裁定并实施**——值域收窄为 Int64/Bool/String/JSON 节点，**Float64 编译期拒绝**（JSON 无二进制浮点）；前端 `checkJsonWriteValue`、运行期 `jsonValueOf` 注释、design-m3 / jit-bytecode-m3 三处口径一致。用例：`p3_3_jsonSetFloat64RejectedAtCompileTime` / `p3_3_jsonSetAcceptsValueDomain`
- [x] A7.4 矩阵诚实化（P3-4）：T48/T51 改为**逐条断言真值**（空列表读写 = 4、空 Map upsert = 成功路径）；新增 `m3AnyJsonIsTripleEqual`（Interp × Native，verMajor=3 产物）；H65 注释的 `19` 统一为 **20**。`returnPositionBoxesIntoAny` 按「方言无返回类型注解 ⇒ 第三插入点不可达」**修订口径**（不新增假用例）
- [x] A7.5 `doc/spec/` 产物补齐（P3-5）：为 `f-jit-m3`、`f-jit-m2.1`、`f-jit-m2.2`、`f-jit-m2.3` 各补 `proposal.md` / `design.md` / `tasks.md`（共 12 个文件，按既有 `design-mN.md` / `jit-bytecode-mN.md` / `plan-mN.md` 反写，文首标注「归档反写、不补造过程」）；验收：四个目录四件套齐全
- [x] A7.6 总回归与 `verify.md`：**已出具** `verify.md`——终态 1076 用例 / 1075 通过 / 0 失败 / 0 error（`PerfOverride_test` 负载下假失败，单跑通过）；26 条逐条落点表 + 已知边界
