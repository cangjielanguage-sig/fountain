# f_xml 模块审查报告

> **模块第 5/7 部分**。本报告只覆盖 `files/f_xml.part5.txt` 列出的 19 个 `.cj`（词法层 + 状态机 + 名字驻留 + 命名空间 + 实体表 + 转义 + 溢出落点，以及 9 个对应测试文件）。「文件覆盖」「覆盖自检」「模块统计」只统计本部分；`README*`、`doc/**`、其余 `src/*.cj` 由第 1–4、6–7 部分产出。为取证引用了范围外文件（`EntityExpander.cj`、`XmlOptions.cj`、`RuneSource.cj`、`QName.cj`、`Spill_test.cj`、`README.md`、`doc/spec/**`）的行号，只作判据、不占统计。

- **审查日期**：2026-11-28
- **模块路径**：`f_xml`（本部分 19 个 `.cj`；模块共 72 `.cj` + 34 `.md`）
- **基线**：工作区快照（`git diff` 为空；HEAD = `f309f0b55`，与 dispatch 记录的 `120fd2542` 不同，但工作区无改动，结论不受影响）⇒ 全部问题记「存量」
- **审查重点**：XML 解析/序列化正确性与安全（XXE、实体展开、转义）、递归与栈溢出、OOM、死代码、重复逻辑、存量 BUG
- **报告版本**：v1（第 5/7 部分）

## 发现

### [严重][存量] #1 文本 token / 属性值 / DTD 内部子集三处全量物化，长度上限只在物化之后生效 → 流式内存契约（O(嵌套深度)）失效

- **位置**：`f_xml/src/Lexer.cj:484-537`（`nextContentToken`：整个文本段一次性堆进 `textScratch`，只在 `<` 处断开）、`:686-744`（`readAttributeValue`：整段属性值一次性堆进 `valueScratch`，循环内无任何长度判定）、`:1022-1087`（`readInternalSubset`：整个 DTD 内部子集一次性堆进 `textScratch`）；上限的唯一检查点 `f_xml/src/ParserEngine.cj:315-321`（在 `attribute.value` 已经构造完成之后）
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §5「一次性物化 / 无拒绝路径」、§11「契约与实现不符」
- **证据**：静态确定 —— 三处累积循环（`Lexer.cj:485-533`、`:693-742`、`:1027-1085`）都以「遇到终止符才退出」为条件，循环体内没有 `size`/`maxAttributeValueLength` 判定；`ParserEngine.cj:315` 拿到的是已完成的 `String`，此时峰值内存已经发生。承诺源：`doc/spec/complete-f-xml-m1-followups/specs/f-xml-conformance/spec.md:81-82`「事件模式的内存复杂度 SHALL 仍为 O(嵌套深度)」（已现场核对原文）、`:252` 同款表述；`README.md:412-413` 把 `maxAttributeValueLength`（1 MiB）描述为防超长属性的手段
- **描述**：三条不受上限约束的增长路径：
  1. **单个文本节点**：`<a>` 后接 N 字节纯文本、无任何标记 → `StringGenerator` 扩容 + `toString()` 各留一份，峰值约 2–3 N，`maxElementDepth`/`maxAttributeValueLength` 都管不到它；N = 数百 MB 时先 OOM，与「事件模式 O(depth)」直接矛盾。
  2. **单个属性值**：`maxAttributeValueLength` 默认 1 MiB，但 `<a b="` + 500 MB `x` + `"/>` 会先吃满 500 MB 再抛「超过上限」——拒绝路径滞后于分配，起不到防 OOM 作用。附带证据：`Lexer` 侧本来有一个 `maxAttributeValueLength` 字段（`:167`），`ParserEngine.init:105` 还把选项写了进去，但 `Lexer` 全文从不读它（见 #11-2）——「早停」是设计意图，只是没接线。
  3. **DTD 内部子集**：`<!DOCTYPE a [` + 大段声明/注释 + `]>` 整段进内存，既无长度上限也无拒绝路径；`Lexer.readInternalSubset` 还把内容 `toString()` 一次再交给 `DoctypeParser`（`ParserEngine.cj:259`）。
  附带一条同源残留：`textScratch` / `valueScratch` / `attrsScratch` 都只 `reset()`/`clear()` 不缩容（`StringGenerator.cj:35-38`、`133-136` 走 `ArrayList.clear()`），**一次大文本/大属性之后，该解析器余下全程都保留峰值容量**（`mem §3.2` / checklist §7 已列明 `clear()` 不还物理内存）。
- **建议**：在三条累积循环里各加一个「已累积 + 本段 > 上限」的判定并立即抛 `XmlException`（文本可用 `maxAttributeValueLength` 同量级的新选项，或复用硬限制）；属性值判定提前到 `gen.size > maxAttributeValueLength` 时即抛（复用已注入但未使用的 `Lexer.maxAttributeValueLength`）。文本节点若要保持流式，应在缓冲达到 `bufSize` 时就把 `TText` 分片吐出（事件语义已允许「文本可能被拆成多条」，`README.md:419-420`），而不是攒到 `<`。缩容问题：解析器生命周期短可不处理，但需在 `design.md` 里写明「单文档峰值容量会常驻到解析器结束」。

### [一般][存量] #2 重复的 `xmlns` / `xmlns:*` 声明不参与「Unique Att Spec」判重，静默 last-wins

- **位置**：`f_xml/src/ParserEngine.cj:287-289`（第一遍对**所有**属性调 `declareNamespace`，无去重）、`:304-314`（第二遍的 `seen` 只收集**非** xmlns 属性）、`:374-382`（`isNamespaceDeclaration` 把 xmlns 属性整体排除）；`f_xml/src/NamespaceScope.cj:69-71`（`declare` 无条件压栈，查表从栈顶回扫 ⇒ 后声明覆盖先声明）
- **来源**：存量（工作区快照）
- **判据**：review-checklist §11「契约与实现不符」；XML 1.0 §3.1 WFC: Unique Att Spec（同一开始标签内属性名不得重复），Namespaces in XML 1.0 §3 同款
- **证据**：静态确定 —— `<a xmlns:p="u" xmlns:p="v"/>` 中两条声明都进 `ns` 栈（`ParserEngine.cj:288` 逐个调用，无判重），第二遍循环在 `:305` 用 `isNamespaceDeclaration` 直接 `continue`，因此不会进入 `:309-313` 的重复检测；`NamespaceScope.lookup`（`:77-89`）自栈顶回扫取第一条匹配 ⇒ 生效值是 `v`，不报错
- **描述**：任何按规范的解析器都会把这类文档判为 not-wf，fountain 接受并以「最后一条」为准；同一份字节在「先声明优先」的实现里会得到另一个绑定，属于可被利用的解析器差异（命名空间混淆）。同类还有重复 `xmlns="…"`（默认命名空间）——同样被放过。
- **建议**：在 `:287-289` 这一遍之前，把 xmlns 属性的**字面名**（`rawNameText`）也放进同一个 `seen` 集合判重（注意判重口径：xmlns 属性按字面名，普通属性按展开名，两者要分开收集），命中即抛「重复的属性」。用例：`<a xmlns:p="u" xmlns:p="v"/>`、`<a xmlns="u" xmlns="v"/>` 两条都应报错。

### [一般][存量] #3 属性重复检测是 O(n²) 且属性个数无上限：单个开始标签可构造平方级 CPU

