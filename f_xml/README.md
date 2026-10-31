# f_xml

通用 **XML 1.0** 解析与生成模块。**不绑定任何业务格式**：RSS / Atom、SVG、SOAP、POM、
Android 布局、OOXML 或任意配置文件，只要符合 XML 1.0，都走这一套能力。模块不认识任何
业务标签，只负责把 XML 讲清楚。

> 设计与取舍见 [`doc/f_xml模块设计.md`](doc/f_xml模块设计.md)。

## 依赖

```
f_xml
├── f_base               StringGenerator（UTF-8 字节累积，unsafeBytes 零转码）
├── charset4cj           UTF-8 之外的编码（GBK / UTF-16 / UTF-32 …）
└── std.io / std.fs      字符串与字节流
```

- **不依赖 `f_io`**：数据源只认 `std.io.InputStream`，任何实现了该接口的缓冲区都能传进来。
- 完全自研，不参考任何现有 XML 实现；行为依据是 XML 1.0 规范与 Namespaces in XML 1.0。

## 能力（按里程碑）

| 里程碑 | 状态与范围 |
|---|---|
| M1 | **已实现**：推 / 拉 / 单回调三种解析前端、DOM、生成器、DTD 内部子集（含声明语法校验）与溢出策略、安全上限 |
| M2 | **规划**：XPath 1.0 子集（含命名空间前缀）；当前版本尚未提供 `selectNodes` 等 API |
| M3 | **规划**：XML 1.1、C14N（inclusive 1.0/1.1 + exclusive 1.0）；当前版本尚未提供 |

## 能力表（M1）

| 能力 | 入口 | 说明 |
|---|---|---|
| 拉模式 | `XmlPullParser.nextEvent()` / `skipElement()` | 唯一内核，`None` 表示文档结束 |
| 多回调 | `XmlParser.parse(input, handler)` | 只覆盖关心的方法，其余默认 `Continue` |
| 单回调 | `XmlParser.parse(input) { e => … }` | 不建 DOM |
| DOM | `XmlParser.parse(input / bytes / text / path)` | 4 个重载，`parse(text)` 跳过字节嗅探 |
| 命名空间 | 内建 | 默认命名空间继承、`xmlns=""` 重置、属性不受默认命名空间影响 |
| DTD 内部子集 | `<!ENTITY>`（普通 + 参数）+ 四类声明的语法良构校验 | 外部实体与外部子集**永不加载**；不做 DTD 有效性校验 |
| 生成 | `XmlWriter` | 整树 / **增量**（`startElement`+`text`+`endElement`）、紧凑 / 缩进、CDATA 三模式、自定义实体引用、输出编码 |

## 用法示例

### 1. 流式解析大文档（不建树）

```cangjie
let parser = XmlPullParser(File("rss.xml", OpenMode.Read))
while (let Some(event) <- parser.nextEvent()) {
    match (event) {
        case XmlEvent.StartElement(name, _, _) => if (name.local == "item") {
            // 只关心 item，其余整棵子树跳过
            parser.skipElement()
        }
        case _ => ()
    }
}
```

### 2. 建 DOM 后取值

```cangjie
let doc = XmlParser.parse(File("pom.xml", OpenMode.Read))
let root = doc.root.getOrThrow()
let groupId = root.child("groupId").getOrThrow().text()
```

### 3. 生成

```cangjie
let element = XmlElement("rss")
element.setAttr("version", "2.0")
element.appendChild(XmlNode.ElementNode(XmlElement("channel").withText("我的订阅")))
let output = ByteBuffer()
XmlWriter(output, options: XmlWriterOptions(indent: Some("  "))).write(element)
```

### 4. 增量生成（边产生边写）

整树写要求先把 `XmlElement` 建出来；大文档（逐行数据、流式导出）用增量接口：

