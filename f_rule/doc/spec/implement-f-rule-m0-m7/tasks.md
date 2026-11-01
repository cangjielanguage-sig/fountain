# Tasks — implement-f-rule-m0-m7

> 每个任务按 Red-Green-Refactor 推进：先写失败用例并确认失败原因正确，再写最小实现，跑绿后才勾选。
> 用例编号沿用 `doc/09-testing.md`（F/C/R/A/P/T/I），写在测试类注释里便于对账。
> 提交边界按 `doc/10-roadmap.md` §3：每个里程碑至少一次 `feat`/`test` 提交，禁止无测试提交。

## 1. M0 骨架、依赖与 spike

- [x] 1.1 失败用例：`RuleException_test` 断言 `RuleErrorCode` 26 个码的 `toString()` 为稳定大写蛇形名、`==`/`hashCode` 可用
- [x] 1.2 实现 `exception/RuleErrorCode.cj` 与 `exception/RuleException.cj`（`code` / `message` / `caused`）
- [x] 1.3 建立 `src/` 9 个包骨架（`exception/fact/condition/rule/rete/agenda/flow/table` + 根包 `rule.cj`），每个包至少一个可编译文件
- [x] 1.4 失败用例：`RuleRuntime_test` 断言 `initCompiler(c)` 后 `RuleRuntime.compiler()` 返回同一实例；未初始化时惰性创建并只 WARN 一次
- [x] 1.5 实现 `RuleRuntime.cj`；`RuleInitializer.cj` 按 `f_app.Initializer` 模式在 `static init()` 注册，`name = "fountain::f_rule"`、`dependencies = ["fountain::f_egraph"]`
- [x] 1.6 `f_rule/cjpm.toml` 补 `fountain::f_app`、`fountain::f_ticktock` 路径依赖
- [x] 1.7 spike ①：对 `DynamicFact` 加 `@JitBind` 后编译 `{ f: DynamicFact => f.get("amount") > 200 }`，记录失败码与消息
- [x] 1.8 spike ②：编译 `{ b: Bool => b }` 与 `call<Bool>`、`call<Any>`，确认"`T` 必须精确等于返回类型"与 `Option` 不可用
- [x] 1.9 spike ③：确认 `@JitBind` 对 `static func` / `static let` 的展开边界（能否在脚本里调用 `Order.of(...)`）
- [x] 1.10 把 1.7~1.9 结论写入 `f_rule/doc/03-condition-expression.md` §6，并据此确定 `ExpressionMode` 默认值（预期 `JitPreferred` + 动态事实降级）
- [x] 1.11 `.modules` 的 `[include]` 增加 `f_rule`（`f_excel` 之后）；`f_rule/README.md` 状态段与依赖表更新；新增 `f_rule/CHANGELOG`
- [x] 1.12 `cjpm build` 通过（空模块），记录首次构建耗时

## 2. M1 事实模型与条件

