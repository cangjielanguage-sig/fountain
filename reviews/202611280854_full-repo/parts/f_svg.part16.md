# f_svg 模块审查报告（第 16/26 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_svg/src`（本部分 18 个源文件，全部 `.cj`，无 `.md`）
- **基线**：工作区快照（`git diff` 为空，HEAD `f309f0b5`）⇒ 所有问题来源一律「存量」
- **审查重点**：SVG/XML 解析与序列化边界、注入与转义、递归与栈溢出、OOM、死代码、重复逻辑（本轮覆盖渐变采样、几何包围盒、GSUB 上下文整形、gzip、Hershey 字体与字体特性）
- **报告版本**：v1（本部分分报告，供主 Agent 合并到 `docs/review/2026-11-28/f_svg_v2.md`）

## 发现

### [严重][存量] #1 渐变采样器按「像素」累积 warning，渲染路径既不读取也不去重

- **位置**：`f_svg/src/SvgGradient.cj:205`（`public let warnings`）、`:254`、`:256`、`:344`、`:347`、`:466`、`:487`（6 处 `warnings.add`）
- **来源**：存量（`git blame` 均落在 `f0d369c020` 2026-11-07，快照模式无 diff 可比）
- **判据**：review-checklist §5「无界容器 / 全局集合只增不减」+ §3「静默吞异常（诊断丢失）」
- **证据**：静态确定 —— `SvgRasterizer.fillGradient/strokeGradient` 在**逐像素闭包**里调用 `sampler.sample(...)`（`f_svg/src/SvgRasterizer.cj:211-219`、`:269-277`），而 `sample()` 的 4 条路径无条件（无去重、无一次性标记）向实例字段 `this.warnings` 追加字符串：`radialT` 的 `fr`/`FR` 提示与 `r <= 0` 提示（`:343-349`）、`gradientTransform` 解析失败/不可逆（`:254`、`:256`）、`href` 循环与目标缺失（`:466`、`:487`）
- **描述**：
  1. **无界增长**：`warnings` 生命周期 = 一次 fill，但增长量 = 覆盖像素数。以默认 `maxPixels = 64 Mi`（`f_svg/src/SvgBitmap.cj:230`）计，一个 `r="0"` 的径向渐变填充整块画布会生成 6.4e7 条字符串（每条 60–80 B + 槽位），数百 MB 到 GB 级，属于「到 OOM 才知道」的增长面；1000×1000 的常见画布也已是约 1e6 条 / 约 100 MB。
  2. **诊断丢失**：`sampler` 是 `fillGradient`/`strokeGradient` 的局部变量，`sampler.warnings` 在 `SvgRasterizer` 与 `SvgRenderer`（`grep "sampler.warnings"` 在 `f_svg/src/SvgRasterizer.cj` 零命中，`SvgRenderer.cj` 全文无 `catch`）中**从未被读取或合并**，因此渲染期产生的渐变告警（不可逆矩阵、循环 href、r≤0）全部丢弃，而内存照付。
- **建议**：把「解析一次」与「采样每点」拆开——在 `fillGradient` 入口调用一次 `resolveChain` + `resolveStops` + `gradientTransform` 求逆，得到的不可变快照传入逐像素闭包；warning 只在解析阶段写一次，并由 `SvgRasterizer` 暴露 `warnings` 让 `SvgRenderer` 合并进渲染告警。若短期不改结构，至少给 6 处 `warnings.add` 加 `if (this.warnings.size < N)` 上限并让调用方读取。

### [严重][存量] #2 GSUB coverage format 2 按文件声明长度全量展开，可被单个小字体放大成 GB 级内存

- **位置**：`f_svg/src/SvgGsubContext.cj:217-229`（`gsubCoverage` format 2）
- **来源**：存量（同一函数体亦复制于 `f_svg/src/SvgOpenTypeLayout.cj:481-493`，见「重复逻辑」条目）
- **判据**：review-checklist §5「按不可信长度预分配 / 一次性物化」，§4「OOM 面」
- **证据**：静态确定 —— `count = reader.u16(offset + 2)` 与每段的 `start/end = reader.u16(...)` 全部来自字体字节，循环 `while (glyph <= end) result.add(glyph)` 无任何上限、无总量校验；`gsubReadCoverages`（`:233-243`）对每个 coverage 偏移各调用一次，`gsubParseContextSubtable` 的 `inputCount/backtrackCount/lookaheadCount` 均为 u16
- **描述**：单段最多 65536 个字形，单 coverage 最多 65535 段 ⇒ 理论上限约 4.29e9 个 `Int64`（≈34 GB），而驱动这些数字的输入仅需约 393 KB（65535 × 6 B）。字体字节来自 `SvgTrueTypeFont.parse(bytes)`（`@font-face` / data URI，属文档可控输入），因此一个几百 KB 的恶意字体即可在解析期耗尽内存或长时间卡死（外层 `try/catch (SvgException)` 无法拦截 OOM/长时间循环）。同时该展开也发生在 GPOS 侧 `parseGposCoverage` / `parseGposClassDef`。
- **建议**：coverage 内部改用「区间表示」（`Array<(Int64, Int64)>` + 二分查找）代替展开；必须展开时加总量上限（如 `coverage 展开总数 ≤ 4 × CSS_GSUB_MAX_INPUT` 或与 `reader.length` 挂钩的放大比上限），超限 warning + 丢弃子表。查找函数 `arrayContainsSvgGlyph` 改为区间二分。

