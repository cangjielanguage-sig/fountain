# f_chart 模块设计

## 1. 目标

用一份 JSON 描述图表，运行期生成 SVG。所有图实现同一个 `Chart` 接口，一个图一个源文件；调用方导入哪个实现就能画哪种图，不需要全局注册表或反射。

非目标：

- 不做前端交互（tooltip、缩放、拖拽）——输出是静态 SVG。
- 不做地图投影算法——地图类图接收已投影的 SVG path。
- 不在模块内引入第三方绘图库。

## 2. 依赖与边界

```
f_chart → f_svg → f_xml → f_base
        → f_data → f_base / f_collection / ...
        → f_base
```

- 包名 `fountain::f_chart`，动态链接库。
- `f_svg` 负责 SVG 文档模型与序列化；`f_chart` 只负责把数据映射成图元与布局。
- 不修改 `f_svg` / `f_data` 的公开 API。

## 3. 目录结构

```
f_chart/
├── cjpm.toml
├── README.md / README_en.md
├── doc/
│   ├── f_chart模块设计.md
│   ├── chart-json-spec.md
│   └── spec/<change-name>/...
└── src/
    ├── Chart.cj                  M0 接口
    ├── ChartException.cj         统一异常
    ├── ChartJson.cj              JSON 读取助手（internal）
    ├── ChartSpec.cj              通用信封（internal）
    ├── ChartTheme.cj             主题与调色板（internal）
    ├── ChartScale.cj             比例尺（internal）
    ├── ChartFrame.cj             坐标框、轴、网格、图例（internal）
    ├── ChartSvgKit.cj            SVG 输出助手（internal）
    ├── BarChart.cj               M1
    ├── BarChart_test.cj          M1 测试
    ├── tui/                      M1–M7、M52 的 TUI 子包（fountain::f_chart.tui）
    │   ├── TuiCanvas.cj          字符画布与 ANSI 输出（internal）
    │   ├── TuiFrame.cj           字符坐标框、轴、图例（internal）
    │   ├── TuiBarRenderer.cj     柱族共享渲染（internal）
    │   ├── BarChart.cj           TuiBarChart
    │   └── ...
    └── ...
```

一个图一个源文件，公开类型与文件名一致（`BarChart` / `GroupedBarChart` / ...）。公共基础设施全部 `internal`。

## 4. M0：接口

```cangjie
public interface Chart {
    func draw(data: JsonObject): String
}
```

契约：

- 纯函数语义：不修改入参，不依赖全局可变状态，同一输入产生确定性输出。
- 成功返回完整 SVG 文档；失败抛 `ChartException`。
- `ChartException.kind`：`InvalidJson` / `MissingField` / `InvalidValue` / `UnsupportedChart`；`path` 为字段路径。

## 5. JSON 信封

所有图共用：

| 字段 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `type` | string | 无（必填） | 图类型判别符 |
| `title` | string \| object | 无 | 标题；对象形式支持 `text` / `subtext` / `align` / `fontSize` |
| `width` | number | 800 | 画布宽 |
| `height` | number | 480 | 画布高 |
| `padding` | object \| number | 24 | 画布内边距 |
| `theme` | object | 内置浅色 | 背景、调色板、字体、文字/轴/网格颜色 |
| `legend` | object | 自动 | `show` / `position` / `orient` |
| `xAxis` | object | 视图而定 | 类目 / 数值 / 时间轴 |
| `yAxis` | object | 视图而定 | 数值轴；组合图可用 `yAxis2` |
| `series` | array | 视图而定 | 数据系列 |
| `annotations` | array | `[]` | 文本、参考线、参考带、标记点 |

轴字段：

| 字段 | 类型 | 说明 |
|---|---|---|
| `type` | string | `category` / `linear` / `log` / `time` |
| `title` | string | 轴标题 |
| `labels` | string[] | 类目轴标签 |
| `min` / `max` | number \| null | 数值轴范围；缺省按数据自适应 |
| `tickCount` | number | 期望刻度数 |
| `grid` | bool | 是否画网格 |
| `labelRotate` | number | 标签旋转角度 |
| `labelFormat` | string | `{value}` 占位格式，如 `{value}%` |
| `logBase` | number | 对数轴底数，默认 10 |

系列字段：

