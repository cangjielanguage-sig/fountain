# f_rule 模块审查报告（模块第 12/12 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_rule`（本部分 12 个源文件，全部位于 `f_rule/src/test`；模块全量 184 个 `.cj` + 33 个 `.md`）
- **基线**：工作区快照（无 diff 可比，本部分所有问题来源统一记「存量」）
- **审查重点**：规则引擎求值正确性、递归与栈溢出、OOM、死代码、重复逻辑、并发安全、存量 BUG；本部分实际审查对象是差分基准 `NaiveMatcher` 与性能/一致性门禁用例
- **报告版本**：v1（本部分只产出分报告，模块报告由主 Agent 合并）

## 发现

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

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `Differential_test.expectEqual` 在成功路径上每次拼两份全量字符串比对（`joinKeys` 无截断），200 组下可能占用例可观 CPU | `Differential_test.cj:130`、`:170` | 该函数自耗时占比、字符串分配量 | `cjprof record` 跑 200 组差分，看 `String.operator+` / `joinKeys` 自耗时与分配次数 |
| 2 | `ReteNetwork_test.sameActivations` 的 O(n·m) 线性查找在大激活集合下可能成为用例瓶颈（当前用例规模 < 10 条） | `ReteNetwork_test.cj:189` | 用例内 n、调用次数、耗时 | 给该用例加分段计时，跑 100/1000 条事实两组对照 |
| 3 | `Differential_test` 每个 group 重建网络占用例总时长的主要部分 | `Differential_test.cj:48` | 构建耗时占比 | `cjprof record` 200 组，按 `ShardedNetwork.init` 汇总自耗时 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_rule/src/test/Differential_test.cj` | .cj | ✅ | 差分主用例；见 #2、#7 |
| 2 | `f_rule/src/test/Integration_test.cj` | .cj | ✅ | I-01~I-06；见 #2、#11 |
| 3 | `f_rule/src/test/NaiveMatcher.cj` | .cj | ✅ | 差分基准；见 #6、#7、#8、#9 |
| 4 | `f_rule/src/test/NaiveMatcher_test.cj` | .cj | ✅ | 空间语义用例，6 个用例与实现一致 |
| 5 | `f_rule/src/test/PerfFixture_test.cj` | .cj | ✅ | 夹具契约；见 #10 |
| 6 | `f_rule/src/test/PerfInsert_test.cj` | .cj | ✅ | B-02~B-04；见 #1、#12 |
| 7 | `f_rule/src/test/PerfMemory_test.cj` | .cj | ✅ | B-05；见 #3 |
| 8 | `f_rule/src/test/PerfNetwork_test.cj` | .cj | ✅ | B-01/B-06，口径与 `doc/09-testing.md` 描述一致 |
| 9 | `f_rule/src/test/PerfSupport.cj` | .cj | ✅ | 门禁与采样工具；见 #3、#7、#8、#9、#12 |
| 10 | `f_rule/src/test/PerfTable_test.cj` | .cj | ✅ | B-07，解析+编译口径与注释一致 |
| 11 | `f_rule/src/test/PropertyGen.cj` | .cj | ✅ | 生成器；见 #5、#9 |
| 12 | `f_rule/src/test/ReteNetwork_test.cj` | .cj | ✅ | R-01/R-08/R-10~R-13；见 #4 |

合计：`.cj` 12 个 / `.md` 0 个 / 共 12 个，全部读完（本部分清单不含 `.md`）。

## 覆盖自检

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

> 仅统计本部分 12 个文件。

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 1 |
| 一般 | 5 |
| 轻微 | 6 |
| 优化方案（堆内存 / CPU） | 1 / 2 |

存量缺陷 12 条（1 严重 + 5 一般 + 6 轻微），是否纳入修复待用户决定。本部分改动为零，无「本次改动」条目。

## 总评

本部分是测试与门禁代码，不含生产逻辑，但它是 `f_rule` 正确性的执行层，问题性质集中在"断言是否真的能失败"上，而不是运行时缺陷。

最需要排期的是 #1：B-02 明明算了 1000 条激活的完整排序键，却在比对前把它截断到 20 条，使 `1000 规则 / 10000 事实` 这条核心等价性门禁对 98% 的激活失明。它和 #2（两侧都为空时断言恒真）、#4（多重集退化成集合包含）是同一类问题的三个面：门禁的形状是对的，判定强度不足，回归会以"绿色通过"的方式漏出去。#3 的 B-05 内存门禁属于同一风险族：`rssBytes()` 的 `-1` 哨兵值直接让 `requireBelow` 通过，绝对 RSS 又受同进程前序用例的静态缓存影响，读数可信度不足。

#5（`PropertyGen` 负种子）与 #6（排序键影子实现）是两条"现在不炸、改动时炸"的存量隐患：前者把非法参数变成难排查的 `EMPTY_PATTERN` / `UNKNOWN_BINDING`，后者让差分基线与 `Activation.key_` 只在注释层面保持一致。#7~#12 属可维护性与测量纪律问题，可随下一次接触该目录时顺带处理。

正面结论也要写清：分层与命名清晰，`PerfSupport` 统一了采样口径（最近秩分位数、warmup 分离、门禁阈值集中在 `PerfGate`），差分/集成用例的覆盖面（约束类型、撤销、会话隔离、JIT 与解释器对齐）设计到位，`NaiveMatcher` 作为语义基准的实现足够直白。没有任何空实现、无界容器、栈溢出或并发共享写路径；`MatchWalker` 的递归深度由规则模式数封顶，`bindings.remove` 建立在 `Pattern.requireUniqueBindings`（`src/condition/Pattern.cj:115`，由 `src/rule/rule.cj:210` 在构建期强制）之上，属可证明安全的写法。
