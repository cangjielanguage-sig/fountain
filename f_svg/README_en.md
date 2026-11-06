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

## Capabilities (M3)

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
| Filters | `SvgFilter`, `SvgFilterRenderer`, `SvgFilterBuffer`, eight `fe*` primitives |
| Patterns | `SvgPattern`, `SvgPatternSampler`, `href` inheritance and `patternTransform` |
| Bitmaps | `SvgPngDecoder`, `SvgImageResourceProvider`, `SvgRenderOptions.images` |
| SVGZ | `SvgParser.parseAuto`, `parseGzip`, `writeGzip` |
| Text path | `SvgTextPathLayout`, `rotate` lists |
| Markers | `SvgMarker`, `SvgMarkerExpander` |
| Analytic AA | `SvgAntiAliasMode.Analytic`, `SvgRenderOptions.antiAlias` |

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

## M3: filters, patterns, bitmaps and SVGZ

M3 only adds options with defaults. Default rendering output stays byte-identical to M2, except:
a valid `data:image/png` is now drawn instead of using a placeholder, and explicitly setting
`antiAlias = Analytic` changes the coverage source.

### Filters

`<filter>` and all eight `fe*` primitives are typed. The filter region is resolved from
`filterUnits`, intersected with the canvas, and rejected with `SvgException(kind: Limit)`
before allocating a buffer when it exceeds `SvgRenderOptions.maxPixels`.

### Patterns

`fill="url(#p)"` and strokes support `<pattern>`: `patternUnits` / `patternContentUnits`
size the tile, `patternTransform` is applied before sampling, `href` is inherited per property,
and cycles only produce warnings.

### Bitmaps and resource boundary

```cangjie
class MemoryImages <: SvgImageResourceProvider {
    public func resolve(href: String): ?Array<Byte> {
        if (href == "mem://logo") {
            return Some(pngBytes)
        }
        None
    }
}

let options = SvgRenderOptions(images: Some(MemoryImages()))
let bitmap = SvgRenderer(options: options).render(document)
```

