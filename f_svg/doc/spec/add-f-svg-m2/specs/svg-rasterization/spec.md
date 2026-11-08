# svg-rasterization

## ADDED Requirements

### Requirement: 位图契约

系统 SHALL 提供 `SvgBitmap`，包含 `width`、`height` 与 RGBA8 `pixels`。

`pixels` SHALL 为行优先、非预乘、每像素 4 字节（R、G、B、A），且 `pixels.size == width * height * 4`。`pixel(x, y)` SHALL 返回对应像素的 `SvgColor`，坐标越界 SHALL 抛 `SvgException(kind: InvalidValue)`。

`width` 或 `height` ≤ 0 的位图 SHALL 不被创建（构造入口抛 `InvalidValue`）。

#### Scenario: 尺寸与字节数

- **WHEN** 创建 3×2 位图
- **THEN** `pixels.size == 24`，初始像素为全透明

#### Scenario: 像素读写一致

- **WHEN** 位图某像素为 `(255, 0, 0, 255)`
- **THEN** `pixel(x, y)` 返回不透明红色

#### Scenario: 越界访问

- **WHEN** 访问 `x == width` 或 `y < 0`
- **THEN** 抛 `SvgException(kind: InvalidValue)`

### Requirement: 渲染选项

系统 SHALL 提供 `SvgRenderOptions`，字段为 `width` / `height` / `background` / `samplesPerPixel` / `maxPixels` / `fonts` / `devicePixelRatio`。

默认值 SHALL 为：`width` / `height` 取根元素尺寸，根元素无绝对尺寸时取 300×150；`background` 为透明；`samplesPerPixel = 4`；`maxPixels = 64 × 1024 × 1024`；`devicePixelRatio = 1.0`。

`samplesPerPixel` SHALL 只接受 1、2、4，其余值抛 `InvalidValue`；`devicePixelRatio` ≤ 0 抛 `InvalidValue`。

#### Scenario: 默认尺寸

- **WHEN** 根元素 `width="120" height="80"`，使用默认选项
- **THEN** 输出位图为 120×80

#### Scenario: 无尺寸根元素

- **WHEN** 根元素没有 `width` / `height`，使用默认选项
- **THEN** 输出位图为 300×150

#### Scenario: 非法采样数

- **WHEN** `samplesPerPixel = 3`
- **THEN** 抛 `SvgException(kind: InvalidValue)`

### Requirement: 像素尺寸与上限

最终像素尺寸 SHALL 为 `ceil(width × devicePixelRatio)` × `ceil(height × devicePixelRatio)`。

乘积超过 `maxPixels` 时 SHALL 在分配像素前抛 `SvgException(kind: Limit)`。

#### Scenario: 内存炸弹

- **WHEN** `width = 100000`、`height = 100000`、`maxPixels = 1000000`
- **THEN** 抛 `SvgException(kind: Limit)`，且未分配 40 GB 像素缓冲

### Requirement: 扫描线填充

`SvgRasterizer` SHALL 把闭合路径按扫描线 + 边表（active edge table）填充。

填充规则 SHALL 支持 `nonzero` 与 `evenodd`：`nonzero` 累计有向交点符号，`evenodd` 按交点配对。每像素覆盖率 SHALL 为 `命中子采样数 / samplesPerPixel²`，取值 `0..1`。

水平边、零长度边、端点恰好落在扫描线上的边 SHALL 被稳定处理，不得产生漏行或重复计数。

#### Scenario: 矩形覆盖

- **WHEN** 在 4×4 位图上、`samplesPerPixel = 1` 填充 `(1,1)-(3,3)` 的矩形
- **THEN** 恰好 `(1,1)`、`(2,1)`、`(1,2)`、`(2,2)` 四个像素被完全覆盖，边界像素保持透明

#### Scenario: 凹多边形奇偶规则

- **WHEN** 填充一个自交的回旋多边形，分别使用 `evenodd` 与 `nonzero`
- **THEN** 两种规则在重叠区域结果不同：`evenodd` 空洞、`nonzero` 实心

#### Scenario: 退化边

- **WHEN** 路径包含重复点与水平边
- **THEN** 填充结果与去掉退化段后的等价路径一致

### Requirement: 抗锯齿

默认 SHALL 使用 4×4 超采样：每像素在 x 与 y 方向各取 `samplesPerPixel` 个子采样点，覆盖率由命中数平均。

`samplesPerPixel = 1` SHALL 关闭抗锯齿，用于像素精确用例；`2` / `4` SHALL 逐级提升边缘平滑度。

#### Scenario: 斜边覆盖

- **WHEN** `samplesPerPixel = 4` 填充一个 45° 三角形
- **THEN** 斜边经过的像素覆盖率严格介于 0 与 1 之间，且相邻像素覆盖率和约为 1

