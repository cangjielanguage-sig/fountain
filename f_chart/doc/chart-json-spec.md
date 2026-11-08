# f_chart JSON 图表规范

本文件是所有图表的**唯一字段真相**。每种图给出字段说明与一份可直接解析的 JSON 示例；实现与测试必须以本文件为准。

- 版本：1.0（随 M0 建立）
- 模块：`fountain::f_chart`
- 接口：`Chart.draw(data: JsonObject): String`
- 输出：完整 SVG 文档字符串

## 1. 约定

1. 所有图共用第 2 节的「通用字段」；第 5 节只列图专属字段。
2. 同一语义只用一个字段名：类目标签用 `xAxis.labels`，系列数据用 `series[].data`，节点关系用 `nodes` / `links`。
3. 数值缺省值：`null` 表示缺失值，折线断开；柱状图跳过。
4. 颜色使用 CSS 颜色字符串（`#rrggbb`、`rgb()`、颜色名）。
5. 尺寸单位均为 SVG 用户单位（默认 px）。
6. 时间使用 ISO-8601 字符串（`2026-01-31` 或 `2026-01-31T10:00:00`）或毫秒时间戳。
7. 每种图的 `type` 必须与第 4 节索引一致；具体实现收到不匹配的 `type` 抛 `UnsupportedChart`。
8. JSON 示例中的省略号不合法；示例均为完整可解析文档。

## 2. 通用字段

| 字段 | 类型 | 必填 | 默认 | 说明 |
|---|---|---|---|---|
| `type` | string | 是 | — | 图类型判别符 |
| `title` | string \| object | 否 | 无 | 字符串等价于 `{"text": ...}` |
| `width` | number | 否 | 800 | 画布宽 |
| `height` | number | 否 | 480 | 画布高 |
| `padding` | number \| object | 否 | 24 | 数字为四边相同；对象为 `{top,right,bottom,left}` |
| `theme` | object | 否 | 浅色主题 | 见 2.1 |
| `legend` | object | 否 | `{"show":true,"position":"top"}` | 见 2.2 |
| `xAxis` | object | 视图而定 | 无 | 见 2.3 |
| `yAxis` | object | 视图而定 | 无 | 见 2.3 |
| `yAxis2` | object | 否 | 无 | 组合图右侧数值轴 |
| `series` | array | 视图而定 | `[]` | 见 2.4 |
| `annotations` | array | 否 | `[]` | 见 2.5 |

### 2.1 `title`

| 字段 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `text` | string | `""` | 主标题 |
| `subtext` | string | `""` | 副标题 |
| `align` | string | `center` | `left` / `center` / `right` |
| `fontSize` | number | 18 | 主标题字号 |
| `color` | string | 主题文字色 | 标题颜色 |

### 2.2 `theme`

| 字段 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `background` | string | `#ffffff` | 画布背景；`none` 为透明 |
| `palette` | string[] | 内置 10 色 | 系列默认配色，循环取用 |
| `fontFamily` | string | `sans-serif` | 字体族 |
| `fontSize` | number | 12 | 正文字号 |
| `textColor` | string | `#333333` | 文字颜色 |
| `axisColor` | string | `#999999` | 轴线与刻度颜色 |
| `gridColor` | string | `#e5e5e5` | 网格颜色 |
| `legendTextColor` | string | `textColor` | 图例文字颜色 |

内置调色板：

```json
["#4e79a7", "#f28e2b", "#e15759", "#76b7b2", "#59a14f", "#edc948", "#b07aa1", "#ff9da7", "#9c755f", "#bab0ac"]
```

### 2.3 `legend`

| 字段 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `show` | bool | `true` | 是否显示；单系列且无 `name` 时自动隐藏 |
| `position` | string | `top` | `top` / `bottom` / `left` / `right` |
| `orient` | string | `horizontal` | `horizontal` / `vertical` |
| `itemGap` | number | 16 | 图例项间距 |
| `markerSize` | number | 10 | 色块边长 |

### 2.4 `xAxis` / `yAxis`

| 字段 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `type` | string | `category`（x）/ `linear`（y） | `category` / `linear` / `log` / `time` |
| `title` | string | `""` | 轴标题 |
| `labels` | string[] | `[]` | 类目轴标签；也用于热力矩阵的列名 |
| `min` | number \| null | `null` | 数值轴最小值；`null` 按数据自适应 |
| `max` | number \| null | `null` | 数值轴最大值 |
| `tickCount` | number | 5 | 期望刻度数 |
| `grid` | bool | `true`（y）/ `false`（x） | 是否画网格 |
| `labelRotate` | number | 0 | 标签旋转角度（度） |
| `labelFormat` | string | `{value}` | 数值格式，`{value}` 为占位符 |
| `logBase` | number | 10 | 对数轴底数 |
| `values` | number[] | `[]` | 显式刻度值；非空时忽略 `tickCount` |

### 2.5 `series`

| 字段 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `name` | string | `""` | 系列名，用于图例与 tooltip 语义 |
| `type` | string | 图的 `type` | 组合图必须显式给出 |
| `data` | array | `[]` | 数据，形状见第 3 节 |
| `color` | string | 调色板 | 系列颜色 |
| `stack` | string | `""` | 同组堆叠；空串表示不堆叠 |
| `axis` | string | `left` | `left` / `right`，配合 `yAxis2` |
| `opacity` | number | 1 | 0–1 |
| `barWidth` | number | 自动 | 柱宽（像素） |
| `smooth` | bool | false | 折线/面积是否平滑 |
| `symbol` | string | `circle` | `circle` / `square` / `diamond` / `triangle` / `none` |
| `symbolSize` | number | 6 | 点大小 |
| `areaStyle` | object | 无 | `{"opacity":0.2}` 面积填充 |
| `label` | object | 无 | `{"show":true,"position":"top","format":"{value}"}` |

### 2.6 `annotations`

| 字段 | 类型 | 说明 |
|---|---|---|
| `type` | string | `text` / `line` / `band` / `point` |
| `x` / `y` | number \| string | 数据坐标；类目轴可写标签 |
| `x2` / `y2` | number \| string | 参考线/参考带终点 |
| `text` | string | 文本内容 |
| `color` | string | 颜色 |
| `dash` | string | 虚线样式，如 `4 4` |

## 3. 数据形状

| 代号 | 形状 | 说明 |
|---|---|---|
| `C` | `number[]` | 类目数值；与 `xAxis.labels` 等长 |
| `XY` | `{x:number,y:number,...}[]` | 连续坐标点 |
| `M` | `number[][]` | 矩阵；行对应 `yAxis.labels`，列对应 `xAxis.labels` |
| `N` | `nodes[] + links[]` | 关系图；链接 `{source,target,value}` |
| `H` | `nodes[]`（含 `parent`） | 层级图；根节点 `parent` 为 `null` |
| `S` | 专用 | 甘特 `tasks`、时序 `participants/messages`、地图 `regions` 等 |

## 4. 图类型索引

| M | `type` | 实现文件 | 数据 | 备注 |
|---|---|---|---|---|
| M1 | `bar` | `BarChart.cj` | C | 柱状图 |
| M2 | `grouped-bar` | `GroupedBarChart.cj` | C | 分组柱状图 |
| M3 | `stacked-bar` | `StackedBarChart.cj` | C | 堆叠柱状图 |
| M4 | `percent-stacked-bar` | `PercentStackedBarChart.cj` | C | 百分比堆叠柱状图 |
| M5 | `line` | `LineChart.cj` | C / XY | 折线图 |
| M6 | `scatter` | `ScatterChart.cj` | XY | 散点图 |
| M7 | `combo` | `ComboChart.cj` | C / XY | 六图任意组合 |
| M8 | `gantt` | `GanttChart.cj` | S | 甘特图 |
| M9 | `flowchart` | `Flowchart.cj` | N | 流程图 |
| M10 | `sequence` | `SequenceChart.cj` | S | 时序图 |
| M11 | `horizontal-bar` | `HorizontalBarChart.cj` | C | 条形图 |
| M12 | `dot` | `DotChart.cj` | C | 点图 / 克利夫兰点图 |
| M13 | `radar` | `RadarChart.cj` | C | 雷达图 |
| M14 | `area` | `AreaChart.cj` | C | 面积图 |
| M15 | `stacked-area` | `StackedAreaChart.cj` | C | 堆叠面积图 |
| M16 | `waterfall` | `WaterfallChart.cj` | S | 瀑布图 |
| M17 | `histogram` | `HistogramChart.cj` | C | 直方图 |
| M18 | `density` | `DensityChart.cj` | C | 核密度图 |
| M19 | `boxplot` | `BoxPlotChart.cj` | S | 箱线图 |
| M20 | `violin` | `ViolinChart.cj` | C | 小提琴图 |
| M21 | `swarm` | `SwarmChart.cj` | C | 蜂群图 / 抖动图 |
| M22 | `stem-leaf` | `StemLeafChart.cj` | C | 茎叶图 |
| M23 | `qq` | `QQChart.cj` | C | QQ 图 |
| M24 | `ridge` | `RidgeChart.cj` | C | 山脊图 |
| M25 | `2d-histogram` | `Histogram2DChart.cj` | XY | 二维直方图 / 六边形分箱 |
| M26 | `bubble` | `BubbleChart.cj` | XY | 气泡图 |
| M27 | `correlation-matrix` | `CorrelationMatrixChart.cj` | M | 相关矩阵图 |
| M28 | `parallel-coordinates` | `ParallelCoordinatesChart.cj` | S | 平行坐标图 |
| M29 | `contour` | `ContourChart.cj` | XY | 等高线图 |
| M30 | `scatter-matrix` | `ScatterMatrixChart.cj` | C | 散点矩阵图 |
| M31 | `pie` | `PieChart.cj` | S | 饼图 |
| M32 | `donut` | `DonutChart.cj` | S | 环形图 |
| M33 | `mosaic` | `MosaicChart.cj` | M | 马赛克图 |
| M34 | `treemap` | `TreemapChart.cj` | H | 矩形树图 |
| M35 | `funnel` | `FunnelChart.cj` | S | 漏斗图 |
| M36 | `sankey` | `SankeyChart.cj` | N | 桑基图 |
| M37 | `pareto` | `ParetoChart.cj` | C | 帕累托图 |
| M38 | `control` | `ControlChart.cj` | C | 控制图 |
| M39 | `error-bar` | `ErrorBarChart.cj` | XY | 误差线图 |
| M40 | `residual` | `ResidualChart.cj` | XY | 残差图 |
| M41 | `influence` | `InfluenceChart.cj` | XY | 杠杆图 / 影响图 |
| M42 | `probability` | `ProbabilityChart.cj` | C | 概率图 |
| M43 | `heatmap` | `HeatmapChart.cj` | M | 热力图 |
| M44 | `calendar-heatmap` | `CalendarHeatmapChart.cj` | S | 日历热力图 |
| M45 | `box-scatter` | `BoxScatterChart.cj` | C | 箱线+散点 |
| M46 | `violin-box` | `ViolinBoxChart.cj` | C | 小提琴+箱线 |
| M47 | `roc` | `RocChart.cj` | XY | ROC 曲线 |
| M48 | `pr` | `PrChart.cj` | XY | PR 曲线 |
| M49 | `survival` | `SurvivalChart.cj` | S | Kaplan-Meier |
| M50 | `forest` | `ForestChart.cj` | S | 森林图 |
| M51 | `nomogram` | `NomogramChart.cj` | S | 列线图 |
| M52 | `flame` | `FlameChart.cj` | H | 火焰图 |
| M53 | `icicle` | `IcicleChart.cj` | H | 冰柱图 |
| M54 | `differential-flame` | `DifferentialFlameChart.cj` | H | 差分火焰图 |
| M55 | `offline-flame` | `OfflineFlameChart.cj` | H | 离线火焰图 |
| M56 | `heat-flame` | `HeatFlameChart.cj` | H | 热火焰图 |
| M57 | `choropleth` | `ChoroplethChart.cj` | S | 分级统计地图 |
| M58 | `dot-density-map` | `DotDensityMapChart.cj` | S | 点密度地图 |
| M59 | `heat-map` | `HeatMap.cj`（公开类型 `HeatMapChart`） | S | 热力地图 |
| M60 | `flow-map` | `FlowMapChart.cj` | S | 流向地图 |
| M61 | `cartogram` | `CartogramChart.cj` | S | 变形地图 |
| M62 | `node-link` | `NodeLinkChart.cj` | N | 节点-链接图 |
| M63 | `arc` | `ArcChart.cj` | N | 弧线图 |
| M64 | `chord` | `ChordChart.cj` | N | 和弦图 |
| M65 | `hive` | `HiveChart.cj` | N | 蜂巢图 |
| M66 | `alluvial` | `AlluvialChart.cj` | N | 冲积图 |
| M67 | `sankey` | `SankeyChart.cj` | N | 同 M36，别名 |
| M68 | `network-heatmap` | `NetworkHeatmapChart.cj` | M | 网络热力图 |
| M69 | `sunburst` | `SunburstChart.cj` | H | 旭日图 |
| M70 | `circle-packing` | `CirclePackingChart.cj` | H | 圆堆积图 |
| M71 | `org-chart` | `OrgChart.cj` | H | 组织图 / 树状图 |
| M72 | `rose` | `RoseChart.cj` | S | 南丁格尔玫瑰图 |
| M73 | `waffle` | `WaffleChart.cj` | S | 华夫图 |
| M74 | `pictogram` | `PictogramChart.cj` | S | 象形图 |
| M75 | `percent-bar` | `PercentBarChart.cj` | C | 百分比条 |
| M76 | `bullet` | `BulletChart.cj` | S | 子弹图 |
| M77 | `dumbbell` | `DumbbellChart.cj` | S | 哑铃图 |
| M78 | `slope` | `SlopeChart.cj` | S | 斜率图 |
| M79 | `lollipop` | `LollipopChart.cj` | C | 棒棒糖图 |
| M80 | `paired-line` | `PairedLineChart.cj` | S | 配对连线图 |
| M81 | `timeline` | `TimelineChart.cj` | S | 时间线图 |
| M82 | `streamgraph` | `StreamgraphChart.cj` | C | 主题河流图 |
| M83 | `candlestick` | `CandlestickChart.cj` | S | 蜡烛图 / K 线图 |
| M84 | `spiral` | `SpiralChart.cj` | S | 螺旋图 |
| M85 | `swimlane` | `SwimlaneChart.cj` | S | 泳道图 |
| M86 | `funnel` | `FunnelChart.cj` | S | 同 M35，别名 |
| M87 | `waterfall` | `WaterfallChart.cj` | S | 同 M16，别名 |
| M88 | `raincloud` | `RaincloudChart.cj` | C | 雨云图 |
| M89 | `dot-strip` | `DotStripChart.cj` | C | 豆图 |
| M90 | `ecdf` | `EcdfChart.cj` | C | 累积频率图 |
| M91 | `bland-altman` | `BlandAltmanChart.cj` | XY | Bland-Altman 图 |
| M92 | `volcano` | `VolcanoChart.cj` | XY | 火山图 |
| M93 | `manhattan` | `ManhattanChart.cj` | XY | 曼哈顿图 |
| M93b | `confusion-matrix` | `ConfusionMatrixChart.cj` | M | 混淆矩阵 |
| M94 | `lift` | `LiftChart.cj` | XY | 提升图 / Lift 图 |
| M95 | `gain` | `GainChart.cj` | XY | 增益图 |
| M96 | `calibration` | `CalibrationChart.cj` | XY | 校准曲线 |
| M97 | `learning-curve` | `LearningCurveChart.cj` | XY | 学习曲线 |
| M98 | `lasso-path` | `LassoPathChart.cj` | S | LASSO 路径图 |
| M99 | `decision-tree` | `DecisionTreeChart.cj` | N | 决策树图 |
| M100 | `pdp` | `PdpChart.cj` | XY | 部分依赖图 |
| M101 | `shap` | `ShapChart.cj` | S | SHAP 图 |
| M102 | `word-cloud` | `WordCloudChart.cj` | S | 词云 |
| M103 | `word-network` | `WordNetworkChart.cj` | N | 词网络图 |
| M104 | `tag-cloud` | `WordCloudChart.cj` | S | 同 M102，别名 |
| M105 | `gauge` | `GaugeChart.cj` | S | 仪表盘 |
| M106 | `calendar-heatmap` | `CalendarHeatmapChart.cj` | S | 同 M44，别名 |

