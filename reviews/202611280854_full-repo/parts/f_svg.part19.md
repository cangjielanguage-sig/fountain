# f_svg 模块审查报告（第 19/26 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_svg`（本部分 17 个源文件，全部 `.cj`）
- **本部分范围**：`SvgPaintOrder` / `SvgParser` / `SvgPath` / `SvgPathData` / `SvgPathLength` / `SvgPathMeasure` / `SvgPattern` / `SvgPatternSampler` 及其 9 个测试文件
- **基线**：工作区快照（`git rev-parse HEAD` = `f309f0b5`，`git status` 显示 `f_svg/` 无未提交改动；dispatch 记载的基线提交为 `120fd2542`，本部分结论按当前工作区取，来源统一记「存量」）
- **审查重点**：SVG/XML 解析与序列化边界、注入与转义、递归与栈溢出、OOM、死代码、重复逻辑
- **报告版本**：v1（第 19 部分，仅统计本部分）

## 发现

### [严重][存量] pattern tile 缓存无会话级上限，峰值内存随「元素数 × 单 tile 上限」增长

- **位置**：`f_svg/src/SvgPatternSampler.cj:93`（`private let cache = HashMap<String, SvgPatternTile>()`）、`f_svg/src/SvgPatternSampler.cj:178`（key = `pattern.identity + objectBounds`）、`f_svg/src/SvgPatternSampler.cj:330`（`this.cache[key] = tile`）
- **来源**：存量（快照模式无基线；`git log -1 -- SvgPatternSampler.cj` = `985801390`，早于本轮快照）
- **判据**：review-checklist §5（无界容器 / 无拒绝路径）
- **证据**：静态确定 —— 缓存只有 `cache.clear()`（`SvgPatternSampler.cj:161`，仅在非会话模式、每次公开 `sample` 入口）与「渲染结束对象被回收」两个出口，**没有任何条目数或总像素上限**；单 tile 上限只限制**一枚** tile（`SvgPatternSampler.cj:229-244`，≤ `SVG_MAX_PATTERN_TILE_PIXELS` = 4 Mi 像素 = 16 MiB RGBA）。而 key 含 `objectBounds`，同一 pattern 被 N 个包围盒不同的图元引用就产生 N 条互不复用的条目。
- **描述**：`SvgRenderer.renderDisplayList` 在整次渲染中复用一个 `SvgPatternSampler`（`f_svg/src/SvgRenderer.cj:138-139`），`sampleTile` 用 `command.bounds`（`SvgRenderer.cj:591-592`）作 key 的一部分。攻击者可控输入：一个 `<pattern width="2000" height="2000">`（4 Mi 像素，正好在上限内）+ 1000 个位置/尺寸各不相同的 `rect` 共用该 pattern ⇒ 1000 枚 16 MiB tile 同时常驻 ≈ 16 GiB，且这些 tile 在对应图元绘制完后已无用途。`SvgRenderOptions.validatePixels` 只约束输出画布，`SvgDecodeBudget` 只约束图片解码，pattern tile 没有任何预算。
- **建议**：给 sampler 增加会话级 tile 预算（复用 `SvgDecodeBudget` 或新增 `SVG_MAX_PATTERN_TILES_TOTAL_PIXELS`），超限时按 LRU 淘汰或直接降级为 `None` + warning；若能证明多数 pattern 的内容映射与 `objectBounds` 无关（`patternContentUnits=userSpaceOnUse` 且无 `viewBox` 时成立），可把 key 收窄为 `pattern.identity`，从根上消除按包围盒生成条目的放大。

### [一般][存量] pattern 子内容出现任何 warning 即整体丢弃，与其他渲染路径的 warning 语义不一致

- **位置**：`f_svg/src/SvgPatternSampler.cj:293-298`、`f_svg/src/SvgPatternSampler.cj:305-310`
- **来源**：存量
- **判据**：review-checklist §11（错误处理不对称 / 语义与注释不符）+ §14.1（只做了一半的分支）
- **证据**：静态确定 —— `buildContent` / `renderDisplayList` 返回后判断 `if (warnings.size > 0) { ...; return None }`，即把「有警告」等同于「渲染失败」；同文件 `SvgRenderTree.cj` 产生的警告包括良性项：`"已跳过不支持的元素「${element.tag}」"`（`SvgRenderTree.cj:647`）、`"<image> 缺少 href，使用占位矩形"`（`SvgRenderTree.cj:1396`）、`"use 引用目标「${targetId}」不存在"`（`SvgRenderTree.cj:1002`）。
- **描述**：pattern 内容里出现一个 `<animate>`、一个缺 `href` 的 `<image>`、或任一 `use` 悬空引用，整块 pattern 填充就变成不绘制（返回 `None`），而同文档主渲染路径对同类警告是「跳过该元素、继续画别的」。结果：图案区域整片消失，且与主画布的降级策略相反，使用者很难从 warning 文本判断「为什么图案没了」。
- **建议**：区分致命与良性 warning（例如 builder/renderer 返回 `errors` 与 `warnings` 两个列表，或只在 `SvgErrorKind` 级失败时返回 `None`）；至少把「已跳过不支持的元素」「占位矩形」这类计入 warning 但不中止 tile。

