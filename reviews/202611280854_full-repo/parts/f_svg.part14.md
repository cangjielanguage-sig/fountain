# f_svg 模块审查报告

> **模块第 14/26 部分**（只覆盖 `files/f_svg.part14.txt` 列出的 20 个文件：`SvgDropShadowM5_test` → `SvgFilterPrimitive`；本部分**不含 `.md`**，20 个全部是 `.cj`。其余 25 部分由主 Agent 顺序调度，合并以主 Agent 为准。）

- **审查日期**：2026-11-28
- **模块路径**：`f_svg`（本部分 20 个 `.cj`：2 个元素基类/API 实现、4 个滤镜模型实现、1 个滤镜缓冲、1 个椭圆、1 个异常、1 个外部文档契约、10 个 `*_test.cj`）
- **基线**：工作区快照（`git status --porcelain` 只有未跟踪的 `docs/review/`、`reviews/`；`git diff` 为空 ⇒ 全部问题记「存量」。注：`_dispatch.md` 记录的基线提交是 `120fd2542`，当前 HEAD 为 `f309f0b55`，仅记录不改判）
- **审查重点**：SVG 元素模型的解析/序列化边界与注入、递归与栈溢出、OOM、死代码、重复逻辑；滤镜原语（光照 / 投影 / 混合 / 合成 / 合并 / 色彩矩阵）的取值边界与内存放大
- **报告版本**：v1（第 14/26 部分分报告）

## 发现

### [一般][存量] #1 公共 DOM 编辑 API 不维护「单父 + 无环」不变量：可重复挂载、可成环（成环后 `svgRootOf` / `svgNotifyMutation` 死循环，序列化与包围盒递归爆栈）

- **位置**：`f_svg/src/SvgElement.cj:259-270`（`appendChild`）、`f_svg/src/SvgElement.cj:278-306`（`insertBefore`）、`f_svg/src/SvgElement.cj:336-338`（`appendElement`）
- **来源**：存量（blame `18a60454f0`，快照无 diff）
- **判据**：review-checklist §11「契约与实现不符」+ §4「自引用结构 / 间接递归」
- **证据**：静态确定 —— `appendChild` 只做 `children.add(node)` + `element.parent = this`（`:260-263`），既不从旧父节点摘除，也不检查 `this` 是否已是 `node` 的祖先；`insertBefore` 同样（`:285-289`）
- **描述**：三种可复现的结构破坏，全部来自公开 API 的常规用法（README:255 明确把 `appendChild` / `insertBefore` / `removeChild` 列为「节点编辑 支持」）：
  1. **重复挂载**：`p1.appendElement(x); p2.appendElement(x)` 后 `x` 同时出现在两棵子树的 `children` 里，`x.parent` 指向 `p2`。渲染会画两遍；对 `p1.removeChild(x)` 会把 `x.parent` 置 `None`，而 `p2.children` 仍持有它 —— 此后 `x` 的子节点变更不再通知 `p2` 所在的根（`svgNotifyMutation` 从 `None` 直接 `return`），`x.elementPath()`（`SvgElement.cj:377-384`）也退化成 `/<tag>[<同名计数>]`（`siblingIndex` 未命中时返回累计计数，`:601-619`）。
  2. **成环 → 挂死**：`a.appendElement(b); b.appendElement(a)` 之后，`svgRootOf`（`f_svg/src/SvgElementApi.cj:41-60`）的 `while (true)` 沿 `parent` 永远走不到 `None`；`svgNotifyMutation`（`f_svg/src/SvgMutation.cj:110-127`）同理。二者都是主路径（`getBBox` / `getCTM` / 任意 `setAttr` 都会进）。
  3. **成环 → 栈溢出**：`SvgElement.toString()`（`f_svg/src/SvgElement.cj:412-445`，递归在 `:433`）、`toXmlElement()`（`:386-409`，递归在 `:401`）、`text()` → `collectText`（`:624-633`）、`svgDescendants`（`SvgElementApi.cj:361-370`）、`svgContainerBBox`（`SvgElementApi.cj:165-189`）都是裸递归，环上直接无限递归。
- **建议**：`appendChild` / `insertBefore` 入口加两条廉价守卫：(a) 若 `node` 是元素且 `element.parent.isSome()`，先从其旧父的 `children` 里摘除（DOM 的 adopt 语义）；(b) 沿 `this` 的 `parent` 链上溯，命中 `node` 则抛 `SvgException(kind: InvalidValue)`（上溯深度不超过当前树深，成本可忽略）。两处共用一个私有 `wouldCreateCycle(node)` 辅助函数。补 3 条用例：重复挂载后旧父 `children` 不含该节点、成环抛异常、成环后序列化不再触发递归。

### [一般][存量] #2 滤镜链按原语数线性保留全部中间缓冲：默认 `maxPixels` 下单缓冲 256 MiB，20 个原语的链在最坏区域下峰值可达 GiB 级

