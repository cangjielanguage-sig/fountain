# 04 Rete 网络

## 1. 目标与约束

| 目标 | 手段 |
|---|---|
| 规则数、事实数不设上限（受内存约束） | 节点共享 + 索引探测 + 令牌共享 |
| 插入/撤销只做增量传播 | alpha/beta 记忆 + 引用计数 |
| 匹配代价与规则数近似无关 | 网络结构按约束签名 hash-consing |
| 可撤销 | 每个令牌记录来源，`refCount` 归零即回收 |
| 多事实库隔离 | 按 `FactSpace` 分片，每片一张独立网络 |

网络一旦构建完成即**冻结**：节点集合、连接关系、索引结构不再变化，只有 memory 内容变化。新增规则必须重建网络（或走版本化重建）。

### 1.1 按 FactSpace 分片

一个规则集只有**一个** `ReteNetwork` 类型，但运行期持有**多个实例**，每个 `FactSpace` 一个：

```
RuleSet
├── FactSpace("orders")
│   └── ReteNetwork   ← 只包含 facts("orders") 的规则
├── FactSpace("users")
│   └── ReteNetwork   ← 只包含 facts("users") 的规则
└── FactSpace("default")
    └── ReteNetwork   ← 未声明空间的规则
```

分片规则：

| 规则 | 归属 |
|---|---|
| `.facts("orders")` | `orders` 片 |
| 未声明 | `default` 片 |
| 决策表 `.factSpace("pricing")` | 该表编译出的全部规则进 `pricing` 片 |

分片的理由：

1. 不同空间的事实集合不同，混在一张网络里 join 语义无法定义；
2. 分片后每张网络的规模更小，节点共享只在真正相关的一组规则间发生；
3. 撤销事实时只需遍历所属分片，不影响其他空间；
4. 版本重建可以按片进行，不同空间的规则可以独立升级。

**节点共享不跨片**：两个空间里出现完全相同的 alpha 签名，也各建一个节点。跨片共享会破坏"片内自洽"的可撤销性。

## 2. 网络结构

单张分片的内部结构：

```
                     RootNode
                        │ 按 typeTag 分发
        ┌───────────────┼───────────────┐
        ▼               ▼               ▼
   AlphaNode(A1)   AlphaNode(A2)   AlphaNode(A3)      ← 按 (typeTag, field, op, value) 共享
        │               │               │
        ▼               ▼               ▼
   AlphaMemory1    AlphaMemory2    AlphaMemory3
        │               │               │
        └───────┬───────┴───────┬───────┘
                ▼               ▼
           JoinNode(J1)    JoinNode(J2)                ← 按 (left, right, joinSig) 共享
                │               │
                ▼               ▼
           BetaMemory1     BetaMemory2
                │               │
                ▼               ▼
          TerminalNode     TerminalNode                ← 每个规则一个
```

一条规则 `p1(x) ∧ p2(y) ∧ x.k = y.k` 的网络：

```
AlphaNode(type=p1) → AlphaMemory(p1) ──┐
                                       ├─▶ JoinNode(x.k=y.k) → BetaMemory → Terminal(rule)
AlphaNode(type=p2) → AlphaMemory(p2) ──┘
```

注意第一个模式不走 join：`AlphaMemory(p1)` 直接作为左输入，用一个哑令牌（dummy token）驱动，避免为单模式建空 join。

## 3. 节点定义

