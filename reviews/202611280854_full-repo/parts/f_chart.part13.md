# f_chart 模块审查报告

> **模块第 13/37 部分**（本报告只覆盖 `files/f_chart.part13.txt` 列出的 20 个文件：`add-f-chart-icicle` / `influence` / `lasso-path` / `learning-curve` / `lift` / `line` 六个变更的 `spec.md` / `design.md` / `proposal.md` / `tasks.md`。六个图型的 `src/*.cj` 不在本部分清单内，只在取证时引用，不占本部分文件覆盖统计。）

- **审查日期**：2026-11-28
- **模块路径**：`f_chart`（本部分 0 个 `.cj` + 20 个 `.md`，共 20 个文件）
- **基线**：工作区快照（`sts/1.3.x`，无 diff 可比 ⇒ 所有问题来源记「存量」）
- **审查重点**：本轮指定「渲染/布局算法正确性、坐标与数值边界、OOM、资源与内存、死代码、重复逻辑、存量 BUG」。本部分素材全部是 OpenSpec 变更文档，代码侧维度按 §13（文档与实现一致性）/ §14（功能完备性）执行：把 6 组文档的每条 Requirement / Scenario / Design 断言逐项落到 `src/` 的行，并优先用已提交的样例 SVG（`charts/M041/M053/M094/M097/M098-*.svg`）核对坐标——样例是产物级证据，比文字描述更硬
- **报告版本**：v1（第 13/37 部分）

## 发现

### [严重][存量] #1 四个图型的 x/y 轴方向与文档轴语义相反：整图被镜像，样例 SVG 已镜像提交

- **位置**：
  - 规格侧（本部分文件）：`f_chart/doc/spec/add-f-chart-lift/specs/chart-rendering/spec.md:23-30`（提升图轴）、`f_chart/doc/spec/add-f-chart-learning-curve/specs/chart-rendering/spec.md:5-12`（学习曲线折线）、`f_chart/doc/spec/add-f-chart-lasso-path/specs/chart-rendering/spec.md:5-12`（LASSO 路径）、`f_chart/doc/spec/add-f-chart-influence/specs/chart-rendering/spec.md:5-12`（影响点）、`f_chart/doc/spec/add-f-chart-line/design.md:7-12`（比例尺约定）
  - 实现侧（交叉核对用，属其他部分）：`f_chart/src/LiftChart.cj:134-135`、`f_chart/src/LassoPathChart.cj:156-157`、`f_chart/src/LearningCurveChart.cj:195-196`、`f_chart/src/InfluenceChart.cj:138-139`
  - 产物侧：`f_chart/charts/M094-lift.svg`、`M097-learning-curve.svg`、`M098-lasso-path.svg`、`M041-influence.svg`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「规格与实现漂移」+ §11「契约与实现不符」
- **证据**：静态确定 —— `LinearScale` 的语义写在 `f_chart/src/ChartScale.cj:22`：「`topPixel` 对应最大值，`bottomPixel` 对应最小值」，`scale()`（`:36-43`）为 `bottomPixel - (v-min)/span*(bottomPixel-topPixel)`，即 min→`bottomPixel`、max→`topPixel`。因此水平轴要"向右递增"必须传 `(plot.right(), plot.x)`，垂直轴要"向上递增"必须传 `(plot.y, plot.bottom())`；`LineChart.cj:177-178` 正是这样传的。而 lift / lasso-path / learning-curve 三处传的是 x→`(plot.x, plot.right())`、y→`(plot.bottom(), plot.y)`（两个方向同时取反＝180° 旋转），influence 只把 x 取反、y 正确。样例可直接读出：`M094-lift.svg` 的 x 刻度 `0` 在 `x=736`、`1` 在 `x=56`；`M097-learning-curve.svg` 的 y 刻度 `0` 在 `y=74`、`1` 在 `y=432`；`M041-influence.svg` 的 x 刻度 `0` 在 `x=908`、`0.1` 在 `x=577`。
- **描述**：提升图 x=0 应贴左边、学习曲线 y 越大应越靠上，这是读图前提。当前四个图型坐标框整体反向：提升曲线在 100% 处收于左侧、学习曲线随样本量增加向右下走、LASSO 的 0 系数线画在上方、杠杆图的杠杆值向右递减。由于 `drawXAxisNumeric` / `drawYAxis` 都按 `scale` 摆刻度（`ChartFrame.cj:168-187`、`:278-310`），刻度文字随数据一起反向，图形自洽所以"看不出错"，但结论会被读反。文档的问题是：这 5 份 spec/design 只写"范围覆盖全部数据 + 留 3%/5%/8% 余量"（如 `add-f-chart-lift/specs/chart-rendering/spec.md:25`、`add-f-chart-line/design.md:9-11`），**没有任何一条 requirement / scenario 约束轴方向**，镜像实现能通过全部验收场景，现有测试也只断言 class 计数与文案（`LearningCurveChart_test.cj:56-57,100,115`），不断言坐标。
- **建议**：把四处 `LinearScale` 实参改为 x→`(plot.right(), plot.x)`、y→`(plot.y, plot.bottom())`（与 `LineChart` 对齐）并重生成 `charts/M041/M094/M097/M098`；规格侧在 4 份 `specs/chart-rendering/spec.md` 各补一条 scenario：「WHEN 数据 x 递增 THEN 首点像素 x 严格小于末点像素 x」「WHEN 数据 y 递增 THEN 首点像素 y 严格大于末点像素 y」，把方向变成可回归的契约。
- **备注**：`.cj` 不在本部分清单内，本条按"文档契约与实现不符"立项，修代码时与上述四个图型所属子轮的发现合并，避免重复计数。

