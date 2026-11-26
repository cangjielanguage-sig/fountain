# add-f-svg-m4 修复后复验报告（第二轮）

复验时间：2026-11-06
复验对象：`f_svg/doc/spec/add-f-svg-m4/verification.md` 第 7 节、`fix-plan.md`、`openspec/changes/add-f-svg-m4/specs/*`、`openspec/specs/svg-*`、`f_svg/src` 与全部 `*_test.cj`。
复验方式：静态对照 + 源码审阅 + 执行 `cjpm test` / `cjpm build`；未修改源码、未归档、未执行任何 git 写操作。
复验环境：Cangjie SDK 1.3.0-alpha.08，Linux x86_64；分支 `feature/f_svg`，HEAD `cd287be0`，工作区干净。

## 0. 结论摘要

- `cjpm test`：`TOTAL: 691 / PASSED: 691 / FAILED: 0`。
- `cjpm build`：成功；22 条 warning 全部来自 `f_xml`，`f_svg` 自身 0 warning。
- M1–M3 快照：13 个场景全部通过容差 0 的 `compareSceneExact`；快照文件自 M3 阶段提交 `a39db449` 后未再改动（`git diff a39db449..HEAD` 对 13 个快照为空）。
- C1–C4：已清除。C5：**仍存在**（上限已加，但上限本身仍允许实际可用的 DoS）。
- W1、W2、W9 存在部分未落地；W3–W8、W10–W12 已落地（W7 另有新缺陷，见第 4 节）。
- **CRITICAL=2**：C5 残余 1 项；W7 修复引入的 marker 裁剪误判 1 项。

## 1. C1–C5 逐条结论

| 编号 | 状态 | 结论 |
|---|---|---|
| C1 | 已清除 | 5 个 M3 场景已纳入容差 0 的逐字节基线，并有人为篡改检测用例 |
| C2 | 已清除 | `screenCTM` 顺序已改为 `scale(dpr) × viewport.matrix × ctm(element)`，与渲染树一致 |
| C3 | 已清除 | endPts 单调性、轮廓端点、表 tag ASCII、表级边界均已校验，恶意输入抛 `Syntax` |
| C4 | 已清除 | 两处 delta spec、设计文档、README 中英统一为 `NoEffect`，实现与 spec 一致 |
| C5 | **仍存在** | 已加 `min(4096, max(区域宽, 区域高))` 上限，但 512×512 区域允许半径 512，运算量约 1.1×10¹² 次采样，仍可造成小时级 DoS |

### C1. M3 逐字节基线

证据：

- `f_svg/src/SvgScene_test.cj:124-154` 新增 `sceneExactMismatch` / `compareSceneExact`，比较每个字节，无容差。
- `f_svg/src/SvgScene_test.cj:156-230` 的 `SvgSceneByteBaseline_test` 覆盖 M1/M2 的 `basic`、`gradient`、`stroke`、`clip`、`text`、`animation-0/05/1`，以及 `m3-filter`、`m3-pattern`、`m3-image`、`m3-textpath`、`m3-marker`，共 13 个快照。
- `exactMismatchDetected` 修改一个字节后必须报告差异，证明比较器不是恒真。
- 快照来源：`m3-*.rgba` 只在 M3 阶段提交 `a39db449`（2026-11-05 19:38）中出现过；`git diff a39db449..HEAD` 对 13 个 M1–M3 快照为空，说明没有被 M4 修复重新生成。
- 实跑：`m3FilterExact`、`m3PatternExact`、`m3ImageExact`、`m3TextPathExact`、`m3MarkerExact`、`exactMismatchDetected` 均 `[ PASSED ]`。

结论：C1 的验收缺口已闭合。C1 的“覆盖时跳过离屏层”优化另有文本装饰线裁剪副作用，见 4.3，不影响 C1 本身。

### C2. `screenCTM` 矩阵顺序

证据：

- `f_svg/src/SvgGeometry.cj:168-172` 已改为
  `SvgMatrix.scale(dpr,dpr).multiply(viewport.matrix).multiply(ctm(element))`。
