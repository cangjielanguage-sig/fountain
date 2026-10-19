# fmq 消费语义（delta）

## ADDED Requirements

### Requirement: 订阅匹配规则

服务端 SHALL 按「主题完全相等 → 订阅 tags 是消息 tags 的子集（顺序无关，空集不限制）→ 过滤器求值为真」
的顺序判定，并在前一步失败时短路。BODY 只在需要评估过滤器时才解码。
当 BODY 是未在本进程注册的对象类型、无法评估过滤器时，该记录 MUST NOT 被投递，
并 SHALL 以 `FILTER_UNSUPPORTED_BODY` 语义报错。

#### Scenario: 主题必须完全相等

- **WHEN** 订阅 `/a/b`，消息 topic 为 `/a/bc`
- **THEN** 不匹配

#### Scenario: tags 子集

- **WHEN** 订阅 tags `["a","b"]`，消息 tags 为 `["b","c","a"]`
- **THEN** 匹配；订阅 tags 为 `["a","x"]` 时不匹配

#### Scenario: 空订阅 tags

- **WHEN** 订阅 tags 为 `[]`
- **THEN** 任意消息 tags 都匹配

#### Scenario: 过滤器决定投递

- **WHEN** 过滤器 `$[?(@.level > 2)]`，两条消息的 level 分别为 3 与 1
- **THEN** 只有 level = 3 的那条被投递

#### Scenario: 无法评估的对象 BODY

- **WHEN** 记录 BODY 是服务端未注册的对象类型，且订阅过滤器非空
- **THEN** 该记录不被投递，并向发布者回 `FILTER_UNSUPPORTED_BODY`（不得静默丢消息）

### Requirement: 组内不重复消费

同一主题、同一队列、同一订阅组 SHALL 共享一个消费游标；一条消息在同一组内 SHALL 只被投递给
一个订阅者，不同组之间 SHALL 可以各自重复消费同一条消息。

#### Scenario: 两个订阅同组总数守恒

- **WHEN** 同组两个订阅并发消费 100 条
- **THEN** 两者收到的位置集合不相交，合起来恰好 100 条

#### Scenario: 跨组各自消费

- **WHEN** A 组已消费某条消息，B 组也订阅同一主题
- **THEN** B 组仍能取到该条消息

### Requirement: 连续确认前缀推进

游标 SHALL 维护 `committed`（已连续确认的位置）与段内所有未决位置；`committed` 只在**连续前缀**
全部确认时前进，允许乱序确认但不允许跳过空洞推进。

#### Scenario: 顺序确认

- **WHEN** 依次投递并确认 3 条
- **THEN** `committed` 每次前进，最终位于第 3 条之后

#### Scenario: 乱序确认留洞

- **WHEN** 先确认第 2、3 条而不确认第 1 条
- **THEN** `committed` 不前进；随后确认第 1 条时一次推进到第 3 条之后

#### Scenario: 空洞可重投

- **WHEN** 第 1 条未确认且超过 `ackTimeout`
- **THEN** 该条可被再次投递，不会被永久跳过

### Requirement: 超时重投

已投递未确认的记录 SHALL 在 `now - lastDeliverTime >= ackTimeout` 后重新可投递，
每次投递 SHALL 递增 `deliverCount` 并刷新投递时间。

#### Scenario: 超时后重复投递

- **WHEN** 一条消息被投递后既不确认也不释放，注入时钟前进 `ackTimeout`
- **THEN** 同一位置被再次投递，`deliverCount` 增加

#### Scenario: 未超时不重投

- **WHEN** 时钟前进不足 `ackTimeout`
- **THEN** 该位置仍处于已投递状态，不会被再次分配

### Requirement: 死信判定与按组隔离

当某条记录对某个组的投递次数超过 `deadMsgThreshold`（默认 3）时，服务端 SHALL 把它写入死信队列，
并把该位置对该组标记为已决（游标可越过）。死信 SHALL 按组独立：A 组进死信不影响 B 组。

