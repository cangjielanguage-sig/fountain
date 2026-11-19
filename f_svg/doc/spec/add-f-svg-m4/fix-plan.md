# add-f-svg-m4 校验修复计划

> 依据：`verify-report.md`（CRITICAL 5 / WARNING 12 / SUGGESTION 10）。
> 纪律：每项先写失败用例（Red），确认失败原因正确，再写最小实现（Green），`cjpm test` 全绿后独立提交。
> 分支：`feature/f_svg`。

## 1. CRITICAL（必须修复）

### C1. M3 快照没有逐字节验收

**问题**：`SvgScene_test` 的 5 个 M3 场景只用容差 1 比较；`SvgSceneByteBaseline_test` 只覆盖 M1/M2。README/tasks 声称“M3 逐字节一致”不成立。

**要求**：
- 把 `m3-filter` / `m3-pattern` / `m3-image` / `m3-textpath` / `m3-marker` 纳入 `compareExact`（容差 0）；
- 快照缺失时失败而不是写入；
- 修正 tasks 17.5、README 中英的表述（通过后保留“逐字节一致”）。

**用例**：五个 M3 场景逐字节通过；人为改动一个像素时用例如实失败。

### C2. `screenCTM` 矩阵顺序错误

**问题**：当前 `ctm × viewport × scale(dpr)`；渲染器顺序为 `scale(dpr) × viewport × ctm`。

**要求**：改为 `scale(dpr).multiply(viewport.matrix).multiply(ctm(element))`；同步修正 design D9 公式。

**用例**：`<g transform="translate(10,10)">` + `viewBox` meet + `dpr=2`，`screenCTM` 把 `(0,0)` 映射到 `(40,40)`；无 transform 时结果不变。

### C3. TTF 结构校验可抛出非 `SvgException`

**问题**：`endPtsOfContours` 非单调可越界；表 tag 用 `String.fromUtf8` 可能抛非法参数；表读取只校验文件边界。

**要求**：
- `endPtsOfContours` 必须严格递增且最后一项 < 10000，否则 `Syntax`；
- `appendTtfContour` 入口校验 `endPoint < pointCount`；
- 表 tag 按 4 字节 ASCII 校验，非法字符抛 `Syntax`；
- 新增 `SvgTtfTableReader`，所有表读取以 `table.offset/length` 为界，越界抛 `Syntax`；
- `head.length` / `hhea.length` / `maxp.length` / `cmap` 子表长度做最小校验。

**用例**：`endPts=[1000,1]` 抛 `Syntax`；非 ASCII tag 抛 `Syntax`；`head.length=0` 抛 `Syntax`；`cmap` 子表越界抛 `Syntax`；截断 `loca` 中段抛 `Syntax`。

### C4. `SvgVectorEffect` 公开 API 与 spec 不一致

**决定**：采用 `NoEffect`（与 M1 `SvgAspectAlign.NoAlign` 一致），修改 delta spec 与设计文档，不提供 `None` 以避免与 `Option.None` 冲突。

**要求**：`svg-value-types` delta、`f_svg-M4设计.md`、README（中英）统一为 `NoEffect` / `NonScalingStroke`，字符串 `none` / `non-scaling-stroke` 不变。

**用例**：枚举 `toString` 与解析；文档一致性由 grep 检查（无 `SvgVectorEffect.None`）。

### C5. `feMorphology.radius` 无上限

**要求**：
- 像素半径上限：`min(4096, max(regionWidth, regionHeight))`，超限抛 `SvgException(kind: Limit)`，检查在循环前；
- `svg-security` M4 上限表补一行；
- 补负向用例。

**用例**：`radius="1000000000"` 在 100×100 区域抛 `Limit`；`radius` 为正常值时结果不变。

## 2. WARNING（本轮必须修复）

| 编号 | 要求 |
|---|---|
| W2 | 补齐 9 个缺失断言：锐化核、零尺寸输入 warning、`feDisplacementMap scale="nan"`、多语言优先级、`<image>`+`feImage` 预算共享、字体不读文件、`switch` 受 `maxElements` 约束、`loca` 中段截断、无显式 `x` 的竖排列推进 |
| W3 | 表级边界读取器（与 C3 合并） |
| W4 | 文本属性统一读计算样式：`tspan` 的 `dominant-baseline` / `alignment-baseline` / `baseline-shift` / `text-decoration` 走计算样式；祖先 `text-decoration` 从计算样式树继承 |
| W5 | 装饰线按字形起点取样渐变：装饰路径按字形切分，每段用该字形起点作为渐变取样原点 |
| W6 | `textPath method="stretch"` 同时缩放字形宽度；`spacing="exact"` 计入 `letter-spacing`；补 `letter-spacing` 与“未提供时等同 auto”用例 |
| W7 | 旋转视口 / marker 裁剪改用覆盖率蒙版（复用 `clip` 的矩形蒙版），去掉 marker 的 `inflate(1.0)`，补旋转 45° 与边界像素用例 |
| W8 | `anchors()` 返回所有 `a`（无 href 时 `href=None`） |
| W9 | `requiredFeatures=""` / 纯空白视为满足；README 与 proposal 的兼容性例外补上 `switch` 行为变化 |
| W10 | 零尺寸滤镜区域追加 warning；`feConvolveMatrix.order` 必须为正整数（`2.5` → warning + 直通）；补 `edgeMode="wrap"`、`feImage slice`、base64 超限、`scale="nan"` 行为用例 |
| W11 | 奇异 CTM 的 `non-scaling-stroke` 渲染回退用例（按 none 描边 + warning） |
| W12 | `SvgView` 修改字段后写回再解析的断言；说明 setter 写默认值的行为 |
| W1 | 复核 tasks 勾选：无证据的项改为 `[ ]` 或补用例后勾选；18.6 的 validate 由主流程执行 |

## 3. SUGGESTION（本轮处理）

- S4：spec 明确 `clip: none` 等同 `auto`；
- S5：`pointAtLength` 对仅 `M` 的路径返回该点；
- S6：TTF 表读取器测试文件改名为 `SvgTrueTypeTables_test.cj`；
- S9：修正 `SvgTextBaseline.shift` 注释方向；
- S10：补 `view` 无 `viewBox` + 非法视口用例；
- S3/S7/S8：随 W2 一起补测试。

## 4. 记录不改

- S1 的 CI 接入（仓库无 CI 配置；字节基线已进入 `cjpm test`）；
- W7 中“裁剪不够严格”的残余（本次改为蒙版后消除）；
- 其余 SUGGESTION 若与上表重复则随项处理。

## 5. 完成标准

- C1–C5 全部清除；
- 第 2 节 WARNING 全部落地；
- `cjpm test` 全绿（≥ 656 条），`f_svg` 自身 0 warning；
- M1–M3 全部快照逐字节通过；
- `verification.md` 追加修复结果表，明确 `CRITICAL=0`。
