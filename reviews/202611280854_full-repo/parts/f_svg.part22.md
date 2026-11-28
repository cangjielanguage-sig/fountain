# f_svg 模块审查报告（第 22/26 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_svg`（本部分 20 个源文件，全部为 `.cj`）
- **基线**：工作区快照（`git status` 仅见未跟踪的 `docs/review/`、`reviews/`；`f_svg/src` 无改动）⇒ 全部问题来源为「存量」
- **审查重点**：SVG/XML 解析与序列化边界、注入与转义、递归与栈溢出、OOM、死代码、重复逻辑（本部分文件集中在样式级联、描边轮廓化、形状属性与 switch/tag 分派，不含解析器/序列化器本体）
- **报告版本**：v1（分部分报告，供主 Agent 合并到 `<module>.md` / `<module>_v2.md`）

## 发现

### [严重][存量] F1 dash 切分的片段数无上限，极小 dash 值可造成长时间占用 CPU 与内存爆炸

- **位置**：`f_svg/src/SvgStrokeOutliner.cj:547`（`dashPieces`，热点循环 `600-623`），配套 `149-159`（`isValidDash`）、`47`（`STROKE_EPSILON = 1e-9`）
- **来源**：存量（`git log -1 -- f_svg/src/SvgStrokeOutliner.cj` = `0a5bc715c`，2026-11-07；工作区无改动）
- **判据**：review-checklist §5（按不可信长度增长的无界容器）/ §6.4（按输入规模放大的循环）/ §11（边界未校验）
- **证据**：静态确定 —— `isValidDash` 只拒绝负数、NaN、Inf，任意正小数（如 `1e-4`）都通过；`dashPieces` 的内层 `while (consumed < length - STROKE_EPSILON)` 每轮只前进 `take = min(length-consumed, remaining)`，每轮新建 `SvgPoint`，每段 dash 结束时 `current.toArray()` 追加到 `result`。片段数 ≈ `路径长度 / (dash 周期)`，两个因子都由文档控制，代码里没有任何片段数上限、最短 dash 长度、总分配量上限。
- **描述**：`stroke-dasharray="0.0001"` 配一条长度 1000 的路径即产生约 5×10⁶ 个片段，每个片段还各自走 `outlineOne`（再产生四边形轮廓）。渲染入口 `SvgRenderer`→`SvgRasterizer.stroke`（`f_svg/src/SvgRasterizer.cj:150`）对这一路输入不做 clamp（`SvgRenderer.cj:509-527` 的 `scaleStrokeDash` 只做等比缩放），而 `pathLength` 属性还能把 dash 进一步等比缩小（`SvgRenderer.cj:517-527` 用 `actualLength / declaredPathLength`），等于给攻击者一个放大系数。后果是渲染不可信 SVG 时 CPU 与堆同时爆掉（OOM / 长时间无响应），本模块其余安全过滤（脚本、外部引用、`maxElements`、`maxDepth`）都拦不住这条路径。
- **建议**：在 `dashPieces` 入口对 dash 周期设下限（例如 `sum < 路径长度 / 最大片段数` 时按上限截断或退化为实线），并把片段总数上限（如 10⁴）作为常量或 `SvgRenderOptions` 字段；`isValidDash` 增加「最小有效 dash 长度」判据，与 `STROKE_EPSILON` 分离（后者目前是 1e-9，远小于 0.25 的几何容差，不能当业务下限用）。

### [一般][存量] F2 `calc()` 百分比对 `r` 用算术平均，规范要求对角线基准

- **位置**：`f_svg/src/SvgStyleResolver.cj:503`（`cssCalcPercentReference`，第 `507` 行）
- **来源**：存量（`git log -1` = `33a56f6ba`，2026-11-07）
- **判据**：review-checklist §11（契约与规格不符）+ §2（换算复制）
- **证据**：静态确定 —— 承诺源 `f_svg/doc/spec/add-f-svg-module/specs/svg-value-types/spec.md:34,36`：「`r` 用对角线基准」「对角线基准为 `sqrt(w²+h²)/sqrt(2)`」，`f_svg/doc/f_svg模块设计.md:254` 同述；实现为 `case "r" => Some((this.mediaWidth + this.mediaHeight) / 2.0)`。项目里已有正确实现 `toUserUnits(..., SvgLengthAxis.Diagonal, ...)`（`f_svg/src/SvgLength.cj:205-229`），本函数不复用而另写一份换算。
- **描述**：300×150 视口下 `calc(50%)` 用于 `r` 得到 112.5，规范值 118.6（偏低约 5%）；同一文档里非 `calc` 的 `r="50%"` 走 `toUserUnits` 得到 118.6，两条路径结果不一致。目前影响面限于 `r` + `calc()` + 百分比的组合。
- **建议**：`cssCalcPercentReference` 改为返回 `SvgLengthAxis`（或直接调用 `toUserUnits` 的百分比分支），`r` 映射到 `Diagonal`，删除自算的 `(w+h)/2`。

### [一般][存量] F3 样式缓存无界且跨 `compute` 复用，重复求值时诊断信息被静默丢弃