- 渲染树根矩阵见 `f_svg/src/SvgRenderTree.cj:215-217`：
  `scale(dpr) × viewport.transform(root) × elementTransformMatrix(root)`，随后逐级右乘；两者顺序一致。
- `f_svg/src/SvgGeometryApiM4_test.cj:150-205` 的 `screenCtmWithTransform` 使用 `viewBox="0 0 50 50"`、`dpr=2`、`g transform="translate(10,10)"`，断言原点映射到 `(40,40)`，并逐条比较渲染树命令矩阵；`screenCtm` 另测无 transform 与无 viewBox。
- 设计文档 `f_svg/doc/f_svg-M4设计.md:253-256` 已同步该顺序。

结论：C2 已清除，且新增用例直接覆盖原先被 identity `ctm` 掩盖的顺序问题。

### C3. TTF 恶意输入

证据：

- `f_svg/src/SvgTrueTypeTables.cj:67-125` 新增 `SvgTtfTableReader`，所有 `u8/u16/i16/i8/u32/slice` 都以 `table.offset + table.length` 为界，越界抛 `SvgException(kind: Syntax)`。
- `f_svg/src/SvgTrueTypeTables.cj:135-155` 的 `readTtfTag` 逐字节只接受 `0x20..0x7E`，非法 tag 抛 `Syntax`；目录解析在 `:197-210` 校验表长上限与 `offset + length <= bytes.size`。
- `f_svg/src/SvgTrueTypeFont.cj:141-176` 增加 `head.length >= 54`、`hhea.length >= 36`、`maxp.length >= 6`、`hmtx`、`loca` 最小长度校验。
- `f_svg/src/SvgTrueTypeFont.cj:340-355` 校验 `endPtsOfContours` 严格递增，非单调抛 `Syntax`；`f_svg/src/SvgTrueTypeFont.cj:633-646` 的 `appendTtfContour` 再次校验 `endPoint < xs.size/ys.size/flags.size`。
- `f_svg/src/SvgTrueTypeFont.cj:490-604` 的 `parseCmap` 校验 cmap 记录、子表偏移、声明长度、段表/分组长度。
- 用例：`SvgTrueTypeM4_test.cj:368-386`（`endPts=[1000,1]` → `Syntax`）、`SvgTrueTypeTables_test.cj:85-95`（非 ASCII tag）、`:98-107`（head/hhea/maxp 声明长度为 0）、`:108-120`（cmap 子表长度越界）、`:122-130`（文件在 loca 中段被截断）。
- 点数 > 10000 仍抛 `Limit`（`SvgTrueTypeFont.cj:346-351`），与 `svg-security` 主/增量规格的“点数上限 → Limit”一致；仅 `fix-plan.md` 写成“否则 Syntax”，属计划措辞不精确，不是实现缺陷。

结论：C3 已清除。

### C4. `SvgVectorEffect` 公开 API

证据：

- `openspec/changes/add-f-svg-m4/specs/svg-value-types/spec.md:50` 已改为
  `NoEffect` / `NonScalingStroke`（类 + 静态属性，说明避免与 `Option.None` 同名）；两处 delta 副本 `diff` 为空。
- 实现 `f_svg/src/SvgVectorEffect.cj:26-72` 为 class + 静态属性，字符串形式 `none` / `non-scaling-stroke` 正确。
- `f_svg/doc/f_svg-M4设计.md:93`、`f_svg/README.md:301`、`f_svg/README_en.md:296` 均改为 `NoEffect`。
- 全仓 grep：除历史 `verification.md` 的旧结论外，没有 `SvgVectorEffect.None` 使用。

结论：C4 已清除。

### C5. `feMorphology.radius` 上限

已落地的部分：

- `f_svg/src/SvgFilterPrimitives2.cj:926-937` 计算
  `pixelLimit = min(4096, max(input.width, input.height))`，对 `scaledRadiusX/Y` 做有限性与上限检查，超限抛 `Limit`，检查位于 `:938` 的 `round` 与 `:953` 的双层循环之前。
- `openspec/changes/add-f-svg-m4/specs/svg-security/spec.md:11` 已登记该上限，并新增“形态学半径超限”场景。
- `f_svg/src/SvgLimitsM4_test.cj:65-75` 用 100×100 区域、`radius=1000000000` 断言 `Limit`；正常半径用例仍通过。

