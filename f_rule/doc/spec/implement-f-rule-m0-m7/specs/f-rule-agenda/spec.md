# Spec Delta — f-rule-agenda

## ADDED Requirements

### Requirement: 激活与去重

`Activation` SHALL 携带 `rule`、`factSpace`、`bindings`、`salience`、`seq`、`specificity`，
相等性与哈希 SHALL 为 `(factSpace, rule.id, bindings)`：同一规则同一组绑定在议程中只允许一个激活，
不同空间的同名规则是不同激活。

`Bindings` SHALL 是不可变视图，提供 `get(binding): ?FactHandle`、`resolve(binding): ?Fact`、
`names()`、`toMap()`；`resolve` SHALL 回查 `activation.factSpace` 对应的 `FactBase`。

#### Scenario: 同绑定去重

- **WHEN** 同一规则同一组绑定连续两次进入议程
- **THEN** `Agenda.size()` 为 1（A-05 前提）

#### Scenario: 跨空间同名规则

- **WHEN** `orders/R1` 与 `users/R1` 同时满足
- **THEN** 议程中存在两个激活，`factSpace` 不同

### Requirement: 议程是会话级的惰性堆

`Agenda` SHALL 是 session 级而非 space 级：不同空间的激活进入同一队列并按统一策略排序，
每条激活的执行只作用于 `activation.factSpace`。

`Agenda` SHALL 实现为惰性堆：`fire` 取堆顶前 SHALL 校验激活是否仍有效（对应令牌未撤回），
失效则丢弃并继续取；`remove` SHALL NOT 做队列中间删除。

`Agenda` SHALL 提供 `add` / `remove` / `fire(limit!: Int64 = -1)` / `size` / `clear` / `snapshot`，
`fire` SHALL 返回实际执行的激活数。`limit` 是命名参数（仓颉惯用 `name!:` 形式），调用写作
`fire(limit: 10)`。

#### Scenario: 失效跳过

- **WHEN** 堆顶激活的事实已被前一个动作 retract
- **THEN** `fire` 跳过该激活继续执行下一个，返回值不计它（A-08）

#### Scenario: 空议程

- **WHEN** 议程为空时调用 `fire()`
- **THEN** 返回 0，不抛错

### Requirement: 冲突消解策略

`ConflictResolver` SHALL 提供 `compare(left, right: ConflictKey): Ordering`（`LT` 表示 left 先执行、
`EQ` 表示本策略无法区分，交给组合链下一环），并 SHALL 提供 6 种预置策略：
`SalienceResolver`、`SpecificityResolver`、`FifoResolver`、`LifoResolver`、`RuleOrderResolver`、
`RuleIdResolver`，以及 `CompositeResolver` 依次比较、全 `EQ` 时用 `(factSpace, ruleId)` 兜底。
策略实例通过 `Resolvers.salience()` 等工厂获取。

接口用 `ConflictKey` 而非 `Activation`：`rule` 包要保存解析器，若签名收 `Activation` 会让 `rule`
反向依赖 `agenda`。用 `Ordering` 而非 `Int64`：`LT` 即「左先执行」，避免调用方记错符号方向。

默认链 SHALL 为 `salience -> specificity -> ruleOrder -> seq`，且 SHALL 构成全序：
任意两个不同激活的比较结果都不为 `EQ`。

#### Scenario: 优先级

- **WHEN** 同一条件下 salience 分别 100 与 0 的两条规则同时激活
- **THEN** 先执行 salience 100 的（A-01）

#### Scenario: 全序

- **WHEN** 随机生成 100 个激活两两比较
- **THEN** 不存在比较结果为 0 的异激活对（A-04）

### Requirement: 执行模式

`FireMode` SHALL 支持 `Refract`（默认，执行后立即失效）、`NoLoop`（同一规则同一绑定整次 `fire` 只执行一次）、
`Loop`（允许重复触发直到议程为空或达到 `limit`）。

`NoLoop` 的已执行集合 SHALL 按 `(ruleId, bindings)` 记录，`fire` 结束后清空，跨 `fire` 调用不保留。
`Loop` 模式 SHALL 建议配 `limit`；未配置时依赖循环检测防死循环。

#### Scenario: Refract

- **WHEN** 一条 `Refract` 规则的条件在动作执行后仍成立
- **THEN** 该激活不会在本次 `fire` 内再次执行（A-05）

#### Scenario: Loop + limit

- **WHEN** `Loop` 模式且 `limit = 5`
- **THEN** `fire` 返回 5，不抛死循环错误（A-07）

### Requirement: 动作与动作上下文

动作 SHALL 实现 `RuleAction.execute(ctx: ActionContext)`。`ActionContext` SHALL 暴露
`factSpace`、`fact(binding)`、`assert`、`retract`、`update`、`set(name, value)`、`get(name)`、
`outputs()`、`factIn(space, handle)`、`copyTo(space, fact)`。

三种动作实现 SHALL 为：`ClosureAction`（宿主闭包）、`TableAction`（写输出槽、无副作用）、
`ScriptAction`（`f_jit` 编译的规则体）。

跨空间访问 SHALL 一律显式：只提供 `factIn`（只读）与 `copyTo`（物化），不提供 `assertInto`；
`assert` / `retract` / `update` SHALL 默认作用于 `ctx.factSpace`。

#### Scenario: 动作默认写回来源空间

- **WHEN** `orders` 空间的规则在动作中 `ctx.assert(fact)`
- **THEN** 事实进入 `orders` 空间，不进入其他空间

#### Scenario: 跨空间只读

- **WHEN** 动作调用 `ctx.factIn("users", handle)`
- **THEN** 能读到目标空间事实，但撤销该句柄需要目标空间的视图（本上下文不提供）

### Requirement: 循环控制与异常语义

`Agenda.fire` SHALL 具备重入保护：`fire` 期间再次调用 SHALL 抛 `RuleException(REENTRANT_FIRE)`。

`ruleSet.enableCycleDetection(window: Int64 = 10000)` SHALL 记录最近 N 个激活的
`(ruleId, bindings)` 指纹，同一指纹在窗口内出现超过阈值（默认 100）SHALL 抛
`RuleException(CYCLE_LIMIT)`；检测默认关闭。

动作抛出异常时 `fire` SHALL 立即终止并原样上抛，包装为 `RuleException(ACTION_FAILED)` 且 `caused`
保留原异常；已执行的动作 SHALL NOT 回滚。

#### Scenario: 重入

- **WHEN** 动作内部再次调用 `agenda.fire()`
- **THEN** 抛 `RuleException(REENTRANT_FIRE)`，外层 `fire` 终止（A-09）

#### Scenario: 循环收敛失败

- **WHEN** 开启循环检测，同一指纹在窗口内第 101 次出现
- **THEN** 抛 `RuleException(CYCLE_LIMIT)`（A-11）

#### Scenario: 动作异常

- **WHEN** 第 3 个激活的动作抛 `ArithmeticException`
- **THEN** `fire` 抛 `RuleException(ACTION_FAILED)`，`caused` 是该异常，前 2 个动作的结果保留（A-10）
