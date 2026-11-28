# f_svg 模块审查报告（第 21/26 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_svg/src`（本部分 9 个源文件，均为 `.cj`）
- **基线**：工作区快照（`120fd2542`，`git diff` 为空）⇒ 所有问题来源为「存量」
- **审查重点**：SVG/XML 解析与序列化边界、注入与转义、递归与栈溢出、OOM、死代码、重复逻辑
- **报告版本**：分部分报告 v1（供主 Agent 合并为 `f_svg_v2.md`；本文件不写 `docs/review/`）

本部分覆盖渲染树构建与光栅化入口：`SvgRenderTree`（显示列表构建、use/symbol/嵌套 svg 展开、marker 实例化、
外部文档解析）、`SvgRenderer`（逐指令光栅化、离屏层、clip/mask/filter 应用、image 取样）、渲染提示枚举
（`SvgRenderingHints`）、`SvgRoot` 属性包装，以及对应的 5 个测试文件。解析侧（`SvgParser` / `SvgBuilder` /
`SvgWriter`）、`SvgClipMask` / `SvgPatternSampler` / `SvgFilterRenderer` 主体不在本部分，只在追调用链时引用。

## 发现

### [一般][存量] #1 `<use>` 的 `transform` 被丢弃；`opacity` / `clip-path` / `mask` / `filter` 同样不生效

- **位置**：`f_svg/src/SvgRenderTree.cj:533-535`（`case use: SvgUse => this.expandUse(...)`）、`:1006-1008`（只乘 `translate(x, y)`）、`:1067-1075`（只乘**目标**元素的变换）；对照 `:558-566`（text）、`:1118-1125`（shape）、`:1404-1412`（image）、`:736-744`（container）都乘了自身 `elementTransformMatrix`
- **来源**：存量（工作区快照；`git diff` 为空，非本次改动）
- **判据**：review-checklist §11（契约与实现不符）、§14（功能完备性）；承诺源 `f_svg/README.md:127`「`transform` 支持 `translate`/`scale`/`rotate`/…」、`README.md:150`「`display` / `visibility` / `opacity` 支持」
- **证据**：静态确定 —— `expandUse`（`:955-1102`）从入口到结束没有调用 `elementTransformMatrix(use, …)`，也没有任何 `resolveUrlRef(style.get("clip-path"/"mask"/"filter"))` 或 opacity 分层；`walkElement` 取到的 `style`（`:522-528`）只用于 `display:none` 判断，随后 `case use` 直接 `return`，style 再未被消费
- **描述**：`<use transform="translate(10,20) scale(2)"/>`、`<use opacity="0.5"/>`、`<use clip-path="url(#c)"/>` 全部静默无效，与同文档里 `g` / 图形元素的行为不一致。其中 `opacity` / `clip-path` / `mask` / `mix-blend-mode` 一项已在 `f_svg/doc/spec/add-f-svg-m4/verification-2.md:110` 被记录（属"已知限制"），但 **`transform` 既没有被记录，也没进 README 的"部分支持"行**；同时 `SvgElementApi.svgUseBBox`（`f_svg/src/SvgElementApi.cj:207-252`）也不含 use 自身变换，因此渲染与 bbox 两条路径一致地错，缺少互相校验的机会
- **建议**：`expandUse` 开头补一次 `matrix = context.matrix.multiply(elementTransformMatrix(use, style: style, bounds: targetBounds, …))`（几何先于 `translate(x,y)` 还是之后需按 SVG 规范确认，建议补一条像素断言固定顺序）；`opacity` / `clip-path` / `mask` / `filter` 用与 `walkContainer:751-801` 相同的元素组包装（可复用 `appendFilteredGroupBegin:1244`）；若本轮不做，至少在 README 的 `use` 行明确写出不支持项，避免与 `transform` 那一行冲突

### [一般][存量] #2 嵌套 `<svg>` 的 `opacity` / `clip-path` / `mask` / `filter` 不生效

- **位置**：`f_svg/src/SvgRenderTree.cj:530-532`（`case svg: SvgRoot => this.walkNestedSvg(...)`）、`:812-874`（整个 `walkNestedSvg`）
- **来源**：存量
- **判据**：review-checklist §11（同一属性对不同元素行为不一致）、§14；对照 `:745-753`（`walkContainer` 的 `grouped` 判据同时看 opacity / clip-path / mask / filter / clip / blend / isolation）
- **证据**：静态确定 —— `walkNestedSvg` 只做视口计算（`:820-831`）、`overflow` 裁剪与 quad（`:834-857`）、`depth+1`（`:865`），全程没有 `style.opacity()`、没有 `resolveUrlRef(style.get("clip-path"/"mask"/"filter"))`、没有 `blendMode` / `isolated`
- **描述**：`<svg opacity="0.5">`、`<svg clip-path="url(#c)">`、`<svg filter="url(#f)">` 静默无效；`transform` / `display` 则正常（`:823-831`、`:526`），因此是"部分属性可用"的中间态，最容易让使用者误判。仓内无覆盖：`grep "<svg[^>]*opacity"`/`"<svg[^>]*transform"` 在 `*_test.cj` 均无命中（旋转裁剪用例只测 overflow）
- **建议**：把 `walkNestedSvg` 的收尾与 `walkContainer` 对齐——先按 `svg` 自身样式建组（opacity / clip / mask / filter / blend / isolation），再 `walkChildren`；`clip` 与视口裁剪的先后顺序需与 `applyEffects:693-759` 现有次序保持一致

### [一般][存量] #3 外部文档缓存按 `href` 无界累积，单次构建可放大到 N×16 MiB

