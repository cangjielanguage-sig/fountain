# f_svg 模块审查报告（第 18/26 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_svg/src`（本部分 20 个源文件，`.md` 0 个）
- **基线**：工作区快照（master 与 sts/1.3.x 同一提交 `120fd2542`，`git diff` 为空 ⇒ 全部记「存量」）
- **审查重点**：SVG/XML 解析与序列化边界、注入与转义、递归与栈溢出、OOM、死代码、重复逻辑
- **报告版本**：分部分报告（part18），由主 Agent 合并进 `docs/review/2026-11-28/f_svg_v2.md`
- **本部分覆盖**：marker 模型与派生、矩阵/数值/列表/画笔/选项/overflow、DOM 变更事件、OpenType（kern/GPOS/GSUB）表解析，以及对应测试

## 发现

### [严重][存量] GPOS Coverage / ClassDef format 2 按范围展开，无条数上限也未去重，可被小体积字体放大成 OOM

- **位置**：`f_svg/src/SvgOpenTypeLayout.cj:481`（`parseGposCoverage` format 2 的 `while (glyph <= end)`）、`f_svg/src/SvgOpenTypeLayout.cj:506`（`parseGposClassDef` format 2 同一写法）
- **来源**：存量（工作区快照，`git diff` 为空，无基线可比）
- **判据**：review-checklist §5「无界容器 / 按不可信长度预分配」；同文件 `kern`、`PairPos format 1/2` 都有上限，唯独这两处范围展开没有
- **证据**：静态确定 —— `count = reader.u16(offset + 2)`（≤65535 条 RangeRecord），每条 RangeRecord 的 `start..end` 是 u16 闭区间（≤65536 个字形），内层无条件 `result.add(glyph)`，既不去重也不累计计数；`parseGposClassDef` 同构
- **描述**：一个约 384 KB 的 `GPOS` 表（65535 条 RangeRecord × 6 B）即可让 `parseGposCoverage` 向 `ArrayList<Int64>` 追加 65535 × 65536 ≈ 4.29e9 个元素，按 8 B/元素 ≈ 34 GB，必然 OOM；同一份表在 `parseGposClassDef` 里变为 4.29e9 次 HashMap 写入，变成分钟级 CPU 占用。`parseGposCoverage` 还被 GSUB 连字解析复用（`SvgOpenTypeLayout.cj:630`），影响面不止 GPOS。字体字节由调用方 `SvgTrueTypeFont.parse` 传入（`f_svg/src/f_svg.cj:56` 明确「字体只由调用方显式 parse / load」），字体文件是典型不可信输入；`doc/f_svg-M3设计.md:370-381` 的资源上限表也没有为字体表列任何条数上限
- **建议**：三处同时收口——(1) 为 coverage / classDef 设总条数上限（字形总数本就 ≤65536，可用 `maxGlyphId` 或 `CSS_GPOS_MAX_PAIRS` 复用）；(2) 覆盖表改用 `Array<Bool>`/`HashMap` 去重后再落数组；(3) 超出时按现有风格 `warnings.add(...)` 并 `return false`（丢弃该子表），不要静默扩容

### [一般][存量] GPOS PairPos format 1 的 pair 表只有「单 pair set」上限，缺全局累计上限（与 kern 不对称）

- **位置**：`f_svg/src/SvgOpenTypeLayout.cj:388`（`if (pairCount > CSS_GPOS_MAX_PAIRS)` 位于内层循环内）；对照 `f_svg/src/SvgOpenTypeLayout.cj:231-236`（`kern` 用 `totalPairs` 累计，超限整表忽略）
- **来源**：存量
- **判据**：review-checklist §5（无界容器）/ §2（同一约束在两处实现不一致）
- **证据**：静态确定 —— `target.pairs` 是跨子表、跨 lookup 共享的 `HashMap`，只在每个 pair set 内比较 `pairCount`，没有 `totalPairs`；`parseGposPairSubtable` 的 `parsed` 只表示「有内容」，不参与限流
- **描述**：`pairSetCount`（≤65535）× 每 set 最多 65536 对 ⇒ 上限仍是 4.29e9 条，只是被文件体积线性约束（每对 6 B）。10 MB 的 GPOS 表约能塞 1.7M 对，落成 HashMap 约 40 B/条 ⇒ 约 70 MB 常驻，且解析期还有 `coverage` 数组副本；同一份字体在 `kern` 路径会整表拒绝，在 GPOS 路径却全部收下
- **建议**：把 `kern` 的 `totalPairs` 计数方式提到 GPOS（函数内累计，超 `CSS_GPOS_MAX_PAIRS` 时告警并停止该 lookup）

### [一般][存量] GPOS 不支持 Extension lookup（Type 9），且静默跳过不留 warning

