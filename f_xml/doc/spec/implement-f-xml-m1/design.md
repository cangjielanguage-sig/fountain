# Design: 实现 f_xml M1

> 依据 `f_xml/doc/f_xml模块设计.md` v1.1（下称「设计文档」）。本文只处理 **M1** 的落地细节，
> 并对设计文档里无法字面实现、或与仓库现状冲突的地方给出结论（§8）。
> **唯一入库副本**：`f_xml/doc/spec/implement-f-xml-m1/`。`openspec/changes/implement-f-xml-m1/`
> 是本地工作副本（`openspec/` 已被 `.gitignore` 忽略）；两份 SHALL 逐文件字节一致（见 `tasks.md` 12.7）。
> 同步以入库副本为准：`rsync -a --delete f_xml/doc/spec/implement-f-xml-m1/ openspec/changes/implement-f-xml-m1/`
> 校验：`diff -ru f_xml/doc/spec/implement-f-xml-m1 openspec/changes/implement-f-xml-m1` 无输出。

## 1. 目标与非目标

### 目标

1. `f_xml` 成为通用的 XML 1.0（含 Namespaces 1.0）解析 / 生成模块，**不绑定任何业务格式**。
2. 三个解析前端共用**一套词法器、一种事件序列**：拉模式（`nextEvent`）、单回调、多回调。
3. DOM 由事件流累积而成；生成器从 DOM 序列化，紧凑模式为默认。
4. 支持 DTD **内部子集**实体（普通 + 参数），外部实体与外部子集**永不加载**。
5. 实体膨胀的三层上限与溢出策略可配置、可分类、可降级重试。
6. xmlconf 20130923 的 2154 条断言全过（Gate A），`unsupported` 清单可复核。

### 非目标

- M2（XPath 1.0 子集）与 M3（XML 1.1、C14N inclusive/exclusive）：本次不写任何相关公开 API。
- DTD 校验、默认属性注入、外部子集加载、NOTATION。
- 不为了「多支持一点」放宽 XML 1.0 的严格性——不合法的输入必须报错，不猜。

## 2. 范围边界

| 能力 | M1 | M2 | M3 |
|---|---|---|---|
| 推 / 拉 / 单回调、`skipElement` | ✅ | | |
| DOM、命名空间解析、生成器、内部实体、安全上限 | ✅ | | |
| XPath 1.0 子集 + `XPathContext` | | ✅ | |
| XML 1.1、`canonicalize`（inclusive 1.0/1.1 + exclusive 1.0） | | | ✅ |

M1 的 API 形状需保证不阻碍 M2/M3：`XmlNode` 保留注释 / PI 节点（C14N `withComments` 需要），
`XmlDocument` 保留 `prolog` / `epilog`，`QName` 保留 `prefix`（`name()` 需要）。

六个 spec 分册各覆盖一层，分册开头的范围摘要统一收在本文，spec 文件只保留 Requirement：

| spec | 覆盖内容 |
|---|---|
| `f-xml-char-layer` | 数据源、字节嗅探、前缀回放、字符来源、行拼接、编解码失败策略 |
| `f-xml-stream-parser` | 事件模型、三个前端、`skipElement`、词法与状态机、字符引用、CDATA、注释与 PI、命名空间解析 |
| `f-xml-dom` | DOM 模型与事件到树的累积 |
| `f-xml-writer` | 紧凑 / 缩进、转义、非法字符、CDATA 模式、自定义实体、输出编码与缓冲 |
| `f-xml-dtd-entities` | DTD 内部子集实体、三层上限、溢出策略与安全边界 |
| `f-xml-conformance` | xmlconf 20130923 套件、恶意样本与格式样本 |

**XML 1.1 的失败语义**：M1 遇到 `<?xml version="1.1"?>` 直接抛
`XmlException("XML 1.1 尚未支持（M3）", line, column)`，**不降级按 1.0 解析**。
理由是 1.1 放宽了字符范围，按 1.0 解析会把合法文档判成非法，错误信息会误导。

## 3. 依赖与复用查证

### 3.1 依赖表（不变）

```toml
[dependencies]
  "fountain::f_base" = {path = "../f_base"}
  "cangjie_tpc::charset4cj" = "1.0.5"
```

`f_xml/cjpm.toml` 现状已满足，本变更**不修改**该文件。`include = ["src"]` 保持不变，
`.cache/` 不入包（测试通过路径解析读取，见 §9.3）。

### 3.2 `f_base.StringGenerator`（`f_base/src/StringGenerator.cj:22`）