### [一般][存量] #2 学习曲线的 `std` 不随 `x` 排序重排，置信带与 y 轴范围按错位索引计算

- **位置**：`f_chart/doc/spec/add-f-chart-learning-curve/design.md:5`（"`std` 与 `data` 等长"）、`f_chart/doc/spec/add-f-chart-learning-curve/specs/chart-rendering/spec.md:39`（"`std` 提供时长度 MUST 与 `data` 一致"）；实现 `f_chart/src/LearningCurveChart.cj:80-114`（`std` 按输入顺序收集）、`:112`（只排 `points`）、`:131-134`（轴范围按 `index` 取 `std`）、`:220-245`（置信带按 `position` 取 `std`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「规格与实现漂移」、§11「语义与注释不符」
- **证据**：静态确定 —— `raw` 逐条 `add([x, y])` 后经 `sortLiftPoints(raw.toArray())` 得到按 x 升序的 `points`（`:112`），`stdValues` 是另一条独立数组（`:80-107`），全程没有跟随同一次置换；`LearningSeries` 只保存两份并行数组（`:24-33`）。随后 `dataMinY/dataMaxY`（`:131-134`）与闭合 path（`:222-235`）都用同一个下标同时索引 `points[i]` 与 `std[i]`。只要输入 data 不是按 x 升序（README 与样例恰好升序，掩盖了问题），第 i 个标准差就落到另一个 x 上。
- **描述**：规格承诺 `std` 与 `data` 逐点等长，读者会理解为"每点的 ±标准差"；排序后这条对应关系丢失。后果两层：(1) 置信带上/下包络取错点，带宽忽宽忽窄甚至交叉；(2) `y ± std` 参与 y 轴范围，轴范围与所有系列的刻度一起偏。`LearningCurveChart_test.cj:85-101` 只断言 `learning-band` 出现 1 次，覆盖不到这层。
- **建议**：把 `std` 与点绑定为一个内部结构（如 `LearningPoint(x, y, std)`）后再排序，或排序时同步置换 `std`；补一条"输入 data 逆序、std 已知"的用例，断言 band 的 y 值与轴范围。

### [一般][存量] #3 冰柱图静默丢弃与根不连通的节点，且"环检测"分支恒不成立

- **位置**：`f_chart/doc/spec/add-f-chart-icicle/specs/chart-rendering/spec.md:5-18`（"MUST 为每个节点绘制一个矩形"+ 七个节点场景）、`:42-54`（校验只要求"父存在 / 恰好一个根"）；实现 `f_chart/src/IcicleChart.cj:94-111`（建树 + 只校验根的个数）、`:166-169` 与 `:182-185`（`depth > total` 判环）、`:192-200`、`:241-243`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「空集合 / 边界未处理」、§1「恒真恒假分支」、§13「规格与实现漂移」
- **证据**：静态确定 —— 每节点只有一个 `parentId`，父存在即挂到 `children`（`:96-105`），不满足的只有"根不是恰好 1 个"（`:106-108`）。取 `R(parent=null)`、`A(parent=B)`、`B(parent=A)`：`roots=[R]` 通过校验，`A`/`B` 互为父子、永远遍历不到；`validateValues` / `assignDepth` / `layoutNode` / `drawNode` 都从 `rootNode` 出发（`:110-111`、`:139`、`:151`），于是 A、B 既不出现在 SVG 里也不报错——该输入满足 spec 的全部校验（parent 都存在、恰好一个根、value>0），按 spec 应输出 3 个 `icicle-node`。同时 `depth > total` 的两处判环（`:167`、`:183`）在这种情况下到不了；对"从根可达"的集合，因每节点至多一个父，可达子图必然无环，这两个分支恒为假。
- **描述**：坏输入被"部分渲染 + 不报错"吞掉，用户看到一张少画了节点的图且无任何信号；两处防御代码给出"已做环检测"的错觉。
- **建议**：建树后做一次可达性统计（节点数 vs 遍历点数），不等即抛 `chartInvalidValue("nodes", "存在与根不连通的节点")`；删掉 `validateValues` / `assignDepth` 里恒假的 `depth > total` 判断，或改为基于访问计数的检查。
- **备注**：`.cj` 不在本部分清单内，本条按"文档契约与实现不符"立项，与第 12 部分（`parts/f_chart.part12.md` #5）的同源代码发现合并即可，避免重复计数。