- **位置**：`f_svg/src/SvgRenderTree.cj:254-257`（`externalDocuments` / `missingExternalDocuments`）、`:900-931`（命中/未命中分支）、`:914-919`（单文档 16 MiB 上限）
- **来源**：存量
- **判据**：review-checklist §5（无界容器 / 按不可信输入累积）、§7（生命周期与上限）
- **证据**：静态确定 —— 上限只有"单文档字节"（`f_svg/src/SvgExternalDocument.cj:24` `SVG_EXTERNAL_MAX_BYTES = 16 MiB`）与"引用深度 4"（同文件 `:33`、`svgExternalDepthAllows`），代码里没有任何"不同 href 数量"或"累计字节"的计数；解析成功即 `this.externalDocuments[href] = parsed`（`:924`）并保留到 builder 生命周期结束
- **描述**：`href` 来自不可信 SVG，provider 由宿主注入。100 个不同 href 各自 16 MiB 的文档 ⇒ builder 内常驻约 1.6 GiB（每份还含完整 `SvgElement` 树与 `SvgStylesheet`），且 `SvgParser` 的 `maxElements = 1,000,000` 允许单文档本身很大；`missingExternalDocuments`（`:910`）同样只增不减，只是对象很小。这是"有单点上限、无聚合上限"的典型放大面
- **建议**：复用 `SvgDecodeBudget`（`SvgImageResource` 已在用）给外部文档加"累计字节 + 文档数"预算，超限按 `SvgException(kind: Limit)` 抛；或按 `svgExternalDepthAllows` 的风格新增 `SVG_EXTERNAL_MAX_DOCUMENTS`（如 8）并在超限时 warning + 停止解析

### [一般][存量] #4 每个分组一条整画布离屏层，层数 × 画布无聚合上限

- **位置**：`f_svg/src/SvgRenderer.cj:144-160`（`GroupBegin` → `SvgGroupCompositor.createLayer(list.width, list.height, …)`）、`:221-253`（非组指令的 `needsLayer` 分支同样整画布）、层分配实现 `f_svg/src/SvgClipMask.cj:155-158`（`createLayer` → `SvgBitmap(width, height)`）
- **来源**：存量
- **判据**：review-checklist §5（按画布规模物化）、§7（内存上限）
- **证据**：静态确定（按公式可算）—— 单层字节 = `width × height × 4`；`frames` 是后进先出栈（`:146`、`:165`），外层层在子组渲染期间**保持存活**，峰值 ≈ 打开层数 × 单层；`SvgRenderOptions.maxPixels` 默认 `64 * 1024 * 1024`（`f_svg/src/SvgBitmap.cj:230`，`SvgRenderOptionsM4_test.cj:33` 断言）⇒ 满配单层 256 MiB；文档深度上限 512（`f_svg/src/SvgOptions.cj:66`），`<g opacity="0.9">` 只需嵌套 8 层就到 2 GiB 量级
- **描述**：不是"无界增长"（有 `maxPixels` 与 `maxDepth` 两条拒绝路径），但缺"层数 × 画布"的聚合预算：`opacity < 1`、`isolation:isolate`、`mix-blend-mode`、以及**只要有 `clipRect` 的容器**（`walkContainer:751` 的 `context.clipRect.isSome()`）都会触发建层，而 `opacity`/`clip` 是常见写法，文档又由不可信输入控制。深嵌套 + 大画布时先 OOM 而非先触发 `maxPixels`
- **建议**：层尺寸改为"命令包围盒与画布求交"后分配（`GroupBegin` 已带 `bounds`/`clipBounds`，无包围盒时退回整画布），合成时带偏移：`composite(target, layer, opacity, offsetX, offsetY, mode)`；同时加"离屏层累计字节"预算（如 `maxPixels × 2`），超限按 `Limit` 抛，避免用 OOM 当拒绝路径

### [一般][存量] #5 渲染遍历对普通容器嵌套无深度上限，程序化深树可致栈溢出

- **位置**：`f_svg/src/SvgRenderTree.cj:504-521`（`walkChildren` ↔ `walkElement` 互递归）、`:1517-1536`（`findSvgElementById`）、`:1789-1813`（`findSvgElementPath`）、`:1586-1680`（`markerContentFitsIn`）
- **来源**：存量
- **判据**：review-checklist §4（无界递归 / 深度由输入决定）
- **证据**：静态确定 —— 深度上限只存在于三处：解析期 `SvgBuilder.cj:127-128`（默认 512，`SvgOptions.cj:66`）、`use` 链 `:981`（`SVG_USE_MAX_DEPTH`）、嵌套 svg `:817`（64）。普通 `g` / 容器嵌套**没有任何计数**，而 `SvgElement.appendElement`（`SvgElement.cj`）、`SvgAuthoringBuilder`、`SvgRenderer.render(element:width:height:)`（`SvgRenderer.cj:101`）都接受任意深度的程序化树
- **描述**：解析得到的文档受 `maxDepth = 512` 保护，栈帧数量可控；但 API 拼出的 10⁵ 层 `<g>` 链会让 `walkElement` 每层占一帧（含 3 个引用参数与每层 `ArrayList`），先爆栈（仓颉不保证尾调用优化，`walkContainer` 末尾还有 `for` 循环，本就不是尾位置）；`findSvgElementById` 会在同深度上再走一遍
- **建议**：给渲染遍历加与 `use`/嵌套 svg 同风格的 `depth` 计数（例如 > 256 抛 `SvgException(kind: Limit)`），`findSvgElementById` 传同一计数；或把 `walkChildren`/`walkElement` 改成显式栈迭代（`SvgDisplayCommand` 已是扁平列表，改成"待访问队列 + 帧状态"并不破坏现有结构）

### [一般][存量] #6 `SvgRenderer` / `SvgRenderTreeBuilder` 的会话状态无同步，也未声明单线程使用

- **位置**：`f_svg/src/SvgRenderer.cj:68-72`（`warnings` / `warnedColorProfiles` / `sessionGuard`）、`:280`、`:293-295`、`:131-141`；`f_svg/src/SvgRenderTree.cj:247-259`（`warnings` / `externalDocuments` / `missExternalDocuments` / `textLayouts` / `renderOptions`）
- **来源**：存量
- **判据**：review-checklist §12.1（共享可变状态无保护）、§11（契约未声明）
- **证据**：待确认 —— `render` 期间对 `ArrayList<String>`（`warnings`）与 `HashMap`（`warnedColorProfiles`、`externalDocuments`）追加写、对 `sessionGuard.stack`（`f_svg/src/SvgRenderGuard.cj:30-54`）增删，全部无锁无原子；类注释（`SvgRenderer.cj:61-65`）只承诺"不读时间/随机数/环境变量"，既没写线程安全也没写单线程。仓内没有并发复用的用例，无法确认外部是否存在该用法
- **描述**：`SvgRenderer(options:)` 的 `options` 天然不可变、看起来就是"建一次、多次 render"的对象；两线程共享同一实例时，`warnings` / `warnedColorProfiles` 会出现丢失写入与并发扩容，`sessionGuard.stack` 的 `enter/leave` 交错会让引用循环检测误判（一个线程 `enter` 的 identity 被另一线程 `leave` 弹掉），表现为随机丢内容而非崩溃，排查成本高
- **建议**：把会话状态（`warnings`、`sessionGuard`、`SvgImageResource`、`warnedColorProfiles`）从实例字段下沉为 `renderDisplayList` 的局部对象（`SvgRenderer` 只保留 `options`），顺带解决"多次 render 后 `warnings` 只增不减"；若保持现状，则在类注释与 README 明确"实例不可跨线程并发使用"

