# f_svg 模块审查报告（第 20/26 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_svg/src`（本部分 19 个源文件，均为 `.cj`）
- **基线**：工作区快照（`120fd2542`，`git diff` 为空）⇒ 所有问题来源为「存量」
- **审查重点**：SVG/XML 解析与序列化边界、注入与转义、递归与栈溢出、OOM、死代码、重复逻辑
- **报告版本**：分部分报告 v1（供主 Agent 合并为 `f_svg_v2.md`；本文件不写 `docs/review/`）

本部分覆盖：PNG 编解码（`SvgPngDecoder` / `SvgPngEncoder`）、软件光栅器（`SvgRasterizer`）、
点列表与指针事件、`preserveAspectRatio`、`rect` / `radialGradient` / `polygon` / `polyline` 属性包装、
引用守卫，以及 7 个测试文件。解析/序列化的 XML 侧（`SvgParser` / `SvgWriter` 等）不在本部分。

## 发现

### [严重][存量] #1 `antiAlias=Analytic` 与 `shape-rendering:crispEdges` 叠加时，每个被扫到的像素都饱和成不透明

- **位置**：`f_svg/src/SvgRasterizer.cj:284`（`computeCoverage` 的 Analytic 分支）与 `f_svg/src/SvgRasterizer.cj:390`（`coverageTotal` 的 `aaDisabled` 前置分支）
- **来源**：存量（工作区快照，无 diff 可比）
- **判据**：review-checklist §11（语义与命名不符 / 契约与实现不符）、§10 正确性
- **证据**：静态确定 —— `computeCoverage` 在 `antiAlias == Analytic` 时**不看** `aaDisabled`，直接 `return analyticCoverage(...)`，其元素是 `0..65535` 的定点覆盖率（`SvgAnalyticRasterizer.cj:78` `ANALYTIC_COVERAGE_SCALE = 65535`，`SvgAnalyticRasterizer.cj:210-212`（`total = 65535`，`coverage[i] = round(clampSvgUnit(accumulated[i]) * total)`））；而 `coverageTotal()` 第一行 `if (this.aaDisabled) { return 1 }`，于是 `coverageRatio = count / 1 = count ≥ 1`，`alpha = ratio × color.alpha × opacity` 被 `clampSvgUnit` 夹到 1.0。
- **描述**：触发路径完全走公开 API：`SvgRenderOptions(antiAlias: SvgAntiAliasMode.Analytic)` + `shape-rendering: crispEdges`（或 `optimizeSpeed`）→ `SvgRenderer.cj:494` `svgShapeAntiAlias` 返回 `Some(false)` → `SvgRenderer.cj:664/674` 传入 `antiAliasOverride` → `prepareHints` 置 `aaDisabled = true`。结果：解析覆盖率仍按 4×4 精度算出（0..65535），但分母被当成 1，凡是覆盖率 ≥ 1/65535 的像素全部变成 `alpha = color.alpha × opacity`，即整条边缘向外扩约 1 像素并完全实心——`crispEdges` 想要的"1× 采样、二值边缘"反而变成"全实心外扩"。grep `antiAliasOverride` 在 `f_svg/src` 只命中 `SvgRasterizer` 自身、`SvgRenderer:664/674` 与 `SvgRenderingHintsM6_test.cj:106/128`，后者未改 `antiAlias`，故仓内无用例覆盖该组合。
- **建议**：在 `computeCoverage` 里把 `aaDisabled` 判断提前：`aaDisabled` 时走 1× 采样路径（`samples = 1` 的 `collectHits` 分支），不要进 `analyticCoverage`；或让 `coverageTotal()` 在 Analytic 下恒定返回 `ANALYTIC_COVERAGE_SCALE`，并在 `analyticCoverage` 之后把 `coverage` 二值化成 `0 / 65535`。前者与 `samplesPerPixel=1` 的语义一致，改动最小。

### [一般][存量] #2 `fillGradient` / `strokeGradient` 不复位 `aaDisabled` / `toleranceScale`，结果依赖调用顺序

