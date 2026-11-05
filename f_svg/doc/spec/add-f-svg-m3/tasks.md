# 任务：add-f-svg-m3

> 每个任务按 Red-Green-Refactor 推进：先写失败用例并确认失败原因正确，再写最小实现，最后重构。
> 每个阶段结束 `cjpm test` 必须全绿；每个阶段独立提交，全部工作位于 `feature/f-svg-m3` 分支。
> M3 只增不改 M1/M2 公开 API；不新增模块、子包或第三方依赖；不改根 `cjpm.toml`、`.modules` 与聚合根 shim。

## 1. 准备与基线

- [x] 1.1 从当前 `f_svg` 工作分支切出 `feature/f-svg-m3`，确认工作区干净
- [x] 1.2 运行 `cjpm test`，记录基线（当前实测 348 条用例：348 个 `@TestCase` + 53 个 `@Test` 类标注）、耗时与零失败
- [x] 1.3 通读 `f_svg/doc/f_svg-M3设计.md` 与本变更 `proposal.md` / `design.md` / `specs/`，确认实现顺序与边界
- [x] 1.4 新建空实现骨架（仅包声明与 `TODO`）：`SvgFilter.cj`、`SvgFilterPrimitive.cj`、`SvgFilterRenderer.cj`、`SvgFilterBuffer.cj`、`SvgPattern.cj`、`SvgPatternSampler.cj`、`SvgPngDecoder.cj`、`SvgImageResource.cj`、`SvgGzip.cj`、`SvgTextPathLayout.cj`、`SvgMarker.cj`、`SvgMarkerExpander.cj`、`SvgAnalyticRasterizer.cj`
- [x] 1.5 确认所有文件位于 `f_svg/src` 单包，`cjpm build` 通过
- [x] 1.6 建立 `testdata/render/m3-*` 场景目录与负向 fixture 目录，先只放占位说明

## 2. 值类型、选项与 CSS 属性（M3-9 前置）

- [x] 2.1 先写 `SvgValueTypesM3_test.cj`：七个新枚举的解析、`toString`、未知值回退 warning
- [x] 2.2 实现 `SvgAntiAliasMode` / `SvgBlendMode` / `SvgCompositeOperator` / `SvgColorMatrixType` / `SvgMarkerUnits` / `SvgMarkerOrient` / `SvgImageRendering`
- [x] 2.3 先写 `SvgNumberList` 补充用例：单值 / 双值 / 负值 / 非有限值
- [x] 2.4 先写 `SvgRenderOptions` 用例：`images == None`、`antiAlias == Supersample`、既有字段默认值不变、既有构造调用编译通过
- [x] 2.5 在 `SvgBitmap.cj` 为 `SvgRenderOptions` 增加 `images` / `antiAlias` 带默认值字段
- [x] 2.6 先写 `SvgComputedStyle_test` 的 `image-rendering` 用例：初始值、继承、内联覆盖、非法值 warning
- [x] 2.7 在 `SvgComputedStyle` 属性表注册 `image-rendering` 并实现取值归一化
- [x] 2.8 先写 `SvgSecurityOptions` 用例：`maxDecompressedBytes` 默认 64 MiB、负值抛 `InvalidValue`
- [x] 2.9 在 `SvgOptions.cj` 增加 `maxDecompressedBytes` 带默认值字段

## 3. 类型化元素与往返（M3-1/2/3/8 模型）

- [x] 3.1 先写 `SvgFilter_test.cj`：`filter` 映射、区域属性默认值、`primitives` 顺序
- [x] 3.2 先写八个 `fe*` 的属性用例：`stdDeviation`、`dx/dy`、`flood-color/opacity`、`in2/mode`、`operator/k1-k4`、`feMergeNode`、`matrixType/values`、`feTile`
- [x] 3.3 先写 `SvgPattern_test.cj`：属性默认值、`href` 读写、`is SvgContainer` 与 `kind == Pattern`
- [x] 3.4 先写 `SvgMarker_test.cj`：属性默认值、`kind == Marker`、`orient` 三种形式
- [x] 3.5 实现 `SvgFilter` / `SvgFilterPrimitive` / 八个 `SvgFe*` / `SvgFeMergeNode`
- [x] 3.6 实现 `SvgPattern` / `SvgMarker`（继承 `SvgContainer`，构造传入既有 kind）
- [x] 3.7 扩展 `SvgTag.create` / `isKnown` 与 `SvgBuilder` 白名单；非 `fe*` 子元素告警
- [x] 3.8 先写 `SvgRoundTrip_test` 增量用例：filter / pattern / marker / fe* 的标签、属性、子节点顺序往返
- [x] 3.9 实现生成侧标签与属性回写；确认 `SvgContainerKind` 枚举值未变
- [x] 3.10 先写 `textPath` 的 `path` 属性读写用例（模型层），补齐 `SvgTextPath.path`

