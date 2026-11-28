# f_rule 模块审查报告（模块第 6/12 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_rule`（本部分 20 个源文件：`.cj` 20 个 / `.md` 0 个；模块整体 184 个 `.cj` + 33 个 `.md`）
- **基线**：工作区快照（sts/1.3.x，无 diff 可比，全部问题记「存量」）
- **审查重点**：规则引擎求值正确性、递归与栈溢出、OOM、死代码、重复逻辑、并发安全、存量 BUG
- **报告版本**：v1（模块第 6/12 部分，仅覆盖 `files/f_rule.part6.txt` 列出的文件；不产出 `docs/review/` 模块报告）

## 发现

### [严重] [存量] 事实存储路径完全没有同步，与文档承诺的「线程安全 / 分段锁」相反

- **位置**：`f_rule/src/fact/FactBase.cj:28`（类声明）～`:89`（`assert`）、`:112`（`retract`）、`:128`（`update`）；`f_rule/src/fact/FactBaseView.cj:182`（`FactBaseViewStore`）、`:192`（`view`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §12.1（共享可变状态无保护 / 检查-然后-写入）、§11（契约与实现不符）
- **证据**：静态确定 —— 在 `f_rule/src/**/*.cj` 全量检索 `Mutex|synchronized|ConcurrentHashMap|Atomic`，`fact/` 包内只有 `fact.cj:60` 的 `FactIdentity` 计数器带锁；`FactBase` 的 6 个可变容器（`buckets_` / `slots_` / `dead_` / `facts_` / `byIdentity_` / `looseFacts_`，`FactBase.cj:32`-`:39`）与 `FactBaseViewStore.views_`（`FactBaseView.cj:184`）一律裸 `HashMap` / `ArrayList`。而承诺源写的是：`f_rule/doc/01-architecture.md:187`「事实插入｜多线程｜`FactBase` 按空间独立分段锁；同一 `(space, typeTag)` 的桶串行」、`f_rule/doc/08-api.md:25`「`FactBase` / `FactBaseView` … 线程安全：是」。生产调用链 `RuleSession.assert`（`engine/RuleSession.cj:164`-`:175`）与 `RuleSession.factsOf`（`:148`-`:150`）也没有任何锁，直接把 view 交给调用方。
- **描述**：按文档，同一 `(space, session)` 会被多线程并发插入 / 撤回。此时两个线程同时执行 `FactBase.assert` 会在 `values` 层并发写同一个 `HashMap`（Cangjie 标准容器非线程安全），后果是桶与 `slots_` 索引不一致、条目丢失甚至容器内部结构损坏；`FactBaseViewStore.view`（`FactBaseView.cj:192`-`:209`）是典型检查-然后-写入，两个线程可各建一个 `FactBase`，后写者覆盖前者，先插入的事实彻底不可见。`FactBase.scan` 还会在只读路径写 `dead_`（见轻微项），进一步扩大竞态面。
- **建议**：二选一并同步文档。① 按文档补「每 `(space, typeTag)` 一把锁」：把 `buckets_`/`slots_`/`dead_` 收进一个带锁的分段结构，`facts_`/`byIdentity_` 用独立锁或整体改成 `ConcurrentHashMap`；`FactBaseViewStore.view` 用 `synchronized` 或「先放后取 + 相等则复用」。② 若确定单线程使用，删掉 `08-api.md` 的「是」与 `01-architecture.md:187` 的分段锁描述，并在 `RuleSession` 文档里写明「同 session 不允许多线程并发写」，同时给 `FactBase` 加显式断言（debug 下校验线程）。

### [严重] [存量] 嵌套 / 自引用 `Array<Any>` 的递归无深度上限，可栈溢出

- **位置**：`f_rule/src/fact/DynamicFact.cj:131`（`checkValue` 递归，递归点在 `:141`/`:145`/`:149`）；`f_rule/src/fact/ValueKey.cj:96`（`of`）、`:156`（`listOf`）、`:216`（`compare` → `compareList` `:381`）、`:283`（`hashCode`）、`:306`（`encode`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §4（无界递归 / 自引用结构 / 每层分配）、§5（递归 + 每层分配）
- **证据**：静态确定 —— 三处递归都以「集合元素」为递归入口，且全程没有深度计数、没有访问集合做环检测。
- **描述**：`DynamicFact.set` 先走 `checkValue` 递归校验；`Array<Any>` 是可变的，调用方可以直接构造自引用（`let a: Array<Any> = Array<Any>(1, repeat: 0); a[0] = a`）或深嵌套（循环 10 万层 `[[[…]]]`）。前者在 `set` 时无限递归，后者在约 10^5 层时爆栈；`ValueKey.of` / `compare` / `hashCode` / `encode` 对同一结构重复这套递归，因此「校验通过 → 建索引」的每一步都会再爆一次。崩溃而非变慢，且发生在事实写入主路径上，`RuleException` 无法拦截。
- **建议**：`checkValue` / `ValueKey.of` 增加 `depth: Int64 = 0` 参数与上限常量（如 32），超限抛 `RuleException(TYPE_MISMATCH, "值嵌套超过 N 层")`；`compare`/`hashCode`/`encode` 接收已归一好的 `ValueKey` 树，不再对原始 `Any` 递归；同时把 `KeyValue.ListValue` 的嵌套深度作为不变量写入类型注释。

### [一般] [存量] `FlowContext` 静态会话表无界增长：生产路径没有任何 `release` 调用，`Retain` 也没有 TTL