### [一般][存量] `resolveAxis` / `resolveOrigin` 自实现长度换算，漏掉绝对单位与 `em`/`ex`

- **位置**：`f_svg/src/SvgPatternSampler.cj:390-410`（`resolveAxis`）、`f_svg/src/SvgPatternSampler.cj:412-433`（`resolveOrigin`）
- **来源**：存量
- **判据**：review-checklist §11（契约与实现不符）+ §2（重复逻辑导致行为漂移）
- **证据**：静态确定 —— 两个函数只区分 `Percent` 与「其他」，`em`/`ex`/`in`/`cm`/`mm`/`pt`/`pc` 一律按裸数值使用；而模块已有 `public func toUserUnits(length, axis, context)`（`f_svg/src/SvgLength.cj:205-227`）覆盖 `In/Cm/Mm/Pt/Pc/Em/Ex/Percent` 全部单位，且 `toUserUnits` 在本模块被 19 处调用。
- **描述**：`patternUnits="userSpaceOnUse"` 且 `width="1in"` 时，tile 宽度被算成 1 用户单位（按 96dpi 应为 96），`width="2em"` 时为 2 而非 `2 × fontSize`。该偏差同时是「同一换算在两处实现」的直接后果：一处修了单位，另一处不会跟着修。
- **建议**：`resolveAxis` / `resolveOrigin` 改调 `toUserUnits`，`Percent` 的基准按 `objectBoundingBox`/视口分别构造 `SvgLengthContext`；`objectBoundingBox` 语义（数值即 bbox 比例）用单独的 `SvgLengthAxis`/基准表达，避免再次分叉。

### [一般][存量] `SvgPattern` 的 9 个 typed prop 在 `src/` 内零调用，取样器另走一套 attr 字符串解析

- **位置**：`f_svg/src/SvgPattern.cj:38-72`（`x`/`y`/`width`/`height`）、`74-106`（`patternUnits`/`patternContentUnits`）、`108-126`（`patternTransform`）、`138-156`（`viewBox`）、`158-173`（`preserveAspectRatio`）；对应平行实现见 `f_svg/src/SvgPatternSampler.cj:214-221`、`268-271`、`314-317`、`449-488`
- **来源**：存量
- **判据**：review-checklist §2（跨层复制 / 换算复制）
- **证据**：静态确定 —— 全仓 grep：`patternUnits` / `patternContentUnits` / `patternTransform` / `viewBox` / `preserveAspectRatio` 在 `src/` 内除 `SvgPattern.cj` 定义处外**没有任何读取点**（`SvgPatternSampler.cj` 读的是 `effectiveAttr(chain, "patternUnits")`、`attr("patternTransform")` 等原始字符串），仅 `*_test.cj` 使用这些 prop。
- **描述**：同一份属性存在两条解析路径：`SvgPattern` 的 prop（`SvgValueCache` + `SvgCoordinateUnits.fromName` / `tryParseSvgTransform` / `tryParseSvgViewBox`）与 sampler 的链式 attr 解析 + 自建换算。上面第 3 条已发生实质漂移（`em`/绝对单位）。另外 prop 侧有 `attributesVersion` 缓存，sampler 侧每次 `sampleTileUncached` 重新 `tryParse` 一遍（`resolveLength` / `effectiveTransform` / `effectiveViewBox` / `effectiveAspect`），缓存价值被绕过。
- **建议**：把「href 继承链 + 首个可解析值」抽成一个泛型链式查找（见优化方案 O3），链首元素直接复用 `SvgPattern` 的 typed prop；只在需要继承时才回落到 attr 解析，并让两处共用同一换算函数。

### [一般][存量] `findPatternById` 递归遍历 DOM，深度上界 4096，与 `f_xml` 的「不递归」约定相反