- **位置**：`f_svg/src/SvgOpenTypeLayout.cj:335-338`（`if (lookupType != 2) { continue }`）；对照 `f_svg/src/SvgOpenTypeLayout.cj:165-184`（GSUB 对 Type 7 有递归解包 + 告警）
- **来源**：存量
- **判据**：review-checklist §14.1（只做了一半的分支 / 两表处理不对称）与 §3（静默跳过）
- **证据**：静态确定 —— 代码中不存在 `lookupType == 9` 分支；`continue` 前没有任何 warning；GSUB 侧存在等价解包（`reader.u16(subOffset) != 1` 还会告警）
- **描述**：现代字体在 PairPos 偏移超过 64 KB 时会把真实子表包进 Extension（Type 9），这是 libharfbuzz/FreeType 的常规布局。此处直接 `continue`，结果是「字距悄悄消失」，既不生效也不告警，与本模块「能解析就解析、不能解析就 warning」的既有策略相反；测试 `SvgOpenTypeLayoutM5_test.cj` 也只覆盖了 Type 2，无法暴露
- **建议**：与 `cssCollectGsubLookup` 对齐，加 Type 9 分支（format 1 → `ExtensionOffset` 指向真实 lookup，深度 +1 并受上限约束），无法解包时 `warnings.add("GPOS 扩展 lookup 不受支持")`

### [一般][存量] `cssLayoutTag` 用 `String.fromUtf8` 解析 4 字节 tag，非法 UTF-8 抛 `IllegalArgumentException`，会穿透只捕 `SvgException` 的解析函数

- **位置**：`f_svg/src/SvgOpenTypeLayout.cj:34-43`；捕获点 `f_svg/src/SvgOpenTypeLayout.cj:258`、`:351`、`:607`（均只 `catch (_: SvgException)`）
- **来源**：存量
- **判据**：review-checklist §11「错误处理缺失」/ §10 异常类型；语言文档：`cangjie_runtime/stdlib/doc/libs/std/core/core_package_api/core_package_structs.md:6384-6386`（`String.fromUtf8` 入参不符合 utf-8 序列规则时抛 `IllegalArgumentException`）
- **证据**：静态确定 —— tag 取自 `reader.u8()` 的 4 个任意字节，`String.fromUtf8` 会校验码点；`SvgException <: BaseException`，`IllegalArgumentException` 不是它的子类，三个 `catch` 都接不住
- **描述**：字体 tag 按规范是 ASCII，但畸形 / 被篡改字体给出 `0xFF 0x00 ...` 时，异常从 `SvgGposPairs.parse` / `SvgGsubLigatures.parse` 直接冒到 `SvgTrueTypeFont` 构造，调用方拿到的是非 `SvgException`，与模块「解析失败统一 `SvgException` + warning」的契约不符（严格模式下更会绕过按 kind 的分类处理）
- **建议**：tag 比较改为直接比 4 个字节（或 `String.fromUtf8Unchecked` + 只做相等比较），或把三处 `catch` 放宽到 `Exception` 并保留 `SvgException` 分支以维持 kind

### [一般][存量] `SvgMatrix.invert` 用绝对行列式阈值，小尺度但可逆的矩阵被判不可逆，调用方静默回退

- **位置**：`f_svg/src/SvgMatrix.cj:106-119`（阈值 `SVG_INVERT_EPSILON = 1e-12`，`f_svg/src/SvgMatrix.cj:21`）
- **来源**：存量
- **判据**：review-checklist §11（边界 / 契约与注释不符）：注释写「不可逆（行列式接近 0）时返回 None」，实现是 `abs(det) < 1e-12` 的**绝对**阈值
- **证据**：静态确定 —— `SvgMatrix.scale(1e-7, 1e-7)` 的 `det = 1e-14 < 1e-12`，但逆矩阵存在且元素有限（1e7），`invert()` 返回 `None`。等价地，`viewBox="0 0 1000000000 1000"` 这类合法文档的矩阵（scale≈1e-9）会被判奇异
- **描述**：失败路径在调用侧全部静默：`SvgRasterizer.cj:205`、`:263` 用 `?? SvgMatrix.identity`（把设备坐标当用户坐标，图案/纹理错位），`SvgRenderer.cj:601-604` 同样回退 identity，`SvgPatternSampler.cj:163` 直接跳过该图案。用户看到的是「大面积空白 / 填充跑到别处」，而不是错误。上述调用点在本次审查范围外，仅作影响面证据
- **建议**：改相对判据（如 `abs(det) <= eps * max(|a|,|b|,|c|,|d|)^2`，或按 2×2 的最大元素归一化后再比较），并把「不可逆」从 `?SvgMatrix` 换成可上报的错误，至少让上层能记一条 warning 而不是 identity 兜底