| 成员 | 实测签名 / 行为 | f_xml 用法 |
|---|---|---|
| `init()` / `init(s: String)` | 内部 `ArrayList<Byte>` | 文本累积、输出缓冲 |
| `append<T>(content) where T <: ToString` | `utf8.add(all: content.toString().unsafeBytes())` | 追加字符串片段 |
| `append(r: Rune)` | ASCII 走单字节 `add`，非 ASCII 走 `Rune.intoUtf8Array` | 逐字符转义时用，避免每字符分配 String |
| `size` | **字节数**（`utf8.size`），不是字符数 | 单块长度判断 |
| `unsafeBytes()` | `utf8.unsafeData()`，零拷贝 | 直接喂 `OutputStream.write` |
| `toString()` | `String.fromUtf8Unchecked(unsafeBytes())`，零拷贝 | 需要 String 时用 |

三条复用结论：

1. **长度语义可直接依赖**：`toString()` 与 `endsWith()`（`:126`）都假定
   `unsafeBytes().size == size`，否则会出现尾部 `NUL`。所以「长度 == size、冗余已剪除」
   这一前提在 `f_base` 内部已被使用；仍在 §10 的待实测项里确认一次。
2. **不缓存返回值**：`ArrayList` 扩容会换底层数组，缓存句柄可能看不到后续写入。
   要用就重新取（重新取是零成本的）。
3. **非线程安全**（无锁）；`XmlWriter` 单线程使用，不做同步。

### 3.3 `f_base.BaseException`（`f_base/src/BaseException.cj:44`）

`open class BaseException <: Exception`，提供 `init(message)`、`init(message, caused)`、
`addSuppressed`、`suppressed`、`printStackTrace(output)`。`f_egraph.GraphException` 即此法。

结论：`XmlException <: BaseException`。构造器：

```cangjie
public init(message: String)                                    // line = 0, column = 0, kind = None
public init(message: String, line: Int64, column: Int64)        // kind = None
public init(message: String, line: Int64, column: Int64, kind!: ?EntityLimitKind)
```

即设计文档 §9 的两个构造器 + 一个无位置便捷构造（`skipElement` 前置条件、`spillDir` 失败这类
没有源码位置的错误用它）。`line = 0` 表示「位置未知」，不是「第 0 行」。

### 3.4 `charset4cj`

| 项 | 实测 | 说明 |
|---|---|---|
| 依赖别名 | `cangjie_tpc::charset4cj` | `cjpm.toml` 的 key 是 `"cangjie_tpc::charset4cj"` |
| 包路径 | `cangjie_tpc::charset4cj.charset.{Charsets, TextReader, TextWriter}`、`...charset.encoding.Charset` | 与 `f_base` / `f_zip` / `f_process` 一致 |
| 构造 | `TextReader(stream, charset: charset)`、`TextWriter(output, charset: charset)` | `f_process/src/CurrentProcess.cj:25,29` |
| 版本 | 仓库 9 个模块统一 `1.0.5` | 设计文档写 `1.0.6`；1.0.5 的导入路径**已经是** `charset4cj.charset.*`，故「1.0.6 才改布局」这条不成立 |

`Charset` 出现在公开 API（`XmlWriterOptions.charset`），因此 `f_xml` 需
`public import cangjie_tpc::charset4cj.charset.encoding.Charset` 与
`public import cangjie_tpc::charset4cj.charset.Charsets`（参照 `f_httpclient/src/ExtendHttpResponse.cj:21-22`），
否则调用方无法命名该类型。

### 3.5 明确不复用的相邻实现

| 相邻能力 | 位置 | 为什么不复用 |
|---|---|---|
| 四级临时目录探测 | `f_zip/src/TempSpill.cj:35` | 设计文档 §5.4.2 明确「各模块私有约 20 行，不提到公用模块」；`f_xml` 不依赖 `f_zip` |
| `InputStream` 适配器写法 | `f_zip/src/BoundedStream.cj:27` | 仅作 `PrefixStream` 的写法参照（`read(buffer): Int64`，EOF 返回 `-1`），不引用代码 |

## 4. 包结构

**单包 `fountain::f_xml`，扁平 `src/*.cj`。**

理由：仓颉的 `internal` 对**父包不可见**（`f_egraph` 实施时实测踩到：`loader` 子包的 `internal`
类型无法被根包调用），而 f_xml 的字符层、词法层、实体层之间共享大量内部类型；分子包会逼着把
内部类型改成 `public`，等于把实现细节漏到 API 面上。`f_zip` / `f_orm` 也是扁平单包。