- **位置**：`f_svg/src/SvgPatternSampler.cj:499-521`
- **来源**：存量
- **判据**：review-checklist §4（无界递归 / 深度由输入决定）
- **证据**：静态确定 —— 每个 `ElementNode` 递归一次，无深度计数、无显式栈；可达深度上界由 `XmlParserOptions.maxElementDepth` 决定，默认 **4096**（`f_xml/src/XmlOptions.cj:136,146`），`SvgParseOptions` 未覆盖该值。对照 `f_xml` 自己的约定：「深度由解析引擎的 `maxElementDepth` 把关，这里不再递归，不会栈溢出」（`f_xml/src/DomBuilder.cj:27`）——即 4096 层被认为是**不能安全递归**的深度。调用点 `f_svg/src/SvgRenderer.cj:588` 在每次 pattern 填充时都走一遍全树搜索。
- **描述**：一个 4096 层嵌套的合法 SVG（在 `maxElements` 上限内，元素数只需 ~8k）即可让 `findPatternById` 压入 4096 层栈帧；每层还有 `match`/局部变量与两次 `for` 迭代，是否越界取决于平台栈大小与单帧大小（未实测）。同文件另一处 `SvgRenderTreeBuilder` 的引用展开已有 `SVG_MAX_REFERENCE_DEPTH` 与 `SvgRenderGuard` 保护，说明「递归深度必须显式设限」是本模块既有基线，此处是遗漏。
- **建议**：改为显式栈迭代（`ArrayList<SvgElement>` 待访问队列 + `HashSet<Int64>` 去重），或先构建一次 `id → element` 索引供 `findPatternById` / `findSvgElementById` / `resolveChain` 共用（同时消除每次填充 O(元素数) 的全树扫描）。

### [一般][存量] `SvgPath.d` 的 setter 经 `toString()` 回写，6 位小数与 `|v|<1e-6` 归零导致丢精度

- **位置**：`f_svg/src/SvgPath.cj:43-61`（`set` 分支 `SvgPath.cj:57`）；序列化侧 `f_svg/src/SvgPathData.cj:296-305` → `formatSvgNumber`（`f_svg/src/SvgNumber.cj:32-49`）
- **来源**：存量
- **判据**：review-checklist §11（语义与注释不符 / 数据丢失）
- **证据**：静态确定 —— `set` 只做 `this.setAttr("d", data.toString())`，`get` 再 `SvgPathData.tryParse`；`formatSvgNumber` 把非整数裁到 6 位小数、`|v| < 1e-6` 直接输出 `"0"`。本模块测试已把该行为固定为已知边界：`SvgPathData_test.cj:196-204`（`M0.1234567` → `M 0.123457`，且 `parse(toString(x)) != x`）。`SvgLength` 的文档明确声明了这条「已声明的不保真边界」（`f_svg/src/SvgLength.cj:86-87`），而 `SvgPath.d` 的文档（`SvgPath.cj:43` 前后）没有声明。
- **描述**：`SvgPath(d: data)` 与 `path.d = data` 都会把内存中的数据降精度后重新解析，`path.d` 读回的不是传入对象；`d` 中坐标量级 < 1e-6 的部分会被吸成 0（例如把 1e-3 比例的局部坐标图形平移后写回）。解析外部 SVG 不受影响（原本就是文本），受影响的是**程序化构造/编辑**路径，属于静默数据损失而非崩溃。
- **建议**：二选一 —— ①在 `d` prop 文档与 `SvgPath.init(d:)` 注释里显式声明「写回按 6 位小数规范化」；②`SvgPath` 直接缓存传入的 `SvgPathData` 对象（`attributesVersion` 不变时优先用对象，文本仅作序列化视图），把丢精度限制在 `toString()` 这一条明示边界上。同类 setter（`patternTransform`、`viewBox`、`preserveAspectRatio`）应按同一结论统一处理。

### [轻微][存量] `toAbsolute` 对绝对命令直接复用入参 `Array`，产生跨对象别名

- **位置**：`f_svg/src/SvgPathData.cj:235-241`、`244-250`、`253-259`、`262-268`（`else { command.values }` 分支）
- **来源**：存量
- **判据**：review-checklist §11（值/引用语义误用）
- **证据**：静态确定 —— `SvgPathCommand.values` 是 `Array<Float64>`（引用类型），绝对命令分支把同一个数组引用塞进新 `SvgPathCommand`，因此 `data` 与其 `toAbsolute()` 结果共享缓冲区；`SvgPathCommand` 是 struct，复制时数组仍共享。
- **描述**：调用方若原地改 `absolute.commands[i].values[0]`，原始 `data` 的对应命令同时被改（反之亦然）。当前仓内没有原地写入，故未触发；但 `commands` 是 `public let`，属对外可写面。
- **建议**：`toAbsolute` 统一 `command.values.clone()`（或文档声明返回结果与入参共享数组、不得原地修改）；更彻底的做法是把 `values` 暴露为只读视图。