## 4. SVGZ 容器（M3-6）

- [x] 4.1 先写 `SvgGzip_test.cj`：`parseAuto` 纯文本与 gzip 结果一致、`parseGzip` 强制解压
- [x] 4.2 先写负向用例：非 gzip 输入、截断 gzip、损坏 CRC、解压输出超 `maxDecompressedBytes`
- [x] 4.3 先写 `writeGzip` 往返与字节确定性用例（连续两次相等、mtime 为 0）
- [x] 4.4 实现 `SvgGzip`：gzip 解压 / 压缩、输出上限计数、mtime 固定
- [x] 4.5 在 `SvgParser` 增加 `parseAuto` / `parseGzip` 静态入口，复用既有解析与安全上限
- [x] 4.6 实现顶层 `writeGzip(document)`，复用 `writeSvgString`
- [x] 4.7 先写「解压后仍受元素数 / 深度上限约束」用例并确认通过

## 5. PNG 解码（M3-4）

- [x] 5.1 先写 `SvgPngDecoder_test.cj`：最小 1×1 RGBA、签名校验、IHDR 字段校验
- [x] 5.2 先写六类变体用例：灰度、灰度+α、RGB、RGBA、调色板、Adam7
- [x] 5.3 先写 filter 0–4 逐行逆运算用例，覆盖 Sub / Up / Average / Paeth
- [x] 5.4 先写 `tRNS`、1/2/4-bit 展开、调色板越界用例
- [x] 5.5 实现 chunk 状态机：签名、长度、CRC、`IHDR`、`IDAT` 连续性、`IEND`
- [x] 5.6 实现 `IDAT` 解压与行长校验，复用 `stdx.compress.zlib.DecompressInputStream`
- [x] 5.7 实现反 filter 与 Adam7 七 pass 写入
- [x] 5.8 实现错误语义：`Syntax` / `InvalidValue` / `Limit`，确认无裸异常
- [x] 5.9 先写下限用例：单图像素上限、总解码像素计数、超大 IHDR 在解压前抛 `Limit`
- [x] 5.10 先写编码 → 解码回环用例（复用 `SvgBitmap.toPngBytes`），确认 RGBA 与全透明像素一致

## 6. `<image>` 绘制与资源提供者（M3-5）

- [x] 6.1 先写 `SvgImageResource_test.cj`：`SvgImageResourceProvider` 接口、data URI 解析、base64 校验与上限
- [x] 6.2 先写 `SvgRenderer_test` 增量用例：data URI 绘制、provider 绘制、未注入占位 warning
- [x] 6.3 先写 `preserveAspectRatio` 三档映射用例：`none` / `meet` / `slice`
- [x] 6.4 先写 `image-rendering` 两档取样用例：`pixelated` 与 `auto`
- [x] 6.5 实现 `SvgImageResource`：data URI 解析、base64 解码、provider 调用与单次渲染缓存
- [x] 6.6 在渲染树中把 `<image>` 从占位改为「资源 → 解码 → 映射 → 绘制」，失败回退占位
- [x] 6.7 实现双线性 / 最近邻取样，确认 `opacity` / `clipPath` / `mask` / `filter` 生效（通用图层路径 + `SvgRenderer_test` 覆盖）
- [x] 6.8 先写缓存用例：同一 `href` 多次引用只解码一次，跨 `render` 不共享
- [x] 6.9 先写累计解码像素超限用例，确认抛 `Limit`

## 7. 图案平铺（M3-3）

