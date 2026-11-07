# Spec Delta

## ADDED Requirements

### Requirement: 存储网关单实例复用

一次装配 MUST 最多创建一个 `LoomStoreGateway`（首次使用时创建，之后复用）；`loomStore` 网关、`memoryCall`、`knowledgeIngest`、技能演进读取 MUST 共用这个实例，MUST NOT 在每次调用时重新构造。装配阶段 MUST NOT 主动连接存储。

#### Scenario: 多次 store 调用只建一次

- **WHEN** 装配完成（`LoomWiring.wire`）后连续调用 `loomStore` 三次
- **THEN** 网关构造次数保持为 1

#### Scenario: 装配不连存储

- **WHEN** 只执行 `LoomWiring.wire` 而未发生任何 store 调用
- **THEN** 网关构造次数为 0（启动阶段不打开存储）

#### Scenario: 工具与网关同源

- **WHEN** 已装配自定义存储函数，再调用 `memoryCall`
- **THEN** 调用落在装配期安装的那个函数上，而不是工具自己新建的网关

#### Scenario: 未装配时的降级

- **WHEN** 没有执行装配就调用 `memoryCall`
- **THEN** 工具自建网关完成调用（保持可用），不抛「未安装」

### Requirement: 网关构造可观测

系统 MUST 提供包内可见的网关构造计数，供装配自检与测试确认「只建一次」。

#### Scenario: 计数可重置

- **WHEN** 重置计数后执行一次装配
- **THEN** 计数为 1；再调用 `loomStore` 不增加
