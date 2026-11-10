# Design

## 1. 统计

- 每对 `(x, y)`：`mean = (x + y) / 2`、`diff = y - x`。
- `meanDiff` 为差值均值，`sd` 为样本标准差（分母 `n − 1`），`n = 1` 时 `sd = 0`。
- 界限为 `meanDiff ± 1.96 * sd`。

## 2. 轴

- x 轴范围覆盖全部 `mean`，两侧各留 5%。
- y 轴范围覆盖全部 `diff` 与两条界限，上下各留 8%。

## 3. 绘制

- 散点半径 3.5px，主题第一色。
- 均值线实线 `#4caf50`，界限线虚线 `#e53935`，线宽 1px。
- 三条线右端标注数值，使用 `chartFormatTick` 格式化。

## 4. 校验

`series` 数量不为 1、`data` 为空、`x`/`y` 缺失或非数字均抛 `ChartException`。
