# svg-marker

## ADDED Requirements

### Requirement: marker 模型

系统 SHALL 提供 `SvgMarker <: SvgContainer`，`kind` 为 `SvgContainerKind.Marker`，包含：

- `markerUnits: SvgMarkerUnits`（`StrokeWidth` / `UserSpaceOnUse`，缺省 `StrokeWidth`）；
- `refX` / `refY`（`?SvgLength`，缺省 0）；
- `markerWidth` / `markerHeight`（`?SvgLength`，缺省 3）；
- `orient: SvgMarkerOrient`（缺省 0 度）；
- `viewBox: ?SvgViewBox`；
- `preserveAspectRatio: SvgPreserveAspectRatio`（缺省 `xMidYMid meet`）。

上述属性 SHALL 可解析、可修改、可无损写回；`marker` 仍保留 `SvgContainer` 的既有行为与 `SvgContainerKind.Marker` 值。

#### Scenario: 缺省值

- **WHEN** 解析 `<marker id="m"><path d="M0 0L10 0"/></marker>`
- **THEN** `markerUnits == StrokeWidth`、`markerWidth == 3`、`markerHeight == 3`、`refX == 0`、`refY == 0`、`orient` 为 0 度

#### Scenario: 属性往返

- **WHEN** 设置 `markerUnits="userSpaceOnUse"`、`orient="auto"`、`refX="5"` 后写回再解析
- **THEN** 三个属性与设置值一致

### Requirement: marker 派生与定位

系统 SHALL 在渲染树展开阶段，对 `path` / `line` / `polyline` / `polygon` 的扁平化顶点派生 marker 实例：

- `marker-start` 应用于首个顶点；
- `marker-end` 应用于末个顶点；
- `marker-mid` 应用于除首末外的每个顶点；
- 闭合路径的末顶点与首顶点重合时，`marker-mid` 不重复派生同一顶点。

`refX` / `refY` SHALL 把 marker 内容坐标原点对齐到目标顶点；`viewBox` 与 `preserveAspectRatio` SHALL 复用 M1 的 `toMatrix` 生成内容矩阵。

`markerUnits="strokeWidth"` 时，marker 实例 SHALL 再乘以元素 `stroke-width`（缺省 1）；`userSpaceOnUse` 时不缩放。

#### Scenario: start 与 end 对齐

- **WHEN** 水平线从 `(0,0)` 到 `(10,0)`，`refX=0 refY=0`，marker 内容为 `(0,0)` 处的小方块
- **THEN** 两个方块分别以 `(0,0)` 与 `(10,0)` 为原点绘制

#### Scenario: mid 顶点

- **WHEN** `polyline` 顶点为 `(0,0)`、`(5,5)`、`(10,0)` 且设置 `marker-mid`
- **THEN** 只在 `(5,5)` 派生一个实例

#### Scenario: strokeWidth 缩放

- **WHEN** `markerUnits="strokeWidth"`、`stroke-width="4"`、`markerWidth="3"`
- **THEN** marker 实例的缩放系数为 4，绘制尺寸为 12 个用户单位

### Requirement: marker 朝向

`orient` SHALL 支持：

- `auto`：按目标顶点处的切线角旋转；起点使用离开方向，终点使用进入方向，中间点使用相邻两段方向的平分方向；
- `auto-start-reverse`：与 `auto` 相同，但 `marker-start` 额外旋转 180°；
- 固定角度：按给定角度旋转，不做切线计算。

零长度线段 SHALL 不改变切线角，并沿用前一段方向；整条路径只有一个点时按 0 度处理。

#### Scenario: auto 起点反向

- **WHEN** `marker-start` 使用 `orient="auto-start-reverse"`，路径从 `(0,0)` 向右延伸
- **THEN** 起点 marker 朝向为 180°

#### Scenario: 固定角度

- **WHEN** `orient="45"`
- **THEN** 所有 marker 实例旋转 45°，与路径方向无关

### Requirement: marker 效果与上限

marker 内容作为独立子树参与渲染，其中 `clipPath` / `mask` / `filter` SHALL 正常生效。

每个元素派生的 marker 实例数 SHALL 不超过 1024；超出时 SHALL 追加 warning 并停止继续派生，已派生实例仍正常绘制。

marker 引用链深度超过 64 时 SHALL 抛 `SvgException(kind: Limit)`；`href` 指向不存在的 marker 时 SHALL 不派生并记 warning。

#### Scenario: 数量上限

- **WHEN** 一条含 2000 个顶点的 `polyline` 同时设置 `marker-mid`
- **THEN** 最多绘制 1024 个 marker，`warnings` 含数量上限告警

#### Scenario: marker 内裁剪

- **WHEN** marker 内容引用一个 `clipPath`
- **THEN** 绘制结果按该裁剪路径裁剪

#### Scenario: 缺失引用

- **WHEN** `marker-end="url(#none)"`
- **THEN** 不绘制 marker 并追加 warning，元素本身正常绘制