### [一般][存量] #4 时间轴解析既不校验日历合法性也不拒绝尾部多余字符，非法日期被静默归一

- **位置**：`f_chart/doc/spec/add-f-chart-line/design.md:25-27`（"`ChartTime.parseDays` 支持 `YYYY-MM-DD` 与 `YYYY-MM-DDTHH:MM:SS`（忽略时间部分）"）；实现 `f_chart/src/ChartTime.cj:28-39`（只检查长度 ≥10、`-` 位置与 `1..12 / 1..31`）、`:60-71`（`daysFromCivil`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「缺少边界校验」、§13「文档写 A 实现做 B」
- **证据**：静态确定 —— 长度判断是 `bytes.size < 10`（`:29`），只校验 `bytes[4]`、`bytes[7]` 是 `-`，第 10 位之后的任何内容全部忽略，因此 `"2026-01-01xyz"`、`"2026-01-01T99:99"` 都被接受（文档只声明两种形态）。日期只判 `day <= 31`（`:35`），`"2026-02-31"` 通过后由 `daysFromCivil` 按连续日期处理得到 2026-03-03。
- **描述**：文档把 `YYYY-MM-DD` 当契约，实现却接受"月份内不存在的日"和任意尾缀。时间轴数据来自用户 JSON，无声归一化会把 2 月 31 日画成 3 月 3 日的点，与相邻点的相对位置一起错，且从图上无法看出输入非法。
- **建议**：`parseDays` 增加每月天数校验（含闰年）与"第 10 位之后必须是 `T` 或结束"的判断，非法即抛 `chartInvalidValue(path, "日期不合法")`；文档同步写明"仅接受 `YYYY-MM-DD[T…]`，非法日期报错"。

### [一般][存量] #5 LASSO 路径图单系列时图例被整体隐藏，违反 spec 的 MUST

- **位置**：`f_chart/doc/spec/add-f-chart-lasso-path/specs/chart-rendering/spec.md:14-21`（"MUST 输出每个系列名称的图例文本"）；实现 `f_chart/src/LassoPathChart.cj:154`（`legendVisible = config.legend.show && series.size > 1`）、`:175`（仍无条件调 `drawLegend`）、`f_chart/src/ChartFrame.cj:134-137`（`!legendVisible` 直接 return）；测试 `f_chart/src/LassoPathChart_test.cj:64-69` 只覆盖 4 系列
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「契约与实现不符」、§14.1「只做了一半的分支」
- **证据**：静态确定 —— 单系列且 `legend.show` 默认真时 `legendVisible=false`，`ChartFrame` 因此不为图例预留高度，`drawLegend` 在 `:135-136` 提前返回；系列名在整份 SVG 里没有任何输出点（路径与点都不带标签）。spec 的 requirement 不带"多系列才显示"的前提，scenario 用的是两个变量名（`年龄`、`血压`），单系列场景无覆盖。
- **描述**：LASSO 路径图的唯一身份信息就是变量名，单变量输入时用户拿不到"这条线是谁"的提示；同时 `drawLegend` 传入完整 `names`/`colors` 却什么都不画，可见性判断与调用点分散在两处，后续改成 `>= 1` 时容易只改一边。
- **建议**：二选一并写进 spec——(a) 单系列也显示：`154` 改为 `config.legend.show && !series.isEmpty()`，spec 补 scenario；(b) 保持隐藏：spec `:16` 改成"单系列时除外"，并把 `drawLegend` 调用移进 `if (legendVisible)`，让判断与调用同源。

### [轻微][存量] #6 时间轴刻度没有"按天取整"，短跨度时日期标签重复

- **位置**：`f_chart/doc/spec/add-f-chart-line/design.md:27`（"刻度按天取整"）；实现 `f_chart/src/LineChart.cj:151-156`（`chartNiceTicks` 直接作用于天数）、`:365-375`（`formatXTicks`）、`f_chart/src/ChartTime.cj:42-45`（`formatDays` 里 `Int64(days)` 截断）；`f_chart/src/ChartScale.cj:70-105`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「文档过期 / 与实现不符」
- **证据**：静态确定 —— `chartNiceTicks` 按 1/2/5×10ⁿ 生成步长，不做整数化；`formatDays` 对小数天数直接 `Int64(days)` 截断。x 数据跨度小于 2 天（如只有 `2026-01-01`、`2026-01-02`）时，5% 余量 + nice 步长会落在 0.5 天这种位置，两个不同刻度被格式化成同一个 `YYYY-MM-DD`。
- **描述**：文档承诺刻度按天对齐，实现只保证"标签是日期字符串"，时间轴会出现两个同文本刻度，跨度越小越容易触发；另外 `Int64()` 对 1970 年以前的负天数向零截断，会整体偏一天。
- **建议**：时间轴刻度改为整数天步长（≥1 天），或对 `formatDays` 结果去重/合并，并对负天数改用向下取整；`design.md:27` 若只是意图描述，改为"刻度按 nice 步长生成、标签取整到天"。

