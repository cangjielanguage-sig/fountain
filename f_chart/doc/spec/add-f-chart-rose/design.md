# Design

## 1. 数据

读取 `series[0].data` 为 `{name, value}` 列表；`value` 不小于 0、总和大于 0；`roseType` 仅接受 `radius` / `area`。

## 2. 半径映射

- `maxValue` 为数据最大值；`maxRadius` 取绘图区短边的 45%。
- `radius`：`roseRadius = maxRadius * value / maxValue`。
- `area`：`roseRadius = maxRadius * sqrt(value / maxValue)`。

## 3. 绘制

- 扇区角度均分 360°，从 −90° 起顺时针；每片 path 由中心、起始弧点、弧线、结束弧点闭合。
- 填充取主题调色板，描边白色 1px。
- 标签放在 0.65 倍半径处，文本为类目名。

## 4. 校验

`series` 数量不为 1、`data` 为空、`value` 为负或总和为 0 均抛 `InvalidValue`；`roseType` 非法同理。
