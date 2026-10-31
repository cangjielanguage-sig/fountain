# 11. 装配层：决策表与规则集的接线

## 1. 问题

`doc/08-api.md` 给了两个用法，当前都编译不过：

```cangjie
// ① 规则集装配期加入决策表
let ruleSet = RuleSetBuilder("pricing")
    .version("v1")
    .registerFact(orderSchema)
    .table(table)          // ← 不存在
    .build()

// ② 引擎执行期按表跑会话
let engine = RuleEngine(ruleSet)
let result = engine.executeTable(table, session)   // ← 不存在
```

M5 交付了 `DecisionTable`、`TableCompiler`、`TableExecutor`，但两个门面方法都缺。原因不是没时间写，是**写不出来**：`RuleSetBuilder` 在 `rule` 包，`table` 包依赖 `rule`，再加 `rule → table` 就是循环。

## 2. 根因

```
rule  ←── table        现有：table 依赖 rule（TableCompiler 产出 Rule）
rule  ──→ table        若加 table() 方法则反向依赖 ── 循环
```

`engine → table` 本身合法（`table` 不依赖 `engine`），所以 ② 只是没实现，不是被阻塞。真正被阻塞的只有 ①。

但 ② 的现状也不干净：`TableExecutor.init(table: DecisionTable, ruleSet: RuleSet)` 要一个完整 `RuleSet`，而编译期实际只用 `ruleSet.registry`：

```cangjie
// TableCompiler.cj:108
this.space_ = match (ruleSet.registry.get(table.factSpace)) { ... }
```

`TableCompiler` 对 `RuleSet` 的依赖面只有一处 `registry`。把整个 `RuleSet` 传进去，是为了拿一个字段而绑定一个聚合根——这也是循环的诱因。

## 3. 候选方案

| 方案 | 做法 | 评价 |
|---|---|---|
| A | 删掉 `table()`，用户 `RuleSetBuilder.rules(table.compile(ruleSet))` | 不成立：`compile` 需要 `RuleSet`，鸡生蛋 |
| B | `RuleSetBuilder` 上移到新 `assembly` 包 | 可行，但 `RuleSetBuilder` 是高频入口，移动会连带改所有测试；且 `assembly` 又要依赖 `rule`+`table`，只是把循环上推一层 |
| C | `table` 提供静态函数 `TableRules.compile(table, registry)` | 需要用户拿到 `registry`，破坏 builder 封装 |
| D | **`rule` 定义 `TableSource` 接口，`DecisionTable` 实现** | **选定**：依赖方向不变，API 与文档一致，不动 `RuleSetBuilder` 位置 |
| E | 把 `TableCompiler` 下沉到 `rule` 包 | `table` 的模型全在 `table` 包，下沉会让 `rule` 反过来知道列、行、命中策略，职责混乱 |

## 4. 选定方案

### 4.1 接口反转

在 `rule` 包定义「表能被装配」的最小契约，`table` 包实现它：

```cangjie
// src/rule/TableSource.cj
package fountain::f_rule.rule

import fountain::f_rule.fact.FactSpaceRegistry

/**
 * 决策表在规则装配期的抽象。
 *
 * `table` 包依赖 `rule` 包，因此 `RuleSetBuilder` 不能引用 `DecisionTable`。
 * 该接口把「表 → 规则」的能力反转：由表实现，装配器只按接口调用。
 *
 * 只保留「编译」一项能力：表 id、版本、空间都是表编译期的内部输入，
 * 装配器不需要，也不该让 `rule` 包认识这些概念。
 */
public interface TableSource {
    /**
     * 编译成规则。
     * @param registry 已声明的事实空间与类型，用于校验条件/输出列引用的字段
     * @throws RuleException TABLE_INVALID / UNKNOWN_FACT_SPACE / UNKNOWN_FIELD / TYPE_MISMATCH
     */
    func compileInto(registry: FactSpaceRegistry): Array<Rule>
}
```

