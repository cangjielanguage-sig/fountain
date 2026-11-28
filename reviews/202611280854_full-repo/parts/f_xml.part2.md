# f_xml 模块审查报告

> **模块第 2/7 部分**（本报告只覆盖 `files/f_xml.part2.txt` 列出的 11 个文件，全部是 `doc/spec/` 下的 `.md`：`implement-f-xml-m1` 的 baseline / design / proposal / `specs/f-xml-char-layer`，与 `complete-f-xml-m1-followups` 的 design / proposal / tasks / verification / 三份 spec。本部分 0 个 `.cj`。因为本部分没有代码，专项维度按「文档承诺 → 实现取证」的方式执行：文档声明的每个符号、默认值、行为都在 `f_xml/src` 里核到位置，核不到的才报。`implement-f-xml-m1/tasks.md`、`implement-f-xml-m1/verification.md`、该变更另外 5 份 spec、`optimize-f-xml-semantic-layer/**`、`reuse-f-xml-writer-scratch/**`、`README*.md`、`doc/f_xml模块设计.md`、`doc/build-warnings.md`、`doc/xmlconf-unsupported.md` 均不在本部分清单，由其他子轮产出；本报告只在取证时引用它们。本部分编号独立，合并时以主 Agent 为准。）

- **审查日期**：2026-11-28
- **模块路径**：`f_xml`（本部分 0 个 `.cj` + 11 个 `.md`；模块清单共 106 个文件 = 72 个 `.cj` + 34 个 `.md`）
- **基线**：工作区快照（`sts/1.3.x` 工作区，无 diff 可比 ⇒ 全部问题记「存量」）
- **审查重点**：XML 解析/序列化正确性与安全（XXE、实体展开、转义）、递归与栈溢出、OOM、死代码、重复逻辑、存量 BUG。本部分实际落在专项 **§13 文档与代码一致性**、**§14 功能完备性**，并把文档里的安全承诺（外部实体不加载、三层实体上限、属性值不溢出、BOM/声明冲突）逐条核到实现。
- **报告版本**：v1（第 2/7 部分）

## 取证说明（本部分的方法）

- 文档里的每个符号都做了存在性核对：`BufferedRuneSource` / `decodeInto` / `readCodePointBlock` / `blocksFilled` / `codepointsYielded` / `hasOwnBlock`（`f_xml/src/RuneSource.cj:79,93,95,117,132,158`）、`SpillDir.createFileFrom`（`ExpandSink.cj:61`）、`EntityCounter`（`ExpandSink.cj:301`）、`XmlPullParser.warnings()`（`XmlPullParser.cj:63`）、`totalExpanded()`（`:72`）、`AttTypeMap`（`DoctypeParser.cj:69`）——全部存在。
- `verification.md:63-122` 登记的 23 个「Scenario → 用例名」逐个搜过：除文档自己声明的两处「无用例」（`verification.md:85` 的静态检查、`:102` 的 DOM 不作门禁）外，其余用例名在 `f_xml/src/*_test.cj` 全部命中，Python 侧 `tools/test_xmlconf_gen.py` 的 4 个用例名也全部命中。
- 安全承诺核对结果一致，未发现文档与实现相反：外部实体「引用即报错、永不加载」（`EntityTable.cj:25`、`EntityExpander.cj:73,293`）；条件段只在外部子集、内部子集出现即报错（`DoctypeParser.cj:381`）；BOM 与声明冲突致命错误（`ByteSniffer.cj:161`）；属性值永不溢出、超限抛 `AttributeValue`（`ExpandSink.cj:85,160`）；`EntityLimits` 默认 64 KB / 8 MB / 16 / 1024 / 2 GB 与 `design.md:486-497` 逐项一致（`XmlOptions.cj:102-110`）；`XmlParserOptions` 默认 8192 / 4096 / 1 MiB 与 `design.md:178-190` 一致（`XmlOptions.cj:141-148`）；`blockCapacityOf = max(64, min(bufSize, 1 MiB))` 与 `design.md:96`、spec「缓冲大小可配」一致（`RuneSource.cj:61-71`）；`xmlconf-unsupported.md` 的 313+95+59+47+10=524 与 `baseline.md:18` 一致。
- 结论：这两个已归档变更的产物**主体自洽**，问题集中在「旧口径未清理」与「数字 / 口径未回填」两类，不涉及功能缺失。

## 发现

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

## 优化可行性方案

本部分不含代码，没有可执行的堆内存 / CPU 改造项，故本节为空。文档里唯一带性能含义的结论是 R5 的 16 384 档 −9.3%（`design.md:436-444`）：按 D5（`design.md:584`）与 spec「`bufSize` 实测与回填」的 `SHALL NOT 修改默认值`，它只能作为建议值记录，不能据此改默认行为；若要改默认值，须按 `performance-optimization.md` 的口径给出改前改后对照（同机、`-O2`、3 次 min、同输入），那属于代码变更而非文档修订。

## 待验证假设

