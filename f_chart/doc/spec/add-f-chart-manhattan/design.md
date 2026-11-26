# Design

## 1. 数据

解析 `x`、`y`、`chromosome`；`chromosomeGap` 必须非负；`threshold` 可选。

## 2. 位置映射

- 按染色体首次出现顺序分组，组内保持原始顺序。
- 每组跨度 `span = max(x) − min(x)`。
- 组起始偏移累加 `span + chromosomeGap`；显示位置为 `offset + (x − min)`。

## 3. 绘制

- 散点半径 3px，颜色按染色体索引奇偶在主题前两色间交替。
- 数据按显示位置排序后绘制折线？不画折线，只画散点。
- 阈值线为 `#e53935` 虚线，右端标注 `阈值`。
- x 轴刻度使用显示位置，标签保留原始数值格式不便，改为按显示位置生成 nice ticks。

## 4. 校验

`series` 数量不为 1、`data` 为空、`x`/`y` 非数字、`chromosome` 缺失或为空、`chromosomeGap` 为负均抛 `ChartException`。
