# 任务：复用三处读缓冲

## 1. f_dbd

- [x] 1.1 Red：`readChunk` 覆盖精确长度、读至 EOF、短块、空流（验证：新断言失败或编译失败）
- [x] 1.2 Green：单块 `DEFAULT_STREAM_CHUNK` + `buf[0..want]` 读 + `add(all:)`（验证：1.1 全绿，既有 `sqltypes_test` 全绿）

## 2. f_zip

- [x] 2.1 Red：`EntrySource.readAt` 的 dst 大于/等于/小于剩余、部分读、EOF（验证：断言失败）
- [x] 2.2 Red：`BoundedStream.read` 与 `FileRangeBoundedStream.read` 的三态与 EOF（验证：断言失败）
- [x] 2.3 Green：`readAt` 直接 `file.read(dst[got..want])`（验证：2.1 全绿）
- [x] 2.4 Green：越界分支直接 `input.read(buffer[0..remaining])`（验证：2.2 全绿，既有 `EntrySource_test` 全绿）

## 3. f_excel

- [x] 3.1 行为用例：`sliceAt` 覆盖长度 0、<4 KB、跨 4 KB、跨多次 read、部分读（验证：长串两次读取完整一致）
- [x] 3.2 Green：按已知长度一次分配 + 切片读 + `String.fromUtf8(bytes[0..got])`（验证：3.1 全绿，既有共享字符串用例全绿）

## 4. 基准与回归

- [x] 4.1 f_zip 两处零分配断言（1 MiB `readAt`、256 KiB 限长流）；f_dbd 记录分配；f_excel 只保留行为用例
- [x] 4.2 `f_dbd`、`f_zip`、`f_excel` 全量测试通过（验证：三模块 0 失败）
- [x] 4.3 镜像 proposal/design/tasks 到 `f_dbd/doc/spec/reuse-read-buffers/`
- [x] 4.4 提交并勾选任务