- [x] 2.1 失败用例 `ValueKey_test`：`Int64(1) == Float64(1.0)`、`DateTime`→纳秒、`Array`/`Set` 归一、跨域排序抛 `TYPE_MISMATCH`（F-07/F-08）
- [x] 2.2 实现 `fact/ValueKey.cj`：`Hashable & Equatable & Comparable`，域序 Number < Text < Bool < Time < List
- [x] 2.3 失败用例 `FactSchema_test` / `TypedFact_test`：字段读取、未声明字段返回 None、`has` 与 `get` 区分、`hostTypeName` 记录（F-01）
- [x] 2.4 实现 `fact/Fact.cj`（`Fact` / `FactHandle` / `TypeTag` 常量）、`fact/FactSchema.cj`、`fact/TypedFact.cj`
- [x] 2.5 失败用例 `DynamicFact_test`：缺失字段、`set`/`remove`、`freeze` 后 `set` 抛 `ILLEGAL_STATE`、非法值类型抛 `TYPE_MISMATCH`（F-02/F-03）
- [x] 2.6 实现 `fact/DynamicFact.cj`（含允许类型白名单校验）
- [x] 2.7 失败用例 `FactBase_test`：`assert` 返回句柄、重复 `assert` 同实例抛 `DUPLICATE_FACT`、`update` 保 id、`retract` 不存在返回 false、`scan`/`size`/`clear`（F-04/F-05/F-06）
- [x] 2.8 实现 `fact/FactBase.cj`（`typeTag` 分桶 + 单调 id + 实例弱引用表）
- [x] 2.9 失败用例 `FactSpace_test` / `FactSpaceRegistry_test`：类型注册、`fieldTypes`、不一致 schema 重复注册抛 `DUPLICATE_TYPE`、`freeze()` 后注册抛 `NETWORK_FROZEN`（F-16）
- [x] 2.10 实现 `fact/FactSpace.cj`、`fact/FactSpaceRegistry.cj`
- [x] 2.11 失败用例 `FactBaseView_test`：会话隔离（F-09）、`fork` + `commitToParent`（F-10）、`Shared`/`Isolated` 两种级别
- [x] 2.12 实现 `fact/FactBaseView.cj`
- [x] 2.13 失败用例 `Operator_test`：15 个算子各一组正/反例，`In` 空集合恒 false，`IsNull` vs 字段缺失，`Matches` 整串匹配（C-01/C-02/C-03）
- [x] 2.14 实现 `condition/Operator.cj`、`condition/Operand.cj`，以及三值逻辑求值器 `condition/Truth.cj`
- [x] 2.15 失败用例 `TruthTable_test`：`And`/`Or`/`Not` 与 SQL 真值表一致，`Unknown` 不产生激活（C-04）
- [x] 2.16 失败用例 `Constraint_test` / `Pattern_test`：约束重排语义不变、未知字段抛 `UNKNOWN_FIELD`、绑定名重复抛 `ILLEGAL_STATE`（C-05/C-08）
- [x] 2.17 实现 `condition/Constraint.cj`、`condition/Pattern.cj`、`condition/JoinConstraint.cj`
- [x] 2.18 失败用例 `ConditionExpr_test`：`Or` 跨类型展开为多条规则（id 加 `#1`/`#2`）、`Not` 包裹 join 抛错、深度 33 抛 `TABLE_INVALID`（C-06/C-07）
- [x] 2.19 实现 `condition/ConditionExpr.cj`（含展开与深度校验）
- [x] 2.20 失败用例 `JitExpression_test`：完整 lambda 编译、裸表达式按绑定类型包装、语法错误抛 `SCRIPT_COMPILE`、形参缺失抛 `SCRIPT_BINDING_MISSING`、动态事实绑定走解释器并 WARN
- [x] 2.21 实现 `condition/JitExpression.cj`（两种构造 + `f_jit` 错误包装）与 `condition/Interpreter.cj`（白名单 10 函数 + 节点计数上限）
- [x] 2.22 失败用例 `InterpreterVsJit_test`：同一批表达式在 `JitPreferred` 与 `Interpreted` 下结果逐条一致（I-03）
- [x] 2.23 失败用例 `RuleBuilder_test`：`salience`/`facts`/`addPattern`/`join`/`script`/`then`/`build`（`when`/`where` 是仓颉关键字，故改名为 `addPattern`/`script`），无模式规则抛 `EMPTY_PATTERN`，重复规则 id 抛 `DUPLICATE_RULE`
- [x] 2.24 实现 `rule/Rule.cj`、`rule/RuleBuilder.cj`、`rule/Bindings.cj`
- [x] 2.25 失败用例 `RuleSetBuilder_test`：空间自动声明、`registerFact(space, schema)`、`registerDynamicType`、`expressionMode`、`conflictResolver`、缺省空间 `default`（F-15）
- [x] 2.26 实现 `rule/RuleSet.cj` 与根包 `RuleSetBuilder` 的装配部分（不含网络构建）
- [x] 2.27 失败用例 `RuleSetValidation_test`：跨空间 `CROSS_SPACE_JOIN`、未知空间 `UNKNOWN_FACT_SPACE`（F-13/F-14）、无空间 `EMPTY_FACT_SPACE_SET`、未知类型 `UNKNOWN_TYPE`、失败后 `Invalid` 且不可建引擎
- [x] 2.28 实现构建期校验器 `rule/Validator.cj`，按 `doc/02` §8 表格逐项实现
- [x] 2.29 实现 `ReteNetwork` 之前的顺序匹配器 `test/NaiveMatcher.cj`（嵌套循环 + 逐条 join 判定）与 `test/PropertyGen.cj`（固定种子 20261031）
- [x] 2.30 失败用例 `NaiveMatcher_test`：单空间/多空间分别产出激活、共享空间事实互通、隔离空间互不可见（F-11/F-12）
- [x] 2.31 `cjpm test` 全绿，F-01~F-18、C-01~C-08 全部覆盖