#### Scenario: 超过阈值进死信

- **WHEN** `deadMsgThreshold = 3`，同一位置被投递 4 次仍未确认
- **THEN** 该条进入死信队列，游标可继续推进

#### Scenario: 组间隔离

- **WHEN** 同一条消息在 A 组已进死信
- **THEN** B 组仍可正常消费该条消息

#### Scenario: 死信条目内容完整

- **WHEN** 读取死信条目
- **THEN** 含原始记录字节、topic、queueIndex、组名、原位置、投递次数与入死信时间

### Requirement: 自动确认

`autoAck = true` 的订阅在消息投递时 SHALL 立即视为已确认，不留下未决项，客户端无需调用 `ack`。

#### Scenario: 自动确认推进游标

- **WHEN** 订阅 `autoAck = true` 并消费 3 条
- **THEN** 无需任何 ack，`committed` 已越过这 3 条，游标无未决残留

### Requirement: 确认归属校验

`ack` SHALL 只接受属于本游标且属于该订阅的位置：位置不在未决集合、或该位置已被分配给其他订阅并投递时，
SHALL 返回失败（`ACK_UNKNOWN`），不得误推进游标。

#### Scenario: 他人消息不可确认

- **WHEN** S2 对已投递给 S1 的位置发 `ACK`
- **THEN** 返回 `ACK_UNKNOWN`，游标不变

#### Scenario: 已越过的位置

- **WHEN** 确认一个已在 `committed` 之前或已进死信的位置
- **THEN** 返回 `ACK_UNKNOWN`

#### Scenario: 重复确认

- **WHEN** 对同一位置连续确认两次
- **THEN** 第一次成功，第二次返回 `ACK_UNKNOWN`，游标不重复推进

### Requirement: 无匹配订阅者时暂停

若某条记录对组内任何活跃订阅都不匹配，或匹配的订阅者当前全部离线，游标 SHALL 保留该位置为未决，
不得跳过推进（保证消息不丢）；订阅重新上线后仍可取到。

#### Scenario: 组内无匹配

- **WHEN** 一条消息的 tags 与组内所有订阅都不匹配
- **THEN** 该位置被标记为「不适用」并允许越过；不进入死信

#### Scenario: 组内无人在线

- **WHEN** 组内订阅者全部注销，队列中仍有消息
- **THEN** `committed` 不前进；订阅者重新订阅后能继续消费

### Requirement: 订阅注销释放已分配记录

订阅注销或连接断开时，其名下「已分配未确认」的记录 SHALL 退回组内（`target` 复位为空），
可被同组其它订阅者取走。

#### Scenario: 注销后可被他人取走

- **WHEN** 消息已分配给 S2 但未取走，S2 注销
- **THEN** S1 或新订阅者能取到该条

#### Scenario: 连接断开清理

- **WHEN** 订阅所在连接被关闭
- **THEN** 该订阅被移除，其已分配记录被释放

### Requirement: 至少一次投递与重启恢复

系统 SHALL 提供 at-least-once 语义：未确认消息在服务重启后 SHALL 被重新投递；
`committed` 之前的消息 MUST NOT 再投递。已投递记录集合只在内存，不落盘。

#### Scenario: 重启重投未确认

- **WHEN** 消费 3 条并只确认前 2 条，然后重启服务
- **THEN** 第 3 条被重新投递，第 1、2 条不再出现

#### Scenario: 位点恢复

- **WHEN** 游标重建并加载同一 `CursorStore`
- **THEN** `committed` 等于落盘值

### Requirement: 并发安全

同一游标的 `next` / `ack` / `sweep` SHALL 串行化，不得出现同一位置被两次未确认投递；
不同组/队列的游标 SHALL 互不阻塞。

#### Scenario: 并发取与确认

- **WHEN** 4 个线程交替执行 `next` 与 `ack` 共 1000 次
- **THEN** 不出现同一位置的两份未确认副本，`committed` 单调不减