- [x] 7.1 先写 `SvgPatternSampler_test.cj`：20×20 tile 平铺 100×100，四角颜色正确
- [x] 7.2 先写 `patternUnits` / `patternContentUnits` 的尺寸换算用例
- [x] 7.3 先写 `patternTransform` 旋转 45° 与缩放用例
- [x] 7.4 先写 `href` 继承、循环引用 warning、自身属性优先用例
- [x] 7.5 先写空 tile、负尺寸 tile、超大 tile 用例
- [x] 7.6 实现 `SvgPattern` 的继承链解析与 tile 尺寸计算
- [x] 7.7 实现 tile 离屏渲染（复用渲染树 / 光栅器）与单次渲染内缓存
- [x] 7.8 把图案接入 `fill` / `stroke` 的画笔解析与 `fillContoursShader` 平铺取样
- [x] 7.9 先写「图案裁剪到填充区域」用例，确认圆外无图案像素
- [x] 7.10 先写 pattern 子内容渲染失败降级用例

## 8. 滤镜框架（M3-1）

- [x] 8.1 先写 `SvgFilterBuffer_test.cj`：RGBA8 非预乘、尺寸与索引、区域外透明
- [x] 8.2 先写 `SvgFilterRenderer_test.cj`：滤镜区域换算（两种 units）、区域裁剪到画布
- [x] 8.3 先写图连接用例：首个原语默认 `SourceGraphic`、链式 `result`、`in2` 默认、未定义引用 warning
- [x] 8.4 先写空滤镜链直通、`linearRGB` 往返转换、输出确定性用例
- [x] 8.5 实现 `SvgFilterBuffer` 与区域计算（`maxPixels` 先检查后分配）
- [x] 8.6 实现 `SvgFilterRenderer.apply` 的缓冲调度、隐式命名与 warning 收集
- [x] 8.7 把滤镜接入渲染树：元素内容 → filter → clip/mask/opacity 的固定顺序
- [x] 8.8 先写滤镜区域超限、缺失 filter 引用用例

## 9. 滤镜原语（M3-2）

- [x] 9.1 先写 `feGaussianBlur` 用例：单值 / 双值、σ=0 直通、脉冲扩散对称
- [x] 9.2 实现可分离高斯卷积，核半径 `ceil(3σ)`
- [x] 9.3 先写 `feOffset` 正负偏移与越界补透明用例
- [x] 9.4 实现 `feOffset`
- [x] 9.5 先写 `feFlood` 颜色 × 不透明度、`feBlend` 五种模式（含 normal = over）用例
- [x] 9.6 实现 `feFlood` / `feBlend`
- [x] 9.7 先写 `feComposite` 五种 Porter-Duff 与 arithmetic 钳制用例
- [x] 9.8 实现 `feComposite`
- [x] 9.9 先写 `feMerge` 顺序与缺省输入用例
- [x] 9.10 实现 `feMerge`（按 `feMergeNode` 顺序 over）
- [x] 9.11 先写 `feColorMatrix` 四种类型、值个数不符、结果钳制用例
- [x] 9.12 实现 `feColorMatrix`
- [x] 9.13 先写 `feTile` 周期平铺、零尺寸输入用例
- [x] 9.14 实现 `feTile`
- [x] 9.15 先写 blur + offset + merge 的 golden 用例

## 10. textPath 与 rotate（M3-7）

- [x] 10.1 先写 `SvgTextPathLayout_test.cj`：水平路径上的字形落位与切线角
- [x] 10.2 先写 `startOffset` 长度 / 百分比、负值 / 超长钳制用例
- [x] 10.3 先写 `text-anchor` 三档起点调整用例
- [x] 10.4 先写路径短于文本的截断 warning 用例
- [x] 10.5 先写 `href` 缺失、指向不存在元素、路径为空的降级用例
- [x] 10.6 实现 `SvgTextPathLayout`（复用 `SvgPathData` 扁平化与弧长采样）
- [x] 10.7 在 `SvgTextRenderer` 中接入 textPath：字形落位 + 切线旋转
- [x] 10.8 先写 `rotate` 单值 / 列表 / 短列表复用 / 与 textPath 叠加用例
- [x] 10.9 实现 `rotate` 列表消费与非法值 warning
- [x] 10.10 先写「textPath 降级不影响其他文本」用例

## 11. marker（M3-8）

