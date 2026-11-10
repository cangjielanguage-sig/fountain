# add-f-svg-m5 校验修复计划

> 依据：`verify-report.md`（CRITICAL 10 / WARNING 14 / SUGGESTION 6）。
> 纪律：每项先写失败用例（Red），确认失败原因正确，再写最小实现（Green），`cjpm test` 全绿后独立提交。
> 分支：`feature/f_svg`。

## 1. CRITICAL（必须修复）

### C1. 补 `SvgTransformBox` 公开枚举

新增 `SvgTransformBox`（`ViewBox` / `FillBox`，`Equatable` + `ToString`，大小写不敏感解析），`transform-box` 的计算样式改为该枚举；渲染与几何统一从枚举取值。

**用例**：解析 `view-box` / `fill-box` / 大小写混合；`toString`；未知值回退 `ViewBox` + warning。

### C2. GPOS / GSUB 按 feature 过滤

- GPOS：解析 ScriptList → FeatureList → LookupList，只收集 `kern` 特性引用的 PairPos lookup；无 `kern` 特性时回退 `kern` 表。
- GSUB：同样只收集 `liga` 特性引用的 Type 4 lookup；无 `liga` 时不应用。
- fixture 补真实 ScriptList / FeatureList（feature tag `kern` / `liga`）。

**用例**：GPOS 有 PairPos 但 `kern` 特性缺失 → 不应用且回退 kern 表；GSUB 有 Type 4 但 `liga` 缺失 → 不替换；`liga` 存在 → 替换。

### C3. GPOS format 2 校验 Coverage

`SvgGposPairs.adjust` 在 class matrix 路径先检查左字形是否被 Coverage 覆盖，未覆盖返回 0；修正把 glyph 9 断言为 -70 的错误测试。

**用例**：Coverage 只含 glyph 1 时，glyph 9 调整量为 0；glyph 1 保持原值。

### C4. `@font-face` 缺失目标不回退首个 family

`SvgFontRegistry.derived` 在目标 family 未注册时：不建立别名，返回的注册表附带 warning（或在调用方收集）；不得回退 `primaryFamily()`。

**用例**：默认注册表 + `font-family: Missing` → 文本仍用默认字体，且产生 warning；`Body → Brand` 仅在 Brand 存在时生效。

### C5. `calc()` 支持几何长度属性

把 `width` / `height` / `x` / `y` / `cx` / `cy` / `r` / `rx` / `ry` 注册进级联表；`calc()` 在归一化阶段求值；渲染树与几何读取优先使用计算样式，元素级属性 getter 保持原语义。

**用例**：`rect { width: calc((10px + 5px) * 2) }` → 30；`x: calc(10% + 5px)` 在 200 宽视口 → 25；非法 calc → 回退初始值 + warning。

### C6. GSUB lookup 深度上限

在 lookup 遍历中加入 depth 计数，上限 8；超过停止替换并 warning。单层实现下 depth 恒为 1，但入口与告警必须存在。

**用例**：测试用合成的链式 lookup 描述（测试专用构造器）深度 9 → 停止 + warning；深度 8 → 正常。

### C7. `mix-blend-mode` 按元素整组合成

- blend 从单条命令移到元素/组图层：所有绘制命令（含未过滤文本）在元素级 `GroupBegin` 上携带 blend；
- `needsLayer` 依据元素级 blend 建层，只在组结束时混合一次；
- 元素内部命令不再各自混合。

**用例**：`<rect fill stroke style="mix-blend-mode:multiply">` 与「先渲染到离屏再一次混合」的参考像素一致；未过滤文本的 blend 生效；`paint-order` 组合下仍只混合一次。

### C8. 连字簇消费定位列表项

连字簇视为单个布局单元：
- 消费簇内首个字符的 `x` / `y` / `dx` / `dy` / `rotate` 列表项；
- 其余被消费字符的列表项跳过（不推进笔位置、不计字距）；
- `textLength` / `text-anchor` / 后续字形位置只按簇首计算。

