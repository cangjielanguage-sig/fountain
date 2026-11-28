# f_chart 模块审查报告

> **模块第 4/37 部分**（只覆盖 `files/f_chart.part4.txt` 列出的 20 个文件，全部位于 `f_chart/doc/spec/add-f-chart-{bland-altman,box-scatter,boxplot,bubble,bullet,calendar-alias}/`。本部分 0 个 `.cj`、20 个 `.md`；`src/**` 的其余文件与同模块其他 spec 目录由后续子轮产出，合并时以主 Agent 为准。）

- **审查日期**：2026-11-28
- **模块路径**：`f_chart`（本部分 0 个 `.cj` + 20 个 `.md`，共 20 个文件）
- **基线**：工作区快照（`sts/1.3.x`，无 diff 可比 ⇒ 所有问题来源记「存量」）
- **审查重点**：本轮指定「图表渲染/布局算法正确性、坐标与边界、OOM、资源与内存、死代码、重复逻辑、存量 BUG」。本部分文件全部是 OpenSpec 规格（proposal / design / spec delta / tasks），因此实际做法是：把每条 requirement 与 scenario 当作契约，逐条到对应实现（`BlandAltmanChart.cj` / `BoxScatterChart.cj` / `BoxPlotChart.cj` / `BubbleChart.cj` / `BulletChart.cj` / `CalendarHeatmap.*`）取证比对，并顺手核查实现侧的渲染算法、坐标边界、内存副本、重复实现与存量缺陷。
- **报告版本**：v1（第 4/37 部分）

## 发现

### [一般][存量] #1 Bland-Altman 复用子弹图的 `bulletNumber`，负数测量值被当成非法输入拒绝

- **位置**：`f_chart/doc/spec/add-f-chart-bland-altman/specs/chart-rendering/spec.md:39`（契约）；`f_chart/src/BlandAltmanChart.cj:68-69`（调用点）；`f_chart/src/BulletChart.cj:239-241`（拒绝逻辑）
- **来源**：存量（`git blame -L 68,69` = `4af5d9450b 2026-11-08`；快照模式无基线可比）
- **判据**：review-checklist §13「规格与实现漂移」、§11「契约与实现不符」、§2「跨层复制 / 语义漂移」
- **证据**：静态确定 —— spec 的 Bland-Altman 校验只写「每项 MUST 提供数字型 `x` 与 `y`」，没有任何非负约束；实现却调用 `BulletChart` 的 `bulletNumber`（`BlandAltmanChart.cj:68-69`），该函数除「必须是数字」外还带 `if (number < 0.0) throw chartInvalidValue(..., "数值不能为负")`（`BulletChart.cj:239-241`），而子弹图的非负约束来自它自己的规格（`add-f-chart-bullet/specs/chart-rendering/spec.md:34`「`value`、`target` MUST 为非负数字」）。`grep -rn "bulletNumber" f_chart/src` 只有 `BulletChart.cj` 定义与 `BlandAltmanChart.cj:68,69` 两处调用，无第三个消费者。
- **描述**：Bland-Altman 的输入是两种方法对同一对象的成对测量值，测量值本身可以为负（温度、对数比值、收支差额、z 分数）。传 `{"x": -1.2, "y": 0.8}` 会在解析阶段抛 `ChartException(InvalidValue, "series[0].data[0].x 数值不能为负")`，与 spec 写的「数字型即可」相反，用户无法从规格推出这条限制。现有测试 `BlandAltmanChart_test.cj:39-56` 的样例全为正数，也没有负数用例，因此这条偏移没有被用例挡住。
- **建议**：给 `ChartJson` 加一个只做「必填 + 数字 + 有限」的通用读取（如 `requiredNumberField(json, field, path)`），Bland-Altman 改用它；`bulletNumber` 保留非负判断但改名为 `bulletNonNegativeNumber` 之类，避免名字暗示「通用数字读取」。同时在 `add-f-chart-bland-altman` 的 spec 里补一条「负数测量对」的 scenario。

### [一般][存量] #2 「读取必填数字字段」在 4 个图里各写一遍，规则已开始分叉

- **位置**：`f_chart/src/BulletChart.cj:233-243`（`bulletNumber`，额外要求非负）、`f_chart/src/BoxPlotChart.cj:241-247`（`requiredNumber`，无额外约束）、`f_chart/src/BoxScatterChart.cj:214-226`（`parseValues`，逐元素同规则）、`f_chart/src/BubbleChart.cj:121-123`（内联 `jsonNumberValue(pointJson.required(...))`）、`f_chart/src/BlandAltmanChart.cj:68-69`（复用 `bulletNumber`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §2「只改类型名 / 字面量复制」「近似重复」，判据要求点名语义差异
- **证据**：静态确定 —— 五处代码的输入-输出-副作用都是「`ChartJson` + 字段名 + 路径 → `Float64`，缺失抛 `MissingField`、类型不符抛 `InvalidValue`」，差别只有两处：`bulletNumber` 多了 `>= 0` 判断（`BulletChart.cj:239`），`parseValues` 作用于数组元素而不是具名字段。底层 `jsonNumberValue`（`ChartJson.cj:215-227`）本身已经做了「非数字 → InvalidValue」「NaN/Inf → InvalidValue」。
- **描述**：同一语义被复制 4 份、另被跨图复用 1 处后已经开始漂移——#1 就是 `bulletNumber` 的非负语义被别处复用造成的错误拒绝；`BoxPlotChart.requiredNumber` 与 `BoxScatterChart.parseValues` 的报错文案也不一致（前者 `"期望数字"`，后者同样 `"期望数字"` 但路径拼接方式不同），后续任何一处收紧（例如统一拒绝 Inf）都不会同步到其余四处。
- **建议**：在 `ChartJson` 上补两个方法：`func requiredNumber(name: String): Float64`（字段级）与 `func numberItems(name: String): Array<Float64>`（数组级），内部都走 `jsonNumberValue`；各图只保留自己真正的业务约束（子弹图非负、箱线图五数单调），删除 4 个包装函数。

