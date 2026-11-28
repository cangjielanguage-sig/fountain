# f_svg 模块审查报告（模块第 17/26 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_svg/src`（本部分 20 个源文件：命中测试 / 命中查询 / 交互状态 / 长度与插值 / 图像资源 / 元素属性样板 + 9 个测试文件）
- **基线**：工作区快照（`master` 与 `sts/1.3.x` 同一提交，`git diff` 为空）⇒ 本部分问题全部记「存量」
- **审查重点**：模块专项（SVG 解析 / 序列化边界、注入与转义、递归与栈溢出、OOM）为主，叠加本轮通用维度（死代码、重复逻辑、空实现、并发、存量 BUG）
- **报告版本**：v1（分部分报告，不写 `docs/review/` 下的模块报告）

## 发现

### [严重][存量] 命中查询系列 API 用元素局部 bbox 直接与根用户空间 rect 比较，忽略元素与祖先的 transform

- **位置**：`f_svg/src/SvgHitQueries.cj:79-94`（`svgHitQueryMatches`）；对照 `f_svg/src/SvgHitTest.cj:378-389`（`svgHitLocalPoint` 才做 CTM 求逆）
- **来源**：存量（`git blame` a061fe1ef5，2026-11-07）
- **判据**：review-checklist §11（契约与实现不符）/ §10 正确性
- **证据**：静态确定 —— `svgBBoxOf` 返回的是元素**自身用户空间**的盒子：`rectBounds` 只读 `x / y / width / height`（`f_svg/src/SvgGeometry.cj:281-299`），容器层才显式对每个子元素调用 `childBox.transform(svgChildTransform(child, …))` 应用**子元素**的变换（`f_svg/src/SvgElementApi.cj:150-170`），说明 bbox 本身不含自身与祖先变换。`svgHitQueryMatches` 把该盒子与 `rect`（规格上位于根用户空间）直接做 `intersect` / 包含比较，全程没有任何 `invert()`；同一模块的 `hitTest` 走 `SvgGeometry.ctm` + `ctm.invert()` 才正确。
- **描述**：任何带 `transform` 的元素（或位于带 `transform` 的 `<g>` / 嵌套 `<svg>` 内）在 `getIntersectionList` / `getEnclosureList` / `checkIntersection` / `checkEnclosure` 中位置全部错位。典型失败：`<g transform="translate(100,100)"><rect x="0" y="0" width="10" height="10"/></g>` 在 `(100,100,10,10)` 查询不到，反而在 `(0,0,10,10)`（实际什么都没画）报命中。`checkIntersection` 与 `checkEnclosure` 同样错。
- **建议**：查询路径与命中测试共用坐标处理——对每个候选元素求 `SvgGeometry.ctm(element, styles, viewport…)` 的逆，把 `rect` 变换到元素局部空间后再比 bbox（容器则按子元素的 CTM 逐层下推）；同时补 transform / 嵌套 `svg` 的用例，当前 `SvgDomApiM6_test.cj:214-251` 全部是无变换文档，所以这条一直没被覆盖。

### [一般][存量] 命中查询遍历不剪枝：定义容器与 `display:none` 子树内的元素仍被判为命中

- **位置**：`f_svg/src/SvgHitQueries.cj:50-63`（`svgHitQueryCollect`）；对照 `f_svg/src/SvgHitTest.cj:352-362`
- **来源**：存量（blame a061fe1ef5）
- **判据**：review-checklist §2（重复逻辑导致行为漂移）+ §11
- **证据**：静态确定 —— `svgHitQueryCollect` 对每个子节点无条件递归，只有 `svgBBoxOf` 在**容器自身**上按 tag 排除 `defs / mask / pattern / clipPath / linearGradient / …`（`f_svg/src/SvgElementApi.cj:124-127`），对其**子元素**没有任何祖先约束；`display` 不可继承（`f_svg/src/SvgComputedStyle.cj:98`），`display:none` 容器的子元素计算值仍是 `inline`，`svgBBoxOf` 会正常返回盒子；`computeSubtree` 遍历整棵树（`f_svg/src/SvgStyleResolver.cj:143-151`），所以 `styles.get(element)` 一定命中，不会被 `None` 分支挡掉。
- **描述**：`<defs><rect id="a" …/></defs>` 里的 `a`、`<mask>` / `<pattern>` / `<clipPath>` / `<symbol>` 内的图形、以及 `<g display="none">` 子树内的元素，都会出现在 `getIntersectionList` / `getEnclosureList` 结果里；同一批元素在 `SvgHitTest.hitTest` 中会被正确剪枝（`nonePrunesSubtree` 用例即验证这一点）。两个公开 API 对同一文档给出互斥结论。
- **建议**：把“是否进入子树”的判定抽成共用函数（`display == "none"`、`pointer-events == none`、定义容器 tag 列表），`svgHitQueryCollect` 与 `svgHitWalk` 都调用它；或让查询以回调形式复用 `svgHitWalk` 的遍历。

