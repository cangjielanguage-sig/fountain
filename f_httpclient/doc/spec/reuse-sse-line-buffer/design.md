# 设计：`SseReader.readLine` 的实例字段字节行缓冲

## 1. 目标与约束

**目标**：消除 `SseReader.readLine` 每行新建 `ArrayList<Byte>` 及其扩容 / `toArray()` 拷贝，
改为实例字段的字节缓冲 + 已写长度，缓冲按需增长且上界为 `maxLineBytes`；
`next()` 的返回结果与现状逐字节一致。

**硬约束**：

| 约束 | 判定方式 |
| --- | --- |
| 事件与字段值逐字节不变 | 新增等价用例 + 既有 `SseReader_test.cj` 8 条一字不改 |
| CRLF、裸 `\r`、半行 EOF 语义不变 | 专项用例（`\r` 与 `\n` 跨块、EOF 保留 `\r`） |
| `maxLineBytes` 判定不变 | 恰好等于上限通过、上限 +1 抛 `SseLineTooLongException` |
| 缓冲不超上限 | 增长函数收敛到 `maxLineBytes`；超限在写入前抛错 |
| 公开 API 不变 | `git diff` 无 `public` 符号变化 |
| 不引入耗时门禁 | 基准只打印耗时，断言只用分配量 |

## 2. 现状与成本

`f_httpclient/src/sse/SseReader.cj:145-175`：

```cangjie
private func readLine(): ?String {
    let bytes = ArrayList<Byte>()            // 每行一次
    var sawAny = false
    while(true){
        if(pos >= len){
            if(eof){
                if(!sawAny){
                    return None<String>
                }
                return String.fromUtf8(bytes.toArray())      // EOF 半行：一次拷贝
            }
            fill()
            continue
        }
        let b = buffer[pos]
        pos++
        sawAny = true
        if(b == 0x0A){
            var end = bytes.size
            if(end > 0 && bytes[end - 1] == 0x0D){
                end--
            }
            return String.fromUtf8(bytes[0 .. end].toArray())  // 切片 + 拷贝
        }
        bytes.add(b)
        if(bytes.size > maxLineBytes){
            throw SseLineTooLongException(maxLineBytes)
        }
    }
    None<String>
}
```

设一行内容 `n` 字节、`ArrayList` 初始容量为 `C0`（`n <= C0` 时不扩容）。每行的堆分配：

| 项 | EOF 半行 | `\n` 结束 |
| --- | --- | --- |
| `ArrayList` 底层数组 | `max(C0, n)`（含扩容中间副本，若 `n > C0`） | 同左 |
| `bytes[0 .. end]` 切片 | — | `n` B |
| `toArray()` | `n` B | `n` B |
| `String.fromUtf8` 的 String | `n` B | `n` B |

SSE 的常态是「一条连接上几千条事件 × 每事件 2～5 行 × 每行几十字节」。
短行时 `ArrayList` 的固定开销（对象头 + 初始数组）甚至超过内容本身；
长行时 `ArrayList` 还会经历数次几何扩容拷贝。两类都是可以结构性消除的 churn。

**为什么不用 `@ local!`**：`docs/LocalMode.md:320` 把 `@ local!` 列为备选，但它仍要每行分配，
只是把分配放进 local region；`docs/LocalMode.md:439` 对本条路径的结论是
「字段缓冲 + `String.fromUtf8(buf, 0, n)` 即可，不需要 local」。

## 3. 方案对比

| 方案 | 每行分配 | 语义风险 | 结论 |
| --- | --- | --- | --- |
| **A 现状**：每行 `ArrayList<Byte>` + `toArray()` | 集合 + 1～2 次拷贝 | 无 | 否 |
| **B 实例字段 `Array<Byte>` + 已写长度** | 1 次前缀拷贝（可选 0 次）+ String | 低（见 §5） | **采纳** |
| **C `@ local!` 包住现状** | 同 A（换 region） | 无 | 否（不消除分配） |
| **D `ThreadLocal` 复用** | 0 | 无必要 | 否（`SseReader` 单线程，见 `proposal.md` Why-2） |
| **E 全局缓冲池** | 0 | 生命周期/借还管理复杂 | 否（缓冲天然属于单实例） |

选 B：

- `SseReader` 是非线程安全、单消费者的对象（`SseReader.cj:23-28`），字段缓冲不存在共享问题；
  这与 `f_jsonrpc` 必须用 `ThreadLocal` 的场景（`callAsync` 的 `spawn`）是不同前提。
