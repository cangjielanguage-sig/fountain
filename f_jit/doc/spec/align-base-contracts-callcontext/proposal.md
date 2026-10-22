# Proposal

## Why

`f-jit-base-contracts` 的「公共值类型」仍写着 `CallContext` 的默认值契约包含 `literalCopy=false`、`strictFp=false`，对应 Scenario 还断言这两个字段；而它们早在 `close-f-jit-out-of-checklist-findings`（X3）就已删除，`args` 也在 2026-10-22 的 `CallContext` 收窄中移除。规格与代码直接矛盾——这是上一轮只改了 facade-bridge 与文档、漏改 base-contracts 造成的。

## What Changes

- `公共值类型` 改为：`CallContext` 只含调用级选项，唯一字段是 `deadline: ?DateTime`（缺省 `None`、构造后只读）；显式写明 `literalCopy` / `strictFp` / `args` SHALL NOT 出现。
- `默认值契约` Scenario 同步：只断言 `deadline` 为 None，并断言类型上不存在上述三个字段。
- 纯规格对齐，零代码改动。

## Capabilities

### Modified Capabilities

- `f-jit-base-contracts`：`公共值类型` 的 `CallContext` 默认值契约。

## Impact

- **代码**：零改动。
- **测试**：不改（`CallContext_test` 已由合入方改写为只测 `deadline`）。
- **不在本次范围**：`JitValue` / `Engine` 的可见性口径。
