# f_rule 模块审查报告（第 2/12 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_rule`（本部分覆盖 `doc/` 下 18 个 `.md`，0 个 `.cj`）
- **基线**：工作区快照（sts/1.3.x，未对照远端目标分支；本部分所有问题来源均为「存量」）
- **审查重点**：规则引擎求值正确性、递归与栈溢出、OOM、死代码、重复逻辑、并发安全、存量 BUG；本部分实际以「文档承诺 ↔ 代码实现」核对为主线
- **报告版本**：v1

> 本文件是 `f_rule` 模块第 2/12 部分的分报告，只统计 `files/f_rule.part2.txt` 的 18 个文档；模块级结论以主 Agent 合并后的报告为准。

## 发现

### [严重][存量] FlowContext 的事实视图未接入规则会话与 Rete，按文档写法断言的事实不会产生激活

- **位置**：`f_rule/doc/06-flow-orchestration.md:287-341`、`:386-400`（承诺）；`f_rule/src/flow/FlowContext.cj:97-120`、`f_rule/src/flow/RuleTask.cj:73-87`（实现）
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §11（契约与实现不符）、§14.1（接线缺失）
- **证据**：静态确定 —— `FlowContext.factsOf()` 用 `new FactBaseViewStore(registry)` 建的是一个只依赖 `FactSpaceRegistry` 的独立视图仓库；`FlowContext` 全类没有持有 `RuleSession` / `SessionRuntime`，也没有任何把该视图接到 Rete 分片的代码。`RuleTask.exec()` 只用 `FlowContext.attach()` 建立/绑定上下文，随后用 `engine_.session(envelope.session).assert(...)` 写事实，完全绕过 `FlowContext` 的视图。全仓搜索 `FlowContext` 的非测试引用只有 `RuleTask` 的 `configure/attach/detach`，没有 `current().facts(...)` 或 `factsOf(...)` 进入网络传播的路径。
- **描述**：`doc/06` §5 把 `FlowContext` 描述为「一个会话在多个 `FactSpace` 上的视图集合」，§5.3 明确写「`FactBaseView` 的事实变更直接驱动所属空间分片的网络传播」，§6.1 的宿主 Task 示例也直接 `orders.assert(...)`。但实际 `FlowContext` 的视图与 `RuleSession` 的视图是两个独立的 `FactBaseViewStore`，各自创建独立 `FactBase`。按文档写法，在业务 Task 里通过 `FlowContext.factsOf(space).assert(...)` 写入的事实不会进入议程/Rete，规则不会触发且没有任何报错，属于静默失效。`doc/06` §5.2 的「规则 Task 读写各自空间的事实」在当前实现里只对 `RuleTask` 内部那条 `engine.session` 路径成立，对文档公开的 `FlowContext` 路径不成立。
- **建议**：二选一并统一：① 让 `FlowContext` 持有一个会话级 `RuleSession`/`SessionRuntime` 的视图桥（`factsOf` 返回 `RuleSession.factsOf` 的同一 `FactBaseView`），由 `RuleTask` 或 `RuleSetFlow` 注入；② 如果 `FlowContext` 只是脚本只读视图，则改写 `doc/06` §5、§5.3、§6.1，明确事实写入只能走 `RuleSession`，并删除误导性的 `orders.assert(...)` 示例。补一条端到端用例：按文档在 Task 中经 `FlowContext` 断言事实后，议程必须产生对应激活。

### [严重][存量] 线程安全承诺不成立：RuleEngine 会话表与 FactBase 均无可用的同步手段

