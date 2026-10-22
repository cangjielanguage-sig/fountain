# 测试计划

基线：`close-f-jit-out-of-checklist-findings` 归档后 **1090 / 1090 / 0 / 0**。

| 用例 | 断言 | 落点 |
| --- | --- | --- |
| `optionsDefaultToLatestVersion`（改） | `strictFp == true` | `CompileOptions_test` |
| `defaultIsStrict`（新） | 不设选项编译 `1.0/x`，`x=0.0` → 错误码 1；产物含 `FDIV_CHK`、不含 `FDIV` | `StrictFp_test` |
| `looseDivisionByZeroYieldsInf`（改） | 显式 `strictFp=false` → `+Inf`、码 0 | `StrictFp_test` |
| `strictFpIsPartOfCacheKey`（改） | 宽松侧显式 false | `StrictFp_test` |
| `a3_5_bridgeKeepsDivisionSemantics`（改） | 显式 false | `AnyBridgeCall_test` |
| `T2/nan`、`T8/nan|inf|neg-inf|nan-str`（改） | 编译辅助函数显式 false，仍断言 NaN/±Inf | `DiffExec_test` / `Acceptance_test` |
| A64 `0.0/0.0`（改） | 显式 false，仍断言 canonical NaN | `A64Exec_test` |

门槛：全量零失败；IEEE 用例必须在显式关闭后保持原断言，不得放宽。
