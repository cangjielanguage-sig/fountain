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
4. 支持 DTD **内部子集**（实体 + 声明语法良构校验 + 属性类型映射与属性值规范化），外部实体与
   外部子集**永不加载**。
5. 实体膨胀的三层上限与溢出策略可配置、可分类、可降级重试。
6. xmlconf 20130923 的 2038 条断言全过（Gate A），`unsupported`（524 条）清单可复核。

### 非目标

- M2（XPath 1.0 子集）与 M3（XML 1.1、C14N inclusive/exclusive）：本次不写任何相关公开 API。
- DTD **有效性**校验（内容模型与文档匹配、`ID`/`IDREF` 唯一与引用一致性、NOTATION 语义、
  枚举取值是否落在声明列表内、默认属性注入）、外部子集加载。
  **声明语法良构校验属于良构性，已纳入本变更**（§6.7）；`<!ATTLIST>` 的属性类型映射也只服务
  属性值规范化，不服务有效性（§6.7）。
- 性能优化：本变更只记录现状，字符层重写另开 `optimize-f-xml-char-layer`（§13）。
- 不为了「多支持一点」放宽 XML 1.0 的严格性——不合法的输入必须报错，不猜。

## 2. 范围边界

| 能力 | M1 | M2 | M3 |
|---|---|---|---|
| 推 / 拉 / 单回调、`skipElement` | ✅ | | |
| DOM、命名空间解析、生成器、内部实体、安全上限 | ✅ | | |
| DTD 声明语法良构校验（`ELEMENT` / `ATTLIST` / `NOTATION` / `ENTITY`） | ✅ | | |
| `<!ATTLIST>` 属性类型映射 + 属性值规范化（非 CDATA 去首尾、内部空白折叠） | ✅ | | |
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

与这条语义配套：xmlconf 里测试文件声明 `version="1.1"` 的 **59 条**用例整体移出可跑集
（`unsupported` 原因 `xml-1.1`）。它们与「1.1 报错」互斥，留在可跑集只会制造必然失败；
把「拒绝 1.1」与「通过 1.1 用例」同时写进验收，本身就是矛盾。

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
| `DoctypeParser.cj` | 内部子集解析：四类声明（`ENTITY` / `ELEMENT` / `ATTLIST` / `NOTATION`）的语法校验 + 条件段拒绝 + 属性类型映射 |
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

其余类型严格按设计文档 §3 / §4 / §5.4 / §7 / §9 落地，差异仅 §8 登记的七项。

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

**嗅探优先级**：BOM > 声明 > UTF-8。**BOM 与 `encoding` 声明冲突时报 fatal error**
（XML 1.0 §4.3.3：BOM 已经确定了实体的编码，声明却写了另一种，属编码层致命错误，
SHALL NOT 用「以 BOM 为准」悄悄把冲突抹平）。错误 SHALL 带行列号（定位到 `<?xml?>` 所在行）
并同时带出两个编码名，形如
`编码声明 'GBK' 与字节序标记确定的 'UTF-8' 冲突（第 1 行第 1 列）`。
设计文档 §12.2 H 写的是「以 BOM 为准，或按规范报错」；M1 选后者——猜编码会让「声明与实际不符」
的错误文档静默通过，而这类文档本该被拒。

只有「无 BOM」时声明才具有决定性：那时 `encoding` 声明就是唯一线索（§6.1 嗅探第 3 步）。

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

`DoctypeParser` 解析内部子集中的**四类声明**，并对每类做**声明语法良构校验**：

| 声明 | 校验内容（只验产生式） | 不校验 |
|---|---|---|
| `<!ENTITY>` | `Name` + `EntityDef`（`EntityValue` / `ExternalID` / `NDataDecl`）+ 可选空白 | 外部实体不加载（引用即报错） |
| `<!ELEMENT>` | `Name` + `contentspec`：`EMPTY` / `ANY` / `Mixed` / `children`；`children` 里 `choice` / `seq` 与 `?` `*` `+` 的**紧邻规则**（`(a) ?` 这种空白摆放非法） | 内容模型与文档实际结构是否匹配 |
| `<!ATTLIST>` | `Name` + 若干 `AttDef`：`AttType`（`CDATA` / `ID` / `IDREF` / `IDREFS` / `ENTITY` / `ENTITIES` / `NMTOKEN` / `NMTOKENS` / `NOTATION` 枚举 / 普通枚举）+ `DefaultDecl`（`#REQUIRED` / `#IMPLIED` / `#FIXED` + `AttValue` / `AttValue`） | 属性类型语义（如 `ID` 唯一性）、默认值注入 |
| `<!NOTATION>` | `Name` + `ExternalID` 或 `PublicID`，之后可选空白 | NOTATION 的任何语义用途 |

