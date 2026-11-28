# f_rule 模块审查报告

> **模块第 5/12 部分**：只覆盖 `files/f_rule.part5.txt` 列出的 20 个 `.cj`（`src/condition/**` 的 10 个、`src/engine/**` 的 9 个、`src/exception/RuleErrorCode.cj`），本部分没有 `.md`。`ConditionExpr` / `Interpreter` / `JitExpression` / `rete/**` / `agenda/**` / `rule/**` / `table/**` 由其他部分产出，本报告只在追调用链时引用它们，不对其单独下结论。

- **审查日期**：2026-11-28
- **模块路径**：`f_rule`（本部分 20 个源文件：20 `.cj` + 0 `.md`；模块整体 184 `.cj` + 33 `.md`）
- **基线**：工作区快照（sts/1.3.x，无 diff 可比 ⇒ 全部记「存量」）
- **审查重点**：规则引擎求值正确性、递归与栈溢出、OOM、死代码、重复逻辑、并发安全、存量 BUG
- **报告版本**：v1（第 5/12 部分）

## 发现

### [严重][存量] `RuleEngine` 文档承诺线程安全，但会话表与关闭标志零同步；`RuleSession` 内部状态同样无锁

- **位置**：`f_rule/src/engine/RuleEngine.cj:35-38`（`sessions_` 为普通 `HashMap`、只有 `tableExecutors_` 配了 `executorsMtx_`）、`f_rule/src/engine/RuleEngine.cj:75-84`（`session()` 的 get→new→put）、`f_rule/src/engine/RuleEngine.cj:87-94`（`release()`）、`f_rule/src/engine/RuleEngine.cj:123-136`（`close()` 写 `closed_` 并遍历/清空 `sessions_`）；`f_rule/src/engine/RuleSession.cj:105-111`、`148-217`（会话内部 `FactBaseViewStore` / `SessionRuntime` / `Agenda`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §12.1「共享可变状态无保护」「检查-然后-写入」「可见性」；§11「契约与实现不符」
- **证据**：静态确定 —— ①`doc/08-api.md:23` 明确写 `RuleEngine`「线程安全：是」，`RuleEngine` 也只在 `tableExecutors_` 上加了锁，说明作者已有并发意识，缺锁的 `sessions_` 不是有意设计；②`std.collection` 集合不支持并发（`stdlib/doc/libs/std/collection/collection_package_overview.md:27`：「collection 包提供的集合类型都不支持并发安全」）；③`session()` 的条件判断与写入分属两条语句，是典型检查-然后-写入；④`FactBase`/`SessionNetwork`/`Agenda` 全仓 `grep Mutex|synchronized` 为零命中。
- **描述**：三条并发访问路径都没有同步手段：
  1. 两个线程同时 `session("s1")`，都读到 `None`，各自 `RuleSession(this, id)` 后写回：后写者覆盖先写者。两个对象各自持有独立的 `FactBaseViewStore`，但会话名相同 ⇒ 同一个 `id` 出现两份互不可见的事实，被覆盖的那个从 `sessions_` 消失、无法 `release`，其令牌与议程只能等 GC；
  2. `session()` / `release()` / `close()` 与 `close()` 并发：`close()` 在无锁状态下遍历 `sessions_` 并 `clear()`，同时另一线程 `sessions_[id] = created` ⇒ 非线程安全 `HashMap` 的迭代期间修改，结果可能是漏关会话、丢元素或运行时异常；
  3. `closed_` 是普通 `var`，`close()` 写在无锁区、`ensureOpen()` 在另一线程读，既无原子也无锁 ⇒ 关闭后仍可能读到旧值并往已关闭引擎里塞新会话（该会话后续 `assert`/`fire` 会抛 `CLOSED`，等于凭空多出一个永不释放的会话）。
- **建议**：新增 `sessionsMtx: Mutex`，把「`ensureOpen` 检查 + 查表 + 创建 + 插入」整体放进同一临界区（`release`、`close` 的遍历/清空同理），`closed_` 的读写也纳入该锁或改为原子；若要保留「同 id 同会话」，必须在临界区内二次确认。`RuleSession` 的并发边界要么加锁、要么在 `doc/08-api.md` 与类注释里明确写「一个会话只能由单线程使用」——现状是两边都没说，使用者按引擎级承诺推断会话安全就会踩到 `HashMap` 损坏。

### [一般][存量] 同一 `RuleSet` 上多引擎共享时，`expressionTimeout` 互相覆盖、`close()` 互相牵连