```cangjie
let writer = XmlWriter(output)
writer.writeDeclaration(encoding: "UTF-8")
writer.startElement(QName("worksheet", uri: Some("http://schemas.openxmlformats.org/spreadsheetml/2006/main")))
writer.startElement(QName("sheetData"))
for (row in rows) {                     // 数据边产生边写，内存与行数无关
    writer.startElement(QName("row"), attributes: [XmlAttribute(QName("r"), "${row.index}")])
    writer.startElement(QName("c"), attributes: [XmlAttribute(QName("r"), "A${row.index}")])
    writer.text(row.value)
    writer.endElement(QName("c"))
    writer.endElement(QName("row"))
}
writer.endElement(QName("sheetData"))
writer.endElement(QName("worksheet"))
writer.close()
```

- `startElement` 只写 `<name attrs`，**延迟闭合**：紧接 `endElement` 输出 `<name/>`，有内容才输出 `>`；
- 命名空间在 `startElement` 时按当前作用域声明，与整树写共享同一套规则（不重复声明）；
- 缩进行为与整树写一致（`indent` 选项）；
- 增量与整树写**不可混用**；`close()` 时仍有未闭合元素会抛 `XmlException`。

## API 参考

### `XmlParser`：解析入口

| 签名 | 返回 | 说明 |
| --- | --- | --- |
| `parse(input: InputStream, options!)` | `XmlDocument` | 从字节流解析并建 DOM；自动做 BOM / 编码嗅探 |
| `parse(bytes: Array<Byte>, options!)` | `XmlDocument` | 从内存字节解析 |
| `parse(text: String, options!)` | `XmlDocument` | 输入已是字符：跳过字节嗅探，不校验声明里的 `encoding` |
| `parse(path: Path, options!)` | `XmlDocument` | 从文件解析，内部负责关闭文件 |
| `parse(input, onEvent: (XmlEvent) -> XmlAction, options!)` | `Unit` | 单回调，不建 DOM |
| `parse(input, handler: XmlEventHandler, options!)` | `Unit` | 多回调，只覆盖关心的方法 |

所有重载都接受 `options!: XmlParserOptions = XmlParserOptions()`。正则/实体错误抛 `XmlException`。

### `XmlPullParser`：拉模式

```cangjie
public class XmlPullParser {
    public init(input: InputStream, options!: XmlParserOptions = XmlParserOptions())
    public func nextEvent(): ?XmlEvent
    public func skipElement(): Unit
    public func close(): Unit
    public func warnings(): Array<String>
}
```

- `nextEvent()` 返回 `None` 表示文档结束（`EndDocument` 之后）。
- `skipElement()` 只能在刚产出 `StartElement` 后调用；`selfClosing = true` 时是空操作，
  匹配的 `EndElement` 仍会发出。
- `close()` 关闭底层输入流（若它实现了 `Resource`）；`warnings()` 返回解析过程中的告警。
- `XmlParser` 的推模式与 `XmlPullParser` 共用同一内核，事件日志逐行一致。

### DOM

#### `XmlDocument`

```cangjie
public class XmlDocument {
    public var root: ?XmlElement
    public var declaration: ?XmlDeclaration
    public var doctype: ?DocTypeInfo
    public let prolog: ArrayList<XmlNode>   // 根元素之前的注释 / PI
    public let epilog: ArrayList<XmlNode>   // 根元素之后的注释 / PI
}
```

#### `XmlElement`

```cangjie
public class XmlElement {
    public let name: QName
    public let attributes: ArrayList<XmlAttribute>
    public let children: ArrayList<XmlNode>

    public init(name: QName)
    public init(name: String)
    public func setAttr(name: String, value: String): Unit
    public func appendChild(node: XmlNode): XmlElement
    public func withText(text: String): XmlElement
    public func attr(name: String): ?String
    public func attr(ns: String, local: String): ?String
    public func child(name: String): ?XmlElement
    public func childrenOf(name: String): ArrayList<XmlElement>
    public func text(): String
}
```

- `setAttr` / `attr(name)` / `child` / `childrenOf` 按 **local name** 匹配；`attr(ns, local)`
  额外要求命名空间 URI 相等。
- `text()` 拼接所有后代文本（含 CDATA），不含注释与 PI。
- `toString()` 输出紧凑 XML（不缩进）。

#### `XmlNode`