判定口径：**「声明写得合不合法」是良构性（WFC），「声明与文档是否一致」是有效性（VC）**。
前者必须报错，后者不做——`invalid` 类用例仍然期望解析成功。报错 SHALL 带行列号与声明类型
（如 `<!ATTLIST> 的属性类型 'NUTOKEN' 不是合法记号`、`<!ELEMENT> 的 '?' 必须紧跟在内容粒子后`）。

**条件段只允许出现在外部子集**：XML 1.0 §3.4 的 `intSubset` 产生式里没有 `conditionalSect`，
`<![INCLUDE[` / `<![IGNORE[` 只属于外部子集（及外部参数实体）。因此 M1 遇到内部子集里的条件段
SHALL 直接抛 `XmlException`，消息写明「条件段只能出现在外部子集」并带行列号。外部子集永不加载，
所以 M1 **不存在**「按标志位选分支」这条路径——上一轮设计的 `INCLUDE` / `IGNORE` 分支选择
整体删除，`IGNORE` 分支的「不校验其内部声明」也随之作废。

**单实体替换文本必须自身良构**（WFC: Parsed Entity）：内部一般实体的替换文本 SHALL 匹配
`content` 产生式。展开时把替换文本按内容片段解析，并断言其中的标签**在实体内部配平**：

- 标签不得跨实体边界——实体里开的元素必须在实体里关，实体外开的元素不能在实体里关；
- 替换文本里出现孤立的结束标签、或多出未配对的开始标签，都是良构性错误；
- 属性值位置使用的实体只要求替换文本不含 `<`（那条规则本就存在）。

违规 SHALL 抛 `XmlException`，消息带**实体名**与行列号（展开点位置）。
这条不是有效性校验，与 DTD 内容模型无关——`<a>&e;</a>` 配 `<!ENTITY e "<b>">` 不需要任何
`<!ELEMENT>` 声明就已经不良构。

**属性值处理顺序**（做反了会留下本不该有的 `\n`）：

```
字符引用 + 实体引用展开  →  空白字符归一并（非 CDATA 类型时）折叠
```

**属性类型映射（只服务规范化，不服务有效性）**：解析 `<!ATTLIST>` 时 SHALL 建立
「元素名 → 属性名 → `AttType`」映射（同名重复声明取**第一个**，与实体一致），用于
XML 1.0 §3.3.3 的属性值规范化：

| 属性类型 | 空白处理 |
|---|---|
| `CDATA` | 只做字符级归一：`#x9` / `#xA` / `#xD` 一律变 `#x20`；**不去首尾、不折叠连续空格** |
| 非 `CDATA`（`ID` / `IDREF(S)` / `ENTITY(IES)` / `NMTOKEN(S)` / 枚举 / `NOTATION`） | 先做同上归一，再**去首尾空格**并把内部连续空格折叠成单个 `#x20` |
| 未在 `<!ATTLIST>` 中声明的属性 | 按 `CDATA` 处理（这是规范默认，不是遗漏） |

映射 SHALL 只用于规范化。SHALL NOT 因此做有效性校验：不检查 `ID` 唯一性、不检查 `IDREF`
能否解析到目标、不检查枚举取值是否落在声明的候选列表里、不注入默认值 / `#FIXED` 值。
映射的键 SHALL 按**元素的字面名**（QName 的 `prefix:local` 原文）匹配，不做命名空间解析——
DTD 本身不认识命名空间，用展开名匹配会得到与规范相反的结果。

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

**实体值内的引用延迟展开**：`<!ENTITY b "&a;y">` 在**声明时**不解析 `&a;`，只把原文存进
`EntityTable`；等 `&b;` 真正被使用时才按 `a → …` 递归展开。因此
`<!ENTITY b "&a;y"><!ENTITY a "x">` 合法（使用时 `a` 已声明），只有**使用时仍未声明**才报错
（WFC: Entity Declared）。声明时就展开会把一批合法文档判死——那正是当前 5 条
`sa02` / `sa03` / `sa04` / `not-sa04` / `valid-sa-115` 失败的原因。