## 3. M2 Rete 网络

- [x] 3.1 失败用例 `Token_test`：结构共享（子令牌只存 parent/handle/binding）、`==`/`hashCode`、`bindings()` 展开、`retain/release` 引用计数归零释放父链（R-14）
- [x] 3.2 实现 `rete/Token.cj`
- [x] 3.3 失败用例 `AlphaNode_test` / `AlphaMemory_test`：链式短路、幂等 `add`、`remove` 通知下游、`probe` 等值命中、无规则关心类型直接忽略（R-01/R-10/R-12/R-13）
- [x] 3.4 实现 `rete/AlphaNode.cj`、`rete/AlphaMemory.cj`（`eqIndex` + `nullSet`）
- [x] 3.5 失败用例 `RangeIndex_test`：`Gt/Ge/Lt/Le/Between` 与全扫结果一致；10 万条插入后范围探测正确；同值 100 条全部返回
- [x] 3.6 实现 `rete/RangeKey.cj` 与 `ordIndex`（`ConcurrentSkipListMap` + `tailer/header/sub`），不设规模阈值
- [x] 3.7 失败用例 `BetaNode_test` / `BetaMemory_test`：等值 join、范围 join、三模式链、`produced` 撤销 O(k)、左/右激活对称（R-02/R-03/R-04/R-09）
- [x] 3.8 实现 `rete/BetaNode.cj`（`JoinPlan` 四分支）、`rete/BetaMemory.cj`（join 索引 + `probeByJoin`）
- [x] 3.9 失败用例 `TerminalNode_test`：`leftActivate` 产出激活、`leftRetract` 移除、只依赖 `ActivationSink`
- [x] 3.10 实现 `rete/TerminalNode.cj` 与 `ActivationSink` 接口、`rete/ReteNode.cj`
- [x] 3.11 失败用例 `NetworkSharing_test`：100 条规则共享 20 个 alpha 签名时节点数 = 20 + join 数；相同 join 签名只建一次；前两模式相同、第三模式不同时前两个 join 共享（R-05/R-06/R-07/R-15）
- [x] 3.12 实现 `rete/AlphaSignature.cj`、`rete/JoinSignature.cj`、`rete/NetworkBuilder.cj`（约束排序后入签名，构建完成后冻结）
- [x] 3.13 失败用例 `ReteNetwork_test`：`assert`/`retract`/`update` 与朴素匹配一致；重复传播幂等；`frozen()` 后 `build` 抛 `NETWORK_FROZEN`（R-08/R-11）
- [x] 3.14 实现 `rete/ReteNetwork.cj`（结构）+ `rete/SessionNetwork.cj`（`(space, session)` memory）+ `rete/SessionRuntime.cj`
- [x] 3.15 失败用例 `SpaceSharding_test`：断言 `a` 空间不影响 `b`（R-16）、相同签名不跨片共享（R-17）、按片重建不影响其他片（R-18）、同会话跨空间各有激活（R-19）、空分片忽略未知类型（R-20）
- [x] 3.16 实现分片路由（`RuleSet` 按 `rule.factSpace` 分组 → 每空间一个 `ReteNetwork`）与按片重建
- [x] 3.17 失败用例 `Differential_test`：≥200 组随机规则/事实，Rete 与 `NaiveMatcher` 的激活集合逐条相等；插入后随机撤销 30% 再比对
- [x] 3.18 差分测试全绿；失败时输出两侧激活的排序键与规则 id 便于定位
- [x] 3.19 `RuleSet` 内部 `matcher` 开关（`Rete` 默认 / `Naive` 仅测试）落地，公开 API 不变
- [x] 3.20 `cjpm test` 全绿，R-01~R-20 全部覆盖

## 4. M3 议程与冲突消解

