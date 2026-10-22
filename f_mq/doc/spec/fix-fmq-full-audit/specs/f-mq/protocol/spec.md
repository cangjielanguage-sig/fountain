# f_mq 协议（delta）

## MODIFIED Requirements

### Requirement: 记录字节在帧内的承载与还原

记录 SHALL 以原始字节块作为 `Message` 载荷；接收侧 SHALL 通过 `MQBlob.fromData` 还原记录字节，
并 SHALL 同时支持「字节块」与「超过编解码阈值后落临时文件」两种形态。
承载记录的协议载荷类（`MQConsumeResult`、`MQInternalMessage`、`MQBackupPayload`、
`MQDeadLetterMessage`）的字节字段 SHALL 使用可无损解码大载荷的字段类型；其编码结果 MUST 与
`Array<Byte>` 的 `DataCollection<Array<Byte>, Byte>` 字节布局完全一致。
无法识别为字节序列时 SHALL 返回 `None`，不得返回空数组；临时文件与其父目录 SHALL 在读取后清理，
清理失败不得改变解码结果但 SHALL 记 WARN。

#### Scenario: 常规记录原样往返

- **WHEN** 记录长度不超过编解码器的字节池阈值
- **THEN** 字节字段解码结果与发送端逐字节相等，且与同值的 `Array<Byte>` 编码字节一致

#### Scenario: 大记录走临时文件仍可还原

- **WHEN** 记录长度超过阈值（4096、16KB、1MB 各取一例）
- **THEN** 解码结果为完整字节，逐字节等于原记录；解码后 `/tmp/tmpFile*` 下不再残留该次解码的文件与目录

#### Scenario: 大记录出现在消费响应中

- **WHEN** `MQConsumeResult.record` 为 16KB 且帧经过编码/解码
- **THEN** `MQProtocol.asConsumeResult` 返回的 `record.size > 0`，内容逐字节相等

#### Scenario: 大记录出现在内部信封中

- **WHEN** `MQInternalMessage{kind = "backup"}` 的子载荷超过 4KB
- **THEN** `asInternal` 之后 `decodePayload<MQBackupPayload>` 成功，记录数量与内容不变

#### Scenario: 非字节载荷不伪装成空消息

- **WHEN** 字段收到对象、`DataNone` 或非文件流形态的 `DataInputStream`
- **THEN** 解码失败（返回 `None` 或抛出解码异常），调用方据此回错误，不得把字段降级为 `[]`

#### Scenario: 解码失败不被解释为无消息

- **WHEN** 消费响应对象存在但字节字段无法还原
- **THEN** `asConsumeResult` 返回 `None`，客户端 SHALL 视为协议错误并抛出异常，MUST NOT 触发
  「空 `record` → 换下一个 owner」

### Requirement: messageId 发布时间解析

`MessageID.toString()` SHALL 固定按 UTC 格式化时间戳，与进程本地时区无关。
`MQMessageRecord.publishTime(record): ?DateTime` SHALL 取 messageId 最后一个 `_` 之后的
23 位 `yyyyMMddHHmmss` + 9 位纳秒片段，按 UTC 解析；字段缺失、长度不符或数字非法时 SHALL 返回 `None`。
解析结果晚于当前时刻超过容差（5 分钟）时 SHALL 记 WARN；延迟判定 SHALL 把该记录视为已到期，
`lagMs` SHALL 取 0，不得出现负延迟或按「未来时间」长期不投递。

#### Scenario: 标准 ID

- **WHEN** messageId 为 `1_2_3_20261018183000123456789`
- **THEN** 解析出的 UTC 时间为 `2026-10-18T18:30:00.123456789Z`

#### Scenario: 本地时区进程生成的 ID 仍是 UTC

- **WHEN** 进程时区为 `Asia/Shanghai`，以任一 `DateTime` 构造 `MessageID` 并 `toString()`
- **THEN** 末尾 23 位等于该时刻的 UTC 墙钟时间，而不是本地时间

#### Scenario: 非标准 ID

- **WHEN** messageId 为 `mid-1` 或时间戳位数不足
- **THEN** `publishTime` 返回 `None`，延迟判定按已到期处理并记 WARN

#### Scenario: 未来时间戳

- **WHEN** 解析出的发布时间比当前时刻晚 8 小时
- **THEN** 记录 WARN；该记录不被延迟阻塞，`lagMs` 为 0

### Requirement: 载荷按运行时类型分派