- **位置**：`f_svg/src/SvgRasterizer.cj:189`（`fillGradient`）、`f_svg/src/SvgRasterizer.cj:223`（`strokeGradient`）、状态定义 `f_svg/src/SvgRasterizer.cj:72-74`、重置点 `f_svg/src/SvgRasterizer.cj:107`（`prepareHints`，仅被 `fill` / `stroke` 调用）
- **来源**：存量
- **判据**：review-checklist §11（隐藏状态导致行为漂移）、§10 正确性
- **证据**：静态确定 —— 只有 `fill`（102 行）与 `stroke`（138 行）调用 `prepareHints`；`fillGradient` / `strokeGradient` 直接走 `fillContoursShader` → `computeCoverage`，读的是上一次 `fill` / `stroke` 遗留的 `this.aaDisabled`。
- **描述**：同一 `SvgRasterizer` 实例上依次执行 `fill(path, color: c, antiAliasOverride: Some(false))` 再 `fillGradient(...)`，后者会用 1× 采样渲染（甚至叠加前一条问题的覆盖率分母错误），而单独调用 `fillGradient` 时是正常 AA。仓内 `SvgRenderer.cj:552/596/650` 每个 paint 都新建 rasterizer，所以库内流程不触发；一旦外部使用者复用实例（类是 `public`，`fillGradient`/`strokeGradient` 也是 `public`），渲染结果便与元素绘制顺序耦合，且没有任何警告。
- **建议**：把 `aaDisabled` / `toleranceScale` 从字段改为 `fillContours` / `fillContoursShader` 的显式参数（`computeCoverage(contours, fillRule, aaDisabled, samples)`），或在两个 Gradient 入口开头调用 `prepareHints(1.0, None)` 显式归零；前者能同时消除"字段跨调用存活"这一类问题。

### [一般][存量] #3 覆盖率缓冲按整幅画布分配 `Int64`，默认上限下单个元素可达 512 MiB

- **位置**：`f_svg/src/SvgRasterizer.cj:316`（`let coverage = Array<Int64>(this.bitmap.width * this.bitmap.height, repeat: 0)`）
- **来源**：存量
- **判据**：review-checklist §5（按画布规模一次性物化）、§7（中间副本）
- **证据**：静态确定（按公式可算）—— 分配量 = `width × height × 8` 字节；`SvgRenderOptions.maxPixels` 默认 `64 * 1024 * 1024`（`SvgBitmap.cj:230`，`SvgRenderOptionsM4_test.cj:33` 断言），`SvgBitmap` 自身只占 `4` 字节/像素。满配画布下：位图 256 MiB + 覆盖率 512 MiB；且只在 `firstRow..lastRow`（`311-315`）落到画布内时才分配，**与路径 bbox 无关**——一个 10×10 图标画在 4096×4096 画布上同样分配 128 MiB，每个元素一次。
- **描述**：不是"无界增长"（有 `maxPixels` 拒绝路径），但属于按画布规模而非按路径规模放大内存：一次渲染里 N 个元素就有 N 次 8 B/px 的瞬时分配，GC 压力与大画布下的峰值内存都会被放大；并发渲染多张图时叠加明显。
- **建议**：只分配 bbox 行区间 `(lastRow - firstRow + 1) × width`，索引统一加 `(row - firstRow) * width` 偏移；元素类型可降为 `UInt16`（上限 `samples² = 16`，`UInt8` 也够），收益再乘 4。改后需用等价性用例固定输出（现成的 `SvgRasterizer_test.cj` 覆盖率断言可直接复用）。

### [一般][存量] #4 PNG 编码把整幅位图物化 3–4 份，64 Mi 像素时峰值接近 1 GiB

- **位置**：`f_svg/src/SvgPngEncoder.cj:44-53`（`buildRawScanlines` + `idat` 组装）、`f_svg/src/SvgPngEncoder.cj:59-72`（`raw` 全量数组）、`f_svg/src/SvgPngEncoder.cj:92-105`（`writeChunk` 的 `crcInput` 全量拼接）
- **来源**：存量
- **判据**：review-checklist §5（一次性物化）、§7（删除中间副本）
- **证据**：静态确定（按公式可算）—— `raw = (4w+1)h ≈ 256 MiB`（64 Mi 像素）；`idat.write(deflated)` 再持有一份同量级压缩数据；`writeChunk` 里 `crcInput` 又把 `kind + data` 拼成第三份；`encode` 的 `output` ByteBuffer 是第四份。`SvgPngEncoder.encode` / `SvgBitmap.toPngBytes` 没有任何尺寸校验，只受 `SvgBitmap` 分配成功与否约束。
- **描述**：`write` 已经有 `OutputStream` 形态，但实现仍是"先造完整 raw、再造完整 IDAT、再拼 CRC 输入"，因此 `writePng(OutputStream)` 这条名义上的流式入口并没有降低峰值内存。对 4K×4K RGBA（67 MiB raw）尚可接受，对接近 `maxPixels` 的输出则会连续申请数份 256 MiB 级数组。
- **建议**：逐行生成 scanline → 直接 `compressor.write(row)`，同时增量更新 Adler-32（`first/second` 两个累加器即可，无需保留 `raw`）；CRC 用现成的增量接口 `SvgCrc32.update(0, kindBytes)` + `SvgCrc32.update(prev, data)` 两段计算（`SvgPngDecoder.cj:259` 已经这么用），删掉 `crcInput`。改完峰值从 `O(4wh)` 降到 `O(w)`。

### [一般][存量] #5 `SvgPathCommand` 不校验参数个数，光栅化直接下标访问 → 抛 `IndexOutOfBoundsException` 而非 `SvgException`