### [一般][存量] #3 手写插入排序在 `f_chart` 里复制了 8 份，箱线散点每组都要 O(n²)

- **位置**：`f_chart/src/BoxScatterChart.cj:245-260`（`sortValues`）；同实现另见 `ViolinChart.cj:271-287`、`ViolinBoxChart.cj:298-313`、`SwarmChart.cj:218-233`、`RaincloudChart.cj:320-333`、`ProbabilityChart.cj:156-171`、`QQChart.cj:156-171`、`StemLeafChart.cj:160-174`（内联在茎叶图解析函数里）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §2「换控制流 / 跨文件复制」、§6.4「低效算法（双层循环做排序）」、§11「重复实现导致行为漂移」
- **证据**：静态确定 —— `grep -rn "sorted\[j\] < sorted\[j - 1\]" f_chart/src` 命中 8 个文件，函数体逐行一致（拷贝到 `ArrayList` → 从 `i=1` 起向前冒泡移位 → `toArray()`），只有所属类型名不同。`add-f-chart-box-scatter/design.md:12` 只写「组内排序后用 `quantileSorted` 取 Q1 / 中位数 / Q3」，没有说明排序算法，也没有数据规模上限。
- **描述**：`BoxScatterChart` 的每组样本都走 `sortValues`（`BoxScatterChart.cj:163`），复杂度 O(n²)、含 `ArrayList` 拷贝。散点叠加箱线的图本身鼓励大样本（每组上千点才看得出分布），n = 10 000 时比较次数约 5×10⁷ 量级；同时这套排序被 8 处复制，任何一处修正（例如改成稳定排序、处理 NaN）都要改 8 遍。
- **建议**：抽成模块内单一工具（放 `ChartScale.cj` 或新建 `ChartSort.cj`）：`internal func sortedFloats(values: Array<Float64>): Array<Float64>`，实现用 `sort` 的 `Float64` 比较，8 处调用点全部替换；`quantileSorted` 的入参不变。等价性用例需覆盖：重复值、负数、单元素、全相等。
- **说明**：这条的**重复逻辑部分**是静态确定的；「它是不是热点」没有 profile 数据，见「待验证假设」#1。

### [一般][存量] #4 连续轴范围计算有 3 套实现，留白规则互相不一致

- **位置**：`f_chart/src/BoxPlotChart.cj:249-264` 与 `f_chart/src/BoxScatterChart.cj:228-243`（两份逐字相同的 `resolveYRange`，两侧都加 5% 留白）；同族实现另见 `ViolinChart.cj:254`、`ViolinBoxChart.cj:281`、`SwarmChart.cj:201`；`f_chart/src/LineChart.cj:457-478`（`lineRange`，只给一侧显式边界时另一侧**不留白**）；`f_chart/src/BlandAltmanChart.cj:87-110`（第三次实现：x 轴 5%、y 轴 8% 留白）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §2「只改类型名 / 换算复制」，并要求点名语义差异
- **证据**：静态确定 —— 三套规则的差异可以逐条列出：(a) `resolveYRange`（`BoxPlotChart.cj:249-264` 与 `BoxScatterChart.cj:228-243` 完全一致）在 `yAxis.min` 只给一侧时，另一侧仍按 `0.05 × span` 留白；(b) `lineRange`（`LineChart.cj:466-473`）只给一侧时另一侧直接取数据极值，不留白；(c) `BlandAltmanChart` 内联版对 x 用 `0.05`、对 y 用 `0.08`。`BubbleChart` 走的是 (b)（`BubbleChart.cj:148-149`），`BoxScatterChart` 走的是 (a)。
- **描述**：同一份 `xAxis.min` / `yAxis.min` 配置在不同图类型上得到不同的绘图区范围，Bubble（连续双轴散点）与 Bland-Altman（同为连续双轴）在同一数据下画出的点位置不一致；`add-f-chart-bubble/design.md:11` 写「复用 `drawXAxisNumeric` 与 `drawYAxis`」，即设计上是复用轴能力，但范围计算并没复用。
- **建议**：把 `lineRange` 提成唯一入口，用参数显式表达差异：`chartAxisRange(dataMin, dataMax, axisMin, axisMax, padRatio, path)`；`BoxPlot` / `BoxScatter` / `Violin*` / `Swarm` 的 `resolveYRange` 删除后统一调用（留白比 0.05），Bland-Altman 传 0.05 / 0.08。差异参数化后，行为差异就变成可读的常量而不是隐式约定。

