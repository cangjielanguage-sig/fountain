# 设计：multipart 流式块复用 + EOF / 多文件 / 落盘读取修复

## 1. 目标与约束

**目标**：
1. 复用 `MultipartFormDataParser` 的 1 KB 流式块与 2 B CRLF，消除多 part 场景的重复分配；
2. 修 3 个既有缺陷：截断报文死循环（b）、多落盘文件目录冲突（c）、落盘 `bytes()` 必失败（d）；
3. 建立 `f_http` 首批回归测试与 `f_io` 的 EOF 用例。

**硬约束**：
- 正常报文的解析结果不变；
- `f_http` / `f_io` 公开 API 0 变化；
- 空内容 part（a）不在本变更内，另开 `fix/multipart-empty-part`。

## 2. 现状与发现

### 2.1 `String.unsafeUtf8` 是零拷贝别名，header 不能复用

探针：`s = String.unsafeUtf8(a)` 后改 `a[0]`，`s` 内容跟着变；`String.fromUtf8` 才复制。
header 的 `split('\r\n')` 子串会以 `DataMultipartTuples` key、`ContentDisposition.name/filename` 逃逸到返回的 `Data`。
复用 headerBuf + `unsafeUtf8` 会让下一个 part 改写上一个 part（实测 key `long` → `brie`、filename 残留 1900 B）。
改用 `fromUtf8` 复制后，每 part 仍复制 `headerLen` 字节，header 复用净收益≈0。
**结论：header 保持精确长度 `Array` + `unsafeUtf8`，不复用。**

### 2.2 既有缺陷

| # | 现象 | 根因 | 处理 |
| --- | --- | --- | --- |
| a | 空内容 part 失败/此前死循环 | `RotatableBuffer` 在 `sectionEnd` 处提前旋转，吞掉空 part 分隔符 | 另开 fix，本变更不覆盖 |
| b | 截断报文死循环 | `read` 不按 `bufferEnd` 截断，EOF 后仍返回满长度 | 本变更修 |
| c | ≥2 个落盘文件 `Directory.create already exists` | 每个文件 part 都 `Directory.create` | 本变更修 |
| d | 落盘 `MultipartFile.bytes()` 抛 `FSException` | `copyTo` 与 `bytes` 各 close 一次；4096 整块写超 `ByteBuffer` 容量 | 本变更修 |

## 3. 决策

### D1 只复用 `chunkBuf` 与 `crlf`

```cangjie
private let crlf = Array<Byte>(2, repeat: 0)
private var chunkBuf = Array<Byte>(0, repeat: 0)

func chunkBuffer(): Array<Byte> {
    if (chunkBuf.size == 0) {
        chunkBuf = Array<Byte>(STREAM_CHUNK_BYTES, repeat: 0)   // 1024
    }
    chunkBuf
}
```

- 文本流式分支与文件分支都改用 `chunkBuffer()`；循环只用 `buf[0..len)`，缓冲不逃逸，复用安全。
- `crlf` 每次读前把两个字节置 0，保持“新建数组零尾部”的语义。
- header 仍是 `Array<Byte>(headerLen)` + `stream.read` + `String.unsafeUtf8`。
- 不预分配 `chunkBuf`：只有进入流式/文件分支才创建 1024 B；纯小表单不增加常驻。

### D2 `RotatableBuffer.read` 按 `bufferEnd` 截断（修 b）

```cangjie
let windowEnd = if (sectionEnd > 0 && sectionEnd < bufferSize) { sectionEnd } else { bufferSize }
let dataEnd = if (bufferEnd < 0) { 0 } else if (bufferEnd < bufferSize) { bufferEnd } else { bufferSize }
let limit = if (windowEnd < dataEnd) { windowEnd } else { dataEnd }
let rawSize = if (bytes.size < limit - offset) { bytes.size } else { limit - offset }
let size = if (rawSize < 0) { 0 } else { rawSize }
```

- `bufferEnd < bufferSize` 表示底层流已读完；必须与 `sectionEnd` 取较小值，避免读窗口后半的旧/零字节。
- `size` 钳制到非负，避免 `offset += size` 回退。
- 正数据与 section/boundary 的旋转逻辑保持不变；f_io 原有 30 条测试 + 3 条新 EOF 用例全绿。

### D3 多文件目录（修 c）

文件分支：
```cangjie
if (!exists(path)) {
    Directory.create(path, recursive: true)
}
```
parser 单线程，检查-创建无竞态；第二次文件 part 复用同一目录。

### D4 `MultipartFile.bytes()`（修 d）

```cangjie
public func bytes(): Array<Byte> {
    match (content) {
        case input: ByteBuffer => input.bytes()
        case file: File =>
            let buffer = ByteBuffer(initialCapacity: file.length)
            copyTo(buffer)          // copyTo 内部只 close 一次
            buffer.bytes()
        case _ =>
            let buffer = ByteBuffer(initialCapacity: 64 * 1024)
            copyTo(buffer)
            buffer.bytes()
    }
}
```
- 去掉 `bytes()` 的 `finally close()`，避免第二次 close 对已删除父目录调 `Directory.isEmpty`。
- 按文件长度预分配 `ByteBuffer`，4096 B 整块写不会超容量。

### D5 测试

- `f_http/src/MultipartFormDataParser_test.cj`：21 条回归（字段/文件/多 part/CRLF/畸形/媒体类型），含截断报文、多文件、落盘 bytes；
- `f_http/src/MultipartBufferReuse_test.cj`：5 条（长/短 header 前后、3 文件 chunk 复用、残留、parser 独立）；
- `f_io/src/RotatableBuffer_test.cj`：3 条 EOF（普通/空流/恰好半窗）。
- 空 part 用例明确不加入，注释指向 `fix/multipart-empty-part`。

## 4. 等价性

- 正常报文：header 仍精确数组 + unsafeUtf8；`end >0` 分支仍精确分配内容数组；两个流式分支只换 1024 B 来源，`read` 的 `len` 序列与 `[0,len)` 内容不变。
- 截断报文：read 在 EOF 返回 0，流式分支 break，随后外层 `crlf` 读到 `(0,0)` 抛 `MultipartException`（不再死循环）。
- 多文件：目录只建一次，每个 part 的 `File` 路径独立（各自 `UUID` 子目录）。
- 落盘 bytes：`ByteBuffer` 容量 = 文件长度，`copyTo` 只 close 一次，返回内容逐字节一致。

## 5. 验收

| 项 | 标准 |
| --- | --- |
| f_http | `cjpm test` 26/26 |
| f_io | `cjpm test` 33/33 |
| 契约 | `f_http` / `f_io` 无 `public` 变化 |
| 已知缺陷 | 空 part 仍抛 `MultipartException`，但不死循环；另开 fix |

## 6. 风险与回退

| 风险 | 处理 |
| --- | --- |
| f_io `read` 改动影响既有调用 | 只增加 `dataEnd` 上限与非负钳制；原有 30 条测试 + 新 3 条过 |
| chunkBuf 复用串扰 | 只用 `[0,len)`；文件写入/ArrayList.add 都复制 |
| 多文件目录检查竞态 | parser 单线程；同一实例只 parse 一次 |
| 落盘 bytes 容量 | 按 `file.length` 预分配；非文件流 64 KiB 起 |
| 空 part 仍未修 | 文档明确，另开 `fix/multipart-empty-part` |

**回退**：三个文件的局部修改，`git revert` 即可；无数据/配置/协议影响。
