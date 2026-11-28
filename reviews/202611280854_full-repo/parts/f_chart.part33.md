# f_chart 模块审查报告（第 33/37 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_chart/src`（本部分 20 个文件：9 个 `.cj` 图表实现 + 11 个 `*_test.cj`，0 个 `.md`）
- **基线**：工作区快照（master 与 sts/1.3.x 同一提交 `120fd2542`，`git diff` 为空）⇒ 全部问题来源记「存量」
- **审查重点**：渲染/布局算法正确性、坐标与数值边界、OOM、资源与内存、死代码、重复逻辑
- **报告版本**：v1（分部分报告；仅覆盖 `files/f_chart.part33.txt` 的 20 个文件，合并由主 Agent 完成）

## 发现

### [严重][存量] 残差图 / ROC 图 x 轴方向镜像（`LinearScale` 参数顺序与其文档语义相反）

- **位置**：`f_chart/src/RocChart.cj:123`、`f_chart/src/ResidualChart.cj:112`
- **来源**：存量（快照模式无基线；两行均在本部分文件内，`git blame` 只能追到快照提交）
- **判据**：review-checklist §11（契约与实现不符、语义与注释不符）、§10 正确性
- **证据**：静态确定 —— `ChartScale.cj:22` 的注释写明「`topPixel` 对应最大值，`bottomPixel` 对应最小值」，`scale()`（`ChartScale.cj:36-43`）按 `bottomPixel - t*(bottomPixel-topPixel)` 计算。设 `plot.x=60`、`plot.right()=560`：
  - 传 `(plot.x, plot.right())` ⇒ `topPixel=60`、`bottomPixel=560`，`scale(min)=560`（右）、`scale(max)=60`（左）⇒ **值越小越靠右**；
  - 传 `(plot.right(), plot.x)` ⇒ `scale(min)=60`（左）、`scale(max)=560`（右）⇒ 正常方向。
  同模块 `LineChart.cj:177`、`AreaChart.cj:158`、`ScatterChart.cj:128`、`RidgeChart.cj:129` 都用后者；`ResidualChart.cj:112`、`RocChart.cj:123` 用前者。
- **描述**：这两张图的数值 x 轴自右向左递增：ROC 的假阳性率 0 落在右边界、1 落在左边界，曲线与对角参考线整体左右镜像；残差图的「拟合值」轴同样反向。刻度线（`ChartFrame.drawXAxisNumeric`，`ChartFrame.cj:291-309`）用同一个比例尺，因此标签也跟着反向，输出不会报错、只是读图结论被反向。`RocChart_test.cj:60-65` 只统计元素个数，覆盖不到方向。
- **建议**：两处改为 `LinearScale(xRange[0], xRange[1], frame.plot.right(), frame.plot.x)`；或给 `LinearScale` 增加一个具名构造（`horizontal(min, max, left, right)`）把方向收敛到一处，避免同类调用继续按「x 在前」猜参数。改完补一条断言坐标的用例（如 `x=0` 的元素 `x` 坐标应等于 `plot.x`）。
- **范围外提示**：`grep "let xScale = LinearScale("` 在非 `tui` 代码命中 30 处，两种参数顺序各 15 处，属同一系统性写法分歧，其余 13 处（`PrChart`、`EcdfChart`、`CalibrationChart`、`LiftChart`、`GainChart`、`SurvivalChart`、`VolcanoChart`、`ManhattanChart`、`PdpChart`、`LearningCurveChart`、`LassoPathChart`、`InfluenceChart`、`BlandAltmanChart`）不在本部分，未计入统计。

### [一般][存量] ROC 对角参考线用 y 比例尺映射 x 值

