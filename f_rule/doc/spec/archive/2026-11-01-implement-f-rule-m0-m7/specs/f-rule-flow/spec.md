# Spec Delta — f-rule-flow

## Purpose

定义规则与流程编排的接缝：单条规则如何映射为可独立启动的流程、规则集如何链式编排、扇出与汇合任务的语义，以及会话信息在流程中的透传方式。它保证规则执行可以被组合进更大的流程而语义不变。

## ADDED Requirements

### Requirement: 一条规则一个 Flow

`RuleFlow.build(ruleSetId, rule, version)` SHALL 为单条规则构造一个 `ImmediateFlow`：
`category = "<ruleSetId>/<ruleId>"`、`tag = rule.version`（即规则集版本），并 SHALL 注册
`registerStart(rule.acceptableEvent)` 与 `registerEnd()`。

`category` SHALL NOT 编码事实库空间；空间绑定只存在于 `rule.factSpace`，由 `FlowContext` 在运行时解析。

#### Scenario: 命名正确

- **WHEN** 为规则集 `pricing`、规则 `R1`、版本 `v1` 构建 `RuleFlow`
- **THEN** 底层流程 `toString()` 为 `pricing/R1-v1`，可独立启动（P-01）

#### Scenario: 子流程嵌入父流程

- **WHEN** 父流程 `registerTaskByImmediateFlow(eventName: "x", subCategory: "pricing/R1", subTag: "v1")`
- **THEN** 子流程结束事件作为父流程下一跳（P-02）

### Requirement: 扇出（ResolveTask）

`ResolveTask(name, acceptable, producing, plan)` SHALL 把单个事件按 `plan` 拆成若干
`(子事件名, 子载荷)`，返回一个 `name = EventType.Multi.toString()` 的 `MultiEvent`，
其 `events` 里每个子事件的 `data` SHALL 是 `RuleEnvelope`，`session` SHALL 取自父事件的信封。

`plan` 返回空列表 SHALL 抛 `RuleException(EMPTY_FANOUT)`；`plan` 抛异常 SHALL 包装为
`RuleException(ACTION_FAILED)`。

#### Scenario: 两路扇出

- **WHEN** `plan` 返回两个子事件
- **THEN** 两个下游执行器都收到事件（P-03）

#### Scenario: 空产出

- **WHEN** `plan` 返回空列表
- **THEN** 抛 `RuleException(EMPTY_FANOUT)`（P-12）

### Requirement: 汇合（JoinTask）

`JoinTask(name, branches, output, timeout, timeoutEvent)` SHALL 按 session 累积已到达分支，
当到达集合覆盖 `branches` 全集时清空该 session 状态并返回一个 `output` 的 `TaskEvent`；
未集齐时 SHALL 返回 `DummyEvent.instance`。

`JoinTask` 的状态 SHALL 以 `RuleEnvelope.session` 为键（不读 `Event.session`），并 SHALL 使用
`ConcurrentHashMap` + 分段状态保证 `AsyncFlow` 下的线程安全；同一分支重复到达 SHALL 幂等，
不推进计数；到齐后 SHALL 立即清态，允许同一 session 发起下一轮。
不同 session 的扇出 SHALL 互不串扰。

配置 `timeout` 时，`JoinTask` SHALL 通过 `f_ticktock` 的延迟任务在超时后清态并发出
`timeoutEvent`；未配置 `timeoutEvent` 时 SHALL 发出 `ErrorEvent`。`f_ticktock` 未初始化时
`JoinTask` SHALL 在构造期记 WARN 并退化为"不超时"，SHALL NOT 静默丢弃分支状态。

#### Scenario: 收齐只发一次

- **WHEN** `branches = [a, b]`，依次到达 a、b
- **THEN** 恰好发出一次 `output`，随后 `size() == 0`（P-06）

#### Scenario: 缺一路

- **WHEN** 只有 a 到达
- **THEN** 返回 `DummyEvent`，无 `output`（P-07）

#### Scenario: 重复到达

- **WHEN** a 到达两次、b 到达一次
- **THEN** 只发出一次 `output`（P-08）

#### Scenario: 并发会话

- **WHEN** session s1 与 s2 交错扇出，分支到达顺序不同
- **THEN** 各自独立汇合，互不消费对方分支（P-09）

### Requirement: 扇出必须汇合

`ResolveTask` 的所有子事件，其后续路径 SHALL 最终汇入同一个 `JoinTask`；`JoinTask` 之前
SHALL NOT 存在通往 `EndEvent` / `registerEnd()` 的路径。

`RuleSetFlow.build()` SHALL 在构建期做可达性检查，发现"扇出后存在通往 End 的路径"时抛
`RuleException(FANOUT_WITHOUT_JOIN)`。

该约束的理由 SHALL 在实现与文档中写明：`f_egraph` 的 `ImmediateDispatcher.dispatch()` 在遇到
`EndExecutor` 时立即返回，剩余队列事件既不会在本轮执行、也**不会被清空**，而会在下一次
`start()` 时被重放——表现为跨 session 的串扰，比"丢弃"更难排查。

多层扇出时每个 `JoinTask` 的 `branches` SHALL 互不重叠，重叠 SHALL 在构建期抛
`RuleException(ILLEGAL_STATE)`（`f_egraph` 同一事件只能注册一个执行器）。

#### Scenario: 分支直达 End

- **WHEN** `ResolveTask` 的一个子事件路径直接 `registerEnd()`
- **THEN** 构建期抛 `RuleException(FANOUT_WITHOUT_JOIN)`（P-05）

