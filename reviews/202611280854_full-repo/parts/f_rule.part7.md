# f_rule 模块审查报告（模块第 7/12 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_rule`（本部分 20 个源文件：`.cj` 20 个 / `.md` 0 个；模块整体 184 个 `.cj` + 33 个 `.md`）
- **基线**：工作区快照（sts/1.3.x，无 diff 可比，全部问题记「存量」）
- **审查重点**：规则引擎求值正确性、递归与栈溢出、OOM、死代码、重复逻辑、并发安全、存量 BUG
- **报告版本**：v1（模块第 7/12 部分，仅覆盖 `files/f_rule.part7.txt` 列出的文件：`flow/` 包 19 个 + `rete/AlphaMemory.cj`；不产出 `docs/review/` 模块报告）
- **与同模块其他部分的关系**：第 1/2 部分已就 `JoinTask` 的「完成 vs 超时」交错竞态、`FlowContext`/`RuleEngine` 会话无界增长、`doc/06 §8` 错误路径报过同根因问题；本部分不重复计数，只在正文标注「同根因，见第 N 部分」，仅保留它们未覆盖的路径（轮次复用、半到达状态、编排门面接线）。

## 发现

### [严重][存量] 超时定时任务只带 session，不带轮次：上一轮的残留定时器会清掉同一 session 的下一轮状态

- **位置**：`f_rule/src/flow/JoinTask.cj:249`（`scheduleTimeout` 注册 `{ => expire(session) }`）、`:263`-`:299`（`expire` 先无条件 `states_.remove(session)`）；对照 `:223`-`:234`（到齐只 `arrived.clear()` + `states_.remove`，不取消定时器）、`:28`-`:31`（`JoinTimeoutScheduler` 只有 `schedule`，没有 cancel）
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §11（语义与注释不符 / 状态机错误）、§12.1（生命周期竞态）；`f_rule/doc/06-flow-orchestration.md:262`-`:268` 承诺「到齐后立即清态，允许同一 session 发起下一轮」
- **证据**：静态确定 —— 定时回调的唯一参数是 `session: String`（`JoinTask.cj:252`），`expire` 收到后直接 `states_.remove(session)`（`:264`）并按默认 `ErrorEvent` 或 `timeoutEvent` 发事件（`:279`-`:296`）。`exec` 到齐时没有取消已注册的定时任务（`JoinTimeoutScheduler` 接口也没有取消能力），`JoinTimeoutTickTask` 是 `once` 任务，只会在触发时才从 `f_ticktock` 摘除。
- **描述**：触发条件是「配置了 `timeout` + 第一轮在超时前到齐 + 同一 session 在超时到期前开始第二轮」：第一轮留下的定时器到期时，`states_[session]` 已是第二轮的**新** `JoinBranchState`，`expire` 会把它整体移除并发出 `timeoutEvent`/`ErrorEvent`。后果：第二轮已到达的分支被丢弃，剩余分支只能从零累积（多数情况永久卡住），而业务还收到一条误报超时。`JoinTimeout_test.cj:136`-`:147` 只验证「到齐后 fire 不重复发事件」，且 `FakeTimeoutScheduler`（`:28`）只保存**最后一个** action，天然掩盖了多轮多定时器的场景。
- **建议**：定时回调携带 `generation`（每次 `JoinBranchState` 创建时自增或携带实例引用），`expire` 只在「`states_.get(session)` 仍是同一实例且代数匹配」时生效；或在 state 上加 `deadline`，由 `exec` 在锁内判断过期、定时器只做「唤醒检查」。补用例：第一轮 `a+b` 完成后、定时器 fire 前再 `exec(session, "a")`，断言第二轮状态不被清、且不产生 timeout 事件。

### [一般][存量] 半到达的 Join 状态没有淘汰路径，编排门面构造的 `JoinTask` 永远不会超时