### [轻微][存量] #7 `needsLayer` 中 `filter` / `blendMode` 两个条件对非组指令恒不成立

- **位置**：`f_svg/src/SvgRenderer.cj:217-221`（`command.filter.isSome() || … || command.blendMode != SvgMixBlendMode.Normal`）、`:224-238`（filter 应用块）、`:253`（`mode: command.blendMode`）
- **来源**：存量
- **判据**：review-checklist §1（恒假分支）
- **证据**：静态确定 —— 非测试代码共 9 处 `SvgDisplayCommand(...)` 构造点：`SvgRenderTree.cj:600/784/1151/1438/1258` 是 `GroupBegin`（带 `blendMode`），其余 `:614`（Text）、`:1177`/`:1204`（Fill/Stroke）、`:1452`（Image）与 `SvgRenderer.cj:300/339/361/383`（文本轮廓、装饰线）全部显式 `filter: Option<SvgElement>.None` 且不传 `blendMode`（默认 `Normal`）；`renderDisplayList` 的 `GroupBegin` 走独立 `case`（`:144`），不会进入这段
- **描述**：`FillPath/StrokePath/Text/Image` 的 `filter` 恒 `None`、`blendMode` 恒 `Normal`，故 218 行的 filter 子句、224-238 的整段 filter 应用、253 行的 `mode:` 都是死路径；更大的问题是它构成陷阱——将来若给元素指令也填 `blendMode`，就会与树里已有的 elementGroup（`SvgRenderTree.cj:598-611`）叠加成"两次混合"
- **建议**：删掉这两个条件与 224-238 分支（保留一句注释说明组指令已承担），或在 `SvgDisplayCommand` 字段注释里写清"非 `GroupBegin` 指令的 `filter` 必须为 `None`、`blendMode` 必须为 `Normal`"，并加断言

### [轻微][存量] #8 `applyQuadCoverages` 注释写"交集缓冲"，实现是并集，缓冲按外层 quad 走

- **位置**：`f_svg/src/SvgRenderer.cj:863-897`（`:872-888` 的 `left = min(...)` / `right = max(...)`、`:893-896` 注释"交集外不可见；交集内先用 255 初始化"）
- **来源**：存量
- **判据**：review-checklist §11（注释与实现不符）、§7（缓冲按画布规模物化）
- **证据**：静态确定 —— 上界由 `left = min(left, box.x)`、`right = max(right, box.x + box.width)` 得到，是各 quad AABB 的**并集**；注释（`:861-862`、`:895-896`）声明的是"交集缓冲"。当前结果之所以正确，是因为 `applyEffects` 先用同组 AABB 的交集 `clipRect` 清零（`:693-696`，`clipRect` = `childClip` 链式 `intersect`，见 `SvgRenderTree.cj:842-845`），使存活像素必落在每个 quad 的 bbox 内；该前提只写在别处，没有任何断言
- **描述**：并集缓冲最坏等于整画布（`intersectionWidth × intersectionHeight` 字节，默认上限下 64 MiB），多层 quad 时扫描面积与分配都按最外层走；同时"先 clipRect 后 quad"的顺序一旦被调整（例如把 quad 提前到 filter 之前），漏裁剪会静默发生
- **建议**：改成真交集（`left = max(...)`、`right = min(...)`），交集为空直接 `clearBitmapAlpha`，缓冲自然缩小；若保留并集，则把注释改成"并集，交集外由 `clipRect` 先清零"，并在 `applyEffects` 注明两条清理顺序不可交换

### [轻微][存量] #9 `clipRectCoversCommand` 的描边余量未覆盖 miter 上限

- **位置**：`f_svg/src/SvgRenderer.cj:782-791`（`var margin = 1.0; margin += style.strokeWidth().value * max(sx, sy)`）、判定 `:808-810`
- **来源**：存量
- **判据**：review-checklist §11（快速路径判据不完整 → 该裁的没裁）
- **证据**：待确认 —— 描边相对路径的最大外扩是 `max(miterLimit × w / 2, w / 2)`；`stroke-miterlimit` 缺省 4（`f_svg/src/SvgComputedStyle.cj:278-280`），即最坏 `2w`，而 margin 只有 `1 + w × max(sx,sy)`。`max(sx,sy) = 1`、`w = 3` 时 margin = 4 < 6，45° 尖角可越过裁剪矩形。需要构造"裁剪矩形贴着包围盒、路径为锐角折线"的用例才能观测
- **描述**：命中时 `needsLayer` 被判为 false，跳过离屏层，尖角会画到裁剪矩形之外；常规矩形/圆角描边（miter 外扩 ≤ w/2）不受影响，因此长期不会被发现
- **建议**：margin 用 `1 + max(w × scale, miterLimit × w × scale / 2)`（lineCap 的 `w/2` 已包含）；或保守处理：`style.strokeMiterLimit() > 2` 时直接返回 false（多一次离屏层，不改变像素）

### [轻微][存量] #10 文本忽略 `paint-order`，固定 fill → stroke

