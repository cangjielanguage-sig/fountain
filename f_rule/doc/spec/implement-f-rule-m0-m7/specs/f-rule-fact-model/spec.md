# Spec Delta — f-rule-fact-model

## ADDED Requirements

### Requirement: 事实双形态

系统 SHALL 同时支持强类型事实与动态字典事实，两者 SHALL 能进入同一张 Rete 网络并被同一套算子求值。

强类型路径 SHALL 由 `FactSchema<T>` 注册字段访问器（`field(name, getter)` 与
`field(name, type, getter)` 两个重载）、`FactSpace.register(schema)` 登记、`TypedFact<T>` 承担 `Fact` 适配；
`TypedFact` SHALL 不做字段拷贝，`get` 每次调用注册的 getter。

动态路径 SHALL 由 `DynamicFact` 承担，支持 `init(typeTag)`、`init(typeTag, values)`、`set` / `remove` /
`freeze` / `frozen`；字段值类型 SHALL 限于
`String / Int64 / Float64 / Bool / DateTime / Decimal / Array<Any> / Set<Any>`，其余在 `assert` 阶段抛
`RuleException(TYPE_MISMATCH)`；不支持嵌套 `Fact`。

#### Scenario: 强类型取值

- **WHEN** `FactSchema<Order>` 注册了 `amount -> { o => o.amount }` 并断言 `TypedFact(Order("1", 500, 3), schema)`
- **THEN** `fact.get("amount")` 返回该对象当前的 `amount` 值

#### Scenario: 动态事实冻结

- **WHEN** 一个 `DynamicFact` 被 `FactBase.assert` 插入后再调用 `set("amount", 1)`
- **THEN** 抛 `RuleException(ILLEGAL_STATE)`，`frozen` 为 true

#### Scenario: 非法字段值

- **WHEN** 为 `DynamicFact` 的字段设置 `Object` 等未支持类型的值
- **THEN** `set` 期即抛 `RuleException(TYPE_MISMATCH)`，坏值进不了事实对象，也就进不了网络

> 实施修订：校验点在 `set` 而非 `assert`。约束更早生效——坏事实根本构造不出来，
> 不必等到断言时才发现，`assert` 只做重复插入检查。

### Requirement: 不可变与句柄语义

进入网络的事实 SHALL 不可变。`FactBase.update(handle, fact)` SHALL 等价于 `retract` + 以同一 id 重新
`assert`，且 SHALL 保持原 `FactHandle` 的 id 不变。`retract` 不存在或已撤销的句柄 SHALL 静默返回 false。

`FactHandle` SHALL 由 `(space, id, typeTag)` 构成，相等性与哈希 SHALL 只比较 `(space, id)`；`id` 在
`(space, session)` 内单调唯一。

同一 `Fact` 实例在同一 `FactBase` 内重复 `assert` SHALL 抛 `RuleException(DUPLICATE_FACT)`；
网络侧按句柄插入 SHALL 幂等（同一句柄重复进入 `AlphaMemory` 不重复计数）。

#### Scenario: update 保持句柄

- **WHEN** 对已断言事实执行 `update(handle, 新事实)`
- **THEN** 返回 true，`handle.id` 不变，后续 `get(handle)` 得到新字段值，旧激活被撤销

#### Scenario: 幂等插入不重复激活

- **WHEN** 同一句柄被网络重复传播两次
- **THEN** `AlphaMemory.size()` 与激活数都不增加

### Requirement: 值的归一与比较

系统 SHALL 以 `ValueKey` 作为索引与算子比较的统一键：`Int64/Int32/Int16/Int8` 归一为 `Int64`，
`Float64/Float32` 归一为 `Float64`，`Decimal` 保留、与整数比较时提升，`DateTime` 归一为 Unix 纳秒
`Int64`，`Array`/`Set` 保序/去重后转 `ArrayList<ValueKey>`，`String` 不做大小写折叠。

