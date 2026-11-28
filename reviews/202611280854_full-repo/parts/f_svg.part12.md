# f_svg 模块审查报告

> **模块第 12/26 部分**（本报告只覆盖 `files/f_svg.part12.txt` 列出的 15 个文件，全部为 `.cj`；其余 286 个 `.cj` 与 141 个 `.md` 由其他子轮产出，合并时以主 Agent 为准。）

- **审查日期**：2026-11-28
- **模块路径**：`f_svg`（本部分 15 个源文件，4773 行）
- **基线**：工作区快照（`sts/1.3.x`，无 diff 可比 ⇒ 全部问题记「存量」）
- **审查重点**：SVG 解析/序列化正确性与 XML 边界、注入与转义、OOM、递归与栈溢出、死代码、重复逻辑、存量 BUG
- **报告版本**：v1.1（第 12/26 部分；同一文件清单的第二次独立通读，补充 #17–#26，与第一轮 #1–#16 合并保留）
- **编号说明**：`#1–#16` 为第一轮通读结论（保持原文与交叉引用不变），`#17–#26` 为第二轮补充；**#17 为严重级**，读时请按标题里的级别筛选，不要按编号推断级别。

## 发现

### [严重][存量] #1 clipPath / mask 引用每层都分配整幅画布位图，循环引用要走到深度 64 才识别 —— 1080p 下约 1 GiB 峰值

- **位置**：`f_svg/src/SvgClipMask.cj:230`（`renderClipCoverage` 的 `SvgBitmap(width, height)`）、`275`（`renderMaskCoverage` 同）、`393` 与 `531`（每个带 clip/mask 的子元素再分配一个 `layer`）、`638-644` 与 `689-695`（`if (depth >= 64)` 才做环检测）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §5「无界容器 / 递归 + 每层分配」、§4「间接递归」、§6.4「同一输入重复整幅计算」
- **证据**：静态确定（分配次数与字节数可直接从代码推出；实际 RSS 未实测）—— 调用链是 `applyClipReference → renderClipCoverage → renderClipChildren → applyClipReference`。在递归到最深处时，每一层同时存活：`renderClipCoverage` 的 `bitmap`（4 B/像素）+ `renderClipChildren` 的 `layer`（4 B/像素），即 **8 B/像素/层**；另有 `coverage`（1 B/像素）在回程分配。深度上限是 64，且环检测放在 `depth >= 64` 分支里（`639`、`690`），不是进入时检测 —— 一个 `a → b → a` 的两节点环会完整跑满 64 层。
  - 1000×1000 画布：8 MB/层 × 64 ≈ **512 MB**；
  - 1920×1080 画布：约 16.6 MB/层 × 64 ≈ **1.06 GiB**；
  - 默认 `SvgRenderOptions.maxPixels = 64 * 1024 * 1024`（`f_svg/src/SvgBitmap.cj:230`）只限制**单张**位图，不限制"层数 × 单张"的累计峰值。
- **描述**：一份仅含两个互相 `clip-path` 引用的小 SVG，在默认选项下渲染 1080p 目标即可触发约 1 GiB 分配与 64 次整幅光栅化；即使不是环，10 层嵌套 clip 也有约 166 MB 的无谓峰值。这是典型的"小输入、大分配"放大面，属 OOM / 拒绝服务风险；同时环的告警只有一条（`640`），用户看不到 64 次重复光栅化的代价。
- **建议**：① 进入 `applyClipReference` / `applyMaskReference` 时先用 `containsSvgStackId` 判环（命中立即 warning + return），把深度上限降到能覆盖真实文档的量级（如 16），而不是"跑满 64 层再判断"；② 计算子元素的设备空间包围盒（含抗锯齿/描边余量），按包围盒分配小 `layer` 与覆盖率蒙版，只合成该区域；③ 若短期不改结构，至少在 `renderClipCoverage`/`renderMaskCoverage` 入口按 `SvgRenderOptions.maxPixels / (depth + 1)` 做总量校验，超限抛 `Limit`。

### [严重][存量] #2 mask 内容只按"元素自身 fill 属性的纯色"渲染：渐变/继承填充/文本/图像/evenodd 全部产生错误覆盖率，元素会整体消失

- **位置**：`f_svg/src/SvgClipMask.cj:592-622`（`drawMaskPath` 只看 `shape.fill` / `shape.fillOpacity` / `shape.opacity`，`paint.kind != Color` 直接不画，`fillRule` 硬编码 `Nonzero`）、`511-514`（`childStyle` 算了却没传给 `drawMaskPath`）、`613`；`drawMaskPath` 在 `531-533` 被调用
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「逻辑错误 / 错误结果」、§14「承诺了但没实现」、§3「静默失效」
- **证据**：静态确定 —— `drawMaskPath` 的签名只有 `(child, path, matrix, bitmap, samplesPerPixel)`，没有 `SvgComputedStyle`；`shape.fill` 的实现是 `readPaint(this, "fill")`（`f_svg/src/SvgShape.cj:164-171`），只读元素自身属性，不读继承/样式表。于是：
  1. `<mask><g fill="white"><rect .../></g></mask>`：`rect` 自身无 `fill` → 走 `?? SvgPaint.of(SvgColor.Black)`（`601`）→ 蒙版位图是**黑色不透明**，亮度 0（`306-307`）→ 覆盖率 0 → 目标元素被判为完全透明而消失；
  2. `<mask><rect fill="url(#grad)" .../></mask>`：`paint.kind == Gradient` → `602` 条件不成立 → 一个像素都不画 → 覆盖率 0 → 元素整体消失（渐变蒙版是最常见的淡出写法）；
  3. `<mask><text>…</text></mask>` / `<image>` / `<use>`：`elementPathData` 对它们返回 `None`（`779-852` 只覆盖 rect/circle/ellipse/polygon/polyline/path/line），`renderMaskChildren` 走 `None` 分支继续递归（`515-527`），文本/图像子节点没有可画内容 → 覆盖率 0；
  4. `fill-rule="evenodd"` 的路径在蒙版里按 `Nonzero` 填充（`613`），孔洞被填实 → 蒙版多出本不该有的不透明区域；
  5. `display:none` / `visibility:hidden` 的子元素照常参与蒙版（clip 侧同样如此，`364-391`）。
- **描述**：README（`f_svg/README.md:218`）把 `mask` 列为"支持，亮度与 alpha 两种模式"，但实际只支持"元素自带纯色 fill 的七种形状"。上面 1/2/3 三种写法都会让被蒙版元素**静默消失**，没有任何 warning；这与"蒙版不生效"是两种完全不同的错误方向，排查成本很高。clip 侧因为覆盖率只取 alpha，纯色/黑色不是问题，但 `text`/`image`/`use` 内容同样被忽略。
- **建议**：让 `drawMaskPath` 接收 `SvgComputedStyle`（`renderMaskChildren` 已经算好 `childStyle`），用 `style.fill()` / `style.fillOpacity()` / `style.fillRule()` 代替元素属性直读；非纯色画笔走与主渲染器相同的 gradient/pattern 采样路径（`SvgRasterizer.fillGradient` 已存在）；`elementPathData` 增加文本轮廓/图像边界分支，或至少对不支持的子元素记 warning（"mask 内容类型不支持，已忽略"），避免静默全透明；同时补"组继承 fill""渐变蒙版""evenodd 蒙版""文本蒙版"四条用例。

### [一般][存量] #3 clip/mask 的元素树遍历递归没有深度计数，深 DOM 或父子环会栈溢出

