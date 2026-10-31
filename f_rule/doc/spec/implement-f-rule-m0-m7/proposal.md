# Proposal: 实现 f_rule 规则引擎全量 M0~M7

## Why

`f_rule` 目前只有 `cjpm.toml`、`README.md` 与 `doc/01~10`，`src/` 不存在（README 自述"设计阶段"）。
技术文档已经把语义钉到 API 签名级别，但模块不可编译、不可发布，`f_egraph` 的流程编排、
`f_jit` 的表达式编译、`f_excel` 的读取能力也无法组合成"事实库 + Rete + 议程 + 决策表"的规则引擎。

本变更按 `doc/10-roadmap.md` 一次性交付 M0~M7，使模块达到"可发布"验收清单
（公开 API 有单元测试、差分测试通过、性能门禁达标、文档与实现一致）。

## What Changes

| 里程碑 | 交付 |
|---|---|
| **M0 骨架** | `src/` 9 个包（`rule` 根 + `exception/fact/condition/rule/rete/agenda/flow/table`）、`RuleErrorCode`、`RuleException`、`RuleInitializer`、`RuleRuntime`；`cjpm.toml` 补 `f_app` / `f_ticktock` 依赖；`.modules` 的 `[include]` 登记 `f_rule`；三项 spike 结论回填 `doc/03` §6 |
| **M1 事实·条件·顺序匹配** | `Fact` 双形态（`FactSchema` + `TypedFact` / `DynamicFact`）、`ValueKey`、`FactSpace` / `FactSpaceRegistry` / `FactBase` / `FactBaseView`、全部算子与三值逻辑、`JitExpression` + 内置解释器、`Rule` / `RuleSet` 构建期校验、`NaiveMatcher`（长期保留的差分基准） |
| **M2 Rete 网络** | `Token`（父链 + refCount）、`AlphaNode` / `AlphaMemory`、`BetaNode` / `BetaMemory`、`TerminalNode`、`NetworkBuilder`（alpha/join 签名共享）、按空间分片的 `ReteNetwork` + `SessionNetwork`、等值索引 + `ConcurrentSkipListMap` 有序索引、增量插入/撤销/更新 |
| **M3 议程与冲突消解** | `Activation` / `Bindings`、惰性堆 `Agenda`、6 种预置策略 + 组合、3 种 `FireMode`、`ActionContext` / `ClosureAction` / `TableAction`、循环检测、`RuleEngine` / `RuleSession` 门面 |
| **M4 流程编排** | `RuleEnvelope`、`FlowContext`、`RuleFlow`（一条规则一个 `ImmediateFlow`）、`RuleSetFlow` 链式编排、`ResolveTask` 扇出、`JoinTask` 汇合（含超时）、`RuleTask`、扇出可达性构建期检查 |
| **M5 决策表 API + CSV** | `DecisionTable` / `Column` / `TableRow`、`HitPolicy` 7 种、单元格语法（算子 / `${}` / `expr`）、`CsvTableParser`、`TableCompiler`、`TableExecutor` |
| **M6 决策表 XLSX** | `XlsxTableParser`（整表 / 指定 sheet / 流式）、类型行与合并单元格、`_meta` sheet 表属性、夹具生成脚本 |
| **M7 门禁与收尾** | B-01~B-07 性能门禁、差分回归（Rete vs 朴素、f_jit vs 解释器）、README / CHANGELOG / 文档回填、`cjlint` / `cjfmt` 无告警 |

### 已拍板事项与本变更的落点

| 拍板 | 落点 |
|---|---|
| 事实双形态（`FactSchema` + `DynamicFact`） | 事实模型 spec R1；`design.md` D2 |
| `FactSpace` 每规则独立或多规则共享；Rete 按空间分片、禁止跨空间 join | 事实模型 spec R4/R5、Rete spec R1；`design.md` D3 |
| 决策表 API / CSV / XLSX 硬依赖 `f_excel` | 决策表 spec R5；`design.md` D9（XLSX 只走 `f_excel` 读取，不另写解析器） |
| Rete 不限规模，范围索引用 `ConcurrentSkipListMap` | Rete spec R5；`design.md` D4（含 `RangeKey` 全序设计） |
| 本变更不改 `f_egraph`，用 `RuleEnvelope` 透传 session，扇出必须 `JoinTask` 汇合 | 流程 spec R4/R5；`design.md` D8 |
| `f_rule` 登记 `.modules` 的 `include` | 引擎核心 spec R6；任务 1.5 |

## Impact

- **新增代码**：`f_rule/src/` 下 9 个包、约 40 个源文件与同目录 `*_test.cj`。
- **修改**：`f_rule/cjpm.toml`（补 `f_app`、`f_ticktock` 依赖）、`.modules`（`[include]` 加 `f_rule`）、
  `f_rule/README.md`（状态从"设计阶段"改为可用）、新增 `f_rule/CHANGELOG`。
- **不修改**：`f_egraph`、`f_jit`、`f_excel` 三个上游模块；根 `cjpm.toml` 与根 `src/` 聚合 shim。
- **测试**：`doc/09-testing.md` 的 F-01~F-18、C-01~C-08、R-01~R-20、A-01~A-11、P-01~P-15、
  T-01~T-15、I-01~I-06 全量落地；Rete 差分 200 组随机用例；性能门禁 B-01~B-07。
- **风险面**：`f_jit` 无表达式 API 且不支持 `Option`/`Any` 返回，动态事实的脚本条件必须走内置解释器
  （`design.md` D7）；`f_egraph` 的 `dispatch()` 在遇到 `EndExecutor` 时立即返回，剩余队列事件会在
  **下一次 `start()` 被重放**（比"丢弃"更隐蔽），`design.md` D8 给出构建期拦截 + 运行期回归用例。

## Out of Scope

- 规则持久化 / 版本库、分布式规则执行、可视化编辑器。
- Rete 的增量规则增删（改规则即按分片重建）。
- 事务与回滚、`accumulate` 聚合节点（首版用 `BarrierTask`）。
- `f_egraph` 的 E1~E4 扩展（`emit` 透传 session、`drainMode`、同事件多执行器）；本变更只用 `RuleEnvelope` 兜底。
- 决策表 XLSX 的写回（只读）。
