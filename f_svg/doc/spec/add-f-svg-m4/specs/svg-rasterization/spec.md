# svg-rasterization

## ADDED Requirements

### Requirement: vector-effect 非缩放描边

系统 SHALL 支持 `vector-effect: non-scaling-stroke`：

- 描边宽度 SHALL 按设备空间解释，换算到用户空间的宽度为 `stroke-width / sqrt(|det(CTM)|)`；
- 虚线数组与偏移 SHALL 同样按设备空间解释，即各分量除以 `sqrt(|det(CTM)|)`；
- 该效果 SHALL 只影响描边，不影响填充几何；
- `none` SHALL 保持既有行为；
- 其他取值 SHALL 记 warning 并按 `none` 处理；
- CTM 行列式为 0 或不可逆时 SHALL 按 `none` 处理并记 warning。

#### Scenario: 整体缩放

- **WHEN** 元素 `transform="scale(2)"`、`stroke-width="4"`、`vector-effect="non-scaling-stroke"`
- **THEN** 设备空间描边宽度为 4，与未缩放元素相同

#### Scenario: 非均匀缩放

- **WHEN** `transform="scale(2,1)"`、`stroke-width="4"`、`vector-effect="non-scaling-stroke"`
- **THEN** 用户空间描边宽度为 `4 / sqrt(2)`，设备空间宽度约为 `4 × sqrt(2)`

#### Scenario: 虚线不缩放

- **WHEN** `stroke-dasharray="4 2"`、`transform="scale(2)"`、`non-scaling-stroke`
- **THEN** 设备空间每段虚线与间隔仍为 4 与 2

#### Scenario: 非法取值

- **WHEN** `vector-effect="scaling-stroke"`
- **THEN** 按 `none` 描边并追加 warning