接口刻意用方法而非 `prop`：`DecisionTable` 的 `id` / `version` / `factSpace` 是 `public let`，仓颉里 `let` 不满足接口的 `prop` 声明，硬加会迫使表改字段形态。既然装配器用不到这三个值，就不进接口。

`RuleSetBuilder` 新增：

```cangjie
/**
 * 把一张决策表编译成规则后加入规则集。
 *
 * 表引用的 `factSpace` 必须已通过 `factSpace(id)` 声明、且已注册对应的
 * `FactSchema`；否则编译期抛 `UNKNOWN_FACT_SPACE` / `UNKNOWN_TYPE`。
 * 编译出的规则 id 冲突时抛 `DUPLICATE_RULE`。
 */
public func table(source: TableSource): RuleSetBuilder {
    for (rule in source.compileInto(registry_)) {
        let _ = this.rule(rule)
    }
    this
}
```

`DecisionTable` 增加实现（`compile(ruleSet)` 保留为兼容层）：

```cangjie
public class DecisionTable <: TableSource {
    public func compileInto(registry: FactSpaceRegistry): Array<Rule> {
        TableCompiler(this, registry, RuleRuntime.compiler()).compile().rules
    }

    /** @deprecated 等价于 compileInto(ruleSet.registry)，仅为兼容 M5 调用方。 */
    public func compile(ruleSet: RuleSet): Array<Rule> {
        compileInto(ruleSet.registry)
    }
}
```

### 4.2 registry 取代 RuleSet

`TableCompiler` / `TableExecutor` / `DecisionTable.resolvedFactType` 的入参从 `RuleSet` 收窄为 `FactSpaceRegistry`：

| 位置 | 改前 | 改后 |
|---|---|---|
| `TableCompiler.init` | `(table, ruleSet, compiler)` | `(table, registry, compiler)` |
| `TableExecutor.init` | `(table, ruleSet, compiler)` | `(table, registry, compiler)` |
| `DecisionTable.resolvedFactType` | `(ruleSet)` | `(registry)` |
| `DecisionTable.compile` | `(ruleSet[, compiler])` | 保留，内部转 registry |

收益不只是解循环：编译器不再持有聚合根，单测可以直接构造 registry 而不必先 build 一个 `RuleSet`。

### 4.3 引擎门面

`engine` 包可以依赖 `table`（`table` 不依赖 `engine`），所以 `executeTable` 直接加在 `RuleEngine`：

```cangjie
/**
 * 按决策表的 hitPolicy 执行并聚合输出。
 *
 * 用 `table.factSpace` 对应的事实视图作为输入；表在执行前编译一次并缓存，
 * 键为 `(table.id, table.version)`。表变更需换版本号或新建引擎。
 */
public func executeTable(table: DecisionTable, session: RuleSession,
    trace!: Bool = false): TableResult {
    let executor = tableExecutors_.computeIfAbsent("${table.id}@${table.version}") {
        TableExecutor(table, ruleSet_.registry, RuleRuntime.compiler())
    }
    executor.execute(session.factsOf(table.factSpace), trace: trace)
}
```

`RuleEngine` 需 `import fountain::f_rule.runtime.RuleRuntime` 与 `fountain::f_rule.table.{DecisionTable, TableExecutor, TableResult}`。

### 4.4 议程侧新增 `activationGroup`

决策表进议程后，`HitPolicy` 不能靠 `TableExecutor` 聚合，必须由议程表达。Drools 用 `activation-group` 做这件事：同组内只执行第一个激活，执行后其余失效。

```cangjie
// Rule 新字段（构造器是包内 init，不影响外部调用点）
public let activationGroup: ?String

// RuleBuilder
/** 互斥组名。同组激活只执行一个，其余在首个执行后失效。 */
public func activationGroup(name: String): RuleBuilder

// Activation
public let activationGroup: ?String

// Agenda.fire 执行一个激活后
match (activation.activationGroup) {
    case Some(group) => invalidateGroup(group, except: activation)
    case None => ()
}
```

