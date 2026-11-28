# f_xml 模块审查报告

- **审查日期**：2026-11-28
- **模块路径**：`f_xml`（106 个文件：72 个 .cj + 34 个 .md）
- **基线**：工作区快照（sts/1.3.x 工作区，master 同提交 120fd2542，无分支差异）
- **审查重点**：见 scope.md（正确性、死代码、重复逻辑、空实现、栈溢出、OOM、热点、并发与锁、存量 BUG、内存/CPU 优化空间、local mode 可行性、README 覆盖）
- **报告版本**：v1（由 7 个分部分报告合并：`parts/f_xml.part1..7.md`）

## 发现

<!-- 第 1 部分 -->

### [严重][存量] #1 实体软阈值溢出（Spill）在解析主路径不可达；单实体上限判的是原文长度而非展开长度

- **位置**：文档侧 `f_xml/README.md:407-409`（「单实体 64 KB / 总量 8 MB（软，可 `Spill` 到临时文件续跑）」）、`README.md:385-386`（「`PerEntity` / `Total` 是软阈值，可改用 `EntityOverflowPolicy.Spill` 重试」）、`doc/f_xml模块设计.md:956-1004`（5.4 / 5.4.1 三层上限表）、`doc/f_xml模块设计.md:1024-1041`（溢出切换逻辑）、`doc/f_xml模块设计.md:1312`（安全表）、`doc/f_xml模块设计.md:1952`（P3.5 验收「20 MB 展开量下 `retainedBytes` 恒定」）；实现侧 `f_xml/src/EntityExpander.cj:77-113`（`82-89` 无条件抛 `PerEntity`、`108-113` 同一条件再次判断）、`f_xml/src/ParserEngine.cj:475`（内容实体唯一入口 `expandEntity → feed`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §3「开关打开后走进空分支 / 功能未接完」、§13「文档承诺与实现相反」、§14.1「承诺了但没实现」
- **证据**：静态确定 ——
  1. 内容位置实体只走 `EntityExpander.feed()`（`ParserEngine.cj:475`）。`feed()` 在 `EntityExpander.cj:82-89` 对 `size > maxExpandedPerEntity` **无条件抛 `EntityLimitKind.PerEntity`**，完全不看 `overflowPolicy`。
  2. `EntityExpander.cj:108-113` 是同一条件 `size > maxExpandedPerEntity` 的第二次判断；执行到此处时该条件必为假 ⇒ **不可达分支**。该分支内部还用了 `ExpandSink(this.limits, EntityCounter())`（新建计数器，不共享文档总量），并写入 `value`（原文，而非展开结果）——三处特征都说明它从未被跑过。
  3. 全仓生产代码中 `ExpandSink(` 只有两个构造点：`EntityExpander.cj:110`（上述不可达分支）与 `EntityExpander.cj:256`（`attribute: true`，属性路径永不溢出）。因此 `ExpandSink.spill()`（`ExpandSink.cj:216-231`）在解析主路径上**一次也不会执行**；`Spill` 的唯一可观测效果是 `EntityExpander.cj:90-98` 里「总量超 8 MB 不抛错」。
  4. 单实体阈值比较的是 `runesOf(value).size`（`EntityExpander.cj:77`，实体**原文**长度），而设计文档 `doc/f_xml模块设计.md:962` 定义为「单个实体**展开后**的最大字符数」。`e5 = "&e4;"×10` 这类原文 30 字符、展开 30 万字符的实体不会触发 `PerEntity`（`EntityLimits_test.degradeRetrySucceeds` 正是靠这一行为通过）。
  5. `Spill_test.cj` 的 8 条用例全部在 `ExpandSink` / `SpillDir` 层（`Spill_test.cj:36-58` 直接 new sink），没有一条从 `XmlParser.parse` 进入；`EntitySecurity_test.cj:26` 还写着「用 `Spill` 跑炸弹会先写满磁盘才停」，与代码实际行为（内容路径从不写盘）相反。
- **描述**：README 与设计文档在 6 处承诺「软阈值可降级到临时文件续跑、对下游透明、内存恒定」，实际行为是：
  - 单个实体原文超过 64 KB ⇒ 即使默认 `Spill` 也抛 `PerEntity`；README 教用户的「降级重试」对这类错误**必然再次失败**（与同页 `README.md:385-386` 自己的分类相反）；
  - 累计展开量超过 8 MB ⇒ 不报错也不溢出，继续在内存里展开到 2 GiB 硬限（DOM 模式下这段文本最终还要整体驻留，等于把 8 MB 的「软保护」实际放宽到 2 GiB）；
  - 「单实体 64 KB」只约束原文，嵌套展开可以远超 64 KB，与设计文档的「展开后」定义不符；
  - `retainedBytes` 恒定的验收只在 `ExpandSink` 单测层面成立，没有端到端证据。
  这是 fail-closed（不会静默产出错误数据），所以没有升级为数据错误；但它是**文档承诺的默认降级路径整体不存在**，属于功能未接完。
- **建议**：`feed()` 按 `overflowPolicy` 分流：`Strict` 保持抛错；`Spill` 时用 `ExpandSink(this.limits, this.counter)`（共享计数器）写入展开结果后 `openReader(bufSize)` 返回——即把 `108-113` 的前提移到 `82` 之前并删除重复判断。单实体阈值改判 `projected`（展开后的大小），消息里同时给出原文与展开量。补一条**解析器级**用例：单实体 > 64 KB + `Spill`，断言 `isSpilled()` 为真、`retainedBytes()==0`、读回内容与内存路径一致。同步修正 README/设计文档的 6 处表述。

### [严重][存量] #2 属性值 1 MiB 上限只在整值物化后校验，扫描期没有增量上限；默认 `Spill` 下单个属性可放大到 2 GiB 内存

- **位置**：文档侧 `f_xml/README.md:410-413`（「属性值不溢出……`maxAttributeValueLength`（默认 1 MiB）防超长属性」）；实现侧 `f_xml/src/Lexer.cj:686-743`（`gen` 全量累积属性值）、`f_xml/src/Lexer.cj:167` + `f_xml/src/ParserEngine.cj:105`（`maxAttributeValueLength` 只赋值、Lexer 内从未读取）、`f_xml/src/ParserEngine.cj:315-320`（唯一的长度校验，发生在 `RawAttribute` 已构造完成之后）、`f_xml/src/ExpandSink.cj:154-174`（属性分支在 `Spill` 下不检查 `maxExpandedTotal`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §5「全量物化 / 按不可信长度累积」、§11「边界校验顺序错误」、§13「安全边界与实现不符」
- **证据**：静态确定 ——
  1. `readAttributeValue()` 从 `Lexer.cj:686` 开始把整个属性值（含每个 `&ent;` 的展开结果）追加进 `valueScratch`，循环里没有任何长度判断；`maxAttributeValueLength` 在 `Lexer.cj` 只出现一次（`167` 行声明），没有任何读取点。
  2. 唯一校验在 `ParserEngine.openElement()` 的 `315-320`，此时 `attribute.value` 已经是完整 `String`；该异常也没有带 `EntityLimitKind.AttributeValue`（该 kind 只由 `ExpandSink` 的单实体展开检查产生）。
  3. 属性路径的实体展开走 `ExpandSink(attribute: true)`（`EntityExpander.cj:256`）：`ExpandSink.cj:154-174` 只检查单实体 `maxExpandedPerEntity`（64 Ki 码点）与 `maxExpandedHardLimit`（2 Gi 码点），**`Spill` 下不检查 8 MB 总量**；每个 `&big;` 各建一个 sink，累计量只体现在共享 `EntityCounter` 上。
  4. `ExpandSink.write()` 每次还 `runesOf(segment)`（`ExpandSink.cj:150`，`XmlChars.cj:155-161` 每次新建 `ArrayList` + `toArray`）复制一份码点数组，峰值再叠一层。
- **描述**：默认选项下，`<!ENTITY big "…64 Ki…">` + 一个含约 3.3 万个 `&big;` 的属性（输入约 200 KB）即可让 `gen` 在内存里增长到接近 2 GiB 才被硬限打断，输入放大约 1 万倍；容器堆通常先于该阈值耗尽，表现为 OOM kill/DoS。README 把 `maxAttributeValueLength`（1 MiB）列为安全边界，但它只是**事后拒绝**，不是内存上界；`Lexer` 侧那个为增量检查准备的字段实际是死配置（§1「读了不用」）。
- **建议**：在 `readAttributeValue()` 的每次 `append` 后比较 `gen.size > this.maxAttributeValueLength` 并立即抛错（消息带属性名与行列号，`kind: AttributeValue`）；删除 `ParserEngine.cj:105` 的无效赋值或真正使用它；属性值路径对 `maxExpandedTotal` 也应生效（属性本来就不支持溢出，没有理由跳过 8 MB 软上限）。补用例：200 KB 输入 + 64 Ki 实体，断言在 1 MiB 处抛 `AttributeValue` 且峰值内存不随引用次数线性增长。

### [一般][存量] #3 实体展开上限在文档里是「64 KB / 8 MB / 2 GB」，实现按**码点**计数，非 ASCII 文档的实际内存上限可达标注值的 2–4 倍

- **位置**：`f_xml/README.md:320-326`（`EntityLimits` 字段注释 `64 KiB` / `8 MiB` / `2 GiB`）、`f_xml/README.md:407-409`、`f_xml/README_en.md:331-340`、`f_xml/README_en.md:421-428`；实现 `f_xml/src/ExpandSink.cj:148-152`、`f_xml/src/EntityExpander.cj:77-107`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「API / 配置 / 默认值与源码不符」、§11「契约与实现不符」；上限口径同时影响 §5（OOM 拒绝路径）
- **证据**：静态确定 —— `ExpandSink.cj:150` 的 `let length = Int64(runesOf(segment).size)` 是**码点数**，`nextBytes` / `nextTotal` 都按码点累加；`EntityExpander.cj:77` 同样用 `runesOf(value).size`。错误消息经 `kbText()`（`ExpandSink.cj:283-291`）渲染成 `KB` / `MB`，README 也照抄成 KB / MB / GB。设计文档自身也不一致：`doc/f_xml模块设计.md:962` 写「最大**字符数**」，`:1434-1435` 又要求「`size` 是字节数，做单块长度上限判断时要用它」，`:971` / `:1004` 则写 2 GB。
- **描述**：ASCII 文档里「码点数 = 字节数」，所以口径看不出问题；含中文 / emoji 的文档里 1 码点 = 2–4 字节，于是：
  1. `maxExpandedPerEntity = 65536` 实际允许 65536 个汉字（≈192 KB UTF-8），不是 64 KB；
  2. `maxExpandedHardLimit = 2^31` 实际允许 21 亿个码点，纯 CJK 文本在 UTF-8 `String` 里可达约 6 GB 堆才触发硬限——README 承诺的「2 GB 上限」在这类输入下不成立；
  3. 错误消息会报「超过 64 KB」，但用户按 64 KB 构造的文档可能根本不触发，排查时口径对不上。
- **建议**：统一单位，二选一——(a) 文档与消息改成「64 K 码点 / 8 M 码点 / 2 G 码点」，并在「安全边界」补一句「上限按 Unicode 码点计，UTF-8 字节数可达 4 倍」；(b) 计数改为 UTF-8 字节（`segment.size` 或 `ByteScratch.size`），保持 KB / MB 语义不变。同时修正设计 §5.4 / §10.2 / §5.4.1 三处口径，并在 `EntityLimits` 字段注释写死单位。注意本条与 #1 是两个独立问题：本条是**单位**， #1 是**判定对象**（原文 vs 展开）。

### [一般][存量] #4 设计文档对 `StringGenerator.unsafeBytes()` 给出相反结论：§10.2 说「零拷贝、零成本」，§15.1 说「会拷贝」

- **位置**：`f_xml/doc/f_xml模块设计.md:1437`（「**`unsafeBytes()` 返回原始内部字节数组，不复制，零成本。**（已确认）」）、`:1458-1466`（「要用就重新取，反正是零成本，没有任何理由去缓存」）、`:2338`（决策 23）、`:2354`（「性能问题已排除」）；同一文档 `:2436-2437`（「`StringGenerator.unsafeBytes()` **会拷贝**，逐字节比对需要零拷贝视图」）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「文档与实现不一致」、§8「缓存 / 预计算的判断依据必须正确」
- **证据**：静态确定 —— `f_base/src/UnsafeData.cj:24-29` 的实现是 `this.getRawArray()[0 .. this.size]`，按 `size` 切片，**每次调用都产生新数组**；`f_xml/src/ByteScratch.cj:26` 的类注释也明确写「`StringGenerator.unsafeBytes()` 返回的是按 `size` 截好的**新数组，每次比对都分配**」。设计 §10.2 / 决策 23 / §14.2 的「零成本」结论不成立，§15.1 才是对的。
- **描述**：§10.2 是设计文档里唯一系统讲「为什么用 `StringGenerator`」的章节，也是后来者判断「能不能在热路径反复取 `unsafeBytes()`」的依据。按它写会把 O(n) 的整段复制当成 O(1)：每次取都复制当前全部字节，在 16 KB 缓冲上就是每 flush 一次复制 16 KB，在 10 MB 文本上就是每取一次复制 10 MB。文档还专门否定了「上次的错误推断」，现在反而是这次修正写错了，误导性更强。§14.3 的验收项（`:2363`）已经预判了这种可能（「若 false 则说明每次做了裁剪拷贝，性能结论要修正」），但结论没回填。
- **建议**：把 §10.2、决策 23、§14.2 的「零拷贝 / 零成本」改为「每次调用按 `size` 复制一份新数组，成本 O(size)；需要零拷贝视图用 `ByteScratch.bytes()`」；删掉「重新取一次是零成本的」，改成「缓存会失效（扩容换数组），但热路径应改用 `ByteScratch` / 只取一次」。§15.1 的表述保留。

### [一般][存量] #5 README「其他公开 API」把 8 个 `internal` 类型成员当成对外 API，同时漏登记三个内置字符源的公开构造

- **位置**：`f_xml/README.md:449-455`（`## 其他公开 API`，`:453` 的模块级清单）、`f_xml/README_en.md:465-471`（`:469`）；被误列的成员：`f_xml/src/Lexer.cj:1118-1130`（`internal interface RuneFeed` 的 `peekCp` / `advanceCp` / `exhausted` / `remaining` / `origin`）、`Lexer.cj:1131-1208`（`internal class WindowFeed` / `StringFeed`）、`f_xml/src/ExpandSink.cj:307-311`（`internal interface ExpandReader` 的 `nextCp` / `next`）、`f_xml/src/EntityExpander.cj:393-464`（`internal class SinkFeed`）、`f_xml/src/PrefixStream.cj:21`（`internal class TextInputStream.read`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「API 与源码不符」、§14.2「公开 API 覆盖」、§1 硬原则二（对外不可达的 `public` 不是 API）
- **证据**：静态确定 —— 清单里的 `advanceCp` / `exhausted` / `next` / `nextCp` / `origin` / `peekCp` / `remaining` / `read` 全部是 **internal 类型**的成员，模块外无法命名、无法调用；反向遗漏：`Utf8RuneSource` / `CharsetRuneSource` / `BlockRuneSource` 是 `public class`，但它们的公开构造 `init(input, mode!, bufSize!)`（`RuneSource.cj:309`）、`init(input, charset!, bufSize!)`（`:345`）在 README 检索不到；`LineWindow` 的 `init` / `peek` / `advance` / `position` / `peekFast` / `advanceFast`（`LineWindow.cj:44,155,180,297,307,317`）也未列。
- **描述**：下游按 README 写 `advanceCp()` 或 `read(...)` 作为模块级函数无法编译；反过来，真正可用的低层入口（`LineWindow`、三个内置字符源）只能读源码猜。`BufferedRuneSource` 虽被列出，但没说明它是 `abstract`、构造函数是 `protected`（只能继承，不能直接 new）。这条清单看起来是「`grep '^public '` 的结果」，没有做对外可达性判断——与本项目「对外可达的 public 才算契约」的口径相反。
- **建议**：把这 8 个 internal 名字移出「其他公开 API」（或单列「内部实现，不保证兼容」）；补三个字符源的 `public init` 签名与一个最小用例（例如 `Utf8RuneSource(File(...))`），并注明 `BufferedRuneSource` 是扩展点。若这些观测器确实需要对外，则先改可见性再登记为 API，并评估契约成本。

### [一般][存量] #6 设计文档称 `cases.json`「随仓库提交」，实际仓库策略是「一律不入库」，照文档找不到文件、harness 直接 fail

- **位置**：`f_xml/doc/f_xml模块设计.md:1806-1812`（「把所有 `<TEST>` 抽成 `cases.json`，随仓库提交」「测试运行时只读这份 JSON」）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「文档过期 / 链接路径失效 / 操作不可复现」、§14「接线缺失」
- **证据**：静态确定 —— `f_xml/tools/xmlconf_gen.py:6-13` 的脚本说明写「缓存目录固定为 `f_xml/.cache/xmlconf/`……**套件与派生 JSON 一律不入库**」；`f_xml/src/XmlconfHarness_test.cj:27-28` 写「只读缓存里的 `cases.json`。套件本体与派生 JSON 不入库，缓存缺失时用例 **fail**（不是 skip），消息固定为「先运行 xmlconf_gen.py」」；`f_xml/tools/` 下只有 `known-issues.json` / `xmlconf_gen.py` / `test_xmlconf_gen.py`，`git ls-files f_xml` 里没有 `cases.json`；同批次 `doc/spec/complete-f-xml-m1-followups/baseline.md:83-84` 的复现基线也是「需先准备缓存：python3 tools/xmlconf_gen.py」。
- **描述**：设计文档是 README 指向的「设计与取舍」主文档（`README.md:7`）。新维护者按 §12.4 在仓库里找 `cases.json` 会找不到；不读脚本说明就不知道要先跑生成器，而 harness 的行为是 **fail 而不是 skip**，`cjpm test` 会直接红。这会让「2038 条断言 / Gate A」这个核心验收数字看起来不可复现。
- **建议**：把 §12.4 改为「`cases.json` / `unsupported.json` 由 `tools/xmlconf_gen.py` 生成到 `.cache/xmlconf/`，**不入库**；首次运行前先执行 `python3 tools/xmlconf_gen.py`」，并补一句「缓存缺失时 `XmlconfHarness_test` 会 fail 并提示」；README 的「状态」段也可加一条链接。

### [轻微][存量] #7 README / README_en 的「状态」段测试数停在 376，当前源码有 396 个 `@TestCase`

- **位置**：`f_xml/README.md:425-426`、`f_xml/README_en.md:440-441`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「文档过期（描述的功能已新增但统计未更新）」
- **证据**：静态确定 —— `grep -c '^\s*@TestCase' f_xml/src/*_test.cj` 合计 **396**；README 的 376 = `optimize-f-xml-semantic-layer` 验证时的 376（`doc/spec/optimize-f-xml-semantic-layer/verification.md:76`，当时 337+39）。此后 `XmlWriterIncremental_test.cj` 带来 14 条、`XmlWriterScratch_test.cj` 带来 6 条，376+14+6=396。README 的「其中……新增 34 条、……新增 39 条」也只列了前两次变更，`reuse-f-xml-writer-scratch` 未提及。
- **描述**：统计数字本身不影响行为，但它出现在「状态」这一节，是使用者判断成熟度的第一入口；漏登记两次变更还会让「哪次改动加了哪些用例」无法从 README 追溯。
- **建议**：更新为 396，并把「XmlWriter 增量接口（14 条）」「XmlWriter 字节暂存复用（6 条）」补进括号内的变更清单；或改成「以 `cjpm test` 输出为准，不在文档硬编码」。

### [轻微][存量] #8 设计文档多处签名 / 成员修饰 / 示例与实现不符，照抄会编译失败

- **位置**：
  - `doc/f_xml模块设计.md:376`（`func peek(offset!: Int64 = 0): ?Rune`）↔ `src/RuneSource.cj:29-52`（5 个方法、`peek(offset: Int64)` 位置参数、无默认值）
  - `doc/f_xml模块设计.md:509-518`（`public let bufSize!: Int64 = 8192` 等字段写成「命名形参」语法，且缺 `maxElementDepth` / `maxAttributeValueLength`）↔ `src/XmlOptions.cj:122-155`
  - `doc/f_xml模块设计.md:789-835`（`public prop name` / `prop children`）↔ `src/XmlNode.cj:148-155`（`public let`，无 setter）
  - `doc/f_xml模块设计.md:1150-1163`（`XmlWriter` 代码块没有 `close()`）↔ `src/XmlWriter.cj:276`
  - `doc/f_xml模块设计.md:1337-1339`（`XmlException <: Exception`、`kind: ?EntityLimitKind`）↔ `src/XmlException.cj:67,92`（`<: BaseException`、`kind!: EntityLimitKind` 必填）
  - `doc/f_xml模块设计.md:1543`（`QName(None, "rss", Some(...))`）↔ `src/QName.cj:52`（`init(local: String, prefix!: ?String, uri!: ?String)`，后两个必须命名传参）
  - `doc/f_xml模块设计.md:271-301, 368-404`（`CharWindow` 三层缓冲）↔ 现实现为 `LineWindow` + `BufferedRuneSource` 按块解码（`:2424-2428` 已记录该重写，但正文未改）
  - `doc/f_xml模块设计.md:357`（「读 charset4cj **v1.0.6** 源码」）↔ `:167` / `f_xml/cjpm.toml:3`（锁定 **1.0.5**）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「API / 参数 / 默认值 / 示例与源码不符」
- **证据**：静态确定 —— 上述每组都是「文档声明 vs 源码声明」的直接对照；`QName(None, "rss", Some(...))` 按 `QName.cj:52` 无法通过编译，`public let bufSize!: Int64` 也不是合法字段声明（`!` 只用于形参）。
- **描述**：该文档被 README 首行标为「设计与取舍见 …」，是外部理解模块的主要入口；`§15 实施回填` 只覆盖了 `XmlEntityRef`、`builder`、两个新上限、`BlockRuneSource`、`BaseException` 五处（`:2372-2381`），上述漂移不在回填表内，读者仍会照抄错误签名。
- **建议**：按实现改正各处签名；或在 §15 回填表补齐，并在 §2.6 / §3 / §4 / §7 / §9 的代码块前加「以 `src/` 为准」的提示；`§2.1~2.5` 明确标注「历史方案，已被字符层重写取代」。

### [轻微][存量] #9 设计文档引用了不存在的测试类 `NameSyntax_test`

- **位置**：`f_xml/doc/f_xml模块设计.md:1629-1630`（「❌ 已自造（`NameSyntax_test.nonAsciiNames`）」「❌ 已自造（`NameSyntax_test.nameMayNotStartWithDigit`）」）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「链接 / 名称失效」
- **证据**：静态确定 —— `f_xml/src/` 下没有 `NameSyntax_test.cj`；两个用例实际在 `f_xml/src/ParserError_test.cj:145`（`nonAsciiNames`）与 `:155`（`nameMayNotStartWithDigit`）。同表 `:1675` 的 `DtdIgnoreSection_test` 也不是文件，而是 `DtdDeclSyntax_test.cj:197` 里的 `@Test` 类名。
- **描述**：覆盖率矩阵用「已自造（某测试）」作为「盲区已关闭」的证据，名字对不上就无法复核；读者会以为有一份专门的名字语法测试文件。
- **建议**：改为 `ParserError_test.nonAsciiNames` / `ParserError_test.nameMayNotStartWithDigit`，`DtdIgnoreSection_test` 标注「`DtdDeclSyntax_test.cj` 内的用例类」。

### [轻微][存量] #10 设计文档 §10.2 表格被 35 行正文截断，末行「前瞻由 `CharWindow` 提供」孤立成普通段落

- **位置**：`f_xml/doc/f_xml模块设计.md:1408-1414`（表格）与 `:1473`（孤立行）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「格式 / 可读性」
- **证据**：静态确定 —— `:1473` 以 `| 前瞻由 \`CharWindow\` 提供 | **不要依赖 Reader 的 peek……** |` 开头，与 `:1414` 之间隔着 `:1416-1472` 共 30 余行正文和多个空行；GFM 表格要求行连续，这一行会渲染成带竖线的普通文字，不在表内。
- **描述**：这条要点（不要依赖 Reader 的 peek）与 §2.2、§10.3 讲的是同一件事，本来就是 §10.2 表格的一行；现在既丢格式又与后文重复。
- **建议**：把该行移回 `:1414` 之后（§10.2 表格末尾），或删除（§2.2 已有完整论述）。

### [轻微][存量] #11 README 中文版把解析错误写成「正则/实体错误」，模块内并不使用正则

- **位置**：`f_xml/README.md:115`（「所有重载都接受 `options!: XmlParserOptions = XmlParserOptions()`。**正则/实体错误**抛 `XmlException`。」）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「中英不同步 / 措辞错误」
- **证据**：静态确定 —— `f_xml/README_en.md:117` 对应句是「Parse / entity errors throw `XmlException`」；`f_xml/src/` 中没有任何正则使用，设计文档 §10.2（`:1411`）还明确「不要用正则」。
- **描述**：「正则错误」会让读者以为解析走正则引擎、或以为有正则相关配置需要设置；实际错误来自词法器 / 解析引擎 / 实体展开。
- **建议**：中文改为「词法 / 语法与实体错误抛 `XmlException`」。

### [轻微][存量] #12 README 缺两条关键限制：DOM 序列化 / 取文本的逐层递归无上限、单实例非线程安全未声明

- **位置**：`f_xml/README.md:403-421`（「安全边界」与「已声明的契约」两节，全文无「线程」字样、无序列化深度说明）；`f_xml/README_en.md:417-436`；实现 `f_xml/src/XmlNode.cj:234-250`（`collectText` 递归）、`XmlNode.cj:251-266`（每个元素新建 `StringGenerator`，`ElementNode → e.toString()` 互递归）、`f_xml/src/ParserEngine.cj:278`（`maxElementDepth` 只在解析入口生效）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §14.2「缺关键段落（限制与注意事项）」、§4「栈溢出」、§12.1「并发前提要写清」
- **证据**：静态确定 —— `collectText` 对每个 `ElementNode` 递归、`toString()` 对每个子节点递归；深度保护只存在于解析入口（`ParserEngine.cj:278-283`），构造型 DOM（`XmlElement` / `appendChild` 都是 `public`）与解析得到的 4096 层 DOM 在 `toString()` / `text()` 时都没有深度保护。线程侧：`doc/f_xml模块设计.md:26` 明确「`StringGenerator` 非线程安全，`XmlWriter` 单线程使用」，`:1323` 说实体计数器是「解析器实例级」，但 README 没有任何「单实例不可并发」的说明。
- **描述**：两处都是「使用者按文档用，结果在文档没写的地方踩坑」：
  1. 递归：`XmlElement.toString()` 每层压一帧，解析结果 4096 层就会压 4096 帧；构造型 DOM 可以更深，`text()` 同样递归。文档没给「序列化深度上限」或「序列化可能栈溢出」的提示。
  2. 线程：`XmlWriter` 持有可变缓冲、命名空间栈、`closed` / `frames` 状态；`XmlPullParser` 持有解析游标，明显不可并发。README 不写「非线程安全」，读者可能把同一个 writer 放进多线程回调。
- **建议**：README 的「已声明的契约」补两条：`XmlWriter` / `XmlPullParser` / `XmlElement` **非线程安全，单实例单线程使用**；`XmlElement.toString()` / `text()` 按嵌套层递归，深度受构造方式影响，超深树请改用流式写出（代码侧改成显式栈属 `XmlNode.cj` 的修法，留给对应部分）。「安全边界」把「深度 4096」限定为「解析期嵌套深度」，不要让人以为覆盖序列化。

### [轻微][存量] #13 「外部实体引用即报错」不覆盖外部参数实体：`%ext;` 被静默跳过

- **位置**：`f_xml/README.md:405-406`（「`<!ENTITY x SYSTEM "…">` 声明可识别，**引用即报错**」）、`doc/f_xml模块设计.md:923-924`（参数实体行写「❌ 同上」）；实现侧 `f_xml/src/DoctypeParser.cj:440-448`（`case None => () // 外部参数实体：不加载`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「文档承诺与实现不符」、§3「静默吞掉」
- **证据**：静态确定 —— 一般实体引用在 `EntityExpander.cj:71-74` / `291-294` 抛「外部实体…永不加载」；参数实体引用走 `DoctypeParser.expandParameterEntity()`，外部声明（`value == None`）直接返回 `()`，不抛错也不告警。
- **描述**：内部子集里 `<!ENTITY % p SYSTEM "x.dtd">` + `%p;` 时，文档承诺报错，实际静默继续；若 `%p;` 本应引入属性默认值/实体声明，后续引用会变成「未声明」并被 `standalone` 策略降级为「跳过并告警」，最终可能产出一份少了内容却解析成功的文档。
- **建议**：二选一并写进文档：要么在 `case None` 抛 `XmlException("外部参数实体…永不加载")`；要么把 README 改成「外部**一般**实体引用即报错；外部参数实体引用静默跳过（不加载）」，并在 `warnings()` 里记一条。

