# f_rule 模块审查报告（模块第 1/12 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_rule`（模块共 184 个 `.cj` + 33 个 `.md`；本部分只含 `files/f_rule.part1.txt` 的 7 个 `.md`）
- **基线**：工作区快照（sts/1.3.x 工作区，无 diff，全部问题记「存量」）
- **审查重点**：规则引擎求值正确性、递归与栈溢出、OOM、死代码、重复逻辑、并发安全、存量 BUG
- **报告版本**：v1（模块第 1/12 部分的分报告，只统计本部分 7 个文件；`docs/review/2026-11-28/f_rule.md` 由主 Agent 合并各分报告后产出，本文件不替代模块报告）

> 说明：本部分文件全部是文档（README / README_en / doc/01~05）。为避免"只对文字下结论"，每条发现都按「文档承诺源 + `src/` 实现取证」的方式核对；`.cj` 的完整代码审查留给第 2~12 部分，本报告中的代码定位仅用于证明文档契约与实现是否一致。

## 发现

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

## 优化可行性方案

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

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 会话表随历史 session 数线性增长，长跑最终 OOM | `src/engine/RuleEngine.cj:35` / `src/flow/FlowContext.cj:67` | 单会话平均 facts/tokens 与 RSS 曲线 | 10 万唯一 session 循环，采 `heapUsed`/RSS/`sessions_.size` |
| 2 | `invalidateGroup` 在"每组一条规则"时退化为 O(n²) | `src/agenda/agenda.cj:216` | `fire` 自耗时占比 | `cjprof record` + 1000 组规则 bench |
| 3 | 激活指纹字符串占 B-02 插入路径 >5% | `src/agenda/Bindings.cj:132` / `src/agenda/Activation.cj:52` | 分配量与自耗时 | `cjprof` 分配采样 + B-02 对照 |
| 4 | `In` 全扫在 In 密集规则中成为 join 瓶颈 | `src/rete/AlphaMemory.cj:166` | 覆盖率与实际耗时 | 500 条 In 约束规则 bench，对照 Eq |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `README.md` | .md | ✅ | 逐节读完；API/默认值/依赖与实现比对，见发现 2/6/7/9/12/13 |
| 2 | `README_en.md` | .md | ✅ | 与中文版逐节对照，结构/条目一致；同源问题同上（发现 12） |
| 3 | `doc/01-architecture.md` | .md | ✅ | 分层/包结构/数据流/并发模型/错误码；问题见发现 1/7 |
| 4 | `doc/02-fact-model.md` | .md | ✅ | 事实模型/FactSpace/会话隔离；问题见发现 2/6/8/10 |
| 5 | `doc/03-condition-expression.md` | .md | ✅ | 算子/条件树/JIT/解释器；问题见发现 5/6/8/11 |
| 6 | `doc/04-rete-network.md` | .md | ✅ | Rete 结构/共享/索引/回收；问题见发现 3/4/10/11 |
| 7 | `doc/05-agenda-conflict-resolution.md` | .md | ✅ | 议程/冲突消解/FireMode/循环检测；问题见发现 9 |

合计：`.cj` 0 个 / `.md` 7 个 / 共 7 个，全部读完。

## 覆盖自检

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

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 2 |
| 一般 | 7 |
| 轻微 | 4 |
| 优化方案（堆内存 / CPU） | 1 / 2 |

存量 13 条，是否纳入修复待用户决定。

## 总评

文档整体质量在同类模块里偏高：README 与 `README_en` 结构完全同步，错误码（27 个）、性能门禁 B-01~B-07、包结构、API 速查都有覆盖，`doc/04` 还主动标注了 `In` 未展开的已知边界。主要风险不是"写得少"，而是**文档领先于实现**：

1. **阻塞项（2 条严重）**：`doc/01`/`doc/08` 宣称 `RuleEngine`/`FactBase` 线程安全，但实现完全没有同步（发现 1）；`FlowContext` 与 `RuleSession` 各建一套 `FactBaseViewStore`，文档承诺的同一视图不成立，且文档指定的释放路径释放不掉引擎会话，按每请求一个 session 使用会无界增长（发现 2）。这两条要么补同步/统一 store，要么改写文档承认"会话线程封闭 + 显式 engine.release"，不能保留现状。
2. **可排期（7 条一般）**：`RuleSet.close()` 空实现与静态网络缓存（发现 3）；`doc/04` 的 Rete API（发现 4）、`doc/03` 的条件 API（发现 5）、`doc/05` 的议程 API（发现 9）仍在描述旧设计/旧签名，示例无法编译；`doc/02` §7 的动态事实 JIT 示例与强制解释器策略矛盾（发现 6）；`doc/01` 的包结构与依赖方向错误（发现 7）；`TraceLevel` 追踪能力只有文字（发现 8）。
3. **文档卫生（4 条轻微）**：网络持有事实对象的描述、`In` 可索引口径、README 自动生成清单、`f_util` 死依赖。

规则求值正确性本身在本部分只能做"文档承诺 vs 实现"层面的核对：三值逻辑、DNF 展开上限、HitPolicy 降级、循环检测阈值都与实现基本一致（仅阈值文案差一次）；更细的求值路径（alpha/beta 探测、脚本降级、决策表编译）留给第 2~12 部分的 `.cj` 审查。性能结论均无本轮测试数据，只以「待验证假设」形式保留，未写成结论。
