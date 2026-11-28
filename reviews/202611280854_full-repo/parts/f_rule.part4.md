# f_rule 模块审查报告（第 4/12 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_rule`（本部分 20 个源文件：`src/agenda/` 11 个、`src/condition/` 9 个）
- **基线**：工作区快照（sts/1.3.x，无基线可比，全部问题记为「存量」）
- **审查重点**：规则引擎求值正确性、递归与栈溢出、OOM、死代码、重复逻辑、并发安全、存量 BUG
- **报告版本**：v1（模块第 4/12 部分分报告，由主 Agent 与其他部分合并；本报告只统计这 20 个文件）

## 发现

> 编号约定：`S` = 严重、`G` = 一般、`L` = 轻微，按本节出现顺序编号（如 `#G2` 即第 2 条一般问题）；`O` = 优化方案，见下一节。后文表格与「文件覆盖」用这些编号互相引用。

### [严重][存量] 解释器求值状态放在共享实例上，多会话并发求值互相重置步数与截止时间

- **位置**：`f_rule/src/condition/Interpreter.cj:50`（`private var steps` / `private var deadline`），写入点 `:86-87`，读取点 `:104-117`
- **来源**：存量（快照模式无基线；`git blame` 全文件同批提交，无 diff 可比）
- **判据**：review-checklist §12.1（共享可变状态无保护 / 数据竞争）
- **证据**：静态确定 —— 共享路径可完整给出：
  1. `RuleEngine.network()` 返回的 `ShardedNetwork` 是**跨引擎共享的结构**（`f_rule/src/engine/RuleEngine.cj:56`，`f_rule/src/rete/ShardedNetwork.cj:80-84` 明写「多个引擎共享同一份结构是安全的，只有 memory 随会话变化」）；
  2. 结构里的 `TerminalNode` 持有 `scripts_: Array<JitExpression>`（`f_rule/src/rete/TerminalNode.cj:36`），求值入口 `evaluate` 直接调 `script.evalDetailed(...)`（`:120`）；
  3. `JitExpression` 持有 `program_: ?InterpreterProgram`（`f_rule/src/condition/JitExpression.cj:67`），`evalDetailed` 转调 `program.evalOutcome`（`:246-248`）；
  4. `InterpreterProgram` 的 `steps`、`deadline` 是**实例字段**，`evaluate()` 每次进来先 `steps = 0; deadline = limit`（`Interpreter.cj:86-87`），`tick()` 每节点自增并读 `deadline`（`:104-117`）。
- **描述**：同一份 `RuleSet` 上开两个引擎（或同一引擎的两个 session）在两个线程求值同一个解释器脚本时，两个线程共享同一个 `InterpreterProgram` 实例。线程 B 的 `steps = 0` 会把线程 A 已累计的步数清掉，`maxSteps` 上限因此失效（病态表达式可跑满 CPU 而不被截断）；`deadline` 被另一线程覆盖后，A 的 `tick()` 可能读到 B 的截止时间，产生「误超时」或「永不超时」。求值本身没有加锁，属于读写交错的数据竞争。默认配置下 `ExpressionMode` 为 `JitPreferred`，但动态事实、决策表 `expr` 列和 `Interpreted` 模式都会落到解释器，路径是主线。
- **建议**：把 `steps` / `deadline` 改成求值期间的局部状态（新增内部 `EvalState` 类，或把两者作为参数在 `truthOf` / `valueOf` / `tick` 之间传递），`InterpreterProgram` 保持无状态；若不改结构，至少给 `evaluate` 加实例级互斥并说明代价（会把并发求值串行化，不推荐）。

### [严重][存量] 表达式解析器递归下降没有深度上限，深括号 / 长 `!` 链先爆栈

- **位置**：`f_rule/src/condition/Interpreter.cj:393`（`parsePrimary` → `parseOr` 递归），`:384-391`（`parseUnary` 递归）
- **来源**：存量
- **判据**：review-checklist §4（无界递归，深度由输入决定）
- **证据**：静态确定 —— `maxNodes` 只在 `countNode()`（`:311-316`）里计数，且只在匹配到 `||` / `&&` / `!` / 比较符 / 一个 `parseTerm` 时调用；`(` 本身不计节点。`((((…1` 这种输入每个 `(` 都会走 `parsePrimary → parseOr → parseAnd → parseUnary → parsePrimary`，约 4 个栈帧/层，节点计数始终约等于 1，永远到不了 `maxNodes`（默认 1_000_000）。`!!!…x` 每层只 `countNode()` 一次，上限同样是 10^6 层，远超栈容量。
- **描述**：来源是决策表 `expr` 列或脚本条件（`f_rule/src/table/ExprColumn.cj:41` → `JitExpression.ofExpression` → 动态事实走 `InterpreterProgram.compile`），也就是**表文件内容**（Excel 导入）可以决定解析深度。一段几千字符的 `(` 或 `!` 就能在 `SCRIPT_COMPILE` 之前触发栈溢出。按每层约 4 帧、每帧百字节量级估算，几千层即进入危险区（具体阈值依赖平台默认栈大小，需实测确认）。
- **建议**：给解析器加 `depth` 计数（建议上限 32~64，与 `ConditionExpr` 的深度上限对齐），在 `parsePrimary` 处理 `(`、`parseUnary` 处理 `!` 时自增并在超限时 `fail("表达式嵌套过深")`；`maxNodes` 保持原语义。

### [一般][存量] `Agenda` 的可变状态无任何同步，`firing_` 重入标志不是原子量