- **位置**：`f_svg/src/SvgClipMask.cj:376-389`、`405-418`（`renderClipChildren` 递归传原 `depth`）、`515-527`、`534-546`（`renderMaskChildren` 同）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §4「无界递归 / 自引用结构」
- **证据**：静态确定 —— 四处递归调用都把 `depth` 原样传下去（`depth` 只在 `applyClipReference`/`applyMaskReference` 里 `depth + 1`，见 `667`、`722`），所以"容器套容器"这条路完全没有计数；`SvgElement.appendElement` 也不做环检测（父指针 + children 双向链，可被调用方构造成环）。`SvgClipPathMasker.render` / `SvgMasker.render` 是公开 API，参数就是调用方给的 `SvgElement` 树。
- **描述**：解析路径被 `SvgSecurityOptions.maxDepth = 512`（`f_svg/src/SvgOptions.cj:66`）兜住，正常文档不会触发；但直接构造 DOM（`SvgRoot` + `SvgContainer` 循环 `appendElement`，或把某个容器 append 到自己的后代里）后调用公开渲染 API 会无限递归直至栈溢出，进程崩溃。栈溢出按后果属崩溃类，这里因可达性依赖程序化构造，定为一般。
- **建议**：给两处遍历加显式深度参数（与引用深度分开，例如 `treeDepth`，上限取 `maxDepth` 或更小），超限抛 `SvgException(kind: Limit)`；`appendElement` 做"祖先链包含自身"检查，直接拒绝成环。

### [一般][存量] #4 嵌套 clip/mask 对非形状子元素用 `SvgBounds.empty()` 当目标盒，objectBoundingBox 单位把覆盖率缩放成负值 —— 内容被裁光或只剩 1 像素

- **位置**：`f_svg/src/SvgClipMask.cj:420-423`、`548-551`（`case None => SvgBounds.empty()`）、`210-212`（`bboxMatrix` 直接 `translate(box.x, box.y) * scale(box.width, box.height)`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「空值未处理 / 边界」、§10「正确性」
- **证据**：静态确定 —— `SvgBounds.empty()` 是 `(0, 0, -1, -1)`（`f_svg/src/SvgBounds.cj:36-38`）。当 clip/mask 里的子元素是 `<g>` / `<text>` / `<image>` / `<use>`（`elementPathData` 返回 `None`）且它自己带 `clip-path` / `mask` 引用时，`box=(-1,-1)` 会被传给两条路径：① `clipPathUnits="objectBoundingBox"` / `maskContentUnits="objectBoundingBox"` → `matrix = childMatrix * scale(-1,-1)`（`232-234`、`277-279`），子内容镜像到负象限，覆盖率恒为 0；② mask 默认 `maskUnits=objectBoundingBox` 时 `maskRegion` 由 `box` 推出 `x=0.1`、`width=-1.2` 的退化区域（`899-917`），最终 `firstX/firstY=0`、`lastX/lastY=1`（`924-928`），覆盖率只剩左上角 1×1 像素 —— 元素几乎被整段抹掉。
- **描述**：只有"容器/文本/图像/use 自带 clip 或 mask，且引用目标是 objectBoundingBox 单位"这一组合会触发，但这是图标库里常见写法（`<g clip-path="url(#round)">`）。当前没有任何 warning，表现为"组内容凭空消失"或"只显示左上角一个像素"。
- **建议**：`box` 改成按元素类型取真实包围盒：容器取子元素并集（`svgBBoxOf` 已有），文本取布局包围盒，图像取 `x/y/width/height`；确实无法计算时不要回退 `empty()`，而是退回 `UserSpaceOnUse` 语义并记 warning。

### [一般][存量] #5 `font-variant-ligatures` 用 `contains` 匹配，`no-common-ligatures` / `no-contextual` 被解析成"启用"，与 CSS 语义相反

- **位置**：`f_svg/src/SvgComputedStyle.cj:445-453`（`for (value in ["none", "common-ligatures", ...]) if (lower.contains(value)) return value`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「语义与命名不符 / 逻辑错误」、§2「近似重复导致的判定漂移」
- **证据**：静态确定 —— `font-variant-ligatures: no-common-ligatures` 经 `SvgStyleResolver` 校验后原样存入（`f_svg/src/SvgStyleResolver.cj:837-843` 接受 `contains("common-ligatures")` 并返回原串），`fontVariantLigatures()` 里 `"no-common-ligatures".contains("none") == false`、`contains("common-ligatures") == true` → 返回 `"common-ligatures"`。下游 `SvgFontFeatures.fromStyle` 的 `case "common-ligatures"` 会把 `liga` / `clig` 置为 **true**（`f_svg/src/SvgFontVariant.cj:191-193`），即"显式关闭连字"反而打开连字。`no-contextual` 同理返回 `"contextual"` 并打开 `calt`。
- **描述**：文本整形结果与作者声明相反，且没有任何 warning；`no-discretionary-ligatures` / `no-historical-ligatures` 同样反向。现有测试只覆盖 `small-caps` 与 `font-feature-settings`（`SvgFontDetailsM6_test.cj:241-244`），没有 `no-*` 用例。
- **建议**：按 `splitCssWhitespaceWords` 逐词精确匹配，先处理 `no-` 前缀（`none`/关闭对应特性），再匹配正值；或直接返回 `SvgFontFeatures` 而不是字符串。补 `no-common-ligatures` / `no-contextual` 两条断言。

### [一般][存量] #6 `SvgManualClock.stop()` / `start()` 对 `now()` 完全没有影响，`enabled` 是只写不读的死字段

- **位置**：`f_svg/src/SvgClock.cj:26`（`private var enabled = true`）、`32-34`（`now()` 直接返回 `time`）、`36-42`（`stop` / `start` 只改 `enabled`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §1「读了不用」、§3「公开契约承诺有行为，实际为空」、§11「契约与命名不符」
- **证据**：静态确定 —— 全仓搜索 `enabled` 在 `SvgClock.cj` 内只有 `26`、`37`、`41` 三处（两处写、零处读）；`SvgManualClock` 的 `stop` / `start` 在仓内无任何调用点，`SvgClock_test.cj` 也只测 `now()` 与 timeline 采样。README（`f_svg/README.md:609`）把 `stop` 列为公开方法。
- **描述**：调用 `stop()` 后 `now()` 仍返回 `time`，`SvgTimeline.sampleCurrent()` 继续推进动画；`start()` 无任何可观察效果。`stop` 是文档承诺的行为，实际是空操作，属于"读代码看不出来、运行时也不报错"的契约缺陷。
- **建议**：二选一——① `stop()` 时记录冻结时间（如 `frozenAt = time`），`now()` 在停止状态返回 `frozenAt`，`start()` 恢复（并明确是否需要累计暂停时长）；② 删除 `enabled` / `stop` / `start` 并同步删掉 README 条目。无论哪种都补一条 `stop()` 后 `now()` 不变的用例。

### [一般][存量] #7 外部引用/危险内容判定是字面量子串匹配：CSS 转义漏报，空 href、`mailto:`、注释里的 `@import` 误报

- **位置**：`f_svg/src/SvgBuilder.cj:396-407`（`externalCssUrlTarget`）、`410-443`（`externalUrlTarget` 只找字面 `url(`）、`445-463`（`handleHrefValue`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §10「安全性：外部输入未校验」、§11「错误处理缺失 / 误判」、§13（安全承诺）
- **证据**：静态确定 ——
  - **漏报**：`externalUrlTarget` 逐字节匹配 `u r l (`（`414-416`），CSS 允许标识符转义，`u\72l(http://evil)`、`@im\70 ort url(...)` 都合法且会被浏览器 CSS 解析器还原成 `url(` / `@import`，本扫描器全部放行；`<style>` 内容与 `style` 属性走同一函数（`173-190`、`367-372`）。若调用方把清洗后的 DOM 再序列化交给浏览器，这是可绕过 `allowExternalReferences=false` 的路径。
  - **误报**：`href=""`（合法的"无引用"）在 strict 模式下进入 `handleHrefValue` 后 `allowed` 为 false，直接抛 `Security`（`459-461`）；`href="mailto:a@b"`（`<a>` 的正常链接）同样被当作外部资源拒绝/移除；CSS 注释或字符串里出现 `@import` 字样（如 `/* @import unsupported */`）会让整个 `<style>` 被移除（`403-405` + `185-187`），strict 模式下直接抛错。
