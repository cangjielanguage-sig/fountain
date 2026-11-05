# 任务：add-f-svg-m2

> 每个任务按 Red-Green-Refactor 推进：先写失败用例并确认失败原因正确，再写最小实现，最后重构。
> 每个阶段结束 `cjpm test` 必须全绿；每个阶段独立提交，全部工作位于 `feature/f-svg-m2` 分支。
> M2 只增不改 M1 公开 API；不改 `f_svg/cjpm.toml` 依赖、根 `cjpm.toml`、`.modules` 与聚合根 shim。

## 1. 准备与基线

- [ ] 1.1 从 `feature/f_svg` 创建 `feature/f-svg-m2`（M2 依赖 M1 未合并代码），确认工作区干净
- [ ] 1.2 跑通 `cjpm test`，记录 M1 基线（当前 216 条）与耗时，确认零失败
- [ ] 1.3 阅读 `f_svg/doc/f_svg-M2设计.md` 与 `openspec/changes/add-f-svg-m2/` 四个产物，确认实现顺序
- [ ] 1.4 新建空实现文件骨架（仅包声明与 `TODO` 注释，不写逻辑）：`CssLexer.cj`、`CssParser.cj`、`CssSelector.cj`、`CssStyleSheet.cj`、`SvgComputedStyle.cj`、`SvgStyleResolver.cj`、`SvgBounds.cj`、`SvgGeometry.cj`、`SvgViewport.cj`、`SvgStrokeOutliner.cj`、`SvgBitmap.cj`、`SvgRasterizer.cj`、`SvgRenderTree.cj`、`SvgRenderer.cj`、`SvgFont.cj`、`SvgHersheyFont.cj`、`SvgTextRenderer.cj`、`SvgPngEncoder.cj`、`SvgCrc32.cj`、`SvgAnimation.cj`、`SvgTimeline.cj`、`SvgInterpolator.cj`、`SvgClock.cj`
- [ ] 1.5 确认这些文件都在 `f_svg/src/` 单包内，`cjpm build` 仍能通过空实现

## 2. CSS 词法与规则解析（M2.1）

- [ ] 2.1 先写 `CssLexer_test.cj`：注释跳过、单双引号字符串、`url(...)` 原样保留、转义、非法字符后恢复
- [ ] 2.2 实现 `CssLexer`（单遍扫描，带位置信息，不引入正则）
- [ ] 2.3 先写 `CssStyleSheet_test.cj`：基本规则、分组选择器、`!important`、声明原样值、`order` 递增
- [ ] 2.4 先写跳过用例：`@media`、`@import`、`@font-face`、伪类、属性选择器整条跳过并写 warning
- [ ] 2.5 先写容错用例：缺右花括号、缺分号、空声明块、多余分号
- [ ] 2.6 实现 `CssDeclaration` / `CssRule` / `CssStyleSheet.parse(text[, warnings])` / `empty()`
- [ ] 2.7 实现 `CssStyleSheet.toString` 的稳定输出（调试用，不要求可往返）

## 3. 选择器与匹配（M2.1）

- [ ] 3.1 先写 `CssSelector_test.cj`：类型、`.class`、`#id`、`*`、复合 `rect.a#b`
- [ ] 3.2 先写组合符用例：后代 `g rect`、子代 `g > rect`、三级链、跨兄弟不匹配
- [ ] 3.3 先写特异性用例：`(ids, classes, types)`、`*` 不计、复合累加
- [ ] 3.4 先写边界用例：空 class、重复 class 词、大小写敏感、属性缺失
- [ ] 3.5 实现 `CssSelectorPart` / `CssCombinator` / `CssSpecificity` / `CssSelector.matches`
- [ ] 3.6 实现右端选择器倒排桶（id / class / type），供 resolver 预过滤

## 4. 级联、继承与计算样式（M2.1）

