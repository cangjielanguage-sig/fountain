# add-f-svg-m2 终验修复计划（第三轮）

> 依据：第三轮只读终验结论（N1–N9 已清除、C1–C9 无回退、CRITICAL=0），新发现 2 个 WARNING。
> 纪律：每项先写失败用例（Red），确认失败原因，再写最小实现（Green），`cjpm test` 全绿后独立提交。
> 分支：`feature/f_svg`。

## 1. WARNING

### W1. 根 `text` 与外层 `tspan` 覆盖内层显式 `x` / `y`

**现状**：`collectSvgTextChars` 在子 `tspan` 返回后写入其 `x`/`y`，但不再区分「该字符是否已被内层显式定位」；`applyRootTextAttributes` 在收集完成后无条件把根 `text` 的 `x`/`y` 写到**所有**字符。
**规格**：`svg-text` 要求「`tspan` 显式提供 `x`/`y` 时 SHALL 绝对重置当前笔位置」。
**修法**：
- `SvgTextChar` 增加 `xExplicit` / `yExplicit` 标记。
- `tspan` 应用 `x`/`y` 时跳过已显式字符，并标记本次写入的字符。
- 根 `text` 的 `x`/`y` 只填充未显式字符（保留短列表复用末值）。
**用例**：
- `<text x="0"><tspan x="50">A</tspan></text>` → A 在 50，不是 0。
- `<text x="0"><tspan x="50"><tspan x="80">A</tspan></tspan></text>` → A 在 80。
- 无 `tspan` 显式值时根 `x` 列表行为不变（回归）。

### W2. 混合字体场景下缺字判定不完整

**现状**：
- 渲染时字体未注册的 `case None` 只加占位并 warning，不置 `missingGlyph`。
- `SvgGeometry.textElementBounds` 先按根样式 `resolve` 字体，未注册直接返回 `None`，忽略 `tspan` 可能已覆盖字体。
**规格**：`svg-geometry` 要求「未注册任何可用字体或字体没有该字符时，SHALL 返回 `None`」。
**修法**：
- `case None` 分支同样置 `missingGlyph = true`。
- 删除 `textElementBounds` 的根字体预检查，统一以 `layout.missingGlyph` 为准。
**用例**：
- 根 `font-family` 未注册、但 `tspan` 用已注册字体覆盖全部字符 → `Some`。
- 根字体已注册、`tspan` 指定未注册字体 → `None`。

## 2. 完成标准

- W1、W2 落地并有对应用例。
- `cjpm test` 全绿（≥ 346 条），`cjpm build` 中 `f_svg` 自身 0 warning。
- 在 `verification.md` 追加第 8 节，明确 `CRITICAL=0`、本轮 WARNING 清零。
