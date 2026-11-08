## Context

仪表盘以极坐标圆弧表达单一指标。SVG 圆弧需要显式的 `large-arc-flag`，且 `y` 轴向下导致角度方向与数学坐标系相反。实现集中在角度映射与圆弧路径两个纯函数上，便于直接测试。

## Decisions

### 参数

- `min` 默认 `0`、`max` 默认 `100`，要求 `max > min`。
- `startAngle` 默认 `-120`、`endAngle` 默认 `120`，要求 `startAngle < endAngle`。
- `thresholds` 可空；非空时每项 `value` 必须严格递增且落在 `(min, max]`；`color` 缺省取主题调色板。

### 角度映射

`gaugeAngleForValue(value, min, max, startAngle, endAngle)` 为线性映射：
`startAngle + (value - min) / (max - min) × (endAngle - startAngle)`。

### 圆弧

- 圆心取绘图区中心，外半径取 `min(plot.width, plot.height) × 0.42`，内半径取外半径的 `0.62`。
- `gaugeArcPath` 生成环形扇段：外弧 `sweep-flag = 1`、内弧回退 `sweep-flag = 0`，扫过角度大于 180° 时 `large-arc-flag = 1`。
- 色带按阈值从 `min` 依次绘制到各阈值；无阈值时单段 `min → max`。

### 指针与文本

- 指针从圆心指向数值角度、长度为外半径的 `0.92`，线宽 3px。
- 中心数值使用标题字号加粗色，指标名置于数值下方。

## Risks

- 角度跨越 ±180° 时 `large-arc-flag` 容易算错；通过比较 `abs(end - start) > 180` 判定。
- 阈值色带与数值弧重叠；只绘制色带 + 指针，避免双弧干扰读数。

## Testing

- 覆盖色带数量、指针与数值文本、默认量程/角度、无阈值单段、越界数值、非法量程/角度/阈值与类型。
- 直接测试 `gaugeAngleForValue` 与 `gaugeArcPath` 的端点。
- 全量回归在签名后执行 `cjpm test --skip-build`。