- **描述**：同一处用"文本包含"代替 CSS/URL 词法分析，同时存在安全漏报与合法输入误报。误报的后果是 strict 模式拒绝合法文档、宽松模式丢样式/丢链接且只留一条 warning。
- **建议**：`href` 先判空串 / 只含空白 → 视为无引用直接放行；按 scheme 白名单处理（`mailto:` / `tel:` 单独放行或明确文档化为不支持）。CSS 侧至少做一次转义反转义（`\XX` 与 `\c`）后再生效，或直接复用 `CssLexer`（`CssStyleSheet.parse` 已在用）拿 token，再判 `url` / `@import`，避免注释与字符串误判。

### [一般][存量] #8 安全过滤对非 SVG 命名空间的元素整体短路，`foreignObject` 内的 XHTML 事件属性与 `javascript:` 引用被原样保留

- **位置**：`f_svg/src/SvgBuilder.cj:340-342`（`if (elementNamespace != SvgNamespaces.SVG) { return false }`）、`358-360`（属性不在 SVG 命名空间也直接放行）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §10「安全性：注入」、§11「契约与实现不符」
- **证据**：静态确定 —— `shouldRemoveAttribute` 一进入就按元素的命名空间短路；`buildSvgChildren` 会把这些元素完整保留为 `SvgUnknownElement`（`169-171`），`SvgWriter` 再按原 QName 序列化。于是 `<foreignObject><div xmlns="http://www.w3.org/1999/xhtml" onclick="…" href="javascript:…">` 里的 `onclick` / `javascript:` 不会被 `unsafePolicy` / `allowEventAttributes` 处理（`<script>` 元素因为按 local name 判断仍会被移除，见 `134-149`）。`xml:onclick` 这类带命名空间的属性同样绕过 `on` 前缀检查（`361-366` 只在 `uri.isNone()` 时生效）。
- **描述**：`SvgSecurityOptions` 的语义是"不安全内容的处理策略"，但只覆盖 SVG 命名空间。渲染器本身不执行脚本，所以直接危害有限；一旦调用方把清洗后的文档再交给浏览器/HTML 引擎（上传 SVG 的典型链路），就是存储型 XSS 面。属"安全承诺的边界未写清 + 实现遗漏"。
- **建议**：把事件属性检查提到命名空间判断之前（对 `local` 以 `on` 开头、`href` / `src` / `style` 统一过滤，不看命名空间）；或在 README / 选项注释里明确"只清洗 SVG 命名空间内容，foreignObject 内容由调用方负责"，并给出剥离 foreignObject 的选项。

### [一般][存量] #9 `warnings` 无上限、无去重，路径字符串随深度线性放大 —— 病态文档可用警告洪泛把输入放大数倍

- **位置**：`f_svg/src/SvgBuilder.cj:25`（`SvgBuildContext.warnings`）、`140`、`167`、`203`、`215`、`224`、`232`、`477`、`503`、`522`（各 warning 追加点）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §5「无界容器」「按不可信规模分配」、§6.4（重复字符串拼接）
- **证据**：静态确定 —— `warnings` 是普通 `ArrayList<String>`，只在 `buildSvgDocument:77-79` 整体复制到 `document`，没有任何条数上限或同类合并。每条 warning 都拼接 `elementPath`（`100` 行按层累加 `tag[index]`），单个元素的路径长度 = O(深度)。`maxElements` 默认 1,000,000，且单元素可有任意多个非法属性 —— 1M 元素 × 每条 30–200 B 的警告 ≈ 30–200 MB，深度 100 的深层文档还会把每条路径放大到约 1 KB。
- **描述**：输入大小与警告内存不成比例（path 重复构造是主要放大项），且 `document.warnings` 会把条目再存一份引用。对上传/第三方 SVG 是低成本的内存放大面；warning 数量也失去可读性（同一元素的同类错误不合并）。
- **建议**：给 `SvgBuildContext` 加 `warningLimit`（例如 1000 条），超限后只保留一条"已省略 N 条警告"；同类 warning 按 `(kind, path)` 去重；路径用共享前缀或只在需要时拼接，不要在热路径上为每条 warning 重建整条路径。

### [一般][存量] #10 `SvgCoverageMask` / `SvgClipCoverage.render` 不校验 maxPixels，公开 API 可直接分配任意 `w×h`

- **位置**：`f_svg/src/SvgClipMask.cj:27-34`（`Array<Byte>(width * height, repeat: 0)`）、`36-43`；`f_svg/src/SvgClipProperty.cj:121-129`（只判 `> 0` 就 `SvgCoverageMask` + `SvgBitmap`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §5「按不可信长度预分配」、§11「缺少边界校验」
- **证据**：静态确定 —— 同模块的 `SvgGroupCompositor.createLayer` 明确"按 `maxPixels` 校验后创建离屏层"（`SvgClipMask.cj:154-158`），但 `SvgCoverageMask` 的两个公开构造函数、`SvgClipCoverage.render` 都没有对应校验：`SvgClipCoverage.render(rect, matrix, 100_000, 100_000)` 会先分配 10^10 B 的覆盖率数组，再分配 4×10^10 B 的 scratch 位图（`129`），直接 OOM；`width * height` 也没有溢出保护（对比 `SvgBitmap.cj:97-100` 有 `width > Int64.MAX / height` 检查）。
- **描述**：渲染器主路径传入的是已校验的位图尺寸，所以目前不炸；但这两个类型是公开 API（`SvgCoverageMask` 可直接构造、`SvgClipCoverage` 供外部复用），调用方按默认语义传入画布尺寸时没有任何拒绝路径，"到 OOM 才知道"。
- **建议**：`SvgCoverageMask` 构造函数接收/复用 `SvgRenderOptions.maxPixels`（或新增 `limit` 参数，默认 64M 像素）并在分配前 `width > maxPixels / height` 抛 `SvgException(kind: Limit)`；`SvgClipCoverage.render` 增加 `options!: SvgRenderOptions` 或至少把 `maxPixels` 透传；同时补 `width * height` 的溢出检查。

### [一般][存量] #11 `SvgClipProperty.parse` 丢弃 `SvgLength.unit`：`rect(2em, ...)`、`rect(1cm, ...)` 被当成 2 / 1 用户单位

- **位置**：`f_svg/src/SvgClipProperty.cj:73-79`（`values.add(Some(length.value))`）、`100-108`（`toBounds` 直接用这些裸值）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「语义与数据错误」、§10「语言特性：类型信息被丢弃」
- **证据**：静态确定 —— `parse` 只取 `length.value`，`unit` 被丢弃；`toBounds` 也不接收 `SvgLengthContext`。`clip: rect(1cm, 10cm, 10cm, 0)` 会得到 1×10 的裁剪框而不是 37.8×378；`rect(1em, …)` 同样按 1 用户单位处理。`SvgLength.toUserUnits`（`f_svg/src/SvgLength.cj:205`）已经提供了带 `dpi`/`fontSize` 的换算，但这里没用。百分比虽然不符合 CSS 2.1 的 `clip` 语法，当前也会被当作裸值接受（`50%` → 50）。
- **描述**：单位不同的合法 `clip` 值得到静默错误的裁剪区域（差 37 倍以上），且 `normalize()` 会把错误值重新写成无单位的 `rect(1, 10, 10, 0)`，问题在 round-trip 后被"固化"。
- **建议**：`parse` 保留 `SvgLength`（或至少拒绝非 `Number`/`Px` 单位并记 warning），`toBounds` 增加 `SvgLengthContext` / `fontSize` 参数走 `toUserUnits`；百分比按 CSS 2.1 直接判非法。补 `cm` / `em` 两条用例。

### [轻微][存量] #12 `renderClipChildren` 与 `renderMaskChildren` 是约 110 行的逐段复制，已经产生行为漂移