| 文件 | 职责 |
|---|---|
| `f_xml.cj` | 包文档 |
| `XmlException.cj` | `XmlException`、`EntityLimitKind` |
| `XmlOptions.cj` | `XmlParserOptions`、`EntityLimits`、`EntityOverflowPolicy`、`InvalidByteMode`、`InvalidCharMode` |
| `QName.cj` | `QName`、`XmlAttribute`、`SourcePosition` |
| `XmlNode.cj` | `XmlNode`（enum）、`XmlElement`、`XmlDeclaration`、`DocTypeInfo`、`XmlDocument`、`EntityDecl`、`XmlEntityRef`（工厂函数） |
| `XmlEvent.cj` | `XmlEvent`、`XmlAction`、`XmlEventHandler` |
| `XmlPullParser.cj` | 拉模式前端（唯一内核） |
| `XmlParser.cj` | 多回调 / 单回调 / `parse` 的 4 个 DOM 重载 |
| `DomBuilder.cj` | 事件 → DOM |
| `PrefixStream.cj` | 前缀回放流 |
| `ByteSniffer.cj` | BOM / 魔数 / 声明的编码嗅探 |
| `RuneSource.cj` | `RuneSource` 接口 + `ByteDecoder` + `Utf8ReplaceDecoder` + `Utf8RuneSource` + `CharsetRuneSource` + `BlockRuneSource` |
| `LineWindow.cj` | 行拼接、行尾归一、≤4 前瞻、行列号 |
| `Lexer.cj` | 词法 + 状态机 + 名称栈 |
| `SkipScanner.cj` | `skipElement` 的标签级扫描 |
| `NamespaceScope.cj` | 命名空间作用域栈 |
| `EntityTable.cj` | 实体声明表（普通 / 参数） |
| `DoctypeParser.cj` | 内部子集解析与跳过 |
| `EntityExpander.cj` | 递归展开 + 计数 + 溢出判定 |
| `ExpandSink.cj` | `MemorySink` / `FileSink` / 读回 |
| `SpillDir.cj` | 四级临时目录解析 |
| `XmlWriter.cj` | 序列化 + 输出缓冲 + 编码 |
| `XmlWriterOptions.cj` | `XmlWriterOptions`、`CdataMode`、`Doctype` |
| `Escaper.cj` | 文本 / 属性值转义与非法字符检查 |

## 5. 公开 API

选项结构体按仓颉 `init` 命名形参落地（设计文档里的字段级 `!` 是示意）。

```cangjie
package fountain::f_xml

public struct XmlParserOptions {
    public let bufSize: Int64                  // 默认 8192
    public let trimWhitespaceOnly: Bool        // 默认 false
    public let entityLimits: EntityLimits
    public let onInvalidByte: InvalidByteMode  // 默认 Strict
    public let maxElementDepth: Int64          // 默认 4096（G1）
    public let maxAttributeValueLength: Int64  // 默认 1 MiB（G2）
    public init(bufSize!: Int64 = 8192, trimWhitespaceOnly!: Bool = false,
                entityLimits!: EntityLimits = EntityLimits(),
                onInvalidByte!: InvalidByteMode = InvalidByteMode.Strict,
                maxElementDepth!: Int64 = 4096,
                maxAttributeValueLength!: Int64 = 1024 * 1024)
}

public static func XmlParser.parse(input: InputStream, options!: XmlParserOptions = XmlParserOptions()): XmlDocument
public static func XmlParser.parse(bytes: Array<Byte>, options!: XmlParserOptions = XmlParserOptions()): XmlDocument
public static func XmlParser.parse(text: String, options!: XmlParserOptions = XmlParserOptions()): XmlDocument
public static func XmlParser.parse(path: Path, options!: XmlParserOptions = XmlParserOptions()): XmlDocument
public static func XmlParser.parse(input: InputStream, onEvent: (XmlEvent) -> XmlAction,
                                   options!: XmlParserOptions = XmlParserOptions()): Unit
public static func XmlParser.parse(input: InputStream, handler: XmlEventHandler,
                                   options!: XmlParserOptions = XmlParserOptions()): Unit
```

其余类型严格按设计文档 §3 / §4 / §5.4 / §7 / §9 落地，差异仅 §8 登记的六项。

## 6. 关键实现路线

### 6.1 字符层

```
InputStream
  → ByteSniffer.sniff()      读 ≤4 字节判 BOM，再读至多 1024 字节找 xml 声明
  → PrefixStream(prefix, rest)
  → RuneSource（按编码选实现）
  → LineWindow               行拼接 + \r→\n + ≤4 前瞻 + 行列号
  → Lexer
```

**嗅探优先级**：BOM > 声明 > UTF-8。BOM 与声明冲突时以 BOM 为准（不做「报错」——
设计文档 §12.2 H 写的是「以 BOM 为准，或按规范报错」，M1 选前者，理由是现实文档里
「UTF-8 BOM + 声明 latin1」极常见，报错会把大量可读文件判死）。

**读取字节上限**：嗅探最多消费 4 + 1024 字节，全部进 `PrefixStream` 回放；`PrefixStream`
不做编码判断，纯字节搬运。

**`RuneSource` 与共享字节层**：