- **位置**：`f_rule/src/engine/RuleEngine.cj:53`（构造时 `ruleSet.configureExpressionTimeout(options.expressionTimeout)`）、`f_rule/src/engine/RuleEngine.cj:135`（`close()` 调 `ruleSet_.close()`）；被改写方 `f_rule/src/rule/RuleSet.cj:137-139`、`:161-164`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「契约与实现不符」「共享可变状态」；§12.1「共享可变状态无保护」
- **证据**：静态确定 —— `ShardedNetwork.shared()` 的注释写明「多个引擎共享同一份结构是安全的」（`f_rule/src/rete/ShardedNetwork.cj:83-84`），`RuleEngine` 构造正是走 `shared()`；`ShardedNetwork` 按 `refEq(ruleSet)` 命中缓存，说明「一个 `RuleSet` 多个 `RuleEngine`」是被支持的用法。而 `RuleSet.failureGuard` 是规则集级的唯一实例（`RuleSet.cj:56`，注释「跨会话共享」），超时被存在该实例里（`RuleFailureGuard.cj:38`）。
- **描述**：引擎 B 用 `EngineOptions(expressionTimeout: 2ms)` 构造时，会把**已在运行的引擎 A** 全部会话的求值超时改成 2ms（A 的 `EngineOptions` 从此失效，且没有任何提示）；反过来，A 之后再构造一个默认选项的引擎也会把 B 的超时改回 50ms。`close()` 同理：A 关闭会把共享 `RuleSet` 置 `closed_`，B 的 `ruleSet.closed` 立刻变 `true`、之后无法再为同一个 `RuleSet` 建引擎，但 B 的会话仍能 `fire`（`RuleSession.ensureOpen` 只看 `engine_.closed`）⇒ 对外可见状态（`closed == true`）与实际能力（仍能执行）自相矛盾。
- **建议**：把超时下沉到引擎/会话层（`RuleFailureGuard` 每引擎一份，或 `TerminalNode` 从 `SessionRuntime` 取超时），`RuleSet` 只保留与规则内容相关的状态；`close()` 不要跨引擎级联，或者给 `RuleSet` 加引用计数、禁止一个 `RuleSet` 被两个 `RuleEngine` 同时持有（构造时抛 `ILLEGAL_STATE`）。若坚持「超时属于规则集」，至少要在 `RuleEngine` 构造处检测并拒绝「同一 `RuleSet` 二次配置不同超时」。

### [一般][存量] `release` / `dispose` 不释放 Rete 运行态，与「释放会话及其事实、令牌、议程」不符

- **位置**：`f_rule/src/engine/RuleSession.cj:209-217`（`dispose` 只 `agenda_.clear()` + `views_.release(id_)`）、`f_rule/src/engine/RuleEngine.cj:86-94`（注释承诺「释放会话及其事实、令牌、议程」）、`f_rule/src/engine/RuleEngine.cj:123-136`（`close()` 走同一路径）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「资源释放不对称」「契约与实现不符」；§7「缩短生命周期」
- **证据**：静态确定 —— 会话的事实与令牌有两份持有者：`FactBaseViewStore`（`dispose` 已释放）和 `SessionRuntime` 的 `SessionNetwork.alphaMems_/betaMems_/alphaHits_`（仍持有 `Fact` / `Token`）。`SessionRuntime` 没有任何 `dispose`/`clear` 方法（`src/rete/SessionRuntime.cj` 只有 `assert`/`retract`/`update`/`shard` 与只读计数），唯一能清空的 `SessionNetwork.clearMemories()`（`src/rete/SessionNetwork.cj:150`）全仓零调用；`RuleSession.runtime_` 是 `let`，`dispose` 之后依旧被会话对象强引用。
- **描述**：调用方若保留 `RuleSession` 引用（缓存会话、把会话塞进 map 的常见写法），`engine.release(id)` 返回 `true`、`agenda` 被清空、`facts` 变空，但网络里每条事实对应的 alpha/beta memory 与令牌仍在 ⇒ 大量事实对象无法回收，调 `release` 释放内存的目的落空。只有等调用方丢掉会话对象、且没有 `agenda`/`runtime` 的其它引用时才会被 GC。
- **建议**：`RuleSession.dispose()` 里遍历 `engine.network().spaces()`，对每个空间调 `runtime_.shard(space).clearMemories()`（或给 `SessionRuntime` 加 `dispose()` 封装同样的循环），再清议程、释放视图；`RuleEngine.close()` 复用同一路径。若「释放」本就不打算回收网络内存，应把注释与 `doc/08-api.md` 的承诺改成「仅解除会话登记，内存由 GC 回收」。

### [一般][存量] `OperatorEvaluator.elements` 的容器契约不成立：只认 `Any` 参数化容器，还把无序集合交给 `Between`

- **位置**：`f_rule/src/condition/Truth.cj:278-284`（`case items: Array<Any>` / `ArrayList<Any>` / `ReadOnlySet<Any>`）、`:223-234`（`In`/`NotIn`）、`:248-265`（`Between` 取 `items[0]`/`items[1]`）、`:267-275`（逐元素 `ValueKey.of`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「边界 / 空值未处理」「契约与实现不符」；语言特性「泛型不型变」
- **证据**：静态确定（数组类型）＋待确认（集合迭代顺序）—— 仓颉泛型在其类型参数处不型变（`docs/dev-guide/source_zh_cn/generic/generic_subtype.md:27`、`:35`），`is` 判定的是「运行时类型是目标类型的子类型」（`docs/dev-guide/source_zh_cn/class_and_interface/typecast.md:9`），而数组字面量默认推断为 `Array<Int64>`（`docs/dev-guide/source_zh_cn/basic_data_type/array.md:34`）。项目内所有调用点都显式构造 `Array<Any>`（`CellParser.cj:152-169`、`PropertyGen.cj:161-166`、`Operator_test.cj:31-33`），恰好绕开了这个边界。
- **描述**：外部按最自然的写法 `.constrain("level", Operator.In, [1, 2, 3])`，`value: Any` 里装的是 `Array<Int64>`，`is Array<Any>` 为 `false` ⇒ `elements` 返回 `None` ⇒ 抛 `TYPE_MISMATCH`「In/NotIn 的右值必须是集合」，可传入的明明是集合，错误文案误导。`ArrayList<Int64>` 同样落到 `None`；`ValueKey.of` 有完全相同的限制（`ValueKey.cj:108-124`，`Array<Int64>` 落 `_` 分支抛「值类型不受支持」）。另一个方向是 `Between`：`ReadOnlySet` 也被归一成数组，然后按 `items[0]`/`items[1]` 当上下界，集合不承诺顺序，上下界可能颠倒（`Between` 结果恒 `false`）——具体表现取决于底层哈希顺序，需实测确认。
- **建议**：`Constraint` 构建期就把常量归一成 `Array<Any>`（或直接预计算 `Array<ValueKey>`）并对不可接受类型给出「请传 `Array<Any>` / 用 `constrain` 的集合重载」的明确错误；`Between` 只接受有序二元容器，`ReadOnlySet`/`Set` 直接拒绝（`TYPE_MISMATCH` 文案改成「Between 需要 [low, high] 有序二元数组」）；为 `constrain` 增加 `Collection<Any>` 重载并在 README 的 `In`/`Between` 示例里写清容器的确切类型。

