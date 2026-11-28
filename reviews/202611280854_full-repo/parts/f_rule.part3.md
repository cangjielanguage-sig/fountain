# f_rule 模块审查报告（模块第 3/12 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_rule`（全模块 184 个 `.cj` / 33 个 `.md`；本部分 13 个 `.cj` / 7 个 `.md`）
- **基线**：工作区快照（sts/1.3.x 工作区，未对照远端目标分支；本部分文件 `git status` 无本地改动，全部按存量审）
- **审查重点**：规则引擎求值正确性、递归与栈溢出、OOM、死代码、重复逻辑、并发安全、存量 BUG
- **报告版本**：v1（本部分只写分报告，`docs/review/2026-11-28/f_rule.md` 由主 Agent 合并产出）
- **本部分范围**：`doc/spec/archive/**/tasks.md`、`doc/spec/specs/f-rule-{agenda,condition,decision-table,engine-core,fact-model,flow,rete}/spec.md`、`src/{RuleInitializer,RuleSetBuilder,RuleSetBuilderCondition,RuleSetValidation}*.cj`、`src/agenda/{ActionContext,Activation,ActivationSink}.cj` 及其 5 个 `_test.cj`

## 发现

### [一般][存量] 动作改事实与 Rete 传播不是原子操作，传播失败后事实库与网络永久分叉

- **位置**：`f_rule/src/agenda/ActionContext.cj:103`（`assert`）、`:109`（`retract`）、`:115`（`update`）
- **来源**：存量（`git blame`：`4e1987478 feat(f_rule): M3 议程、冲突消解与引擎门面`）
- **判据**：review-checklist §11（资源/状态不对称、错误处理缺失）、§3（静默吞掉失败路径）
- **证据**：静态确定 —— `assert` 先 `view_.assert(fact)` 写库，再 `propagation_.onAssert(...)` 推网络；`retract` 先 `view_.retract(handle)` 删库，再 `onRetract`。两步之间任何一次传播抛错就会停在"库已改、网络未改"。传播确实会抛：`SessionRuntime.shard()` 在分片缺失时抛 `UNKNOWN_FACT_SPACE`（`src/rete/SessionRuntime.cj:128-135`），`ShardedNetwork`/`SessionNetwork` 的传播路径也未声明不抛。对照 `RuleSession.assert` 的同名入口，那里有 `try { runtime_.assert } catch { view_.retract(handle); throw }` 的回滚（`src/engine/RuleSession.cj:164-175`），动作路径没有。
- **描述**：触发条件是动作里 `ctx.assert` / `ctx.retract` / `ctx.update` 的传播抛异常（分片缺失、网络内部错误）。后果：`assert` 失败后事实在库里、网络永远看不到它（后续 `fire` 不再产生相关激活，`session.factsOf(space).scan` 却能查到）；`retract` 失败后库里没了、网络仍持令牌，`TerminalNode` 会继续把已撤销事实的激活送进议程。`Agenda.runOne` 只把它包成 `ACTION_FAILED` 上抛（`src/agenda/agenda.cj:270-288`），调用方 `catch` 之后会话状态已不可信。规范允许"已执行动作不回滚"（f-rule-agenda spec:121-122），但那说的是动作之间，不是单次动作内库与网络的不一致。
- **建议**：在 `SessionActionContext` 内对齐 `RuleSession` 的做法：`assert` 传播失败时 `view_.retract(handle)` 回滚；`retract`/`update` 先做传播再改库（或失败时恢复原事实并用同一 handle 重插）。若判定传播不可能失败，就把 `SessionRuntime.shard` 的抛错条件在装配期排除并写明前提。

### [一般][存量] `Bindings.resolve` 不回查事实库，`fact(binding)` 把已撤销事实当有效事实返回