- [x] 4.1 失败用例 `Activation_test`：相等性 `(factSpace, ruleId, bindings)`、`specificity` 计算、`seq` 单调、跨空间同名规则不同激活
- [x] 4.2 实现 `agenda/Activation.cj`、`agenda/Bindings.cj`（`resolve` 回查来源空间）
- [x] 4.3 失败用例 `Agenda_test`：入队去重、惰性堆跳过失效激活、`fire` 返回执行数、空议程返回 0、`snapshot` 顺序（A-08/A-09）
- [x] 4.4 实现 `agenda/Agenda.cj`（二叉堆 + `index` + `firing` 重入保护 + `popValid`）
- [x] 4.5 失败用例 `ConflictResolver_test`：6 种策略各自排序正确、组合策略全序（任意两个异激活比较不为 0）、自定义解析器可插入（A-01~A-04）
- [x] 4.6 实现 `agenda/ConflictResolver.cj`（含默认链 `salience → specificity → ruleOrder → seq`）
- [x] 4.7 失败用例 `FireMode_test`：`Refract` 只执行一次（A-05）、`NoLoop` 同一绑定跨轮次不重复且 `fire` 后清空（A-06）、`Loop + limit` 执行数等于 limit（A-07）
- [x] 4.8 实现三种 `FireMode` 语义
- [x] 4.9 失败用例 `ActionContext_test`：`fact(binding)` 解析、`assert`/`retract`/`update` 默认写回 `factSpace`、`set`/`get`/`outputs`、`factIn` 只读、`copyTo` 生成新句柄且两库独立撤销（F-17/F-18）
- [x] 4.10 实现 `agenda/ActionContext.cj`、`agenda/ClosureAction.cj`、`agenda/TableAction.cj`
- [x] 4.11 失败用例 `CycleDetection_test`：窗口内第 101 次同一指纹抛 `CYCLE_LIMIT`（A-11）、`enableCycleDetection` 默认关闭
- [x] 4.12 实现循环检测（环形指纹窗口）
- [x] 4.13 失败用例 `FireError_test`：重入抛 `REENTRANT_FIRE`（A-09）、动作异常抛 `ACTION_FAILED` 且 `caused` 保留、已执行动作不回滚（A-10）
- [x] 4.14 实现异常包装与 `caused` 传递
- [x] 4.15 失败用例 `RuleEngine_test` / `RuleSession_test`：`session(id)` 复用、`release` 释放、`closed` 后 `fire` 抛 `CLOSED`、`fireDetailed` 返回 `outputs` + `fired` 行级结果
- [x] 4.16 实现根包 `RuleEngine.cj` / `RuleSession.cj`（含 `fireDetailed`，`fire` 为其薄封装）
- [x] 4.17 `cjpm test` 全绿，A-01~A-11 全部覆盖

## 5. M4 流程编排