### [一般][存量] #5 `bulletRangeColor` 用取模轮转，第 7 个区间起颜色回到最浅，违反「由浅到深」的规格

- **位置**：`f_chart/doc/spec/add-f-chart-bullet/specs/chart-rendering/spec.md:7`、`f_chart/doc/spec/add-f-chart-bullet/design.md:16`（契约）；`f_chart/src/BulletChart.cj:246-249`（实现）
- **来源**：存量（`git blame -L 246,249` = `a7273653af 2026-11-08`；快照模式无基线可比）
- **判据**：review-checklist §13「文档承诺与实现不符」、§11「语义与命名不符」
- **证据**：静态确定 —— spec 要求「颜色 MUST 由 `bulletRangeColor` 按区间序号返回由浅到深的灰色」，design 写死色阶「从 `#efefef` 到 `#d0d0d0`」；实现是 6 元素数组 `["#efefef","#e0e0e0","#d0d0d0","#c0c0c0","#b0b0b0","#a0a0a0"]` 后用 `shades[index % shades.size]`（`BulletChart.cj:247-248`）。`ranges` 只要求「非空、全为正数且严格递增」（`BulletChart.cj:75-95`），个数无上限。
- **描述**：两处不一致：一是色阶终点是 `#a0a0a0` 而不是文档写的 `#d0d0d0`；二是第 7 个区间（index=6）取模回到 `#efefef`（最浅），第 8 个又变成 `#e0e0e0`。于是「越靠右的区间底色越深」的视觉编码在 7 段以上会反向，读者会把最大区间误读成最小背景。子弹图通常 3–5 段，但配置没有上限，也没有校验或截断。
- **建议**：改为「用区间序号在固定色阶上插值/取整」且对 `index >= shades.size` 收敛到最深色（`shades[min(index, shades.size - 1)]`），并把 design 的终点色与实现对齐；或在 `ranges` 校验里加上「最多 N 段」并同步 spec。

### [一般][存量] #6 Bland-Altman 右端界限标签只预留固定 52px，数值位数一多就溢出画布右边

- **位置**：`f_chart/doc/spec/add-f-chart-bland-altman/specs/chart-rendering/spec.md:30`（「在右端标注数值」）；`f_chart/src/BlandAltmanChart.cj:144-147`（`rightLabelWidth: 52.0`）、`f_chart/src/BlandAltmanChart.cj:211-217`（文本起点 `plot.right() + 6.0`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「边界差一 / 越界」、§13「文档承诺与实现不符」（承诺标注数值，实际可能画到画布外）
- **证据**：静态确定（按模块自带的宽度估算函数推算）—— `ChartFrame` 用 `right = padding.right + rightLabelWidth` 算绘图区右边界（`ChartFrame.cj:86,91`），默认 `padding.right = 24`（`ChartConfig.cj:23`），所以留给标签的横向空间是 `24 + 52 - 6 = 70px`；标签文本由 `${label} ${chartFormatTick(...)}` 拼成（`BlandAltmanChart.cj:213`），`label` 是「均值/下限/上限」两个汉字。按 `chartTextWidth`（`ChartScale.cj:113-123`，CJK 记 1em、其余 0.56em，标签字号 `fontSize - 1 = 11`）估算：`下限 -1.234` ≈ 2×11 + 7×6.16 ≈ 65px（勉强放下），`下限 -1234.567` ≈ 2×11 + 11×6.16 ≈ 90px，超出 20px 即被画布裁掉；用户自定义 `yAxis.labelFormat`（`ChartConfig.cj:80` 默认 `{value}`，可任意加前后缀）时必然溢出。`grep -rn "clip" f_chart/src --include=*.cj` 在生产代码中无 `clipPath`，越界内容不会被裁成绘图区内，而是被 SVG 视口裁掉。
- **描述**：规格要求「在右端标注数值」，实现把一个与数据无关的常量 52 当成标签宽度上界，于是测量值量级一大（Bland-Altman 差值常见几十到几百）或换 `labelFormat`，标注文字末端就跑出 `width` 之外，右侧数值不可读。三个标签还共用同一固定基准，无法按各自宽度调整。
- **建议**：改为先把三条标签文本格式化好，用 `chartTextWidth` 取最大值动态传入 `rightLabelWidth`（形如 `max(width) + 12`），再建 `ChartFrame`；或退一步，把标签放到绘图区内部右下角并加背景，避免依赖右外边距。

### [一般][存量] #7 显式轴范围小于数据时，图元无裁剪地画到绘图区之外

