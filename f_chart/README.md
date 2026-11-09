# f_chart

**JSON 驱动的 SVG 图表**模块：调用方用一份 JSON 描述数据与样式，运行期由 `f_svg` 生成 SVG；所有图实现同一个 `Chart` 接口，一个图一个源文件，按需导入。

> 字段规范与每种图的完整 JSON 示例见 [`doc/chart-json-spec.md`](doc/chart-json-spec.md)。
> 设计与里程碑见 [`doc/f_chart模块设计.md`](doc/f_chart模块设计.md)。
> 每种图的绘制方式与 JSON 结构见文末[附录](#附各图绘制方式与-json-结构)。

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
| M51 | 列线图 `NomogramChart`（变量尺、总分尺、风险刻度） | 已完成 |
| M52 | 火焰图 `FlameChart`（调用栈树、自底向上、名称/值配色） | 已完成 |
| M53 | 冰柱图 `IcicleChart`（自顶向下、调用栈树） | 已完成 |
| M54 | 差分火焰图 `DifferentialFlameChart`（红增蓝减、双版本对比） | 已完成 |
| M55 | 离线火焰图 `OfflineFlameChart`（指定子树、深度限制） | 已完成 |
| M56 | 热火焰图 `HeatFlameChart`（热度字段、冷热渐变） | 已完成 |
| M57 | 分级统计地图 `ChoroplethChart`（区域路径、颜色分档、质心标签） | 已完成 |
| M58 | 点密度地图 `DotDensityMapChart`（底图、权重半径） | 已完成 |
| M59 | 热力地图 `HeatMapChart`（底图、影响半径、颜色渐变） | 已完成 |
| M60 | 流向地图 `FlowMapChart`（区域质心、折线路径、流量线宽） | 已完成 |
| M61 | 变形地图 `CartogramChart`（质心缩放、value/sqrt 比例） | 已完成 |
| M62 | 节点-链接图 `NodeLinkChart`（force/circular/manual 布局） | 已完成 |
| M63 | 弧线图 `ArcChart`（圆周节点、二次贝塞尔弧、按值排序） | 已完成 |
| M64 | 和弦图 `ChordChart`（外圈分段、带状线、标签） | 已完成 |
| M65 | 蜂巢图 `HiveChart`（分组聚簇、簇内环形、跨组连线） | 已完成 |
| M66 | 冲积图 `AlluvialChart`（阶段列、流量带、高度分配） | 已完成 |
| M67 | 桑基图别名（复用 `SankeyChart`，回归测试） | 已完成 |
| M68 | 网络热力图 `NetworkHeatmapChart`（节点方阵、行列标签） | 已完成 |
| M69 | 旭日图 `SunburstChart`（同心环、层级角度、一级标签） | 已完成 |
| M70 | 圆堆积图 `CirclePackingChart`（嵌套圆、面积半径、网格布局） | 已完成 |
| M71 | 组织图 `OrgChart`（垂直/水平布局、正交连线、父节点居中） | 已完成 |
| M72 | 南丁格尔玫瑰图 `RoseChart`（等角扇区、radius/area 半径） | 已完成 |
| M73 | 华夫图 `WaffleChart`（最大余数取整、方格矩阵、图例） | 已完成 |
| M74 | 象形图 `PictogramChart`（单位换算、person/circle/square/自定义路径） | 已完成 |
| M75 | 百分比条 `PercentBarChart`（复用百分比堆叠、`type=percent-bar`） | 已完成 |
| M76 | 子弹图 `BulletChart`（区间色带、值条、目标线） | 已完成 |
| M77 | 哑铃图 `DumbbellChart`（成对端点、连接线、自动范围） | 已完成 |
| M78 | 斜率图 `SlopeChart`（双时间点、斜率线、右侧标签） | 已完成 |
| M79 | 棒棒糖图 `LollipopChart`（茎线、圆头、null 跳过） | 已完成 |
| M80 | 配对连线图 `PairedLineChart`（before/after 配对、端点与标签） | 已完成 |
| M81 | 时间线图 `TimelineChart`（水平/垂直、交替事件、描述文本） | 已完成 |
| M82 | 主题河流图 `StreamgraphChart`（居中堆叠、wiggle/zero/symmetry） | 已完成 |
| M83 | 蜡烛图 `CandlestickChart`（影线、实体、涨跌配色） | 已完成 |
| M84 | 螺旋图 `SpiralChart`（阿基米德螺旋、圈数/方向、周期标签） | 已完成 |
| M85 | 泳道图 `SwimlaneChart`（横/纵泳道、节点、正交箭头） | 已完成 |
| M86 | 漏斗图别名（复用 `FunnelChart`，回归测试） | 已完成 |
| M87 | 瀑布图别名（复用 `WaterfallChart`，回归测试） | 已完成 |
| M88 | 雨云图 `RaincloudChart`（半小提琴、雨点、箱线组合） | 已完成 |
| M89 | 豆图 `DotStripChart`（确定性抖动、散点、点大小） | 已完成 |
| M90 | 累积频率图 `EcdfChart`（排序阶梯、累计频率） | 已完成 |
| M91 | Bland-Altman 图 `BlandAltmanChart`（均值差、±1.96 SD 界限） | 已完成 |
| M92 | 火山图 `VolcanoChart`（上调/下调分类、阈值线、显著标签） | 已完成 |
| M93 | 曼哈顿图 `ManhattanChart`（染色体分段、交替配色、阈值线） | 已完成 |
| M93b | 混淆矩阵 `ConfusionMatrixChart`（行列归一化、热度格、数值） | 已完成 |
| M94 | 提升图 `LiftChart`（升序折线、数据点、基准虚线） | 已完成 |
| M95 | 增益图 `GainChart`（累计捕获曲线、对角线基准） | 已完成 |
| M96 | 校准曲线 `CalibrationChart`（预测-实际对照、对角线开关） | 已完成 |
| M97 | 学习曲线 `LearningCurveChart`（训练/验证、标准差带、metric） | 已完成 |
| M98 | LASSO 路径图 `LassoPathChart`（系数收缩轨迹、零线、图例） | 已完成 |
| M99 | 决策树图 `DecisionTreeChart`（叶子槽位、分支标签、叶节点配色） | 已完成 |
| M100 | 部分依赖图 `PdpChart`（边际效应曲线、特征标注） | 已完成 |
| M101 | SHAP 图 `ShapChart`（绝对值降序、正负配色、零基线） | 已完成 |
| M102 | 词云图 `WordCloudChart`（开方字号映射、旋转循环、货架布局） | 已完成 |
| M103 | 词网络图 `WordNetworkChart`（权重半径、force/circular、节点内标签） | 已完成 |
| M104 | 标签云 `tag-cloud`（`WordCloudChart` 别名，回归测试） | 已完成 |
| M105 | 仪表盘 `GaugeChart`（阈值色带、指针、中心数值） | 已完成 |
| M106 | 日历热力图里程碑闭合（复用 `CalendarHeatmapChart`，回归测试） | 已完成 |

M1–M106 全部完成。测试总数 1144，全部通过（含 TUI 子包 52 个用例）。

## 图表样例（charts/）

`src/ChartGallery_test.cj` 为每个里程碑准备了一份真实 JSON，渲染后把 SVG 写入 `charts/`：

- 文件命名：`M<编号>-<type>.svg`，例如 `M001-bar.svg`、`M093b-confusion-matrix.svg`、`M106-calendar-heatmap.svg`。
- 共 107 个文件（M1–M106 含 M93b；别名各占一份），均为可被浏览器直接打开的完整 SVG。
- 重新生成：

```bash
cd f_chart
cjpm test --skip-build
```

测试会断言 SVG 包含 `<svg`，并自动创建 `charts/` 目录；SVG 内容变化会直接体现在 `git diff` 中，便于做视觉回归。

TUI 子包另由 `src/tui/TuiGallery_test.cj` 生成 7 份字符画样例：

- 文件命名：`M<编号>-<type>.tui.txt`，例如 `M001-bar.tui.txt`、`M007-combo.tui.txt`。
- 全部保留 ANSI 24 位真彩颜色，`cat` 即可看到系列配色；分组/堆叠/百分比堆叠的各系列或分段、组合图的柱/线/散点均使用不同颜色。
- 尺寸取 JSON 中的 `width`/`height`（字符列/行），与 SVG 样例共用同一批图表语义。

## TUI 子包（fountain::f_chart.tui）

终端/SSH 场景可直接渲染字符画。TUI 子包不引入任何第三方依赖，复用同一份 JSON 与 `Chart` 接口：

```cangjie
import fountain::f_chart.*
import fountain::f_chart.tui.*
import fountain::f_data.json.JsonValue

let svg = TuiBarChart().draw(data)   // 返回 ANSI 彩色字符串
print(svg)
```

| 类 | `type` | 说明 |
|---|---|---|
| `TuiBarChart` | `bar` | 单系列柱状图 |
| `TuiGroupedBarChart` | `grouped-bar` | 类目内并排柱 |
| `TuiStackedBarChart` | `stacked-bar` | 正负双向堆叠 |
| `TuiPercentStackedBarChart` | `percent-stacked-bar` | 按类目归一到 100% |
| `TuiLineChart` | `line` | 类目 / 数值 / 时间轴，null 断开 |
| `TuiScatterChart` | `scatter` | 数值 / 时间轴散点 |
| `TuiComboChart` | `combo` | 上述 6 种柱/线/点类型任意组合，支持右轴 |

约定：

- `width` / `height` 表示字符列数与行数，缺省 80×24，最小 20×8；建议 TUI JSON 显式写 `"width": 80, "height": 24`。
- 输出为 ANSI 24 位真彩色字符串，每行以 `\u{1B}[0m\n` 结束，可直接 `print`。
- 标记字符：柱族按系列循环使用 `█ ▓ ▒ ░`，折线 `*`、散点 `o`、网格 `·`、坐标轴 `│ ─ └`、图例 `■`；即使终端不支持颜色，多系列柱体也能通过符号区分。
- CJK 字符按 2 列显示；标签超出可用宽度时截断并以 `…` 结尾。
- TUI 组合图要求类目横轴；`axis: "right"` 的系列需要 `yAxis2`。

完整用法（各类 JSON 示例、尺寸与版式、错误处理、样例文件）见文末[附：TUI 子包用法](#附tui-子包用法)。

## 错误语义

`draw` 只在成功时返回字符串；任何结构或数值问题都以 `ChartException` 抛出，不会返回空串或半成品 SVG。`path` 字段形如 `series[0].data[2]`，非空时拼进异常消息。

---

## 附：各图绘制方式与 JSON 结构

本节按功能分组，逐一说明每种图的**绘制方式**与**JSON 结构**。完整字段语义与更多示例见 [`doc/chart-json-spec.md`](doc/chart-json-spec.md)；下面列出的 JSON 均可直接解析。

### 公共字段

所有图共享以下顶层字段，各图的 JSON 结构是在此基础上的增补：

| 字段 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `type` | string | — | 图类型判别符，必须与索引一致 |
| `title` | string \| object | 无 | 标题；对象形式支持 `text` / `subtext` / `align` / `fontSize` / `color` |
| `width` / `height` | number | 800 / 480 | 画布尺寸 |
| `padding` | number \| object | 24 | 四边留白，或 `{top,right,bottom,left}` |
| `theme` | object | 浅色 | `background` / `palette` / `fontFamily` / `fontSize` / `textColor` / `axisColor` / `gridColor` |
| `legend` | object | 显示 | `show` / `position` / `orient` / `itemGap` / `markerSize` |
| `xAxis` / `yAxis` | object | — | `type` / `title` / `labels` / `min` / `max` / `tickCount` / `grid` / `labelRotate` / `labelFormat` / `logBase` / `values` |
| `yAxis2` | object | 无 | 组合图右侧数值轴 |
| `series` | array | `[]` | 系列；每项含 `name` / `data` / `color` / `stack` / `axis` / `smooth` / `symbol` / `symbolSize` / `barWidth` / `opacity` / `areaStyle` / `label` |

数据形状代号：`C` = `number[]`；`XY` = `{x,y,...}[]`；`M` = `number[][]`；`N` = `nodes[] + links[]`；`H` = `nodes[]`（含 `parent`）；`S` = 图专属结构。

分组索引：

- 5.1 比较类
- 5.2 趋势类
- 5.3 分布类
- 5.4 关系类
- 5.5 构成、层级与网络
- 5.6 统计诊断与模型评价
- 5.7 项目、流程与时间
- 5.8 火焰图
- 5.9 地图
- 5.10 文本与仪表
- 5.11 组合图


### 5.1 比较类

#### M1 柱状图 `bar`

- 实现：`f_chart/src/BarChart.cj`
- 数据形状：`C`
- 绘制方式：类目轴用等宽带布局，数值轴线性；每个类别一根柱，以 0 为基线，正值向上、负值向下，柱宽默认为槽宽的 60%，可在柱顶显示数值。

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

- 实现：`f_chart/src/GroupedBarChart.cj`
- 数据形状：`C`
- 绘制方式：同一类别内按系列并排分组，组内均分带宽，按系列取色并生成图例。

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

- 实现：`f_chart/src/StackedBarChart.cj`
- 数据形状：`C`
- 绘制方式：每个类别一根堆叠柱，系列自下而上首尾相接，正值向上、负值向下，空值跳过。

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

- 实现：`f_chart/src/PercentStackedBarChart.cj`
- 数据形状：`C`
- 绘制方式：先按类别把各系列归一化为百分比，再堆叠；纵轴默认 0–100，柱顶可显示百分比标签。

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

- 实现：`f_chart/src/HorizontalBarChart.cj`
- 数据形状：`C`
- 绘制方式：类别放在纵轴、数值放在横轴，水平柱从 0 基线向正方向或负方向延伸。

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

- 实现：`f_chart/src/DotChart.cj`
- 数据形状：`C`
- 绘制方式：类别纵轴 + 数值横轴，每类一条水平茎线与一个圆点，适合少量类别的精确比较。

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

- 实现：`f_chart/src/RadarChart.cj`
- 数据形状：`C`
- 绘制方式：指标轴从圆心放射，背景为多层同心多边形；每个系列闭合为多边形并半透明填充。

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

- 实现：`f_chart/src/RoseChart.cj`
- 数据形状：`S`
- 绘制方式：所有扇区角度相等，半径按数值线性或开方映射，形成长短不一的花瓣。

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

- 实现：`f_chart/src/WaffleChart.cj`
- 数据形状：`S`
- 绘制方式：将总量折算为固定格数（默认 100），用最大余数法分配各类格数，再按行铺满方格矩阵。

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

- 实现：`f_chart/src/PictogramChart.cj`
- 数据形状：`S`
- 绘制方式：每个图标代表固定单位，按数量重复图标并按列换行，剩余零头用部分图标表示。

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

- 实现：`f_chart/src/PercentBarChart.cj`
- 数据形状：`C`
- 绘制方式：百分比堆叠柱的独立类型入口，复用同一渲染逻辑，按类别归一到 100% 后堆叠。

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

- 实现：`f_chart/src/BulletChart.cj`
- 数据形状：`S`
- 绘制方式：绘制区间色带、实际值条与目标竖线，横向对比当前值与目标。

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

- 实现：`f_chart/src/DumbbellChart.cj`
- 数据形状：`S`
- 绘制方式：每项由一条水平连接线连接 low 与 high 两个端点，两端口径分色。

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

- 实现：`f_chart/src/SlopeChart.cj`
- 数据形状：`S`
- 绘制方式：仅两个时间点，每个系列画一条连接两点的斜率线，两端画点并在右侧标注系列名。

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

- 实现：`f_chart/src/LollipopChart.cj`
- 数据形状：`C`
- 绘制方式：垂直茎线顶端放圆点，多系列在类目带内分槽，空值跳过。

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

- 实现：`f_chart/src/PairedLineChart.cj`
- 数据形状：`S`
- 绘制方式：before/after 两列配对点用连线连接，表示同一对象的前后变化，右侧可显示名称。

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

- 实现：`f_chart/src/LineChart.cj`
- 数据形状：`C / XY`
- 绘制方式：支持类目、数值、时间三种 x 轴；逐点连线，可选平滑（二次贝塞尔），null 处断开分段，可显示数据点符号。

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

#### M14 面积图 `area`

- 实现：`f_chart/src/AreaChart.cj`
- 数据形状：`C`
- 绘制方式：折线下方填充到 0 基线，支持平滑与 null 分段，填充透明度可配（默认 0.3）。

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

- 实现：`f_chart/src/StackedAreaChart.cj`
- 数据形状：`C`
- 绘制方式：多系列按 stack 分组累加，再绘制堆叠面积带，带与带之间无缝衔接。

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

- 实现：`f_chart/src/WaterfallChart.cj`
- 数据形状：`S`
- 绘制方式：每根柱表示一个增减量，柱底承接上一累计值；增加、减少与合计使用不同语义色，柱间画连接器。
- 别名：M87 也使用 `waterfall`，复用 `WaterfallChart`。

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

- 实现：`f_chart/src/StreamgraphChart.cj`
- 数据形状：`C`
- 绘制方式：堆叠面积以居中基线（zero/symmetry/wiggle）展开，形成上下流动的河带状图形。

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

- 实现：`f_chart/src/CandlestickChart.cj`
- 数据形状：`S`
- 绘制方式：每期绘制 high–low 影线与 open–close 实体，收盘不低于开盘为涨色，否则为跌色。

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

- 实现：`f_chart/src/SpiralChart.cj`
- 数据形状：`S`
- 绘制方式：数据点沿阿基米德螺旋等距分布，半径随序号增长，可配置圈数与旋转方向。

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

- 实现：`f_chart/src/HistogramChart.cj`
- 数据形状：`C`
- 绘制方式：将原始数值按等宽区间分箱，柱高为落入该箱的频数，箱数缺省取 sqrt(n) 向下取整。

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

- 实现：`f_chart/src/DensityChart.cj`
- 数据形状：`C`
- 绘制方式：用高斯核做核密度估计得到平滑曲线，带宽缺省用 Silverman 规则，曲线下方填充。

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

- 实现：`f_chart/src/BoxPlotChart.cj`
- 数据形状：`S`
- 绘制方式：由五数概括绘制箱体（Q1–Q3）与中位线，须延伸到 1.5 IQR 内的极值并加端帽，须外点标为异常值。

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

- 实现：`f_chart/src/ViolinChart.cj`
- 数据形状：`C`
- 绘制方式：每个类别绘制镜像的核密度轮廓成小提琴形，内部嵌入窄箱体与中位线。

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

- 实现：`f_chart/src/SwarmChart.cj`
- 数据形状：`C`
- 绘制方式：同一类别的点按确定性抖动横向错开，避免重叠，形成蜂群效果。

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

- 实现：`f_chart/src/StemLeafChart.cj`
- 数据形状：`C`
- 绘制方式：以文本表格呈现：左侧茎（十位）分组，右侧按个位拼接叶，长行自动换列。

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

- 实现：`f_chart/src/QQChart.cj`
- 数据形状：`C`
- 绘制方式：样本分位数对理论正态分位数作散点，并附最小二乘拟合参考线。

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

- 实现：`f_chart/src/RidgeChart.cj`
- 数据形状：`C`
- 绘制方式：每个类别的密度曲线按行错位叠加，overlap 控制行距重叠程度，形成山脊状。

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

- 实现：`f_chart/src/Histogram2DChart.cj`
- 数据形状：`XY`
- 绘制方式：在二维平面上分箱计数，支持方形网格或六边形网格，颜色按计数映射。

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

- 实现：`f_chart/src/RaincloudChart.cj`
- 数据形状：`C`
- 绘制方式：左侧为抖动散点（雨），右侧为半小提琴密度（云），中间叠加窄箱线与中位线。

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

- 实现：`f_chart/src/DotStripChart.cj`
- 数据形状：`C`
- 绘制方式：每个类别一列散点，用确定性抖动在带内横向错开，点大小可配。

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

- 实现：`f_chart/src/EcdfChart.cj`
- 数据形状：`C`
- 绘制方式：样本排序后按累计比例 (i/n) 绘制阶梯曲线，横轴为数值、纵轴为累积频率。

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

- 实现：`f_chart/src/BlandAltmanChart.cj`
- 数据形状：`XY`
- 绘制方式：横轴为两种测量的均值、纵轴为差值，绘制散点，并叠加均值差与 ±1.96 标准差界限。

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

- 实现：`f_chart/src/BoxScatterChart.cj`
- 数据形状：`C`
- 绘制方式：箱线图叠加抖动后的原始点，同时展示五数概括与样本分布。

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

- 实现：`f_chart/src/ViolinBoxChart.cj`
- 数据形状：`C`
- 绘制方式：小提琴密度轮廓 + 内嵌箱体、须线与 Tukey 异常点，组合展示分布形态与统计量。

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

- 实现：`f_chart/src/ScatterChart.cj`
- 数据形状：`XY`
- 绘制方式：数值或时间双轴散点，按 (x, y) 定位圆点，支持符号大小、形状与标签。

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

- 实现：`f_chart/src/BubbleChart.cj`
- 数据形状：`XY`
- 绘制方式：在散点基础上按第三个数值映射点半径，用于三变量关系。

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

- 实现：`f_chart/src/CorrelationMatrixChart.cj`
- 数据形状：`M`
- 绘制方式：N×N 方阵，每个格子用相关系数做三色插值（负相关、零、正相关），可标注数值。

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

- 实现：`f_chart/src/ParallelCoordinatesChart.cj`
- 数据形状：`S`
- 绘制方式：每个维度一条归一化垂直轴，每个样本是一条依次连接各轴的折线。

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

- 实现：`f_chart/src/ContourChart.cj`
- 数据形状：`XY`
- 绘制方式：在规则网格上计算标量场并抽取等值线，按层级绘制边界或填充区域。

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

- 实现：`f_chart/src/ScatterMatrixChart.cj`
- 数据形状：`C`
- 绘制方式：k×k 小散点矩阵，非对角格为两两变量散点，对角格显示变量名。

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

- 实现：`f_chart/src/HeatmapChart.cj`
- 数据形状：`M`
- 绘制方式：二维矩阵按行列排布单元格，数值经颜色插值填充，可显示数值与格间隙。

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

- 实现：`f_chart/src/NetworkHeatmapChart.cj`
- 数据形状：`M`
- 绘制方式：以节点为行列构造方阵，格色表示两节点间的关系强度，行列标签为节点名。

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

- 实现：`f_chart/src/PieChart.cj`
- 数据形状：`S`
- 绘制方式：按数值占比分配圆心角并绘制扇区，外圈标注百分比，配图例。

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

- 实现：`f_chart/src/DonutChart.cj`
- 数据形状：`S`
- 绘制方式：饼图中心挖去圆形内孔形成环带，圆心可显示总计或标题文本。

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

- 实现：`f_chart/src/MosaicChart.cj`
- 数据形状：`M`
- 绘制方式：列宽按每列总量分配，列内按类别占比纵向堆叠，格块面积对应联合频数。

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

- 实现：`f_chart/src/TreemapChart.cj`
- 数据形状：`H`
- 绘制方式：层级节点按权重铺满父矩形，递归沿较长边切分，子块用不同颜色区分。

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

- 实现：`f_chart/src/FunnelChart.cj`
- 数据形状：`S`
- 绘制方式：每个阶段一条水平阶段条，长度按数值递减，右侧标注转化率。
- 别名：M86 也使用 `funnel`，复用 `FunnelChart`。

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

- 实现：`f_chart/src/SankeyChart.cj`
- 数据形状：`N`
- 绘制方式：节点按层级分列排布，连线画成三次贝塞尔流量带，带宽按流量比例。
- 别名：M67 也使用 `sankey`，复用 `SankeyChart`。

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

- 实现：`f_chart/src/SunburstChart.cj`
- 数据形状：`H`
- 绘制方式：层级数据映射为同心环，每个父节点的角度范围按子节点权重细分，一级节点带标签。

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

- 实现：`f_chart/src/CirclePackingChart.cj`
- 数据形状：`H`
- 绘制方式：层级圆打包，叶圆面积按数值开方映射，父圆包裹子圆并递归布局。

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

- 实现：`f_chart/src/OrgChart.cj`
- 数据形状：`H`
- 绘制方式：树状组织图：叶子分配等距槽位，父节点位于子节点中点，正交折线连接；支持纵向与横向。

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

- 实现：`f_chart/src/NodeLinkChart.cj`
- 数据形状：`N`
- 绘制方式：节点与连线，支持确定性力导向、圆周与手动坐标三种布局，线宽按链接值映射。

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

- 实现：`f_chart/src/ArcChart.cj`
- 数据形状：`N`
- 绘制方式：节点沿圆周排列并按总流量排序，节点间以二次贝塞尔弧连接，弧高控制向圆心的弯曲程度。

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

- 实现：`f_chart/src/ChordChart.cj`
- 数据形状：`N`
- 绘制方式：外圈按节点总量分段并留出间隙，节点间用带状闭合路径连接，带宽按流量。

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

- 实现：`f_chart/src/HiveChart.cj`
- 数据形状：`N`
- 绘制方式：按 group 聚簇，簇心沿大圆周分布，簇内节点环形排列，跨簇关系画连线。

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

- 实现：`f_chart/src/AlluvialChart.cj`
- 数据形状：`N`
- 绘制方式：按阶段分列，节点高度取流入/流出总量的较大者，阶段之间用三次贝塞尔流量带连接。

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


### 5.6 统计诊断与模型评价

#### M37 帕累托图 `pareto`

- 实现：`f_chart/src/ParetoChart.cj`
- 数据形状：`C`
- 绘制方式：柱按数值降序排列，右侧叠加累计百分比折线，累计到 100%。

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

- 实现：`f_chart/src/ControlChart.cj`
- 数据形状：`C`
- 绘制方式：折线图叠加中心线与上下控制限（均值 ± 3σ）虚线，超出控制限的点高亮。

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

- 实现：`f_chart/src/ErrorBarChart.cj`
- 数据形状：`XY`
- 绘制方式：每项画中心点、上下界竖线与端帽，x 轴支持类目、数值与时间。

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

- 实现：`f_chart/src/ResidualChart.cj`
- 数据形状：`XY`
- 绘制方式：横轴为拟合值、纵轴为残差的散点，并画 y=0 零参考线，纵轴范围强制包含 0。

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

- 实现：`f_chart/src/InfluenceChart.cj`
- 数据形状：`XY`
- 绘制方式：散点按 Cook 距离映射点半径，可标注样本名，用于识别强影响点。

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

- 实现：`f_chart/src/ProbabilityChart.cj`
- 数据形状：`C`
- 绘制方式：样本值对理论分位数作散点，分布可选 normal/uniform/exponential，并附最小二乘参考线。

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

- 实现：`f_chart/src/RocChart.cj`
- 数据形状：`XY`
- 绘制方式：横轴假正率、纵轴真正率绘制 ROC 曲线，附对角线基准并标注 AUC。

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

- 实现：`f_chart/src/PrChart.cj`
- 数据形状：`XY`
- 绘制方式：横轴召回率、纵轴精确率绘制 PR 曲线，附精确率基线并标注 AP。

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

- 实现：`f_chart/src/SurvivalChart.cj`
- 数据形状：`S`
- 绘制方式：按时间绘制 Kaplan-Meier 阶梯生存曲线，删失点用 + 标记，可选置信带。

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

- 实现：`f_chart/src/ForestChart.cj`
- 数据形状：`S`
- 绘制方式：每项一行，效应量点为方块（大小按权重），水平线为置信区间，并画无效线；支持对数轴。

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

- 实现：`f_chart/src/NomogramChart.cj`
- 数据形状：`S`
- 绘制方式：多行刻度尺：变量尺、总分尺与风险刻度按系数映射点位，用于列线图评分。

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

- 实现：`f_chart/src/VolcanoChart.cj`
- 数据形状：`XY`
- 绘制方式：横轴为 fold change、纵轴为 -log10(p) 的散点，按阈值分为上调、下调与不显著并着色，画阈值线。

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

- 实现：`f_chart/src/ManhattanChart.cj`
- 数据形状：`XY`
- 绘制方式：按染色体分组沿横轴排布并留组间空隙，纵轴为 -log10(p)，染色体交替配色并画显著性阈值线。

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

- 实现：`f_chart/src/ConfusionMatrixChart.cj`
- 数据形状：`M`
- 绘制方式：混淆矩阵方阵，颜色按计数或行列归一化后的值映射，格内可显示数值。

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

- 实现：`f_chart/src/LiftChart.cj`
- 数据形状：`XY`
- 绘制方式：按横轴升序绘制提升曲线与数据点，附基准线。

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

- 实现：`f_chart/src/GainChart.cj`
- 数据形状：`XY`
- 绘制方式：绘制累计捕获比例随样本比例变化的曲线，附对角线基准。

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

- 实现：`f_chart/src/CalibrationChart.cj`
- 数据形状：`XY`
- 绘制方式：将预测概率分箱，横轴为平均预测值、纵轴为实际正例率，附对角线（可关闭）。

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

- 实现：`f_chart/src/LearningCurveChart.cj`
- 数据形状：`XY`
- 绘制方式：训练与验证指标随训练样本量的曲线，可选 ±标准差置信带。

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

- 实现：`f_chart/src/LassoPathChart.cj`
- 数据形状：`S`
- 绘制方式：每个变量一条系数随正则化强度变化的轨迹，附 y=0 零线。

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

- 实现：`f_chart/src/DecisionTreeChart.cj`
- 数据形状：`N`
- 绘制方式：决策树按叶子槽位布局，内部节点居中于子节点，分支带条件标签，叶节点单独着色。

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

- 实现：`f_chart/src/PdpChart.cj`
- 数据形状：`XY`
- 绘制方式：特征取值与模型边际效应的折线图，左上角标注特征名。

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

- 实现：`f_chart/src/ShapChart.cj`
- 数据形状：`S`
- 绘制方式：单样本特征贡献的水平条，按绝对值降序，正贡献红、负贡献蓝，附零基线与数值标签。

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

- 实现：`f_chart/src/GanttChart.cj`
- 数据形状：`S`
- 绘制方式：时间横轴、任务纵轴的甘特图；每任务一条圆角条，内嵌进度条，依赖关系用折线箭头连接。

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

- 实现：`f_chart/src/Flowchart.cj`
- 数据形状：`N`
- 绘制方式：节点按入边分层，同层纵向排布；支持六种节点形状，边为带箭头的正交或曲线。

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

- 实现：`f_chart/src/SequenceChart.cj`
- 数据形状：`S`
- 绘制方式：顶部绘制参与者框并向下垂生命线，消息为带箭头的水平线，返回消息用虚线，备注为便签框。

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

- 实现：`f_chart/src/TimelineChart.cj`
- 数据形状：`S`
- 绘制方式：事件按时间排布：水平模式沿轴交替上下，垂直模式左侧日期、右侧标题，可按 group 着色。

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

- 实现：`f_chart/src/SwimlaneChart.cj`
- 数据形状：`S`
- 绘制方式：横向或纵向泳道内排列节点，节点间用正交折线连接并加箭头，表示跨角色流转。

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

#### M52 火焰图 `flame`

- 实现：`f_chart/src/FlameChart.cj`
- 数据形状：`H`
- 绘制方式：调用栈树自底向上堆叠，矩形宽度按自身耗时，颜色按名称散列或按值映射。

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

- 实现：`f_chart/src/IcicleChart.cj`
- 数据形状：`H`
- 绘制方式：与火焰图同构，但根节点在顶部、子节点向下展开。

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

- 实现：`f_chart/src/DifferentialFlameChart.cj`
- 数据形状：`H`
- 绘制方式：双版本调用树对比，宽度按新版本值，颜色按差值红增蓝减。

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

- 实现：`f_chart/src/OfflineFlameChart.cj`
- 数据形状：`H`
- 绘制方式：以指定子树为根，按最大深度截断，宽度按子树根值归一化。

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

- 实现：`f_chart/src/HeatFlameChart.cj`
- 数据形状：`H`
- 绘制方式：火焰图矩形按 heat 字段着色，使用冷到热的颜色渐变，并可在块内显示热度。

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

#### M57 分级统计地图 / 等值线地图 `choropleth`

- 实现：`f_chart/src/ChoroplethChart.cj`
- 数据形状：`S`
- 绘制方式：在地图用户坐标系中直接绘制区域 path，填充色按数值分档，区域质心处标注名称。

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

- 实现：`f_chart/src/DotDensityMapChart.cj`
- 数据形状：`S`
- 绘制方式：可选区域底图，点位圆半径按权重开方缩放，适合展示分布密度。

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

- 实现：`f_chart/src/HeatMap.cj`
- 数据形状：`S`
- 绘制方式：底图上叠加半透明热力圆，按数值排序绘制以形成由内到外的渐变。

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

- 实现：`f_chart/src/FlowMapChart.cj`
- 数据形状：`S`
- 绘制方式：在区域质心之间绘制流量线（直线或折线），线宽按流量大小映射。

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

- 实现：`f_chart/src/CartogramChart.cj`
- 数据形状：`S`
- 绘制方式：以区域质心为中心按 value 或 sqrt 比例缩放区域形状，形成变形地图。

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

- 实现：`f_chart/src/WordCloudChart.cj`
- 数据形状：`S`
- 绘制方式：词项按权重映射字号，按货架式布局从左到右、从上到下排布，支持旋转与颜色覆盖。
- 别名：M104 使用 `tag-cloud`，由 `WordCloudChart` 识别为同义类型。

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

- 实现：`f_chart/src/WordNetworkChart.cj`
- 数据形状：`N`
- 绘制方式：词共现网络，节点半径按权重开方映射，词名居中显示在节点内，支持 force 与 circular 布局。

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

#### M105 仪表盘 `gauge`

- 实现：`f_chart/src/GaugeChart.cj`
- 数据形状：`S`
- 绘制方式：在起止角度之间绘制阈值色带，指针指向当前值，圆心显示数值与指标名。

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

- 实现：`f_chart/src/CalendarHeatmapChart.cj`
- 数据形状：`S`
- 绘制方式：按「周 × 星期」排列日期格，颜色按数值分档，顶部标月份、左侧标星期。
- 别名：M106 也使用 `calendar-heatmap`，复用 `CalendarHeatmapChart`。

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


### 5.11 组合图

#### M7 组合图 `combo`

- 实现：`f_chart/src/ComboChart.cj`
- 数据形状：`C / XY`
- 绘制方式：在同一坐标系混合柱、折线、散点、面积等系列，支持第二纵轴与按 stack 分组堆叠。

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

---

## 附：TUI 子包用法

TUI 子包（`fountain::f_chart.tui`）把与 SVG 版相同的 JSON 渲染成终端字符画。7 个类都实现 `fountain::f_chart.Chart`，因此可以按统一接口调用、替换或注入。

### 最小示例

```cangjie
import fountain::f_chart.tui.*
import fountain::f_data.json.JsonValue

main(): Int64 {
    let json = """
{
  "type": "bar",
  "title": "月度销售额",
  "width": 60,
  "height": 18,
  "xAxis": { "type": "category", "labels": ["一月", "二月", "三月", "四月"] },
  "yAxis": { "type": "linear", "min": 0 },
  "series": [ { "name": "销售额", "data": [120, 200, 150, 180] } ]
}
"""
    print(TuiBarChart().draw(JsonValue.fromStr(json).asObject()))
    0
}
```

`draw` 返回 ANSI 24 位真彩色字符串，每行以 `\u{1B}[0m\n` 结束，直接 `print` 即可在终端看到彩色字符画；写入文件时转义序列会保留，需纯文本时自行剥离 `\u{1B}[...m`。

### 按图类型调用

只需替换图表类；JSON 的 `type` 与类一一对应（`word-cloud` 等非 M1–M7 图不在 TUI 范围内）。

```cangjie
let charts: Array<Chart> = [
    TuiBarChart(),                  // bar
    TuiGroupedBarChart(),           // grouped-bar
    TuiStackedBarChart(),           // stacked-bar
    TuiPercentStackedBarChart(),    // percent-stacked-bar
    TuiLineChart(),                 // line
    TuiScatterChart(),              // scatter
    TuiComboChart()                 // combo
]
for (chart in charts) {
    println(chart.draw(data))
}
```

#### 分组柱状图

```json
{
  "type": "grouped-bar",
  "width": 64,
  "height": 18,
  "xAxis": { "type": "category", "labels": ["Q1", "Q2", "Q3", "Q4"] },
  "yAxis": { "type": "linear", "min": 0 },
  "series": [
    { "name": "产品 A", "data": [120, 150, 170, 160] },
    { "name": "产品 B", "data": [90, 110, 130, 140] }
  ]
}
```

#### 堆叠柱状图

```json
{
  "type": "stacked-bar",
  "width": 60,
  "height": 18,
  "xAxis": { "type": "category", "labels": ["华东", "华南", "华北"] },
  "yAxis": { "type": "linear", "min": 0 },
  "series": [
    { "name": "线上", "stack": "revenue", "data": [120, 90, 70] },
    { "name": "门店", "stack": "revenue", "data": [80, 70, 60] },
    { "name": "分销", "stack": "revenue", "data": [40, 35, 30] }
  ]
}
```

负值同样支持：正段向 0 基线以上堆叠，负段向基线以下堆叠。

#### 百分比堆叠柱状图

```json
{
  "type": "percent-stacked-bar",
  "width": 60,
  "height": 18,
  "xAxis": { "type": "category", "labels": ["2024", "2025", "2026"] },
  "series": [
    { "name": "线上", "data": [60, 70, 80] },
    { "name": "门店", "data": [30, 20, 15] },
    { "name": "分销", "data": [10, 10, 5] }
  ]
}
```

每个类目按系列总和归一到 100%，纵轴刻度显示百分比。

#### 折线图

类目横轴使用数值数组，长度须与 `xAxis.labels` 一致：

```json
{
  "type": "line",
  "width": 60,
  "height": 18,
  "xAxis": { "type": "category", "labels": ["周一", "周二", "周三", "周四", "周五"] },
  "yAxis": { "type": "linear" },
  "series": [ { "name": "活跃", "data": [120, 160, 140, null, 180] } ]
}
```

数值或时间横轴使用 `{x, y}` 点；`null` 处断线：

```json
{
  "type": "line",
  "width": 64,
  "height": 16,
  "xAxis": { "type": "time" },
  "yAxis": { "type": "linear" },
  "series": [
    { "name": "访问", "data": [
      { "x": "2026-01-01", "y": 120 },
      { "x": "2026-02-01", "y": 180 },
      { "x": "2026-03-01", "y": 150 }
    ] }
  ]
}
```

时间轴也接受数字 x（按天序号）；数值轴则要求数字 x。

#### 散点图

散点图要求 `linear` 或 `time` 横轴，数据为 `{x, y}`：

```json
{
  "type": "scatter",
  "width": 60,
  "height": 18,
  "xAxis": { "type": "linear", "title": "身高" },
  "yAxis": { "type": "linear", "title": "体重" },
  "series": [
    { "name": "样本", "data": [
      { "x": 160, "y": 55 }, { "x": 165, "y": 60 }, { "x": 170, "y": 65 },
      { "x": 175, "y": 70 }, { "x": 180, "y": 75 }
    ] }
  ]
}
```

#### 组合图

组合图要求类目横轴，`series[].type` 可取 `bar`、`grouped-bar`、`stacked-bar`、`percent-stacked-bar`、`line`、`scatter`；数据统一为数值数组并与 `xAxis.labels` 对齐：

```json
{
  "type": "combo",
  "width": 72,
  "height": 20,
  "xAxis": { "type": "category", "labels": ["Q1", "Q2", "Q3", "Q4"] },
  "yAxis": { "type": "linear", "min": 0 },
  "yAxis2": { "type": "linear", "labelFormat": "{value}%" },
  "series": [
    { "name": "产品 A", "type": "bar", "stack": "sales", "data": [120, 150, 170, 180] },
    { "name": "产品 B", "type": "bar", "stack": "sales", "data": [90, 110, 120, 130] },
    { "name": "增长", "type": "line", "axis": "right", "data": [8, 14, 18, 22] },
    { "name": "样本", "type": "scatter", "axis": "right", "data": [10, 12, 17, 21] }
  ]
}
```

规则：

- `bar` 系列各自占一个槽位；同 `stack` 值的 `stacked-bar` 合并堆叠；`percent-stacked-bar` 合并为一个百分比槽位；`grouped-bar` 在组内并排。
- `axis: "right"` 的系列读取 `yAxis2`，未提供 `yAxis2` 会报错。
- `line` / `scatter` 叠加在柱族之上；`smooth` 在 TUI 中按普通折线绘制。

### 尺寸与版式

- `width` / `height` 的单位是**字符列 / 行**，缺省 80×24，最小 20×8；低于下限抛 `ChartException`。
- 高度需要容纳标题（1–2 行）、图例（1 行）、x 轴与标签（2 行）；宽度需要容纳 y 轴刻度（含右轴）。绘图区不足 1 列或 1 行时报错，建议至少 `60×18`。
- SVG 的 `padding` 不参与字符布局，TUI 按终端行列重新排布。
- `legend.position: "bottom"` 时图例占底部一行；`show: false` 可关闭。
- `theme` 中的 `palette`、`textColor`、`axisColor`、`gridColor` 生效；`background` 不适用（终端背景由宿主决定）。
- CJK 字符按 2 列显示，超宽标签截断并以 `…` 结尾。

### 错误处理

与 SVG 版一致，所有结构或数值问题都抛 `ChartException`，不会返回空串或半成品：

```cangjie
import fountain::f_chart.ChartException

try {
    print(TuiScatterChart().draw(JsonValue.fromStr(json).asObject()))
} catch (error: ChartException) {
    eprintln("图表配置错误: ${error.message}")
}
```

常见错误：`scatter` 使用类目横轴、`combo` 非类目横轴、数据长度与标签不一致、`axis: "right"` 缺少 `yAxis2`、画布小于 20×8。

### 样例与回归

`src/tui/TuiGallery_test.cj` 的 7 个用例会把 M1–M7 的字符画写入 `charts/`：

- 文件命名：`M<编号>-<type>.tui.txt`。
- 全部保留 ANSI 24 位真彩颜色，`cat` 即可看到系列配色。

| 文件 | 类 |
|---|---|
| `M001-bar.tui.txt` | `TuiBarChart` |
| `M002-grouped-bar.tui.txt` | `TuiGroupedBarChart` |
| `M003-stacked-bar.tui.txt` | `TuiStackedBarChart` |
| `M004-percent-stacked-bar.tui.txt` | `TuiPercentStackedBarChart` |
| `M005-line.tui.txt` | `TuiLineChart` |
| `M006-scatter.tui.txt` | `TuiScatterChart` |
| `M007-combo.tui.txt` | `TuiComboChart` |

分组柱状图按系列交替取 `theme.palette`（或 `series[].color`）的颜色；堆叠柱状图、百分比堆叠柱状图以及组合图中的柱系列每个分段/柱体同理。柱体同时按系列循环使用 `█ ▓ ▒ ░`，因此相邻系列在 ANSI 输出和无色文本中都能区分。

重新生成：

```bash
cd f_chart
cjpm test --skip-build
```

这些文件是纯文本（ANSI 已剥离），可直接 `cat` 查看或纳入视觉回归。

