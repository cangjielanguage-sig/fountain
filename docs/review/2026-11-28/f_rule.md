# f_rule 模块审查报告

- **审查日期**：2026-11-28
- **模块路径**：`f_rule`（217 个文件：184 个 .cj + 33 个 .md）
- **基线**：工作区快照（sts/1.3.x 工作区，master 同提交 120fd2542，无分支差异）
- **审查重点**：见 scope.md（正确性、死代码、重复逻辑、空实现、栈溢出、OOM、热点、并发与锁、存量 BUG、内存/CPU 优化空间、local mode 可行性、README 覆盖）
- **报告版本**：v1（由 12 个分部分报告合并：`parts/f_rule.part1..12.md`）

## 发现

<!-- 第 1 部分 -->

### [严重][存量] 文档声明 RuleEngine / FactBase 线程安全，实现却没有任何同步

- **位置**：`doc/01-architecture.md:182-189`（§5 并发模型，第 187 行「事实插入 | 多线程 | `FactBase` 按空间独立分段锁」）；`doc/08-api.md:22-26`（线程安全表：`RuleEngine`=是、`FactBase`/`FactBaseView`=是，作为同源佐证）；实现：`src/engine/RuleEngine.cj:35,75-94,123-136`、`src/fact/FactBase.cj:31-38,71-89`、`src/fact/FactBaseView.cj:184,192-209`
- **来源**：存量（快照模式无基线；文档与当前实现比对）
- **判据**：review-checklist §12.1（共享可变状态无保护、检查-然后-写入、可见性）、§13（文档承诺与实现相反）
- **证据**：静态确定 —— `sessions_` 是普通 `HashMap`，`session(id)` 先 `get` 再 `put`（`RuleEngine.cj:75-84`）；`release`/`close` 同样直接 `remove`/遍历 `sessions_`（87-94、128-131）；`RuleEngine.closed_`、`RuleSession.disposed_` 是普通 `Bool`（`RuleEngine.cj:38`、`RuleSession.cj:111`）。`FactBase` 的 `nextId_`、`buckets_`、`slots_`、`dead_`、`facts_`、`byIdentity_` 全是普通字段，`assert` 中 `nextId_ += 1` 与桶/槽/映射的多步写入没有任何锁（`FactBase.cj:31-38,71-89`）；`FactBaseViewStore.views_` 也是 get-then-put（`FactBaseView.cj:184,192-209`）。全模块的锁只覆盖 `tableExecutors_`（`executorsMtx_`，`RuleEngine.cj:106-114`）、`RuleFailureGuard`、`FlowContext` 的静态表、`JoinTask`、`NetworkBuilder` 告警计数、`ReteNetwork` 的 generation 与 `ShardedNetwork` 静态缓存、`FactIdentity`；`sessions_` / `views_` / `FactBase` 全部在锁外。
- **描述**：两个线程同时 `engine.session("s")`：都 miss，各自 `new RuleSession`，后写覆盖先写，先建的会话及其 FactBase 变成不可达对象泄漏；并发写同一个 `HashMap` 还可能在扩容期读到半迁移状态。两个线程对同一 session `assert`：`nextId_` 自增与桶/槽/映射多步更新非原子，可能出现重复 id、`facts_` 与 `buckets_` 不一致、事实丢失。文档把「事实插入」标为多线程并声称有分段锁，`doc/08` 更把 `RuleEngine`、`FactBase` 直接标成线程安全，使用者会据此并发调用。
- **建议**：先定语义再改实现。要支持多线程：`sessions_` 与 `views_` 用与 `executorsMtx_` 同级的 `Mutex`（session 创建用锁内 double-check），`FactBase` 按 `(space, typeTag)` 分段加锁，`closed_`/`disposed_` 改 `AtomicBool`。若只支持「一个 session 一个线程」：把 `doc/01` §5 的「多线程 / 分段锁」和 `doc/08` §2 的「是」改成「会话线程封闭；同一 session 不允许并发」，并给 `session`/`release` 加显式约束说明。两条路都必须与现状不同，不能保留"文档说安全、代码无锁"的组合。

### [严重][存量] FlowContext 与 RuleSession 各自持有事实存储；文档承诺的"同一视图"不成立，文档指定的释放路径也释放不掉会话

- **位置**：`doc/02-fact-model.md:384-406`（§6.7，第 385 行「同一 (space, session) 返回同一视图」、第 406 行「`FlowContext.facts(space)` 返回同一 `FactBaseView`」）；实现：`src/flow/FlowContext.cj:67-68,107-118,156-181,237-245`、`src/engine/RuleSession.cj:117`、`src/flow/RuleTask.cj:76-80`、`src/engine/RuleEngine.cj:87-94`
- **来源**：存量
- **判据**：review-checklist §5（无界容器 / 长期持有）、§11（契约与实现不符）、§13
- **证据**：静态确定 —— `FlowContext.factsOf` 在首次访问时 `new FactBaseViewStore(registry)`（`FlowContext.cj:107-118`），`RuleSession` 构造时又 `new FactBaseViewStore(engine.ruleSet.registry)`（`RuleSession.cj:117`），两者互不相通；`RuleTask.exec` 通过 `engine_.session(...).assert` 写入的是 RuleSession 的那一份（`RuleTask.cj:76-80`）。`FlowContext.release` 只走 `releaseViews` → `store_.release(session)`（`FlowContext.cj:156-181,237-245`），全仓无 `FlowContext` 调用 `engine.release` / `session.dispose` 的路径。
- **描述**：两条后果。① `FlowContext.facts` / `factsOf` 看不到 RuleTask 经 `session.assert` 写入的事实；按 `doc/06` §5（第 194/339 行"供 f_jit 脚本读取"）在脚本/宿主里用它读取会读到空集，规则求值结果与"事实已插入"不一致。② `RuleEngine.sessions_` 只增不减：RuleTask 每个事件按 `envelope.session` 建会话，流程结束后按文档调用 `FlowContext.release` 只回收它自己那套 store（RuleTask 写入的并不在其中），RuleSession 及其 FactBase、Token、议程一直留在 `sessions_` 中；按每请求一个 session 使用即线性增长，直到 `engine.release`/`close`。`doc/04` §1（第 7 行）还明确写「规则数、事实数不设上限」，没有任何容量或 TTL 兜底。
- **建议**：把 `FactBaseViewStore` 收敛为 `RuleEngine` 级、按 `(space, session)` 唯一持有，并注入 `FlowContext`；`FlowContext.release` 回调 `engine.release(session)`（或在 `RuleTask.exec` 的 finally 里按 `Release` 策略释放）。若确实要保留两套视图，`doc/02` §6.7 必须改写，并给 `FlowContext` 存储单独的容量/TTL 与释放 API。OOM 的实际增速需压测，见「待验证假设 1」。

### [一般][存量] RuleSet.close() 只置关闭位，没有"清空网络与缓存"

- **位置**：`src/rule/RuleSet.cj:161-164`；`doc/04-rete-network.md:507`；`src/rete/ShardedNetwork.cj:49-52,86-108`；`src/engine/RuleEngine.cj:123-136`；`src/engine/RuleSession.cj:219-223`
- **来源**：存量
- **判据**：review-checklist §3（公开契约承诺行为、函数体近似空）、§11（资源释放不对称）、§13
- **证据**：静态确定 —— `close()` 的注释写「清空网络与缓存；重复调用幂等」，函数体只有 `closed_ = true`。`ShardedNetwork` 用静态 `cachedRuleSet`/`cachedNetwork` 强引用最近一次规则集与整张网络（`ShardedNetwork.cj:49-52`），`shared()` 从不响应关闭（86-108）；`RuleEngine.close()` 只清 `sessions_` 与 `tableExecutors_`、置 `ruleSet.closed`（123-136），没有任何 `cachedNetwork = None`。`RuleSession.ensureOpen` 只检查 `disposed_ || engine_.closed`，不读 `ruleSet.closed`（219-223）。
- **描述**：① 关闭后 Rete 结构（节点、签名、类型描述）仍被静态缓存持有，要等下一个 `RuleSet` 构建才被替换；对周期性 reload 规则集的应用，旧网络会一直活到下一次构建。② 用户直接调用公开的 `ruleSet.close()` 后，已建的 `RuleEngine`/`RuleSession` 仍能 assert/fire，与 `isValid()==false` 的语义冲突。
- **建议**：`RuleEngine.close()` 里清空 ShardedNetwork 静态缓存（新增 `ShardedNetwork.reset()`）；`RuleSession.ensureOpen` 增加 `engine_.ruleSet.closed` 判断。若网络结构是故意跨引擎共享，把 `RuleSet.close` 的注释与 `doc/04` §11 改成"只置关闭位，结构由缓存/GC 回收"，不要承诺"清空"。

### [一般][存量] doc04 的 Rete 公开 API 与当前实现大面积不符

- **位置**：`doc/04-rete-network.md:104-115`（AlphaNode）、`248-268`（Token）、`287-293`（传播伪代码）、`462-471`（ReteNetwork）
- **来源**：存量
- **判据**：review-checklist §13（API / 示例与源码不符）、§14（文档承诺的能力不存在）
- **证据**：静态确定 —— `AlphaNode` 实际只有 `signature`/`test`/`children`/`rightSinks`/`leftSinks`，没有 `successor` / `output`（`src/rete/AlphaNode.cj:31-42`）；`ReteNetwork` 没有 `assert(handle, fact)` / `retract(handle)` / `prop space`，实际入口是 `open(session, sink): SessionNetwork`（`ReteNetwork.cj:91-137`）；`Token` 没有 `valid()`，`release()` 返回 `Bool` 且是 public（`Token.cj:81-108`）；`AlphaSignature` 是 `public class` 而非 §4.1 写的 `internal class`。§6.1 的 `match (successor)` 伪代码在当前"children + sinks"结构里无法对应。
- **描述**：按 doc04 写代码编译不过；更严重的是它把"单链 alpha + 每规则一个 Terminal"的旧结构当作当前结构，读者会误解节点共享与撤销路径（当前是 `SessionNetwork`/`SessionRuntime` + 分片）。
- **建议**：按当前类重写 §3/§5/§6/§9 的签名与伪代码，或在文首标注"§3/§5/§6/§9 为 M2 设计稿，实施见 `src/rete`"；至少删除不存在的成员，避免示例被当成可运行代码。

### [一般][存量] doc03 条件表达式文档与实现不一致（方法名、签名、缓存、Not 限制）

- **位置**：`doc/03-condition-expression.md:100-113`（`Pattern.where`）、`139-140`（"Not 只允许包裹单事实约束"）、`195-211`（`JitExpression.of(source, compiler!)`、`eval(Bindings)`）、`216`（二级缓存）
- **来源**：存量
- **判据**：review-checklist §13、§14
- **证据**：静态确定 —— `Pattern` 只有 `constrain` / `constrainField` / `constrainNot`（`src/condition/Pattern.cj:59-80`），全仓无 `func where`；`JitExpression.of` 是 `(source: String, compiler: Compiler)` 位置参数（`JitExpression.cj:78`），`eval` 收 `HashMap<String, Fact>`（230）；`condition` / `rule` / `runtime` 下搜不到任何 `Map<(source, 签名), JitExpression>` 缓存；`Not(And/Or)` 在 `dnfNot` 里做否定下推（`ConditionExpander.cj:107-124`），只有 `Not(Join)` / `Not(Script)` 抛 `ILLEGAL_STATE`，README:390 也这么写。
- **描述**：文档示例无法编译（`where` 不存在），并把已支持的 `Not(And/Or)` 说成不支持；二级缓存是从未落地的设计描述，读者会据此估算编译开销。
- **建议**：§4 的 API 块改为 `constrain` / `constrainField`；§6 的签名与示例改成 `of(source, compiler)` + `eval(HashMap<String, Fact>)`；§5 的 Not 限制改成"可包 `Leaf`/`And`/`Or`，不可包 `Join`/`Script`"；§6.1 删除二级缓存或标注"未实现，只有 f_jit 的 CompileCache"。

### [一般][存量] doc02 §7 的动态事实 JIT 示例不可用，且与"动态事实强制解释器"策略矛盾

- **位置**：`doc/02-fact-model.md:437-449`（§7 示例）；对照 `doc/03-condition-expression.md:272-285,321-323` 与 `src/condition/JitExpression.cj:97-119,141-155`
- **来源**：存量
- **判据**：review-checklist §13（示例引用不存在的 API / 旧签名）、§11（契约与实现不符）
- **证据**：静态确定 —— 示例 `JitExpression.of("{ f: DynamicFact => ... }")` 缺第二个 `compiler` 参数（`of` 要求两参），`expr.eval([order])` 也不是 `HashMap<String, Fact>`；并且 doc03 §6.4 已用 spike 证明 `?Any` 没有任何 JIT 写法，`JitExpression.ofExpression` / `forRule` 对 `DynamicFact` 绑定直接 `InterpreterProgram.compile` 并只记 WARN（`JitExpression.cj:107-110,142-146,150-154`）。
- **描述**：读者按 doc02 §7 写动态事实 JIT 表达式会先遇到编译错误；即使补上 `compiler` 参数，`JitExpression.of` 仍按 JIT 路径编译 `?Any` 取值（无动态绑定检测），按 doc03 §6.4 的 spike 会在构建期抛 `SCRIPT_COMPILE`；只有改走 `forRule` / `ofExpression` / `interpretedOf` 才会被识别为动态事实并切到解释器。该示例与同文件 §7 风险 R1 的结论相反。
- **建议**：把 §7 示例改成 `JitExpression.interpretedOf(...)` / `forRule(...)` 路径，并明确"`DynamicFact` 只走解释器"；若需要 JIT，改用具名宿主类 + `TypedFact`。

### [一般][存量] doc01 的包结构、依赖方向与 RuleInitializer 职责与实现不符

- **位置**：`doc/01-architecture.md:39-102`（目录树）、`107-122`（依赖方向）、`42`（RuleInitializer 说明）；`README.md:703`（依赖链同源问题）
- **来源**：存量
- **判据**：review-checklist §13（文档过期 / 路径失效）
- **证据**：静态确定 —— 树里写 `fact/Fact.cj`、`rule/Rule.cj`、`rule/Bindings.cj`，实际是 `fact/fact.cj`、`rule/rule.cj`、`agenda/Bindings.cj`（`rule/Bindings.cj` 不存在）；同时漏掉 `fact/ValueKey.cj`、`fact/FactBaseView.cj`、`condition/ConditionExpr.cj`、`condition/Interpreter.cj`、`rule/ConditionExpander.cj`、`rete/SessionNetwork.cj`、`rete/ShardedNetwork.cj`、`engine/EngineOptions.cj` 等。第 116 行写「`agenda` 依赖 `rule`/`rete` 的产出接口」，实际是 `rete` 反向 import `agenda.{Activation, ActivationSink, Bindings}`（`ReteNetwork.cj:18`、`Token.cj:20`、`TerminalNode.cj:19`），`agenda` 不 import `rete`；第 107 行的链条把 `runtime` 放在 `exception` 之前（`runtime` 实际只依赖 `f_jit`/`f_log`，不依赖 `exception`），第 119 行自己又写「runtime 是最底层」，前后矛盾。第 42 行说 RuleInitializer "注册决策表加载器"，实现只调 `RuleRuntime.compiler()`（`RuleInitializer.cj:25,49-51`），README:639 的描述才是对的。`README.md:703` 的依赖链同样漏掉 `agenda → rete` 这条边。
- **描述**：目录树误导定位；依赖方向写反会让维护者以为可以照 `agenda → rete` 改代码（实际会形成反向依赖）；RuleInitializer 的职责描述会让读者以为有决策表自动加载。
- **建议**：按当前文件重画目录树；依赖边改为 `exception → fact → condition → rule → agenda → rete → engine → flow`（`table` 与 `agenda` 并列、`runtime` 独立）；第 42 行改成"保证共享 Compiler 可用"。

### [一般][存量] 文档承诺 TraceLevel 追踪能力，全仓没有实现

- **位置**：`doc/02-fact-model.md:355`、`doc/03-condition-expression.md:411-417`；对照全仓 `grep -rn "TraceLevel" --include=*.cj` = 0 命中
- **来源**：存量
- **判据**：review-checklist §14.1（承诺了但没实现，需双证）、§13
- **证据**：静态确定 —— 承诺源 1：doc02 §6.5 的缓解措施「开启 `TraceLevel.Activations` 记录来源规则」；承诺源 2：doc03 §10 给出 `ruleSet.trace(level: TraceLevel.Constraints)` 调用与 JSON 输出格式。缺失证据：`RuleSet` 公开成员清单（`RuleSet.cj:49-164`）无 `trace`，模块内无 `TraceLevel`/`trace` 定义，全仓 `.cj` 0 命中。
- **描述**：可解释性是被文档当作能力介绍的（决策表的 `RowTrace` 只覆盖表路径，不覆盖规则匹配），用户按 doc03 §10 无法开启规则级追踪。
- **建议**：要么实现 `RuleSet.trace`（至少输出 alpha / beta join / script 三级命中原因）并接线到 `TerminalNode`；要么把 doc02/doc03 的追踪段落标注"规划中"，删掉不可编译的 API 示例。

### [一般][存量] doc05 议程文档的 API 漂移（不存在的 Rule.snapshot / Resolvers.default、参数标签、失效示例）

- **位置**：`doc/05-agenda-conflict-resolution.md:128`（`Resolvers.default()`）、`159`（`Rule.snapshot()`）、`55-68`（`Agenda.init(resolver, mode)` / `fire(limit:)`）、`285`（`enableCycleDetection(window:)`）、`303`（`RuleTask(ruleSet)`）
- **来源**：存量
- **判据**：review-checklist §13、§14
- **证据**：静态确定 —— `Resolvers` 只有 `defaultChain()`（`src/agenda/ConflictResolver.cj:149`），无 `default`；`Rule` 无 `snapshot()`（`src/rule/rule.cj:33-101`）；`Agenda.init` 的 `mode` / `runner` / `cycle` 都是命名参数且有默认值（`agenda.cj:101-102`），`fire(limit!:)`（135）；`enableCycleDetection(window!:)`（`RuleSet.cj:126`）；`RuleTask` 需要 `(engine, name!, acceptable!, output!, factory!)`（`RuleTask.cj:40-41`），示例 `RuleTask(ruleSet)` 编译不过。另有 §9 "同一指纹在窗口内出现超过阈值" 与实现 `current >= threshold_`（`CycleDetector.cj:68`）差一次。
- **描述**：文档是用户查 API 的第一入口，这几处会让示例直接编译失败，或让用户以为可以按 `Rule.snapshot()` 扩展事实值快照。
- **建议**：改成 `defaultChain()`、删掉/实现 `Rule.snapshot`、补命名参数写法、补全 `RuleTask(...)`；§9 文案改为"达到阈值（第 100 次）即抛"。

### [轻微][存量] 文档称网络只持句柄，实际 Token / AlphaMemory 强引用事实对象

- **位置**：`doc/02-fact-model.md:33-34`、`doc/04-rete-network.md:504`；对照 `src/rete/Token.cj:44`（`public let fact: Fact`）、`src/rete/AlphaMemory.cj:30-37`（`facts_: HashMap<FactHandle, Fact>`）
- **来源**：存量
- **判据**：review-checklist §7（长期持有 / 生命周期）、§13
- **证据**：静态确定 —— `Token` 每个节点直接保存 `Fact`；`AlphaMemory` 保存 `handle → Fact`；只有 `BetaMemory` 存 Token。文档写"网络传播与索引只持有句柄，不直接持有事实对象，避免大量 token 长期滞留业务对象"与代码相反。
- **描述**：这不一定是错误设计（避免回查 `FactBase` 的哈希查找），但会让读者低估"令牌/激活存活即事实存活"的内存路径：`Loop` 模式下激活可跨轮次留在 `index_`，被 retract 的事实只要令牌没撤干净就仍可达。
- **建议**：把文档改成"`Token` 与 `AlphaMemory` 持有 `Fact` 强引用；`BetaMemory` 持令牌"；若目标是降 RSS，再评估令牌改存 handle + 惰性回查（属优化方案，需数据）。

### [轻微][存量] `In` 的"可索引"口径在 doc03 / doc04 / `Operator.indexable` 三处不一致

- **位置**：`doc/03-condition-expression.md:40`（`In` 可索引，"集合展开为多值索引"）、`doc/04-rete-network.md:217-223`（承认 `In` 是单节点全扫）；`src/condition/Operator.cj:78`（`In → true`）、`src/rete/AlphaMemory.cj:166-188`（`select` 只处理 Eq/范围/Between，其余全扫）
- **来源**：存量
- **判据**：review-checklist §13（规格与实现漂移）、§6.4（指标误导优化决策）
- **证据**：静态确定 —— `Operator.indexable` 把 `In` 计为 true；`AlphaMemory.select` 的 `match` 没有 `In` 分支，落到全扫；`NetworkBuilder` 用 `indexable` 统计覆盖率（`NetworkBuilder.cj:88,97`），因此 `indexCoverage` 会把 `In` 计为"已索引"，而 doc03 又说它展开成多值索引。
- **描述**：匹配结果正确（`AlphaNode.test`/`holdsWith` 会重算），但运维信号失真：大量 `In` 的规则覆盖率显示 1.0，实际探测仍全扫。doc03 与 doc04 对同一算子给出相反结论。
- **建议**：短期把 `In` 的 `indexable` 改为 false（覆盖率如实反映），doc03 §2 的 `In` 行改成"否（当前全扫）"；长期按 doc04 §4.1 展开成 `Eq` 或专用节点。

### [轻微][存量] README「其他公开 API」失真：常量值被剥离，且漏列 RuleSet 的公开成员

- **位置**：`README.md:841`（PerfFixture 常量）、`437-451`（RuleSet API 块）；`README_en.md:842` 同源；对照 `src/rule/RuleSet.cj:52-54,156-159`
- **来源**：存量
- **判据**：review-checklist §14.2（公开 API 未文档化）、§13（文档内容错误）
- **证据**：静态确定 —— 第 841 行写成 `FIELDS: Array<String> = [ , , , ]`、`TYPE: String =`（字符串字面量被剥离，值不可读）；`RuleSet.registry`、`RuleSet.expressionMode`、`RuleSet.conflictResolver`、`RuleSet.freeze()` 在 README 全文检索不到（`grep` 只命中 FactSpace/DynamicFact 的 `freeze` 与 Builder 的 `expressionMode`/`conflictResolver`）。`registry` 是 `RuleTask`/`FlowContext` 实际依赖的公开成员。
- **描述**：自动生成的 API 清单既不完整又有不可读的常量值，使用者无法据此了解规则集的可观测面。
- **建议**：重新生成清单并在生成器里保留字面量；至少补上上述 4 个成员及其用途。

### [轻微][存量] README 依赖表声明 f_util，但模块源码零引用

- **位置**：`README.md:777`；`cjpm.toml` 的 `[dependencies] fountain::f_util`；全模块 `grep -rn "f_util" src --include=*.cj` = 0
- **来源**：存量
- **判据**：review-checklist §1（读了不用 / 死依赖）、§14（文档与工程配置不一致）
- **证据**：静态确定 —— 11 个 path 依赖中只有 `f_util` 没有任何 import；README 把它列为"基础设施"用途。
- **描述**：多一个编译期依赖会拉长构建、增加版本对齐面，也让依赖图失真（`doc/01` §4 的依赖表没有列 `f_util`，与 README 不一致）。
- **建议**：从 `cjpm.toml` 与 README 依赖表移除，或补上真实用途。

> 范围外提示（不计入本部分统计）：追证冲突消解链时看到 `rule/ConflictResolver.cj` 的 `DefaultConflictResolver` 与 `agenda/ConflictResolver.cj` 的 `ConflictCompare`/`CompositeResolver` 存在三份等价的 `Ordering` 比较辅助（Int64/String 的 asc/desc），细节留给 `.cj` 子轮判定是否为可合并的重复逻辑。

<!-- 第 2 部分 -->

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

<!-- 第 3 部分 -->

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

<!-- 第 4 部分 -->

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

<!-- 第 5 部分 -->

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

<!-- 第 6 部分 -->

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

<!-- 第 7 部分 -->

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

<!-- 第 8 部分 -->

### [严重][存量] `BetaMemory.orderedHeader` 的边界取值方向与 `AlphaMemory` 相反：`Le` 连接漏掉等值令牌，静默丢激活

- **位置**：`f_rule/src/rete/BetaMemory.cj:264`-`:276`（`orderedHeader`，边界在 `:266`-`:270`）；调用链 `BetaMemory.cj:142`-`:151`（`select`，`case Operator.Le => orderedHeader(fieldKey, value, true)` 在 `:148`）→ `:184`-`:199`（`selectList`）→ `:168`-`:181`（`probeJoinList`）→ `f_rule/src/rete/BetaNode.cj:249`-`:256`（`candidatesOf` 的 `FromBeta` 分支）
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §11（边界差一 / 语义与命名不符）、§2（近似重复里一块少了边界判断，往往同时是缺陷）
- **证据**：静态确定 —— 三项代码事实即可定：① `BetaMemory.orderedHeader` 的 `including` 分支写的是 `RangeKey(value, Int64.Min)`（`:266`-`:270`），与 `orderedTail`（`:250`-`:262`）**完全一样**，而 `AlphaMemory.orderedHeader`（`AlphaMemory.cj:209`-`:222`）是 `including ? RangeKey(value, Int64.Max) : RangeKey(value, Int64.Min)`，两者方向相反；② `ConcurrentSkipListMap.header(max, including)` 的语义是 `key < max` / `key <= max`（`f_concurrent/src/ConcurrentSkipListMap.cj:740`-`:753`），令牌键是 `(value, token.id)`，`Token.id` 从 1 递增（`Token.cj:58`-`:60`），永不为 `Int64.Min`；③ 因此 `Le` 走 `header((V, Min), including: true)` 只会返回**严格小于** `V` 的令牌，`value == V` 的令牌全部被排除。
- **描述**：`Le` 连接在「左令牌来自 beta memory、右侧新事实到达」这条路径上会漏掉等值的全部候选。`BetaNode` 只在候选集合内逐条重算 join（`holdsWith`），**候选缺失无法被发现** —— 表现为规则少触发、聚合结果偏小，且没有任何日志。`Lt` 走 `header((V, Max), including: false)` 恰好是超集（`BetaNode.cj:276`-`:281` 的注释允许超集），所以问题只落在 `Le` 上，更隐蔽：范围 join 的 `Gt/Ge/Lt` 全部正常，只有 `Le` 丢数据。现有用例均未覆盖：`BetaMemory_test.cj:66`-`:74` 只断言 `Ge`，`BetaNode_test.cj:144`-`:153` 的范围用例用 `Gt`，`PropertyGen.randomJoinOp`（`f_rule/src/test/PropertyGen.cj:144`-`:150`）虽会随机出 `Le`，但差分用例固定种子、且 `Le` 必须落在第 3 个及以后模式（`index >= 2` 才会走 `FromBeta`）才命中，实际没覆盖到。
- **建议**：把 `orderedHeader` 的边界改成与 `AlphaMemory` 一致（`including ? RangeKey(value, Int64.Max) : RangeKey(value, Int64.Min)`），并同时补一个「`Le` 与全扫逐条一致」的用例（`BetaMemory_test` 里对 `o.amount Le u.amount` 断言命中数含等值）；更彻底的做法是按第 7 部分建议把两份 `orderedBound` 合并成单个带 `fromHead` 参数的实现，避免第三处漂移。

### [严重][存量] `JoinSignature` 的共享键不含绑定名：无 join 的多模式规则会共享 beta 节点，第二条规则的令牌绑定名被第一条覆盖，规则静默不触发

- **位置**：`f_rule/src/rete/JoinSignature.cj:33`-`:42`（键由 `leftRef` + `rightAlphaId` + `joinKeys` 拼成）、`:68`-`:70`（`joinKey` 才带绑定名）；`f_rule/src/rete/ReteNetwork.cj:187`-`:204`（`betaNodeFor` 用该键查表，命中即复用）；`f_rule/src/rete/NetworkBuilder.cj:169`-`:175`（登记挂接用的是**本条规则**的 `leftBinding`，节点自身保存的是**首条规则**的绑定名）
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §11（契约与实现不符：共享键不完整导致跨规则语义串味）、§12.1（发布逸出/共享结构不一致）
- **证据**：静态确定 —— ① `JoinSignature.init` 只把 `leftSource.toString()`、`rightAlphaId`、`joinKeys` 拼进键（`:34`-`:41`），`leftBinding`/`rightBinding` 不在其中；② 无 join 时 `joinKeys` 为空（`NetworkBuilder.joinsAt` 返回空数组，`:236`-`:249`），两条**类型序列相同、无 join、绑定名不同**的规则得到同一把键；③ `alphaChain` 对无约束模式统一走 `AlphaSignature.typeOnly`（`NetworkBuilder.cj:191`-`:196`），两条规则的 alpha 节点 id 也相同，于是 `betaNodeFor` 返回同一个 `BetaNode`，它的 `leftBinding`/`rightBinding` 是第一条规则的值（`ReteNetwork.cj:198`-`:199`）；④ 产出子令牌时 `Token.child(parent, handle, rightBinding, fact)` 用的是节点上的绑定名（`BetaNode.cj:352`），第二条规则的终端只能拿到 `{自己的左绑定, 第一条的右绑定}`。
- **描述**：触发条件是「两条规则模式类型序列相同、模式之间没有 join 约束、绑定名不同」，例如 `R1 = [(Order,"o"), (Order,"u")]`、`R2 = [(Order,"a"), (Order,"b")]`。这种形态是合法且被支持的：`Validator` 只校验「join 引用的绑定存在」（`f_rule/src/rule/Validator.cj:75`-`:90`），不要求相邻模式之间有 join；`BetaNode.choosePlan` 专门为无 join 定义了 `JoinPlan.RightScan`「逐条右侧事实与左令牌做笛卡尔积」（`BetaNode.cj:47`-`:48`），doc 也把它当正式能力（`f_rule/doc/04-rete-network.md:398` 一带的 build/probe 选择）。后果是 R2 的脚本/动作按 `"b"` 取不到事实：`JitExpression` 求值失败 → `TerminalNode.leftActivate` 记 WARN 并按 `RuleFailureGuard` 累计失败（`TerminalNode.cj:76`-`:90`），连续失败达到阈值后该规则被**整条禁用**。业务侧看到的只是「规则不生效」，没有异常抛出。
- **建议**：把 `leftBinding`/`rightBinding` 加入 `JoinSignature` 的键（最直接：`init` 参数补两个字段并拼进 `key_`）；若担心共享率下降，可在键里只放「join 未涉及的那些绑定名」；同时在 `Validator` 里显式拒绝「相邻模式之间没有 join」的规则并更新 doc，二选一必须落到文档，不能让两种语义并存。

### [一般][存量] 共享 beta 节点在上游被重复登记，同一事实按「共享规则数」重复传播，靠下游幂等掩盖

- **位置**：`f_rule/src/rete/NetworkBuilder.cj:169`-`:175`（`endpoints[index].addRightConsumer(beta)` 与 `outgoing.addConsumer(beta)` / `endpoints[0].addLeftConsumer(beta, ...)` 无条件下发，每条规则各来一次）；接收侧 `f_rule/src/rete/AlphaNode.cj:78`-`:85`、`f_rule/src/rete/BetaNode.cj:140`-`:142` 都是纯 `add`，没有「同 sink 已存在」判断
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §11（重复登记 / 接线冗余）、§8（同一份工作重复做）
- **证据**：静态确定 —— `betaNodeFor` 命中已有节点时直接返回（`ReteNetwork.cj:191`-`:195`），但调用方完全不看「是否新建」，照旧把同一个 `BetaNode` 再登记一次；`NetworkSharing_test.identicalJoinSignatureIsShared`（`:76`-`:84`）明确构造了两条规则共享 1 个 beta 节点的场景，因此该 alpha 节点的 `rightSinks_` 里有同一 sink 两份、`leftSinks_` 里有两份（绑定名相同），`outgoing.consumers_` 同理。结果正确性不受影响（`AlphaMemory.add`/`BetaMemory.add` 返回 false 时短路，`emit` 还先查 `BetaMemory.productions.contains`），但每条事实会走 K 次 `probeRight` + `holdsWith`，K = 共享该节点的规则数；同一份 join 表被重复求值 K 次，K 条规则全等时等于 100 倍（对应 `NetworkSharing_test.hundredRulesShareTwentyAlphaSignatures` 的形态）。
- **描述**：这不是「结果错」，而是「同一次传播被做了 K 遍」，而且异常路径也会被放大：约束求值抛异常时 `RuleFailureReporter.report` 按 `ruleIds_` 逐个记失败，重复调用会把共享规则连坐禁用（`AlphaNode.cj:101`-`:107`）。放大倍数只取决于规则集形态，代码里没有任何去重或告警，容易被误当成「rete 就是慢」。
- **建议**：`addRightConsumer`/`addLeftConsumer`/`addConsumer` 加「同实例（或同 sink + 同 binding）已存在则跳过」的判断，或让 `ReteNetwork.betaNodeFor` 返回 `(node, created)` 由 `NetworkBuilder` 只在 `created` 时登记；补一条用例断言「两条同签名规则共享节点时 `rightConsumers().size == 1`」。

### [一般][存量] `ReteNetwork.build` 的 `frozen_` 检查与置位非原子，构建期容器全无同步