### [一般][存量] 命中查询以硬编码 300×150 求值样式与 bbox 请求，与文档实际视口无关

- **位置**：`f_svg/src/SvgHitQueries.cj:28`、`f_svg/src/SvgHitQueries.cj:46`（`mediaWidth: 300.0, mediaHeight: 150.0`）、`f_svg/src/SvgHitQueries.cj:79-84`（`viewportWidth: 300.0, viewportHeight: 150.0`）
- **来源**：存量（blame a061fe1ef5）
- **判据**：review-checklist §11（语义与实现不符/硬编码）
- **证据**：静态确定 —— `SvgHitTest` 同职责代码从根元素解析视口并按渲染选项覆盖（`f_svg/src/SvgHitTest.cj:306-315`，`SvgViewport.from` + `options.width/height`），查询路径则写死字面量。
- **描述**：`@media (min-width: …)` 的判定、嵌套 `<svg>` 的视口尺寸、`<use>` 的宽高基准、根 bbox 的 `(0,0,w,h)` 回退（`f_svg/src/SvgElementApi.cj:293`）全部按 300×150 计算。文档实际为 800×600 时，`getIntersectionList` 可能因媒体查询命中不同的 `display` / `pointer-events` / 填充规则而返回不同集合。
- **建议**：从 `SvgDocument` 侧推导视口（根 `width/height` 或 `viewBox`），或直接复用 `SvgViewportTransform.from(root, options:)`，并允许调用方传入视口；不要在库内部写文档尺寸常量。

### [一般][存量] 命中查询没有元素数上限，且对每个元素重算一次子树 bbox

- **位置**：`f_svg/src/SvgHitQueries.cj:33-35`、`f_svg/src/SvgHitQueries.cj:50-63`
- **来源**：存量（blame a061fe1ef5）
- **判据**：review-checklist §5 / §6.4（未受信输入无上限 + 复杂度）
- **证据**：静态确定（无计数器、无 `maxElements` 参数）——对照 `SvgHitTest` 有 `visited` 计数并在超限时抛 `SvgErrorKind.Limit`（`f_svg/src/SvgHitTest.cj:340-351`）。单次耗时占比属 `需实测`。
- **描述**：`svgHitQueryMatches` 对每个元素调用 `svgBBoxOf`，而容器 bbox 会递归自身整棵子树，一趟查询最坏是 `O(n×depth)`；`document.parseOptions.security.maxElements`（默认 1e6）只约束**解析**，查询侧完全不看，`display:none` / 定义容器又不剪枝，等于对不可信文档没有任何成本上界。`SvgDomApiM6_test.largeDocumentPerformance` 只用 1000 个扁平 `<rect>`，覆盖不到这条路径。
- **建议**：加 `maxElements!` 参数（默认取 `document.parseOptions.security.maxElements`），遍历计数超限抛 `SvgErrorKind.Limit`；容器 bbox 在同一趟遍历中自底向上累加，避免每个父节点重算子树。

### [一般][存量] 奇异 CTM 时命中测试退回未变换点，不可见元素被报命中

- **位置**：`f_svg/src/SvgHitTest.cj:385-388`（`svgHitLocalPoint` 的 `None` 分支）；同形态 `f_svg/src/SvgHitTest.cj:223-226`
- **来源**：存量（blame a061fe1ef5）
- **判据**：review-checklist §11（边界 / 退化输入）
- **证据**：静态确定 —— `SvgMatrix.invert()` 在 `|det| < SVG_INVERT_EPSILON` 时返回 `None`（`f_svg/src/SvgMatrix.cj:106-110`），此时 `svgHitLocalPoint` 直接把根空间点当局部点返回，`svgHitElementMatches` 继续用它做点内判定。
- **描述**：`<rect width="100" height="100" transform="scale(0)">` 实际零面积、不渲染，但 `hitTest(point:(50,50))` 会命中它（局部坐标恰好等于根坐标）。任何使行列式为 0 的 `transform`（`scale(0)`、`scale(0 1)`、`matrix(0 0 0 0 0 0)`）都成立。
- **建议**：`None` 分支直接判定「该元素及其子树无命中」（返回不入结果的信号），而不是回退原点；`elementsAt` 的根矩阵 `None` 分支同理应改为“无命中”。

### [一般][存量] `calcMode` 存在两套拼写映射且大小写行为不一致