- **位置**：`f_rule/src/agenda/ActionContext.cj:92-101`（`case None => activation_.bindings.resolve(binding)`，第 97 行）；根因 `f_rule/src/agenda/Bindings.cj:74-76`
- **来源**：存量（`4e1987478`；`Bindings.cj` 同提交）
- **判据**：review-checklist §11（语义与注释/契约不符）、§13（规格与实现漂移）
- **证据**：静态确定 —— `Bindings.resolve` 只是 `facts_.get(binding)`，返回激活构造时捕获的实例，没有任何 `FactBase` 引用；而 `doc/spec/specs/f-rule-agenda/spec.md:15` 明写"`resolve` SHALL 回查 `activation.factSpace` 对应的 `FactBase`"。`fact()` 的 KDoc（`ActionContext.cj:86-91`）也把回退描述为"没有句柄（朴素匹配路径）时"，但实现把"有句柄、事实已被撤掉"这条路径也接到了同一个回退上。
- **描述**：`bindings.get` 返回 `Some(handle)` 后 `view_.get(handle)` 为 `None`（事实已被本规则前面某个动作 `retract`，或被 `update` 换成了新实例）时，代码回退到快照，于是动作能继续读写一个已经不存在的事实。典型序列：`rule.actions = [a1, a2]`，`a1` 里 `ctx.retract(ctx.fact("o"))`，`a2` 里 `ctx.fact("o").getOrThrow()` 仍拿到旧对象并据此 `set` 输出槽或再断言回去——输出值来自撤销前的事实，且没有任何提示。`update` 之后的读不走这条路径（`view_.get` 命中新实例），所以"注释承诺的当前实例"只在 update 场景成立。
- **建议**：`Some(handle)` 且 `view_.get(handle) == None` 时返回 `None`（把快照回退限制在 `bindings.get(binding).isNone()` 这一支）。同时把 `resolve` 的语义二选一写清：要么按 spec 回查 `FactBase`，要么改 spec 为"激活时快照"，不要两处各说一套。

### [一般][存量] f-rule-agenda 规格的异常语义自相矛盾，且与实现对不上

- **位置**：`f_rule/doc/spec/specs/f-rule-agenda/spec.md:121-122`；实现 `f_rule/src/agenda/agenda.cj:270-288`
- **来源**：存量（spec 文件 `810651520 chore(f_rule): 归档 implement-f-rule-m0-m7，同步主规范到 doc/spec`）
- **判据**：review-checklist §13（规格与实现漂移）
- **证据**：静态确定 —— spec 同一条里同时要求"立即终止并**原样上抛**"与"**包装为** `RuleException(ACTION_FAILED)`，`caused` 保留原异常"；实现对 `RuleException` 原样上抛（注释写明"不再套一层"），对其它 `Exception` 才包 `ACTION_FAILED`。两条要求无法同时满足。
- **描述**：读者按 spec 无法判定"动作里 `ctx.factIn("nope", h)` 抛出的 `UNKNOWN_FACT_SPACE` 最终以哪个 code 呈现"——按实现是 `UNKNOWN_FACT_SPACE`，按 spec 字面应是 `ACTION_FAILED`。决策表/流程侧依靠 `catch RuleException` 分支处理错误码的代码会因此误判。
- **建议**：改成两句分情况表述（"已是 `RuleException` 的原样上抛；其它异常包装为 `ACTION_FAILED` 并带 `caused`"），并补一条断言该行为的分支用例（现有 `FireError_test` 只覆盖 `ArithmeticException` 型动作异常）。

### [轻微][存量] 激活相等键用 `|` 直接拼接，id 含分隔符时静默碰撞

- **位置**：`f_rule/src/agenda/Activation.cj:52`（`"${rule.factSpace}|${rule.id}|${bindings.sortKey()}"`）
- **来源**：存量（`d03b92da3 docs(f_rule): M7 收尾…`）
- **判据**：review-checklist §11（边界）、§12.1（复合键判等）
- **证据**：静态确定 —— 键由三段字符串以 `|` 连接；`factSpace` 与 `rule.id` 都是调用方给的自由文本，`RuleSetBuilder`/`RuleBuilder` 未校验分隔符（全模块无相关校验）。`(space="a|b", rule="R1")` 与 `(space="a", rule="b|R1")` 在同一组绑定下产生同一 `key_`。
- **描述**：碰撞后 `Activation.==` 判等、`Agenda.index_` 去重（`agenda.cj:115-122`）会把其中一条激活当成重复丢弃：规则静默不触发，且没有任何日志。同模块的 `FactBaseViewStore.key` 已经用 `\u{0001}` 并写明"分隔符不可出现在空间名/会话名里即可"（`src/fact/FactBaseView.cj:233-236`），两处口径不一致。概率低（需要刻意构造 id），后果是静默少执行一条规则，故定轻微。
- **建议**：与 `FactBaseViewStore` 统一用不可打印分隔符，或在 `RuleSetBuilder.build` 校验 `rule.id` / space 名不含分隔符。

### [轻微][存量] 跨空间句柄的 `retract` / `update` 静默无操作