- **位置**：`f_rule/src/flow/FlowContext.cj:66`-`:70`（`contexts` / `registries` 静态表）、`:142`（`create` 只增不减）、`:156`（`release`）、`:174`（`Retain => ()`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §5（无界容器 / 缓存键无界）、§14.1（承诺了但没实现 / 接线缺失）
- **证据**：静态确定（仓内调用点）+ 待确认（下游是否自行调用）—— 全模块检索 `FlowContext.release`，命中只有 `flow/FlowContext_test.cj:142`、`:157`、`:172`；唯一的生产调用方 `flow/RuleTask.cj:71`-`:83` 只有 `attach` + `finally { detach() }`，`detach` 明确「不释放会话」（`FlowContext.cj:136`-`:139`）。承诺源：`f_rule/doc/06-flow-orchestration.md:334`-`:342` 的生命周期图写着「流程 End / Error → `FlowContext.release(session)`」，`:350` 写着「`Retain` 保留 N 分钟，支持流程重入/补偿（需要定时清理）」；实现里 `Retain` 分支是空语句，没有计时、没有定时器、也没有对外的按会话清理入口（只有测试用的 `resetForTest`，`:215`）。
- **描述**：每个新 session 都会在 `contexts` 里留下一个 `FlowContext` → `FactBaseViewStore` → `FactBase` → 全部事实，键是 `(ruleSetId, session)`，永不淘汰。按文档推荐「一请求一 session」的用法，堆占用随请求数单调增长，直到 OOM；`Retain` 更是按设计就要求长期保留，却没有文档承诺的 N 分钟回收。`registries` 同样只增不减（每个 ruleSetId 一份，`RuleSet` 重建即残留）。
- **建议**：① 让 `RuleTask`（以及 `RuleFlow` 的结束事件处理）在会话结束时调用 `FlowContext.release(session, policy: engine.options.release)`；② 为 `Retain` 落地 TTL：`contexts` 值加 `retainUntil`，用 `f_ticktock` 定时扫描（与 `JoinTask` 超时同一套机制），或至少提供 `releaseExpired(now)` 供宿主定时调用；③ 给 `contexts` / `registries` 加容量上限与告警指标（`f_rule` 已有可观测钩子的先例，见 `RuleSet.ruleFailureCount`）。

### [一般] [存量] `Release.Archive` 的三条失败路径都会静默丢数据，或在异常时泄漏整个会话

- **位置**：`f_rule/src/flow/FlowContext.cj:248`（`archiveFacts`）、`:252`-`:254`（`archiver_ == None` 直接返回）、`:255`（在 `ctx.viewLock` 内归档）、`:269`（调用外部 `archiver.archive`）、`:172`-`:180`（`release` 里 `archiveFacts` 之后才 `releaseViews`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §3（静默吞掉 / 开关打开后走空分支）、§11（资源释放不对称）、§6.2 / §12.2（锁内调用外部回调与 I/O）
- **证据**：静态确定（代码路径）+ 需实测（持锁时长）
- **描述**：三个问题同源：① 选了 `Archive` 但没 `setArchiver`，`archiveFacts` 走 `case None => ()`，事实被直接丢弃且无日志、无异常 —— 用户以为落盘了；② `archiver.archive`（外部实现，通常是 DB / 文件 I/O）在 `synchronized(ctx.viewLock)` 内调用，单条归档慢就阻塞同会话全部 `factsOf` / `spaces` 调用，持锁时长完全由外部实现决定；③ `release` 先 `archiveFacts` 再 `releaseViews`，`archiveFacts` 抛异常时 `releaseViews` 不执行，而此时 `contexts` 已经从静态表里删掉（`:166`-`:170`），这批事实既不在表里也没释放，成为不可达的堆占用，异常还会中断 `victims` 循环，后续会话同样不释放。
- **建议**：① `Archive` 且 `archiver_ == None` 时抛 `RuleException(ILLEGAL_STATE)`（或至少 `WARN` 日志 + 计数），不要静默；② 归档移出锁：先在锁内 `scan` 出 `(space, handle)` 快照与事实引用，出锁后再逐条调 `archive`；③ `release` 每个 victim 用 `try { archiveFacts } finally { releaseViews }`，并让单个 victim 的异常不阻断其余 victim（收集异常后统一抛）。

### [一般] [存量] `FactHandle` 只按 `(space, id)` 判等，`retract` / `update` 不校验 session 与 `typeTag`，可误删事实或留下悬挂桶项

- **位置**：`f_rule/src/fact/fact.cj:91`-`:98`（`hashCode` / `==` 忽略 `typeTag` 与 session）；`f_rule/src/fact/FactBase.cj:44`（`nextId_` 每个 base 从 1 开始）、`:112`-`:120`（`retract`）、`:128`-`:148`（`update`）、`:216`-`:242`（`removeFromBucket`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（边界 / 契约与实现不符：`fact.cj:77`-`:78` 自己写明「id 只在同一 `(space, session)` 内唯一」，相等性却只用 `(space, id)`）
- **证据**：静态确定 —— `FactHandle` 是 `public` 且 `public init`，任何调用方都能构造；`facts_.remove(handle)` / `facts_.get(handle)` 只按 `(space, id)` 命中。
- **描述**：两条可达路径：① 跨会话：session A 与 session B 在同一 space 各自从 id=1 分配，把 A 的句柄传给 B 的视图（`RuleSession.retract` 只用 `handle.space` 定位会话内的 base，`engine/RuleSession.cj:179`），`retract` 会把 B 中 id 相同的**另一条事实**删掉并返回 `true`；② `typeTag` 不符：`retract` 在 `facts_` 里按 id 命中了事实，但 `removeFromBucket` 用 `handle.typeTag` 去取桶（`:217`/`:222`/`:224`），墓碑记到了错误的桶上，真实桶里那个槽位既没被标死也没被整理，于是 `scan` 继续返回一个 `get()` 为 `None` 的句柄，下游 alpha/beta memory 会看到「有句柄无事实」。测试 `FactBaseView_test.cj:74` 只覆盖了「目标会话为空」的情形，给出的是假安全感。
- **建议**：`FactHandle` 增加 `session`（或 `(space, id, session)` 三元组参与相等性），`FactBase.retract` / `update` 先校验 `handle.session == session_` 且 `handle.typeTag == facts_[handle].typeTag`，不符返回 `false` / 抛 `ILLEGAL_STATE`；`removeFromBucket` 用事实自身的 `typeTag` 而不是句柄的。

