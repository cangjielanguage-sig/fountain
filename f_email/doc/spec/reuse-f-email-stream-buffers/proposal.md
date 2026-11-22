# 复用 f_email 流式缓冲

## 为什么

两处每次调用都整块申请 64 KB：

| 位置 | 现状 | 每次浪费 |
| --- | --- | --- |
| `MimeWriter.writeLeafStream` | `sampleBuffer` 64 KB + `rest` 64 KB | 128 KB / 附件 part，且第一块只用于采样 |
| `LineChannel.readExact` | `chunk` 64 KB 只用来取 `.size`；循环内再按 `want` 新建 `tmp` | 64 KB 空数组 + 每次循环一块 `tmp` |

两处都是函数内临时缓冲，但都作为 `InputStream.read` / `OutputStream.write` 的实参（`@ ~local`），按实测无法 local 化；应直接复用。

## 变更什么

- `MimeWriter.writeLeafStream`：只分配一块 64 KB 缓冲。采样并 `encoded.write(sample)` 之后，同一块内存继续用于读取剩余字节。
- `LineChannel.readExact`：65536 改为包内常量；每次调用分配一块 64 KB 缓冲，循环用 `buf[0 .. want]` 读取，再批量拷贝到结果；删除只取 `.size` 的 `chunk` 与每轮 `tmp`。
- 输出字节、异常类型、读超时行为全部不变。

## 影响

- 生产代码：`f_email/src/mime/MimeWriter.cj`、`f_email/src/transport/LineChannel.cj`。
- 契约：无 `public` 变化。

## 验收

- `writeLeafStream` 输出与内存路径（`writeLeaf`）逐字节一致，覆盖 > 64 KB、恰 64 KB、< 64 KB 三种正文；
- `readExact` 在分块大小 1/7/4096/65536、跨 pending 残留、EOF 提前中断下字节正确；
- 分配基准（env gated）：单次流式 part 的中间缓冲从 128 KB + 循环块降到 64 KB 一块；`readExact` 从每次一块 `tmp` 降到一次一块；
- `f_email` 全量回归通过。

## 明确不做

- 不改编码选择规则、换行规范化和 CRLF 注入防线。
- 不做 local 化（I/O 形参阻断）。
- 不引入跨连接共享缓冲（线程安全边界不变）。