- **位置**：`f_svg/src/SvgFilterBuffer.cj:28-35`（`pixels = Array<Byte>(width * height * 4, repeat: 0)`）、`f_svg/src/SvgFilterBuffer.cj:18-22`（类注释「每个原语产生新缓冲」）
- **来源**：存量（blame `ec44b3adcb`，快照无 diff）
- **判据**：review-checklist §5「无界容器 / 一次性物化」+ §7「删除中间副本」
- **证据**：静态确定（单缓冲尺寸的算术）+ 需实测（峰值 RSS 与同时存活缓冲数）
- **描述**：单缓冲字节数 = `width × height × 4`，`width × height` 只受 `SvgRenderOptions.maxPixels`（默认 `64 * 1024 * 1024` 像素，`f_svg/src/SvgBitmap.cj:230`；滤镜区域在分配前做了除法判定，`f_svg/src/SvgFilterRenderer.cj:127`）约束 ⇒ 单个缓冲上限 **64 Mi 像素 × 4 B = 256 MiB**。而执行链把每个原语的结果都存进 `named` 直到 `runChain` 返回（`f_svg/src/SvgFilterRenderer.cj:202-251`，`named[name] = result` 在 `:247`，`previous` 只是别名），`feMerge` 还会按名同时取多个。因此峰值 ≈（原语数 + 源图 + 输出 + 线性化副本）× 区域字节：4000×4000 区域（16 Mi 像素 ⇒ 64 MiB/缓冲）+ 20 个原语 ≈ 1.3 GiB；若区域顶到 `maxPixels`，单缓冲即 256 MiB。滤镜原语数量由文档内容决定（`maxElements` 是元素总数上限，量级远大于 20），区域由元素包围盒 / `filterUnits` 决定。
- **建议**：三层按代价递增：(a) `runChain` 维护每个缓冲的最后一次引用下标，原语消费完即从 `named` 释放（`result` 未被后续 `in`/`in2` 引用时可立刻丢弃）；(b) 无别名风险时原地写回 `previous`（`SvgFilterBuffer` 已提供 `pixels: Array<Byte>`，`blur` / `flood` / `colorMatrix` 这类逐像素原语可原地完成）；(c) 对整条链的累计分配量设上限，超限抛 `SvgException(kind: Limit)`，与现有 `maxPixels` 语义一致。验证：同输入下 `getAllocatedHeapSize()` 峰值 + RSS，改前改后对照。

### [一般][存量] #3 类型化属性缓存是「无同步的惰性写」：同一 `SvgDocument` 被多线程渲染时存在数据竞争（缓存字段无锁、无原子、无 volatile）

- **位置**：`f_svg/src/SvgElement.cj:28-41`（`SvgValueCache.get` 写 `cached` / `version` / `hasCached`）、`f_svg/src/SvgElement.cj:515-523`（`transformCacheOf` 惰性建缓存）；缓存实例遍布 `f_svg/src/SvgFilterPrimitive.cj:206/237-238/265-266/301-305/385/420-424/537-538`、`f_svg/src/SvgFilterLighting.cj:23-24/97/116-117/146-147/174-176/212-219`、`f_svg/src/SvgFilter.cj:27-32`、`f_svg/src/SvgEllipse.cj:20-23`
- **来源**：存量（blame `18a60454f0` / `5e98c82764` / `2cae19b829`，快照无 diff）
- **判据**：review-checklist §12.1「共享可变状态无保护 / 惰性初始化」
- **证据**：待确认（缺「是否允许跨线程共享同一文档」的契约；仓内无该声明，`grep -n "线程\|并发\|thread" README.md` 只命中 `README.md:37` 的 local-mode 说明）+ 静态确定（字段写路径无任何同步手段）
- **描述**：共享路径具体是：一个解析好的 `SvgDocument` 被多个 `SvgRenderer` 实例（每请求一个，以便各自持有 `warnings`）在不同线程并发 `render`；渲染读树时会调用 `element.transform`、`*Lighting.*`、`SvgFilter.*` 的 getter，首次访问即写各自元素的 `SvgValueCache`（`hasCached` / `version` / `cached` 三个普通字段，`SvgElement.cj:29-31`）。同一元素被两线程首次取同一属性时是「检查-然后-写入」，`?T` 里若为类实例（`SvgTransform`、`SvgPaint`）还存在非同步发布。`SvgElement.identity` 用了 `AtomicInt64`（`:622`），说明作者对多线程有所考虑，但缓存路径没有。
- **建议**：先定性再定改法。若明确不支持跨线程共享（推荐，代价最低）：在 `README.md` 的「限制」段落与 `SvgElement` 类注释写明「`SvgElement` / `SvgDocument` 非线程安全，跨线程使用需自行串行化或每线程各持一份」——这类声明缺失本身就是契约空白。若要求支持读并发：把类型化取值改为渲染期局部（`SvgComputedStyle` 已是渲染期构建，可扩展同款做法），或在解析完成时一次性预热全部缓存并冻结（`attributesVersion` 只在 mutation 时变，冻结后只读）。

### [轻微][存量] #4 `SvgFilterBuffer` 构造不校验 `width * height * 4` 的量级：不产出统一的 `Limit` 错误

- **位置**：`f_svg/src/SvgFilterBuffer.cj:28-35`
- **来源**：存量（blame `ec44b3adcb`）
- **判据**：review-checklist §11「缺少边界校验 / 错误类型不一致」
- **证据**：静态确定 —— 只有 `width <= 0 || height <= 0` 一个前置检查（`:29-31`），乘积直接进 `Array<Byte>(...)`
- **描述**：`SvgFilterBuffer` 是 `public` 类型，调用方可以传任意尺寸。乘积超过 `Int64` 上限时按仓颉默认溢出策略抛算术异常，而不是模块统一的 `SvgException(kind: Limit)`（对比 `f_svg/src/SvgBitmap.cj:281-282`、`f_svg/src/SvgFilterRenderer.cj:127-131` 都用 `Limit` 表达"太大"）。渲染主路径已有 `maxPixels` 前置检查，因此这是公共 API 的健壮性问题，不是当前渲染路径的缺陷。
- **建议**：构造里按"先除法后乘法"校验（`if (height > 0 && width > SVG_FILTER_BUFFER_MAX_BYTES / 4 / height) throw SvgException(..., kind: Limit)`），上限取一个模块常量并与 `maxPixels` 语义对齐；或在类注释写明"尺寸由调用方保证在 maxPixels 内"。