### [轻微][存量] #7 `symbol` 非法取值静默退化为圆点，文档列的四种取值没有被校验

- **位置**：`f_chart/doc/spec/add-f-chart-line/proposal.md:11`（`symbol`（circle/square/diamond/none））；实现 `f_chart/src/LineChart.cj:117`（`string("symbol", default: "circle")`）、`:447-452`（`case _ => circle`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「契约与实现不符」（枚举值无校验）、§11「错误处理静默」
- **证据**：静态确定 —— `drawSymbol` 的 `match` 只有 `"none"` / `"square"` / `"diamond"` 三个精确分支，其余（含拼错的 `"squar"`、`"Circle"`）一律落到 `_ => kit.circle(...)`，全文件无 `chartInvalidValue("symbol", …)`。
- **描述**：其余图型对枚举字段普遍抛 `InvalidValue`（如 `IcicleChart.cj:114-120` 的 `orientation` / `colorBy`），折线图的 `symbol` 是例外：写错不报错、直接变形，用户会以为"diamond 不支持"。
- **建议**：读入后立即校验四值，非法抛 `chartInvalidValue("series[i].symbol", "期望 circle / square / diamond / none")`；`case _` 可保留为 `circle`，但校验前移。

### [轻微][存量] #8 影响图 design 描述的负 Cook 距离分支在公开路径上不可达

- **位置**：`f_chart/doc/spec/add-f-chart-influence/design.md:9-12`（"`cooks <= 0` 或 `maxCooks <= 0` 时返回 4"）、`f_chart/doc/spec/add-f-chart-influence/specs/chart-rendering/spec.md:14-26`（"等于最大值时返回 12"）；实现 `f_chart/src/InfluenceChart.cj:80-87`（负值抛 `InvalidValue`）、`:202-207`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §1「恒真恒假分支」的文档侧对应、§13「文档描述与可观测行为不符」
- **证据**：静态确定 —— 进入 `influenceRadius` 的 `cooks` 只可能来自已通过 `0 <= value` 校验的 `cooksDistance`（`:82-84`）或常量 4（`:159`），`cooks <= 0.0` 只剩 `cooks == 0` 可达，`cooks < 0` 这一半永远走不到。且所有点的 `cooksDistance` 都为 0 时 `maxCooks = 0`，函数返回 4，与 spec「等于样本最大值 → 12」的场景冲突（design `:11` 的退化规则没写进 spec）。单测 `InfluenceChart_test.cj:90,96` 只覆盖 0 与最大值。
- **描述**：design 把"负值返回 4"写成映射规则，读者会以为负 Cook 距离被当作 0 处理，实际是抛错；spec 的"最大值→12"场景在全 0 输入下不成立。两处都给后续维护者留下错误预期。
- **建议**：design `:11` 改成"`cooks == 0` 或 `maxCooks <= 0` 时返回 4（负值在校验阶段已拒绝）"；spec 的 Cook 距离映射 requirement 补"所有距离为 0 时半径取 4"。

### [轻微][存量] #9 两个图型输出了 proposal 清单里没有的 class（`lift-baseline-label`、`lasso-zero`）

- **位置**：`f_chart/doc/spec/add-f-chart-lift/proposal.md:12`（列 3 个 class）、`f_chart/doc/spec/add-f-chart-lasso-path/proposal.md:11`（列 2 个 class）、`f_chart/doc/spec/add-f-chart-lasso-path/design.md:17`（零线只写颜色，未给 class）；实现 `f_chart/src/LiftChart.cj:162-168`、`f_chart/src/LassoPathChart.cj:178-181`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「文档过期」、§14.2「公开 API 未文档化」（class 名是样式契约）
- **证据**：静态确定 —— `LiftChart` 在基准虚线右端另画 `className: "lift-baseline-label"` 的文本；`LassoPathChart` 的零线用 `className: "lasso-zero"`。两个 class 在对应 proposal / spec 的 class 清单里都不存在（全仓 grep 只在源码与 SVG 命中）。
- **描述**：class 名是对外样式钩子，下游用它写 CSS / 断言；少列两个 class 会让按文档写样式的人漏掉基准值标签与零线，也让"按 class 计数"的测试漏测。
- **建议**：在两份 proposal 的清单补 `lift-baseline-label`（基准值文本）与 `lasso-zero`（零系数参考线），各加一条 scenario。

### [轻微][存量] #10 折线图 design 对轴余量与类目标签的描述与实现不一致

