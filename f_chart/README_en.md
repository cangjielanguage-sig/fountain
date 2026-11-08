# f_chart

**JSON-driven SVG charts**: callers describe data and styling in JSON; at runtime `f_svg` turns it into SVG. Every chart implements the same `Chart` interface, one chart per source file, imported on demand.

> See [`doc/chart-json-spec.md`](doc/chart-json-spec.md) for the field specification and a complete JSON example of every chart.
> See [`doc/f_chart模块设计.md`](doc/f_chart模块设计.md) for the design and milestones.

## Dependencies

```
f_chart
├── f_svg      SVG 1.1 document generation
├── f_data     JSON parsing (JsonObject / JsonValue)
└── f_base     BaseException
```

## Install

The module ships with the fountain repository; its version tracks the repository (currently `1.3.17`):

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
- Invalid input raises `ChartException` with `kind` set to `InvalidJson` / `MissingField` / `InvalidValue` / `UnsupportedChart`.

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
| M5 | Line chart `LineChart` (category / XY / time, smooth, symbols) | Done |
| M6 | Scatter chart `ScatterChart` (numeric / time axes) | Done |
| M7 | Combo chart `ComboChart` (bar/line/scatter, dual axes) | Done |
| M8 | Gantt chart `GanttChart` (timeline, progress, dependencies) | Done |
| M2–M106 | Chart implementations (one OpenSpec change + TDD per chart) | In progress |

## Error semantics

`draw` returns a string only on success; every structural or numeric problem is raised as `ChartException`. The `path` field looks like `series[0].data[2]` and is prefixed to the message when non-empty.