#### Scenario: 残留事件回归

- **WHEN** 故意构造缺 `JoinTask` 的流程并连续 `start()` 两次
- **THEN** 测试断言第二次 `start` **会**消费第一次的残留分支（`arrivals[0] == "first-round"`），
  锁定 `f_egraph` 的 `dispatch` 遇 `EndExecutor` 提前返回且不清队列这一上游行为，防回归

> 本 Scenario 的目的是**锁定现状**而非期望值：构建期的 `FANOUT_WITHOUT_JOIN` 拦截让合法编排不会
> 走到这条路径，但一旦有人绕过校验，残留事件会被下一次 `start` 重放。用例断言「会消费」是为了让
> 上游行为变化时立刻暴露，而不是把错误行为当成约定。

### Requirement: session 透传（RuleEnvelope）

所有 `f_rule` 事件载荷 SHALL 统一包 `RuleEnvelope(session, ruleSetId, payload, traceId)`。
`RuleEnvelope.from(event)` SHALL 优先取载荷中的信封，其次回退到 `event.session`；
`RuleEnvelope.wrap(parent, payload)` SHALL 用父事件信封的元信息包裹新载荷；`unwrap()` 返回业务载荷。

下游 Task SHALL 从载荷取 session，SHALL NOT 依赖 `Event.session`——因为 `f_egraph` 的
`emit` 与 `multiEventTaskBody` 均不传递 session，会为新事件生成随机 UUID。

#### Scenario: 扇出后 session 不变

- **WHEN** 父事件信封 session 为 `s1`，经 `ResolveTask` 扇出两路
- **THEN** 两个子事件的 `Event.session` 可能不同，但 `RuleEnvelope.from(e).session == "s1"`

#### Scenario: 缺信封回退

- **WHEN** 事件载荷不是 `RuleEnvelope`
- **THEN** `from` 回退使用 `event.session`，不抛错

### Requirement: 流程上下文（FlowContext）

`FlowContext` SHALL 是"一个会话在多个 `FactSpace` 上的视图集合"，提供
`attach(envelope)` / `detach()` / `create(ruleSetId, session)` / `release(session)` /
`current()` / `bind(ctx)` / `unbind()`，以及 `session`、`ruleSetId`、`facts`（缺省空间）、
`factsOf(space)`、`spaces()`。

`factsOf(space)` SHALL 惰性创建视图，空间未声明时抛 `UNKNOWN_FACT_SPACE`；`current()` 未绑定时抛
`NO_CONTEXT`。`attach`/`detach` SHALL 以 ThreadLocal 绑定，供 `f_jit` 脚本读取。

`release(session)` SHALL 对该会话的全部空间生效，并按 `Release.Discard`（默认）/ `Archive` / `Retain`
处理事实。

#### Scenario: 多空间视图

- **WHEN** 会话 `s1` 先后访问 `orders` 与 `users`
- **THEN** `spaces()` 按首次访问顺序返回两者，两次 `facts("orders")` 返回同一视图

#### Scenario: 未声明空间

- **WHEN** `ctx.facts("nope")`
- **THEN** 抛 `RuleException(UNKNOWN_FACT_SPACE)`

### Requirement: RuleSetFlow 编排门面

`RuleSetFlow.build(engine)` SHALL 提供链式 `start(name)` / `fanout(event, branches)` /
`join(branches, output)` / `end()` / `flow`，底层 SHALL 由 `ImmediateFlow` + `ResolveTask` +
`JoinTask` 实现，`flow` 属性 SHALL 暴露底层 `ImmediateFlow` 供进一步定制。

`fanout` SHALL 校验每条分支首条规则的事实空间：分支之间存在同空间规则时 SHALL 抛
`RuleException(SAME_SPACE_FANOUT)`——同空间扇出会并发改写同一批事实，执行顺序不可控；
同空间的多条规则 SHALL 由调用方串联。

#### Scenario: 不同空间扇出

- **WHEN** 分支分别落在 `orders` 与 `users`
- **THEN** 构建成功，两分支互不干扰（P-13）

#### Scenario: 同空间扇出被拒

- **WHEN** 两个分支都是 `orders` 空间的规则
- **THEN** 构建期抛 `RuleException(SAME_SPACE_FANOUT)`（P-14）

#### Scenario: 版本切换

- **WHEN** 新 tag 注册完成后调用 `removeExceptCurrentTag()`
- **THEN** 旧 tag 被移除，新 tag 生效（P-10）；若旧 tag 仍被依赖则抛 `GraphException`（P-11）

### Requirement: 产生式接缝（RuleTask）

`RuleTask` SHALL 实现 `f_egraph.Task`，`exec(e)` 顺序为：取 `RuleEnvelope` → `FlowContext.attach` →
按可配置 `FactFactory` 把事件数据构造成事实 → `SessionRuntime.agenda.fire()` →
清空输出槽并把结果包装成下一个 `TaskEvent`（同时用 `RuleEnvelope.wrap` 保留 session/traceId）。

`RuleTask` SHALL 只读写 `ruleSet` 中声明过的空间；未声明空间 SHALL 抛 `RuleException(UNKNOWN_FACT_SPACE)`。

#### Scenario: 产生式与决策流混用

- **WHEN** 同一 session 先执行决策流规则、再执行 `RuleTask`
- **THEN** 两者看到同一批事实，`RuleTask` 的输出事件携带同一 session（I-02）