- **位置**：`f_svg/src/SvgClipMask.cj:315-462` 与 `464-590`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §2「换控制流 / 跨函数复制」
- **证据**：静态确定 —— 两段的结构、参数列表、`childStyle` 计算、`childBounds` 计算、`clipId`/`maskId` 解析、`layer` 分配、`applyClipReference`/`applyMaskReference` 调用顺序逐行对齐；唯一语义差异是叶子绘制（clip 用 `SvgRasterizer.fill(..., SvgColor.Black, fillRule)`，mask 用 `drawMaskPath`）和 `fillRule` 是否传递。漂移已经发生：clip 侧会按 `clip-rule` 传 `fillRule`（`367-374`、`396-403`），mask 侧根本不传（`514`、`533`），直接导致 #2 的 evenodd 错误。
- **描述**：两份实现各自演进，任何一边补 display/visibility/文本/图像支持都会漏掉另一边；当前两个函数的差异点没有注释说明。
- **建议**：合并成一个遍历，把"叶子如何画"作为参数（`leaf: (SvgElement, SvgPathData, SvgMatrix, SvgBitmap) -> Unit`，外加 `fillRule` / `style`），clip 与 mask 只提供各自的叶子实现；合并后补一组"同一文档分别走 clip/mask"的对照用例。

### [轻微][存量] #13 属性值校验有两套表：`SvgBuilder.isValidSvgAttribute` 与 `SvgStyleResolver.normalizeValue`，覆盖集合与失败行为都不同

- **位置**：`f_svg/src/SvgBuilder.cj:525-596`（`case _ => true` 在 `594`；`color` / `stop-color` 接受 `"none"` 在 `528-531`；`x`/`y` 用 `parseSvgLengthList` 在 `539`）与 `f_svg/src/SvgStyleResolver.cj:548-561`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §2「同一组规则散落多处 / 近似重复」、§11「校验不一致」
- **证据**：静态确定 —— 同一属性在两条路径上规则不同：`stop-color="none"` 被属性校验判为合法（`531`），CSS 侧 `normalizeColor` 会判非法并回退黑；`x="1 2"` 被属性校验接受（列表解析），而 `x` 只允许单值；`vector-effect` / `mix-blend-mode` / `paint-order` / `isolation` / `dominant-baseline` / `shape-rendering` 等已在 `SVG_PROPERTY_TABLE` 里的属性在 `isValidSvgAttribute` 中没有分支，走 `_ => true`，strict 模式既不抛也不 warn；失败行为也不同（属性校验 strict 抛 `InvalidValue`，CSS 侧只加 warning）。
- **描述**：strict 模式的"严格"程度取决于属性是写在 XML 属性上还是 `style` 里，同一份文档改个写法行为就变；后续新增属性需要同时改两张表，容易漏。
- **建议**：抽一张 `属性名 → 校验函数` 的单一表，CSS 与属性两条入口共用；失败策略（strict 抛 / 宽松 warn）作为参数传入，而不是各写一套；把 `SVG_PROPERTY_TABLE` 与校验表做成同源生成。

### [轻微][存量] #14 `SvgClipPathMasker.render` / `SvgMasker.render` 的 `units` 默认值与元素自身属性脱节

- **位置**：`f_svg/src/SvgClipMask.cj:78-110`（`units!` 默认 `UserSpaceOnUse`，不读 `clip.attr("clipPathUnits")`）、`115-149`（`maskUnits` / `maskContentUnits` 默认值，不读元素属性）；对照 `652-654`、`703-708`（嵌套引用路径会读属性）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「契约与实现不符」、§10「API 设计」
- **证据**：静态确定 —— 顶层 `render(clip)` 直接调用时完全忽略 `clipPathUnits="objectBoundingBox"` / `maskUnits` 属性；只有 `applyClipReference` / `applyMaskReference` 内部才会读属性。渲染器主路径在 `SvgRenderer.cj:714-717`、`736-741` 手工读取并传入，所以内部自洽；外部调用方按"传元素就能渲染"的直觉使用时，`objectBoundingBox` 会被静默当作 `userSpaceOnUse`。
- **描述**：同一语义在两条入口上有两套行为，且默认参数看起来像"已处理"，实际是"调用方必须自己解析属性"。文档注释没有提示这一点。
- **建议**：`units` / `maskUnits` / `maskContentUnits` 改为 `?SvgCoordinateUnits = None`，为 `None` 时读元素属性（再回退默认值）；或在注释与 README 明确"调用方负责解析单位属性"。

### [轻微][存量] #15 `XmlNode.EntityRefNode` 被静默丢弃，strict 模式也不报错，round-trip 后实体引用消失

- **位置**：`f_svg/src/SvgBuilder.cj:110`（`case XmlNode.EntityRefNode(_) => ()`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「错误处理缺失」、§13「序列化一致性」
- **证据**：静态确定 —— 该分支既不保留节点也不加 warning。`f_xml` 自己的解析器对未声明实体走"跳过 + 告警"（`f_xml/src/ParserEngine.cj:470-473`），不会产出该节点；但 `XmlEntityRef` 是公开构造函数（`f_xml/src/XmlNode.cj:53-55`），`SvgParser.parse(xmlDocument)` 允许调用方传入含实体引用节点的 DOM，此时 `SvgWriter` 本可原样写回 `&name;`（`f_xml/src/XmlWriter.cj:429`），经过 `buildSvgChildren` 后该节点消失，且 strict 模式不会把它当作语法/安全问题。
- **描述**：从文本解析的路径基本不可达（未声明实体已在 f_xml 侧告警并跳过），主要影响"复用已构造 DOM"的调用方：实体引用在 round-trip 后静默丢失，排查时只能看到文本少了一段。
- **建议**：至少记 warning（含实体名）并按 `unsafePolicy` 决定保留/移除；strict 模式直接抛 `Syntax`/`Security`。

### [轻微][存量] #16 `SvgBuilderM7_test` 依赖当前工作目录下的 `target/` 与固定文件名，测试不可并行且会留脏文件

- **位置**：`f_svg/src/SvgBuilderM7_test.cj:487`（`"target/m7-card.svg"`）、`488`、`494`、`514`、`555`、`626`（`File.createTemp(Path("target"))`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §10「可测试性」、§11「资源/环境假设」
- **证据**：静态确定 —— 用例直接写模块相对的 `target/`，没有 `mkdir`；`save` 的失败用例（`514`）又依赖 `target/m7-missing-dir` 不存在。`target/` 不存在时 `File.createTemp` 与 `save` 全部失败；两个测试进程并行跑同一模块会互相覆盖同名文件（`m7-card.svg`、`m7-design-card.svg`）。
- **描述**：在干净检出或沙箱里跑 `cjpm test` 会因目录缺失而失败；并行/重复执行结果不确定，且残留文件没有清理。
- **建议**：用 `std.fs` 的临时目录 API 或 `File.createTemp` 返回的路径做基目录，测试结束删除；失败用例用随机不存在的子目录名。

### [严重][存量] #17 用「字节长度 + 定长字节切片」识别前缀关键字，非 ASCII 输入抛 `IllegalArgumentException` 穿透 `SvgException` 契约

- **位置**：
  - `f_svg/src/SvgBuilder.cj:451`（`lower[0..5] == "data:"`，`handleHrefValue`）
  - `f_svg/src/SvgBuilder.cj:467-469`（`lower[0..5] == "http:"` / `lower[0..6] == "https:"` / `lower[0..2] == "//"`，`isPermittedExternalReference`）
  - `f_svg/src/SvgBuilder.cj:361`（`local.size > 2 && local[0..2].toAsciiLower() == "on"`，`shouldRemoveAttribute`；该处还取决于 `f_xml` 是否接受非 ASCII 名称，其余四处只依赖属性值，必然可达）
  - `f_svg/src/SvgClipMask.cj:734`（`trimmed[0..4].toAsciiLower() != "url("`，`readEffectId`）
  - `f_svg/src/SvgClipProperty.cj:56`（`lower.size <= 5 || lower[0..5] != "rect("`，`SvgClipProperty.parse`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §10「安全性：外部输入未校验」、§11「边界 / 错误处理」；API 语义见标准库文档 `std/core/core_package_api/core_package_structs.md:9380`「operator func \[](Range\<Int64>)」——*「区间为 UTF-8 编码后的字节下标范围，起止点必须位于字符边界上……范围起止点不是字符边界，抛出 `IllegalArgumentException`」*
