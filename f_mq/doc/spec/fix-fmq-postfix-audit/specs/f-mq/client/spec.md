# f-mq/client（delta）

## ADDED Requirements

### Requirement: 客户端会话状态的最小集

`MQSubscription` SHALL 只保留运行时确实读取的状态，且每个字段 SHALL 至少有一个生产读取方：

- `subscribedId`、`topic`、`subscribeGroup` SHALL 用于日志与错误文案（连接失败、解码失败、
  退订失败至少含订阅 id 与 topic）；
- `owners`、`deliveries`、`autoAck`、`cursor` SHALL 用于路由与去重；
- `tags` SHALL 在客户端本地校验后即不再保留，除非客户端真的执行二次过滤；
- `filter`（`MQFilter` 预编译结果）MUST NOT 作为普通字段挂在订阅上：它的唯一作用是本地语法校验，
  客户端不再按它过滤投递。若未来需要客户端二次过滤，SHALL 先写规格与用例再引入。

`MQClient.subscribe` 成功后 SHALL NOT 保存任何客户端不会读取的副本；删除字段后
SHALL 保持 `unsubscribe`、`sweep`、日志的行为不变。

#### Scenario: 日志含订阅身份

- **WHEN** 某节点在 `publish`/`consume`/`unsubscribe` 时连接失败
- **THEN** WARN/ERROR 日志含订阅 id 与 topic（适用时），可直接定位是哪个订阅

#### Scenario: 过滤只由服务端执行

- **WHEN** 订阅时传入非空 `tags` 与 `filter`，服务端投递一条被服务端判定为匹配的记录
- **THEN** 客户端不因本地 `filter` 结果丢弃该记录；订阅对象中不存在未使用的 `MQFilter` 字段

#### Scenario: 删除字段不改变路由

- **WHEN** 移除 `tags`/`filter` 字段后重跑订阅、消费、退订用例
- **THEN** owner 汇总、投递映射与退订清理结果与移除前一致

### Requirement: 客户端关键路径的用例覆盖

以下场景 SHALL 各有一条直接用例（MUST NOT 只靠等价路径或渲染层用例代替）：

1. 订阅回滚失败：回滚请求本身失败时，异常文案含失败节点，且记 ERROR 日志；
2. ack 发送失败：`deliveries` 映射保留该位置，重试可成功；成功后映射删除；
3. 发布 10 个 tags：顺序保持，服务端收到同一数组；
4. 订阅 owner 汇总：节点 1 回 `NOT_OWNER` 时 owner 集合为 `[0]`；
5. 对象 BODY 端到端：`publish(对象)` → 服务端落盘 → `consume` → `message.get<T>()` 得到同值；
6. 配置还原：用例开始前键不存在、结束后仍不存在（`--filter` 单跑必须通过）。

#### Scenario: 回滚失败可观测

- **WHEN** 第二个节点拒绝订阅且回滚请求也失败
- **THEN** 抛出的异常文本包含回滚失败的节点下标，日志为 ERROR 且含 topic 与订阅 id

#### Scenario: ack 失败可重试

- **WHEN** 第一次 ack 因连接关闭失败，重连后对同一位置再次 ack
- **THEN** 第一次抛 `MQConnectionException` 且映射仍在，第二次成功且映射被删除

#### Scenario: 十个标签顺序保持

- **WHEN** `publish(topic, body, tags: ["t0"…"t9"])`
- **THEN** 服务端收到的 tags 数量为 10 且顺序与入参一致

#### Scenario: 只记接受者

- **WHEN** 两个节点中只有一个接受订阅，另一个回 `NOT_OWNER`
- **THEN** `owners == [0]`，后续 `consume` 只向该节点请求

#### Scenario: 对象 BODY 端到端

- **WHEN** 发布一个自定义对象并在另一客户端 `consume`
- **THEN** `message.get<T>()` 返回与原对象字段相等的实例，`get<String>()` 返回 `None`

#### Scenario: 配置原样还原

- **WHEN** 用例开始前 `mqClient_hosts` 不存在，用例结束后单独执行 `configIsRestoredAfterTest`
- **THEN** 该键仍不存在，断言通过

## MODIFIED Requirements

### Requirement: 节点连接自愈

客户端 SHALL 在连接被对端关闭后自动重建，且建连 MUST NOT 长时间持有全局锁。
`clientOf(nodeIndex)` SHALL 在**持有该节点锁之后**再次检查池是否已关闭；池关闭后
MUST NOT 建立新连接，已有连接 SHALL 被关闭且不留下未关闭句柄。
`close()` 与 `clientOf` 并发时：要么 `clientOf` 在关闭前完成建连（随后被 `close()` 关闭），
要么在锁内看到 `closed` 并抛 `MQConnectionException`；MUST NOT 出现「`close()` 已返回、
池中仍有活连接」的状态。

#### Scenario: 节点重启后恢复

- **WHEN** 对端关闭连接后再次发布
- **THEN** 客户端重建连接并成功发送，不永久报错

#### Scenario: 慢节点不阻塞其它节点

- **WHEN** 一个节点建连缓慢
- **THEN** 其它节点的发布/消费不受影响

#### Scenario: 并发首次建连

- **WHEN** 多线程同时对同一未连接节点调用 `clientOf`
- **THEN** 只建立一条连接，其余线程复用同一句柄