- **位置**：`f_rule/doc/08-api.md:22-25`（声称 `RuleEngine`、`FactBase`/`FactBaseView` 线程安全）；`f_rule/src/engine/RuleEngine.cj:35`、`:75-90`、`:123-145`；`f_rule/src/fact/FactBase.cj:32-40`
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §12.1（共享可变状态无保护 / 检查-然后-写入）、§11（契约与实现不符）
- **证据**：静态确定 —— `RuleEngine.sessions_` 是普通 `HashMap<String, RuleSession>`，`session(id)` 先 `get` 再 `sessions_[id] = created`，没有任何锁；`release(id)` 直接 `remove`；`close()` 直接遍历并 `clear()`。`executorsMtx_` 只保护 `tableExecutors_`，不保护 `sessions_`。`FactBase` 的 `buckets_`、`slots_`、`facts_`、`nextId_` 等全部是无锁 `HashMap`/`Int64`，`FactBaseView` 只是转发，没有同步。
- **描述**：`doc/08` §2 把 `RuleEngine`、`FactBase`/`FactBaseView` 标为「线程安全：是」。但引擎是应用级单例，服务端通常按请求调用 `engine.session(requestId)`；两个请求并发首次创建同一/不同会话时，`sessions_` 处于无同步的 check-then-write，可能丢会话、重复建会话或破坏 HashMap 内部结构。`FactBase` 侧更直接：`doc/06` §4.2 明确 `JoinTask.exec` 可能在 `AsyncFlow` 的不同线程执行；同一 session 的多个 `RuleTask` 并发 `session.assert/fire` 时会同时改同一 `FactBase` 的桶、槽位与 `nextId_`，而文档却承诺线程安全。两者都是数据竞争，不是「需要实测」的推测。
- **建议**：要么兑现承诺：给 `RuleEngine.sessions_` 加锁（`session` 的 get-or-create 必须原子，`release/close` 同锁），给 `FactBase` 加锁或明确按 session 线程封闭并在 `RuleSession` 层串行化 `assert/retract/update/fire`；要么把 `doc/08` §2 的线程安全列改为「否/仅单线程」，并在 `RuleEngine`/`RuleSession` 文档中写明调用约束。并发用例：N 个线程同时 `engine.session`/`assert`，断言会话唯一且事实计数等于 N。

### [严重][存量] FlowContext 会话上下文永不释放，静态表随 session 无界增长

- **位置**：`f_rule/doc/06-flow-orchestration.md:332-350`（承诺流程 End/Error 调 `release`）；`f_rule/src/flow/FlowContext.cj:67`、`:130-180`、`:237-245`
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §5（无界容器）、§11（资源释放不对称）
- **证据**：静态确定 —— `FlowContext.contexts` 是 `private static let HashMap<String, FlowContext>`，`attach()` → `create()` 会为每个 `(ruleSetId, session)` 放入一项；`release()` 是唯一删除入口，但全仓非测试代码没有任何调用（`grep "FlowContext.release" src` 只命中 `FlowContext_test.cj`）。`RuleSetFlow.end()` 只 `flow_.registerEnd()`，没有注册释放动作；`RuleEngine.release/close` 也只处理 `RuleSession`，不触碰 `FlowContext.contexts`。`Release.Retain` 分支更是不删除、也没有任何到期清理。
- **描述**：`doc/06` §5.2 的生命周期图写着「流程 End / Error → `FlowContext.release(session)`」，并给出 `Discard/Archive/Retain` 三种策略；实现里这条链路完全没接线。服务端按 session 处理请求时，每来一个新 session 就在静态 map 里永久留下一个 `FlowContext`；一旦业务按文档调用 `factsOf(...)`，它还会持有该会话的 `FactBaseViewStore` 与事实，进程 RSS 随 session 总数单调增长，最终 OOM。`Retain` 声称「保留 N 分钟」，实际既无 N 也无定时器，等价永久保留。
- **建议**：在 `RuleSetFlow` 的 End/Error 出口或 `RuleTask` 的 finally 中按策略调用 `FlowContext.release`；`Release.Retain` 需要明确的 TTL 与清理任务（`f_ticktock`），或直接删掉该枚举值；`RuleEngine.release/close` 应级联释放同 `ruleSetId` 的 `FlowContext`。补用例：创建 N 个 session 并结束流程后，`FlowContext` 的上下文数回到 0（可加 internal 观测点）。

### [严重][存量] JoinTask 超时与汇合完成存在竞态，可能重复发事件或丢分支