- **位置**：`f_svg/src/SvgInterpolator.cj:39-46`（`toString` → `"Linear"`）、`f_svg/src/SvgInterpolator.cj:48-55`（`fromName`，`toAsciiLower` 大小写不敏感）；对照 `f_svg/src/SvgAnimate.cj:19-26`（`svgCalcModeAttrName` → `"linear"`）、`f_svg/src/SvgAnimate.cj:56-68`（`svgCalcModeFromName`，仅 `trimAscii`，大小写敏感）
- **来源**：存量（blame a061fe1ef5 / 同批枚举实现）
- **判据**：review-checklist §2（字面量复制的映射表 + 行为漂移）
- **证据**：静态确定 —— `animate.calcMode` 的 getter 走 `svgCalcModeFromName`，对 `calcMode="Linear"` 返回 `None`；而时间轴 `SvgTimeline.cj:538` 走 `SvgCalcMode.fromName`，同一个值被接受。`"${mode}"` 得到 `"Linear"`，写回属性即非法值（序列化用 `svgCalcModeAttrName`）。
- **描述**：同一个枚举有 2 张“枚举 ↔ 属性拼写”表、2 个解析入口，且对大小写的容忍度相反；除此之外 `SvgZoomAndPan` / `SvgImageRendering` 的 `toString` 都返回属性拼写，`SvgCalcMode.toString` 返回类型名，`SvgLengthUnit.toString` 又返回 `"Number"/"Percent"`（`f_svg/src/SvgLength.cj:50-63`）——三套约定并存。
- **建议**：保留 `svgCalcModeAttrName` / `svgCalcModeFromName` 作为唯一映射，`SvgCalcMode.toString` 改为委托它（或删除 ToString 实现），属性 getter 与时间轴统一用同一入口；`SvgLengthUnit` / `SvgCalcMode` 的 `toString` 语义在 README「已知 API 约定」中写清。

### [轻微][存量] 方形端点帽的角落区域不参与命中

- **位置**：`f_svg/src/SvgHitTest.cj:660-679`（两处 `svgDistanceToPoint(point, contour[…]) <= halfWidth` 附加条件），配合 `f_svg/src/SvgHitTest.cj:686-709`（`Square` 分支）
- **来源**：存量（blame a061fe1ef5）
- **判据**：review-checklist §11（与函数注释/几何定义不符）
- **证据**：静态确定 —— 该函数自述“`square` 用沿线延伸的半宽矩形”（`f_svg/src/SvgHitTest.cj:685`），`svgLineCapCoversPoint` 的 `Square` 分支也确实按 `along ∈ [0,hw] × across ∈ [0,hw]` 判定；但调用处额外要求 `distance ≤ halfWidth`，正方形四角距端点 `√2·hw`，被裁掉。
- **描述**：`stroke-linecap="square"` 的笔画末端四角处（占端点帽面积约 21%）判为未命中；`Round` 分支的同一条件恒真、`Butt` 分支返回 `false`，所以只有 `Square` 受影响。
- **建议**：把距离判定移进 `svgLineCapCoversPoint` 的 `Round` 分支，端点调用处只保留 `svgLineCapCoversPoint` 一个条件。

### [轻微][存量] 描边命中不含 join 区域

- **位置**：`f_svg/src/SvgHitTest.cj:638-683`（`svgPointNearContours`）
- **来源**：存量（blame a061fe1ef5）
- **判据**：review-checklist §11（实现与“描边区域”语义不符）
- **证据**：静态确定 —— 函数只遍历线段（`1..contour.size`）并补端点帽，没有任何 join 处理；同一模块的 `SvgStrokeOutliner.outlineContours` 是显式生成 join 轮廓的，两处对“描边覆盖区”的定义不同。
- **描述**：`stroke-linejoin="miter"` 的尖角（可伸出半宽以外）处点选会判未命中；`round` join 与端点圆盘近似重合，影响小。
- **建议**：若要求与渲染像素一致，可复用 `SvgStrokeOutliner` 的轮廓做点内判定；否则在 `hitTest` 文档注释中声明“join 区域按线段近似”。

### [轻微][存量] `elementsAt` / `elementAt` 静默丢弃命中过程产生的 warning

- **位置**：`f_svg/src/SvgHitTest.cj:227-237`
- **来源**：存量（blame a061fe1ef5）
- **判据**：review-checklist §3（静默吞掉诊断）/ §11
- **证据**：静态确定 —— 该调用传入临时 `ArrayList<String>()` 作为 `warnings`，`svgHitText` 的 “text 轮廓缺失，该元素不参与命中”（`f_svg/src/SvgHitTest.cj:520-522`）写进这个临时表后随调用返回被丢弃；实例方法 `hitTest` 则把同一批 warning 追加到 `this.warnings`（`f_svg/src/SvgHitTest.cj:181-183`）。
- **描述**：规格 API 与实例 API 的诊断能力不一致：调用方用 `elementsAt` 时无法得知“文本元素因缺字形轮廓被跳过”，只能看到命中数为 0。
- **建议**：给两个静态方法加 `warnings!` 出参（或返回 `(hits, warnings)` 结构），至少在注释中声明不产生诊断。

### [轻微][存量] `SvgLinearGradient` 的类型化坐标属性未参与渲染管线，坐标另有读取路径

