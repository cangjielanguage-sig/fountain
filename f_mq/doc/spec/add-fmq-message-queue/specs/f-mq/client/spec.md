# f_mq 客户端（delta）

## ADDED Requirements

### Requirement: 客户端配置与节点表

`MQClient` SHALL 支持显式传入节点列表，或从配置项 `mqClient_hosts` 读取；节点列表顺序即节点下标。
每项必须是可解析的 `host:port`。配置缺失、为空、或存在非法项时 SHALL 在构造期抛
`MQConnectionException`，不得静默跳过。

#### Scenario: 从配置读取并保持顺序

- **WHEN** `mqClient_hosts = "127.0.0.1:2350, 127.0.0.1:2351"`
- **THEN** 节点表为两项且顺序一致，多余空格被去除

#### Scenario: 配置缺失

- **WHEN** 配置项不存在
- **THEN** 构造失败并抛 `MQConnectionException`，文案包含配置键名

#### Scenario: 非法地址

- **WHEN** 某一项缺少端口、端口为 0 或超过 65535、或为空串
- **THEN** 该地址解析为 `None`，构造失败

### Requirement: 发布路由与失败重试

`publish<T>(topic, body, tags!)` SHALL 先在本地校验主题与 tags，再编码记录并选择一个 owner 节点发送；
收到 `RESP`/`MQResult(0)` 即成功。收到 `NOT_OWNER` SHALL 修正所有权缓存并换下一个节点重试；
收到 `TOPIC_NOT_EXIST` SHALL 抛 `MQServiceException`（code = 1）；全部节点不可达 SHALL 抛
`MQConnectionException`。非法主题 SHALL 在本地失败，不发出任何请求。

#### Scenario: 发往 owner 并保持字段

- **WHEN** 向已注册主题发布带 10 个 tags 的消息
- **THEN** 服务端收到的记录解码后 topic、tags（顺序不变）、body 正确，
  且帧 `id` 与记录中的 `MESSAGE_ID` 相同

#### Scenario: 主题不存在

- **WHEN** 服务端回 `ERROR(TOPIC_NOT_EXIST)`
- **THEN** 客户端抛 `MQServiceException`，`code == 1`

#### Scenario: 非 owner 自动换节点

- **WHEN** 首选节点回 `NOT_OWNER`，下一节点回成功
- **THEN** 发布最终成功，且所有权缓存被修正为实际 owner

#### Scenario: 非法主题本地失败

- **WHEN** topic 不以 `/` 开头或含空段
- **THEN** 抛 `MQException`，且没有任何请求到达服务端

#### Scenario: 全部节点不可达

- **WHEN** 所有配置节点均拒绝连接
- **THEN** 抛 `MQConnectionException`

### Requirement: 订阅向所有节点广播并汇总 owner

`subscribe(topic, subscribeGroup!, tags!, filter!, autoAck!)` SHALL 生成 UUID 作为 `subscribedId`，
把同一份订阅载荷发送给**所有**配置节点，并收集成功节点作为 owner 集合。
收到 `GROUP_NOT_EXIST` 或 `TOPIC_NOT_EXIST` SHALL 中止，并向已接受该订阅的节点补发
`UNSUBSCRIBE` 回滚后抛 `MQServiceException`。过滤器非法 SHALL 在本地失败、不发请求。
若所有节点都不可达或都非 owner，SHALL 抛 `MQConnectionException`。

#### Scenario: 返回 UUID

- **WHEN** 订阅成功
- **THEN** 返回的 `subscribedId` 可被 `UUID.tryParse` 解析

#### Scenario: 各节点收到同一 id 与同一参数

- **WHEN** 两个节点都接受订阅
- **THEN** 两边收到的 `subscribedId`、topic、group、tags、filter、autoAck 完全一致

#### Scenario: 只把接受者记为 owner

- **WHEN** 节点 0 回成功、节点 1 回 `NOT_OWNER`
- **THEN** owner 集合为 `[0]`，后续 `consume` 只向节点 0 请求

#### Scenario: 未注册订阅组回滚

- **WHEN** 节点 1 回 `GROUP_NOT_EXIST`
- **THEN** 客户端向节点 0 发送 `UNSUBSCRIBE` 并抛 `MQServiceException`（code = 3）

#### Scenario: 默认组可用

- **WHEN** `subscribeGroup = ""` 且该默认组已注册
- **THEN** 订阅正常发出并成功

### Requirement: 阻塞式消费

