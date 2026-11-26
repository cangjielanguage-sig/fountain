# svg-paint-and-clip

## ADDED Requirements

### Requirement: 线性渐变

系统 SHALL 支持 `linearGradient` 作为 `fill` / `stroke` 的画笔服务器。

参数 `t` SHALL 按 `t = dot(p - p0, p1 - p0) / |p1 - p0|²` 计算；`p0`、`p1` 按 `gradientUnits` 解析。`p0 == p1` 时 SHALL 取最后一个 stop 的颜色（或第一个，二者一致的退化处理不得崩溃）。

`spreadMethod` SHALL 支持 `pad`（钳制到 `0..1`）、`repeat`（取小数部分）、`reflect`（按 2 周期折返）。

stops SHALL 按 `offset` 升序排序；`offset` SHALL 钳制到 `0..1`；相邻 stop 之间按 sRGB 通道线性插值（不做 gamma 校正），`stop-opacity` 参与 alpha 插值。

#### Scenario: 端点颜色

- **WHEN** 线性渐变从 `(0,0)` 到 `(10,0)`，stops 为 `0` 红、`1` 蓝，采样 `(0,0)` 与 `(10,0)`
- **THEN** 分别为红与蓝

#### Scenario: 中点插值

- **WHEN** 同上，采样 `(5,0)`
- **THEN** RGB 各通道约为 `(128, 0, 128)`，容差 1/255

#### Scenario: spreadMethod

- **WHEN** `pad` / `repeat` / `reflect` 分别采样 `t = 1.5`
- **THEN** 分别取末 stop、`t = 0.5` 的颜色、`t = 0.5` 的颜色（`reflect` 折返）

#### Scenario: stop 乱序与越界

- **WHEN** stops 依次为 `1` 蓝、`0` 红、`2` 绿
- **THEN** 排序并钳制后按 `0` 红、`1` 蓝着色，不产生非法颜色

### Requirement: 径向渐变

系统 SHALL 支持 `radialGradient`，参数为 `cx` / `cy` / `r` / `fx` / `fy`。

采样参数 SHALL 为 `t = |p - f| / r`，其中 `f` 为焦点、`r` 为半径；`fx` / `fy` 缺省等于 `cx` / `cy`；`r <= 0` 时 SHALL 不绘制并记 warning。

`fr` 与 `FR` 在 M2 SHALL 不支持：解析到这些属性时忽略并记 warning，不影响 `cx` / `cy` / `r` 的绘制。

#### Scenario: 圆心与边缘

- **WHEN** `radialGradient(cx=50,cy=50,r=10)`、stops `0` 白 `1` 黑，采样圆心与半径处
- **THEN** 分别为白与黑

#### Scenario: 焦点偏移

- **WHEN** `fx=60`、`cx=50`、`r=10`
- **THEN** 最亮区域中心位于 `(60,50)` 附近

#### Scenario: 零半径

- **WHEN** `r = 0`
- **THEN** 该填充不绘制，并产生一条 warning

### Requirement: 渐变坐标系与引用

`gradientUnits` SHALL 支持 `userSpaceOnUse`（默认）与 `objectBoundingBox`；后者 SHALL 把元素几何包围盒归一化到 `0..1` 后再求值。

`gradientTransform` SHALL 在采样前应用其逆矩阵；矩阵不可逆时 SHALL 视为无变换并记 warning。

`href="#id"` SHALL 允许渐变继承另一渐变的 stops 与未显式设置的属性；循环引用 SHALL 被检测并停止继承，深度上限 64。

画笔引用未命中（目标不存在或不是渐变）时 SHALL 回退到画笔的 fallback；无 fallback 时按 `none` 处理并记 warning。

#### Scenario: objectBoundingBox

- **WHEN** 元素包围盒为 `(10,20,40,20)`，`gradientUnits="objectBoundingBox"`、渐变从 `0` 到 `1`
- **THEN** 包围盒左边界取起点颜色、右边界取终点颜色

#### Scenario: gradientTransform 逆变换

