# 任务：add-f-svg-m4

> 每个任务按 Red-Green-Refactor 推进：先写失败用例并确认失败原因正确，再写最小实现，最后重构。
> 每组结束 `cjpm test` 必须全绿；每组独立提交，全部工作位于 `feature/f-svg-m4` 分支。
> M4 只增不改 M1–M3 公开 API 语义；不新增模块、子包或第三方依赖；不改根 `cjpm.toml`、`.modules` 与聚合根 shim。

## 1. 准备与基线

- [ ] 1.1 从当前 `f_svg` 工作分支切出 `feature/f-svg-m4`，`git status` 确认工作区干净
- [ ] 1.2 运行 `cjpm test`，记录基线（533 条用例）、耗时与零失败，写入本任务备注
- [ ] 1.3 通读 `f_svg/doc/f_svg-M4设计.md` 与本变更 `proposal.md` / `design.md` / `specs/`，确认实施顺序与边界
- [ ] 1.4 新建空实现骨架（仅包声明与 `TODO`）：`SvgClipProperty.cj`、`SvgOverflow.cj`、`SvgVectorEffect.cj`、`SvgFilterPrimitives2.cj`、`SvgFilterLighting.cj`、`SvgTrueTypeFont.cj`、`SvgTrueTypeTables.cj`、`SvgTextBaseline.cj`、`SvgTextDecoration.cj`、`SvgTextWritingMode.cj`、`SvgView.cj`、`SvgSwitch.cj`、`SvgAnchor.cj`、`SvgPathMeasure.cj`；`cjpm build` 通过
- [ ] 1.5 建立 `testdata/render/m4-*` 场景目录与 `testdata/fonts/` fixture 目录，先只放占位说明，确认 `cjpm test` 仍全绿

## 2. 值类型、属性表与选项

- [ ] 2.1 先写 `SvgValueTypesM4_test.cj`：文本枚举（`SvgWritingMode` / `SvgDominantBaseline` / `SvgAlignmentBaseline` / `SvgTextDecoration` / `SvgBaselineShift`）的解析、`toString`、组合与非法值回退；实现后用例转绿
- [ ] 2.2 先写渲染枚举用例：`SvgVectorEffect` / `SvgOverflow` / `SvgTransferFunctionType` / `SvgMorphologyOperator` / `SvgEdgeMode` / `SvgChannelSelector` / `SvgTurbulenceType`；实现后用例转绿
- [ ] 2.3 先写 `SvgComputedStyle_test` 增量用例：8 个 M4 属性的初始值、继承性、`inherit` / `initial` / `unset`；实现 `SVG_PROPERTY_TABLE` 注册后转绿
- [ ] 2.4 先写 `SvgStyleResolver_test` 增量用例：`clip` 函数归一、`overflow: scroll` → `hidden`、`baseline-shift` 百分比、`text-decoration` 排序、非法值 warning；实现 `normalizeValue` 后转绿
- [ ] 2.5 先写 `SvgRenderOptions` 用例：`languages == ["en"]`、既有字段默认值不变、既有构造调用编译通过；在 `SvgBitmap.cj` 增加 `languages` 后转绿

## 3. clip / overflow / vector-effect（A1–A3）

- [ ] 3.1 先写 `SvgClipProperty_test.cj`：`auto`、四边长度、单边 `auto`、`rect()` 空白与逗号分隔、非法值 warning；实现解析后转绿
- [ ] 3.2 先写 `SvgRenderer_test` 增量用例：矩形四边裁剪、旋转 45° 裁剪、`auto` 单边、与 `clip-path` 叠加；实现 `SvgClipCoverage` 并在显示指令中应用后转绿
- [ ] 3.3 先写 `SvgRenderTree_test` 增量用例：`clip` 与 `filter` 顺序（滤镜先、裁剪后），重复渲染逐字节一致；实现固定顺序后转绿
- [ ] 3.4 先写 `SvgOverflow` 用例：marker 默认裁剪越界内容、`overflow="visible"` 放行、symbol 裁剪、嵌套 `svg` 放行、pattern tile 边界；分别实现 marker / nested svg / symbol 分支后转绿
- [ ] 3.5 先写 `SvgVectorEffect_test.cj`：`scale(2)` 描边宽度不变、`scale(2,1)` 用 `sqrt(|det|)`、虚线长度不缩放、非法值 warning；实现渲染树宽度与虚线换算后转绿
- [ ] 3.6 先写组合用例：`non-scaling-stroke` 与 dash / 渐变描边 / 图案描边同时使用，且与 `clip` 叠加；确认输出确定性后提交本组