- **位置**：`f_xml/src/ParserEngine.cj:304-324`（每个属性对 `seen`（`ArrayList<QName>`）线性扫描一次，`:309-313`）
- **来源**：存量（工作区快照）
- **判据**：review-checklist §6.4「双层循环做匹配 / 去重 → O(n·m)」
- **证据**：静态确定（复杂度）—— 属性数 n 时比较次数 = n(n−1)/2，每次是 `QName.operator==`（`QName.cj:59-61`，含两次 `String` 比较）；`resolved` 数组 `:300` 也按 n 分配。属性个数只受输入长度限制（单属性值有 1 MiB 上限，**属性条数没有**）。实际耗时占比未测。
- **描述**：`<a ` + 50000 个 `a1="1" a2="1" …` + `/>`（约 600 KB 输入）会出现约 1.25×10⁹ 次 QName 比较，单标签即可占满一个核若干秒，而文档其余部分都是线性的。当前合成基准（`SemanticPerf_test` / `PerfFifty_test`）的属性个数固定为 2，测不到这条曲线。
- **建议**：改用 `HashSet<QName>`（或按 `(uri, local)` 建 `HashMap`）把判重降到 O(n)；若要保留"先报哪一个"的错误顺序，用 `HashMap<QName, Int64>` 记首次出现下标即可。等价性用例：`<a x="1" x="2"/>`、`<a xmlns:p="u" xmlns:q="u" p:x="1" q:x="2"/>`（`ParserError_test.cj:52/58` 已有）必须仍然报错且消息不变。顺带补一个「1 万属性」的耗时冒烟，避免以后回退。

### [一般][存量] #4 `Escaper.escapeAttribute` 不转义 LF / TAB，属性值往返会静默变成空格

- **位置**：`f_xml/src/Escaper.cj:43-60`（只处理 `& < > " \r`，`:56` 仅 `\r`）；对照同文件 `:21-22` 的自述理由「`\r` 必须转成 `&#13;`：否则写出再读回会被行尾归一转成 `\n`，往返不一致」；对照解析侧 `f_xml/src/Lexer.cj:732-734`（读回时 `0x0A` / `0x09` 一律归一成空格）
- **来源**：存量（工作区快照）
- **判据**：review-checklist §11「语义与注释不符」；XML 1.0 §3.3.3 属性值规范化（字面 LF/TAB → `#x20`）
- **证据**：静态确定 —— 写侧 `match` 分支里没有 `r'\n'` / `r'\t'`，只有 `r'\r'`；读侧对字面 LF/TAB 一律 `gen.append<String>(" ")`
- **描述**：`XmlWriter` 写出 `b="x\ny"` 后，用任何合规解析器（含本模块自己的 `Lexer`）读回都是 `b="x y"`——与 `\r` 的处理逻辑完全同类，只是漏了两个字符。以「写出去再读回来」为契约的调用方（配置导出、OOXML 片段拼接）会静默拿到被改写的属性值；`&#10;`/`&#9;` 才是保真的写法。
- **建议**：在 `escapeAttribute` 的 `match` 里补 `case r'\n' => out.append("&#10;")`、`case r'\t' => out.append("&#9;")`；`escapeText` 不需要（文本节点不做空白归一）。补一条往返用例：属性值含 `\n`、`\t`、`\r` 各一处，`parse(write(doc))` 后与原值逐码点相等。若判断为「有意不保真」，则必须改 `Escaper.cj:21-22` 的注释，否则注释本身在误导维护者。

### [一般][存量] #5 `LineWindow.peek(offset)` 对 `offset > 8` 静默返回 `None`，把「看得太远」伪装成 EOF

- **位置**：`f_xml/src/LineWindow.cj:155-164`（`peekFast` 快路径只覆盖 `0..8`）、`:166-177`（`peekFastSlow` 在 `:167-169` 对 `offset > 8` 直接 `return -1`）、`:297-304`（`peek` 把 `-1` 翻成 `None`，与真 EOF 无法区分）
- **来源**：存量（工作区快照）
- **判据**：review-checklist §11「契约与实现不符」、§10（正确性：边界）
- **证据**：静态确定 —— `if (offset < 0 || offset > 8) { return -1 }`；`position()` / `peek(0)` 仍报告真实位置，调用方无法区分「到 EOF」与「看得太远」。补充取证：`RuneSource.cj:40-45` 的注释声称 `peekFast` 与 `peek` / `advance`「语义完全一致」，而 `BufferedRuneSource.peekFast`（`:242`）同样在 `offset > 8` 返回 `-1`——两个实现口径一致，但都与 public `peek(offset)` 的接口语义（无上限）不一致，且上限只写在 `blockCapacityOf` 的注释里（`RuneSource.cj:61`「下限 64 保证 `peek(≤ 8)`」），`LineWindow` 与 README 都没有
- **描述**：`LineWindow` 是公开类型（`README.md:400` 明确登记，「一般业务代码不需要直接使用这些类型」同时说明它仍是契约的一部分），外部使用者按接口语义 `peek(20)` 会得到 `None`＝「只剩不到 20 个字符」，实际可能还有整篇文档。仓内调用者（`Lexer`）只用 0–5，所以内部解析不受影响；但这是对外可复现的错误答案。同一文件 `:157` 与 `:167` 把魔数 `8` 硬编码了两处（重复逻辑）。
- **建议**：三选一并写进 README 的「已声明的契约」：(a) `peekFastSlow` 改为循环 `ensure(offset + 1)` 支持任意 offset（块容量 ≥ 64，代价可控）；(b) 超限抛 `XmlException("peek 上限 8")`，不再伪装 EOF；(c) 把上限提成 `static let kMaxLookahead` 常量，在 `LineWindow`/`RuneSource`/README 三处写明。仓内既然只用到 5，(b)+(c) 最省事。

### [一般][存量] #6 `Lexer.nextScratchId` 是静态可变量，构造 `Lexer` 时无同步自增 —— 并发解析的数据竞争

- **位置**：`f_xml/src/Lexer.cj:157`（`private static var nextScratchId`）、`:173-176`（每次 `init` 做两次 `++` 与两次读）
- **来源**：存量（工作区快照）；与第 4/7 部分已报的 `ByteScratch.nextId`（`ByteScratch.cj:33/41`）同源同模式，合并时可并成一条
- **判据**：review-checklist §12.1「共享可变状态无保护」、§11「并发正确性」
- **证据**：静态确定 —— 共享路径：任意两个线程各自 `XmlPullParser(...)` → `ParserEngine.init` → `Lexer.init`（`ParserEngine.cj:104`）→ 对同一个 `static var` 做 `++`/读；无锁、无原子、无 thread-local。解析器本身是实例级、可并发使用（`EntityCounterIsolation_test.cj:33-58` 还专门验证了实例隔离），所以这条路真实存在
- **描述**：`Int64` 自增非原子，两个线程可读到相同序号（`this.valueScratchId` 与 `this.textScratchId` 也可能相等）。后果限于诊断字段：`BufferReuse_test.cj:104` 用这三个 id 做「复用缓冲实例数恒定」的结构性断言，并发跑该用例时可能拿到重复 id 而误判；不影响解析结果。`id` 的用途纯属测试观测，却把可变静态状态带进了生产热路径的构造流程。
- **建议**：这两处序号只是测试观测值，最省事的修法是删掉 `nextScratchId` / 三个 `*ScratchId` 字段，测试改为断言「同一次解析内 `ByteScratch` 实例数不增长」（用 `BufferReuse_test` 已有的计数方式）；若必须保留，用 `AtomicInt64.fetchAdd(1)`（`std.sync`）或在 `synchronized` 里自增，并在字段注释写明「仅测试观测，允许跳号」。

### [一般][存量] #7 实体展开上限按「码点数」记账，`EntityLimits` 文档与异常文案按 KB/MB，实际内存与溢出文件按 UTF-8 字节

