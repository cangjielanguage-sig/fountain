# f_chart 模块审查报告（模块第 37/37 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_chart/src/tui`（本部分 13 个文件：6 个 `.cj` 实现 + 7 个 `*_test.cj`）
- **基线**：工作区快照（`120fd2542`，`git diff` 为空）⇒ 全部问题来源记「存量」
- **审查重点**：渲染/布局算法正确性、坐标与数值边界、OOM、资源与内存、死代码、重复逻辑
- **报告版本**：v1（分部分报告，供主 Agent 合并为 `f_chart_v2.md`；不单独产出 `docs/review/` 模块报告）

## 发现

### [严重][存量] 画布尺寸与层高直接由 JSON 数值转 Int64，无上界校验 → 巨量分配 OOM / 溢出异常逃出 `ChartException` 契约

- **位置**：`f_chart/src/tui/TuiFrame.cj:74`（`let width = Int64(config.width)` / `:75` `Int64(config.height)`）、`f_chart/src/tui/TuiFlameChart.cj:73`（`TuiCanvas(Int64(config.width), Int64(config.height))`）、`f_chart/src/tui/TuiFlameChart.cj:81`（`Int64(floor(configuredHeight))`
- **来源**：存量（快照模式无基线；相关行属 2026 TUI 首版，全仓仅此一份实现）
- **判据**：review-checklist §5「按不可信长度预分配」+ §11「契约与实现不符」；`integer.md:137`（`D:/docs/work/cangjie/cangjie-doc/cangjie_docs/docs/dev-guide/source_zh_cn/basic_data_type/integer.md`）明确「类型转换时可能发生溢出……否则根据默认的溢出策略将抛出异常」
- **证据**：静态确定 —— `ChartConfig.cj:182` 只校验 `width <= 0.0 || height <= 0.0`，全模块（`grep "MAX\|上限" f_chart/src/tui/*.cj` 无命中）没有任何上界；`TuiCanvas` 构造函数按 `width * height` 逐个 `add(TuiCell())`
- **描述**：`{"width": 100000, "height": 100000}` 这类合法 JSON 会通过全部校验，随后分配 10^10 个 `TuiCell`（每格 2 个 String 引用 + Bool，数十字节量级），直接触发堆耗尽；`{"width": 1e30}` 则在 `Int64(...)` 处按默认溢出策略抛 `OverflowException`。`Chart.draw` 的契约（`Chart.cj:33`「@throws ChartException 输入结构或数值不合法时抛出」）要求调用方只需处理 `ChartException`，此处会泄漏其它异常类型。所有 TUI 图表共用同一路径（`TuiBarChart`/`TuiLineChart` 等同样先建 `TuiFrame` 再建 `TuiCanvas`），本部分以火焰图为代表位置
- **建议**：在 `ChartConfig` 或 `TuiFrame` 构造里加常量上限（例如 `width <= 1000 && height <= 500`，超出抛 `chartInvalidValue("width"/"height", …)`），并把 `Int64(...)` 转换移到位阶校验之后；`frameHeight` 同样先判 `<= 上限` 再取整

### [一般][存量] 火焰图的环检测分支不可达，含环输入被静默丢弃而不是报错

- **位置**：`f_chart/src/tui/TuiFlameChart.cj:173`（`if (depth > total)`）、`:191`（同）、`:153`（`resolveRoot`）
- **来源**：存量（`FlameChart.cj:167-194` 有完全相同的实现，属同一设计）
- **判据**：review-checklist §1「恒真恒假分支 / 不可达语句」+ §11「错误处理缺失或静默」
- **证据**：静态确定 —— 每个节点只有单一 `parentId`（`parseNodes:123-133`），把 `parentId` 连成有向边后图是「森林 + 若干环」；`roots.size == 1` 时环必然不在根的可达子树内，`validateTree`/`assignDepth`/`layoutNode` 只沿 `children` 自根下探，永远走不到环，因此 `depth > total`（`total = nodes.size`，合法树最大深度只能是 `nodes.size - 1`）恒为假
- **描述**：`nodes` 中若存在一个根加一组互指的节点（例如 `a.parent=b, b.parent=a`），三个校验函数都不会抛「节点关系存在环」，环内节点既不进 `boxes` 也不占深度，最终渲染出一张缺少这些节点的图且无任何提示。这条 `throw` 是唯一对外承诺的环错误，实际不可达
- **建议**：装配完 `children` 后按「已访问集合」做一次显式遍历（或直接校验「每个节点从根可达且访问次数为 1」），环/不可达节点抛 `chartInvalidValue("nodes", "存在环或孤立节点")`；同时删掉 `depth > total` 这两处死分支

