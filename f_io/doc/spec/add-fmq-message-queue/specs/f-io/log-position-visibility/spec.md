# f_io 位置可见性（delta）

## ADDED Requirements

### Requirement: 分段日志位置可跨模块读取

`f_io.LogPosition` 的 `seq` 与 `offset` SHALL 为 `public let`，使 `f_mq` / `fmq` 能直接读取
`SegmentedLog.append` 返回的位置，并把两个字段回传给 `openEntryStream(index:offset:)` 续读。

#### Scenario: 跨模块读取 append 返回值

- **WHEN** 模块 `f_mq` 调用 `log.append(record)` 并读取返回值的 `.seq` / `.offset`
- **THEN** 编译通过，两个字段的值等于该记录所在段的编号与段内起始偏移

#### Scenario: 用位置续读

- **WHEN** 以 `position.seq` 与 `position.offset` 调用 `log.openEntryStream(index:offset:)`
- **THEN** 流从该位置的第一条记录开始，按写入顺序读出后续全部记录

### Requirement: 可见性放宽不改变既有行为

该改动 SHALL 只放宽可见性，不改变 `LogPosition` 的构造、比较、字段值与任何 `SegmentedLog` 行为。

#### Scenario: f_io 全量回归通过

- **WHEN** 执行 `cd f_io && cjpm test`
- **THEN** 全部既有用例通过，无新增失败或错误

#### Scenario: 既有使用方不受影响

- **WHEN** 既有只读使用 `LogPosition` 的模块（如 `f_store`）重新编译
- **THEN** 无需改动即可通过
