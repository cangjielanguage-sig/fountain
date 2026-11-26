# svg-authoring

## MODIFIED Requirements

### Requirement: XML 文本输出契约

`toSvgString(options!)` SHALL 通过既有 `SvgWriter` / `writeSvgString` 输出 UTF-8 文本。默认输出 SHALL 包含 XML 声明与 `xmlns="http://www.w3.org/2000/svg"`，SHALL NOT 由构建器自行拼接 XML。

`options` SHALL 为既有 `SvgWriteOptions`，其 `xmlDeclaration`、`indent`、`xlink` 等字段 SHALL 按既有语义生效。

系统 SHALL 提供 `write(output: OutputStream): Unit`，把与 `toSvgString()` 等价的字节写入调用方提供的流，并 SHALL 只 `flush`、SHALL NOT 关闭该流。

#### Scenario: 声明与命名空间

- **WHEN** 对任意构建器调用 `toSvgString()`
- **THEN** 结果以 `<?xml version="1.0" encoding="UTF-8"?>` 开头，根元素带 `xmlns="http://www.w3.org/2000/svg"`

#### Scenario: 缩进选项

- **WHEN** 调用 `toSvgString(options: SvgWriteOptions(indent: Some("  ")))`
- **THEN** 输出按两空格缩进，且重新解析后的结构与紧凑输出一致

#### Scenario: 写入输出流

- **WHEN** 传入内存 `OutputStream` 调用 `write(output)`
- **THEN** 流中的字节与同一构建器的 `toSvgString()` 逐字节一致，且流仍可继续写入

#### Scenario: 浏览器可播放

- **WHEN** 按设计示例构建 `rect + animate` 并输出
- **THEN** 结果包含 `animate` 元素及其 `attributeName`、`from`、`to`、`dur`、`begin`、`repeatCount`，浏览器无需额外声明即可播放 SMIL

### Requirement: 文件落盘

系统 SHALL 提供 `save(path: String)`、`save(path: Path)` 与 `save(file: File)`，把与 `toSvgString()` 等价的 UTF-8 内容写入调用方给定路径或已打开文件，SHALL NOT 读取其他文件或访问网络。

`save(file: File)` SHALL 写入调用方已打开的文件，并 SHALL 只 `flush`、SHALL NOT 关闭该文件。

落盘后的文件 SHALL 能被 `SvgParser` 重新解析，且元素结构、标签与属性与生成时一致。文件系统失败 SHALL 包装为 `SvgException`，其 `kind` SHALL 为既有 `SvgErrorKind.InvalidValue`（与 `SvgBitmap.savePng` 的落盘失败口径一致；M7 不新增 `SvgErrorKind` 构造器）。

#### Scenario: 落盘可重解析

- **WHEN** 调用 `save("target/m7-card.svg")` 后把该路径交给 `SvgParser.parse(path)`
- **THEN** 解析成功，根为 `svg`，`rect` 与 `animate` 的属性与生成时一致

#### Scenario: 写入已打开文件

- **WHEN** 调用方以 `File.create` 打开文件后调用 `save(file)`，随后自行关闭
- **THEN** 文件内容与 `toSvgString()` 一致，且 `save` 未关闭该文件

#### Scenario: 写入失败

- **WHEN** 目标路径位于不存在的目录
- **THEN** 抛出 `SvgException`，`kind` 为 `InvalidValue`，消息包含目标路径
