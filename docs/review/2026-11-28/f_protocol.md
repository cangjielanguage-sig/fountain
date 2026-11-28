# f_protocol 模块审查报告

- **审查日期**：2026-11-28
- **模块路径**：`f_protocol`（24 个文件：15 个 .cj + 9 个 .md）
- **基线**：工作区快照（sts/1.3.x 工作区，master 同提交 120fd2542，无分支差异）
- **审查重点**：见 scope.md（正确性、死代码、重复逻辑、空实现、栈溢出、OOM、热点、并发与锁、存量 BUG、内存/CPU 优化空间、local mode 可行性、README 覆盖）
- **报告版本**：v1（由 2 个分部分报告合并：`parts/f_protocol.part1..2.md`）

## 发现

<!-- 第 1 部分 -->

本部分无「严重」级发现，最高为「一般」。帧头/帧尾/截断/CRC 各条边界路径逐条核对后行为正确（见「覆盖自检」§11），问题集中在**编码异常路径的资源归还**、**长度上限的配置边界**与**解码错误契约**三处。

### [一般][存量] `Message.encode()` 在编码抛异常时不归还编解码器池项，累计可让全进程写失败

- **位置**：`f_protocol/src/default/Message.cj:271-276`（`encode()`）；关联 `f_codec/src/default/DefaultCodec.cj:713-726`（`finish()` 移交所有权、`release()` 契约）与 `:124-149`（`lastBuffer()` 借池项）
- **来源**：存量（blame：`Message.cj:271` 为 `4be871f2fd` 2026-10-02，`:273-274` 为 `7f29af9eb3` 2026-11-06）
- **判据**：review-checklist §11（资源不对称：异常跳过释放）
- **证据**：静态确定 —— `encode()` 是 `let bytes = DefaultCodec(headroom: …).encode(...)….finish()` 一条表达式，**没有任何 try/finally**。`DefaultCodec` 的第一个 `encode(...)` 就会经 `lastBuffer()` 从池里借一个 8 KB 缓冲并入 `inputs`；而 `encode(data)` 在多处会抛：不支持类型（`DefaultCodec.cj:223-227`）、浮点 NaN/Inf（`:445-450`、`:435-440`、`:425-431`）、池耗尽（`:128` 的 `getOrThrow()`）。异常穿出 `Message.encode()` 后，`DefaultCodec` 对象连同 `inputs` 一起不可达，`release()` 永远不会被调用；所有权只在 `finish()` 成功后才交给 `EncodedMessage`，失败路径没有第二次机会。
- **描述**：每失败一次永久损失一个池项（默认池 `initSize: 1024`，`doc/perf/frame-encode-4k.md §6` 记录 1024 × 8192 B）。池的借还计数不会因 GC 回收内存而恢复；累计 1024 次后 `lastBuffer()` 等 30 s 仍取不到缓冲，`Message.encode()` 对**所有**消息抛异常，该进程的 RPC / MQ / DB 写全部停摆，只有重启可恢复。触发源可以是把解码得到的 NaN 浮点再编码回去（`decodeData` 对 `Float64.fromBits` 不做 NaN 校验，见 `DefaultCodec.cj:891-895`），也可以是任何业务侧传入不支持类型。现有回归只覆盖了 `copy()` 失败要释放（`Protocol_test.cj:588-611`），没有覆盖 `encode()` 失败。
- **建议**：把 `encode()` 改成显式持有 codec 的写法，失败时归还：`let codec = DefaultCodec(headroom: FRAME_HEAD_SIZE); try { let bytes = codec.encode(...).finish(); EncodedMessage(command.value, bytes) } catch (e) { codec.release(); throw e }`；或给 `DefaultCodec` 的 `finish()` 增加「未调用 finish 的对象在作用域结束时归还」的兜底（`try` 资源语法 / `Releasable` 包装）。补一条用例：让 `Message.encode()` 对 `DataReal(Float64.NaN)` 抛异常，断言池项可再借出（复用 `Protocol_test.cj:540-550` 的 `availOf`）。

### [一般][存量] `framePayloadLimit()` 无同步惰性缓存：全进程解码线程竞态写 `Option<Int64>`

- **位置**：`f_protocol/src/default/Message.cj:35-44`（`private var maxFramePayloadCache` / `framePayloadLimit()`）；每帧调用点 `:295`、`:340`
- **来源**：存量（blame：`89bbfea6ce` 2026-10-03）
- **判据**：review-checklist §12.1（共享可变状态无保护、惰性初始化）；§11（并发正确性）
- **证据**：静态确定 —— 读 `maxFramePayloadCache`、写 `maxFramePayloadCache = Some(n)` 都在裸 `private var` 上，没有 `synchronized` / `Atomic` / `Once`，也没有「先构造完成再发布」的屏障。共享路径明确：`f_net/src/server/server.cj:139-142` 每条连接 `spawn` 一个线程调用 `Message.decode<T>`，而 `decode` 每帧都会走 `framePayloadLimit()`（`:295` 判断、`:296` 再取一次）；`f_net/src/client/client.cj:97`、`ListeningClient.cj:32` 同构。
- **描述**：首个帧并发到达时，两个线程都可能读到 `None`，各自读一次配置并写 `Some(n)`。写入值相同（幂等），所以不会出现「A 的上限 / B 的上限」这种语义错误；但 `Option<Int64>` 是带标签的多字结构，非同步发布在弱内存模型下允许读侧看到撕裂值（标签为 `Some`、载荷为半写），此时 `framePayloadLimit()` 会返回一个任意 Int64 —— 放大到「放行超大帧」或「拒绝全部合法帧」。是否真的能观测到取决于运行时的内存模型实现，故后果记为待确认。
- **建议**：用 `std.sync.Once` 或 `synchronized` 保护首次初始化；更简单的是取消惰性：配置在启动期本就只读一次（`fountain-baseline.md §5`），由 `fboot` / `@Bean` 初始化阶段调用 `ProtocolConfig` 把上限写进 `Message` 的不可变静态字段，运行时只读 `let`。同时把 `:296` 里第二次 `framePayloadLimit()` 调用改成复用已取到的局部值。

### [一般][存量] 解码按对端声明长度分配、默认上限 1 GB，且无帧级超时：单连接即可吃 1 GB 并占住解码线程

- **位置**：`f_protocol/src/default/Message.cj:294-305`（`len` 校验 + 交给 `DefaultCodec`）；分配点 `f_codec/src/default/DefaultCodec.cj:766-777`（`checkedBuffer`）与 `:803`（string）、`:1005`（inputstream payload）
- **来源**：存量（blame：`89bbfea6ce` 2026-10-03）
- **判据**：review-checklist §5（按不可信长度预分配）、§10（安全性：外部输入未约束）
- **证据**：静态确定（分配路径）/ 需实测（是否真的 OOM 取决于并发连接数与堆上限）—— `checkedBuffer` 只校验 `declared <= SizeBoundedInput.remainingBytes`，而 `remainingBytes` 的上限正是 `protocol_maxFramePayload`（默认 `1 << 30`，`ProtocolConfig.cj:31-33`）。因此：帧头声明 `len = 1 GB`（≤ 上限，通过 `:295`）→ 送 ≤ 20 B 合法的 time/pid/tid/hostId + 一个声明 1 GB 的字符串头 → `checkedBuffer` 立即 `Array<Byte>(declared)` 分配 1 GB，随后 `input.read(array)` 阻塞等待剩余字节。`FrameBodyStream.read`（`:114-133`）没有任何 deadline，只能等对端继续发或 EOF。
- **描述**：`f_net` 服务端在鉴权之前就 `Message.decode`（`server.cj:142`），未认证对端每连接可稳定占用约 1 GB 堆 + 1 个解码线程；N 条连接 ≈ N GB。README:49/195 把这条限制描述为「防声称超大长度拖死对端」，但 1 GB 的默认值对 RPC/MQ 报文而言远超实际（`doc/perf` 的基准报文是 4 KB 级），且没有每连接 / 每进程预算，也没有慢速发送的帧级超时。
- **建议**：默认上限下调到业务真实上界（如 16 MB / 64 MB），并在 README 的配置表里写清「超过即断链」；给解码加「帧级读超时」参数（或明确要求调用方在 socket 层设置 `socketReadTimeout`，并写进 `Protocol` 接口注释）；如需保留大帧能力，增加「每连接已分配字节」计数与全局预算，而不是只靠单帧上限。若部署环境无法在网关侧限制帧长，应把本条升为严重。

