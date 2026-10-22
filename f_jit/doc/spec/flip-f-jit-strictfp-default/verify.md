# Verify

## 全量回归

| 项 | 数值 |
| --- | --- |
| 基线（`close-f-jit-out-of-checklist-findings` 归档后） | 1090 用例 / 1090 通过 / 0 失败 / 0 error |
| 终态 | **1092 用例 / 1092 通过 / 0 失败 / 0 error / 0 skipped** |
| 新增用例 | 2 条（`defaultIsStrict`、`defaultEmitsFdivChk`） |
| 改写用例 | 7 处显式声明宽松（见下表）+ `optionsDefaultToLatestVersion` 断言翻转 |
| 回归 | 0 |

## 默认翻转的落点

| 层 | 改动 |
| --- | --- |
| `CompileOptions.strictFp` | `false` → **`true`**（公开缺省） |
| `SourceCompiler(strictFp!)` | `false` → **`true`**（内部装配与公开层一致） |
| `Lowerer(strictFp!)` | `false` → **`true`**（同上） |

三处同时改，避免「经 `Compiler` 是严格、经 `SourceCompiler` 直连是宽松」的分叉。

## 显式声明宽松的 7 处

| 位置 | 原因 |
| --- | --- |
| `Acceptance_test.rawOf` | `T8/nan`、`T8/inf`、`T8/neg-inf`、`T8/nan-str` 断言 IEEE |
| `DiffExec_test.check`（`DiffExec_test`） | `T2/nan` 差分基线 |
| `DiffExec_test.check`（`GoldenDiff_test`） | 同文件的第二个类，同一基线口径 |
| `A64Exec_test.run2` | `0.0/0.0 → canonical NaN`（FPCR.DN 硬件行为） |
| `StrictFp_test.looseDivisionByZeroYieldsInf` | 用例本体就是「关闭严格」 |
| `StrictFp_test.strictFpIsPartOfCacheKey` 的宽松侧 | 需要 `fp0` 产物 |
| `AnyBridgeCall_test.a3_5` | 断言桥层不改变 IEEE 语义 |

原则：这些用例验证的是 **`FDIV` 的 IEEE 语义**，不是产品缺省策略；口径必须由用例自己声明，不能把「默认值」写进语义断言里——否则默认一变，语义用例跟着红。

## 新增用例

- `defaultIsStrict`（`StrictFp_test`）：不设任何选项编译 `{ x: Float64 => 1.0f64 / x }`，`x = 0.0` → 错误码 1。
- `defaultEmitsFdivChk`（`StrictFpCodegen_test`）：不传 `strictFp` 的产物含 `FDIV_CHK` 且不含 `FDIV`。

## 行为与兼容性

| 面 | 结论 |
| --- | --- |
| 默认行为 | **破坏性**：`Float64` 的 `÷0` 由「得 ±Inf」改为「错误码 1 失败」；显式 `strictFp = false` 可恢复 |
| `.fbc` 格式 | 不变（`FDIV` / `FDIV_CHK` 均既有） |
| 缓存键 | 格式不变；缺省配置从 `fp0` 段迁到 `fp1` 段 |
| 性能 | `FDIV_CHK` 与 `FDIV` 同为单条指令（A64 侧 `floatBin(4)` 本就是 `fcmp + b.eq + fdiv`），无额外调用开销 |
| 文档 | `design-m1` §2.3.4 / §浮点算术行、`jit-bytecode-m1` flags 行 / `FDIV_CHK` 条目、`CompileOptions` 注释均已写明「缺省严格」 |

## 已知边界

- `Int64` / `Decimal` 的除零不受本选项影响（本来就是错误码 1 / 10）。
- 未提供「整批调用级覆盖」——严格是产物属性，切换需重新编译（缓存键已区分）。

## 归档（全流程收尾）

| 项 | 结果 |
| --- | --- |
| 命令 | `openspec archive flip-f-jit-strictfp-default --yes` |
| 增量应用 | **+0 added / ~1 modified**（`编译选项的版本与严格浮点` 增加缺省值条款与 Scenario） |
| 归档路径 | `openspec/changes/archive/2026-10-21-flip-f-jit-strictfp-default/` |
| 活动变更 | `openspec list` → `No active changes found` |
