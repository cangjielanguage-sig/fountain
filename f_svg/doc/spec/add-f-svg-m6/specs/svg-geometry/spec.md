# svg-geometry

## ADDED Requirements

### Requirement: M6 命中测试

系统 SHALL 提供 `SvgHitTest.elementsAt(root, point, viewport, styles)` 与 `SvgHitTest.elementAt(...)`。`point` SHALL 为设备像素坐标，按 `viewport` 的矩阵逆与 `devicePixelRatio` 换算到用户空间。返回列表 SHALL 按绘制顺序从上到下排列，`elementAt` 返回其中第一个；未命中的文档 SHALL 返回空列表与 `None`。

#### Scenario: 顶层优先

- **WHEN** 两个重叠矩形，后绘制者覆盖先绘制者，点落在重叠区
- **THEN** 返回列表首项为后绘制的矩形

#### Scenario: 设备坐标换算

- **WHEN** `viewport` 含 2 倍 DPR 与平移，点以设备像素给出
- **THEN** 换算后的用户空间点与直接使用逻辑坐标的结果一致

#### Scenario: 空文档

- **WHEN** 点在所有元素之外
- **THEN** `elementsAt` 返回空列表，`elementAt` 返回 `None`

### Requirement: M6 命中语义

命中判定 SHALL 遵循 `pointer-events`：`none` 的元素及其子树不参与；`visible*` 要求 `visibility != hidden`；`painted` 要求 `fill` 或 `stroke` 非 `none`；`bounding-box` 使用包围盒；`visible` 命中内区或描边几何，但不要求 `fill` / `stroke` 非 `none`；其余使用路径 / 描边区域；`auto` 等价 `visiblePainted`。`image` 使用矩形，`text` 使用字形轮廓，容器仅在自身 `pointer-events` 允许包围盒命中时参与。

#### Scenario: pointer-events: none

- **WHEN** 上层矩形的祖先组声明 `pointer-events: none`
- **THEN** 该组及其全部后代不出现在返回列表，下层矩形可被命中

#### Scenario: 仅描边命中

- **WHEN** 元素 `fill="none"`、`pointer-events="visibleStroke"`，点落在填充区内部
- **THEN** 不命中；点落在描边上时命中

#### Scenario: bounding-box

- **WHEN** 元素 `pointer-events="bounding-box"`，点落在包围盒内但路径外
- **THEN** 命中

#### Scenario: 隐藏元素

- **WHEN** 元素 `visibility="hidden"`、`pointer-events="visibleFill"`
- **THEN** 不命中；`pointer-events="all"` 时命中

#### Scenario: auto 等价 visiblePainted

- **WHEN** 元素 `visibility="hidden"` 且未声明 `pointer-events`
- **THEN** 不命中

### Requirement: M6 pathLength 校准

`pathLength` SHALL 接受正有限数值；`<= 0`、非有限或无法解析时 SHALL 忽略并 warning。存在合法 `pathLength` 时，系统 SHALL 以 `scale = 实际弧长 / pathLength` 校准该路径上的距离量，使声明单位与实际弧长一致。

#### Scenario: 校准比例

- **WHEN** 路径实际弧长 200、`pathLength="100"`
- **THEN** 校准比例为 2

#### Scenario: 斜率相同

- **WHEN** 路径实际弧长 100、`pathLength="100"`
- **THEN** 校准比例为 1，输出与未声明时逐字节一致

#### Scenario: 非法值

- **WHEN** `pathLength="0"`、`pathLength="-5"` 或 `pathLength="abc"`
- **THEN** 比例按 1 处理并各产生一条 warning

#### Scenario: 缺失属性

- **WHEN** 未声明 `pathLength`
- **THEN** 比例为 1，不产生 warning

### Requirement: M6 矢量效果几何语义

`vector-effect` 新增值 SHALL 按以下语义修改元素的有效变换：`non-scaling-size` 仅保留平移与旋转分量；`non-rotation` 去除旋转分量；`fixed-position` 固定元素在设备空间的位置，不随祖先变换移动。多个值同时声明时 SHALL 按 `non-scaling-size` → `non-rotation` → `fixed-position` 的顺序依次应用。

#### Scenario: 去缩放

- **WHEN** 祖先 `scale(3)`，元素 `vector-effect="non-scaling-size"`
- **THEN** 元素几何在设备空间保持原始尺寸，位置仍随平移

#### Scenario: 去旋转

- **WHEN** 祖先 `rotate(45)`，元素 `vector-effect="non-rotation"`
- **THEN** 元素几何不旋转，平移分量保留

#### Scenario: 固定位置

- **WHEN** 祖先 `translate(50, 30)`，元素 `vector-effect="fixed-position"`
- **THEN** 元素在设备空间的位置与无该祖先时一致

#### Scenario: 组合顺序

- **WHEN** 同时声明三个新值且祖先含缩放、旋转与平移
- **THEN** 结果等于固定按 `non-scaling-size` → `non-rotation` → `fixed-position` 顺序应用三个修正后的矩阵，与声明顺序无关

#### Scenario: 既有值不受影响

- **WHEN** `vector-effect="non-scaling-stroke"` 或 `none`
- **THEN** 几何与 M4 逐字节一致
