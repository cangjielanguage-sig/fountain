# f_chart 模块审查报告（模块第 28/37 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_chart/src`（本部分 20 个文件：10 个实现 + 10 个测试）
- **基线**：工作区快照（master 与 sts/1.3.x 同一提交 `120fd2542`，`git diff` 为空）⇒ 全部问题来源记「存量」
- **审查重点**：渲染/布局算法正确性、坐标与数值边界、OOM、资源与内存、死代码、重复逻辑（`_dispatch.md` 模块重点表）
- **报告版本**：分部分报告 v1（part28，供主 Agent 合并进 `docs/review/2026-11-28/f_chart_v2.md`）

本部分覆盖图表：`density` / `differential-flame` / `donut` / `dot` / `dot-density-map` / `dot-strip` / `dumbbell` / `ecdf` / `error-bar` / `flame`。

## 发现

### [一般][存量] `ecdf` 的 X/Y 比例尺实参顺序颠倒，整张图被旋转 180°

- **位置**：`f_chart/src/EcdfChart.cj:144-145`
- **来源**：存量（`git blame` 指向 `2845ac7dca`，2026-11-08，早于本轮快照基线）
- **判据**：review-checklist §10（布局算法正确性）/ §11（语义与注释不符）
- **证据**：静态确定 —— `LinearScale` 的构造约定写在 `f_chart/src/ChartScale.cj:22`（「`topPixel` 对应最大值，`bottomPixel` 对应最小值」），`scale()` 实现为 `bottomPixel - (value-min)/span*(bottom-top)`（`ChartScale.cj:36-43`）。正确写法见同模块 `DumbbellChart.cj:133`、`HistogramChart.cj:118`：X 轴传 `(plot.right, plot.x)`，Y 轴传 `(plot.y, plot.bottom)`。EcdfChart 两处都传反：`LinearScale(xMin, xMax, frame.plot.x, frame.plot.right())` 使最小值落在 `plot.right`、最大值落在 `plot.x`；`LinearScale(yMin, yMax, frame.plot.bottom(), frame.plot.y)` 使 yMin 落在顶部。
- **描述**：所有 x 值、y 值、`drawXAxisNumeric`（195）与 `drawYAxis`（164）的刻度位置都用这两个 scale，于是 ECDF 曲线、起始竖线（175）和两轴刻度一起被点对称翻转：累积频率从左上向右下递减，x 轴刻度从右往左递增。现有测试只统计 `class="ecdf-line"` 出现次数（`EcdfChart_test.cj:54-56`）与文本包含关系（60-65），不校验坐标，因此测不到。
- **建议**：改为 `LinearScale(xMin, xMax, frame.plot.right(), frame.plot.x)` 与 `LinearScale(yMin, yMax, frame.plot.y, frame.plot.bottom())`；补一条坐标断言用例（如 `yScale.scale(yMax)` 必须等于 `frame.plot.y`）。

### [一般][存量] `ecdf` 阶梯路径缺少最后一段跃升，曲线止于 `(n-1)/n` 而非 1

- **位置**：`f_chart/src/EcdfChart.cj:178-186`（`position + 1 < points.size` 条件在 182 行）
- **来源**：存量（`2845ac7dca`）
- **判据**：review-checklist §11（边界差一 / 与规格冲突）；承诺源 `f_chart/doc/chart-json-spec.md:966`（「实现排序后绘制阶梯累计频率」）
- **证据**：静态确定 —— `ecdfPoints` 返回 `points[i] = (x_i, (i+1)/n)`（`EcdfChart.cj:208-210`）。路径先 `M (x0, yMin)`、`V y_0`，随后每个 `position` 只画 `H x_i` 并在 `position+1 < size` 时补 `V y_{i+1}`。最后一个下标 `n-1` 只画到 `H x_{n-1}`，没有对应的 `V y_n = 1.0`，路径终点为 `(x_last, (n-1)/n)`。
- **描述**：n≥2 时 ECDF 都画不到 100%，曲线顶端恒缺一级台阶（n=1 恰好由开头的 `V firstY` 补上，属侥幸正确）；读图会把最大值处的累计频率低估 `1/n`。
- **建议**：循环结束后补 `path.append(" V ${formatSvgNumber(yScale.scale(points[points.size - 1][1]))}")`；或把循环改为「先 H 到 x_i，再 V 到 y_i」的统一步骤并补上首个 `V`。补一条 `n=3` 的路径断言（末尾 `V` 值等于 `yScale.scale(1.0)`）。

### [一般][存量] `error-bar` 线性/时间 X 轴比例尺实参同向颠倒

- **位置**：`f_chart/src/ErrorBarChart.cj:172`
- **来源**：存量（`git blame` 指向 `7477fb9c22`，2026-11-08 16:59）
- **判据**：review-checklist §10（坐标边界）/ §11（契约与实现不符）
- **证据**：静态确定 —— `LinearScale(xRange[0], xRange[1], frame.plot.x, frame.plot.right())`，与 `ChartScale.cj:22` 的约定相反，也与同模块横向数值轴写法（`DumbbellChart.cj:133`、`BulletChart.cj:154`）相反。类别轴分支不受影响（`BandScale`，174 行），只有 `xAxis.type` 为 `linear`/`time` 时命中。
- **描述**：连续 X 轴下误差线与中心点位置整体镜像（x 越大越靠左），`drawXAxisNumeric`（225）的刻度也反向递增。测试 `supportsNumericX` / `supportsTimeX`（`ErrorBarChart_test.cj:90-125`）只统计元素个数，无法发现。
- **建议**：改为 `LinearScale(xRange[0], xRange[1], frame.plot.right(), frame.plot.x)`；补一条 `x=10` 必须落在 `x=20` 左侧的坐标断言。