### [一般][存量] 树递归的三处实现深度完全由输入决定，无固定上限

- **位置**：`f_chart/src/tui/TuiFlameChart.cj:172-188`（`validateTree`）、`:190-198`（`assignDepth`）、`:200-225`（`layoutNode`，此函数连 `depth` 判据都没有）
- **来源**：存量
- **判据**：review-checklist §4「无界递归：深度由输入决定」+「尾递归不能当保险」
- **证据**：静态确定 —— 递归深度 = 输入树的链长，唯一「上限」是 `depth > total`（`total = nodes.size`），即链长 N 允许 N 层调用，常量层面没有任何截断
- **描述**：`nodes` 是一条 10^4 量级的长链时，三个函数各需要等量栈帧（`layoutNode` 每帧还有 `Float64`/`Int64` 局部量），可触发栈溢出崩溃，且崩溃点是 panic 而非 `ChartException`。正常火焰数据链深通常只有数百层，故定为「一般」，但输入若来自外部（profile 文件、LLM 生成）即等同严重
- **建议**：装配阶段先算层深并设常量上限（例如 256/512），超限抛 `chartInvalidValue("nodes", "层级过深")`；或把 `validateTree`/`assignDepth`/`layoutNode` 改为显式栈迭代

### [一般][存量] 节点名、标题、轴标签原样进入 ANSI 输出，未过滤控制字符 → 终端转义注入与行结构破坏

- **位置**：`f_chart/src/tui/TuiFlameChart.cj:264-267`（`canvas.putText(..., box.node.name, ...)`）、`f_chart/src/tui/TuiFrame.cj:124-126`（`config.title`/`config.subtitle`）、`f_chart/src/tui/TuiFrame.cj:190-199`（类目标签）
- **来源**：存量
- **判据**：review-checklist §10「安全性：外部输入未校验」；`TuiCanvas.putText:96-106` / `render:178-201` 只按 `tuiRuneWidth` 排布，符号字符串原样 append
- **证据**：静态确定 —— 颜色走 `tuiAnsiForeground` 的 `SvgColor.parse` 再拼 RGB（`TuiColor.cj:28-35`，无注入面），但文本路径整条链上没有任何 `0x1B`/`\n`/`\r` 过滤（`grep` 全包只命中 ANSI 生成与 `tuiStripAnsi` 两处）
- **描述**：`{"name": "\u001b[2J\u001b[H"}` 或内含 `\n` 的节点名/标题会原样写进返回串：前者可在渲染方的终端清屏、改光标、写 OSC 序列；后者会撑破「每行恰好 width」的行模型（`TuiFlameChart_test` 断言的 25 行随之失效）。同时 `tuiDisplayWidth` 把 ESC 当 1 列，截断与居中都会错位
- **建议**：在 `TuiCanvas.putText`（或 `tuiTruncate` 入口）统一剔除 `U+0000–U+001F`、`U+007F`、`U+009B`，或把控制字符替换为 `?`；该修法同时覆盖柱/线/散点等其它 TUI 图

### [一般][存量] 火焰图节点解析与校验逻辑与 SVG 版 `FlameChart` 逐行重复