### [一般][存量] #3 `SvgFontFeatures.fromStyle` 把 parse 结果里的「默认开关」一起复制，静默重置 `font-variant-ligatures`

- **位置**：`f_svg/src/SvgFontVariant.cj:199-205`（合并循环）；根因在 `:116-126`（私有构造预置 6 个默认开关）与 `:160-174`（`parse` 以该构造函数为基底）
- **来源**：存量（`git blame`：`f0d369c020` 2026-11-07）
- **判据**：review-checklist §11「语义与注释/实现不符」、§10 正确性
- **证据**：静态确定 —— `fromStyle` 先用 `fontVariantLigatures()` 写 `result`（`:187-198`），随后 `for ((tag, value) in explicit.switches) result.set(tag, value)`；而 `explicit` 由 `SvgFontFeatures.parse` 构造，其 `switches` 里**始终含默认值** `liga=true, clig=true, dlig=false, hlig=false, calt=false, kern=true`
- **描述**：`font-variant-ligatures="none"` + 任意 `font-feature-settings`（例如只写 `"dlig" 1`）时，默认值 `liga=true / clig=true` 会把前一步的 `none` 覆盖回开启，连字被意外启用。这与 `:176` 注释承诺的「variant-ligatures 先，font-feature-settings 覆盖」相反——覆盖面被扩大成「整张默认表」。现有用例 `SvgFontDetailsM6_test.cj:215-235` 只断言了被显式写入的 `liga`/`kern`，覆盖不到该分支。
- **建议**：`parse` 区分「默认值」与「显式条目」（例如只在 `explicitCount > 0` 的 tag 上合并，或让 `parse` 返回 `ordered` 中的显式 tag 列表再合并），`fromStyle` 只按显式 tag 覆盖；顺带用 `ordered` 而非 `switches` 迭代，恢复 `toString()` 的确定性顺序（HashMap 遍历顺序不稳定，`ordered` 会被打乱）。

### [一般][存量] #4 `font-variant-ligatures` 的 `no-*` 与多关键字值被解析层接受，但合取层无分支，静默不生效

- **位置**：`f_svg/src/SvgFontVariant.cj:187-198`（`match (style.fontVariantLigatures())` 只有 5 个单值 case + `_ => ()`）
- **来源**：存量
- **判据**：review-checklist §14.1「只做了一半的分支 / 开关只在一处判断」、§13「规格与实现漂移」
- **证据**：静态确定 —— `SvgStyleResolver.cj:837-845` 用 `textLower.contains("common-ligatures")` 等条件放行 `no-common-ligatures`、`no-discretionary-ligatures`、`common-ligatures discretionary-ligatures` 等值并原样写入计算样式；`fromStyle` 的 `match` 只有 `"none" / "common-ligatures" / "discretionary-ligatures" / "historical-ligatures" / "contextual"`，其余落到 `case _ => ()`
- **描述**：合法值 `font-variant-ligatures="no-common-ligatures"` 被样式层当作合法值接受（无 warning、不进 `SvgStyleSource` 回退），但整形时 `liga/clig` 保持默认开启，用户看到的是「设置无效且无任何提示」。多关键字组合（`common-ligatures no-discretionary-ligatures`）同样整条失效。
- **建议**：把该属性解析成结构化位集合（`liga/clig/dlig/hlig/calt` 五路，各含 on/off），在 `SvgStyleResolver` 归一化阶段生成规范串（如 `liga=1,clig=0,...`），`fromStyle` 只按该规范串赋值；无法识别的 token 必须 warning。

### [一般][存量] #5 渐变 stop 的 `stop-color` / `stop-opacity` 只读 XML 属性，忽略 CSS 与 `style=`

- **位置**：`f_svg/src/SvgGradient.cj:416-428`（`stop.attr("stop-color")` / `stop.attr("stop-opacity")`）
- **来源**：存量
- **判据**：review-checklist §14.1「接线缺失：配置/能力已实现但没人用」
- **证据**：静态确定 —— `stop-color` / `stop-opacity` 已是模块注册的 CSS 属性并有取值函数（`f_svg/src/SvgComputedStyle.cj:109-110`、`:351-358`），样式层也做了归一化（`f_svg/src/SvgStyleResolver.cj:557-562`、`:394`），但采样器完全不接触 `SvgComputedStyleTree`，只读元素属性
- **描述**：`<stop style="stop-color:red"/>`、`<style>stop{stop-color:#0f0}</style>`、`<stop class="c"/>` 三种写法在渲染时全部退化成 `SvgColor.Black`（`:423`），而 `getBBox`/样式 API 侧却报告已解析的颜色，形成「样式层有值、采样层不用」的分裂。测试只覆盖了属性写法（`SvgGradientSampler_test.cj:22-34` 的 `addStop` 走 `setAttr`）。
- **建议**：`SvgGradientSampler` 增加 `styles!: ?SvgComputedStyleTree` 参数（`root` 已具备），`resolveStops` 优先取 `styles.get(stop)?.stopColor()/stopOpacity()`，属性作为回退；同时把 `offset` 也走 `SvgStop.offset` 语义（当前 `tryParseSvgOffset ?? 0.0` 会静默把非法 offset 当 0）。