- **位置**：`f_rule/src/rete/ReteNetwork.cj:91`-`:103`（`if (frozen_) throw ...` 在 `:93`-`:98`，`frozen_ = true` 在 `:102`）；被并发改写的容器与入口：`nextNodeId`（`:166`-`:171`）、`alphaNodeFor`（`:173`-`:184`）、`betaNodeFor`（`:186`-`:204`）、`newTerminal`（`:206`-`:230`）
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §12.1（检查-然后-写入 / 共享可变状态无保护）、§11（契约：注释称「构建完成后冻结，运行期不再增加节点」）
- **证据**：**待确认** —— 共享路径与缺失同步是静态可见的：`build` 是 `public`（`:91`），`frozen_` 是普通 `var`（`:50`），先判后置之间没有锁、没有 `Atomic`；两个线程同时进入都会看到 `false`，于是 `nextId_` 自增交错（`:167`-`:171`）、`alphaByKey_`/`betaByKey_` 双写同一 key（`:181`、`:201`），后写者覆盖先写者而节点仍挂在 `alphaNodes_`/`betaNodes_` 列表里 → 网络出现两个同签名节点、id 也重复（共享键与传播顺序都依赖 id）。缺的信息是「生产路径是否可能并发」。目前唯一生产调用点是 `ShardedNetwork.shared` 在 `cacheMtx` 内建一次（`f_rule/src/rete/ShardedNetwork.cj:86`-`:103`），所以现实风险低；但 `ReteNetwork` 与 `build` 都是对外 `public`，且没有任何注释声明「非线程安全、仅允许单线程构建一次」。
- **描述**：并发 `build` 或 `build` 与 `open`/`assert` 交错时，运行线程可能读到只挂了一半的网络（节点在 `alphaByKey_` 里但不在 `alphaNodes_` 里，或反之），表现为「部分规则永不触发、`nodeCount()` 与实际不符」。这是典型的检查-然后-写入竞态，属于契约未声明 + 实现未保护。
- **建议**：二选一并写进注释/文档：① 明确「`ReteNetwork` 只能单线程构建一次」，把 `build` 收窄为 `internal` 或加一次性 `Atomic` 门闩（CAS 失败即抛 `NETWORK_FROZEN`，顺带把「重复构建」也统一到同一错误码）；② 若要保持 `public`，用 `Mutex` 保护整个 `build`，并在 `open`/`assert` 侧检查 `frozen_`。

### [一般][存量] 常量无法归一化时 `AlphaSignature` 的键塌缩成 `-`，不同常量的两条规则会共享同一 alpha 节点（假阳性面）

- **位置**：`f_rule/src/rete/AlphaSignature.cj:73`-`:80`（`valueOf` 捕获异常退化为 `None`）、`:102`-`:113`（`buildKey` 把 `None` 写成 `"-"`）；同类降级 `f_rule/src/rete/NetworkBuilder.cj:309`-`:315`（`valueKey` 抛异常返回 `""`，使 `sortedConstraints` 的两个不可归一约束排序键相同）
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §3（静默吞异常、降级不告警）、§11（契约与实现不符：`:73` 注释断言「语义不受影响」）
- **证据**：**待确认** —— 键塌缩本身是静态确定的：`value` 为 `None` 时 `valueText` 恒为 `"-"`（`:104`-`:107`），于是「同字段、同算子、同 `negated`、同为不可归一常量」的两个不同约束产生完全相同的 `key()`，`ReteNetwork.alphaNodeFor` 直接复用首个节点（`ReteNetwork.cj:174`-`:184`），节点的 `test` 闭包是**首个**规则那份 `constraint.eval`（`NetworkBuilder.cj:206`、`:223`-`:225`）。缺的信息是「哪些常量能走到这条路径」：`Validator.validateConstraintTypes` 只校验算子与字段域、`Field` 对 `Field` 的兼容性（`f_rule/src/rule/Validator.cj:136`-`:158`），**完全不校验常量值类型**，而 `ValueKey.of` 只接受标量、`Array<Any>`、`Set<Any>`（`f_rule/src/fact/ValueKey.cj:96`-`:129`），其余类型一律抛 `TYPE_MISMATCH`；因此一个 `constrain("code", Eq, 自定义对象)` 能通过校验器、落到 `valueOf` 的 `catch` 分支。
- **描述**：若另一个规则对同一字段约束了**另一个**同类不可归一常量，两条规则共用节点，第二个规则的约束根本不会被求值 —— 事实只要通过第一个规则的测试就向下游传播，产生假阳性激活（第二条规则在不该触发时触发）。若首个约束的 `eval` 恰好抛异常，则 `AlphaNode.propagate` 把异常记到共享节点的**全部** `ruleIds_` 上（`AlphaNode.cj:105`），无关规则被连坐。`AlphaSignature.cj:73` 的注释「语义不受影响」在这条路径上不成立。
- **建议**：在 `Validator` 的常量校验里加一步「常量必须能被 `ValueKey.of` 归一」，不可归一则抛 `TYPE_MISMATCH` 并指明字段；`AlphaSignature.valueOf` 的 `catch` 改为上报一次 WARN 或把原始类型名拼进 `buildKey`（例如 `"-:" + raw.runtimeType` 之类的可区分占位），使不同常量至少不共享节点。

### [一般][存量] 传播与撤销的递归深度由规则定义决定，构建期没有上界校验

- **位置**：`f_rule/src/rete/AlphaNode.cj:99`-`:124`（`propagate` 的 `:121`-`:123` 递归子节点）、`:126`-`:145`（`retract` 的 `:142`-`:144` 递归子节点）；`f_rule/src/rete/BetaNode.cj:351`-`:362`（`emit` → `consumer.leftActivate` → 下游 `leftActivate` → `emit` 的间接递归）、`:176`-`:189`/`:192`-`:205`（撤销同型）
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §4（无界递归 / 间接递归 / 每帧大对象）
- **证据**：**待确认** —— 递归结构是静态确定的：alpha 链深度 = 单个模式的约束数（`NetworkBuilder.alphaChain` 逐约束串链，`:198`-`:213`），beta 链深度 = 规则模式数（`attach` 逐模式串 `addConsumer`，`:159`-`:178`），每个栈帧持有 `session`/`token`/`fact` 与若干 `match` 临时量，没有「深度计数器」。上界来源是规则定义（应用显式构建并注入，见 `f_rule/src/RuleInitializer.cj:23`-`:25` 的注释「规则集由应用显式构建与注入」），不是不可信报文；但 `RuleBuilder.build` 只校验「至少一个模式 / 绑定名唯一」（`f_rule/src/rule/rule.cj:203`-`:210`），`Validator` 不校验模式数或单模式约束数上限，也没有任何常量限制。缺的信息是「实际规则集的最大模式数与约束数」以及平台默认栈大小下的安全深度（按官方文档现场核对，本轮未取）。
- **描述**：目前所有规则集都在几十个模式以内时这条不可达；但一旦出现「按配置批量生成模式」的规则集（`ConditionExpander` 的 `maxExpansions` 只限制 DNF 展开条数，`f_rule/src/rule/ConditionExpander.cj:206`-`:215`，不限制单条规则的合取项数），深度就是外部可控的，`StackOverflow` 会直接打穿断言/撤销路径，而不是可捕获的 `RuleException`。
- **建议**：在 `Validator` 增加「单规则模式数 / 单模式约束数」上限（常量写在模块内并进文档），超限抛 `ILLEGAL_STATE`；或在 `AlphaNode`/`BetaNode` 的传播入口加深度参数，超过阈值改显式栈迭代。至少要在 doc 里写出「深度 = 模式数 + 约束数」这条隐含约束。

### [轻微][存量] `ReteNetwork.build` 里 `let _ = registry` 是死语句

- **位置**：`f_rule/src/rete/ReteNetwork.cj:99`（紧接着 `:100` 就是 `registry_ = Some(registry)`）
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §1（读了不用 / 兼容残留）
- **证据**：静态确定 —— 该语句只把参数绑定到 `_`，之后没有任何使用；`registry` 真正被消费在下一行的字段赋值与 `newTerminal` 的 `registry_` 分支（`:212`-`:222`）。
- **描述**：看起来像「为了消除未使用告警」留下的痕迹，会误导读者以为 `build` 有意忽略 `registry`。
- **建议**：删除该行。

### [轻微][存量] `BetaNode` 注释承诺「按节点 id 升序登记、传播顺序因此可复现」，实现是规则登记顺序

- **位置**：`f_rule/src/rete/BetaNode.cj:135`-`:139`（`addConsumer` 的注释）；实际顺序由 `f_rule/src/rete/NetworkBuilder.cj:169`-`:176` 的 `attach` 循环决定
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §11（语义与注释不符）、§13（与 doc 约定不符）
- **证据**：静态确定 —— `consumers_` 只按 `add` 顺序追加（`BetaNode.cj:140`-`:142`），而 `attach` 按规则顺序逐条登记；当后一条规则复用一个**更早创建**（id 更小）的 beta 节点时，它会被追加到一个 id 更大的节点之后，`consumers_` 就不再是 id 升序。`f_rule/doc/04-rete-network.md:357`-`:359` 明确写「同一事实触发的多个下游按 `node.id` 升序传播」。
- **描述**：传播顺序仍是确定的（规则定义顺序），只是与注释/doc 声称的「id 升序」不一致；影响限于「激活插入议程的先后」这类可复现性论证，不改变最终匹配集合。
- **建议**：要么 `addConsumer` 按 `ReteNode.id` 有序插入（节点都实现 `ReteNode`，比较成本极低），要么把注释与 doc §6.4 改成「按规则定义顺序传播」。

### [轻微][存量] 重复逻辑：`inverse(op)` 两份逐字相同、插入排序三份、`keyOf(raw)` 归一包装本部分 4 处

- **位置**：`f_rule/src/rete/BetaMemory.cj:240`-`:248` 与 `f_rule/src/rete/BetaNode.cj:380`-`:388`（`inverse` 完全一致）；`NetworkBuilder.cj:262`-`:275`（`sortedConstraints`）、`:279`-`:298`（`sortJoins`）、`JoinSignature.cj:49`-`:66`（`sortJoins`）三份插入排序（元素类型不同、都在做 `keys[j] > currentKey` 的同一件事）；`AlphaSignature.cj:74`-`:80`、`BetaMemory.cj:391`-`:397`、`BetaNode.cj:390`-`:396`、`RootDispatch.cj:111`-`:117`（`try { Some(ValueKey.of(raw)) } catch { None }` 同一段）
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §2（只改类型名 / 换控制流的同语义实现）
- **证据**：静态确定 —— 逐行比对：`inverse` 的 `match` 分支与返回值完全相同；三处插入排序的循环体、比较方向、稳定性一致，差异只有容器类型与「返回新数组 vs 原地」；四处 `keyOf` 只有 `return` 位置与变量名不同。
- **描述**：`inverse` 两份已经出现语义漂移风险（发现 1 的边界 bug 就是「镜像实现改一处漏一处」的产物）；插入排序三份导致「排序键定义」分散在 `constraintKey`/`joinKey`/`JoinSignature.joinKey` 三处，改一处就会让共享签名与节点登记顺序不再一致。归一包装重复本身无害（每处都是 6 行），但把 `catch` 语义复制四遍，等于把「静默降级」复制四遍（见一般项 5）。
- **建议**：`inverse` 收进 `Operator` 扩展（`op.inverse()`）或 `rete` 包的内部工具；插入排序抽成 `sortByKeys<T>(items: ArrayList<T>, key: (T) -> String)`；`keyOf` 收成 `fact` 包内的 `ValueKeys.tryOf(raw): ?ValueKey`，并在其中统一决定「降级是否告警」。

### [轻微][存量] `ReteSession.forgetAlphaHits` 全仓无调用者，`SessionNetwork.retract` 内联了同一动作

- **位置**：`f_rule/src/rete/ReteNode.cj:59`-`:60`（接口声明）；`f_rule/src/rete/SessionNetwork.cj:105`-`:108`（`retract` 里直接 `alphaHits_.remove(handle)`）、`:118`-`:120`（`forgetAlphaHits` 实现）
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §1（兼容残留 / 无调用者）、§14.1（接线缺失）
- **证据**：静态确定 —— 全仓检索 `forgetAlphaHits`，命中只有接口声明、`SessionNetwork` 实现与 3 个测试会话的空实现（`AlphaNode_test.cj:78`、`BetaNode_test.cj:83`、`TerminalNode_test.cj:60`），**没有任何调用点**；`RootNode.retract` 只调用 `alphaHits`（`RootNode.cj:95`），清理由 `SessionNetwork.retract` 内联完成。
- **描述**：接口多出一个「撤销完成后调用」的方法，但真正实现撤销的路径没走它，反而复制了它的实现体。后续若有人把清理从 `retract` 挪走（例如改成「撤销后延迟清理」），两处语义会分叉。按硬原则一，`ReteSession` 是 `public` 接口、成员对外可达，因此**不计入死代码**，只作为收窄/清理建议。
- **建议**：要么 `SessionNetwork.retract` 改为调用 `forgetAlphaHits(handle)`（单一实现），要么删掉接口方法并同步移除三处测试空实现。

<!-- 第 9 部分 -->

### [严重] `ShardedNetwork.rebuild` 在共享实例上无同步改写分片表，且改动对所有引擎生效

- **位置**：`f_rule/src/rete/ShardedNetwork.cj:130`（`rebuild`）、`:125`（`network` 读取）、`:86`（`shared` 把同一实例发布给所有引擎）
- **来源**：存量（快照模式无基线；`git status` 无 diff）
- **判据**：review-checklist §12.1（共享可变状态无保护 / 迭代与修改并发）、§10（设计：隔离）
- **证据**：静态确定
  - 写者：`rebuild` 直接执行 `shards_[space] = ShardedNetwork.buildShard(...)`（`:137`），无锁、无原子替换。
  - 读者：`network(space)` 是 `shards_.get(space)`（`:126`）；`SessionRuntime.shard()` 在每次 `assert`/`retract`/`update` 路径上都调用它（`SessionRuntime.cj:129`），即请求主路径。
  - 共享路径：`shared(ruleSet)` 返回进程级缓存实例（`:86`-`:108`），`RuleEngine` 构造时取它（`engine/RuleEngine.cj:55`），所有会话、所有线程都读同一张 `shards_`。
  - 语义第二层：注释宣称「多个引擎共享同一份结构是安全的」（`:80`-`:85`），但 `rebuild` 是公开方法，A 引擎改分片会同时改变 B 引擎的匹配结构。
- **描述**：`std.collection.HashMap` 不是并发安全的，一边 `get` 一边 `put` 属于数据竞争，可能读到半更新的桶、丢元素或崩溃。另外 `rebuild` 的语义是「热替换某分片」，而它修改的是全局共享的单例，破坏 `RuleEngine` 之间的隔离。设计上 `SessionRuntime.shard()` 特意用 `generation` 检测分片换代（`SessionRuntime.cj:137`-`:151`），说明 `rebuild` 被定位为「运行期可用」，因此并发场景是设计意图内而非误用。当前仓内唯一调用点是 `SpaceSharding_test.cj:87`，暴露面限于直接使用 `rete` 公开 API 的外部调用者；严重度按后果（数据竞争 + 隔离破坏）定，不因暂无生产调用点下调。
- **建议**：`shards_` 改为不可变快照 + 引用原子替换（构造新 `HashMap` 后 `AtomicReference`/`synchronized` 换引用），或整体加读写锁；`shared()` 返回的实例不允许结构性 `rebuild`（要改规则就新建 `RuleSet` + 新网络），并在文档里写清共享实例的不可变契约。分片换代后的旧激活清理见下一条。

### [一般] 分片重建后旧分片的激活残留在会话共享的 `TrackingSink`，形成「幽灵激活」

- **位置**：`f_rule/src/rete/SessionRuntime.cj:128`（`shard()` 换代）、`:81`（`tracking_` 为会话级单实例）、`:155`（`activations()`）；`f_rule/src/rete/SessionRuntime.cj:24`（`TrackingSink.items`）
- **来源**：存量
- **判据**：review-checklist §11（错误处理 / 状态不对称）、§12.1（共享可变状态的一致性）
- **证据**：静态确定
  - `shard()` 在 `generation` 变化时新建 `SessionNetwork(network, session, tracking_)`（`:148`），复用同一个 `tracking_`；旧 `SessionNetwork` 被丢弃，但其此前 `delegate.add` 进 `TrackingSink.items` 的激活没有任何清理路径（`TrackingSink` 只有 `add`/`remove`，无按空间清理）。
  - 测试 `SpaceSharding_test.cj:87`-`:92` 只断言 `tokenCount("a") == 0`，未断言 `activations()` 中 `a` 空间的条目已消失，所以该行为未被覆盖。
- **描述**：`rebuild("a")` 之后 `a` 分片的 alpha/beta memory 归零，但 `runtime.activations()`（进而下游议程）仍返回旧分片产出的激活。这些激活指向网络里已不存在的事实/令牌，在用户重新 `assert` 之前可以继续被 `fire`，动作据此改事实会出现「按已消失的匹配执行」。重新 `assert` 同一批事实时，`TrackingSink.add` 因 `items.contains(sortKey)` 命中而直接返回（`:35`-`:37`），也不会补发到下游，只能等显式 `retract` 才清掉。
- **建议**：`SessionNetwork` 记录本分片产出的激活键集合，`SessionRuntime.shard()` 在换新分片时把旧分片键集合逐个 `tracking_.remove(...)`（或给 `TrackingSink` 增加按 `factSpace` 批量撤销）；并补一条 `rebuild` 后 `activations()` 不含旧空间条目的用例。

### [一般] `RuleSet.close()` 承诺「清空网络与缓存」，实现只置位，静态缓存继续强引用已关闭规则集

- **位置**：`f_rule/src/rule/RuleSet.cj:161`（`close()` 只有 `closed_ = true`）；`f_rule/src/rete/ShardedNetwork.cj:50`-`:52`（`cachedRuleSet` / `cachedNetwork` 静态强引用）、`:103`-`:106`（只在下次构建时整体替换）
- **来源**：存量
- **判据**：review-checklist §3（公开契约承诺有行为、函数体近乎为空）、§11（语义与注释不符）、`mem §6.2`（注册表不注销）
- **证据**：静态确定
  - `close()` 全文只有 `closed_ = true`（`:163`），注释写「清空网络与缓存；重复调用幂等」（`:161`）。
  - 全仓搜 `cachedRuleSet` / `cachedNetwork` 只出现在 `ShardedNetwork.cj:50`-`:105`，没有任何清空入口；`RuleEngine.close()`（`engine/RuleEngine.cj:135`）只转调 `ruleSet_.close()`。
- **描述**：`RuleEngine.close()` 后，`ShardedNetwork` 的静态缓存仍持有 `?RuleSet` 与整棵 `ShardedNetwork`（全部分片的 alpha/beta 节点、终端、`RuleFailureGuard`），直到下一次有别的 `RuleSet` 走 `shared()` 才被替换。对「按规则集版本热重建引擎」的进程，旧规则集的网络会活到下一个版本构建完成；对「关闭后长期不再建引擎」的进程，这份结构直到进程退出都不回收。注释承诺的行为不存在，属契约与实现不符；因为缓存只有一个槽位，不构成无界增长，所以按「一般」而非「严重」。
- **建议**：`close()` 真做它写的事——`ShardedNetwork` 增加 `invalidate(ruleSet)` 静态方法（`synchronized(cacheMtx)` 内比较 `refEq` 后置 `None`），由 `RuleSet.close()` 回调；或把注释改成实情并明确「结构随下次构建释放」。

### [一般] 规则集级求值健康状态用一把全局锁覆盖每条激活路径（锁粒度过粗）

- **位置**：`f_rule/src/rule/RuleFailureGuard.cj:34`（唯一 `mtx_`）、`:64`（`expressionTimeout` 读也加锁）、`:83`（`recordFailure`）、`:104`（`recordSuccess`）、`:121`（`isDisabled`）；调用点 `f_rule/src/rete/TerminalNode.cj:72`、`:91`、`:120`
- **来源**：存量
- **判据**：review-checklist §12.2（一把锁保护多个无关资源 / 纯读也拿锁）、§6.2（临界区属性）
- **证据**：静态确定（结构）+ 需实测（竞争程度）
  - 共享路径：`RuleSet.failureGuard` 在规则集构造时创建（`RuleSet.cj:71`），分片构建时下发给每个 `ReteNetwork`（`ShardedNetwork.cj:147`）与每个 `TerminalNode`（`ReteNetwork.cj:227`），因此**同一规则集的所有会话、所有线程共用这一把锁**。
  - 临界区内容：`HashMap.get/put`、`HashSet.contains/add`、键串拼接；单次持有时长量级为亚微秒。
  - 调用频率：每条激活至少 2 次（`isDisabled` + `recordSuccess`），有脚本条件的规则每次求值再加 1 次（`expressionTimeout`，`:120`）；频率等于规则产出速率。
  - 是否主路径：是，`TerminalNode.leftActivate` 是每次令牌到达终端的必经之路。
- **描述**：锁保护了四类互不相关的东西：不可变的配置值 `expressionTimeout_`、连续失败计数、禁用位、最近失败分类。配置值本可不可变或原子读，每次读都抢同一把锁纯属浪费；计数/禁用位按 `ruleId` 天然可分片。结果是所有会话在同一把锁上排队，属于并发串行化点。是否已成瓶颈缺线程状态数据（见「待验证假设 #2」），故此处只判锁粒度设计问题，不判「性能缺陷」。
- **建议**：`expressionTimeout_` 收敛为构建期不可变（`RuleEngine` 构造前设好，之后只读；需要变更就走新 `RuleSet`）；失败计数改 `HashMap<String, AtomicInt64>`（禁用位只需单向置位，可用原子布尔或 `ConcurrentHashMap.putIfAbsent`），锁只在真正要写计数时使用，成功路径先做一次无锁「有没有失败记录」判断。

### [一般] 「记失败 → 达阈值禁用 → 打警告/错误日志」在终端节点与报告器里各写一套

- **位置**：`f_rule/src/rete/TerminalNode.cj:77`-`:91`；`f_rule/src/rete/RuleFailureReporter.cj:37`-`:52`
- **来源**：存量
- **判据**：review-checklist §2（重复逻辑，跨文件、同一语义三段式）
- **证据**：静态确定
  - 两处都是同一流水线：跳过已禁用 → `log.warn("规则 ${ruleId} 表达式求值失败（session=…，site=…，code=…）：…")` → `recordFailure` → 返回 true 时 `log.error("连续失败 ${threshold} 次，已禁用…")`。
  - 差异点：终端节点用 `EvalOutcome.kind`/`detail`（`TerminalNode.cj:81`），报告器用 `classify(error)` 与 `error.message`（`RuleFailureReporter.cj:37`、`:44`）；报告器按 `ruleIds` 循环，终端只处理单条规则；终端在成功路径额外 `recordSuccess`。
- **描述**：同一条「失败收敛」策略被复制两份，错误文案只在「detail 还是 message」「单条还是多条」上分叉。后续改阈值语义、日志级别或禁用措辞时极易只改一处，形成行为漂移（例如报告器先判 `isDisabled` 再记，终端是先判后求值，两者对「禁用瞬间正在求值的令牌」处理不同）。差异不涉及业务要求，属可合并重复。
- **建议**：把收敛逻辑收到 `RuleFailureGuard`（如 `reportFailure(ruleId, kind, detail, site, session)`），`TerminalNode` 与 `RuleFailureReporter` 都只负责「取 kind 与 detail」；日志格式统一到一处。

### [一般] 条件树展开后的规则仍携带 `condition`/`conditionClauses`，二次展开会抛 `ILLEGAL_STATE`

- **位置**：`f_rule/src/rule/ConditionExpander.cj:201`-`:203`（把 `rule.condition`、`rule.conditionClauses` 原样传进展开结果）、`:165`-`:177`（`compile` 遇到已存在的 `o` 绑定直接抛错）
- **来源**：存量
- **判据**：review-checklist §11（契约与实现不符）、§4/§10（非幂等）
- **证据**：静态确定（机制）；触发需按该用法调用 → 触发面待确认
  - `Rule.withOrder` 同样原样带这些字段（`rule/Rule.cj:87`-`:90`），所以进 `RuleSet.rules` 的每条展开结果都还写着「我有一个条件树」。
  - `compile` 生成固定绑定名 `o` 的模式，并在 `:166`-`:173` 对已存在 `o` 绑定的规则抛 `ILLEGAL_STATE`。
- **描述**：`ruleSet.rules[i].condition` 是公开字段（`Rule.cj:51`），本意是「构建期条件树」；展开后它与实际 `patterns` 已经不对应（真实语义在合并后的 `o` 模式里）。任何把既有 `RuleSet.rules` 再喂给 `RuleSetBuilder.rule(...)` 的路径（复制规则集改 id、二次装配）都会走 `expand` 并命中「已有绑定 o」而抛异常，而不是幂等地返回原规则。
- **建议**：展开时把新 `Rule` 的 `condition`/`conditionType`/`conditionClauses` 置空（`None` / `[]`），即可让 `expand` 幂等；若要保留诊断信息，另加只读的 `expandedFrom` 标识字段而不是复用 `condition`。

### [轻微] `Token` 的引用计数只写不读，注释宣称的「父链保活」并不成立

- **位置**：`f_rule/src/rete/Token.cj:45`-`:46`（`refCount_`/`released_`）、`:73`、`:81`、`:86`、`:98`（`refCount`/`isReleased`/`retain`/`release`）；调用点 `rete/BetaMemory.cj:80`、`:112`、`rete/BetaNode.cj:355`
- **来源**：存量
- **判据**：review-checklist §1（读了不用 / 计算了没人消费）、§11（注释与实现不符）
- **证据**：静态确定
  - 全仓搜 `isReleased` / `refCount` 只在 `Token.cj` 与 `Token_test.cj` 命中，生产代码无任何读取。
  - 三处 `release()` 调用点全部写成 `let _ = …`（`BetaMemory.cj:112`、`BetaNode.cj:355`、`Token.cj:108`），返回值无人使用。
  - `parent` 字段是强引用（`:41`），对象生命周期由 GC 决定，计数无法「保证父链不被回收」。
- **描述**：每次令牌入/出 beta memory 都要做一次 `retain`/`release`（含级联递归），却没有任何功能消费者，属自证式记账；注释（`:67`-`:70`）会让后续维护者误以为这里有手写内存管理，改坏 `retain`/`release` 配对后也无从观察。不构成正确性缺陷（记账错误不影响匹配结果），按可维护性定为轻微。
- **建议**：要么删除 `refCount_`/`released_` 与相关调用（改为纯 GC 语义），要么给它们一个真实消费者（如泄漏断言或 `BetaMemory` 收缩触发条件）并在注释里写清「仅诊断、不参与生命周期」。

### [轻微] 同构样板三连：`ConditionExpander.singleXxx` 与 `SessionNetwork` 的惰性 getter

- **位置**：`f_rule/src/rule/ConditionExpander.cj:140`、`:148`、`:156`（`singleConstraint`/`singleJoin`/`singleScript`）；`f_rule/src/rete/SessionNetwork.cj:70`、`:80`、`:90`（`alphaMemory`/`betaMemory`/`betaProductions`）
- **来源**：存量
- **判据**：review-checklist §2（只改类型名 / 只改容器的复制）
- **证据**：静态确定
  - 三个 `singleXxx` 函数体逐行对齐，唯一差别是往 `Conjunction` 的哪个 `ArrayList` 里 `add`；三个 getter 逐行对齐，唯一差别是 `HashMap` 与构造类型。
  - 差异点：无（错误文案、边界、可空性均一致）。
- **描述**：两处都是「改类型名」型复制。`singleXxx` 后续若给某一类合取项加处理（例如脚本条件去重）必然会漏掉另外两个；三个 getter 若要改缓存策略（例如加容量上限）也是三处同改。
- **建议**：`Conjunction` 增加静态工厂（`Conjunction.of(constraint)` 三个重载）或让 `dnf` 直接 `Conjunction().also { … }`；`SessionNetwork` 抽一个 `getOrCreate<T>(map: HashMap<Int64, T>, id: Int64, make: () -> T)` 私有泛型函数。纯内部整理，不改语义。

### [轻微] 三个测试文件 import 了未使用的 `Fact`

- **位置**：`f_rule/src/rete/SpaceSharding_test.cj:24`、`f_rule/src/rete/TerminalNode_test.cj:23`、`f_rule/src/rete/Token_test.cj:20`
- **来源**：存量
- **判据**：review-checklist §1（未使用的 import）
- **证据**：静态确定 —— 三个文件内 `Fact` 只出现在 `import` 行（各文件 `grep -c "\bFact\b"` 均为 1），实际类型标注用的是 `FactHandle` / `DynamicFact`。
- **描述**：冗余导入，`cjlint` 会报未使用导入；不影响行为。
- **建议**：从括号列表里去掉 `Fact`。

### [轻微] `RuleBuilder_test.cj` 末尾的 `BuilderOrder` 测试辅助类零引用

- **位置**：`f_rule/src/rule/RuleBuilder_test.cj:114`-`:123`
- **来源**：存量
- **判据**：review-checklist §1（无调用者的测试辅助类型）
- **证据**：静态确定 —— 全仓搜 `BuilderOrder` 在 `fountain::f_rule.rule` 包内只有本文件的定义；同名类存在于 `src/RuleSetBuilder_test.cj:26`（包 `fountain::f_rule`），被 `builderOrderSchema()`（`src/RuleSetBuilder_test.cj:36`）使用，与本文件这个类无关。
- **描述**：`fountain::f_rule.rule` 包里的这个 `BuilderOrder` 是复制粘贴残留，没有任何用例引用它；同名的另一个类在另一包里正常工作，容易让人误以为两处是同一个类型。
- **建议**：删除本文件中的 `BuilderOrder`；若后续要用，从 `RuleSetBuilder_test` 的 schema 工厂复用。

### [轻微] `rete.cj` 包注释停留在 M0/M2 里程碑，与现状不符

- **位置**：`f_rule/src/rete/rete.cj:18`-`:23`
- **来源**：存量
- **判据**：review-checklist §13（文档过期；代码内包级文档同样是对外说明）
- **证据**：静态确定 —— 注释写「M0 只建包骨架；`Token`/`AlphaNode`/…/`SessionNetwork` 在 M2 落地」，而 `Token.cj`、`RootNode.cj`、`TerminalNode.cj`、`SessionNetwork.cj`、`ShardedNetwork.cj` 均已实现并被 `RuleEngine` 使用（`engine/RuleEngine.cj:55`）。
- **描述**：包注释是 IDE 与新人读代码的第一入口，现在读起来像「尚未实现」，会误导对模块成熟度的判断。
- **建议**：改成描述当前包职责与文件分工（网络结构 / 会话运行态 / 失败收敛 / 令牌），去掉里程碑叙述。

### [轻微] `RuleSetStatus.==` 通过 `toString()` 比较枚举

- **位置**：`f_rule/src/rule/RuleSet.cj:33`-`:39`；被 `:92` 的 `isValid()` 使用
- **来源**：存量
- **判据**：review-checklist §10（仓颉语言特性 / 可读性）
- **证据**：静态确定 —— 两个枚举值的比较实现为 `this.toString() == other.toString()`，每次比较都构造字符串再比内容。
- **描述**：`RuleSetStatus` 是无参枚举，用字符串判等既绕又脆弱（改 `toString` 文案就会改语义）。`isValid()` 在每次 `RuleEngine` 构造、`RuleSetBuilder` 校验时调用，虽然次数不高，但没有理由付字符串分配。
- **建议**：`match (this, other) { case (Valid, Valid) => true; case (Invalid, Invalid) => true; case _ => false }`，或直接依赖枚举自带的 `Equatable` 派生（若编译器为无参枚举生成）。

### [轻微] `ShardedNetwork.shared` 的双检实际会重复构建网络

- **位置**：`f_rule/src/rete/ShardedNetwork.cj:86`-`:108`
- **来源**：存量
- **判据**：review-checklist §12.1（惰性初始化）、§10（可读性）
- **证据**：静态确定 —— 命中检查在 `synchronized(cacheMtx)` 内（`:87`-`:97`），未命中就**出锁**构建（`:102`），再进锁写入（`:103`-`:106`）。两个线程同时首用时都会构建，后写覆盖前写，先返回者拿到的是不在缓存里的实例。
- **描述**：结果不是错误（两份结构语义等价、都不可变），但代价是首请求并发时整棵网络被构建 N 次（每个分片的全部 alpha/beta 节点），且两个引擎会持有不同实例——此时对一个实例 `rebuild` 不会影响另一个，行为不可预期。属「检查-然后-写入」的经典形态，后果仅为重复工作，故定轻微。
- **建议**：用 `synchronized` 包住构建（构建在启动期发生，串行成本可接受），或显式接受重复构建但把「缓存只用于命中、不同实例互不影响」写进注释，并禁止对 `shared()` 实例调用 `rebuild`。

<!-- 第 10 部分 -->

### [一般][存量] CSV 未闭合引号被静默接受，剩余整个文件被吞成单元格