| 字段 | 类型 | 说明 |
|---|---|---|
| `name` | string | 系列名，用于图例 |
| `type` | string | 缺省等于图的 `type`；组合图必填 |
| `data` | array | 数值数组或对象数组，形状由图类型决定 |
| `color` | string | 覆盖调色板 |
| `stack` | string | 同组堆叠 |
| `axis` | string | `left` / `right`（组合图） |
| `opacity` | number | 0–1 |
| `barWidth` | number | 柱宽（像素） |
| `smooth` | bool | 折线/面积平滑 |
| `symbol` | string | `circle` / `square` / `diamond` / `none` |
| `symbolSize` | number | 点大小 |

数据形状约定：

1. **类目图**：`xAxis.labels` 与 `series[].data` 等长，`data` 为 `number | null`。
2. **XY 图**：`series[].data` 为 `{ "x": number, "y": number, ... }`。
3. **矩阵图**：`series[0].data` 为 `number[][]`，行列对应 `xAxis.labels` / `yAxis.labels`。
4. **关系图**：顶层 `nodes` + `links`。
5. **层级图**：顶层 `nodes`，每个节点带 `parent`（根为 `null`）。
6. **专用数据**：`tasks`（甘特）、`participants` / `messages`（时序）、`regions`（地图）、`words`（词云）等，逐图声明。

同一语义只用一个字段名：类目标签一律 `xAxis.labels`；系列数据一律 `series[].data`；节点关系一律 `nodes` / `links`；时间一律 ISO-8601 字符串或毫秒时间戳。

## 6. 渲染管线

1. `ChartJson` 读取并校验信封；错误带字段路径。
2. `ChartFrame` 计算画布与绘图区：扣除标题、图例、轴标签占位。
3. `ChartScale` 把数据值映射到像素（linear / log / band / time）。
4. 图实现用 `ChartSvgKit` 往 `SvgBuilder` 写图元。
5. `SvgBuilder.toSvgString()` 输出，根元素带 `width` / `height` / `viewBox`。

`ChartFrame` 统一负责背景、标题、副标题、绘图区、网格、刻度、轴标题、图例；图实现只负责数据图元。这样 100+ 个图的轴与图例行为保持一致。

## 7. 里程碑与文件映射