**`standalone` 语义**（WFC: Entity Declared）：判定分两步，**先看有没有可能从本文件以外声明**，
再看 `standalone`。

| 前提 | `standalone` | 行为 |
|---|---|---|
| — | `"yes"` | **报错**（文档自称自包含，却引用了未声明的东西） |
| 无外部子集（`DOCTYPE` 没有 `SYSTEM`/`PUBLIC`）且全文无参数实体引用 | `"no"` / 省略 | **报错**：连「可能声明在别处」的通道都没有，未声明就是未声明 |
| 有外部子集，或有参数实体引用 | `"no"` / 省略 | 跳过该实体（内容位置产出空、属性值里去掉该引用）并记一条告警，不报错 |

不报错的那一档，理由是「声明可能在永不加载的外部子集里」，所以只能跳过；
`standalone="no"` 的文档与「省略」同等对待。告警写入解析器实例的告警列表
（`XmlPullParser.warnings()`，包内可见），不打断解析。这条分档让
`not-sa03` / `rmt-e3e-13` 这类带外部 DTD 的**合法**文档不被误判，同时不再把
「无 `DOCTYPE` 且引用未声明实体」这种真错误放过。

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
| 1 | 支持 DTD 内部子集（实体 + 声明语法良构校验），外部不加载，三层上限 | §6.7 / §6.8（含属性类型映射与属性值规范化） | `f-xml-dtd-entities` 全部 Scenario |
| 2 | XPath 做，M2 | **不做** | — |
| 3 | XML 1.1 做，M3 | **不做**；`version="1.1"` 报错，xmlconf 的 59 条 1.1 用例按 `xml-1.1` 移出可跑集 | `f-xml-stream-parser`「1.1 拒绝」+ 可跑集 2062 统计 |
| 4 | 自定义实体 / CDATA 输出都做 | `CdataMode` + `XmlEntityRef` + `Doctype` | `f-xml-writer` |
| 5 | pull parser 做，推建立在它之上 | `XmlPullParser` 是唯一内核 | 推拉事件日志 diff |
| 6 | `skipElement()` 做 | 推 `SkipSubtree` / 拉 `skipElement()` | §6.4 四个边界各一条 |
| 7 | `PrefixStream` f_xml 自实现 | `PrefixStream.cj` | 前缀回放 + `close` 关底层 |
| 8 | `bufSize` 可配，默认 8192 | `XmlParserOptions.bufSize` | 两种 bufSize 输出一致 |
| 9 | C14N 做，M3 | **不做** | — |
| 10 | 只认 `InputStream`，不 import ByteBuffer | 4 个 `parse` 重载 + 构造器 | `f-xml-char-layer` |
| 11 | 读 `InvalidByteMode` / 写 `InvalidCharMode`，默认严格 | §6.1 / §6.9 | 两种模式各一条 |
| 12 | 软阈值溢出续跑，硬限制拦截 | §6.8 | 20 MB 展开量 `retainedBytes` 恒定 |
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

## 8. 与设计文档的差异（7 项，逐条给理由）

| # | 差异 | 理由 | 影响 |
|---|---|---|---|
| 1 | `XmlException <: BaseException` 而非 `Exception` | 仓库统一异常基类，`GraphException` 同法；白拿 `addSuppressed` / `printStackTrace` | 公开签名一致，`catch (e: Exception)` 仍可捕获 |
| 2 | `XmlNode` 保持 enum，新增 `EntityRefNode(String)`；`XmlEntityRef(name)` 是**工厂函数**返回 `XmlNode` | 仓颉不允许类继承 enum，设计 §4 与 §7.6 互斥；enum 还带来穷尽 `match`，且不允许调用方注入任意节点类型 | 写侧仍可「显式构造才输出」 |
| 3 | `charset4cj` 保持 `1.0.5` | 仓库 9 个模块统一；1.0.5 的包路径已是 `charset4cj.charset.*`，「1.0.6 才改布局」不成立 | 设计文档 §1.3 待修正 |
| 4 | `XmlDocument.builder` 为 `internal` | 建成后 builder 栈已空；外露会诱导「继续往文档里追加」这种没有语义的操作 | 公开 API 少一个字段 |
| 5 | 新增 `maxElementDepth`（4096）与 `maxAttributeValueLength`（1 MiB） | 设计 §12.8 要求「超深嵌套报错」「超长属性有上限」，但未给配置项 | 新增 2 个选项、2 类错误 |
| 6 | 新增 `BlockRuneSource` 与共享 `ByteDecoder` | 设计 §2.5 要求 UTF-16/32 不走 `readln()`，§2.6 却只给两个实现；`InvalidByteMode.Replace` 也需要字节级解码 | 字符层多一个实现，`peek`/`position` 语义不变；`Replace` 复用同一字节层 |
| 7 | `<!ELEMENT>` / `<!ATTLIST>` / `<!NOTATION>` 从「识别并跳过、不校验」升级为「声明语法良构校验」 | xmlconf 385 条 `not-wf` 用例的不良构出在声明产生式本身（`(a) ?`、`NUTOKEN`、`NotationDecl` 缺标识符）；只跳过等于放弃良构性，缺口永远收不拢 | 新增纯语法校验；`<!ATTLIST>` 另建「元素 + 属性 → 类型」映射，**仅**用于属性值规范化（不注入默认值、不做 `ID` 唯一性等有效性检查）；四类声明非法即报错，`invalid` 类用例仍期望成功 |

