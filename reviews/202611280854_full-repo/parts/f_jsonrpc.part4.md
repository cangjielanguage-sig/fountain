# f_jsonrpc 模块审查报告（模块第 4/4 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_jsonrpc`（模块共 32 个 `.cj` + 30 个 `.md`；**本部分只覆盖 2 个 `.cj`**：SSE 内核 `SseStream.cj` 与其用例 `Sse_test.cj`）
- **基线**：工作区快照（sts/1.3.x，无 diff 基线；`git blame` 两个文件全部指向 2026-11-10 `00d2a8f6d`「feat(f_jsonrpc.sse): 服务端推送内核——SseStream…；8 条用例」，故全部记为「存量」）
- **审查重点**：RPC 协议正确性、批量与错误码、超时与资源、死代码、重复逻辑、存量 BUG（本部分实际落点为「流式读契约 / 心跳超时 / 有界丢弃 / 关闭释放 / 用例有效性」）
- **报告版本**：v1（分报告；模块报告由主 Agent 合并 4 个部分后写入 `docs/review/2026-11-28/f_jsonrpc.md`）

## 发现

### [一般][存量] 空帧入队会让 `read` 在未 `close` 时返回 0，调用方按 EOF 提前终止 SSE 响应

- **位置**：`f_jsonrpc/src/server/SseStream.cj:92-105`（`92` 行判断 `offset >= current.size`、`94` 行 `current = frame`、`97` 行 `offset = 0`、`100-104` 行拷贝循环）；入队侧 `SseStream.cj:54-69` 不校验空串
- **来源**：存量（快照模式无基线；blame `00d2a8f6d`）
- **判据**：review-checklist §11「契约与实现不符」、§10 正确性（边界/空值）；契约源为 `SseStream.cj:26`「`read` 返回 **0** 表示结束，且只有 `close()` 之后才会返回 0」
- **证据**：静态确定 —— `push('')` 把空串加入 `frames`（`push` 无长度校验）；`read` 取到该帧后 `current = ''`、`offset = 0`，`while (written < buffer.size && offset < current.size)` 一次都不执行，直接返回 `written == 0`。仓颉 `InputStream.read` 文档只约定「返回读取的字节数」（`cangjie_runtime/stdlib/doc/libs/std/io/io_package_api/io_package_interfaces.md:13-27`），0 当 EOF 是本类的自述契约；`f_mvc/src/ResponseDownload.cj:73` 的 `while (let bytes <- input.read(buf) && bytes > 0)` 与 `f_mvc/src/RequestMeta.cj:396-404` 的 chunked 流式响应都按「0 = 结束」消费，`Sse_test.cj:32-34` 的 `drain` 同样把 `<= 0` 当结束
- **描述**：任何空帧都会让 `read` 返回 0，HTTP 层随即认为响应体结束并收尾，长连接被静默关闭，而 `closed` 仍是 `false`（后续写入全部丢失）。同一契约在 `SseStream.cj:89-91`（`buffer.size == 0` 直接返回 0）也有一处例外——这是 std 的普遍约定，本身无害，但说明 `:26` 那句「只有 close 之后」并不成立，读代码的调用方容易把 0 一律当 EOF。当前仓内唯一生产者 `SseHub.frameOf`（`SseHub.cj:151-160`）总是拼出非空帧，所以尚未触发，属公开 API 上的潜伏缺陷
- **建议**：`read` 里对空帧继续取下一帧（`while` 取帧直到 `current` 非空或 `nextFrame()` 返回 `None`），或在 `push` 处拒绝空串并返回 `false`；同时把 `:26` 的契约改成「仅当 `close()` 且队列排空后返回 0；空 buffer 返回 0」

### [一般][存量] `heartbeat` 构造参数未校验，非正值会让 `wait` 在 `read` 路径抛 `IllegalArgumentException`