- **位置**：`f_svg/src/SvgRenderer.cj:310-311`（`this.drawFill(...)` 紧接 `this.drawStroke(...)`，无层序判断）
- **来源**：存量
- **判据**：review-checklist §14（README 承诺与实现不符）；承诺源 `f_svg/README.md:146`「`paint-order` 支持 `fill` / `stroke` / `markers` 任意无重复顺序」
- **证据**：静态确定 —— `svgPaintOrderOf` 全仓仅 `SvgRenderTree.cj:1164`（`addShape`）使用，`paintOrder` 在 text / image 路径无命中；`SvgDisplayCommand` 也没有携带层序的字段
- **描述**：`<text paint-order="stroke">`（先描边后填充，避免细笔画被描边吃掉）无效；文本装饰线的 wavy / 普通 run 也固定按"描边 → 填充"输出（`:331-393`）。图形元素的 markers 层序由 `addShape:1226-1238` 正确实现，因此行为在元素之间不一致
- **建议**：让 `SvgRenderer` 的 Text 分支读 `style.paintOrder()`，按 `layers` 顺序调用 `drawFill` / `drawStroke`（装饰线内部次序不变）；补一条 `paint-order="stroke"` 的像素断言（描边色与填充色不同即可区分）

### [轻微][存量] #11 重复逻辑：四角 AABB ×4、嵌套视口裁剪块 ×3、元素组包装 ×3

- **位置**：四角 AABB —— `f_svg/src/SvgRenderTree.cj:1550-1566`（`transformedRectBounds`）、`:1756-1764`（`unionCommandBounds` 内联）、`f_svg/src/SvgRenderer.cj:792-807`（`clipRectCoversCommand` 内联）、`:1115-1122`（`drawImage` 内联）；嵌套裁剪块 —— `SvgRenderTree.cj:842-857`、`:1040-1052`、`:1334-1361`；元素组包装 —— `SvgRenderTree.cj:582-633`（text）、`:1133-1241`（shape）、`:1420-1471`（image）
- **来源**：存量
- **判据**：review-checklist §2（换控制流 / 内联化的同语义实现）
- **证据**：静态确定 —— 四段 AABB 都是"对 `(x,y)`/`(x+w,y)`/`(x+w,y+h)`/`(x,y+h)` 四次 `matrix.apply` → 两次 `min` + 两次 `max` → `SvgBounds(minX, minY, maxX-minX, maxY-minY)`"，逐句同构；三处裁剪块都是"`transformedRectBounds` → 与 `context.clipRect` 求交 → `!isAxisAlignedMatrix` 时 `appendSvgQuad(transformedRectQuad(...))`"
- **描述**：已核对差异点：marker 版多 `contentFits` 条件（`:1334`）、text 版组包围盒用 `clipBounds`（含装饰线，`:606`）、image 版 tag 硬编码 `"image"`——都属参数差异，无业务语义差异。风险在于 clip/quad 语义改动要同步改三处，漏一处就是"某个元素不裁剪"
- **建议**：`transformedRectBounds` 改 `internal` 供 `SvgRenderer` 复用（现在两文件各写一份）；嵌套裁剪提为 `nestedViewportClip(context, matrix, w, h, needQuad: Bool) -> (clipRect, clipQuads)`；元素组包装提为 `emitElementGroup(commands, tag, matrix, style, bounds, filtered, clipPath, mask, clip, quads)` 并保证 `GroupEnd` 配对

### [轻微][存量] #12 死存储：`var resolvedStackKey` 从未重新赋值

- **位置**：`f_svg/src/SvgRenderTree.cj:987`（`var resolvedStackKey = stackKey`）、`:1080`（`nextStack.add(resolvedStackKey)`）
- **来源**：存量
- **判据**：review-checklist §1（未使用可变性 / 死存储）
- **证据**：静态确定 —— `grep -n resolvedStackKey` 全仓仅这两处，函数体内无第二次赋值
- **描述**：读代码时会误以为外部 href 会在解析后被规范化（例如去掉 fragment 再入栈），但实际一直用 `stackKey`；而 `resolveExternalUse` 内部用的是 `"ext:" + href`（`:889`），两处对同一 href 的键规则分散在两个函数里
- **建议**：先改 `let`；若原意是要与 `resolveExternalUse` 的 marker 规则保持一致，则把键构造收敛成一个 `externalUseKey(href)` 并在两处共用

### [轻微][存量] #13 两套 `/tag[i]` 路径拼接，索引规则不同源

- **位置**：`f_svg/src/SvgRenderTree.cj:1774-1813`（`svgElementPath` / `findSvgElementPath`）与 `f_svg/src/SvgElement.cj:377-384`（`elementPath` / `siblingIndex`）
- **来源**：存量
- **判据**：review-checklist §2（同语义两份实现，易漂移）
- **证据**：静态确定 —— 两者都产出 `/svg[1]/g[1]` 形态（`SvgRoot_test.cj:107` 断言 `elementPath()`），`svgElementPath` 额外有"root 不匹配就返回 `/${target.tag}[1]`"（`:1785`）与"找不到就回退 base"（`:1781-1783`）两种降级；warning 文案（`:1307`、`SvgTextRenderer.cj:397`）用的是树遍历版，测试断言的是父链版
- **建议**：warning 场景直接用 `target.elementPath()`（目标必然在树上），仅在跨文档（外部 `use` 目标与主 root 不同树）时回退到树遍历；或把"同名兄弟计数"抽成 `svgSiblingIndex(node)` 供两处共用，避免一处按元素计数、一处按 `children` 计数时漂移

### [轻微][存量] #14 同一外部 href 每次 `use` 都重算整棵外部文档样式树并重复追加 warning

- **位置**：`f_svg/src/SvgRenderTree.cj:943-951`（缓存命中后仍 `SvgStyleResolver().compute(document.root, …)` 并 `this.warnings.add(warning)` 全量追加）
- **来源**：存量
- **判据**：review-checklist §6.4（同一输入重复解析）、§11（可观测噪声）
- **证据**：静态确定 —— 文档缓存（`:900-931`）只缓存 `SvgParser.parse` 的结果；`resolver.compute` 在缓存分支之后无条件执行，且 `resolver.warnings` 每次全量 `add`。同一 href 被 N 个 `<use>` 引用 ⇒ N 次全文档样式解析、同一 warning 出现 N 次
- **描述**：`SvgExternalDocumentM6_test.cj:59` 有"同一外部 href 两次 use"的用例，但只断言解析/provider 次数，不校验 warning 去重，因此重复告警不会被测出；对含大量 `<use>` 的外部文档，样式解析会随引用次数线性放大
- **建议**：把 `SvgStyleResolver` 结果与 `SvgDocument` 一起缓存（`HashMap<String, SvgExternalResolution>`，复用 `SvgExternalResolution` 的 `styles` 字段），warning 只在首次 compute 时收集