### [一般][存量] 帧长上限取自配置却未校验范围：> 4 GB 时 `len` 被静默截断，≤ 0 时所有帧被拒

- **位置**：`f_protocol/src/default/Message.cj:340-343`（写侧校验）、`:354`/`:363`/`:384`（`putInt32BE`）；`ProtocolConfig.cj:31-33`（`getMaxFramePayload`）
- **来源**：存量（blame：`Message.cj:340-343` 与 `ProtocolConfig.cj:31-33` 均为 `89bbfea6ce` 2026-10-03）
- **判据**：review-checklist §11（边界差一 / 契约与实现不符）；§13（README:49 只说受配置限制，未写 4 B 硬上限）
- **证据**：静态确定 —— `putInt32BE`（`:57-62`）逐字节写 `(value >> 24) & 0xff` 等，只保留低 32 位；`getMaxFramePayload()` 直接 `Config.getValue<Int64>(...) ?? (1 << 30)`，没有 `1..UInt32.Max` 的夹取。
- **描述**：把 `protocol_maxFramePayload` 配成 8 GB（Int64 允许）后，5 GB 的载荷能通过 `:340` 的校验，但帧头 `len` 写成 5 GB 的低 32 位 = 1 GB；对端按 1 GB 读 payload、再读 4 B 当 CRC，剩余字节被当成下一帧头 —— 静默的字节流错位（表现为 CRC 不符或后续帧解析错乱，而不是「配置无效」）。配成 0 或负数时，所有合法帧在 `:295` / `:340` 被拒，故障点离配置项很远。
- **建议**：`getMaxFramePayload()` 做范围校验并 `throw IllegalArgumentException`（非法配置启动即失败，符合 `fountain-baseline.md §4` 的「启动直接失败」原则），上限取 `UInt32.Max`；README 配置表补「4 B 大端字段，硬上限 4294967295」。

### [一般][存量] 解码错误类型不统一：`IllegalArgumentException`（无消息）替代 README 承诺的 `CodecException`

- **位置**：`f_protocol/src/default/Message.cj:301-304`（`getOrThrow {IllegalArgumentException()}`）；`:319`（对端 `hostId == 0` → `MessageID.cj:29-32` 抛 `IllegalArgumentException`）
- **来源**：存量（blame：`89bbfea6ce` 2026-10-03）
- **判据**：review-checklist §13（README:56-59 / README_en:58-61 的异常语义）；§11（契约与实现不符）
- **证据**：静态确定 —— `DefaultCodec.decode<T>` 返回 `?T`（`Codec.cj:70-72`、`DefaultCodec.cj:1078-1085`），当 `T.tryFromData` 返回 `None` 时 `getOrThrow { IllegalArgumentException() }` 抛的是**无 message** 的 `IllegalArgumentException`。README 只承诺两类：「首字节读不到 ⇒ `InputClosedException`」「版本不符 / 载荷没读尽 / CRC 不符 / 中途 EOF ⇒ `CodecException`」，没有 `IllegalArgumentException` 这一档。同一现象还有第二个入口：对端帧里的 `hostId` 为 0 时，`MessageID` 构造器直接拒绝（这是发送侧的配置错误被搬到接收侧复现）。
- **描述**：构造一个 time 字段被写成字符串的帧（CRC 正确、长度自洽），接收侧抛 `IllegalArgumentException` 且消息为空，日志里既没有字段名也没有帧上下文；按 `catch (e: CodecException)` 分类的调用方会把它当未预期异常。`f_net` 目前 `catch (e: Exception)`（`server.cj:152`）兜住并断链，所以不是可观测故障，但错误分类与可诊断性受损，也让「协议层错误」无法被统一计数。
- **建议**：`decode` 里把四段 id 的解码失败统一包成 `CodecException('invalid frame head: <field>', e)`；`hostId == 0` 在解码分支单独判并抛 `CodecException('peer hostId must not be 0')`，不要把发送侧约束泄漏成 `IllegalArgumentException`。README 的异常清单同步补上「帧头字段类型不符 ⇒ `CodecException`」。

### [一般][存量] `decode<T>` 在载荷类型不符时静默降级为 `DataNone`

- **位置**：`f_protocol/src/default/Message.cj:305`（`let data = decoder.decode<T>(body)`）与 `:319`（`build` → `:175-183` 把 `None` 映射成 `DataNone.INSTANCE`）
- **来源**：存量（blame：`4be871f2fd` 2026-10-02）
- **判据**：review-checklist §11（错误处理静默 / `Option` 被丢弃）；§10 正确性
- **证据**：静态确定（机制）—— `DefaultCodec.decode<T>` 的失败形态是返回 `None<T>`，不是抛异常；`Message.decode` 对 `data` 不做判空就直接 `build<T>(command, id, data)`，而 `toData<T>(None)` 返回 `DataNone.INSTANCE`。此时帧体已被完整消费、`body.remaining == 0`（`:306`），CRC 也会通过，因此没有任何异常路径暴露这次丢弃。
- **描述**：调用方按具体类型解码（`T` 不是 `DataAny`）而帧内载荷是另一种类型时，得到一条「命令与 id 正确、载荷为空」的消息，而不是错误。仓内调用方全部用 `DataAny`（`f_net/src/client/client.cj:97`、`server.cj:142`、`ListeningClient.cj:32`、`f_mq/src/base/MQProtocol_test.cj:33`），`DataAny.tryFromData` 恒成功，所以仓内不会触发；影响面是下游按 `FromToData` 具体类型解码的使用者。
- **建议**：`decode` 中对 `data` 判 `None` 时抛 `CodecException('payload cannot be converted to <T>')`，或让 `build` 区分「无载荷（`DataNone`）」与「解码失败（`None`）」两个语义（例如新增私有 `buildOrThrow`）。README 里把 `T` 的失败语义写清（目前只写「按 `T` 转换载荷」）。

### [一般][存量] `Message.tryFromData` 契约与实现不符：转不了返回 `None`，不抛 `DataException`

- **位置**：`f_protocol/src/default/Message.cj:151-157`；对照 `f_data/src/base/DataFields.cj:37-43`（同类 API 用 `?? throw DataException`）
- **来源**：存量（blame：`4be871f2fd` 2026-10-02）
- **判据**：review-checklist §13（README:140 / README_en:142「转不了抛 `DataException`」）；§11（契约与实现不符）
- **证据**：静态确定 —— `T.tryFromData(data)` 返回 `Any`，实现里 `case x: ?T => x` 直接返回，`None` 会原样返回；只有「返回了既不是 `T` 也不是 `?T` 的值」才走到 `:155` 的 `throw DataException`。而 `f_data` 的 `DataFields.fromData` 在同一位置写的是 `x ?? throw DataException(...)`，说明项目内约定是「`fromData` 抛、`tryFromData` 返 None」——`Message.tryFromData` 的名字与返回类型 `?T` 暗示 `try` 语义，但注释与 README 承诺的是 `fromData` 语义。调用方 `f_rpc/src/server/RPCServer.cj:105` 用 `.getOrThrow()`，实际抛的是无上下文的 `NoneValueException`。
- **建议**：二选一并对齐文档：要么 `case x: ?T => x ?? throw DataException('data ${data} cannot be converted to ${TypeInfo.of<T>()}')`，要么把 KDoc 与 README 改成「返回 `None` 表示无法转换」，并同步改 `RPCServer.cj` 的错误处理。

### [一般][存量] README「其他公开 API」清单失真：列了不存在的模块级 `read`/`write`，漏了 `ProtocolConfig`/`ProcessID`