- **位置**：`f_rule/src/flow/JoinTask.cj:136`（`states_`）、`:162`-`:172`（`timeout == None` 直接关闭超时）、`:210`-`:233`（只有到齐才 `remove`）；`f_rule/src/flow/RuleSetFlow.cj:117`-`:121`（构造 `JoinTask` 时不传 `timeout`）
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §5（无界容器：键是会话 id，无容量 / TTL / 淘汰）、§14.1（接线缺失）
- **证据**：静态确定 —— `RuleSetFlow.join` 只传 `name`/`branches`/`output`，`timeout` 保持缺省 `None` → `timeoutEnabled_` 为 false → `scheduleTimeout` 不会调用 → `expire` 永不执行；`exec` 只有 `arrived.size == branchSet_.size` 才 `states_.remove`（`:223`-`:234`），没有任何按时间或容量的清理入口。
- **描述**：任一条分支失败、被上层吞掉、或流程中途 `End`（残留分支即 `FlowSessionRegression_test.cj:42`-`:78` 记录的行为）时，该 session 的 `JoinBranchState` 永久留在 map 中。单个 state 约一个 `Mutex` + 一个 `HashSet` + 4 个空 `String` 引用，按 1e6 个卡住会话粗估约 200–300 MB（**未实测**，进「待验证假设」）。同时 `size()`（`:201`-`:203`）把「活跃」和「泄漏」混在一起，排障时无法区分。
- **建议**：给 `JoinTask` 一个默认 TTL（构造参数或模块常量），到期清态并记 WARN；`RuleSetFlow.join` 暴露 `timeout` 并强制要求；再提供 `purgeExpired(now)` / `purge(session)` 供宿主定时调用。若坚持「超时可选」，至少要在 `states_.size` 上暴露指标并在文档写明「无超时的 Join 状态不回收」。

### [一般][存量] `timeoutSink` 缺省时超时事件被静默丢弃，`RuleSetFlow` 也没有接上注释承诺的 `flow.emit`

- **位置**：`f_rule/src/flow/JoinTask.cj:145`（注释「`timeoutSink` 由 `RuleSetFlow` 接到 `flow.emit`」）、`:295`-`:298`（`case None => ()`）；`f_rule/src/flow/RuleSetFlow.cj:108`-`:124`（`join` 无 timeout/sink 参数）
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §3（`case None => ()` 当兜底把结果吃掉）、§14.1（承诺了但没实现）
- **证据**：静态确定 —— `expire` 已经构造好 `TaskEvent`/`ErrorEvent`（`:279`-`:294`），但 `timeoutSink_` 为 `None` 时既不发送、不记录、不计数；`RuleSetFlow.join` 构造 `JoinTask` 时既不给 `timeout`，也不给 `timeoutSink`，全模块检索 `timeoutSink` 只有 `JoinTask.cj` 自身与测试命中。
- **描述**：公开 API 允许 `timeout: Some(...)` 而不传 sink（构造期无校验），到期后状态被清空、事件消失，调用方只看到流程停住；按注释以为「RuleSetFlow 会接」，实际编排门面根本没有这条路径，超时能力在门面层不可达。
- **建议**：构造期校验「有 `timeout` 必须有 `timeoutSink`，否则抛 `ILLEGAL_STATE`」；`RuleSetFlow.join` 增加 `timeout`/`timeoutEvent` 参数并把 sink 接到 `flow_.emit`；确实允许无 sink 时至少 `WARN` 一次并计数。

### [一般][存量] `RuleSetFlow.end()` 没做它承诺的逐边可达性校验，只判断「有没有 Join」

- **位置**：`f_rule/src/flow/RuleSetFlow.cj:126`-`:140`（`end`，尤其 `:129`-`:137`）；对照同类注释 `:28`-`:30`、「校验扇出可达性」`:126`、`f_rule/doc/06-flow-orchestration.md:183`
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §14.1（承诺了但没实现）、§13（文档与实现相反）
- **证据**：静态确定 —— 全仓检索 `Reachability.validate(`，命中仅 `Reachability_test.cj:44`/`:53`/`:72`；`RuleSetFlow` 只调用 `Reachability.validateJoinBranches`（`:115`）。`end()` 的唯一检查是 `productions_.size > 0 && joinGroups_.size == 0`（`:129`-`:134`），注释 `:135`-`:136` 自己承认「逐边的可达性由 `Reachability.validate` 在显式拓扑场景使用」。
- **描述**：只要建过任意一个 `JoinTask`，即使某条扇出分支仍有直达 `End` 的路径（doc §3.4 明令禁止的形态），`end()` 也放行。这正是 `FlowSessionRegression_test.cj:42`-`:78` 锁定的「残留分支被下一轮 `start()` 消费」故障的上游原因——构建期没拦住，运行期就会串轮。另外 `end()` 也不校验 join 的 branches 是否真由 `fanout` 产出、join 输出是否被下游消费，编排写错只能等到运行期卡住。
- **建议**：在 `end()` 用 `productions_` + 已登记任务边构造 `edges`，调用 `Reachability.validate(productions_, edges, EventType.End.toString())`；若当前 `ImmediateFlow` 拿不到中间边，则删掉类注释与 doc 里的「逐边可达性」承诺，并在 README 写明「只保证存在 Join，不保证分支都汇入」。

