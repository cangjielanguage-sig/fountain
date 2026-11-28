# f_xml 模块审查报告

> **模块第 1/7 部分**：本报告只覆盖 `files/f_xml.part1.txt` 列出的 5 个文件（`README.md`、`README_en.md`、`doc/build-warnings.md`、`doc/f_xml模块设计.md`、`doc/spec/complete-f-xml-m1-followups/baseline.md`）。本部分不含 `.cj`，发现的载体是「文档承诺 ↔ 实现取证」；`.cj` 只作为核对证据读取，不展开逐项审查，源文件问题归属第 3~7 部分。
>
> **版本说明**：v2（2026-11-28 15:07 重跑）。同日 13:27 的 v1 已给出 10 条文档一致性问题；本次全量重读后保留并复核了这 10 条（其中 #4 的 `unsafeBytes` 结论已用 `f_base/src/UnsafeData.cj` 坐实），新增两条**严重**项（实体 Spill 主路径不可达、属性值上限不是内存上界），并修正 v1 总评中「安全边界逐条与实现对得上」的结论——该结论不成立。
>
> **合并提示（给主 Agent）**：本轮同模块已有 `f_xml.part4.md` / `part5.md`。#1 与 part4 #1 同源（`EntityExpander.feed` 的落盘链路不可达），#2 与 part5 #1 同源（属性值 / 文本 / DTD 三处全量物化后才校验；part5 覆盖更全）。合并时请以代码部分的取证明细为主，本部分只补**文档侧位置**（`README.md:385/407/410-413`、设计 §5.4.1 / §5.4.2 / §8 / §12.8 六处）与「文档必须同步改」的结论；若按根因去重，本部分统计的 2 条严重不应再重复计入模块总数。

- **审查日期**：2026-11-28
- **模块路径**：`f_xml`（全模块 72 个 `.cj` + 34 个 `.md`；本部分 5 个 `.md`）
- **基线**：工作区快照（master 与 `sts/1.3.x` 同一提交 `120fd2542`，`git diff` 为空 ⇒ 全部问题记「存量」）
- **审查重点**：XML 解析 / 序列化的**文档契约与安全承诺**（XXE、实体展开上限与溢出、转义）、递归与栈溢出、OOM 上限、死引用 / 重复内容、存量文档与实现不符
- **报告版本**：v2（第 1/7 部分）

## 发现

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

## 优化可行性方案

本部分 5 个文件全部是文档，**不构成堆内存 / CPU 优化对象**，本轮不产出优化方案（0 / 0）。#1 / #2 是缺陷修复而不是优化；#4 的 `unsafeBytes()` 复制成本已作为文档缺陷记录，没有改前 / 改后基线，按规则不写成优化方案、不进 `tasks.md`。文档中出现的性能数字（`README.md:434-438`、`doc/f_xml模块设计.md:2392-2422`）是已归档的验证数据，本轮未复跑，只进「待验证假设」。

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | README 的「1 MB ≈ 58 ms / 10 MB ≈ 497 ms / 50 MB ≈ 2.47 s、`VmHWM(50 MB) = 104 MB`」在当前离线环境无法复核；是否仍与当前 HEAD 一致未知 | `f_xml/README.md:434-438`、`README_en.md:449-454` | 当前机器 `-O2` 交付构建的 5 次 `min`、`max/min` 离散度、`VmHWM` | 按 `doc/spec/complete-f-xml-m1-followups/baseline.md:87` 跑 `F_XML_PERF=1 cjpm test --filter=Perf`，并单独跑 `PerfTen_test` / `PerfFifty_test` 两个进程门禁 |
| 2 | 深层 DOM 的 `toString()` 为每个元素新建一个 `StringGenerator`，深树可能退化为 O(n·depth) 复制 | `src/XmlNode.cj:251-266`、`XmlNode.cj:35-47` | 10 MB、深度 1000/4000 的耗时与分配量 | 合成深树 + `cjprof record`，对照 `text()`（单 generator，`XmlNode.cj:234-249`） |
| 3 | 元素内重复属性检测是线性扫描，宽元素（上千属性）可能 O(a²) | `src/ParserEngine.cj:309-312`（`for (existing in seen)`） | 属性数 10/1000/10000 时的自耗时 | 合成单元素宽属性文档，`cjpm bench -O2` 对照 HashSet |
| 4 | `ExpandSink.write` 每次 `runesOf(segment)` 分配码点数组，在属性实体展开路径上放大分配量 | `src/ExpandSink.cj:150`、`src/XmlChars.cj:155-161` | 每次 write 的分配字节数、占总分配比例 | 对属性值实体展开跑 `cjprof heap`，与直接 `segment.size` 计数对照 |

## 文件覆盖

