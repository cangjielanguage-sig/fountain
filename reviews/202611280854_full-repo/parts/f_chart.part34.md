# f_chart 模块审查报告

> **模块第 34/37 部分**（分报告）。本部分只覆盖 `SequenceChart` / `ShapChart` / `SlopeChart` / `SpiralChart` / `StackedAreaChart` / `StackedBarChart` / `StemLeafChart` / `StreamgraphChart` / `SunburstChart` / `SurvivalChart` 及其测试，共 20 个文件；同模块其余文件见其他分报告，最终模块报告由主 Agent 合并。

- **审查日期**：2026-11-28
- **模块路径**：`f_chart`（本部分 20 个源文件，均为 `.cj`）
- **基线**：工作区快照（`git status --porcelain f_chart` 为空）；相关文件最后提交为 `e52c6e3db`（2026-11-08）等，全部按「存量」计
- **审查重点**：渲染 / 布局算法正确性、坐标与数值边界、OOM、资源与内存、死代码、重复逻辑
- **报告版本**：v1

## 发现

### [一般][存量] 时序图自调用消息（`from == to`）没有箭头，只剩零长度线段

- **位置**：`f_chart/src/SequenceChart.cj:125-140`（箭头两个分支），`:121-123`
- **来源**：存量（`a1dc954e9`，2026-11-08 `feat(f_chart): M10 时序图`，工作区无改动）
- **判据**：review-checklist §11「边界 / 空集合未处理」、§13「文档承诺与实现不符」
- **证据**：静态确定 —— `toX > fromX` 与 `toX < fromX` 两个分支都不覆盖 `toX == fromX`；`kit.line` 在两点相同时输出 `M x y L x y`，SVG 里不可见。README:2398 明确写「消息为带箭头的水平线」，而 `SequenceChart_test.cj:196` 自己就用 `{"from": "u", "to": "u"}` 且只断言可解析，说明该输入被允许但没有任何可见图形
- **描述**：UML 时序图的自调用是常规写法。当前输入不报错、不警告，参与者生命线上的这段消息只剩一行压在 lifeline 上的标签，读者会误判消息不存在。`messages[].from/to` 也没有任何校验禁止自调用
- **建议**：`toX == fromX` 时画自环（例如向右折返的 `H` 形折线 + 箭头），或至少画一个小回环箭头；同时在 spec 的 `sequence` 小节说明自调用的绘制方式

### [一般][存量] 时序图 `messages[].type` 只认 `return`：spec 承诺的 `async` 无差别渲染，非法值静默接受

- **位置**：`f_chart/src/SequenceChart.cj:124`（`dashed` 判定）、`:208`（`json.string("type", default: "sync")`）；承诺源 `f_chart/doc/chart-json-spec.md:2194`
- **来源**：存量
- **判据**：review-checklist §14.1「只做了一半的分支：枚举新 case 没有分支」、§11「语义与注释不符」
- **证据**：静态确定 —— spec:2194 写「`type` 取 `sync` / `async` / `return`」，但全文件搜 `async` 零命中（只有 `:208` 的默认值 `"sync"` 与 `:124` 的 `== "return"`）；`sync` 与 `async` 生成的 SVG 完全一致，`"bogus"` 之类取值也不报 `InvalidValue`
- **描述**：文档把 `async` 列为可取值，调用方按文档区分同步/异步调用后拿到的图完全一样，属于承诺功能未落地；非法取值被当作 `sync` 处理，错误被推迟到看图时才发现
- **建议**：要么实现 `async` 的差异化（开放式箭头 / 平行双线），要么把 spec 收窄为 `sync` / `return`；同时对 `type` 做白名单校验，非法值抛 `chartInvalidValue("messages[i].type", ...)`

### [一般][存量] 旭日图：环状引用的节点被静默丢弃，而两处「节点关系存在环」守卫实际不可达

- **位置**：`f_chart/src/SunburstChart.cj:99-113`（建树 + `roots.size != 1`）、`:151-153`、`:179-181`（两处 `depth > total` 守卫）
- **来源**：存量（`ed978a37b`，2026-11-08）
- **判据**：review-checklist §1「恒真恒假分支 / 不可达语句」、§11「数据丢失 / 错误处理缺失」、§4「环检测」
- **证据**：静态确定 —— 每个节点最多一个 `parent`，所以从唯一根出发的 `children` 图必然无环，`depth` 最大为 `nodes.size - 1`，`depth > nodes.size` 恒不成立（`total` 参数名是"节点数"，语义是节点计数而非深度上限）。真正的环（如 `a.parent=c`、`c.parent=a` 再加一个独立根）不产生第二个根，`roots.size == 1` 通过，环内节点既不在 `roots` 也不在任何根的子树里，`resolveTotals`/`drawNode` 都碰不到它们
- **描述**：输入含环时既不报错也不提示，图上少掉整块层级数据（数据丢失）；注释声称的「节点关系存在环」保护永远不触发，读者会误以为已经防住。孤立分量同理（只可能由环产生，因为其它孤立节点会成为第二个根而被 `:111` 拦下）
- **建议**：建树后统计「从根可达的节点数」与 `nodes.size` 比较，不等即抛 `chartInvalidValue("nodes", "节点关系存在环或存在不可达节点")`；随后删掉 `:151` / `:179` 两处不可达守卫（或改成固定的深度上限常量，用于防栈溢出，见下条）

### [一般][存量] 旭日图只有根节点时输出空图（无扇环、无提示）