- **位置**：`f_chart/src/RocChart.cj:147-148`
- **来源**：存量
- **判据**：review-checklist §11（边界/语义错配）
- **证据**：静态确定 —— 端点写成 `xScale.scale(xRange[0]), yScale.scale(xRange[0])` 与 `xScale.scale(xRange[1]), yScale.scale(xRange[1])`，第二个坐标把 **x 域**的值喂给了 **y 比例尺**。
- **描述**：x、y 轴范围相同（默认 0–1）时刚好正确；一旦用户写 `"yAxis": {"min": 0, "max": 2}` 或 `"xAxis": {"min": -0.1}`，参考线端点就落在错误的 y 上（例如从 y=0 拉到 y=1，而非 0 拉到 2），不再是「y=x」参考线。这是配置可触发的静默错图。
- **建议**：端点改为 `(xScale.scale(xRange[0]), yScale.scale(yRange[0]))` → `(xScale.scale(xRange[1]), yScale.scale(yRange[1]))`，并补一条 `yAxis.max ≠ xAxis.max` 的用例断言端点 y 坐标。

### [一般][存量] 雷达图忽略 `legend.show` 配置

- **位置**：`f_chart/src/RadarChart.cj:63`
- **来源**：存量
- **判据**：review-checklist §14（配置项被读取却未生效）、§11（契约不符）
- **证据**：静态确定 —— `let legendVisible = series.size > 1`，未与 `config.legend.show` 相与；同模块 `RaincloudChart.cj:148`、`ResidualChart.cj:93`、`RocChart.cj:106`、`ScatterChart.cj:111` 都写成 `config.legend.show && …`。
- **描述**：传 `"legend": {"show": false}` 且有两个以上系列时，图例依然输出；`legend.position` 等配置也被部分绕过（`ChartFrame` 只在 `legendVisible` 为真时生效）。用户无法关闭图例。
- **建议**：改为 `let legendVisible = config.legend.show && series.size > 1`；补一条 `legend.show=false` + 双系列的用例，断言 `class="legend"` 计数为 0。

### [一般][存量] 玫瑰图画布过小时静默输出空图

- **位置**：`f_chart/src/RoseChart.cj:113-122`
- **来源**：存量
- **判据**：review-checklist §11（静默失效）、§3（开关打开走进空分支）
- **证据**：静态确定 —— `maxRadius = minFloat(width-…, height-…-40.0)/2.0 - 20.0` 可能为负；循环里 `if (slice.value > 0.0 && radius > 0.0)` 不满足就什么也不画，函数照常返回完整 SVG（只有背景与标题）。
- **描述**：`width`/`height` 较小时（例如 120×120，减去 padding 与 40 的固定留白后 `maxRadius < 0`），得到一张没有任何扇区、也没有任何报错的图，调用方无法区分「数据为空」与「画布太小」。同模块 `RadarChart.cj:88-91` 对同类情形明确 `throw chartInvalidValue("width", "画布太小…")`，两者行为不一致。
- **建议**：`maxRadius <= 0.0` 时抛出与雷达图一致的 `ChartException(InvalidValue)`；若要保留「空图」语义，至少在返回前给出可观测信号并在文档写明。

### [一般][存量] 桑基图垂直布局与连线偏移没有上限约束

- **位置**：`f_chart/src/SankeyChart.cj:193-215`（层高与 y 起点）、`f_chart/src/SankeyChart.cj:226-234`（出/入边偏移累加）
- **来源**：存量
- **判据**：review-checklist §11（边界越界）、§10 正确性（布局算法）
- **证据**：静态确定 —— 每层 `totalHeight = nodeGap*(k-1) + Σ max(throughput/maxThroughput*maxNodeHeight, 6.0)`，`y = top + (plotHeight - totalHeight)/2.0`；`totalHeight > plotHeight` 时 `y < top`，最后一个节点 `y + height` 必然超过 `bottom`，代码没有任何裁剪或缩放。同一层节点数 `k` 越大越严重（每个节点至少 6px + 12px 间距，`plotHeight=300` 时 `k>16` 即溢出）。第二条：`outOffsets/inOffsets` 按 `strokeWidth+1` 单调累加，且 `strokeWidth = max(link.value/maxFlow*22, 1)` 与节点高度无关，节点出边多时连线带宽总和可远超节点矩形高度。
- **描述**：节点数较多的单层场景下，节点会画到标题区或画布外、互相压盖；连线从节点框外起笔，看起来像连到了相邻节点。输出仍是合法 SVG，不会报错。
- **建议**：`totalHeight > plotHeight` 时按 `plotHeight/totalHeight` 等比压缩（或按层内最大阈值截断并给出「已省略」标记）；出/入边偏移改为按 `node.height / ΣstrokeWidth` 归一化后再定位中心线。补一条「单层 30 节点」的用例断言所有 `rect` 的 `y+height <= plot.bottom()`。

