# add-f-svg-m4 复验修复计划（第二轮）

> 依据：`verify-report-2.md`（CRITICAL 2 + WARNING 6）。
> 纪律：每项先写失败用例（Red），确认失败原因正确，再写最小实现（Green），`cjpm test` 全绿后独立提交。
> 分支：`feature/f_svg`。

## 1. CRITICAL

### C5-2. `feMorphology` 半径上限仍不足以阻止 DoS

**问题**：`min(4096, max(区域宽, 区域高))` 在 512×512 区域仍允许半径 512，采样量约 1.1×10¹²。

**要求**：
- 固定像素半径上限 `16`（`radius` 超过即 `Limit`）；
- 复杂度守卫：`width × height × (2rx+1) × (2ry+1) ≤ 64 × 1024 × 1024`，否则 `Limit`；
- 两道检查都在循环前；
- `svg-security` 的 M4 上限表更新为上述两条。

**用例**：512×512 + `radius=512` → `Limit`；512×512 + `radius=16` → `Limit`（复杂度守卫）；64×64 + `radius=4` → 正常。

### NEW-C1. `markerContentFits` 误判导致跳过裁剪

**问题**：`SvgRenderTree.markerContentFits` 用内容坐标直接与 `markerWidth/markerHeight` 比较，未应用 `viewBox` 内容矩阵；样式化 `stroke` / `filter` 只读呈现属性。

**要求**：
- 用渲染时的完整内容矩阵（`markerUnits` × `viewBox` × `preserveAspectRatio`）把子元素包围盒变换到 marker 视口坐标再比较；
- 描边外扩与滤镜区域外扩从**计算样式**读取（`stroke` / `stroke-width` / `filter`）；
- 任一条件无法确定时回退为“需要裁剪”，不得误判为“无需裁剪”；
- 保留“内容完全在视口内时不建蒙版”的快路径。

**用例**：
- `markerWidth=10`、`viewBox="0 0 5 5"`、子元素 `width=6` → 判定越界并裁剪；
- `style="stroke:red;stroke-width:4"` 的子元素超出视口 → 裁剪；
- `filter` 作用于超出视口的 marker 内容 → 按滤镜区域裁剪；
- 内容确实在视口内 → 不产生蒙版（可用内部计数或像素等价断言）。

## 2. WARNING

### W1-2. 任务勾选与说明矛盾

`tasks.md:145` 的 18.6 已勾选但下一行说明“保留未勾选”。
**要求**：删除矛盾说明，18.6 标注“已由主流程执行并通过”。

### W2-2. 三个断言未真正触达目标路径

- `loca` 中段截断用例在目录解析阶段就失败，未触达表级读取器；
- “字体不读文件”只验证降级 warning；
- `<image>` + `feImage` 共享预算不是单次渲染集成用例。

**要求**：构造能通过目录解析、在 `loca`/`glyf` 读取阶段失败的用例；用计数 provider 验证单次渲染内两处资源共享同一预算；字体用例改为断言 `parse(Array<Byte>)` 不产生任何文件访问（用不存在的路径反证 + 只从内存解析成功）。

### W7-2. 四边形蒙版的复杂度

**问题**：每条指令 × 每个 quad 全画布重算，`O(命令数 × quad 数 × 画布像素)`。

**要求**：每个 quad 只在其设备 AABB（外扩 1 像素）内写蒙版；同一元素多个 quad 共用一张蒙版；补大文档基准（100 个裁剪元素）并记录。

### W9-2. README 未提 switch 差异

**要求**：README 中英的兼容性说明补上“`switch` 由遍历全部子元素改为选第一个满足条件者”。

### NEW-W1. 文本裁剪快路径忽略装饰线

`clipRectCoversCommand` 用 Text 的 `bounds`，不含 `text-decoration`。
**要求**：文本带装饰线时把装饰线范围并入 bounds，或对该命令禁用快路径。

### NEW-W2. `SvgGeometry` 未接收计算样式树

`renderBounds` / `bounds` 未传 `styles`，样式化 `tspan` 的字形 y 与包围盒可能不一致。
**要求**：`SvgGeometry.bounds` / `renderBounds` 增加可选 `styles` 参数（默认 `None`），渲染树传入；补样式化 tspan 的 bbox 用例。

### NEW-W3. 装饰线渐变语义与规格不一致

实现是“每个字形重设渐变 bbox”，规格写“按字形起点取样”。
**要求**：统一为“按字形包围盒取样”（更符合 SVG 的 `objectBoundingBox` 语义），同步 `svg-text` delta 与设计文档；补渐变装饰线断言。

### NEW-W4. 校验报告计数与结论不一致

`verification.md` 写 143 Scenario / security 10 条，实际 144 / 11；并声称 WARNING=0。
**要求**：更新为实测计数，WARNING 结论改为“本轮计划内 WARNING 已清零，剩余项见已知限制”。

## 3. 记录不改

- S1 CI 接入；
- W7 残余的“裁剪精度”优化之外的性能项；
- 其余与上表重复的 SUGGESTION。

## 4. 完成标准

- C5-2、NEW-C1 清除；
- 第 2 节 WARNING 全部落地；
- `cjpm test` 全绿（≥ 691 条），`f_svg` 自身 0 warning；
- M1–M3 全部快照逐字节通过；
- `verification.md` 追加结果，明确 `CRITICAL=0`。
