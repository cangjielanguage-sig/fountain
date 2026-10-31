# 06 流程编排

## 1. 设计原则

`f_egraph` 提供的是**确定性事件 DAG**：一个事件名对应一个执行器，执行器返回一个事件，dispatcher 按队列顺序推进。`f_rule` 在此之上补齐三件事：

1. **一条规则一个 Flow**：规则独立注册、独立版本、独立启停；
2. **一对多扇出**：`ResolveTask` 把一个事件拆成多个子事件；
3. **多对一汇合**：`JoinTask` 等齐分支后再继续。

共享事实库不通过 `Flow` 传递，而是通过 `RuleEnvelope` + `FlowContext` 显式携带。

## 2. 一条规则一个 Flow

```cangjie
public class RuleFlow {
    /**
     * 为单条规则构建独立流程。
     * @param ruleSetId 规则集标识
     * @param rule 规则定义
     * @param version 规则集版本，作为 tag
     */
    public static func build(ruleSetId: String, rule: Rule, version: String): ImmediateFlow

    public prop flow: ImmediateFlow
    public prop ruleId: String
}
```

命名规范：

| 字段 | 取值 | 说明 |
|---|---|---|
| `category` | `"<ruleSetId>/<ruleId>"` | 规则集 + 规则唯一标识 |
| `tag` | `ruleSet.version` | 与规则集版本同步，切换即重建 |
| `registerStart(eventName)` | 规则的 `acceptableEvent` | 该规则接受的上游事件 |
| 输出事件名 | 规则 `producingEvent` | 该规则产出的事件 |

`category` 不编码事实库：规则与空间的绑定在 `rule.factSpace` 上，`RuleFlow.build()` 时写进 `FlowContext`。这样同一规则换空间不需要改流程名。

同一 `FactSpace` 的多条规则做成多个 Flow 时，它们读写同一批事实，**必须串联而不是扇出**（扇出会并发改写同一空间，执行顺序不确定）：

```cangjie
// 同空间的规则：串联，顺序由 salience 决定
parent.registerTaskByImmediateFlow(eventName: "order.created", subCategory: "pricing/R1", subTag: "v1")
parent.registerTaskByImmediateFlow(eventName: "order.vip.done", subCategory: "pricing/R2", subTag: "v1")
```

不同空间的规则可以扇出，互不干扰。

子流程嵌入父流程：

```cangjie
parent.registerTaskByImmediateFlow(
    eventName: "order.created",
    subCategory: "pricing/R1",
    subTag: "v1"
)
```

`registerTaskByImmediateFlow` 的语义（`f_egraph` 已有）：收到事件后 `flow.start(data).get().get()`，把子流程的结束事件作为父流程的下一跳。**子流程必须同时注册 `registerEnd()`**，否则永远不会返回。

### 2.1 为什么一条规则一个 Flow

| 收益 | 说明 |
|---|---|
| 独立启停 | 灰度某条规则只需 `removeExceptCurrentTag()` 或单独卸载 |
| 独立版本 | 单条规则升级不影响其他规则 |
| 独立超时 | `AsyncFlow` 可按规则配置 dispatch 超时 |
| 可观测 | 流程 `toString()` 直接含 ruleId，日志可定位 |
| 复用 | 同一规则可被多个规则集引用（category 前缀不同） |

代价：N 条规则 = N 个 `ImmediateFlow` = N 个 dispatcher。`ImmediateFlow` 的 `dispatchers` 是全进程静态 map，空流程也占一个条目。规则数上万时内存与注册耗时上升。

**约束**：Flow 模式适用于**规则数在千级以内、分支明确**的场景；规则数更大时用产生式模式（一张网络），不要把每条规则都做成 Flow。

### 2.2 版本切换

```cangjie
// v2 注册完成后
flowV2.removeExceptCurrentTag()   // 删除同 category 下非当前 tag 的所有流程
```

`removeExceptCurrentTag()` 会先调 `canBeRemoved()` 检查依赖：若旧 tag 被其他流程 `dependencied` 引用，抛 `GraphException`。因此切换顺序必须是**先注册新、再移除旧**。

## 3. ResolveTask：一对多扇出

### 3.1 背景

`f_egraph` 一个事件只能挂一个执行器：`ImmediateDispatcher.doRegister` 对同一 `acceptable` 事件重复注册直接抛 `GraphException`。但业务上常有"事件 A 需要 E1、E2 各自处理"。