- **位置**：`f_jsonrpc/src/server/SseStream.cj:41-51`（构造只夹取 `capacity`，`heartbeat` 原样保存）、`SseStream.cj:115`（`available.wait(timeout: heartbeat)`）
- **来源**：存量（blame `00d2a8f6d`）
- **判据**：review-checklist §11「缺少边界校验 / 契约与实现不符」；`Condition.wait(timeout!: Duration)` 文档明确「如果 `timeout` 小于等于 `Duration.Zero`，抛出 `IllegalArgumentException`」（`cangjie_runtime/stdlib/doc/libs/std/sync/sync_package_api/sync_package_interfaces.md:61-84`，第 83 行）
- **证据**：静态确定 —— `init(capacity!: Int64 = 256, heartbeat!: Duration = Duration.second * 15)` 对 `capacity <= 0` 有回落（`:42-46`），对 `heartbeat` 没有任何归一化；`heartbeat = Duration.Zero` 或负值时，第一次空队列 `read` 进到 `nextFrame` 的 `wait` 就抛异常
- **描述**：异常从 `read` 直接穿透到调用方（`InputStream.read` 无返回值表示失败），SSE 请求线程在进入流式响应后崩溃，且该连接既不 `close` 也不返回数据。`heartbeat` 是 public 构造命名参数（`SseStream` 为 public 类），外部可任意传值；类注释与 `init` 都没有写参数约束。`capacity` 的静默夹取同样没有文档说明（传 0 得到容量 1，行为是「每帧都丢前帧」而不是「不限」）
- **建议**：构造时与 `capacity` 一样归一化 `heartbeat`（`<= Duration.Zero` 时回落到 15s），或对非正值抛带说明的 `IllegalArgumentException`；在 `init` 上补参数文档，写清 `capacity` 的下界与丢弃策略

### [一般][存量] `close()` 与「帧消费完」都不释放缓冲，已关闭/已读完的流仍持有最多 `capacity` 帧

- **位置**：`f_jsonrpc/src/server/SseStream.cj:145-150`（`close` 只置 `closed` + `notifyAll`）、`SseStream.cj:100-106`（`current` 消费完后不复位）
- **来源**：存量（blame `00d2a8f6d`）
- **判据**：review-checklist §7「缩短生命周期」、§11「资源释放不对称」、§12.1「跨线程资源」
- **证据**：静态确定 —— `close()` 之后 `frames`、`head`、`current` 原样保留；每条流最多保留 `capacity`（默认 256）个帧字符串，外加 `current` 里最后一帧的完整副本。持有路径：`SseHub.subscribers`（`SseHub.cj:51`）→ `ArrayList<SseSubscription>` → `SseSubscription.stream`（`SseHub.cj:27`）→ `SseStream.frames`；而 `SseSubscription.close()`（`SseHub.cj:36-38`）只转调 `stream.close()`，`SseHub` 没有任何退订/移除路径（`subscribers` 只在 `subscribe` 里 `add`、`reset` 里 `clear`），所以「关闭的流」仍被全局表长期强引用
- **描述**：单条流的滞留量 = 最多 256 帧 + 1 帧，乘以全局订阅表里积累的连接数。`close()` 是唯一显式的资源释放 API，却不释放任何数据；`read` 消费完一帧后 `current` 也一直指向它，直到下一帧到达。这条本身是「关闭后不回收」，真正的放大器是 `SseHub` 无退订（见「范围外提示」），因此未按严重计
- **建议**：`close()` 内在锁里 `frames.clear()`、`head = 0`、`current = ''`；`read` 在 `offset` 追平 `current.size` 时把 `current` 置空；跨文件补齐 `SseHub.unsubscribe(id)` 并在响应结束时调用

### [轻微][存量] 「丢帧只 warn 一次」只实现了一半：只置标志，没有任何告警调用

- **位置**：`f_jsonrpc/src/server/SseStream.cj:53-78`（`push` 置 `dropReported`、`dropped` getter）；消费侧 `SseHub.cj:112`（`let _ = item.stream.push(text)` 丢弃返回值）；`Sse_test.cj:72` 只断言标志
- **来源**：存量（blame `00d2a8f6d`）
- **判据**：review-checklist §14「承诺了但没实现」（承诺源：`f_jsonrpc/doc/spec/add-jsonrpc-sse/design.md:58`「溢出时 `removeFirst()` 再 `addLast()`，并置 `dropped = true`（**只 warn 一次**，避免刷屏）」）
- **证据**：静态确定 —— 全仓 `.dropped` 只有 `Sse_test.cj:72` 一处读取（`grep -rn "\.dropped"`），生产代码零引用；`SseHub.publish` 用 `let _` 吞掉 `push` 的返回值，模块内也没有任何 `f_log` 调用与之关联
- **描述**：慢消费者丢事件时，服务端既不记日志也不计数，`dropped` 一旦置位永不复位。design.md 承诺的「warn 一次」完全缺失，线上只能看到事件消失，无法判断是网络抖动还是本地丢弃
- **建议**：在 `SseHub.publish` 检查 `push` 返回值并 `f_log` 各订阅一次 warn（带 `subscription.id` / `topic` / 丢弃计数），或给 `SseStream` 增加 `dropCount: Int64` 由 hub 汇总；`dropped` 的注释同步改成「是否曾经丢过帧」