Note: the default `SvgParseOptions` removes external references such as `mem://`. Parse such
documents with `SvgSecurityOptions(unsafePolicy: SvgUnsafePolicy.Keep)`, otherwise the provider
is never called. `allowExternalReferences` only permits `http(s):` and protocol-relative URLs,
not custom schemes.
```

`<image>` accepts exactly two sources: inline `data:image/png;base64,` bytes, or bytes returned
by a caller-supplied `SvgImageResourceProvider.resolve(href)`. The library never opens network
connections or files and never executes scripts. Missing providers, `None` results and decode
failures fall back to a placeholder with a warning.

### SVGZ

```cangjie
let document = SvgParser.parseAuto(bytes)   // gzip when the 1F 8B magic matches
let document2 = SvgParser.parseGzip(bytes)  // force gzip
let compressed = writeGzip(document)        // mtime pinned to 0, deterministic bytes
```

Decompressed output above `SvgSecurityOptions.maxDecompressedBytes` (64 MiB by default)
raises `Limit`.

### textPath, markers and analytic AA

- `<textPath href="#path">` lays glyphs out by arc length, honouring `startOffset`
  (length or percentage), `text-anchor` and per-glyph `rotate`; short paths truncate with a warning.
- `marker-start` / `marker-mid` / `marker-end` honour `markerUnits`, `orient`, `refX` / `refY`
  and `viewBox`; at most 1024 markers per element, excess is truncated with a warning.
- `SvgRenderOptions(antiAlias: SvgAntiAliasMode.Analytic)` enables analytic coverage.
  The default remains `Supersample`, with the exact M2 `samplesPerPixel` semantics.

### M3 limits

Single decoded image 16 × 1024 × 1024 px, decoded pixels per render 64 × 1024 × 1024,
base64 text 32 MiB, gzip output 64 MiB, filter region bounded by `maxPixels`,
pattern tile 4 × 1024 × 1024, pattern/marker reference depth 64. Every check happens
before large buffers are allocated.

## M4: rendering fidelity, text layout and query APIs

M4 only adds behaviour behind default values and new queries; `SvgRenderOptions` only gains
`languages` (default `["en"]`). Documents that do not use M4 properties render byte-identically
to M3. Two conditional differences exist: marker content is clipped to
`markerWidth × markerHeight` as required by SVG 1.1, and `switch` selects only the first
child whose conditions match instead of rendering every child (M3 snapshots trigger neither
difference and stay byte-identical).

### Capabilities

| Group | Capability | Entry points |
|---|---|---|
| A | `clip` / `overflow` / `vector-effect` | `SvgClipProperty` / `SvgClipCoverage` / `SvgOverflow` / `SvgVectorEffect` |
| A | Seven new filter primitives | `SvgFeComponentTransfer` / `SvgFeMorphology` / `SvgFeConvolveMatrix` / `SvgFeTurbulence` / `SvgFeDisplacementMap` / `SvgFeImage` |
| A | Lighting | `SvgFeDiffuseLighting` / `SvgFeSpecularLighting` / `SvgFeDistantLight` / `SvgFePointLight` / `SvgFeSpotLight` |
| A | Pattern viewport | `SvgPattern.viewBox` / `preserveAspectRatio` |
| B | Baseline / decoration / vertical text | `SvgTextBaseline` / `SvgTextDecoration` / `SvgTextWritingMode` |
| B | textPath extensions | `SvgTextPath.side` / `method` / `spacing` |
| B | TrueType | `SvgTrueTypeFont.parse` / `load`, `cmap` 4/12, simple + composite glyphs |
| C | Document queries | `SvgView` / `SvgDocument.views()` / `view(id)` / `switch` / `SvgDocument.anchors()` |
| C | Geometry APIs | `SvgPathData.totalLength` / `pointAtLength`, `SvgGeometry.ctm` / `screenCTM` |

### A: clip, overflow and non-scaling stroke

```cangjie
let document = SvgParser.parse(
    "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"40\" height=\"40\">" +
    "<g clip=\"rect(0, 20, 20, 0)\">" +
    "<rect width=\"40\" height=\"40\" fill=\"red\" vector-effect=\"non-scaling-stroke\"/>" +
    "</g></svg>"
)
let bitmap = SvgRenderer().render(document)
```

- `clip` is a coverage mask that follows the element CTM; with `clip-path`, `clip` is applied first.
- `overflow` only affects marker / symbol / pattern / nested `svg`; `scroll` and `auto` normalise to `hidden`.
- `vector-effect="non-scaling-stroke"` divides stroke width and dash lengths by `sqrt(|det(CTM)|)`.
- Public values are `SvgVectorEffect.NoEffect` / `SvgVectorEffect.NonScalingStroke` (class with static properties, avoiding a clash with `Option.None`).

### B: baseline, decoration, vertical text and TrueType

```cangjie
let registry = SvgFontRegistry()
registry.register("MyFont", SvgTrueTypeFont.load(Path("my.ttf")))
let options = SvgRenderOptions(fonts: registry)
```

- Baseline calculation order is fixed: baseline table → `dominant-baseline` → `baseline-shift`.
- `text-decoration` is not inherited but propagates from the nearest declaring ancestor; strips are
  generated per glyph and rotate with the glyph.
- `writing-mode="tb-rl"` advances along y and stacks columns right-to-left, rotating glyphs 90° clockwise.
  It is ignored with a warning when `textPath` is present.
- `textPath` `side`, `method="stretch"` and `spacing="exact"` keep M3-compatible defaults.

### C: view, switch, anchors and geometry queries

```cangjie
let views = document.views()
let anchors = document.anchors()
let length = SvgPathData.parse("M0 0 L100 0").totalLength()
let point = SvgPathData.parse("M0 0 L100 0").pointAtLength(50)
let ctm = SvgGeometry.ctm(document.elementsByTag("rect")[0])
```

- `switch` evaluates children in document order; `systemLanguage` is prefix-matched against
  `SvgRenderOptions.languages` with `-` boundaries.
- `view` is model-only: it does not render by default and `url(#view)` navigation is not implemented.
- `anchors()` only reports links kept by the existing security policy; external `href` is still removed.

### M4 limitations

- `pattern` `overflow="visible"` does not extend into adjacent tiles; the tile remains the sampling period.
- TTF supports TrueType outlines only: CFF / OTF raises `Unsupported`. Hinting, `GSUB`, `GPOS` and `kern`
  are not parsed; spacing comes from `hmtx` only. The library never opens paths on its own:
  `SvgTrueTypeFont.load(path)` is the only file entry, while `parse(bytes)` and rendering do not
  touch the file system.
- `feImage` accepts only `data:image/png` and providers, sharing the per-render decode budget with `<image>`.
- `ctm` does not include transforms introduced by `use` instantiation.

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

## M5 selector support

`CssSelector.parse(text)` supports the following subset and shares one implementation
with the `SvgStyleResolver` cascade and `querySelectorAll`:

- type selectors, `*`, `#id`, `.class`;
- attribute selectors `[attr]`, `[attr=v]`, `[attr~=v]`, `[attr|=v]`, `[attr^=v]`,
  `[attr$=v]`, `[attr*=v]`; values may be bare identifiers, single-quoted or
  double-quoted strings, and an `i` flag before `]` enables ASCII case-insensitive
  comparison;
- structural pseudo-classes `:root`, `:first-child`, `:last-child`, `:only-child`,
  `:nth-child(An+B)`, `:first-of-type`, `:last-of-type`, `:nth-of-type(An+B)`,
  `:only-of-type`, `:empty`; `An+B` accepts `odd` / `even` / integers / `n` / `-n+2`;
- `:not(<simple selector>)`; only a single simple selector is allowed, nested and
  compound arguments are rejected;
- combinators: descendant (whitespace), child `>`, adjacent sibling `+`, general
  sibling `~`.

```cangjie
let selector = CssSelector.parse("g > rect:not(.skip)[data-role^=badge] + circle")
if (selector.matches(element)) {
    // ...
}
```

A single selector is capped at 256 simple selectors; beyond that the whole rule is
skipped with a warning.

### @media and @font-face

- `@media <query-list> { rules }` supports `screen` / `all`, `and`, comma-separated OR
  lists and `(min-width: Npx)` / `(max-width: Npx)`. The width is the logical render
  viewport width (`SvgRenderOptions.width` first, then the root width, then 300);
  `SvgStyleResolver.compute` accepts `mediaWidth:` when used standalone. Other media
  types such as `print` simply do not match and produce no warning; unparsable queries
  are skipped with a warning.
- `@font-face` reads the required `font-family` plus optional `font-weight` / `font-style`
  and maps it to the same-named registered family; when that family is absent it maps to
  the registry's first family. `src` loads nothing and only emits a warning. Aliases live
  for one render and never mutate the caller's registry.

### CSS variables and calc()

- `--name: value` inherits per element and keeps its original case;
  `var(--name, fallback)` expands before normalization, nesting is capped at 8 levels,
  and cycles or a missing variable without fallback invalidate the declaration with a
  warning; fallbacks may contain another `var()`.
- `calc()` supports `+` / `-` / `*` / `/`, parentheses and `px` / `%` / `em`, with at most
  16 nested parentheses. At least one side of `*` / `/` must be a number and percentages
  cannot be mixed with absolute lengths. `calc()` is only accepted on `stroke-width`,
  `letter-spacing`, `word-spacing`, `font-size` and `stroke-dashoffset`; elsewhere it is
  treated as invalid.
- Computed-style initial values: `paint-order` `fill stroke markers` (inherited),
  `mix-blend-mode` `normal`, `isolation` `auto`, `transform-origin` `0 0`,
  `transform-box` `view-box`, `direction` `ltr` (inherited), `unicode-bidi` `normal`,
  `font-kerning` `auto` (inherited). Invalid values fall back to the initial value with a
  warning.

### Paint order

`paint-order` is a duplicate-free ordered subset of `fill` / `stroke` / `markers`,
defaulting to `fill stroke markers`. The render tree emits commands in that order;
layers not listed are appended in the default relative order, and marker derivation,
count and orientation stay unchanged.

```xml
<svg xmlns="http://www.w3.org/2000/svg">
  <rect x="10" y="10" width="40" height="40"
        fill="orange" stroke="navy" stroke-width="6"
        style="paint-order: stroke fill"/>
</svg>
```

The example draws the stroke first and the fill last, so overlaps show the fill.
Documents without `paint-order` are byte-identical to M4; invalid values fall back to
the default order with a warning.

## Non-goals for M3

- JPEG / WebP / GIF decoding, the `feImage` primitive;
- XHTML semantics inside `foreignObject`;
- CSS animations/transitions, pseudo-elements (`::before` / `::after`),
  `@supports` / `@layer` / `@container`;
- Bidirectional text, ligatures, glyph substitution, built-in CJK fonts, TTF/OTF
  parsing (M5 adds baseline ligatures and kerning, see the related sections);
- SMIL extensions (`animateColor`, event-driven animation, scripts) and `textPath` `side`;
- GPU/native raster backends.

When no registered font covers a character, text bounds return `None`; rendering
still draws a placeholder glyph and emits a warning.

## API notes

- The paint reference factory is `referencing(id, fallback:)` (the field is `reference`).
  `id` may be written with or without `#` and is stored as `#id`; an empty id throws
  `InvalidValue`.
- The "no alignment" value of `SvgAspectAlign` is `NoAlign` (serialized as `none`).
- `attributes` / `children` / `warnings` are exposed as mutable lists for read-only
  traversal convenience. Write through `setAttr` / `removeAttr` / `appendChild`;
  mutating the lists directly bypasses cache invalidation and `parent` maintenance.
  `warnings` is append-only by contract and should not be cleared.