- **证据**：静态确定 —— 上述 5 处都只用「字节长度 ≥ n」做前置判断，再按固定字节数切片；`toAsciiLower()` 只改 ASCII 字节、不改变 UTF-8 字节长度，因此非 ASCII 前缀一定把切点落在多字节字符中间。最小触发输入：`<image href="中文"/>`（`中` 占 3 字节，`lower[0..5]` 切在 `文` 的第 2、3 字节之间）、`<rect clip-path="中文"/>`（`readEffectId` 的 `[0..4]`）、`<rect clip="中文字"/>`（`SvgClipProperty.parse` 的 `[0..5]`）。`SvgParser.loadXml`（`SvgParser.cj:96-104`）只把 `XmlException` 包装成 `SvgException`，`buildSvgDocument` 内抛出的 `IllegalArgumentException` 直接穿透到调用方。
- **描述**：前缀关键字识别用字节切片比较而不是字符串前缀比较，于是任意中文/emoji 开头的 `href`、`clip-path`、`mask`、`clip`、事件属性名都会让解析抛出错误的异常类型（按文档只捕获 `SvgException` 的调用方会漏捕，进程内未捕获异常）。这是不可信 SVG 输入上的确定性崩溃路径，且与 #7 的「外部引用判定」共用同一批函数——修 #7 时若仍保留 `[0..n]` 写法，漏报修好了、崩溃面还在。
- **建议**：全部改成前缀比较：`lower.startsWith("data:")`、`lower.startsWith("http:")`、`lower.startsWith("https:")`、`lower.startsWith("//")`、`trimmed.startsWith("url(")`、`lower.startsWith("rect(")`、`local.startsWith("on")`（`startsWith` 已是本模块惯用法，见 `SvgComputedStyle.cj:199`）。顺便全仓 grep 一次 `\[0\.\.` / `\[1\.\.` 的定长前缀切片，逐处确认切点落在 ASCII 字节上（`SvgColor.cj` 的 `'#'` / `'('` / `'%'` / `"deg"` 四处已逐个核对，安全）。

### [一般][存量] #18 `maskRegion` 在 `userSpaceOnUse` 下把百分比当绝对长度，蒙版区域整体错位

- **位置**：`f_svg/src/SvgClipMask.cj:913-916`（`maskRegion` 的 userSpace 分支）→ `f_svg/src/SvgClipMask.cj:958-967`（`userSpaceValue`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「契约与规格不符」、§10「正确性：单位换算」
- **证据**：静态确定 —— `userSpaceValue` 只取 `SvgLength.value`，丢弃 `SvgLengthUnit.Percent`；同文件 `objectBoxValue`（`:931-956`）却对 `Percent` 做了 `value / 100.0`。SVG 1.1/2 规定 `mask` 的 `x`/`y`/`width`/`height` 在 `maskUnits="userSpaceOnUse"` 下百分比相对当前 viewport，`x="50%"` 应为 `0.5 × canvasWidth`，现状得到 `50` 用户单位。
- **描述**：同一文件内两种单位语境各写一套换算，其中一套漏了百分比。画布宽 1000 时 `width="50%"` 得 50 而非 500，蒙版被裁到左上角一块；若 `x="50%"` 则整体右移量差 20 倍。现有 `SvgClipMask_test.cj:139-196` 只用无单位数值，未覆盖该组合，因此测试全绿。
- **建议**：`userSpaceValue` 增加 viewport 参数，`Percent` 时返回 `value / 100.0 × viewport`；`maskRegion` 的 x/y 传画布宽高、width/height 同理。补 `maskUnits="userSpaceOnUse"` + `x="50%" width="50%"` 的用例并断言覆盖范围。

### [轻微][存量] #19 `rect` → `SvgPathData` 的五段命令在三处逐字复制

- **位置**：`f_svg/src/SvgClipMask.cj:789-797`（`elementPathData` 的 `SvgRect` 分支）、`f_svg/src/SvgClipProperty.cj:130-140`（`SvgClipCoverage.render`）、`f_svg/src/SvgRenderer.cj:1022-1031`（`rectPathData`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §2「字面量复制」
- **证据**：静态确定 —— 三处都是 `MoveTo(x,y) → LineTo(x+w,y) → LineTo(x+w,y+h) → LineTo(x,y+h) → ClosePath(空数组)`，只有变量名不同（`box.x/box.width` vs `x/width`）。
- **描述**：矩形的路径等价表示有三份，改填充方向、是否闭合或命令参数个数时要同步三处，漏一处就会让 `clip` / `clip-path` / 主渲染三条路径的 nonzero 结果不一致（`ClosePath` 缺失直接改变填充）。
- **建议**：在 `SvgPathData` 或 `SvgShape.cj` 提供 `internal func rectPathData(bounds: SvgBounds): SvgPathData`，三处改为调用；删除 `SvgRenderer` 的同名私有函数。

### [轻微][存量] #20 `clampUnit` 与 `clampSvgUnit` 是同语义两份实现，NaN 语义还不一致

- **位置**：`f_svg/src/SvgColor.cj:356-358`（`clampUnit`）、`f_svg/src/SvgStop.cj:92-100`（`clampSvgUnit`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §2「只改函数名的重复实现」
- **证据**：静态确定 —— 函数体都是 `value < 0 → 0; value > 1 → 1; else value`，都不处理 NaN；`SvgColor.clampUnit` 等价于 `clampSvg(v, 0.0, 1.0)`。调用方按名字分散选择（`SvgBitmap`/`SvgBlend` 用 `clampSvgUnit`，`SvgColor` 内部用 `clampUnit`）。
- **描述**：同语义两个名字，新增调用点容易选错；`SvgColor.clampAlpha` 单独拒绝 NaN，而 `clampSvgUnit` 放行 NaN，NaN 输入经 `quantizeSvgChannel` 会得到 `Int64(round(NaN))` 的未定义结果。两处归一化不统一是潜在数值缺陷源。
- **建议**：保留引用面更广的 `clampSvgUnit`，删除 `SvgColor.clampUnit` 并内部改调；同时一次性定死 NaN 行为（建议与 `clampAlpha` 一致，显式拒绝或归 0）。

### [轻微][存量] #21 `maxI64` / `minI64` 重复 `std.core` 的泛型 `max` / `min`

- **位置**：`f_svg/src/SvgClipMask.cj:969-975`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §2「标准库已有能力却自写」
- **证据**：静态确定 —— `std/core/core_package_funcs.md:366 / :433` 提供 `func max<T>(T, T, Array<T>) where T <: Comparable<T>` 与 `min`，`Int64 <: Comparable<Int64>`；同模块其他文件已直接用 `max`/`min`（`SvgFilterRenderer.cj:88-91`、`SvgFilterPrimitives2.cj:1416`）。
- **描述**：模块内并存「用标准库 `max`」与「自写 `maxI64`」两种写法，读者要确认两者在相等时返回哪个参数（自写版返回 `second`），增加无谓认知成本。
- **建议**：删除 `maxI64`/`minI64`，改用 `max`/`min`。

### [轻微][存量] #22 `warnOffsetIfClamped` 复刻了 `tryParseSvgOffset` 的百分比归一化，同一 `offset` 值被解析两遍