<!-- 第 2 部分 -->

### [一般][存量] #1 字符层「Strict 走 `StringReader`、GBK 走 `readln()`」的旧口径与同一变更的修正记录、spec 与实现三处互斥

- **位置**：`f_xml/doc/spec/implement-f-xml-m1/design.md:234`、`:236`、`:242`、`:247`、`:256`；`f_xml/doc/spec/implement-f-xml-m1/proposal.md:34-36`；`f_xml/doc/spec/implement-f-xml-m1/specs/f-xml-char-layer/spec.md:119`、`:151`
- **来源**：存量（快照模式无基线可比；这四份文件同属一个已归档变更，彼此矛盾，与"后来的实现变了"无关）
- **判据**：review-checklist §13「规格与实现漂移 / 文档过期」、§11「语义与注释不符」
- **证据**：静态确定 —— 同一变更内三种写法：
  - `design.md:234` 表格：`Utf8RuneSource`（Strict）底层 `std.io.StringReader<T>`、读取方式 `readln()`；`design.md:242` 还写成规范句：「`Strict` 路径 SHALL NOT 经过该解码器，必须保持 `std.io.StringReader` 的原始行为」；`design.md:236` / `:256` 让 `CharsetRuneSource`（GBK）也走 `readln()`。
  - `design.md:649-661`（同一文件的「实现修正 2」）：Strict 改为走 `ByteDecoder` 的 `Utf8Strict`，理由是 `readln()` 会吃掉行尾 `\r\n`、「字符层契约直接破掉」。
  - `specs/f-xml-char-layer/spec.md:107-110`：`Strict` 与 `Replace` **均**走自研字节解码；但同文件 `:119` 仍写「字符层 SHALL 把 `readln()` 的结果拼回字符窗口」、`:151` 仍写「GBK 等多字节编码 SHALL 仍走 `readln()`」。
  - `complete-f-xml-m1-followups/design.md:242`：「不用 `readln()` 绕过——那是 M1 已经否掉的方案（会吃掉行尾、破坏换行语义）」。
  - 实现侧：`RuneSource.cj:314` 为 `if (this.strict) { ByteCodec.Utf8Strict } else { ByteCodec.Utf8Replace }`；`RuneSource.cj:320`、`:385` 的 `decodeBatch` 转 `ByteDecoder.decodeBlock`；`CharsetRuneSource` 走 `TextReader.read()`（`RuneSource.cj:350-356`）；`grep -n readln f_xml/src/*.cj` 只命中 3 处注释（`ByteSniffer.cj:24`、`LineWindow.cj:22`、`RuneSource.cj:373`），**没有任何调用**。
- **描述**：这四份文档是字符层唯一的成文契约。`spec.md:119/151` 是带 SHALL 的验收要求，`design.md:242` 是带 SHALL NOT 的实现约束，两者与已落地的实现相反。后果有两条：(1) 第三方按 spec 实现 `RuneSource` 或按「行拼接」Requirement 复核时，会把已经被否掉的 `readln()` 语义当成契约，重新引入「吃掉行尾换行」的缺陷；(2) 后续 `optimize-f-xml-*` 按 `design.md` 的成本链（`design.md:663-671` 与 `:234` 的表）定位瓶颈时，会去找一条已经不存在的 `StringReader` 路径。
- **建议**：`design.md:234/236` 表格改为「`ByteDecoder.decodeBlock`（`Utf8Strict` / `Utf8Replace`）」「`charset4cj.TextReader.read()`」；删除 `:242` 的 SHALL NOT 与 `:247` 的「与 `StringReader` 一致」；`spec.md:119` 改为「字符层把 `RuneSource` 产出的码点（`Int32` 块）拼回窗口」，`:151` 改为「GBK 走 `charset4cj.TextReader`（逐字符 `read()`，`readln()` 已否决）」。若不想改归档正文，按该变更 §14 已有的作废登记机制补一条 A/B 编号（`design.md:737-753` 就是这种登记），但 spec 里的 SHALL 属于验收口径，必须直接改。
- **范围外提示**：`f_xml/src/RuneSource.cj:300` 的类注释同样写着 Strict「走 `std.io.StringReader`」，属 part1 清单，本部分未展开。

### [一般][存量] #2 Gate P 的相对基线与阈值有 9649 ms / 16 346 ms 两种写法，「≥25%」与「7200 ms」在 16 346 ms 基线下不能同时成立

- **位置**：`f_xml/doc/spec/complete-f-xml-m1-followups/design.md:13`、`:403-404`、`:411`、`:590`；`f_xml/doc/spec/complete-f-xml-m1-followups/proposal.md:58`；`f_xml/doc/spec/complete-f-xml-m1-followups/specs/f-xml-conformance/spec.md:31`、`:71`；`f_xml/doc/spec/complete-f-xml-m1-followups/verification.md:5`、`:12`
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §13「规格与实现漂移」；报告格式要求「判据 + 可复核数字」
- **证据**：静态确定（算术）——
  - `design.md:13`：Gate = `< 7200 ms`，括号写「相对**同轮同机 `-O0` 旧代码 16 346 ms** 提升 ≥25%」；`verification.md:5` 同口径。
  - `proposal.md:58`、`spec.md:31`、`:71`：Gate = `< 7200 ms`，括号写「相对基线 **9649 ms** ≥25%」。
  - `design.md:411`：9649 ms「只作参考，不用于本变更的 Gate 判定」。
  - 算术：16 346 × 0.75 = 12 259 ms ≠ 7200 ms；9649 × 0.75 = 7 237 ms ≈ 7200 ms。即 7200 只能由 9649 推出，却被挂在 16 346 上；按 16 346 的「≥25%」实际门槛应是 12 259 ms。
- **描述**：验收阈值本身可执行（7200 ms 是硬数字），但「相对谁提升多少」的配套说明自相矛盾，导致同一份 Gate 在复验时无法判定「达标」是按绝对值还是按相对比例。`spec.md` 是验收契约，`verification.md` 是验收记录，两者给外部读者的却是相反的基线口径。
- **建议**：统一成「绝对阈值 `min(3) < 7200 ms`」+ 单独一行「基线记录：同机 `-O0` 旧代码 16 346 ms（历史参考 9649 ms）」，删掉与阈值绑定的 ≥25%，或改成「相对 9649 ms 历史基线 ≥25%（该比例只用于解释阈值来源）」。四处（design / proposal / spec / verification）同改。

### [一般][存量] #3 `verification.md` §3 的结论「四档差异 < 0.5%」与同一张表的 16 384 档 −9.3% 直接矛盾

- **位置**：`f_xml/doc/spec/complete-f-xml-m1-followups/verification.md:52-59`（表 `:53-57`，结论 `:59`）；对照 `f_xml/doc/spec/complete-f-xml-m1-followups/design.md:436-444`；另 `f_xml/doc/spec/implement-f-xml-m1/design.md:646` 重复了同一错误结论
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §13「文档结论与自身数据相反」；`performance-optimization.md` 要求结论必须能被同表数据复核
- **证据**：静态确定 —— 同表数字：4096 = 1111.47 ms、8192 = 1103.78 ms、16384 = 1000.81 ms、65536 = 1098.55 ms。相对 8192：+0.70% / 0 / **−9.33%** / −0.47%（极差 110.66 ms = 10.0%）。结论写「10 MB 档四档差异 < 0.5%，无拐点」，与 16384 一档相差近 20 倍；`design.md:440` 自己写的是「−9.33% / 本机最快」，`:443` 也是「16K 有约 9% 的边际收益但不构成拐点」；`doc/f_xml模块设计.md:2422` 同样写 9%。
- **描述**：`verification.md` 是验收留档，`design.md:381` 又规定「对外一句话结论」要回填 README。若照 `verification.md:59` 回填成「四档无差异」，等于把一次 9% 的块大小效应抹掉；将来有人照这条结论去查「为什么 16K 更快 / 为什么默认不选 16K」会拿到错误前提。`implement-f-xml-m1/design.md:646` 的 R5 回填行同样写「10 MB 档差异 < 0.5%」，属同一错误结论的第二处副本。默认值 8192 的决策（D5、`design.md:584`）本身不受影响。
- **建议**：两处均改为「4096 / 8192 / 65536 三档落在 ±0.7% 内；16384 单档低 9.3%，属块大小效应而非拐点，且 16K 收益与文档形态相关，故默认仍取 8192（D5）」；`implement-f-xml-m1/design.md:646` 只保留指向 §8.2 的链接，不再抄结论。

### [轻微][存量] #4 设计文档记录的 `XmlException` 第三构造器形参类型与实现不一致

- **位置**：`f_xml/doc/spec/implement-f-xml-m1/design.md:106-112`（`:108` 为签名）；实现 `f_xml/src/XmlException.cj:92`（字段 `:76`）
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §13「API 与源码不符」
- **证据**：静态确定 —— 文档：`public init(message: String, line: Int64, column: Int64, kind!: ?EntityLimitKind)`；实现：`public init(message: String, line: Int64, column: Int64, kind!: EntityLimitKind)`（`XmlException.cj:92`），字段仍是 `?EntityLimitKind`（`:76`）。按文档写 `XmlException("m", 1, 1, kind: None)` 不能编译。
- **描述**：`design.md` §5 自称是「公开 API」章节，这一节是外部使用方写 `catch (e: XmlException)` 后构造/判分类的唯一成文来源；形参用 `Option` 还是裸枚举影响调用写法。归档件的自洽性检查（`design.md:782-789` 的五条）没有覆盖到这一处。
- **建议**：把文档改成 `kind!: EntityLimitKind`（与实现一致，语义上也更严格：有 `kind` 就一定是某个分类）。若希望支持「无分类」写法，那是新增重载、改公开 API，需用户单独拍板，不在文档修订范围内。

### [轻微][存量] #5 三处计数与估算数字未随产物对齐（WARNING 20/21、Python 用例 3/4、块填充次数 1 万/128）

- **位置**：`f_xml/doc/spec/complete-f-xml-m1-followups/tasks.md:161-162`（WARNING 20）vs `f_xml/doc/spec/complete-f-xml-m1-followups/design.md:16`、`verification.md:128-129`（21）；`f_xml/doc/spec/complete-f-xml-m1-followups/proposal.md:110`、`design.md:518-524`（Python 3 条）vs `verification.md:134`（4 条）；`f_xml/doc/spec/complete-f-xml-m1-followups/design.md:230-231`（1 MB ≈ 1 万次块填充）
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §13「数字与实现不符」、§14.1「版本与依赖漂移」同源问题
- **证据**：静态确定 ——
  - WARNING：`doc/build-warnings.md` §1 列 6 条 + §2 明写 15 条 = 21 条，与 `design.md:16` / `verification.md:128` 一致，`tasks.md:161` 的「现有 20 条」是改前值未更新（同一文档 `:16` 已说明新增 `hasOwnBlock()` 一条）。
  - Python 用例：`f_xml/tools/test_xmlconf_gen.py:26-61` 有 4 个 `def test_`（`test_matching_hash_passes` / `test_mismatch_returns_two_and_reports_both_values` / `test_default_expected_is_suite_digest` / `test_corrupted_cache_aborts_without_outputs`），`verification.md:134` 的「4 条」正确，`proposal.md:110` / `design.md:518-524` 的「3 条」是计划值。
  - 块填充：`design.md:230-231` 说「1 MB 文档大约 1 万次块填充，而不是 100 万次」；按 `bufSize = 8192`（`XmlOptions.cj:142`）与 `blockCapacityOf`（`RuneSource.cj:61-71`），1 MiB ≈ 128 个块，误差约 80 倍。
- **描述**：三处都不影响行为，但第 3 条会削弱 spec「块填充次数 ≤ 码点数 / 64 + 1」这个结构性断言的论证——按 128 次/1 MB 计算，余量是两个数量级，「数量级差」的说法应改用真实量级。
- **建议**：`tasks.md:161` 改 21；`proposal.md:110` 与 `design.md:518` 的「3 条」改「4 条」；`design.md:230` 改「1 MB ≈ 128 次块填充（`bufSize=8192`），10 MB ≈ 1 280 次」。

### [轻微][存量] #6 性能基准的「每档重复 3 次」要求与实测记录不符（1 MB / 50 MB 只跑 1 次）

- **位置**：`f_xml/doc/spec/complete-f-xml-m1-followups/specs/f-xml-conformance/spec.md:113-118`（`:117` 为「每档重复 3 次」）；`f_xml/doc/spec/complete-f-xml-m1-followups/verification.md:33-37`；`f_xml/doc/spec/complete-f-xml-m1-followups/design.md:395`；`tasks.md:110-111`
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §13「规格与实现漂移」（同一变更的 Requirement「性能基准可复现」）
- **证据**：静态确定 —— spec 写「每档重复 3 次（每次新建流与 parser），报告 3 个值与最小值」；`verification.md:33-37` 表中 1 MB 与 50 MB 的 run2 / run3 均为「—」，只有 10 MB 有 3 个值；`design.md:395` 写明「50 MB 只跑 1 次」；`tasks.md:110-111` 要求按 §6.2 的 3 次口径执行。
- **描述**：Gate P 只判定 10 MB，三次成立；但同一 Requirement 还承诺「计时结果可复核」，并把 1 MB / 50 MB 的耗时写进记录表。表中这两行把单次值放进 `min` 列，读者会误以为都是 3 次最小值。
- **建议**：二选一并在三处同步 —— ① 在 spec 为「1 MB 冒烟」「50 MB 单次记录」开书面例外（写明 `runs=1`、仅记录、不进 Gate）；② 补跑 50 MB 3 次并回填。无论选哪条，记录表都应显式标注 `runs`，不要用 `min` 掩盖单次值。

### [轻微][存量] #7 char-layer spec 的 Purpose 与 proposal 的块容量公式未随 D2 / D13 更新

- **位置**：`f_xml/doc/spec/complete-f-xml-m1-followups/specs/f-xml-char-layer/spec.md:5-9`（`:6` 为「10 MB < 1 s」）；`f_xml/doc/spec/complete-f-xml-m1-followups/proposal.md:36-37`；对照 `f_xml/doc/spec/complete-f-xml-m1-followups/design.md:18-20`、`:96`、`:590`
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §13「文档过期」/「同变更内数字不一致」
- **证据**：静态确定 —— spec Purpose 仍写「让事件模式解析达到 10 MB < 1 s」，而 D13（`design.md:18-20`、`:590`）已把出口改成「< 7200 ms，≥25%」，`verification.md:12` 实测 1101.8 ms；1 s 是后续 `optimize-f-xml-semantic-layer` 才达成的（范围外：`f_xml/README.md:434-437` 记 10 MB ≈ 497 ms）。另：`proposal.md:36-37` 写「码点块容量 = `max(64, bufSize)`，内存上界固定」，`design.md:96` 与 `spec.md:104` 为 `max(64, min(bufSize, 1048576))`；当 `bufSize > 1 MiB` 时前者不再有 4 MiB 单块上限。
- **描述**：两条都是「规划稿按初版写、设计决策改后没回头同步」。Purpose 会让读者以为本变更以 1 s 为验收线（实际差 10%，已移交）；块容量漏掉上限则使 proposal 对内存上界的说法偏乐观。
- **建议**：Purpose 改为「把 10 MB 从 ~15.8 s 降到 < 7.2 s（绝对 1 s 目标移交 `optimize-f-xml-semantic-layer`）」；`proposal.md:36-37` 补 `min(bufSize, 1<<20)`；两处一并登记到 `design.md` §16 的「与设计文档 / M1 产物的差异登记」。

### [轻微][存量] #8 性能表吞吐列混用十进制 MB 与 MiB

- **位置**：`f_xml/doc/spec/complete-f-xml-m1-followups/design.md:397-401`；`f_xml/doc/spec/complete-f-xml-m1-followups/verification.md:33-37`
- **来源**：存量（快照模式无基线可比）
- **判据**：review-checklist §13「数值口径不一致」
- **证据**：静态确定（算术）—— 1 MB 行写 12.5 MB/s，但 1 048 576 B / 80.1 ms = 13.1 MB/s（12.5 对应 1 000 000 B）；10 MB 行 9.5 MB/s 对应 10 485 760 / 1101.8 ms = 9.52 MB/s（MiB 口径），50 MB 行 9.7 MB/s 同理。而 spec 的 `targetBytes = 10 * 1024 * 1024`（`specs/f-xml-conformance/spec.md:122`）与用例的 `measure(1024 * 1024, …)`（`src/Perf_test.cj:548`）都按 1024 进制取值。
- **描述**：只有 1 MB 行按十进制算，10 / 50 MB 行按 MiB 算，同一列不可横向比较；1 MB 的吞吐被低估约 5%。
- **建议**：统一按 MiB 重算 1 MB 行为 13.1 MB/s，或在表头标注「MB = 10^6 B」并把另外两行重算为 9.1 / 9.3 MB/s；两种做法都要与 `perf: bytes=…` 输出的单位说明一致。

### 已排除的候选（误报边界，不计入统计）

- **「包结构表漏 `NameTable.cj` / `ByteScratch.cj`」**：这两个文件由后续 `optimize-f-xml-semantic-layer` 引入（`git log`：`639046e37` 复用字节暂存、`485471c5e` 收口门禁），M1 归档时并不存在。按 checklist §13 误报边界（`doc/spec/<已归档变更>/` 只要求当时自洽），不判缺陷。
- **「`design.md:277-283` 的 Lexer 静态检查白名单行号失效（200/209 → 235/244、1123/1156 → 1211/1244）」**：同上，行漂移由后续改动造成，白名单的**分类**结论仍成立（其余命中均为 `this.position()`）。若要与当前代码对齐，可随下次文档维护一次性改为符号名，不作为缺陷。
- **「`verification.md` 的 Scenario 对照表把只打印耗时的 `smokeOneMegabyte` 计为覆盖」**（`verification.md:79`）：该 Scenario 在 `spec.md:130-133` 要求「不出现逐字符新建 `String` 的路径」，用例只有 `measure + println` 无断言（`src/Perf_test.cj:547-550`），严格说「覆盖」偏宽；但文档已在 `:85` 以同样方式诚实标注静态检查项，影响仅限措辞，本轮不单列。

> 存量缺陷 8 条（一般 3 / 轻微 5），是否纳入修复待用户决定；本报告不替用户拍板。

<!-- 第 3 部分 -->

### [一般][存量] #1 同一份 `tasks.md` 对 xmlconf Gate A 给出相反结论：12.5 记「未达成」，10.2 / 8.10 记「已达成」

- **位置**：`f_xml/doc/spec/implement-f-xml-m1/tasks.md:350`（12.5「xmlconf 的 Gate A 未达成」）；同文件 `:294-296`（10.2「**已达成**：实测 `pass=2038 fail=0 unsupported=524`」）、`:218`（8.10 同样记达成）
- **来源**：存量（工作区快照，无基线可比；12.5 是第三轮修订前的文字，10.2 重写后未回填）
- **判据**：review-checklist §13「规格与实现漂移 / 文档过期」、§11「契约与实现不符」
- **证据**：静态确定 —— 12.5 是本文件唯一一处「未达成」，而 10.2 勾选并给出三数字，`implement-f-xml-m1/baseline.md:1-12`（「当前基线（Gate A 已达成）」）与 `implement-f-xml-m1/verification.md:12`（`pass=2038`、`fail=0`）一致指向达成。12.5 的括注还写「见 10.2 与 baseline.md」，而那两处结论都与它相反
- **描述**：读者按任务表核对验收状态会得到互斥答案。这不是措辞问题：Gate A 是整个变更的出口条件，验收记录自相矛盾会让「是否可归档」无法复核
- **建议**：把 12.5 改为「Gate A 已达成（见 10.2）」；若想保留历史，写成「首轮基线未达成（见 `baseline.md` §2），第三轮后达成（见 §1）」，不要在同一句里给单值结论

### [一般][存量] #2 `f-xml-writer` 规格要求 UTF-8 走 `StringWriter` + `StringGenerator.unsafeBytes()`，实现已整体换成 `ByteScratch`，且无任何偏离登记

- **位置**：`f_xml/doc/spec/implement-f-xml-m1/specs/f-xml-writer/spec.md:143`（「UTF-8 SHALL 走 `std.io.StringWriter` + `StringGenerator.unsafeBytes()` 直接写字节」）
- **来源**：存量（工作区快照；后一次变更 `reuse-f-xml-writer-scratch` 改了实现但没改这条 SHALL）
- **判据**：review-checklist §13「API / 配置 / 默认值与源码不符」、§14.1「承诺了但没实现」
- **证据**：静态确定 —— 全模块 `grep -rn StringWriter f_xml/src` **0 命中**；实际实现是 `f_xml/src/XmlWriter.cj:51` `private let buffer = ByteScratch()` 与 `XmlWriter.cj:311` `this.output.write(this.buffer.bytes()[0 .. this.buffer.size])`；`reuse-f-xml-writer-scratch/design.md:43-53`（D1）明确「`XmlWriter` 缓冲换成 `ByteScratch`」，但该变更的 `proposal.md:19` 只声明「公开 API 不变」，`specs/xml-writer-output/spec.md` 也未声明覆盖 / 作废 writer spec 的这条要求。同一 Requirement 内「SHALL NOT 用 `writeln()`」仍然成立（`writeln` 全模块 0 命中）
- **描述**：两条 SHALL 中一条已永久不可满足（没有 `StringWriter`），另一条成立。规格是归档契约，后续按 spec 审计会把现状判成违约；反过来若有人照 spec 恢复 `StringGenerator` 缓冲，则与 `reuse` 变更的实测结论（`design.md:5-25`：`append(Rune)` 每字符 68 B）冲突。这是本部分最硬的一处「SHALL 与实现相反」（另一处相关表述见 #12 的 `close()` 契约）
- **建议**：在 writer spec 该行补注「已于 `reuse-f-xml-writer-scratch` 改为复用 `ByteScratch`，输出字节不变（见其 spec / design）」；或按 `optimize-f-xml-semantic-layer/verification.md:119-125` 的既有做法，在 reuse 变更的 `verification.md` 里单列一张「与既有 spec 的偏离登记」表并把这条登记进去

### [一般][存量] #3 DOM 侧两个公开递归入口（`text()` / `XmlWriter.write*`）没有深度契约，程序化构造的 DOM 可栈溢出

- **位置**：`f_xml/doc/spec/implement-f-xml-m1/specs/f-xml-dom/spec.md:69`（`text(): String`（拼接所有后代文本））、`f_xml/doc/spec/implement-f-xml-m1/specs/f-xml-writer/spec.md:11-12`（`write(doc)` / `write(element)`）
- **来源**：存量（工作区快照；规格与实现同批落地，缺的是「限制」这一段）
- **判据**：review-checklist §4「无界递归 / 深度由输入决定」、§11「边界差一 / 越界」；§14.2「缺关键段落：限制与注意事项」
- **证据**：静态确定 —— 实现按层递归：`f_xml/src/XmlNode.cj:234-240` `text()` 调 `collectText`，`:240-249` 对每个 `ElementNode` 递归自身；`f_xml/src/XmlWriter.cj:465-497` `writeElement` → `:502-508` `writeNodeWithName` → `writeElement`。上游没有任何深度护栏：`XmlElement.appendChild`（`XmlNode.cj:172`）、`XmlDocument.root`（`XmlNode.cj:277`，`public var`）都可程序化设置任意深度；解析侧唯一的深度限制 `XmlOptions.cj:146` `maxElementDepth = 4096` 是**用户可配**且无上限校验（`:153` 直接赋值）
- **描述**：解析产物默认受 4096 层约束，按 4096 层估算递归深度通常安全；但规格把 `text()` / `write()` 定义为可接受任意 `XmlElement` / `XmlDocument`，而 DOM 是公开可变的，调用方（或把 `maxElementDepth` 调高的解析结果）构造出深链后调用 `text()` / `write(element)` 就是无界递归——没有拒绝路径、没有告警，后果是进程崩溃而不是异常。规格对这一层完全沉默，使用者无法从文档得知「必须自己保证深度」
- **建议**：规格补一条显式约定，二选一：(a) 要求实现改成显式栈迭代，文档写明「任意深度安全」；(b) 声明「递归实现，调用方 SHALL 保证深度 ≤ N（N 与 `maxElementDepth` 默认值一致），超限行为未定义」并在 `text()` / `write()` 的注释里重复。倾向 (a)：这两处都只是树的先序遍历，改迭代成本低且能同时消掉 `maxElementDepth` 被调高后的隐患

### [一般][存量] #4 Gate C 承诺「每次运行把 unsupported 的 ID 清单存档」，harness 只写 fail 清单

- **位置**：`f_xml/doc/spec/implement-f-xml-m1/specs/f-xml-conformance/spec.md:171`（Gate C 行：「每次运行输出 `pass / fail / unsupported` 三个数字，并把 `unsupported` 的 ID 清单存档」）、`:193-196`（Scenario「Gate C 三数字」重复同一要求）
- **来源**：存量（工作区快照）
- **判据**：review-checklist §3「公开契约承诺有行为，实现缺失」、§14.1「承诺了但没实现」
- **证据**：静态确定 —— `f_xml/src/XmlconfHarness_test.cj:110` 只 `println` 三数字；`:114-119` 只写 `cache/failures.txt`（fail 清单），全文件没有任何写 unsupported 清单的语句；`unsupported` 的 ID 集合只存在于生成脚本一次性产出的 `cache/unsupported.json`（`tools/xmlconf_gen.py` 另生成入库的 `doc/xmlconf-unsupported.md`）。同目录 `tasks.md:147-148` 反而写明「harness 只读缓存并计数」，与 spec 的 Gate C 直接冲突
- **描述**：数据本身没有丢——`unsupported.json` / `xmlconf-unsupported.md` 可复核（本部分已核对：524 行，`edition 313 / external-entity 95 / xml-1.1 59 / external-subset 47 / namespace-name 10` 与 spec 完全一致）。缺的是「每次运行留档」这个动作，因此 Gate C 的「可追溯」实际只覆盖 fail 一侧；换一套缓存重建后，运行记录里查不到当次被判 unsupported 的具体 ID。按后果（无运行时影响、数据可另取）记一般，不判严重
- **建议**：harness 增写 `cache/unsupported.txt`（一行一个 ID，与 `failures.txt` 同处），或在 spec 侧把口径改成「`unsupported` 清单由 `xmlconf_gen.py` 存档，harness 只断言计数」并同步该 Scenario——两者选一，不要保持「承诺了但没人做」

### [轻微][存量] #5 8.11 的残差条数（12）与 §13 / `baseline.md` 的分解（13）不符，归因也错位

- **位置**：`f_xml/doc/spec/implement-f-xml-m1/tasks.md:234-236`（「`not-wf` 被接受从 385 条降到 60 条…余下 12 条由 8.9 / 8.12 / 8.13 收敛」）
- **来源**：存量（工作区快照）
- **判据**：review-checklist §13「规格与实现漂移」、§2「近似重复导致的口径漂移」（同一条收口链在两处给出不同结论）
- **证据**：静态确定 —— 同文件 `:366-369` 写「余下 13 条里 11 条由实现修正收掉（B1 2 + B2 1 + B4 7 + B5 1）、2 条（`rmt-ns10-043` / `-044`）由 `namespace-name` 排除」；`implement-f-xml-m1/baseline.md:78-84` 的算式是 `385 − 325 = 60`、`60 − 47 = 13`、`13 − 2 − 11 = 0`。三条都指向 13，只有 8.11 写 12。归因同样不符：B1（BOM 与 `encoding` 冲突）、B2（内部子集条件段）不在 8.9 / 8.12 / 8.13 名下，8.9（standalone 三档）在这 13 条里贡献为 0
- **描述**：8.11 是「声明语法校验」这项工作的收口记录，读者据此判断剩余不良构去向会数错 1 条，并把 2 条排除规则的功劳记到实现任务上。最终 `fail = 0` 已被 `baseline.md` / `verification.md` 复核，故只记轻微
- **建议**：改为「余下 13 条：11 条由 B1 / B2 / B4 / B5 实现修正收掉，2 条由 `namespace-name` 规则移出」，与 `baseline.md` §3 的算式逐项对齐

### [轻微][存量] #6 `optimize-f-xml-semantic-layer/baseline.md` 50 MB 行的事件数与记录数不满足它自己声明的不变式

