# svg-paint-and-clip

## ADDED Requirements

### Requirement: 图案元素

系统 SHALL 提供 `SvgPattern <: SvgContainer`，`kind` 为 `SvgContainerKind.Pattern`，包含 `x` / `y` / `width` / `height`（`?SvgLength`）、`patternUnits` / `patternContentUnits`（`SvgCoordinateUnits`）、`patternTransform: ?SvgTransform` 与 `href: ?String`。

`patternUnits` 缺省为 `ObjectBoundingBox`，`patternContentUnits` 缺省为 `UserSpaceOnUse`。`x` / `y` 缺省 0，`width` / `height` 缺省 0。

`SvgPaint.Reference` 指向 `pattern` 元素时，`fill` / `stroke` SHALL 使用图案取样器绘制，而不是回退为 `none`。

#### Scenario: 图案作为填充

- **WHEN** 矩形 `fill="url(#p)"` 且 `#p` 为 20×20 的 pattern
- **THEN** 矩形内部按 20×20 周期出现图案颜色，而不是空白

### Requirement: 图案引用继承

`href` 继承 SHALL 逐属性进行：自身已设置的属性优先，缺失项从被引用 pattern 递归取；引用链循环时 SHALL 记 warning 并停止继承，已解析部分仍然生效。

#### Scenario: href 继承

- **WHEN** pattern A 设置 `patternUnits` 与 `width`，pattern B 只设置 `href="#A"` 与 `height`
- **THEN** B 继承 A 的 `patternUnits` 与 `width`，使用自身的 `height`

#### Scenario: 循环引用

- **WHEN** A 的 `href` 指向 B，B 的 `href` 指向 A
- **THEN** 继承在检测到循环时停止，追加 warning，渲染不递归崩溃

### Requirement: 图案平铺与坐标

系统 SHALL 提供 `SvgPatternSampler`（`init(registry!)`）与 `sample(pattern, objectBounds, transform, options)`，返回可平铺的 `SvgBitmap`，或在不合法时返回 `None`。

平铺 SHALL 遵守：

- `patternUnits="objectBoundingBox"` 时，`x` / `y` / `width` / `height` 先按元素包围盒换算为 tile 尺寸；
- `patternContentUnits` 决定 pattern 子内容的坐标空间；
- `patternTransform` SHALL 在 tile 采样前作用于 tile，使图案可旋转 / 缩放 / 平移；
- 平铺结果 SHALL 裁剪到当前填充区域，不越过路径边界；
- 图案 SHALL 按 sRGB 通道直接取样，不做额外插值补偿。

#### Scenario: tile 尺寸

- **WHEN** `patternUnits="objectBoundingBox"`、`width="0.5"`、`height="0.5"`，元素包围盒为 100×100
- **THEN** tile 尺寸为 50×50

#### Scenario: patternTransform 旋转

- **WHEN** `patternTransform="rotate(45)"` 且 tile 为两色相间条纹
- **THEN** 填充区域内的条纹方向相对未旋转时旋转 45°

#### Scenario: 裁剪到填充区域

- **WHEN** 圆形 `fill="url(#p)"` 且 pattern 覆盖整个画布
- **THEN** 圆外区域不出现图案像素

### Requirement: 图案上限与降级

`width` 或 `height` ≤ 0、或换算后的 tile 宽高 ≤ 0 时，图案 SHALL 不绘制，追加 warning，并保持目标像素透明。

tile 像素数超过 `4 × 1024 × 1024` 时 SHALL 抛 `SvgException(kind: Limit)`。

pattern 引用深度超过 64 时 SHALL 抛 `SvgException(kind: Limit)`。

pattern 元素的子内容渲染失败时 SHALL 降级为不绘制并记 warning，不中断整个文档渲染。

#### Scenario: 空 tile

- **WHEN** `width="0"` 的 pattern 被引用为 `fill`
- **THEN** 目标区域全透明，`warnings` 含空 tile 告警

#### Scenario: 超大 tile

- **WHEN** 换算后 tile 像素数超过上限
- **THEN** 抛 `SvgException(kind: Limit)`，不分配 tile 缓冲

#### Scenario: 渲染失败降级

- **WHEN** pattern 子内容引用不存在的裁剪路径
- **THEN** 该图案不绘制并追加 warning，文档其余元素正常渲染