- **位置**：`f_rule/src/agenda/agenda.cj:97`（`private var firing_`）、`:135-139`（检查-然后-写入）、`:115-127`（`heap_` / `index_` 写）
- **来源**：存量
- **判据**：review-checklist §12.1（检查-然后-写入、共享容器并发写）
- **证据**：待确认 —— 共享路径已确认：`RuleEngine.session(id)` 对同 id 返回**同一个** `RuleSession`（`f_rule/src/engine/RuleEngine.cj:75-84`，`f_rule/README.md:489`「同 id 的 `session(id)` 返回同一会话」），`RuleSession` 持有唯一 `agenda_`（`f_rule/src/engine/RuleSession.cj:110,124`）。缺的是契约：文档没有声明「一个 session 只能被单线程使用」，也没有说明同 id 多线程访问是否合法。
- **描述**：若同 id 会话被两个线程同时 `fire()`，`if (firing_)` 判定与 `firing_ = true` 之间存在竞态，两个线程可同时进入执行循环，并发写 `heap_`（`ArrayList`）、`index_`、`lastOutputs_`、`lastFired_`，后果是丢激活、堆结构损坏、`lastFired` 结果错乱。即便不同 session，`heap_` 之间也不共享，风险仅限同 session。
- **建议**：先定契约——在 `RuleSession` / `Agenda` 文档里显式写「会话非线程安全，调用方需按 id 串行」，并在 `fire` 入口加 `synchronized`/`AtomicBool` 的 CAS 重入保护（CAS 失败即抛 `REENTRANT_FIRE`），把竞态从「静默损坏」变成「明确失败」；若要支持并发，则应把 Agenda 改为线程封闭 + 每线程独立 session。

### [一般][存量] 惰性堆只清有效性位、从不压实，只写不 fire 的会话会无界持有 Fact

- **位置**：`f_rule/src/agenda/agenda.cj:125-127`（`remove` 只做 `index_.remove`）、`:291-299`（`popValid` 是唯一回收点）
- **来源**：存量
- **判据**：review-checklist §5（无界容器 / 长期持有）
- **证据**：静态确定（机制）+ 需实测（规模阈值）—— `heap_` 只在 `popHeap()` 里缩短，`remove()` 只摘 `index_` 里的有效位，因此「大量 assert→retract、很少 fire」的会话里 `heap_` 单调增长，且每个失效 `Activation` 仍持有 `Bindings`（两个 `HashMap`）与 `Fact`/`HostFact` 宿主对象。
- **描述**：最坏情况：一次批量导入 10^6 条事实并逐条 retract、期间不调用 `fire`，`heap_` 仍是 10^6 个 `Activation`。按每条 `Activation`（`key_` 字符串 + 5 个标量字段）+ `Bindings`（2 个 `HashMap`，各 ≥1 桶）估算约 0.3~0.5 KB，峰值可达 300~500 MB 的**不可回收**保留。没有拒绝路径，也没有容量上限；只有 `fire`（把失效项弹出）或 `clear()` 才会释放。
- **建议**：给 `Agenda` 加压实：当 `heap_.size > 2 * index_.size` 且超过阈值（如 1024）时，`heap_` 过滤重建并重新 `heapify`；或在 `remove` 计数达到阈值时压实一次。等价性要求：压实后相对顺序由 `ConflictResolver` 全序决定，可直接重建堆。

### [一般][存量] 白名单函数不校验参数个数，越界被吞成 `RuntimeFailure`，多余参数被静默忽略

- **位置**：`f_rule/src/condition/Interpreter.cj:212-261`（`values[0]` 见 `:228/235/241/249/264`，`values[1]` 见 `:254/256/258`）
- **来源**：存量
- **判据**：review-checklist §11（边界 / 越界、错误处理缺失）
- **证据**：静态确定 —— `parseCall`（`:565-593`）允许 `name()` 空参列表，`invoke` 对 `length` / `abs` / `round` / `dayOfWeek` / `lower`… 直接取 `values[0]`，对 `contains` / `startsWith` / `endsWith` 直接取 `values[1]`，没有任何 arity 检查。
- **描述**：`length()` 会抛数组越界，`contains("a")` 少一个参数、`contains(1,2,3)` 多参数同样越界或静默丢参；`now(1,2,3)`、`lower("a","b")` 直接忽略多余参数。越界异常在 `evaluate`（`:88-100`）被 `catch (e: Exception)` 收成 `RuntimeFailure`，于是**作者写错参数个数不会在构建期报错**，只会在运行期让规则持续求值失败；`TerminalNode` 侧连续失败会把整条规则禁用（`f_rule/src/rete/TerminalNode.cj:84-90`），表现为「规则莫名不生效」。
- **建议**：在 `InterpreterProgram.isWhitelisted` 旁给出 `(name, minArity, maxArity)` 表，`parseCall` 结束时校验并抛 `SCRIPT_COMPILE`；`invoke` 内保留一次防御性检查（`values.size < need` 直接抛 `SCRIPT_COMPILE` 而非索引）。

### [一般][存量] `contains` / `startsWith` / `endsWith` 把三值 `Unknown` 压成 `false`，否定后变 `true`

- **位置**：`f_rule/src/condition/Interpreter.cj:253-259`
- **来源**：存量
- **判据**：review-checklist §10（正确性）、§11（语义与契约不符）；契约见本文件 `:44-45` 与 `doc/03-condition-expression.md` §4/§6.2（类型不符一律 `Unknown`）
- **证据**：静态确定 —— 三个分支都是 `Some(OperatorEvaluator.apply(...).isTrue())`，`Truth.Unknown.isTrue() == false`，于是 `invoke` 返回 `Some(false)`，`truthOf`（`:155-163`）据此给 `Truth.False`。
- **描述**：`CompareExpr` 路径（`:136-139`）直接返回 `OperatorEvaluator.apply` 的 `Truth`，能保留 `Unknown`；函数式路径把 `Unknown` 折叠成 `False`，两者语义不一致。例如 `!contains(o.name, 5)`（类型不符）：正确语义是 `Not Unknown = Unknown`（不产生激活），实现给出 `True`（**错误激活**）。这条与三值逻辑契约直接冲突，且只在 `!` 组合或参与 `And` 时暴露，测试里没有覆盖。
- **建议**：让 `invoke` 返回 `Truth`（或 `?Truth`），`contains`/`startsWith`/`endsWith` 直接透传 `OperatorEvaluator.apply` 的结果；`truthOf` 的 `FuncCall` 分支按 `Truth` 处理而不是 `Bool`。

