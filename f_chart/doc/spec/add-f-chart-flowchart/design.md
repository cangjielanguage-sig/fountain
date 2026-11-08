# Design

## 1. 解析

节点 id 必填，label 缺省为 id；边 source/target 必填并校验存在。节点尺寸缺省：rect/round/ellipse 120×48，diamond 100×70。

## 2. 分层

`levels[i]` 初始 0；对每条边执行 `levels[target] = max(levels[target], levels[source]+1)`，重复节点数次以处理长链；循环依赖在迭代上限内稳定。

## 3. 定位

- 每层节点在绘图区内水平均分，垂直层距 90。
- `manual` 直接使用节点 `x` / `y` 作为左上角。
- 边从源节点边界到目标节点边界，末端画箭头；边标签放中点。

## 4. 形状

rect / round 用矩形，diamond / parallelogram / document 用 path，ellipse 用 `<ellipse>`；节点先于边绘制（边在下）。
