# 01 总体架构

## 1. 分层

```
┌──────────────────────────────────────────────────────────┐
│                     应用 / 业务代码                        │
└───────────────┬──────────────────────────┬───────────────┘
                │ 声明式                     │ 脚本式
┌───────────────▼───────────────┐  ┌───────▼───────────────┐
│  决策表 (API / CSV / XLSX)     │  │  f_jit 表达式 / 规则体 │
└───────────────┬───────────────┘  └───────┬───────────────┘
                │ 编译                      │ 编译
┌───────────────▼───────────────────────────▼───────────────┐
│                    RuleSet（规则集）                       │
│  ┌────────────┐  ┌──────────────┐  ┌───────────────────┐  │
│  │  Rule 模型  │  │  FactSpace   │  │  Agenda（议程）    │  │
│  │            │  │   ↕ FactBase  │  │                   │  │
│  └─────┬──────┘  └──────┬───────┘  └─────────┬─────────┘  │
│        │                │                    │            │
│  ┌─────▼────────────────▼────────────────────▼─────────┐  │
│  │        ReteNetwork（按 FactSpace 分片）              │  │
│  └─────────────────────┬───────────────────────────────┘  │
│                        │ 匹配                                │
│  ┌─────────────────────▼───────────────────────────────┐  │
│  │        FlowOrchestration（规则流 / Resolve / Join）  │  │
│  └─────────────────────┬───────────────────────────────┘  │
└────────────────────────┼──────────────────────────────────┘
                         │
┌────────────────────────▼──────────────────────────────────┐
│  f_egraph（Flow / Event / Task）   f_jit（Compiler / Jit）  │
└───────────────────────────────────────────────────────────┘
```

`f_rule` 向上只暴露 `RuleSet`、`RuleEngine`、`DecisionTable`、`FactSpace` 四个门面；向下只依赖 `f_egraph` 的事件模型与 `f_jit` 的编译能力。

## 2. 包结构

```
f_rule/src/
├── rule.cj                       # 包根，public import 重导出
├── RuleInitializer.cj            # f_app Initializer（注册决策表加载器）
├── RuleRuntime.cj                # 共享 Compiler 与全局配置
├── exception/
│   └── RuleException.cj
├── fact/
│   ├── Fact.cj                   # Fact / FactHandle / TypeTag
│   ├── FactSchema.cj             # 强类型字段访问器注册表
│   ├── TypedFact.cj              # 强类型事实适配器
│   ├── DynamicFact.cj            # 动态字典事实
│   ├── FactSpace.cj              # 事实库命名空间与类型注册
│   ├── FactSpaceRegistry.cj      # 规则集级空间注册表
│   └── FactBase.cj               # (space, session) 级存储 + 版本
├── condition/
│   ├── Operator.cj               # 算子枚举与语义
│   ├── Operand.cj                # 常量 / 字段 / 绑定引用
│   ├── Constraint.cj             # 单事实约束
│   ├── Pattern.cj                # 模式（类型 + 绑定 + 约束集）
│   ├── JoinConstraint.cj         # 跨模式连接约束
│   └── JitExpression.cj          # f_jit 表达式条件（含降级）
├── rule/
│   ├── Rule.cj                   # 规则模型与 Builder
│   ├── RuleSet.cj                # 规则集与版本
│   ├── RuleSetBuilder.cj         # 构建器（根包 public import 重导出）
│   ├── Bindings.cj               # 绑定表（不可变视图）
│   └── ConflictResolver.cj       # ConflictKey + 解析器接口 + 默认链
├── rete/
│   ├── ReteNetwork.cj            # 网络容器与构建入口
│   ├── AlphaNode.cj              # 单事实测试节点（可共享）
│   ├── AlphaMemory.cj            # 匹配事实集合 + 索引
│   ├── BetaNode.cj               # join 节点（可共享）
│   ├── BetaMemory.cj             # 令牌集合
│   ├── Token.cj                  # 令牌（父链共享 + 引用计数）
│   ├── TerminalNode.cj           # 规则终端，产出激活
│   └── NetworkBuilder.cj         # 规则 → 网络（node sharing）
├── agenda/
│   ├── Agenda.cj                 # 激活队列与 fire 循环（惰性堆 + 重入保护）
│   ├── Activation.cj             # 激活实例
│   ├── ActivationSink.cj         # 终端 → 议程的产出接口（避免 rete ↔ agenda 循环）
│   ├── Bindings.cj               # 绑定的议程侧视图
│   ├── ConflictResolver.cj       # 6 种策略实现 + 组合 + Resolvers 工厂
│   ├── ActionContext.cj          # 动作上下文（factIn 只读 / copyTo 物化）
│   ├── ClosureAction.cj          # 闭包动作
│   ├── TableAction.cj            # 决策表动作（写输出槽）
│   └── CycleDetector.cj          # 环形指纹窗口，超限抛 CYCLE_LIMIT
├── engine/
│   ├── RuleEngine.cj             # 引擎门面（会话管理、关闭级联）
│   └── RuleSession.cj            # 会话（事实、议程、fire/fireDetailed、FireResult）
├── flow/
│   ├── RuleFlow.cj               # 一条规则一个 ImmediateFlow
│   ├── RuleSetFlow.cj            # 规则集编排流程
│   ├── ResolveTask.cj            # 事件分解（一对多扇出）
│   ├── JoinTask.cj               # 多分支汇合
│   └── FlowContext.cj            # session → 多空间 FactBaseView
└── table/
    ├── DecisionTable.cj          # 表模型 + Builder
    ├── HitPolicy.cj              # 命中策略
    ├── CsvTableParser.cj         # CSV 载体
    ├── XlsxTableParser.cj        # XLSX 载体（依赖 f_excel）
    └── TableCompiler.cj          # 表 → Rule[]
```