## 优化可行性方案

> 均无改前/改后对照数据，按铁律标 `无基线（待验证，不进 tasks）`。

### [堆内存] 离屏层按命令包围盒分配，而不是整画布

- **现状**：`SvgGroupCompositor.createLayer(list.width, list.height, …)`（`f_svg/src/SvgRenderer.cj:145`、`:222`）每次都分配 `width × height × 4` 字节；默认 `maxPixels = 64 Mi` 下单层 256 MiB，`frames` 栈让外层全部常驻（`#4`）
- **方案**：`GroupBegin` 已带 `bounds`/`clipBounds`（`SvgRenderTree.cj:606/793`），用其设备空间 AABB 与画布求交后再分配；`SvgGroupCompositor.composite` 增加偏移参数，`applyEffects` 内的 clip/mask 覆盖率按偏移后的尺寸渲染
- **预期**：典型场景（小图标画在大画布上、局部 `opacity` 组）层内存从 `O(画布)` 降到 `O(元素包围盒)`；满配深嵌套场景峰值按包围盒面积比例下降。具体倍数需实测
- **代价**：合成与 clip/mask 的坐标系要带上偏移，`clipBitmapToRect`/`applyQuadCoverages` 需接受子矩形；`bounds` 缺失时必须保守退回整画布（现有部分 `GroupBegin` 无包围盒）
- **验证**：同文档（含 8 层嵌套 `opacity` 组、1024²/4096² 两种画布）改前后 `getUsedHeapSize()` 峰值与 RSS 对照，并保持 `SvgRenderer_test` / `SvgOverflowM4_test` 全部像素断言逐字节一致
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] `applyQuadCoverages` 用真交集缓冲 + 复用 quad 蒙版位图

- **现状**：缓冲按并集分配（`SvgRenderer.cj:893-896`，最坏整画布 1 B/px），每个 quad 再新建一个 `SvgBitmap(box.width, box.height)`（`:904`，4 B/px）并立即丢弃
- **方案**：缓冲区按 AABB 交集分配（`left=max`、`right=min`）；quad 蒙版位图按最大 quad 尺寸分配一次、逐 quad 清零复用（或直接用覆盖率 `Array<Byte>` 而不建 `SvgBitmap`）
- **预期**：多 quad 场景缓冲从"最外层 quad 面积"降到"交集面积"，每个 quad 少一次 4 B/px 分配；具体收益需实测
- **代价**：交集为空要提前 `clearBitmapAlpha`；复用蒙版需保证清零（`clear()` 不还内存也不置零，必须显式覆写）
- **验证**：`SvgOverflowM4_test.nestedRotatedQuadsIntersect` / `rotatedMarkerClip` 改前后逐像素一致；再加一条"交集为非矩形"的用例
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `sampleImage` 每像素 3–4 次小数组分配

- **现状**：`SvgRenderer.cj:1174`（`transparent`）、`:1181`（`result`）每次调用都新建；双线性路径再新建 `weights` / `columns` / `rows` 三个数组（`:1202-1209`）。`drawImage` 的像素循环（`:1136-1164`）对目标矩形内每个像素调用一次，1000×1000 的 `<image>` 即 100 万次调用 × 4 个数组
- **方案**：改为 `sampleImage(source, mapping, u, v, bilinear, out: Array<Byte>)` 写外参数；`transparent` 提为文件级 `let`；双线性权值/行列改为标量局部变量（`x0/x1/y0/y1` 与 4 个 `Float64`），去掉三个数组
- **预期**：单图少 400 万次分配、约 12 MB 分配量（1000×1000 场景），GC 次数与取样耗时下降；降幅需 `cjprof` 实测
- **代价**：`sampleImage` 变私有带外写签名，可读性略降；需保持 `alpha <= 0` 时返回全透明与 `clampImageIndex` 的边界语义
- **验证**：`cjprof record` 跑 1024×1024 源图放大到 2048×2048，看 `sampleImage` 自耗时与 GC 占比；`cjpm bench -O2` 对照 `imageRenderingModes` / `preserveAspectRatioModes` 的像素断言
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `build()` 最多做 3 次全量样式解析

- **现状**：`SvgRenderTree.cj:289-294`（按 viewport 尺寸）、`:306-311`（`width/height: auto` 时按内容尺寸）、`:315-320`（按 `logicalWidth/Height` 无条件再算一次）。`SvgStyleResolver.compute` 是整树遍历 + 选择器匹配，第三次在"非 auto 且未指定 width/height"时与第一次参数完全相同
- **方案**：先判断是否需要 auto 分支（`widthAuto/heightAuto && options.width <= 0 && options.height <= 0`），仅在需要时做第二次；其余路径合并为一次"先按最终 media 尺寸算"——即先确定 `logicalWidth/Height` 再 compute（auto 分支仍保留两次，但把第三次删掉）
- **预期**：常见路径（显式尺寸或根 `viewBox`）样式解析次数 3 → 1，`build` 端到端按样式解析占比下降；需 profile 数据支撑
- **代价**：`auto` 分支依赖"按 300×150 首算"来决定内容尺寸，顺序不能简单合并；需要保证 `resolver.warnings` 不因计算次数变化而重复/丢失
- **验证**：`cjprof record` 跑 10k 元素文档的 `build`，看 `SvgStyleResolver.compute` 占比；改后 `SvgRenderer_test` + `SvgAutoSizeM6_test` 逐字节一致
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `walkContainer` 每个容器复制一遍子指令列表