### [轻微][存量] #5 属性读写的模板逻辑在 4 个函数里逐行重复，已出现行为漂移（`??` 兜底与错误处理不一致）

- **位置**：`f_svg/src/SvgElement.cj:152-172`（`setAttr(name:value:)`）与 `:175-201`（`setAttr(namespace:local:value:)`）；`:204-223`（`removeAttr(namespace:local:)`）与 `:238-257`（`removeAttr(name:)`）；`f_svg/src/SvgFilterPrimitive.cj:272-287` / `:355-370` / `f_svg/src/SvgFilterLighting.cj:42-57`（`lighting-color` 默认值 `White`，另两处 `Black`）
- **来源**：存量（blame `18a60454f0` / `5e98c82764` / `2cae19b829`）
- **判据**：review-checklist §2「只改类型名 / 字面量复制」
- **证据**：静态确定（两两比对函数体的输入-输出-副作用：定位索引 → 保存旧值 → 替换/删除 → `attributesVersion++` → `svgNotifyMutation(Attribute, oldValue, newValue)`）
- **描述**：`setAttr` 两个重载除索引查找方式（`bareAttributeIndex` / `namespacedAttributeIndex`）和 `attributeName` 上报值外逐行对齐；`removeAttr` 两个重载同理。漂移已经发生：#8 里 `feGaussianBlur.stdDeviation` 的兜底分支不可达而 `feDropShadow.stdDeviation` 可走 `None` 分支，就是同一模板抄两遍导致的。paint 类 getter 三处（`flood-color` ×2、`lighting-color` ×1）也只差默认色常量。
- **建议**：抽两个内部辅助，落点在本文件（不新建 util 包）：`private func replaceAttributeAt(index: Int64, name: SvgAttribute, value: String, reported: String): Unit`（替换 + 版本自增 + 通知）与 `private func removeAttributeAt(index: Int64, reported: String): Bool`；paint 侧加 `internal func readPaintOr(element, name, fallback: SvgColor): SvgPaint`。合并时**保留**差异点并显式参数化：错误文案里上报的是本地名还是裸名、`removeAttr` 未命中返回 `false` 而不抛异常、`setAttr` 返回 `this` 以便链式调用。

### [轻微][存量] #6 `SvgFilterBuffer.fromBitmap` 与 `writeTo` 是同一套双向区域拷贝算法抄了两遍

- **位置**：`f_svg/src/SvgFilterBuffer.cj:37-65`（bitmap → buffer，补透明）与 `:75-95`（buffer → bitmap，裁剪）
- **来源**：存量（blame `ec44b3adcb`）
- **判据**：review-checklist §2「换控制流 / 只改类型名」
- **证据**：静态确定 —— 两层 `while` + 同一组边界判断（`:51-52` vs `:82-83`）+ 同一组 4 通道逐字节赋值（`:55-58` vs `:86-89`），只有源/目标角色互换
- **描述**：两段各约 20 行，唯一语义差异是「源侧越界补 0」（目标数组已初始化为 0）与「目标侧越界跳过」，即一份是 `blit(dst=新缓冲, src=bitmap)`、另一份是 `blit(dst=bitmap, src=缓冲)`。当前两份实现一致，但任一处的边界或通道顺序改动都会造成单向漂移（例如只改 `writeTo` 的 alpha 处理，读回与写出就不再互逆）。
- **建议**：抽 `private static func blit4(source: Array<Byte>, sourceWidth: Int64, sourceHeight: Int64, target: Array<Byte>, targetWidth: Int64, targetHeight: Int64, offsetX: Int64, offsetY: Int64)`，两个方法各留 3 行壳。拷贝语义差异（补 0 vs 跳过）在 `blit4` 里天然统一为"越界不写"，因为目标都已清零；`fromBitmap` 的缓冲由构造函数清零，`writeTo` 的目标位图无需补。补一条往返用例（`fromBitmap` → `writeTo` 原地回写后除越界区外逐字节相等）。

### [轻微][存量] #7 `SvgBlendMode.fromNameOrWarn` / `SvgCompositeOperator.fromNameOrWarn` 生产路径零引用，只有测试在用

- **位置**：`f_svg/src/SvgFilterPrimitive.cj:60-75`、`f_svg/src/SvgFilterPrimitive.cj:122-137`
- **来源**：存量（blame `11e6b765cc`）
- **判据**：review-checklist §1「仅测试使用 / 兼容残留」+ §2「只改类型名」
- **证据**：静态确定 —— 全仓 `grep -rn "fromNameOrWarn" f_svg/src` 只命中定义处与 `f_svg/src/SvgValueTypesM3_test.cj:106/113/119`；生产路径的校验与告警在 `f_svg/src/SvgBuilder.cj:557/562`（`fromName(...).isSome()` 判定，warning 由 builder 自己发）与 `SvgFilterPrimitive.cj:406/446`（getter 里直接 `fromName`，非法值静默回退默认）
- **描述**：两个函数体仅类型名与回退值（`Normal` / `Over`）、文案不同，属"只改类型名"的重复；且它们是 `internal`，仓内唯一消费者是测试 ⇒ 实际是上一版"取值即告警"设计的残留。按硬原则一，`public` 枚举本身没问题，问题在这两个 `internal` 辅助函数的去处。
- **建议**：二选一：(a) 删除两个 `fromNameOrWarn` 与对应测试，告警统一留在 `SvgBuilder`（现状就是这条路）；(b) 若希望 getter 侧也告警，把 `SvgBuilder` 的校验逻辑改成调用它们（一次共享实现），并补一个"非法 `mode` 在直接构造元素时也进 warning"的用例。保留现状则是两套告警路径并存，容易再次漂移。