### [一般] [存量] `assert` 与 `assertCopy` 的字段处理不对称，同一事实经两条路径得到不同字段集与不同判重语义

- **位置**：`f_rule/src/fact/FactBase.cj:71`-`:89`（`assert` 只校验 `hasType`，不校验字段）、`:92`-`:109`（`assertCopy` 用描述符字段重建 `DynamicFact`）、`f_rule/src/fact/FactBaseView.cj:112`-`:120`（`assert` / `copyTo` 分别走两条路径）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2（近似重复导致行为漂移）、§11（缺少边界校验）
- **证据**：静态确定 —— `assert` 全程不读 `space_.descriptor(...)`；`assertCopy` 只遍历 `desc.fieldNames()`（`:102`-`:107`），描述符外的字段被静默丢弃。
- **描述**：`DynamicFact` 的 `set` 允许任意字段名，`FactBase.assert` 只查类型标签，于是「未在空间声明的字段」可以写进事实库：条件里对它的引用永远取不到值，拼写错误也不会报 `UNKNOWN_FIELD`。同一条事实改走 `assertCopy` 又会把这些字段删掉，且因为副本是新的 `DynamicFact`（新 identity），判重从「实例身份」退化成「字段快照」——`copyTo`（`FactBaseView.cj:118`）因此允许把同一事实物化多份而 `assert` 会拒绝。两条路径对「哪些字段是合法字段」给出相反答案。
- **建议**：`assert` 与 `assertCopy` 共用同一段字段校验（抽 `validateAgainstDescriptor(fact)`）：字段必须 ⊆ `fieldNames(typeTag)`，否则抛 `UNKNOWN_FIELD`；字段类型与 `FieldType` 不符时抛 `TYPE_MISMATCH`。`assertCopy` 在注释里写清「identity 不随复制传递」，避免调用方以为判重口径一致。

### [一般] [存量] `assertCopy` 只做浅拷贝，`Array` / `ArrayList` / `Set` 字段仍与调用方共享，冻结后照样能被改

- **位置**：`f_rule/src/fact/FactBase.cj:101`-`:107`（`copy.set(field, value)` 直接搬运 `Any`）；`f_rule/src/fact/DynamicFact.cj:106`-`:108`（`freeze` 只置布尔）、`:131`-`:157`（允许 `Array<Any>` / `ArrayList<Any>` / `ReadOnlySet<Any>`）；`f_rule/src/fact/fact.cj:23`-`:24`（`Fact` 契约：进入网络后 `get` 的返回值不再变化）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（语义与注释不符：`FactBase.cj:91`「拷贝字段后插入：用于可变业务对象，避免网络索引跟着原对象变化」）、§10（值 / 引用语义）
- **证据**：静态确定 —— Cangjie 的 `Array` / `ArrayList` 是引用类型；`copy.set(field, value)` 存的是同一个引用；`freeze()` 只阻止 `set`/`remove`，不阻止已存容器内部元素的写入。
- **描述**：`assertCopy`（以及 `copyTo`）承诺「字段快照」，实际只快照了标量字段。`fact.set("items", arr)` 之后继续 `arr[0] = ...`，库内事实、alpha 索引里已归一好的 `ValueKey`、beta memory 的记录会互相矛盾：索引按键命中，取值却是新值，产生假命中 / 漏命中。`DynamicFact.freeze` 的注释（`DynamicFact.cj:105`）说「之后 `set`/`remove` 抛 `ILLEGAL_STATE`」，从容器角度看这个不变式并不成立。测试 `FactBase_test.cj:165`-`:181` 只验证了标量字段 `amount`，掩盖了该问题。
- **建议**：`assertCopy` 对集合字段做一次浅复制（`Array` → `clone`、`ArrayList` → 新 `ArrayList`、`Set` → 新集合），并在 `Fact` 契约里写明「集合值在事实生命周期内必须视为不可变」；若允许 `ArrayList`/`Set` 作为字段值，至少在 `freeze()` 时把它们替换成不可变视图（或直接移除这两类支持，只留 `Array` 并深拷）。

### [一般] [存量] `update(handle, 同一实例)` 对非 `IdentifiedFact` 抛 `DUPLICATE_FACT`，对 `TypedFact`/`DynamicFact` 正常返回，行为随实现类型漂移

- **位置**：`f_rule/src/fact/FactBase.cj:140`（`ensureNotDuplicate(fact, Some(handle))`）、`:273`-`:301`（`ensureNotDuplicate`）、`:244`-`:249`（`recordIdentity` 把非 identified 事实塞进 `looseFacts_`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（边界 / 契约与实现不符：`update` 注释为「等价于 retract + assert」）
- **证据**：静态确定 —— identified 分支用 `byIdentity_.get(identity)` 与 `replacing` 的句柄比较，相等则放行（`:276`-`:287`）；非 identified 分支遍历 `looseFacts_` 只做 `sameReference`（`:290`-`:299`），而 `looseFacts_` 里此刻仍持有 `old`（`facts_[handle]` 要到 `:142` 才被替换，`forgetIdentity` 在 `:143`）。
- **描述**：业务方自定义 `Fact` 实现（不实现 `IdentifiedFact`）时，`update(handle, 原实例)` 这种「无变化更新」会命中 `looseFacts_` 中的旧实例并抛 `DUPLICATE_FACT`；`json/csv` 驱动的批量刷新若原样回写就会整批失败。同一调用对 `TypedFact` / `DynamicFact` 却是合法 no-op（返回 `true`），因为它们的 identity 相同且映射到同一句柄。
- **建议**：`ensureNotDuplicate` 的 `replacing` 分支对非 identified 事实也做「引用等于当前 `facts_[handle]` 则放行」，或把 `forgetIdentity(old)` 提到 `ensureNotDuplicate` 之前（先摘旧记录再判重）。

### [一般] [存量] `TypedFact.get` 把可空 getter 的 `None` 包成 `Some(None)`，违反 `Fact.get` 契约