- **位置**：`f_chart/src/SunburstChart.cj:221`（`if (node.depth > 0)`）、`:124-125`
- **来源**：存量（`ed978a37b`）
- **判据**：review-checklist §11「边界 / 空集合未处理」、§14.1「半成品」
- **证据**：静态确定 —— 单节点（`parent: null` + `value > 0`）能通过全部校验（`:155-165` 走叶子分支，`totalDepth` 返回 0，`:124` 兜底为 1），但 `drawNode` 对 `depth == 0` 直接跳过绘制，于是 SVG 里只有背景和标题。`SunburstChart_test.cj:80-93` 正好用这种单节点输入测 `innerRadius` 校验，却没有任何用例断言它画出了东西
- **描述**：合法输入得到"看起来渲染失败"的空图，用户无从判断是数据问题还是实现问题；对单层数据（只有一个汇总值）这是唯一可能的形状，属于功能缺口
- **建议**：`depth == 0` 且无子节点时画一个整圆环（`0 → 2π`）并标注名称；或在校验阶段直接拒绝并给出明确消息，二者取一，不要静默输出空图

### [一般][存量] 茎叶图行布局无裁剪 / 无换列：行数一多就画出画布之外；README 承诺的「长行自动换列」未实现

- **位置**：`f_chart/src/StemLeafChart.cj:104`（`rowHeight`）、`:112-140`（逐行 `y += rowHeight`）、`:126-138`（叶拼成一条 `StringBuilder`）；承诺源 `f_chart/README.md:942`
- **来源**：存量（`e52c6e3db`）
- **判据**：review-checklist §13「文档承诺与实现不符」、§14.1「承诺了但没实现」、§11「布局越界」
- **证据**：静态确定 —— `y` 只增不减，没有与 `config.height` 比较（`config.height` 只用于 `viewBox` 与背景，`:83-90`），没有分列、没有 clipPath；叶只在一个 `StringBuilder` 里用空格连接后单次 `kit.text`，全文件搜 `column` / `clip` 零命中。README:942 写「长行自动换列」
- **描述**：`stemUnit` 小或数据跨度大时（例如 0–10000、`stemUnit=10` 产生上千行），后面的行落在 viewBox 之外被渲染器裁掉，用户只能看到前十几行且不知道还有数据；单个茎上的叶很多时也会横向冲出画布。README 描述的换列能力完全不存在，两条问题叠加使这张图在真实数据下基本不可用
- **建议**：按 `config.height` 计算可容纳行数，超出按列分栏（README 承诺的换列）或按比例压缩行高并给出省略提示；叶按可用宽度分块输出；实现后在 README 与 spec 写明「行数/叶数超限时的行为」

### [一般][存量] 极端但合法的数值在后续运算中溢出，抛出的不是 `ChartException`

- **位置**：`f_chart/src/SpiralChart.cj:41-45`（只校验 `turns > 0`）、`:174`（`turns * 360.0 * index`）、`:121-122`；`f_chart/src/SunburstChart.cj:167-174`（`sum += child.total`）、`:206-208`；`f_chart/src/StemLeafChart.cj:180-181`（`Int64(floor(...))` / `Int64(round(...))`）
- **来源**：存量
- **判据**：review-checklist §11「契约与实现不符」「边界越界」；契约源 `f_chart/README.md:255`「任何结构或数值问题都以 `ChartException` 抛出」
- **证据**：静态确定（异常类型可推导）—— `ChartJson.cj:223-225` 只拦 `NaN`/`Inf`，`1e308` 这类有限值放行；`turns = 1e308` 时 `turns * 360.0` 溢出为 `Inf`，再乘 `Float64(0)` 得 `NaN`，`cos(NaN)` 使坐标变 `NaN`，`f_svg/src/SvgNumber.cj:33-35` 的 `formatSvgNumber` 对非有限值抛 `SvgException`；旭日图两个 `1e308` 叶子求和为 `Inf`，`assignAngles` 里 `Inf / Inf` 得 `NaN`，同样落到 `SvgException`；茎叶图 `Int64(1e307)` 触发溢出异常（语言文档 `docs/dev-guide/source_zh_cn/basic_data_type/integer.md`「数值类型之间的转换」注意段：「根据默认的溢出策略将抛出异常」）
- **描述**：调用方按 README 只 `catch ChartException`，遇到上述输入会漏出 `SvgException` / 数值溢出异常直接冒泡，图既不返回也不按契约失败；同时对 `turns`、`yAxis` 数值、茎叶值都缺少量级上限，错误信息里也拿不到是哪个字段越界
- **建议**：在 `ChartConfig.parse` 与各图专属字段处统一加上限（如 `abs(v) <= 1e12`）并抛 `chartInvalidValue`；`SpiralChart` 对 `turns` 增加 `isInf()/isNaN()` 与合理上限（如 ≤ 1000）；茎叶图在做 `Int64` 转换前校验 `stem` 落在 `Int64` 安全区间。更彻底的做法是在 `draw` 外层把 `SvgException` 包装成 `ChartException(InvalidValue)`，保证 README 承诺的单一异常类型

### [一般][存量] 茎叶图参数校验重复三遍，且两处规则不一致

