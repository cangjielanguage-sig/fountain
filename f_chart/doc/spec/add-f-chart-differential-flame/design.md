# Design

## 1. 树与宽度

- 与火焰图相同的树构建与校验，额外校验 `value1` / `value2` 各自满足父节点不小于子节点之和。
- 宽度以 `value2` 为基准（新版本剖析宽度）；根 `value2` 为 0 时退回 `value1`。

## 2. 差值颜色

- `delta = value2 - value1`，`maxAbs` 为所有节点 `|delta|` 的最大值。
- `colorRange` 两个颜色时按 `[减少, 增加]`，中性色取 `#f0f0f0`；三个颜色时按 `[减少, 中性, 增加]`。
- 正差值从中心色插值到增加色，负差值从中心色插值到减少色，复用 `heatmapColor`。

## 3. 布局与文字

- 自底向上布局，`y = plot.bottom - (depth + 1) * frameHeight`。
- 节点名称在宽度足够时写入左侧内边距，class `diff-flame-label`；深色块用白字。