- **位置**：`f_protocol/README.md:216`、`README_en.md:220`；代码侧 `Message.cj:94`（`Crc32OutputStream.write`）、`Message.cj:114`（`FrameBodyStream.read`）、`ProtocolConfig.cj:20-33`、`ProcessID.cj:18-20`
- **来源**：存量（README 为 `4be871f2fd` 起的文档，`read/write` 条目在快照内）
- **判据**：review-checklist §14.2（公开 API 未文档化 / README 覆盖）、§13（文档与代码不符）
- **证据**：静态确定 —— 全仓搜 `func read(buffer: Array<Byte>)` 与 `func write(bytes: Array<Byte>)`，`f_protocol` 内只命中 `private class Crc32OutputStream` 与 `private class FrameBodyStream` 的成员（以及测试 stub），**模块级不存在任何同名 `public func`**；相反，`ProtocolConfig`（`protocol` / `protocol_hostId` / `protocol_maxFramePayload` 三个公开常量 + 两个 getter，是配置的唯一编程入口）与 `ProcessID` 接口在整个 README 中检索不到。
- **描述**：README:208 声明「本 README 与 `src/**` 是唯一出处」，但「其他公开 API」章节把两个私有类的成员当成模块级公开函数（下游按图索骥会找不到），同时漏掉真正需要被调用的 `ProtocolConfig`（`f_mq/src/client/MQClient.cj:82` 就在用它）与 `ProcessID`。配置键本身有表格（README:197-204），所以不算「关键配置完全无文档」，但类名与调用方式缺失。
- **建议**：删掉两条错误的 `read`/`write` 条目（或改为「`FrameBodyStream.read` / `Crc32OutputStream.write`，均为私有实现细节」）；补 `ProtocolConfig`（键常量 + 两个 getter 的语义与返回值）与 `ProcessID`/`CurrentProcessID`；中英两版同步。

### [轻微][存量] `Command.parse` 的 `case _ => throw` 不可达

- **位置**：`f_protocol/src/default/constants.cj:200-223`（不可达分支 `:221`）
- **来源**：存量（blame：`4be871f2fd` 2026-10-02）
- **判据**：review-checklist §1（恒假分支）
- **证据**：静态确定 —— `value` 是 `Byte`，`value >> 4` 的取值域恰为 0..15，而 `:204-220` 已把 0..15 全部枚举；测试自身也写明「这 16 个编号都被 Command 占满 → parse 永不抛」（`Protocol_test.cj:58-59`）。
- **描述**：`case _` 是死分支，且会让人误以为 4 bit 命令号还有保留值（README:127「未知命令号抛 `CommandException`」同样不成立）。
- **建议**：改成 `case _ => throw UnreachableException()` 并加一行注释说明「高 4 位只有 16 种、已全覆盖」；README 的命令表删掉「未知命令号抛 `CommandException`」，改为「4 bit 命令号已被 16 个命令占满」。

### [轻微][存量] 同一张标志位表复制三份，`constants.cj` 的 PING 行与实现/README 相反

- **位置**：`f_protocol/src/default/constants.cj:29`（`PING | WITHNODE`）vs `Message.cj:169`（`PING | 0`）vs `README.md:92` / `README_en.md:94`（「`ping()` 固定发 `PING(1)`，不置 bit3」）
- **来源**：存量（blame：`constants.cj:29` 为 `4be871f2fd` 的注释块）
- **判据**：review-checklist §2（字面量复制导致的行为漂移）、§13
- **证据**：静态确定 —— `Command.value` 的 PING 分支（`constants.cj:149`）是 `(12 << 4) | tag(x) | 1`，bit3 只来自构造参数，`Message.ping()`（`Message.cj:247-249`）传的是 `PING(1)`，所以 bit3 恒 0；`constants.cj` 的注释表却写 `WITHNODE`。
- **描述**：三份表分别是 README（对）、`Message.cj` 注释（对）、`constants.cj` 注释（错）。改协议位时三处必须同步，已出现一次漂移；按 `constants.cj` 读代码会以为 `ping()` 带 node 信息。
- **建议**：只在 README 保留完整表，两处源码注释改成「见 README 标志位表」；修正 `constants.cj:29` 为 `0`。`WITHNODE` 常量保留但注明「当前无发送方置位」。

### [轻微][存量] `asOneSmallFrame()` 两个分支重复同一套帧装配

- **位置**：`f_protocol/src/default/Message.cj:348-370`（`frameBytes` 命中分支 `:351-357`、`asBytes` 回退分支 `:359-367`）
- **来源**：存量（blame：`7f29af9eb3` 2026-11-06）
- **判据**：review-checklist §2（同语义、换缓冲来源）
- **证据**：静态确定 —— 两支都做「写 version / 写 cmd / `putInt32BE(len)` / `crc32(头部+payload)` / `putInt32BE(crc)`」四步，只有缓冲区来自「池内整帧视图」还是「新分配 `Array<Byte>`」不同。回退分支还隐含一个未校验的假设：`payload.size` 必须等于 `n`，否则 `out` 尾部留 0 且 CRC 覆盖这些 0，对端会读到一条「长度对、内容多了 0」的帧。
- **建议**：抽 `private func fillFrame(frame: Array<Byte>, command: Byte, n: Int64)`（写头 + 算 CRC 写尾），两支共用；回退分支加 `if (payload.size != n) { throw CodecException(...) }`，把 `BytesCopyTo.byteSize`/`asBytes` 的一致性变成显式契约。

### [轻微][存量] `Message.auth(hasData: false)` 静默丢弃 `authData`

- **位置**：`f_protocol/src/default/Message.cj:193-199`
- **来源**：存量（blame：`4be871f2fd` 2026-10-02）
- **判据**：review-checklist §10（正确性：输入被静默丢弃）、§11
- **证据**：静态确定 —— `hasData == false` 时直接 `build(AUTH(to(ack, ACK)))`（走无载荷重载），`authData` 完全未参与；而参数是必填的 `authData!: T`，调用方很难意识到传了也不会发。
- **描述**：`HASDATA` 位与载荷是否存在是两个独立输入，实现不校验一致性。误用（`hasData: false` 却传了凭据）会在线上表现为「认证请求没有数据」，对端只能报参数错误。
- **建议**：`authData` 改成 `?T`，`hasData` 为 `true` 时要求 `Some`、为 `false` 时要求 `None`，不一致抛 `IllegalArgumentException`；或至少加 `Debug` 级日志。

### [轻微][存量] `QoS.parse` 保留整段注释实现，且「非法位」用例从不传非法位

- **位置**：`f_protocol/src/default/constants.cj:72-77`（注释掉的 `match` 版本）；`Protocol_test.cj:335-348`（`qosParseWithInvalidBits`）
- **来源**：存量（blame：`4be871f2fd` 2026-10-02）
- **判据**：review-checklist §1（兼容残留 / 注释死代码）、§14（用例覆盖）
- **证据**：静态确定 —— `:72-77` 是被注释的等价实现；用例名与注释说「`QoS.parse(6u8)`：bits 1-2 both set → 6」，但函数体只调 `QoS.parse` 的 0/2/4 三个合法值，`else` 分支（`:69-71` 抛 `CommandException`）没有任何用例，注释里「编译器将 case _ 优化为 unreachable」的说法也与当前 `if/else` 实现不符。
- **建议**：删除注释代码；用例补 `@ExpectThrows(CommandException, { => QoS.parse(6u8) })`（或现有框架的等价写法），并改掉失真的注释。

### [轻微][存量] `Command.PING(0)` 与 `PING(1)` 线上字节相同但 `==` 不等，往返不幂等

- **位置**：`f_protocol/src/default/constants.cj:149`（`value` 强制 `| 1`）、`:159-179`（`operator==` 比较原始 `x`）、`:200-223`（`parse` 回读低 4 位）
- **来源**：存量（blame：`4be871f2fd` 2026-10-02）
- **判据**：review-checklist §11（语义与身份不一致 / 契约不符）
- **证据**：静态确定 —— `Command.PING(0).value == Command.PING(1).value == 0xC1`，但 `operator==` 对 `PING(x)/PING(y)` 比较 `x == y`，故二者 `!=`；同时 `Command.parse(Command.PING(0).value)` 返回 `PING(1)`，即 `parse` 后与原值不相等。`hashCode()` 都按 `value`，出现「hash 相同、值不等、线上字节相同」的三重不一致。
- **建议**：`==` 与 `hashCode` 统一按 `value` 判定（`this.value == other.value`），或在构造 `PING(x)` 时把 bit0 归一化（`x | 1`），使身份 = 线上字节。

### [轻微][存量] `slaveof(masterSocket:)` 强制转换失败时抛无消息的 `NoneValueException`

- **位置**：`f_protocol/src/default/Message.cj:212-214`
- **来源**：存量（blame：`4be871f2fd` 2026-10-02）
- **判据**：review-checklist §11（空值 / 边界未处理）
- **证据**：静态确定 —— `(masterSocket.remoteAddress as IPSocketAddress).getOrThrow()`：`remoteAddress` 是 `SocketAddress`，对 Unix domain 或未连接的 socket 不是 `IPSocketAddress`，`as` 得到 `None` 后 `getOrThrow()` 抛无上下文的 `NoneValueException`。
- **建议**：`match` 显式判断类型，抛带 `masterSocket.remoteAddress` 文本的 `IllegalArgumentException`；或改用接受 `SocketAddress` 的重载，避免断言式转换。

