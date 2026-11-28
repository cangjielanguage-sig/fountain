# f_chart 模块审查报告（模块第 27/37 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_chart/src`（本部分 20 个文件：10 个实现 + 10 个测试）
- **基线**：工作区快照（master 与 sts/1.3.x 同一提交 `120fd2542`，`git diff` 为空）⇒ 全部问题来源记「存量」
- **审查重点**：渲染/布局算法正确性、坐标与数值边界、OOM、资源与内存、死代码、重复逻辑（`_dispatch.md` 模块重点表）
- **报告版本**：分部分报告 v1（part27，供主 Agent 合并进 `docs/review/2026-11-28/f_chart_v2.md`）

本部分覆盖图表：`chord` / `choropleth` / `circle-packing` / `combo` / `confusion-matrix` / `contour` / `control` / `correlation-matrix` / `decision-tree`，以及日期工具 `ChartTime` 与接口分派测试。

## 发现

### [一般][存量] 堆叠柱/百分比堆叠柱的所有分段使用同一颜色，与图例不符

- **位置**：`f_chart/src/ComboChart.cj:562-565`（缺省色回退在 564）、`f_chart/src/ComboChart.cj:630-633`（折线缺省色）、`f_chart/src/ComboChart.cj:651-654`（散点缺省色）
- **来源**：存量（快照模式无基线；`git blame` 指向该文件引入 commit）
- **判据**：review-checklist §10（正确性：同一语义的颜色在绘制与图例两处必须一致）/ §11（契约与实现不符）
- **证据**：静态确定 —— 图例在 `ComboChart.cj:197-203` 用**全局系列下标** `config.theme.colorAt(index)` 取色；而 `drawBarGroups` 的多系列分支对所有分段统一回退到 `config.theme.colorAt(group.series[0].paletteIndex)`。同一 stack 组的 `series[0]` 恒定，故 3 个分段得到同一个色值
- **描述**：`stacked-bar` / `percent-stacked-bar` 组内任意多系列未显式写 `color` 时，所有分段渲染成同一种颜色，分段边界不可辨认；同时图例色块按 `colorAt(0..n)` 展开，与图中颜色一一对不上。`line` / `scatter` 的缺省色进一步硬编码 `"#4e79a7"`（632、653），多折线时所有线同色而图例多色
- **建议**：缺省色统一改为 `config.theme.colorAt(item.paletteIndex)`（`ComboSeries.paletteIndex` 已存在，可直接用），删掉 632/653 的字面量；或把「系列 → 颜色」在 `draw()` 里预计算成 `Array<String>` 后传入 `drawBars/drawLines/drawScatters`，保证图例与图形同源

### [一般][存量] `combo` 的 `bar` / `grouped-bar` 丢弃 `stack` 字段，规格示例不堆叠

- **位置**：`f_chart/src/ComboChart.cj:238-243`（第 241 行把 `stack` 固定写成 `""`）；消费者 `f_chart/src/ComboChart.cj:459-471`
- **来源**：存量
- **判据**：review-checklist §11（与规格冲突）；承诺源 `f_chart/doc/chart-json-spec.md:2650`（「同一 `stack` 的柱先堆叠」）与 `:2663-2664`（示例用 `"type": "bar", "stack": "sales"`）
- **证据**：静态确定 —— `parseSeries` 只在 `case "stacked-bar" | "percent-stacked-bar"`（244-251）读取 `json.string("stack")`；`bar`/`grouped-bar` 分支 `ComboSeries(...)` 的第 6 个实参固定 `""`，于是 `buildBarGroups` 里 `item.stack.isEmpty()` 恒真，每个柱系列各占一个 `__single_${index}` 组
- **描述**：规格首例（两个 `type: "bar"` + 同一 `stack: "sales"`）期望堆叠，实际渲染为并排分组柱；用户按文档写 `stack` 得不到任何效果，也不会报错
- **建议**：`bar` 分支改为 `json.string("stack", default: "")` 透传（`grouped-bar` 保持固定空串以区别于堆叠）；同步在 `ComboChart_test` 增加「`bar` + `stack` 应只产生 2 个 rect 区间（堆叠）」用例；若确认设计上 `bar` 不堆叠，则须修规格示例而非代码——两者必须一致

### [一般][存量] `combo` 忽略 `legend.show`，图例无法关闭

- **位置**：`f_chart/src/ComboChart.cj:167`
- **来源**：存量
- **判据**：review-checklist §14.1（配置项被读取却从未使用 / 接线缺失）；承诺源 `f_chart/doc/chart-json-spec.md:71`（`legend.show` 默认 `true`，是通用字段）
- **证据**：静态确定 —— `let legendVisible = series.size > 1`，全文件无 `config.legend.show` 引用（`grep config.legend f_chart/src/ComboChart.cj` 仅命中 ChartFrame 调用）；同模块 `ControlChart.cj:123` 的正确写法是 `config.legend.show && !seriesName.isEmpty()`
- **描述**：多系列 combo 图无法通过 `"legend": {"show": false}` 隐藏图例，且 `position` 之外的配置被静默忽略；与同模块其他图的语义不一致
- **建议**：改为 `config.legend.show && series.size > 1`（`ChartFrame.drawLegend` 内部已有 `legendVisible && names.isEmpty()` 保护，无需再判空）

### [一般][存量] 圆堆积图对含环输入静默丢节点，三处「存在环」守卫不可达

