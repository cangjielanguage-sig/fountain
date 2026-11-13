## ADDED Requirements

### Requirement: 逐单元格绘制接口

模块 MUST 提供公开接口 `fountain::f_chart.tui.TuiCellChart`，方法签名为 `func drawCells(data: JsonObject): Array<Array<String>>`。`TuiLineChart` 与 `TuiBarChart` MUST 实现该接口，并 MUST 继续实现 `fountain::f_chart.Chart`。

`drawCells` MUST 返回字符网格：外层数组长度等于画布 `height`，每行元素数等于画布 `width`；元素为单元格符号，宽字符的后半格 MUST 为空字符串；输出 MUST NOT 包含 ANSI 转义序列。

同一份 JSON 输入下，`drawCells` 与 `draw` MUST 表达同一幅图：把矩阵每行中的空字符串去掉后按顺序拼接，结果 MUST 等于 `draw` 输出去除 ANSI 转义后的对应文本行。

`draw` 的返回 MUST 保持既有行为：ANSI 24 位真彩色、行尾复位与换行、行数与显示宽度符合 `width` / `height`。

#### Scenario: 折线图矩阵尺寸

- **WHEN** 用 `width = 40`、`height = 12` 的 `line` JSON 调用 `TuiLineChart().drawCells`
- **THEN** 返回 12 行，每行恰好 40 个元素

#### Scenario: 柱状图矩阵尺寸

- **WHEN** 用 `width = 40`、`height = 12` 的 `bar` JSON 调用 `TuiBarChart().drawCells`
- **THEN** 返回 12 行，每行恰好 40 个元素

#### Scenario: 与 draw 的符号一致

- **WHEN** 同一份 JSON 分别调用 `draw` 与 `drawCells`
- **THEN** 矩阵逐行去掉空字符串后拼接的文本，等于 `draw` 输出去除 ANSI 后按行拆分的对应文本

#### Scenario: 宽字符后半格

- **WHEN** 图表标题或类目标签含中文，且该字符完整落在画布内
- **THEN** 该字符所在行存在一个空字符串元素，其前一个元素为该宽字符
- **AND** 该行元素总数仍等于画布宽度

#### Scenario: 矩阵不含 ANSI

- **WHEN** 调用任意 `drawCells`
- **THEN** 所有元素都不含 `ESC`（`\u{1B}`）

#### Scenario: draw 行为不变

- **WHEN** 运行既有的 TUI 图表用例
- **THEN** `draw` 的颜色序列、标记字符、行数与每行显示宽度与变更前一致

#### Scenario: 尺寸不足

- **WHEN** JSON 的 `width < 20` 或 `height < 8`
- **THEN** `drawCells` 与 `draw` 一样抛出 `ChartException`，`kind` 为 `InvalidValue`
