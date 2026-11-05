# svg-value-types

## ADDED Requirements

### Requirement: 长度值解析与规范化

系统 SHALL 提供 `SvgLength`，把 SVG 长度字符串解析为「数值 + 单位」，并输出规范形式。

单位集合 SHALL 覆盖无单位数、`%`、`em`、`ex`、`px`、`pt`、`pc`、`cm`、`mm`、`in`，单位匹配不区分大小写。

`SvgLength.parse` SHALL 在输入为空、含未知单位、数值为 `NaN` 或 `Inf` 时抛 `SvgException(kind: InvalidValue)`；`tryParse` SHALL 返回 `None` 而不抛错。

`toString` SHALL 输出规范形式：整数不带小数点，小数去掉末尾 `0`，百分比与单位原样拼接。

#### Scenario: 解析常用单位

- **WHEN** 输入 `10`、`10px`、`10PX`、`50%`、`1.5em`、`2.54cm`
- **THEN** 依次得到 `10 Number`、`10 Px`、`10 Px`、`50 Percent`、`1.5 Em`、`2.54 Cm`

#### Scenario: 拒绝非法长度

- **WHEN** 输入为空串、`10foo`、`NaN`、`Inf`
- **THEN** `parse` 抛 `SvgException` 且 `kind == InvalidValue`，`tryParse` 返回 `None`

#### Scenario: 规范形式往返

- **WHEN** 对任意合法长度执行 `SvgLength.parse(length.toString())`
- **THEN** 结果与原值相等

### Requirement: 长度到用户单位换算

系统 SHALL 提供 `toUserUnits(length, axis, context)`，按 SVG 1.1 约定把长度换算为当前用户单位。

换算基准 SHALL 为：`px`/无单位取原值；`in = 96`；`cm = 96/2.54`；`mm = 96/25.4`；`pt = 96/72`；`pc = 16`；`em = fontSize`；`ex = fontSize/2`；`%` 按 `SvgLengthAxis` 取视口宽、视口高或对角线基准。

百分比基准 SHALL 由调用方显式指定轴，不得隐式猜测；对角线基准为 `sqrt(w²+h²)/sqrt(2)`。

#### Scenario: 绝对单位换算

- **WHEN** `context` 为默认（DPI 96、fontSize 16），输入 `1in`、`25.4mm`、`72pt`、`1pc`
- **THEN** 结果分别为 `96`、`96`、`96`、`16`

#### Scenario: 百分比按轴换算

- **WHEN** 视口为 200×100，输入 `50%` 且轴为 `Horizontal` / `Vertical`
- **THEN** 结果分别为 `100` / `50`

### Requirement: 颜色解析与序列化

系统 SHALL 提供 `SvgColor`，支持 `#rgb`、`#rrggbb`、`#rrggbbaa`、`rgb()`、`rgba()`、CSS Color 4 的空格/斜杠语法、`hsl()`、`hsla()`、CSS3 命名色与 `transparent`，大小写不敏感。

颜色分量 SHALL 支持 `0~255` 与 `0%~100%` 两种写法并钳制到合法范围；alpha 支持 `0~1` 与百分比。

`SvgColor.parse("none")` SHALL 失败（`none` 是画笔关键字而非颜色）；未知色名、空串、分量个数错误 SHALL 抛 `InvalidValue`。

`toString` SHALL 在 `alpha == 1` 时输出 `#rrggbb`，否则输出 `rgba(r,g,b,a)` 且 alpha 取最短表示。

#### Scenario: 十六进制与简写

- **WHEN** 输入 `#f00`、`#FF0000`、`#ff000080`
- **THEN** 前两者得到同一颜色，第三者 alpha 约为 `0.502`

#### Scenario: 函数式语法

- **WHEN** 输入 `rgb(255, 0, 0)`、`rgb(100% 0% 0% / 50%)`、`hsl(120, 100%, 50%)`
- **THEN** 均解析成功，且 alpha 分别为 `1`、`0.5`、`1`

#### Scenario: 拒绝画笔关键字

- **WHEN** 输入 `none`
- **THEN** `parse` 抛 `SvgException(kind: InvalidValue)`

### Requirement: 画笔解析

系统 SHALL 提供 `SvgPaint`，区分 `None`、`CurrentColor`、`Color`、`Reference` 四种形态。

`url()` 内部 SHALL 只接受同文档片段引用（`#id`，允许带引号），并可携带一个回退画笔；外部 URL SHALL 抛安全类 `SvgException(kind: Security)`。

`SvgPaint.parse` SHALL 不发起任何 I/O。

#### Scenario: 片段引用与回退

- **WHEN** 输入 `url(#grad1)`、`url("#grad1") none`、`url(#grad1) red`
- **THEN** 均解析为 `Reference`，`id` 为 `grad1`，回退分别为 `None`、`Some(None)`、`Some(Color(red))`

#### Scenario: 拒绝外部引用

- **WHEN** 输入 `url("http://example.com/x.svg#g")`
- **THEN** 抛 `SvgException(kind: Security)`

### Requirement: 矩阵与变换

系统 SHALL 提供 `SvgMatrix`（a,b,c,d,e,f）与 `SvgTransform`（有序操作列表）。

`SvgTransform.parse` SHALL 支持 `matrix`、`translate`、`scale`、`rotate`、`skewX`、`skewY`，允许逗号或空白分隔参数，允许省略 `ty`（默认 0）与 `sy`（默认等于 `sx`）；空串与纯空白 SHALL 解析为 `identity`；未知函数名与非法数字 SHALL 抛 `InvalidValue`。