#### Scenario: 关闭后不重建

- **WHEN** `close()` 返回后再调用 `clientOf`
- **THEN** 抛 `MQConnectionException`，且不建立新连接

#### Scenario: 关闭与建连并发不泄漏

- **WHEN** 线程 A 通过外层 `closed` 检查后被挂起，线程 B 完成 `close()`，A 继续进入 `clientOf`
- **THEN** A 在节点锁内看到 `closed` 并抛异常；`close()` 返回后池中没有任何活连接

### Requirement: 退订与生命周期

`unsubscribe(subscribedId)` SHALL 先向该订阅的所有 owner 发送 `UNSUBSCRIBE`，全部成功（或回
`SUBSCRIBE_NOT_EXIST`）后再删除本地订阅；任一发送失败 SHALL 保留本地订阅并抛
`MQConnectionException`。`close()` SHALL 幂等，关闭全部节点连接并清空订阅；
关闭后任何公开 API SHALL 抛 `MQConnectionException`。
`close()` 与在途公开 API 并发时 MUST NOT 崩溃、死锁或访问已释放连接；在途调用可以收到
`MQConnectionException`。

退订 SHALL 对「本地已成功退订过的 id」幂等：对同一 id 连续退订两次，两次都 SHALL 成功返回、
不抛异常，且第二次 MUST NOT 发出请求。客户端 SHALL 用一个**有界**的「已退订 id」集合区分
「已退订」与「从未订阅」：后者（从未出现过的 id）SHALL 抛 `MQServiceException(SUBSCRIBE_NOT_EXIST)`
且不发请求。集合容量 SHALL 有上界（建议 4096），超出时按先进先出淘汰，并 SHALL 在文档中说明
「淘汰后的旧 id 再退订会按未知 id 处理」。

#### Scenario: 退订幂等

- **WHEN** 对同一 id 连续退订两次
- **THEN** 两次调用都不抛异常，第二次不发请求，`subscriptions` 与 `retired` 状态一致

#### Scenario: 未知 id

- **WHEN** 退订一个从未订阅过的 id
- **THEN** 抛 `MQServiceException`，且没有任何请求发出

#### Scenario: 退订后重试（超时场景）

- **WHEN** 第一次退订已在服务端成功但因响应丢失未返回，调用方重试同一 id
- **THEN** 第二次按已退订处理并返回成功，不因本地已删除而抛异常

#### Scenario: 发送失败保留订阅

- **WHEN** 某个 owner 的 `UNSUBSCRIBE` 发送失败
- **THEN** 抛 `MQConnectionException`，本地订阅仍在，可重试

#### Scenario: 关闭后可重入

- **WHEN** 连续调用 `close()` 两次
- **THEN** 均不抛异常

#### Scenario: 关闭后调用

- **WHEN** `close()` 后调用 `publish`/`subscribe`/`consume`/`ack`/`unsubscribe`
- **THEN** 均抛 `MQConnectionException`

#### Scenario: 关闭与调用并发

- **WHEN** 一个线程 `close()`，其它线程持续 `publish`/`consume`
- **THEN** 不崩溃、不死锁；在途调用收到 `MQConnectionException` 属预期

### Requirement: 客户端可观测性

客户端 SHALL 在连接失败、解码失败、订阅回滚失败、ack 失败时记录可定位日志：
至少含节点地址/下标、订阅 id（订阅相关操作）、topic（发布/订阅/消费相关操作）与失败原因。
日志级别 SHALL 与后果匹配：可重试的发送失败为 WARN，数据无法解码或回滚失败为 ERROR。
日志 MUST NOT 只打印异常类型而不含订阅/主题身份。

#### Scenario: 连接失败有日志

- **WHEN** 某节点不可达导致发布失败
- **THEN** WARN 日志含节点地址、topic 与异常原因

#### Scenario: 解码失败有日志

- **WHEN** 消费响应中的记录无法解码
- **THEN** ERROR 日志含节点、topic 与位置（段号/偏移）

#### Scenario: 回滚失败含节点

- **WHEN** 订阅回滚阶段某节点失败
- **THEN** ERROR 日志与异常文本都含失败节点的下标或地址

### Requirement: 客户端配置与节点表

客户端 SHALL 从 `mqClient_hosts` 读取节点表并保持顺序；缺失或非法地址 SHALL 抛
`MQConfigException`/`MQException`，MUST NOT 静默回落到默认值。
客户端测试 SHALL 在用例结束后把进程级 `Config` 恢复为**修改前的存在性与值**：
修改前键不存在时，结束后 SHALL 删除该键，MUST NOT 留下空串。
用例 MUST NOT 依赖同类中前序用例的执行顺序；单独运行任一用例 SHALL 通过。

#### Scenario: 从配置读取并保持顺序

- **WHEN** 配置为 `h1:2350,h2:2351`
- **THEN** 节点表顺序与配置一致

#### Scenario: 配置缺失

- **WHEN** 未设置 `mqClient_hosts` 且构造 `MQClient()`
- **THEN** 抛 `MQConfigException`

#### Scenario: 非法地址

- **WHEN** 配置项不是 `host:port`
- **THEN** 抛异常，不回落到默认地址

#### Scenario: 用例隔离

- **WHEN** 修改前键不存在，用例写入后结束
- **THEN** 键被删除；单独运行 `configIsRestoredAfterTest` 通过