| 里程碑 | 图 | 文件 |
|---|---|---|
| M0 | 接口 | `Chart.cj` |
| M1 | 柱状图 | `BarChart.cj` |
| M2 | 分组柱状图 | `GroupedBarChart.cj` |
| M3 | 堆叠柱状图 | `StackedBarChart.cj` |
| M4 | 百分比堆叠柱状图 | `PercentStackedBarChart.cj` |
| M5 | 折线图 | `LineChart.cj` |
| M6 | 散点图 | `ScatterChart.cj` |
| M7 | 六图组合 | `ComboChart.cj` |
| M8 | 甘特图 | `GanttChart.cj` |
| M9 | 流程图 | `Flowchart.cj` |
| M10 | 时序图 | `SequenceChart.cj` |
| M11 | 条形图 | `HorizontalBarChart.cj` |
| M12 | 点图 | `DotChart.cj` |
| M13 | 雷达图 | `RadarChart.cj` |
| M14 | 面积图 | `AreaChart.cj` |
| M15 | 堆叠面积图 | `StackedAreaChart.cj` |
| M16 | 瀑布图 | `WaterfallChart.cj` |
| M17 | 直方图 | `HistogramChart.cj` |
| M18 | 核密度图 | `DensityChart.cj` |
| M19 | 箱线图 | `BoxPlotChart.cj` |
| M20 | 小提琴图 | `ViolinChart.cj` |
| M21 | 蜂群图 | `SwarmChart.cj` |
| M22 | 茎叶图 | `StemLeafChart.cj` |
| M23 | QQ 图 | `QQChart.cj` |
| M24 | 山脊图 | `RidgeChart.cj` |
| M25 | 二维直方图 | `Histogram2DChart.cj` |
| M26 | 气泡图 | `BubbleChart.cj` |
| M27 | 相关矩阵图 | `CorrelationMatrixChart.cj` |
| M28 | 平行坐标图 | `ParallelCoordinatesChart.cj` |
| M29 | 等高线图 | `ContourChart.cj` |
| M30 | 散点矩阵图 | `ScatterMatrixChart.cj` |
| M31 | 饼图 | `PieChart.cj` |
| M32 | 环形图 | `DonutChart.cj` |
| M33 | 马赛克图 | `MosaicChart.cj` |
| M34 | 矩形树图 | `TreemapChart.cj` |
| M35 | 漏斗图 | `FunnelChart.cj` |
| M36 | 桑基图 | `SankeyChart.cj` |
| M37 | 帕累托图 | `ParetoChart.cj` |
| M38 | 控制图 | `ControlChart.cj` |
| M39 | 误差线图 | `ErrorBarChart.cj` |
| M40 | 残差图 | `ResidualChart.cj` |
| M41 | 杠杆图 | `InfluenceChart.cj` |
| M42 | 概率图 | `ProbabilityChart.cj` |
| M43 | 热力图 | `HeatmapChart.cj` |
| M44 | 日历热力图 | `CalendarHeatmapChart.cj` |
| M45 | 箱线+散点 | `BoxScatterChart.cj` |
| M46 | 小提琴+箱线 | `ViolinBoxChart.cj` |
| M47 | ROC 曲线 | `RocChart.cj` |
| M48 | PR 曲线 | `PrChart.cj` |
| M49 | 生存曲线 | `SurvivalChart.cj` |
| M50 | 森林图 | `ForestChart.cj` |
| M51 | 列线图 | `NomogramChart.cj` |
| M52 | 火焰图 | `FlameChart.cj` |
| M53 | 冰柱图 | `IcicleChart.cj` |
| M54 | 差分火焰图 | `DifferentialFlameChart.cj` |
| M55 | 离线火焰图 | `OfflineFlameChart.cj` |
| M56 | 热火焰图 | `HeatFlameChart.cj` |
| M57 | 分级统计地图 | `ChoroplethChart.cj` |
| M58 | 点密度地图 | `DotDensityMapChart.cj` |
| M59 | 热力地图 | `HeatMap.cj`（公开类型 `HeatMapChart`，避开与 M43 文件名大小写冲突） |
| M60 | 流向地图 | `FlowMapChart.cj` |
| M61 | 变形地图 | `CartogramChart.cj` |
| M62 | 节点-链接图 | `NodeLinkChart.cj` |
| M63 | 弧线图 | `ArcChart.cj` |
| M64 | 和弦图 | `ChordChart.cj` |
| M65 | 蜂巢图 | `HiveChart.cj` |
| M66 | 冲积图 | `AlluvialChart.cj` |
| M69 | 旭日图 | `SunburstChart.cj` |
| M70 | 圆堆积图 | `CirclePackingChart.cj` |
| M71 | 组织图 | `OrgChart.cj` |
| M72 | 南丁格尔玫瑰图 | `RoseChart.cj` |
| M73 | 华夫图 | `WaffleChart.cj` |
| M74 | 象形图 | `PictogramChart.cj` |
| M75 | 百分比条 | `PercentBarChart.cj` |
| M76 | 子弹图 | `BulletChart.cj` |
| M77 | 哑铃图 | `DumbbellChart.cj` |
| M78 | 斜率图 | `SlopeChart.cj` |
| M79 | 棒棒糖图 | `LollipopChart.cj` |
| M80 | 配对连线图 | `PairedLineChart.cj` |
| M81 | 时间线图 | `TimelineChart.cj` |
| M82 | 主题河流图 | `StreamgraphChart.cj` |
| M83 | 蜡烛图 | `CandlestickChart.cj` |
| M84 | 螺旋图 | `SpiralChart.cj` |
| M85 | 泳道图 | `SwimlaneChart.cj` |
| M88 | 雨云图 | `RaincloudChart.cj` |
| M89 | 豆图 | `DotStripChart.cj` |
| M90 | 累积频率图 | `EcdfChart.cj` |
| M91 | Bland-Altman | `BlandAltmanChart.cj` |
| M92 | 火山图 | `VolcanoChart.cj` |
| M93 | 曼哈顿图 | `ManhattanChart.cj` |
| M93b | 混淆矩阵 | `ConfusionMatrixChart.cj` |
| M94 | 提升图 | `LiftChart.cj` |
| M95 | 增益图 | `GainChart.cj` |
| M96 | 校准曲线 | `CalibrationChart.cj` |
| M97 | 学习曲线 | `LearningCurveChart.cj` |
| M98 | LASSO 路径图 | `LassoPathChart.cj` |
| M99 | 决策树图 | `DecisionTreeChart.cj` |
| M100 | 部分依赖图 | `PdpChart.cj` |
| M101 | SHAP 图 | `ShapChart.cj` |
| M102 | 词云 | `WordCloudChart.cj` |
| M103 | 词网络图 | `WordNetworkChart.cj` |
| M105 | 仪表盘 | `GaugeChart.cj` |

重复别名复用同一实现：

| 别名 | 实现 |
|---|---|
| M67 桑基图 | `SankeyChart` |
| M86 漏斗图 | `FunnelChart` |
| M87 瀑布图 | `WaterfallChart` |
| M104 标签云 | `WordCloudChart` |
| M106 热力图日历 | `CalendarHeatmapChart` |