| 实现 | 底层 | 适用 | 读取方式 |
|---|---|---|---|
| `Utf8RuneSource`（Strict） | `std.io.StringReader<T>` | UTF-8 + `InvalidByteMode.Strict` | `readln()` |
| `Utf8RuneSource`（Replace） | 自研 `Utf8ReplaceDecoder` + 共享 `ByteDecoder` | UTF-8 + `InvalidByteMode.Replace` | 固定 `bufSize` 块读字节 |
| `CharsetRuneSource` | `charset4cj.TextReader` | GBK 等 | `readln()` |
| `BlockRuneSource` | 共享 `ByteDecoder` + 编码 Decoder | UTF-16 / UTF-32 | 固定 `bufSize` 块解码 |

`ByteDecoder` 是 `RuneSource.cj` 里的共享字节层：固定块读取、块尾不完整字符回退（≤ 3 字节）、
坏字节分类、按字符推进行列号。`BlockRuneSource` 用它承载 UTF-16/32 解码器；UTF-8 的 `Replace`
路径用它承载 RFC 3629 maximal-subpart 解码器——两者共用同一套块边界与回退逻辑，不各写一份。
`Strict` 路径 SHALL NOT 经过该解码器，必须保持 `std.io.StringReader` 的原始行为。

`InvalidByteMode` 的两条路径由测试分别钉住，互不替代：

- **`Strict`**：坏字节抛 `XmlException`，消息带行号、列号与坏字节偏移；所有合法输入的逐字符输出
  与 `StringReader` 一致。
- **`Replace`**：按 RFC 3629 maximal subpart 消费，每个最大子部分产出**恰好一个** `U+FFFD`；
  块边界处截断的多字节序列与块内截断必须得到相同结果，后续字符不错位。

`BlockRuneSource` 是新增的第三个实现（§8 差异 6）。原因是 `readln()` 按**字节**找 `0x0A`，
UTF-16 里 U+0A00 的低字节就是 `0x0A`，会在字符中间断行。固定块解码需要处理「块尾半个字符」：
读入 `bufSize` 字节后，若末字节是 UTF-8 前导字节或 UTF-16 高位代理，把不完整尾字节留到下一块
（UTF-16/32 按 2/4 字节对齐，回退量恒 ≤ 3 字节）。这套回退只在 `ByteDecoder` 里实现一次。

GBK 仍走 `readln()`：GBK 的尾字节范围是 `0x40–0x7E` / `0x80–0xFE`，不含 `0x0A`，不会误断行。

**行拼接三约定**（设计文档 §2.4）：`Some("")` 是空行要补 `\n`；`None` 是流结束**不补**；
`\r` 归一只在 `LineWindow` 这一层做（两层都做会得到 `\r\r\n`）。

**`peek(offset)` 只保证 `offset ≤ 4`**，实现用固定 8 槽环形缓冲。

### 6.2 词法与状态机

```
PROLOG ─┬─ <?xml?> / <!DOCTYPE> / <!-- --> / <?pi?> ─→ PROLOG
        └─ <name ...> ─→ CONTENT
CONTENT ─┬─ <name ...> 入栈 / </name> 出栈（栈空转 EPILOG）
         ├─ text / <![CDATA[]]> / <!-- --> / <?pi?>
EPILOG ─┬─ <!-- --> / <?pi?> ─→ EPILOG
        └─ EOF
```

状态机只回答「当前位置允许出现什么」，元素配对靠**名称栈**（存展开名 `QName`，
按 `uri + local` 比较，而不是按字面名）。

**重复属性判定按展开名**：`<a xmlns:p="u" xmlns:q="u" p:x="1" q:x="2">` 是非法
（XML Namespaces §6.3），字面名不同但展开名相同。

### 6.3 事件与前端

```cangjie
while (let Some(e) <- pull.nextEvent()) {
    let action = dispatch(e)
    if (action == XmlAction.Stop) { break }
    if (action == XmlAction.SkipSubtree) { pull.skipElement() }
}
```

`XmlEvent` 只实现 `ToString`（不实现 `Equatable`，因为带载荷的比较语义没有意义），
`toString()` 输出**稳定文本**供「推 / 拉事件日志逐行 diff」的验收使用：

```
START document
DECL 1.0 encoding=UTF-8 standalone=-
DOCTYPE rss - -
START QName(-,rss,http://purl.org/rss/1.0/) attrs=1 selfClosing=false
TEXT "我的订阅" 6
END QName(-,rss,http://purl.org/rss/1.0/)
END document
```

（`TEXT "..." 6` 的 6 是字符数，便于断言拆分行为。）

**枚举比较必须显式实现**：仓颉 enum **不自动派生** `==`；声明 `<: Equatable<T>` 后必须自己提供
`operator func ==`。`XmlAction` SHALL 声明 `<: Equatable<XmlAction> & ToString` 并显式写：

```cangjie
public operator func ==(that: XmlAction): Bool {
    match (this, that) {
        case (Continue, Continue) => true
        case (SkipSubtree, SkipSubtree) => true
        case (Stop, Stop) => true
        case _ => false
    }
}
```