- **位置**：`f_xml/doc/spec/optimize-f-xml-semantic-layer/baseline.md:34`（50 MB 行：事件数 `3 726 208`、记录数 `1 247 399`）、同文件 `:39-40`（不变式「`events = 3 × records + 4`」）
- **来源**：存量（工作区快照）
- **判据**：review-checklist §13「文档数值不一致」、§11「与规格 / 文档记载冲突」
- **证据**：静态确定 —— `3 × 1 247 399 + 4 = 3 742 201`，与表内 `3 726 208` 差 `15 993`（恰好 `5 331 × 3`，即 5 331 条记录）；同一张表的 1 MB（`80 311 = 3 × 26 769 + 4`）与 10 MB（`764 857 = 3 × 254 951 + 4`）两行都严格成立
- **描述**：这张表是 Gate T / Gate M 的改前对照引用源，其中一列抄错会让「事件数校验」这个自检形同虚设；也说明当时没有真的按不变式复算 50 MB 一行。由于 Gate 只引用时间与 `VmHWM`，不影响门禁结论，记轻微
- **建议**：复跑 50 MB 或用例输出（`PerfFifty_test` 打印项）核对后订正事件数或记录数，并在表下注明「两列以用例输出为准」

### [轻微][存量] #7 `baseline.md` 三处未随实测回填：协议「每档 5 次」、标题「待补」、「只有 2 个不同字面名」

- **位置**：`f_xml/doc/spec/optimize-f-xml-semantic-layer/baseline.md:51-53`（协议第 4 条「每档 5 次、每次独立进程、取 `min`」）、`:42`（小节标题仍写「同轮实测（**待补** …）」）、`:112`（「`readName` … **只有 2 个不同字面名**」）
- **来源**：存量（工作区快照）
- **判据**：review-checklist §13「文档与自身协议不一致 / 文档过期」、§6.1「测量口径必须可复核」
- **证据**：静态确定 ——
  - 协议要求每档 5 次，但 `:65-67`、`:77-81` 的 1 MB 与 50 MB 只有 `run1`（其余 `—`，`:67` 括注「50 MB 单次」），`:69` 仍称「均无负载污染（阈值 1.4）」——单次测量算不出 `max/min`。`design.md:96` 只对 50 MB 声明单次（`PerfFifty_test` 1 次），1 MB 的单次没有任何依据。
  - `:42` 标题写「待补」，而 `:56-81` 已填两组实测值、文件头 `:6-8` 也声明「§3 已补齐」。
  - `:112` 写「2 个不同字面名」；同变更 `tasks.md:77` 与 `f_xml/src/Lexer_test.cj:157,170` 都按 **3** 个（`item` / `id` / `a`）断言。
- **描述**：三处都是「实测出来后没回头改估算 / 协议 / 标题」。第 3 条把名字驻留的收益面写小了一个（4 次 `readName` 只对应 2 个不同名字，实际 3 个），会让读者误判驻留覆盖度；第 1 条把「单次」说成「无污染」，读者第一反应会是「作者算过波动」。均不影响 Gate 结论（10 MB 的 5 次值齐全），但误导证据强度
- **建议**：`:51-53` 限定为「10 MB 5 次；1 MB / 50 MB 各 1 次，不参与 `max/min`」并删掉 `:69` 的「均」；`:42` 去掉「待补」；`:112` 改为「3 个不同字面名（`item` / `id` / `a`）」

### [轻微][存量] #8 `StringGenerator.unsafeBytes()` 的语义在两份归档 spec 里被描述成互斥的两件事，而其中一侧正是 `ByteScratch` 的立论依据

- **位置**：`f_xml/doc/spec/optimize-f-xml-semantic-layer/baseline.md:94`（「`StringGenerator.unsafeBytes()` 返回**按 size 截好的新数组**…每次驻留比对都会分配」）与同目录 `design.md:425`（D16 同义）；对照 `f_xml/doc/spec/reuse-f-xml-writer-scratch/design.md:12`（「`unsafeBytes()` 返回的是按 size 截好的**数组视图**」＋「**没有** 16 KB 的整块复制」）
- **来源**：存量（工作区快照）
- **判据**：review-checklist §13「规格与实现漂移」、§2「同一事实两种表述导致决策漂移」
- **证据**：文档互斥（静态确定）；实现侧 `f_base/src/StringGenerator.cj:265-267` 是 `utf8.unsafeData()`（`ArrayList` 底层存储直取，方法体内无复制语句），`reuse` 侧实测（`reuse design.md:5-12`：64 次 × 16 KB 刷写总分配 20 080 B）只能用「共享存储、不复制字节」解释。**待确认**：`ArrayList.unsafeData()` 每次是否仍产生一个小的视图对象（本机 `~/.autocode/cj/doc` 不可用，无法查标准库语义），这一点决定「每 token 分配一次」是否成立
- **描述**：一侧说「新数组（会分配）」、一侧说「视图（无整块复制）」。两种描述若都按字面理解，D16「因此名字扫描必须改用 `ByteScratch`」与 D1「因此 `XmlWriter` 不必改 flush」就至少有一条立据错误；后续按文档继续复用（例如给文本缓冲也换 `ByteScratch`）会得出相反结论。代码本身行为不受影响（`BufferReuse_test` 有逐字节对拍），故记轻微
- **建议**：统一为「返回共享底层存储的视图；是否每次新建视图对象需实测」，两处互相引用同一句结论，并注明探针（填 10000 取 10000、reset 后 append 1 取 1）说明的是「长度跟随 size」而不是「发生拷贝」

### [轻微][存量] #9 `optimize-f-xml-semantic-layer/verification.md` 章节编号重复且乱序（两个 `## 6.`，且第二个排在 `## 8.` 之后）

- **位置**：`f_xml/doc/spec/optimize-f-xml-semantic-layer/verification.md:96`（`## 6. Scenario → 用例对照`）、`:127`（`## 8. 遗留项`）、`:133`（`## 6. verify 收口（2026-10-30）`）
- **来源**：存量（工作区快照）
- **判据**：review-checklist §13「结构 / 引用失效」、可维护性
- **证据**：静态确定 —— 文档出现 `1,2,3,4,5,6,7,8,6` 的编号序列；末尾的收口表（W1 / S1–S5）是最后追加的一节，未重编号
- **描述**：验收记录被其他部分引用（`design.md:10` 指向「`verification.md` §2」），编号错乱会让「§6 指哪一节」产生歧义；不影响结论
- **建议**：收口节改为 `## 9. verify 收口`，或整体重排为 1–9

### [轻微][存量] #10 `design.md` §11 承诺「实施后回填实际值」，用例数仍停在估算区间 22–28（实测 39）

- **位置**：`f_xml/doc/spec/optimize-f-xml-semantic-layer/design.md:435`（「上一轮 `README.md`「337 条」→ 本变更在此基础上新增约 22–28 条 → **实施后回填实际值**」）
- **来源**：存量（工作区快照）
- **判据**：review-checklist §13「文档过期」、§14.2「版本与命令过期」同类
- **证据**：静态确定 —— `verification.md:76`「改动前 337，新增 39」、`:83-94` 的分布表（7+8+13+4+1+1+2+3 = 39）与本文件 `:435` 的 22–28 相差 11–17 条
- **描述**：这是 design 自己写明的回填义务，未执行。读者若按 design 估算新增规模会低估 40%；`proposal.md:143` 的同区间属提案期估算，可保留，但 design 的「回填」承诺应兑现
- **建议**：回填「实测 +39（`cjpm test` 337 → 376）」，保留原估算区间并标注为估算

### [轻微][存量] #11 三份文档的「文件清单 / 路径」陈述与仓库现状不符（4 处）

- **位置**：`implement-f-xml-m1/tasks.md:144`、`:185`；`implement-f-xml-m1/specs/f-xml-conformance/spec.md:22-24`；`optimize-f-xml-semantic-layer/tasks.md:95-96`
- **来源**：存量（工作区快照）
- **判据**：review-checklist §13「链接 / 路径失效」、§14.1「文档过期」
- **证据**：静态确定 ——
  - `tasks.md:144` 写「写 `src/XmlconfHarness_test.cj` + `src/TestDataRoot.cj`」，`f_xml/src/TestDataRoot.cj` 不存在；`TestDataRoot` 定义在 `f_xml/src/TestDataRoot_test.cj:32`（`internal class`）。
  - `tasks.md:185` 写「→ 实现 `src/SpillDir.cj`」，该文件不存在；`SpillDir` 定义在 `f_xml/src/ExpandSink.cj:30`（四级目录顺序 `:27-47` 与 spec 一致）。
  - `spec.md:22-24` 写「版本库 SHALL 只保留三样：`xmlconf_gen.py`、`known-issues.json`、`xmlconf-unsupported.md`」，`git ls-files f_xml/tools` 实际命中四份（多 `test_xmlconf_gen.py`，且 `baseline.md:18` 明确引用它的 4 条用例）。
  - `tasks.md:95-96` 写 grep「只剩 … 白名单里的位置（`collapseSpaces` 等 **4 处**）」，`design.md:227-235` 的实测复核是 **3 处**（`Lexer.cj:72,143,145` 实测一致），白名单表本身 4 行但跨 4 个不同文件。
- **描述**：四处都是「任务写完后实现换了落点 / 后续变更增了文件，文档不回填」。第 1、2 条会让按文档找实现的读者直接扑空；第 3 条规定了一条现在被违反的入库规则（照它执行会误删 Python 用例）；第 4 条把「白名单 4 条（跨文件）」与「`Lexer.cj` 内 3 处命中」混为一谈。均为文档问题，无功能影响
- **建议**：`tasks.md:144` 改 `TestDataRoot_test.cj`；`:185` 改「实现于 `src/ExpandSink.cj` 的 `internal class SpillDir`」；`spec.md:22-24` 改为「生成脚本 + 人工裁定文件 + Python 用例 `tools/test_xmlconf_gen.py` 一并入库」；`tasks.md:95-96` 改为「`Lexer.cj` 内剩 3 处（白名单跨 4 个文件）」

### [轻微][存量] #12 `f-xml-writer` spec 的公开 API 清单与 `close()` 契约落后于实现

- **位置**：`f_xml/doc/spec/implement-f-xml-m1/specs/f-xml-writer/spec.md:9-13`（成员清单）、`:15-16`（`close()` 后为「未定义行为」）、`:20-23`（`close` Scenario）
- **来源**：存量（快照；spec 随 `622f0c2c6` 入库，增量接口随 `9066e1cd7` 加入，spec 未回填）
- **判据**：review-checklist §13「契约与实现不符」、§14.2「公开 API 未文档化」
- **证据**：静态确定 ——
  - spec 成员清单只有 `init` / `write(doc)` / `write(element)` / `flush` / `close`；实现另有 5 个 `public` 方法：`writeDeclaration`（`f_xml/src/XmlWriter.cj:168`）、`startElement`（:184）、`endElement`（:207）、`text`（:234）、`emptyElement`（:245），`README.md:124` 已文档化，但 `doc/spec/**` 无任何 spec 覆盖这批接口。
  - spec:15-16 称 close 后调用「未定义行为」；实现是确定性行为——`close()` 之后任何入口走 `ensureOpen()` 抛 `XmlException("XmlWriter 已关闭，不得再调用")`（`XmlWriter.cj:295-299`），`close()` 自身幂等（`XmlWriter.cj:277-279`）。`README.md:417` 同样写「未定义行为」，两份文档一起偏离实现。
  - spec:20-23 只写「写入后 `close()` → 底层收到全部字节并被 flush」；实现里仍有未闭合元素时 `close()` **先抛** `XmlException("有 N 个元素未闭合，不能关闭 XmlWriter")`（`XmlWriter.cj:278-282`），底层既不 flush 也不 close。该行为只写在 `README.md:100,300`。
- **描述**：这份 spec 是 `XmlWriter` 的对外契约，读者按它无法得知：(a) 存在增量写入接口；(b) close 会因未闭合元素失败且失败后底层流未 flush；(c) close 后的调用是可捕获异常而不是 UB（UB 的说法会让人不去 catch）。三者都是使用者会踩的路径
- **建议**：补 5 个增量方法各 1 条 Scenario（增量与整树不可混用）；`close()` 段改为「冲刷 → flush → 关闭底层；若仍有未闭合元素则抛 `XmlException` 且**不**关闭底层」；把「未定义行为」改为「抛 `XmlException`」，与实现对齐并同步 README

### [轻微][存量] #13 `f-xml-dom` spec 用 `prop` 描述实际为 `let` / `var` 的字段，其中三个字段可写

- **位置**：`f_xml/doc/spec/implement-f-xml-m1/specs/f-xml-dom/spec.md:62-64`、`:85-89`
- **来源**：存量（快照）
- **判据**：review-checklist §13「文档与实现不符」、语言特性（`prop` 与字段的区别）
- **证据**：静态确定 —— spec 写 `prop name` / `prop attributes` / `prop children`、`prop root` / `prop declaration` / `prop doctype` / `prop prolog` / `prop epilog`；实现是 `public let name`、`public let attributes`、`public let children`（`f_xml/src/XmlNode.cj:149-151`）与 `public var root` / `declaration` / `doctype`（`XmlNode.cj:277-279`）、`public let prolog` / `epilog`（:281,283）
- **描述**：仓颉里 `prop` 是计算属性，字段声明是 `let` / `var`。更实质的是 `root` / `declaration` / `doctype` 是 `var`——使用者可整体替换根元素或声明，spec 的 `prop` 写法会让人以为只能读；`prolog` / `epilog` 是 `let` 容器（可 add 不可换），也不是 `prop`
- **建议**：8 处改为字段写法；对 `root` / `declaration` / `doctype` 明确「可写（`var`）」，对 `prolog` / `epilog` 注明「容器只读、内容可变」

### [轻微][存量] #14 `reuse-f-xml-writer-scratch` 缺 tasks.md 与 verification.md，验收无书面记录

- **位置**：`f_xml/doc/spec/reuse-f-xml-writer-scratch/`（仅 `design.md`、`proposal.md`、`specs/xml-writer-output/spec.md`）
- **来源**：存量（`639046e37` 已入库）
- **判据**：review-checklist §14（可追溯 / 产物完备），对照同目录另两个变更的六件套结构
- **证据**：静态确定 —— `implement-f-xml-m1/` 与 `optimize-f-xml-semantic-layer/` 均含 `tasks.md` + `verification.md`；本变更两者都缺。`design.md:84-92` 承诺的验收项（多段刷写逐字节一致、`≤ 8 B/rune`、基线高 8 倍）只在 `f_xml/src/XmlWriterScratch_test.cj:164-227` 的断言里，无实测数值与运行环境记录
- **描述**：代码与用例都在（`ByteScratch.cj:30-107` 已有 `append(text)` / `putCp` / `reset` / `bytes` / `toUtf8String`），行为契约也有 spec，唯独缺「这条变更怎么验收的」这一层。后续若质疑 8 B/rune 的来源，只能重跑用例
- **建议**：补一份极简 `verification.md`（实测 `allocPerRune`、基线比值、`cjpm test` 条数、`-O2` 档位）；`tasks.md` 可只列已完成项，重点是让三个变更的产物结构一致

> 存量缺陷共 **14 条**（一般 4 / 轻微 10），是否纳入修复待用户决定。本部分全部结论基于工作区快照，无「本次改动」项。

**范围外提示**（不占本部分统计）：

- `f_xml/src/NameTable.cj:82` 的注释「表内不同名字数即 `insertions`，不另设计数」与 `:66` 的 `prop distinct` 矛盾（属实现文件，留给对应部分）。
- `f_xml/src/Lexer_test.cj:171-172` 连续两次断言 `insertions`（第二条消息写「distinct 应为 3」），`NameTable.distinct` 在该用例里实际未被断言——核对 `verification.md` S3 收口声明时撞见，属 part5 覆盖。

<!-- 第 4 部分 -->

### [严重][存量] #1 实体溢出的落盘链路在解析主路径上完全不可达：8 MB / 64 KB 软阈值实际不生效，语义与设计文档相反

- **位置**：`f_xml/src/EntityExpander.cj:82-113`（`feed`：:82 抛 `PerEntity`、:108-113 是同一条件下的恒假分支，也是唯一的落盘分支）、`:249-264`（`expand` 建 sink）；对照 `f_xml/src/ExpandSink.cj:184-205`（非属性分支才 `spill()`）、`:216-231`（`spill` 本体）、`f_xml/src/Lexer.cj:1113`（生产路径唯一 `expand` 调用）
- **来源**：存量（工作区快照无基线；`git blame` 不适用，全部为当前快照代码）
- **判据**：review-checklist §5「无界容器 / 拒绝路径失效」、§11「契约与实现不符」、§3「开关打开后走进空分支（功能未接完）」、§14.1「接线缺失」
- **证据**：静态确定 —— 三条互锁事实：
  1. 生产代码里 `expand` 只被 `Lexer.cj:1113` 调用一次，形参固定 `attribute: true`；`ExpandSink` 的 `attribute` 分支（`ExpandSink.cj:154-174`）对单实体超限直接抛 `AttributeValue`，对总量在 `Spill` 下既不抛也不落盘（`:166-174` 的总量判定只在 `Strict` 生效）——属性值不落盘是设计确认的行为（必须在内存里参与命名空间解析），但"总量也不落盘"同样与设计 §5.4.1 的表不符。
  2. 唯一能走非属性分支（`ExpandSink.cj:175-205`，`spill()` 在此）的地方是 `EntityExpander.cj:110`，而它被 :82 的 `if (size > this.limits.maxExpandedPerEntity) { throw ... }` 拦死：:108 与 :82 判断的是同一个 `size` 与同一份 `limits`（都是 `let`，中间没有重新赋值）⇒ :108-113 恒不可达。注意 `feed` 的 `bufSize` 形参**只**在这个死分支里被使用（`:112`）。
  3. 因此 `ExpandSink.spill()`（`:216-231`）、`SpillDir`、`FileExpandReader` 在整个生产路径上零调用，只有 `Spill_test.cj:39/66/89/115` 直接 `ExpandSink(limits, counter)` 构造时才执行。
- **描述**：设计与 README 把 Spill 当作默认策略的主防线——`doc/f_xml模块设计.md:1000-1001`（`maxExpandedPerEntity` 64 KB 软「该实体的展开结果转写临时文件」、`maxExpandedTotal` 8 MB 软「整个文档转入溢出模式」）、`:1312`、`README.md:333`（「`Spill`：软阈值超限转临时文件」）、`:407`。实际后果有三条，方向都相反：
  - **单个实体超 64 KB 被直接拒绝**：即使 `overflowPolicy = Spill`（默认值，`XmlOptions.cj:109`），内容位置的 `<!ENTITY e "…70000 字符…">` 配 `<a>&e;</a>` 也抛 `PerEntity`，合法文档被拒。判定用的是**原文长度**（`:77`），因此组合实体（10 字节原文 → 数百 KB 展开）反而绕过这条软阈值。
  - **8 MB 总量阈值对内容位置完全不生效**：`:90-98` 只在 `Strict` 下抛，`Spill` 下既不抛也不落盘，只把 `counter.total` 加到一个投影值上，真正的拒绝点是 :99 的 2 GiB 硬限。
  - **小输入可换大驻留（OOM 面）**：`<!ENTITY e "…60000 个字符…">` + 正文 `&e;` × 20000（输入约 140 KB）→ 展开 1.2×10⁹ 字符全部驻留（DOM 文本缓冲 + 文本节点，取决于前端），计数停在 1.2e9 < 2 GiB 硬限，**不抛任何异常**；单回调前端（`XmlParser.cj:55-63`，本应靠落盘保持恒定内存）同样吃满。默认堆远小于 2 GiB，即拒绝路径实际是"先 OOM 再报错"。
  - 附带两个"这条分支从未跑过"的痕迹：`:110` 给落盘 sink 传的是新建的 `EntityCounter()`，即便分支被恢复，文档级计数也会漏记这段内容（`ExpandSink.write` 只累加传入的 counter）；`EntityLimits_test.cj:107-129`（名为 `degradeRetrySucceeds`，「Strict 失败 → Spill 重试成功」）之所以通过，是因为那 300000 字符从未落盘，它验证不到 Spill 语义。
- **建议**：把判定交还 `ExpandSink`（与设计 §5.4.2 的伪码一致）：`feed` 删掉 :82-89 的提前抛，改成 `Strict` 才抛、`Spill` 走 :108-113；同时把 `EntityCounter()` 换成 `this.counter`。补两条能真正区分行为的用例：(a) 70 KB 单实体 + `Spill` 应成功且 `isSpilled()` 为真；(b) 总量超 8 MB + `Spill` 且带 `onEvent` 回调时，`retainedBytes` 不随展开量增长。若确定"内容位置也不落盘"是有意收窄，则必须改 `README.md:333/407` 与设计 §5.4.1 的表，并在 `EntityLimits` 注释里写明"Spill 仅对属性值以外的路径无效"——不能让默认值承诺一件没做的事。

### [严重][存量] #2 `<!ELEMENT>` 内容模型的分组嵌套无深度上限，`parseGroup` 自递归 → 栈溢出

- **位置**：`f_xml/src/DoctypeParser.cj:607-635`（`parseContentSpec` 入口）、`:638-682`（`parseGroup`）、`:685-704`（`parseCp` → `:689` 回到 `parseGroup`）；`depth` / `maxDepth` 字段仅用于参数实体（`:115-116`、`:426-451`）
- **来源**：存量（工作区快照）
- **判据**：review-checklist §4「无界递归：深度由输入决定，无出口 / 无深度计数」
- **证据**：静态确定 —— `parseCp` 在 `(` 处直接 `this.parseGroup(decl, topLevel: false)`，`parseGroup` 又调 `parseCp`，两者构成 `(` 层数 = 递归层数的自递归；`parseGroup`/`parseCp` 都不查 `this.depth`（全文 `grep depth` 只命中 `expandParameterEntity` 与构造），也不查 `maxElementDepth`（那是元素层，`ParserEngine` 用显式栈）。DTD 原文由 `Lexer.readInternalSubset`（`Lexer.cj:1022` 起）整段收进 token，没有长度或嵌套上限，`ParserEngine.cj:259` 直接把它交给 `DoctypeParser.parse`。
- **描述**：`<!DOCTYPE a [<!ELEMENT a ` + `(` × N + `b` + `)` × N + `>]><a/>` 会压 N 层栈帧（每层 `parseGroup`+`parseCp` 两帧）。N 只受输入长度限制：一份 1 MB 的 DTD 可给到 ~10⁵ 层，栈溢出在仓颉里是进程级失败（不可 `catch`），且这是纯 DTD 层，与 `maxElementDepth` / `maxDepth` 的保护完全无关。实体递归有 16 层硬限（`EntityExpander.cj:54`）、参数实体有 `maxDepth`（`:427`），同一文件里的内容模型递归却没有任何上限——同一类风险只堵了两条路径。
- **建议**：给 `parseGroup` 增加 `depth: Int64` 形参（或复用 `EntityLimits.maxDepth`，16 层对内容模型也够，`DocBook` 最深处不足 10 层），超限抛 `XmlException(..., kind: EntityLimitKind.Depth)`；或改为显式栈迭代。用例：1000 层 `(` 嵌套应报 `XmlException` 而不是崩溃；顺带补 `(#PCDATA` 出现在深层分组的既有错误路径（`:642-644`）。

### [一般][存量] #3 数字字符引用解析在 5 处重复，其中 3 份缺溢出钳制 → `OverflowException` 逃出 `XmlException` 契约

- **位置**：`f_xml/src/DoctypeParser.cj:562-584`（`appendReference` 的 `&#…;` 分支，累加在 `:569`）、`:893-913`（`parseAttributeReference`，累加在 `:900`）、`:1036-1054`（`expandCharRefs`，累加在 `:1044`）；对照有钳制的实现 `f_xml/src/EntityExpander.cj:326-342`（`:337-339` `if (cp > 0x10FFFF) cp = 0x110000`）与 `f_xml/src/Lexer.cj:427-430`
- **来源**：存量（工作区快照）
- **判据**：review-checklist §2「字面量复制 / 近似重复，其中一块少了边界判断」+ §11「错误处理缺失：抛出契约外的异常类型」
- **证据**：静态确定 —— 这几段代码逐行同构（`hex` 判定、`cp = cp * base + digit`、`digits` 计数、`;` 与 `isXmlChar(cp)` 校验），5 份副本里只有 `Lexer.readReference` 与 `EntityExpander.expandInto` 做了溢出钳制。溢出行为有权威依据：整数算术溢出抛 `OverflowException`（`<: ArithmeticException <: Exception`，`cangjie-doc/1.3.0/libs/std/core/core_package_api/core_package_exceptions.html`「算术运算溢出异常」；`--int-overflow` 默认 `throwing`，见 `dev-guide/.../Appendix/compile_options`）。
- **描述**：`<!DOCTYPE a [<!ENTITY e "&#99999999999999999999;">]><a/>`（20 位十进制）在第 19 位数字处即越过 Int64 上限（9.22×10¹⁸），`cp * 10 + d` 溢出 → 抛 `OverflowException`，不带行号/列号，也不是 `XmlException`；按 `catch (XmlException)` 处理解析失败的调用方（`README.md:115` 承诺「正则/实体错误抛 `XmlException`」；fboot 的请求边界就是这种写法）会漏掉它，变成未处理异常。属性默认值（`:900`）与 `expandCharRefs`（`:1044`）同理。边界条件完全由输入决定，`&#` + 19 位数字 + `;` 共 23 个字符即可触发。
- **建议**：抽一个 `parseCharRef(runes, start) -> ?(cp, nextIndex)` 供这些副本复用，内部用 `EntityExpander` 已有的钳制写法（超过 `0x10FFFF` 直接判非法，不进 `isXmlChar`），把"非法字符引用"统一成带行列号的 `XmlException`。用例：20 位十进制、20 位十六进制、`&#xFFFFFFFFFFFFFFFFFF;` 三条都应得到 `XmlException`。

### [一般][存量] #4 编码嗅探把注释/正文里的 `<?xml … encoding=…?>` 当成真实声明 → 误判编码或误报 BOM 冲突

- **位置**：`f_xml/src/ByteSniffer.cj:280-315`（`findDeclaredEncodingInText`：`text.indexOf("<?xml")` 不锚定文档开头，也不排除注释 / PI 文本）、`:155-168`（`fromBom` 据此判定冲突并抛致命错误）、`:120-129`（无 BOM 分支据此选编码）
- **来源**：存量（工作区快照）
- **判据**：review-checklist §11「语义与命名/注释不符、契约不符」；XML 1.0 §4.3.3（`XMLDecl` 只能出现在文档最前，`encoding` 只在那一个位置有效）
- **证据**：静态确定 —— 函数只用 `indexOf("<?xml")` 找第一个出现位置，随后在 `?>` 之前找 `encoding`，没有任何"是否位于文档首部 / 是否落在 `<!-- -->` 或 `<?…?>` 数据里"的判断；扫描窗是 BOM 之后 1024 字节（`:120` 的 `4 + EXTRA_SCAN`），所以只要注释在头部就会命中。
- **描述**：两个可复现方向，都是合法文档被误判决：
  - 无 BOM（UTF-8 实际编码）：`<!-- <?xml version="1.0" encoding="GBK"?> --><a>中文</a>` → `sniff` 返回 `Other(GBK)`，`XmlPullParser` 用 GBK 解码后续字节。GBK 解码器对 UTF-8 字节多数情况能"成功"，于是变成静默乱码（比报错更难查）；遇到 GBK 非法序列时 `InvalidByteMode.Strict` 抛解码错误。
  - 有 UTF-8 BOM：同一内容 → `declaredConflicts(Utf8, "GBK")` 成立 → 抛「编码声明「GBK」与字节序标记确定的「UTF-8」冲突」，把一个完全合法的文档判成致命错误。
  日常最可能的触发形态是"注释掉的旧声明"（`<!-- <?xml version="1.0" encoding="GBK"?> -->`），在从 GBK 迁移到 UTF-8 的历史文档里很常见。
- **建议**：只在 `bomLength` 之后跳过纯空白后要求 `<?xml` 严格紧邻（即位置 0），或显式跳过 `<!--…-->` / `<?…?>` 后再判定；冲突检查只对"真正的声明"做。用例：注释内的伪声明 + 有/无 BOM 两条，期望编码均为 UTF-8 且不报错。

### [一般][存量] #5 `ByteScratch.nextId` 静态自增无同步：并发解析时的数据竞争