- 缓冲大小随「见过的最长行」增长，之后稳定；上界由 `maxLineBytes` 锁死，不会被恶意长行放大。
- 不引入新依赖（`ByteBuffer` 在 stdx，`StringBuilder` 不适合按字节判行）。

## 4. 详细设计

### 4.1 字段与常量

```cangjie
private static let INITIAL_LINE_BYTES: Int64 = 256

/** 可复用的行字节缓冲；只有 [0, lineLen) 是有效前缀。init 中按 min(256, max(0, maxLineBytes)) 创建。 */
private var lineBuf: Array<Byte>
private var lineLen: Int64 = 0
```

`INITIAL_LINE_BYTES` 取 256：SSE 的字段行几乎都在这个量级以内，同时避免每行首字节就触发增长。
实际初始容量取 `min(256, max(0, maxLineBytes))`，因此 `maxLineBytes < 256` 时也不会超过上限。
**不**按 `maxLineBytes` 预分配：默认值是 1 MiB，预分配会把「每行小 churn」换成「每实例常驻 1 MiB」。

字段名与既有的 `buffer`（8 KiB 输入块缓冲）区分：前者是「一行」的累积区，后者是「一次 `read`」的落地区。

### 4.2 `readLine` 形态

```cangjie
private func readLine(): ?String {
    lineLen = 0
    var sawAny = false
    while(true){
        if(pos >= len){
            if(eof){
                if(!sawAny){
                    return None<String>
                }
                return takeLine(stripCr: false)     // EOF 半行不剥 \r
            }
            fill()
            continue
        }
        let b = buffer[pos]
        pos++
        sawAny = true
        if(b == 0x0A){
            return takeLine(stripCr: true)          // 只有 \n 结束才剥 \r
        }
        if(lineLen >= maxLineBytes){
            lineLen = 0
            throw SseLineTooLongException(maxLineBytes)
        }
        ensureLineCapacity(lineLen + 1)
        lineBuf[lineLen] = b
        lineLen += 1
    }
    None<String>
}
```

与现状的判定一一对应：

| 现状 | 新实现 |
| --- | --- |
| `bytes.add(b)` 之后判 `bytes.size > maxLineBytes` | 写入前判 `lineLen >= maxLineBytes`（等价：`lineLen == maxLineBytes` 时再写一个非 `\n` 字节就会超限） |
| `\n` 分支里 `end--` 剥 `\r` | `takeLine(stripCr: true)` |
| EOF 分支不剥 `\r` | `takeLine(stripCr: false)` |
| 每行新建集合，自然无残留 | 行首 `lineLen = 0`；`takeLine` 与抛错路径都复位 |

### 4.3 辅助函数

```cangjie
/** 把 [0, lineLen) 拷贝到更大的数组；容量上限 maxLineBytes。 */
private func ensureLineCapacity(need: Int64): Unit {
    if(need <= lineBuf.size){
        return
    }
    var want = lineBuf.size
    while(want < need){
        if(want >= maxLineBytes / 2){
            want = maxLineBytes
            break
        }
        want = want * 2
    }
    let grown = Array<Byte>(want, repeat: 0)
    for(i in 0 .. lineLen){
        grown[i] = lineBuf[i]
    }
    lineBuf = grown
}

/**
 * 用已写前缀构造一行并复位。
 * stripCr 只在以 \n 结束的行上为 true：EOF 半行保留末尾 \r（现状行为）。
 */
private func takeLine(stripCr: Bool): String {
    var end = lineLen
    if(stripCr && end > 0 && lineBuf[end - 1] == 0x0D){
        end -= 1
    }
    lineLen = 0
    String.fromUtf8(lineBuf[0 .. end])
}
```

要点：

1. **前缀切片**：`lineBuf[0 .. end]` 只包含已写字节，`fromUtf8` 不可能读到上一行的残余。
   编译器探针（本机 1.3.0-alpha）显示 `Array<Byte>` 的 `[a..b]` 返回**共享存储的视图**而非拷贝，
   且每次切片本身 0 分配；`String.fromUtf8` 会把视图内的字节复制进独立的 String
   （构造后改写源数组，String 不变），因此 I2「行缓冲不逃逸」仍然成立。
2. **复位先于构造**：若 `fromUtf8` 因非法 UTF-8 抛异常，`lineLen` 已经归零，下一次读取不会累积脏数据；
   这与现状「集合是局部变量、异常即丢弃」可观察行为一致。
