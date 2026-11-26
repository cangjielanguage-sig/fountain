# Design

## 1. 分层

初始化所有节点层级为 0；对每条边执行 `layer[target] = max(layer[target], layer[source]+1)`，重复节点数轮以覆盖长链。

## 2. 布局

- 每层 x 等距；节点宽度 `nodeWidth`，层间留白。
- 层内节点按吞吐量高度堆叠，`nodeGap` 分隔。
- 吞吐量取 `max(sumIn, sumOut)`。

## 3. 流量带

- 从源节点右缘到目标节点左缘绘制三次贝塞尔带，线宽按 `value / maxFlow` 缩放。
- 颜色取源节点调色板颜色。
