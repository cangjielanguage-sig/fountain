# f_chart

**JSON-driven SVG charts**: callers describe data and styling in one JSON document; at runtime `f_svg` turns it into SVG. Every chart implements the same `Chart` interface, one chart per source file, imported on demand.

> Field specification and a complete JSON example of every chart: [`doc/chart-json-spec.md`](doc/chart-json-spec.md).
> Design and milestones: [`doc/f_chart模块设计.md`](doc/f_chart模块设计.md).
> Drawing approach and JSON structure of every chart: [appendix](#appendix-drawing-approach-and-json-structure-for-each-chart) at the end of this document.

## Dependencies

```
f_chart
├── f_svg      SVG 1.1 document generation
├── f_data     JSON parsing (JsonObject / JsonValue)
└── f_base     BaseException
```

## Install

The module ships with the fountain repository; its version tracks the repository (currently `1.3.1019`):

```toml
[dependencies]
  "fountain::f_chart" = { path = "../fountain/f_chart" }
```

## M0: the Chart interface

```cangjie
package fountain::f_chart

import fountain::f_data.json.JsonObject

public interface Chart {
    func draw(data: JsonObject): String
}
```

- `data` is a chart JSON document; the `type` field selects the chart type.
- The return value is a complete SVG document string.
- Invalid input raises `ChartException`; `kind` distinguishes `InvalidJson` / `MissingField` / `InvalidValue` / `UnsupportedChart`.

### Minimal usage

```cangjie
import fountain::f_chart.*
import fountain::f_data.json.JsonValue

let data = JsonValue.fromStr("""
{
  "type": "bar",
  "title": "Monthly sales",
  "xAxis": { "type": "category", "labels": ["Jan", "Feb", "Mar"] },
  "yAxis": { "type": "linear", "min": 0 },
  "series": [{ "name": "Sales", "data": [120, 200, 150] }]
}
""").asObject()

let chart: Chart = BarChart()   // available from M1
let svg = chart.draw(data)
```

## Status

| Milestone | Capability | Status |
|---|---|---|
| M0 | `Chart` interface, `ChartException`, JSON specification | Done |
| M1 | Bar chart `BarChart` + shared rendering infrastructure | Done |
| M2 | Grouped bar chart `GroupedBarChart` | Done |
| M3 | Stacked bar chart `StackedBarChart` | Done |
| M4 | Percent-stacked bar chart `PercentStackedBarChart` | Done |
| M5 | Line chart `LineChart` (category / XY / time axes, smooth, symbols) | Done |
| M6 | Scatter chart `ScatterChart` (numeric / time axes) | Done |
| M7 | Combo chart `ComboChart` (bar/line/scatter in any combination, dual axes) | Done |
| M8 | Gantt chart `GanttChart` (timeline, progress, dependencies) | Done |
| M9 | Flowchart `Flowchart` (layered layout, six shapes, arrowed edges) | Done |
| M10 | Sequence chart `SequenceChart` (participants, lifelines, messages, dashed returns) | Done |
| M11 | Horizontal bar chart `HorizontalBarChart` | Done |
| M12 | Dot / Cleveland dot chart `DotChart` | Done |
| M13 | Radar chart `RadarChart` (multi-indicator, multi-series polygons) | Done |
| M14 | Area chart `AreaChart` (fill opacity, smooth, gaps for missing data) | Done |
| M15 | Stacked area chart `StackedAreaChart` (accumulated by `stack` group) | Done |
| M16 | Waterfall chart `WaterfallChart` (running totals, connectors, semantic colors) | Done |
| M17 | Histogram `HistogramChart` (equal-width bins, frequency bars) | Done |
| M18 | Density chart `DensityChart` (Gaussian kernel, Silverman bandwidth, fill) | Done |
| M19 | Box plot `BoxPlotChart` (five-number summary, whiskers, outliers) | Done |
| M20 | Violin chart `ViolinChart` (mirrored density, inner box) | Done |
| M21 | Swarm / jitter chart `SwarmChart` (deterministic jitter) | Done |
| M22 | Stem-and-leaf `StemLeafChart` (text grouping, leaf clamping) | Done |
| M23 | QQ plot `QQChart` (theoretical quantiles, least-squares reference line) | Done |
| M24 | Ridgeline `RidgeChart` (per-row offset densities, overlap factor) | Done |
| M25 | 2D histogram `Histogram2DChart` (square / hexagon bins) | Done |
| M26 | Bubble chart `BubbleChart` (radius mapping, labels) | Done |
| M27 | Correlation matrix `CorrelationMatrixChart` (three-color bands, value labels) | Done |
| M28 | Parallel coordinates `ParallelCoordinatesChart` (normalized multi-dimensional polylines) | Done |
| M29 | Contour chart `ContourChart` (grid levels, iso-line boundaries) | Done |
| M30 | Scatter matrix `ScatterMatrixChart` (pairwise scatter, diagonal labels) | Done |
| M31 | Pie chart `PieChart` (slices, percent labels) | Done |
| M32 | Donut chart `DonutChart` (hole, center text) | Done |
| M33 | Mosaic chart `MosaicChart` (column widths, stacking inside columns) | Done |
| M34 | Treemap `TreemapChart` (hierarchical areas, squarify layout) | Done |
| M35 | Funnel chart `FunnelChart` (stage bars, conversion rates) | Done |
| M36 | Sankey chart `SankeyChart` (layered nodes, flow bands) | Done |
| M37 | Pareto chart `ParetoChart` (descending bars, cumulative line) | Done |
| M38 | Control chart `ControlChart` (center line, upper/lower limits, out-of-limit points) | Done |
| M39 | Error bar chart `ErrorBarChart` (center value, lower/upper bounds, caps) | Done |
| M40 | Residual chart `ResidualChart` (residuals against fitted values, zero reference) | Done |
| M41 | Influence chart `InfluenceChart` (point size mapped to Cook's distance, labels) | Done |
| M42 | Probability chart `ProbabilityChart` (three distributions, least-squares reference line) | Done |
| M43 | Heatmap `HeatmapChart` (matrix cells, three-color interpolation, value labels) | Done |
| M44 | Calendar heatmap `CalendarHeatmapChart` (week grid, date range, color buckets) | Done |
| M45 | Box-scatter chart `BoxScatterChart` (box, whiskers, jittered raw points) | Done |
| M46 | Violin-box chart `ViolinBoxChart` (density outline, box, outliers) | Done |
| M47 | ROC curve `RocChart` (curve, diagonal, AUC label) | Done |
| M48 | PR curve `PrChart` (curve, precision baseline, AP label) | Done |
| M49 | Survival curve `SurvivalChart` (step line, censoring marks, confidence band) | Done |
| M50 | Forest chart `ForestChart` (confidence intervals, null line, weight squares, log axis) | Done |
| M51 | Nomogram `NomogramChart` (variable scales, total-points scale, risk tick marks) | Done |
| M52 | Flame chart `FlameChart` (call-stack tree, bottom-up, name/value coloring) | Done |
| M53 | Icicle chart `IcicleChart` (top-down, call-stack tree) | Done |
| M54 | Differential flame chart `DifferentialFlameChart` (red for added, blue for removed, two-version diff) | Done |
| M55 | Offline flame chart `OfflineFlameChart` (chosen subtree, depth limit) | Done |
| M56 | Heat flame chart `HeatFlameChart` (heat field, cold-to-hot gradient) | Done |
| M57 | Choropleth chart `ChoroplethChart` (region paths, color buckets, centroid labels) | Done |
| M58 | Dot density map `DotDensityMapChart` (base map, weighted radii) | Done |
| M59 | Heat map `HeatMapChart` (base map, influence radius, color gradient) | Done |
| M60 | Flow map `FlowMapChart` (region centroids, polyline paths, flow-width lines) | Done |
| M61 | Cartogram `CartogramChart` (centroid scaling, value / sqrt scaling) | Done |
| M62 | Node-link chart `NodeLinkChart` (force / circular / manual layouts) | Done |
| M63 | Arc chart `ArcChart` (nodes on a circle, quadratic Bézier arcs, sorted by value) | Done |
| M64 | Chord chart `ChordChart` (outer segments, ribbon bands, labels) | Done |
| M65 | Hive chart `HiveChart` (grouped clusters, rings inside clusters, cross-group links) | Done |
| M66 | Alluvial chart `AlluvialChart` (stage columns, flow bands, height allocation) | Done |
| M67 | Sankey alias (reuses `SankeyChart`, regression test) | Done |
| M68 | Network heatmap `NetworkHeatmapChart` (node square matrix, row/column labels) | Done |
| M69 | Sunburst chart `SunburstChart` (concentric rings, hierarchical angles, first-level labels) | Done |
| M70 | Circle packing `CirclePackingChart` (nested circles, area-to-radius, grid layout) | Done |
| M71 | Org chart `OrgChart` (vertical / horizontal layout, orthogonal links, centered parents) | Done |
| M72 | Nightingale rose chart `RoseChart` (equal angles, radius / area mapping) | Done |
| M73 | Waffle chart `WaffleChart` (largest-remainder rounding, cell matrix, legend) | Done |
| M74 | Pictogram `PictogramChart` (unit conversion, person / circle / square / custom path) | Done |
| M75 | Percent bar `PercentBarChart` (reuses percent stacking, `type=percent-bar`) | Done |
| M76 | Bullet chart `BulletChart` (range bands, value bar, target line) | Done |
| M77 | Dumbbell chart `DumbbellChart` (paired endpoints, connecting line, automatic range) | Done |
| M78 | Slope chart `SlopeChart` (two time points, slope lines, right-side labels) | Done |
| M79 | Lollipop chart `LollipopChart` (stems, round heads, `null` values skipped) | Done |
| M80 | Paired line chart `PairedLineChart` (before/after pairs, endpoints and labels) | Done |
| M81 | Timeline chart `TimelineChart` (horizontal / vertical, alternating events, description text) | Done |
| M82 | Streamgraph `StreamgraphChart` (centered stacking, wiggle / zero / symmetry) | Done |
| M83 | Candlestick chart `CandlestickChart` (wicks, bodies, up/down colors) | Done |
| M84 | Spiral chart `SpiralChart` (Archimedean spiral, turns / direction, period labels) | Done |
| M85 | Swimlane chart `SwimlaneChart` (horizontal / vertical lanes, nodes, orthogonal arrows) | Done |
| M86 | Funnel alias (reuses `FunnelChart`, regression test) | Done |
| M87 | Waterfall alias (reuses `WaterfallChart`, regression test) | Done |
| M88 | Raincloud chart `RaincloudChart` (half violin, rain dots, box plot combined) | Done |
| M89 | Dot strip chart `DotStripChart` (deterministic jitter, scatter, dot size) | Done |
| M90 | ECDF chart `EcdfChart` (sorted steps, cumulative frequency) | Done |
| M91 | Bland-Altman plot `BlandAltmanChart` (mean difference, ±1.96 SD limits) | Done |
| M92 | Volcano plot `VolcanoChart` (up/down classification, threshold lines, significance labels) | Done |
| M93 | Manhattan plot `ManhattanChart` (chromosome segments, alternating colors, threshold line) | Done |
| M93b | Confusion matrix `ConfusionMatrixChart` (row/column normalization, heat cells, values) | Done |
| M94 | Lift chart `LiftChart` (ascending polyline, data points, baseline dashed line) | Done |
| M95 | Gain chart `GainChart` (cumulative capture curve, diagonal baseline) | Done |
| M96 | Calibration curve `CalibrationChart` (predicted vs actual, diagonal toggle) | Done |
| M97 | Learning curve `LearningCurveChart` (train / validation, standard-deviation band, metric) | Done |
| M98 | LASSO path `LassoPathChart` (coefficient shrinkage paths, zero line, legend) | Done |
| M99 | Decision tree chart `DecisionTreeChart` (leaf slots, branch labels, leaf coloring) | Done |
| M100 | Partial dependence plot `PdpChart` (marginal-effect curve, feature labels) | Done |
| M101 | SHAP chart `ShapChart` (descending absolute value, signed colors, zero baseline) | Done |
| M102 | Word cloud `WordCloudChart` (square-root font scaling, rotation cycle, shelf layout) | Done |
| M103 | Word network `WordNetworkChart` (weight radii, force / circular, in-node labels) | Done |
| M104 | Tag cloud `tag-cloud` (`WordCloudChart` alias, regression test) | Done |
| M105 | Gauge chart `GaugeChart` (threshold bands, needle, center value) | Done |
| M106 | Calendar heatmap milestone closure (reuses `CalendarHeatmapChart`, regression test) | Done |

M1–M106 are all complete. Test count 1168, all passing (including 76 TUI subpackage cases).

## Chart samples (charts/)

`src/ChartGallery_test.cj` carries one real JSON document per milestone, renders it and writes the SVG into `charts/`:

- Naming: `M<number>-<type>.svg`, e.g. `M001-bar.svg`, `M093b-confusion-matrix.svg`, `M106-calendar-heatmap.svg`.
- 107 files in total (M1–M106 including M93b; aliases get their own file), each a complete SVG that a browser can open directly.
- Regenerate:

```bash
cd f_chart
cjpm test --skip-build
```

The tests assert that the SVG contains `<svg` and create `charts/` automatically; any change to the SVG content shows up in `git diff`, which makes visual regression easy.

The TUI subpackage generates 8 character-art samples through `src/tui/TuiGallery_test.cj`; `TuiFlameChart_test` additionally emits 4 flame-chart variants:

- Naming: `M<number>-<type>.tui.txt`, e.g. `M001-bar.tui.txt`, `M007-combo.tui.txt`, `M052-flame.tui.txt`.
- Flame-chart variants: `M052-flame-bottom-up`, `-top-down`, `-value`, `-frame-height`.
- All samples keep ANSI 24-bit true color, so `cat` shows the series colors; the series or segments of grouped / stacked / percent-stacked bars, the bars / lines / points of combo charts and every flame-chart node use distinct colors.
- The size comes from `width` / `height` in the JSON (character columns / rows); the samples share the same chart semantics as the SVG ones.

## TUI subpackage (fountain::f_chart.tui)

For terminal / SSH scenarios the TUI subpackage renders character art directly. It pulls in no third-party dependency and reuses the same JSON and `Chart` interface:

```cangjie
import fountain::f_chart.*
import fountain::f_chart.tui.*
import fountain::f_data.json.JsonValue

let svg = TuiBarChart().draw(data)   // returns an ANSI-colored string
print(svg)
```

### Per-cell rendering (`TuiCellChart`)

When the host already owns its terminal buffer (for example the `fprobe` TUI), parsing ANSI is both slow and easy to misalign on wide characters. `TuiLineChart` and `TuiBarChart` additionally implement `TuiCellChart`:

```cangjie
public interface TuiCellChart {
    func drawCells(data: JsonObject): Array<Array<String>>
}
```

- The outer array is rows, each with exactly `width` elements;
- the trailing half of a wide character is an empty string: the host skips that column but still advances the column index;
- elements contain no ANSI escape sequences; the host decides the colors;
- `draw` behaves exactly as before and still returns an ANSI string.

The other 6 chart classes only provide `draw` for now; add `drawCells` under the same contract when needed.

| Class | `type` | Description |
|---|---|---|
| `TuiBarChart` | `bar` | Single-series bar chart |
| `TuiGroupedBarChart` | `grouped-bar` | Side-by-side bars within a category |
| `TuiStackedBarChart` | `stacked-bar` | Stacking in both positive and negative directions |
| `TuiPercentStackedBarChart` | `percent-stacked-bar` | Normalized to 100% per category |
| `TuiLineChart` | `line` | Category / numeric / time axis, `null` breaks the line |
| `TuiScatterChart` | `scatter` | Scatter on numeric / time axes |
| `TuiComboChart` | `combo` | Any combination of the 6 bar / line / point types above, right axis supported |
| `TuiFlameChart` | `flame` | True-color call-stack flame graph, supports `bottom-up` / `top-down` and `colorBy` |

Conventions:

- `width` / `height` are character columns and rows; default 80×24, minimum 20×8. Writing `"width": 80, "height": 24` explicitly in TUI JSON is recommended.
- Output is an ANSI 24-bit true-color string, each row terminated by `\u{1B}[0m\n`, ready for `print`.
- Marks: the bar family cycles `█ ▓ ▒ ░` per series, lines `*`, points `o`, grid `·`, axes `│ ─ └`, legend `■`; even without color support, multi-series bars stay distinguishable through the symbols.
- CJK characters take 2 columns; labels wider than the available space are truncated with `…`.
- TUI combo charts require a category x-axis; series with `axis: "right"` need `yAxis2`.
- For flame charts, `frameHeight` is the maximum number of character rows per layer in the TUI; the default 18 compresses to the available height. `colorBy` supports `name` and `value`.

Full usage (JSON examples per class, size and layout, error handling, sample files) is in the [appendix: TUI subpackage usage](#appendix-tui-subpackage-usage) at the end of this document.

## Error semantics

`draw` returns a string only on success; every structural or numeric problem is raised as `ChartException` — it never returns an empty string or a half-built SVG. The `path` field looks like `series[0].data[2]` and is prefixed to the message when non-empty.

---

## Appendix: drawing approach and JSON structure for each chart

This section groups charts by function and documents the **drawing approach** and **JSON structure** of every chart. Full field semantics and more examples are in [`doc/chart-json-spec.md`](doc/chart-json-spec.md); every JSON below parses as-is.

### Common fields

All charts share the top-level fields below; each chart's JSON structure is an extension of them:

| Field | Type | Default | Description |
|---|---|---|---|
| `type` | string | — | Chart type discriminator; must match the index |
| `title` | string \| object | none | Title; the object form supports `text` / `subtext` / `align` / `fontSize` / `color` |
| `width` / `height` | number | 800 / 480 | Canvas size |
| `padding` | number \| object | 24 | Padding on all four sides, or `{top,right,bottom,left}` |
| `theme` | object | light | `background` / `palette` / `fontFamily` / `fontSize` / `textColor` / `axisColor` / `gridColor` |
| `legend` | object | shown | `show` / `position` / `orient` / `itemGap` / `markerSize` |
| `xAxis` / `yAxis` | object | — | `type` / `title` / `labels` / `min` / `max` / `tickCount` / `grid` / `labelRotate` / `labelFormat` / `logBase` / `values` |
| `yAxis2` | object | none | Right-hand numeric axis of combo charts |
| `series` | array | `[]` | Series; each item has `name` / `data` / `color` / `stack` / `axis` / `smooth` / `symbol` / `symbolSize` / `barWidth` / `opacity` / `areaStyle` / `label` |

Data shape codes: `C` = `number[]`; `XY` = `{x,y,...}[]`; `M` = `number[][]`; `N` = `nodes[] + links[]`; `H` = `nodes[]` (with `parent`); `S` = chart-specific structure.

Group index:

- 5.1 Comparison
- 5.2 Trend
- 5.3 Distribution
- 5.4 Relationship
- 5.5 Composition, hierarchy and network
- 5.6 Statistical diagnostics and model evaluation
- 5.7 Project, process and time
- 5.8 Flame charts
- 5.9 Maps
- 5.10 Text and gauges
- 5.11 Composite charts

### 5.1 Comparison

#### M1 Bar chart `bar`

- Implementation: `f_chart/src/BarChart.cj`
- Data shape: `C`
- Drawing: the category axis uses an equal-band layout, the value axis is linear; one bar per category with the baseline at 0, positive values upward and negative values downward, bar width defaults to 60% of the slot, and values can be shown on top of the bars.

```json
{
  "type": "bar",
  "title": "Monthly sales",
  "width": 800,
  "height": 480,
  "xAxis": { "type": "category", "title": "Month", "labels": ["Jan", "Feb", "Mar", "Apr", "May", "Jun"] },
  "yAxis": { "type": "linear", "title": "Sales (10k CNY)", "min": 0, "grid": true },
  "legend": { "show": false },
  "series": [
    { "name": "Sales", "type": "bar", "data": [120, 200, 150, 180, 240, 210], "barWidth": 32 }
  ]
}
```

#### M2 Grouped bar chart `grouped-bar`

- Implementation: `f_chart/src/GroupedBarChart.cj`
- Data shape: `C`
- Drawing: series sit side by side within one category, the band is split evenly among them, colors follow the palette and a legend is generated.

```json
{
  "type": "grouped-bar",
  "title": "Quarterly product sales",
  "xAxis": { "type": "category", "labels": ["Q1", "Q2", "Q3", "Q4"] },
  "yAxis": { "type": "linear", "title": "10k CNY", "min": 0 },
  "legend": { "show": true, "position": "top" },
  "series": [
    { "name": "Product A", "data": [120, 150, 170, 160] },
    { "name": "Product B", "data": [90, 110, 130, 140] },
    { "name": "Product C", "data": [60, 70, 80, 95] }
  ]
}
```

#### M3 Stacked bar chart `stacked-bar`

- Implementation: `f_chart/src/StackedBarChart.cj`
- Data shape: `C`
- Drawing: one stacked bar per category, series connect end to end from bottom to top, positive values upward and negative values downward, empty values are skipped.

```json
{
  "type": "stacked-bar",
  "title": "Revenue mix by region",
  "xAxis": { "type": "category", "labels": ["East", "South", "North", "West"] },
  "yAxis": { "type": "linear", "title": "10k CNY", "min": 0 },
  "series": [
    { "name": "Online", "stack": "revenue", "data": [120, 90, 70, 50] },
    { "name": "Store", "stack": "revenue", "data": [80, 70, 60, 40] },
    { "name": "Distribution", "stack": "revenue", "data": [40, 35, 30, 25] }
  ]
}
```

#### M4 Percent-stacked bar chart `percent-stacked-bar`

- Implementation: `f_chart/src/PercentStackedBarChart.cj`
- Data shape: `C`
- Drawing: each category is first normalized to percentages across series and then stacked; the value axis defaults to 0–100 and percentage labels can be shown on top of the bars.

```json
{
  "type": "percent-stacked-bar",
  "title": "Channel share",
  "xAxis": { "type": "category", "labels": ["2024", "2025", "2026"] },
  "yAxis": { "type": "linear", "title": "Share", "min": 0, "max": 100, "labelFormat": "{value}%" },
  "series": [
    { "name": "Online", "stack": "share", "data": [45, 52, 60] },
    { "name": "Store", "stack": "share", "data": [35, 30, 25] },
    { "name": "Distribution", "stack": "share", "data": [20, 18, 15] }
  ]
}
```

#### M11 Horizontal bar chart `horizontal-bar`

- Implementation: `f_chart/src/HorizontalBarChart.cj`
- Data shape: `C`
- Drawing: categories on the y-axis and values on the x-axis; horizontal bars extend from the 0 baseline in the positive or negative direction.

```json
{
  "type": "horizontal-bar",
  "title": "Sales by city",
  "width": 720,
  "height": 420,
  "xAxis": { "type": "linear", "title": "10k CNY", "min": 0, "grid": true },
  "yAxis": { "type": "category", "labels": ["Shanghai", "Beijing", "Shenzhen", "Guangzhou", "Hangzhou"] },
  "legend": { "show": false },
  "series": [
    { "name": "Sales", "data": [320, 290, 260, 210, 180], "barWidth": 24 }
  ]
}
```

#### M12 Dot / Cleveland dot chart `dot`

- Implementation: `f_chart/src/DotChart.cj`
- Data shape: `C`
- Drawing: category y-axis plus numeric x-axis; each category gets one horizontal stem with a dot, suited to precise comparison of a small number of categories.

```json
{
  "type": "dot",
  "title": "Satisfaction by department",
  "xAxis": { "type": "linear", "title": "Satisfaction", "min": 0, "max": 100 },
  "yAxis": { "type": "category", "labels": ["Internal", "Surgery", "Pediatrics", "Obstetrics", "Emergency"] },
  "legend": { "show": false },
  "series": [
    { "name": "Satisfaction", "data": [88, 82, 91, 86, 79], "symbolSize": 10 }
  ]
}
```

#### M13 Radar chart `radar`

- Implementation: `f_chart/src/RadarChart.cj`
- Data shape: `C`
- Drawing: indicator axes radiate from the center over several concentric polygons; each series closes into a polygon with a semi-transparent fill.

```json
{
  "type": "radar",
  "title": "Player capability",
  "width": 600,
  "height": 600,
  "indicators": [
    { "name": "Speed", "max": 100 },
    { "name": "Strength", "max": 100 },
    { "name": "Skill", "max": 100 },
    { "name": "Stamina", "max": 100 },
    { "name": "Awareness", "max": 100 }
  ],
  "series": [
    { "name": "Player A", "data": [85, 70, 90, 75, 88] },
    { "name": "Player B", "data": [70, 88, 65, 82, 72] }
  ]
}
```

#### M72 Nightingale rose chart `rose`

- Implementation: `f_chart/src/RoseChart.cj`
- Data shape: `S`
- Drawing: every sector has the same angle and the radius maps the value linearly or by square root, producing petals of different lengths.

```json
{
  "type": "rose",
  "title": "Sales share by category",
  "width": 600,
  "height": 600,
  "roseType": "radius",
  "series": [
    {
      "name": "Sales",
      "data": [
        { "name": "Womenswear", "value": 40 },
        { "name": "Menswear", "value": 30 },
        { "name": "Shoes", "value": 18 },
        { "name": "Bags", "value": 12 }
      ]
    }
  ]
}
```

#### M73 Waffle chart `waffle`

- Implementation: `f_chart/src/WaffleChart.cj`
- Data shape: `S`
- Drawing: the total is converted into a fixed number of cells (100 by default), each category's cells are allocated with the largest-remainder method, then filled row by row into the cell matrix.

```json
{
  "type": "waffle",
  "title": "Budget allocation",
  "width": 520,
  "height": 520,
  "cells": 100,
  "columns": 10,
  "series": [
    {
      "name": "Budget",
      "data": [
        { "name": "R&D", "value": 42 },
        { "name": "Marketing", "value": 28 },
        { "name": "Operations", "value": 18 },
        { "name": "Other", "value": 12 }
      ]
    }
  ]
}
```

#### M74 Pictogram `pictogram`

- Implementation: `f_chart/src/PictogramChart.cj`
- Data shape: `S`
- Drawing: each icon stands for a fixed unit; icons repeat with the count and wrap by column, and the remainder is drawn as a partial icon.

```json
{
  "type": "pictogram",
  "title": "Team size",
  "width": 720,
  "height": 360,
  "icon": "person",
  "unit": 10,
  "columns": 10,
  "series": [
    { "name": "R&D", "data": [{ "name": "R&D", "value": 120 }] },
    { "name": "Marketing", "data": [{ "name": "Marketing", "value": 60 }] }
  ]
}
```

#### M75 Percent bar `percent-bar`

- Implementation: `f_chart/src/PercentBarChart.cj`
- Data shape: `C`
- Drawing: a standalone type entry for the percent-stacked bar that reuses the same rendering logic, normalizing each category to 100% before stacking.

```json
{
  "type": "percent-bar",
  "title": "Quarterly revenue mix",
  "width": 720,
  "height": 360,
  "xAxis": { "type": "category", "labels": ["Q1", "Q2", "Q3", "Q4"] },
  "series": [
    { "name": "Product A", "data": [30, 40, 35, 50] },
    { "name": "Product B", "data": [50, 40, 45, 30] },
    { "name": "Product C", "data": [20, 20, 20, 20] }
  ]
}
```

#### M76 Bullet chart `bullet`

- Implementation: `f_chart/src/BulletChart.cj`
- Data shape: `S`
- Drawing: range bands, the actual-value bar and a target line, comparing the current value against the target horizontally.

```json
{
  "type": "bullet",
  "title": "Quarterly target achievement",
  "width": 720,
  "height": 360,
  "xAxis": { "type": "linear", "min": 0, "max": 100, "title": "Achievement" },
  "yAxis": { "type": "category", "labels": ["Revenue", "Collections", "New customers"] },
  "series": [
    {
      "name": "Achievement",
      "data": [
        { "name": "Revenue", "value": 72, "target": 80, "ranges": [50, 75, 100] },
        { "name": "Collections", "value": 88, "target": 85, "ranges": [60, 80, 100] },
        { "name": "New customers", "value": 45, "target": 70, "ranges": [40, 70, 100] }
      ]
    }
  ]
}
```

#### M77 Dumbbell chart `dumbbell`

- Implementation: `f_chart/src/DumbbellChart.cj`
- Data shape: `S`
- Drawing: each item connects a `low` and a `high` endpoint with a horizontal line; the two endpoints use distinct colors.

```json
{
  "type": "dumbbell",
  "title": "Score change over two years",
  "xAxis": { "type": "linear", "title": "Score", "min": 0, "max": 100 },
  "yAxis": { "type": "category", "labels": ["Team A", "Team B", "Team C"] },
  "series": [
    {
      "name": "2025 → 2026",
      "data": [
        { "name": "Team A", "low": 60, "high": 82 },
        { "name": "Team B", "low": 75, "high": 68 },
        { "name": "Team C", "low": 52, "high": 74 }
      ]
    }
  ]
}
```

#### M78 Slope chart `slope`

- Implementation: `f_chart/src/SlopeChart.cj`
- Data shape: `S`
- Drawing: only two time points; each series draws a slope line connecting both points, with dots at both ends and the series name labeled on the right.

```json
{
  "type": "slope",
  "title": "Ranking change",
  "xAxis": { "type": "category", "labels": ["2025", "2026"] },
  "yAxis": { "type": "linear", "title": "Score", "min": 0, "max": 100 },
  "series": [
    { "name": "Team A", "data": [60, 82] },
    { "name": "Team B", "data": [75, 68] },
    { "name": "Team C", "data": [52, 74] }
  ]
}
```

#### M79 Lollipop chart `lollipop`

- Implementation: `f_chart/src/LollipopChart.cj`
- Data shape: `C`
- Drawing: a dot sits on top of a vertical stem; multiple series take sub-slots inside the category band and empty values are skipped.

```json
{
  "type": "lollipop",
  "title": "Conversion by channel",
  "xAxis": { "type": "category", "labels": ["Search", "Social", "Email", "Direct", "Affiliate"] },
  "yAxis": { "type": "linear", "title": "Conversion", "min": 0, "labelFormat": "{value}%" },
  "legend": { "show": false },
  "series": [
    { "name": "Conversion", "data": [4.2, 2.8, 3.6, 5.1, 1.9], "symbolSize": 8 }
  ]
}
```

#### M80 Paired line chart `paired-line`

- Implementation: `f_chart/src/PairedLineChart.cj`
- Data shape: `S`
- Drawing: before/after paired points are joined by lines to show the change of the same object, with names on the right.

```json
{
  "type": "paired-line",
  "title": "Metrics before and after intervention",
  "xAxis": { "type": "category", "labels": ["Before", "After"] },
  "yAxis": { "type": "linear", "title": "Metric", "min": 0, "max": 100 },
  "series": [
    {
      "name": "Subject",
      "data": [
        { "name": "S1", "before": 62, "after": 78 },
        { "name": "S2", "before": 70, "after": 66 },
        { "name": "S3", "before": 55, "after": 81 },
        { "name": "S4", "before": 80, "after": 85 }
      ]
    }
  ]
}
```

### 5.2 Trend

#### M5 Line chart `line`

- Implementation: `f_chart/src/LineChart.cj`
- Data shape: `C / XY`
- Drawing: supports category, numeric and time x-axes; points are connected in order, smoothing (quadratic Bézier) is optional, `null` breaks the line into segments, and data-point symbols can be shown.

```json
{
  "type": "line",
  "title": "Monthly active users",
  "xAxis": { "type": "category", "labels": ["Jan", "Feb", "Mar", "Apr", "May", "Jun"] },
  "yAxis": { "type": "linear", "title": "10k users", "min": 0 },
  "series": [
    { "name": "App", "data": [120, 132, 145, 160, 178, 190], "smooth": true, "symbol": "circle", "symbolSize": 6 },
    { "name": "Web", "data": [80, 78, 82, 85, 88, 92], "smooth": true, "symbol": "square", "symbolSize": 6 }
  ]
}
```

#### M14 Area chart `area`

- Implementation: `f_chart/src/AreaChart.cj`
- Data shape: `C`
- Drawing: the area below the line fills down to the 0 baseline, supports smoothing and `null` segments, and the fill opacity is configurable (0.3 by default).

```json
{
  "type": "area",
  "title": "Cumulative registered users",
  "xAxis": { "type": "category", "labels": ["Jan", "Feb", "Mar", "Apr", "May", "Jun"] },
  "yAxis": { "type": "linear", "title": "10k users", "min": 0 },
  "series": [
    { "name": "Registered", "data": [20, 45, 75, 110, 150, 195], "smooth": true, "areaStyle": { "opacity": 0.25 } }
  ]
}
```

#### M15 Stacked area chart `stacked-area`

- Implementation: `f_chart/src/StackedAreaChart.cj`
- Data shape: `C`
- Drawing: multiple series are accumulated by `stack` group and drawn as stacked area bands that join seamlessly.

```json
{
  "type": "stacked-area",
  "title": "Traffic mix by client",
  "xAxis": { "type": "category", "labels": ["Jan", "Feb", "Mar", "Apr", "May", "Jun"] },
  "yAxis": { "type": "linear", "title": "10k visits", "min": 0 },
  "series": [
    { "name": "App", "stack": "traffic", "data": [120, 132, 145, 160, 178, 190], "areaStyle": { "opacity": 0.6 } },
    { "name": "Web", "stack": "traffic", "data": [80, 78, 82, 85, 88, 92], "areaStyle": { "opacity": 0.6 } },
    { "name": "Mini program", "stack": "traffic", "data": [40, 48, 55, 62, 70, 80], "areaStyle": { "opacity": 0.6 } }
  ]
}
```

#### M16 Waterfall chart `waterfall`

- Implementation: `f_chart/src/WaterfallChart.cj`
- Data shape: `S`
- Drawing: each bar is one increment or decrement and starts from the previous running total; increases, decreases and totals use different semantic colors, with connectors between bars.
- Alias: M87 also uses `waterfall` and reuses `WaterfallChart`.

```json
{
  "type": "waterfall",
  "title": "Profit breakdown",
  "xAxis": { "type": "category", "labels": ["Opening", "Revenue", "Cost", "Tax", "Closing"] },
  "yAxis": { "type": "linear", "title": "10k CNY", "min": 0 },
  "legend": { "show": false },
  "series": [
    {
      "name": "Profit",
      "data": [
        { "name": "Opening", "value": 120, "type": "total" },
        { "name": "Revenue", "value": 80, "type": "increase" },
        { "name": "Cost", "value": -45, "type": "decrease" },
        { "name": "Tax", "value": -15, "type": "decrease" },
        { "name": "Closing", "value": 140, "type": "total" }
      ]
    }
  ]
}
```

#### M82 Streamgraph `streamgraph`

- Implementation: `f_chart/src/StreamgraphChart.cj`
- Data shape: `C`
- Drawing: stacked areas unfold around a centered baseline (`zero` / `symmetry` / `wiggle`), forming a river-like band that flows up and down.

```json
{
  "type": "streamgraph",
  "title": "Music genre popularity",
  "xAxis": { "type": "category", "labels": ["2019", "2020", "2021", "2022", "2023", "2024"] },
  "yAxis": { "type": "linear", "grid": false },
  "baseline": "wiggle",
  "series": [
    { "name": "Pop", "data": [40, 45, 50, 48, 55, 60] },
    { "name": "Rock", "data": [30, 28, 25, 27, 24, 22] },
    { "name": "Electronic", "data": [15, 20, 28, 35, 40, 45] },
    { "name": "Folk", "data": [10, 12, 14, 13, 16, 18] }
  ]
}
```

#### M83 Candlestick chart `candlestick`

- Implementation: `f_chart/src/CandlestickChart.cj`
- Data shape: `S`
- Drawing: each period draws a high–low wick and an open–close body; close at or above open uses the up color, otherwise the down color.

```json
{
  "type": "candlestick",
  "title": "Daily candles",
  "xAxis": { "type": "category", "labels": ["2026-01-05", "2026-01-06", "2026-01-07", "2026-01-08"] },
  "yAxis": { "type": "linear", "title": "Price", "min": 0 },
  "series": [
    {
      "name": "Price",
      "data": [
        { "date": "2026-01-05", "open": 100, "high": 108, "low": 98, "close": 105 },
        { "date": "2026-01-06", "open": 105, "high": 110, "low": 103, "close": 108 },
        { "date": "2026-01-07", "open": 108, "high": 109, "low": 101, "close": 103 },
        { "date": "2026-01-08", "open": 103, "high": 107, "low": 100, "close": 106 }
      ]
    }
  ]
}
```

#### M84 Spiral chart `spiral`

- Implementation: `f_chart/src/SpiralChart.cj`
- Data shape: `S`
- Drawing: data points are laid out evenly along an Archimedean spiral, the radius grows with the index, and the number of turns and the rotation direction are configurable.

```json
{
  "type": "spiral",
  "title": "Monthly cycle",
  "width": 600,
  "height": 600,
  "turns": 3,
  "startAngle": -90,
  "clockwise": true,
  "series": [
    {
      "name": "Period value",
      "data": [
        { "period": "Jan", "value": 12 },
        { "period": "Feb", "value": 18 },
        { "period": "Mar", "value": 25 },
        { "period": "Apr", "value": 20 },
        { "period": "May", "value": 30 },
        { "period": "Jun", "value": 28 }
      ]
    }
  ]
}
```

### 5.3 Distribution

#### M17 Histogram `histogram`

- Implementation: `f_chart/src/HistogramChart.cj`
- Data shape: `C`
- Drawing: raw values are binned into equal-width intervals and the bar height is the frequency in that bin; the bin count defaults to `floor(sqrt(n))`.

```json
{
  "type": "histogram",
  "title": "Height distribution",
  "xAxis": { "type": "linear", "title": "Height (cm)" },
  "yAxis": { "type": "linear", "title": "Frequency", "min": 0 },
  "legend": { "show": false },
  "series": [
    {
      "name": "Samples",
      "data": [162, 165, 168, 170, 171, 172, 173, 174, 175, 176, 178, 180, 182, 185, 168, 172, 174, 176, 169, 171],
      "bins": 8
    }
  ]
}
```

#### M18 Kernel density / density chart `density`

- Implementation: `f_chart/src/DensityChart.cj`
- Data shape: `C`
- Drawing: a Gaussian kernel produces a smooth density-estimation curve, the bandwidth defaults to Silverman's rule, and the area below the curve is filled.

```json
{
  "type": "density",
  "title": "Income distribution",
  "xAxis": { "type": "linear", "title": "Monthly income (k CNY)" },
  "yAxis": { "type": "linear", "title": "Density", "min": 0 },
  "series": [
    { "name": "2025", "data": [8, 9, 10, 10, 11, 12, 13, 15, 16, 18, 20, 22, 25, 30], "bandwidth": 2.0, "fill": true },
    { "name": "2026", "data": [9, 10, 11, 12, 13, 14, 15, 17, 19, 21, 24, 27, 30, 35], "bandwidth": 2.0, "fill": false }
  ]
}
```

#### M19 Box plot `boxplot`

- Implementation: `f_chart/src/BoxPlotChart.cj`
- Data shape: `S`
- Drawing: the five-number summary draws the box (Q1–Q3) and the median line; whiskers extend to the extreme within 1.5 IQR with caps, and points beyond the whiskers are marked as outliers.

```json
{
  "type": "boxplot",
  "title": "Score distribution by class",
  "xAxis": { "type": "category", "labels": ["Class 1", "Class 2", "Class 3", "Class 4"] },
  "yAxis": { "type": "linear", "title": "Score", "min": 0, "max": 100 },
  "legend": { "show": false },
  "series": [
    {
      "name": "Score",
      "data": [
        { "name": "Class 1", "min": 55, "q1": 68, "median": 76, "q3": 85, "max": 96, "outliers": [42, 98] },
        { "name": "Class 2", "min": 60, "q1": 70, "median": 78, "q3": 86, "max": 94, "outliers": [] },
        { "name": "Class 3", "min": 50, "q1": 62, "median": 70, "q3": 80, "max": 90, "outliers": [35] },
        { "name": "Class 4", "min": 58, "q1": 72, "median": 82, "q3": 90, "max": 99, "outliers": [] }
      ]
    }
  ]
}
```

#### M20 Violin chart `violin`

- Implementation: `f_chart/src/ViolinChart.cj`
- Data shape: `C`
- Drawing: each category draws a mirrored kernel-density outline shaped like a violin, with a narrow box and median line embedded inside.

```json
{
  "type": "violin",
  "title": "Order value distribution by channel",
  "xAxis": { "type": "category", "labels": ["Search", "Social", "Email", "Direct"] },
  "yAxis": { "type": "linear", "title": "Order value (CNY)", "min": 0 },
  "legend": { "show": false },
  "series": [
    { "name": "Order value", "data": [[88, 92, 95, 99, 105], [110, 115, 120, 130, 150], [90, 96, 102, 108, 118], [85, 89, 94, 101, 112]], "bandwidth": 6.0, "showBox": true }
  ]
}
```

#### M21 Swarm / jitter chart `swarm`

- Implementation: `f_chart/src/SwarmChart.cj`
- Data shape: `C`
- Drawing: points of the same category are offset horizontally by deterministic jitter so they do not overlap, producing a swarm effect.

```json
{
  "type": "swarm",
  "title": "Measurements per group",
  "xAxis": { "type": "category", "labels": ["Control", "Low dose", "High dose"] },
  "yAxis": { "type": "linear", "title": "Measurement", "min": 0 },
  "series": [
    { "name": "Measurement", "data": [[12, 14, 15, 18], [22, 25, 30, 33], [36, 38, 40, 41]], "jitter": 0.25, "side": "both" }
  ]
}
```

#### M22 Stem-and-leaf `stem-leaf`

- Implementation: `f_chart/src/StemLeafChart.cj`
- Data shape: `C`
- Drawing: presented as a text table: the left column groups the stem (tens digit) and the right side concatenates leaves (units digit), wrapping to a new column when a row is too long.

```json
{
  "type": "stem-leaf",
  "title": "Exam scores as a stem-and-leaf plot",
  "width": 600,
  "height": 520,
  "stemUnit": 10,
  "leafDigits": 1,
  "series": [
    { "name": "Score", "data": [52, 55, 58, 61, 63, 63, 67, 70, 72, 75, 78, 81, 85, 88, 92, 96] }
  ]
}
```

#### M23 QQ plot `qq`

- Implementation: `f_chart/src/QQChart.cj`
- Data shape: `C`
- Drawing: sample quantiles are scattered against theoretical normal quantiles with a least-squares reference line.

```json
{
  "type": "qq",
  "title": "Normal QQ plot",
  "xAxis": { "type": "linear", "title": "Theoretical quantile" },
  "yAxis": { "type": "linear", "title": "Sample quantile" },
  "legend": { "show": false },
  "series": [
    { "name": "Samples", "data": [12, 15, 18, 20, 22, 24, 26, 28, 31, 35, 40], "distribution": "normal", "showLine": true }
  ]
}
```

#### M24 Ridgeline `ridge`

- Implementation: `f_chart/src/RidgeChart.cj`
- Data shape: `C`
- Drawing: the density curve of each category is overlaid row by row with an offset; `overlap` controls how much adjacent rows overlap, forming ridges.

```json
{
  "type": "ridge",
  "title": "Income distribution by year",
  "xAxis": { "type": "linear", "title": "Monthly income (k CNY)" },
  "yAxis": { "type": "category", "labels": ["2023", "2024", "2025", "2026"] },
  "series": [
    { "name": "2023", "data": [6, 8, 9, 10, 11, 12, 14, 16, 18, 22], "overlap": 0.5 },
    { "name": "2024", "data": [7, 9, 10, 12, 13, 15, 17, 20, 23, 28], "overlap": 0.5 },
    { "name": "2025", "data": [8, 10, 12, 14, 16, 18, 21, 25, 30, 36], "overlap": 0.5 },
    { "name": "2026", "data": [10, 12, 15, 18, 21, 24, 28, 33, 40, 48], "overlap": 0.5 }
  ]
}
```

#### M25 2D histogram / hexbin chart `2d-histogram`

- Implementation: `f_chart/src/Histogram2DChart.cj`
- Data shape: `XY`
- Drawing: counts are binned on a two-dimensional plane using a square or hexagon grid, and the color maps the count.

```json
{
  "type": "2d-histogram",
  "title": "Joint height/weight distribution",
  "xAxis": { "type": "linear", "title": "Height (cm)" },
  "yAxis": { "type": "linear", "title": "Weight (kg)" },
  "legend": { "show": false },
  "series": [
    {
      "name": "Samples",
      "bins": [12, 12],
      "shape": "hexagon",
      "data": [
        { "x": 165, "y": 58 }, { "x": 168, "y": 60 }, { "x": 170, "y": 62 },
        { "x": 172, "y": 65 }, { "x": 175, "y": 68 }, { "x": 178, "y": 72 },
        { "x": 180, "y": 75 }, { "x": 182, "y": 78 }, { "x": 168, "y": 55 }
      ]
    }
  ]
}
```

#### M88 Raincloud chart `raincloud`

- Implementation: `f_chart/src/RaincloudChart.cj`
- Data shape: `C`
- Drawing: jittered points on the left (rain), a half-violin density on the right (cloud), and a narrow box with median line layered in between.

```json
{
  "type": "raincloud",
  "title": "Score distribution by group",
  "xAxis": { "type": "category", "labels": ["Group A", "Group B", "Group C"] },
  "yAxis": { "type": "linear", "title": "Score", "min": 0 },
  "series": [
    { "name": "Score", "data": [55, 60, 62, 65, 68, 70, 72, 75, 78, 82, 88, 92], "bandwidth": 4.0, "showCloud": true, "showRain": true, "showBox": true }
  ]
}
```

#### M89 Dot strip chart `dot-strip`

- Implementation: `f_chart/src/DotStripChart.cj`
- Data shape: `C`
- Drawing: one column of points per category, spread horizontally inside the band with deterministic jitter; the dot size is configurable.

```json
{
  "type": "dot-strip",
  "title": "Small samples per group",
  "xAxis": { "type": "category", "labels": ["A", "B", "C"] },
  "yAxis": { "type": "linear", "title": "Value", "min": 0 },
  "series": [
    { "name": "Samples", "data": [12, 15, 18, 20, 24, 28, 31, 35], "jitter": 0.15, "dotSize": 7 }
  ]
}
```

#### M90 ECDF chart `ecdf`

- Implementation: `f_chart/src/EcdfChart.cj`
- Data shape: `C`
- Drawing: after sorting the samples, a step curve follows the cumulative proportion (i/n); the x-axis is the value and the y-axis the cumulative frequency.

```json
{
  "type": "ecdf",
  "title": "Response-time cumulative distribution",
  "xAxis": { "type": "linear", "title": "Response time (ms)" },
  "yAxis": { "type": "linear", "title": "Cumulative frequency", "min": 0, "max": 1 },
  "series": [
    { "name": "Before", "data": [120, 135, 150, 160, 175, 190, 210, 240, 280, 320] },
    { "name": "After", "data": [80, 90, 95, 100, 110, 120, 130, 145, 160, 180] }
  ]
}
```

#### M91 Bland-Altman plot `bland-altman`

- Implementation: `f_chart/src/BlandAltmanChart.cj`
- Data shape: `XY`
- Drawing: the x-axis is the mean of the two measurements and the y-axis their difference; points are plotted with the mean difference and ±1.96 SD limits overlaid.

```json
{
  "type": "bland-altman",
  "title": "Agreement between two measurement methods",
  "xAxis": { "type": "linear", "title": "Mean" },
  "yAxis": { "type": "linear", "title": "Difference" },
  "legend": { "show": false },
  "series": [
    {
      "name": "Measurement pairs",
      "data": [
        { "x": 10.2, "y": 10.5 }, { "x": 12.0, "y": 11.6 }, { "x": 14.5, "y": 14.9 },
        { "x": 16.1, "y": 15.8 }, { "x": 18.3, "y": 18.9 }, { "x": 20.0, "y": 19.5 }
      ]
    }
  ]
}
```

#### M45 Box + scatter chart `box-scatter`

- Implementation: `f_chart/src/BoxScatterChart.cj`
- Data shape: `C`
- Drawing: a box plot overlaid with jittered raw points, showing the five-number summary and the sample distribution together.

```json
{
  "type": "box-scatter",
  "title": "Distribution and raw points",
  "xAxis": { "type": "category", "labels": ["Group A", "Group B", "Group C"] },
  "yAxis": { "type": "linear", "title": "Measurement", "min": 0 },
  "series": [
    { "name": "Measurement", "data": [12, 14, 15, 17, 19, 22, 25, 28, 31, 35], "showBox": true, "jitter": 0.2 }
  ]
}
```

#### M46 Violin + box chart `violin-box`

- Implementation: `f_chart/src/ViolinBoxChart.cj`
- Data shape: `C`
- Drawing: a violin density outline with an embedded box, whiskers and Tukey outliers, combining the distribution shape with its statistics.

```json
{
  "type": "violin-box",
  "title": "Distribution, quantiles and outliers",
  "xAxis": { "type": "category", "labels": ["Group A", "Group B", "Group C"] },
  "yAxis": { "type": "linear", "title": "Measurement", "min": 0 },
  "series": [
    { "name": "Measurement", "data": [11, 13, 14, 16, 18, 20, 23, 26, 30, 36, 45], "bandwidth": 4.0, "showBox": true, "showOutliers": true }
  ]
}
```

### 5.4 Relationship

#### M6 Scatter chart `scatter`

- Implementation: `f_chart/src/ScatterChart.cj`
- Data shape: `XY`
- Drawing: scatter on numeric or time axes; points are positioned by (x, y) with configurable symbol size, shape and labels.

```json
{
  "type": "scatter",
  "title": "Height and weight",
  "xAxis": { "type": "linear", "title": "Height (cm)" },
  "yAxis": { "type": "linear", "title": "Weight (kg)" },
  "series": [
    {
      "name": "Samples",
      "symbolSize": 8,
      "data": [
        { "x": 160, "y": 52 }, { "x": 165, "y": 56 }, { "x": 168, "y": 60 },
        { "x": 170, "y": 62 }, { "x": 172, "y": 65 }, { "x": 175, "y": 68 },
        { "x": 178, "y": 72 }, { "x": 180, "y": 75 }, { "x": 183, "y": 80 }
      ]
    }
  ]
}
```

#### M26 Bubble chart `bubble`

- Implementation: `f_chart/src/BubbleChart.cj`
- Data shape: `XY`
- Drawing: builds on the scatter chart and maps a third value to the point radius, showing a three-variable relationship.

```json
{
  "type": "bubble",
  "title": "Country indicators",
  "xAxis": { "type": "linear", "title": "GDP per capita" },
  "yAxis": { "type": "linear", "title": "Life expectancy" },
  "series": [
    {
      "name": "Country",
      "sizeRange": [6, 34],
      "data": [
        { "x": 12000, "y": 72, "size": 40, "label": "Country A" },
        { "x": 25000, "y": 78, "size": 80, "label": "Country B" },
        { "x": 40000, "y": 82, "size": 120, "label": "Country C" },
        { "x": 60000, "y": 84, "size": 60, "label": "Country D" }
      ]
    }
  ]
}
```

#### M27 Correlation matrix `correlation-matrix`

- Implementation: `f_chart/src/CorrelationMatrixChart.cj`
- Data shape: `M`
- Drawing: an N×N square matrix where each cell is colored by a three-point interpolation of the correlation coefficient (negative, zero, positive); values can be labeled.

```json
{
  "type": "correlation-matrix",
  "title": "Variable correlations",
  "width": 640,
  "height": 640,
  "xAxis": { "type": "category", "labels": ["Height", "Weight", "Age", "Income"] },
  "yAxis": { "type": "category", "labels": ["Height", "Weight", "Age", "Income"] },
  "method": "pearson",
  "showValues": true,
  "series": [
    {
      "name": "Correlation",
      "data": [
        [1.00, 0.81, 0.12, 0.08],
        [0.81, 1.00, 0.18, 0.15],
        [0.12, 0.18, 1.00, 0.42],
        [0.08, 0.15, 0.42, 1.00]
      ]
    }
  ]
}
```

#### M28 Parallel coordinates `parallel-coordinates`

- Implementation: `f_chart/src/ParallelCoordinatesChart.cj`
- Data shape: `S`
- Drawing: one normalized vertical axis per dimension; each sample is a polyline joining the axes in order.

```json
{
  "type": "parallel-coordinates",
  "title": "Car model comparison",
  "width": 760,
  "height": 440,
  "dimensions": [
    { "name": "Price", "min": 0, "max": 60 },
    { "name": "Fuel", "min": 0, "max": 20 },
    { "name": "Power", "min": 0, "max": 400 },
    { "name": "Space", "min": 0, "max": 10 }
  ],
  "series": [
    { "name": "Sedan", "data": [[25, 7, 180, 6], [18, 6, 150, 5], [40, 9, 300, 7]] },
    { "name": "SUV", "data": [[35, 12, 250, 9], [50, 14, 350, 10]] }
  ]
}
```

#### M29 Contour chart `contour`

- Implementation: `f_chart/src/ContourChart.cj`
- Data shape: `XY`
- Drawing: a scalar field is computed on a regular grid and iso-lines are extracted; boundaries or filled regions are drawn per level.

```json
{
  "type": "contour",
  "title": "Response surface",
  "xAxis": { "type": "linear", "title": "Temperature" },
  "yAxis": { "type": "linear", "title": "Pressure" },
  "legend": { "show": false },
  "levels": 8,
  "interpolate": "linear",
  "series": [
    {
      "name": "Response",
      "data": [
        { "x": 0, "y": 0, "value": 10 }, { "x": 1, "y": 0, "value": 14 }, { "x": 2, "y": 0, "value": 20 },
        { "x": 0, "y": 1, "value": 12 }, { "x": 1, "y": 1, "value": 18 }, { "x": 2, "y": 1, "value": 26 },
        { "x": 0, "y": 2, "value": 16 }, { "x": 1, "y": 2, "value": 24 }, { "x": 2, "y": 2, "value": 34 }
      ]
    }
  ]
}
```

#### M30 Scatter matrix `scatter-matrix`

- Implementation: `f_chart/src/ScatterMatrixChart.cj`
- Data shape: `C`
- Drawing: a k×k grid of small scatters; off-diagonal cells show pairwise scatter and diagonal cells show the variable name.

```json
{
  "type": "scatter-matrix",
  "title": "Pairwise relationships",
  "width": 720,
  "height": 720,
  "variables": ["Height", "Weight", "Age"],
  "series": [
    {
      "name": "Samples",
      "data": [
        [160, 52, 22], [165, 56, 25], [168, 60, 28],
        [170, 62, 31], [172, 65, 35], [175, 68, 38],
        [178, 72, 42], [180, 75, 45], [183, 80, 50]
      ]
    }
  ]
}
```

#### M43 Heatmap `heatmap`

- Implementation: `f_chart/src/HeatmapChart.cj`
- Data shape: `M`
- Drawing: a two-dimensional matrix lays cells out by row and column, values are filled through color interpolation, and values plus cell gaps can be shown.

```json
{
  "type": "heatmap",
  "title": "Weekly activity",
  "xAxis": { "type": "category", "labels": ["Mon", "Tue", "Wed", "Thu", "Fri"] },
  "yAxis": { "type": "category", "labels": ["Morning", "Afternoon", "Evening"] },
  "colorRange": ["#e8f1fb", "#7fb3d5", "#1f4e79"],
  "showValues": true,
  "series": [
    {
      "name": "Activity",
      "data": [
        [12, 18, 20, 17, 25],
        [22, 28, 30, 26, 35],
        [30, 36, 32, 28, 40]
      ]
    }
  ]
}
```

#### M68 Network heatmap `network-heatmap`

- Implementation: `f_chart/src/NetworkHeatmapChart.cj`
- Data shape: `M`
- Drawing: a square matrix indexed by node; the cell color is the relationship strength between two nodes and the row/column labels are node names.

```json
{
  "type": "network-heatmap",
  "title": "Node relationship strength",
  "width": 640,
  "height": 640,
  "nodes": [
    { "id": "a", "name": "Gateway" },
    { "id": "b", "name": "Orders" },
    { "id": "c", "name": "Inventory" },
    { "id": "d", "name": "Payments" }
  ],
  "colorRange": ["#f7fbff", "#6baed6", "#08306b"],
  "series": [
    {
      "name": "Calls",
      "data": [
        [0, 120, 80, 95],
        [60, 0, 40, 130],
        [35, 25, 0, 20],
        [90, 110, 15, 0]
      ]
    }
  ]
}
```

### 5.5 Composition, hierarchy and network

#### M31 Pie chart `pie`

- Implementation: `f_chart/src/PieChart.cj`
- Data shape: `S`
- Drawing: central angles are allocated by value share and sectors drawn, percentages are labeled on the outside, with a legend.

```json
{
  "type": "pie",
  "title": "Market share",
  "width": 600,
  "height": 480,
  "startAngle": 0,
  "showPercent": true,
  "series": [
    {
      "name": "Share",
      "data": [
        { "name": "Brand A", "value": 38 },
        { "name": "Brand B", "value": 27 },
        { "name": "Brand C", "value": 20 },
        { "name": "Other", "value": 15 }
      ]
    }
  ]
}
```

#### M32 Donut chart `donut`

- Implementation: `f_chart/src/DonutChart.cj`
- Data shape: `S`
- Drawing: a circular hole is cut out of the pie center to form a ring; the center can show a total or a title.

```json
{
  "type": "donut",
  "title": "Budget mix",
  "width": 600,
  "height": 480,
  "innerRadius": 0.55,
  "centerText": "Total budget 100%",
  "series": [
    {
      "name": "Budget",
      "data": [
        { "name": "R&D", "value": 42 },
        { "name": "Marketing", "value": 28 },
        { "name": "Operations", "value": 18 },
        { "name": "Other", "value": 12 }
      ]
    }
  ]
}
```

#### M33 Mosaic chart `mosaic`

- Implementation: `f_chart/src/MosaicChart.cj`
- Data shape: `M`
- Drawing: column widths follow each column's total, categories stack vertically inside a column by share, and cell area corresponds to the joint frequency.

```json
{
  "type": "mosaic",
  "title": "Region and purchase intent",
  "width": 720,
  "height": 480,
  "xAxis": { "type": "category", "labels": ["East", "South", "North", "West"] },
  "series": [
    { "name": "Purchased", "data": [120, 90, 70, 50] },
    { "name": "Not purchased", "data": [80, 70, 60, 40] }
  ]
}
```

#### M34 Treemap `treemap`

- Implementation: `f_chart/src/TreemapChart.cj`
- Data shape: `H`
- Drawing: hierarchical nodes fill the parent rectangle by weight, splitting recursively along the longer edge, with children distinguished by color.

```json
{
  "type": "treemap",
  "title": "Disk usage",
  "width": 760,
  "height": 480,
  "tiling": "squarify",
  "nodes": [
    { "id": "root", "name": "root", "parent": null },
    { "id": "usr", "name": "usr", "parent": "root" },
    { "id": "var", "name": "var", "parent": "root" },
    { "id": "bin", "name": "bin", "parent": "usr", "value": 120 },
    { "id": "lib", "name": "lib", "parent": "usr", "value": 260 },
    { "id": "log", "name": "log", "parent": "var", "value": 90 },
    { "id": "cache", "name": "cache", "parent": "var", "value": 60 }
  ]
}
```

#### M35 Funnel chart `funnel`

- Implementation: `f_chart/src/FunnelChart.cj`
- Data shape: `S`
- Drawing: one horizontal stage bar per stage, lengths decreasing with the value, conversion rates labeled on the right.
- Alias: M86 also uses `funnel` and reuses `FunnelChart`.

```json
{
  "type": "funnel",
  "title": "Signup conversion",
  "width": 640,
  "height": 480,
  "gap": 2,
  "showConversion": true,
  "series": [
    {
      "name": "Stage",
      "data": [
        { "name": "Visits", "value": 10000 },
        { "name": "Signups", "value": 6200 },
        { "name": "Activated", "value": 3800 },
        { "name": "Paid", "value": 1200 }
      ]
    }
  ]
}
```

#### M36 Sankey chart `sankey`

- Implementation: `f_chart/src/SankeyChart.cj`
- Data shape: `N`
- Drawing: nodes are arranged in columns by level and links are cubic Bézier flow bands whose width follows the flow.

```json
{
  "type": "sankey",
  "title": "Traffic sources",
  "width": 760,
  "height": 480,
  "nodeWidth": 16,
  "nodeGap": 12,
  "nodes": [
    { "id": "search", "name": "Search" },
    { "id": "social", "name": "Social" },
    { "id": "home", "name": "Home" },
    { "id": "detail", "name": "Detail" },
    { "id": "cart", "name": "Cart" },
    { "id": "pay", "name": "Payment" }
  ],
  "links": [
    { "source": "search", "target": "home", "value": 400 },
    { "source": "social", "target": "home", "value": 300 },
    { "source": "home", "target": "detail", "value": 550 },
    { "source": "detail", "target": "cart", "value": 260 },
    { "source": "cart", "target": "pay", "value": 180 }
  ]
}
```

#### M69 Sunburst chart `sunburst`

- Implementation: `f_chart/src/SunburstChart.cj`
- Data shape: `H`
- Drawing: hierarchical data maps to concentric rings; each parent's angular range is subdivided by child weights and first-level nodes carry labels.

```json
{
  "type": "sunburst",
  "title": "Product revenue hierarchy",
  "width": 640,
  "height": 640,
  "innerRadius": 0.2,
  "nodes": [
    { "id": "root", "name": "All", "parent": null },
    { "id": "hw", "name": "Hardware", "parent": "root" },
    { "id": "sw", "name": "Software", "parent": "root" },
    { "id": "phone", "name": "Phones", "parent": "hw", "value": 60 },
    { "id": "pc", "name": "PCs", "parent": "hw", "value": 40 },
    { "id": "saas", "name": "SaaS", "parent": "sw", "value": 55 },
    { "id": "license", "name": "Licenses", "parent": "sw", "value": 25 }
  ]
}
```

#### M70 Circle packing `circle-packing`

- Implementation: `f_chart/src/CirclePackingChart.cj`
- Data shape: `H`
- Drawing: hierarchical circles are packed; leaf areas map the square root of the value, and parent circles enclose their children in a recursive layout.

```json
{
  "type": "circle-packing",
  "title": "File type share",
  "width": 640,
  "height": 640,
  "padding": 2,
  "nodes": [
    { "id": "root", "name": "All", "parent": null },
    { "id": "code", "name": "Code", "parent": "root" },
    { "id": "asset", "name": "Assets", "parent": "root" },
    { "id": "ts", "name": "TypeScript", "parent": "code", "value": 120 },
    { "id": "cj", "name": "Cangjie", "parent": "code", "value": 90 },
    { "id": "img", "name": "Images", "parent": "asset", "value": 70 },
    { "id": "font", "name": "Fonts", "parent": "asset", "value": 30 }
  ]
}
```

#### M71 Org chart / tree chart `org-chart`

- Implementation: `f_chart/src/OrgChart.cj`
- Data shape: `H`
- Drawing: a tree-like org chart: leaves take evenly spaced slots, parents sit at the midpoint of their children and orthogonal polylines connect them; vertical and horizontal layouts are supported.

```json
{
  "type": "org-chart",
  "title": "Organization",
  "width": 900,
  "height": 560,
  "layout": "vertical",
  "nodeWidth": 140,
  "nodeHeight": 48,
  "levelGap": 80,
  "nodes": [
    { "id": "ceo", "name": "CEO", "parent": null },
    { "id": "cto", "name": "CTO", "parent": "ceo" },
    { "id": "cfo", "name": "CFO", "parent": "ceo" },
    { "id": "fe", "name": "Frontend", "parent": "cto" },
    { "id": "be", "name": "Backend", "parent": "cto" },
    { "id": "fin", "name": "Finance", "parent": "cfo" }
  ]
}
```

#### M62 Node-link chart `node-link`

- Implementation: `f_chart/src/NodeLinkChart.cj`
- Data shape: `N`
- Drawing: nodes and links with deterministic force-directed, circular or manual layouts; line width maps the link value.

```json
{
  "type": "node-link",
  "title": "Service dependencies",
  "width": 760,
  "height": 520,
  "layout": "force",
  "linkDistance": 120,
  "charge": -300,
  "nodes": [
    { "id": "gw", "name": "Gateway", "group": "Edge" },
    { "id": "order", "name": "Orders", "group": "Business" },
    { "id": "stock", "name": "Inventory", "group": "Business" },
    { "id": "pay", "name": "Payments", "group": "Business" },
    { "id": "db", "name": "Database", "group": "Storage" }
  ],
  "links": [
    { "source": "gw", "target": "order", "value": 3 },
    { "source": "order", "target": "stock", "value": 2 },
    { "source": "order", "target": "pay", "value": 2 },
    { "source": "order", "target": "db", "value": 1 },
    { "source": "stock", "target": "db", "value": 1 }
  ]
}
```

#### M63 Arc chart `arc`

- Implementation: `f_chart/src/ArcChart.cj`
- Data shape: `N`
- Drawing: nodes sit on a circle ordered by total flow and are joined by quadratic Bézier arcs; the arc height controls how far they bend toward the center.

```json
{
  "type": "arc",
  "title": "Department collaboration",
  "width": 640,
  "height": 640,
  "arcHeight": 0.5,
  "nodes": [
    { "id": "rd", "name": "R&D" },
    { "id": "pm", "name": "Product" },
    { "id": "design", "name": "Design" },
    { "id": "qa", "name": "QA" },
    { "id": "ops", "name": "Ops" }
  ],
  "links": [
    { "source": "pm", "target": "rd", "value": 8 },
    { "source": "design", "target": "rd", "value": 5 },
    { "source": "rd", "target": "qa", "value": 6 },
    { "source": "qa", "target": "ops", "value": 3 }
  ]
}
```

#### M64 Chord chart `chord`

- Implementation: `f_chart/src/ChordChart.cj`
- Data shape: `N`
- Drawing: the outer ring is segmented by each node's total with gaps, and nodes are joined by ribbon-like closed paths whose width follows the flow.

```json
{
  "type": "chord",
  "title": "City migration",
  "width": 640,
  "height": 640,
  "padAngle": 0.02,
  "nodes": [
    { "id": "bj", "name": "Beijing" },
    { "id": "sh", "name": "Shanghai" },
    { "id": "gz", "name": "Guangzhou" },
    { "id": "sz", "name": "Shenzhen" }
  ],
  "links": [
    { "source": "bj", "target": "sh", "value": 120 },
    { "source": "sh", "target": "bj", "value": 90 },
    { "source": "gz", "target": "sz", "value": 80 },
    { "source": "sz", "target": "gz", "value": 60 },
    { "source": "bj", "target": "sz", "value": 40 }
  ]
}
```

#### M65 Hive chart `hive`

- Implementation: `f_chart/src/HiveChart.cj`
- Data shape: `N`
- Drawing: nodes cluster by `group`; cluster centers lie on a large circle, nodes inside a cluster are arranged in a ring, and cross-cluster relations are drawn as links.

```json
{
  "type": "hive",
  "title": "Skill relationships",
  "width": 760,
  "height": 520,
  "groupField": "group",
  "nodeRadius": 18,
  "clusterGap": 80,
  "nodes": [
    { "id": "cangjie", "name": "Cangjie", "group": "Language" },
    { "id": "go", "name": "Go", "group": "Language" },
    { "id": "sql", "name": "SQL", "group": "Data" },
    { "id": "redis", "name": "Redis", "group": "Data" },
    { "id": "k8s", "name": "K8s", "group": "Ops" }
  ],
  "links": [
    { "source": "cangjie", "target": "sql", "value": 2 },
    { "source": "go", "target": "redis", "value": 3 },
    { "source": "sql", "target": "redis", "value": 2 },
    { "source": "redis", "target": "k8s", "value": 1 }
  ]
}
```

#### M66 Alluvial chart `alluvial`

- Implementation: `f_chart/src/AlluvialChart.cj`
- Data shape: `N`
- Drawing: nodes are laid out in stage columns, each node's height is the larger of its inflow and outflow totals, and stages are joined by cubic Bézier flow bands.

```json
{
  "type": "alluvial",
  "title": "User state transitions",
  "width": 800,
  "height": 480,
  "stages": ["2025", "2026"],
  "nodeWidth": 14,
  "nodeGap": 10,
  "nodes": [
    { "id": "new-2025", "name": "New", "stage": "2025" },
    { "id": "old-2025", "name": "Returning", "stage": "2025" },
    { "id": "new-2026", "name": "New", "stage": "2026" },
    { "id": "old-2026", "name": "Returning", "stage": "2026" },
    { "id": "lost-2026", "name": "Churned", "stage": "2026" }
  ],
  "links": [
    { "source": "new-2025", "target": "old-2026", "value": 420 },
    { "source": "new-2025", "target": "lost-2026", "value": 180 },
    { "source": "old-2025", "target": "old-2026", "value": 600 },
    { "source": "old-2025", "target": "lost-2026", "value": 120 },
    { "source": "new-2026", "target": "old-2026", "value": 300 }
  ]
}
```

### 5.6 Statistical diagnostics and model evaluation

#### M37 Pareto chart `pareto`

- Implementation: `f_chart/src/ParetoChart.cj`
- Data shape: `C`
- Drawing: bars are sorted by descending value and a cumulative-percentage line is overlaid on the right, reaching 100%.

```json
{
  "type": "pareto",
  "title": "Defect cause analysis",
  "xAxis": { "type": "category", "labels": ["Appearance", "Size", "Assembly", "Function", "Packaging", "Other"] },
  "yAxis": { "type": "linear", "title": "Defects", "min": 0 },
  "showCumulative": true,
  "series": [
    { "name": "Defects", "data": [120, 80, 55, 30, 12, 8] }
  ]
}
```

#### M38 Control chart `control`

- Implementation: `f_chart/src/ControlChart.cj`
- Data shape: `C`
- Drawing: a line chart with a center line and dashed upper/lower control limits (mean ± 3σ); points beyond the limits are highlighted.

```json
{
  "type": "control",
  "title": "Process control chart",
  "xAxis": { "type": "category", "labels": ["1", "2", "3", "4", "5", "6", "7", "8"] },
  "yAxis": { "type": "linear", "title": "Measurement" },
  "legend": { "show": false },
  "series": [
    {
      "name": "Measurement",
      "data": [50.2, 49.8, 50.5, 50.1, 51.2, 49.5, 50.0, 50.3],
      "center": 50.0,
      "ucl": 51.5,
      "lcl": 48.5
    }
  ]
}
```

#### M39 Error bar chart `error-bar`

- Implementation: `f_chart/src/ErrorBarChart.cj`
- Data shape: `XY`
- Drawing: each item draws a center point, a vertical line for the lower/upper bounds and caps; the x-axis supports category, numeric and time.

```json
{
  "type": "error-bar",
  "title": "Group means and confidence intervals",
  "xAxis": { "type": "category", "labels": ["A", "B", "C", "D"] },
  "yAxis": { "type": "linear", "title": "Mean", "min": 0 },
  "legend": { "show": false },
  "series": [
    {
      "name": "Mean",
      "data": [
        { "x": "A", "y": 12.0, "low": 10.5, "high": 13.5 },
        { "x": "B", "y": 15.0, "low": 13.2, "high": 16.8 },
        { "x": "C", "y": 11.0, "low": 9.0, "high": 13.0 },
        { "x": "D", "y": 18.0, "low": 16.5, "high": 19.5 }
      ]
    }
  ]
}
```

#### M40 Residual chart `residual`

- Implementation: `f_chart/src/ResidualChart.cj`
- Data shape: `XY`
- Drawing: residuals are scattered against fitted values with a y=0 reference line, and the y range always includes 0.

```json
{
  "type": "residual",
  "title": "Regression residuals",
  "xAxis": { "type": "linear", "title": "Fitted value" },
  "yAxis": { "type": "linear", "title": "Residual" },
  "legend": { "show": false },
  "series": [
    {
      "name": "Residual",
      "data": [
        { "x": 10, "y": 0.5 }, { "x": 12, "y": -1.2 }, { "x": 14, "y": 0.8 },
        { "x": 16, "y": -0.4 }, { "x": 18, "y": 1.1 }, { "x": 20, "y": -0.9 }
      ]
    }
  ]
}
```

#### M41 Influence chart `influence`

- Implementation: `f_chart/src/InfluenceChart.cj`
- Data shape: `XY`
- Drawing: point radii map Cook's distance and sample names can be labeled, making high-influence points easy to spot.

```json
{
  "type": "influence",
  "title": "Leverage and influence",
  "xAxis": { "type": "linear", "title": "Leverage" },
  "yAxis": { "type": "linear", "title": "Studentized residual" },
  "legend": { "show": false },
  "series": [
    {
      "name": "Samples",
      "data": [
        { "x": 0.05, "y": 0.4, "cooksDistance": 0.02 },
        { "x": 0.08, "y": -1.1, "cooksDistance": 0.04 },
        { "x": 0.12, "y": 0.9, "cooksDistance": 0.06 },
        { "x": 0.20, "y": -2.0, "cooksDistance": 0.18 },
        { "x": 0.25, "y": 1.6, "cooksDistance": 0.12 }
      ]
    }
  ]
}
```

#### M42 Probability chart `probability`

- Implementation: `f_chart/src/ProbabilityChart.cj`
- Data shape: `C`
- Drawing: sample values are scattered against theoretical quantiles; the distribution can be `normal` / `uniform` / `exponential`, with a least-squares reference line.

```json
{
  "type": "probability",
  "title": "Normal probability plot",
  "xAxis": { "type": "linear", "title": "Theoretical quantile" },
  "yAxis": { "type": "linear", "title": "Sample quantile" },
  "legend": { "show": false },
  "series": [
    { "name": "Samples", "data": [12, 15, 18, 20, 22, 24, 26, 28, 31, 35, 40], "distribution": "normal", "showLine": true }
  ]
}
```

#### M47 ROC curve `roc`

- Implementation: `f_chart/src/RocChart.cj`
- Data shape: `XY`
- Drawing: false-positive rate on the x-axis and true-positive rate on the y-axis form the ROC curve, with a diagonal baseline and an AUC label.

```json
{
  "type": "roc",
  "title": "ROC curve",
  "xAxis": { "type": "linear", "title": "False positive rate", "min": 0, "max": 1 },
  "yAxis": { "type": "linear", "title": "True positive rate", "min": 0, "max": 1 },
  "diagonal": true,
  "series": [
    {
      "name": "Model A (AUC=0.86)",
      "auc": 0.86,
      "data": [
        { "x": 0.0, "y": 0.0 }, { "x": 0.1, "y": 0.45 }, { "x": 0.2, "y": 0.65 },
        { "x": 0.4, "y": 0.80 }, { "x": 0.6, "y": 0.90 }, { "x": 1.0, "y": 1.0 }
      ]
    }
  ]
}
```

#### M48 PR curve `pr`

- Implementation: `f_chart/src/PrChart.cj`
- Data shape: `XY`
- Drawing: recall on the x-axis and precision on the y-axis form the PR curve, with a precision baseline and an AP label.

```json
{
  "type": "pr",
  "title": "PR curve",
  "xAxis": { "type": "linear", "title": "Recall", "min": 0, "max": 1 },
  "yAxis": { "type": "linear", "title": "Precision", "min": 0, "max": 1 },
  "baseline": 0.12,
  "series": [
    {
      "name": "Model A (AP=0.72)",
      "ap": 0.72,
      "data": [
        { "x": 0.0, "y": 1.0 }, { "x": 0.2, "y": 0.92 }, { "x": 0.4, "y": 0.81 },
        { "x": 0.6, "y": 0.68 }, { "x": 0.8, "y": 0.45 }, { "x": 1.0, "y": 0.12 }
      ]
    }
  ]
}
```

#### M49 Survival / Kaplan-Meier chart `survival`

- Implementation: `f_chart/src/SurvivalChart.cj`
- Data shape: `S`
- Drawing: a Kaplan-Meier step survival curve over time, censoring points marked with +, and an optional confidence band.

```json
{
  "type": "survival",
  "title": "Kaplan-Meier survival curve",
  "xAxis": { "type": "linear", "title": "Time (months)", "min": 0 },
  "yAxis": { "type": "linear", "title": "Survival", "min": 0, "max": 1 },
  "confidence": false,
  "series": [
    {
      "name": "Treatment",
      "data": [
        { "time": 0, "survival": 1.0 }, { "time": 6, "survival": 0.92 },
        { "time": 12, "survival": 0.80 }, { "time": 18, "survival": 0.70, "censored": true },
        { "time": 24, "survival": 0.62 }
      ]
    },
    {
      "name": "Control",
      "data": [
        { "time": 0, "survival": 1.0 }, { "time": 6, "survival": 0.85 },
        { "time": 12, "survival": 0.68 }, { "time": 18, "survival": 0.55 },
        { "time": 24, "survival": 0.40 }
      ]
    }
  ]
}
```

#### M50 Forest chart `forest`

- Implementation: `f_chart/src/ForestChart.cj`
- Data shape: `S`
- Drawing: one row per item, the effect estimate is a square sized by weight, the horizontal line is the confidence interval, and a null line is drawn; log axes are supported.

```json
{
  "type": "forest",
  "title": "Effect size summary",
  "width": 720,
  "height": 480,
  "nullLine": 1,
  "xAxis": { "type": "log", "title": "OR (95% CI)", "min": 0.1, "max": 10 },
  "yAxis": { "type": "category", "labels": ["Study A", "Study B", "Study C", "Pooled"] },
  "series": [
    {
      "name": "OR",
      "data": [
        { "label": "Study A", "estimate": 0.8, "lower": 0.5, "upper": 1.3, "weight": 30 },
        { "label": "Study B", "estimate": 1.5, "lower": 1.1, "upper": 2.1, "weight": 45 },
        { "label": "Study C", "estimate": 1.1, "lower": 0.7, "upper": 1.8, "weight": 25 },
        { "label": "Pooled", "estimate": 1.2, "lower": 0.95, "upper": 1.5, "weight": 100 }
      ]
    }
  ]
}
```

#### M51 Nomogram `nomogram`

- Implementation: `f_chart/src/NomogramChart.cj`
- Data shape: `S`
- Drawing: several rows of scales — variable scales, a total-points scale and a risk scale — with positions mapped by coefficient, for nomogram scoring.

```json
{
  "type": "nomogram",
  "title": "Risk prediction nomogram",
  "width": 760,
  "height": 420,
  "variables": [
    { "name": "Age", "range": [20, 80], "points": [0, 100] },
    { "name": "Blood pressure", "range": [90, 180], "points": [0, 80] },
    { "name": "BMI", "range": [18, 35], "points": [0, 60] }
  ],
  "totalPoints": [0, 240],
  "risk": [
    { "points": 0, "probability": 0.02 },
    { "points": 80, "probability": 0.15 },
    { "points": 160, "probability": 0.45 },
    { "points": 240, "probability": 0.80 }
  ]
}
```

#### M92 Volcano plot `volcano`

- Implementation: `f_chart/src/VolcanoChart.cj`
- Data shape: `XY`
- Drawing: fold change on the x-axis and -log10(p) on the y-axis; points are classified into up-regulated, down-regulated and not significant by threshold, colored accordingly, with threshold lines drawn.

```json
{
  "type": "volcano",
  "title": "Differential expression",
  "xAxis": { "type": "linear", "title": "log2 Fold Change" },
  "yAxis": { "type": "linear", "title": "-log10(p)" },
  "foldChangeThreshold": 1,
  "pThreshold": 1.3,
  "legend": { "show": false },
  "series": [
    {
      "name": "Genes",
      "data": [
        { "x": -2.4, "y": 4.1, "label": "GENE1" },
        { "x": 2.1, "y": 3.6, "label": "GENE2" },
        { "x": 0.3, "y": 0.8, "label": "GENE3" },
        { "x": -0.6, "y": 1.1, "label": "GENE4" },
        { "x": 1.8, "y": 2.9, "label": "GENE5" }
      ]
    }
  ]
}
```

#### M93 Manhattan plot `manhattan`

- Implementation: `f_chart/src/ManhattanChart.cj`
- Data shape: `XY`
- Drawing: points are grouped by chromosome along the x-axis with gaps between groups, -log10(p) on the y-axis, chromosomes alternate colors and a significance threshold line is drawn.

```json
{
  "type": "manhattan",
  "title": "GWAS Manhattan plot",
  "xAxis": { "type": "linear", "title": "Chromosome position" },
  "yAxis": { "type": "linear", "title": "-log10(p)" },
  "threshold": 5.0,
  "legend": { "show": false },
  "series": [
    {
      "name": "SNP",
      "data": [
        { "x": 1000, "y": 2.1, "chromosome": "1" },
        { "x": 2500, "y": 4.8, "chromosome": "1" },
        { "x": 5200, "y": 6.2, "chromosome": "2" },
        { "x": 7800, "y": 1.5, "chromosome": "3" },
        { "x": 9900, "y": 5.4, "chromosome": "3" }
      ]
    }
  ]
}
```

#### M93b Confusion matrix `confusion-matrix`

- Implementation: `f_chart/src/ConfusionMatrixChart.cj`
- Data shape: `M`
- Drawing: a confusion-matrix square where color maps the count or the row/column-normalized value, with optional in-cell values.

```json
{
  "type": "confusion-matrix",
  "title": "Classification confusion matrix",
  "width": 560,
  "height": 560,
  "labels": ["Cat", "Dog", "Bird"],
  "normalize": "row",
  "showValues": true,
  "series": [
    {
      "name": "Samples",
      "data": [
        [45, 3, 2],
        [4, 38, 8],
        [1, 6, 33]
      ]
    }
  ]
}
```

#### M94 Lift chart `lift`

- Implementation: `f_chart/src/LiftChart.cj`
- Data shape: `XY`
- Drawing: the lift curve and its data points are drawn in ascending x order with a baseline.

```json
{
  "type": "lift",
  "title": "Lift curve",
  "xAxis": { "type": "linear", "title": "Sample share", "min": 0, "max": 1 },
  "yAxis": { "type": "linear", "title": "Lift" },
  "baseline": 1,
  "series": [
    {
      "name": "Model A",
      "data": [
        { "x": 0.1, "y": 2.8 }, { "x": 0.2, "y": 2.3 }, { "x": 0.4, "y": 1.7 },
        { "x": 0.6, "y": 1.35 }, { "x": 0.8, "y": 1.12 }, { "x": 1.0, "y": 1.0 }
      ]
    }
  ]
}
```

#### M95 Gain chart `gain`

- Implementation: `f_chart/src/GainChart.cj`
- Data shape: `XY`
- Drawing: the cumulative captured share is plotted against the sample share, with a diagonal baseline.

```json
{
  "type": "gain",
  "title": "Cumulative gain",
  "xAxis": { "type": "linear", "title": "Sample share", "min": 0, "max": 1 },
  "yAxis": { "type": "linear", "title": "Captured share", "min": 0, "max": 1 },
  "series": [
    {
      "name": "Model A",
      "data": [
        { "x": 0.1, "y": 0.42 }, { "x": 0.2, "y": 0.62 }, { "x": 0.4, "y": 0.82 },
        { "x": 0.6, "y": 0.91 }, { "x": 0.8, "y": 0.97 }, { "x": 1.0, "y": 1.0 }
      ]
    }
  ]
}
```

#### M96 Calibration curve `calibration`

- Implementation: `f_chart/src/CalibrationChart.cj`
- Data shape: `XY`
- Drawing: predicted probabilities are binned; the x-axis is the mean predicted value and the y-axis the observed positive rate, with a diagonal that can be turned off.

```json
{
  "type": "calibration",
  "title": "Probability calibration",
  "xAxis": { "type": "linear", "title": "Predicted probability", "min": 0, "max": 1 },
  "yAxis": { "type": "linear", "title": "Observed frequency", "min": 0, "max": 1 },
  "diagonal": true,
  "series": [
    {
      "name": "Model A",
      "data": [
        { "x": 0.05, "y": 0.08 }, { "x": 0.15, "y": 0.12 }, { "x": 0.30, "y": 0.35 },
        { "x": 0.50, "y": 0.46 }, { "x": 0.70, "y": 0.74 }, { "x": 0.90, "y": 0.88 }
      ]
    }
  ]
}
```

#### M97 Learning curve `learning-curve`

- Implementation: `f_chart/src/LearningCurveChart.cj`
- Data shape: `XY`
- Drawing: training and validation metrics against training-set size, with an optional ±standard-deviation band.

```json
{
  "type": "learning-curve",
  "title": "Learning curve",
  "xAxis": { "type": "linear", "title": "Training samples" },
  "yAxis": { "type": "linear", "title": "Accuracy", "min": 0, "max": 1 },
  "metric": "score",
  "series": [
    { "name": "Train", "data": [{ "x": 100, "y": 0.72 }, { "x": 500, "y": 0.86 }, { "x": 1000, "y": 0.91 }, { "x": 2000, "y": 0.94 }] },
    { "name": "Validation", "data": [{ "x": 100, "y": 0.60 }, { "x": 500, "y": 0.78 }, { "x": 1000, "y": 0.84 }, { "x": 2000, "y": 0.87 }] }
  ]
}
```

#### M98 LASSO path chart `lasso-path`

- Implementation: `f_chart/src/LassoPathChart.cj`
- Data shape: `S`
- Drawing: one coefficient path per variable as the regularization strength changes, with a y=0 zero line.

```json
{
  "type": "lasso-path",
  "title": "LASSO coefficient paths",
  "xAxis": { "type": "linear", "title": "log(lambda)" },
  "yAxis": { "type": "linear", "title": "Coefficient" },
  "variables": ["Age", "Blood pressure", "BMI", "Glucose"],
  "series": [
    { "name": "Age", "data": [{ "x": -4, "y": 0.8 }, { "x": -2, "y": 0.5 }, { "x": 0, "y": 0.1 }, { "x": 2, "y": 0.0 }] },
    { "name": "Blood pressure", "data": [{ "x": -4, "y": 0.6 }, { "x": -2, "y": 0.4 }, { "x": 0, "y": 0.2 }, { "x": 2, "y": 0.0 }] },
    { "name": "BMI", "data": [{ "x": -4, "y": 0.3 }, { "x": -2, "y": 0.1 }, { "x": 0, "y": 0.0 }, { "x": 2, "y": 0.0 }] },
    { "name": "Glucose", "data": [{ "x": -4, "y": 0.2 }, { "x": -2, "y": 0.0 }, { "x": 0, "y": 0.0 }, { "x": 2, "y": 0.0 }] }
  ]
}
```

#### M99 Decision tree chart `decision-tree`

- Implementation: `f_chart/src/DecisionTreeChart.cj`
- Data shape: `N`
- Drawing: the tree lays out by leaf slots, internal nodes are centered above their children, branches carry condition labels and leaf nodes use their own color.

```json
{
  "type": "decision-tree",
  "title": "Decision tree",
  "width": 900,
  "height": 520,
  "nodes": [
    { "id": "root", "label": "Age > 30?", "leaf": false },
    { "id": "left", "label": "Income > 10k?", "parent": "root", "leaf": false },
    { "id": "right", "label": "Approve", "parent": "root", "leaf": true },
    { "id": "ll", "label": "Reject", "parent": "left", "leaf": true },
    { "id": "lr", "label": "Approve", "parent": "left", "leaf": true }
  ],
  "edges": [
    { "source": "root", "target": "left", "label": "no" },
    { "source": "root", "target": "right", "label": "yes" },
    { "source": "left", "target": "ll", "label": "no" },
    { "source": "left", "target": "lr", "label": "yes" }
  ]
}
```

#### M100 Partial dependence plot `pdp`

- Implementation: `f_chart/src/PdpChart.cj`
- Data shape: `XY`
- Drawing: a line chart of the feature value against the model's marginal effect, with the feature name labeled at the top-left.

```json
{
  "type": "pdp",
  "title": "Effect of age on prediction",
  "xAxis": { "type": "linear", "title": "Age" },
  "yAxis": { "type": "linear", "title": "Prediction" },
  "feature": "Age",
  "legend": { "show": false },
  "series": [
    {
      "name": "PDP",
      "data": [
        { "x": 20, "y": 0.12 }, { "x": 30, "y": 0.28 }, { "x": 40, "y": 0.45 },
        { "x": 50, "y": 0.58 }, { "x": 60, "y": 0.62 }, { "x": 70, "y": 0.55 }
      ]
    }
  ]
}
```

#### M101 SHAP chart `shap`

- Implementation: `f_chart/src/ShapChart.cj`
- Data shape: `S`
- Drawing: horizontal bars of per-feature contributions for a single sample, sorted by absolute value, red for positive and blue for negative, with a zero baseline and value labels.

```json
{
  "type": "shap",
  "title": "Single-sample SHAP explanation",
  "width": 720,
  "height": 440,
  "features": ["Age", "Blood pressure", "BMI", "Glucose"],
  "series": [
    {
      "name": "SHAP",
      "data": [
        { "feature": "Age", "value": 0.32 },
        { "feature": "Blood pressure", "value": -0.18 },
        { "feature": "BMI", "value": 0.12 },
        { "feature": "Glucose", "value": -0.05 }
      ]
    }
  ]
}
```

### 5.7 Project, process and time

#### M8 Gantt chart `gantt`

- Implementation: `f_chart/src/GanttChart.cj`
- Data shape: `S`
- Drawing: a Gantt chart with time on the x-axis and tasks on the y-axis; each task is a rounded bar with an inline progress bar, and dependencies are joined by polyline arrows.

```json
{
  "type": "gantt",
  "title": "Project schedule",
  "width": 900,
  "height": 480,
  "xAxis": { "type": "time", "title": "Date" },
  "yAxis": { "type": "category", "labels": ["Requirements", "Design", "Development", "Testing", "Release"] },
  "tasks": [
    { "id": "t1", "name": "Requirements research", "start": "2026-01-05", "end": "2026-01-16", "progress": 1.0, "lane": "Requirements" },
    { "id": "t2", "name": "Solution design", "start": "2026-01-19", "end": "2026-02-06", "progress": 0.8, "dependsOn": ["t1"], "lane": "Design" },
    { "id": "t3", "name": "Coding", "start": "2026-02-09", "end": "2026-03-20", "progress": 0.45, "dependsOn": ["t2"], "lane": "Development" },
    { "id": "t4", "name": "Integration testing", "start": "2026-03-23", "end": "2026-04-10", "progress": 0.1, "dependsOn": ["t3"], "lane": "Testing" },
    { "id": "t5", "name": "Release", "start": "2026-04-13", "end": "2026-04-17", "progress": 0, "dependsOn": ["t4"], "lane": "Release" }
  ]
}
```

#### M9 Flowchart `flowchart`

- Implementation: `f_chart/src/Flowchart.cj`
- Data shape: `N`
- Drawing: nodes are layered by incoming edges and stacked vertically within a layer; six node shapes are supported and edges are orthogonal or curved with arrowheads.

```json
{
  "type": "flowchart",
  "title": "Order processing flow",
  "width": 900,
  "height": 520,
  "layout": "vertical",
  "nodes": [
    { "id": "start", "label": "Start", "shape": "ellipse" },
    { "id": "create", "label": "Create order", "shape": "rect" },
    { "id": "pay", "label": "Paid?", "shape": "diamond" },
    { "id": "ship", "label": "Ship", "shape": "rect" },
    { "id": "cancel", "label": "Cancel order", "shape": "rect" },
    { "id": "end", "label": "End", "shape": "ellipse" }
  ],
  "edges": [
    { "source": "start", "target": "create" },
    { "source": "create", "target": "pay" },
    { "source": "pay", "target": "ship", "label": "yes" },
    { "source": "pay", "target": "cancel", "label": "no" },
    { "source": "ship", "target": "end" },
    { "source": "cancel", "target": "end" }
  ]
}
```

#### M10 Sequence chart `sequence`

- Implementation: `f_chart/src/SequenceChart.cj`
- Data shape: `S`
- Drawing: participant boxes at the top with lifelines dropping down, messages as horizontal arrowed lines, returns as dashed lines, and notes as sticky boxes.

```json
{
  "type": "sequence",
  "title": "Login sequence",
  "width": 900,
  "height": 520,
  "participants": [
    { "id": "user", "name": "User" },
    { "id": "app", "name": "Client" },
    { "id": "auth", "name": "Auth service" },
    { "id": "db", "name": "Database" }
  ],
  "messages": [
    { "from": "user", "to": "app", "text": "Enter credentials", "type": "sync" },
    { "from": "app", "to": "auth", "text": "POST /login", "type": "sync" },
    { "from": "auth", "to": "db", "text": "Query user", "type": "sync" },
    { "from": "db", "to": "auth", "text": "User record", "type": "return", "dashed": true },
    { "from": "auth", "to": "app", "text": "token", "type": "return", "dashed": true },
    { "from": "app", "to": "user", "text": "Login succeeded", "type": "async" }
  ]
}
```

#### M81 Timeline chart `timeline`

- Implementation: `f_chart/src/TimelineChart.cj`
- Data shape: `S`
- Drawing: events are laid out over time: in horizontal mode they alternate above and below the axis, in vertical mode the date sits on the left and the title on the right; colors can follow `group`.

```json
{
  "type": "timeline",
  "title": "Product milestones",
  "width": 900,
  "height": 420,
  "orientation": "horizontal",
  "events": [
    { "date": "2026-01", "title": "Kickoff", "description": "Requirements review done" },
    { "date": "2026-03", "title": "Internal beta", "description": "First users onboarded" },
    { "date": "2026-06", "title": "Public beta", "description": "Registration opened" },
    { "date": "2026-09", "title": "General availability", "description": "Full rollout" }
  ]
}
```

#### M85 Swimlane chart `swimlane`

- Implementation: `f_chart/src/SwimlaneChart.cj`
- Data shape: `S`
- Drawing: nodes are placed inside horizontal or vertical swimlanes and joined by orthogonal polylines with arrows, showing hand-offs across roles.

```json
{
  "type": "swimlane",
  "title": "Approval flow",
  "width": 900,
  "height": 560,
  "direction": "horizontal",
  "lanes": [
    { "id": "employee", "name": "Employee" },
    { "id": "manager", "name": "Manager" },
    { "id": "finance", "name": "Finance" }
  ],
  "nodes": [
    { "id": "submit", "label": "Submit request", "lane": "employee" },
    { "id": "review", "label": "Manager approval", "lane": "manager" },
    { "id": "pay", "label": "Payment", "lane": "finance" },
    { "id": "reject", "label": "Rejected", "lane": "manager" }
  ],
  "edges": [
    { "source": "submit", "target": "review" },
    { "source": "review", "target": "pay", "label": "approved" },
    { "source": "review", "target": "reject", "label": "rejected" }
  ]
}
```

### 5.8 Flame charts

#### M52 Flame chart `flame`

- Implementation: `f_chart/src/FlameChart.cj`
- Data shape: `H`
- Drawing: the call-stack tree stacks from the bottom up, rectangle width follows each node's own time, and color comes from a name hash or a value mapping.

```json
{
  "type": "flame",
  "title": "CPU flame graph",
  "width": 900,
  "height": 480,
  "orientation": "bottom-up",
  "colorBy": "name",
  "nodes": [
    { "id": "root", "name": "main", "parent": null, "value": 100 },
    { "id": "parse", "name": "parse", "parent": "root", "value": 40 },
    { "id": "render", "name": "render", "parent": "root", "value": 60 },
    { "id": "lex", "name": "lex", "parent": "parse", "value": 25 },
    { "id": "ast", "name": "ast", "parent": "parse", "value": 15 },
    { "id": "layout", "name": "layout", "parent": "render", "value": 35 },
    { "id": "paint", "name": "paint", "parent": "render", "value": 25 }
  ]
}
```

#### M53 Icicle chart `icicle`

- Implementation: `f_chart/src/IcicleChart.cj`
- Data shape: `H`
- Drawing: same structure as the flame chart, but the root sits at the top and children expand downward.

```json
{
  "type": "icicle",
  "title": "Call-stack icicle",
  "width": 900,
  "height": 480,
  "orientation": "top-down",
  "colorBy": "name",
  "nodes": [
    { "id": "root", "name": "main", "parent": null, "value": 100 },
    { "id": "parse", "name": "parse", "parent": "root", "value": 40 },
    { "id": "render", "name": "render", "parent": "root", "value": 60 },
    { "id": "lex", "name": "lex", "parent": "parse", "value": 25 },
    { "id": "ast", "name": "ast", "parent": "parse", "value": 15 },
    { "id": "layout", "name": "layout", "parent": "render", "value": 35 },
    { "id": "paint", "name": "paint", "parent": "render", "value": 25 }
  ]
}
```

#### M54 Differential flame chart `differential-flame`

- Implementation: `f_chart/src/DifferentialFlameChart.cj`
- Data shape: `H`
- Drawing: compares two versions of the call tree; width follows the new version's value and color follows the delta, red for added and blue for removed.

```json
{
  "type": "differential-flame",
  "title": "Version difference",
  "width": 900,
  "height": 480,
  "nodes": [
    { "id": "root", "name": "main", "parent": null, "value1": 100, "value2": 120 },
    { "id": "parse", "name": "parse", "parent": "root", "value1": 40, "value2": 30 },
    { "id": "render", "name": "render", "parent": "root", "value1": 60, "value2": 90 },
    { "id": "lex", "name": "lex", "parent": "parse", "value1": 25, "value2": 20 },
    { "id": "layout", "name": "layout", "parent": "render", "value1": 35, "value2": 55 },
    { "id": "paint", "name": "paint", "parent": "render", "value1": 25, "value2": 35 }
  ]
}
```

#### M55 Offline flame chart `offline-flame`

- Implementation: `f_chart/src/OfflineFlameChart.cj`
- Data shape: `H`
- Drawing: starts from the given subtree, truncates at the maximum depth and normalizes width against that subtree root's value.

```json
{
  "type": "offline-flame",
  "title": "render subtree",
  "width": 900,
  "height": 480,
  "root": "render",
  "maxDepth": 4,
  "nodes": [
    { "id": "root", "name": "main", "parent": null, "value": 100 },
    { "id": "parse", "name": "parse", "parent": "root", "value": 40 },
    { "id": "render", "name": "render", "parent": "root", "value": 60 },
    { "id": "layout", "name": "layout", "parent": "render", "value": 35 },
    { "id": "paint", "name": "paint", "parent": "render", "value": 25 },
    { "id": "text", "name": "text", "parent": "layout", "value": 20 },
    { "id": "image", "name": "image", "parent": "layout", "value": 15 }
  ]
}
```

#### M56 Heat flame chart `heat-flame`

- Implementation: `f_chart/src/HeatFlameChart.cj`
- Data shape: `H`
- Drawing: flame-chart rectangles are colored by the `heat` field using a cold-to-hot gradient, and the heat can be shown inside the block.

```json
{
  "type": "heat-flame",
  "title": "CPU hot spots",
  "width": 900,
  "height": 480,
  "heatField": "self",
  "colorRange": ["#ffffcc", "#fd8d3c", "#800026"],
  "nodes": [
    { "id": "root", "name": "main", "parent": null, "value": 100, "self": 0 },
    { "id": "parse", "name": "parse", "parent": "root", "value": 40, "self": 5 },
    { "id": "render", "name": "render", "parent": "root", "value": 60, "self": 8 },
    { "id": "lex", "name": "lex", "parent": "parse", "value": 25, "self": 25 },
    { "id": "layout", "name": "layout", "parent": "render", "value": 35, "self": 35 },
    { "id": "paint", "name": "paint", "parent": "render", "value": 25, "self": 25 }
  ]
}
```

### 5.9 Maps

#### M57 Choropleth chart `choropleth`

- Implementation: `f_chart/src/ChoroplethChart.cj`
- Data shape: `S`
- Drawing: region paths are drawn directly in the map's user coordinate system, the fill is bucketed by value, and the region name is labeled at its centroid.

```json
{
  "type": "choropleth",
  "title": "Sales by province",
  "width": 760,
  "height": 560,
  "viewBox": [0, 0, 760, 560],
  "colorRange": ["#e8f1fb", "#7fb3d5", "#1f4e79"],
  "showLabels": true,
  "regions": [
    { "id": "east", "name": "East", "value": 320, "path": "M 420 180 L 560 190 L 570 300 L 430 310 Z" },
    { "id": "south", "name": "South", "value": 260, "path": "M 430 320 L 560 315 L 550 430 L 420 420 Z" },
    { "id": "north", "name": "North", "value": 210, "path": "M 300 120 L 410 130 L 415 240 L 300 230 Z" },
    { "id": "west", "name": "West", "value": 150, "path": "M 120 180 L 290 190 L 295 360 L 130 350 Z" }
  ]
}
```

#### M58 Dot density map `dot-density-map`

- Implementation: `f_chart/src/DotDensityMapChart.cj`
- Data shape: `S`
- Drawing: an optional region base map with point radii scaled by the square root of the weight, well suited to showing distribution density.

```json
{
  "type": "dot-density-map",
  "title": "Store distribution",
  "width": 760,
  "height": 560,
  "viewBox": [0, 0, 760, 560],
  "radius": 3,
  "regions": [
    { "id": "area", "name": "Area", "path": "M 100 100 L 650 110 L 640 480 L 120 470 Z" }
  ],
  "points": [
    { "x": 220, "y": 210, "weight": 2 },
    { "x": 260, "y": 230, "weight": 1 },
    { "x": 410, "y": 300, "weight": 3 },
    { "x": 450, "y": 320, "weight": 2 },
    { "x": 520, "y": 380, "weight": 1 }
  ]
}
```

#### M59 Heat map `heat-map`

- Implementation: `f_chart/src/HeatMap.cj`
- Data shape: `S`
- Drawing: semi-transparent heat circles are layered on the base map and drawn in value order so the gradient builds from the inside out.

```json
{
  "type": "heat-map",
  "title": "Visit heat",
  "width": 760,
  "height": 560,
  "viewBox": [0, 0, 760, 560],
  "radius": 28,
  "colorRange": ["#ffffcc", "#fd8d3c", "#800026"],
  "regions": [
    { "id": "area", "name": "Area", "path": "M 100 100 L 650 110 L 640 480 L 120 470 Z" }
  ],
  "points": [
    { "x": 240, "y": 220, "value": 20 },
    { "x": 300, "y": 260, "value": 45 },
    { "x": 420, "y": 310, "value": 80 },
    { "x": 500, "y": 360, "value": 35 }
  ]
}
```

#### M60 Flow map `flow-map`

- Implementation: `f_chart/src/FlowMapChart.cj`
- Data shape: `S`
- Drawing: flow lines (straight or polyline) are drawn between region centroids, and the line width maps the flow magnitude.

```json
{
  "type": "flow-map",
  "title": "Population migration",
  "width": 760,
  "height": 560,
  "viewBox": [0, 0, 760, 560],
  "regions": [
    { "id": "a", "name": "City A", "path": "M 170 200 L 250 210 L 245 280 L 165 270 Z" },
    { "id": "b", "name": "City B", "path": "M 480 300 L 560 310 L 555 380 L 475 370 Z" }
  ],
  "flows": [
    { "source": "a", "target": "b", "value": 1200, "points": [[210, 240], [350, 300], [520, 340]] },
    { "source": "b", "target": "a", "value": 800, "points": [[520, 340], [350, 320], [210, 240]] }
  ]
}
```

#### M61 Cartogram `cartogram`

- Implementation: `f_chart/src/CartogramChart.cj`
- Data shape: `S`
- Drawing: region shapes are scaled around their centroid by `value` or `sqrt` ratio, producing a cartogram.

```json
{
  "type": "cartogram",
  "title": "Scaled by population",
  "width": 760,
  "height": 560,
  "viewBox": [0, 0, 760, 560],
  "scaleBy": "sqrt",
  "regions": [
    { "id": "a", "name": "District A", "value": 400, "path": "M 180 200 L 260 205 L 265 280 L 185 275 Z", "centroid": [220, 240] },
    { "id": "b", "name": "District B", "value": 100, "path": "M 460 300 L 520 305 L 525 365 L 465 360 Z", "centroid": [490, 330] },
    { "id": "c", "name": "District C", "value": 250, "path": "M 320 120 L 400 125 L 405 190 L 325 185 Z", "centroid": [360, 155] }
  ]
}
```

### 5.10 Text and gauges

#### M102 Word cloud `word-cloud`

- Implementation: `f_chart/src/WordCloudChart.cj`
- Data shape: `S`
- Drawing: term weights map to font sizes and words are packed shelf-style from left to right and top to bottom, with optional rotation and color overrides.
- Alias: M104 uses `tag-cloud`, which `WordCloudChart` recognizes as the same type.

```json
{
  "type": "word-cloud",
  "title": "User feedback keywords",
  "width": 760,
  "height": 480,
  "minFontSize": 14,
  "maxFontSize": 56,
  "rotate": [0, 90],
  "words": [
    { "text": "Easy to use", "weight": 80 },
    { "text": "Stable", "weight": 65 },
    { "text": "Fast", "weight": 60 },
    { "text": "UI", "weight": 45 },
    { "text": "Docs", "weight": 35 },
    { "text": "Price", "weight": 25 }
  ]
}
```

#### M103 Word network `word-network`

- Implementation: `f_chart/src/WordNetworkChart.cj`
- Data shape: `N`
- Drawing: a word co-occurrence network where node radii map the square root of the weight, the word is centered inside its node, and `force` / `circular` layouts are supported.

```json
{
  "type": "word-network",
  "title": "Word co-occurrence",
  "width": 760,
  "height": 520,
  "layout": "force",
  "linkDistance": 100,
  "nodes": [
    { "id": "chart", "name": "Chart", "weight": 40 },
    { "id": "svg", "name": "SVG", "weight": 30 },
    { "id": "json", "name": "JSON", "weight": 28 },
    { "id": "data", "name": "Data", "weight": 36 }
  ],
  "links": [
    { "source": "chart", "target": "svg", "value": 18 },
    { "source": "chart", "target": "json", "value": 15 },
    { "source": "chart", "target": "data", "value": 22 },
    { "source": "json", "target": "data", "value": 12 }
  ]
}
```

#### M105 Gauge chart `gauge`

- Implementation: `f_chart/src/GaugeChart.cj`
- Data shape: `S`
- Drawing: threshold bands are drawn between the start and end angles, the needle points at the current value, and the center shows the value and metric name.

```json
{
  "type": "gauge",
  "title": "Task completion",
  "width": 480,
  "height": 360,
  "min": 0,
  "max": 100,
  "startAngle": -120,
  "endAngle": 120,
  "thresholds": [
    { "value": 60, "color": "#e15759" },
    { "value": 85, "color": "#edc948" },
    { "value": 100, "color": "#59a14f" }
  ],
  "series": [
    { "name": "Completion", "data": [{ "name": "Completion", "value": 72 }] }
  ]
}
```

#### M44 Calendar heatmap `calendar-heatmap`

- Implementation: `f_chart/src/CalendarHeatmapChart.cj`
- Data shape: `S`
- Drawing: date cells are laid out as week × weekday, the color is bucketed by value, months are labeled at the top and weekdays on the left.
- Alias: M106 also uses `calendar-heatmap` and reuses `CalendarHeatmapChart`.

```json
{
  "type": "calendar-heatmap",
  "title": "Commit activity",
  "width": 900,
  "height": 220,
  "startDate": "2026-01-01",
  "endDate": "2026-03-31",
  "cellSize": 14,
  "weekStart": "mon",
  "colorRange": ["#ebedf0", "#9be9a8", "#40c463", "#216e39"],
  "series": [
    {
      "name": "Commits",
      "data": [
        { "date": "2026-01-05", "value": 2 },
        { "date": "2026-01-06", "value": 5 },
        { "date": "2026-01-12", "value": 8 },
        { "date": "2026-02-03", "value": 3 },
        { "date": "2026-02-04", "value": 12 },
        { "date": "2026-03-09", "value": 6 }
      ]
    }
  ]
}
```

### 5.11 Composite charts

#### M7 Combo chart `combo`

- Implementation: `f_chart/src/ComboChart.cj`
- Data shape: `C / XY`
- Drawing: bar, line, scatter and area series are mixed in one coordinate system, with a secondary y-axis and stacking by `stack` group.

```json
{
  "type": "combo",
  "title": "Sales and growth",
  "width": 900,
  "height": 480,
  "xAxis": { "type": "category", "labels": ["Q1", "Q2", "Q3", "Q4"] },
  "yAxis": { "type": "linear", "title": "Sales (10k CNY)", "min": 0 },
  "yAxis2": { "type": "linear", "title": "Growth", "min": 0, "max": 50, "labelFormat": "{value}%" },
  "legend": { "show": true, "position": "top" },
  "series": [
    { "name": "Product A", "type": "bar", "stack": "sales", "data": [120, 150, 170, 180] },
    { "name": "Product B", "type": "bar", "stack": "sales", "data": [90, 110, 120, 130] },
    { "name": "Growth", "type": "line", "axis": "right", "smooth": true, "data": [8, 14, 18, 22] }
  ]
}
```

---

## Appendix: TUI subpackage usage

The TUI subpackage (`fountain::f_chart.tui`) renders the same JSON as the SVG version into terminal character art. All 8 classes implement `fountain::f_chart.Chart`, so they can be called, swapped or injected through the same interface.

### Minimal example

```cangjie
import fountain::f_chart.tui.*
import fountain::f_data.json.JsonValue

main(): Int64 {
    let json = """
{
  "type": "bar",
  "title": "Monthly sales",
  "width": 60,
  "height": 18,
  "xAxis": { "type": "category", "labels": ["Jan", "Feb", "Mar", "Apr"] },
  "yAxis": { "type": "linear", "min": 0 },
  "series": [ { "name": "Sales", "data": [120, 200, 150, 180] } ]
}
"""
    print(TuiBarChart().draw(JsonValue.fromStr(json).asObject()))
    0
}
```

`draw` returns an ANSI 24-bit true-color string, each row terminated by `\u{1B}[0m\n`; `print` it directly to see colored character art in the terminal. When written to a file the escape sequences are preserved; strip `\u{1B}[...m` yourself if you need plain text.

### Calling by chart type

Only the chart class changes; the JSON `type` maps one-to-one to a class (`TuiFlameChart` handles M52; chart types not yet ported to TUI stay out of scope).

```cangjie
let charts: Array<Chart> = [
    TuiBarChart(),                  // bar
    TuiGroupedBarChart(),           // grouped-bar
    TuiStackedBarChart(),           // stacked-bar
    TuiPercentStackedBarChart(),    // percent-stacked-bar
    TuiLineChart(),                 // line
    TuiScatterChart(),              // scatter
    TuiComboChart(),                // combo
    TuiFlameChart()                 // flame
]
for (chart in charts) {
    println(chart.draw(data))
}
```

#### Grouped bar chart

```json
{
  "type": "grouped-bar",
  "width": 64,
  "height": 18,
  "xAxis": { "type": "category", "labels": ["Q1", "Q2", "Q3", "Q4"] },
  "yAxis": { "type": "linear", "min": 0 },
  "series": [
    { "name": "Product A", "data": [120, 150, 170, 160] },
    { "name": "Product B", "data": [90, 110, 130, 140] }
  ]
}
```

#### Stacked bar chart

```json
{
  "type": "stacked-bar",
  "width": 60,
  "height": 18,
  "xAxis": { "type": "category", "labels": ["East", "South", "North"] },
  "yAxis": { "type": "linear", "min": 0 },
  "series": [
    { "name": "Online", "stack": "revenue", "data": [120, 90, 70] },
    { "name": "Store", "stack": "revenue", "data": [80, 70, 60] },
    { "name": "Distribution", "stack": "revenue", "data": [40, 35, 30] }
  ]
}
```

Negative values work too: positive segments stack above the 0 baseline and negative segments below it.

#### Percent-stacked bar chart

```json
{
  "type": "percent-stacked-bar",
  "width": 60,
  "height": 18,
  "xAxis": { "type": "category", "labels": ["2024", "2025", "2026"] },
  "series": [
    { "name": "Online", "data": [60, 70, 80] },
    { "name": "Store", "data": [30, 20, 15] },
    { "name": "Distribution", "data": [10, 10, 5] }
  ]
}
```

Each category is normalized to 100% across series and the y-axis ticks show percentages.

#### Line chart

A category x-axis uses a numeric array whose length must match `xAxis.labels`:

```json
{
  "type": "line",
  "width": 60,
  "height": 18,
  "xAxis": { "type": "category", "labels": ["Mon", "Tue", "Wed", "Thu", "Fri"] },
  "yAxis": { "type": "linear" },
  "series": [ { "name": "Active", "data": [120, 160, 140, null, 180] } ]
}
```

A numeric or time x-axis uses `{x, y}` points; `null` breaks the line:

```json
{
  "type": "line",
  "width": 64,
  "height": 16,
  "xAxis": { "type": "time" },
  "yAxis": { "type": "linear" },
  "series": [
    { "name": "Visits", "data": [
      { "x": "2026-01-01", "y": 120 },
      { "x": "2026-02-01", "y": 180 },
      { "x": "2026-03-01", "y": 150 }
    ] }
  ]
}
```

The time axis also accepts a numeric x (day ordinal); the numeric axis requires a numeric x.

#### Scatter chart

The scatter chart requires a `linear` or `time` x-axis and `{x, y}` data:

```json
{
  "type": "scatter",
  "width": 60,
  "height": 18,
  "xAxis": { "type": "linear", "title": "Height" },
  "yAxis": { "type": "linear", "title": "Weight" },
  "series": [
    { "name": "Samples", "data": [
      { "x": 160, "y": 55 }, { "x": 165, "y": 60 }, { "x": 170, "y": 65 },
      { "x": 175, "y": 70 }, { "x": 180, "y": 75 }
    ] }
  ]
}
```

#### Combo chart

The combo chart requires a category x-axis; `series[].type` can be `bar`, `grouped-bar`, `stacked-bar`, `percent-stacked-bar`, `line` or `scatter`, and the data is always a numeric array aligned with `xAxis.labels`:

```json
{
  "type": "combo",
  "width": 72,
  "height": 20,
  "xAxis": { "type": "category", "labels": ["Q1", "Q2", "Q3", "Q4"] },
  "yAxis": { "type": "linear", "min": 0 },
  "yAxis2": { "type": "linear", "labelFormat": "{value}%" },
  "series": [
    { "name": "Product A", "type": "bar", "stack": "sales", "data": [120, 150, 170, 180] },
    { "name": "Product B", "type": "bar", "stack": "sales", "data": [90, 110, 120, 130] },
    { "name": "Growth", "type": "line", "axis": "right", "data": [8, 14, 18, 22] },
    { "name": "Samples", "type": "scatter", "axis": "right", "data": [10, 12, 17, 21] }
  ]
}
```

Rules:

- Each `bar` series takes its own slot; `stacked-bar` series sharing the same `stack` value are stacked together; `percent-stacked-bar` merges into one percentage slot; `grouped-bar` places bars side by side inside the group.
- Series with `axis: "right"` read `yAxis2`; omitting `yAxis2` is an error.
- `line` / `scatter` are layered on top of the bar family; `smooth` is drawn as a plain polyline in the TUI.

#### Flame chart

`flame` uses the `nodes` tree; the node value determines width and the level determines the row:

```json
{
  "type": "flame",
  "title": "CPU flame graph",
  "width": 80,
  "height": 24,
  "orientation": "bottom-up",
  "colorBy": "name",
  "nodes": [
    { "id": "root", "name": "main", "parent": null, "value": 100 },
    { "id": "parse", "name": "parse", "parent": "root", "value": 40 },
    { "id": "render", "name": "render", "parent": "root", "value": 60 },
    { "id": "lex", "name": "lex", "parent": "parse", "value": 25 },
    { "id": "ast", "name": "ast", "parent": "parse", "value": 15 },
    { "id": "layout", "name": "layout", "parent": "render", "value": 35 },
    { "id": "paint", "name": "paint", "parent": "render", "value": 25 }
  ]
}
```

- `orientation`: `bottom-up` (root at the bottom) or `top-down` (root at the top).
- `colorBy`: `name` hashes the name stably into the palette; `value` maps the share of the root value onto a heat gradient.
- `frameHeight`: the maximum number of character rows per layer in the TUI; the default 18 compresses to the available height, and each layer keeps at least 1 row.
- Node blocks are filled with true-color `█` and the label color switches between black and white by background luminance; the label is omitted when the block is too narrow.

### Size and layout

- `width` / `height` are **character columns / rows**; default 80×24, minimum 20×8, and anything below the minimum raises `ChartException`.
- The height must fit the title (1–2 rows), the legend (1 row) and the x-axis plus labels (2 rows); the width must fit the y-axis ticks (including the right axis). A plot area below 1 column or 1 row is an error, so at least `60×18` is recommended.
- The SVG `padding` does not participate in character layout; the TUI reflows by terminal rows and columns.
- With `legend.position: "bottom"` the legend occupies the bottom row; `show: false` hides it.
- `palette`, `textColor`, `axisColor` and `gridColor` in `theme` take effect; `background` does not apply (the terminal background belongs to the host).
- CJK characters take 2 columns; over-wide labels are truncated with `…`.

### Error handling

As with the SVG version, every structural or numeric problem raises `ChartException` and never returns an empty string or a half-built chart:

```cangjie
import fountain::f_chart.ChartException

try {
    print(TuiScatterChart().draw(JsonValue.fromStr(json).asObject()))
} catch (error: ChartException) {
    eprintln("Invalid chart configuration: ${error.message}")
}
```

Common errors: `scatter` with a category x-axis, `combo` without a category x-axis, data length not matching the labels, `axis: "right"` without `yAxis2`, and a canvas below 20×8.

### Samples and regression

The 8 cases in `src/tui/TuiGallery_test.cj` write the character art of M1–M7 and M52 into `charts/`:

- Naming: `M<number>-<type>.tui.txt`.
- All samples keep ANSI 24-bit true color, so `cat` shows the series colors.

| File | Class |
|---|---|
| `M001-bar.tui.txt` | `TuiBarChart` |
| `M002-grouped-bar.tui.txt` | `TuiGroupedBarChart` |
| `M003-stacked-bar.tui.txt` | `TuiStackedBarChart` |
| `M004-percent-stacked-bar.tui.txt` | `TuiPercentStackedBarChart` |
| `M005-line.tui.txt` | `TuiLineChart` |
| `M006-scatter.tui.txt` | `TuiScatterChart` |
| `M007-combo.tui.txt` | `TuiComboChart` |
| `M052-flame.tui.txt` | `TuiFlameChart` |

The flame-chart visual test also emits 4 variants: `M052-flame-bottom-up.tui.txt`, `M052-flame-top-down.tui.txt`, `M052-flame-value.tui.txt`, `M052-flame-frame-height.tui.txt`.

Grouped bars alternate through the `theme.palette` (or `series[].color`) colors per series; the same holds for every segment / bar of stacked bars, percent-stacked bars and the bar series inside combo charts. Bars also cycle `█ ▓ ▒ ░` per series, so adjacent series stay distinguishable in ANSI output and in colorless text.

Regenerate:

```bash
cd f_chart
cjpm test --skip-build
```

These files are plain text (ANSI stripped) and can be viewed with `cat` or used for visual regression.

---

## Other public API

The declarations below are not expanded above; they are grouped by module level and by type (members declared in `extend` blocks are listed under the extended type). See the corresponding files under `src/` for the full semantics.

- Module level: `ChartErrorKind` (enum)











