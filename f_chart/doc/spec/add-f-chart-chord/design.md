# Design

## 1. 角度分配

- 节点总量为该节点作为 source 或 target 的 value 之和。
- `total = Σ 节点总量`；可用角度为 `2π - padAngle * 节点数`。
- 每个节点分得 `节点总量 / total * 可用角度`，分段之间各留 `padAngle / 2` 的间隔。
- 从 `-π/2` 开始按输入顺序排列。

## 2. 外圈

`chordArcPath(cx, cy, r, start, end)` 生成 `M ... A r r 0 largeArc 1 ...` 路径；用 14px 描边绘制，颜色按节点调色板。

## 3. 带状线

从 source 分段中点到 target 分段中点画二次贝塞尔曲线，控制点取圆心；线宽 `chordWidth(value, maxValue) = 1 + 6 * sqrt(value / maxValue)`，描边透明度 0.35。

## 4. 标签

`showLabels` 为 true 时在分段中点外侧 16px 处写节点名。
