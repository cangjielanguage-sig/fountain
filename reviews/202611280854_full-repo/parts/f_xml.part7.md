# f_xml 模块审查报告（模块第 7/7 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_xml/`（本部分 15 个文件：0 个 `.md` / 15 个 `.cj`）
- **基线**：工作区快照（HEAD `f309f0b55`，`git diff` 为空）⇒ 全部为「存量」
- **审查重点**：XML 解析与安全（XXE / 实体展开 / 转义）、递归与栈溢出、OOM、死代码、重复逻辑；本部分聚焦 **DOM / 三入口 / 写入器 / 选项 / 异常** 五个生产文件 + 7 个测试文件
- **报告版本**：v1（分部分报告，供主 Agent 合并到 `docs/review/2026-11-28/f_xml_v2.md`）

## 发现

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

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 非 UTF-8 编码写路径 `encodeChecked` 的往返校验让 CPU ≈ 2 倍编码，是 GBK 大文档写出的主要成本 | `f_xml/src/XmlWriter.cj:325-356` | 自耗时占比（encode / decode / 比较三分） | `cjprof record` 跑 100 MB 中文文档 GBK 输出，`UTF8` 同输入做对照 |
| 2 | `flushBuffer` 的切片复制占 writer 总分配的显著比例 | `f_xml/src/XmlWriter.cj:310-313` | 分配量拆分（缓冲 vs 切片 vs encoder） | 复用 `XmlWriterScratch_test.scratchMeasure`，分别统计 `UTF8` 与 `GBK` 路径 |
| 3 | `Doctype.isDeclared` 的线性扫描在「实体声明多 + 引用多」时成为 CPU 热点（声明 ≤1024 × 引用数） | `f_xml/src/XmlWriterOptions.cj:92-99` | 引用条数、单次比较耗时、占比 | 造 1024 条声明 + 100 万次 `&e;` 引用（需 streaming API 支持，否则先埋点统计调用次数） |
| 4 | 解析 4096 层文档后调 `XmlElement.toString()` / `XmlWriter.write()` 是否已接近默认栈上限 | `f_xml/src/XmlNode.cj:251-267`、`f_xml/src/XmlWriter.cj:465-508` | 默认线程栈大小与每帧字节数 | 生成 4096 层文档，在 `spawn` 线程与主线程分别跑 `toString()`，观察是否栈溢出；同时查 SDK 文档确认默认栈值 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_xml/src/XmlEvent_test.cj` | .cj | ✅ | 事件文本格式 / 枚举相等性用例；断言与实现一致 |
| 2 | `f_xml/src/XmlException.cj` | .cj | ✅ | 异常与 `EntityLimitKind`；三构造与位置拼接核对无误 |
| 3 | `f_xml/src/XmlNode.cj` | .cj | ✅ | DOM 模型；见发现 #1 #3 #7，`toString` 族见 #6 |
| 4 | `f_xml/src/XmlOptions.cj` | .cj | ✅ | 解析选项与实体上限；见 #13 |
| 5 | `f_xml/src/XmlParser.cj` | .cj | ✅ | 三入口 + 推模式转译；`dispatch` 覆盖全部 `XmlEvent`，无死分支 |
| 6 | `f_xml/src/XmlParser_test.cj` | .cj | ✅ | 见 #14 #15；`catch (_: Exception) {}` 仅用于临时文件清理 |
| 7 | `f_xml/src/XmlPullParser.cj` | .cj | ✅ | 内核入口；`createEngine` 的 `mode` 重复赋值见「覆盖自检 §1」说明 |
| 8 | `f_xml/src/XmlPullParser_test.cj` | .cj | ✅ | Stop / skipElement 边界用例完整 |
| 9 | `f_xml/src/XmlWriter.cj` | .cj | ✅ | 本次问题最集中：见 #2 #4 #5 #8 #9 #10 #11 #12 |
| 10 | `f_xml/src/XmlWriterIncremental_test.cj` | .cj | ✅ | 增量写用例；未覆盖「声明写在元素内」（#4）与「setAttr 带前缀」（#1） |
| 11 | `f_xml/src/XmlWriterOptions.cj` | .cj | ✅ | 见 #2 #5 #6 |
| 12 | `f_xml/src/XmlWriterScratch_test.cj` | .cj | ✅ | 分配基准（`F_XML_BENCH=1` 才跑）；见 #14 |
| 13 | `f_xml/src/XmlWriter_test.cj` | .cj | ✅ | 紧凑 / 缩进 / CDATA 用例；见 #15 |
| 14 | `f_xml/src/XmlconfHarness_test.cj` | .cj | ✅ | 见 #15；harness 本身逻辑与注释口径一致 |
| 15 | `f_xml/src/f_xml.cj` | .cj | ✅ | 仅包注释 + `Charset`/`Charsets` 再导出，与 `XmlWriterOptions.charset` 需求自洽 |

合计：`.cj` 15 个 / `.md` 0 个 / 共 15 个，全部读完。

## 覆盖自检

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
| 严重 | 0 |
| 一般 | 7 |
| 轻微 | 8 |
| 优化方案（堆内存 / CPU） | 3 / 0 |

存量 15 条（本部分无本次改动），是否纳入修复待用户决定。

## 总评

写侧（`XmlWriter` + `XmlWriterOptions`）是本部分的风险重心：7 条一般问题里有 6 条落在这里，且都不是「性能还可以更好」而是**输出错误或非法文档**——`setAttr` 覆盖丢前缀、`Doctype.isDeclared` 放过参数实体、`EntityDecl.toString` 丢 PUBLIC、`writeDeclaration` 可写进元素内、`toString` 不转义、`CdataMode.Auto` 空承诺。这些都在默认配置的主路径上，静默失败（不抛错、产出错误 XML），建议优先修。

读侧（`XmlParser` / `XmlPullParser` / `XmlNode` / `XmlOptions`）质量明显更好：三入口收敛到同一个内核、`dispatch` 穷尽 `XmlEvent`、`close()` 用 `Resource` 类型判定只关资源型流、`maxElementDepth` 在引擎层统一把关，未发现解析正确性或实体安全缺陷；剩下的递归风险（#7）只在手工构造超深 DOM 时成立，可排期。

测试覆盖与代码质量匹配：推拉一致性、增量/整树逐字节对齐、编码往返、实体上限都有对应用例，缺陷集中在「未被用例覆盖的契约分支」（声明位置、参数实体、setAttr 前缀、Auto CDATA），补 4 条用例即可锁死这批回归。
