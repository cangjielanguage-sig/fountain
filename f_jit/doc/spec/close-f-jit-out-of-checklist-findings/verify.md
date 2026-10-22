# Verify

## 全量回归

| 项 | 数值 |
| --- | --- |
| 基线（`fix-f-jit-audit-defects` 归档后） | 1076 用例 / 1076 通过 / 0 失败 / 0 error |
| 终态 | **1090 用例 / 1090 通过 / 0 失败 / 0 error / 0 skipped** |
| 新增用例 | 14 条（CompileOptions 2 + 版本 3 + strictFp 行为 4 + strictFp 发射 3 + 键不变式 2） |
| 改写用例 | `CallContext_test`（字段删除）、`AnyBridgeCall_test.a3_5`（口径改为桥层不改语义） |
| 回归 | 0（既有 1076 条全部保持通过） |

复现（融合侧）：

```bash
unset CJPM_CONFIG && cjpm test --parallel 1 --no-color --no-progress
```

## 四项清单外发现的落点

| 编号 | 发现 | 红态证据 | 终态用例 |
| --- | --- | --- | --- |
| X1 | `CompilePipeline` 硬编码 `verMajor`，公开 `compile` 无法选择版本、缓存不区分版本 | 13 处编译错误：`'verMajor' is not a member of class 'CompileOptions'` / `'LATEST' is not a member of class 'Version'` | `optionsDefaultToLatestVersion` / `versionIsSettable` / `m2VersionRejectsAnySource` / `latestVersionAcceptsAnySource` / `versionIsPartOfCacheKey` |
| X2 | 值型键分叉：`CanonKey.f64` 产 `f:<bits>`、`cell` 产 `i:<bits>` | `Assert Failed: CanonKey.f64(bits) != CanonKey.cell(...)`（实际 `f:4609434218613702656` vs `i:4609434218613702656`） | `x2_f64KeyEqualsCellKey` / `x2_boxedAndRawFloatKeyAgree` / 既有 `p1_7_*` 三条 |
| X3 | `strictFp` 写 flags 后无人读；`literalCopy` 无消费点 | 前端从不出 `FDIV_CHK`；`CallContext.strictFp` 全仓零读取点 | `looseDivisionByZeroYieldsInf` / `strictDivisionByZeroFails` / `strictStillComputesNormalDivision` / `strictFpIsPartOfCacheKey` / `strictEmitsFdivChk` / `looseKeepsFdiv` / `otherArithmeticUnaffected` |
| X4 | 值用法 `else if` 的 `while` 永不进入 | 上一轮已红（`x = if … else if …` 编不过），本轮代码零改动 | `p1_4_elseIfParses`（语句 + 值用法各三臂） |

红态取得方式：X1 用「新 API 尚不存在 → 构建失败」；X2 用真实断言失败；X3 先在**未接线**状态下跑行为用例（÷0 恒 `+Inf`、`FDIV_CHK` 零出现）再接线。

## X2 深挖出的两个附带缺陷

修 X2 时用例把两个更底层的问题逼了出来，一并收口：

1. **`JitAnyBox` 未解包 ⇒ 装箱键塌成同一个键**：`mapKeyOf` 对盒句柄走 `canonKeyOf(JitAnyBox)`，落到 `case _` 返回空串——任意两个 `Float64` 盒的 Map 键都是 `""`，互相覆盖。修法：`mapKeyOf` 先解包 `JitAnyBox` 再取键。用例 `x2_boxedAndRawFloatKeyAgree` 同时断言「盒 ≡ 裸 cell」与「不同盒不同键」。
2. **位模式转换的检查型溢出**：`Int64(bits)` 是检查型转换，负浮点 / NaN 的位模式 ≥ 2^63 会抛 `OverflowException`（`-0.0` 的位模式即触发）。新增 `CanonKey.bitsAsI64` 按补码折返，常量表（`ConstRegistry`）与 `f64` 共用。注：当前字面量里负浮点走一元负号、未必直接产生负位模式常量，属**潜在**崩溃点，按重解释修正后不再可能触发。

## 兼容性

| 面 | 结论 |
| --- | --- |
| `.fbc` 格式 / 规则集 | 不变 |
| 默认产物 | 逐字节不变（`strictFp=false` 仍发 `FDIV`） |
| 公共 API | **破坏性**：删 `CallContext.literalCopy` / `CallContext.strictFp`；新增 `CompileOptions.verMajor` / `CompileOptions.strictFp`、`Version.LATEST`、`CanonKey.bitsAsI64` |
| 缓存 | 键新增 `v<major>` 与 `fp<0|1>` 两段；旧键自然失效（仅进程内） |
| 错误码 | 不新增；strict 下 ÷0 复用 1（`DIV_ZERO`） |
| `ctx.flags` bit0 | 保留为历史位，运行期无读者（`CtxFlags.STRICT_FP` 注释已同步） |

## 规格 lint（顺带改善）

归档后 `f-jit-facade-bridge` 的超长需求从 3 条降到 2 条：`统一调用包装` 由 962 字符拆成「统一调用包装（325）+ 调用入口与选项（467）+ 编译选项的版本与严格浮点（391）」，全部 ≤ 500 字符。其余 4 个规格的既有超长正文不在本次范围。

## 已知边界

- `mapKeyOf` 只解一层 `JitAnyBox`；盒套盒（`any_box(15, …)`）本就不被前端发射（D12 同型直传），不构成缺口。
- `CtxFlags.STRICT_FP` 不再有读者，但作为 ctx 线上位保留（ABI 面不动）。
- 未实现「运行期切换严格浮点」——这是**有意否决**的设计（成本由全部浮点除承担），见 design D2。

## 归档（全流程收尾）

| 项 | 结果 |
| --- | --- |
| 命令 | `openspec archive close-f-jit-out-of-checklist-findings --yes` |
| 增量应用 | **+2 added / ~4 modified / −0 removed / →0 renamed**（2 条新增需求 + 4 条修改） |
| 归档路径 | `openspec/changes/archive/2026-10-21-close-f-jit-out-of-checklist-findings/` |
| 活动变更 | `openspec list` → `No active changes found` |
| 镜像 | `f_jit/doc/spec/close-f-jit-out-of-checklist-findings/` 与归档目录逐文件一致 |

### 规格 lint 变化

`f-jit-facade-bridge` 的超长需求由 3 条降为 2 条：`统一调用包装` 从 962 字符拆成
325 + 467 + 391 三段（全部 ≤ 500）。其余 4 个规格的既有超长正文不在本次范围，仍登记为债务。