### [一般][存量] `RuleTask.defaultFactory` 把非 `Fact` 载荷静默降级为空事实集，`JoinTask` 的 `"joined"` 载荷正好命中

- **位置**：`f_rule/src/flow/RuleTask.cj:93`-`:98`（`defaultFactory` 返回空数组）、`:77`-`:90`（继续 `session.fire()` 并输出）；配合 `f_rule/src/flow/JoinTask.cj:239`-`:244`（输出载荷固定 `"joined"`）
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §3（`case None => ()` 兜底把错误吃掉）、§11（错误处理缺失）
- **证据**：静态确定 —— payload 不是 `Fact` 时返回 `Array<(String, Fact)>()`，`exec` 不做任何检查，直接 `session.fire()` 并把空 `outputs` 包成下一事件；不抛错、不告警。`JoinTask` 的输出事件 `data` 是 `RuleEnvelope(payload: "joined")`，因此「Join → RuleTask（默认 factory）」这条最自然的编排会走到空事实路径。
- **描述**：编排里少写一个 `factory` 时，规则一条都不触发、下游拿到空输出，且没有任何诊断信息；排查时只能靠对比 `size()`。这是「看起来能跑」的静默失效，比抛错更难定位。
- **建议**：`defaultFactory` 对非 `Fact` 载荷抛 `RuleException(TYPE_MISMATCH, ...)`（或返回 `Result` 由 `exec` 决定），至少 `WARN` 一次并带上 `traceId`；同时在 `JoinTask` 文档里写明 `"joined"` 只是占位，下游必须自定义 factory。

### [一般][存量] `JoinTask` 未校验 `branches` 重复，单个分支即可触发汇合

- **位置**：`f_rule/src/flow/JoinTask.cj:147`-`:153`（构造，`branchSet_` 去重）、`:223`（以去重后的 `branchSet_.size` 判完成）
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §11（缺少边界校验 / 语义与命名不符）
- **证据**：静态确定 —— `branches: ["a", "a"]` 时 `branchSet_.size == 1`，`arrived` 收到一次 `a` 就满足 `arrived.size == branchSet_.size`，直接发出 output；`Reachability.validateJoinBranches`（`:56`-`:69`）只查跨组的重叠，不查组内重复。
- **描述**：配置写重（复制粘贴、动态拼 branches）时汇合提前触发，下游在缺一路数据的情况下继续执行，属于静默的业务错误。
- **建议**：构造期校验 `branches` 非空、无重复（`branchSet_.size == branches.size`），不满足抛 `ILLEGAL_STATE`。

### [一般][存量] `AlphaMemory` 的索引维护没有同步手段，`sharedEmpty` 还是可被调用方改写的静态单例

- **位置**：`f_rule/src/rete/AlphaMemory.cj:35`（`private static let sharedEmpty = ArrayList<FactHandle>()`）、`:38`-`:44`（`HashMap`/`ArrayList` 字段）、`:57`-`:103`（`add`/`remove`）、`:235`-`:261`（`ensureEqIndex`/`ensureOrdIndex` 的 contains→put）、`:133`-`:139`（`probeList` 返回内部列表或 `sharedEmpty`）
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §12.1（共享可变状态无保护 / 惰性初始化）、§11（契约与实现不符）
- **证据**：**待确认**（同根因已在第 2 部分「线程安全契约不成立」报过，此处只补本文件的具体路径）—— 共享路径是 `RuleSession → SessionNetwork.alphaMemory(nodeId)`（`SessionNetwork.cj:68`-`:77`，每个 session 一份、惰性创建）→ `AlphaNode.propagate` 的 `memory.add`（`AlphaNode.cj:111`-`:113`）与 `BetaNode` 的 `probeList`/`orderedList`；`doc/06:267` 明确「`exec` 可能在不同线程被调用（`AsyncFlow`）」，若同一 session 的两条分支被并发执行，`HashMap` 插入与桶内 `ArrayList.add`、`ensureEqIndex` 的检查-然后-写入都会竞争。另：`probeList` 空桶返回的是**静态** `sharedEmpty`，任何调用方对返回值做 `add`/`remove` 都会污染全进程所有 alpha memory（当前调用点 `BetaNode.cj:210`/`:230`/`:236`/`:262`/`:296`/`:302` 都是只读遍历或直接返回给只读遍历，属潜在雷）。
- **描述**：轻则索引桶与 `facts_` 不一致（漏匹配 / 重复候选），重则 `HashMap` 结构损坏；`sharedEmpty` 一旦被改写，空桶探测会返回别的事实句柄，造成跨会话串数据。
- **建议**：二选一并落到文档：① 明确「`ReteSession` 线程封闭、同一 session 只允许串行执行」，在 `RuleSession`/`SessionNetwork` 上加断言；② 若要支持并发，`alphaMems_`/`betaMems_` 换 `ConcurrentHashMap`（`computeIfAbsent`），`AlphaMemory` 内部按字段分桶加锁，`probeList` 改为返回只读快照或接受 `(FactHandle) -> Unit` 回调（同时消除 `sharedEmpty` 逸出）。

