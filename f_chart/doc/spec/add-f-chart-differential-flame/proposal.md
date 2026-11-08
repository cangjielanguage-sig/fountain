# Proposal

## Why

差分火焰图对比两次剖析结果，用红蓝颜色标出各调用栈耗时的增减，能快速定位版本升级后变慢或变快的代码路径。

## What Changes

- 新增 `DifferentialFlameChart`，`type` 为 `differential-flame`。
- `nodes` 的元素为 `{id, name, parent, value1, value2}`；`delta = value2 - value1`。
- 宽度按 `value2` 分配；颜色按 `delta` 相对最大绝对差值映射，红色表示增加、蓝色表示减少。
- `colorRange` 支持 `[减少色, 增加色]` 或 `[减少色, 中性色, 增加色]`。
- 节点矩形 class `diff-flame-node`，标签 class `diff-flame-label`。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `chart-rendering`：新增差分火焰图需求。

## Impact

- 新增 `src/DifferentialFlameChart.cj`、`src/DifferentialFlameChart_test.cj`。
- 新增内部 `differentialColor` 便于单测颜色映射。
