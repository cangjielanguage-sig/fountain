# f_svg

**SVG 1.1 documents and rendering**: value types, typed DOM, parser/writer,
security filtering, CSS cascade, CPU software rasterization, deterministic PNG
and SMIL animation.

M1 static-document behavior is unchanged; M2 adds "document to pixels" and
"time to document" pipelines. All XML work is delegated to
[`f_xml`](../f_xml/README_en.md); there is no second XML lexer here.

> Design and trade-offs: [`doc/f_svg模块设计.md`](doc/f_svg模块设计.md) (Chinese).

## Dependencies

```
f_svg
├── f_xml     XML 1.0 parser, DOM, namespaces, XmlWriter, entity limits
└── f_base    BaseException / StringGenerator
```

## Installation

The module is released with the fountain repository and follows its version
(currently `1.3.17`). Declare it in your `cjpm.toml`:

```toml
[dependencies]
  "fountain::f_svg" = { path = "../fountain/f_svg" }
```

When a central repository is configured, `"fountain::f_svg" = "1.3.17"` also works.

## Capabilities (M2)

| Capability | Entry point |
|---|---|
| Parse | Five `SvgParser.parse` overloads: text / bytes / stream / path / `XmlDocument` |
| Model | `SvgDocument`, `SvgRoot`, `SvgElement`, shapes, text, gradients, `use`, `image` |
| Typed values | `SvgLength`, `SvgColor`, `SvgPaint`, `SvgTransform`, `SvgPathData`, `SvgViewBox` |
| Write | `SvgWriter` / `writeSvgString`, via `XmlDocument` and `f_xml::XmlWriter` |
| Security | Scripts, event attributes and external references removed by default; hard size limits |
| Preservation | Unknown elements/attributes, comments, PIs, CDATA and DOCTYPE kept |
| CSS | `CssStyleSheet`, `CssSelector`, `SvgStyleResolver`, `SvgComputedStyle` |
| Geometry | `SvgBounds`, `SvgGeometry`, `SvgViewport` |
| Rendering | `SvgBitmap`, `SvgRasterizer`, `SvgRenderer`, `renderToPng` |
| PNG | `SvgPngEncoder`, `SvgBitmap.toPngBytes`, `writePng`, `savePng` |
| Animation | `SvgTimeline`, `SvgInterpolator`, `SvgClock`, `SvgManualClock` |
| Fonts | `SvgFont` interface, `SvgFontRegistry`, built-in `SvgHersheyFont` |

## Quick start

### 1. Parse and traverse

```cangjie
import fountain::f_svg.*
import std.fs.Path

let document = SvgParser.parse(Path("logo.svg"))
let root = document.root
println(root.width?.toString() ?? "100%")

for (rect in document.elementsByTag("rect")) {
    println("${rect.id ?? "-"}: ${rect.attr("x") ?? "0"}")
}

for (warning in document.warnings) {
    println("warning: ${warning}")
}
```

Parsing from text skips byte sniffing:

```cangjie
let document = SvgParser.parse("<svg xmlns=\"http://www.w3.org/2000/svg\"><rect width=\"10\" height=\"10\"/></svg>")
```

### 2. Build a document

```cangjie
let svg = SvgRoot(
    width: SvgLength(200.0, unit: SvgLengthUnit.Px),
    height: SvgLength(100.0, unit: SvgLengthUnit.Px)
)
svg.viewBox = SvgViewBox(0.0, 0.0, 200.0, 100.0)

let rect = SvgRect(
    x: SvgLength(10.0), y: SvgLength(10.0),
    width: SvgLength(80.0), height: SvgLength(40.0)
)
rect.fill = SvgPaint.of(SvgColor.parse("#09f"))
rect.strokeWidth = SvgLength(2.0)
svg.appendElement(rect)

let document = SvgDocument(svg)
```

### 3. Write

```cangjie
let compact = writeSvgString(document)
let pretty = writeSvgString(document, options: SvgWriteOptions(indent: Some("  ")))
```

To a file:

```cangjie
import std.fs.{File, OpenMode}

let file = File("out.svg", OpenMode.Write)
try {
    let writer = SvgWriter(file)
    writer.write(document)
    writer.flush()
} finally {
    file.close()
}
```

### 4. Security options

The default policy is "remove and warn", so a single `<script>` does not fail the
whole document:

```cangjie
let document = SvgParser.parse(userInput, options: SvgParseOptions(
    strict: false,
    security: SvgSecurityOptions(
        unsafePolicy: SvgUnsafePolicy.Remove,
        allowScript: false,
        allowEventAttributes: false,
        allowExternalReferences: false,
        allowDataImages: true,
        maxElements: 1_000_000,
        maxDepth: 512
    )
))
```

| Content | Default | Switch |
|---|---|---|
| `<script>` | removed | `allowScript` / `unsafePolicy` |
| `on*` event attributes | removed | `allowEventAttributes` |
| `http:` / `https:` / `//` references | removed | `allowExternalReferences` |
| `file:` / `javascript:` references | removed | `unsafePolicy` only (`allowExternalReferences` does not apply) |
> `allowExternalReferences` applies to `href` only (`use` / `image` / `a`);
> external `url(...)` references in `fill` / `stroke` / `filter` / `clip-path` / `mask` / `marker-*` / `cursor` / `style`
> are controlled by `unsafePolicy` alone.

| `data:` images | kept | `allowDataImages` (`false` removes) |
| `#id` fragment references | kept | always kept |
| External DTD / entities | never loaded | not configurable |

