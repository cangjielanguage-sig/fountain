# Design

## 1. 比例

`cartogramScale(value, maxValue, scaleBy)`：

- `maxValue <= 0` 时返回 1。
- `scaleBy == "value"`：`value / maxValue`。
- 否则：`sqrt(value / maxValue)`。

## 2. 变换

每个区域用一个 `<g>` 包裹 path，transform 为：

```
translate(cx, cy) scale(f) translate(-cx, -cy)
```

`cx, cy` 取 region 的 `centroid`，缺省用 `pathCentroid`。

## 3. 配色

按 `value / maxValue` 用 `heatFlameColor` 在 `colorRange` 上插值；默认 `["#e8f1fb", "#7fb3d5", "#1f4e79"]`。
