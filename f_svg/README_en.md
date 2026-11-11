# f_svg

**SVG 1.1 core plus parts of SVG 2**, implemented in pure Cangjie. One module covers five pipelines:

| Pipeline | Entry point | Result |
|---|---|---|
| Parse | `SvgParser` | Typed DOM; unknown elements and attributes are preserved |
| Style | `CssStyleSheet` / `SvgStyleResolver` | Computed style tree |
| Render | `SvgRenderer` | RGBA8 bitmap / PNG |
| Animate | `SvgTimeline` | Document snapshot at an arbitrary time |
| Author | `SvgBuilder` | SVG text/file that browsers can render and play |

No scripts, no event loop, no network, no file access for fonts or images.
Rendering is **offline frame rendering**, not a real-time player.
All XML work is delegated to [`f_xml`](../f_xml/README_en.md).

> Design and trade-offs: [`doc/f_svg模块设计.md`](doc/f_svg模块设计.md) (Chinese).

## Dependencies and installation

```
f_svg
├── f_xml     XML 1.0 parser, DOM, namespaces, XmlWriter, entity limits
└── f_base    BaseException / StringGenerator
```

The module follows the fountain repository version (currently `1.3.18`):

```toml
[dependencies]
  "fountain::f_svg" = { path = "../fountain/f_svg" }
```

With a central repository configured, `"fountain::f_svg" = "1.3.18"` also works.
Register `f_svg` in the repository root `.modules` file.

## Quick start

### 1. Parse → render PNG

```cangjie
import fountain::f_svg.*
import std.fs.Path

let document = SvgParser.parse(Path("input.svg"))
let bitmap = SvgRenderer(
    options: SvgRenderOptions(width: 800, height: 600, background: SvgColor.White)
).render(document)
bitmap.savePng(Path("output.png"))
```

### 2. Build → save SVG

```cangjie
import fountain::f_svg.*
import std.fs.{File, Path}

let document = SvgParser.parse(
    "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"100\" height=\"100\">" +
    "<rect x=\"10\" y=\"10\" width=\"40\" height=\"40\" fill=\"#09f\"/></svg>"
)
let rect = document.elementsByTag("rect")[0]
rect.setAttr("fill", "#f60")

let text = writeSvgString(document, options: SvgWriteOptions(indent: Some("  ")))
File.writeTo(Path("edited.svg"), text.toArray())
```

### 3. Generate a playable animation

```cangjie
import fountain::f_svg.*

SvgBuilder(200.0, 100.0)
    .rect(x: 10.0, y: 30.0, width: 40.0, height: 40.0)
    .fill("#3366cc")
    .animate(
        attribute: "x",
        from: "10",
        to: "150",
        dur: "2s",
        begin: SvgBegin.offset(0.0),
        repeatCount: "indefinite"
    )
    .save("card.svg")
```

The output includes the XML declaration and `xmlns`, so a browser renders and
plays it directly. `save` can be replaced by `toSvgString()` /
`write(output: OutputStream)` / `save(file: File)`.

## Implemented SVG features

Status: **Yes** = implemented with tests; **Partial** = implemented with a stated
boundary; **No** = listed in the unsupported section.

### Documents, parsing and serialization

| Feature | Status | Notes |
|---|---|---|
| XML 1.0 / namespaces / DOCTYPE / entities | Yes | Via `f_xml`; external DTDs and entities are never loaded |
| Root attributes | Yes | `width` / `height` / `viewBox` / `preserveAspectRatio`; `version` / `baseProfile` / `zoomAndPan` are stored only |
| Nested `svg`, `g`, `defs`, `symbol`, `use`, `switch`, `a`, `view` | Yes | `switch` selects the first matching child |
| Unknown elements / attributes | Yes | Prefix, URI, subtree and raw attributes are preserved |
| Comments / PI / CDATA | Yes | Preserved on parse and written back structurally |
| Input forms | Yes | Text, bytes, stream, `Path`, `XmlDocument`; `parseAuto` detects gzip by magic |
| Writer | Yes | `SvgWriter` / `writeSvgString`; `href` form is configurable |
| SVGZ | Yes | `parseGzip` / `writeGzip`; 64 MiB decompression limit by default |
| Security filtering | Yes | Removes `<script>`, `on*`, external `href` by default; 1,000,000 elements / 512 depth hard limits |

### Shapes and paths

| Feature | Status | Notes |
|---|---|---|
| `rect` (with `rx` / `ry`) | Yes | |
| `circle` / `ellipse` / `line` / `polyline` / `polygon` | Yes | |
| `path` | Yes | `M L H V C S Q T A Z`, absolute and relative |
| `pathLength` | Yes | Calibrates dashes, dash offset and absolute `textPath` `startOffset` |
| Fill rules | Yes | `fill-rule` / `clip-rule`: `nonzero` / `evenodd` |
| `use` / `symbol` | Yes | `x` / `y`, `href` inheritance, instantiation |
| `switch` | Yes | `systemLanguage` prefix match against `SvgRenderOptions.languages` |
| Nested viewports | Yes | `viewBox` / `preserveAspectRatio` of nested `svg` |
| `transform` | Yes | `translate` / `scale` / `rotate` / `skewX` / `skewY` / `matrix` lists |
| Root `width` / `height: auto` | Yes | Derived from the content box and `viewBox` aspect ratio |
| Geometry queries | Yes | `getBBox` / `getCTM` / `getScreenCTM` / `absoluteBounds` |

### Styles and CSS