### [轻微][存量] #8 `SvgFeGaussianBlur.stdDeviation` 的 `??` 兜底不可达，且错误处理与 `SvgFeDropShadow.stdDeviation` 不一致

- **位置**：`f_svg/src/SvgFilterPrimitive.cj:212-232`（`?? SvgNumberList(Array<Float64>())` 在 `:227`）对比 `f_svg/src/SvgFilterPrimitive.cj:332-352`（`:347` 的 `?? SvgNumberList([2.0])`）
- **来源**：存量（blame `5e98c82764`）
- **判据**：review-checklist §1「恒真恒假分支」+ §11「语义与注释不符」
- **证据**：静态确定 —— 前一处的 compute 闭包返回 `SvgNumberList`（`:220` / `:224` 两个分支都是非 `Option` 值，被隐式包成 `Some`），`get` 的返回值永远 `Some`，`:227` 的 `??` 永不生效；后一处的闭包显式返回 `None`（`:342` / `:344`）才有意义
- **描述**：两处"解析失败怎么办"的语义已经分叉：`feGaussianBlur` 非法值 → 空列表（渲染层按 σ=0 处理，无 warning，`f_svg/src/SvgFilterRenderer.cj:301-316` 只在负值时报 warning）；`feDropShadow` 非法值 → `None` → 回退 2（符合 `SvgDropShadowRenderM5_test.cj:141` 钉住的行为）。注释「1 或 2 个非负标准差；缺省单个 2」只写了投影那一侧。
- **建议**：把 `feGaussianBlur` 的 getter 改成与投影同构（解析失败 `None`、外层 `??` 给该原语的规范缺省值 0），并删掉不可达的 `?? SvgNumberList(Array<Float64>())`；若坚持"非法即空列表"，请在 getter 注释里写明与投影的差异，避免下一个读者按对称性改错。

### [轻微][存量] #9 序列化不校验 PI 内容与标签名：`toString()` 可产出非良构 XML

- **位置**：`f_svg/src/SvgElement.cj:412-445`（`:437` `out.append("<?${target} ${data}?>")`、`:418-419` / `:440-442` 直接拼 `literalName`）
- **来源**：存量（blame `3ec7f9f27c`）
- **判据**：review-checklist §11「边界 / 语义与注释不符」，安全性维度（转义边界）
- **证据**：静态确定 —— 属性值走 `escapeSvgAttribute`（`:424`）、文本走 `escapeSvgText`（`:434`），CDATA 与注释都做了合法化（`serializeSvgCData` `:665-685`、`serializeSvgComment` `:688-703`），唯独 PI 与标签名是原样输出
- **描述**：`SvgElement(tag: "a><script>")` 或 `SvgNode.PiNode("p", "x?>y")` 序列化后得到 `<>` / `?>` 提前闭合，输出不再是良构 XML；若下游把它当 HTML 插入，标签名注入即可产生标签结构（属性与文本已转义，故不构成完整的 XSS 链，但契约"序列化结果是合法 XML"被破坏）。解析路径不受影响——`f_xml` 词法保证了输入侧的名字与 PI 合法。
- **建议**：`toString` 前对 `literalName` 做一次名字合法性校验（复用 `f_xml` 的 `QName` 校验，失败时抛 `SvgException(kind: InvalidValue)`）；PI 分支按 XML 规范处理 `?>`（拆成 `? >` 或直接拒绝）。若定为"调用方保证"，就在 `SvgElement` 类注释写明。

### [轻微][存量] #10 可读性残留：过期 TODO、结构体定义行格式错乱、注释措辞与行为不符、无用中间变量

- **位置**：`f_svg/src/SvgFilterPrimitive.cj:177`（`// TODO(M3-1/M3-2): 滤镜原语基类与八个 fe* 原语模型。`）、`f_svg/src/SvgFilterLighting.cj:317`（`private struct M4LightVector {    let x: Float64`）、`f_svg/src/SvgFilterLighting.cj:376`、`:387`（`let dz = lz`）、`f_svg/src/SvgElement.cj:498-499`（注释「后代中 `class` 含指定词的第一个集合」）、`f_svg/src/SvgFilterLighting.cj:444-455`（`constant` / `exponent` 先赋默认值再按类型改写，`specularLighting` 形参只在 `case _` 用）
- **来源**：存量（blame `a708c3ee4a` / `2cae19b829` / `18a60454f0`）
- **判据**：review-checklist §3「占位 TODO」+ §10「命名 / 可读性」
- **证据**：静态确定
- **描述**：`:177` 的 TODO 说"待做"，其下方 40 行后即已实现 9 个原语类（`feGaussianBlur`…`feTile`），且数量写的是"八个"；`M4LightVector` 的大括号与首个字段挤在一行（`cjfmt` 会重排）；`dz = lz` 是从点光源代码复制到聚光灯时的残留，后面直接用的是 `dz`；`getElementsByClassName` 注释"第一个集合"读起来像"只返回第一个"，实现返回全部（`SvgElementApi.cj:373-388`，四处测试均按"全部"断言）。
- **建议**：删掉过期 TODO 或改成"设计记录：原语模型见本文件下半部"；`M4LightVector` 按标准缩进重排；`dz` 直接用 `lz`；注释改为「后代中 `class` 含指定词的**全部**元素（文档顺序，不含自身）」；`lightingFilterBuffer` 的 `constant` / `exponent` 改为在 `match` 内一次算出（`(constant, exponent, diffuse)` 三元组），形参 `specularLighting` 可在 `case _` 里保留但在注释说明它只服务于自定义子类。