### [轻微][存量] `AlphaMemory.nullSet_` 从未写入，配套的空值索引恒为空

- **位置**：`f_rule/src/rete/AlphaMemory.cj:44`/`:53`（字段与初始化）、`:70`-`:72`、`:99`-`:101`（两处维护循环）、`:333`-`:338`（`indexNull`）
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §1（无调用者 / 死字段）
- **证据**：静态确定 —— 全仓检索 `nullSet_` 只有这三处读写，没有任何 `nullSet_[field] = ...`；因此 `indexNull` 永远不会被有效执行，`add`/`remove` 里两个 `for` 循环恒空转，字段本身也不会被填充。
- **描述**：看起来实现了「字段缺失（null）索引」，实际完全没有建立入口也没有查询路径（`select` 的缺失字段仍走全扫）；后续维护者容易误以为空值走的是索引。若原本打算支持 `IsNull` 类算子，这是未接线的半成品。
- **建议**：要么补上建立/查询入口（`ensureNullIndex` + `select` 分支 + 测试），要么删除字段、两处循环与 `indexNull`。

### [轻微][存量] 重复逻辑：镜像的范围探测与索引构建，测试辅助三份逐字拷贝

- **位置**：`f_rule/src/rete/AlphaMemory.cj:194`-`:207`（`orderedTail`）与 `:209`-`:222`（`orderedHeader`，仅方向与边界不同）、`:235`-`:247`（`ensureEqIndex`）与 `:249`-`:261`（`ensureOrdIndex`，仅容器类型不同）；`f_rule/src/flow/FlowContext_test.cj:54`-`:62`、`Reachability_test.cj:30`-`:38`、`SameSpaceFanout_test.cj:64`-`:72`（三个逐字相同的 `codeOf`）
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §2（只改类型名 / 换控制流的同语义实现）
- **证据**：静态确定 —— tail/header 的差异只有 `RangeKey(value, Min|Max)`、`tailer`/`header` 与 `including` 的传递；两个 `ensure*` 的差异只有容器类型与 `indexEq`/`indexOrd` 的选择；三份 `codeOf` 文本一致（只有初始枚举值同为 `CLOSED`）。
- **描述**：镜像实现对改一处漏一处很敏感（例如给 tail 加「跳过 tombstone」时 header 容易漏）；测试辅助三份拷贝会让「错误码比较」的约定漂移。`ensure*` 因 `HashMap` 与 `ConcurrentSkipListMap` 无公共索引接口，硬合并会引入额外抽象，可保留双份但抽出「遍历 `order_` 建索引」的公共骨架。
- **建议**：`orderedTail`/`orderedHeader` 合并为 `orderedBound(field, value, including, fromHead: Bool)`；`codeOf` 收敛到模块内测试辅助（如 `flow/testing.cj` 或 `test/` 下的共享文件）。

### [轻微][存量] 未使用的 import

- **位置**：`f_rule/src/flow/JoinTask.cj:21`-`:22`（`fountain::f_base.*`、`fountain::f_collection.*`）、`f_rule/src/flow/FlowSessionRegression_test.cj:21`（`Event`）、`f_rule/src/flow/ResolveTask_test.cj:21`（`DataEvent`）
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §1（未使用的 `import`）
- **证据**：静态确定（两个测试文件）—— 逐文件检索 `Event` / `DataEvent`，除 import 行外无引用；**待确认**（`JoinTask` 的两条通配符）—— 文件内检索不到明显来自 `f_base` / `f_collection` 的符号（`LoggerFactory` 来自 `:24`），需 `cjlint` 复核通配符是否有隐式命中。
- **建议**：删掉两个测试文件的单个符号；`JoinTask` 的通配符改为按需导入，交给 `cjlint` 收口。

