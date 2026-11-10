# 05 议程与冲突消解

## 1. 为什么需要议程

Rete 网络只负责"哪些规则被满足"。同一时刻可能有大量激活同时成立，执行顺序会改变最终结果：

- 两条规则都改 `discount`，谁后执行谁生效；
- 规则 A 产生的事实让规则 B 成立，B 又让 A 再次成立（循环）；
- 同一规则在多组绑定下成立，需要决定先处理哪一组。

议程（Agenda）负责：**排序、去重、循环控制、执行**。

## 2. 激活

```cangjie
package fountain::f_rule.agenda

public class Activation <: Hashable & Equatable<Activation> {
    public let rule: Rule
    /** 规则所属事实库空间。 */
    public let factSpace: String
    /** 绑定名 → 事实句柄；执行时按需解析成实例。 */
    public let bindings: Bindings
    /** 规则声明的优先级，越大越先执行。 */
    public let salience: Int64
    /** 产生顺序，单调递增。 */
    public let seq: Int64
    /** 条件数，用于"具体度"比较。 */
    public prop specificity: Int64

    public func hashCode(): Int64
    public operator func ==(other: Activation): Bool
}
```

相等性：`(factSpace, rule.id, bindings)`。同一规则同一组绑定只允许一个激活存在于议程中；不同空间的同名规则是不同激活。

`Bindings` 是不可变视图：

```cangjie
public class Bindings {
    public func get(binding: String): ?FactHandle
    public func resolve(binding: String): ?Fact      // 回查来源空间的 FactBase
    public func names(): Array<String>
    public func toMap(): HashMap<String, FactHandle>
}
```

## 3. 议程

议程是 **session 级**的，不是空间级：不同 `FactSpace` 的激活进入同一个队列，按统一策略排序，这样跨库的优先级比较才有意义。但每条激活的执行只作用于 `activation.factSpace` 指定的空间。

```cangjie
public class Agenda {
    public init(resolver: ConflictResolver, mode: FireMode)

    /** 新激活进入议程；重复激活被丢弃。 */
    public func add(activation: Activation): Unit

    /** Rete 撤销时同步移除；不存在时静默返回。 */
    public func remove(activation: Activation): Unit

    /**
     * 执行循环。
     * @param limit 最多执行多少个激活；-1 表示不限制（依赖 FireMode 防循环）
     * @return 实际执行的激活数
     */
    public func fire(limit: Int64 = -1): Int64

    public func size(): Int64
    public func clear(): Unit
    public func snapshot(): Array<Activation>
}
```

内部结构：

```
Agenda
├── queue: 优先队列（按 ConflictResolver 全序）
├── index: HashMap<(ruleId, bindings), Activation>   // 去重
└── firing: Bool                                      // 重入保护
```

不使用 `java.util.PriorityQueue` 式的"入队后不可变优先级"：规则执行可能 assert/retract，导致已有激活失效。实现为**惰性堆**——每次 `fire` 取堆顶前校验激活是否仍有效（对应令牌未撤回），失效则丢弃并继续取。

## 4. 冲突消解

### 4.1 策略

```cangjie
/**
 * 比较用的只读快照。放在 rule 包是为了让 RuleSet 能保存解析器，
 * 而不让 rule 反向依赖 agenda；Activation 在比较时构造本类型。
 */
public class ConflictKey {
    public let salience: Int64
    public let specificity: Int64
    public let ruleOrder: Int64
    public let seq: Int64
    public let factSpace: String
    public let ruleId: String
}

public interface ConflictResolver {
    /** LT 表示 left 先执行（与堆的最小序一致），EQ 表示交给下一个比较器。 */
    func compare(left: ConflictKey, right: ConflictKey): Ordering
}

public class SalienceResolver <: ConflictResolver     // salience 降序
public class SpecificityResolver <: ConflictResolver  // 条件数降序
public class FifoResolver <: ConflictResolver         // seq 升序
public class LifoResolver <: ConflictResolver         // seq 降序
public class RuleOrderResolver <: ConflictResolver    // 声明顺序升序
public class RuleIdResolver <: ConflictResolver       // ruleId 字典序
public class CompositeResolver <: ConflictResolver    // 依次比较，全 EQ 时用 (factSpace, ruleId) 兜底
public class DefaultConflictResolver <: ConflictResolver  // salience ↓ → specificity ↓ → ruleOrder ↑ → seq ↑

/** 工厂，返回上述策略的单例式实例。 */
public class Resolvers {
    public static func salience(): ConflictResolver
    public static func specificity(): ConflictResolver
    public static func fifo(): ConflictResolver
    public static func lifo(): ConflictResolver
    public static func ruleOrder(): ConflictResolver
    public static func ruleId(): ConflictResolver
    public static func composite(resolvers: Array<ConflictResolver>): ConflictResolver
    public static func default(): ConflictResolver
}
```