```cangjie
package fountain::f_rule.rete

/** 网络节点公共契约。 */
public interface ReteNode {
    /** 节点唯一 id，构建期分配，用于共享键与调试。 */
    prop id: Int64
}

/** 令牌消费方：beta 节点与终端节点都实现它。 */
public interface TokenSink {
    func leftActivate(token: Token): Unit
    func leftRetract(token: Token): Unit
}

/** 根节点：按 typeTag 路由到 alpha 链。 */
public class RootNode <: ReteNode {
    public func child(typeTag: String): ?AlphaNode
}

/** alpha 节点：单事实约束测试。同一签名全局唯一。 */
public class AlphaNode <: ReteNode {
    public prop id: Int64
    public prop signature: AlphaSignature
    /** 当前节点的测试；通过后进入 successor。 */
    public prop test: (Fact) -> Bool
    /** 下一个 alpha 节点（同一模式的多个约束串成链）。 */
    public prop successor: ?AlphaNode
    /** 链尾输出到 memory。 */
    public prop output: ?AlphaMemory
    /** 沿链传播：测试通过则转交 successor，链尾写 output。 */
    public func propagate(handle: FactHandle, fact: Fact): Unit
}

/** alpha memory：匹配事实集合 + 索引。 */
public class AlphaMemory <: ReteNode {
    public prop id: Int64
    /** 以本 memory 为右输入的下游 join 节点。 */
    public prop rightConsumers: Array<BetaNode>
    public func add(handle: FactHandle, fact: Fact): Bool
    public func remove(handle: FactHandle): Bool
    public func size(): Int64
    /** 等值索引探测。 */
    public func probe(field: String, key: ValueKey): Array<FactHandle>
    /** 范围探测（闭区间）。 */
    public func range(field: String, low: ValueKey, high: ValueKey): Array<FactHandle>
    public func all(): Array<FactHandle>
}

/** 构建期确定的探测计划，运行期不重新决策。 */
public enum JoinPlan {
    /** 左侧哈希索引探测右侧值（连接算子全为 Eq）。 */
    | LeftHashProbe
    /** 左侧有序索引范围扫描。 */
    | LeftRangeScan
    /** 左集合很小：全扫左侧令牌。 */
    | LeftScan
    /** 右集合很小：遍历右侧逐条探测左索引。 */
    | RightScan
}

/** beta join 节点：left 令牌 × right alpha memory。 */
public class BetaNode <: ReteNode & TokenSink {
    public prop id: Int64
    public prop left: ?BetaMemory
    public prop right: AlphaMemory
    public prop joins: Array<JoinConstraint>
    public prop plan: JoinPlan
    /** 本节点输出的下游消费方（下一个 join 的左输入或终端）。 */
    public prop consumers: Array<TokenSink>
    /** 右激活：新事实进入时，遍历匹配的左令牌。 */
    public func rightActivate(handle: FactHandle, fact: Fact): Unit
    /** 左激活：新令牌进入时，探测右侧索引。 */
    public func leftActivate(token: Token): Unit
    public func leftRetract(token: Token): Unit
    public func rightRetract(handle: FactHandle): Unit
}

/** beta memory：令牌集合。 */
public class BetaMemory <: ReteNode {
    public prop id: Int64
    /** 以本 memory 为左输入的下游 join。 */
    public prop leftConsumers: Array<BetaNode>
    public func add(token: Token): Bool
    public func remove(token: Token): Bool
    public func tokens(): Array<Token>
    public func size(): Int64
    /**
     * 按连接约束在左集合中探测候选令牌。
     * 等值约束走哈希索引；范围约束走有序索引；无索引时全扫。
     */
    public func probeByJoin(joins: Array<JoinConstraint>, fact: Fact,
                            factBinding: String): Array<Token>
}

/** 规则终端：产出激活。 */
public class TerminalNode <: ReteNode & TokenSink {
    public prop id: Int64
    public prop ruleId: String
    /** 规则声明的脚本条件，构建期编译；空数组表示只靠模式约束。 */
    public init(id: Int64, rule: Rule, scripts!: Array<JitExpression>)
    public func activate(bindings: Bindings): Activation
    public func deactivate(bindings: Bindings): Unit
    /** 先求值脚本，全部为 true 才产出激活。 */
    public func leftActivate(token: Token): Unit
    public func leftRetract(token: Token): Unit
}
```

**脚本求值在终端而不是 alpha 节点**：脚本可以引用多个绑定（`{ o: Order, u: User => o.level > u.minLevel }`），只有到终端时全部绑定才齐备。编译放在网络构建期（`ReteNetwork.newTerminal`），失败即抛 `SCRIPT_COMPILE`，运行时只求值不编译。

忽略脚本会让规则退化为「模式匹配即触发」——这是 M2 的真实缺陷，由 `ScriptCondition_test` 的三个用例锁定（假→无激活、真→有激活、未声明绑定→构建期拒绝）。