- **位置**：`f_rule/src/table/CsvTableParser.cj:65-111`（`scan` 循环结束处 107-109）、`:113-138`（`readQuoted` 只在遇到配对引号时置 `inQuotes = false`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（错误处理缺失 / 非法输入当合法）
- **证据**：静态确定 —— `scan` 的唯一退出条件是 `index >= bytes.size`；退出后只判断 `cell.size > 0 || !row.isEmpty()` 就 `flushRow()`，`inQuotes` 从未被检查，也没有「引号内 EOF」的错误分支。`readQuoted` 的 `"` 分支（114-123）是唯一清 `inQuotes` 的地方
- **描述**：`doc/07` §5.2 要求按 RFC 4180 解析，RFC 规定引号包裹字段必须闭合。当前实现下，少一个结尾引号时（常见于手工编辑或导出脚本截断）解析器会把文件剩余全部内容拼进一个单元格：若因此列数不符，会抛 `TABLE_INVALID` 但行号指向错误位置，掩盖真正原因；若列数恰好凑齐（多行内容里含逗号/换行），则得到一张**静默错误**的表——条件/输出值被整体污染，编译期不会报错
- **建议**：`scan()` 收尾处加 `if (inQuotes) { throw RuleException(TABLE_INVALID, "第 ${recordLine} 行起的引号未闭合") }`；`readQuoted` 的 EOF 路径也可直接抛错，避免走到半成品 `flushRow`

### [一般][存量] `in`/`not in`/`between` 的值列表不做引号感知切分，含逗号的值被静默拆错

- **位置**：`f_rule/src/table/CellParser.cj:152-169`（`requireList`，切分在 `:165` `for (part in inner.split(","))`）
- **来源**：存量
- **判据**：review-checklist §11（边界 / 数据错误：值被静默改写）+ §13（与载体转义约定不一致）
- **证据**：静态确定 —— `requireList` 先把 `[` `]` 剥掉再 `inner.split(",")`，没有任何引号状态；随后的 `parseValue` → `unquote`（`:289-298`）只剥**整串**两端成对的引号，不还原被切碎的值。举例：`in ['A,B']` → 切成 `"'A"` 与 `"B'"` → `unquote` 两端不成对、原样返回 → 右值变成 `"'A"`、`"B'"` 两个错误字符串
- **描述**：`doc/07` §5.2 明确「含逗号的单元格必须用双引号包裹」，而 §4.1 的列表语法 `in [A, B]` 又允许给值加引号（`CellParser_test.cj:77` 用 `not in ['A', 'B']`）。两者组合（`'A,B'`）时不会报错，只会得到两个不存在的候选值，规则随之永不命中——最典型的「同义不同形」静默失败。相关同根问题：以算子关键字开头的裸值（如文本 `in progress`）会被当成 `In` 算子并抛 `TABLE_INVALID`，当前语法没有逃生写法
- **建议**：`requireList` 改为手写一次扫描（只在引号外认 `,`），或复用一个「行内值 tokenizer」；同时补用例 `in ['A,B', 'C']`。另外在 `doc/07` §4.1 注明「值以算子关键字开头时必须显式 `=` 前缀」

### [一般][存量] CSV 全量物化、每格两次拷贝，且没有大小上限

- **位置**：`f_rule/src/table/CsvTableParser.cj:187-196`（`File.readFrom(path)` 整文件读入）、`:198-203`（字节数组 + 全部 `CsvRecord` 同时存活）、`:159-162`（`flushCell` 先 `cell.toArray()` 再 `String.fromUtf8`）
- **来源**：存量
- **判据**：review-checklist §5（一次性物化 / 无拒绝路径）
- **证据**：静态确定（结构）—— 峰值由三部分叠加：整文件 `Array<UInt8>`（= 文件大小 S）、`cell.toArray()` 的逐格临时字节数组（`Array` 切片/`toArray` 按文档 `core_package_structs.md:1948-1958`、`5` 均为拷贝）、`String.fromUtf8` 再复制一遍字节；随后 `parseBytes` 又为每行建 `ArrayList<?String>` 并存入 `TableRow`。量级换算（按 10 MB / 10 万行 / 6 列估算：60 万格 × 约 40–48 B 对象与指针开销 ≈ 25–30 MB，加 2×S 字节 ≈ 20 MB）合计约 45–60 MB；文件线性放大、无上限可配。具体倍数**需实测**（见「待验证假设」）
- **描述**：`doc/07` §6.4 给 XLSX 提供了 `stream()` 的恒内存路径，CSV 侧只有整表路径（`DecisionTable.streaming` 对 CSV 永远 `false`，见 `DecisionTable.cj:156-160`），而 `CsvTableParser` 既不限大小也不给出拒绝路径。决策表通常在启动期加载，正常规模无碍；但误把一个几十上百 MB 的导出文件当表加载就会在启动阶段打穿内存，且报错是 OOM 而非「表太大」
- **建议**：给 `parseFile` 加可配上限（如 `maxBytes`，超限抛 `TABLE_INVALID`）；`flushCell` 改为复用同一个 `ByteBuffer`，或用 `String.fromUtf8Unchecked` 跳过二次校验（`isValidUtf8` 已整文件校验过，见下条重复逻辑）

### [一般][存量] `doc/07` 声称 `RuleException` 携带 `line`/`column`，实现两者都没有

- **位置**：`f_rule/src/table/CsvTableParser.cj:265-271`（列数错误只把 `line=${}` 拼进 message）、`f_rule/src/table/Column.cj:101-104`（表头未知列完全不提行号）、`f_rule/src/exception/RuleException.cj:26-46`（只有 `code` 与 `message`）
- **来源**：存量
- **判据**：review-checklist §13（文档承诺与实现不符，须给两边位置）
- **证据**：静态确定 —— 承诺源：`f_rule/doc/07-decision-table.md:258`「错误定位：`RuleException(TABLE_INVALID)` 携带 `line`（物理行号）与 `column`（列名）」；反证：`RuleException` 类体只有 `public let code: RuleErrorCode`（`RuleException.cj:28`），全仓 `grep` 无 `line`/`column` 字段；实现侧只有部分错误把 `line=` 写进文案（`CsvTableParser.cj:268-269`、`:312`、`:319`），而表头错误（`CsvTableParser.cj:260-262` → `Column.cj:101-104`）连行号都没有。`README.md:257` 的措辞是「错误消息带物理行号」，与实现一致、与 `doc/07` 相反（文档侧属其他部分）
- **描述**：`RuleException` 的类注释明确「调用方按 `code` 分支处理，不解析 `message`」（`RuleException.cj:29-30`），而 `doc/07` 又承诺可编程读取行/列。使用者按文档写 `e.line` 会编译失败；退化成解析 message 又得不到列名。表结构错（未知列）时定位信息最缺，恰恰是最需要行号的场景
- **建议**：二选一并对齐三处文档——(a) 给 `RuleException` 增 `line: ?Int64` / `column: ?String` 两个可选字段并在 `CsvTableParser` 填充；(b) 改 `doc/07:258` 为「错误消息内带 `line=`，列名以 `column` 文案形式出现」，并让 `Column.parse` 的异常统一带上行号（在 `CsvTableParser` 侧 catch 后重抛，或在 `builder.column` 传入 line）

### [一般][存量] `ColumnKind.Metadata` 文档承诺「说明 / 启用开关」列，解析器只接受 `id`/`name`

- **位置**：`f_rule/src/table/Column.cj:77-79`（只识别 `id`/`name`）、`:101-104`（其余列名一律 `TABLE_INVALID`，错误文案自证「允许 id/name/salience/when.*/then.*/expr.*」）
- **来源**：存量
- **判据**：review-checklist §14（承诺了但没实现，双证）
- **证据**：静态确定 —— 承诺源：`f_rule/doc/07-decision-table.md:26`「`| Metadata    // 规则 id / 名称 / 说明 / 启用开关`」；缺失证据：`grep -rn '"comment"\|"description"\|"enabled"' f_rule/src` 无命中，`Column.parse` 也没有对应分支，`ColumnKind.Metadata` 的产生点只有 `Column.cj:78`
- **描述**：使用者照 `doc/07` §1 在表头加一列「说明」或「启用开关」，会在 `CsvTableParser.cj:260-262` 直接抛 `TABLE_INVALID`（未知列名），既不能注释也不能停用单行。README 的表头说明只列 `id`/`name`/`when.*`/`then.*`/`expr.*`/`salience`（`README.md:241-257` 示例与 557-560 的 API 段），与 `doc/07` 自相矛盾
- **建议**：要么实现 `comment`/`enabled` 两类元数据列（`enabled=false` 时跳过该行编译），要么把 `doc/07:26` 改为「规则 id / 名称」，并在 `doc/07` §5.1 的表头规则里写明「其余列名一律 `TABLE_INVALID`」

### [轻微][存量] `CsvScanner.start` 是死字段

- **位置**：`f_rule/src/table/CsvTableParser.cj:44`（`private let start`）、`:53-56`（init 里写一次）
- **来源**：存量
- **判据**：review-checklist §1（死字段：读了不用）
- **证据**：静态确定 —— 全仓 `grep -n "start" f_rule/src/table/CsvTableParser.cj` 只有声明、赋值与 `init` 形参三处；后续扫描全部用 `index`，`start` 再无读取点
- **描述**：构造时把 BOM 偏移存进字段纯属残留，删除不影响行为（`index = start` 已承担定位）
- **建议**：删掉字段，`init` 只保留形参

### [轻微][存量] 测试辅助 `sample` 未使用

- **位置**：`f_rule/src/table/CsvTableParser_test.cj:39-41`
- **来源**：存量
- **判据**：review-checklist §1（private 函数零调用）
- **证据**：静态确定 —— 该文件 `grep -n "sample"` 只有定义处一行，全部用例直接调 `csv(...)`
- **描述**：`sample` 函数体就是 `csv(lines)`，是改名过程的残留；测试文件内的死代码会让人误以为存在第二套构造入口
- **建议**：删除；若想表达语义可改名为局部变量或直接删

### [轻微][存量] `asRuleAction` 兼容残留，且两个实现逐字相同

- **位置**：`f_rule/src/rule/TableAction.cj:52-55`（本部分）、`f_rule/src/rule/ClosureAction.cj:34-37`（部分外）
- **来源**：存量
- **判据**：review-checklist §1（兼容残留）+ §2（重复逻辑）
- **证据**：静态确定 —— 两处方法体都是 `this`，注释也都是「兼容旧调用点：动作对象自身就是 `RuleAction`」；全仓 `grep -rn "asRuleAction" f_rule` 只有这两个定义，无调用点
- **描述**：两个类都已 `<: RuleAction`，方法恒等返回 `this`，没有存在的必要。因所属类型是 `public class`、成员对外可达，按硬原则一不判死代码；但「兼容旧调用点」已无旧调用点，属残留 API
- **建议**：确认无下游引用后删除两处（属对外可见性收窄，需用户拍板）；若保留，至少把注释改成「保留给按旧签名书写的调用方」并给出迁移说明

### [轻微][存量] `prioritySorted` 与 `OutputOrder` 分支函数体等价

- **位置**：`f_rule/src/table/HitAggregator.cj:94-96`（`OutputOrder` 分支）与 `:100-103`（`prioritySorted`）
- **来源**：存量
- **判据**：review-checklist §2（换控制流/换名字的同一套逻辑）
- **证据**：静态确定 —— 两段都是 `let names = orderedNames(hits)` + `sorted(hits) { l, r => compareOutputs(l, r, names) == Ordering.LT }`，逐字相同，只差函数封装
- **描述**：`Priority` 与 `OutputOrder` 的差异只在「取第 0 个」还是「全返回」，排序部分完全一致；两份实现将来若只改一处（比如换成 `std.sort`）就会静默漂移
- **建议**：`OutputOrder` 分支直接调 `prioritySorted(hits)`（命名可改为 `sortedByOutputs`），排序逻辑只留一份

### [轻微][存量] `number` 与 `infer` 的数值推断逻辑重复

- **位置**：`f_rule/src/table/CellParser.cj:175-188`（`number`）与 `:266-274`（`infer` 的前半段）
- **来源**：存量
- **判据**：review-checklist §2（只改类型名的近似复制）
- **证据**：静态确定 —— 两处都是「含 `.`/`e`/`E` → `Float64.parse`，否则 `Int64.parse`」，都在 `try/catch` 里；差异只有失败时的动作（抛 `TYPE_MISMATCH` vs 继续推断）
- **描述**：同一套数值判定规则写两遍，`Float64`/`Int64` 的取舍将来若调整（例如支持 `_` 分隔、支持超出 `Int64` 的整数降级为浮点），很容易只改一处，导致 `Number` 列与 `Any` 列对同一文本给出不同类型
- **建议**：抽出 `private static func tryNumber(text: String): ?Any`，`number` 在 `None` 时抛错、`infer` 在 `None` 时继续向后推断

### [轻微][存量] 手写 UTF-8 校验与 `String.fromUtf8` 重复，同一份字节扫两遍

- **位置**：`f_rule/src/table/CsvTableParser.cj:189-194`（调用）、`:347-393`（`isValidUtf8` 状态机）
- **来源**：存量
- **判据**：review-checklist §2（与标准库能力重复）+ §8（同一输入重复解析）
- **证据**：静态确定 —— `String.fromUtf8` 文档明确「入参不符合 utf-8 序列规则……抛 `IllegalArgumentException`」（`std/core/core_package_api/core_package_structs.md:6384-6386`），与 `isValidUtf8` 的职责重叠；`flushCell`（`:160`）每格都调 `fromUtf8`，等于整文件被校验两次
- **描述**：手写状态机覆盖了过长编码与代理区（`:378-389`），正确性没问题；代价是 O(S) 多扫一遍、且多维护 47 行易出错代码
- **建议**：保留一次「整文件校验」或「逐格校验」即可——推荐保留 `isValidUtf8`（能给出文件名/统一错误码），单元格改用 `fromUtf8Unchecked`；或删掉 `isValidUtf8`，把 `fromUtf8` 的 `IllegalArgumentException` 包成 `TABLE_INVALID`（`parseFile` 处 catch 一次）

### [轻微][存量] `Validator` 对每条规则都取一次共享编译器，无脚本也会触发惰性创建与 WARN

- **位置**：`f_rule/src/rule/Validator.cj:95`（`let compiler = RuleRuntime.compiler()` 在 `for (rule in ruleSet.rules)` 内）
- **来源**：存量
- **判据**：review-checklist §3（静默副作用：日志噪声）+ §6.1 / §12（无谓的全局锁流量）
- **证据**：静态确定 —— 语句位于规则循环体内、`for (source in rule.scripts)` 之前；`RuleRuntime.compiler()`（`RuleRuntime.cj:53-71`）在未注入时会创建 `Compiler` 并打一条「未注入共享 Compiler」WARN
- **描述**：N 条规则 = N 次 `synchronized(mtx)`；没有任何脚本条件的规则集也会触发惰性编译器和那条 WARN，运维看到「脚本条件将在构建期报 SCRIPT_COMPILE」的告警却根本没有脚本，属误导。多次构建时该 WARN 只出一次（`lazyWarned`），但仍是错误信号
- **建议**：把 `compiler` 提到规则循环外，并且只在 `!rule.scripts.isEmpty()` 时取；或改成惰性 `var compiler: ?Compiler = None` 首次需要时再取

### [轻微][存量] `buildOrInvalid` 成功路径上先装配一遍再丢弃

- **位置**：`f_rule/src/rule/RuleSetBuilder.cj:161`（`var ruleSet = assemble(rules_)`）、`:169`（`ruleSet = assemble(expanded)`）
- **来源**：存量
- **判据**：review-checklist §1（读了不用：第一次装配结果在成功路径上未被使用）+ §6.4（同一输入重复处理）
- **证据**：静态确定 —— 两次 `assemble` 都会为每条规则 `withOrder` 新建一个 `Rule`（`RuleSetBuilder.cj:179-187`），成功路径上第一次的结果整体被覆盖
- **描述**：规则集每次构建都多分配 1 个 `RuleSet` + N 个 `Rule`，并在 `build()` 前多走一遍 O(N) 复制；失败路径才真正需要这份「未展开」结果
- **建议**：先算 `expanded` 再 `assemble`；`catch` 分支里才 `ruleSet = assemble(rules_)`（或直接复用失败前的对象）

### [轻微][存量] `lastError_` 不在构建入口清零，成功后仍返回旧错误

- **位置**：`f_rule/src/rule/RuleSetBuilder.cj:160-177`（`buildOrInvalid` 只在 `catch` 里赋值）、`:189-194`（`lastError()`）
- **来源**：存量
- **判据**：review-checklist §11（语义与命名不符：文档说「最近一次校验失败的错误」）
- **证据**：静态确定 —— 入口没有 `lastError_ = None`；一次失败后继续 `rule(...)` 再 `buildOrInvalid()` 成功时，`isValid()` 为 true 但 `lastError()` 仍返回上一次的异常
- **描述**：诊断 API 在成功构建后给出陈旧错误，调用方若按「`lastError() != None` 就当失败」判断会误报；当前用例（`RuleSetValidation_test.cj:138`、`RuleSetBuilderCondition_test.cj:223`）都只在失败后读取，所以未暴露
- **建议**：`buildOrInvalid()` 开头 `lastError_ = None`；并在 `lastError()` 文档里写明「仅当 `buildOrInvalid()` 返回的规则集 `isValid() == false` 时有意义」

### [轻微][存量] 两处注释与当前实现不符

- **位置**：`f_rule/src/rule/RuleSetBuilder.cj:26-28`（「放在包根是为了……不制造包循环」）、`f_rule/src/rule/ScriptAction.cj:32-34`（「注册为四个重载（`Int64/Float64/Bool/String`）」）
- **来源**：存量
- **判据**：review-checklist §11（注释承诺 A、实现做 B）+ §10（可维护性）
- **证据**：静态确定 —— `RuleSetBuilder.cj:16` 是 `package fountain::f_rule.rule`（不是包根），且 `RuleSet.cj:16` 同包，注释里描述的「`rule → 根包` 反向依赖」已不成立；`ScriptAction.cj:96-100` 实际注册 5 个 `set` 重载（`i64`/`f64`/`dec`/`bool`/`str`），`dec` 对应 `LocalType.DECIMAL`
- **描述**：这类过期注释会直接误导下一轮改动（例如有人照「包根」的说法把类搬走，或以为 `Decimal` 不被支持）
- **建议**：`RuleSetBuilder` 的段落改为「与 `RuleSet` 同包，因此装配器不能由 `RuleSet` 提供 `builder()`（会与 `RuleSetBuilder` 形成同包内的构造环）」；`ScriptAction` 把「四个重载」改为「五个重载（含 `Decimal`）」

### [轻微][存量] `RuleRuntime` 用两个字段表达同一状态，计数器名不副实

- **位置**：`f_rule/src/runtime/RuleRuntime.cj:36-37`（`lazyWarned` / `lazyWarnings`）、`:60-67`（`if (!lazyWarned) { lazyWarned = true; lazyWarnings += 1; ... }`）
- **来源**：存量
- **判据**：review-checklist §2（重复状态）/ §10（命名与语义）
- **证据**：静态确定 —— `lazyWarnings` 只在 `!lazyWarned` 分支内自增，恒 ≤ 1；`resetForTest()`（`:90-96`）同时清两个字段，说明它们语义相同
- **描述**：名为「计数」的字段实际只能取 0/1，测试断言（`RuleRuntime_test.cj:55`）也因此只能写 `1`；两个字段必须同步维护，容易漏清一个
- **建议**：保留一个 `lazyWarned: Bool`，把 `lazyWarningCount()` 改为 `if (lazyWarned) { 1 } else { 0 }`；或反过来只留计数并判断 `== 0`

### [轻微][存量] `ColumnKind` 用 `toString()` 字符串比较实现相等

- **位置**：`f_rule/src/table/Column.cj:38-44`（`==` 走 `this.toString() == other.toString()`，`!=` 再取反）
- **来源**：存量
- **判据**：review-checklist §10（仓颉语言特性：枚举判等应走 `match`/序数，不应构造字符串）
- **证据**：静态确定 —— `toString()`（`:28-36`）每次比较新建字符串，`!=` 又包一层；`ColumnKind` 是无载荷枚举，两种实现结果一致
- **描述**：每次 `column.kind == ColumnKind.When` 都分配一个 `String` 并逐字符比较；调用点集中在 `DecisionTable.binding`/`columnsOf`、`TableCompiler` 的列遍历，规模小（列数级），所以只算可读性/微性能问题，不是热点
- **建议**：`==` 改成 `match ((this, other)) { case (When, When) => true ... }` 或先转 `Int64` 序数比较；`!=` 保持 `!(this == other)`

### [轻微][存量] CSV 未知 `# key: value` 元数据键静默忽略，拼错即静默用默认值

- **位置**：`f_rule/src/table/CsvTableParser.cj:289-303`（`applyMetadata` 只按 `:` 拆键值，不校验键名）、`:224-259`（逐个 `metadata.get(...)`，缺失即跳过）
- **来源**：存量
- **判据**：review-checklist §11（错误处理缺失：可识别的错误输入被静默降级为默认值）
- **证据**：静态确定 —— `applyMetadata` 对任意键都写入 map，`parseBytes` 只读 8 个已知键；`# hitPolciy: Unique` 这类拼写错误既不报错也不告警，最终 `hitPolicy` 取默认 `First`
- **描述**：命中策略、`factSpace`、`salience` 拼错时表仍能建起来并按默认值运行，测试与生产都难发现；对比 `required(metadata, "id")` 对唯一必填键做了校验，其余键完全没有
- **建议**：对「形如 `key: value` 但 key 不在白名单」的行记一条 WARN（普通注释没有冒号，不会误报）；或在 `applyMetadata` 里按白名单过滤并统计未知键

### [轻微][存量] 空行判定只对「单列空行」生效，多列全空行会变成无约束兜底行

- **位置**：`f_rule/src/table/CsvTableParser.cj:164-171`（`var blank = row.size == 1 && row[0].trimAscii() == ""`）
- **来源**：存量
- **判据**：review-checklist §11（边界：空行/分隔符行的处理不一致）
- **证据**：静态确定 —— 空行 `\n` 只产生 1 个空单元格 → 被跳过；但 3 列表里的 `,,\n` 会产生 3 个空单元格 → `row.size == 3` → 不当空行，落成一条「条件全空、输出全空」的数据行。是否为缺陷取决于 `TableCompiler` 是否拒绝全空行，本部分无该代码
- **描述**：在 3 列以上表里，视觉上像空行的 `,,` 行（或误粘贴的纯分隔符行）会生成一条永不产出输出的兜底规则，改变命中计数（`Collect`/`Any` 策略下尤其明显）
- **建议**：`blank` 改为「所有单元格 `trimAscii()` 后都为空」；或在 `TableCompiler` 侧拒绝全空行并给出 `line`。补一条 `,,\n` 的用例

### [轻微][存量] 决策表编译失败后仍停留在 `Assembled`，无法切回聚合路径

- **位置**：`f_rule/src/table/DecisionTable.cj:228-234`（`compile(ruleSet, compiler)` 先 `markAssembled()`）、`:242-245`（`compileInto` 同样先标记）
- **来源**：存量
- **判据**：review-checklist §11（失败路径改状态且不回滚）
- **证据**：静态确定 —— `markAssembled()` 在 `TableCompiler(...).compile()` 之前调用；`compile()` 抛 `RuleException`（未知字段、类型不匹配等）时没有任何 `catch` 回滚，`mode_` 已是 `Assembled`，随后 `TableExecutor` 调 `markExecuted()` 会抛 `TABLE_MODE_CONFLICT`（`:115-127`）
- **描述**：装配失败通常是可修复的（补齐注册、改表头），但修复后同一张表已不能走聚合路径，只能重建实例；`markAssembled` 的重复调用是允许的（`case _ =>`），所以只有「失败后改走另一条路径」被永久阻断
- **建议**：`compile`/`compileInto` 用 try/catch 在失败时回滚成 `Unbound`（需在 `markAssembled` 增加对应的 `unmark`，仍在同一把 `modeMutex_` 下），或把标记推迟到 `TableCompiler.compile()` 成功之后

### [轻微][存量] `ScriptAction` 每次构造都重刷一次全局接口绑定快照

- **位置**：`f_rule/src/rule/ScriptAction.cj:85-94`（`ensureContextRegistered` 先 `enrollInterfaceOf`，再判断 `compiler.hasClass(owner)` 提前返回）
- **来源**：存量
- **判据**：review-checklist §12.2（不必要的全局写锁与全量拷贝）/ §6.4（构建期重复工作）
- **证据**：静态确定 —— `JitBindSupport.enrollInterfaceOf`（`f_jit/src/JitBindSupport.cj:130-144`）每次都 `copyBindings` + `copyAccepts` 全量复制快照并在 `writeMtx` 下 `store`；`ScriptAction` 的调用点在 `hasClass` 早退**之前**，因此每条 `thenScript` 动作都会重刷一次，且用 `JitBindings.empty()` 覆盖 `ActionContext` 的绑定项
- **描述**：规则集里 K 条脚本动作 → K 次全局快照复制 + K 次全局写锁，构建期被串行化；若将来有代码用 `@JitBind` 为 `ActionContext` 登记真实绑定，会被这里覆盖成空。功能上目前没有第二个写入者，所以只影响构建耗时
- **建议**：用 `JitBindSupport.isInterface(owner)`（`JitBindSupport.cj:156-158`）判断是否已登记，已登记则跳过；同时把 `enrollInterfaceOf` 移进「首次注册」分支内，避免用空绑定覆盖已有项

<!-- 第 11 部分 -->

### [一般][存量] #1 流式 XLSX 两条路径都不释放 `ExcelSheetStream`：`RowReader` 只在读到头才关，编译中途失败即泄漏

- **位置**：`f_rule/src/table/XlsxTableParser.cj:106-119`（`stream(path)` 建 `ExcelSheetStream` 后交给 `XlsxTableStream`，全流程无 `stream.close()`）、`f_rule/src/table/XlsxTableParser.cj:771-777`（`XlsxRowSource.rows()` 每次新开 `RowReader`）、`f_rule/src/table/XlsxTableParser.cj:857-870`（`warnMergedRanges()` 是唯一 `reader.close()`，只在 `reader.next()` 返回 `None` 时触发）
- **来源**：存量（`git blame`：`4e765c37c4 2026-11-01`，`stream` 与 `XlsxRowIterator` 同一提交）
- **判据**：review-checklist §11「资源不对称：打开未关、异常跳过释放」
- **证据**：静态确定 —— `ExcelSheetStream` 明确要求显式关闭才能释放 ZIP 句柄与 spool 临时目录（`f_excel/src/ExcelSheetStream.cj:357-377`：`close()` 里 `zip.close()`、删 `spoolDir`）；`RowReader.close()` 关的是单个 sheet 的条目流（同文件 `82-91`）。f_rule 侧全包搜 `close()` 只有 `XlsxTableParser.cj:137`（读 `_meta`）、`:177`（读表头/类型行）、`:869`（读到流尾）三处，**没有任何** `stream.close()`。
- **描述**：三类可复现的泄漏面：
  1. `XlsxTableParser.stream(path)` 返回的迭代器把 `ExcelSheetStream` 一直挂在 `XlsxTableStream.stream`（`:721`）里，即使把所有 sheet 迭代完也不会关，ZIP 句柄（`open(input)` 场景还有落盘的 spool 临时目录）活到 GC 或进程结束；
  2. `TableCompiler.compile()`（`f_rule/src/table/TableCompiler.cj:178`）遍历 `rowIterator()` 时，任何一行触发 `TABLE_INVALID` / `TYPE_MISMATCH`（例如 `CellParser` 值解析失败、`render` 遇到 `Error` 单元格）都会抛出并丢弃迭代器 ⇒ 该 sheet 的 `RowReader` 永不关闭，而此时 `ExcelSheetStream` 仍被表模型引用，等于条目不释放；
  3. `XlsxRowIterator` 没有破坏性释放路径（无 `finally`、`Iterator` 也无 `close` 约定），调用方无法主动收尾。
- **建议**：`XlsxTableParser.stream` 的返回类型改为自带 `close()` 的迭代器（或返回 `(Iterator<DecisionTable>, () -> Unit)`），把 `stream.close()` 交给调用方；更省事的做法是 `XlsxTableStream` 在 `next()` 返回 `None` 时自行 `stream.close()`，并让 `TableCompiler.compile()` 用 `try { ... } finally { 关闭行来源 }` 包住 `rowIterator()` 循环——为此需要给 `TableRowSource` 加 `func close(): Unit`（默认空实现，`XlsxRowSource` 覆盖为 `reader.close()`）。

### [一般][存量] #2 「流式大表内存与行数无关」的承诺在编译/执行路径不成立：每行仍物化成 `CompiledRow + Rule + Pattern` 并常驻

- **位置**：`f_rule/src/table/XlsxTableParser.cj:53-54`（类注释："`ExcelSheetStream` 走流式路径（大表，内存与行数无关）"）、`f_rule/src/table/XlsxTableParser.cj:101-105`（"10 万行的表也只有一行在内存里"）；反证：`f_rule/src/table/TableCompiler.cj:175-184`（`for (row in table_.rowIterator())` 逐行 `rows.add(compiled)` + `rules.add(compiled.rule)`）、`f_rule/src/table/TableExecutor.cj:43-44`（`compiled_` 随执行器长期持有）
- **来源**：存量（`git blame`：注释 `4e765c37c4 2026-11-01`，编译循环 `4e765c37c4 / 57e7cd67f6`）
- **判据**：review-checklist §14.1「承诺了但没实现（契约与实现不符）」、§5「一次性物化」
- **证据**：静态确定（对象数）+ 需实测（字节量）——`CompiledTable.rows` 长度恒等于数据行行数，`CompiledRow` 内嵌 `TableRow`（含 `Array<?String>`）、`Rule`（含 `Pattern` 与输出闭包捕获的 `Array<CompiledOutput>`）、`conditions`/`outputs` 两个数组；`CompiledTable.rules` 再持一份同样的 `Rule` 指针。100 000 行 ⇒ 至少 10 万 × (1 `CompiledRow` + 1 `Rule` + 1 `Pattern` + 2~3 个数组) 个对象常驻，按每行 0.4–0.8 KB 估算约 40–80 MB（量级待实测）。同一个 `TableExecutor` 还会被 `RuleEngine` 按 `id@version` 缓存到引擎生命周期（`f_rule/src/engine/RuleEngine.cj:110-111`），不会随一次调用释放。
- **描述**：文档与类注释把"10 万行"作为流式入口的卖点，测试 `XlsxTableParser_test.cj:600-630`（T-14）也只断言 `table.rows.isEmpty()` 与逐行可读，**没有**覆盖"编译/执行后仍不物化"。实际链路是"读取流式、编译物化"：只要表被编译（无论议程路径还是 `TableExecutor`），内存就回到 O(行数)，`stream()` 只省了原始单元格文本那一层。
- **建议**：两个方向二选一，并在文档写清：(a) 把注释/文档改成"读取阶段内存与行数无关；编译后每行一条规则，内存为 O(行数)"，同时给 T-14 补一条"编译 10 万行后 `getUsedHeapSize()` 增量"的用例；(b) 若确实要保住 O(1) 行内存，聚合路径需要改成"边读边判边聚合"（`TableExecutor` 不缓存 `CompiledRow`，只保留命中行），这需要把 `HitAggregator` 改成流式累加器（见优化方案 3）。

### [一般][存量] #3 `Any` 策略多命中时返回全部行，与 `TableResult` 文档契约「单值策略至多一条」冲突

- **位置**：`f_rule/src/table/HitAggregator.cj:87-89`（`case Any => ensureConsistentOutputs(hits); return hits`）；契约源：`f_rule/src/table/TableResult.cj:23-24`（注释："`outputs` 与 `hits` 一一对应（`Collect` 类策略多条，单值策略至多一条）"）、`f_rule/doc/07-decision-table.md:404`（"单值时 size == 1，Collect 类策略时可能多条"）
- **来源**：存量（`git blame`：`57e7cd67f6 2026-10-31`）
- **判据**：review-checklist §11「契约与实现不符」、§3「空实现/契约语义错位」
- **证据**：静态确定 —— `Any` 分支只做一致性校验后原样返回 `hits`（N 条）；`TableResult.outputs` 在 `TableExecutor.cj:75-78` 逐条展开，因此 `Any` 且 N 行命中时 `outputs.size == N`，而 `Any` 不在文档所列的 `Collect 类策略`（`Collect` / `RuleOrder` / `OutputOrder`）之内。测试 `HitPolicy_test.cj:96-101` 已把该行为写成断言（`@Assert(ids(...), ["R1", "R2"])`），说明是有意实现但与契约文字相反；DMN 对 `Any` 的语义也是"任取一条输出"。
- **描述**：调用方若按契约写 `result.outputs[0]` + 断言 `size == 1`（`Any` 是"多行命中但输出必须一致"的策略，本就只该有 1 条输出），会拿到 N 条重复输出；对下游"取唯一输出"的消费逻辑（例如把 outputs 直接当事件负载写出）会造成 N 倍重复。反过来若按现状写，则与文档冲突。
- **建议**：择一并同步三处：把 `Any` 改为 `return [hits[0]]`（与 DMN、文档一致，测试改为断言 size==1 且输出一致），或把 `TableResult.cj:23-24` 与 `doc/07:404` 改成"`Any`/`Collect` 类策略可能多条"。前者更符合策略语义，改动只在 `HitAggregator.cj:87-89` 一行 + 一条测试。

### [一般][存量] #4 `${binding}` 整事实输出与 `Any` / `Priority` / `OutputOrder` 的组合在聚合期抛 `TYPE_MISMATCH`