**用例**：`"fi"` + `dx="5 9"` → 总前进量只加 5；`x="10 20 30"` 三字符连字 → 只消费 10；后续字形位置正确。

### C9. 整形管线顺序改为 GSUB → kern/GPOS → bidi

`SvgTextRenderer` 调整：字符收集 → GSUB 连字 → kern/GPOS 字距 → bidi 视觉重排 → 定位。

**用例**：RTL + 连字：连字在逻辑序列上匹配；字距作用于整形后的字形；视觉顺序正确。

### C10. `transform-origin` 全路径接线

统一 `effectiveElementTransform(element, style!, bounds!, viewport!)` 并接入：
- `SvgClipMask` 的 clipPath / mask 子元素；
- `SvgRenderTree` 的 root、嵌套 `svg`、`use` 目标；
- `g` / `text` 传 `bounds`，使 `fill-box` 生效；
- `SvgElementApi` 的容器子元素 bbox；
- `SvgGeometry` 的 `ctm` / `absoluteBounds` 同步。

**用例**：clipPath 子元素带 `transform-origin` 的裁剪结果与主路径一致；`use` 目标 `fill-box` 原点正确；`g` 的 `fill-box` 百分比原点；`getCTM` 与渲染矩阵一致。

## 2. WARNING（本轮必须修复）

| 编号 | 要求 |
|---|---|
| W1 | `SvgFontKerning` 改为枚举；`screenCTM` 增加可选样式重载（与 `ctm` 对齐） |
| W2 | `SvgContextPaint.cj` 落实为实际实现文件（把 `SvgPaint`/`SvgRenderTree` 中的逻辑迁入），或改 design 文件地图 |
| W3 | `paint-order` 未知关键字逐项丢弃，保留合法项后按默认顺序补齐 |
| W4 | `feDropShadow` 非法 `stdDeviation` 回退 2；非法 `flood-color` 回退黑色 + warning；补回退值断言 |
| W5 | `getBBox`：嵌套 `svg` 视口用 `viewBox` 裁剪、`display:none`/`visibility:hidden` 返回 `None`、`use` 循环保护、`symbol` 目标支持、子变换走 `effectiveElementTransform` |
| W6 | `unicode-bidi: embed` 建立嵌入层；`tspan` 的 `direction`/`unicode-bidi` 生效；`B` 分段；竖排列序由 `direction` 决定；`rotate` 绑定逻辑字符 |
| W9 | GSUB 输入上限严格为 4，超限 warning；连字不跨 tspan 字体/字号边界 |
| W10 | README 修正：M4 限制段与 M5 章节一致；删除未实现的能力声明 |
| W11 | 归档时同步主规格（本轮先保证 delta 与实现一致） |
| W14 | `getBBox` / `getCTM` 增加可选 `mediaWidth` / 视口参数；`absoluteBounds` 使用真实视口 |

## 3. SUGGESTION（本轮处理）

- S1：GPOS/GSUB fixture 补真实 ScriptList/FeatureList 与负向用例；
- S2：补 9 个场景测试（`width: calc()`、`SvgTransformBox`、连字列表项、GSUB 深度、竖排列序、@font-face 缺失目标、嵌套 svg 裁剪、整组混合、单连字字形）；
- S3：`m5-shaping` 改用含 kern/GPOS/GSUB 的最小 TTF；`m5-element-api` 增加 API 可断言输出或改名；
- S5：`SvgContextPaint` 文件职责落实；
- S6：多命令元素的 blend 像素回归。

## 4. 记录不改

- 13.7 合并回上游（共享分支，等用户确认）；
- GSUB 上下文替换（Type 5/6）、复杂脚本整形（M5 非目标）。

## 5. 完成标准

- C1–C10 全部清除；
- 第 2 节 WARNING 全部落地；
- `cjpm test` 全绿（≥ 941 条），`f_svg` 自身 0 warning；
- M1–M4 的 17 张快照逐字节一致；
- `verification.md` 追加结果，明确 `CRITICAL=0`。