- **位置**：`f_chart/src/BulletChart.cj:184-213`（区间条 / 值条 / 目标线按 `xScale.scale` 直接定位）；`f_chart/src/BlandAltmanChart.cj:184-192`（散点、以及 `drawLimit` 的三条参考线）；`f_chart/src/BoxPlotChart.cj:233-235`（`outliers`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「边界 / 越界」、§13「坐标与边界」
- **证据**：静态确定（几何）+ 待确认（契约）—— `BulletChart` 的 `max` 取 `xAxis.max`（`BulletChart.cj:126-129`）后直接 `xScale.scale(item.value)`（`194`）、`xScale.scale(item.target)`（`204`）、区间条右端 `xScale.scale(upper)`（`183`），没有任何 `min/max` 夹取；`xAxis.max = 100`、`value = 120` 时 `valueX < frame.plot.x`，矩形左边界越过 y 轴刻度文字区。`BlandAltmanChart` 对 `yAxis.min/max` 同理（`yScale.scale(pair.diff)`），散点与参考线会画到标题或 x 轴刻度上。整模块 SVG 输出无 `clipPath`（`grep -rn "clip"` 只命中 `tui/TuiCanvas.cj` 的文本截断）。规格未规定「越界数据应裁剪还是应报错」，故契约层面记 `待确认`。
- **描述**：`xAxis.max` / `yAxis.min` 是公开配置（`ChartConfig.cj:75-76`），用户常用它做「固定刻度对齐」。一旦数据超过显式范围，图元就叠到轴标签、标题、图例上，视觉上像渲染错位；子弹图尤其容易，因为 `target` 常大于当前上限。
- **建议**：二选一并写进 spec——(a) 生成 `clipPath`（`SvgBuilder` 加 `clipRect`）把绘图区形状包起来；(b) 在 `*Scale.scale` 返回后统一夹取到 `[plot.x, plot.right()]` / `[plot.y, plot.bottom()]`，并在 spec 补一条「超范围值被裁剪」的 scenario。同时给 `xAxis.max < max(value, target, ranges.last)` 的子弹图加校验或告警。

### [轻微][存量] #8 箱线图箱宽多了一条「不超过 0.9 槽宽」的上限，`design.md` 未记载

- **位置**：`f_chart/doc/spec/add-f-chart-boxplot/design.md:9`（「箱宽 `bandWidth * 0.5`，最小 12」）；`f_chart/src/BoxPlotChart.cj:197`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「文档与实现不符」
- **证据**：静态确定 —— 实现是 `minFloat(maxFloat(band.bandWidth * 0.5, 12.0), band.bandWidth * 0.9)`，多一层 `0.9 × bandWidth` 上限；design 只写「最小 12」。
- **描述**：类目数一多（`bandWidth` 小于约 13.3）时，实际箱宽等于 `0.9 × bandWidth` 而不是 design 承诺的「最小 12」，两文档对同一场景给出不同预期；上限本身是合理的（避免箱体盖住相邻类目），只是没写。
- **建议**：design 改成「箱宽 `bandWidth * 0.5`，夹取到 `[min(12, 0.9×bandWidth), 0.9×bandWidth]`」，并说明上限是为了留出相邻类目间隙。

### [轻微][存量] #9 子弹图目标线高度：`design.md` 写「行顶 20% 到 80%」，实现是区间条高度的 70%

- **位置**：`f_chart/doc/spec/add-f-chart-bullet/design.md:18`；`f_chart/src/BulletChart.cj:205-213`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「文档与实现不符」
- **证据**：静态确定 —— 实现把目标线从 `centerY - rangeHeight / 2.0` 画到 `centerY + rangeHeight / 2.0`，`rangeHeight = bandWidth * 0.7`（`178`），即行高的 70%、居中；design 的「20% → 80%」是行高的 60%。
- **描述**：差异只有 10% 行高，但两处口径不一致，按 design 实现会得到更短的目标线；文档读者无法判断哪个是准的。
- **建议**：design 改为「从 `centerY - 0.35×bandWidth` 到 `centerY + 0.35×bandWidth`（与区间色带同高）」，或把实现改成 0.2/0.8 并同步。

### [轻微][存量] #10 气泡图 `design.md` 承诺「填充透明度 0.6、同色描边」，实现与 SVG 工具层都不支持

- **位置**：`f_chart/doc/spec/add-f-chart-bubble/design.md:9`；`f_chart/src/BubbleChart.cj:212-215`；`f_chart/src/ChartSvgKit.cj:123-137`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「文档承诺与实现相反」、§14.1「承诺了但没实现」
- **证据**：静态确定 —— `BubbleChart` 画点只有 `kit.circle(x, y, radius, fill: color, className: "bubble")`，无透明度、无描边；`ChartSvgKit.circle` 的签名只有 `fill!` 与 `className!`（`ChartSvgKit.cj:123-128`），函数体只写 `fill`（`135`），没有 `fill-opacity` / `stroke`，因此当前工具层**无法**表达 design 承诺的样式（`rect` 有 `fillOpacity` 参数，`circle` 没有）。
- **描述**：气泡互相重叠时，design 的 0.6 透明 + 同色描边是区分叠加层次的关键手段；实际输出是不透明实心圆，重叠区域完全遮挡，图上「哪里更密」看不出来。属于设计承诺未落地，而不是渲染参数写错。
- **建议**：给 `ChartSvgKit.circle` 补 `stroke!: ?String = None`、`strokeWidth!: Float64 = 0.0`、`fillOpacity!: Float64 = 1.0`（与 `rect` 对齐），`BubbleChart` 传 `fillOpacity: 0.6` 与 `stroke: color`；若决定不支持，就把 design 第 9 行改成实际样式。

### [轻微][存量] #11 气泡图未把 `xAxis.labelRotate` 计入底部留白，旋转标签会压到轴标题/画布边缘