### [一般][存量] `dumbbell` 把 X 比例尺传给 `drawYAxis`，左侧数值刻度与网格线错位越界

- **位置**：`f_chart/src/DumbbellChart.cj:152`
- **来源**：存量（`git blame` 指向 `dd85af4fc7`，2026-11-08 19:53）
- **判据**：review-checklist §10（布局正确性）/ §11（与规格冲突）；承诺源 `f_chart/doc/chart-json-spec.md:502`（哑铃图 `yAxis.type` 为 `category`）
- **证据**：静态确定 —— `ChartFrame.drawYAxis`（`ChartFrame.cj:168-202`）用 `y := scale.scale(tick)` 定位，并固定画在 `plot.x - 8`；第 152 行传入的是第 133 行的水平 `xScale`（值域 → 像素在 `plot.x..plot.right`）。样例 `min=0,max=100` 时刻度 y 落在约 `plot.right..plot.x`（≈776..100），远超 `plot.y..plot.bottom`（≈40..430）。对照同样画横向数值轴的 `HorizontalBarChart.cj:105-112`，它是手工用 `xScale` 画竖网格、不调 `drawYAxis`。
- **描述**：画布左侧出现一串属于 X 轴的数字刻度（位置随机、多数落到绘图区外），同时 `yAxis.grid` 默认 `true`（`ChartConfig.cj:213`）会画出位置无意义的横网格线；168-178 行正确的类目标签与这批错位刻度重叠，输出图形明显破版。测试 `drawsAxes`（`DumbbellChart_test.cj:73-78`）只断言 `svg.contains("100")`，测不到位置。
- **建议**：删除第 152 行；若需要网格，按 `xScale` 画竖线（照 `HorizontalBarChart.cj:105-112`）或改用 `drawXAxisNumeric` 自带的刻度。

### [一般][存量] `donut` 单扇区（100%）用圆弧闭合，起终点重合导致整圆不渲染

- **位置**：`f_chart/src/DonutChart.cj:108-123`（拼路径在 116-119）
- **来源**：存量（`git blame` 指向 `3919464d7d`，2026-11-08 16:29）
- **判据**：review-checklist §10（渲染正确性）/ §11（边界：占比恰为 1）；承诺源 `f_chart/doc/chart-json-spec.md:1272-1274`（「环形图」）
- **证据**：静态确定 —— `fractions[index] * 360.0` 在单数据项时为 `360.0`，`endAngle = angle + 360`，于是 `startX/startY` 与 `endX/endY` 完全相同；SVG 规范中起终点重合的 `A` 弧命令被忽略，剩下的 `M 圆心 L 起点 … Z` 只形成一条退化三角形。
- **描述**：`data` 只有一项（如 `[{"name":"全部","value":100}]`）时，环形图只剩圆心到圆周的一条细线，`donut-hole` 圆也照常画在白底上，用户看到的是空白画布。现有用例 `drawsSlicesAndHole`（`DonutChart_test.cj:59-63`）用 4 个扇区，覆盖不到。同样的写法出现在 `PieChart.cj:114-147`（范围外提示，同一根因）。
- **建议**：`sweep >= 359.999` 时改用整圆：`<circle cx cy r>` + 内孔（或两条 180° 弧）。测试补一条单扇区用例，断言存在 `circle`（或两条 `A` 弧）。

### [一般][存量] `differential-flame` 根节点 `value2=0` 时宽度全部为 0，整图静默空白

- **位置**：`f_chart/src/DifferentialFlameChart.cj:157-158`（`rootWidth` 回退）、`f_chart/src/DifferentialFlameChart.cj:214-222`（宽度只按 `value2` 计算，216 行）
- **来源**：存量（`2845ac7dca` 同批，当前行 blame 为 `dd85af4fc7`）
- **判据**：review-checklist §11（静默失效 / 分支只做了一半）
- **证据**：静态确定 —— 校验允许「`value1>0 且 value2=0`」（93-98 只要求两者非负、至少一个大于 0），并校验 `child2 <= node.value2`（195-198），因此一个「全部删除」的差分树（根 `value1=100,value2=0`）是合法输入。此时 `rootWidth` 回退到 `value1`（157），而 `layoutNode` 的 `node.width = node.value2 / rootWidth * plotWidth`（216）仍用 `value2`，所有节点 width 均为 0；`drawNode` 的标签条件 `width > 文本宽 + 6`（242）也不成立，图上什么都不画，也不报错。
- **描述**：全部帧都减少的差分火焰图输出为空白（仅背景+标题），用户无法区分「没数据」与「全部归零」。
- **建议**：宽度与 `rootWidth` 使用同一口径——要么都用 `max(value1, value2)`（推荐，能画出被删除的宽度并用颜色表达），要么在 `value2=0` 时直接抛 `InvalidValue`。补一条「全部减少」用例断言 rect 宽度之和 > 0。