### [一般][存量] 设计承诺「渲染全程只读 `SvgDocument`」，但类型化 getter 在读取时写入缓存，同一文档并发渲染构成数据竞争

- **位置**：`f_svg/src/SvgElement.cj:33-40`（`SvgValueCache.get` 写 `cached` / `version` / `hasCached`，无任何同步）；使用方示例 `f_svg/src/SvgMarker.cj:117-222`（8 个属性全部走该缓存）
- **来源**：存量
- **判据**：review-checklist §12.1（共享可变状态无保护）+ §13 类（与设计文档冲突：`doc/f_svg-M3设计.md:73`「渲染全程只读 `SvgDocument`」）
- **证据**：静态确定 —— 缓存字段是普通 `var`，无锁 / 无原子 / 无线程封闭标注；共享路径明确：一个 `SvgDocument` 被两个线程同时 `SvgRenderer.render`，两条线程对同一 `SvgMarker` 调 `markerUnits` 等 getter 即并发写同一 `SvgValueCache`
- **描述**：设计文档把「只读」当作可并发的前提，实现却在读路径上做惰性写。后果是 `version` 与 `cached` 可能不一致（读到上一代缓存值或半写状态），并且首次读取时重复计算。单线程下无影响，所以测试与常规用法都发现不了
- **建议**：二选一并写进文档——(1) 解析完成后冻结文档（`seal()` 后禁止写，getter 走不可变索引），(2) 缓存改为解析期一次性预计算，或按线程持有 side table。若坚持懒缓存，README/类注释必须显式声明「同一文档不可跨线程渲染」

### [一般][存量] 变更 hub 的监听器列表既无并发保护也无遍历快照，重入会无限递归

- **位置**：`f_svg/src/SvgMutation.cj:76`（`private let listeners = ArrayList<...>`）、`:86-93`（`remove` 直接 `remove(at:)`）、`:95-106`（`notify` 直接 `for (listener in this.listeners)`）
- **来源**：存量
- **判据**：review-checklist §12.1（迭代与修改并发、锁对象误用）与 §4（无界递归：同步回调无重入保护）
- **证据**：静态确定 —— 全类无同步原语；`notify` 没有 `notifying` 标志、没有 `listeners.clone()` 快照；监听器里调 `element.setAttr(...)` → `svgNotifyMutation`（`:110-124`）→ 同一 hub `notify` → 同一个监听器，递归无出口
- **描述**：两个具体触发面：(1) 监听器在回调内判断并修正属性（很常见的「归一化」写法）→ 每次修正又触发一次通知，直到栈溢出；(2) 监听器在回调内 `removeMutationListener(this)` 或再 `add` → 遍历中结构修改，`ArrayList` 迭代器语义未定义（文档未声明安全），最坏抛 `ConcurrentModificationException` 并中断后续监听器。共享路径：`SvgDocument.mutationHub` 是单实例，`addMutationListener` / `removeMutationListener` 是 public（`SvgDocument.cj:41-48`）
- **建议**：`notify` 改为「拷贝一份监听器数组 + `notifying` 标志」，重入时把事件入队或直接 `warnings.add("监听器重入被忽略")`；`add/remove` 走同一把锁或写时复制，并在 `SvgMutationListener` 注释里写明「回调内不得修改本文档」

### [一般][存量] `attributes` / `children` 是 public 可变集合，绕过 `setAttr` 直接修改不会递增 `attributesVersion`，`SvgMarker` 的属性缓存永久陈旧

- **位置**：根因 `f_svg/src/SvgElement.cj:51`（`public let attributes = ArrayList<SvgAttribute>()`）、`:56`（`internal var attributesVersion`）；受影响使用方 `f_svg/src/SvgMarker.cj:117-222`
- **来源**：存量
- **判据**：review-checklist §11（契约与实现不符：「`attributes` 是唯一事实源，缓存只在 `attributesVersion` 未变时复用」，但版本只由 `setAttr/removeAttr` 递增）
- **证据**：静态确定 —— `SvgValueCache.get`（`SvgElement.cj:33-40`）只用 `attributesVersion` 做键；`attributes` 的增删改不经过任何版本递增路径
- **描述**：`markerUnits` / `orient` / `refX` / `refY` / `markerWidth` / `markerHeight` / `viewBox` / `preserveAspectRatio` 八个 getter 全部命中此问题：调用方 `element.attributes[0] = SvgAttribute(...)`（public 列表，编译期合法）后，之后每次读都把首次解析结果返回，读写不一致且无告警。`children` 同理会绕过变更事件（监听器收不到通知）
- **建议**：把 `attributes` / `children` 收窄为只读视图（对外暴露 `attr()` 与迭代器，写入只走 `setAttr/removeAttr/appendChild`），或让缓存键改为「属性列表的内容哈希」（代价是每次 getter O(属性数)）；至少在校验期把直接修改列表标为不受支持