- **位置**：`f_svg/src/SvgRasterizer.cj:522`（`command.values[0]`，同类 `530` / `536-538` / `552-553` / `586-591`）；根因在 `f_svg/src/SvgPathData.cj:106`（`SvgPathCommand.init` 只赋值、不校验 `values.size == kind.arity()`，`arity()` 已存在于 `SvgPathData.cj:80`）
- **来源**：存量
- **判据**：review-checklist §11（错误处理缺失：非法输入应走模块约定的 `SvgException`/`SvgErrorKind`）、§14（契约未封闭）
- **证据**：静态确定 —— `SvgPathCommand` 的 `init` 是 `public` 且无长度校验，`SvgPathData(commands:)` 同样不校验；`flattenPathData` 对 `MoveTo` 无条件取 `values[0]`/`values[1]`。
- **描述**：`SvgPathData.parse` 产出的命令长度总是正确，所以解析路径安全；但 `SvgPathData(commands: [...])` 与 `SvgPathCommand(kind: .CurveTo, relative: false, values: [])` 都是公开构造入口，外部拼装路径数据后交给 `SvgRasterizer.fill` 会得到越界异常（非 `SvgException`，`SvgErrorKind` 契约被绕过），调用方无法按 `kind` 分流处理。
- **建议**：在 `SvgPathCommand.init` 里按 `kind.arity()` 校验并 `throw invalidValue(...)`（这是唯一能覆盖所有下游的落点）；若不便改构造，则在 `flattenPathData` 入口遍历一次按 `arity()` 校验后抛 `SvgException(kind: InvalidValue)`。

### [轻微][存量] #6 `SvgPngDecoder` 三处恒假分支 + 一处未使用 import

- **位置**：`f_svg/src/SvgPngDecoder.cj:251`（`length < 0`）、`f_svg/src/SvgPngDecoder.cj:99-104`（`pixels > SVG_MAX_IMAGE_PIXELS` 二次判断）、`f_svg/src/SvgPngDecoder.cj:136-140`（`bytesPerPixel < 1` 兜底）、`f_svg/src/SvgPngEncoder.cj:20`（`import fountain::f_base.*`）
- **来源**：存量
- **判据**：review-checklist §1（恒真恒假分支、未使用的 import）
- **证据**：静态确定 —— `readU32BE`（`604-607`）由 4 个 `Byte` 拼成 `Int64`，值域 `0..0xFFFFFFFF`，`length < 0` 恒假；`header.width > SVG_MAX_IMAGE_PIXELS / header.height`（91-92）已保证 `width × height ≤ 上限`（`height > 上限` 时右值为 0，任何 `width ≥ 1` 都会先抛），故 99 行恒假；`bytesPerPixel = (channels × bitDepth + 7) / 8`，而 `bitDepth ≥ 1` 已由 109 行的 `validateColorCombination` 保证，故 `< 1` 恒假。`SvgPngEncoder.cj` 全文件未使用 `f_base` 任何符号（`SvgBitmap`/`SvgCrc32` 均在 `f_svg` 内，`invalidValue` 未被调用）。
- **描述**：四处都是"看起来在防御、实际不会成立"的分支，读代码时会误导人以为还存在溢出/负长度窗口；未使用 import 属残留。
- **建议**：删除 251 行的负值判断、99-104 行的重复上限判断与 136-140 的兜底（或改注释说明由上游保证）；`import fountain::f_base.*` 建议在 WSL 构建确认后移除。

### [轻微][存量] #7 `SvgPngDecoder_test` 内构造后未读取的局部变量

- **位置**：`f_svg/src/SvgPngDecoder_test.cj:296-299`（`encoded` / `scanline`）、`f_svg/src/SvgPngDecoder_test.cj:320` 与 `332`（`pixelIndex`）
- **来源**：存量
- **判据**：review-checklist §1（读了不用）
- **证据**：静态确定 —— 第一段 `while`（290-302）的产物只有 `expected` 在 327-330 被断言使用，`encoded` 与 `scanline` 之后再无引用；`pixelIndex` 只做 `pixelIndex++`，从未参与断言。
- **描述**：`filterTypesRoundTrip` 的第一段循环实际只为了填 `expected`，却顺手算了一遍前向 filter 与 scanline 拼装（真正的拼装在 304-316 的第二段），是重复劳动 + 死变量；`pixelIndex` 纯噪声。测试仍然通过，但读者会以为第一段产物参与了校验。
- **建议**：第一段只保留 `expected` 的填充（或直接把它并入第二段循环），删掉 `encoded` / `scanline` 与 `pixelIndex`。

### [轻微][存量] #8 重复逻辑：Adler-32、PNG 签名、`maxInt64` / `maxFloat` 多份实现

