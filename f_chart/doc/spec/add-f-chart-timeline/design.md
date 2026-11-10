# Design

## 1. 数据

解析 `events` 的 `date`、`title`、可选 `description` 与 `group`；`date`、`title` 必须为字符串。

## 2. 水平布局

- 轴线为 `y = plot.centerY()` 的水平线。
- 事件 x 坐标在 plot 内等距分布，首尾各留 40px。
- 偶数索引事件在轴上方，奇数在轴下方；点上方的顺序为日期、标题、描述，下方顺序为标题、描述、日期。
- 文本锚点为 `middle`，描述按可用宽度截断。

## 3. 垂直布局

- 轴线为 `x = plot.x + 72` 的竖线。
- 事件 y 坐标在 plot 内等距分布。
- 日期在轴左侧（右对齐），标题与描述在轴右侧。

## 4. 颜色

事件点与标题颜色按 `group` 散列到主题调色板，无 `group` 时按事件下标取色。

## 5. 校验

`events` 为空、`date`/`title` 缺失或非字符串、`orientation` 非法均抛 `ChartException`。
