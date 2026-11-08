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
| M11 | 条形图 `HorizontalBarChart` | 已完成 |
| M12 | 点图 / 克利夫兰点图 `DotChart` | 已完成 |
| M13 | 雷达图 `RadarChart`（多指标、多系列多边形） | 已完成 |
| M14 | 面积图 `AreaChart`（填充透明度、平滑、缺测分段） | 已完成 |
| M15 | 堆叠面积图 `StackedAreaChart`（按 stack 分组累加） | 已完成 |
| M16 | 瀑布图 `WaterfallChart`（增减累计、连接器、语义色） | 已完成 |
| M17 | 直方图 `HistogramChart`（等宽分箱、频数柱） | 已完成 |
| M18 | 核密度图 `DensityChart`（高斯核、Silverman 带宽、填充） | 已完成 |
| M19 | 箱线图 `BoxPlotChart`（五数概括、须、异常值） | 已完成 |
| M20 | 小提琴图 `ViolinChart`（镜像密度、内嵌箱体） | 已完成 |
| M21 | 蜂群图 / 抖动图 `SwarmChart`（确定性抖动） | 已完成 |
| M22 | 茎叶图 `StemLeafChart`（文本分组、叶钳制） | 已完成 |
| M23 | QQ 图 `QQChart`（理论分位、最小二乘参考线） | 已完成 |
| M24 | 山脊图 `RidgeChart`（逐行错位密度、重叠系数） | 已完成 |
| M25 | 二维直方图 `Histogram2DChart`（方形/六边形分箱） | 已完成 |
| M26 | 气泡图 `BubbleChart`（半径映射、标签） | 已完成 |
| M27 | 相关矩阵图 `CorrelationMatrixChart`（三色分段、数值标注） | 已完成 |
| M28 | 平行坐标图 `ParallelCoordinatesChart`（多维归一化折线） | 已完成 |
| M29 | 等高线图 `ContourChart`（网格分层、等值边界） | 已完成 |
| M30 | 散点矩阵图 `ScatterMatrixChart`（两两散点、对角标签） | 已完成 |
| M31 | 饼图 `PieChart`（扇区、百分比标签） | 已完成 |
| M32 | 环形图 `DonutChart`（内孔、中心文本） | 已完成 |
| M33 | 马赛克图 `MosaicChart`（列宽、列内堆叠） | 已完成 |
| M34 | 矩形树图 `TreemapChart`（层级面积、squarify 布局） | 已完成 |
| M35 | 漏斗图 `FunnelChart`（阶段条、转化率） | 已完成 |
| M36 | 桑基图 `SankeyChart`（分层节点、流量带） | 已完成 |
| M37 | 帕累托图 `ParetoChart`（降序柱、累计折线） | 已完成 |
| M38 | 控制图 `ControlChart`（中心线、上下控制限、越限点） | 已完成 |
| M39 | 误差线图 `ErrorBarChart`（中心值、上下界、端帽） | 已完成 |
| M40 | 残差图 `ResidualChart`（拟合值对残差、零参考线） | 已完成 |
| M41 | 杠杆图 `InfluenceChart`（Cook 距离映射点大小、标签） | 已完成 |
| M42 | 概率图 `ProbabilityChart`（三种分布、最小二乘参考线） | 已完成 |
| M43 | 热力图 `HeatmapChart`（矩阵单元格、三色插值、数值标签） | 已完成 |
| M44 | 日历热力图 `CalendarHeatmapChart`（周网格、日期范围、颜色分档） | 已完成 |
| M45 | 箱线散点图 `BoxScatterChart`（箱体、须线、抖动原始点） | 已完成 |
| M46 | 小提琴箱线图 `ViolinBoxChart`（密度轮廓、箱体、异常值） | 已完成 |
| M47 | ROC 曲线 `RocChart`（曲线、对角线、AUC 标注） | 已完成 |
| M48 | PR 曲线 `PrChart`（曲线、精确率基线、AP 标注） | 已完成 |
| M49 | 生存曲线 `SurvivalChart`（阶梯线、删失标记、置信带） | 已完成 |
| M50 | 森林图 `ForestChart`（置信区间、无效线、权重方块、对数轴） | 已完成 |
| M51–M106 | 各图实现（每图一个 OpenSpec 变更 + TDD） | 按里程碑推进 |

## 错误语义

`draw` 只在成功时返回字符串；任何结构或数值问题都以 `ChartException` 抛出，不会返回空串或半成品 SVG。`path` 字段形如 `series[0].data[2]`，非空时拼进异常消息。