- **位置**：`f_chart/src/tui/TuiFlameChart.cj:99-198`（`parseNodes` / `findNode` / `resolveRoot` / `validateTree` / `assignDepth`）对照 `f_chart/src/FlameChart.cj:53-124`、`:158-194`
- **来源**：存量
- **判据**：review-checklist §2「跨文件复制：只改类型名」——两处 `parseNodes` 的字段校验顺序、错误文案（`"节点 id 重复"`、`"父节点 ${parentId} 不存在"`、`"必须恰好有一个根节点"`、`"节点 ${node.id} 的值小于子节点之和"`、`"期望字符串或 null"`、`"节点值必须大于 0"`）、容差常量 `1e-6` 完全一致；`validateTree` 与 `validateValues` 除函数名外逐字相同
- **证据**：静态确定 —— 已逐段比对两个文件体量（本部分 `:99-198` vs `FlameChart.cj:53-124` + `:158-194`），差异仅在 `maxDepth` 写法（`if` 表达式 vs `for + if`）
- **描述**：同一份 JSON 契约维护两份实现，已出现的漂移是「TUI 版用 `for + if` 求 maxDepth、SVG 版用三元式」；上文两条缺陷（环检测失效、递归无上限）也因此在两处同时存在，修一处不改另一处就会行为分叉
- **建议**：把 `parseNodes` / `resolveRoot` / 环与深度校验提到 `fountain::f_chart` 的 internal 助手（与 `FlameNode`、`flameColorIndex` 同包），TUI 与 SVG 共用；`layoutNode` 保持各自实现（一个是列区间、一个是像素区间，属真实差异）

### [轻微][存量] 死代码：`tuiPadRight` 与 `TuiRect.centerX/centerY` 无任何调用者

- **位置**：`f_chart/src/tui/TuiText.cj:65-78`（`tuiPadRight`）、`f_chart/src/tui/TuiFrame.cj:43-49`（`TuiRect.centerX` / `centerY`）
- **来源**：存量
- **判据**：review-checklist §1「`internal` 按本包及子包内无调用者判」
- **证据**：静态确定 —— `grep -rn "tuiPadRight" f_chart/src` 只命中定义行；`grep -rn "centerX()\|centerY()" f_chart/src/tui` 只命中 `TuiFrame.cj:43/47` 两处定义（`ArcChart.cj:127` 等命中是 SVG 侧 `ChartRect.centerX()`，不同类型）
- **描述**：`TuiRect` 本身被 `LineChart.cj:153`、`TuiBarRenderer.cj:260`、`TuiFrame` 使用，但两个取中心点的辅助从未被调用；`tuiPadLeft` 有调用（`TuiFrame.cj:174`），`tuiPadRight` 没有
- **建议**：删除三处；若确定要保留给后续按宽度补空白的场景，改成有调用方的公共助手并补用例

### [轻微][存量] 未使用的 import：`TuiText.cj:18`

- **位置**：`f_chart/src/tui/TuiText.cj:18`（`import std.collection.ArrayList`）
- **来源**：存量
- **判据**：review-checklist §1「未使用的 `import`」
- **证据**：静态确定 —— 文件内只用到 `StringBuilder`、`Rune`（prelude），无 `ArrayList` 出现
- **描述**：多余 import，`cjlint` 会报未使用
- **建议**：删除该行

### [轻微][存量] `TuiFrame` 尺寸校验的错误路径固定写 `"width"`，无法定位到真正越界的字段

- **位置**：`f_chart/src/tui/TuiFrame.cj:71-73`（`config.height < 8.0` 也抛 `chartInvalidValue("width", …)`）、`:103-105`（`plotHeight < 1` 也报 `width`）
- **来源**：存量
- **判据**：review-checklist §11「语义与命名 / 注释不符」；`ChartException.path` 是调用方定位字段的唯一线索
- **证据**：静态确定 —— 两个 `if` 都覆盖宽高两个条件，`path` 实参恒为 `"width"`
- **描述**：`{"width": 80, "height": 5}` 报 `path="width"`，使用者会去改宽度而不是高度；绘图区过小同理
- **建议**：拆成两个分支分别报 `"width"` / `"height"`；绘图区不足时用 `"height"`（TUI 下几乎总是行数不够）或 `"size"`

### [轻微][存量] 图例配置只部分生效：`position` 除 `"bottom"` 外一律当顶部，`orient`/`itemGap`/`markerSize` 被忽略