- **位置**：`f_xml/src/ByteScratch.cj:33`（`private static var nextId`）、`:40-43`（`init()` 里 `ByteScratch.nextId++; this.id = ByteScratch.nextId`）；同类实现 `f_xml/src/Lexer.cj:152`、`:172-176`（`Lexer.nextScratchId`，范围外提示，同一根因）
- **来源**：存量（工作区快照）
- **判据**：review-checklist §12.1「共享可变状态无保护：静态成员被多线程读写，无锁、无原子」
- **证据**：静态确定 —— 每个 `Lexer` 构造即创建一个 `ByteScratch`（`Lexer.cj:141`、`:172`），而解析器本身设计为多实例并发使用（`EntityCounterIsolation_test.cj:63-81` 就用 `spawn` 同时跑两个 `XmlPullParser`）。`++` 是非原子的读-改-写，两个线程同时构造会出现同号或丢号。
- **描述**：可观察后果限于 `nameScratchId` 的"实例数恒定"结构性断言（`BufferReuse_test.cj:103-147` 用它对拍），解析结果与业务行为不受影响，因此按后果记一般而非严重；但这是"测试钩子写在生产路径上"的典型——`id` 除了给测试看没有别的用途，却给并发调用引入了共享可变状态；一旦有人把 `id` 当缓存键，就会实质串数据。
- **建议**：改用 `std.sync.AtomicInt64` 的 `fetchAdd(1)`；更彻底的做法是把 id 发放移出生产代码（测试用 `refEq` 判断同一实例），`Lexer.nextScratchId` 一并处理。

### [一般][存量] #6 溢出读回器只在读到 EOF 时关闭：解析报错或提前放弃会泄漏临时文件与句柄

- **位置**：`f_xml/src/EntityExpander.cj:424-433`（`SinkFeed.fillTo` 仅在 `nextCp() < 0` 时 `this.reader.close()`）、`:354-361`；`f_xml/src/XmlPullParser.cj:56-60`（`close()` 只关输入流）
- **来源**：存量（工作区快照）
- **判据**：review-checklist §11「资源不对称：异常跳过释放」+ §5「长期持有（临时文件/句柄只增不减）」
- **证据**：静态确定 —— `FileExpandReader.close()` 是唯一删除溢出文件的入口（`ExpandSink.cj:371-384` 里 `file.close()` + `removeIfExists(path)`），而 `SinkFeed` 只在读到 EOF 时调用它；`Lexer.cj:227` 也只在正常读到 EOF 时 `feeds.remove`。`XmlPullParser.close()` 只对 `this.stream` 做 `resource.close()`，不遍历 `Lexer.feeds` 栈。
- **描述**：`Spill` 是默认策略。当文档在**已落盘的实体内部**出错（标签不匹配、非法字符、属性值超限等），或调用方拿到需要的事件后提前停止拉取、直接丢弃 `XmlPullParser`，栈上的 `SinkFeed` 不会被关闭：临时文件残留在 `TMPDIR/.fountain_tmp`、`File` 句柄不释放。对反复提交恶意文档的服务，这会累积成磁盘/句柄耗尽（注意 #1：当前生产路径其实不会落盘，一旦按 #1 修好接线，这条就会立刻变成现实路径）。
- **建议**：给 `ParserEngine`/`Lexer` 增加 `closeFeeds()`（逐个 `feed.close()`，`SinkFeed` 实现 `close()` 并转调 `reader.close()`），在 `XmlPullParser.close()` 与解析异常的统一出口处调用；`ExpandSink.close()` 的幂等语义可直接复用。补一条「实体落盘后文档报错，临时目录不残留」的用例。

### [一般][存量] #7 `<!ATTLIST>` 属性声明不计数、无上限：内存随 DTD 线性放大且无拒绝路径

- **位置**：`f_xml/src/DoctypeParser.cj:760`（`this.table.attTypes.declare(element, attribute, attType)`）、`:69-92`（`AttTypeMap` 无容量概念）
- **来源**：存量（工作区快照）
- **判据**：review-checklist §5「无界容器 / 上限写在哪里」
- **证据**：静态确定（无上限这一事实）；放大倍数为估算，需实测 —— `EntityTable.declare` 只对**实体**声明计数（`f_xml/src/EntityTable.cj:48-55`，`ordered.size + 1 > limit`），`attTypes` 完全在限额之外；`maxDeclarations` 的文档口径也只是「实体声明条数硬限制」（`XmlOptions.cj:91-92`）。
- **描述**：一条 `<!ATTLIST e a1 CDATA #IMPLIED>` 约 30 字节，会在 `HashMap<String, HashMap<String, AttType>>` 里产生一个元素名条目 + 两个 `String` + 一个内层 `HashMap` 条目。10 MB 内部子集约可写出 30 万条 AttDef，额外常驻数十 MB（约为输入的数倍到十倍），而这类输入不触发任何既有上限。`AttTypeMap` 的值只服务属性值规范化，用完即弃，却以「每个元素名一张子表」的结构持有到解析结束。
- **建议**：把 AttDef 计入同一个 `maxDeclarations` 预算（或在 `EntityLimits` 增 `maxAttDefs`），超限抛 `Declarations` 分类错误；若担心兼容性，至少给 `AttTypeMap` 加 `maxEntries` 并在超限时降级为「不规范化」（行为可预期，不 OOM）。

### [轻微][存量] #8 `AttType.toString()` 没有任何调用点（接口冗余，按硬原则不计死代码）

- **位置**：`f_xml/src/DoctypeParser.cj:27-61`（`internal enum AttType <: ToString`）、`:47-60`（`public func toString`）
- **来源**：存量（工作区快照）
- **判据**：review-checklist §1 说明（`ToString` 属接口实现 ⇒ **不判死代码**，只作可维护性/可见性建议）
- **证据**：静态确定 —— 全仓 `grep -rn "AttType" --include=*.cj .` 只命中 `f_xml/src` 内的 `declare` / `lookup` / `isTokenized` / `attTypeOf` / `AttType.Cdata` 等构造与比较，无任何 `toString` / 字符串插值调用；`AttType <: ToString` 这条约束目前只为该函数存在。`AttType` 是 `internal` 枚举，外部模块不可见。
- **描述**：`AttType` 只被 `Lexer.normalizeAttributeTypes`（`Lexer.cj:648-653`）用来判 `isTokenized()`，类型名从未出现在任何错误消息里。功能上无害，但多一个 `ToString` 约束会让"枚举值可以打印"变成无法验证的假设。
- **建议**：要么在当前（`internal`）范围内删掉 `ToString` 与 `toString`；要么在 `parseAttType` 的失败分支/属性类型相关的错误消息里真正用上它，让它成为活代码。对外 API 无影响。

### [轻微][存量] #9 `declarationPosition` 混用字节偏移与 rune 下标，报错列号偏大

- **位置**：`f_xml/src/ByteSniffer.cj:249-268`（`start = text.indexOf("<?xml")` 是字节偏移，`while (i < start && i < runes.size)` 的 `i` 是 rune 下标）
- **来源**：存量（工作区快照）
- **判据**：review-checklist §11「语义与实现不符」；API 依据 `std/core core_package_structs`「`String` 的 `size`、下标访问、切片和迭代均基于 UTF-8 编码后的字节」
- **证据**：静态确定 —— `indexOf` 返回字节下标，`runesOf` 返回按字符的数组，两者直接比较，当前缀含多字节字符时循环次数偏多，`column` 被多计 `字节数 − 字符数`。
- **描述**：只在 #4 的伪声明场景（`<?xml` 前有多字节注释）下暴露；正常声明位于 byte 0，偏差为 0。错误消息里的列号会偏大 1–2 位，不影响解析判定。
- **建议**：改在 rune 数组里定位 `<?xml`（`runesOf("<?xml")` 前缀匹配），或把 `start` 用 `text[0..start].runes().count()` 换算成 rune 下标。

### [轻微][存量] #10 `ByteSniffer.fill` 只是 `readUpTo` 的纯别名

- **位置**：`f_xml/src/ByteSniffer.cj:132-143`（`readUpTo`）、`:145-147`（`fill` 仅转调 `readUpTo(input, sink, total)`）
- **来源**：存量（工作区快照）
- **判据**：review-checklist §2「重复逻辑：函数体逐行对齐、只换名字，无额外语义」
- **证据**：静态确定 —— `fill` 的完整函数体是一次同名参数转发，没有任何额外判断、日志或错误处理；9 个调用点（`:80/84/88/92/96/103/107/111/115/120`）与 `readUpTo` 的语义完全一致。
- **描述**：多余的一层间接让"嗅探只读 1028 字节"这件事在读代码时要跳两次才确认，也让优化（见「优化可行性方案」#3）没有落点。
- **建议**：删掉 `fill` 直接调 `readUpTo`；或反过来让 `fill` 承载"一次分配 1028 字节缓冲、循环读到满或 EOF"的实现，`readUpTo` 只保留首 4 字节的用途。

### [轻微][存量] #11 DTD 内部子集的注释不校验 `--`，与文档级注释校验漂移

- **位置**：`f_xml/src/DoctypeParser.cj:362-366`（`<!--` → `skipUntil("-->")`）、`:415-424`（`skipUntil` 逐字符推进，只认终止符）；对照 `f_xml/src/Lexer.cj:920-946`（`readComment` 把第一个 `--` 当终止符并在其后不是 `>` 时报错）
- **来源**：存量（工作区快照）
- **判据**：review-checklist §11「与规格冲突：接受非良构输入」+ §2「近似重复导致的行为漂移」
- **证据**：静态确定 —— 文档级注释在 `--` 后不是 `>` 时直接抛「注释未闭合」（`Lexer.cj:926-935`）；`DoctypeParser.skipUntil("-->")` 要求完整 `-->`，于是 `--` 出现在中间时会被跳过并继续扫到真正的 `-->`，`<!DOCTYPE a [<!-- x -- y -->]><a/>` 通过，而同一段注释写在根元素里会被拒。
- **描述**：XML 1.0 §2.5 的 `Comment` 产生式不允许 `--` 出现在内容里，这是良构性（not-wf），不是有效性。`doc/xmlconf-unsupported.md` 的判定口径以 not-wf 为准，这类用例若出现在可跑集里会被误判为 pass；同时"同一种注释在文档不同位置规则不同"对使用者是隐性不一致。
- **建议**：让 `DoctypeParser` 复用 Lexer 的注释扫描（检查 `--`、`--->`、非法 `Char`），或把 `skipUntil` 换成带内容校验的 `readComment(decl)`。用例：`<!DOCTYPE a [<!-- x -- y -->]>` 期望报错，与 `<a><!-- x -- y --></a>` 对齐。

### [轻微][存量] #12 实体总量把"投影大小"与"逐层展开"重复计入

- **位置**：`f_xml/src/EntityExpander.cj:79-80`（`projected = this.expandedSize(name, 1)` 直接累加到 `counter.total`）；同一份内容在嵌套引用时又经 `:53-115` 的 `feed` 再记一次
- **来源**：存量（工作区快照）
- **判据**：review-checklist §11「语义与注释不符」——`:33` 的注释承诺「实体展开后的字符数（含嵌套）」
- **证据**：静态确定 —— `<!ENTITY e2 "abc"><!ENTITY e1 "&e2;&e2;">` 配 `<a>&e1;</a>`：`feed(e1)` 记 6（投影），随后词法器扫到两个 `&e2;`，各 `feed(e2)` 记 3 → `counter.total = 12`，真实展开量为 6。放大倍数约等于嵌套层数（≤ `maxDepth` = 16）。
- **描述**：投影判定本身是"毫秒级拦炸弹"的有意设计（`:76-80` 注释），所以只记轻微；但把投影**永久累加**进总量会带来两个副作用：`totalExpanded()`（`XmlPullParser.cj:72`，internal，测试/观测用）数值偏大；`Strict` 下真实展开约 512 KB 的合法文档可能提前触发 8 MB 的 `Total`。默认 `Spill` 下不抛错，故影响面窄。
- **建议**：`expandedSize` 只用于"这次是否越线"的判断，不进 `counter`；累加交给实际写出路径（`ExpandSink.write` 已按写出量累加）。若保留投影累加，则在注释里写明"含投影，可能大于实际展开量"。

### [轻微][存量] #13 `attributeArrayLengthIsExact` 的断言可能整体不执行

- **位置**：`f_xml/src/BufferReuse_test.cj:181-195`（三个规格循环，断言全在 `case XmlEvent.StartElement(...)` 分支内，`case _ => ()` 吞掉其余事件，没有兜底失败的断言）
- **来源**：存量（工作区快照）
- **判据**：review-checklist §3「空实现 / 断言缺失：调用方依赖的副作用没被验证」
- **证据**：静态确定 —— 若解析器对 `<r/>` 不产出 `StartElement`（回归时最可能的形态），循环体一条断言都不跑，用例仍然绿灯；同文件其它用例（`:167-177`）都写了 `case _ => assertTrue(false, ...)` 兜底，只有这条没有。
- **描述**：这是"测试自己变成空实现"的形态：断言数取决于被测行为是否发生，而用例名承诺的是"交付数组长度精确等于属性个数"。
- **建议**：先把所有 `StartElement` 收进 `ArrayList`，再断言 `collected.size == 1` 与 `attrs.size == spec[1]`；或补 `case _ => assertTrue(false, "未取到 StartElement")`。

### [轻微][存量] #14 `CharLayerParity_test.assertSame` 的 `inputFactory` 参数是死参数

- **位置**：`f_xml/src/CharLayerParity_test.cj:40-46`（`inputFactory: (Int64) -> InputStream`，`:41-43` 只用 `sizes` 传 `bufSize`）；调用点 `:52/67/74/84-86` 全部写成 `{size => MemoryInputStream(bytes)}`，`size` 未使用
- **来源**：存量（工作区快照）
- **判据**：review-checklist §1「读了不用 / 死参数」
- **证据**：静态确定 —— `assertSame` 在 `:41` 与 `:43` 两次调用 `inputFactory(size)`，而 6 个调用点传入的闭包全部忽略该实参（只捕获 `bytes`）；把形参删掉，闭包与全部断言都不变。
- **描述**：签名暗示"按 bufSize 构造不同的输入流"（例如按块边界切分的流），实际做不到；读者会误以为等价性覆盖了"分块输入流"这一维度。
- **建议**：签名改成 `() -> InputStream`；若确实想覆盖"分块流"，则用 `size` 构造一个每次 `read` 只返回 `size` 字节的 `InputStream`（与 `bufSize` 解耦），那才是这类等价性测试缺的一维。

### [轻微][存量] #15 `SinkFeed.peekCp` 对 offset ≥ 256 静默返回 -1（接口无偏移上界）

- **位置**：`f_xml/src/EntityExpander.cj:396`（`block = Array<Int32>(256, …)`）、`:408-443`（`fillTo` / `peekCp` / `exhausted`）
- **来源**：存量（工作区快照）
- **判据**：review-checklist §11「边界 / 契约脆弱」
- **证据**：静态确定（代码行为）+ 待确认（是否有调用者会超界）—— `fillTo(target)` 在 `len >= block.size` 时返回 `len - pos >= target`，`target > 256` 必然为 `false`，于是 `peekCp(offset>=256)` 返回 `-1`，与「EOF」无法区分。
- **描述**：`Lexer.peekCp` 会把 `remaining` 原样传给栈顶 feed（`Lexer.cj:197-204`），一旦出现长度 > 256 的前瞻匹配（`startsWith(text)` 的动态串），跨界处会被当成输入结束，表现为**静默截断**而不是报错。当前调用者的最大偏移约 10（`"<![CDATA["`、`kInlineNames` 最长 4、`SkipScanner` 最长 3），所以现在不可达。
- **建议**：`fillTo` 在 `target > block.size` 时扩容 `block`（或返回 `-2` 表示「偏移越界」并由 `Lexer` 抛内部错误），把「块大小」与「接口语义」解耦。

### [轻微][存量] #16 上限类错误的诊断位置为 `0:0`

- **位置**：`f_xml/src/EntityExpander.cj:184-190`（`expandedSize` 的 Depth 错误）
- **来源**：存量（工作区快照）
- **判据**：review-checklist §11「诊断信息缺失；与本模块自己的补偿口径不一致」
- **证据**：静态确定 —— 该处显式传 `0, 0`；而 `writeChecked`（`:378-390`）专门把 `line == 0 && column == 0` 的错误补上真实位置，说明「0:0 不可接受」是本模块自己的口径。`EntityTable.cj:49-54` 的 `Declarations` 错误同样传 `0, 0`。
- **描述**：17 层实体链（`EntityLimits_test.depthOverLimitRejected` 覆盖的场景）或声明数超限时，`XmlException.line/column` 为 0，调用方无法定位；现有用例只断言 `entityLimitKind`，所以没被发现。
- **建议**：`expandedSize` 增加 `line/column` 入参（`feed` 已有）；`EntityTable.declare` 的异常由 `DoctypeParser` 捕获后用 `positionAt(pos)` 补齐。

### [轻微][存量] #17 未声明实体的处置在三个类里各写一遍，`EntityExpander` 的两份不可达

- **位置**：`f_xml/src/EntityExpander.cj:64-69`、`:284-288`；对照 `f_xml/src/ParserEngine.cj:470-474`、`f_xml/src/Lexer.cj:1097-1100`
- **来源**：存量（工作区快照）
- **判据**：review-checklist §2（跨层复制的同一判定）+ §1（不可达分支）
- **证据**：静态确定 —— 两个调用点都先 `general(name).isNone()` 拦截并按 `EntityRefPolicy` 处置，之后才调 `feed()`/`expand()`；表在两次调用之间不会变化（同一解析器、单线程推进），因此 `EntityExpander` 里的 `policy` 分支永远不命中。
- **描述**：同一业务规则（未声明实体：报错 or 告警跳过）有三份实现，任一处改文案/改降级策略都可能漂移；`EntityExpander` 那份还让 `feed`/`expandInto` 多出一个 `?EntityRefPolicy` 依赖。
- **建议**：二选一——删除 `EntityExpander` 的 `policy` 分支（由调用方保证前置条件，并在注释里写明契约），或把判定收进 `EntityExpander`、调用方不再前置检查。

### [轻微][存量] #18 `xmlconf-unsupported.md` 统计表里 2062 与 2038 的差额没有说明

- **位置**：`f_xml/doc/xmlconf-unsupported.md:13-27`
- **来源**：存量（工作区快照）
- **判据**：review-checklist §13（文档口径不完整；数字可复算但缺解释）
- **证据**：静态确定 —— 表中「可跑集 2062」「参与判定的断言 2038」相差 24，`TYPE` 分布里正好 `error: 24`，但本文档没有任何一句说明「`error` 类不判定」；该口径只写在 `doc/spec/implement-f-xml-m1/baseline.md:20`（「`error` 不判定」）与 `design.md:557`。
- **描述**：读者按本表复算会得到「少算 24 条」的疑问。清单由 `f_xml/tools/xmlconf_gen.py` 生成（文件头注明「不要手改」），所以修点在生成器而不是本文档。
- **建议**：在「统计」表下补一行「其中 `error` 24 条不参与判定（2038 = 2062 − 24）」，由 `xmlconf_gen.py` 输出。

<!-- 第 5 部分 -->

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

<!-- 第 6 部分 -->

### [一般][存量] #1 同一模块存在两套互斥的性能门禁阈值，且旧门禁在同一进程里先测 10 MB 再测 50 MB

- **位置**：`f_xml/src/Perf_test.cj:554-580`（阈值在 `:571` / `:575` / `:576`）；对照 `f_xml/src/PerfTen_test.cj:75`、`f_xml/src/PerfFifty_test.cj:64`（后两个文件属第 5 部分）
- **来源**：存量（`git blame -L 554,580` 为 `5be2470bd2`（26 行）+ `ed671ce909`（1 行）；PerfTen/PerfFifty 侧为同一轮的后继实现）
- **判据**：review-checklist §14「接线缺失 / 只做了一半的分支」+ §11「契约与实现不符」；同一开关 `F_XML_PERF=1` 下两套判定对同一被测对象给出不同结论
- **证据**：静态确定 —— 三处阈值直接读代码即可比对
- **描述**：
  1. 10 MB 事件解析：`Perf_test.cj:571` 断 `min(3) < 7200 ms`，`PerfTen_test.cj:75` 断 `min(5) < 1000 ms`。3000 ms 的机器会「旧门禁通过、新门禁失败」。
  2. 50 MB 峰值：`Perf_test.cj:576` 断 `VmHWM ≤ 320 MB`，`PerfFifty_test.cj:64` 断 `VmHWM < 262144 kB（256 MB）`。300 MB 的机器同样一过一失。
  3. `Perf_test.gateTenAndFiftyMegabytes` 在**同一进程**内先跑 10 MB×3 再跑 50 MB×1，而 `PerfTen_test.cj:22-26` 明确写了「单独一个类是为了让门禁独占进程：`VmHWM` 是进程级单调峰值，同进程内先跑的 10 MB 会垫高 50 MB 的读数」。旧门禁用 `delta = hwm50 - hwm10` 试图补偿，但同一用例里还保留了绝对值断言（`≤ 320 MB`），补偿与绝对值混用，且绝对阈值被放宽到恰好掩盖污染量。
  4. `F_XML_PERF=1` 时三个用例同时执行，仓库里没有任何一处说明以哪个为准（旧用例也没有 `@Deprecated` 或注释标注被取代）。
- **建议**：二选一并二选一落文档 —— 删除 `Perf_test.gateTenAndFiftyMegabytes`（保留 `syntheticStream*` 三个自检用例），或把它收窄成「只跑 1 MB 冒烟 + 打印」，阈值判定统一交给 `PerfTen_test` / `PerfFifty_test`。若要保留旧口径，至少在类注释里写清「阈值以 `PerfTen/PerfFifty` 为准，本用例只作历史对照」，并去掉绝对值断言。

### [一般][存量] #2 `BufferedRuneSource.ensureOwn` 在「部分解码 + 解码错误」时丢弃 `BlockFill.error`

- **位置**：`f_xml/src/RuneSource.cj:220-228`（判据行 `:222-228`）
- **来源**：存量（`git blame -L 208,231` 全部 24 行为 `4006c4c25d`）
- **判据**：review-checklist §11「错误处理缺失或静默」+ §3「`Result` 失败被丢弃是一般以上」
- **证据**：静态确定（丢弃动作）+ 待确认（被丢弃的错误是否会在下一次 `decodeInto` 重新抛出，取决于底层解码器抛异常后的状态）
- **描述**：`ensureOwn` 只在 `fill.count == 0` 时把 `fill.error` 存进 `ownError`：

  ```
  let fill = this.finishFill(this.decodeInto(block, this.ownLen, this.capacity - this.ownLen), block, this.ownLen)
  this.ownLen += fill.count
  if (fill.count == 0) { if (fill.error.isSome()) { this.ownError = fill.error } else { this.ownEof = true } }
  ```

  `fill.count > 0 && fill.error.isSome()` 时 `fill.error` 被直接丢弃，循环继续。内置两条路径（`Utf8RuneSource` / `BlockRuneSource` → `ByteDecoder`）在严格模式下是「抛错前不消费坏字节」，所以下一次 `decodeInto` 会重新抛同一错误并以 `count == 0` 落进 `ownError`，实际不丢；但 `decodeViaPull` 的路径（`CharsetRuneSource`、以及任何第三方 `BufferedRuneSource` 子类）依赖 `pull()` 抛异常后的可重入性 —— 若 `TextReader.read()` 抛异常后已跨过坏字符，则该错误永久丢失，表现为「文档被静默截断且不报错」。
  这与第 5 部分 #9（`LineWindow.fillOnce` 同样只在 `fill.count == 0` 时保留 `pendingError`）是同一根因的两处实例，合并时可归为一条。
- **建议**：把条件改为「有错就存」——`if (fill.error.isSome()) { this.ownError = fill.error } else if (fill.count == 0) { this.ownEof = true }`；`LineWindow.fillOnce` 同步改（`f_xml/src/LineWindow.cj:104-110`）。这样错误一定在消费到 `ownLen` 时抛出，不依赖解码器的可重入性。

### [轻微][存量] #3 三个零引用的测试辅助（`minOf` / `MemoryInputStream.consumed` / `JsonRecord.isNull`）

- **位置**：`f_xml/src/TestSupport_test.cj:141-147`（`minOf`）、`f_xml/src/TestSupport_test.cj:49-51`（`consumed()`）、`f_xml/src/TestDataRoot_test.cj:78-80`（`isNull`）
- **来源**：存量（`git blame`：`minOf` 与 `consumed()` 为 `9a74dcbe9f`，`isNull` 为 `d17d3f528e`）
- **判据**：review-checklist §1「非 public 符号在可预见范围内无引用」
- **证据**：静态确定 —— `grep -F "minOf" --include=*.cj f_xml/src` 仅命中定义处；`grep -F "consumed()"` 仅命中 `TestSupport_test.cj:49`；`grep -F "isNull"` 仅命中 `TestDataRoot_test.cj:78`
- **描述**：三者都在 `internal` 顶层声明里且模块内（含全部 `*_test.cj`）零调用。`MemoryInputStream` 的 `consumed()` 与 `TrackingInputStream.readCount` 功能重叠，但后者被 `XmlPullParser_test.cj:54` 使用，前者没有。`JsonRecord.get` 有 5 处调用（`XmlconfHarness_test.cj:74-76/183/185`），`isNull` 是它的未使用包装。
- **建议**：删除这三个成员；`consumed()` 若将来要用于「读了多少字节」的断言，届时再加（`readCount` 已覆盖同类需求）。

### [轻微][存量] #4 两处恒不可达的分支：`truncatedOrNone` 的 `truncatedReported` 与 `peekFast` 的第二个错误判断

- **位置**：`f_xml/src/RuneSource.cj:633-636`、`f_xml/src/RuneSource.cj:251-253`
- **来源**：存量（`git blame -L 626,641` 为 `9a74dcbe9f` / `d17d3f528e`；`peekFast` 段在 `:240-255` 内，为 `4006c4c25d` / `d17d3f528e`）
- **判据**：review-checklist §1「不可达语句 / 恒假分支」
- **证据**：静态确定 —— 两条都可由前置状态直接推出
- **描述**：
  1. `truncatedOrNone`：只有 `ensure(2)` / `ensure(4)` 返回 `false` 才会进入，此时 `eof == true` 且 `available < count`。第一次进入走 `truncatedReported = true` 分支并 `consume(remaining)`，`consume` 在 `pos == len` 时把 `pos/len` 双双归零 ⇒ 下次进入必然 `available() == 0`，先命中 `:630` 的 `return -1`。所以 `:633-636` 的「重复上报保护」永远走不到，`truncatedReported` 字段只被写、从不产生不同行为（注释声称的「只报一次」已由 `available() == 0` 保证）。
  2. `peekFast`：`:245` 的 `if (!this.ensureOwn(offset + 1))` 为假意味着 `ownLen - ownPos >= offset + 1`，即 `ownPos + offset <= ownLen - 1 < ownLen`，所以 `:251` 的 `ownPos + offset == ownLen` 恒假。
- **建议**：删掉 `:633-636` 与 `truncatedReported` 字段（或把 `truncatedReported` 改成对 `available()` 的显式断言，保留意图）；删掉 `:251-253`。

### [轻微][存量] #5 三组重复逻辑：性能计时循环、门禁开关读取、测试文本重复

- **位置**：`f_xml/src/Perf_test.cj:404-414` 与 `:426-436`；`f_xml/src/Perf_test.cj:378-383` 与 `:418-423`；`f_xml/src/TextScan_test.cj:31-34` 与 `f_xml/src/TestSupport_test.cj:247-255`
- **来源**：存量（`git blame`：前者 `1fd1dd35ca` / `5be2470bd2`，后者 `19e26c9c32`）
- **判据**：review-checklist §2「只改名字，函数体逐行对齐」/「纯别名包装」
- **证据**：静态确定 —— 函数体逐行比对
- **描述**：
  1. `runSyntheticPass(targetBytes, bufSize)` 与 `Perf_test.runOnce(targetBytes, bufSize)` 的函数体逐行相同（建 `SyntheticXmlStream` → 建 `XmlPullParser` → `nextEvent` 计数 → 返回 `(ms, events)`），差异只有 doc 注释；前者被 `SemanticPerf_test.cj:100` 与 `PerfTen/PerfFifty` 使用，后者只在本类内使用。
  2. `perfGateEnabled()`（顶层）与 `Perf_test.perfEnabled()`（私有方法）读同一个 `F_XML_PERF` 并做同一个 `== "1"` 比较；`Perf_test` 内部 2 处（`:555`、`:585`）走私有版本，`SemanticPerf_test` / `PerfTen` / `PerfFifty` 走顶层版本。
  3. `TextScan_test.repeatBlock(block, times)` 函数体只有 `repeatText(block, times)`，是纯别名；`repeatText` 已被 13 个测试文件直接调用。
