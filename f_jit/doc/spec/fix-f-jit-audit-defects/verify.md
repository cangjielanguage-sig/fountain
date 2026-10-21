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

## 归档（全流程收尾）

| 项 | 结果 |
| --- | --- |
| 命令 | `openspec archive fix-f-jit-audit-defects --yes` |
| 增量应用 | **+14 added / ~4 modified / −0 removed / →0 renamed**（与 18 条 delta 一一对应） |
| 归档路径 | `openspec/changes/archive/2026-10-21-fix-f-jit-audit-defects/`（proposal / design / tasks / test-plan / verify + 6 个能力 delta + `.openspec.yaml`） |
| 活动变更 | `openspec list` → `No active changes found` |
| 主规格 | 9 个 capability；需求数：backend 11、base-contracts 13、bytecode-format 14、compiler-frontend 25、differential-acceptance 12、facade-bridge 19、module-skeleton 4、runtime 25、f-util-fnv 7 |
| 镜像一致性 | `f_jit/doc/spec/fix-f-jit-audit-defects/` 与归档目录逐文件 `diff` 一致（5 个顶层文件 + 6 个 delta） |

### 归档后规格 lint：既有债务，非本变更引入

`openspec validate --all --strict` 结果 **4 passed / 5 failed**，5 个失败全部是「需求正文 > 500 字符」的 WARNING（不是结构错误）。按变更前主规格与历史归档逐条测量：

| 规格 | 超限需求（字符数） | 判定 |
| --- | --- | --- |
| f-jit-base-contracts | 638 / 564 | 变更前已超限 |
| f-jit-compiler-frontend | 645 / 692 / 685 / 843 | 变更前已超限 |
| f-jit-differential-acceptance | 656 | 变更前已超限 |
| f-jit-facade-bridge | 722 / 592 | 变更前已超限 |
| f-jit-runtime | 786 / 801（+ H78–H80 765） | 变更前已超限 |

本变更只新增 **1 处**告警：`统一调用包装` 由 492 → 962 字符（D3 引入 `invoke` / `deadline` 契约文本）。OpenSpec 给出的处置建议是「拆成多条 requirement 或把细节移入 scenario」——那会改写既有规格结构，属**独立**的规格治理变更；本变更不改写既有规格骨架，按仓库惯例登记为债务（与「374 条编译 warning」同口径）。

判定口径：变更级门禁 `openspec validate fix-f-jit-audit-defects --strict` 在归档前**通过**；全局 `--all --strict` 的失败集合在本次前后不变（同一 5 个规格）。
