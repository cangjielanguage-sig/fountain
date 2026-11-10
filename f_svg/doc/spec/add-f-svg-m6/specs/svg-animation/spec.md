# svg-animation

## MODIFIED Requirements

### Requirement: 时间模型

时间值 SHALL 支持秒（`s`）、毫秒（`ms`）与小数值；`indefinite` SHALL 表示永不结束。

`begin` / `end` SHALL 支持：绝对偏移（`0s`、`1.5s`、`500ms`）、`id.begin`、`id.end`、`indefinite`；事件型时间项（`click`、`mouseover`、`accessKey`、`wallclock` 等）SHALL 被保留为待触发项，在未调用 `fireEvent` 时 SHALL NOT 激活动画。

`dur` 缺省 SHALL 为 `indefinite`；`repeatCount` SHALL 支持正数与 `indefinite`；`repeatDur` SHALL 截断总活动时长。

`fill` SHALL 支持 `remove`（默认，结束后恢复基础值）与 `freeze`（结束后保持末值）。

`begin="indefinite"` 的动画 SHALL NOT 自行开始，只有显式 `begin(id)` 或匹配的 `fireEvent` 才进入活动状态。

#### Scenario: 毫秒解析

- **WHEN** `dur="500ms"`、`begin="1.5s"`
- **THEN** 动画从 1.5 秒开始，持续 0.5 秒

#### Scenario: id.begin

- **WHEN** 动画 A 的 `begin="0s"`、`dur="1s"`，动画 B 的 `begin="A.end"`
- **THEN** B 从 1.0 秒开始

#### Scenario: 重复次数

- **WHEN** `dur="1s"`、`repeatCount="2.5"`、`fill="remove"`
- **THEN** 动画在 2.5 秒后结束，2.6 秒时恢复基础值

#### Scenario: repeatDur 截断

- **WHEN** `dur="1s"`、`repeatCount="indefinite"`、`repeatDur="2.5s"`
- **THEN** 动画在 2.5 秒后结束，不再重复

#### Scenario: fill freeze

- **WHEN** 同上但 `fill="freeze"`
- **THEN** 2.6 秒时保持末值

#### Scenario: 事件型 begin

- **WHEN** `begin="click"`，未调用 `fireEvent`
- **THEN** 动画不活动，不产生「已忽略」warning

#### Scenario: begin indefinite

- **WHEN** `begin="indefinite"`、`dur="1s"`，采样 10 秒且未调用 `begin(id)`
- **THEN** 动画从未开始，目标属性保持基础值

### Requirement: 采样快照

系统 SHALL 提供 `SvgTimeline.init(document, clock!)`、`duration()`、`animations()`、`sample(time)`、`sampleCurrent()`，以及 M6 的 `begin(id)` / `end(id)` / `fireEvent(id, event)` / `currentTime()` / `setCurrentTime(time)` / `pause()` / `unpause()`。

`sample(time)` SHALL 返回应用了该时刻动画值的**新** `SvgDocument`，原文档的属性与结构 SHALL 保持不变。`sampleCurrent()` SHALL 使用 `currentTime()` 作为采样时间；未暂停且未显式设置时间时等于 `SvgClock.now()`。

`duration()` SHALL 返回所有动画的最晚结束时间；没有动画时 SHALL 返回 0；结束时间为 `indefinite` 的动画 SHALL 被忽略，若全部动画都是 `indefinite` 则返回 0。

`animations()` SHALL 返回 `SvgAnimationInfo` 列表，每项包含 `targetId`、`attributeName`、`begin`、`end` 与 `kind`；`kind` 取值 SHALL 为 `Animate` / `AnimateTransform` / `AnimateMotion` / `Set` 之一。

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

#### Scenario: 仅无限动画

- **WHEN** 文档只有一个 `dur="indefinite"` 的动画
- **THEN** `duration()` 为 0

#### Scenario: 手动时钟

- **WHEN** `SvgManualClock(time: 0.5)` 且 `sampleCurrent()`
- **THEN** 等价于 `sample(0.5)`

#### Scenario: sample 语义不变

- **WHEN** 对 M5 既有动画文档调用 `sample(t)`
- **THEN** 输出与 M5 逐字节一致

## ADDED Requirements

### Requirement: M6 动画触发与时间控制

`begin(id)` SHALL 以 `currentTime()` 记录该动画的开始时刻，对 `begin="indefinite"` 与事件型 `begin` 的动画生效；`end(id)` SHALL 立即结束该动画，`fill="freeze"` 时保持末值。未知 id SHALL warning 且无副作用。

`fireEvent(id, event)` SHALL 对 `begin` 或 `end` 列表中包含该事件名的动画等价于 `begin(id)` 或 `end(id)`；事件名比较 SHALL 大小写不敏感；未匹配任何时间项时 SHALL 无副作用。