- **位置**：`f_chart/src/StemLeafChart.cj:59-61` 与 `:151-153`（`"数据不能为空"`）、`:73-80` 与 `:154-159`（`stemUnit` / `leafDigits` 同文案）
- **来源**：存量（`e52c6e3db`）
- **判据**：review-checklist §2「跨层复制 / 近似重复：一块少了边界判断」、§11「语义漂移风险」
- **证据**：静态确定 —— 三条错误消息文本完全相同；`draw` 侧 `leafDigits` 还额外校验 `rawDigits != floor(rawDigits)`（`:78`），helper 侧拿到的是已转好的 `Int64`，只校验 `[0, 6]`，两侧规则并不等价；`stemUnit` 判断（`:74` vs `:154`）逐字重复
- **描述**：改一处漏一处就会出现"`draw` 放行、helper 抛错"或反之的行为漂移；`stemLeafRows` 是 `internal` 且被测试直接调用（`StemLeafChart_test.cj:41`）做了防御，`draw` 里的同一套校验就是纯冗余
- **建议**：只保留 `stemLeafRows` 内的校验（它是唯一入口，测试也走它），`draw` 侧删掉重复判断；或反过来把校验抽成 `validateStemLeafOptions(stemUnit, rawDigits)` 一处实现、两侧共用

### [一般][存量] 通用原语被反复手写：插入排序（本部分 4 处 / 全模块 22 处）、唯一性检查 2 处 O(n²)、分组去重线性查找

- **位置**：本部分 4 处插入排序 `f_chart/src/ShapChart.cj:179-187`、`StemLeafChart.cj:164-172`、`SunburstChart.cj:183-191`、`SurvivalChart.cj:280-288`；O(n²) 唯一性检查 `ShapChart.cj:70-74`、`SunburstChart.cj:78-82`；`SunburstChart.cj:141-148`（`findNode` 线性查找）、`StackedAreaChart.cj:313-320`（`groupIndexesOf` 线性查找）
- **来源**：存量
- **判据**：review-checklist §2「表现形式不同的重复逻辑（只改类型名 / 字面量复制）」、§6.4「热点里反复 `contains` / 双层循环做去重」
- **证据**：静态确定 —— 全模块 `grep "while (j > 0"` 命中 22 个文件，比较键分别是 `Float64`、`Int64`、`SurvivalPoint.time`、`node.total`，升降序与稳定性假设各写一遍；`ShapChart` 与 `SunburstChart` 的重复检查是同一个"遍历已收集列表 + 字符串相等"结构，只是错误文案不同（"特征 … 重复" / "节点 id 重复"）
- **描述**：同一份排序/去重语义复制 20+ 次，任何一次改动（例如改成稳定排序、加并列处理）都要人工同步；`ShapChart`/`SunburstChart` 的去重是 O(n²) 字符串比较，`n` 由输入特征数/节点数决定，上万条时会成为可见耗时（占比未测，见「待验证假设」）
- **建议**：在 `ChartScale.cj`（或新的 `ChartSort.cj`）提供 `stableSortBy` 与 `indexOfUnique`；去重改用 `HashMap<String, Int64>`（`SequenceChart.cj:63-69` 已经是正确写法，可直接复用该模式）；`SunburstChart` 建 `HashMap<String, SunburstNode>` 后 `findNode` 变 O(1)

### [一般][存量] 堆叠面积图把分组结果算两遍，颜色解析也写两遍

- **位置**：`f_chart/src/StackedAreaChart.cj:104`（`stackedAreaBounds` 内部调 `groupIndexesOf` + `uniqueGroupCount`）、`:157-158`（draw 里再调一次）、`:142-150` 与 `:189-192`（同一套 color 解析）
- **来源**：存量
- **判据**：review-checklist §2「同文件内两两比对函数体的输入-输出-副作用」「同一输入重复计算」、§6.4
- **证据**：静态确定 —— `groupIndexesOf(groups)` 与 `uniqueGroupCount(...)` 的入参完全相同（`:104` 与 `:157-158` 都是 `groups.toArray()`），`StackedAreaChart.cj:310-339` 两函数均无副作用，结果必然一致；颜色：`:146-149` 生成 `colors` 数组后，`:189-192` 又对每个 series 重做同一个 `match`
- **描述**：`groupIndexesOf` 是 O(S²) 线性查找（`:313-320`），`stackedAreaBounds` 里还要按 `groupCount` 维护累计数组，等于把同一份分组信息算两遍；颜色解析重复则让"改配色规则"需要同时改两处，且两处容易漂移（`SurvivalChart.cj:268-273` 的 `colorOf` 已经是抽好的写法）
- **建议**：在 `draw` 里先算 `groupIndexes` / `groupCount` 并以参数传入 `stackedAreaBounds`（或让 `stackedAreaBounds` 返回 `(bounds, groupIndexes, groupCount)`）；颜色统一走 `colorOf` 式辅助函数（见「优化可行性方案」）

### [一般][存量] 生存曲线置信带是直线折线，与阶梯状主曲线几何不一致

- **位置**：`f_chart/src/SurvivalChart.cj:195-215`（band 路径）、对照 `:228-244`（`survival-line` 的阶梯构造）
- **来源**：存量
- **判据**：review-checklist §11「语义与实现不符」、渲染一致性
- **证据**：静态确定 —— band 用 `M` + 逐点 `L` 直接连接每个时间点的上下界，主曲线则对相邻两点插入 `(x_i, y_{i-1})` 形成水平-垂直台阶；两者在同一时刻的边界不重合，band 会在每个区间内斜穿阶梯
- **描述**：开启 `confidence: true` 后，置信区间看起来像普通折线带，与 KM 曲线的阶梯语义矛盾，读者会误读"生存率在区间内线性下降"；在台阶陡降处 band 与曲线的间隙最明显
- **建议**：band 的上/下界都按主曲线的方式生成台阶路径（每个 `time_i` 输出 `L x_i y_upper(prev)` + `L x_i y_upper(i)`），下界逆序回描后闭合

