# Design

## 1. 分位点

- 样本排序后 `p_i = (i + 0.5) / n`。
- `normalQuantile` 用 Acklam 有理逼近；`p` 钳制到 `(1e-12, 1-1e-12)`。
- `uniform` 返回 `p`；`exponential` 返回 `-ln(1-p)`。

## 2. 参考线

- 对散点做最小二乘拟合 `y = a + b x`；方差为 0 时取水平线。
- 线覆盖 x 轴范围，class `qq-line`，虚线 `4 4`。

## 3. 轴

- x 轴为理论分位数、y 轴为样本分位数；各自留 5% 余量，显式 min/max 优先。
- 复用 `drawXAxisNumeric` 与 `drawYAxis`。