- **位置**：输出侧 `f_rule/src/table/OutputCell.cj:98-101`（`BindingRef` 直接把 `Fact` 当 `Any` 返回）；聚合侧 `f_rule/src/table/HitAggregator.cj:121-134`（`sameOutputs` → `ValueKey.of(value)`）、`:138-146` / `:177-184`（`compareOutputs` / `compareValue` → `ValueKey.of`）
- **来源**：存量（`git blame`：`57e7cd67f6 2026-10-31`）
- **判据**：review-checklist §11「逻辑错误 / 契约承诺但实现不支持」
- **证据**：静态确定 —— `ValueKey.of` 只接受 `String/整数/浮点/Decimal/Bool/DateTime/Array<Any>/Set<Any>`，其余一律抛 `RuleException(TYPE_MISMATCH, "ValueKey 不支持的值类型…")`（`f_rule/src/fact/ValueKey.cj:96-129`，`124-128` 是兜底 `_ =>` 抛出）。而 `${binding}` 是**文档化的输出形态**（`doc/07-decision-table.md:191`：`${<binding>}  # 整个事实`），`OutputCell.resolve` 返回的正是 `Fact` 对象，`TableExecutor.outputsOf`（`TableExecutor.cj:158-169`）把它原样塞进 `HashMap<String, Any>`。
- **描述**：下表任一行成立即在运行期抛异常（表定义本身完全合法、编译期不报错）：

  | hitPolicy | 触发条件 | 抛错点 |
  | --- | --- | --- |
  | `Any` | ≥2 行命中且输出含 `${o}` | `sameOutputs` → `ValueKey.of(Fact)` |
  | `Priority` | ≥2 行命中且 `outputOrder` 含该输出槽 | `prioritySorted` → `compareValue` |
  | `OutputOrder` | ≥2 行命中 | `sorted` 的比较器 → `compareValue` |
  | `Collect` / `First` / `Unique` / `RuleOrder` | — | 不比较输出，正常 |

  抛出的错误码是 `TYPE_MISMATCH`（数据问题），而根因是"输出值类型超出聚合比较器支持范围"，排障会指向错误的表/字段。附带问题：`TableResult.outputs` 中出现 `Fact` 对象后，任何按标量序列化/日志化的下游（如把 outputs 直接转 JSON）都会失败。
- **建议**：在 `TableCompiler.compileOutputs`（`TableCompiler.cj:332-358`）就拒掉"`BindingRef` 输出 + 需要比较输出的策略"组合并抛 `TABLE_INVALID`（带列名与策略名），或在 `HitAggregator.compareValue`/`sameOutputs` 里对 `Fact` 走引用相等（`ValueKey` 不做比较，直接用 `refEq`），同时补一条 `${o}` + `Any` 的两行命中用例。

### [一般][存量] #5 命中排序用插入排序 O(n²)：`RuleOrder` / `OutputOrder` 在 10 万行命中时退化为平方级

- **位置**：`f_rule/src/table/HitAggregator.cj:187-204`（`sorted`：插入排序）、`:100-103`（`prioritySorted` 复用同一排序）、`:163-173`（`orderedNames` 里另写一遍 `String` 版插入排序）
- **来源**：存量（`git blame`：`57e7cd67f6 2026-10-31`）
- **判据**：review-checklist §6.4「低效算法：每请求排序用 O(n²)」、§2「只改类型名的重复实现」
- **证据**：静态确定（复杂度）——`sorted` 的双层 `while` 是教科书插入排序，比较次数 = O(n²)（逆序时最坏）；输入规模 n = **命中行数**，上界由表行数决定，而本模块主打的流式表就是 10 万行（`XlsxTableParser.cj:101-105`）。**未做耗时实测**，故不声称端到端占比或收益百分比（见「待验证假设」5）。
- **描述**：`Collect` 直接返回不做排序，所以不受影响；但 `RuleOrder`（按 salience 降序）与 `OutputOrder`（按输出值）对所有命中行排序，`Priority` 也先全排序再取 `[0]`。一张"宽条件"表（例如所有行都满足 `level >= 1`）在 10 万行规模下命中数≈行数，10¹⁰ 量级比较，单次 `execute` 可能从毫秒级掉到分钟级；`Priority` 只需最小值，却付了全排序的代价。
- **建议**：`sorted` 换成稳定排序（`std.sort.sort` 不保证稳定，可先按行序编号做二级键，或用 `ArrayList.sort` 的自定义比较把"行序"作为 tie-break）；`Priority` 改为单趟取最小（O(n)）；`orderedNames` 的 `String` 插入排序改 `ArrayList<String>.sort()` 或直接用 `names.sort()`（排序后顺序即输出顺序，稳定性无意义）。改完补等价性用例（同 salience 保持行序、缺失输出键排最后）。

### [轻微][存量] #6 `markAssembled` / `markExecuted` 在编译之前执行：编译失败后实例被永久锁在单一模式

- **位置**：`f_rule/src/table/DecisionTable.cj:233`（`markAssembled()` 在 `TableCompiler(...).compile()` 之前）、`:243`（`compileInto` 同）、`:115-127`（`markExecuted`）；调用点 `f_rule/src/table/TableExecutor.cj:52`（构造期先 `markExecuted()` 再编译）
- **来源**：存量（`git blame`：`5702078ebc 2026-11-01`）
- **判据**：review-checklist §11「错误处理缺失 / 状态机残留」
- **证据**：静态确定 —— 编译抛错（`UNKNOWN_FACT_SPACE`、`UNKNOWN_FIELD`、`TYPE_MISMATCH`、空表…）时 `mode_` 已被写成 `Assembled` / `Executed`，`compile()` 与 `TableExecutor` 构造都没有回滚路径。
- **描述**：错误恢复场景（改注册表后重试另一条路径、在配置错误后想改用 `TableExecutor` 调试）会得到与真实原因无关的 `TABLE_MODE_CONFLICT`；`TableAssembly_test.cj:74-100`（AS-03/AS-05）本身就制造了这种"失败后实例被标记"的状态，只是没有断言。
- **建议**：把 `markXxx()` 挪到编译成功之后（`compile()` 返回前），或失败时在 `catch` 里恢复 `Unbound`；`TableExecutor` 同理改成"编译成功 → `markExecuted` → 赋值字段"。这样 `mode` 才真实反映"已被成功使用"。

### [轻微][存量] #7 `CsvScanner.start` 字段只写不读（死字段）

- **位置**：`f_rule/src/table/CsvTableParser.cj:44`（`private let start: Int64`）、`:53-56`（构造里 `this.start = start` 后再无引用）
- **来源**：存量（`git blame`：`57e7cd67f6 2026-10-31`）
- **判据**：review-checklist §1「读了不用 / 死字段」，机械动作第 6 条
- **证据**：静态确定 —— 全仓搜 `start` 在 `CsvTableParser.cj` 内只命中 `44`（声明）、`53`/`55`（形参/赋值）、`56`（`this.index = start` 用的是形参）、`199-203`（`parseBytes` 的局部变量，与字段无关）；`CsvScanner` 的扫描逻辑全部基于 `index`，`start` 字段没有任何读者。
- **建议**：删掉字段与 `this.start = start`，构造函数保留形参直接 `this.index = start`。

### [轻微][存量] #8 `TableExecutor.evaluate` 无候选分支里的 `let _ = condition` 是空转语句

- **位置**：`f_rule/src/table/TableExecutor.cj:108-115`（`110` 行 `for (condition in row.conditions)`、`111` 行 `let _ = condition`）
- **来源**：存量（`git blame`：`57e7cd67f6 2026-10-31`）
- **判据**：review-checklist §1「不可达/无效语句：局部 `let` 赋值后不被读取」
- **证据**：静态确定 —— `let _ = condition` 的唯一作用是消掉"循环变量未使用"的告警，循环体真正做的事只有 `unknowns.add(Truth.False)`，等价于按条件数补 `False`。
- **建议**：整段替换为 `results = Array<Truth>(row.conditions.size, repeat: Truth.False)`（一次分配、无中间 `ArrayList`），同时消掉这条死语句。

### [轻微][存量] #9 `XlsxRowIterator` 耗尽后再 `next()` 抛 `ExcelException`，与同包其它迭代器行为不一致；且行读取异常未折算成 `RuleException`

- **位置**：`f_rule/src/table/XlsxTableParser.cj:805-819`（`next()` 走 `reader.next()`，`None` 分支调 `warnMergedRanges()` → `reader.close()`）、`:857-870`（唯一的 `close()`）
- **来源**：存量（`git blame`：`4e765c37c4 2026-11-01`）
- **判据**：review-checklist §11「契约不符 / 错误类型泄漏」、§3「错误处理不完善」
- **证据**：静态确定 —— `RowReader.next()` 在 `closed` 后直接 `throw ExcelException("流已关闭")`（`f_excel/src/ExcelSheetStream.cj:64-67`，`close()` 在 `82-91`）。`XlsxRowIterator` 在返回第一个 `None` 前就 `close()` 了 reader，因此第二次 `next()` 必抛；同包的 `XlsxEmptyRowIterator`（`:781-785`）与整表路径的 `rows.iterator()` 都会稳定返回 `None`。此外 `reader.next()` 在解析损坏的 sheet XML 时抛的 `ExcelException`（f_excel 类型）会原样穿过 `TableCompiler.compile()`，与"表问题统一 `RuleException(TABLE_INVALID)`"的约定（`openDocument`/`stream` 都做了折算，`:257-268`、`:107-116`）不一致。
- **建议**：`next()` 加 `if (finished) { return None<TableRow> }` 的幂等守卫；在 `TableCompiler` 的行循环（或 `XlsxRowIterator.next()` 外层）用 `catch (e: ExcelException)` 折算为 `RuleException(TABLE_INVALID, "sheet X 第 N 行读取失败: ...")`。

### [轻微][存量] #10 `==` / `!=` 用 `toString()` 字符串比较，三份逐字重复

- **位置**：`f_rule/src/table/TableMode.cj:40-46`、`f_rule/src/table/HitPolicy.cj:54-60`、`f_rule/src/table/Column.cj:38-44`（三处函数体只有类型名不同）
- **来源**：存量（`git blame`：`57e7cd67f6 2026-10-31`）
- **判据**：review-checklist §2「只改类型名的重复实现」
- **证据**：静态确定 —— 三个 `enum` 的 `==` 都是 `this.toString() == other.toString()`，`!=` 都是 `!(this == other)`；`toString()` 本身是 `match` 到字面量，等价于按变体比较，但每次比较都分配两个 `String`（`HitPolicy.parse`、`Column.parse` 的频繁判断都走这条路径）。
- **建议**：无参 enum 的相等可直接 `match` 枚举变体（或对单例变体用引用比较），至少把三份样板收敛为一次显式 `match`；若语言版本支持，让三个 enum 各自实现 `Equatable` 的 `match` 版本，避免相等判断走字符串。若判定收益不足，至少加注释说明"用 toString 比较是为了避免变体字段比较"。

### [轻微][存量] #11 `_meta` → `DecisionTableBuilder` 的属性映射在 CSV / XLSX 各写一份（含 `salience` 解析三份）

- **位置**：`f_rule/src/table/CsvTableParser.cj:224-259` 与 `f_rule/src/table/XlsxTableParser.cj:494-531`（8 个键逐个 `match`）；另 `salience` 解析三份：`CsvTableParser.cj:324-333`、`XlsxTableParser.cj:543-552`、`TableCompiler.cj:378-400`
- **来源**：存量（`git blame`：`57e7cd67f6 2026-10-31`）
- **判据**：review-checklist §2「换控制流 / 字面量复制：同一组字段名散落多处」
- **证据**：静态确定 —— 两处处理的键集合完全相同（`name`/`version`/`factspace`/`facttype`/`hitpolicy`/`salience`/`outputorder`），`outputorder` 的"逗号切分 + trim + 丢空段"逻辑逐行相同；**已知差异**只有三点：XLSX 额外对 `_meta.id` 与 sheet 名不一致打 WARN（`XlsxTableParser.cj:532-540`）、CSV 的 `salience` 错误文案是 `# salience 必须是整数`、XLSX 的是 `_meta.salience 必须是整数`。三处 `salience` 都是"`Int64.parse` 失败 → `TABLE_INVALID`"。
- **描述**：同一张表用 CSV 与 XLSX 两种载体承载时，属性行为已出现分叉风险（XLSX 有 id 校验、CSV 没有；错误文案不同），而 T-12 等价性用例（`XlsxTableParser_test.cj:546-577`）只比对 `id/name/version/factSpace/hitPolicy/salience` 的**值**，比不出这类漂移。
- **建议**：在 `table` 包内抽 `applyMeta(builder, meta: HashMap<String,String>, tableId: ?String)` 与 `parseSalience(text, context)`（两个解析器同包，抽取不跨层），把"是否校验 id"作为可选参数（XLSX 传表名、CSV 传 `None`）；`TableCompiler` 的行级 `salience` 保留独立实现但复用同一个 `parseSalience`。

### [轻微][存量] #12 `HitAggregator` 内三处排序样板：`prioritySorted` 与 `OutputOrder` 分支函数体逐行相同，另有两份插入排序

- **位置**：`f_rule/src/table/HitAggregator.cj:94-96`（`OutputOrder` 分支）与 `:100-103`（`prioritySorted`）：同为 `let names = orderedNames(hits); sorted(hits) { ... compareOutputs(...) == Ordering.LT }`；`:163-173`（`String` 插入排序）与 `:187-204`（`TableHit` 插入排序）
- **来源**：存量（`git blame`：`57e7cd67f6 2026-10-31`）
- **判据**：review-checklist §2「换控制流 / 只改类型名」
- **证据**：静态确定 —— `prioritySorted` 只有 `aggregate` 一处调用（`:85`），其函数体与 `OutputOrder` 分支完全一致，唯一差别是调用方后续取 `[0]`；两处插入排序外层循环结构逐行相同，只有元素类型与比较谓词不同。
- **建议**：删掉 `prioritySorted`，`Priority` 分支复用同一条排序后取 `[0]`（或按 #5 改成单趟取最小）；`orderedNames` 的排序改调 `ArrayList<String>.sort()`，与 #5 的 `sorted` 替换一起做。

### [轻微][存量] #13 「单绑定 + 逐输出槽解析」逻辑在 `TableExecutor` 与 `TableCompiler` 各写一遍

- **位置**：`f_rule/src/table/TableExecutor.cj:158-169`（`outputsOf`：建 `HashMap<String,Fact>`、填 `bindings[compiled_.binding]=fact`、遍历 `row.outputs` 调 `cell.resolve`）与 `f_rule/src/table/TableCompiler.cj:361-376`（`actionFor` 返回的闭包：建同一个 `HashMap`、`ctx.fact(binding)`、同样遍历 `outputs` 调 `cell.resolve`）
- **来源**：存量（`git blame`：`57e7cd67f6 2026-10-31`）
- **判据**：review-checklist §2「跨层复制：输入-输出-副作用相同，只改写入目标」
- **证据**：静态确定 —— 两段都是"1 个绑定 → `HashMap<String, Fact>` → 对每个 `CompiledOutput` 调 `resolve` → 有值则写入"，差别只在写入目标是 `HashMap<String, Any>` 还是 `ActionContext.set`；`resolve` 的 `None` 语义（缺绑定/缺字段静默跳过）也在两处各判一次。
- **建议**：抽 `private func resolveOutputs(outputs: Array<CompiledOutput>, binding: String, fact: ?Fact): Array<(String, Any)>`，两处各自消费结果（executor 填 map、action 调 `ctx.set`）。注意保留差异：executor 的 `fact` 来自命中事实、action 的来自 `ctx.fact(binding)`，抽取时以 `?Fact` 入参。

### [轻微][存量] #14 数值字面量推断与表头宽度计算各有两套近似实现

- **位置**：`f_rule/src/table/CellParser.cj:175-188`（`number`：`contains(".")/"e"/"E"` → `Float64.parse`，否则 `Int64.parse`，失败抛 `TYPE_MISMATCH`）与 `:266-287`（`infer`：同样判 `contains(".")/"e"/"E"` 走 `Float64.parse`，否则 `Int64.parse`，失败静默继续）；`f_rule/src/table/XlsxTableParser.cj:302-312`（`headerWidth`：`while (width < cols)` 读 `cellText(1, width+1)` 到空为止）与 `:184-190`（`streamLayout` 内的同逻辑，只是数据源换成 `streamCellText`）
- **来源**：存量（`git blame`：`57e7cd67f6 2026-10-31` / `4e765c37c4 2026-11-01`）
- **判据**：review-checklist §2「换算复制 / 近似重复」
- **证据**：静态确定 —— 数字判定表达式完全相同（`text.contains(".") || text.contains("e") || text.contains("E")`），`infer` 只是把异常静默后继续尝试 Bool/时间；两处表头宽度都是"从第 1 列起连续非空单元格数"，`parse()` 里 `:74` 与 `parseWorksheet` 里 `:327` 还会对同一 sheet 各算一次。
- **描述**：`infer` 与 `number` 的差异（一个抛错、一个回退）是业务需要，可以保留，但"是否为实数字面量"的判据重复后一旦修改（例如支持 `Infinity`/`_` 分隔符）必须同步两处；表头宽度两份实现在"空格也算断开"的边界上必须永远一致，否则整表路径与流式路径对同一文件会得到不同列数。
- **建议**：`CellParser` 抽 `private func looksReal(text: String): Bool`；`XlsxTableParser` 抽 `private func headerWidthOf(textAt: (Int64) -> String, limit: Int64): Int64`，两条路径各传自己的取单元格函数（顺带消掉 `parse()` 的重复计算）。

**存量合计 14 条**（严重 0 / 一般 5 / 轻微 9），是否纳入修复待用户决定。

<!-- 第 12 部分 -->

### [严重][存量] #1 B-02 的激活等价性比对只覆盖前 20 条，1000 条激活中 980 条未被核对

- **位置**：`f_rule/src/test/PerfInsert_test.cj:84`（比对），`f_rule/src/test/PerfInsert_test.cj:180`（`joinKeys` 截断）
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §11（契约与实现不符）/ §3（门禁承诺的行为未落实）
- **证据**：静态确定 —— `activationKeys`/`naiveKeys`（`:164`、`:172`）各自 `PerfSupport.sortedKeys` 排好全部 1000 个键，但随后 `joinKeys` 的循环条件是 `while (i < keys.size && i < 20)`（`:183`），两侧文本只拼前 20 个键；`reteText != naiveText`（`:86`）因此只比较字典序最小的 20 条激活。
- **描述**：方法 docstring 承诺"激活集合与 `NaiveMatcher` 逐条比对（含激活数），比对不计时"（`:30`-`:31`）。实际只做了"总数相等 + 前 20 条相同"。若实现把第 21..1000 条激活绑定到错误的事实实例，`left.size == right.size` 与 20 条前缀都可能同时成立，B-02 依然绿。同模块 `Differential_test.expectEqual`（`:120`-`:136`）用的是无截断的 `joinKeys`（`:170`），说明这是 B-02 单点的口径退化，不是统一设计。
- **建议**：比对与提示信息分离：新增无截断的 `fullKeys()` 用于相等判定（或直接逐下标比较两个已排序数组），截断版只用于异常消息里打印前 N 条 + `firstDiff`（`:190` 已有）定位首个差异。

### [一般][存量] #2 等价性断言在"两侧都为空/都未命中"时恒真

- **位置**：`f_rule/src/test/Differential_test.cj:58`、`f_rule/src/test/Differential_test.cj:73`；`f_rule/src/test/Integration_test.cj:187`
- **来源**：存量（工作区快照）
- **判据**：review-checklist §11（契约与实现不符）/ §14 类似口径（承诺的能力无有效断言）
- **证据**：静态确定 —— `Differential_test` 只断言 `runtime.activations()` 与 `NaiveMatcher` 结果集合相等，200 组里没有任何一组要求"激活数 > 0"或"累计激活数达到下界"；`Integration_test.i03` 只比较 `jitOutputs.contains("hit")` 与 `interpretedOutputs.contains("hit")` 的布尔值。
- **描述**：两侧同时"什么都不产出"时断言成立。若 Rete 与朴素匹配同时漏掉某类模式组合（例如两边共用的 `Pattern.matches` 语义被改错、或 generate 出的规则全部退化），差分用例不会失败。I-03 的名字与 docstring 是"逐条给出相同结论"，但没有任何一条断言要求"至少有一条第命中"，JIT 路径整体失效也能通过。
- **建议**：`reteMatchesNaiveAcrossRandomCases` 累计总激活数并在循环结束后断言 `total > 0`（或按种子给出解析下界）；`i03JitAndInterpreterAgreePerFact` 增加对命中性的事实级期望（`samples[1]`、`samples[3]` 必须为 `true`，其余为 `false`）。

### [一般][存量] #3 B-05 内存门禁可静默通过，且判据口径依赖进程内前序用例

- **位置**：`f_rule/src/test/PerfMemory_test.cj:38`（取基线）、`f_rule/src/test/PerfMemory_test.cj:50`（门禁）；`f_rule/src/test/PerfSupport.cj:148`（`rssBytes`）
- **来源**：存量（工作区快照）
- **判据**：review-checklist §3（静默失效）+ §5（上限判定必须可量化和可拒绝）
- **证据**：静态确定 —— `rssBytes()` 在 `/proc/self/status` 里找不到以 `VmRSS:` 开头的行时返回 `-1`（`PerfSupport.cj:166`）；`requireBelow("B-05 RSS", -1, 512MB)` 的判定是 `actual >= limit`（`PerfSupport.cj:189`），`-1` 必然通过。同时 `baseline`、`afterGc`、`delta` 三者只在 `println`（`PerfMemory_test.cj:48`）里出现，不参与门禁；`requireBelow` 用的是进程绝对 RSS。
- **描述**：两层风险。① procfs 若被裁剪或字段改名（找不到 `VmRSS:` 行），门禁从"未达标"变成"通过"而无任何提示，属于典型的静默失效。② 绝对 RSS 里包含同进程前序用例的残留：`PerfNetwork_test.b01` 持有 6 套 1000 条规则的 `RuleSet`（`PerfNetwork_test.cj:42`-`:47`），`ShardedNetwork` 还有一个静态单槽结构缓存（`src/rete/ShardedNetwork.cj:51`-`:52`），所以 B-05 的读数与用例执行顺序相关，而基线差值又不参与判定。
- **建议**：`rssBytes()` 失败返回 `-1` 时直接抛异常（或让 `requireBelow` 拒绝非正数实测值）；门禁改为判定 `used - afterGc`（增量）并同时打印基线，把绝对上限保留为辅助信息；必要时在 B-05 开头 `gc()` 两次并显式丢弃前序缓存引用。

### [一般][存量] #4 `sameActivations` 用"集合包含"代替"多重集相等"，重复/缺失激活互相掩盖

- **位置**：`f_rule/src/test/ReteNetwork_test.cj:176`
- **来源**：存量（工作区快照）
- **判据**：review-checklist §11（边界/语义与命名不符）+ §6.4（热点 O(n·m) 扫描，测试规模小仅作附注）
- **证据**：静态确定 —— 先判 `actual.size != expected.size`（`:177`），再对 `left` 每个键在 `right` 里做一次线性查找（`:191`-`:196`）。`left = [A, A]`、`right = [A, B]` 时长度相等且 `A` 命中，函数返回 `true`，`B` 从未被检查。
- **描述**：R-01/R-11 的"与朴素匹配逐条比对"（文件头 docstring `:33`）在多激活场景下不成立：Rete 产出重复激活（同一规则同一绑定被加入两次）或少产出但恰好被另一个激活补位时不会失败。`RecordingSink.add` 对同键激活做槽位覆盖（`src/rete/RecordingSink.cj:41`-`:46`），所以重复激活本身会被吞掉，这个盲区正好遮住了"重复加入"这一类回归。
- **建议**：两侧 `sortKey` 各自排序后按下标逐个比较（可直接复用 `PerfSupport.sortedKeys`），既得到多重集相等，也把 O(n·m) 降为 O(n log n)；失败时用首个不等下标给出差异。

### [一般][存量] #5 `PropertyGen.next` 对负种子产生负伪随机数，导致 0 模式规则（`EMPTY_PATTERN`）或指向不存在绑定的 join

- **位置**：`f_rule/src/test/PropertyGen.cj:37`（`next`）、`f_rule/src/test/PropertyGen.cj:114`（`patternCount`）、`f_rule/src/test/PropertyGen.cj:130`（`previous`）
- **来源**：存量（工作区快照）
- **判据**：review-checklist §11（边界未校验）；语言语义见 `docs/dev-guide/source_zh_cn/basic_data_type/basic_operators.md:65`（取余定义为 `a - b * (a / b)`，被除数为负时结果为负）
- **证据**：静态确定 —— `public init(seed!: Int64 = 20261031)` 接受任意 `Int64`；`state = (state * 1103515245 + 12345) % 2147483648` 在 `seed < 0` 时结果保持负号，`next(bound)` 的 `(state / 65536) % bound` 可以是负数（`bound <= 0` 的保护只在 `:39` 挡住非正上界，挡不住负返回值）。于是 `patternCount = 1 + next(5)` 可能 ≤ 0，`:117` 的循环一次不执行，`builder.build()` 因 `patterns_` 为空抛 `EMPTY_PATTERN`（`src/rule/rule.cj:204`-`:209`）；`previous = next(j)` 可能为负，`:131` 拼出 `"b-3"` 这类不存在的绑定名。
- **描述**：默认种子为正，当前用例不触发，但 `seed!` 是公开参数（文档写明"默认种子 `20261031`，保证差分失败可复现"，暗示可由调用方指定）。一旦传入负数，失败现场是 `Rule.build()` 抛 `EMPTY_PATTERN` 或 `RuleSetBuilder.build()` 抛 `UNKNOWN_BINDING`，错误码指向"规则没有任何模式"，与"种子取值非法"这个真实原因无关，排查成本高。
- **建议**：`init` 里对 `seed` 取 `abs`（或 `% 2147483648` 后加模数保证非负），`next` 里对返回值再做一次 `if (r < 0) r = -r`；`randomRules` 对 `patternCount` 取 `max(1, ...)`；三条都对，才能在改种子时保持"可复现但不退化"。

### [一般][存量] #6 激活排序键在测试基准里另写一份，与生产 `Bindings.sortKey` / `Activation.key_` 靠注释约定同步

- **位置**：`f_rule/src/test/NaiveMatcher.cj:62`（`NaiveActivation.sortKey`）对照 `src/agenda/Bindings.cj:132`（`Bindings.sortKey`）、`src/agenda/Activation.cj:52`（`key_`）
- **来源**：存量（工作区快照）
- **判据**：review-checklist §2（跨层复制 / 字面量复制导致行为漂移）
- **证据**：静态确定 —— `NaiveActivation.sortKey` 自己拼 `"${factSpace}|${ruleId}|"`、自己调 `bindings.names()`、自己对名字做一轮排序、自己拼 `name=identity-or-?;`；`Bindings.sortKey` 做的是同一件事，只是把非 `IdentifiedFact` 的情况交给 `handleKey`（`Bindings.cj:149`）而不是硬编码 `"?"`（`NaiveMatcher.cj:84`、`:86`）。两者唯一的同步机制是 `Activation.cj:27`-`:28` 的一句注释"`sortKey()` 与测试基准 `NaiveActivation.sortKey()` 保持同一格式，差分测试依赖这一点"。
- **描述**：`Activation.key_` 同时是判等键（`Activation.cj:82`-`:83`），差分用例靠字符串相等判定"同一激活"。生产侧格式只要变一次（例如 `handleKey` 改成带空间前缀、或 `Bindings.names()` 加前缀），朴素基准不会跟着变，差分测试会以"激活集合不一致"大面积失败，而真正原因是基准漂移；反向漂移则更糟——两侧都"错得一致"，差分永远绿。
- **建议**：`NaiveActivation.sortKey` 改为 `"${rule.factSpace}|${rule.id}|${bindings.sortKey()}"`（`Bindings.ofFacts` 的 handles 为空，`handleKey(None)` 就是 `"?"`，输出逐字符等价），把格式定义收敛到 `Bindings` 一处；同时在 `Bindings_test` 里加一条"格式快照"用例锁住契约。

### [轻微][存量] #7 同一套插入排序在 4 个位置逐行重复

- **位置**：`f_rule/src/test/PerfSupport.cj:195`（`sortedKeys`）、`f_rule/src/test/PerfSupport.cj:214`（`sorted`）、`f_rule/src/test/Differential_test.cj:156`（`sort`）、`src/agenda/Bindings.cj:165`（`sortNames`）
- **来源**：存量（工作区快照）
- **判据**：review-checklist §2（只改类型名的重复）
- **证据**：静态确定 —— 四段代码除容器元素类型（`String` / `Int64`）与函数名外逐行相同：`let current = items[i]` + `while (j >= 0 && items[j] > current)` 后移 + 回填 + `i += 1`。
- **描述**：`PerfSupport.sorted` 与 `sortedKeys` 之间的重复是纯粹的类型差异；`Differential_test.sort` 与 `sortedKeys` 完全同签名，等于复制了一份。这类复制在"修改比较规则（例如改成忽略大小写或按数值排序）"时必然漏改一处，而排序结果直接决定差分比对的结论。
- **建议**：`Differential_test.sort` 直接删掉改用 `PerfSupport.sortedKeys`；`PerfStats` 走 `std.sort`（`sort/sort_package_api`）或一个带 `Comparable` 约束的泛型 `sorted<T>`；`Bindings.sortNames` 属生产代码，可保留独立实现但建议加注释说明"不依赖测试包"。

### [轻微][存量] #8 `NaiveActivation.specificity` 复制 `Activation.specificityOf` 的公式

- **位置**：`f_rule/src/test/NaiveMatcher.cj:51` 对照 `src/agenda/Activation.cj:56`
- **来源**：存量（工作区快照）
- **判据**：review-checklist §2（同语义实现两份）
- **证据**：静态确定 —— 两处都是 `Int64(rule.patterns.size)` 起算，再累加 `pattern.constraints.size`，无任何差异；`NaiveActivation.specificity` 全仓零引用（见下条）。
- **描述**：冲突消解排序依赖 `specificity`（`src/agenda/ConflictResolver.cj:35`），若将来把"否定约束计 2 分"之类规则加进生产实现，基准类不会跟着变；当前它甚至没人用，属于"为了对称而留"的死重量。
- **建议**：直接调用 `Activation.specificityOf(rule)`，或删除该属性（见下条可见性建议）。

### [轻微][存量] #9 可见性建议：4 个对外可达的测试辅助成员全仓零引用

- **位置**：`f_rule/src/test/NaiveMatcher.cj:51`（`NaiveActivation.specificity`）、`f_rule/src/test/PerfSupport.cj:77`（`PerfStats.mean`）、`f_rule/src/test/PerfSupport.cj:115`（`PerfStats.raw`）、`f_rule/src/test/PropertyGen.cj:46`（`PropertyGen.facts`）、`f_rule/src/test/PropertyGen.cj:61`（`PropertyGen.rules`）
- **来源**：存量（工作区快照）
- **判据**：review-checklist §1（按硬原则一，`public` 且对外可达**不判死代码**，此处只作可见性建议）
- **证据**：静态确定 —— 全仓 `grep -rn` 仅命中定义处：`PerfStats` 只在 `PerfSupport.cj` 内部出现，`.mean()` / `.raw()` 无调用；`PropertyGen.` 只有 `PropertyGen(seed:)` 构造调用，无 `PropertyGen.facts(` / `PropertyGen.rules(`；`.specificity` 的命中全部是 `Activation.specificity`。
- **描述**：`PerfStats` 的 `init` 本身是包内可见（`PerfSupport.cj:50`），外部拿不到实例，所以 `mean` / `raw` 实际上连"对外契约"都算不上；`PropertyGen.facts` / `rules` 是被 `randomFacts` / `randomRules` 取代后的旧生成入口（后者注释明确写了"与 [facts] 的区别是字段不保证齐全，用于差分测试"，说明 `facts` 已被有意弃用）。留着会让下一个使用者误以为有两套等价生成语义。
- **建议**：删除 `NaiveActivation.specificity`、`PerfStats.mean` / `raw`、`PropertyGen.facts` / `rules`；若要保留 `PropertyGen.facts` 供以后扩展，改成带注释的"未使用，保留作全字段生成"并把类收窄为 `internal`。此项需用户确认无下游测试依赖，不默认删。

### [轻微][存量] #10 "多会话"用例只开了一个前序会话：`while (round < 1)` 恒执行一次

- **位置**：`f_rule/src/test/PerfFixture_test.cj:55`
- **来源**：存量（工作区快照）
- **判据**：review-checklist §1（恒真控制流）/ §14（承诺的场景未覆盖）
- **证据**：静态确定 —— `round` 从 0 开始、循环体末尾 `round += 1`、条件 `round < 1`，只可能执行一次；用例名与注释是"同一网络连续开**多个**会话后，新会话的激活集合仍然完整"（`:48`）。
- **描述**：会话隔离是一类典型的"第 3、第 4 个会话才暴露"的回归（会话级 generation、静态缓存槽位替换），当前只验证了"1 个前序会话 + 1 个验证会话"。这段 `while` 也容易被误读成可配置轮数。
- **建议**：改成 `for (round in 0..3)`（或 `while (round < 3)`），并把轮数提成命名常量 `WARM_SESSIONS`；如果只想要 1 轮，改成 `if` 并把用例名改为"单个前序会话"。