### [轻微][存量] `acceptableEvents` 直接返回内部数组，调用方可以改到任务内部状态

- **位置**：`f_rule/src/flow/JoinTask.cj:181`-`:185`；同模式见 `f_rule/src/flow/ResolveTask.cj:57`-`:61`、`f_rule/src/flow/RuleTask.cj:59`-`:63`
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §10（引用语义 / 封装）、§12.1（发布逸出）
- **证据**：静态确定 —— 返回的是 `branches_` / `acceptable_` 本体，调用方 `add`/下标赋值会改掉任务内部数组；`JoinTask` 的 `branchSet_` 在构造时已固定，二者从此不一致：`acceptableEvents` 声称接受的事件与实际接受集合分离，排查时会被误导。
- **建议**：返回 `branches_.clone()`（或标准库只读视图）；若 `f_egraph` 的热路径依赖零拷贝，至少在注释里写明「调用方不得修改」并加测试。

### [轻微][存量] `findRule` 丢掉 `ruleSetId` 前缀，`join` 任务命名也不符文档约定

- **位置**：`f_rule/src/flow/RuleSetFlow.cj:160`-`:165`（只取最后一个 `/` 之后的 `ruleId`）、`:117`-`:118`（`"join-${joinGroups_.size}"`）；对照 `f_rule/doc/06-flow-orchestration.md:274`（`"<ruleSetId>/join/<joinId>"`，`joinId` 由编排代码显式指定）
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §11（语义与命名不符 / 校验不足）、§13（与文档约定不符）
- **证据**：静态确定 —— `fanout` 的 `ruleCategory` 允许 `"other/R1"`，`findRule` 会拿本规则集的 `R1` 通过校验，事实空间校验因此作用在错误的规则上；`join` 名字是自增序号，没有参数可以指定 `joinId`，文档里的命名规范无法实现。
- **描述**：跨规则集误传时构建期不报错，等到运行期分支根本不会到达（事件名对不上）才暴露；`join-N` 也让文档里的「按 joinId 排障 / 定位」失效。
- **建议**：`findRule` 校验前缀等于 `engine_.ruleSet.id`（不匹配抛 `ILLEGAL_STATE`）；`join` 增加可选 `joinId: String = ""`，缺省时按文档格式生成 `"${ruleSet.id}/join/${n}"`。

## 优化可行性方案

> 不是缺陷，是「还能更好」。本部分没有改前基线，以下两条均按「待验证假设」处理，不进 `todo.md` / `tasks.md`。

### [堆内存] `AlphaMemory` 同一事实在 5 个容器里各存一份，索引长期驻留

- **现状**：每个事实同时出现在 `facts_`（handle→Fact）、`order_`（ArrayList）、`slots_`（handle→槽位）、每个已索引字段的 `eqIndex_` 桶（`ArrayList<FactHandle>`）或 `ordIndex_` 跳表节点；索引一旦建立（`ensureEqIndex`/`ensureOrdIndex`）永不删除，即使该字段之后不再被 join 引用。字段数 × 事实数就是常驻放大系数（具体字节量未测）。
- **方案**：① 桶内只存 `order_` 槽位（`Int64`）而不是 `FactHandle` 引用，探测时再 `order_[slot]` 取句柄；② 给索引加引用计数（网络构建期统计每个字段被多少 join 使用），归零时按需释放；③ `slots_` 与 `order_` 可合并为「句柄 → 槽位」单一结构。
- **预期**：索引内存随字段数线性下降（比例待测），减少一层句柄对象的引用开销；语义不变（探测结果需逐条重算 `holdsWith`，超集安全）。
- **代价**：探测多一次数组寻址；释放索引需要「重建」逻辑，重建期间不能有并发写（与当前线程模型一致）。
- **验证**：同规则集、同事实量（如 10 万事实 × 3 个 join 字段）下对比 `getAllocatedHeapSize()`、RSS 与 `cjpm bench -O2` 的探测耗时。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `AlphaMemory` 探测路径每次复制结果，`BetaNode` 再复制一层