- **位置**：`f_rule/doc/06-flow-orchestration.md:262-268`（声称线程安全）；`f_rule/src/flow/JoinTask.cj:205-270`
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §12.1（检查-然后-写入、锁外状态迁移）、§11（并发正确性）
- **证据**：静态确定 —— `exec()` 在 `synchronized(state.lock)` 内置 `complete = true` 并 `arrived.clear()`，出锁后才执行 `states_.remove(session)`（`:234`）；`expire()` 先执行 `states_.remove(session)`（`:264`），再拿 `removed.lock` 清态并发超时事件。存在确定交错：`exec` 置 `complete` 后、执行 `states_.remove` 前，超时线程先 `remove` 成功并发出 timeout；随后 `exec` 的 `remove` 变成 no-op 并照常发出 `output`，同一 session 同时收到 timeout 与 output。另一交错：`expire` 在 `exec` 的 `computeIfAbsent` 之后、`synchronized(state.lock)` 之前移除 state，`exec` 把分支加进一个已不在 map 的孤儿 state，后续分支新建 state，永远等不到该分支。
- **描述**：`doc/06` §4.2 把 JoinTask 的并发语义写成「`ConcurrentHashMap` + 分段锁」并承诺线程安全，但完成与超时是两条独立的「移除 state → 发事件」路径，移除动作没有和状态 lock 组成一个原子迁移。超时是可选项，但只要配置了 `timeout` 且分支在超时边界到达，就会出现下游收到两个事件（重复执行 Join 后续动作）或某个分支被吞（流程永久停住）。这是同步缺失导致的行为错误，不是性能问题。
- **建议**：把「完成/超时」建模为 state 上的原子状态迁移：`expire` 与 `exec` 都在 `state.lock` 内判断并 `remove`，用一个 `done` 标记保证只有一方能发事件；或 `expire` 在拿到 state 后重新 `states_.get(session)` 校验同一实例并 CAS 移除。补并发压力用例：交替在超时边界投递最后一路分支，断言 output 与 timeout 恰好一个。

### [一般][存量] doc/06 与 doc/README 称 ImmediateDispatcher「丢弃」剩余队列，实际是下次 start 重放

- **位置**：`f_rule/doc/06-flow-orchestration.md:171-177`、`f_rule/doc/README.md:62`；实现见 `f_egraph/src/base/ImmediateDispatcher.cj:70-95`
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §13（文档与实现相反）
- **证据**：静态确定 —— `dispatch()` 在命中 `EndExecutor` 时 `return this.end = end`，`eventQueue` 是 dispatcher 的成员 `LinkedBlockingQueue`，返回时既没有 `clear()` 也没有新的清空逻辑；下一次 `start()` 直接复用同一队列。`f_rule/src/flow/FlowSessionRegression_test.cj:32-79` 的 P-05b 用例明确断言第二次 `start()` 消费第一次残留的 `b` 分支（载荷仍是 `first-round`）。
- **描述**：`doc/README` 强制约束 3 和 `doc/06` §3.4 的代码注释都写「队列中剩余事件被丢弃」，而归档 `design.md`、`proposal.md`、flow spec 都写「不清空、下次 start 重放」。实际行为是重放，且会跨 session 串扰；「丢弃」会让读者低估漏 JoinTask 的后果，认为只是少跑一个分支，实际是污染下一轮流程。
- **建议**：把 `doc/README:62`、`doc/06:171-177` 统一改为「不清空，下一次 `start()` 重放」，并引用 P-05b 用例；保留「扇出必须 JoinTask」的强制约束。

### [一般][存量] doc/06 §8 的错误路径与实现相反：plan 异常抛 ACTION_FAILED，分支异常也没有被 RuleSetFlow 包装

- **位置**：`f_rule/doc/06-flow-orchestration.md:525-533`；实现 `f_rule/src/flow/ResolveTask.cj:69-89`、`f_egraph/src/base/TaskExecutor.cj:39-41`
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §13（行为描述与实现不符）
- **证据**：静态确定 —— `ResolveTask.exec()` 对 `plan_(e)` 的异常 `throw RuleException(RuleErrorCode.ACTION_FAILED, ..., cause)`，不是返回 `ErrorEvent`；`TaskExecutor.execute()` 只是 `accepter.accept(task(event))`，不捕获异常；`RuleSetFlow` 的 `start/fanout/join/end` 没有 try/catch，也没有把异常转成 `ErrorEvent` 的代码。归档 flow spec §扇出 也写的是 `ACTION_FAILED`，与实现一致，只有 current doc/06 §8 写反。
- **描述**：按 §8 表，调用方会预期 `plan` 抛异常时流程进入 `registerError()` 的 Error 执行器；实际异常直接冒泡到 `flow.start(...).get()` 的调用方，若调用方只注册了 Error 分支而没有 try/catch，会得到未处理异常而不是 ErrorEvent。§8 最后一行「`RuleSetFlow` 统一包装」同样没有对应实现。
- **建议**：把 §8 表改为「plan 异常 → `RuleException(ACTION_FAILED)`，异常冒泡到 `start()`；需要 ErrorEvent 时由编排层显式 catch 并 `flow.emit(Error)`」；若确实希望统一包装，则实现 `RuleSetFlow` 的 try/catch 并在文档中给出对应错误码。

