# Design

## 1. 数据

与 `ViolinChart` 一致：嵌套数组按组解析，扁平数组视为单组；每组非空且全为数值。

## 2. 偏移

- `swarmOffsets(count, jitter, side)` 生成锯齿序列：0、+1、-1、+2、-2…（按 side 取单侧或双侧），再归一化到最大绝对值 `jitter`。
- 点 x = 类别中心 + 偏移 × 类别半宽。

## 3. 绘制

- 点半径 3，class `swarm-point`，颜色取系列色或调色板首位。
- y 范围覆盖全部数据并留 5% 余量；x 轴复用 `drawXAxis`。
