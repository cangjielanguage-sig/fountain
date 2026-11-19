# Design

## 1. 模块边界

```
f_chart
├── f_svg      SVG 1.1 文档生成（SvgBuilder / SvgDocument / SvgWriter）
├── f_data     JSON 解析与 JsonObject / JsonArray / JsonValue
└── f_base     BaseException
```

- 包名 `fountain::f_chart`，动态链接库，版本与仓库一致。
- 不引入第三方绘图库；所有图元最终落到 `f_svg` 的 `SvgBuilder`。
- 不修改 `f_svg` / `f_data` 的公开 API。

## 2. 目录与文件约定

```
f_chart/
├── cjpm.toml
├── README.md / README_en.md
├── doc/
│   ├── f_chart模块设计.md
│   ├── chart-json-spec.md
│   └── spec/<change-name>/...
└── src/
    ├── Chart.cj                 M0 接口
    ├── ChartException.cj        统一异常
    ├── ChartJson.cj             JSON 读取助手（internal）
    ├── ChartTheme.cj            调色板 / 主题（internal）
    ├── ChartFrame.cj            坐标框、轴、网格、图例（internal）
    ├── ChartScale.cj            线性 / 对数 / 分段 / 带状比例尺（internal）
    ├── ChartSvgKit.cj           SVG 输出助手（internal）
    ├── BarChart.cj              M1
    ├── GroupedBarChart.cj       M2
    ├── ...
    └── BarChart_test.cj         与实现同名的测试
```

- 一个图一个源文件，公开类型与文件名一致（如 `BarChart`）。
- 公共基础设施全部 `internal`，不对外暴露；后续图只能依赖接口与 internal 助手。
- 测试文件 `<图名>_test.cj` 放在 `src/`，包内可见 internal 助手。

## 3. M0 契约

```cangjie
package fountain::f_chart

import fountain::f_data.json.JsonObject

public interface Chart {
    func draw(data: JsonObject): String
}
```

- 接口只约束输入输出，不约束内部如何组织。
- `draw` 必须是纯函数语义：不修改入参，不依赖全局可变状态；同一输入产生确定性输出（便于黄金文件测试）。
- 失败统一抛 `ChartException`，不返回空串或半成品 SVG。

`ChartException` 设计：

```cangjie
public enum ChartErrorKind {
    | InvalidJson
    | MissingField
    | InvalidValue
    | UnsupportedChart
}

public class ChartException <: BaseException {
    public let kind: ChartErrorKind
    public let path: String   // 如 "series[0].data[2]"
}
```

## 4. JSON 信封

所有图共用以下顶层字段（详见 `doc/chart-json-spec.md`）：

| 字段 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `type` | string | 是 | 图类型判别符 |
| `title` | string \| object | 否 | 标题 / 副标题 |
| `width` | number | 否 | 默认 800 |
| `height` | number | 否 | 默认 480 |
| `padding` | object | 否 | 画布内边距 |
| `theme` | object | 否 | 背景、调色板、字体、颜色 |
| `legend` | object | 否 | 是否显示、位置、方向 |
| `xAxis` | object | 视图而定 | 类目 / 数值 / 时间轴 |
| `yAxis` | object | 视图而定 | 数值轴 |
| `series` | array | 视图而定 | 数据系列 |
| `annotations` | array | 否 | 文本、参考线、参考带 |

- 笛卡尔图使用 `xAxis` / `yAxis` / `series`。
- 非笛卡尔图（饼图、桑基、网络、地图等）沿用 `series` 承载数据，省略轴字段；专属结构放 `series[0]` 或顶层专属字段（如 `nodes` / `links`），在文档中逐图声明。
- `series[].data` 的形状由 `type` 决定：类目图为数值数组；XY 图为 `{x,y}` 对象数组；层级 / 网络图为专属对象数组。文档为每个图给出完整示例。

## 5. 公共渲染管线

每个图的 `draw` 遵循同一顺序：

1. `ChartJson` 读取并校验信封字段，错误带字段路径。
2. 计算画布与绘图区（`ChartFrame`：标题、图例、轴标签占位）。
3. 由 `ChartScale` 把数据值映射到像素。
4. 图实现用 `ChartSvgKit` 往 `SvgBuilder` 写入图元。
5. `SvgBuilder.toSvgString()` 输出，确保 `viewBox` 与宽高一致。

