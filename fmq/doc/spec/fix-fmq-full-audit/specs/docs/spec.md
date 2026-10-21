# 文档（delta）

## ADDED Requirements

### Requirement: 设计文档与实现一致

`f_mq/doc/详细设计.md` 与 `fmq/doc/详细设计.md` SHALL 与源码保持一致，至少覆盖：
协议字段与构造签名、命令分派表、`MQConsumeResult`/`MQAckPayload`/`MQMessage` 的 `queueIndex`、
`MQTopicMeta`/`MQTopicAssignment` 的 `delayingMs`、`MQInternalMessage` 的三种 kind 与五个
`metaSync` 重载、`MQClient` 的公开签名（含 `ack` 的 `queueIndex`）、`MQNodePool` 构造参数、
`GroupCursor` 的 `entries` 结构/`next` 参数/`sweep` 触发方式、段记录格式（含 64 MiB 上界）、
备份语义（真实状态、异步发送、失败重试、清理）、退出钩子与关闭顺序、子命令数量与输出格式。
每项 SHALL 有可 grep 的唯一关键串，供验收脚本检查。

#### Scenario: 协议字段可检索

- **WHEN** 在 `f_mq/doc/详细设计.md` 检索 `queueIndex`、`delayingMs`、`ACK`、`stats`
- **THEN** 对应表项同时出现字段名与语义说明，且与 `f_mq/src/base/payload/*` 一致

#### Scenario: 签名可对照

- **WHEN** 对照文档中的 `MQClient.ack` 与源码
- **THEN** 参数个数、顺序与类型一致

#### Scenario: 分派与 kind 完整

- **WHEN** 查阅内部消息章节
- **THEN** 列出 `metaSync` / `backup` / `stats` 三种 kind 及各自子载荷类型

#### Scenario: 存储格式与上界

- **WHEN** 查阅 `fmq/doc/详细设计.md` 存储章节
- **THEN** 含「4 字节大端长度 + 记录字节」、64 MiB 上界、不可跨段与损坏处理

#### Scenario: 关闭顺序与钩子

- **WHEN** 查阅服务端生命周期章节
- **THEN** 含退出钩子注册点与「相反顺序释放」的完整列表

### Requirement: README 与实际行为一致

`fmq/README.md` 与 `fmq/README_en.md` SHALL 准确描述：配置覆盖方式与参数位置限制（或已支持的
前置写法）、7 个管理子命令、备份的丢弃/重试/清理语义、段 TTL 与离线组保留、统计错误的可见性。
文档 MUST NOT 声称实现未提供的能力，也 MUST NOT 与实际丢弃策略矛盾。

#### Scenario: 命令行写法

- **WHEN** 按 README 示例执行配置参数前置与后置两种写法
- **THEN** 两种都能启动或返回帮助，退出码符合描述

#### Scenario: 子命令数量

- **WHEN** 检索 README 与管理端 `--help`
- **THEN** 均为 7 个子命令（含 `stats`），名称一致

#### Scenario: 备份语义

- **WHEN** 查阅备份章节
- **THEN** 明确「发布不阻塞」「失败重试」「队列满/关闭丢弃并 WARN」「备份段纳入 TTL」

#### Scenario: 已知限制

- **WHEN** 查阅已知限制
- **THEN** 含「离线超过墓碑 TTL 的节点需全量重建」「大记录依赖全部节点升级」两条

### Requirement: 任务台账真实

`f_mq/doc/spec/add-fmq-message-queue/tasks.md` SHALL 反映真实完成状态：
已完成项 SHALL 勾选，未完成项 MUST NOT 勾选；每条勾选项 SHALL 能指向实际存在的文件或用例，
不得引用不存在的用例文件。新增的本次变更任务 SHALL 在 `tasks.md` 中单独成节，完成后逐项勾选。

#### Scenario: 勾选项可验证

- **WHEN** 对每个 `[x]` 项检查其声称的文件或用例
- **THEN** 文件存在且用例可运行

#### Scenario: 无幽灵文件

- **WHEN** 检索 `tasks.md` 中出现的 `*_test.cj`
- **THEN** 全部存在于仓库

#### Scenario: 六项遗留已勾选

- **WHEN** 查阅第 11 节
- **THEN** 11.1–11.6 的状态与实际一致（已落地则勾选）