已有的 `MultiEvent` 机制正好承担扇出：`ImmediateFlow` 构造时自动注册 `EventType.Multi` 执行器，其任务体 `multiEventTaskBody` 把子事件逐个 `flow.emit`。`ResolveTask` 只是把"拆解策略"标准化。

### 3.2 定义

```cangjie
public class ResolveTask <: Task {
    /**
     * @param name 任务名，用于日志与追踪
     * @param acceptable 接受的事件名
     * @param producing 产出的事件名（子事件），仅用于声明与校验
     * @param plan 拆解函数：输入原事件，输出若干 (子事件名, 子载荷)
     */
    public init(
        name!: String,
        acceptable!: Array<String>,
        producing!: Array<String>,
        plan!: (Event) -> Array<(String, Any)>
    )

    public prop name: String
    public prop acceptableEvents: Array<String>
    public prop producingEvents: Array<String>
    public func exec(e: Event): Event
}
```

`exec` 实现要点：

```cangjie
public func exec(e: Event): Event {
    let parts = plan(e)
    if (parts.size == 0) {
        throw RuleException("ResolveTask '${name}' produced no sub-event")
    }
    let events = ArrayList<Event>(parts.size)
    for ((childName, payload) in parts) {
        // name 必须是 EventType.Multi.toString()，否则 dispatcher 找不到 Multi 执行器
        events.add(TaskEvent(
            category: e.category,
            tag: e.tag,
            name: childName,
            data: RuleEnvelope.wrap(e, payload),
            session: e.session
        ))
    }
    MultiEvent(
        category: e.category,
        tag: e.tag,
        name: EventType.Multi.toString(),
        events: events,
        session: e.session
    )
}
```

### 3.3 扇出语义

```
Ea ──▶ ResolveTask(RT) ──▶ MultiEvent ──▶ Multi 执行器
                                              ├── flow.emit(Ea1)
                                              └── flow.emit(Ea2)
                                                    │
                                          ┌─────────┴─────────┐
                                          ▼                   ▼
                                        E1(Ea1)             E2(Ea2)
```

`Multi 执行器` 是 `ImmediateFlow` 构造时自动注册的，`ResolveTask` 不需要自己注册它。

### 3.4 强制约束：扇出必须汇合

`ImmediateDispatcher.dispatch()` 的实现：

```cangjie
while (let event <- getEvent()) {
    ...
    for (executor in executors) {
        executor.accept(event)
        if (let end: EndExecutor <- executor) {
            return this.end = end      // ← 立即返回，队列剩余事件被丢弃
        }
    }
}
```

因此：**任一扇出分支直达结束事件，其余分支会被静默丢弃**。这不是可以绕过的实现细节，必须在编排层强制。

规则：

1. `ResolveTask` 的所有子事件，其后续路径必须最终汇入同一个 `JoinTask`；
2. `JoinTask` 之前不允许出现 `EndEvent` / `flow.registerEnd()` 可达路径；
3. `RuleSetFlow.build()` 在构建期做可达性检查，发现"扇出后存在通往 End 的路径"直接抛 `RuleException(FANOUT_WITHOUT_JOIN)`。

### 3.5 session 传递

`ImmediateFlow.emit` 的签名是 `emit(eventType!:, name!:, data!:)`，内部构造 `DataEvent` 时**不传 session**，会用新的随机 UUID。也就是说 `MultiEvent` 扇出后，子事件的 `Event.session` 与父事件不同。

这会破坏"按 session 隔离事实库"的前提。三层处理：

| 层 | 做法 |
|---|---|
| 数据层（主） | 所有 f_rule 事件载荷统一包 `RuleEnvelope`，内含不可变的 `session`；下游 Task 从载荷取 session，不读 `Event.session` |
| 上下文层（辅） | `FlowContext.current()` 用 `ThreadLocal` 绑定当前 session，供 f_jit 脚本读取 |
| 上游扩展（长期） | 建议 `f_egraph` 给 `emit` 增加可选 `session` 参数并在 `multiEventTaskBody` 透传；该扩展向后兼容，不改变现有行为 |

`RuleEnvelope`：

```cangjie
public class RuleEnvelope <: ToString {
    /** 原始会话标识，贯穿整个流程。 */
    public let session: String
    /** 规则集标识。 */
    public let ruleSetId: String
    /** 业务载荷。 */
    public let payload: Any
    /** 透传的追踪 id，用于日志串联。 */
    public let traceId: String

    public init(session!: String, ruleSetId!: String, payload!: Any, traceId!: String = "")

    /** 从事件构造：session 优先取载荷中的信封，其次取 event.session。 */
    public static func from(event: Event): RuleEnvelope
    /** 用父事件的元信息包裹新载荷。 */
    public static func wrap(parent: Event, payload: Any): RuleEnvelope
    public func unwrap(): Any
}
```