### [轻微][存量] `pointAt` 的空段表回退写成「循环 + 立即 break」，实际只检查第一条命令

- **位置**：`f_svg/src/SvgPathMeasure.cj:153-159`
- **来源**：存量
- **判据**：review-checklist §1（不可达结构）/ §10（可读性）
- **证据**：静态确定 —— `for (command in path.commands) { if (...) { return ... } break }`，`break` 在同层无条件执行，第二圈永不进入；等价于 `if (commands.size > 0 && commands[0].kind == MoveTo && ...)`。
- **描述**：读者会以为在找「第一个 MoveTo」，实际只看第 0 条。当前语义（路径必须以 `M` 开头才有起点）与实现一致，故仅为可读性/误导问题；但若将来放宽「首命令可为 L/C」，此处会静默返回 (0,0)。
- **建议**：改写成显式 `if` 并注明「按规范首命令应为 MoveTo，否则起点视为 (0,0)」。

### [轻微][存量] tile 上限校验与告警文案重复

- **位置**：`f_svg/src/SvgPatternSampler.cj:229-236` 与 `239-244`（同一文案 `"pattern tile 像素数超过上限 ${SVG_MAX_PATTERN_TILE_PIXELS}"` 出现两次，两条 `throw` 结构相同）
- **来源**：存量
- **判据**：review-checklist §2（字面量复制 / 近似重复）
- **证据**：静态确定 —— 两处 `throw SvgException(..., kind: SvgErrorKind.Limit)` 只差触发条件（单轴超限 / 像素积超限），可合并为一次 `if (…|| pixelWidth * pixelHeight > MAX …)` 或抽 `limitError` 辅助。
- **描述**：文案与错误类别是契约的一部分，分散两处后改一处容易漏另一处（本模块其他地方已有 `limitError` 之类的统一入口，`SvgBuilder.cj:50`）。
- **建议**：合并为一个判据表达式 + 单条 `throw`；文案带 `tileWidth × tileHeight` 便于定位。

### [轻微][存量] `sample()` 的 `transform` 参数只做可逆性校验，不参与取样

- **位置**：`f_svg/src/SvgPatternSampler.cj:148-171`（`transform` 只在 `163` 行 `transform.invert().isNone()` 被使用）
- **来源**：存量
- **判据**：review-checklist §11（契约与实现不符）
- **证据**：待确认 —— 公开签名 `sample(pattern, objectBounds, transform, options)` 未写文档说明 `transform` 语义；实现中 tile 映射只用 `patternTransform` 的逆矩阵（`SvgPatternSampler.cj:314-321`）。仓内唯一调用方 `SvgRenderer` 走的是 `sampleTile`（不带 `transform`），测试全部传 `SvgMatrix.identity`，因此无法从仓内判断该参数是否应参与设备空间分辨率决策。
- **描述**：传非单位 `transform` 的调用方会得到与原样调用完全相同的 tile（仅多一次可逆性检查），若其期望「按 CTM 决定 tile 光栅分辨率/裁剪」则行为不符。
- **建议**：补文档说明「`transform` 仅用于拒绝不可逆变换，tile 始终在用户空间生成」，或让 `transform` 参与 `pixelWidth/pixelHeight` 的推导。

### [轻微][存量] `normalizeCssPaintOrder` 对同一字符串做两遍分词与大小写归一

- **位置**：`f_svg/src/SvgPaintOrder.cj:117-123`（先 `splitCssWhitespaceWords(text.toAsciiLower())`，再调 `SvgPaintOrder.parse(text, warnings)`，后者又 `text.trimAscii().toAsciiLower()` + 再分词，`SvgPaintOrder.cj:63`）
- **来源**：存量
- **判据**：review-checklist §6.4（同一输入重复解析）
- **证据**：静态确定 —— 每次 computed style 计算 `paint-order` 声明都分词/转小写两次，并在 `paintLayerFromName`（`SvgPaintOrder.cj:95`）中对每个 token 再做一次 `trimAscii().toAsciiLower()`（token 已是小写且无空白）。
- **描述**：纯冗余分配（每次 2 个 `Array<String>` + 每 token 1 个新 `String`），不影响正确性；CJK/ASCII 转小写走 `toAsciiLower`，无 locale 问题。
- **建议**：让 `parse` 接受已分词的 `Array<String>`（或让 `normalizeCssPaintOrder` 直接用 `tokens.size` 判空后调用一个内部 `build(tokens, warnings)`），`paintLayerFromName` 去掉多余的 trim/lower。

## 优化可行性方案

### [堆内存] `totalLength` 只累加长度，不物化整张段表

