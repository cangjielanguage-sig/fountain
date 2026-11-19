# Tasks

> 每个任务按 Red-Green-Refactor 推进：先写用例并确认因「功能未实现」失败，再写最小实现，`cjpm test` 全绿后才勾选。禁止在项目外建单文件测试；用例放在对应模块的 `src/**/*_test.cj`。

## 1. `f_chart.tui`：画布单元格矩阵

- [x] 1.1 Red：在 `f_chart/src/tui/TuiCanvas_test.cj` 增加 `cellSymbols` 用例——3 列 × 2 行画布写入普通字符与一个 CJK 字符，断言外层 2 行、每行 3 个元素、CJK 后一格为 `""`、默认空格为 `" "`；验证：`cd f_chart && cjpm test` 该用例因方法不存在失败。
- [x] 1.2 Green：在 `TuiCanvas.cj` 实现 `internal func cellSymbols(): Array<Array<String>>`；验证：1.1 转绿，且既有 `plainLines`/`render` 用例不受影响。
- [x] 1.3 Red：新增 `f_chart/src/tui/TuiCellChart_test.cj`——`line` 40×12 的 `drawCells` 返回 12 行 × 40 元素、逐行过滤空串拼接等于 `draw` 去 ANSI 文本、所有元素不含 `ESC`、`width=10` 抛 `ChartException(InvalidValue)`；验证：用例失败。
- [x] 1.4 Green：新增 `f_chart/src/tui/TuiCellChart.cj` 接口；把 `TuiLineChart.draw` 主体抽为 `buildCanvas(data)`，`draw` 与 `drawCells` 复用之；声明 `TuiLineChart <: Chart & TuiCellChart`；验证：1.3 转绿。
- [x] 1.5 Red：在 `TuiBarChart_test.cj` 增加 `drawCells` 用例——40×12 `bar` 尺寸正确、包含 `█`、与 `draw` 符号一致；验证：失败。
- [x] 1.6 Green：`TuiBarRenderer` 抽出 `static func canvas(...): TuiCanvas`，`render` 改为 `canvas(...).render()`；`TuiBarChart` 实现 `TuiCellChart`，`drawCells` 调 `TuiBarRenderer.canvas(data, "bar", BarMode.Simple).cellSymbols()`；验证：1.5 转绿。
- [x] 1.7 回归：`cd f_chart && cjpm test` 全绿，确认既有 76 个 TUI 用例的 `draw` 断言（ANSI 序列、行数、显示宽度）逐字节不变。

## 2. `fprobe`：`ChartPanel` 适配器

- [x] 2.1 Red：新增 `fprobe/src/tui/ChartPanel_test.cj`——`chartJson` 含 `type`/`width`/`height`，`series[0].name` 与 `data` 等于入参，`title` 为空且 `xAxis.labels` 为空；空序列、空数值、`19×8`、`20×7`、未知类型均返回 `None`；验证：失败（类与方法不存在）。
- [x] 2.2 Green：`ChartPanel.chartJson` 直接用 `JsonObject`/`JsonArray` 构造图表 JSON（`type`/`title`/`width`/`height`/`xAxis.type=category`/单具名系列），不依赖 `fprobe.report`，避免 `tui ↔ report` 循环依赖。
- [x] 2.3 Red：在 `ChartPanel_test.cj` 增加渲染用例——`line` 返回 `height` 行且每行 `width` 元素并包含 `*`/`o`；`bar` 包含 `█`；验证：失败。
- [x] 2.4 Green：新增 `fprobe/src/tui/ChartPanel.cj`，实现 `MIN_WIDTH=20`、`MIN_HEIGHT=8`、`chartJson(...)` 与 `render(...)`，捕获 `ChartException`/`Exception` 返回 `None`；验证：2.3 转绿，`cd fprobe && cjpm test` 本组用例通过。

## 3. `RenderPlan`：页面图表意图与高度