- **现状**：`probe`（`:124`-`:130`）复制桶、`select`（`:166`-`:188`）复制全扫结果、`BetaNode.asList`（`BetaNode.cj:240`-`:246`）再把数组复制成 `ArrayList`；范围 join 每次激活都要走这条链。`BetaNode` 的等值路径已改用 `probeList`（零拷贝），范围路径仍是三层复制。
- **方案**：为范围探测提供 `forEachCandidate(field, op, key) { handle => ... }` 回调式接口（或返回 `Iterable` 视图），让 `BetaNode` 直接在迭代里做 `holdsWith`；只读约束写进签名注释。
- **预期**：每次 join 探测少 1–2 次 O(k) 复制与相应分配（k=候选数），GC 压力下降；端到端收益取决于候选规模，未测。
- **代价**：回调接口会让调用点略复杂；若调用方需要保留候选集（如去重）仍要复制。
- **验证**：`cjprof record` 对比 `AlphaMemory.select`/`BetaNode.asList` 的自耗时与分配次数；`cjpm bench -O2` 同输入（1 万事实、范围 join 命中率 10%）。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 未完成 Join 状态的真实增速会导致 RSS 持续上涨 | `f_rule/src/flow/JoinTask.cj:136` | 每会话 state 字节数、失败会话占比 | 长跑压测（10 万请求，其中 10% 分支丢失），每 1 分钟采 `getAllocatedHeapSize()` 与 RSS，观察是否线性 |
| 2 | `AlphaMemory` 范围探测的复制是 join 热点的一部分 | `f_rule/src/rete/AlphaMemory.cj:166`-`:233` | `select`/`asList` 自耗时占比、单次分配量 | `cjprof record` 跑 1 万事实 × 1 万次范围 join，取 self time 与分配火焰图 |
| 3 | `Reachability.visit` 用 `remove(at: 0)` 做 BFS 队列，在大拓扑下 O(V²) | `f_rule/src/flow/Reachability.cj:77` | 构建期图规模与耗时 | 构造 1k/10k 节点 DAG，分段计时 `validate`；对照 `ArrayDeque`/索引游标实现 |
| 4 | 每条事件新建 `RuleEnvelope`/`TaskEvent`/`HashMap` 的分配量可观 | `f_rule/src/flow/RuleTask.cj:71`-`:90` | 每事件分配字节、GC 次数 | `cjprof heap` 稳态跑 10 分钟，读分配速率；再对比复用输出 map（注意语义：每次 fire 必须新 map） |

## 范围外提示（不计入统计）

- `f_rule/src/engine/RuleEngine.cj:75`-`:84`：`sessions_` 用普通 `HashMap`、`session()` 是检查-然后-写入，`RuleTask.cj:76` 是唯一生产调用点（第 1/2 部分已就线程安全契约报过，归 engine 子轮处理）。
- `f_rule/src/flow/FlowContext.cj:67`/`:142`：静态 `contexts` 只增不减，`RuleTask.cj:73` 是唯一生产触发点（第 1/2 部分已报，本部分不重复计数）。
- `f_rule/doc/06-flow-orchestration.md:230`-`:238`、`:320`、`:529`：签名与 exec 契约落后于实现（归 doc 子轮）。

## 文件覆盖