`InvalidByteMode` / `InvalidCharMode` / `CdataMode` / `EntityOverflowPolicy` / `EntityLimitKind`
同样声明 `Equatable` 并各自显式实现 `operator func ==`。不写实现会编译失败；靠 `match` 手写比较
还能在新增分支时被穷尽性检查拦住。仓库里 `f_zip.CompressionMethod` 因未声明 `Equatable` 无法
`==` 比较，M1 不重犯。

### 6.4 `skipElement()` 的边界

- 只能在「刚产出 `StartElement`」之后调用；其他位置抛
  `XmlException("skipElement 必须在 StartElement 之后调用")`（`line = column = 0`）。
- **`selfClosing = true` 时是空操作**：`<a/>` 的深度已经配对，此时若吞掉待发的 `EndElement`，
  推模式 handler 的栈就失衡了。
- 跳过的是**子节点**，匹配的 `EndElement` 仍然发出。
- 跳过期间不解析属性值、不解码实体、不建节点，但必须正确处理：引号内的 `>`、`<!-- -->`、
  `<![CDATA[ ]]>`、`<? ?>`。这几条缺一个，`<!-- a > b -->` 就能骗过扫描器。

### 6.5 命名空间

进入元素时把 `xmlns` / `xmlns:prefix` 压入作用域栈；出栈时弹出。`xml` 前缀固定绑定
`http://www.w3.org/XML/1998/namespace`，不需要声明；`xmlns` 作元素前缀报错。

**属性不受默认命名空间影响**：`<a xmlns="X" b="1">` 里 `b` 的 `uri = None`。
这条单独写用例（设计文档 §12.2 G 明确要求）。

`xmlns=""` 是重置默认命名空间的唯一手段，作用域栈里存 `Some("")` 表示「重置为无命名空间」，
解析时映射为 `None`。

### 6.6 DOM

```cangjie
public enum XmlNode {
    | ElementNode(XmlElement)
    | TextNode(String)
    | CDataNode(String)
    | CommentNode(String)
    | PiNode(String, String)          // target, data
    | EntityRefNode(String)           // 显式实体引用，见 §8 差异 2
}
```

`DomBuilder` 处理三件事：

1. **相邻文本合并**：上一个子节点也是 `TextNode` 就追加，不新建（`StringGenerator` 累积）。
2. `trimWhitespaceOnly = true` 时丢弃**纯空白**文本节点；`xml:space="preserve"` 作用域内强制保留。
3. `maxElementDepth` 超限抛错（既有恶意样本要求，见 §8 差异 5）。

`XmlElement.child(name)` / `attr(name)` 按 **local name** 匹配；`attr(ns, local)` /
`childrenOf(name)` 同理。`text()` 拼接所有后代文本（含 CDATA），不含注释与 PI。

### 6.7 DTD 内部子集

`DoctypeParser` 只理解 `<!ENTITY>`，其余声明**跳过但必须跳对**（能识别引号与内部 `>`）。
条件段 `<![INCLUDE[ ]]>` / `<![IGNORE[ ]]>` 按标志位选择分支。

**属性值处理顺序**（做反了会留下本不该有的 `\n`）：

```
字符引用 + 实体引用展开  →  换行/制表归一成空格
```

**不做首尾 trim**：XML 只对**非 CDATA 类型**的属性值去首尾空格，而 M1 不解析 `<!ATTLIST>`
（因此拿不到属性类型），一律按 CDATA 处理。这是规范行为，不是遗漏。

**M1 的实体展开发生在字符层之上**：展开结果已经是 `String`，不再回到字节层。

### 6.8 实体上限与溢出

计数器挂在「往输出追加字符」的那一刻，**不能先拼成字符串再量长度**（10 层 ×10 倍 = 10¹⁰ 字符）。

```
每追加一段 seg：
  if (sink is Memory && total + seg.len > maxExpandedTotal):
      把 MemorySink 已有内容倒进 FileSink（一次性）；sink = FileSink
  if (total + seg.len > maxExpandedHardLimit): throw HardLimit
  total += seg.len; sink.write(seg)
```

**切换单向、不回头**：反复切换会产生大量小文件，而磁盘 IO 已是瓶颈。

**溢出文件恒为 UTF-8**：`FileSink` 写的是**已解码的字符**的 UTF-8 编码，与输入编码无关。
读回时按 `bufSize` 分块解码，块尾不完整字节按 UTF-8 前导字节回退（≤3 字节），
对 `onText` 完全透明（消费方只看到分块，本来就允许一段文本拆成多次回调）。

**属性值不溢出**：属性值必须在开始标签解析完后整体在内存（要参与命名空间解析、`xml:space`
判定），所以单实体超 `maxExpandedPerEntity` 时即便 `Spill` 也抛
`EntityLimitKind.AttributeValue`，消息带属性名：
`属性 'r' 的值中实体展开超过 64 KB，属性值不支持溢出（第 3 行第 17 列）`。