## 4. 新滤镜元素模型（A4–A10 模型层）

- [ ] 4.1 先写 `SvgFilter_test` 增量用例：`feComponentTransfer`、`feFunc*`、`feMorphology`、`feConvolveMatrix`、`feTurbulence`、`feDisplacementMap`、`feImage`、`feDiffuseLighting` / `feSpecularLighting`、三种光源的属性默认值与读写
- [ ] 4.2 实现 15 个新元素类型与 `SvgFilterPrimitive` 子类，扩展 `SvgTag.create` / `isKnown` 后用例转绿
- [ ] 4.3 先写 `SvgRoundTrip_test` 增量用例：新标签、新属性、光照子元素顺序的解析 → 生成 → 解析；实现生成侧命名空间与属性回写后转绿
- [ ] 4.4 先写非法结构用例：光照原语多个光源、`feComponentTransfer` 混入非 `feFunc` 子元素、`feImage` 缺 `href`；实现 warning + 降级后转绿

## 5. 分量传递、形态学与卷积（A4–A6）

- [ ] 5.1 先写 `SvgFilterPrimitives2_test.cj`：`identity` / `table` / `discrete` / `linear` / `gamma` 五种传递函数、结果钳制、缺失通道 identity、空 `tableValues` warning；实现 `feComponentTransfer` 后转绿
- [ ] 5.2 先写 `feMorphology` 用例：erode 收边、dilate 扩边、半径 0 直通、负半径 warning、`primitiveUnits` 换算；实现矩形核局部极值后转绿
- [ ] 5.3 先写 `feConvolveMatrix` 用例：单位核直通、锐化核、`divisor` / `bias` 换算、`edgeMode` 三档、`preserveAlpha`；实现二维卷积后转绿
- [ ] 5.4 先写负向用例：`kernelMatrix` 长度不符、`order="10 10"` 抛 `Limit` 且未分配缓冲；实现参数校验后转绿
- [ ] 5.5 先写链式用例：`feComponentTransfer` → `feMorphology` → `feConvolveMatrix` 的 `result` 连接与确定性；确认逐字节一致后提交本组

## 6. 湍流、位移与图像原语（A7–A9）

- [ ] 6.1 先写 `feTurbulence` 用例：`fractalNoise` / `turbulence` 输出差异、同 seed 逐字节一致、`baseFrequency` 单/双值、`numOctaves="9"` 抛 `Limit`；实现整数哈希 Perlin 噪声后转绿
- [ ] 6.2 先写 `feDisplacementMap` 用例：`scale=0` 直通、通道位移、越界透明、`in2` 缺省、通道选择器回退；实现双线性位移采样后转绿
- [ ] 6.3 先写 `feImage` 用例：`data:image/png` 绘制、provider 注入、未注入 provider 透明 + warning、同一 `href` 只解码一次；实现复用 `SvgImageResource` 后转绿
- [ ] 6.4 先写 `feImage` 专项用例：`preserveAspectRatio` 三档、base64 超限、累计解码像素超限抛 `Limit`；确认预算共享后提交本组

## 7. 光照（A10）

- [ ] 7.1 先写 `SvgFilterLighting_test.cj`：`feDistantLight` 平面漫反射、`fePointLight` 距离衰减、`feSpotLight` 锥角与 `limitingConeAngle`
- [ ] 7.2 实现 alpha 中心差分法线与 Lambert 漫反射；用例转绿
- [ ] 7.3 先写 `feSpecularLighting` 用例：`specularExponent` 高光峰值、通道钳制、alpha 透传；实现 Blinn-Phong 后转绿
- [ ] 7.4 先写降级用例：缺光源、未知光源、`surfaceScale` 非有限值；实现透明 + warning 后转绿
- [ ] 7.5 先写组合用例：光照 + `feComposite` + `feBlend` 的链式输出与两次执行一致性；提交本组

## 8. pattern 视口（A11）

- [ ] 8.1 先写 `SvgPattern_test` 增量用例：`viewBox` / `preserveAspectRatio` 属性默认值与往返；实现字段与标签白名单后转绿
- [ ] 8.2 先写 `SvgPatternSampler_test` 用例：`viewBox="0 0 10 10"` tile 20×20 放大 2 倍、`slice` 裁剪、有 `viewBox` 时忽略 `patternContentUnits`、无 `viewBox` 输出与 M3 一致
- [ ] 8.3 实现 tile 内容矩阵与 `patternTransform` 合成；用例转绿后提交本组