- **位置**：`f_svg/src/SvgPngDecoder.cj:609` 与 `f_svg/src/SvgPngEncoder.cj:82`（`adler32` 逐行同构）；PNG 签名 `SvgPngEncoder.cj:22`、`SvgPngDecoder.cj:236`（另在 `SvgPngEncoder_test.cj` / `SvgPngDecoder_test.cj` 各 2 处字面量）；`SvgRasterizer.cj:489` 与 `SvgRenderTree.cj:1722`（`maxInt64`）；`SvgRasterizer.cj:731` 与 `SvgTimeline.cj:1213`（`maxFloat`）
- **来源**：存量
- **判据**：review-checklist §2（字面量复制 / 只改类型名）
- **证据**：静态确定 —— `grep "func adler32"` 在 `f_svg` 内 4 处（2 处生产 + 2 处测试），生产两处函数体逐行一致（65521 取模、`b * 65536 + a`）；签名数组 `[0x89,0x50,0x4E,0x47,...]` 共 5 处；`maxInt64` / `maxFloat` 各两份同实现（仅参数名不同）。
- **描述**：Adler-32 是编解码两侧必须完全一致的校验算法，两份实现任何一处被"顺手优化"（例如加 `%` 的合并技巧）都会让编码/解码互不兼容，属高风险重复；签名常量分 5 处同理。
- **建议**：把 `adler32`（含增量更新形态）与 `PNG_SIGNATURE` 提到 `f_svg/src` 内的共享 util（与 `SvgCrc32` 同级），编码器改用同一份；`maxInt64` / `maxFloat` 收敛为一份内部工具（放 `SvgValueTypes` 之类既有工具文件），或直接用 `std.math.max` 的重载（需先查签名确认）。

### [轻微][存量] #9 重复逻辑：合成循环、渐变描边轮廓化、`polygon` / `polyline` 整文件同构

- **位置**：`f_svg/src/SvgRasterizer.cj:366-387` 与 `399-415`（`compositeCoverageShader` / `compositeCoverage`）；`f_svg/src/SvgRasterizer.cj:139-159` 与 `243-262`（`stroke` / `strokeGradient` 的"扁平化 → 轮廓化 → 逐点变换"）；`f_svg/src/SvgPolygon.cj:19-38` 与 `f_svg/src/SvgPolyline.cj:19-38`
- **来源**：存量
- **判据**：review-checklist §2（换参数/换类型的同语义实现）
- **证据**：静态确定 —— 两个合成函数的循环体逐句一致（`count > 0` → `ratio = count/total` → `alpha > 0` → `bitmap.blend(SvgRgba.fromColor(...))`），唯一差异是颜色来自 `colorAt(x,y)` 还是常量 `color`；`stroke` 与 `strokeGradient` 的 139-150 与 243-254 都是 `matrixScale → userTolerance → flattenPathData(identity) → SvgStrokeStyle → outlineContours`，随后 `151-158` / `255-262` 都是同一段 `matrix.apply` 双循环；`SvgPolygon` / `SvgPolyline` 除构造参数 `"polygon"` / `"polyline"` 外完全相同。
- **描述**：三条都不是"错误"，但都是行为漂移的高发点：合成口径（覆盖率 → alpha → 预乘 over）一旦改动要同时改两处，漏一处就是渐变与纯色着色不一致；描边轮廓化两侧的容差/变换顺序同理；`points` 属性的缓存失效逻辑（`pointsCache` + `attributesVersion`）也是两份。
- **建议**：合成合并为 `compositeCoverage(coverage, opacity, colorAt: (Int64, Int64) -> SvgColor)`，纯色调用方传常量闭包（注意保留现有 `x/y` 计算顺序，验证逐像素等价）；描边前处理抽成 `buildDeviceOutline(path, matrix, strokeWidth, ..., tolerance) -> Array<Array<SvgPoint>>`；`SvgPolygon` / `SvgPolyline` 合并到同一个 `internal` 基类（tag 由 `init` 传入），或至少让 `pub` 属性实现共用一处（差异只有元素名，没有业务语义差异）。

### [轻微][存量] #10 可读性：`deviceContours` 实为用户坐标；预算错误消息硬编码全局上限

- **位置**：`f_svg/src/SvgRasterizer.cj:150`（`let deviceContours = SvgStrokeOutliner.outlineContours(userContours, style)`）、`f_svg/src/SvgPngDecoder.cj:46`（`SvgDecodeBudget.consume` 的消息）
- **来源**：存量
- **判据**：review-checklist §10（命名与实际语义不符）、§11（语义与注释/契约不符）
- **证据**：静态确定 —— 150 行拿到的是 `userContours`（141 行以 `SvgMatrix.identity` 扁平化）的轮廓化结果，真正转到设备坐标发生在 152-158 的循环里，名字与内容相反；`SvgDecodeBudget.init` 接受任意 `total`（测试里用 `1` / `4` / `1024`），但 44-48 行的超限消息固定打印 `SVG_MAX_RENDER_DECODE_PIXELS`（64 Mi），与实际预算不符。
- **描述**：前者容易让后续维护者误以为 156 行的 `matrix.apply` 是重复变换而删掉；后者会让调用方看到"超过上限 67108864"却只申请了 1024 的困惑日志，排查时被带偏。
- **建议**：150 行改名 `userOutlines`（`strokeGradient` 的 254 行 `outlines` 已是正确命名）；`SvgDecodeBudget` 增加 `total` 字段并在消息里打印 `this.total`（或在 `consume` 里打印剩余量），保留全局上限只在 `SvgRenderer` 构造预算处体现。