- **位置**：`f_chart/src/BubbleChart.cj:177`；对照 `f_chart/src/BoxPlotChart.cj:169-173`、`f_chart/src/BoxScatterChart.cj:129-133`、`f_chart/src/BlandAltmanChart.cj:138-142`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「边界 / 布局」、§13「同类实现不一致」
- **证据**：静态确定 —— 气泡图固定传 `config.theme.fontSize + 12.0`（默认 12 → 24px）作为 `xLabelHeight`；其余同族图都按 `if (config.xAxis.labelRotate == 0.0) fontSize + 12.0 else 48.0` 预留。`ChartFrame.drawXAxisNumeric` 在旋转时把标签放在 `plot.bottom() + 10`、`anchor: "end"`（`ChartFrame.cj:297-309`），需要约 48px 的竖直空间。
- **描述**：`labelRotate` 是公开配置（`ChartConfig.cj:79`），气泡图开了旋转后只有 24px 底部空间，标签会与 `xAxis.title`（`plot.bottom() + fontSize + 14`）重叠并可能超出画布。`add-f-chart-bubble/design.md:11` 声称「复用 `drawXAxisNumeric` 与 `drawYAxis`」，但留白没有跟着复用同一规则。
- **建议**：把这段「按是否旋转决定 xLabelHeight」的判断抽成 `ChartFrame` 的静态辅助（如 `ChartFrame.xLabelHeight(config)`），四处调用点统一；气泡图改为调用它。

### [轻微][存量] #12 `CalendarHeatmapAlias_test` 注释写「七个星期标签」，与断言 4 及 proposal 冲突

- **位置**：`f_chart/src/CalendarHeatmapAlias_test.cj:71`；对照 `f_chart/doc/spec/add-f-chart-calendar-alias/proposal.md:8`（「4 个星期标签」）、`CalendarHeatmapAlias_test.cj:76`（断言 `== 4`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「文档与实现不符」（注释即文档）
- **证据**：静态确定 —— 注释是「三个月与七个星期标签」，同一用例下一行断言 `count(svg, "class=\"weekday-label\"") == 4`；实现侧 `CalendarHeatmapChart` 固定输出 4 条星期标签（`CalendarHeatmapChart.cj:223-233`，`for (position in 0..4)`，取周一/三/五/日或周日/二/四/六）。
- **描述**：日历热力图是 7 行 × N 列的网格，注释里的「七个星期」大概是「七行」的口误；但对读注释的人来说，它和断言、和 proposal 的「4 个星期标签」同时对不上，会怀疑到底该断言 4 还是 7。
- **建议**：注释改成「三个月与四个星期标签（网格 7 行，只标注 4 行）」。

### [轻微][存量] #13 `calendar-alias/design.md` 称别名测试方式与 M104 一致，但 M104（`tag-cloud`）没有 `*Alias_test.cj`

- **位置**：`f_chart/doc/spec/add-f-chart-calendar-alias/design.md:8`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「文档与实现不符 / 指向不存在的结构」
- **证据**：静态确定 —— `ls f_chart/src | grep -i alias` 只有 4 个：`CalendarHeatmapAlias_test.cj`、`FunnelAlias_test.cj`（M86）、`SankeyAlias_test.cj`（M67）、`WaterfallAlias_test.cj`（M87）；`doc/chart-json-spec.md:241` 的 M104 是 `tag-cloud` / `WordCloudChart.cj`，对应测试是 `TagCloud_test.cj`（`grep -rln "tag-cloud" f_chart/src` 命中 `TagCloud_test.cj`、`WordCloudChart.cj`、`ChartGallery_test.cj`）。
- **描述**：design 用「与 M86/M87/M104 的别名测试方式一致」来说明本测试的定位，但三个参照物里 M104（`tag-cloud`）并没有独立别名测试，仓库里第 4 个 `*Alias_test` 对应的是 M67（`sankey`）。参照清单错了一项，按它去核对会找不到对应文件。
- **建议**：把 M104 换成 M67，写成「与 M67/M86/M87 的别名测试方式一致」。

### [轻微][存量] #14 子弹图 proposal 声称新增的 `bulletRange` 函数不存在，区间校验被内联

- **位置**：`f_chart/doc/spec/add-f-chart-bullet/proposal.md:13`；实现 `f_chart/src/BulletChart.cj:73-95`
- **来源**：存量（`git blame -L 73,95` = `a7273653af 2026-11-08`；快照模式无基线可比）
- **判据**：review-checklist §13「文档过期 / 指向不存在的符号」、§14.1「承诺了但没实现」
- **证据**：静态确定 —— `grep -rn "bulletRange\b" f_chart/src` 只命中 `bulletRangeColor`，`bulletRange` 既无定义也无调用；proposal 写「新增内部 `bulletRangeColor` 与 `bulletRange`（校验并返回排序后的区间上界）」，实际「非空 + 正数 + 严格递增」三项校验全部内联在 `draw` 的 `ranges` 解析循环里（`BulletChart.cj:73-95`），无法脱离完整 JSON 单测。
- **描述**：文档读者会去找一个不存在的函数；更实质的损失是 proposal 当初抽出该函数的目的（可单独单测区间校验）落空，`[50, 50, 100]` 这类负向用例只能通过整图渲染触发。
- **建议**：二选一——按 proposal 抽出 `internal func bulletRange(json: ChartJson, itemPath: String): Array<Float64>` 并把 `73-95` 搬进去，或把 proposal 该行改成「区间校验内联于 `BulletChart.draw`」。

