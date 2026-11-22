# 提案：`SseReader.readLine` 改为实例字段字节行缓冲

> **唯一入库副本**：`f_httpclient/doc/spec/reuse-sse-line-buffer/`。`openspec/changes/reuse-sse-line-buffer/`
> 是本地工作副本（`openspec/` 已被 `.gitignore:62` 忽略）；两份逐文件字节一致。
> 同步：以 `f_httpclient/doc/spec/reuse-sse-line-buffer/` 为准 `cp -a` 到
> `openspec/changes/reuse-sse-line-buffer/`（本机无 rsync）。
> 校验：`diff -ru f_httpclient/doc/spec/reuse-sse-line-buffer openspec/changes/reuse-sse-line-buffer` 无输出。

## Why

1. **每一行都新建一个 `ArrayList<Byte>`，短行占绝对多数**。
   `f_httpclient/src/sse/SseReader.cj:145-175` 的 `readLine` 每读一行都：

   ```cangjie
   let bytes = ArrayList<Byte>()          // 145-146
   ...
   bytes.add(b)                           // 169
   return String.fromUtf8(bytes[0 .. end].toArray())   // 167
   ```

   一行内容的字节数为 `n` 时，这一行至少产生：`ArrayList` 自身存储（含初始容量与几何扩容）、
   一次 `[0..end]` 切片、一次 `toArray()` 全量拷贝、一次 `String.fromUtf8` 拷贝。
   SSE 的正常行是 `data: ...` / `event: ...` 这种几十字节的短行，一条事件 2～5 行，
   也就是说**每个事件都要重复若干次「分配小集合 + 扩容 + 复制」**。对 LLM 流式输出这类
   长期连接（只读一次响应、但持续产出成百上千条事件），这是持续性的分配 churn。

2. **`SseReader` 本身就是单消费者对象，字段缓冲是安全的**。
   类文档（`SseReader.cj:23-28`）明确「非线程安全」，实例只被一个读取方按 `next()` 顺序调用，
   没有 `spawn` 并发读取。因此缓冲可以挂在实例字段上，不需要 `ThreadLocal`。
   这一点与 `f_jsonrpc` 的 `readCapped` 不同（后者被 `callAsync` 的 `spawn` 并发进入，
   必须线程本地，见 `f_jsonrpc/doc/spec/reuse-jsonrpc-read-buffer/proposal.md:24-29`）。

3. **仓库既有结论已经指向这个方向**。
   `docs/LocalMode.md:439` 对这条路径的结论是：「`SseReader.readLine` 每行 `ArrayList<Byte>` +
   `toArray()` 双份……`SseReader` 本身就是可复用对象，改成『字段缓冲 + `String.fromUtf8(buf, 0, n)`』
   即可，不需要 local。」`docs/LocalMode.md:320` 的备选也是「`@ local!`，或复用字段缓冲」。
   复用字段缓冲同时消除了分配本身，而 `@ local!` 只改变分配位置。

4. **行上限决定了缓冲必须「按需增长」，不能一次性按 `maxLineBytes` 预分配**。
   `maxLineBytes` 默认 1 MiB；绝大多数行只有几十字节。若构造时就分配 1 MiB，
   等于把「每行的小 churn」换成「每个 `SseReader` 常驻 1 MiB」，是更差的取舍。
   因此缓冲从小容量起步，按几何倍数增长，**上限锁死在 `maxLineBytes`**。

5. **语义必须逐字节不变**：`\n` 与 `\r\n`、以 `:` 开头的注释、空行分隔事件、
   `data` 多行以 `\n` 拼接、字段值去掉一个前导空格、未知字段忽略、
   单行超过 `maxLineBytes` 抛 `SseLineTooLongException`、流结束返回 `None`、
   EOF 时的半行按残留内容返回。以上每一条都已由 `SseReader_test.cj` 与
   `f_httpclient/doc/spec/f-llm-openai-compat/specs/http-sse-client/spec.md` 固定。

6. **公开契约不能动**：`SseReader` 的构造参数（`body` / `maxLineBytes` / `idleTimeout`）、
   `next()` / `close()` / `isClosed()`、`SseEvent`、`SseException` 家族、
   `HttpResponse.sseReader(...)` 的签名与默认值全部保持不变。本变更只改私有实现。

## What Changes

### A. 新增实例字段与常量（`SseReader` 内部）

- `private static let INITIAL_LINE_BYTES: Int64 = 256`：行缓冲初始容量上限。
  实际初始容量取 `min(256, max(0, maxLineBytes))`：短行场景不浪费，`maxLineBytes < 256` 时也不会超过上限。
- `private var lineBuf: Array<Byte>`：构造时按上述初始容量创建，可复用的字节行缓冲。
- `private var lineLen: Int64 = 0`：本次行已写入的字节数（`[0, lineLen)` 才是有效前缀）。

缓冲与 `buffer`（8 KiB 输入块缓冲）是两个独立的字段，互不影响。

### B. `readLine` 不再创建集合

把 `ArrayList<Byte>` 的「追加—扩容—拷贝」换成：

1. 每条新行开始时 `lineLen = 0`；
2. 读到非 `\n` 字节时，先判定 `lineLen >= maxLineBytes`（超限直接抛，判定位置与现状一致），
   再按需扩容并写入 `lineBuf[lineLen]`，`lineLen++`；