为什么仍判定“仍存在”：

- 上限按“区域边长”放大，没有固定的小核上限或运算预算。512×512 区域允许 `radius=512`，每像素每通道遍历 `(2×512+1)² = 1,050,625` 个采样：
  `262,144 像素 × 4 通道 × 1,050,625 ≈ 1.1×10¹²` 次采样。
- 按本仓 M4 基准中“512×512、3×3 卷积约 151 ms / 9.4M 采样”的量级（约 6×10⁷ 采样/秒）估算，上述形态学单次约需 5 小时；100×100、`radius=100` 也已约 1.6×10⁹ 次、数十秒。
- 因此 `radius=1000000000` 的直接反例被挡住了，但攻击者只需把半径设为区域边长（如 512）即可继续造成实际 DoS。这是“有界”但未达到安全界。

建议：优先改为可分离的 1D 滑动窗口极值（O(1)/像素），或把像素半径硬限制到固定小值（如 64）并增加 `(2rx+1)(2ry+1) ≤ K` 的运算预算；同时更新 `svg-security` 的上限表。

## 2. W1–W12 落地情况

| 编号 | 状态 | 证据与说明 |
|---|---|---|
| W1 | **部分未落地** | 5.3、6.4、8.2、10.3、12.3、16.3、17.5 已补证据或修正表述；但 `tasks.md:145` 的 18.6 仍是 `[x]`，同段小字却写“该项保留未勾选”，`verification.md` 也称“保持未勾选”，三者矛盾 |
| W2 | **部分未落地** | 9 条断言均已新增，但“loca 中段截断”在目录解析阶段就因文件越界失败，未触达表级读取器；“字体不读文件”只断言降级 warning，无法证明没有 `File.readFrom`；“`<image>`+feImage 共享预算”是直接调用 `load`，不是单次渲染集成用例 |
| W3 | 已落地 | 与 C3 合并；`SvgTtfTableReader` 表级边界完整 |
| W4 | 已落地 | `SvgTextRenderer.cj:637-690` 从计算样式读取祖先 `text-decoration`；`:721-790` 的 tspan 基线/对齐/位移/装饰走 `SvgComputedStyleTree`；新增 `<style>` 与内联样式用例 |
| W5 | 已落地（语义有争议） | `SvgTextRenderer.cj:518-570` 按字形切分 `SvgDecorationRun`，`SvgRenderer.cj:288-314` 对渐变按 run.bounds 绘制；但“每个字形重新从渐变起点开始”与“按字形起点取样”并不等价，见 4.7 |
| W6 | 已落地 | `SvgTextPathLayout.cj:94-104` stretch 同时缩放 advance 与字形宽度；`:127-135` exact 计入 `letter-spacing`；`SvgTextPathExtensionM4_test.cj:133-181` 覆盖字形宽度、letter-spacing 与缺省等同 auto |
| W7 | 已落地（引入新缺陷） | `SvgRenderTree.cj:493-547`、`:583-645`、`:807-850` 增加设备空间四边形；`SvgRenderer.cj:571-578`、`:690-727` 应用四边形覆盖率；marker 不再 `inflate(1.0)`。但 `markerContentFits` 坐标系错误，见 4.1；逐指令全画布蒙版带来性能/内存问题，见 4.2 |
| W8 | 已落地 | `SvgDocument.cj:137-160` 返回所有 `a`，无 href 时 `href=None`；delta spec 已同步；`SvgDocumentApiM4_test.cj:297-310` 覆盖 |
| W9 | **部分未落地** | `SvgSwitch.cj:70-105` 将空/纯空白条件视为满足，`emptyConditions` 覆盖 `requiredFeatures` 与 `systemLanguage`；proposal 已说明 switch 兼容性差异；但 `README.md:269-270` 仍写“唯一条件性差异是 marker”，未补 switch |
| W10 | 已落地 | `SvgFilterRenderer.cj:111-115` 零尺寸追加 warning 并返回透明；`SvgFilterPrimitives2.cj:998-1015` order 必须为正整数；`SvgFilterPrimitives2M4_test.cj:268-285`、`:287-305` 覆盖非整数 order 与 wrap；`SvgFilterNoiseM4_test.cj:163-224` 覆盖 slice、base64 上限与共享预算 |
| W11 | 已落地 | `SvgVectorEffectM4_test.cj:136-153` 覆盖 `scale(0)` 下按 none 回退、warning 与无墨迹 |
| W12 | 已落地 | `SvgDocumentApiM4_test.cj:47-70` 覆盖三个字段修改后写回再解析；`SvgView.cj:61-68` 注释说明默认值会显式写出属性 |