- [x] 3.1 Red：在 `fprobe/src/tui/ViewModel_test.cj` 增加 `MetricPage.chartType()` 表驱动用例——CPU/内存/网络/服务/健康为 `line`，磁盘为 `bar`，拓扑/告警为 `""`；验证：失败。
- [x] 3.2 Green：在 `MetricPage` 实现 `chartType()`；验证：3.1 转绿。
- [x] 3.3 Red：新增 `fprobe/src/tui/TuiLayout_test.cj`——`viewportHeight=24` 且 6 个指标 → 13；`12` 且 6 个 → 1；`0` → 0；指标行数吃满时不为负；验证：失败。
- [x] 3.4 Green：新增 `TuiLayout.cj`（`MIN_CHART_HEIGHT=8`、`innerHeight`、`chartHeight`），实现上述公式；验证：3.3 转绿。
- [x] 3.5 Red：在 `RenderPlan_test.cj` 增加字段用例——CPU 页 `chartType="line"`、`chartSeries` 为第一条序列、`chartHeight` 随 `viewportHeight` 变化；磁盘 `bar`；拓扑/告警 `chartType=""`、`chartSeries=None`、`chartHeight=0`；验证：失败。
- [x] 3.6 Green：`RenderPlan` 追加 `chartType`/`chartSeries`/`chartHeight`（带默认值）；`RenderPlanBuilder.build` 增加 `viewportHeight: Int64 = 0` 并填充三字段；验证：3.5 转绿，既有 `RenderPlan` 构造调用仍编译。
- [x] 3.7 Green：`Painter` 增加 `viewportHeight(): Int64`；`FprobePainter` 返回渲染器高度、`NullPainter` 返回 0；`RenderLoop.renderOnce()` 把该值传给 builder；同步 `RecordingPainter`、`SlowPainter` 等测试替身；验证：`cd fprobe && cjpm test` 编译通过，新增 `RenderLoop` 用例断言高度被传入。

## 4. `FprobePainter`：单元格写入与回退

- [x] 4.1 Red：在 `FprobePainter_test.cj` 增加假 `chartRender` 用例——80×24、CPU plan、`chartHeight=10`，假矩阵含空串；断言 `A`/`B` 写在预期坐标、空串列不写且后续列不左移、调用高度参数为 `min(10, 实际剩余)`；验证：失败。
- [x] 4.2 Green：`FprobePainter` 构造增加 `chartRender` 注入点（默认 `ChartPanel.render`），实现 `paintCells`；验证：4.1 转绿。
- [x] 4.3 Red：增加回退用例——12 行终端使 `chartHeight<8` 时出现 `▁..█` 且假 chart 未被调用；`chartSeries=None` 或假 chart 返回 `None` 时回退；回退时仍绘制该页全部序列；验证：失败。
- [x] 4.4 Green：调整 `paintMetrics` 为「指标表 → 空白 → 图表或 sparkline」，加入 `available` 下限判断；验证：4.3 转绿。
- [x] 4.5 回归：更新 `samplePlan()` 等既有构造（如需显式图表字段），确认边框、表格、选中高亮、footer 断言不变；`cd fprobe && cjpm test` 全绿。

## 5. 文档、镜像与验收

- [x] 5.1 更新 `f_chart/README.md` 与 `f_chart/doc/f_chart模块设计.md`：说明 `TuiCellChart`、矩阵语义、宽字符续格，以及 `draw` 行为不变。
- [x] 5.2 更新 `fprobe/doc/tui.md`：右侧指标区改为「表格 + 多行图表」，补充页面类型映射、8 行/20 列阈值与 sparkline 回退。
- [x] 5.3 把本变更的 `proposal.md`、`specs/**`、`design.md`、`tasks.md` 原样镜像到 `fprobe/doc/spec/add-fprobe-tui-charts/`，目录结构与 `openspec/changes/add-fprobe-tui-charts/` 一致。
- [x] 5.4 执行 `openspec validate add-fprobe-tui-charts --strict`（该 worktree 已有 `openspec/config.yaml`）。
- [x] 5.5 全量验收：`cd f_chart && cjpm test` 与 `cd fprobe && cjpm test` 均全绿；抽查 80×24 终端下 CPU（多行折线）、磁盘（柱状）、拓扑（无图）、16 行终端（sparkline）四种画面。

## 6. 提交

- [x] 6.1 在集成分支 `feature/fprobe` 上按任务组独立提交（每个提交都含已通过的用例）；本变更不新建分支、不合并 `master`。
