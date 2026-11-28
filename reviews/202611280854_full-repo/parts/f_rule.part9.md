# f_rule 模块审查报告（模块第 9/12 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_rule`（本部分 20 个源文件：`.cj` 20 个 / `.md` 0 个；模块整体 184 个 `.cj` + 33 个 `.md`）
- **基线**：工作区快照（`git status` 仅有未跟踪的 `docs/review/`、`reviews/`，无 diff → 全部问题来源记为「存量」）
- **审查重点**：规则引擎求值正确性、递归与栈溢出、OOM、死代码、重复逻辑、并发安全、存量 BUG
- **报告版本**：v1（本文件是模块分报告 `parts/f_rule.part9.md`，不替代 `docs/review/2026-11-28/f_rule.md`）

## 发现

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

## 优化可行性方案

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

## 待验证假设

> 没有性能测试数据支撑的猜测，只用于下一轮补数据；不进 `todo.md` / `tasks.md`。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `Token.hashCode` 的 O(模式数) 重算在多模式规则下占插入路径可观比例 | `f_rule/src/rete/Token.cj:149` | `Token.hashCode` 的 self time 占比、每事实平均哈希调用次数 | `cjprof record` 跑 4 模式规则 + 5 万/50 万事实的 assert，导出 self time；同时在 `BetaMemory` 加哈希调用计数埋点 |
| 2 | `RuleFailureGuard` 单一 `Mutex` 使多会话并发激活串行化 | `f_rule/src/rule/RuleFailureGuard.cj:34`、`rete/TerminalNode.cj:72` | 锁等待时长、线程 BLOCKED 比例、加锁频率 | 4 线程 × 各自 `RuleSession`、同一 `RuleSet`、10 万次激活；用线程状态采样（CPU profile 看不到锁等待）+ 在 `synchronized` 前后打时间戳统计等待分布 |
| 3 | `alphaHits_` 每条事实一个条目（含空命中）在百万级事实下抬高峰值内存 | `f_rule/src/rete/SessionNetwork.cj:37`、`rete/RootDispatch.cj:101` | 100 万事实下 `alphaHits_` 的条目数与字节量 | 固定规则集，注入 10 万/100 万事实，对比 `getAllocatedHeapSize()` 与 `getUsedHeapSize()` 稳态，并统计 `recordAlphaHits` 命中率为 0 的比例 |
| 4 | 首次并发 `shared()` 重复构建网络造成启动毛刺 | `f_rule/src/rete/ShardedNetwork.cj:86` | 并发首用时的构建次数与耗时 | 8 线程同时构造 `RuleEngine`（同一 `RuleSet`），统计 `ReteNetwork` generation 自增次数与各自耗时 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_rule/src/rete/RootDispatch_test.cj` | .cj | ✅ | 等值分发语义用例，覆盖字符串/数值/桶内多链头/范围回退/join；未见缺口 |
| 2 | `f_rule/src/rete/RootNode.cj` | .cj | ✅ | `heads()`/`typeTags()` 仓内零引用（对外可 reachable，不判死代码）；`addHead` 去重后早退不登记 dispatch，因 `alphaNodeFor` 已按签名共享节点，无实际缺陷 |
| 3 | `f_rule/src/rete/RuleFailureReporter.cj` | .cj | ✅ | 与 `TerminalNode` 重复失败收敛（发现 #5） |
| 4 | `f_rule/src/rete/SessionNetwork.cj` | .cj | ✅ | 三个惰性 getter 同构复制（#8）；`betaMemoryCount`/`clearMemories` 仓内零引用（对外可 reachable） |
| 5 | `f_rule/src/rete/SessionRuntime.cj` | .cj | ✅ | 分片换代不清旧激活（#2）；Naive 分支为测试后端 |
| 6 | `f_rule/src/rete/ShardedNetwork.cj` | .cj | ✅ | `rebuild` 数据竞争（#1）、静态缓存不失效（#3）、`shared` 重复构建（#13） |
| 7 | `f_rule/src/rete/SpaceSharding_test.cj` | .cj | ✅ | 分片隔离用例；未覆盖重建后激活残留；未使用 import `Fact`（#9） |
| 8 | `f_rule/src/rete/TerminalNode.cj` | .cj | ✅ | 失败收敛重复（#5）、全局锁调用点（#4）、求值复制（优化 #3） |
| 9 | `f_rule/src/rete/TerminalNode_test.cj` | .cj | ✅ | 终端左激活/左撤回用例；测试替身 `TerminalTestSession` 的空实现有注释说明；未使用 import `Fact`（#9） |
| 10 | `f_rule/src/rete/Token.cj` | .cj | ✅ | 引用计数只写不读（#7）；`hashCode` 递归重算（优化 #2） |
| 11 | `f_rule/src/rete/Token_test.cj` | .cj | ✅ | 结构共享/判等/计数用例；未使用 import `Fact`（#9） |
| 12 | `f_rule/src/rete/rete.cj` | .cj | ✅ | 仅包级注释，内容停留在 M0/M2（#11） |
| 13 | `f_rule/src/rule.cj` | .cj | ✅ | 门面重导出，无逻辑；未逐项验证重导出符号是否存在（跨子轮） |
| 14 | `f_rule/src/rule/ActionContext.cj` | .cj | ✅ | 接口声明，分层理由有注释；实现方 `SessionActionContext` 在 `engine` 包（范围外） |
| 15 | `f_rule/src/rule/ClosureAction.cj` | .cj | ✅ | `asRuleAction()` 仓内零引用（public 且对外可达，仅记信息） |
| 16 | `f_rule/src/rule/ConditionExpander.cj` | .cj | ✅ | DNF 展开有 64 条上限；三个 `singleXxx` 同构（#8）；展开结果保留条件树（#6） |
| 17 | `f_rule/src/rule/ConflictResolver.cj` | .cj | ✅ | 默认链给出全序；`compareAsc` 重载重复但属惯用写法，未单列 |
| 18 | `f_rule/src/rule/RuleBuilder_test.cj` | .cj | ✅ | 装配契约用例；末尾 `BuilderOrder` 零引用（#10） |
| 19 | `f_rule/src/rule/RuleFailureGuard.cj` | .cj | ✅ | 单锁覆盖四类状态（#4）；键为 `(ruleSetId, ruleId)`，有界 |
| 20 | `f_rule/src/rule/RuleSet.cj` | .cj | ✅ | `close()` 未清缓存（#3）；`RuleSetStatus.==` 走字符串（#12） |

合计：`.cj` 20 个 / `.md` 0 个 / 共 20 个，全部读完（本部分无 `.md` 文件）。

## 覆盖自检

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

## 模块统计

> 仅统计本部分（模块第 9/12 部分，20 个文件）。

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 1 |
| 一般 | 5 |
| 轻微 | 7 |
| 优化方案（堆内存 / CPU） | 1 / 2 |

存量缺陷 13 条（本部分全部发现均为存量），是否纳入修复待用户决定。

## 总评

本部分聚焦 Rete 运行态（根分发、会话分片、令牌、终端）与规则集装配的收尾件，核心求值路径的语义是站得住的：等值分发有空值/类型不匹配兜底、撤销走「命中记录 + 未索引链头」双路径且保留了全链头回退、令牌判等与哈希一致、条件树展开有 64 条上限与 `Not` 下推的明确边界、失败收敛有阈值与成功清零。没有发现会算错匹配结果的逻辑错误，也没有无界容器或按不可信长度预分配的 OOM 面。

阻塞项只有一个：`ShardedNetwork.rebuild` 在进程级共享实例上无同步改写 `HashMap`，同时破坏引擎隔离——它的设计意图（`SessionRuntime` 用 `generation` 感知换代）说明它被当作运行期能力，因此必须先把并发与隔离修掉，否则这个公开 API 迟早被误用成线上崩溃点。紧随其后的是 `rebuild` 与 `SessionRuntime.shard()` 合起来留下的旧激活残留，两者应一起修（重建 = 结构换代 + 旧激活撤销）。

可以排期的是三件「契约说了没做/做重了」的事：`RuleSet.close()` 不清缓存（内存滞留到下次构建）、规则集级健康状态一锁四用把全部会话的激活路径串起来、终端与报告器各写一套失败收敛。前两件改动小、收益明确；第三件是纯重构，建议与下一次日志规范调整一起做。

其余为可维护性层面的清理：`Token` 的只写不读引用计数（会误导后来者以为有手写内存管理）、两处同构样板、测试文件里的死代码与过期包注释。性能侧只有三条待验证假设级的候选（令牌哈希重算、绑定表复制、空命中条目），都还没有基线数据，不进修复清单。
