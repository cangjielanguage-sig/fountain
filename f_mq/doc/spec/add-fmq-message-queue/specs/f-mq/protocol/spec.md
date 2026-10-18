# f_mq 协议与记录格式（delta）

## ADDED Requirements

### Requirement: 复用既有协议命令

系统 SHALL 用 `f_protocol.Command` 的既有命令承载全部 MQ 操作，不得新增命令号，也不得依赖命令的
标志位（tag）区分子类型。映射关系为：主题/订阅组注册与内部元数据同步 → `REGISTER`；注销 → `DEREGISTER`；
发布与备份 → `PUBLISH`；订阅 → `SUBSCRIBE`；退订 → `UNSUBSCRIBE`；取消息 → `CONSUME`；
确认 → `ACK`；错误 → `ERROR`；响应 → `RESP`。

#### Scenario: 工厂产出的命令正确

- **WHEN** 调用 `MQProtocol.registerTopic` / `registerGroup` / `deregister` / `publish` / `subscribe` /
  `unsubscribe` / `consume` / `ack` / `metaSync` / `publishBackup`
- **THEN** 返回消息的 `command` 分别落在 `REGISTER` / `REGISTER` / `DEREGISTER` / `PUBLISH(_)` /
  `SUBSCRIBE` / `UNSUBSCRIBE` / `CONSUME(_)` / `ACK` / `REGISTER` / `PUBLISH(_)`

#### Scenario: 不引入新命令号

- **WHEN** 检查 `f_mq` / `fmq` 的源码
- **THEN** 不存在对 `f_protocol` 命令枚举的扩展，也不存在按 tag 位解释 MQ 子类型的代码

### Requirement: 发布记录的四段字节布局

一条消息记录 SHALL 为 `codec(TOPIC:String) ‖ codec(TAGS:Array<String>) ‖ codec(MESSAGE_ID:String) ‖ codec(BODY)`，
四部分各自独立编码、连续排列，不加额外长度前缀；接收侧用同一个 `DefaultCodec` 逐段解码。

#### Scenario: 四种成分逐部分解码

- **WHEN** 对 `MQMessageRecord.encode(topic, tags, messageId, body)` 的结果依次调用
  `MQMessageRecord.topic` / `tags` / `messageId` / `body`
- **THEN** 四次调用分别得到原始的 topic、tags、messageId 与 BODY，且 `decode` 得到同一组值

#### Scenario: 支持规格列举的 BODY 类型

- **WHEN** BODY 依次取基本类型、`String`、`Decimal`、`DateTime`、`Duration`、
  `@DataAssist[props fields]` 类，以及它们的 `Array` / `ArrayList` / `HashSet` / `TreeSet` /
  `HashMap` / `TreeMap`
- **THEN** 每种类型编码后再解码，类型与值都与输入相等

#### Scenario: 空 tags 往返

- **WHEN** `tags = []`
- **THEN** 解码结果仍为空数组，而不是 `None` 或缺失

#### Scenario: 截断或多余的记录判为损坏

- **WHEN** 记录被砍掉末尾若干字节，或四段之后追加了额外字节，或记录为空
- **THEN** `decode` 返回 `None`；不抛异常，也不返回半条记录

#### Scenario: 只解前缀不影响后续段

- **WHEN** 在合法记录末尾追加字节后调用 `body(record)`
- **THEN** 仍返回原 BODY（只消费一个自描述值）；而 `decode(record)` 返回 `None`（未恰好用尽）

### Requirement: 记录字节在帧内的承载与还原

记录 SHALL 以原始字节块（`Array<Byte>`）作为 `Message` 载荷；接收侧 SHALL 通过
`MQBytes.fromData` 还原记录字节，并同时支持「字节块」与「超过编解码阈值后落临时文件」两种形态；
无法识别为字节序列时返回 `None`，不得返回空数组。

#### Scenario: 常规记录原样往返

- **WHEN** 记录长度不超过编解码器的字节池阈值
- **THEN** `MQBytes.fromData` 返回与发送端逐字节相等的数组

#### Scenario: 大记录走临时文件仍可还原

- **WHEN** 记录长度超过阈值（如 16KB），解码结果为临时文件形态
- **THEN** `MQBytes.fromData` 读回完整字节并清理临时文件与父目录，返回值逐字节等于原记录

#### Scenario: 非字节载荷不伪装成空消息

- **WHEN** 载荷是对象或 `DataNone`
- **THEN** `MQBytes.fromData` 返回 `None`，调用方据此回错误，而不是把它当成「没有消息」

### Requirement: 载荷按运行时类型分派

服务端 SHALL 用中性类型（`DataAny`）接收载荷，并按运行时 `Data` 子类型分派：字节块 → 用户记录；
`SimpleDataObject` 且 `typeInfo` 为 MQ 载荷类 → 对应命令载荷；`MQInternalMessage` → 内部消息
（再按 `kind` 解子载荷）；`DataNone` → 空载荷；其它 → 未知。

#### Scenario: 六类载荷分类正确

- **WHEN** 依次传入记录字节块、`MQTopicMeta`、`MQInternalMessage`、`DataNone`、其它对象
- **THEN** `MQProtocol.kindOf` 分别返回 `Record`、`TopicMeta`、`Internal`、`Empty`、`Unknown`