`Activation` 的相等键仍是 `(factSpace, ruleId, bindings)`，`activationGroup` 不参与相等性——组只影响调度，不影响身份。

`invalidateGroup` 遍历 `index_` 移除同组激活。规则规模按 doc/04 的定位（千级以内）时 O(n) 可接受；若后续成为热点，再加 `groups_: HashMap<String, HashSet<Activation>>` 索引。

**HitPolicy 在两条路径上的等价关系**（必须写进 `doc/07`，否则用户会以为两条路完全等价）：

| HitPolicy | 议程路径（`.table()`） | 聚合路径（`executeTable`） |
|---|---|---|
| `Unique` | 同组 + 行序 salience；构建期查重（`TableCompiler.cj:129` 已实现）。运行期多命中只执行一条，**不报错** | 完整：0 命中/多命中均抛 `TABLE_NO_MATCH` / `TABLE_MULTI_MATCH` |
| `First` | 同组 + 行序降序 salience，等价 | 完整 |
| `Priority` | 同组 + **降级为行序**：议程的 `ConflictKey` 不含运行期输出值，无法按 `outputOrder` 比较 | 完整：按 `outputOrder` 取值最小 |
| `Any` | 不分组，全部执行；**不校验输出一致** | 完整：多命中输出必须一致 |
| `Collect` | 不分组 + 行序 salience，等价 | 完整 |
| `RuleOrder` | 不分组 + 按 salience，等价 | 完整 |
| `OutputOrder` | 不分组 + **按行序**执行：无法按输出值排序 | 完整：按输出值升序 |

三项降级（`Unique` 的运行期检查、`Priority`、`Any`、`OutputOrder`）不是实现偷懒，是议程的固有边界——议程按激活调度，看不到「表的整批输出」。需要完整语义时用 `executeTable`。

### 4.5 两条路径互斥（实例级）

同一 `DecisionTable` 实例被两条路使用会重复触发。用实例级模式标记拒绝：

```cangjie
enum TableMode {
    | Unbound      // 未使用
    | Assembled    // 已被 compileInto 装配进规则集
    | Executed     // 已被 TableExecutor 执行
}
```

- `DecisionTable.compileInto`：`Unbound` → `Assembled`；已是 `Executed` 则抛 `TABLE_MODE_CONFLICT`
- `TableExecutor.init`：`Unbound` → `Executed`；已是 `Assembled` 则抛 `TABLE_MODE_CONFLICT`
- 同模式重复使用**允许**：多引擎 `executeTable` 同一张表、多规则集装配同一张表都合法
- 互斥是**实例级**，不同实例（哪怕是同一份 CSV 解析两次）互不影响

`mode_` 用 `Mutex` 保护，因为它可能被多个 `RuleEngine` 并发访问。

新增错误码 `TABLE_MODE_CONFLICT`（第 27 个）。

为什么不用「文档约定」而用硬互斥：重复触发不会报错、只会让输出槽被写两遍或动作执行两次，排查成本远高于一次构建期失败。这条与 `FANOUT_WITHOUT_JOIN` 同类——把静默错误变成显式失败。

## 5. 包依赖

改前：

```
runtime → exception → fact → condition → rule ─┬→ rete ─┐
                                               └→ agenda ┴→ engine → flow
table → (rule, fact, condition, runtime)
```

改后：

```
runtime → exception → fact → condition → rule ─┬→ rete ─┐
        ↑                                      ├→ agenda ┴→ engine → flow
        └────────── table → (rule, …)          └→ table ──────┘
```

不变式：

1. `rule` 只通过 `TableSource` 接口知道「有东西能编译成规则」，不知道表结构；
2. `table` 不依赖 `engine`，所以 `engine → table` 单向；
3. `table` 的测试不 import `engine`，否则又会形成 `table → engine → table`。

## 6. 迁移步骤