### [轻微][存量] `push` 在已关闭时返回 `true`，调用方无法区分「已投递 / 已丢弃 / 已关闭」

- **位置**：`f_jsonrpc/src/server/SseStream.cj:55-58`（`if (closed) { return true }`）、`SseStream.cj:66-67`（`return pendingCount < capacity`）
- **来源**：存量（blame `00d2a8f6d`）
- **判据**：review-checklist §11「语义与命名不符」、§10 可维护性
- **证据**：静态确定 —— 关闭后帧被直接丢弃，却返回「本次未发生丢弃」的 `true`；真正的丢弃返回 `false`
- **描述**：返回值的语义是「没有丢帧」，而关闭分支既没入队也没丢帧计数，`false` 与 `true` 都无法表达「流已结束」。`SseHub` 现在忽略返回值所以无害，但任何按布尔值做投递统计/重试的调用方都会得到错误结论
- **建议**：文档明确「`closed` 后返回 `true` 表示不再投递」并改名（如 `tryPush`），或改成三态（枚举/`Result`）；至少在注释里写清

### [轻微][存量] SSE 过滤/补发用例只做正向断言，过滤与广播同时失效也能通过

- **位置**：`f_jsonrpc/src/server/Sse_test.cj:99-110`（topic 隔离）、`Sse_test.cj:114-124`（taskId 过滤）、`Sse_test.cj:128-139`（Last-Event-ID 补发）
- **来源**：存量（blame `00d2a8f6d`）
- **判据**：review-checklist §14「示例/用例覆盖不足」、§11「测试未覆盖承诺行为」
- **证据**：静态确定 —— `testTopicIsolation` 只在 `b` 上 publish，随后断言 `subscriberCount('a') == 1`，**从未读取 `a` 的流**，注释「a 收不到 b 的事件：读会走到心跳」与实际代码不符；`testTaskIdFilter` 只断言第一帧含 `one`，不检查第二帧是否混入 `two`；`testReplayAfterLastEventId` 只断言含 `three`，不检查 `one`/`two` 是否被重复补发。把 `SseHub.matches` 改成恒 `true`、或把 `publish` 改成向所有 topic 广播，这三条用例仍会全绿
- **描述**：`Sse_test.cj` 的 8 条用例覆盖了「写入能读回 / 心跳 / 丢弃 / 补发能到」，但过滤的反向行为没有任何断言；而 topic/taskId 过滤正是该接口对外的核心承诺（`SseHub.cj:57/86-93`、README 的 A2A 用例）。另外 `drain`（`Sse_test.cj:29-36`）用 `String.fromUtf8(buffer[0..count])` 解码被截断的字节，帧大于缓冲（如含中文的 100+ 字节帧）时会抛 UTF-8 解码异常，只是当前用例的帧都小于缓冲才没暴露
- **建议**：隔离用例读一次 `a` 并断言只得到 `: ping`；过滤用例再读一帧并断言不含 `two`；补发用例断言不含 `one`/`two`；`drain` 改为累积字节后一次性解码（或只用 ASCII 断言）

### [轻微][存量] `Sse_test.cj` 的 `import std.collection.*` 未使用

- **位置**：`f_jsonrpc/src/server/Sse_test.cj:18`
- **来源**：存量（blame `00d2a8f6d`）
- **判据**：review-checklist §1「未使用的 `import`」
- **证据**：静态确定 —— 文件内只使用 `Array`/`String`/`Duration`/`JsonString`/`SseHub`，`grep -nE "ArrayList|HashMap|HashSet|ArrayDeque|LinkedList|TreeMap"` 零命中
- **描述**：多余导入增加编译依赖面（`std.collection` 整体导入），也让读者误以为用例用了集合类型
- **建议**：删除该行；`std.time`（`Duration`）、`std.unittest*`、`f_data` 保留

## 优化可行性方案

> 以下均无改前基线，按规则只能作为「待验证」方案，不进修复清单。