### [一般][存量] doc/06 多处 API 片段引用不存在的成员，代码示例无法编译

- **位置**：`f_rule/doc/06-flow-orchestration.md:33-37`（`rule.acceptableEvent`）、`:124`（单参 `RuleException`）、`:339`（`RuleRuntime.current().facts`）、`:362-377`（`SessionRuntime` / `SessionNetwork` 构造与方法）、`:458`（`RuleSet.builder`）
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §13（示例引用了不存在的 API / 旧签名）
- **证据**：静态确定 —— `Rule` 没有 `acceptableEvent` 字段，`RuleFlow.build` 的可选参数名是 `acceptableEvent!`，缺省值是 `rule.id`；`RuleException` 只有 `init(code)`、`init(code,message)`、`init(code,caused)`、`init(code,message,caused)`，没有单 `String` 构造；`RuleRuntime` 只有 `initCompiler/compiler/lazyWarningCount/resetForTest`，没有 `current()`；`SessionRuntime` 构造是 `init(sharded: ShardedNetwork, session: String, sink: ActivationSink)`，只有 `shard(space)`，没有 `network(space)`、`agenda`、`close()`；`SessionNetwork` 构造需要 `sink: ActivationSink`；`RuleSet` 没有静态 `builder`，公开入口是 `RuleSetBuilder(id)`。
- **描述**：这些片段是读者复制使用的直接来源：`RuleSet.builder("pricing")`、`RuleException("...")`、`SessionRuntime(ruleSet, session)` 都会直接编译失败；`rule.acceptableEvent` 则会让读者以为规则自带上游事件，实际必须显式传 `acceptableEvent` 或落到 `rule.id`，编排错事件时不会报错。`doc/06` 是流程编排的主文档，示例不可编译会显著增加接入成本。
- **建议**：按当前源码重写这些片段；`RuleFlow.build` 增加 `acceptableEvent:` 说明；`SessionRuntime/SessionNetwork` 若只是内部实现，改为「内部结构」伪代码并去掉 `public` 构造签名，避免被当成公开 API。

### [一般][存量] doc/07 决策表构建 API 名称错误，且 factType / outputOrder 未文档化

- **位置**：`f_rule/doc/07-decision-table.md:104-126`（写成 `when/expr/then`）、`:5-14`（模型无 `factType`）、`:216-239`（CSV 元数据无 `factType`/`outputOrder`）；实现 `f_rule/src/table/DecisionTableBuilder.cj:129-139`、`:74`、`:91`，`f_rule/src/table/CsvTableParser.cj:235-270`
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §13（API 与源码不符）、§14.2（关键配置无文档）
- **证据**：静态确定 —— 实际方法名是 `whenColumn(path)`、`thenColumn(name)`、`exprColumn(name)`；同一文档 §3 的示例（`:136-139`）用的也是 `whenColumn/thenColumn`，与上面的声明块自相矛盾。`DecisionTable` 实际有 `factType`、`outputOrder` 字段与 builder 方法，CSV 解析器实际识别 `# facttype:` 与 `# outputorder:`，但 doc/07 的模型、构建 API、CSV 元数据表都没有列出；`doc/07` 全文搜索 `factType` 为零命中。
- **描述**：按 §3 声明块写 `.when("order.level")` 会编译失败；更关键的是多类型空间必须显式 `factType`，否则构建期抛 `TABLE_INVALID`，而 doc/07 没有告诉用户这个配置存在；`Priority` 聚合路径要求 `outputOrder`（`HitAggregator` 在命中多行且未声明时抛 `TABLE_INVALID`），doc/07 只说「需声明」却没有给出 builder 或 CSV 写法。按文档无法配置出可用的 `Priority` 表。
- **建议**：把声明块改为 `whenColumn/thenColumn/exprColumn`；在模型与 builder 中补 `factType`、`outputOrder`；CSV §5.1 元数据补 `# factType:`、`# outputOrder:` 示例；`Priority` 段给一个完整 CSV 片段。补文档一致性用例：按 doc/07 示例逐行编译。

### [一般][存量] doc/08 §10 的 close 释放承诺未实现：RuleSet.close 只置标志，静态网络缓存仍持有 RuleSet

