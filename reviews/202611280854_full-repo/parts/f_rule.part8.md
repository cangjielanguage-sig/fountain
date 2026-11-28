# f_rule 模块审查报告（模块第 8/12 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_rule`（本部分 20 个源文件：`.cj` 20 个 / `.md` 0 个；模块整体 184 个 `.cj` + 33 个 `.md`）
- **基线**：工作区快照（sts/1.3.x，无 diff 可比，全部问题记「存量」）
- **审查重点**：规则引擎求值正确性、递归与栈溢出、OOM、死代码、重复逻辑、并发安全、存量 BUG
- **报告版本**：v1（模块第 8/12 部分，仅覆盖 `files/f_rule.part8.txt` 列出的 `rete/` 包 20 个 `.cj`；不产出 `docs/review/` 模块报告）
- **与同模块其他部分的关系**：本部分文件与第 1–7 部分无重叠。第 7 部分已就 `AlphaMemory` 的「索引无同步 + `sharedEmpty` 静态单例」与「`orderedTail`/`orderedHeader` 镜像重复」报过账，本部分**不重复计数**，只在正文标注「同根因，见第 7 部分」，并补上它没发现的跨文件边界漂移缺陷（发现 1）与 `BetaMemory` 侧的同源点。

## 发现

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

## 优化可行性方案

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

## 待验证假设

> 没有性能测试数据支撑的猜测。**不进 `todo.md` / `tasks.md`**，只用于下一轮补数据。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `alreadyEmitted` 的线性判重在大扇出 join 下成为自耗时主要来源 | `f_rule/src/rete/BetaProductions.cj:63`-`:79` | `contains` 自耗时占比、每次调用的平均列表长度 | `cjprof record` 跑「1 万左令牌 × 1 条右侧事实全命中」，按函数取 self time；同时埋点统计 `byHandle_` 列表长度分布 |
| 2 | `FromAlpha` 路径的临时 `Token.root` 占插入阶段分配量可观比例 | `f_rule/src/rete/BetaNode.cj:266`-`:271` | 每事实分配字节数、临时 `Token` 占比 | `cjprof heap` 稳态插入 10 分钟，对比「临时令牌数 / 子令牌数」；再试缓存复用后的分配量 |
| 3 | 懒建索引的首次探测（全量扫描 `tokens_`/`order_`）在首插阶段形成尖刺 | `f_rule/src/rete/BetaMemory.cj:278`-`:298` | 首次探测耗时、触发次数、扫描规模 | 分段计时 `ensureEqIndex`/`ensureOrdIndex`，在 1k/1w/10w 令牌三档各跑一次首探测 |
| 4 | 共享节点的重复登记使传播耗时按「共享规则数」线性放大 | `f_rule/src/rete/NetworkBuilder.cj:171`-`:174` | 同一 alpha/beta 节点的 consumer 份数分布、传播耗时对比 | 用 `NetworkSharing_test.hundredRulesShareTwentyAlphaSignatures` 的规则集，对比「去重前/去重后」的 `assert` 总耗时（同 SDK、`-O2`、10 万事实） |

## 范围外提示（不计入统计）

- `f_rule/doc/04-rete-network.md:357`-`:359`（传播顺序按 `node.id` 升序）、`:371`-`:387`（§7.2 只描述 `BetaMemory` 的等值索引，实际已有有序索引）：文档滞后于实现，归 doc 子轮。
- `f_rule/src/rete/SessionNetwork.cj`、`SessionRuntime.cj`：会话容器同样无同步、`shard()` 是检查-然后-写入；第 7 部分已就 `AlphaMemory` 报过同根因的线程安全契约问题，此处不重复计数。
- `f_rule/src/rete/Token.cj:141`-`:157`：`==`/`hashCode` 沿父链递归（深度 = 模式数）且相等性忽略 `binding`，与发现 2 互为放大器；`Token.cj` 归其他子轮。

## 文件覆盖

