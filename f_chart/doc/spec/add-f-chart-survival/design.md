# Design

## 1. 数据

- 每个系列解析为 `SurvivalPoint(time, survival, censored)`，按 `time` 升序稳定排序。
- 校验 `time >= 0`、`0 <= survival <= 1`。

## 2. 坐标

- x 轴默认 `[0, maxTime * 1.02]`，`xAxis.min` / `max` 优先。
- y 轴默认 `[0, 1]`，`yAxis.min` / `max` 优先。
- 刻度用 `chartNiceTicks`。

## 3. 阶梯线

从首点开始，对每个后续点先画水平段到新时间点、再画垂直段到新生存率，class `survival-line`。

## 4. 置信带近似

没有风险人数时按二项分布近似：

```
se = sqrt(S * (1 - S) / n)
lower = max(0, S - 1.96 * se)
upper = min(1, S + 1.96 * se)
```

`n` 取系列数据点数。多边形沿上界正向、下界反向闭合，class `survival-band`，透明度 0.15。

## 5. 删失

`censored` 为 true 且 `showCensors` 为 true 时，在点位置写 `+`，class `survival-censor`。
