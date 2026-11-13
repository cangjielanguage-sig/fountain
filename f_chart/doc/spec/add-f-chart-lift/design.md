# Design

## 1. 数据

解析 `series[0].data` 的 `x`、`y`；`baseline` 默认 1、必须大于 0。

## 2. 轴

- x 轴缺省范围 0 到 1；给了数据超出时扩展到数据最小/最大值。
- y 轴覆盖全部 `y` 与 `baseline`，上下各留 8%。

## 3. 绘制

- 折线按 `x` 升序连接，线宽 2px，颜色取主题第一色。
- 数据点半径 3.5px，同色。
- 基准线为 `#9e9e9e` 虚线，右端标注 `baseline`。

## 4. 校验

`series` 数量不为 1、`data` 为空、`x`/`y` 非数字、`baseline` 非正均抛 `ChartException`。