包依赖方向（单向，禁止反向）：

```
exception  ←  fact  ←  condition  ←  rule  ←  rete  ←  engine  ←  flow
                                        ↑        ↑         ↑
                                     agenda ─────┘         │
                                        └──────────────────┘
```

| 规则 | 说明 |
|---|---|
| `flow` 依赖 `engine` | `RuleTask` 调 `RuleEngine.session()` 与 `RuleSession.fire()` |
| `engine` 依赖 `rete`/`agenda`/`rule`/`fact` | 会话持有网络运行态与议程 |
| `agenda` 依赖 `rule`/`rete` 的产出接口 | `ActivationSink` 定义在 `agenda`，由 `rete` 反向实现 |
| **根包不依赖任何子包的具体实现** | 根包只 `public import` 重导出；因此子包**不能** `import fountain::f_rule.*` |

违反最后一条会造成包循环：早期 `RuleEngine` 放在根包，`flow` 引它，根包就无法重导出 `flow`，用户被迫写 `import fountain::f_rule.flow.*`。现已把 `RuleEngine` / `RuleSession` 下移到 `engine/`，用户按 `doc/08` 的 `import fountain::f_rule.*` 即可拿到全部门面。

## 3. 核心数据流

### 3.1 产生式模式

```
决策表 / 规则代码（每条规则声明 factSpace）
   │ TableCompiler / Rule.Builder
   ▼
Rule[] ──按 factSpace 分组──▶ Map<space, ReteNetwork 分片>
                                   ▲
FactSpace.assert(fact) ────────────┘ 增量传播（只在片内）
                                   │
                                   ▼
                            TerminalNode → Activation
                                   │
                                   ▼
                    Agenda（session 级，跨片统一排序）
                                   │
                                   ▼
                    动作执行 ──▶ 写回来源 space
```

不变式：

- 一次 `assert` 只触发**所属空间**网络分片的增量传播，不跨片；
- 每个 `FactSpace` 一张网络，片内节点共享；跨片不共享节点；
- 网络构建完成后结构不可变，只有 memory 内容变化；
- 议程是 session 级而非 space 级：不同空间的激活可以统一排序，但动作只能读写来源空间（跨库改写需显式搬运）；
- `fire()` 期间产生的事实变更进入队列，按冲突消解顺序重新参与匹配。