- **位置**：`f_svg/src/SvgBuilder.cj:484-507`（`warnOffsetIfClamped`）vs `f_svg/src/SvgStop.cj:102-121`（`tryParseSvgOffset`）；调用点 `f_svg/src/SvgBuilder.cj:289-293`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §2「换算复制」
- **证据**：静态确定 —— 两处都做「去尾 `%` → `value / 100.0` → 与 `0.0 / 1.0` 比较」，区别只是前者产出 warning、后者返回钳制值；`fillSvgAttributes` 先在 `validateSvgAttribute` 里调 `tryParseSvgOffset`，紧接着在 `warnOffsetIfClamped` 里再解析一遍同一字符串。
- **描述**：归一化规则有两份，`tryParseSvgOffset` 若改单位支持或钳制策略，告警判断会与实际取值脱节（出现「告警说不越界、实际被钳制」或反之）。
- **建议**：抽 `internal func normalizeSvgOffset(text: String): ?(Float64, Bool)`（值 + 是否越界），两个调用点共用，顺带消掉重复解析。

### [轻微][存量] #23 `buildSvgChildren` / `collectXmlText` 的递归深度等于可配置的 `maxDepth`，而选项不校验其上限

- **位置**：`f_svg/src/SvgBuilder.cj:84-113`（`buildSvgChildren`）、`:240-251`（`collectXmlText`）、`:52`（前置 `checkDepth`）；选项 `f_svg/src/SvgOptions.cj:59-80`（只校验 `maxDecompressedBytes`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §4「无界递归：深度由配置决定」、§11「缺少边界校验」
- **证据**：待确认（深度上限是配置项，实际帧大小与栈容量需实测）—— `checkDepth` 用显式栈迭代、注释写「避免深文档在构建前就爆栈」，但真正的构建与 `<style>` 文本收集仍然是递归，深度恰好等于 `security.maxDepth`；`SvgSecurityOptions.init` 对 `maxDepth` / `maxElements` 没有任何正值或上限校验，调用方可传 `maxDepth = 1_000_000`。
- **描述**：默认 512 层时安全，但只要调用方把 `maxDepth` 调大（或从配置读到异常值），迭代式预检会顺利通过，随后递归构建在同一深度上爆栈。预检与执行采用两套递归模型，安全边界只对默认值成立。
- **建议**：`SvgSecurityOptions.init` 给 `maxDepth` 加合理上限（如 ≤ 1024）并校验 `> 0`；或把 `buildSvgChildren` / `collectXmlText` 改成显式栈迭代，使「预检通过即可安全构建」成为真正的不变量。

### [轻微][存量] #24 `splitClipComponents` 函数体首语句与签名同行，不符合本模块格式

- **位置**：`f_svg/src/SvgClipProperty.cj:155`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §10「可读性」（`cjfmt` 会拆行）
- **证据**：静态确定 —— `private func splitClipComponents(body: String): Array<String> {    let result = ArrayList<String>()`，本模块其余函数均为换行缩进风格。
- **建议**：跑 `cjfmt -w` 或手工换行。

### [轻微][存量] #25 文件名 `SvgBuilder.cj` 与内容不符（内容是 `buildSvgDocument`，公开类 `SvgBuilder` 在 `SvgAuthoringBuilder.cj`）

- **位置**：`f_svg/src/SvgBuilder.cj:34`（`buildSvgDocument`）；公开类 `SvgBuilder` 位于 `f_svg/src/SvgAuthoringBuilder.cj`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §10「可读性 / 可维护性」
- **证据**：静态确定 —— 本文件全部符号为 `internal`/`private`（`SvgBuildContext`、`buildSvgDocument`、`buildSvgChildren`…），无 `SvgBuilder` 类型；`SvgBuilderM7_test.cj` 测的是 `SvgAuthoringBuilder.cj` 的 `SvgBuilder`，与被审文件无关（#16 的落盘用例也属后者）。
- **描述**：按文件名找 `SvgBuilder` 实现会落到 XML→模型 构建器上，改动序列化逻辑时容易改错文件；测试文件与实现文件不成对也源于此。
- **建议**：改名为 `SvgDocumentBuilder.cj`（纯移动，不涉及逻辑），与 `SvgAuthoringBuilder.cj` 区分。

### [轻微][存量] #26 `SvgComputedStyle.cj` 的 `fountain::f_base` 导入疑似未使用

- **位置**：`f_svg/src/SvgComputedStyle.cj:20`（`import fountain::f_base.*`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §1「未使用的 `import`」
- **证据**：待确认 —— 文件内出现的类型/函数（`HashMap`、`ArrayList`、`AtomicInt64`、`StringBuilder`、`SvgLength`、`SvgColor`、`tryParseSvgFloat`、`splitCssWhitespaceWords`、`svgPaintOrderOf`）分别来自 `std.collection` / `std.sync` / 本包，未发现 `f_base` 的 `invalidValue` / `syntaxError` / 日志宏等符号；需 `cjlint` 或构建警告确认（本轮不跑构建）。
- **建议**：跑一次 `cjlint`，报 `unused import` 则删除该行，否则保留。

## 优化可行性方案

> 以下均为"还能更好"，无改前/改后基线，按 reviewer 约定标 `无基线（待验证）`，不进修复清单。

### [堆内存] 计算样式对每个元素做 75 属性全量快照

- **现状**：每个 `SvgComputedStyle` 持有 `values`（约 75 个条目）、`sources`（约 75 个条目）、`varExpressions`（少量）三张 `HashMap`（`f_svg/src/SvgComputedStyle.cj:169-172`）；样式树按元素建一份（`SvgStyleResolver.cj:111`、`399`）。10 万元素文档约 1500 万条 map 条目；若条目 + 桶开销按 32 B 估，约 480 MB 常驻，文档规模线性放大。
- **方案**：只物化"与 initial 不同"的属性，`get()` 沿父链回退；`sources` 只存非 `Default`/`Presentation` 的项；`varExpressions` 已经是稀疏的，保持。或者把 75 个初始值做成共享不可变表，元素只存覆盖项。
- **预期**：常规文档每元素非默认属性通常 < 10 个，条目数预计降 80% 以上；峰值 RSS 与 GC 压力同步下降。
- **代价**：`get()` 从 O(1) 变成"沿父链 + 默认表"查找，`toString()`/`customProperties()` 需要遍历合并；继承语义（尤其 `currentColor`、`var()` 展开）要逐条回归；`SvgComputedStyle` 是 public 类型，字段布局变化不影响 API，但性能特征变化需写进文档。
- **验证**：同机器、`-O2`，分别用 1k / 10k / 100k 元素的合成文档跑 `SvgParser.parse` + 样式树构建，记录 `getAllocatedHeapSize()` 峰值、RSS、`getUsedHeapSize()` 与构建耗时中位数/离散度；与现状对照。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] 蒙版渲染复用 scratch 位图与覆盖率缓冲，按引用层数做常数上限

- **现状**：每次 `renderClipCoverage` / `renderMaskCoverage` / `SvgClipCoverage.render` 都新建 `SvgBitmap`（`f_svg/src/SvgClipMask.cj:230`、`275`；`f_svg/src/SvgClipProperty.cj:129`）与 `Array<Byte>(width*height)`（`SvgClipMask.cj:251`、`295`；`SvgClipProperty.cj:124`）；循环引用时 64 层各分配一套（见 #1），峰值 ≈ 9 B/px/层。
- **方案**：一次渲染内共享一个 `SvgMaskScratch`（`bitmap` + `coverage` + 复用计数），嵌套层按需清零复用；层数上限设为常数（如 8），超限抛 `Limit`。
- **预期**：循环引用的峰值从「64 × 9 B/px」降到「常数 × 9 B/px」，非循环场景每次少 2 次全画布分配。
- **代价**：复用必须严格清零（漏清会产生上一层残影）；`SvgCoverageMask` 当前直接持有外部 `Array<Byte>`，复用期间要禁止把内部缓冲交给调用方（或改为拷贝出）。
- **验证**：同输入下 `getAllocatedHeapSize()` 峰值与 RSS 对照，加像素级回归（`SvgClipMask_test` / `SvgClipRenderM4_test` 逐字节一致）。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 嵌套 clip/mask 按整幅画布光栅化与合成