- **位置**：`f_rule/src/fact/TypedFact.cj:55`-`:60`；契约在 `f_rule/src/fact/fact.cj:29`（「字段不存在返回 None；字段存在但值为空也应返回 None」）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（契约与实现不符）
- **证据**：静态确定 —— `get` 无条件 `Some(getter(value))`，getter 的返回类型是 `Any`，若宿主字段是 `?Int64`，`Some(None<Int64>)` 会成为 `Option<Any>` 的 `Some` 分支。
- **描述**：宿主类的可空字段（业务里很常见）在事实层表现为「存在且值为 None」，与 `has()` 的语义叠加后产生三态混乱：`has("x") == true`、`get("x").isSome() == true`，而取出的值不是标量。下游 `ValueKey.of` 会因 `Option` 不在白名单抛 `TYPE_MISMATCH`，使一条正常的可选字段直接让条件求值失败（还会被 `ExpressionFailure` 之类路径吞成规则不命中）。
- **建议**：`get` 内先判 `None`：`match (getter(value)) { case v: Option<Any> ... }` 无法直接做到，最简做法是约定注册的 getter **不得**返回 `Option`（在 `FactSchema.field` 处用 `TypeInfo` 校验返回类型不可为 `Option` 并抛 `TYPE_MISMATCH`），或提供 `nullableField(name, getter: (T) -> ?Any)` 重载把 `None` 透出。

### [一般] [存量] 同形状重复注册保留首个宿主类，`hostTypeName` / `hostSimpleName` 静默忽略，JIT 形参类型可能与实际对象不符

- **位置**：`f_rule/src/fact/FactSpace.cj:179`-`:192`（`addDescriptor`：`Some(existing)` 只做形状校验，不更新描述符）、`:64`-`:80`（`sameShape` 只比字段名与 `FieldType`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（契约缺失）、§10（正确性）
- **证据**：静态确定（描述符不更新）+ 待确认（JIT 侧后果需要具体注册组合）—— `condition/JitExpression.cj:168` 用 `descriptor.hostSimpleName` 拼脚本形参类型，`table/TableCompiler.cj:136` 同样使用该字段。
- **描述**：两个不同宿主类用同一个 `typeTag`、同字段同类型注册时（例如 `OrderV1` 与 `OrderV2` 都叫 `"Order"`），第二个被当成「幂等重复注册」接受，但描述符仍是第一个的 `hostSimpleName`。之后传入 `OrderV2` 的事实，JIT 表达式按 `OrderV1` 编译形参，运行期取值要么类型不匹配、要么读到错字段。这类错误在构建期完全没有提示，比抛 `DUPLICATE_TYPE` 更难排查。
- **建议**：`sameShape` 追加「`hostTypeName` 一致（或两者都为空）」的判定，不一致抛 `DUPLICATE_TYPE` 并给出两个类名；确实需要「同形不同类」时要求显式 `registerAlias(typeTag, hostType)`。

### [一般] [存量] `commitToParent` 不是原子操作，且用「捕获 `DUPLICATE_FACT`」实现幂等

- **位置**：`f_rule/src/fact/FactBaseView.cj:149`-`:174`（`commitToParent`，`try` 在 `:160`-`:167`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（错误处理缺失 / 部分成功）、§6.4（异常当控制流，性能面见待验证假设）
- **证据**：静态确定 —— 循环内逐条 `parent.base_.assert(fact)`，只捕获 `DUPLICATE_FACT`，其他 `RuleException`（如父视图空间未注册该类型时的 `UNKNOWN_TYPE`）直接冒泡；已在父视图提交过的条目不会回滚。
- **描述**：子视图有 100 条事实、第 57 条因类型未注册失败时，父视图留下 56 条半提交事实，子视图与父视图从此不可区分地「各有一半」，重试提交又会重复走异常路径。幂等判定依赖「父视图已持有同一实例」，对 `TypedFact` 成立（同一对象），但父视图若先提交了等价的另一实例则不会去重（identity 不同），可产生重复事实。
- **建议**：先在子视图内做一次可失败的预检（类型/字段都已校验，理论上不应失败，失败即视为内部错误并整体回滚：记录本次新增的句柄，异常时逐个 `parent.base_.retract`）；幂等改成显式查询（父视图 `byIdentity` 或 `scan` 后比对字段），不要用异常做控制流。

### [轻微] [存量] `ValueKey.compare` 的 `case _ => Ordering.EQ` 是永不命中的兜底，未来新增变体会静默判等

- **位置**：`f_rule/src/fact/ValueKey.cj:240`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §1（恒假分支 / 被前面 case 完全覆盖）
- **证据**：静态确定 —— `domain` 相同意味着 `rank` 相同，Number 域的 3 个变体 9 种组合在 `:227`-`:235` 全部枚举，Text/Bool/Time/List 各有分支，`_` 分支不可达。
- **描述**：索引的正确性依赖 `compare` 是全序；这里用「兜底判等」收尾，一旦 `KeyValue` 新增变体（例如 `Blob`），新变体会与任意同域值「相等」，跳表会静默丢键而不报错。
- **建议**：兜底改为 `throw RuleException(ILLEGAL_STATE, "compare 未覆盖的组合")`，或删除兜底让编译器在新增变体时报穷尽性错误。

### [轻微] [存量] 三组「只改类型名」的重复分支：集合归一 / 集合校验 / get-or-create