### [一般][存量] 字段路径超过两级被静默截断，未绑定标识符被当成字段名兜底

- **位置**：`f_rule/src/condition/Interpreter.cj:191-210`（`segments[1]` 在 `:201`；单绑定兜底在 `:204-208`）
- **来源**：存量
- **判据**：review-checklist §11（缺少边界校验 / 静默失效）
- **证据**：静态确定 —— `parseIdentifier`（`:537-562`）允许解析任意多段 `a.b.c`，`resolveField` 只用 `segments[0]` 与 `segments[1]`，`segments[2..]` 从未读取。
- **描述**：`o.addr.city` 会被求值成 `o.addr`（通常不是 `Bool`）→ `Unknown`，条件静默不成立，没有任何报错；拼写错误的裸标识符（`amountt`）在单绑定场景下会退化成「取该事实的 `amountt` 字段」→ `None` → `Unknown`，同样无提示。表作者无法从结果区分「字段真缺失」与「表达式写错」。
- **建议**：在 `parseIdentifier` 结束时对 `segments.size > 2` 抛 `SCRIPT_COMPILE`（或实现递归取值）；单绑定兜底建议加一次字段存在性检查，不存在时抛编译期错误而不是 `None`。

### [一般][存量] `interpretFallback` 每次求值重新编译解释器，且静默把 JIT 语义降级为受限子集

- **位置**：`f_rule/src/condition/JitExpression.cj:255-260`（触发点）、`:355-370`（每次 `InterpreterProgram.compile(body)`）
- **来源**：存量
- **判据**：review-checklist §3（静默降级 / 空实现式兜底）、§6.4（同一输入重复解析）
- **证据**：静态确定 —— `compiled_` 非空但绑定事实不是 `HostFact` 时进入 `interpretFallback`，函数体里现场 `InterpreterProgram.compile(body)`，没有缓存、没有 `warnInterpreter` 记录。
- **描述**：两条后果：(1) 语义上，JIT 支持算术/方法调用，解释器子集不支持，同一个 lambda 在这里会从「正常求值」变成恒定 `RuntimeFailure`（被 `:367-369` 吞掉），规则静默失效，且与构建期「动态事实记一次 WARN」的策略不一致；(2) 每次求值都做一次完整词法/语法分析与 AST 分配，命中该路径时是纯浪费。用 `JitExpression.of(...)` 搭配 `DynamicFact` 即可触发。
- **建议**：缓存兜底程序（`private var fallback_: ?InterpreterProgram`，首次编译后复用，注意与 S1 的无状态化改造配套）；首次降级时 `log.warn` 一次并说明「该表达式不受解释器子集支持的部分将恒为 Unknown」，或直接改为构建期拒绝。

### [一般][存量] lambda 形参解析按逗号盲切，带逗号的类型直接编译失败

- **位置**：`f_rule/src/condition/JitExpression.cj:327-344`（`header.split(",")` 在 `:330`）
- **来源**：存量
- **判据**：review-checklist §11（契约与实现不符）；承诺见 `:77`「从完整 lambda 字面量编译」与 `:51-52`「形参带类型」
- **证据**：静态确定 —— 头部按 `,` 切分后逐段要求含 `:`，第二段起若落在类型内部（`Map<String, Int64>` 的第二段是 ` Int64>`）就没有 `:`，直接抛 `SCRIPT_COMPILE "lambda 形参缺少类型"`。
- **描述**：`{ m: Map<String, Int64> => m.size > 0 }`、`{ t: (Int64, String) => … }` 这类合法 lambda 会被判为非法；而 `compileLambda` 本身能编过。表 / 脚本作者一改形参类型就遇到与语法无关的报错。
- **建议**：把「按逗号切分」换成按 `<>`、`()`、`[]` 嵌套深度切分；或者干脆让 f_jit 的编译错误成为唯一真源，参数名从编译产物里取（若 `JitFunction` 暴露形参表）。

### [一般][存量] 两套「Or 跨类型展开」并存且边界行为不一致

- **位置**：`f_rule/src/condition/ConditionExpr.cj:122-161`（`ConditionExpr.expand`）与 `f_rule/src/rule/ConditionExpander.cj:34-74`（生产路径）
- **来源**：存量
- **判据**：review-checklist §2（表现形式不同的重复逻辑 / 近似重复）、§11（契约与实现不符）
- **证据**：静态确定 —— 生产调用点只有 `f_rule/src/rule/RuleSetBuilder.cj:165` 的 `ConditionExpander.expand`；`ConditionExpr.expand` 全仓只被 `ConditionExpr_test.cj:63,78` 使用。两者差异：`ConditionExpr.expand` 空 `clauses` 时生成 `Or([])`（恒假，永不匹配且不报错）并把 `typeTag` 置 `""`；`ConditionExpander` 空展开抛 `TABLE_INVALID`，并有 64 条上限与 DNF 分配律展开。
- **描述**：同一语义（按 `typeTag` 把 `Or` 拆成多条规则、id 加 `#N`）有两份实现，编号规则、空输入、嵌套 `And(Or(...))` 的处理都不同。`ConditionExpr.expand` 是对外 `public` API（不能按死代码删），但它与真实构建路径已经漂移，下游若照它写规则会得到与引擎不一致的展开结果。
- **建议**：保留 `ConditionExpr.expand` 作为薄适配层，内部转调 `ConditionExpander`（或在文档中明确标注「仅用于同类型合并且不做 DNF，生产请用 RuleBuilder」）；空输入行为统一为抛 `TABLE_INVALID`。

