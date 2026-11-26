# svg-filter

## ADDED Requirements

### Requirement: feDropShadow 投影原语

系统 SHALL 支持 `<feDropShadow>`，并提供 `dx`、`dy`、`stdDeviation`、`flood-color`、`flood-opacity` 的类型化读写；缺省值 SHALL 为 `dx=2`、`dy=2`、`stdDeviation=2`、`flood-color=black`、`flood-opacity=1`。

`feDropShadow` SHALL 等价于「取输入 alpha → 高斯模糊 → 按 `dx` / `dy` 偏移 → 用 flood 颜色与 `flood-opacity` 着色 → 与原图 `source-over` 合并」。系统 SHALL 复用既有高斯模糊、洪水填充与合并原语，不引入新的像素算法。

#### Scenario: 默认投影

- **WHEN** 不透明红色矩形应用空 `<feDropShadow/>`
- **THEN** 原图右下方出现黑色半透明阴影，原图保持红色

#### Scenario: 偏移与模糊

- **WHEN** `dx="10" dy="0" stdDeviation="0"`
- **THEN** 阴影为向右平移 10 的硬边副本，不出现模糊过渡像素

#### Scenario: 洪水透明度

- **WHEN** `flood-color="blue"`、`flood-opacity="0.5"`
- **THEN** 阴影为 50% 不透明蓝色，原图不受影响

#### Scenario: 确定性

- **WHEN** 同一投影滤镜连续渲染两次
- **THEN** 两次位图逐字节一致

### Requirement: feDropShadow 参数与区域

`stdDeviation` SHALL 接受 1 或 2 个非负数；负值、非有限值与非法颜色 SHALL 回退对应缺省值并记 warning。

滤镜区域 SHALL 由 `filterUnits` 与 `x` / `y` / `width` / `height` 决定，并 SHALL 容纳偏移与模糊外扩；越出区域的部分 SHALL 被裁剪。

#### Scenario: 非法参数

- **WHEN** `stdDeviation="-1"` 与 `flood-color="not-a-color"`
- **THEN** 分别回退 `2` 与黑色，各追加一条 warning，渲染继续

#### Scenario: 区域裁剪

- **WHEN** 小尺寸滤镜区域与 `dx="30"` 同时使用
- **THEN** 阴影超出区域的部分不被绘制