补充：`verification.md:11,27,30` 仍记载“143 个 Scenario / svg-security 10 个”，C5 新增“形态学半径超限”后实际为 **144 / 11**；`verification.md:366` 的“WARNING=0（W1–W12 全部落地）”与本节结论不符。这是文档准确性问题，不改变代码结论。

## 3. 测试与构建实跑

- `cjpm test`：691 条全绿，含 13 个 M1–M3 逐字节用例；总耗时约 10.95 s。
- `cjpm build`：成功；最后一次完整输出为 22 条 warning，全部指向 `f_xml/src`（unused variable/function 等），`f_svg/src` 无 warning。
- M4 基准 `SvgBenchmarkM4_test.m4Benchmarks`：整例 545.8 ms，与 `doc/perf-baseline.md` 的 M4 参考值（卷积 ~151 ms + 湍流 ~96 ms + TTF ~288 ms + 路径 <1 ms）量级一致，未见明显回归；该基准按文档声明“参考、非门禁”。

## 4. 新发现

### 4.1 CRITICAL：W7 的 `markerContentFits` 用错坐标系，可能完全跳过 marker 裁剪

证据：

- `f_svg/src/SvgRenderTree.cj:1012-1070`：`markerContentFits(marker, width, height)` 以 `SvgMatrix.identity` 递归计算子元素包围盒，直接与 `width/height`（`markerWidth/markerHeight`）比较。
- `f_svg/src/SvgMarkerExpander.cj:176-183` 的 `viewportWidth/viewportHeight` 就是 `markerWidth/markerHeight`（视口坐标），而 marker 子元素的路径坐标在存在 `viewBox` 时是 **viewBox 内容坐标**；两者之间还差 `preserveAspectRatio.toMatrix(viewBox, w, h)`（`SvgMarkerExpander.cj:384-392`）。
- 例：`markerWidth="10"`、`viewBox="0 0 5 5"`（内容放大 2 倍）、子元素 `<rect width="6" height="6"/>`。内容坐标 6 ≤ 10，`markerContentFits` 返回 true；实际映射到 12 > 10，已越出视口。
- `f_svg/src/SvgRenderTree.cj:807-835` 在 `contentFits == true` 时把 `markerClip` 设为 `None` 且不追加 quad，于是越界内容完全不裁剪。W7 之前 marker 始终有 AABB 裁剪，因此这是本次修复引入的回归。
- 同一函数只看 `child.attr("stroke")` / `child.attr("filter")` 等呈现属性（`:1035-1042`），不读计算样式；`style="stroke:red;stroke-width:8"` 或 `style="filter:url(#f)"` 会被误判为“完全在视口内”，同样跳过裁剪。
- 另外，marker 的 clip rect/quad 计算在 `:815-825` 用 `viewportMatrix * translate(-refX,-refY)`；`refX/refY` 是 viewBox 内容坐标，存在 `viewBox` 且 `ref != 0` 时应先乘内容矩阵再平移，当前少乘了 viewBox 缩放（这是 W7 之前就存在的 clip 公式问题，W7 把它复制到了 quad）。

影响：默认 `overflow="hidden"` 的 marker 在 `viewBox` 放大或使用样式化描边/滤镜时，内容可越出 `markerWidth × markerHeight`，违反 `svg-paint-and-clip` 的 marker 裁剪要求；这与 W7 的目标相反，且现有测试（`SvgOverflowM4_test.rotatedMarkerClip`、`SvgMarkerExpander_test.alignmentAndViewBox`）都没有覆盖“viewBox + 非零 ref + 放大”组合。