`consume(subscribedId)` SHALL 在 owner 集合上轮转请求；收到非空 `record` 时解码为 `MQMessage`
并填入 `segmentedIndex` / `segmentedOffset`；收到空 `record` 时换下一个 owner；
全部 owner 都空时按固定间隔（200ms）退避后重试，直到取到消息。
收到 `SUBSCRIBE_NOT_EXIST` SHALL 抛 `MQServiceException`（code = 7）。

#### Scenario: 解码并填位置

- **WHEN** 服务端回 `MQConsumeResult{7, 128, record}`
- **THEN** 返回的 `MQMessage` 的 topic / tags / body 正确，位置为 `(7, 128)`

#### Scenario: 空后换 owner

- **WHEN** owner 0 回空、owner 1 有消息
- **THEN** 同一轮内拿到消息，且 owner 0 只被请求一次

#### Scenario: 持续空则持续等待

- **WHEN** 服务端连续两次回空，第三次有消息
- **THEN** `consume` 在退避后返回该消息，不提前抛异常

#### Scenario: 订阅已失效

- **WHEN** 服务端回 `SUBSCRIBE_NOT_EXIST`
- **THEN** 抛 `MQServiceException`，`code == 7`

### Requirement: 确认路由

`ack(subscribedId, queueIndex, segmentedIndex, segmentedOffset)` SHALL 优先把确认发给「投递该位置」的节点
（该映射由 `consume` 记录，键包含 `queueIndex`，命中后删除）；未命中时 SHALL 向所有 owner 广播，
并忽略 `ACK_UNKNOWN`。`autoAck = true` 的订阅不记录投递来源，显式 `ack` 走广播路径且不抛异常。

#### Scenario: 回到投递节点

- **WHEN** 从节点 1 取到消息后 ack 该位置
- **THEN** 只有节点 1 收到 `ACK`，载荷中的 `queueIndex` 与位置和取消息时一致

#### Scenario: 两队列同位置不串台

- **WHEN** 同一节点的队列 0 与队列 2 都投递过 `(1,0)`，先 ack 队列 2 的 `(1,0)`，再消费队列 0
- **THEN** 队列 2 的游标前进；队列 0 的那条记录仍可被消费，不因 ACK 误落而丢失

#### Scenario: 未知位置广播

- **WHEN** ack 一个未经本进程 `consume` 的位置
- **THEN** 所有 owner 都收到 `ACK`；返回 `ACK_UNKNOWN` 的响应被忽略，不抛异常

#### Scenario: autoAck 订阅

- **WHEN** 订阅时 `autoAck = true`，随后显式 ack 某位置
- **THEN** 走广播路径且不抛异常；客户端的投递映射不增长

### Requirement: 退订与生命周期

`unsubscribe(subscribedId)` SHALL 向该订阅的所有 owner 发送 `UNSUBSCRIBE` 并删除本地订阅；
服务端回 `SUBSCRIBE_NOT_EXIST` 视为成功（幂等）；对本地不存在的 id SHALL 抛
`MQServiceException` 且不发请求。`close()` SHALL 幂等，关闭全部节点连接并清空订阅；
关闭后任何公开 API SHALL 抛 `MQConnectionException`。

#### Scenario: 退订幂等

- **WHEN** 对同一 id 连续退订两次，第二次服务端回 `SUBSCRIBE_NOT_EXIST`
- **THEN** 两次调用都不抛异常

#### Scenario: 未知 id

- **WHEN** 退订一个从未订阅过的 id
- **THEN** 抛 `MQServiceException`，且没有任何请求发出

#### Scenario: 关闭后可重入

- **WHEN** 连续调用两次 `close()`
- **THEN** 都不抛异常，`isClosed()` 为真

#### Scenario: 关闭后调用

- **WHEN** `close()` 之后调用 `publish` / `subscribe` / `consume` / `ack`
- **THEN** 均抛 `MQConnectionException`

### Requirement: 并发安全

`MQClient` 的公开方法 SHALL 可被多线程并发调用；订阅表、投递映射、所有权缓存不得出现数据竞争；
同一 `(segmentedIndex, segmentedOffset)` 不得被两个线程同时认领。

#### Scenario: 多线程消费不重复

- **WHEN** 4 个线程各消费 50 条，共 200 条
- **THEN** 总数为 200，位置集合无重复

#### Scenario: 关闭与调用并发

- **WHEN** 一个线程执行 `close()`，其它线程持续调用公开 API
- **THEN** 不崩溃、不永久阻塞；调用方收到 `MQConnectionException` 属预期
