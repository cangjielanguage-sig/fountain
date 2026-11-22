# 设计：分隔符延迟跳过

## Context

`RotatableBuffer.read` 当前的收尾分支会在 `offset == sectionEnd` 时立即消费 `\r\n--boundary`，并把 `offset` 推到下一 section。这个契约隐含假设「调用方读到 sectionEnd 就表示当前 section 已处理完」，但 `MultipartFormDataParser` 需要先 `indexOf(seperatorBoundaryBytes)` 确认内容长度，再决定读多少。

空内容 part 的 header 读取恰好结束在 `sectionEnd`（内容长度 0），于是分隔符在 `indexOf` 之前被吞掉。`offset` 已越过分隔符：

| 形状 | header 读完后 offset | `indexOf(separator)` | 结果 |
| --- | --- | --- | --- |
| 唯一的空 part | 已越过分隔符 | `-1` | 走流式分支，把 `--\r\n` 当内容，下一轮 EOF 抛 `MultipartException` |
| 空 part 在首位 | 已越过分隔符 | 下一 part 的分隔符 | 把下一 part 的 boundary 行与 header 当内容 |
| 空 part 在中间/末位 | 已越过分隔符 | `-1` 或后续分隔符 | 同上，后续 part 错位 |

探针（临时用例，已删除）确认六种形状全部失败：单独、首、中、尾、超窗口字段前后、半窗边界附近。

## Goals / Non-Goals

**Goals：**
- 空内容 part（空字段值、0 字节文件）正确解析，不抛异常。
- 非空 part 的解析结果与异常类型完全不变。
- `RotatableBuffer` 的公开签名与返回结构不变；`f_http` 仅调整两个流式循环的退出条件。

**Non-Goals：**
- 不重构 `parse()` 的分支结构，不引入 header 的按字节解析。
- 不为 `sectionEnd == 0` 及其他潜在窗口对齐边角单独补用例（入口跳过已覆盖其正常路径）。
- 内容长度恰为分块整数倍的歧义由 D2 的 `partEnd` 退出消除，不再单列。

## Decisions

### D1 延迟跳过分隔符，而不是在 parser 里补偿

**选择**：把「消费分隔符」从**本次 `read` 的收尾**移到**下一次 `read` 的入口**。

```cangjie
public func read(bytes: Array<Byte>): (length: Int64, remainder: Bool, partEnd: Bool) {
    // 上一次读停在 sectionEnd；分隔符延迟到本次入口才消费
    if (offset == sectionEnd) {
        if (sectionEnd + boundaryBytes.size >= halfBufferSize) {
            buffer = (buffer[1], buffer[0])
            offset += boundaryBytes.size - halfBufferSize
            if (bufferEnd < bufferSize) {
                bufferEnd -= halfBufferSize
                sectionEnd -= halfBufferSize
            } else {
                bufferEnd = halfBufferSize + input.read(buffer[1])
                sectionEnd = indexOf(boundaryBytes)
            }
        } else {
            offset = sectionEnd + boundaryBytes.size
            sectionEnd = indexOf(boundaryBytes)
        }
    }
    // 以下为原有 limit 计算、搬运、partEnd 与半窗/整窗旋转分支；
    // 仅删除原收尾的两个 sectionEnd 分支。
}
```

**理由**：
- 空 part 的 header 读完时 `offset == sectionEnd`，此时分隔符仍在，`indexOf` 返回 `offset`，`parse()` 走既有零长度分支，**分支结构不用改**。
- 非空 part：`parse()` 读内容到 `sectionEnd` 后同样停住；下一轮 `read`（循环顶部的 CRLF 读取）先跳过分隔符，再读到 boundary 行后的 `\r\n`，与旧时序完全等价。
- `partEnd` 仍是「本次读取结束在 sectionEnd」，语义不变。