### [轻微][存量] #11 定义型标签排除表不含 `symbol`：带子元素的 `<symbol>` 会从 `getBBox()` 返回包围盒

- **位置**：`f_svg/src/SvgElementApi.cj:123-128`（`case "defs" | "marker" | ... | "stop" => return None`），`symbol` 被映射为 `SvgContainer`（`f_svg/src/SvgTag.cj:69-71`）从而落到 `:145-146` 的容器分支
- **来源**：存量（blame `2ef62b12e7` / `ca72d35c36`）
- **判据**：review-checklist §11「与规格 / README 冲突」
- **证据**：静态确定（代码路径）；规格解读待确认
- **描述**：`<symbol>` 不会被直接渲染，规格上对它的 `getBBox()` 应得到空矩形；当前实现会把子元素的并集返回。现有用例只覆盖空 `<symbol>`（`f_svg/src/SvgElementApiM5_test.cj:118-125`，空子节点自然得 `None`），所以没暴露。`svgUseBBox` 对 `symbol` 是**显式**调 `svgContainerBBox`（`SvgElementApi.cj:225-229`），因此把 `symbol` 加进排除表不会破坏 `<use>` 展开。
- **建议**：把 `"symbol"` 加入 `:125-126` 的排除列表（`view` 也建议一并核对：`SvgView` 走 `SvgGeometry.bounds` 目前返回 `None`，属巧合而非显式约定）；补一条 `<symbol><rect/></symbol>` 的 `getBBox().isNone()` 用例。

## 优化可行性方案

> 都不是缺陷，是"还能更好"。以下全部**无改前/改后对照数据**，只能作为待验证方向，不进 `todo.md` / `tasks.md`。

### [堆内存] `serializeSvgCData` 把整段文本物化成 `ArrayList<Rune>` 只为做三字符前瞻

- **现状**：`f_svg/src/SvgElement.cj:665-685` 先把 `text.runes()` 全量塞进 `ArrayList<Rune>`（每元素 ≥ 4 B + 扩容冗余），再按下标判断 `]]>`。CDATA 长度由调用方文本决定（`SvgElement.toString()` 输出大段 CDATA 时为 O(文本长度) 的额外整份副本）
- **方案**：改成单遍迭代 + 长度 3 的滑动窗口（或 `String.indexOf("]]>")` 直接找分隔点，命中处插 `]]]]><![CDATA[>`，其余原样 append）
- **预期**：序列化期间额外堆占用从 O(n) 降到 O(1)；大 CDATA（如内联 base64 文本）场景峰值明显下降
- **代价**：实现从"按下标"改成"按游标/查找"，逻辑分支略增；输出必须逐字节不变（现有测试 `SvgElement_test.cj:221-235` 已钉住三种边界）
- **验证**：同文档序列化 100 次，对比 `getAllocatedHeapSize()` 峰值与 RSS；输出与现实现逐字节比对
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] 滤镜中间缓冲的复用与提前释放

- **现状**：见发现 #2——`named` 持到链结束，单缓冲上限 256 MiB；`SvgFilterBuffer` 类注释（`f_svg/src/SvgFilterBuffer.cj:18-22`）把"每个原语产生新缓冲"定为设计
- **方案**：先做"最后引用计数"释放（改动集中在 `f_svg/src/SvgFilterRenderer.cj:196-252`，本部分文件只需保证 `SvgFilterBuffer` 可被覆盖写）；再评估逐像素原语（`flood` / `colorMatrix` / `blur`）原地写回
- **预期**：N 原语链的峰值从 (N+1)×区域字节降到约 2–3×区域字节
- **代价**：原地写需要别名分析（`in` / `in2` / `SourceGraphic` 可能指向同一缓冲），判断错会静默产生错误像素；`feMerge` 的名引用使"最后引用"要按 `in` / `in2` 名字静态算
- **验证**：固定 20 原语 + 4000×4000 区域的基准，测 `getAllocatedHeapSize()` 峰值、RSS、单帧耗时；像素输出与现实现逐字节相等
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `getBBox` / `getCTM` / `getScreenCTM` 每次调用都重建整棵计算样式树

- **现状**：`f_svg/src/SvgElement.cj:459-464`（`getBBox` 里 `SvgStyleResolver().compute(root, ...)`）与 `f_svg/src/SvgElementApi.cj:313`（`svgElementCtm`）、`:343`（`svgElementScreenCtm`）各自新建样式树；element 数量为 n 时批量测量 m 个元素是 O(m·n)
- **方案**：给 `SvgDocument` / `SvgRoot` 增加可复用的样式树槽位（按 `attributesVersion` 和媒体尺寸做键，命中即复用），或提供批量 API `measureAll(elements)` 只算一次树
- **预期**：批量测量从 O(m·n) 降到 O(n + m)（数量级收益，但当前无实测数据支撑具体降幅）
- **代价**：样式树缓存要处理 DOM 变更失效（`attributesVersion` 只到单元素粒度，子树变更需要冒泡到根）与媒体尺寸变化；缓存生命周期变长，需与 §7 的"缩短生命周期"取向权衡
- **验证**：对 2000 元素文档逐元素 `getBBox()`，`cjprof record` 看 `SvgStyleResolver.compute` 自耗时占比；改后同输入对照
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `setAttr` 双次扫描属性表；`svgNotifyMutation` 在无监听器时仍逐级上溯