### [一般][存量] `Pattern` 构建完成后仍可变更，与「规则集构建后只读」冲突，Rete 与参考实现会漂移

- **位置**：`f_rule/src/condition/Pattern.cj:32`（可变 `constraints_: ArrayList<Constraint>`）、`:53-56`（`addConstraint`）、`:59-62`、`:71-74`、`:77-80`（三个 `constrain*` 均原地 append 并返回 `this`）；被引用处 `f_rule/src/rule/rule.cj:232`（`Rule` 只保存 `patterns_.toArray()`，元素是同一批对象引用）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「契约与实现不符」；§2「近似重复导致的行为漂移」；§12.1「共享可变状态」
- **证据**：静态确定 —— `doc/08-api.md:22` 声明 `RuleSet`「构建期单线程；构建后只读」，`Rule.patterns` 是 `public let Array<Pattern>`，而 `Pattern` 的约束集合没有任何冻结标记；`NetworkBuilder.cj:224` 在构建期用 `{ fact => constraint.eval(fact).isTrue() }` 把当时存在的 `Constraint` 编进 alpha 节点，构建后新增的约束不会被补节点。
- **描述**：`ruleSet.rules[0].patterns[0].constrain("amount", Operator.Lt, 100)` 这类调用在构建后仍然合法：`RuleSet` 表面上「只读」，但 `Pattern.eval`/`Pattern.matches`（参考实现 `NaiveMatcher` 与差分测试走的路径）、`TableCompiler` 会看到新约束，Rete 仍按旧约束匹配 ⇒ 同一规则集在两条路径上给出不同结果，差分测试可能因此偶发不一致；并发场景下 `ArrayList` 无锁，另一个线程遍历时 append 还可能抛并发修改异常。
- **建议**：`RuleBuilder.build()` 时深拷贝 `Pattern`（含约束数组）或在 `Pattern` 上加 `frozen_` 标记，`constrain*`/`addConstraint` 在冻结后抛 `ILLEGAL_STATE`；顺带把 `Pattern.constraints` 的 `toArray()` 复制语义写进注释（目前每次访问都分配一次副本）。

### [一般][存量] `executeTable` 编译失败会把决策表永久标成 `Executed`，后续装配被误报 `TABLE_MODE_CONFLICT`

- **位置**：`f_rule/src/engine/RuleEngine.cj:106-115`（缓存未命中时 `TableExecutor(table, ...)` 在锁内构造）、`f_rule/src/table/TableExecutor.cj:51-54`（先 `table.markExecuted()` 再 `TableCompiler(...).compile()`）、`f_rule/src/table/DecisionTable.cj:115-127`（`markExecuted` 只置位不回退）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「错误处理缺失」「状态不对称」；§3「开关打开后走进空分支」的同类形态（失败路径留下的状态被当成成功）
- **证据**：静态确定 —— `TableExecutor` 构造函数第 52 行 `table.markExecuted()`，第 54 行才编译；`TableCompiler.compile` 会抛 `UNKNOWN_FACT_SPACE`（`TableCompiler.cj:130`）、`UNKNOWN_FIELD`（`:343`/`:406`）、`TYPE_MISMATCH`（`:417`）、`TABLE_INVALID`（`:431`）等。
- **描述**：最典型的触发：`engine.executeTable(table, session)` 时引擎的 `RuleSet` 没有声明 `table.factSpace`，构造函数在 `UNKNOWN_FACT_SPACE` 处抛出；此时表已被标记 `Executed`、`RuleEngine.tableExecutors_` 里也没有对应条目。之后想把这同一张表装配进一个声明了该空间的规则集（`.table(table)`），`markAssembled()` 看到 `Executed` 直接抛 `TABLE_MODE_CONFLICT`，用户按错误码会去排查「两条路径混用」，而真实原因是上一次执行失败；`table.mode` 也谎报「已执行」。
- **建议**：先编译、成功后再 `markExecuted()`（把标记移到 `compile()` 之后），或给 `DecisionTable` 加包内 `unmarkExecuted()` 在失败时回滚；`RuleEngine.executeTable` 里对 `UNKNOWN_FACT_SPACE` 这类「表与规则集不匹配」的情况提前校验，避免进入构造流程。

### [一般][存量] 会话暴露的写入口与关闭检查不一致：视图写入不传播、关闭后读入口仍可用