每步都能单独编译通过，便于二分定位。

| 步 | 改动 | 验证 |
|---|---|---|
| S1 | 新增 `rule/TableSource.cj`（接口只有声明，无实现） | `cjpm build` |
| S2 | `TableCompiler` / `TableExecutor` / `resolvedFactType` 改收 `registry`；`DecisionTable.compile(ruleSet)` 内部转 | `cjpm test` 352 全绿（既有用例不变） |
| S3 | `DecisionTable` 实现 `TableSource`，加 `compileInto` | 同上 |
| S4 | `Rule.activationGroup` + `RuleBuilder.activationGroup` + `Activation.activationGroup` + `Agenda.invalidateGroup` | 新增 `ActivationGroup_test`：同组只执行一个、不同组互不影响、无组行为不变 |
| S5 | `TableCompiler` 按 HitPolicy 注入 group 与 salience | `TableCompiler_test` 增补：`First`/`Unique` 同组、`Collect` 不分组、`Priority` 降级为行序 |
| S6 | `RuleSetBuilder.table(source)` + `TableMode` 互斥 | 新增 `TableAssembly_test`：表规则进入规则集、未声明空间、重复 id、模式冲突 |
| S7 | `RuleEngine.executeTable` + 执行器缓存 | 新增 `EngineTable_test`：端到端输出、缓存命中、表换版本重新编译 |
| S8 | 同步 `doc/07` 的 HitPolicy 等价表与 `doc/08` 的示例 | 文档代码块人工核对 |
| S9 | `cjpm test` 全绿 | 预期 352 + 14 = 366 |

## 7. 测试策略

| 编号 | 用例 | 断言 |
|---|---|---|
| AS-01 | 表规则进入规则集 | `.table(t)` 后 `rules.size` 等于表行数 |
| AS-02 | 表 id 前缀 | 编译出的规则 id 形如 `<tableId>/<rowId>` |
| AS-03 | 未声明空间 | `.table(t)` 抛 `UNKNOWN_FACT_SPACE` |
| AS-04 | 重复装配同一张表 | 第二次抛 `DUPLICATE_RULE` |
| AS-05 | 未注册字段 | `.table(t)` 抛 `UNKNOWN_FIELD` |
| AS-06 | 引擎端到端 | `executeTable` 输出与 `TableExecutor` 直调一致 |
| AS-07 | 执行器缓存 | 同一表两次调用，`TableCompiler` 只被构造一次 |
| AS-08 | 表版本切换 | 同 id 不同 version 视为两张表，各自编译 |
| AS-09 | `First` 议程语义 | 两行都命中，`fire` 只执行第一行，输出槽是第一行的值 |
| AS-10 | `Collect` 议程语义 | 两行都命中，两行动作都执行，输出槽按行序后写覆盖 |
| AS-11 | 模式冲突 | 先 `.table(t)` 再 `executeTable(t)` 抛 `TABLE_MODE_CONFLICT`，反向亦然 |
| AS-12 | 同模式重复使用 | 两个引擎对同一表各 `executeTable` 一次，均成功 |
| AS-13 | `activationGroup` 通用性 | 非表的代码规则也能用 `.activationGroup("x")` 实现互斥 |
| AS-14 | 无组规则不受影响 | 不设组的规则执行数与改动前一致（回归 M3 的 A-05~A-07） |

AS-07 需要一个可观测点：给 `TableCompiler` 加 `internal static var compileCount`（测试用），或在 `RuleEngine` 暴露 `tableExecutorCount()`。选前者，因为它不扩大门面 API。

## 8. 风险