#### Scenario: 关闭抗锯齿

- **WHEN** `samplesPerPixel = 1` 填充同样的三角形
- **THEN** 每个像素覆盖率为 0 或 1

### Requirement: 颜色合成

光栅器内部 SHALL 使用预乘 alpha 合成；源覆盖 SHALL 为 `a = color.a × coverage × opacity`。

合成公式 SHALL 为 `out = src + dst × (1 - src.a)`；写入 `SvgBitmap` 前 SHALL 转换回非预乘 RGBA8。

`background` SHALL 在绘制任何图元前填满整个画布；未设置时画布初始为全透明。

#### Scenario: 两层 50% 叠加

- **WHEN** 透明画布上先画不透明红、再画 50% 蓝
- **THEN** 结果约为 `(128, 0, 128, 255)`，每通道容差 1/255

#### Scenario: 背景填充

- **WHEN** `background = 白色` 且不绘制任何图元
- **THEN** 所有像素为不透明白色

#### Scenario: 不产生色边

- **WHEN** 半透明红色图元完全覆盖透明像素
- **THEN** RGB 保持红色分量，不因预乘/反预乘出现黑边

### Requirement: 描边参数

系统 SHALL 提供 `SvgStrokeOutliner`，把中心线路径转换为可填充的闭合轮廓。

支持参数 SHALL 为：`stroke-width`、`stroke-linecap`（butt / round / square）、`stroke-linejoin`（miter / round / bevel）、`stroke-miterlimit`、`stroke-dasharray`、`stroke-dashoffset`。

#### Scenario: butt 与 square 端点

- **WHEN** 水平线段 `(0,0)-(10,0)`、`stroke-width=2`，分别使用 `butt` 与 `square`
- **THEN** butt 覆盖 `x ∈ [0,10]`，square 覆盖 `x ∈ [-1,11]`

#### Scenario: 零宽描边

- **WHEN** `stroke-width=0`
- **THEN** 不产生任何描边像素

### Requirement: join 与 dash 规则

miter join 超过 `miterlimit` 时 SHALL 退化为 bevel。

round join / cap SHALL 按设备像素误差 ≤ 0.25 离散为折线。

dash SHALL 按 `dasharray` 周期切分中心线，奇数长度数组 SHALL 复制一次后使用，每段独立加 cap；`dasharray` 全为 0 或负数 SHALL 视为不描边。

#### Scenario: miter 截断

- **WHEN** 锐角 join、`miterlimit=2`
- **THEN** 尖角被截断为 bevel，不产生超长尖刺

#### Scenario: dash 相位

- **WHEN** `stroke-dasharray="4 2"`、`stroke-dashoffset="2"`
- **THEN** 虚线相位整体前移 2 个用户单位，周期仍为 6

### Requirement: 描边轮廓填充与快速路径

轮廓 SHALL 以 `nonzero` 填充规则光栅化。

`rect` / `circle` / `ellipse` / `line` SHALL 使用解析轮廓快速路径，其余形状走通用 outliner。

#### Scenario: 快速路径一致

- **WHEN** 对同一个矩形分别走解析快速路径与通用 outliner
- **THEN** 两者的覆盖率差异 ≤ 1/255

### Requirement: 设备变换

每个绘制指令 SHALL 携带用户坐标到设备坐标的 `SvgMatrix`；光栅化前 SHALL 把路径控制点变换到设备坐标并扁平化，贝塞尔细分误差 ≤ 0.25 设备像素。

光栅器 SHALL NOT 通过缩放位图实现变换。

#### Scenario: 平移与缩放

- **WHEN** 路径 `(0,0)-(10,0)`、矩阵 `scale(2) × translate(5, 0)`
- **THEN** 设备坐标端点为 `(10,0)` 与 `(30,0)`

#### Scenario: 贝塞尔扁平化

- **WHEN** 大半径圆弧在 4×4 SSAA 下渲染
- **THEN** 轮廓边缘的像素覆盖率连续，不出现明显折线台阶

### Requirement: 光栅性能基准

以下目标 SHALL 在参考环境（Linux x86_64、`-O2`、单线程）测量并记录：

- 512×512、50 个形状、4×4 SSAA：≤ 50 ms；
- 512×512、100 段路径：< 8 ms；
- 1024×1024、渐变 + 裁剪：≤ 200 ms；
- 峰值内存：≤ 输出像素数 × 12 字节 + 文档模型。

这些指标为参考目标、非 CI 门禁；未达标时必须在 `f_svg/doc/perf-baseline.md` 记录实测值与差距。

#### Scenario: 场景基准确认

- **WHEN** 运行 512×512 与 1024×1024 两个基准场景
- **THEN** 耗时与内存被记录，未达标项写入 `perf-baseline.md`