- **位置**：`f_svg/src/SvgStyleResolver.cj:70`、`71`（`styleCache` / `inlineCache`）、`84`、`85`（`warnedColorProfiles`）、`105`（`warnings.clear()`）、`212-235`（`parseStyleText` / `inlineDeclarations`）
- **来源**：存量（`33a56f6ba`，2026-11-07）
- **判据**：review-checklist §5（缓存键无界、无容量/TTL）+ §3（静默失效：诊断不再产生）+ §11
- **证据**：静态确定 —— `styleCache` 以完整 `<style>` 文本为 key，`inlineCache` 以完整 `style="..."` 文本为 key，二者只在 `get`/赋值处出现，`prepare` 与 `compute` 都不清理、不设上限；`warnedColorProfiles` 同样只增不清。`compute` 每次 `warnings.clear()`（105），但 `parseStyleText` 命中缓存时不会再调用 `CssStyleSheet.parse(text, this.warnings)`（216），`normalizeColorProfile` 命中 `warnedColorProfiles` 也不再 `warnings.add`（933-936）。
- **描述**：同一 resolver 实例第二次求值（文档不同但样式文本相同）时，`style` 解析告警与 `color-profile` 告警都不再出现——调用方看到「无告警」却拿到了降级值，属于静默失效；同时三次 map 都以用户文本为 key 永久保留，长期持有 resolver（如服务端常驻）处理多份文档时内存只增不减，`SvgComputedStyle` 里还挂着这些 sheet。
- **建议**：`warnings.clear()` 时同步清 `warnedColorProfiles`；缓存改为「每次 `compute` 一份、`compute` 结束即弃」（`compute` 内部 `local` 容器）或加容量上限 + LRU；若确要跨调用缓存，则把告警与缓存绑定（缓存项里保存首次解析的告警，命中时重放）。

### [一般][存量] F4 `prepare` 只按根元素 identity 命中缓存，文档增删 `<style>` 后仍返回旧规则

- **位置**：`f_svg/src/SvgStyleResolver.cj:158`（`prepare`，早退在 `163-165`，写回在 `208-209`）
- **来源**：存量（`33a56f6ba`，2026-11-07）
- **判据**：review-checklist §11（缓存失效缺失、注释契约不符）/ §12.1（可见性）
- **证据**：静态确定 —— 早退条件只有 `hasPrepared && preparedRoot == key`，`key` 是 `element.identity`；`mergedRules` / `selectorIndex` 一旦生成就不再随文档变化。项目已提供文档级变更通知 `SvgDocument.addMutationListener`（`f_svg/src/SvgDocument.cj:42-44`，`SvgMutationHub` 见 `f_svg/src/SvgMutation.cj:75`），但本类没有任何订阅（全目录 grep `mutationHub|addMutationListener` 在 `SvgStyleResolver.cj` 无命中）。
- **描述**：调用方 `compute(doc.root)` → 追加一个 `<style>`（或删除、改其文本）→ 再次 `compute(doc.root)`，第二次拿到的仍是第一次的规则集，且没有任何告警；类注释（`58-64`）写的是「`compute` 收集文档中的 `<style>`」，与实现的可观察行为不符。
- **建议**：`prepare` 增加失效信号——订阅 `SvgDocument` 的 mutation hub（或在 `prepare` 里比对已收集 `<style>` 文本序列的哈希），也可在类注释中显式声明「同一实例只对首次求值的文档快照有效」，二选一但必须落到文档上。

### [一般][存量] F5 `computeElement` 不清空 `warnings`，重复调用无限累积且无法区分来源

- **位置**：`f_svg/src/SvgStyleResolver.cj:125`（重载体 `132-136`），对照 `compute` 的 `105`
- **来源**：存量（`33a56f6ba`，2026-11-07）
- **判据**：review-checklist §11（两个入口契约不一致、资源无界累积）
- **证据**：静态确定 —— `compute` 在求值前 `this.warnings.clear()`；`computeElement` 两个重载（`120-122`、`125-137`）都不清理，`cascade` 里的 `warnings.add`（`285`、`307`、`344`、`371`、`673`、`905`、`935`）直接追加到同一个 `ArrayList`。
- **描述**：循环里逐元素 `computeElement`（例如批量算样式）时，每个非法值都留一条告警且永不释放，长跑进程内存随调用次数线性增长；调用方也无法判断某条告警属于哪一次调用，与 `compute` 的「本次求值告警」语义不一致。
- **建议**：与 `compute` 对齐，在 `computeElement` 入口 `warnings.clear()`（若需保留历史则改成返回本次告警）；`warnedColorProfiles` 一并复位。

### [一般][存量] F6 `outlineElement` 的「解析快路径」与通用 outliner 语义不一致（忽略 dash、忽略圆角、百分比按裸数值）