| Feature | Status | Notes |
|---|---|---|
| Presentation attributes / `style` / `<style>` | Yes | Specificity, `!important` and inheritance |
| Selectors | Yes | Type, `*`, `#id`, `.class`, attribute selectors, structural pseudo-classes, `:not`, four combinators |
| Structural pseudo-classes | Yes | `:root`, `:first-child`, `:last-child`, `:only-child`, `:nth-child(An+B)`, `:first-of-type`, `:last-of-type`, `:nth-of-type`, `:only-of-type`, `:empty` |
| `:hover` / `:focus` | Partial | Static evaluation through `hoveredIds` / `focusedIds`; no event loop |
| `@media` | Partial | `screen` / `all`, `and`, comma lists, `min-width` / `max-width`; other features are ignored |
| `@font-face` | Partial | Family alias into the registry only; `src` never loads files |
| `@color-profile` | Partial | Name and `src` are parsed; no ICC transform, renders as sRGB |
| CSS variables | Yes | Inherited `--name`, `var(--name, fallback)`, nesting limit 8 |
| `calc()` | Partial | `+ - * /`, parentheses, `px` / `%` / `em`; only on selected length properties |
| `currentColor` | Yes | |
| `context-fill` / `context-stroke` | Yes | Only inside `use` instances |
| `paint-order` | Yes | Any non-repeating order of `fill` / `stroke` / `markers` |
| `mix-blend-mode` | Yes | `normal`, `multiply`, `screen`, `overlay`, `darken`, `lighten`, `color-dodge`, `color-burn`, `hard-light`, `soft-light`, `difference`, `exclusion` |
| `isolation` | Yes | `auto` / `isolate` |
| `transform-origin` / `transform-box` | Partial | `transform-box` supports `view-box` / `fill-box` only |
| `display` / `visibility` / `opacity` | Yes | Includes group opacity and offscreen composition |
| `shape-rendering` / `text-rendering` / `color-rendering` / `color-interpolation` | Yes | `auto` preserves existing output; `linearRGB` interpolates gradients in linear light |

### Paint, strokes and markers

| Feature | Status | Notes |
|---|---|---|
| Colors | Yes | Named colors, `#rgb` / `#rrggbb` / `#rrggbbaa`, `rgb()` / `rgba()` / `hsl()` / `hsla()` |
| Paint fallback | Yes | `fill="url(#g) red"` |
| Linear / radial gradients | Yes | `gradientUnits`, `gradientTransform`, `spreadMethod`, stop opacity |
| `pattern` | Yes | `patternUnits`, `patternContentUnits`, `patternTransform`, `viewBox`, `href` inheritance |
| Stroke properties | Yes | `stroke-width`, `linecap`, `linejoin`, `miterlimit`, `dasharray`, `dashoffset` |
| `stroke-linejoin` extensions | Yes | `miter-clip` / `arcs` |
| `vector-effect` | Yes | `none`, `non-scaling-stroke`, `non-scaling-size`, `non-rotation`, `fixed-position` |
| Markers | Yes | `marker-start` / `marker-mid` / `marker-end`, `markerUnits`, `orient`, `refX` / `refY`, `viewBox` |
| Context paint | Yes | `context-fill` / `context-stroke` |

### Text and fonts

| Feature | Status | Notes |
|---|---|---|
| `text` / `tspan` / `textPath` | Yes | `x` / `y` / `dx` / `dy` / `rotate` lists, `text-anchor`, `textLength` / `lengthAdjust` |
| `textPath` | Yes | `startOffset`, `side`, `method`, `spacing`; truncation emits a warning |
| Baselines | Yes | `dominant-baseline`, `alignment-baseline`, `baseline-shift` |
| Text decoration | Yes | `underline` / `overline` / `line-through`, `double` / `dotted` / `dashed` / `wavy`, longhands and `text-underline-position` |
| Vertical writing | Partial | `writing-mode: tb-rl`; no `text-orientation`, no vertical metrics |
| Bidirectional text | Partial | UAX#9 subset (L/R/AL/EN/AN/WS/ON/B, numbers, bracket mirroring); no Arabic/Indic shaping |
| Built-in font | Partial | Hershey stroke font: ASCII uppercase, digits and punctuation; no lowercase, no CJK |
| TrueType | Partial | `glyf` simple/composite, `cmap` 4/12; no CFF/OTF, WOFF, variable fonts or hinting |
| Kerning | Yes | `kern` format 0, `GPOS` Pair Adjustment format 1/2 (x advance only) |
| Ligatures / contextual substitution | Partial | GSUB Type 4 (`liga` / `clig` / `hlig` / `dlig` / `calt` switches) and Type 5/6 format 3; other lookups are not implemented |
| `font-stretch` | Yes | Nine keywords and percentages; synthesizes `requested / selected-face` when no exact face exists |
| `font-variant: small-caps` | Yes | Uppercase glyphs scaled to 0.8 with matching advance |
| `font-size-adjust` | Yes | Uses `OS/2.sxHeight / unitsPerEm` |
| `font-feature-settings` / `font-variant-ligatures` | Yes | Four-character tags, limit 64 |
| `font-kerning` | Yes | `auto` / `normal` / `none` |
| Text alignment / wrapping | Partial | No automatic line breaking or justification |

### Images, embedding and external resources

| Feature | Status | Notes |
|---|---|---|
| `image` + PNG | Yes | `data:image/png` or `SvgImageResourceProvider`; 16 Mi pixels per image, 64 Mi pixels per render |
| `preserveAspectRatio` / `image-rendering` | Yes | Nearest, bilinear and high-quality sampling |
| SVGZ | Yes | See Documents |
| `foreignObject` | Partial | Injection through `SvgForeignObjectRenderer`; XHTML is not parsed |
| External document `use` | Partial | `SvgExternalDocumentProvider`; no recursive loading; 16 MiB per document |
| `initialView` | Yes | `#id` / `id` overrides the initial viewport |
| JPEG / WebP / GIF / SVG-as-image | No | PNG only |
| External `@import` / image URLs / network | No | Removed or skipped by the security boundary |

### Filters

| Feature | Status | Notes |
|---|---|---|
| Filter framework | Yes | `filterUnits`, `primitiveUnits`, region clipping, `maxPixels` check |
| Color and composition | Yes | `feColorMatrix`, `feComponentTransfer`, `feBlend`, `feComposite`, `feMerge`, `feFlood`, `feDropShadow` |
| Blur / morphology / displacement | Yes | `feGaussianBlur`, `feMorphology`, `feOffset`, `feDisplacementMap` |
| Turbulence and convolution | Yes | `feTurbulence`, `feConvolveMatrix`, `feTile` |
| Lighting | Yes | `feDiffuseLighting`, `feSpecularLighting` with distant / point / spot lights |
| `feImage` | Partial | `data:image/png` and providers only; shares the image decode budget |

