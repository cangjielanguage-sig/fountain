# Spec Delta

## ADDED Requirements

### Requirement: 蜡烛图影线与实体

`CandlestickChart` MUST 为每个数据项输出一条 `class="candlestick-wick"` 竖线（`high` 到 `low`）与一个 `class="candlestick-body"` 矩形（`open` 到 `close`）。

#### Scenario: 四根蜡烛

- **WHEN** `data` 有 4 项
- **THEN** 输出 4 条 `candlestick-wick` 与 4 个 `candlestick-body`

### Requirement: 蜡烛图涨跌标识

`candlestickUp` MUST 在 `close >= open` 时返回 `true`；上涨实体的 class MUST 附加 `candlestick-up`，下跌附加 `candlestick-down`。

#### Scenario: 上涨判定

- **WHEN** open 为 100、close 为 105
- **THEN** `candlestickUp` 返回 `true`

#### Scenario: 平盘判定

- **WHEN** open 与 close 均为 100
- **THEN** `candlestickUp` 返回 `true`

### Requirement: 蜡烛图价格范围

纵轴范围 MUST 覆盖所有 `high` 与 `low`；`yAxis.min` / `yAxis.max` 给出时 MUST 按给定值。

#### Scenario: 缺省范围

- **WHEN** 数据 high 最大 110、low 最小 98
- **THEN** 纵轴范围包含 98 到 110

### Requirement: 蜡烛图校验

`series` MUST 恰好 1 个且 `data` MUST 非空；每项 MUST 提供数字型 `open`、`high`、`low`、`close`；`high` MUST 不小于 `open`、`close`、`low`，`low` MUST 不大于 `open`、`close`；`xAxis.labels` 非空时长度 MUST 等于 `data` 长度；`type` 不匹配抛 `UnsupportedChart`。

#### Scenario: 最高价过低

- **WHEN** 某根 `high` 小于 `close`
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

#### Scenario: 缺少收盘价

- **WHEN** 某个数据项没有 `close`
- **THEN** 抛出 `ChartException`，`kind` 为 `MissingField`