- **位置**：`f_svg/src/SvgLinearGradient.cj:39-73`；对照 `f_svg/src/SvgGradient.cj:298-312`（`coordinate(chain, "x1", …)` 直接读 `attr`，并处理 `href` 继承与单位轴）
- **来源**：存量（blame a061fe1ef5）
- **判据**：review-checklist §2（同语义双实现）/ §1（对外可达 `public` 记信息）
- **证据**：静态确定 —— 全仓搜索 `gradient.x1 / x2 / y1 / y2` 无业务使用，仅构造器赋值；`SvgLinearGradient` 是 public 类、属性对外可达，按硬原则一**不判死代码**。
- **描述**：属性只做“字符串 ↔ `SvgLength`”转换，不解析 `href` 继承；渲染实际用 `SvgGradient.coordinate`。两套读法一旦对默认值/单位处理产生分歧（例如 `x1="50%"`），属性侧读到的是原始 `SvgLength`、渲染侧读的是按轴换算后的值，使用者按属性做校验会得到与渲染不同的结论。
- **建议**：让 `SvgGradient.coordinate` 在无 `href` 继承时复用同名属性，或反之把属性标注为“仅作者侧读写、不参与继承解析”，避免两套语义并存。

### [轻微][存量] `SvgHitTest.warnings` 跨调用只增、无 reset 契约

- **位置**：`f_svg/src/SvgHitTest.cj:143`、`f_svg/src/SvgHitTest.cj:181-183`
- **来源**：存量（blame a061fe1ef5）
- **判据**：review-checklist §7（生命周期）/ §12.1（`ArrayList` 无同步）
- **证据**：静态确定 —— 每次 `hitTest` 追加、从不清空，也没有 `reset` 方法；`ArrayList` 本身不保证并发写安全。
- **描述**：长生命周期实例（如服务内复用一个 `SvgHitTest`）在反复失败路径上线性增长，且不同次调用的 warning 混在一起难以归因；多线程共用一个实例时是数据竞争。与 `SvgRenderer.warnings` 属同一约定，因此只记为轻微。
- **建议**：提供 `resetWarnings()`，或在类注释中写明“单次使用、调用方负责 `warnings.clear()`”；如需跨线程复用，标注为“非线程安全”。

### [轻微][存量] 未使用的 import

- **位置**：`f_svg/src/SvgInterpolator.cj:20`、`f_svg/src/SvgLength.cj:19`（`import fountain::f_base.*`）；`f_svg/src/SvgInitialViewM6_test.cj:18`、`f_svg/src/SvgLineJoinM6_test.cj:18`、`f_svg/src/SvgLimitsM3_test.cj:18`、`f_svg/src/SvgImageResource_test.cj:18`（`import std.collection.*`）
- **来源**：存量（blame a061fe1ef5）
- **判据**：review-checklist §1（未使用的 import）
- **证据**：待确认 —— 编译器不报未使用 import（README 称 0 warning），按符号枚举判定：`SvgInterpolator.cj` / `SvgLength.cj` 内无任何 `f_base` 顶层符号或扩展方法名（`toInt` / `numberOfLeadingZeros` / `stringJoin` / `trimAsciiBlanks` / `replaceFirst` / `isEven` 等）出现；4 个测试文件内无 `ArrayList` / `HashMap` / `HashSet` 使用。
- **描述**：多余的依赖声明会误导“该文件依赖 f_base”，也掩盖真实的模块边界。
- **建议**：删除上述 6 处 import；若不删，请在 `f_svg/README.md` 说明为何统一引入 `f_base`。

### [轻微][存量] `SvgLength` 构造不校验有限性，`toString()` 会抛异常；与 `parse` 的契约不对称

- **位置**：`f_svg/src/SvgLength.cj:93-96`（`init`）、`f_svg/src/SvgLength.cj:127-129`（`toString`）；抛点 `f_svg/src/SvgNumber.cj:32-35`
- **来源**：存量（blame a061fe1ef5）
- **判据**：review-checklist §11（契约与注释不符）
- **证据**：静态确定 —— 类注释只承诺“`toString` 输出规范形式”“`parse` 失败抛 `InvalidValue`”；`SvgLength(Float64.NaN)` 可正常构造，`toString()` 经 `formatSvgNumber` 抛 `SvgException(InvalidValue)`，所以 `writeLength`（`f_svg/src/SvgShape.cj:332-334`）会在属性写入时抛错。类型契约（`ToString`）被打破。
- **建议**：`init` 中校验 `isFinite` 并抛 `InvalidValue`（把校验前移到构造），或把“非有限值 `toString` 抛异常”写进类注释。

### [轻微][存量] `SvgInteractionState.hoveredIds` 构造后修改不会同步内部集合

