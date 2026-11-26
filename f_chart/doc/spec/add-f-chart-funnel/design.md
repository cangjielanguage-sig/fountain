# Design

## 1. 归一化

最大值为基准，阶段宽度 = `value / maxValue × 可用宽度`。阶段从上到下按输入顺序排列。

## 2. 阶段条

- 每个阶段条宽度 = `value / maxValue × 可用宽度`，高度按阶段均分。
- 相邻阶段条之间留 `gap` 像素。
- 矩形 class `funnel-stage`，阶段值以文本显示在条内。

## 3. 标签

- 阶段名称与值放在梯形中心，class `stage-label`。
- 转化率文本放在两阶段之间居中，class `conversion-label`。
