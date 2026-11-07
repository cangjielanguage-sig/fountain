# M6 校验修复计划（第三轮）

依据：`openspec/changes/add-f-svg-m6/verify-report-2.md`（CRITICAL=1，WARNING=8）。

约束：每项先 Red 后 Green，独立提交；25 张 M1–M5 快照逐字节一致；不改 M1–M5 公开 API 语义；禁止 `git worktree` 与改写 `.git`。

## 1. CRITICAL（N1）

### N1 外部文档“不递归”在 `Reject` / `Keep` 策略下失效

- 现象：
  - `unsafePolicy=Reject`：外部文档内部的非片段 `href` 触发 `SvgErrorKind.Security`，与“跳过并 warning”不符；
  - `unsafePolicy=Keep`：href 被保留，`resolveExternalUse` 在 `externalDepth=1` 时再次调用 provider，直到深度 4 抛 `Limit`。
- 修法：`svgExternalParseOptions` 对外部文档统一使用 `unsafePolicy: Remove`（其余安全上限沿用主文档），确保外部 `href` 一定被移除并 warning，不依赖调用方策略；在函数注释与 README 写明该边界。
- 用例：同一 provider 文档内含 `use href="other.svg#x"`，分别用 `Reject` / `Remove` / `Keep` 三种策略渲染，断言 provider 只调用一次、无异常、warning 存在。
- 规格同步（主流程已完成）：`svg-security` 补一句“外部文档内部不安全内容一律按 Remove + warning 处理”。

## 2. WARNING（W1–W10）

| 编号 | 项 | 修法 |
|---|---|---|
| W1 | `pointer-events: all` 仍按包围盒命中 | 改为内区或描边几何（不看 `visibility` / `fill` / `stroke`），补 `all` 在路径外但包围盒内的负向用例 |
| W2 | 文本容差被 `shape-rendering` 二次缩放 | 文本指令只使用 `textTolerance`（`None` 时才回退 `svgShapeTolerance`），补叠加场景断言 |
| W3 | `wavy` 装饰线为开放折线被填充 | 装饰线按描边绘制（`StrokePath`），线宽 = thickness；用例断言不出现双叶填充带 |
| W4 | 请求 80% 但只有 75% 面时不做合成 | `font-stretch` 无精确匹配时按 `请求值 / 选中面 stretch` 缩放；只有精确命中才跳过 |
| W5 | `clig` 只进开关集合，未参与替换 | 将 `clig` 与 `liga` 同等纳入 Type 4 连字替换（仍受 `font-variant-ligatures` / `font-feature-settings` 控制） |
| W6 | `elementsAt` / `elementAt` 为实例方法 | 新增 `public static func` 版本（内部转调实例实现），保留实例方法兼容；用例按静态调用编译 |
| W7 | provider 返回 `None` 未缓存 | 负结果同样缓存（单次渲染内），补同一 href 两次 `use` 的 provider 调用次数断言 |
| W8 | `verification.md` 声称“旧 M1–M5 用例未改”不准确 | 改为“未削弱旧断言；`:hover` 样本改为 `:active`、helper 扩展属适配 M5 新能力”，列明 4 个文件 |
| W9 | design 仍写“深度 4 抛 Limit” | 主流程已改 design，检查无残留 |
| W10 | 覆盖矩阵计数与规格不符 | 重新生成矩阵：`svg-security` 12、`svg-geometry` 17、`svg-render-pipeline` 34，合计 256；每行场景名与 spec 完全一致 |

## 3. 记录不改

- `SvgHitTest` 实例方法保留（静态版本为新增入口）。
- 外部文档的 `maxExternalDocumentDepth` 常量与 `svgExternalDepthAllows` 仅作异常路径防御，保留但不再可达；在 `verification.md` 注明。
