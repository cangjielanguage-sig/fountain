# add-f-svg-m3 校验修复计划

> 依据：`verify-report.md`（CRITICAL 7 / WARNING 22 / SUGGESTION 6）。
> 纪律：每项先写失败用例（Red），确认失败原因正确，再写最小实现（Green），`cjpm test` 全绿后独立提交。
> 分支：`feature/f_svg`。不改 M1/M2 公开 API 语义；默认渲染输出必须保持。

## 1. CRITICAL（必须修复）

### C1. 滤镜按元素级图层应用

**问题**：`<g filter>` 完全失效；填充+描边的元素被滤镜两次；marker 不进入元素滤镜输入。

**要求**：
- 渲染树对**每个元素**的输出（fill + stroke + 该元素派生的 marker）作为一个图层单元；元素带 `filter` 时，滤镜作用于该图层一次。
- `GroupBegin` / 组结束路径必须携带并执行 `filter`；`<g filter>`、`<text filter>`、`<image filter>` 与形状一致。
- 元素同时有 `filter`、`clip-path`、`marker-end` 时，顺序为：marker 内容 → 滤镜 → 裁剪/蒙版 → 透明度。
- 组自身的 `filter` 与子元素 `filter` 各自独立生效，不合并。

**用例**：
- `<g filter="url(#blur)"><rect/></g>` 的像素与“把 filter 写在 rect 上”一致；
- 填充+描边的矩形加滤镜后，与“先整体渲染再滤镜”的参考结果一致；
- `marker-end` + `filter`：marker 像素参与滤镜（与去掉 marker 的结果不同）；
- 组 filter 与子 filter 叠加时两者都生效。

### C2. `feTile` 按滤镜区域平铺

**问题**：真实链中 `tileFilterBuffer(input, input.width, input.height)` 恒等。

**要求**：`feTile` 以输入缓冲为一个 tile，平铺到**滤镜区域尺寸**；输入宽或高为 0 时输出透明并记 warning。

**用例**：2×2 输入 + 6×6 区域，经 `SvgFilterRenderer.apply` 后按 2×2 周期重复；0 尺寸输入 → 全透明 + warning。

### C3. 上限乘法防溢出

**问题**：`width * height` 在 Int64 上可溢出，绕过 `Limit`。

**要求**：PNG 解码、`SvgBitmap` 分配、pattern tile 三处统一改为除法/钳制检查：
- 宽或高 ≤ 0 或 > `0x7FFFFFFF` → `Limit`；
- `width > MAX / height` → `Limit`；
- 任何检查都必须在分配/解压之前。

**用例**：`IHDR` 宽高为 `0xFFFFFFFF`、`0xFFFFFFFF × 2`、`(2^31) × (2^31)` 均抛 `Limit`；pattern tile 同边界；检查发生在分配前（用不会真正分配的极大值验证）。

### C4. pattern / marker 内容自引用防护

**问题**：pattern tile 内 `fill="url(#同一个pattern)"`、marker 内容再带 `marker-*` 可无限递归。

**要求**：
- 渲染会话内维护跨嵌套渲染器的 `visited` 集合与深度计数（pattern、marker、gradient 共用）；
- 循环引用 → warning 并停止展开，不抛异常；
- 非循环超深 > 64 → `Limit`；
- 嵌套渲染共享同一个解码预算。

**用例**：pattern 内容引用自身 → 渲染完成 + warning；marker 内容再带 marker-start → 渲染完成 + warning；深度 65 的合法链 → `Limit`。

### C5. 空 `textPath` 降级

**问题**：`path=""` / `d=""` 返回空 `SvgPathData`，所有字形被丢弃。

**要求**：解析出的路径为空（无命令或总弧长 ≤ 0）时视为“路径不可用”，降级为普通水平文本并记 warning。

**用例**：`<text><textPath path="">abc</textPath></text>` 与 `<text>abc</text>` 像素一致 + warning；`href` 指向零长度路径同样降级。

### C6. 解析 AA 按有符号面积累加

**问题**：多轮廓/自交路径退化为固定 8×8 子采样，不是规格算法。

**要求**：
- 把全部轮廓扁平化为设备空间线段；
- 对每条线段按像素列累加有符号面积（扫描线方向），得到每个像素的覆盖率；
- nonzero 与 evenodd 分别按绕数奇偶判定内外；
- 覆盖率钳制到 `[0, 1]`，相邻像素覆盖率和守恒（误差 ≤ 1/255）；
- 复杂自交路径也走同一算法，不再有 8×8 分支。

**用例**：
- 45° 斜线相邻像素覆盖率和 ≈ 1；
- 圆的逐像素通道差与 4× 超采样 ≤ 2/255（逐像素，不是平均值）；
- 自交五角星 nonzero 与 evenodd 的填充面积不同且与解析值一致；
- 多轮廓（甜甜圈）内孔覆盖率为 0。

