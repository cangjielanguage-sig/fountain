# Proposal

## Why

和弦图用圆周分段表示各实体的总流量、用内部带状线表示两两之间的有向流量，能同时呈现总量规模与流向结构，常用于城市迁移、贸易与通话关系分析。

## What Changes

- 新增 `ChordChart`，`type` 为 `chord`。
- 顶层 `nodes` + `links`；链接值构成有向流量矩阵。
- `padAngle` 控制分段间隔，默认 0.02；`showLabels` 默认 false。
- 外圈弧 class `chord-arc`，内部带状线 class `chord-ribbon`，标签 class `chord-label`。

## Capabilities

### New Capabilities

无。

## Modified Capabilities

- `chart-rendering`：新增和弦图需求。

## Impact

- 新增 `src/ChordChart.cj`、`src/ChordChart_test.cj`。
- 新增内部 `chordArcPath` / `chordWidth` 便于单测弧路径与带宽。