### [轻微][存量] #11 I-06 用 `measure(0, 1)` 单样本无预热作为 B-02 门禁，与测量纪律相悖

- **位置**：`f_rule/src/test/Integration_test.cj:246`
- **来源**：存量（工作区快照）
- **判据**：review-checklist §6.1（测量口径）/ 项目基线 `fountain-baseline.md` §8（一次取值不构成结论）
- **证据**：静态确定 —— 调用是 `PerfSupport.measure(0, 1)`，而 `PerfSupport.measure` 的注释写明"warmup 不计入样本（覆盖 JIT/索引懒建/缓存预热）"（`PerfSupport.cj:124`-`:128`），`PerfStats.percentile` 在 n=1 时必然返回唯一样本（`PerfSupport.cj:89`-`:105`）。
- **描述**：该样本包含首次网络构建、首次 `FactBase` 建立与首次索引懒建，全部落在 2s 的 B-02 预算里；同时只有一个样本，`p95` 退化成单次取值，噪声无法通过中位数/离散度排除。与同门禁 `PerfInsert_test.b02` 的 `measure(1, 5)`（`:57`）口径不一致，两条路径对同一阈值给出不同可信度。是否为实际 flaky 需实测，但口径不一致是静态可见的。
- **建议**：改用 `measure(1, 3)` 或至少 `measure(1, 2)` 并保留 correctness 断言在前；若确实想要"冷启动"数字，另起一个用例命名冷启动，不与 B-02 阈值共用。

### [轻微][存量] #12 B-03 为拿 600 条新事实物化了 11000 条

- **位置**：`f_rule/src/test/PerfInsert_test.cj:110`
- **来源**：存量（工作区快照）
- **判据**：review-checklist §5（一次性物化，规模可静态量化）
- **证据**：静态确定 —— `PerfFixture.facts(factCount + 1000)` 生成 11000 个 `DynamicFact`，游标从 `factCount`（10000）开始，`100` 次预热 + `500` 次采样只读到下标 10000..10599，其余 10400 个对象在整个用例期间保持强引用。
- **描述**：不影响判定，但在同一个以 512MB RSS 为门禁的测试进程里制造了 94% 的无用对象；`PerfFixture.facts` 只支持"从 0 开始连续编号"，所以这里用"多造再偏移"的写法绕开。
- **建议**：给 `PerfFixture` 加 `factRange(from, count)`（或让 `facts(count, offset!)` 支持起始下标），B-03 只造 600 条。

## 优化可行性方案

> 不是缺陷，是「还能更好」；无基线的方案只作待验证假设，不进 tasks。

<!-- 第 1 部分 -->

### [堆内存] 会话与视图有界化，释放链打通

- **现状**：`RuleEngine.sessions_`（`RuleEngine.cj:35`）与 `FlowContext.contexts`（`FlowContext.cj:67`）都以 session id 为键；每条会话持有 `FactBase`（`facts_`/`buckets_`/`slots_`/`byIdentity_`）与 `SessionRuntime`（每空间 Alpha/BetaMemory、Token）。无容量、TTL、淘汰；只有显式 `release`/`close` 才移除，而 `FlowContext.release` 又不触及引擎会话（见发现 2）。
- **方案**：`RuleEngine` 增加 `maxSessions` + LRU/空闲 TTL（默认值可参考应用并发度），淘汰时调 `session.dispose()`；`FlowContext.release` 回调 `engine.release(session)`；`RuleTask` 结束时按 `Release` 策略释放。
- **预期**：稳态内存与"活跃会话数"成正比，而非"历史会话总数"；最坏峰值可估为 `maxSessions × 单会话 facts/tokens`。当前无基线，不能给出百分比。
- **代价**：淘汰后同 id 新会话看不到旧事实（语义变化）；LRU 需要锁，可能引入新竞争；需配置项与文档。
- **验证**：10 万唯一 session 循环压测，记录 `sessions_.size`、`getAllocatedHeapSize()`、RSS 与事实数；改前应线性增长，改后应有平台期。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 互斥组二级索引，替代全量扫描

- **现状**：`Agenda.invalidateGroup` 每次激活执行后遍历整个 `index_`（`agenda.cj:216-231`），复杂度 O(待执行激活数)；G 个互斥组各执行一次即 O(G·n)，最坏 O(n²)。决策表行共享同一组时只扫一次（可接受），用户规则"每组一条"时退化。
- **方案**：维护 `group → HashSet<Activation>` 二级索引，`add` / `remove` / `invalidateGroup` 同步维护，组内失效 O(k)。注意 `Loop` 回堆与 `remove` 的一致性。
- **预期**：多组场景的 `fire` 调度从 O(G·n) 降到 O(G·k)；具体收益需数据。
- **代价**：额外 O(n) 内存与一组不变量；实现复杂度上升；仍需保持 session 单线程语义。
- **验证**：`cjpm bench -O2` 或 `cjprof`，构造 1000 条各带独立 `activationGroup` 的规则，比较 `fire` 自耗时与 P95。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 激活指纹去字符串化

- **现状**：每次构造 `Activation` 都调 `Bindings.sortKey()`（`Bindings.cj:132-147`）：`names()` 遍历两个 map + 插入排序 + `out = out + ...` 拼接，生成 `"name=identity;"` 串存进 `key_`（`Activation.cj:52`）。每次插入事实产生激活都分配一条字符串，且 `sortKey` 的拼接是 O(k²)。
- **方案**：用结构化指纹（排序后的 `Array<(String, Int64)>`，预计算 hash）或把指纹缓存在 Token 上；判等/哈希直接比较结构，避免字符串分配与二次拼接。
- **预期**：降低插入/激活路径的分配量与 GC；占比需测（B-02 只有 1000 条激活，按现有数据不一定显著）。
- **代价**：需保持与 `NaiveActivation.sortKey()` 的差分一致性；`Activation` 作为 `HashMap` 键的 hash 必须稳定。
- **验证**：B-02/B-03 前后对照（同机、`-O2`、中位数与离散度）+ `cjprof` 分配采样。
- **证据状态**：`无基线（待验证，不进 tasks）`

<!-- 第 2 部分 -->

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

<!-- 第 3 部分 -->

### [CPU] `Activation.specificity` 在每次激活构造时重算，可预计算到 `Rule`

- **现状**：每个 `Activation` 构造都调 `Activation.specificityOf(rule)`（`Activation.cj:50`），遍历全部 `pattern` 再累加每个 pattern 的 `constraints.size`（`:56-62`）。`Rule` 在规则集构建后不可变，`specificity` 只依赖 `rule`，同一规则产出 N 个激活就重算 N 次；B-02（1000 规则 / 10000 事实 / 1000 激活）量级下是 1000 次重复遍历。
- **方案**：在 `Rule` 构建完成时算一次并作为 `let specificity: Int64` 字段（或 `RuleBuilder.build()` 里赋值），`Activation` 直接读 `rule.specificity`；`specificityOf` 保留为构建期的计算函数。
- **预期**：激活产出路径少一次 O(patterns × constraints) 遍历，收益随"每条规则的约束数 × 激活数"线性增长；具体占比无数据。
- **代价**：`Rule` 增加一个字段（+8B/规则，可忽略）；`Rule` 是 public 类型，需同步 README 的成员清单；`Activation.specificityOf` 若被外部调用（当前只有构造与 `NaiveActivation` 的等价实现）保持不变即可，语义不变。
- **验证**：`cjpm bench -O2`（同机、同输入）对照 B-02 的插入耗时中位数与 P95，并用 `cjprof` 看 `specificityOf` 的 self time 占比是否从非零降到 0。
- **证据状态**：`无基线（待验证，不进 tasks）`

<!-- 第 4 部分 -->

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

<!-- 第 5 部分 -->

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

<!-- 第 6 部分 -->

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

<!-- 第 7 部分 -->

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

<!-- 第 8 部分 -->

> 不是缺陷，是「还能更好」。本部分没有改前基线，以下两条均按「待验证假设」处理，不进 `todo.md` / `tasks.md`。

### [CPU] `alreadyEmitted` 走 `BetaProductions.contains` 的线性扫描，候选多时退化为 O(k²)

- **现状**：`BetaNode.alreadyEmitted`（`BetaNode.cj:336`-`:338`）对每个候选都调用 `BetaProductions.contains(parent, handle)`（`BetaProductions.cj:63`-`:79`），后者取 `byHandle_[handle]` 后**线性遍历**该句柄产出的全部子令牌，逐个比较 `child.parent == parent`。单个右侧事实在 k 个父令牌上都命中时，`byHandle_[handle]` 长度就是 k，每条候选判重是 O(k)，整轮 O(k²)；`Token ==` 又是沿父链递归比较（`Token.cj:141`-`:143`），每个比较还是 O(深度)。
- **方案**：给 `BetaProductions` 增一个 `HashSet<String>`（键 `"${parent.id}\u{0001}${handle}"`，`Token.id` 进程内单调唯一）做 O(1) 判重，`record`/`forget`/`takeBy*` 同步维护；原来的两个 `HashMap` 保留给撤销用。
- **预期**：k 较大（同一右侧事实命中多个左令牌）时，判重从 O(k) 降到 O(1)，整轮 O(k)；具体降幅取决于 k 的分布，未测。
- **代价**：多一份 `HashSet` 常驻（条目数 = 子令牌数），内存换 CPU；需要保证三条清理路径（`leftRetract`/`rightRetract`/`forget`）都同步删键。
- **验证**：构造「1 万左令牌 × 1 条右侧事实全命中」的场景，`cjprof record` 对比 `BetaProductions.contains` 自耗时与 GC 次数；`cjpm bench -O2` 同输入前后对照。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] `FromAlpha` 路径为每个候选临时构造 `Token.root`，配合 `probeByJoin`/`asList` 的三层复制抬高分配量

- **现状**：`BetaNode.candidatesOf` 的 `FromAlpha` 分支（`BetaNode.cj:257`-`:273`）对每个候选句柄 `Token.root(handle, leftBinding, leftFact)` 新建一个令牌，其中只有真正 emit 的才会被子令牌 retain，其余立刻成为垃圾；同一路径上 `AlphaNode.propagate` 还为每个 left consumer 各建一个 `Token.root`（`AlphaNode.cj:118`-`:120`）。范围 join 另有三层复制：`AlphaMemory.select` 建数组 → `BetaNode.asList` 复制进 `ArrayList`（`BetaNode.cj:240`-`:246`）→ 迭代；`BetaMemory.probeByJoin` 再把内部列表复制一次（`BetaMemory.cj:159`-`:165`）。单次激活的临时对象数 = O(候选数 + 左令牌数)，全部短命。
- **方案**：① 首模式的左令牌改为「按 (handle, binding) 惰性缓存/复用」，或直接把 `FromAlpha` 分支改成不建令牌、用 `(handle, fact)` 直接参与 `holds`（需要 `holdsWith` 增加一个「左事实直传」重载）；② 范围探测提供 `forEachCandidate(field, op, key, fn)` 回调式接口，让 `BetaNode` 在迭代里直接判 join，去掉 `asList` 与 `probeByJoin` 的复制（与第 7 部分对 `AlphaMemory.select` 的建议同向）；③ 若确认这些临时对象不逃逸，可评估 local mode（`--experimental --enable-local-mode`），但 `Token` 会逃逸进 `BetaMemory`，只能在 ② 的候选数组/回调闭包作用域上做局部化。
- **预期**：每次激活少 1–3 次 O(k) 复制与 k 个临时 `Token` 的分配（k = 候选数），峰值与 GC 压力下降；比例未测。
- **代价**：① 需要保证「同一 (handle, binding) 的令牌复用」不破坏 `Token ==` 去重与引用计数（复用后 retain 语义要重算）；② 回调接口让调用点略复杂，且调用方不能再持有候选集；③ local mode 是实验特性，工具链与 SDK 需锁版。
- **验证**：同规则集、同事实量（如 5 万事实、3 模式、join 命中率 10%）下对比 `getAllocatedHeapSize()`、`getUsedHeapSize()` 峰值、RSS 与 `cjpm bench -O2` 端到端耗时。
- **证据状态**：`无基线（待验证，不进 tasks）`

<!-- 第 9 部分 -->

### [堆内存] 未命中任何等值链头的事实在 `alphaHits_` 里也占一条空数组记录

- **现状**：`RootDispatch.propagate` 只要该类型存在任何等值索引，就对每条事实执行 `session.recordAlphaHits(handle, hits.toArray())`（`RootDispatch.cj:101`-`:103`），即使 `hits` 为空；`SessionNetwork.alphaHits_` 因此对**每条事实**持有一个 `HashMap` 条目 + 一个空 `Array<AlphaNode>`（`SessionNetwork.cj:37`、`:110`）。生命周期等于事实在网络中的存活期，量级为 O(事实数)。
- **方案**：把「空命中」表示为共享的静态空数组（`static let EMPTY_HITS = Array<AlphaNode>()`），或仅在 `hits` 非空时记录、`retract` 侧把 `None` 解释为「只回收未建索引的链头」——需要同步调整 `RootNode.retract`（`RootNode.cj:95`-`:113`）的 `None` 分支语义，避免退回全链头扫描。
- **预期**：每条不命中事实省一个 `Array` 对象头 + 元素区（约几十字节，视运行时对象头而定），以及一次 `toArray()` 分配；1e6 事实规模下为几十 MB 量级的峰值差（估算，需实测）。
- **代价**：`retract` 的 `None` 分支语义变复杂，必须补「不命中事实撤销后不得漏回收未索引链头」的用例。
- **验证**：同规则集、同事实量（10 万 / 100 万）跑 assert→retract 循环，对比 `getAllocatedHeapSize()` 与 RSS 稳态，并断言 `activations()` 结果不变。
- **证据状态**：无基线（待验证，不进 tasks）

### [CPU] `Token.hashCode()` 每次沿父链重算

- **现状**：`hashCode()` 递归取父令牌哈希再乘 31 加本节点哈希（`Token.cj:149`-`:157`），复杂度 O(模式数)。`Token` 被用作 `HashSet`/`HashMap` 键（`BetaMemory.cj:48`、`:50`、`BetaProductions.cj:31`），每次插入、探测、去重都会重算整条链。
- **方案**：`Token` 构造时一次算好 `hash_`（父令牌已持有自己的哈希，O(1) 递推），`hashCode()` 直接返回字段；`==` 仍按 `(parent, handle)` 递归但可在哈希不等时提前退出（现有实现由容器保证）。
- **预期**：把每次哈希从 O(k) 降到 O(1)，k = 规则模式数；k 越大收益越明显（k≤2 时可忽略）。
- **代价**：每个 `Token` 多一个 `Int64` 字段（8 字节），换取 CPU；需保证 `@OverflowWrapping` 语义不变。
- **验证**：`cjpm bench -O2` 对照「4 模式规则 + 5 万事实」的 assert/probe 吞吐；`cjprof` 看 `Token.hashCode` self time 是否消失。
- **证据状态**：无基线（待验证，不进 tasks）

### [CPU] `TerminalNode.evaluate` 每次求值复制一份绑定事实表

- **现状**：每条令牌进入终端时 `token.bindings()` 已构造两个 `HashMap`（`Token.cj:117`-`:126`），`evaluate` 又调用 `bindings.toFactMap()` 全量复制一份（`TerminalNode.cj:118`、`Bindings.cj:99`-`:101`），只为传给 `script.evalDetailed` 做只读查询。持有期为单次求值，量级 = 绑定数 × 每条激活。
- **方案**：给 `Bindings` 增加包内只读视图（`func factsRef(): HashMap<String, Fact>`，注释写明调用方不得修改），`evalDetailed` 使用该视图；或在 `JitExpression` 侧提供接受 `Bindings` 的重载，彻底去掉复制。
- **预期**：每条带脚本条件的激活少一次 `HashMap` 复制（k 个桶数组 + k 个节点），降低分配速率与 GC 压力。
- **代价**：暴露内部映射有被误改的风险，需要包内可见性约束 + 注释；跨包（`condition` 依赖 `agenda`？当前是 `Bindings` 在 `agenda`，`JitExpression` 在 `condition`）需确认依赖方向，可能要加一层只读接口而不是直接暴露。
- **验证**：`cjpm bench -O2` 对照「带 script 的规则、10 万次激活」，看分配量与 P99 延迟。
- **证据状态**：无基线（待验证，不进 tasks）

<!-- 第 10 部分 -->

### [堆内存] CSV 单元格解析去掉逐格临时数组与二次字节拷贝

- **现状**：`flushCell` 每格执行 `String.fromUtf8(cell.toArray())`：`toArray()` 产生一个 `Array<UInt8>`（按 `core_package_structs.md:1948-1958` 是拷贝），`fromUtf8` 内部再复制一份字节并做一遍 UTF-8 校验。10 万行 × 6 列 = 60 万次临时数组分配，生命周期只到下一次 `cell.clear()`
- **方案**：保留一个可复用的 `Array<UInt8>` 缓冲按需扩容，或改成「记录 (from,to) 偏移、最后一次切片」；UTF-8 合法性由 `parseFile` 的整文件 `isValidUtf8` 已保证，可改用 `fromUtf8Unchecked`（见 `core_package_structs.md:6411-6419`）省掉逐格校验
- **预期**：减少 60 万次短命数组分配与一次全量字节复制（约等于文件大小 S 的额外峰值）；GC 次数与峰值同步下降
- **代价**：`fromUtf8Unchecked` 是 `unsafe` API，安全性依赖「先整文件校验」这一前置条件；`parse(text: String)` 入口拿到的已经是合法 `String`，同样成立。需在代码里把该前置条件写成注释/断言
- **验证**：同一 10 MB/10 万行 CSV，多轮加载取 `getAllocatedHeapSize()` 增量与 RSS 峰值中位数，对照改前
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `HitAggregator` 用手写插入排序，`Priority` 只取最小值也全量排序

- **现状**：`f_rule/src/table/HitAggregator.cj:187-204` 的 `sorted` 是 O(n²) 插入排序，被 `RuleOrder`（:92-93）、`OutputOrder`（:94-96）、`Priority`（:100-103）使用；`Priority` 最终只取 `ordered[0]`，却先排完整个命中集。n = 命中行数，流式表可达 10 万行（`doc/07` §6.4）
- **方案**：① `Priority` 改为单趟取最小（O(n)）；② 需要全序时改用 `std.sort.sort(items, by: {l, r => compareOutputs(l, r, names)}, stable: true)`（`std/sort/sort_package_api/sort_package_funcs.md:463-475` 提供 `stable!` 参数，语义与现在的稳定插入排序一致）
- **预期**：`Priority` 由 O(n²) 降到 O(n)，`OutputOrder`/`RuleOrder` 由 O(n²) 降到 O(n log n)；n=10⁴ 时比较次数从 ~5×10⁷ 降到 ~1.3×10⁵ 量级（数量级估算，实际收益待测）
- **代价**：需引入 `std.sort`；`stable: true` 的常数比默认大，但只在 n 大时才有意义
- **验证**：`cjpm bench -O2` 用 1k/10k/100k 命中行分别跑 `OutputOrder` 与 `Priority`，对照改前中位数与离散程度；另用 10k 行做 `cjprof` 看 `sorted` 自耗时占比
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] CSV 的 UTF-8 校验做了两遍全量扫描

- **现状**：`f_rule/src/table/CsvTableParser.cj:189-194` 先 `isValidUtf8(bytes)` 全量扫一遍（`:347-393` 手写状态机），随后每格 `String.fromUtf8`（`:160`）内部再逐字节校验一遍；同一份 S 字节被校验两次，第二遍还拆成 60 万次小调用
- **方案**：整文件校验保留一次；单元格构造改用 `fromUtf8Unchecked`（前置条件由整文件校验保证），或直接依赖 `fromUtf8` 的 `IllegalArgumentException` 并把 `isValidUtf8` 降级为「仅在抛错时用于定位」
- **预期**：去掉一次 O(S) 扫描 + 每格一次 UTF-8 状态机；具体占比待测
- **代价**：`unsafe` API；错误码需要从 `IllegalArgumentException` 包装成 `TABLE_INVALID`（现在由 `isValidUtf8` 提前给出）
- **验证**：`cjpm bench -O2`，输入 10 MB 合法 CSV 与 1 处非法字节的 CSV 各跑 20 轮，对照耗时中位数；并确认非法字节仍抛 `TABLE_INVALID`
- **证据状态**：`无基线（待验证，不进 tasks）`

<!-- 第 11 部分 -->

> 本部分没有 `cjprof` / `cjpm bench` 基线，五条都只是"结构上可以更好"，均标 `无基线（待验证，不进 tasks）`。

### [堆内存] `execute()` 无条件构造 trace 对象（`trace = false` 时全量丢弃）

- **现状**：`f_rule/src/table/TableExecutor.cj:116-123` 每行都 `new ArrayList<ColumnTrace>` + `Array<ColumnTrace>` + N 个 `ColumnTrace` + 1 个 `RowTrace`；`:67-69` 在 `trace = false` 时直接丢弃。对象数 ≈ 行数 × (2 + 条件列数 + 1)。10 万行 × 4 条件 ≈ 70 万个短命对象/次调用。
- **方案**：`evaluate` 增加 `collectTrace: Bool` 入参（或让 `RowOutcome.trace` 为 `?RowTrace`），`trace = false` 时只算 `matched` 不建 `ColumnTrace`；`RowTrace.columns` 也可改为惰性（只存每个条件的 `Truth` 数组，需要时再包 `ColumnTrace`）。
- **预期**：`trace = false`（生产默认）时该路径分配降到接近 0；收益取决于行数 × 条件列数与调用频次（**未测**）。
- **代价**：`RowOutcome`/`evaluate` 的签名变化（内部类型，无对外影响）；`trace = true` 行为不变。
- **验证**：同一视图跑 1 万次 `execute`（10 万行表），对比 `getAllocatedHeapSize()` 增量、GC 次数与 P95 延迟。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] 每个 (行 × 事实) 都新建 `HashMap<String, Fact>` 装单绑定

- **现状**：`f_rule/src/table/TableExecutor.cj:128-129`（`evaluateConditions`）与 `:160-161`（`outputsOf`）各建一个 `HashMap<String,Fact>`，只放 1 个 entry。成本 = 行数 × 候选事实数 × 2 个 `HashMap`（外加桶数组）；无 `expr` 列、输出全是字面量时这些 map 完全无用。
- **方案**：编译期给每行算两个标记 `needsBindingsForExpr` / `needsBindingsForOutput`（`CompiledRow` 上加字段），只在需要时构造 map；更彻底的做法是给 `Constraint.eval` / `JitExpression.eval` 提供"单绑定"重载（`eval(fact)`），彻底去掉 map。
- **预期**：无 `expr` 列的表（`doc/07` 的主用法）在该路径上减少 2 个 map/行/事实；配合候选事实数 N，减少量 = 2 × R × N 个对象（**未测**）。
- **代价**：`CompiledRow` 多 2 个 `Bool`；需要给 `JitExpression` 加重载（跨包改动）。
- **验证**：`cjpm bench -O2` 跑 1 万行 × 100 事实，对比分配量与中位耗时。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] 聚合路径重复持有 `CompiledTable.rules`

- **现状**：`f_rule/src/table/TableCompiler.cj:175-184` 同时填 `rows`（`CompiledRow`，含 `rule`）与 `rules`（`Array<Rule>`，同一批 `Rule` 指针）；`TableExecutor` 只用 `rows`，`rules` 仅议程路径（`DecisionTable.compile`/`compileInto` 取 `.rules`）需要。100 万字节级：10 万行 × 8 B 指针 ≈ 0.8 MB（`Array` 本体），外加读者误用风险。
- **方案**：`CompiledTable.rules` 改为 `?Array<Rule>`（`agendaPath_` 为 true 时填），或让 `compile()` 返回 `Array<Rule>` 由调用方取，`CompiledTable` 不再存。
- **预期**：聚合路径少一个 10 万元素数组；议程路径不变（**未测**）。
- **代价**：`CompiledTable.rules` 由 `let Array<Rule>` 变 `?Array<Rule>`，`TableAssembly_test`/`TableCompiler_test` 取值处要改。
- **验证**：编译 10 万行表后 `getUsedHeapSize()` 差值与 `CompiledTable` 对象图规模。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 编译期把"列级校验"下沉到行循环外

- **现状**：`f_rule/src/table/TableCompiler.cj:239-245` 每行每列调 `fieldTypeOf`（一次 `HashMap.get` + 缺失即抛），`:413-422` 的 `validateOperator` 又对同一列**再取一次** `fieldType`；每行还要额外遍历列 3 遍：`compileOutputs`（`:332-358`）、`salienceOf`（`:378-400`）、`conditionKey`（`:441-456`，仅 Unique）。10 万行 × 6 列 ⇒ 约 300 万次 hash 查找 + 2 倍冗余。
- **方案**：编译前建一次 `Array<ColumnPlan>`（列种类、`FieldType`、是否已通过算子校验、输出槽名、是否 salience 列、列下标），行循环里只按下标取 `row.values[i]` 并解析值；`requireUniqueRows` 的 key 构造改 `StringBuilder`。
- **预期**：编译期列级 hash 查找从 O(行×列) 降到 O(列)（**未测**）；对 10 万行表的 `compile()` 总耗时影响需实测。
- **代价**：多一个内部类型 `ColumnPlan`；`compileRow` 结构重排（行为不变，靠现有 15 条编译用例回归）。
- **验证**：`cjpm bench -O2` 或用例内分段计时，对比 1 万 / 10 万行 `compile()` 中位耗时与 `cjprof` 里 `HashMap.get` 占比。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 命中排序改稳定 O(n log n) + `Priority` 单趟取最小

- **现状**：见发现 #5（`HitAggregator.cj:100-103`、`187-204`、`163-173`），插入排序 O(n²)，`Priority` 全排序后只取 `[0]`。
- **方案**：`RuleOrder`/`OutputOrder` 用"行序 index 作二级键"的通用排序（或先 `sort` 再按行序稳定化）；`Priority` 用 `minBy`（单趟，O(n)）；`orderedNames` 用 `sort()`。
- **预期**：排序比较次数从 O(n²) 降到 O(n log n)；10 万命中时理论降幅 3~4 个数量级（**未测**，实际取决于比较器成本）。
- **代价**：需保证"同键保持行序"语义不变（新增用例断言），`OutputOrder` 缺失输出键的排序位置（当前 `None` 排最后）必须保持。
- **验证**：`cjpm bench -O2` 构造 1 千 / 1 万 / 10 万条 hit 的 `aggregate` 基准，对比中位耗时；再用等价性用例覆盖重复值、缺失键、同 salience。
- **证据状态**：`无基线（待验证，不进 tasks）`

<!-- 第 12 部分 -->

### [堆内存] B-03 按需生成事实，去掉 10400 个无用 `DynamicFact`

- **现状**：`PerfInsert_test.b03` 一次性持有 11000 个 `DynamicFact`（每个含一个 5 项 `HashMap<String, Any>` + 一个 5 项 `ArrayList<String>` 字段序表，见 `src/fact/DynamicFact.cj:32`-`:36`），其中 10400 个从创建到用例结束都未被读取；生命周期覆盖整个 `measure` 调用（`PerfInsert_test.cj:110`-`:117`）。
- **方案**：`PerfFixture` 增加带起始下标的重载，B-03 只构造 `warmup + samples` 条；或在 `measure` 的 `body` 内用 `PerfFixture.fact(cursor)` 单条按需构造。
- **预期**：单用例常驻对象数从 11000 降到 600（数量级 -94%）；对进程 RSS 的影响量级约 1MB 以内，不改变 512MB 门禁结论。
- **代价**：`PerfFixture` 多一个重载；`fact(index)` 已是 public（`PerfSupport.cj:323`），单条构造路径现成，改动面很小。
- **验证**：`cjpm bench -O2` 前后对照该用例的 `getAllocatedHeapSize()` 与 RSS 中位数；断言 B-03 的 p95 不变（不引入测量偏差）。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 差分用例每个 group 重建整张网络

- **现状**：`Differential_test` 每组都执行 `ShardedNetwork(ruleSet)`（`Differential_test.cj:48`）+ `base.assert`，200 组共 200 次网络构建；构建成本随规则数线性、随共享签名变化，未测量。
- **方案**：若规则集签名（模式 + 约束 + join）相同，复用 `ShardedNetwork`；不同则按签名分组后批量跑同签名组，减少构建次数。
- **预期**：未知（构建占比未测）。
- **代价**：用例结构复杂化，需要额外的分组键；会削弱"每组独立网络"的隔离性。
- **验证**：`cjprof record` 跑 200 组，看 `ShardedNetwork.init`/`NetworkBuilder` 自耗时占比；`cjpm bench -O2` 前后对照用例总时长中位数。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `matcherSwitchFallsBackToNaive` 每次求值都重建 `RuleSet` 与 `NaiveMatcher`

- **现状**：注入的 naive lambda 里执行 `NaiveMatcher(ruleSetOf(ruleList))`（`Differential_test.cj:86`-`:88`）；`SessionRuntime.activations()` 在 Naive 模式下每次调用都重算（`src/rete/SessionRuntime.cj:155`-`:163`），该 lambda 每次都会重建规则集并重新编译脚本。
- **方案**：把 `NaiveMatcher` 提到 lambda 外（按 `ruleSet` 缓存），lambda 只做事实映射与 `Activation` 包装。
- **预期**：未知（当前 6 条事实 × 3 规则，绝对耗时很小）。
- **代价**：缓存需与 `ruleList` 身份绑定，防止跨规则集误用。
- **验证**：`measure(10, 100)` 包住 lambda 体，对比缓存前后 p50/p95。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

<!-- 第 1 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 会话表随历史 session 数线性增长，长跑最终 OOM | `src/engine/RuleEngine.cj:35` / `src/flow/FlowContext.cj:67` | 单会话平均 facts/tokens 与 RSS 曲线 | 10 万唯一 session 循环，采 `heapUsed`/RSS/`sessions_.size` |
| 2 | `invalidateGroup` 在"每组一条规则"时退化为 O(n²) | `src/agenda/agenda.cj:216` | `fire` 自耗时占比 | `cjprof record` + 1000 组规则 bench |
| 3 | 激活指纹字符串占 B-02 插入路径 >5% | `src/agenda/Bindings.cj:132` / `src/agenda/Activation.cj:52` | 分配量与自耗时 | `cjprof` 分配采样 + B-02 对照 |
| 4 | `In` 全扫在 In 密集规则中成为 join 瓶颈 | `src/rete/AlphaMemory.cj:166` | 覆盖率与实际耗时 | 500 条 In 约束规则 bench，对照 Eq |

<!-- 第 2 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `HitAggregator.sorted` 是 10 万行全命中表的 CPU 热点 | `src/table/HitAggregator.cj:170` | 自耗时占比、k 的实际分布 | `cjprof record` 跑 10 万行 `Collect` 表，统计 `sorted` self time |
| 2 | 流式装配的峰值内存由 `CompiledRow` 而非 XLSX 读取主导 | `src/table/TableCompiler.cj:170` | 编译前后 heapUsed / RSS 峰值 | 对 `pricing_large.xlsx` 跑 stream + `.table()`，分段记录 `getAllocatedHeapSize()` 与 RSS |
| 3 | `TableExecutor.collect` 的 `Array<Fact>` 在百万级事实下抬高单次执行峰值 | `src/table/TableExecutor.cj:96-108` | 事实数 × 单次 execute 的峰值增量 | 100 万事实下重复 `executeTable`，对比 scan 迭代实现的峰值 |
| 4 | `CellParser` / `TableCompiler` 的逐行字符串与临时数组适合 local mode | `src/table/CellParser.cj:38-140`、`TableCompiler.cj:170-260` | 临时对象分配量、逃逸情况、峰值内存 | 开 `--experimental --enable-local-mode` 做改前/改后峰值对照；当前无数据 |

<!-- 第 3 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 动作里高频 `ctx.fact("o")` 的双次哈希查找（`bindings.get` + `view_.get`）占动作自耗时可观比例 | `f_rule/src/agenda/ActionContext.cj:92-101` | 动作路径自耗时占比、每动作平均读取次数 | 构造"单规则 10 个动作、每动作读 5 个绑定"的会话跑 10k 次 `fire`，`cjprof record` 看 `ActionContext.fact` self time |
| 2 | `outputs()` 的全量复制在决策表批量输出场景产生可观测分配 | `f_rule/src/agenda/ActionContext.cj:129-135` | 每次 `fire` 的分配字节数、`outputs()` 调用次数 | 在 `TableExecutor` 路径埋计数 + `getAllocatedHeapSize()` 前后差，1000 行表跑 100 轮 |

<!-- 第 4 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `Agenda.compare` 的 `ConflictKey` 分配是议程的主要 GC 来源 | `f_rule/src/agenda/agenda.cj:356` | 分配量占比、GC 次数 | `cjprof heap` 跑 10 万次 add+fire（10k 激活），统计 `ConflictKey` 实例数与 GC 停顿 |
| 2 | `CycleDetector.record` 的 `remove(at:0)` 在窗口满后成为线性热点 | `f_rule/src/agenda/CycleDetector.cj:78` | 单次 record 耗时（窗口 10k） | 微基准：window=10000，record 10 万次，`-O2`，中位数；再对照环形缓冲实现 |
| 3 | 决策表同组互斥导致 `invalidateGroup` O(N²) 是实际瓶颈 | `f_rule/src/agenda/agenda.cj:216` | 组内行数分布、`fire` 总耗时占比 | 用 1 万行同组决策表跑 `cjpm bench -O2` + `cjprof` 分段 |
| 4 | 解释器每节点 `DateTime.now()` 占解释执行耗时的可观比例 | `f_rule/src/condition/Interpreter.cj:113` | 自耗时占比 | `cjprof record` 跑 10 万次 `evalOutcome`（50ms 超时），看 `DateTime.now` 与 `tick` 的 self time |
| 5 | 惰性堆不压实会让「高 churn 低 fire」会话内存线性上涨 | `f_rule/src/agenda/agenda.cj:125` | 真实会话的 assert/retract 与 fire 配比、单条保留字节 | 压测：10 万 assert+retract、不 fire，测 `getUsedHeapSize()` 与 RSS 曲线；再对照压实版 |