## 优化可行性方案

> 不是缺陷，是「还能更好」。两条都**没有**改前/改后测量数据，因此只作方案登记，不改写成收益结论。

### [堆内存] Bland-Altman 同一批测量对在内存里存了 3 份

- **现状**：`BlandAltmanChart.draw` 同时持有 `pairs: ArrayList<BlandAltmanPair>`（每项 2 个 `Float64` 字段的对象）、`rawPairs: ArrayList<Array<Float64>>`（每项一个 2 元素 `Float64` 数组），随后 `pairs.toArray()` 与 `rawPairs.toArray()` 各再复制一份（`BlandAltmanChart.cj:59-75`）；`blandAltmanStats` 内部又建 `diffs: ArrayList<Float64>`（`226-232`）。即 n 个测量对 → 约 3n 个 `Float64` 值 + 2n 个对象头 + 4 次容器扩容复制，且 `pairs` / `rawPairs` 在整段绘制期间都存活。
- **方案**：`blandAltmanStats` 直接吃 `ArrayList<BlandAltmanPair>`（`diff` 字段已在），删掉 `rawPairs`；`pairs` 用 `toArray()` 后的数组传给 `stats`，不保留两份表示。
- **预期**：n 个测量对的常驻对象数从约 2n 降到 n（少一半容器与对象头），临时分配从 4 次容器复制降到 1 次。
- **代价**：`blandAltmanStats` 的签名变化影响其单元测试（`BlandAltmanChart_test.cj:83-107` 目前直接传 `Array<Array<Float64>>`），需同步改用新入参；语义不变。
- **验证**：同一份 10 万点输入连续渲染 100 次，比较 `getAllocatedHeapSize()` 峰值与稳定态 RSS，同时断言 SVG 输出字节完全一致。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 8 份插入排序合并成一次 `O(n log n)` 排序

- **现状**：`BoxScatterChart.sortValues`（`245-260`）等 8 处实现都是插入排序，复杂度 `O(n²)`；`BoxScatterChart` 对每个分组各排一次（`163`），组内样本数由用户数据决定，无上限。
- **方案**：抽 `internal func sortedFloats(values: Array<Float64>): Array<Float64>`，8 处替换；排序基元换成标准库排序，`quantileSorted` 语义（最近秩取下标）不变。
- **预期**：单组 n 个样本的比较次数从 `n²/4` 量级降到 `n log n`，n = 10 000 时约 3 个数量级的比较次数差；由于整个 `draw` 还包含 SVG 字符串拼接，端到端收益需实测。
- **代价**：输出必须逐字节可复现（SVG 是快照资产），需确认稳定排序后重复值顺序不影响任何 class 序列；`quantileSorted` 的取值口径不允许变化。
- **验证**：`cjpm bench -O2`，同一份 JSON（含 1/10/100 组 × 10/1000/10000 样本）跑改前改后，取中位数与 P95；再比对 107 个快照 SVG 的 diff 为空。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

> 没有性能测试数据支撑的猜测，不进 `todo.md` / `tasks.md`，只用于下一轮补数据。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 箱线散点的插入排序在大样本下成为热点 | `f_chart/src/BoxScatterChart.cj:163,245-260` | 排序自耗时占 `draw` 的比例、n 的分布 | `cjprof record` 跑单组 1k / 10k / 100k 样本的 `box-scatter` 渲染各 100 次，看 `sortValues` self time 占比 |
| 2 | Bland-Altman 右端标签的动态宽度计算不会带来可观开销 | `f_chart/src/BlandAltmanChart.cj:144-147` | 三条 `chartTextWidth` 调用的耗时（相对整图） | 分段计时，10 万点场景对比加/不加预计算的 `draw` 耗时 |
| 3 | 气泡图多系列 + 千级点数时，`bubbleRadius` 与标签文本是主要分配源 | `f_chart/src/BubbleChart.cj:206-226` | 每轮分配字节数、GC 次数 | `cjprof heap` + 分配量计数，输入 5 系列 × 2000 点 |

## 文件覆盖