- **位置**：`f_chart/src/CirclePackingChart.cj:108-113`（只校验根数量）、`:146-149`、`:170-173`、`:190-199`（`depth > total` 守卫）
- **来源**：存量
- **判据**：review-checklist §1（恒假分支 / 不可达语句）+ §11（静默数据错误）
- **证据**：静态确定 —— 每个节点只有一个 `parent`，`roots.size == 1` 要求全图恰有一个无父节点；任何环上的节点都有父节点，因此环只可能构成与根不相连的独立分量。`resolveTotals(rootNode, 0, nodes.size)` 只沿根可达子树下钻，深度上界为 `nodes.size - 1 < total`，故 `depth > total` 恒假；环分量既不参与布局也不参与绘制，且不抛错
- **描述**：输入如 `root(parent=null)`、`b(parent=c)`、`c(parent=b)` 时，`b`、`c` 被静默丢弃（不渲染、不计入面积、不报错），用户看到的是「少了两块」的图；三处环检测代码实际是死分支。反例可对比 `DecisionTreeChart.cj:186-189`（用可达节点计数做真检测）
- **建议**：解析阶段用「父链查环」（对每个节点沿 parent 上溯计数，超过 `nodes.size` 即判环）或在 `resolveTotals` 前用 `HashSet` 做访问标记；把 `depth > total` 替换为「可达节点数 != nodes.size」的统一校验，并补一条环输入的负向用例

### [一般][存量] 圆堆积子圆按矩形网格布点，3/5/7 个子节点会溢出父圆

- **位置**：`f_chart/src/CirclePackingChart.cj:203-216`
- **来源**：存量
- **判据**：review-checklist §10（布局算法正确性）
- **证据**：静态确定 —— `columns = ceil(sqrt(count))`、`rows = ceil(count/columns)`，子圆心落在父圆的外接正方形网格中心（212-213），半径上限 `min(cellWidth, cellHeight)/2 - padding`（214-216）。`count = 3` 时 `2×2` 网格：子圆心在 `(±r/2, ±r/2)`，距父圆心 `0.707r`，加半径 `0.5r` 得 `1.207r > r`
- **描述**：子节点数不是完全平方数（3、5、6、7、8…）时，角落子圆有约 20% 半径露出父圆之外，视觉上「圆堆积不嵌套」；现有测试 `CirclePackingChart_test.cj` 的样例每个父节点恰好 2 个子节点（`columns=2, rows=1`），因此测不到
- **建议**：按可用半径做内切约束（子圆心到父圆心的距离 + 子半径 ≤ 父半径 − padding），或改用「按面积排布 + 螺旋/同心环」布点；补一条 3 子节点的几何断言（`hypot(dx,dy) + childR <= parentR`）

### [一般][存量] 树形图递归深度等于树深且无上限，深链输入会栈溢出

- **位置**：`f_chart/src/CirclePackingChart.cj:146`（`resolveTotals`）、`:170`（`sortChildren`）、`:190`（`layoutChildren`）、`:221`（`drawNode`）；`f_chart/src/DecisionTreeChart.cj:301`（`countDecisionNodes`）、`:310`（`decisionAssignDepth`）、`:318`（`decisionAssignSlots`）
- **来源**：存量
- **判据**：review-checklist §4（无界递归）
- **证据**：静态确定（深度无上限）+ 需实测（溢出阈值）—— 递归深度 = 从根到最深叶的层数，节点数与层级完全由 JSON 输入决定，模块内无深度上限、无节点数上限、无迭代改写。`CirclePackingChart` 的 `depth > total` 守卫按上一条已证明恒假，起不到限制作用
- **描述**：输入一条 1 万层的链式 `parent`（或决策树 1 万层 `edges` 链）时，7 个递归函数逐个下钻，栈帧在 `resolveTotals`/`countDecisionNodes` 处耗尽即进程崩溃（Cangjie 不保证尾调用优化，`decisionAssignSlots` 也不是尾递归）
- **建议**：改为显式栈迭代（后序求 total、层序求 depth/slot），或在解析阶段限制层数（如 `maxDepth` 默认 64，超出抛 `InvalidValue`）；同时把 `nodes.size` 上限（如 5000）写进规格与校验

### [一般][存量] `pathCentroid` 把弧命令参数与指数当坐标，弧线地图的标签位置错误

- **位置**：`f_chart/src/ChoroplethChart.cj:176-217`（扫描 182-203，配对 211-216，异常吞掉 194-198）
- **来源**：存量
- **判据**：review-checklist §10（正确性）/ §3（`catch (_: Exception) { () }` 静默吞异常）
- **证据**：静态确定 —— 扫描器把所有「数字串」按出现顺序两两配对求和，不区分命令类型。`A rx ry rot large-arc sweep x y` 会贡献 5 个非坐标数字（`rx, ry, rot, large-arc, sweep`），`M`/`L` 之后的 `Z` 无影响但 `H/V` 只给一个坐标；指数写法 `1e-3` 被切成 `1` 与 `3`
- **描述**：`regions[].path` 使用 `A`（圆弧，地图里用于海岸线/圆角边界很常见）时，标签位置按错误坐标均值计算，可偏出区域甚至落到画布外；`Float64.parse` 失败又被 `catch { () }` 吞掉，非法数字不会报错，只是少一个点，偏差无法察觉
- **建议**：按 SVG path 命令语义解析（`M/L/T` 取 2 个、`H/V` 取 1 个、`C/S/Q` 取 6/4/4、`A` 取 7 并只取末 2 个）；或收窄契约：只接受 `M/L/H/V/Z`，出现其它命令抛 `InvalidValue`。两者都比现在的「数字流近似」可控