- **建议**：`Perf_test` 内部改调 `runSyntheticPass` 与 `perfGateEnabled`，删掉两个私有副本；`repeatBlock` 删除并让 `TextScan_test` 直接调 `repeatText`。这三处合并只减代码、不改语义（`runs` 默认值、打印口径均不受影响）。

### [轻微][存量] #6 `Utf8RuneSource` 头注释仍称 Strict 档「走 `std.io.StringReader`」，实现两档都走 `ByteDecoder`

- **位置**：`f_xml/src/RuneSource.cj:300-303`（注释）对照 `f_xml/src/RuneSource.cj:309-317`（构造 `ByteDecoder(input, ByteCodec.Utf8Strict / Utf8Replace, bufSize)`）
- **来源**：存量（`git blame -L 298,306` 为 `9a74dcbe9f`，而构造器在 `d17d3f528e` 已改成 `ByteDecoder`）
- **判据**：review-checklist §11「语义与注释不符」/ §13「文档与实现漂移」
- **证据**：静态确定 —— 类注释列出的两条实现路径与构造函数实际使用的两条 codec 分支不是同一件事；模块内 `grep "StringReader"` 只命中 `Perf_test.cj:21/245/292`（读 `/proc`），`RuneSource.cj` 除该注释外无任何 `StringReader` 引用
- **描述**：注释说「`Strict` 走 `std.io.StringReader`，`Replace` 走自研 `ByteDecoder`」「两条路径互不替代」，实际 `strict` 只决定同一 `ByteDecoder` 里的 `ByteCodec.Utf8Strict` / `Utf8Replace` 分支。读注释的人会以为严格档不受自研解码器缺陷影响，从而在排查解码差异时找错方向。与第 2 部分 #1（spec 里「Strict 走 StringReader」的旧口径）同源，此处是源码侧未同步的实例，合并时可并入一条。
- **建议**：注释改成「两档共用 `ByteDecoder`，`strict` 只切换 `ByteCodec.Utf8Strict`（非法序列抛 `XmlException`）/ `Utf8Replace`（按 RFC 3629 maximal subpart 产 `U+FFFD`）」。

### [轻微][存量] #7 `RuneSource` 的前瞻偏移契约三处不一致：文档写 ≤4、实现接受 ≤8、越界静默当 EOF

- **位置**：`f_xml/src/RuneSource.cj:24-27`（类/接口文档「只保证 `offset ≤ 4`」）、`f_xml/src/RuneSource.cj:242-244`（`offset > 8` 直接 `-1`）、`f_xml/src/RuneSource.cj:274-281`（`peek` 把 `-1` 转成 `None`）
- **来源**：存量（`git blame -L 240,255` 以 `4006c4c25d` 为主，另含 `d17d3f528e` / `9a74dcbe9f` 各 1–4 行）
- **判据**：review-checklist §11「契约与实现不符」；与第 5 部分 #5（`LineWindow.peek` 对 `offset > 8` 静默 `None`）同一模式
- **证据**：静态确定 —— `LineWindow.peekFast` 自己的慢路径允许到 8（`LineWindow.cj:157/167`），说明真实上界是 8；文档写的 4 是 `<!--` / `<![CDATA[` 这类前缀长度，不是实现上界
- **描述**：三处口径互斥：（1）公开接口文档承诺 4；（2）实现支持 8，超过 8 返回 `-1`；（3）`peek(9)` 得到 `None`，与「流结束」不可区分，调用方无法把「看太远」和「到 EOF」分开。当前模块内 `RuneSource.peek/peekFast` 只被测试直接调用（生产路径统一走 `LineWindow`），因此影响面是「直接使用公开 `RuneSource` 的下游」，属于潜在而不是已发生的错判。
- **建议**：把接口文档改成「`offset ∈ [0, 8]`，超出范围返回 `None` / `-1`（与 EOF 同值，调用方不得用越界偏移探边界）」；若希望区分，另加 `Option` 版本或断言。至少让三处写成同一个数。

### [轻微][存量] #8 行列号只把 `LF` 当换行：CR-only 文档的解码错误行号恒为 1

- **位置**：`f_xml/src/RuneSource.cj:265-270`（`advanceFast` 只在 `cp == 0x0A` 时 `line++`）、`f_xml/src/RuneSource.cj:163-171`（`finishFill` 的 `decLine` 同样只认 `0x0A`）
- **来源**：存量（`git blame -L 163,171` 以 `4006c4c25d` 为主，另含 `9a74dcbe9f`）
- **判据**：review-checklist §11「语义与注释/规格不符」—— XML 1.0 §2.11 要求把 `CR` 与 `CRLF` 都归一成 `LF`，孤立 `CR` 是合法换行
- **证据**：静态确定（判定事实）+ 待确认（影响面：需要构造 CR-only 文档 + 坏字节才能看到）
- **描述**：`LineWindow.fillOnce`（`LineWindow.cj:96-105`）在填充时已把 `0x0D` 归一成 `0x0A` 并吞掉后继 `0x0A`，所以**词法器侧**报错行列号是对的；但字符源侧的两套游标（`line/column` 与 `decLine/decColumn`）看的是**归一前**的原始码点，只认 `0x0A`。后果：CR-only 文档（旧 Mac 换行）里，第 3 行的非法 UTF-8 字节会被 `positionedError`（`RuneSource.cj:186-196`）报成「第 1 行第 N 列」；直接使用 `RuneSource.position()` 的下游同样拿不到 CR 换行。CRLF 文档不受影响（`LF` 仍会重置列）。
- **建议**：`advanceFast` 与 `finishFill` 统一按 XML 1.0 §2.11 处理 `0x0D`（`CR` 记一次换行，`CRLF` 只记一次，用一个 `pendingSkipLf` 标志，与 `LineWindow` 的实现保持一致）；或直接把行列号职责上收，让字符源只报「已消费码点数」，行列号只由 `LineWindow` 计算。

### [轻微][存量] #9 `SkipScanner` 的结束标签只比较 `local`：前缀不同也判匹配，`depth > 0` 时完全不校验名字

- **位置**：`f_xml/src/SkipScanner.cj:47-52`（判据行 `:48` `if (name.local != startName.local)`）
- **来源**：存量（`git blame -L 47,49` 全部为 `7cd8b9d291`）
- **判据**：review-checklist §11「边界遗漏」；`skipElement` 是公开 API（`XmlPullParser.skipElement`），跳过期间的配对错误会被静默接受
- **证据**：静态确定 —— `<p:a> … </q:a>` 在 `depth == 0` 处 `local` 相同即 `return`，前缀不参与比较
- **描述**：`skipSubtree` 的 doc 已声明「只按深度配对」，`depth > 0` 不校验名字是有意取舍；但在 `depth == 0`（即将结束本次跳过）处既然已经调了 `readName()`，只比 `local` 会让前缀不匹配的结束标签也算配对，跳过早结束，随后主解析器在残留的 `</p:a>` 上再报错——错误位置指向「跳过结束后」而不是真正的失配处。触发需要构造前缀不一致的畸形输入，正常文档不受影响。
- **建议**：`depth == 0` 处比较 `(name.prefix, name.local)` 与 `startName` 的对应字段（`RawName` 已在手，比较成本可忽略）；或按注释的口径彻底不比名字、把 `readName()` 换成 `skipName()`，让行为与文档一致。

### [轻微][存量] #10 门禁的环境探测只在 Linux 生效，无 `/proc` 时 `gateEnvironmentOk()` 恒为真

- **位置**：`f_xml/src/Perf_test.cj:241-266`（`readProcMem`）、`:288-300`（`readProcText`）、`:303-319`（`cpuCount` 读不到返回 1）、`:322-328`（`loadAverage1` 读不到返回 0）、`:399-401`（`gateEnvironmentOk`）
- **来源**：存量（`git blame -L 398,401` 为 `1fd1dd35ca`）
- **判据**：review-checklist §11「错误处理静默」+ §14「接线缺失」（本文件的 10/50 MB 用例 `:554-580` 没有调用 `gateEnvironmentOk()`）
- **证据**：静态确定 —— 三个探测函数都以 `catch (_: Exception) → None` 收口，`gateEnvironmentOk` 在 `cpuCount() == 1`、`loadAverage1() == 0.0` 时判定为「环境合格」
- **描述**：非 Linux（或容器内 `/proc` 不可读）时：`nproc=1`、`loadavg1=0.0`、`load_bound=0.5`，`gateEnvironmentOk()` 返回 `true`，打印的 `load_bound` 也是假值；`PerfFifty_test` 至少还会因为 `hwm <= 0` 打印 `invalid` 并 `return`，而 `Perf_test.gateTenAndFiftyMegabytes` 只打印 `rss unavailable` 就继续做时间断言。第 5 部分 #20 已就「开关关闭即 return」记过一条，本条是环境探测侧的另一个入口，合并成一条「门禁在不可测环境下静默降级」也成立。
- **建议**：探测函数增加「不可用」与「值为 0」的区分（返回 `?Int64` / `?Float64`），`gateEnvironmentOk()` 在任一探测不可用时返回 `false`（判 invalid 而不是 ok）；`Perf_test.gateTenAndFiftyMegabytes` 在跑之前也调一次 `environmentLine()` + `gateEnvironmentOk()`（与 `PerfTen/PerfFifty` 对齐），或在注释里写明「本用例不设环境门禁，仅作历史对照」。

### [轻微][存量] #11 两处格式塌行：函数签名与函数体、注释与声明挤在同一行

- **位置**：`f_xml/src/XmlChars.cj:101`（`static func isDigit(r: Rune): Bool {        r >= r'0' && r <= r'9'`）、`f_xml/src/TestSupport_test.cj:229`（`/** … */internal func utf32beBytes(…`）
- **来源**：存量（`git blame`：`XmlChars.cj:101` 为 `19e26c9c32`；`TestSupport_test.cj:229` 为 `f3024e0e61`）
- **判据**：review-checklist §10「可读性 / 维护性」；`cjfmt` 会把这些行展开，说明它与工程格式化口径不一致
- **证据**：静态确定 —— 同一文件其余重载（`:104-106`、`:113-115`）都是标准缩进，只有这两处塌行
- **描述**：不影响编译与行为，但 `cjfmt` / diff / 代码检索时这两行与周围不一致；`XmlChars.cj:101` 还是 `XmlChars` 唯一一处「身体紧贴 `{`」的写法。
- **建议**：按 `cjfmt` 口径展开为多行（把 `r >= r'0' && r <= r'9'` 放回缩进体，`utf32beBytes` 的 doc 注释换行）。

<!-- 第 7 部分 -->

### [一般][存量] `setAttr` 覆盖带前缀属性时丢掉 prefix，序列化后属性脱离命名空间

- **位置**：`f_xml/src/XmlNode.cj:162-170`（关键行 165）
- **来源**：存量（`git blame` → `7cd8b9d291` 2026-10-29）
- **判据**：review-checklist §11「语义与命名 / 注释不符」「契约与实现不符」；§10 正确性
- **证据**：静态确定 —— 第 165 行重建属性时只带 `uri`：`QName(name, uri: this.attributes[i].name.uri)`，`prefix` 落到默认值 `None`（`QName.cj:53`：`init(local, prefix!: ?String = None, uri!: ?String = None)`）。`XmlWriter.ensureBinding`（`XmlWriter.cj:545-555`）对「有 uri 无 prefix」的属性不输出任何 `xmlns`，`literalName`（`XmlWriter.cj:526-531`）只输出 local 名。
- **描述**：对 `<x:item x:id="1">` 执行 `setAttr("id", "2")`（README.md:170 明确 setAttr 按 local name 匹配、会覆盖同名属性），结果是内存里 `name = QName(local:"id", prefix:None, uri:Some(u))`、序列化输出 `<item id="2">`。XML 规范下无前缀属性不属于默认命名空间，输出文档里该属性从「命名空间 u 的 id」变成「无命名空间的 id」，且不报任何错；同时 `attr(ns:local:)` 仍能在内存里命中它，内存与序列化结果不一致。
- **建议**：覆盖时保留原 `QName` 的三元组（`prefix` 与 `uri` 一并复制），只替换 `value`；顺带在 `ensureBinding` 对「attributes 里 uri 有值但 prefix 为 None」显式抛错或补 `xmlns`，不要静默降级。

### [一般][存量] `CdataMode.Auto` 与 `Never` 行为完全相同，README 承诺的「自动选择」未实现

- **位置**：`f_xml/src/XmlWriter.cj:434-437`；`f_xml/src/XmlWriterOptions.cj:47-53`
- **来源**：存量（`git blame` → `7cd8b9d291` / `9066e1cd77`）
- **判据**：review-checklist §14.1「承诺了但没实现」「只做了一半的分支」；§3 空实现（分支无差别）
- **证据**：静态确定 —— `case CdataMode.Auto | CdataMode.Never => Escaper.escapeText(...)` 两个枚举值走同一分支；全仓 `CdataMode` 仅此一处消费（`grep -rn "CdataMode" f_xml/src` 只命中 `XmlWriter.cj:434-436` 与选项定义）。
- **描述**：`XmlWriterOptions.cj:48-53` 把 `Auto` 注释为「常规转义，不产 CDATA」、`Never` 为「强制转义，即使内容适合 CDATA」（隐含 Auto 在合适时会选 CDATA）；README.md:363 更直接写「自动选择」。实际两条路径完全一致，`Never` 是无效开关，`Auto` 未实现承诺的自动判定。调用方按 README 选 `Auto` 得不到任何 CDATA 优化。
- **建议**：二选一——(a) 实现 `Auto`（例如按「特殊字符占比 / 是否含 `]]>`」选择 CDATA），(b) 若确定永不自动选，删掉 `Never` 或把三个模式的文档改成「Auto ≡ Never」并在 README.md:363 同步；两种改法都要补一条 Auto/Never 差异用例。

### [一般][存量] `XmlElement.toString()` 未转义文本与属性值，与 README「输出紧凑 XML」冲突

- **位置**：`f_xml/src/XmlNode.cj:251-267`（文本经 `XmlNode.toString` `:35-44` 原样返回；属性经 `XmlAttribute.toString`）
- **来源**：存量（`git blame` → `7cd8b9d291`）
- **判据**：review-checklist §11「与规格 / README 冲突」；§13 判据要求两边位置
- **证据**：静态确定 —— `XmlNode.cj:38` `case TextNode(t) => t`、`XmlNode.cj:42` `case EntityRefNode(name) => "&${name};"` 均无转义；`XmlAttribute.toString`（`QName.cj:82-84`）是 `'${this.name}="${this.value}"'`，值未转义。承诺源：README.md:173「`toString()` 输出紧凑 XML（不缩进）」。
- **描述**：`XmlElement("a").withText("a<b & c")` 的 `toString()` 产出 `<a>a<b & c</a>`，既非良构也不可回读；属性值含 `"` 时直接截断属性。这是公开 API 且被文档描述为「XML」，容易被当成序列化入口使用（例如日志、模板拼装），属注入面。
- **建议**：`toString()` 内部改走 `Escaper.escapeText` / `escapeAttribute`（或直接复用 `XmlWriter` 的紧凑模式）；若坚持保留「调试渲染」语义，则改名（如 `debugString()`）并在 README.md:173 与 KDoc 写明「不转义、不是 XML」。

### [一般][存量] `writeDeclaration` 只校验「只写一次」，不校验「必须在任何元素之前」

- **位置**：`f_xml/src/XmlWriter.cj:167-181`
- **来源**：存量（`git blame` → `9066e1cd77` 2026-10-30）
- **判据**：review-checklist §11「契约与实现不符」；§3「公开契约承诺有行为，实现缺失」
- **证据**：静态确定 —— KDoc `:167` 写明「只能调用一次，且必须在任何元素之前」，实现只检查 `declarationWritten`（:175-178），没有任何 `frames.size > 0` 的判断。
- **描述**：`startElement(a)` 之后调用 `writeDeclaration()` 会往尚未闭合的 start tag 里追加 `<?xml version="1.0"?>` 与换行，输出 `<a<?xml ...?>`，不可回读；且不抛错，调用方无从发现。
- **建议**：`writeDeclaration` 开头加 `if (this.frames.size > 0) { throw XmlException("XML 声明必须在任何元素之前") }`；补一条对应用例到 `XmlWriterIncremental_test.cj`。

### [一般][存量] `Doctype.isDeclared` 忽略 `parameter` 标记，参数实体能通过 strictEntities 校验

- **位置**：`f_xml/src/XmlWriterOptions.cj:92-99`；消费点 `f_xml/src/XmlWriter.cj:447-463`
- **来源**：存量（`git blame` → `7cd8b9d291`）
- **判据**：review-checklist §11「契约与实现不符」；§10 正确性（输出非法文档）
- **证据**：静态确定 —— `isDeclared` 只比较 `decl.name`，不检查 `decl.parameter`；`EntityDecl.parameter` 在 `XmlNode.cj:89` 明确定义为「参数实体（`<!ENTITY % name ...>`）」。
- **描述**：DTD 里只声明了 `<!ENTITY % p "x">` 时，`strictEntities = true`（默认）下写 `XmlEntityRef("p")` 不报错，输出 `&p;`——一般实体 `p` 并未声明，文档非法。默认配置即触发，且错误延后到下游解析器。
- **建议**：`isDeclared` 增加 `parameter` 过滤（或新增 `isGeneralEntityDeclared`），`writeEntityRef` 走后者；补「只声明参数实体 + strictEntities」用例。

### [一般][存量] `EntityDecl.toString()` 丢掉 publicId，而 `writeDoctype` 直接拿它拼内部子集

- **位置**：`f_xml/src/XmlWriterOptions.cj:110-116`；消费点 `f_xml/src/XmlWriter.cj:378-385`
- **来源**：存量（`git blame` → `7cd8b9d291`）
- **判据**：review-checklist §11「数据丢失 / 错误」；§13 文档承诺（`EntityDecl.publicId` 在 `XmlNode.cj:86` 是公开字段）
- **证据**：静态确定 —— 外部实体分支只输出 `SYSTEM "${this.systemId ?? ""}"`，`publicId` 从未参与；`writeDoctype` 对 `doctype.entities` 逐条 `decl.toString()`。
- **描述**：解析得到的 PUBLIC 外部实体（`EntityDecl(publicId: Some(p), systemId: Some(s))`）经 `XmlWriter.write(doc)` 输出成 `<!ENTITY e SYSTEM "s">`，PUBLIC 标识被静默丢弃；若只有 publicId 没有 systemId，则输出 `SYSTEM ""`，是非法声明。DTD 语义随往返改变。
- **建议**：`EntityDecl.toString()` 与 `Doctype.toString()` 补齐 publicId 分支（`PUBLIC "p" "s"`）、`NDATA` 未支持则显式拒绝；或让 `XmlWriter` 不再复用这个 lossy `toString`，改为专用序列化函数并加往返用例。

### [一般][存量] DOM 遍历与序列化递归无深度守卫（`maxElementDepth` 只作用于解析侧）

- **位置**：`f_xml/src/XmlNode.cj:240-249`（`collectText`）、`f_xml/src/XmlNode.cj:251-267`（`toString` 经 `XmlNode.toString :35-44` 互递归）、`f_xml/src/XmlWriter.cj:465-508`（`writeElement` / `writeNodeWithName`）
- **来源**：存量（`git blame` → `7cd8b9d291`）
- **判据**：review-checklist §4「无界递归 / 间接递归」；§11 边界
- **证据**：静态确定（无守卫）+ 待确认（平台栈上限）——解析侧有硬上限：`ParserEngine.cj:278` `if (this.stack.size + 1 > this.options.maxElementDepth) throw`（默认 4096），因此**解析产物**深度 ≤ 4096；但 `XmlElement` 是公开可变结构（`children: ArrayList<XmlNode>` 可自由 append），`text()` / `toString()` / `writer.write(element)` 对深度没有任何检查，递归层数 = 调用方构造的树深。默认栈大小未在本地文档检索到（`cangjie-doc-lookup` 的三个文档源对「线程栈大小」均 0 命中），故不给出具体字节数。
- **描述**：两类场景：(a) 手工构造 > 数千层的 DOM 后调 `toString()` / `write()`，栈溢出直接 abort（不是抛 `XmlException`）；(b) 解析 4096 层文档后 `toString()`，每层还额外分配一个 `StringGenerator`（`XmlNode.cj:252`），帧更大，是否已接近默认栈上限需实测。
- **建议**：`collectText` / `toString` / `writeElement` 改为显式栈迭代（数组保存待访问节点），或增加深度计数并在超限时抛 `XmlException`（复用 `maxElementDepth` 语义，writer 侧作为选项透传）；至少补一条「4096 层 + toString」的实测用例。

### [轻微][存量] 刷写门限判断散落三处，`close()` 内联了 `flush()` 的函数体

- **位置**：`f_xml/src/XmlWriter.cj:299-304`（`appendText` 内）、`:441-445`（`checkThreshold`）、`:283-284`（`close` 内联 `flushBuffer` + `output.flush`）
- **来源**：存量
- **判据**：review-checklist §2「表现形式不同的重复逻辑」（同一不变量多处实现，易漂移）
- **证据**：静态确定 —— `appendText` 与 `checkThreshold` 是同一段 `if (buffer.size >= FLUSH_THRESHOLD) flushBuffer()`；`close()` 重复了 `flush()` 的两行实现。
- **描述**：门限值改一次要动三处；`checkThreshold` 存在的原因是 `Escaper` 直接写 `buffer`、绕过了 `appendText`。目前三处一致，属可维护性问题。
- **建议**：`appendText` 改为 `this.buffer.append(text); this.checkThreshold()`，`close()` 改为先 `this.flush()`；一处定义门限逻辑。

### [轻微][存量] `encodeChecked` 的位置计数是「本次刷写块内序号」，消息里的「文本内第 N 个字符」跨块即错

- **位置**：`f_xml/src/XmlWriter.cj:336-350`
- **来源**：存量
- **判据**：review-checklist §11「语义与注释不符」（错误消息给出错误的定位）
- **证据**：静态确定 —— `position` 在 `for (r in text.runes())` 内自增，`text` 是当前 ≤16 KB 的刷写块（`flushBuffer` `:315` 传入 `buffer.toUtf8String()`），不是整个文本节点。
- **描述**：往 GBK 写 20 KB 文本、不可映射字符落在第二块时，报「文本内第 300 个字符」而实际是第 8000+ 个；块边界还随 `FLUSH_THRESHOLD` 与元素切分变化，用户无法据此定位。
- **建议**：文案改成「本段第 N 个字符」并同时给出 `buffer` 起始偏移，或由 `XmlWriter` 维护跨块累计字符数一并输出。

### [轻微][存量] `CDataNode` 从 `writeNode` 进入时元素名为空串，错误消息缺上下文

- **位置**：`f_xml/src/XmlWriter.cj:411-431`（`:416` 传 `""`）；`f_xml/src/XmlWriter.cj:502-507`（CData 落到 `_ => this.writeNode(node, depth)`）
- **来源**：存量
- **判据**：review-checklist §11「语义与命名 / 注释不符」（诊断信息与调用上下文不符）
- **证据**：静态确定 —— `Escaper.writeCData(text, elementName, buffer)` 用 `elementName` 拼「元素「X」」；`:506` 的兜底分支把 CData 交给 `writeNode`，`elementName` 变成 `""`。
- **描述**：元素内 CDATA 含非法控制字符时报「元素「」中…」，与同类文本错误（`writeText` 有正确元素名）不一致，排查时定位不到是哪个元素。
- **建议**：`writeNodeWithName` 为 `CDataNode` 单独分支并传 `elementName`；`writeNode` 的 `CDataNode` 分支只在无元素上下文（prolog/epilog）使用。

### [轻微][存量] 写侧对名称与内容零校验：未绑定前缀、注释里的 `--`、实体引用名都能直接写出去

- **位置**：`f_xml/src/XmlWriter.cj:557-591`（`ensureBinding`：`case None => ()` 静默跳过）、`:417-420`（注释原样拼接）、`:447-463`（`&name;` 原样拼接）；`f_xml/src/XmlNode.cj:53-55`（`XmlEntityRef` 工厂）
- **来源**：存量
- **判据**：review-checklist §10 安全性（外部输入未校验 / 注入面）；§11 边界
- **证据**：静态确定 —— 三点均无校验：`QName(local:"b", prefix:Some("p"), uri:None)` 会输出 `p:b` 而不产生 `xmlns:p`；`CommentNode("a--b")` 输出 `<!--a--b-->`（XML 禁止）；`XmlEntityRef("x><y")` 输出非良构片段。
- **描述**：解析器不会产出这类 QName / 内容，但 `XmlElement` / `XmlNode` 是公开可变 API，服务端把用户输入拼进注释、实体名或带前缀 QName 时，写出的文档非法，且错误在下游才暴露。
- **建议**：写侧统一入口做轻量校验：`ensureBinding` 遇 `prefix Some + uri None` 抛错；注释内容含 `--` 或结尾 `-` 抛错（或拆分）；`XmlEntityRef` 名称按 XML Name 规则校验。校验收紧前先确认现有调用方（f_svg / f_excel）是否依赖当前宽松行为。

### [轻微][存量] 六个同构编码判定函数，新增编码要同步改多处

- **位置**：`f_xml/src/XmlWriter.cj:84-107`
- **来源**：存量
- **判据**：review-checklist §2「只改类型名」（同形状、仅常量不同）；§10 可维护性
- **证据**：静态确定 —— `isUtf8` / `isUtf16Le` / `isUtf16Be` / `isUtf32Le` / `isUtf32Be` 各一行 `this.options.charset == Charsets.XXX`，`isWideUnicode` 再把前五个析取一遍。
- **描述**：这是数据表式的重复（charset → 家族），逻辑无实质差异；新增编码（如 UTF-7）要同时改判定函数与 `isWideUnicode`，漏一处就会导致 BOM 或往返校验走错分支。
- **建议**：`init` 里算一次 `let family = classify(charset)`（枚举 `Utf8 | Utf16Le | … | Other`），后续全部读该字段；`isWideUnicode` 简化为 `family != Other`。

### [轻微][存量] 选项结构无边界校验（`bufSize` / `maxElementDepth` / `maxAttributeValueLength` 允许 0 与负数）

- **位置**：`f_xml/src/XmlOptions.cj:141-155`
- **来源**：存量
- **判据**：review-checklist §11「缺少边界校验」
- **证据**：待确认 —— 构造体只赋值不校验；`maxElementDepth = 0` 会导致任何元素都抛「嵌套深度超过上限 0」（`ParserEngine.cj:278`），`bufSize = 0` 的下游行为需要看 `Utf8RuneSource` / `BlockRuneSource` 的读循环（本部分未覆盖）才能判定是报错还是死循环/截断。
- **描述**：错误配置的表现是「解析报奇怪的深度错」或「读到空白」，不是「配置非法」。属调用方错误，但库不拦。
- **建议**：`XmlParserOptions.init` 对三个字段做 `> 0` 断言（抛 `XmlException` 或 `IllegalArgumentException`），并补一条配置非法用例。

### [轻微][存量] 两处未使用 import

- **位置**：`f_xml/src/XmlParser_test.cj:21`（`Path` 未按名使用，仅 `join()` 隐式返回）；`f_xml/src/XmlWriterScratch_test.cj:21`（`getGCCount` 未使用）
- **来源**：存量
- **判据**：review-checklist §1「未使用的 `import`」
- **证据**：静态确定 —— `grep -n "Path" XmlParser_test.cj` 只命中 import 行；`grep -n "getGCCount" *.cj` 只命中 import 行。
- **描述**：构建告警噪声（`f_xml/doc/build-warnings.md` 一类的清单会累积这类条目），不影响行为。
- **建议**：删除两个符号；若 `getGCCount` 原本想用于「GC 次数」采样，则应真正加入 `scratchMeasure` 的输出。

### [轻微][存量] 测试断言弱化与 xmlconf 口径硬编码