## 9. 测试策略

### 9.1 分层

| 层 | 用例形态 | 数量级 |
|---|---|---|
| 语法矩阵（设计 §12.2 A–I） | 每条产生式至少 1 条，❌ 盲区必须自造 | ~120 |
| 组合矩阵（§12.3） | 语法元素 × 语法元素抽样 | ~30 |
| 往返（§12.6） | DOM → 序列化 → 解析 → DOM 逐节点比语义 | ~10 |
| 推拉一致 | 同一输入，两份事件日志逐行 diff | ~15 |
| 恶意样本（§12.8） | 全部固定 `EntityOverflowPolicy.Strict` | ~12 |
| xmlconf | 缓存内 `cases.json` 驱动；缓存缺失直接 fail | 2038 断言（可跑 2062，`error` 24 不判定） |

### 9.2 溢出策略的测试分工

- **正常文档 / 实体用例**：`Spill`（默认）。
- **Billion Laughs 类**：固定 `Strict`。否则炸弹会先写满 2 GB 磁盘才停，CI 直接炸。
- **`Spill` 的语义验证**用「构造一份展开量 20 MB 的合法文档」，断言：切换到 `FileSink` 后
  `retainedBytes`（内存侧保留字节）**不随展开量增长**，且 `onText` 内容与 `Strict` 路径逐字节一致。
  进程 RSS 只做人工记录、不作门禁——性能已移出本变更（§13）。

### 9.3 测试数据（套件与派生 JSON 不入库）

**入库的只有三样**：

| 路径 | 内容 |
|---|---|
| `f_xml/tools/xmlconf_gen.py` | 下载 `xmlts20130923.tar.gz` → 校验 SHA-256 → 解压 → 解析 catalog → 生成 `cases.json` / `unsupported.json`；`--offline` 只用缓存，`--force` 重新下载 |
| `f_xml/tools/known-issues.json` | 人工裁定清单，上限 5 条，**默认清空（0 条）**。第三轮之前登记的 5 条「命名空间感知 vs XML 1.0 允许多冒号名」已全部改由 `namespace-name` 排除规则移出可跑集，不再占用例外额度；此后只允许登记真正的套件争议（判定口径与 XML 1.0 文本相悖、且无法归入任何一条排除规则的情形） |
| `f_xml/doc/xmlconf-unsupported.md` | 524 条排除清单（`edition` 313 + `external-entity` 95 + `xml-1.1` 59 + `external-subset` 47 + `namespace-name` 10；人读版，由脚本从 `unsupported.json` 生成后提交） |

**可跑集五规则**（生成脚本与 harness 共用同一口径，按此顺序去重）：

1. `EDITION` 含 `1`/`2`/`3`/`4` → 排除（313 条），原因 `edition`；
2. 测试文件出现 `<!ENTITY … SYSTEM|PUBLIC>` → 排除（95 条），原因 `external-entity`；
3. 测试文件声明 `version="1.1"` 且期望成功 → 排除（59 条），原因 `xml-1.1`——M1 明确拒绝 1.1，
   这些用例留在可跑集只会制造必然失败；`not-wf` 的 1.1 用例仍可跑（「拒绝 1.1」正好满足期望）；
