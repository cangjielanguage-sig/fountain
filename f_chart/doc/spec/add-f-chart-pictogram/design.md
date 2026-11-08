# Design

## 1. 图标数量

`pictogramCount(value, unit) = ceil(value / unit)`；`value <= 0` 返回 0。

## 2. 布局

- 每个数据项占一个区块，自上而下排列。
- 区块内先画标签行（名称 + 数值），下方按 `columns` 列排布图标；图标 22px、间距 4px。
- 图标行数 `ceil(count / columns)`，区块高度按行数计算，块间距 12px。
- 超出绘图区高度的内容不额外缩放。

## 3. 图标形状

- `person`：头部弧线 + 肩部曲线的组合路径。
- `circle`：两段半圆弧组成整圆。
- `square`：矩形路径。
- 其它字符串：视为 SVG path，`d` 原样输出。

## 4. 校验

`unit` 必须大于 0，`columns` 正整数，`icon` 非空；`series` 非空、`data` 非空、`value` 非负。