- **位置**：`f_xml/src/XmlParser_test.cj:175`；`f_xml/src/XmlWriter_test.cj:104`；`f_xml/src/XmlconfHarness_test.cj:111-119`
- **来源**：存量
- **判据**：review-checklist §10 可测试性；§11「注释与实现不符」
- **证据**：静态确定 —— `assertTrue(d1.root?.text() == d2.root?.text())` 在两边都是 `None` 时恒真；`:104` 的 `text.contains("\n</a>")` 在同一表达式中重复出现（析取恒等于自身）；`XmlconfHarness_test` 注释称「只读缓存里的 `cases.json`」（`:27`）但 `:114-119` 往缓存目录写 `failures.txt`，且 `pass+known == 2038` / `unsupported == 524` 是套件快照常量。
- **描述**：前两处让用例在根节点缺失时也不会失败；xmlconf 套件一旦重新生成（新版本数据）就必然失败且提示指向代码而不是数据版本；只读挂载的缓存目录会让用例因写文件失败而挂。
- **建议**：`assertTrue` 改为先 `getOrThrow()` 再比较；删掉重复析取；把 2038 / 524 抽成 `tools/` 下的期望文件（与 `known-issues.json` 同源），`failures.txt` 写到 `target/` 或临时目录。

## 优化可行性方案

> 不是缺陷，是「还能更好」；无基线的方案只作待验证假设，不进 tasks。

<!-- 第 1 部分 -->

本部分 5 个文件全部是文档，**不构成堆内存 / CPU 优化对象**，本轮不产出优化方案（0 / 0）。#1 / #2 是缺陷修复而不是优化；#4 的 `unsafeBytes()` 复制成本已作为文档缺陷记录，没有改前 / 改后基线，按规则不写成优化方案、不进 `tasks.md`。文档中出现的性能数字（`README.md:434-438`、`doc/f_xml模块设计.md:2392-2422`）是已归档的验证数据，本轮未复跑，只进「待验证假设」。

<!-- 第 2 部分 -->

本部分不含代码，没有可执行的堆内存 / CPU 改造项，故本节为空。文档里唯一带性能含义的结论是 R5 的 16 384 档 −9.3%（`design.md:436-444`）：按 D5（`design.md:584`）与 spec「`bufSize` 实测与回填」的 `SHALL NOT 修改默认值`，它只能作为建议值记录，不能据此改默认行为；若要改默认值，须按 `performance-optimization.md` 的口径给出改前改后对照（同机、`-O2`、3 次 min、同输入），那属于代码变更而非文档修订。

<!-- 第 3 部分 -->

> 本部分没有新增可执行方案。文档已自带 `-O2` 同轮对照数据（10 MB `1026.4 → 497.0 ms`、`VmHWM(50 MB) 295 136 → 104 280 kB`），且 `design.md` §8 的 B1–B4 / M0–M4 阶梯在 `verification.md:53-58` 已记录「一级未用」。在没有新的 profile 数据前再提方案，只会变成无基线的猜测，按铁律只进「待验证假设」。

<!-- 第 4 部分 -->

> 本部分没有任何 profile / bench 数据，以下三条全部 `无基线`，只作为下一轮补数据的候选，**不进** `todo.md` / `tasks.md`。

### [堆内存] 内容位置的实体引用每次都复制整段替换文本

- **现状**：`EntityExpander.feed` 每处理一次 `&e;` 都做 `Int64(runesOf(value).size)`（`:77`，`Array<Rune>` 约 4 B/字符）与 `MemoryExpandReader(cps32Of(value))`（`:114`，`Array<Int32>` 另约 4 B/字符，两者内部都先建 `ArrayList` 再 `toArray`）。一个 60 KB 的实体，每次引用产生约 1 MB 短命对象（含 `ArrayList` 扩容），2 万次引用 ≈ 20 GB 累计分配（静态推算，非实测）。这些对象生命周期只有一次 `feed`，且 `sizes` 缓存已经证明"按实体名复用"是安全的。
- **方案**：`MemoryExpandReader` 改成持有 `String` + 游标，按 UTF-8 逐码点推进（`RuneSource` 已有同类解码逻辑可参考），去掉两个中间数组；若必须保留数组形式，则在 `sizes` 同级加一个有上限的码点缓存（键 = 实体名，容量上限 = `maxDeclarations`）。长度只需要"码点数"，可用 `value.runes().count()` 替代 `runesOf(value).size`。
- **预期**：单次引用分配从 ~2×4×N 降到 0（缓存命中）或一次性；GC 次数与峰值 RSS 下降幅度待测。
- **代价**：`MemoryExpandReader` 从 O(1) 下标变成带解码分支的游标，热路径可能略慢；缓存与实体表同生命周期，`maxDeclarations` 上限内可控。
- **验证**：`<!ENTITY e "…60000 字符…">` + `&e;` × 1e4，改前后同一 `-O2` 构建对比 `getAllocatedHeapSize()`、`cjprof heap` 峰值与 `cjpm bench` 中位数（≥5 轮）。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] `DoctypeParser.parse` 把整个内部子集复制成 `Array<Rune>`

- **现状**：`DoctypeParser.parse` 用 `runesOf(subset)`（`DoctypeParser.cj:136`）把 DTD 原文整体转成 `Array<Rune>`，ASCII 场景是 4× 放大；同一份文本在 `Lexer` 侧还有一份 `String`（`readInternalSubset` 的 `textScratch`）。10 MB 的 DTD ⇒ 约 40 MB 常驻 + 10 MB 原文。
- **方案**：DTD 语法全部是 ASCII（`Name` / 引号 / 括号 / `#PCDATA`），改为按 UTF-8 字节扫描、只在 `Name` 需要时解码非 ASCII 码点；或对大 DTD 走"分块 + 位置映射"（`positionAt` 已是按需 O(n)，可保留）。
- **预期**：DTD 内存从 4× 降到约 1×（外加 Lexer 那份），10 MB DTD 省 ~30 MB 峰值。
- **代价**：`peek` / `readName` / `startsWith` 等基础函数要重写为字节版，改动面大、回归面广；建议先加阈值旁路（> N MB 才走字节版）以降低风险。
- **验证**：10 MB 合成 DTD 的 `getUsedHeapSize()` / RSS 改前后对照，`-O2` 同输入。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `DoctypeParser` 的前缀比较每字符都重建一次 rune 数组

- **现状**：`startsWith`（`DoctypeParser.cj:181-192`）每次调用 `runesOf(value)`；`skipUntil`（`:415-424`）在注释 / PI 里**逐字符**调用 `startsWith("-->")` / `startsWith("?>")`，一个 100 KB 的 DTD 注释产生约 10 万次 3 元素数组分配；`parseStatements` 每条声明还要做 ~8 次关键字前缀比较（`:383-398`），2 千条声明 ≈ 1.6 万次分配。`startsWithKeyword`（`:195-203`）再叠一次 `runesOf(keyword)`。
- **方案**：把关键字与终止符提为 `static let` 的 `Array<Rune>` / `Array<Int64>` 常量（与 `Lexer.kCommentClose`、`kPiClose` 同法，`Lexer.cj:115-123`），`startsWith` 直接比较常量数组；ASCII 关键字可再退化到码点比较。
- **预期**：DTD 扫描的分配次数从"每字符一次"降到"每声明一次"；耗时占比需实测（DTD 通常只占整份文档的一小段）。
- **代价**：常量表增加少量常驻内存；无行为变化。
- **验证**：`cjpm bench -O2`，输入为"2000 条声明 + 100 KB 注释"的 DTD，改前后 ≥5 轮中位数；`cjprof record` 看 `startsWith` / `runesOf` 自耗时占比。
- **证据状态**：`无基线（待验证，不进 tasks）`

<!-- 第 5 部分 -->

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

<!-- 第 6 部分 -->

> 以下均无改前基线 + 改后对照，**不进 `todo.md` / `tasks.md`**，只作下一轮补数据的候选。

### [堆内存] `parse(text)` 入口把整份文本复制成字节数组，峰值多一份输入

- **现状**：`TextInputStream(text)` 在构造时执行 `text.toArray()`（`f_xml/src/PrefixStream.cj:25-27`），此后整个解析期间同时持有原 `String` 与等价 `Array<Byte>`；`XmlPullParser.init(text:)`（`XmlPullParser.cj:37`）把它挂到 `private let stream` 上，生命周期 = parser 生命周期。1 MB 文档 = 多驻留约 1 MB；10 MB = 约 10 MB。
- **方案**：给 `parse(text)` 路径换成「按码点游标的 `InputStream` 适配」或直接让 `ParserEngine` 接受 `String` 源（`text.runes()` 迭代器 + 少量环形缓冲），不再 `toArray()`；`XmlParser.parse(bytes)` 路径保持不变。
- **预期**：`parse(text)` 峰值下降约 1 份输入大小（1 MB 输入约 −1 MB，10 MB 输入约 −10 MB）；解析吞吐不变。
- **代价**：需要一个 `String` → 码点块的新适配器（或复用 `LineWindow` 的填充接口）；`TextInputStream` 的 `init(data:)` 分支仍被 `XmlParser.cj:34` 使用，不能整体删除。
- **验证**：同一 10 MB 文本分别走 `parse(text)` 与 `parse(bytes)`，多轮取 `getAllocatedHeapSize()` 峰值 + RSS 稳态；断言字节结果与事件日志逐行一致（`PushPullParity_test` 的样本集可直接复用）。
- **证据状态**：无基线（待验证，不进 tasks）

### [CPU] `finishFill` 对每个已解码码点再做一次换行扫描，只服务罕见的错误定位

- **现状**：`f_xml/src/RuneSource.cj:163-171` 在**每次块填充**后遍历 `fill.count` 个码点，只为推进 `decLine/decColumn`；这两个游标唯一的消费点是 `positionedError`（`:186-196`），即只有解码异常时才需要。等于在热路径上给每个字符再加一次「比较 + 分支 + 计数」，输入越大浪费越多。
- **方案**：把「块内换行数」与「最后一个换行后的偏移」交给 `ByteDecoder.decodeBlock` 顺手统计（它本来就在逐字节走），或在块内只记 `fill.count` 与首码点位置，等真正出错时再对当前块做一次局部回扫（错误路径慢一点无妨）。
- **预期**：省掉一次全量遍历（每字符 1 次比较 + 1 次分支 + 2 次字段写），量级待侧。
- **代价**：`decLine/decColumn` 的推进点从「填充时」挪到「报错时」，需要保证并发/重入语义不变（当前是单解析器单线程，风险低）；错误位置必须逐点对齐（`InvalidByteMode_test` 已有 `1:5` 这类精确断言可作回归）。
- **验证**：`cjpm bench -O2` 同输入（10 MB / 50 MB 合成流）改前改后各 5 轮取中位数；同时跑 `InvalidByteMode_test` / `TextScan_test` 的错误位置断言。
- **证据状态**：无基线（待验证，不进 tasks）

### [CPU] `ByteReader` 的双缓冲让每次 `fill` 多一次整块 `memcpy`

- **现状**：`f_xml/src/RuneSource.cj:752-782` 每次 `fill()`：先把未消费尾部搬到 `buf[0..]`（拷贝 A），再 `input.read(scratch)`（读入第二块缓冲），再把 `scratch` 的前 `n` 字节拷进 `buf`（拷贝 B）。`buf` 与 `scratch` 各占 `bufSize`（默认 8 KB × 2）。1 MB 输入约 128 次填充 ⇒ 约 1 MB 尾部搬运 + 1 MB scratch→buf 拷贝。
- **方案**：`read` 直接读进 `buf[len..]`（`Array` 支持带偏移视图或按长度切片），只在 `len == buf.size` 且 `pos > 0` 时才压缩；压缩仍按原逻辑。这样去掉拷贝 B，拷贝 A 也只在必要时发生。
- **预期**：每 MB 输入少一次全量 `memcpy`，另省 `scratch` 的 `bufSize` 常驻（每解析器 8 KB，默认值下占比很小）。
- **代价**：`InputStream.read(Array<Byte>)` 只能整数组传入，若要读进 `buf[len..]` 需要一份 `bufSize - len` 的临时视图或改成分段读取；`bufSize < 单个字符宽度` 时的扩容分支要重新验证（`bufSize = 4/8` 的用例在 `RuneSource_test` / `TextScan_test`）。
- **验证**：`cjpm bench -O2` 10 MB 合成流改前改后 5 轮中位数；`RuneSource_test.assertFastParity` + `TextScan_test` 四档 `bufSize` 全绿。
- **证据状态**：无基线（待验证，不进 tasks）

<!-- 第 7 部分 -->

> 都不是缺陷，是「还能更好」。本部分没有改前/改后对照数据，全部为 `无基线（待验证）`，不进修复清单。

### [堆内存] 每次刷写都复制一个 16 KB 切片

- **现状**：`flushBuffer`（`XmlWriter.cj:310-313`）执行 `this.output.write(this.buffer.bytes()[0 .. this.buffer.size])`。`ByteScratch.bytes()`（`ByteScratch.cj:103`）返回**底层数组本体**（容量可能大于 `size`），因此必须切片；按 std 文档 `Array.[](range)` 返回切片数组，即每块都新分配一份 ≤16 KB 的临时数组并立即丢弃，总量 ≈ 输出字节数。
- **方案**：给 `ByteScratch` 增加 `writeTo(output: OutputStream)`（内部用一次缓存好的 trimmed 数组或 unsafe 视图），或让 `OutputStream` 侧支持「数组 + 长度」；`XmlWriter.flushBuffer` 的 UTF-8 分支直接调用。
- **预期**：UTF-8 大文档写的临时分配从 ~N 字节降到 ~0（N = 输出字节数），减少 GC 次数；对短文档无感。
- **代价**：`ByteScratch` 需要新的零拷贝出口，且必须保证 `write` 同步消费（`OutputStream.write` 是同步契约，可行）；`unsafe` 用法需注释。
- **验证**：`cjpm bench -O2` 写 100 MB 文档，对比 `getAllocatedHeapSize()` 增量与 GC 次数（`XmlWriterScratch_test` 的 `scratchMeasure` 已有可复用骨架）；同时确认 RSS 峰值不升。
- **证据状态**：无基线（待验证，不进 tasks）

### [堆内存] 每个元素写属性时 `attributes.toArray()` 复制一次

- **现状**：`declareNamespaces(element)`（`XmlWriter.cj:541-543`）为把 `ArrayList<XmlAttribute>` 传给 `declareNamespacesFor(name: QName, attributes: Array<XmlAttribute>)`，先 `element.attributes.toArray()`——每个元素一次 O(属性数) 的新数组分配，写 N 个元素就是 N 次。
- **方案**：`declareNamespacesFor` 改为接受 `ArrayList<XmlAttribute>`（或迭代器/只读视图），增量路径（`:195` 已是数组）与整树路径共用一个重载。
- **预期**：削减「每元素一次数组分配」，元素数 10 万级时是 10 万次短命分配；与属性数成正比。
- **代价**：两个重载或引入轻量只读接口；调用点极少（2 处），改动面小。
- **验证**：同一 100 万元素文档，对比分配总量与 `cjprof` 中 `ArrayList.toArray` 的自耗时占比；确认输出逐字节不变（`BufferReuse_test` 已有对拍）。
- **证据状态**：无基线（待验证，不进 tasks）

### [堆内存] 单个巨大文本使缓冲峰值等于该节点大小

- **现状**：`appendText`（`XmlWriter.cj:299-304`）先整串 `buffer.append(text)` 再判门限。`ByteScratch` 只增不减（`ByteScratch.cj:20-21`），因此写入一个 100 MB 文本节点时缓冲容量涨到 ~100 MB 并在 writer 生命周期内常驻；门限 16 KB 只限制「块数」，不限制「单块大小」。
- **方案**：`Escaper.escapeText/escapeAttribute/writeCData` 已按 rune 写 `ByteScratch`，改为「每写满 ~8 KB 就 `writer.checkThreshold()` 一次」（把回调或输出缓冲下推一层），或在 `writeText` 里按 4 KB 前缀分段调用 Escaper。
- **预期**：缓冲峰值从「最大单节点大小」降到 ~16 KB 量级，与文档总大小无关；对大文本 + 大属性场景显著。
- **代价**：Escaper 需要能与 writer 的刷写协作（当前签名只接 `ByteScratch`），改动触及 3 个函数；分段不得切断 `&#13;` 之类转义序列（转义单元是完整写入的，天然满足）。
- **验证**：构造「单文本节点 = 50 MB」的用例，对比改前/改后 `getUsedHeapSize()` 峰值与 RSS；确认字节输出不变。
- **证据状态**：无基线（待验证，不进 tasks）

## 待验证假设

<!-- 第 1 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | README 的「1 MB ≈ 58 ms / 10 MB ≈ 497 ms / 50 MB ≈ 2.47 s、`VmHWM(50 MB) = 104 MB`」在当前离线环境无法复核；是否仍与当前 HEAD 一致未知 | `f_xml/README.md:434-438`、`README_en.md:449-454` | 当前机器 `-O2` 交付构建的 5 次 `min`、`max/min` 离散度、`VmHWM` | 按 `doc/spec/complete-f-xml-m1-followups/baseline.md:87` 跑 `F_XML_PERF=1 cjpm test --filter=Perf`，并单独跑 `PerfTen_test` / `PerfFifty_test` 两个进程门禁 |
| 2 | 深层 DOM 的 `toString()` 为每个元素新建一个 `StringGenerator`，深树可能退化为 O(n·depth) 复制 | `src/XmlNode.cj:251-266`、`XmlNode.cj:35-47` | 10 MB、深度 1000/4000 的耗时与分配量 | 合成深树 + `cjprof record`，对照 `text()`（单 generator，`XmlNode.cj:234-249`） |
| 3 | 元素内重复属性检测是线性扫描，宽元素（上千属性）可能 O(a²) | `src/ParserEngine.cj:309-312`（`for (existing in seen)`） | 属性数 10/1000/10000 时的自耗时 | 合成单元素宽属性文档，`cjpm bench -O2` 对照 HashSet |
| 4 | `ExpandSink.write` 每次 `runesOf(segment)` 分配码点数组，在属性实体展开路径上放大分配量 | `src/ExpandSink.cj:150`、`src/XmlChars.cj:155-161` | 每次 write 的分配字节数、占总分配比例 | 对属性值实体展开跑 `cjprof heap`，与直接 `segment.size` 计数对照 |

<!-- 第 2 部分 -->

> 文档自带实测值（`design.md` §7.3 / §8.2、`verification.md` §2 / §3），本轮只读审查、未跑构建也未复测，因此这些数字只作线索。它们不计入模块统计，也不进 `todo.md`。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 10 MB 事件解析 `min(3) = 1101.8 ms` 仍成立 | `complete-f-xml-m1-followups/design.md:400`、`verification.md:36` | 同机 `-O2` 复跑值（文档为 2026-10-30、aarch64-linux、SDK 1.3.0） | `cd f_xml && F_XML_PERF=1 cjpm test --filter=Perf_test --show-all-output` |
| 2 | `VmHWM(50 MB) − VmHWM(10 MB) = 32 kB`、`VmHWM(50) = 288.1 MB` 仍成立 | `verification.md:13`、`design.md:405-407` | 目标机 `VmHWM` 绝对值与差值（受 GC / 分配器保留影响） | 同上，读 `/proc/self/status` 的 `VmRSS` / `VmHWM` |
| 3 | 16 384 档 10 MB 比 8192 快 9.3% 可复现（多轮中位数） | `design.md:440`、`verification.md:56` | 4 档 × 2 文档 × 3 次、≥3 轮的中位数与离散度；文档结论 `verification.md:59` 与同表数据矛盾（见 #3） | `--filter=Perf_test` 的 `bufSizeMatrix` 用例 |

<!-- 第 3 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 名字驻留表达到 `maxEntries = 65536` 后硬停插，若文档的唯一名字数超过上限（如每行名字都不同），驻留命中率崩溃、10 MB 耗时会回到 1 s 量级 | `f_xml/doc/spec/optimize-f-xml-semantic-layer/design.md:70-71`（上限与降级口径）、`f_xml/src/NameTable.cj:117` | 唯一名字数 ∈ {1k, 10k, 65k, 200k} 时的 `hits/misses` 与 10 MB 耗时曲线 | `cjpm bench -O2` 跑合成流（把 `<item>` 换成唯一名字），同时打印 `NameTable.distinct` |
| 2 | 长名字（> 256 B，触发 `ByteScratch` 扩容）下，名字驻留的收益被逐字节比对与扩容拷贝吃掉 | `design.md:133`（容量翻倍）、`:237-255`（`ByteScratch` 只增不减） | 名字长度 8 / 64 / 512 B 三档的分配量与耗时 | `F_XML_BENCH=1` 或 `cjprof record`，对比 `StringGenerator` 路径 |
| 3 | 文档记录的 497.0 ms / 104 280 kB 在当前 HEAD 仍成立（采集于 2026-10-30，之后 `f_xml` 又有 reuse-writer 与增量写入两次提交） | `f_xml/doc/spec/optimize-f-xml-semantic-layer/verification.md:11-14` | 当前 HEAD 的同轮值 | 空载机、默认运行时（`env | grep -iE '^cj(...)'` 为空），`F_XML_PERF=1 cjpm test --filter=PerfTen_test` / `--filter=PerfFifty_test`，各取 `min(5)` 与 `VmHWM` |

<!-- 第 4 部分 -->

> 没有性能测试数据支撑的猜测，**不进** `todo.md` / `tasks.md`，只用于下一轮补数据。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 每次实体引用 `runesOf` + `cps32Of` 造成分配量随"引用次数 × 实体长度"放大，GC 时间是该路径的主要成本 | `f_xml/src/EntityExpander.cj:77,114` | 分配字节数、GC 停顿占比 | 60 KB 实体 × 1e4 引用，`cjprof heap` + `getAllocatedHeapSize()`，`-O2` |
| 2 | `checkReplacement` 为每个含 `<` / `&` 的实体新建一套 `Lexer`（含 `NameTable` 初始槽数组），1024 条实体声明时固定开销可观 | `f_xml/src/EntityExpander.cj:139-141` | 每实体固定开销、总占比 | 1024 条 `<!ENTITY>` 的 DTD，`cjprof record` 看 `Lexer` 构造与 `checkReplacement` 自耗时 |
| 3 | `startsWith` / `skipUntil` 的逐字符 `runesOf` 是 DTD 扫描的主要分配来源 | `f_xml/src/DoctypeParser.cj:181-192,415-424` | 分配次数、自耗时占比 | 2000 声明 + 100 KB 注释的 DTD，`cjprof record` + 分配计数埋点 |
| 4 | `ByteSniffer.readUpTo` 每次 `read` 都新建一个"剩余长度"大小的数组，慢速输入流（每次 1 字节）下产生 1028 次递减分配 | `f_xml/src/ByteSniffer.cj:132-143` | 单次 sniff 的分配次数与字节数 | 用每次 `read` 只返回 1 字节的 `InputStream`，计数分配次数（`cjprof heap`） |
| 5 | `AttTypeMap` 的「每元素名一张 `HashMap`」结构造成显著内存放大 | `f_xml/src/DoctypeParser.cj:69-92` | 每条 AttDef 的实际字节数 | 10 万条 ATTLIST 输入，`getAllocatedHeapSize` 峰值对照「无 ATTLIST」基线 |

<!-- 第 5 部分 -->

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

<!-- 第 6 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `finishFill` 的逐码点换行扫描占解码侧自耗时的比例（猜测 5% 量级，未测） | `f_xml/src/RuneSource.cj:163-171` | 该函数自耗时占比 + 调用次数 | `cjprof record` 跑 `runSyntheticPass(50 MB)`；对照把循环注释掉的一版 |
| 2 | `ByteReader.fill` 的两段拷贝占 I/O 侧耗时比例 | `f_xml/src/RuneSource.cj:752-782` | 分段计时（`fill` 累计耗时 / 解析总耗时） | 在 `fill()` 首尾加 `MonoTime` 累计（仅测量构建），跑 50 MB × 3 |
| 3 | 非 UTF-8（GBK）路径每字符一次 `TextReader.read()` 的 `?Rune` 分配是 GBK 文档的主要成本 | `f_xml/src/RuneSource.cj:350-357`、`:140-155` | 分配次数 / GC 占比 / 吞吐对比 | `cjprof heap` + 用 `CharsetRuneSource` 跑 1 MB GBK 文档；与 UTF-8 同规模对比 |

<!-- 第 7 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 非 UTF-8 编码写路径 `encodeChecked` 的往返校验让 CPU ≈ 2 倍编码，是 GBK 大文档写出的主要成本 | `f_xml/src/XmlWriter.cj:325-356` | 自耗时占比（encode / decode / 比较三分） | `cjprof record` 跑 100 MB 中文文档 GBK 输出，`UTF8` 同输入做对照 |
| 2 | `flushBuffer` 的切片复制占 writer 总分配的显著比例 | `f_xml/src/XmlWriter.cj:310-313` | 分配量拆分（缓冲 vs 切片 vs encoder） | 复用 `XmlWriterScratch_test.scratchMeasure`，分别统计 `UTF8` 与 `GBK` 路径 |
| 3 | `Doctype.isDeclared` 的线性扫描在「实体声明多 + 引用多」时成为 CPU 热点（声明 ≤1024 × 引用数） | `f_xml/src/XmlWriterOptions.cj:92-99` | 引用条数、单次比较耗时、占比 | 造 1024 条声明 + 100 万次 `&e;` 引用（需 streaming API 支持，否则先埋点统计调用次数） |
| 4 | 解析 4096 层文档后调 `XmlElement.toString()` / `XmlWriter.write()` 是否已接近默认栈上限 | `f_xml/src/XmlNode.cj:251-267`、`f_xml/src/XmlWriter.cj:465-508` | 默认线程栈大小与每帧字节数 | 生成 4096 层文档，在 `spawn` 线程与主线程分别跑 `toString()`，观察是否栈溢出；同时查 SDK 文档确认默认栈值 |

## 文件覆盖

