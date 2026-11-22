# 复用三处读缓冲（f_dbd / f_zip / f_excel）

## 为什么

三处读路径都在「目标缓冲小于剩余长度」时新建整块临时数组，读完再拷贝：

| 模块 | 位置 | 现状 | 每次浪费 |
| --- | --- | --- | --- |
| f_dbd | `DbdStatementTypes.readChunk` | 每轮 `Array<Byte>(want)`（≤64 KB）+ 逐字节 `add` | 每 64 KB 一块临时 + 每字节一次 `add` |
| f_zip | `BoundedStream.read` / `FileRangeBoundedStream.read` | `buffer.size > remaining` 时 `Array<Byte>(remaining)` 再拷贝 | 每个流一块 `remaining` |
| f_zip | `EntrySource.readAt` | 每轮 `Array<Byte>(want - got)` 再拷贝 | 每轮一块剩余长度 |
| f_excel | `SharedStringIndex.sliceAt` | 4 KB 读缓冲 + `ArrayList<UInt8>` 逐字节收集 | 每字符串 4 KB + 逐字节扩容 |

四处都是纯中间缓冲，但都作为 `InputStream.read` 的实参（`@ ~local`），实测无法 local 化；应直接读入目标切片或复用一个块。

## 变更什么

- f_dbd：`readChunk` 用一块 `DEFAULT_STREAM_CHUNK` 缓冲，循环 `stream.read(buf[0..want])`，结果用 `add(all: buf[0..n])` 批量追加。
- f_zip：`BoundedStream` 与 `FileRangeBoundedStream` 的 `buffer.size > remaining` 分支直接 `input.read(buffer[0..remaining])`；`EntrySource.readAt` 直接 `file.read(dst[got..want])`。
- f_excel：`sliceAt` 按已知长度一次分配 `Array<UInt8>(len)`，循环 `handle.read(bytes[got..total])`，末尾 `String.fromUtf8(bytes[0..got])`。
- 返回字节、异常、部分读语义全部不变。

## 影响

- 生产代码：`f_dbd/src/common/types.cj`、`f_zip/src/BoundedStream.cj`、`f_zip/src/EntrySource.cj`、`f_excel/src/SharedStringIndex.cj`。
- 契约：无 `public` 变化。

## 验收

- f_dbd：`readChunk` 精确长度、读至 EOF、短块、空流四种形态字节一致；
- f_zip：`readAt`/`BoundedStream.read` 在 dst/remaining 大小交叉、EOF、部分读下字节一致；
- f_excel：共享字符串在跨 4 KB、空串、部分读到 EOF 下结果一致；
- 分配基准（env gated）记录四处单次调用的中间分配下降；
- 三模块全量回归通过。

## 明确不做

- 不改 `readChunk` 的 EOF 表征（空数组）与调用方约定。
- 不改 f_zip 的 zip 格式处理与 f_excel 的 sharedStrings 索引格式。
- 不做 local 化。