- **现状**：`SvgRenderTree.cj:769`（每容器 `new ArrayList<SvgDisplayCommand>()`）+ `:802-804`（逐个 `commands.add`）。子指令在每一层祖先都被复制一次 ⇒ 命令数 × 嵌套深度的搬移量
- **方案**：给 `commands` 记录"段起点"，子内容直接追加到父列表，只在需要包裹 `GroupBegin/GroupEnd` 时插入；或改成"先写子、再在起点位置插入组指令"（`ArrayList` 头部插入是 O(n)，需换成双端结构或两段拼接）
- **预期**：深嵌套文档（几百层 `g`）的构树搬移量从 O(n·depth) 降到 O(n)；需 profile 证明构树耗时占比
- **代价**：组指令必须严格包住子段，插错位置会破坏渲染顺序；测试里的"文档顺序保持"（`SvgRenderTree_test.displayNoneAndOrder`）要保留
- **验证**：`cjpm bench -O2` 对比 500 层嵌套 + 10k 图元的 `build` 中位数（≥5 轮），并比对显示列表逐条 `kind/tag/matrix` 一致
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 每个 marker 实例都做一次整树路径遍历

- **现状**：`SvgRenderTree.cj:1304-1308` 在 marker 实例循环内调用 `svgElementPath(Some(context.root), instance.marker)`，实现是 `findSvgElementPath` 从根递归找 identity（`:1789-1813`）⇒ 单条路径上的 K 个 marker 就是 K 次整树遍历，仅用于 warning 标签
- **方案**：标签在 `SvgMarkerExpander.expand` 阶段一次性算好（那里已知 marker 元素），或惰性生成——只有 `sessionGuard.enter` 返回 false / 抛错时才构造 label（`enter` 目前把 label 当必填参数，可改成 `() -> String`）
- **预期**：marker 数量多的文档省掉 O(K·N) 的遍历；需实测占比
- **代价**：`SvgRenderGuard.enter` 签名变化（内部类，影响 `SvgPatternSampler` 一处调用）；惰性标签要在 warning 路径上保证文案一致
- **验证**：`cjprof record` 跑 1000 个 marker 的文档；改后 `SvgOverflowM4_test` 的 marker 裁剪用例与 warning 文案断言不变
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `sampleImage` 的每像素小数组分配是 `<image>` 绘制的主要 GC 压力 | `f_svg/src/SvgRenderer.cj:1167-1231` | 分配量、GC 次数、`sampleImage` 自耗时占比 | `cjprof record` 渲染 1024² 源图 → 2048² 目标，samplesPerPixel=1，统计 `alloc` 与 GC 停顿 |
| 2 | 三次 `SvgStyleResolver.compute` 占 `build` 端到端 30% 以上 | `f_svg/src/SvgRenderTree.cj:289-320` | 分段计时占比（10k 元素文档） | 在三次 compute 前后加计时，`-O2` 跑 10 轮取中位数 |
| 3 | 整画布离屏层合成（含空组）是 `opacity < 1` 文档的热点 | `f_svg/src/SvgRenderer.cj:144-160`、`:201-206` | `composite` 自耗时、层数分布 | `cjprof record` 跑 50 个 `opacity="0.9"` 组、1024² 画布；另统计"子内容全被 display:none 的空组"数量 |
| 4 | `walkContainer` 的子指令复制在深嵌套文档里占构树时间的主要部分 | `f_svg/src/SvgRenderTree.cj:769-804` | 复制次数与耗时（depth × 命令数） | 构造 200/500/1000 层 `g` + 每层 10 个矩形，分段计时 `walkChildren` |
| 5 | 长生命周期 `SvgRenderer` 的 `warnings` 只增不减会累积到可观内存 | `f_svg/src/SvgRenderer.cj:68-72`、`:293-295` | 每轮 warning 条数 × 轮数、RSS/堆占用 | 同一实例渲染 10k 个含缺失 `<image>` 的文档，采 `getUsedHeapSize()` 与 `warnings.size` |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_svg/src/SvgRenderTree.cj` | .cj | ✅ | 显示列表构建；见 #1、#2、#3、#5、#11、#12、#13、#14 与优化方案 4/6 |
| 2 | `f_svg/src/SvgRenderTree_test.cj` | .cj | ✅ | display:none/顺序/文档只读、use 展开（x/y、symbol）、循环、use 与嵌套 svg 深度 64、image 占位；未覆盖 use/nested-svg 的 transform/opacity（见 #1/#2） |
| 3 | `f_svg/src/SvgRenderer.cj` | .cj | ✅ | 逐指令光栅化、离屏层、clip/mask/filter、image 取样；见 #4、#6、#7、#8、#9、#10、#11 与优化方案 1/2/3 |
| 4 | `f_svg/src/SvgRenderer_test.cj` | .cj | ✅ | 入口/背景/高 DPI/百分尺寸/确定性/PNG/image 三档映射/filter 空链/文本；断言与实现一致 |
| 5 | `f_svg/src/SvgRenderingHints.cj` | .cj | ✅ | 三个渲染提示枚举 + `quantizeSteps`；`fromName`/`toString` 成对，`quantizeSteps` 在 `SvgRenderer.cj:496` 消费 |
| 6 | `f_svg/src/SvgRenderingHintsM6_test.cj` | .cj | ✅ | 提示解析/继承/非法值 warning/AA 关闭/linearRGB/量化/管线接线；与 `svgTextTolerance` 等实现一致 |
| 7 | `f_svg/src/SvgRoot.cj` | .cj | ✅ | 6 个版本缓存属性 + 两个 `tryParse*` 包装；无死代码，空值语义为 `None` 不补默认 |
| 8 | `f_svg/src/SvgRootAttrsM6_test.cj` | .cj | ✅ | baseProfile/version/zoomAndPan 缺省与非法值；与 `SvgDocument` 实现一致 |
| 9 | `f_svg/src/SvgRoot_test.cj` | .cj | ✅ | 缺省 `None`、构造参数、长度/ viewBox / preserveAspectRatio 读写与删除、子节点路径 |

合计：`.cj` 9 个 / `.md` 0 个 / 共 9 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 6 | 正确性 2（#1 use 变换与效果丢失、#2 嵌套 svg 效果丢失）；设计 1（#6 会话状态下沉）；可读性 3（#8 注释与实现不符、#11 三处同构、#12 死存储）；语言特性 0（`Option` 全部显式 `match`，无静默 `getOrThrow`；`SvgValueCache` 版本缓存用法正确）；安全性 0：本部分不做字符串拼 XML、不过滤用户文本，`warnings` 只输出元素 tag/id 与 href，无凭据面；外部文档解析强制 `unsafePolicy: Remove` + `allowExternalReferences: false`（`SvgRenderTree.cj:1871-1889`），未发现注入面 |
| §1 死代码 | 3 | 逐符号搜引用：`SvgRenderTree.cj` 的 24 个 private/internal 顶层函数（`elementTransformMatrix`、`symbolDimension`、`transformedRectBounds`、`markerContentFits*`、`isAxisAlignedMatrix`、`appendSvgQuad`、`maxInt64`、`ceilSvgPixel`、`arrayContainsSvgString`、`unionCommandBounds`、`svgElementPath`、`findSvgElementPath`、`deriveRenderFonts`、`svgStyledLengthOrZero`、`SvgExternalResolution`、`svgHrefFragment`、`svgExternalParseOptions`、`svgApplyM6VectorEffects` 等）均在本文件有调用；`findSvgElementById`（internal）在 `SvgClipMask`/`SvgElementApi`/`SvgHitTest`/`SvgMarkerExpander`/`SvgPatternSampler`/`SvgTextRenderer`/`SvgTimeline` 有调用；`SvgRenderer.cj` 的 14 个 private 符号（`clipRectCoversCommand`、`quadDeviceBounds`、`applyQuadCoverages`、`clearBitmapAlpha`、`clipBitmapToRect`、`strokeDashValues`、`scaleStrokeDash`、`rectPathData`、`SvgImageMapping`、`imageMapping`、`drawImage`、`sampleImage`、`clampImageIndex`、`svgShapeAntiAlias`/`svgShapeTolerance`/`svgGradientColor*`）均有调用；`svgTextTolerance`/`svgWarnColorProfile`（internal）在 `SvgRenderer` 与测试中调用。命中：`needsLayer` 两条恒假分支（#7）、`resolvedStackKey` 死存储（#12）、`import fountain::f_base.*` **不判**（`SvgRenderTree.cj:1855` 的 `String.unsafeBytes()` 来自 `f_base/UnsafeBytes.cj`，`grep` 已确认）。对外可达 public（`SvgDisplayCommand`/`SvgDisplayList`/`SvgRenderTreeBuilder`/`SvgRenderer`/`renderToPng`/`SvgRoot`/四个提示枚举）不判；`SvgDisplayCommand.textTolerance`/`strokeWidthOverride`、`SvgDisplayList.styles/textLayouts/fonts` 为 internal 且都有消费 |
| §2 重复逻辑 | 3 | 同文件逐函数体比对 + 跨文件按字面量/形状搜索：四角 AABB ×4、嵌套视口裁剪块 ×3、元素组包装 ×3（#11）；两套 `/tag[i]` 路径拼接（#13）；同一外部文档样式重算（#14）。另：`maxInt64` 三份（`SvgRenderTree.cj:1722`、`SvgRasterizer.cj:489`、`SvgPatternSampler.cj:491` 的 `maxInt64Pattern`）已由 part20 #8 记录，此处不重复计数；测试侧 `svgDoc` / `fillCommands` 属共享测试夹具，不计 |
| §3 空实现 | 0 | 逐个函数体检查：无 `{}`、无 `TODO`/`FIXME`、无 `catch {}`（`SvgRoot.cj:160-174` 的 `catch (_: SvgException)` 是"非法值 → `None`"的显式降级，返回值被使用）；`walkElement` 的 `case _ => ()`、`applyEffects` 的 `case None => ()` 都是可选属性缺省，不是吞错 |
| §4 栈溢出 | 1 | 命中 #5（`walkChildren`/`walkElement`、`findSvgElementById`、`findSvgElementPath`、`markerContentFitsIn` 对程序化深树无深度上限）。已排除：`use` 链（`SVG_USE_MAX_DEPTH` 64，先查循环再查深度）、嵌套 svg（`:817` 64 层）、`SvgRenderGuard.stack`（`SVG_MAX_REFERENCE_DEPTH`）、解析路径（`SvgBuilder` 的 `maxDepth` 512）。`markerContentFitsIn` 的递归深度受文档深度约束，只有与 #5 同源时才可触发 |
| §5 OOM | 2 | 命中 #3（外部文档缓存 N×16 MiB）、#4（层数 × 整画布）。已量化：单层 = `w×h×4`，默认上限下单层 256 MiB；外部文档单份 ≤16 MiB、无份数上限。拒绝路径：`maxPixels`（单位图）、`SVG_EXTERNAL_MAX_BYTES`（单文档）、`maxDepth`/`maxElements`（单文档结构），缺"聚合"维度 |
| §6.1 热点瓶颈 | 0 | 本部分无 `cjprof` / `cjpm bench` 数据（`doc/perf-baseline.md` 只覆盖 M4 滤镜基准，与渲染树/取样无关），所有性能判断均降级为「待验证假设」1–5 与优化方案（均标无基线） |
| §6.2 大粒度锁 | 0 | 本部分无锁、无 `synchronized`、无读写锁；`SvgRenderGuard` 是普通 `ArrayList`，依赖单线程调用（见 #6） |
| §6.3 并发串行 | 0 | 无 `spawn` / `Future` / 线程池；`renderDisplayList` 是纯顺序循环，不存在"形式并发实际串行"的结构 |
| §6.4 低效算法 | 2 | 已按"无基线"处理、未计缺陷：`walkContainer` 子指令逐层复制（O(n·depth)，优化方案 4）、每 marker 实例整树路径遍历（优化方案 6）；`build` 三次样式解析（优化方案 3）同属此类。`findSvgElementById` 每次线性扫描（`use`/`resolveUrlRef`/`paint` 引用）在文档元素数大时也偏高，缺调用频次数据，未单列 |
| §7 降堆内存方案 | 2 | 离屏层按包围盒分配、quad 覆盖率缓冲交集化 + 蒙版复用（方案 1、2）。`SvgRenderer.warnings` 只增不减并入 #6 的修法（会话状态下沉），不单列 |
| §8 降 CPU 方案 | 4 | `sampleImage` 每像素分配、`build` 三次样式解析、`walkContainer` 指令复制、marker 路径遍历（方案 3–6） |
| §9 local mode 可行性 | 0 | 本部分的临时大对象都**逃逸**：显示列表（`commands.toArray()` 返回给 `SvgDisplayList`）、离屏层 `SvgBitmap`（跨指令存活）、`coverage` 缓冲（`Array<Byte>`，且 `applyQuadCoverages` 返回后被 `bitmap.pixels` 复用）。`drawImage`/`sampleImage` 的临时数组不逃逸但总量小（4 字节级），收益无法用峰值内存对照证明，故不立项 |
| §11 现有代码的 BUG（存量） | 14 | 本部分 14 条发现全部为存量（快照模式无 diff）。另核对未计入的边界：`SvgDisplayCommand.init` 的 `clipBounds` 回退到 `bounds`（`:129-132`）与字段注释一致；`foreignObject` 的 `maxPixels` 判定（`:665`、`:683`）因 `SvgBitmap` 保证宽高 > 0（`SvgBitmap.cj:93-96`）不会除零；`walkElement` 的 `case` 顺序经继承链核对无遮蔽（`SvgRoot`/`SvgUse`/`SvgImage`/`SvgTextElement`/`SvgShape` 均直接继承 `SvgElement`，`SvgShape` 是 `abstract class`）；`drawImage` 的 `sourceWidth/Height = 0` 会得到 `Inf/NaN` 并被 `sampleImage` 的边界判断吞掉（`SvgBitmap` 构造已禁止 0 尺寸，不可达）；`svgWarnColorProfile` 用原始 `profile` 作 key（`:1327-1330`），大小写不同的同一 profile 会各告警一次，影响仅限噪声，未单列 |
| §12 并发安全与锁粒度 | 1 | 命中 #6（`SvgRenderer`/`SvgRenderTreeBuilder` 实例状态）。线程封闭证据：`SvgRenderTreeBuilder` 在 `SvgRenderer.render`（`:92`、`:102`）与 `SvgPatternSampler.sampleTileUncached`（`SvgPatternSampler.cj:283`）都是每次新建；`SvgElements` 本身可变且无同步（`attributesVersion` 递增、`SvgValueCache`），属于文档模型既定契约（单线程修改），未单列 |
| §14 功能完备性与 README 覆盖 | 3 | 命中 #1（use `transform` 未进 README 例外）、#2（嵌套 svg 效果无文档）、#10（`paint-order` 承诺与实现不符）。本部分所有 public 类型均在 `README.md` 符号清单命中（`SvgDisplayCommand(Kind)`、`SvgDisplayList`、`SvgRenderTreeBuilder`、`SvgRenderer`、`SvgRoot`、`SvgShapeRendering`/`SvgTextRendering`/`SvgColorRendering`/`SvgColorInterpolation`、`renderToPng`），无"公开 API 未文档化" |
| 文件覆盖（§13 等） | 9/9 | 无缺失；本部分不含 `.md`，§13（文档一致性）不适用，仅把 `README.md` 作为承诺源做交叉核对（README 本身归其他部分） |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 6 |
| 轻微 | 8 |
| 优化方案（堆内存 / CPU） | 2 / 4 |

存量缺陷 14 条（严重 0 / 一般 6 / 轻微 8），是否纳入修复待用户决定。

## 总评

本部分是全模块的"渲染总装线"，工程质量总体扎实：显示列表把 `use`/symbol/嵌套 svg/marker/foreignObject 全部展开成扁平指令，`clip`/quad/marker 的坐标推导有注释且与测试对应；`SvgRenderGuard` 把 pattern/marker/文本引用循环统一成"进入即查、离开必清"的 `try/finally`；外部文档的解析选项被强制收紧（`unsafePolicy: Remove`、`allowExternalReferences: false`），安全策略没有被主文档的宽松配置带跑；`SvgRenderer_test` / `SvgRenderTree_test` / `SvgOverflowM4_test` 对确定性、逐字节一致、深度上限、旋转裁剪都有断言。本部分未发现注入、转义或凭据暴露面。

主要风险集中在**"元素级效果只覆盖了部分元素类"**与**"聚合上限缺失"**两条线：

1. 元素级效果覆盖不全（#1、#2）是本部分最值得优先处理的正确性问题：`g`/图形/文本/图像都走完整的 `opacity + clip + mask + filter + blend` 包装，而 `use` 与嵌套 `<svg>` 只做了变换/视口裁剪。`use` 的 `opacity`/`clip-path`/`mask` 已在 M4 复验里被记录为已知限制，但 **`use` 的 `transform` 连"已知限制"都不是**，README 又泛称 `transform` 支持——这条会直接给出错误画面且无 warning，建议先修或先在 README 的 `use` 行写清。嵌套 `<svg>` 的 `opacity` 同理（`<svg opacity="0.5">` 是常见写法）。
2. 聚合上限缺失（#3、#4）都不会立刻 OOM，但都缺"单点上限之外的聚合预算"：外部文档按 href 无界累积（16 MiB × N）、离屏层按层数 × 整画布累积（默认 256 MiB × 层数）。两者的修法都成熟（预算对象 / 包围盒化），适合与渲染性能优化一起排期，并以 RSS 峰值对照验收。
3. #5（程序化深树无深度上限）只在 API 拼装场景触发，解析路径已被 `maxDepth` 保护；但它是"崩溃级别、且只需要加一个计数"的低成本修复，建议随手补上。
4. #6（会话状态线程安全）目前没有并发使用的证据，属"契约未声明"；最省的修法不是加锁，而是把 `warnings`/`sessionGuard`/图像预算下沉为 `render` 局部对象，顺带消掉"同一实例多次 render 后 `warnings` 只增不减"。
5. 轻微项以死分支（#7）、注释与实现不符（#8）、快速路径判据偏窄（#9）、`paint-order` 未接线（#10）与三处同构代码（#11–#14）为主，可随手清理；其中 #11 的三处同构块（嵌套裁剪、元素组包装）与 #1/#2 的修法同源——先把"元素级效果包装"抽成一处，再补 `use`/嵌套 svg 的两处调用，可以一次解决"重复"和"覆盖不全"两个问题。