- **位置**：`f_chart/doc/spec/add-f-chart-line/design.md:7-12`（"y 范围：显式 min/max 优先；否则 min/max 各留 5%"）、`f_chart/doc/spec/add-f-chart-line/proposal.md:10`（类目模式只用数值数组）；实现 `f_chart/src/LineChart.cj:456-478`（`lineRange`：`:468` / `:472` 单侧缺省时不留余量）、`:287-302`（缺省生成 `1..n` 类目标签）、`:304-313`（`xAxis.labels` 长度必须等于每个系列点数）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「文档过期 / 关键行为未记录」
- **证据**：静态确定 —— `lineRange` 只给 `axisMax` 时 `minimum` 直接取 `dataMin`（`:468`），只给 `axisMin` 时 `maximum` 取 `dataMax`（`:472`），与"否则两侧各留 5%"的字面不一致；`resolveLabels` 在没给 `xAxis.labels` 时生成 `"1"…"n"`，`validateLengths` 又要求每个系列点数与标签数完全相等，两条行为在 design / proposal 里都没提。
- **描述**：三处都是"用户会踩到但文档没写"的行为：只设 `yAxis.max` 时图形贴边（而非留 5%）、类目轴默认标签是序号而不是数据的 x、多系列长度不一致会抛 `InvalidValue`。按 design 推断会得到错误预期。
- **建议**：design §2 写明"单侧显式时另一侧贴数据、不额外留余量"，§4 补"类目模式缺省标签为 `1..n`、`xAxis.labels` 长度必须与每个系列一致"。

### [轻微][存量] #11 影响图 spec 未声明"恰好 1 个系列"，多系列输入被判非法

- **位置**：`f_chart/doc/spec/add-f-chart-influence/specs/chart-rendering/spec.md:37-39`（校验 requirement 只写 `x` / `y` / `cooksDistance` / `data` / `series` 缺失）；对照 `f_chart/doc/spec/add-f-chart-lift/specs/chart-rendering/spec.md:32-34`（提升图明写"`series` MUST 恰好 1 个"）；实现 `f_chart/src/InfluenceChart.cj:50-52`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §14.1「只做了一半的分支 / 承诺与实现不齐」、§13
- **证据**：静态确定 —— 实现拒绝 `series.size != 1`（"仅支持 1 个系列"，`InvalidValue`），而同批的 lift 图把这条写进了 spec；influence 的 spec 只在 proposal `:10` 用 `series[0].data` 隐含单系列。
- **描述**：按 influence spec 逐条实现，两个系列应当合法（spec 无数量限制），实际抛错，会直接变成用户工单。
- **建议**：influence spec 的校验 requirement 补"`series` MUST 恰好 1 个"，scenario 补"两个系列 → `InvalidValue`"，与 lift 对齐措辞。

### [轻微][存量] #12 冰柱图标签规格场景未说明"节点宽度不足时不输出标签"

- **位置**：`f_chart/doc/spec/add-f-chart-icicle/specs/chart-rendering/spec.md:14-17`（"WHEN 节点 name 为 main THEN SVG 中包含 icicle-label 文本 main"）；实现 `f_chart/src/IcicleChart.cj:227-240`（`if (node.width > chartTextWidth(node.name, fontSize) + 6.0)` 才输出）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「规格与实现漂移」（MUST 级验收场景缺前置条件）
- **证据**：静态确定 —— `spec.md:7` 的 requirement 是"为每个节点绘制矩形"，scenario 对标签无条件断言；实现按"矩形宽度是否容得下文本 + 6px"决定是否画 `icicle-label`。深层或小 value 节点天然宽度不足，因此"每个节点都有标签"并不成立；`IcicleChart_test.cj:66-70` 只断言 `main` / `layout` 两个宽节点，掩盖了差异。
- **描述**：按 scenario 写验收用例（小 value 叶子节点 + 检查标签）会失败；反过来，用户按文档以为标签是保证项，实际图上有节点无标签且无提示。
- **建议**：scenario 补前置条件（"WHEN 节点宽度足以容纳文本 THEN 输出 icicle-label"），或在 requirement 里显式写"标签按可用宽度省略，截断策略见实现"。

### [轻微][存量] #13 学习曲线的 `metric` 字段只做取值校验，对输出零影响（"语义标注"未接线）

- **位置**：`f_chart/doc/spec/add-f-chart-learning-curve/specs/chart-rendering/spec.md:28-35`（"`metric` MUST 为 `score` 或 `loss`（默认 `score`），仅用于语义标注，不改变坐标方向"）、`f_chart/doc/spec/add-f-chart-learning-curve/proposal.md:11`（`metric`（`score` / `loss`））；实现 `f_chart/src/LearningCurveChart.cj:43-46`（读出后仅做相等比较，之后不再使用）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §1「读了不用」（配置字段无效果）、§14.1「接线缺失」
- **证据**：静态确定 —— 全文件 `metric` 只有两处命中（`:43` 读取、`:44-45` 校验），SVG 里没有任何由 `metric` 派生的文本、`class` 或轴标题回退；`README.md:2212-2229` 的示例也带 `"metric": "score"`，读者会以为它有可见作用。
- **描述**：spec 用"语义标注"描述该字段，实现只把它当合法枚举校验；`loss` 与 `score` 输出完全一致（含 y 轴方向），字段实际上是死配置。这不影响数据正确性，但契约与实现口径不一致。
- **建议**：二选一并写进 spec——(a) 真正做标注（如无显式 `yAxis.title` 时回退为 metric 语义、或在根节点输出 `data-metric`）；(b) 改成"仅做取值校验，供调用方自行解释"，并删掉"语义标注"字样。

