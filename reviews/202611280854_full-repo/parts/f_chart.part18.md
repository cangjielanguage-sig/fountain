# f_chart 模块审查报告（模块第 18/37 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_chart`（本部分 20 个 `.md`，0 个 `.cj`；覆盖 `doc/spec/add-f-chart-{qq,radar,raincloud,residual,ridge,roc}` 六个已完成的变更文档）
- **基线**：工作区快照（master 与 sts/1.3.x 同一提交 `120fd2542`，`git diff` 为空）⇒ 全部问题来源记「存量」
- **审查重点**：文档与实现一致性、规格自洽性、功能完备性与 README 覆盖（本部分无源码，渲染/布局/OOM/并发等专项通过文档承诺反查实现核对）
- **报告版本**：v1

## 发现

### [轻微][存量] 雷达图 `design.md` 的几何与校验口径与实现不一致（半径、标签偏移、空 `indicators` 的错误类型）

- **位置**：`f_chart/doc/spec/add-f-chart-radar/design.md:5`（半径 `min(plot.width, plot.height)/2 - 30`）、`:8`（标签「1.0 半径外 14px」）、`:18`（`indicators` 非空否则 `InvalidValue`）；`f_chart/src/RadarChart.cj:88`（`- 36.0`）、`RadarChart.cj:107-126`（标签落在圆周顶点上，仅 `dx ±8` / `dy ∓6`）、`RadarChart.cj:52-55`（空数组抛 `chartMissingField`）
- **来源**：存量（快照模式无基线；`git log` 显示 `design.md` 与 `RadarChart.cj` 由同一提交 `24366dad0` 引入，说明写文档时即未与实现对齐，不是后续实现漂移）
- **判据**：review-checklist §13「规格与实现漂移 / 文档过期」——文档给出的可复算数值（30px、14px）与代码常量（36.0、8/6）不同，属两边位置都能点名的确定性不符
- **证据**：静态确定 —— `RadarChart.cj:88` 字面量 `36.0`；`107-126` 行 `labelPoint` 与 `point` 同参数（半径 `1.0`），文字坐标只加 `offsetX=±8`、`labelOffsetY=±6`，没有任何沿半径向外的 14px 位移
- **描述**：按 `design.md` 复现会得到比实现大 6px 的绘图半径、并把标签放到圆环之外；实测半径差会让 1.0 圈与标签的间距与文档描述不同（标签实际压在轴端点上，最外圈与文字可能重叠）。第三处是错误契约：空 `indicators` 走 `requiredArray` 后的显式判空分支，抛 `MissingField`，而 design 写「否则 InvalidValue」，按文档写断言的调用方会失败。另有一处文档未覆盖的硬错误：`RadarChart.cj:89-91` 在 `radius <= 0` 时抛 `chartInvalidValue("width", "画布太小…")`，`design.md` / `spec.md` 均未记录画布下限，小画布（如 100×100）会拿到未预期的 `InvalidValue`
- **建议**：把 `design.md:5` 改为 36px、`:8` 改为「标签落在 1.0 半径顶点，水平 ±8px、垂直 ∓6px」、`:18` 区分「缺失/空数组 → `MissingField`，`max <= 0` / 长度不符 → `InvalidValue`」；在 `spec.md` 的「雷达指标轴」下补一条画布下限（`min(plot.width, plot.height) > 72`）的需求或场景

### [轻微][存量] 山脊图 `design.md` 的采样点数比实现少一个（80 vs 81）

- **位置**：`f_chart/doc/spec/add-f-chart-ridge/design.md:10`（「取 80 个采样点」）；`f_chart/src/RidgeChart.cj:154`（`for (step in 0..=80)`，闭区间 81 个点）
- **来源**：存量（同提交 `04d69cecc` 引入）
- **判据**：review-checklist §13「文档与实现不一致」——采样点数决定曲线顶点数与 `densities` 长度，是可复算的确定值
- **证据**：静态确定 —— `0..=80` 为含两端点的 81 次迭代；`points` / `densities` 各 81 项，路径输出 81 个 `L` 段
- **描述**：文档写 80 个点、实现 81 个点（80 段），按文档复算出的顶点间距（`span/79`）与实现（`span/80`）差一个步长；对视觉影响可忽略，但会让「按设计核对曲线采样密度」的后续维护者误判
- **建议**：文档改为「81 个采样点（80 段）」或实现改为 `0..<80`（后者会改变已有 SVG 输出，需同步快照类断言，故优先改文档）

