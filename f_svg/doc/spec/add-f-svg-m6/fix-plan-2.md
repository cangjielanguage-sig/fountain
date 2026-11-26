# M6 校验修复计划（第二轮）

依据：`openspec/changes/add-f-svg-m6/verify-report.md`（CRITICAL=13，WARNING=22，SUGGESTION=4）。

约束：

- 每项先写失败用例（Red），确认失败原因是“功能未实现/语义不符”，再写最小实现（Green），全绿后独立提交。
- 不改 M1–M5 公开 API 语义；25 张 M1–M5 快照必须逐字节一致。
- 9 张 `m6-*` 快照中 `m6-color-interpolation`、`m6-svg2` 允许在修复后按新语义重新生成（属功能修正，不是回归）；`m6-hit-queries` 改为调用命中查询后重新生成。
- 禁止 `git worktree` 命令与改写 `.git`；分支 `feature/f_svg`。

## 1. CRITICAL（C1–C13）

### C1（CP-01）补齐 `SvgHitTest` 规格 API

- 新增 `public static func elementsAt(root: SvgElement, point: SvgPoint, viewport: SvgViewport, styles: SvgComputedStyleTree): ArrayList<SvgElement>` 与 `elementAt(...): ?SvgElement`，签名与 `specs/svg-geometry/spec.md:7` 一致。
- `hitTest` 保留为兼容别名（内部转调），`maxElements`/`options` 作为可选参数。
- 用例：按规格四参签名调用，断言顺序、`None`、与 `hitTest` 结果一致。
- 同时修 C9（`auto` 语义），共用同一命中核心。

### C2（CP-02）`text-decoration` 长属性接入真实渲染

- `SvgTextRenderer.decorationRuns`（`:773`）改为消费 `SvgComputedStyle`：`textDecorationStyle/Thickness/Color/UnderlinePosition`。
- 线型：`solid`/`double`/`dotted`/`dashed`/`wavy`，厚度按 `text-decoration-thickness`（`auto` 用字体度量，长度按用户单位，百分比按字号）。
- 颜色：`text-decoration-color` 独立于文本 `fill`；`currentColor` 取 `color`。
- `effectiveTextDecoration`（`:898`）改为逐长属性合并：子级 `text-decoration-line: none` 覆盖父级简写。
- 简写 `text-decoration: underline dotted red` 展开为三个长属性。
- 删除或接线 `SvgTextDecorationSpec.outline`（死代码），保留单一几何实现。
- 用例：dashed+thickness 3、double、独立颜色、子级 none 覆盖、简写颜色、wavy、百分比厚度。

### C3（CP-03）`text-rendering` 容差映射

- 文本轮廓光栅化传入 `toleranceScale`：`optimizeSpeed` ×2、`auto`/`optimizeLegibility` ×1/×0.5、`geometricPrecision` ×0.25。
- 用例：同一曲线文本在四种取值下的轮廓点数/像素差单调关系（精确档误差更小），并断言 `optimizeSpeed` 同时关闭连字。

### C4（CP-04）`textPath` 的 `pathLength` 接线

- `SvgTextRenderer.cj:639` 调用 `SvgTextPathLayout.place` 时传 `pathLengthRatio = actualLength / pathLength`（`pathLength` 缺失或 ≤0 时为 1）。
- 绝对 `startOffset` 与字形累计弧长均乘该比例。
- 用例：真实 `<text x><textPath pathLength="200">` 渲染，断言首字形位置与截断点。

### C5（CP-05）渐变元素自身的 `color-interpolation` / `color-profile`

- `SvgGradientSampler` 的颜色空间来源改为“渐变元素自身的计算样式，缺失时沿祖先继承，再缺失时用使用元素”。
- `SvgRenderer` 把 `SvgComputedStyleTree` 传给渐变采样器；`color-profile` 非 `sRGB` 时回退 + warning。
- 修复后重新生成 `m6-color-interpolation.rgba`，并补像素断言：两条色带中点必须不同。
- 用例：渐变元素上 `linearRGB` 中点、祖先继承、`color-profile` 非 sRGB 回退 warning。

### C6（CP-06）`vector-effect` 多值解析与固定顺序

- `SvgComputedStyle` 增加 `vectorEffects(): Array<SvgVectorEffect>`（保留 `vectorEffect(): SvgVectorEffect` 返回首值以兼容）。
- 解析空格分隔多值；未知值 warning 并跳过。
- `SvgRenderTree` 传完整数组；`SvgVectorEffect2.apply` 强制固定顺序 `non-scaling-size → non-rotation → fixed-position`。
- 规格统一：删除 `svg-geometry` 中“按声明顺序逐个应用”的 Scenario 措辞，改为固定顺序；design D16 同步。
- 用例：三值同时声明（无论书写顺序）应用顺序固定；未知值 warning。

### C7（CP-07）`auto` 尺寸的 warning 与单轴推导

- `SvgAutoSize.resolve` 增加 `warnings` 参数；无法确定时回退并 warning。
- 单轴 `auto`：另一轴已定且 `viewBox` 存在时按宽高比推导；无 `viewBox` 时该轴取内容包围盒。
- 嵌套 `auto` 取父视口 100%（已有则补断言）。
- 用例：单轴 root auto + viewBox、无内容、无 viewBox、嵌套 auto，覆盖 warning 与推导。