服务端 SHALL 用中性类型（`DataAny`）接收载荷，并按运行时 `Data` 子类型分派：字节块 → 用户记录；
`SimpleDataObject` 且 `typeInfo` 为 MQ 载荷类 → 对应命令载荷；`MQInternalMessage` → 内部消息
（再按 `kind` 解子载荷）；`DataNone` → 空载荷；其它 → 未知。
`asPayload<T>` 与 `decodePayload<T>` SHALL 使用**严格转换**：运行时类型与 `T` 不一致时必须返回 `None`，
MUST NOT 返回字段全默认值的 `T`。`T` 为标量或字符串时，只有对应 `Data` 子类型才算匹配。

#### Scenario: 六类载荷分类正确

- **WHEN** 依次传入记录字节块、`MQTopicMeta`、`MQInternalMessage`、`DataNone`、其它对象
- **THEN** `MQProtocol.kindOf` 分别返回 `Record`、`TopicMeta`、`Internal`、`Empty`、`Unknown`

#### Scenario: 内部消息的两种 kind

- **WHEN** `MQInternalMessage.kind` 为 `metaSync` 或 `backup`
- **THEN** 子载荷字节可分别解码为 `MQMetaSyncRequest` / `MQMetaSnapshot` / `MQTopicAssignment`
-  与 `MQBackupPayload`，且 `kind` 常量与设计一致

#### Scenario: 内部消息的三种 kind

- **WHEN** `MQInternalMessage.kind` 为 `metaSync`、`backup`、`stats`
- **THEN** 子载荷字节可分别解码为 `MQMetaSyncRequest` / `MQMetaSnapshot` / `MQTopicAssignment` /
  `MQSubscribeGroupMeta` / `MQDeregisterPayload` / `MQMetaTombstone`（`metaSync`）、`MQBackupPayload`
  （`backup`）与 `String`（`stats`），且 `kind` 常量与设计一致

#### Scenario: 标量载荷不变成默认对象

- **WHEN** 往 metaSync 信封里塞入 `DataString("x")` 或 `DataReal(1)`
- **THEN** `decodePayload<MQMetaSyncRequest>` 与 `decodePayload<MQTopicAssignment>` 均返回 `None`，
  不得返回 `requesterIndex = -1` 或 `topic = ""` 的对象

#### Scenario: 类型不匹配时不产出半成品

- **WHEN** 对一条记录字节调用 `asPayload<MQSubscribePayload>`
- **THEN** 返回 `None`，不抛异常，也不返回字段为空的默认对象

### Requirement: 稳定的错误码表

系统 SHALL 提供固定数值的错误码，并保证每个码有非空且互不重复的可读文案。
每个错误码 SHALL 至少有一个可达的产生路径；`INVALID_GROUP` SHALL 由订阅组名校验产生。

| 码 | 名称 | 触发语义 |
| --- | --- | --- |
| 0 | `OK` | 成功 |
| 1 | `TOPIC_NOT_EXIST` | 发布/订阅的主题不存在 |
| 2 | `TOPIC_ALREADY_EXIST` | 重复注册主题 |
| 3 | `GROUP_NOT_EXIST` | 使用未注册的订阅组 |
| 4 | `GROUP_ALREADY_EXIST` | 重复注册订阅组 |
| 5 | `INVALID_TOPIC` | 主题不是合法绝对路径 |
| 6 | `INVALID_GROUP` | 订阅组名非法 |
| 7 | `SUBSCRIBE_NOT_EXIST` | 未知的 `subscribedId` |
| 8 | `NOT_OWNER` | 本节点不持有该主题的任何队列 |
| 9 | `ACK_UNKNOWN` | 确认位置不属于该订阅 |
| 10 | `FILTER_UNSUPPORTED_BODY` | 过滤器无法评估该 BODY |
| 11 | `INTERNAL` | 其它内部错误 |

#### Scenario: 错误码文案完整

- **WHEN** 对 0–11 每个码调用 `MQErrorCode.messageOf`
- **THEN** 返回非空字符串，且任意两个不同码的文案不相等

#### Scenario: 常量数值稳定

- **WHEN** 读取 `MQErrorCode.TOPIC_NOT_EXIST` 等常量
- **THEN** 数值与上表完全一致（对外协议契约，不得漂移）

#### Scenario: 每个码可达

- **WHEN** 遍历 0–11
- **THEN** 均能在 `f_mq`/`fmq` 中找到至少一个构造该码的非测试代码路径

## ADDED Requirements

### Requirement: 订阅组名校验