### [一般][存量] 火焰图四趟递归遍历深度等于节点层数且无上限，深链输入会栈溢出

- **位置**：`f_chart/src/FlameChart.cj:111`（`validateValues`）、`:112`（`assignDepth`）、`:140`（`layoutNode`）、`:152`（`drawNode`），递归体分别在 `:181-183`、`:191-193`、`:200-203`、`:245-247`；`f_chart/src/DifferentialFlameChart.cj:119`、`:120`、`:158`、`:170`，递归体在 `:199-201`、`:209-211`、`:218-221`、`:256-258`
- **来源**：存量（`2845ac7dca`）
- **判据**：review-checklist §4（无界递归：树遍历深度由输入决定）
- **证据**：静态确定（深度无上限）+ 需实测（溢出阈值）—— 递归深度 = 根到最深叶的层数，`nodes` 的层级与个数完全由 JSON 决定；唯一守卫是 `depth > total`（`FlameChart.cj:168`、`DifferentialFlameChart.cj:186`），而 `total = parsed.size`，对一条 N 层链式 `parent` 来说 `depth` 从 0 递增到 N-1，永远不满足 `> total`，守卫不构成深度上限。按每帧约 100–200 B、常见 1 MB 栈估算，约 5k–10k 层即可耗尽，具体阈值需实测。
- **描述**：构造 N 层链的 `nodes`（N 取 1 万即可）时，四个递归函数依次下钻，`validateValues` 先在栈上崩溃（进程级崩溃，非异常）。模块内无 `maxDepth`/节点数上限，`offline-flame` 的 `maxDepth` 也没有出现在这两张图上。
- **建议**：改为显式栈迭代（建树用队列，depth/layout/draw 用后序+层序），或在解析阶段限制层数（如 `maxDepth` 默认 64，超出抛 `InvalidValue`）并给 `nodes.size` 一个上限。测试补一条 2000 层链的用例断言不崩溃。

### [轻微][存量] 轴范围推导与图例装配样板在 6 张图里各写一遍，填充比例已出现漂移

- **位置**：范围推导 `DensityChart.cj:102-138`、`DotChart.cj:216-265`、`DotStripChart.cj:101-123`、`DumbbellChart.cj:90-110`、`EcdfChart.cj:90-104`、`ErrorBarChart.cj:241-289`；图例装配 `DensityChart.cj:212-221`、`DotChart.cj:94-103`、`DotStripChart.cj:158-164`、`EcdfChart.cj:157-163`
- **来源**：存量（各文件引入 commit）
- **判据**：review-checklist §2（换算复制 / 近似重复）
- **证据**：静态确定 —— 六处函数体压成摘要后完全同构：「遍历数据求 min/max → span<=0 时置 1 → 两端按比例外扩 → `axis.min`/`axis.max` 覆盖 → `max<=min` 抛错」，差异只有外扩比例（0.02 / 0.05 / 0.08）与错误路径文案；四处图例装配同构：「逐系列取 name 与 `color ?? colorAt(i)` → `drawLegend`」。
- **描述**：目前外扩比例的差异没有业务依据（同一「留白」语义三种系数），后续改边界规则要同时改六处，容易再漂移；图例装配重复使得「系列颜色是否与图元同源」这类一致性问题要逐图核对（参见 part27 的 ComboChart 颜色不一致问题）。
- **建议**：在 `ChartScale.cj` 增加 `chartAxisRange(dataMin, dataMax, padRatio, axis, path): Array<Float64>`（或返回 struct），在 `ChartFrame` 增加 `drawSeriesLegend(kit, names, colors, visible)`；外扩比例作为显式参数，语义差异参数化而不是复制。合并前先确认六处错误文案/路径是否需要保持各自 `series[0].data` 形式。

### [轻微][存量] `ErrorBarPoint.label` 只写不读，连续轴分支的 `label` 计算是死赋值

- **位置**：`f_chart/src/ErrorBarChart.cj:24`（字段）、`:31`（构造赋值）、`:94`（连续轴分支赋值，之后无读取）
- **来源**：存量（`7477fb9c22`）
- **判据**：review-checklist §1（读了不用 / 死字段）
- **证据**：静态确定 —— 全文件 `\.label` 只在 31 行赋值命中（`grep -n "\.label" ErrorBarChart.cj`）；绘制循环 197-220 只用 `point.x/y/low/high`，类目文案统一取 `categoryLabels`（223）。94 行的 `label = chartFormatTick(...)` 之后无任何读取。
- **描述**：`label` 字段对类目轴无用途（类目标签来自 `xAxis.labels`/数据顺序），连续轴写入的格式化文本也从不输出；属于兼容残留，误导读者以为点标签会参与绘制。
- **建议**：删除 `ErrorBarPoint.label` 与 94 行赋值；若确实想画点标签，则在 197-220 里真正使用它并加用例。

### [轻微][存量] `ecdf` 的 `points.isEmpty()` 分支不可达