### Clipping, masking and compositing

| Feature | Status | Notes |
|---|---|---|
| `clip-path` | Yes | `clipPath`, `clipPathUnits`, reference depth 64 |
| `clip` | Yes | `rect()` coverage mask, composable with `clip-path` |
| `mask` | Yes | `maskUnits`, `maskContentUnits`; luminance and alpha modes |
| `mask-type` | Partial | Element attribute only, not part of CSS cascade |
| Group opacity / blending / isolation | Yes | `opacity`, `mix-blend-mode`, `isolation` |
| Order of operations | Yes | filter → `clip` → `clip-path` → `mask` → group opacity → blend |

### Animation (SMIL)

| Feature | Status | Notes |
|---|---|---|
| Animation elements | Yes | `animate`, `animateTransform`, `animateMotion`, `set`, `discard`, `mpath` |
| Value sources | Yes | `from`, `to`, `by`, `values` |
| Interpolation | Yes | `calcMode`: `linear`, `discrete`, `spline`, `paced`; `keyTimes`, `keySplines` |
| Additive behavior | Yes | `additive`, `accumulate` |
| Timing | Yes | `dur`, `begin`, `end`, `repeatCount`, `repeatDur`, `min`, `max`, `fill` |
| `begin` forms | Partial | Numbers, `id.begin` / `id.end`, `indefinite`; multi-values, `id.end+1s`, `repeat(n)` can be generated for browsers but are warned and ignored during sampling |
| Event triggers | Partial | Explicit `fireEvent(id, "click" / "mouseover" / ...)`; no UI event loop |
| Time source | Yes | `setCurrentTime`, `currentTime`, `pause`, `unpause` |
| Animation control | Yes | `begin(id)`, `end(id)`, `discard`; `attributeType` CSS/XML |
| `restart` | Partial | Written back, but restart semantics are not sampled |
| CSS animations / transitions / `@keyframes` | No | SMIL only |

### Interaction and hit testing

| Feature | Status | Notes |
|---|---|---|
| `pointer-events` | Yes | `auto`, `none`, `visiblePainted`, `visibleFill`, `visibleStroke`, `visible`, `painted`, `fill`, `stroke`, `all`, `bounding-box` |
| `cursor` | Partial | Keyword whitelist stored in computed style; `url()` never loads resources |
| Hit testing | Yes | `SvgHitTest.hitTest(document/root, point)`, using fill outlines, strokes and text glyphs |
| Hit queries | Yes | `getIntersectionList`, `getEnclosureList`, `checkIntersection`, `checkEnclosure` |
| `elementsAt` / `elementAt` | Yes | `public static`; returns the hit chain with topmost first |
| Links / navigation / event dispatch | No | Security boundary |

### DOM, queries and script interfaces

| Feature | Status | Notes |
|---|---|---|
| Document queries | Yes | `elementById`, `elementsByTag`, `getElementsByClassName`, `querySelectorAll`, `views`, `anchors` |
| Node editing | Yes | `appendChild`, `insertBefore`, `removeChild`, `setAttr`, `removeAttr` |
| Mutation listeners | Yes | `addMutationListener` / `removeMutationListener`, synchronous, limit 32 |
| View state | Yes | `SvgViewState(currentScale, currentTranslate)` through render options |
| Factory methods | Yes | `SvgPoint.create`, `SvgMatrix.create`, `SvgTransform.create` |
| Path measurement | Yes | `getTotalLength` / `getPointAtLength` on `SvgPath` and `SvgPathData` |
| `getElementById` / `matches` / `closest` | No | Use the document queries above |

### SVG 2 completion and authoring

| Feature | Status | Notes |
|---|---|---|
| Multi-value `vector-effect` | Yes | Fixed order `non-scaling-size → non-rotation → fixed-position` |
| `stroke-linejoin: miter-clip / arcs` | Yes | |
| Root `width` / `height: auto` | Yes | |
| `mesh` / `hatch` gradients | No | |
| `SvgBuilder` chain API | Yes | `rect` / `circle` / `ellipse` / `line` / `polyline` / `polygon` / `path` / `text` / `use` / `image`, plus styles, groups, animation, output and `save` |
| Typed animation | Yes | `SvgAnimate`, `SvgAnimateTransform`, `SvgAnimateMotion`, `SvgSet`, `SvgMpath` |
| Time expressions | Yes | `SvgBegin.offset`, `clock`, `at`, `after`, `repeatOf`, `event`, `indefinite`, `literal`, `join` |
| Authoring enums | Yes | `SvgRestart`, `SvgAnimationFill`, `SvgAnimationTransformType`, `SvgMotionRotate` |
| Gradient / `defs` authoring | No | Use the DOM API or write `defs` before handing the document to `SvgBuilder` |

## Usage guide

### Parsing

```cangjie
let fromText = SvgParser.parse("<svg xmlns=\"http://www.w3.org/2000/svg\"/>")
let fromBytes = SvgParser.parse(bytes)
let fromPath = SvgParser.parse(Path("logo.svg"))
let fromAuto = SvgParser.parseAuto(bytes)       // detects SVGZ
let fromXml = SvgParser.parse(xmlDocument)      // reuse a parsed XML DOM
```

Strict mode:

```cangjie
let document = SvgParser.parse(text, options: SvgParseOptions(strict: true))
```

Lenient mode records recoverable issues in `document.warnings`; syntax errors
still throw `SvgException(kind: Syntax)` with 1-based line/column.

### Traversal, queries and editing