- **位置**：`f_rule/doc/08-api.md:398-401`；实现 `f_rule/src/rule/RuleSet.cj:162-164`、`f_rule/src/rete/ShardedNetwork.cj:50-52`、`:103-106`
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §13（文档承诺与实现不符）、§11（资源释放不对称）
- **证据**：静态确定 —— `RuleSet.close()` 只有 `closed_ = true`，注释写「清空网络与缓存」但没有清空任何集合；`ShardedNetwork` 的 `cachedRuleSet/cachedNetwork` 是 `private static var`，`shared()` 构建后强引用最近一个 `RuleSet` 与其全部 `ReteNetwork`，`RuleSet.close()` 不会清除它。`RuleSet` 也没有任何「已编译 JitExpression 缓存」字段，doc/08 §10 所说「规则集级缓存，`ruleSet.close()` 一并清空」在实现中不存在。
- **描述**：`engine.close()` 会 dispose 会话并清 `tableExecutors_`，但最后一个 `RuleSet`/网络结构仍被静态缓存强引用；若应用反复「构建规则集 → 关闭 → 构建新规则集」，旧的那一份会一直活到下一次 `ShardedNetwork.shared()` 替换为止。文档却承诺 close 后网络、索引与 JIT 缓存都已释放，排查内存问题时会被误导。
- **建议**：让 `RuleSet.close()` 或 `RuleEngine.close()` 清空 `ShardedNetwork` 的单条缓存（增加 `ShardedNetwork.clearShared(ruleSet)` 并做身份校验），或把缓存改成 `WeakRef<RuleSet>`；文档按实际能力改写「JIT 缓存是 `f_jit` 进程级，规则集级没有独立缓存」。

### [一般][存量] doc/09 的测试与基准布局和仓库不符，性能门禁执行方式自相矛盾

- **位置**：`f_rule/doc/09-testing.md:193`、`:197-203`、`:209-221`、`:227-243`；对照 `f_rule/doc/perf.md:36`、`f_rule/src/test/`
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §13（文档过期 / 示例路径失效）、§14.1（接线缺失）
- **证据**：静态确定 —— 文档写「基准用例固定在 `src/bench/`（不随单元测试默认执行）」，仓库没有 `src/bench/`，性能用例实际在 `src/test/PerfInsert_test.cj`、`PerfNetwork_test.cj`、`PerfMemory_test.cj`、`PerfTable_test.cj`，且带 `@Tag[perf]`；`perf.md` §2 明确写「门禁用例带 `@Tag[perf]`，默认随 `cjpm test` 一起执行」，与 09 §5 直接矛盾。§6 夹具表列的 `shared_space.json`、`isolated_space.json`、`rules_1000.json`、`facts_10000.json` 在 `src/fixtures/` 下均不存在（实际只有 `orders.csv`、`pricing.csv`、`pricing.xlsx`、`pricing_large.xlsx`、`users.csv`）。§7 列 `src/bench/BenchMain.cj` 也不存在；归档 `design.md` D13（`:241-242`）还写「性能门禁写在 `src/Perf_test.cj`」，实际是按 `PerfInsert_test.cj` / `PerfNetwork_test.cj` / `PerfMemory_test.cj` / `PerfTable_test.cj` 拆分；§7 末尾说 `test/` 类型为 `internal`，而 `design.md` D1（`:83-85`）明确记录实际为 `public`，并说明这是对 09 §7 的偏差。
- **描述**：按 09 §5 的路径找不到基准入口，也无法判断 `cjpm test` 是否会跑性能门禁；按 09 §6 找夹具会得到空结果。作为验收文档，这些失效路径会直接阻碍复现 B-01~B-07。
- **建议**：以 `perf.md` 为准重写 09 §5：基准在 `src/test/Perf*_test.cj`，默认参与 `cjpm test`，用 `--exclude-tags=perf` 跳过；§6 只保留实际存在的夹具，或补上缺失文件；§7 改成实际文件树，并说明 `test/` 为 `public`（跨包测试约束）。另核对 P-15「同空间扇出」与 `SAME_SPACE_FANOUT` 强制拒绝是否冲突，冲突则删除或改写该用例。

### [轻微][存量] HitPolicy 议程/聚合等价矩阵在三份文档重复维护

