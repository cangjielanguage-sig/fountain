# svg-paint-and-clip

## MODIFIED Requirements

### Requirement: 线性渐变

系统 SHALL 支持 `linearGradient` 作为 `fill` / `stroke` 的画笔服务器。

参数 `t` SHALL 按 `t = dot(p - p0, p1 - p0) / |p1 - p0|²` 计算；`p0`、`p1` 按 `gradientUnits` 解析。`p0 == p1` 时 SHALL 取最后一个 stop 的颜色，不得崩溃。

`spreadMethod` SHALL 支持 `pad`（钳制到 `0..1`）、`repeat`（取小数部分）、`reflect`（按 2 周期折返）。

stops SHALL 按 `offset` 升序排序；`offset` SHALL 钳制到 `0..1`；相邻 stop 之间 SHALL 按生效的 `color-interpolation` 插值：`auto` / `sRGB` 在 sRGB 通道上线性插值（不做 gamma 校正），`linearRGB` 先把通道转为线性光、插值后再转回 sRGB。`stop-opacity` 在两种模式下均参与 alpha 线性插值。

#### Scenario: 端点颜色

- **WHEN** 线性渐变从 `(0,0)` 到 `(10,0)`，stops 为 `0` 红、`1` 蓝，采样 `(0,0)` 与 `(10,0)`
- **THEN** 分别为红与蓝

#### Scenario: 中点插值

- **WHEN** 同上，采样 `(5,0)`
- **THEN** RGB 各通道约为 `(128, 0, 128)`，容差 1/255

#### Scenario: spreadMethod

- **WHEN** `pad` / `repeat` / `reflect` 分别采样 `t = 1.25`
- **THEN** 分别取末 stop、`t = 0.25` 的颜色、`t = 0.75` 的颜色（`reflect` 折返）

#### Scenario: stop 乱序与越界

- **WHEN** stops 依次为 `1` 蓝、`0` 红、`2` 绿
- **THEN** 排序并钳制后按 `0` 红、`1` 蓝着色，不产生非法颜色

#### Scenario: linearRGB 中点

- **WHEN** 同一红蓝渐变声明 `color-interpolation="linearRGB"`，采样 `(5,0)`
- **THEN** 中点通道约为 `(188, 0, 188)`（线性光插值后转回 sRGB），与 sRGB 中点不同

## ADDED Requirements

### Requirement: M6 颜色插值模式

渐变插值 SHALL 读取生效的 `color-interpolation`。`auto` SHALL 等价 `sRGB` 并保持 M5 逐字节输出；`linearRGB` SHALL 按 IEC 61966-2-1 转换：`c <= 0.04045` 时线性值 `c / 12.92`，否则 `((c + 0.055) / 1.055)^2.4`，插值后使用逆变换。

`color-interpolation` SHALL 独立于滤镜的 `color-interpolation-filters`；滤镜行为 SHALL NOT 因此改变。

#### Scenario: 缺省不变

- **WHEN** 未声明 `color-interpolation`
- **THEN** 与 `sRGB` 输出逐字节一致

#### Scenario: 线性光两端一致

- **WHEN** `linearRGB` 采样 `t = 0` 与 `t = 1`
- **THEN** 颜色与 `sRGB` 的端点完全相同

#### Scenario: 与滤镜独立

- **WHEN** 同一文档分别设置 `color-interpolation` 与 `color-interpolation-filters`
- **THEN** 前者只影响渐变，后者只影响滤镜

#### Scenario: 继承

- **WHEN** 渐变元素祖先声明 `color-interpolation="linearRGB"`
- **THEN** 该渐变按线性光插值

### Requirement: M6 颜色配置回退

`color-profile` 属性 SHALL 作用于渐变插值。`auto` / `sRGB` SHALL 按 sRGB 处理；已声明的非 sRGB profile SHALL 按 sRGB 处理并 warning；未声明的名称 SHALL 回退 `sRGB` 并 warning。系统 SHALL NOT 执行 ICC 变换。

#### Scenario: 缺省

- **WHEN** 未声明 `color-profile`
- **THEN** 插值与 M5 逐字节一致，不产生 warning

#### Scenario: 已声明非 sRGB

- **WHEN** 声明 `@color-profile p3` 并在渐变上设 `color-profile: p3`
- **THEN** 按 sRGB 插值并产生一条 warning

#### Scenario: 未声明名称

- **WHEN** 渐变上设 `color-profile: unknown`
- **THEN** 回退 `sRGB` 并 warning，不抛异常
