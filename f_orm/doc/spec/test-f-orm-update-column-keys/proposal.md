# UPDATE 的 Column 键重载回归网

## Why

`docs/LocalMode.md` 2.5 列出 `SqlPartial.UPDATE`（123-143）的 `HashMap<String, Any>` 中转，建议 `@ local!`。可行性探针显示 3 键映射 **1,542 B → 120 B**，但在真实代码中 local 化被类型系统阻断：

1. `HashMap<String, Any>() @ local!` 的**下标赋值**被拒绝（`cannot assign to this subscript expression`，4 处）；
2. 从 local 映射读出的 `Any` 带 local 限定，**不能传给 `arg(Any)`**（`mismatched types`，3 处）。

同时实测收益上限只有 9%：mock 下每次 UPDATE 总分配 16,763 B，中间映射约 1,542 B；真实 DB I/O 下占比更低。

因此本变更**不做性能优化**，改为把四个 Column 键重载与 `Map<String, Any>` 版本的等价性固化成回归网——这条路径此前零测试。

## What Changes

- **新增 `f_orm/src/base/SqlPartialColumnKey_test.cj`**：用 `@DataAssist` + `@QueryMappersGenerator` 实体与 `MOCKDB` 捕获，逐项对比四个 Column 键重载与字符串键版本的 SQL 文本和绑定参数。
- **不修改生产代码**：`SqlPartial.cj`、`f_orm/cjpm.toml` 保持原样。
- **审计表回写**：`docs/LocalMode.md` 记录阻断原因与 9% 收益上限。

**公开 API 不变**：纯测试与文档变更。

## Capabilities

### New Capabilities

- `orm-update-binding`：UPDATE 的列名解析与参数绑定契约（四个 Column 键重载与字符串键版本等价、字段名/列名双键解析）。

### Modified Capabilities

无。

## Impact

- 代码：无生产代码改动。
- 测试：新增 `f_orm/src/base/SqlPartialColumnKey_test.cj`（5 条）。
- 文档：`docs/LocalMode.md` 的 f_orm 行。
- 行为：无变化；测试锁住现状。
