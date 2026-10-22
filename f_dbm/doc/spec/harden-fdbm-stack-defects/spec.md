## ADDED Requirements

### Requirement: 扩展契约的默认行为与异常类型（MUST）

本要求为强制要求（MUST）。

`f_dbm` 是第三方扩展的唯一契约面，必须保证：

- `IdGenerator.nextStringId()` / `nextIntId()` 的默认实现抛 `fountain::f_dbm.IdGeneratorException`，消息含生成器 `name` 与「不支持哪种 ID」；
- 实现至少支持一种 ID 能力即为合法用法，另一种沿用默认实现（不得要求两者都实现）；
- 契约层抛出的异常类型必须是 `IdGeneratorException`（而不是裸 `Exception`），调用方据此映射 `ID_GENERATOR`。

#### Scenario: 默认实现抛契约异常

- **GIVEN** 一个只实现 `nextStringId` 的 `IdGenerator`
- **WHEN** 调用 `nextIntId()`
- **THEN** 抛 `IdGeneratorException`，`message` 含生成器名与 `int`

#### Scenario: 只实现一种能力是合法的

- **GIVEN** 上述生成器被 fdbm 使用
- **WHEN** 表需要整型分库键
- **THEN** 调用方按能力回退到字符串 ID 并成功（见 fdbm「ID 生成」要求）

### Requirement: 扩展名的唯一性与内置名保护（MUST）

本要求为强制要求（MUST）。

- 自定义 `PartitionAlgorithm.name` 之间、`IdGenerator.name` 之间不得重名；
- 自定义名不得等于内置名（分区：`step`/`hash`/`std`/`crc16`/`crc32`/`crc64`/`murmur`/`substr`；
  ID：`uuid`/`snowflake`/`sequence`）；
- 冲突必须由 fdbm 启动自检拒绝（`PARTITION_CONFIG` / `CONFIG`），**不允许覆盖内置实现**。

#### Scenario: 与内置重名

- **GIVEN** 扩展库声明 `name = 'hash'` 或 `'uuid'`
- **WHEN** fdbm 启动
- **THEN** 启动失败并给出冲突名，运行期不会用扩展实现替换内置

### Requirement: 分区算法的确定性（MUST）

本要求为强制要求（MUST）。

`PartitionAlgorithm.partition<K>(key)` 必须对同一 key 在任意节点、任意时刻返回同一物理库；不得依赖进程内随机、时间或未声明的外部状态。key 的规范化（可无损解析为 `Int64` 时用 `Int64`，否则 `String`）由 fdbm 路由层在调用前完成，实现不得改变 key 语义。

#### Scenario: 跨实例一致

- **GIVEN** 同一实现的两个实例、同一 key 集合
- **WHEN** 分别计算
- **THEN** 每个 key 的结果相同

### Requirement: 扩展契约的回归基线（MUST）

本要求为强制要求（MUST）。

`f_dbm` 必须自带可执行的单元测试，覆盖：两个默认方法各抛 `IdGeneratorException` 且消息保真、只实现一种能力的用法、
`PartitionAlgorithm` 的确定性、以及「扩展名与内置名冲突由 fdbm 拒绝」的契约说明（后者在 fdbm 侧以启动负例验证）。
`cjpm test` 在 `f_dbm` 必须可独立运行。

#### Scenario: 模块自带测试

- **GIVEN** 干净的 `f_dbm` 工作树
- **WHEN** `cjpm test`
- **THEN** 全绿，且断言数 > 0