- [x] 11.1 先写 `SvgMarkerExpander_test.cj`：path / line / polyline / polygon 的 start / mid / end 派生
- [x] 11.2 先写闭合路径首末重合不重复派生用例
- [x] 11.3 先写 `refX` / `refY` 对齐、`markerUnits` 缩放、`viewBox` 映射用例
- [x] 11.4 先写 `orient` 三种形式用例：auto、auto-start-reverse、固定角度
- [x] 11.5 实现顶点提取与 marker 实例派生
- [x] 11.6 实现实例变换：单位缩放 × 对齐 × 朝向 × 内容矩阵
- [x] 11.7 把 marker 子树接入渲染树，确认 `clipPath` / `mask` / `filter` 生效
- [x] 11.8 先写 1024 上限截断、缺失引用、引用深度 64 用例
- [x] 11.9 实现数量与深度上限

## 12. 解析覆盖率 AA（M3-9）

- [x] 12.1 先写 `SvgAnalyticRasterizer_test.cj`：45° 斜线相邻像素覆盖率和 ≈ 1（误差 ≤ 1/255）
- [x] 12.2 先写圆与 4× 超采样的通道差 ≤ 2/255 用例
- [x] 12.3 先写自交路径 nonzero / evenodd 两例
- [x] 12.4 实现有符号面积累加与像素覆盖率缓冲
- [x] 12.5 实现 nonzero / evenodd 内外判定，确认面积不参与内外规则
- [x] 12.6 在 `SvgRasterizer` / `SvgRenderer` 按 `antiAlias` 分派，默认路径不变
- [x] 12.7 先写与描边、渐变、图案、滤镜、marker、裁剪、蒙版组合的确定性用例
- [x] 12.8 先写 `antiAlias = Analytic` 时 `samplesPerPixel` 不参与计算的用例

## 13. 上限与负向用例补齐

- [x] 13.1 按 `verification.md` §2.2 的判定列记录上限负向用例；未覆盖项列入已知限制
- [x] 13.2 确认单图像素、总解码像素、base64、gzip、滤镜区域、tile、引用深度均在分配前失败
- [x] 13.3 确认 marker 超限为 warning 截断而非异常
- [x] 13.4 确认 pattern / marker / gradient 循环引用只 warning 不递归
- [x] 13.5 确认所有 warning 含可定位信息，`SvgRenderer.warnings` 可审计

## 14. 场景快照与性能基准（M3-10）

- [x] 14.1 新增 `testdata/render/m3-filter.svg` 与期望图（blur + offset + merge）
- [x] 14.2 新增 `testdata/render/m3-pattern.svg` 与期望图（tile + patternTransform）
- [x] 14.3 新增 `testdata/render/m3-image.svg` 与期望图（data URI + meet/slice）
- [x] 14.4 新增 `testdata/render/m3-textpath.svg` 与期望图（textPath + rotate）
- [x] 14.5 新增 `testdata/render/m3-marker.svg` 与期望图（start/mid/end + orient）
- [x] 14.6 扩展 `SvgScene_test.cj`：逐像素比较、容差 ≤ 1、失败输出首个差异坐标与像素值
- [x] 14.7 新增基准：512×512 高斯模糊、512×512 图案平铺、1024×1024 解析 AA 圆
- [x] 14.8 把实测记录到 `f_svg/doc/perf-baseline.md`，标注「参考、非门禁」

## 15. 文档、验收与提交

- [x] 15.1 更新 `f_svg/src/f_svg.cj` 包注释为 M3 能力概述
- [x] 15.2 更新 `f_svg/README.md`：M3 能力表、滤镜 / 图案 / 位图 / SVGZ / textPath / marker / AA 示例、`SvgImageResourceProvider` 安全边界
- [x] 15.3 更新 `f_svg/README_en.md`，与中文 README 对齐
- [x] 15.4 核对 README、`doc/f_svg模块设计.md`、`doc/f_svg-M3设计.md` 与公开 API 一致
- [x] 15.5 运行 `cjpm build`，确认 `f_svg` 自身 0 warning
- [x] 15.6 运行 `cjpm test`，确认 M1/M2 基线零回归、M3 新增用例全绿
- [x] 15.7 按 `verification.md` §2.2 的判定列记录 Scenario 映射；未覆盖项列入已知限制
- [x] 15.8 确认未新增模块 / 依赖，`cjpm.toml`、根 `cjpm.toml`、`.modules` 无改动
- [ ] 15.9 按 `AGENTS.md` 在 `feature/f-svg-m3` 分阶段提交，最后 `git merge --no-ff` 回上游并删除分支
- [ ] 15.10 归档本变更：`/opsx:archive add-f-svg-m3`
