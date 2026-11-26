## Context

M1–M7 的 SVG 实现已完成，JSON 契约稳定。TUI 版本需要在字符网格中复用同一份 JSON、同一套比例尺与刻度算法，并输出可直接打印到终端的 ANSI 字符串。`ratatui-cj` 在当前工具链下依赖解析崩溃（多个包触发 cjpm SIGTRAP），因此不引入第三方 TUI 库。

## Decisions

### 1. 子包与复用边界

- 目录 `f_chart/src/tui/`，包名 `fountain::f_chart.tui`；子包可访问根包的 `internal` 类型（已验证），因此直接复用：
  - `ChartConfig` / `ChartJson` / `ChartException`
  - `BandScale` / `LinearScale` / `chartNiceTicks` / `chartFormatTick`
  - `ChartTime`（时间轴转天数）
- 不修改 SVG 实现，不新增 JSON 字段；TUI 专属行为只在子包内。
- 唯一根包改动：`ChartConfig.parse` 增加 `defaultWidth` / `defaultHeight` 可选参数（`internal` 调用面不变），让 TUI 使用 80×24 字符默认值而不是 800×480 像素。

### 2. 画布模型

- `TuiCanvas` 持有 `width × height` 个 `TuiCell`。
- `TuiCell`：`symbol: String`、`color: String`、`continuation: Bool`。
- CJK/全角字符占 2 列：首格写字符，次格标记 `continuation = true`；渲染时跳过续格。
- 文本写入按显示宽度推进；右边界不足时截断并补 `…`（若只放得下 1 列则写 `…`）。
- 颜色统一存 CSS 颜色字符串，渲染时用 `SvgColor.parse` 转 RGB。

### 3. ANSI 编码

- 颜色格式：`\u{1B}[38;2;R;G;Bm`。
- 每行按相同颜色的连续段合并转义，行尾 `\u{1B}[0m`，行末 `\n`；空行仅输出 `\u{1B}[0m\n`。
- 背景保持终端默认，不输出背景色。

### 4. 布局

- 画布即终端字符网格；`width`/`height` 缺省 80×24，最小 20×8。
- 行分配：标题（1 行）→ 副标题（可选 1 行）→ 图例（可选 1 行）→ 绘图区 → 横轴标签（1 行）→ 横轴标题（可选 1 行）。
- 左边距 = 最长纵轴刻度标签显示宽度 + 2；绘图区右边界 = `width - 1`。
- 纵轴：`LinearScale(min, max, plot.top, plot.bottom)`，刻度用 `chartNiceTicks`；每档画 `·` 网格与右对齐刻度标签。
- 横轴：类目用 `BandScale`，数值/时间用 `LinearScale`；底部画 `─` 与刻度 `┬`，标签按可用宽度截断，类目过多时按 `ceil(n / 可用列数 × 2)` 抽稀。
- 轴角 `└`，纵轴 `│`。

### 5. 标记字符

| 元素 | 字符 |
|---|---|
| 柱体 | `█` |
| 折线 | `*` |
| 数据点 | `o` |
| 散点 | `o` |
| 网格 | `·` |
| 图例色块 | `■` |

折线用整数 Bresenham；同列多段时后写覆盖先写。`smooth` 接受但按折线绘制（字符网格无法有意义地表达贝塞尔曲率）。

### 6. 柱族渲染

- `TuiBarRenderer.render(data, expectedType, mode)`：`Simple` / `Grouped` / `Stacked` / `PercentStacked`。
- 基线：数据全正为 0；含负值时 0 位于比例尺内对应行。
- 柱宽：`max(1, floor(bandWidth × 0.6))`；分组模式在类目带内均分槽位；堆叠模式同槽累加。
- 百分比堆叠先按类目把正值归一到 1；零和类目不画。
- 柱体从基线行向值行逐行填 `█`；高度不足 1 行时至少画 1 格。

### 7. 折线与散点

- 类目轴按 `BandScale.center` 定位；数值/时间轴按 `LinearScale` 定位。
- `null` 跳过并断开；时间字符串用 `ChartTime.parseDays` 转换，刻度用 `ChartTime.formatDays`。
- 散点仅画 `o`；重叠点自然覆盖。

### 8. 组合图

- 系列分类：
  - 叠加层：`line`、`scatter`
  - 柱层：`bar`、`grouped-bar`、`stacked-bar`、`percent-stacked-bar`
- 柱层槽位分配：
  - `bar` 与 `grouped-bar` 各占一个并排槽位；
  - 所有 `stacked-bar` 按 `stack`（缺省用系列名）归组，每组占一个槽位；
  - 所有 `percent-stacked-bar` 归为一个百分比槽位；
  - 槽位在类目带内均分。
- `axis == "right"` 的系列用 `yAxis2`；左右轴各自计算范围与刻度；右轴标签画在绘图区右侧（占用 1 列 + 标签宽度），若空间不足则省略右轴标签但仍按右轴比例定位。
- 先画柱层，再画线/散点层，保证叠加可见。

### 9. 错误处理

- 复用 `ChartException`：
  - 类型不匹配 → `UnsupportedChart`
  - 缺 `series`/`data` → `MissingField`
  - 长度不符、非法数值、非法颜色、尺寸过小 → `InvalidValue`
- 颜色解析失败时包装为 `ChartException`，`path` 指向系列颜色字段。

### 10. 测试策略

- 每个 TUI 类一个测试文件，先 Red 后 Green；`TuiCanvas`、`TuiFrame` 各一个测试文件。
- 测试辅助：`tuiStripAnsi` 去掉转义；`tuiDisplayWidth` 计算 CJK 宽度；`tuiPlainLines` 返回去色后的行数组。
- 断言真实行为：标题、轴标签、标记字符、颜色转义、行数/列宽、错误 kind。
- 组合图测试覆盖 3 种类型同时呈现与柱族混合。
- 全量 `cjpm test` 回归，确保 SVG 1092 个用例不受影响。

## Risks

- 终端对 CJK 宽度的实现存在差异；按 Unicode East Asian Width 的常用区间判定（≥ `0x2E80` 记 2 列），并在文档中说明。
- 800×480 的既有 SVG JSON 直接交给 TUI 会生成超大字符画；TUI 推荐显式传 `width`/`height`（如 80×24），文档给出示例。
- 字符网格分辨率有限，密集数据会重叠；折线/散点通过抽稀标签与固定 1 列标记缓解。
- 组合图槽位规则为 TUI 简化版，与 SVG 的像素级布局不保证逐像素一致，但语义一致。

## Migration

- 无既有 API 变更；新增子包与可选参数，SVG 调用方零改动。
- `f_chart` 不新增依赖，构建时间与产物不受影响。