### [轻微][存量] README 称「配置首次使用后缓存」，实际只有 `maxFramePayload` 缓存，`hostId` 每次构造都读配置

- **位置**：`f_protocol/README.md:204` / `README_en.md:208`；代码 `MessageID.cj:25`（默认参数 `ProtocolConfig.getProtocolHostId()`）+ `ProtocolConfig.cj:24-26`（`Config.getValue<Int64>`，每次做字符串键查表 + `Int64` 解析）
- **来源**：存量（blame：`89bbfea6ce` 2026-10-03）
- **判据**：review-checklist §13（文档与实现不符）
- **证据**：静态确定 —— 只有 `Message.cj:35-44` 的 `framePayloadLimit()` 做了缓存；`hostId` 在每次 `MessageID()` 构造时重新读（`Message.cj:143`、`:182` 等所有工厂方法都会走到）。
- **描述**：文档描述会让人以为构造 `MessageID` 无配置查找成本；实际上每条工厂消息都会查一次配置表并解析整数字符串（`f_mq/src/client/MQClient.cj:82` 里甚至显式再读一次）。配置不可热更新（`fountain-baseline.md §5`），所以这个重复读取只有成本没有收益。
- **建议**：文档改为「`maxFramePayload` 首次使用后缓存；`hostId` 每次读取」；或把 `hostId` 也做成一次性缓存（启动后不变），同时删掉 `MQClient.cj:82` 的重复读取。

### [轻微][存量] 两个用例依赖 `DateTime.now()` 的纳秒分辨率，粗化时钟下会假失败

- **位置**：`f_protocol/src/default/Protocol_test.cj:118-123`（`messageIDUniqueness`）、`Message_unsubscribe_test.cj:52-60`（`unsubscribeWithDataTwiceYieldsDifferentIds`）
- **来源**：存量（blame：`4be871f2fd` 2026-10-02 / 本次快照内）
- **判据**：review-checklist §11（测试稳定性）
- **证据**：待确认 —— 两个用例都靠连续两次 `MessageID()` 的 `time` 不同来断言 id 不同；`MessageID` 的相等与 hash 都以 `toUnixTimeStamp().toNanoseconds()` 为准（`MessageID.cj:34-35`、`:45`）。在时钟被粗化（部分容器 / 虚拟化环境）或调用恰好落在同一 tick 时，二者相等，用例失败。CI 目前通过，说明当前环境分辨率足够。
- **建议**：用例显式给不同的 `time`/`tid`（或改成「同一时刻 + 不同 pid」断言不等），把「自动生成 id 唯一」交给一条不依赖时钟的实现约束（例如进程内单调计数器），避免测试与运行时时钟耦合。

<!-- 第 2 部分 -->

本部分只有两类文件：**帧截断/长度边界的回归测试**（`truncated_message_test.cj`，20 个 `@TestCase`）与**两个异常类型 + 一个 import 汇总文件**。异常类型本身没有任何逻辑（4 个构造器全部直转 `f_base.BaseException`，与 `f_exception` 模块公开的模板逐字一致），未发现缺陷；问题全部落在测试文件上：**最核心的一条是「只断言抛了异常」无法区分协议错误与干净关闭**，其余三条是测试基建的隐式上限、池项未归还与不可达分支。

### [一般][存量] 截断/版本用例只断言「抛了任意异常」，无法区分 `CodecException` 与 `InputClosedException`，文件头承诺的「中途 EOF 不是干净关闭」没有被任何用例锁定

- **位置**：`f_protocol/src/default/truncated_message_test.cj:83-93`（`decodeThrows`，`catch (_: Exception) { true }` 在 `:90`）；被 `:170`、`:195`、`:203-204`、`:213`、`:220`、`:227`、`:234`、`:243`、`:257`、`:265`、`:273`、`:281`、`:304` 使用
- **来源**：存量（blame：文件由 `fb69eede1` 2026-10-03「半条消息必须在接收侧被识别为"不完整"」新增，`decodeThrows` 自引入起未改；快照无基线）
- **判据**：review-checklist §11（契约与实现不符 / 边界校验缺失）、§14（用例覆盖不足）；承诺源为同文件 `:26-30` 与 `:194`
- **证据**：静态确定 —— `Message.decode` 用**两种不同异常**表达两种语义：首字节读不到 → `InputClosedException`（`Message.cj:287-289`），帧中途 EOF / CRC 缺失 / 长度不符 → `CodecException`（`Message.cj:78`、`:123`、`:308`、`:312`、`:317`）。文件头 `:28-30` 明确要求「帧中途 EOF、`len` 与实际不符、CRC 不符 ⇒ 必须抛，绝不返回半条」，`:194` 的注释还专门写了「且不能是"干净关闭"」。但 `decodeThrows` 把 `Exception` 全吞了，只返回 `true`/`false`，不区分类型、也不看 `message`。
- **描述**：11 个「必须抛」用例（`:195`、`:203-204`、`:213`、`:220`、`:227`、`:234`、`:243`、`:257`、`:265`、`:273`、`:281`）没有一条会因为异常类型变了而失败。`Message.decode` 的「零字节输入」异常类型本身就变过一次（`c51cf61bc` 把 `IllegalArgumentException` 改成 `InputClosedException`，`Message.cj:288`）——这两种类型都能通过 `decodeThrows` 的判定；同理，若把 `readFully` 的「读了一半再 EOF」也归成干净关闭，`truncatedHeaderMustThrow`/`partiallyReceivedHeaderMustThrow` 会抛 `InputClosedException` 而不是 `CodecException`，用例照样通过。`unknownFrameVersionMustThrow` 的注释写明「不能是'干净关闭'」，但断言对此毫无约束。而 `f_net` 对这两类异常的处理是**分开的**：`InputClosedException` 记 DEBUG、当作正常收尾并 `break`（`f_net/src/server/server.cj:143-151`，注释即「对端干净关闭」），其余异常才 `log.warn('error occurred on decoding', e)` 并断链（`:152-158`）。所以分类一旦漂移，协议错误会被静默降级成「对端正常关闭」——没有 WARN、没有错误计数。反向同理：任意无关异常（如 `IllegalArgumentException`、池耗尽）也会让这些「必须抛」的用例变绿，把真正的失败原因藏起来。同模块的 `Protocol_test.cj:486-496`（`messageDecodeEmptyStreamThrows`）已经示范了正确写法：只捕获 `InputClosedException`，其他异常直接冒出去让用例失败。
- **建议**：把 helper 改成断言异常类型并保留原始失败：`private func decodeThrowsCodec(all, keep): Bool` 内 `catch (e: CodecException) { true } catch (_: Exception) { false }`；「版本不符」再单独断言 `e.message` 含 `unsupported frame version`；`completeMessageStillDecodes`/`frameSurvivesDribbledReads` 保持「不抛」的断言。若想保留「任意异常都算截断」的宽口径，至少另加一条用例锁定「半头/半体 ⇒ 必须是 `CodecException`，不是 `InputClosedException`」。

### [轻微][存量] 两处 `match` 的 `case _ => []` 不可达

- **位置**：`f_protocol/src/default/truncated_message_test.cj:139-143`（死分支在 `:142`）、`:156-160`（死分支在 `:159`）
- **来源**：存量（blame：`fb69eede1` 2026-10-03）
- **判据**：review-checklist §1（`match` 里被前面 case 完全覆盖的 case）
- **证据**：静态确定 —— 待匹配值来自 `decoded.tryFromData<Array<String>>()`，静态类型是 `?Array<String>`（`Message.cj:151` 的返回类型 `?T`）。`Option` 只有 `Some`/`None` 两个构造器（仓颉文档 `enum_and_pattern_match/option_type.md` 开头定义），而前两个类型模式 `Array<String>` 与 `?Array<String>` 已覆盖全部取值：`Some` 由第一个或第二个接住，`None` 由第二个（`?Array<String>` 是 `Option<Array<String>>` 自身）接住，第三个分支没有值可落。
- **描述**：这是死分支，且会误导读者以为「转换失败会静默返回空数组」——实际上转换失败时 `x ?? []` 走的是第二分支，第三分支永不可达；`[]` 兜底一旦被误读成「容错」，后续新增断言会以为失败路径已被覆盖。
- **建议**：删除 `case _`；更直接的写法是 `let got = decoded.tryFromData<Array<String>>() ?? []`，或用 `match (opt) { case Some(x) => x; case None => [] }` 显式表达 `Option` 的两个构造器。