## 优化可行性方案

> 均无改前/改后对照数据，按铁律标 `无基线（待验证）`，不进 `todo.md` / `tasks.md`。

### [堆内存] PNG 解码改为逐 chunk 消费，去掉 IDAT 全量拼接与整文件读入

- **现状**：`decode(stream)`（`SvgPngDecoder.cj:69-86`）先把整条流读进 `ByteBuffer`（上限 64 MiB），再 `decode(out.bytes())`；`readHeaderChunks`（`243`）用 `idat` 再攒一份完整 IDAT，末尾 `idat.bytes()` 交给 `inflateZlib`，后者又 `compressed[2..size-4]` 复制一份 payload。16 Mi 像素图的最坏组合约为：流缓冲 64 MiB + IDAT 缓冲 64 MiB + payload 64 MiB + 解压输出 64 MiB + 位图 64 MiB。
- **方案**：给 `readHeaderChunks` 加一个"IDAT 直接喂 `DecompressInputStream`"的路径（边读 chunk 边解压到 `ByteBuffer`），或至少让 `inflateZlib` 接受 `ByteBuffer` + 起止偏移，避免 `payload` 切片复制；`decode(stream)` 侧改为增量喂给 chunk 解析器。
- **预期**：峰值从"4 份输入量级"降到"1 份输入 + 1 份输出"，按 16 Mi 像素上限估算约降 120–190 MiB；具体数值需实测。
- **代价**：chunk 状态机与解压器耦合度上升，需要保留"CRC 先校验后解压"的现有语义（否则会先解压坏数据）；改动面在私有函数，不影响公开签名。
- **验证**：同一组 PNG（1×1 / 8×8 / 2048×2048 / Adam7）跑 `getAllocatedHeapSize()` + RSS 峰值对照，并保持 `SvgPngDecoder_test.cj` 全绿（尤其 `chunkStateMachine` 的 CRC 与截断用例）。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `readPixel` 每像素分配 4 字节数组

- **现状**：`SvgPngDecoder.cj:525` 每个像素 `Array<Byte>(4, repeat: 0)`，由 `writeScanline`（`502-512`）逐列调用。16 Mi 像素单图 = 16 Mi 次小数组分配，全部短命，只用于把 4 个通道搬到 `bitmap.pixels`。
- **方案**：改成 `readPixel(row, column, ..., out: Array<Byte>, outOffset: Int64)` 直接写入 `bitmap.pixels` 的 `base..base+4`；或让 `writeScanline` 内联 5 种 colorType 的写入分支（`palette` / `tRNS` 查找保持原样）。
- **预期**：单图少 16 Mi 次分配与 64 MiB 分配量，GC 次数与解码耗时下降；降幅需实测（无 profile 数据）。
- **代价**：`readPixel` 变成带外写参数的私有函数，可读性略降；需逐 colorType 保持现有 tRNS / 调色板越界语义（`558-560` 的 `Syntax`）。
- **验证**：`cjpm bench -O2` 对比 4096×4096 RGBA / 调色板 / 灰度 4-bit 三种输入的解码中位数（≥5 轮），同时比对 `SvgPngDecoder_test` 的逐像素断言。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 覆盖率收集：每子扫描线新建容器 + 全量扫边

- **现状**：`computeCoverage`（`318-334`）对每个 `row × samples` 调 `collectHits`（`441`），后者 `new ArrayList<SvgEdgeHit>()` 并遍历**全部** edges，随后 `nonzeroSpans` / `evenOddSpans` 再各建一个 `ArrayList<SvgSpan>`；`sortHits`（`451`）是插入排序。复杂路径（edges 数百、画布上千行）下是 `O(rows × samples × edges)` 次求交 + 每子扫描线 2 个容器分配。
- **方案**：按行维护活动边表（edges 先按 `yMin` 排序，逐行进出），`hits` / `spans` 用复用的 `ArrayList`（`clear()` 后重用，注意 `clear()` 不还物理内存，但避免了反复扩容）；`sortHits` 在 hits 较少时保留插入排序，超过阈值换 `sort`。
- **预期**：求交次数从 `rows × edges` 降到"活动边数 × rows"；分配次数从 `2 × rows × samples` 降到 2。具体收益需 `cjprof` 自耗时占比支撑。
- **代价**：活动边表需要正确的增删边界（`y >= yMin && y < yMax` 的半开区间语义，`444`），改错会直接改变覆盖率；插入排序换 `sort` 需保证相等 x 的相对顺序不影响 winding 计算（`nonzeroSpans` 依赖同 x 事件的次序）。
- **验证**：`cjprof record` 跑 1000 条边的合成路径（画布 1024×1024、samples=4），看 `collectHits` / `sortHits` 自耗时占比；改后用 `SvgRasterizer_test.cj` 全部覆盖率断言 + 随机路径逐像素 diff。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 合成阶段每像素两次整数除法