- **位置**：`f_rule/src/agenda/ActionContext.cj:109-119`
- **来源**：存量（`4e1987478`）
- **判据**：review-checklist §11（错误处理缺失）、§3（静默）
- **证据**：静态确定 —— `view_` 是 `activation_.factSpace` 的视图，`FactBase.retract` 以 `FactHandle`（含 space）为键查 `facts_`（`src/fact/FactBase.cj:112-120`），非本空间句柄必然返回 `false`，于是 `propagation_` 不触发、整个调用无声返回。
- **描述**：动作里 `ctx.retract(ctx.factIn("users", h).handle)` 这类写法（spec 只承诺 `factIn` 只读，`retract` 默认本空间）会静默不执行任何动作。与 `factIn` 对未声明空间抛 `UNKNOWN_FACT_SPACE` 的风格不一致，调用方无法区分"撤销成功"与"句柄不属于本空间"。spec 的措辞（f-rule-agenda spec:108-111）只说"本上下文不提供"，没说不提供时的表现。
- **建议**：`handle.space != factSpace` 时抛 `RuleException(ILLEGAL_STATE, ...)`，或至少 `log.warn` 一次；并给一条用例锁定。

### [轻微][存量] 测试注释与实现不符，断言无法发现差异（`outputSlotsAreShared`）

- **位置**：`f_rule/src/agenda/ActionContext_test.cj:155-165` vs `f_rule/src/agenda/ActionContext.cj:129-135`
- **来源**：存量（`4e1987478`）
- **判据**：review-checklist §11（语义与注释不符）、§13
- **证据**：静态确定 —— 用例名与注释称"`set`/`get`/`outputs` 指向同一份本次执行结果"，但 `outputs()` 逐条复制出一个新 `HashMap`（同一模式在 `agenda.cj:257-263`、`Bindings.cj:179-193` 也重复出现）；用例只断言 `ctx.outputs().size == 1`，把实现改成返回内部引用、深拷贝或只读视图都仍然通过。
- **描述**：这条用例锁不住任何语义，等于只验证了"写完能读到 size"。若将来有人为了性能把 `outputs()` 改成返回内部 map，调用方拿到的就是可继续被后续动作改写的活引用，而测试不会报警。
- **建议**：注释改为"返回快照"，并补断言 `ctx.outputs()` 与随后 `ctx.set` 的隔离性（改后再取 size 变化，或断言两次取到的实例不是同一个）。

### [轻微][存量] 测试里的死读：`let _ = original`

- **位置**：`f_rule/src/agenda/ActionContext_test.cj:125`
- **来源**：存量（`4e1987478`）
- **判据**：review-checklist §1（读了不用 / 无意义抑制语句）
- **证据**：静态确定 —— `original` 由 `setup()` 返回后在本用例中未被使用，`let _ = original` 只为消除未使用告警；同一函数第 121 行用 `_` 解构就能达到目的。
- **描述**：无功能影响，但把"占位"写成了正式语句，掩盖了 `setup()` 返回 5 元组而本用例只用 3 个的事实。
- **建议**：第 121 行改成 `let (views, _, _, _, activation) = setup()`，删除第 125 行。

### [轻微][存量] `RuleInitializer_test` 对 f_app 注册行为的描述与框架实现不符

- **位置**：`f_rule/src/RuleInitializer_test.cj:26`；框架实现 `f_app/src/Initializer.cj:54-69`
- **来源**：存量（`f387e214e feat(f_rule): M0 模块骨架与运行时`）
- **判据**：review-checklist §11（注释与实现不符）
- **证据**：静态确定 —— 注释写"`f_app` 按 `name` 去重、按 `dependencies` 排序执行初始化"，但 `InitializerCollection.doRegister` 只是 `initializers.add(initializer)` 并把依赖登记进 `dependencies` map，**没有任何按 name 去重**的逻辑（同名注册两次会在 `doInit` 里执行两次 `initialize()`）。
- **描述**：误导后续维护者：以为 `RuleInitializer` 的静态注册天然幂等（例如动态库被加载两次、测试重复 import 时不会重复初始化），而实际会重复执行。`name` 在本模块确实是契约（`dependencies` 用它做拓扑排序），这部分描述正确。
- **建议**：删掉"按 name 去重"，或改为"`name` 用于依赖排序与识别"。若确实需要幂等，应在 `RuleInitializer.init()` 里做保护（当前 `initialize()` 只取一次 `RuleRuntime.compiler()`，重复执行无害，但语义上应写明）。

### [轻微][存量] f-rule-condition 规格未覆盖同类型 `Or` 拆分与 64 条展开上限