### [轻微][存量] `SvgNode` 的 PI 序列化不转义 target / data，与文本、属性、CDATA 的转义策略不对称

- **位置**：`f_svg/src/SvgNode.cj:32`（`case PiNode(target, data) => "<?${target} ${data}?>"`）；同一写法见 `f_svg/src/SvgElement.cj:437`（范围外，同一根因）
- **来源**：存量
- **判据**：review-checklist §10（安全性：序列化注入）/ §13 类（转义一致性）
- **证据**：静态确定 —— 同文件 `serializeSvgCData`（`SvgElement.cj:665`）处理 `]]>`、`serializeSvgComment`（`:688`）处理 `--`、`escapeSvgText`（`:705`）与 `escapeSvgAttribute`（`:718`）都做了转义，唯独 PI 直拼
- **描述**：`SvgNode.PiNode` 是 public 构造入口，程序化构造 `PiNode("xml", "?> <script>alert(1)</script>")` 后 `document.toString()` 会输出可执行的标签；解析得到的 PI 不可能含 `?>`（XML 解析器已截断），所以这是「构造 → 序列化」链上的注入面，而非解析面
- **建议**：序列化前校验 target 符合 XML `Name` 产生式，并把 data 中的 `?>` 替换为 `? >`（与 CDATA 的处理思路一致）；无法安全表达时抛 `SvgException(InvalidValue)`

### [轻微][存量] `SvgKernPairs.horizontalOnly` 只写不读，是死字段

- **位置**：`f_svg/src/SvgOpenTypeLayout.cj:194`（字段）、`:196-198`（构造参数）、`:213`（唯一写入点 `SvgKernPairs(true)`）
- **来源**：存量
- **判据**：review-checklist §1（非 public 类型的成员，全仓无读取）
- **证据**：静态确定 —— 全仓 `grep horizontalOnly` 仅命中定义、构造参数与赋值；`adjust()`（`:200-202`）与 `parse()` 都不读它，且构造点恒传 `true`（`parse` 本身就只收 `format == 0 && horizontal` 的子表，`SvgOpenTypeLayout.cj:230`）
- **建议**：删除字段与构造参数，`private init()` 无参；若为将来「垂直字距」保留，需要注释说明并接上读取点

### [轻微][存量] LangSys 的 `requiredFeatureIndex` 从未读取，只在 requiredFeature 里声明 kern/liga 的字体被整体忽略

- **位置**：`f_svg/src/SvgOpenTypeLayout.cj:45-57`（`cssLayoutCollectLangSys` 只读 `offset+4` 的 count 与 `offset+6` 起的索引）
- **来源**：存量
- **判据**：review-checklist §14.1（只处理部分输入）/ §13 类（与 OpenType LangSys 表定义不符）
- **证据**：静态确定 —— LangSys 头为 lookupOrderOffset(2) / requiredFeatureIndex(2) / featureIndexCount(2)，代码从 `+4` 开始读，`+2` 从未访问
- **描述**：`requiredFeatureIndex != 0xFFFF` 时该特性是强制的，字体作者可以只把它记在 required 字段。此时 `cssLayoutLookupRefs` 找不到 `kern` / `liga`，`warnings.add("... 缺少 X 特性，已忽略")` 后整表放弃
- **建议**：`cssLayoutCollectLangSys` 先读 `offset+2`，`!= 0xFFFF` 时把该索引加入 `featureIndices`（去重逻辑复用）

### [轻微][存量] `SvgSecurityOptions` 只校验 `maxDecompressedBytes`，`maxElements` / `maxDepth` 允许 0 与负数

- **位置**：`f_svg/src/SvgOptions.cj:69-71`（仅 `maxDecompressedBytes <= 0` 抛错）、`:65-66`（默认 1_000_000 / 512）
- **来源**：存量
- **判据**：review-checklist §11（缺少边界校验、校验不对称）
- **证据**：静态确定 —— 构造体只对三个字段中的一个做校验；`maxElements = 0` 会让构建器把第一个元素判为超限，`maxDepth = -1` 会让「深度 > maxDepth」在任何深度成立，效果是「静默拒绝一切文档」，与「配置写错」难以区分
- **建议**：三个上限统一 `> 0` 校验并给出参数名；`maxDepth` 再加一个合理下界（如 ≥ 1）

### [轻微][存量] `fromNameOrWarn` 的「解析失败 → warning → 默认值」在同一模块内复制 16 份，其中两处已无生产调用

