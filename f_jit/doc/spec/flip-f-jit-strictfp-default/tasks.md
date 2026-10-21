# Tasks

## C1 默认翻转

- [x] C1.1 先写失败用例——`CompileOptions(DummyDiagnosticsSink()).strictFp == true`；再把 `CompileOptions` / `SourceCompiler` / `Lowerer` 三处缺省改为 `true`。**（`optionsDefaultToLatestVersion` 断言翻转；三层缺省同日改，无分叉）**
- [x] C1.2 端到端：不设任何选项编译 `{ x: Float64 => 1.0f64 / x }`，以 `x = 0.0` 调用必以 1 失败、产物含 `FDIV_CHK` 且不含 `FDIV`。**（`defaultIsStrict` + `defaultEmitsFdivChk`）**

## C2 受影响用例显式声明宽松

- [x] C2.1 IEEE 用例改为在编译辅助函数里传 `strictFp: false`：`T2/nan`、`T8/nan`、`T8/inf`、`T8/neg-inf`、`T8/nan-str`、A64 `0.0/0.0`；验收：这些用例仍断言 `NaN/±Inf` 且错误码为 0。**（实际落在 4 个辅助函数：`Acceptance_test.rawOf`、`DiffExec_test.check` ×2、`A64Exec_test.run2`；七组定向用例全绿）**
- [x] C2.2 `StrictFp_test.looseDivisionByZeroYieldsInf` 与 `strictFpIsPartOfCacheKey` 的「宽松」一侧、`AnyBridgeCall_test.a3_5` 改为显式 `strictFp = false`。**（三处各建独立 `CompileOptions`，不污染共享 `compiler()` 辅助）**

## C3 文档与规格

- [x] C3.1 `CompileOptions` 注释、`doc/design-m1.md` §2.3.4 写明「缺省严格，要 IEEE 显式关」。**（另同步 §浮点算术 总表行）**
- [x] C3.2 `doc/jit-bytecode-m1.md` §2 的 `flags` 行与 `FDIV_CHK` 条目注明缺省严格。**（`flags` 行标「严格浮点缺省开启」；`FDIV_CHK` 标「缺省形态」）**
- [x] C3.3 规格 delta：`编译选项的版本与严格浮点` 增加缺省值条款与「缺省即严格」Scenario。**（`validate --strict` 通过）**

## C4 回归与归档

- [x] C4.1 全量 `cjpm test --parallel 1` 零失败零 error；用例数与本变更前（1090）对照。**（1092/1092 / 0 / 0）**
- [x] C4.2 `verify.md`：默认翻转的落点、7 处显式关闭清单。**（已出具）**
- [x] C4.3 归档 `openspec archive flip-f-jit-strictfp-default --yes`，同步 `f_jit/doc/spec/` 镜像。**（+0 added / ~1 modified）**