3. **增长上界**：`want >= maxLineBytes / 2` 时直接收敛到 `maxLineBytes`，既不会超过上限，
   也避免了 `want * 2` 的溢出；`need <= maxLineBytes` 恒成立（超限已提前抛错），因此 `want` 足够。
4. **可选零拷贝**：若 std 文档确认存在 `String.fromUtf8(bytes, start, len)` 的前缀重载，
   把 `lineBuf[0 .. end]` 换成 `(lineBuf, 0, end)` 即可省掉一次切片拷贝；
   两者都只读前缀，语义不变。落地前用文档 + 编译探针确认（`docs/LocalMode.md:439` 的写法暗示存在，
   但本文不把它当成既定事实）。

### 4.4 不变量

| 编号 | 不变量 | 保证方式 |
| --- | --- | --- |
| I1 | 只消费 `[0, lineLen)` | `takeLine` 唯一出口用 `lineBuf[0 .. end]` |
| I2 | 行缓冲不逃逸 | `String.fromUtf8` 复制字节到 String，缓冲不被返回（切片是视图，但 String 持有独立存储） |
| I3 | 容量不超过 `max(maxLineBytes, 0)` | 初始取 `min(256, maxLineBytes)`；超限在写入前抛；`ensureLineCapacity` 收敛到 `maxLineBytes` |
| I4 | 行间无残留 | 行首与 `takeLine` / 抛错路径都置 `lineLen = 0` |
| I5 | 单线程使用 | `SseReader` 文档已声明非线程安全；本变更不新增并发入口 |
| I6 | `\n` 不计数、`\r` 计数 | `\n` 分支先返回；`\r` 作为普通字节写入，结束时才可能剥除 |
| I7 | 半行 EOF 不剥 `\r` | `takeLine(stripCr: false)` |

I6 是 `maxLineBytes` 边界等价的关键：现状里 `\r` 会先 `add` 进 `bytes` 并参与 `> maxLineBytes` 判定，
新实现同样把 `\r` 当普通字节写入并计数。

## 5. 等价性论证

对任意输入流，按「一行」的结束方式分类：

1. **`\n` 结束、无 `\r`**：新旧都把 `\n` 之前的 `lineLen` 字节交给 `String`；
   新实现多出的只是「前缀来自字段缓冲」。
2. **`\r\n` 结束**：旧实现在 `\n` 分支把末尾 `\r` 排除；新实现 `stripCr: true` 做同一件事。
   即使 `\r` 与 `\n` 分属两次 `read`，二者都已在 `lineBuf`/`bytes` 中，结论不变。
3. **空行**：`lineLen == 0`，`takeLine` 返回 `''`；旧实现返回空 `ArrayList` 的 `String`，同为 `''`。
4. **EOF 半行**：旧 `String.fromUtf8(bytes.toArray())` 不做 `\r` 剥除；新 `stripCr: false` 同。
5. **超限行**：旧在追加第 `maxLineBytes + 1` 个非 `\n` 字节后抛；新在写入该字节前抛。
   两者都已消费到该字节（`pos` 已前进），抛出的异常类型与参数相同，且都不返回事件。
6. **长短行交替**：`lineLen` 在每行首与每行出口复位，`takeLine` 只读 `[0, end)`，
   因此长行残留不会进入短行。
7. **非法 UTF-8**：两者都由 `String.fromUtf8` 抛同一类异常；新实现先复位 `lineLen`，
   后续读取的状态不劣于旧实现（旧实现的集合本就随栈帧丢弃）。

唯一需要测试兜底的是第 2、4、6 条，见 §6。

## 6. 测试设计

新增 `f_httpclient/src/sse/SseReaderLineBuffer_test.cj`，包 `fountain::f_httpclient.sse`。
复用 `SseReader_test.cj` 的 `streamOf` / `ChunkStream`（同包、文件内 `class` 的作用域需确认；
若不可见，则在测试文件内自带等价假流）。新增一个「限流假流」`ThrottledStream`，
每次 `read` 最多返回 `maxChunk` 字节，用于强制跨块。

### 6.1 用例清单