### [一般][存量] 散点图 / 散点矩阵对空 `data` 静默通过，与同模块其余图表契约不一致

- **位置**：`f_chart/src/ScatterChart.cj:75-88`（`parsePoints` 不过滤空数组，`ScatterChart.cj:175-203`）、`f_chart/src/ScatterMatrixChart.cj:77-104`
- **来源**：存量
- **判据**：review-checklist §14（只做了一半的分支 / 契约漂移）、§3（空数据当合法）
- **证据**：静态确定 —— 两处只调 `json.requiredArray("data")`，随后 `for (item in …getItems())`，空数组不产生任何行为；`ScatterChart.cj:221-247` 的 `resolveXRange/resolveYRange` 用 `hasData=false` 兜底成 0–1。对照：`RaincloudChart.cj:71-73`、`ResidualChart.cj:55-57`、`RocChart.cj:56-58`、`RidgeChart.cj:72-74`、`RoseChart.cj:61-63`、`ScatterMatrixChart.cj` 之外的同类图都抛 `chartInvalidValue(…, "数据不能为空")`。
- **描述**：同一份 JSON 契约下，`"data": []` 在 5 张图里是 `InvalidValue`，在散点图/散点矩阵里是「成功但空图」。调用方若靠异常判断数据质量问题，会漏掉这两类。`SankeyChart` 的 `links: []` 同样允许（只画节点），是否属于同类问题需产品确认。
- **建议**：两个 `data` 解析入口补 `if (items.isEmpty()) throw chartInvalidValue("${path}.data", "数据不能为空")`；`links` 若允许为空，请在 `doc/chart-json-spec.md` 明写。

### [一般][存量] 数值轴前置样板在多个图表中整段复制（含 47 处 `xLabelHeight` 字面重复）

- **位置**：`f_chart/src/ResidualChart.cj:78-113`、`f_chart/src/RocChart.cj:91-124`、`f_chart/src/ScatterChart.cj:92-129`；`xLabelHeight` 片段另见 `f_chart/src/RaincloudChart.cj:153-157`、`ResidualChart.cj:104-108`、`RocChart.cj:117-121`、`ScatterChart.cj:122-126`
- **来源**：存量
- **判据**：review-checklist §2（换控制流/跨文件复制、字面量复制）
- **证据**：静态确定 —— 三段代码逐行同构：`xTicks/yTicks = config.*Axis.values.isEmpty() ? chartNiceTicks(...) : ...` → `xLabels` 循环 → `maxYLabelWidth` 循环 → `xLabelHeight = if (labelRotate == 0.0) { fontSize+12.0 } else { 48.0 }` → `ChartFrame(config, legendVisible, maxYLabelWidth+12.0, xLabelHeight)` → 两个 `LinearScale` → `SvgBuilder/ChartSvgKit/drawBackground/drawTitle`，只有变量名与是否有 `time` 轴分支不同。`grep "labelRotate == 0.0"` 在模块内命中 47 个文件，全部是同一段 if-else。
- **描述**：同一套边距/刻度/比例尺装配逻辑散落 47 处，已经出现漂移：`xLabelHeight`、`maxYLabelWidth+12.0`、`legendVisible` 的判定在各图之间不同（见上文雷达图条目），任何一次边距调整都要改 47 个文件且必然漏改。不是「为可读性刻意展开」——它是 300 行级的同构复制。
- **建议**：在 `ChartFrame`（或新 `ChartAxisKit`）里加一个 `internal func numericAxes(config, xRange, yRange): (Array<Float64>, Array<Float64>, Array<String>, ChartFrame)` 之类的入口，把刻度、标签宽度、`xLabelHeight`、`plot` 一次算完；先迁移本部分 3 张图，再按同样方式收敛其余 44 处。差异点（time 轴格式化、`legend.show` 组合）作为参数显式传入，不要靠复制保留。