`currentTime()` SHALL 返回当前文档时间；`setCurrentTime(t)` SHALL 设置显式时间并覆盖时钟（负值按 0 处理，非有限值抛 `InvalidValue`）；`pause()` SHALL 冻结 `currentTime()`，重复调用无副作用；`unpause()` SHALL 从冻结时刻继续计时。

#### Scenario: 显式开始 indefinite

- **WHEN** `begin="indefinite"`、`dur="2s"`，在 `currentTime = 5` 时调用 `begin("a")`
- **THEN** `sample(5)` 处于起点，`sample(7)` 处于终点

#### Scenario: 显式结束

- **WHEN** 动画活动期间调用 `end("a")`
- **THEN** 之后的采样不再应用该动画；`fill="freeze"` 时保持末值

#### Scenario: 未知 id

- **WHEN** `begin("missing")`
- **THEN** 追加 warning，其他动画不受影响

#### Scenario: 事件触发

- **WHEN** `begin="click"`，调用 `fireEvent("a", "click")`
- **THEN** 与调用 `begin("a")` 等价

#### Scenario: 事件未匹配

- **WHEN** `begin="click"`，调用 `fireEvent("a", "mouseover")`
- **THEN** 动画不开始，无 warning

#### Scenario: 设置时间

- **WHEN** `setCurrentTime(3.5)` 后调用 `sampleCurrent()`
- **THEN** 等价于 `sample(3.5)`

#### Scenario: 非法时间

- **WHEN** `setCurrentTime(-1)` 与 `setCurrentTime(Float64.NaN)`
- **THEN** 前者按 0 处理，后者抛 `InvalidValue`

#### Scenario: 暂停与恢复

- **WHEN** 时钟推进到 2 秒时 `pause()`，时钟继续推进到 10 秒后再 `unpause()`
- **THEN** `pause` 期间 `currentTime()` 恒为 2，`unpause` 后从 2 继续

### Requirement: M6 动画写入类型

动画 SHALL 支持 `attributeType`：`XML`（缺省）把结果写为目标元素的属性；`CSS` 把结果写入目标元素的内联样式覆盖层，使计算样式的优先级高于样式表。非法值 SHALL 回退 `XML` 并 warning。

#### Scenario: XML 默认

- **WHEN** 未声明 `attributeType`，动画 `attributeName="fill"`
- **THEN** 快照中目标元素的 `fill` 属性为动画值，内联样式不变

#### Scenario: CSS 写入

- **WHEN** `attributeType="CSS"`，动画 `attributeName="fill"`，样式表同时声明 `fill: blue`
- **THEN** 快照的计算样式 `fill` 为动画值

#### Scenario: 保留既有内联样式

- **WHEN** 目标元素已有 `style="stroke: red"`，`attributeType="CSS"` 动画 `fill`
- **THEN** 快照内联样式同时含 `stroke: red` 与动画 `fill`

#### Scenario: 非法值

- **WHEN** `attributeType="AUTO"`
- **THEN** 按 `XML` 处理并 warning

### Requirement: M6 活动时长钳制

动画 SHALL 支持 `min` 与 `max` 时间值：生效活动时长 SHALL 为 `min(max, max(min, dur × repeatCount))`；`min` 缺省 0，`max` 缺省 `indefinite`。`min > max` 时 SHALL warning 并忽略两者。`max` 小于单次 `dur` 时 SHALL 在 `max` 处截断。

#### Scenario: max 截断

- **WHEN** `dur="10s"`、`max="3s"`
- **THEN** 动画在 3 秒后结束

#### Scenario: min 延长

- **WHEN** `dur="1s"`、`repeatCount="1"`、`min="3s"`
- **THEN** 动画活动到 3 秒

#### Scenario: min 大于 max

- **WHEN** `min="5s"`、`max="2s"`
- **THEN** 两者被忽略，按无 `min` / `max` 处理并 warning

#### Scenario: 缺省

- **WHEN** 未声明 `min` / `max`
- **THEN** 活动时长与 M5 一致

### Requirement: M6 discard 快照移除

`discard` SHALL 在 `currentTime()` 到达其 `begin + dur` 后把目标元素从采样快照中移除；目标缺失或时间未到 SHALL 无副作用。`discard` SHALL NOT 传播到后代或引用实例，嵌套 `discard` 深度大于 1 时 SHALL warning 并只处理最外层。

#### Scenario: 到时移除

- **WHEN** `<discard begin="1s" dur="1s"/>` 指向矩形，采样 2.5 秒
- **THEN** 快照中不含该矩形

#### Scenario: 未到时保留

- **WHEN** 同一文档采样 0.5 秒
- **THEN** 矩形仍在快照中

#### Scenario: 目标缺失

- **WHEN** `discard` 指向不存在的 id
- **THEN** 无副作用，不抛异常

#### Scenario: 嵌套深度

- **WHEN** 两个 `discard` 嵌套且内层也要移除元素
- **THEN** 只处理最外层并 warning
