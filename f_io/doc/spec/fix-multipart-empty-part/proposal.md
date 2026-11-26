# 修复空内容 multipart part 解析

## Why

空内容 part 是最常见的表单形状之一（用户留空未填字段、0 字节上传文件），但 `MultipartFormDataParser.parse()` 目前对它会抛 `MultipartException`。

根因不在 `f_http`：`f_io.RotatableBuffer.read` 一旦读到 `sectionEnd` 就**立即**跳过分隔符 `\r\n--boundary`。空 part 的 header 读取恰好结束在 `sectionEnd`，分隔符在 `parse()` 调用 `indexOf(seperatorBoundaryBytes)` 之前就被吞掉，于是 `parse()` 把下一 part 的首部行当成内容，或在报文末尾读到 EOF 后抛异常。

该缺陷在上一个变更（`reuse-multipart-parse-buffers`）中已确认并显式排除，本次单独修复。

## What Changes

- **`RotatableBuffer.read` 改为延迟跳过分隔符**：本次 `read` 只读到 `sectionEnd` 为止，不消费分隔符；下一次 `read` 在入口处再消费 `\r\n--boundary`（含跨半窗时的窗口旋转）。`partEnd` 返回值语义保持不变。
- **`MultipartFormDataParser` 分支结构不变，只改循环退出条件**：流式文本与落盘文件两个 `while` 循环原先靠「短读」判断 section 结束；延迟跳过会让最后一次读直接返回下一段数据（内容长度恰为 1024 整数倍时尤其明显），因此改用 `read` 返回的 `partEnd || len < buf.size` 退出。空内容 part 仍走既有零长度分支，得到空字符串或 0 字节 `MultipartFile`。
- **测试**：`f_io` 增加延迟跳过语义用例（读到 sectionEnd 后 `offset` 不动、下次 `read` 跳过并读到下一段、分隔符跨半窗）；`f_http` 新增空 part 套件（单独空字段、首/中/尾位置、超窗口字段前后、连续两个空 part、空文件、落盘边界形状），并删除上一变更留下的「空 part 已知缺陷」注释。
- **公开 API 不变**：`RotatableBuffer.read` 签名与返回结构不变；`f_http` 无签名变化。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `io-rotatable-buffer`：明确「分隔符延迟跳过」契约，并修订原「既有正数据行为不变」中关于 `offset` 推进时机的表述。
- `http-multipart`：新增「空内容 part 解析」要求，覆盖空字段值与 0 字节文件。

## Impact

- 代码：`f_io/src/RotatableBuffer.cj`（`read` 的跳过时机）、`f_http/src/MultipartFormDataParser.cj`（两个流式循环的退出条件）。
- 测试：`f_io/src/RotatableBuffer_test.cj`、`f_http/src/MultipartEmptyPart_test.cj`（新增）、`f_http/src/MultipartFormDataParser_test.cj`（删除缺陷注释）。
- 行为：空内容 part 从抛 `MultipartException` 变为返回空值/空文件；非空 part 的解析结果、异常类型、`partEnd` 语义不变。
- 调用面：`RotatableBuffer` 在本仓库仅被 `f_http.MultipartFormDataParser` 使用，另需通过 `f_io` 既有 33 条测试回归。
