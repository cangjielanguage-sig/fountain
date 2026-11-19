# 变更提案：M7 输出重载

## Why

M7 的 `SvgBuilder` 现在只能 `toSvgString()`、`save(path: String)` 与 `save(path: Path)`。调用方若已有打开的 `File` 或任意 `OutputStream`（内存缓冲、网络流、压缩流），必须先转成字符串再自行写出，既多一次拷贝，也无法复用既有 `SvgWriter` 的流式输出。

## What Changes

- 新增 `SvgBuilder.write(output: OutputStream): Unit`：把与 `toSvgString()` 等价的内容写入调用方提供的流，不关闭流。
- 新增 `SvgBuilder.save(file: File): Unit`：写入调用方已打开的文件，不关闭文件。
- 既有 `toSvgString` / `save(path: String)` / `save(path: Path)` 语义不变。

## Impact

- 只改 `SvgAuthoringBuilder.cj`（M7 新增文件）与 `SvgBuilderM7_test.cj`。
- 既有解析、渲染、时间轴与公开 API 不受影响；M7 之前的 1226 条用例零改动。
- 规格：`svg-authoring` 的「XML 文本输出契约」与「文件落盘」两条 Requirement 做增量修改。