- **位置**：`f_rule/doc/spec/specs/f-rule-condition/spec.md:77-79`；实现 `f_rule/src/rule/ConditionExpander.cj:31`；用例 `f_rule/src/RuleSetBuilderCondition_test.cj:97-111`、`:201-214`
- **来源**：存量（`810651520`）
- **判据**：review-checklist §13（规格遗漏 / 用户可见行为无承诺）、§14.1（能力未文档化）
- **证据**：静态确定 —— spec 只写"`Or` 的分支**跨不同 `typeTag`** 时 SHALL 展开"与"嵌套深度上限 32"；实现对所有 `Or` 一律按 DNF 拆分（`orWithinOneTypeExpands` 断言同类型 `Or` 也产出 `R1#1` / `R1#2` 两条规则），并且另有 `maxExpansions = 64` 的展开条数上限（消息"条件树展开爆炸"）。
- **描述**：这两项都改变外部可见结果（`RuleSet.rules` 的条数、`rule.id` 后缀、决策表/规则集 id 前缀），却只存在于实现与用例中。spec 读者会以为同类型 `Or` 保留单条规则，按 32 层嵌套构造条件树时也不会预期"条数超 64 就 `TABLE_INVALID`"。
- **建议**：在"条件树与展开限制"一节补两条：`Or` 无论是否跨类型都按 DNF 拆分并加 `#n` 后缀；展开条数上限 64，超出抛 `TABLE_INVALID`（消息口径一并写死）。

### [轻微][存量] f-rule-condition 规格只列两种 `JitExpression` 构造，实现有五种

- **位置**：`f_rule/doc/spec/specs/f-rule-condition/spec.md:93-97`；实现 `f_rule/src/condition/JitExpression.cj:78/97/128/177/188`
- **来源**：存量（`810651520`）
- **判据**：review-checklist §13（公开 API 与规格不符）
- **证据**：静态确定 —— spec 写"SHALL 支持两种构造：`of(source)` 与 `ofExpression(source, bindings)`"；实现还有 `forRule(...)`、`interpreted(source, parameters)`、`interpretedOf(source)`，且本部分用例 `RuleSetBuilderCondition_test.cj:173` 正是用 `JitExpression.interpreted("o.amount > 100", ["o"])` 构造脚本条件。
- **描述**：规格声称"两种"，用例却用了第三种，读者按 spec 写不出用例里的写法。
- **建议**：补 `forRule` / `interpreted` / `interpretedOf` 三个构造的适用场景（尤其 `interpreted` 是强制解释器模式的唯一入口，与 `ExpressionMode.Interpreted` 的关系要写明）。

### [轻微][存量] f-rule-agenda 规格暗示循环检测阈值可配，实现只能配窗口

- **位置**：`f_rule/doc/spec/specs/f-rule-agenda/spec.md:117-119`；实现 `f_rule/src/rule/RuleSet.cj:76/115-129`
- **来源**：存量（`810651520`）
- **判据**：review-checklist §13（配置面与规格不符）
- **证据**：静态确定 —— spec 写"同一指纹在窗口内出现超过阈值（**默认** 100）"，"默认"隐含可改；`RuleSet` 只有 `enableCycleDetection(window!)`，`cycleThreshold_` 固定 100 且只有 getter，全模块无写入点（`grep cycleThreshold` 仅 `RuleSet.cj:61/76/115` 与 `RuleSession.cj:122`、用例 `CycleDetection_test.cj:110`）。`CycleDetector` 的构造虽然收 `threshold!`，但 `RuleSession` 传的是 `ruleSet.cycleThreshold`，外部改不到。
- **描述**：使用者想调阈值（例如 20 次就判环）没有任何入口；spec 又暗示可调。
- **建议**：`enableCycleDetection(window!, threshold! = 100)` 一并暴露，或把 spec 改成"阈值固定 100"。

### [轻微][存量] §2 重复逻辑：差分基准复制了 `Activation` / `Bindings` 的指纹与 `specificity` 实现

- **位置**：`f_rule/src/test/NaiveMatcher.cj:51-58`（`specificity`）、`:62-92`（`sortKey`） vs `f_rule/src/agenda/Activation.cj:56-62`、`f_rule/src/agenda/Bindings.cj:132-147`
- **来源**：存量（`Activation.cj` 见 `d03b92da3`；`NaiveMatcher.cj` 在 M2 提交）
- **判据**：review-checklist §2（表现形式不同的重复逻辑 / 实现漂移）
- **证据**：静态确定 —— 两处各自手写同一公式 `patterns.size + Σ constraints.size`；两处各自手写同一格式 `"${space}|${ruleId}|" + Σ "${name}=<identity>;"`。差异只在"事实不是 `IdentifiedFact`"时的回退：`Bindings` 回退成 `FactHandle` 串，`NaiveActivation` 回退成 `"?"`。
- **描述**：这是差分测试的基准，**保持独立实现是合理设计**（避免与被测代码共享同一个 bug），所以不建议合并；但代价是这条字符串格式成了只存在于两处代码里的隐性契约——任一侧改格式，差分测试会以"激活集合不一致"的形式失败，而不是编译错误，排查成本高。另外那个回退差异目前不可达（`DynamicFact`/`TypedFact` 都实现 `IdentifiedFact`，`src/fact/DynamicFact.cj:32`、`src/fact/TypedFact.cj:24`），一旦引入自定义 `Fact` 实现就会真的让两侧键不同。
- **建议**：保留两份实现，但在 `Bindings.sortKey` 与 `NaiveActivation.sortKey` 的 KDoc 里互相点名"格式必须逐字一致"（现在 `Activation.cj:27-28` 只有单向声明），并把回退键统一成 `"?"` 或都改成句柄串。

