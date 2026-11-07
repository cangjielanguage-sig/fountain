# Spec Delta

## ADDED Requirements

### Requirement: 知识文档带归属

`writeKnowledge` 生成的 `docId` MUST 形如 `loom:<userId>:<namespace>:<flow>:<时间戳>-<序号>`；同一流程重复执行 MUST 产生不同 `docId`，MUST NOT 覆盖既有文档。

#### Scenario: 重复执行不覆盖

- **WHEN** 同一流程在 `writeKnowledge=true` 下执行两次
- **THEN** 知识库里出现两条不同 `docId`，且都以 `loom:<userId>:<namespace>:` 开头

### Requirement: 记忆策略的并发安全

`LoomMemoryPolicy` 的安装、重置与读取 MUST 在锁保护下进行，MUST NOT 出现「读到半个策略」的竞态。

#### Scenario: 安装与读取并发

- **WHEN** 一个线程 `install`、另一个线程 `effective`
- **THEN** 读到的要么是旧策略要么是新策略，不出现中间态

### Requirement: 演进归属与记忆策略同源

`LoomWiring.wire` 的演进归属 MUST 在调用方未显式给出时跟随记忆策略；`evolutionNamespace` MUST 支持「未给」语义（空串）。

#### Scenario: 只配记忆策略

- **WHEN** `memoryPolicy.userId=7, namespace='work'`，`evolutionUserId` 未给
- **THEN** 演进按 `7/work` 读取，与写入侧一致

#### Scenario: 显式覆盖

- **WHEN** 显式给 `evolutionUserId=9, evolutionNamespace='explicit'`
- **THEN** 以显式值为准

### Requirement: 知识素材按租户过滤

演进读取知识素材时 MUST 只取 `docId` 前缀匹配当前 `userId/namespace` 的文档；前缀不匹配或旧格式 MUST NOT 参与演进。

#### Scenario: 跨租户隔离

- **WHEN** 知识库里有 `loom:8:work:...` 与 `loom:7:work:...`
- **THEN** 以 `7/work` 运行时只取后者

#### Scenario: 旧格式不被消费

- **WHEN** 存在 `loom:daily:1` 这类旧格式 docId
- **THEN** 它不进入演进素材

### Requirement: 提炼失败可观测

流程结束提炼时，异常与「成功但零写入」MUST 各留一条 warn 日志，MUST NOT 完全静默。

#### Scenario: 提炼抛异常

- **WHEN** `LoomMemoryExtractor.extract` 抛异常
- **THEN** 流程结果不受影响，但日志里有 `loom extract failed`

#### Scenario: 零写入

- **WHEN** 提炼返回 0 且策略开启
- **THEN** 日志里有 `loom extract wrote nothing`