- **位置**：`f_svg/src/SvgHitTest.cj:27-45`、`f_svg/src/SvgHitTest.cj:51-60`
- **来源**：存量（blame a061fe1ef5）
- **判据**：review-checklist §11（可变状态契约）
- **证据**：静态确定 —— `hoveredIds` 是 `public let Array<String>`（元素可变），`hoveredSet` 只在 `init` 中一次性构建；`isHovered` 只查 `hoveredSet`。
- **描述**：`state.hoveredIds[0] = "other"` 后 `isHovered("other")` 仍为 `false`，`:hover` 求值（`f_svg/src/CssSelector2.cj:793-798`）与用户可见状态不一致；README 只提醒 `attributes / children / warnings` 不要直接改，未提这里。
- **建议**：`init` 中复制数组为内部私有副本，或在注释与 README「已知 API 约定」中声明这些数组为只读语义。

## 优化可行性方案

### [堆内存] data URI 前缀判定与 payload 切片产生多份整串副本

- **现状**：`SvgImageResource.load` 先 `href.toAsciiLower()` 复制整串（上限 `SVG_MAX_BASE64_LENGTH = 32 MiB`，`f_svg/src/SvgImageResource.cj:70`），再 `text[prefix.size..].trimAscii()` 复制 payload，随后 base64 解码再产生约 3/4 大小的字节数组；单张 24 MiB 图峰值约 `32(原 href) + 32(lower) + 32(payload) + 24(bytes)`。
- **方案**：前缀判定改为只比较前 `SVG_DATA_PNG_PREFIX.size` 个字节的小写化切片；payload 直接从 `text[prefix.size..]` 交给解码（若 `trimAscii` 不承担去空白语义就省掉）；`lower` 不再整体生成。
- **预期**：单次解码峰值少 1–2 份 ≈ 32–64 MiB（按 32 MiB 上限估算），大 data URI 文档的尖峰显著下降。
- **代价**：前缀必须按 ASCII 逐字节比较（不能依赖 `toAsciiLower` 整串），代码略增；语义不变。
- **验证**：同输入（1 张 8/16/24 MiB PNG data URI）改前改后 `getAllocatedHeapSize()` 峰值与 RSS 峰值各 5 轮中位数。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] `SvgInterpolator.path` / `transform` 的 `ArrayList → toArray()` 双份峰值

- **现状**：`f_svg/src/SvgInterpolator.cj:106-125`、`f_svg/src/SvgInterpolator.cj:161-196` 先向 `ArrayList` 逐项追加，再 `toArray()` 复制；元素数在循环前已知（`from.commands.size` / `from.operations.size`）。
- **方案**：直接 `Array<SvgPathCommand>(count, …)` / `Array<SvgTransformOp>(count, …)` 按下标写入，去掉中间容器。
- **预期**：该次插值的峰值对象数从 2× 降到 1×（动画每帧都会调用，帧数高时可累积成持续 GC 压力）。
- **代价**：提前返回 `None` 时需丢弃已分配数组（或先做一遍结构校验再分配）；实现略长。
- **验证**：`cjprof heap` 对比同一动画采样 1000 帧的分配量与峰值。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] `svgDirectChildElements` 每个节点都新建 `ArrayList`

- **现状**：`f_svg/src/SvgHitQueries.cj:97-105` 每次调用都把 `children` 里的元素节点收进新 `ArrayList`，两处调用（`:33`、`:60`）在整棵树上是每节点一次。
- **方案**：调用处直接遍历 `element.children` 并 `match`，或改为把 `result` 作为出参复用（`svgHitQueryCollect` 已有 `result` 形参可复用）。
- **预期**：一趟查询少 O(n) 个临时 `ArrayList`（n = 元素数），GC 压力与分配计数线性下降。
- **代价**：遍历代码从“两行 for”变成“for + match”，可读性略降。
- **验证**：1000 / 10000 元素文档各 100 次查询，对比分配计数与 RSS。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `elementAt` 为取首项仍全量物化命中链

- **现状**：`f_svg/src/SvgHitTest.cj:240-262` 先调 `elementsAt` 遍历完整棵树、把所有命中装进 `ArrayList`，再取 `hits[0]`；命中数可达 1e6（`maxElements` 默认值）。
- **方案**：给 `svgHitCollect` 加 early-exit 变体（命中第一个即返回并停止遍历，`svgHitWalk` 用布尔出参冒泡中断）。
- **预期**：重叠元素多的文档上省掉其余全部元素遍历与结果列表分配；理论上限为“从首个命中到遍历结束”的那段成本。
- **代价**：新增一个遍历变体，或给现有函数加 `firstOnly` 参数；需保证返回顺序（后绘制者优先）不变。
- **验证**：`cjpm bench` 同文档（1 层 1k 重叠 rect / 深 50 层树）改前改后中位数，同时断言首项一致。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `SvgValueCache.get` 的惰性参数每次读数都构造闭包

