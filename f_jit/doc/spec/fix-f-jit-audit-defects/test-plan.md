# A0.2 缺陷 → 用例清单（26 条）

> 规则：每条缺陷至少一个**先红**用例；断言必须命中行为（返回值 / 错误码 / site / 资源账目），
> 不得只断言 `TCase.hit` 或产物里「出现过某指令」。P3 为文档/矩阵项，用命令级验收。

| ID | 红用例名 | 断言要点 | 对应任务 |
| --- | --- | --- | --- |
| P0-1a | `p0_1_asHostClassRespectsClassBoundary` | `as A` 命中、`as 父类` 命中、`as 无关类` 22、`as 子类` 22；`is` 同构；成功句柄 tag=11 | A2.2/A2.3 |
| P0-1b | `p0_1_asHostClassReturnsTag11` | `as A` 返回句柄 `tagOf == HOST_OBJECT`，`getAs` 取回同一对象；不再 8/12 | A2.2 |
| P0-2 | `p0_2_callAnyAndJsonAreReachable` | `call<Any>` 取回原生对象；`call<JsonObject/JsonArray/JsonNull>` 取回节点；逐个 `T` 的 `unboxCode` 与解包表一致 | A3.1/A3.2 |
| P0-3 | `bnotInvertsAndPopsOperand` | `~5=-6`、`~(-1)=0`、`~7=-8`、`~5+1=-5`（栈不残留） | A1.1 |
| P0-4 | `p0_4_replayResetsErrorSlot` | `errCode=DEOPT` 后重放 `PUSH 42; RET` 返回 42 且 `errCode=0` | A1.3 |
| P0-5 | `p0_5_replayErrorIsRethrown` / `p0_5_replayInterruptThrows` | 重放体内 4 → `JitException(4)`；`-2` → `InterruptedException` | A1.4 |
| P0-6 | `p0_6_deadlineInterruptsLoop` / `p0_6_nestedInvokeRestoresDeadline` | 过期 deadline 在 `LOOP_BACK` 返回 −2；内层无期限调用后外层恢复 | A3.3 |
| P1-1 | `p1_1_regexFlagsSurviveLexing` | `r"AbC"i` 命中 `abc`、无 `i` 不命中；`m`/`s` 各一例；`Token.flags` 逐位 | A4.1 |
| P1-2 | `p1_2_stringArithmeticIsCompileError` | `"a"-"b"`、`*`、`/`、`%`、`"a"-1` 逐条编译错误（含位置）；`+` 仍拼接 | A4.8 |
| P1-3 | `p1_3_tailRecursionSwappedArgs` | `rec(b,a)` 与手写循环结果一致；实参左→右求值后统一写槽 | A4.3 |
| P1-4 | `p1_4_elseIfParses` | `else if` 三臂与嵌套 `if` 逐位等价；`else` 接非块仍报错 | A4.2 |
| P1-5 | `p1_5_iifeUsesClosureReturnType` | 返回 String 的 IIFE 可 `.size`；Any/JSON/Unit 各一例；未知签名报错不静默 | A4.4 |
| P1-6 | `p1_6_instanceOverloadByArgTypes` | 同名 `f(Int64)`/`f(String)` 各命中；多元数；多义编译错误；子类上行 | A4.5 |
| P1-7 | `p1_7_constMapFloatDecimalKeysHit` | `Map<Float64,…>`/`Map<Decimal,…>` 常量键运行期命中；同值同键、异值异键 | A5.1 |
| P1-8 | `p1_8_lowerExprAsRejectsUnconvertible` | `Int64→String`、`String→Int64`、`Bool→Int64`、`14→值型` 逐个 `diagFail`（含期望→实际） | A4.6 |
| P1-9 | `p1_9_listAnyBoxesOnAssignAndArg` | 实参 / 赋值 / 整体 Any 三路径：元素是 Any 盒、整盒一次、装箱数 = 元素数 + 1 | A4.7 |
| P2-1 | `p2_1_fetchAnyBoxChecksGeneration` | 释放→复用→旧 ID 必 8 | A2.6 |
| P2-2 | `p2_2_iterTableClearedPerCall` / `p2_2_iterTableConcurrentSafe` | 调用结束 `liveCount=0`；旧游标 99；并发不撕裂 | A5.2/A5.3 |
| P2-3 | `p2_3_escapedAnyJsonSlotsReleased` | 15 与 16–19 各 1000 次返回后 `windowUsed`/表长不增长 | A2.7 |
| P2-4 | `p2_4_callForFnSerialized` | 两线程各自 `callForFn`，提升组互不干扰；`lastClosureGroup` 不残留 | A6.1 |
| P2-5 | `p2_5_a64Imm9SlowPath` | 偏移 −256/255 走立即数，−257/256 走慢路径；执行结果 ≡ 解释器 | A6.2/A6.3 |
| P2-6 | `p2_6_anyAsCountsWindow` | 容量 N 下第 N+1 次 `any_as` 命中报 16；`windowUsed` 与命中数一致；H79 零分配 | A2.5 |
| P3-1 | 命令级 | `grep -rn "H66–H68\|H73–H75" f_jit/doc` 零命中 | A7.1 |
| P3-2 | 命令级 | 三条推翻表述在「当前规则」章节零命中 | A7.2 |
| P3-3 | `p3_3_jsonSetFloat64Domain` | Float64 变量路径的诊断/错误码与规格一致（二选一后不再有第三态） | A7.3 |
| P3-4 | 命令级 + 用例 | `check_scenarios m3` 无虚报 full；`returnPositionBoxesIntoAny`；只读字段写 20；`m3AnyJsonIsTripleEqual` | A7.4 |
| P3-5 | 命令级 | 四个 `doc/spec/` 目录四件套齐全 | A7.5 |