- **位置**：`f_xml/src/ExpandSink.cj:150-152`（`length = runesOf(segment).size`、`nextBytes`）、`:208-209`（`bytes = nextBytes`）、`:283-291`（`kbText` 按 KB/MB 格式化）
- **来源**：存量（工作区快照）
- **判据**：review-checklist §11「契约与实现不符（单位不符）」、§5（上限的实际强度）
- **证据**：静态确定 —— `bytes` 累加的是 `runesOf(...).size`（码点数）；同类里的 `retainedBytes()` 返回 `this.memory.size`，而 `StringGenerator.size = utf8.size`（字节，`f_base/src/StringGenerator.cj:30-34`），溢出落盘写的是 `memory.unsafeBytes()`（UTF-8 字节，`ExpandSink.cj:227`）；`EntityLimits` 文档写「默认值：单实体 64 KB、总量 8 MB」（`XmlOptions.cj:79`），异常文案经 `kbText()` 输出「64 KB」
- **描述**：同一份配置在不同字符集下含义不一致：纯 ASCII 时 1 码点 = 1 字节，CJK/emoji 时 1 码点 = 3–4 字节。默认 `maxExpandedPerEntity = 64 KB` 对中文内容实际允许约 192 KB 内存/落盘，`maxExpandedHardLimit = 2 GB` 最坏对应约 8 GB 字节——上限比文档承诺宽松 3–4 倍，安全余量被静默吃掉。顺带 `size()` 返回码点数、`retainedBytes()` 返回字节数，同一族接口单位也不统一（与 #15 同一根因）。
- **建议**：计量改成 UTF-8 字节（`segment.size`，与 `StringGenerator` 同口径），或把字段/文案统一改成「字符数」并同步 `EntityLimits` 注释与 `kbText`；两者不要混用。改动会同时影响 `#1` 的阈值语义，建议一起做。

### [一般][存量] #8 未声明实体的告警列表无上限，随输入线性累积

- **位置**：`f_xml/src/ParserEngine.cj:99`（`warningList = ArrayList<String>()`）、`:63`（`EntityRefPolicy.undeclared` 逐条 `add`）、`:125-127`（`warnings()` 每次 `toArray()` 整表复制）
- **来源**：存量（工作区快照）
- **判据**：review-checklist §5「无界容器：全局集合只增不减」
- **证据**：静态确定 —— `ArrayList<String>` 没有任何条数/字节上限；`undeclared()` 每命中一次未声明引用就压一条含行列号的文案。量化：`<!DOCTYPE r SYSTEM "x"><r>&a;&a;…</r>`，输入 4 字节/引用即产出 1 条约 40–60 汉字的 `String`（≈120–180 字节 + 对象头），10 MB 输入可累积数百 MB；`warnings()` 每次调用再复制一份
- **描述**：`standalone != yes` 且有外部子集（或内部子集出现参数实体引用）时走「跳过并告警」（`EntityRefPolicy.configure`，`:44-53`），攻击者用大量未声明引用即可把「告警」变成内存放大器；解析结束后该列表仍被 `XmlPullParser` 持有
- **建议**：加条数上限（例如 1024 条后只累加计数，`warnings()` 末尾补一条「另有 N 条」），或把告警改成可选回调 `(String) -> Unit` 由调用方决定是否留存；`warnings()` 可返回惰性视图或直接返回内部快照的副本计数

### [一般][存量] #9 `LineWindow.fillOnce` 在「部分填充 + 解码错误」时丢弃 `BlockFill.error`

- **位置**：`f_xml/src/LineWindow.cj:113-118`
- **来源**：存量（工作区快照）
- **判据**：review-checklist §11「错误处理缺失 / 静默」、§12.1（异步语义：错误被吞）
- **证据**：静态确定 —— `if (fill.count == 0) { this.eof = true; if (fill.error.isSome()) { this.pendingError = fill.error } }`，`count > 0` 且 `error.isSome()` 时 error 直接丢失。`BlockFill` 的契约明确允许这种组合：`RuneSource.cj:50-58`「`count` 个有效码点；`error` 非 `None` 表示**这 `count` 个之后**就是坏字节」，产生点 `RuneSource.cj:152` 与 `:473`
- **描述**：内置 UTF-8 源在 Strict 模式下不消费坏字节（`RuneSource.cj:487-492`），下一次填充会重现同一错误，因此实际表现是「延后一次填充」，可自愈；但 `BufferedRuneSource` 是 **public** 扩展点，第三方子类或字符集源若在抛异常前推进了读位置，这条错误就永久丢失，文档会被当作正常 EOF 解析完（静默截断）。证据等级：丢弃行为静态确定；「是否必然重现」取决于具体源，待确认
- **建议**：把 error 记录与 count 解耦——`if (fill.error.isSome()) { this.pendingError = fill.error }`，EOF 判定单独用 `fill.count == 0 && fill.error.isNone()`；补一条用例：自造一个「先产 2 个码点再抛错且推进位置」的 `BufferedRuneSource` 子类，断言仍抛错

### [轻微][存量] #10 DOCTYPE 名字丢掉前缀：`<!DOCTYPE p:root>` 的 `DocType` 事件只报 `root`

- **位置**：`f_xml/src/Lexer.cj:953`（`readName()` 已切出 `prefix`/`local`）、`:994`（`Token.TDoctype(name.local, …)` 只传 local）；消费侧 `f_xml/src/ParserEngine.cj:272`、`XmlEvent.cj:30`
- **来源**：存量（工作区快照）
- **判据**：review-checklist §11「语义与命名不符 / 信息丢失」；XML 1.0 §2.8 `doctypedecl ::= '<!DOCTYPE' S Name …`（Name 可带冒号）
- **证据**：静态确定 —— 元素名走 `RawName` 全量（`QName` 保留 `prefix`），DOCTYPE 名只取 `name.local`；`Token.TDoctype` 的第一个字段类型是 `String`，没有存前缀的位置
- **描述**：`<!DOCTYPE p:root […]><p:root/>` 解析成功，`onDocType` 收到的 name 是 `root`，与根元素 `QName("root", prefix=Some("p"))` 对不上；依赖「doctype 名 == 根元素名」做校验/分派的调用方会误判（本模块自己不做该校验，所以只在事件消费者侧可见）。文档里也没有「DocType 名只给 local」的说明。
- **建议**：把 `Token.TDoctype` 与 `XmlEvent.DocType` 的名字字段改成 `QName`（破坏性变更，需同步 README 与 `XmlEventHandler.onDocType`），或至少在当前 `String` 里写 `rawNameText(name)` 并补一行注释说明「原样字面名」。用例：`<!DOCTYPE p:root><p:root/>` 断言事件里拿到 `p:root`。

### [轻微][存量] #11 死代码一组：只写不读的字段/上限、零调用的 public 包装、不可达分支、恒等 `match`