**临时目录四级**（OHOS 无 `/tmp`）：`EntityLimits.spillDir` → `TMPDIR` →
`env.getTempDirectory()` → `env.getWorkingDirectory().join(".fountain_tmp")`（自动创建）。
四级全失败抛 `XmlException("无法创建实体溢出文件，请显式指定 spillDir")`，**不降级回内存**。

**`standalone` 语义**：`"yes"` 且引用了只有外部子集才声明的实体 → 报错；`"no"` 或省略 →
跳过该实体并记一条告警（不报错）。不区分会让 xmlconf 里一批带外部 DTD 的**合法**文档被误判。

### 6.9 生成器

```
DOM → token 序列 → StringGenerator（UTF-8 字节缓冲，8~64 KB 冲一次）
                            ├─ UTF-8  → OutputStream.write(bytes)
                            └─ 其他   → charset4cj.TextWriter.write(String)
```

- **UTF-8 路径不经过 `String`**：`StringGenerator.unsafeBytes()` 直接给字节。
- **UTF-16/32 自己写 BOM**（`Encoder.encode` 不产 BOM）；**UTF-8 不写 BOM**。
- **UTF-8 / UTF-16 / UTF-32 跳过 `InvalidCharMode` 往返校验**（恒可编码），只有 GBK 等
  窄字符集才做「encode → decode → 比较」。
- **`Replace` 用 `?`（0x3F）**，不用 U+FFFD（GBK 表示不了 U+FFFD）。
- **不用 `writeln()`**：紧凑模式不产生换行，缩进模式的换行只由 `indent` 产生。
- `close()` 之后任何调用都是未定义行为，类注释必须写明。

### 6.10 错误

| 错误 | `entityLimitKind` | 消息要点 |
|---|---|---|
| 单实体 > 64 KB（`Strict`） | `Some(PerEntity)` | 实体名、已展开量 |
| 总展开 > 8 MB（`Strict`） | `Some(Total)` | 已展开量 |
| 深度 > 16 | `Some(Depth)` | 实体名、深度 |
| 声明数 > 1024 | `Some(Declarations)` | 已声明条数 |
| 展开 > 2 GB | `Some(HardLimit)` | 已展开量 |
| 属性值单实体超限 | `Some(AttributeValue)` | **属性名**、阈值、行列号 |
| 其余（配对、根、属性、字符引用、前缀、注释、EOF） | `None` | 行列号 |

软阈值在 `Spill` 下不抛；调用方拿到 `PerEntity` / `Total` 可以**降级到 `Spill` 重试一次**，
拿到硬限制分类则不该重试。

## 7. 26 项已定决策的落实位置

> 设计文档 §14.1 的 26 项，逐条给出本变更的落地位置或「本次不做」的说明。

| # | 决策 | M1 落地 | 验收 |
|---|---|---|---|
| 1 | 支持 DTD 内部子集实体（普通 + 参数），外部不加载，三层上限 | §6.7 / §6.8 | `f-xml-dtd-entities` 全部 Scenario |
| 2 | XPath 做，M2 | **不做** | — |
| 3 | XML 1.1 做，M3 | **不做**；`version="1.1"` 报错 | `f-xml-stream-parser`「1.1 拒绝」 |
| 4 | 自定义实体 / CDATA 输出都做 | `CdataMode` + `XmlEntityRef` + `Doctype` | `f-xml-writer` |
| 5 | pull parser 做，推建立在它之上 | `XmlPullParser` 是唯一内核 | 推拉事件日志 diff |
| 6 | `skipElement()` 做 | 推 `SkipSubtree` / 拉 `skipElement()` | §6.4 四个边界各一条 |
| 7 | `PrefixStream` f_xml 自实现 | `PrefixStream.cj` | 前缀回放 + `close` 关底层 |
| 8 | `bufSize` 可配，默认 8192 | `XmlParserOptions.bufSize` | 两种 bufSize 输出一致 |
| 9 | C14N 做，M3 | **不做** | — |
| 10 | 只认 `InputStream`，不 import ByteBuffer | 4 个 `parse` 重载 + 构造器 | `f-xml-char-layer` |
| 11 | 读 `InvalidByteMode` / 写 `InvalidCharMode`，默认严格 | §6.1 / §6.9 | 两种模式各一条 |
| 12 | 软阈值溢出续跑，硬限制拦截 | §6.8 | 20 MB 展开量 RSS 恒定 |
| 13 | 保留 `XmlAction`；默认实现；单回调重载；**不加 `stop()`** | §6.3 | `XmlEventHandler` 零空方法用例 |
| 14 | XPath 命名空间，M2 | **不做** | — |
| 15 | C14N 三模式，M3 | **不做** | — |
| 16 | 正常文档用 `Spill`，恶意样本用 `Strict` | §9.2 | 恶意样本固定 `Strict` |
| 17 | `defaultNamespace` 严格标准兼容，M2 | **不做** | — |
| 18 | `withComments` 默认 false，M3 | **不做** | — |
| 19 | `XmlException.entityLimitKind` 六值，软阈值可降级重试 | §6.10 | 六分类各一条 + 降级重试用例 |
| 20 | 文本累积用 `f_base.StringGenerator` | §3.2 / §6.6 | 不出现 `StringBuilder` |
| 21 | `assumeQNameInValues`，M3 | **不做** | — |
| 22 | `@When` 只 `os == "Linux"` 与非 Linux 两分支 | 若需平台分支（临时目录）只用这两支 | 构建期无第三分支 |
| 23 | `unsafeBytes()` 零拷贝、长度 == size、不缓存 | §3.2 | §10 待实测 |
| 24 | `close()` 后未定义行为 | `XmlWriter` 类注释 + 文档 | 文档核对 |
| 25 | `xml` / `xmlns` 四处跳过 | M1 承担**解析侧两处**（元素名、属性名）；C14N 三处归 M3 | `xmlns` 作前缀报错用例 |
| 26 | `AttributeValue` 消息带属性名 | §6.8 | 消息含 `属性 'r'` |

