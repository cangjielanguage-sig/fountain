# f_xml

Generic **XML 1.0** parser and generator. **Not tied to any business format**: RSS / Atom, SVG,
SOAP, POM, Android layouts, OOXML or any configuration file that conforms to XML 1.0 can use the
same capabilities. The module knows nothing about business tags; it only explains XML.

> Design and trade-offs: [`doc/f_xml模块设计.md`](doc/f_xml模块设计.md) (Chinese).

## Dependencies

```
f_xml
├── f_base               StringGenerator (UTF-8 byte accumulation, zero-transcode unsafeBytes)
├── charset4cj           Non-UTF-8 encodings (GBK / UTF-16 / UTF-32 …)
└── std.io / std.fs      Strings and byte streams
```

- **No dependency on `f_io`**: the only accepted data source is `std.io.InputStream`; any
  interface implementation (including buffers) can be passed in.
- Fully self-implemented, without consulting any existing XML implementation; the only behavioral
  reference is XML 1.0 and Namespaces in XML 1.0.

## Capabilities (by milestone)

| Milestone | Status and scope |
|---|---|
| M1 | **Implemented**: push / pull / single-callback parsers, DOM, writer, DTD internal subset (with declaration syntax checks) and spill policy, security limits |
| M2 | **Planned**: XPath 1.0 subset with namespace prefixes; no `selectNodes`-style API exists yet |
| M3 | **Planned**: XML 1.1 and C14N (inclusive 1.0/1.1 + exclusive 1.0); not available yet |

## Capabilities (M1)

| Capability | Entry point | Notes |
|---|---|---|
| Pull parser | `XmlPullParser.nextEvent()` / `skipElement()` | The only kernel; `None` means end of document |
| Multi-callback | `XmlParser.parse(input, handler)` | Override only the methods you care about |
| Single callback | `XmlParser.parse(input) { e => … }` | No DOM is built |
| DOM | `XmlParser.parse(input / bytes / text / path)` | Four overloads; `parse(text)` skips byte sniffing |
| Namespaces | Built in | Default namespace inheritance, `xmlns=""` reset, attributes unaffected by the default namespace |
| DTD internal subset | `<!ENTITY>` (general + parameter) plus well-formedness checks on all four declaration types | External entities and external subsets are **never loaded**; no DTD validity checking |
| Writer | `XmlWriter` | Tree / **incremental** (`startElement` + `text` + `endElement`), compact / indented, three CDATA modes, custom entity refs, output encoding |

## Examples

### 1. Stream a large document (no DOM)

```cangjie
let parser = XmlPullParser(File("rss.xml", OpenMode.Read))
while (let Some(event) <- parser.nextEvent()) {
    match (event) {
        case XmlEvent.StartElement(name, _, _) => if (name.local == "item") {
            parser.skipElement()   // skip the whole subtree
        }
        case _ => ()
    }
}
```

### 2. Build a DOM and read values

```cangjie
let doc = XmlParser.parse(File("pom.xml", OpenMode.Read))
let groupId = doc.root.getOrThrow().child("groupId").getOrThrow().text()
```

### 3. Generate

```cangjie
let element = XmlElement("rss")
element.setAttr("version", "2.0")
element.appendChild(XmlNode.ElementNode(XmlElement("channel").withText("my feed")))
let output = ByteBuffer()
XmlWriter(output, options: XmlWriterOptions(indent: Some("  "))).write(element)
```

### 4. Incremental generation (produce and write)

Tree writing requires an `XmlElement` first; for large documents (row-by-row data, streaming export)
use the incremental API:

