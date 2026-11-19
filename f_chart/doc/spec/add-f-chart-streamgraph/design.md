# Design

## 1. 数据

解析 `series[].data` 为等长数值数组，忽略 `null`；类目取 `xAxis.labels`，为空时生成 `1..n`。

## 2. 基线与堆叠

- 每列总量 `totals[x] = Σ values[s][x]`。
- `streamBaseline`：`zero` 返回 0；`symmetry` 返回 `-totals[x] / 2`；`wiggle` 在 `symmetry` 基础上做一次 `(b[x-1] + 2b[x] + b[x+1]) / 4` 平滑（边界复制）。
- 第 s 层在第 x 列的下界为 `baseline[x] + Σ_{i<s} values[i][x]`，上界再加本层值。

## 3. 绘制

- 上边界从左到右、下边界从右到左拼接为闭合 path。
- 填充取系列主题色、透明度 0.85，不描边。
- 纵轴范围覆盖所有层的上下界，缺省上下各留 5%。

## 4. 校验

`series` 为空、数据长度不一致、`baseline` 非法均抛 `ChartException`。