### [一般][存量] `Loop` 模式 + 默认 `limit = -1` 没有终止保证

- **位置**：`f_rule/src/agenda/agenda.cj:135-198`（`limit` 判断在 `:146`；回堆在 `:184-192`）
- **来源**：存量
- **判据**：review-checklist §11（边界 / 死循环）
- **证据**：静态确定 —— `limit = -1` 时 `limit >= 0` 为假，循环只在 `popValid()` 返回 `None` 时退出；`Loop` 模式下 `index_` 从不删除、执行后必回堆，议程因此永不为空。循环检测默认关闭（`CycleDetection_test.cj:108` 断言 `ruleSet.cycleDetection == false`，需 `enableCycleDetection` 显式开启）。
- **描述**：`setMode(FireMode.Loop)` 后直接 `fire()`（不传 limit）就是死循环，且 `firing_` 一直为真，同会话后续任何 `fire` 都被判为重入；在 `f_egraph` 事件循环里表现为挂死而非报错。文档只写了「`-1` 表示不限制」，没有给出「Loop 必须配 limit」的约束。
- **建议**：`Loop` 模式下若 `limit < 0` 且未配置 `CycleDetector`，构造或 `fire` 时抛 `ILLEGAL_STATE`（或在 `setMode` 里拒绝）；把这条约束写进 `doc/05` §5。

### [一般][存量] `ConditionExpr.validate` 先整树算高度再递归，32 层上限挡不住深层树

- **位置**：`f_rule/src/condition/ConditionExpr.cj:60-87`（`depth()` 调用在 `:61`，递归在 `:67-86`）
- **来源**：存量
- **判据**：review-checklist §4（无界递归 / 检查顺序错误）
- **证据**：静态确定 —— `validate()` 第一句是 `if (depth() > 32)`，而 `depth()`（`:39-57`）本身就是无深度限制的递归；超限异常只有在整棵树走完之后才可能抛出。
- **描述**：代码构造 10^4 层 `Not`/`And` 的条件树（例如按外部配置批量包 `And`）时，`depth()` 先在栈上走完整个高度才轮到 `33 > 32` 的判断，结果仍是栈溢出而不是 `TABLE_INVALID`。另外每层 `validate` 都对子树重新算一次高度，退化为 O(n·h) 的重复遍历。
- **建议**：把深度改成「带当前层级参数的递归」`validate(level: Int64)`，进入时判定 `level > 32` 即抛，不做整树高度预算；删除 `depth()` 的重复调用（`depth()` 可保留为公开查询，但不参与校验）。

### [轻微][存量] 死代码：赋值后未读的局部、两个不可达分支

- **位置**：`f_rule/src/condition/JitExpression.cj:87`（`let body = lambdaBody(trimmed)` 后再无读取）；`f_rule/src/condition/JitExpression.cj:273`（`case None => EvalOutcome.evaluated(false)`）；`f_rule/src/condition/Interpreter.cj:259`（`invoke` 的 `case _ => None`）
- **来源**：存量
- **判据**：review-checklist §1（读了不用 / 恒真恒假分支）
- **证据**：静态确定 —— `of()` 的返回值只用到 `trimmed`/`parameters`/`compiled`；`JitExpression` 的两个字段由构造器保证至少一个非 `None`（`of`/`ofExpression`/`interpreted` 三条路径都传了其中一个），`:273` 不可达；`invoke` 在 `:213-215` 已拒绝非白名单函数，`match` 的 `_` 分支不可达。
- **描述**：无害，但会误导读者以为 `body` 参与编译，也掩盖了「白名单之外的函数名会走哪个分支」的真实路径。
- **建议**：删掉未读局部；两个不可达分支改为 `throw RuleException(ILLEGAL_STATE, ...)` 或加注释说明「由构造器不变量保证不可达」。

### [轻微][存量] 三个枚举各自手写 `toString()` + 字符串判等

- **位置**：`f_rule/src/agenda/agenda.cj:34-48`（`FireMode`）、`f_rule/src/condition/EvalOutcome.cj:30-45`（`EvalFailureKind`）、`f_rule/src/condition/JitExpression.cj:31-44`（`ExpressionMode`）
- **来源**：存量
- **判据**：review-checklist §2（只改类型名的复制）
- **证据**：静态确定 —— 三段代码逐行对齐，唯一差异是构造器名；`==` 都实现成 `this.toString() == other.toString()`，`!=` 都实现成 `!(this == other)`。
- **描述**：判等走字符串比较，比构造器比较多一次方法调用与字符串比较；三处任一处改动（如新增构造器忘记加 `toString` 分支）会连带影响判等语义。不构成缺陷，属可维护性。
- **建议**：`==` 改为 `match ((this, other))` 按构造器比较，或统一由一处 `toString` 映射表驱动；若编译器已能为无参枚举合成 `Equatable`，则直接删掉手写实现（需按 `cangjie-doc-lookup` 核对当前 SDK 的枚举派生规则后再动）。

### [轻微][存量] `Bindings` 与 `JitExpression` 内的临近复制