### [一般][存量] 螺旋图与茎叶图自绘标题，通用字段 `title.subtext` / `title.align` 被静默忽略

- **位置**：`f_chart/src/SpiralChart.cj:97-106`、`f_chart/src/StemLeafChart.cj:93-102`；承诺源 `f_chart/doc/chart-json-spec.md:44`（`subtext` 通用字段）、`ChartFrame.cj:98-130`（统一实现含副标题与对齐）
- **来源**：存量
- **判据**：review-checklist §14.1「接线缺失 / 通用能力未接入」、§13「文档承诺与实现不符」
- **证据**：静态确定 —— 两处都手写 `kit.text(config.title, anchor: "middle")`，无 `config.subtitle`、无 `config.titleAlign`；全模块另有 14 个文件同样自绘（`PieChart.cj`、`DonutChart.cj`、`SankeyChart.cj` 等，`grep "config.title.isEmpty()"` 全模块 17 个文件），属跨部分同源问题
- **描述**：spec §2.1 把 `subtext` 定义为通用字段，用户给 `spiral` / `stem-leaf` 配了副标题后图上什么都不出现，且没有任何告警；`align` 同样失效，标题永远居中。这类"通用字段局部失效"最难排查
- **建议**：两图改用 `ChartFrame`（`ChartFrame(config, false, 0.0, 0.0)` 后调 `drawTitle`），保留各自的文本排版；若必须自绘，至少复用 `ChartFrame.drawTitle` 的副标题/对齐分支

### [轻微][存量] 生存曲线置信区间把"数据点个数"当样本量

- **位置**：`f_chart/src/SurvivalChart.cj:196`（`count = points.size`）、`:198`、`:209`
- **来源**：存量
- **判据**：review-checklist §11「注释与实现语义」、统计口径待确认
- **证据**：待确认 —— 代码注释（`:293`）声明是"二项近似"，spec:1794 只写「是否画置信带」，没有规定置信区间的算法与样本量口径；KM 的方差应基于每个时间点的风险集人数（或 Greenwood 公式），而这里用的是整条曲线的点数，且对所有时间点共用
- **描述**：同一系列里早期时间点（风险集大）与晚期时间点（风险集小）的区间宽度完全相同，晚期区间被显著低估；由于没有规格，只能作提示，不能定为错误
- **建议**：明确口径：若坚持二项近似，至少按时间点传入风险集人数；若无法获得，spec 应写明"置信带为示意，非统计推断"

### [轻微][存量] 画布过小时螺旋图半径可为负，生成非法 `r` 值

- **位置**：`f_chart/src/SpiralChart.cj:110-113`、`:146`
- **来源**：存量
- **判据**：review-checklist §11「边界差一 / 越界」
- **证据**：静态确定 —— `maxRadius = min(width - padL - padR, height - padT - padB - 40.0) / 2.0 - 30.0`，`width/height` 只校验 `> 0`（`ChartConfig.cj:182`）；默认 `padding` 为 24（`ChartConfig.cj:22-25`），`width = height = 100` 时 `min(52.0, 12.0)/2.0 - 30.0 = -24.0`，即高度小于约 148 时 `maxRadius` 即为负，`spiralPoint` 之后的点坐标全部落在圆心另一侧
- **描述**：`maxRadius` 为负时 `spiralPoint`（`:175`）的半径随序号从负数开始增大，所有点落到圆心另一侧、且最大偏移只有 `|maxRadius|`（上例 24px），整张图缩成圆心附近的镜像小团；`distance` 也随之变小，标签被 `1 + 12/distance` 推到离点 12px 处，文字互相重叠。不崩溃，但输出已无信息量
- **建议**：`maxRadius <= 0` 时抛 `chartInvalidValue("width", "画布过小，无法绘制螺旋图")`，或对 `maxRadius` 设下限（如 ≥ 20）后再计算

### [轻微][存量] SHAP 图的 `features` 字段在 spec 与 README 示例里出现，实现从不读取

- **位置**：`f_chart/src/ShapChart.cj:38-79`（全文件无 `features`）；承诺源 `f_chart/doc/chart-json-spec.md:2115`、`f_chart/README.md:2316`
- **来源**：存量
- **判据**：review-checklist §13「API / 配置与源码不符」、§1「读了不用 / 死配置」
- **证据**：静态确定 —— 全文件搜 `features` 零命中（只有测试样例 JSON 里带着）；特征名实际来自 `series[0].data[].feature`
- **描述**：文档把 `features` 写成专属字段，用户按文档维护这份数组后它完全不参与渲染；两处数据源（`features` 与 `data[].feature`）不一致时也没有任何校验，容易让人以为顺序/子集受 `features` 控制
- **建议**：要么删掉 spec 与 README 里的 `features`（推荐，避免双数据源），要么把它实现为"特征白名单/排序"，并与 `data[].feature` 做一致性校验

### [轻微][存量] 时序图行高压缩到 25px 以下时，备注框与下一行消息标签重叠

- **位置**：`f_chart/src/SequenceChart.cj:114-118`（`rowHeight` 下限无约束）、`:141-147`（标签在 `y - 8`）、`:148-163`（备注框在 `y + 5`、高 20）
- **来源**：存量
- **判据**：review-checklist §11「布局越界 / 重叠」
- **证据**：静态确定 —— `rowHeight = minFloat(40.0, available / messages.size)`，消息多时可为 5–10px，而单条消息纵向占用约 `8 + 20 + 5 = 33px`；没有裁剪、折行或省略逻辑
- **描述**：消息条数多（约 `available/33` 以上）时，备注便签会压到下一条消息的文本上，`note` 与 `text` 都不可读；这是排版降级而非崩溃
- **建议**：`rowHeight` 设下限（如 24px）并在超限时按比例缩减字号或省略备注，或在备注存在时给该行分配更高行高