- **位置**：`f_chart/src/EcdfChart.cj:168-170`
- **来源**：存量（`2845ac7dca`）
- **判据**：review-checklist §1（恒假分支）
- **证据**：静态确定 —— 57-61 行已保证每个 `series[].data` 非空，`ecdfPoints` 仅在 `count == 0` 时返回空（`EcdfChart.cj:205-207`），因此 `points.isEmpty()` 恒假。
- **描述**：防御性分支不会执行，且会让人误以为「空数据是允许的」——实际空数据在 59-61 行就抛错，两处语义矛盾。
- **建议**：删除该分支，或把空数据改成「跳过该系列」并把 59-61 行的报错一并去掉，两处只保留一种语义。

### [轻微][存量] `dot` 允许空 `data`，与其他图「数据不能为空」的契约不一致

- **位置**：`f_chart/src/DotChart.cj:44-48`（只校验 `series` 非空）、`:162-172`（`data` 允许为空数组）
- **来源**：存量（`git blame` 见文件引入 commit）
- **判据**：review-checklist §11（契约不一致 / 缺少边界校验）
- **证据**：静态确定 —— 同批实现均对空数据报 `InvalidValue`：`DensityChart.cj:67-69`、`DonutChart.cj:48-50`、`DotStripChart.cj:60-62`、`EcdfChart.cj:59-61`、`ErrorBarChart.cj:65-67`、`FlameChart.cj:55-57`；DotChart 无此检查，`resolveLabels` 得到 0 个标签（188-203），`BandScale(…, 0)` 的 `bandWidth` 为 0（`ChartScale.cj:57`），最终只画坐标轴与网格后正常返回。
- **描述**：同样的空数据，`dot` 静默输出空图、其他图抛 `ChartException`，调用方按统一错误处理时会漏掉这一类输入。
- **建议**：在 `parseSeries` 后加「任一 `values.isEmpty()` 抛 `chartInvalidValue("series[i].data", "数据不能为空")`」，与其他图对齐；若确认空图是刻意行为，则在规格里写明并补用例。

### [轻微][存量] `dot` 的 stem 基线固定取 0，0 不在 X 范围时限段越出绘图区

- **位置**：`f_chart/src/DotChart.cj:113`（`baseline = xScale.scale(0.0)`）、`:126-129`（从 `baseline` 画到 `valueX`）
- **来源**：存量
- **判据**：review-checklist §11（边界）
- **证据**：静态确定 —— `resolveRange` 在数据全为正时把 minimum 设为 0（243-247），此时基线正好在 `plot.x`；但用户显式 `xAxis.min > 0`（如 50）时，`xScale.scale(0.0)` 落在 `plot.x` 左侧（`scale` 无裁剪，`ChartScale.cj:36-43`），stem 从绘图区外画进来。
- **描述**：`xAxis.min=50` 之类的输入下，点图的牵引线穿过左边距压到类目标签上；无 `clipPath`，越界部分正常渲染。
- **建议**：基线改为 `maxFloat(xScale.scale(0.0), frame.plot.x)`，或按 `min(max(value, range.min), range.max)` 把基线夹到值域内；与 `HorizontalBarChart.cj:113` 的同类写法一起统一。

### [轻微][存量] `donut` 半径可为负，画布过窄时输出非法路径

- **位置**：`f_chart/src/DonutChart.cj:102-105`（半径公式）、`:141-144`（内孔圆）
- **来源**：存量（`3919464d7d`）
- **判据**：review-checklist §11（边界 / 数值）
- **证据**：静态确定 —— `radius = min(w-left-right, h-top-bottom-40)/2 - 20`，`ChartConfig` 只校验 `width/height > 0`（`ChartConfig.cj:180-184`）。`width=60`（默认 padding 24）时 `min(12, …)/2 - 20 = -14`，`A -14 -14 …` 与 `circle r="-14"` 都是非法 SVG；`innerRadius=0.55` 时内孔半径为负。
- **描述**：小画布输入不报错但产出渲染器无法解释的路径（多数渲染器直接丢弃该元素），用户得到空白环形图。
- **建议**：`radius` 计算后 `if (radius <= 0.0) throw chartInvalidValue("width", "画布过小，无法绘制环形图")`，或把下限夹到 `1.0` 并缩小内孔；`PieChart.cj:109-113` 有同一公式（范围外提示）。

### [轻微][存量] 本部分 10 个测试只统计 class 出现次数，未断言任何坐标，轴方向类缺陷全部漏检

- **位置**：`EcdfChart_test.cj:54-65`、`DumbbellChart_test.cj:73-78`、`ErrorBarChart_test.cj:90-125`、`DotChart_test.cj:41-53`，以及同批其余 `*_test.cj` 的 `count()` 断言
- **来源**：存量
- **判据**：review-checklist §11（测试未覆盖契约）/ §14.1（半成品）
- **证据**：静态确定 —— 本部分 10 个测试文件共用同一 `count(svg, needle)` 助手，断言形式只有「class 出现 N 次」「svg.contains(文本)」「两次输出相等」「SvgParser 可解析」四类，没有任何 `transform`/`x=`/`y=` 数值断言；上面 4 条轴/几何缺陷（EcdfChart 两条、ErrorBarChart、DumbbellChart）因此全部通过。
- **描述**：渲染类图表的契约核心是坐标，当前测试只能保证「元素存在」，无法防住镜像、越界、退化弧。
- **建议**：为每张图补 1-2 条坐标断言（如取 `class="dumbbell-high"` 的 `cx`，断言 high>low 时 `cx` 更大），或引入 SVG 快照测试（`ChartGallery_test.cj` 已有全量渲染入口，可作为快照来源）。