4. `TYPE` 为 `not-wf`、`<!DOCTYPE … SYSTEM|PUBLIC …>` 引用**外部子集**、且**测试文件自身良构** →
   排除（47 条），原因 `external-subset`——不良构只写在永不加载的 `.dtd` 里，M1 不可能检出。
   「测试文件自身良构」由标准库 `xml.parsers.expat` 以「不加载外部实体 / 不解析参数实体」的
   方式试解析判定；已经能被本地规则拦下的 `not-wf` 用例不在此列（排除它们只会少一条有效断言）。
   判定还要求测试文件自身不声明 1.1——那一档已被规则 3 覆盖；
5. 名字违反 Namespaces 1.0 的 `QName` 约束（多个冒号 / 冒号在开头或结尾 / 前缀未声明）→ 排除
   （10 条），原因 `namespace-name`：`valid-sa-012`、`x-ibm-1-0.5-valid-P04-ibm04v01.xml`、
   `x-ibm-1-0.5-valid-P05-ibm05v01.xml` / `ibm05v02.xml` / `ibm05v03.xml` / `ibm05v05.xml`、
   `o-p04pass1`、`o-p05pass1`、`rmt-ns10-043`、`rmt-ns10-044`。判定范围是「期望成功的用例」
   （`valid` / `invalid`）里的元素名 / 属性名 / PI target，以及 `not-wf` 用例里 **DTD 声明名**
   （`<!ENTITY>` / `<!NOTATION>`）：前者是「本地名字约束」的必然冲突，后者在 XML 1.0 的 `Name`
   下合法但违反 `QName`。

规则 4 与规则 2 不重叠：规则 2 排除的是**测试文件自己声明**外部实体，规则 4 排除的是
`DOCTYPE` 指向外部子集。规则 5 是「M1 一律做命名空间解析」的直接代价——这 10 条文档在 XML 1.0
下合法，在命名空间感知处理器里必然报错，两者互斥。

合计 `unsupported` 524、可跑 2062、断言 2038（`error` 24 不判定）。`TYPE` 分布由生成脚本实测回填：
`not-wf` **1106**（1155 − 47 − 2）、`valid` **705**（711 − 6）、`invalid` **227**（229 − 2）、
`error` **24**。上一轮把规则 4 / 规则 5 的条数按 48 / 9 估算，实测是 **47 / 10**（前者多算了 1 条
已被本地规则拦下的 `not-wf`，后者漏掉了 `ibm05v05` 的 `<!ENTITY Name: …>`）——总数不变，
逐条数字以脚本输出为准。

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
| R5 | `bufSize` 最优值 | 1 MB / 20 万行文档扫 4K/8K/16K/64K | 记录耗时曲线 | 移出本变更，随字符层重写一并实测（§13） |
| R6 | `cjpm test` 的工作目录 | 在用例里打印 `env.getWorkingDirectory()` | 模块根 | 若否，`TestDataRoot` 增加 `CJPM_MODULE_ROOT` 候选 |

### 10.1 实测记录（2026-10-29，本 worktree）

| # | 实测结论 |
|---|---|
| R1 | **线性**。`append("x")` 的耗时：2.5 万 → 9.1 ms，5 万 → 17.6 ms，10 万 → 34.7 ms，20 万 → 70.3 ms，比例稳定。`XmlWriter` 不需要改预分配策略。 |
| R2 | **扩容倍数约 ×1.5**（16 → 24 → 36 → 54 → 81 → …），不是 ×2，但仍是几何增长，摊还 O(1)。 |
| R3 | `unsafeBytes()` 返回的数组长度**恒等于 `size`**（5 → 5、10 → 10），无尾部冗余、无 `NUL`。连续两次取值内容一致。是否能靠 `===` 判同一对象：仓颉没有引用相等运算符，改为「长度 == size + 追加后旧数组长度不变」的行为断言；结论满足「长度语义可直接依赖」。 |
| R4 | **`charset4cj` 对不可映射字符静默替换成 `?`（0x3F），不抛异常**：GBK 编码 `😀` 得到单字节 `0x3F`，解码回来是 `?`，`back == emoji` 为 `false`。→ 写方向的 `Throw` **必须**用往返校验实现，不能等编码器抛错；`Replace` 直接用 `?`，与编码器行为一致。§6.9 的往返校验保留。 |
| R5 | 未做。字符层被判为需要整体重写，`bufSize` 微调在结构性瓶颈下没有意义；留待 `optimize-f-xml-char-layer`。 |
| R6 | **`cjpm test` 的工作目录 = 模块根**（`.../f_xml`）。`TestDataRoot` 的第二候选 `<module>/.cache/xmlconf/` 可直接用工作目录拼接，不需要 `CJPM_MODULE_ROOT`。 |