### [一般][存量] #6 `rect` 的 miter 尖角几何用未套计算样式的属性值，与 `rectBounds` 的取值口径不一致

- **位置**：`f_svg/src/SvgGeometry.cj:766-781`（`collectMiterPolylines` 的 `case rect`）；对照 `:283-298`（`rectBounds` 走 `svgStyledLength`）
- **来源**：存量
- **判据**：review-checklist §11「契约与实现不符 / 同一量两套算法」、§2「近似重复且一块少了边界判断」
- **证据**：静态确定 —— `rectBounds` 用 `svgStyledLength(style, "width", rect.width)`（样式优先、属性回退），而同文件 miter 分支直接用 `rect.width`/`rect.height`/`rect.x`/`rect.y`
- **描述**：`width/height/x/y` 是模块已注册的 CSS 几何属性（`SvgComputedStyle.cj:124-127`）。当作者用 CSS/内联样式改写 rect 几何时，`SvgGeometry.strokeBounds`（公开 API，`SvgElementApi.cj:155` 用于 `getBBox` 含描边口径）先按样式算盒、再按属性算尖角：尖角位置偏离，既可能漏掉真实尖角（裁剪/剔除裁掉描边端点），也可能凭空外扩。`path` 分支（`:782-857`）同样没有 `style` 可用，属同一根因。
- **建议**：`collectMiterPolylines` / `miterTips` 增加 `style: ?SvgComputedStyle` 参数并复用 `svgStyledLength`；无法获得样式时显式说明「按属性口径」。

### [一般][存量] #7 无 `stop` 的渐变按不透明黑填充

- **位置**：`f_svg/src/SvgGradient.cj:234-236`（`if (stops.size == 0) { return SvgColor.Black }`）
- **来源**：存量
- **判据**：review-checklist §11「错误处理缺失 / 失败路径当成功」
- **证据**：待确认（规范口径）—— SVG 规范规定「渐变未定义任何 stop 时按 `none` 处理（不绘制）」；仓内 `f_svg/doc/spec/add-f-svg-m2/specs/svg-paint-and-clip/spec.md:9-32` 未记载该场景，故不能据仓内文档定性
- **描述**：`<linearGradient id="g"/>` 被 `fill="url(#g)"` 引用时，采样器返回 `SvgColor.Black`，渲染器（`SvgRenderer.cj:538-585` 无 stop 数量检查）会画出一整块不透明黑，而正确行为是「该元素不绘制」。同理 `chain.size == 0`（`:226-229`）返回黑色也是不透明兜底。
- **建议**：无 stop 时返回 `SvgColor(0,0,0,alpha: 0.0)`（与 `r<=0` 分支 `:268-270` 的处理一致），或在 `SvgRenderer` 侧遇到 0 stop 直接跳过该 paint；两条路径择一，不要一边透明一边黑。

### [一般][存量] #8 GSUB/GPOS 解析与连字匹配在两条整形路径上各写一份，且已出现告警漂移

- **位置**：`f_svg/src/SvgGsubContext.cj:197-206`（`gsubTag`）≡ `f_svg/src/SvgOpenTypeLayout.cj:34-43`（`cssLayoutTag`）；`:176-195` ≡ `SvgOpenTypeLayout.cj:45-57`；`:156-174` ≡ `:69-90`；`:209-231` ≡ `:473-495`（`parseGposCoverage`，逐行相同）；`:343-385` ≈ `:614-686`（`parseGsubLigatureSubtable`）；`:581-614`（Type 4 最长匹配）≡ `SvgOpenTypeLayout.cj:541-573`（`findLigature`）
- **来源**：存量
- **判据**：review-checklist §2「只改类型名 / 跨层复制的重复逻辑」+「近似重复往往同时是缺陷」
- **证据**：静态确定 —— 函数体逐行对齐，差异仅在函数名与容器类型；两条路径在生产代码中**同时存活**（`f_svg/src/SvgTrueTypeFont.cj:273-296` 先解析 3 份 `SvgGsubLigatures`（liga/hlig/clig），再解析 1 份 `SvgGsubContextTable`，四次都从同一份 GSUB 字节重新走 ScriptList→FeatureList→LookupList）
- **描述**：同一份 OpenType 表被两套实现解析，已产生可观察漂移：① `componentCount < 2` 时 M6 静默 `continue`（`SvgGsubContext.cj:366-368`）而 M5 会 `warnings.add`（`SvgOpenTypeLayout.cj:655-658`）；② M5 逐字段做截断判断并给出「子表/连字集/连字记录/连字组件截断」四种定位信息（`SvgOpenTypeLayout.cj:620-672`），M6 全部依赖 `reader` 抛异常后统一成一条「GSUB 上下文表截断」（`SvgGsubContext.cj:508-511`），可诊断性下降。此外每次加载字体把 GSUB 全表解析 4 遍（见 CPU 优化方案）。
- **建议**：抽出 `f_svg` 内共享的 `SvgOpenTypeTables`（coverage/tag/LangSys/FeatureList/LookupList/Extension 解析 + 区间化 coverage），M5/M6 只保留各自的应用语义（`findLigature` 返回下标 vs `applyLookupAt` 就地改写）；GSUB 表只解析一次，按 tag 建立 `tag → lookup 索引` 视图供三条 ligature 通道复用。