<!-- 第 5 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `In`/`Contains` 对集合右值的 `toArray()` + 线性扫描是匹配路径的主要分配/耗时来源 | `f_rule/src/condition/Truth.cj:267-284` | 单次判定自耗时占比、每次分配字节数 | `cjprof record` 跑 10 万事实 × `In` 100 元素集合；`cjprof heap` 看分配 |
| 2 | 决策表首次编译在全局锁内导致多表并发首次执行被串行化 | `f_rule/src/engine/RuleEngine.cj:106-114` | 编译单次耗时、锁等待时长、并发度 | 8 线程 × 20 张不同表，分段计时 + 线程状态（BLOCKED 占比） |
| 3 | `Pattern.eval` / `ConditionExpr` 的 `And`/`Or` 不短路，多约束模式下会做多余求值 | `f_rule/src/condition/Pattern.cj:88-94` | 约束数分布、每条约束平均耗时 | `cjpm bench -O2`，4 条约束的模式对比「全部求值」与「手工短路」版本 |
| 4 | `tableExecutors_` 长期增长对 RSS 的实际影响 | `f_rule/src/engine/RuleEngine.cj:36` | 单执行器占用、版本增长率 | 连续 1 万次不同 `version` 的 `executeTable`，观察 RSS / `getAllocatedHeapSize()` |
| 5 | `release` 后保留会话引用时事实不回收（前述「一般」条的内存侧影响） | `f_rule/src/engine/RuleSession.cj:210-217` | release 前后 heapUsed/RSS 对照 | 断言 10 万事实 → `release` → 保留 `session` 引用，`gc()` 后读 `getUsedHeapSize()`/RSS |

<!-- 第 6 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 事实插入主路径（`FactBase.assert` + `FactHandle`/`ValueKey` 构造）是会话插入的 CPU 热点 | `f_rule/src/fact/FactBase.cj:71`、`f_rule/src/fact/ValueKey.cj:96` | 自耗时占比、每秒插入量 | `cjprof record` 跑 `PerfInsert_test` 场景（10k 事实 × 3 类型），看 `assert` / `ValueKey.of` 的 self time |
| 2 | alpha 过滤对每条事实每个约束都新建 `ValueKey`，GC 压力显著 | `f_rule/src/fact/ValueKey.cj:96`、`rete/AlphaMemory.cj:343` | 分配速率、GC 次数 | 在 `ValueKey.of` 加计数器，跑 1M 事实 × 3 约束，统计对象数与 GC 时间 |
| 3 | `commitToParent` 的异常路径在重复提交时占比高 | `f_rule/src/fact/FactBaseView.cj:160` | 异常构造耗时 / 提交总耗时 | 10k 事实连续提交 10 次，`cjprof` 看 `RuleException` 构造与 `string interpolation` 占比 |
| 4 | `ValueKey.encode` 的长列表拼接成为签名构建热点 | `f_rule/src/fact/ValueKey.cj:306` | n 与耗时曲线 | `cjpm bench -O2`，列表长度 10 / 100 / 1000，看是否超线性 |
| 5 | `ValueKey.sortByValue` 的插入排序在较大 `Set` 上退化 | `f_rule/src/fact/ValueKey.cj:175` | n 与耗时 | 构造 100 / 1000 / 10000 元素 `ReadOnlySet` 做 `ValueKey.of`，计时 |
| 6 | `FlowContext` 的 `viewLock` 在归档场景成为会话串行点 | `f_rule/src/flow/FlowContext.cj:255` | 持锁时长、阻塞线程数 | 注册一个模拟 20ms I/O 的 `FactArchiver`，并发 8 个会话释放，采线程 BLOCKED 时长 |

<!-- 第 7 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 未完成 Join 状态的真实增速会导致 RSS 持续上涨 | `f_rule/src/flow/JoinTask.cj:136` | 每会话 state 字节数、失败会话占比 | 长跑压测（10 万请求，其中 10% 分支丢失），每 1 分钟采 `getAllocatedHeapSize()` 与 RSS，观察是否线性 |
| 2 | `AlphaMemory` 范围探测的复制是 join 热点的一部分 | `f_rule/src/rete/AlphaMemory.cj:166`-`:233` | `select`/`asList` 自耗时占比、单次分配量 | `cjprof record` 跑 1 万事实 × 1 万次范围 join，取 self time 与分配火焰图 |
| 3 | `Reachability.visit` 用 `remove(at: 0)` 做 BFS 队列，在大拓扑下 O(V²) | `f_rule/src/flow/Reachability.cj:77` | 构建期图规模与耗时 | 构造 1k/10k 节点 DAG，分段计时 `validate`；对照 `ArrayDeque`/索引游标实现 |
| 4 | 每条事件新建 `RuleEnvelope`/`TaskEvent`/`HashMap` 的分配量可观 | `f_rule/src/flow/RuleTask.cj:71`-`:90` | 每事件分配字节、GC 次数 | `cjprof heap` 稳态跑 10 分钟，读分配速率；再对比复用输出 map（注意语义：每次 fire 必须新 map） |

<!-- 第 8 部分 -->

> 没有性能测试数据支撑的猜测。**不进 `todo.md` / `tasks.md`**，只用于下一轮补数据。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `alreadyEmitted` 的线性判重在大扇出 join 下成为自耗时主要来源 | `f_rule/src/rete/BetaProductions.cj:63`-`:79` | `contains` 自耗时占比、每次调用的平均列表长度 | `cjprof record` 跑「1 万左令牌 × 1 条右侧事实全命中」，按函数取 self time；同时埋点统计 `byHandle_` 列表长度分布 |
| 2 | `FromAlpha` 路径的临时 `Token.root` 占插入阶段分配量可观比例 | `f_rule/src/rete/BetaNode.cj:266`-`:271` | 每事实分配字节数、临时 `Token` 占比 | `cjprof heap` 稳态插入 10 分钟，对比「临时令牌数 / 子令牌数」；再试缓存复用后的分配量 |
| 3 | 懒建索引的首次探测（全量扫描 `tokens_`/`order_`）在首插阶段形成尖刺 | `f_rule/src/rete/BetaMemory.cj:278`-`:298` | 首次探测耗时、触发次数、扫描规模 | 分段计时 `ensureEqIndex`/`ensureOrdIndex`，在 1k/1w/10w 令牌三档各跑一次首探测 |
| 4 | 共享节点的重复登记使传播耗时按「共享规则数」线性放大 | `f_rule/src/rete/NetworkBuilder.cj:171`-`:174` | 同一 alpha/beta 节点的 consumer 份数分布、传播耗时对比 | 用 `NetworkSharing_test.hundredRulesShareTwentyAlphaSignatures` 的规则集，对比「去重前/去重后」的 `assert` 总耗时（同 SDK、`-O2`、10 万事实） |

<!-- 第 9 部分 -->

> 没有性能测试数据支撑的猜测，只用于下一轮补数据；不进 `todo.md` / `tasks.md`。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `Token.hashCode` 的 O(模式数) 重算在多模式规则下占插入路径可观比例 | `f_rule/src/rete/Token.cj:149` | `Token.hashCode` 的 self time 占比、每事实平均哈希调用次数 | `cjprof record` 跑 4 模式规则 + 5 万/50 万事实的 assert，导出 self time；同时在 `BetaMemory` 加哈希调用计数埋点 |
| 2 | `RuleFailureGuard` 单一 `Mutex` 使多会话并发激活串行化 | `f_rule/src/rule/RuleFailureGuard.cj:34`、`rete/TerminalNode.cj:72` | 锁等待时长、线程 BLOCKED 比例、加锁频率 | 4 线程 × 各自 `RuleSession`、同一 `RuleSet`、10 万次激活；用线程状态采样（CPU profile 看不到锁等待）+ 在 `synchronized` 前后打时间戳统计等待分布 |
| 3 | `alphaHits_` 每条事实一个条目（含空命中）在百万级事实下抬高峰值内存 | `f_rule/src/rete/SessionNetwork.cj:37`、`rete/RootDispatch.cj:101` | 100 万事实下 `alphaHits_` 的条目数与字节量 | 固定规则集，注入 10 万/100 万事实，对比 `getAllocatedHeapSize()` 与 `getUsedHeapSize()` 稳态，并统计 `recordAlphaHits` 命中率为 0 的比例 |
| 4 | 首次并发 `shared()` 重复构建网络造成启动毛刺 | `f_rule/src/rete/ShardedNetwork.cj:86` | 并发首用时的构建次数与耗时 | 8 线程同时构造 `RuleEngine`（同一 `RuleSet`），统计 `ReteNetwork` generation 自增次数与各自耗时 |

<!-- 第 10 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | CSV 解析峰值内存约为文件大小的 2–4 倍 + 每格 ~40 B 对象开销，大文件会在启动期打穿容器内存 | `f_rule/src/table/CsvTableParser.cj:187-203` | 峰值 RSS / `getUsedHeapSize()` 与文件大小的比值 | 用 10 MB / 50 MB 两张同构 CSV 各加载 10 轮，记录进程峰值 RSS 与 `getAllocatedHeapSize()` |
| 2 | `HitAggregator.sorted` 在万级命中行时成为聚合路径热点（插入排序 O(n²)） | `f_rule/src/table/HitAggregator.cj:187-204` | 自耗时占比、n 与耗时的增长曲线 | `cjprof record` 跑 `TableExecutor` + `OutputOrder`，输入 1k/10k/100k 行；同时记录 n 翻倍时耗时倍数 |
| 3 | `ScriptAction` 共享同一个 `JitFunction` 被多线程并发 `call` 是否安全（`compiled_` 是规则集级单例，`JitFunction` 内部有 `active`/`lastEscaped` 等可变字段） | `f_rule/src/rule/ScriptAction.cj:66-69`、`f_jit/src/JitFunction.cj:59-115` | `JitFunction.call` 的线程安全契约 | 查 `f_jit` 的并发契约文档；若未声明，用两线程各 10 万次执行同一条 `thenScript` 规则，比对输出与异常率 |
| 4 | `ColumnKind.==` 用 `toString()` 字符串比较在编译期列遍历中占比可忽略（预计 <1%，仅登记） | `f_rule/src/table/Column.cj:38-44` | 单次比较耗时与调用次数 | 对 `TableCompiler` 编译一张 6 列 / 10 万行表做 `cjprof`，看 `ColumnKind.toString` 累计占比 |

<!-- 第 11 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `TableExecutor.execute` 的 O(行 × 候选事实) 求值是聚合路径的主要热点 | `f_rule/src/table/TableExecutor.cj:62-70`（行循环）→ `:94-107`（事实循环）→ `:126-147`（条件求值） | 自耗时占比、条件列数/事实数下的曲线 | `cjprof record` 跑 1 万行 × 1/100/1000 事实三档，看 `evaluate`/`evaluateConditions` self time 占比是否 >20% |
| 2 | 10 万行流式表编译后的常驻堆与"内存与行数无关"的偏差有多大 | `f_rule/src/table/TableCompiler.cj:175-184`、`TableExecutor.cj:43-44` | `CompiledRow`/`Rule` 单对象字节量、总堆增量 | 对 `src/fixtures/pricing_large.xlsx` 跑 `stream → compile`，前后取 `getUsedHeapSize()`/`getAllocatedHeapSize()`，并用 `cjprof heap` 看 `CompiledRow` 实例数与占比 |
| 3 | `CellParser.parseCondition` 的十余次 `startsWith` + `toAsciiLower` 在宽表编译中占比可观 | `f_rule/src/table/CellParser.cj:54-122` | 单次解析耗时、每表单元格数 | 分段计时：只解析条件单元格 vs 全量 `compile()`，`cjprof` 看 `CellParser.parseCondition` 占比；输入 10 万行 × 6 列 |
| 4 | `XlsxMergeMap.anchorOf` 线性扫描在合并区域多的表上放大成 O(单元格 × 合并数) | `f_rule/src/table/XlsxTableParser.cj:691-698`（每次 `readCells` 每格都遍历 `ranges`） | 合并区域数、单次 `parse()` 耗时 | 造 500 个合并区域的 1 万行表，`cjprof` 看 `anchorOf` 自耗时；对照无合并区域版本 |
| 5 | `HitAggregator` 插入排序在真实宽条件表上确实退化为秒级 | `f_rule/src/table/HitAggregator.cj:187-204` | n=1k/10k/100k 命中的单次 `aggregate` 耗时与增长曲线 | `cjpm bench -O2` 直接对 `aggregate` 造逆序/随机/已排序三组输入，测中位数与 P95；同时记录比较次数埋点 |

<!-- 第 12 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `Differential_test.expectEqual` 在成功路径上每次拼两份全量字符串比对（`joinKeys` 无截断），200 组下可能占用例可观 CPU | `Differential_test.cj:130`、`:170` | 该函数自耗时占比、字符串分配量 | `cjprof record` 跑 200 组差分，看 `String.operator+` / `joinKeys` 自耗时与分配次数 |
| 2 | `ReteNetwork_test.sameActivations` 的 O(n·m) 线性查找在大激活集合下可能成为用例瓶颈（当前用例规模 < 10 条） | `ReteNetwork_test.cj:189` | 用例内 n、调用次数、耗时 | 给该用例加分段计时，跑 100/1000 条事实两组对照 |
| 3 | `Differential_test` 每个 group 重建网络占用例总时长的主要部分 | `Differential_test.cj:48` | 构建耗时占比 | `cjprof record` 200 组，按 `ShardedNetwork.init` 汇总自耗时 |

## 文件覆盖