```cangjie
let writer = XmlWriter(output)
writer.writeDeclaration(encoding: "UTF-8")
writer.startElement(QName("worksheet", uri: Some("http://schemas.openxmlformats.org/spreadsheetml/2006/main")))
writer.startElement(QName("sheetData"))
for (row in rows) {                     // produced and written on the fly; memory is row-independent
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

- `startElement` writes `<name attrs` and **defers closing**: an immediate `endElement` emits `<name/>`,
  otherwise the tag is closed on first content;
- namespaces are declared at `startElement` time using the same scope rules as tree writing (no duplicates);
- indentation matches tree writing (`indent` option);
- incremental and tree writing **must not be mixed**; `close()` with unclosed elements throws `XmlException`.

## API reference

### `XmlParser`: parsing entry points

| Signature | Returns | Description |
| --- | --- | --- |
| `parse(input: InputStream, options!)` | `XmlDocument` | Parse a byte stream into a DOM; performs BOM / encoding sniffing |
| `parse(bytes: Array<Byte>, options!)` | `XmlDocument` | Parse in-memory bytes |
| `parse(text: String, options!)` | `XmlDocument` | Input is already characters: skips byte sniffing and ignores the declared `encoding` |
| `parse(path: Path, options!)` | `XmlDocument` | Parse a file; the file is closed internally |
| `parse(input, onEvent: (XmlEvent) -> XmlAction, options!)` | `Unit` | Single callback, no DOM |
| `parse(input, handler: XmlEventHandler, options!)` | `Unit` | Multi-callback; override only the methods you care about |

All overloads accept `options!: XmlParserOptions = XmlParserOptions()`. Parse / entity errors throw
`XmlException`.

### `XmlPullParser`: pull mode

```cangjie
public class XmlPullParser {
    public init(input: InputStream, options!: XmlParserOptions = XmlParserOptions())
    public func nextEvent(): ?XmlEvent
    public func skipElement(): Unit
    public func close(): Unit
    public func warnings(): Array<String>
}
```

- `nextEvent()` returns `None` after the document ends (after `EndDocument`).
- `skipElement()` is valid only immediately after a `StartElement`; for `selfClosing = true` it is a
  no-op, and the matching `EndElement` is still emitted.
- `close()` closes the underlying input if it implements `Resource`; `warnings()` returns parser
  warnings.
- The push frontends share the same kernel, so their event logs match the pull parser line by line.

### DOM

#### `XmlDocument`

```cangjie
public class XmlDocument {
    public var root: ?XmlElement
    public var declaration: ?XmlDeclaration
    public var doctype: ?DocTypeInfo
    public let prolog: ArrayList<XmlNode>   // comments / PIs before the root
    public let epilog: ArrayList<XmlNode>   // comments / PIs after the root
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

- `setAttr` / `attr(name)` / `child` / `childrenOf` match by **local name**; `attr(ns, local)`
  additionally requires the namespace URI to match.
- `text()` concatenates all descendant text (including CDATA), excluding comments and PIs.
- `toString()` emits compact XML without indentation.

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

Only an explicitly constructed `EntityRefNode` is serialized as `&name;`; expanded entity text is a
`TextNode`.

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

`QName` equality uses the **expanded name** (`uri + local`); the prefix does not participate.

#### Declarations and DTD

```cangjie
public class XmlDeclaration {
    public let version: String
    public let encoding: ?String
    public let standalone: ?Bool
    public init(version: String, encoding!: ?String = None, standalone!: ?Bool = None)
}

public class EntityDecl {
    public let name: String
    public let value: ?String       // None for external entities
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

### Events and callbacks

```cangjie
public enum XmlEvent {
    | StartDocument
    | XmlDeclaration(String, ?String, ?Bool)
    | DocType(String, ?String, ?String)
    | StartElement(QName, Array<XmlAttribute>, Bool)   // third value is selfClosing
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

- `XmlAction.SkipSubtree` is meaningful only when returned from `onStartElement`; the parser skips
  the whole subtree.
- `XmlAction.Stop` terminates parsing immediately.
- Text events may be split at entity / CDATA / buffer boundaries; consumers must concatenate them.
  `DomBuilder` already does.

### `XmlWriter`: generator

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

- Tree mode (`write`) and incremental mode (`startElement` / `text` / `endElement`) **must not be
  mixed**; mixing throws `XmlException`.
- `startElement` defers closing the start tag: an immediate `endElement` emits `<name/>`, otherwise
  the tag closes with `>` before content.
- `close()` throws `XmlException` if elements are still open; no method may be called after
  `close()`.
- Output is buffered in 16 KB chunks; `flush()` flushes the buffer and calls the underlying
  `output.flush()`.
- Non-UTF encodings are round-trip checked; unmappable characters throw or become `?` according to
  `onInvalidChar`.

### Read options

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
    public let spillDir: ?Path                   // None = TMPDIR -> system temp -> ./.fountain_tmp
    public let overflowPolicy: EntityOverflowPolicy // Spill
}
```

| Enum | Values | Meaning |
| --- | --- | --- |
| `InvalidByteMode` | `Strict` / `Replace` | Throw on invalid bytes / replace each maximal subpart with `U+FFFD` |
| `EntityOverflowPolicy` | `Spill` / `Strict` | Spill over the soft limit to a temp file / throw immediately; hard limits always throw |

### Write options

```cangjie
public struct XmlWriterOptions {
    public let indent: ?String                 // None = compact
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

| Enum | Values | Meaning |
| --- | --- | --- |
| `CdataMode` | `Auto` / `Always` / `Never` | Auto / wrap all text in CDATA / force escaping |
| `InvalidCharMode` | `Throw` / `Replace` | Throw when the target charset cannot encode / replace with `?` |

`indent` is for humans only: it inserts whitespace text nodes between elements, so a round trip adds
whitespace nodes.

### Exceptions and positions

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

`PerEntity` / `Total` are soft limits and can be retried with `EntityOverflowPolicy.Spill`;
`Depth` / `Declarations` / `HardLimit` / `AttributeValue` are hard limits that cannot be retried.

### Low-level character sources (advanced)

```cangjie
public interface RuneSource {
    func peek(offset: Int64): ?Rune
    func advance(): ?Rune
    func position(): SourcePosition
    func peekFast(offset: Int64): Int64
    func advanceFast(): Int64
}
```

`Utf8RuneSource` / `CharsetRuneSource` / `BlockRuneSource` are the built-in implementations;
`LineWindow` tracks line / column positions and `PrefixStream` pushes sniffed bytes back into the
input. Normal application code does not need these types directly.

## Security boundaries

- **External entities are never loaded**: `<!ENTITY x SYSTEM "…">` is recognized but *referencing*
  it throws; an external subset (`SYSTEM` / `PUBLIC` `.dtd`) is never opened and no network request
  is ever issued.
- **Three layers of limits**: per entity 64 KB / total 8 MB (soft: `Spill` continues in a temp file),
  depth 16 / declarations 1024 / hard cap 2 GB (hard: throws). `entityLimitKind` tells the caller
  whether a retry with `Spill` can succeed.
- **Attribute values never spill**: they must stay in memory for namespace resolution; exceeding the
  limit throws `entityLimitKind = AttributeValue`.
- `maxElementDepth` (4096) and `maxAttributeValueLength` (1 MiB) guard against deep nesting and huge
  attribute values.

## Contract

- No method may be called after `XmlWriter.close()` (undefined behavior).
- `indent` is for humans: it inserts whitespace text nodes between elements.
- Text may be delivered in several `Text` events (entity / CDATA / buffer boundaries);
  `DomBuilder` merges them for you.
- `parse(text)` takes characters and does not sniff bytes or complain about `encoding` mismatches.

## Status

M1 is implemented and covered by **376** unit tests (34 added by
`complete-f-xml-m1-followups`, 39 by `optimize-f-xml-semantic-layer`). The xmlconf 20130923 figures are: 2062 runnable
cases (`unsupported` 524 = 313 `edition` + 95 external-entity + 59 XML 1.1 + 47 external-subset +
10 namespace-name), 2038 assertions, and the measured result is 2038 passed / 0 failed (Gate A met).
The five exclusion rules are `edition` / external-entity / XML 1.1 / external-subset /
namespace-name; the three accompanying specification fixes (DTD declaration syntax well-formedness,
`standalone` and single-entity replacement-text well-formedness, and `<!ATTLIST>` attribute-type
mapping with attribute-value normalization) are in place. `known-issues` is empty.

Performance (event mode, synthetic stream, `bufSize = 8192`, `-O2`, min of 5 runs,
**default runtime**): **1 MB ≈ 58 ms, 10 MB ≈ 497 ms, 50 MB ≈ 2.47 s**, with
`VmHWM(50 MB) = 104 MB`. Same-run, same-machine comparison on one zero-allocation
benchmark: the previous code measured **1026 ms** for 10 MB and **295 MB** `VmHWM(50 MB)`,
so this change is **−51.6%** and **−64.7%**. Both gates are met (10 MB `min(5) < 1000 ms`,
`VmHWM(50 MB) < 256 MB`) and **no GC environment variable is set**.

The character layer now decodes in blocks over a single active buffer — see
[`doc/spec/complete-f-xml-m1-followups/`](doc/spec/complete-f-xml-m1-followups/). The semantic
layer (name interning, three reused buffers, batched text/attribute scanning, event-side container
reuse) landed via
[`doc/spec/optimize-f-xml-semantic-layer/`](doc/spec/optimize-f-xml-semantic-layer/) with zero
public API change.
