# 10 实施路线

## 1. 总览

```
M0 骨架与 spike
 └─▶ M1 事实·条件·顺序匹配
      └─▶ M2 Rete 网络
           ├─▶ M3 议程与冲突消解
           └─▶ M4 流程编排
                └─▶ M5 决策表 API + CSV
                     └─▶ M5.5 装配层（table / executeTable / activationGroup）
                          └─▶ M6 决策表 XLSX
                               └─▶ M7 性能门禁与收尾
```

M3 与 M4 可并行；M5 依赖 M2 + M3；M6 依赖 M5。

**M5.5 是实施中新增的里程碑**：M5 交付后 `doc/08` 的 `.table()` 与 `executeTable()` 无法编译——
`rule ↔ table` 包循环阻塞，且决策表与议程缺乏统一语义。设计见 [11-assembly.md](11-assembly.md)，
交付 `TableSource` 接口反转、`activationGroup`、两条执行路径的实例级互斥。M6 必须在 M5.5 之后，
否则 XLSX 表同样走不通门面。

## 2. 里程碑

### M0 骨架与 spike

| 项 | 内容 |
|---|---|
| 交付 | `f_rule/cjpm.toml`、`src/rule.cj`、`exception/RuleException.cj`、`RuleErrorCode`、`doc/*` |
| 验证 | `cjpm build` 通过（空模块）；文档评审通过 |
| Spike | ① f_jit 是否支持 `Option<T>` 与 `Any` 作为表达式返回值；② `DynamicFact.get` 能否在脚本中调用；③ `@JitBind` 对 `static func` 的展开边界 |
| 退出条件 | spike 结论写入 `doc/03-condition-expression.md` §6，确定 `ExpressionMode` 默认值 |
| 风险 | spike 失败 → 动态事实表达式改走内置解释器，`Operator` 条件不受影响 |

### M1 事实·条件·顺序匹配

| 项 | 内容 |
|---|---|
| 交付 | `fact/*`（含 `FactSpace`、`FactSpaceRegistry`）、`condition/*`、`rule/*`、`NaiveMatcher` |
| 能力 | 强类型 + 动态事实；全部算子；`And/Or/Not`；多事实库空间与规则绑定；`(space, session)` 隔离；顺序匹配（无网络） |
| 验收 | F-01~F-18、C-01~C-08 全绿；`NaiveMatcher` 能按空间分别产出激活，供后续差分基线 |
| 依赖 | M0 |

M1 的顺序匹配器**长期保留**，不作为生产路径，只作为 M2 的差分基准。

### M2 Rete 网络

| 项 | 内容 |
|---|---|
| 交付 | `rete/*`（`RootNode`、`AlphaNode`、`AlphaMemory`、`BetaNode`、`BetaMemory`、`Token`、`TerminalNode`、`NetworkBuilder`、`SortedIndex`） |
| 能力 | 按 `FactSpace` 分片；alpha 链 + join + 令牌共享 + 引用计数 + 增量插入/撤销 + 片内节点共享 + 等值索引 |
| 验收 | R-01~R-20 全绿；差分测试 200 组随机用例通过；B-01/B-02 达标 |
| 依赖 | M1 |
| 风险 | R2（有序索引）、R3（`produced` 内存）——先实现可用版本，压测后优化 |

`SortedIndex` 的首版用"有序数组 + 二分"，插入 O(n)。若 B-02 不达标，再换跳表。

### M3 议程与冲突消解

| 项 | 内容 |
|---|---|
| 交付 | `agenda/*`（`Activation`、`Agenda`、`ConflictResolver`、`ActionContext`、`ClosureAction`） |
| 能力 | 惰性堆 + 失效跳过；6 种预置策略 + 组合；3 种 `FireMode`；循环检测 |
| 验收 | A-01~A-11 全绿；`fire` 在动作修改事实后仍返回一致结果 |
| 依赖 | M2 |

### M4 流程编排

| 项 | 内容 |
|---|---|
| 交付 | `flow/*`（`RuleFlow`、`RuleSetFlow`、`ResolveTask`、`JoinTask`、`RuleEnvelope`、`FlowContext`、`RuleTask`） |
| 能力 | 一条规则一个 Flow；扇出 + 汇合；session 透传；构建期可达性检查 |
| 验收 | P-01~P-12 全绿；扇出后分支不丢事件；版本切换正确 |
| 依赖 | M3（`RuleTask` 需要 Agenda） |
| 前置 | 确认是否需要 f_egraph 扩展 E1~E4；不扩展时用 `RuleEnvelope` 兜底 |

### M5 决策表 API + CSV

| 项 | 内容 |
|---|---|
| 交付 | `table/DecisionTable.cj`、`HitPolicy.cj`、`CsvTableParser.cj`、`TableCompiler.cj`、`TableExecutor.cj` |
| 能力 | 构建 API；7 种命中策略；CSV 解析（含转义、元数据、BOM）；单元格算子；`${}` 引用 |
| 验收 | T-01~T-11 全绿；决策表编译出的规则与手写规则产生相同激活 |
| 依赖 | M2 + M3 |

### M6 决策表 XLSX

| 项 | 内容 |
|---|---|
| 交付 | `table/XlsxTableParser.cj`、夹具生成脚本 |
| 能力 | 整表读取；流式读取；合并单元格；类型行；多 sheet |
| 验收 | T-12~T-15 全绿；`pricing.xlsx` 与 `pricing.csv` 编译结果逐字段相同 |
| 依赖 | M5 + `f_excel` 稳定版 |

### M7 性能门禁与收尾

