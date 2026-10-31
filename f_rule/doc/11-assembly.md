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
| S2 | `TableCompiler` / `TableExecutor` / `resolvedFactType` 改收 `registry`；`DecisionTable.compile(ruleSet)` 内部转 | `cjpm test` 349 全绿（M5 用例不变） |
| S3 | `DecisionTable` 实现 `TableSource`，加 `compileInto` | 同上 |
| S4 | `RuleSetBuilder.table(source)` | 新增 `TableAssembly_test`：`.table(t)` 后 `ruleSet.rules` 含表规则、未声明空间抛 `UNKNOWN_FACT_SPACE`、重复表 id 抛 `DUPLICATE_RULE` |
| S5 | `RuleEngine.executeTable` + 执行器缓存 | 新增 `EngineTable_test`：端到端输出、缓存命中（同表两次调用只编译一次）、表换版本重新编译 |
| S6 | 同步 `doc/08` 的示例与 `doc/07` 的 `compile` 说明 | 文档代码块可编译（人工核对） |
| S7 | `cjpm test` 全绿 | 预期 352 + 6 = 358 |

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

AS-07 需要一个可观测点：给 `TableCompiler` 加 `internal static var compileCount`（测试用），或在 `RuleEngine` 暴露 `tableExecutorCount()`。选前者，因为它不扩大门面 API。

## 8. 风险

| 风险 | 影响 | 对策 |
|---|---|---|
| `TableSource` 接口泄漏表的内部概念 | `rule` 包被表语义污染 | 接口只有 `compileInto(registry)` 一个方法，列、行、命中策略、表 id 都不进 |
| `RuleSetBuilder.table()` 的编译时机 | 表在装配期编译，运行期改表无效 | 文档写明「表不可变；改表需新建规则集」 |
| `executeTable` 绕过议程 | 表输出与产生式路径的冲突消解不一致 | 明确这是两条路径：表走 `HitPolicy` 聚合，规则走 `Agenda`；`doc/07` §9 已声明。M7 若要做「表进 Rete」，需另开设计 |
| `RuleRuntime.compiler()` 的全局状态 | 表编译与脚本条件共用编译器，注册类型不一致会失败 | 与 `doc/03` §6.4 同一条约束：应用须先 `registerType` 再 `build` |
| 循环再现 | `table` 测试若引 `engine`，编译期即报 cyclic | 在 `doc/01` 依赖表里写明；AS 用例全部放 `rule`/`table` 包，S5 的用例放 `engine` 包 |

## 9. 不做的事

- **不把 `TableExecutor` 接到 `Agenda`**。表是逐行求值 + `HitPolicy` 聚合，与议程的「激活-冲突消解」是两套语义。强行合并会丢失行级 trace 与 `${}` 行绑定。
- **不引入 `assembly` 包**。目前只有两个接线点，接口反转已足够；等出现第三个「上层包要装配下层模型」的场景再考虑。
- **不改 `DecisionTable.compile(ruleSet)` 的签名**。M5 已发布，保留为兼容层，内部转 `compileInto`。
- **不给 `RuleSet` 加 `tables` 字段**。规则集只存编译后的 `Rule`；表本身属于装配输入，运行期不需要。

## 10. 与 roadmap 的关系

本设计属于 M7 的「文档对齐」前置项，但必须在 M6（XLSX）之前完成：M6 产出的 `XlsxTableParser` 返回 `DecisionTable`，如果 `table()` / `executeTable()` 还不可用，XLSX 表同样只能停在 `TableExecutor` 直调层，无法走门面。

实施顺序建议：**本设计 → M6（XLSX）→ M7（性能门禁与收尾）**。
