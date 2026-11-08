# Design

## 1. 节点布局

- 按排序后的节点顺序，在 `[-π/2, 3π/2)` 上均匀分布角度。
- 半径取绘图区短边的 0.35 倍，圆心取绘图区中心。

## 2. 弧线

每条链接从 source 点到 target 点画二次贝塞尔曲线，控制点取两点中点向圆心收缩：

```
control = midpoint + (center - midpoint) * arcHeight
```

`arcHeight` 为 0 时退化为直线。

## 3. 排序

`arcNodeOrder(totals)` 用稳定插入排序返回按总流量降序的下标数组。总流量为节点作为 source 或 target 的 value 之和。