- **位置**：`f_svg/src/SvgStrokeOutliner.cj:104`（`outlineElement`）、`444-490`（`rectOutline`）、`502-519`（`circleOutline`）、`521-544`（`ellipseOutline`）
- **来源**：存量（`0a5bc715c`，2026-11-07）
- **判据**：review-checklist §11（同一公开 API 对不同元素类型行为漂移）/ §2（近似重复导致的行为漂移）
- **证据**：静态确定 —— `outlineElement` 对 `SvgRect`/`SvgCircle`/`SvgEllipse` 直接走 `rectOutline` / `circleOutline` / `ellipseOutline`，这三个函数体内 `style.dashArray` 零引用（`grep dashArray` 在本文件命中处仅 `69`、`89`、`549`、`552` 等 dash 分支）；`rectOutline` 内无 `rx`/`ry` 引用（圆角矩形被当成直角矩形）；几何值统一经 `lengthOrZero`（`f_svg/src/SvgGeometry.cj:375-380`）取 `.value`，百分比 `x="10%"` 被当成 10 用户单位。而 `SvgLine`/`SvgPolyline`/`SvgPolygon`/`SvgPath` 分支经 `outlinePolyline`/`outlineContours`，dash 正常生效。
- **描述**：同一个 `outlineElement(element, style)`，传 path 得到虚线，传 rect/circle 得到实线环；带 `rx="4"` 的圆角矩形描边变成直角；百分比几何在描边轮廓里错位。随着 `style.dashArray` 由调用方按元素类型决定是否预切分，行为差异对使用方是隐形的。
- **建议**：`outlineElement` 入口统一判断 `style.dashArray` 有效时改走「几何→点列→`outlinePolyline`/`outlineContours`」通用路径（`rectOutline` 已有该分支，只需把条件从「join 非 miter」改成「dash 有效 或 join 非 miter」）；圆角与百分比要么解析后再轮廓化，要么在注释里写明该入口只接受无单位、无 dash 的样式。

### [一般][存量] F7 `SvgStyleResolver` 全部求值状态是可变字段且无同步，共享实例并发 `compute` 会串扰

- **位置**：`f_svg/src/SvgStyleResolver.cj:69-85`（`sheet`/缓存/`mediaWidth`/`mediaHeight`/`interaction`/`preparedRoot`/`hasPrepared`）、`96-114`（`compute` 写这些字段）、`125-137`
- **来源**：存量（`33a56f6ba`，2026-11-07）
- **判据**：review-checklist §12.1（共享可变状态无保护）；判据要求：指出共享路径 + 缺失的同步手段
- **证据**：静态确定 —— 共享路径：`public class SvgStyleResolver` 的实例被两个线程同时调用 `compute`（类未声明线程封闭，无 `Mutex`/`Atomic`，注释亦未声明「非线程安全」）。缺失同步：`mediaWidth`/`mediaHeight`/`interaction` 在 `102-104` 写入后被 `cascade` → `considerSheet`（`429`）/`cssCalcPercentReference`（`505-507`）读取；`prepare` 依据 `preparedRoot` 决定是否重建 `mergedRules`/`selectorIndex`（`163-165`、`205-209`）；`warnings` 在 `105` 被 `clear` 而 `cascade` 同时追加。仓内生产路径每次 `SvgStyleResolver().compute(...)` 新建实例（如 `f_svg/src/SvgElement.cj:461`），风险只落在外部复用实例的调用方。
- **描述**：线程 A 在 `compute` 中把 `mediaWidth` 设为 400 后，线程 B 把它改成 800，A 的 `@media` 求值就用了 B 的视口；A 清空 `warnings` 后 B 追加的告警被吞；两线程各自 `prepare` 不同 root 时 `mergedRules` 与 `selectorIndex` 可能来自不同文档，`considerSheet` 用 `index.candidates` 得到的下标去索引另一份 `mergedRules`（`425-426`），越界或取错规则。
- **建议**：优先做成无状态——`compute` 内部用局部 `SvgCascadeContext`（媒体尺寸、interaction、规则集、告警收集器）串起来，类只保留不可变的 `sheet`；若要保留缓存，把可变字段收进每调用一份的上下文。至少要在类注释写明「非线程安全，需每线程一份」。

### [轻微][存量] F8 `normalizedFontSize` 的 `isNone()` 分支是不可达死代码

- **位置**：`f_svg/src/SvgStyleResolver.cj:383-385`
- **来源**：存量（`33a56f6ba`）
- **判据**：review-checklist §1（恒假分支）
- **证据**：静态确定 —— `296-308` 已经保证 `normalizedFontSize` 在该分支之后必为 `Some`：第一次 `normalizeValue` 返回 `None` 时先重试继承值（`303`），仍 `None` 则赋 `Some("16px")`（`304-306`）；`309-382` 之间无任何再赋值。
- **描述**：`if (normalizedFontSize.isNone()) { fontSizeExpression = None }` 永远不会成立，读代码的人会误以为 `font-size` 仍可能缺省。
- **建议**：删除该分支；若本意是「回退后不再记录 var 表达式」，应在 `304-306` 的回退路径里直接 `fontSizeExpression = None`。

### [轻微][存量] F9 `dashPieces` 开头的 dash 有效性判断不可达

- **位置**：`f_svg/src/SvgStrokeOutliner.cj:549-551`
- **来源**：存量（`0a5bc715c`）
- **判据**：review-checklist §1（不可达防御分支）
- **证据**：静态确定 —— `dashPieces` 是 `private`，仅有两处调用：`outlineContours:69-75` 与 `outlinePolyline:89-97`，两处都在调用前用同一条件 `style.dashArray.size == 0 || !isValidDash(style.dashArray)` 做了分流（`69`、`89`）。函数内 `549-551` 的同一判断恒为假。
- **描述**：重复的防御性分支让「dash 为空时是否切分」有两个真值来源，后续改动容易只改一处。
- **建议**：删除函数内的重复判断，或在函数首行注释「调用方已保证 dash 有效」，并在 `outlineContours`/`outlinePolyline` 里保留唯一判断。

### [轻微][存量] F10 轮廓方向反转的两处实现重复，`outlineContours` 与 `outlinePolyline` 的 dash 分支结构重复