- **位置**：`f_rule/src/agenda/Bindings.cj:179-193`（`copyHandles`/`copyFacts` 只差类型名）、`:79-91` 与 `:112-120`（`names()`/`size()` 各写一遍并集口径）、`:165-177` 与 `f_rule/src/agenda/agenda.cj:366-382`（两处手写插入排序）；`f_rule/src/condition/JitExpression.cj:357-364` 与 `:381-390`（`interpretFallback` 内联复制了 `lambdaBody`）、`:99-111` 与 `:132-139`（`names`+`dynamic` 扫描两遍）
- **来源**：存量
- **判据**：review-checklist §2（跨文件 / 同文件复制）
- **证据**：静态确定 —— 上述函数体逐行比对一致（仅类型参数或错误兜底不同）。
- **描述**：`interpretFallback` 与 `lambdaBody` 的复制最危险：`lambdaBody` 将来若支持 `=>` 之外的写法（如箭头函数体里的 `}` 处理），兜底路径不会同步。`size()`/`names()` 的并集口径也要两处同时改，否则 `isEmpty()` 与 `names()` 会漂移。
- **建议**：`interpretFallback` 直接调 `lambdaBody(source_)`；`copyHandles`/`copyFacts` 合成一个泛型 `copyMap<K, V>`；`size()` 复用 `names().size`（或两者都基于一个 `keySet()`）；两处插入排序统一用 `std.sort.sortInPlace`（或都收敛到 `Agenda.sortInPlace` 的等价实现）。

### [轻微][存量] 解释器降级告警计数是非原子静态变量

- **位置**：`f_rule/src/condition/JitExpression.cj:62`（`private static var warnings`）、`:294-297`（`warnings += 1`）
- **来源**：存量
- **判据**：review-checklist §12.1（共享可变状态无保护）
- **证据**：静态确定 —— 普通 `static var` 自增，无 `AtomicInt64`、无锁；`warnInterpreter` 在 `ofExpression`/`forRule` 里被调用，即规则构建期。
- **描述**：构建期若多线程同时编译规则（多引擎并发 build），计数会丢自增；`interpretationWarningCount()` 还被 `JitExpression_test.cj:131-142` 当断言基线，跨用例并行时可能抖动。只影响诊断与测试，不影响业务结果，故记轻微。
- **建议**：改为 `AtomicInt64`（与 `Activation.seqCounter` 同做法），或把计数改成实例级并显式注入。

### [轻微][存量] 内置函数边界：`abs`/`round` 溢出抛异常、`length` 类型不符返回 `None`

- **位置**：`f_rule/src/condition/Interpreter.cj:236`（`-n`）、`:243`（`Float64(Int64(n ± 0.5))`）
- **来源**：存量
- **判据**：review-checklist §11（边界 / 溢出）；语言语义见 `dev-guide/source_zh_cn/basic_data_type/integer.md:137`（类型转换溢出按默认溢出策略抛异常）
- **证据**：静态确定 —— `abs(Int64.Min)` 的 `-n` 溢出；`round(1e30)` 的 `Int64(...)` 超出 `Int64` 范围。两者都会在 `invoke` 内抛异常，被 `evaluate` 收成 `RuntimeFailure`。
- **描述**：极端数值下 `abs`/`round` 不返回数值而返回 `Unknown`，与「白名单函数可用」的直觉不符；不会崩进程（异常被收敛），但会让条件静默不成立。
- **建议**：`abs` 用 `if (n == Int64.Min) { ... }` 显式处理；`round` 先判 `n` 是否落在 `Int64` 可表示区间，超范围按 `TypeMismatch` 返回 `None` 并在文档里写明。

### [轻微][存量] 注释与实现不一致：白名单函数数量

- **位置**：`f_rule/src/condition/Interpreter.cj:270`（注释「白名单 10 个函数」）对 `:273-274`（实际 11 个）
- **来源**：存量
- **判据**：review-checklist §13（注释 / 文档与实现不一致）
- **证据**：静态确定 —— 白名单列出 `lower`、`upper`、`trim`、`length`、`abs`、`round`、`now`、`dayOfWeek`、`contains`、`startsWith`、`endsWith`，共 11 个；`doc/03` 的清单在模块其他部分核对。
- **描述**：注释少算一个，容易让后续维护者按「10 个」去对齐文档或测试。
- **建议**：注释改为「11 个」并列出名字（或直接去掉数量，改为「见 `isWhitelisted`」）。

## 优化可行性方案

> 不是缺陷，是"还能更好"。本部分**没有任何 bench / profile 数据**（范围内无 bench 用例、无 `cjprof` 输出），下列全部为 `无基线（待验证）`，不得据此写「降 X%」。编号 `O1`~`O5` 按出现顺序。

### [CPU] 循环检测窗口用 `remove(at: 0)` 当队列头

- **现状**：`CycleDetector.record` 每次记录都 `order_.add(key)`，超窗后 `order_.remove(at: 0)`（`f_rule/src/agenda/CycleDetector.cj:76-88`）。`ArrayList.remove(at: 0)` 需要搬移 `window - 1` 个元素，默认 `window = 10000`，即窗口填满后**每次激活一次 10^4 量级搬移**；`channel` 的 `record` 在 `Agenda.fire` 每个激活前调用一次（`agenda.cj:172-175`）。
- **方案**：换成环形缓冲（`Array<String>(window)` + `head`/`size` 指针），淘汰时 O(1)；`counts_` 逻辑不变。
- **预期**：把每次记录的 O(window) 降为 O(1)，窗口 10000 时单次搬移从 ~10^4 次元素写降到 2 次写。端到端收益取决于循环检测开启比例与激活速率，未测。
- **代价**：多两个字段与取模运算；`reset()` 需同时清指针。
- **验证**：`cjpm bench -O2` 对照「开循环检测 + 10 万次 record」的宏基准，看中位数与离散度；再用 `cjprof` 确认 `ArrayList.remove` 的 self 占比。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] `ConflictKey` 是 class，堆比较每次比较分配 2 个对象

