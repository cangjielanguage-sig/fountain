# 测试计划

基线：`fix-f-jit-audit-defects` 归档后全量 **1076 / 1076 通过 / 0 失败 / 0 error**。

## 新增与改写用例

| 编号 | 用例 | 断言对象 | 落点 |
| --- | --- | --- | --- |
| X1-a | `optionsDefaultToLatestVersion` | `opts.verMajor == Version.LATEST`、`LATEST == M3_MAJOR` | `CompileOptions_test` |
| X1-b | `m2VersionRejectsAnySource` | `SourceCompileException`（消息含请求值与支持集） | `CompilePipeline_test` |
| X1-c | `versionIsPartOfCacheKey` | 同源 M2 / LATEST 两次编译得到不同产物版本且互不覆盖 | `CompilePipeline_test` |
| X3-a | `strictFpEmitsFdivChk` | 产物逐指令：`0x44`（strict）/ `0x43`（非 strict） | `StrictFp_test` |
| X3-b | `strictFpChangesDivisionByZero` | `false → +Inf`（码 0）；`true → 1` | `StrictFp_test` |
| X3-c | `strictFpIsPartOfCacheKey` | 同源两种配置产物 opcode 各自正确 | `StrictFp_test` |
| X3-d | `callContextHasOnlyCallLevelOptions` | 字段集合 = `{args, deadline}`（编译失败即证据） | `CallContext_test`（改写） |
| X2-a | `f64KeyEqualsCellKey` | `f64(bits) == cell(bits)`（1.5 / −0.0 / NaN） | `CanonKey_test` |
| X2-b | `boxedAndRawFloatKeyAgree` | `mapKeyOf` 两形态同一 `ConstMapKey` | `CanonKey_test` |
| X2-c | `constMapFloatKeyHitWithBoxedKey` | 装箱键命中常量条目 | `A5MapKey_test` |
| X4-a | `elseIfValuePositionThreeArms` | 值用法三臂结果（若既有用例未覆盖） | `A4Frontend_test` |

## 回归面

- `CallContext_test`：字段删除后重写（默认值契约只剩 `deadline = None`）。
- `AnyBridgeCall_test.a3_5_strictFpDoesNotChangeFdivChk`：口径改为「编译选项探针」，不再断言 `invoke` 的 `strictFp`。
- `p1_7_constMapFloatKeysHit` / `p1_7_constMapDecimalKeysHit` / `p1_7_canonKeyIsSingleSource`：必须保持绿。
- `p1_4_elseIfParses`：必须保持绿。

## 门槛

- 新增用例先红后绿：红态用「临时回退实现」取得，逐条记录在 `verify.md`。
- 全量 `cjpm test --parallel 1` 零失败零 error；`PerfOverride_test` 若在高负载下假失败，单独复跑确认。
- 差分最小集 `Interp × AArch64`：X3 的 ÷0 行为在两引擎上逐位一致。