> 与 `files/f_rule.txt` 一一对应；分部分报告逐文件确认已读。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_rule/README.md` | .md | ✅ | — |
| 2 | `f_rule/README_en.md` | .md | ✅ | — |
| 3 | `f_rule/doc/01-architecture.md` | .md | ✅ | — |
| 4 | `f_rule/doc/02-fact-model.md` | .md | ✅ | — |
| 5 | `f_rule/doc/03-condition-expression.md` | .md | ✅ | — |
| 6 | `f_rule/doc/04-rete-network.md` | .md | ✅ | — |
| 7 | `f_rule/doc/05-agenda-conflict-resolution.md` | .md | ✅ | — |
| 8 | `f_rule/doc/06-flow-orchestration.md` | .md | ✅ | — |
| 9 | `f_rule/doc/07-decision-table.md` | .md | ✅ | — |
| 10 | `f_rule/doc/08-api.md` | .md | ✅ | — |
| 11 | `f_rule/doc/09-testing.md` | .md | ✅ | — |
| 12 | `f_rule/doc/10-roadmap.md` | .md | ✅ | — |
| 13 | `f_rule/doc/11-assembly.md` | .md | ✅ | — |
| 14 | `f_rule/doc/README.md` | .md | ✅ | — |
| 15 | `f_rule/doc/perf.md` | .md | ✅ | — |
| 16 | `f_rule/doc/spec/README.md` | .md | ✅ | — |
| 17 | `f_rule/doc/spec/archive/2026-11-01-implement-f-rule-m0-m7/design.md` | .md | ✅ | — |
| 18 | `f_rule/doc/spec/archive/2026-11-01-implement-f-rule-m0-m7/proposal.md` | .md | ✅ | — |
| 19 | `f_rule/doc/spec/archive/2026-11-01-implement-f-rule-m0-m7/specs/f-rule-agenda/spec.md` | .md | ✅ | — |
| 20 | `f_rule/doc/spec/archive/2026-11-01-implement-f-rule-m0-m7/specs/f-rule-condition/spec.md` | .md | ✅ | — |
| 21 | `f_rule/doc/spec/archive/2026-11-01-implement-f-rule-m0-m7/specs/f-rule-decision-table/spec.md` | .md | ✅ | — |
| 22 | `f_rule/doc/spec/archive/2026-11-01-implement-f-rule-m0-m7/specs/f-rule-engine-core/spec.md` | .md | ✅ | — |
| 23 | `f_rule/doc/spec/archive/2026-11-01-implement-f-rule-m0-m7/specs/f-rule-fact-model/spec.md` | .md | ✅ | — |
| 24 | `f_rule/doc/spec/archive/2026-11-01-implement-f-rule-m0-m7/specs/f-rule-flow/spec.md` | .md | ✅ | — |
| 25 | `f_rule/doc/spec/archive/2026-11-01-implement-f-rule-m0-m7/specs/f-rule-rete/spec.md` | .md | ✅ | — |
| 26 | `f_rule/doc/spec/archive/2026-11-01-implement-f-rule-m0-m7/tasks.md` | .md | ✅ | — |
| 27 | `f_rule/doc/spec/specs/f-rule-agenda/spec.md` | .md | ✅ | — |
| 28 | `f_rule/doc/spec/specs/f-rule-condition/spec.md` | .md | ✅ | — |
| 29 | `f_rule/doc/spec/specs/f-rule-decision-table/spec.md` | .md | ✅ | — |
| 30 | `f_rule/doc/spec/specs/f-rule-engine-core/spec.md` | .md | ✅ | — |
| 31 | `f_rule/doc/spec/specs/f-rule-fact-model/spec.md` | .md | ✅ | — |
| 32 | `f_rule/doc/spec/specs/f-rule-flow/spec.md` | .md | ✅ | — |
| 33 | `f_rule/doc/spec/specs/f-rule-rete/spec.md` | .md | ✅ | — |
| 34 | `f_rule/src/RuleInitializer.cj` | .cj | ✅ | — |
| 35 | `f_rule/src/RuleInitializer_test.cj` | .cj | ✅ | — |
| 36 | `f_rule/src/RuleSetBuilderCondition_test.cj` | .cj | ✅ | — |
| 37 | `f_rule/src/RuleSetBuilder_test.cj` | .cj | ✅ | — |
| 38 | `f_rule/src/RuleSetValidation_test.cj` | .cj | ✅ | — |
| 39 | `f_rule/src/agenda/ActionContext.cj` | .cj | ✅ | — |
| 40 | `f_rule/src/agenda/ActionContext_test.cj` | .cj | ✅ | — |
| 41 | `f_rule/src/agenda/Activation.cj` | .cj | ✅ | — |
| 42 | `f_rule/src/agenda/ActivationGroup_test.cj` | .cj | ✅ | — |
| 43 | `f_rule/src/agenda/ActivationSink.cj` | .cj | ✅ | — |
| 44 | `f_rule/src/agenda/Activation_test.cj` | .cj | ✅ | — |
| 45 | `f_rule/src/agenda/Agenda_test.cj` | .cj | ✅ | — |
| 46 | `f_rule/src/agenda/Bindings.cj` | .cj | ✅ | — |
| 47 | `f_rule/src/agenda/Bindings_test.cj` | .cj | ✅ | — |
| 48 | `f_rule/src/agenda/ClosureAction.cj` | .cj | ✅ | — |
| 49 | `f_rule/src/agenda/ConflictResolver.cj` | .cj | ✅ | — |
| 50 | `f_rule/src/agenda/ConflictResolver_test.cj` | .cj | ✅ | — |
| 51 | `f_rule/src/agenda/CycleDetection_test.cj` | .cj | ✅ | — |
| 52 | `f_rule/src/agenda/CycleDetector.cj` | .cj | ✅ | — |
| 53 | `f_rule/src/agenda/FireError_test.cj` | .cj | ✅ | — |
| 54 | `f_rule/src/agenda/FireMode_test.cj` | .cj | ✅ | — |
| 55 | `f_rule/src/agenda/TableAction.cj` | .cj | ✅ | — |
| 56 | `f_rule/src/agenda/agenda.cj` | .cj | ✅ | — |
| 57 | `f_rule/src/condition/ConditionExpr.cj` | .cj | ✅ | — |
| 58 | `f_rule/src/condition/ConditionExpr_test.cj` | .cj | ✅ | — |
| 59 | `f_rule/src/condition/Constraint.cj` | .cj | ✅ | — |
| 60 | `f_rule/src/condition/Constraint_test.cj` | .cj | ✅ | — |
| 61 | `f_rule/src/condition/EvalOutcome.cj` | .cj | ✅ | — |
| 62 | `f_rule/src/condition/Interpreter.cj` | .cj | ✅ | — |
| 63 | `f_rule/src/condition/InterpreterVsJit_test.cj` | .cj | ✅ | — |
| 64 | `f_rule/src/condition/JitExpression.cj` | .cj | ✅ | — |
| 65 | `f_rule/src/condition/JitExpressionMode_test.cj` | .cj | ✅ | — |
| 66 | `f_rule/src/condition/JitExpression_test.cj` | .cj | ✅ | — |
| 67 | `f_rule/src/condition/JoinConstraint.cj` | .cj | ✅ | — |
| 68 | `f_rule/src/condition/Operand.cj` | .cj | ✅ | — |
| 69 | `f_rule/src/condition/Operator.cj` | .cj | ✅ | — |
| 70 | `f_rule/src/condition/Operator_test.cj` | .cj | ✅ | — |
| 71 | `f_rule/src/condition/Pattern.cj` | .cj | ✅ | — |
| 72 | `f_rule/src/condition/Pattern_test.cj` | .cj | ✅ | — |
| 73 | `f_rule/src/condition/Truth.cj` | .cj | ✅ | — |
| 74 | `f_rule/src/condition/TruthTable_test.cj` | .cj | ✅ | — |
| 75 | `f_rule/src/condition/condition.cj` | .cj | ✅ | — |
| 76 | `f_rule/src/engine/EngineOptions.cj` | .cj | ✅ | — |
| 77 | `f_rule/src/engine/EngineTable_test.cj` | .cj | ✅ | — |
| 78 | `f_rule/src/engine/ExpressionFailure_test.cj` | .cj | ✅ | — |
| 79 | `f_rule/src/engine/RuleEngine.cj` | .cj | ✅ | — |
| 80 | `f_rule/src/engine/RuleEngine_test.cj` | .cj | ✅ | — |
| 81 | `f_rule/src/engine/RuleSession.cj` | .cj | ✅ | — |
| 82 | `f_rule/src/engine/RuleSession_test.cj` | .cj | ✅ | — |
| 83 | `f_rule/src/engine/ScriptAction_test.cj` | .cj | ✅ | — |
| 84 | `f_rule/src/engine/ScriptCondition_test.cj` | .cj | ✅ | — |
| 85 | `f_rule/src/exception/RuleErrorCode.cj` | .cj | ✅ | — |
| 86 | `f_rule/src/exception/RuleException.cj` | .cj | ✅ | — |
| 87 | `f_rule/src/exception/RuleException_test.cj` | .cj | ✅ | — |
| 88 | `f_rule/src/fact/DynamicFact.cj` | .cj | ✅ | — |
| 89 | `f_rule/src/fact/DynamicFact_test.cj` | .cj | ✅ | — |
| 90 | `f_rule/src/fact/FactBase.cj` | .cj | ✅ | — |
| 91 | `f_rule/src/fact/FactBaseView.cj` | .cj | ✅ | — |
| 92 | `f_rule/src/fact/FactBaseView_test.cj` | .cj | ✅ | — |
| 93 | `f_rule/src/fact/FactBase_test.cj` | .cj | ✅ | — |
| 94 | `f_rule/src/fact/FactSchema.cj` | .cj | ✅ | — |
| 95 | `f_rule/src/fact/FactSchema_test.cj` | .cj | ✅ | — |
| 96 | `f_rule/src/fact/FactSpace.cj` | .cj | ✅ | — |
| 97 | `f_rule/src/fact/FactSpaceRegistry.cj` | .cj | ✅ | — |
| 98 | `f_rule/src/fact/FactSpaceRegistry_test.cj` | .cj | ✅ | — |
| 99 | `f_rule/src/fact/FactSpace_test.cj` | .cj | ✅ | — |
| 100 | `f_rule/src/fact/TypedFact.cj` | .cj | ✅ | — |
| 101 | `f_rule/src/fact/TypedFact_test.cj` | .cj | ✅ | — |
| 102 | `f_rule/src/fact/ValueKey.cj` | .cj | ✅ | — |
| 103 | `f_rule/src/fact/ValueKey_test.cj` | .cj | ✅ | — |
| 104 | `f_rule/src/fact/fact.cj` | .cj | ✅ | — |
| 105 | `f_rule/src/flow/FlowContext.cj` | .cj | ✅ | — |
| 106 | `f_rule/src/flow/FlowContext_test.cj` | .cj | ✅ | — |
| 107 | `f_rule/src/flow/FlowSessionRegression_test.cj` | .cj | ✅ | — |
| 108 | `f_rule/src/flow/JoinTask.cj` | .cj | ✅ | — |
| 109 | `f_rule/src/flow/JoinTask_test.cj` | .cj | ✅ | — |
| 110 | `f_rule/src/flow/JoinTimeout_test.cj` | .cj | ✅ | — |
| 111 | `f_rule/src/flow/Reachability.cj` | .cj | ✅ | — |
| 112 | `f_rule/src/flow/Reachability_test.cj` | .cj | ✅ | — |
| 113 | `f_rule/src/flow/ResolveTask.cj` | .cj | ✅ | — |
| 114 | `f_rule/src/flow/ResolveTask_test.cj` | .cj | ✅ | — |
| 115 | `f_rule/src/flow/RuleEnvelope.cj` | .cj | ✅ | — |
| 116 | `f_rule/src/flow/RuleEnvelope_test.cj` | .cj | ✅ | — |
| 117 | `f_rule/src/flow/RuleFlow.cj` | .cj | ✅ | — |
| 118 | `f_rule/src/flow/RuleFlow_test.cj` | .cj | ✅ | — |
| 119 | `f_rule/src/flow/RuleSetFlow.cj` | .cj | ✅ | — |
| 120 | `f_rule/src/flow/RuleTask.cj` | .cj | ✅ | — |
| 121 | `f_rule/src/flow/RuleTask_test.cj` | .cj | ✅ | — |
| 122 | `f_rule/src/flow/SameSpaceFanout_test.cj` | .cj | ✅ | — |
| 123 | `f_rule/src/flow/VersionSwitch_test.cj` | .cj | ✅ | — |
| 124 | `f_rule/src/flow/flow.cj` | .cj | ✅ | — |
| 125 | `f_rule/src/rete/AlphaMemory.cj` | .cj | ✅ | — |
| 126 | `f_rule/src/rete/AlphaMemory_test.cj` | .cj | ✅ | — |
| 127 | `f_rule/src/rete/AlphaNode.cj` | .cj | ✅ | — |
| 128 | `f_rule/src/rete/AlphaNode_test.cj` | .cj | ✅ | — |
| 129 | `f_rule/src/rete/AlphaSignature.cj` | .cj | ✅ | — |
| 130 | `f_rule/src/rete/BetaMemory.cj` | .cj | ✅ | — |
| 131 | `f_rule/src/rete/BetaMemory_test.cj` | .cj | ✅ | — |
| 132 | `f_rule/src/rete/BetaNode.cj` | .cj | ✅ | — |
| 133 | `f_rule/src/rete/BetaNode_test.cj` | .cj | ✅ | — |
| 134 | `f_rule/src/rete/BetaProductions.cj` | .cj | ✅ | — |
| 135 | `f_rule/src/rete/IndexCoverage.cj` | .cj | ✅ | — |
| 136 | `f_rule/src/rete/IndexCoverage_test.cj` | .cj | ✅ | — |
| 137 | `f_rule/src/rete/JoinSignature.cj` | .cj | ✅ | — |
| 138 | `f_rule/src/rete/NetworkBuilder.cj` | .cj | ✅ | — |
| 139 | `f_rule/src/rete/NetworkSharing_test.cj` | .cj | ✅ | — |
| 140 | `f_rule/src/rete/RangeIndex_test.cj` | .cj | ✅ | — |
| 141 | `f_rule/src/rete/RangeKey.cj` | .cj | ✅ | — |
| 142 | `f_rule/src/rete/RecordingSink.cj` | .cj | ✅ | — |
| 143 | `f_rule/src/rete/ReteNetwork.cj` | .cj | ✅ | — |
| 144 | `f_rule/src/rete/ReteNode.cj` | .cj | ✅ | — |
| 145 | `f_rule/src/rete/RootDispatch.cj` | .cj | ✅ | — |
| 146 | `f_rule/src/rete/RootDispatch_test.cj` | .cj | ✅ | — |
| 147 | `f_rule/src/rete/RootNode.cj` | .cj | ✅ | — |
| 148 | `f_rule/src/rete/RuleFailureReporter.cj` | .cj | ✅ | — |
| 149 | `f_rule/src/rete/SessionNetwork.cj` | .cj | ✅ | — |
| 150 | `f_rule/src/rete/SessionRuntime.cj` | .cj | ✅ | — |
| 151 | `f_rule/src/rete/ShardedNetwork.cj` | .cj | ✅ | — |
| 152 | `f_rule/src/rete/SpaceSharding_test.cj` | .cj | ✅ | — |
| 153 | `f_rule/src/rete/TerminalNode.cj` | .cj | ✅ | — |
| 154 | `f_rule/src/rete/TerminalNode_test.cj` | .cj | ✅ | — |
| 155 | `f_rule/src/rete/Token.cj` | .cj | ✅ | — |
| 156 | `f_rule/src/rete/Token_test.cj` | .cj | ✅ | — |
| 157 | `f_rule/src/rete/rete.cj` | .cj | ✅ | — |
| 158 | `f_rule/src/rule.cj` | .cj | ✅ | — |
| 159 | `f_rule/src/rule/ActionContext.cj` | .cj | ✅ | — |
| 160 | `f_rule/src/rule/ClosureAction.cj` | .cj | ✅ | — |
| 161 | `f_rule/src/rule/ConditionExpander.cj` | .cj | ✅ | — |
| 162 | `f_rule/src/rule/ConflictResolver.cj` | .cj | ✅ | — |
| 163 | `f_rule/src/rule/RuleBuilder_test.cj` | .cj | ✅ | — |
| 164 | `f_rule/src/rule/RuleFailureGuard.cj` | .cj | ✅ | — |
| 165 | `f_rule/src/rule/RuleSet.cj` | .cj | ✅ | — |
| 166 | `f_rule/src/rule/RuleSetBuilder.cj` | .cj | ✅ | — |
| 167 | `f_rule/src/rule/ScriptAction.cj` | .cj | ✅ | — |
| 168 | `f_rule/src/rule/TableAction.cj` | .cj | ✅ | — |
| 169 | `f_rule/src/rule/TableSource.cj` | .cj | ✅ | — |
| 170 | `f_rule/src/rule/Validator.cj` | .cj | ✅ | — |
| 171 | `f_rule/src/rule/rule.cj` | .cj | ✅ | — |
| 172 | `f_rule/src/runtime/RuleRuntime.cj` | .cj | ✅ | — |
| 173 | `f_rule/src/runtime/RuleRuntime_test.cj` | .cj | ✅ | — |
| 174 | `f_rule/src/table/CellParser.cj` | .cj | ✅ | — |
| 175 | `f_rule/src/table/CellParser_test.cj` | .cj | ✅ | — |
| 176 | `f_rule/src/table/Column.cj` | .cj | ✅ | — |
| 177 | `f_rule/src/table/CsvTableParser.cj` | .cj | ✅ | — |
| 178 | `f_rule/src/table/CsvTableParser_test.cj` | .cj | ✅ | — |
| 179 | `f_rule/src/table/DecisionTable.cj` | .cj | ✅ | — |
| 180 | `f_rule/src/table/DecisionTableBuilder.cj` | .cj | ✅ | — |
| 181 | `f_rule/src/table/DecisionTableBuilder_test.cj` | .cj | ✅ | — |
| 182 | `f_rule/src/table/ExprColumn.cj` | .cj | ✅ | — |
| 183 | `f_rule/src/table/ExprColumn_test.cj` | .cj | ✅ | — |
| 184 | `f_rule/src/table/FixtureTable_test.cj` | .cj | ✅ | — |
| 185 | `f_rule/src/table/HitAggregator.cj` | .cj | ✅ | — |
| 186 | `f_rule/src/table/HitPolicy.cj` | .cj | ✅ | — |
| 187 | `f_rule/src/table/HitPolicy_test.cj` | .cj | ✅ | — |
| 188 | `f_rule/src/table/OutputCell.cj` | .cj | ✅ | — |
| 189 | `f_rule/src/table/OutputCell_test.cj` | .cj | ✅ | — |
| 190 | `f_rule/src/table/RowTrace.cj` | .cj | ✅ | — |
| 191 | `f_rule/src/table/TableAssembly_test.cj` | .cj | ✅ | — |
| 192 | `f_rule/src/table/TableCompiler.cj` | .cj | ✅ | — |
| 193 | `f_rule/src/table/TableCompilerAgenda_test.cj` | .cj | ✅ | — |
| 194 | `f_rule/src/table/TableCompiler_test.cj` | .cj | ✅ | — |
| 195 | `f_rule/src/table/TableExecutor.cj` | .cj | ✅ | — |
| 196 | `f_rule/src/table/TableExecutor_test.cj` | .cj | ✅ | — |
| 197 | `f_rule/src/table/TableMode.cj` | .cj | ✅ | — |
| 198 | `f_rule/src/table/TableMode_test.cj` | .cj | ✅ | — |
| 199 | `f_rule/src/table/TableResult.cj` | .cj | ✅ | — |
| 200 | `f_rule/src/table/TableRow.cj` | .cj | ✅ | — |
| 201 | `f_rule/src/table/TableSource_test.cj` | .cj | ✅ | — |
| 202 | `f_rule/src/table/TableTestSupport_test.cj` | .cj | ✅ | — |
| 203 | `f_rule/src/table/XlsxTableParser.cj` | .cj | ✅ | — |
| 204 | `f_rule/src/table/XlsxTableParser_test.cj` | .cj | ✅ | — |
| 205 | `f_rule/src/table/table.cj` | .cj | ✅ | — |
| 206 | `f_rule/src/test/Differential_test.cj` | .cj | ✅ | — |
| 207 | `f_rule/src/test/Integration_test.cj` | .cj | ✅ | — |
| 208 | `f_rule/src/test/NaiveMatcher.cj` | .cj | ✅ | — |
| 209 | `f_rule/src/test/NaiveMatcher_test.cj` | .cj | ✅ | — |
| 210 | `f_rule/src/test/PerfFixture_test.cj` | .cj | ✅ | — |
| 211 | `f_rule/src/test/PerfInsert_test.cj` | .cj | ✅ | — |
| 212 | `f_rule/src/test/PerfMemory_test.cj` | .cj | ✅ | — |
| 213 | `f_rule/src/test/PerfNetwork_test.cj` | .cj | ✅ | — |
| 214 | `f_rule/src/test/PerfSupport.cj` | .cj | ✅ | — |
| 215 | `f_rule/src/test/PerfTable_test.cj` | .cj | ✅ | — |
| 216 | `f_rule/src/test/PropertyGen.cj` | .cj | ✅ | — |
| 217 | `f_rule/src/test/ReteNetwork_test.cj` | .cj | ✅ | — |

合计：`.cj` 184 个 / `.md` 33 个 / 共 217 个，全部读完。

## 覆盖自检

### 第 1 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 9 | 文档契约违例 9 条（发现 1~9）；安全性未发现注入/凭据类问题（本部分无代码） |
| §1 死代码 | 1 | 本部分全是 `.md`，无声明可判；命中的是工程级死依赖：`cjpm.toml`/README 声明 `f_util` 但 `src` 零引用（发现 13）。对文档点名的符号做了全仓存在性核查，`TraceLevel`/`Rule.snapshot`/`Resolvers.default`/`Pattern.where` 属于"文档有、代码无"，按 §13/§14 计入发现，不列死代码 |
| §2 重复逻辑 | 0 | 文档层的错误码表、默认冲突链在 README 与 doc 间重复描述，已比对，无行为漂移；代码侧追证看到的三份 `Ordering` 比较辅助属范围外，已单列一句提示、不计数 |
| §3 空实现 | 1 | `RuleSet.close()` 注释承诺"清空网络与缓存"，函数体只置位（发现 3） |
| §4 栈溢出 | 0 | 条件树深度上限 32 由 `ConditionExpr.validate` 在构建期强制；`depth()/eval()` 本身递归但树由宿主代码构造、非外部输入，未构成无界递归；文档也无可递归遍历的示例 |
| §5 OOM | 1 | FlowContext/RuleEngine 双 store + 释放链断裂导致会话无界滞留（发现 2）；规模需实测，已列待验证假设 1 |
| §6.1 热点瓶颈 | 0 | 本部分没有新的 profile/bench 数据；README 自带 B-01~B-07 属既有基线，不据此新增热点结论 |
| §6.2 大粒度锁 | 0 | 相关代码是无锁而非锁过大；锁粒度问题不成立 |
| §6.3 并发串行 | 0 | 文档明确要求同 factSpace 分支必须串联（doc06 §2），未承诺可并行扇出 |
| §6.4 低效算法 | 1 | `In` 被计为可索引但实际全扫，覆盖率信号失真（发现 11）；`invalidateGroup` 的 O(n) 扫描仅有静态线索，已列待验证假设 2 |
| §7 降堆内存方案 | 1 | 会话/视图有界化（优化方案 1） |
| §8 降 CPU 方案 | 2 | 互斥组索引、激活指纹去字符串化（优化方案 2/3） |
| §9 local mode 可行性 | 0 | 无峰值内存前后数据；文档未涉及 local mode，不满足改造前提，按规则只能写"待验证假设"，本轮不列方案 |
| §11 现有代码的 BUG（存量） | 5 | 代码行为类 5 条（发现 1/2/3/10/11：并发无同步、双 store 释放链、close 空实现、事实强引用、In 全扫口径）；其余 8 条为文档契约类，已在 §13/§14 单列。快照模式，全部为存量 |
| §12 并发安全与锁粒度 | 1 | `sessions_`/`views_`/`FactBase` 无同步，且文档声明线程安全（发现 1） |
| §14 功能完备性与 README 覆盖 | 2 | `TraceLevel` 承诺未实现（发现 8）；README 公开 API 清单漏项/常量失真（发现 12）；`f_util` 死依赖归 §1（发现 13） |
| 文件覆盖（§13 等） | 7/7 | 无缺文件 |

### 第 2 部分

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

### 第 3 部分

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

### 第 4 部分

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

### 第 5 部分

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

### 第 6 部分

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

### 第 7 部分

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

### 第 8 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 5 | 正确性 2（发现 1、2）、设计 2（发现 3、4）、可读性 1（发现 8）；语言特性面核对了 `Option` 分支（`select`/`probe` 的 `case None => ()` 均有兜底语义）、`Hashable`/`Equatable` 自实现一致性（`AlphaSignature`/`JoinSignature`/`RangeKey` 的 `==` 与 `hashCode` 同源，无违例）、`@OverflowWrapping` 用法（`RangeKey.hashCode`）正确；安全性：本部分无外部输入解析、无 SQL/日志拼接、无凭据，未命中 |
| §1 死代码 | 2 | 逐符号机械过：本部分 `private` 全部有引用（`AlphaSignature.valueOf`/`buildKey`、`BetaMemory.joinProbe`/`inverse`/`orderedTail`/`orderedHeader`/`index*`/`valueAt`、`BetaNode.probeRight`/`candidatesOf`/`probeLeftAlpha`/`holds*`/`alreadyEmitted`/`factMapOf`/`emit`/`site`、`NetworkBuilder.*`、`RecordingSink.compactIfNeeded`、`RootDispatch.keyOf`、`ReteNetwork.nextNodeId`/`alphaNodeFor`/`betaNodeFor`/`newTerminal`/`setIndexCoverage`）；`internal`（`JoinProbe`、`BetaMemory.probeJoinList`/`selectList`/`tokensList`、`NetworkBuilder.sortedConstraints`、`RootDispatch` 及其成员、`ReteNetwork.nextNodeId`）在包内均有调用者；`protected` 本部分无声明。命中 2 条：`ReteNetwork.cj:99` 的 `let _ = registry`（发现 7）、`forgetAlphaHits` 残留（发现 10，按硬原则一只记信息）。对外可达的 `public` 但仓内零引用：`AlphaNode.ruleIds()`/`children()`/`leftConsumers()`/`rightConsumers()`、`BetaNode.ruleIds()`、`RootNode.typeTags()`（非本部分文件）——按硬原则一不判死代码，未计入 |
| §2 重复逻辑 | 3 | 同文件两两比对函数「输入→输出→副作用」：`RecordingSink.add/remove` 与 `BetaProductions.append/removeFrom` 语义不同（一个按 sortKey 覆盖、一个按实例删元素），不合并；`AlphaNode.propagate/retract` 是对偶而非重复。命中：`inverse` ×2、插入排序 ×3、`keyOf` ×4（发现 9），以及 `BetaMemory.orderedHeader` 与 `AlphaMemory.orderedHeader` 的镜像漂移（并入发现 1，不重复计数）。跨文件字面量检索（`"\u{0001}"` 分隔符、`"-"` 占位）只在各自签名内使用，无跨文件复制 |
| §3 空实现 | 1 | 命中：`AlphaSignature.valueOf` 的 `catch → None` 静默降级（并入发现 5）。其余空函数体只有 3 个测试会话的 `recordAlphaHits`/`forgetAlphaHits`（`AlphaNode_test.cj:70`-`:79`、`BetaNode_test.cj:75`-`:84`、`TerminalNode_test.cj`），都有注释说明「单节点用例不经过根分发」，属有意 Null Object，不判 |
| §4 栈溢出 | 1 | 命中：alpha 链（深度=约束数）与 beta 链（深度=模式数）的递归传播/撤销，构建期无上界校验（发现 6）。核对过 `RecordingSink`/`BetaProductions`/`Token` 的遍历均为 `while` 或单层 `for`，不递归；`Token.hashCode` 的父链递归见「范围外提示」 |
| §5 OOM | 0 | 逐个容器核对生命周期：`AlphaNode.children_`/`rightSinks_`/`leftSinks_`/`ruleIds_`、`BetaNode.consumers_`/`ruleIds_`、`ReteNetwork.alphaNodes_`/`byKey_`/`terminals_`、`RootDispatch.indexed` 全部**构建期**写入、`frozen_` 后不再增长，规模由规则集决定；`BetaMemory.tokens_`/`slots_`/`eqIndex_`/`ordIndex_`/`parts_` 与 `AlphaMemory` 侧同型，条目随事实/令牌增加但有对应 `remove` 对称清理（`parts_` 上界 = join 字段数）；`BetaProductions.byHandle_`/`byParent_` 由 `takeBy*`/`forget` 成对清理。未发现只增不减的容器，也没有按报文长度预分配 |
| §6.1 热点瓶颈 | 0 | 本部分无 profile / bench 数据（`scope.md` 的「已有性能资料」只给 `docs/LocalMode*.md`，与本部分无关联），按铁律不作发现，全部转入「待验证假设」4 条 |
| §6.2 大粒度锁 | 0 | 本部分运行期无锁：`Mutex` 只出现在构建期的 `NetworkBuilder.warnMtx`（仅 `warnCount` 自增）与 `ReteNetwork.genMtx`（仅 `generation` 自增），临界区内无 I/O、无解析、无回调；未命中 |
| §6.3 并发串行 | 0 | 本部分无 `spawn`/`Future`/线程池调用，传播是同步调用链，不存在「spawn 后立刻 get」或批大小为 1 的形态；未命中 |
| §6.4 低效算法 | 1 | 命中：`BetaProductions.contains` 线性扫描 + `Token ==` 递归比较（优化方案 1）。核对其他循环：`RootDispatch.propagate` 按字段数遍历（字段数=构建期常量）、`NetworkBuilder.warnCoverage` 的字符串 `+=` 只在构建期且条数=建议字段数（小）、`unindexEq`/`removeFrom` 的线性删除发生在索引桶（桶内元素=同值事实数），均属可接受量级，未计入 |
| §7 降堆内存方案 | 1 | 见优化方案 2（`FromAlpha` 临时令牌 + 三层复制），`无基线（待验证）` |
| §8 降 CPU 方案 | 1 | 见优化方案 1（判重 O(1)，本部分唯一 CPU 专项方案）；优化方案 2 的 ② 属同一条的附加收益，不另计。均 `无基线（待验证）` |
| §9 local mode 可行性 | 1 | 部分可行：`BetaNode.factMapOf` 的 `HashMap`、`probeRight`/`candidatesOf` 的临时 `ArrayList` 都是函数内创建、函数内消费，但 `Token` 会经 `emit` 逃逸进 `BetaMemory`，std API 也无对应 mode 重载，需先做优化方案 2 的 ② 才有局部化空间；无峰值内存前后数据，只能是「待验证假设」（已并入优化方案 2 的 ③） |
| §11 现有代码的 BUG（存量） | 6 | 本轮读到的 20 个文件全部核对边界/空值/错误处理/资源/契约：命中 2 条严重（发现 1、2）+ 4 条一般（发现 3、4、5、6）。另核对了：`AlphaNode.propagate` 异常吞并记失败后不写 memory（与 retract 的「没有则跳过」自洽）；`BetaMemory.remove` 的 `slot != last` 尾填补（含 `slot == last` 时不会越界）；`BetaNode.leftRetract/rightRetract` 的 `takeBy*` + `forget` 成对释放（`takeBy*` 已摘表，`forget` 再摘一次是 no-op，不产生泄漏）；`RecordingSink` 墓碑计数 `size = items - dead` 与 `compactIfNeeded` 阈值自洽；`IndexCoverage.coverage` 除零保护 |
| §12 并发安全与锁粒度 | 3 | 命中：`ReteNetwork.build` 检查-然后-写入（发现 4）、共享节点重复登记导致的重复传播（发现 3，并发面体现为同一 sink 被多入口调用）、`BetaMemory.sharedEmpty`（`BetaMemory.cj:42`-`:44`）作为静态可变 `ArrayList` 被 `selectList` 返回给调用方（当前 4 个调用点只读，与第 7 部分报过的 `AlphaMemory.sharedEmpty` 同根因，此处不重复计数，仅在发现 1 的建议里一并处理）。锁粒度面无问题：本部分运行期零锁 |
| §14 功能完备性与 README 覆盖 | 2 | 命中：`forgetAlphaHits` 声明了但撤销路径没接线（发现 10）；`JoinSignature` 共享键缺绑定名使「跨规则共享」这一能力在特定规则形态下失效（发现 2，属「承诺了共享但语义不成立」）。README/doc 覆盖不属本部分（0 个 `.md`），归 doc 子轮 |
| 文件覆盖（§13 等） | 20/20 | 无缺失；本部分不含 `.md`，`§13 文档一致性` 无从命中，只在「范围外提示」记录读取实现时撞见的两处 doc 滞后 |

### 第 9 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 8 | 正确性：#2、#6；设计：#1、#4；语言特性：#12；可读性：#8、#10、#11。安全性：本部分无外部输入解析、无 SQL/命令拼接、无凭据，未命中 |
| §1 死代码 | 3 | 机械过了一遍：`private` 全仓搜（`dispatchFor`/`classify`/`factsOf`/`nextId`/`leftRightEqual`/`keyOf` 均有调用者）；`internal` 包内搜（`TrackingSink`、`NaiveEntry`、`ConditionExpander`、`Conjunction`、`RuleFailureReporter` 均被引用，实现接口的成员按接口调用计）；`protected` 本部分 0 个；`public` 逐个判对外可达性——`SessionNetwork.betaMemoryCount`/`clearMemories`、`RootNode.heads`/`typeTags`、`ShardedNetwork.spaces`、`RuleSet.factSpaces`、`Token.refCount`/`isReleased`、`ClosureAction.asRuleAction` 仓内零引用，但所属顶层声明全是 `public`，按硬原则一不判死代码，只作信息记录。实际命中：未使用 import ×3（#9）、零引用测试辅助类（#10）、只写不读的引用计数（#7） |
| §2 重复逻辑 | 2 | 已把本部分 40+ 个函数体压成「输入→输出→副作用」两两比对；命中失败收敛三段式（#5）与同构样板（#8）。`DefaultConflictResolver` 的 `compareAsc` 三个重载只差类型，属刻意展开，未计 |
| §3 空实现 | 1 | `RuleSet.close()` 承诺清网络与缓存、实现只置位（计入 #3）；`TerminalTestSession.recordAlphaHits` 等测试替身的空体有注释、非契约，不计 |
| §4 栈溢出 | 1 | `ConditionExpander.dnf`/`dnfNot`/`cross` 递归深度 = 条件树嵌套深度（构建期、非外部报文），`Token.hashCode`/`==`/`release` 递归深度 = 模式数，均无上界但不可由运行期输入放大；合为一条轻微观察，未单列为发现（深度上界由规则定义常量级给出） |
| §5 OOM | 0 | 逐个容器核对：`heads_`/`dispatches_` 按类型数、`alphaHits_`/`BetaMemory` 按事实数且 `retract` 有回收、`failures_`/`disabled_` 按规则数、静态网络缓存只 1 槽；无按不可信长度预分配、无全量物化到内存的入口（本部分不解析外部报文） |
| §6.1 热点瓶颈 | 0 | 未提供本模块的 profile / bench 数据，热点结论不成立；已把 4 条候选写入「待验证假设」 |
| §6.2 大粒度锁 | 0 | 结构问题（一锁四用、纯读加锁）记在 §12.2 的 #4；「已成热点」缺线程状态数据，进假设 #2 |
| §6.3 并发串行 | 0 | 同一把 `RuleFailureGuard` 锁串行化全部会话激活，属结构性串行点，未测等待占比，进假设 #2 |
| §6.4 低效算法 | 1 | `Token.hashCode` O(模式数) 重算（记为优化方案 #2，属静态复杂度问题，不主张耗时占比）；`SessionRuntime.retract` 的 `remove(at: i)` 线性删除只在 Naive 测试后端，未计 |
| §7 降堆内存方案 | 1 | `alphaHits_` 空命中条目（优化 #1）；`clear()` 不还物理内存的语义已在方案里避免依赖 |
| §8 降 CPU 方案 | 2 | `Token.hashCode` 缓存、`evaluate` 去掉一次 `toFactMap` 复制（优化 #2、#3）；均标 `无基线（待验证）` |
| §9 local mode 可行性 | 0 | 本部分临时对象集中在 `bindings()`/`toFactMap()`/`naiveFactMap()`，但都是要逃逸到 `Activation` 的映射，`@ local!` 逃逸检查不通过；无函数内自产自销的大临时结构，收益无法用峰值内存证明 |
| §11 现有代码的 BUG（存量） | 6 | #2、#3、#5、#6、#7、#12；已逐个核对 20 个文件的边界（空集合、`Option` 取值、`HashMap` 取值、`retract` 未知句柄、`generation` 缺失分支），其余分支均有 `None`/空集合兜底 |
| §12 并发安全与锁粒度 | 3 | #1（数据竞争）、#4（锁粒度）、#13（惰性初始化重复构建）。已核对：`Token` 的可变字段只在本会话内读写（`SessionRuntime` 线程封闭，无跨会话共享路径），不计竞争；`RuleSet` 的 `var` 字段仅构建期写，除 `enableCycleDetection`/`configureExpressionTimeout`（`RuleEngine` 构造期调用）外无跨线程写路径 |
| §14 功能完备性与 README 覆盖 | 1 | `RuleSet.close()` 承诺未兑现（#3）；README 覆盖不在本部分（无 `.md`），留给含 README 的子轮 |
| 文件覆盖（§13 等） | 20/20 | 无缺失文件；本部分无 `.md`，故 §13 文档一致性无对象 |

### 第 10 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 6 | 正确性 2（引号未闭合、列表切分）；设计 1（编译失败不回滚模式位）；语言特性 1（`ColumnKind` 用 `toString` 实现 `==`）；可读性 2（两处注释与实现不符、`RuleRuntime` 双状态）；安全性 0（无 SQL/命令/路径拼接，CSV 与规则表来自运维文件而非请求体，未发现注入面） |
| §1 死代码 | 2 | `CsvScanner.start`（`:44` 写入后从不读取，全文件仅 `:55-56` 出现）；`CsvTableParser_test.sample`（`:39-41`，全文件零调用）。其余 private/internal 逐个搜过：`CsvRecord`/`CsvScanner` 成员、`CellParser` 的 11 个 private 静态函数、`Column.conditionColumn`、`DecisionTableBuilder.columnType`/`rowSource`/`header`、`Rule.withId`、`Validator.pairCompatible`、`ConditionExpander` 调用链均有引用。`public` 且对外可达的一律不判（`TableAction.asRuleAction`、`DecisionTable.columnsOf`、`RuleRuntime.resetForTest`/`lazyWarningCount` 仅测试或仓内零引用，按硬原则一不算死代码，只记信息）。`RuleSetBuilder.cj:142-148` 的 `case None` 目前不可达（`markInvalid` 只与 `lastError_` 同时发生），属防御性兜底，不计 |
| §2 重复逻辑 | 4 | `HitAggregator.prioritySorted`（:100-103）与 `OutputOrder` 分支（:94-96）函数体等价；`CellParser.number`（:175-188）与 `infer`（:266-274）的「含 `.`/`e`/`E` 判浮点 + try/catch」逐字重复；手写 `isValidUtf8`（`CsvTableParser.cj:347-393`）与 `String.fromUtf8` 的校验重复（同一份字节扫两遍）；`TableAction.asRuleAction`（:52-55）与 `ClosureAction.cj:34-37` 完全同形同注释。`CsvTableParser` 的 7 段 `match (metadata.get(...))` 形状相近但 setter 与解析各不相同，判为可读性而非重复；`DecisionTableBuilder.row` 家族是接口重载，不判 |
| §3 空实现 | 0 | 无空函数体、无 `TODO`/`FIXME`、无 `UnsupportedException`。5 处 `catch (_: Exception)`（`CellParser.cj:185`、`:252`、`:260`、`:272`，`CsvTableParser.cj:327`）都是「转成 `RuleException(TYPE_MISMATCH)`」「推断失败继续下一候选」或「解析失败改用兜底值」，均非静默吞错 |
| §4 栈溢出 | 0 | 唯一递归链是 `parseValue → list → requireList → parseValue`，第二层起 `fieldType` 固定降级为 `Any`（`CellParser.cj:171-173`），按代码推进最深 3 层、与输入括号嵌套无关；`HitAggregator`/`CsvScanner`/`Validator`/`ConditionExpander` 均为迭代实现。条件树展开另有 `maxExpansions = 64` 上限（`ConditionExpander.cj:32`） |
| §5 OOM | 1 | CSV 全量物化 + 每格两次拷贝且无大小上限（见发现）。其余无「按不可信长度预分配」「只增不减的全局容器」：`RuleRuntime.shared` 单实例、`DecisionTable.rows` 由表结构决定 |
| §6.1 热点瓶颈 | 0 | 本轮无 bench / `cjprof` 数据，不成立任何热点结论；候选（`HitAggregator.sorted`、CSV 解析、`ColumnKind.==`）全部进「待验证假设」 |
| §6.2 大粒度锁 | 0 | 临界区只有内存操作：`RuleRuntime.compiler()`（:54-70，锁内只构造 `Compiler` 与写两个标量）、`DecisionTable.mode`（:91-127，锁内只有 `match`+赋值），无 I/O、解析、回调 |
| §6.3 并发串行 | 0 | 本部分无 `spawn`、无 `Future.get`、无线程池 |
| §6.4 低效算法 | 1 | `HitAggregator.sorted` 为 O(n²) 插入排序且 `Priority` 只需最小值（见 CPU 方案）；无占比数据，故不进缺陷、只进方案与假设 |
| §7 降堆内存方案 | 1 | CSV 逐格临时数组与二次字节拷贝（`无基线（待验证）`）。`buildOrInvalid` 的重复装配已作为静态确定的轻微缺陷计入「发现」，不再重复列为方案 |
| §8 降 CPU 方案 | 2 | `HitAggregator` 排序；CSV UTF-8 双次全量扫描。均 `无基线（待验证）` |
| §9 local mode 可行性 | 0 | 候选是 `CsvScanner.flushCell` 的临时字节数组与 `CellParser.requireList` 的临时 `ArrayList`，但收益只能靠峰值内存对照证明；`String.fromUtf8` 无 local mode 重载（需 `exclave`/重建），且 `--enable-local-mode` 为实验特性、`cjLocalRegionMaxSize` 会引入新 OOM 面。结论：不可证明收益，不列为方案 |
| §11 现有代码的 BUG（存量） | 7 | 一般 2：「引号未闭合静默接受」「列表切分不识别引号」；轻微 5：「未知 `#` 元数据键静默忽略」「空行判定只覆盖单列」「`lastError_` 不清零」「两处注释与实现不符」「编译失败仍留 `Assembled`」。另逐条核对了 `DecisionTableBuilder.rowAt` 宽度校验、`HitAggregator` 五种策略的零/单/多命中分支、`Validator` 的 `getOrThrow` 前置条件（均先 `has`/`contains` 校验）、`CsvScanner` 行号推进（`\n` / `\r\n` / 引号内换行）与 `CsvTableParser.headerIndex` 越界（`record.cells.size == headerRecord.cells.size` 已保证），未再发现缺陷 |
| §12 并发安全与锁粒度 | 0 | 逐点核对：`RuleRuntime` 全局 `shared` 有 `Mutex`（无双重检查锁缺陷）；`DecisionTable.mode_` 有专用 `Mutex`，`markAssembled`/`markExecuted` 的检查-然后-写入在同一临界区；`HitAggregator`/`CellParser`/`CsvTableParser`/`Column` 无可变共享状态；`RuleSetBuilder` 为 builder，无线程安全承诺。流式表 `rowIterator()` 共享底层流属已声明限制（`DecisionTable.cj:162-167` 注释 + `doc/07` §6.4），按契约由调用方串行，不判缺陷。唯一未定项是 `ScriptAction` 共享 `JitFunction` 的并发调用，见假设 3（待确认） |
| §14 功能完备性与 README 覆盖 | 1 | `ColumnKind.Metadata` 承诺「说明/启用开关」但解析器只认 `id`/`name`（见发现，随 `doc/07` 一并在合并时去重）。抽查本部分 public API 与 `README.md:555-580` 的声明块：`TableAction`（README 未列，属内部动作实现）、`CellParser`/`Column`/`ExprColumn`/`HitAggregator` 未进声明块但 `doc/07` §4.1/§1/§4.3/§2 有对应章节，不判「公开 API 未文档化」；`CsvTableParser.parse/parseFile`、`DecisionTableBuilder` 的公开方法在 README 与 `doc/07` 均齐全 |
| 文件覆盖（§13 等） | 20/20 | 本部分 20 个 `.cj` 全部读完；本部分无 `.md`，§13 只做跨部分抽查（`doc/07-decision-table.md`、`README.md`），文档侧归属其他部分 |

### 第 11 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 6 | 正确性 #3（`Any` 语义）、#4（`${o}` 组合抛错）、#9（迭代器契约/异常类型）；设计 #1（资源所有权）、#2（流式承诺与编译物化）；可读性 #10（枚举样板）。语言特性：#4 涉及 `Any` 装箱后进入 `ValueKey` 的边界，其余 `Option`/`match` 用法正确（无静默丢弃：`OutputCell.resolve` 的 `None` 语义有文档、`collect` 的 `None` 分支是正常缺失）。安全性：本部分不拼 SQL/HTML/路径，无凭据、无外部输入进命令，XLSX/CSV 解析只做值转换；未命中 |
| §1 死代码 | 2 | 逐符号机械过：`private`（全仓搜）`RowOutcome`/`CsvRecord`/`CsvScanner`/`RenderedCell`/`XlsxStreamLayout`/`XlsxTableStream`/`XlsxRowSource`/`XlsxRowIterator`/`XlsxEmptyRowIterator`/`ColumnKindInference`/`XlsxMergeMap`/`TableCompiler.conflicts`/`agendaGroup`/`agendaSalience`/`salienceOf`/`fieldTypeOf`/`validateOperator`/`requireUniqueRows`/`conditionKey`/`warnAgendaDegradation`/`prioritySorted`/`orderedNames`/`sameOutputs`/`compareOutputs`/`compareValue` 均有调用者；`internal`（默认可见性的包内成员：`XlsxTableParser.streamTable`/`streamLayout`/`streamCellText`/`render`/`resolveTypeRow`/`typeOfToken`/`idIndex`/`ruleIdAt`/`readCells`/`applyMeta`/`parseSalience`/`putMeta`/`headerWidth`/`cellText`/`parseWorksheet`/`readTypeRow`/`readMeta`/`readStreamMeta`/`openDocument`，`CsvTableParser.parseBytes`/`applyMetadata`/`required`/`parseSalience`/`headerIndex`/`isValidUtf8`，`DecisionTableBuilder.columnType`/`rowSource`/`rowAt`，`DecisionTable.markAssembled`/`markExecuted`）在本包内均有引用。命中 2 条：#7（`CsvScanner.start` 只写不读）、#8（`let _ = condition`）。`protected` 本部分零声明。对外可达 `public` 一律不判；仓内零引用者仅作信息：`CompiledCondition.isEmpty`（`TableCompiler.cj:41-45`）、`DecisionTable.columnsOf`（`DecisionTable.cj:145-153`）、`DecisionTable.compile(ruleSet, compiler)` 两参重载（`DecisionTable.cj:232-235`）——三者都在 `public class` 上且顶层 `public`，属对外 API，只提示"仓内无使用"。无不可达语句、无恒真恒假分支；20 个文件 import 逐条核对均有使用 |
| §2 重复逻辑 | 5 | 同文件函数体两两比对（`TableExecutor` 5 个私有函数、`TableCompiler` 9 个、`HitAggregator` 6 个、`XlsxTableParser` 20 个、`CellParser` 9 个、`CsvTableParser` 7 个），跨文件按相同错误文案/字面量搜。命中：#10（三个 enum 的 `==`/`!=`）、#11（`_meta` 映射 ×2 + `salience` 解析 ×3）、#12（`prioritySorted` vs `OutputOrder` 分支 + 两份插入排序）、#13（`outputsOf` vs `actionFor`）、#14（数字推断 ×2 + 表头宽度 ×2）。已排除：`CellParser.parseValue` 的 7 个 `case`（按 `FieldType` 分派，非重复）；`TableCompiler.compileRow`/`compileOutputs`/`salienceOf`/`conditionKey` 的"遍历列"（各自取不同的列种类，属正交职责，仅建议下沉列计划见优化方案）；CSV/XLSX 两套扫描器（RFC 4180 与 OOXML 本质不同）；三份 `codeOf(...)` 测试辅助（各自捕获自家异常码，测试准备代码不判） |
| §3 空实现 | 0 | 全部分支逐条看：`XlsxEmptyRowIterator.next()` 返回 `None` 是有注释的 Null Object（`XlsxTableParser.cj:780-785`）；`collect`/`outputsOf`/`OutputCell.resolve`/`parseCondition` 的 `None` 分支都是"可选缺失"的正常语义（有文档说明）；`CsvTableParser`/`XlsxTableParser` 无 `TODO`/`FIXME`/`UnsupportedException`（全目录 grep 无命中）；无 `catch (_: Exception) {}` 空吞（`CellParser.parseIntOr`/`tryTime`/`TableCompiler.salienceOf` 的 `catch` 都转成了确定值或 `RuleException`） |
| §4 栈溢出 | 0 | 唯一的递归是 `XlsxTableParser.render`（`:586-595`）对 `Formula` 缓存值自调用，深度受 `CellValue` 模型嵌套限制（Excel 解析只产生一层 `Formula(inner)`），不可由表行数/列数放大；`TableCompiler`/`TableExecutor`/`HitAggregator`/两个解析器全部是显式循环，无树/图遍历、无 `equals`/`hashCode`/`toString` 自引用、无深拷贝 |
| §5 OOM | 1 | 命中 #2（编译/执行把每行物化为 `CompiledRow`，10 万行 40–80 MB 量级常驻；上界由表行数决定，无拒绝路径/上限配置）。已核对不算 OOM：`CsvTableParser.parseFile` 的 `File.readFrom` 与 `XlsxTableParser.parse` 的全表读取都以"文件大小"为上界（不是按报文头/DB 字段预分配）；`TableExecutor.collect` 的候选数组是单次调用的临时物化（O(事实数)，不跨调用累积）；`compileCount_` 是单个 `Int64`；无全局集合只增不减、无按请求 ID 建键的缓存 |
| §6.1 热点瓶颈 | 0 | 未提供 `cjprof`/`cjpm bench`/分段计时数据，5 条疑似热点全部进「待验证假设」；发现 #5 只声明"复杂度 O(n²)"这一可从代码静态判定的部分，不声称耗时占比或端到端收益 |
| §6.2 大粒度锁 | 0 | 仅有 2 处锁：`TableCompiler.countMtx`（只包一次 `Int64 +=`/读）、`DecisionTable.modeMutex_`（只包 `mode_` 读写，临界区 3 行）；无锁内 I/O、日志、解析、回调，且都不在请求主路径上 |
| §6.3 并发串行 | 0 | 本部分无 `spawn`/`Future`/线程池/队列，无"提交后立刻 `get`"、无单消费者串行段 |
| §6.4 低效算法 | 1 | 命中 #5（插入排序 O(n²)，`Priority` 全排序取最小）。另提示未计入缺陷的形态：`XlsxMergeMap.anchorOf` 每单元格线性遍历合并区域（`XlsxTableParser.cj:691-698`）、`conditionKey` 循环内 `String +=`（`TableCompiler.cj:441-456`，列数小，可忽略）、`XlsxRowIterator.rowOf` 对越界单元格再调 `streamCellText` 形成 O(单元格²)（仅畸形行触发）——三者都进「待验证假设」4 或不成立 |
| §7 降堆内存方案 | 3 | 优化方案 1（trace 对象按需构造）、2（单绑定 map 按需）、3（`CompiledTable.rules` 去重），全部 `无基线（待验证）` |
| §8 降 CPU 方案 | 2 | 优化方案 4（列级校验下沉 + 列计划）、5（稳定排序 + `Priority` 单趟），全部 `无基线（待验证）` |
| §9 local mode 可行性 | 0 | 无合格候选：`TableExecutor.evaluate` 的临时对象（`Array<Truth>`、`RowTrace`/`ColumnTrace`、`bindings`）要么**逃逸**进 `TableResult`/`RowOutcome`，要么是每 (行×事实) 的短命对象但 std 的 `HashMap`/`ArrayList` 无 local mode 重载，需 `@ local!` 重建且工具链（`cjfmt`/`cjlint`/LSP）不保证支持；且 `cjLocalRegionMaxSize` 是新的 OOM 面（10 万行 × 多列临时对象）。没有改前/改后峰值内存数据，按 §9 只能写"不可行（逃逸 + 无 mode 重载）" |
| §11 现有代码的 BUG（存量） | 14 | 14 条全部为存量（快照无 diff，`git status f_rule` 空；`git blame` 落在 `57e7cd67f6 2026-10-31`、`4e765c37c4 / 5702078ebc 2026-11-01`）。已逐个核对未列入缺陷的边界：`Column.parse` 的 `trimmed[5..]` 对 `"when."`（长度 5）得到空串并抛 `TABLE_INVALID`（正确）；`OutputCell.parse` 的 `raw[2..size-1]` 对 `"${"`+`"}"` 得空串 → 抛"引用为空"（正确，且下标全 ASCII 无 UTF-8 越界）；`CellParser` 的算子偏移量（`in`=2、`not in`=6、`between`=7、`contains `=9、`startswith `=11、`endswith `=9、`matches `=8）逐个与字面量长度一致；`tryTime` 的 `day<=31` 由 `DateTime.of` 兜底（非法日期被 catch 成 `None`）；`CsvTableParser.isValidUtf8` 的过长的编码/代理区/上界检查（`E0/ED/F0/F4`）完整，且 `i+extra>=size` 先判；`CsvScanner` 的 `\r\n` 与引号内换行行号维护一致；`DecisionTable.columnTypeAt` 越界返回 `None`；`TableExecutor.evaluate` 中 `results` 与 `conditions` 长度恒等（三处来源都按条件数填充） |
| §12 并发安全与锁粒度 | 0 | 逐个共享点取证：① `TableExecutor` 被 `RuleEngine` 按 `id@version` 缓存后跨会话共享（`engine/RuleEngine.cj:106-115`），但 `table_`/`compiled_` 都是 `let` 且 `CompiledTable` 构造后只读，`execute` 全部状态是局部变量 ⇒ 可并发调用（`JitExpression.eval` 只读，`condition/JitExpression.cj:230-241`）；② `DecisionTable.mode_` 的读（`prop mode`）与写（`markAssembled`/`markExecuted`）都在 `modeMutex_` 内，检查-然后-写入在同一临界区（无 TOCTOU）；③ `TableCompiler.compileCount_` 的 `+=` 与读都在 `countMtx` 内；④ 唯一未声明线程约束的是 `DecisionTable.rowIterator()` 在流式表上会与共享的 `ExcelSheetStream` 交互（`ExcelSheetStream.cj:310` 写 `lastSheet`），但类文档已写"不要同时持有两个迭代器"（`DecisionTable.cj:165-166`），且现有唯一调用方 `TableCompiler.compile` 由 `RuleEngine` 的 `executorsMtx_` 串行化 ⇒ 当前无并发路径踩到，仅作为公共 API 的隐含约束记在此处。锁粒度：#6.2 的 3 处临界区都在微秒级、无嵌套锁、无锁顺序问题 |
| §14 功能完备性与 README 覆盖 | 0 | 本部分不含 `README.md`/`README_en.md`/`doc/**`，README 覆盖无法在本部分判定（模块 README 属其他部分）。就"承诺源—实现"对照做了三处抽查（承诺源都在本部分文件内）：`table.cj:18-24` 声称的两个载体与 `stream` 入口均存在；`OutputCell.cj:40-41` 声称的 `${binding}` 已实现（但组合语义见 #4）；`DecisionTable.cj:162-167` 声称的 `rowIterator` 两种来源均实现。`f_rule/src/rule.cj:33-34` 的门面重导出已含 `CsvTableParser`/`XlsxTableParser`/`Column`/`ColumnKind`/`HitPolicy`/`RowTrace`/`TableMode`/`TableResult`/`TableRow`/`DecisionTable(Builder)`（`TableExecutor`/`OutputCell`/`HitAggregator` 未进门面，但 `f_rule.table` 是公开子包，可取到，不判缺失） |
| 文件覆盖（§13 等） | 20/20 | 无缺文件；本部分 0 个 `.md`，§13 无对象。跨文件一致性按要求用 `doc/07-decision-table.md`（§2/§4.2/§6/§9）与 `f_excel/src/ExcelSheetStream.cj`、`f_rule/src/fact/ValueKey.cj` 做了判据核对，不计入本部分覆盖 |

