# Design

## 1. 模式判定

读取所有系列后统一判定：全部数值数组 → 类目模式；全部 `{x,y}` → 连续模式；混合抛 `InvalidValue`。

## 2. 比例尺

- 类目：`BandScale`，点在 `band.center(i)`。
- 数值/时间：`LinearScale`，x 范围为数据 min/max 各留 5%；时间先转成 1970-01-01 起的天数。
- y 范围：显式 min/max 优先；否则 min/max 各留 5%，不强制包含 0。

## 3. 路径

- 按 null 分段；每段 `M` 起点后逐点 `L`。
- `smooth` 时用 `M p0 Q p1 p2 ...`（每个数据点作为控制点，终点落在下一点）。
- 颜色取 `series.color` 或调色板；线宽默认 2。
- 符号用 `ChartSvgKit.circle/square/diamond`，class `symbol`。

## 4. 轴

- 类目轴复用 `ChartFrame.drawXAxis`。
- 数值/时间轴新增 `drawXAxisNumeric`：轴线、刻度线、标签（可旋转）、轴标题。

## 5. 时间

`ChartTime.parseDays` 支持 `YYYY-MM-DD` 与 `YYYY-MM-DDTHH:MM:SS`（忽略时间部分），返回 1970 起的天数；`formatDays` 反向格式化，刻度按天取整。
