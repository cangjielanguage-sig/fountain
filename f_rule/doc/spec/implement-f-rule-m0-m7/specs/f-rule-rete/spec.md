# Spec Delta — f-rule-rete

## ADDED Requirements

### Requirement: 按 FactSpace 分片

系统 SHALL 为每个 `FactSpace` 持有**独立的** `ReteNetwork` 实例，分片只包含归属该空间的规则；
节点共享 SHALL 只在分片内发生，两个分片出现相同 alpha 签名 SHALL 各建一个节点。

一次 `assert` SHALL 只触发所属空间分片的增量传播；撤销事实 SHALL 只遍历所属分片。
重建某一分片 SHALL NOT 影响其他分片的令牌与激活。

网络结构 SHALL 与运行态分离：`ReteNetwork` 只存节点与共享键（进程内共享），
`SessionNetwork(network, session)` 存 `(space, session)` 的 alpha/beta memory，
`SessionRuntime(ruleSet, session)` 聚合该会话的多张分片并共享一个 `Agenda`。

#### Scenario: 断言不跨片

- **WHEN** 向 `a` 空间断言事实
- **THEN** `b` 空间分片的 alpha memory 大小不变（R-16）

#### Scenario: 相同签名不跨片共享

- **WHEN** `a` 与 `b` 空间都有 `Order.amount > 200` 的 alpha 签名
- **THEN** 两片各有一个 `AlphaNode`，节点总数比单空间时多 1（R-17）

#### Scenario: 按片重建

- **WHEN** 仅重建 `orders` 分片
- **THEN** `users` 分片的令牌数、激活数完全不变（R-18）

### Requirement: alpha 链与 memory

`RootNode` SHALL 按 `typeTag` 路由；`AlphaNode` SHALL 按
`(typeTag, field, op, 归一值, 右字段)` 签名共享，同一模式的多个约束 SHALL 串成链并短路；
链尾输出到 `AlphaMemory`。

`AlphaMemory` SHALL 提供 `add` / `remove` / `size` / `probe(field, key)` / `range(field, low, high)` /
`all`；`add` SHALL 幂等（同一句柄重复加入不改变大小），并 SHALL 通知全部 `rightConsumers`。

`In [A, B, C]` SHALL 展开为 `Or(Eq A, Eq B, Eq C)` 的三个 alpha 节点加一个布尔聚合节点，
聚合节点不占 memory。

#### Scenario: 单模式规则

- **WHEN** 规则只有一个模式，断言 3 条两条满足约束的事实
- **THEN** `AlphaMemory.size() == 2`，产生 2 个激活（R-01）

#### Scenario: 无规则关心类型

- **WHEN** 断言一个没有任何规则引用的 `typeTag`
- **THEN** 直接返回，不抛错（R-13）

### Requirement: beta join 与令牌

`BetaNode` SHALL 按 `(左 beta memory id, 右 alpha memory id, 归一化 join 约束)` 签名共享；
首个模式 SHALL 用哑令牌直接驱动，不建空 join。

`Token` SHALL 只存 `(parent, handle, binding)` 做结构共享，相等性 SHALL 为
`parent == parent && handle == handle`；`refCount` SHALL 在多个下游引用时递增、撤回时递减，
归零 SHALL 从 `BetaMemory` 移除并递归释放父链。`Token.bindings()` SHALL 沿父链展开一次。

`BetaMemory` SHALL 为下游 join 的左字段维护 `field -> ValueKey -> ArrayList<Token>` 的 join 索引，
并 SHALL 提供 `probeByJoin(joins, fact, factBinding)`。

#### Scenario: 两模式等值 join

- **WHEN** `p1(x) ∧ p2(y) ∧ x.k = y.k`，`x.k` 取值 {1,2,3}、`y.k` 取值 {2,3,4}
- **THEN** 激活数为 2，与嵌套循环结果一致（R-02）

#### Scenario: 令牌引用计数

- **WHEN** 一个令牌被两个下游 join 引用，随后其中一个撤回
- **THEN** 令牌仍在 `BetaMemory`；第二个撤回后从 memory 与父链释放（R-14）

#### Scenario: 缺失绑定

- **WHEN** 三模式链式 join，其中一条中间事实被撤销
- **THEN** 仅包含该事实的令牌消失，其余令牌保留（R-09）

### Requirement: 索引与规模