- **位置**：`f_rule/src/fact/ValueKey.cj:110`-`:123`（`Set<Any>` 与 `ReadOnlySet<Any>` 两块体逐行相同）；`f_rule/src/fact/DynamicFact.cj:139`-`:150`（`Array` / `ArrayList` / `ReadOnlySet` 三段递归体相同）；`f_rule/src/fact/FactBase.cj:185`-`:213`（`bucket` / `slotIndex` / `deadOf` 三个 get-or-create 同构）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2（只改类型名 / 字面量复制）
- **证据**：静态确定 —— `std.collection` 里 `Set<T> <: ReadOnlySet<T>`（`collection_package_interface.md:975`），因此 `ValueKey.cj:110` 的分支被 `:117` 完全覆盖，属于冗余重复；另两组的差异只有容器类型。
- **描述**：同一语义写三份，任何一处加规则（例如 `:110` 分支补 `dedup` 或补深度限制）都会漂移。`ValueKey` 的重复还多一层风险：`of` 的归一逻辑与 `DynamicFact.checkValue` 的白名单必须同步维护，目前 `checkValue` 接受 `DecimalNumber` 但 `ValueKey.of` 也接受，尚无差异，但没有任何机制保证。
- **建议**：`ValueKey` 删掉 `Set<Any>` 分支（`ReadOnlySet` 已覆盖）；`checkValue` 的三段合并为一个 `case items: ReadOnlySet<Any>` + 一个数组/列表分支；`FactBase` 的三个 helper 抽成「`HashMap<K, V>` 取值或建值」的私有泛型函数（`mut` 参数或闭包）。

### [轻微] [存量] `FactBase.scan` 在只读路径写入 `dead_`（读操作产生状态副作用）

- **位置**：`f_rule/src/fact/FactBase.cj:160`（`let dead = deadOf(typeTag)`）、`:205`-`:213`（`deadOf` 无则新建并写入）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（副作用不对称，只读查询不应修改状态）
- **证据**：静态确定 —— 只要该类型有过桶（`buckets_` 命中），`scan` 就会往 `dead_` 插入一个空 `HashSet`。
- **描述**：`scan` 被 alpha 传播、`FactBaseView.size`、`commitToParent`、`FlowContext.archiveFacts` 反复调用；给只读查询加写操作既让「scan 可以并发」这件事彻底不可能（见严重项 1），也让 `dead_` 的条目数取决于「调用过 scan 的类型数」而不是「发生过撤回的类型数」，语义上多了一类无用状态。
- **建议**：`scan` 里改成 `match (dead_.get(typeTag)) { case Some(d) => d, case None => 不跳过任何槽位 }`，只在 `removeFromBucket` 里创建 `dead_` 条目。

### [轻微] [存量] `FactSpaceRegistry.declare` 冻结后对已存在 id 静默返回，与自身注释「冻结后抛 `NETWORK_FROZEN`」相反

- **位置**：`f_rule/src/fact/FactSpaceRegistry.cj:43`（注释）、`:44`-`:59`（先返回已存在、后判 `frozen_`）；对照 `f_rule/src/fact/FactSpace.cj:115`-`:124`（`register` 先 `ensureMutable`，冻结后即使完全一致也抛）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（语义与注释不符）、§2（两个入口策略不一致）
- **证据**：静态确定 —— `declare` 的 `spaces_.get(id)` 命中即在 `:46` return，`frozen_` 检查在 `:49` 之后。
- **描述**：同一条「冻结后不得声明空间」的规则在注册表与空间两个层级行为相反：`registry.declare("orders")`（已存在）静默成功，`space.register(sameSchema)` 抛 `NETWORK_FROZEN`。测试 `FactSpaceRegistry_test.cj:54` 只测了新 id，没有覆盖这个分叉。副作用是运行期误调用 `declare` 不会暴露装配顺序问题。
- **建议**：把 `frozen_` 检查提到存在性判断之前，或把注释改成「已存在的空间在冻结后仍可重复声明（无副作用）」，并在 `FactSpace.register` 侧选择同一策略。

### [轻微] [存量] `ValueKey` 的 NaN 归一没有规范哈希，`compare` 判等但 `hashCode` 可能不等

- **位置**：`f_rule/src/fact/ValueKey.cj:132`-`:144`（`realNumber` 对 NaN 直接返回 `RealNumber(v)`）、`:350`-`:361`（两个 NaN 判 `EQ`）、`:283`-`:299`（`RealNumber` 用 `v.hashCode()`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（`==` 与 `hashCode` 必须自洽，否则 `HashMap` 索引失效）
- **证据**：待确认 —— 需要确认 `Float64.hashCode()` 是否把所有 NaN 归一到同一值；若按 bit pattern 计算，两个不同来源的 NaN（`0.0/0.0` 与 `Float64.NaN`）会「相等但哈希不同」。
- **描述**：`compare` 把 NaN 定义为「小于任何非 NaN、两个 NaN 相等」，是索引的全序基础；但哈希没有同步规范化。若假设成立，`HashMap` 索引里用 NaN 当键的事实会查不到，`RangeIndex` 与哈希索引给出不同答案。
- **建议**：`realNumber` 把 NaN 归一成一个固定表示（例如 `KeyValue.RealNumber(Float64.NaN)` 并让 `hashCode` 对 NaN 返回常量），并在 `ValueKey_test` 补一条「两个不同来源的 NaN 相等且同 hash」的用例。

## 优化可行性方案

> 以下均为「还能更好」，没有改前 / 改后对照数据，全部标 `无基线（待验证）`，不进 `todo.md` / `tasks.md`。

### [堆内存] 会话结束后一次性释放 `FactBase` 的容器容量，而不是只清元素

- **现状**：`FactBase` 的 `buckets_`（`ArrayList<FactHandle>`，每个已用类型一条）、`slots_`、`facts_`、`byIdentity_`、`looseFacts_` 只增不减；`retract` 只做墓碑标记（`FactBase.cj:216`-`:242`），`clear()`（`:176`-`:183`）清元素但不还容量。按 `FactBaseViewStore.release` 的现有路径（`FactBaseView.cj:212`-`:223`）整个 `FactBase` 会被丢弃，所以当前只在「长会话 + 大批量撤回」时留下容量；若后续引入会话复用，则峰值容量会长期驻留。
- **方案**：`FactBase.clear()` 之后重建容器（`buckets_`/`slots_`/`dead_` 换成新实例），或在 `FactBaseViewStore.release` 里直接把 `FactBase` 置空并由会话重新创建；`removeFromBucket` 压缩时用 `ArrayList` 的 `reserve` 反向收缩（若 std 提供）。
- **预期**：撤回后常驻容量从「历史峰值」降到「当前活跃条数」，长会话场景可回收「历史峰值 − 当前值」× 每槽 8~16 字节；具体量级需实测。
- **代价**：`clear()` 从 O(1)（清指针）变 O(类型数) 的重建；需确认没有调用方在 `clear()` 后继续持有旧容器引用（当前无外部可见引用）。
- **验证**：`getAllocatedHeapSize()` + RSS 在「插入 100k → 全撤 → clear」循环 10 轮下是否回到基线；`cjprof heap` 看 `FactHandle` 与 `HashMap` 节点数。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] 减少 `scan` / `size` / `commitToParent` 的句柄数组中转