### [一般][存量] 等高线图 `levels` 显式数组只取长度，且不校验「递增」

- **位置**：`f_chart/src/ContourChart.cj:110`（调用）、`:247-267`（`resolveLevels`，数组分支 250-256）
- **来源**：存量
- **判据**：review-checklist §14.1（半成品）/ §11（契约与实现不符）；承诺源 `f_chart/doc/spec/add-f-chart-contour/specs/chart-rendering/spec.md:25`（「`levels` MUST 为正整数或递增数组」）、`f_chart/doc/chart-json-spec.md:1140`（「等值线层级数或显式数组」）
- **证据**：静态确定 —— 数组分支只 `return items.size`，元素值从未读取；无任何单调性检查，`[30, 10, 20]` 与 `[1, 2, 3]` 等价
- **描述**：规格承诺「显式层级数组」可用，实际退化为「层级数 = 数组长度」，用户给的阈值（如 `[10, 20, 50]`）被完全忽略，等值线位置仍按 `min/max` 均分；非递增数组也不报错，属于静默错误输出
- **建议**：`resolveLevels` 返回 `Array<Float64>`（显式阈值或按 `min/max` 均分生成），`contourLevel` 改为「落在哪个阈值区间」；数组分支补递增校验（`levels[i] <= levels[i-1]` 即 `InvalidValue`，`path: "levels[i]"`）

### [一般][存量] 三个规格字段「读取/声明但无消费者」：`interpolate`、`method`、`condition`

- **位置**：`f_chart/src/ContourChart.cj:111-114`（`interpolate`）、`f_chart/src/CorrelationMatrixChart.cj:81-84`（`method`）、`f_chart/src/DecisionTreeChart.cj:91-92`（只读 `label`/`leaf`，`condition` 从未读取）
- **来源**：存量
- **判据**：review-checklist §1（读了不用 / 死配置字段）+ §14.1（接线缺失）；承诺源 `f_chart/doc/chart-json-spec.md:1140`（`interpolate` 控制 `linear`/`nearest`）、`:1089`（`method` 取 `pearson`/`spearman`）、`:2065`（节点字段含 `condition?`）
- **证据**：静态确定 —— `grep -n interpolate f_chart/src` 除 `ContourChart.cj:111-113` 与测试外无命中；`method` 只在 81-84 参与比较后再无引用；`grep -n condition f_chart/src/DecisionTree*.cj` 无命中
- **描述**：`interpolate` 无论取 `linear` 还是 `nearest`，输出 SVG 完全一致（实现按网格点分层着色，根本没有插值分支）；`method` 对着已经算好的相关矩阵没有任何作用，只在取值非法时抛错；决策树的 `condition` 字段被丢弃，节点只显示 `label`。三者都会让使用者以为配置生效
- **建议**：要码就接线——`contour` 至少让 `nearest`/`linear` 在「跨格等值线是否插值切割」上产生可观测差异；`correlation` 既然吃现成矩阵就删掉 `method`（或改为「由原始样本计算」的入口）；`decision-tree` 在节点文本里拼接 `condition`。不实现则从规格与校验里删除，避免「校验通过但无效果」

### [一般][存量] 混淆矩阵/相关矩阵输出量随标签数平方增长，无上限也无拒绝路径

- **位置**：`f_chart/src/ConfusionMatrixChart.cj:128-154`（每个单元 1 个 `rect` + 1 个 `text`）、`f_chart/src/CorrelationMatrixChart.cj:122-152`
- **来源**：存量
- **判据**：review-checklist §5（平方级增长 / 无界容器，判据要求量化）
- **证据**：需实测 —— 输入规模 n（`labels.size`）不受限，输出元素数 = n²（混淆矩阵还额外 n² 个 `confusion-value` 文本）。按每单元约 150–200 字节序列化估算，n = 300 时约 9 万单元（≈15–18 MB），n = 1000 时约 10⁶ 单元（≈150–200 MB），且 `SvgBuilder` 全程在内存里拼字符串，未流式
- **描述**：一个「标签 1000×1000」的矩阵请求即可让单次 `draw` 产出上百 MB 字符串并常驻到返回，触发 OOM 或把上游（HTTP 响应）拖死；没有 `maxLabels` 之类的上限，也没有分块/降采样路径
- **建议**：加显式上限（如 `labels.size <= 200`，超出抛 `InvalidValue`，path `labels`），并在 `showValues` 打开时按 `cellSize` 阈值自动关闭数值文本；长期方案是把矩阵输出改为流式拼接（`SvgBuilder` 之外的 writer）

### [一般][存量] 相关矩阵 `colorRange` 不校验颜色，规格要求的 `InvalidValue` 缺失

- **位置**：`f_chart/src/CorrelationMatrixChart.cj:167-190`
- **来源**：存量
- **判据**：review-checklist §11（契约与实现不符）；承诺源 `f_chart/doc/chart-json-spec.md:2713`（「颜色字符串无法解析 → `InvalidValue`」）
- **证据**：静态确定 —— `resolveColorRange` 只校验「是字符串」「恰好 3 个」，不调用 `SvgColor.tryParse`；同模块 `ChoroplethChart.cj:110-119` 对 `colorRange` 逐个 `tryParse` 并抛错，两处口径不一致
- **描述**：`"colorRange": ["#fff", "oops", "#000"]` 会原样写进 `fill`，SVG 渲染器按无效值处理（多数实现回退为黑色/不绘制），负相关格变成黑块且没有任何错误提示
- **建议**：复用 `ChoroplethChart` 的校验循环（`SvgColor.tryParse` + `chartInvalidValue("colorRange[i]", ...)`），或把它抽成 `ChartTheme`/`ChartJson` 里的公共 `parseColorArray(path, count)`，供两处共用（见重复逻辑条目）