### [轻微][存量] `dataFieldSize` 编码后未 `release()`，每次调用永久丢一个 8 KB 池项（与第 1 部分一般 #1 同一类错误）

- **位置**：`f_protocol/src/default/truncated_message_test.cj:99-101`（`DefaultCodec().encode(data).finish().byteSize() ?? -1`）
- **来源**：存量（blame：`fb69eede1` 2026-10-03）
- **判据**：review-checklist §11（资源释放不对称）、§10（契约与实现不符）
- **证据**：静态确定 —— `DefaultCodec.encode(data)` 在第一次编码时就经 `lastBuffer()` 从池借一个 8 KB 缓冲并加入 `inputs`（`f_codec/src/default/DefaultCodec.cj:124-149`，`:139` 的 `inputs.add(buf)`）；`finish()` 只是把 `inputs` 包成 `ChainedBytesCopyTo`（`:713-715`），**不归还**；唯一归还路径是 `release()`（`:720-726`），其 KDoc 写明「调用方若只做 decode，或不打算把编码结果写出，也必须调用本方法」。`f_pool/src/BytesListOutputStream.cj:211-219` 的 `release()` 是显式且幂等的，全文件没有析构函数兜底（`~init` 只在 `f_pool/src/Ref.cj:24` 出现）。`byteSize()` 只读长度，之后对象被丢弃，池项再也回不去。
- **描述**：本文件共 3 次调用（`eofAtDataFieldMustThrow` 1 次 + `frameWithDataField` 在 `splicedDataFieldStillDecodes`/`oversizedValueLengthIsRejectedBeforeAllocating` 中各 1 次），泄漏 3 × 8 KB，测试进程内可忽略；但这是「量一下编码长度」这种最自然的用法踩中的坑，与第 1 部分一般 #1（`Message.encode()` 异常路径不归还）同源，说明 `DefaultCodec` 的所有权契约缺少一个安全的便捷封装。
- **建议**：`let codec = DefaultCodec(); try { codec.encode(data).finish().byteSize() ?? -1 } finally { codec.release() }`；或抽一个 `private func encodedSize(data: Data): Int64` 并注释「内部必须 release，否则每次泄漏一个池项」。更彻底的做法（属 f_codec）是让 `finish()` 之后的对象在 GC/作用域结束时归还，或提供 `bytes.byteSize()` 后自动回收的 API。

### [轻微][存量] `wireOf` 用固定 1 MiB 缓冲单次读取，超过 1 MiB 的帧会被静默截断

- **位置**：`f_protocol/src/default/truncated_message_test.cj:74-81`（`Array<Byte>(1 << 20, repeat: 0)` 在 `:78`，`buf.read(all)` 在 `:79`）
- **来源**：存量（blame：`fb69eede1` 2026-10-03）
- **判据**：review-checklist §11（边界未校验 / 隐式上限）、§14（测试基建可维护性）
- **证据**：静态确定 —— `ByteBuffer.read(buffer)` 单次读取最多填满 `buffer`（与 `Message.readFully` 的 `let n = input.read(tmp)`、`tmp.size = 剩余` 用法一致，`Message.cj:72-73`），因此 `n <= 1 MiB`；`all[0..n]` 静默丢弃第 1 MiB 之后的字节，没有任何断言或注释提示这个上限。当前用例最大 9000 B（`:226`、`:298`），未触发。
- **描述**：模块自身允许最大 1 GB 的帧（`Message.cj:29`、`ProtocolConfig` 默认 `1 << 30`），而测试 helper 有一个未声明的 1 MiB 上限。一旦有人新增 2 MB 帧的用例，`wireOf` 返回的是**被截断的真帧**：在「必须抛」的用例里会因为截断而通过（假绿），在往返用例里则报一个与真实原因无关的 `len` 断言失败，排查成本很高。
- **建议**：按 `EncodedMessage` 的 `byteSize()` 精确分配（或循环 `read` 直到返回 0）；若刻意限制测试帧大小，就写成 `private const TEST_FRAME_LIMIT = 1 << 20`，超过时 `@Assert`/抛错而不是静默切片。

> **合并提示（不计入本部分缺陷数）**：README 的「其他公开 API」清单（`f_protocol/README.md:216` / `README_en.md:220`）还漏了 `InputClosedException`（`f_protocol/src/exception/InputClosedException.cj:18`；下游必须写 `import fountain::f_protocol.exception.InputClosedException`，见 `f_net/src/server/server.cj:27`），且 `CommandException`/`InputClosedException` 两个类都没有任何 KDoc 说明抛出条件。这与第 1 部分「一般 #8：README 公开 API 清单失真」同根因，合并时并入该条，不另计。

## 优化可行性方案

> 不是缺陷，是「还能更好」；无基线的方案只作待验证假设，不进 tasks。

<!-- 第 1 部分 -->

### [堆内存] 编码缓冲池常驻 ≈ 8 MB，按实际并发编码线程数收紧

- **现状**：`f_codec/src/default/DefaultCodec.cj:49-50` 的 `byteListOutputBuilder` 是 `initSize: 1024, minSize: 1024, maxSize: 1024`，单缓冲 `capacity` 默认 8192（`f_pool/src/BytesListOutputStream.cj:240`），即**进程常驻 1024 × 8192 B ≈ 8 MB**（`doc/perf/frame-encode-4k.md §6` 已记录该数）；另有每线程本地缓存 2 × 8 KB（`BytesListOutputStream.cj:242`）。
- **方案**：把 `initSize` 收到「峰值并发编码线程数 × 2」量级（如 64~128），`maxSize` 保留 1024 以吸收突发；单缓冲 `capacity` 若要下调，下限必须 ≥ `SMALL_MESSAGE_LIMIT + FRAME_OVERHEAD` = 4106（`Message.cj:325`、`:52-54`），否则 4 KB 档的帧会落到扩容路径（扩容缓冲不归还池，见 `BytesListOutputStream.cj:126-129`），可取 8192 → 4160 这类贴近上限的值。
- **预期**：常驻从 ≈ 8 MB 降到 0.5~1 MB（一个数量级），`allocBytesPerFrame` 不变（稳态复用同一批缓冲）。
- **代价**：并发超过 `initSize` 时 `build` 会走池增长/等待（`maxWaiting` 默认 30 s 的等待面变大）；`capacity` 收紧后 4~8 KB 帧必然走扩容（扩容后不归还池 → 更多 GC 垃圾）。需先确认生产峰值并发编码线程数与 4 KB 以上帧的占比。
- **验证**：稳态负载 10 分钟采 RSS + `getUsedHeapSize()` + `f_pool` 的 borrow 等待/超时计数；同机 `cjpm bench -O2` 对照 4 KB 帧 p50/p99 与 16 线程扩展比（对齐 `doc/perf/frame-encode-4k.md §11` 的口径）。
- **证据状态**：`已有基线（doc/perf/frame-encode-4k.md §6：1024 × 8192 B ≈ 8 MB；§10：384 B/帧）`

> 本部分没有具备基线的 CPU 方案：`doc/perf/frame-encode-4k.md` 的对照数据只覆盖**编码**路径（C p50 1341 ns、分配 384 B/帧），而解码路径没有任何 profile 或 bench 数据，相关候选一律进「待验证假设」。

<!-- 第 2 部分 -->

本部分只有测试代码与两个空壳异常类型，没有可量化的堆内存 / CPU 改造对象：

- 堆内存：测试期的 1 MiB `wireOf` 缓冲与 8 KB 池项泄漏都属于测试进程内的一次性开销，不构成可写进 `tasks` 的优化方案（池项泄漏已作为缺陷单列）。
- CPU：没有 profile / bench 数据，异常构造是否成为断链路径热点只能进「待验证假设」。

## 待验证假设