### [轻微][存量] #9 死字段：`SvgGsubContextSubtable.chained` 只写不读

- **位置**：`f_svg/src/SvgGsubContext.cj:53`（声明）、`:66`（赋值）
- **来源**：存量
- **判据**：review-checklist §1「读了不用 / 兼容残留」；`chained` 是 `private class` 字段，全仓搜 `\.chained` 仅命中定义与赋值（`:60`、`:66` 为构造参数）
- **证据**：静态确定 —— `coversInput`（`:73-100`）与两个调用点都不读该字段，链式与非链式的差异完全由 `gsubParseContextSubtable` 的入参 `chained`（`:249`）决定
- **描述**：字段无语义用途，保留会让人误以为 Type 5/6 可共用同一子表实例
- **建议**：删除字段与构造参数，或改为真正的 `isChained()` 并在 `coversInput` 中用于区分回溯段校验

### [轻微][存量] #10 三处恒不可达的兜底分支

- **位置**：`f_svg/src/SvgGeometry.cj:205-207`（`if (chain.size == 0) return SvgMatrix.identity`）、`:539`、`:853`（`case _ => ()`）
- **来源**：存量
- **判据**：review-checklist §1「恒真恒假分支」
- **证据**：静态确定 —— `ctm` 的 `chain` 至少包含 `element` 本身（`:196-204` 先 `add` 再取 `parent`），`size == 0` 不可能；`pathDataBounds`/`collectMiterPolylines` 都先调用 `data.toAbsolute()`，而 `toAbsolute` 已把 `HorizontalLineTo`/`VerticalLineTo` 全部改写为 `LineTo`（`f_svg/src/SvgPathData.cj:181` 起的 H/V 分支），8 个 `SvgPathCommandKind` 值（`SvgPathData.cj:22-32`）中的 H/V 不再出现
- **描述**：三处分支永不会命中，掩盖了「若将来放宽 `toAbsolute` 契约」的真实缺口
- **建议**：删除或改为 `case _ => throw`（或加注释说明依赖 `toAbsolute` 的归一化契约）

### [轻微][存量] #11 `SvgGzip.cj` 末尾的 `TODO(M3-6)` 已过时

- **位置**：`f_svg/src/SvgGzip.cj:96`（`// TODO(M3-6): SvgParser.parseAuto / parseGzip 入口。`）
- **来源**：存量
- **判据**：review-checklist §3「TODO 占位仍在主路径」/ §13「文档过期」
- **证据**：静态确定 —— `SvgParser.parseAuto` 已在 `f_svg/src/SvgParser.cj:71` 实现、`parseGzip` 在 `:83` 实现，且 `SvgGzip_test.cj:28-35` 已覆盖两者
- **描述**：注释会让维护者以为入口缺失；同时该文件 doc 注释（`:21-27`）承诺「同输入输出逐字节一致」，实际依赖 zlib 默认 mtime=0，属隐含契约
- **建议**：删除该 TODO，并把「mtime=0」的依赖写进 `compress` 的注释

### [轻微][存量] #12 枚举 `toString()` 返回 CamelCase，与同文件 `attrName()` 的 SVG 关键字不一致

- **位置**：`f_svg/src/SvgGradient.cj:36-41`、`:74-80`（`toString` → `"UserSpaceOnUse"` / `"Pad"`）；对照 `:43-48`、`:82-88`（`attrName` → `"userSpaceOnUse"` / `"pad"`）
- **来源**：存量（`SvgGradient_test.cj:91-92` 已把 CamelCase 固化为断言）
- **判据**：review-checklist §10 可读性 / §13「命名与语义」
- **证据**：静态确定 —— 两个公开枚举同时提供 `toString`（调试名）与 `attrName`（序列化值），取值不同；调用方若用 `toString()` 拼属性会写出非法值
- **描述**：`SvgSpreadMethod.Pad.toString() == "Pad"` 不是合法 SVG 属性值；`SvgCoordinateUnits` 同理。对外 API 上「ToString 不是可回写值」无文档说明
- **建议**：保持 `attrName` 为唯一序列化入口，并在两个 `toString` 上加注释「调试用，写属性请用 attrName」；或在收敛破坏性变更窗口把 `toString` 改成关键字并以 `FromName` 可逆

## 优化可行性方案

### [CPU] 渐变采样每次像素重做「href 链 + stops 解析 + 全文档 id 搜索」

