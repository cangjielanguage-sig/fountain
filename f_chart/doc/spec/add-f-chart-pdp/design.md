# Design

## 1. 数据

解析 `series[0].data` 的 `x`、`y`，按 `x` 升序排序；`feature` 为可选字符串。

## 2. 轴

- x 轴覆盖全部特征值，两侧各留 3%。
- y 轴覆盖全部预测值，上下各留 8%。
- 支持 `xAxis` / `yAxis` 的 `min`、`max`、`values`。

## 3. 绘制

- 折线 2px 主题第一色，数据点半径 3.5px。
- 特征标注写在绘图区左上角，颜色为主题文本色、字号减 1。

## 4. 校验

`series` 数量不为 1、`data` 为空、`x`/`y` 非数字均抛 `ChartException`。