- **位置**：`f_rule/src/engine/RuleSession.cj:136-140`（`facts` 返回可写 `FactBaseView`）、`:148-150`（`factsOf`）、`:152-156`（`agenda`）、`:219-223`（`ensureOpen` 只被 `assert`/`retract`/`update`/`fire` 调用）；视图实现 `f_rule/src/fact/FactBaseView.cj:87-90`（`assert` 只写 `base_`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「契约与实现不符」；§3「接口承诺有行为、实现为空」的相邻形态（入口存在但语义缺失）
- **证据**：静态确定 —— `RuleSession.assert` 在写完视图后还要调 `runtime_.assert` 才产生匹配（`RuleSession.cj:164-175`），而 `FactBaseView.assert` 只做 `base_.assert(fact)`；`facts`/`factsOf`/`agenda` 三个访问器都不检查 `disposed_` 或 `engine_.closed`，`Agenda.fire` 也不感知会话状态。
- **描述**：两个方向的坑：①`session.facts.assert(fact)`（或 `session.factsOf(space).assert`）能成功写入并让 `facts.size()` 变大，但网络没有收到传播 ⇒ 规则永远不激活，没有任何错误或日志；②`engine.close()` 之后，`session.factsOf("orders")` 不抛 `CLOSED` 而是重建一个空视图（`FactBaseViewStore.view` 在键缺失时新建），`session.agenda.fire()` 也不抛 `CLOSED`（只是空议程返回 0）——与 `RuleEngine.cj:30`「之后任何执行都抛 `CLOSED`」的承诺不符，调用方无法通过异常感知「引擎已关闭」。
- **建议**：会话层只暴露只读视图（新增 `FactBaseView` 的只读子类型，或把写方法改为 `internal`），写入口统一走 `RuleSession.assert/retract/update`；`facts`/`factsOf`/`agenda` 前置 `ensureOpen()`，或在 `dispose` 后让 `views_.view` 直接抛 `CLOSED`；`Agenda.fire` 通过回调检查会话状态。

### [轻微][存量] `tableExecutors_` 以用户可控的 `(id, version)` 为键、无容量上限与淘汰

- **位置**：`f_rule/src/engine/RuleEngine.cj:36`、`:105-113`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §5「缓存键无界」（无量化 ⇒ 只能定轻微）；§7「有界化」
- **证据**：静态确定 —— 键由 `table.id` + `table.version` 拼成，`executeTable` 是 `public`，任何调用方都能传入新表；`TableExecutor` 只在 `close()` 时随整表清空（`RuleEngine.cj:132-134`），期间没有任何字节/条目上限或 LRU。
- **描述**：长生命周期引擎若按请求生成表版本（例如每次灰度发布换 `version`），每个版本都会常驻一个已编译执行器（含编译后的表达式/JIT 结果），RSS 单调上升；由于没有量化数据，本条只按「缓存无界」记轻微，收益与阈值需要实测。
- **建议**：加容量上限 + LRU（复用 `f_cache` 的 `HeapCache`），或按表 `id` 只保留最近 N 个版本；至少提供 `evictTable(id, version)` 让调用方在发布切换后主动释放。

### [轻微][存量] `RuleErrorCode.==` 是第二份变体表且兜底 `false`，新增变体会静默破坏「自反相等」

- **位置**：`f_rule/src/exception/RuleErrorCode.cj:120-151`（27 对逐条匹配 + `case _ => false`）对照 `:83-113`（`toString`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §2「字面量复制 / 只改变体名的重复」
- **证据**：静态确定 —— 两个 match 覆盖同一组 27 个变体；`toString` 无兜底（漏写会编译失败），`==` 有 `_ => false`（漏写不会报错）。
- **描述**：新增第 28 个错误码时，编译器只强制更新 `toString`，`==` 会静默落到 `false` ⇒ `CODE == CODE` 为假、放进 `HashMap`/`HashSet` 后取不回来，而文件头注释承诺「== 按变体判等，两者自洽」。当前 27 个变体全部正确，属于潜在维护风险。
- **建议**：`==` 改为 `this.toString() == other.toString()`（与 `Operator`/`Truth` 保持同一策略，`toString` 已是编译期穷尽检查），或去掉兜底让编译器强制穷尽；若担心字符串比较开销，可用 `hashCode()` 比较。

### [轻微][存量] `OperatorEvaluator` 里两个 `orderingOf` 函数体逐行相同，只差参数类型

- **位置**：`f_rule/src/condition/Truth.cj:175-183`（`orderingOf(Int64, Int64)`）与 `:185-193`（`orderingOf(String, String)`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §2「只改类型名」
- **证据**：静态确定 —— 两个函数体都是 `if (left == right) { EQ } else if (left < right) { LT } else { GT }`，输入→输出→副作用完全一致。
- **描述**：属于可合并的同语义实现；同类形态还有 `Operator.==`/`Truth.==` 各自用 `toString()` 比较（`Operator.cj:64-70`、`Truth.cj:82-88`），以及 `RuleSetStatus.==`（不在本部分）。合并收益是可读性，不是性能。
- **建议**：抽一个私有 `compareOrdered<T: Comparable<T>>`（若语言侧泛型约束不便，也可用 `Comparable` 接口）供两处调用；`==`/`!=` 的样板保持现状即可（各类型独立实现是必要样板，不强制合并）。

### [轻微][存量] `RuleSession.cj` 未使用的 import `ShardedNetwork`

- **位置**：`f_rule/src/engine/RuleSession.cj:22`（`import fountain::f_rule.rete.{SessionRuntime, ShardedNetwork}`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §1「未使用的 import」
- **证据**：静态确定 —— 全文件搜 `ShardedNetwork` 只命中第 22 行；`engine.network()` 的返回类型推断为 `SessionRuntime`，不需要该类型名。
- **建议**：改为 `import fountain::f_rule.rete.SessionRuntime`。

### [轻微][存量] 动作传播钩子在 `runtime` 未注入时静默丢弃事实变更