> 与 `{workdir}/files/f_chart.part4.txt` 一一对应，20 行全部读完。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_chart/doc/spec/add-f-chart-bland-altman/specs/chart-rendering/spec.md` | .md | ✅ | 与实现基本一致；x/y 非负约束见 #1，右端标签见 #6，越界见 #7 |
| 2 | `f_chart/doc/spec/add-f-chart-bland-altman/tasks.md` | .md | ✅ | 4 项均已勾选，`BlandAltmanChart.cj` / `_test.cj` 均存在；「全量测试通过」无法静态复核（本轮不跑构建） |
| 3 | `f_chart/doc/spec/add-f-chart-box-scatter/design.md` | .md | ✅ | 分组/统计/绘制规则与实现一致；排序算法未记载，见 #3 |
| 4 | `f_chart/doc/spec/add-f-chart-box-scatter/proposal.md` | .md | ✅ | 5 个 class 名（box/median/whisker/cap/point）与实现逐一对上；`jitter` 默认 0.15 一致 |
| 5 | `f_chart/doc/spec/add-f-chart-box-scatter/specs/chart-rendering/spec.md` | .md | ✅ | `[1,3,5,7,10]` 与 `quantileSorted`（最近秩）一致；标签长度校验一致 |
| 6 | `f_chart/doc/spec/add-f-chart-box-scatter/tasks.md` | .md | ✅ | 已勾选，`BoxScatterChart_test.cj` 存在 |
| 7 | `f_chart/doc/spec/add-f-chart-boxplot/design.md` | .md | ✅ | 箱宽上限未记载，见 #8；其余与实现一致 |
| 8 | `f_chart/doc/spec/add-f-chart-boxplot/proposal.md` | .md | ✅ | 五数对象格式、顺序校验、异常值圆点均一致 |
| 9 | `f_chart/doc/spec/add-f-chart-boxplot/specs/chart-rendering/spec.md` | .md | ✅ | 4 类目 → 4 box / 4 median / 8 whisker / 3 outlier 与实现计数一致 |
| 10 | `f_chart/doc/spec/add-f-chart-boxplot/tasks.md` | .md | ✅ | 已勾选，`BoxPlotChart_test.cj` 存在 |
| 11 | `f_chart/doc/spec/add-f-chart-bubble/design.md` | .md | ✅ | 半径公式/退化取值一致；透明度与描边未实现，见 #10；留白见 #11 |
| 12 | `f_chart/doc/spec/add-f-chart-bubble/proposal.md` | .md | ✅ | `sizeRange` 默认 `[4,30]` 与 `BubbleChart.cj:87-88` 一致 |
| 13 | `f_chart/doc/spec/add-f-chart-bubble/specs/chart-rendering/spec.md` | .md | ✅ | 校验分支与实现一致；`[20,10]` → `InvalidValue` 成立 |
| 14 | `f_chart/doc/spec/add-f-chart-bubble/tasks.md` | .md | ✅ | 已勾选，`BubbleChart_test.cj` 存在 |
| 15 | `f_chart/doc/spec/add-f-chart-bullet/design.md` | .md | ✅ | 色阶终点见 #5，目标线高度见 #9；横轴范围规则与实现一致 |
| 16 | `f_chart/doc/spec/add-f-chart-bullet/proposal.md` | .md | ✅ | 3 个 class 名与实现一致；`bulletRange` 未单独成函数（校验内联在 `draw`），见 #14 |
| 17 | `f_chart/doc/spec/add-f-chart-bullet/specs/chart-rendering/spec.md` | .md | ✅ | 区间/值条/目标线计数成立；颜色单调性见 #5 |
| 18 | `f_chart/doc/spec/add-f-chart-bullet/tasks.md` | .md | ✅ | 已勾选，`BulletChart_test.cj` 存在 |
| 19 | `f_chart/doc/spec/add-f-chart-calendar-alias/design.md` | .md | ✅ | M106 = M44 与 `doc/chart-json-spec.md:243` 一致；别名测试参照清单见 #13 |
| 20 | `f_chart/doc/spec/add-f-chart-calendar-alias/proposal.md` | .md | ✅ | 90 格 / 3 月份 / 4 星期与 `CalendarHeatmapChart` 实现及测试断言一致；测试注释见 #12 |

合计：`.cj` 0 个 / `.md` 20 个 / 共 20 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 1 | 命中 #1（负数被拒，正确性/契约）。安全性无外部输入注入面：所有数据经 `ChartJson` 类型校验，SVG 由 `f_svg` 构造器转义；设计上 spec→实现一一对应，无分层问题（纯函数库） |
| §1 死代码 | 0 | 本部分无 `.cj`；对本部分文档所指的 6 个实现文件逐个核对了 `internal` 符号引用：`blandAltmanStats` / `boxScatterBounds` / `bubbleRadius` / `bulletNumber` / `bulletRangeColor` 均被生产代码调用（非仅测试），`BlandAltmanPair` / `BoxScatterGroup` / `BulletItem` / `BubblePoint` / `BubbleSeries` 均在 `draw` 中使用；未发现 `return` 后同层语句或未使用 `import`（`std.math.*` 各文件都用到 `minFloat`/`maxFloat`/`abs`/`sqrt`）。死代码的完整判定留给包含 `src/**` 的子轮 |
| §2 重复逻辑 | 3 | #2（数值字段读取 4 处实现 + 1 处跨图复用）、#3（插入排序 8 份）、#4（轴范围 3 套）。已两两比对这 6 个实现文件的 `draw` 主体摘要：Bland-Altman / BoxPlot / BoxScatter / Bubble / Bullet 的「读取 series → 校验 → 求范围 → 取色 → 建 frame → 画图」骨架相似但字段与图形不同，不构成同语义实现 |
| §3 空实现 | 0 | 逐文件检查：无 `TODO` / `FIXME` / `UnsupportedException`；`BoxPlotChart.cj:124` 的 `case None => ()` 是可选字段 `outliers` 缺失的正常分支，`BubbleChart.cj:106` 同理（`sizeRange` 可选），均非吞异常 |
| §4 栈溢出 | 0 | 6 个实现文件无递归；`quantileSorted`、`swarmOffsets`、`sortValues`、`blandAltmanStats` 均为单层循环，深度不随输入增长 |
| §5 OOM | 0 | 无全局容器、无缓存、无 `Array(n, repeat:)` 预分配；所有容器规模 = 输入规模。Bland-Altman 的 3 份副本是常数倍（3n 个 `Float64`），已归入「优化可行性方案 · 堆内存」，不构成 OOM 面 |
| §6.1 热点瓶颈 | 0 | 未提供 `cjprof` / `cjpm bench` 数据；`scope.md` 的「已有性能资料」只有 `docs/LocalMode.md`、`docs/LocalMode-O2-Plan.md`，不含本模块 profile。热点结论全部降级为「待验证假设」#1–#3 |
| §6.2 大粒度锁 | 0 | 6 个实现文件无锁、无 `synchronized`、无原子类型；`draw` 全部是局部状态 |
| §6.3 并发串行 | 0 | 无 `spawn` / `Future` / 线程池调用 |
| §6.4 低效算法 | 1 | #3 的插入排序（`O(n²)`，复杂度静态确定）；是否成热点缺数据，收益归「待验证假设」#1，不单列缺陷 |
| §7 降堆内存方案 | 1 | 「Bland-Altman 三份副本」，`无基线（待验证）` |
| §8 降 CPU 方案 | 1 | 「8 份插入排序合并为 `O(n log n)`」，`无基线（待验证）` |
| §9 local mode 可行性 | 0 | 未评估为方案：`draw` 返回 `String`（必然逃逸），中间对象（`ArrayList`、`SvgBuilder` 缓冲）在函数内创建但被 builder 持有到末尾；缺少峰值内存基线，且 `f_chart` 目前未启用 `--enable-local-mode`，收益无法证明，故只写结论不列方案 |
| §11 现有代码的 BUG（存量） | 5 | #1（负数被拒）、#5（色阶取模）、#6（标签溢出）、#7（越界不裁剪）、#11（旋转标签留白）。已核对这 6 个实现文件的边界与空值：空 `data`、单元素组、全相等值、`span = 0`（Bland-Altman `87-94`、BoxScatter `229-230`）、`max <= min` 均有显式处理，未发现除上述之外的差一或除零 |
| §12 并发安全与锁粒度 | 0 | `Chart` 契约声明「纯函数语义」（`Chart.cj:24-26`），6 个实现类只有 `let` 字段（`init` 后不可变）与 `draw` 内局部变量，无静态可变状态、无单例、无回调注册；并发调用互不共享可变数据，线程封闭成立 |
| §13 文档一致性（.md） | 7 | #5、#8、#9、#10、#12、#13、#14（另 #1、#6、#7 兼具规格漂移性质）。已逐条把 proposal/design/spec delta 的字段名、默认值、class 名、计数场景与实现对齐；`tasks.md` 只核对产物文件是否存在，测试是否真跑过记 `待确认` |
| §14 功能完备性与 README 覆盖 | 1 | 5 个图类型（`bland-altman` / `box-scatter` / `boxplot` / `bubble` / `bullet`）都在 `ChartConfig.parse(data, "<type>")` 处校验类型且类已实现，`Chart` 由调用方直接实例化（模块无注册表），不存在「注册了没人用」；命中 #14（proposal 声称的 `bulletRange` 未实现），其余 proposal 列出的 class 名逐个在实现中命中；M106 复用 M44 与 `doc/chart-json-spec.md:243` 一致 |
| 文件覆盖（§13 等） | 20/20 | 无缺文件 |

## 模块统计

> 仅统计本部分（第 4/37 部分）的 20 个文件。

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 7 |
| 轻微 | 7 |
| 优化方案（堆内存 / CPU） | 1 / 1 |

## 总评

本部分是 5 个新增图类型的 OpenSpec 记录与 1 个别名里程碑的收尾文档，规格颗粒度不错：requirement 与 scenario 写到了 class 名、计数、默认值和异常 `kind`，逐条对照实现后大部分都成立（`[1,3,5,7,10]` 的五数与 `quantileSorted` 的最近秩口径、`jitter` 默认 0.15、`sizeRange` 默认 `[4,30]`、子弹图横轴覆盖规则、日历 90 格 / 3 月份 / 4 星期都能对上）。真正的风险不在「文档写得对不对」，而在文档背后那层被复用的实现：

- **契约面**：Bland-Altman 借用了子弹图的数字读取，把「非负」这条不相干约束带进了测量值场景（#1），这是本轮唯一的「合法输入被拒」类缺陷；#7 的越界不裁剪则取决于尚未写清的裁剪契约。
- **结构面**：数字字段校验 4 处实现、插入排序 8 份、轴范围 3 套（#2/#3/#4），是同一种「复制粘贴再微调」的痕迹，已经产生过一次语义漂移（#1），后续每次收紧都会漏。
- **呈现面**：#5 的色阶取模回绕、#6 的固定 52px 标签预留属于会直接影响读图的坐标/边界问题，建议排在 #1 之后修。

没有阻塞项（无崩溃、无数据损坏、无并发/内存风险），上述 7 条一般项建议随下次 `f_chart` 迭代一并处理；7 条轻微项多是 design 文本与实现的 10% 级偏差、参照清单笔误或未落地的内部函数，可批量核对后一次性修文档。存量 14 条，是否纳入修复待用户决定。本部分未跑构建与测试（`tasks.md` 的「全量测试通过」只能静态核对产物存在），性能结论全部停留在假设层。