存量缺陷共 14 条（一般 7 / 轻微 7），是否纳入修复待用户决定。

## 优化可行性方案

> 不是缺陷，是"还能更好"。以下均无改前/改后对照数据，`证据状态` 一律为「无基线」，不进 `tasks.md`。

### [CPU] 火焰图建树与 id 查重是 O(n²)

- **现状**：`FlameChart` / `DifferentialFlameChart` 各有一处「每解析一个节点就线性扫已解析列表查重」（`FlameChart.cj:71-75`、`DifferentialFlameChart.cj:74-78`）和一处「每个节点线性找父节点」（`FlameChart.cj:99`、`DifferentialFlameChart.cj:107`），合计约 `n²` 次字符串比较（`findNode` 见 `FlameChart.cj:158-165`）。火焰图典型规模 2k–50k 节点。
- **方案**：解析时用 `HashMap<String, FlameNode>` 同时承担查重与父查找（一次 `add` 前 `contains`，建树时直接 `map[parentId]`），把 `parsed` 数组保留仅用于遍历。
- **预期**：比较次数从 `n(n-1)` 降到 `2n`；n=20k 时从约 4 亿次字符串比较降到 4 万次量级（按复杂度估算，未测）。
- **代价**：多一个 `HashMap`（n 个 entry，约 `n×48B`）；内存微增，行为不变。
- **验证**：`cjpm bench -O2` 或对 `draw()` 做分段计时，输入 2k / 10k / 50k 节点，比较改前改后中位数。
- **证据状态**：无基线（待验证，不进 tasks）

### [CPU] `density` 的核密度被算了两遍，每系列 202×n 次 `exp`

- **现状**：`DensityChart` 先对 101 个采样点求 `maxDensity`（`DensityChart.cj:140-151`），再在 `drawDensity` 里对同样的 101 个点重算一遍（`244-248`）。每次 `gaussianKde` 遍历全部 n 个值并调用 `exp`（`272-283`），即单系列 `2×101×n` 次 `exp`，3 系列、n=10k 时约 606 万次。
- **方案**：在 140-151 的循环里把每系列的 101 个密度值存进 `Array<Float64>`（或 `Array<Array<Float64>>`），`drawDensity` 直接复用并按 `xScale`/`yScale` 映射，去掉第二次 `gaussianKde`。
- **预期**：该图的 `exp` 调用与 KDE 遍历量减半（按复杂度估算，未测）。
- **代价**：每系列多 101 个 `Float64`（约 0.8KB），需把 `drawDensity` 的入参从 `series`+`bandwidth` 改成密度数组。
- **验证**：`cjprof record` 看 `gaussianKde` 自耗时占比与 `draw()` 总耗时；输入 3 系列 × 10k 值，改前改后中位数对照。
- **证据状态**：无基线（待验证，不进 tasks）

### [CPU] `ecdf` 依赖的 `sortRaincloud` 是插入排序，最坏 O(n²)

- **现状**：`ecdfPoints`（`EcdfChart.cj:201-212`）调用 `sortRaincloud`（`RaincloudChart.cj:320-341`，范围外文件），实现为插入排序：对随机输入平均 n²/4 次比较与搬移。ECDF 的输入就是原始数值数组，n 可达 10⁴–10⁵。
- **方案**：把 `sortRaincloud` 的实现改为 `std.sort`（或 `Array.sort` 稳定排序）；插入排序只在 n<32 的小数组上保留（小数组上更快且无分配）。ECDF 侧可顺带删除「先复制到 `ArrayList` 再 `toArray`」的一次拷贝。
- **预期**：n=10k 随机输入从约 2500 万次比较降到约 13 万次；n=100k 时差距两个数量级以上（复杂度估算，未测）。
- **代价**：排序稳定性若变化会影响等值点的绘制顺序（同值点在同一 x，帧位置一致，视觉无差），需保留「确定性」用例；该函数被 `RaincloudChart` 共用，需同步回归。
- **验证**：`cjpm bench -O2`，输入 1k / 10k / 100k 随机与升序/降序数组，比较中位数；跑 `RaincloudChart_test`、`ViolinChart_test` 回归。
- **证据状态**：无基线（待验证，不进 tasks）

### [堆内存] `ecdf` 为每个点物化 `[x, cumulative]` 双元素数组

- **现状**：`ecdfPoints` 返回 `Array<Array<Float64>>`，每点 2 个 `Float64` 数组（约 2 个对象 + 16B 数据，外加 `ArrayList` 扩容），n=100k 时约 20 万个短命数组；`draw` 随后逐点读 `points[i][0/1]`（`EcdfChart.cj:178-186`）即丢弃。
- **方案**：`ecdfPoints` 改为只返回排序后的 `Array<Float64>`（或直接返回 `points` 的 `x` 与 `i/n` 两个标量序列），绘制时在循环里用 `Float64(i+1)/n` 现算累计值；`draw` 内不再持有中间二维结构。
- **预期**：每系列减少约 `2n` 次小对象分配；n=100k 时峰值临时堆下降约 10–15MB 量级（按对象布局估算，未测）。
- **代价**：`ecdfPoints` 是 `internal` 且被 `EcdfChart_test.cj:70-86` 直接断言，签名变化需同步测试；`RaincloudChart` 不受影响。
- **验证**：`getAllocatedHeapSize()` 与 RSS，改前改后各跑 200 次 `draw()`（n=100k），比较分配总量与峰值。
- **证据状态**：无基线（待验证，不进 tasks）