- **位置**：`f_svg/src/SvgStrokeOutliner.cj:366-377`（`ensurePositiveOrientation` 内的反转循环）与 `492-500`（`reverseContour`）；`69-75`（`outlineContours` 的 dash 分支）与 `89-97`（`outlinePolyline` 的 dash 分支）
- **来源**：存量（`0a5bc715c`）
- **判据**：review-checklist §2（表现形式不同的重复逻辑）
- **证据**：静态确定 —— `ensurePositiveOrientation` 在面积为负时执行的 `while (index >= 0) { reversed.add(points[index]); index-- }`（`370-376`）与 `reverseContour`（`492-500`）逐行同构，唯一差异是前者多一次 `signedArea` 判定；`outlineContours` 的「dash 无效 → `outlineOne`；否则逐 `dashPieces` → `outlineOne(false)`」与 `outlinePolyline` 的同一段（`89-97`）输入输出一致，仅前者多了 `width <= 0` 之外的首尾闭合检测。
- **描述**：反转逻辑存在两份，`reverseContour` 的语义（无条件反转）与 `ensurePositiveOrientation`（条件反转）名称接近，`487`/`516`/`540` 的 `reverseContour(ensurePositiveOrientation(x))` 组合会让读者误以为可能双重反转。
- **建议**：`ensurePositiveOrientation` 在面积为负时调用 `reverseContour`；`outlineContours` 抽出 `outlineWithDash(points, closed, style)` 供两个入口共用（保留 `outlineContours` 额外的闭合检测与 `outlinePolyline` 的宽度守卫作为调用前条件）。

### [轻微][存量] F11 `SvgTag.create` 与 `SvgTag.isKnown` 维护两份同构标签字面量表

- **位置**：`f_svg/src/SvgTag.cj:21-77`（`create`）与 `79-93`（`isKnown`）
- **来源**：存量（`f8b4c49bd`，2026-11-07）
- **判据**：review-checklist §2（字面量复制）
- **证据**：静态确定 —— 逐项比对两地：`create` 分支覆盖 47 个标签（含 `style|title|desc|metadata|discard` 与 8 个容器标签），`isKnown` 的 `match` 列表为同一集合；`SvgBuilder.cj:152-153`、`192` 成对使用 `isKnown` + `create`。
- **描述**：新增/删除标签时必须同时改两处，漏改一处会让 `SvgBuilder` 走进 `SvgUnknownElement`（`154`）或让严格模式的未知标签检查（`163-171`）与实际建模能力相反；当前两份一致，属可维护性风险而非现存错误。
- **建议**：保留 `isKnown` 作为 O(1) 判断（用 `HashSet` 常量或 `Array` + `contains`），`create` 的 `match` 作为唯一定义源；或让 `isKnown` 由 `create` 的标签表派生（避免每次实例化对象可先查表）。

### [轻微][存量] F12 同族枚举的 `toString()` 约定不一致（`SvgLineCap` 返回 PascalCase，`SvgLineJoin` 返回属性名小写）

- **位置**：`f_svg/src/SvgShape.cj:36-42`（`SvgLineCap.toString` → `"Butt"`）、`82-84`（`SvgLineJoin.toString` → `attrName()`，即 `"miter"`）、`121-126`（`SvgFillRule.toString` → `"Nonzero"`）
- **来源**：存量（`519058f67`，2026-11-07）
- **判据**：review-checklist §10（可读性/一致性）/ §11（语义与命名不符）
- **证据**：静态确定 —— 三个枚举的 `toString` 分别返回 PascalCase、小写属性名、PascalCase；而写入属性时用的是 `attrName()`（`215`、`227`、`290`），序列化属性值统一走小写。
- **描述**：`SvgLineJoin.toString()` 的注释自称「与 `attrName()` 一致的规范字符串」，另外两个枚举没有同样处理；把 `SvgLineCap.toString()` 结果直接写进 `stroke-linecap` 属性虽然仍能被 `fromName` 小写化匹配，但与其他枚举的用法不对称，容易在序列化层写出 `Butt` 这类非标准值。
- **建议**：统一为两种风格之一：要么三个枚举 `toString` 全返回属性名（并同步 `SvgLineJoin` 注释），要么全返回类型名并把 `attrName()` 明确为唯一序列化入口；并在文档里写清哪个用于序列化。

### [轻微][存量] F13 `outlineContours` 缺 `width <= 0` 守卫，返回退化轮廓

- **位置**：`f_svg/src/SvgStrokeOutliner.cj:57-78`
- **来源**：存量（`0a5bc715c`）
- **判据**：review-checklist §11（同一 API 系列的边界处理不对称）
- **证据**：静态确定 —— `outlinePolyline:86-88` 与 `outlineElement:105-107` 都有 `style.width <= 0.0` 提前返回空数组；`outlineContours` 没有，`half = style.width / 2.0 = 0` 时 `outlineOne` 生成的四点四边形四个顶点重合，`addContour`（`359-364`）只检查 `size < 3`，仍会把它加入结果。
- **描述**：零宽描边经 `outlineContours` 得到一批零面积轮廓，调用方（`SvgRasterizer.stroke` 之外直接用 `outlineContours` 的外部代码）拿到非空结果却什么也画不出来；`SvgRasterizer` 自己在 `134` 处挡了零宽，所以仓内无可见后果。
- **建议**：与另外两个入口对齐，在 `outlineContours` 入口加 `style.width <= 0.0` 返回空数组。

