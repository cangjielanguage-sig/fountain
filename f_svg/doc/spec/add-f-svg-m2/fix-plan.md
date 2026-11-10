# f_svg M2 校验修复计划

依据：M2 归档后校验报告（CRITICAL=9、WARNING=16、SUGGESTION=6）。
目标：CRITICAL 清零；影响正确性/安全/规格一致性的 WARNING 修复；其余记录为已知限制。
每个修复先补失败用例（Red），确认失败原因，再实现（Green），跑 `cjpm test` 后提交。

## CRITICAL

- **C1 非法动画条目**：`collectAnimationSpecs` 必须过滤缺少 `attributeName` 的 `animate`/`set`、缺少 `type` 的 `animateTransform`、无 `path`/`mpath` 的 `animateMotion`；只记 warning，不进入 `animations()`、不参与 `duration()`、不参与采样。补 `animations().size == 0` 用例。
- **C2 递归/循环上限**：统一规则——**循环引用**（当前栈上重复）在深度 64 终止并 warning，渲染继续；**非循环超深**（>64）抛 `SvgException(kind: Limit)`。覆盖 `use`、嵌套 `<svg>`、渐变 `href`、`clipPath`、`mask`、`mpath`。`mpath` 循环改为 warning，不再一律 `Limit`。补 65 层非循环 `use` 抛 `Limit`、`mpath` 循环 warning 用例。
- **C3 `animateMotion.keyPoints`**：解析并校验；与 `keyTimes` 对应时按关键点映射路径进度；缺省按路径长度匀速。补直线/曲线 `keyPoints` 用例。
- **C4 `calcMode="paced"`**：按数值距离（数值差、颜色 RGBA 距离、列表逐项距离和）分配时间；补 `values="0;10;0"` 与不等距关键帧用例，确保与 linear 结果不同。
- **C5 `CssSelectorPart.combinator`**：公开字段补齐（最左为 `None`，其余为 `Some(Descendant/Child)`），选择器解析时填充；保留现有 `combinators` 或迁移，补公开 API 断言。
- **C6 `SvgBounds.inflate` 负值**：宽高用 `max(0, width + 2*amount)` / `max(0, height + 2*amount)`；空盒扩展后仍为空；修改现有相反断言。
- **C7 空格字形**：`SvgFont.glyphPath(32, size)` 返回命令为空的 `SvgPathData`，不是 `None`；不可打印字符才返回 `None`；修改现有相反断言，并确认文本渲染仍正确。
- **C8 线性渐变 `p0 == p1`**：取**最后一个 stop**；修改现有相反断言。
- **C9 文本 `x`/`y` 短列表**：列表短于字符数时**复用最后一个值**（`y` 修正当前的第一个值逻辑）；补单值 `x`/`y` 多字符用例。

## WARNING（必须修复）

- W1 径向渐变 `r <= 0`：不绘制 + warning；补“无像素”断言，修正文案。
- W2 可继承属性非法值：回退到**父元素计算值**；不可继承属性回退初始值；补“父 fill=red，子 fill=bogus”用例。
- W3 属性元数据：`stop-color` / `stop-opacity` 改为不可继承；把 `clip-path` / `mask` 加入属性表（不可继承），渲染器从计算样式读取。
- W4 `em` / `ex`：所有长度属性的 `em`/`ex` 按当前元素计算 `font-size` 解析；补 `stroke-width="2em"` → 32（font-size 16）用例。
- W5 `SvgViewport.from`：两个 fallback 都 ≤ 0 时抛 `InvalidValue`；补用例。
- W6 最终像素尺寸：`ceil(width × dpr)` / `ceil(height × dpr)`；补 1.1 / 1.3 DPR 用例。
- W7 `keyTimes` / `keySplines` 数量不符：回退并记 warning；补用例。
- W8 `clipPath` / `mask` 递归引用：按 C2 统一深度/循环规则实现；补嵌套与循环用例。
- W9 文本 bbox：渲染树把 `options.fonts` 传给 `SvgGeometry.bounds`；文本 bbox 遵循 `tspan` 字号、`dx/dy`、`letter-spacing`、`word-spacing`、`textLength`；补自定义字体与复杂文本用例。
- W10 CSS 警告定位：非法值/外部画笔 warning 包含元素路径；补断言。
- W12 测试阈值：贝塞尔扁平化 ≤ 0.25、快速路径覆盖率差 ≤ 1/255、45° 斜边相邻像素覆盖率和约 1；补九种对齐中的其余六种视口用例。
- W13 PNG：逐 chunk CRC 校验；`savePng` 读取文件字节与 `toPngBytes()` 相等。
- W14 端到端补测：`SvgRenderer` 的 `maxPixels` 超限、`<image href="file:///etc/passwd">` 不打开文件且像素为占位、单元素渲染不继承祖先样式、`<defs>`/未引用渐变不产生指令、不同 `samplesPerPixel` 的确定性、65 层 `<use>` 抛 `Limit`。
- W15 任务与计数：`proposal.md` / `design.md` 的 M1 用例数统一为 216；修复后把 tasks 中不实的 `6.4`、`11.3`、`14.11`、`14.13`、`16.7` 补齐到真实；新增测试文件命名按设计约定或更新设计说明。
- **W11 性能**：不追求达标；在 `doc/perf-baseline.md` 明确 CSS 匹配口径（简单类选择器 × 1000 元素、仅匹配阶段）、渲染基准的 SSAA 档位与实测差距，并补几何 bbox 基准。标注“参考、非门禁”。

## SUGGESTION（低成本可做）

- 删除空的 `CssParser.cj`（解析已在 `CssStyleSheet.cj`）或补职责注释。
- `SvgScene_test`：`.rgba` 缺失时直接失败，不自动写文件。
- `SvgFontRegistry.resolve` 未知 family 回退到默认字体（Hershey），并补测试；或同步修改规格——优先实现回退。
- 补选择器负向测试（命名空间 `|`、`+`/`~`、转义）。

## 归档与文档同步

- 归档目录已清除 `specs/specs` 重复结构；修复后把最终 `proposal.md` / `design.md` / `tasks.md` / `specs/**` / `verification.md` / `fix-plan.md` 同步到 `f_svg/doc/spec/add-f-svg-m2/`。
- 修复完成后重新跑 `cjpm test`、`cjpm build`、`openspec validate --specs`，并做一次定向复验（CRITICAL=0）。