建议：

1. `markerContentFits` 接收并应用 marker 的内容矩阵 `C`（含 `preserveAspectRatio` 与 `ref`），或直接把子元素包围盒变换到视口坐标后再比较；
2. 读取计算样式判断 stroke/filter/clip-path/mask，而不是只读呈现属性；
3. clip rect/quad 的 `ref` 平移改为 `V * C * T(-ref)` 的内容坐标语义，或统一由 `instance.matrix` 推导视口四边形；
4. 补 `markerWidth=10 + viewBox="0 0 5 5" + refX=5 + rect width=6` 的越界像素用例。

### 4.2 WARNING：W7 的四边形蒙版按“每条指令 × 每个 quad”全画布重算，性能/内存回归

证据：

- `f_svg/src/SvgRenderer.cj:571-578` 在 `applyEffects` 中对每条指令遍历所有 `clipQuads`。
- `f_svg/src/SvgRenderer.cj:690-727` 每次 `applyQuadCoverage` 都新建整幅 `SvgBitmap`、整幅 `Array<Byte>` coverage，再做一次全画布光栅化与逐像素乘法。
- `f_svg/src/SvgRenderTree.cj:530-547`、`:827-850` 会把祖先旋转裁剪的 quad 原样传给每个后代指令。
- 复杂度为 `O(命令数 × quad 数 × 画布像素)`；1024×1024 画布、1000 条子指令、1 个旋转 clip 即约 10⁹ 像素级操作和约 6 GB 的临时分配（每 quad 约 4 MB 位图 + 1 MB coverage）。

影响：旋转嵌套 `svg` / marker 内含大量子元素时，渲染时间和 GC 压力显著上升；这是 W7 引入的新开销，现有基准未覆盖该场景。

建议：对同一 `clipQuads` 组合缓存一次覆盖率蒙版（按 clip 身份缓存），或仅在 quad 的包围盒内光栅化/应用；为“旋转 clip + 1000 子元素”增加基准。

### 4.3 WARNING：C1 的“裁剪矩形覆盖即跳过离屏层”未计入文本装饰线，可能漏裁

证据：

- `f_svg/src/SvgRenderer.cj:645-686` 的 `clipRectCoversCommand` 使用 `command.bounds` 判断覆盖；`Text` 命令的 `bounds` 来自 `SvgGeometry.renderBounds` → `SvgTextRenderer.layout().bounds`。
- `f_svg/src/SvgTextRenderer.cj:432-492` 的 `layout` 只把字形路径包围盒并入 `bounds`，**不含** `text-decoration`；装饰线在 `SvgRenderer.cj:290-315` 的 Text 分支内另行绘制。
- 因此嵌套 `svg` 视口紧贴字形时，`clipRectCoversCommand` 会认为矩形覆盖文本，跳过离屏层，下划线/上划线（基线下方 `0.1 × fontSize`）可能绘制到视口外；`margin = 1.0` 只能吸收 1 像素。

影响：这是 C1 优化引入的裁剪回归，条件较窄（文本 + 装饰线 + 紧视口），但违反 `overflow="hidden"` 的裁剪契约。

建议：`clipRectCoversCommand` 对 `Text` 命令使用包含装饰线的包围盒，或对 `Text` 禁用该跳过优化；补一条“嵌套 svg 紧贴下划线文本”的用例。

### 4.4 WARNING：W4 后 `SvgGeometry` 的文本 bounds 仍未传计算样式树

证据：

- `f_svg/src/SvgGeometry.cj:33-37` 的公共 `bounds` 经 `:851-866` 的 `textElementBounds` 调用 `layout(text, style: style)`，`:99-113` 的 `renderBounds` 调用 `layout(text, style: style, root: root)`，两处都没有 `styles` 参数。
- W4 后 `SvgTextRenderer.collectSvgTextChars` 对 tspan 的 `dominant-baseline` / `alignment-baseline` / `baseline-shift` / `text-decoration` 走计算样式（`SvgTextRenderer.cj:721-790`），font-size 等仍读原始属性；而 `SvgRenderTree.cj:374` 用 `renderBounds` 生成 Text 命令的 `bounds` 与滤镜区域。
- 结果：`<tspan style="baseline-shift:super">` 或 CSS 选择器设置的基线属性会改变实际字形 y，但 `bounds` 仍按无样式布局计算，导致 Text 命令包围盒、滤镜区域与 `clipRectCoversCommand` 判断偏差。