- [x] 5.1 失败用例 `RuleEnvelope_test`：`from` 优先取载荷信封、缺信封回退 `event.session`、`wrap` 继承 session/ruleSetId/traceId、`unwrap` 还原载荷
- [x] 5.2 实现 `flow/RuleEnvelope.cj`
- [x] 5.3 失败用例 `FlowContext_test`：`create`/`attach`/`detach`/`current`/`bind`/`unbind`、`facts(space)` 惰性建视图且同一空间同视图、未声明空间抛 `UNKNOWN_FACT_SPACE`、未绑定抛 `NO_CONTEXT`、`release` 按 `Discard` 清空
- [x] 5.4 实现 `flow/FlowContext.cj`（ThreadLocal + 视图缓存 + `Release` 策略）
- [x] 5.5 失败用例 `RuleFlow_test`：`category = "<ruleSetId>/<ruleId>"`、`tag = version`、`flow.toString()` 正确、可独立 `start`（P-01/P-02）
- [x] 5.6 实现 `flow/RuleFlow.cj`
- [x] 5.7 失败用例 `ResolveTask_test`：两路/三路扇出都到达、子事件载荷是信封且 session 与父一致、`plan` 空产出抛 `EMPTY_FANOUT`、返回值 `name == EventType.Multi.toString()`（P-03/P-04/P-12）
- [x] 5.8 实现 `flow/ResolveTask.cj`
- [x] 5.9 失败用例 `JoinTask_test`：收齐只发一次（P-06）、缺一路不发（P-07）、重复到达幂等（P-08）、并发两 session 交错不串扰（P-09）、到齐后清态可下一轮
- [x] 5.10 实现 `flow/JoinTask.cj`（`ConcurrentHashMap<session, BranchState>`，键取信封 session）
- [x] 5.11 失败用例 `JoinTimeout_test`：配置 `timeout` 后未集齐发 `timeoutEvent`、未配置 `timeoutEvent` 发 `ErrorEvent`、`Ticktock` 不可用时构造期 WARN 且不超时
- [x] 5.12 实现 `JoinTask` 超时（`f_ticktock.DelayedTicktockTask` 一次性延迟任务 + 清态）
- [x] 5.13 失败用例 `Reachability_test`：扇出分支直达 `End` 抛 `FANOUT_WITHOUT_JOIN`（P-05）、两个 `JoinTask.branches` 重叠抛 `ILLEGAL_STATE`、合法编排（`order.created → split → {…} → join → End`）通过
- [x] 5.14 实现 `flow/Reachability.cj`（从 `ResolveTask.producing` BFS，遇到 End 边即失败）
- [x] 5.15 失败用例 `SameSpaceFanout_test`：两个分支都在 `orders` 时抛 `SAME_SPACE_FANOUT`（P-14）、跨空间扇出通过（P-13）
- [x] 5.16 实现 `flow/RuleSetFlow.cj` 的 `start`/`fanout`/`join`/`end`/`flow` 与同空间校验
- [x] 5.17 失败用例 `RuleTask_test`：`exec` 按信封取 session → 建事实 → `agenda.fire` → 输出事件带同一 session；未声明空间抛 `UNKNOWN_FACT_SPACE`（I-02）
- [x] 5.18 实现 `flow/RuleTask.cj` 与可配置 `FactFactory`
- [x] 5.19 失败用例 `FlowSessionRegression_test`：构造缺 `JoinTask` 的流程并连续 `start()` 两次，锁定"残留事件会被第二次 `start` 消费"的上游行为（P-05b）
- [x] 5.20 失败用例 `VersionSwitch_test`：新 tag 注册后 `removeExceptCurrentTag()` 生效（P-10）、旧 tag 被依赖时抛 `GraphException`（P-11）
- [x] 5.21 `cjpm test` 全绿，P-01~P-15 全部覆盖

## 6. M5 决策表 API + CSV

- [x] 6.1 失败用例 `DecisionTableBuilder_test`：列声明顺序、`row(values)` / `row(ruleId, values)`、`factSpace` 缺省 `default`、`factType` 缺省单类型推断、多类型无 `factType` 抛 `TABLE_INVALID`
- [x] 6.2 实现 `table/Column.cj`、`table/TableRow.cj`、`table/DecisionTable.cj`、`table/DecisionTableBuilder.cj`
- [x] 6.3 失败用例 `HitPolicy_test`：7 种策略的 0/1/N 命中行为与 `doc/07` §2 表格一致（T-07~T-11）
- [x] 6.4 实现 `table/HitPolicy.cj` 与聚合逻辑 `table/HitAggregator.cj`
- [x] 6.5 失败用例 `CellParser_test`：13 种条件写法、`-` 与空单元格等价、`FieldType` 各类型解析、非法值抛 `TYPE_MISMATCH`（T-05）
- [x] 6.6 实现 `table/CellParser.cj`（算子解析 + 值类型推断）
- [x] 6.7 失败用例 `OutputCell_test`：字面量、`${binding.field}`、`${binding}`、未声明绑定抛 `UNKNOWN_BINDING`（T-06）
- [x] 6.8 实现输出单元格解析（编译期转字段引用）
- [x] 6.9 失败用例 `ExprColumn_test`：`expr` 列裸表达式按 `factType` + 绑定包装编译、语法错误抛 `SCRIPT_COMPILE`
- [x] 6.10 实现 `expr` 列接线到 `JitExpression.ofExpression`
- [x] 6.11 失败用例 `CsvTableParser_test`：基本解析（T-01）、引号转义（T-02）、`#` 注释与 `# key: value` 元数据（T-03）、列数不一致带行号（T-04）、BOM、非 UTF-8 报错
- [x] 6.12 实现 `table/CsvTableParser.cj`（RFC 4180 状态机 + 元数据 + UTF-8 校验）
- [x] 6.13 失败用例 `TableCompiler_test`：每行编译为单模式 `Rule`、`factSpace`/`salience`/`id` 映射正确、`when.*` 未知字段抛 `UNKNOWN_FIELD`、空表抛 `TABLE_INVALID`（T-15）、`Unique` 重复行抛 `TABLE_INVALID`
- [x] 6.14 实现 `table/TableCompiler.cj` 与 §8 校验清单
- [x] 6.15 失败用例 `TableExecutor_test`：端到端输出（I-01）、`Collect` 返回全部且按行序（T-10）、`RowTrace` 记录每列结果
- [x] 6.16 实现 `table/TableExecutor.cj`、`table/TableResult.cj`、`table/RowTrace.cj`
- [x] 6.17 夹具 `src/fixtures/pricing.csv`、`orders.csv`、`users.csv` 并接入测试
- [x] 6.18 `cjpm test` 全绿，T-01~T-11 全部覆盖

