## Context

M106 在文档索引中是 M44 的重复条目，`type` 同为 `calendar-heatmap`，实现文件同为 `CalendarHeatmapChart.cj`。若为其虚构新类型会破坏文档一致性，因此按「里程碑闭合」处理：只增加 OpenSpec 记录与回归测试。

## Decisions

- 不修改 `CalendarHeatmapChart` 与 `ChartConfig`。
- 回归测试独立为 `CalendarHeatmapAlias_test.cj`，与 M86/M87/M104 的别名测试方式一致。
- 测试选择文档示例（跨 3 个月、90 天），可同时校验日格与月份/星期标签。

## Risks

- 该测试与 M44 测试存在重叠；这是别名里程碑的预期冗余，用于锁定文档口径。
- 若 M44 行为变更，本测试会同步失败，提示需要复核两条里程碑。

## Testing

- 断言 `calendar-cell` 数量、`month-label` 数量、`weekday-label` 数量、最高值颜色与非法类型。
- 全量回归在签名后执行 `cjpm test --skip-build`。