| 用例 | 步骤与断言 |
| --- | --- |
| `testShortLinesReuse` | 1000 行 `data: v<i>` + 空行；逐条断言 `data` 序号连续、最后返回 `None` |
| `testLongLineGrowsBuffer` | 单行内容 1000 B（> 初始 256）；`data` 长度与内容精确 |
| `testLineAcrossManyChunks` | `ThrottledStream(maxChunk: 7)` 喂 `data: ` + 9000 个 `x` + `\n\n`；断言长度 9000 且全为 `x` |
| `testCrlfSplitAcrossChunks` | 块序列 `data: a\r` / `\ndata: b\r` / `\n\r\n`；断言 `data == "a\nb"` |
| `testCrAtEofIsPreserved` | 流为 `data: a\r`（无 `\n`）；断言 `data == "a\r"` |
| `testStaleTailDoesNotLeak` | 先读 1000 B 长行，再读 `data: b`；断言第二条 `data == "b"` |
| `testMaxLineBytesExactlyAtLimit` | `maxLineBytes = 16`，构造 16 B 行；不抛，正常返回 |
| `testMaxLineBytesOverLimit` | 同一配置，构造 17 B 行；抛 `SseLineTooLongException` |
| `testHalfLineAtEof` | 流为 `data: abc`（无 `\n`）；断言 `data == "abc"` |
| `testBenchGateDefaultsOff` | 未设门控时打印 `SKIP:` |

### 6.2 边界构造

`maxLineBytes` 的边界必须按**整行字节数**算（含 `data: ` 前缀与 `\r`）：

- 16 B 行：`":0123456789012345"`（1 + 15 = 16）；
- 17 B 行：`":01234567890123456"`（1 + 16 = 17）；
- 两者都不含 `\n`，让判定落在行长上；再补一个 `\n` 结束。

### 6.3 分配基准（`F_HTTPCLIENT_SSE_BENCH=1`）

沿用 `f_jsonrpc` / `f_mcp` 的门控与测量写法（`f_jsonrpc/src/client/ReadBufferReuse_test.cj:363-419`）：

- `sseBenchEnabled()`：`getVariable("F_HTTPCLIENT_SSE_BENCH") == Some("1")`；
- `settleGc()`：`gc(heavy: true)` + 等 `getGCCount()` 连续 3 次不变；
- 分配量 = `(getAllocatedHeapSize 增量) + (getGCFreedSize 增量)`，5 样本中位数；
- 输出前缀 `SSE_LINEBUF_BENCH`。

| 用例 | 参数 | 断言 |
| --- | --- | --- |
| `case=line_reuse` | 20000 行 `: aaaa\n`，一次 `next()` 读完 | `allocPerLine <= 96` |
| `case=line_fresh` | 同窗口内每行 `ArrayList<Byte>` + `toArray()` + `fromUtf8` | 只打印；断言 `reuse * 2 < fresh` |
| `case=line_long` | 8192 B 行 × 200 | 只打印 `allocPerLine` / `nsPerLine` |
| `case=event_small` | 5000 条 `data: x\n\n`，走 `next()` | 只打印 `allocPerEvent` / `nsPerEvent` |

选「只含注释行」的流作为 `line_reuse` 的原因：注释行不产生事件、不进入 `data` 的
`ArrayList<String>` 与 `StringBuilder`，`next()` 在该流上的每行开销几乎只剩 `readLine` 本身，
可以把行缓冲的收益单独归因，而不被事件组装稀释。

`line_fresh` 必须在测试内**重现旧算法**（`ArrayList<Byte>` 累积 → `[0..n].toArray()` → `fromUtf8`），
不能调用已被替换的实现，否则对照失效。

`-O0` 测试构建下的耗时只作参考，不作断言。

`-O0` 还会给每次 `Array<Byte>` 下标读写记 16 B 堆分配（§10.1 的编译探针：6 次读 = 96 B，`-O2` 下为 0）。
SSE 每行至少 7 次流缓冲读取，因此 `-O0` 下「摊销分配 `<= 96 B/行`」在数学上不可达。
分配门控按 `docs/LocalMode.md:920` 的口径执行：临时给 `f_httpclient/cjpm.toml` 追加 `-O2`，
跑完回退，不提交优化选项。`-O0` 下的同一门控只作参考。

## 7. 验收

| 项 | 标准 |
| --- | --- |
| 等价性 | 新增 9 条行为用例全部通过；`SseReader_test.cj` 8 条既有用例一字不改、通过 |
| 边界 | 恰好 `maxLineBytes` 通过、`+1` 抛 `SseLineTooLongException`；EOF 半行保留 `\r` |
| 分配 | 门控下 `line_reuse allocPerLine <= 96`，且 `reuse * 2 < fresh` |
| 回归 | `cd f_httpclient && cjpm test` 全绿；`cjpm build` 不新增 WARNING |
| 契约 | `git diff` 无 `public` 符号变化；仅新增私有常量 / 字段 / 辅助函数并替换 `readLine` 函数体 |

