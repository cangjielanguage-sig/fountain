# Design

## 1. 树与总量

- 叶子总量为其 `value`；非叶子总量为子节点总量之和。
- 非叶子的 `value` 字段忽略。

## 2. 角度

- 根节点占据整圆，从 `-π/2` 开始。
- 子节点按 `sort` 排序后，按 `总量 / 父节点总量` 分配父节点的角度区间。

## 3. 半径

- 外半径取绘图区短边的 0.45 倍。
- 内孔半径为 `outer * innerRadius`。
- 每个层级环宽为 `(outer - innerHole) / maxDepth`。

## 4. 绘制

`sunburstArcPath(cx, cy, innerR, outerR, start, end)` 生成外弧 + 内弧闭合路径；颜色按节点名散列，一级节点在环带中心写标签。