```cangjie
let root = document.root
let rect = document.elementById("hero").getOrThrow()
for (shape in document.elementsByTag("rect")) {
    println("${shape.id ?? "-"}: ${shape.attr("x") ?? "0"}")
}

let hits = root.querySelectorAll("g > rect:not(.skip) + circle")
let box = rect.getBBox(options: SvgBBoxOptions(stroke: true))
let ctm = rect.getCTM()
```

Write back after editing:

```cangjie
rect.setAttr("fill", "#f60")
rect.setAttr("stroke-width", "2")
let svg = writeSvgString(document)
```

Serialization contract: stable attribute order, unknown content preserved,
`parse → write → parse` is structurally equivalent, and two consecutive compact
writes are byte-identical.

### Styles

```cangjie
let sheet = CssStyleSheet.parse(
    "rect { fill: red } .badge { stroke: navy; stroke-width: 2 }"
)
let resolver = SvgStyleResolver(sheet: sheet)
let styles = resolver.compute(document.root)
let style = styles.get(rect)
```

`@media` width comes from `SvgRenderOptions.width`; standalone evaluation can
pass `mediaWidth:`. CSS variables, `calc()`, `@font-face` aliases and static
`:hover` / `:focus` states are supported as described above.

### Rendering

```cangjie
let options = SvgRenderOptions(
    width: 800,
    height: 600,
    background: SvgColor.White,
    samplesPerPixel: 4,
    devicePixelRatio: 1.0,
    antiAlias: SvgAntiAliasMode.Supersample
)
let bitmap = SvgRenderer(options: options).render(document)
bitmap.savePng(Path("out.png"))
```

- Output is RGBA8, non-premultiplied, row-major; identical input and options are byte-identical.
- `samplesPerPixel` accepts 1 / 2 / 4; `maxPixels` defaults to 64 Mi pixels.
- `antiAlias: Analytic` uses analytic coverage and differs from supersampling.
- Common options: `fonts`, `images`, `languages`, `hoveredIds` / `focusedIds`,
  `initialView`, `foreignObjectRenderer`, `externalDocuments`, `viewState`.

### Animation sampling

```cangjie
let timeline = SvgTimeline(document)
timeline.setCurrentTime(1.5)
let frame = timeline.sampleCurrent()             // clones and applies the 1.5 s state

let bitmap = SvgRenderer(
    options: SvgRenderOptions(width: 800, height: 600)
).render(frame)
```

`sample(time)` never mutates the source document; repeated sampling at the same
time is deterministic. For explicit triggers:

```cangjie
timeline.begin("fade-in")
timeline.fireEvent("pulse", "click")
timeline.end("pulse")
```

### Authoring

```cangjie
let builder = SvgBuilder(200.0, 100.0, viewBox: SvgViewBox(0.0, 0.0, 200.0, 100.0))
builder
    .group(id: "card")
    .rect(x: 10.0, y: 10.0, width: 180.0, height: 80.0, rx: 12.0, ry: 12.0)
    .fill("#0d47a1")
    .end()
    .circle(cx: 100.0, cy: 50.0, r: 24.0)
    .fill("#ffb300")
    .animateTransform(
        attribute: "transform",
        transformType: SvgAnimationTransformType.Rotate,
        from: "0 100 50",
        to: "360 100 50",
        dur: "3s",
        begin: SvgBegin.offset(0.0),
        repeatCount: "indefinite"
    )
    .save("badge.svg")
```

Cursor semantics: `group()` enters a group, `end()` returns to the parent;
shapes, styles and animations apply to the current cursor. Output:

```cangjie
let text = builder.toSvgString()                 // compact string
builder.write(outputStream)                     // writes and flushes, never closes
builder.save(Path("badge.svg"))                 // I/O failure throws InvalidValue
// builder.save(file)                            // writes an open file, flushes only
```

Extended `begin` and typed elements:

```cangjie
builder.rect(x: 0.0, y: 0.0, width: 20.0, height: 20.0)
    .animate(
        attribute: "opacity",
        values: ["0", "1", "0"],
        dur: "2s",
        begin: SvgBegin.after("intro", 0.5),
        repeatCount: "2"
    )

builder.circle(cx: 40.0, cy: 40.0, r: 10.0)
    .animateMotion(mpath: "#orbit", dur: "4s", repeatCount: "indefinite")
```

### Security options

```cangjie
let options = SvgParseOptions(
    strict: false,
    security: SvgSecurityOptions(
        unsafePolicy: SvgUnsafePolicy.Remove,
        allowScript: false,
        allowEventAttributes: false,
        allowExternalReferences: false,
        allowDataImages: true,
        maxElements: 1_000_000,
        maxDepth: 512,
        maxDecompressedBytes: 64 * 1024 * 1024
    )
)
```

| Content | Default | Switch |
|---|---|---|
| `<script>` | removed | `allowScript` / `unsafePolicy` |
| `on*` event attributes | removed | `allowEventAttributes` |
| `http:` / `https:` / `//` references | removed | `allowExternalReferences` |
| `file:` / `javascript:` references | removed | `unsafePolicy` only; `allowExternalReferences` does not allow them |
| `data:` images | kept | `allowDataImages` |
| `#id` fragments | kept | cannot be disabled |
| External DTD / entities | never loaded | cannot be enabled |

`allowExternalReferences` affects `href` only; `url(...)` in styles is controlled
by `unsafePolicy`. Size limits hard-fail in both strict and lenient modes with
`SvgException(kind: Limit)`.

### Errors and warnings

```cangjie
try {
    let document = SvgParser.parse(untrusted)
} catch (error: SvgException) {
    println("${error.kind}: ${error.message} @ ${error.elementPath()}")
}
```

- Parse/build errors: `SvgException` with `Syntax` / `InvalidValue` / `Unsupported` / `Security` / `Limit`.
- Recoverable issues: appended to `document.warnings`, which only grows.
- Element path: `elementPath()` such as `/svg[1]/g[2]/rect[1]`; XML syntax errors keep line/column.

## Value types

For canonically representable values, `parse(toString(x)) == x`; `parse` throws
`SvgException`, while `SvgLength` / `SvgColor` / `SvgPathData` also provide `tryParse`.