比较返回 `Ordering` 而非 `Int64`：`LT` 即「左先执行」，避免调用方记错符号方向；`EQ` 明确表示「本策略无法区分」，交给组合链的下一环。

### 4.2 默认策略

```
salience → specificity → ruleOrder → seq
```

理由：

1. `salience` 是业务显式声明的意图，最高优先；
2. `specificity` 让"更具体的规则"覆盖"更通用的规则"，符合决策表的直觉；
3. `ruleOrder` 保证同一 `salience` 下结果与书写顺序一致；
4. `seq` 兜底，保证全序（不存在两个激活比较结果为 0 的情况），避免堆不稳定。

### 4.3 自定义

```cangjie
class MyResolver <: ConflictResolver {
    public func compare(left: ConflictKey, right: ConflictKey): Ordering {
        // 业务自定义：金额大的优先。金额需在激活产生时快照进 ConflictKey，
        // 不能在比较器里读事实——fire 期间字段可能已被前面的动作改写。
        compareDesc(left.amount, right.amount)
    }
}
```

`ConflictKey` 目前只携带判定元数据（salience / specificity / ruleOrder / seq / factSpace / ruleId）。需要基于事实值的策略时，应先在激活产生阶段把关键值快照进 `Activation`（`Rule.snapshot()` 声明，见 §2），再扩展 `ConflictKey` 或自建解析器——**不要在比较器里回查事实库**。

比较器必须是**全序且无副作用**；组合策略必须保证任意两个不同激活比较不为 `EQ`，否则堆序不稳定。

## 5. 执行模式

```cangjie
public enum FireMode {
    /** 激活执行后立即失效，即使条件仍成立也不重复触发。默认。 */
    | Refract
    /** 同一规则同一组绑定在整次 fire 中只执行一次（比 Refract 更强）。 */
    | NoLoop
    /** 允许重复触发，直到议程为空或达到 limit。 */
    | Loop
}
```

| 模式 | 适用 | 风险 |
|---|---|---|
| `Refract` | 大多数业务规则 | 动作 retract 后重新 assert 会再次触发 |
| `NoLoop` | 幂等性要求高的规则（扣款、发券） | 需要额外记录已执行集合，内存随绑定数增长 |
| `Loop` | 迭代收敛类（评分、定价逼近） | 必须配 `limit`，否则死循环 |

`NoLoop` 的已执行集合按 `(ruleId, bindings)` 记录，`fire` 结束后清空；跨 `fire` 调用不保留。

## 6. fire 循环

```
fire(limit):
  if firing: throw RuleException(REENTRANT_FIRE)
  firing = true
  count = 0
  try:
    while queue 非空:
      if limit >= 0 && count >= limit: break
      act = popValid()                    # 跳过已失效激活
      if act == None: break
      if mode == Refract: queue.remove(act)      # 已弹出，无需再删
      if mode == NoLoop:
        if firedSet.contains(act): continue
        firedSet.add(act)
      execute(act)                        # 动作可能 assert/retract
      count++
  finally:
    firing = false
  return count
```

`popValid()`：

```
while queue 非空:
  act = queue.peek()
  if act.stillValid(): return queue.pop()
  queue.pop()                            # 令牌已撤回，丢弃
return None
```

`stillValid` 由 `Activation` 持有令牌引用计数，Rete 撤销时递减；归零即失效。这样避免在 `remove` 时做队列中间删除（O(n)）。

## 7. 动作

