# Design

## 1. 数据

解析 `series[0].data` 的 `x`、`y`、可选 `label`；`foldChangeThreshold` 与 `pThreshold` 必须非负。

## 2. 分类

`volcanoCategory(x, y, foldChangeThreshold, pThreshold)` 返回 `up` / `down` / `none`，边界值计入显著。

## 3. 轴与参考线

- x 轴范围覆盖全部 `x` 与两条阈值线，两侧各留 5%。
- y 轴范围覆盖全部 `y` 与 `pThreshold`，上下各留 8%。
- 三条阈值线为虚线、颜色 `#bdbdbd`，线宽 1px。

## 4. 绘制

散点半径 4px，颜色按分类；显著项在点右侧 6px 处绘制标签，超过 10 个字符截断。

## 5. 校验

`series` 数量不为 1、`data` 为空、`x`/`y` 缺失或非数字、阈值为负均抛 `ChartException`。