### 3.2 决策流模式

```
RuleSetFlow.start(data)
   │
   ▼  StartEvent
RuleFlow(rule-1) ──Event──▶ RuleFlow(rule-2) ──▶ ... ──▶ EndEvent
   │                            │
   └──── 共享所属空间的 FactBase ┘
```

一条规则一个 `ImmediateFlow`，`category = "<ruleSetId>/<ruleId>"`，`tag = ruleSet.version`。父流程用 `registerTaskByImmediateFlow` 串联；分支用 `ResolveTask` 扇出，`JoinTask` 汇合。

## 4. 依赖边界

| 依赖 | 用途 | 不允许的用法 |
|---|---|---|
| `f_egraph` | `Task`/`Flow`/`Event`/`MultiEvent` | 不直接操作 `Dispatcher` 内部结构 |
| `f_jit` | 表达式编译、规则体脚本 | 不在 `f_rule` 内重新实现字节码/解释器 |
| `f_excel` | XLSX 决策表读取 | 不把 Excel 对象泄漏进 `Rule` 模型 |
| `f_regex` | `Matches` 算子 | 不缓存跨规则的正则编译结果（由 `f_regex` 自己缓存） |
| `f_collection` | 有序索引 / 集合 | — |
| `f_concurrent` | 并发容器 | 网络构建期必须单线程 |

`f_rule` **不依赖** `f_orm`、`f_dbd`：规则引擎不负责持久化，事实来源由调用方注入。

## 5. 并发模型

| 阶段 | 并发性 | 说明 |
|---|---|---|
| 规则/决策表编译 | 单线程 | `NetworkBuilder` 非线程安全，构建完成后冻结 |
| 事实插入 | 多线程 | `FactBase` 按空间独立分段锁；同一 `(space, typeTag)` 的桶串行 |
| 网络传播 | 单线程 per session | 同一 `session` 的传播串行，避免令牌乱序 |
| `Agenda.fire` | 单线程 per session | 动作可能产生事实，必须顺序化 |
| 决策流 | `ImmediateFlow` 同步 / `AsyncFlow` 异步 | 同一 session 内事件顺序由 dispatcher 保证 |

会话隔离键：`(factSpace, session)`。跨空间、跨会话都不共享 token、不共享 agenda，只共享不可变的网络结构、类型描述与规则定义。

## 6. 错误处理

统一异常 `RuleException <: BaseException`，分类由 `RuleErrorCode` 区分：

| 码 | 场景 |
|---|---|
| `DUPLICATE_RULE` | 同一规则集内规则 id 重复 |
| `EMPTY_PATTERN` | 规则没有任何模式 |
| `UNKNOWN_FACT_SPACE` | 规则引用了未声明的事实库空间 |
| `EMPTY_FACT_SPACE_SET` | 规则集没有任何事实库空间 |
| `CROSS_SPACE_JOIN` | 同一规则的模式或 join 跨事实库空间 |
| `DUPLICATE_TYPE` | 同一空间内 `typeTag` 被不一致的 schema 重复注册 |
| `UNKNOWN_TYPE` | 模式引用了未注册的 `typeTag` |
| `UNKNOWN_FIELD` | 约束引用了未注册字段 |
| `TYPE_MISMATCH` | 算子与操作数类型不兼容 |
| `TABLE_INVALID` | 决策表结构/单元格非法 |
| `TABLE_NO_MATCH` | `Unique` 命中策略下零命中 |
| `TABLE_MULTI_MATCH` | `Unique` 命中策略下多命中 |
| `NETWORK_FROZEN` | 网络已冻结后仍尝试注册规则或空间 |
| `CYCLE_LIMIT` | `Agenda.fire` 超过循环上限 |

编译期错误（决策表、规则定义）一律在构建阶段抛出，不留到运行期；运行期只保留事实类型不匹配、表达式运行时异常两类。