- **现状**：`renderClipCoverage` / `renderMaskCoverage` 每次分配 `w×h` 位图（`SvgClipMask.cj:230`、`275`），`renderClipChildren` / `renderMaskChildren` 为每个带 clip/mask 的子元素再分配整幅 `layer`（`393`、`531`）并整幅 `composite`（`458`、`586`）；实际被裁剪的内容通常只占画布很小一块。
- **方案**：先算子元素设备空间包围盒（含描边/抗锯齿余量），按包围盒分配小 layer、只在该区域光栅化与合成；引用深度进入时判环（同时解决 #1 的 64 层重复计算）。
- **预期**：典型图标元素占画布 < 10% 时，layer 像素与合成工作量降约一个数量级；#1 的 1080p 峰值随之下降。
- **代价**：需要可靠的 device bbox（描边、滤镜、变换后的包围盒），合成坐标要带偏移；`Normal` 路径必须保持与 M4 逐字节一致，需要全量图像回归；`mask` 的 luminance 仍需整幅背景（可只算 region 内的像素）。
- **验证**：`cjpm bench -O2`，1000×1000 画布、嵌套 1/5/10 层各跑多轮，记录 p50/p95 与 `cjprof` self time；同时对比现有输出的逐像素哈希。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `SvgBuilder` 构建前做两趟全量遍历，且每个元素都新建 path 计数 `HashMap`

- **现状**：`buildSvgDocument` 先 `countXmlElements`（BFS，`ArrayList` 持有全部元素，`SvgBuilder.cj:630-647`），再 `checkDepth`（第二趟 BFS，`660-677`），最后递归构建；`buildSvgChildren` 对每个元素（含叶子）新建 `HashMap<String, Int64>` 做同级索引（`92`）。
- **方案**：构建时单趟完成"元素数 + 深度"检查（提前 fail-fast 可在进入子节点前判断，仍能保持"先检查后构建"的错误语义）；`counters` 只在存在元素子节点时创建，或复用一个按层清空的 map。
- **预期**：DOM 遍历 3 趟 → 1 趟；每元素至少少一次 `HashMap` 分配，10 万元素文档预计减少 10 万次小对象分配与相应 GC。
- **代价**：错误抛出时机从"构建前"变成"构建中"（部分 DOM 已构造，但不会泄漏给调用方）；`maxElements` 的判定需要在新位置保持同样的 `Limit` 异常与消息。
- **验证**：`cjpm bench -O2` 构建 1k/10k/100k 元素文档，记录构建 p50/p95 与 `cjprof` 分配采样；对比 `SvgException` 消息与 kind。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