#### Scenario: 内部消息的两种 kind

- **WHEN** `MQInternalMessage.kind` 为 `metaSync` 或 `backup`
- **THEN** 子载荷字节可分别解码为 `MQMetaSyncRequest` / `MQMetaSnapshot` / `MQTopicAssignment`
  与 `MQBackupPayload`，且 `kind` 常量与设计一致

#### Scenario: 类型不匹配时不产出半成品

- **WHEN** 对一条记录字节调用 `asPayload<MQSubscribePayload>`
- **THEN** 返回 `None`，不抛异常，也不返回字段为空的默认对象

### Requirement: 响应与错误的构造

系统 SHALL 用 `Message.resp` 构造成功响应并回显请求的 `MessageID`，用 `Message.error` 构造错误响应；
错误载荷统一为 `MQResult{code, message}`。空成功响应 SHALL 用 `DataNone`，其 `asResult` 语义为 `code == 0`。

#### Scenario: 响应回显请求 id

- **WHEN** 对一条请求调用 `MQProtocol.respond(request, data)` 或 `respondEmpty(request)`
- **THEN** 响应的 `id` 等于请求的 `id`，`command` 为 `RESP(_)`

#### Scenario: 错误使用 ERROR 命令

- **WHEN** 调用 `MQProtocol.fail(request, code, message)`
- **THEN** `command` 为 `ERROR`，解码后 `MQResult.code` 与 `message` 等于入参

#### Scenario: 空成功载荷可判定

- **WHEN** 对 `respondEmpty` 的结果调用 `asResult`
- **THEN** 得到 `code == 0`

#### Scenario: 消费响应可解析

- **WHEN** 响应载荷为 `MQConsumeResult{segmentedIndex, segmentedOffset, record}`
- **THEN** `asConsumeResult` 三个字段与入参一致；载荷不是该类型时返回 `None`

### Requirement: 稳定的错误码表

系统 SHALL 提供固定数值的错误码，并保证每个码有非空且互不重复的可读文案。

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

### Requirement: 主题路径校验

系统 SHALL 只接受「非空、以 `/` 开头、不以 `/` 结尾、无空段、无空白字符」的主题名。

#### Scenario: 合法主题

- **WHEN** 校验 `/order`、`/order/create`、`/a.b-c_1`
- **THEN** 返回合法

#### Scenario: 非法主题

- **WHEN** 校验 `""`、`order`、`/order/`、`//a`、`/a b`
- **THEN** 均返回非法

### Requirement: 订阅过滤器求值

过滤器 SHALL 按以下规则求值：空串恒为真；否则用 `f_data.path` 求值该表达式，
取结果迭代器的首元素——无元素为假，`DataBool(b)` 取 `b`，`DataNone` 为假，其它类型为真。
表达式非法时 SHALL 在编译期抛异常（本地快速失败）。

#### Scenario: 空过滤器不读 BODY

- **WHEN** `filter = ""`，BODY 为 `DataNone`、标量或对象
- **THEN** 全部返回匹配

#### Scenario: 布尔路径

- **WHEN** 过滤器为 `$.enabled`，BODY 的 `enabled` 分别为 `true` / `false` / 缺失
- **THEN** 结果分别为真 / 假 / 假

#### Scenario: 谓词表达式

- **WHEN** 过滤器为 `$[?(@.age > 30)]`，BODY 的 `age` 为 40 / 20
- **THEN** 结果分别为真 / 假

#### Scenario: 存在即真

- **WHEN** 过滤器选中 `DataNone` 或非布尔值（如 `count = 3`）
- **THEN** 前者为假，后者为真

#### Scenario: 非法表达式

- **WHEN** 编译 `"order"`（不以 `$` / `@` 开头）
- **THEN** 抛异常，且异常类型与文案稳定可断言

### Requirement: 载荷类的编解码自洽

全部协议载荷类 SHALL 用 `@DataAssist[props fields]` 定义，字段带默认值，并能在 `DefaultCodec`
下完整往返；对语义为「空」的集合/字节数组（如空 `record`、空 `owners`）不得被编解码吞掉。

#### Scenario: 嵌套集合往返

- **WHEN** `MQMetaSnapshot` 含 2 个主题与 1 个订阅组，`MQBackupPayload.records` 含 3 个字节数组
- **THEN** 往返后数量、顺序与每个元素逐项相等

#### Scenario: 空记录表示无消息

- **WHEN** `MQConsumeResult.record = []`
- **THEN** 往返后仍为空数组；服务端与客户端据此判定「本次没有消息」

#### Scenario: 队列分配越界查询

- **WHEN** `MQTopicAssignment.owners = [0,1,2,0]`
- **THEN** `owner(0) == Some(0)`、`owner(3) == Some(0)`、`owner(4) == None`、`owner(-1) == None`

#### Scenario: 死信条目自描述

- **WHEN** 一条 `MQDeadLetterMessage` 往返
- **THEN** topic / queueIndex / subscribeGroup / segmentedIndex / segmentedOffset / deliverCount /
  deadTime / record 全部保持