| 风险 | 影响 | 对策 |
|---|---|---|
| `TableSource` 接口泄漏表的内部概念 | `rule` 包被表语义污染 | 接口只有 `compileInto(registry)` 一个方法，列、行、命中策略、表 id 都不进 |
| `RuleSetBuilder.table()` 的编译时机 | 表在装配期编译，运行期改表无效 | 文档写明「表不可变；改表需新建规则集」 |
| 两条路径语义不完全等价 | 用户以为 `.table()` 与 `executeTable` 等价，`Priority`/`Any`/`OutputOrder` 结果不同 | §4.4 的等价表写进 `doc/07`；三个降级点在 `TableCompiler` 打 WARN |
| `activationGroup` 的失效范围 | 误以为组内未命中的行也会被标记失效 | 语义限定为「已进入议程的同组激活」；未命中行从未入队，无影响 |
| 硬互斥破坏既有用法 | 同一实例既 compile 又 execute 的代码直接失败 | `FixtureTable_test` 需拆成两个实例；这是预期行为，不是回归 |
| `RuleRuntime.compiler()` 的全局状态 | 表编译与脚本条件共用编译器，注册类型不一致会失败 | 与 `doc/03` §6.4 同一条约束：应用须先 `registerType` 再 `build` |
| 循环再现 | `table` 测试若引 `engine`，编译期即报 cyclic | 在 `doc/01` 依赖表里写明；AS 用例全部放 `rule`/`table` 包，S7 的用例放 `engine` 包 |

## 9. 不做的事

- **不把 `executeTable` 改成走议程**。聚合路径的价值在于「整表求值 + 行级 trace + 无副作用」，改成议程会丢掉 `TableResult` 与 `RowTrace`。两条路径并存，靠 §4.5 的硬互斥隔离。
- **不让议程表达 `Priority` / `OutputOrder` 的完整语义**。需要 `Activation` 携带运行期输出值快照，会让 `ConflictKey` 依赖表的输出列定义——把表的私有结构泄漏进议程。需要完整语义时用 `executeTable`。
- **不引入 `assembly` 包**。目前只有两个接线点，接口反转已足够；等出现第三个「上层包要装配下层模型」的场景再考虑。
- **不改 `DecisionTable.compile(ruleSet)` 的签名**。M5 已发布，保留为兼容层，内部转 `compileInto`。
- **不给 `RuleSet` 加 `tables` 字段**。规则集只存编译后的 `Rule`；表本身属于装配输入，运行期不需要。

## 10. 与 roadmap 的关系

本设计属于 M7 的「文档对齐」前置项，但必须在 M6（XLSX）之前完成：M6 产出的 `XlsxTableParser` 返回 `DecisionTable`，如果 `table()` / `executeTable()` 还不可用，XLSX 表同样只能停在 `TableExecutor` 直调层，无法走门面。

`activationGroup` 是议程层的新能力，不属于 M4 已交付的范围，作为 M5.5 插入：

| 里程碑 | 范围 | 依赖 |
|---|---|---|
| M5.5（本设计） | `TableSource`、registry 收窄、`activationGroup`、`table()`、`executeTable`、模式互斥 | M5 |
| M6 | XLSX 载体 | M5.5（表要能走门面） |
| M7 | 性能门禁、文档收尾、`doc/07` 等价表 | M6 |

实施顺序：**M5.5 → M6 → M7**。

## 11. 决策记录

| 编号 | 决策 | 理由 |
|---|---|---|
| D1 | 两条路径并存，不合并 | 聚合路径要 `TableResult`/`RowTrace`/无副作用；议程路径要与代码规则混排。合并必丢一方 |
| D2 | 用 `activationGroup` 而非新增 `HitPolicy` 调度器 | Drools 已验证的通用能力；非表规则也能用，不是表专用机制 |
| D3 | 三项 HitPolicy 在议程路径降级 | 议程看不到「整表输出」，强行支持会把表的输出列结构泄漏进 `ConflictKey` |
| D4 | 实例级硬互斥，不靠文档约定 | 重复触发静默出错，排查成本远高于一次构建期失败 |
| D5 | 接口只有 `compileInto` 一个方法 | `DecisionTable` 的 id/version/factSpace 是 `let`，不满足接口 `prop`；装配器也用不到 |