```cangjie
public interface RuleAction {
    func execute(ctx: ActionContext): Unit
}

public interface ActionContext {
    /** 当前激活所属事实库空间；动作默认只读写这个空间。 */
    public prop factSpace: String
    public func fact(binding: String): ?Fact
    public func assert(fact: Fact): FactHandle
    public func retract(handle: FactHandle): Unit
    public func update(handle: FactHandle, fact: Fact): Unit
    /** 取输出槽，决策表的 then 列写入这里。 */
    public func set(name: String, value: Any): Unit
    public func get(name: String): ?Any
    public func outputs(): HashMap<String, Any>

    /** 跨空间只读访问。 */
    public func factIn(space: String, handle: FactHandle): ?Fact
    /** 把事实复制到另一个空间，返回目标空间的新句柄。 */
    public func copyTo(space: String, fact: Fact): FactHandle
}
```

跨空间访问一律**显式**：不提供 `assertInto(space)` 之类的快捷方式，搬运必须走 `copyTo`。两条空间里的同名事实是两个独立对象，各自的撤销互不影响。

三种动作实现：

| 实现 | 来源 | 说明 |
|---|---|---|
| `ClosureAction` | 代码 `rule.then { ctx => ... }` | 宿主闭包，直接调用 |
| `TableAction` | 决策表 `then.*` 列 | 写输出槽，不产生副作用 |
| `ScriptAction` | f_jit 规则体 | 编译 `{ ctx: ActionContext => ... }` 后调用 |

三种实现都在 `rule` 包（与 `RuleAction`、`ActionContext` 同包，避免包循环），
`agenda` 包保留公开重导出，历史导入路径不变。`RuleBuilder` 的两个入口：

```cangjie
/** 公开签名不变；内部包装成 ClosureAction。 */
public func then(action: (ActionContext) -> Unit): RuleBuilder

/** 新增：脚本动作；编译失败在构建期抛 SCRIPT_COMPILE。 */
public func thenScript(source: String): RuleBuilder
```

脚本动作的 `ActionContext` 方法表由 `ScriptAction` **手工注册**（不是 `@JitBind` 宏）：
`set` 按实参静态类型注册 `Int64 / Float64 / Decimal / Bool / String` 五个重载，每个绑定
使用独立函数名。原因是 f_jit 会把 `Any` 形参映射为 `HostObject`，宏展开后
`ctx.set("x", 0.85)` 无法通过类型检查。脚本里写小数字面量时请显式带 `f64` 后缀
（`0.85f64`）以命中 `Float64` 重载；裸 `0.85` 按 Cangjie 语义是 `Decimal`。
返回 `Option`/`Any` 的方法（`fact`/`get`/`outputs`/`factIn`）尚不能表达为 f_jit 类型，
暂不进入脚本面；需要这些能力时用宿主闭包 `then { ctx => ... }`。

## 8. 异常与事务

- 动作抛出异常 → `fire` 立即终止，异常原样上抛（包 `RuleException(ACTION_FAILED)`，`caused` 保留原异常）；
- 已执行的动作**不回滚**：规则引擎不提供分布式事务；
- 需要原子性时，在动作里写业务事务，或把整批事实变更放到 `FactBaseView(space, session, Isolated)` 中，成功后 `commitToParent`。

## 9. 循环检测

除了 `limit`，提供可选的周期检测：

```cangjie
ruleSet.enableCycleDetection(window: Int64 = 10_000)
```

检测逻辑：记录最近 N 个激活的 `(ruleId, bindings)` 指纹，若同一指纹在窗口内出现超过阈值（默认 100 次），抛 `RuleException(CYCLE_LIMIT)`。检测本身有开销，默认关闭。

## 10. 与 f_egraph 的衔接

产生式模式在流程中的位置：

```
RuleFlow(collect) ──Event──▶ RuleFlow(match) ──Event──▶ RuleFlow(act) ──▶ EndEvent
                                  │
                                  └─ 内部：agenda.fire()
```

或者把整个规则集作为一个 `Task`：

```cangjie
let task = RuleTask(ruleSet)
flow.registerTask(task)
```

`RuleTask.exec(e)`：

1. 按 `RuleEnvelope` 取 session，按 `activation.factSpace` 取 `FactBaseView`；
2. 用事件数据构造事实（`FactFactory` 可配置）；
3. `agenda.fire()`；
4. 把输出槽包装成下一个 `TaskEvent` 返回。

`RuleTask` 是产生式模式与决策流模式的接缝；两种模式可以在同一流程里交替出现。
