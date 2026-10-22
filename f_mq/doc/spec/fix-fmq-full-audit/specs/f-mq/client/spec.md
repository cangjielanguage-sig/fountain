# f_mq 客户端（delta）

## MODIFIED Requirements

### Requirement: 客户端配置与节点表

`MQClient` SHALL 支持显式传入节点列表，或从配置项 `mqClient_hosts` 读取；节点列表顺序即节点下标。
每项 SHALL 由 `f_mq.base.MQHost.parseHost` 解析。配置缺失、为空、或存在非法项时 SHALL 在构造期抛
`MQConnectionException`，不得静默跳过。测试 SHALL 在结束后还原进程级 `Config` 状态。

#### Scenario: 从配置读取并保持顺序

- **WHEN** `mqClient_hosts = "127.0.0.1:2350, 127.0.0.1:2351"`
- **THEN** 节点表为两项且顺序一致，多余空格被去除

#### Scenario: 配置缺失

- **WHEN** 配置项不存在
- **THEN** 构造失败并抛 `MQConnectionException`，文案包含配置键名

#### Scenario: 非法地址

- **WHEN** 某一项缺少端口、端口为 0 或超过 65535、主机为空、或含非法字符
- **THEN** 该地址解析为 `None`，构造失败

#### Scenario: 用例隔离

- **WHEN** 任一用例修改 `mqClient_hosts` 后结束
- **THEN** 配置恢复为修改前的值，后续用例不读取到残留节点表

### Requirement: 发布路由与失败重试

`publish<T>(topic, body, tags!)` SHALL 先在本地校验主题与 tags，再编码记录并选择一个 owner 节点发送；
收到 `RESP`/`MQResult(0)` 即成功。收到 `NOT_OWNER` SHALL 修正所有权缓存并换下一个节点重试；
收到其它非 0 码 SHALL 抛 `MQServiceException`。全部节点都回 `NOT_OWNER` SHALL 抛
`MQServiceException(NOT_OWNER)`；全部节点连接失败 SHALL 抛 `MQConnectionException`。
非法主题或非法 tags SHALL 在本地失败，不发出任何请求。

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

#### Scenario: 全部非 owner

- **WHEN** 所有节点都回 `NOT_OWNER`（链路正常）
- **THEN** 抛 `MQServiceException`，`code == 8`，不抛 `MQConnectionException`

#### Scenario: 非法主题本地失败

- **WHEN** topic 不以 `/` 开头或含空段
- **THEN** 抛 `MQException`，且没有任何请求到达服务端

#### Scenario: 非法 tags 本地失败

- **WHEN** tags 含空串、含空白/控制字符、单个超过 128 字符、或超过 64 个
- **THEN** 抛 `MQException`，且没有任何请求到达服务端

#### Scenario: 全部节点不可达

- **WHEN** 所有配置节点均拒绝连接
- **THEN** 抛 `MQConnectionException`

### Requirement: 订阅向所有节点广播并汇总 owner

`subscribe(topic, subscribeGroup!, tags!, filter!, autoAck!)` SHALL 生成 UUID 作为 `subscribedId`，
把同一份订阅载荷发送给**所有**配置节点，并收集成功节点作为 owner 集合。
收到 `GROUP_NOT_EXIST`、`TOPIC_NOT_EXIST`、`INVALID_GROUP` 或 `INVALID_TOPIC` SHALL 中止，并向
已接受该订阅的节点补发 `UNSUBSCRIBE` 回滚后抛 `MQServiceException`。
回滚发送失败 SHALL 记 ERROR 日志，并把失败节点写入抛出异常的文案。
过滤器非法 SHALL 在本地失败、不发请求。若所有节点都不可达或都非 owner，SHALL 抛
`MQConnectionException`（全部非 owner 时可抛带说明的 `MQServiceException(NOT_OWNER)`）。

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

#### Scenario: 回滚失败可观测

- **WHEN** 回滚时节点 0 不可达
- **THEN** 仍抛出原始 `MQServiceException`，文案包含未回滚成功的节点下标，且日志有 ERROR

#### Scenario: 默认组可用

- **WHEN** `subscribeGroup = ""` 且该默认组已注册
- **THEN** 订阅正常发出并成功

### Requirement: 阻塞式消费

