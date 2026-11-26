# add-f-svg-m6 校验修复计划

> 依据：apply 收尾自检（独立复跑发现 2 个 ERROR）+ 未完成任务清单（21 项）。
> 纪律：每项先写失败用例（Red），确认失败原因正确，再写最小实现（Green），`cjpm test` 全绿后独立提交。
> 分支：`feature/f_svg`。

## 1. CRITICAL（阻断门禁）

### C1. `SvgRenderTree_test.useExpansion` 回归：use 深度按文档深度计算

**现象**：既有 M1/M2 用例 ERROR：`SvgException: use 引用深度超过 64`。

**根因**：`SvgRenderTree.expandUse` 用 `context.depth >= 64` 判断 use 链深度，而 `context.depth` 统计的是整棵文档的嵌套层数；M6 新增的 `externalDepth` 又把外部文档深度混入。结果普通文档只要嵌套较深就误报。

**要求**：
- 新增独立的 `useDepth`（只在 `expandUse` 内 +1，返回后不残留）；
- 深度检查改用 `useDepth`；`externalDepth` 只用于外部文档；
- 循环仍由 `useStack` 检测，循环时 warning 并停止；
- 非循环但 `useDepth > 64` 才抛 `Limit`。

**用例**：`useExpansion` 恢复通过；60 层普通嵌套 + 1 层 use 不报错；65 层 use 链抛 `Limit`。

### C2. `SvgExternalDocumentM6_test.circularReference` ERROR

**现象**：外部文档自引用时抛异常而不是 warning。

**要求**：外部文档循环引用 warning + 停止，不抛异常；深度超限才抛 `Limit`。

**用例**：A→B→A 外部引用完成渲染 + warning；深度 5（>4）抛 `Limit`。

## 2. 未完成的规格项（必须补齐）

### C3. GSUB Type 5/6 未实现（任务 5.9–5.11）

**要求**：
- Context（Type 5）与 ChainContext（Type 6）的 format 3 解析与应用；
- 回溯 / 输入 / 前瞻序列匹配；替换 lookup 只允许 Type 1 / 4；
- lookup 栈深度 ≤ 8，超限停止 + warning；
- 不支持 format 1/2 时 warning 并跳过。

**用例**：单层上下文替换；前后文匹配与不匹配；覆盖表越界；链式两层；第 9 层停止 + warning；Type 6 回溯/前瞻组合。

### C4. `miter-clip` / `arcs` 仅为近似（任务 8.5）

**要求**：
- `miter-clip`：斜接超过 `miterlimit` 时按 `miterlimit / 斜接长度` 截断端点，而不是退化为 bevel；
- `arcs`：以 `stroke-width / 2` 为半径生成圆弧连接，覆盖外角扇形；
- 三种旧 join（miter / round / bevel）输出逐字节不变。

**用例**：miter-clip 截断位置像素断言；arcs 半径 2 的圆弧覆盖；miterlimit 边界；旧 join 快照逐字节一致。

## 3. 缺失测试与文档（WARNING）

| 编号 | 要求 |
|---|---|
| W1 | 补 5.3 stretch 合成、5.4 small-caps、5.5 OS/2 sxHeight、5.8 GSUB 特性分组、5.16 组合交互的直接用例 |
| W2 | 补 9.3 的 9 张 `m6-*` 快照，并确认重复渲染逐字节一致 |
| W3 | 9.7 覆盖矩阵写入 `verification.md`（54 Requirement / 255 Scenario 逐条映射） |
| W4 | `README_en.md` 同步 M6 章节（与中文一致） |
| W5 | 1.x 过程任务按实际状态勾选（分支按用户指定为 `feature/f_svg`，基线 997 已记录） |

## 4. 记录不改

- 9.8 合并回上游（共享分支，等用户确认）；
- `mesh`/`hatch`、图像格式（M7）；
- `foreignObject` 内部 XHTML（只做注入）；
- ICC 变换（仅 sRGB 回退）。

## 5. 完成标准

- C1、C2 修复，`cjpm test` 0 error / 0 failed；
- C3、C4 落地并有对应用例；
- 第 3 节 WARNING 全部落地；
- `cjpm test` ≥ 1104 条全绿，`f_svg` 自身 0 warning；
- M1–M5 的 25 张快照逐字节一致；
- `verification.md` 追加结果，明确 `CRITICAL=0`。