### [轻微][存量] §2 重复逻辑：HashMap 手工复制循环在模块内重复四处

- **位置**：`f_rule/src/agenda/ActionContext.cj:129-135`、`f_rule/src/agenda/agenda.cj:257-263`、`f_rule/src/agenda/Bindings.cj:179-193`（`copyHandles` / `copyFacts`）
- **来源**：存量（`4e1987478`）
- **判据**：review-checklist §2（字面量/结构复制）
- **证据**：静态确定 —— 四处都是 `let copy = HashMap<K, V>(); for ((k, v) in src) { copy[k] = v }; copy` 同一形状，仅泛型参数不同，且都出现在本部分的调用链上（`outputs()`、`lastOutputs()`、`Bindings.of`）。
- **描述**：无行为差异，纯维护成本：将来若要改成"预留容量"或"只读视图"，需要同步改四处。属于模块内 util 级别的小重复，不涉及分层问题。
- **建议**：在 `f_rule` 内建一个 `collectionUtil`（或直接用 std 提供的等价构造，先查 `std.collection.HashMap` 是否有接受集合的构造再决定），四处统一调用。

> 范围外提示（不计入本部分统计）：
> 1. `Agenda.remove` 只清有效性位（`agenda.cj:125-127`），失效激活对象连同它持有的 `Bindings`（含事实引用）要等 `popValid` 弹出才释放（`agenda.cj:291-299`）；对"大量 assert + retract 但从不 fire"的会话，`heap_` 会随历史激活数无界增长——属 `.cj` 子轮范围，请勿遗漏。
> 2. `CycleDetector` 的 KDoc 称"`window` 必须大于 `threshold`……构造期直接拒绝"（`src/agenda/CycleDetector.cj:26-30`），构造体只校验两者 `>= 1`（`:39-51`），注释承诺的校验不存在。
> 3. `doc/08-api.md:20-26` 把 `RuleEngine`、`FactBase`/`FactBaseView` 标为线程安全，但 `RuleEngine.session` 的 check-then-write 与 `FactBase` 的普通 `HashMap` 都没有同步——该问题已由第 2 部分作为严重项报出，此处不重复计数。

## 优化可行性方案

### [CPU] `Activation.specificity` 在每次激活构造时重算，可预计算到 `Rule`