- **位置**（同一条根因「重构后未清理」，合并列出）：
  1. `f_xml/src/ParserEngine.cj:88` `private var sawRoot`：只在 `:335` / `:345` 被赋值，全仓无读取（`grep sawRoot` 仅这三处）；真正的状态推进靠 `this.state`。
  2. `f_xml/src/Lexer.cj:167` `var maxAttributeValueLength`：`ParserEngine.cj:105` 写入后从不读取；长度校验实际在 `ParserEngine.cj:315` 用 `options.maxAttributeValueLength`（全仓只有这一处赋值、零读取）。
  3. `f_xml/src/Lexer.cj:138` + `:171` `let limits: EntityLimits`：同样只赋值不读——解析器级上限全在 `EntityExpander`/`ExpandSink` 里判，`Lexer` 自己一个都没用。
  4. `f_xml/src/Lexer.cj:235-251` `public func peek(offset): ?Rune` / `public func advance(): ?Rune`：`Lexer` 是 `internal class`，这两个 `public` 成员全项目零调用（非测试侧只命中 `DoctypeParser` 自己的 `peek` 与 `LineWindow`/`RuneSource`；测试侧只作用在 `LineWindow`/`RuneSource` 实例上）⇒ 按硬原则二判死代码。
  5. `f_xml/src/ExpandSink.cj:309` `ExpandReader.next()` 及其实现（`:330`、`:362`）：全仓零调用（`SinkFeed.fillTo` 只用 `nextCp()`），`Spill_test.cj:170` 甚至断言 `nextCalls == 0` —— 被测试证明用不到的接口方法。
  6. `f_xml/src/Lexer.cj:732` 的 `cp == 0x0D` 与 `:134-135` 掩码里的 `0x0D`：`LineWindow.fillOnce`（`LineWindow.cj:102-109`）已把 CR 全部归一成 LF，属性值展开路径（`EntityExpander.cj:300-307`）也把 `\r` 换成空格，该分支不可达。
  7. `f_xml/src/Lexer.cj:1161-1205` `internal class StringFeed`：全类零构造点（`grep StringFeed` 只命中定义处），实际接回词法流的是 `SinkFeed`。
  8. `f_xml/src/Lexer.cj:513` `case RefValue.EntityName(_) => ()`：`referenceIsInline()`（`:318-335`）只可能对 `&#` 与五个预定义名返回 `true`，`readReference` 对这些只会返回 `CharText`，该分支不可达（且若真走到，会**静默丢字符**）。
  9. `f_xml/src/ParserEngine.cj:222-227` `emitMisc`：三个 `match` 分支体完全相同（都 `Some(event)`），整个函数等价于恒等映射。
- **来源**：存量（工作区快照）
- **判据**：review-checklist §1「不可达语句 / 恒真恒假分支 / 读了不用 / 兼容残留 / 无调用者」、§1 硬原则二
- **证据**：静态确定 —— 逐项给出全仓搜索结果（见上）；`private` 字段按「全仓无引用」判，`internal` 类的 `public` 成员按「全项目无使用」判，`internal` 接口方法按「本包及子包无调用」判
- **描述**：`sawRoot` 与 `Lexer` 的两个上限字段让读者以为存在「根元素已出现」「词法层会拦超长属性」两个保护，实际都没有；`StringFeed`（44 行）与 `Lexer.peek/advance` 是旧接口残留，会让后续维护者以为存在「带 Option 的词法入口」。单看每一处都不影响行为，合起来是明确的维护成本与误导。
- **建议**：删 1/2/3/4/5/7/9；6/8 删分支并把掩码注释里的 `0x0D` 说明成「CR 已被行窗归一，这里只是防御」；若保留 `Lexer.peek/advance` 供测试用，改为 `internal` 并在用例里显式构造。

### [轻微][存量] #12 重复逻辑五组：引号字面量读取 ×3、转义两函数 ×2、命名空间名解析 ×2、命名空间查表 ×2、`String→Int32` 转换 ×2

- **位置**：
  1. `f_xml/src/Lexer.cj:861-886`（`readDeclarationValue`）与 `:997-1019`（`readQuoted`）：逐行同构（跳引号 → 循环累积 → 遇引号结束 → `toString()`），差异只有错误文案与「未闭合」判定的位置；`readAttributeValue`（`:677-744`）是同一模式的超集（多了异常处理、空白归一、实体展开），三份实现各自演进——`readAttributeValue` 校验 `isXmlChar`，另两处不校验，严格度已经分叉。
  2. `f_xml/src/Escaper.cj:25-41`（`escapeText`）与 `:43-60`（`escapeAttribute`）：同构的「逐 rune 校验 `isXmlChar` + `match` 转义」，差异只有 `"` 一条转义与错误文案里的「元素/属性」。
  3. `f_xml/src/ParserEngine.cj:428-446`（`resolveElementName`）与 `:448-462`（`resolveAttributeName`）：同构的「prefix 三分支」，差异只有 `elementNamespace` / `attributeNamespace` 与无前缀分支（元素走默认命名空间）。
  4. `f_xml/src/NamespaceScope.cj:73-91`（`lookup`）与 `:93-105`（`lookupDefault`）：同为「栈顶向后扫 + `?String` uri 映射成 `Declared/Reset` + 扫完 `Missing`」，唯一差别是匹配条件（`Some(p) == prefix` vs `prefix.isNone()`）。
  5. `f_xml/src/Lexer.cj:1167-1175`（`StringFeed.init` 里 `cpsOf` → 逐元素 `Int32` 再拷进第二个数组）与 `f_xml/src/XmlChars.cj:173` `cps32Of`：同一件事的两种写法，`StringFeed` 用的是更慢的那份（该类已判死代码，随 #11-7 删除即消失）。
- **来源**：存量（工作区快照）
- **判据**：review-checklist §2「只改类型名 / 字面量复制 / 近似重复」
- **证据**：静态确定 —— 逐行比对函数体；差异点已在上文点名（错误文案、`"` 转义、默认命名空间、`?String` 入参）
- **描述**：这五组都不是「业务要求两份」，而是复制后各自演化：`resolveElementName`/`resolveAttributeName` 的错误文案已经出现「元素/属性」两套（`:437-438` vs `:457-458`），改一处忘另一处的概率很高；引号读取三份的严格度已经开始分叉。
- **建议**：1 抽 `readQuotedRaw(quoteCp, what: String)`（`what` 只用于错误文案），三处共用；2 抽 `escapeRunes(text, mode: Text|Attribute, name)`，差异参数化为「额外转义字符表 + 文案里的名词」；3 抽 `resolveName(raw, useDefaultNs: Bool)`；4 合并为 `lookup(prefix: ?String)`，两个语义入口留薄包装；5 随死代码删除。前四组都要附等价性用例（现有 `ParserError_test` / `NamespaceScope_test` 已覆盖大部分错误文案，改完应全绿）。

### [轻微][存量] #13 `distinct` 相关的两处失真：`NameTable.cj:82` 的注释与实现矛盾，`Lexer_test.cj:172` 的断言复制了上一条

- **位置**：`f_xml/src/NameTable.cj:82`（注释「表内不同名字数即 `insertions`，不另设计数」）对照 `:65-70`（`prop distinct` 返回 `this.texts.size`）；`f_xml/src/Lexer_test.cj:170-172`（第二条 `assertTrue(lexer.names.insertions == 3, "distinct 应为 3，实际 ${lexer.names.insertions}")`）
- **来源**：存量（工作区快照；第 3/7 部分把注释矛盾列为「范围外提示」转给本部分）
- **判据**：review-checklist §11「注释与实现不符」、§10（测试有效性）
- **证据**：静态确定 —— 注释说不另设计数，实际有一个独立 prop；测试里名为 `distinct` 的断言把被测表达式写成了 `insertions`，于是 `distinct` 在该用例中根本没被校验（`NameTable_test.cj:66/83/169` 另有覆盖，所以不是完全没测）
- **描述**：注释会让下一个人以为 `insertions == distinct` 是恒等式（当前实现确实恒等，但那是实现巧合，`distinct` 的语义是「表内条目数」）；`Lexer_test` 的重复断言等于白写一条，`insertions` 被断言了两次。
- **建议**：注释改成「`insertions` 与 `distinct` 目前同值，前者是累计插入次数、后者是表内条目数」；`Lexer_test.cj:172` 改成 `lexer.names.distinct == 3`。