```cangjie
public enum XmlNode {
    | ElementNode(XmlElement)
    | TextNode(String)
    | CDataNode(String)
    | CommentNode(String)
    | PiNode(String, String)
    | EntityRefNode(String)
}
public func XmlEntityRef(name: String): XmlNode
```

只有显式构造的 `EntityRefNode` 才会在输出时写成 `&name;`；实体展开后的文本是 `TextNode`。

#### `QName` / `XmlAttribute` / `SourcePosition`

```cangjie
public struct QName {
    public let prefix: ?String
    public let local: String
    public let uri: ?String
    public init(local: String, prefix!: ?String = None, uri!: ?String = None)
}
public struct XmlAttribute {
    public let name: QName
    public let value: String
    public init(name: QName, value: String)
}
public struct SourcePosition {
    public let line: Int64       // 1-based
    public let column: Int64     // 1-based
}
```

`QName` 的相等按**展开名**（`uri + local`）比较，前缀不参与。

#### 声明与 DTD

```cangjie
public class XmlDeclaration {
    public let version: String
    public let encoding: ?String
    public let standalone: ?Bool
    public init(version: String, encoding!: ?String = None, standalone!: ?Bool = None)
}

public class EntityDecl {
    public let name: String
    public let value: ?String       // 外部实体为 None
    public let publicId: ?String
    public let systemId: ?String
    public let parameter: Bool      // <!ENTITY % ...>
    public init(name: String, value!: ?String = None, publicId!: ?String = None,
        systemId!: ?String = None, parameter!: Bool = false)
    public func isExternal(): Bool
}

public class DocTypeInfo {
    public let name: String
    public let publicId: ?String
    public let systemId: ?String
    public var entities: Array<EntityDecl>
    public init(name: String, publicId!: ?String = None, systemId!: ?String = None,
        entities!: Array<EntityDecl> = Array<EntityDecl>())
}
```

### 事件与回调

```cangjie
public enum XmlEvent {
    | StartDocument
    | XmlDeclaration(String, ?String, ?Bool)
    | DocType(String, ?String, ?String)
    | StartElement(QName, Array<XmlAttribute>, Bool)   // 第三个参数是 selfClosing
    | EndElement(QName)
    | Text(String)
    | CData(String)
    | Comment(String)
    | ProcessingInstruction(String, String)
    | EndDocument
}

public enum XmlAction { | Continue | SkipSubtree | Stop }

public interface XmlEventHandler {
    func onStartDocument(): XmlAction { Continue }
    func onXmlDeclaration(version: String, encoding: ?String, standalone: ?Bool): XmlAction { Continue }
    func onDocType(name: String, publicId: ?String, systemId: ?String): XmlAction { Continue }
    func onStartElement(name: QName, attrs: Array<XmlAttribute>, selfClosing: Bool): XmlAction { Continue }
    func onEndElement(name: QName): XmlAction { Continue }
    func onText(text: String): XmlAction { Continue }
    func onCData(text: String): XmlAction { Continue }
    func onComment(text: String): XmlAction { Continue }
    func onProcessingInstruction(target: String, data: String): XmlAction { Continue }
    func onEndDocument(): XmlAction { Continue }
}
```

- `XmlAction.SkipSubtree` 只在 `onStartElement` 返回时有意义：解析器会跳过整棵子树。
- `XmlAction.Stop` 立即终止解析。
- 文本事件可能因实体 / CDATA / 缓冲边界拆成多条，消费方需自行拼接；`DomBuilder` 已合并。

### `XmlWriter`：生成器

```cangjie
public class XmlWriter {
    public init(output: OutputStream, options!: XmlWriterOptions = XmlWriterOptions())
    public func write(doc: XmlDocument): Unit
    public func write(element: XmlElement): Unit
    public func flush(): Unit
    public func writeDeclaration(version!: String = '1.0', encoding!: ?String = None,
        standalone!: ?Bool = None): Unit
    public func startElement(name: QName, attributes!: Array<XmlAttribute> = []): Unit
    public func endElement(name: QName): Unit
    public func text(value: String): Unit
    public func emptyElement(name: QName, attributes!: Array<XmlAttribute> = []): Unit
    public func close(): Unit
}
```

