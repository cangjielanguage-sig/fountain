# 复用 multipart 流式块缓冲并修复解析器健壮性

## Why

`f_http` 的 `MultipartFormDataParser.parse` 是**零测试**模块。实现过程中确认了三类可修问题：

1. **流式块重复分配**：每个文本流式 part / 文件 part 都新建 `Array<Byte>(1024)`；`crlf` 每个 `parse()` 新建 2 B。多文件上传时这两类分配随 part 数线性增长。
2. **截断报文死循环**：缺少终止分隔符时，`f_io.RotatableBuffer.read` 不按 `bufferEnd` 截断，永远返回满长度，`parse()` 无限累积。
3. **多文件 / 落盘读取失败**：≥2 个落盘文件时 `Directory.create` 第二次抛 already exists；`MultipartFile.bytes()` 对落盘 part 因双重 `close()` 与 4096 B 整块写超容量而必抛 `FSException`。

**明确排除**：空内容 part 仍会失败（`RotatableBuffer` 在 `sectionEnd` 处提前旋转、吞掉空 part 的分隔符），需要修改 `RotatableBuffer` 的 section 旋转语义，另开 `fix/multipart-empty-part` 变更处理。本变更的测试套件不覆盖该场景，并在设计里记录为已知缺陷。

**header 块不复用**：`String.unsafeUtf8` 是零拷贝别名，header 的 key / filename 会逃逸到返回的 `Data`，复用 header 缓冲会改写上一 part；改用 `String.fromUtf8` 复制后净收益≈0。因此 header 保持“精确长度 Array + unsafeUtf8”，只复用 `chunkBuf` 与 `crlf`。

## What Changes

- **`chunkBuf` 复用**：`MultipartFormDataParser` 新增惰性 `chunkBuf`（首次进入流式/文件分支时创建 1024 B，之后复用）；`crlf` 改为构造时创建一次。
- **header 保持精确分配**：`Array<Byte>(headerLen)` + `stream.read` + `String.unsafeUtf8`，不使用复用缓冲。
- **`f_io.RotatableBuffer.read` EOF 截断**：`size` 同时受 `bufferEnd` 约束；EOF 返回 0，不再读窗口后半的旧/零字节。
- **多文件目录**：`Directory.create` 仅在目录不存在时调用。
- **`MultipartFile.bytes()`**：只 close 一次；按文件长度预分配 `ByteBuffer`；非文件流用 64 KiB 初始容量。
- **测试**：`f_http` 新增 26 条（回归 21 + 复用 5，空 part 除外）；`f_io` 新增 3 条 EOF 用例；f_io 原有 30 条全绿。

**公开 API 不变**：`f_http` / `f_io` 均无签名、访问级别、配置项变化；`chunkBuffer()` 包内可见。

## Capabilities

### Modified Capabilities

- `http-multipart`：流式块缓冲复用、截断报文终止、多文件与落盘读取。
- `io-rotatable-buffer`：`read` 在 EOF 处按真实数据末尾截断并返回 0。

## Impact

- 代码：`f_http/src/MultipartFormDataParser.cj`、`f_http/src/MultipartFile.cj`、`f_io/src/RotatableBuffer.cj`。
- 测试：`f_http/src/MultipartFormDataParser_test.cj`、`f_http/src/MultipartBufferReuse_test.cj`、`f_io/src/RotatableBuffer_test.cj`。
- 行为：正常报文解析结果不变；截断报文从死循环变为抛 `MultipartException`；多文件/落盘读取从失败变为成功。
- 已知缺陷（另开 fix）：空内容 part 仍抛 `MultipartException`，不会死循环（b 修复后 EOF 可终止），但尚不能正确返回空值。

## Non-goals

- 不修空内容 part（`fix/multipart-empty-part`）。
- 不复用 header 缓冲（别名/收益原因）。
- 不引入耗时门禁；不做 header 的按字节解析重构。