### [轻微][存量] #14 `handleText` 报错行列号取自 token **之后**的位置，前导区/尾部区裸文本的错误列号偏后

- **位置**：`f_xml/src/ParserEngine.cj:210-217`（`throw XmlException(message, this.lexer.position().line, this.lexer.position().column)`）
- **来源**：存量（工作区快照）
- **判据**：review-checklist §11「语义与注释不符 / 诊断信息错误」
- **证据**：静态确定 —— `position()`（`Lexer.cj:254-259`）报的是「下一个待读字符」，而 `TText` 已在 `nextContentToken`/`nextMarkupToken` 里被整段消费完；`Token.TText` 结构里没有位置字段，无法回溯起点
- **描述**：`hello<a/>` 报「根元素之前不允许出现文本」时列号是 6 而不是 1；文本越长偏得越多（`<a/>` 后的尾部文本同理）。错误消息本身正确，但定位会指向文本末尾，自动化工具按行列号回查源码时会指错位置。
- **建议**：给 `Token.TText` 加 `(String, Int64, Int64)` 三元（`nextContentToken` / `nextMarkupToken` 入口已有 `this.position()` 可取），`handleText` 用 token 自带位置；顺带让 `XmlEvent.Text` 的消费方也能拿到源位置（非必须）。

### [轻微][存量] #15 溢出落点的内存指标不能证明「已释放」：`retainedBytes()` 在溢出后直接返回 0，但底层缓冲容量仍在

- **位置**：`f_xml/src/ExpandSink.cj:128-134`（`if (this.isSpilled()) { 0 } else { this.memory.size }`）、`:229`（`this.memory.clear()`）；`f_base/src/StringGenerator.cj:133-136`（`clear()` 只 `utf8.clear()`）
- **来源**：存量（工作区快照）
- **判据**：review-checklist §5「拒绝路径是否真的成立」、§7「`clear()` 只清元素不还物理内存」
- **证据**：静态确定 —— `retainedBytes` 的返回值由 `file.isSome()` 决定，与 `memory` 的实际容量无关；`ArrayList.clear()` 不缩容，`unsafeBytes()` 返回的仍是同一块底层数组。另一个口径问题：`retainedBytes()` 返回字节数、`size()`（`:136-138`）返回码点数，同名族接口单位不一致（与 #7 同源）
- **描述**：`Spill_test.cj:48` / 设计文档 `implement-f-xml-m1/design.md:518/564` 用「`retainedBytes` 恒定 / 为 0」来证明「内存不随展开量增长」。结论方向没错（容量被软阈值限住），但指标口径是"逻辑长度"而非"物理驻留"，用它做断言会让真正的问题（缓冲不缩容、峰值容量常驻）永远测不出来。
- **建议**：`retainedBytes` 改名为 `pendingBytes`（语义是"尚未落盘的字符数"），另加一个测物理容量的观测点（`memory.unsafeBytes().size`）；文档把「retainedBytes == 0」的结论改成「驻留 ≤ maxExpandedPerEntity」，并在 `ExpandSink` 类注释里写明「clear 不缩容」。

### [轻微][存量] #16 `EntitySecurity_test.xxeRejected` 用工作目录固定文件名，测试间互相覆盖且不清理旧文件

- **位置**：`f_xml/src/EntitySecurity_test.cj:103-121`（`env.getWorkingDirectory().join(".f_xml_xxe_probe.txt")`，`File(..., OpenMode.Write)` 直接覆盖，`finally` 里才删）
- **来源**：存量（工作区快照）
- **判据**：review-checklist §11「资源不对称 / 测试隔离」
- **证据**：静态确定 —— 文件名是常量、位置是进程工作目录；同机并行跑两份测试（或上一次异常退出留下残留）时，`:116` 的 `@Assert(n == 10)` 会失败或读到别人的内容
- **描述**：这是安全用例（XXE 不得读文件），却自身依赖一个可被外部影响的路径；若工作目录不可写，`File(...)` 直接抛异常，测试以"环境问题"失败而不是断言失败，容易被误判成 XXE 回归。
- **建议**：改用 `Directory.createTemp()` 下的随机路径（或 `File.createTemp(dir)`），写入后 `flush`/`close` 再断言；断言内容用「文件内容未被拼进解析结果」而不是仅凭字节数。

### [轻微][存量] #17 实体声明数超限的异常不带行列号（同文件其他 DTD 错误都带）

- **位置**：`f_xml/src/EntityTable.cj:48-55`（`throw XmlException("实体声明数超过上限 …", 0, 0, kind: Declarations)`）；调用方 `f_xml/src/DoctypeParser.cj:499`（`this.table.declare(...)`，外面没有 `catch` 补位置），对照同文件 `:170-172` 的 `error()` 会按 `positionAt(this.pos)` 补行列号
- **来源**：存量（工作区快照）
- **判据**：review-checklist §11「错误处理不一致 / 诊断信息缺失」；`XmlException.cj:25` 与 README 的错误契约隐含「解析错误带位置」
- **证据**：静态确定 —— `declare` 传的是字面量 `0, 0`；`DoctypeParser.parse`（`:134-139`）与 `parseStatements` 全文无 `catch`，因此这条异常一路冒到调用方时 line/column 仍是 0
- **描述**：第 1025 条 `<!ENTITY …>` 报「实体声明数超过上限 1024」却不指位置，用户无法定位是哪个 DOCTYPE 子集触发的（多文档拼接场景尤其明显）；`EntityLimits_test.cj:58` 只断言了 `entityLimitKind`，正好放过了位置缺失。分类为 `Declarations` 的这条错误是六个 `EntityLimitKind` 里唯一不带位置的一档。
- **建议**：`EntityTable` 不持位置上下文，最小改动是在 `DoctypeParser` 调 `declare` 处 `try/catch (e: XmlException)`，当 `e.line == 0` 时用带位置的 `XmlException` 重新抛出（保留 `kind`）；或在用例层直接断言 `error.line > 0` 逼出这条缺口。

### [轻微][存量] #18 `ParserEngine` 字段初始化被 `init` 全覆盖（死初始化 + 字面量 `1024` 复制）

- **位置**：`f_xml/src/ParserEngine.cj:95-99` 对比 `:106-112`
- **来源**：存量（工作区快照）
- **判据**：review-checklist §1「读了不用（赋值后即被覆盖）」+ §2「字面量复制」
- **证据**：静态确定 —— `entityTable = EntityTable(1024)`、`expander = EntityExpander(EntityTable(1024), EntityLimits(), EntityCounter())` 在构造时先创建 2 个 `EntityTable` + `EntityLimits` + `EntityExpander` + `EntityCounter`，随后 `init` 用 `options.entityLimits` / `this.counter` 全部重建，前一组对象立刻不可达；`1024` 同时出现在 `:95`、`:98`、`:106` 三处（与 `EntityLimits.maxDeclarations` 的默认值重复）
- **描述**：每次 `new XmlPullParser` 多分配 5 个对象（其中 2 个带 `HashMap`），纯浪费；三处 `1024` 也与「上限来自 `EntityLimits`」的单一事实源冲突，改默认值时容易漏改
- **建议**：字段改为无初始化的 `private var entityTable: EntityTable`（在 `init` 里一次性构造），`1024` 统一取 `options.entityLimits.maxDeclarations`

### [轻微][存量] #19 测试：`InvalidByteMode_test.concat` 未被使用

