# f_rule 技术文档

`fountain::f_rule` —— 建立在 `f_egraph` 与 `f_jit` 之上的规则引擎。

## 定位

| 层 | 模块 | 职责 |
|---|---|---|
| 规则编排 | `f_egraph` | 流程 DAG、事件路由、版本切换、错误事件 |
| 规则求值 | `f_jit` | 复杂表达式编译与沙箱执行 |
| 规则引擎 | `f_rule` | 事实库、Rete 网络、议程、决策表、事件分解 |

`f_rule` 不重复实现流程与编译能力，只做规则语义层。

## 两种执行模式

| 模式 | 适用 | 数据流 |
|---|---|---|
| **决策流模式** | 分支明确、路径短、需人工编排 | 一条规则一个 `f_egraph.Flow`，事件驱动逐跳执行 |
| **产生式模式** | 规则量大、条件交叉、需全量匹配 | 决策表/代码规则 → Rete 网络 → 议程 → 冲突消解后执行 |

两种模式共享同一份 `FactBase`，可在同一规则集内混用。

## 文档索引

| 文档 | 内容 |
|---|---|
| [01-architecture.md](01-architecture.md) | 分层架构、模块结构、核心数据流、依赖边界 |
| [02-fact-model.md](02-fact-model.md) | 事实模型：强类型与动态字典双支持、会话隔离 |
| [03-condition-expression.md](03-condition-expression.md) | 条件算子、模式、`f_jit` 表达式求值与降级路径 |
| [04-rete-network.md](04-rete-network.md) | Rete 网络：alpha/beta、节点共享、索引、增量与撤销 |
| [05-agenda-conflict-resolution.md](05-agenda-conflict-resolution.md) | 议程、激活、冲突消解策略、循环控制 |
| [06-flow-orchestration.md](06-flow-orchestration.md) | 一条规则一个 Flow、`ResolveTask` 扇出、`JoinTask` 汇合 |
| [07-decision-table.md](07-decision-table.md) | 决策表：构建 API、CSV、XLSX 三载体与命中策略 |
| [08-api.md](08-api.md) | 对外 API 与完整示例 |
| [09-testing.md](09-testing.md) | 测试策略、用例矩阵、性能门禁 |
| [10-roadmap.md](10-roadmap.md) | 里程碑拆分与验收标准 |

## 术语表

| 术语 | 英文 / 标识 | 含义 |
|---|---|---|
| 事实 | `Fact` | 可字段寻址的数据单元，网络匹配的输入 |
| 事实库 | `FactBase` | 按规则集与会话隔离的事实容器 |
| 模式 | `Pattern` | 一类事实 + 绑定名 + 约束集合 |
| 约束 | `Constraint` | 单事实上的一个判定（字段、算子、右操作数） |
| 规则 | `Rule` | 模式序列 + 连接约束 + 动作 |
| 规则集 | `RuleSet` | 一组规则 + 一个 `FactBase` + 一个版本 |
| 激活 | `Activation` | 某条规则在某一组绑定下被满足的实例 |
| 议程 | `Agenda` | 待执行激活的优先队列 |
| 令牌 | `Token` | beta 网络中沿路径传播的部分匹配结果 |
| 事件分解执行器 | `ResolveTask` | 把单个事件拆成多个子事件，扇出到多个执行器 |
| 汇合执行器 | `JoinTask` | 等待多个分支事件全部到达后再发出一个事件 |
| 命中策略 | `HitPolicy` | 决策表多行同时命中时的输出规则 |

## 强制约束

1. **进入 Rete 网络的事实不可变**。修改必须走 `FactBase.update()`（内部等价 retract + assert），否则网络索引与事实内容不一致。
2. **扇出分支不得直达结束事件**。`f_egraph` 的 `ImmediateDispatcher.dispatch()` 在遇到 `EndExecutor` 时立即返回，队列中剩余事件被丢弃；所有扇出必须有 `JoinTask` 汇合。
3. **脚本面只暴露白名单类型**。`f_jit` 表达式只能访问 `Compiler.registerType` / `@JitBind` 登记的成员，未登记的类型在编译期报"未注册"。
4. **规则版本切换以 `tag` 为单位**。同一 `category` 下同时只允许一个活跃 `tag`，切换后调用 `removeExceptCurrentTag()`。