`consume(subscribedId)` SHALL 在 owner 集合上轮转请求；收到非空 `record` 时解码为 `MQMessage`
并填入 `segmentedIndex` / `segmentedOffset`；收到空 `record` 时换下一个 owner；
全部 owner 都空时按固定间隔（200ms）退避后重试，直到取到消息。
本轮内全部 owner 的失败原因均为**连接失败/超时**时 SHALL 抛 `MQConnectionException`，不得继续空转。
收到 `SUBSCRIBE_NOT_EXIST` SHALL 抛 `MQServiceException`（code = 7）；收到其它 `ERROR`（含
`FILTER_UNSUPPORTED_BODY`）SHALL 抛对应 `MQServiceException`，不得静默跳过。
`record` 非空但记录解码失败 SHALL 记 ERROR 并抛 `MQServiceException(INTERNAL)`，不得静默丢弃。

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

#### Scenario: 全部 owner 不可达

- **WHEN** 一轮内所有 owner 的请求都因连接失败返回空
- **THEN** 抛 `MQConnectionException`，文案包含尝试过的节点

#### Scenario: 负载不可评估

- **WHEN** 服务端回 `ERROR(FILTER_UNSUPPORTED_BODY)`
- **THEN** 抛 `MQServiceException`，`code == 10`

#### Scenario: 记录解码失败

- **WHEN** 服务端回非空 `record`，但 `MQMessageRecord.decode` 返回 `None`
- **THEN** 记 ERROR（含位置与长度）并抛 `MQServiceException(INTERNAL)`，不进入下一轮轮询

### Requirement: 确认路由

`ack(subscribedId, queueIndex, segmentedIndex, segmentedOffset)` SHALL 优先把确认发给「投递该位置」的节点
（该映射由 `consume` 记录，键包含 `queueIndex`，**发送成功后**删除）；未命中时 SHALL 向所有 owner 广播。
`ACK_UNKNOWN` SHALL 视为成功并忽略；其它错误码 SHALL 抛 `MQServiceException`；发送失败 SHALL
抛 `MQConnectionException`，并把投递映射恢复，供调用方重试。
`autoAck = true` 的订阅不记录投递来源，显式 `ack` 走广播路径。

#### Scenario: 回到投递节点

- **WHEN** 从节点 1 取到消息后 ack 该位置
- **THEN** 只有节点 1 收到 `ACK`，载荷中的 `queueIndex` 与位置和取消息时一致

#### Scenario: 两队列同位置不串台

- **WHEN** 同一节点的队列 0 与队列 2 都投递过 `(1,0)`，先 ack 队列 2 的 `(1,0)`，再消费队列 0
- **THEN** 队列 2 的游标前进；队列 0 的那条记录仍可被消费，不因 ACK 误落而丢失

#### Scenario: 未知位置广播

- **WHEN** ack 一个未经本进程 `consume` 的位置
- **THEN** 所有 owner 都收到 `ACK`；返回 `ACK_UNKNOWN` 的响应被忽略，不抛异常

#### Scenario: 发送失败可重试

- **WHEN** 投递节点在 ack 时不可达
- **THEN** 抛 `MQConnectionException`；再次 ack 同一位置时仍能命中该投递节点

#### Scenario: 服务端错误

- **WHEN** 服务端回 `ACK_UNKNOWN` 之外的非 0 码（如 `INTERNAL`）
- **THEN** 抛 `MQServiceException`，不静默吞掉

#### Scenario: autoAck 订阅

- **WHEN** 订阅时 `autoAck = true`，随后显式 ack 某位置
- **THEN** 走广播路径且不抛异常；客户端的投递映射不增长

### Requirement: 退订与生命周期

`unsubscribe(subscribedId)` SHALL 先向该订阅的所有 owner 发送 `UNSUBSCRIBE`，全部成功（或回
`SUBSCRIBE_NOT_EXIST`）后再删除本地订阅；任一发送失败 SHALL 保留本地订阅并抛
`MQConnectionException`。对本地不存在的 id SHALL 抛 `MQServiceException` 且不发请求。
`close()` SHALL 幂等，关闭全部节点连接并清空订阅；关闭后任何公开 API SHALL 抛
`MQConnectionException`。`close()` 与在途公开 API 并发时 MUST NOT 崩溃、死锁或访问已释放连接；
在途调用可以收到 `MQConnectionException`。

#### Scenario: 退订幂等