- [ ] 4.1 先写 `SvgComputedStyle_test.cj`：属性元数据表（继承性与初始值）、`get` / `has`、类型化 getter
- [ ] 4.2 先写六级级联交叉矩阵：UA 默认 < 呈现属性 < `<style>` < 内联 < `!important`，以及同特异性源顺序
- [ ] 4.3 先写继承用例：可继承属性、`opacity` 不继承、`inherit` / `initial` / `unset`
- [ ] 4.4 先写 `currentColor` 两级继承与元素自身 `color` 覆盖
- [ ] 4.5 先写非法值降级：未知属性忽略、非法颜色回退初始值并 warning、外部 `url()` 捕获 `Security` 后按 `none` 处理并 warning
- [ ] 4.6 实现属性元数据表与指定值 → 计算值流程
- [ ] 4.7 实现 `SvgComputedStyle` / `SvgComputedStyleTree`（`get` / `size`）
- [ ] 4.8 实现 `SvgStyleResolver.init(sheet!)` 与 `compute(root)`：按文档顺序收集 `<style>`，与外部 sheet 合并；`<style>` 文本解析结果做进程内缓存
- [ ] 4.9 实现 `computeElement(element, parent)`，并保证不修改元素属性
- [ ] 4.10 先写 1000 规则 × 1000 元素基准用例，记录匹配耗时；未达 20 ms 时写入 `doc/perf-baseline.md`

## 5. 包围盒代数与基本形状（M2.2）

- [ ] 5.1 先写 `SvgBounds_test.cj`：`empty` / `isEmpty` / `union` / `intersect` / `inflate`
- [ ] 5.2 先写变换用例：45° 旋转、非等比缩放、平移、不可逆矩阵边界
- [ ] 5.3 实现 `SvgBounds` 与 `transform` 四角法
- [ ] 5.4 先写 `SvgGeometry_test.cj` 的形状用例：rect / circle / ellipse / line / polyline / polygon
- [ ] 5.5 先写非法输入用例：负宽高、单点折线、空多边形、缺失坐标
- [ ] 5.6 实现 `SvgGeometry.bounds` 的形状分支

## 6. 路径包围盒（M2.2）

- [ ] 6.1 先写 `SvgPathBounds_test.cj`：M/L/H/V/Z 端点与子路径起点
- [ ] 6.2 先写三次贝塞尔极值用例：控制点同侧、异侧、退化共线、端点极值
- [ ] 6.3 先写二次贝塞尔极值用例（含 `T` 的隐式控制点）
- [ ] 6.4 先写弧用例：半圆、整圆、大弧/小弧、翻转标志、`rx/ry = 0`、四种轴向极值（`SvgPathBounds_test.arcBounds`，大/小弧与四轴向极值用扁平化点集对照）
- [ ] 6.5 先写退化用例：零长段、`NaN` 参数、重复点
- [ ] 6.6 实现内部路径段迭代器（绝对化 + `H/V` 转 `L` + `S/T` 控制点推导）
- [ ] 6.7 实现三次/二次贝塞尔导数求根与极值纳入
- [ ] 6.8 实现端点参数 → 中心参数（含角度归一化与扫描角范围）
- [ ] 6.9 先写 `strokeBounds` 用例：无描边、普通外扩、miterlimit 截断、round/bevel
- [ ] 6.10 实现 `strokeBounds`
- [ ] 6.11 先写 `absoluteBounds` 用例：祖先变换累乘、无变换、嵌套组
- [ ] 6.12 实现 `absoluteBounds` 的祖先矩阵合成
- [ ] 6.13 先写文本 bbox 用例（测试字体 / 无字体提供者）
- [ ] 6.14 实现文本 bbox（依赖第 11 节字体接口，可先用测试桩）

## 7. 视口映射（M2.2）

- [ ] 7.1 先写 `SvgViewport_test.cj`：无 viewBox、meet、slice、none、九种对齐
- [ ] 7.2 先写尺寸解析用例：绝对宽高、百分比、缺省 fallback 300×150、非法尺寸
- [ ] 7.3 先写嵌套 svg 用例：外层 × 内层矩阵、`x/y` 平移、裁剪区域
- [ ] 7.4 实现 `SvgViewport.from` / `transform`
- [ ] 7.5 抽出嵌套视口矩阵计算，供渲染树与 `symbol` 复用

## 8. 位图与光栅基元（M2.3）

