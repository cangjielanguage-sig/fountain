# svg-animation

## ADDED Requirements

### Requirement: 动画元素识别

系统 SHALL 识别 `animate`、`animateTransform`、`animateMotion`、`set` 四类动画元素。

`animate`、`animateTransform`、`animateMotion`、`set` SHALL 分别记录为 `kind` 对应的动画记录。

#### Scenario: 识别四类动画

- **WHEN** 文档中同时含 `animate`、`animateTransform`、`animateMotion`、`set`
- **THEN** `SvgTimeline.animations()` 返回四条记录，`kind` 分别为对应类型

### Requirement: animate 属性

`animate` SHALL 支持 `attributeName`、`from` / `to` / `by` / `values`、`dur`、`begin`、`end`、`repeatCount`、`repeatDur`、`fill`、`calcMode`、`keyTimes`、`keySplines`、`additive`、`accumulate`。

`animateTransform` SHALL 额外支持 `type`（`translate` / `scale` / `rotate` / `skewX` / `skewY`）。

#### Scenario: animate 属性解析

- **WHEN** 解析 `<animate attributeName="x" from="0" to="10" dur="1s"/>`
- **THEN** 动画记录包含 `attributeName=x`、`from=0`、`to=10`、`dur=1`

### Requirement: animateMotion 与 set 属性

`animateMotion` SHALL 支持 `path` / `mpath`、`rotate`（`auto` / `auto-reverse` / 角度）、`keyPoints`。

`set` SHALL 支持 `attributeName`、`to`、`begin`、`dur`、`fill`。

缺少 `attributeName` 的 `animate` / `set`、缺少 `type` 的 `animateTransform`、既无 `path` 又无可解析 `mpath` 的 `animateMotion` SHALL 被忽略并记 warning。

#### Scenario: 缺失 attributeName

- **WHEN** `<animate to="5" dur="1s"/>`
- **THEN** 该动画被忽略，产生一条 warning

#### Scenario: 缺少 type 的 animateTransform

- **WHEN** `<animateTransform attributeName="transform" dur="1s"/>`
- **THEN** 被忽略并记 warning

### Requirement: 时间模型

时间值 SHALL 支持秒（`s`）、毫秒（`ms`）与小数值；`indefinite` SHALL 表示永不结束。

`begin` / `end` SHALL 支持：绝对偏移（`0s`、`1.5s`、`500ms`）、`id.begin`、`id.end`、`indefinite`；事件型（`click`、`mouseover` 等）SHALL 被忽略并记 warning。

`dur` 缺省 SHALL 为 `indefinite`；`repeatCount` SHALL 支持正数与 `indefinite`；`repeatDur` SHALL 截断总活动时长。

`fill` SHALL 支持 `remove`（默认，结束后恢复基础值）与 `freeze`（结束后保持末值）。

#### Scenario: 毫秒解析

- **WHEN** `dur="500ms"`、`begin="1.5s"`
- **THEN** 动画从 1.5 秒开始，持续 0.5 秒

#### Scenario: id.begin

- **WHEN** 动画 A 的 `begin="0s"`、`dur="1s"`，动画 B 的 `begin="A.end"`
- **THEN** B 从 1.0 秒开始

#### Scenario: 重复次数

- **WHEN** `dur="1s"`、`repeatCount="2.5"`、`fill="remove"`
- **THEN** 动画在 2.5 秒后结束，2.6 秒时恢复基础值

#### Scenario: fill freeze

- **WHEN** 同上但 `fill="freeze"`
- **THEN** 2.6 秒时保持末值

#### Scenario: 事件型 begin

- **WHEN** `begin="click"`
- **THEN** 该时间项被忽略，产生包含 `click` 的 warning

### Requirement: 数值与关键帧插值

`calcMode` SHALL 支持 `linear`（默认）、`discrete`、`spline`、`paced`。

`values` + `keyTimes` SHALL 定义关键帧；`keyTimes` 缺省 SHALL 均匀分布，数量必须与 `values` 一致，否则回退到均匀分布并记 warning。

`spline` SHALL 使用 `keySplines` 的四控制点三次贝塞尔缓动；`keySplines` 数量必须为 `values.size - 1`，否则回退到 `linear` 并记 warning。

`discrete` SHALL 取当前时间段之前的最后一个关键值。

#### Scenario: 线性关键帧

- **WHEN** `values="0;10"`、`keyTimes="0;1"`、`dur="1s"`，采样 0.5 秒
- **THEN** 值为 5

#### Scenario: 离散关键帧

- **WHEN** `values="0;10"`、`calcMode="discrete"`，采样 0.9 秒
- **THEN** 值为 0；采样 1.0 秒时为 10

#### Scenario: 样条缓动

- **WHEN** `keySplines="0.42 0 1 1"`、`values="0;10"`，采样 0.5 秒
- **THEN** 值介于 0 与 10 之间且不等于线性结果 5

#### Scenario: keyTimes 数量不符

- **WHEN** `values` 有 3 项、`keyTimes` 有 2 项
- **THEN** 回退为均匀分布并产生 warning

### Requirement: 多类型插值

插值 SHALL 按属性类型选择规则：

- 数值：线性；
- 数值列表：逐项插值，长度不等时按较短者处理，多余项取末值；
- 颜色：RGBA 各通道线性插值（sRGB）；
- 变换：分解为 translate / scale / rotate / skew 后逐项插值，无法分解时离散；
- 路径：命令结构一致时逐坐标插值，否则离散；
- 字符串与枚举：离散。