## 7.5 M5.5 装配层（设计见 `f_rule/doc/11-assembly.md`，在 M6 之前执行）

- [x] 7.5.1 失败用例 `ActivationGroup_test`：同组两条激活只执行 salience 高的那条、不同组互不影响、无组规则执行数与改动前一致（AS-13/AS-14）
- [x] 7.5.2 `Rule.activationGroup: ?String` + `RuleBuilder.activationGroup(name)` + `Activation.activationGroup`（不参与相等键）
- [x] 7.5.3 `Agenda.fire` 执行后调 `invalidateGroup(group, except)` 移除同组剩余激活
- [x] 7.5.4 失败用例 `TableSource_test`：`compileInto(registry)` 返回行数条规则、未声明空间抛 `UNKNOWN_FACT_SPACE`
- [x] 7.5.5 `TableCompiler` / `TableExecutor` / `DecisionTable.resolvedFactType` 入参由 `RuleSet` 收窄为 `FactSpaceRegistry`；`DecisionTable.compile(ruleSet)` 内部转
- [x] 7.5.6 `DecisionTable` 实现 `TableSource.compileInto`，编译器改用 `RuleRuntime.compiler()`
- [x] 7.5.7 失败用例：`TableCompiler` 按 HitPolicy 注入组与 salience —— `First`/`Unique` 同组且行序降序、`Priority` 同组但降级行序、`Collect`/`RuleOrder` 不分组、`Any`/`OutputOrder` 不分组
- [x] 7.5.8 实现 HitPolicy → `activationGroup` + `salience` 映射；三项降级打 WARN
- [x] 7.5.9 失败用例 `TableAssembly_test`（AS-01~AS-05）：规则进入规则集、id 前缀、未声明空间、重复 id、未注册字段
- [x] 7.5.10 `RuleSetBuilder.table(source: TableSource)`
- [x] 7.5.11 `TableMode`（Unbound/Assembled/Executed）实例级互斥，跨模式抛 `TABLE_MODE_CONFLICT`（第 27 个错误码）；同步 `RuleException_test` 的 26 → 27
- [x] 7.5.12 失败用例 `EngineTable_test`（AS-06~AS-08）：端到端、缓存只编译一次、表换版本重编译
- [x] 7.5.13 `RuleEngine.executeTable(table, session, trace)` + 按 `(id, version)` 缓存执行器
- [x] 7.5.14 AS-09~AS-12 补全：`First` 只执行第一行、`Collect` 全执行、双向模式冲突、同模式重复使用
- [x] 7.5.15 `doc/07` §2.1 等价表、`doc/08` 示例、`CHANGELOG` 同步
- [x] 7.5.16 `cjpm test` 全绿（预期 352 + 14 = 366）

## 7. M6 决策表 XLSX