- **现状**：`SvgPathMeasure.totalLength`（`SvgPathMeasure.cj:105-112`）先 `buildSegments` 得到 `ArrayList<SvgMeasuredSegment>`，再只读最后一个元素的 `start + length`。单个 `SvgMeasuredSegment` 是 6 个 `Float64` + 对象头（≥ 64 B），段数约等于 `flattenPathData`（`SvgRasterizer.cj:498`）产出的折线顶点数；默认 `tolerance=0.25` 时 `refine=true` 会把容差压到 0.0125（`SvgPathMeasure.cj:74`），顶点数按「弧长 / 容差」量级增长。`buildSegments` 还先整份 `contours: Array<Array<SvgPoint>>` 再转段表，同一份几何存在两份副本。
- **方案**：为长度新增 `accumulate` 路径：遍历 `contours` 时只累加 `sqrt(dx²+dy²)`，不构造段；`pointAt` 才建段表（并可只保留「累计长度 + 端点」两列，去掉 `x0/y0` 冗余）。
- **预期**：`totalLength` 的临时对象从 O(顶点数) 降到 O(1)（除 flatten 自身的顶点数组外），段表峰值完全消失。
- **代价**：新增一个内部函数，`sample` 仍需完整段表；需保证两条路径的浮点累加顺序一致，否则 `getTotalLength()` 与 `getPointAtLength(total)` 的钳制边界会出现极微小差异。
- **验证**：`cjpm bench -O2` 跑长路径（≥ 10k 顶点）1000 次，对照 `getAllocatedHeapSize()` 峰值与 RSS；再用 `SvgElementApiM5_test.cj:177-183` 的等价性断言回归。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] pattern 失败结果做负缓存，并复用 builder / renderer

- **现状**：tile 只在成功时写缓存（`SvgPatternSampler.cj:330`）；`sampleTileUncached` 在 `293-298`、`305-310`、`223-228`、`209-211` 等分支返回 `None` 时不写任何记录，于是**每个引用该 pattern 的图元都会重新走一遍** `resolveChain` → `buildContent` → `renderDisplayList`。同时每枚 tile 都 `new SvgRenderTreeBuilder()` + `new SvgRenderer(...)`（`SvgPatternSampler.cj:283-304`）。
- **方案**：缓存 `?SvgPatternTile`（含 `None`），key 不变；把 builder/renderer 提升为 sampler 字段在会话内复用（注意 warning 列表需按次清空或改为 append-only 并记录起点）。
- **预期**：失败 tile 的重复构建次数从 O(N 图元) 降到 O(1)；成功路径省掉每 tile 一次对象图构建。
- **代价**：负缓存会掩盖「同一 pattern 因上下文不同而结果不同」的情形，需确认 tile 结果只依赖 `(pattern, bounds, options)`（当前 key 已如此假设）；复用 renderer 需确认其内部无跨 tile 状态。
- **验证**：构造一个 pattern 内含悬空 `clip-path` 的文档，复制 200 份图元，用 `cjprof record` 对照改前改后的 `buildContent` 自耗时与总时长（中位数 5 轮）。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 合并 5 处链式属性查找与 2 处长度换算，统一走 `toUserUnits`

- **现状**：`effectiveAttr`（`SvgPatternSampler.cj:380-388`）、`resolveLength`（`435-447`）、`effectiveTransform`（`449-461`）、`effectiveViewBox`（`462-474`）、`effectiveAspect`（`476-488`）是同一形状（按链取首个可解析值），`resolveAxis`/`resolveOrigin`（`390-433`）除最后一步合并方式外逐行相同；换算逻辑又是 `SvgLength.cj:205` `toUserUnits` 的子集。
- **方案**：一个 `firstParsed<T>(chain, name, parse: (String) -> ?T): ?T` 覆盖前 4 个；`resolveAxis`/`resolveOrigin` 合并为 `resolveLengthValue(chain, name, base, extent, objectUnits, axis, context)`，内部调 `toUserUnits`。
- **预期**：`SvgPatternSampler.cj` 减少约 90 行重复实现，源码与行为漂移面从 3 套收敛为 1 套（同时修掉上一个一般级发现的 `em`/绝对单位缺失）。
- **代价**：泛型 + 闭包会多一层间接调用（每 tile 十余次，量级可忽略）；`objectBoundingBox` 的「数值即比例」语义需在 `SvgLengthContext` 之外单独表达，避免误用百分比基准。
- **验证**：`cjpm test` 全量回归（`SvgPatternSampler_test` / `SvgPatternViewBoxM4_test` / `SvgPattern_test`）；性能用 `cjpm bench -O2` 对照 1000 枚 tile 的取样总时长。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 避免 `totalLength` 每次重建绝对命令表