- **位置**：`f_rule/src/engine/RuleSession.cj:78-97`（`onAssert`/`onRetract`/`onUpdate` 的 `case None => ()`）、注入点 `:126`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §3「`case None => ()` 当兜底把错误吃掉」
- **证据**：静态确定 —— 三个钩子都是「有 runtime 就传播、没有就什么都不做」，且没有任何日志或异常；`runtime` 是 `public var`，可被置回 `None`。
- **描述**：正常构造流程中 `runner.runtime = Some(runtime_)` 紧跟议程创建，当前不可达；但一旦会话构造中途失败或有人把 `runtime` 置空，动作里 `ctx.assert/retract/update` 会改视图却不改网络 ⇒ 事实与令牌不一致且无任何痕迹，排查成本极高。
- **建议**：`None` 分支改为抛 `RuleException(ILLEGAL_STATE, "会话运行时未注入")`；`runtime` 收窄为 `private var` 并提供包内 setter。

### [轻微][存量] `EngineOptions.expressionTimeout` 是公开可写字段，但构造后再改不生效

- **位置**：`f_rule/src/engine/EngineOptions.cj:25-29`（`public var expressionTimeout`）、读取点仅 `f_rule/src/engine/RuleEngine.cj:53`（构造时一次性拷进 `RuleSet`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「语义与命名不符」；§1「读了不用 / 死配置」的相邻形态
- **证据**：静态确定 —— `RuleEngine` 只在构造函数里读一次 `options.expressionTimeout`，之后没有任何监听或重新读取；`EngineOptions` 没有 `apply`/`bind` 入口。
- **描述**：`doc/08-api.md:328-330` 特意写了「未实现前不提供对应字段，避免『有字段不生效』」，但这个已实现的字段本身就有同样的坑：`engine = RuleEngine(rs, opts); opts.expressionTimeout = ...` 会静默无效。字段是 `var`，使用者很容易认为可热调。
- **建议**：把字段改成 `let`（构造后不可变），或在 `RuleEngine` 上提供 `setExpressionTimeout()` 并明确生效范围；至少在字段注释里写「仅在构造 `RuleEngine` 时读取，之后修改无效」。

### [轻微][存量] `executeTable` 不校验传入会话是否属于本引擎

- **位置**：`f_rule/src/engine/RuleEngine.cj:102-116`（只 `ensureOpen()` 后用 `session.factsOf(...)`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「缺少边界校验」
- **证据**：静态确定 —— `RuleSession` 不携带指回引擎的可比较标识（`engine_` 是 `private let`，没有 `engine` 属性），`executeTable` 也没有任何归属检查；执行器按**本引擎**的 `ruleSet_.registry` 编译，事实却取自传入会话。
- **描述**：把引擎 A 的会话传给引擎 B 的 `executeTable`，会用 B 的字段/类型定义去解释 A 的事实视图，结果错但不报错（两个规则集类型同名同结构时尤其隐蔽）。
- **建议**：`RuleSession` 暴露包内 `engineId` 或 `owner()`，`executeTable` 校验不一致时抛 `ILLEGAL_STATE`；或让 `executeTable` 直接接收 `sessionId` 由引擎自己解析。

## 优化可行性方案

> 不是缺陷，是「还能更好」。以下都没有改前/改后对照数据，一律按「待验证」处理。

### [堆内存] `In`/`Between`/`Contains` 的集合归一不做整表复制

- **现状**：`elements()` 对 `ArrayList<Any>`/`ReadOnlySet<Any>` 调 `toArray()`（`Truth.cj:281-282`），随后 `containsElement` 对每个元素现算 `ValueKey`（`:267-275`）。单次判定分配 1 个数组（n 个槽）+ n 个 `ValueKey`，n = 右值集合大小；判定次数 = 候选事实数。
- **方案**：把常量右值在构建期归一成 `Array<ValueKey>`（`Constraint` 持有一份），求值时只对左值算一次 `ValueKey` 再线性比较；`ReadOnlySet` 保留原集合、直接用 `contains`（`Set` 已是 O(1)，不要退化成数组）。
- **预期**：单次判定从「1 次数组复制 + n 次 ValueKey 分配」降为「1 次 ValueKey 分配」；集合查找从 O(n) 降到 O(1)（`Set` 分支）。绝对收益取决于 n 与判定次数。
- **代价**：`Constraint` 增加一份预计算字段（内存换 CPU），`Operand.Const` 语义需要区分「原始值」与「归一后的 key」；`Between` 要同时保留顺序信息，不能再接受 `Set`。
- **验证**：`cjpm bench -O2` 对照「10 万事实 × 100 元素集合的 `In` 匹配」，同时看 `cjprof heap` 的分配量与峰值。
- **证据状态**：`无基线（待验证）`

### [堆内存] 决策表执行器缓存有界化

- **现状**：`tableExecutors_` 每个 `(id, version)` 常驻一个 `TableExecutor`（含编译结果），只在 `close()` 时整体清空。
- **方案**：上限 + LRU（例如最近 32 个版本），或按 `id` 分组只留最新 N 个版本；命中时刷新 LRU。
- **预期**：长跑场景下常驻对象数从「版本数」降为固定上限，RSS 不再随发布次数单调增长。
- **代价**：淘汰后再次执行同一版本要重新编译（毫秒级），需要按发布节奏选上限；LRU 结构本身有锁竞争风险（当前缓存已在一把锁内，可复用）。
- **验证**：连续 `executeTable` 1 万个不同 `version`，观察 `getAllocatedHeapSize()`/RSS 是否在淘汰后回到稳态。
- **证据状态**：`无基线（待验证）`

### [CPU] 决策表首次编译移出全局锁