- [x] 7.1 失败用例 `XlsxTableParser_test`：表头解析、`_meta` sheet 表属性、类型行覆盖推断、sheet 名作为表 id（T-12 前置）
- [x] 7.2 实现 `table/XlsxTableParser.cj` 的整表路径（`ExcelDocument` + `sheet(name)` + `cell(row,col)`）
- [x] 7.3 失败用例：`CellValue` 八变体映射、`Formula(_, None)` 与 `Error` 抛 `TABLE_INVALID`、字段声明与单元格类型冲突时以字段声明为准并 WARN
- [x] 7.4 实现类型推断优先级（单元格 > 类型行 > 字段声明）
- [x] 7.5 失败用例：合并单元格取左上角值（T-13）、`mergedValue` 与合并范围重叠
- [x] 7.6 实现合并单元格处理
- [x] 7.7 失败用例：`parse(path)` 返回多表、`parse(path, sheet)` 返回单表、`stream(path)` 逐表迭代
- [x] 7.8 实现流式路径（`ExcelSheetStream.open` + `rows(sheet)`），10 万行内存恒定（T-14）
- [x] 7.9 夹具生成脚本 `doc/tools/gen_fixtures.py` 生成 `pricing.xlsx`、`pricing_large.xlsx`
- [x] 7.10 失败用例：`pricing.xlsx` 与 `pricing.csv` 编译结果逐字段相同（T-12）
- [x] 7.11 `cjpm test` 全绿，T-12~T-15 全部覆盖

## 8. M7 性能门禁与收尾

- [x] 8.1 失败用例 `PerfNetwork_test`：B-01（1000 规则构建 < 500ms、节点数 < 3000）、B-06（重复构建 < 50ms）
- [x] 8.2 失败用例：B-02（10000 事实 < 2s 且激活数与朴素一致）、B-03（单条插入 P95 < 1ms）、B-04（撤销 30% < 500ms）
- [x] 8.3 失败用例：B-05（RSS < 512MB）、B-07（1000 行决策表解析 + 编译 < 300ms）
- [x] 8.4 调优至全部门禁达标；实测值写入 `f_rule/doc/perf.md`（含机器、日期、构建模式）
- [x] 8.5 差分回归：`Differential_test` ≥200 组与 `InterpreterVsJit_test` 在 M7 全量重跑
- [x] 8.6 补齐 `I-01~I-06` 集成用例（决策表→Rete→议程、决策流 + 产生式混用、未登记类型构建期报错）
- [x] 8.7 `f_rule/README.md`：状态改为可用，补快速开始与"产生式 / 决策表 / 决策流"三种典型用法、初始化顺序、空间与扇出约束（实际写了四种用法 + 6 条约束表）
- [x] 8.8 `f_rule/CHANGELOG` 记录首个版本；`f_rule/doc/01~10` 与实际实现对齐（API 签名、配置项、错误码；doc/10 补 M5.5 里程碑与验收状态）
- [x] 8.9 `cjlint -f ./src -m $CANGJIE_HOME` 的非 License error 归零（41 条已修：G.FUN.02 30、G.ENU.01 4、G.DCL.02 4、G.EXP.03 3）；仅剩 G.OTH.03，交项目级配置处理。`cjfmt` 仍按 `doc/10` §7 的结论保留
- [x] 8.10 验收清单逐项核对（`doc/10` §7）：里程碑退出条件、公开 API 用例、差分、门禁、文档一致、CHANGELOG；`cjfmt` 一项按项目格式惯例如实标注未满足

## 9. 验证报告跟进（C2/C3/C4 + lint）

- [x] 9.1 C2：运行期异常/超时视为 `Unknown`，WARN 含规则 id、session、site；失败计数按 `(ruleSetId, ruleId)` 规则集级共享，连续 100 次禁用并记 ERROR，成功一次清零；终端脚本、alpha 单事实约束、beta join 三类求值点统一收敛；`EngineOptions` 进 `engine` 包，`RuleEngine(ruleSet, options)` 重载
- [x] 9.2 C3：动态事实脚本条件走解释器；运行期类型不符按 `TYPE_MISMATCH` 分类，与 C2 共用同一计数器与禁用位（脚本/约束/join 均覆盖）
- [x] 9.3 C4：`RuleAction` 改为 `execute(ctx: ActionContext)` 接口；`ClosureAction`/`TableAction`/`ScriptAction` 三实现；`then(action: (ActionContext) -> Unit)` 签名不变，新增 `thenScript(source)`，脚本编译失败抛 `SCRIPT_COMPILE`
- [x] 9.4 lint：修掉全部 41 条非 License error，`cjlint -f ./src -m $CANGJIE_HOME` 只剩 G.OTH.03
- [x] 9.5 回归：`cjpm test` 430 个用例全绿（原 418 + 新增 12），`doc/03`、`doc/05`、`doc/08` 同步完成