- **现状**：`SvgPathMeasure.buildSegments` → `flattenPathData` → `data.toAbsolute()`（`SvgRasterizer.cj:500`），每次 `getTotalLength()` / `getPointAtLength()` 都为每条命令新建 `Array<Float64>`（`SvgPathData.cj:181-294`：`[x, y]` 字面量、`ArrayList` + `toArray()`），即使原路径全是绝对命令也要整份复制外壳。
- **方案**：`SvgPath` 已有 `dCache`（`SvgPath.cj:20`），再加一层 `absoluteCache`（同 `attributesVersion` 失效）；或 `toAbsolute` 对纯绝对路径直接返回 `this`（结构性共享，配合上一节「不得原地修改」的约定）。
- **预期**：重复量长度/取点时省掉 O(命令数) 的数组分配；对逐帧调用 `getPointAtLength` 的交互场景收益最明显。
- **代价**：`SvgPathData` 增加一份缓存（内存换 CPU，命令数 × 每条 values 大小）；共享 `this` 后若调用方原地改 `values` 会污染缓存，需与别名结论一起定契约。
- **验证**：1 万条命令的路径连续 10k 次 `totalLength()`，`cjprof` 看 `toAbsolute` 自耗时占比与分配量；改前改后中位数对照。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `buildSegments` 的 `contours → segments` 双份物化是 `getTotalLength` 的主要分配来源 | `f_svg/src/SvgPathMeasure.cj:75-102` | 分配量占比、峰值 RSS | 10k 顶点路径跑 1000 次，`getAllocatedHeapSize()` 前后差 + `cjprof heap` |
| 2 | pattern 失败 tile 的重复构建在「多图元共用 pattern」文档上是主要耗时 | `f_svg/src/SvgPatternSampler.cj:193-200, 283-310` | `buildContent` 自耗时占比 | 200 图元 + 1 个含悬空引用的 pattern，`cjprof record` |
| 3 | 每枚 tile 新建 `SvgRenderer`/`SvgRenderTreeBuilder` 带来可观的构造与预热成本 | `f_svg/src/SvgPatternSampler.cj:283-304` | 构造耗时、GC 次数 | 1000 枚 20×20 tile，分段计时 + GC 计数 |
| 4 | `findPatternById` 全树搜索在「pattern 多、元素多」文档上是 O(元素数 × 填充数) 热点 | `f_svg/src/SvgPatternSampler.cj:499-521`、调用点 `f_svg/src/SvgRenderer.cj:588` | 搜索自耗时占比 | 5k 元素 + 500 个 pattern 填充，`cjprof record` |
| 5 | `paint-order` 的双次分词在样式密集文档上占比可忽略（用于关闭该优化项） | `f_svg/src/SvgPaintOrder.cj:63,117-123` | 自耗时占比 | 1 万条声明跑 `SvgStyleResolver`，`cjprof` |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `src/SvgPaintOrder.cj` | .cj | ✅ | 见 §2/§6.4 轻微项 #11 |
| 2 | `src/SvgPaintOrderM5_test.cj` | .cj | ✅ | 测试，覆盖去重/未知关键字/大小写，与实现一致 |
| 3 | `src/SvgPaintOrderRenderM5_test.cj` | .cj | ✅ | 测试，paint-order 渲染层序断言完整 |
| 4 | `src/SvgPaint_test.cj` | .cj | ✅ | 测试（SvgPaint 定义不在本部分），外部引用拒绝用例齐全 |
| 5 | `src/SvgParser.cj` | .cj | ✅ | 五个入口 + `parseAuto`/`parseGzip`，异常包装正确；见总评范围外提示 |
| 6 | `src/SvgParser_test.cj` | .cj | ✅ | 五入口等价、命名空间、严格/宽松模式用例齐全；测试写 `target/` 文件未清理（轻微，仅测试） |
| 7 | `src/SvgPath.cj` | .cj | ✅ | 见 #6 一般项（`d` setter 丢精度） |
| 8 | `src/SvgPathBounds_test.cj` | .cj | ✅ | 测试，贝塞尔/弧/描边包围盒用例与 `SvgGeometry` 契约一致 |
| 9 | `src/SvgPathData.cj` | .cj | ✅ | 见 #7 轻微项（`values` 别名）、#1 死代码结论（`SvgArcParams` 仅测试构造，public 对外可达不判死代码） |
| 10 | `src/SvgPathData_test.cj` | .cj | ✅ | 词法/隐式重复/绝对化/精度边界齐全，精度边界为已声明不保真 |
| 11 | `src/SvgPathLength.cj` | .cj | ✅ | `ratio` 边界（非有限、≤0）处理完整；`actualLength` 非法时静默返回 1.0 无 warning（与 `declared` 分支不对称，未达问题门槛） |
| 12 | `src/SvgPathMeasure.cj` | .cj | ✅ | 见 #8 轻微项（`for+break`）；段表/容差语义与文档一致 |
| 13 | `src/SvgPattern.cj` | .cj | ✅ | 见 #4 一般项（typed prop 与 sampler 双轨） |
| 14 | `src/SvgPatternSampler.cj` | .cj | ✅ | 见 #1/#2/#3/#5 与优化方案 |
| 15 | `src/SvgPatternSampler_test.cj` | .cj | ✅ | 单位换算/继承/循环/上限/每调用 provider 用例齐全 |
| 16 | `src/SvgPatternViewBoxM4_test.cj` | .cj | ✅ | viewBox + preserveAspectRatio + patternTransform 合成用例齐全 |
| 17 | `src/SvgPattern_test.cj` | .cj | ✅ | 默认值与 href 往返用例，与实现一致 |