### [轻微][存量] 雨云图输出的 `raincloud-cap` 类名未进入任何文档；`spec.md` 的图元清单还缺 `raincloud-outlier`

- **位置**：`f_chart/doc/spec/add-f-chart-raincloud/specs/chart-rendering/spec.md:7`（只列 box / median / whisker）、`f_chart/doc/spec/add-f-chart-raincloud/proposal.md:12`（列了 outlier，未列 cap）；`f_chart/src/RaincloudChart.cj:301-310`（两条 `raincloud-cap`）、`RaincloudChart.cj:311-314`（`raincloud-outlier`）
- **来源**：存量（同提交 `8f44451ab` 引入）
- **判据**：review-checklist §14.2「公开 API / 输出面未文档化」、§13「文档与实现不一致」——SVG class 是该模块对外的唯一定制面（外部靠它挂 CSS / 后处理），属于对外契约
- **证据**：静态确定 —— 全仓 `grep -rn "raincloud-cap" --include=*.md` 零命中；`.cj` 仅 `RaincloudChart.cj:304`、`:309` 两处输出
- **描述**：箱线须端的横向端帽（`raincloud-cap`）完全不可发现：使用者按 proposal 的类名清单写样式时箱须端帽永远保持默认描边；`spec.md` 的图元清单又比 proposal 少 `raincloud-outlier`，两份文档对同一输出的枚举不一致。注意这两处只是文档缺项，`showBox=false` 时实现确实不输出它们（与 spec 的开关需求一致）
- **建议**：`proposal.md:12` 补 `raincloud-cap`，`spec.md:7` 的 MUST 清单补 `raincloud-outlier` 与两条 `raincloud-cap`

### [轻微][存量] 残差图 `spec.md` / `design.md` 未记录「`series` 必须恰好 1 个」这一硬校验

- **位置**：`f_chart/doc/spec/add-f-chart-residual/specs/chart-rendering/spec.md:34`（校验清单只有 `x`/`y` 数字、`data` 非空、`series` 缺失、`type` 不符）、`f_chart/doc/spec/add-f-chart-residual/design.md:3-5`；`f_chart/src/ResidualChart.cj:45-47`（`seriesItems.size != 1` → `InvalidValue`）
- **来源**：存量（同提交 `0c5ff05eb` 引入）
- **判据**：review-checklist §13「文档与实现不一致」、§14.1「只做了一半的分支 / 文档未覆盖实现中的硬校验」——同一批文档里 `qq/specs/chart-rendering/spec.md:30` 明确写了「`series` MUST 恰好 1 个」，残差图却漏了，属同类需求的口径漂移
- **证据**：静态确定 —— `spec.md` 全文无「系列数 / 恰好 1 个 / 多系列」表述；`ResidualChart.cj:45-47` 明确抛错；`ResidualChart_test.cj` 10 个用例中没有多系列用例（该分支无测试覆盖）
- **描述**：使用者按 spec 的「校验」清单理解契约时，会认为多系列是合法输入（例如同一模型多个残差集）；实际直接抛 `InvalidValue`，只能从源码发现。测试也没覆盖该分支，后续若有人放宽限制不会有失败用例提醒
- **建议**：`spec.md` 的「残差校验」补「`series` MUST 恰好 1 个，否则 `InvalidValue`」，并补一个 `rejectsMultipleSeries` 用例（与 `QQChart_test.cj:146` 对齐）

### [轻微][存量] 山脊图 `spec.md` / `proposal.md` 未标明 `overlap`（及 `bandwidth`）的挂载层级，放在顶层会被静默忽略