- **位置**：`f_svg/src/SvgMarker.cj:84-99`、`f_svg/src/SvgOverflow.cj:64-79`（本部分两处）；同构实现另见 `SvgFilterPrimitive.cj:60`、`:122`、`SvgFilterPrimitives2.cj:66`、`:112`、`:167`、`:230`、`:276`、`SvgTextPath.cj:48`、`:94`、`:140`、`SvgTextBaseline.cj:76`、`SvgWritingMode`、`SvgVectorEffect.cj:100`、`SvgTextWritingMode.cj:64`
- **来源**：存量
- **判据**：review-checklist §2（只改类型名的重复逻辑）/ §1（仅测试使用）
- **证据**：静态确定 —— 16 处函数体逐行同构（match raw → fromName → 失败 `warnings.add("${context} 的值「${text}」不合法，已回退为 …")` + 默认值）；`grep fromNameOrWarn` 显示 `SvgMarkerOrient` / `SvgOverflow` 两个版本的调用者只有 `SvgValueTypesM3_test.cj:126` 与 `SvgValueTypesM4_test.cj:148`，生产路径走的是 `SvgBuilder.cj:555-556` 的解析期校验 + `SvgStyleResolver` / getter 里的 `fromName`
- **建议**：抽 `parseEnumOrWarn<T>(raw: ?String, parse: (String) -> ?T, fallback: T, warnings, context)` 一处实现；两个已无生产调用的版本要么接到 getter 上（让 `setAttr` 路径也产出 warning），要么删除，避免「有告警能力但没人用」的假象

### [轻微][存量] `containsCssFeatureIndex` 线性查重嵌在 Script × LangSys 双层循环里，最坏 O(特性数 × 语言数)

- **位置**：`f_svg/src/SvgOpenTypeLayout.cj:53`（调用点）、`:59-66`（线性扫描 `ArrayList<Int64>`）
- **来源**：存量
- **判据**：review-checklist §6.4（热点里反复 `contains`）
- **证据**：静态确定 —— `scriptCount` ≤ 65535，每个 Script 的 `languageCount` ≤ 65535，`featureIndices` 只增不减，每次插入前线性扫描；即 65535 × 65535 次比较的上界来自报文头字段，不来自实际表体积（LangSys 记录 6 B）
- **描述**：正常字体 `featureIndices` 只有几十条，问题不显现；构造字体可让 `featureIndices` 增长到数万后再逐条扫描，形成纯 CPU 放大。与上面 GPOS 范围展开属不同根因（数据量放大 vs 查重算法），故分开列
- **建议**：`featureIndices` 换成 `HashSet<Int64>`（或 `Array<Bool>` 按 65536 上限位图），插入/查询 O(1)；同时给 featureIndices 一个总量上限

## 优化可行性方案

> 不是缺陷，是「还能更好」。本部分没有改前基线，全部标 `无基线（待验证，不进 tasks）`。

### [CPU] marker 派生无条件构建 mid 列表、无条件离散整条 path

- **现状**：`SvgMarkerExpander.expand`（`f_svg/src/SvgMarkerExpander.cj:65`）对每条 contour 都构建 `midPoints` / `midAngles` 并 `toArray()`（`:92-110`），而 `appendMarkers` 在 `style.get("marker-mid")` 为 `None` 时立刻 `return`（`:145-148`）；`shapeContours` 对 `SvgPath` 一律 `flattenPathData(data, identity, 0.25)`（`:263`）全量离散，即使只设了 `marker-start` / `marker-end`。按 2k 顶点 polyline 只设 `marker-start` 估算：白建 2×1998 个槽位 + 2 次数组复制；按 10k 段曲线 path 估算：白做一次完整 flatten（含容差细分）
- **方案**：`expand` 开头按 `style.get("marker-mid").isSome()` 决定是否收集 mid；对 `SvgPath` 在只有 start/end 时改走「子路径端点枚举」（`SvgPathData` 增加只取端点/切线方向的遍历），保留 `flattenPathData` 给 mid 场景
- **预期**：每元素少 2×(n-2) 个临时槽位与 2 次复制；曲线路径在不需 mid 时省一次 O(细分数) 的离散与分配。具体占比未测
- **代价**：需要新的路径遍历 API，且必须与 flatten 的端点语义一致（`C`/`S`/`Q`/`T`/`A` 终点）；与 `marker-mid` 分支的行为差异要补等价用例
- **验证**：`cjpm bench -O2`，同输入 2k / 20k 顶点 polyline 与 10k 段 path，只设 start/end，取中位数与离散程度；同时看分配量
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 每次属性写入都向上遍历到根找 hub，且 listeners 为空时也不短路