- **现状**：每个 `Activation` 构造都调 `Activation.specificityOf(rule)`（`Activation.cj:50`），遍历全部 `pattern` 再累加每个 pattern 的 `constraints.size`（`:56-62`）。`Rule` 在规则集构建后不可变，`specificity` 只依赖 `rule`，同一规则产出 N 个激活就重算 N 次；B-02（1000 规则 / 10000 事实 / 1000 激活）量级下是 1000 次重复遍历。
- **方案**：在 `Rule` 构建完成时算一次并作为 `let specificity: Int64` 字段（或 `RuleBuilder.build()` 里赋值），`Activation` 直接读 `rule.specificity`；`specificityOf` 保留为构建期的计算函数。
- **预期**：激活产出路径少一次 O(patterns × constraints) 遍历，收益随"每条规则的约束数 × 激活数"线性增长；具体占比无数据。
- **代价**：`Rule` 增加一个字段（+8B/规则，可忽略）；`Rule` 是 public 类型，需同步 README 的成员清单；`Activation.specificityOf` 若被外部调用（当前只有构造与 `NaiveActivation` 的等价实现）保持不变即可，语义不变。
- **验证**：`cjpm bench -O2`（同机、同输入）对照 B-02 的插入耗时中位数与 P95，并用 `cjprof` 看 `specificityOf` 的 self time 占比是否从非零降到 0。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 动作里高频 `ctx.fact("o")` 的双次哈希查找（`bindings.get` + `view_.get`）占动作自耗时可观比例 | `f_rule/src/agenda/ActionContext.cj:92-101` | 动作路径自耗时占比、每动作平均读取次数 | 构造"单规则 10 个动作、每动作读 5 个绑定"的会话跑 10k 次 `fire`，`cjprof record` 看 `ActionContext.fact` self time |
| 2 | `outputs()` 的全量复制在决策表批量输出场景产生可观测分配 | `f_rule/src/agenda/ActionContext.cj:129-135` | 每次 `fire` 的分配字节数、`outputs()` 调用次数 | 在 `TableExecutor` 路径埋计数 + `getAllocatedHeapSize()` 前后差，1000 行表跑 100 轮 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `doc/spec/archive/2026-11-01-implement-f-rule-m0-m7/tasks.md` | .md | ✅ | 已归档变更的当时的任务清单，逐条与当前实现抽查（4.1~4.17、7.5.1~7.5.3、10.1~10.3 对应本部分文件）；按"当时结论是否自洽"核对，未按当前实现要求；M0 期的"26 个错误码"已在 7.5.11 自行修订为 27，自洽 |
| 2 | `doc/spec/specs/f-rule-agenda/spec.md` | .md | ✅ | 激活/议程/冲突消解/动作上下文/循环检测；见发现 #2、#3、#5、#11 |
| 3 | `doc/spec/specs/f-rule-condition/spec.md` | .md | ✅ | 算子/三值逻辑/条件树/求值模式；见发现 #9、#10 |
| 4 | `doc/spec/specs/f-rule-decision-table/spec.md` | .md | ✅ | 表模型/单元格/命中策略/CSV/XLSX；逐项核对 `DecisionTableBuilder`（`whenColumn`/`thenColumn`/`exprColumn`/`row`/`build`）、`DecisionTable.builder`、`TableExecutor.execute(facts, trace!)`、`TableResult`/`RowTrace`、`HitPolicy` 默认 `First`，一致 |
| 5 | `doc/spec/specs/f-rule-engine-core/spec.md` | .md | ✅ | 门面/校验/错误码/初始化/性能门禁；27 个错误码与 `RuleErrorCode.cj` 逐项对齐；`RuleInitializer` 名称与依赖一致；B-01~B-07 的实测值确在 `doc/perf.md`（188MB/58ms 等），门禁用例 `src/test/Perf*_test.cj` 齐备 |
| 6 | `doc/spec/specs/f-rule-fact-model/spec.md` | .md | ✅ | 事实双形态/句柄/ValueKey/空间/会话视图；`FactBaseView` 实际成员比 spec 列的 7 个多 `update`/`assertCopy`/`copyTo`/`size`/`level`，属规格列举不全（并入 #9 的同类问题，不单列） |
| 7 | `doc/spec/specs/f-rule-flow/spec.md` | .md | ✅ | 一规则一 Flow/扇出/汇合/session 透传/FlowContext；抽查 `RuleFlow.build` 的 `category` 拼接（`src/flow/RuleFlow.cj:50-52`）一致；其余由第 2 部分（flow 子轮）负责实现核对 |
| 8 | `doc/spec/specs/f-rule-rete/spec.md` | .md | ✅ | 分片/alpha/beta/索引/增量传播；抽查 `ConcurrentSkipListMap` 有序索引（`src/rete/AlphaMemory.cj:43/253`）与 `SessionNetwork`/`SessionRuntime` 命名一致 |
| 9 | `src/RuleInitializer.cj` | .cj | ✅ | 52 行；`initializer` 模式与 `f_health`/`f_egraph` 同型，`name`/`dependencies` 与 spec、用例三方一致；无死代码（`init()` 由 `static init()` 与用例使用） |
| 10 | `src/RuleInitializer_test.cj` | .cj | ✅ | 2 个用例；注释对 f_app 去重的描述不属实，见发现 #8；`lazyWarningCount` 的 WARN-once 契约由 `RuleRuntime_test` 覆盖，本文件不重复断言 |
| 11 | `src/RuleSetBuilderCondition_test.cj` | .cj | ✅ | 11 个用例；同类型 `Or` 拆分与 64 条上限的规格缺口见发现 #9；`JitExpression.interpreted` 见 #10 |
| 12 | `src/RuleSetBuilder_test.cj` | .cj | ✅ | 7 个用例；逐条核对 `RuleSetBuilder` 实际方法（`registerFact`/`registerDynamicType`/`factSpace`/`rule`/`expressionMode`/`conflictResolver`/`build`/`buildOrInvalid`/`lastError`）均存在；`IdentityResolver`/`BuilderOrder`/`builderOrderSchema` 均为测试宿主，对外可达不判死代码 |
| 13 | `src/RuleSetValidation_test.cj` | .cj | ✅ | 11 个用例；错误码与 `RuleErrorCode` 对齐；`failedBuildLeavesInvalidState` 复用同一 builder 连调两次 `build`，行为与实现一致（`lastError` 缓存） |
| 14 | `src/agenda/ActionContext.cj` | .cj | ✅ | 150 行；非原子传播见 #1，陈旧事实回退见 #2，跨空间静默见 #5，`outputs()` 复制见 #6、#13；`NoopPropagation` 是有 KDoc 的 Null Object，不计空实现 |
| 15 | `src/agenda/ActionContext_test.cj` | .cj | ✅ | 6 个用例 + `RecordingPropagation`；见 #6、#7；`copyTo` 的双库独立撤销断言有效 |
| 16 | `src/agenda/Activation.cj` | .cj | ✅ | 101 行；相等键分隔符见 #4，`specificityOf` 预计算见优化方案；`seq` 走 `AtomicInt64`，无共享可变状态问题 |
| 17 | `src/agenda/ActivationGroup_test.cj` | .cj | ✅ | 4 个用例（AS-13/AS-14 + 组名不参与相等键）；与 `Agenda.invalidateGroup` 行为一致；`bindingsOf` 与 `Agenda_test` 同名 helper 属测试准备代码，按 §2 误报边界不计重复 |
| 18 | `src/agenda/ActivationSink.cj` | .cj | ✅ | 27 行，仅 `add`/`remove` 接口声明 + 包归属理由的 KDoc；无实现、无死代码 |
| 19 | `src/agenda/Activation_test.cj` | .cj | ✅ | 5 个用例；`specificity`=4、跨空间不同激活、`seq` 单调等断言与实现一致；`ruleOrder` 透传未断言（`Activation.cj:71-75` 无覆盖），影响小，记入总评不单列 |
| 20 | `src/agenda/Agenda_test.cj` | .cj | ✅ | 6 个用例 + `RecordingRunner`（被 `ActivationGroup_test` 复用）；断言与 `Agenda` 的惰性堆/去重/`fire` 返回值一致；`fire(limit:)` 的 limit 语义本文件无覆盖（`FireMode_test` 在别处） |