### [轻微][存量] 冗余包装与重复实参

- **位置**：`f_chart/src/ComboChart.cj:210`（调用）、`:217-219`（`labelCount` 仅 `labels.size`）；`f_chart/src/ControlChart.cj:168-179`（三个调用点都传 `frame.plot.right()` 同时作 `right` 与 `labelX`）、`:209-219`（`drawLimitLine` 签名）
- **来源**：存量
- **判据**：review-checklist §10（可读性）/ §1（冗余间接）
- **证据**：静态确定
- **描述**：`labelCount(labels)` 只是 `labels.size` 的一层包装，且与 `drawBarGroups` 的形参同名，读代码时容易误判为另一套语义；`drawLimitLine` 的 `right` 与 `labelX` 永远相等（3 个调用点均传 `frame.plot.right()`），双参数是历史残留
- **建议**：直接传 `labels.size` 并删除 `labelCount`；`drawLimitLine` 去掉 `labelX`，用 `right + 6.0` 定位标签

### [轻微][存量] `ChartTime` 日期校验只覆盖形状与 1..31，非法日期被静默归一化

- **位置**：`f_chart/src/ChartTime.cj:27-39`（范围校验 35-37）、`:52-58`（数字解析）、`:60-71`（`daysFromCivil`）、`:89-96`（`pad`）
- **来源**：存量
- **判据**：review-checklist §11（边界校验缺失、语义与注释不符）
- **证据**：静态确定（月份天数 / 尾随字符）+ 待确认（负年份整除语义、越界切片的运行时行为）
- **描述**：① `2026-02-31` 通过校验，`daysFromCivil` 直接溢出到 3 月，`formatDays` 回显 `2026-03-03`；② 只检查前 10 字节，`"2026-01-01xyz"` 被接受；③ 年份为负（`"-123-05-06"` 能过 `bytes[4]=='-'`）时 `y / 400` 是截断除法而算法要求向下取整，天数会偏一天以上；④ `pad` 对负年份把 `"-1"` 补成 `"00-1"`；⑤ 切片 `text[0..4]` 等按字节下标，若多字节字符恰好跨在 3/5/8/10 边界（如 `"20é-01-01"` 通过两处 `'-'` 检查），切片落在非字符边界的行为需按 `String` 文档确认（本地 `~/.autocode/cj/doc` 不可用，未能查证）
- **建议**：解析前先 `if (text.size < 10) ...`，再用正则/逐字符校验 `0..10` 全为 ASCII 且形如 `\d{4}-\d{2}-\d{2}`；补「按当月天数校验」（用 `civilFromDays(daysFromCivil(...))` 回读比对）与尾部字符校验；负年份用 `floorDiv` 语义

### [轻微][存量] 重复逻辑：id 去重循环与线性查找助手在 5 个文件各写一遍

- **位置**：`f_chart/src/ChordChart.cj:82-86`（id 去重）、`:204-211`（`findNode`）；`f_chart/src/ChoroplethChart.cj:82-86`；`f_chart/src/CirclePackingChart.cj:74-78`、`:137-144`；`f_chart/src/DecisionTreeChart.cj:86-90`、`:281-288`；`f_chart/src/ComboChart.cj:311-319`（类目名线性查找）
- **来源**：存量
- **判据**：review-checklist §2（只改类型名的跨文件复制）
- **证据**：静态确定 —— 五处 `for (existing in X) { if (existing.id == id) throw ... }` 结构逐行对齐，仅文案从「节点 id 重复 / 区域 id 重复 / 节点 id 重复」变化；四套线性查找返回 `Int64` 或 `?T` 两种形态
- **描述**：`O(n)` 校验让建图阶段变成 `O(n²)`（下一条的性能线索），且错误文案与 path 规则已经出现漂移（`Chord` 用 `${itemPath}.id`、`CirclePacking` 用 `nodes`、`DecisionTree` 用 `edges`）
- **建议**：在模块内加一个 `ChartGraph` 小工具（`internal`）：`addNode(id, path)` 内部维护 `HashMap<String, Int64>`，同时提供 `index(id): ?Int64`，五个图改用它；错误文案以参数传入，避免行为漂移

### [轻微][存量] 重复逻辑：插入排序、y 轴标签宽度、两位小数格式各有多份

- **位置**：插入排序 `f_chart/src/CirclePackingChart.cj:174-184` 与 `f_chart/src/ContourChart.cj:226-234`；`maxYLabelWidth` 统计 `f_chart/src/ComboChart.cj:143-152`、`f_chart/src/ContourChart.cj:133-142`、`f_chart/src/ControlChart.cj:124-133`；两位小数格式化 `f_chart/src/CorrelationMatrixChart.cj:222-234`（`formatCorrelation`）与 `f_chart/src/ConfusionMatrixChart.cj:229-238`（`confusionText`）
- **来源**：存量
- **判据**：review-checklist §2（换算复制 / 字面量复制）
- **证据**：静态确定 —— 两处插入排序的控制流与临时变量名一致（`while (j > 0 && a[j] >/< a[j-1])`）；三处宽度统计是同一段 `chartTextWidth(chartFormatTick(...)) + maxFloat` 循环；两处小数格式化都是 `round(v*100)` → 拆整数/百分位 → 补零
- **描述**：差异点是业务性的（一边取「深色/浅色阈值」、一边把符号单独处理），因此不建议合并成一个函数；但排序与「标签宽度」这两组没有差异，属于纯复制，后者还各自漏掉了 `labelRotate` 分支（`ComboChart:168-172`、`ControlChart:134-138` 又各写一遍）
- **建议**：排序用 `std.sort`（或在 `ChartScale.cj` 放一个 `sortDescending/​sortAscending` 助手）；「y 轴标签宽度 + x 轴标签高度」抽成 `ChartFrame.measureAxisLabels(config, ticks, axis)`（`ComboChart`/`ContourChart`/`ControlChart` 已有 `ChartFrame` 依赖，落点合规）；`formatCorrelation` 与 `confusionText` 保留两份，但在注释里写清「一个处理符号、一个假定非负」