影响：样式化 tspan 的包围盒在 y 方向可能偏小或偏移，可能裁掉滤镜输出或错误跳过裁剪；不影响无样式 tspan 与 M1–M3 快照。

建议：把 `styles` 贯通到 `SvgGeometry.renderBounds` / `bounds`，或让 layout 的 bounds 与实际排版共用同一路径。

### 4.5 WARNING：W1/W9 的文档与勾选不一致

证据：

- `f_svg/doc/spec/add-f-svg-m4/tasks.md:145-146`：18.6 勾选为 `[x]` 且标题写“（通过）”，下一行却写“未能执行 CLI……该项保留未勾选”。`f_svg/doc/spec/add-f-svg-m4/verification.md:340` 也写“保持未勾选”，与实际文件不符。
- `f_svg/README.md:269-270` 与 `README_en.md:263-265` 仍称“唯一条件性差异是 marker”，没有提 `switch` 从 M3 普通容器到“只选第一个满足条件子元素”的行为变化；proposal `:76` 有该说明。
- `verification.md:11/27/30` 的 143 个 Scenario、svg-security 10 个 Scenario 已过期（实际 144/11）。

影响：验收记录过度声明，归档时会误以为 `openspec validate --strict` 已通过、switch 兼容性已在 README 说明。

建议：把 18.6 改回 `[ ]` 并删除“（通过）”；README 中英补 switch 例外；更新 verification 的计数。

### 4.6 WARNING：W2 中三条断言强度不足

证据：

- `SvgTrueTypeTables_test.cj:122-130` 的 `locaTruncatedInMiddle` 把整个字节数组截到 `loca.offset + 3`，`SvgTtfTableDirectory.parse` 在目录阶段就会因 `offset + length > bytes.size` 抛 `Syntax`，没有经过 `SvgTtfTableReader.require` 的表中段路径。
- `SvgSecurity_test.cj:186-202` 的“字体不读文件”只断言渲染成功且出现“未找到字体”warning；没有文件系统探针，无法区分“没读”与“尝试读失败后降级”。静态检查显示渲染链确实只查注册表（`SvgTrueTypeFont.load` 仅由调用方显式调用），行为正确但测试不能证明。
- `SvgFilterNoiseM4_test.cj:205-219` 的共享预算用 `shared.load(...)` 后直接调用 `feImageFilterBuffer`，验证的是同一个 `SvgImageResource` 的累计计数，不是一次渲染中 `<image>` 与 `feImage` 的集成路径。
- `SvgSwitch` 的 `requiredExtensions=""` 已修为满足（`SvgSwitch.cj:70-80`），但 `emptyConditions` 只测了 `requiredFeatures` 与 `systemLanguage`。

影响：这些用例会在实现退化时仍然通过，属于测试有效性问题，不影响当前行为结论。

建议：为 loca 单独设置“表长度不足但文件完整”的用例；用可注入的 FS/provider 证明字体未读文件；增加包含 `<image>` 与 `feImage` 的单次渲染预算用例；补 `requiredExtensions=""` 断言。

### 4.7 WARNING：W5 的“按字形起点取样”实际是“每个字形重设渐变包围盒”

证据：

- `f_svg/src/SvgTextRenderer.cj:518-570` 为每个字形生成一个 `SvgDecorationRun`，其 `bounds` 是该字形装饰线路径的包围盒。
- `f_svg/src/SvgRenderer.cj:288-314` 用 `run.bounds` 调用 `drawFill`；对 `gradientUnits="objectBoundingBox"` 的渐变，这会把每个字形的装饰线当作独立的渐变对象，渐变在每个字形内重新从 0 到 1。
- 新增测试 `SvgTextDecorationM4_test.cj` 的 `decorationGradientPerGlyph` 明确断言“第二个字形起点重新接近渐变起点（红）”，把该解释固化。
- spec `svg-text:46` 与设计 `f_svg-M4设计.md:143` 的措辞是“渐变按字形起点取样 / 取字形起点颜色”，更自然的语义是保持整段文本的渐变几何，仅取起点颜色；“重设 bbox”会改变 objectBoundingBox 渐变的几何。

