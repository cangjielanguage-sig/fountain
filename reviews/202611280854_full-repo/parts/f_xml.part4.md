# f_xml 模块审查报告（第 4/7 部分）

> **模块第 4/7 部分**（本报告只覆盖 `files/f_xml.part4.txt` 列出的 20 个文件：`doc/spec/reuse-f-xml-writer-scratch/tasks.md`、`doc/xmlconf-unsupported.md`，以及 `src/` 下的 `ByteScratch` / `ByteSniffer` / `DoctypeParser` / `EntityExpander` / `DomBuilder` 与对应 13 个测试文件。文件覆盖、覆盖自检、模块统计均只统计本部分；`README*`、其余 `doc/**` 与其余 `.cj` 由第 1–3、5–7 部分产出。为取证需要引用了范围外文件的行号（`ExpandSink.cj`、`XmlOptions.cj`、`Lexer.cj`、`ParserEngine.cj`、`XmlParser.cj`），只作判据、不占统计。）

- **审查日期**：2026-11-28
- **模块路径**：`f_xml`（本部分 18 个 `.cj` + 2 个 `.md`）
- **基线**：工作区快照（sts/1.3.x 工作区，无 diff ⇒ 全部问题记「存量」）
- **审查重点**：XML 解析 / 序列化正确性与安全（XXE、实体展开、转义）、递归与栈溢出、OOM、死代码、重复逻辑、存量 BUG。本部分实际落在字符层（`ByteSniffer` / `ByteScratch`）、DTD 声明语法（`DoctypeParser`）、实体展开（`EntityExpander`）与 DOM 组装（`DomBuilder`）四段
- **报告版本**：v1（第 4/7 部分）

## 发现

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

## 优化可行性方案

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

## 待验证假设