- **现状**：`executeTable` 在 `synchronized(executorsMtx_)` 内构造 `TableExecutor`（编译整张表，`RuleEngine.cj:106-114`）。所有表、所有会话的首次执行共享这一把锁，一次编译期间其它表的缓存命中也被挡住。
- **方案**：锁内只做查表；未命中时先在锁外编译，再回锁内 `addIfAbsent`（重复编译的结果丢弃），或用 per-key 的单飞（singleflight）避免同表重复编译。注意 `RuleCompiler`/`Compiler` 是否可并发编译需要先确认（当前串行可能同时是编译器的保护）。
- **预期**：多表并发首次执行时串行段从「编译耗时」降为「查表耗时」。
- **代价**：可能重复编译（浪费 CPU），需要确认 `f_jit.Compiler` 与 `RuleRuntime.compiler()` 的线程安全性；缓存淘汰与单飞逻辑增加复杂度。
- **验证**：`cjpm bench -O2`，8 线程 × 20 张不同表各执行一次，比较端到端耗时与 `cjprof` 中锁等待；同时观察 `TableCompiler.compileCount()`。
- **证据状态**：`无基线（待验证）`

### [CPU] `fire()` 复用 `fireDetailed()` 时省掉 `FiredRule` 包装

- **现状**：`fire()` 直接调 `fireDetailed()`（`RuleSession.cj:194-196`），后者为每条 `FireRecord` new 一个 `FiredRule` 并 `toArray()`（`:199-207`），即使调用方只要输出槽。
- **方案**：`fire()` 单独走「`agenda_.fire` + `lastOutputs()`」的快路径，不构造 `FiredRule` 数组。
- **预期**：单次 `fire` 的对象数从 `fired + 1` 降为 1；fired 规模大时（Collect 策略、数百行）收益明显。
- **代价**：两条路径需要保持输出合并语义一致（当前 `fire` 是薄封装，改动后要防止漂移）。
- **验证**：`cjpm bench -O2` 对照 1000 次 `fire`（每次 100 条命中），看分配量与 P50/P99。
- **证据状态**：`无基线（待验证）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `In`/`Contains` 对集合右值的 `toArray()` + 线性扫描是匹配路径的主要分配/耗时来源 | `f_rule/src/condition/Truth.cj:267-284` | 单次判定自耗时占比、每次分配字节数 | `cjprof record` 跑 10 万事实 × `In` 100 元素集合；`cjprof heap` 看分配 |
| 2 | 决策表首次编译在全局锁内导致多表并发首次执行被串行化 | `f_rule/src/engine/RuleEngine.cj:106-114` | 编译单次耗时、锁等待时长、并发度 | 8 线程 × 20 张不同表，分段计时 + 线程状态（BLOCKED 占比） |
| 3 | `Pattern.eval` / `ConditionExpr` 的 `And`/`Or` 不短路，多约束模式下会做多余求值 | `f_rule/src/condition/Pattern.cj:88-94` | 约束数分布、每条约束平均耗时 | `cjpm bench -O2`，4 条约束的模式对比「全部求值」与「手工短路」版本 |
| 4 | `tableExecutors_` 长期增长对 RSS 的实际影响 | `f_rule/src/engine/RuleEngine.cj:36` | 单执行器占用、版本增长率 | 连续 1 万次不同 `version` 的 `executeTable`，观察 RSS / `getAllocatedHeapSize()` |
| 5 | `release` 后保留会话引用时事实不回收（前述「一般」条的内存侧影响） | `f_rule/src/engine/RuleSession.cj:210-217` | release 前后 heapUsed/RSS 对照 | 断言 10 万事实 → `release` → 保留 `session` 引用，`gc()` 后读 `getUsedHeapSize()`/RSS |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_rule/src/condition/JitExpression_test.cj` | .cj | ✅ | 覆盖 JIT/解释器降级契约，断言与 doc/03 描述一致；无缺陷 |
| 2 | `f_rule/src/condition/JoinConstraint.cj` | .cj | ✅ | 绑定缺失返回 `Unknown`（符合注释）；`evalWith` 为 Rete 热路径的正确重载，无问题 |
| 3 | `f_rule/src/condition/Operand.cj` | .cj | ✅ | `Bind` 单事实求值返回 `None`（设计如此）；`isBind` 被 `Constraint.validate` 使用 |
| 4 | `f_rule/src/condition/Operator.cj` | .cj | ✅ | 15 个算子名与 `indexable`/`ordering` 表自洽；`==` 走 `toString`（见「轻微 同构实现」） |
| 5 | `f_rule/src/condition/Operator_test.cj` | .cj | ✅ | 15 个算子 + 空集合 + 跨域排序均有断言；`list()` 强制 `Array<Any>`，恰好绕开容器契约问题（见「一般 elements」） |
| 6 | `f_rule/src/condition/Pattern.cj` | .cj | ✅ | 见「一般 Pattern 可变」 |
| 7 | `f_rule/src/condition/Pattern_test.cj` | .cj | ✅ | 覆盖约束重排、`whereNot`、字段右值、重复绑定；无缺陷 |
| 8 | `f_rule/src/condition/Truth.cj` | .cj | ✅ | 三值真值表正确；见「一般 elements」「轻微 orderingOf 重复」 |
| 9 | `f_rule/src/condition/TruthTable_test.cj` | .cj | ✅ | 9 格 `And`/`Or` + `Not Unknown` 全覆盖，与实现一致 |
| 10 | `f_rule/src/condition/condition.cj` | .cj | ✅ | 仅包声明与 M0 说明注释，无代码；注释里「M1 落地」已完成，属历史说明 |
| 11 | `f_rule/src/engine/EngineOptions.cj` | .cj | ✅ | 见「轻微 可变但不生效」 |
| 12 | `f_rule/src/engine/EngineTable_test.cj` | .cj | ✅ | AS-06~AS-12 覆盖缓存/版本/命中策略/双向互斥；`compileCount` 精确断言依赖测试串行（信息项，未确证并行度） |
| 13 | `f_rule/src/engine/ExpressionFailure_test.cj` | .cj | ✅ | 失败计数、跨会话禁用、超时、动态事实类型不符均有断言，与 `RuleFailureGuard` 语义一致 |
| 14 | `f_rule/src/engine/RuleEngine.cj` | .cj | ✅ | 见「严重 并发」「一般 共享 RuleSet」「一般 executeTable 标记」「轻微 缓存无界」「轻微 会话归属」 |
| 15 | `f_rule/src/engine/RuleEngine_test.cj` | .cj | ✅ | 会话复用/释放/关闭/非法规则集均覆盖；未覆盖并发 `session()`（与「严重」条对应） |
| 16 | `f_rule/src/engine/RuleSession.cj` | .cj | ✅ | 见「一般 release 不释放」「一般 写入口/关闭检查」「轻微 静默丢弃」「轻微 未使用 import」 |
| 17 | `f_rule/src/engine/RuleSession_test.cj` | .cj | ✅ | 跨空间议程、撤销失效、`fireDetailed` 顺序均有断言；无缺陷 |
| 18 | `f_rule/src/engine/ScriptAction_test.cj` | .cj | ✅ | 脚本动作/裸体包装/编译失败/`RuleAction` 接口四条路径覆盖；无缺陷 |
| 19 | `f_rule/src/engine/ScriptCondition_test.cj` | .cj | ✅ | 脚本 true/false 与构建期缺绑定覆盖；`RuleRuntime.initCompiler` 是全局状态（测试间串行依赖，信息项） |
| 20 | `f_rule/src/exception/RuleErrorCode.cj` | .cj | ✅ | 27 个变体与 `toString` 一致；见「轻微 `==` 重复表」 |

