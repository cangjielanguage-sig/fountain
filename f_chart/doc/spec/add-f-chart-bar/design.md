# Design

## 1. 文件

| 文件 | 职责 |
|---|---|
| `src/ChartJson.cj` | 带字段路径的 JSON 读取与校验 |
| `src/ChartConfig.cj` | 通用信封：type/title/width/height/padding/theme/legend/axis |
| `src/ChartTheme.cj` | 调色板、字体、颜色默认值 |
| `src/ChartScale.cj` | 线性比例尺、类目比例尺、nice ticks、数值格式化 |
| `src/ChartFrame.cj` | 标题、图例、绘图区、网格、轴、刻度 |
| `src/ChartSvgKit.cj` | `SvgBuilder` 上的文本/矩形/线/路径助手 |
| `src/BarChart.cj` | M1 柱状图 |
| `src/BarChart_test.cj` | M1 测试 |

## 2. 为什么不用 `@DataAssist`

`f_data.macros` 的宏库在鸿蒙沙箱内无法被 `cjc` `dlopen`（`Permission denied`），
`@DataAssist` 不可用。图表 JSON 的 `series[].data` 本身是随图类型变化的动态结构，
因此统一用 `ChartJson` 读取：固定字段仍映射到强类型 `ChartConfig`，只有数据数组保留
`JsonValue` 的动态访问，且所有错误都带字段路径。

## 3. 解析与校验

`ChartJson` 提供：

```cangjie
ChartJson(obj).string("title")
ChartJson(obj).number("width", default: 800.0)
ChartJson(obj).numberArray("series[0].data")
ChartJson(obj).requiredArray("series")
```

- 每个读取方法接收逻辑路径，错误消息形如 `series[0].data[2]: 期望数字`。
- 数字接受 `JsonInt` 与 `JsonDecimal`，拒绝 `NaN` / `Inf`。
- 缺失必填字段抛 `MissingField`；类型不符抛 `InvalidValue`。

`ChartConfig.parse` 读取：`type`、`title`（字符串或对象）、`width`、`height`、
`padding`、`theme`、`legend`、`xAxis`、`yAxis`。缺省值按规范第 2 节。

## 4. 柱状图布局

1. 画布 `(width, height)`，默认 800×480；`padding` 默认 24。
2. 标题占顶部；图例按 `position` 占上/下/左/右。
3. 剩余区域为绘图区。左边距按 y 轴刻度文本最大宽度估算，底边距按 x 标签高度
   （含旋转）估算；最小边距 40。
4. `BandScale` 把 `n` 个类目映射到绘图区宽度，`bandWidth = plotW / n`，
   柱宽 = `series.barWidth` 或 `bandWidth * 0.6`，柱在槽内居中。
5. `LinearScale` 把数值映射到绘图区高度。y 轴范围：
   - 显式 `min` / `max` 优先；
   - 否则下界 = min(0, 数据最小值)，上界 = max(0, 数据最大值) 并留 5% 余量；
   - 全为 `null` 时用 `[0, 1]`。
6. 刻度用 nice 算法取 1/2/5×10ⁿ，默认 `tickCount = 5`。
7. 柱：`x = bandStart + (bandWidth - barW)/2`；正值 `y = scale(value)`、
   `height = baseline - y`；负值 `y = baseline`、`height = scale(value) - baseline`。
8. 颜色：`series.color` > `theme.palette[i % palette.size]`。
9. 图例：单系列且 `name` 为空时隐藏；否则在指定位置画色块 + 名称。

## 5. SVG 输出

- `SvgBuilder(width, height, viewBox: SvgViewBox(0, 0, width, height))`。
- 背景 `rect` 覆盖整幅，`fill = theme.background`（`none` 时不画）。
- 每个图元带 `class`：`bar`、`grid`、`axis`、`tick-label`、`legend-item`、`title`，
  便于测试与下游 CSS。
- 文本统一 `font-family`、`font-size`、`fill`；数值格式固定 3 位小数以内并去尾零，
  保证确定性。
- 最终 `builder.toSvgString()`。

## 6. 测试

`BarChart_test.cj` 覆盖：

1. 三根柱的 `class="bar"` 数量；
2. 默认 800×480 与显式尺寸；
3. x 标签文本存在；
4. 调色板首色；
5. 网格线数量；
6. 标题；
7. 类型不匹配、`series` 缺失、非数值、长度不一致的错误 kind/path；
8. 负值柱方向；
9. `null` 跳过；
10. 两次输出逐字节一致；
11. `SvgParser.parse` 成功；
12. 单系列无名隐藏图例。

运行方式（鸿蒙）：

```bash
cjpm test --no-run
python3 ~/tmp_sign/sign_elfs.py target/release
cjpm test --skip-build
```