`ChartFrame` 负责：背景、标题、副标题、绘图区边框、网格线、刻度、轴标题、图例。图实现只负责数据图元，避免每个图重复坐标轴代码。

## 6. 里程碑与文件映射

| 里程碑 | 图 | 文件 |
|---|---|---|
| M0 | 接口 | `Chart.cj` |
| M1 | 柱状图 | `BarChart.cj` |
| M2 | 分组柱状图 | `GroupedBarChart.cj` |
| M3 | 堆叠柱状图 | `StackedBarChart.cj` |
| M4 | 百分比堆叠柱状图 | `PercentStackedBarChart.cj` |
| M5 | 折线图 | `LineChart.cj` |
| M6 | 散点图 | `ScatterChart.cj` |
| M7 | 六图组合 | `ComboChart.cj` + 复用 M1–M6 |
| M8–M10 | 甘特 / 流程 / 时序 | `GanttChart.cj` / `Flowchart.cj` / `SequenceChart.cj` |
| M11–M13 | 条形 / 点图 / 雷达 | `HorizontalBarChart.cj` / `DotChart.cj` / `RadarChart.cj` |
| M14–M16 | 面积 / 堆叠面积 / 瀑布 | `AreaChart.cj` / `StackedAreaChart.cj` / `WaterfallChart.cj` |
| M17–M30 | 分布、关系 | 每个 M 一个文件，见 `chart-json-spec.md` |
| M31–M36 | 构成、层级、流向 | 每个 M 一个文件 |
| M37–M51 | 诊断、模型评价 | 每个 M 一个文件 |
| M52–M56 | 火焰图族 | 每个 M 一个文件 |
| M57–M61 | 地图族 | 每个 M 一个文件 |
| M62–M71 | 网络、层级 | 每个 M 一个文件 |
| M72–M87 | 构成变体、时间流程 | 每个 M 一个文件；重复别名复用同一实现 |
| M88–M106 | 分布补充、模型评价、文本 | 每个 M 一个文件；重复别名复用同一实现 |

合并用户清单中的重复项（同一实现、不同 `type` 别名）：

| 别名 | 复用实现 |
|---|---|
| M67 桑基图 | `SankeyChart` |
| M86 漏斗图 | `FunnelChart` |
| M87 瀑布图 | `WaterfallChart` |
| M104 标签云 | `WordCloudChart` |
| M106 热力图日历 | `CalendarHeatmapChart` |

M93 在清单中出现两次：`ManhattanChart`（曼哈顿图）与 `ConfusionMatrixChart`（混淆矩阵），两者都保留，文档以 `manhattan` / `confusion-matrix` 区分。

## 7. 每个图的 OpenSpec + TDD 流程

每个 M 独立一个 change：

1. `openspec new change "add-f-chart-<type>"`。
2. proposal / specs / design / tasks 四件套，spec 增量写入 `chart-rendering` 能力。
3. 评审后 apply：
   - 先写 `<Chart>_test.cj`，覆盖：最小 JSON、默认尺寸、单个数据点、空数据、非法类型、非法数值、确定性输出、可被 `SvgParser` 解析。
   - 运行 `cjpm test` 观察失败（Red）。
   - 最小实现到绿（Green），再重构公共助手。
4. `cjpm test` 全绿 + `openspec validate --strict` → verify → archive。
5. 四件套同步到 `f_chart/doc/spec/<change-name>/`。

## 8. 测试策略

- 单元测试为主：每个图至少 6 个用例（正常、边界、错误、确定性、SVG 可解析、主题/图例开关）。
- 黄金文件只用于结构复杂且易回归的图（M7 组合、M9 流程图、M10 时序图、M36 桑基、M85 泳道），放 `testdata/`，比较前统一换行与数值格式。
- 公共助手单独测试（比例尺、刻度、图例布局、数值格式化）。
- 所有测试跑在 `f_chart` 模块内，不创建项目外单文件测试。

## 9. 兼容与风险

- 新增模块，无兼容负担。
- 风险：106 个图字段容易漂移。对策：`ChartJson` 统一读取、`chart-json-spec.md` 作为唯一字段真相、每个图的测试锁定 JSON 形状。
- 风险：图元重叠 / 标签溢出。对策：`ChartFrame` 统一做边距与标签旋转，测试覆盖密集类目与小画布。
- 风险：不同图对同一字段解释不一致。对策：信封字段语义在文档中固定，图专属字段必须加前缀或在文档中显式声明。
