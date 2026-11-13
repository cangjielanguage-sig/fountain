# svg-png

## ADDED Requirements

### Requirement: PNG 解码入口

系统 SHALL 提供 `SvgPngDecoder.decode(bytes: Array<Byte>)` 与 `SvgPngDecoder.decode(stream: InputStream)`，返回非预乘 RGBA8 的 `SvgBitmap`。

解码失败 SHALL 统一抛 `SvgException`：

- 结构错误（签名错误、chunk 长度越界、缺 `IHDR` / `IEND`、`IDAT` 不连续、CRC 不匹配、截断）抛 `SvgException(kind: Syntax)`；
- 不支持的位深 / 颜色类型 / 压缩方法 / 过滤方法抛 `SvgException(kind: InvalidValue)`；
- 超过像素或解压上限抛 `SvgException(kind: Limit)`。

解码器 SHALL NOT 修改输入字节数组，且同一输入多次解码结果逐字节一致。

#### Scenario: 最小 PNG

- **WHEN** 解码一张 1×1 不透明红色 RGBA PNG
- **THEN** 返回 1×1 位图，像素为 `(255, 0, 0, 255)`

#### Scenario: 输入不被修改

- **WHEN** 对同一字节数组连续解码两次
- **THEN** 两次位图一致，输入数组逐字节与调用前相同

### Requirement: 支持的 PNG 变体

解码器 SHALL 支持：

| 维度 | 支持范围 |
|---|---|
| 位深 | 1 / 2 / 4 / 8-bit（1/2/4-bit 仅用于灰度与调色板，并按规范展开到 8-bit） |
| 颜色类型 | 0 灰度、2 RGB、3 调色板、4 灰度+α、6 RGBA |
| 行过滤 | 0 None / 1 Sub / 2 Up / 3 Average / 4 Paeth |
| 交错 | 非交错与 Adam7 |

`tRNS` SHALL 在灰度、RGB 与调色板图像中生效；不存在 `tRNS` 时 alpha 为 255。

调色板索引越界、`PLTE` 长度不是 3 的倍数、`tRNS` 长于调色板时 SHALL 抛 `SvgException(kind: Syntax)`。

#### Scenario: 灰度展开

- **WHEN** 解码 4-bit 灰度 PNG，像素原始值为 0x0F
- **THEN** 输出 RGBA 为 `(255, 255, 255, 255)`

#### Scenario: 调色板

- **WHEN** 解码 4-bit 调色板 PNG，索引 1 对应 `PLTE` 中的红色
- **THEN** 对应像素为 `(255, 0, 0, 255)`

#### Scenario: tRNS

- **WHEN** RGB 图像的 `tRNS` 声明透明色为 `(0, 255, 0)`
- **THEN** 所有该颜色的像素 alpha 为 0

### Requirement: 行过滤与交错

解码器 SHALL 对每一行按 filter 类型逆运算：

- `0` None：原样；
- `1` Sub：加上左侧重建像素；
- `2` Up：加上上一行同列像素；
- `3` Average：加上左侧与上方均值；
- `4` Paeth：按 Paeth 预测器选择左 / 上 / 左上。

filter 类型大于 4 时 SHALL 抛 `SvgException(kind: InvalidValue)`。

Adam7 SHALL 按 7 个 pass 各自的宽高、偏移与步长解压与反过滤，最终写入同一张位图的对应坐标；未被任何 pass 覆盖的像素 SHALL 保持全透明。

同一图像分别以非交错与 Adam7 编码时，解码结果 SHALL 逐像素一致。

#### Scenario: Paeth 行

- **WHEN** 第二行 filter 为 4，左侧、上方、左上分别为 10、20、30
- **THEN** 重建值等于 `原始值 + 20`（Paeth 选择上方）

#### Scenario: Adam7 与非交错一致

- **WHEN** 同一 8×8 RGBA 图像分别以非交错和 Adam7 编码后解码
- **THEN** 两张位图逐字节一致

### Requirement: 解码校验与上限

解码器 SHALL 校验：

- 8 字节 PNG 签名；
- `IHDR` 为第一个 chunk 且长度 13；
- 每个 chunk 的 CRC-32（复用 `SvgCrc32`）；
- `IDAT` 至少出现一次且连续；
- `IEND` 存在且长度为 0；
- 解压后字节数等于 `height × (1 + rowBytes)`。

单张解码图像像素数超过 `16 × 1024 × 1024` 时 SHALL 抛 `SvgException(kind: Limit)`；单次渲染累计解码像素数超过 `64 × 1024 × 1024` 时同样抛 `Limit`。`data:image/png;base64,` 的 base64 文本长度超过 32 MiB 时 SHALL 抛 `Limit`。

#### Scenario: 坏 CRC

- **WHEN** 篡改任一 chunk 的 CRC
- **THEN** 抛 `SvgException(kind: Syntax)`

#### Scenario: 截断 IDAT

- **WHEN** 删除最后一个 `IDAT` chunk 的尾部数据
- **THEN** 抛 `SvgException(kind: Syntax)`

#### Scenario: 缺 IEND

- **WHEN** 删除 `IEND`
- **THEN** 抛 `SvgException(kind: Syntax)`

#### Scenario: 解码炸弹

- **WHEN** `IHDR` 声明 `100000 × 100000` 且未提高上限
- **THEN** 在解压前抛 `SvgException(kind: Limit)`

### Requirement: 解码与编码回环

对同一 `SvgBitmap` 使用 M2 的 `toPngBytes()` 编码后再解码，结果 SHALL 与原始 `pixels` 逐字节一致。

测试 SHALL 覆盖灰度、灰度+α、RGB、RGBA、调色板与 Adam7 六类 PNG；编码侧不支持的变体可使用测试内构造的最小字节流。

#### Scenario: RGBA 回环

- **WHEN** 8×8 位图含随机 RGBA 值，编码后解码
- **THEN** 逐字节等于原始 `pixels`

#### Scenario: 全透明保留

- **WHEN** 位图含 `(0, 0, 0, 0)` 像素
- **THEN** 解码后仍为 `(0, 0, 0, 0)`
