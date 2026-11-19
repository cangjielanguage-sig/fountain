# add-f-svg-m4 终验修复计划（第三轮）

> 依据：`verify-report-3.md`（CRITICAL 1，已由主流程直接修复；WARNING 5）。
> 纪律：每项先写失败用例（Red），确认失败原因正确，再写最小实现（Green），全绿后独立提交。
> 分支：`feature/f_svg`。

## 0. 已完成（主流程直接处理）

- **N1**：`openspec/changes/add-f-svg-m4/specs/svg-security/spec.md` 已同步为「半径 16 + 64 Mi 采样预算」，并补「形态学运算预算超限」Scenario；
- **N4**：`svg-text` delta、`tasks.md`、`verification.md` 已与 `f_svg/doc` 副本同步；计数为 145 Scenario / security 12；
- `openspec validate add-f-svg-m4 --strict` 通过。

## 1. WARNING（本轮修复）

### N2. 装饰线并入 `command.bounds` 改变了文本渐变几何

**问题**：NEW-W1 把装饰线范围并入 `command.bounds`，而 `SvgRenderer` 用该 bounds 建立 `objectBoundingBox` 渐变，带装饰线的文本 fill/stroke 渐变几何被改变。

**要求**：
- `command.bounds` 恢复为纯文本布局包围盒；
- 新增独立的裁剪范围（如 `clipBounds: ?SvgBounds`），只在 `clipRectCoversCommand` 快路径使用；
- 带装饰线的文本渐变结果与不带装饰线时一致（同一 fill）。

**用例**：
- 同一 `text` 加/不加 `text-decoration`，填充渐变采样结果一致；
- 紧贴视口的下划线仍被正确裁剪（NEW-W1 原有断言保持通过）。

### N3. 每个文本多一次 layout

**问题**：`SvgGeometry` 与 `SvgTextRenderer` 各自 layout，单文本约 4 次。

**要求**：单次渲染内按「元素 + 样式版本」缓存 layout 结果，文本包围盒与显示列表复用同一次布局；缓存不跨渲染。

**用例**：用计数包装的字体统计 `advance` 调用次数，带装饰线文本不高于不带装饰线文本的 1.5 倍。

### N5. `markerContentFits` 未考虑子元素自身的 marker

**问题**：子形状带 `marker-start/mid/end` 时，marker 实例可能越界，但快路径判为“内容在视口内”而跳过裁剪。

**要求**：子树中任一元素声明了 `marker-start` / `marker-mid` / `marker-end` 时，直接返回“需要裁剪”。

**用例**：`markerWidth=10`、子路径带 `marker-end` 且 marker 尺寸使实例越界 → 父 marker 仍执行裁剪。

### N6. 字体“不读文件”仍为间接证明

**要求**：保留现有内存 `parse` 用例，并在文档中明确“库内不打开路径，`load(path)` 是唯一文件入口”；若可行，用不存在的路径断言 `load` 抛 `SvgException` 且 `parse(bytes)` 正常工作。

## 2. 记录不改

- 字体文件访问的强证明（受语言运行时限制）；
- 其余已在第 8 节记录的限制。

## 3. 完成标准

- N2、N3、N5、N6 落地；
- `cjpm test` 全绿（≥ 704 条），`f_svg` 自身 0 warning；
- M1–M3 全部快照逐字节通过；
- `verification.md` 追加结果，明确 `CRITICAL=0`。