## 4. 共享键

共享键的作用域是**单个 `FactSpace` 分片**。两个分片中出现完全相同的 alpha 或 join 签名，也各建一个节点——跨片共享会让撤销语义依赖两个库的生命周期，得不偿失。

### 4.1 Alpha 共享

```cangjie
/** 归一化后可用作 map key。 */
internal class AlphaSignature <: Hashable & Equatable<AlphaSignature> {
    let typeTag: String
    let field: String
    let op: Operator
    let value: ValueKey        // Const 归一后的值
    let rightField: ?String    // 字段对字段比较时为 Some
}
```

同一签名只建一个 `AlphaNode`，多个模式共享。决策表里大量重复的 `order.level >= 3` 只会产生一个 alpha 节点。

`In` 算子展开：`In [A, B, C]` 拆成 `Or(Eq A, Eq B, Eq C)` 三个 alpha 节点 + 一个或节点，或节点只做布尔聚合，不占 memory。

### 4.2 Beta 共享

```cangjie
internal class JoinSignature <: Hashable & Equatable<JoinSignature> {
    let leftNodeId: Int64          // 左侧 beta memory 的 id；首模式用 0
    let rightAlphaId: Int64        // 右侧 alpha memory 的 id
    let joins: Array<(String, Operator, String)>   // 归一化后的连接约束
}
```

要求左侧路径**完全一致**才能共享。两条规则前两个模式相同、第三个模式不同 → 前两个 join 共享，第三个分叉。这是 Rete 相对顺序匹配的核心收益。

### 4.3 共享的边界

不共享的情况：

- 同一 alpha 签名但 `typeTag` 不同（规范上不允许，`typeTag` 已是签名一部分）；
- join 约束顺序不同但语义等价（不做交换律归一，保持实现简单；由 `NetworkBuilder` 在构建前对约束排序，保证相同集合产生相同签名）；
- 跨规则集的网络不共享（不同 `RuleSet`，无可共享的结构）。

## 5. 令牌

```cangjie
public class Token <: Hashable & Equatable<Token> {
    /** 父令牌；首模式为 None。 */
    public let parent: ?Token
    /** 本步绑定的事实。 */
    public let handle: FactHandle
    /** 绑定名，如 "o"。 */
    public let binding: String
    /** 该令牌被多少下游节点引用；归零即回收。 */
    var refCount: Int64

    public func hashCode(): Int64
    public operator func ==(other: Token): Bool
    /** 沿父链展开绑定表；只在产生激活时调用一次。 */
    public func bindings(): Bindings
    /** 下游引用 +1。 */
    internal func retain(): Unit
    /** 下游引用 -1；归零时通知父令牌递归释放。 */
    internal func release(): Unit
    /** 父链上是否有任一事实已被撤销。 */
    public func valid(): Bool
}
```

设计要点：

1. **结构共享**：子令牌只存 `(parent, handle, binding)`，不复制父绑定表。N 个模式的规则，令牌内存 O(1) 而非 O(N)。
2. **引用计数**：同一令牌被 K 个下游 join 引用时 `refCount = K`；每个下游撤回时减一，归零才从 memory 删除。
3. **相等性**：`parent == parent && handle == handle`。同一路径的同一事实只产生一个令牌，天然去重。

## 6. 增量传播

### 6.1 插入

```cangjie
func assertFact(handle: FactHandle, fact: Fact): Unit {
    let alpha = root.child(fact.typeTag) ?? return   // 无规则关心该类型
    alpha.propagate(handle, fact)
}

func AlphaNode.propagate(handle: FactHandle, fact: Fact): Unit {
    if (!test(fact)) { return }
    match (successor) {
        case Some(next) => next.propagate(handle, fact)   // 链式测试，短路
        case None => output.add(handle, fact)             // 链尾写 memory
    }
}
```

`AlphaMemory.add` 成功后通知所有下游 `BetaNode`：

```cangjie
func AlphaMemory.add(handle, fact): Bool {
    if (!facts.add(handle)) { return false }     // 幂等：重复插入直接返回
    index(handle, fact)
    for (node in rightConsumers) { node.rightActivate(handle, fact) }
    true
}
```