- **位置**：`f_rule/doc/07-decision-table.md:74-86`、`f_rule/doc/11-assembly.md:177-189`、`f_rule/doc/spec/archive/2026-11-01-implement-f-rule-m0-m7/specs/f-rule-decision-table/spec.md:69-84`
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §2（字面量/表结构复制）
- **证据**：静态确定 —— 三处都维护同一张「7 种 HitPolicy × 聚合路径/议程路径」矩阵，当前内容一致；但 07 是用户文档、11 是设计决策、spec 是行为契约，三者独立演进，任一处修改都可能漏改另外两处。
- **描述**：当前没有行为漂移，属于可维护性风险；这类规范表一旦漂移，读者无法判断哪份是权威。
- **建议**：指定 07 §2.1 为唯一来源，11 与 spec 只保留「见 doc/07 §2.1」并只记录设计理由（降级原因），不再复制整张矩阵。

### [轻微][存量] doc/10 路线图仍记录「有序数组 + 二分」，且 M7 交付的 src/bench 不存在

- **位置**：`f_rule/doc/10-roadmap.md:57`、`:100`
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §13（文档过期）
- **证据**：静态确定 —— 实现 `AlphaMemory.ordIndex_` 与 `BetaMemory.ordIndex_` 直接使用 `f_concurrent.ConcurrentSkipListMap`（`src/rete/AlphaMemory.cj:43`、`src/rete/BetaMemory.cj:52`），归档 `design.md` D4 也明确「不用有序数组 + 二分」；M7 交付项写 `src/bench/*`，仓库无该目录。路线图是历史计划，保留原计划可以理解，但当前文档没有标注「已被 D4 取代」，读者会把「首版有序数组」当成现状。
- **建议**：在 10 §2 M2 加一句「实施改为 `ConcurrentSkipListMap`，见 design D4 / perf.md §5」；M7 的 `src/bench/*` 改为实际 `src/test/Perf*_test.cj`，或标注该交付项未按原计划落地。

## 优化可行性方案

### [CPU] HitAggregator 的稳定插入排序在 Collect / RuleOrder / OutputOrder 大命中集上是 O(k²)

- **现状**：`HitAggregator.sorted()` 用插入排序（`src/table/HitAggregator.cj:170-190`），`Collect` 直接返回、`RuleOrder`/`OutputOrder`/`Priority` 走排序；文档支持 10 万行流式表（`doc/07:318-326`），若大部分行命中，k≈10⁵，比较次数约 5×10⁹。
- **方案**：改为稳定归并排序或 `std.sort` + 行号兜底键；`Priority` 只需最小元，可用单趟选择 O(k) 代替全排序。
- **预期**：大命中集下将排序段从 O(k²) 降到 O(k log k)；端到端收益取决于排序占比，当前无数据。
- **代价**：实现与等价性用例（同键保持行序、`None` 输出排序、`outputOrder` 优先）需要补齐；`Priority` 单趟选择要单独保持并列时的行序语义。
- **验证**：`cjpm bench -O2` 构造 10 万行全命中表，对照改前/改后中位数与 P95，并用 `cjprof` 看 `HitAggregator.sorted` 自耗时占比。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] TableCompiler 对流式表仍累积全部 CompiledRow