## 5. 各图规范

### 5.1 比较类

#### M1 柱状图 `bar`

专属字段：`series[].barWidth`、`series[].label`。

```json
{
  "type": "bar",
  "title": "月度销售额",
  "width": 800,
  "height": 480,
  "xAxis": { "type": "category", "title": "月份", "labels": ["1月", "2月", "3月", "4月", "5月", "6月"] },
  "yAxis": { "type": "linear", "title": "销售额（万元）", "min": 0, "grid": true },
  "legend": { "show": false },
  "series": [
    { "name": "销售额", "type": "bar", "data": [120, 200, 150, 180, 240, 210], "barWidth": 32 }
  ]
}
```

#### M2 分组柱状图 `grouped-bar`

同一 `xAxis.labels` 下并列多个系列；`series[].type` 可省略。

```json
{
  "type": "grouped-bar",
  "title": "各季度产品销售额",
  "xAxis": { "type": "category", "labels": ["Q1", "Q2", "Q3", "Q4"] },
  "yAxis": { "type": "linear", "title": "万元", "min": 0 },
  "legend": { "show": true, "position": "top" },
  "series": [
    { "name": "产品 A", "data": [120, 150, 170, 160] },
    { "name": "产品 B", "data": [90, 110, 130, 140] },
    { "name": "产品 C", "data": [60, 70, 80, 95] }
  ]
}
```

#### M3 堆叠柱状图 `stacked-bar`

`series[].stack` 相同即堆叠；同一类目下各段从下到上按系列顺序排列。

```json
{
  "type": "stacked-bar",
  "title": "各区收入构成",
  "xAxis": { "type": "category", "labels": ["华东", "华南", "华北", "西部"] },
  "yAxis": { "type": "linear", "title": "万元", "min": 0 },
  "series": [
    { "name": "线上", "stack": "revenue", "data": [120, 90, 70, 50] },
    { "name": "门店", "stack": "revenue", "data": [80, 70, 60, 40] },
    { "name": "分销", "stack": "revenue", "data": [40, 35, 30, 25] }
  ]
}
```

#### M4 百分比堆叠柱状图 `percent-stacked-bar`

与 `stacked-bar` 相同的数据形状；实现把每个类目归一化到 100%，`yAxis.max` 固定为 100。

```json
{
  "type": "percent-stacked-bar",
  "title": "各渠道占比",
  "xAxis": { "type": "category", "labels": ["2024", "2025", "2026"] },
  "yAxis": { "type": "linear", "title": "占比", "min": 0, "max": 100, "labelFormat": "{value}%" },
  "series": [
    { "name": "线上", "stack": "share", "data": [45, 52, 60] },
    { "name": "门店", "stack": "share", "data": [35, 30, 25] },
    { "name": "分销", "stack": "share", "data": [20, 18, 15] }
  ]
}
```

#### M11 条形图 `horizontal-bar`

类目在 `yAxis.labels`，数值在 `xAxis`。

```json
{
  "type": "horizontal-bar",
  "title": "各城市销售额",
  "width": 720,
  "height": 420,
  "xAxis": { "type": "linear", "title": "万元", "min": 0, "grid": true },
  "yAxis": { "type": "category", "labels": ["上海", "北京", "深圳", "广州", "杭州"] },
  "legend": { "show": false },
  "series": [
    { "name": "销售额", "data": [320, 290, 260, 210, 180], "barWidth": 24 }
  ]
}
```

#### M12 点图 / 克利夫兰点图 `dot`

用点代替条形，适合类别多或标签长的场景。

```json
{
  "type": "dot",
  "title": "各科室满意度",
  "xAxis": { "type": "linear", "title": "满意度", "min": 0, "max": 100 },
  "yAxis": { "type": "category", "labels": ["内科", "外科", "儿科", "妇产科", "急诊"] },
  "legend": { "show": false },
  "series": [
    { "name": "满意度", "data": [88, 82, 91, 86, 79], "symbolSize": 10 }
  ]
}
```

#### M13 雷达图 `radar`

专属字段：`indicators: [{name, max}]`。`series[].data` 长度必须等于指标数。

```json
{
  "type": "radar",
  "title": "选手能力评估",
  "width": 600,
  "height": 600,
  "indicators": [
    { "name": "速度", "max": 100 },
    { "name": "力量", "max": 100 },
    { "name": "技巧", "max": 100 },
    { "name": "耐力", "max": 100 },
    { "name": "意识", "max": 100 }
  ],
  "series": [
    { "name": "选手 A", "data": [85, 70, 90, 75, 88] },
    { "name": "选手 B", "data": [70, 88, 65, 82, 72] }
  ]
}
```

#### M72 南丁格尔玫瑰图 `rose`

专属字段：`roseType`（`radius` / `area`，默认 `radius`）。

```json
{
  "type": "rose",
  "title": "各品类销量占比",
  "width": 600,
  "height": 600,
  "roseType": "radius",
  "series": [
    {
      "name": "销量",
      "data": [
        { "name": "女装", "value": 40 },
        { "name": "男装", "value": 30 },
        { "name": "鞋靴", "value": 18 },
        { "name": "箱包", "value": 12 }
      ]
    }
  ]
}
```

#### M73 华夫图 `waffle`

专属字段：`cells`（总格数，默认 100）、`columns`（默认 10）。

```json
{
  "type": "waffle",
  "title": "预算分配",
  "width": 520,
  "height": 520,
  "cells": 100,
  "columns": 10,
  "series": [
    {
      "name": "预算",
      "data": [
        { "name": "研发", "value": 42 },
        { "name": "市场", "value": 28 },
        { "name": "运营", "value": 18 },
        { "name": "其他", "value": 12 }
      ]
    }
  ]
}
```

#### M74 象形图 `pictogram`

专属字段：`icon`（`person` / `circle` / `square`，或 SVG path 字符串）、`unit`（一个图标代表的数值）、`columns`。

```json
{
  "type": "pictogram",
  "title": "团队人数",
  "width": 720,
  "height": 360,
  "icon": "person",
  "unit": 10,
  "columns": 10,
  "series": [
    { "name": "研发", "data": [{ "name": "研发", "value": 120 }] },
    { "name": "市场", "data": [{ "name": "市场", "value": 60 }] }
  ]
}
```

#### M75 百分比条 `percent-bar`

每个类目一根 100% 横条，系列按顺序堆叠。

```json
{
  "type": "percent-bar",
  "title": "各季度收入构成",
  "width": 720,
  "height": 360,
  "xAxis": { "type": "category", "labels": ["Q1", "Q2", "Q3", "Q4"] },
  "series": [
    { "name": "产品 A", "data": [30, 40, 35, 50] },
    { "name": "产品 B", "data": [50, 40, 45, 30] },
    { "name": "产品 C", "data": [20, 20, 20, 20] }
  ]
}
```

#### M76 子弹图 `bullet`

专属字段：`series[0].data[]` 为 `{name, value, target, ranges}`；`ranges` 是从低到高的区间上界。