- **现状**：`Agenda.compare` 每次比较都 `resolver_.compare(keyOf(left), keyOf(right))`（`f_rule/src/agenda/agenda.cj:356-363`），`keyOf` 新建 `ConflictKey`；`ConflictKey` 是 `public class`（`f_rule/src/rule/ConflictResolver.cj:24`）。`siftUp`/`siftDown` 每次 O(log n) 次比较 → 每个激活插入/弹出约 `2·log₂n` 次分配，n = 10^4 时约 28 次/操作。
- **方案**：① 把 `ConflictKey` 改为 `struct`（值语义，无分配）；或 ② 在 `Activation` 里预构建并缓存一份 `ConflictKey` 字段，`compare` 直接复用。① 是公开 API 的语义变更（破坏性，需拍板），② 只需改 agenda 包内部。
- **预期**：消除堆操作的绝大多数短命分配，降低 GC 频率；`Activation` 每条多约 40~50 B 常驻（方案 ② 的取舍）。
- **代价**：① 破坏公开类型语义（`ConflictKey` 被外部按引用比较的话会变）；② 每条激活多一份常驻对象。
- **验证**：`cjprof heap` 看 `ConflictKey` 分配量与 GC 次数；`cjpm bench -O2` 跑「10 万次 add+fire」对照。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `Bindings.names()` / `sortKey()` 的并集与排序是 O(n²)

- **现状**：`names()` 先遍历 `facts_`，再遍历 `handles_` 且每个名字线性 `containsName`，最后插入排序（`f_rule/src/agenda/Bindings.cj:79-91,156-177`）；`size()` 又用另一套循环重算同一并集（`:112-120`）。`sortKey()`（`:132-147`）在 `names()` 上做字符串逐段 `+` 拼接，`Activation` 构造时调用一次（`Activation.cj:52`）。
- **方案**：`names()` 改为直接把两个 map 的 key 灌进 `ArrayList` + `sortInPlace`（重复键用一次 `HashSet` 去重），`size()` 复用同一实现；`sortKey` 用 `StringBuilder` 追加，或直接把 `name=identity;` 的哈希值作为 `key_`（判等仍用全串，注意碰撞风险需保留全串）。
- **预期**：绑定数 n 一般等于模式数（2~5），收益有限；只有在宽模式（n ≥ 20）或高频构造激活时可测。**没有数据，不能断言收益**。
- **代价**：多一个 `HashSet` 临时对象；`key_` 改为哈希需评估碰撞与可读性损失。
- **验证**：先用 `cjprof` 确认 `Bindings.sortKey` / `names` 的 self 占比；再用宽模式（n = 32）构造 10^5 个激活的基准对照。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `invalidateGroup` 每次执行都全量扫描议程

- **现状**：`invalidateGroup` 遍历整个 `index_` 找同组激活（`f_rule/src/agenda/agenda.cj:216-231`），每个带 `activationGroup` 的激活执行后调用一次（`:180-183`）。N 个同组激活 → O(N²) 扫描 + `doomed` 临时数组。
- **方案**：在 `Agenda` 内维护 `groups_: HashMap<String, ArrayList<Activation>>`，`add` 时登记、`remove`/失效时惰性清理，`invalidateGroup` 只遍历该组条目。
- **预期**：把每组 O(议程大小) 降为 O(组大小)；决策表 1000 行同组场景理论降幅两个数量级，**但无实测**。
- **代价**：多一份索引的内存与一致性维护（`remove`、`clear`、`popValid` 都要同步）；必须保证「失效位」与「组索引」不漂移。
- **验证**：构造 1 万行同组决策表做 `cjpm bench -O2` 对照；`cjprof` 看 `invalidateGroup` 占比。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 解释器每个节点都读一次墙钟，`And`/`Or` 不做短路

