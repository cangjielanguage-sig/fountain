## ADDED Requirements

### Requirement: SHAP 解释图

渲染器 MUST 支持 `type` 为 `shap` 的图表，使用水平条形展示单个样本各特征的 SHAP 贡献值。

#### Scenario: 基本绘制

- **WHEN** 输入 4 个特征、SHAP 值为 `0.32` / `-0.18` / `0.12` / `-0.05` 的 `shap`
- **THEN** 输出 4 个 `shap-bar`，其中 2 个 `shap-positive`、2 个 `shap-negative`

#### Scenario: 绝对值降序

- **WHEN** 输入上述数据
- **THEN** 从上到下的条形依次对应 `年龄`、`血压`、`BMI`、`血糖`

#### Scenario: 零基线

- **WHEN** 输入包含正负混合的 SHAP 值
- **THEN** 输出 1 条 `shap-zero` 垂直虚线作为零基线

#### Scenario: 数值标注

- **WHEN** 输入任意合法数据
- **THEN** 每个条形端部 MUST 输出 1 个 `shap-label` 文本，内容为该特征 SHAP 值

#### Scenario: 空数据

- **WHEN** `series[0].data` 为空数组
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`

#### Scenario: 类型不匹配

- **WHEN** `type` 不是 `shap`
- **THEN** 抛出 `ChartException`，`kind` 为 `UnsupportedChart`

### Requirement: SHAP 字段校验

渲染器 MUST 校验 `features` 与数据项字段的合法性。

#### Scenario: 缺少 value

- **WHEN** 数据项缺少 `value` 字段
- **THEN** 抛出 `ChartException`，`kind` 为 `MissingField`

#### Scenario: 特征名为空

- **WHEN** 数据项 `feature` 为空字符串
- **THEN** 抛出 `ChartException`，`kind` 为 `InvalidValue`