### [轻微][存量] 两处测试断言偏弱：一条恒真、一条由无关元素满足

- **位置**：`f_chart/src/StackedBarChart_test.cj:59-61`、`f_chart/src/SequenceChart_test.cj:94`
- **来源**：存量
- **判据**：review-checklist §11「语义与命名不符」、测试有效性
- **证据**：静态确定 —— `StackedBarChart_test.cj:59-60` 用同样入参调 `stackedBarX` 两次再断言相等，属同义反复（真正有效的是 `:62` 与 `band.center(0) - 15.0` 的比较）；`SequenceChart_test.cj:94` 断言 `count(svg, "stroke-dasharray") >= 2`，但每个参与者的 lifeline 本来就带 `dash: "4 4"`（`SequenceChart.cj:108`），两个参与者即已满足，消息虚线失效也不会被发现
- **描述**：前者删掉也不影响覆盖，后者给了"返回消息虚线已实现"的假保证；`type: "return"` 的虚线行为实际没有有效用例
- **建议**：`SequenceChart_test` 改为断言 `class="message"` 那条线的 `stroke-dasharray`（例如统计同时含 `message` 与 `stroke-dasharray` 的片段，或解析 SVG 后按 class 取属性）；删除 `:59-60` 的恒真断言

### [轻微][存量] 主题河流图图例恒为可见，单系列/空名时白占 26px

- **位置**：`f_chart/src/StreamgraphChart.cj:162`（`ChartFrame(config, true, ...)`）；对照 `f_chart/src/SlopeChart.cj:132`
- **来源**：存量
- **判据**：review-checklist §11「同类实现不一致」
- **证据**：静态确定 —— `SlopeChart` 用 `config.legend.show && series.size > 1`，`StackedAreaChart.cj:112` 用「非单系列空名」，`StreamgraphChart` 直接传 `true`；`ChartFrame.cj:76-83` 在 `legendVisible` 为真时把 `top` 增加 26px，`drawLegend`（`:135`）在 `names` 为空时直接 return，标题区因此留白
- **描述**：只有一个系列（或系列都没 `name`）时，图上多出一段空白，且与同模块其它多系列图表的行为不一致，属观感问题
- **建议**：改为 `config.legend.show && series.size > 1`，与 `SlopeChart` 对齐

> 存量缺陷共 17 条（一般 11 / 轻微 6），是否纳入修复待用户决定。

## 优化可行性方案

### [堆内存] 堆叠面积图改为逐系列流式累计，去掉 `2 × S × C` 的层数组

- **现状**：`StackedAreaChart.cj:159-187` 预分配 `lowerLayers` 与 `upperLayers` 两个 `S × C` 的 `Float64` 数组（`S` = 系列数、`C` = 类目数），共 `2·S·C·8` 字节常驻到 `draw` 结束；`S=50`、`C=2000` 时约 1.6 MB，`S=200`、`C=10000` 时约 32 MB
- **方案**：只保留每组一个 `cums[groupCount][C]` 与当前系列的 `lower/upper` 两个长度 `C` 的数组，按系列顺序"算 lower/upper → 画 path → 累加进 cums"，即把 `:188-238` 的绘制循环上移进 `:175-187` 的累计循环
- **预期**：该结构的峰值内存从 `2SC` 降到 `2C + G·C`（`G` = 分组数，通常为 1–3），常见场景下降约 50%–95%（按上述规模估算），GC 压力同步下降
- **代价**：循环结构调整，绘制与累计耦合在同一循环；语义不变（同一 `stack` 内的累计顺序保持系列输入序），需要补一个"分组 ≥ 2 且含负值"的回归用例
- **验证**：`cjpm bench -O2` 同输入（S=50/C=2000 与 S=200/C=5000 两组）对照 `getAllocatedHeapSize()` 峰值与 RSS，取多轮中位数
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] 茎叶图去掉数据的三份副本

- **现状**：`StemLeafChart.cj:62-71` 收集 `ArrayList<Float64>` → `toArray()` 一份拷贝；`stemLeafRows:160-163` 再复制一份做插入排序；`:181-197` 又把每个值转成 `Int64` 存进 `leaves` 数组。三个结构同时存活到 `draw` 结束，`n` 个值时约 `24n` 字节（不含对象头与 `ArrayList` 扩容余量）
- **方案**：在 `stemLeafRows` 内直接对入参数组排序（调用方已 `toArray()`，无需再保护），叶只在拼字符串时按需转换、不再单独存 `Int64` 数组（或把 `leaves` 改为 `ArrayList<Int64>` 按茎大小精确分配，避免每个茎一个满额数组）
- **预期**：峰值对象数从 3 份降到 1–2 份，`n=100k` 时省约 1.6 MB 常驻与一次全量复制
- **代价**：`stemLeafRows` 变为"会修改入参数组"，需在注释与测试里写明；`StemLeafRow.leaves` 类型若是 `Array<Int64>` 仍要保留，收益主要来自前两项
- **验证**：同输入（10 万随机值，5 个不同 `stemUnit`）对照 `getAllocatedHeapSize()` 峰值与 GC 次数
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 主题河流图的分层路径从 O(S²·C) 降到 O(S·C)

