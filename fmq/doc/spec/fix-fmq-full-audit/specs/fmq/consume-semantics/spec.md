# fmq 消费语义（delta）

## MODIFIED Requirements

### Requirement: 订阅匹配规则

服务端 SHALL 按「主题完全相等 → 订阅 tags 是消息 tags 的子集（顺序无关，空集不限制）→ 过滤器求值为真」
的顺序判定，并在前一步失败时短路。BODY 只在需要评估过滤器时才解码。
当 BODY 是未在本进程注册的对象类型、无法评估过滤器时，该记录 MUST NOT 被投递给该订阅，
并 SHALL 按「无法评估 BODY 的消费出口」处理：不阻塞组、推进该组游标、记 WARN，并向触发扫描的
消费者返回一次 `FILTER_UNSUPPORTED_BODY` 语义的错误。

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
- **THEN** 该记录不被投递，组游标越过该位置，消费者收到一次 `FILTER_UNSUPPORTED_BODY` 错误

### Requirement: 确认归属校验

`ack` SHALL 只接受属于本游标、属于该订阅、且**确实已投递**的位置：位置不在未决集合、该位置已被
分配给其他订阅、或该位置尚未投递（`delivered = false`）时，SHALL 返回失败（`ACK_UNKNOWN`），
不得误推进游标。

#### Scenario: 他人消息不可确认

- **WHEN** S2 对已投递给 S1 的位置发 `ACK`
- **THEN** 返回 `ACK_UNKNOWN`，游标不变

#### Scenario: 尚未投递不可确认

- **WHEN** 位置已分配给 S2（`delivered = false`），S2 直接发 `ACK`
- **THEN** 返回 `ACK_UNKNOWN`，游标不变

#### Scenario: 已越过的位置

- **WHEN** 确认一个已在 `committed` 之前或已进死信的位置
- **THEN** 返回 `ACK_UNKNOWN`

#### Scenario: 重复确认

- **WHEN** 对同一位置连续确认两次
- **THEN** 第一次成功，第二次返回 `ACK_UNKNOWN`，游标不重复推进

### Requirement: 无匹配订阅者时暂停

若某条记录对组内任何活跃订阅都不匹配，游标 SHALL 把该位置标记为「不适用」并允许越过，
不得进入死信、不得永久阻塞组；该行为 SHALL 记 DEBUG 日志并累加跳过计数。
若匹配的订阅者当前全部离线，游标 SHALL 保留该位置为未决，不得跳过推进（保证消息不丢）；
订阅重新上线后仍可取到。
「组内无匹配」与「组内无人在线」是两种不同状态，实现 MUST NOT 混用。

#### Scenario: 组内无匹配

- **WHEN** 一条消息的 tags 与组内所有订阅都不匹配，且组内至少一个订阅在线
- **THEN** 该位置被标记为「不适用」并越过；不进入死信；后续消息可继续消费

#### Scenario: 组内无人在线

- **WHEN** 组内订阅者全部注销，队列中仍有消息
- **THEN** `committed` 不前进；订阅者重新订阅后能继续消费

#### Scenario: 后加入的匹配订阅

- **WHEN** 组内最初只有一个不匹配的订阅，某条消息被越过；之后新增一个匹配的订阅
- **THEN** 该订阅看不到已被越过的消息，但能正常消费后续消息（过滤器不追溯）

### Requirement: 订阅注销释放已分配记录

订阅注销或连接断开时，其名下「已分配未确认」的记录 SHALL 退回组内（`target` 复位为空），
可被同组其它订阅者取走。断链订阅 MUST NOT 被计入「活跃订阅」；释放 SHALL 在下一次
`CONSUME`/`sweep` 时生效，不得等待额外的巡检周期。

#### Scenario: 注销后可被他人取走

- **WHEN** 消息已分配给 S2 但未取走，S2 注销
- **THEN** S1 或新订阅者能取到该条

#### Scenario: 连接断开清理

- **WHEN** 订阅所在连接被关闭
- **THEN** 该订阅被移除，其已分配记录被释放

#### Scenario: 断链立即不活跃

- **WHEN** 订阅的连接已关闭，但巡检尚未运行
- **THEN** 同组其它订阅者下一次消费即可取到其名下记录

## ADDED Requirements

### Requirement: 无法评估 BODY 的消费出口

当扫描到「BODY 无法评估且当前订阅过滤器非空」的记录时，游标 SHALL：

1. 不向该订阅投递该记录；
2. 为该组写入一个已决项并推进 `committed`（不得停在同一位置）；
3. 记 WARN（含主题、队列、位置、组）；
4. 累加「不可评估跳过」计数；
5. 让触发本次扫描的 `CONSUME` 返回 `ERROR(FILTER_UNSUPPORTED_BODY)`，载荷含位置信息。

随后对该组的消费 SHALL 从下一条继续；同一位置 MUST NOT 重复报错。
发布侧「存在活跃非空 filter 订阅时拒绝不可评估 BODY」的保护 SHALL 保留，但不得作为唯一防线。

#### Scenario: 先发布后加过滤器

- **WHEN** 先在没有 filter 订阅时发布一条含未注册对象 BODY 的记录，随后新增非空 filter 订阅
- **THEN** 第一次消费返回 `FILTER_UNSUPPORTED_BODY`（含位置），第二次消费返回后续消息，
  组不再停摆

#### Scenario: 不重复报错

- **WHEN** 同一位置已因不可评估被越过
- **THEN** 后续 `CONSUME` 不再返回该错误

#### Scenario: 不影响其它组

- **WHEN** A 组因不可评估越过某位置
- **THEN** B 组的游标与消费不受影响

#### Scenario: 发布侧拒绝

- **WHEN** 存在非空 filter 活跃订阅时发布不可评估 BODY
- **THEN** 发布返回 `FILTER_UNSUPPORTED_BODY`，记录不落盘

### Requirement: 离线组位点保留

订阅组离线（无在线消费者）或服务重启后，其持久化位点 SHALL 继续作为段保留的依据；
消费恢复时 SHALL 从该位点继续，MUST NOT 因为内存游标缺失而把位点前移到最老段。
若位点所在段确实已被删除，SHALL 记 ERROR 后从现存最老段恢复，并在统计中暴露该异常。

#### Scenario: 离线超过 TTL

- **WHEN** 组 G 的位点指向段 3，G 离线超过 TTL，清理器运行
- **THEN** 段 3 不被删除；G 重新上线后从段 3 继续消费

#### Scenario: 重启后恢复

- **WHEN** 服务重启，G 未重新订阅，清理器运行
- **THEN** 磁盘位点仍参与保留判定

#### Scenario: 位点段被删

- **WHEN** 运维手工删除了位点所在段
- **THEN** 恢复时记 ERROR，从最老段继续，`stats` 对该组返回错误而非伪造 `backlog = 0`