> 文档自带实测值（`design.md` §7.3 / §8.2、`verification.md` §2 / §3），本轮只读审查、未跑构建也未复测，因此这些数字只作线索。它们不计入模块统计，也不进 `todo.md`。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 10 MB 事件解析 `min(3) = 1101.8 ms` 仍成立 | `complete-f-xml-m1-followups/design.md:400`、`verification.md:36` | 同机 `-O2` 复跑值（文档为 2026-10-30、aarch64-linux、SDK 1.3.0） | `cd f_xml && F_XML_PERF=1 cjpm test --filter=Perf_test --show-all-output` |
| 2 | `VmHWM(50 MB) − VmHWM(10 MB) = 32 kB`、`VmHWM(50) = 288.1 MB` 仍成立 | `verification.md:13`、`design.md:405-407` | 目标机 `VmHWM` 绝对值与差值（受 GC / 分配器保留影响） | 同上，读 `/proc/self/status` 的 `VmRSS` / `VmHWM` |
| 3 | 16 384 档 10 MB 比 8192 快 9.3% 可复现（多轮中位数） | `design.md:440`、`verification.md:56` | 4 档 × 2 文档 × 3 次、≥3 轮的中位数与离散度；文档结论 `verification.md:59` 与同表数据矛盾（见 #3） | `--filter=Perf_test` 的 `bufSizeMatrix` 用例 |

## 文件覆盖

> 与 `reviews/202611280854_full-repo/files/f_xml.part2.txt` 一一对应。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_xml/doc/spec/complete-f-xml-m1-followups/design.md` | .md | 已读 | 见 #1 / #2 / #3 / #5 / #6 / #7 / #8；§3.2/§3.3 的块 seam 与 `RuneSource.cj` / `LineWindow.cj` 一致 |
| 2 | `f_xml/doc/spec/complete-f-xml-m1-followups/proposal.md` | .md | 已读 | 见 #2 / #5 / #7 |
| 3 | `f_xml/doc/spec/complete-f-xml-m1-followups/specs/f-xml-char-layer/spec.md` | .md | 已读 | 与实现一致（块解码 / 三层合并 / 零 Option 已核到 `RuneSource.cj`、`LineWindow.cj`）；Purpose 见 #7 |
| 4 | `f_xml/doc/spec/complete-f-xml-m1-followups/specs/f-xml-conformance/spec.md` | .md | 已读 | 见 #2 / #6；Gate A/B/C 口径与 harness 一致 |
| 5 | `f_xml/doc/spec/complete-f-xml-m1-followups/specs/f-xml-dtd-entities/spec.md` | .md | 已读 | 四级目录 / `createFileFrom` seam / 计数器实例级均与实现一致（`ExpandSink.cj:52,61,301`） |
| 6 | `f_xml/doc/spec/complete-f-xml-m1-followups/tasks.md` | .md | 已读 | 见 #5 / #6；12 节全部 `[x]`，抽查落点均存在 |
| 7 | `f_xml/doc/spec/complete-f-xml-m1-followups/verification.md` | .md | 已读 | 见 #2 / #3 / #5 / #6 / #8；用例名 23 条全部命中 |
| 8 | `f_xml/doc/spec/implement-f-xml-m1/baseline.md` | .md | 已读 | 524 / 2062 / 2038 与 `xmlconf-unsupported.md` 统计一致；缺口收敛算式 385−325−47−2−11=0 自洽 |
| 9 | `f_xml/doc/spec/implement-f-xml-m1/design.md` | .md | 已读 | 见 #1 / #3 / #4 / #5；安全与上限口径已核到实现 |
| 10 | `f_xml/doc/spec/implement-f-xml-m1/proposal.md` | .md | 已读 | 见 #1 |
| 11 | `f_xml/doc/spec/implement-f-xml-m1/specs/f-xml-char-layer/spec.md` | .md | 已读 | 见 #1（`:119` / `:151` 旧 readln 口径）；其余 Requirement 与实现一致 |

合计：`.cj` 0 个 / `.md` 11 个 / 共 11 个，全部读完。

## 覆盖自检

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

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 3 |
| 轻微 | 5 |
| 优化方案（堆内存 / CPU） | 0 / 0 |

## 总评

这 11 个文件是 f_xml M1 与其后续补强的完整规划与验收留档，质量整体在「可直接复核」的水平：上限默认值、安全边界（XXE / 实体膨胀 / 属性值）、`SpillDir` 四级回退、`ByteDecoder` 块解码这些关键承诺都能在源码里逐一找到落点，`baseline.md` 的缺口收敛算式（385 − 325 − 47 − 2 − 11 = 0，59 − 59 = 0，14 − 7 − 7 = 0）与 `xmlconf-unsupported.md` 的 313+95+59+47+10 = 524 也自洽，`verification.md` 的 23 条用例映射没有一条落空。因此本部分**没有阻塞项**，也没有功能缺失。

风险集中在「旧口径未清理」这一处：`spec.md:119/151` 与 `design.md:234/242` 仍把 `readln()` / `StringReader` 写成 SHALL / SHALL NOT，而实现的字符层早就换成 `ByteDecoder` 块解码——这是唯一会被后来者当成契约照做、从而把已修好的换行缺陷带回来的地方，建议优先修（#1）。其次是验收数字：Gate P 的 9649 / 16 346 两种基线（#2）和 `verification.md:59` 与自身表格矛盾的「< 0.5%」（#3）会让下一次复验拿到相反的前提，虽然不影响已交付代码，但会影响后续 `optimize-f-xml-*` 的判定口径，属可排期项。其余 5 条（构造器签名、三处计数、基准重复次数、Purpose / 块容量公式、吞吐单位）是文档卫生问题，随下次文档修订顺手改即可。

另有两处候选按 checklist 的误报边界排除了：包结构表漏 `NameTable.cj` / `ByteScratch.cj`、Lexer 白名单行号漂移——它们都是后续 `optimize-f-xml-semantic-layer` 引入的文件 / 代码位移造成的，归档件只要求「当时自洽」，不计缺陷。
