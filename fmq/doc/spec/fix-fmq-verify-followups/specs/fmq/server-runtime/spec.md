# fmq 服务运行时（delta）

## ADDED Requirements

### Requirement: host 解析归属

`host:port` 解析 SHALL 位于 `f_mq.base`（`MQHost.parseHost`），`f_mq.client` 与 `fmq` 均复用它。
`fmq` 的源码 SHALL NOT import `f_mq.client`，以保证服务端只依赖共用基础层。解析语义保持不变：
去空白后按单个冒号切分，主机或端口为空、端口非数字、端口为 0 或越界时返回 `None`。

#### Scenario: 服务端不依赖客户端包

- **WHEN** 检查 `fmq/src/**` 的非测试源码（排除 `*_test.cj`）的 import
- **THEN** 不存在 `fountain::f_mq.client` 引用；`NodeRegistry` 使用 `f_mq.base.MQHost`

#### Scenario: 解析语义不变

- **WHEN** 输入 `127.0.0.1:2350`、` h:1 `、`h:0`、`h:70000`、`h`
- **THEN** 前两者返回主机与端口，后三者返回 `None`

### Requirement: 备份存储关闭并发安全

`BackupStore.close()` 与在途 `append` 并发时 SHALL NOT 崩溃或产生半写记录；关闭后到达的写入
SHALL 被安全丢弃（不重新创建 `QueueLog`）。关闭前已成功返回的 `append`，其记录 SHALL 能被读回。

#### Scenario: 关闭与写入并发

- **WHEN** 4 个线程持续 `append`，同时主线程调用 `close()`
- **THEN** 进程无崩溃；`close()` 返回后 `instanceCount == 0`

#### Scenario: 关闭前写入可读回

- **WHEN** 顺序写入 10 条后调用 `close()`
- **THEN** 从备份目录能读回全部 10 条

#### Scenario: 关闭后写入

- **WHEN** `close()` 返回后再调用 `append`
- **THEN** 调用不抛异常、不创建新 `QueueLog`，`instanceCount` 保持 0