> 与 `files/f_xml.txt` 一一对应；分部分报告逐文件确认已读。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_xml/README.md` | .md | ✅ | — |
| 2 | `f_xml/README_en.md` | .md | ✅ | — |
| 3 | `f_xml/doc/build-warnings.md` | .md | ✅ | — |
| 4 | `f_xml/doc/f_xml模块设计.md` | .md | ✅ | — |
| 5 | `f_xml/doc/spec/complete-f-xml-m1-followups/baseline.md` | .md | ✅ | — |
| 6 | `f_xml/doc/spec/complete-f-xml-m1-followups/design.md` | .md | ✅ | — |
| 7 | `f_xml/doc/spec/complete-f-xml-m1-followups/proposal.md` | .md | ✅ | — |
| 8 | `f_xml/doc/spec/complete-f-xml-m1-followups/specs/f-xml-char-layer/spec.md` | .md | ✅ | — |
| 9 | `f_xml/doc/spec/complete-f-xml-m1-followups/specs/f-xml-conformance/spec.md` | .md | ✅ | — |
| 10 | `f_xml/doc/spec/complete-f-xml-m1-followups/specs/f-xml-dtd-entities/spec.md` | .md | ✅ | — |
| 11 | `f_xml/doc/spec/complete-f-xml-m1-followups/tasks.md` | .md | ✅ | — |
| 12 | `f_xml/doc/spec/complete-f-xml-m1-followups/verification.md` | .md | ✅ | — |
| 13 | `f_xml/doc/spec/implement-f-xml-m1/baseline.md` | .md | ✅ | — |
| 14 | `f_xml/doc/spec/implement-f-xml-m1/design.md` | .md | ✅ | — |
| 15 | `f_xml/doc/spec/implement-f-xml-m1/proposal.md` | .md | ✅ | — |
| 16 | `f_xml/doc/spec/implement-f-xml-m1/specs/f-xml-char-layer/spec.md` | .md | ✅ | — |
| 17 | `f_xml/doc/spec/implement-f-xml-m1/specs/f-xml-conformance/spec.md` | .md | ✅ | — |
| 18 | `f_xml/doc/spec/implement-f-xml-m1/specs/f-xml-dom/spec.md` | .md | ✅ | — |
| 19 | `f_xml/doc/spec/implement-f-xml-m1/specs/f-xml-dtd-entities/spec.md` | .md | ✅ | — |
| 20 | `f_xml/doc/spec/implement-f-xml-m1/specs/f-xml-stream-parser/spec.md` | .md | ✅ | — |
| 21 | `f_xml/doc/spec/implement-f-xml-m1/specs/f-xml-writer/spec.md` | .md | ✅ | — |
| 22 | `f_xml/doc/spec/implement-f-xml-m1/tasks.md` | .md | ✅ | — |
| 23 | `f_xml/doc/spec/implement-f-xml-m1/verification.md` | .md | ✅ | — |
| 24 | `f_xml/doc/spec/optimize-f-xml-semantic-layer/baseline.md` | .md | ✅ | — |
| 25 | `f_xml/doc/spec/optimize-f-xml-semantic-layer/design.md` | .md | ✅ | — |
| 26 | `f_xml/doc/spec/optimize-f-xml-semantic-layer/proposal.md` | .md | ✅ | — |
| 27 | `f_xml/doc/spec/optimize-f-xml-semantic-layer/specs/f-xml-semantic-layer/spec.md` | .md | ✅ | — |
| 28 | `f_xml/doc/spec/optimize-f-xml-semantic-layer/tasks.md` | .md | ✅ | — |
| 29 | `f_xml/doc/spec/optimize-f-xml-semantic-layer/verification.md` | .md | ✅ | — |
| 30 | `f_xml/doc/spec/reuse-f-xml-writer-scratch/design.md` | .md | ✅ | — |
| 31 | `f_xml/doc/spec/reuse-f-xml-writer-scratch/proposal.md` | .md | ✅ | — |
| 32 | `f_xml/doc/spec/reuse-f-xml-writer-scratch/specs/xml-writer-output/spec.md` | .md | ✅ | — |
| 33 | `f_xml/doc/spec/reuse-f-xml-writer-scratch/tasks.md` | .md | ✅ | — |
| 34 | `f_xml/doc/xmlconf-unsupported.md` | .md | ✅ | — |
| 35 | `f_xml/src/AttrNormalize_test.cj` | .cj | ✅ | — |
| 36 | `f_xml/src/BlockRuneSource_test.cj` | .cj | ✅ | — |
| 37 | `f_xml/src/BufferReuse_test.cj` | .cj | ✅ | — |
| 38 | `f_xml/src/ByteScratch.cj` | .cj | ✅ | — |
| 39 | `f_xml/src/ByteSniffer.cj` | .cj | ✅ | — |
| 40 | `f_xml/src/ByteSniffer_test.cj` | .cj | ✅ | — |
| 41 | `f_xml/src/CharLayerParity_test.cj` | .cj | ✅ | — |
| 42 | `f_xml/src/CharRef_test.cj` | .cj | ✅ | — |
| 43 | `f_xml/src/CharsetRuneSource_test.cj` | .cj | ✅ | — |
| 44 | `f_xml/src/DoctypeParser.cj` | .cj | ✅ | — |
| 45 | `f_xml/src/DoctypeParser_test.cj` | .cj | ✅ | — |
| 46 | `f_xml/src/DomBuilder.cj` | .cj | ✅ | — |
| 47 | `f_xml/src/DomBuilder_test.cj` | .cj | ✅ | — |
| 48 | `f_xml/src/DtdDeclSyntax_test.cj` | .cj | ✅ | — |
| 49 | `f_xml/src/EntityCounterIsolation_test.cj` | .cj | ✅ | — |
| 50 | `f_xml/src/EntityExpander.cj` | .cj | ✅ | — |
| 51 | `f_xml/src/EntityLimits_test.cj` | .cj | ✅ | — |
| 52 | `f_xml/src/EntityReplacementWf_test.cj` | .cj | ✅ | — |
| 53 | `f_xml/src/EntitySecurity_test.cj` | .cj | ✅ | — |
| 54 | `f_xml/src/EntityTable.cj` | .cj | ✅ | — |
| 55 | `f_xml/src/Escaper.cj` | .cj | ✅ | — |
| 56 | `f_xml/src/ExpandSink.cj` | .cj | ✅ | — |
| 57 | `f_xml/src/FormatSamples_test.cj` | .cj | ✅ | — |
| 58 | `f_xml/src/InvalidByteMode_test.cj` | .cj | ✅ | — |
| 59 | `f_xml/src/Lexer.cj` | .cj | ✅ | — |
| 60 | `f_xml/src/Lexer_test.cj` | .cj | ✅ | — |
| 61 | `f_xml/src/LineWindow.cj` | .cj | ✅ | — |
| 62 | `f_xml/src/LineWindow_test.cj` | .cj | ✅ | — |
| 63 | `f_xml/src/NameTable.cj` | .cj | ✅ | — |
| 64 | `f_xml/src/NameTable_test.cj` | .cj | ✅ | — |
| 65 | `f_xml/src/NamespaceScope.cj` | .cj | ✅ | — |
| 66 | `f_xml/src/NamespaceScope_test.cj` | .cj | ✅ | — |
| 67 | `f_xml/src/ParserEngine.cj` | .cj | ✅ | — |
| 68 | `f_xml/src/ParserError_test.cj` | .cj | ✅ | — |
| 69 | `f_xml/src/ParserState_test.cj` | .cj | ✅ | — |
| 70 | `f_xml/src/PerfFifty_test.cj` | .cj | ✅ | — |
| 71 | `f_xml/src/PerfTen_test.cj` | .cj | ✅ | — |
| 72 | `f_xml/src/Perf_test.cj` | .cj | ✅ | — |
| 73 | `f_xml/src/PrefixStream.cj` | .cj | ✅ | — |
| 74 | `f_xml/src/PrefixStream_test.cj` | .cj | ✅ | — |
| 75 | `f_xml/src/PushPullParity_test.cj` | .cj | ✅ | — |
| 76 | `f_xml/src/QName.cj` | .cj | ✅ | — |
| 77 | `f_xml/src/RuneSource.cj` | .cj | ✅ | — |
| 78 | `f_xml/src/RuneSource_test.cj` | .cj | ✅ | — |
| 79 | `f_xml/src/SemanticPerf_test.cj` | .cj | ✅ | — |
| 80 | `f_xml/src/SkipScanner.cj` | .cj | ✅ | — |
| 81 | `f_xml/src/SkipScanner_test.cj` | .cj | ✅ | — |
| 82 | `f_xml/src/SpillDirFallback_test.cj` | .cj | ✅ | — |
| 83 | `f_xml/src/SpillDir_test.cj` | .cj | ✅ | — |
| 84 | `f_xml/src/Spill_test.cj` | .cj | ✅ | — |
| 85 | `f_xml/src/TestDataRoot_test.cj` | .cj | ✅ | — |
| 86 | `f_xml/src/TestSupport_test.cj` | .cj | ✅ | — |
| 87 | `f_xml/src/TextScan_test.cj` | .cj | ✅ | — |
| 88 | `f_xml/src/WriterEncoding_test.cj` | .cj | ✅ | — |
| 89 | `f_xml/src/XmlChars.cj` | .cj | ✅ | — |
| 90 | `f_xml/src/XmlElement_test.cj` | .cj | ✅ | — |
| 91 | `f_xml/src/XmlEvent.cj` | .cj | ✅ | — |
| 92 | `f_xml/src/XmlEvent_test.cj` | .cj | ✅ | — |
| 93 | `f_xml/src/XmlException.cj` | .cj | ✅ | — |
| 94 | `f_xml/src/XmlNode.cj` | .cj | ✅ | — |
| 95 | `f_xml/src/XmlOptions.cj` | .cj | ✅ | — |
| 96 | `f_xml/src/XmlParser.cj` | .cj | ✅ | — |
| 97 | `f_xml/src/XmlParser_test.cj` | .cj | ✅ | — |
| 98 | `f_xml/src/XmlPullParser.cj` | .cj | ✅ | — |
| 99 | `f_xml/src/XmlPullParser_test.cj` | .cj | ✅ | — |
| 100 | `f_xml/src/XmlWriter.cj` | .cj | ✅ | — |
| 101 | `f_xml/src/XmlWriterIncremental_test.cj` | .cj | ✅ | — |
| 102 | `f_xml/src/XmlWriterOptions.cj` | .cj | ✅ | — |
| 103 | `f_xml/src/XmlWriterScratch_test.cj` | .cj | ✅ | — |
| 104 | `f_xml/src/XmlWriter_test.cj` | .cj | ✅ | — |
| 105 | `f_xml/src/XmlconfHarness_test.cj` | .cj | ✅ | — |
| 106 | `f_xml/src/f_xml.cj` | .cj | ✅ | — |

合计：`.cj` 72 个 / `.md` 34 个 / 共 106 个，全部读完。

## 覆盖自检

### 第 1 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 6 | 安全性 #1（Spill 承诺落空）/ #2（属性值 OOM）/ #3（上限单位）；设计 #5（公开 API 清单按修饰符而非可达性生成）；可读性 / 契约 #8 #12。语言特性维度：文档里的 `struct` / `class` / `enum` / `prop` / 命名参数逐条对照了 `src/`（`QName` 是 `struct`、`XmlNode` 是 `enum`、`XmlElement` 字段是 `let`），除 #8 外无错 |
| §1 死代码 | 2 | 文档侧按「引用的符号 / 文件是否存在」逐条核对：README「其他公开 API」的 9 个名字里 8 个不可达（#5）；设计引用的 `NameSyntax_test` 不存在（#9）。`build-warnings.md` 列的 6 个观测器均有定义与测试引用，不是死引用（按 §1「仅测试使用」属可见性建议）；设计里 M2/M3 的 `selectNodes` / `canonicalize` / `XPathContext` 明确标注「规划」，不计。**范围外提示**：`EntityExpander.cj:108-113` 是不可达分支（已作为 #1 证据引用，请第 4/5 部分确认并计入其统计） |
| §2 重复逻辑 | 0 | README.md 与 README_en.md 逐节对照（455 行 vs 471 行），章节、表格、示例、数字一一对应，只有 #11 一处术语漂移；设计 §2.2 与 §10.2 / §10.3 讲同一件事（不要依赖 Reader 的 peek），属分层论述，#10 只处理其排版断裂，不判重复。另：实体上限规则被复制在 `README.md:407`、`design:998`、`design:1312`、`design:1673`、`design:1952`、`design:2327` 六处，彼此一致但与实现不符 ⇒ 不是重复逻辑缺陷，但修 #1 时必须六处同步 |
| §3 空实现 | 1 | #1：Spill 机制在解析主路径未接线（`feed` 的溢出分支不可达、`ExpandSink.spill` 生产零调用） |
| §4 栈溢出 | 1 | #12：`XmlElement.toString()` / `text()` 逐层递归，而 README 把「深度 4096」写成整体安全边界。设计文档 §4 只说明「`DomBuilder` 不递归」，没有覆盖序列化。解析路径本身已核对：元素深度 `ParserEngine.cj:278-283`、实体递归 `EntityExpander.cj:54-61/274-281`、参数实体 `DoctypeParser.cj:426-433`，均有上限 |
| §5 OOM | 2 | #2（属性值全量物化 + 事后校验，默认策略下可放大到 2 GiB）；#3（硬限按码点计，非 ASCII 输入的实际内存上限高于文档承诺） |
| §6.1 热点瓶颈 | 0 | 没有 `cjprof` / `cjpm bench` 数据；README 的性能数字按「待验证假设 1」处理，不当结论 |
| §6.2 大粒度锁 | 0 | 本部分为文档，无锁代码可查；设计里也没有「锁内 I/O」类描述 |
| §6.3 并发串行 | 0 | 同上；文档层面唯一并发陈述是「计数器实例级」，与 `EntityCounterIsolation_test` 对得上，不构成串行热点 |
| §6.4 低效算法 | 0 | 文档里没有算法实现；#4 的 `unsafeBytes()` 复制是 API 成本语义，不是算法问题，已归 §13。`toString()` 与重复属性扫描两条候选无数据 ⇒ 待验证假设 2/3 |
| §7 降堆内存方案 | 0 | 本部分无代码可优化；#2 / #3 属缺陷修复，不作优化方案 |
| §8 降 CPU 方案 | 0 | 同上；`unsafeBytes()` 的复制成本（#4）缺基线，已列入待验证假设而非方案 |
| §9 local mode 可行性 | 0 | 这 5 个文件未提出 local mode 改造；`reuse-f-xml-writer-scratch/design.md` 引用了 `docs/LocalMode.md`，但该文件不在本部分清单，且无峰值内存数据，按规则不判 |
| §11 现有代码的 BUG（存量） | 2 | #1（软阈值语义 / 未接线）、#2（属性上限顺序）根因在代码，已用静态证据定位；详细代码级复审归属第 4~7 部分。`build-warnings.md` 的 21 条 WARNING 归因逐条核实，未发现未说明的告警 |
| §12 并发安全与锁粒度 | 1 | #12 的第二条：README 全文无「线程」字样，而设计（`:26`）明确 `XmlWriter` 单线程、解析计数器实例级。没有共享路径可判死锁 / 锁粒度 |
| §13 文档一致性 | 11 | #1 #2 #3 #4 #6 #7 #8 #9 #10 #11 #13 |
| §14 功能完备性与 README 覆盖 | 3 | #1（承诺的 Spill 未实现）、#5（公开 API 清单失真 + 三个字符源构造未登记）、#12（缺线程与递归深度两条限制）。逐项对照：`XmlParser` / `XmlPullParser` / `XmlDocument` / `XmlElement` / `XmlNode` / `QName` / `XmlAttribute` / `SourcePosition` / `XmlDeclaration` / `EntityDecl` / `DocTypeInfo` / `XmlEvent` / `XmlAction` / `XmlEventHandler` / `XmlWriter` / `XmlParserOptions` / `EntityLimits` / `XmlWriterOptions` / `Doctype` / `XmlException` / `EntityLimitKind` / `RuneSource` / `LineWindow` / `PrefixStream` / `BufferedRuneSource` 均在两版 README 中有落点（扣 #5 的漏项） |
| 文件覆盖（§13 等） | 5/5 | 无缺文件 |

### 第 2 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 0 | 本部分无代码。安全性按「文档承诺 → 实现」核对：外部实体永不加载、条件段仅外部子集、BOM 冲突致命、属性值不溢出、三层实体上限默认值，五条全部与实现一致（见「取证说明」）。设计层面只报文档间互斥（#1、#2） |
| §1 死代码 | 0 | 本部分无声明可判。反向做了等价检查：文档点名的 12 个内部符号（`decodeInto` / `readCodePointBlock` / `blocksFilled` / `codepointsYielded` / `hasOwnBlock` / `createFileFrom` / `EntityCounter` / `AttTypeMap` / `nextCp` / `totalExpanded` / `warnings` / `EntityLimitKind` 六值）全部在源码中命中，不存在「文档承诺但代码里没有」的空符号 |
| §2 重复逻辑 | 0 | 两份变更的 spec 有刻意复述（`f-xml-char-layer` 的「行拼接」「缓冲大小」被 followups 以 MODIFIED 重述），属增量文档的固定形态，不算重复缺陷；真正同义而不一致的部分已按「不一致」报在 #1（`spec.md:151` 与 `followups/design.md:242`）；R5 结论的三处副本已并入 #3 |
| §3 空实现 | 0 | 抽查 6 个「都有默认实现」的契约（`XmlEventHandler` 默认 `Continue`、`Span`/`Stop`、`EntityLimits` 默认值、`warnings()`、`AttTypeMap.lookup` 未声明属性回落 `Cdata`），实现均非空；`verification.md:85` 自报的「无运行期用例」是静态检查项，不是空实现 |
| §4 栈溢出 | 0 | 文档对两类递归都给的是有界常量：实体展开深度 `maxDepth = 16`（`XmlOptions.cj:105`）、元素嵌套 `maxElementDepth = 4096`（`:146`）；`design.md:388-397` 的「实体替换文本自身良构」校验由 `EntityExpander.checkReplacement` 实现。本部分无递归代码可判 |
| §5 OOM | 0 | 文档承诺的三条 OOM 防线逐条对到实现：三层上限 + 硬限 2 GB（`XmlOptions.cj:102-110`）、软阈值溢出到文件且切换单向（`ExpandSink.cj:85`）、属性值永不溢出（`ExpandSink.cj:160`）；事件模式 O(嵌套深度) 由 `readCodePointBlock` 单缓冲保证。未发现「承诺有界、实现无界」的文档；proposal 块容量漏上限已按 #7 报为文档缺陷 |
| §6.1 热点瓶颈 | 0 | 本轮无 profile / bench 数据（只读、不跑构建）。文档自带实测值未复测，已列「待验证假设」1–3；且 `verification.md:59` 的结论与自身数据矛盾（#3），不能直接当热点结论用 |
| §6.2 大粒度锁 | 0 | 本部分无锁相关代码；文档 `followups/design.md:501` 明确「`XmlPullParser` 实例不共享可变状态、不加锁」，已核到 `ParserEngine.cj:97` 的 `private let counter = EntityCounter()` 为实例字段、`f_xml/src/*.cj` 无其他 `static var`（除 `ByteScratch.cj:33` / `Lexer.cj:157` 的 id 自增，仅用于标识、不参与解析语义） |
| §6.3 并发串行 | 0 | 无并发代码 |
| §6.4 低效算法 | 0 | 文档描述的复杂度（块解码 O(n)、固定串匹配用预置 `Array<Int64>`）与实现一致；实际耗时归 §6.1，无数据不下结论 |
| §7 降堆内存方案 | 0 | 本部分无代码；文档里的内存数字（`VmHWM` 差值 32 kB）无复测数据，列入待验证假设 2，不写成方案 |
| §8 降 CPU 方案 | 0 | 同上；R5 的 16K 建议（#3 / 优化一节）是「记录值」而非可执行方案，且 spec 明文禁止改默认值 |
| §9 local mode 可行性 | 0 | 两份变更的产物全篇未涉及 local mode；本部分无函数内临时对象可评估，且无峰值内存前后对照 ⇒ 不成立即为「待验证假设」的前提都不满足 |
| §11 现有代码的 BUG（存量） | 0 | 本部分无代码可判；文档类缺陷（旧口径、数字、签名、口径）按 §13 统计在下方行，不与代码 BUG 混计。取证时顺带核到的实现细节（`decodeViaPull` 的异常延迟、`SpillDir.createFileFrom` 的 `continue` 语义、`CharsetRuneSource` 的逐字符 `Option` 例外）与文档一致 |
| §12 并发安全与锁粒度 | 0 | 文档承诺「计数器实例级、解析器实例不共享可变状态」已按 §6.2 行的方式核到；双线程用例 `EntityCounterIsolation_test.concurrentParsersDoNotShareCounter` 存在 |
| §13 文档一致性 | 8 | #1 旧 readln / StringReader 口径（4 个文件 8 处）、#2 Gate 基线、#3 验收结论与数据矛盾（2 处副本）、#4 构造器签名、#5 三处计数、#6 基准重复次数、#7 Purpose / 块容量公式、#8 吞吐单位 |
| §14 功能完备性与 README 覆盖 | 0 | 文档承诺的 8 项交付物全部落地：`tools/xmlconf_gen.py`、`tools/known-issues.json`（`[]`）、`doc/xmlconf-unsupported.md`（524 条、五个原因名齐备）、`Perf_test` / `CharLayerParity_test` / `SpillDirFallback_test` / `EntityCounterIsolation_test`、`tools/test_xmlconf_gen.py`；`doc/build-warnings.md` 存在且 6+15=21 条与 `design.md:16` 一致。`verification.md:63-122` 的 Scenario→用例表 23 条逐条命中，无「承诺但没接线」项；README 覆盖属 part1 |
| 文件覆盖（§13 等） | 11/11 | 清单 11 个文件全部读完；本部分没有 `.cj` |

### 第 3 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 11 | 正确性 #1 #5 #6 #7；设计 #2 #4 #11；语言特性 #13；可读性 #9 #12；安全性 #3。安全性另做专项取证：XXE 不读文件（`EntityExpander.cj:73,293`）、外部子集不发请求（全模块无网络 API，`File` 只用于 spill）、转义表逐格对齐（`Escaper.cj:25-63`）、非法字符拒绝带元素 / 属性名，均无新缺陷 |
| §1 死代码 | 0 | 本部分无 `.cj`，改做「文档引用的符号是否仍存在」：`QName`、`attr(ns,local)`、`child`、`childrenOf`、`setAttr`、`withText`、`text`、`prolog` / `epilog` / `declaration` / `doctype` / `root` 全在 `XmlNode.cj:162-234, 276-284` 命中；`StringWriter` 反向 0 命中即为 #2 的证据；未命中的 2 条路径已并入 #11 |
| §2 重复逻辑 | 1 | #8（同一 `unsafeBytes` 事实在两份 spec 里给出相反描述）。另逐条比对：五条排除规则在 spec / tasks / baseline / `xmlconf-unsupported.md` 头部 / `xmlconf_gen.py` 注释 5 处陈述，阈值与措辞一致（313/95/59/47/10、2586/2062/2038/524）；Gate 阈值在 baseline §2/§7、design §1.1、proposal F、semantic spec 4 处重复，`1000 ms` / `262144 kB` / `0.95` 一致（`256 MB` 与 `262 144 kB` 为等值换算，不判重复） |
| §3 空实现 | 1 | #4（Gate C 的清单存档动作缺失） |
| §4 栈溢出 | 1 | #3（`text()` / `writeElement` 递归无深度契约）；解析侧 `ParserEngine.cj:278` 按 `maxElementDepth` 检查、`DomBuilder.cj:27` 用迭代建树，已排除 |
| §5 OOM | 0 | 三层上限（64 KB / 8 MB 软，16 / 1024 / 2 GB 硬）与 `Spill` 溢出策略均为有界设计，默认值与 `XmlOptions.cj:103-108` 一致；`Spill` 下内存恒定、2 GB 上限落磁盘不落堆；未见「按不可信长度预分配」的规格承诺 |
| §6.1 热点瓶颈 | 0 | 本部分文档自带 `-O2` 同轮实测，本轮无新的 profile / bench，故不新增热点结论；未验证项进「待验证假设」#1–#3 |
| §6.2 大粒度锁 | 0 | 文档未承诺任何锁语义，`f_xml` 解析器为单实例单线程使用（计数器已实例化，`EntityCounterIsolation_test` 覆盖） |
| §6.3 并发串行 | 0 | 无 `spawn` / 任务提交相关承诺 |
| §6.4 低效算法 | 0 | 文档记录的批量扫描（`asciiRunLength` / `skipRun` / 掩码）与 `LineWindow` internal 块视图已在实现中落地（`design.md:259-343` 对照 `LineWindow.cj` 成员），规格与实现同向 |
| §7 降堆内存方案 | 0 | 现有方案（名字驻留 + 三缓冲复用 + 基准零分配）已有改前 / 改后数据（295 → 104 MB），无基线的新方案不写入本节 |
| §8 降 CPU 方案 | 0 | 同上（1026.4 → 497.0 ms 已达成）；B1–B4 阶梯未启用，缺数据前不列为方案 |
| §9 local mode 可行性 | 0 | `reuse-f-xml-writer-scratch/design.md:5-12` 已用实测否掉 `XmlWriter.flush` 的 local / 复用收益（313 B/次，无 16 KB 复制）；无新增可评估函数 |
| §11 现有代码的 BUG（存量） | 14 | 本部分全部 14 条均为存量文档缺陷（无 `.cj`）；每条均已给位置 / 判据 / 证据等级 |
| §12 并发安全与锁粒度 | 0 | 文档只承诺「计数器实例级、非全局」（dtd-entities spec §计数器实例级），与 `ParserEngine` 实例字段一致；无共享可变状态承诺 |
| §14 功能完备性与 README 覆盖 | 3 | #4（承诺的存档动作未实现）、#11（文件清单 / 入库规则过期）、#14（变更缺验收记录）；`README.md:417` 与 `XmlWriter.cj:42` 的「close 后不得再调用」与 spec 一致（但其「未定义行为」表述见 #12） |
| 文件覆盖（§13 等） | 16/16 | 无缺文件 |

### 第 4 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 7 | 正确性：#3（异常类型逃逸）、#4（编码误判）、#11（接受非良构注释）、#12（计数语义）、#16（诊断位置）；可读性：#9（行列号换算）、#10（多余别名）。安全性专项另核：外部实体「引用即报错、永不加载」（`EntityExpander.cj:73,293`）、外部子集不加载（`DoctypeParser` 无任何 IO，`SpillDir` 只被死分支引用）、BOM 与声明冲突按 §4.3.3 抛致命错（`:155-168`）、属性值不溢出（`ExpandSink.cj:154-174`）——XXE 面封死；未发现注入 / 越权 / 凭据问题 |
| §1 死代码 | 3 | #14（`inputFactory` 死参数）、#17（`EntityExpander` 的 `policy` 分支不可达）、#1 的 :108-113 恒假分支。机械核对：本部分 5 个生产 `.cj` 的 `private` 符号逐个全仓搜名，均有调用者（`putAscii`←`putCp`、`findDeclaredEncoding`←`sniff`、`isTokenized`←`Lexer.cj:652`、`attTypeOf`←`parseAttType`、`fill`←9 处）；`internal` 顶层函数 `expandCharRefs` / `attTypeOf` 在本包内均有引用；`SinkFeed` 的 5 个 `RuneFeed` 方法经接口被 `Lexer.cj:201,206,222,256` 使用；`public` 成员里 `ByteScratch.id`（←`Lexer.cj:172`）、`SniffResult.prefix`（←`XmlPullParser.cj:86`）均活；`AttType.toString` / `DetectedEncoding.toString` 属 `ToString` 接口实现，按硬原则**不判**死代码（#8 已降为可维护性建议） |
| §2 重复逻辑 | 3 | #3（`&#…;` 数字解析 5 份，其中 3 份缺钳制）、#10（`fill` 与 `readUpTo` 同体）、#17（未声明实体处置跨 3 个类复制）。已逐个比对本部分 5 个生产文件与 13 个测试文件的函数体（「输入-输出-副作用」摘要两两对照）：`readName` / `readNmtoken` / `readNameCharRun` 差异在首字符规则与是否允许空（业务要求，不合并）；`parseNameEnum` / `parseNmtokenEnum` 差异在 `Name` 与 `Nmtoken` 首字符（同上）；`decodeHead` 的 4 个分支差异在字节序（必要展开）；`expandCharRefs` / `checkDefaultEntityInto` / `expandedSize` 三处都在扫实体值里的 `&name;`，但输出分别是「展开后的串」「递归环检测」「长度」，差异是语义而非语法（建议抽公共迭代器，但不判重复缺陷）——均判为非重复 |
| §3 空实现 | 2 | #1（Spill 开关打开后走进不可达分支，功能未接线）；#13（测试断言可整体不执行）。未发现 `catch (_: Exception) {}` 在本部分静默吞异常（`ExpandSink.cj:264,380` 的吞异常在范围外，且为清理临时文件的合理忽略） |
| §4 栈溢出 | 1 | #2（`parseGroup` ↔ `parseCp` 自递归，深度 = `(` 层数，无计数）。已排除：`EntityExpander.expandInto` / `expandedSize` 有 `maxDepth` 16 层硬限（`:274,184`）；`checkDefaultEntityInto` 有 `stack` 环检测且被 `maxDeclarations` 1024 兜住（按 ≤1024 层评估可接受）；`DomBuilder` 与 `ParserEngine` 都是显式栈 / 迭代，不递归 |
| §5 OOM | 2 | #1（8 MB 软阈值不生效，2 GiB 硬限成为唯一拒绝点，140 KB 输入可换 1.2 GB 驻留）；#7（`AttTypeMap` 无上限）。量化：#1 为 60000 字符实体 × 20000 次引用 = 1.2e9 字符 < 2 GiB，故全程不抛错；#7 为每条 AttDef 至少 2 个哈希条目、10 MB 子集约 30 万条 → 数十 MB，放大倍数待实测 |
| §6.1 热点瓶颈 | 0 | 本轮无 profile / bench 数据，`ByteSniffer`、`EntityExpander.feed`、`DoctypeParser.startsWith` 的"热门"只有静态线索（调用次数、每字符分配），已全部降级为「待验证假设」#1–#5，不作缺陷、不进统计 |
| §6.2 大粒度锁 | 0 | 本部分无锁、无同步块；`ByteScratch` / `ByteSniffer` / `DoctypeParser` 均为每次解析新建的实例 |
| §6.3 并发串行 | 0 | 本部分无 `spawn`（仅 `EntityCounterIsolation_test.cj:67-76` 在测试里并发跑两个解析器，用于验证计数隔离），无任务提交 / 批处理 |
| §6.4 低效算法 | 0 | 未发现 O(n²) 或 `remove(at: 0)` 型写法；`DoctypeParser` 的逐字符 `skipUntil` / `positionAt` 虽是 O(n)，但没有 n 与耗时数据，按 §6.4 要求（必须能回答"n 多大成为瓶颈"）只能进「待验证假设」#3；`SinkFeed.fillTo` 只在块尾搬移剩余元素，均摊 O(1)，判为合格 |
| §7 降堆内存方案 | 2 | 「实体引用每次复制替换文本」、「DTD 子集整体转 `Array<Rune>`」两条，均 `无基线（待验证）` |
| §8 降 CPU 方案 | 1 | 「前缀比较的常量表化」，`无基线（待验证）` |
| §9 local mode 可行性 | 0 | 不成立：`EntityExpander` 的中间串经 `ExpandSink` / `EntityTable` 逃逸（写入 `HashMap`、返回给 `Lexer`），`cps32Of` 结果存进 `MemoryExpandReader` 跨调用存活，`DoctypeParser` 的 `StringGenerator` 结果存入 `EntityTable`，`ByteScratch.buf` / `DomBuilder.doc` 都是成员级长寿对象；没有"函数内创建、函数内释放"的大对象，且无改前改后峰值数据可证收益 |
| §11 现有代码的 BUG（存量） | 18 | 全部 18 条均为存量（快照无基线）。逐条核对过边界：`ByteSniffer` 的空流 / 4 字节截断 / 单双引号 / 大小写；`DoctypeParser` 的 `EMPTY`/`ANY`/`Mixed`/`children` 四类内容模型、`&`/`%`/`#` 三类引用、`NDATA` 与外部标识符、空集合与 EOF；`EntityExpander` 的空值 / 外部实体 / 未声明 / 深度 / 三层阈值 / 资源关闭；`DomBuilder` 的空文本、`trim` 与 `xml:space` 嵌套 |
| §12 并发安全与锁粒度 | 1 | #5（`ByteScratch.nextId` 静态读-改-写）。其余共享点已核：`EntityCounter` 是解析器实例字段（`ExpandSink.cj:301`），`EntityTable` / `AttTypeMap` 每次解析新建；`DomBuilder` / `DoctypeParser` 无线程共享路径。锁粒度维度不适用：本部分无锁 |
| §14 功能完备性与 README 覆盖 | 1 | #1（承诺的 Spill 落盘主路径未接线）。其余承诺逐条对到实现：`ByteScratch` 的 5 个能力（`append`/`reset`/`bytes`/`size`/`toUtf8String`）全在 `Escaper.cj:34`、`XmlWriter.cj:300,311-316`、`Lexer.cj:384` 落地；`xmlconf-unsupported.md` 的 524 条与 `tools/xmlconf_gen.py` 存在；本部分类型全部 `internal`，无 README 覆盖义务 |
| 文件覆盖（§13 等） | 20/20 | 无缺文件；两份 `.md` 的文档-代码一致性已核（见文件覆盖表 #1 / #2） |

### 第 5 部分

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

### 第 6 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 5 | #6（注释与实现不符）、#7（偏移契约三口径）、#8（CR 换行口径）、#9（跳过配对只比 `local`）、#11（格式塌行）；语言特性方面核对了 `Option` 热路径替身（`peekFast`/`advanceFast`）、`match` 类型分派、`protected` 扩展点语义，未发现误用；并发与安全见 §12 行 |
| §1 死代码 | 2 | #3（3 个零引用测试辅助）、#4（2 处恒假分支）。机械动作：对 `RuneSource.cj` / `XmlChars.cj` / `SkipScanner.cj` / `PrefixStream.cj` / `XmlEvent.cj` / `QName.cj` 全部 `private`·`internal` 符号逐个全模块 `grep`（`blockCapacityOf` / `runesOf` / `cpsOf` / `cps32Of` / `isAsciiXmlChar` / `asciiMaskFor` / `hex` / `hexValue` / `isDigit` / `isHexDigit` / `isWhitespace` / `readCodePointBlock` / `decodeInto` / `decodeBatch` / `finishFill` / `pull` 等均有引用），测试辅助对 `minOf` / `consumed` / `isNull` / `get` / `tokenText` / `drainStream` 等逐个查；`public` 顶层声明（`QName` / `SourcePosition` / `XmlAttribute` / `XmlEvent` / `XmlAction` / `XmlEventHandler` / `RuneSource` / `BufferedRuneSource` / 三个字符源 / `PrefixStream` / `LineWindow`）对外可达，按硬原则一不判 |
| §2 重复逻辑 | 1 | #5（3 组：计时循环、门禁开关、文本重复别名）。同文件内把 20 个文件的函数体压成「输入→输出→副作用」两两比对；跨文件搜了错误文案（「跳过子树时」「提前 EOF」）、`F_XML_PERF`、`/proc/` 路径、`repeatText` / `runSyntheticPass` 等字面量 |
| §3 空实现 | 0 | 无 `TODO` / `FIXME` / `UnsupportedException`；`MemoryInputStream.close() {}`、`SyntheticXmlStream.close() {}`、`RecordingOutputStream` 只有计数的 `flush`、`raiseOwnError` 的 `case None => ()` 都是带语义的 no-op（测试夹具 / 可选关闭），不是契约空实现 |
| §4 栈溢出 | 0 | 本部分唯一递归是测试侧 `semanticDump`（`WriterEncoding_test.cj:221-247`），输入是固定小样本，深度由用例控制；`SkipScanner.skipSubtree` 用 `while (true)` + `depth` 显式深度，不递归；`BufferedRuneSource` / `ByteDecoder` / `ByteReader` 全为迭代 |
| §5 OOM | 0 | 本部分无「按不可信长度预分配」：`Array<Int32>(capacity)` 的 `capacity` 由 `blockCapacityOf` 钳到 `[64, 1 MiB]`；`ByteReader` 扩容按 `len + n` 精确值，不放大；`TextInputStream` 的全量副本是「省内存」候选（进优化方案），不是无界增长 |
| §6.1 热点瓶颈 | 0 | 本部分没有 `cjprof` / 分段计时数据，`Perf_test` 只有端到端总耗时；任何热点结论都不成立，线索全部进「待验证假设」#1–#3 |
| §6.2 大粒度锁 | 0 | 本部分无锁、无 `synchronized`、无共享容器 |
| §6.3 并发串行 | 0 | 无 `spawn` / `Future` / 线程池；`SyntheticXmlStream` 的跨块读取是单线程状态机 |
| §6.4 低效算法 | 0 | 未发现平方级路径：`ByteReader.copyAsciiRun` / `LineWindow.asciiRunLength` 是单趟扫描，`SkipScanner.skipUntil` 线性；`encode`/`decode` 无嵌套循环；`Perf_test.measure` 的 `SyntheticXmlStream(targetBytes)` 重算记录数只有 O(log n) 次除法，不在解析主路径 |
| §7 降堆内存方案 | 1 | 「`parse(text)` 全量副本」（无基线，不进 tasks） |
| §8 降 CPU 方案 | 2 | 「`finishFill` 二次遍历」「`ByteReader` 双缓冲多一次 memcpy」（均无基线） |
| §9 local mode 可行性 | 0 | 本部分函数内临时对象只有定长小数组（`hex` 的数字串、`toString` 的 `StringGenerator`），逃逸面大（返回值 / 事件载荷）；且收益只能靠峰值内存证明，当前无改前基线，按 §9 结论写法只能是「待验证假设」，故不列方案 |
| §11 现有代码的 BUG（存量） | 2 | #2（`ensureOwn` 丢 `error`）、#8（CR 换行口径）；另核对了 `ByteReader.fill` 扩容 / `copyAsciiRun` 的 `pos==len` 复位、`consumeBroken` 的 `available` 边界、`nextUtf16` 代理对与 `ensure(4)` 失败路径、`decodeCompleteUtf8` 的 `E0/ED/F0/F4` 上下界，未发现其它越界或丢字节 |
| §12 并发安全与锁粒度 | 0 | 本部分所有类型（`BufferedRuneSource` 及其子类、`ByteDecoder`、`ByteReader`、`SkipScanner`、`PrefixStream`）都是**每解析器一份**的可变对象，无静态可变状态、无注册表、无回调；`SyntheticXmlStream` 仅测试内单线程使用 ⇒ 线程封闭，不构成共享路径。唯一可被多线程共享的是 `public` 常量（`XmlEvent` 分支、`QName` 值类型）与 `kGcEnvNames`，均不可变 |
| §14 功能完备性与 README 覆盖 | 0 | 本部分不含 `.md`（README / doc 在第 1–3 部分已审，`#5`/`#7`/`#12` 已登记公开 API 与限制面）；`XmlAction.SkipSubtree`→`SkipScanner`、`skipElement`→`ParserEngine.skipElement` 的接线完整（`ParserEngine.cj:499`）；`Perf_test` 的 10/50 MB 门禁与 `PerfTen/PerfFifty` 的重复见 #1，属「两次实现」而非「接线缺失」 |
| 文件覆盖（§13 等） | 20/20 | 本部分 20 个文件全部读完，无 `.md`；与 `files/f_xml.part6.txt` 逐行对应 |

### 第 7 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 7 | 正确性 #1 #3 #4 #5 #6；递归 #7；安全（写侧零校验）#11；分层与职责无问题（DOM / 引擎 / 写入器边界清晰） |
| §1 死代码 | 0（2 条信息） | 逐个核对：`XmlNode` 4 个 private（`collectText` 等）均有调用；`XmlParser` 的 `parseToDocument` / `parseWithHandler` / `dispatch` / `LambdaEventHandler` 均被生产代码引用；`XmlWriter` 的全部 private 字段与辅助函数（`isUtf8`…`ensureBinding`，共 29 处声明）均有调用点（`checkThreshold` 经 `writeText`、`currentUri` 经 `ensureBinding`）；`XmlPullParser` 的 `internal init(text:)`、`doctypeEntities` 被 `XmlParser` 使用。仅测试使用的 `internal` 符号两处（`roundTripChecks`、`totalExpanded`）按硬原则只记信息、不作死代码。`XmlPullParser.cj:81/85` 的 `mode` 二次赋值是冗余写入（轻微，未单列）。`createEngine` 的 `var stream` / `var encoding` 均被重新赋值后有读。 |
| §2 重复逻辑 | 2 | 已把 15 个文件的函数体压成「输入→输出→副作用」两两比对。命中 #8（门限判断 3 处）、#12（6 个同构 charset 判定）。5 个枚举的 `==`/`toString` 手写实现（`EntityLimitKind`、`InvalidByteMode`、`EntityOverflowPolicy`、`InvalidCharMode`、`CdataMode`）确属「只改类型名」的重复，但仓颉枚举无派生能力、且 `XmlEvent_test.enumComparisonExplicit` 明确要求显式实现以拦住新增分支，**不构成可合并重复**，不计入。测试里的 4 个 sink（`RecordingOutputStream` / `IncrementalSink` / `ScratchSink` / `DiscardSink`）为刻意解耦（`XmlWriterIncremental_test.cj:23` 有注释），不计。 |
| §3 空实现 | 0 | `IncrementalSink.flush()`、`DiscardSink.flush()` 等空体是测试替身的有意 no-op；生产代码无空函数、无 `TODO`/`FIXME`（`grep -rn "TODO\|FIXME" f_xml/src` 无命中）。`CdataMode.Never` 的「分支无差别」按 §14 记在 #2，不重复计。 |
| §4 栈溢出 | 1 | #7；解析侧已被 `maxElementDepth`（`ParserEngine.cj:278`）封顶，递归风险集中在 DOM 遍历/序列化侧。 |
| §5 OOM | 0 | `XmlWriter` 输出缓冲有 16 KB 门限；非 UTF-8 路径 `encodeChecked` 的对象上限 = 一个刷写块。唯一「峰值 = 最大单节点」的问题按优化方案（堆内存第 3 条）处理，未达缺陷门槛（无拒绝路径缺失的量化证据）。`XmlconfHarness_test.readBytes` 全量读入仅测试用。 |
| §6.1 热点瓶颈 | 0 | 无 `cjprof` / 改前改后基线下发不了热点结论：`XmlWriterScratch_test` 只测「非 ASCII 追加」的分配上限，未覆盖刷写、编码、命名空间路径。相关猜测全部进「待验证假设」1-4。 |
| §6.2 大粒度锁 | 0 | 本部分无 `synchronized` / `Mutex` / 原子操作（`AtomicInt64` 仅出现在测试的 sink 计数）。 |
| §6.3 并发串行 | 0 | 无 `spawn`、无 `Future.get`；推模式是单线程循环。 |
| §6.4 低效算法 | 0 | `Doctype.isDeclared` 的 O(声明数) 线性扫描（`XmlWriterOptions.cj:92-99`）是唯一候选，无调用次数与规模数据，进待验证假设 #3；`hasElementChild` 的额外一通遍历在压缩模式下直接短路（`XmlWriter.cj:510-522`）。 |
| §7 降堆内存方案 | 3 | 见「优化可行性方案」三条（切片复制、`toArray` 复制、单节点峰值），均为无基线。 |
| §8 降 CPU 方案 | 0 | 无基线，不写结论；编码往返校验、`isDeclared` 扫描的 CPU 猜测进待验证假设 #1 #3。 |
| §9 local mode 可行性 | 0 | 写侧的临时对象（`ByteScratch`、`NamespaceScope`、`IncrementalFrame`）都是**实例级复用**、跨调用存活，不是「函数内创建、函数内释放」；`encodeChecked` 的 `ArrayList<Byte>` 虽在函数内创建，但 `toArray()` 作为返回值逃逸。无逃逸清白的候选，收益无法用峰值内存证明。 |
| §11 现有代码的 BUG（存量） | 11 | 逐函数核对边界 / 空值 / 契约：#1 `setAttr` 前缀丢失、#3 `toString` 不转义、#4 声明位置、#5 参数实体、#6 PUBLIC 丢失、#7 递归、#9 位置计数、#10 空元素名、#11 名称校验、#13 选项校验、#15 断言弱化。`XmlPullParser.close()` 的 `if (let resource: Resource <- this.stream)` 已核对：std 的 `InputStream` 不继承 `Resource`，而 `File <: Resource & IOStream`（`std/fs/fs_package_classes.md:560`），因此只关闭资源型流、对内存流静默跳过——是正确设计，不报。 |
| §12 并发安全与锁粒度 | 0 | 全部分共享可变状态只有 `XmlWriter` / `XmlElement` / `XmlDocument` 的实例字段，且每实例独立创建；无全局 `var`（`FLUSH_THRESHOLD`、`kInitialCapacity` 均为 `let`）；`XmlPullParser` 持有 `engine` / `stream` 也随实例。范围外提示：`ByteScratch.cj:33` 的 `static var nextId` 是非原子自增，多线程并发 new 会撞号（仅影响 `BufferReuse_test` 的身份断言），该文件属第 4 部分。 |
| §14 功能完备性与 README 覆盖 | 1 | #2（`CdataMode.Auto` 承诺未实现）。其余公开符号（`XmlParser` 4 个 `parse`、`XmlWriter` 11 个方法、`XmlNode` / `XmlDocument` / `Doctype` / `EntityLimits` 等）在 README.md 中均能检索到；README 覆盖的逐项评估属第 1 部分。 |
| 文件覆盖（§13 等） | 15/15 | 15 个文件全部读完；`.md` 与 README 一致性由第 1 部分负责，本部分仅把 README.md:173 / 363 作为 #2 #3 的承诺源引用。 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 5 |
| 一般 | 33 |
| 轻微 | 61 |
| 其中存量 | 99 |
| 优化方案 | 见「优化可行性方案」各条 |

## 总评

**第 1 部分**：文档整体质量高于仓库平均水平：API 表、事件契约、xmlconf 口径、性能数字与验收门槛都写到了可复核的程度，`build-warnings.md` 也为每条编译告警给了理由。XXE 侧的核心承诺是成立的——`SYSTEM` / `PUBLIC` 外部子集在 `DoctypeParser` 里不发起任何文件 / 网络 IO，一般实体引用在 `EntityExpander.cj:71-74` / `291-294` 直接抛错；转义侧 `Escaper.cj:25-60` 的 `& < > " \r` 处理与设计 §7.2 一致，非法控制字符也按 §7.3 拒绝。**但 v1 据此得出的「安全边界逐条与实现对得上」并不成立**：

1. **阻塞项（安全 / 功能）**：#1 的 Spill 是本模块对外承诺的「软阈值降级」机制，README 与设计文档重复了 6 处，但解析主路径上唯一能触发它的分支不可达；同时「单实体 64 KB」判的是原文长度而非展开长度。结果是「合法但重度使用实体」的文档仍会在 64 KB 处硬失败，而 README 的「降级重试」建议本身无效。
2. **阻塞项（OOM）**：#2 的属性值 1 MiB 上限是事后拒绝，不是内存上界；默认 `Spill` 下单个属性可把内存推到接近 2 GiB 硬限，输入放大约 1 万倍。在用 `f_xml` 解析不可信 XML（网关、消息队列、上传文件）之前应先修这两条。
3. **次阻塞项**：#3 的上限单位（码点 vs 字节）让「2 GB 硬限」在 CJK 输入下实际放宽到约 6 GB；#5 的「其他公开 API」把 internal 成员列为公开，同时漏掉三个字符源的构造；#6 让 2038 条断言的复现路径与设计文档相反，属于「验收不可复现」。
4. **排期项**：#4 的 `unsafeBytes()` 自相矛盾（已由 `f_base/src/UnsafeData.cj` 坐实「会拷贝」）、#7 的测试数、#8 的签名与示例、#9 的测试名、#10 的表格断行、#11 的术语、#12 的两条限制、#13 的参数实体表述，都是低成本修正，可一次性打包。

性能方面本部分没有可验证的新结论：README 的 58 ms / 497 ms / 2.47 s / 104 MB 是作者提供的历史数据，本轮未复测，按规则只进「待验证假设」，不进 `todo.md` / `tasks.md`。

存量缺陷共 13 条（严重 2 / 一般 4 / 轻微 7），是否纳入修复待用户决定；本报告只读文件，未修改任何源码或文档。

**第 2 部分**：这 11 个文件是 f_xml M1 与其后续补强的完整规划与验收留档，质量整体在「可直接复核」的水平：上限默认值、安全边界（XXE / 实体膨胀 / 属性值）、`SpillDir` 四级回退、`ByteDecoder` 块解码这些关键承诺都能在源码里逐一找到落点，`baseline.md` 的缺口收敛算式（385 − 325 − 47 − 2 − 11 = 0，59 − 59 = 0，14 − 7 − 7 = 0）与 `xmlconf-unsupported.md` 的 313+95+59+47+10 = 524 也自洽，`verification.md` 的 23 条用例映射没有一条落空。因此本部分**没有阻塞项**，也没有功能缺失。

风险集中在「旧口径未清理」这一处：`spec.md:119/151` 与 `design.md:234/242` 仍把 `readln()` / `StringReader` 写成 SHALL / SHALL NOT，而实现的字符层早就换成 `ByteDecoder` 块解码——这是唯一会被后来者当成契约照做、从而把已修好的换行缺陷带回来的地方，建议优先修（#1）。其次是验收数字：Gate P 的 9649 / 16 346 两种基线（#2）和 `verification.md:59` 与自身表格矛盾的「< 0.5%」（#3）会让下一次复验拿到相反的前提，虽然不影响已交付代码，但会影响后续 `optimize-f-xml-*` 的判定口径，属可排期项。其余 5 条（构造器签名、三处计数、基准重复次数、Purpose / 块容量公式、吞吐单位）是文档卫生问题，随下次文档修订顺手改即可。

另有两处候选按 checklist 的误报边界排除了：包结构表漏 `NameTable.cj` / `ByteScratch.cj`、Lexer 白名单行号漂移——它们都是后续 `optimize-f-xml-semantic-layer` 引入的文件 / 代码位移造成的，归档件只要求「当时自洽」，不计缺陷。

**第 3 部分**：这 16 份文档的质量明显高于仓库平均水平：每个变更都有「proposal / design / spec / tasks / baseline / verification」六件套（`reuse` 缺后两件，见 #14），性能结论带 `-O2` 同轮新旧对照与 `max/min` 离散度，spec 的每个 Scenario 都能在 `verification.md` 里映射到用例名。本轮抽查的默认值（64 KB / 8 MB / 16 / 1024 / 2 GB、4096、1 MiB）、公开 API 面（`QName` / `XmlElement` / `XmlDocument`）、xmlconf 口径（524 条，313/95/59/47/10）、`Lexer` 的 `StringGenerator()` 三处残留，**全部与代码一致**——说明文档不是事后补写的。

风险不在「写错」，而在「改完没回填」：#1 / #5 / #6 / #7 / #10 / #11 都是同一类问题——第三轮修订或后续变更落地后，任务状态、残差条数、测量协议、事件数、估算区间、文件路径没有回填。建议在合并报告里作为一条流程建议提出（每次变更收口时对 `tasks.md` / `baseline.md` 做一次数值复算与路径核对），而不是按六处独立缺陷排期。

真正需要动作的是三条：#2（writer spec 的 `StringWriter` SHALL 已永久不可满足，必须补偏离登记，否则后续审计会把现状判成违约）、#3（`text()` / `write()` 对程序化构造的 DOM 无深度契约，属可崩溃面，建议改迭代并在 spec 写明）、#4（Gate C 少了 unsupported 清单留档，补一个写文件或改口径即可）。#12 与 #2 同属 writer spec，建议一并处理。四条都不阻塞本次归档，也不需要回滚任何已发布行为。

无严重项，无数据丢失 / 安全漏洞 / 并发缺陷。存量 14 条，是否纳入修复待用户决定。

**第 4 部分**：这四段是全模块最"硬"的部分，代码本身的可读性和防御意识都不错：`ByteScratch` 的容量复用与零拷贝视图、`ByteSniffer` 的 BOM → 魔数 → 声明优先级、`DoctypeParser` 对四类声明产生式的逐条校验（连 `NDATA` 只能在外部实体上、`%p ;` 不允许中间空白这种细节都做了）、`EntityExpander` 的"先校验替换文本良构再接线"、`DomBuilder` 的文本合并与 `xml:space` 作用域，都是照着 XML 1.0 逐条实现的，XXE 面也确实封死了（外部实体只记声明、引用即抛，外部子集永不加载，`SpillDir` 不接收任何外部路径）。这批代码的主要风险不在"写错规范"，而在**边界的最后一公里**。

两条阻塞项都在"边界"上：

1. **#1 的落盘链路没有接线**。这是本部分最需要动作的一条：`feed` 在第 82 行把所有超过 64 KB 的实体直接拒掉，第 108 行那段唯一会 `spill()` 的代码因此永远走不到，于是默认 `Spill` 策略与设计文档 §5.4.1 / README 的承诺完全相反——单个大实体被拒、8 MB 总量阈值形同虚设、真正的拒绝点是 2 GiB 硬限。它同时解释了为什么 `EntityLimits_test.degradeRetrySucceeds` 与 `Spill_test` 都是绿的：一个走内容路径（根本不落盘）却断言"成功"，另一个直接构造 `ExpandSink`（绕过主路径）。修法很小（按 `overflowPolicy` 决定 :82 抛还是 :108 落盘，并把 `EntityCounter()` 换成 `this.counter`），但必须补上"能区分落盘与不落盘"的用例，否则回归网仍然证明不了这条链路活着；修好之后 #6 的临时文件泄漏会立刻成为现实路径，应与 #1 同批处理。
2. **#2 的 DTD 递归没有上限**。这是纯解析侧的崩溃面：一份 1 MB 的 `<!ELEMENT>` 就能压 10⁵ 层栈帧，且不可捕获。它与实体递归（16 层硬限）、参数实体递归（`maxDepth`）在同一文件里，唯独内容模型这条路径没有计数——属于"同一类风险只堵了两条路"。

一般项五条（#3 字符引用溢出的异常类型逃逸、#4 注释内伪声明改变编码判定、#5 `nextId` 的数据竞争、#6 溢出文件在异常路径泄漏、#7 `ATTLIST` 声明无上限）都是"小输入 + 边界"型，单条影响有限，但都会让调用方看到契约外的行为（`OverflowException`、错误编码、重复 id、残留临时文件、随 DTD 放大的内存）。十一条轻微项集中在测试可靠性（#13 / #14）、死代码与冗余（#8 / #10 / #17）、文档与注释的精度（#9 / #12 / #15 / #16 / #18）与一处良构性缺口（#11）。

另需在合并报告里对齐口径：第 2、3 部分的文档审查据 `design.md` / spec 认定"`Spill` 下内存恒定、2 GB 上限落磁盘不落堆"，那只在**直接驱动 `ExpandSink`** 时成立；解析主路径并不落盘（#1）。合并时请以本部分的代码取证为准，并把第 2/3 部分的 §5 OOM「0 命中」改为"文档有承诺、实现未接线"。

存量 18 条（严重 2 / 一般 5 / 轻微 11），是否纳入修复待用户决定。

**第 5 部分**：本部分（词法层 + 状态机 + 名字驻留 + 命名空间 + 实体表 + 转义）是整个模块质量最高的部分：解析器用显式名称栈而非递归、实体递归有三层上限、XXE 与外部子集在代码层面就是「永不加载 / 零 I/O」、`readName` 的驻留与批量扫描都有结构性断言兜底，`LineWindow` 的 CR/LF 归一与行列号推进在 4 种块大小下都有对照用例。核心安全目标（不加载外部实体、不炸内存）在默认配置下成立，没有发现可远程触发的解析崩溃。

阻塞项只有一条：**流式内存契约（O(嵌套深度)）在「单段超大文本 / 超大属性 / 超大 DTD 内部子集」上不成立，且属性长度上限在物化之后才检查**——这条与 README 和 spec 的明文承诺直接冲突（spec 原文 `SHALL 仍为 O(嵌套深度)`），也是目前唯一能靠输入把进程推成 OOM 的路径，建议优先修（改动局限在三个累积循环内加长度判定，并复用已注入但未使用的 `Lexer.maxAttributeValueLength`）。

其余可排期：实体上限的「码点 vs 字节」记账（#7，与 #1 同批改最省事）、未声明实体告警无上限（#8）、重复 `xmlns` 声明不判重（#2，规范 WFC 缺口，会导致解析器差异）、属性判重 O(n²)（#3）、属性值 LF/TAB 不转义（#4，往返失真）、`fillOnce` 丢弃部分填充的错误（#9）。死代码与重复逻辑两组属于清理项（#11 九处、#12 五组），`ExpandReader.next`、`StringFeed`、`sawRoot` 这类"看起来有保护其实没有"的残留应尽快删掉，避免后续维护者误判。

存量 20 条（1 严重 + 8 一般 + 11 轻微），是否纳入修复待用户决定；其中 #1 建议单独立项，#2/#4/#7/#8 建议随下一次维护窗口处理，#3/#6 可与已有的 `ByteScratch.nextId` 条目合并。性能类结论全部未成立（无 profile / bench 数据），只保留 7 条待验证假设供下一轮补数据。

**第 6 部分**：本部分（字符源与解码层、事件定义、`skipElement` 标签级扫描器、性能与回归测试基础设施）代码质量良好：`RecordSource` 的 `Option` 热路径替身有明确动机与对照用例，块解码在 `bufSize = 4/8` 的极端边界上有逐字符等价测试，错误定位用「消费游标 + 解码游标」两套位置分离处理，`SkipScanner` 把四类「假 `>`」都考虑到了，注释密度与「为什么这样写」的说明明显高于一般模块。

**没有阻塞项**（无崩溃、无越界、无数据竞争、本部分无 XXE/实体展开路径）。两条「一般」都属口径/健壮性问题而不是功能失效：门禁阈值有两套互斥定义且旧用例违反「独占进程测 VmHWM」的自定约束；`ensureOwn` 在部分解码失败时会丢掉错误对象，当前只影响第三方/`CharsetRuneSource` 直连 `peek/advance` 的路径。九条「轻微」里，#7/#8/#9 是三条独立的「契约口径漂移」（偏移上界、换行定义、名字比较），#3/#4/#5 是机械检查到的死代码与重复，#6/#10/#11 是注释与格式层面。

存量缺陷共 11 条，是否纳入修复待用户决定；三条优化方案均无基线，只能进下一轮补数据清单，不进 `tasks.md`。

**第 7 部分**：写侧（`XmlWriter` + `XmlWriterOptions`）是本部分的风险重心：7 条一般问题里有 6 条落在这里，且都不是「性能还可以更好」而是**输出错误或非法文档**——`setAttr` 覆盖丢前缀、`Doctype.isDeclared` 放过参数实体、`EntityDecl.toString` 丢 PUBLIC、`writeDeclaration` 可写进元素内、`toString` 不转义、`CdataMode.Auto` 空承诺。这些都在默认配置的主路径上，静默失败（不抛错、产出错误 XML），建议优先修。

读侧（`XmlParser` / `XmlPullParser` / `XmlNode` / `XmlOptions`）质量明显更好：三入口收敛到同一个内核、`dispatch` 穷尽 `XmlEvent`、`close()` 用 `Resource` 类型判定只关资源型流、`maxElementDepth` 在引擎层统一把关，未发现解析正确性或实体安全缺陷；剩下的递归风险（#7）只在手工构造超深 DOM 时成立，可排期。

测试覆盖与代码质量匹配：推拉一致性、增量/整树逐字节对齐、编码往返、实体上限都有对应用例，缺陷集中在「未被用例覆盖的契约分支」（声明位置、参数实体、setAttr 前缀、Auto CDATA），补 4 条用例即可锁死这批回归。