### C8（CP-08）外部文档深度语义统一

- 决定：**外部文档不递归加载外部引用**（与 `svg-security` 一致）。`SvgRenderTree` 解析外部文档时保持 `allowExternalReferences: false`。
- 修改 `specs/svg-render-pipeline/spec.md:43,72-75`：删除“第 5 层抛 `Limit`”，改为“第 2 层外部引用被忽略并追加 warning，provider 对同一 href 只调用一次”；`SvgExternalDocumentM6_test.depthLimit` 更名为 `noRecursion`，断言 provider 调用次数与 warning。
- `SvgSecurityOptions.maxExternalDocumentDepth` 保留但标注“仅限制同一文档内 `use` 展开计数”，或删除字段（二选一，倾向保留并写清语义）。
- 同步 `svg-security` delta 与 design。

### C9（CR-01）`pointer-events: auto` = `visiblePainted`

- `svgHitRequiresVisible` 纳入 `Auto`。
- 用例：`<rect visibility="hidden"/>` 默认 `pointer-events` 不命中；显式 `bounding-box` 仍不命中（visibility 语义优先）。

### C10（CR-02）`SvgMutationKind` 对齐规格

- 枚举改为 `Attribute` / `ChildList`；插入与移除都发 `ChildList`，`child` 字段区分。
- 同步 `SvgMutation.cj` 调用点与测试。

### C11（CR-03）`removeMutationListener` 按引用移除

- `listeners` 中按 `l == listener` 查找并移除；未注册时无副作用。
- 用例：注册 A、B，移除 B 后 A 仍收到事件；移除未注册对象不影响 A/B。

### C12（CR-04）`font-stretch` 参与真实匹配，合成缩放收窄

- `SvgTextRenderer:377` 改调 `registry.resolve(family, weight, style, stretch)`。
- `applyFontStretchSynthesis` 只在“最终选中字体 stretch == 100 且请求值 != 100”时缩放；精确匹配 75% 字体时不再缩放。
- 用例：注册 75% 与 100% 同名字体，`font-stretch: 75%` 选 75% 且 advance 不再乘 0.75。

### C13（CR-05）字体特性开关控制 Type 4 连字与 kern

- `applyFontLigatures` 增加 feature 参数：`font-variant-ligatures: none` 关闭 `liga`/`clig`；`historical-ligatures` 开启 `hlig`；`font-feature-settings` 的 `"liga" 0`、`"kern" 0` 覆盖。
- `applyFontKerning` 读取 `fontFeatures().enabled("kern")`（显式 0 关闭，1 开启），无声明时沿用 `font-kerning`。
- 用例：普通 Type 4 `fi` 连字在 `font-variant-ligatures: none` 下拆开；`"kern" 0` 使字距归零；`hlig` 开关生效。

## 2. WARNING（W1–W14）

| 编号 | 项 | 修法 |
|---|---|---|
| W1（CR-06） | 根元素 `pointer-events: none` 未生效 | `hitTest` 先检查根自身，再遍历子节点 |
| W2（CR-07） | 命中 `maxElements` 未读安全选项 | 缺省取 `document.parseOptions.security.maxElements`，显式参数优先 |
| W3（CR-08） | `text` 轮廓缺失回退 bbox | 轮廓缺失时返回不命中 + warning；仅 `bounding-box` 用 bbox |
| W4（CR-09） | 嵌套 `discard` 无 warning | 超深度时 warning 并跳过 |
| W5（CR-10） | `attributeType` 非法值无 warning | 非法值回退 `XML` + warning |
| W6（CR-11） | `min` 用例无断言 | 改为断言动画值在 `min` 前保持起始值 |
| W7（CR-12） | `font-size-adjust` 遇缺 OS/2 提前 return | 改 `continue`，逐字体处理 |
| W8（CR-13） | 命名空间版 `setAttr`/`removeAttr` 不通知 | 统一走通知路径 |
| W9（CR-14） | `visible` 语义 design 与实现不一致 | 以“内区或描边几何”为准，改 design D2 措辞 |
| W10（CO-01） | CHANGELOG 用例数过期 | 更新为最终实测数 |
| W11（CO-02） | design 代码规模过期 | 更新文件/测试计数 |
| W12（CO-03/CO-04） | 外部文档深度、vector-effect 顺序表述冲突 | 随 C8/C6 一并改 |
| W13（CP-09/CP-10/CO-06/CO-07/CO-08） | 覆盖矩阵缺失、design 文件表漂移、快照语义说明 | 补 `verification.md` 覆盖矩阵、修 design 文件清单与快照说明 |
| W14（CP-12/CP-13） | `font-feature-settings` 样式层 warning 丢失；`foreignObject` 位图无 `maxPixels` | 合并局部 warning；`addForeignObject` 分配前检查并补负向用例 |

## 3. SUGGESTION

- CO-S1：删除 `println` 调试输出。
- CO-S2：枚举 `fromName` 公开（或规格明确为内部）。
- CO-S3：`SvgLineJoin.toString` 与 `attrName()` 统一口径，规格注明。
- CO-S4：删除或接线 `SvgTextDecorationSpec.outline`（随 C2 处理）。

## 4. 记录不改

- `m6-hit-queries` 快照改为调用命中查询后重生成（属修复，不是不改项）。
- 其余 M6 快照仅在语义变化时重生成，并在 `verification.md` 记录原因。
