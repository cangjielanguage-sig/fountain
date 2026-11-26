# add-f-svg-m5 复验修复计划（第二轮）

> 依据：`verify-report-2.md`（CRITICAL 1 + WARNING 12）。
> 纪律：每项先写失败用例（Red），确认失败原因正确，再写最小实现（Green），`cjpm test` 全绿后独立提交。
> 分支：`feature/f_svg`。

## 1. CRITICAL

### N1. `@font-face` 跨 family 别名未实现，且规格场景自相矛盾

**问题**：规格场景要求「注册表有 `Brand`，声明 `font-family: Body` → 文本 `Body` 用 `Brand`」，但 `src` 被忽略后没有目标来源；实现只做 `Body → Body` 恒等别名，测试自证。

**决定**：用 `src: local(<family>)` 作为唯一目标来源，修正规格：
- `src` 中出现 `local(<name>)` 且 `<name>` 已注册 → 别名 `font-family → <name>`；
- `src` 中无 `local()` → 仅当同名 family 已注册时建立恒等别名，否则 warning；
- `url(...)` 一律忽略并 warning（不加载文件）。

**用例**：
- 注册 `Brand`，`@font-face { font-family: Body; src: local(Brand) }` → 文本 `Body` 用 `Brand`；
- `src: local(Missing)` → 不建别名 + warning；
- `src: url(x.ttf)` + 注册 `Body` → 恒等别名 + warning；
- 删除 `local()` 解析后首个用例必须失败（防自证）。

## 2. WARNING（本轮修复）

| 编号 | 要求 |
|---|---|
| N2 | delta 与主规格在归档时同步；本轮先确保 `svg-css` delta 的 `@media` 场景与描述一致（删除“跳过 @media”的旧场景） |
| N3 | `SvgGeometry.screenCTM(element, viewport, styles)` 把视口宽高传入 `ctm`，与 `getScreenCTM` 一致 |
| N4 | `getBBox(clipped: true)` 的嵌套 `svg` 裁剪矩形使用 `viewBox` 的 `min-x` / `min-y` / `width` / `height` |
| N5 | `calc()` 允许 `%` 与 `px` 混合（按视口解析百分比），并同步 delta 规格 |
| N6 | GSUB 深度改为「链式 lookup 嵌套深度」，用二层嵌套 lookup 用例验证；第 9 层停止 + warning |
| N8 | `getCTM` 对容器/文本的 `fill-box` 传入元素包围盒，与渲染路径一致 |
| N9 | marker 裁剪优化改用带样式的 `effectiveElementTransform` |
| N10 | README 中英的 `getBBox` / `getCTM` 签名补 `mediaWidth` / `mediaHeight` / `styles` |
| N11 | 恢复 `SvgBidiM5_test.override` 直接用例（不要只靠间接覆盖） |
| N12 | 多个 GPOS format 2 子表的 class matrix 合并而不是互相覆盖（后者补前者未覆盖的 pair） |

## 3. 记录不改

- `SvgFontRegistry` 的 `@font-face` weight/style 限定（M6 处理）；
- N7 `<use>` 自身混合样式（M6 元素级效果统一处理）；
- 13.7 合并与主规格归档同步（归档步骤执行）。

## 4. 完成标准

- N1 清除；
- 第 2 节 WARNING 全部落地；
- `cjpm test` 全绿（≥ 987 条），`f_svg` 自身 0 warning；
- 17 张 M1–M4 快照逐字节一致；
- `verification.md` 追加结果，明确 `CRITICAL=0`。