- **WHEN** 对同一 id 连续退订两次，第二次服务端回 `SUBSCRIBE_NOT_EXIST`
- **THEN** 两次调用都不抛异常

#### Scenario: 未知 id

- **WHEN** 退订一个从未订阅过的 id
- **THEN** 抛 `MQServiceException`，且没有任何请求发出

#### Scenario: 发送失败保留订阅

- **WHEN** 向某个 owner 发送 `UNSUBSCRIBE` 失败
- **THEN** 抛 `MQConnectionException`，本地订阅仍存在，重试退订可继续

#### Scenario: 关闭后可重入

- **WHEN** 连续调用两次 `close()`
- **THEN** 都不抛异常，`isClosed()` 为真

#### Scenario: 关闭后调用

- **WHEN** `close()` 之后调用 `publish` / `subscribe` / `consume` / `ack`
- **THEN** 均抛 `MQConnectionException`

#### Scenario: 关闭与调用并发

- **WHEN** 一个线程执行 `close()`，其它线程持续调用公开 API
- **THEN** 不崩溃、不永久阻塞；调用方收到 `MQConnectionException` 属预期

### Requirement: 并发安全

`MQClient` 的公开方法 SHALL 可被多线程并发调用；订阅表、投递映射、所有权缓存不得出现数据竞争；
同一 `(queueIndex, segmentedIndex, segmentedOffset)` 不得被两个线程同时认领。客户端 SHALL 在
返回消息前完成认领（按位置做原子占位），重复投递的位置对第二个线程不可见。

#### Scenario: 多线程消费不重复

- **WHEN** 4 个线程各消费 50 条，共 200 条
- **THEN** 总数为 200，位置集合无重复

#### Scenario: 关闭与调用并发

- **WHEN** 一个线程执行 `close()`，其它线程持续调用公开 API
- **THEN** 不崩溃、不永久阻塞；调用方收到 `MQConnectionException` 属预期

#### Scenario: 服务端重复投递同一位置

- **WHEN** 桩对两个线程返回同一 `(queueIndex, seq, offset)`
- **THEN** 只有一个线程返回该消息，另一个继续请求后续位置

## ADDED Requirements

### Requirement: 节点连接自愈

`MQNodePool` SHALL 在命中的连接已关闭时丢弃该连接并重建，而不是永久抛错；重建 SHALL 只阻塞该
节点，MUST NOT 持有全局锁执行 TCP 连接/DNS 解析；同一节点的并发首次建连 SHALL 只建立一条连接。
建连失败 SHALL 按节点退避（初始 200ms，指数增长，上限 5s），避免故障期间形成连接风暴。
`aliveNodes` SHALL 包含尚未建连或已关闭但可重建的节点，使发布/消费能在节点恢复后重新尝试。

#### Scenario: 节点重启后恢复

- **WHEN** 某节点连接被对端关闭，随后节点重新监听
- **THEN** 下一次请求会重建连接并成功，不需要重建 `MQClient`

#### Scenario: 慢节点不阻塞其它节点

- **WHEN** 节点 0 的地址不可达（连接超时数秒），同时向节点 1 发布
- **THEN** 节点 1 的请求不被节点 0 的建连阻塞

#### Scenario: 并发首次建连

- **WHEN** 8 个线程同时首次请求同一节点
- **THEN** 只建立一条连接，全部调用复用同一实例

#### Scenario: 关闭后不重建

- **WHEN** `MQNodePool.close()` 之后调用 `clientOf`
- **THEN** 抛 `MQConnectionException`，不建立新连接

### Requirement: 客户端可观测性

`MQClient` SHALL 使用 `LoggerFactory` 记录连接失败、请求超时、协议解码失败、记录解码失败与回滚
失败，日志 SHALL 含节点下标、主题或订阅 id、位置（可得时）。日志 MUST NOT 输出消息 BODY。
静默吞掉异常的分支 SHALL 在捕获处留下 DEBUG/WARN/ERROR 级日志。

#### Scenario: 连接失败有日志

- **WHEN** 所有节点拒绝连接
- **THEN** 每个节点至少产生一条 WARN/ERROR 日志，包含节点下标与地址

#### Scenario: 解码失败有日志

- **WHEN** 服务端回非空但无法解码的记录
- **THEN** 产生 ERROR 日志，包含订阅 id、队列与位置
