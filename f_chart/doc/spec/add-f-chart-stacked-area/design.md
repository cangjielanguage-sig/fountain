# Design

## 1. 数据

只支持类目模式：`xAxis.labels` 或按最长系列生成。每个系列解析为数值数组，`null` 记为 0。长度必须一致。

## 2. 累加

- 按 `stack` 分组（空字符串视为默认组）。
- 对每个类目，每组维护 `cum`；系列 i 的区间为 `[cum, cum + value]`，随后 `cum += value`。
- 前一层用系列色填充，顶边描边 class `line`，填充 class `stacked-area`。

## 3. 范围

`stackedAreaBounds(groups, values)` 遍历所有类目与组，记录 `cum` 的最大/最小值，返回 `[min, max]` 并保证包含 0。

## 4. 绘制

- 面积路径：下边界反向遍历 + 上边界正向遍历，闭合。
- 类目轴复用 `ChartFrame.drawXAxis`；y 轴复用 `drawYAxis` / `drawGrid`。