合计：`.cj` 13 个 / `.md` 7 个 / 共 20 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 3 | #1、#2、#5 计入正确性与错误处理；分层（`ActionContext` 接口在 `rule` 包、实现在 `agenda` 包以避免包循环）经核对成立，设计维度无问题；无外部输入拼串/SQL/凭据，安全性 0；`Option` 用法（`?Fact`/`?FactHandle` 经 `match` 展开、`getOrThrow` 仅在有判定后使用）无静默丢弃 |
| §1 死代码 | 1 | 逐个检查本部分 4 个源文件的 private 字段/方法（`activation_`/`view_`/`viewOf_`/`outputs_`/`propagation_`/`key_`/`seqCounter`/`handleKey`/`nextSeq`/`specificityOf` 等）全仓搜引用均有调用者；`public` 类型（`Activation`/`SessionActionContext`/`NoopPropagation`/`FactPropagation`/`ActivationSink`/`RuleInitializer`）对外可达，不判；`protected` 声明 0 个。命中 1 条为测试里的死读（#7） |
| §2 重复逻辑 | 2 | 同文件内两两比对 `ActionContext` 7 个方法体（`assert`/`retract`/`update` 三者形状相似但目标不同，不算重复）；跨文件按错误消息、字面量、格式串搜索，命中差分基准的键/公式复制（#12）与 HashMap 复制循环（#13）；测试 helper 的重复按误报边界不计 |
| §3 空实现 | 1 | `NoopPropagation` 三个空方法是带 KDoc 的 Null Object（spec 明确允许），不计；`copyTo` 的 `case None => ()` 会静默跳过传播，并入 #1 的同类失败路径，#5 是"静默无操作"形态 |
| §4 栈溢出 | 0 | 本部分 4 个源文件无递归、无自引用结构遍历、无每帧大对象（`Activation`/`ActionContext` 全是平铺方法）；递归的条件树 `depth()`/展开在 `condition`、`rule` 子轮范围，已在此说明不重复 |
| §5 OOM | 0 | 本部分无全量物化、无按不可信长度预分配、无只增不减的容器：`outputs_`/`bindings` 的生命周期是单次激活；`Activation` 的 `key_` 长度随绑定数（规则内常量）线性，不随输入增长。`Agenda.heap_` 的保留问题在 `agenda.cj`，已列范围外提示 1 |
| §6.1 热点瓶颈 | 0 | 未提供本部分的 profile/bench 数据；`doc/perf.md` 只给端到端门禁（B-02/B-03），无函数级 self time，无法成立热点结论，相关猜测进"待验证假设" |
| §6.2 大粒度锁 | 0 | 本部分无锁：`SessionActionContext` 无同步块，`Activation.seq` 用 `AtomicInt64` 而非互斥锁 |
| §6.3 并发串行 | 0 | 本部分无 `spawn`、无 Future、无线程池提交；动作是 `for (action in activation.rule.actions)` 的串行调用（语义要求有序，属正确设计） |
| §6.4 低效算法 | 0 | `SessionActionContext` 各方法 O(k)（k=绑定数）；`facts()` 回退是两次哈希查找而非嵌套循环；`specificityOf` 的重复遍历计入优化方案而非缺陷（无耗时数据） |
| §7 降堆内存方案 | 0 | 本部分对象生命周期都短于一次 `fire`，没有可缩短的长期持有、没有全量副本；唯一可减的 `key_` 串已由第 1 部分作为 CPU/内存方案提出，不重复 |
| §8 降 CPU 方案 | 1 | `specificity` 预计算（见"优化可行性方案"），标 `无基线（待验证）` |
| §9 local mode 可行性 | 0 | 本部分函数内没有大临时对象（最大的是 `outputs` 一个 `HashMap`，元素数=输出槽数），也没有大数组解析中间结构；无逃逸分析对象可标注，收益无法用峰值内存证明，不写方案 |
| §11 现有代码的 BUG（存量） | 4 | 本轮读到的 4 个源文件逐函数核对边界/空值/错误处理/状态对称：#1（传播原子性）、#2（陈旧事实）、#4（键碰撞）、#5（跨空间静默）为代码缺陷；#3、#8 为注释/规格与实现不符，按 §13 归类 |
| §12 并发安全与锁粒度 | 0 | 本部分无线程共享路径：`SessionActionContext` 每个激活新建、`outputs` 为局部 map（`RuleSession.cj:68-76`）；`Activation` 构造后只读，`seq` 用原子计数。会话级的线程安全承诺问题（`RuleEngine`/`FactBase`）已由第 2 部分报出 |
| §14 功能完备性与 README 覆盖 | 0 | 本部分 spec 的承诺项逐条落到实现：错误码 27、`RuleInitializer` 名称/依赖、B-01~B-07 门禁用例与 `doc/perf.md` 实测值、`.modules` 含 `f_rule`、`CHANGELOG` 存在，均成立；README 本身不在本部分文件清单（第 1 部分已审） |
| 文件覆盖（§13 等） | 20/20 | 无缺失；7 个 `.md` 全部按 §13 与实现双侧取证（见文件覆盖表"说明"列） |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 3 |
| 轻微 | 10 |
| 优化方案（堆内存 / CPU） | 0 / 1 |

