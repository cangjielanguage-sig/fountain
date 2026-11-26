# Design

## 1. 几何

- 中心为绘图区中心，半径 `min(plot.width, plot.height)/2 - 30`。
- 第 i 条轴角度 `-90° + i * 360°/n`，使用 `cos/sin` 计算顶点。
- 网格 4 层（0.25/0.5/0.75/1.0），每层一个闭合多边形。
- 指标标签放在 1.0 半径外 14px，按象限选择锚点。

## 2. 系列

- `data[i]` 归一化为 `clamp(value/max, 0, 1)`，得到半径。
- 多边形 class `radar-area`，填充色用系列色+`fill-opacity=0.2`，描边 2px。
- 顶点圆 `class="symbol"`。

## 3. 校验

indicators 非空、max>0；series data 长度必须等于指标数；否则 InvalidValue。