- **现状**：`f_svg/src/SvgElement.cj:153-154` 先 `attr(name)` 再 `bareAttributeIndex(name)`，同一张 `attributes` 扫两遍（属性多时 2×O(k)）；`f_svg/src/SvgMutation.cj:110-127` 每次属性写入都沿 `parent` 链走到根才 `return`，而 `SvgDocument` 的 hub 通常在但 `listeners` 为空（`f_svg/src/SvgMutation.cj:76`，只有显式 `addMutationListener` 才非空）
- **方案**：`setAttr` 用一次查找同时拿到 `index` 与 `oldValue`（新增 `private func locate(name) -> (Int64, ?String)`）；`svgNotifyMutation` 在根上维护 `hasListeners` 计数（`add` / `remove` 时更新），无监听器时 element 侧直接短路（元素缓存一个 `?SvgMutationHub` 引用亦可）
- **预期**：动画逐帧写样式的路径（`SvgTimeline.cj:1341` → `svgSetInlineStyleProperty` → `setAttr`）每帧少一次属性扫描 + 一次到根的上溯；深度大的文档收益更明显
- **代价**：`hasListeners` 需要与 `listeners` 同步维护（单线程 DOM 语义下无额外锁）；缓存 hub 引用要在 `mutationHub` 赋值处一并失效（`SvgDocument.cj:37`）
- **验证**：60 帧动画写 1 万个属性，`cjprof` 看 `svgNotifyMutation` / `bareAttributeIndex` 自耗时；改前改后同输入对照
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 光照滤镜逐像素经"带版本校验的 getter"取光源参数

- **现状**：`f_svg/src/SvgFilterLighting.cj:474` 每像素调 `m4LightFor`，内部按光源类型每次读 `azimuth` / `elevation`（`:362-363`）或 `x/y/z` + `pointsAt*` + `limitingConeAngle`（`:382-391`），每个属性都是一次 `SvgValueCache.get`（版本比较 + `Option` 匹配）
- **方案**：在 `lightingFilterBuffer` 进入像素循环前把光源参数解构成本地结构（`M4LightSpec`），循环内只读局部变量
- **预期**：每像素从 ~3–8 次 cache 查询降到 0；具体降幅取决于像素规模（无数据）
- **代价**：新增一个内部 struct + 一处 `match`，逻辑重复一次"取值"，但与 `m4LightFor` 合并后可只留一份
- **验证**：4000×4000 缓冲的 `feDiffuseLighting`，`cjprof` 看 `SvgValueCache.get` 与 `m4LightFor` 自耗时占比
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 批量 `getBBox()` 的耗时主要花在重复构建样式树（O(m·n)） | `f_svg/src/SvgElement.cj:459-464`、`f_svg/src/SvgElementApi.cj:313` | `SvgStyleResolver.compute` 自耗时占比；m、n 的实测值 | 2000 元素文档逐元素 `getBBox()`，`cjprof record` + 分段计时（构建 vs 求值） |
| 2 | 大区域光照滤镜的热点在逐像素 getter 与 `m4LightFor` | `f_svg/src/SvgFilterLighting.cj:460-514` | 每像素成本拆分（getter / 法线 / 光照 / 写回） | 4000×4000 缓冲跑 `feDiffuseLighting`，`-O2`，`cjprof` 看自耗时；同时给 800×800 对照看是否随像素线性 |
| 3 | 动画逐帧路径上 `svgNotifyMutation` 与属性双扫描构成可观开销 | `f_svg/src/SvgMutation.cj:110-127`、`f_svg/src/SvgElement.cj:152-172` | 每帧写入次数、`svgNotifyMutation` 自耗时、`bareAttributeIndex` 调用次数 | 60 帧 × 1 万属性写入，`cjprof` + 计数埋点；开/关监听器各跑一遍 |
| 4 | 多原语滤镜链的峰值内存由"全部中间缓冲"主导（发现 #2） | `f_svg/src/SvgFilterRenderer.cj:202-251`、`f_svg/src/SvgFilterBuffer.cj:34` | 链执行期间同时存活的缓冲数、峰值 RSS | 20 原语 + 4000×4000 区域的渲染，采 `getAllocatedHeapSize()` 峰值、RSS、每缓冲命中日志；同输入改 5 原语对照 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_svg/src/SvgDropShadowM5_test.cj` | .cj | ✅ | 投影类型化取值/缺省/往返/标签注册 5 例；`m5FirstPrimitive` 为跨文件共用 helper |
| 2 | `f_svg/src/SvgDropShadowRenderM5_test.cj` | .cj | ✅ | 8 例像素级断言（与手写链逐字节一致、负 σ 回退、非法 flood-color 回退+告警）；`m5RenderSvg` 被 `SvgElementBlendM5_test` 复用 |
| 3 | `f_svg/src/SvgElement.cj` | .cj | ✅ | 元素基类：属性/子节点/序列化/包围盒入口；发现 #1 #3 #5 #9 #10，方案 O1 O4 |
| 4 | `f_svg/src/SvgElementApi.cj` | .cj | ✅ | `getBBox`/`getCTM`/选择器查询实现；发现 #11，方案 O3 |
| 5 | `f_svg/src/SvgElementApiM5_test.cj` | .cj | ✅ | 13 例包围盒/CTM/路径长度/查询；空 `<symbol>` 用例见 #11 说明 |
| 6 | `f_svg/src/SvgElementBlendM5_test.cj` | .cj | ✅ | 混合组落到 GroupBegin 的显示列表断言 + 像素等价 |
| 7 | `f_svg/src/SvgElementFilterM3_test.cj` | .cj | ✅ | 组/元素滤镜、fill+stroke 只滤一次、marker 参与、缺字形不消失 |
| 8 | `f_svg/src/SvgElement_test.cj` | .cj | ✅ | 14 例基础语义；`namespacePrefixAllocation` 钉住 `ns1`/`ns2` 与 xlink/xml 前缀 |
| 9 | `f_svg/src/SvgEllipse.cj` | .cj | ✅ | 4 个长度属性 + 缓存，无问题 |
| 10 | `f_svg/src/SvgException.cj` | .cj | ✅ | 5 类错误 + 位置拼装；`withPosition` 私有静态有引用 |
| 11 | `f_svg/src/SvgException_test.cj` | .cj | ✅ | 4 例（枚举互斥、无/有位置、0,0 无后缀） |
| 12 | `f_svg/src/SvgExternalDocument.cj` | .cj | ✅ | 契约 + 3 个上限常量；`SVG_EXTERNAL_MAX_BYTES`/`SVG_EXTERNAL_MAX_DEPTH`/`svgExternalDepthAllows`/`SVG_USE_MAX_DEPTH` 均在 `SvgRenderTree.cj:878/914/981` 有引用，非死代码 |
| 13 | `f_svg/src/SvgExternalDocumentM6_test.cj` | .cj | ✅ | 13 例（单次调用、片段、无 provider、字节上限、不递归、环、data: 旁路） |
| 14 | `f_svg/src/SvgFilter.cj` | .cj | ✅ | 6 个属性 + `primitives` 过滤；属性缺省 `None` 与注释一致 |
| 15 | `f_svg/src/SvgFilterBuffer.cj` | .cj | ✅ | 发现 #2 #4 #6，方案 O2 |
| 16 | `f_svg/src/SvgFilterLighting.cj` | .cj | ✅ | 光照模型 + 逐像素求值；发现 #10，方案 O5 |
| 17 | `f_svg/src/SvgFilterLightingM4_test.cj` | .cj | ✅ | 6 例（平行/点/聚光、峰值 ≤255、缺光源与 NaN 降级、链式确定性） |
| 18 | `f_svg/src/SvgFilterModelM4_test.cj` | .cj | ✅ | 15 个 fe* 类型映射、缺省值、读写回写、标签注册 |
| 19 | `f_svg/src/SvgFilterNoiseM4_test.cj` | .cj | ✅ | 湍流/位移/feImage/解码预算 4 组；`M4MemoryProvider` 实现接口故非死代码 |
| 20 | `f_svg/src/SvgFilterPrimitive.cj` | .cj | ✅ | 9 个原语模型；发现 #5 #7 #8 #10，以及 `??` 不可达 |