### [轻微][存量] F14 `outlineElement` 无生产调用点，注释宣称的「解析路径」在渲染管线里从未走通

- **位置**：`f_svg/src/SvgStrokeOutliner.cj:100-104`（注释与签名）
- **来源**：存量（`0a5bc715c`）
- **判据**：review-checklist §14.1（接线缺失）
- **证据**：静态确定 —— 全模块 grep `outlineElement` 只有 `SvgStrokeOutliner_test.cj:170,198,209` 三处调用；`SvgRenderer` 与 `SvgRasterizer` 的描边一律 `flattenPathData` + `SvgStrokeOutliner.outlineContours`（`SvgRasterizer.cj:150`、`254`，`SvgRenderer.cj:618`）。
- **描述**：rect/circle/ellipse/line 的解析轮廓快路径对外的公开能力确实可用（测试覆盖），但注释「rect / circle / ellipse / line 走解析路径」描述的加速在渲染器里并不存在——所有元素都被扁平化后走通用 outliner，读者会误以为渲染已享受该优化。
- **建议**：要么把 `outlineElement` 接进 `SvgRenderer` 的描边分支（先解析几何再决定是否用解析轮廓），要么把注释改成「供调用方自行选用的解析轮廓入口，渲染管线不调用」。

### [轻微][存量] F15 测试用例与阈值：M6 全套复制 M5 用例、快照路径字面量两份、大样本阈值比注释目标宽 200 倍、1M 元素用例复用同一实例

- **位置**：`f_svg/src/SvgSnapshotM6_test.cj:95-137`（复制 `SvgSnapshotM5_test.cj:106-135` 的三个用例与两份场景常量）；`f_svg/src/SvgScene_test.cj:22`（`SCENE_DIR`）与 `f_svg/src/SvgSnapshotM5_test.cj:23`（`M5_SNAPSHOT_DIR`）同值 `"testdata/render"`；`f_svg/src/SvgRoundTrip_test.cj:59-83`（注释目标 25 ms / 20 ms，断言 `< 5_000.0`）；`f_svg/src/SvgSecurity_test.cj:245-256`（同一 `rect` 实例挂 1,000,000 次）
- **来源**：存量（各文件最后提交 2026-11-05 ~ 11-08）
- **判据**：review-checklist §2（测试中的重复复制）/ §11（断言强度不足、测试资源开销）
- **证据**：静态确定 —— `SvgSnapshotM5_test.m1ToM3SnapshotsExact` / `animationSnapshotsExact` / `m4SnapshotsExact` 与 `SvgSnapshotM6_test` 同名同体，同一批快照在一次 `cjpm test` 里被渲染两遍；`M1_TO_M3` 与 `M5_SCENES` 常量在两个类各写一份；`largeSampleSmoke` 注释写「解析 ≤ 25 ms、序列化 ≤ 20 ms」，实际断言 5000 ms；`elementCountAtDefaultLimit` 用同一个 `XmlElement` 反复 `children.add` 凑 1M 节点，而默认上限已由 `defaultLimits`（`260-268`）断言过。
- **描述**：快照套件重复执行使 CI 时长翻倍且两处常量容易只改一处；5 s 阈值等于没有回归门禁；1M 节点用例耗时与内存都不小，却只验证「默认值 1,000,000」这一个可由常量断言的性质，而且复用同一实例使树形不真实。
- **建议**：M6 只保留 M6 新增用例，历史快照回归交给一处；场景清单抽成共享 `internal` 常量；把大样本断言阈值按注释目标收紧或明确标注「仅冒烟」；元素数上限用例改为 `maxElements` 配小阈值（已有同类用例）或直接断言默认常量。

## 优化可行性方案

> 以下均为「还能更好」，不是缺陷。**没有改前基线 + 改后对照，一律标 `无基线（待验证）`，不得写成收益结论。**

### [堆内存] `cascade` 每次求值为单元素新建 4-5 个 `HashMap` 与一条元素路径字符串

- **现状**：每个元素一次 `cascade`（`f_svg/src/SvgStyleResolver.cj:237-400`）新建 `best`、`customBest`、`custom`、`values`、`sources`、`varExpressions` 六个容器，并调用 `element.elementPath()`（`240`）拼一条仅用于告警的路径串；`values` 再按 `SVG_PROPERTY_TABLE` 全量填 ~100 项。以 1 万元素文档估算，单次 `compute` 即 6 万个容器对象 + 1 万条路径串。
- **方案**：`elementPath` 改为惰性求值（只在真的要 `warnings.add` 时拼，或传入 `StringBuilder` 前缀）；`best`/`customBest` 用「每层复用 + `clear()`」的 scratch（注意 `clear()` 不归还容量，见 `mem §3.2`，应保留容量而不是反复扩容）；`values`/`sources` 直接构造进 `SvgComputedStyle`，不再先建 map 再拷贝。
- **预期**：每元素容器分配从 6 个降到 2-3 个；元素路径串分配降到 0（无告警时）。具体字节量需实测。
- **代价**：scratch 复用会让 `cascade` 不可重入（需保持每调用一份或线程封闭）；`elementPath` 惰性化会改变告警文本拼装位置。
- **验证**：同一 1 万元素文档 `cjpm bench -O2` 前后对照，取 `getAllocatedHeapSize()` 峰值与 GC 次数中位数（≥5 轮）。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] 计算样式全量存字符串，`values` 里大量值等于属性初值

