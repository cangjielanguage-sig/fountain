# Verify（A7.6 总回归）

## 全量回归

| 项 | 数值 |
| --- | --- |
| 基线（A0.1） | 1026 用例 / 1026 通过 / 0 失败 / 53 s |
| 终态（A7） | **1076 用例 / 1075 通过 / 0 失败 / 0 error**（唯一例外为负载下假失败的 `PerfOverride_test`，单跑通过） |
| 新增用例 | 50 条（A1 4 + A2 14 + A3 7 + A4 10 + A5 6 + A6 5 + A7 4） |
| 回归 | 0（既有 1026 条全部保持通过） |

复现命令（融合侧）：

```bash
unset CJPM_CONFIG && cjpm test --parallel 1 --no-color --no-progress
# 负载敏感的 PerfOverride_test 单独复跑：
unset CJPM_CONFIG && cjpm test --filter PerfOverride_test --parallel 1
```

## 26 条缺陷的落点

| 缺陷 | 落点 | 用例 |
| --- | --- | --- |
| P0-1 H80 14 类界 / tag | A2.2–A2.4 | `p0_1_asHostClassReturnsTag11` / `p0_1_asHostClassRespectsClassBoundary` / `p0_1_anyIsMatchesNonAnyIs` / `p1_4_auxCarriesAsHelperId` |
| P0-2 `call<Any>` / `call<Json*>` | A3.1/A3.2 | `p0_2_callAnyIsReachable` / `p0_2_callJsonReturnsAreReachable` / `p0_2_jsonNullMappingExists` |
| P0-3 `BNOT_I` | A1.1 | `bnotInvertsAndPopsOperand` |
| P0-4/5 DEOPT 三态 | A1.3/A1.4 | `p0_4_replayResetsErrorSlot` / `p0_5_replayErrorIsRethrown` / `p0_5_replayInterruptThrows` |
| P0-6 deadline | A3.3/A3.4 | `p0_6_deadlineInterruptsLoop` / `p0_6_deadlineRestoredAfterCall` / `a3_4_invokeMatchesCall` |
| P1-1 正则 flags | A4.1 | `p1_1_regexFlagsSurviveLexing` / `p1_1_regexFlagsAffectMatching` |
| P1-2 String 算术 | A4.8 | `p1_2_stringArithmeticIsCompileError` |
| P1-3 尾递归实参 | A4.3 | `p1_3_tailRecursionSwappedArgs` |
| P1-4 值用法 `else if` | A4.2 | `p1_4_elseIfParses` |
| P1-5 IIFE 返回类型 | A4.4 | `p1_5_iifeUsesClosureReturnType` |
| P1-6 实例方法重载 | A4.5 | `p1_6_instanceOverloadByArgTypes` / `p1_6_overloadAmbiguityIsCompileError` |
| P1-7 常量 Map 键 | A5.1 | `p1_7_constMapFloatKeysHit` / `p1_7_constMapDecimalKeysHit` / `p1_7_canonKeyIsSingleSource` |
| P1-8 `lowerExprAs` | A4.6 | `p1_8_lowerExprAsRejectsUnconvertible` |
| P1-9 `List<Any>` 装箱 | A4.7 | `p1_9_listAnyBoxesOnAssignAndArg` |
| P2-1 `fetchAnyBox` 代数 | A2.6 | `p2_1_fetchAnyBoxChecksGeneration` |
| P2-2 `IterTable` | A5.2/A5.3 | `p2_2_bridgeClearsIterTableAtCallEnd` / `p2_2_iterTableClearInvalidatesCursor` / `p2_2_iterTableConcurrentSafe` |
| P2-3 逃逸槽归还 | A2.7 | `p2_3_escapedAnyJsonSlotsReleased` / `p2_3_returnHandleCodesCoverAnyAndJson` / `releaseReclaimsEscapedSlot` |
| P2-4 `callForFn` | A6.1 | `p2_4_callForFnSerialized` / `p2_4_lastClosureGroupIsCleared` |
| P2-5 A64 imm9 | A6.2/A6.3 | `imm9OverflowUsesScratchRegister` / `largeOffsetIsChunked` / `deepFrameExceedsImm9` |
| P2-6 H80 窗口记账 | A2.5 | `p2_6_anyAsCountsWindow` |
| P3-1 helper 编号 | A7.1 | 命令级：规则文档零命中（变更自身文档保留旧编号用于描述缺陷） |
| P3-2 三条推翻表述 | A7.2 | 命令级：`16–255 仍拒绝` / `→ 语法错误` 仅余「已推翻/已作废」历史句 |
| P3-3 `json_set` 值域 | A7.3 | `p3_3_jsonSetFloat64RejectedAtCompileTime` / `p3_3_jsonSetAcceptsValueDomain` |
| P3-4 矩阵虚报 | A7.4 | `t48EmptyContainers`（改为逐条断言真值）/ `m3AnyJsonIsTripleEqual` / H65 注释口径统一为 20 |
| P3-5 `doc/spec/` 缺件 | A7.5 | **未完成**（f-jit-m3 与 m2.1–m2.3 仍缺 proposal/design/tasks） |

## 未完成项

- **A7.5**：四个 `doc/spec/` 目录（f-jit-m3、f-jit-m2.1、f-jit-m2.2、f-jit-m2.3）仍缺
  `proposal.md` / `design.md` / `tasks.md`。此项只影响归档文档的完整性，不影响代码与测试。

## 已知边界（已在 design 记录）

- 注册函数（user helper）的 `List<Any>` 实参无法逐元素装箱：`PredefinedSnapshot` 只存类型码，
  没有元素类型。闭包 / IIFE 形参走 TypeRef，可装箱。
- `strictFp` / `literalCopy` 为**未接线**占位（前端恒发 `FDIV`，`FDIV_CHK` 不可达）。