- **位置**：`f_chart/doc/spec/add-f-chart-ridge/specs/chart-rendering/spec.md:16`（只写「`overlap` MUST 在 0 到 1 之间」）、`f_chart/doc/spec/add-f-chart-ridge/proposal.md:10`（「`overlap` 控制曲线重叠程度…`bandwidth` 可选」，未说属于 series）；`f_chart/src/RidgeChart.cj:85-96`（只在每个 `series[i]` 对象上读 `bandwidth` / `overlap`）
- **来源**：存量（同提交 `04d69cecc` 引入）
- **判据**：review-checklist §13「文档与实现不一致」——`grep -rn "overlap" f_chart/src/*.cj` 只有 `RidgeChart.cj:93`（series 对象）一处读取；`ChartConfig` 只按名读已知字段，没有未知键校验，因此顶层 `overlap` 既不生效也不报错
- **证据**：静态确定 —— `RidgeChart.cj:63-100` 的循环体对 `item`（series 元素）取 `json`，`json.number("overlap", default: 0.5)`；绘制侧用 `item.overlap`（`:150`）。顶层写入 `"overlap": 1.5` 时 `0-1` 校验不会被触发，全部系列静默使用 0.5
- **描述**：spec 的第二条需求（重叠系数）是该图唯一的专属参数需求，却没说它挂在 `series[i]` 上；按 proposal 的字面读法把 `overlap` 写在顶层是最自然的理解，结果是「配置无效且无告警」，同时「非法重叠抛 `InvalidValue`」的场景在这种写法下永不成立。`README.md:990-993` 的示例写法是对的，所以影响面限于只读 spec/proposal 的使用者与后续维护者
- **建议**：`spec.md:16` 与 `proposal.md:10` 明写「`series[i].overlap`（默认 0.5）」「`series[i].bandwidth`」；若要容忍顶层写法，则在 `RidgeChart.draw` 里做一次根级回退读取并保留同样的 0–1 校验

> 存量 5 条（均为轻微，文档口径类），是否纳入修复待用户决定。

## 优化可行性方案