## 8. 与设计文档的差异（6 项，逐条给理由）

| # | 差异 | 理由 | 影响 |
|---|---|---|---|
| 1 | `XmlException <: BaseException` 而非 `Exception` | 仓库统一异常基类，`GraphException` 同法；白拿 `addSuppressed` / `printStackTrace` | 公开签名一致，`catch (e: Exception)` 仍可捕获 |
| 2 | `XmlNode` 保持 enum，新增 `EntityRefNode(String)`；`XmlEntityRef(name)` 是**工厂函数**返回 `XmlNode` | 仓颉不允许类继承 enum，设计 §4 与 §7.6 互斥；enum 还带来穷尽 `match`，且不允许调用方注入任意节点类型 | 写侧仍可「显式构造才输出」 |
| 3 | `charset4cj` 保持 `1.0.5` | 仓库 9 个模块统一；1.0.5 的包路径已是 `charset4cj.charset.*`，「1.0.6 才改布局」不成立 | 设计文档 §1.3 待修正 |
| 4 | `XmlDocument.builder` 为 `internal` | 建成后 builder 栈已空；外露会诱导「继续往文档里追加」这种没有语义的操作 | 公开 API 少一个字段 |
| 5 | 新增 `maxElementDepth`（4096）与 `maxAttributeValueLength`（1 MiB） | 设计 §12.8 要求「超深嵌套报错」「超长属性有上限」，但未给配置项 | 新增 2 个选项、2 类错误 |
| 6 | 新增 `BlockRuneSource` 与共享 `ByteDecoder` | 设计 §2.5 要求 UTF-16/32 不走 `readln()`，§2.6 却只给两个实现；`InvalidByteMode.Replace` 也需要字节级解码 | 字符层多一个实现，`peek`/`position` 语义不变；`Replace` 复用同一字节层 |

## 9. 测试策略

### 9.1 分层

| 层 | 用例形态 | 数量级 |
|---|---|---|
| 语法矩阵（设计 §12.2 A–I） | 每条产生式至少 1 条，❌ 盲区必须自造 | ~120 |
| 组合矩阵（§12.3） | 语法元素 × 语法元素抽样 | ~30 |
| 往返（§12.6） | DOM → 序列化 → 解析 → DOM 逐节点比语义 | ~10 |
| 推拉一致 | 同一输入，两份事件日志逐行 diff | ~15 |
| 恶意样本（§12.8） | 全部固定 `EntityOverflowPolicy.Strict` | ~12 |
| xmlconf | 缓存内 `cases.json` 驱动；缓存缺失直接 fail | 2154 断言 |

### 9.2 溢出策略的测试分工

- **正常文档 / 实体用例**：`Spill`（默认）。
- **Billion Laughs 类**：固定 `Strict`。否则炸弹会先写满 2 GB 磁盘才停，CI 直接炸。
- **`Spill` 的语义验证**用「构造一份展开量 20 MB 的合法文档」，断言：切换到 `FileSink` 后
  `retainedBytes`（内存侧保留字节）**不随展开量增长**，且 `onText` 内容与 `Strict` 路径逐字节一致。
  RSS 由人工在 P6 记录（单测不做 RSS 断言）。

### 9.3 测试数据（套件与派生 JSON 不入库）

**入库的只有三样**：