### [轻微][存量] 插入排序在 4 处换类型复制

- **位置**：`f_chart/src/RocChart.cj:188-203`、`f_chart/src/RaincloudChart.cj:320-335`（另有 `f_chart/src/PrChart.cj:197-212`、`f_chart/src/SurvivalChart.cj:275-290`）
- **来源**：存量
- **判据**：review-checklist §2（只改类型名）
- **证据**：静态确定 —— 四段函数体逐行一致，仅元素类型（`RocPoint`/`Float64`/`PrPoint`/`SurvivalPoint`）与比较字段（`.x`/自身/`.x`/`.time`）不同；`RocChart.sortPoints` 与 `PrChart.sortPoints` 连参数名、临时变量名都相同。
- **描述**：目前四份实现等价、无行为漂移，但「稳定 + 确定性」这一约定靠四份手写代码各自维持，新增点集类型时会继续复制第五份。
- **建议**：抽一个模块内 `internal func stableSortBy<T>(items: ArrayList<T>, less: (T, T) -> Bool): Array<T>`（保持插入排序实现即可，语义无变化），四处改为传比较器。不要顺手换标准库排序——先证 `std.sort` 在当前 SDK 下的稳定性，否则会改变同 x 重复点的输出顺序、破坏「确定性」用例。

### [轻微][存量] 散点矩阵读入系列名却从不使用，且不画图例

- **位置**：`f_chart/src/ScatterMatrixChart.cj:25`、`30`、`75`、`104`
- **来源**：存量
- **判据**：review-checklist §1（读了不用）、§14（能力接线缺失）
- **证据**：静态确定 —— `grep -n "name" ScatterMatrixChart.cj` 只有定义（25/30）、赋值（75/104）四处，无任何读取点；整个文件没有 `drawLegend` 调用，多系列时颜色与系列名无法对应。
- **描述**：多系列散点矩阵会给每组点不同颜色，但既没有图例也没有标签，读者无法判断颜色归属；`name` 字段是纯死字段。
- **建议**：补 `frame.drawLegend`（或矩阵下方自绘图例）把 `name`/`color` 用起来；若确定不支持多系列，则在解析处直接拒绝 `series.size > 1` 并删掉 `name` 字段。

### [轻微][存量] 玫瑰图错误文案与判据不符

- **位置**：`f_chart/src/RoseChart.cj:88-90`
- **来源**：存量
- **判据**：review-checklist §11（语义与注释/文案不符）
- **证据**：静态确定 —— `if (maxValue <= 0.0) throw chartInvalidValue(…, "数值总和必须大于 0")`，判断的是**最大值**，不是总和。
- **描述**：`[0, 0, 5]` 这类数据总和 > 0 但前两个扇区被静默跳过，报错文案又声称校验的是总和，误导调用方去排查数据求和。
- **建议**：文案改为「最大值必须大于 0」；若确实要拦「全零」，现有判据已覆盖，无需改逻辑。

### [轻微][存量] 雷达图重复计算同一个标签坐标

- **位置**：`f_chart/src/RadarChart.cj:102-107`
- **来源**：存量
- **判据**：review-checklist §2（同文件内同输入同输出的重复计算）
- **证据**：静态确定 —— `point` 与 `labelPoint` 调用参数完全相同（`centerX, centerY, radius, 1.0, index, indicators.size`），随后只用 `labelPoint`。
- **描述**：每绘制一个指标多算一次 `cos/sin`，属可删的重复计算与冗余变量，不影响输出。
- **建议**：删掉 `labelPoint`，直接用 `point`（或把轴端点与标签锚点合并成一次局部变量）。

### [轻微][存量] 测试只统计元素个数，坐标方向与数值无法被覆盖