- **现状**：`svgNotifyMutation`（`f_svg/src/SvgMutation.cj:110-124`）从被改元素沿 `parent` 链上溯，直到命中 `mutationHub`（只有根有）；`SvgElement` 的每个 `setAttr` / `setAttr(ns)` / `removeAttr` / `appendChild` / `insert` / `remove` 都调用它（`SvgElement.cj:161` 等 7 处）。深度 d 时单次写入 O(d)，批量构建 n 个元素共 O(n·d)；`SvgMutationHub.notify` 在 `listeners` 为空时仍进入循环
- **方案**：(1) `notify` 前 `if (this.listeners.size == 0) { return }`；(2) 元素在挂载时缓存 hub 指针（或根在 `SvgDocument.init` 时下发），reparent 时刷新——把「每次写入上溯」降为「每次写入一次判空」
- **预期**：无监听器（绝大多数渲染/解析场景）时把每次属性写入从 O(d) 降为 O(1)；具体端到端收益需 profile 证明
- **代价**：新增「hub 指针可能陈旧」的不变量，必须覆盖 `appendChild` / `remove` / `parent` 直改（`parent` 是 public `var`，`SvgElement.cj:53`，外部可直接改写）的所有路径，否则通知会丢
- **验证**：`cjprof record` 跑「解析 1 万元素文档」与「批量 setAttr 10 万次」，对比 `svgNotifyMutation` 自耗时占比与总时长
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 每个类型化 getter 都创建捕获 `this` 的闭包（`SvgMarker` 8 个属性最集中），在渲染树逐元素读属性时形成可观分配量 | `f_svg/src/SvgMarker.cj:119-127`、`f_svg/src/SvgElement.cj:33` | 每次读取的分配字节数与占比 | `cjprof heap` / 分配埋点，跑 1 万元素文档一次完整渲染，统计 `getAllocatedHeapSize()` 与 getter 调用次数 |
| 2 | `flattenPathData` 在 marker 派生中的自耗时占比（长曲线 path） | `f_svg/src/SvgMarkerExpander.cj:263` | 自耗时占比与调用路径 | `cjprof record` 渲染含 10k 段 `C` 的 path（仅 marker-end），看 `flattenPathData` self time |
| 3 | `SvgValueCache` 的命中率与「同一属性在渲染树里被重复读取」的比例 | `f_svg/src/SvgElement.cj:33-40` | 命中率、每次未命中耗时 | 在 `get` 里加计数埋点，跑 100 份文档稳态负载 |
| 4 | 大字体（>5 MB）的 GPOS/GSUB/kern 解析耗时与内存峰值 | `f_svg/src/SvgOpenTypeLayout.cj:205` / `:315` / `:575` | 解析耗时、峰值内存 | 用 3 个真实 CJK 字体跑 `SvgTrueTypeFont.parse`，记录 `cjprof` 与峰值 RSS |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_svg/src/SvgMarker.cj` | .cj | ✅ | 8 个属性均走 `SvgValueCache`；缓存失效问题见发现 #8；`fromNameOrWarn` 仅测试调用见 #13 |
| 2 | `f_svg/src/SvgMarkerExpander.cj` | .cj | ✅ | marker 派生主逻辑；mid 空转见优化方案 1；`import fountain::f_base.*` 仓内未见使用（待确认，未计入统计） |
| 3 | `f_svg/src/SvgMarkerExpander_test.cj` | .cj | ✅ | 覆盖 start/mid/end、闭合去重、viewBox、1024 截断、深度上限 |
| 4 | `f_svg/src/SvgMarker_test.cj` | .cj | ✅ | 属性默认值与往返；与实现一致 |
| 5 | `f_svg/src/SvgMatrix.cj` | .cj | ✅ | 乘法/求逆/工厂；`invert` 阈值问题见发现 #5 |
| 6 | `f_svg/src/SvgMatrix_test.cj` | .cj | ✅ | 结合律、可逆往返、奇异矩阵；未覆盖小尺度矩阵 |
| 7 | `f_svg/src/SvgMutation.cj` | .cj | ✅ | 变更 hub；并发/重入问题见发现 #7 |
| 8 | `f_svg/src/SvgNamespaces.cj` | .cj | ✅ | 三个命名空间常量，`SVG`/`XLINK`/`XML` 均有引用 |
| 9 | `f_svg/src/SvgNode.cj` | .cj | ✅ | PI 序列化不转义见发现 #9 |
| 10 | `f_svg/src/SvgNumber.cj` | .cj | ✅ | 扫描/规范化/有限性校验；`Float64.toString` 固定 6 位小数（文档已核） |
| 11 | `f_svg/src/SvgNumberList.cj` | .cj | ✅ | 分隔符三态与错误分支完整；`Array ==` 为逐元素比较（文档已核） |
| 12 | `f_svg/src/SvgNumberList_test.cj` | .cj | ✅ | 含 `1e999` 溢出与非有限值用例 |
| 13 | `f_svg/src/SvgNumber_test.cj` | .cj | ✅ | 6 位小数、去尾零、无科学计数法；`expectSvgException` 供多文件复用 |
| 14 | `f_svg/src/SvgOpenTypeLayout.cj` | .cj | ✅ | 本部分主要风险集中处：发现 #1-#4、#10-#11、#14 |
| 15 | `f_svg/src/SvgOpenTypeLayoutM5_test.cj` | .cj | ✅ | GPOS/GSUB 合成表；未覆盖 Type 9、范围展开、非法 tag |
| 16 | `f_svg/src/SvgOptions.cj` | .cj | ✅ | 安全选项校验不对称见 #12 |
| 17 | `f_svg/src/SvgOverflow.cj` | .cj | ✅ | `fromName` 生产可用（`SvgComputedStyle.cj:375`、`SvgStyleResolver.cj:658`）；`fromNameOrWarn` 仅测试 |
| 18 | `f_svg/src/SvgOverflowM3_test.cj` | .cj | ✅ | PNG 尺寸/位图/pattern tile 乘法溢出，均断言 `Limit` |
| 19 | `f_svg/src/SvgOverflowM4_test.cj` | .cj | ✅ | marker/symbol/嵌套 svg 的 overflow 裁剪与快路径 |
| 20 | `f_svg/src/SvgPaint.cj` | .cj | ✅ | 仅接受 `url(#id)`，外部 URL 抛 `Security`；与 README「不联网」一致 |

合计：`.cj` 20 个 / `.md` 0 个 / 共 20 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 6 | 正确性：#1/#2/#5/#11；设计：#8/#9；语言特性：`String.fromUtf8` 异常类型（#4）、`Array ==` 与 `Float64.toString` 已对文档核对；可读性：#13 的重复实现；安全性：#9 序列化注入 |
| §1 死代码 | 2 | 逐个核对本部分全部 private / internal 符号：`sameSvgPoint`、`startAngle`、`endAngle`、`midAngle`、`markerIdOf`、`markerUnitScale`、`markerWidth/Height`、`markerViewportMatrix`、`markerContentMatrix`、`normalizeSvgNumber`、`isSvgDigit/isSvgSpace/isSvgAlpha/skipSvgSpaces/scanSvgNumber/requireFinite`、`cssLayoutTag/cssLayoutCollectLangSys/cssLayoutFeatureIndices/cssLayoutLookupRefs/cssCollectGsubLookup/cssPairKey/parseGposPairSubtable/valueRecordSize/readGposXAdvance/parseGposCoverage/parseGposClassDef/parseGsubLigatureSubtable` 均有调用者；命中 2 条：`SvgKernPairs.horizontalOnly`（#10 字段与构造参数只写不读）、两个 `fromNameOrWarn` 仅测试调用（#13）。`SvgMarkerUnits/Orient/Overflow.fromName`、`SVG_MAX_MARKER*`、`markerViewBoxMatrix`、`svgNotifyMutation` 均有生产引用；public（`SvgNamespaces`、`SvgPoint.create`、`SvgMatrix.create` 等）对外可达，不判 |
| §2 重复逻辑 | 2 | 同文件两两比对：`startAngle`/`endAngle`/`midAngle` 各自语义不同（方向与边界不同）不合并，但四处重复 `180.0 / 3.141592653589793` 字面量、`sameSvgPoint`/`startAngle`/`endAngle` 三处重复 `1e-9` 容差；跨文件命中 `fromNameOrWarn` 16 份同构实现（#13）。`SvgKernPairs.adjust` 与 `SvgGposPairs.adjust` 结构相似但存储与回退不同，属业务差异，不记 |
| §3 空实现 | 0 | 无空函数体、无 `TODO`/`FIXME`；`SvgMutationHub.notify` 的 `case None => ()` 是「文档未挂 hub」的合法分支且有注释；`SvgPaintKind.None` 是真实枚举值不是空实现 |
| §4 栈溢出 | 1 | `cssCollectGsubLookup` 有深度上限（8）不构成风险；`SvgElement.toString` → 子节点递归受解析期 `maxDepth`（默认 512）约束；命中唯一一条：变更监听器重入无出口（#7） |
| §5 OOM | 2 | GPOS coverage/classDef 范围展开（#1）、GPOS format 1 pair 表无全局上限（#2）；marker 1024 上限、kern 65536 上限、marker 深度 64 均已闭环，不再报 |
| §6.1 热点瓶颈 | 0 | 本部分无 profile / bench 数据，无法成立热点结论；相关猜测进「待验证假设」#1-#4 |
| §6.2 大粒度锁 | 0 | 本部分无锁；`synchronized` 零出现 |
| §6.3 并发串行 | 0 | 无 `spawn`、无任务提交，不适用 |
| §6.4 低效算法 | 1 | `containsCssFeatureIndex` 线性查重（#14）；其余 `ArrayList` 遍历均在一次线性扫描内 |
| §7 降堆内存方案 | 0 | 本部分可降内存点（marker mid 临时数组、GPOS 表结构）需要分配基线才能量化，已并入优化方案与假设，未单列堆方案 |
| §8 降 CPU 方案 | 2 | marker 派生空转（优化方案 1）、属性写入上溯（优化方案 2） |
| §9 local mode 可行性 | 0 | `SvgMarkerExpander.expand` 的临时数组随返回值（`Array<SvgMarkerInstance>`）逃逸到渲染树，`shapeContours` 结果同样逃逸；要拿到收益须给 `flattenPathData` 等整条调用链补 mode 重载，且只能用峰值内存对照证明，缺数据，不成立 |
| §11 现有代码的 BUG（存量） | 4 | 本轮读到的边界/空值/资源/契约均已核对：命中 #4（异常类型）、#5（阈值）、#8（缓存失效）、#12（参数校验）；`scanSvgNumber` 的符号/小数/指数边界、`parseSvgNumberSequence` 的逗号三态、`expand` 的空 contour 与 1/2 点边界、`SvgPaint.parseReference` 的引号与嵌套 `url()` 均已逐分支核对，无缺陷 |
| §12 并发安全与锁粒度 | 2 | 共享点两条：`SvgDocument.mutationHub`（#7）、同一文档的 `SvgValueCache`（#6）；`SvgMarkerExpander` 的 `warnings` 也是可变实例状态，但 `SvgRenderTree.cj:1286` 每次新建、线程封闭，只作提示不计命中。无锁，故 §12.2 无粒度问题 |
| §14 功能完备性与 README 覆盖 | 2 | GPOS Extension 缺分支（#3，承诺源：GSUB 侧同类实现与「不支持会告警」的既有策略）、`requiredFeatureIndex` 未接（#11）；本部分不含 `.md`，README 逐项对照在其它部分完成，本部分 public 声明（`SvgMarker`、`SvgMarkerExpander`、`SvgMatrix`、`SvgPaint`、`SvgMutation*`）均为既有 API，README:164 已列 marker 能力，未见新增未文档化符号 |
| 文件覆盖（§13 等） | 20/20 | 20 个文件全部读完，无缺失 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 1 |
| 一般 | 7 |
| 轻微 | 6 |
| 优化方案（堆内存 / CPU） | 0 / 2 |

存量缺陷 14 条（本部分全部为存量：快照模式无 diff），是否纳入修复待用户决定。

## 总评

本部分的代码质量整体偏中上：数值/列表/画笔的解析器边界处理扎实（符号紧邻、多余逗号、指数截断、非有限值都有明确错误），marker 派生的递归与数量上限按设计文档闭环（1024 截断 + 深度 64 抛 `Limit`），测试对裁剪与快路径的覆盖也到位。真正需要排期的是两类问题：

第一类是字体表解析的资源边界（#1、#2、#14）。`kern` 做了累计上限，`GPOS` 却在两个位置漏了上限，且 Coverage/ClassDef 的范围展开既不去重也不计数——这是同一个「把报文头字段当数组长度」的根因在不同函数里的三种表现，**阻塞项**应优先修 #1（一条 384 KB 的构造表就能打爆内存）。#3（GPOS Extension 不支持）不是内存问题但会静默丢字距，属于「安静的错误结果」，建议同批修掉，因为修法就是复刻 GSUB 已有的 15 行解包逻辑。

第二类是缓存与变更模型（#6、#7、#8）。三者共享一个前提：`SvgElement` 既暴露可变集合，又在读路径上写缓存，而设计文档把渲染描述为「全程只读」。单线程常规用法下不会出错，所以现有测试全绿；但一旦有人按文档假设并发渲染，或直接改 `attributes` 列表，就会出现陈旧值、数据竞争或监听器栈溢出。建议按「先定契约再改实现」处理：要么冻结文档 + 预计算缓存，要么在 README 明确「单线程写、不可并发渲染」。这三条都属于存量、非阻塞，但应在同一次契约整理中一起定掉。

其余（#4 异常类型穿透、#5 求逆阈值、#9 PI 转义、#10-#13 死代码与校验）都是低风险但修起来很便宜的项：`horizontalOnly` 字段、两个仅测试使用的 `fromNameOrWarn`、`requiredFeatureIndex` 都可以顺手清掉或接上；`invert` 的绝对阈值建议改相对判据，因为调用侧全部静默兜底 identity，出错时用户只会看到「画面不对」而无从定位。