- 整树（`write`）与增量（`startElement` / `text` / `endElement`）**不能混用**，混用抛 `XmlException`。
- `startElement` 延迟闭合 start tag：紧接 `endElement` 输出 `<name/>`，有内容才输出 `>`。
- `close()` 时仍有未闭合元素会抛 `XmlException`；`close()` 之后不得再调用任何方法。
- 输出先攒在 16 KB 缓冲中；`flush()` 会冲刷缓冲并调用底层 `output.flush()`。
- 非 UTF 编码会对不可映射字符做往返校验，按 `onInvalidChar` 抛错或替换为 `?`。

### 读选项

```cangjie
public struct XmlParserOptions {
    public let bufSize: Int64                    // 8192
    public let trimWhitespaceOnly: Bool          // false
    public let entityLimits: EntityLimits
    public let onInvalidByte: InvalidByteMode    // Strict
    public let maxElementDepth: Int64            // 4096
    public let maxAttributeValueLength: Int64    // 1 MiB
    public init(bufSize!: Int64 = 8192, trimWhitespaceOnly!: Bool = false,
        entityLimits!: EntityLimits = EntityLimits(), onInvalidByte!: InvalidByteMode = InvalidByteMode.Strict,
        maxElementDepth!: Int64 = 4096, maxAttributeValueLength!: Int64 = 1024 * 1024)
}

public struct EntityLimits {
    public let maxExpandedPerEntity: Int64       // 64 KiB
    public let maxExpandedTotal: Int64           // 8 MiB
    public let maxDepth: Int64                   // 16
    public let maxDeclarations: Int64            // 1024
    public let maxExpandedHardLimit: Int64       // 2 GiB
    public let spillDir: ?Path                   // None = TMPDIR → 系统临时目录 → ./.fountain_tmp
    public let overflowPolicy: EntityOverflowPolicy // Spill
}
```

| 枚举 | 值 | 说明 |
| --- | --- | --- |
| `InvalidByteMode` | `Strict` / `Replace` | 非法字节抛错 / 每个最大子部分替换为 `U+FFFD` |
| `EntityOverflowPolicy` | `Spill` / `Strict` | 软阈值超限转临时文件 / 直接抛错；硬限制始终抛错 |

### 写选项

```cangjie
public struct XmlWriterOptions {
    public let indent: ?String                 // None = 紧凑
    public let cdata: CdataMode                // Auto
    public let charset: Charset                // UTF-8
    public let onInvalidChar: InvalidCharMode  // Throw
    public let strictEntities: Bool            // true
    public let doctype: ?Doctype               // None
    public init(indent!: ?String = None, cdata!: CdataMode = CdataMode.Auto,
        charset!: Charset = Charsets.UTF8, onInvalidChar!: InvalidCharMode = InvalidCharMode.Throw,
        strictEntities!: Bool = true, doctype!: ?Doctype = None)
}

public class Doctype {
    public let name: String
    public let publicId: ?String
    public let systemId: ?String
    public let entities: Array<EntityDecl>
    public init(name: String, publicId!: ?String = None, systemId!: ?String = None,
        entities!: Array<EntityDecl> = Array<EntityDecl>())
    public func isDeclared(entityName: String): Bool
}
```

| 枚举 | 值 | 说明 |
| --- | --- | --- |
| `CdataMode` | `Auto` / `Always` / `Never` | 自动选择 / 所有文本用 CDATA / 强制转义 |
| `InvalidCharMode` | `Throw` / `Replace` | 目标编码不可映射时抛错 / 替换为 `?` |

`indent` 只影响可读性：它会在元素之间插入空白文本节点，往返解析后会多出空白节点。

### 异常与位置

```cangjie
public class XmlException <: BaseException {
    public let line: Int64
    public let column: Int64
    public let entityLimitKind: ?EntityLimitKind
    public init(message: String)
    public init(message: String, line: Int64, column: Int64)
    public init(message: String, line: Int64, column: Int64, kind!: EntityLimitKind)
}

public enum EntityLimitKind {
    | PerEntity | Total | Depth | Declarations | HardLimit | AttributeValue
}
```