### [CPU] `read` 逐字节索引复制，大帧回放时每次读都要做 N 次边界检查

- **现状**：`SseStream.cj:100-104` 对每字节执行 `buffer[written] = current[offset]`（`String` 下标 + `Array` 写入各带一次边界检查）。`f_mvc` 的流式写出按 `MVCConfig.downloadBufferSize` 分块读（`f_mvc/src/ResponseDownload.cj:71-75`），单次 `read` 最多拷 `buffer.size` 字节；A2A 状态事件的帧通常 100B–1KB，若推送大 payload（如工具结果）可到数十 KB
- **方案**：帧改存 `Array<Byte>`（`SseHub.frameOf` 生成 `toString().unsafeBytes()` 或编码一次），`read` 用 `Array.copyTo(dst, srcStart, dstStart, copyLen)`（`cangjie_runtime/stdlib/doc/libs/std/core/core_package_api/core_package_structs.md:472-475`）一次拷完剩余片段，`currentOffset` 之外不再逐字节循环
- **预期**：把每次 read 的 N 次索引/边界检查降为 1 次批量拷贝；收益随帧大小线性增长（待测）
- **代价**：`frames` 元素类型从 `String` 变 `Array<Byte>`，`SseHub`/测试的 `push` 调用点与断言需同步；`ping` 常量也要转字节
- **验证**：`cjpm bench -O2`，1KB / 100KB 两档帧各 10k 次 read，取中位数与 P95，与当前实现同机对照；`cjprof record` 看 `read` 的 self time 占比
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] `ArrayList + head + compact` 换成 `ArrayDeque`，去掉 2× 峰值与临时副本

- **现状**：`SseStream.cj:33-35` 用 `ArrayList` + `head` 模拟出队，`compact()`（`:131-143`）在 `head >= 64 && head*2 >= size` 时新建 `kept` 把存活帧全部复制一遍再回填。队列满后每次 `push` 只 `head++`，`frames.size` 继续增长到约 `2 × capacity` 才压缩，因此稳态下 256 容量的流最多持有约 512 个槽位，压缩瞬间还多一份 `kept` 副本（再 +256 引用）
- **方案**：改用 `std.collection.ArrayDeque<String>`（`ArrayDeque.addLast` / `removeFirst` 均存在，见 `cangjie_runtime/stdlib/doc/libs/std/collection/collection_package_api/collection_package_class.md:288-291`、`:427-430`），丢弃 `head`/`compact` 与临时 `kept`；这与设计文档 `doc/spec/add-jsonrpc-sse/design.md:44` 原本写的 `ArrayDeque<Array<Byte>>` 一致
- **预期**：每流稳态槽位从 ~512 降到 ~257，压缩时的临时副本与 O(k) 复制消失；对象数减少与峰值内存下降需实测
- **代价**：`ArrayList` 的按下标访问（`frames[head]`）改成 `removeFirst()`，`push` 的「丢最旧」从 `head++` 改成 `removeFirst()`（返回 `?T` 需处理 `None`）；行为语义不变
- **验证**：1000 条并发流、每流 256 帧稳态负载，`-O2`，对比 `getAllocatedHeapSize()` 峰值 / RSS / 每秒 push 吞吐
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `read` 的逐字节复制是大帧 SSE 回放的主要自耗时 | `SseStream.cj:100-104` | `read` 的 self time 占比、帧大小分布 | `cjprof record` 跑 10k 帧回放（1KB 与 100KB 两档），对照 `copyTo` 版本 |
| 2 | 每流 `mutex` 与 `SseHub` 全局锁串联（publish 持 hub 锁调 `push` 取流锁）限制多订阅者下的 publish 吞吐 | `SseStream.cj:55`、`SseStream.cj:111`；`SseHub.cj:94-116` | 锁等待时长、BLOCKED 线程数、publish P95 | 100/1000 个订阅者并发 publish，分段计时 + 线程状态采样（CPU profile 看不到锁等待） |
| 3 | `compact()` 的 O(k) 重建在「慢消费者 + 持续 publish」下形成周期性 CPU 尖峰 | `SseStream.cj:131-143` | 每次 compact 耗时与触发频率 | 容量 256、publish 速率高于读速率 10 倍，分段计时统计 compact 调用次数与总耗时 |

## 范围外提示

