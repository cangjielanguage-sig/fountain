# 设计：复用 f_email 流式缓冲

## D1 `MimeWriter.writeLeafStream`：一块 64 KB 走完

```cangjie
let buf = Array<Byte>(STREAM_BUFFER_BYTES, repeat: 0)
let sampleSize = readUpTo(input, buf)
let sample = if (sampleSize == buf.size) { buf } else { buf[0..sampleSize] }
let encoding = chooseEncoding(sample, isText)
writeHeaders(withTransferEncoding(part.headers, encoding))
let encoded = openEncoder(encoding)
encoded.write(sample)
// sample 已被编码器消费完，同一块内存继续读剩余
while (true) {
    let n = input.read(buf)
    if (n <= 0) { break }
    encoded.write(buf[0..n])
}
closeEncoder(encoded, encoding)
```

**安全性依据**（已核对实现）：

- `Base64Encoder.write` 逐字节消费，只把 0~2 个尾字节拷进自己的 `carry`；
- `QuotedPrintable.encoder.write` 逐字节消费，仅保留 `pendingCr` 布尔；
- `chooseEncoding` 在写入前完成，不持有 `sample`。

因此 `encoded.write(sample)` 返回后复用 `buf` 不会污染输出。原来 `rest` 与 `sampleBuffer` 各 64 KB，现降为一块。

## D2 `LineChannel.readExact`：常量 + 一块 64 KB

```cangjie
private static let READ_CHUNK_BYTES: Int64 = 65536
...
let buf = Array<Byte>(READ_CHUNK_BYTES, repeat: 0)
while (written < count) {
    applyReadTimeout()
    let want = if (count - written < READ_CHUNK_BYTES) { count - written } else { READ_CHUNK_BYTES }
    let n = try { input.read(buf[0..want]) } catch (...) { ... }
    if (n <= 0) { throw ioFailure(...) }
    buf[0..n].copyTo(result, 0, written, n)
    written += n
    traceBytes(r'S', n)
}
```

- 删除只取 `.size` 的 `chunk` 与每轮 `tmp`；
- `input.read(buf[0..want])` 走数组切片视图（`readUpTo` 已在用同一手法）；
- 异常类型、错误文案、`traceBytes` 调用次数与顺序不变。

## D3 测试

1. **输出等价**：同一正文分别走 `writeLeaf`（内存）与 `writeLeafStream`（流式），逐字节比较；正文 32 KB / 恰 64 KB / 192 KB；
2. **分块边界**：假 `InputStream` 每次最多返回 1 / 7 / 4096 / 65536 字节，`readExact` 结果一致；
3. **pending 残留**：先读一行留下残留，再 `readExact`，覆盖跨缓冲拼接；
4. **EOF 中断**：不足 count 时抛 `MailIoException`，文案不变。

## D4 分配基准

- `F_EMAIL_BENCH=1`：192 KB 流式正文写出重复 200 次，记录 sink 之前的分配量；目标 ≤ 旧路径的 60%（少一块 64 KB + 每轮块）；
- `readExact(256 KB)` 重复 200 次；目标 ≤ 旧路径的 60%。
- 噪声大时只记录，不作为门禁（与既有基准口径一致）。

## 风险

| 风险 | 处理 |
| --- | --- |
| 编码器持有输入数组 | 已核对：只拷 carry / 布尔状态 |
| 切片读是否写穿 | `readUpTo` 既有实现已依赖同一语义；用例覆盖 |
| 并发共享缓冲 | 缓冲是每次调用的局部变量，不跨调用共享 |

## 实测记录（2026-11-22，`-O0`）

- 192 KB 流式附件写 100 次：`allocPerWrite=65,043,637 B`（含编码输出与 sink，只记录，不作门禁）；
- 本次确定消除的是每 part 的一块 64 KB（`rest`），以及 `readExact` 每轮一块 `tmp` 与只取 `.size` 的 64 KB `chunk`。