## 8. 每个图的 OpenSpec + TDD 流程

每个里程碑独立一个 change：

1. `openspec new change "add-f-chart-<type>"`。
2. proposal / specs / design / tasks 四件套；spec 增量写入 `chart-rendering` 能力。
3. 评审后 apply：
   - 先写 `<Chart>_test.cj`：最小 JSON、默认尺寸、单点/空数据、非法类型、非法数值、确定性、`SvgParser` 可解析。
   - `cjpm test` 观察失败（Red）。
   - 最小实现到绿（Green），再重构公共助手。
4. `cjpm test` 全绿 + `openspec validate --strict` → verify → archive。
5. 四件套同步到 `f_chart/doc/spec/<change-name>/`。

## 9. 测试策略

- 每个图至少 6 个用例：正常、边界、错误、确定性、SVG 可解析、主题/图例开关。
- 复杂图（M7、M9、M10、M36、M85）加黄金文件，比较前统一换行与数值格式。
- 公共助手单独测试：比例尺、刻度、图例布局、数值格式化。
- 测试只放在模块 `src/` 内，不创建项目外单文件测试。


## 10. TUI 子包（M1–M7、M52）

`f_chart/src/tui/` 声明包 `fountain::f_chart.tui`，为 M1–M7 与 M52 提供字符画实现，全部实现 `fountain::f_chart.Chart`，不引入第三方依赖。

| TUI 类 | `type` | 复用 |
|---|---|---|
| `TuiBarChart` | `bar` | `TuiBarRenderer`（Simple） |
| `TuiGroupedBarChart` | `grouped-bar` | `TuiBarRenderer`（Grouped） |
| `TuiStackedBarChart` | `stacked-bar` | `TuiBarRenderer`（Stacked） |
| `TuiPercentStackedBarChart` | `percent-stacked-bar` | `TuiBarRenderer`（PercentStacked） |
| `TuiLineChart` | `line` | `TuiPointCommon` + Bresenham |
| `TuiScatterChart` | `scatter` | `TuiPointCommon` |
| `TuiComboChart` | `combo` | 柱槽位 + 线/点叠加 + 右轴 |
| `TuiFlameChart` | `flame` | `FlameNode` + `flameColorIndex` / `heatColor` |

约定：

- `width` / `height` 为字符列/行，缺省 80×24，最小 20×8；`ChartConfig.parse` 新增 `defaultWidth` / `defaultHeight` 可选参数，SVG 调用不变。
- 子包可访问根包 `internal`（`ChartConfig`、`ChartJson`、`ChartScale`、`ChartTime`），不新增公开 JSON 字段。
- 画布 `TuiCanvas` 按显示宽度处理文本（CJK=2 列），输出 ANSI 24 位真彩色，每行 `ESC[0m\n`。
- 标记：柱族按系列 `█ ▓ ▒ ░`、折线 `*`、散点 `o`、网格 `·`、轴 `│ ─ └`、图例 `■`。
- 组合图要求类目横轴；柱族按 `bar`/`grouped-bar` 独立槽位、`stacked-bar` 按 `stack` 分组、`percent-stacked-bar` 合并为一个槽位；`axis: right` 使用 `yAxis2`。
- 火焰图按 `nodes` 单根树布局：`value / root.value` 映射列宽，层级映射行；`bottom-up` 根在底部，`top-down` 根在顶部；`frameHeight` 作为每层最大字符行数并压缩到可用高度；`colorBy = name` 按名称散列到调色板，`colorBy = value` 使用热力色阶；标签颜色按背景亮度选黑/白。
- TUI 的 `smooth` 仅接受不报错，字符网格按折线绘制。

测试策略：每个 TUI 类一个测试文件，另加 `TuiCanvas_test` / `TuiFrame_test` / `TuiConfig_test`；断言纯文本（`tuiStripAnsi`）与 ANSI 颜色序列，覆盖默认尺寸、CJK 截断、null 断开、负值、类型错误。

### 10.1 逐单元格接口

`draw` 返回 ANSI 字符串，宿主若要写进自己的缓冲需要解析转义并在宽字符上跳列，既慢又易错。
`TuiLineChart` 与 `TuiBarChart` 额外实现 `TuiCellChart`：

```cangjie
public interface TuiCellChart {
    func drawCells(data: JsonObject): Array<Array<String>>
}
```

`TuiCanvas.cellSymbols()` 负责生成矩阵：外层行、每行 `width` 个元素，宽字符的后半格是空串。
`draw` 仍走 `TuiCanvas.render()`，输出与既有用例逐字节一致；其余图表类暂不实现该接口。