`rightActivate` 选择 build/probe：

```cangjie
func BetaNode.rightActivate(handle, fact): Unit {
    // 右侧单事实：用左侧索引找候选令牌；左侧令牌数通常更少时反之。
    let candidates = left.probeByJoin(joins, fact)   // 索引探测，不全扫
    for (token in candidates) {
        if (testJoins(token, fact)) {
            let child = Token(parent: token, handle: handle, binding: rightBinding)
            betaMemory.add(child)
            propagateDownstream(child)
        }
    }
}
```

### 6.2 撤销

```cangjie
func AlphaMemory.remove(handle): Bool {
    if (!facts.remove(handle)) { return false }
    for (node in rightConsumers) { node.rightRetract(handle) }
    unindex(handle)
    true
}

func BetaNode.rightRetract(handle): Unit {
    // 关键：不能让右侧事实走后再重算 join。
    // 维护 produced: Map<FactHandle, ArrayList<Token>>，撤销 O(k)。
    if (let Some(tokens) <- produced.remove(handle)) {
        for (token in tokens) {
            betaMemory.remove(token)
            token.release()          // refCount--
            propagateRetractDownstream(token)
        }
    }
}
```

`produced` 是 join 节点为撤销付出的额外索引。没有它，撤销需要全扫 `betaMemory` 重算 join。

### 6.3 更新

```cangjie
func FactBase.update(handle, fact): Bool {
    retract(handle)                 // 全量撤回 token 与 activation
    assertWithId(handle, fact)      // 复用同一 id，网络侧无感知
}
```

不允许"原地改字段再重跑"：索引键会变，必须走完整撤销 + 重新插入。

### 6.4 传播顺序

同一事实触发的多个下游按 `node.id` 升序传播，保证跨 session 可复现的激活顺序；激活的最终顺序由 Agenda 的冲突消解决定，与传播顺序解耦。

## 7. 索引

### 7.1 Alpha 索引

每个 `AlphaMemory` 对其事实的**全部被 join 引用的字段**建索引：

```cangjie
class AlphaMemory {
    // 等值索引
    private let eqIndex: HashMap<String, HashMap<ValueKey, ArrayList<FactHandle>>>
    // 有序索引，用于 Gt/Ge/Lt/Le/Between
    private let ordIndex: HashMap<String, SortedIndex>
    // 空值桶
    private let nullSet: HashSet<FactHandle>
}
```

`SortedIndex` 若 `f_collection` 无现成实现，用跳表（期望 O(log n) 插入/查询）。索引按需建立：只有被 join 引用的字段才建，避免无谓内存。

### 7.2 Beta 索引

`BetaMemory` 为下游 join 的左字段建索引：

```cangjie
class BetaMemory {
    // field → ValueKey → 令牌
    private let joinIndex: HashMap<String, HashMap<ValueKey, ArrayList<Token>>>
}
```

### 7.3 build / probe 选择

`rightActivate` 时右侧是单事实，左侧是集合：

- 若连接算子全是 `Eq` → 用左索引探测右侧值，O(1) 次哈希查找；
- 若有范围算子 → 用左有序索引范围扫描；
- 若左集合很小（< 32）且无索引 → 全扫左侧令牌；
- 若右侧 alpha memory 很小且左侧有索引 → 反向遍历右侧，逐条探测。

选择规则在构建期确定并记录（`BetaNode.plan`），运行期不重新决策。

## 8. 激活产出

```cangjie
func TerminalNode.activate(token: Token): Unit {
    let bindings = token.bindings()          // 沿父链展开一次
    let act = Activation(rule, bindings, salience: rule.salience, seq: nextSeq())
    agenda.add(act)
}
```

同一规则同一组绑定可能由不同路径产生同一令牌 → `Token` 相等性保证不重复激活。`Agenda.add` 再做一次 `(ruleId, bindings)` 去重。

## 9. 冻结与重建

```cangjie
public class ReteNetwork {
    /** @param space 该分片归属的事实库空间 */
    public init(space: String)
    /** 构建该分片的规则子集，完成后冻结。 */
    public func build(rules: Array<Rule>, registry: FactSpaceRegistry): Unit
    public func assert(handle: FactHandle, fact: Fact): Unit
    public func retract(handle: FactHandle): Unit
    public func frozen(): Bool
    public prop space: String
}
```