| 路径 | 内容 |
|---|---|
| `f_xml/tools/xmlconf_gen.py` | 下载 `xmlts20130923.tar.gz` → 校验 SHA-256 → 解压 → 解析 catalog → 生成 `cases.json` / `unsupported.json`；`--offline` 只用缓存，`--force` 重新下载 |
| `f_xml/tools/known-issues.json` | ≤ 5 条人工裁定，每条写理由 + 规范章节 |
| `f_xml/doc/xmlconf-unsupported.md` | 408 条排除清单（人读版，由脚本从 `unsupported.json` 生成后提交） |

**不入库**（`.gitignore` 覆盖，`git check-ignore` 必须命中）：原始套件解压结果、`cases.json`、
`unsupported.json`，统一落在 `f_xml/.cache/xmlconf/`。根 `.gitignore` 的 `.cache/` 规则已覆盖子目录；
若实际不覆盖，在根 `.gitignore` 增补 `f_xml/.cache/`。

**运行时解析顺序**（`TestDataRoot`）：

1. 环境变量 `F_XML_XMLCONF_CACHE` 指向的目录；
2. `<module>/.cache/xmlconf/`（`cjpm test` 的工作目录为模块根，见 R6）；
3. 都不存在 → **用例 `fail`，不允许 `skip`**，消息固定为：
   `xmlconf 缓存缺失：请先运行 python3 f_xml/tools/xmlconf_gen.py（离线环境请把已生成的缓存放到 F_XML_XMLCONF_CACHE）`。

**网络边界**：`cjpm test` 自身 SHALL NOT 联网；下载只发生在手工运行 `xmlconf_gen.py` 时。
缓存存在时脚本 `--offline` 必须成功；缓存缺失且离线时脚本以非 0 退出并给出同一句提示。

**可重现**：两个 JSON 的键按固定顺序输出、不含时间戳 / 主机名 / 绝对路径；同一套件重复生成逐字节一致。

### 9.4 用例落位

测试文件放**被测代码同目录**（`src/Xxx_test.cj`），与 `f_zip` / `f_base` 一致；包外文件访问不到
`internal` 成员（字符层、实体展开器的内部计数需要同包断言）。

## 10. 待实测项

| # | 项 | 怎么验 | 期望 | 不达标的处置 |
|---|---|---|---|---|
| R1 | `StringGenerator` append 复杂度 | 10 万次 `append("x")`，看耗时是否线性 | 线性 | 若二次，`XmlWriter` 改预分配策略 |
| R2 | `ArrayList<Byte>` 扩容倍数 | 连续 append 记录底层数组换新时机 | 约 ×2 | 同上 |
| R3 | `unsafeBytes()` 是否零拷贝 | 同一 gen 连续取两次比 `===`；并断言长度 == `size` | 同一数组 | 若做了裁剪拷贝，回写设计文档 §10.2 |
| R4 | `charset4cj` 对不可映射字符的行为 | GBK 写 emoji，看是抛 / 替换 `?` / 跳过 | 三者之一，有定论 | 定论决定 §6.9 往返校验是否必须（保守起见先实现） |
| R5 | `bufSize` 最优值 | 1 MB / 20 万行文档扫 4K/8K/16K/64K | 记录耗时曲线 | 只调默认值，不改结构 |
| R6 | `cjpm test` 的工作目录 | 在用例里打印 `env.getWorkingDirectory()` | 模块根 | 若否，`TestDataRoot` 增加 `CJPM_MODULE_ROOT` 候选 |

## 11. 里程碑与出口

| 阶段 | 内容 | 出口 |
|---|---|---|
| P-1 | 字符层 + R1–R6 实测 | UTF-8 / GBK / UTF-16LE 各一份逐字符读出，行列号正确，BOM 跳过 |
| P0 | Lexer：标签、属性、文本、字符引用、五预定义实体 | 最小 XML 正确切分 |
| P1 | 状态机 + 名称栈 + 配对校验 | 畸形 XML 报错且带行列号 |
| P1.5 | 事件 + `XmlAction` + `DomBuilder` | 建树正确；`Stop` / `SkipSubtree` 生效 |
| P2 | `XmlPullParser` | 推 / 拉事件日志逐行一致 |
| P2.5 | xmlconf harness + 基线 | 输出 `pass / fail / unsupported`；缓存缺失时 fail 并提示运行生成脚本；基线入档（此时允许 fail） |
| P3 | 命名空间作用域栈 | 带前缀文档正确；属性不受默认命名空间影响 |
| P3.5 | DTD 内部实体 + 上限 + 溢出 | 228 条实体用例通过；`Strict` 下炸弹 1 MB 内中断；`Spill` 下 20 MB 展开 RSS 恒定 |
| P4 | `XmlWriter` | 往返语义一致；`]]>` 拆分正确；未声明实体报错 |
| P5 | 安全收尾 + Gate A | 恶意样本被拒；2154 条全过；`known-issues` ≤ 5 |
| P6 | 性能 | 10 MB 文档 < 1 s；事件模式 RSS 平稳 |