```cangjie
SvgLength.parse("1.5em")
SvgColor.parse("hsl(120,100%,50%)")            // #00ff00
SvgPaint.parse("url(#grad1) none")             // reference + fallback
SvgTransform.parse("translate(10,20) scale(2)").toMatrix()
SvgPathData.parse("M0 0 A5 5 0 0110 10")
SvgViewBox.parse("0 0 200 100")
SvgPreserveAspectRatio.parse("xMinYMax slice")
```

Known boundaries: non-zero absolute values below `1e-6` become zero, and values
with more than six decimals are rounded. Percentage lengths need an explicit axis:

```cangjie
let context = SvgLengthContext.of(200.0, 100.0)
toUserUnits(SvgLength(50.0, unit: SvgLengthUnit.Percent), SvgLengthAxis.Horizontal, context)
```

## Model and serialization contract

- **Stable attribute order**: source order on parse, assignment order on build, same on write.
- **Unknown is not dropped**: non-SVG elements become `SvgUnknownElement`; unknown attributes are kept raw.
- **Structural round-trip**: tags, URIs, attributes, text, child order, comments / PI / CDATA survive
  `parse → write → parse`; empty-element form, quoting, indentation and XML declaration need not match.
- **Stable compact bytes**: two consecutive compact writes are identical.
- `href` reads both `href` and `xlink:href`; output form follows `SvgWriteOptions.xlink`.
- `writeSvgString` accepts UTF-8 only; use `SvgWriter` for other charsets.

## Unsupported and security boundaries

| Area | Not implemented |
|---|---|
| Scripts and interaction | `<script>`, `on*`, event loop, link activation/navigation, cursor resource loading |
| Resources | network and file access, external CSS `@import`, external image URLs, external DTD/entities |
| Images | JPEG / WebP / GIF, SVG-as-image, `image-orientation`, ICC color management |
| SVG 2 graphics | `mesh` / `hatch` gradients, `mask-type` in CSS, `transform-box` `content-box` / `border-box` |
| Fonts | CFF/OTF, WOFF/WOFF2, variable fonts, hinting, `vmtx`/`vhea`, `text-orientation`, `font-variation-settings`, `font-optical-sizing` |
| Text | complex-script shaping (Arabic joining, Indic reordering), full UAX#9, automatic wrapping/justification, `text-emphasis`, `text-decoration-skip-ink` |
| OpenType | GPOS mark-to-base / mark-to-mark / cursive / contextual positioning; GSUB single, multiple, alternate and chaining format 1/2 |
| CSS | animations / transitions / `@keyframes` / `@property`, `@supports` / `@layer` / `@container`, pseudo-elements, `:has()`, `:nth-child(of S)`, `@media` `resolution` / `orientation` / `prefers-*` |
| Animation | `restart` sampling semantics, real syncbase / wallclock / accessKey clocks, `animateColor` (deprecated) |
| Rendering | real-time player, GPU/native backend, browser pixel parity |

Missing fonts or glyphs make `getBBox` return `None`; rendering draws a
placeholder glyph and emits a warning.

## Tests and samples

`testdata/` contains basic samples (`basic-shapes.svg`, `text.svg`, `gradient.svg`,
`namespaces.svg`, `comments.svg`, `unsafe.svg`), render scenes
(`testdata/render/*.svg` + `*.rgba`) and story animations (`testdata/story/*.svg`).
Scene snapshots compare 64×64 pixels with tolerance ≤ 1.

```bash
cd f_svg
cjpm test
cjpm build
```

All 1230 tests pass and `f_svg` builds with 0 warnings. Performance notes:
[`doc/perf-baseline.md`](doc/perf-baseline.md).

## API conventions

- `SvgPaint` uses `referencing(id, fallback:)`; `id` may include or omit `#`.
- `SvgAspectAlign` names the no-align value `NoAlign` (serialized as `none`).
- `SvgVectorEffect.NoEffect` is a static property to avoid clashing with `Option.None`.
- The author-side `SvgBuilder` lives in `SvgAuthoringBuilder.cj`; it does not conflict with the parser-side `SvgBuilder.cj`.
- `SvgHitTest.elementsAt` / `elementAt` are `public static` because Cangjie does not
  allow static and instance methods with the same name.
- `attributes` / `children` / `warnings` are exposed as lists for traversal; write through
  `setAttr` / `removeAttr` / `appendChild` to keep caches and `parent` consistent.

## More documentation

- Module design: [`doc/f_svg模块设计.md`](doc/f_svg模块设计.md) (Chinese)
- Per-milestone specs and verification reports: `doc/spec/`
- OpenSpec specs: `openspec/specs/svg-*`
- Authoring API design: [`doc/f_svg-M7设计.md`](doc/f_svg-M7设计.md) (Chinese)

---

## Other public API

The declarations below are not expanded above; they are grouped by module level and by type (members declared in `extend` blocks are listed under the extended type). See the corresponding files under `src/` for the full semantics.