Element count, depth and entity limits are **hard failures** in both strict and
lenient modes: `SvgException(kind: SvgErrorKind.Limit)`.

## M2: styles, rendering, PNG and animation

```cangjie
import fountain::f_svg.*
import std.fs.Path

let resolver = SvgStyleResolver(sheet: CssStyleSheet.parse("rect { fill: red }"))
let styles = resolver.compute(document.root)

let options = SvgRenderOptions(width: 128, height: 128, background: SvgColor.White)
let bitmap = SvgRenderer(options: options).render(document)
bitmap.savePng(Path("out.png"))

let timeline = SvgTimeline(document)
let frame = timeline.sample(0.5)          // original document is untouched
let frameBitmap = SvgRenderer().render(frame)

let fonts = SvgFontRegistry.defaultRegistry()  // Hershey built in
let textOptions = SvgRenderOptions(fonts: fonts)
```

Output is RGBA8, non-premultiplied, row-major; same document plus same options
produces byte-identical PNGs. `samplesPerPixel` accepts 1 / 2 / 4 and `maxPixels`
defaults to 64M.

## Value types

Every value type satisfies `parse(toString(x)) == x` for values representable in
canonical form. `parse` throws `SvgException`; `SvgLength`, `SvgColor` and
`SvgPathData` also provide `tryParse` returning `None`.

Known lossy boundaries: non-zero values with `|v| < 1e-6` become `0`, and values
with more than 6 fractional digits are rounded. `SvgColor` emits `#rrggbbaa`
(e.g. `#ff000080`) when alpha is exactly representable by a `0..255` byte, and
`rgba()` otherwise.

```cangjie
SvgLength.parse("1.5em")             // value = 1.5, unit = Em
SvgColor.parse("hsl(120,100%,50%)")  // #00ff00
SvgPaint.parse("url(#grad1) none")   // Reference(#grad1, fallback = Some(SvgPaint.None))
SvgTransform.parse("translate(10,20) scale(2)").toMatrix()
SvgPathData.parse("M0 0 A5 5 0 0110 10")
SvgViewBox.parse("0 0 200 100")
SvgPreserveAspectRatio.parse("xMinYMax slice")
```

Percentage lengths need an explicit axis:

```cangjie
let context = SvgLengthContext.of(200.0, 100.0)
toUserUnits(SvgLength(50.0, unit: SvgLengthUnit.Percent), SvgLengthAxis.Horizontal, context) // 100
```

## Model and serialization contracts

- **Stable attribute order**: source order when parsing, assignment order when building.
- **Unknown is not dropped**: foreign-namespace elements become `SvgUnknownElement`
  (prefix, URI and subtree preserved); unknown attributes stay in `attributes`.
- **Structural round trip**: tag, URI, expanded attribute names/values, text, child
  order, comments, PIs and CDATA survive `parse → write → parse`.
  Empty-element style, quotes, indentation and the XML declaration may differ.
- **Byte-stable compact output**: writing a compact document twice yields identical bytes.
- `href` is read from both `href` and `xlink:href`; the written form follows
  `SvgWriteOptions.xlink` (default `true` → `xlink:href`). If an element carries
  both forms, only the first is kept.
- `writeSvgString` accepts UTF-8 only; for other charsets write bytes through
  `SvgWriter`. The string helper throws `SvgException(kind: InvalidValue)`.

## Error locations

`f_xml::XmlException` is wrapped at the parse boundary into
`SvgException(kind: SvgErrorKind.Syntax)` with 1-based line/column.
Build-time value and security errors also carry `elementPath()`:

```
/svg[1]/g[2]/rect[1]
```

Build-time (value / security / structure) errors use `line == 0` and `column == 0`;
locate them via `elementPath`. Only XML lexical/syntax errors keep line/column.

## Samples and tests

`testdata/` contains six small samples: `basic-shapes.svg`, `text.svg`,
`gradient.svg`, `namespaces.svg`, `comments.svg`, `unsafe.svg`.

```bash
cd f_svg
cjpm test
```

The large-sample smoke test uses `.assets/README/module-dependencies.svg` when it
exists and is skipped otherwise. M2 rendering scenes live in
`testdata/render/*.svg` with `*.rgba` snapshots (64×64, per-pixel tolerance ≤ 1).
Performance reference values are recorded in
[`doc/perf-baseline.md`](doc/perf-baseline.md).

## Non-goals for M2

- Filters, XHTML inside `foreignObject`, `pattern`;
- `<image>` decoding or any external resource access (a placeholder is drawn);
- Full CSS3: pseudo-classes, attribute selectors, media queries, `@font-face`, CSS transitions;
- Bidirectional text, ligatures, glyph substitution, built-in CJK fonts, TTF/OTF parsing;
- `textPath` layout, text `rotate` lists, event-driven animation and scripts;
- SVGZ, GPU/native raster backends.

`textPath` and text `rotate` degrade to plain text with a warning; unknown
elements are skipped during rendering.

## API notes

- The paint reference factory is `referencing(id, fallback:)` (the field is `reference`).
  `id` may be written with or without `#` and is stored as `#id`; an empty id throws
  `InvalidValue`.
- The "no alignment" value of `SvgAspectAlign` is `NoAlign` (serialized as `none`).
- `attributes` / `children` / `warnings` are exposed as mutable lists for read-only
  traversal convenience. Write through `setAttr` / `removeAttr` / `appendChild`;
  mutating the lists directly bypasses cache invalidation and `parent` maintenance.
  `warnings` is append-only by contract and should not be cleared.