合计：`.cj` 17 个 / `.md` 0 个 / 共 17 个，全部读完（本部分清单无 `.md`）。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 6 | #3 单位换算漂移、#4 双轨解析、#6 写回丢精度、#7 数组别名、#8 伪循环、#10 `transform` 契约；安全性方面 SVG 外部引用拒绝在 `SvgPaint`/`SvgBuilder`（本部分外）实现，本部分未见注入面（pattern/sampler 只处理已解析元素，不做字符串拼接进输出） |
| §1 死代码 | 0 | 逐个搜过：`paintLayerFromName`/`normalizeCssPaintOrder`/`svgPaintOrderOf`/`containsPaintLayer`/`validateTolerance`/`maxInt64Pattern`/`clampPatternIndex`/`pathKind`/`absolutePairs`/`commandLetter`/`SvgPathScanner`/`findPatternById`/`attachSession`/`sampleTile`/`SVG_MAX_PATTERN_*` 均有调用者；`SvgPathMeasure`/`SvgMeasuredSegment`/`SvgMeasuredPoint` 被 `SvgPathData` 使用；`SvgArcParams` 仅测试构造但为顶层 public（对外可达）⇒ 按硬原则一不判死代码，只记「仓内 `src/` 无构造点」；`SvgPattern` 9 个 prop 同为 public，按硬原则一不判死，其「零 `src/` 读取」已作为 §2 双轨证据（#4）；未见 `return`/`throw` 后同层语句与恒真恒假分支 |
| §2 重复逻辑 | 3 | #3（长度换算重复实现且已漂移）、#4（typed prop vs attr 解析两套）、#9（tile 上限判定与文案复制）；另外逐对比对了 `SvgPaintOrder`/`SvgPathLength`/`SvgPathMeasure`/`SvgPatternSampler` 内 30 余个函数体的「输入-输出-副作用」，`resolveAxis`/`resolveOrigin` 同构已并入 #3 |
| §3 空实现 | 0 | 无空函数体；`SvgParser.loadXml` 只有 try/catch 包装且有返回；无 `TODO`/`FIXME`（grep 17 个文件 0 命中）；`sample` 对失败返回 `None` 均有 warning 或文档说明 |
| §4 栈溢出 | 1 | #5 `findPatternById` 递归深度上界 4096；其余递归均为常量上限（`subdivideCubic` depth ≤ 16、`resolveChain` 循环而非递归、pattern 嵌套受 `SvgRenderGuard`/`SVG_MAX_REFERENCE_DEPTH` 限制） |
| §5 OOM | 1 | #1 tile 缓存无总量上限（单 tile ≤ 16 MiB，条目数随输入增长）；`buildSegments` 段表属可回收临时对象，量化后只列入优化方案 |
| §6.1 热点瓶颈 | 0 | 本部分未提供 profile/bench 数据，所有热点线索（tile 重复构建、全树搜索、段表）已降级进「待验证假设」，未作缺陷 |
| §6.2 大粒度锁 | 0 | 本部分无锁、无 `synchronized` |
| §6.3 并发串行 | 0 | 本部分无 `spawn`/`Future`/线程池 |
| §6.4 低效算法 | 1 | #11 `paint-order` 双次分词/解析（每次 computed style）；`resolveChain` 的 `visited` 线性扫描受 `SVG_MAX_PATTERN_DEPTH=64` 限定，不构成问题 |
| §7 降堆内存方案 | 1 | O1（`totalLength` 不物化段表）；结论全部标 `无基线（待验证）` |
| §8 降 CPU 方案 | 3 | O2（负缓存 + 复用 builder/renderer）、O3（合并链式查找与换算）、O4（复用绝对命令表） |
| §9 local mode 可行性 | 0 | 本部分临时大对象（段表、tile 位图）都会逃逸或被缓存（tile 进 `cache`、段表跨 `sample` 调用），逃逸检查不通过；且 `f_svg` 未启用 local mode，`SvgBitmap.pixels` 为大块 `Array<Byte>`，收益需峰值内存对照才能证明，本轮无数据 |
| §11 现有代码的 BUG（存量） | 6 | #3/#4/#5/#6/#7/#10 均为存量缺陷（快照模式，`git status` 无 `f_svg` 改动）；本轮读到的 `SvgPathScanner` 词法边界（逗号、`Z` 后数字、弧标志、相对/重复命令、非有限数）逐个对照 `SvgPathData_test.cj` 用例复核，除上述各项外未再发现新缺陷 |
| §12 并发安全与锁粒度 | 0 | `SvgPatternSampler` 有可变状态（`cache`/`warnings`/`guard`/`images`）但类文档明确「实例生命周期为一次 render」（`SvgPatternSampler.cj:85-88`），仓内唯一使用方 `SvgRenderer.renderDisplayList` 每渲染新建一个（`SvgRenderer.cj:138`）⇒ 线程封闭；`SvgPaintOrder`/`SvgPathData` 构造后不可变；`SvgValueCache` 随元素走，元素本身非线程安全是模块既有约定，本部分无新增共享面 |
| §14 功能完备性与 README 覆盖 | 0 | 公开符号逐个对照 README：`SvgPaintOrder`(2)、`SvgPatternSampler`(1)、`SvgPathData`(4)、`SvgPathLength`(2)、`SvgParser`(10)、`parseAuto`(2)、`parseGzip`(1)、`SvgArcParams`(`README.md:574` 有字段说明) 均已登记；`SvgPathMeasure`/`SvgMeasuredSegment` 为 internal，无需文档；未发现「承诺但未实现」——`parseAuto`/`parseGzip` 入口均已接线并有测试 |
| 文件覆盖（§13 等） | 17/17 | 本部分清单 17 个文件全部 `.cj`，已逐个读完；无 `.md`，故 §13 文档一致性无对象，README 覆盖按 §14 抽查 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 1 |
| 一般 | 5 |
| 轻微 | 5 |
| 优化方案（堆内存 / CPU） | 1 / 3 |