- **现状**：`tick()`（`f_rule/src/condition/Interpreter.cj:103-118`）对每个 AST 节点调用一次 `DateTime.now()`；生产路径 `TerminalNode` 传入的 `failureGuard_.expressionTimeout` 默认是 50ms（`f_rule/src/engine/EngineOptions.cj:27`），即 `deadline` 常态非 `None`。`ConditionExpr.eval`（`ConditionExpr.cj:90-113`）对 `And`/`Or` 不做短路，`result` 已为 `False`（And）/`True`（Or）时仍继续求值后续分支，包括脚本。
- **方案**：① `tick()` 每 64/256 步才检查一次时钟（步数上限仍每步检查）；② `And` 在 `result == Truth.False`、`Or` 在 `result == Truth.True` 时立即返回（三值逻辑下 `False ∧ x = False`、`True ∨ x = True`，与先算全部再折叠结果等价）。
- **预期**：减少每节点一次时钟读取与后续分支的白跑；收益量与表达式平均节点数成正比，未测。
- **代价**：超时判定精度从「每节点」降到「每 64 节点」，需在文档里说明；短路会改变「后续分支脚本是否被执行」的副作用（脚本本身应无副作用，需确认）。
- **验证**：`cjpm bench -O2` 跑 10 万次 `evalDetailed`（50ms 超时开启）对照；`cjprof` 确认 `DateTime.now` 的 self 占比。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `Agenda.compare` 的 `ConflictKey` 分配是议程的主要 GC 来源 | `f_rule/src/agenda/agenda.cj:356` | 分配量占比、GC 次数 | `cjprof heap` 跑 10 万次 add+fire（10k 激活），统计 `ConflictKey` 实例数与 GC 停顿 |
| 2 | `CycleDetector.record` 的 `remove(at:0)` 在窗口满后成为线性热点 | `f_rule/src/agenda/CycleDetector.cj:78` | 单次 record 耗时（窗口 10k） | 微基准：window=10000，record 10 万次，`-O2`，中位数；再对照环形缓冲实现 |
| 3 | 决策表同组互斥导致 `invalidateGroup` O(N²) 是实际瓶颈 | `f_rule/src/agenda/agenda.cj:216` | 组内行数分布、`fire` 总耗时占比 | 用 1 万行同组决策表跑 `cjpm bench -O2` + `cjprof` 分段 |
| 4 | 解释器每节点 `DateTime.now()` 占解释执行耗时的可观比例 | `f_rule/src/condition/Interpreter.cj:113` | 自耗时占比 | `cjprof record` 跑 10 万次 `evalOutcome`（50ms 超时），看 `DateTime.now` 与 `tick` 的 self time |
| 5 | 惰性堆不压实会让「高 churn 低 fire」会话内存线性上涨 | `f_rule/src/agenda/agenda.cj:125` | 真实会话的 assert/retract 与 fire 配比、单条保留字节 | 压测：10 万 assert+retract、不 fire，测 `getUsedHeapSize()` 与 RSS 曲线；再对照压实版 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_rule/src/agenda/Bindings.cj` | .cj | ✅ | 见 §2 重复（copy/并集/排序）与 §5 OOM 相关背景 |
| 2 | `f_rule/src/agenda/Bindings_test.cj` | .cj | ✅ | 覆盖不可变视图与稳定指纹，无缺陷 |
| 3 | `f_rule/src/agenda/ClosureAction.cj` | .cj | ✅ | 仅公开重导出，仓内被 `engine/ScriptAction_test.cj` 经此路径导入 |
| 4 | `f_rule/src/agenda/ConflictResolver.cj` | .cj | ✅ | 见 §1 信息（`ConflictKey` 在 `rule` 包） |
| 5 | `f_rule/src/agenda/ConflictResolver_test.cj` | .cj | ✅ | 覆盖 A-01~A-04，含自定义链插入 |
| 6 | `f_rule/src/agenda/CycleDetection_test.cj` | .cj | ✅ | 覆盖阈值/淘汰/接入议程；默认关闭由 :108 断言 |
| 7 | `f_rule/src/agenda/CycleDetector.cj` | .cj | ✅ | 见优化 §CPU 环形缓冲 |
| 8 | `f_rule/src/agenda/FireError_test.cj` | .cj | ✅ | 覆盖 REENTRANT_FIRE / ACTION_FAILED / 不回滚 |
| 9 | `f_rule/src/agenda/FireMode_test.cj` | .cj | ✅ | 覆盖 Refract / NoLoop / Loop+limit |
| 10 | `f_rule/src/agenda/TableAction.cj` | .cj | ✅ | 仅公开重导出，仓内无引用（对外契约，不判死代码） |
| 11 | `f_rule/src/agenda/agenda.cj` | .cj | ✅ | 见 #S1/#G1/#G2/#G9/#L2/#O2/#O4 |
| 12 | `f_rule/src/condition/ConditionExpr.cj` | .cj | ✅ | 见 #G8/#G10 |
| 13 | `f_rule/src/condition/ConditionExpr_test.cj` | .cj | ✅ | 覆盖 C-06/C-07 与三值折叠 |
| 14 | `f_rule/src/condition/Constraint.cj` | .cj | ✅ | 字段/Bind 右值校验完整，无缺陷 |
| 15 | `f_rule/src/condition/Constraint_test.cj` | .cj | ✅ | 覆盖常量/字段/否定/缺字段/IsNull |
| 16 | `f_rule/src/condition/EvalOutcome.cj` | .cj | ✅ | 见 #L2（枚举三连） |
| 17 | `f_rule/src/condition/Interpreter.cj` | .cj | ✅ | 见 #S1/#S2/#G3/#G4/#G5/#L1/#L6 |
| 18 | `f_rule/src/condition/InterpreterVsJit_test.cj` | .cj | ✅ | 差分用例仅 4 条表达式、5 条事实，未覆盖函数与未知值 |
| 19 | `f_rule/src/condition/JitExpression.cj` | .cj | ✅ | 见 #G6/#G7/#L1/#L3/#L4 |
| 20 | `f_rule/src/condition/JitExpressionMode_test.cj` | .cj | ✅ | 覆盖 usesJit 与一元 `!` 回归 |

合计：`.cj` 20 个 / `.md` 0 个 / 共 20 个，全部读完（本部分清单内无 `.md`；模块 README 与 `doc/**` 在其他部分）。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 9 | 命中 #S1、#G1、#G3、#G4、#G5、#G6、#G7、#G9、#L5；安全性无外部注入面（无 SQL / 无 shell / 无凭据） |
| §1 死代码 | 1 | 逐个核对了 `agenda.cj` 的 10 个 private 方法与 8 个字段、`Bindings` 的 6 个 private 静态方法、`Interpreter` 的内部 enum/parser 全部成员、`JitExpression` 的 8 个 private 方法，均有调用者；唯一命中是 `JitExpression.of` 里赋值后未读的 `body`（#L1）。`public` 声明（`Bindings.adopt/of/ofFacts/merged`、`Agenda.setMode/invalidateGroup`、`InterpreterProgram.eval`、`TypedClause.typeTags`、`JitExpression.interpretationWarningCount`）按硬原则一不判死代码，仅记录仓内引用情况：`merged`/`of`/`typeTags`/`setMode`/`InterpreterProgram.eval` 仓内只有测试或无引用 |
| §2 重复逻辑 | 3 | 同类比对范围：本部分 20 个文件内全部函数体的「输入→输出→副作用」；另按错误消息、白名单字面量、正则跨文件搜。命中 #G8（两套 Or 展开）、#L2（三个枚举的 `toString`+字符串判等）、#L3（`Bindings` 的 copy/并集/插入排序 + `JitExpression` 的 `interpretFallback`/`lambdaBody` 逐行复制 + `names`/`dynamic` 扫描两处复制）。`ConflictCompare.desc/asc` 三个小函数属「为可读性刻意展开」，不计 |
| §3 空实现 | 0 | `NoopRunner`（`agenda.cj:73-80`）是显式 Null Object 且有注释说明；无 `TODO`/`FIXME`/`UnsupportedException`；`catch` 均有归类或上抛，唯一「空」是 `EvalFailureKind` 分类兜底（有明确语义） |
| §4 栈溢出 | 2 | #S2（解析器，外部输入可达）、#G10（`ConditionExpr.depth` 先递归后判限）。`ConditionExpr.eval`/`validate` 的递归深度受 32 层限制（#G10 顺序问题除外）；`CycleDetector`/`Bindings` 无递归 |
| §5 OOM | 1 | #G2（惰性堆不压实）。`CycleDetector.order_` 受 `window` 约束、`counts_` 受窗口内不同指纹数约束、`lastFired_` 每次 `fire` 清空，均有界；`InterpreterProgram` 的 AST 规模受 `maxNodes` 约束 |
| §6.1 热点瓶颈 | 0 | 无 `cjprof` / `cjpm bench` 数据，范围内也无 bench 用例；未成立热点，5 条线索已转「待验证假设」 |
| §6.2 大粒度锁 | 0 | 本部分代码不含任何锁（`Agenda`/`CycleDetector`/`Interpreter` 均无 `synchronized`/`Mutex`）；并发问题表现为「无同步」而非「锁太大」，见 #G1 |
| §6.3 并发串行 | 0 | 无 `spawn` / `Future` / 线程池使用 |
| §6.4 低效算法 | 0 | 有 3 处复杂度可疑（`remove(at:0)`、`invalidateGroup` 全扫描、`ConflictKey` 每次比较分配），因缺实测数据按规则移入「优化可行性方案」与「待验证假设」，不记为发现 |
| §7 降堆内存方案 | 1 | [堆内存] `ConflictKey` 去分配；另 #G2 的压实建议本身即内存修复（计入发现） |
| §8 降 CPU 方案 | 4 | 环形缓冲、`Bindings` 名称/指纹、组索引、解释器 tick 降频 + 短路 |
| §9 local mode 可行性 | 0 | 本部分无「函数内创建、函数内消费」的大中间结构：`Bindings`/`Activation`/`EvalOutcome` 全部逃逸到议程或返回值，`InterpreterExpr` AST 在构建期一次性存活；且无峰值内存基线，按约束不能给方案 |
| §11 现有代码的 BUG（存量） | 18 | 本部分全部 18 条发现均为存量（快照模式无基线）；已核对 `Agenda.fire` 的 limit/重入/异常路径、`popValid`/`popHeap` 的边界、`Bindings.size/names` 的并集口径、`Constraint.eval/validate` 的空值与字段校验、`Interpreter` 的 11 个白名单函数与解析器边界、`JitExpression` 的四条构造路径 |
| §12 并发安全与锁粒度 | 3 | #S1（解释器实例状态跨会话共享）、#G1（Agenda 无同步 + 非原子 `firing_`）、#L4（`warnings` 静态计数器非原子）。已给出共享路径（`ShardedNetwork.shared` → `TerminalNode.scripts_`；`RuleEngine.session(id)` → 同一 `RuleSession`） |
| §14 功能完备性与 README 覆盖 | 0 | 本部分清单不含 `.md`，README 与 `doc/**` 的对照在模块其他部分完成；代码侧未见「声明了但没接线」的 public API（`TableAction` 重导出属对外契约，非缺失） |
| 文件覆盖（§13 等） | 20/20 | 无缺失，无跳过文件；本部分无 `.md`，故 §13 无适用对象 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 2 |
| 一般 | 10 |
| 轻微 | 6 |
| 优化方案（堆内存 / CPU） | 1 / 4 |

存量缺陷 18 条（本部分全部为存量），是否纳入修复待用户决定。

## 总评

本部分（agenda 的绑定表 / 冲突消解 / 循环检测 / 议程执行，condition 的条件树 / 约束 / 解释器 / JIT 表达式）整体结构清晰：议程用惰性二叉堆 + 有效性索引，冲突消解用可组合的全序解析器，条件求值把三值逻辑集中在 `Truth`，异常收敛到 `EvalOutcome` 并有失败计数与自动禁用，这些设计是对的，注释与判据（doc/05、doc/03 的节号）也对得上。

阻塞项有两条，都在 condition 包：

1. `InterpreterProgram` 把 `steps`/`deadline` 放在实例字段上，而该实例通过 `ShardedNetwork.shared` 的共享结构被多会话共享 —— 默认 50ms 超时下每个节点都在读写这两个字段，并发求值会互相重置步数和截止时间，既是数据竞争，也让步数上限失效。这是结构性问题，建议本轮就改（改为求值局部状态，改动集中在 `Interpreter.cj` 一个文件）。
2. 表达式解析器递归下降没有深度上限，`maxNodes` 数不到括号层数，而脚本来源可以是决策表 / Excel 的 `expr` 列 —— 一条深括号表达式就能把进程打崩。加一个 `depth` 计数即可，成本很低。

其余一般项属于「静默失效」类：白名单函数不校验 arity、`contains` 系列把 `Unknown` 压成 `false`（`!` 之后变真）、多级字段路径被截断、`interpretFallback` 逐次重编译并静默降级、`parseLambdaParameters` 按逗号盲切。它们不会崩，但会让规则「看起来配了却不触发」，且都缺乏对应用例（`InterpreterVsJit_test` 只有 4 条表达式、5 条事实，没覆盖函数与未知值），建议补一组函数/未知值/错误表达式的差分用例后再修。

`Agenda` 侧的风险是并发契约缺失（同 id 会话共享同一实例但无同步）与惰性堆不压实导致的内存保留，前者需要先定线程模型再谈改法，后者可以在不动语义的前提下加压实。性能与内存的 5 条方案全部没有基线，只能作为下一轮补数据的清单，不进 `tasks.md`。