本部分为 20 个 `.md`，无运行时语义，不产出堆内存 / CPU 方案（无基线即不成立）。源码侧的算法线索见「总评·范围外提示」，交由对应源文件部分取证与统计。

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| — | 无 | — | 本部分无性能承诺或性能描述，文档中的采样点数（48 / 81）为固定常量，不随输入增长，不存在「文档宣称的性能结论待验证」的场景 | — |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_chart/doc/spec/add-f-chart-qq/specs/chart-rendering/spec.md` | .md | ✅ | 三条需求与 `QQChart.cj` 逐条核对一致（分位公式、点数/参考线、校验错误类型）；四分位场景 0.125/0.375/0.625/0.875 复算正确 |
| 2 | `f_chart/doc/spec/add-f-chart-qq/tasks.md` | .md | ✅ | 任务均已完成；声明的 6 类用例在 `QQChart_test.cj:41-185` 均有对应 |
| 3 | `f_chart/doc/spec/add-f-chart-radar/design.md` | .md | ✅ | 见发现 #1（半径、标签偏移、错误类型三处与实现不符） |
| 4 | `f_chart/doc/spec/add-f-chart-radar/proposal.md` | .md | ✅ | 字段与实现一致；未记录 `indicators[].max` 缺省 100、`name` 缺省序号的默认值 |
| 5 | `f_chart/doc/spec/add-f-chart-radar/specs/chart-rendering/spec.md` | .md | ✅ | 三条需求与实现一致（4 层网格、10 个 symbol、clamp01 到外圈）；未记录画布下限（并入发现 #1） |
| 6 | `f_chart/doc/spec/add-f-chart-radar/tasks.md` | .md | ✅ | 已完成；`max <= 0` 与画布过小两条校验无用例（`RadarChart_test.cj` 7 个用例未覆盖） |
| 7 | `f_chart/doc/spec/add-f-chart-raincloud/design.md` | .md | ✅ | 布局常量（0.35 / 0.15 / 0.18 / 0.1、8% 余量、48 采样）与实现逐项一致 |
| 8 | `f_chart/doc/spec/add-f-chart-raincloud/proposal.md` | .md | ✅ | 复用的 4 个内部函数均存在并被调用；类名清单缺 `raincloud-cap`（见发现 #3） |
| 9 | `f_chart/doc/spec/add-f-chart-raincloud/specs/chart-rendering/spec.md` | .md | ✅ | 开关与校验与实现一致；图元清单缺 outlier / cap（见发现 #3） |
| 10 | `f_chart/doc/spec/add-f-chart-raincloud/tasks.md` | .md | ✅ | 已完成；云/雨/箱/开关/校验在 `RaincloudChart_test.cj:52-154` 均有对应用例 |
| 11 | `f_chart/doc/spec/add-f-chart-residual/design.md` | .md | ✅ | x 5% / y 8% 余量、含 0、虚线零线、4px 半径均与实现一致 |
| 12 | `f_chart/doc/spec/add-f-chart-residual/proposal.md` | .md | ✅ | 与实现一致；未提「仅 1 个系列」（见发现 #4） |
| 13 | `f_chart/doc/spec/add-f-chart-residual/specs/chart-rendering/spec.md` | .md | ✅ | 见发现 #4；`y` 轴含 0 与余量的措辞与 `residualRange` 的「先并入 0 再加余量」实现一致 |
| 14 | `f_chart/doc/spec/add-f-chart-residual/tasks.md` | .md | ✅ | 已完成；声明的散点/零线/轴范围/校验在 `ResidualChart_test.cj:59-176` 均有对应用例 |
| 15 | `f_chart/doc/spec/add-f-chart-ridge/design.md` | .md | ✅ | 见发现 #2（采样点数）；行基线、绘制顺序、Silverman 带宽（`DensityChart.cj:302` 为 1.06σn^-0.2）均与实现一致 |
| 16 | `f_chart/doc/spec/add-f-chart-ridge/proposal.md` | .md | ✅ | 见发现 #5（`overlap` / `bandwidth` 挂载层级未写明）；`ridgeAmplitude` 存在且被实现与测试引用 |
| 17 | `f_chart/doc/spec/add-f-chart-ridge/specs/chart-rendering/spec.md` | .md | ✅ | 振幅公式 `bandHeight × (0.8 + 0.4 × overlap)` 与 `RidgeChart.cj:241` 一致；4 系列场景计数与实现一致 |
| 18 | `f_chart/doc/spec/add-f-chart-ridge/tasks.md` | .md | ✅ | 已完成；10 个用例覆盖曲线数量、标签、overlap、带宽与校验 |
| 19 | `f_chart/doc/spec/add-f-chart-roc/design.md` | .md | ✅ | 稳定插入排序、0–1 默认范围、AUC 文本 `AUC = 0.86`（`formatSvgNumber` 去尾零）均与实现一致 |
| 20 | `f_chart/doc/spec/add-f-chart-roc/proposal.md` | .md | ✅ | `diagonal` 默认 true 与 `RocChart.cj:87` 一致；`auc` 校验在 `specs/chart-rendering/spec.md:25` 已有承诺，无缺项 |

合计：`.cj` 0 个 / `.md` 20 个 / 共 20 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 0 | 本部分 20 个 `.md` 无执行代码；已逐条复算文档中的可验证数值（QQ 四分位四点、雷达 2×5=10 symbol、雨云 12 点/1 箱/2 须、山脊 4/4/4、残差 6 点），并核对渲染侧实现，未发现文档承诺与行为相反之处 |
| §1 死代码 | 0 | 文档无声明可判死代码。反向做了「文档点名符号是否真实存在」检查：`qqTheoryQuantiles` / `normalQuantile` / `qqFitLine` / `ridgeAmplitude` / `residualXRange` / `residualYRange` / `clamp01` / `gaussianKde` / `defaultBandwidth` / `boxScatterBounds` / `swarmOffsets` / `chartNiceTicks` / `LinearScale` / `ChartFrame` 全部在 `f_chart/src/*.cj` 命中且有调用者，无失效引用 |
| §2 重复逻辑 | 0 | 六组文档的 `## ADDED Requirements` / `Capabilities` 段落属 OpenSpec 文件格式要求，需求正文语义互不相同，不判重复；同文件中无两段同义描述。源码侧三处插入排序（见总评「范围外提示」）不在本部分文件清单内，不占用本部分统计 |
| §3 空实现 | 0 | 文档无函数体；「承诺的图元」逐类 grep 均有输出点（`qq-point`/`radar-area`/`symbol`/`raincloud-*`/`ridge-*`/`residual-*`/`roc-*`），无 TODO / 占位 / 空分支承诺 |
| §4 栈溢出 | 0 | 文档描述的算法（核密度采样、插入排序、分位计算）在实现中均为定长循环或单层循环，无递归、无用户可控深度 |
| §5 OOM | 0 | 文档未承诺无界容器；采样点数固定（雨云 48、山脊 81），数据点数只在输出图元数量上线性增长，无「按不可信长度预分配」的文档承诺 |
| §6.1 热点瓶颈 | 0 | 本部分无 profile / bench 数据，也无性能承诺，热点结论不成立；未写入待验证假设（文档不引入新的性能断言） |
| §6.2 大粒度锁 | 0 | 文档无并发 / 锁语义，`f_chart` 渲染路径为「入参构造 → 输出字符串」，无 `synchronized` |
| §6.3 并发串行 | 0 | 同上，文档未描述任务提交或并行度配置 |
| §6.4 低效算法 | 0 | 文档未描述复杂度；实现中的插入排序（O(n²)）属源码线索，无基线不判定，见「范围外提示」 |
| §7 降堆内存方案 | 0 | 本部分无运行时对象生命周期；无基线，按铁律不写方案 |
| §8 降 CPU 方案 | 0 | 同上 |
| §9 local mode 可行性 | 0 | 文档无函数内临时大对象描述；无改前改后峰值内存数据，按 §9 只能停留在假设，故不列 |
| §11 现有代码的 BUG（存量） | 0 | 本部分无源码；核对文档时读到的实现边界（空 `series`/空 `data`/单系列约束/轴范围/`peak <= 0` 早退）已逐个与文档比对，除发现 #1–#5 的口径差异外未发现实现侧缺陷 |
| §12 并发安全与锁粒度 | 0 | `f_chart` 的 `Chart` 实现均为无状态（`public class XChart <: Chart` + `init()` 空构造，每次 `draw` 局部变量），文档也未承诺线程安全，无共享可变状态可指认 |
| §14 功能完备性与 README 覆盖 | 2 | 命中发现 #3（`raincloud-cap` 未进任何 `.md`）、#4（残差图多系列约束未写）；其余 public 图表类（`QQChart`/`RadarChart`/`RaincloudChart`/`ResidualChart`/`RidgeChart`/`RocChart`）均在 `README.md` 有独立小节与示例 |
| 文件覆盖（§13 等） | 20/20 | 清单 20 个文件全部读完，无跳过；§13 一致性命中 5 条（发现 #1–#5，均轻微） |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 0 |
| 轻微 | 5 |
| 优化方案（堆内存 / CPU） | 0 / 0 |

## 总评

这 20 个文件是 6 个已完成变更（M13 雷达、M23 QQ、M24 山脊、M40 残差、M47 ROC、M88 雨云）的归档规格，整体质量高于常见「写完就丢」的变更文档：每条需求都带可验证场景，场景里的计数与数值（分位点、图元数量、振幅公式、余量比例）都能与当前实现逐项对上，`tasks.md` 声明的用例在对应 `*_test.cj` 里确实存在。没有承诺未实现、空实现、占位 TODO 或失效引用，不存在阻塞项。

5 条发现全部是文档口径类：`design.md` 的几何常量（30px vs 36px、14px vs ±8/∓6px）与采样点数（80 vs 81）在实现里对不上，且与实现同一提交引入，说明是「文档随手写的数」而非后续漂移；`spec.md` 侧有两处契约漏项——雨云的 `raincloud-cap` 类名在任何 `.md` 里都搜不到、残差图漏写「仅 1 个系列」但实现会抛错，前者影响样式定制，后者会让按文档理解契约的使用者踩坑；山脊图的 `overlap` 没写挂载层级，写在顶层会被静默忽略且 0–1 校验不触发（README 示例是对的，故影响有限）。建议按条更新文档，不需要改实现；若希望「顶层 `overlap` 也能用」，则是实现侧的小改动，需单独评估。

存量 5 条，均为轻微，是否纳入修复待用户决定。

**范围外提示**（不在本部分 20 个文件内，不占用统计，交由对应源文件部分取证）：

1. 插入排序在 `f_chart/src/QQChart.cj:156-171`（`sortValues`）、`f_chart/src/RaincloudChart.cj:320-335`（`sortRaincloud`）两处函数体逐行相同（仅函数名不同），`f_chart/src/RocChart.cj:188-203`（`sortPoints`）是同一算法换元素类型与比较键——属 §2「只改类型名」型重复，建议抽 `sortFloat64Asc(values: Array<Float64>)` 复用；O(n²) 在大样本系列上是否构成热点需 `cjprof` 数据，当前无可测基线。
2. `f_chart/src/RocChart.cj:145-151` 的对角线用 `xRange` 端点同时映射 x 与 y（`yScale.scale(xRange[0])`），当调用方把 `yAxis.min` 设为大于 0（如 0.4）时线段会画到绘图区外（`f_chart` 全模块无 `clipPath`），可能压到标题/轴标签；`README.md:1919-1920` 的示例用 0–1 不会触发，属显式轴范围下的边界问题，建议改用 `max(xRange[0], yRange[0])`..`min(xRange[1], yRange[1])` 裁剪端点。