<!-- 第 1 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 解码每帧至少 6 次小数组分配 + 双拷贝：`readFully` 每次 `read` 新建 `Array<Byte>(剩余)` 再逐字节拷回（`Message.cj:69-86`），`FrameBodyStream.read` 同样每次 `tmp` + 逐字节拷（`:114-133`），`decode` 还额外分配 header/CRC 数组（`:286`、`:310`） | `Message.cj:69-86`、`:114-133`、`:286`、`:310` | 解码的 ns/帧与分配字节/帧（当前只有编码基线 1341 ns、384 B/帧，见 doc/perf §11） | 给 `Message.decode` 加 `getAllocatedHeapSize()` 窗口埋点，跑 4 KB 帧 5 万次；再用 `cjprof record` 看 `readFully`/`FrameBodyStream.read` 自耗时占比。对照改法：直接 `input.read(buffer[got..got+want])` 读入目标切片，去掉 `tmp` 与拷贝 |
| 2 | 每条工厂消息都做一次 `Config.getValue<Int64>` + `Int64` 字符串解析（`MessageID` 默认参数），在 1 µs 级编码预算里占可观比例 | `MessageID.cj:25`、`ProtocolConfig.cj:24-26`、`Message.cj:143` | 该路径在 `Message.publish/register` 自耗时中的占比 | `cjprof` 采样工厂方法调用链；或临时把 `hostId` 缓存成 `static let` 做 A/B（同机、`-O2`、5 万帧、中位数） |
| 3 | `Message.decode` 每帧 `new DefaultCodec()` + 4 次 `?T.getOrThrow{...}` 闭包（`:300-305`）的解码开销大于实际字段解析 | `Message.cj:300-305` | 对象分配数/帧与 decode 自耗时占比 | 分配埋点 + `cjprof`；对照「复用线程本地 codec」改法（注意这是 spec 已评估后搁置的方向，需先拿数据） |
| 4 | > 4 KB 的大帧走「头 + 流式载荷 + CRC」两次 write 且经过 `Crc32OutputStream` 逐次虚调用，吞吐明显低于小帧路径 | `Message.cj:378-391` | 8 KB / 64 KB payload 的 ns/帧与 write 次数 | 用 `F_PROTOCOL_BENCH` 现有 harness 改 payload 尺寸跑 `cjpm bench -O2`，对比 4 KB 档的 p50/p99 |

<!-- 第 2 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 每次正常断链都 `new InputClosedException`，而 `BaseException` 给每个实例分配一个 `ArrayList<Exception>`（`f_base/src/BaseException.cj:45`）；高连接 churn 的服务端（`f_net/src/server/server.cj:143` 每条连接关闭走一次）里，异常构造 + 栈回溯可能占关闭路径的可观比例 | `f_protocol/src/exception/InputClosedException.cj:18`、`Message.cj:288`、`f_net/src/server/server.cj:143` | 每次断链的分配字节数、`InputClosedException` 构造的自耗时占比 | `cjprof` 跑 10k 次 connect/close（同机、`-O2`、固定并发），对照「复用单例异常（不可变、不加 suppressed）」与现实现的 ns/次、alloc/次；注意单例异常会丢栈信息，需同时评估可诊断性 |

## 文件覆盖