| 项 | 内容 |
|---|---|
| 交付 | `src/bench/*`、README、CHANGELOG、完整文档回填 |
| 能力 | B-01~B-07 全部达标；内存与吞吐报告 |
| 验收 | 1000 规则 / 10000 事实端到端 < 3s；RSS < 512MB |
| 依赖 | M1~M6 |

## 3. 每阶段的提交边界

| 阶段 | 提交 |
|---|---|
| M0 | `docs(f_rule): 技术文档` + `chore(f_rule): 模块骨架` |
| M1 | `feat(f_rule): 事实模型与条件` + `test(f_rule): 事实与条件用例` |
| M2 | `feat(f_rule): Rete 网络` + `test(f_rule): 网络与差分用例` |
| M3 | `feat(f_rule): 议程与冲突消解` + `test(f_rule): 议程用例` |
| M4 | `feat(f_rule): 流程编排与事件分解` + `test(f_rule): 编排用例` |
| M5 | `feat(f_rule): 决策表与 CSV` + `test(f_rule): 决策表用例` |
| M6 | `feat(f_rule): XLSX 决策表` + `test(f_rule): Excel 用例` |
| M7 | `perf(f_rule): 规模门禁` + `docs(f_rule): 使用说明` |

遵循项目约定：每个任务独立提交，**有单元测试后再提交**。

## 4. 依赖的外部条件

| 条件 | 影响 | 状态 |
|---|---|---|
| `f_jit` 解释器在 aarch64-linux-ohos 可用 | 表达式求值 | 已知：机器码后端只支持 Linux，ohos 走解释器，功能可用 |
| `f_jit` 支持 `Option`/`Any` | 动态事实表达式 | 已确认不支持（M0 spike，见 `doc/03` §6.4）：`?Any` 映射为 `HostObject`，不可比较/取 `as`；动态事实改走内置解释器 |
| `f_excel` 读取 API 稳定 | XLSX 决策表 | 已知：`ExcelDocument` / `ExcelSheetStream` 可用 |
| `f_egraph` `emit` 不丢 session | 扇出后会话一致 | 已知：会丢；用 `RuleEnvelope` 兜底 |

## 5. 不做的范围

明确排除，避免范围蔓延：

| 项 | 理由 |
|---|---|
| 规则持久化 / 版本库 | 由调用方负责，`f_rule` 只吃内存中的规则 |
| 分布式规则执行 | 单进程内引擎；跨进程用 `f_rpc` 自行编排 |
| 规则可视化编辑器 | 独立前端产品，不在本模块 |
| Rete 的增量规则增删 | 改规则即重建网络，符合版本切换语义 |
| 事务与回滚 | 规则引擎不提供分布式事务 |
| 聚合节点（accumulate） | M4 之后按需求评估，首版用 `BarrierTask` 替代 |

## 6. 风险登记

| 编号 | 风险 | 概率 | 影响 | 缓解 |
|---|---|---|---|---|
| R1 | f_jit 不支持 `Option`/`Any` | 中 | 动态事实表达式受限 | 降级到内置解释器；`Operator` 条件不受影响 |
| R2 | 范围索引性能不足 | 中 | 大表范围 join 慢 | 有序数组 → 跳表 |
| R3 | `produced` 索引内存翻倍 | 中 | RSS 超标 | 只对 join 事实记录 |
| R4 | 扇出丢事件 | 高（已确认） | 流程静默截断 | `JoinTask` + 构建期可达性检查 |
| R5 | 扇出丢 session | 高（已确认） | 事实库串会话 | `RuleEnvelope` 承载 session |
| R6 | 脚本面类型注册遗漏 | 中 | 构建期报错 | `RuleSet.build()` 预校验全部绑定 |
| R7 | 规则数过大时 Flow 模式内存高 | 中 | 启动慢 | 文档明确 Flow 模式适用千级以内；超过用产生式模式 |

## 7. 验收清单

模块可发布需同时满足。状态截至 2026-11-01（`cjpm test` 418/418）：

- [x] M0~M7 全部退出条件达成（含 M5.5）
- [x] 公开 API 均有单元测试
- [x] 差分测试（Rete vs 朴素、f_jit vs 解释器）通过
- [x] 性能门禁 B-01~B-07 达标并记录在 [`perf.md`](perf.md)
- [x] README 含快速开始与三种典型用法（实际写了四种：产生式 / 决策表聚合 / 决策表进议程 / 决策流）
- [x] 文档与实现一致（API 签名、配置项、错误码 27 个）
- [ ] `cjlint` / `cjfmt` 无告警 —— **未满足，工具链原因，非代码问题**
- [x] CHANGELOG 记录本模块首个版本

最后一项的实测情况：

| 工具 | 结果 | 原因 |
|---|---|---|
| `cjlint` | 无法运行 | 依次尝试 `-m` 指向 `./target`、`./target/release`、`$CANGJIE_HOME/lib`、`$CANGJIE_HOME/lib/linux_aarch64_cjnative`、`$CANGJIE_HOME/modules`、`$CANGJIE_HOME/modules/linux_aarch64_cjnative`，全部报 `Can not find modules` |
| `cjfmt` | 172 文件有差异 | 差异集中在 License 头的 `*/` 与 ` */`。对照组 `f_egraph/src/base/Task.cj` 同样有差异，说明是项目统一的格式惯例与 `cjfmt` 默认配置冲突，不是 `f_rule` 特有 |

未为通过检查而批量改写既有格式：那会让 `f_rule` 与仓库其余模块不一致，且改动 172 个文件只为对齐一个注释空格。待项目提供 `cangjie-format.toml` 后再执行。