> 与 `reviews/202611280854_full-repo/files/f_xml.part1.txt` 一一对应，5 行全部读完。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_xml/README.md` | .md | ✅ | 中文主文档；见 #1 #2 #3 #5 #7 #11 #12 #13 |
| 2 | `f_xml/README_en.md` | .md | ✅ | 与中文版逐节比对，章节、签名、数字、限制一致（376 同步过期，并入 #7）；#1 #2 #3 的单位/边界表述同源 |
| 3 | `f_xml/doc/build-warnings.md` | .md | ✅ | 6 个「仅测试使用」观测器逐个在 `src/` 找到定义与测试引用（`totalExpanded` / `spillPath` / `retainedBytes` / `size` / `readAll` / `hasOwnBlock`）；`XmlEventHandler` 10 个默认方法共 15 个形参，6+15=21 条与 `optimize-f-xml-semantic-layer/verification.md:16` 的「21 条」一致。**注意**：`spillPath` / `retainedBytes` / `readAll` 指向的 spill 路径在生产代码不可达，见 #1 |
| 4 | `f_xml/doc/f_xml模块设计.md` | .md | ✅ | 2458 行全部读完；见 #1 #3 #4 #6 #8 #9 #10 #13；§15 回填表与当前实现基本对齐，其余陈旧点已列 |
| 5 | `f_xml/doc/spec/complete-f-xml-m1-followups/baseline.md` | .md | ✅ | 归档变更的冻结基线，按「当时结论是否自洽」核对：303 用例 / 998 ms / 9649 ms / Gate 口径与 §6 复现命令自洽；§1 的「20 条 WARNING」是改动前快照（现为 21），文档已声明「不改写历史」，不计问题；其 §6「需先准备缓存」正好是 #6 的反证 |

合计：`.cj` 0 个 / `.md` 5 个 / 共 5 个，全部读完。

## 覆盖自检

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

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 2 |
| 一般 | 4 |
| 轻微 | 7 |
| 优化方案（堆内存 / CPU） | 0 / 0 |

> 13 条全部为存量（快照模式无基线）；是否纳入修复由用户在门禁决定，本报告不代为拍板。

## 总评

文档整体质量高于仓库平均水平：API 表、事件契约、xmlconf 口径、性能数字与验收门槛都写到了可复核的程度，`build-warnings.md` 也为每条编译告警给了理由。XXE 侧的核心承诺是成立的——`SYSTEM` / `PUBLIC` 外部子集在 `DoctypeParser` 里不发起任何文件 / 网络 IO，一般实体引用在 `EntityExpander.cj:71-74` / `291-294` 直接抛错；转义侧 `Escaper.cj:25-60` 的 `& < > " \r` 处理与设计 §7.2 一致，非法控制字符也按 §7.3 拒绝。**但 v1 据此得出的「安全边界逐条与实现对得上」并不成立**：

1. **阻塞项（安全 / 功能）**：#1 的 Spill 是本模块对外承诺的「软阈值降级」机制，README 与设计文档重复了 6 处，但解析主路径上唯一能触发它的分支不可达；同时「单实体 64 KB」判的是原文长度而非展开长度。结果是「合法但重度使用实体」的文档仍会在 64 KB 处硬失败，而 README 的「降级重试」建议本身无效。
2. **阻塞项（OOM）**：#2 的属性值 1 MiB 上限是事后拒绝，不是内存上界；默认 `Spill` 下单个属性可把内存推到接近 2 GiB 硬限，输入放大约 1 万倍。在用 `f_xml` 解析不可信 XML（网关、消息队列、上传文件）之前应先修这两条。
3. **次阻塞项**：#3 的上限单位（码点 vs 字节）让「2 GB 硬限」在 CJK 输入下实际放宽到约 6 GB；#5 的「其他公开 API」把 internal 成员列为公开，同时漏掉三个字符源的构造；#6 让 2038 条断言的复现路径与设计文档相反，属于「验收不可复现」。
4. **排期项**：#4 的 `unsafeBytes()` 自相矛盾（已由 `f_base/src/UnsafeData.cj` 坐实「会拷贝」）、#7 的测试数、#8 的签名与示例、#9 的测试名、#10 的表格断行、#11 的术语、#12 的两条限制、#13 的参数实体表述，都是低成本修正，可一次性打包。

性能方面本部分没有可验证的新结论：README 的 58 ms / 497 ms / 2.47 s / 104 MB 是作者提供的历史数据，本轮未复测，按规则只进「待验证假设」，不进 `todo.md` / `tasks.md`。

存量缺陷共 13 条（严重 2 / 一般 4 / 轻微 7），是否纳入修复待用户决定；本报告只读文件，未修改任何源码或文档。