- **现状**：`FactBase.scan` 每次构造 `ArrayList` 再 `toArray()`（`:161`-`:169`）；`FactBaseView.size` 对每个 `typeTag` 调一次 `scan` 只为取 `size`（`:122`-`:128`），因此 `size()` 一次调用产生 T 个数组；`commitToParent` 对每个类型再 `scan` 一次（`:156`-`:157`）。T = 空间内类型数，N = 事实数，单次 `size()` 临时内存约 T×N×8 字节。
- **方案**：`FactBase` 维护 `liveCount_`（assert +1 / retract −1 / clear 归零），`size()` 直接读；`commitToParent` 改为遍历 `buckets_` 的内部视图（包内私有 `forEachLive` 回调），避免 `scan` 的数组物化。
- **预期**：`size()` 从 O(T·N) 分配降到 0 分配；`commitToParent` 少一次 N 元素数组。收益取决于 T 与提交频率，需实测。
- **代价**：新增一个必须与三个容器同步维护的计数（`retract` 的 `Some(fact)` 分支、`clear`、`assert`），幂等性要有用例覆盖。
- **验证**：`cjpm bench` 跑「10k 事实 × 3 类型，每轮 size() 1 次 + commit 1 次」，对比分配量与耗时中位数。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `commitToParent` 用异常表达「已提交」的幂等判定

- **现状**：每次提交，父视图已有的每条事实都会走 `assert` → `ensureNotDuplicate` → `throw RuleException(DUPLICATE_FACT)` → 捕获（`FactBaseView.cj:160`-`:167`）。异常构造含字符串插值（`FactBase.cj:285`），在 N 条事实、重复提交 M 次的场景下是 N×M 次异常 + N×M 次消息格式化。
- **方案**：提交前用 `byIdentity_`（identified 事实）或字段比对做存在性判断，命中即跳过；只对真正新增的事实调 `assert`。
- **预期**：重复提交从「N 次异常」降到「N 次哈希查询」，异常路径开销通常是普通返回的 10^2 量级（需实测），端到端收益取决于提交频率。
- **代价**：需要暴露一个包内 `contains(fact)`；非 identified 事实仍需线性扫描（见下一条）。
- **验证**：`cjpm bench -O2` 对「子视图 10k 事实、连续提交 10 次」测中位数与 P95，`cjprof` 看 `RuleException` 构造占比。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `ValueKey.encode` 的列表编码是 O(n²) 字符串拼接

- **现状**：`ValueKey.cj:314`-`:319` 在循环里 `out = out + item.encode() + ","`，每个元素复制一次已有前缀；`escape`（`:324`-`:326`）对文本做 4 次全串 `replace`，每次产生新串。`encode` 被节点签名使用（`rete/AlphaSignature.cj:105`、`rete/NetworkBuilder.cj:311`），构建期调用、输入是规则里的常量列表。
- **方案**：用 `StringBuilder`（`std.collection`）一次性拼接；`escape` 改成单趟扫描的 `StringBuilder` 版本。
- **预期**：n 元素列表从 O(n²) 降到 O(n)；n 为常量列表长度（通常 < 100）时收益小，只有超长 `IN` 列表才明显。需实测。
- **代价**：新增一个 builder 依赖；输出必须逐字节等价（签名不可变），要加等价性用例（含转义字符、嵌套列表）。
- **验证**：`cjpm bench` 对 `encode` 输入 n = 10 / 100 / 1000 的元素列表，对比耗时曲线是否线性。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 外部 `Fact` 实现的判重是 O(n²)

