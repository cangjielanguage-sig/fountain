# Proposal: fix-fmq-verify-followups

## Why

`add-fmq-message-queue` 已归档（86/86，测试与 E2E 全绿），但二次 `opsx:verify` 留下的 6 项
warning / suggestion 仍是真实缺口：管理端缺少独立用例、BODY 容器类型未进测试矩阵、备份定时刷写
与关闭并发未被验证、`fmq` 为解析 host 反向依赖 `f_mq.client`、段记录格式未进设计文档、
远端节点收到主题广播后不推进轮转指针。这些缺口不会让现有用例变红，却会在后续改动或扩容时
放大为可观察缺陷（分配倾斜、关闭丢数据、跨版本误读段文件）。本次变更把它们逐项关闭。

## What Changes

1. **管理端测试**：新增 `fmq/src/server/MQManager_test.cj`（`MQServerOptions` 对包外不可见，用例放在
   `fmq.server` 包），覆盖六个子命令的正常路径与错误路径
   （主题/组已存在、目标不存在、空列表、连接失败），断言退出码与状态变化。
2. **BODY 容器矩阵**：为 `TreeSet` / `HashMap` / `Array` 补齐 `MQMessageRecord` 编解码往返用例，
   并验证 `filter` 对容器内字段的求值结果。
3. **备份刷写与关闭**：补 `BackupReplicator` 的 100ms 定时 flush 用例；补 `BackupStore.close()`
   与在途 `append` 并发的用例，必要时修正关闭路径（关闭后写入应被拒绝或安全丢弃，不得崩溃）。
4. **依赖分层**：把 `parseHost` 从 `f_mq.client.MQClientConfig` 下沉到 `f_mq.base`，`fmq` 只
   import `f_mq.base`；`FMQ` 行为不变，`f_mq.client` 内部改用新位置。
5. **段格式文档**：把 `QueueLog` / `SegmentedLog` 的「4 字节大端长度 + 载荷」记录格式写入
   `design.md`（以及模块设计文档），并注明跨版本读取约束。
6. **远端轮转指针**：`MetaSyncer.applyRemote` 在应用主题分配时同步推进 `nextStartNode`，
   使任意节点后续承接注册时都从正确位置轮转；补失败用例后修正。

**非目标**：不改变已有协议命令与帧格式；不引入新配置项；不做故障转移或备份自动接管。

## Capabilities

**Modified Capabilities**

- `fmq/manager-cli`：把六个子命令的错误路径固化为可断言的系统行为（新增需求与场景）。
- `f-mq/protocol`：新增 BODY 容器类型（`TreeSet` / `HashMap` / `Array`）的编解码与过滤求值需求。
- `fmq/metadata-cluster`：队列轮转需求补充「远端节点同步推进指针」场景；备份需求补充定时刷写场景。
- `fmq/server-runtime`：新增 host 解析归属（只依赖 `f_mq.base`）与备份关闭并发需求。
- `fmq/queue-storage`：新增段记录二进制格式与其文档化要求。

## Impact

| 范围 | 影响 |
|---|---|
| `fmq/src/server/MQManager_test.cj` | 新增用例文件（与 `MQServer` 同包复用测试装配） |
| `f_mq/src/base/MQHost.cj`（新）/ `MQClientConfig.cj` | `parseHost` 迁移，公开 API 位置变化 |
| `fmq/src/cluster/NodeRegistry.cj` | 改用 `f_mq.base.MQHost` |
| `f_mq/src/base/payload/*_test.cj` | 容器矩阵用例 |
| `fmq/src/cluster/BackupReplicator_test.cj` | 定时 flush 用例 |
| `fmq/src/server/BackupStore.cj` / `_test.cj` | 关闭并发用例，必要时加关闭标志 |
| `fmq/src/cluster/MetaSyncer.cj` / `_test.cj` | 远端应用推进 `nextStartNode` |
| `openspec/changes/.../design.md`、`fmq/doc/详细设计.md`、`f_mq/doc/详细设计.md` | 段格式与分层说明 |

兼容性：`parseHost` 位置变化会破坏直接引用 `MQClientConfig.parseHost` 的外部代码；该 API 仅存在于
本 worktree 的未发布功能分支，且仓库内调用点全部同步更新，按 **BREAKING（源码级）** 记录。
`MQClientConfig` 自身仍保留对外的配置解析接口，语义不变。