### [轻微][存量] 相关矩阵在窄画布上算出负的 `size`/`cell`，输出无效尺寸

- **位置**：`f_chart/src/CorrelationMatrixChart.cj:110-120`
- **来源**：存量
- **判据**：review-checklist §11（边界差一 / 负值未处理）
- **证据**：静态确定 —— `availableWidth = width - padding.left - padding.right - labelWidth - 16`；`width = 100`（`ChartConfig` 只要求 `> 0`，见 `ChartConfig.cj:182-184`）时 `availableWidth = -28`，`size = min(-28, ...) = -28`，`cell = -28 / order` 为负，`kit.rect` 原样写入 `width="-14px"`（`SvgAuthoringBuilder.cj:115-131` + `SvgNumber.cj:32-48`，写出阶段不校验非负）
- **描述**：负尺寸 rect 在 SVG 规范里是错误值，浏览器不渲染 ⇒ 整图为空白；同模块 `ConfusionMatrixChart.cj:110-112` 用 `maxFloat(..., 1.0)` 做了钳制，口径不一致
- **建议**：`let size = maxFloat(minFloat(availableWidth, availableHeight), 1.0)`，并给 `labelWidth` 加下限校验；或在 `ChartConfig.parse` 里按图类型校验最小画布尺寸

### [轻微][存量] 轴余量与规格默认不一致（8% / 0% vs 5%）

- **位置**：`f_chart/src/ControlChart.cj:102-113`（`span * 0.08`）、`f_chart/src/ContourChart.cj:269-287`（`resolveRange` 完全不加余量）
- **来源**：存量
- **判据**：review-checklist §13/§11（与规格默认冲突）；承诺源 `f_chart/doc/chart-json-spec.md:2720`（「数值轴未给 `min`/`max` 时按数据范围留 5% 余量」）
- **证据**：静态确定 —— `ComboChart` 走 `lineRange`（`LineChart.cj:457-477`，5%），`ControlChart` 自写 8%，`ContourChart` 自写 0%
- **描述**：同为「数值轴自动范围」，三张图留白不同；`contour` 的极值格恰好贴边（等值线被坐标框裁掉一半），`control` 的留白偏大。属默认值漂移，不影响正确性
- **建议**：`ContourChart.resolveRange` 与 `ControlChart` 改用 `lineRange(...)`（已导出、已带 5% 与「一端显式」语义），删除各自的私有实现

## 优化可行性方案

> 不是缺陷，是「还能更好」。本部分**没有任何 profile / bench 数据**，因此以下全部为 `无基线（待验证，不进 tasks）`。

### [堆内存] 等高线网格的三份中间表示合一

- **现状**：`ContourChart.draw` 同时持有 `points`（`ArrayList<ContourPoint>`，每点一个 class 对象：3 个 Float64 + 对象头）、`xs`/`ys`（去重排序后的坐标）、`values`（`Float64[xs*ys]`，初值 NaN）、`bands`（`Int64[xs*ys]`），另有 `dataArray.getItems()` 由 JSON 侧持有的原始项列表。一个 100×100 网格（10⁴ 点）约 4 份 O(n) 结构并存
- **方案**：解析时直接把 `(x, y, value)` 写入以 `xs`/`ys` 排序后下标为键的 `Float64` 数组（先收集 `x`/`y` 到 `ArrayList` → 排序去重 → 第二遍填值），删掉 `ContourPoint` 与 `bands`（`contourLevel` 就地计算或在画线时算两次）
- **预期**：峰值对象数从 ≈4n 降到 ≈2n（`points` 与 `bands` 消失），10⁴ 点时省约 2×10⁴ 个对象/约 0.5–1 MB（量级估算，未测）
- **代价**：需要两遍遍历（当前也是一遍建点 + 一遍填值），代码结构调整；错误信息里的 `series[0].data[i]` 下标要保留（改成先校验后填充）
- **验证**：`getAllocatedHeapSize()` 差值 + 峰值 RSS，输入 20×20 / 100×100 / 200×200 三档，`-O2`
- **证据状态**：`无基线（待验证）`

### [堆内存] 圆堆积节点改为紧凑表示

- **现状**：每个 `CirclePackingNode` 是 class（`id`/`name`/`parentId`/`ownValue`/`children` ArrayList + 4 个可变数值字段），children 又是 `ArrayList` ⇒ 每节点 2 个堆对象 + 一个数组
- **方案**：解析后立刻转成「下标 + 平行数组」（`ids: Array<String>`、`parentIdx: Array<Int64>`、`childrenStart/childrenCount: Array<Int64>` 的 CSR 结构），布局字段放 `Array<Float64>`；`id` 只用于查父与重复校验，布局完成后即可释放
- **预期**：节点数 n 时堆对象从 ≈2n 降到 2 个数组（约 6n×8 字节 + 字符串本身），n = 5000 时省约 10⁴ 个对象
- **代价**：CSR 构建需要一次计数 + 一次填充，可读性下降；递归改迭代后可读性反而更好
- **验证**：n = 1000/5000 两档的峰值内存与 `draw` 耗时对照
- **证据状态**：`无基线（待验证）`