合计：`.cj` 20 个 / `.md` 0 个 / 共 20 个，全部读完（与 `files/f_svg.part14.txt` 20 行一一对应）。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 5 | 正确性：#1 #11；可读性：#10；安全性（序列化边界）：#9；语言特性：`as` 返回 `Option` 已查证（`typecast.md:54`），测试里 `(x as T).getOrThrow()` 合法，不是缺陷；设计合理性未命中（元素/原语/缓冲三层职责清晰，滤镜只依赖 `SvgFilterBuffer`） |
| §1 死代码 | 1 | #7（`internal fromNameOrWarn` ×2 仅测试引用）。逐个核过：`private` 的 `transformCacheOf` / `bareAttributeIndex` / `namespacedAttributeIndex` / `prefixFor` / `prefixInUse` / `siblingIndex` / `collectText` / `parseTransformOrNone` / `findSvgStyleColon` / `svgContainerBBox` / `svgChildTransform` / `svgUseBBox` / `applyBBoxClip` / `nestedSvgClipRect` / `collectSvgDescendants` / `readLightingFloat` / `M4LightVector` / `m4Normalize` / `m4HeightAt` / `m4LightFor` / `withPosition` 均有调用者；`internal` 的 `SvgValueCache` / `writeOptionalAttribute` / `appendAttribute` / `attributesVersion` / `mutationHub` / `rawQName` / `identity` / `readSvgHref` / `writeSvgHref` / `serializeSvgCData` / `serializeSvgComment` / `escapeSvgText` / `escapeSvgAttribute` / `svgRootOf` / `svgStyleFor` / `svgBBoxOf` / `lightingFilterBuffer` / `fromBitmap` / `copy` / `writeTo` / `invalidValue` / `syntaxError` / 四个外部文档常量与 `svgExternalDepthAllows` 均在本包内有引用；`public` 且对外可达的 `SvgElement` 成员、`SvgFeMerge.inputs`（仓内仅 `SvgFilter_test.cj:108` 用）、`SvgFeMergeNode` 不判死代码 |
| §2 重复逻辑 | 3 | #5（属性读写 4 函数 + paint 默认值 3 处）、#6（`fromBitmap` / `writeTo`）、#7（`fromNameOrWarn` ×2）。已两两比对同文件 20 个函数体：5 个枚举的 `operator ==` 手写表在语言层没有可用的通用替代（仓颉文档未给枚举自动派生 `Equatable` 的机制，`typecast.md` / `enum.md` 均无相关说明），合并不成立，按"不能乱上泛型"不报；`attr` 两个重载、`insertBefore` 两个重载差异是业务要求（`None` 追加 / 抛错）不报 |
| §3 空实现 | 1 | #10 的过期 `TODO`（`SvgFilterPrimitive.cj:177`）。无空函数体、无 `catch {}`：`parseTransformOrNone` / `tryParseSvgPaint` 的 `catch` 返回 `None` 是"非法值降级"的显式契约（`SvgElement_test.cj:186-192` 有断言） |
| §4 栈溢出 | 1 | #1 的第 3 条（成环）。解析路径有界：`SvgSecurityOptions.maxDepth` 默认 512（`SvgOptions.cj:66`），`SvgBuilder.cj:127` / `:660-672` 双重拦截，故"解析得到的树"递归深度 ≤512，不单列；程序化构造无上限（`appendElement` 无深度参数），与 #1 同根因故合并 |
| §5 OOM | 1 | #2（缓冲按原语数线性增长，单缓冲 256 MiB）。已核对现有拒绝路径：`SvgBitmap.cj:281`（输出像素）、`SvgFilterRenderer.cj:127`（滤镜区域）、`SvgRenderTree.cj:665/683`（foreignObject）、`SVG_EXTERNAL_MAX_BYTES` 16 MiB（`SvgRenderTree.cj:914`） |
| §6.1 热点瓶颈 | 0 | 无 profile / bench 数据，未成立；已转「待验证假设」1–4（含函数、输入规模、采集工具） |
| §6.2 大粒度锁 | 0 | 本部分 20 个文件无 `synchronized` / `Mutex` / 锁内 I/O；`SvgMutationHub` 无线程同步要求（见 §12 行） |
| §6.3 并发串行 | 0 | 无 `spawn` / `Future` / 线程池；光照与滤镜都是单线程循环 |
| §6.4 低效算法 | 1 | 方案 O3（`getBBox`/`getCTM` 每次重建样式树，O(m·n)）。`m4HeightAt` 的边界判断、`blur` 的滑动窗口等均未发现顺序/复杂度缺陷 |
| §7 降堆内存方案 | 2 | O1（CDATA 全量 `ArrayList<Rune>`）、O2（滤镜中间缓冲），均标 `无基线（待验证）` |
| §8 降 CPU 方案 | 3 | O3（样式树重建）、O4（属性双扫描 + 通知上溯）、O5（逐像素 getter），均标 `无基线（待验证）` |
| §9 local mode 可行性 | 0 | 模块已整体开启 local mode（`README.md:37`），但本部分的临时对象都是 std 容器（`ArrayList<Rune>`、`ArrayList<String>`、`ArrayList<SvgElement>`），std API 无对应 mode 重载 ⇒ 改造需重建容器类型，且收益必须用峰值内存对照证明；当前无数据，不写成建议 |
| §11 现有代码的 BUG（存量） | 3 | #1（DOM 不变量）、#4（缓冲尺寸边界）、#11（`symbol` 包围盒）；另 #8 #9 兼属边界/语义。均核对过调用链与相邻实现，未发现越界、除零、资源不对称（本部分无文件/句柄/原生内存） |
| §12 并发安全与锁粒度 | 1 | #3（类型化缓存无同步惰性写，共享路径=同一文档被多线程渲染，缺同步手段=无锁/无原子）。锁粒度维度未命中：本部分无锁可谈；`AtomicInt64` 只用于 `identity` 自增，用法正确 |
| §14 功能完备性与 README 覆盖 | 0 | 逐个对照：`SvgElement`、`SvgBBoxOptions`（`README.md:577`）、`SvgEllipse`、`SvgException`/`SvgErrorKind`、`SvgExternalDocumentProvider`（`README.md:188`）、`SvgFilter`、`SvgFilterBuffer`（`:595`）、`SvgLightingPrimitive`（`:607`）、9 个 fe*、`svgSetInlineStyleProperty`（`:559`）均已进 README；`fromBitmap`/`copy`/`writeTo` 是 `internal`，不必文档化。未发现"承诺但未实现" |
| 文件覆盖（§13 等） | 20/20 | 本部分无 `.md`，故 §13 文档一致性无适用对象；20 个 `.cj` 全部读完并逐个给结论 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 3 |
| 轻微 | 8 |
| 优化方案（堆内存 / CPU） | 2 / 3 |