合计：`.cj` 20 个 / `.md` 0 个 / 共 20 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 9 | 正确性 4（容器契约、`Pattern` 可变、`executeTable` 状态污染、关闭旁路）；设计 2（共享 `RuleSet`、释放不对称）；语言特性 2（泛型不型变 + `Any` 装箱、`toString` 判等）；可读性 1（同构 `orderingOf`）；安全性 0（本部分无外部输入拼接、无 SQL/HTML/路径、无凭据；`Matches` 的正则来自规则定义，`f_regex` 已有缓存与超时保护） |
| §1 死代码 | 1 | 逐个核对：`private` 成员（`Pattern.constraints_`、`OperatorEvaluator` 的 `init`/`equalValues`/`bool`/`compare`/`orderingOf`×2/`stringPair`/`contains`/`membership`/`matches`/`between`/`containsElement`、`RuleEngine` 6 个字段、`RuleSession` 6 个字段 + `ensureOpen`、`SessionActionRunner` 3 个字段）均有引用；`internal` 的 `RuleEngine.network()`、`RuleSession.init/dispose`、`OperatorEvaluator.elements`、`SessionActionRunner` 均有调用者；本部分无 `protected`；对外可达 `public`（`Pattern.any`/`constraints`、`Operand.isBind`、`Operator.indexable`/`ordering`、`Truth.or`、`FiredRule`/`FireResult`）仓内引用情况已记录但不判死代码；测试文件内的 `internal` 顶层辅助函数（`engineRuleSet`/`sessionRuleSet`/`failureRuleSet`/`scriptRuleSet` 等）逐个确认被同文件用例使用。唯一命中：1 条未使用 import。`OperatorEvaluator.apply` 末尾的 `case IsNull \| NotNull => Truth.Unknown` 是 match 穷尽性必需，非死分支 |
| §2 重复逻辑 | 1 | 同文件内把 20 个文件的函数体压成「输入→输出→副作用」两两比对：命中 `orderingOf` 两份同体；其余已核对并判为非重复——`Pattern.constrain/constrainField/constrainNot` 差异在右值与取反，`JoinConstraint.eval/evalWith` 差异在绑定表 vs 解析函数（注释已说明热路径动机），`RuleSession.fire/fireDetailed` 是语义不同的薄封装，`SessionActionRunner` 三个钩子签名与副作用不同，各枚举的 `toString`/`==` 是必要样板；跨文件字面量：`Duration.millisecond * 50` 在 `EngineOptions.cj:27` 与 `RuleFailureGuard` 各出现一次（后者是独立默认值，且引擎总会覆盖），不构成行为漂移，未单列 |
| §3 空实现 | 1 | 无 `TODO`/`FIXME`/`UnsupportedException`/空函数体（`OperatorEvaluator` 的 `private init() {}` 是防实例化，`condition.cj` 只有注释）；唯一命中是 `SessionActionRunner` 三个传播钩子的 `case None => ()` 静默丢弃 |
| §4 栈溢出 | 0 | 本部分无递归：`Pattern.eval`/`Truth.*`/`OperatorEvaluator.*` 全是单层 match/循环，`JoinConstraint` 无自引用，`RuleEngine`/`RuleSession` 无递归调用；`ConditionExpr` 的深度保护在另一个部分，未在本部分展开 |
| §5 OOM | 1 | 命中 `tableExecutors_` 缓存无上限（未量化 ⇒ 轻微）；`sessions_` 只增不减但有 `release` 公开出口，按设计不算缺陷；`Pattern.constraints_` 只在构建期增长；`elements()` 每次求值复制集合属于可回收短命对象（计入优化方案，不按无界增长报） |
| §6.1 热点瓶颈 | 0 | 本部分未提供 profile/bench 数据，热点的四项要件（函数自耗时、调用路径、输入规模、工具）都不成立；候选已放「待验证假设」1~3 |
| §6.2 大粒度锁 | 0 | `executorsMtx_` 的临界区内确实是「查表 + 编译」，但缺少持有时长与竞争线程数，按清单只能进「优化方案（CPU）」与「待验证假设」2，不按缺陷报；`sessions_` 无锁的问题已在「严重」条按并发正确性处理（正确性优先于锁粒度） |
| §6.3 并发串行 | 0 | 本部分无 `spawn`/`Future`/批处理；`Agenda.fire` 的串行执行属议程语义，不在本部分判定 |
| §6.4 低效算法 | 0 | `In`/`Contains` 对 `ReadOnlySet` 先 `toArray()` 再线性扫描（复杂度 O(n) → 本可 O(1)）已确认，但缺「n 多大时成为瓶颈」与耗时占比，按要求放「优化方案（堆内存）」与「待验证假设」1；无循环字符串拼接、无 `remove(at:0)` 队列、无重复正则编译（`f_regex` 有 `HeapCache` 缓存） |
| §7 降堆内存方案 | 2 | 集合归一预计算、执行器缓存有界化，均标 `无基线（待验证）` |
| §8 降 CPU 方案 | 2 | 编译移出全局锁、`fire` 快路径，均标 `无基线（待验证）` |
| §9 local mode 可行性 | 0 | 本部分没有「函数内创建、函数内销毁的大对象」：`OperatorEvaluator` 的临时对象都是小标量/短数组，`RuleEngine`/`RuleSession` 的对象全部长期持有并跨线程发布（逃逸明确）；收益只能用峰值内存证明，本部分无基线，故不提出改造 |
| §11 现有代码的 BUG（存量） | 14 | 本轮 20 个文件的边界/空值/错误处理/资源/并发/契约均已过：命中 14 条（全部标 `[存量]`）。核对后判为非缺陷：`Operand.resolve` 对 `Bind` 返回 `None`（`Constraint.validate` 已禁止 `Bind` 右值）、`Truth.and/or` 的 `Unknown` 组合与 SQL 表一致（测试 9 格全覆盖）、`RuleErrorCode` 的 `hashCode` 与 `==` 自洽、`RuleSession.assert` 的回滚与 `view.retract` 返回值忽略（`retract` 在同对象上必为真）、`Pattern.constraints` 的 `toArray()` 返回副本（防外部改写，仅分配开销） |
| §12 并发安全与锁粒度 | 1 | 命中「严重：会话表/关闭标志无锁 + 会话内部无锁」；已核对：`RuleFailureGuard` 自带 `Mutex`（`RuleFailureGuard.cj:34`、`:70-118` 全部访问加锁），`ShardedNetwork` 的静态缓存用 `cacheMtx`（`ShardedNetwork.cj:87-106`），`DecisionTable.mode_` 用 `modeMutex_`（`DecisionTable.cj:100-127`）——说明项目内其余并发点已有同步手段，`RuleEngine.sessions_` 是遗漏而非约定 |
| §14 功能完备性与 README 覆盖 | 0 | 本部分无 `.md`；抽查公开符号 `RuleEngine`/`RuleSession`/`FiredRule`/`FireResult`/`JoinConstraint`/`Truth`/`Operator`/`RuleErrorCode`/`EngineOptions` 均在 `README.md` 有对应章节（如 `README.md:471-472` 的 `EngineOptions`），未发现「承诺但未接线」；`EngineOptions` 注释声明「其余策略项待后续里程碑」，与 `doc/08-api.md:328-330` 一致 |
| 文件覆盖（§13 等） | 20/20 | 无缺文件；本部分无 `.md`，§13 的文档一致性由模块其它部分覆盖。`doc/08-api.md`/`doc/03` 仅作为契约证据引用，未纳入本部分审查 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 1 |
| 一般 | 6 |
| 轻微 | 7 |
| 优化方案（堆内存 / CPU） | 2 / 2 |