`AlphaMemory` SHALL 为被 join 引用的字段建两类索引：等值 `HashMap<ValueKey, ArrayList<FactHandle>>`，
有序索引 SHALL 使用 `f_concurrent.ConcurrentSkipListMap`，**不设规模上限、不退化为止有序数组**。

有序索引的实现 SHALL 是 `ConcurrentSkipListMap<RangeKey, FactHandle>`，其中
`RangeKey = (ValueKey, FactHandle.id)`，`RangeKey` 实现 `Comparable<RangeKey>` 并以 `ValueKey` 全序优先、
id 次序兜底，从而允许同值多事实共存。范围查询 SHALL 使用该 map 的
`tailer` / `header` / `sub`：

| 算子 | 查询 |
|---|---|
| `Gt v` | `tailer(v, including: false)` |
| `Ge v` | `tailer(v, including: true)` |
| `Lt v` | `header(v, including: false)` |
| `Le v` | `header(v, including: true)` |
| `Between [a,b]` | `sub(a, b, includingMin: true, includingMax: true)` |

等值索引缺失或 join 无索引时 MAY 回退全扫，但 `NetworkBuilder` SHALL 在构建期统计索引覆盖率，
低于阈值时写 WARN 并给出建议字段。

#### Scenario: 范围 join 与嵌套循环一致

- **WHEN** `x.amount` 取 1..200，`y.limit` 取随机值，join 约束 `x.amount Between [y.low, y.high]`
- **THEN** 激活集合与 `NaiveMatcher` 完全相同（R-03）

#### Scenario: 大规模有序索引

- **WHEN** 单个 alpha memory 插入 100000 条事实并按范围探测
- **THEN** 插入与探测均成功，无"索引过大退化/上限"错误

#### Scenario: 同值多事实

- **WHEN** 100 条事实的 `level` 都是 3，用 `Eq 3` 探测
- **THEN** 返回 100 个句柄

### Requirement: 增量插入、撤销与更新

`assert` SHALL 走 `FactBase.assert -> 分片路由 -> RootNode -> AlphaNode 链 -> AlphaMemory.add ->
BetaNode.rightActivate`；`rightActivate` SHALL 用左索引探测候选并按 `JoinPlan` 执行，构建期确定的计划
SHALL 在运行期不再改变。

`BetaNode` SHALL 维护 `produced: Map<FactHandle, ArrayList<Token>>`，使 `rightRetract` 为 O(k) 而非全扫重算；
`produced` 只对参与 join 的事实记录，纯 alpha 事实不记录。

`FactBase.update` SHALL 表现为 retract + assert：先全量撤回相关 token 与 activation，再以同一 id 重新插入。

同一事实触发的多个下游 SHALL 按 `node.id` 升序传播，保证跨 session 可复现的传播顺序。

#### Scenario: 撤销归零

- **WHEN** 断言两条 join 事实后撤销其中一条
- **THEN** 相关令牌数归零、对应激活被移除，另一条相关激活保留（R-08/R-09）

#### Scenario: 更新等价

- **WHEN** 对一条事实执行 `update`，字段从满足约束变为不满足
- **THEN** 原激活消失且无新激活，等价于先 retract 再 assert（R-11）

### Requirement: 冻结、重建与激活产出

网络构建完成后 SHALL 冻结：节点集合、连接关系、索引结构不变，只有 memory 内容变化；
`frozen()` SHALL 返回 true，冻结后新增规则 SHALL 抛 `NETWORK_FROZEN`。

版本变更 SHALL 按分片重建：用新版本号重建受影响分片，旧分片处理完在飞事实后卸载，
`FactSpace` 切换 rete 指针。

`TerminalNode` SHALL 实现 `TokenSink`，`leftActivate` 时展开绑定、构造 `Activation` 并交给
`ActivationSink.add`；`leftRetract` 时交给 `ActivationSink.remove`。终端 SHALL 只依赖 `ActivationSink`
接口，不直接依赖 `Agenda` 实现。

#### Scenario: 冻结后新增规则

- **WHEN** 网络已 `build` 完成，再次注册规则
- **THEN** 抛 `RuleException(NETWORK_FROZEN)`

#### Scenario: 去重激活

- **WHEN** 同一规则的同一组绑定由不同路径产生同一令牌
- **THEN** `ActivationSink.add` 只收到一次（R-10）