## 待验证假设

> 没有性能测试数据支撑的猜测（热点、瓶颈、优化收益）。**不进 `todo.md` / `tasks.md`**，只用于下一轮补数据。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `gaussianKde` 是 `density` 图的主要自耗时点 | `f_chart/src/DensityChart.cj:272-283` | 自耗时占比、调用次数 | `cjprof record` 渲染 3 系列 × 10k 值，统计 `gaussianKde`/`draw` 占比 |
| 2 | 火焰图 O(n²) 查重在建树阶段占比超过 50% | `f_chart/src/FlameChart.cj:71-75,99`；`DifferentialFlameChart.cj:74-78,107` | 建树 vs 布局 vs 序列化分段耗时 | 分段计时 + `cjpm bench -O2`，输入 2k/10k/50k 节点 |
| 3 | `sortRaincloud` 插入排序在 n≥10k 时主导 `ecdf` 耗时 | `f_chart/src/EcdfChart.cj:202`；`RaincloudChart.cj:320` | 排序耗时占比、不同分布的差异 | `cjprof` + 随机/升序/降序各 10k、100k 输入 |
| 4 | ECDF 路径逐点 `formatSvgNumber` 字符串拼接是第二大开销 | `f_chart/src/EcdfChart.cj:171-186` | 字符串构造占比 | `cjprof record`，n=100k 单系列 |
| 5 | 火焰图 `rect`/`text` 的 SVG 序列化（`toSvgString`）占比可观 | `f_chart/src/FlameChart.cj:226-244` | 序列化耗时占比 | `cjprof`，5k 节点；对照 `builder` 与最终字符串长度 |

## 文件覆盖