```json
{
  "type": "bullet",
  "title": "季度目标完成情况",
  "width": 720,
  "height": 360,
  "xAxis": { "type": "linear", "min": 0, "max": 100, "title": "完成率" },
  "yAxis": { "type": "category", "labels": ["营收", "回款", "新客"] },
  "series": [
    {
      "name": "完成率",
      "data": [
        { "name": "营收", "value": 72, "target": 80, "ranges": [50, 75, 100] },
        { "name": "回款", "value": 88, "target": 85, "ranges": [60, 80, 100] },
        { "name": "新客", "value": 45, "target": 70, "ranges": [40, 70, 100] }
      ]
    }
  ]
}
```

#### M77 哑铃图 `dumbbell`

专属字段：`series[0].data[]` 为 `{name, low, high}`。

```json
{
  "type": "dumbbell",
  "title": "两年得分变化",
  "xAxis": { "type": "linear", "title": "得分", "min": 0, "max": 100 },
  "yAxis": { "type": "category", "labels": ["A 团队", "B 团队", "C 团队"] },
  "series": [
    {
      "name": "2025 → 2026",
      "data": [
        { "name": "A 团队", "low": 60, "high": 82 },
        { "name": "B 团队", "low": 75, "high": 68 },
        { "name": "C 团队", "low": 52, "high": 74 }
      ]
    }
  ]
}
```

#### M78 斜率图 `slope`

两个时间点，每个系列一条斜率线；`xAxis.labels` 固定两个值。

```json
{
  "type": "slope",
  "title": "排名变化",
  "xAxis": { "type": "category", "labels": ["2025", "2026"] },
  "yAxis": { "type": "linear", "title": "得分", "min": 0, "max": 100 },
  "series": [
    { "name": "A 团队", "data": [60, 82] },
    { "name": "B 团队", "data": [75, 68] },
    { "name": "C 团队", "data": [52, 74] }
  ]
}
```

#### M79 棒棒糖图 `lollipop`

与柱状图同数据形状；用细线 + 端点圆呈现。

```json
{
  "type": "lollipop",
  "title": "各渠道转化率",
  "xAxis": { "type": "category", "labels": ["搜索", "社交", "邮件", "直访", "联盟"] },
  "yAxis": { "type": "linear", "title": "转化率", "min": 0, "labelFormat": "{value}%" },
  "legend": { "show": false },
  "series": [
    { "name": "转化率", "data": [4.2, 2.8, 3.6, 5.1, 1.9], "symbolSize": 8 }
  ]
}
```

#### M80 配对连线图 `paired-line`

专属字段：`series[0].data[]` 为 `{name, before, after}`；每对一条连线。