- **位置**：`f_chart/src/RocChart_test.cj:60-65`、`f_chart/src/ScatterChart_test.cj:41-53`、`f_chart/src/RadarChart_test.cj:55-56`（11 个测试文件同一模式）
- **来源**：存量
- **判据**：review-checklist §10（可测试性）、§11（缺陷未被用例拦住）
- **证据**：静态确定 —— 断言全部形如 `count(svg, "class=\"roc-point\"") == 6`、`svg.contains("女装")`，没有一条断言 `x`/`y` 坐标、刻度顺序或数值区间；上文 x 轴镜像、对角线错位两条缺陷因此全绿。
- **描述**：现有用例能守住「有没有画」和「参数校验」，守不住「画在哪」。这正是本轮两条渲染缺陷存活的直接原因。
- **建议**：每个图表补 1–2 条坐标断言（用 `SvgParser.parse` 取 `circle`/`line` 的 `cx`/`x1` 属性，断言最小值的像素小于最大值），优先补 `RocChart`（x∈[0,1] 边界固定，最容易断言）。

### [轻微][存量] 测试辅助 `draw` / `count` 在 11 个测试文件各写一份

- **位置**：`f_chart/src/RadarChart_test.cj:25-37`、`f_chart/src/RaincloudChart_test.cj:24-36`、`f_chart/src/ScatterMatrixChart_test.cj:24-36` 等 11 处
- **来源**：存量
- **判据**：review-checklist §2（字面量/实现复制）
- **证据**：静态确定 —— 每个测试类的 `private func draw`（一行 `XxxChart().draw(JsonValue.fromStr(json).asObject())`）与 `private func count(svg, needle)`（`indexOf` 循环计数）逐行相同；`grep -rn "func count(svg: String, needle: String)"` 在模块内命中 106 个文件。
- **描述**：测试基础设施被复制 106 份，任何一处修 bug（例如 `count` 用 `needle.toArray().size` 每次重新编码字符串）都要改 106 个地方。属测试代码重复，不影响产品行为。
- **建议**：在 `f_chart/src/testutil`（或测试目录下的 `ChartTestSupport.cj`）提供 `internal func chartCount(svg: String, needle: String)` 与 `internal func drawChart(chart: Chart, json: String)`，各测试文件改为引用。

## 优化可行性方案

### [堆内存] 去掉图表装配阶段的中间 `ArrayList` 副本

- **现状**：每张图在 `draw` 里至少保留 2–4 份同长度集合：`RaincloudChart.cj:105-113`（`labels`）+ `172-177`（`names`、`colors`）→ 再 `toArray()` 传给 `drawLegend/drawXAxis`；`ResidualChart.cj:88-91`、`126-131` 同型；`ScatterMatrixChart.cj:108-117` 把 `allRows.toArray()` 放在 `for (index in 0..variableCount)` **循环内**，每列都重新物化一次行数组（O(变量数 × 样本数) 次指针拷贝）。
- **方案**：`ScatterMatrixChart.cj:116` 把 `allRows.toArray()` 提到循环外；`names/colors/labels` 改为在需要时直接按下标取值（或让 `drawLegend` 接受 `Array<String>` 之外的只读视图），避免 `ArrayList → Array` 的一次性拷贝。
- **预期**：单次绘制减少 2–3 个与输入等长的临时数组；`ScatterMatrix` 在 10 变量 × 1000 样本时省去 9 次行数组拷贝。对象数与字节量需按上述输入实测。
- **代价**：`ChartFrame.drawLegend` 签名若改会波及全模块 40+ 调用点；只做「提前 `toArray`」这一步零风险。
- **验证**：`getAllocatedHeapSize()` 前后对照 + 单次 `draw` 的分配采样，同输入同并发，取中位数。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 排序与路径拼接的重复实现收敛