- **WHEN** `gradientTransform="translate(10,0)"`，采样点 `(10,0)` 在局部坐标中对应 `(0,0)`
- **THEN** 取起点颜色

#### Scenario: 继承 stops

- **WHEN** `linearGradient id="a"` 定义 stops，`linearGradient id="b" href="#a"` 只覆盖 `x2`
- **THEN** `b` 使用 `a` 的 stops 与自己的 `x2`

#### Scenario: 引用缺失回退

- **WHEN** `fill="url(#missing) red"`
- **THEN** 使用红色填充

### Requirement: 裁剪路径

系统 SHALL 支持 `clipPath`：把 `clipPath` 子内容按 `clipPathUnits`（`userSpaceOnUse` 默认 / `objectBoundingBox`）渲染为 8-bit 覆盖率蒙版，并与被裁剪图元的覆盖率逐像素相乘。

`clip-rule` SHALL 支持 `nonzero` 与 `evenodd`。裁剪只影响绘制，不影响几何包围盒。裁剪内容不能再次引用自身；循环引用 SHALL 在深度 64 处终止并记 warning。

#### Scenario: 矩形裁剪

- **WHEN** 一个覆盖全画布的红色矩形被 `clipPath` 中的 `(0,0,10,10)` 矩形裁剪
- **THEN** 只有 `(0,0)-(10,10)` 区域为红色，其余透明

#### Scenario: 圆形裁剪抗锯齿

- **WHEN** 使用圆形 `clipPath` 裁剪实心矩形
- **THEN** 圆边界像素为部分覆盖率，内部为全不透明

#### Scenario: evenodd 裁剪

- **WHEN** `clip-rule="evenodd"` 且裁剪路径含同心矩形
- **THEN** 内层矩形区域被挖空

### Requirement: 蒙版

系统 SHALL 支持 `mask`，生成 alpha 或 luminance 蒙版，并与被蒙版图元逐像素相乘。

`maskUnits` SHALL 默认 `objectBoundingBox`，`maskContentUnits` SHALL 默认 `userSpaceOnUse`。

蒙版取值 SHALL 默认按 luminance 计算：`0.2125R + 0.7154G + 0.0721B`，再乘蒙版 alpha；当 `mask` 元素显式声明 `mask-type="alpha"` 时 SHALL 改用蒙版 alpha。

#### Scenario: 半透明蒙版

- **WHEN** 蒙版内容为 50% 不透明黑色，被蒙版图元为不透明红色
- **THEN** 结果为 50% alpha 的红色

#### Scenario: luminance 蒙版

- **WHEN** 蒙版内容为白色不透明、被蒙版图元为蓝色
- **THEN** 蓝色保持不透明；蒙版内容改为黑色时结果透明

#### Scenario: alpha 蒙版

- **WHEN** `mask-type="alpha"`，蒙版内容为不透明白色
- **THEN** 结果保持被蒙版图元的原始 alpha

### Requirement: 组透明度与隔离组

`opacity < 1` 的组 SHALL 先渲染到独立离屏缓冲，再以预乘 alpha 整体合成到父层，不得对子元素逐个应用透明度。

嵌套 `opacity` 组 SHALL 逐层独立合成；`mask` 与 `clipPath` 组合同样 SHALL 走隔离组合成。

`opacity` 值 SHALL 钳制到 `0..1`；非法值按 `1` 处理并记 warning。

#### Scenario: 组透明度不是逐元素

- **WHEN** `<g opacity="0.5">` 内两个重叠的不透明红色矩形
- **THEN** 重叠区域不会因为两次 50% 叠加而更深，整组以 50% 合成一次

#### Scenario: 嵌套组

- **WHEN** 外层 `opacity=0.5`、内层 `opacity=0.5`
- **THEN** 内层内容最终 alpha 约为 `0.25`

#### Scenario: 非法透明度

- **WHEN** `opacity="2"` 或 `opacity="abc"`
- **THEN** 按 `1` 处理，后者额外产生一条 warning
