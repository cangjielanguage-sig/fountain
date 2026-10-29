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

| Milestone | Scope |
|---|---|
| M1 | Push / pull / single-callback parsers, DOM, writer, DTD internal subset (with declaration syntax checks) and spill policy, security limits |
| M2 | XPath 1.0 subset with namespace prefixes |
| M3 | XML 1.1, C14N (inclusive 1.0/1.1 + exclusive 1.0) |

## Capabilities (M1)

| Capability | Entry point | Notes |
|---|---|---|
| Pull parser | `XmlPullParser.nextEvent()` / `skipElement()` | The only kernel; `None` means end of document |
| Multi-callback | `XmlParser.parse(input, handler)` | Override only the methods you care about |
| Single callback | `XmlParser.parse(input) { e => … }` | No DOM is built |
| DOM | `XmlParser.parse(input / bytes / text / path)` | Four overloads; `parse(text)` skips byte sniffing |
| Namespaces | Built in | Default namespace inheritance, `xmlns=""` reset, attributes unaffected by the default namespace |
| DTD internal subset | `<!ENTITY>` (general + parameter) plus well-formedness checks on all four declaration types | External entities and external subsets are **never loaded**; no DTD validity checking |
| Writer | `XmlWriter` | Compact / indented, three CDATA modes, custom entity refs, output encoding |

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

M1 is implemented and covered by 236 unit tests. The xmlconf 20130923 figures are: 2062 runnable
cases (`unsupported` 524 = 313 `edition` + 95 external-entity + 59 XML 1.1 + 48 external-subset +
9 namespace-name), 2038 assertions.
Gate A is pending a re-run: under the old figures (2178 runnable) 1696 passed and 458 failed, and the
gap is accounted for by five exclusion rules (`edition` / external-entity / XML 1.1 / external-subset /
namespace-name) plus three specification fixes — DTD declaration syntax well-formedness checks,
`standalone` and single-entity replacement-text well-formedness, and `<!ATTLIST>` attribute-type
mapping with attribute-value normalization. `known-issues` is empty by default.
Performance (1 MB ≈ 1.5 s / 10 MB ≈ 15.8 s) is recorded but is **not a gate**; the character-layer
rewrite is tracked separately as `optimize-f-xml-char-layer`. See
[`doc/spec/implement-f-xml-m1/baseline.md`](doc/spec/implement-f-xml-m1/baseline.md).