系统 SHALL 提供与 `MQTopic.isValid` 同级的组名校验：空串表示默认组、合法；非空组名 SHALL
长度不超过 255、不含空白与控制字符、不含 `/`、`\`、`:`、`%`、不以 `.` 开头或结尾。
`registerGroup`、`subscribe`、`deregister(kind="group")` 与管理端 `registerSubscriber` /
`deleteSubscribeGroup` SHALL 在本地或服务端入口执行同一校验；非法时返回 `INVALID_GROUP`，
MUST NOT 落盘、广播或创建目录。

#### Scenario: 合法组名

- **WHEN** 校验 `""`、`grp1`、`order.create-v2`
- **THEN** 全部合法

#### Scenario: 非法组名

- **WHEN** 校验 `g 1`、`g:1`、`g/1`、`g%2F`、`.g`、`g.`
- **THEN** 全部非法，服务端回 `ERROR(INVALID_GROUP)`，`metas/groups/` 下无新文件

#### Scenario: 默认组不受影响

- **WHEN** `subscribeGroup = ""`
- **THEN** 校验通过，订阅与消费行为不变

### Requirement: 注销载荷的 kind 判别

`MQDeregisterPayload` SHALL 把 `kind` 作为封闭枚举处理：`"topic"` 表示删除主题，`"group"` 表示
删除订阅组，其它任何值（含空串、大小写变体、拼写错误）SHALL 判为非法并返回 `ERROR(INTERNAL)`，
MUST NOT 落到「删除订阅组」分支，也不得删除任何元数据、订阅或游标。

#### Scenario: 精确匹配

- **WHEN** `kind = "topic"` 或 `"group"`
- **THEN** 分别进入删除主题 / 删除组路径

#### Scenario: 空 kind 不删组

- **WHEN** 收到 `MQDeregisterPayload(topic="/t", subscribeGroup="g", kind="")`
- **THEN** 回 `ERROR`，`/t` 与其组 `g` 均保持不变

#### Scenario: 大小写与拼写错误

- **WHEN** `kind = "Topic"`、`"TOPIC"`、`"subscriber"`、`"groups"`
- **THEN** 均回 `ERROR`，不产生删除副作用

### Requirement: 消息 BODY 的类型契约

`MQMessage.get<T>()` SHALL 仅在 BODY 存在、且其运行时类型与 `T` 严格匹配时返回 `Some`。
BODY 为空（`DataNone` 或空字节）、BODY 是其它 `@DataAssist` 类型、或字段转换失败时 SHALL 返回 `None`，
MUST NOT 返回字段全默认值的 `T`，也不得抛出未捕获异常。

#### Scenario: 空 BODY

- **WHEN** 发布空 BODY 后消费，调用 `msg.get<Order>()`
- **THEN** 返回 `None`

#### Scenario: 异类对象 BODY

- **WHEN** BODY 为 `Payment`，调用 `msg.get<Order>()`
- **THEN** 返回 `None`

#### Scenario: 匹配类型

- **WHEN** BODY 为 `Order{id: 7}`，调用 `msg.get<Order>()`
- **THEN** 返回 `Some(Order{id: 7})`

#### Scenario: 标量 BODY

- **WHEN** BODY 为 `Int64(3)`，调用 `msg.get<Int64>()` 与 `msg.get<Order>()`
- **THEN** 前者返回 `Some(3)`，后者返回 `None`

### Requirement: 工厂重载与帧 id 一致性

`MQProtocol.publish(record, id!)` SHALL 用传入的 `id` 构造帧头，并 SHALL 原样透传 `record` 字节、
MUST NOT 解析或改写记录内容。记录中的 `MESSAGE_ID` 与帧 id 的一致性由调用方保证：调用方 SHALL 用同一
`id.toString()` 编码记录后再传入。`metaSync` 的五个重载 SHALL 分别产出 `REGISTER`（快照请求、主题分配、
订阅组）与 `DEREGISTER`（删除载荷、删除墓碑）命令，并 SHALL 能被接收侧按子载荷类型唯一还原。

#### Scenario: 指定 id 的发布

- **WHEN** 调用方先用 `mid.toString()` 编码记录，再调用 `publish(record, id: mid)` 并往返
- **THEN** `message.id == mid`，且记录字节与传入时逐字节相等（工厂不改写）

#### Scenario: 记录 id 与帧 id 不一致

- **WHEN** 传入的 `record` 内部 `MESSAGE_ID` 与帧 id 不同
- **THEN** 工厂照常透传记录字节，不做修正（一致性由调用方负责）

#### Scenario: 删除同步走 DEREGISTER

- **WHEN** 调用 `metaSync(MQDeregisterPayload("/t", "g", "group"))`
- **THEN** `command == DEREGISTER`，子载荷解码为同一 `MQDeregisterPayload`

#### Scenario: 三类 REGISTER 子载荷可区分

- **WHEN** 分别调用 `metaSync(MQMetaSyncRequest(1))`、`metaSync(MQTopicAssignment(...))`、
  `metaSync(MQSubscribeGroupMeta(...))`
- **THEN** 三者均为 `REGISTER`，且子载荷分别按类型解码成功、互不误判
