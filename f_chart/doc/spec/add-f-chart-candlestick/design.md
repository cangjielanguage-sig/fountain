# Design

## 1. 数据

解析 `series[0].data` 的 `date`、`open`、`high`、`low`、`close`；校验 `high >= max(open, close, low)`、`low <= min(open, close)`。

## 2. 轴

- 横轴 `BandScale`，类目取 `xAxis.labels`，缺省用各项 `date`。
- 纵轴 `LinearScale`，范围覆盖全部 `high` / `low`，缺省上下各留 5%。

## 3. 图元

- 影线：类目中心竖线，从 `high` 到 `low`，线宽 1px。
- 实体：宽度取 `bandWidth * 0.6`，从 `open` 到 `close`；高度为 0 时按 1px 绘制。
- 上涨（`close >= open`）填充 `#e53935`，下跌填充 `#43a047`；影线同色。

## 4. 校验

`series` 数量不为 1、`data` 为空、四个价格缺失或非数字、价格区间矛盾、类目长度不匹配均抛 `ChartException`。