- **位置**：`f_xml/src/InvalidByteMode_test.cj:28-36`
- **来源**：存量（工作区快照）
- **判据**：review-checklist §1「无调用者（`private` 函数，文件内零调用）」
- **证据**：静态确定 —— `grep concat` 在本文件只有定义处命中，其余用例都直接用字面量 `Array<Byte>`
- **建议**：删除，或把现有 `[0x61, 0xFF, 0x62]` 之类的构造改用它（顺带统一素材写法）

### [轻微][存量] #20 性能门禁用例在开关关闭 / 环境不合格时直接 `return`，等价于「通过」

- **位置**：`f_xml/src/PerfFifty_test.cj:31-39`、`f_xml/src/PerfTen_test.cj:31-38`
- **来源**：存量（工作区快照）
- **判据**：review-checklist §3「开关打开后走进空分支 / 静默走过场」、§14「测试有效性」
- **证据**：静态确定 —— `if (!perfGateEnabled()) { println("gate: disabled …"); return }`，`gateEnvironmentOk()` 失败同样 `return`；`cjpm test` 默认环境下这两条用例恒绿，`Gate M`（50 MB VmHWM < 262144 kB）与 `Gate T`（10 MB min < 1000 ms）在 CI 里没有任何保护作用
- **描述**：这是「未测量即通过」——与 `PerfFifty_test.cj:61` 自己写的「未测量即通过是不可接受的」自相矛盾（那里只针对 `/proc` 不可用，而更常见的「没设环境变量」反而静默通过）
- **建议**：改用显式跳过语义（`@Ignore` 或输出可被 CI 统计的 SKIP 标记），并把「未测量」与「通过」在报告里分开

## 优化可行性方案

> 以下均无改前/改后对照数据，`证据状态` 一律为「无基线（待验证）」，**不进 `todo.md` / `tasks.md`**。

### [堆内存] 实体文本被复制成 `Array<Int32>` 再读回

- **现状**：`EntityExpander.feed` 返回 `MemoryExpandReader(cps32Of(value))`（`EntityExpander.cj:114`，`cps32Of` 见 `XmlChars.cj:173`），实体替换文本的 `String`（UTF-8，N 字节）与其 `Array<Int32>`（4N 字节）同时存活；`SinkFeed`（`EntityExpander.cj:394-465`）又用 256 码点小块二次搬运。一次深度 16、总量 8 MB 的展开会依次产生多个这样的临时帧
- **方案**：让 `MemoryExpandReader` 直接持有 `String` 并按需游标迭代（或按块惰性解码），不预转 `Int32` 数组
- **预期**：单帧峰值从「约 5N」降到「约 N + 256×4」；按 8 MB 展开量、单帧 64 KB 估算，少分配约 8 MB 瞬时临时对象（量级估计，非实测）
- **代价**：逐码点取 rune 比数组下标略慢（需实测）；`RuneFeed.peekCp(offset)` 需支持跨 rune 前瞻（`referenceIsInline` 最大 5）
- **验证**：`cjpm bench -O2` 跑 10 万次 `&e;` 展开（e 为 64 KB 中文实体），对照 `getAllocatedHeapSize()` 与耗时中位数；`VmHWM` 对照
- **证据状态**：无基线（待验证，不进 tasks）

### [CPU] `ExpandSink.write` 用 `runesOf(segment).size` 只为了数字符，每次写都分配一个 rune 数组

- **现状**：`ExpandSink.cj:150` 每次 `write` 都 `runesOf(segment)`（`XmlChars.cj:155` 返回 `Array<Rune>`）取长度，随后数组立即丢弃；写路径在实体展开与属性展开的主路径上，按段调用。
- **方案**：改成 `var n = 0; for (_ in segment.runes()) { n++ }`（`runes().count()` 同义），或若"字节"语义可接受就直接用 `segment.size`（需同步修正 `kbText`、`EntityLimits` 注释与 #7 的单位）
- **预期**：每次写省一次 O(len) 分配；按 8 MB 展开量、64 KB 分段计 ≈ 128 次分配、约 8 MB 临时对象（量级估计）
- **代价**：极低；改用 `segment.size` 会改变计数语义（当前按码点计）
- **验证**：`cjpm bench -O2` 对照 `feed`/`write` 路径耗时；`getAllocatedHeapSize()`
- **证据状态**：无基线（待验证，不进 tasks）

### [CPU] `Lexer.peekCalls++` 是测试专用计数器，却放在最热的 `peekCp` 里逐次自增

- **现状**：`Lexer.cj:192-193` 每次 `peekCp` 都写一次实例字段；`peekCp` 是词法层所有扫描的原子操作（`startsWithCp` 每个字符一次、`readName` 每字符一次）。该计数只在 `TextScan_test.cj:47` 与 `SemanticPerf_test.cj:89` 被读取（打印"批量扫描的结构性证据"）。
- **方案**：删掉计数器，改为在测试里用 `@When[...]` 条件编译的字段，或用 `LineWindow` 的 `cpAt` 调用次数间接推断；最省事的是把 `peekCalls` 从 `peekCp` 挪到非热路径并同步改测试口径
- **预期**：热路径每次 peek 少一次非必要的内存写（是否可测得出需 profile）
- **代价**：测试要改断言口径；`SemanticPerf_test` 打印行会变
- **验证**：`cjprof record` 对照 `Lexer.peekCp` 自耗时占比；`cjpm bench -O2` 跑 50 MB 合成流
- **证据状态**：无基线（待验证，不进 tasks）

### [CPU] `Lexer.startsWith(String)` 每次调用都 `cpsOf` 新建 `Int64` 数组

- **现状**：`Lexer.cj:301-303`；唯一调用方 `SkipScanner`（`SkipScanner.cj:56` / `:58` / `:110`），其中 `:110` 的 `skipUntil` 是**逐字符**判定 —— 跳过一个 N 字节的注释 / CDATA / PI 会做 N 次 `cpsOf(terminator)` 分配（`startsWith` 每次新建 `Array<Int64>`）。代码注释自己也写了「只给 `SkipScanner` 这类非热路径用」，但 `SkipScanner` 的用途恰恰是大文档跳读，`skipElement` 是公开 API（`XmlPullParser`）。
- **方案**：把 `SkipScanner` 用到的三个终止符（`-->`、`]]>`、`?>`）提成 `Lexer` 的 `static let` 码点常量（与 `kCommentClose` 等同款），`SkipScanner` 改用 `startsWithCp`
- **预期**：被跳过的每个字符少一次 `Array<Int64>` 分配（3–9 元素）+ 一次 `runes()` 迭代；一份 10 MB 的 CDATA 被 `skipElement` 跳过时分数量级下降
- **代价**：需在 `SkipScanner` 增加 3 个常量引用，`startsWith(String)` 可降为测试专用
- **验证**：`cjpm bench -O2` 跑「10 万元素 + skipElement」场景；`getAllocatedHeapSize()`
- **证据状态**：无基线（待验证，不进 tasks）

## 待验证假设