3. 读到 `\n`（或以 EOF 结束半行）时，用 `[0, lineLen)` 构造 `String`；
   `\n` 结束的行若最后一个字节是 `\r` 则前移一位。EOF 半行不剥除 `\r`（与现状一致）；
4. 构造 `String` 后立即 `lineLen = 0`，异常路径同样复位。

新增两个私有辅助函数：`ensureLineCapacity(need)` 与 `takeLine(stripCr)`；
`readLine` 的返回类型、`None` 语义、抛错类型全部不变。

### C. 增长策略

- 只在 `lineLen == lineBuf.size` 时增长；
- 新容量按 2 倍递增，并在 `maxLineBytes / 2` 处收敛到 `maxLineBytes`，**绝不越界多分配**；
- 容量只增不减（与「可复用对象」的定位一致），上界为 `max(max(INITIAL_LINE_BYTES, 最长行), …)`
  且不超过 `maxLineBytes`；
- 容量一旦长到某条长行的长度，后续短行直接复用，不再分配。

### D. `String` 只读已写前缀

`String.fromUtf8` 的入参必须只含 `[0, lineLen)`（剥 `\r` 后再减一），
**不得把整块 `lineBuf` 交给 `fromUtf8`**，否则上一轮长行的尾部会进入本行内容。
落地时优先使用 `lineBuf[0 .. end]` 前缀切片；若 std 文档确认存在
`String.fromUtf8(Array<Byte>, start, len)` 形式的前缀重载，则改用它省掉这次切片拷贝
（见 `design.md` §4.3，属可选优化，不改变语义）。

### E. 测试

新增 `f_httpclient/src/sse/SseReaderLineBuffer_test.cj`（同包），覆盖：

- 短行连续（1000 行）内容正确；
- 长行（超过初始容量）与跨多次 `read` 才补齐的行；
- `\r\n` 且 `\r` 与 `\n` 落在不同块；
- 长短行交替，确认上一条长行的残留字节不泄漏；
- `maxLineBytes` 边界：恰好等于上限通过，上限 +1 抛 `SseLineTooLongException`；
- EOF 半行（含以 `\r` 结尾的半行保留 `\r`）；
- 既有 `SseReader_test.cj` 的 8 条用例**一字不改**，作为行为不变的硬约束。

### F. 分配基准（`F_HTTPCLIENT_SSE_BENCH=1` 门控）

- `case=line_reuse`：对只含注释行的流连续读 20000 行，断言摊销分配 `<= 96 B/行`；
- `case=line_fresh`：同窗口内用「每行新建 `ArrayList<Byte>` + `toArray()`」的旧形态作对照，只打印；
  并断言 `line_reuse * 2 < line_fresh`；
- `case=line_long`：8 KiB 长行重复 200 次，打印 `allocPerLine` / `nsPerLine`，
  证明扩容只发生在第一次；
- `case=event_small`：5000 条 `data: x` 事件走完整 `next()`，打印 `allocPerEvent` / `nsPerEvent`；
- 未设门控时打印 `SKIP:` 并返回，常规 `cjpm test` 不受影响。

## Impact

- **修改代码**：`f_httpclient/src/sse/SseReader.cj` —— 新增 1 个常量、2 个实例字段、
  2 个私有辅助函数；`readLine` 函数体替换（判定顺序、异常类型、返回语义不变）。
- **新增代码**：`f_httpclient/src/sse/SseReaderLineBuffer_test.cj`。
- **公开 API**：0 处变更；无新增配置项、无新增公开类型。
- **依赖**：不改 `cjpm.toml`，不新增第三方依赖。
- **行为**：对任意输入流，`next()` 返回的 `SseEvent` 字段与现状逐字节相同；
  超限抛错时机、空闲超时判定、`close()` 行为均不变。
- **内存**：每个 `SseReader` 常驻一块行缓冲，初始 `min(256, max(0, maxLineBytes))`，随最长行增长，
  上界 `maxLineBytes`；与流长度、行数无关。
- **风险**：调用方若错误地跨线程共享同一个 `SseReader`，本变更不引入新的不安全点
  （现状同样不安全，字段缓冲只是把「每行临时集合」换成「实例缓冲」）。

## Out of Scope

- **不改成 `ByteBuffer` / `StringBuilder` 累积**：`ByteBuffer` 是 stdx 依赖，`StringBuilder`
  按 `String` 追加会在字节层丢失「按字节判行 + 按字节限长」的语义；字段 `Array<Byte>` 最贴近现状。
- **不做零拷贝 `unsafe` 构造**：`String` 不可变且拥有自己的存储，零拷贝需要依赖未公开的
  内部布局；收益（每行省一次小拷贝）与风险不匹配。
- **不改 8 KiB 输入块缓冲**：`fill()` 的 `buffer` 已经是复用的实例字段，不属于本问题。
- **不改 `next()` 的事件组装**（`ArrayList<String>` 存 `data` 行、`StringBuilder` 拼接）：
  这是事件级而非行级的分配，量级与事件数同阶，另行评估。
- **不改 `maxLineBytes` 默认值与配置面**：公开 API 不变。
- **不做 `@ local!`**：字段复用已经从结构上消除分配，local 只降低单次分配成本。
- **不做全局缓冲池**：缓冲归属单个 `SseReader`，没有跨实例共享的必要，池化只会引入生命周期管理。
