# verify 修复计划（add-f-svg-module）

依据：`verify-report.md`。目标：清零 CRITICAL，修复影响安全/数据正确性的 WARNING，其余记录为已知限制。
每个修复先补失败用例（Red），再改实现（Green），跑 `cjpm test`，绿后提交。

## 必须修复（CRITICAL）

### C-1 外部引用过滤覆盖所有 URL 型属性

- 在构建期统一检查：`fill`、`stroke`、`filter`、`clip-path`、`mask`、`marker-start`、`marker-mid`、`marker-end`、`cursor`。
- 值中出现 `url(...)` 且内容不是 `#` 开头 → 按 `unsafePolicy` 处理（默认 `Remove` 移除属性 + warning；`Reject` 抛 `Security`；`Keep` 保留）。
- `SvgPaint` 的 `#id` 引用不受影响；`url(#id)` 保留。
- 增加解析级用例：`<rect fill="url(https://evil/x.svg#p)"/>`、`<rect filter="url(http://evil/f.svg#f)"/>`、`stroke`、`clip-path`；默认移除、严格拒绝、Keep 保留。

### C-2 往返契约与实现对齐

采用「规范形式可表示」口径，并补 `#rrggbbaa` 精确往返：

- `SvgColor.toString`：alpha 可由 0..255 字节精确表示时输出 `#rrggbbaa`（如 `#ff000080`），否则输出 `rgba(..., a)`；`parse(toString(x)) == x` 对 `#rrggbbaa` 成立。
- 规格/README/设计统一改为：
  - 值类型 `parse(toString(x)) == x` 仅对「规范形式可表示」的值成立；
  - 明确列出不保真边界：`|v| < 1e-6` 归零、超过 6 位小数舍入、`SvgPreserveAspectRatio` 的 `none` 无 `slice` 语义（若实现保留 slice 则改为可保真）。
- 增加边界用例：`1e-7` → `0`、`1.2345678` → 舍入、`#ff000080` 精确往返、`M0.1234567 0` 舍入行为。
- 同步更新 `doc/f_svg模块设计.md`、`README.md`、`README_en.md`、`specs/svg-value-types/spec.md`。

## 必须修复（WARNING）

- **W-3.3 重复 href**：`SvgWriter.normalizeElementHrefs` 先按展开名去重，再按 `xlink` 选项统一写一种；`<use href="#a" xlink:href="#b"/>` 只输出一个引用。补用例。
- **W-3.4 `SvgPaint.referencing` 自洽**：工厂自动补 `#`（已带则保持）；`reference` 统一存 `#id`；规格/README 示例统一。补 `referencing("grad1")` → `url(#grad1)` → `parse` 成功。
- **W-3.5 `setAttr(namespace:local:)` 前缀**：元素内维护 URI→前缀映射，按 `ns1`、`ns2`… 分配稳定前缀；同一 URI 复用；不同 URI 不冲突。补多命名空间 setter 用例。
- **W-3.6 外部命名空间属性校验**：只有 `namespace == SVG` 且已知元素才做 `validateSvgAttribute`；外部命名空间属性原样保留。补 `<x:rect fill="var(--x)"/>` 严格模式不报错。
- **W-3.7 `javascript:` / `file:`**：`allowExternalReferences=true` 只放行 `http`/`https`/协议相对；`javascript:` 与 `file:` 仍按 `unsafePolicy` 处理，只有 `Keep` 保留。补用例。
- **W-3.8 声明编码**：写入时按 `SvgWriteOptions.charset` 生成声明的 `encoding`（保留 version/standalone）；`writeSvgString` 对非 UTF-8 charset 抛 `InvalidValue`。补用例。
- **W-3.9 `none slice` 往返**：`toString` 在 `NoAlign && slice` 时输出 `"none slice"`。补用例。
- **W-3.12 任意命名空间的 `script`**：按 local name 过滤，不再限定 SVG 命名空间。补 `foreignObject` 内 XHTML script 用例。
- **W-4.1 标签表**：把 `style`、`title`、`desc`、`metadata` 加入已知标签，映射为通用 `SvgElement`（保留 tag/属性/子节点，不告警、严格模式不拒绝）。补用例。
- **W-4.2 D2 描述**：设计文档改为「构建时校验一次；类型化值首次读取时解析并缓存」，不再声称构建时预置缓存。
- **W-4.3 往返表述**：与 C-2 同步。
- **S-3.13 易修项**：
  - `SvgTransform.parse` 拒绝 `translate(10,)` 尾逗号；
  - `elementsByTag` 只返回后代，不含根元素；
  - `SvgElement.toString` 对 CDATA 的 `]]>` 与注释的 `--` 做安全处理；
  - `xlink=false` 只折叠 SVG/XLink 命名空间的 `href`；
  - `SvgDocument.toString` 走 `SvgWriter` 默认选项，避免与 `writeSvgString` 不一致。
- **S-2.5 死 API**：删除 `SvgPaintServerRef` 及其测试引用；同步任务/设计文档（如仍需要，改为 internal）。

## 记录为已知限制（不改代码）

- **W-3.10 行列号**：XML 词法错误保留行列；SVG 语义错误只有 `elementPath`（`line=column=0`）。在 proposal/README 写明。
- **W-3.11 公开可变列表**：`attributes` / `children` / `warnings` 直接修改会绕过缓存与 parent 维护；文档写明「写入请用 `setAttr` / `appendChild`」，并把该条列为已知限制。
- **S-2.2 性能**：`perf-baseline.md` 与 tasks 17.8 明确「参考值、非门禁」；不声称已达 25/20 ms。
- **S-2.4 测试文件命名**：保持现状，在设计 D11 注明「同一主题的测试可合并到主实现同名文件」。
- **S-2.6 Git 元数据**：worktree 的 `.git` 绝对路径在融合侧不可用，属环境问题；提交在鸿蒙侧完成。

## 验收

- `cjpm test` 全绿（新增用例计入）。
- `cjpm build` 无 `f_svg` 自身 warning。
- `openspec validate add-f-svg-module --strict` 通过。
- 更新 `verify-report.md` 末尾追加「修复结果」表：每条 CRITICAL/WARNING 标注「已修复 / 已知限制」。
