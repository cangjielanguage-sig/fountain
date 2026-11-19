# add-f-svg-m2 复验修复计划（第二轮）

> 依据：`verification.md` 复验结论（C1–C9 已清除，新发现 3 个 CRITICAL / 6 个 WARNING）。
> 纪律：每项先写失败用例（Red），确认失败原因正确，再写最小实现（Green），`cjpm test` 全绿后独立提交。
> 分支：`feature/f_svg`。

## 1. CRITICAL

### N1. 无 `id` 目标的动画在 `sample()` 中不生效

**现状**：`SvgTimeline.sample` 在 `spec.targetId == None` 时 `continue`；`targetId` 来自 `target.attr("id")`。
**规格**：`svg-animation` 的「采样快照」未要求目标必须有 `id`，`SvgAnimationInfo.targetId` 类型为 `?String`。
**要求**：动画目标按**结构路径**定位，`id` 只用于 `animations()` 展示。
**修法**：`SvgAnimationSpec` 记录 `targetPath = target.elementPath()`；`sample()` 在快照中按该路径查找元素（`targetId` 命中优先，否则路径兜底）。路径查找需处理同名兄弟序号。
**用例**：`<rect><animate attributeName="x" from="0" to="10" dur="1s"/></rect>`，`sample(0.5)` 后 `x == "5"`；原文档仍为原值。

### N2. 数值列表插值未接入时间轴

**现状**：`interpolateAnimationValue` 只尝试标量 / 颜色 / 路径，其余落到 `stringValue`；`SvgInterpolator.numericList` 仅被单测调用。
**规格**：`svg-animation` 的「多类型插值」要求「数值列表：逐项插值，长度不等时按较短者处理，多余项取末值」；`by`、`additive`、`accumulate` 对数值列表同样成立。
**修法**：在 `interpolateAnimationValue` 中于标量之后、颜色之前加入数值列表分支；`by` 的列表相加、`additive`/`accumulate` 的列表叠加走同一套逐项规则。
**用例**：`from="0 0"`、`to="10 20"`，中点结果为 `5 10`；`by="1 2"` 基础值 `10 20` 结束为 `11 22`；`additive="sum"` 列表叠加；长度不等时多余项取末值。

### N3. 同元素多动画未按 `begin` 排序

**现状**：`sample()` 按文档顺序应用动画。
**规格**：「同一元素存在多个动画时 SHALL 按 `begin` 排序，后者覆盖前者」。
**修法**：应用前对 specs 做稳定排序（`begin` 升序，相等时保持文档顺序），再逐个应用。
**用例**：文档中先 `begin="1s"` 后 `begin="0s"`，`sample(2)` 的最终值来自 `begin="1s"` 的动画。

## 2. WARNING

### N4. `font-size` 非法值未按继承回退且无 warning

`SvgStyleResolver` 对非法 `font-size` 固定回退 `"16px"`，绕过「可继承属性回退父计算值」与路径 warning。
**修法**：`font-size` 解析失败时按可继承属性回退父计算值，并产生含元素路径的 warning。
**用例**：父 `font-size=20`、子 `font-size=bogus` → 子计算值为 20 且有 warning。

### N5. `stroke-dasharray` 的 `em` / `ex` 未解析

标量分支走 `resolveFontRelativeLength`，列表分支仍原样输出。
**修法**：列表逐项做 em/ex 解析（基于当前元素字号），再格式化。
**用例**：`font-size=16`、`stroke-dasharray="2em 1ex"` → 等效 `32 <1ex 值>`，且不是 `2`。

### N6. 字体缺字时文本包围盒返回占位框而非 `None`

`SvgGeometry.bounds` 只看注册表是否有字体；`SvgTextRenderer.layout` 对缺字生成占位路径并计入 bounds。
**规格**：「未注册任何可用字体或字体没有该字符时，SHALL 返回 `None`」。
**修法**：`layout` 记录缺字标记；`SvgGeometry` 遇缺字返回 `None`。渲染仍可画占位框（渲染行为不变）。
**用例**：注册只含 `A` 的字体，`text` 内容 `"AB"` → `bounds` 为 `None`；内容 `"AA"` → `Some`。

### N7. `tspan` 的 `x` / `y` 列表仍只作用于首字符

`SvgTextRenderer` 对 `span.x` / `span.y` 只取 `values[0]`。
**修法**：与根 `text` 一致——逐字符消费列表，短列表复用末值。
**用例**：`<tspan x="10 20">ABC</tspan>` → 三个字符分别落在 10 / 20 / 20。

### N8. 退化线性渐变叠加 `spreadMethod="repeat"` 仍取首 stop

`p0 == p1` 返回 `t=1.0` 后仍执行 spread，`repeat` 的 `fmod(1,1)=0` 回到首 stop。
**修法**：退化分支直接返回末 stop，不再经过 spread。
**用例**：`x1==x2`、`spreadMethod="repeat"`、红→蓝 → 采样为蓝。

### N9. `tasks.md` 工作副本与归档副本漂移

`f_svg/doc/spec/add-f-svg-m2/tasks.md` 为 0/157 勾选，归档副本为 157/157，且部分任务描述仍是旧版。
**修法**：以归档副本为准覆盖工作副本，确保勾选数与描述一致。
**验收**：两份文件 `diff` 为空。

## 3. 不在本轮范围

- W16、SUGGESTION 1–6：保持记录，不改动。
- 性能目标仍为参考口径，不作门禁。

## 4. 完成标准

- N1–N9 全部落地，每项有对应用例。
- `cjpm test` 全绿（预计 ≥ 350 条），`cjpm build` 中 `f_svg` 自身 0 warning。
- 更新 `verification.md` 第 7 节修复结果表，明确 `CRITICAL=0`。