> 无性能测试数据，仅作为下一轮补数据清单，不计入统计、不进 `todo.md` / `tasks.md`。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `SvgColor.parse` 对命名色线性扫描 148 项，且同一属性值会被属性校验、样式解析、画笔解析多次调用，可能占解析时间可观比例 | `f_svg/src/SvgColor.cj:105-115`、`SvgBuilder.cj:527-530` | 该函数 self time 占比、每文档调用次数 | `cjprof record` 解析 1 万条 `fill="颜色名"` 的文档；或加计数器统计调用次数 |
| 2 | `SvgBuilder` 每条 warning 重建整条 `elementPath` 字符串，在非法属性密集的文档中是主要分配源 | `f_svg/src/SvgBuilder.cj:100`、`140`、`503`、`522` | 分配采样、每条 warning 平均长度与条数 | 构造 1 万元素 × 每条 2 个非法属性的文档，`cjprof` 分配采样 + 统计 warning 数与内存 |
| 3 | `SvgClipMask` 的 mask 覆盖率按整幅画布逐像素扫描（`renderMaskCoverage:296-311`），小区域蒙版时浪费明显 | `f_svg/src/SvgClipMask.cj:293-312` | region 面积占比与函数 self time | 1000×1000 画布、mask region 10% 的场景跑 `cjprof`，对比只扫描 region 的临时改造 |
| 4 | `SvgComputedStyle` 的 `findSvgPropertySpec` 线性扫描 75 项，CSS 规则多时是热点 | `f_svg/src/SvgComputedStyle.cj:154-161`、`SvgStyleResolver.cj:461`、`493` | 调用次数与 self time 占比 | 1 万条 CSS 声明的文档跑 `cjprof`，统计 `findSvgPropertySpec` 样本数 |
| 5 | 每元素一个 `SvgComputedStyle` + 三张 HashMap 的构建成本是样式解析的主要开销 | `f_svg/src/SvgStyleResolver.cj:237-399` | 样式构建占端到端解析时间的比例 | 10 万元素文档分段计时（DOM 构建 / 样式 / 渲染），并采样 `getAllocatedHeapSize()` |
| 6 | 蒙版/组合成逐像素 `layer.pixel()` / `destination.pixel()` / `setPixel()`（每像素构造 `SvgColor`/`SvgRgba` 并多次 `clamp`/`round`）是合成阶段主要自耗时 | `f_svg/src/SvgClipMask.cj:185-206`、`:296-311` | `SvgGroupCompositor.composite` 与 `quantizeSvgChannel` 的 self time 占比 | `cjprof record` 渲染 100 张带 mask 的 512×512 图后 `cjprof report` |
| 7 | clip 渲染对每个子元素重建 `SvgPathData`（`elementPathData` 内含 `ArrayList`→`Array` 与命令数组分配）是热点 | `f_svg/src/SvgClipMask.cj:363`、`:511`、`:779-852` | 每图调用次数与自耗时 | 同 #6 的 profile，另加计数器统计 `elementPathData` 调用数 |
| 8 | 属性校验（`isValidSvgAttribute`）与类型化 getter 对同一属性值各解析一次，占解析时间可观 | `f_svg/src/SvgBuilder.cj:289-295`、`:525-596` | 解析阶段耗时占比与重复解析次数 | 10 MB / 10 万元素 SVG 分段计时包住 `buildSvgDocument` 与属性读取 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_svg/src/SvgBounds_test.cj` | .cj | ✅ | 断言与 `SvgBounds.empty()` 的 `(0,0,-1,-1)` 哨兵一致，无缺陷 |
| 2 | `f_svg/src/SvgBuilder.cj` | .cj | ✅ | 见 #7 / #8 / #9 / #13 / #15；第二轮补 #17 / #22 / #23 / #25 |
| 3 | `f_svg/src/SvgBuilderM7_test.cj` | .cj | ✅ | 见 #16；功能断言本身有效 |
| 4 | `f_svg/src/SvgCircle.cj` | .cj | ✅ | 三个 `SvgValueCache` 按 `attributesVersion` 失效，逻辑正确 |
| 5 | `f_svg/src/SvgClipMask.cj` | .cj | ✅ | 见 #1 / #2 / #3 / #4 / #10 / #12 / #14；第二轮补 #17（`readEffectId`）、#18、#21 |
| 6 | `f_svg/src/SvgClipMask_test.cj` | .cj | ✅ | 覆盖纯色蒙版/裁剪/环/深度上限；未覆盖继承 fill、渐变、evenodd、文本蒙版 |
| 7 | `f_svg/src/SvgClipProperty.cj` | .cj | ✅ | 见 #10 / #11；第二轮补 #17（`parse` 前缀切片）、#19（rect→path 第二份）、#24（格式）；`normalize` 仅测试引用，作可见性建议 |
| 8 | `f_svg/src/SvgClipPropertyM4_test.cj` | .cj | ✅ | 断言与 `parse` 的逗号/空格/auto 行为一致 |
| 9 | `f_svg/src/SvgClipRenderM4_test.cj` | .cj | ✅ | 端到端 `clip` 用例，无缺陷 |
| 10 | `f_svg/src/SvgClock.cj` | .cj | ✅ | 见 #6（第二轮复核一致：`enabled` 只写不读，`stop`/`start` 无观察效果） |
| 11 | `f_svg/src/SvgClock_test.cj` | .cj | ✅ | 只测 `now()` / timeline，未覆盖 `stop` / `start`（与 #6 对应） |
| 12 | `f_svg/src/SvgColor.cj` | .cj | ✅ | 解析/序列化/round-trip 正确；命名表 148 项与测试列表逐条一致（第二轮用脚本比对过）；性能线索见待验证 #1；第二轮补 #20（`clampUnit`） |
| 13 | `f_svg/src/SvgColor_test.cj` | .cj | ✅ | 覆盖 hex/rgb/hsl/命名色/非法输入；`names.size == 148` 与实现表一致 |
| 14 | `f_svg/src/SvgComputedStyle.cj` | .cj | ✅ | 见 #5；`get` 的规范化由 `SvgStyleResolver` 物化时保证，注释与实现一致；第二轮补 #26（`f_base` 导入待确认） |
| 15 | `f_svg/src/SvgComputedStyleM4_test.cj` | .cj | ✅ | 初始值/继承/CSS 关键字断言与实现一致 |

合计：`.cj` 15 个 / `.md` 0 个 / 共 15 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 26 | 26 条发现均至少涉及其中一项：`SvgLength.unit` 丢弃、mask 画笔语义、OBB 目标盒、ligatures 反向、单位参数脱节（第一轮）；非 ASCII 字节切片崩溃、`maskRegion` 百分比、clamp/max 双份实现、命名/导入/格式（第二轮） |
| §1 死代码 | 2 | 逐个 private/internal 顶层符号全仓搜引用（全部 ≥2 处：定义 + 使用）；`protected` 本部分无；**#6** `SvgManualClock.enabled` 只写不读；**#26** `SvgComputedStyle.cj:20` 的 `fountain::f_base` 导入疑似未使用（待 `cjlint` 确认）。`SvgClipProperty.normalize` 只被测试引用 → 仅作**可见性建议**，不计死代码；`rootOfSvgElement:758` 尾表达式位于 `while (true)` 之后，可能是编译器发散分析所需，未计（待确认）；对外可达 public 无引用（`has`、`SvgComputedStyleTree.size`、`start`）仅作信息 |
| §2 重复逻辑 | 7 | 同文件两两比对函数体 + 跨文件搜同形字面量：`renderClipChildren` vs `renderMaskChildren`（#12）、属性校验两套表（#13）；第二轮补 `rect→path` 三份（#19）、`clampUnit`/`clampSvgUnit`（#20）、`maxI64`/`minI64` vs 标准库（#21）、`warnOffsetIfClamped` vs `tryParseSvgOffset`（#22）、`countXmlElements`/`checkDepth` 与 `buildSvgOne` 内联校验（两趟全量 BFS 重复同一判定，已并入优化方案「构建前两趟全量遍历」）。`maskRegion`/`objectBoxValue`/`SvgClipCoverage` 之间无同语义实现 |
| §3 空实现 | 1 | `stop` / `start` 无观察效果（#6）；无 `TODO` / 空函数体 / `catch {}` |
| §4 栈溢出 | 2 | clip/mask 元素树递归无深度计数（#3）；`buildSvgChildren` / `collectXmlText` 递归深度 = 可配置 `maxDepth` 且选项不校验上限（#23，默认 512 时安全）；`rootOfSvgElement` 为迭代 |
| §5 OOM | 3 | 嵌套引用逐层整幅位图（#1）、warnings 无上限（#9）、`SvgCoverageMask` 缺 maxPixels（#10）；`SvgBitmap` 有溢出检查 |
| §6.1 热点瓶颈 | 0 | 未提供 profile / bench 数据，热点结论不成立；候选见「待验证假设」#1–#8 |
| §6.2 大粒度锁 | 0 | 本部分无锁 / `synchronized` / 共享容器 |
| §6.3 并发串行 | 0 | 无 `spawn` / `Future.get` / 并发批处理 |
| §6.4 低效算法 | 0 | 线性颜色表、`findSvgPropertySpec` 线性扫描、每元素 path 拼接均为复杂度线索，缺 self time 数据，已列入待验证假设，不作发现 |
| §7 降堆内存方案 | 2 | 计算样式全量快照、蒙版 scratch 复用（见优化方案） |
| §8 降 CPU 方案 | 2 | 嵌套 clip/mask 整幅光栅化、`SvgBuilder` 多趟遍历 + 每元素 HashMap（见优化方案） |
| §9 local mode 可行性 | 0 | 无峰值内存数据；`renderClipCoverage` 的覆盖率数组作为返回值逃逸、位图交给 `SvgRasterizer`，`SvgComputedStyle` 进入样式树，逃逸检查不通过，收益无法用峰值内存证明 |
| §11 现有代码的 BUG（存量） | 18 | 26 条发现全部为存量，其中 18 条属本节形态（逻辑/边界/契约）；新增 #17（非 ASCII 切片抛错误异常类型）、#18（百分比当绝对长度）；`SvgCoverageMask.multiply` / `applyTo` 的尺寸与索引已核对无越界；`SvgColor.parse` 的四处定长切片切点均在 ASCII 字节上，已逐个排除误报 |
| §12 并发安全与锁粒度 | 0 | 未发现跨线程共享点：`SvgComputedStyleTree` 每次解析新建并在渲染期只读，`SvgValueCache` 属于元素实例，`SvgManualClock` 为手动单线程时钟；`warnings` 由调用方持有，未声明线程安全 |
| §14 功能完备性与 README 覆盖 | 0 | 本部分无 `.md`；README 交叉引用仅用于 #2（mask 承诺）与 #6（`stop` 承诺），合并时由含 README 的子轮统一核对 |
| 文件覆盖（§13 等） | 15/15 | 本部分无 `.md`；`.cj` 全部逐行读完，无跳过 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 3 |
| 一般 | 10 |
| 轻微 | 13 |
| 优化方案（堆内存 / CPU） | 2 / 2 |

## 总评

本部分的核心风险集中在 `SvgClipMask.cj`：嵌套 clip/mask 的"整幅画布一层"实现把"引用深度 64"直接放大成 64 倍画布内存（#1），而 mask 内容的绘制只认元素自身的纯色 `fill`，渐变/继承填充/文本/evenodd 会得到空白或反向覆盖率（#2）；这两个问题叠加，使"支持 mask"在当前实现下只对最简单的手写纯色蒙版成立。`SvgBuilder` 的安全面整体方向正确（元素/深度上限、事件属性、外部引用、`script` 都有处理），但外部引用判定用字面量匹配，既有 CSS 转义漏报也有空 `href` / `mailto:` / 注释误报（#7），且非 SVG 命名空间整体跳过过滤（#8），需要在合并报告里作为安全项单独列出。

`SvgColor`、`SvgCircle`、`SvgBounds_test`、`SvgClipPropertyM4_test` 等文件质量良好：解析/序列化有 round-trip 用例，边界与非法输入覆盖到位；`SvgComputedStyle` 的规范化与继承也有完整测试，唯一实质问题是 `font-variant-ligatures` 的 `no-*` 反向解析（#5）。

第二轮通读又补出一条同级别阻塞项：**#17「前缀关键字用字节长度 + 定长切片识别」**——`href` / `clip-path` / `clip` / 事件属性五个入口，任意中文或 emoji 开头就把切片点落在多字节字符中间，抛出的 `IllegalArgumentException` 不在 `SvgException` 契约内，`<image href="中文"/>` 即可触发。改动量只有 5 行（改 `startsWith`），风险和收益比最高，应和 #1 一起列为第一优先。次一级是 `maskRegion` 的 `userSpaceOnUse` 百分比换算（#18，与 #11 的 `SvgLength.unit` 丢弃同源：单位/百分比信息在值传递中被丢掉）。其余补充项都是可维护性（rect→path 三份、clamp/max 双份、warning 归一化复刻、构建递归深度依赖可配置上限、命名与格式）。

存量 26 条（严重 3 / 一般 10 / 轻微 13），是否纳入修复待用户决定；性能与内存优化 4 条均无基线，只作为下一轮采数清单，不构成结论。