> 没有性能测试数据支撑的猜测，**不进** `todo.md` / `tasks.md`，只用于下一轮补数据。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 每次实体引用 `runesOf` + `cps32Of` 造成分配量随"引用次数 × 实体长度"放大，GC 时间是该路径的主要成本 | `f_xml/src/EntityExpander.cj:77,114` | 分配字节数、GC 停顿占比 | 60 KB 实体 × 1e4 引用，`cjprof heap` + `getAllocatedHeapSize()`，`-O2` |
| 2 | `checkReplacement` 为每个含 `<` / `&` 的实体新建一套 `Lexer`（含 `NameTable` 初始槽数组），1024 条实体声明时固定开销可观 | `f_xml/src/EntityExpander.cj:139-141` | 每实体固定开销、总占比 | 1024 条 `<!ENTITY>` 的 DTD，`cjprof record` 看 `Lexer` 构造与 `checkReplacement` 自耗时 |
| 3 | `startsWith` / `skipUntil` 的逐字符 `runesOf` 是 DTD 扫描的主要分配来源 | `f_xml/src/DoctypeParser.cj:181-192,415-424` | 分配次数、自耗时占比 | 2000 声明 + 100 KB 注释的 DTD，`cjprof record` + 分配计数埋点 |
| 4 | `ByteSniffer.readUpTo` 每次 `read` 都新建一个"剩余长度"大小的数组，慢速输入流（每次 1 字节）下产生 1028 次递减分配 | `f_xml/src/ByteSniffer.cj:132-143` | 单次 sniff 的分配次数与字节数 | 用每次 `read` 只返回 1 字节的 `InputStream`，计数分配次数（`cjprof heap`） |
| 5 | `AttTypeMap` 的「每元素名一张 `HashMap`」结构造成显著内存放大 | `f_xml/src/DoctypeParser.cj:69-92` | 每条 AttDef 的实际字节数 | 10 万条 ATTLIST 输入，`getAllocatedHeapSize` 峰值对照「无 ATTLIST」基线 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_xml/doc/spec/reuse-f-xml-writer-scratch/tasks.md` | .md | ✅ | 归档变更记录；`[x]` 与 `ByteScratch` 现有成员一致（`append` / `putCp` / `reset` / `bytes` / `toUtf8String` 均在，`XmlWriter.buffer` 已改 `ByteScratch`，`Escaper` 三个方法的 `out` 均已是 `ByteScratch`），`F_XML_BENCH` 基准断言与 `XmlWriterScratch_test.cj:186-220` 一致；仅 `1.3` 的行号区间 `34-101` 已不含 `bytes()`（:103）/ `toUtf8String()`（:107），属历史条目，按 §13 误报边界不记问题 |
| 2 | `f_xml/doc/xmlconf-unsupported.md` | .md | ✅ | 生成物，524 行与统计（2586 − 524 = 2062，2062 − 24 = 2038）自洽，原因分布 `edition 313 / external-entity 95 / xml-1.1 59 / external-subset 47 / namespace-name 10` 逐项复算一致；`tools/xmlconf_gen.py` 存在；见 #18（24 条差额未在本文档说明） |
| 3 | `f_xml/src/AttrNormalize_test.cj` | .cj | ✅ | 属性类型映射与规范化用例，与 `Lexer.normalizeAttributeTypes` 对得上 |
| 4 | `f_xml/src/BlockRuneSource_test.cj` | .cj | ✅ | 块边界、代理对、UTF-16/32 用例，无问题 |
| 5 | `f_xml/src/BufferReuse_test.cj` | .cj | ✅ | 见 #13（`attributeArrayLengthIsExact` 断言可能落空）；`ByteScratch` 与 `StringGenerator` 对拍用例有效 |
| 6 | `f_xml/src/ByteScratch.cj` | .cj | ✅ | 见 #5（`nextId` 静态自增无同步）；`putAscii` / `append` / `bytes` / `reset` / `toUtf8String` 均有调用者，`bytes()` 的「零拷贝视图 + 外部配合 `size`」契约在 `NameTable.cj:84-101` 被正确使用 |
| 7 | `f_xml/src/ByteSniffer.cj` | .cj | ✅ | 见 #4 / #9 / #10；BOM 优先级、魔数、UTF-16/32 解码逻辑与 XML 1.0 附录 F 对得上 |
| 8 | `f_xml/src/ByteSniffer_test.cj` | .cj | ✅ | BOM / 魔数 / 声明 / 冲突 14 例；#4 的缺口（注释内伪声明）与「声明超出 1028 字节窗口」均未覆盖 |
| 9 | `f_xml/src/CharLayerParity_test.cj` | .cj | ✅ | 见 #14（`inputFactory` 死参数）；6 档 bufSize × 4 种编码的等价性网有效 |
| 10 | `f_xml/src/CharRef_test.cj` | .cj | ✅ | 含 `Cdata_test` / `CommentPi_test`；字符引用边界（NUL / 代理区 / >0x10FFFF）已覆盖，长数字溢出（#3）未覆盖 |
| 11 | `f_xml/src/CharsetRuneSource_test.cj` | .cj | ✅ | GBK 路径与 bufSize 不变性，无问题 |
| 12 | `f_xml/src/DoctypeParser.cj` | .cj | ✅ | 见 #2（`parseGroup` 无界递归）、#3（字符引用解析重复 + 溢出）、#7（`AttTypeMap` 无上限）、#8（`AttType.toString` 接口冗余）、#11（注释不校验 `--`）；`1022` 行 `expandCharRefs` 函数体首行紧贴 `{`，与全仓格式不一致（可读性，不单列） |
| 13 | `f_xml/src/DoctypeParser_test.cj` | .cj | ✅ | 四类声明 + 实体展开/前向引用/standalone 三档，用例与实现一致；未覆盖深层内容模型与超长字符引用 |
| 14 | `f_xml/src/DomBuilder.cj` | .cj | ✅ | 文本合并、`xml:space` 作用域、prolog/epilog 分流均正确；顶层空白文本被 `ParserEngine.handleText` 拦下，`prolog` 实际只会收到注释 / PI，与 `XmlNode.cj:280-283` 的契约一致 |
| 15 | `f_xml/src/DomBuilder_test.cj` | .cj | ✅ | 9 例覆盖合并 / trim / `xml:space` / prolog-epilog / 深度上限 |
| 16 | `f_xml/src/DtdDeclSyntax_test.cj` | .cj | ✅ | 声明语法矩阵；`doctypeWith` / `assertDoctypeError` 仅本文件使用（非死代码，属可见性可收窄） |
| 17 | `f_xml/src/EntityCounterIsolation_test.cj` | .cj | ✅ | 实例级计数与双线程隔离；正是 #5 的并发证据（但未覆盖 `nextId` 竞态） |
| 18 | `f_xml/src/EntityExpander.cj` | .cj | ✅ | 见 #1（`feed` 落盘分支不可达）、#3（钳制对比）、#6（读回器泄漏）、#12（计数重复）、#15（256 块偏移）、#16（`0:0`）、#17（policy 分支不可达） |
| 19 | `f_xml/src/EntityLimits_test.cj` | .cj | ✅ | 深度 / 声明数 / 硬限 / 属性值四类；`degradeRetrySucceeds` 通过但验证不到落盘（见 #1） |
| 20 | `f_xml/src/EntityReplacementWf_test.cj` | .cj | ✅ | 替换文本良构校验 9 例，与 `checkReplacement` 逐条对应 |

合计：`.cj` 18 个 / `.md` 2 个 / 共 20 个，全部读完。

## 覆盖自检

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

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 2 |
| 一般 | 5 |
| 轻微 | 11 |
| 优化方案（堆内存 / CPU） | 2 / 1 |

## 总评

这四段是全模块最"硬"的部分，代码本身的可读性和防御意识都不错：`ByteScratch` 的容量复用与零拷贝视图、`ByteSniffer` 的 BOM → 魔数 → 声明优先级、`DoctypeParser` 对四类声明产生式的逐条校验（连 `NDATA` 只能在外部实体上、`%p ;` 不允许中间空白这种细节都做了）、`EntityExpander` 的"先校验替换文本良构再接线"、`DomBuilder` 的文本合并与 `xml:space` 作用域，都是照着 XML 1.0 逐条实现的，XXE 面也确实封死了（外部实体只记声明、引用即抛，外部子集永不加载，`SpillDir` 不接收任何外部路径）。这批代码的主要风险不在"写错规范"，而在**边界的最后一公里**。

两条阻塞项都在"边界"上：

1. **#1 的落盘链路没有接线**。这是本部分最需要动作的一条：`feed` 在第 82 行把所有超过 64 KB 的实体直接拒掉，第 108 行那段唯一会 `spill()` 的代码因此永远走不到，于是默认 `Spill` 策略与设计文档 §5.4.1 / README 的承诺完全相反——单个大实体被拒、8 MB 总量阈值形同虚设、真正的拒绝点是 2 GiB 硬限。它同时解释了为什么 `EntityLimits_test.degradeRetrySucceeds` 与 `Spill_test` 都是绿的：一个走内容路径（根本不落盘）却断言"成功"，另一个直接构造 `ExpandSink`（绕过主路径）。修法很小（按 `overflowPolicy` 决定 :82 抛还是 :108 落盘，并把 `EntityCounter()` 换成 `this.counter`），但必须补上"能区分落盘与不落盘"的用例，否则回归网仍然证明不了这条链路活着；修好之后 #6 的临时文件泄漏会立刻成为现实路径，应与 #1 同批处理。
2. **#2 的 DTD 递归没有上限**。这是纯解析侧的崩溃面：一份 1 MB 的 `<!ELEMENT>` 就能压 10⁵ 层栈帧，且不可捕获。它与实体递归（16 层硬限）、参数实体递归（`maxDepth`）在同一文件里，唯独内容模型这条路径没有计数——属于"同一类风险只堵了两条路"。

一般项五条（#3 字符引用溢出的异常类型逃逸、#4 注释内伪声明改变编码判定、#5 `nextId` 的数据竞争、#6 溢出文件在异常路径泄漏、#7 `ATTLIST` 声明无上限）都是"小输入 + 边界"型，单条影响有限，但都会让调用方看到契约外的行为（`OverflowException`、错误编码、重复 id、残留临时文件、随 DTD 放大的内存）。十一条轻微项集中在测试可靠性（#13 / #14）、死代码与冗余（#8 / #10 / #17）、文档与注释的精度（#9 / #12 / #15 / #16 / #18）与一处良构性缺口（#11）。

另需在合并报告里对齐口径：第 2、3 部分的文档审查据 `design.md` / spec 认定"`Spill` 下内存恒定、2 GB 上限落磁盘不落堆"，那只在**直接驱动 `ExpandSink`** 时成立；解析主路径并不落盘（#1）。合并时请以本部分的代码取证为准，并把第 2/3 部分的 §5 OOM「0 命中」改为"文档有承诺、实现未接线"。

存量 18 条（严重 2 / 一般 5 / 轻微 11），是否纳入修复待用户决定。