存量缺陷 12 条（1 严重 + 5 一般 + 5 轻微，另 1 条为轻微范围内的契约待确认项已计入 #10），是否纳入修复待用户决定。

## 总评

本部分风险集中在 `SvgPatternSampler`：它是唯一同时持有跨元素缓存、递归 DOM 搜索与自建几何换算的类型，本轮 1 条严重（tile 缓存无总量上限）+ 3 条一般（warning 即丢弃整块内容、长度换算漏单位、typed prop 与 attr 解析双轨）全部落在这里。`SvgPathData` 的扫描器与 `toAbsolute` 质量较好：词法边界、隐式重复、弧标志、非有限数都有对应用例，未见解析崩溃面；`SvgPaintOrder` 语义符合 CSS `paint-order` 规范（缺省补齐、去重、未知关键字丢弃并告警）。

阻塞项：`pattern tile 缓存无上限`（可被单个恶意/超大文档触发到 GB 级常驻）。其余一般项可按模块排期：`warning 即丢弃` 与 `长度换算漏单位` 都是小改动但影响可见行为，建议与 pattern 相关的 M4/M5 回归一起做；`findPatternById` 递归建议与「建一次 id 索引」的重构合并（顺带解决 O(元素数 × 填充数) 的全树扫描）。

代码质量整体为「结构清楚、文档密度高、边界用例扎实」，主要债务是「同一语义多处实现」——pattern 的 typed prop / sampler 解析 / `toUserUnits` 三套并存，`paint-order` 的双次分词是同一类问题的轻量版。本部分所有性能结论均无基线，已按规则放入「待验证假设」与「优化可行性方案（无基线）」，未写入缺陷统计。

**范围外提示**（不计入本部分统计）：`f_svg/src/SvgGzip.cj:96` 仍留 `// TODO(M3-6): SvgParser.parseAuto / parseGzip 入口。`，这两个入口已在 `SvgParser.cj:71-92` 实现并有 `SvgGzip_test.cj` 覆盖，属过期 TODO，建议随该文件所属部分一并清理。`SvgParser_test.cj:113-133` 在 `target/` 下写临时文件且未删除，测试重复运行会残留文件（仅影响测试环境）。