变换合成顺序 SHALL 为 `A B C` ⇒ `A × B × C`，点按列向量右乘，即最后书写的变换最先作用于坐标。

`SvgMatrix` SHALL 提供 `multiply`、`apply`、`determinant`、`invert`（不可逆时返回 `None`）。

#### Scenario: 合成顺序

- **WHEN** 变换为 `translate(10,20) scale(2)`，作用于点 `(1,1)`
- **THEN** 结果为 `(12,22)`

#### Scenario: 旋转参数缺省

- **WHEN** 输入 `rotate(45)`
- **THEN** 绕原点旋转 45 度，解析成功

#### Scenario: 空变换

- **WHEN** 输入空串或 `"   "`
- **THEN** 得到 `SvgTransform.identity`，`toMatrix()` 为 `SvgMatrix.identity`

### Requirement: 路径数据解析与绝对化

系统 SHALL 提供 `SvgPathData`，支持 `M/m`、`L/l`、`H/h`、`V/v`、`C/c`、`S/s`、`Q/q`、`T/t`、`A/a`、`Z/z` 十条命令，并保留每条命令的绝对/相对属性。

解析器 SHALL 处理：符号分隔（`M1-2`）、小数连写（`0.5.5`）、指数（`1e3` / `1E-3`）、弧标志位连写（`A5 5 0 0110 10`）、逗号与空白混用；双逗号、`Z` 后直接跟数字、参数个数不足 SHALL 抛 `Syntax` 或 `InvalidValue`。

`M` 后多余的坐标对 SHALL 按 `L` 隐式重复；空串与纯空白 SHALL 是合法的空路径。

`toAbsolute()` SHALL 把相对命令转绝对，`H/V` 转成 `L`，`A` 只转换终点，`Z` 后当前点回到子路径起点。

`toString` SHALL 每个命令输出一个字母加空格分隔的参数，命令之间用空格分隔，数字使用 `formatSvgNumber`。

#### Scenario: 隐式重复与符号分隔

- **WHEN** 输入 `M1-2L3 4`
- **THEN** 解析为 `MoveTo(1,-2)`、`LineTo(3,4)`

#### Scenario: 弧标志连写

- **WHEN** 输入 `M0 0A5 5 0 0110 10`
- **THEN** 解析出一条 `ArcTo`，`largeArc == false`、`sweep == true`、终点为 `(10,10)`

#### Scenario: 绝对化

- **WHEN** 输入 `m10 10h5v5z`
- **THEN** `toAbsolute()` 输出 `M 10 10 L 15 10 L 15 15 Z` 等价结构

#### Scenario: 空路径

- **WHEN** 输入 `""` 或 `"  "`
- **THEN** 解析成功且 `commands` 为空

### Requirement: 视口与纵横比

系统 SHALL 提供 `SvgViewBox` 与 `SvgPreserveAspectRatio`。

`SvgViewBox` SHALL 解析四个数值（逗号或空白分隔），宽或高为 0/负数 SHALL 抛 `InvalidValue`。

`SvgPreserveAspectRatio` SHALL 支持 `none`、九种对齐值与 `meet`/`slice` 修饰，未知值 SHALL 抛错。

`toMatrix(viewBox, width, height)` SHALL 按 SVG 1.1 算法计算缩放与平移，`meet` 取较小缩放、`slice` 取较大缩放，结果形式为 `translate(tx,ty) × scale(sx,sy) × translate(-minX,-minY)`；退化视口（宽高 ≤ 0）SHALL 抛 `InvalidValue`。

#### Scenario: meet 与 slice

- **WHEN** `viewBox` 为 `0 0 100 50`，视口为 `200 200`
- **THEN** `meet` 的缩放为 `2` 且垂直居中；`slice` 的缩放为 `4` 且水平方向被裁切

#### Scenario: none 非等比拉伸

- **WHEN** `align == None` 且视口与 `viewBox` 宽高比不同
- **THEN** x、y 缩放分别等于 `width/viewBox.width` 与 `height/viewBox.height`

### Requirement: 数字格式化与数值列表

系统 SHALL 提供 `formatSvgNumber(value)`：`NaN`/`±Inf` 抛 `InvalidValue`；`-0.0` 输出 `0`；整数不带 `.0`；非整数最多 6 位小数并去掉末尾 `0`；绝对值 `< 1e-6` 的非零值输出 `0`；不使用科学计数法。

系统 SHALL 提供 `SvgPointList` 与 `SvgNumberList`：支持逗号或空白分隔，`SvgPointList` 只接受成对的 `x y`，奇数个数字 SHALL 抛 `InvalidValue`。

#### Scenario: 数字规范化

- **WHEN** 输入 `1.5000`、`-0.0`、`1e-9`、`3`
- **THEN** 输出 `1.5`、`0`、`0`、`3`

#### Scenario: 点列表奇数个数字

- **WHEN** 输入 `10,20 30`
- **THEN** 抛 `SvgException(kind: InvalidValue)`

### Requirement: 值类型错误契约

所有值类型的 `parse` SHALL 在失败时抛 `SvgException`。

定义了 `tryParse` 的类型（`SvgLength`、`SvgColor`、`SvgPathData`）SHALL 在失败时返回 `None` 且不抛错，安全类错误同样返回 `None`。

所有值类型 SHALL 满足 `parse(toString(x)) == x`。

#### Scenario: tryParse 不抛错

- **WHEN** 对 `SvgLength.tryParse("10foo")`、`SvgColor.tryParse("nope")`、`SvgPathData.tryParse("M1")` 求值
- **THEN** 均返回 `None`，不抛异常