- Module level: `CssAttributeOperator` (enum), `CssAttributeSelector` (struct), `CssColorProfileRule` (class), `CssCombinator` (enum), `CssDeclaration` (struct), `CssFontFaceRule` (class), `CssLexer` (class), `CssMediaFeature` (struct), `CssMediaQuery` (class), `CssMediaQueryItem` (class), `CssPseudoClass` (enum), `CssRule` (class), `CssSelector` (class), `CssSelectorPart` (struct), `CssSimpleSelector` (struct), `CssSimpleSelectorKind` (enum), `CssSpecificity` (struct), `CssStyleSource` (enum), `CssToken` (struct), `CssTokenKind` (enum), `SvgAlignmentBaseline` (enum), `SvgAnchorInfo` (class), `SvgAnimationInfo` (class), `SvgAnimationKind` (enum), `SvgAntiAliasMode` (enum), `SvgArcParams` (struct), `SvgAttribute` (struct), `SvgAutoSize` (class), `SvgAutoSizeSize` (struct), `SvgBaselineShift` (enum), `SvgBidiClass` (enum), `SvgBitmap` (class), `SvgBlendMode` (enum), `SvgBounds` (struct), `SvgCalcMode` (enum), `SvgChannelSelector` (enum), `SvgCircle` (class), `SvgClipCoverage` (class), `SvgClipPathMasker` (class), `SvgClipProperty` (class), `SvgClipRect` (struct), `SvgClock` (interface), `SvgColorInterpolation` (enum), `SvgColorMatrixType` (enum), `SvgColorRendering` (enum), `SvgCompositeOperator` (enum), `SvgComputedStyle` (class), `SvgComputedStyleTree` (class), `SvgContainer` (class), `SvgContainerKind` (enum), `SvgCoordinateUnits` (enum), `SvgCoverageMask` (class), `SvgCrc32` (class), `SvgCursor` (struct), `SvgDirection` (enum), `SvgDisplayCommand` (class), `SvgDisplayCommandKind` (enum), `SvgDisplayList` (class), `SvgDocument` (class), `SvgDominantBaseline` (enum), `SvgEdgeMode` (class), `SvgElement` (class), `SvgEllipse` (class), `SvgErrorKind` (enum), `SvgFeBlend` (class), `SvgFeColorMatrix` (class), `SvgFeComponentTransfer` (class), `SvgFeComposite` (class), `SvgFeConvolveMatrix` (class), `SvgFeDiffuseLighting` (class), `SvgFeDisplacementMap` (class), `SvgFeDistantLight` (class), `SvgFeDropShadow` (class), `SvgFeFlood` (class), `SvgFeFunc` (class), `SvgFeFuncA` (class), `SvgFeFuncB` (class), `SvgFeFuncG` (class), `SvgFeFuncR` (class), `SvgFeGaussianBlur` (class), `SvgFeImage` (class), `SvgFeMerge` (class), `SvgFeMergeNode` (class), `SvgFeMorphology` (class), `SvgFeOffset` (class), `SvgFePointLight` (class), `SvgFeSpecularLighting` (class), `SvgFeSpotLight` (class), `SvgFeTile` (class), `SvgFeTurbulence` (class), `SvgFillRule` (enum), `SvgFilter` (class), `SvgFilterBuffer` (class), `SvgFilterPrimitive` (class), `SvgFilterRenderer` (class), `SvgFont` (interface), `SvgFontFeatures` (class), `SvgFontKerning` (enum), `SvgFontRegistry` (class), `SvgFontStretch` (enum), `SvgGeometry` (class), `SvgGradient` (class), `SvgGradientSampler` (class), `SvgGroupCompositor` (class), `SvgGzip` (class), `SvgHersheyFont` (class), `SvgImage` (class), `SvgImageRendering` (enum), `SvgInteractionState` (class), `SvgInterpolator` (class), `SvgLengthAdjust` (enum), `SvgLengthAxis` (enum), `SvgLengthContext` (struct), `SvgLengthUnit` (enum), `SvgLightingPrimitive` (class), `SvgLine` (class), `SvgLineCap` (enum), `SvgLineJoin` (enum), `SvgLinearGradient` (class), `SvgListSeparator` (enum), `SvgManualClock` (class), `SvgMarker` (class), `SvgMarkerExpander` (class), `SvgMarkerInstance` (class), `SvgMarkerOrient` (enum), `SvgMarkerUnits` (enum), `SvgMasker` (class), `SvgMixBlendMode` (enum), `SvgMorphologyOperator` (enum), `SvgMutationEvent` (class), `SvgMutationKind` (enum), `SvgMutationListener` (class), `SvgNamespaces` (class), `SvgNode` (enum), `SvgNumberList` (struct), `SvgOverflow` (enum), `SvgPaintKind` (enum), `SvgPaintLayer` (enum), `SvgPaintOrder` (class), `SvgPathCommand` (struct), `SvgPathCommandKind` (enum), `SvgPathLength` (class), `SvgPattern` (class), `SvgPatternSampler` (class), `SvgPngDecoder` (class), `SvgPngEncoder` (class), `SvgPointList` (struct), `SvgPointerEvents` (enum), `SvgPolygon` (class), `SvgPolyline` (class), `SvgPreserveAspectRatio` (struct), `SvgRadialGradient` (class), `SvgRasterizer` (class), `SvgRect` (class), `SvgRenderTreeBuilder` (class), `SvgRgba` (struct), `SvgRoot` (class), `SvgShape` (class), `SvgShapeRendering` (enum), `SvgSpreadMethod` (enum), `SvgStop` (class), `SvgStrokeOutliner` (class), `SvgStrokeStyle` (struct), `SvgSwitch` (class), `SvgTag` (class), `SvgText` (class), `SvgTextAnchor` (enum), `SvgTextBaseline` (class), `SvgTextDecoration` (struct), `SvgTextDecorationGeometry` (class), `SvgTextDecorationSpec` (class), `SvgTextDecorationStyle` (enum), `SvgTextElement` (class), `SvgTextGlyph` (class), `SvgTextLayout` (class), `SvgTextPath` (class), `SvgTextPathLayout` (class), `SvgTextPathMethod` (enum), `SvgTextPathSide` (enum), `SvgTextPathSpacing` (enum), `SvgTextPlacement` (class), `SvgTextRenderer` (class), `SvgTextRendering` (enum), `SvgTextUnderlinePosition` (enum), `SvgTransferFunctionType` (enum), `SvgTransformBox` (enum), `SvgTransformOp` (enum), `SvgTrueTypeFont` (class), `SvgTspan` (class), `SvgTurbulenceType` (enum), `SvgUnicodeBidi` (enum), `SvgUnsafePolicy` (enum), `SvgUse` (class), `SvgVectorEffect2` (class), `SvgView` (class), `SvgViewport` (struct), `SvgViewportTransform` (struct), `SvgWritingMode` (enum), `SvgZoomAndPan` (enum), `public static func count(): Int64`, `formatSvgNumber` (func), `renderToPng` (func), `public static func reset(): Unit`, `svgBidiClass` (func), `svgMirrorBidiCodePoint` (func), `svgSetInlineStyleProperty` (func), `table` (func)
- `CssAttributeSelector`: `let caseInsensitive: Bool`, `let op: CssAttributeOperator`, `let value: ?String`
- `CssDeclaration`: `let value: String`
- `CssFontFaceRule`: `let family: String`, `let srcPresent: Bool`, `let weight: ?String`
- `CssLexer`: `tokenize` (func)
- `CssMediaFeature`: `let isMinWidth: Bool`
- `CssMediaQuery`: `let items: Array<CssMediaQueryItem>`
- `CssMediaQueryItem`: `let features: Array<CssMediaFeature>`, `mediaType` (let)
- `CssRule`: `let declarations: Array<CssDeclaration>`, `let selectors: Array<CssSelector>`, `specificity` (func)
- `CssSelector`: `let combinators: Array<CssCombinator>`, `let parts: Array<CssSelectorPart>`, `let specificity: CssSpecificity`
- `CssSelectorPart`: `let classes: Array<String>`, `let combinator: ?CssCombinator`, `simples` (let), `let typeName: ?String`
- `CssSpecificity`: `let classes: Int64`, `compareTo` (func), `let ids: Int64`, `plus` (func), `let types: Int64`, `zero` (let)
- `CssStyleSheet`: `colorProfiles` (let), `fontFaces` (let), `let rules: Array<CssRule>`
- `SvgAnchorInfo`: `let element: SvgElement`, `let target: String`
- `SvgAnimationInfo`: `let attributeName: String`, `let targetId: ?String`
- `SvgArcParams`: `let largeArc: Bool`, `let sweep: Bool`, `let xAxisRotation: Float64`
- `SvgAttribute`: `let value: String`
- `SvgAutoSize`: `static func rootSize(`
- `SvgBBoxOptions`: `clipped` (let)
- `SvgBitmap`: `pixel` (func), `let pixels: Array<Byte>`, `setPixel` (func), `writePng` (func)
- `SvgBounds`: `inflate` (func), `intersect` (func), `isEmpty` (func), `union` (func)
- `SvgBuilder`: `className` (func), `fillOpacity` (func), `strokeOpacity` (func), `strokeWidth` (func)
- `SvgClipRect`: `let bottom: ?Float64`, `let left: ?Float64`, `let right: ?Float64`, `let top: ?Float64`
- `SvgColor`: `Black` (let), `static let Transparent = SvgColor(0, 0, 0, alpha: 0.0)`, `let alpha: Float64`, `let blue: UInt8`, `let green: UInt8`
- `SvgComputedStyle`: `alignmentBaseline` (func), `baselineShift` (func), `clipRect` (func), `clipRule` (func), `colorInterpolation` (func), `colorProfile` (func), `colorRendering` (func), `direction` (func), `dominantBaseline` (func), `fillOpacity` (func), `fillRule` (func), `fontFamily` (func), `fontFeatures` (func), `fontKerning` (func), `fontSize` (func), `fontSizeAdjust` (func), `fontStretch` (func), `fontStyle` (func), `fontVariantCaps` (func), `fontVariantLigatures` (func), `fontWeight` (func), `imageRendering` (func), `isolationIsolate` (func), `letterSpacing` (func), `mixBlendMode` (func), `overflowMode` (func), `paintOrder` (func), `pathLengthValue` (func), `pointerEvents` (func), `shapeRendering` (func), `let source: CssStyleSource`, `sourceOf` (func), `stopColor` (func), `stopOpacity` (func), `strokeDashArray` (func), `strokeDashOffset` (func), `strokeLineCap` (func), `strokeLineJoin` (func), `strokeMiterLimit` (func), `strokeOpacity` (func), `strokeWidth` (func), `textAnchor` (func), `textDecoration` (func), `textDecorationColor` (func), `textDecorationSpec` (func), `textDecorationStyle` (func), `textDecorationThickness` (func), `textRendering` (func), `textUnderlinePosition` (func), `transformBox` (func), `unicodeBidi` (func), `vectorEffect` (func), `vectorEffects` (func), `wordSpacing` (func), `writingMode` (func)
- `SvgCoverageMask`: `applyTo` (func), `let coverage: Array<Byte>`, `coverageAt` (func)
- `SvgCrc32`: `static func checksum(bytes: Array<Byte>): Int64`, `update` (func)
- `SvgDisplayCommand`: `aspect` (let), `blendMode` (let), `bounds` (let), `clipBounds` (let), `clipQuads` (let), `let clipRect: ?SvgBounds`, `filter` (let), `isolated` (let), `nonScalingStroke` (let), `paintOverride` (let), `let tag: String`, `let textElement: ?SvgTextElement`
- `SvgDisplayList`: `let commands: Array<SvgDisplayCommand>`, `let logicalHeight: Float64`, `let logicalWidth: Float64`
- `SvgDocument`: `var declaration: ?XmlDeclaration = None`, `var doctype: ?DocTypeInfo = None`, `let epilog = ArrayList<SvgNode>()`, `parseOptions` (var), `let prolog = ArrayList<SvgNode>()`
- `SvgEdgeMode`: `Duplicate` (let), `static let NoEdge = SvgEdgeMode(2)`, `static let Wrap = SvgEdgeMode(1)`
- `SvgElement`: `appendElement` (func), `appendText` (func), `childrenOf` (func), `let namespace: String`, `let tag: String`
- `SvgException`: `let column: Int64`
- `SvgFeComponentTransfer`: `functionFor` (func)
- `SvgFeMerge`: `inputs` (prop)
- `SvgFilter`: `primitives` (prop)
- `SvgFilterBuffer`: `let pixels: Array<Byte>`
- `SvgFilterRenderer`: `apply` (func), `region` (func)
- `SvgFontFeatures`: `static let MAX_ENTRIES: Int64 = 64`, `enabled` (func)
- `SvgFontRegistry`: `defaultRegistry` (func), `derived` (func), `register` (func), `resolve` (func)
- `SvgFontStretch`: `percentage` (func)
- `SvgGeometry`: `bounds` (func), `screenCTM` (func), `strokeBounds` (func)
- `SvgGroupCompositor`: `composite` (func), `createLayer` (func)
- `SvgGzip`: `compress` (func), `decompress` (func)
- `SvgHersheyFont`: `advance` (func), `ascent` (func), `descent` (func), `glyphBounds` (func), `glyphPath` (func)
- `SvgInterpolator`: `static func numeric(from: Float64, to: Float64, t: Float64, mode!: SvgCalcMode = SvgCalcMode.Linear): Float64`, `numericList` (func), `splineValue` (func), `stringValue` (func)
- `SvgLength`: `isAbsolute` (func), `let value: Float64`
- `SvgLengthContext`: `let dpi: Float64`, `let fontSize: Float64`, `let viewportHeight: Float64`, `let viewportWidth: Float64`
- `SvgLightingPrimitive`: `lightSource` (func), `lightSources` (func)
- `SvgLineJoin`: `attrName` (func)
- `SvgManualClock`: `now` (func), `stop` (func)
- `SvgMarkerExpander`: `expand` (func)
- `SvgMarkerInstance`: `let viewportHeight: Float64`, `viewportMatrix` (let), `let viewportWidth: Float64`
- `SvgMatrix`: `apply` (func), `let b: Float64`, `let c: Float64`, `let d: Float64`, `determinant` (func), `let e: Float64`, `let f: Float64`, `identity` (let), `invert` (func), `rotateAround` (func)
- `SvgMutationEvent`: `let attributeName: ?String`, `let element: SvgElement`, `let newValue: ?String`, `let oldValue: ?String`
- `SvgMutationListener`: `func onMutation(event: SvgMutationEvent): Unit`
- `SvgNamespaces`: `static let SVG: String =`, `static let XLINK: String =`, `static let XML: String =`
- `SvgOverflow`: `clips` (func)
- `SvgPaint`: `static let CurrentColor = make(SvgPaintKind.CurrentColor)`, `let reference: ?String`
- `SvgPaintOrder`: `defaultOrder` (func), `let layers: Array<SvgPaintLayer>`
- `SvgParseOptions`: `xml` (let)
- `SvgPathCommand`: `let relative: Bool`
- `SvgPathData`: `let commands: Array<SvgPathCommand>`, `pointAtLength` (func), `totalLength` (func)
- `SvgPathLength`: `static func ratio(element: SvgElement, actualLength: Float64): Float64`
- `SvgPngDecoder`: `static func decode(bytes: Array<Byte>): SvgBitmap`
- `SvgPngEncoder`: `static func encode(bitmap: SvgBitmap): Array<Byte>`
- `SvgPointList`: `let points: Array<SvgPoint>`
- `SvgPreserveAspectRatio`: `Default` (let), `let align: SvgAspectAlign`, `let slice: Bool`
- `SvgRasterizer`: `fillGradient` (func), `strokeGradient` (func)
- `SvgRenderOptions`: `validatePixels` (func)
- `SvgRenderTreeBuilder`: `build` (func), `buildElement` (func)
- `SvgRenderer`: `renderToPng` (func)
- `SvgRgba`: `let alpha: Float64`, `let blue: Float64`, `let green: Float64`, `over` (func), `transparent` (let)
- `SvgStrokeOutliner`: `outlineContours` (func), `outlineElement` (func), `outlinePolyline` (func)
- `SvgStrokeStyle`: `let dashArray: Array<Float64>`, `let dashOffset: Float64`, `let lineCap: SvgLineCap`, `let lineJoin: SvgLineJoin`, `let miterLimit: Float64`
- `SvgStyleResolver`: `computeElement` (func), `fontFaces` (let)
- `SvgSwitch`: `select` (func)
- `SvgTag`: `isKnown` (func)
- `SvgTextDecoration`: `isNone` (func), `let lineThrough: Bool`
- `SvgTextDecorationGeometry`: `lineThroughOffset` (func), `overlineOffset` (func), `thickness` (func), `underlineOffset` (func)
- `SvgTextDecorationSpec`: `let lines: SvgTextDecoration`, `let thickness: ?SvgLength`, `let underlinePosition: SvgTextUnderlinePosition`
- `SvgTextGlyph`: `let advance: Float64`, `angle` (let), `ascent` (let), `let codePoint: Int64`, `descent` (let), `let fontSize: Float64`
- `SvgTextLayout`: `let advance: Float64`, `let bounds: ?SvgBounds`, `let glyphs: Array<SvgTextGlyph>`
- `SvgTextPathLayout`: `place` (func)
- `SvgTextPlacement`: `angle` (let), `originX` (let), `let originY: Float64`
- `SvgTextRenderer`: `decorationOutline` (func), `layout` (func), `outline` (func)
- `SvgTimeline`: `animations` (func), `duration` (func)
- `SvgTransform`: `identity` (let), `let operations: Array<SvgTransformOp>`
- `SvgTrueTypeFont`: `advance` (func), `ascent` (func), `descent` (func), `glyphBounds` (func), `glyphPath` (func), `load` (func)
- `SvgUnknownElement`: `let rawName: QName`
- `SvgVectorEffect`: `static prop FixedPosition: SvgVectorEffect`, `static prop NonRotation: SvgVectorEffect`, `static prop NonScalingSize: SvgVectorEffect`, `static prop NonScalingStroke: SvgVectorEffect`, `strokeScale` (func)
- `SvgVectorEffect2`: `apply` (func)
- `SvgViewBox`: `let minX: Float64`, `let minY: Float64`
- `SvgViewport`: `forView` (func), `nestedTransform` (func), `nestedViewport` (func)
- `SvgWriteOptions`: `let cdata: CdataMode`, `let charset: Charset`, `let trailingNewline: Bool`, `let xmlDeclaration: Bool`
- `SvgWriter`: `close` (func), `flush` (func)
- `SvgWritingMode`: `isVertical` (func)
