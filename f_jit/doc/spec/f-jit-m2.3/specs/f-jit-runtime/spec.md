# Spec Mirror — f-jit-runtime（M2.3 增量）

> 只收录 `f-jit-m2.3` 改动的 requirement；其余仍由 `check_scenarios.sh m2` 等承担。

### Requirement: H77 转型失败码

运行期 SHALL 提供固定 helper **H77 `cast_fail`**：无入参、恒以 **7 `BAD_CAST`** 失败、不返回。它存在的理由是「`as` 转型失败必须是 7，而 user helper 抛出的普通异常会被统一转 21」——固定 helper 直接置码，码值不被改写。H77 SHALL 登记进固定 helper 名表，且 SHALL NOT 占用既有保留位（66–68 仍为保留）。

#### Scenario: 恒置 7

- **WHEN** 直接调用 `cast_fail`
- **THEN** 错误码恰为 `BAD_CAST`（7），不逃逸成 18/21

#### Scenario: 编号不越界

- **WHEN** 查询 `HelperId.isFixed(77)` 与 `HelperId.name(77)`
- **THEN** 分别为真与 `cast_fail`；66–68 仍为保留（`isFixed` 假）