- [ ] 8.1 先写 `SvgBitmap_test.cj`：尺寸、`pixels.size`、初始透明度、`pixel()`、越界抛错
- [ ] 8.2 先写 `SvgRenderOptions` 用例：默认值、`samplesPerPixel` 只允许 1/2/4、`devicePixelRatio`、`maxPixels` 超限
- [ ] 8.3 实现 `SvgRgba`（预乘 Float64）与 `SvgBitmap` 的 RGBA8 存取
- [ ] 8.4 实现 `SvgRenderOptions` 与尺寸/上限校验
- [ ] 8.5 先写 `SvgRasterizer_test.cj`：4×4 位图上的矩形覆盖、边界像素、半开半闭
- [ ] 8.6 先写填充规则用例：三角形、凹多边形、自交回旋体，nonzero 与 evenodd 结果不同
- [ ] 8.7 先写退化边用例：水平边、重复点、端点落在扫描线
- [ ] 8.8 实现边表 + 活跃边表 + 子扫描线遍历
- [ ] 8.9 实现 nonzero 有向交点累计与 evenodd 交点配对
- [ ] 8.10 先写抗锯齿用例：45° 斜边覆盖率、`samplesPerPixel=1` 时 0/1
- [ ] 8.11 实现 `ss × ss` 子采样与覆盖率量化
- [ ] 8.12 先写颜色合成用例：两层 50% 叠加、背景填充、半透明边缘无黑边
- [ ] 8.13 实现预乘 `over` 合成与反预乘写回
- [ ] 8.14 先写路径扁平化用例：贝塞尔细分误差 ≤ 0.25 设备像素
- [ ] 8.15 实现设备矩阵变换与路径扁平化

## 9. 描边轮廓（M2.4）

- [ ] 9.1 先写 `SvgStrokeOutliner_test.cj`：butt/round/square 端点覆盖范围
- [ ] 9.2 先写 join 用例：miter、miter 超限退 bevel、round、bevel
- [ ] 9.3 先写 dash 用例：周期、相位、奇数数组复制、全零数组、负值
- [ ] 9.4 先写解析快速路径用例：rect / circle / ellipse / line 与通用 outliner 结果一致
- [ ] 9.5 实现线段偏移与左右轮廓拼接
- [ ] 9.6 实现 cap / join / miterlimit
- [ ] 9.7 实现 dash 切分与逐段 cap
- [ ] 9.8 实现 rect / circle / ellipse / line 解析轮廓
- [ ] 9.9 先写描边光栅用例：零宽不绘制、轮廓按 nonzero 填充、自交不破洞
- [ ] 9.10 接入 `SvgRasterizer` 的 `StrokePath` 指令

## 10. 渐变、裁剪、蒙版与组透明度（M2.5）

- [ ] 10.1 先写 `SvgGradient_test.cj` 的采样用例：线性端点、中点、`t` 公式、`p0 == p1`
- [ ] 10.2 先写 `spreadMethod` 用例：pad / repeat / reflect
- [ ] 10.3 先写 stops 用例：乱序、越界钳制、`stop-opacity`、相同 offset
- [ ] 10.4 先写径向渐变用例：圆心/边缘、焦点偏移、`r=0` warning、`fr/FR` 忽略 warning
- [ ] 10.5 先写坐标系用例：`userSpaceOnUse`、`objectBoundingBox`、`gradientTransform` 逆矩阵、不可逆矩阵 warning
- [ ] 10.6 先写 `href` 继承用例：stops 继承、属性覆盖、循环引用深度 64
- [ ] 10.7 实现线性/径向渐变采样与 stops 插值
- [ ] 10.8 实现 `gradientUnits` / `gradientTransform` / `href` 模板链
- [ ] 10.9 接入 `FillPath` / `StrokePath` 的画笔解析与 fallback
- [ ] 10.10 先写 `clipPath` 用例：矩形裁剪、圆形抗锯齿、`clip-rule=evenodd`、`clipPathUnits` 两种
- [ ] 10.11 实现 8 位裁剪覆盖率蒙版与乘法合成
- [ ] 10.12 先写 `mask` 用例：半透明蒙版、luminance、alpha、`maskUnits` / `maskContentUnits`
- [ ] 10.13 实现 alpha / luminance 蒙版生成与合成
- [ ] 10.14 先写组透明度用例：组内重叠不叠深、嵌套 0.5×0.5、非法值按 1
- [ ] 10.15 实现隔离组与离屏缓冲（按需创建、受 `maxPixels` 约束）

## 11. 字体与文本（M2.6）