### [轻微][存量] #14 单点系列输出只有 `M` 的 path：文档承诺的"折线"在 1 个数据点时不可见

- **位置**：`f_chart/doc/spec/add-f-chart-learning-curve/specs/chart-rendering/spec.md:7`、`add-f-chart-lasso-path/specs/chart-rendering/spec.md:7`、`add-f-chart-lift/specs/chart-rendering/spec.md:7`（三处均要求"输出 1 条折线并连接全部数据点"）；实现 `f_chart/src/LearningCurveChart.cj:246-262`、`f_chart/src/LassoPathChart.cj:186-202`、`f_chart/src/LiftChart.cj:171-187`；校验处 `add-f-chart-learning-curve/specs/chart-rendering/spec.md:39`、`add-f-chart-lasso-path/specs/chart-rendering/spec.md:25`、`add-f-chart-lift/specs/chart-rendering/spec.md:34`（只要求 `data` 非空）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「规格未覆盖的边界」
- **证据**：静态确定 —— 三处路径生成都是 `position == 0 → "M x y"`、其余 `" L x y"`；`data` 只有 1 项时 path 只有一条 `M` 指令，无 `L`、无描边长度，SVG 里 `class="*-line"` 元素存在但不渲染任何线；三个 spec 都允许 `data` 长度为 1。
- **描述**：单点系列（如只有 1 个样本量的评估结果）得到的是一条看不见的"折线" + 1 个圆点，按 class 计数的测试仍会通过。文档既没规定最少点数，也没说明单点退化为散点。
- **建议**：spec 补"`data` 至少 2 点"（并在实现里加 `InvalidValue`），或明确"单点系列只输出圆点、不输出 line"，二者取一并让测试跟着断言。

## 优化可行性方案

> 本部分只有规格文档，没有独立实现与基线，因此不产出堆内存 / CPU 方案。文档里能看出的实现侧改进线索（插入排序、路径字符串拼接）按铁律降级到「待验证假设」，不进 `todo.md` / `tasks.md`。

- 优化方案（堆内存 / CPU）：0 / 0。

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `sortLiftPoints` 是插入排序（O(n²)），Lift / LassoPath / LearningCurve 三个图型共用；点数上千后排序可能成为 `draw()` 的主耗时 | `f_chart/src/LiftChart.cj:202-218`（被 `:65`、`LassoPathChart.cj:80`、`LearningCurveChart.cj:112` 调用） | n 从 100 到 10000 时的排序耗时与占 `draw()` 的比例 | `cjpm bench -O2` 生成 100 / 1000 / 10000 点的 `{x,y}` 输入，对 `draw()` 计时取中位数与离散度；或用 `cjprof record` 看 `sortLiftPoints` self time |
| 2 | 每个数据点用 `StringBuilder` 追加 `" L x y"` 生成 path，大 n 下字符串分配可能主导 GC；LASSO / 学习曲线 / 提升 / 折线四者同构 | `f_chart/src/LassoPathChart.cj:186-202`、`LearningCurveChart.cj:221-262`、`LiftChart.cj:171-187`、`LineChart.cj:411-431` | 单次 `draw()` 的分配字节数与 GC 次数 | `getAllocatedHeapSize()` 前后差值 + `cjprof heap`，输入 1k / 10k 点，各跑 200 次取中位数 |

## 文件覆盖