> 与 `files/f_chart.part28.txt`（20 行）一一对应。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_chart/src/DensityChart.cj` | .cj | ✅ | 见「轴范围样板」「KDE 双算」与待验证假设 #1 |
| 2 | `f_chart/src/DensityChart_test.cj` | .cj | ✅ | 9 个用例，未断言坐标（见轻微「测试只统计 class」） |
| 3 | `f_chart/src/DifferentialFlameChart.cj` | .cj | ✅ | 见「rootWidth 回退」「递归深度」「与 FlameChart 重复」 |
| 4 | `f_chart/src/DifferentialFlameChart_test.cj` | .cj | ✅ | 12 个用例，未覆盖全减少输入 |
| 5 | `f_chart/src/DonutChart.cj` | .cj | ✅ | 见「100% 弧退化」「负半径」 |
| 6 | `f_chart/src/DonutChart_test.cj` | .cj | ✅ | 9 个用例，均为 4 扇区/校验类 |
| 7 | `f_chart/src/DotChart.cj` | .cj | ✅ | 见「空 data」「基线越界」 |
| 8 | `f_chart/src/DotChart_test.cj` | .cj | ✅ | 7 个用例，含 SvgParser 可解析断言 |
| 9 | `f_chart/src/DotDensityMapChart.cj` | .cj | ✅ | 无缺陷；数值经 `jsonNumberValue` 判有限（`ChartJson.cj:223`），viewBox/半径校验完整 |
| 10 | `f_chart/src/DotDensityMapChart_test.cj` | .cj | ✅ | 11 个用例，覆盖半径/权重/空点集负例 |
| 11 | `f_chart/src/DotStripChart.cj` | .cj | ✅ | 无缺陷；抖动范围由 `dotStripOffset` 保证 |
| 12 | `f_chart/src/DotStripChart_test.cj` | .cj | ✅ | 8 个用例，含抖动边界断言 |
| 13 | `f_chart/src/DumbbellChart.cj` | .cj | ✅ | 见「drawYAxis 传 xScale」 |
| 14 | `f_chart/src/DumbbellChart_test.cj` | .cj | ✅ | 7 个用例，`drawsAxes` 只判文本存在 |
| 15 | `f_chart/src/EcdfChart.cj` | .cj | ✅ | 见「轴反转」「末段缺失」「不可达分支」 |
| 16 | `f_chart/src/EcdfChart_test.cj` | .cj | ✅ | 6 个用例，`ecdfPoints` 只断言数值不断言路径 |
| 17 | `f_chart/src/ErrorBarChart.cj` | .cj | ✅ | 见「X 轴反转」「label 死字段」 |
| 18 | `f_chart/src/ErrorBarChart_test.cj` | .cj | ✅ | 11 个用例，连续/时间轴只统计元素数 |
| 19 | `f_chart/src/FlameChart.cj` | .cj | ✅ | 见「递归深度」「O(n²) 查重」 |
| 20 | `f_chart/src/FlameChart_test.cj` | .cj | ✅ | 11 个用例，无深链/大批量输入 |

合计：`.cj` 20 个 / `.md` 0 个 / 共 20 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 7 | 正确性 6 条（Ecdf ×2、ErrorBar、Dumbbell、Donut、DiffFlame）+ 设计 1 条（轴范围样板）；语言特性上均为「局部 `ArrayList` + `toArray` 惯用法」，无值/引用语义误用；安全性已核对：所有 JSON 文本/路径经 `SvgElement.escapeSvgText`/`escapeSvgAttribute`（`f_svg/src/SvgElement.cj:705-725`）转义，`kit.path` 的 `d` 属性同样走属性转义，无注入面；无硬编码凭据 |
| §1 死代码 | 2 | 已逐个搜引用：`gaussianKde`/`defaultBandwidth`（`DensityChart.cj:272,286`）另有 Raincloud/Ridge/Violin/ViolinBox 4 处调用；`differentialColor`、`dotDensityRadius`、`dotStripOffset`、`ecdfPoints`、`flameColorIndex`（另有 CirclePacking/Hive/Icicle/NodeLink/OfflineFlame/Sunburst/WordNetwork/tui 调用）；`DensitySeries`/`DiffFlameNode`/`DotSeries`/`DotDensityPoint`/`DotStripGroup`/`DumbbellItem`/`EcdfSeries`/`FlameNode` 均只在本文件使用但都被构造与读取，非死代码；`findNode`/`validateValues`/`assignDepth`/`layoutNode`/`drawNode`/`parseSeries`/`resolveLabels`/`validateLengths`/`resolveRange`/`indexOfLabel`/`resolveYRange`/`resolveXRange`/`drawDensity` 全部有调用者。命中 2 条：`ErrorBarPoint.label` 只写不读、`EcdfChart.cj:168` 不可达分支。public 的 10 个 `Chart` 实现与 `draw`/`init` 对外可达，不判；本部分无 `protected` 声明；未发现未使用 import（逐个核对 `std.math.*` 的 `exp/sqrt/pow/minFloat/maxFloat/cos/sin/floor/abs` 均有使用） |
| §2 重复逻辑 | 2 | 已把本部分 10 个实现文件的函数体压成「输入→输出→副作用」摘要两两比对：命中 2 条 —— `FlameChart` 与 `DifferentialFlameChart` 的解析/建树/`validateValues`/`assignDepth`/`layoutNode`/`drawNode` 近逐行重复（差异只是单值 vs `value1`/`value2`），记入「重复逻辑」条；六处轴范围推导 + 四处图例装配同构，记入「轴范围样板」条。测试里的 `count(svg, needle)`/`draw(json)` 助手 10 份重复按 checklist §2 误报边界（测试准备代码）不计；`DonutChart.cj:66-68` 与 `pieFractions`（`PieChart.cj:155-171`）的负值校验重复，随「负半径」条一并说明，未单独计数 |
| §3 空实现 | 0 | 逐文件核对：10 个 `Chart` 实现的 `draw` 均有实际解析与绘制逻辑；无 `TODO`/`FIXME`/`UnsupportedException`/空 `catch`；`match` 的 `case None => ()` 均为可选字段缺省（如 `DotDensityMapChart.cj:76` 无 regions、`DotChart.cj:134` 空值跳过），属正常可选语义；仅 `EcdfChart.cj:168` 是恒假分支，已归 §1 |
| §4 栈溢出 | 1 | 只命中火焰图两张（见「递归深度」条）；其余 8 张图无递归：`DensityChart`/`DotChart`/`DumbbellChart`/`EcdfChart`/`ErrorBarChart` 全为单层循环，`DonutChart`/`DotDensityMapChart`/`DotStripChart` 无自调用，`sortRaincloud` 为迭代 |
| §5 OOM | 0 | 逐图核算峰值：所有容器规模都是「输入元素数 × 常数」——`DensityChart` 额外 101 元素网格、`EcdfChart` 每点 2 个 `Float64` 数组（已列优化方案）、火焰图每节点 1 个类实例 + 子数组；无按报文字段预分配、无全局/静态容器、无缓存、无 `spawn`，`chartNiceTicks` 有 `guard < 1000` 上限（`ChartScale.cj:98-103`）。最坏输入 100k 点时临时堆在 10MB 量级，远低于默认堆，故不判 OOM（量化见「堆内存」方案） |
| §6.1 热点瓶颈 | 0 | 本模块无 bench/profile 数据（`scope.md` 未提供，本轮也未跑构建），热点结论不成立；已把 5 条疑似热点写入「待验证假设」，注明缺哪种数据与采法 |
| §6.2 大粒度锁 | 0 | 本部分代码无 `synchronized`/`Mutex`/`Atomic`，无锁可判 |
| §6.3 并发串行 | 0 | 无 `spawn`/`Future`/线程池/队列，全为单线程同步绘制 |
| §6.4 低效算法 | 2 | 命中 2 条：火焰图 `n²` 查重（`FlameChart.cj:71-75,99`）、`sortRaincloud` 插入排序（`EcdfChart.cj:202` 间接使用）；因无耗时数据，已降级为「优化可行性方案（CPU，无基线）」+ 待验证假设 #2/#3，不作为缺陷计数 |
| §7 降堆内存方案 | 1 | `ecdf` 的二维点数组物化（无基线）；其余图临时对象数与输入同阶且生命周期与 `draw()` 一致，无长期持有，不另列 |
| §8 降 CPU 方案 | 3 | 火焰图 `HashMap` 建树、`density` KDE 复用、`ecdf` 排序改 `std.sort`；均无基线 |
| §9 local mode 可行性 | 0 | 各 `draw()` 内确有大量短生命周期 `ArrayList`/`StringBuilder`，但收益口径是**峰值内存**，本轮无 `getUsedHeapSize`/RSS 前后对照，且 `Chart` 输出字符串必然逃逸（`exclave`），收益无法证明 ⇒ 不列为方案，仅作为后续可测项（需 `--experimental --enable-local-mode` + 峰值内存对照） |
| §11 现有代码的 BUG（存量） | 7 | 逐函数核对了空集合/空值/边界：`points[0]`/`groupArray[0].values[0]`/`items[0]` 之前均有非空校验（`ErrorBarChart.cj:65-67`、`DotStripChart.cj:46-62`、`DumbbellChart.cj:58-60`），`values[0]` 前有 `data` 非空（`DensityChart.cj:67-69`）；命中 7 条（Ecdf 轴反转、Ecdf 末段、ErrorBar X 轴、Dumbbell drawYAxis、Donut 100%、DiffFlame 全零宽、火焰图递归） |
| §12 并发安全与锁粒度 | 0 | 10 个图类只有 `init` 与 `draw`，字段为零（`DensityChart` 等的系列类型为每次调用内构造的局部对象），无可变共享状态；`Config`/`Theme` 为只读局部实例 ⇒ 线程封闭成立，无需同步。无锁粒度议题 |
| §14 功能完备性与 README 覆盖 | 0 | 本部分清单无 `.md`，README/规格覆盖核对留给含 `README.md` 的部分；实现侧无未接线字段：`DonutChart` 的 `innerRadius`/`centerText`/`startAngle`/`showPercent`、`FlameChart` 的 `orientation`/`colorBy`/`frameHeight`、`DifferentialFlameChart` 的 `colorRange`/`frameHeight`、`DotStripChart` 的 `jitter`/`dotSize`、`DotDensityMapChart` 的 `viewBox`/`radius` 均被读取并使用（与 `doc/chart-json-spec.md:168-2415` 的字段表一致）。唯一能力差异：`donut` 没有「显示扇区名称」选项（`PieChart` 有 `showPercent=false` 分支），规格未承诺，记待确认、不计入统计 |
| 文件覆盖（§13 等） | 20/20 | 无缺失文件；本部分不含 `.md`，故 §13 文档一致性 0 条 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 7 |
| 轻微 | 7 |
| 优化方案（堆内存 / CPU） | 1 / 3 |

（「待验证假设」5 条不计入统计。）

## 总评

本部分代码风格一致、校验普遍到位：每张图都先做字段存在性/类型/数值范围校验（含 `jsonNumberValue` 的有限性检查），错误路径统一走 `ChartException` 带 JSON 路径；10 个图类无可变状态，线程安全按构造即成立；没有空实现、没有吞异常、没有无界全局容器。资源与内存面上没有 OOM 风险点，只有 KDE 双算、火焰图 `n²` 查重、插入排序三处可优化（均无基线，不进修复清单）。

真正的问题集中在**渲染几何**，而不是数据校验：`ecdf` 与 `error-bar` 把 `LinearScale` 的 `topPixel/bottomPixel` 传反（图形整体镜像），`ecdf` 还缺最后一级阶梯，`dumbbell` 把 X 比例尺喂给 `drawYAxis` 导致左侧刻度错位越界，`donut` 单扇区因弧起终点重合而不渲染。这四类都属于「SVG 合法、测试全绿、肉眼一看就错」，根因是测试只统计 class 出现次数、从不校验坐标——这也是本部分最值得先补的基础设施（一条坐标断言就能防住上面 4 条中的 3 条）。`differential-flame` 的全零宽回退是同一类「静默空白」问题。火焰图两张的递归深度只受节点数约束，深链输入会崩进程，建议与 `offline-flame` 的 `maxDepth` 语义对齐。

按处置建议排序：坐标/轴类 5 条（Ecdf ×2、ErrorBar、Dumbbell、Donut）优先，改动小、影响直观；火焰图递归与 `DiffFlame` 宽度口径次之（需补负向用例）；重复逻辑（火焰图两文件、六处轴范围）与测试补强可排期，属结构性改善。存量 14 条是否纳入修复，待用户在门禁决定，本报告不代为取舍。

**范围外提示**（不计入本部分统计）：同批把 `LinearScale` 实参写反的还有 `BlandAltmanChart.cj:148-149`、`CalibrationChart.cj:129-130`、`GainChart.cj:125-126`、`LearningCurveChart.cj:195-196`、`LiftChart.cj:134-135`、`ManhattanChart.cj:165-166`、`LassoPathChart.cj:156-157`、`InfluenceChart.cj:138-139`、`PdpChart.cj:132-133`、`PrChart.cj:130-131`、`ResidualChart.cj:112-113`、`RocChart.cj:123-124`、`SurvivalChart.cj:168-169`；`PieChart.cj:114-147` 与 `DonutChart` 共用同一段扇区绘制代码（含 100% 退化），`PieChart.cj:109-113` 也有负半径公式。