```json
{
  "type": "paired-line",
  "title": "干预前后指标",
  "xAxis": { "type": "category", "labels": ["干预前", "干预后"] },
  "yAxis": { "type": "linear", "title": "指标值", "min": 0, "max": 100 },
  "series": [
    {
      "name": "受试者",
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

### 5.2 趋势类

#### M5 折线图 `line`

类目数据用 `C`；连续数据用 `XY`。专属字段：`series[].smooth`、`series[].symbol`、`series[].symbolSize`。

```json
{
  "type": "line",
  "title": "月活跃用户",
  "xAxis": { "type": "category", "labels": ["1月", "2月", "3月", "4月", "5月", "6月"] },
  "yAxis": { "type": "linear", "title": "万人", "min": 0 },
  "series": [
    { "name": "App", "data": [120, 132, 145, 160, 178, 190], "smooth": true, "symbol": "circle", "symbolSize": 6 },
    { "name": "Web", "data": [80, 78, 82, 85, 88, 92], "smooth": true, "symbol": "square", "symbolSize": 6 }
  ]
}
```

`XY` 形式（时间轴）：

```json
{
  "type": "line",
  "title": "日活跃用户",
  "xAxis": { "type": "time", "title": "日期" },
  "yAxis": { "type": "linear", "title": "万人", "min": 0 },
  "series": [
    {
      "name": "DAU",
      "data": [
        { "x": "2026-01-01", "y": 12.0 },
        { "x": "2026-01-02", "y": 13.5 },
        { "x": "2026-01-03", "y": 12.8 }
      ],
      "smooth": true
    }
  ]
}
```

#### M14 面积图 `area`

折线 + 面积填充。专属字段：`series[].areaStyle.opacity`（默认 0.2）。

```json
{
  "type": "area",
  "title": "累计注册用户",
  "xAxis": { "type": "category", "labels": ["1月", "2月", "3月", "4月", "5月", "6月"] },
  "yAxis": { "type": "linear", "title": "万人", "min": 0 },
  "series": [
    { "name": "注册用户", "data": [20, 45, 75, 110, 150, 195], "smooth": true, "areaStyle": { "opacity": 0.25 } }
  ]
}
```

#### M15 堆叠面积图 `stacked-area`

`series[].stack` 相同即堆叠；强调总量与构成随时间变化。

```json
{
  "type": "stacked-area",
  "title": "各端流量构成",
  "xAxis": { "type": "category", "labels": ["1月", "2月", "3月", "4月", "5月", "6月"] },
  "yAxis": { "type": "linear", "title": "万次", "min": 0 },
  "series": [
    { "name": "App", "stack": "traffic", "data": [120, 132, 145, 160, 178, 190], "areaStyle": { "opacity": 0.6 } },
    { "name": "Web", "stack": "traffic", "data": [80, 78, 82, 85, 88, 92], "areaStyle": { "opacity": 0.6 } },
    { "name": "小程序", "stack": "traffic", "data": [40, 48, 55, 62, 70, 80], "areaStyle": { "opacity": 0.6 } }
  ]
}
```

#### M16 瀑布图 `waterfall`

专属字段：`series[0].data[]` 为 `{name, value, type}`；`type` 取 `total` / `increase` / `decrease`。`total` 表示从 0 重新起算的汇总柱。

```json
{
  "type": "waterfall",
  "title": "利润增减分解",
  "xAxis": { "type": "category", "labels": ["期初", "收入", "成本", "税费", "期末"] },
  "yAxis": { "type": "linear", "title": "万元", "min": 0 },
  "legend": { "show": false },
  "series": [
    {
      "name": "利润",
      "data": [
        { "name": "期初", "value": 120, "type": "total" },
        { "name": "收入", "value": 80, "type": "increase" },
        { "name": "成本", "value": -45, "type": "decrease" },
        { "name": "税费", "value": -15, "type": "decrease" },
        { "name": "期末", "value": 140, "type": "total" }
      ]
    }
  ]
}
```

#### M82 主题河流图 `streamgraph`

专属字段：`baseline`（`wiggle` / `zero` / `symmetry`，默认 `wiggle`）。`series[].data` 为等长数值数组。

```json
{
  "type": "streamgraph",
  "title": "音乐流派热度",
  "xAxis": { "type": "category", "labels": ["2019", "2020", "2021", "2022", "2023", "2024"] },
  "yAxis": { "type": "linear", "grid": false },
  "baseline": "wiggle",
  "series": [
    { "name": "流行", "data": [40, 45, 50, 48, 55, 60] },
    { "name": "摇滚", "data": [30, 28, 25, 27, 24, 22] },
    { "name": "电子", "data": [15, 20, 28, 35, 40, 45] },
    { "name": "民谣", "data": [10, 12, 14, 13, 16, 18] }
  ]
}
```

#### M83 蜡烛图 / K 线图 `candlestick`

专属字段：`series[0].data[]` 为 `{date, open, high, low, close}`；`xAxis.type` 用 `time` 或 `category`。

```json
{
  "type": "candlestick",
  "title": "日 K 线",
  "xAxis": { "type": "category", "labels": ["2026-01-05", "2026-01-06", "2026-01-07", "2026-01-08"] },
  "yAxis": { "type": "linear", "title": "价格", "min": 0 },
  "series": [
    {
      "name": "价格",
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

#### M84 螺旋图 `spiral`

专属字段：`turns`（圈数，默认 3）、`startAngle`（默认 -90）、`clockwise`（默认 true）。`series[0].data` 为 `{period, value}`。

```json
{
  "type": "spiral",
  "title": "月度周期",
  "width": 600,
  "height": 600,
  "turns": 3,
  "startAngle": -90,
  "clockwise": true,
  "series": [
    {
      "name": "周期值",
      "data": [
        { "period": "1月", "value": 12 },
        { "period": "2月", "value": 18 },
        { "period": "3月", "value": 25 },
        { "period": "4月", "value": 20 },
        { "period": "5月", "value": 30 },
        { "period": "6月", "value": 28 }
      ]
    }
  ]
}
```

### 5.3 分布类

#### M17 直方图 `histogram`

专属字段：`series[].bins`（分箱数或上界数组，默认 10）、`series[].normalize`（是否转为频率密度，默认 false）。

```json
{
  "type": "histogram",
  "title": "身高分布",
  "xAxis": { "type": "linear", "title": "身高（cm）" },
  "yAxis": { "type": "linear", "title": "频数", "min": 0 },
  "legend": { "show": false },
  "series": [
    {
      "name": "样本",
      "data": [162, 165, 168, 170, 171, 172, 173, 174, 175, 176, 178, 180, 182, 185, 168, 172, 174, 176, 169, 171],
      "bins": 8
    }
  ]
}
```

#### M18 核密度图 / 密度图 `density`

专属字段：`series[].bandwidth`（核带宽，缺省用 Silverman 规则）、`series[].fill`（默认 true）。

```json
{
  "type": "density",
  "title": "收入分布",
  "xAxis": { "type": "linear", "title": "月收入（千元）" },
  "yAxis": { "type": "linear", "title": "密度", "min": 0 },
  "series": [
    { "name": "2025", "data": [8, 9, 10, 10, 11, 12, 13, 15, 16, 18, 20, 22, 25, 30], "bandwidth": 2.0, "fill": true },
    { "name": "2026", "data": [9, 10, 11, 12, 13, 14, 15, 17, 19, 21, 24, 27, 30, 35], "bandwidth": 2.0, "fill": false }
  ]
}
```

#### M19 箱线图 `boxplot`

专属字段：`series[].data[]` 为 `{name, min, q1, median, q3, max, outliers}`；`outliers` 可省略。

```json
{
  "type": "boxplot",
  "title": "各班级成绩分布",
  "xAxis": { "type": "category", "labels": ["一班", "二班", "三班", "四班"] },
  "yAxis": { "type": "linear", "title": "分数", "min": 0, "max": 100 },
  "legend": { "show": false },
  "series": [
    {
      "name": "成绩",
      "data": [
        { "name": "一班", "min": 55, "q1": 68, "median": 76, "q3": 85, "max": 96, "outliers": [42, 98] },
        { "name": "二班", "min": 60, "q1": 70, "median": 78, "q3": 86, "max": 94, "outliers": [] },
        { "name": "三班", "min": 50, "q1": 62, "median": 70, "q3": 80, "max": 90, "outliers": [35] },
        { "name": "四班", "min": 58, "q1": 72, "median": 82, "q3": 90, "max": 99, "outliers": [] }
      ]
    }
  ]
}
```

#### M20 小提琴图 `violin`

专属字段：`series[].bandwidth`、`series[].showBox`（默认 true）。`data` 为「每组一个数值数组」的嵌套数组；单组时可写扁平数值数组。

```json
{
  "type": "violin",
  "title": "各渠道客单价分布",
  "xAxis": { "type": "category", "labels": ["搜索", "社交", "邮件", "直访"] },
  "yAxis": { "type": "linear", "title": "客单价（元）", "min": 0 },
  "legend": { "show": false },
  "series": [
    { "name": "客单价", "data": [[88, 92, 95, 99, 105], [110, 115, 120, 130, 150], [90, 96, 102, 108, 118], [85, 89, 94, 101, 112]], "bandwidth": 6.0, "showBox": true }
  ]
}
```

#### M21 蜂群图 / 抖动图 `swarm`

专属字段：`series[].jitter`（抖动宽度，默认自动）、`series[].side`（`both` / `left` / `right`）。`data` 为「每组一个数值数组」的嵌套数组；单组时可写扁平数值数组。

```json
{
  "type": "swarm",
  "title": "各组测量值",
  "xAxis": { "type": "category", "labels": ["对照组", "低剂量", "高剂量"] },
  "yAxis": { "type": "linear", "title": "测量值", "min": 0 },
  "series": [
    { "name": "测量值", "data": [[12, 14, 15, 18], [22, 25, 30, 33], [36, 38, 40, 41]], "jitter": 0.25, "side": "both" }
  ]
}
```

#### M22 茎叶图 `stem-leaf`

专属字段：`series[0].data` 为原始数值数组；`stemUnit`（茎的单位，默认 10）、`leafDigits`（叶位数，默认 1）。

```json
{
  "type": "stem-leaf",
  "title": "考试成绩茎叶图",
  "width": 600,
  "height": 520,
  "stemUnit": 10,
  "leafDigits": 1,
  "series": [
    { "name": "成绩", "data": [52, 55, 58, 61, 63, 63, 67, 70, 72, 75, 78, 81, 85, 88, 92, 96] }
  ]
}
```

#### M23 QQ 图 `qq`

专属字段：`series[0].distribution`（`normal` / `uniform` / `exponential`，默认 `normal`）、`showLine`（默认 true）。

```json
{
  "type": "qq",
  "title": "正态 QQ 图",
  "xAxis": { "type": "linear", "title": "理论分位数" },
  "yAxis": { "type": "linear", "title": "样本分位数" },
  "legend": { "show": false },
  "series": [
    { "name": "样本", "data": [12, 15, 18, 20, 22, 24, 26, 28, 31, 35, 40], "distribution": "normal", "showLine": true }
  ]
}
```

#### M24 山脊图 `ridge`

多组分布上下错位排列。专属字段：`series[].overlap`（重叠系数，默认 0.5）、`series[].bandwidth`。

```json
{
  "type": "ridge",
  "title": "各年份收入分布",
  "xAxis": { "type": "linear", "title": "月收入（千元）" },
  "yAxis": { "type": "category", "labels": ["2023", "2024", "2025", "2026"] },
  "series": [
    { "name": "2023", "data": [6, 8, 9, 10, 11, 12, 14, 16, 18, 22], "overlap": 0.5 },
    { "name": "2024", "data": [7, 9, 10, 12, 13, 15, 17, 20, 23, 28], "overlap": 0.5 },
    { "name": "2025", "data": [8, 10, 12, 14, 16, 18, 21, 25, 30, 36], "overlap": 0.5 },
    { "name": "2026", "data": [10, 12, 15, 18, 21, 24, 28, 33, 40, 48], "overlap": 0.5 }
  ]
}
```

#### M25 二维直方图 / 六边形分箱图 `2d-histogram`

专属字段：`series[0].bins`（`[x分箱, y分箱]`，默认 `[20,20]`）、`shape`（`hexagon` / `square`，默认 `hexagon`）。

```json
{
  "type": "2d-histogram",
  "title": "身高体重联合分布",
  "xAxis": { "type": "linear", "title": "身高（cm）" },
  "yAxis": { "type": "linear", "title": "体重（kg）" },
  "legend": { "show": false },
  "series": [
    {
      "name": "样本",
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

#### M88 雨云图 `raincloud`

专属字段：`series[].showCloud` / `showRain` / `showBox`（默认均 true）、`bandwidth`。

```json
{
  "type": "raincloud",
  "title": "各组得分分布",
  "xAxis": { "type": "category", "labels": ["A 组", "B 组", "C 组"] },
  "yAxis": { "type": "linear", "title": "得分", "min": 0 },
  "series": [
    { "name": "得分", "data": [55, 60, 62, 65, 68, 70, 72, 75, 78, 82, 88, 92], "bandwidth": 4.0, "showCloud": true, "showRain": true, "showBox": true }
  ]
}
```

#### M89 豆图 `dot-strip`

专属字段：`series[].jitter`、`series[].dotSize`。

```json
{
  "type": "dot-strip",
  "title": "各组小样本",
  "xAxis": { "type": "category", "labels": ["A", "B", "C"] },
  "yAxis": { "type": "linear", "title": "值", "min": 0 },
  "series": [
    { "name": "样本", "data": [12, 15, 18, 20, 24, 28, 31, 35], "jitter": 0.15, "dotSize": 7 }
  ]
}
```

#### M90 累积频率图 `ecdf`

`series[].data` 为原始数值数组；实现排序后绘制阶梯累计频率。

```json
{
  "type": "ecdf",
  "title": "响应时间累积分布",
  "xAxis": { "type": "linear", "title": "响应时间（ms）" },
  "yAxis": { "type": "linear", "title": "累积频率", "min": 0, "max": 1 },
  "series": [
    { "name": "优化前", "data": [120, 135, 150, 160, 175, 190, 210, 240, 280, 320] },
    { "name": "优化后", "data": [80, 90, 95, 100, 110, 120, 130, 145, 160, 180] }
  ]
}
```

#### M91 Bland-Altman 图 `bland-altman`

`series[0].data` 为成对测量 `{x, y}`；实现计算均值与差值，并画均值线与 ±1.96 SD 界限。

```json
{
  "type": "bland-altman",
  "title": "两种测量方法一致性",
  "xAxis": { "type": "linear", "title": "均值" },
  "yAxis": { "type": "linear", "title": "差值" },
  "legend": { "show": false },
  "series": [
    {
      "name": "测量对",
      "data": [
        { "x": 10.2, "y": 10.5 }, { "x": 12.0, "y": 11.6 }, { "x": 14.5, "y": 14.9 },
        { "x": 16.1, "y": 15.8 }, { "x": 18.3, "y": 18.9 }, { "x": 20.0, "y": 19.5 }
      ]
    }
  ]
}
```

#### M45 箱线图 + 散点组合图 `box-scatter`

在小提琴/箱线图旁叠加原始点。专属字段：`series[].showBox`（默认 true）、`series[].jitter`。

```json
{
  "type": "box-scatter",
  "title": "分布与原始点",
  "xAxis": { "type": "category", "labels": ["A 组", "B 组", "C 组"] },
  "yAxis": { "type": "linear", "title": "测量值", "min": 0 },
  "series": [
    { "name": "测量值", "data": [12, 14, 15, 17, 19, 22, 25, 28, 31, 35], "showBox": true, "jitter": 0.2 }
  ]
}
```

#### M46 小提琴 + 箱线组合图 `violin-box`

专属字段：`series[].bandwidth`、`series[].showBox`（默认 true）、`series[].showOutliers`（默认 true）。

```json
{
  "type": "violin-box",
  "title": "分布、分位数与异常值",
  "xAxis": { "type": "category", "labels": ["A 组", "B 组", "C 组"] },
  "yAxis": { "type": "linear", "title": "测量值", "min": 0 },
  "series": [
    { "name": "测量值", "data": [11, 13, 14, 16, 18, 20, 23, 26, 30, 36, 45], "bandwidth": 4.0, "showBox": true, "showOutliers": true }
  ]
}
```

### 5.4 关系类

#### M6 散点图 `scatter`

`series[].data` 为 `{x, y, label?, group?}`；`symbolSize` 控制点大小。

```json
{
  "type": "scatter",
  "title": "身高与体重",
  "xAxis": { "type": "linear", "title": "身高（cm）" },
  "yAxis": { "type": "linear", "title": "体重（kg）" },
  "series": [
    {
      "name": "样本",
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

#### M26 气泡图 `bubble`

`XY` 基础上增加 `size`。专属字段：`series[].sizeRange`（`[最小半径, 最大半径]`，默认 `[4, 30]`）。

```json
{
  "type": "bubble",
  "title": "国家指标",
  "xAxis": { "type": "linear", "title": "人均 GDP" },
  "yAxis": { "type": "linear", "title": "预期寿命" },
  "series": [
    {
      "name": "国家",
      "sizeRange": [6, 34],
      "data": [
        { "x": 12000, "y": 72, "size": 40, "label": "A 国" },
        { "x": 25000, "y": 78, "size": 80, "label": "B 国" },
        { "x": 40000, "y": 82, "size": 120, "label": "C 国" },
        { "x": 60000, "y": 84, "size": 60, "label": "D 国" }
      ]
    }
  ]
}
```

#### M27 相关矩阵图 `correlation-matrix`

数据为方阵 `M`。专属字段：`method`（`pearson` / `spearman`，默认 `pearson`）、`showValues`（默认 true）、`colorRange`（`[低, 中, 高]`）。

```json
{
  "type": "correlation-matrix",
  "title": "变量相关性",
  "width": 640,
  "height": 640,
  "xAxis": { "type": "category", "labels": ["身高", "体重", "年龄", "收入"] },
  "yAxis": { "type": "category", "labels": ["身高", "体重", "年龄", "收入"] },
  "method": "pearson",
  "showValues": true,
  "series": [
    {
      "name": "相关系数",
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

#### M28 平行坐标图 `parallel-coordinates`

专属字段：`dimensions: [{name, min, max}]`；`series[].data` 为样本行 `number[][]`，每行长度等于维度数。

```json
{
  "type": "parallel-coordinates",
  "title": "车型多指标对比",
  "width": 760,
  "height": 440,
  "dimensions": [
    { "name": "价格", "min": 0, "max": 60 },
    { "name": "油耗", "min": 0, "max": 20 },
    { "name": "马力", "min": 0, "max": 400 },
    { "name": "空间", "min": 0, "max": 10 }
  ],
  "series": [
    { "name": "轿车", "data": [[25, 7, 180, 6], [18, 6, 150, 5], [40, 9, 300, 7]] },
    { "name": "SUV", "data": [[35, 12, 250, 9], [50, 14, 350, 10]] }
  ]
}
```

#### M29 等高线图 `contour`

`series[0].data` 为 `{x, y, value}` 网格点。专属字段：`levels`（等值线层级数或显式数组）、`interpolate`（`linear` / `nearest`，默认 `linear`）。

```json
{
  "type": "contour",
  "title": "响应面",
  "xAxis": { "type": "linear", "title": "温度" },
  "yAxis": { "type": "linear", "title": "压力" },
  "legend": { "show": false },
  "levels": 8,
  "interpolate": "linear",
  "series": [
    {
      "name": "响应",
      "data": [
        { "x": 0, "y": 0, "value": 10 }, { "x": 1, "y": 0, "value": 14 }, { "x": 2, "y": 0, "value": 20 },
        { "x": 0, "y": 1, "value": 12 }, { "x": 1, "y": 1, "value": 18 }, { "x": 2, "y": 1, "value": 26 },
        { "x": 0, "y": 2, "value": 16 }, { "x": 1, "y": 2, "value": 24 }, { "x": 2, "y": 2, "value": 34 }
      ]
    }
  ]
}
```

#### M30 散点矩阵图 `scatter-matrix`

专属字段：`variables: string[]`；`series[].data` 为样本行 `number[][]`，每行长度等于变量数。实现按变量两两绘制子图。

```json
{
  "type": "scatter-matrix",
  "title": "多变量两两关系",
  "width": 720,
  "height": 720,
  "variables": ["身高", "体重", "年龄"],
  "series": [
    {
      "name": "样本",
      "data": [
        [160, 52, 22], [165, 56, 25], [168, 60, 28],
        [170, 62, 31], [172, 65, 35], [175, 68, 38],
        [178, 72, 42], [180, 75, 45], [183, 80, 50]
      ]
    }
  ]
}
```

#### M43 热力图 `heatmap`

数据为矩阵 `M`。专属字段：`colorRange`（`[低, 中, 高]`）、`showValues`（默认 false）、`cellGap`（默认 1）。

```json
{
  "type": "heatmap",
  "title": "周活跃热力",
  "xAxis": { "type": "category", "labels": ["周一", "周二", "周三", "周四", "周五"] },
  "yAxis": { "type": "category", "labels": ["上午", "下午", "晚上"] },
  "colorRange": ["#e8f1fb", "#7fb3d5", "#1f4e79"],
  "showValues": true,
  "series": [
    {
      "name": "活跃度",
      "data": [
        [12, 18, 20, 17, 25],
        [22, 28, 30, 26, 35],
        [30, 36, 32, 28, 40]
      ]
    }
  ]
}
```

#### M68 网络热力图 `network-heatmap`

与热力图同形；行列标签来自 `nodes`，用于展示节点间关系强度。专属字段：`nodes: [{id, name}]`、`colorRange`。

```json
{
  "type": "network-heatmap",
  "title": "节点关系强度",
  "width": 640,
  "height": 640,
  "nodes": [
    { "id": "a", "name": "网关" },
    { "id": "b", "name": "订单" },
    { "id": "c", "name": "库存" },
    { "id": "d", "name": "支付" }
  ],
  "colorRange": ["#f7fbff", "#6baed6", "#08306b"],
  "series": [
    {
      "name": "调用量",
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

### 5.5 构成、层级与网络

#### M31 饼图 `pie`

`series[0].data` 为 `{name, value}`。专属字段：`startAngle`（默认 0）、`showPercent`（默认 true）、`innerRadius`（默认 0）。

```json
{
  "type": "pie",
  "title": "市场份额",
  "width": 600,
  "height": 480,
  "startAngle": 0,
  "showPercent": true,
  "series": [
    {
      "name": "份额",
      "data": [
        { "name": "品牌 A", "value": 38 },
        { "name": "品牌 B", "value": 27 },
        { "name": "品牌 C", "value": 20 },
        { "name": "其他", "value": 15 }
      ]
    }
  ]
}
```

#### M32 环形图 `donut`

与饼图同数据形状；专属字段：`innerRadius`（默认 0.55，取外半径比例）、`centerText`。

```json
{
  "type": "donut",
  "title": "预算构成",
  "width": 600,
  "height": 480,
  "innerRadius": 0.55,
  "centerText": "总预算 100%",
  "series": [
    {
      "name": "预算",
      "data": [
        { "name": "研发", "value": 42 },
        { "name": "市场", "value": 28 },
        { "name": "运营", "value": 18 },
        { "name": "其他", "value": 12 }
      ]
    }
  ]
}
```

#### M33 马赛克图 `mosaic`

`xAxis.labels` 为一维类别；每个 `series` 是第二维的一个取值，`data` 与 `xAxis.labels` 等长。

```json
{
  "type": "mosaic",
  "title": "地区与购买意愿",
  "width": 720,
  "height": 480,
  "xAxis": { "type": "category", "labels": ["华东", "华南", "华北", "西部"] },
  "series": [
    { "name": "购买", "data": [120, 90, 70, 50] },
    { "name": "未购买", "data": [80, 70, 60, 40] }
  ]
}
```

#### M34 矩形树图 `treemap`

`nodes` 为层级结构，每个节点 `{id, name, parent, value?}`；叶子必须有 `value`，父节点值由子节点求和。专属字段：`tiling`（`squarify` / `slice`，默认 `squarify`）。

```json
{
  "type": "treemap",
  "title": "磁盘占用",
  "width": 760,
  "height": 480,
  "tiling": "squarify",
  "nodes": [
    { "id": "root", "name": "根目录", "parent": null },
    { "id": "usr", "name": "usr", "parent": "root" },
    { "id": "var", "name": "var", "parent": "root" },
    { "id": "bin", "name": "bin", "parent": "usr", "value": 120 },
    { "id": "lib", "name": "lib", "parent": "usr", "value": 260 },
    { "id": "log", "name": "log", "parent": "var", "value": 90 },
    { "id": "cache", "name": "cache", "parent": "var", "value": 60 }
  ]
}
```

#### M35 漏斗图 `funnel`

`series[0].data` 为 `{name, value}`，按数组顺序从上到下。专属字段：`gap`（层间距，默认 2）、`showConversion`（默认 true）。

```json
{
  "type": "funnel",
  "title": "注册转化",
  "width": 640,
  "height": 480,
  "gap": 2,
  "showConversion": true,
  "series": [
    {
      "name": "阶段",
      "data": [
        { "name": "访问", "value": 10000 },
        { "name": "注册", "value": 6200 },
        { "name": "激活", "value": 3800 },
        { "name": "付费", "value": 1200 }
      ]
    }
  ]
}
```

#### M36 桑基图 `sankey`

顶层 `nodes` + `links`。专属字段：`nodeWidth`（默认 16）、`nodeGap`（默认 12）、`iterations`（布局迭代次数，默认 32）。

```json
{
  "type": "sankey",
  "title": "流量来源",
  "width": 760,
  "height": 480,
  "nodeWidth": 16,
  "nodeGap": 12,
  "nodes": [
    { "id": "search", "name": "搜索" },
    { "id": "social", "name": "社交" },
    { "id": "home", "name": "首页" },
    { "id": "detail", "name": "详情" },
    { "id": "cart", "name": "购物车" },
    { "id": "pay", "name": "支付" }
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

#### M69 旭日图 `sunburst`

`nodes` 层级结构；专属字段：`innerRadius`（默认 0.2）、`sort`（`value` / `none`，默认 `value`）。

```json
{
  "type": "sunburst",
  "title": "产品收入层级",
  "width": 640,
  "height": 640,
  "innerRadius": 0.2,
  "nodes": [
    { "id": "root", "name": "全部", "parent": null },
    { "id": "hw", "name": "硬件", "parent": "root" },
    { "id": "sw", "name": "软件", "parent": "root" },
    { "id": "phone", "name": "手机", "parent": "hw", "value": 60 },
    { "id": "pc", "name": "电脑", "parent": "hw", "value": 40 },
    { "id": "saas", "name": "SaaS", "parent": "sw", "value": 55 },
    { "id": "license", "name": "授权", "parent": "sw", "value": 25 }
  ]
}
```

#### M70 圆堆积图 `circle-packing`

`nodes` 层级结构；叶子值决定圆面积。专属字段：`padding`（圆间距，默认 2）。

```json
{
  "type": "circle-packing",
  "title": "文件类型占比",
  "width": 640,
  "height": 640,
  "padding": 2,
  "nodes": [
    { "id": "root", "name": "全部", "parent": null },
    { "id": "code", "name": "代码", "parent": "root" },
    { "id": "asset", "name": "资源", "parent": "root" },
    { "id": "ts", "name": "TypeScript", "parent": "code", "value": 120 },
    { "id": "cj", "name": "Cangjie", "parent": "code", "value": 90 },
    { "id": "img", "name": "图片", "parent": "asset", "value": 70 },
    { "id": "font", "name": "字体", "parent": "asset", "value": 30 }
  ]
}
```

#### M71 组织图 / 树状图 `org-chart`

`nodes` 层级结构；专属字段：`layout`（`vertical` / `horizontal`，默认 `vertical`）、`nodeWidth`、`nodeHeight`、`levelGap`。

```json
{
  "type": "org-chart",
  "title": "组织架构",
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
    { "id": "fe", "name": "前端组", "parent": "cto" },
    { "id": "be", "name": "后端组", "parent": "cto" },
    { "id": "fin", "name": "财务组", "parent": "cfo" }
  ]
}
```

#### M62 节点-链接图 `node-link`

顶层 `nodes` + `links`。专属字段：`layout`（`force` / `circular` / `manual`，默认 `force`）、`linkDistance`、`charge`。`manual` 时节点需提供 `x` / `y`。

```json
{
  "type": "node-link",
  "title": "服务依赖",
  "width": 760,
  "height": 520,
  "layout": "force",
  "linkDistance": 120,
  "charge": -300,
  "nodes": [
    { "id": "gw", "name": "网关", "group": "接入" },
    { "id": "order", "name": "订单", "group": "业务" },
    { "id": "stock", "name": "库存", "group": "业务" },
    { "id": "pay", "name": "支付", "group": "业务" },
    { "id": "db", "name": "数据库", "group": "存储" }
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

#### M63 弧线图 `arc`

节点按圆周排列，链接画成弧。专属字段：`arcHeight`（弧高系数，默认 0.5）、`sort`（`value` / `none`）。

```json
{
  "type": "arc",
  "title": "部门协作",
  "width": 640,
  "height": 640,
  "arcHeight": 0.5,
  "nodes": [
    { "id": "rd", "name": "研发" },
    { "id": "pm", "name": "产品" },
    { "id": "design", "name": "设计" },
    { "id": "qa", "name": "测试" },
    { "id": "ops", "name": "运维" }
  ],
  "links": [
    { "source": "pm", "target": "rd", "value": 8 },
    { "source": "design", "target": "rd", "value": 5 },
    { "source": "rd", "target": "qa", "value": 6 },
    { "source": "qa", "target": "ops", "value": 3 }
  ]
}
```

#### M64 和弦图 `chord`

顶层 `nodes` + `links`；链接值构成有向流量矩阵。专属字段：`padAngle`（默认 0.02）、`showLabels`。

```json
{
  "type": "chord",
  "title": "城市迁移",
  "width": 640,
  "height": 640,
  "padAngle": 0.02,
  "nodes": [
    { "id": "bj", "name": "北京" },
    { "id": "sh", "name": "上海" },
    { "id": "gz", "name": "广州" },
    { "id": "sz", "name": "深圳" }
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

#### M65 蜂巢图 `hive`

节点按 `group` 分簇排布；专属字段：`groupField`（默认 `group`）、`nodeRadius`、`clusterGap`。

```json
{
  "type": "hive",
  "title": "技能关系",
  "width": 760,
  "height": 520,
  "groupField": "group",
  "nodeRadius": 18,
  "clusterGap": 80,
  "nodes": [
    { "id": "cangjie", "name": "仓颉", "group": "语言" },
    { "id": "go", "name": "Go", "group": "语言" },
    { "id": "sql", "name": "SQL", "group": "数据" },
    { "id": "redis", "name": "Redis", "group": "数据" },
    { "id": "k8s", "name": "K8s", "group": "运维" }
  ],
  "links": [
    { "source": "cangjie", "target": "sql", "value": 2 },
    { "source": "go", "target": "redis", "value": 3 },
    { "source": "sql", "target": "redis", "value": 2 },
    { "source": "redis", "target": "k8s", "value": 1 }
  ]
}
```

#### M66 冲积图 `alluvial`

层级流向；节点需带 `stage`，链接跨阶段。专属字段：`stages: string[]`、`nodeWidth`、`nodeGap`。

```json
{
  "type": "alluvial",
  "title": "用户状态迁移",
  "width": 800,
  "height": 480,
  "stages": ["2025", "2026"],
  "nodeWidth": 14,
  "nodeGap": 10,
  "nodes": [
    { "id": "new-2025", "name": "新客", "stage": "2025" },
    { "id": "old-2025", "name": "老客", "stage": "2025" },
    { "id": "new-2026", "name": "新客", "stage": "2026" },
    { "id": "old-2026", "name": "老客", "stage": "2026" },
    { "id": "lost-2026", "name": "流失", "stage": "2026" }
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

> M67 `sankey` 与 M36 相同，复用 `SankeyChart`；M86 `funnel` 与 M35 相同，复用 `FunnelChart`。

### 5.6 统计诊断与模型评价

#### M37 帕累托图 `pareto`

类目柱 + 累计百分比折线；实现按 `data` 从大到小排序。专属字段：`showCumulative`（默认 true）、`cumulativeFormat`（默认 `{value}%`）。

```json
{
  "type": "pareto",
  "title": "缺陷原因分析",
  "xAxis": { "type": "category", "labels": ["外观", "尺寸", "装配", "功能", "包装", "其他"] },
  "yAxis": { "type": "linear", "title": "缺陷数", "min": 0 },
  "showCumulative": true,
  "series": [
    { "name": "缺陷数", "data": [120, 80, 55, 30, 12, 8] }
  ]
}
```

#### M38 控制图 `control`

专属字段：`series[0].center`、`series[0].ucl`、`series[0].lcl`（控制限）；也可给 `sigma` 让实现按均值 ±3σ 计算。`data` 为按时间顺序的数值。

```json
{
  "type": "control",
  "title": "过程控制图",
  "xAxis": { "type": "category", "labels": ["1", "2", "3", "4", "5", "6", "7", "8"] },
  "yAxis": { "type": "linear", "title": "测量值" },
  "legend": { "show": false },
  "series": [
    {
      "name": "测量值",
      "data": [50.2, 49.8, 50.5, 50.1, 51.2, 49.5, 50.0, 50.3],
      "center": 50.0,
      "ucl": 51.5,
      "lcl": 48.5
    }
  ]
}
```

#### M39 误差线图 `error-bar`

`series[0].data` 为 `{x, y, low, high}`；`low` / `high` 为误差上下界。

```json
{
  "type": "error-bar",
  "title": "各组均值与置信区间",
  "xAxis": { "type": "category", "labels": ["A", "B", "C", "D"] },
  "yAxis": { "type": "linear", "title": "均值", "min": 0 },
  "legend": { "show": false },
  "series": [
    {
      "name": "均值",
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

#### M40 残差图 `residual`

`series[0].data` 为 `{x: 拟合值, y: 残差}`；实现画 y=0 参考线。

```json
{
  "type": "residual",
  "title": "回归残差",
  "xAxis": { "type": "linear", "title": "拟合值" },
  "yAxis": { "type": "linear", "title": "残差" },
  "legend": { "show": false },
  "series": [
    {
      "name": "残差",
      "data": [
        { "x": 10, "y": 0.5 }, { "x": 12, "y": -1.2 }, { "x": 14, "y": 0.8 },
        { "x": 16, "y": -0.4 }, { "x": 18, "y": 1.1 }, { "x": 20, "y": -0.9 }
      ]
    }
  ]
}
```

#### M41 杠杆图 / 影响图 `influence`

`series[0].data` 为 `{x: 杠杆值, y: 学生化残差, label?, cooksDistance?}`；点大小可按 Cook 距离映射。

```json
{
  "type": "influence",
  "title": "杠杆与影响",
  "xAxis": { "type": "linear", "title": "杠杆值" },
  "yAxis": { "type": "linear", "title": "学生化残差" },
  "legend": { "show": false },
  "series": [
    {
      "name": "样本",
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

#### M42 概率图 `probability`

与 QQ 图同形；专属字段：`distribution`（`normal` / `uniform` / `exponential`）、`showLine`。

```json
{
  "type": "probability",
  "title": "正态概率图",
  "xAxis": { "type": "linear", "title": "理论分位数" },
  "yAxis": { "type": "linear", "title": "样本分位数" },
  "legend": { "show": false },
  "series": [
    { "name": "样本", "data": [12, 15, 18, 20, 22, 24, 26, 28, 31, 35, 40], "distribution": "normal", "showLine": true }
  ]
}
```

#### M47 ROC 曲线 `roc`

`series[0].data` 为 `{x: FPR, y: TPR}`。专属字段：`auc`（可选，显示在图例/标注）、`diagonal`（是否画对角线，默认 true）。

```json
{
  "type": "roc",
  "title": "ROC 曲线",
  "xAxis": { "type": "linear", "title": "假阳性率", "min": 0, "max": 1 },
  "yAxis": { "type": "linear", "title": "真阳性率", "min": 0, "max": 1 },
  "diagonal": true,
  "series": [
    {
      "name": "模型 A（AUC=0.86）",
      "auc": 0.86,
      "data": [
        { "x": 0.0, "y": 0.0 }, { "x": 0.1, "y": 0.45 }, { "x": 0.2, "y": 0.65 },
        { "x": 0.4, "y": 0.80 }, { "x": 0.6, "y": 0.90 }, { "x": 1.0, "y": 1.0 }
      ]
    }
  ]
}
```

#### M48 PR 曲线 `pr`

`series[0].data` 为 `{x: 召回率, y: 精确率}`。专属字段：`ap`（平均精确率）、`baseline`（正例比例，画水平基线）。

```json
{
  "type": "pr",
  "title": "PR 曲线",
  "xAxis": { "type": "linear", "title": "召回率", "min": 0, "max": 1 },
  "yAxis": { "type": "linear", "title": "精确率", "min": 0, "max": 1 },
  "baseline": 0.12,
  "series": [
    {
      "name": "模型 A（AP=0.72）",
      "ap": 0.72,
      "data": [
        { "x": 0.0, "y": 1.0 }, { "x": 0.2, "y": 0.92 }, { "x": 0.4, "y": 0.81 },
        { "x": 0.6, "y": 0.68 }, { "x": 0.8, "y": 0.45 }, { "x": 1.0, "y": 0.12 }
      ]
    }
  ]
}
```

#### M49 生存曲线 / Kaplan-Meier 图 `survival`

`series[].data` 为 `{time, survival, censored?}`。专属字段：`confidence`（是否画置信带，默认 false）、`showCensors`（默认 true）。

```json
{
  "type": "survival",
  "title": "Kaplan-Meier 生存曲线",
  "xAxis": { "type": "linear", "title": "时间（月）", "min": 0 },
  "yAxis": { "type": "linear", "title": "生存率", "min": 0, "max": 1 },
  "confidence": false,
  "series": [
    {
      "name": "治疗组",
      "data": [
        { "time": 0, "survival": 1.0 }, { "time": 6, "survival": 0.92 },
        { "time": 12, "survival": 0.80 }, { "time": 18, "survival": 0.70, "censored": true },
        { "time": 24, "survival": 0.62 }
      ]
    },
    {
      "name": "对照组",
      "data": [
        { "time": 0, "survival": 1.0 }, { "time": 6, "survival": 0.85 },
        { "time": 12, "survival": 0.68 }, { "time": 18, "survival": 0.55 },
        { "time": 24, "survival": 0.40 }
      ]
    }
  ]
}
```

#### M50 森林图 `forest`

`series[0].data` 为 `{label, estimate, lower, upper, weight?}`；实现画估计值与置信区间，中线为 1（或 `nullLine`）。

```json
{
  "type": "forest",
  "title": "效应量汇总",
  "width": 720,
  "height": 480,
  "nullLine": 1,
  "xAxis": { "type": "log", "title": "OR（95% CI）", "min": 0.1, "max": 10 },
  "yAxis": { "type": "category", "labels": ["研究 A", "研究 B", "研究 C", "合并"] },
  "series": [
    {
      "name": "OR",
      "data": [
        { "label": "研究 A", "estimate": 0.8, "lower": 0.5, "upper": 1.3, "weight": 30 },
        { "label": "研究 B", "estimate": 1.5, "lower": 1.1, "upper": 2.1, "weight": 45 },
        { "label": "研究 C", "estimate": 1.1, "lower": 0.7, "upper": 1.8, "weight": 25 },
        { "label": "合并", "estimate": 1.2, "lower": 0.95, "upper": 1.5, "weight": 100 }
      ]
    }
  ]
}
```

#### M51 列线图 `nomogram`

专属字段：`variables: [{name, range, points}]`、`totalPoints`（总分范围）、`risk`（总分到风险的映射数组 `[{points, probability}]`）。

```json
{
  "type": "nomogram",
  "title": "风险预测列线图",
  "width": 760,
  "height": 420,
  "variables": [
    { "name": "年龄", "range": [20, 80], "points": [0, 100] },
    { "name": "血压", "range": [90, 180], "points": [0, 80] },
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

#### M92 火山图 `volcano`

`series[0].data` 为 `{x: log2FC, y: -log10(p), label?}`。专属字段：`foldChangeThreshold`（默认 1）、`pThreshold`（默认 1.3，即 -log10(0.05)）、`upColor` / `downColor`。

```json
{
  "type": "volcano",
  "title": "差异表达",
  "xAxis": { "type": "linear", "title": "log2 Fold Change" },
  "yAxis": { "type": "linear", "title": "-log10(p)" },
  "foldChangeThreshold": 1,
  "pThreshold": 1.3,
  "legend": { "show": false },
  "series": [
    {
      "name": "基因",
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

#### M93 曼哈顿图 `manhattan`

`series[0].data` 为 `{x: 基因组位置, y: -log10(p), chromosome}`。专属字段：`threshold`（显著性阈值线）、`chromosomeGap`。

```json
{
  "type": "manhattan",
  "title": "GWAS 曼哈顿图",
  "xAxis": { "type": "linear", "title": "染色体位置" },
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

#### M93b 混淆矩阵 `confusion-matrix`

数据为方阵 `M`。专属字段：`labels: string[]`、`normalize`（`none` / `row` / `column`，默认 `none`）、`showValues`。

```json
{
  "type": "confusion-matrix",
  "title": "分类混淆矩阵",
  "width": 560,
  "height": 560,
  "labels": ["猫", "狗", "鸟"],
  "normalize": "row",
  "showValues": true,
  "series": [
    {
      "name": "样本数",
      "data": [
        [45, 3, 2],
        [4, 38, 8],
        [1, 6, 33]
      ]
    }
  ]
}
```

#### M94 提升图 / Lift 图 `lift`

`series[0].data` 为 `{x: 样本比例, y: lift}`；专属字段：`baseline`（默认 1）。

```json
{
  "type": "lift",
  "title": "Lift 曲线",
  "xAxis": { "type": "linear", "title": "样本比例", "min": 0, "max": 1 },
  "yAxis": { "type": "linear", "title": "Lift" },
  "baseline": 1,
  "series": [
    {
      "name": "模型 A",
      "data": [
        { "x": 0.1, "y": 2.8 }, { "x": 0.2, "y": 2.3 }, { "x": 0.4, "y": 1.7 },
        { "x": 0.6, "y": 1.35 }, { "x": 0.8, "y": 1.12 }, { "x": 1.0, "y": 1.0 }
      ]
    }
  ]
}
```

#### M95 增益图 `gain`

`series[0].data` 为 `{x: 样本比例, y: 累计捕获比例}`；专属字段：`baseline`（对角线）。

```json
{
  "type": "gain",
  "title": "累积增益",
  "xAxis": { "type": "linear", "title": "样本比例", "min": 0, "max": 1 },
  "yAxis": { "type": "linear", "title": "捕获比例", "min": 0, "max": 1 },
  "series": [
    {
      "name": "模型 A",
      "data": [
        { "x": 0.1, "y": 0.42 }, { "x": 0.2, "y": 0.62 }, { "x": 0.4, "y": 0.82 },
        { "x": 0.6, "y": 0.91 }, { "x": 0.8, "y": 0.97 }, { "x": 1.0, "y": 1.0 }
      ]
    }
  ]
}
```

#### M96 校准曲线 `calibration`

`series[0].data` 为 `{x: 预测概率, y: 实际频率}`；专属字段：`diagonal`（默认 true）、`binCount`（可选）。

```json
{
  "type": "calibration",
  "title": "概率校准",
  "xAxis": { "type": "linear", "title": "预测概率", "min": 0, "max": 1 },
  "yAxis": { "type": "linear", "title": "实际频率", "min": 0, "max": 1 },
  "diagonal": true,
  "series": [
    {
      "name": "模型 A",
      "data": [
        { "x": 0.05, "y": 0.08 }, { "x": 0.15, "y": 0.12 }, { "x": 0.30, "y": 0.35 },
        { "x": 0.50, "y": 0.46 }, { "x": 0.70, "y": 0.74 }, { "x": 0.90, "y": 0.88 }
      ]
    }
  ]
}
```

#### M97 学习曲线 `learning-curve`

`series[].data` 为 `{x: 样本量, y: 得分}`；专属字段：`metric`（`score` / `loss`）、`shade`（是否画标准差带）。

```json
{
  "type": "learning-curve",
  "title": "学习曲线",
  "xAxis": { "type": "linear", "title": "训练样本量" },
  "yAxis": { "type": "linear", "title": "准确率", "min": 0, "max": 1 },
  "metric": "score",
  "series": [
    { "name": "训练集", "data": [{ "x": 100, "y": 0.72 }, { "x": 500, "y": 0.86 }, { "x": 1000, "y": 0.91 }, { "x": 2000, "y": 0.94 }] },
    { "name": "验证集", "data": [{ "x": 100, "y": 0.60 }, { "x": 500, "y": 0.78 }, { "x": 1000, "y": 0.84 }, { "x": 2000, "y": 0.87 }] }
  ]
}
```

#### M98 LASSO 路径图 `lasso-path`

专属字段：`variables: string[]`；`series[].data` 为 `{x: log(lambda), y: 系数}`，每个系列一条路径。

```json
{
  "type": "lasso-path",
  "title": "LASSO 系数路径",
  "xAxis": { "type": "linear", "title": "log(lambda)" },
  "yAxis": { "type": "linear", "title": "系数" },
  "variables": ["年龄", "血压", "BMI", "血糖"],
  "series": [
    { "name": "年龄", "data": [{ "x": -4, "y": 0.8 }, { "x": -2, "y": 0.5 }, { "x": 0, "y": 0.1 }, { "x": 2, "y": 0.0 }] },
    { "name": "血压", "data": [{ "x": -4, "y": 0.6 }, { "x": -2, "y": 0.4 }, { "x": 0, "y": 0.2 }, { "x": 2, "y": 0.0 }] },
    { "name": "BMI", "data": [{ "x": -4, "y": 0.3 }, { "x": -2, "y": 0.1 }, { "x": 0, "y": 0.0 }, { "x": 2, "y": 0.0 }] },
    { "name": "血糖", "data": [{ "x": -4, "y": 0.2 }, { "x": -2, "y": 0.0 }, { "x": 0, "y": 0.0 }, { "x": 2, "y": 0.0 }] }
  ]
}
```

#### M99 决策树图 `decision-tree`

顶层 `nodes` + `edges`；节点字段 `{id, label, parent?, condition?, leaf?}`，边字段 `{source, target, label?}`。

```json
{
  "type": "decision-tree",
  "title": "决策树",
  "width": 900,
  "height": 520,
  "nodes": [
    { "id": "root", "label": "年龄 > 30?", "leaf": false },
    { "id": "left", "label": "收入 > 10k?", "parent": "root", "leaf": false },
    { "id": "right", "label": "通过", "parent": "root", "leaf": true },
    { "id": "ll", "label": "拒绝", "parent": "left", "leaf": true },
    { "id": "lr", "label": "通过", "parent": "left", "leaf": true }
  ],
  "edges": [
    { "source": "root", "target": "left", "label": "否" },
    { "source": "root", "target": "right", "label": "是" },
    { "source": "left", "target": "ll", "label": "否" },
    { "source": "left", "target": "lr", "label": "是" }
  ]
}
```

#### M100 部分依赖图 `pdp`

`series[0].data` 为 `{x: 特征值, y: 预测值}`；专属字段：`feature`（特征名）。

```json
{
  "type": "pdp",
  "title": "年龄对预测的影响",
  "xAxis": { "type": "linear", "title": "年龄" },
  "yAxis": { "type": "linear", "title": "预测值" },
  "feature": "年龄",
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

#### M101 SHAP 图 `shap`

专属字段：`features: string[]`；`series[0].data` 为 `{feature, value}`（单个样本的 SHAP 值），按绝对值排序绘制。

```json
{
  "type": "shap",
  "title": "单样本 SHAP 解释",
  "width": 720,
  "height": 440,
  "features": ["年龄", "血压", "BMI", "血糖"],
  "series": [
    {
      "name": "SHAP",
      "data": [
        { "feature": "年龄", "value": 0.32 },
        { "feature": "血压", "value": -0.18 },
        { "feature": "BMI", "value": 0.12 },
        { "feature": "血糖", "value": -0.05 }
      ]
    }
  ]
}
```

### 5.7 项目、流程与时间

#### M8 甘特图 `gantt`

专属字段：`tasks: [{id, name, start, end, progress?, dependsOn?, lane?, color?}]`；`xAxis.type` 为 `time`。`progress` 为 0–1。

```json
{
  "type": "gantt",
  "title": "项目进度",
  "width": 900,
  "height": 480,
  "xAxis": { "type": "time", "title": "日期" },
  "yAxis": { "type": "category", "labels": ["需求", "设计", "开发", "测试", "上线"] },
  "tasks": [
    { "id": "t1", "name": "需求调研", "start": "2026-01-05", "end": "2026-01-16", "progress": 1.0, "lane": "需求" },
    { "id": "t2", "name": "方案设计", "start": "2026-01-19", "end": "2026-02-06", "progress": 0.8, "dependsOn": ["t1"], "lane": "设计" },
    { "id": "t3", "name": "编码", "start": "2026-02-09", "end": "2026-03-20", "progress": 0.45, "dependsOn": ["t2"], "lane": "开发" },
    { "id": "t4", "name": "联调测试", "start": "2026-03-23", "end": "2026-04-10", "progress": 0.1, "dependsOn": ["t3"], "lane": "测试" },
    { "id": "t5", "name": "发布", "start": "2026-04-13", "end": "2026-04-17", "progress": 0, "dependsOn": ["t4"], "lane": "上线" }
  ]
}
```

#### M9 流程图 `flowchart`

顶层 `nodes` + `edges`。节点 `{id, label, shape, x?, y?, width?, height?}`；`shape` 取 `rect` / `round` / `diamond` / `ellipse` / `parallelogram` / `document`。`layout` 为 `manual` 时使用 `x` / `y`，否则自动分层。

```json
{
  "type": "flowchart",
  "title": "订单处理流程",
  "width": 900,
  "height": 520,
  "layout": "vertical",
  "nodes": [
    { "id": "start", "label": "开始", "shape": "ellipse" },
    { "id": "create", "label": "创建订单", "shape": "rect" },
    { "id": "pay", "label": "已支付?", "shape": "diamond" },
    { "id": "ship", "label": "发货", "shape": "rect" },
    { "id": "cancel", "label": "取消订单", "shape": "rect" },
    { "id": "end", "label": "结束", "shape": "ellipse" }
  ],
  "edges": [
    { "source": "start", "target": "create" },
    { "source": "create", "target": "pay" },
    { "source": "pay", "target": "ship", "label": "是" },
    { "source": "pay", "target": "cancel", "label": "否" },
    { "source": "ship", "target": "end" },
    { "source": "cancel", "target": "end" }
  ]
}
```

#### M10 时序图 `sequence`

专属字段：`participants: [{id, name}]`、`messages: [{from, to, text, type?, dashed?, note?}]`。`type` 取 `sync` / `async` / `return`；`dashed` 为 true 时画虚线。

```json
{
  "type": "sequence",
  "title": "登录时序",
  "width": 900,
  "height": 520,
  "participants": [
    { "id": "user", "name": "用户" },
    { "id": "app", "name": "客户端" },
    { "id": "auth", "name": "认证服务" },
    { "id": "db", "name": "数据库" }
  ],
  "messages": [
    { "from": "user", "to": "app", "text": "输入账号密码", "type": "sync" },
    { "from": "app", "to": "auth", "text": "POST /login", "type": "sync" },
    { "from": "auth", "to": "db", "text": "查询用户", "type": "sync" },
    { "from": "db", "to": "auth", "text": "用户记录", "type": "return", "dashed": true },
    { "from": "auth", "to": "app", "text": "token", "type": "return", "dashed": true },
    { "from": "app", "to": "user", "text": "登录成功", "type": "async" }
  ]
}
```

#### M81 时间线图 `timeline`

专属字段：`events: [{date, title, description?, group?}]`、`orientation`（`horizontal` / `vertical`，默认 `horizontal`）。

```json
{
  "type": "timeline",
  "title": "产品里程碑",
  "width": 900,
  "height": 420,
  "orientation": "horizontal",
  "events": [
    { "date": "2026-01", "title": "立项", "description": "完成需求评审" },
    { "date": "2026-03", "title": "内测", "description": "首批用户试用" },
    { "date": "2026-06", "title": "公测", "description": "开放注册" },
    { "date": "2026-09", "title": "正式发布", "description": "全量上线" }
  ]
}
```

#### M85 泳道图 `swimlane`

专属字段：`lanes: [{id, name}]`；节点带 `lane`；`edges` 同流程图。`direction` 取 `horizontal`（默认）或 `vertical`。

```json
{
  "type": "swimlane",
  "title": "审批流程",
  "width": 900,
  "height": 560,
  "direction": "horizontal",
  "lanes": [
    { "id": "employee", "name": "员工" },
    { "id": "manager", "name": "主管" },
    { "id": "finance", "name": "财务" }
  ],
  "nodes": [
    { "id": "submit", "label": "提交申请", "lane": "employee" },
    { "id": "review", "label": "主管审批", "lane": "manager" },
    { "id": "pay", "label": "财务打款", "lane": "finance" },
    { "id": "reject", "label": "驳回", "lane": "manager" }
  ],
  "edges": [
    { "source": "submit", "target": "review" },
    { "source": "review", "target": "pay", "label": "通过" },
    { "source": "review", "target": "reject", "label": "不通过" }
  ]
}
```

### 5.8 火焰图

火焰图族共用层级数据：`nodes: [{id, name, parent, value, self?}]`，根的 `parent` 为 `null`；`value` 为包含子节点的总耗时，`self` 为自身耗时（缺省等于 `value - 子节点之和`）。

#### M52 火焰图 `flame`

专属字段：`orientation`（默认 `bottom-up`）、`colorBy`（`name` / `value`，默认 `name`）、`frameHeight`（默认 18）。

```json
{
  "type": "flame",
  "title": "CPU 火焰图",
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

#### M53 冰柱图 `icicle`

火焰图倒置：根在顶部，子节点向下展开。专属字段：`orientation`（默认 `top-down`）、`colorBy`。

```json
{
  "type": "icicle",
  "title": "调用栈冰柱图",
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

#### M54 差分火焰图 `differential-flame`

专属字段：`nodes[].value1`、`nodes[].value2`；`delta` 由实现计算（`value2 - value1`），红色表示增加、蓝色表示减少。`colorRange` 可覆盖默认红蓝。

```json
{
  "type": "differential-flame",
  "title": "版本差异",
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

#### M55 离线火焰图 `offline-flame`

只展示指定根节点下的调用栈。专属字段：`root`（起始节点 id，默认整棵树）、`maxDepth`（最大深度，默认不限）。

```json
{
  "type": "offline-flame",
  "title": "render 子树",
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

#### M56 热火焰图 `heat-flame`

颜色编码热度或耗时。专属字段：`heatField`（节点字段名，默认 `self`）、`colorRange`（`[冷, 热]`）。

```json
{
  "type": "heat-flame",
  "title": "CPU 热点",
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

### 5.9 地图

地图类图不做投影：`regions[].path` 是已经投影到画布坐标系的 SVG path；`viewBox` 给出坐标范围。

#### M57 分级统计地图 / 等值线地图 `choropleth`

专属字段：`viewBox: [x, y, w, h]`、`regions: [{id, name, value, path}]`、`colorRange`、`showLabels`。

```json
{
  "type": "choropleth",
  "title": "各省销售额",
  "width": 760,
  "height": 560,
  "viewBox": [0, 0, 760, 560],
  "colorRange": ["#e8f1fb", "#7fb3d5", "#1f4e79"],
  "showLabels": true,
  "regions": [
    { "id": "east", "name": "华东", "value": 320, "path": "M 420 180 L 560 190 L 570 300 L 430 310 Z" },
    { "id": "south", "name": "华南", "value": 260, "path": "M 430 320 L 560 315 L 550 430 L 420 420 Z" },
    { "id": "north", "name": "华北", "value": 210, "path": "M 300 120 L 410 130 L 415 240 L 300 230 Z" },
    { "id": "west", "name": "西部", "value": 150, "path": "M 120 180 L 290 190 L 295 360 L 130 350 Z" }
  ]
}
```

#### M58 点密度地图 `dot-density-map`

专属字段：`viewBox`、`regions`（底图，可只给 `path`）、`points: [{x, y, weight?}]`、`radius`（默认 3）。

```json
{
  "type": "dot-density-map",
  "title": "门店分布",
  "width": 760,
  "height": 560,
  "viewBox": [0, 0, 760, 560],
  "radius": 3,
  "regions": [
    { "id": "area", "name": "区域", "path": "M 100 100 L 650 110 L 640 480 L 120 470 Z" }
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

#### M59 热力地图 `heat-map`

专属字段：`viewBox`、`regions`（底图）、`points: [{x, y, value}]`、`radius`（影响半径，默认 24）、`colorRange`。

```json
{
  "type": "heat-map",
  "title": "访问热力",
  "width": 760,
  "height": 560,
  "viewBox": [0, 0, 760, 560],
  "radius": 28,
  "colorRange": ["#ffffcc", "#fd8d3c", "#800026"],
  "regions": [
    { "id": "area", "name": "区域", "path": "M 100 100 L 650 110 L 640 480 L 120 470 Z" }
  ],
  "points": [
    { "x": 240, "y": 220, "value": 20 },
    { "x": 300, "y": 260, "value": 45 },
    { "x": 420, "y": 310, "value": 80 },
    { "x": 500, "y": 360, "value": 35 }
  ]
}
```

#### M60 流向地图 `flow-map`

专属字段：`viewBox`、`regions`、`flows: [{from, to, value, points?}]`；`points` 为折线坐标，缺省时用两端区域中心连直线。

```json
{
  "type": "flow-map",
  "title": "人口迁移",
  "width": 760,
  "height": 560,
  "viewBox": [0, 0, 760, 560],
  "regions": [
    { "id": "a", "name": "A 市", "path": "M 170 200 L 250 210 L 245 280 L 165 270 Z" },
    { "id": "b", "name": "B 市", "path": "M 480 300 L 560 310 L 555 380 L 475 370 Z" }
  ],
  "flows": [
    { "source": "a", "target": "b", "value": 1200, "points": [[210, 240], [350, 300], [520, 340]] },
    { "source": "b", "target": "a", "value": 800, "points": [[520, 340], [350, 320], [210, 240]] }
  ]
}
```

#### M61 变形地图 / 卡托图 `cartogram`

专属字段：`viewBox`、`regions: [{id, name, value, path, centroid?}]`、`scaleBy`（`value` / `sqrt`，默认 `sqrt`）。

```json
{
  "type": "cartogram",
  "title": "按人口变形",
  "width": 760,
  "height": 560,
  "viewBox": [0, 0, 760, 560],
  "scaleBy": "sqrt",
  "regions": [
    { "id": "a", "name": "A 区", "value": 400, "path": "M 180 200 L 260 205 L 265 280 L 185 275 Z", "centroid": [220, 240] },
    { "id": "b", "name": "B 区", "value": 100, "path": "M 460 300 L 520 305 L 525 365 L 465 360 Z", "centroid": [490, 330] },
    { "id": "c", "name": "C 区", "value": 250, "path": "M 320 120 L 400 125 L 405 190 L 325 185 Z", "centroid": [360, 155] }
  ]
}
```

### 5.10 文本与仪表

#### M102 词云 `word-cloud`

专属字段：`words: [{text, weight, color?}]`、`minFontSize`（默认 12）、`maxFontSize`（默认 64）、`rotate`（允许旋转角度数组，默认 `[0]`）。

```json
{
  "type": "word-cloud",
  "title": "用户反馈关键词",
  "width": 760,
  "height": 480,
  "minFontSize": 14,
  "maxFontSize": 56,
  "rotate": [0, 90],
  "words": [
    { "text": "易用", "weight": 80 },
    { "text": "稳定", "weight": 65 },
    { "text": "快速", "weight": 60 },
    { "text": "界面", "weight": 45 },
    { "text": "文档", "weight": 35 },
    { "text": "价格", "weight": 25 }
  ]
}
```

#### M103 词网络图 `word-network`

顶层 `nodes` + `links`；节点 `{id, name, weight?}`，链接 `{source, target, value}`。专属字段：`layout`、`linkDistance`。

```json
{
  "type": "word-network",
  "title": "词语共现",
  "width": 760,
  "height": 520,
  "layout": "force",
  "linkDistance": 100,
  "nodes": [
    { "id": "chart", "name": "图表", "weight": 40 },
    { "id": "svg", "name": "SVG", "weight": 30 },
    { "id": "json", "name": "JSON", "weight": 28 },
    { "id": "data", "name": "数据", "weight": 36 }
  ],
  "links": [
    { "source": "chart", "target": "svg", "value": 18 },
    { "source": "chart", "target": "json", "value": 15 },
    { "source": "chart", "target": "data", "value": 22 },
    { "source": "json", "target": "data", "value": 12 }
  ]
}
```

> M104 `tag-cloud` 与 M102 相同，复用 `WordCloudChart`。

```json
{
  "type": "tag-cloud",
  "title": "热门标签",
  "width": 760,
  "height": 480,
  "words": [
    { "text": "仓颉", "weight": 90 },
    { "text": "SVG", "weight": 70 },
    { "text": "JSON", "weight": 55 },
    { "text": "图表", "weight": 40 }
  ]
}
```

#### M105 仪表盘 `gauge`

专属字段：`min`（默认 0）、`max`（默认 100）、`startAngle`（默认 -120）、`endAngle`（默认 120）、`thresholds: [{value, color}]`。

```json
{
  "type": "gauge",
  "title": "任务完成率",
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
    { "name": "完成率", "data": [{ "name": "完成率", "value": 72 }] }
  ]
}
```

#### M44 日历热力图 `calendar-heatmap`

专属字段：`series[0].data[]` 为 `{date, value}`；`startDate` / `endDate`（缺省按数据范围）、`cellSize`（默认 14）、`weekStart`（`mon` / `sun`，默认 `mon`）、`colorRange`。

```json
{
  "type": "calendar-heatmap",
  "title": "提交活跃度",
  "width": 900,
  "height": 220,
  "startDate": "2026-01-01",
  "endDate": "2026-03-31",
  "cellSize": 14,
  "weekStart": "mon",
  "colorRange": ["#ebedf0", "#9be9a8", "#40c463", "#216e39"],
  "series": [
    {
      "name": "提交数",
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

> M106 `calendar-heatmap` 与 M44 相同，复用 `CalendarHeatmapChart`。

### 5.11 组合图

#### M7 组合图 `combo`

在同一绘图区叠加柱状图、折线图、散点图、分组柱状图、堆叠柱状图、百分比堆叠柱状图。`series[].type` 必填，取以下之一：

| `series[].type` | 说明 |
|---|---|
| `bar` | 普通柱 |
| `grouped-bar` | 分组柱；同组系列共享类目槽位 |
| `stacked-bar` | 堆叠柱；`stack` 相同者堆叠 |
| `percent-stacked-bar` | 百分比堆叠柱；每个类目归一化到 100% |
| `line` | 折线 |
| `scatter` | 散点 |

专属字段：`yAxis2` 用于右侧轴；`series[].axis` 指定 `left` / `right`。柱类与线类可同屏叠加；同一 `stack` 的柱先堆叠，再与线/点绘制。

```json
{
  "type": "combo",
  "title": "销售额与增长率",
  "width": 900,
  "height": 480,
  "xAxis": { "type": "category", "labels": ["Q1", "Q2", "Q3", "Q4"] },
  "yAxis": { "type": "linear", "title": "销售额（万元）", "min": 0 },
  "yAxis2": { "type": "linear", "title": "增长率", "min": 0, "max": 50, "labelFormat": "{value}%" },
  "legend": { "show": true, "position": "top" },
  "series": [
    { "name": "产品 A", "type": "bar", "stack": "sales", "data": [120, 150, 170, 180] },
    { "name": "产品 B", "type": "bar", "stack": "sales", "data": [90, 110, 120, 130] },
    { "name": "增长率", "type": "line", "axis": "right", "smooth": true, "data": [8, 14, 18, 22] }
  ]
}
```

三种图同屏（柱 + 线 + 点）：

```json
{
  "type": "combo",
  "title": "三种图组合",
  "width": 900,
  "height": 480,
  "xAxis": { "type": "category", "labels": ["1月", "2月", "3月", "4月"] },
  "yAxis": { "type": "linear", "min": 0 },
  "series": [
    { "name": "销量", "type": "bar", "data": [120, 150, 130, 170] },
    { "name": "趋势", "type": "line", "data": [110, 140, 145, 160] },
    { "name": "异常点", "type": "scatter", "data": [{ "x": "2月", "y": 180 }, { "x": "4月", "y": 195 }] }
  ]
}
```

## 6. 别名与重复项

| 用户清单 | 本规范处理 |
|---|---|
| M36 / M67 桑基图 | 同一实现 `SankeyChart`，`type` 均为 `sankey` |
| M35 / M86 漏斗图 | 同一实现 `FunnelChart`，`type` 均为 `funnel` |
| M16 / M87 瀑布图 | 同一实现 `WaterfallChart`，`type` 均为 `waterfall` |
| M102 / M104 词云 / 标签云 | 同一实现 `WordCloudChart`，`type` 为 `word-cloud` / `tag-cloud` |
| M44 / M106 日历热力图 | 同一实现 `CalendarHeatmapChart`，`type` 均为 `calendar-heatmap` |
| M93 曼哈顿图 / 混淆矩阵 | 两个不同实现：`manhattan` / `confusion-matrix` |

## 7. 校验规则

实现必须在以下情况抛出 `ChartException`：

| 情况 | `kind` | `path` 示例 |
|---|---|---|
| `type` 缺失或与实现不匹配 | `UnsupportedChart` | `type` |
| `series` 缺失或为空（需要系列的图） | `MissingField` | `series` |
| 类目图 `series[].data` 长度与 `xAxis.labels` 不一致 | `InvalidValue` | `series[0].data` |
| `data` 元素不是数字/对象 | `InvalidValue` | `series[0].data[2]` |
| `x` / `y` 不是有限数 | `InvalidValue` | `series[0].data[2].x` |
| 矩阵行列数与 `xAxis.labels` / `yAxis.labels` 不一致 | `InvalidValue` | `series[0].data` |
| 层级节点 `parent` 指向不存在的 id | `InvalidValue` | `nodes[3].parent` |
| 链接 `source` / `target` 指向不存在的节点 | `InvalidValue` | `links[1].target` |
| 颜色字符串无法解析 | `InvalidValue` | `series[0].color` |
| 数值轴 `min >= max` | `InvalidValue` | `yAxis.min` |

容错与默认：

- 缺省 `width` / `height` 用 800 / 480；缺省 `padding` 用 24。
- 单系列且 `series[0].name` 为空时自动隐藏图例。
- 数值轴未给 `min` / `max` 时按数据范围留 5% 余量；全为 `null` 时用 `[0, 1]`。
- `null` 数据点：折线断开，柱/面积跳过，散点不画。
- 空数据：仍输出带标题与坐标框的 SVG，不抛异常；仅当结构缺失（如没有 `series`）才抛 `MissingField`。

