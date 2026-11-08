# f_chart

**JSON 驱动的 SVG 图表**模块：调用方用一份 JSON 描述数据与样式，运行期由 `f_svg` 生成 SVG；所有图实现同一个 `Chart` 接口，一个图一个源文件，按需导入。

> 字段规范与每种图的完整 JSON 示例见 [`doc/chart-json-spec.md`](doc/chart-json-spec.md)。
> 设计与里程碑见 [`doc/f_chart模块设计.md`](doc/f_chart模块设计.md)。

## 依赖

```
f_chart
├── f_svg      SVG 1.1 文档生成
├── f_data     JSON 解析（JsonObject / JsonValue）
└── f_base     BaseException
```

## 安装

模块随 fountain 仓库发布，版本与仓库一致（当前 `1.3.17`）：

```toml
[dependencies]
  "fountain::f_chart" = { path = "../fountain/f_chart" }
```

## M0：Chart 接口

```cangjie
package fountain::f_chart

import fountain::f_data.json.JsonObject

public interface Chart {
    func draw(data: JsonObject): String
}
```

- `data` 是一份图表 JSON，`type` 字段判别图类型。
- 返回值是完整的 SVG 文档字符串。
- 输入不合法时抛 `ChartException`，`kind` 区分 `InvalidJson` / `MissingField` / `InvalidValue` / `UnsupportedChart`。

### 最小用法

```cangjie
import fountain::f_chart.*
import fountain::f_data.json.JsonValue

let data = JsonValue.fromStr("""
{
  "type": "bar",
  "title": "月度销售额",
  "xAxis": { "type": "category", "labels": ["1月", "2月", "3月"] },
  "yAxis": { "type": "linear", "min": 0 },
  "series": [{ "name": "销售额", "data": [120, 200, 150] }]
}
""").asObject()

let chart: Chart = BarChart()   // M1 起提供
let svg = chart.draw(data)
```

## 状态

| 里程碑 | 能力 | 状态 |
|---|---|---|
| M0 | `Chart` 接口、`ChartException`、JSON 规范文档 | 已完成 |
| M1 | 柱状图 `BarChart` + 公共渲染基础设施 | 已完成 |
| M2 | 分组柱状图 `GroupedBarChart` | 已完成 |
| M3 | 堆叠柱状图 `StackedBarChart` | 已完成 |
| M4 | 百分比堆叠柱状图 `PercentStackedBarChart` | 已完成 |
| M5 | 折线图 `LineChart`（类目 / XY / 时间轴、平滑、符号） | 已完成 |
| M6 | 散点图 `ScatterChart`（数值 / 时间双轴） | 已完成 |
| M7 | 组合图 `ComboChart`（柱/线/点任意叠加、双轴） | 已完成 |
| M8 | 甘特图 `GanttChart`（时间轴、进度、依赖） | 已完成 |
| M9 | 流程图 `Flowchart`（分层布局、六种形状、带箭头边） | 已完成 |
| M10 | 时序图 `SequenceChart`（参与者、生命线、消息、返回虚线） | 已完成 |
| M2–M106 | 各图实现（每图一个 OpenSpec 变更 + TDD） | 按里程碑推进 |

## 错误语义

`draw` 只在成功时返回字符串；任何结构或数值问题都以 `ChartException` 抛出，不会返回空串或半成品 SVG。`path` 字段形如 `series[0].data[2]`，非空时拼进异常消息。