> 与 `{workdir}/files/f_rule.part7.txt` 一一对应（20 行，全部读完）。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_rule/src/flow/FlowContext_test.cj` | .cj | ✅ | ThreadLocal/视图/release 契约测试；`codeOf` 三份副本之一 |
| 2 | `f_rule/src/flow/FlowSessionRegression_test.cj` | .cj | ✅ | 锁定「残留分支下次 start 重放」；存在未使用 import `Event` |
| 3 | `f_rule/src/flow/JoinTask.cj` | .cj | ✅ | 见发现 #1/#2/#3/#6/#11；`branchSet_` 去重与轮次问题 |
| 4 | `f_rule/src/flow/JoinTask_test.cj` | .cj | ✅ | 覆盖单轮幂等/隔离/下一轮，未覆盖跨轮定时器 |
| 5 | `f_rule/src/flow/JoinTimeout_test.cj` | .cj | ✅ | 假调度器只存一个 action，掩盖多定时器场景（#1） |
| 6 | `f_rule/src/flow/Reachability.cj` | .cj | ✅ | BFS 可达性；`validate` 无生产调用者（#4），`remove(at: 0)` 进待验证假设 |
| 7 | `f_rule/src/flow/Reachability_test.cj` | .cj | ✅ | 3 个可达性用例 + 1 个合法编排；`codeOf` 副本 |
| 8 | `f_rule/src/flow/ResolveTask.cj` | .cj | ✅ | 扇出实现；`acceptableEvents` 返回内部数组（#11） |
| 9 | `f_rule/src/flow/ResolveTask_test.cj` | .cj | ✅ | 覆盖空产出/异常包装/同空间顺序；未使用 import `DataEvent` |
| 10 | `f_rule/src/flow/RuleEnvelope.cj` | .cj | ✅ | 不可变信封，session 透传正确；无问题 |
| 11 | `f_rule/src/flow/RuleEnvelope_test.cj` | .cj | ✅ | 信封优先级与回退路径均有覆盖 |
| 12 | `f_rule/src/flow/RuleFlow.cj` | .cj | ✅ | 单规则外壳，仅透传；无问题 |
| 13 | `f_rule/src/flow/RuleFlow_test.cj` | .cj | ✅ | 命名/嵌入/独立启动 |
| 14 | `f_rule/src/flow/RuleSetFlow.cj` | .cj | ✅ | 见发现 #2/#3/#4/#12；`join` 未接 timeout，`end` 未做可达性 |
| 15 | `f_rule/src/flow/RuleTask.cj` | .cj | ✅ | 见发现 #5；会话释放问题归第 1/2 部分 |
| 16 | `f_rule/src/flow/RuleTask_test.cj` | .cj | ✅ | 议程执行/未知空间回滚/流程内执行 |
| 17 | `f_rule/src/flow/SameSpaceFanout_test.cj` | .cj | ✅ | 同空间拒绝、无 Join 拒绝；`codeOf` 副本 |
| 18 | `f_rule/src/flow/VersionSwitch_test.cj` | .cj | ✅ | tag 替换与依赖保护；无问题 |
| 19 | `f_rule/src/flow/flow.cj` | .cj | ✅ | 仅包级文档注释，含 M0 说明；无代码 |
| 20 | `f_rule/src/rete/AlphaMemory.cj` | .cj | ✅ | 见发现 #7/#8/#9；nullSet_ 死字段、镜像索引实现 |

合计：`.cj` 20 个 / `.md` 0 个 / 共 20 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 7 | 正确性：#1/#2/#4/#5/#6；语言特性：#11（数组逸出）；设计：#3（门面接线）；安全性：本部分不处理外部输入，无注入/凭据面（`Reachability`/`RuleSetFlow` 只吃构建期常量） |
| §1 死代码 | 3 | `AlphaMemory.nullSet_` + `indexNull`（#8）；未使用 import（#10）；逐个 private/internal 符号（`TicktockJoinScheduler`、`JoinTimeoutTickTask`、`JoinBranchState`、`visit`、`defaultFactory`、`sharedEmpty`）已在全仓搜引用，均有调用者；`protected` 0 个；对外可达的 public（`JoinTask.size`/`timeoutEnabled`、`Reachability.validate`、`RuleFlow.ruleId` 等）按硬原则一不判，仅记录「`Reachability.validate` 仓内仅测试引用」 |
| §2 重复逻辑 | 1 | #9：tail/header、ensureEqIndex/ensureOrdIndex 为镜像实现；三份 `codeOf` 逐字相同；`ResolveTask_test` 的 `event`/`children` 与 `JoinTask_test` 的 `event` 语义不同（category/默认 session 不一致），不判重复 |
| §3 空实现 | 2 | #3（`timeoutSink` 为 None 时 `case None => ()` 丢弃事件）；#5（非 Fact 载荷静默变空事实集）；`RuleFlow` 的转发任务是有意的最小外壳，注释已说明，不判 |
| §4 栈溢出 | 0 | 本部分无递归：`Reachability.visit` 是显式队列 BFS（无递归）、`AlphaMemory` 全部为循环、`JoinTask`/`ResolveTask`/`RuleTask` 无自调用；`AlphaNode.propagate` 的链式递归不在本部分文件内 |
| §5 OOM | 2 | #2（`states_` 无淘汰，可达 N 个卡住会话）；`AlphaMemory` 索引随事实数线性增长但受会话生命周期约束，已归「优化方案」；`FlowContext` 无界增长归第 1/2 部分，不重复计数 |
| §6.1 热点瓶颈 | 0 | 无 profile / bench 数据；`AlphaMemory` 探测与 `RuleTask` 分配只作待验证假设 #2/#4，未写成缺陷 |
| §6.2 大粒度锁 | 0 | `JoinTask` 的临界区只有 HashSet add/clear 与 4 个字段赋值（`JoinTask.cj:213`-`:227`），无 I/O、无回调；`expire` 的 `sink(event)` 在锁外（`:295`-`:298`） |
| §6.3 并发串行 | 0 | 本部分无 `spawn`/`Future.get`；`TicktockJoinScheduler.schedule` 只是登记任务 |
| §6.4 低效算法 | 0 | `Reachability.visit` 的 `remove(at: 0)` 是构建期小图（flow 拓扑），未达「热点」门槛，放待验证假设 #3；`AlphaMemory` 全扫回退是语义兜底，见待验证假设 #2 |
| §7 降堆内存方案 | 1 | 「AlphaMemory 5 份表示 + 索引永不释放」，无基线，标待验证 |
| §8 降 CPU 方案 | 1 | 「探测路径三层复制」，无基线，标待验证 |
| §9 local mode 可行性 | 0 | 本部分临时对象（`RuleEnvelope`/`TaskEvent`/`MultiEvent`/探测结果）都会逃逸到事件队列或返回值，不满足 local region 的逃逸约束；`AlphaMemory` 索引对象生命周期跨会话；无峰值内存数据，不列为方案 |
| §11 现有代码的 BUG（存量） | 6 | #1 轮次复用、#2 半到达状态、#5 非 Fact 载荷、#6 重复分支、#11 数组逸出、#12 ruleId 前缀；已核对 `exec` 的空分支/重复分支/未知分支三条边界与 `expire` 的空 map 分支 |
| §12 并发安全与锁粒度 | 2 | #1（定时器与轮次的共享状态）、#7（AlphaMemory 索引无同步；同根因见第 2 部分）；`JoinTask` 的 exec/expire 交错竞态已在第 2 部分立为严重，本部分不重复 |
| §14 功能完备性与 README 覆盖 | 3 | #3（超时接线缺失）、#4（可达性校验缺失）、#2（无超时导致状态不回收）；本部分不含 README，公开 API 未文档化问题归 doc 子轮 |
| 文件覆盖（§13 等） | 20/20 | 无缺文件；本部分无 `.md`，文档一致性只在判据里引用 `doc/06` 行号 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 1 |
| 一般 | 6 |
| 轻微 | 5 |
| 优化方案（堆内存 / CPU） | 1 / 1 |

存量缺陷共 12 条（严重 1、一般 6、轻微 5），是否纳入修复待用户决定。

## 总评

本部分代码的骨架是清晰的：`RuleEnvelope` 用不可变信封解决 `f_egraph` 随机 session 的问题，`ResolveTask`/`JoinTask`/`RuleTask` 职责边界干净，构建期校验（`validateJoinBranches`、同空间扇出拒绝）方向正确，测试覆盖了幂等、会话隔离与残留分支重放这些容易踩的点。

真正阻塞的是 **JoinTask 的状态机生命周期**：定时器只带 session 不带轮次（发现 #1，单线程即可复现），加上 `RuleSetFlow.join` 不传 timeout 导致半到达状态永不回收（发现 #2），两者叠加会让「允许同一 session 发起下一轮」这条文档承诺在实际编排中不成立。第 2 部分已报的 exec/expire 交错竞态是同一处状态的并发面，合并报告时建议把 #1 与它放在同一节，按「定时器身份 + 状态原子迁移」一次性改完。

其次是 **编排门面的接线缺口**（发现 #3/#4）：`JoinTask` 注释承诺的超时出口没有接、`end()` 承诺的逐边可达性没有做，导致「能通过构建期校验的流程」比文档承诺的宽松，残留分支问题只能在运行期暴露。这两条修起来都不大（接 `timeoutSink` 到 `flow.emit`、`end()` 调一次 `Reachability.validate`），但需要决定是补实现还是改文档，不能继续两边不一致。

`AlphaMemory` 本身没有本部分级别的正确性缺陷，问题集中在「索引维护无同步 + 一份事实五份表示」；前者与第 2 部分的线程安全契约同根因，后者只有优化价值、缺基线数据。`nullSet_` 死字段和镜像实现属于清理项，可随下一次改动顺手处理。