- **现状**：`SvgGradientSampler.sample`（`f_svg/src/SvgGradient.cj:220-290`）在每一次采样里：`resolveChain` 新建 `ArrayList` + `HashMap` 并逐步 `findGradientById`（`:456-494`、`:506-528`，后者是对整棵文档的递归搜索）；`resolveStops` 重新 `childrenOf("stop")`、逐条 `tryParseSvgOffset/stop-color/stop-opacity` 并做插入排序（`:400-454`）；`linearRGB` 分支再建一份 `linearStops`（`:282-287`）。调用次数 = 覆盖像素数（`SvgRasterizer.cj:215-218`）
- **方案**：把 `fillGradient`/`strokeGradient` 改成「每 fill 解析一次」：入口处一次性算出链、stops（已排序、可选预转线性光）、`gradientTransform` 逆矩阵与 `t` 所需的 x1/y1/x2/y2（或 cx/cy/r/fx/fy），封装成不可变 `SvgResolvedGradient`，逐像素只做一次点积/开方；`SvgRenderer` 处建 `id → 元素` 映射，替换 `findGradientById` 的全树递归
- **预期**：每像素从「O(链长 × 文档元素数 + stops log stops) 次读 + 3~5 次分配」降为「常数次算术 + 0 分配」。上限估算：若采样占端到端 30%（待测），该项可吃掉其中大部分
- **代价**：新增一个快照类型；`href` 目标在采样期间被修改的行为从「实时读取」变为「fill 开始时快照」（对渲染无实义）
- **验证**：`cjprof record` 跑含 3 个渐变填充、2000×2000 画布、`samplesPerPixel=1/4` 两组；对照 `sample` 自耗时占比与总渲染时间中位数（≥5 轮）
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 字体的 GSUB 表被重复解析 4 次

- **现状**：`SvgTrueTypeFont` 构造时对同一份 GSUB 字节调用 3 次 `SvgGsubLigatures.parse`（liga/hlig/clig，`f_svg/src/SvgTrueTypeFont.cj:272-292`）+ 1 次 `SvgGsubContextTable.parse`（`:294-296`）；每次都要走 ScriptList→LangSys→FeatureList→LookupList，其中 `gsubParseLookup` 会用 `GSUB_CONTEXT_FEATURES.contains` 过滤并丢弃非上下文 lookup 的子表
- **方案**：解析一次 `ScriptList/FeatureList/LookupList` 到共享结构，按 tag 建视图（`tag → Array<SvgGsubLookup>`），3 条 ligature 通道与上下文通道各自只消费自己需要的 lookup
- **预期**：字体加载期的 OpenType 遍历次数由 4 次降为 1 次，并天然消除上一条重复逻辑问题
- **代价**：需要一个中等规模的结构重构（`SvgGsubLigatures` 改为视图）
- **验证**：`cjpm bench -O2` 对「解析 100 个嵌入字体」的冷启动场景计时；对照 `parse` 阶段耗时
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] `pathDataBounds` 每次调用都物化一份绝对化路径

- **现状**：`pathDataBounds`（`f_svg/src/SvgGeometry.cj:418-421`）第一行 `let absolute = data.toAbsolute()`，而 `toAbsolute`（`f_svg/src/SvgPathData.cj:181`）为每条命令新建 `SvgPathCommand` + `values` 数组；该函数在 `bounds`、`strokeBounds`、`SvgHersheyFont.glyphBounds`、装饰线包围盒等处被反复调用（全仓 25 处引用），单条长路径（数千命令）会额外产生「1 份命令表 + N 个 values 数组」的瞬时峰值
- **方案**：把「相对→绝对」状态机内联进包围盒遍历（现成变量 `currentX/currentY/startX/startY` 已在维护），或对 `SvgPathData` 缓存绝对化结果（带 `commands` 版本号）
- **预期**：路径包围盒计算的峰值分配从 `O(2n)` 降到 `O(1)`（不含返回的 `?SvgBounds`）；对长路径（n ≥ 1e3）意义明显
- **代价**：`pathDataBounds` 复杂度上升（要处理 H/V/S/T 的相对形式）；缓存需失效钩子
- **验证**：同一文档 1000 路径 × 每帧一次 `getBBox`，对比 `getAllocatedHeapSize()` 与 RSS；跑 10 分钟稳态看是否回落
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] `SvgHersheyFont` 每次 `glyphPath` 重新切分/解析/浮点转换字形串

- **现状**：`glyphPath`（`f_svg/src/SvgHersheyFont.cj:35-74`）对每个字形每次调用都 `splitHersheyStrokes`（`ArrayList<String>` + 子串）、`parseHersheyPoints`（`ArrayList<SvgPoint>`）、`tryParseSvgFloat`，随后每个点再各建一个 `SvgPathCommand` 与 `values` 数组；文本布局按字形逐字调用（`f_svg/src/SvgTextRenderer.cj:931`、`:1992`），`glyphBounds` 又会再算一遍
- **方案**：模块初始化时把 `HERSHEY_GLYPHS` 预解析成 `HashMap<Int64, Array<Array<SvgPoint>>>`（单位坐标），`glyphPath` 只做缩放 + 组装；`glyphBounds` 直接由预解析轮廓求极值，不再走 `pathDataBounds`
- **预期**：单字形布局分配从「O(笔画数) 个 String + 点数个 SvgPoint + 点数个 SvgPathCommand」降为「点数个 SvgPathCommand」，并省掉全部字符串/浮点解析
- **代价**：启动期常量表内存上升（94 字形，量级 KB）；`glyphPath` 返回值仍要新建（公开 API 返回 `SvgPathData`）
- **验证**：10 万字 ASCII 文本 layout 计时 + `getAllocatedHeapSize()` 对照（`-O2`，5 轮中位数）
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] GSUB coverage 用区间表示替代展开