存量 11 条（本部分全部为存量，快照模式无 diff），是否纳入修复待用户决定。

## 总评

本部分是 f_svg 的「元素模型 + 滤镜模型」核心：`SvgElement` 的"原始属性为唯一事实源 + 按 `attributesVersion` 失效的类型化缓存"设计干净，序列化对文本/属性/CDATA/注释四个注入面都做了处理（只有 PI 与标签名漏了，见 #9），9 个滤镜原语与 3 个光源的取值缺省值与 SVG 规范逐条对得上，10 个测试文件覆盖到了像素级等价、非有限值降级、告警文案和预算上限，质量在本仓属于中上。

主要风险集中在三个地方，都不是单文件笔误而是"契约缺口"：

1. **DOM 结构不变量无人维护**（#1）—— `appendChild`/`insertBefore` 既不接管旧父也不防环，重复挂载静默产生双份渲染，成环则让主路径的 `svgRootOf` 挂死、序列化爆栈。这是本部分唯一能稳定复现"挂死/崩溃"的路径，且触发只需要公开 API 的常规误用，建议优先补两条守卫 + 3 条用例。
2. **滤镜内存随原语数线性放大**（#2）—— 单缓冲上限 256 MiB 是既有 `maxPixels` 设计的结果，但 `runChain` 把每个中间结果都留到最后，20 原语链路在 4000×4000 区域下就是 GiB 级峰值。这一条要有峰值数据才好定级，先作为优化方案（O2）推进。
3. **并发契约空白**（#3）—— 缓存是无同步惰性写，而 README 对线程安全一字未提。最省的修法不是加锁，而是在 README/类注释里明确"非线程安全"。

其余 8 条轻微项（属性模板重复、双向拷贝重复、仅测试的 `fromNameOrWarn`、不可达的 `??`、`symbol` 包围盒、注释与格式残留）可以排期批量清理：#5 + #6 + #7 合并后大约能删掉 70 行重复代码，同时消掉已经发生的两处行为漂移。性能方向（O3–O5）都缺基线，按纪律只进「待验证假设」，不进修复清单。
