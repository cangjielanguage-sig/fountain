# Tasks

- [x] 1.1 Red：写 `GroupedBarChart_test.cj`（6 根柱、同组不重叠、共享轴、图例、错误、确定性）
- [x] 1.2 运行 `cjpm test --no-run` 确认 `GroupedBarChart` 缺失
- [x] 2.1 抽出 `BarRenderer`，支持 simple/grouped 模式
- [x] 2.2 `BarChart` 改为薄封装，M1 用例保持全绿
- [x] 2.3 `GroupedBarChart` 实现并转绿
- [x] 3.1 `cjpm build` + `cjpm test` 全绿
- [x] 3.2 `openspec validate add-f-chart-grouped-bar --strict`
- [x] 3.3 同步四件套到 `doc/spec/add-f-chart-grouped-bar/`
- [x] 3.4 `openspec archive add-f-chart-grouped-bar`
- [x] 3.5 提交