### C7. `SvgMarker` 属性类型改为可选

**问题**：`refX` / `refY` / `markerWidth` / `markerHeight` 是 `SvgLength`，无法表达缺失。

**要求**：四个属性改为 `?SvgLength`；使用处缺省为 `refX=0`、`refY=0`、`markerWidth=3`、`markerHeight=3`；既有测试改为断言“缺失为 None、读取默认值走使用处”。

**用例**：新建 marker 时四属性均为 `None`；显式设 0 时不为 `None`；渲染默认尺寸仍为 3×3。

## 2. WARNING（本轮必须修复）

| 编号 | 要求 | 用例 |
|---|---|---|
| W1 | 为 M1/M2 六个场景建立**逐字节**基线：新增测试直接比较完整像素数组（容差 0），`.rgba` 缺失时失败而不是写入 | `SvgSceneByteBaseline_test` |
| W2 | `primitiveUnits="objectBoundingBox"` 时 `stdDeviation` / `dx` / `dy` / 区域按包围盒缩放 | 同一滤镜两种 units 输出不同且符合换算 |
| W3 | 滤镜区域上限检查移到输出位图分配之前 | 超限时不分配（用极大 `maxPixels` 反证） |
| W4 | `filter=""` / 非 `url(` 值 → 跳过 + warning | 空 filter 属性产生 warning |
| W5 | `feColorMatrix` 的 `type` 非法值 → warning + 回退 `Matrix`；`Saturate` / `HueRotate` 非有限值 → warning + 回退 | 三条负向用例 |
| W7 | 嵌套 pattern/marker 渲染共享解码预算 | tile 内 image 计入外层预算，超限抛 `Limit` |
| W9 | marker 对多子路径 path 的每个子路径顶点派生 | 两段 `M...L...M...L...` 产生 4 个顶点 marker |
| W10 | `rotate` 列表部分非法 → 忽略非法项，其余生效 | `"10 bogus 30"` → 10/0/30 |
| W11 | PNG 未知关键 chunk → `Syntax` | 未知 critical chunk 抛 `Syntax` |
| W12 | PNG `tRNS` 长度按颜色类型校验；重复 `IHDR`、`PLTE` 长度 0、缺 `PLTE` 的调色板图 → `Syntax` | 四组负向用例 |
| W13 | `patternContentUnits="objectBoundingBox"` 时内容平移到包围盒原点；`userSpaceOnUse` 百分比按视口解释 | 非零原点包围盒的 tile 内容位置正确 |
| W14 | 统一 `<image>` 占位规格文字：未注入资源时若设置 `background` 仍按 M2 用背景色填充 | 规格与 README 同步，不改实现 |
| W17 | 修正 tasks/README/perf 的过度声明：4.7 补 gzip+maxDepth 用例、6.7/11.7 补 mask/filter 用例、12.7 补真实 marker、15.7 与 perf 计数改为实测 | 文档与用例一致 |
| W19 | `userSpaceOnUse` 的滤镜区域百分比按视口尺寸解释 | `x="10%"` 在 200 宽视口为 20 |
| W20 | `decode(stream)` 增加总字节上限（缺省 64 MiB） | 超限流抛 `Limit` |
| W21 | 文本/路径 warning 附带元素路径或 id | 断言 warning 含 `/svg[1]/...` |
| W22 | README 的 provider 示例补充安全策略说明（默认解析会移除 `mem://`，需 `allowExternalReferences` 或 `Keep`） | 文档修改 |

## 3. 记录不改（已知限制）

- W6 `linearRGB` 下 `feFlood` / `feMerge` 常量色未线性化：M3 只保证 sRGB 链一致，`linearRGB` 在文档中标注为近似。
- W8 marker `href` 只取最深元素、不做属性/内容继承：SVG 1.1 语义留给后续里程碑，README 记录。
- W15 21 个部分覆盖：本轮修复 C1–C7 后重新评估，剩余部分记录在 `verification.md`。
- W16 剩余负向缺口：与 C3/C4 相关的已补，其余记录。
- W18 `SvgPatternSampler.sample` 的 `transform` 参数：保留用于可逆性校验，文档注明。
- S1–S6：清理与文档建议，本轮只处理 S6 的计数与 AA 表述、S2 的占位目录删除。

## 4. 完成标准

- C1–C7 全部修复并有对应用例；
- 第 2 节 WARNING 全部落地；
- `cjpm test` 全绿（≥ 466 条），`cjpm build` 中 `f_svg` 自身 0 warning；
- 默认 M1/M2 场景逐字节不变（新增字节基线测试通过）；
- `verification.md` 追加第 6 节修复结果，明确 `CRITICAL=0`。