- **现状**：`StreamgraphChart.cj:188-214` 对每个 `layer` 都从 `baseline` 重新累加 `0..layer` 的系列值，且正向、反向各算一遍：内层循环次数约 `2 · Σ_{l=0..S-1} l · C = S(S-1)·C`，即系列数的平方；`S=200`、`C=1000` 时约 4000 万次浮点加法
- **方案**：先按列算一次前缀和（`prefix[l][c]`，或直接在列循环里维护长度 `S` 的累加数组），两个方向的 path 都直接读 `prefix`；同时把 `:106-113` 的 `totals` 与 `:118-127` 的累计范围合并到同一遍扫描
- **预期**：浮点加法从 `S(S-1)C` 降到 `S·C`（`S=200` 时约 200 倍），`draw` 的 CPU 时间在系列多、列少时明显下降（端到端占比未测）
- **代价**：增加一个 `S × C` 的 `Float64` 缓冲（`S=200`、`C=1000` 约 1.6 MB），可用"每列累加数组 + 单遍输出"避免；需要保证与现实现的浮点累加顺序一致，避免路径端点出现 1e-16 级差异
- **验证**：`cjpm bench -O2`，输入 S∈{10, 50, 200}、C=1000，比较 `draw` 中位数与输出 SVG 的路径坐标逐字节一致性
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 旭日图建树与索引用 `HashMap` 替代 O(n²) 线性查找

- **现状**：`SunburstChart.cj:78-82` 每个节点对已收集列表做一次全量比较（O(n²) 字符串比较），`:100-110` 每个节点调一次 `findNode`（`:141-148`，O(n) 线性查找），建树整体 O(n²)；n=5000 时约 2500 万次字符串比较
- **方案**：一次遍历建 `HashMap<String, Int64>`（id → 下标）同时完成重复检测，第二次遍历用该表 O(1) 取父节点；`findNode` 可删除（`SequenceChart.cj:63-69` 已是这种写法）
- **预期**：建树从 O(n²) 降到 O(n)，n=5000 时字符串比较次数下降约 4 个数量级；`sortChildren` 的插入排序在大扇出节点上仍是 O(k²)，可一并换稳定排序（见「发现」#8 与本表末条）
- **代价**：多一个 `HashMap`（n 条约 50–80 字节/条），内存换 CPU；`HashMap` 迭代序不影响输出（建树顺序仍按 `nodes` 数组）
- **验证**：`cjpm bench -O2`，输入 100 / 1000 / 5000 个节点（宽树与深链各一组），比较 `draw` 中位数与输出一致性
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 螺旋图每点算两次、每点两个临时数组

- **现状**：`SpiralChart.cj:117-128` 与 `:137-158` 对同一批 `index` 各调用一次 `spiralPoint`（`:164-178`），每次返回一个新的 `Array<Float64>`；即 `2n` 次三角函数对与 `2n` 个双元素数组，`n` 为数据点数
- **方案**：第一遍把 `[x, y]` 存入两个 `ArrayList<Float64>`（或一次算出的 `Array<Float64>` 对），画点与标签直接复用；`spiralPoint` 改为写输出参数（或返回 `struct` 值类型）避免数组分配
- **预期**：三角函数调用减半、临时数组从 `2n` 降到 0–1 个；`n=10k` 时省约 20k 次 `cos/sin` 与 20k 次分配
- **代价**：多一个长度 `n` 的坐标缓存（`2·8·n` 字节），绘制循环需要 index 对齐；语义不变
- **验证**：`cjpm bench -O2`，`n ∈ {1k, 10k}` 对照 `draw` 中位数与输出 SVG 一致性
- **证据状态**：`无基线（待验证，不进 tasks）`