### [CPU] 等高线网格构建是 O(n²)：线性查重 + 插入排序 + 线性定位

- **现状**：`uniqueSorted`（`ContourChart.cj:211-236`）对每个点线性扫 `unique` 查重、再做插入排序；`indexOf`（238-245）对每个点再线性扫 `xs`/`ys`。n 个点 ⇒ 约 3n² 次比较；100×100 网格（10⁴ 点）≈ 3×10⁸ 次比较
- **方案**：`ArrayList` → 排序 + 去重（O(n log n)），再用 `HashMap<Float64, Int64>` 建立坐标→下标，第二遍 O(n) 填值
- **预期**：n = 10⁴ 时比较次数从 10⁸ 量级降到 10⁵ 量级；按比较成本估算可把网格构建阶段降到原来的 1–2%（需实测）
- **代价**：`HashMap` 以 Float64 为键要处理 `-0.0`/精度（当前 `==` 语义相同）；额外 O(n) 哈希表内存
- **验证**：`cjpm bench -O2` 同输入（20×20/50×50/100×100）对照 `draw` 中位数与 P95；`cjprof` 看 `uniqueSorted`/`indexOf` 自耗时占比
- **证据状态**：`无基线（待验证）`

### [CPU] 决策树根检测与边标签查找是 O(n·e) / O(e²)

- **现状**：`DecisionTreeChart.cj:168-181` 用「对每个节点遍历所有节点的所有子节点」判根（O(n·e)）；`decisionEdgeLabel`（291-298）在画每条边时全表扫 `edges`（O(e²)）
- **方案**：根检测改用 `parentCounts` 已有的数组（`edges` 分支里已算出），或在解析时维护 `HashSet<String> hasParent`；边标签用 `HashMap<(source,target), String>`（可拼 `source + "\u0000" + target` 作键）预建
- **预期**：n = e = 2000 时，根检测从 4×10⁶ 次降到 2×10³，边标签从 4×10⁶ 降到 2×10³
- **代价**：多一个哈希表（O(e) 内存）；键拼接产生临时字符串
- **验证**：`cjpm bench -O2`，n = 200/1000/3000 的 `draw` 中位数
- **证据状态**：`无基线（待验证）`

### [CPU] 和弦图每条链接重复线性查节点下标

- **现状**：`ChordChart.cj:107-108` 每条链接查 2 次、`:170-171` 画链接时再查 2 次、`:183` 再查 1 次 ⇒ 每条链接 5 次 O(nodes) 线性扫描；nodes = links = 500 时约 1.25×10⁶ 次字符串比较
- **方案**：解析节点时建 `HashMap<String, Int64>`（与「重复 id 校验」共用，见重复逻辑条目），`ChordLink` 直接存 `sourceIndex/targetIndex`
- **预期**：字符串比较次数降到 O(nodes + links)；大图（500 节点/链接）可省掉绝大部分建图比较
- **代价**：`ChordLink` 结构变化（`String` → `Int64`），`findNode` 可删
- **验证**：`cjpm bench -O2`，nodes = links = 100/500/2000 的 `draw` 中位数
- **证据状态**：`无基线（待验证）`

### [CPU] 组合图每次 draw 重建 4 次堆叠分组

- **现状**：`buildBarGroups` 在 `resolveAxisRange`（`ComboChart.cj:117`、`:129`，左右轴各一次）与 `drawBars`（`:498-499`，左右各一次）里被调用 4 次，每次都重新遍历 series 并在 `groups` 上线性找同 `stack` 的组（O(s²)）
- **方案**：在 `draw` 里算一次 `leftGroups`/`rightGroups`，作为参数传给 `resolveAxisRange` 与 `drawBarGroups`
- **预期**：分组构建从 4 次降为 1 次；series 数 s 的时间从 4·O(s²) 降到 O(s²)，s = 50 时省约 7.5×10³ 次比较（绝对量很小，属「顺带清理」）
- **代价**：函数签名变长；`drawBars` 的结构需要调整
- **验证**：`cjpm bench -O2`，series = 10/50 的中位数对照（噪声内可忽略）
- **证据状态**：`无基线（待验证）`

## 待验证假设