**替代方案**：
- *在 `parse()` 里用 `partEnd` 判断空内容*：`partEnd` 为真并不代表分隔符已被消费。当 `offset == sectionEnd == halfBufferSize` 时收尾分支 1（半窗旋转）先命中，分隔符仍待消费，`offset` 还被重置为 0，无法区分。要可靠判定得给 `RotatableBuffer` 增加公开状态，污染 API。
- *在 `parse()` 里先算 `indexOf` 再读 header*：`read` 内部可能旋转窗口，读前坐标读后失效，且空内容判定仍依赖「跳没跳」。
- *让 `read` 返回四元组标明是否跳过*：破坏公开返回类型，所有调用方都要改。

### D2 流式/文件循环用 `partEnd` 退出

```cangjie
while(let (len, _, partEnd) <- stream.read(buf)){
    byteList.add(all: buf[0 .. len])
    if(partEnd || len < buf.size){
        break
    }
}
```

延迟跳过改变了「section 结束」的可观察信号：旧实现靠下一次 `read` 返回 0 让循环退出；新实现的下一次 `read` 直接返回下一段数据。

实测 8192 B 文本（恰为 8 × 1024）：第 8 次读 `len=1024, partEnd=true`，旧实现下一次读返回 `0`（offset 103）并退出；新实现下一次读返回 `--\r\n`（4 B，offset 107），被计入内容后 EOF 抛 `MultipartException`。

用 `partEnd` 退出即可，顺带消除「内容长度恰为分块大小整数倍」的同类隐患。文件分支同样改为每次写 `buf[0 .. len]`，避免 `len == buf.size` 与 section 结束重合时多写。

### D3 入口跳过的分支顺序

入口跳过沿用原收尾的两个判断，顺序为先跨半窗旋转、再普通前进：

- `sectionEnd + boundaryBytes.size >= halfBufferSize`：分隔符跨半窗，先交换两半缓冲并重定位 `offset`/`sectionEnd`，必要时补读后半窗。
- 否则：`offset = sectionEnd + boundaryBytes.size`，再 `indexOf` 定位下一 section。

这样不改变窗口布局，也不新增分配。

### D4 测试

- `f_io/src/RotatableBuffer_test.cj`：
  - `read` 停在 `sectionEnd` 后 `offset` 不变、`indexOf` 仍能找到分隔符；
  - 下一次 `read` 跳过并读到下一 section；
  - 分隔符跨半窗（`halfBufferSize: 8`）时的跳过与内容；
  - 连续 3 个 section 的顺序读取。
- `f_http/src/MultipartEmptyPart_test.cj`（新增）：
  - 单独空字段、空字段在首/中/尾、连续两个空字段；
  - 空字段紧邻超窗口字段（前/后）；
  - 空文件（`filename` + 0 B）的 `size` 与 `bytes()`；
  - 空字段后接多文件（确保分隔符未错位）。
- `f_http/src/MultipartFormDataParser_test.cj`：删除两处「空 part 已知缺陷」注释。

## Risks / Trade-offs

| 风险 | 处理 |
| --- | --- |
| `offset` 在读到 `sectionEnd` 后不再立即前进，外部若依赖旧时序会受影响 | 本仓库唯一调用方是 `MultipartFormDataParser`；其流式循环改用 `partEnd` 退出，`f_io` 既有 37 条测试回归 |
| 循环退出条件改动影响非空 part | 26 条既有 multipart 用例 + 8192 B 文本、两份落盘文件用例回归 |
| 入口跳过使「读空数组」也会推进分隔符 | 与原收尾行为一致（原来在读到 sectionEnd 的那次调用就推进），且保证每次调用有进展，不会死循环 |
| 分隔符跨半窗时旋转逻辑搬到入口 | 代码原样搬移，仅执行时机从「本次收尾」变为「下次入口」；半窗用例覆盖 |
| 空 part 首次参与流式分支的可能性 | `indexOf` 返回 `offset` 后走 `end > 0` 零长度分支，不会进入流式分支 |
| 公开 API 变化 | 无：`read` 签名、返回元组、`offset`/`indexOf` 均未变 |

## Migration Plan

- 局部修改 `f_io/src/RotatableBuffer.cj`，无数据/配置/协议迁移。
- 回退：`git revert` 单个提交即可；回退后空 part 恢复为抛 `MultipartException`，非空 part 不受影响。

## Open Questions

无。