- **位置**：`f_chart/src/tui/TuiFrame.cj:88-99`（`position != "bottom"` ⇒ 占顶部行）、`:147-164`（游标步长硬编码 `+2`、色块固定 `"■"`）
- **来源**：存量
- **判据**：review-checklist §11「契约与实现不符」；`ChartConfig.cj:105-108` 接受任意 `position` 字符串且不校验取值
- **证据**：静态确定 —— `ChartLegend` 有 `position`/`orient`/`itemGap`/`markerSize` 四个字段，`TuiFrame` 只读 `position` 且只区分 `"bottom"`
- **描述**：`"legend": {"position": "right"}` 会静默变成顶部横向图例；`itemGap`/`markerSize` 写多少都不影响输出。用户按 SVG 版经验配置会得到不一致结果，且没有任何告警
- **建议**：在 `TuiFrame` 构造处对不支持的取值抛 `chartInvalidValue("legend.position", "TUI 仅支持 top / bottom")`，或按 `orient` 实现左右分栏；`itemGap` 至少接到游标步长上

### [轻微][存量] `tuiRuneWidth` 用单一阈值 `0x2E80` 判宽字符，半角片假名与组合符宽度算错

- **位置**：`f_chart/src/tui/TuiText.cj:21-27`
- **来源**：存量
- **判据**：review-checklist §11「边界差一 / 语义与命名不符」（函数注释「CJK/全角按 2 列，其余按 1 列」）
- **证据**：静态确定 —— `rune.position() >= 0x2E80` 这一段覆盖了 U+FF61–U+FF9F（半角片假名，终端实际 1 列）与 U+FFE0 起的一部分符号，同时对 U+0300 起的组合符（实际 0 列）返回 1
- **描述**：标签里出现半角片假名时 `tuiDisplayWidth` 高估 1 列/字，`tuiTruncate` 会提前截断、`putText(align: "middle")` 居中偏左；组合符则会占掉一格并把后续字符整体推后。普通中英混排（模块主要用例）不受影响
- **建议**：按 East Asian Width 分类表实现 `tuiRuneWidth`（至少排除 `0xFF61-0xFFDC`、把 `U+0300-036F`/`U+200B-200F` 记 0）；若暂不做，在 `TuiText.cj` 头注释里写明该近似只保证 BMP 汉字的宽度

### [轻微][存量] 测试断言弱于用例名，无法证明被测行为

- **位置**：`f_chart/src/tui/TuiPercentStackedBarChart_test.cj:66-80`（`skipsZeroTotal`）、`f_chart/src/tui/TuiScatterChart_test.cj:91`（`handlesNegativeY`）
- **来源**：存量
- **判据**：review-checklist §3「有没有用例覆盖」的反面——用例在，但不校验声明的行为
- **证据**：静态确定 —— `skipsZeroTotal` 输入为 `[10,0]`，第一位非零必然画柱，`@Assert(...contains("█"))` 对「零和类目被跳过」无鉴别力；`handlesNegativeY` 的 `contains("-5") || contains("0")` 中 `"0"` 几乎必然命中（轴刻度含 0）
- **描述**：两条用例即使实现回退成「零和类目不跳过」「负值不绘制」也会通过，回归无保护
- **建议**：`skipsZeroTotal` 改为断言纯文本中第二列区域（B 类目）没有任何柱体符号；`handlesNegativeY` 断言 `-5` 刻度存在且负值点位于 0 行下方

### [轻微][存量] 两个测试文件逐字复制 `count` 辅助，且循环内重复 `toArray()`

- **位置**：`f_chart/src/tui/TuiLineChart_test.cj:29-37`、`f_chart/src/tui/TuiScatterChart_test.cj:29-37`
- **来源**：存量
- **判据**：review-checklist §2「字面量复制」；差别仅在所在文件
- **证据**：静态确定 —— 两个函数体逐行一致，`from = index + needle.toArray().size` 每轮重新分配字节数组
- **描述**：测试辅助重复，匹配逻辑（子串重叠、多字节 needle）以后只需修一处会漏另一处
- **建议**：提到 `TuiCanvas_test` 同包的 internal 测试助手（例如 `TuiTestSupport.cj`）并改为 `from = index + needle.size`（`String.size` 即字节长度，无需 `toArray`）

> 范围外提示（不计入统计）：`TuiFlameChart` 是 public `Chart` 实现，仓内唯一使用方是 `TuiGallery_test`/`TuiFlameChart_test`；`fprobe/src/tui/ChartPanel.cj:84-87` 的 TUI 分发只支持 `bar`/`line`，未接火焰图（对外 API 本身不算缺陷，仅提示接线现状）。

## 优化可行性方案