## 8. 风险与回退

| 风险 | 处理 |
| --- | --- |
| 前缀切片仍是一次拷贝 | 已消除集合与额外 `toArray` 拷贝；若存在三参 `fromUtf8` 重载可进一步省掉（§4.3） |
| 长行把缓冲撑大后常驻 | 上界 `maxLineBytes`；容量只增不减是复用对象的正常取舍，且短行不再触发分配 |
| 跨线程误用 `SseReader` | 现状同样不安全（类文档已声明非线程安全），本变更不改变并发契约 |
| `maxLineBytes` 很小（< 256） | 初始容量取 `min(256, maxLineBytes)`，不会超过上限；最多为 0 时缓冲为空 |
| `lineLen` 在异常路径未复位 | 抛错前与 `takeLine` 内都显式归零，并有用例覆盖「超限后再读」 |
| 基准被 `-O0` 与机器负载影响 | 只打印耗时；断言只用确定性的分配量 |

**回退**：改动集中在 `SseReader.cj` 的行读取路径，`git revert` 该提交即可恢复；
无数据、配置、协议影响。

## 9. 落地顺序

1. 用 std 文档确认：`String.fromUtf8` 的前缀重载是否存在、`Array<Byte>` 切片是否为拷贝
   （本仓先例：`f_excel/src/CalcFunctionsStatTextExt.cj` 用 `bytes[0..n]` 直接喂 `fromUtf8`）；
2. 记录基线分配（临时探针，不入库）：旧 `readLine` 在 20000 行短行上的摊销分配；
3. 写新增用例（Red）；
4. 实现字段、辅助函数与 `readLine` 替换（Green）；
5. 跑门控基准，把输出写入 §10；
6. `cd f_httpclient && cjpm test` 全绿后独立提交。

## 10. 实测记录

环境：`aarch64-unknown-linux-gnu`、`Cangjie Compiler 1.3.0-alpha.20261118001016`、7 核。
样本数 5，分配量取中位数，口径为 `(getAllocatedHeapSize 增量) + (getGCFreedSize 增量)`。

### 10.1 构建模式对比（先看这一节）

同一个实现、同一份输入，`cjpm test` 默认的 `-O0` 构建会给**每次 `Array<Byte>` 下标读写**记 16 B
堆分配；编译探针实测：6 次读 = 96 B、6 次写 = 96 B，`-O2` 下均为 0。SSE 每行至少 7 次流缓冲读取，
所以 `-O0` 下「`<= 96 B/行`」不可达，门控断言只在 `-O2` 构建下有效（§6.3）。

| 构建 | `line_reuse` allocPerLine | `line_fresh` allocPerLine | 比值 |
| --- | --- | --- | --- |
| `-O0`（默认 `cjpm test`，仅参考） | 528 | 424 | 1.24× |
| `-O2`（门控口径） | 24 | 104 | 4.33× |

`-O0` 下 `line_reuse` 反而高于 `line_fresh`：后者只是「旧算法 + 局部下标循环」，没有 `SseReader`
每字节的 `pos` / `len` / `eof` / `fill` 分支；两者都含每字节 16 B 的 `-O0` 代码生成开销。

### 10.2 门控输出（`-O2`）

执行方式（`docs/LocalMode.md:920`：临时追加 `-O2`，测完回退，不提交）：

```bash
# f_httpclient/cjpm.toml 的 [package] compile-option / override-compile-option 追加 -O2
cd f_httpclient && F_HTTPCLIENT_SSE_BENCH=1 cjpm test --filter '*SseReaderLineBuffer*' --show-all-output
# 测完恢复 cjpm.toml
```

| case | ops | allocTotal | allocPerOp | nsPerOp | 样本 |
| --- | --- | --- | --- | --- | --- |
| `line_reuse` | 20000 | 489048 | 24 | 430 | 5 |
| `line_fresh` | 20000 | 2080496 | 104 | 311 | 5 |
| `line_long` | 200 | 1900544 | 9502 | 82882 | 5 |
| `event_small` | 5000 | 2253312 | 450 | 674 | 5 |

### 10.3 改造前基线（临时探针，未入库）

| 口径 | `line_reuse` allocPerLine |
| --- | --- |
| 旧 `SseReader.readLine`，`-O0` | 704 |
| 旧算法副本（`line_fresh`），`-O2` | 104 |

`-O2` 下新实现把每行摊销分配从 104 B 降到 24 B（4.33×），与 §2 的成本模型一致。