**实现修正 2（Strict 路径改用自研严格 UTF-8 解码器）**

`std.io.StringReader` 在 1.3.0 上只有两个按字符 API：`read()` 和 `readln()`。实测结论：

- `read()` 每字符返回 `?Rune`，而仓颉的 `Option` 是**引用类型**，等于每字符一次堆分配，
  实测 **~400 ns/字符**（1.5 MB 文本光解码就要 0.6 s）；
- `readln()` 会吃掉行尾的 `\r\n`，无法区分「这一行本来带换行」和「文件在行尾结束」，
  `"<a>\n"` 会被还原成 `"<a>"`——字符层契约直接破掉。

因此 `InvalidByteMode.Strict` 改为走 `ByteDecoder` 的 **`Utf8Strict`** 分支：与 `Replace`
共用固定块读取与块尾回退，但**不复用** maximal-subpart 替换逻辑（非法字节直接抛
`XmlException`，带字节偏移）。`Replace` 分支保持不变，两条路径仍然互不替代。
GR 与 GBK 路径不受影响（`CharsetRuneSource` 仍走 `charset4cj.TextReader`）。

**实现修正 3（性能：只记录现状，移出本变更）**

事件模式解析耗时（开发机，单线程）：1 MB ≈ 1.5 s、10 MB ≈ 15.8 s。瓶颈已定位为字符层的
**逐字符 `Option` 分配**（仓颉 `Option` 是引用类型，每字符一次堆分配）与**三层缓冲**
（`RuneSource` → `LineWindow` → `Lexer`）。已把 `peek` / `advance` 换成码点直返的
`peekFast` / `advanceFast` 并去掉两层 `ArrayList`，收益约 15%，不改变量级。

结论：性能**不再作为 M1 的出口约束**，只记录现状。要达标需把词法器改成「按块扫描 + 只在出错时
回退定位」，属于一次独立的字符层重写，另开变更 `optimize-f-xml-char-layer`（见 §13）。

**实现修正 1（`PrefixStream` 的 EOF 返回值）**：`tasks.md` 1.1 与 `f-xml-char-layer` spec 写的是
「读完后返回 `-1`」，但仓颉 `InputStream` 的契约是 **EOF 返回 `0`**，且 `charset4cj.TextReader`
的 `checkEOF()` 只在 `len == 0` 时判定结束——返回 `-1` 会让 GBK 路径死循环。
实现按标准契约返回 `0`，测试也断言 `0`。这是一处**规格笔误**，不是实现缩水。

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
| P3.5 | DTD 内部子集：实体 + 四类声明语法良构校验 + 上限 + 溢出 | 228 条实体用例通过；非法声明报错且带行列号与声明类型；`Strict` 下炸弹 1 MB 内中断；`Spill` 下 20 MB 展开 `retainedBytes` 恒定 |
| P4 | `XmlWriter` | 往返语义一致；`]]>` 拆分正确；未声明实体报错 |
| P5 | 安全收尾 + Gate A | 恶意样本被拒；2038 条断言全过（`known` 默认 0，≤ 5）；`unsupported` 524 |

**P6（性能）已移出本变更**：1 MB ≈ 1.5 s / 10 MB ≈ 15.8 s 的现状只做记录，不作为出口条件；
字符层重写另开 `optimize-f-xml-char-layer`（§13）。

## 12. 第二轮评审修订登记（2026-10-29）

> **§14 覆盖本文的 C、D 两条**：C 的 `standalone` 口径已改成「先看有无外部子集 / 参数实体引用，
> 再看 `standalone`」，D 的 5 条 `known-issues` 已由 `namespace-name` 排除规则整体移出可跑集。
> 本节保留第二轮当时的决策记录，当前有效口径以 §6.7 / §6.8 / §9.3 / §14 为准。

本轮只改规划产物（`proposal.md` / `specs/**` / `design.md` / `tasks.md` / `baseline.md` 与文档口径），
不动 `src/`。五条修订与落点：

