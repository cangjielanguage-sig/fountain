# Spec Delta — f-rule-engine-core

## ADDED Requirements

### Requirement: 门面与生命周期

`f_rule` SHALL 只向上暴露 `RuleSet`、`RuleEngine`、`RuleSession`、`DecisionTable`、`FactSpace`
五个门面，包根 `fountain::f_rule` SHALL 重导出常用类型，使 `import fountain::f_rule.*` 即可完成
"声明规则集 → 建会话 → 断言事实 → fire"全流程。

`RuleEngine.session(id)` SHALL 对同一 id 返回同一 `RuleSession`；`release(id)` SHALL 释放该会话的
事实、令牌与议程；`RuleEngine.close()` SHALL 级联 `RuleSet.close()`，此后任何 `fire` SHALL 抛
`RuleException(CLOSED)`。

#### Scenario: 同一会话复用

- **WHEN** 连续两次调用 `engine.session("s1")`
- **THEN** 返回同一实例，`facts("orders")` 看到同一批事实

#### Scenario: 关闭后拒绝执行

- **WHEN** `engine.close()` 之后调用 `session.fire()`
- **THEN** 抛 `RuleException(CLOSED)`，不产生任何激活

### Requirement: 构建期全量校验

`RuleSet.build()` SHALL 在进入运行期之前完成全部静态校验，校验项与失败码 SHALL 严格等于
`doc/02-fact-model.md` §8 的表格；任一失败 SHALL 抛 `RuleException` 并使规则集进入 `Invalid` 状态，
`Invalid` 规则集 SHALL 无法构造 `RuleEngine`。

校验通过后 `FactSpaceRegistry.freeze()` SHALL 冻结空间集合、类型描述与字段声明；运行期新增空间或
新增规则 SHALL 抛 `NETWORK_FROZEN`。

#### Scenario: 跨空间模式被拒绝

- **WHEN** 一条规则的两个 `Pattern` 分别属于 `orders` 与 `users`
- **THEN** `build()` 抛 `RuleException(CROSS_SPACE_JOIN)`

#### Scenario: 未知字段被拒绝

- **WHEN** 约束引用 `Order` 未注册的字段 `nonexistent`
- **THEN** `build()` 抛 `RuleException(UNKNOWN_FIELD)`

#### Scenario: 冻结后注册

- **WHEN** `build()` 成功后对 `RuleSet` 追加规则或空间
- **THEN** 抛 `RuleException(NETWORK_FROZEN)`

### Requirement: 错误模型

所有 `f_rule` 抛出的异常 SHALL 是 `RuleException <: BaseException`，携带 `code: RuleErrorCode`，
并 SHALL 支持 `message` 与 `caused: Exception` 构造。错误码集合 SHALL 覆盖：
`DUPLICATE_RULE`、`DUPLICATE_FACT`、`EMPTY_PATTERN`、`UNKNOWN_FACT_SPACE`、`EMPTY_FACT_SPACE_SET`、
`CROSS_SPACE_JOIN`、`SAME_SPACE_FANOUT`、`DUPLICATE_TYPE`、`UNKNOWN_TYPE`、`UNKNOWN_FIELD`、
`UNKNOWN_BINDING`、`TYPE_MISMATCH`、`ILLEGAL_STATE`、`TABLE_INVALID`、`TABLE_NO_MATCH`、
`TABLE_MULTI_MATCH`、`NETWORK_FROZEN`、`CYCLE_LIMIT`、`SCRIPT_COMPILE`、`SCRIPT_BINDING_MISSING`、
`FANOUT_WITHOUT_JOIN`、`EMPTY_FANOUT`、`REENTRANT_FIRE`、`ACTION_FAILED`、`NO_CONTEXT`、`CLOSED`。

错误码 SHALL 是 `public enum RuleErrorCode <: ToString & Hashable & Equatable<RuleErrorCode>`，
`toString()` 返回 SHALL 稳定的大写蛇形名，用于日志与决策表错误定位。

#### Scenario: 错误码可判等

- **WHEN** 捕获到构建期异常并 `match (e.code)`
- **THEN** 可用枚举分支区分 `CROSS_SPACE_JOIN` 与 `UNKNOWN_FIELD`，无需解析 message

### Requirement: 初始化与共享编译器

`f_rule` SHALL 提供 `RuleInitializer <: fountain::f_app.Initializer`（`name = "fountain::f_rule"`，
`dependencies` 含 `fountain::f_egraph`），在 `static init()` 中向 `InitializerCollection` 注册。

`RuleRuntime.initCompiler(compiler)` SHALL 接收外部 `Compiler` 并复用同一实例，使 `f_egraph` 的
`ClosureTask` 与 `f_rule` 的 `JitExpression` 命中同一个 `f_jit` 编译缓存；未显式初始化时
`RuleRuntime` SHALL 惰性创建默认 `Compiler`，但 SHALL 在首次使用时打印一次 WARN 说明类型注册可能不全。

`RuleSet.build()` SHALL 在编译任何 `Script` 条件之前校验 `Compiler` 已登记全部参与类型，缺失时抛
`RuleException(SCRIPT_COMPILE)` 并携带未登记类型名。

#### Scenario: 共享编译器

- **WHEN** 应用先 `RuleRuntime.initCompiler(c)`，再 `RuleSet.build()`
- **THEN** 构建期编译复用 `c`，不新建 `Compiler`

### Requirement: 规模与性能门禁

在发布验收中，以下门禁 SHALL 以可重复的仓颉单元测试断言（`src/*_test.cj`，不随默认单测以外的路径执行）：

| 编号 | 场景 | 门禁 |
|---|---|---|
| B-01 | 1000 规则（每条 2 模式）构建网络 | < 500ms，节点数 < 3000 |
| B-02 | 10000 事实插入 | < 2s，激活数与 `NaiveMatcher` 一致 |
| B-03 | 网络已建时插入单条事实 | < 1ms（P95） |
| B-04 | 撤销 30% 事实 | < 500ms |
| B-05 | 1000 规则 / 10000 事实 RSS | < 512MB |
| B-06 | 重复构建同一规则集 | 第二次 < 50ms |
| B-07 | 决策表 1000 行解析 + 编译 | < 300ms |

门禁 SHALL 记录实际值到 `f_rule/doc/perf.md`；任一不达标 SHALL 阻止本变更收尾。

#### Scenario: 端到端规模

- **WHEN** 构建 1000 条两模式规则并插入 10000 条事实
- **THEN** 总耗时 < 3s，RSS < 512MB，激活集合与朴素匹配逐条相等

### Requirement: 发布登记

`f_rule` SHALL 登记进仓库根 `.modules` 的 `[include]`；`f_rule/README.md` 的状态段 SHALL 从
"设计阶段"更新为可用，并给出快速开始与三种典型用法；`f_rule/CHANGELOG` SHALL 记录首个版本。

#### Scenario: 发布清单包含 f_rule

- **WHEN** 读取仓库根 `.modules`
- **THEN** `[include]` 段包含 `f_rule`，且不在 `[detention]` 段
