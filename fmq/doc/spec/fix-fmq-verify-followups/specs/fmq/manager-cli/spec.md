# fmq 管理端（delta）

## ADDED Requirements

### Requirement: 子命令错误路径的稳定契约

六个管理子命令 SHALL 在成功时返回 0 并打印可读结果；服务端返回错误时 SHALL 返回 1 并打印
`MQErrorCode` 对应文案或服务端消息；客户端无法连接时 SHALL 返回 1 并打印
「无法连接消息队列服务」。这些路径 SHALL 有独立用例覆盖，不依赖端到端脚本间接断言。

#### Scenario: 注册主题成功

- **WHEN** `registerTopic /t 2` 命中健康服务端
- **THEN** 退出码为 0，随后 `listTopics` 能看到该主题

#### Scenario: 主题重复

- **WHEN** 对已存在主题再次 `registerTopic`
- **THEN** 退出码为 1

#### Scenario: 删除不存在的主题或订阅组

- **WHEN** `deleteTopic /missing` 或 `deleteSubscribeGroup /missing g`
- **THEN** 退出码为 1

#### Scenario: 订阅组依赖主题

- **WHEN** 对未注册主题执行 `registerSubscriber`
- **THEN** 退出码为 1

#### Scenario: 空列表

- **WHEN** 服务端没有任何主题或订阅组时执行 `listTopics` / `listSubscribeGroups`
- **THEN** 退出码为 0

#### Scenario: 连接失败

- **WHEN** `--server` 指向未监听端口
- **THEN** 退出码为 1