- **现状**：`RocChart.cj:188-203` / `RaincloudChart.cj:320-335`（及范围外 `PrChart.cj:197`、`SurvivalChart.cj:275`）是插入排序，最坏 O(n²)；`Raincloud.drawBox` 每次绘制都对整组数据排一次序。路径字符串用 `StringBuilder` 逐点拼接的写法在 `RadarChart.cj:147-154`、`RadarChart.cj:236-243`、`RaincloudChart.cj:244-253`、`RidgeChart.cj:169-181`、`RidgeChart.cj:186-200`、`RocChart.cj:153-162` 各写一遍（其中 `RidgeChart` 在同一组 `points/densities` 上算了两遍 `y` 并拼两个 `StringBuilder`）。
- **方案**：① 排序收敛为一个 `stableSortBy`，若确认 `std.sort` 在当前 SDK 下稳定则换 O(n log n)（**先用 `cangjie-doc-lookup` 核对 `std.sort` 签名与稳定性，未核对前不要动**）；② `RidgeChart` 的 area/line 合并为一次遍历：先算 `Array<Float64> ys`，area 路径 = line 路径 + 两条回到 baseline 的 `L`；③ 模块内加 `ChartPathBuilder`（`moveTo/lineTo/close`）替换 6 处手写 `"M … L …"`。
- **预期**：`RidgeChart` 每行少一遍 `O(samples)` 浮点运算与一次 `StringBuilder` 增长；点集 n > 1000 时排序从 O(n²) 降到 O(n log n)。收益比例需实测。
- **代价**：换排序实现会改变同值元素的相对顺序（若不稳定），会破坏「确定性」用例；`ChartPathBuilder` 增加一层间接。
- **验证**：`cjpm bench -O2`，输入取 `RocChart` 100/1000/5000 点、`RidgeChart` 4 系列 × 80 采样、`Raincloud` 12/1000 值；同时用现有 `deterministic` 用例做等价性回归（同输入两次输出必须逐字节相同）。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 核密度采样是雨云图/山脊图的绘制热点（每图 `48×n`、`81×n` 次 `exp`） | `RaincloudChart.cj:234-239`、`RidgeChart.cj:154-162` | 自耗时占比 | `cjprof record` 绘制 12 组 × 1000 值的雨云图与 20 系列山脊图，取 `gaussianKde` self time |
| 2 | 桑基图 `indexOfNode` 的线性查找在节点/链接数增大后成为主要耗时（O(n·m)） | `SankeyChart.cj:101`、`118-121`、`137-139`、`223-225`、`264-271` | 实际耗时随 n、m 的曲线 | 构造 200 节点 / 1000 链接输入，分段计时 `draw` 前后半段 |
| 3 | 插入排序在 ROC 点数 > 1000 时成为瓶颈 | `RocChart.cj:188-203` | n = 100/1000/5000 的单次耗时 | `cjpm bench -O2`，同输入取中位数与 P95 |
| 4 | 路径 `StringBuilder` 拼接占单次绘制 CPU 的比例 | `RadarChart.cj:146-159`、`RocChart.cj:153-162` | self time 占比 | `cjprof record` 跑 200 点散点/ROC，看 `StringBuilder.append` 占比 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_chart/src/QQChart_test.cj` | .cj | ✅ | 测试；覆盖 `QQChart` 外部行为，被测实现不在本部分 |
| 2 | `f_chart/src/RadarChart.cj` | .cj | ✅ | 见发现 #3、#10 |
| 3 | `f_chart/src/RadarChart_test.cj` | .cj | ✅ | 计数型断言，见 #12、#13 |
| 4 | `f_chart/src/RaincloudChart.cj` | .cj | ✅ | 见 #7、#8；`chartTextWidth`/`swarmOffsets` 用法已核对 |
| 5 | `f_chart/src/RaincloudChart_test.cj` | .cj | ✅ | 空数据用例与实现一致 |
| 6 | `f_chart/src/ResidualChart.cj` | .cj | ✅ | 见 #1、#7 |
| 7 | `f_chart/src/ResidualChart_test.cj` | .cj | ✅ | 覆盖含 0 的 y 范围，未覆盖 x 方向 |
| 8 | `f_chart/src/RidgeChart.cj` | .cj | ✅ | 见 #8（重复遍历）、xScale 方向正确 |
| 9 | `f_chart/src/RidgeChart_test.cj` | .cj | ✅ | `ridgeAmplitude` 边界有覆盖 |
| 10 | `f_chart/src/RocChart.cj` | .cj | ✅ | 见 #1、#2、#8 |
| 11 | `f_chart/src/RocChart_test.cj` | .cj | ✅ | 见 #12 |
| 12 | `f_chart/src/RoseChart.cj` | .cj | ✅ | 见 #4、#9；单扇区 360° 圆弧依赖 SVG 端点近似一致语义，未判缺陷（待确认） |
| 13 | `f_chart/src/RoseChart_test.cj` | .cj | ✅ | 未覆盖小画布分支 |
| 14 | `f_chart/src/SankeyAlias_test.cj` | .cj | ✅ | 别名复用 `SankeyChart`，与 `type=sankey` 解析一致 |
| 15 | `f_chart/src/SankeyChart.cj` | .cj | ✅ | 见 #5、#8；`sankeyLayers` 有界（`nodeCount` 轮）已核对，无栈溢出 |
| 16 | `f_chart/src/SankeyChart_test.cj` | .cj | ✅ | 未覆盖单层节点过多 |
| 17 | `f_chart/src/ScatterChart.cj` | .cj | ✅ | 见 #6、#7 |
| 18 | `f_chart/src/ScatterChart_test.cj` | .cj | ✅ | 见 #12 |
| 19 | `f_chart/src/ScatterMatrixChart.cj` | .cj | ✅ | 见 #6、#9、#7（`allRows.toArray()` 在循环内） |
| 20 | `f_chart/src/ScatterMatrixChart_test.cj` | .cj | ✅ | 未覆盖空 `data` 与多系列 |

合计：`.cj` 20 个 / `.md` 0 个 / 共 20 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 3 | 正确性：x 轴镜像、对角线错配、桑基越界；设计：3 处手绘标题绕过 `ChartFrame`、散点矩阵无图例；语言特性：`Option` 均用 `match` 显式展开，未发现静默丢弃；安全性：本部分所有数值经 `formatSvgNumber`、所有文本经 `ChartSvgKit.text → SvgBuilder.text`（`f_svg/src/SvgAuthoringBuilder.cj:186` 注明「转义由 `SvgWriter` 负责」），无手拼属性/文本，未发现注入面 |
| §1 死代码 | 1 | 已逐个检查 `private`（`parseIndicators`/`parseSeries`/`radarPoint`/`polygonPath`/`drawCloud`/`drawBox`/`residualRange`/`resolveXRange`/`sortPoints`/`resolveRange`/`indexOfNode`/`parsePoints`/`resolveXRange`/`resolveYRange` = 14 个）与 `internal`（`clamp01`/`sortRaincloud`/`ridgeAmplitude`/`roseRadius`/`sankeyLayers`/`residualXRange`/`residualYRange`/`columnRange` = 8 个）全部有调用者（全仓 `grep -w`，排除 `.worktrees`）；命中 1 条：`MatrixSeriesData.name` 读了不用。`public` 图表类对外可达，不判 |
| §2 重复逻辑 | 3 | 已两两比对 20 个文件里 40 余个函数体的「输入-输出-副作用」：命中数值轴前置样板（含 47 处 `xLabelHeight`）、插入排序 4 份、路径 `M/L` 拼接 6 处；测试辅助 `draw/count` 11 份计入 #13 |
| §3 空实现 | 0 | 无空函数体、无 `TODO/FIXME`、无 `catch (_:Exception){}`；`case None => ()` 均为可选字段正常缺失（`bandwidth`/`auc`/`color`），`case "none" => ()` 是 symbol 关闭的显式无操作 |
| §4 栈溢出 | 0 | 本部分无递归：`sankeyLayers` 是「外层 `nodeCount` 轮 + 内层边数」的双层循环（`SankeyChart.cj:284-296`），深度恒定，无自引用结构遍历 |
| §5 OOM | 0 | 未发现按不可信长度预分配或无界容器：所有集合长度均与输入数组同阶，绘制结束即释放；`SvgBuilder` 全量拼串是 SVG 输出的固有形态，未按 §5 判缺陷（降内存方案见优化方案） |
| §6.1 热点瓶颈 | 0 | 未提供 `cjprof`/bench 数据，热点不成立；已把核密度采样、`indexOfNode`、插入排序、路径拼接 4 项列入待验证假设 |
| §6.2 大粒度锁 | 0 | 本部分无锁：`draw` 内所有状态均为局部变量，无 `synchronized`/`Mutex` |
| §6.3 并发串行 | 0 | 无 `spawn`/`Future`/线程池调用 |
| §6.4 低效算法 | 2 | 静态复杂度可判的两处：插入排序 O(n²)（4 份，见 #8）、桑基 `indexOfNode` 线性查找 × 每链接 2 次（O(n·m)，见 #5 描述与待验证假设 #2）；`ScatterMatrixChart.cj:116` 的循环内 `toArray()` 计入优化方案。均未给「已变热点」的结论 |
| §7 降堆内存方案 | 1 | 中间 `ArrayList`/`toArray` 副本，证据状态 `无基线` |
| §8 降 CPU 方案 | 1 | 排序与路径拼接收敛，证据状态 `无基线` |
| §9 local mode 可行性 | 0 | 各 `draw` 的临时对象（`points`/`densities`/`StringBuilder`）生命周期确实限于函数内，但 `draw` 返回的 `String` 与 `JsonObject` 入参逃逸，且没有峰值内存数据，按 checklist §9「没有前后峰值数据只能是待验证假设」未列为方案 |
| §11 现有代码的 BUG（存量） | 6 | 已核对本部分所有边界：空数组（`series`/`data`/`nodes`/`links`）、单元素数组（`boxScatterBounds` 在 n=1 时返回全同值，`GaussianKde` 用 `defaultBandwidth` 兜底）、除零（`maxValue`/`maxFlow`/`span` 均有兜底）、`Option` 展开；命中 x 轴镜像、对角线错配、图例配置被忽略、小画布静默空图、桑基越界、空 `data` 契约漂移 |
| §12 并发安全与锁粒度 | 0 | 本部分无全局 `var`、无静态可变字段、无单例：`SankeyNode` 的 `var layer/throughput/x/y/height` 是每次 `draw` 内新建的局部图元，无跨线程共享路径 |
| §14 功能完备性与 README 覆盖 | 2 | 本部分无 `.md`，无法做文档对照（模块 README 在其他部分）；命中：散点矩阵无图例（`name` 未接线）、`RadarChart` 的 `legend.show` 配置未接线 |
| 文件覆盖（§13 等） | 20/20 | 无缺失；本部分无 `.md`，§13 不适用 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 1 |
| 一般 | 6 |
| 轻微 | 6 |
| 优化方案（堆内存 / CPU） | 1 / 1 |

存量缺陷 13 条（本部分全部为存量），是否纳入修复待用户决定。

## 总评

这 9 张图的整体结构是健康的：输入校验密集（每个字段都有 `path` 级定位与 `ChartException` 分类）、无递归、无全局可变状态、无锁，`draw` 基本满足 `Chart` 契约要求的纯函数语义；测试覆盖面在「参数校验」维度上相当扎实（每图 6–10 条用例，缺字段/错类型/越界/确定性都有）。

风险集中在两处：

1. **坐标方向**。`LinearScale` 的 `(topPixel, bottomPixel)` 参数顺序与其文档语义（`topPixel`=最大值）要求 x 轴必须反着传，而模块内 30 处调用各写一半。本部分的 `RocChart.cj:123`、`ResidualChart.cj:112` 落在错误的一半上，ROC 曲线与残差图整体左右镜像；测试只看元素个数，完全拦不住。这是本轮唯一建议优先修的阻塞项，且应连带把另外 13 处同类调用一起核对（范围外提示）。
2. **契约漂移**。同一份 JSON 在 9 张图里有 3 种「空数据」处理（抛 `InvalidValue`、抛 `MissingField`、静默出空图）、2 种图例开关语义（看 `legend.show` 与只看系列数）、3 套标题绘制（`ChartFrame.drawTitle` 与 3 处手写且忽略 `subtitle`/`titleAlign`）。这些单独看都是「轻微」，合起来意味着调用方无法对 `f_chart` 建立统一预期，建议在合并后的模块报告里作为一条「契约统一」专项排期。

其余（桑基越界、玫瑰图小画布、插入排序与轴样板重复）可排期处理：桑基与玫瑰属边界补强，重复样板属 47 文件级的收敛工作，收益是可维护性而非性能。所有性能相关结论本轮均无基线，只进了「待验证假设」，不作为缺陷计入统计。