`ValueKey` SHALL 实现 `Hashable & Equatable<ValueKey>` 与 `Comparable<ValueKey>`，并且比较是**全序**：
先比域（数值 < 文本 < 布尔 < 时间 < 列表），再比域内值。跨域比较用于索引定位 SHALL 不抛错；
但排序类算子（`Gt/Ge/Lt/Le/Between`）在域不同时 SHALL 抛 `RuleException(TYPE_MISMATCH)`。

#### Scenario: 跨数值类型相等

- **WHEN** 比较 `Int64(1)` 与 `Float64(1.0)`
- **THEN** `ValueKey.of` 的结果相等

#### Scenario: 跨域排序

- **WHEN** 对 `String` 字段执行 `Gt`，右值为数字
- **THEN** 抛 `RuleException(TYPE_MISMATCH)`，不静默返回 false

### Requirement: 事实库空间与共享语义

`FactSpace` SHALL 是规则集内的命名空间：`FactSpace(id)` 声明、`register(schema)` /
`registerDynamic(typeTag, fields)` 注册类型、`hasType` / `fieldNames` / `fieldType` / `typeTags` 查询。
`RuleBuilder.facts(space)` SHALL 声明规则归属，缺省 `"default"`；决策表通过 `factSpace(space)` 整表绑定。

同一空间的多条规则 SHALL 共享同一批事实、同一张 Rete 网络分片与互相可见的副作用；不同空间 SHALL
完全隔离（事实、网络、索引、激活互不影响）。共享 SHALL 是显式声明，不存在隐式跨空间可见性。

同一 `(space, typeTag)` 以不一致的字段声明重复注册 SHALL 抛 `RuleException(DUPLICATE_TYPE)`。

#### Scenario: 共享空间

- **WHEN** R1 与 R2 都 `.facts("orders")`，R1 在动作中 retract 一条事实
- **THEN** R2 依赖该事实的激活被同步撤回

#### Scenario: 隔离空间

- **WHEN** R1 `.facts("a")`、R2 `.facts("b")`，向 `a` 断言 `Order`
- **THEN** `b` 空间的 alpha memory 与激活不发生任何变化

#### Scenario: 未声明空间归入 default

- **WHEN** 规则未调用 `.facts(...)`
- **THEN** 其 `factSpace == "default"`，与显式 `.facts("default")` 行为一致

### Requirement: 单库规则与跨空间约束

一条规则的全部 `Pattern` 与 `JoinConstraint` SHALL 属于同一 `FactSpace`；跨空间 SHALL 在构建期抛
`RuleException(CROSS_SPACE_JOIN)`。跨库关联 SHALL 只能通过 `ActionContext.copyTo(space, fact)` 显式物化。

#### Scenario: copyTo 物化

- **WHEN** `orders` 空间的规则执行 `copyTo("users", fact)`
- **THEN** `users` 空间生成新句柄，撤销源空间事实不影响目标空间事实

### Requirement: 会话隔离与事实视图

隔离键 SHALL 是二维的 `(factSpace, session)`。`FactBaseView` SHALL 暴露 `space` / `session` /
`assert` / `retract` / `get` / `scan` / `fork(childSession)` / `commitToParent()`；同一 `(space, session)`
SHALL 返回同一视图，不同组合互不可见。

`fork` 的默认隔离级别为 `Isolated`：子视图事实对父不可见，`commitToParent` 时合并；规则流默认使用
`Shared`：`FlowContext.factsOf(space)` 返回同一视图（`facts` 是缺省空间属性，仓颉不允许属性与方法同名，
故指定空间的方法命名动词化为 `factsOf`）。

#### Scenario: 会话隔离

- **WHEN** 会话 A 断言 `Order#1`，会话 B 扫描同类型
- **THEN** B 看不到该事实

#### Scenario: fork 提交

- **WHEN** 子视图 `assert` 两条事实后 `commitToParent()`
- **THEN** 父视图可扫描到这两条事实，子视图的独立撤销不影响父视图