## 4. JoinTask：多对一汇合

### 4.1 定义

```cangjie
public class JoinTask <: Task {
    /**
     * @param name 任务名
     * @param branches 期望到达的分支事件名；全集到齐才继续
     * @param output 到齐后发出的事件名
     * @param timeout 可选超时；超时发出 timeoutEvent
     * @param timeoutEvent 超时事件名，缺省发 ErrorEvent
     */
    public init(
        name!: String,
        branches!: Array<String>,
        output!: String,
        timeout!: ?Duration = None,
        timeoutEvent!: ?String = None
    )

    public prop name: String
    public prop acceptableEvents: Array<String>   // = branches
    public prop producingEvents: Array<String>    // = [output]
    public func exec(e: Event): Event
}
```

### 4.2 状态机

```
状态：Map<session, Set<arrivedBranch>>

收到分支事件 b：
  arrived.add(b)
  if arrived ⊇ branches:
    arrived.clear()
    返回 TaskEvent(output)
  else:
    返回 DummyEvent     // dispatcher 跳过，不产生下游事件
```

要点：

- **按 session 隔离**：`session` 取自 `RuleEnvelope`（见 §3.5），不是 `Event.session`；
- **幂等**：同一分支重复到达只记一次，不推进计数；
- **清态**：到齐后立即清空，允许同一 session 发起下一轮；
- **线程安全**：`exec` 可能在不同线程被调用（`AsyncFlow`），状态用 `ConcurrentHashMap` + 分段锁；
- **超时**：依赖 `f_ticktock` 定时扫描，M4 实现；超时后清态并发 `ErrorEvent`。

### 4.3 嵌套汇合

多层扇出会产生多个 JoinTask。每个 JoinTask 的 `branches` 必须互不重叠，否则同一事件名会被两个 JoinTask 竞争（`f_egraph` 同一事件只能注册一个执行器，构建期就会失败）。

命名规范：`"<ruleSetId>/join/<joinId>"`，`joinId` 由编排代码显式指定。

## 5. 共享事实库

`FlowContext` 是一个会话在**多个** `FactSpace` 上的视图集合，不是单个事实库。哪些规则共享、哪些独立，由 `rule.factSpace` 决定（见 02 §6.5）：

```
session "s1"
├── FactSpace("orders") → FactBaseView("orders", "s1")   ← R1、R2、R3 共用
├── FactSpace("users")  → FactBaseView("users",  "s1")   ← R4、R5 共用
└── FactSpace("default")→ FactBaseView("default","s1")   ← 未声明的规则
```

一个事件从入口到结束，可能穿过多个空间。`FlowContext` 按需惰性建立视图：第一次 `facts("users")` 时才创建 `FactBaseView`。

### 5.1 FlowContext

```cangjie
public class FlowContext {
    /** 按信封建立或复用会话上下文，并绑定到当前线程。 */
    public static func attach(envelope: RuleEnvelope): FlowContext
    /** 解绑当前线程；不释放会话。 */
    public static func detach(): Unit

    /** 显式创建会话上下文（流程入口使用）。 */
    public static func create(ruleSetId: String, session: String): FlowContext
    /** 释放会话：按 Release 策略丢弃 / 归档 / 保留事实。 */
    public static func release(session: String): Unit

    /** 当前线程绑定的上下文；未绑定时抛 RuleException(NO_CONTEXT)。 */
    public static func current(): FlowContext
    public static func bind(ctx: FlowContext): Unit
    public static func unbind(): Unit

    public prop session: String
    public prop ruleSetId: String

    /** 缺省空间 "default" 的事实视图。 */
    public prop facts: FactBaseView
    /** 指定空间的事实视图；空间未声明时抛 UNKNOWN_FACT_SPACE。 */
    public func factsOf(space: String): FactBaseView
    /** 当前上下文已激活的空间 id（按首次访问顺序）。 */
    public func spaces(): Array<String>
}
```

`RuleTask` / `ResolveTask` / `JoinTask` 的 `exec` 入口统一做：

```cangjie
let envelope = RuleEnvelope.from(e)
let ctx = FlowContext.attach(envelope)      // 按 session 取或建 FactBaseView
try {
    // 任务体
} finally {
    FlowContext.detach()
}
```