- [ ] 11.1 先写 `SvgFont_test.cj`：接口契约、注册表精确匹配、family 列表回退、默认注册表
- [ ] 11.2 实现 `SvgFont` / `SvgFontRegistry`
- [ ] 11.3 先写 Hershey 用例（实际文件 `SvgFont_test.cj`）：ASCII 32–126 全覆盖、空格返回空路径、非 ASCII 返回 `None`、字号线性缩放、ascent/descent
- [ ] 11.4 实现 Hershey 静态字形表与 `glyphPath` / `advance` / `glyphBounds`
- [ ] 11.5 先写 `SvgTextRenderer_test.cj` 布局用例：连续 advance、`letter-spacing`、`word-spacing`
- [ ] 11.6 先写 `text-anchor` 三值、`x/y` 列表、`dx/dy` 列表、`textLength` + `lengthAdjust` 两模式
- [ ] 11.7 先写 `tspan` 嵌套、字号覆盖、进入/离开 `tspan` 的 dx/dy 累加
- [ ] 11.8 先写缺字占位、无字体注册、`textPath` 降级、`rotate` 忽略的 warning 用例
- [ ] 11.9 实现文本布局与字形路径输出
- [ ] 11.10 实现字形路径缓存（字体 + 字号 + 字符）
- [ ] 11.11 接入光栅器：文本填充/描边/渐变/裁剪与形状共用管线

## 12. 渲染树与渲染入口（M2.7）

- [ ] 12.1 先写 `SvgRenderTree_test.cj`：`display:none` 跳过、文档顺序保持、渲染不修改文档
- [ ] 12.2 先写 `use` 用例：基本复用、`x/y` 平移、`symbol` 视口、引用缺失 warning、循环引用深度 64
- [ ] 12.3 先写嵌套 `<svg>` 用例：视口缩放、`x/y` 偏移、超出视口裁剪
- [ ] 12.4 先写 `<image>` 占位用例：透明占位、`background` 占位、不发起请求、warning
- [ ] 12.5 实现 `SvgRenderTreeBuilder`（样式 + 引用展开 + 视口 + 裁剪/蒙版挂载）
- [ ] 12.6 实现 `SvgDisplayList` 与 `FillPath` / `StrokePath` / `Image` / `Text` 指令
- [ ] 12.7 先写 `SvgRenderer_test.cj`：`render(document)`、`render(element, width, height)`、`renderToPng`
- [ ] 12.8 实现 `SvgRenderer` 与顶层 `renderToPng`
- [ ] 12.9 先写确定性用例：同文档连续两次渲染 `pixels` 完全相等
- [ ] 12.10 实现渲染管线的确定性约束（不读时间/随机数/环境变量）

## 13. PNG 编码（M2.8）

- [ ] 13.1 先写 `SvgCrc32_test.cj`：标准测试向量、空数据、分块更新
- [ ] 13.2 实现 `SvgCrc32` 查表算法
- [ ] 13.3 先写 `SvgPngEncoder_test.cj`：签名、chunk 顺序、IHDR 字段、IEND 空数据
- [ ] 13.4 先写 IDAT 结构用例：zlib 头 `0x78 0x9C`、Adler-32、每行 filter 0、解压长度
- [ ] 13.5 实现 `SvgPngEncoder.encode` / `write`：chunk 拼装、CRC、zlib 包装、Adler-32
- [ ] 13.6 实现 `SvgBitmap.writePng` / `toPngBytes` / `savePng`
- [ ] 13.7 先写解压回读用例：随机 RGBA 8×8 往返逐字节一致；半透明 alpha 保留
- [ ] 13.8 先写确定性用例：两次编码一致、三种入口字节一致
- [ ] 13.9 先写文件输出用例：正常保存、目录不存在抛 `InvalidValue`

## 14. SMIL 动画（M2.9）