`by` 动画 SHALL 等价于 `to = from + by`（数值与数值列表）；`additive="sum"` SHALL 把动画值叠加到基础值；`accumulate="sum"` SHALL 在每个重复轮次上累加。

#### Scenario: 颜色插值

- **WHEN** `from="red"`、`to="blue"`，采样中点
- **THEN** 结果为紫，容差 1/255

#### Scenario: 数值列表

- **WHEN** `from="0 0"`、`to="10 20"`，采样中点
- **THEN** 结果为 `5 10`

#### Scenario: by 动画

- **WHEN** 基础值 `10`、`by="5"`，动画结束时
- **THEN** 值为 15

#### Scenario: additive sum

- **WHEN** 基础值 `10`、`from="0"`、`to="5"`、`additive="sum"`，结束时
- **THEN** 值为 15

#### Scenario: 路径结构不一致离散

- **WHEN** `from="M0 0 L10 0"`、`to="M0 0 C1 1 2 2 10 10"`
- **THEN** 不抛异常，按离散切换

### Requirement: animateTransform

`animateTransform` SHALL 作用于目标元素的 `transform` 属性，`type` 支持 `translate`、`scale`、`rotate`、`skewX`、`skewY`。

`additive="sum"` SHALL 把动画变换与基础 `transform` 矩阵相乘；`additive="replace"` SHALL 替换基础变换。

`rotate` 的 `from` / `to` SHALL 允许 `角度` 或 `角度 cx cy` 形式。

#### Scenario: 旋转动画

- **WHEN** `type="rotate"`、`from="0"`、`to="90"`、采样中点
- **THEN** 目标 `transform` 等价于 `rotate(45)`

#### Scenario: 缩放动画

- **WHEN** `type="scale"`、`from="1 1"`、`to="2 3"`、采样中点
- **THEN** 目标 `transform` 等价于 `scale(1.5 2)`

#### Scenario: 叠加基础变换

- **WHEN** 元素已有 `transform="translate(10,0)"`、动画 `type="rotate"`、`additive="sum"`
- **THEN** 最终矩阵为 `translate(10,0) × rotate(...)`

### Requirement: animateMotion

`animateMotion` SHALL 让目标元素沿 `path` 或 `mpath` 引用路径移动。

`rotate` 缺省 SHALL 为 `0`（不旋转）；`auto` SHALL 让元素 x 轴对齐路径切线；`auto-reverse` SHALL 反向对齐；角度值 SHALL 叠加到切线角。

`keyPoints` 与 `keyTimes` 配合 SHALL 控制沿路径的进度分布；缺省 SHALL 按路径长度匀速。

#### Scenario: 直线运动

- **WHEN** `path="M0 0 L100 0"`、`dur="1s"`，采样 0.5 秒
- **THEN** 目标元素平移约 `(50, 0)`

#### Scenario: auto 旋转

- **WHEN** 路径为 `M0 0 L0 100`、`rotate="auto"`
- **THEN** 元素旋转 90 度

#### Scenario: 角度旋转

- **WHEN** `rotate="45"`
- **THEN** 元素在路径切线上额外旋转 45 度

### Requirement: 采样快照

系统 SHALL 提供 `SvgTimeline.init(document, clock!)`、`duration()`、`animations()`、`sample(time)`、`sampleCurrent()`。

`sample(time)` SHALL 返回应用了该时刻动画值的**新** `SvgDocument`，原文档的属性与结构 SHALL 保持不变。`sampleCurrent()` SHALL 使用 `SvgClock.now()` 作为采样时间。

`duration()` SHALL 返回所有动画的最晚结束时间；没有动画时 SHALL 返回 0。

同一元素存在多个动画时 SHALL 按 `begin` 排序，后者覆盖前者；`additive="sum"` 时叠加。

#### Scenario: 不修改原文档

- **WHEN** 对含 `animate` 的文档调用 `sample(0.5)`
- **THEN** 快照中目标属性为插值结果，原文档属性仍为原始值

#### Scenario: 时长

- **WHEN** 两个动画分别结束于 1.0 秒与 2.5 秒
- **THEN** `duration()` 为 2.5

#### Scenario: 无动画

- **WHEN** 文档不含动画
- **THEN** `duration()` 为 0，`animations()` 为空，`sample(1.0)` 返回与原文档结构等价的快照

#### Scenario: 手动时钟

- **WHEN** `SvgManualClock(time: 0.5)` 且 `sampleCurrent()`
- **THEN** 等价于 `sample(0.5)`

### Requirement: 动画规模上限

单个动画的 `values` 项数 SHALL 不超过 10000；动画引用解析（`mpath` 指向的元素链）深度 SHALL 不超过 64。

超过上限 SHALL 抛 `SvgException(kind: Limit)`，不得静默截断。

#### Scenario: values 过多

- **WHEN** 一个 `animate` 的 `values` 包含 10001 项
- **THEN** 构建时间轴时抛 `SvgException(kind: Limit)`

#### Scenario: 引用链过深

- **WHEN** `mpath` 指向的元素经 65 层嵌套 `use` 才能到达目标路径
- **THEN** 构建时间轴时抛 `SvgException(kind: Limit)`