> 与 `reviews/202611280854_full-repo/files/f_rule.part8.txt` 一一对应（20 行，全部读完）。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_rule/src/rete/AlphaMemory_test.cj` | .cj | ✅ | alpha memory 幂等/索引维护用例，与实现一致 |
| 2 | `f_rule/src/rete/AlphaNode.cj` | .cj | ✅ | 链式短路与 memory 幂等；见发现 3、6 |
| 3 | `f_rule/src/rete/AlphaNode_test.cj` | .cj | ✅ | 含测试专用 `AlphaTestSession`（空 `recordAlphaHits`/`forgetAlphaHits` 为测试缝，已在注释说明） |
| 4 | `f_rule/src/rete/AlphaSignature.cj` | .cj | ✅ | 签名归一；见发现 5、9 |
| 5 | `f_rule/src/rete/BetaMemory.cj` | .cj | ✅ | 见发现 1（本部分最高优先级） |
| 6 | `f_rule/src/rete/BetaMemory_test.cj` | .cj | ✅ | 只覆盖 `Eq`/`Ge`，`Le` 路径无用例（发现 1 的证据之一） |
| 7 | `f_rule/src/rete/BetaNode.cj` | .cj | ✅ | 左右对称激活、候选定位；见发现 3、6、8、9 |
| 8 | `f_rule/src/rete/BetaNode_test.cj` | .cj | ✅ | 等值对称、范围（`Gt`）、三模式链、撤销；无 `Le` 连接 |
| 9 | `f_rule/src/rete/BetaProductions.cj` | .cj | ✅ | 产出索引；`contains` 线性扫描见优化方案 1 |
| 10 | `f_rule/src/rete/IndexCoverage.cj` | .cj | ✅ | 覆盖率计算，`total == 0` 有除零保护，未发现问题 |
| 11 | `f_rule/src/rete/IndexCoverage_test.cj` | .cj | ✅ | 覆盖率与 WARN 计数用例，与实现一致 |
| 12 | `f_rule/src/rete/JoinSignature.cj` | .cj | ✅ | 见发现 2（共享键不含绑定名） |
| 13 | `f_rule/src/rete/NetworkBuilder.cj` | .cj | ✅ | 建图/共享/覆盖率；见发现 2、3、5、8、9 |
| 14 | `f_rule/src/rete/NetworkSharing_test.cj` | .cj | ✅ | 共享与签名归一用例；`identicalJoinSignatureIsShared` 未断言 consumer 去重（发现 3） |
| 15 | `f_rule/src/rete/RangeIndex_test.cj` | .cj | ✅ | `AlphaMemory.select` 的 `Gt/Ge/Lt/Le/Between` 与全扫一致，恰好反证发现 1 的 `BetaMemory` 侧不正确 |
| 16 | `f_rule/src/rete/RangeKey.cj` | .cj | ✅ | `(ValueKey, ownerId)` 复合键，比较与哈希一致，未发现问题 |
| 17 | `f_rule/src/rete/RecordingSink.cj` | .cj | ✅ | 墓碑 + 位置索引，`compactIfNeeded` 均摊整理；未发现问题 |
| 18 | `f_rule/src/rete/ReteNetwork.cj` | .cj | ✅ | 节点共享与冻结；见发现 2、4、7 |
| 19 | `f_rule/src/rete/ReteNode.cj` | .cj | ✅ | 接口定义；`forgetAlphaHits` 无调用者见发现 10 |
| 20 | `f_rule/src/rete/RootDispatch.cj` | .cj | ✅ | 等值链头按值分发，`indexed.size == 0` 时不记命中、由 `RootNode` 回退全扫，路径自洽；不可归一字段值时静默跳过（只影响失败诊断，未单列） |

合计：`.cj` 20 个 / `.md` 0 个 / 共 20 个，全部读完。

## 覆盖自检

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

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 2 |
| 一般 | 4 |
| 轻微 | 4 |
| 优化方案（堆内存 / CPU） | 1 / 1 |

## 总评

`rete/` 这部分整体结构清晰：网络构建期与运行态（`ReteNetwork`/`SessionNetwork`）、alpha/beta 两侧索引、共享键三层职责划分明确，注释密度高且大多与实现同步（除发现 8 的一处）。死代码与空实现也很干净——20 个文件里只有一条 `let _ = registry` 和一处接口方法残留。

真正的风险集中在**索引与共享键的正确性**上，两条严重项都属于「静默丢数据」而不是崩溃：

1. `BetaMemory.orderedHeader` 的边界方向与 `AlphaMemory` 相反，`Le` 连接会漏掉全部等值候选，且候选缺失无法在下游 join 重算中被发现。这是本轮最该先修的一条——修改量是一行边界，但需要补 `Le` 连接的等价性用例（现有用例恰好绕过了它）。
2. `JoinSignature` 的共享键不含绑定名，让「无 join 的多模式规则」在跨规则共享节点时拿到别人的绑定名，规则会先刷 WARN、再被失败阈值整条禁用。修法要么补键，要么在 `Validator` 里禁掉这种规则形态，二选一都要落到文档。

四条一般项里，重复登记（发现 3）与 `frozen_` 检查-然后-写入（发现 4）不是正确性阻塞项但会随规则集规模放大后果；常量归一失败导致的签名塌缩（发现 5）需要先确认哪些常量能绕过 `Validator`，再把校验补齐；递归深度（发现 6）在「规则集由代码显式构建」的前提下风险有限，但缺一条书面约束。

优化方案两条都缺基线，只能作为下一轮的补数据清单，不进修复计划。存量缺陷共 10 条，是否纳入修复待用户决定。