### [CPU] 节点装配用 `ArrayList` 线性查找，整体 O(n²) → `HashMap` 索引

- **现状**：`parseNodes` 对每个新节点与已解析列表逐个比 `id`（`TuiFlameChart.cj:117-121`），`resolveRoot` 又对每个节点 `findNode` 全表线性扫描（`:144-151`、`:158`）。n = `nodes` 条数，每条约 2n 次字符串比较，n=10^4 时约 2×10^8 次比较 + 指针追逐
- **方案**：`parseNodes` 内维护 `HashMap<String, FlameNode>` 同时完成去重与建表；`resolveRoot` 改为单次哈希查找。`FlameNode` 定义在 `fountain::f_chart`（`FlameChart.cj:24`），助手可放同包供 SVG/TUI 共用（与上条重复逻辑同一落点）
- **预期**：复杂度从 O(n²) 降到 O(n)。收益随 n 放大，n≤100 时可忽略
- **代价**：多一份 `HashMap` 的常驻内存（约 n 个 entry，画完即释放）；`HashMap` 插入顺序不影响 `children` 顺序（仍按 `nodes` 数组顺序 `add`），渲染结果不变
- **验证**：`cjpm bench -O2`，同一份 1k/10k/50k 节点 JSON，各跑 30 轮取中位数；`cjprof record` 确认 `findNode`/`parseNodes` 的 self time 占比
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] 画布按 `width × height` 逐格 new `TuiCell`，每次 `draw` 产生 width×height 个短命对象

