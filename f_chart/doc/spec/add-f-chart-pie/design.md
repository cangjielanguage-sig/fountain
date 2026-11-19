# Design

## 1. 占比

`total = Σvalue`；`fraction = value / total`；起始角从 12 点方向（-90°）加 `startAngle`。

## 2. 扇区

- 半径取绘图区短边的一半减去标签边距。
- 路径：`M cx cy L p0 A r r 0 largeArc 1 p1 Z`，class `pie-slice`。
- 颜色取调色板轮转。

## 3. 标签

- 中点角度、半径 0.65 处放置文本，class `pie-label`。
- `showPercent` 为 true 显示一位小数百分比，否则显示类别名。