> 无性能测试数据支撑，只是下一轮补数据的清单；不进 `todo.md` / `tasks.md`。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 属性重复检测的平方项在真实负载里可忽略（合成基准每标签 2 个属性，测不到） | `ParserEngine.cj:304-324` | n=10/1k/10k/50k 属性时的单标签耗时曲线 | `cjpm bench -O2` 构造单标签 n 属性文档，记录耗时并与 `n²/2` 拟合 |
| 2 | `peekCalls++` 的自耗时占比低于 5%（若成立则不必改） | `Lexer.cj:192-193` | `Lexer.peekCp` 自耗时占比 | `cjprof record` 跑 50 MB 合成流（`F_XML_PERF=1` 同参数），看 self time |
| 3 | `runesOf` 在 `ExpandSink.write` 里的分配占实体展开路径的 10% 以上 | `ExpandSink.cj:150` | 该路径分配量/次数 | 打开分配统计跑 `Spill_test` 同输入；对照改 `segment.size` 的耗时 |
| 4 | `LineWindow.skipRun` 对含换行的长 run 要做两遍扫描，在长文本流上占比可观 | `LineWindow.cj:261-294` | 含/不含换行两种输入的吞吐差 | 合成 50 MB 纯文本（每 80 字符一个 `\n`）对比单遍实现 |
| 5 | 把 `textScratch` / `valueScratch` 的峰值容量在解析结束后释放，可降长文档的 RSS 尾部 | `Lexer.cj:141-145` + `StringGenerator.clear` | 单份大文本后的常驻容量与 RSS 差 | 解析「1 个 10 MB 文本节点 + 少量元素」的文档，前后读 `getUsedHeapSize()` / RSS |
| 6 | local mode 对 `readInternalSubset` / 文本 token 的临时 `StringGenerator` 有峰值收益 | `Lexer.cj:484-537`、`:1022-1087` | 改前/改后峰值内存（`--experimental --enable-local-mode`） | 同输入（10 MB 单文本节点）对照 `getAllocatedLocalObjectSize()` 与 RSS；先确认无逃逸 |
| 7 | 告警列表在 `standalone=no` 场景下的累积会显著抬高 RSS | `ParserEngine.cj:99`/`:63` | 10 万未声明引用下的 RSS 增量 | 构造 `<!DOCTYPE r SYSTEM "x">` + 10 万 `&a;`，采样 `heapUsed` 与告警条数 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_xml/src/EntitySecurity_test.cj` | .cj | ✅ | XXE/炸弹/深度/超长属性 8 条用例；#16 固定临时文件名 |
| 2 | `f_xml/src/EntityTable.cj` | .cj | ✅ | 与 `EntityExpander`/`DoctypeParser` 契约一致；见 #17（`Declarations` 异常不带位置） |
| 3 | `f_xml/src/Escaper.cj` | .cj | ✅ | 见 #4（LF/TAB 漏转义）、#12-2（与 `escapeText` 重复）；`]]>` 拆分的边界逐例复核无误 |
| 4 | `f_xml/src/ExpandSink.cj` | .cj | ✅ | 见 #7（单位）、#11-5（`ExpandReader.next`）、#15（`retainedBytes` 口径）；`spill()` 生产不可达已由第 4/7 部分覆盖，本部分不重复计 |
| 5 | `f_xml/src/FormatSamples_test.cj` | .cj | ✅ | RSS/Atom/SVG/SOAP/POM/OOXML 6 样本 + 5 组组合；断言与实现一致 |
| 6 | `f_xml/src/InvalidByteMode_test.cj` | .cj | ✅ | Strict/Replace 与块边界 13 条；见 #19（`concat` 未使用） |
| 7 | `f_xml/src/Lexer.cj` | .cj | ✅ | 见 #1、#6、#10、#11-2/3/4/6/7/8、#12、#14 |
| 8 | `f_xml/src/Lexer_test.cj` | .cj | ✅ | 见 #13（`distinct` 断言写错）；其余为 token/驻留结构断言 |
| 9 | `f_xml/src/LineWindow.cj` | .cj | ✅ | 见 #5（`peek` 上限 8）、#9（`fillOnce` 丢错）；CR/LF 归一与行列号推进核对无误 |
| 10 | `f_xml/src/LineWindow_test.cj` | .cj | ✅ | 14 条（含块视图失效规则、坏字节延迟抛出）；未发现问题 |
| 11 | `f_xml/src/NameTable.cj` | .cj | ✅ | 见 #13（注释矛盾）；开放寻址 + 半负载上限推导成立，`lookup` 不会死循环 |
| 12 | `f_xml/src/NameTable_test.cj` | .cj | ✅ | 7 条（同 hash 不同名、上限、重建）；未发现问题 |
| 13 | `f_xml/src/NamespaceScope.cj` | .cj | ✅ | 与 `ParserEngine.declareNamespace` 配合正确；见 #12-4（`lookup`/`lookupDefault` 同构）；`pop()` 依赖 `push()` 配对（调用点均成对） |
| 14 | `f_xml/src/NamespaceScope_test.cj` | .cj | ✅ | 13 条命名空间规则；未发现重复 xmlns 用例（对应 #2 的缺失测试） |
| 15 | `f_xml/src/ParserEngine.cj` | .cj | ✅ | 见 #1、#2、#3、#8、#11-1/9、#14、#18 |
| 16 | `f_xml/src/ParserError_test.cj` | .cj | ✅ | 22 条错误路径（含展开名重复、深度、位置）；未发现问题 |
| 17 | `f_xml/src/ParserState_test.cj` | .cj | ✅ | 12 条状态机用例；未发现问题 |
| 18 | `f_xml/src/PerfFifty_test.cj` | .cj | ✅ | 门禁 50 MB / `VmHWM < 256 MB`；见 #20（开关关闭即通过） |
| 19 | `f_xml/src/PerfTen_test.cj` | .cj | ✅ | 门禁 `min(5) < 1000 ms` + `max/min ≤ 1.4` 噪声保护；取 min 属门禁设计选择，未计入缺陷；见 #20 |

合计：`.cj` 19 个 / `.md` 0 个 / 共 19 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 9 | #2（xmlns 不判重）、#4（LF/TAB 不转义）、#5（peek 上限 8 伪装 EOF）、#7（上限单位不符）、#9（`fillOnce` 丢错）、#10（DOCTYPE 前缀丢失）、#14（错误位置偏后）、#15（`retainedBytes` 口径）、#18（死初始化）。安全面单独核过：外部实体只记录不加载（`EntityTable.declare` + `EntityExpander.feed:73` 抛「永不加载」）、外部子集零 I/O（`EntitySecurity_test.externalSubsetNoRequest` 覆盖）、实体炸弹三层上限、`]]>` 与 `<` 的转义/拒绝路径完整——XXE 与炸弹在默认配置下确实被拦住，本部分无安全类缺陷 |
| §1 死代码 | 1 | #11 一条合并 9 处：`sawRoot`、`Lexer.maxAttributeValueLength`、`Lexer.limits`（只写不读）、`Lexer.peek`/`advance`（`internal` 类的 `public` 成员、全项目零调用）、`ExpandReader.next` + 2 实现（零调用，测试断言 `nextCalls==0`）、`0x0D` 分支/掩码项、`StringFeed`（零构造）、`:513` 不可达 case、`emitMisc` 恒等 match。逐个符号做了全仓 `grep`（`private`/`internal` 口径）；对外可达 public 声明（`LineWindow` 全部方法、`RuneSource` 实现）按硬原则一不判 |
| §2 重复逻辑 | 1 | #12 一条列 5 组：`readDeclarationValue`↔`readQuoted`↔`readAttributeValue`、`escapeText`↔`escapeAttribute`、`resolveElementName`↔`resolveAttributeName`、`lookup`↔`lookupDefault`、`StringFeed.init`↔`cps32Of`。另按「同错误消息」跨文件搜过：`"实体「&…;」未声明"` 出现在 `Lexer.cj:1103/1106`、`EntityExpander.cj:68/288`、`ParserEngine.cj:470`，三处语义确有差别（词法层/展开器/状态机各自的兜底），不合并；`LineWindow` 三处行列号推进（`advanceFast`/`advanceFastSlow`/`skipRun`）判为热路径刻意展开（有注释），不合并 |
| §3 空实现 | 1 | #20（门禁用例开关关闭即 `return`，等价空跑）。其余：无 `TODO/FIXME/UnsupportedException` 占位；`SpillDir.createFileFrom` 的 `catch (_: Exception) { continue }` 是「试下一个候选」的有意语义（四级全失败后抛错）；`ExpandSink.close` 的 `catch {}` 只包临时文件删除，不改变解析结果；`EntityRefPolicy.undeclared` 在非严格档写告警而非静默跳过；`MemoryExpandReader.close() {}` 是带注释的 Null Object |
| §4 栈溢出 | 0 | 本部分全部遍历为显式循环：`nextContentToken`/`readInternalSubset`/`readComment`/`readBang`（CDATA 分支）/`NameTable.lookup`/`NamespaceScope.lookup` 无自递归；`ParserEngine` 元素配对用 `stack: ArrayList<QName>`（`:77`）不递归；实体递归不在本部分（`EntityExpander`，16 层硬限，`ParserEngine.cj:475` 传 `lexer.depth()+1`）。`Escaper` 单遍 rune 循环无递归 |
| §5 OOM | 3 | #1（文本/属性/DTD 子集三处全量物化 + 上限后置 + 缓冲不缩容）、#7（上限按码点记账，实际字节可到 4 倍）、#8（告警无上限）。其余无界容器已逐个排除：`Lexer.feeds` 上限 = 实体深度 + 1（`advanceCp` 弹出已耗尽帧）、`NameTable` 65536 条硬停插、`EntityTable` 1024 条硬限、`attrsScratch` 随输入线性且被标签边界回收；`readAll` 全量物化仅测试调用 |
| §6.1 热点瓶颈 | 0 | 未提供本部分的 `cjprof` / 分段计时数据（`Perf_test` 只有端到端总耗时），任何热点结论都不成立；线索全部进「待验证假设」#1–#5 |
| §6.2 大粒度锁 | 0 | 本部分零锁：`Lexer`/`ParserEngine`/`NameTable`/`NamespaceScope`/`ExpandSink` 均为解析实例私有状态，无 `synchronized`、无共享容器 |
| §6.3 并发串行 | 0 | 无 `spawn`、无线程池、无 `Future.get`；本部分全同步单线程推进 |
| §6.4 低效算法 | 1 | #3（属性重复检测 O(n²)，属性条数无上限）。另核过：`NamespaceScope.lookup` 每次 O(深度)（深度受 `maxElementDepth` 4096 限制，未列为缺陷）、`readDeclaration` 的 `seen` 为 O(k²) 但 k ≤ 3、`Lexer` 批量路径逐码点 `append` 属常数因子（进待验证假设 #2 的相邻范围） |
| §7 降堆内存方案 | 2 | 方案 1（实体文本 `Array<Int32>` 副本）、#1 的「缓冲不缩容」与 #15 的指标口径作为缺陷记，不重复计入方案 |
| §8 降 CPU 方案 | 3 | 方案 2（`runesOf` 计数）、方案 3（`peekCalls++`）、方案 4（`startsWith(String)` 的 `cpsOf`）。全部 `无基线` |
| §9 local mode 可行性 | 0 | 本部分有「函数内创建、函数内用完」的大对象候选（`readInternalSubset` 的 `StringGenerator`、`nextContentToken` 的文本缓冲），但（a）`StringGenerator` 由 `f_base` 提供、是否具备 local 构造/mode 重载未核对到签名；（b）`Lexer` 的三条缓冲是**实例字段**（跨函数逃逸），不满足 local 逃逸约束；（c）无改前/改后峰值内存数据。故只写进「待验证假设」#6 |
| §11 现有代码的 BUG（存量） | 20 | 本部分 20 条发现全部为存量（工作区快照无 diff）：逐条核过边界（空集合、空串、`None` 分支）、错误处理（异常类型与位置）、资源（`ExpandSink.close`/`FileExpandReader.close` 双关闭经 `Spill_test.largeExpansionSpills` 路径验证不抛）、并发（#6）。核对后判定不是缺陷的：`readReference` 的数值累加有钳制（`value > 0x10FFFF` 即压到 `0x110000`，不会溢出）；`EntityTable.declare` 的「首个声明生效」符合注释承诺；`Escaper.writeCData` 对以 `]]` 结尾的文本做逐例推演（`"]]"→"<![CDATA[]]]]>"` 读回仍是 `"]]"`），无误 |
| §12 并发安全与锁粒度 | 1 | #6（`Lexer.nextScratchId` 静态自增无同步）。其余路径已证明线程封闭：`ParserEngine`/`Lexer`/`NameTable`/`NamespaceScope`/`EntityCounter` 全是实例字段，两个解析器互不共享（`EntityCounterIsolation_test` 覆盖）；仅 `Lexer.nextScratchId` 与 `ByteScratch.nextId` 是静态可变状态。锁粒度无可谈（无锁） |
| §14 功能完备性与 README 覆盖 | 1 | 本部分无 `.md` 文件，README 对照不在本部分；功能完备性命中：`maxAttributeValueLength` 注入 `Lexer` 但从未读取（接线缺失，计入 #1/#11-2）。反向的「实现有、README 没写」只有 `peek(offset)` 的 8 字符上限（已并入 #5 建议 (c)） |
| 文件覆盖（§13 等） | 19/19 | 无缺失；本部分无 `.md`，文档一致性归第 1–3 部分 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 1 |
| 一般 | 8 |
| 轻微 | 11 |
| 优化方案（堆内存 / CPU） | 1 / 3 |

## 总评

本部分（词法层 + 状态机 + 名字驻留 + 命名空间 + 实体表 + 转义）是整个模块质量最高的部分：解析器用显式名称栈而非递归、实体递归有三层上限、XXE 与外部子集在代码层面就是「永不加载 / 零 I/O」、`readName` 的驻留与批量扫描都有结构性断言兜底，`LineWindow` 的 CR/LF 归一与行列号推进在 4 种块大小下都有对照用例。核心安全目标（不加载外部实体、不炸内存）在默认配置下成立，没有发现可远程触发的解析崩溃。

阻塞项只有一条：**流式内存契约（O(嵌套深度)）在「单段超大文本 / 超大属性 / 超大 DTD 内部子集」上不成立，且属性长度上限在物化之后才检查**——这条与 README 和 spec 的明文承诺直接冲突（spec 原文 `SHALL 仍为 O(嵌套深度)`），也是目前唯一能靠输入把进程推成 OOM 的路径，建议优先修（改动局限在三个累积循环内加长度判定，并复用已注入但未使用的 `Lexer.maxAttributeValueLength`）。

其余可排期：实体上限的「码点 vs 字节」记账（#7，与 #1 同批改最省事）、未声明实体告警无上限（#8）、重复 `xmlns` 声明不判重（#2，规范 WFC 缺口，会导致解析器差异）、属性判重 O(n²)（#3）、属性值 LF/TAB 不转义（#4，往返失真）、`fillOnce` 丢弃部分填充的错误（#9）。死代码与重复逻辑两组属于清理项（#11 九处、#12 五组），`ExpandReader.next`、`StringFeed`、`sawRoot` 这类"看起来有保护其实没有"的残留应尽快删掉，避免后续维护者误判。

存量 20 条（1 严重 + 8 一般 + 11 轻微），是否纳入修复待用户决定；其中 #1 建议单独立项，#2/#4/#7/#8 建议随下一次维护窗口处理，#3/#6 可与已有的 `ByteScratch.nextId` 条目合并。性能类结论全部未成立（无 profile / bench 数据），只保留 7 条待验证假设供下一轮补数据。