| # | 修订 | 主要落点 |
|---|---|---|
| A | 扩范围：`<!ELEMENT>` / `<!ATTLIST>` / `<!NOTATION>` / `<!ENTITY>` 的**声明语法良构校验**（良构性，不是 DTD 有效性） | §1、§2、§6.7、§8 差异 7、`f-xml-dtd-entities`、tasks 8.11 |
| B | XML 1.1 用例移出可跑集（59 条）：`unsupported` 408 → **467**、可跑 2178 → **2119**、断言 2154 → **2095**；`TYPE` `not-wf` 1155 / `valid` 708 / `invalid` 232 / `error` 24 | §2、§9.1、§9.3、proposal Impact、`f-xml-conformance`、tasks 6.2/10.2、README、`xmlconf-unsupported.md` |
| C | 实体值内的前向引用改为**延迟展开**（使用时仍未声明才报错）；`standalone` 为 `no` / 缺省时未声明实体**跳过并告警**，`yes` 才报错 | §6.7 / §6.8、`f-xml-dtd-entities`、tasks 8.2/8.9 |
| D | `known-issues` 重新核定：总量 ≤ 5，登记 5 条「命名空间 vs XML 1.0 多冒号名」冲突；`o-p04pass1` / `o-p05pass1` 移出 | §9.3、`f-xml-conformance` Gate B、tasks 10.3、`tools/known-issues.json` |
| E | 性能移出本变更：记录现状与根因，删除 P6 出口约束 | §9.2、§10/§10.1、§11、§13、proposal Impact、`f-xml-conformance`、tasks（删除 11.x） |

**缺口收敛推算**（以旧基线 `fail = 458` 为起点）：

```
458 − 59（B：1.1 用例移出可跑集）− 385（A：声明语法校验）− 7（C：5 条前向引用 + 2 条 standalone）= 7
```

剩余 7 条：`valid-sa-012`、`x-ibm-1-0.5-valid-P04-ibm04v01.xml`、`P05-ibm05v01.xml`、
`P05-ibm05v02.xml`、`P05-ibm05v03.xml`（登记 `known-issues`）与 `o-p04pass1` / `o-p05pass1`。
后两条若复跑通过则无需例外；若仍失败，它们与已登记 5 条同类，按 Gate B 的 5 条上限必须提交
用户裁定替换方案。

## 13. 后续变更登记：`optimize-f-xml-char-layer`

| 项 | 内容 |
|---|---|
| 现状 | 事件模式 1 MB ≈ 1.5 s、10 MB ≈ 15.8 s（开发机、单线程） |
| 根因 | 字符层逐字符 `Option` 分配（`Option` 是引用类型，每字符一次堆分配）+ 三层缓冲（`RuneSource` → `LineWindow` → `Lexer`） |
| 已试 | `peekFast` / `advanceFast`、去掉两层 `ArrayList`，合计约 15% 收益，量级不变 |
| 目标方案 | 词法器改为「按块扫描 + 只在出错时回退定位」；补做 `bufSize` 实测（R5）；必要时合并 `LineWindow` 与 `Lexer` 的前瞻层 |
| 边界 | 不改公开 API、不改事件序列、不改错误语义；`InvalidByteMode` 两条路径的输出逐字符保持 |
| 何时开 | 本变更验收通过后单独立项 |

本变更**不再**对性能设门禁；`f-xml-conformance` 的性能条目只要求「有记录」。

## 14. 第三轮评审修订登记（2026-10-29）

本轮同样**只改规划产物**（`proposal.md` / `specs/**` / `design.md` / `tasks.md` / `baseline.md`、
`f_xml/README.md` / `README_en.md`、`f_xml/doc/xmlconf-unsupported.md`），不动 `src/`。
本轮修订覆盖 §12 的 C（`standalone` 口径）与 D（`known-issues` 5 条）。