- **现状**：`f_svg/src/SvgElement.cj:33-40` 的签名为 `get(version, compute: () -> ?T)`，每个属性 getter 传 `{=> readLength(this, "x")}`（本部分 13 处，全模块 61 处 `SvgValueCache<SvgLength>`）。缓存命中也照样构造一次捕获 `this` 的闭包。
- **方案**：把“命中即返回”与“未命中才解析”拆开（如 `peek(version)` + `put`），或让 `get` 接收 `(element, name)` 参数而非闭包。
- **预期**：bbox / 样式求值路径上的属性读取不再每次分配闭包（命中率越高收益越大）。
- **代价**：`SvgElement` 的通用缓存接口改动，触及 61 个调用点；重复逻辑需一次性迁移。
- **验证**：`cjprof record` 跑 bbox 密集场景（10k 元素 `getBBox` 循环），看分配热点与自耗时是否下移；再用 `cjpm bench` 对照。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 单次 `hitTest` 的成本主要在“整树样式重算 + 每元素 CTM/路径扁平化”，而非几何判定本身 | `f_svg/src/SvgHitTest.cj:174-195`、`f_svg/src/SvgHitTest.cj:453-470` | 自耗时占比与调用路径 | `cjprof record` 跑 1k / 10k 元素文档各 100 次 `hitTest`，看 `flattenPathData` / `cascade` 占比 |
| 2 | `flattenPathData` 每个元素重算一遍（无跨查询缓存），在 `elementAt` 场景是主要浪费 | `f_svg/src/SvgHitTest.cj:457`、`f_svg/src/SvgHitTest.cj:524` | 单次扁平化耗时 × 元素数 | 分段计时插桩，记录每元素 `flattenPathData` 累计耗时 |
| 3 | 文本命中每次都新建 `SvgTextRenderer` 且 `layoutCache: None`，多 text 文档上偏贵 | `f_svg/src/SvgHitTest.cj:516-517` | 布局耗时占比 | 对含 100 个 `<text>` 的文档跑 `hitTest`，`cjprof` 看 `SvgTextRenderer.outline` 自耗时 |
| 4 | data URI 解码峰值的 2/3 来自字符串副本，而非解码结果 | `f_svg/src/SvgImageResource.cj:101-150` | 峰值分配构成 | 单张 16 MiB data URI 渲染时抓 `cjprof heap` 分配分类 |
| 5 | 命中查询的 `O(n×depth)` 在 1000 层以上嵌套文档上会到秒级 | `f_svg/src/SvgHitQueries.cj:50-63` | 端到端耗时 | 生成深度 100/500/1000 的嵌套 `<g>` 文档，测 `getIntersectionList` 耗时曲线 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_svg/src/SvgHitQueries.cj` | .cj | ✅ | 见发现 #1/#2/#3/#4；`svgDocumentHitQuery*` 由 `SvgDocument.cj:54-69` 调用，无死代码 |
| 2 | `f_svg/src/SvgHitTest.cj` | .cj | ✅ | 见发现 #5/#7/#8/#9/#11/#14；`isHovered` / `isFocused` 由 `CssSelector2.cj:795/802` 使用 |
| 3 | `f_svg/src/SvgHitTestM6_test.cj` | .cj | ✅ | 19 个用例覆盖指针事件矩阵、DPR、上限；缺 transform / defs / display:none 子树的查询用例 |
| 4 | `f_svg/src/SvgImage.cj` | .cj | ✅ | 4 个长度属性与 `preserveAspectRatio` 均被 `SvgElementApi.cj:134-141`、`SvgFilterPrimitives2.cj:1401` 使用 |
| 5 | `f_svg/src/SvgImageResource.cj` | .cj | ✅ | 见优化方案（data URI 副本）；`load` / `loadDataUri` 的前缀判定与解码降级重复 |
| 6 | `f_svg/src/SvgImageResource_test.cj` | .cj | ✅ | 覆盖 data URI、provider 缓存、累计像素预算；第 18 行 import 未使用（发现 #12） |
| 7 | `f_svg/src/SvgInitialView.cj` | .cj | ✅ | `SvgZoomAndPan.fromName` 由 `SvgDocument.cj:91` 使用；`toString` 为属性拼写（与 #6 的 `SvgCalcMode` 不一致） |
| 8 | `f_svg/src/SvgInitialViewM6_test.cj` | .cj | ✅ | 4 个用例覆盖 `view` 覆盖、回退 warning、`preserveAspectRatio`、`viewTarget` 忽略；第 18 行 import 未使用 |
| 9 | `f_svg/src/SvgInterpolator.cj` | .cj | ✅ | 见发现 #6/#12、优化方案（`path`/`transform` 双份峰值）；`splineValue` 牛顿迭代 10 次有界 |
| 10 | `f_svg/src/SvgInterpolator_test.cj` | .cj | ✅ | 覆盖 numeric/list/color/path/string/transform 六个入口，含结构不一致返回 `None` |
| 11 | `f_svg/src/SvgKernTableM5_test.cj` | .cj | ✅ | kern format 0、非水平子表、65536 条上限、截断告警；辅助函数均被其他测试文件复用 |
| 12 | `f_svg/src/SvgKerningLayoutM5_test.cj` | .cj | ✅ | 14 个用例覆盖 kern/GPOS/GSUB、连字与 dx/x/rotate 列表、跨 tspan 边界；构造 TTF 的辅助函数被多处复用 |
| 13 | `f_svg/src/SvgLength.cj` | .cj | ✅ | 见发现 #12/#13；`toUserUnits` 被 `SvgViewport.cj:156/170` 使用，`isAbsolute` 仅测试使用（对外 API，不判死代码） |
| 14 | `f_svg/src/SvgLengthContext_test.cj` | .cj | ✅ | 覆盖默认值、绝对/字体相对/百分比三轴、退化视口为 0 |
| 15 | `f_svg/src/SvgLength_test.cj` | .cj | ✅ | 覆盖全部单位、大小写、正负号、溢出拒绝、`parse(toString(x))` 往返与已声明的不保真边界；第 134 行注释“小写名”与实际断言不符（并入 #6） |
| 16 | `f_svg/src/SvgLimitsM3_test.cj` | .cj | ✅ | pattern 深度、marker 循环、warning 审计；第 18 行 import 未使用 |
| 17 | `f_svg/src/SvgLimitsM4_test.cj` | .cj | ✅ | 卷积/湍流/TTF/feImage/形态学上限与预算；辅助函数 `m4Buffer` 等来自其他测试文件 |
| 18 | `f_svg/src/SvgLine.cj` | .cj | ✅ | 4 个属性均被 `SvgGeometry.cj:331-334`、`SvgStrokeOutliner.cj:115`、`SvgMarkerExpander.cj:243`、`SvgClipMask.cj:840` 使用 |
| 19 | `f_svg/src/SvgLineJoinM6_test.cj` | .cj | ✅ | miter-clip / arcs / 与 round 覆盖差 ≤1/255；第 18 行 import 未使用 |
| 20 | `f_svg/src/SvgLinearGradient.cj` | .cj | ✅ | 见发现 #10（属性未进渲染管线，对外 API 不作死代码） |

合计：`.cj` 20 个 / `.md` 0 个 / 共 20 个，全部读完（本部分清单不含 `.md`）。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 6 | 坐标空间错配、遍历门禁缺失、硬编码视口、奇异矩阵回退、枚举约定漂移、可变数组失同步；本部分无网络/文件访问，`SvgImageResourceProvider` 把安全责任显式交给调用方，未发现注入面（无字符串拼接进 XML/HTML） |
| §1 死代码 | 1 | 已逐个符号搜引用：`svgDocumentHitQuery*`（SvgDocument）、`svgHitQueryCollect/Matches/DirectChildElements`、`SVG_HIT_TOLERANCE/EPSILON`、`SvgHitContext` 以及 `svgHitWalk/LocalPoint/ElementMatches/Text/BBoxContains/ImageBounds/ImageContains/BoundsContainsPoint/PointInContours/PointNearContours/LineCapCoversPoint/DistanceToSegment/DistanceToPoint/PointOnSegment`、`isHovered/isFocused`、`SVG_DATA_PNG_PREFIX`、`resourceBytes`、`parseUnit`、`interpolateChannel/bezierCoordinate/bezierDerivative`、`fromName` 均有调用者；`SvgLinearGradient` 4 个属性对外可达仅记信息；唯一命中是未使用 import（发现 #12）。无 `return` 后同层语句、无恒真恒假分支（`SvgRoot <: SvgElement` 而非 `SvgContainer`，故 `svgHitElementMatches` 的 container/root 两个 case 不重叠） |
| §2 重复逻辑 | 4 | 已按函数体「输入-输出-副作用」两两比对并跨文件搜同义实现：视口/原点换算 3 份（发现 #3 关联、`SvgViewportTransform.from`）、`calcMode` 双映射（#6）、`svgHitQueryMatches` 与 `svgHitElementMatches` 门禁漂移（#2）、`svgHitImageBounds` 与 `SvgElementApi` image 分支（位置 `SvgHitTest.cj:580-589` vs `SvgElementApi.cj:134-141`，仅重复无漂移，未单列）；13 处长度属性样板属全模块 61 处同一形态，合并记录在 #10 与总评，不按处数计数 |
| §3 空实现 | 1 | `elementsAt` 丢弃 warning（#9）；其余无 `{}` / `TODO` / `return None` 占位；`SvgHitQueryMatches` 的 `None => return false` 是“样式缺失即不命中”的显式降级，非空实现 |
| §4 栈溢出 | 1 | `svgHitQueryCollect` / `svgHitWalk` 按元素深度递归，无自深度上限；解析文档由 `SvgSecurityOptions.maxDepth=512`（`SvgOptions.cj:66`）限定，但 `appendElement` 无深度校验，程序化构造的深树可无限递归（未单列为缺陷，因需调用方主动构造，已在发现 #4 的“无上限”说明中提及） |
| §5 OOM | 2 | 查询无元素上限（#4）、data URI 多份整串副本（优化方案，量化见该条）；`SvgImageResource` 的解码总量受 `SvgDecodeBudget` 约束（`SvgPngDecoder.cj:30-51`），单次渲染 64 Mi 像素上限，不另报 |
| §6.1 热点瓶颈 | 0 | 本部分无 profile / bench 数据，未把任何“看起来慢”的点写成发现；5 条线索已全部转入「待验证假设」 |
| §6.2 大粒度锁 | 0 | 本部分无锁、无 `synchronized`、无共享可变容器写入（`SvgHitTest.warnings` 的并发问题归 §12.1） |
| §6.3 并发串行 | 0 | 无 `spawn` / `Future` / 批量任务提交 |
| §6.4 低效算法 | 2 | 查询每元素重算子树 bbox（#4）、`elementAt` 全量物化（优化方案）；`svgPointInContours` 为单趟扫描，`svgDistanceToSegment` 有零长度保护，未发现二次方级实现 |
| §7 降堆内存方案 | 3 | data URI 副本、`ArrayList → toArray` 双份峰值、`svgDirectChildElements` 临时表；均标 `无基线（待验证）` |
| §8 降 CPU 方案 | 2 | `elementAt` early-exit、`SvgValueCache` 闭包分配；均标 `无基线（待验证）` |
| §9 local mode 可行性 | 0 | 本部分主体是命中判定与数值插值，临时对象都是小对象且多数会写进返回值（`Array`/`ArrayList` 逃逸），没有可量化的“函数内大临时结构”；按 checklist §9 约束（逃逸 + 峰值数据缺失），结论为不适用 |
| §11 现有代码的 BUG（存量） | 7 | 见 #1/#2/#3/#5/#7/#8/#13；另核对 `svgPointNearContours` 的 `contour.size==0` 分支——`flattenPathData` 仅在 `current.size > 0` 时入栈（`SvgRasterizer.cj:518-520`），不会产生空轮廓，故不判越界 |
| §12 并发安全与锁粒度 | 2 | `SvgHitTest.warnings`（#11）与 `SvgInteractionState` 可变数组（#14）是仅有的可变状态；其余函数为纯计算、无静态状态，`SvgImageResource` 文档声明“实例生命周期即一次 render”，属线程封闭 |
| §14 功能完备性与 README 覆盖 | 1 | README「交互与命中测试」表（`f_svg/README.md:239-247`）承诺 `hitTest` / `getIntersectionList` / `getEnclosureList` / `checkIntersection` / `checkEnclosure` / `elementsAt` / `elementAt`，均有实现；`SvgInteractionState`、`SvgInterpolator`、`SvgLength*`、`SvgImageResourceProvider`、`SvgLinearGradient`、`SvgZoomAndPan`、`SvgImageRendering` 在 README 与 README_en 都能搜到。问题在“实现了但结果不对/语义漂移”（#1-#3），不在缺失 |
| 文件覆盖（§13 等） | 20/20 | 本部分清单 20 个 `.cj`，无 `.md` 需要核对；`doc/**` 与 README 仅作 §14 交叉核对，未计入本部分覆盖 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 1 |
| 一般 | 5 |
| 轻微 | 8 |
| 优化方案（堆内存 / CPU） | 3 / 2 |

存量 14 条（本部分无本次改动），是否纳入修复待用户决定。

## 总评

本部分代码的可读性与约定一致性好：命中测试的指针事件矩阵（`visiblePainted / painted / fill / stroke / all / bounding-box`）实现完整且有对应用例，长度解析的往返与不保真边界写得清楚，图像资源把“联网/读文件”的安全责任显式交给调用方，插值器的结构校验返回值语义明确。

阻塞项只有一处：**命中查询系列 API 的坐标空间错配**（`getIntersectionList` / `getEnclosureList` / `checkIntersection` / `checkEnclosure` 忽略元素与祖先的 `transform`）。这四个 API 在 README 中作为“支持”对外承诺，而现有测试全部使用无变换文档，属于典型的“用例避开 bug”。同一文件的遍历门禁缺失（定义容器与 `display:none` 子树不剪枝）、硬编码 300×150 视口、无元素上限，建议与坐标修复一并处理——它们同属“查询路径另写了一套简化遍历，没有复用 `svgHitWalk`”。

其余为可排期的质量问题：奇异矩阵回退导致误命中、方形端点帽与 join 区域漏判（像素级保真）、`calcMode` 双映射、`SvgLinearGradient` 双读取路径、未使用 import、`SvgLength` 非有限值契约。性能与内存的 5 条线索都只有静态推断，已全部留在「待验证假设」与「优化可行性方案（无基线）」，未写成结论。