- **现状**：`values[name] = normalized ?? spec.initial`（`f_svg/src/SvgStyleResolver.cj:373`）对 `SVG_PROPERTY_TABLE` 每个属性都存一条 `String` 引用，未使用的属性也占位；`custom` 属性还会把父元素全部自定义属性复制进每个后代的 `values`（`390-392`）。
- **方案**：`SvgComputedStyle` 改为「仅存与初值不同的项 + 初值表按属性名共享」，自定义属性改为沿 `parent` 链查找而不是复制。
- **预期**：单元素 `HashMap` 条目数从 ~100 降到实际使用数（典型文档 <20）；自定义属性不再按层数平方复制。
- **代价**：`get` 需要一次父链查找（深度 = DOM 深度），需要缓存或限制链长；`customProperties()` 语义变化需要同步文档。
- **验证**：`SvgComputedStyle` 实例的保留大小（`cjprof heap`）+ 多文档渲染的 RSS 稳态。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `getBBox` 每次调用新建 resolver 做整文档级联

- **现状**：`SvgElement.getBBox`（`f_svg/src/SvgElement.cj:455-471`）每次都 `SvgStyleResolver().compute(root, ...)`，即对整棵树重跑级联（含 `<style>` 收集与选择器匹配）。若调用方对 n 个元素逐个 `getBBox`，复杂度为 O(n²)。
- **方案**：提供 `SvgDocument` 级的样式缓存（或在 `SvgBBoxOptions` 里接受现成 `SvgComputedStyleTree`），`getBBox` 命中缓存时直接复用；`SvgSnapshotM5_test.elementApiSceneAssertions`（`SvgSnapshotM5_test.cj:177-185`）这种逐元素查询场景收益最直接。
- **预期**：n 次 `getBBox` 从 n 次全树级联降为 1 次；端到端收益取决于级联占比（未测）。
- **代价**：缓存需要失效策略（与上文 `prepare` 缺失效同源）；API 增加参数。
- **验证**：构造 5k 元素文档，循环 `getBBox` 5k 次，`cjprof record` 看 `cascade` 自耗时占比，`-O2` 前后中位数对照。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 圆角连接每顶点最多生成 256 边形，dash 每片段再分配点数组

- **现状**：`addJoin` 对 `Round`/`Arcs` 直接调用 `circlePolygonForStroke(..., 0.25)`（`f_svg/src/SvgStrokeOutliner.cj:318-320`），`circlePolygonForStroke` 的段数上限 256（`404-406`）；`dashPieces` 每片段 `current.toArray()`（`613`、`626`）再各分配一份点数组。
- **方案**：圆角连接的扇形只覆盖外角范围（按 `dot`/`cross` 求夹角，而不是整圆）；dash 片段直接以「点区间」形式传给 `outlineOne`，避免 `toArray` 复制。
- **预期**：折线每顶点点数从 ≤256 降到与夹角成正比（直角连接约 1/4 圆周）；dash 场景减少一次整段复制。
- **代价**：扇形起止角计算与 `sign` 判定共用同一套法线逻辑，回归风险集中在 join 视觉；需要逐元素快照对照（`SvgSceneByteBaseline_test` 容差 0 会直接暴露差异）。
- **验证**：`cjpm bench -O2` 对「多顶点折线 + round join」与「长虚线路径」两组输入，记录轮廓点数、总耗时中位数与峰值内存。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