## 9. 文本基线（B1）

- [ ] 9.1 先写 `SvgTextBaseline_test.cj`：五种基线 y 顺序、`middle` / `central`、`mathematical`、Hershey 0.8/0.2 度量、无度量回退
- [ ] 9.2 实现 `SvgTextBaseline.offset` 与渲染器接入；用例转绿
- [ ] 9.3 先写 `baseline-shift` 用例：长度、百分比（相对 `font-size`）、`sub` / `super`、正值向上、非法值 warning；实现叠加顺序后转绿
- [ ] 9.4 先写 `alignment-baseline` 用例：`tspan` 相对父基线偏移、`auto` / `baseline` 不偏移、嵌套 `tspan`；用例转绿后提交本组

## 10. 文本装饰线（B2）

- [ ] 10.1 先写 `SvgTextDecoration_test.cj`：三条线的 y 位置与厚度公式、组合、`none`
- [ ] 10.2 实现装饰线几何与按字形旋转矩阵变换；用例转绿
- [ ] 10.3 先写像素用例：颜色取 `fill`、渐变按字形起点取样、textPath 切线旋转、tspan 不断开、祖先传播与 `none` 关闭；用例转绿后提交本组

## 11. 书写模式（B3）

- [ ] 11.1 先写 `SvgTextWritingMode_test.cj`：`lr-tb` / `lr` 输出不变、`tb-rl` 两列从右到左、字形顺时针 90°
- [ ] 11.2 实现换轴布局与 90° 旋转；用例转绿
- [ ] 11.3 先写 `text-anchor` 沿列生效、`x` / `y` 语义、与 `textPath` 冲突 warning、非法值回退；用例转绿后提交本组

## 12. textPath 扩展（B4）

- [ ] 12.1 先写 `SvgTextPathModel_test` 增量用例：`side` / `method` / `spacing` 的默认值与非法值回退
- [ ] 12.2 先写 `SvgTextPathLayout_test` 用例：`side="left"` / `"right"` 的法线偏移与切线角不变
- [ ] 12.3 先写 `method="stretch"` 覆盖全长、`spacing="exact"` 使用 `dx`、缺省行为与 M3 逐字节一致
- [ ] 12.4 实现三个属性并接入布局器；全部用例转绿后提交本组

## 13. TrueType 字体（B5）

- [ ] 13.1 先写 `SvgTrueTypeTables_test.cj`：表目录、`be16` / `be32` / `i16` 边界读取、截断、`loca` 非单调
- [ ] 13.2 手工构造最小 TTF fixture（`head` / `hhea` / `maxp` / `hmtx` / `loca` / `cmap4` / 简单 `glyf`），先写 `SvgTrueTypeFont_test.cj`：`unitsPerEm`、`advance`、`glyphPath`、`glyphBounds`
- [ ] 13.3 实现表读取器与简单字形轮廓（`M` / `L` / `Q` / `Z`、y 翻转、字号缩放）；用例转绿
- [ ] 13.4 先写复合字形用例：`ARG_1_AND_2_ARE_WORDS`、`ARGS_ARE_XY_VALUES`、`MORE_COMPONENTS`、2×2 变换；实现递归组合后转绿
- [ ] 13.5 先写 `cmap` format 12 用例与 CFF / OTF 拒绝、必需表缺失、空字形；用例转绿
- [ ] 13.6 先写上限用例：表数 65、单表 > 16 MiB、字形点数 > 10000、复合深度 > 8 均抛 `Limit`，并在读取前失败；用例转绿后提交本组
- [ ] 13.7 先写集成用例：把 TTF 注册到 `SvgFontRegistry` 后渲染文本，字形与占位方框可区分；确认字距为 0（不使用 kern）后更新 `README` 字体章节

## 14. view、switch 与 anchors（C1–C3）

- [ ] 14.1 先写 `SvgView_test.cj`：`view` 映射、`viewBox` / `preserveAspectRatio` / `viewTarget` 读写、`views()` 顺序、`view(id)` 缺失返回 `None`、往返
- [ ] 14.2 实现 `SvgView`、`SvgTag` 映射与 `SvgDocument.views()` / `view(id)`；用例转绿
- [ ] 14.3 先写 `SvgViewport_test` 增量用例：`forView` 的 meet / none / slice 与非正视口 `InvalidValue`；实现后转绿
- [ ] 14.4 先写 `SvgSwitch_test.cj`：语言前缀匹配、`languages` 优先级、已知特性、未知扩展跳过、全部不满足为空、`display="none"` 交互
- [ ] 14.5 实现 `SvgSwitch` 条件求值与渲染树分派；用例转绿，并写 `SvgRenderOptions.languages` 默认值用例
- [ ] 14.6 先写 `SvgAnchor_test.cj`：嵌套顺序、`href` / `target` 默认、外部 href 不出现、渲染输出与 M3 一致
- [ ] 14.7 实现 `SvgAnchorInfo` 与 `SvgDocument.anchors()`；用例转绿后提交本组