- **现状**：`TableCompiler.compile()` 遍历 `table_.rowIterator()`，把每行编译成 `CompiledRow` 后 `rows.add(compiled)`（`src/table/TableCompiler.cj:170-180`）；`DecisionTable.compileInto()` 只取 `.rules`（`src/table/DecisionTable.cj:242-245`），`CompiledTable` 在装配后即不可达，但编译期间 10 万行的 `CompiledRow`（含 conditions/outputs 数组）全部同时存活，峰值随行数线性增长。
- **方案**：议程路径（`agendaPath: true`）只保留 `Rule`，编译完一行即丢弃 `CompiledRow`；聚合路径仍保留 rows 供 trace/聚合。
- **预期**：10 万行流式装配的编译峰值从「全部 CompiledRow」降到「单行 + Rule 列表」，具体降幅需测。
- **代价**：`CompiledTable.rows` 在议程路径为空，需确认没有调用方依赖；若未来议程路径也要 trace，要另建按需重编译。
- **验证**：同一 `pricing_large.xlsx` 分别走 `stream` + `.table()`，用 `getAllocatedHeapSize()` / RSS 记录编译前后峰值，重复 3 轮取中位数。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `HitAggregator.sorted` 是 10 万行全命中表的 CPU 热点 | `src/table/HitAggregator.cj:170` | 自耗时占比、k 的实际分布 | `cjprof record` 跑 10 万行 `Collect` 表，统计 `sorted` self time |
| 2 | 流式装配的峰值内存由 `CompiledRow` 而非 XLSX 读取主导 | `src/table/TableCompiler.cj:170` | 编译前后 heapUsed / RSS 峰值 | 对 `pricing_large.xlsx` 跑 stream + `.table()`，分段记录 `getAllocatedHeapSize()` 与 RSS |
| 3 | `TableExecutor.collect` 的 `Array<Fact>` 在百万级事实下抬高单次执行峰值 | `src/table/TableExecutor.cj:96-108` | 事实数 × 单次 execute 的峰值增量 | 100 万事实下重复 `executeTable`，对比 scan 迭代实现的峰值 |
| 4 | `CellParser` / `TableCompiler` 的逐行字符串与临时数组适合 local mode | `src/table/CellParser.cj:38-140`、`TableCompiler.cj:170-260` | 临时对象分配量、逃逸情况、峰值内存 | 开 `--experimental --enable-local-mode` 做改前/改后峰值对照；当前无数据 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_rule/doc/06-flow-orchestration.md` | .md | ✅ | 流程编排主文档；发现 FlowContext 脱节/泄漏、队列语义、错误路径、API 片段陈旧 |
| 2 | `f_rule/doc/07-decision-table.md` | .md | ✅ | 决策表模型与载体；发现 builder 名称错误、factType/outputOrder 缺失、HitPolicy 矩阵重复 |
| 3 | `f_rule/doc/08-api.md` | .md | ✅ | 对外 API；发现线程安全承诺不成立、close 释放承诺未实现 |
| 4 | `f_rule/doc/09-testing.md` | .md | ✅ | 测试策略；发现 src/bench、夹具清单、perf 执行方式与仓库不符 |
| 5 | `f_rule/doc/10-roadmap.md` | .md | ✅ | 路线图；发现有序数组索引与 src/bench 描述过期 |
| 6 | `f_rule/doc/11-assembly.md` | .md | ✅ | 装配层设计；核对 TableSource/activationGroup/模式互斥，基本一致；矩阵重复见 §2 |
| 7 | `f_rule/doc/README.md` | .md | ✅ | 技术文档索引；强制约束 3 的「丢弃」表述有误 |
| 8 | `f_rule/doc/perf.md` | .md | ✅ | 性能门禁报告；阈值与 `PerfGate` 一致；与 09 §5 的执行方式矛盾 |
| 9 | `f_rule/doc/spec/README.md` | .md | ✅ | 规格存档索引；46 条 Requirement 与实际 `doc/spec/specs` 计数一致 |
| 10 | `f_rule/doc/spec/archive/2026-11-01-implement-f-rule-m0-m7/design.md` | .md | ✅ | 归档设计；D4/D7/D8/D9/D12 等与实现基本一致，D8 的「重放」反而比 current doc 准确 |
| 11 | `f_rule/doc/spec/archive/2026-11-01-implement-f-rule-m0-m7/proposal.md` | .md | ✅ | 归档提案；风险面与 design 一致 |
| 12 | `f_rule/doc/spec/archive/2026-11-01-implement-f-rule-m0-m7/specs/f-rule-agenda/spec.md` | .md | ✅ | 议程规格；与 Agenda 实现核对一致 |
| 13 | `f_rule/doc/spec/archive/2026-11-01-implement-f-rule-m0-m7/specs/f-rule-condition/spec.md` | .md | ✅ | 条件规格；深度上限 32 与 `ConditionExpr.depth` 一致 |
| 14 | `f_rule/doc/spec/archive/2026-11-01-implement-f-rule-m0-m7/specs/f-rule-decision-table/spec.md` | .md | ✅ | 决策表规格；HitPolicy 矩阵与 07/11 重复 |
| 15 | `f_rule/doc/spec/archive/2026-11-01-implement-f-rule-m0-m7/specs/f-rule-engine-core/spec.md` | .md | ✅ | 门面与错误码；27 个错误码计数一致 |
| 16 | `f_rule/doc/spec/archive/2026-11-01-implement-f-rule-m0-m7/specs/f-rule-fact-model/spec.md` | .md | ✅ | 事实模型规格；与 FactBase/FactBaseView 基本一致 |
| 17 | `f_rule/doc/spec/archive/2026-11-01-implement-f-rule-m0-m7/specs/f-rule-flow/spec.md` | .md | ✅ | 流程规格；`acceptableEvent`、错误路径与实现有偏差，已在 06 条目合并 |
| 18 | `f_rule/doc/spec/archive/2026-11-01-implement-f-rule-m0-m7/specs/f-rule-rete/spec.md` | .md | ✅ | Rete 规格；索引实现为 ConcurrentSkipListMap，与 D4 一致 |

合计：`.cj` 0 个 / `.md` 18 个 / 共 18 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 4 | 发现 4 条严重：FlowContext 事实未接线、线程安全契约不成立、FlowContext 无界增长、JoinTask 竞态；文档示例的 API 错误另见 §13 |
| §1 死代码 | 0 | 本部分只有 `.md`，没有可判定的源码符号；已逐个核对文档中出现的类型/成员名，不存在「定义后无引用」的死代码概念；失效引用属于 §13 文档错误，不按死代码计 |
| §2 重复逻辑 | 1 | HitPolicy 矩阵在 07/11/归档 spec 三处重复，当前一致，按轻微记录 |
| §3 空实现 | 0 | 已核对文档承诺的实现入口：FlowContext.release/close 未接线、TableSource 等均有实现；没有把「缺实现」误报为「空函数」，实际缺陷归入 §11/§14 |
| §4 栈溢出 | 0 | 本部分无递归代码；文档唯一的递归相关约束是条件树深度上限 32（`ConditionExpr.cj:61`），与 09 C-07 的「33 抛 TABLE_INVALID」一致，未发现无界递归承诺 |
| §5 OOM | 1 | FlowContext 静态 `contexts` 随 session 无界增长（严重） |
| §6.1 热点瓶颈 | 0 | 本部分无 profile/bench 数据；疑似热点已放入「待验证假设」，不写成发现 |
| §6.2 大粒度锁 | 0 | 文档描述的 `TableMode` 只保护一个实例标志、`executorsMtx_` 只保护执行器表；没有「锁内 I/O/解析」的文档承诺，未发现可判定的锁粒度缺陷 |
| §6.3 并发串行 | 0 | 已扫描 `spawn`/`Future.get`/批大小相关描述，文档没有把并发写成串行；`JoinTask` 的并发语义问题归入 §12 |
| §6.4 低效算法 | 1 | HitAggregator 插入排序 O(k²) 列入优化方案（无基线，待验证） |
| §7 降堆内存方案 | 1 | TableCompiler 流式编译仍累积 CompiledRow |
| §8 降 CPU 方案 | 1 | HitAggregator 稳定排序降复杂度 |
| §9 local mode 可行性 | 0 | 文档未提供峰值内存基线；TableCompiler/CellParser 的临时对象改造列入待验证假设，不写成收益结论 |
| §11 现有代码的 BUG（存量） | 4 | FlowContext 事实未接线、线程安全、FlowContext 泄漏、JoinTask 竞态；均为静态确定 |
| §12 并发安全与锁粒度 | 2 | RuleEngine/FactBase 无同步；JoinTask 完成/超时竞态 |
| §14 功能完备性与 README 覆盖 | 2 | `factType`/`outputOrder` 未进 doc/07；FlowContext 生命周期未接线 |
| 文件覆盖（§13 等） | 18/18 | `files/f_rule.part2.txt` 的 18 个 `.md` 均已读完，无缺文件 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 4 |
| 一般 | 6 |
| 轻微 | 2 |
| 优化方案（堆内存 / CPU） | 1 / 1 |

存量 12 条（严重 4 / 一般 6 / 轻微 2），是否纳入修复待用户决定；本报告不替用户拍板。

## 总评

`f_rule` 的文档体系完整，规格、设计、API、测试、性能门禁分层清楚，归档 spec 与多数实现细节（27 个错误码、深度上限 32、HitPolicy 两路径语义、RangeKey 索引）都能对上。主要风险不在文字质量，而在**文档承诺与当前实现的漂移集中在最关键的三处**：`FlowContext` 事实视图与规则网络脱节、`RuleEngine`/`FactBase` 的线程安全声明无同步支撑、`FlowContext` 生命周期无人释放。这三项会分别造成「规则静默不触发」「并发下会话/事实损坏」「长跑内存单调增长」，属于阻塞级存量问题；`JoinTask` 的完成/超时竞态是第四个需要优先修的并发缺陷。其余问题以文档修正为主：`doc/06` 的 API 片段与错误路径、`doc/07` 的决策表 builder 名称与 `factType/outputOrder`、`doc/08` 的 close 释放描述、`doc/09` 的测试布局，应在本轮文档回填中一次性对齐。性能类只给了无基线的优化方向，未写成结论，待补 `cjprof`/RSS 数据后再决定是否排期。
