# OPC 包生成缓冲复用 — 增量规格

## ADDED Requirements

### Requirement: 部件字节与独立缓冲路径一致

系统 SHALL 保证每个 XML 部件生成器在「复用缓冲」与「新建缓冲」两种调用方式下，对相同输入产出逐字节相同的 `Array<Byte>`。

生成器函数体 SHALL 不因本次改造改变 XML 内容（元素顺序、属性顺序、转义、声明与换行）。

#### Scenario: 七类部件 + styles 逐字节比对

- **WHEN** 用同一份输入分别调用复用重载与「新建缓冲」调用
- **THEN** 两次返回的字节数组长度相同，且下标 0..n-1 每一字节相等

#### Scenario: 连续两次包写出的同名部件一致

- **WHEN** 对同一个 `ExcelDocument` 连续写出两次，各自解包
- **THEN** 两次产物中同名 XML 部件的字节完全相等

#### Scenario: 反向用例 — 内容不同必须体现为字节不同

- **WHEN** 两次生成使用不同的输入（如 sheet 名或 sheet 数不同）
- **THEN** 返回字节长度或内容不同（防止测试因两侧都为空而假绿）

### Requirement: 缓冲复用不得产生跨部件串扰

系统 SHALL 保证复用缓冲上的生成结果只取决于本次输入，与之前在该缓冲上生成过什么、生成过多大的部件无关。

`ByteBuffer.bytes()` 返回底层数组视图（不是拷贝）；调用方 MUST 在下一次复用同一缓冲前消费该视图。生产路径的 `ZipWriter.add` SHALL 在返回前完成 CRC 与压缩，不保留视图引用。

#### Scenario: 大部件之后接小部件

- **WHEN** 在同一缓冲上先生成一个大于初始容量（256 KiB）的部件，再生成一个小部件
- **THEN** 小部件字节与在全新缓冲上生成的完全一致，不残留前一部件尾部

#### Scenario: 缓冲预置残留字节

- **WHEN** 复用缓冲内已写入上一部件的残留内容，再调用任一生成器
- **THEN** 产出与全新缓冲一致（生成器进入时自行清空）

#### Scenario: 复用前消费字节视图

- **WHEN** 生成器返回 `bytes()` 视图后立即交给 `zip.add`，随后复用同一缓冲生成下一部件
- **THEN** 已写入的 ZIP 条目内容正确；调用方不得在复用后继续持有旧视图

### Requirement: 单次包写出复用同一个缓冲

系统 SHALL 在单次 `PackageWriter.write` 调用内，为 7 处 XML 部件与 `styles.xml` 复用同一个 `ByteBuffer` 实例，初始容量为 256 KiB。

`ExcelWriter` 路径 SHALL 同样复用缓冲，且不得在实例上长期持有该缓冲。

#### Scenario: 超限部件按需增长

- **WHEN** 某部件内容超过 256 KiB（例如 sheet 数上千时的 `[Content_Types].xml`）
- **THEN** 缓冲 `capacity` 大于 256 KiB，返回字节长度等于实际 XML 内容长度，且内容可被 `XmlParser` 解析

#### Scenario: 容量只增不减且不截断

- **WHEN** 先写大部件、再写小部件
- **THEN** 缓冲容量保持在高水位，小部件长度等于其自身内容长度（不被上一部件长度带偏）

### Requirement: 既有调用面与公开 API 保持不变

系统 SHALL 保留 `PackageWriter.contentTypes` / `rootRels` / `workbookXmlFromNames` / `workbookRels` 的既有参数列表，以及 `StylesWriter.write(pool)` 的单参调用方式。

公开 API（`ExcelDocument`、`ExcelWriter`、`ExcelWriteOptions` 等）SHALL 不发生任何签名变更。

#### Scenario: 既有调用无需改动

- **WHEN** 以既有参数列表调用上述四个生成器或 `StylesWriter.write(pool)`
- **THEN** 编译通过，产出字节与改造前一致

#### Scenario: 两条写出路径产物互不退化

- **WHEN** 分别经 `ExcelDocument.write` 与 `ExcelWriter` 写出结构相同的文档
- **THEN** 两者的 XML 部件内容与既有测试的期望一致（round-trip 与包结构用例全绿）

### Requirement: 复用收益可度量

系统 SHALL 提供可运行的基准，对比「复用缓冲」与「每部件新建缓冲」两条路径的耗时。

#### Scenario: 跑 cjpm bench

- **WHEN** 在 `f_excel` 目录执行 `cjpm bench`
- **THEN** 输出包含复用路径与新建路径的用例结果（参考值，不作 CI 性能判定）
