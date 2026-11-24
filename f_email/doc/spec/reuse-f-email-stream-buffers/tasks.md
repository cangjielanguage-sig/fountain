# 任务：复用 f_email 流式缓冲

## 1. Red：输出等价与分块边界

- [x] 1.1 `MimeWriterStream_test.cj`：`writeLeafStream` 与 `writeLeaf` 对 32 KB / 64 KB / 192 KB 正文逐字节一致（验证：断言失败或输出差异）
- [x] 1.2 `LineChannelReadExact_test.cj`：假流按 1/7/4096/65536 分块返回，`readExact(256 KB)` 字节一致（验证：断言失败）
- [x] 1.3 pending 残留 + `readExact` 跨缓冲拼接；EOF 提前中断抛 `MailIoException`（验证：断言失败）

## 2. Green：MimeWriter 单缓冲

- [x] 2.1 `writeLeafStream` 改为一块 64 KB，采样写完后复用（验证：1.1 全绿）
- [x] 2.2 既有 MIME 用例全绿（验证：无输出差异）

## 3. Green：LineChannel 单缓冲

- [x] 3.1 增加 `READ_CHUNK_BYTES` 常量，删除只取 `.size` 的 `chunk`（验证：1.2–1.3 全绿）
- [x] 3.2 循环改为 `buf[0..want]` 读 + `copyTo` 批量拷贝（验证：字节一致、异常文案不变）

## 4. 基准与回归

- [x] 4.1 `F_EMAIL_BENCH=1` 记录 192 KB 流式写出与 `readExact(256 KB)` 的分配变化（验证：数值下降，或按口径只记录）
- [x] 4.2 `f_email` 全量测试通过（验证：0 失败）
- [x] 4.3 镜像 proposal/design/tasks 到 `f_email/doc/spec/reuse-f-email-stream-buffers/`
- [x] 4.4 提交并勾选任务