## 15. 路径长度与 CTM（C4–C5）

- [ ] 15.1 先写 `SvgPathMeasure_test.cj`：直线 / 折线 / 圆 / 圆弧长度、中点坐标、负值与超长钳制、空路径、非正容差 `InvalidValue`、容差收敛
- [ ] 15.2 实现 `SvgPathMeasure` 与 `SvgPathData.totalLength` / `pointAtLength`；用例转绿
- [ ] 15.3 先写一致性用例：同一路径的 `pointAtLength` 与 `textPath` 落点误差 ≤ 0.01；重构 `SvgTextPathLayout` 复用段表后转绿
- [ ] 15.4 先写 `SvgGeometry_test` 增量用例：嵌套 `g` / 嵌套 `svg` 的 `ctm`、无变换 identity；实现 `ctm` 后转绿
- [ ] 15.5 先写 `SvgViewportTransform` 与 `screenCTM` 用例：DPR 2、viewBox 缩放、与渲染设备坐标一致、无 viewBox 等于 `ctm`；实现后转绿并提交本组

## 16. 上限与负向补齐

- [ ] 16.1 按 `svg-security` 的 M4 上限表逐条写负向用例：卷积核、湍流倍频、TTF 表数 / 表长 / 点数 / 复合深度、`feImage` 预算
- [ ] 16.2 确认所有上限在分配或读取前失败；断言异常 kind 与无大块分配
- [ ] 16.3 先写 warning 可审计用例：每条 M4 warning 含元素路径或属性名；确认 `SvgRenderer.warnings` 与 `SvgDocument.warnings` 累积后提交本组

## 17. 场景快照与性能基准

- [ ] 17.1 新增 `testdata/render/m4-clip.svg` 与期望图（clip + overflow + vector-effect）
- [ ] 17.2 新增 `testdata/render/m4-filter.svg` 与期望图（分量传递 + 形态学 + 卷积 + 湍流 + 位移 + 光照）
- [ ] 17.3 新增 `testdata/render/m4-text.svg` 与期望图（基线 + 装饰 + 竖排 + textPath side/stretch）
- [ ] 17.4 新增 `testdata/render/m4-view.svg` 与期望图（pattern viewBox + switch + view 不参与渲染）
- [ ] 17.5 扩展 `SvgScene_test.cj`：逐像素比较、容差 ≤ 1、失败输出首个差异坐标与像素值；确认 M1–M3 全部快照仍逐字节一致
- [ ] 17.6 新增基准：512×512 卷积、512×512 湍流、20 万次 TTF 字形解析、1000 段路径长度；记录到 `f_svg/doc/perf-baseline.md` 并标注「参考、非门禁」

## 18. 文档与验收

- [ ] 18.1 更新 `f_svg/src/f_svg.cj` 包注释为 M4 能力概述
- [ ] 18.2 更新 `f_svg/README.md`：M4 能力表、A/B/C 三组示例、`overflow` 在 pattern 上的限制、marker 裁剪的条件性输出差异、TTF 加载边界
- [ ] 18.3 更新 `f_svg/README_en.md`，与中文 README 对齐
- [ ] 18.4 核对 README、`doc/f_svg模块设计.md` 与公开 API 一致；`doc/f_svg-M4设计.md` 保持不动
- [ ] 18.5 运行 `cjpm build`，确认 `f_svg` 自身 0 warning；运行 `cjpm test`，确认 533 条基线零回归且 M4 用例全绿
- [ ] 18.6 运行 `openspec validate add-f-svg-m4 --strict`，确认通过；逐条核对每个 Requirement 至少一个 Scenario
- [ ] 18.7 确认未新增模块 / 依赖，`f_svg/cjpm.toml`、根 `cjpm.toml`、`.modules` 无改动
- [ ] 18.8 在 `feature/f-svg-m4` 上按组提交，最后合并回上游并删除分支（`git merge --no-ff`）

## Workflow follow-up

- 归档本变更：`/opsx:archive add-f-svg-m4`，确认 `openspec/specs/` 的 10 个能力 spec 已同步 delta。