| # | 修订 | 主要落点 |
|---|---|---|
| A1 | 可跑集新增**第四条**排除规则 `external-subset`（实测 47 条）：不良构只存在于外部 DTD | §9.3、`f-xml-conformance`「可跑集过滤」、tasks 6.2 |
| A2 | 可跑集新增**第五条**排除规则 `namespace-name`（实测 10 条）：XML 1.0 合法但非命名空间良构 | §9.3、`f-xml-conformance`「可跑集过滤」/ Gate B、tasks 6.2 / 10.3 |
| A3 | 口径变更：`unsupported` 467 → **524**、可跑 2119 → **2062**、断言 2095 → **2038**；`TYPE` 分布由生成脚本实测回填 | §1、§7 决策 1/3、§9.1、§9.3、§11、proposal、`f-xml-conformance`、tasks 6.2 / 10.2、README、baseline、`xmlconf-unsupported.md` |
| B1 | BOM 与 `encoding` 声明冲突改报 **fatal error**（原「以 BOM 为准」作废） | §6.1、`f-xml-char-layer`「字节嗅探」、tasks 1.2 |
| B2 | 内部子集出现条件段 `<![INCLUDE[` / `<![IGNORE[` 改**报错**（规范只允许外部子集） | §6.7、`f-xml-dtd-entities`、tasks 8.1 / 8.11 |
| B3 | 修正 `standalone` 口径：无外部子集且无参数实体引用时，未声明实体**仍报错** | §6.8、`f-xml-dtd-entities`「standalone 与未声明实体」、tasks 8.9 |
| B4 | 新增 tasks **8.12**：单实体替换文本良构校验（6 条 `sa-104` / `sa-116` / `sa-117` / `sa-119` / `sa-181` / `sa-182`） | §6.7、`f-xml-dtd-entities`、tasks 8.12 |
| B5 | 新增 tasks **8.13**：`<!ATTLIST>` 属性类型映射与属性值规范化（`rmt-ns10-012`）；同时删除原 §6.7 / §8 差异 7 的旧口径「不建「元素 → 属性类型」映射、一律按 CDATA」 | §6.7、§8 差异 7、`f-xml-dtd-entities`「属性值规范化」、tasks 8.13 |
| C | 全部规划产物与文档口径同步，两份副本逐文件字节一致 | tasks 12.3 / 12.7 |

**缺口收敛推算**（以旧基线 `fail = 458` 为起点；§14 当时是按估算写的，实测值见括号）：

```
458（旧口径 fail = 385 条 not-wf 被接受 + 59 条 XML 1.1 + 14 条 valid/invalid 失败）
 − 59（规则 3：XML 1.1 用例移出可跑集）
 − 325（8.11 声明语法良构校验命中：385 − 60；余下 60 条仍被接受）
 −   7（8.2 / 8.9：5 条前向引用 + 2 条 standalone）
 −   7（规则 5：5 条命名空间冲突 + o-p04pass1 / o-p05pass1）
 −  48（规则 4：不良构只在外部 DTD）
 −  12（B3 / B4 / B5：8.9 口径修正 + 单实体替换文本良构 + 属性值规范化）
 =   0
```

**实测复核（2026-10-29，第三轮落地后）**——旧基线 `fail = 458` 拆成
「385 条 `not-wf` 被接受 + 59 条 1.1 失败 + 14 条 `valid` / `invalid` 失败」，收口路径：

- 规则 3 去掉 59 条；
- 8.11 声明语法校验命中 325 条（385 → 60）；
- 余下 60 条：规则 4（47）+ 规则 5 的 `rmt-ns10-043` / `rmt-ns10-044`（2）+ 实现修正 11
  （B1 2 + B2 1 + B4 7 + B5 1）全部归零；
- 14 条 `valid` / `invalid` 失败：8.2 / 8.9 修掉 7 条（5 条前向引用 + 2 条 `standalone`），
  其余 7 条连同 `ibm05v05` 由规则 5 移出可跑集。

与 §14 估算不同的两处：规则 4 实测 **47**（估算 48，多算的那条不良构在测试文件自身）、
规则 5 实测 **10**（估算 9，漏登了 `ibm05v05` 的空本地名）。总数不变：
`313 + 95 + 59 + 47 + 10 = 524`，断言 **2038**，`fail = 0`、`known = 0`。

**四份产物自洽检查点**：

1. `proposal.md` 的 `unsupported` / 可跑 / 断言三个数字与 §9.3、`f-xml-conformance`、
   `baseline.md`、README、`xmlconf-unsupported.md` 完全一致（524 / 2062 / 2038）；
2. 排除规则在 §9.3、`f-xml-conformance`、tasks 6.2 三处**都是五条、同顺序、同原因名**；
3. 「属性值一律按 CDATA」这句旧口径只允许出现在本文 §14 与 tasks 8.13 的作废登记里，
   其余产物（`proposal.md`、`specs/**`、`baseline.md`、README、`xmlconf-unsupported.md`）应为空；
4. 同理，「条件段按标志位选分支」只允许出现在 §14 / tasks 8.1 的作废登记里，其余产物应为空；
5. tasks 8.9 / 8.12 / 8.13 的验收场景逐条可执行（见各任务下的 `→` 说明与 spec Scenario）。