### 5.2 生命周期

```
流程 start
  └─ FlowContext.create(ruleSetId, session)
       ├─ 按需建立 FactBaseView(space, session)，共享级别默认 Shared
       ├─ 规则 Task 读写各自空间的事实
       ├─ f_jit 表达式通过 RuleRuntime.current().facts(space) 访问
       └─ 流程 End / Error
            └─ FlowContext.release(session) → 对该会话的全部空间生效
```

释放策略：

| 策略 | 行为 |
|---|---|
| `Release.Discard`（默认） | 丢弃会话事实 |
| `Release.Archive` | 调用注册的 `FactArchiver` 落盘 |
| `Release.Retain` | 保留 N 分钟，支持流程重入/补偿（需要定时清理） |

### 5.3 与 Rete 的关系

产生式模式下，`FactBaseView` 的事实变更直接驱动**所属空间分片**的网络传播。作用域是两维的：

| 组成 | 作用域 |
|---|---|
| `ReteNetwork` 结构（节点、连接、共享键） | `FactSpace` 级，进程内共享 |
| alpha/beta memory | `(FactSpace, session)` 级 |
| `Agenda` | `session` 级，跨空间统一排序 |

```cangjie
/** 单个 (space, session) 的网络运行态。 */
public class SessionNetwork {
    public init(network: ReteNetwork, session: String)
    public prop space: String
    public func assert(fact: Fact): FactHandle
    public func retract(handle: FactHandle): Unit
}

/** session 级运行时：持有该会话在各空间的 SessionNetwork + 一个共享议程。 */
public class SessionRuntime {
    public init(ruleSet: RuleSet, session: String)
    public func network(space: String): SessionNetwork
    public prop agenda: Agenda
    public func close(): Unit
}
```

`ReteNetwork` 只存结构与共享键；`SessionNetwork` 存该 `(space, session)` 的 alpha/beta memory。`SessionRuntime` 把同一会话的多张分片聚在一起，共享一个 `Agenda`，这样 `orders` 空间的高优先级规则可以排在 `users` 空间的中优先级规则之前执行。

## 6. 两种规则体写法

### 6.1 宿主侧 Task

```cangjie
public class DiscountTask <: Task {
    public prop name: String { get() { "discount" } }
    public prop acceptableEvents: Array<String> { get() { ["order.priced"] } }
    public prop producingEvents: Array<String> { get() { ["order.discounted"] } }

    public func exec(e: Event): Event {
        let ctx = FlowContext.attach(RuleEnvelope.from(e))
        let orders = ctx.facts("orders")          // 显式指定空间
        let order = orders.get(...)               // 业务逻辑
        orders.assert(DynamicFact("Discount", ...))
        TaskEvent(category: e.category, tag: e.tag,
                  name: "order.discounted", data: ..., session: ctx.session)
    }
}
```

适用：需要访问宿主资源（DB、HTTP）、性能敏感、逻辑复杂。

### 6.2 @JitBind 类 + f_jit 脚本

```cangjie
@JitBind
public class DiscountCalculator {
    public static func compute(amount: Int64, level: Int64): Float64 {
        if (level >= 3 && amount > 200) { 0.85 } else { 1.0 }
    }
}
```

登记：

```cangjie
let compiler = Compiler(CompileOptions(DummyDiagnosticsSink()))
compiler.registerType<DiscountCalculator>()
ClosureTask.initCompiler(compiler)
JitHostRegistry.configure(compiler)
```

脚本规则：

```cangjie
let task = ClosureTask.compile(
    "discount",
    ["order.priced"],
    ["order.discounted"],
    'flowTaskEvent(e.category, e.tag, "order.discounted",
        flowDataOf(e) + ":" + DiscountCalculator.compute(200, 3).toString())'
)
```

适用：规则频繁变更、需要业务方自行维护、需要热更新。

### 6.3 选择建议

| 维度 | 宿主 Task | JitBind + 脚本 |
|---|---|---|
| 性能 | 最高 | 解释器执行，低一个数量级 |
| 热更新 | 需重启或动态加载 | 天然支持 |
| 类型安全 | 编译期 | 脚本编译期，弱于宿主 |
| 可访问的宿主能力 | 全部 | 仅登记过的类型/函数 |
| 调试 | 原生调试器 | f_jit 的 `site` / `report` |

## 7. 编排示例