存量缺陷合计 14 条（严重 1 / 一般 6 / 轻微 7），是否纳入修复待用户决定。

## 总评

求值核心（三值逻辑、15 个算子、`Between`/`In` 的边界、`JoinConstraint` 的绑定缺失语义）实现干净，与 `doc/03` 的约定和 `TruthTable_test`/`Operator_test` 的断言逐条对得上；`RuleFailureGuard`、`DecisionTable.mode_`、`ShardedNetwork` 的静态缓存都有明确的同步手段，说明作者对并发并非无意识。

本部分唯一阻塞项是 `RuleEngine` 的并发承诺：文档写「线程安全」，但 `sessions_` 与 `closed_` 完全没有同步，`session()` 又是检查-然后-写入；一旦多线程按文档用法创建会话，轻则同一 `id` 分裂成两份互不可见的事实、会话从表中丢失无法释放，重则在 `HashMap` 迭代期间被修改。这一条应优先修（加锁或明确改口为「引擎非线程安全」）。

其余「一般」都属于契约层面的收口：`RuleSet` 被多引擎共享时超时与关闭互相影响、`release` 不回收网络内存、`elements` 的容器类型契约与 `Between` 的无序集合、`Pattern` 构建后仍可变、`executeTable` 失败污染表模式、会话写入口绕过传播与关闭检查。它们不会立刻让业务算错，但在「长跑 + 多引擎 + 动态表」的组合下会以「内存不降 / 错误码误导 / 规则静默不激活」的形式暴露，建议排期修。轻微项与优化方案可在有 bench 数据后再定优先级。