> 无性能数据支撑，不进 `todo.md` / `tasks.md`，仅用于下一轮补数据。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `cascade` 的容器分配占渲染总 CPU 的显著比例 | `f_svg/src/SvgStyleResolver.cj:237` | `cascade` 自耗时占比、分配量 | `cjprof record` 渲染 1 万元素文档，看 `cascade`/`normalizeValue` self time 与 `cjprof heap` 分配 |
| 2 | 逐元素 `getBBox` 触发的整树级联是 O(n²) 热点 | `f_svg/src/SvgElement.cj:461` | 端到端耗时随 n 的曲线 | 5k 元素文档循环 `getBBox` 5k 次，分段计时 + `cjprof` |
| 3 | round/arcs 连接的整圆多边形是描边路径主要开销 | `f_svg/src/SvgStrokeOutliner.cj:319` | 轮廓点数与耗时占比 | 生成 1 万顶点 round-join 折线，统计 `outlineContours` 返回点数与耗时 |
| 4 | 计算样式全量字符串使单文档常驻内存偏高 | `f_svg/src/SvgStyleResolver.cj:373` | `SvgComputedStyle` 保留大小 | `cjprof heap` 对比 1 万元素文档 compute 前后的 heapUsed 与对象数 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_svg/src/SvgRoundTripM4_test.cj` | .cj | ✅ | M4 滤镜往返用例，未发现缺陷 |
| 2 | `f_svg/src/SvgRoundTrip_test.cj` | .cj | ✅ | 见发现「测试用例与阈值」#4 |
| 3 | `f_svg/src/SvgSceneM4_test.cj` | .cj | ✅ | 4 个场景快照，容差 1，未发现缺陷 |
| 4 | `f_svg/src/SvgScene_test.cj` | .cj | ✅ | `SCENE_DIR` 与 M5 测试常量重复（F15） |
| 5 | `f_svg/src/SvgSecurity_test.cj` | .cj | ✅ | 安全策略覆盖充分；1M 元素用例见 F15 |
| 6 | `f_svg/src/SvgSet.cj` | .cj | ✅ | `<set>` 类型化属性；仅 authoring builder 使用（解析路径按通用元素处理），非缺陷 |
| 7 | `f_svg/src/SvgShape.cj` | .cj | ✅ | 13 个 `SvgValueCache` 属性；枚举 `toString` 不一致（F12） |
| 8 | `f_svg/src/SvgShape_test.cj` | .cj | ✅ | 属性读写用例，覆盖 `none`/非法值 |
| 9 | `f_svg/src/SvgSnapshotM5_test.cj` | .cj | ✅ | M5 快照辅助函数；常量见 F15 |
| 10 | `f_svg/src/SvgSnapshotM6_test.cj` | .cj | ✅ | 用例复制 M5（F15） |
| 11 | `f_svg/src/SvgStop.cj` | .cj | ✅ | `offset` 归一 0..1、`currentColor` 保留原文，未发现缺陷 |
| 12 | `f_svg/src/SvgStrokeOutliner.cj` | .cj | ✅ | dash 无上限（F1）、解析路径语义漂移（F6）、F9/F10/F13/F14 |
| 13 | `f_svg/src/SvgStrokeOutliner_test.cj` | .cj | ✅ | 端点/连接/dash/解析路径对照，未发现缺陷 |
| 14 | `f_svg/src/SvgStyleResolver.cj` | .cj | ✅ | 级联主体；F2 / F3 / F4 / F5 / F7 / F8 |
| 15 | `f_svg/src/SvgStyleResolverM4_test.cj` | .cj | ✅ | clip/overflow/baseline-shift 归一用例 |
| 16 | `f_svg/src/SvgStyleResolverM6_test.cj` | .cj | ✅ | 交互状态级联用例 |
| 17 | `f_svg/src/SvgSvg2M6_test.cj` | .cj | ✅ | `vector-effect`/`miter-clip`/auto 尺寸用例 |
| 18 | `f_svg/src/SvgSwitch.cj` | .cj | ✅ | 条件求值只读；`splitSwitchTokens` 与 `splitSvgListTokens` 严格度不同，属有意差异，未判重复 |
| 19 | `f_svg/src/SvgTag.cj` | .cj | ✅ | 双份标签表（F11） |
| 20 | `f_svg/src/SvgText.cj` | .cj | ✅ | 3 行包装类，未发现缺陷 |

合计：`.cj` 20 个 / `.md` 0 个 / 共 20 个，全部读完（本部分清单不含 `.md`，故无 §13 文档一致性条目）。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 8 | 正确性 F2（规范偏差）/ F6（同类 API 语义漂移）；诊断静默 F3；缓存失效 F4；告警契约不一致 F5；可读性 F11 / F12；接线 F14。安全性：转义/注入不在本部分文件（解析器与 writer 不在清单内），本部分仅 `normalizePaint` 的外部引用降级（`SvgStyleResolver.cj:900-911`）已核对为安全 |
| §1 死代码 | 2 | 逐个核对了本部分 8 个生产文件的全部 `private` / `internal` 符号（`grep -w` 全仓、排除 `.worktrees`）：`appendAll`/`isValidDash`/`outlineOne`/`removeDuplicatePoints`/`distanceSquared`/`addCap`/`addJoin`/`addContour`/`ensurePositiveOrientation`/`signedArea`/`clampUnitForStroke`/`ellipsePolygonForStroke`/`rectOutline`/`reverseContour`/`circleOutline`/`dashPieces`/`expandCustomValue`/`cssCalcAppliesTo`/`resolveFontRelativeLength`/`considerCssCandidate`/`originSource`/`resolveCssKeyword`/`collectCssStyleTexts`/`normalizeSvgTextDecorationShorthand`/`svgJoinWords`/`clampSvgUnit`/`tryParseSvgOffset`/`isKnownFeature`/`splitSwitchTokens`/`languageMatches`/`read*`/`write*`/`formatSvgLengthList`/`splitSvgListTokens`/`tryParseSvgPointList`/`readPointList` 均有调用点；`protected` 在本部分只有 `SvgShape.cj:160` 一处 `init`（所属 `public abstract class SvgShape`，非 `sealed`）按硬原则豁免；`public` 成员均为对外可达契约，不判死代码。命中 2 处不可达分支（F8 / F9） |
| §2 重复逻辑 | 4 | 同文件两两比对（8 个生产文件内全部函数体压成「输入→输出→副作用」摘要后比对）：F10 两组（`ensurePositiveOrientation`/`reverseContour`、`outlineContours`/`outlinePolyline`）；跨文件字面量：F11（`SvgTag` 双表）、F2（`cssCalcPercentReference` 与 `toUserUnits` 的换算复制）、F15（测试常量与用例复制）。`splitSwitchTokens`（`SvgSwitch.cj:119`）与 `splitSvgListTokens`（`SvgShape.cj:448`）严格度不同（前者容忍双逗号并过滤空项，后者拒绝），属有意差异，未判重复 |
| §3 空实现 | 0 | 本部分 grep `TODO|FIXME|XXX|UnsupportedException` 零命中；无空函数体；`SvgText` 仅包装构造、`SvgValueCache` 之外无「默认空实现」接口；两处 `catch`（`SvgShape.cj:384`、`392`）均为「解析失败 → `None`」的显式降级，非静默吞异常 |
| §4 栈溢出 | 0 | 递归只有两处：`computeSubtree`（`SvgStyleResolver.cj:143-156`）与 `collectCssStyleTexts`（`1016-1026`），深度等于 DOM 深度，由解析期 `maxDepth`（默认 512，`SvgSecurity_test.cj:259-268` 断言）与 `maxElements` 约束；`SvgStrokeOutliner` 的 `dashPieces`/`outlineOne` 均为迭代。未发现可证明的无界递归，故本部分不单列（编程构造的超深树在解析/序列化路径同样先受限） |
| §5 OOM | 2 | dash 片段数无上限（F1）、resolver 三个无界缓存（F3）。`SvgStyleResolver` 的 `mergedRules`/`mergedFontFaces` 每次 `prepare` 覆盖，非只增 |
| §6.1 热点瓶颈 | 0 | 本部分无 `cjprof` / `bench` 数据，任何「此处慢」都没有自耗时占比，已全部降级为「待验证假设」表第 1-4 条 |
| §6.2 大粒度锁 | 0 | 本部分无锁、无 `synchronized`，不存在临界区 |
| §6.3 并发串行 | 0 | 本部分无 `spawn` / `Future.get`，无线程池与队列 |
| §6.4 低效算法 | 1 | dash 循环次数由 `路径长度 / dash 周期` 决定（F1）；`SvgSwitch.isKnownFeature`（`109-116`）为 17 项线性扫描，输入是常量表，未达热点门槛 |
| §7 降堆内存方案 | 2 | 见「优化可行性方案」前两条，均 `无基线（待验证）` |
| §8 降 CPU 方案 | 2 | 见「优化可行性方案」后两条，均 `无基线（待验证）` |
| §9 local mode 可行性 | 0 | `f_svg` 已整体开启 local mode（`f_svg/README.md`「编译期要求」），本部分候选是 `cascade` 的临时 map，但无「改前/改后峰值内存」数据，且 `HashMap` 是否具备 mode 重载未核对 ⇒ 只可能写进待验证假设，本部分未命中 |
| §11 现有代码的 BUG（存量） | 15 | 本部分 15 条发现全部为存量（工作区无改动、无 diff）。边界核对：`removeDuplicatePoints` 空输入、`clean.size == 1`、`signedArea` 空数组、`dashPieces` 全零 dash、`outlineOne` 非闭合路径首尾帽、`tryParseSvgOffset` 空串均已逐条走查；`dashPieces` 的片段数无上限是其中唯一会导致资源耗尽的边界 |
| §12 并发安全与锁粒度 | 1 | `SvgStyleResolver` 可变字段无同步（F7）；`SvgSwitch`（纯静态）、`SvgTag`（纯静态）、`SvgStrokeOutliner`（静态纯函数，`SvgStrokeStyle.dashArray` 只读）线程封闭；`SvgValueCache`（`SvgElement.cj:28-41`）非原子，但所属 DOM 本身是可写结构，按「DOM 非线程安全」处理，未单列 |
| §14 功能完备性与 README 覆盖 | 1 | `outlineElement` 解析路径未接线（F14）；本部分无 `.md`，README 覆盖核对留给含 README 的部分，此处只按 `src/` 公开声明对照调用图 |
| 文件覆盖（§13 等） | 20/20 | 清单 20 个文件全部读完，无遗漏；本部分不含 `.md`，§13 无适用对象 |

## 模块统计（本部分）

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 1 |
| 一般 | 6 |
| 轻微 | 8 |
| 优化方案（堆内存 / CPU） | 2 / 2 |

## 总评

本部分覆盖 `f_svg` 的样式级联、描边轮廓化、形状属性与 `switch`/`tag` 分派，整体结构清楚：`SvgStyleResolver` 的级联键 `(important, origin, specificity, order)` 明确，非法值统一「告警 + 回退」而不是抛异常，安全相关的 `normalizePaint` 对 `Security` 类错误按 `none` 降级，`SvgShape` 的 13 个属性全部走 `SvgValueCache` 且与 `attributesVersion` 绑定，测试覆盖了端点/连接/dash/解析路径对照与逐字节快照。

阻塞项只有一个：`dashPieces` 的片段数完全由文档控制且无任何上限，`stroke-dasharray="0.0001"` 或 `pathLength` 放大即可让渲染在 CPU 与内存上失控，这是继脚本/外部引用过滤之后的又一条不可信输入面，建议优先修。

需要排期的是四条契约类问题：`calc()` 百分比对 `r` 用了算术平均（与 spec 与既有 `toUserUnits` 不一致）、`SvgStyleResolver` 三个缓存跨调用无界且会让诊断静默消失、`prepare` 只按根 identity 缓存导致文档变更后返回旧规则、`computeElement` 与 `compute` 的告警语义不一致。`outlineElement` 的解析快路径与通用 outliner 语义漂移（dash/圆角/百分比）目前只影响直接调用该公开 API 的使用方，因为渲染器走的是 `outlineContours`。

死代码与重复逻辑已机械过完：无「无引用的非 public 符号」，命中的是 2 处不可达分支与 4 组同语义实现（反转轮廓、dash 分支、标签双表、换算复制），另有测试套件内的用例与常量复制。性能方面本轮没有任何 profile/bench 数据，所有热点线索（`cascade` 分配、`getBBox` 的 O(n²)、round join 多边形、计算样式全量字符串）都只写进「待验证假设」与「优化可行性方案（无基线）」，未进修复清单。

存量 15 条（含 1 条严重），是否纳入修复待用户决定。