- **现状**：非 `IdentifiedFact` 的事实进入 `looseFacts_`（`FactBase.cj:247`），`assert` 每次 `ensureNotDuplicate` 线性扫全表（`:291`-`:299`），`retract` 的 `forgetIdentity` 也是线性扫 + `remove(at:)`（`:262`-`:269`）。插入 n 条 → O(n²) 次 `refEq`；撤回 n 条 → O(n²) 次搬移。
- **方案**：对非 identified 事实改用「引用包装」做键（`FactBase` 内部包一层 `WeakRef` 或 `IdentityKey` 对象并实现 `hashCode`/`==` 基于 `refEq`），把线性扫描换成哈希集合；`forgetIdentity` 用同一个键删除。
- **预期**：外部实现的事实插入从 O(n²) 降到 O(n)（n = 10k 时约 5×10^7 次比较消失）。需要先确认仓外是否有非 identified 的 `Fact` 实现（当前仓内生产代码只有 `TypedFact` / `DynamicFact`，第三方实现未知）。
- **代价**：需要确认 Cangjie 是否提供 identity hash（`fact.cj:49`-`:52` 的注释说 `Object` 没有 identity hash，这也是当初退化成线性扫描的原因）；若没有，只能维持现状并把接口注释写清「自定义 Fact 实现请同时实现 `IdentifiedFact`」。
- **验证**：`cjpm bench -O2` 用自定义 `Fact` 实现插入 1k / 10k / 50k，对比耗时曲线。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 事实插入主路径（`FactBase.assert` + `FactHandle`/`ValueKey` 构造）是会话插入的 CPU 热点 | `f_rule/src/fact/FactBase.cj:71`、`f_rule/src/fact/ValueKey.cj:96` | 自耗时占比、每秒插入量 | `cjprof record` 跑 `PerfInsert_test` 场景（10k 事实 × 3 类型），看 `assert` / `ValueKey.of` 的 self time |
| 2 | alpha 过滤对每条事实每个约束都新建 `ValueKey`，GC 压力显著 | `f_rule/src/fact/ValueKey.cj:96`、`rete/AlphaMemory.cj:343` | 分配速率、GC 次数 | 在 `ValueKey.of` 加计数器，跑 1M 事实 × 3 约束，统计对象数与 GC 时间 |
| 3 | `commitToParent` 的异常路径在重复提交时占比高 | `f_rule/src/fact/FactBaseView.cj:160` | 异常构造耗时 / 提交总耗时 | 10k 事实连续提交 10 次，`cjprof` 看 `RuleException` 构造与 `string interpolation` 占比 |
| 4 | `ValueKey.encode` 的长列表拼接成为签名构建热点 | `f_rule/src/fact/ValueKey.cj:306` | n 与耗时曲线 | `cjpm bench -O2`，列表长度 10 / 100 / 1000，看是否超线性 |
| 5 | `ValueKey.sortByValue` 的插入排序在较大 `Set` 上退化 | `f_rule/src/fact/ValueKey.cj:175` | n 与耗时 | 构造 100 / 1000 / 10000 元素 `ReadOnlySet` 做 `ValueKey.of`，计时 |
| 6 | `FlowContext` 的 `viewLock` 在归档场景成为会话串行点 | `f_rule/src/flow/FlowContext.cj:255` | 持锁时长、阻塞线程数 | 注册一个模拟 20ms I/O 的 `FactArchiver`，并发 8 个会话释放，采线程 BLOCKED 时长 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_rule/src/exception/RuleException.cj` | .cj | ✅ | 4 个构造与 `code` 传递正确，无缺陷；`RuleErrorCode` 本体不在本部分 |
| 2 | `f_rule/src/exception/RuleException_test.cj` | .cj | ✅ | 27 个错误码清单与自洽性用例，覆盖充分 |
| 3 | `f_rule/src/fact/DynamicFact.cj` | .cj | ✅ | 见严重项 2（递归）、一般项（浅拷贝 / 字段校验） |
| 4 | `f_rule/src/fact/DynamicFact_test.cj` | .cj | ✅ | 未覆盖集合字段冻结后可写、嵌套深度上限 |
| 5 | `f_rule/src/fact/FactBase.cj` | .cj | ✅ | 见严重项 1、一般项、轻微项 3 |
| 6 | `f_rule/src/fact/FactBaseView.cj` | .cj | ✅ | 见严重项 1（`FactBaseViewStore`）、一般项（`commitToParent`） |
| 7 | `f_rule/src/fact/FactBaseView_test.cj` | .cj | ✅ | 会话隔离用例只覆盖「目标为空」，未覆盖 id 碰撞 |
| 8 | `f_rule/src/fact/FactBase_test.cj` | .cj | ✅ | `assertCopy` 只验证标量快照，未覆盖集合字段 |
| 9 | `f_rule/src/fact/FactSchema.cj` | .cj | ✅ | 注册表语义与实现一致；`simpleTypeName` 按字节扫描 UTF-8 安全 |
| 10 | `f_rule/src/fact/FactSchema_test.cj` | .cj | ✅ | 含测试宿主类 `SchemaOrder`，被 3 个测试文件共用 |
| 11 | `f_rule/src/fact/FactSpace.cj` | .cj | ✅ | 见一般项（重复注册保留首个宿主类）、轻微项（冻结策略） |
| 12 | `f_rule/src/fact/FactSpaceRegistry.cj` | .cj | ✅ | 见轻微项（`declare` 冻结语义） |
| 13 | `f_rule/src/fact/FactSpaceRegistry_test.cj` | .cj | ✅ | 未覆盖「已存在 id 在冻结后重复声明」 |
| 14 | `f_rule/src/fact/FactSpace_test.cj` | .cj | ✅ | 覆盖一致 / 不一致 / 冻结三类重复注册，缺 `declare` 反向场景 |
| 15 | `f_rule/src/fact/TypedFact.cj` | .cj | ✅ | 见一般项（`get` 包装 `Some(None)`） |
| 16 | `f_rule/src/fact/TypedFact_test.cj` | .cj | ✅ | 明确钉住 `typeTag` 不参与句柄相等性（与一般项 3 相符） |
| 17 | `f_rule/src/fact/ValueKey.cj` | .cj | ✅ | 见严重项 2、轻微项 1/2/5、优化方案 4/5 |
| 18 | `f_rule/src/fact/ValueKey_test.cj` | .cj | ✅ | 归一 / 全序 / 严格比较覆盖充分；缺 NaN 与深嵌套用例 |
| 19 | `f_rule/src/fact/fact.cj` | .cj | ✅ | `FactHandle` 见一般项 3；`TypeTag.DYNAMIC_FACT` 仓内零引用（对外 API，不判死代码） |
| 20 | `f_rule/src/flow/FlowContext.cj` | .cj | ✅ | 见一般项 1/2、严重项 1（`FactBaseViewStore` 使用方） |

合计：`.cj` 20 个 / `.md` 0 个 / 共 20 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 2 | `FactBase.scan` 读路径写状态（轻微）；`assert`/`assertCopy` 双路径不对称（一般）。`Fact`/`HostFact` 接口分层合理；无外部输入拼串、无凭据，安全性维度 0 条 |
| §1 死代码 | 1 | 已逐个 private/internal 符号全仓搜引用：`DynamicFact`/`FactBase`/`FactBaseView`/`FactSpace`/`ValueKey` 的私有成员与私有静态函数均有调用者；`simpleTypeName`、`KeyValue`、`FactIdentity`、`TestSet` 均被引用；`protected` 声明 0 个；对外可达 public 不判（记录两条仓内零引用：`TypeTag.DYNAMIC_FACT` `fact.cj:121`、`FactBaseViewStore.release(space,session)` `FactBaseView.cj:226`）。命中 1 条为 `ValueKey.compare` 的恒假兜底 |
| §2 重复逻辑 | 1 | 已把 20 个文件的函数体压成「输入→输出→副作用」两两比对：命中 3 组同构分支（合并为 1 条）；四个枚举（`IsolationLevel`/`FieldType`/`ValueDomain`/`Release`）各手写 `toString`+`==`+`!=`，属同型样板但无行为差异，未单列；测试里 5 份 `codeOf` helper 属 §2 误报边界（测试准备代码） |
| §3 空实现 | 1 | `archiveFacts` 在未注册 archiver 时静默走空分支（与 §14 承诺冲突）；`commitToParent` 的 `Shared => ()`、`release` 的 `Retain => ()` 有注释说明，属有意 no-op |
| §4 栈溢出 | 1 | `checkValue` / `ValueKey` 五处递归均以集合元素为入口，无深度上限、无环检测（严重项 2）；其余无递归（`SimpleTypeName`、`compareInt/Real/Text` 均为迭代或单层） |
| §5 OOM | 1 | `FlowContext.contexts` / `registries` 静态表无淘汰（一般项 1）；`FactBase` 各容器随事实数有界、会话释放后整体丢弃，未单列；`ValueKey.of` 对集合做 2 次复制属有界放大，记入优化方案 |
| §6.1 热点瓶颈 | 0 | 本轮无 `cjprof` / `cjpm bench` 数据，`FactBase.assert`、`ValueKey.of/compare`、`commitToParent` 的耗时占比无法成立，已全部降级进「待验证假设」第 1~4 行 |
| §6.2 大粒度锁 | 1 | `FlowContext.archiveFacts` 在 `viewLock` 内调用外部归档器（与 §3 同一根因的锁粒度侧面）；`fact/` 包无锁（见严重项 1），不在本节重复计 |
| §6.3 并发串行 | 0 | 本部分无 `spawn(...).get()`、无线程池、无单消费者队列；并发串行风险集中在 `viewLock`，计入 §6.2 |
| §6.4 低效算法 | 0 | 静态可判的复杂度问题（`encode` O(n²)、`looseFacts_` O(n²)、`sortByValue` 插入排序）都不满足「有自耗时占比」的取证要求，改列入优化方案 / 待验证假设 |
| §7 降堆内存方案 | 2 | 容器容量回收、`scan`/`size` 中转数组，均标 `无基线（待验证）` |
| §8 降 CPU 方案 | 3 | 异常当幂等判定、`encode` 拼接、`looseFacts_` 判重，均标 `无基线（待验证）` |
| §9 local mode 可行性 | 0 | 判定不可行：`FactHandle` / `ValueKey` 是 `class` 且要进桶与索引（逃逸检查不过），`ArrayList`/`HashMap` 的 std API 无 local mode 重载，且改造要把整个 `fact` 包切到实验编译开关，风险与收益不成比例 |
| §11 现有代码的 BUG（存量） | 9 | 句柄身份、双插入路径、浅拷贝、`update` 自更新、`TypedFact.get` 可空、重复注册宿主类、`commitToParent` 非原子、`declare` 冻结语义、NaN 哈希；另核对了 `retract`/`scan`/`clear`/`size` 的边界（空桶、重复撤回、撤回后重建）均正确 |
| §12 并发安全与锁粒度 | 1 | 严重项 1：`FactBase`（6 个容器）与 `FactBaseViewStore.views_` 无同步，而 `RuleSession` 也未加锁；`FlowContext` 的静态表与 `viewLock` 使用正确（`create`/`release`/`configure` 均在锁内） |
| §14 功能完备性与 README 覆盖 | 1 | `Release.Retain` 的「N 分钟 + 定时清理」承诺（`doc/06-flow-orchestration.md:350`）未实现；本部分无 `README.md`，README 覆盖核对留给包含 `.md` 的子轮 |
| 文件覆盖（§13 等） | 20/20 | 20 个文件全部读完；本部分 `.md` 数量为 0，§13 文档一致性在本部分无命中（引用 `doc/01-architecture.md`、`doc/06-flow-orchestration.md`、`doc/08-api.md` 仅作承诺源） |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 2 |
| 一般 | 9 |
| 轻微 | 5 |
| 优化方案（堆内存 / CPU） | 2 / 3 |

## 总评

本部分集中在事实层（`fact/` 19 个文件）与会话上下文（`flow/FlowContext.cj`），是规则引擎的数据基座，代码风格统一、注释密度高、契约（`Fact` / `FactHandle` / `ValueKey` 全序与归一）写得比多数模块清楚，单元测试对归一、全序、冻结、会话隔离的覆盖也扎实。

风险集中在两处：

1. **并发承诺与实现脱节**（严重项 1）。`01-architecture.md` 与 `08-api.md` 都把 `FactBase` 描述成线程安全、按 `(space, typeTag)` 分段加锁，实现里一个锁都没有，`RuleSession` 也不加锁。这是阻塞项：要么补锁，要么改文档并加运行期断言，二者必须选一个，不能保持现状。
2. **值的引用语义没有闭环**（严重项 2 + 一般项 5/6）。`freeze` 只冻结标量写入，`assertCopy` 只浅拷，`TypedFact` 直接暴露宿主对象，`Fact` 契约「进入网络后取值不变」在三条路径上都不成立；配合 `ValueKey` 归一后的索引，一旦调用方改了容器或宿主字段，索引与事实就会静默漂移。建议把「事实值必须不可变」做成可检查的约束（集合深拷 + 可空字段校验 + 宿主类一致性校验），而不是仅写在注释里。

其余发现多为边界与不变量缺口：句柄身份缺 session、`assert` / `assertCopy` 字段口径不一致、`update` 自更新行为随实现类型漂移、`commitToParent` 非原子、`declare` 冻结语义与注释相反。这些修复面小、风险低，可以排进常规批次。性能方面本轮没有任何 profile / bench 数据，`FactBase.assert` 与 `ValueKey.of` 虽然是插入主路径上的高频点，也只能作为待验证假设，不能进任务清单。

存量缺陷 16 条（严重 2 / 一般 9 / 轻微 5），是否纳入修复待用户决定。