`PerEntity` / `Total` 是软阈值，可改用 `EntityOverflowPolicy.Spill` 重试；`Depth` /
`Declarations` / `HardLimit` / `AttributeValue` 是硬限制，重试必然失败。

### 底层字符源（高级）

```cangjie
public interface RuneSource {
    func peek(offset: Int64): ?Rune
    func advance(): ?Rune
    func position(): SourcePosition
    func peekFast(offset: Int64): Int64
    func advanceFast(): Int64
}
```

`Utf8RuneSource` / `CharsetRuneSource` / `BlockRuneSource` 是内置实现；`LineWindow` 维护行列号，
`PrefixStream` 把嗅探时多读的字节拼回输入流。一般业务代码不需要直接使用这些类型。

## 安全边界

- **外部实体不加载**：`<!ENTITY x SYSTEM "…">` 声明可识别，**引用即报错**；外部子集
  （`SYSTEM` / `PUBLIC` 指向的 `.dtd`）永不打开，也不会发起任何网络请求。
- **三层上限**：单实体 64 KB / 总量 8 MB（软，可 `Spill` 到临时文件续跑）、
  深度 16 / 声明数 1024 / 展开总量 2 GB（硬，直接抛）。
  异常带 `entityLimitKind`，软阈值可判断后**降级重试**。
- **属性值不溢出**：属性值必须在内存里参与命名空间解析，超限抛
  `entityLimitKind = AttributeValue`。
- **元素深度与属性长度**：`maxElementDepth`（默认 4096）与 `maxAttributeValueLength`
  （默认 1 MiB）防超深嵌套与超长属性。

## 已声明的契约

- `XmlWriter.close()` 之后**不得再调用任何方法**（未定义行为）。
- `indent` 只用于人看：缩进会在元素之间插入空白文本节点，往返解析后多出空白节点。
- 文本事件**可能被拆成多条**（实体边界 / CDATA 边界 / 缓冲边界），消费方自行拼接；
  `DomBuilder` 已经做了合并。
- `parse(text)` 拿到的是字符，不做字节嗅探，也不因声明里的 `encoding` 与内容不符报错。

## 状态

已实现并通过 **376** 条单元测试（其中 `complete-f-xml-m1-followups` 新增 34 条、
`optimize-f-xml-semantic-layer` 新增 39 条）。
xmlconf 20130923 的口径：可跑集 **2062** 条
（`unsupported` **524** = `edition` 313 + 外部实体 95 + XML 1.1 59 + 外部子集 47 +
命名空间名 10），断言 **2038** 条，实测 **2038 通过 / 0 失败**（Gate A 达成）。
五条排除规则是 `edition` / 外部实体 / XML 1.1 / 外部子集 / 命名空间名；配套的三项规范修正
（DTD 声明语法良构校验、`standalone` 与单实体替换文本良构、`<!ATTLIST>` 属性类型映射与
属性值规范化）已落地。`known-issues` 已清空。

性能（事件模式，合成流，`bufSize = 8192`，`-O2`，5 次取 `min`，**默认运行时**）：
**1 MB ≈ 58 ms、10 MB ≈ 497 ms、50 MB ≈ 2.47 s**；`VmHWM(50 MB) = 104 MB`。
同轮同机对照（同一份零分配基准）：旧代码 10 MB **1026 ms**、`VmHWM(50 MB)` **295 MB**，
即 **−51.6%** 与 **−64.7%**。门禁：10 MB `min(5) < 1000 ms`、`VmHWM(50 MB) < 256 MB`
均达成，且**未设置任何 GC 环境变量**。

字符层已改为按块解码 + 单一活动缓冲（详见
[`doc/spec/complete-f-xml-m1-followups/`](doc/spec/complete-f-xml-m1-followups/)）；
语义层（名字驻留、三缓冲复用、文本 / 属性值批量扫描、事件侧容器复用）由
[`doc/spec/optimize-f-xml-semantic-layer/`](doc/spec/optimize-f-xml-semantic-layer/)
落地，公开 API 零变更。

