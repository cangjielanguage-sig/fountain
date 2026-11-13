# svg-png

## ADDED Requirements

### Requirement: PNG 结构

系统 SHALL 提供 `SvgPngEncoder.encode(bitmap)` 与 `SvgPngEncoder.write(bitmap, output)`，以及 `SvgBitmap.writePng(output)`、`SvgBitmap.toPngBytes()`、`SvgBitmap.savePng(path)`。

输出 SHALL 依次包含：8 字节 PNG 签名、`IHDR`、一个或多个 `IDAT`、`IEND`。

`IHDR` SHALL 声明 `bit depth = 8`、`color type = 6`（RGBA）、`compression = 0`、`filter = 0`、`interlace = 0`，宽高取位图尺寸。

每个 `IDAT` 解压后的数据 SHALL 为「每行 1 字节 filter 类型 + 行像素」；filter 类型 SHALL 固定为 `0`（None）。

#### Scenario: 签名与 chunk 顺序

- **WHEN** 编码任意 1×1 位图
- **THEN** 前 8 字节等于 PNG 签名，随后 chunk 类型依次为 `IHDR`、`IDAT`、`IEND`

#### Scenario: IHDR 字段

- **WHEN** 编码 3×2 位图
- **THEN** IHDR 中宽为 3、高为 2、bit depth 为 8、color type 为 6

#### Scenario: 行 filter

- **WHEN** 解压 IDAT
- **THEN** 数据长度为 `height × (1 + width × 4)`，每行首字节为 0

### Requirement: zlib 与校验和

`IDAT` SHALL 使用 zlib 流：2 字节头 `0x78 0x9C`、DEFLATE 数据、4 字节大端 Adler-32。

DEFLATE SHALL 通过 `stdx.compress.zlib.CompressOutputStream` 的 `WrapType.DeflateFormat` 生成。

每个 PNG chunk SHALL 携带 CRC-32（覆盖 chunk 类型与数据，多项式 `0xEDB88320`）；CRC-32 SHALL 由 `f_svg` 内部实现，不新增 `f_util` 依赖。

#### Scenario: zlib 头

- **WHEN** 读取第一个 `IDAT` chunk 的前两个数据字节
- **THEN** 为 `0x78`、`0x9C`

#### Scenario: Adler-32 正确

- **WHEN** 解压 `IDAT` 后重新计算 Adler-32
- **THEN** 与 zlib 流尾部 4 字节大端值一致

#### Scenario: CRC 正确

- **WHEN** 对每个 chunk 重新计算 CRC-32
- **THEN** 与 chunk 尾部存储值一致

### Requirement: 编解码往返

测试 SHALL 使用 `stdx.compress.zlib.DecompressInputStream` 解压 `IDAT`，去掉每行 filter 字节后，得到的 RGBA 序列 SHALL 与 `SvgBitmap.pixels` 完全一致。

编码器 SHALL 支持全透明、半透明与不透明像素，不丢失 alpha 通道。

#### Scenario: 像素往返

- **WHEN** 编码一张含随机 RGBA 值的 8×8 位图并解压回读
- **THEN** 逐字节与原始 `pixels` 相等

#### Scenario: alpha 保留

- **WHEN** 位图含 `(255, 0, 0, 128)` 像素
- **THEN** 回读结果仍为 `(255, 0, 0, 128)`

### Requirement: 输出确定性

同一 `SvgBitmap` 重复编码 SHALL 产生逐字节相同的 PNG。

`toPngBytes()`、`writePng(output)` 与 `SvgPngEncoder.encode(bitmap)` SHALL 产生相同字节。

#### Scenario: 重复编码

- **WHEN** 对同一位图连续调用两次 `toPngBytes()`
- **THEN** 两个数组完全相等

#### Scenario: 三种入口一致

- **WHEN** 分别调用 `encode`、`toPngBytes` 与 `writePng`
- **THEN** 三者输出字节完全一致

### Requirement: 文件输出

`savePng(path)` SHALL 使用覆盖模式写文件，写失败时 SHALL 包装为 `SvgException(kind: InvalidValue)` 并保留原始消息。

#### Scenario: 保存到文件

- **WHEN** `bitmap.savePng(Path("out.png"))`
- **THEN** 文件存在，内容等于 `toPngBytes()`

#### Scenario: 非法路径

- **WHEN** 目标目录不存在
- **THEN** 抛 `SvgException`，`kind == InvalidValue`

### Requirement: 编码性能基准

1024×1024 RGBA 位图的 `toPngBytes()` SHALL 在参考环境中 ≤ 100 ms（单次、`-O2`）。

该指标为参考目标、非 CI 门禁；未达标时必须在 `f_svg/doc/perf-baseline.md` 记录实测值与差距。

#### Scenario: 大图编码

- **WHEN** 编码 1024×1024 位图
- **THEN** 实测耗时被记录，且不超过 100 ms 或已写入差距