> 与 `files/f_protocol.txt` 一一对应；分部分报告逐文件确认已读。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_protocol/README.md` | .md | ✅ | — |
| 2 | `f_protocol/README_en.md` | .md | ✅ | — |
| 3 | `f_protocol/doc/perf/frame-encode-4k.md` | .md | ✅ | — |
| 4 | `f_protocol/doc/spec/frame-encode-attrib/design.md` | .md | ✅ | — |
| 5 | `f_protocol/doc/spec/frame-encode-attrib/proposal.md` | .md | ✅ | — |
| 6 | `f_protocol/doc/spec/frame-encode-attrib/tasks.md` | .md | ✅ | — |
| 7 | `f_protocol/doc/spec/frame-encode-bench/design.md` | .md | ✅ | — |
| 8 | `f_protocol/doc/spec/frame-encode-bench/proposal.md` | .md | ✅ | — |
| 9 | `f_protocol/doc/spec/frame-encode-bench/tasks.md` | .md | ✅ | — |
| 10 | `f_protocol/src/Protocol.cj` | .cj | ✅ | — |
| 11 | `f_protocol/src/default/FrameEncodeBench_test.cj` | .cj | ✅ | — |
| 12 | `f_protocol/src/default/Message.cj` | .cj | ✅ | — |
| 13 | `f_protocol/src/default/MessageID.cj` | .cj | ✅ | — |
| 14 | `f_protocol/src/default/Message_unsubscribe_test.cj` | .cj | ✅ | — |
| 15 | `f_protocol/src/default/ProcessID.cj` | .cj | ✅ | — |
| 16 | `f_protocol/src/default/ProtocolConfig.cj` | .cj | ✅ | — |
| 17 | `f_protocol/src/default/ProtocolTestSetup_test.cj` | .cj | ✅ | — |
| 18 | `f_protocol/src/default/Protocol_test.cj` | .cj | ✅ | — |
| 19 | `f_protocol/src/default/constants.cj` | .cj | ✅ | — |
| 20 | `f_protocol/src/default/imports.cj` | .cj | ✅ | — |
| 21 | `f_protocol/src/default/truncated_message_test.cj` | .cj | ✅ | — |
| 22 | `f_protocol/src/exception/CommandException.cj` | .cj | ✅ | — |
| 23 | `f_protocol/src/exception/InputClosedException.cj` | .cj | ✅ | — |
| 24 | `f_protocol/src/exception/imports.cj` | .cj | ✅ | — |

合计：`.cj` 15 个 / `.md` 9 个 / 共 24 个，全部读完。

## 覆盖自检

### 第 1 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 11 | 正确性 4（一般 #6 `DataNone` 静默、#7 `tryFromData`、轻微 #4 `auth` 丢载荷、#6 PING 身份）；设计 2（一般 #3 默认 1 GB 上限、轻微 #7 `socket` 强转）；语言特性 2（一般 #5 `?T` + `getOrThrow` 抛无消息异常、#6 `Option` 被 `build` 吞掉）；可读性 1（轻微 #3 双分支）；安全性 2（一般 #3 未认证输入、#4 配置绕过 4 B 上限） |
| §1 死代码 | 2 | 已逐个搜引用：`maxFramePayloadCache`、`framePayloadLimit`、`FRAME_VERSION`、`FRAME_HEAD_SIZE`、`FRAME_CRC_SIZE`、`FRAME_OVERHEAD`、`putInt32BE`、`getInt32BE`、`readFully`、`Crc32OutputStream`、`FrameBodyStream`、`toData`/三个私有 `build`/公开 `build`、`to(bool,byte)`、`payloadSize`、`asOneSmallFrame`、`SMALL_MESSAGE_LIMIT`（Message.cj）、`hash`（MessageID）、`pid`/`init`（ProcessID）、`tag`（constants）均有调用者；`protected` 声明为 0；顶层 `public`（`Protocol`、`MessageCopier`、`Message`、`EncodedMessage`、`MessageID`、`ProcessID`、`CurrentProcessID`、`ProtocolConfig`、`QoS`、`Command`、13 个常量）对外可达，按硬原则一不判；`QoS.parse`、`WITHNODE`、`Message.tryFromData` 仓内仅测试或零引用，只作信息。命中 2：`Command.parse` 不可达分支（轻微 #1）、`QoS.parse` 注释块（轻微 #5） |
| §2 重复逻辑 | 2 | 同文件两两比较了 `Message.cj` 全部函数体、`constants.cj` 5 个 match 转表、bench 12 个 helper：命中标志位表三处复制且已漂移（轻微 #2）、`asOneSmallFrame` 双分支（轻微 #3）。跨文件搜了错误文案（`frame truncated`/`frame payload size` 各两处，读侧/写侧语义不同，不算重复）、`'frame crc'`。bench 的 `writeInt32BE`/`bigEndianInt32`/`floorFrame` 与生产代码逐行对齐但目标是「测生产同一条路径」，并有 `noCrcFrameMatchesProductionMinusCrc`/`floorFrameMatchesProductionFrame` 逐字节守卫，不判重复；`slaveof` 四个重载是一行转发，不算重复 |
| §3 空实现 | 0 | 全部函数体均有实现；无 `TODO`/`FIXME`/`throw UnsupportedException`；无 `catch {}` 吞异常（`ProtocolTestFailingSink.flush(){}` 是测试 stub，属有意 no-op） |
| §4 栈溢出 | 0 | 本模块无递归（直接/间接调用图已过；`Message.decode → DefaultCodec.decodeData` 的集合递归在 f_codec，见范围外提示）。`Message.encode` 的 `ChainedBytesCopyTo` 只有一层 |
| §5 OOM | 1 | 一般 #3（对端声明长度驱动 1 GB 分配 + 无帧级超时）。已核对编码侧不按声明长度预分配：> 4 KB 走流式（`Message.cj:378-391`），小帧上限 4096（`:325`）；解码侧无全量物化，但 `checkedBuffer` 的分配上限就是帧上限 |
| §6.1 热点瓶颈 | 0 | 只有编码的对照数据（`doc/perf/frame-encode-4k.md`：C p50 1341 ns、384 B/帧、CRC 25~35%），**没有 cjprof self-time，也没有解码数据**；`readFully`/`FrameBodyStream`/`MessageID` 配置读取/每帧 codec 四个候选全部进「待验证假设」，未计入发现 |
| §6.2 大粒度锁 | 0 | 本模块无锁；`framePayloadLimit` 是竞态但不是锁粒度问题（一般 #2）。池锁在 f_pool，不在本部分范围 |
| §6.3 并发串行 | 0 | 生产路径无 `spawn`/`Future`；`FrameEncodeBench_test.cj:178-207` 的 `runThreaded` 是「先提交全部再统一汇合」（`:196-200`），无 `spawn` 后立刻 `get` |
| §6.4 低效算法 | 0 | 无嵌套循环 / 热点 `contains` / `remove(at: 0)` / 循环字符串拼接；`readFully` 与 `FrameBodyStream.read` 的「每次 read 分配 tmp + 逐字节拷」属常数级低效，缺测量，见待验证假设 #1 |
| §7 降堆内存方案 | 1 | 编码缓冲池 8 MB 收紧（有基线，见「优化可行性方案」）。解码缓冲（header 6 B、CRC 4 B、`tmp`）量级太小，不单列方案 |
| §8 降 CPU 方案 | 0 | 无基线：只有编码侧有数据，且 `doc/perf §10` 已把「编码器复用/去虚」评估为「收益不抵复杂度」；解码侧无任何测量，候选进待验证假设 1/3/4 |
| §9 local mode 可行性 | 0 | 逃逸检查不通过：编码缓冲（`BytesListOutputStream`）、`EncodedMessage`、解码出的 `Message`/`Data` 全部返回给调用方或存入池，唯一不逃逸的是 `readFully`/`FrameBodyStream` 的 `tmp`（大小等于解码器请求的读长，通常 1 B~几 KB），其峰值远小于 payload 本身，收益无法用峰值内存证明；且 `DefaultCodec`/`ChainedBytesCopyTo` 都在 f_pool/f_codec，跨包改造需同 SDK 重编 |
| §11 现有代码的 BUG（存量） | 9 | 一般 #1、#3~#7 与轻微 #6、#7（#2 记在 §12，#8 记在 §14）；本轮逐条核对了帧头各条边界（空流 / 半头 / 版本不符 / `len` 超限 / 帧体过半截断 / 载荷未读尽 / CRC 缺失 / CRC 不符）、`len` 与 `remainingBytes` 的一致性、`DataNone` 的 1 字节占位、大帧流式路径的 CRC 覆盖范围，均正确；本报告 17 条发现全部为存量 |
| §12 并发安全与锁粒度 | 1 | 一般 #2（`maxFramePayloadCache` 竞态，已给出两个并发访问者与缺失的同步手段）。锁粒度 0（本模块无锁）。其余共享点核对：`MessageID.pidgen`、`CurrentProcessID.pid` 都是静态 `let`，库初始化期赋值；编码池的线程安全由 f_pool 的 `ThreadLocal` 缓存 + 池锁保证（MT 用例 `singleBufferPoolReuse2k`/`multiThreadHarnessCountsBytes` 兜底） |
| §14 功能完备性与 README 覆盖 | 1 | 一般 #8（README 列了不存在的 `read`/`write`，漏 `ProtocolConfig`/`ProcessID`）；`Protocol`/`MessageCopier`/`Message` 工厂/`EncodedMessage`/`MessageID`/`QoS`/`Command` 与 README 的符号逐项对照无缺；测试覆盖缺口见轻微 #5（`QoS.parse` 非法位） |
| 文件覆盖（§13 等） | 20/20 | 与 `files/f_protocol.part1.txt` 一一对应，无缺失；第 2 部分的 4 个 `.cj` 不在本报告范围 |

### 第 2 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 1 | 正确性 1（一般 #1：用例断言弱于文档契约）；设计 0（异常类型与 `f_exception` 模板一致，不引入新抽象）；语言特性 0（`?T`/`match` 用法本身正确，问题在分支覆盖）；可读性 0（命名 `DribbleInputStream`/`CollectOutputStream` 与用途相符）；安全性 0（测试不开外部端口、不读真实凭据、不落盘） |
| §1 死代码 | 1 | 逐一核过：`DribbleInputStream`（data/pos/step/read）、`CollectOutputStream`（list/write/bytes）与 9 个私有 helper（`wireOf`/`decodeThrows`/`payload`/`dataFieldSize`/`lenOf`/`crcOf`/`reframe`/`stringField`/`frameWithDataField`）全部有调用者；4 条 import 均被使用；`CommandException`/`InputClosedException` 是 public 顶层类（对外可达，按硬原则一不判），其 `init()`/`init(caused:)` 仓内零引用只作信息；`internal import BaseException` 被两个类使用。命中 1：两处 `case _ => []` 不可达（轻微 #1） |
| §2 重复逻辑 | 0 | 逐行比对了两个异常类：4 个构造器完全相同，但差异是**类型身份本身**（`f_net` 按 `InputClosedException` 捕获），合并成基类不会减少代码且会改变公开继承链；且该 4 构造器模板是 `f_exception/README.md:5-14` 明示的全项目约定，不判重复。测试侧把 `reframe`/`stringField`/`frameWithDataField` 压成「输入→输出」比对：三者共享的只是 4~8 行大端写字节，用途分别是「改帧」「拼字段」「拼整帧」，边界与输入不同，抽 helper 收益低于误用风险，不判重复；`wireOf` 相比 `Protocol_test.cj` 里 15 处内联样板是收敛而非复制 |
| §3 空实现 | 0 | 全部函数体有实现；`public init() {}` 是异常类的空体构造器（隐式 `super()`），无契约承诺，不属空实现；无 `TODO`/`FIXME`/`throw UnsupportedException`；无 `catch {}` 静默吞异常（`decodeThrows` 的 catch 有返回语义，已作为一般 #1 单列） |
| §4 栈溢出 | 0 | 本部分无递归（`Message.decode` 的集合递归在 f_codec，第 1 部分已作范围外提示）；`DribbleInputStream`/`CollectOutputStream` 都是线性循环，循环次数由数组长度界定 |
| §5 OOM | 0 | 测试侧缓冲有界（`wireOf` 1 MiB、`payload` ≤ 9000 B、`stringField` 9+B）；没有按不可信长度分配；`oversizedValueLengthIsRejectedBeforeAllocating` 正是验证「1 TB 声明在分配前被拒」，不构成 OOM 面。生产侧 1 GB 上限问题属第 1 部分一般 #3 |
| §6.1 热点瓶颈 | 0 | 本部分无 profile / bench 数据；唯一候选（每条断链构造异常）因缺自耗时占比，按铁律进「待验证假设 #1」，未计入发现 |
| §6.2 大粒度锁 | 0 | 本部分没有锁、没有 `synchronized` |
| §6.3 并发串行 | 0 | 没有 `spawn`/`Future`/线程池；测试类由 unittest 框架单线程驱动 |
| §6.4 低效算法 | 0 | 无嵌套循环、无热点 `contains`、无 `remove(at: 0)`、无循环字符串拼接；`CollectOutputStream.write` 逐字节 `add` 是 O(n) 且 n ≤ 9000（测试专用），不构成低效算法 |
| §7 降堆内存方案 | 0 | 只有测试期临时对象与两个异常实例，无长期持有；池项泄漏是缺陷不是优化项，已单列 |
| §8 降 CPU 方案 | 0 | 无基线数据，候选进「待验证假设 #1」 |
| §9 local mode 可行性 | 0 | 本部分没有生产函数内的临时大对象；测试里的字节数组会作为帧返回给断言，不满足不逃逸前提，收益无法用峰值内存证明 |
| §11 现有代码的 BUG（存量） | 4 | 4 条发现全部标存量：一般 #1（异常类型未被断言）、轻微 #1（不可达 case）、轻微 #2（池项泄漏）、轻微 #3（1 MiB 隐式上限）。已逐条核对两个异常类的构造器转发、`DribbleInputStream` 在 EOF 返回 0 与 `Message.readFully` 的 `n <= 0` 判定一致、`reframe`/`stringField` 的大端位运算与 `putInt32BE`/`getInt32BE` 一致、`crc32(空数组) == 0` 与 `crc32Init/crc32Finish` 语义一致（标准检查值 0xCBF43926），均无缺陷 |
| §12 并发安全与锁粒度 | 0 | 两个异常类型无自有可变状态（`BaseException.suppressed_` 是每实例的，异常对象按抛出线程封闭）；测试类与方法由 unittest 框架串行调用，无共享路径；不存在「每次新建锁对象」「检查-然后-写入」等形态 |
| §14 功能完备性与 README 覆盖 | 0 | 本部分新增 0 条：`CommandException` 已在 README:216 列出；`InputClosedException` 只在解码异常表（README:58）出现、未进公开 API 清单，与第 1 部分一般 #8 同根因，已写在「合并提示」并入该条，不重复计数 |
| 文件覆盖（§13 等） | 4/4 | 与 `files/f_protocol.part2.txt` 一一对应，无缺失；本部分无 `.md`，§13 的文档一致性只涉及 README 对这两个异常类的描述（见合并提示） |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 9 |
| 轻微 | 12 |
| 其中存量 | 21 |
| 优化方案 | 见「优化可行性方案」各条 |

## 总评

**第 1 部分**：**帧编解码的边界处理本身是本模块质量最高的部分。** 帧头 6 B、帧尾 CRC、`FrameBodyStream` 的物理限长、`SizeBoundedInput.remainingBytes` 的「分配前先比对」、`payloadSize` 的收发两侧校验构成了完整的防线：任何截断、版本不符、CRC 不符都不会返回半条消息，解码器也无法读出本帧之外（`Message.cj:285-320`）。这部分还有一组相当扎实的用例（本部分的空流/半头 + 第 2 部分 `truncated_message_test.cj` 的 15 条截断与长度用例），并且编码侧的性能改造（单缓冲 + 原地补帧、线程本地池、硬件 CRC）留下了可复核的 A/B 数据与逐字节守卫，属于「改过且证明没改坏」的少数区域。

**风险集中在三条边上，按优先级如下。**

1. **异常安全**（一般 #1）：`Message.encode()` 一旦抛异常，借出的编码缓冲永久不归还。这不是「漏一次 8 KB」，而是池的借还计数失去 1024 个名额后全进程写停摆；触发条件（NaN/不支持类型）在业务里完全可能出现，而现有回归只覆盖了 `copy()` 失败。修复只需一个 `try/catch { codec.release() }`，应最早做。
2. **长度上限的配置面**（一般 #3、#4）：默认 1 GB 让未认证对端可以「不到 20 字节换 1 GB + 一个线程」，而把上限调大又会踩到 4 B `len` 字段的静默截断；两个方向都没有校验或预算。建议把默认值降到业务上界并把范围校验写进 `ProtocolConfig`，同时把「帧级读超时」写进 `Protocol` 的契约，而不是留给调用方猜。
3. **错误契约的漂移**（一般 #5、#6、#7）：`decode` 用 `IllegalArgumentException`（无消息）表达帧头字段类型不符、用 `DataNone` 表达「载荷类型不符」、`tryFromData` 的 KDoc 与实现相反。单看每条都不致命（`f_net` 用 `catch (Exception)` 兜住），但它们让「协议错误」无法被统一分类与计数，也让下游按文档写代码时拿到意料之外的异常类型。

**并发面只有一处**（一般 #2）：`framePayloadLimit` 的无同步惰性缓存，值幂等但发布不安全。修法很轻（启动期初始化成 `let`），建议顺手做掉，因为它每帧都在读。

**死代码与重复逻辑各 2 条，都很轻**：`Command.parse` 的不可达分支、`QoS.parse` 的注释块与空转用例；标志位表三处复制已经漂移出一处错误（`constants.cj` 的 PING 行），属于「注释把人带偏」的典型。

**文档**：README 的帧格式、标志位、枚举、配置表、异常语义与实现高度一致（逐条比对过），性能文档的取数口径也是本项目里少见的严谨；问题只在「其他公开 API」清单（列了私有类成员、漏了 `ProtocolConfig`）与「配置缓存」一句描述。`README_en.md` 与中文版同步良好。

**性能**：编码侧已有可信基线（4 KB 帧 p50 1341 ns、384 B/帧、CRC 占 25~35%），本轮不再重复提已经评估过的「编码器复用」；**解码侧完全空白**（无 profile、无 bench），这是下一轮最值得补数据的地方，四个候选都在「待验证假设」里，未写成任何收益结论。

存量缺陷共 17 条（严重 0 / 一般 8 / 轻微 9），是否纳入修复由用户决定；本轮只读代码、未改任何源码、未跑构建。

（范围外提示：`f_codec/src/default/DefaultCodec.cj:917-958` 的集合/映射解码按嵌套层级递归，嵌套深度 ≈ 载荷字节数 / 2，深嵌套构造帧可把递归深度推到万级（是否溢出取决于栈大小，需实测），入口在本模块的 `Message.decode`，建议在 f_codec 报告中单列；同文件 `:1032-1072` 会把超过 `fileThreshold` 的 `INPUTSTREAM` 载荷写入 `/tmp` 临时文件，同样是对端可控的磁盘写入面。`f_pool` 的 `PooledBufferBytesCopyTo.byteSize()` 返回 `declaredSize`（`BytesCopier.cj:55-61`），若流的实际字节数与之不符，本模块的 `len` 字段会与实际 payload 不一致，属跨模块契约风险。）

**第 2 部分**：**本部分是「防线上的防线」：一段专门锁定帧截断语义的回归测试，加上两个没有任何逻辑的异常类型。** 20 个用例把「半头 / 半体 / 半尾 / 长度不一致 / CRC 不符 / 版本不符 / 逐字节短读 / 帧内值级超长声明」逐条覆盖，构造手法（`reframe` 重写 len 后重算 CRC、`stringField` 手工拼 8 字节长度头、`frameWithDataField` 借合法帧前缀）是扎实的，且 `splicedDataFieldStillDecodes` 先自检拼接方式再测超长声明，避免了「用例本身构造错」的假阳性。异常类型与 `f_exception` 的模板一致，没有自有状态，线程安全按「每实例每线程」成立。

**唯一的实质问题是「断言口径」而不是「用例数量」**（一般 #1）：`decodeThrows` 把 `Exception` 全吞，导致这 20 个用例只证明「解码器没有静默返回消息」，没有证明「解码器把截断归类为协议错误」。而模块的对外契约恰恰是两分法（干净关闭 vs 协议错误），`f_net` 也按这两类做不同处理（一个 DEBUG 断链、一个记错误）。一旦有人为了「兼容短读」把截断改回 `InputClosedException`，测试全绿、线上把协议错误当正常下线——这是本部分唯一值得排期修的点，改动量只有几行。

**三条轻微问题都在测试基建**：`dataFieldSize` 借池不还（与第 1 部分一般 #1 同类，说明 `DefaultCodec` 的所有权契约容易被自然用法踩中）、`wireOf` 的 1 MiB 隐式上限（未来大帧用例的假绿陷阱）、两处不可达 `case _`（`Option` 的两个构造器已被前两支覆盖）。都不影响当前行为，可随下一次改测试文件时顺手清掉。

**文档**：两个异常类没有 KDoc，README 的公开 API 清单漏了 `InputClosedException`；与第 1 部分的清单问题同根因，合并处理即可。

本部分共 4 条存量问题（严重 0 / 一般 1 / 轻微 3），是否纳入修复由用户决定；只读代码，未改任何源码、未跑构建。

（范围外提示：`f_protocol/cjpm.toml:26` 声明了 `fountain::f_exception` 依赖，但 `f_protocol/src/**` 全仓 grep 不到任何 `f_exception` 引用，该依赖疑似为历史残留，属依赖卫生问题，不在本轮文件清单内故不计。）