> 没有性能测试数据支撑，**不进 `todo.md` / `tasks.md`**。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 等高线网格构建（`uniqueSorted` + `indexOf`）是 `contour` 的主要 CPU 开销 | `f_chart/src/ContourChart.cj:211-245` | 自耗时占比 | `cjprof record` 跑 `ContourChart_test` 的 100×100 网格样本，看 `uniqueSorted`/`indexOf` self time |
| 2 | 和弦图 `findNode` 是 links 规模上的热点 | `f_chart/src/ChordChart.cj:204-211` | 自耗时占比与 links 规模拐点 | `cjpm bench -O2`，links = 100/500/2000，对比「线性查」与「HashMap」两版 |
| 3 | 决策树根检测的 `n×e` 扫描在 n ≥ 1000 时开始主导 | `f_chart/src/DecisionTreeChart.cj:168-181` | 自耗时占比 | `cjprof` 跑 1000 节点链/星形两种拓扑，看该循环 self time |
| 4 | 圆堆积/决策树在 3000+ 层输入下栈溢出 | `CirclePackingChart.cj:146,170,190,221`、`DecisionTreeChart.cj:301,310,318` | 实际可承受深度（依赖线程栈大小） | 生成 depth = 500/1000/2000/5000 的链式输入跑 `draw`，记录崩溃点；同时给出默认线程栈大小 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_chart/src/ChartTime.cj` | .cj | ✅ | 日期换算；校验缺口见 #13 |
| 2 | `f_chart/src/Chart_test.cj` | .cj | ✅ | 接口分派 + 入参不变性，`ProbeChart` 仅测试用 |
| 3 | `f_chart/src/ChordChart.cj` | .cj | ✅ | 见 #14、优化方案「重复查下标」 |
| 4 | `f_chart/src/ChordChart_test.cj` | .cj | ✅ | 覆盖弧/带/标签/错误分支，未覆盖自环链接 |
| 5 | `f_chart/src/ChoroplethChart.cj` | .cj | ✅ | 见 #7；`colorRange` 校验是模块内正面样板 |
| 6 | `f_chart/src/ChoroplethChart_test.cj` | .cj | ✅ | 质心用例只覆盖 `M/L/Z`，无 `A` 命令 |
| 7 | `f_chart/src/CirclePackingChart.cj` | .cj | ✅ | 见 #4/#5/#6 |
| 8 | `f_chart/src/CirclePackingChart_test.cj` | .cj | ✅ | 样例每父 2 子，测不到网格越界；无环输入用例 |
| 9 | `f_chart/src/ComboChart.cj` | .cj | ✅ | 见 #1/#2/#3、#12 |
| 10 | `f_chart/src/ComboChart_test.cj` | .cj | ✅ | 无「`bar`+`stack`」与「堆叠多色」用例 |
| 11 | `f_chart/src/ConfusionMatrixChart.cj` | .cj | ✅ | 见 #10、#15（两位小数格式化） |
| 12 | `f_chart/src/ConfusionMatrixChart_test.cj` | .cj | ✅ | 归一化/方阵/类型分支齐全 |
| 13 | `f_chart/src/ContourChart.cj` | .cj | ✅ | 见 #8/#9、#15、#17、优化方案 1/3 |
| 14 | `f_chart/src/ContourChart_test.cj` | .cj | ✅ | `interpolate` 只测非法值，未测效果差异 |
| 15 | `f_chart/src/ControlChart.cj` | .cj | ✅ | 见 #12、#15、#17；`legend.show` 用法正确 |
| 16 | `f_chart/src/ControlChart_test.cj` | .cj | ✅ | 均值/σ/控制限/异常点覆盖完整 |
| 17 | `f_chart/src/CorrelationMatrixChart.cj` | .cj | ✅ | 见 #10/#11/#16、#15 |
| 18 | `f_chart/src/CorrelationMatrixChart_test.cj` | .cj | ✅ | 无 `colorRange` 非法颜色用例 |
| 19 | `f_chart/src/DecisionTreeChart.cj` | .cj | ✅ | 见 #6/#9、优化方案 4 |
| 20 | `f_chart/src/DecisionTreeChart_test.cj` | .cj | ✅ | 有环/不可达节点无负向用例 |

合计：`.cj` 20 个 / `.md` 0 个 / 共 20 个，全部读完（本部分清单不含 `.md`，`doc/**` 仅作为规格证据引用，未计入本部分覆盖）。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 17 | 与下列专项为同一批条目（正确性 11、可读性 4、契约/安全 2），不重复计入模块统计；安全性方面唯一外部输入是 JSON 与 `path` 字符串，颜色/文本都经 `SvgWriter` 转义，未发现注入面 |
| §1 死代码 | 1 | 机械过：20 个文件的 `import` 全部逐个核对有使用（`CorrelationMatrixChart_test` 未引 `std.math`，其余 `abs`/`min` 均有调用）；全部 `private`/`internal` 符号（`labelCount`、`bodyScale`、`findNode`、`resolveTotals`、`sortChildren`、`layoutChildren`、`drawNode`、`uniqueSorted`、`indexOf`、`resolveLevels`、`resolveRange`、`resolveColorRange`、`resolveLabels`、`drawLimitLine`、`findDecisionNode`、`decisionEdgeLabel`、`countDecisionNodes`、`decisionAssignDepth`、`decisionAssignSlots`、`decisionTreeLayout`、`parseIntOrThrow`、`daysFromCivil`、`civilFromDays`、`pad`、`chordArcPath`、`chordWidth`、`pathCentroid`、`circlePackingRadius`、`contourLevel`、`confusionNormalize`、`confusionText`、`controlMean`、`controlStdDev`、`resolveControlLimits`、`correlationColor`、`formatCorrelation`、`heatFlameColor`、`flameColorIndex`、`orgFitLabel`、`percentStackedValue`）全仓搜索均有调用者；`ChartTime.partsOfDays` 由 `CalendarHeatmapChart.cj:204` 使用，非死代码；无 `return`/`throw` 之后的同层语句。唯一命中是 #4 的三处恒假 `depth > total` |
| §2 重复逻辑 | 2 | 同文件内两两比对 10 个实现的函数体（输入-输出-副作用摘要）：`drawBarGroups` 单/多系列两分支差异是业务性的（百分比归一化）不判重复；`flushLine` 与 `LineChart` 同名函数同源但不属本部分；跨文件按「相同错误文案 / 字面量 / 正则」搜出 #14、#15 两组。测试文件的 `draw`/`count` 助手在 10 个文件重复，属「测试准备代码」误报边界，未计入 |
| §3 空实现 | 1 | 无空函数体、无 `TODO`/`FIXME`（`grep -rn "TODO\|FIXME\|Unsupported" f_chart/src` 仅命中 `UnsupportedChart` kind）；`public init() {}` 是无状态构造，合理。唯一命中是 `pathCentroid` 的 `catch (_: Exception) { () }`（并入 #7） |
| §4 栈溢出 | 1 | 逐函数检查递归：`resolveTotals`/`sortChildren`/`layoutChildren`/`drawNode`/`countDecisionNodes`/`decisionAssignDepth`/`decisionAssignSlots` 深度由输入决定（#6）；`collectXmlText` 类跨模块递归不在本部分；其余图表全为循环，无递归 |
| §5 OOM | 1 | 逐文件核对「全量物化/按不可信长度预分配/无界容器」：`Chord`/`CirclePacking`/`DecisionTree`/`Contour` 的容器规模与输入点数线性（无平方级），不判；`ConfusionMatrix`/`CorrelationMatrix` 输出 n²（#10）成立 |
| §6.1 热点瓶颈 | 0 | 本轮无 `cjprof`/`cjpm bench`/分段计时数据，热点结论一律降级为 4 条「待验证假设」 |
| §6.2 大粒度锁 | 0 | 本部分无 `synchronized`/`Mutex`/锁对象（`grep -rn "synchronized\|Mutex\|Atomic"` 无命中） |
| §6.3 并发串行 | 0 | 无 `spawn`/`Future`/通道；`draw` 是纯同步计算 |
| §6.4 低效算法 | 3 | 静态可判的复杂度问题 3 组（`Contour` 网格 O(n²)、`DecisionTree` 根检测 O(n·e)、`Chord` 每链接线性查），全部写入「优化可行性方案（无基线）」而非缺陷 |
| §7 降堆内存方案 | 2 | 见「堆内存」两条；`clear()` 不归还物理内存、`ArrayList.toArray()` 拷贝等假象已按 `mem §3.2` 逐条排除 |
| §8 降 CPU 方案 | 5 | 见「CPU」五条，全部 `无基线（待验证）`；未给任何百分比结论 |
| §9 local mode 可行性 | 0 | 不成立：布局结果（节点坐标/SVG 字符串）要逃逸出函数，`SvgBuilder` 与 `ChartConfig` 为跨模块对象；且无改前/改后峰值内存数据，只能停留在此结论 |
| §11 现有代码的 BUG（存量） | 17 | 本轮读到的 10 个实现 + 10 个测试全部按边界/空值/错误处理/契约逐条核对；17 条发现全为存量（快照模式无 diff），其中 11 条为一般、6 条为轻微 |
| §12 并发安全与锁粒度 | 0 | 9 个 `*Chart` 均为无字段的 `public class`（仅 `public init() {}`），`draw` 的全部状态是局部变量；`ChartTime` 全是 `static` 纯函数。不存在跨线程共享路径，无需同步手段 |
| §14 功能完备性与 README 覆盖 | 4 | 承诺源全部落在 `doc/chart-json-spec.md` 与 `doc/spec/**`（本部分无 `.md` 清单项）：`bar`+`stack`（#2）、`legend.show`（#3）、`levels` 数组（#8）、`interpolate`/`method`/`condition`（#9）。README 覆盖核对交由包含 `f_chart/doc/**` 的部分 |
| 文件覆盖（§13 等） | 20/20 | 无 `f_chart/src` 外的文件被漏读；`.md` 本部分为 0 个 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 11 |
| 轻微 | 6 |
| 优化方案（堆内存 / CPU） | 2 / 5 |

存量缺陷 17 条（全部为存量），是否纳入修复待用户决定。

## 总评

本部分 9 张图 + 日期工具的共性结构是「读 JSON → 校验 → 算布局 → 拼 SVG」，没有任何成员字段、锁、异步与 I/O：并发安全与资源生命周期这两个维度天然干净（§12 命中 0，句柄/连接类问题不存在）。主要风险集中在三处：

1. **组合图与规格/图例的偏离**（#1/#2/#3）。颜色回退用 `group.series[0].paletteIndex`、`bar` 分支丢弃 `stack`、`legend.show` 未接线，三者都是「配置/文档承诺了但输出不是那个样子」，且测试恰好都没有覆盖（`ComboChart_test` 只用 `stacked-bar` 与单色柱）。这是本部分最值得先修的一批——改动小、影响直接可见。
2. **树形图的输入健壮性**（#4/#5/#6）。圆堆积的环检测是死代码、环节点被静默丢弃，子圆网格越界，7 个递归函数深度等于树深且无上限。决策树侧的环处理是正确的（用可达计数），可把同一套校验抽出来复用；递归要么改迭代，要么加显式层数上限。
3. **矩阵类图的规模与校验**（#10/#11/#16）。输出随标签数平方增长且无上限，`colorRange` 又不校验颜色，和 `ChoroplethChart` 的成熟写法形成反差；同时 `CorrelationMatrixChart` 在窄画布上会算出负尺寸。

没有阻塞项：没有主路径崩溃、没有数据竞争、没有无界常驻增长。`ContourChart` 的 `levels`/`interpolate`（#8/#9）与 `pathCentroid` 的弧命令（#7）属于「功能说不完整」，建议与规格同步收敛——要么实现，要么从校验里删掉，避免「配置通过但输出不变」的误导。性能方面本轮无任何测量数据，5 条优化方案与 4 条待验证假设都只是复杂度线索，需下一轮用 `cjpm bench -O2` / `cjprof` 补基线后再决定是否进任务清单。
