# 任务：multipart 流式块复用 + 健壮性修复

> TDD：先建回归网锁现状 → 再写缺陷/复用用例（Red）→ 最小实现（Green）→ 全量回归。
> 本变更只改 `f_http` 与 `f_io` 内部；公开 API 0 变化。空内容 part（a）另开 `fix/multipart-empty-part`。

## T1 前置与缺陷确认

- [x] 1.1 探针：`Array<Byte>` 切片是可写视图；`String.unsafeUtf8` 是零拷贝别名（header 因此不复用）
- [x] 1.2 探针：`Array<Byte>(-3)` 抛 `NegativeArraySizeException`；`DataMultipartTuples.get` / `DataMultipartList.get` 的访问方式
- [x] 1.3 确认 `HttpConfig.uploadDir` 缺省 `/tmp/fountain/upload`
- [x] 1.4 确认 4 个既有缺陷：a 空 part 死循环/失败、b 截断报文死循环、c 多文件目录冲突、d 落盘 bytes 失败

## T2 f_http 回归套件（实现前全绿）

新增 `f_http/src/MultipartFormDataParser_test.cj`（`f_http` 首批测试）。

- [x] 2.1 辅助：`multipartBytes` / `formPart` / `filePart` / `parseForm` / `parseMixed` / 落盘读取
- [x] 2.2 字段与文件：单/多/重名/中文/Content-Type/无 Content-Type/小文件/落盘文件/混合
- [x] 2.3 边界与畸形：内容含 CRLF、含 boundary 前缀、尾部 CR、大文本流式、二进制、缺首 boundary、缺首部空行、不支持媒体类型、multipart/mixed
- [x] 2.4 新增缺陷回归：缺终止分隔符（b）、落盘 bytes（d）、多文件（c）
- [x] 2.5 空内容 part（a）不加入：注释指向后续 `fix/multipart-empty-part`
- [x] 2.6 `cd f_http && cjpm test` 通过（26 条）

## T3 `f_io.RotatableBuffer.read` EOF 截断（修 b）

- [x] 3.1 Red：新增 `f_io/src/RotatableBuffer_test.cj`——普通 EOF / 空流 / 恰好半窗，三例在旧实现上失败
- [x] 3.2 Green：`read` 的 `size` 同时受 `sectionEnd` 与 `bufferEnd` 限制，负值钳制为 0
- [x] 3.3 `cd f_io && cjpm test` 33/33（既有 30 + 新增 3）

## T4 f_http 缓冲复用与缺陷修复

- [x] 4.1 新增 `crlf` 字段与惰性 `chunkBuf` / `chunkBuffer()`（1024 B）
- [x] 4.2 文本流式分支与文件分支改用 `chunkBuffer()`；CRLF 读前归零
- [x] 4.3 header 保持精确 `Array<Byte>(headerLen)` + `String.unsafeUtf8`，不复用
- [x] 4.4 多文件：`Directory.create` 仅在 `!exists(path)` 时调用（c）
- [x] 4.5 落盘 bytes：只 close 一次，按文件长度预分配 `ByteBuffer`（d）
- [x] 4.6 `cd f_http && cjpm test` 26/26

## T5 回归与契约

- [x] 5.1 `cd f_io && cjpm test` 33/33；`cd f_http && cjpm test` 26/26
- [x] 5.2 `git diff` 中 `f_http` / `f_io` 无 `public` 符号变化
- [x] 5.3 正常报文的解析结果与异常类型保持不变

## T6 产物与提交

- [x] 6.1 镜像 `openspec/changes/reuse-multipart-parse-buffers/` 到 `f_http/doc/spec/reuse-multipart-parse-buffers/`，两份一致
- [x] 6.2 分支 `feature/reuse-multipart-parse-buffers`，单次提交涵盖回归套件、f_io EOF 修复与 f_http 缓冲复用/缺陷修复
- [x] 6.3 提交完成；合并回 `sts/1.3.x-LocalMode` 与推送由交付步骤在 verify 通过后执行

## 后续（不在本变更）

- 空内容 part（a）需要修 `RotatableBuffer` 的 `sectionEnd` 旋转语义，另开 `fix/multipart-empty-part`。