- `SseHub` 没有退订 API：`SseSubscription.close()`（`SseHub.cj:36-38`）只关闭流，`subscribers`（`SseHub.cj:51`）只增不减，每条 SSE 连接结束后仍永久留在全局表里，`publish` 还会继续向已关闭的流 `push`（`SseHub.cj:112`）。这是无界增长（OOM）面的主因，但属 SseHub 文件，不计入本部分统计。
- `README.md:31` 与 `README.md:500`（`README_en.md:32`、`:511` 同）仍把「SSE 传输」列在「不做 / 与规范的差异」里，与已实现的 `SseController` / `SseHub` / `SseStream` / `JsonRpcSseClient` 直接冲突；README 不在本部分文件清单内，留给对应部分。
- `doc/spec/add-jsonrpc-sse/tasks.md:7` 写「`close` 后 `read` 返回 -1」，与 `design.md:46` 及实现（返回 0）相反；属已归档任务清单，按 §13 误报边界不单独计问题。

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_jsonrpc/src/server/SseStream.cj` | .cj | ✅ | 阻塞读 / 心跳 / 有界丢弃实现；3 条一般（空帧 0、heartbeat 校验、关闭不释放）+ 2 条轻微（告警缺失、closed 返回值）；2 条优化方案 |
| 2 | `f_jsonrpc/src/server/Sse_test.cj` | .cj | ✅ | 8 条 `@TestCase`；反向断言缺失、`drain` 截断解码、未使用 import |

合计：`.cj` 2 个 / `.md` 0 个 / 共 2 个，全部读完（与 `files/f_jsonrpc.part4.txt` 一一对应）。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 2 | 正确性 2（空帧导致伪 EOF、heartbeat 未校验）；设计 0（`SseStream` 单责、`SseHub` 分桶合理）；语言特性 0（`Mutex`+`Condition` 用法与官方 `sync.md:622-652` 的 `synchronized` 语义一致，`condition()` 在持锁下创建符合 `sync_package_classes.md:8965-8997`）；可读性 0（命名与注释整体清晰）；安全性 0（无外部输入解析、无凭据、无注入面） |
| §1 死代码 | 1 | 已逐个核对 `private` 符号：`mutex`/`available`/`capacity`/`heartbeat`/`frames`/`head`/`current`/`offset`/`closed`/`dropReported`/`nextFrame`/`compact`/`PING` 全部有引用，`Sse_test.drain` 被 8 处调用；`protected` 声明 0 个；`public`（`SseStream` 为 public 类，成员对外可达）不判死代码，仅记录仓内 `isClosed`/`dropped` 无生产调用；命中：1 个未使用 import |
| §2 重复逻辑 | 0 | 已把本部分 2 个文件内 8 个函数体（`push`/`dropped`/`isClosed`/`read`/`nextFrame`/`compact`/`close` + `drain`）压成「输入-输出-副作用」两两比对，无同语义实现；跨文件搜相同字面量/模板：`String.fromUtf8` 在其它测试里出现但语义不同（整块解码 vs 截断解码），`Int64(frames.size) - head` 只在 `push`/`nextFrame` 各出现一次，属同一不变量的两处读取，不构成可合并重复 |
| §3 空实现 | 0 | 两个文件无空函数体、无 `TODO`/`FIXME`、无 `catch {}`；「丢帧不告警」属「有代码但没接线」，已在 §14 计 1 条 |
| §4 栈溢出 | 0 | `read`/`nextFrame`/`compact`/`push` 均为单层循环或直接转调，无自递归、无间接递归、无递归遍历外部结构 |
| §5 OOM | 0 | 每流队列由 `capacity`（默认 256）+ `current` 封顶，属有界容器；单帧大小由调用方决定但不来自不可信报文，未按报文长度预分配。全局订阅表无界增长在 `SseHub`（范围外提示） |
| §6.1 热点瓶颈 | 0 | 无 `cjprof` / `cjpm bench` 数据；逐字节拷贝、compact 周期、锁串联三项只进「待验证假设」，不作缺陷 |
| §6.2 大粒度锁 | 0 | 临界区只有 `ArrayList` 索引/追加、最多约 512 项的 `compact` 复制与 `notifyAll`，无 I/O、日志、序列化、外部回调；`wait` 会释放锁（`sync_package_interfaces.md:51-59`）。锁是否已成热点缺数据，见假设 #2 |
| §6.3 并发串行 | 0 | 本部分无 `spawn`/`Future`/线程池/批量任务，不存在「形式并发实际串行」 |
| §6.4 低效算法 | 0 | 确认存在两处低效写法：`read` 逐字节拷贝、`compact` 全量重建（均为 O(n) 且无提前退出优化空间），但无耗时占比数据，按规则归入优化方案与假设，不计缺陷 |
| §7 降堆内存方案 | 1 | `close()`/消费完成后不释放 `frames`、`current`（一般，见发现 3）；另 1 条 `ArrayList+head` → `ArrayDeque` 方案（无基线） |
| §8 降 CPU 方案 | 1 | `read` 逐字节复制改批量 `copyTo`（无基线） |
| §9 local mode 可行性 | 0 | `read`/`nextFrame` 不分配对象；`compact` 内的 `kept` 是短生命周期 `ArrayList`，但函数返回后无逃逸、规模 ≤256，收益只能靠峰值内存证明，无数据，不列方案 |
| §11 现有代码的 BUG（存量） | 4 | 发现 1/2/3/5（空帧伪 EOF、heartbeat 未校验、关闭不释放、closed 返回值）全部为存量；边界（空串/空 buffer/非正 Duration）、空值、资源、契约四类已逐函数核对；测试用例缺陷（6）归 §14 |
| §12 并发安全与锁粒度 | 0 | 共享可变状态 `frames`/`head`/`closed`/`dropReported` 全部在 `mutex` 内读写；`current`/`offset` 只由 `read` 读写，符合 `InputStream` 单读线程约定（`f_mvc` 在请求线程内 `copy`），`close()` 可跨线程但只写受锁保护的 `closed`；单锁、无嵌套、`wait` 释放锁，未发现死锁或丢唤醒路径 |
| §13 文档一致性 | 0 | 本部分无 `.md` 文件；与本部分代码相关的文档冲突（README 仍称不做 SSE、tasks.md 写 -1）在「范围外提示」中列出，不计入本部分 |
| §14 功能完备性与 README 覆盖 | 2 | 「丢帧只 warn 一次」未接线（`design.md:58` 承诺，`SseStream.cj:53-78` + `SseHub.cj:112` 无告警）；SSE 过滤/补发用例缺反向断言（`Sse_test.cj:99-139`）。`SseStream` 的 public 成员均在 README「其他公开 API」中列名（`README.md:538`），`close()`/构造参数未展开属 README 部分 |
| 文件覆盖（§13 等） | 2/2 | 与 `files/f_jsonrpc.part4.txt` 一一对应，无缺项 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 3 |
| 轻微 | 4 |
| 优化方案（堆内存 / CPU） | 1 / 1 |

存量缺陷 7 条（一般 3 + 轻微 4），全部只报不修，是否纳入修复待用户决定。

## 总评

`SseStream` 是一个约 150 行的阻塞队列式 `InputStream`，核心设计是对的：单锁 + 条件变量实现阻塞读、`wait` 超时产出 `: ping` 注释帧、队列满丢最旧不阻塞发布方、读写分离的 `head` 游标加定期压缩控制内存，与 `design.md` 的 D3/D4 基本一致。真正的问题集中在契约边界而不是主流程：`read` 用 0 表达 EOF，却在空帧和空 buffer 两个分支提前返回 0（一般）；`heartbeat` 作为 public 参数不校验，非正值会把 `read` 变成抛异常（一般）；`close()` 不释放队列，配合 `SseHub` 无退订把「关闭」变成「仍然占内存」（一般，放大器在范围外）。这四条都不影响当前默认路径（`SseHub.frameOf` 不产空帧、heartbeat 用默认值、`SseHub` 目前也不调 `close`），属于「一旦被外部按 public API 使用就会踩」的潜伏缺陷。

测试侧 8 条用例覆盖了写入读回、心跳、丢弃、补发、过滤的正向路径，但三条过滤类用例都只断言「目标事件到了」，没有断言「非目标事件没到」，把 `matches` 改成恒真也不会失败——这是本部分最值得先补的地方，成本极低。其余两条轻微（丢帧告警未接线、`push` 关闭后返回 `true`）属于可观测性与 API 语义问题，排在契约修复之后。

没有阻塞项：严重 0 条，建议按「一般 3 条 + 测试反向断言」排期；性能与内存方向没有基线数据，只给出 2 条待验证方案与 3 条假设，未做任何「能降 X%」的结论。