- [ ] 14.1 先写 `SvgClock_test.cj`：`SvgManualClock` 读写、`sampleCurrent` 使用时钟
- [ ] 14.2 实现 `SvgClock` / `SvgManualClock`
- [ ] 14.3 先写 `SvgAnimation_test.cj`：四类动画识别、缺失 `attributeName`/`type`/`path` 的 warning
- [ ] 14.4 先写时间解析用例：`0s`、`1.5s`、`500ms`、`indefinite`、`id.begin`、`id.end`、事件型忽略 warning
- [ ] 14.5 先写重复与结束语义：`repeatCount=2.5`、`repeatDur` 截断、`fill=remove`/`freeze`
- [ ] 14.6 先写 `SvgInterpolator_test.cj`：数值 linear/discrete/spline、数值列表、颜色、路径结构一致/不一致、字符串离散
- [ ] 14.7 实现时间轴活动区间与关键帧求值
- [ ] 14.8 实现 `SvgInterpolator` 各类型插值
- [ ] 14.9 先写 `animateTransform` 用例：五种 type、`from/to` 参数形式、`additive=sum` 与基础变换合成
- [ ] 14.10 实现变换分解/合成插值，无法分解时离散
- [ ] 14.11 先写 `animateMotion` 用例：直线运动、路径运动、`rotate=auto`/`auto-reverse`/角度、`keyPoints`（`SvgAnimation_test.animateMotion` / `animateMotionKeyPoints`）
- [ ] 14.12 实现沿路径运动与切线旋转
- [ ] 14.13 先写时间轴用例（实际文件 `SvgAnimation_test.cj`）：`duration()`、`animations()`、同元素多动画覆盖、`by`/`additive`/`accumulate`
- [ ] 14.14 实现动画深拷贝（`SvgDocument` → 副本，含 prolog/epilog/warnings，并重建 `parent` 链，保证 `elementById` 可用）
- [ ] 14.15 实现 `SvgTimeline.sample` / `sampleCurrent`，并写「采样不修改原文档」断言
- [ ] 14.16 先写上限用例：`values` 10001 抛 `Limit`、`mpath` 深度 64 抛 `Limit`

## 15. 场景快照与性能基准（M2.10）

- [ ] 15.1 编写 `testdata/render/basic.svg`（形状 + 分组 + 变换）与 64×64 `.rgba` 期望图
- [ ] 15.2 编写 `testdata/render/gradient.svg`（线性 + 径向 + spread）与期望图
- [ ] 15.3 编写 `testdata/render/stroke.svg`（cap/join/dash）与期望图
- [ ] 15.4 编写 `testdata/render/clip.svg`（clipPath + mask + opacity）与期望图
- [ ] 15.5 编写 `testdata/render/text.svg`（Hershey + anchor + tspan）与期望图
- [ ] 15.6 编写 `testdata/render/animation.svg` 与 0 / 0.5 / 1 秒三张期望图
- [ ] 15.7 新增 `SvgScene_test.cj`：逐像素比较，容差 ≤ 1；失败时输出首个差异坐标与两像素值
- [ ] 15.8 先写 512×512 / 50 形状、1024×1024 渐变+裁剪、1024×1024 PNG 编码基准用例
- [ ] 15.9 记录实测到 `f_svg/doc/perf-baseline.md`，标明「参考、非门禁」

## 16. 文档、验收与提交（M2.10）

- [ ] 16.1 更新 `f_svg/src/f_svg.cj` 包注释：删除「不渲染、不做 CSS 级联、不做动画」，改为 M2 能力概述
- [ ] 16.2 更新 `f_svg/README.md`：M2 能力表、CSS/渲染/动画快速开始、`SvgRenderOptions`、PNG、字体注册
- [ ] 16.3 更新 `f_svg/README_en.md`，与中文 README 对齐
- [ ] 16.4 核对 README、`doc/f_svg模块设计.md`、`doc/f_svg-M2设计.md` 与公开 API 一致，修正漂移
- [ ] 16.5 运行 `cjpm build`，确认 `f_svg` 自身 0 warning
- [ ] 16.6 运行 `cjpm test`，确认 M1 216 条 + M2 新增用例全绿
- [ ] 16.7 对照 `specs/svg-css`、`svg-geometry`、`svg-rasterization`、`svg-paint-and-clip`、`svg-text`、`svg-render-pipeline`、`svg-png`、`svg-animation`、`svg-security` 逐条确认场景有用例（实际映射与剩余缺口见 `verification.md` / `fix-plan.md`）
- [ ] 16.8 按 `AGENTS.md` 在 `feature/f-svg-m2` 分阶段提交，最后 `git merge --no-ff` 回 `feature/f_svg` 并删除分支
- [ ] 16.9 归档本变更：`/opsx:archive add-f-svg-m2`
