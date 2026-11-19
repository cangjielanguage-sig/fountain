# add-f-svg-m3 复验修复计划（第二轮）

> 依据：`verify-report-2.md`（CRITICAL 2 / WARNING 5 残留 + 新增 N1–N5）。
> 纪律：每项先写失败用例（Red），确认失败原因正确，再写最小实现（Green），`cjpm test` 全绿后独立提交。
> 分支：`feature/f_svg`。

## 1. CRITICAL

### C4. 公开入口未受 `SvgRenderGuard` 保护

**问题**：`SvgRenderer` 内部路径已共享 guard，但直接调用 `SvgPatternSampler.sample` 或 `SvgRenderTreeBuilder.build` 时没有 guard，内容自引用可无限递归。

**要求**：
- `SvgPatternSampler.sample`、`SvgRenderTreeBuilder.build` 在没有外部 guard 时自行创建 guard；
- 嵌套调用只能复用同一 guard（不得重置引用栈）；
- 循环 → warning 并停止；非循环超深 65 → `Limit`；
- 解码预算同样共享。

**用例**：
- 直接调用 `SvgPatternSampler.sample` 渲染自引用 pattern → 完成 + warning，不栈溢出；
- 直接调用 `SvgRenderTreeBuilder.build` 渲染自引用 marker → 完成 + warning；
- 深度 65 的合法链 → `Limit`。

### C6. 解析 AA 真正按像素列累加有符号面积

**问题**：已删除 8×8 子采样，但实现仍是 32 条 y 向子扫描线近似，不是规格 D11 的逐像素列有符号面积累加；圆误差用全图平均差。

**要求**：
- 对全部扁平化线段，按扫描线计算每条边与像素列的**有符号面积贡献**并累加到对应像素（`area += dx * (y - y0)` 类算法），最终 `coverage = clamp(|area|, 0, 1)`；
- nonzero 与 evenodd 用绕数/奇偶分别判定内外，面积累加只负责覆盖率；
- 删除所有固定子采样分支；
- 逐像素比较基准改为 **64× 超采样参考图**（4× 点采样的量化误差本身可达 15/255，不能作为 2/255 判据），圆另加解析面积基准；
- 同步修改 `specs/svg-rasterization/spec.md` 的 Scenario 文字，明确参考图定义。

**用例**：
- 45° 斜线相邻像素覆盖率和 ≈ 1（误差 ≤ 1/255）；
- 圆对 64× 参考图逐像素通道差 ≤ 2/255；
- 自交五角星 nonzero 与 evenodd 填充面积不同且与解析值一致；
- 甜甜圈内孔覆盖率为 0。

## 2. WARNING（本轮必须修复）

### N1. 空路径降级误判（C5 回归）

`place` 在“路径有效但首个字形放不下/起点被钳制到末端”时返回空集合，被误判为路径为空并绘制完整水平文本。

**要求**：只有路径本身无命令或总弧长 ≤ 0 才降级；有效路径但无可放置字形时绘制空（或截断结果）+ warning。
**用例**：路径长 5、文本宽 50 → 不绘制字形（不是完整水平文本）；`startOffset="200%"` → 空；空路径 → 水平文本。

### N2. `SvgRenderGuard` 缺少异常安全

`enter` 后没有 `finally`，抛异常时引用栈不弹回。

**要求**：所有 `enter` 必须配对 `finally { exit() }`；同一 renderer 复用不误报循环。
**用例**：先触发一次 `Limit`，再渲染正常文档 → 不误报循环、不提前触发深度上限。

### N3. `feTile` 应以完整输入缓冲为 tile

当前以非透明内容包围盒为 tile，含透明 padding 时周期错误。

**要求**：以输入缓冲的完整宽高为 tile 周期（含透明区域），平铺到滤镜区域；0 尺寸输入透明 + warning。
**用例**：4×4 输入，内容仅左上 2×2 不透明 → 输出周期为 4（不是 2）。

### N4. 缺字文本 + filter 整段消失

`SvgGeometry` 缺字返回 `None` 包围盒 → 滤镜区域为空 → 输出全透明。

**要求**：渲染阶段文本包围盒缺字时仍使用占位字形布局计算滤镜区域；`SvgGeometry.bounds` 的公开契约（缺字返回 `None`）保持不变。
**用例**：注册只含 `A` 的字体，`text` 含 `AB` 且带 `filter` → 文本仍可见（占位字形），不因滤镜消失。

### W2. `primitiveUnits` 未乘 CTM 缩放

`objectBoundingBox` 缩放只用了包围盒尺寸，未乘元素/视口变换的缩放分量。

**要求**：`stdDeviation`、`dx`/`dy`、原语坐标按 `primitiveUnits` 与 `transform` 的缩放共同换算。
**用例**：同一滤镜在 `transform="scale(2)"` 下模糊半径与偏移加倍；identity 下结果不变。

### W14. M3 delta 规格未同步 image 占位语义

`openspec/changes/add-f-svg-m3/specs/svg-render-pipeline/spec.md` 仍只写“透明占位”。

**要求**：改为“未注入资源时绘制透明占位；设置 `background` 时按 M2 用背景色填充”，与实现、README 一致（同步到 `f_svg/doc/spec` 副本）。

### W17. 覆盖声明仍过度

`tasks.md:13.1`、`tasks.md:15.7` 与 `verification.md` §2.2 仍保留旧结论。

**要求**：13.1/15.7 改为“按 §2.2 判定列记录，未覆盖项列入已知限制”；`verification.md` §2.2 更新为本轮实测判定，§5 与第 6 节结论一致。

### W19. `userSpaceOnUse` 百分比二次缩放

百分比用设备像素尺寸求值后又应用 `transform`，dpr≠1 或 viewBox 缩放时区域被二次缩放。

**要求**：百分比在用户空间求值（基于当前视口用户尺寸），再统一应用 transform。
**用例**：`viewBox="0 0 200 100"` 输出 400×200、`x="10%"` → 20 用户单位（不是 40）；DPR 1 与 2 结果一致。

### W21. textPath 警告缺定位

`SvgTextRenderer` 的“路径缺失或为空”warning 未带元素路径；测试只覆盖 `path=""`。

**要求**：所有 textPath 降级/截断 warning 带 `${location}`；补 `href="#missing"` 用例。
**用例**：断言 warning 含 `/svg[1]/...`。

## 3. 记录不改

- W6 `linearRGB` 常量色近似；
- W8 marker `href` 属性/内容继承；
- W15/W16 剩余的“部分覆盖/负向缺口”记录在 `verification.md` 已知限制；
- W18 `SvgPatternSampler.sample` 的 `transform` 语义；
- SUGGESTION 未处理项。

## 4. 完成标准

- C4、C6 真正清除（新增用例可证）；
- N1–N4、W2、W14、W17、W19、W21 全部落地；
- `cjpm test` 全绿（≥ 512 条），`f_svg` 自身 0 warning；
- M1/M2 逐字节基线仍通过；
- `verification.md` 追加第 7 节，明确 `CRITICAL=0`。