- **现状**：`compositeCoverage`（`408-409`）与 `compositeCoverageShader`（`376-377`）用 `index % width` / `index / width` 反算 `(x, y)`；`coverage.size = width × height`，满配画布 64 Mi 像素即 128 Mi 次整数除法，而循环本身已是线性扫描。
- **方案**：改成嵌套 `for (y in 0..height) { for (x in 0..width) { index++ } }`，行首计算一次 `rowBase`，`x` 直接是内层变量；`compositeCoverageShader` 里的 `colorAt(x, y)` 顺带省掉取模。
- **预期**：去掉 2 次除法/像素；按 64 Mi 像素估算约 1–3 % 端到端（按典型整数除法 20–40 cycle 粗算），需实测确认是否超过噪声。
- **代价**：几乎为零（循环结构等价，索引顺序不变）；需保持 `count > 0` 提前跳过与 `alpha > 0` 的判断顺序。
- **验证**：`cjpm bench -O2` 同输入对照 `SvgBitmap` 输出逐像素一致；`cjprof` 看除法是否仍在热点。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `computeCoverage` 的 `rows × samples × edges` 全量扫边是渲染热点（自耗时占比未知） | `f_svg/src/SvgRasterizer.cj:318-334` | 自耗时占比、调用路径、输入规模 | `cjprof record` 渲染含 500 / 2000 条边路径的 1024×1024 图，samples=4 |
| 2 | `sortHits` 插入排序在 edges > 500 时成为行内瓶颈 | `f_svg/src/SvgRasterizer.cj:451-463` | 单行 hits 数量分布与排序耗时 | 在 `sortHits` 前后加分段计时，跑复杂路径 1 万次取中位数 |
| 3 | `subdivideCubic` 深度上限 16 在极端缩放下产生 ~65k 点/段，扁平化内存被放大 | `f_svg/src/SvgRasterizer.cj:686-707`（上限 `695`） | 实际深度分布、单条 `C` 命令产出的点数 | 用 `matrix=scale(1e6)` + 高曲率三次曲线压测，统计 `flattenCubicPolyline` 返回点数与耗时 |
| 4 | PNG 编码的 deflate 与 Adler-32 双遍扫描（raw 读两遍 + CRC 再一遍）占编码耗时主要部分 | `f_svg/src/SvgPngEncoder.cj:44-52` | 各阶段耗时占比 | 分段计时 `buildRawScanlines` / `deflateBytes` / `adler32` / `writeChunk`，输入 4096×4096 RGBA，-O2，10 轮中位数 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_svg/src/SvgPelicanBikeM7_test.cj` | .cj | ✅ | 故事动图 golden 测试；golden 文件 `testdata/story/pelican-{weather,beach-weather}.svg` 存在 |
| 2 | `f_svg/src/SvgPerfM5_test.cj` | .cj | ✅ | 只打印 `M5_PERF`，无门禁；不构成性能基线 |
| 3 | `f_svg/src/SvgPngDecoder.cj` | .cj | ✅ | 见 #6（恒假分支与未使用 import）、#10（预算消息）、优化方案「readPixel 每像素分配」 |
| 4 | `f_svg/src/SvgPngDecoder_test.cj` | .cj | ✅ | 覆盖 IHDR/CRC/Adam7/filter/tRNS/上限；见 #7 死变量 |
| 5 | `f_svg/src/SvgPngEncoder.cj` | .cj | ✅ | 见 #4（内存放大）、#6（未使用 import）、#8（adler32 重复） |
| 6 | `f_svg/src/SvgPngEncoder_test.cj` | .cj | ✅ | 结构/IDAT/往返/确定性/CRC/文件输出；`/tmp` 路径依赖 WSL |
| 7 | `f_svg/src/SvgPointList.cj` | .cj | ✅ | 奇数个数字抛 `invalidValue`；无边界问题 |
| 8 | `f_svg/src/SvgPointerEvents.cj` | .cj | ✅ | 11 个取值解析/序列化对称 |
| 9 | `f_svg/src/SvgPointerEventsM6_test.cj` | .cj | ✅ | 大小写、空白、未知值、相等语义 |
| 10 | `f_svg/src/SvgPolygon.cj` | .cj | ✅ | 与 `SvgPolyline` 同构，见 #9 |
| 11 | `f_svg/src/SvgPolyline.cj` | .cj | ✅ | 同上 |
| 12 | `f_svg/src/SvgPreserveAspectRatio.cj` | .cj | ✅ | `toMatrix` 变换顺序符合 1.1 算法；退化视口抛 `InvalidValue` |
| 13 | `f_svg/src/SvgPreserveAspectRatio_test.cj` | .cj | ✅ | 九对齐/meet/slice/none/退化输入全覆盖 |
| 14 | `f_svg/src/SvgRadialGradient.cj` | .cj | ✅ | 5 个长度属性 + 版本缓存，无死代码 |
| 15 | `f_svg/src/SvgRasterizer.cj` | .cj | ✅ | 见 #1、#2、#3、#5、#9、#10 |
| 16 | `f_svg/src/SvgRasterizer_test.cj` | .cj | ✅ | 覆盖规则/边界/AA/合成/扁平化误差/设备矩阵 |
| 17 | `f_svg/src/SvgRect.cj` | .cj | ✅ | 6 个长度属性 + 版本缓存，无死代码 |
| 18 | `f_svg/src/SvgRenderGuard.cj` | .cj | ✅ | `enter`/`leave` 在 `SvgPatternSampler`、`SvgRenderTree` 均有调用 |
| 19 | `f_svg/src/SvgRenderOptionsM4_test.cj` | .cj | ✅ | 默认值/既有命名参数/自定义 languages |

合计：`.cj` 19 个 / `.md` 0 个 / 共 19 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 4 | 正确性 3（#1 覆盖率分母、#2 隐藏状态、#5 参数个数未校验）、可读性 1（#10）；安全性 0：本部分无字符串拼 XML、无外部文本进日志（PNG 编解码只处理二进制，`SvgPointList.toString` 只输出数字） |
| §1 死代码 | 2 | 逐符号搜引用：`SvgRasterizer` 的 `maxInt64`/`minInt64`/`maxFloat`/`distance`/`midpoint`/`matrixScale`/`SvgRasterEdge`/`SvgSpan` 均有调用，`flattenCubicPolyline`/`SvgRenderGuard.enter|leave`/`svgRenderGuardLabel` 在 `SvgPatternSampler`、`SvgRenderTree`、测试中有调用，`SvgPreserveAspectRatio.isXMin/isYMax` 等在 `SvgFilterPrimitives2`、`SvgRenderer` 有调用；命中为三处恒假分支 + encoder 未使用 import（#6）与测试死变量（#7），无「非 public 符号零引用」的情形，public 声明按对外可达不判 |
| §2 重复逻辑 | 2 | 生产侧逐函数体比对：`adler32`×2、签名×5、`maxInt64`×2、`maxFloat`×2（#8）；合成循环、描边轮廓化、`polygon`/`polyline` 整文件（#9）。测试侧的 `pngPaeth`/`pngForwardFilter`/`pngAdler32` 与被测实现同构，属刻意的往返校验，不计 |
| §3 空实现 | 0 | 逐个函数体检查：无 `{}`、无 `TODO`/`FIXME`、无 `catch {}`；`decodeAdam7` 的 `continue` 是 pass 跳过而非空实现；`SvgDimension` 类属性 getter 均有实现 |
| §4 栈溢出 | 0 | 唯一递归是 `subdivideCubic`（`686`），出口由 `depth >= 16` 硬限（`695`），最多 16 层帧；`flattenPathData`/`decodeAdam7`/`arcPolyline` 都是迭代；点在 `SvgRasterizer.cj:705-706` 两路递归深度相同，不存在间接递归与环 |
| §5 OOM | 2 | `SvgRasterizer` 覆盖率按画布 8 B/px（#3）、`SvgPngEncoder` 3–4 份 4wh 缓冲（#4）；解码侧有 16/64 Mi 像素与 64 MiB 流上限两条拒绝路径，未单列 |
| §6.1 热点瓶颈 | 0 | 本部分唯一"性能资料"是 `SvgPerfM5_test` 的 `println`（无门禁、无对照），无 `cjprof` / `cjpm bench` 数据；所有热点判断已降级到「待验证假设」1–4 |
| §6.2 大粒度锁 | 0 | 本部分无锁、无 `synchronized`、无并发容器（PNG 编解码为纯静态函数，光栅器为单实例顺序调用） |
| §6.3 并发串行 | 0 | 无 `spawn`/`Future`/线程池，不存在形式并发 |
| §6.4 低效算法 | 1 | `computeCoverage` 全量扫边 + 每子扫描线容器分配（优化方案 3，已按"无基线"处理，未计为缺陷）；`sortHits` 插入排序列入假设 2 |
| §7 降堆内存方案 | 1 | 解码侧流式化（去掉整文件读入 + IDAT 全量拼接）；覆盖率缓冲 bbox 化已作为 #3 的修法写进发现，不在方案节重复计数；编码器流式化同理并入 #4 |
| §8 降 CPU 方案 | 3 | `readPixel` 每像素分配、覆盖率收集容器与扫边、合成阶段整数除法 |
| §9 local mode 可行性 | 1 | `computeCoverage` 的 `Array<Int64>(width*height)` 是函数内创建、随 `compositeCoverage` 用完后即弃的非逃逸对象，与 `SvgAnalyticRasterizer.cj:79-101` 已落地的 `ANALYTIC_LOCAL_ACCUMULATOR_*`（8 MiB 上限、`analyticUsesLocalAccumulator` 阈值判断）同型；本部分未改，收益只能用峰值内存对照证明，故不写成方案，只作可行性记录 |
| §11 现有代码的 BUG（存量） | 5 | 本部分读到的 5 个缺陷（#1–#5）全部为存量；另核对边界：`readSample` 位偏移（1/2/4 bit 的 `shift` 与 `mask` 在 0..7 内成立）、`writeScanline` 的 `base+3` 不越界（`x < width`、`y < height` 由 `passWidth/passHeight` 保证）、`reverseFilter` 的 `previous[index]` 与 `encoded` 等长、`arcPolyline` 的 `lambda>1` 半径缩放与 `segments` 上限 256，均无缺陷 |
| §12 并发安全与锁粒度 | 1 | `SvgRasterizer` 的 `aaDisabled`/`toleranceScale` 是可变字段，仓内 9 处创建点（`SvgRenderer:423/552/596/650/921`、`SvgClipMask:370/399/609`、`SvgClipProperty:141`）全部是每次调用新建、随即丢弃 ⇒ 线程封闭，无共享路径；`SvgPngDecoder`/`SvgPngEncoder` 无静态可变状态；`SvgElement.nextIdentity` 用 `fetchAdd`。字段跨调用存活引发的错误见 #2，属正确性而非数据竞争 |
| §14 功能完备性与 README 覆盖 | 0 | 本部分无 `.md` 文件，#13/#14 由模块其余部分承担；本部分新增的公开面（`SvgPngDecoder.decode(stream)`、`SvgRasterizer.fillGradient/strokeGradient`、`SvgPointerEvents`）是否进 README，需在合并阶段对照模块 README 统一核对——此处不单独判定 |
| 文件覆盖（§13 等） | 19/19 | 无缺失；本部分不含 `.md`，§13 文档一致性不适用 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 1 |
| 一般 | 4 |
| 轻微 | 5 |
| 优化方案（堆内存 / CPU） | 1 / 3 |

存量缺陷 10 条（严重 1 / 一般 4 / 轻微 5），是否纳入修复待用户决定。

## 总评

本部分的工程质量在"防御式解析"上做得扎实：PNG chunk 状态机把签名、IHDR 首个且唯一、PLTE/tRNS 位置与长度、IDAT 连续性、CRC、解压长度、Adler-32 全部校验到位，并且有专门的 `SvgPngStructureM3_test` / `SvgPngChunkErrorM3_test` 覆盖；像素上限用"先除后乘"避免溢出，`SvgDecodeBudget` 在分配位图前扣减，`SvgRasterizer` 的 `subdivideCubic` 有显式深度上限——栈溢出与解析注入两条线均未发现缺陷。

主要风险集中在**采样开关的状态语义**与**按画布规模分配缓冲**两处：

1. `aaDisabled` 与 Analytic 模式两条分支互不知情（#1，严重）——`shape-rendering: crispEdges` 是常见样式，只要使用者选了 `antiAlias: Analytic`，边缘就会整体饱和外扩，且现有测试没有任何交叉组合能发现它。这是本部分唯一的阻塞项，建议优先修，并补一条 `Analytic + antiAliasOverride: Some(false)` 的像素断言。
2. `SvgRasterizer` 的 `aaDisabled`/`toleranceScale` 作为跨调用存活的字段（#2）会让 Gradient 入口继承上一次调用的状态；仓内因为"每个 paint 新建实例"而未暴露，但公开类一旦被复用就会出现难查的渲染差异，属于排期内的低风险修复（改成参数传递）。
3. 内存侧：覆盖率按整幅画布 8 B/px（#3）、编码器 3–4 份 4wh 缓冲（#4）都还没有触发 OOM 的证据，但按默认 `maxPixels = 64 Mi` 推导，单次可达 512 MiB / ~1 GiB 量级；两者都有"按行/按 bbox"的成熟修法，适合与渲染性能优化一起排期，并以 RSS 峰值对照验收。
4. 轻微项以死分支、测试死变量、无基线优化为主，可随手清理；`adler32` 与 PNG 签名各有多份副本，虽不影响当前行为，但属于"改动一处另一处不同步就会破坏互操作"的高风险重复，建议收敛到共享 util。