- **现状**：`TuiCanvas` 构造为每个格子 `ArrayList.add(TuiCell())`（`TuiCanvas.cj:36-42`）；80×24 默认尺寸即 1920 个对象 + 1 个 `Array<TuiCell>`，每个 `TuiCell` 含 2 个 `String` 引用与 1 个 `Bool`。火焰图在 `draw` 内建一次即随返回值丢弃
- **方案**：改为「符号 `Array<String>` + 颜色 `Array<String>` + 标志位 `Array<Bool>`」三平行数组，或把 `TuiCell` 改成 `struct`（值类型可直接内联进 `Array`，省掉 1920 次堆分配与指针跳转）
- **预期**：每帧堆分配次数从 O(width×height) 降到 O(1)（3 个数组），GC 压力同比例下降；峰值内存不变（仍是 width×height 个槽位）
- **代价**：`cellSymbols()`/`plainLines()`/`render()` 三个访问点都要跟着改索引方式；`struct` 语义下 `cell.symbol = ...` 需改为数组赋值
- **验证**：多轮 `draw` 后 `getAllocatedHeapSize()` 增量与 GC 次数对比（改前/改后各 10^4 次绘制，`-O2`，同输入）；RSS 稳态对照
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 大节点量下 `parseNodes`/`findNode` 的 O(n²) 是绘制主耗时 | `f_chart/src/tui/TuiFlameChart.cj:117`、`:145` | 自耗时占比、n 的拐点 | `cjprof record` 跑 1k/10k/50k 节点三档，与总耗时对比；再看改 `HashMap` 后中位数 |
| 2 | 每帧 width×height 个 `TuiCell` 是主要分配源 | `f_chart/src/tui/TuiFlameChart.cj:73`（`TuiCanvas` 构造） | 每次 draw 的分配字节与 GC 次数 | `getAllocatedHeapSize()` 前后差值 × 绘制次数；`cjprof heap` 看 `TuiCell` 占比 |
| 3 | 深链（≥10^4）才会栈溢出，正常火焰数据不触发 | `f_chart/src/tui/TuiFlameChart.cj:172`、`:190`、`:200` | 实际崩溃深度、线程栈上限 | 构造 1k/5k/10k/20k 层链逐档跑 `draw`，记录首个崩溃档位；对照 SDK 线程默认栈大小文档 |
| 4 | 图例/轴标签的 `tuiDisplayWidth` 重复扫描在长标签下可测 | `f_chart/src/tui/TuiText.cj:43`、`:66`、`:82` | 单次 `draw` 内 `runes()` 遍历次数与耗时 | 分段计时 `tuiDisplayWidth` 累计耗时占比（标签 ≥ 64 列时） |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_chart/src/tui/TuiConfig_test.cj` | .cj | ✅ | 仅覆盖默认/显式尺寸两例，无缺陷 |
| 2 | `f_chart/src/tui/TuiFlameChart.cj` | .cj | ✅ | 见 #1 #2 #3 #4 #5 #6 相关条目 |
| 3 | `f_chart/src/tui/TuiFlameChart_test.cj` | .cj | ✅ | 15 例，含类型/重复 id/多根/未知父/子值和超父值等负例；写 `charts/` 与 `ChartGallery_test` 同模式，无缺陷 |
| 4 | `f_chart/src/tui/TuiFrame.cj` | .cj | ✅ | 见 #1 #6 #7 #9；布局行号推导已逐项核对（title/subtitle/legend/xTitle/bottom 与 height 自洽） |
| 5 | `f_chart/src/tui/TuiFrame_test.cj` | .cj | ✅ | 5 例覆盖标题/图例/纵轴/类目轴/过小画布，与实现一致 |
| 6 | `f_chart/src/tui/TuiGallery_test.cj` | .cj | ✅ | M1–M7+M52 共 8 例；注释「8 个 .tui.txt」与本类产出数一致 |
| 7 | `f_chart/src/tui/TuiGroupedBarChart_test.cj` | .cj | ✅ | 4 例，含同排双色断言，无缺陷 |
| 8 | `f_chart/src/tui/TuiLineChart_test.cj` | .cj | ✅ | 见 #12（`count` 辅助重复） |
| 9 | `f_chart/src/tui/TuiPercentStackedBarChart_test.cj` | .cj | ✅ | 见 #11（`skipsZeroTotal` 断言弱） |
| 10 | `f_chart/src/tui/TuiPointCommon.cj` | .cj | ✅ | 类目/数值/时间三路解析与 `null` 语义已逐分支核对，无缺陷；被 LineChart/ScatterChart 复用（`grep` 已确认） |
| 11 | `f_chart/src/tui/TuiScatterChart_test.cj` | .cj | ✅ | 见 #11 #12 |
| 12 | `f_chart/src/tui/TuiStackedBarChart_test.cj` | .cj | ✅ | 4 例含正负堆叠，无缺陷 |
| 13 | `f_chart/src/tui/TuiText.cj` | .cj | ✅ | 见 #6 #8 #10 |

合计：`.cj` 13 个 / `.md` 0 个 / 共 13 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 5 | 正确性 #2（环静默丢弃）、#1（尺寸边界）；安全性 #4（控制字符）；设计 #5（双实现）；可读性/语言特性并入 #7 #8 #9 |
| §1 死代码 | 2 | 已逐个符号搜引用：`TuiFlameBox`/`TuiPoint`/`TuiPointSeries`/`TuiRect` 主体、`TuiFrame` 全部私有方法均有调用；命中 `tuiPadRight`、`TuiRect.centerX/centerY`（本包无引用）+ 未用 import。`public` 的 `TuiFlameChart` 对外可达，不判 |
| §2 重复逻辑 | 2 | 已两两比对本部分 6 个实现的函数体摘要：命中 `TuiFlameChart` 与 `FlameChart`（SVG）解析/校验整段复制、两个测试文件 `count` 复制；`tuiPadLeft`/`tuiPadRight` 仅 append 顺序不同，已并入死代码条目（右侧版本无调用者），未单列 |
| §3 空实现 | 0 | 无空函数体、无 TODO/FIXME；`TuiPointCommon.cj:110` 的 `case None => ()` 是可选 `y` 缺失的合法分支（缺失即断线，有 `breaksOnNull` 用例），不是吞错；`tuiContrastColor` 的 `catch` 有显式降级并与注释一致（该文件不在本部分） |
| §4 栈溢出 | 1 | 见 #3；`validateTree`/`assignDepth`/`layoutNode` 三处递归均无常量上限，已给出可达深度推导（= 输入链长） |
| §5 OOM | 1 | 见 #1；本部分唯一无界分配点是 `width × height` 画布（`boxes` 数量上界为 `nodes.size`，受 #1 同一尺寸/数量约束） |
| §6.1 热点瓶颈 | 0 | 未提供 profile / bench 数据（`scope.md` 的已有资料只有 `docs/LocalMode*.md`），热点结论不成立，已转「待验证假设」#1 #2 |
| §6.2 大粒度锁 | 0 | 本部分无任何锁、无共享状态 |
| §6.3 并发串行 | 0 | 无 `spawn`/`Future`/队列，纯同步计算 |
| §6.4 低效算法 | 2 | 线性查找 O(n²)（已写入 CPU 方案）、`needle.toArray()` 在循环内重复分配（并入 #12）；均已按「无基线只能待验证」处理，不作为缺陷统计 |
| §7 降堆内存方案 | 1 | `TuiCanvas` 逐格对象 → 平行数组 / `struct`，`无基线（待验证）` |
| §8 降 CPU 方案 | 1 | 节点装配 O(n²) → `HashMap`，`无基线（待验证）` |
| §9 local mode 可行性 | 0 | 本部分没有「函数内创建、函数内用完且不逃逸」的大缓冲区：`TuiCanvas` 格子数组作为返回值逃逸，`FlameNode` 树虽在 `draw` 内建完即弃但含 `var` 字段（非 `Copyable`，需 local 构造 + mode 重载），且缺峰值内存基线；按 checklist §9 只能列待验证，不写成方案 |
| §11 现有代码的 BUG（存量） | 4 | #1 #2 #3 #4 均为存量；已核对的边界：空 `nodes`（`:101-103` 抛）、`parent: null` 与缺省（`:123-133` 同义）、`value <= 0`（`:135-137`）、子节点和超父值（`:180-184`）、`maxDepth + 1` 恒 ≥ 1（`:65-76`）、`configuredRows` 为 0 时回落 `fitRows`（`:81-86`）、`drawBox` 的 `right <= left`/`bottom < top` 早退（`:253-255`）、`TuiFrame` 行号与 `height` 自洽（`:93-119` 已逐分支推导） |
| §12 并发安全与锁粒度 | 0 | 本部分所有类型都是 `draw` 内新建的局部对象，无 static/全局/单例/注册表；`Chart` 契约要求纯函数语义（`Chart.cj:24-25`），无共享可变状态可竞争 |
| §14 功能完备性与 README 覆盖 | 1 | `TuiFlameChart` 与 `doc/f_chart模块设计.md:291` 登记一致；本部分无 README/`doc/**`。仅提示（范围外）：`fprobe/src/tui/ChartPanel.cj:84-87` 的 TUI 分发未接火焰图 |
| 文件覆盖（§13 等） | 13/13 | 与 `files/f_chart.part37.txt` 一一对应，无遗漏、无未读 |

## 模块统计（仅本部分）

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 1 |
| 一般 | 4 |
| 轻微 | 7 |
| 优化方案（堆内存 / CPU） | 1 / 1 |

存量缺陷 12 条（严重 1 / 一般 4 / 轻微 7），是否纳入修复待用户决定；本部分未产生「本次改动」类问题。

## 总评

本部分是 TUI 渲染层的最后一组文件：`TuiFrame` 的坐标推导（标题/副标题/图例/轴标题与 `height` 的配平）逐分支核对后是自洽的，`TuiPointCommon` 的三路解析与 `null` 语义、火焰图的列区间取整与裁剪都写得干净，测试密度也高于模块平均水平（13 个文件里 7 个是用例，负例覆盖到位）。

真正的阻塞项只有一条：画布尺寸从 JSON 一路无校验地转成 `Int64` 再按 `width × height` 分配，既是 OOM 面也是 `ChartException` 契约的漏口，建议按「严重」优先修。第二梯队是火焰图的树校验——环检测分支实际不可达、含环输入静默丢节点、递归深度由输入决定，这三件事同源，且因为解析/校验逻辑与 SVG 版 `FlameChart` 整段复制而在两处同时存在，合并助手后一次修完最划算。控制字符未过滤属于终端输出层的普遍问题（`TuiCanvas` 一处修、全体受益），单独排期即可。

其余 7 条轻微项（两个死符号、一个多余 import、错误 path 固定写 `width`、图例配置半生效、`tuiRuneWidth` 近似、两条弱断言、测试辅助复制）都是清理级别，不阻塞发布。两条优化方案均无改前基线，只能等下一轮补 `cjprof`/分配量数据后再决定是否进任务清单。