规则集变更（增删规则、改条件）不支持原地修改：

1. 用新版本号重建**受影响的分片**；
2. 旧分片处理完在飞事实后卸载；
3. `FactSpace` 切换 `rete` 指针。

按分片重建的好处：只改 `orders` 空间的规则时，`users` 空间的网络与内存（含大量 token）完全不受影响。

这与 `f_egraph` 的 `tag` 版本切换语义一致：同一 `category` 只保留一个活跃 `tag`。

## 10. 复杂度与规模

| 操作 | 复杂度 |
|---|---|
| `assert` | O(alpha 链长度 + 命中 join 数 × 匹配令牌数)，只在所属分片内 |
| `retract` | O(命中令牌数)（依赖 `produced` 索引），只在所属分片内 |
| 单次 join 探测 | O(1)（等值索引）/ O(log n + k)（范围索引）/ O(n)（无索引回退） |
| 激活产出 | O(模式数)（展开绑定表） |
| 内存 | O(alpha 事实数 + beta 令牌数)，令牌共享父链；按空间分别计量 |

不限规模的前提是**索引覆盖 join 字段**。如果规则里出现大量无索引的回退 join，复杂度退化为笛卡尔积——`NetworkBuilder` 在构建期统计每个 join 的索引覆盖率，低于阈值时写 `WARN` 日志并给出建议字段。

分片对规模的影响：

- 规则均摊到 K 个空间时，单张网络规模约为总量的 1/K，构建与传播都更快；
- 但如果规则分布极度不均（一个空间占 99% 规则），分片不带来收益，也不会带来额外开销（只是多几个空分片）；
- 分片不减少总内存：每个分片独立维护 alpha memory 与 token，跨片不共享；同一事实如果需要被两个空间的规则看到，必须两份（见 02 §6.6）。

## 11. 内存回收

- `AlphaMemory` 只持有 `FactHandle`，事实对象由 `FactBase` 持有；
- `Token.refCount` 归零即从 `BetaMemory` 移除，父令牌相应递减；
- `Activation` 执行后按 `FireMode` 决定是否撤回；
- `ruleSet.close()` 清空网络、memory、index、agenda，解除对 `FactBase` 的引用。

## 12. 与 Agenda 的接口

```cangjie
public interface ActivationSink {
    func add(activation: Activation): Unit
    func remove(activation: Activation): Unit
}
```

`TerminalNode` 只依赖该接口，不直接依赖 `Agenda` 实现，便于测试时替换为记录器。

## 13. 伪代码：完整插入路径

```
assert(fact)
  └─ FactSpace.of(space) → FactBase.assert → handle
      └─ 分片路由：space → ReteNetwork(space)
          └─ RootNode.child(typeTag)
              └─ AlphaNode.test → 通过 → 后继/输出
                  └─ AlphaMemory.add → 建索引 → rightActivate × K
                      └─ BetaNode.rightActivate
                          ├─ 左索引探测候选项
                          ├─ testJoins 逐条校验
                          ├─ 新建 Token(parent, handle)
                          ├─ BetaMemory.add → 建 join 索引
                          └─ 下游 BetaNode.leftActivate 或 Terminal.activate
                              └─ Agenda.add(Activation)
```

## 14. 已识别风险

| 风险 | 影响 | 缓解 |
|---|---|---|
| R2：`SortedIndex` 需自研跳表 | 范围 join 性能 | M2 先用有序数组 + 二分，压测后再换跳表 |
| R3：`produced` 索引使内存翻倍 | 大事实量下 RSS 上升 | 只对参与 join 的事实记 `produced`；纯 alpha 事实不记 |
| R4：否定模式（`Not`）未覆盖 | 表达能力受限 | M2 只支持单事实 `Not`，跨模式否定留到 M3 |
| R5：聚合（count/sum/max）未覆盖 | 无法写"累计超过 N 次" | 用 `BarrierTask` 在流程层做，或 M4 增加 accumulate 节点 |
