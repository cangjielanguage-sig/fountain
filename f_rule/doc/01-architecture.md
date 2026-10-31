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
│  │  Rule 模型  │  │   FactBase   │  │  Agenda（议程）    │  │
│  └─────┬──────┘  └──────┬───────┘  └─────────┬─────────┘  │
│        │                │                    │            │
│  ┌─────▼────────────────▼────────────────────▼─────────┐  │
│  │              ReteNetwork（alpha + beta）             │  │
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

`f_rule` 向上只暴露 `RuleSet`、`RuleEngine`、`DecisionTable`、`FactBase` 四个门面；向下只依赖 `f_egraph` 的事件模型与 `f_jit` 的编译能力。

## 2. 包结构

```
f_rule/src/
├── rule.cj                       # 包根，重导出
├── RuleInitializer.cj            # f_app Initializer（注册决策表加载器）
├── RuleRuntime.cj                # 共享 Compiler 与全局配置
├── exception/
│   └── RuleException.cj
├── fact/
│   ├── Fact.cj                   # Fact / FactHandle / TypeTag
│   ├── FactSchema.cj             # 强类型字段访问器注册表
│   ├── TypedFact.cj              # 强类型事实适配器
│   ├── DynamicFact.cj            # 动态字典事实
│   └── FactBase.cj               # 分桶 + 会话隔离 + 版本
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
│   └── Bindings.cj               # 绑定表（不可变视图）
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
│   ├── Agenda.cj                 # 激活队列与 fire 循环
│   ├── Activation.cj             # 激活实例
│   └── ConflictResolver.cj       # 冲突消解策略与组合
├── flow/
│   ├── RuleFlow.cj               # 一条规则一个 ImmediateFlow
│   ├── RuleSetFlow.cj            # 规则集编排流程
│   ├── ResolveTask.cj            # 事件分解（一对多扇出）
│   ├── JoinTask.cj               # 多分支汇合
│   └── FlowContext.cj            # session → FactBase 视图
└── table/
    ├── DecisionTable.cj          # 表模型 + Builder
    ├── HitPolicy.cj              # 命中策略
    ├── CsvTableParser.cj         # CSV 载体
    ├── XlsxTableParser.cj        # XLSX 载体（依赖 f_excel）
    └── TableCompiler.cj          # 表 → Rule[]
```

## 3. 核心数据流

### 3.1 产生式模式

```
决策表 / 规则代码
   │ TableCompiler / Rule.Builder
   ▼
Rule[]  ──NetworkBuilder──▶  ReteNetwork（alpha/beta 共享图）
                                 ▲
FactBase.assert(fact) ───────────┘ 增量传播
                                 │
                                 ▼
                          TerminalNode → Activation
                                 │
                                 ▼
                          Agenda.fire() ──▶ 动作执行
                                 │              │
                                 └◀── assert/retract ┘
```

不变式：

- 一次 `assert` 只触发受影响的 alpha/beta 路径，不重扫全表；
- 网络构建完成后结构不可变，只有 memory 内容变化；
- `fire()` 期间产生的事实变更进入队列，按冲突消解顺序重新参与匹配。

### 3.2 决策流模式

```
RuleSetFlow.start(data)
   │
   ▼  StartEvent
RuleFlow(rule-1) ──Event──▶ RuleFlow(rule-2) ──▶ ... ──▶ EndEvent
   │                            │
   └──── 共享 FactBase(session) ┘
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
| 事实插入 | 多线程 | `FactBase` 与各 memory 用分段锁；同一 `typeTag` 的桶串行 |
| 网络传播 | 单线程 per session | 同一 `session` 的传播串行，避免令牌乱序 |
| `Agenda.fire` | 单线程 per session | 动作可能产生事实，必须顺序化 |
| 决策流 | `ImmediateFlow` 同步 / `AsyncFlow` 异步 | 同一 session 内事件顺序由 dispatcher 保证 |

会话隔离键：`(ruleSetId, session)`。跨会话不共享 token、不共享 agenda，只共享不可变的网络结构与规则定义。

## 6. 错误处理

统一异常 `RuleException <: BaseException`，分类由 `RuleErrorCode` 区分：

| 码 | 场景 |
|---|---|
| `DUPLICATE_RULE` | 同一规则集内规则 id 重复 |
| `EMPTY_PATTERN` | 规则没有任何模式 |
| `UNKNOWN_TYPE` | 模式引用了未注册的 `typeTag` |
| `UNKNOWN_FIELD` | 约束引用了未注册字段 |
| `TYPE_MISMATCH` | 算子与操作数类型不兼容 |
| `TABLE_INVALID` | 决策表结构/单元格非法 |
| `TABLE_NO_MATCH` | `Unique` 命中策略下零命中 |
| `TABLE_MULTI_MATCH` | `Unique` 命中策略下多命中 |
| `NETWORK_FROZEN` | 网络已冻结后仍尝试注册规则 |
| `CYCLE_LIMIT` | `Agenda.fire` 超过循环上限 |

编译期错误（决策表、规则定义）一律在构建阶段抛出，不留到运行期；运行期只保留事实类型不匹配、表达式运行时异常两类。