**范围外提示**（不计入统计）：`engine/RuleEngine.cj:105` 以 `"${table.id}@${table.version}"` 作为执行器缓存键，两个同名同版本但内容不同的 `DecisionTable` 会复用同一个 `TableExecutor`（文档 `doc/07`/`doc/11` 已要求"表变更需换版本号或新建引擎"，此处仅提示该约束没有运行期校验）。

### 第 12 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 6 | 正确性：断言恒真（#2）、多重集比较（#4）、负种子（#5）；设计：影子实现（#6）；可读性：`while (round < 1)`（#10）；安全性：本部分无外部输入、无凭据与注入面，无命中 |
| §1 死代码 | 0（另 1 条可见性建议） | 逐个 `private`/`internal` 符号搜引用：`MatchWalker`、`PreparedSession`、`PerfSupport.sorted`、`PropertyGen.randomJoinOp/addConstraint`、各 `private func` 均有调用者；`import` 逐个核对无未用；`return`/`break` 后无同层语句。唯一异常是 #9 的 4 个对外可达 `public` 成员零引用，按硬原则一只提可见性建议，不判死代码 |
| §2 重复逻辑 | 3 | 已把 12 个文件的全部函数体压成"输入→输出→副作用"摘要两两比对，并按 `sort` / `sortKey` / `specificity` / 错误文案跨文件搜索：命中 #6（排序键格式）、#7（插入排序 4 份）、#8（specificity 公式）；`activationKeys`/`naiveKeys`/`joinKeys` 三份复制已并入 #1 与 #4 说明 |
| §3 空实现 | 0 | 无空函数体、无 `TODO`/`FIXME`、无 `catch` 吞异常；`PerfSupport.init()`、`PerfFixture.init()` 是为禁止实例化而留的私有空构造，有注释说明意图，不算空实现 |
| §4 栈溢出 | 0 | 唯一递归是 `MatchWalker.walk`（`NaiveMatcher.cj:177`），深度 = `rule.patterns.size`，由规则定义决定、无环、无自引用结构；用例生成器上限 5 个模式。按 5 层估算无风险 |
| §5 OOM | 1 | `NaiveMatcher` 组合数上界 = Π(每模式候选数)，但用例输入被生成器限死（≤6 事实 × ≤5 模式，最大 6^5）；命中 #12 的无用物化 |
| §6.1 热点瓶颈 | 0 | 本部分无 profile / bench 数据，`PerfGate` 只是阈值不是基线；3 条结构性热点线索已全部降级进「待验证假设」 |
| §6.2 大粒度锁 | 0 | 本部分不持锁；`PerfSupport`/`PerfStats` 无同步原语 |
| §6.3 并发串行 | 0 | 无 `spawn`、无 `Future.get`、无任务提交；用例内全部同步串行 |
| §6.4 低效算法 | 0 | 观察到 3 处 O(n²)（插入排序、`sameActivations` 线性查找、`joinKeys` 拼接），因规模小且无耗时数据，分别并入 #7、#4 与「待验证假设」#1/#2 |
| §7 降堆内存方案 | 1 | 提出 B-03 物化方案，`无基线（待验证）`；其余对象生命周期均限于单个用例 |
| §8 降 CPU 方案 | 2 | 网络重建、naive lambda 重建两条，均为 `无基线（待验证）` |
| §9 local mode 可行性 | 0 | 测试包内无大对象峰值问题（单用例峰值由 `PerfFixture` 固定规模决定），无逃逸分析与峰值内存数据，收益无法证明；不提出改造 |
| §11 现有代码的 BUG（存量） | 5 | 本源存量为 #1、#2、#3、#4、#5；另核对 `NaiveMatcher.filter`（类型 + 约束双重过滤）、`MatchWalker.emit`（join 与脚本短路顺序）、`PerfStats.percentile`（最近秩与越界夹紧）、`PerfFixture.expectedActivations`（1000 规则 × 10000 事实解析解）四处边界，未发现缺陷 |
| §12 并发安全与锁粒度 | 0 | 12 个文件均为单线程用例：`private var` 游标只在同一用例内读写；`unittest --parallel` 按测试类分进程（`std 文档/unittest/unittest_samples/unittest_basics.md:465`）且禁止与 `--bench` 同用（同文件 `:468`），不构成共享写。模块级静态状态（`Activation.seqCounter`、`ShardedNetwork` 单槽缓存）已在 #3 作为口径问题记录 |
| §14 功能完备性与 README 覆盖 | 0 | 本部分无 `.md`、无 public 契约新增；`doc/09-testing.md` 引用的 B-01~B-07、I-01~I-06、R/F 用例编号在 `src/test` 内均有对应用例，未发现承诺缺实现 |
| 文件覆盖（§13 等） | 12/12 | 12 个 `.cj` 全部读完；本部分清单不含 `.md`，§13 无对象 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 16 |
| 一般 | 71 |
| 轻微 | 81 |
| 其中存量 | 139 |
| 优化方案 | 见「优化可行性方案」各条 |

## 总评

**第 1 部分**：文档整体质量在同类模块里偏高：README 与 `README_en` 结构完全同步，错误码（27 个）、性能门禁 B-01~B-07、包结构、API 速查都有覆盖，`doc/04` 还主动标注了 `In` 未展开的已知边界。主要风险不是"写得少"，而是**文档领先于实现**：

1. **阻塞项（2 条严重）**：`doc/01`/`doc/08` 宣称 `RuleEngine`/`FactBase` 线程安全，但实现完全没有同步（发现 1）；`FlowContext` 与 `RuleSession` 各建一套 `FactBaseViewStore`，文档承诺的同一视图不成立，且文档指定的释放路径释放不掉引擎会话，按每请求一个 session 使用会无界增长（发现 2）。这两条要么补同步/统一 store，要么改写文档承认"会话线程封闭 + 显式 engine.release"，不能保留现状。
2. **可排期（7 条一般）**：`RuleSet.close()` 空实现与静态网络缓存（发现 3）；`doc/04` 的 Rete API（发现 4）、`doc/03` 的条件 API（发现 5）、`doc/05` 的议程 API（发现 9）仍在描述旧设计/旧签名，示例无法编译；`doc/02` §7 的动态事实 JIT 示例与强制解释器策略矛盾（发现 6）；`doc/01` 的包结构与依赖方向错误（发现 7）；`TraceLevel` 追踪能力只有文字（发现 8）。
3. **文档卫生（4 条轻微）**：网络持有事实对象的描述、`In` 可索引口径、README 自动生成清单、`f_util` 死依赖。

规则求值正确性本身在本部分只能做"文档承诺 vs 实现"层面的核对：三值逻辑、DNF 展开上限、HitPolicy 降级、循环检测阈值都与实现基本一致（仅阈值文案差一次）；更细的求值路径（alpha/beta 探测、脚本降级、决策表编译）留给第 2~12 部分的 `.cj` 审查。性能结论均无本轮测试数据，只以「待验证假设」形式保留，未写成结论。

**第 2 部分**：`f_rule` 的文档体系完整，规格、设计、API、测试、性能门禁分层清楚，归档 spec 与多数实现细节（27 个错误码、深度上限 32、HitPolicy 两路径语义、RangeKey 索引）都能对上。主要风险不在文字质量，而在**文档承诺与当前实现的漂移集中在最关键的三处**：`FlowContext` 事实视图与规则网络脱节、`RuleEngine`/`FactBase` 的线程安全声明无同步支撑、`FlowContext` 生命周期无人释放。这三项会分别造成「规则静默不触发」「并发下会话/事实损坏」「长跑内存单调增长」，属于阻塞级存量问题；`JoinTask` 的完成/超时竞态是第四个需要优先修的并发缺陷。其余问题以文档修正为主：`doc/06` 的 API 片段与错误路径、`doc/07` 的决策表 builder 名称与 `factType/outputOrder`、`doc/08` 的 close 释放描述、`doc/09` 的测试布局，应在本轮文档回填中一次性对齐。性能类只给了无基线的优化方向，未写成结论，待补 `cjprof`/RSS 数据后再决定是否排期。

**第 3 部分**：本部分代码的整体质量良好：`Activation` 的身份/排序契约（`(factSpace, ruleId, bindings)` 判等、`seq` 原子分发、`specificity` 定义）与 `f-rule-agenda` spec、`Agenda` 的冲突消解链、差分基准三方对得上；`SessionActionContext` 的分层（接口在 `rule`、实现在 `agenda`）解决了包循环，不是绕过去的权宜之计；死代码与空实现基本为零（唯一的 `NoopPropagation` 是有注释的 Null Object），4 个源文件里没有递归、没有无界容器、没有锁。

真正的风险集中在动作路径的一致性：`assert`/`retract`/`update` 把"改事实库"和"推 Rete 网络"拆成两次不可回滚的副作用（#1），而 `fact(binding)` 在事实已被撤销时又回退到激活时快照（#2）——这两条叠加，可以让一个动作读到已撤销的事实、或让一条事实永远进不了网络，且都不会有任何日志。它们不是阻塞级（需要传播抛错或"先撤销后读取"的动作写法才触发），但一旦触发就是静默的结果错误，建议排期修掉并补用例。规格层面（#3、#9、#10、#11）的问题是另一种味道：`doc/spec/specs/**` 已经部分退化为"事后描述"，同一条要求里出现自相矛盾的表述，用户可见的展开行为（同类型 `Or`、64 条上限）和配置面（循环检测阈值）没有进契约——这类问题不影响运行，但会让下一轮审查和下游使用者反复踩坑，建议随下一次文档对齐一并处理。

其余（#4~#8、#12、#13）都是低风险项：一个构造 ID 才能触发的键碰撞、几处静默无操作、两处测试断言/注释与实现不符、两处模块内小重复，可以批量清理。本部分无严重项，也没有可量化的性能结论；唯一的 CPU 优化（`specificity` 预计算）必须补基线后才能进任务清单。

**第 4 部分**：本部分（agenda 的绑定表 / 冲突消解 / 循环检测 / 议程执行，condition 的条件树 / 约束 / 解释器 / JIT 表达式）整体结构清晰：议程用惰性二叉堆 + 有效性索引，冲突消解用可组合的全序解析器，条件求值把三值逻辑集中在 `Truth`，异常收敛到 `EvalOutcome` 并有失败计数与自动禁用，这些设计是对的，注释与判据（doc/05、doc/03 的节号）也对得上。

阻塞项有两条，都在 condition 包：

1. `InterpreterProgram` 把 `steps`/`deadline` 放在实例字段上，而该实例通过 `ShardedNetwork.shared` 的共享结构被多会话共享 —— 默认 50ms 超时下每个节点都在读写这两个字段，并发求值会互相重置步数和截止时间，既是数据竞争，也让步数上限失效。这是结构性问题，建议本轮就改（改为求值局部状态，改动集中在 `Interpreter.cj` 一个文件）。
2. 表达式解析器递归下降没有深度上限，`maxNodes` 数不到括号层数，而脚本来源可以是决策表 / Excel 的 `expr` 列 —— 一条深括号表达式就能把进程打崩。加一个 `depth` 计数即可，成本很低。

其余一般项属于「静默失效」类：白名单函数不校验 arity、`contains` 系列把 `Unknown` 压成 `false`（`!` 之后变真）、多级字段路径被截断、`interpretFallback` 逐次重编译并静默降级、`parseLambdaParameters` 按逗号盲切。它们不会崩，但会让规则「看起来配了却不触发」，且都缺乏对应用例（`InterpreterVsJit_test` 只有 4 条表达式、5 条事实，没覆盖函数与未知值），建议补一组函数/未知值/错误表达式的差分用例后再修。

`Agenda` 侧的风险是并发契约缺失（同 id 会话共享同一实例但无同步）与惰性堆不压实导致的内存保留，前者需要先定线程模型再谈改法，后者可以在不动语义的前提下加压实。性能与内存的 5 条方案全部没有基线，只能作为下一轮补数据的清单，不进 `tasks.md`。

**第 5 部分**：求值核心（三值逻辑、15 个算子、`Between`/`In` 的边界、`JoinConstraint` 的绑定缺失语义）实现干净，与 `doc/03` 的约定和 `TruthTable_test`/`Operator_test` 的断言逐条对得上；`RuleFailureGuard`、`DecisionTable.mode_`、`ShardedNetwork` 的静态缓存都有明确的同步手段，说明作者对并发并非无意识。

本部分唯一阻塞项是 `RuleEngine` 的并发承诺：文档写「线程安全」，但 `sessions_` 与 `closed_` 完全没有同步，`session()` 又是检查-然后-写入；一旦多线程按文档用法创建会话，轻则同一 `id` 分裂成两份互不可见的事实、会话从表中丢失无法释放，重则在 `HashMap` 迭代期间被修改。这一条应优先修（加锁或明确改口为「引擎非线程安全」）。

其余「一般」都属于契约层面的收口：`RuleSet` 被多引擎共享时超时与关闭互相影响、`release` 不回收网络内存、`elements` 的容器类型契约与 `Between` 的无序集合、`Pattern` 构建后仍可变、`executeTable` 失败污染表模式、会话写入口绕过传播与关闭检查。它们不会立刻让业务算错，但在「长跑 + 多引擎 + 动态表」的组合下会以「内存不降 / 错误码误导 / 规则静默不激活」的形式暴露，建议排期修。轻微项与优化方案可在有 bench 数据后再定优先级。

**第 6 部分**：本部分集中在事实层（`fact/` 19 个文件）与会话上下文（`flow/FlowContext.cj`），是规则引擎的数据基座，代码风格统一、注释密度高、契约（`Fact` / `FactHandle` / `ValueKey` 全序与归一）写得比多数模块清楚，单元测试对归一、全序、冻结、会话隔离的覆盖也扎实。

风险集中在两处：

1. **并发承诺与实现脱节**（严重项 1）。`01-architecture.md` 与 `08-api.md` 都把 `FactBase` 描述成线程安全、按 `(space, typeTag)` 分段加锁，实现里一个锁都没有，`RuleSession` 也不加锁。这是阻塞项：要么补锁，要么改文档并加运行期断言，二者必须选一个，不能保持现状。
2. **值的引用语义没有闭环**（严重项 2 + 一般项 5/6）。`freeze` 只冻结标量写入，`assertCopy` 只浅拷，`TypedFact` 直接暴露宿主对象，`Fact` 契约「进入网络后取值不变」在三条路径上都不成立；配合 `ValueKey` 归一后的索引，一旦调用方改了容器或宿主字段，索引与事实就会静默漂移。建议把「事实值必须不可变」做成可检查的约束（集合深拷 + 可空字段校验 + 宿主类一致性校验），而不是仅写在注释里。

其余发现多为边界与不变量缺口：句柄身份缺 session、`assert` / `assertCopy` 字段口径不一致、`update` 自更新行为随实现类型漂移、`commitToParent` 非原子、`declare` 冻结语义与注释相反。这些修复面小、风险低，可以排进常规批次。性能方面本轮没有任何 profile / bench 数据，`FactBase.assert` 与 `ValueKey.of` 虽然是插入主路径上的高频点，也只能作为待验证假设，不能进任务清单。

存量缺陷 16 条（严重 2 / 一般 9 / 轻微 5），是否纳入修复待用户决定。

**第 7 部分**：本部分代码的骨架是清晰的：`RuleEnvelope` 用不可变信封解决 `f_egraph` 随机 session 的问题，`ResolveTask`/`JoinTask`/`RuleTask` 职责边界干净，构建期校验（`validateJoinBranches`、同空间扇出拒绝）方向正确，测试覆盖了幂等、会话隔离与残留分支重放这些容易踩的点。

真正阻塞的是 **JoinTask 的状态机生命周期**：定时器只带 session 不带轮次（发现 #1，单线程即可复现），加上 `RuleSetFlow.join` 不传 timeout 导致半到达状态永不回收（发现 #2），两者叠加会让「允许同一 session 发起下一轮」这条文档承诺在实际编排中不成立。第 2 部分已报的 exec/expire 交错竞态是同一处状态的并发面，合并报告时建议把 #1 与它放在同一节，按「定时器身份 + 状态原子迁移」一次性改完。

其次是 **编排门面的接线缺口**（发现 #3/#4）：`JoinTask` 注释承诺的超时出口没有接、`end()` 承诺的逐边可达性没有做，导致「能通过构建期校验的流程」比文档承诺的宽松，残留分支问题只能在运行期暴露。这两条修起来都不大（接 `timeoutSink` 到 `flow.emit`、`end()` 调一次 `Reachability.validate`），但需要决定是补实现还是改文档，不能继续两边不一致。

`AlphaMemory` 本身没有本部分级别的正确性缺陷，问题集中在「索引维护无同步 + 一份事实五份表示」；前者与第 2 部分的线程安全契约同根因，后者只有优化价值、缺基线数据。`nullSet_` 死字段和镜像实现属于清理项，可随下一次改动顺手处理。

**第 8 部分**：`rete/` 这部分整体结构清晰：网络构建期与运行态（`ReteNetwork`/`SessionNetwork`）、alpha/beta 两侧索引、共享键三层职责划分明确，注释密度高且大多与实现同步（除发现 8 的一处）。死代码与空实现也很干净——20 个文件里只有一条 `let _ = registry` 和一处接口方法残留。

真正的风险集中在**索引与共享键的正确性**上，两条严重项都属于「静默丢数据」而不是崩溃：

1. `BetaMemory.orderedHeader` 的边界方向与 `AlphaMemory` 相反，`Le` 连接会漏掉全部等值候选，且候选缺失无法在下游 join 重算中被发现。这是本轮最该先修的一条——修改量是一行边界，但需要补 `Le` 连接的等价性用例（现有用例恰好绕过了它）。
2. `JoinSignature` 的共享键不含绑定名，让「无 join 的多模式规则」在跨规则共享节点时拿到别人的绑定名，规则会先刷 WARN、再被失败阈值整条禁用。修法要么补键，要么在 `Validator` 里禁掉这种规则形态，二选一都要落到文档。

四条一般项里，重复登记（发现 3）与 `frozen_` 检查-然后-写入（发现 4）不是正确性阻塞项但会随规则集规模放大后果；常量归一失败导致的签名塌缩（发现 5）需要先确认哪些常量能绕过 `Validator`，再把校验补齐；递归深度（发现 6）在「规则集由代码显式构建」的前提下风险有限，但缺一条书面约束。

优化方案两条都缺基线，只能作为下一轮的补数据清单，不进修复计划。存量缺陷共 10 条，是否纳入修复待用户决定。

**第 9 部分**：本部分聚焦 Rete 运行态（根分发、会话分片、令牌、终端）与规则集装配的收尾件，核心求值路径的语义是站得住的：等值分发有空值/类型不匹配兜底、撤销走「命中记录 + 未索引链头」双路径且保留了全链头回退、令牌判等与哈希一致、条件树展开有 64 条上限与 `Not` 下推的明确边界、失败收敛有阈值与成功清零。没有发现会算错匹配结果的逻辑错误，也没有无界容器或按不可信长度预分配的 OOM 面。

阻塞项只有一个：`ShardedNetwork.rebuild` 在进程级共享实例上无同步改写 `HashMap`，同时破坏引擎隔离——它的设计意图（`SessionRuntime` 用 `generation` 感知换代）说明它被当作运行期能力，因此必须先把并发与隔离修掉，否则这个公开 API 迟早被误用成线上崩溃点。紧随其后的是 `rebuild` 与 `SessionRuntime.shard()` 合起来留下的旧激活残留，两者应一起修（重建 = 结构换代 + 旧激活撤销）。

可以排期的是三件「契约说了没做/做重了」的事：`RuleSet.close()` 不清缓存（内存滞留到下次构建）、规则集级健康状态一锁四用把全部会话的激活路径串起来、终端与报告器各写一套失败收敛。前两件改动小、收益明确；第三件是纯重构，建议与下一次日志规范调整一起做。

其余为可维护性层面的清理：`Token` 的只写不读引用计数（会误导后来者以为有手写内存管理）、两处同构样板、测试文件里的死代码与过期包注释。性能侧只有三条待验证假设级的候选（令牌哈希重算、绑定表复制、空命中条目），都还没有基线数据，不进修复清单。

**第 10 部分**：本部分是全模块的「装配 + 载体」层：`Rule`/`RuleSetBuilder`/`Validator` 的职责划分清楚，`Validator` 的检查顺序（空间 → 规则身份 → 模式 → 算子类型）与错误码一一对应，注释把设计取舍（仓颉关键字改名、条件树 DNF 展开上限、表/聚合两条路径互斥）写得很到位；`DecisionTable.mode` 的双路径互斥用单把 `Mutex` 做成原子检查-然后-写入，`RuleRuntime` 的共享编译器也走了锁而不是双重检查锁，并发面无缺陷。**没有阻塞项，也没有严重问题**——12 个子轮里这一部分可以按「可排期」处理。

真正的风险集中在 CSV 载体：「引号未闭合」与「列表值含逗号」两处会让畸形输入静默产出**错误的命中结果**（不报错、不告警），建议优先修；同类还有「未知 `#` 元数据键拼错静默用默认策略」，因可用性影响较小只记轻微。`doc/07:258` 承诺的 `line`/`column` 与 `RuleException` 实际字段不符，属文档契约漂移，应与文档侧的本轮结论合并后一并订正；`ColumnKind.Metadata` 承诺的「说明/启用开关」列同理。内存面只有 CSV 全量物化一条（无上限、每格两拷贝），量级是「文件大小的数倍」，在启动期加载的常规规模下不构成事故，但值得加一个 `maxBytes` 拒绝路径。

轻微项多为可维护性：一处死字段、一处未使用的测试辅助、`asRuleAction` 兼容残留、三处重复实现、两处过期注释、`lastError_` 未清零、每规则取一次 `compiler()`、`ScriptAction` 每次构造都重刷一次全局绑定快照、`RuleRuntime` 双状态字段、`ColumnKind` 走字符串判等、空行判定只覆盖单列、编译失败不回滚模式位。这些不影响正常路径行为，但会让下一轮改动更容易踩到「注释说 A、代码做 B」。性能结论本轮一律未成立（无 bench / `cjprof` 数据），`HitAggregator` 的 O(n²) 插入排序是最值得下一轮补数据的一项：它在 `Priority` 场景只需单趟最小值，改动小、验证成本低。

**第 11 部分**：本部分是 `f_rule` 的决策表运行时：模型（`DecisionTable`/`TableRow`/`Column`）、编译（`TableCompiler` + `CellParser`/`OutputCell`/`ExprColumn`）、执行与聚合（`TableExecutor`/`HitAggregator`）、两种载体解析（`CsvTableParser`/`XlsxTableParser`）以及 6 个测试文件。整体质量偏上：编译期校验链完整（空表 → 类型推断 → 字段/算子/值 → 输出引用 → salience → Unique 重复行），错误码区分清楚（`TABLE_INVALID` 结构问题 vs `TYPE_MISMATCH` 数据问题 vs `UNKNOWN_BINDING`/`UNKNOWN_FIELD` 引用问题），两条执行路径的互斥有专门状态机与 5 条用例，流式入口与整表入口的语义差异（合并单元格、类型推断）在文档与 WARN 里都交代过；并发面很小且都用了正确的同步手段（`mode_` 与 `compileCount_` 各一把短锁，执行器本身不可变），没有发现数据竞争或栈溢出。

主要风险集中在**契约与实现的三处错位**，它们都不会在编译期暴露，也都已有测试把"现状"固化成"期望"：

- 契约面 #2：`XlsxTableParser` 类注释与 `table.cj` 把"10 万行"当卖点，但流式只覆盖读取阶段，`TableCompiler` 仍把每行编译成 `CompiledRow + Rule + Pattern` 常驻（40–80 MB 量级），T-14 只断言了 `rows.isEmpty()`，等于用一个不完整的体积不变式背书了整个链路。建议先改文档措辞 + 补一条"编译后堆增量"用例，再决定要不要做流式聚合。
- 契约面 #3 / #4：`Any` 返回 N 条与 `TableResult`「单值策略至多一条」相反；`${o}`（整事实输出）与 `Any`/`Priority`/`OutputOrder` 组合会在聚合期抛 `TYPE_MISMATCH`（`ValueKey` 不接受 `Fact`）。前者改一行 + 一条用例即可对齐 DMN，后者建议在编译期就拒掉该组合，避免运行期用错误的错误码失败。
- 资源面 #1：流式路径从头到尾没有 `ExcelSheetStream.close()`，`RowReader` 只在读到头才关；编译中途因坏单元格失败时条目流不释放，而 `XlsxTableStream` 会一直持有该 stream。这类泄漏在"批量导入一堆 XLSX 决策表"的启动场景里会累积成句柄耗尽。

性能方面本部分**没有**任何测量数据，因此只有一条可以从代码静态判定的算法问题——#5 的插入排序（`RuleOrder`/`OutputOrder` 在 10 万命中时从 O(n log n) 退化到 O(n²)）——其余 5 条假设与 5 条优化方案都标了"无基线（待验证）"，不进修复清单。下一轮最值得补的数据是假设 1（`execute` 的 O(行×事实) 占比）与假设 5（排序耗时曲线），它们决定聚合路径要不要结构改造；假设 2 则直接决定 #2 到底该改文档还是改实现。

轻度债务集中在重复逻辑（三个 enum 的 `==`/`!=`、CSV/XLSX 的 `_meta` 映射与 `salience` 解析、`HitAggregator` 的三处排序样板、`outputsOf` vs `actionFor`、两套数字推断/表头宽度）与两处死代码（`CsvScanner.start`、`let _ = condition`），修起来都轻，但 #11 的映射重复已经出现"XLSX 校验 id、CSV 不校验"的漂移，值得在下一轮一并收敛。

**第 12 部分**：本部分是测试与门禁代码，不含生产逻辑，但它是 `f_rule` 正确性的执行层，问题性质集中在"断言是否真的能失败"上，而不是运行时缺陷。

最需要排期的是 #1：B-02 明明算了 1000 条激活的完整排序键，却在比对前把它截断到 20 条，使 `1000 规则 / 10000 事实` 这条核心等价性门禁对 98% 的激活失明。它和 #2（两侧都为空时断言恒真）、#4（多重集退化成集合包含）是同一类问题的三个面：门禁的形状是对的，判定强度不足，回归会以"绿色通过"的方式漏出去。#3 的 B-05 内存门禁属于同一风险族：`rssBytes()` 的 `-1` 哨兵值直接让 `requireBelow` 通过，绝对 RSS 又受同进程前序用例的静态缓存影响，读数可信度不足。

#5（`PropertyGen` 负种子）与 #6（排序键影子实现）是两条"现在不炸、改动时炸"的存量隐患：前者把非法参数变成难排查的 `EMPTY_PATTERN` / `UNKNOWN_BINDING`，后者让差分基线与 `Activation.key_` 只在注释层面保持一致。#7~#12 属可维护性与测量纪律问题，可随下一次接触该目录时顺带处理。

正面结论也要写清：分层与命名清晰，`PerfSupport` 统一了采样口径（最近秩分位数、warmup 分离、门禁阈值集中在 `PerfGate`），差分/集成用例的覆盖面（约束类型、撤销、会话隔离、JIT 与解释器对齐）设计到位，`NaiveMatcher` 作为语义基准的实现足够直白。没有任何空实现、无界容器、栈溢出或并发共享写路径；`MatchWalker` 的递归深度由规则模式数封顶，`bindings.remove` 建立在 `Pattern.requireUniqueBindings`（`src/condition/Pattern.cj:115`，由 `src/rule/rule.cj:210` 在构建期强制）之上，属可证明安全的写法。

## 范围外提示（不计入统计）

- `f_rule/src/engine/RuleEngine.cj:75`-`:84`：`sessions_` 用普通 `HashMap`、`session()` 是检查-然后-写入，`RuleTask.cj:76` 是唯一生产调用点（第 1/2 部分已就线程安全契约报过，归 engine 子轮处理）。
- `f_rule/src/flow/FlowContext.cj:67`/`:142`：静态 `contexts` 只增不减，`RuleTask.cj:73` 是唯一生产触发点（第 1/2 部分已报，本部分不重复计数）。
- `f_rule/doc/06-flow-orchestration.md:230`-`:238`、`:320`、`:529`：签名与 exec 契约落后于实现（归 doc 子轮）。

- `f_rule/doc/04-rete-network.md:357`-`:359`（传播顺序按 `node.id` 升序）、`:371`-`:387`（§7.2 只描述 `BetaMemory` 的等值索引，实际已有有序索引）：文档滞后于实现，归 doc 子轮。
- `f_rule/src/rete/SessionNetwork.cj`、`SessionRuntime.cj`：会话容器同样无同步、`shard()` 是检查-然后-写入；第 7 部分已就 `AlphaMemory` 报过同根因的线程安全契约问题，此处不重复计数。
- `f_rule/src/rete/Token.cj:141`-`:157`：`==`/`hashCode` 沿父链递归（深度 = 模式数）且相等性忽略 `binding`，与发现 2 互为放大器；`Token.cj` 归其他子轮。