> 共享原语（22 处插入排序、O(n²) 去重）换成 `HashMap`/标准排序的收益同样缺少基线，统一列在「待验证假设」，不单独估算比例。

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 主题河流图 `S²·C` 累加在系列多时成为主要 CPU 段 | `f_chart/src/StreamgraphChart.cj:188-214` | 自耗时占比、调用路径 | `cjprof record` 跑 S=200/C=1000 的 `draw`，100 次取中位数 |
| 2 | 旭日图 `findNode` + 去重的 O(n²) 在 n≥2000 时可见 | `f_chart/src/SunburstChart.cj:78-82`、`:141-148` | 每阶段耗时占比 | `cjprof record` 跑 n=5000 宽树；分段计时建树 vs 绘制 |
| 3 | 22 处插入排序在 n≥10k 时拖慢 `draw` | `ShapChart.cj:179-187`、`StemLeafChart.cj:164-172`、`SurvivalChart.cj:280-288`、`SunburstChart.cj:183-191` | 排序耗时占比 | `cjpm bench -O2`，n∈{1k,10k,100k} 对照 std 排序 |
| 4 | 堆叠面积图 `2·S·C` 层数组是峰值内存主项 | `StackedAreaChart.cj:159-170` | `getAllocatedHeapSize()` 峰值、RSS 曲线 | S=50/C=2000 与 S=200/C=10000 两组各跑 20 轮 |
| 5 | 螺旋图 `2n` 次分配带来可测 GC 抖动 | `SpiralChart.cj:117-158` | 分配速率、GC 次数 | `cjprof heap` 或 `getAllocatedHeapSize()` 增量，n=10k |
| 6 | `draw` 内临时 `StringBuilder`/数组适合 local mode | `ShapChart.cj:130-167`、`SpiralChart.cj:116-128`、`StemLeafChart.cj:126-132` | 改前/改后峰值内存 | 先按 `mem §1` 排除长期引用，再开 `--enable-local-mode` 对照 `getUsedHeapSize()` 峰值；注意 `draw` 返回 `String`、多数临时对象在返回前不再逃逸，但 `cjLocalRegionMaxSize` 是新的 OOM 面 |
| 7 | 旭日图深链（深度≈节点数）会在某个 n 上栈溢出 | `f_chart/src/SunburstChart.cj:150-176`、`:178-196`、`:198-210`、`:212-249` | 触发溢出的最小深度、单帧栈占用 | 构造 500 / 2000 / 5000 / 10000 层链式 `nodes`，逐步跑 `draw` 记录首个崩溃深度；`ulimit -s` 与 SDK 默认栈大小一并记录 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_chart/src/SequenceChart.cj` | .cj | ✅ | 见发现 #1 / #2 / #15 |
| 2 | `f_chart/src/SequenceChart_test.cj` | .cj | ✅ | 见发现 #16（`:94` 弱断言） |
| 3 | `f_chart/src/ShapChart.cj` | .cj | ✅ | 见发现 #8 / #14 |
| 4 | `f_chart/src/ShapChart_test.cj` | .cj | ✅ | 覆盖排序稳定性、重复特征、空数据；未覆盖 `features` 字段 |
| 5 | `f_chart/src/SlopeChart.cj` | .cj | ✅ | 坐标映射与系列校验核对无缺陷；图例判定被 #17 引用 |
| 6 | `f_chart/src/SlopeChart_test.cj` | .cj | ✅ | 覆盖双时点、长度、类型校验 |
| 7 | `f_chart/src/SpiralChart.cj` | .cj | ✅ | 见发现 #6 / #11 / #13 |
| 8 | `f_chart/src/SpiralChart_test.cj` | .cj | ✅ | 覆盖首末点坐标、方向镜像、圈数/负值校验 |
| 9 | `f_chart/src/StackedAreaChart.cj` | .cj | ✅ | 见发现 #9；内存方案见「优化可行性方案」 |
| 10 | `f_chart/src/StackedAreaChart_test.cj` | .cj | ✅ | 覆盖累计、分组、负值、null、长度不一致 |
| 11 | `f_chart/src/StackedBarChart.cj` | .cj | ✅ | 31 行委托 `BarRenderer.render`，无独立逻辑；注释指向的 spec 小节存在（`doc/chart-json-spec.md:287`） |
| 12 | `f_chart/src/StackedBarChart_test.cj` | .cj | ✅ | 见发现 #16（`:59-61` 同义反复） |
| 13 | `f_chart/src/StemLeafChart.cj` | .cj | ✅ | 见发现 #5 / #6 / #7 / #11 |
| 14 | `f_chart/src/StemLeafChart_test.cj` | .cj | ✅ | 覆盖分茎、排序、钳制、参数校验 |
| 15 | `f_chart/src/StreamgraphChart.cj` | .cj | ✅ | 见发现 #17；复杂度与优化见 CPU 方案 |
| 16 | `f_chart/src/StreamgraphChart_test.cj` | .cj | ✅ | 覆盖三条基线、长度不一致、类型校验 |
| 17 | `f_chart/src/SunburstChart.cj` | .cj | ✅ | 见发现 #3 / #4 / #6 / #8 |
| 18 | `f_chart/src/SunburstChart_test.cj` | .cj | ✅ | 覆盖弧数、一级标签、父节点缺失、多根、缺值 |
| 19 | `f_chart/src/SurvivalChart.cj` | .cj | ✅ | 见发现 #10 / #12 |
| 20 | `f_chart/src/SurvivalChart_test.cj` | .cj | ✅ | 覆盖阶梯线、删失、置信带、边界校验 |

合计：`.cj` 20 个 / `.md` 0 个 / 共 20 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 9 | 正确性 9 条（#1 / #3 / #4 / #5 / #6 / #10 / #12 / #13 / #15），#2 属 §14.1、#14 属 §13；设计上 `draw` 统一走 `ChartConfig.parse` + `ChartSvgKit`，分层正常；语言特性使用 `Option`/`match` 惯用，未发现 `mut` 误用；文本均经 `kit.text → SvgBuilder` 转义（`f_svg/src/SvgElement.cj:705-716`），本部分无注入面 |
| §1 死代码 | 3 | 逐个核对本部分 20 个 internal 类型/函数（`Participant`、`SequenceMessage`、`ShapContribution`、`shapOrder`、`SlopeSeries`、`SpiralDatum`、`spiralPoint`、`StackedAreaSeries`、`groupIndexesOf`、`uniqueGroupCount`、`stackedAreaBounds`、`StemLeafRow`、`stemLeafRows`、`StreamSeries`、`streamBaseline`、`SunburstNode`、`sunburstArcPath`、`SurvivalPoint`、`SurvivalSeries`、`survivalConfidence`）全仓引用，均有调用者；`public` 类 `SequenceChart` 等对外可达不判；命中 3 处不可达判定：`SunburstChart.cj:151`、`:179` 两处 `depth > total`（发现 #3）与 `:201` 的 `total <= 0.0`（叶子 total 已校验 > 0），后两处并入 #3 |
| §2 重复逻辑 | 3 | 同文件两两比对 10 个源文件共 31 个函数体：`StackedAreaChart` 的分组/颜色重复（#9）、`StemLeafChart` 三重复制校验（#7）、跨文件排序/去重原语重复（#8）；另核对 10 个测试文件的 `draw`/`count` 辅助函数与 47 个文件里的同一 `labelRotate` 判定片段，测试准备代码属误报边界，布局片段已并入 #8 的统计口径但不单独计条 |
| §3 空实现 | 0 | 20 个文件无空函数体、无 `TODO`/`FIXME`、无 `catch {}`；`StackedBarChart.draw` 是单行委托（非空实现） |
| §4 栈溢出 | 1 | 旭日图 4 个递归函数（`resolveTotals`/`sortChildren`/`assignAngles`/`drawNode`）深度 = 树高，上界为 `nodes.size - 1`（无固定常量）；按 n=5000 深链估算约 5000 帧，实际溢出阈值需实测（待验证假设 #7）；其余 9 个图无递归 |
| §5 OOM | 0 | 无全局容器、无缓存、无按报文头预分配；所有数组长度来自已解析的 `series[].data`（`Array` 长度即输入规模），`StackedArea` 的 `2SC` 与 `StemLeaf` 的 3 副本属"可优化"而非 OOM 面（已量化为优化方案） |
| §6.1 热点瓶颈 | 0 | 本轮无 bench/profile 数据，未把任何"看起来慢"的路径写成缺陷；全部候选进「待验证假设」并注明采集方式（#1–#3 为 CPU，#4–#5 为内存/分配，#6–#7 为 local mode 与栈深度） |
| §6.2 大粒度锁 | 0 | 20 个文件无 `synchronized`/`Mutex`/原子操作 |
| §6.3 并发串行 | 0 | 无 `spawn`、无线程池、无批次提交 |
| §6.4 低效算法 | 4 | 已计入发现 #8（O(n²) 去重/线性查找/插入排序）与优化方案（`Streamgraph` O(S²C)、`Sunburst` O(n²)、螺旋 2n 次三角函数）；因缺占比数据，性能结论不写成缺陷 |
| §7 降堆内存方案 | 2 | `StackedArea` 层数组、`StemLeaf` 三副本，均标注 `无基线（待验证）` |
| §8 降 CPU 方案 | 3 | `Streamgraph` 前缀和、`Sunburst` 哈希索引、`Spiral` 单遍计算；均标注 `无基线（待验证）` |
| §9 local mode 可行性 | 0 | `draw` 内确有大量短生命周期临时对象，但无改前/改后峰值内存数据，且 `draw` 返回 `String`、临时对象生命周期跨越整个函数；只能列为待验证假设 #6，不写成方案 |
| §11 现有代码的 BUG（存量） | 17 | 本部分 20 个文件的边界、空值、错误路径、布局、契约逐条核对；17 条全部为存量（工作区快照，无 diff） |
| §12 并发安全与锁粒度 | 0 | 10 个 `Chart` 实现均为无状态类（仅 `init()`，无成员字段），`SunburstNode` 等可变对象都是 `draw` 内局部构造，不跨线程共享；无共享路径可指，故不判不安全 |
| §14 功能完备性与 README 覆盖 | 4 | 10 个图类型在 `README.md` / `README_en.md` / `doc/chart-json-spec.md` 均已登记（逐个 grep 命中）；命中 3 条承诺缺失：`sequence` 的 `async`（#2）、`stem-leaf` 的自动换列（#5）、通用 `title.subtext` 对 `spiral`/`stem-leaf` 失效（#11）；另 1 条 §13 文档漂移：SHAP 的 `features` 字段被实现忽略（#14） |
| 文件覆盖（§13 等） | 20/20 | 与 `files/f_chart.part34.txt` 一一对应，无遗漏；`chart-json-spec.md` / `README.md` 仅作承诺源交叉核对，不计入本部分文件数 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 11 |
| 轻微 | 6 |
| 优化方案（堆内存 / CPU） | 2 / 3 |

## 总评

这 10 个图类型的输入校验与 SVG 组装整体是扎实的：解析全部走 `ChartJson`（路径化错误信息）、坐标计算统一用 `LinearScale`/`BandScale`、文本全部经过 `f_svg` 转义、测试覆盖了主要校验分支与确定性，没有发现数据竞争或崩溃级缺陷。

主要风险集中在三处。第一是**边界与布局**：`stem-leaf` 的行/列完全不做画布约束（README 承诺的换列不存在），`sunburst` 对单节点输入输出空图、对环状引用静默丢节点，`sequence` 自调用消息没有箭头——这些都不是数据错误，但会让"按文档用"的用户拿到错误或空白的图。第二是**错误契约不完整**：极大但有限的数值会在下游溢出成 `NaN`/`Int64` 溢出，抛出 `SvgException` 或数值异常，与 README:255「任何数值问题都以 `ChartException` 抛出」冲突，调用方的统一 `catch` 会漏。第三是**通用原语重复**：22 处手写插入排序、多处 O(n²) 去重/查找、`StackedArea` 重复算分组，目前规模下影响有限，但已成为行为漂移的来源（`StemLeaf` 已有三份不完全一致的校验）。

没有阻塞项：全部 17 条为存量，严重度均在"一般/轻微"，可排期处理；建议优先做 `stem-leaf` 布局与 `ChartException` 契约收敛（改动小、用户可感知），排序/去重原语与堆内存优化放到性能预算里按「优化可行性方案」的验证方式推进——这些方案的收益目前都还没有基线，不能当结论用。本部分未覆盖的同模块其他图表也存在同一问题（模块内共 17 个文件自绘标题，其中本部分 2 个），合并时建议按根因合并成模块级条目。