影响：装饰线在 objectBoundingBox 渐变下的颜色分布与“取样”语义不一致；`userSpaceOnUse` 渐变不受影响。

建议：在 spec 明确“每个字形独立 objectBoundingBox”或改为按文本整体 bbox 建渐变、按字形起点取色；同步测试。

## 5. 回归检查

### 5.1 M1–M3 逐字节

- 13 个快照全部由 `compareSceneExact` 比较，`cjpm test` 全绿。
- `git diff a39db449..HEAD -- <13 个 M1–M3 .rgba>` 为空，证明快照未被修复重新生成。
- 修复改动只更新了 M4 快照：`m4-text.rgba`（W6 stretch 缩放字形宽度）与 `m4-clip.rgba`（W7 marker 精确视口）；`m4-filter` / `m4-view` 未变。

### 5.2 M4 快照

- `SvgSceneM4_test` 仍按容差 ≤1 比较，符合 delta spec 的 M4 场景要求；本次未发现 M4 快照与实现不一致（691 条全绿）。
- 注意 `m4-clip.rgba` 在 W7 中因裁剪语义变化被更新，属于预期变更，不是回归。

### 5.3 性能

- 全量 691 条约 10.95 s；M4 基准 545.8 ms，与 `perf-baseline.md` 的 M4 参考值一致。
- M1–M3 渲染路径未发现新增分配或循环；C1 的跳过离屏层总体上减少分配。
- 新增的 W7 quad 蒙版是唯一的明显性能/内存风险，见 4.2；现有基准没有覆盖旋转裁剪。

### 5.4 内存

- 未使用堆分析器，本节为静态分析。
- C3 的 `SvgTtfTableReader` 复用原 `Array<Byte>`，不复制表数据；点数字段在分配 flags/xs/ys 前已限制到 10000，未发现新的内存放大。
- C5 的检查在任何大缓冲分配前执行；但计算量问题仍属 CPU DoS（见 C5 结论）。
- W7 的每次 `applyQuadCoverage` 会临时分配约 `5 × 宽 × 高` 字节（4 B/px 位图 + 1 B/px coverage），见 4.2。

### 5.5 构建

- `cjpm build` 成功；`f_svg` 自身 0 warning；依赖 `f_xml` 的 22 条 warning 与修复前一致。

## 6. 复验限制

1. 本机无 `openspec` CLI（`which openspec` 失败），无法执行 `openspec validate --strict`；只能人工核对 43 个 Requirement / 144 个 Scenario。
2. 未使用内存 profiler，5.4 的内存结论是静态推导。
3. 仓库无 CI；逐字节基线目前只由 `cjpm test` 执行，没有独立门禁。
4. 未修改任何源码、未归档、未执行 git 写操作；分支与工作区状态保持原样。
5. 复验发现的 marker `viewBox + ref` 裁剪公式问题在 W7 之前已存在；本次将其列为 W7 新回归的一部分，是因为 `contentFits` 跳过裁剪使该问题从“AABB 偏松”升级为“可能完全不裁剪”。

## 7. 建议处理顺序

1. **C5**：改为可分离形态学或固定小半径 + 运算预算，更新 `svg-security` 上限表；这是当前唯一未清除的原始 CRITICAL。
2. **4.1**：修 `markerContentFits` 的坐标系与计算样式判断，补 `viewBox + ref + 放大` 用例；这是本次修复引入的 CRITICAL。
3. **4.2 / 4.3**：为 quad 蒙版增加缓存/包围盒裁剪；为 Text 的 C1 跳过逻辑补装饰线 bounds。
4. **4.4**：把 `styles` 贯通到 `SvgGeometry` 的文本 bounds。
5. **4.5 / 4.6 / 4.7**：修正 tasks 18.6 勾选、README switch 说明、verification 计数；加强 W2 用例；明确 W5 渐变语义。

CRITICAL=2