```cangjie
// 规则定义时声明所属空间
let ruleVip = Rule.builder("R1").facts("orders").addPattern(...).then(...).build()
let ruleBulk = Rule.builder("R2").facts("orders").addPattern(...).then(...).build()
let ruleLevel = Rule.builder("R3").facts("users").addPattern(...).then(...).build()

// 规则集：订单定价（orders 空间）+ 用户等级（users 空间）
let rs = RuleSet.builder("pricing")
    .version("v1")
    .factSpace("orders")
    .factSpace("users")
    .registerFact("orders", orderSchema)
    .registerFact("users", userSchema)
    .rule(ruleVip)       // R1、R2 共享 orders
    .rule(ruleBulk)
    .rule(ruleLevel)     // R3 独享 users
    .build()

// 父流程
let flow = ImmediateFlow(category: "pricing", tag: "v1")
flow.registerStart("order.created")
flow.registerEnd()
flow.registerError()

// 扇出：orders 分支与 users 分支互不干扰，可以并行
flow.registerTask(ResolveTask(
    name: "split",
    acceptable: ["order.created"],
    producing: ["order.priced.check", "user.level.check"],
    plan: { e =>
        let env = RuleEnvelope.from(e)
        [("order.priced.check", env), ("user.level.check", env)]
    }
))

// orders 分支：R1 → R2 串联（共享同一空间，必须串行）
flow.registerTaskByImmediateFlow(
    eventName: "order.priced.check", subCategory: "pricing/R1", subTag: "v1")
flow.registerTaskByImmediateFlow(
    eventName: "order.vip.done", subCategory: "pricing/R2", subTag: "v1")

// users 分支：R3 独立
flow.registerTaskByImmediateFlow(
    eventName: "user.level.check", subCategory: "pricing/R3", subTag: "v1")

// 汇合：两个空间的分支都完成才进入定价
flow.registerTask(JoinTask(
    name: "join",
    branches: ["order.bulk.done", "user.level.done"],
    output: "order.priced"
))

flow.registerTask(ClosureTask.compile("price", ["order.priced"], ["End"], "..."))

flow.removeExceptCurrentTag()
```

可达性：`order.created → split → {priced.check → vip.done → bulk.done, level.check → level.done} → join → order.priced → End`。`join` 之前没有 End，满足 §3.4 约束。

空间拓扑：

```
orders:  R1 ──▶ R2        （共享，串联）
users:   R3               （独立）
         两者仅通过 JoinTask 汇合，事实不互通
```

如果想在 R2 里用 R3 产出的等级，有两条路：

1. R3 的 `ActionContext.copyTo("orders", fact)` 把等级事实复制进 orders；
2. 或把 R2、R3 都放进同一空间，接受共享副作用。

前者是显式复制，后者是显式共享，都不存在隐式跨库可见性。

## 8. 错误处理

| 场景 | 行为 |
|---|---|
| ResolveTask 的 `plan` 抛异常 | 包装为 `ErrorEvent` 返回，由流程的 Error 执行器处理 |
| ResolveTask 产出空列表 | 抛 `RuleException(EMPTY_FANOUT)` |
| JoinTask 超时 | 发 `timeoutEvent`；未配置则发 `ErrorEvent` |
| 分支执行抛异常 | `f_egraph` 的 `TaskExecutor` 不捕获，异常直接冒泡到 `start()` 调用方；`RuleSetFlow` 统一包装 |
| 规则表达式求值失败 | 视为 `Unknown`，不产生激活，不中断流程（见 03 §6.2） |

## 9. 与 `f_egraph` 的扩展需求

以下为建议向 `f_egraph` 提出的向后兼容扩展，不阻塞 M4 实现（有 `RuleEnvelope` 兜底）：

| 编号 | 扩展 | 理由 |
|---|---|---|
| E1 | `BaseFlow.emit` 增加可选 `session` 参数，默认沿用当前行为 | 扇出后保持会话一致 |
| E2 | `multiEventTaskBody` 透传子事件 `session` | 同上 |
| E3 | `ImmediateDispatcher.dispatch` 提供 `drainMode` 选项（`StopAtEnd` / `DrainQueue`） | 允许扇出后自然收敛，减少 JoinTask 强制约束 |
| E4 | `registerTask` 允许同一事件注册多个执行器并声明顺序 | 简化 `ResolveTask` 的实现 |

E3 是影响最大的一个：如果 `dispatch` 可以选择"遇到 End 继续处理队列直到空"，扇出分支就不需要强制汇合。但这会改变 `f_egraph` 现有语义（`start()` 返回第一个 End 还是最后一个），需要单独评审。
