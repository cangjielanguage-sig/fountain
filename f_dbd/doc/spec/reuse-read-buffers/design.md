# 设计：复用三处读缓冲

## D1 f_dbd `readChunk`

```cangjie
let out = ArrayList<Byte>()
let buf = Array<Byte>(DEFAULT_STREAM_CHUNK, repeat: 0u8)
var got = 0i64
while (toEnd || got < size) {
    let remaining = if (toEnd) { DEFAULT_STREAM_CHUNK } else { size - got }
    let want = if (remaining < DEFAULT_STREAM_CHUNK) { remaining } else { DEFAULT_STREAM_CHUNK }
    let n = stream.read(buf[0..want])
    if (n <= 0) { break }
    out.add(all: buf[0..n])
    got += n
}
out.toArray()
```

- 一块缓冲跨轮复用；`buf[0..want]` 是数组切片视图，直接写穿；
- `add(all:)` 与逐字节 `add` 写出的字节完全一致；
- 输出仍是 `out.toArray()`，EOF 表征（空数组/短块）不变。

## D2 f_zip 直接读入目标

`BoundedStream.read` 与 `FileRangeBoundedStream.read` 的越界分支：

```cangjie
let n = input.read(buffer[0..remaining])   // 或 file.read(...)
if (n <= 0) { remaining = 0; return -1 }
remaining -= n
n
```

`EntrySource.readAt`：

```cangjie
while (got < want) {
    let n = file.read(dst[got..want])
    if (n <= 0) { break }
    got += n
}
got
```

- 原实现的 `tmp` 只是「读进来再拷到目标」的中转，目标本身就是可写数组，直接读入等价；
- `read` 返回值仍是实际写入目标的字节数。

## D3 f_excel `sliceAt`

```cangjie
let total = this.lengths[index]
if (total == 0) { return None<String> }
let bytes = Array<UInt8>(total, repeat: 0)
var got: Int64 = 0
while (got < total) {
    let n = handle.read(bytes[got..total])
    if (n <= 0) { break }
    got += n
}
if (got == 0) { return None<String> }
Some(String.fromUtf8(bytes[0..got]))
```

- 保留「部分读也返回已读内容」的既有语义；
- 删除 4 KB 中间缓冲与逐字节 `ArrayList`。

## D4 测试与基准

1. f_dbd：`readChunk(stream, 0)` 读至 EOF、`size` 精确、跨块、空流；
2. f_zip：`readAt` 的 `dst` 大于/等于/小于剩余；`BoundedInputStream` 同样三态；部分读与 EOF；
3. f_excel：共享字符串长度 0、小于 4 KB、跨 4 KB、跨多次 read；
4. 基准：
   - f_zip 两处断言「读窗口内不产生临时数组」：1 MiB `readAt` 与 256 KiB 限长流，旧实现分别为 1 MiB / 256 KiB，新实现应为 0；
   - f_dbd 的 `readChunk` 输出数组与 `ArrayList` 增长占主导，基准只记录分配，不作硬门禁；
   - f_excel 的公开 `get()` 会构建并缓存解析表，分配量包含表格构建，无法隔离 `sliceAt`；只保留行为用例，不设分配门禁。

## 风险

| 风险 | 处理 |
| --- | --- |
| 切片读未写穿 | `MimeWriter.readUpTo` 已依赖同一语义；f_zip 的 0 分配断言可反证 |
| f_zip `read` 返回 -1 与 0 的区别 | 保持原分支顺序与返回值 |
| f_excel 部分读语义 | 按 `got` 截断，仍返回已读部分 |

## 实测记录（2026-11-22，`-O0`）

- f_zip `readAt` 读取 1 MiB：窗口内分配 **0 B**（旧实现先建 1 MiB `tmp` 再拷贝）；
- f_zip 限长流读取 256 KiB：窗口内分配 **0 B**（旧实现先建 256 KiB `tmp`）；
- f_dbd 1 MiB「读至 EOF」：总分配 5,436,040 B（输出数组与 `ArrayList` 增长占主导，只记录）；
- f_excel 公开 `get()` 会构建并缓存解析表，无法隔离 `sliceAt`，只保留行为用例。