存量 13 条（一般 3 + 轻微 10），是否纳入修复待用户决定。

## 总评

本部分代码的整体质量良好：`Activation` 的身份/排序契约（`(factSpace, ruleId, bindings)` 判等、`seq` 原子分发、`specificity` 定义）与 `f-rule-agenda` spec、`Agenda` 的冲突消解链、差分基准三方对得上；`SessionActionContext` 的分层（接口在 `rule`、实现在 `agenda`）解决了包循环，不是绕过去的权宜之计；死代码与空实现基本为零（唯一的 `NoopPropagation` 是有注释的 Null Object），4 个源文件里没有递归、没有无界容器、没有锁。

真正的风险集中在动作路径的一致性：`assert`/`retract`/`update` 把"改事实库"和"推 Rete 网络"拆成两次不可回滚的副作用（#1），而 `fact(binding)` 在事实已被撤销时又回退到激活时快照（#2）——这两条叠加，可以让一个动作读到已撤销的事实、或让一条事实永远进不了网络，且都不会有任何日志。它们不是阻塞级（需要传播抛错或"先撤销后读取"的动作写法才触发），但一旦触发就是静默的结果错误，建议排期修掉并补用例。规格层面（#3、#9、#10、#11）的问题是另一种味道：`doc/spec/specs/**` 已经部分退化为"事后描述"，同一条要求里出现自相矛盾的表述，用户可见的展开行为（同类型 `Or`、64 条上限）和配置面（循环检测阈值）没有进契约——这类问题不影响运行，但会让下一轮审查和下游使用者反复踩坑，建议随下一次文档对齐一并处理。

其余（#4~#8、#12、#13）都是低风险项：一个构造 ID 才能触发的键碰撞、几处静默无操作、两处测试断言/注释与实现不符、两处模块内小重复，可以批量清理。本部分无严重项，也没有可量化的性能结论；唯一的 CPU 优化（`specificity` 预计算）必须补基线后才能进任务清单。