- **现状**：见「[严重] GSUB coverage format 2」条目，单 coverage 最坏 65536 个 `Int64`（512 KB），可被 393 KB 输入放大到数十 GB
- **方案**：`gsubCoverage` 返回 `Array<(Int64, Int64)>` 区间集合（或压缩的 `SvgGlyphSet` 结构），`arrayContainsSvgGlyph` 改为二分；`gsubParseLigatureSubtable`/`applyLookupAt` 只做包含判定，不需要展开
- **预期**：最坏内存从 O(展开总数) 降为 O(区间数)（≤ 65535 个二元组，约 1 MB 上限），同时消除 OOM/卡死面
- **代价**：包含判定从 O(1) 哈希变 O(log n)（n ≤ 区间数，实际个位数）；实现需保证原有语义（重复 glyph、无序 range）
- **验证**：构造「65535 段全区间」的合成 GSUB，断言解析 CPU < 100 ms 且常驻内存不随段数线性膨胀
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

> 无性能测试数据支撑，不进 `todo.md` / `tasks.md`，只作为下一轮补数据的清单。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 渐变采样是渐变填充渲染的主要自耗时来源（每像素重解析 href 链与 stops） | `f_svg/src/SvgGradient.cj:220-290` | `sample` 自耗时占比、每像素平均分配字节 | `cjprof record` 渲染含 3 个渐变、2000×2000、`samplesPerPixel=1`；输入固定 10 轮取中位数 |
| 2 | `findGradientById` 的全树递归在元素多（>1e4）的文档上成本显著 | `f_svg/src/SvgGradient.cj:506-528` | 单次调用平均遍历节点数、占 `sample` 自耗时的比例 | 埋点统计 `findGradientById` 调用次数与访问节点数；对比建 id 映射后的耗时 |
| 3 | `pathDataBounds` 的 `toAbsolute` 副本在长路径文档上造成峰值内存与 GC 抖动 | `f_svg/src/SvgGeometry.cj:418-421` | 峰值 `getAllocatedHeapSize()`、GC 次数、RSS 曲线 | 100 条路径 × 5000 命令，连续 100 帧 `getBBox`；对照组缓存绝对化结果 |
| 4 | Hershey 字体 `glyphPath` 的字符串解析在长文本布局中占比较高 | `f_svg/src/SvgHersheyFont.cj:35-74` | 自耗时占比、每字形分配字节 | `cjpm bench -O2`：1 万字 layout，对比预解析轮廓实现 |
| 5 | GSUB `applyLookupPass` 的 `ArrayList.remove(at:)` 让长 run（>1e4 字形）的连字整形退化为 O(n²) | `f_svg/src/SvgGsubContext.cj:134-144`、`:540-546` | n 从 1e3 到 1e5 的耗时曲线 | 合成 1 万/10 万字形 run + 每 2 字一个连字，计时并拟合复杂度 |
| 6 | 每次加载字体把 GSUB 解析 4 次在「一次渲染含数百个嵌入字体」的场景里占启动时间 | `f_svg/src/SvgTrueTypeFont.cj:272-296` | 字体解析阶段耗时占比 | 100 个内嵌 @font-face 的文档，对比「解析一次 + 视图」实现 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_svg/src/SvgFontStretchMatchM6_test.cj` | .cj | ✅ | 测试；`layout`/`layoutFor` 两份近重复构造函数属 §2 误报边界（测试准备代码） |
| 2 | `f_svg/src/SvgFontVariant.cj` | .cj | ✅ | 见发现 #3、#4 |
| 3 | `f_svg/src/SvgFont_test.cj` | .cj | ✅ | 注册表/覆盖/缩放断言，与实现一致 |
| 4 | `f_svg/src/SvgForeignObject.cj` | .cj | ✅ | 仅一个注入式接口，契约注释与 `SvgRenderTree` 占位行为一致 |
| 5 | `f_svg/src/SvgForeignObjectM6_test.cj` | .cj | ✅ | 覆盖位图注入、None、缺尺寸、maxPixels、不遍历 XHTML |
| 6 | `f_svg/src/SvgGeometry.cj` | .cj | ✅ | 见发现 #6、#10；`bounds/strokeBounds/ctm/screenCTM` 算法逐个核对 |
| 7 | `f_svg/src/SvgGeometryApiM4_test.cj` | .cj | ✅ | 路径测长/CTM/screenCTM 一致性 |
| 8 | `f_svg/src/SvgGeometry_test.cj` | .cj | ✅ | 形状边界、非法输入、文本布局边界；含测试字体辅助类 |
| 9 | `f_svg/src/SvgGradient.cj` | .cj | ✅ | 见发现 #1、#5、#7、#12 |
| 10 | `f_svg/src/SvgGradientColorSpaceM6_test.cj` | .cj | ✅ | linearRGB 自身/继承/color-profile 告警 |
| 11 | `f_svg/src/SvgGradientSampler_test.cj` | .cj | ✅ | 端点/spread/stops/href/深度上限；`addStop` 只走属性写入（对应发现 #5） |
| 12 | `f_svg/src/SvgGradient_test.cj` | .cj | ✅ | 属性缓存、非法枚举、stop 归一化；`:91-92` 固化 CamelCase toString（发现 #12） |
| 13 | `f_svg/src/SvgGroupCompositorM5_test.cj` | .cj | ✅ | 兼容重载与混合模式，无问题 |
| 14 | `f_svg/src/SvgGsubContext.cj` | .cj | ✅ | 见发现 #2、#8、#9；Type 5/6 format 3 偏移布局逐个核对 |
| 15 | `f_svg/src/SvgGsubContextM6_test.cj` | .cj | ✅ | 上下文/回溯/前瞻/多层/深度/特性门控；表构造器 `m6Gsub*` 仅测试用 |
| 16 | `f_svg/src/SvgGzip.cj` | .cj | ✅ | 见发现 #11；解压上限、CRC/ISIZE 校验逐行核对 |
| 17 | `f_svg/src/SvgGzip_test.cj` | .cj | ✅ | parseAuto/parseGzip/截断/CRC/上限/确定性 |
| 18 | `f_svg/src/SvgHersheyFont.cj` | .cj | ✅ | 见堆内存方案；ASCII 32–126 表与回退逻辑核对 |

合计：`.cj` 18 个 / `.md` 0 个 / 共 18 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 4 | 命中：fromStyle 默认值覆盖（#3）、ligatures 复合值失效（#4）、stop 样式未接线（#5）、miter 口径不一致（#6）。安全性另核：渐变/字体/几何均不拼 SQL/命令，无凭据硬编码；`SvgGzip` 解压有 `maxBytes` 与 CRC 双校验 |
| §1 死代码 | 2 | 已逐个 `private`/`internal` 符号全仓搜引用（`svgSplitFeatureEntries`、`svgParseFeatureEntry`、`rectBounds…textElementBounds`、`cubicAt`、`tipAt`、`elementMatrix`×2、`ancestorTransform`、`GradientStopData`、`applyGradientSpread`、`sampleStops`、`svgChannel*`、`gsubTag`、`gsubCoverage`、`gsubReadCoverages`、`gsubParse*`、`splitHersheyStrokes`、`parseHersheyPoint(s)`、`buildHersheyGlyphs`、`verifyTrailer`、`readU32LE` 全部 ≥2 处命中，均有调用者）；命中死字段 `chained`（#9）与 3 处恒不可达分支（#10）；`public` 一律按「对外可达不判」处理，仓内零引用的 `SvgGeometry.absoluteBounds`、`writeGzip`、`SvgFontFeatures.size/parse(text)` 仅记为信息 |
| §2 重复逻辑 | 1 | 已把本部分 7 个生产文件（`SvgFontVariant`/`SvgForeignObject`/`SvgGeometry`/`SvgGradient`/`SvgGsubContext`/`SvgGzip`/`SvgHersheyFont`，共 105 个 `func`）的函数体压成「输入→输出→副作用」摘要两两比对，并与 `SvgOpenTypeLayout.cj` 同族函数逐行对齐；命中 M5/M6 OpenType 解析重复（#7，6 组逐行等价）。本部分内另有两处「形似不同但语义不同」不判：`cubicBounds` 的 x/y 根两轮循环（合并等价，仅省两次遍历，归入 CPU 线索不单列）、`ctm` 与 `ancestorTransform` 的祖先链收集（语义不同：前者含嵌套 `svg` 视口变换）。测试夹具重复（`layout`/`layoutFor`、`solid`/`m5SolidBitmap`）按误报边界不计 |
| §3 空实现 | 1 | 命中过时 `TODO(M3-6)`（#11）。其余 `case None => ()` 均为可选属性缺失的正常分支；`SvgForeignObjectRenderer` 的 `None` 返回有文档化的「透明占位」语义，非空实现 |
| §4 栈溢出 | 0 | 唯一的输入驱动递归是 `findGradientById`（深度 = 文档嵌套，解析期受 `SvgSecurityOptions.maxDepth=512` 限制，`f_svg/src/SvgOptions.cj:68`），`gsubParseLookup` 的 Type 7 展开与 `applyLookupAt` 的上下文嵌套分别有 `CSS_GSUB_MAX_DEPTH=8` 显式计数。DOM 手工构建的树不受 `maxDepth` 约束，但无环检测缺省不影响本部分结论，属「DOM API 侧风险」，未作为发现 |
| §5 OOM | 2 | 命中 sampler warning 按像素增长（#1）与 GSUB coverage 放大（#2）。`SvgGzip.decompress` 有 `maxBytes` 流式上限（`:38-53`）；`SvgFontFeatures.parse` 有 64 条上限（`:166-169`）；`pointsBounds`/`pathDataBounds` 规模由输入长度线性决定，无放大 |
| §6.1 热点瓶颈 | 0 | 未提供任何 profile/bench 数据，`SvgGradientSampler.sample`、`findGradientById`、`glyphPath` 均只有「调用次数多」线索，已全部降级到「待验证假设」#1–#6 |
| §6.2 大粒度锁 | 0 | 本部分无锁、无 `synchronized`、无共享缓冲；`SvgGradientSampler` 每次 fill 新建，属线程封闭 |
| §6.3 并发串行 | 0 | 无 `spawn`/`Future`/线程池；渲染循环是单线程逐命令 |
| §6.4 低效算法 | 3 | 命中：每像素重解析 href 链/stops（已列 CPU 方案）、`applyLookupPass` + `ArrayList.remove(at:)` 的 O(n²) 风险（待验证假设 #5）、coverage 全量展开（兼作 OOM 与内存方案）。均无实测数据，未计入缺陷 |
| §7 降堆内存方案 | 3 | `pathDataBounds` 绝对化副本、Hershey 字形每次解析、coverage 区间化；均标 `无基线（待验证）` |
| §8 降 CPU 方案 | 2 | 渐变采样一次解析、GSUB 单次解析；均标 `无基线（待验证）` |
| §9 local mode 可行性 | 0 | 候选只有 `sample()` 内每像素的小对象（`SvgPoint`、`SvgColor`、2 元组），生命周期本就止于函数返回，local region 收益无法用峰值内存证明；且 `SvgColor`/`SvgBounds` 为值类型，无 `exclave` 需求。结论：本部分无可证明收益的改造点 |
| §11 现有代码的 BUG（存量） | 12 | 本部分 18 个文件、105 个生产 `func` 的边界、空值、错误路径逐个核对；12 条发现全部为存量（快照模式，`git blame` 落在 `f0d369c020` 等历史提交） |
| §12 并发安全与锁粒度 | 0 | 已确认无全局可变状态：`HERSHEY_GLYPHS`（`SvgHersheyFont.cj:21`）只在模块初始化写一次、之后只读；`SvgGradientSampler`、`SvgFontFeatures`、`SvgGsubApplyState` 都是调用方局部对象；`SvgGradient` 的 `SvgValueCache` 挂在元素上，与模块「DOM 非线程安全」的既有前提一致。无检查-然后-写入、无惰性初始化竞态 |
| §14 功能完备性与 README 覆盖 | 0 | README 不在本部分文件清单，仅做符号交叉核对，结果见「范围外提示」。`SvgGsub*` 属 `internal`，不必进 README |
| 文件覆盖（§13 等） | 18/18 | 本部分清单全为 `.cj`，无 `.md`；`.md` 一致性（README/`doc/**`）由本模块其他部分覆盖 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 2 |
| 一般 | 6 |
| 轻微 | 4 |
| 优化方案（堆内存 / CPU） | 3 / 2 |

- 存量 12 条，全部为存量；是否纳入修复待用户决定（本部分不替用户拍板）。
- 「待验证假设」6 条不计入统计，不进 `todo.md` / `tasks.md`。

## 总评

本部分代码整体结构清晰：几何包围盒走解析极值而非采样（`cubicDerivativeRoots` / `arcBounds` 的中心参数化都对），GSUB Type 5/6 format 3 的偏移布局逐字段正确，gzip 解压的上限与 CRC/ISIZE 双校验、Hershey 字体全覆盖断言、各 M4–M6 测试用例的分层都很扎实；`SvgBounds` 用负尺寸哨兵表示空、零尺寸盒合法的约定也贯彻一致。

主要风险集中在两处「生命周期与入口没对齐」：

1. **渐变采样**把「解析」放进了逐像素路径。同一个根因同时造成严重级的内存无界增长（warning 按像素累积）、诊断静默丢弃（`sampler.warnings` 无人读）以及明显的重复计算。这是本部分唯一建议优先排期的阻塞项——它不是性能优化，而是「一次 fill 的内存随画布面积线性增长」的缺陷。
2. **GSUB coverage 的展开式表示**把字体字节里的长度直接变成堆上的元素个数，放大比可达 10⁵ 量级；`@font-face` 字体属文档可控输入，因此这是一个可被外部触发的 OOM/卡死面，建议与区间化改造一起做。

其余一般级问题（`font-feature-settings` 覆盖默认值、`no-common-ligatures` 无效、stop 的 CSS 颜色未接线、rect miter 未套样式、无 stop 渐变画黑、M5/M6 解析重复且告警漂移）都属于「静默给出错误结果」的类型，不崩溃但会让人误判库的能力，适合排期修复。轻微项（死字段、不可达分支、过时 TODO、枚举 toString 与 attrName 分叉）可随手清理。

另有一处设计取舍需记录，未作为缺陷：`resolveChain` 对 href 循环「warn + 停止继承」，对深度 > 64 却直接抛 `Limit`（`SvgGradient.cj:473-475`），而 `SvgRenderer` 全文无 `catch`，即一个 65 层 href 链会让整幅图渲染失败。测试 `SvgGradientSampler_test.cj:299-307` 已把该行为固化为契约，故按「既定契约」记录；若后续希望与「循环引用降级」保持一致，需要同时改测试与 `doc/spec/add-f-svg-m2/specs/svg-paint-and-clip/spec.md:64` 的口径。

## 范围外提示

- `f_svg/README.md:600` 的 `SvgGeometry` API 摘要只列 `bounds`/`screenCTM`/`strokeBounds`，漏了公开的 `ctm` 与 `absoluteBounds`；`SvgFontFeatures` 摘要（`:597`）只列 `MAX_ENTRIES`/`enabled`，漏了 `parse`/`size`/`toString`。README 与 `doc/**` 不在本部分清单，交给负责 README 的部分处理。
- `f_svg/src/SvgRasterizer.cj:206-219`、`:264-277` 是发现 #1 的调用方（同样构造 sampler 但不读取 `sampler.warnings`），文件不在本部分清单，仅作为持有路径证据引用。
- `f_svg/src/SvgOpenTypeLayout.cj`、`f_svg/src/SvgTrueTypeFont.cj`、`f_svg/src/SvgStyleResolver.cj` 为发现 #2、#4、#7 的对照/调用方，属其他部分的阅读范围。