> 与 `{workdir}/files/f_chart.part13.txt` 一一对应（20 行）。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_chart/doc/spec/add-f-chart-icicle/specs/chart-rendering/spec.md` | .md | ✅ | 见 #3（不连通节点、恒假判环）、#12（标签条件）；方向/配色/其余校验与实现一致 |
| 2 | `f_chart/doc/spec/add-f-chart-icicle/tasks.md` | .md | ✅ | 4 项全 `[x]`，引用的 `IcicleChart_test.cj` 存在；无遗留任务 |
| 3 | `f_chart/doc/spec/add-f-chart-influence/design.md` | .md | ✅ | 半径公式与实现一致；见 #8（负值分支不可达、max=0 退化未入 spec） |
| 4 | `f_chart/doc/spec/add-f-chart-influence/proposal.md` | .md | ✅ | class / 半径 / 单系列意图与实现一致（单系列未写入 spec，见 #11） |
| 5 | `f_chart/doc/spec/add-f-chart-influence/specs/chart-rendering/spec.md` | .md | ✅ | 见 #1（x 轴反向）、#8（Cook 映射边界）、#11（未声明单系列） |
| 6 | `f_chart/doc/spec/add-f-chart-influence/tasks.md` | .md | ✅ | 4 项全 `[x]`，引用文件存在 |
| 7 | `f_chart/doc/spec/add-f-chart-lasso-path/design.md` | .md | ✅ | 排序/轴余量/零线与实现一致；见 #9（零线无 class） |
| 8 | `f_chart/doc/spec/add-f-chart-lasso-path/proposal.md` | .md | ✅ | 见 #9（少列 `lasso-zero`） |
| 9 | `f_chart/doc/spec/add-f-chart-lasso-path/specs/chart-rendering/spec.md` | .md | ✅ | 见 #1（双轴反向）、#5（单系列图例）、#14（单点系列） |
| 10 | `f_chart/doc/spec/add-f-chart-lasso-path/tasks.md` | .md | ✅ | 4 项全 `[x]`，引用文件存在 |
| 11 | `f_chart/doc/spec/add-f-chart-learning-curve/design.md` | .md | ✅ | 见 #2（`std` 未随排序重排）；轴余量 / 线宽 / 点径与实现一致 |
| 12 | `f_chart/doc/spec/add-f-chart-learning-curve/proposal.md` | .md | ✅ | `shade` / 三类 class 与实现一致；`metric` 见 #13 |
| 13 | `f_chart/doc/spec/add-f-chart-learning-curve/specs/chart-rendering/spec.md` | .md | ✅ | 见 #1（y 轴反向）、#2（std 逐点承诺）、#13（metric）、#14（单点系列） |
| 14 | `f_chart/doc/spec/add-f-chart-learning-curve/tasks.md` | .md | ✅ | 4 项全 `[x]`，引用文件存在 |
| 15 | `f_chart/doc/spec/add-f-chart-lift/design.md` | .md | ✅ | 轴范围 / 基准线 / 线宽点径与实现一致（轴方向见 #1） |
| 16 | `f_chart/doc/spec/add-f-chart-lift/proposal.md` | .md | ✅ | 见 #9（少列 `lift-baseline-label`） |
| 17 | `f_chart/doc/spec/add-f-chart-lift/specs/chart-rendering/spec.md` | .md | ✅ | 见 #1（x 轴反向）、#14（单点系列）；校验与场景其余可由实现满足 |
| 18 | `f_chart/doc/spec/add-f-chart-lift/tasks.md` | .md | ✅ | 4 项全 `[x]`，引用文件存在 |
| 19 | `f_chart/doc/spec/add-f-chart-line/design.md` | .md | ✅ | 见 #1（轴方向）、#4（日期解析）、#6（刻度取整）、#10（余量/标签） |
| 20 | `f_chart/doc/spec/add-f-chart-line/proposal.md` | .md | ✅ | 见 #7（`symbol` 无校验）；`ChartTime` / `drawXAxisNumeric` / 三种符号均存在 |

合计：`.cj` 0 个 / `.md` 20 个 / 共 20 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 5 | 正确性 4（#1 轴方向、#2 `std` 错位、#3 节点丢弃、#4 日期解析），可读性 1（#9 文档 class 清单不全）；设计 / 语言特性不适用（本部分无 `.cj`）。安全性做了反向核对：6 组文档未引入凭据、注入或外部路径写入，渲染入参只来自 JSON |
| §1 死代码 | 2 | 本部分无 `.cj`，未做 private / internal / protected 符号搜索（属各 `.cj` 子轮）。计入 2 条：`IcicleChart` 的两处 `depth > total` 在"单父 + 单根"约束下恒为假（#3），`LearningCurveChart.metric` 读出后不再使用（#13）。另外机械核对了文档引用到的 14 个符号（`IcicleChart` / `InfluenceChart` / `InfluencePoint` / `influenceRadius` / `LassoPathChart` / `LearningCurveChart` / `LiftChart` / `LineChart` / `sortLiftPoints` / `BandScale` / `LinearScale` / `drawXAxisNumeric` / `parseDays` / `formatDays`）——`grep` 全部在 `src/` 命中，无过期引用；5 份 `tasks.md` 共 20 条任务全部 `[x]`，引用的 5 个 `*_test.cj` 与 `ChartTime.cj` 都存在 |
| §2 重复逻辑 | 0 | 逐条比对 5 份 `specs/chart-rendering/spec.md` 的 requirement 与 scenario：learning-curve 与 lasso-path 的"按 x 升序连接 + 逐点圆点"、lift 与 lasso-path 的"轴范围覆盖全部数据"措辞相近，但边界（3% / 5% / 8% 余量、是否含基线、是否单系列）各不相同，属各变更的独立 delta，合并会抹掉差异，按 checklist §2 误报边界不判重复。实现侧的跨图复用（`sortLiftPoints`、`volcanoNumber` 被三张图借用）属 `.cj`，只作提示 |
| §3 空实现 | 0 | 6 组文档承诺的 class（`icicle-node/label`、`influence-point/label`、`lasso-line/point`、`learning-line/point/band`、`lift-line/point/baseline`、`line/symbol`）在 `src/` 都有实际输出路径；20 份文档中无 `TODO` / `FIXME` / `UnsupportedException` 占位。`metric` 的"仅校验"按 §1/§14 归类，不在此重复计数 |
| §4 栈溢出 | 0 | 文档侧未承诺递归，也未写节点数 / 树深上限。相关线索（`IcicleChart` 的四趟按树深递归）已在第 12 部分（`parts/f_chart.part12.md` #6）立项，本部分不重复；建议规格补"`nodes` 规模上限"或"树深上限"，使递归深度变成常量 |
| §5 OOM | 0 | 6 组文档均未声明数据规模上限，也未承诺流式/分页；本部分无分配路径。文档可补"单图点数上限"建议，但无基线不单列 |
| §6.1 热点瓶颈 | 0 | 无 `cjprof` / `cjpm bench` 数据，不提出热点结论；两条线索已进「待验证假设」#1 / #2 |
| §6.2 大粒度锁 | 0 | 6 个图型均为单次同步 `draw()`，文档未描述任何锁或共享 writer |
| §6.3 并发串行 | 0 | 同上，无 `spawn` / 批处理语义可核对 |
| §6.4 低效算法 | 0 | 文档未承诺复杂度；实现侧 `sortLiftPoints` 为插入排序（潜在 O(n²)），无输入规模数据，按铁律只进「待验证假设」#1 |
| §7 降堆内存方案 | 0 | 本部分无实现、无基线，见「优化可行性方案」 |
| §8 降 CPU 方案 | 0 | 同上 |
| §9 local mode 可行性 | 0 | 文档未提及 local mode；无函数级临时对象峰值数据，收益无法证明 |
| §11 现有代码的 BUG（存量） | 4 | 逐份核对 6 组文档的校验清单 / 轴范围 / 排序 / 解析断言与实现：#1（轴方向）、#2（`std` 错位）、#3（节点丢弃）、#4（日期解析）为存量缺陷；其余边界（空 `series`、空 `data`、非数字、负值、长度不符、`type` 不匹配）实现与文档一致（`ChartConfig.cj:166-176` 抛 `UnsupportedChart`） |
| §12 并发安全与锁粒度 | 0 | 六个图型的 `draw()` 只操作局部对象与 `ChartConfig` 快照，无共享可变状态、无惰性初始化、无跨线程发布；文档也未声明线程安全契约 |
| §14 功能完备性与 README 覆盖 | 3 | #7（`symbol` 枚举未校验）、#11（influence 未声明单系列）、#13（`metric` 无可见作用）。反向核对：6 个 `type` 值（`icicle` / `influence` / `lasso-path` / `learning-curve` / `lift` / `line`）都在 `ChartConfig.parse` 的入参校验中落地，README 均有对应小节（`README.md:664` 折线图、`1862` 影响图、`2138` 提升图、`2212` 学习曲线、`2232` LASSO、`2506` 冰柱图），样例 SVG 齐全；另记一句提示——`doc/spec/` 下 108 份 `chart-rendering` delta 没有合并后的 capability spec（`openspec/specs/` 只有 5 个无关能力），跨图型的轴/图例约定只能靠人工比对，这是仓库约定层面的问题，不作发现计数 |
| 文件覆盖（§13 等） | 20/20 | 无缺文件；§13 另命中 8 条（#1、#4、#5、#6、#8、#9、#10、#12），与上表 §11 / §14 条目互有交叉，统计按主根因归类，不重复计数 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 1 |
| 一般 | 4 |
| 轻微 | 9 |
| 优化方案（堆内存 / CPU） | 0 / 0 |

存量缺陷 14 条（均为本轮读到的既有文档 / 实现问题，快照模式无基线可比），是否纳入修复待用户决定。

## 总评

这 20 份文档的结构质量在模块内属上游：每个变更都有 spec delta（requirement + scenario）、design 给出坐标与配色参数、tasks 留了红绿过程，`design` 里的半径映射、线宽、点径、留白比例、class 名与实现基本逐项对得上。

真正的问题出在**文档没有覆盖的维度**：spec 只写"轴范围覆盖全部数据 + 留 X% 余量"，从不约束方向，于是 lift / learning-curve / lasso-path / influence 四个图型把 `LinearScale` 的 `topPixel` / `bottomPixel` 传反、整图镜像，全部验收场景与只数 class 的单测依然通过，`charts/` 里已提交的样例 SVG 也是镜像版本——这是本部分唯一应先修的阻塞项（#1）。其次是学习曲线的 `std` 排序错位（#2）与冰柱图静默丢节点（#3），都属于"跑得通、图画错"且被样例数据掩盖。

其余命中都是"少写一句"级别（日期合法性、刻度取整、class 清单、单系列图例、单点系列、标签省略条件、`metric` 无效果），不影响按文档起步，但会让使用者在边角输入上得到与预期不同的结果，建议随对应图型一起补齐。本部分没有实现文件，故不产出栈溢出、OOM、并发与性能结论；两条性能线索缺基线，只留在「待验证假设」里并提供采集方法。
