# f_mq 模块审查报告（模块第 4/6 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_mq`（本部分 20 个 `.cj`；模块整体 61 个 `.cj` + 36 个 `.md`）
- **基线**：工作区快照（sts/1.3.x 工作区，未对照远端目标分支；本部分无 diff 基线，全部问题判为 `存量`）
- **审查重点**：消息队列投递/确认语义、重复与丢失、无界队列 OOM、大粒度锁与并发串行、死代码、重复逻辑、存量 BUG
- **报告版本**：v1（模块第 4/6 部分，只覆盖 `files/f_mq.part4.txt` 的 20 个文件；模块报告由主 Agent 合并，本文件不写 `docs/review/`）
- **本部分范围**：`f_mq/src/base/{MQMessageRecord,MQProtocol,MQTags,MQTopic}.cj` + `model/{MQMessage,MQMessageContent,MQSubscribeGroupMeta,MQTopicMeta}.cj` + `payload/{MQAckPayload,MQBackupCursor,MQBackupPayload,MQBackupState,MQBlob}.cj` + 7 个 `_test.cj`

## 发现

### [严重][存量] 大 BODY 的临时文件清理只覆盖「字节字段」路径：`MQMessageRecord.decode` / `body()` 把文件形态原样交给上层（与第 3 部分 #1 同源，合并为一条）

- **位置**：`f_mq/src/base/MQMessageRecord.cj:69`（`decode` 把第 4 段直接包成 `DataAny(v[3])`）、`f_mq/src/base/MQMessageRecord.cj:141-146`（`body()` 同样原样返回）；唯二的清理实现 `f_mq/src/base/payload/MQBlob.cj:97-144`
- **影响路径**：`f_mq/src/client/MQClient.cj:244`（`MQMessageRecord.decode(result.record.copyBytes())`）→ `:255` `content.toMessage(...)`，之后既没有 `close()` 也没有 `removeIfExists`；服务端 `fmq/src/queue/MQMatcher.cj:110`（同源路径，已由第 3 部分登记）
- **来源**：存量 —— `git blame`：`MQMessageRecord.decode` 出自 6303d88（2026-10-18「feat(f_mq): 新增消息队列客户端与共用协议库」）；唯一清理实现 `MQBlob.readWholeFile` 出自 ed9f73c（2026-10-21「fix(f_mq): 字节字段改用 MQBlob，修复 >4096 字节记录被降级为空（A01/A07）」）——清理只加在字节字段上，记录 BODY 路径没跟着改
- **判据**：review-checklist §11（资源不对称）、§5（无界增长）、§3（错误/形态被静默折掉）
- **证据**：静态确定 ——
  1. `f_codec/src/default/DefaultCodec.cj:1000-1036`：`INPUTSTREAM` 值 `size > fileThreshold`（默认 4096）时创建 `/tmp/tmpFile<UUID>/` 并 `File.createTemp(dir)`，解码结果是 `DataInputStream(File)`（`f_data/src/base/DataInputStream.cj:20-32`）；
  2. 字节块正好编码成该形态（`f_codec/src/default/DefaultCodec.cj:542-549`：`encode(Array<Byte>)` 写 `INPUTSTREAM` 头 + 长度），所以 BODY 里任何 > 4096 字节的字节序列（直接 BODY 或对象字段）解码后都是文件形态；
  3. `DefaultCodec.release()` 只归还编码侧 `inputs`（`DefaultCodec.cj:720-726`），不删除解码产生的文件；
  4. 全仓唯一的清理在 `MQBlob.readWholeFile`（`close` + `removeIfExists(path)` + 删父目录，`MQBlob.cj:115-135`），它只被 `MQBytes.fromData`（`MQMessageRecord.cj:200-214`，作用于**整条记录字节**）与 `MQBlob.tryFromData`（作用于**声明为 `MQBlob` 的字段**）调用；`decode`/`body` 返回的 BODY 不经过这两条路径；
  5. 无兜底清理器：`grep -rn "tmpFile" f_mq/src f_codec/src f_data/src` 只命中 `DefaultCodec.cj:1022`、`:1032`（创建处）与一条测试，没有任何删除/启动扫描逻辑。
- **描述**：BODY 为大字节（> 4096）时，每解码一次记录就新建一个 `/tmp/tmpFile<UUID>/<filename>` 并保持打开，客户端 `consume` 后不关闭、不删除；按 `MQClient.cj:244` 的调用频率，`/tmp` 文件与 fd 随消费条数线性增长，直到磁盘/inode 耗尽（默认无需任何配置，发一条 5KB 字节 BODY 即触发）。同源后果「filter 判成不匹配并越过」「`MQMessage.get<Array<Byte>>()` 读成空数组/None」已由第 3 部分 #1 详述，本条只补充「记录 BODY 解码主路径」的位置与清理边界，合并时按一条计。
- **建议**：在 BODY 边界统一形态，而不是各使用点各自处理——把 `MQMessageContent.body` / `MQMessage.body` 的类型从 `DataAny` 改为 `MQBlob`（或新增同构的 `MQBody`），`decode`/`body()` 返回前就地 `MQBlob.tryFromData` 归一化（读回 + close + 删文件与父目录），失败返回 `None`；`MQMessage.get<T>` 相应支持 `MQBlob` → 字节。补用例：4096 / 4097 / 16KB 三档 BODY，断言 `get<Array<Byte>>()` 可读回且 `/tmp` 无残留。

### [一般][存量] 同一段 BODY 有两套类型闸门且结论不同：`MQMessage.get` 走 `SILENCE`（字符串可读成数字、结构漂移折成默认对象），`MQProtocol.asPayload` 走严格闸门

- **位置**：`f_mq/src/base/model/MQMessage.cj:62-88`（闸门 `:69-80`、转换 `:82` 的 `convert<T>(data)` 未传 `flag`）vs `f_mq/src/base/MQProtocol.cj:158-207`（`readPayload` 用 `flag = 0` 做对象转换，`scalarTypeMatches` 做标量闸门）
- **来源**：存量 —— `git blame`：`MQMessage.get` 主体出自 6303d88（2026-10-18），闸门所在行出自 5da7fe5（2026-10-21「fix(fmq): 内部载荷严格类型校验与 BODY 契约（A03/A04）」）——同一次严格化只改到 `MQProtocol.readPayload`，`MQMessage.get` 的 `convert<T>(data)` 没同步
- **判据**：review-checklist §2（近似重复导致行为漂移）、§11（契约与实现不符：`MQMessage.cj:54-61` 注释写「这里用严格转换把不匹配变成异常再折回 `None`（A04）」）
- **证据**：静态确定 ——
  1. `convert<T>(data)` 的默认 `flag` 是 `DEFAULT_DATA_FLAG = SILENCE`（`f_data/src/base/DataFields.cj:46`、`f_data/src/base/global_objects.cj:42-51`），因此 `convert` 在失败时走 `case _ => None`，**根本不抛异常**，注释里的「异常再折回」不成立；
  2. `SILENCE` 含 `IGNORE_FIELD_NOT_CONVERTABLE`，数值类型对 `DataString` 有正则兜底分支（`f_data/src/base/NumberData.cj:254-257` 的 `Int64` 分支：`DataString` 匹配整数正则且 `ignoreNotConvertable(flag)` → `DataReal(...).tryToInt64()`，各数值类型同构；同文件 `NumberData_test.cj:64-66` 用浮点固化了这条），于是 `MQMessage(body: DataString("42")).get<Int64>()` 返回 `Some(42)`，而 `MQProtocol.asPayload<Int64>(Message(..., DataString("42")))` 返回 `None`（`MQProtocol.cj:203-205`：`case _: DataString => stringTarget` → false）；
  3. 对象侧：同名异结构对象在严格路径返回 `None`（`MQProtocol_test.cj:287-294` 用 `DriftedMetaSyncRequest` 固化），在 `SILENCE` 路径 `DataObject.populate` 走 `case _ => target` 返回「字段全默认」实例（`f_data/src/base/DataObject.cj:194-206`）。
- **描述**：客户端取 BODY 的唯一入口（`MQMessage.get`）与服务端/内部载荷入口（`MQProtocol.asPayload`）对同一段字节给出不同结论：客户端把 `"42"` 读成 `42`、把结构漂移的对象读成字段全默认值，两端对「同一条消息的 BODY 是什么」不一致。A03/A04 的严格化只落到 `MQProtocol` 一处，`MQMessage.get` 的注释声称同样严格但实现没有走到。
- **建议**：把 `readPayload` 提升为 `fountain::f_mq.base` 内的 `internal` 共享实现，`MQMessage.get` 直接复用它（含 `scalarTypeMatches` 闸门与 `flag: 0`），删除 `MQMessage` 里的第二套闸门；补用例：`DataString("42")` 的 BODY 在两个 API 上同为 `None`，漂移对象在两个 API 上同为 `None`。

### [一般][存量] `MQTopic.isValid` 没有长度上限，而主题名 escape 后直接成为文件名（3× 放大）→ 注册时 `ENAMETOOLONG`

- **位置**：`f_mq/src/base/MQTopic.cj:25-35`（只校验非空 / `/` 前后缀 / 空段 / 空白与控制字符，无长度判定）
- **来源**：存量 —— `git blame`：`MQTopic.isValid` 整体出自 6303d88（2026-10-18「feat(f_mq): 新增消息队列客户端与共用协议库」），自引入起就没有长度判定
- **判据**：review-checklist §11（边界 / 契约与实现不符）；承诺源 `f_mq/doc/详细设计.md:419`「主题 `MQTopic` —（无显式长度上限）」、`f_mq/README.md:115`（长度限制表主题行也没有长度项）
- **证据**：静态确定（字节数可按输入复算，落盘失败形式待实测）——
  1. 主题名直接构成文件名：`fmq/src/meta/MQFileNames.cj:92-94`（`topics/${escape(topic)}.meta`），落盘点 `fmq/src/meta/MetaStore.cj:236`、`:301`；
  2. `escape` 按 UTF-8 **字节**逐字节转 `%XX`（`MQFileNames.cj:52-67`），放大 3 倍：28 个汉字 = 84 字节 → 252 字符 + `.meta`（5）= 257 > ext4/overlayfs 的 `NAME_MAX = 255`；纯 ASCII 下 250 字节主题 + 后缀即越界；
  3. 设计文档 `详细设计.md:425` 只对**组名**写了「会直接成为文件名，因此路径与转义字符必须在入口挡下」，主题同构却没写、也没校验。
- **描述**：`MQTopic.isValid` 与客户端的本地快速失败都放行任意长度的主题，服务端注册（`MetaStore` 写 `topics/<escaped>.meta`）或建目录时才失败，且失败点在深层 IO 而不是 `INVALID_TOPIC`；运维用 `fmq manager` 注册一个长中文主题即可复现。与第 3 部分 #2（组名 255 与文件名 255 冲突）同根因，本条只覆盖主题侧。
- **建议**：给 `MQTopic` 增加与 `MQFileNames` 同口径的上限（按「escape 后 + 后缀 ≤ 224」反推原始字节上限，约 70 字节），在 `isValid` 与 `MQCommandExecutor` 的权威校验里共用；或让 `MQFileNames` 对超长名改哈希短名并保留反查。补边界用例：70/71 字节 ASCII、23/24 个汉字。

### [轻微][存量] `MQProtocol.decodePayload(bytes)` 不校验「恰好用尽字节」，与同包 `MQMessageRecord.decode` 的 exact 语义相反

- **位置**：`f_mq/src/base/MQProtocol.cj:272-286`（`decodeData(ByteBuffer(bytes))` 后直接 `readPayload`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §1（恒真/恒假判定的对称性缺失）、§11（契约与实现不符）
- **证据**：静态确定 —— `MQMessageRecord.cj:34-35` 的类注释明确「完整性判定必须同时满足四段都解出与恰好消费完所有字节」，并在 `:176` 用 `buffer.readOffset != record.size` 落地；`MQProtocol.decodePayload` 的同一属性 `readOffset` 完全没用，尾部多余字节被静默忽略。`MQProtocol_test.cj` 也没有「多余字节」用例（对比 `MQMessageRecord_test.cj:222-226`）。
- **描述**：内部子载荷（`MQInternalMessage.payload`、`MQBackupPayload` 子载荷）在损坏/被拼接时会被当成合法载荷解码成功，坏数据进入备份与元数据路径；两套解码器对「什么算完整」口径不一。
- **建议**：`decodePayload` 内保留 `buffer` 引用并在解码后比较 `readOffset == bytes.size`，不相等返回 `None`；补一条「尾部追加 1 字节 → `None`」用例。

### [轻微][存量] 两个不可达的 `case ...: MQBlob` 分支（`tryFromData` 的每个返回都是 `?MQBlob`）

- **位置**：`f_mq/src/base/payload/MQBlob.cj:92`（`MQBlob.fromData` 的 `case x: MQBlob => x`）、`f_mq/src/base/MQMessageRecord.cj:211`（`MQBytes.fromData` 的 `case b: MQBlob => ...`）
- **来源**：存量（快照模式无基线；`MQBlob.cj:67-68` 的注释正是这两个分支的由来）
- **判据**：review-checklist §1（恒假分支）
- **证据**：静态确定 —— `MQBlob.tryFromData` 的每个 `return` 都是 `Some(...)` / `None<MQBlob>`（`MQBlob.cj:69-85`），而 `match` 的对象是 `Any`（`:88`、`MQMessageRecord.cj:205`）；`Some(x)` 装箱后不可能匹配非 `Option` 的 `case x: MQBlob`，因此两个分支恒不可达。
- **描述**：注释说明作者曾因 `Option` 推断踩坑，于是「两种形态都匹配」保平安；现在这两条分支只剩噪音，读代码时容易误以为 `tryFromData` 可能返回裸 `MQBlob`（进而影响判空逻辑的理解）。
- **建议**：把 `tryFromData` 的返回类型从 `Any` 收窄为 `?MQBlob`（接口 `FromData` 的约束允许具体化，参考 `DataFields` 里 `fromData` 的写法），然后删掉两个不可达分支；若必须保留 `Any`（接口约束），至少在分支上加注释说明不可达。

### [轻微][存量] `MQMessageRecord.cj` 有两个未使用的 import（`std.fs.*`、`std.io.SeekPosition`）

- **位置**：`f_mq/src/base/MQMessageRecord.cj:19`、`:20`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §1（未使用的 import）
- **证据**：静态确定 —— 该文件对 `File` / `Directory` / `exists` / `SeekPosition` 零引用（`grep -n "File\|Directory\|SeekPosition\|exists(" MQMessageRecord.cj` 只命中 `:20` 这条 import 自身）；同样的 import 在 `MQBlob.cj:18-19` 才是真正被 `readWholeFile` 使用的。
- **描述**：临时文件读写逻辑搬到 `MQBlob` 后，这两个 import 没跟着删；`cjpm` 会报 unused import 警告，干扰「编译零警告」的基线。
- **建议**：删除两行 import，并在 CI 里把 unused import 当错误。

### [轻微][存量] `encode` 模板重复：`MQMessageRecord.encode` 与 `MQProtocol.encodePayload` 是同一段「取池 → 编码 → 拷贝 → 释放」的复制

- **位置**：`f_mq/src/base/MQMessageRecord.cj:39-52` 与 `f_mq/src/base/MQProtocol.cj:245-257`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2（表现形式不同的重复逻辑：只改了类型参数与错误文案前缀）
- **证据**：静态确定 —— 两者逐行同构：`let codec = DefaultCodec()` → `codec.encode(...)`（前者 4 段链式、后者 1 段）→ `match (codec.finish().asBytes())` → `Some(bytes) => bytes.clone()` → `None => throw IllegalArgumentException("<前缀>: codec produced no bytes")` → `finally { codec.release() }`；连「必须在 release 前拷出」的注释都是同一句（`MQMessageRecord.cj:45` / `MQProtocol.cj:250`）。差异只有文案前缀与编码段数。
- **描述**：池缓冲的「拷贝后释放」这条易错约束现在有两份拷贝，任何一侧改动（例如改成 `finish()` 之后先取长度、或错误类型换成 `CodecException`）都会漂移。二者都在同一个包内、都是 public 静态方法，抽取不违反分层。
- **建议**：抽一个包内 `internal func encodeOnce(build: (DefaultCodec) -> Unit): Array<Byte>`（或用 `Data` 参数），两处改为调用它；`MQMessageRecord.encode` 的 4 段链式调用作为 `build` 闭包传入。测试侧无需改动。

### [轻微][存量] `MQBlob.readWholeFile` 错误路径的 `close` 失败被空 `catch` 吞掉（fd 泄漏不可见）

- **位置**：`f_mq/src/base/payload/MQBlob.cj:136-143`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §3（`catch (_: Exception) {}` 静默吞异常）、§11（资源不对称）
- **证据**：静态确定 —— 外层 `catch (_: Exception)` 已经在处理读失败，内层 `try { if (!file.isClosed()) file.close() } catch (_: Exception) {}` 把关闭失败的异常完全丢弃；同一文件在删文件/删目录失败时是有 `log.warn` 的（`:119-130`），只有关闭这条没有。
- **描述**：`close` 失败（fd 已被回收、FS 报错）时既不记录也不重试，句柄真正的泄漏点变成不可观测；排障时只能看到「消息 BODY 读不出来」，看不到 fd 状态。
- **建议**：内层 catch 补 `log.warn("cannot close decoded temp file ...: ${e.message}")`，与同函数其余清理失败的处置保持一致。

## 优化可行性方案

> 不是缺陷，是「还能更好」。本部分没有任何 bench / profile 数据，下面四条全部是 `无基线（待验证）`，不进 `todo.md` / `tasks.md`。

### [堆内存] 记录解码少一次整记录拷贝：`ByteBuffer(record)` 构造即整份拷贝

- **现状**：`MQMessageRecord.decodeValues` 每次都 `ByteBuffer(record)`（`MQMessageRecord.cj:171`），而 `f_io.ByteBuffer` 的数组构造会 `Array<Byte>(array.size)` 再 `write(array)` 整份拷贝（`f_io/src/ByteBuffer.cj:34-40`）。单条记录上限 64MB（`fmq/src/queue/QueueLog.cj:48`，`MAX_RECORD_SIZE = 64 * 1024 * 1024`），因此每次解码多一份整记录副本；`decode` 1 次 + 前缀解码各 1 次（见下一条）→ 一条消息最坏 4 份。
- **方案**：给 `f_io.ByteBuffer` 增加「不拷贝的只读视图」构造（或在 `MQMessageRecord` 内按偏移顺序解析，不建 `ByteBuffer`）；更省事的一步是先让调用方改用一次 `decode()` 拿 4 段。
- **预期**：单条 64MB 记录少 64–192MB 瞬时分配；常规 1KB 记录少 3KB/条（按调用次数线性）。
- **代价**：要么新增 codec 的「零拷贝输入」入口（改 `f_codec`），要么在 MQ 侧重写解析器（与线格式耦合，风险高）；只读视图需要文档约束调用方不得写。
- **验证**：`cjprof heap` + `getAllocatedHeapSize()` 前后对照，`-O2`，固定 1KB 与 64MB 两档，各 10 万条，给中位数与离散度。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] `MQProtocol.decodePayload(MQBlob)` 的全量副本：先 `copyBytes()` 再 `ByteBuffer(bytes)` 又拷一次

- **现状**：`MQProtocol.cj:267-269` → `:272` 的 `ByteBuffer(bytes)`，一条备份批次（N 条记录，单条 ≤ 64MB）在解码期至少存在「`MQBlob` 内部数组 + `copyBytes` 副本 + `ByteBuffer` 副本」三份，解码产物（`Array<MQBlob>`）再算一份。
- **方案**：`MQBlob` 增加只读的 `func borrowBytes(): Array<Byte>`（文档声明调用方不得修改），`decodePayload(blob)` 直接传入它；进一步配合上一条的「不拷贝 `ByteBuffer`」可只剩一份。
- **预期**：备份解码峰值降约 1/2（批次维度）。
- **代价**：`borrowBytes` 暴露内部数组，任何写入都会污染 `MQBlob`（需文档 + 只用 `internal`）；若 `MQBlob` 后续要支持流式，borrow 语义要重定。
- **验证**：100 条 × 64MB 的备份批次解码，`heapUsed` 峰值 + RSS 对照。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `MQMessageRecord.publishTime` 的逐条解析开销：split + toRuneArray + 7 次 String 切片与 `Int64.parse`

- **现状**：`MQMessageRecord.cj:106-138`：1 次 `split("_")`（分配 `Array<String>` + N 个 String）、1 次 `toRuneArray()`（分配 `Array<Rune>`）、7 次 `stamp[a..b]` 切片 + `Int64.parse`——单次约 9 次分配。调用点在服务端延迟投递判定与段扫描主路径（`fmq/src/queue/QueueLog.cj:260`、`fmq/src/server/ConsumeService.cj:247`、`fmq/src/queue/GroupCursor.cj:564`）。
- **方案**：`stamp` 已逐字符校验为 23 位 ASCII 数字，直接按下标取 `stamp[i]`（或先转一次 `Array<Byte>`）累加成 `year/month/day/h/m/s/nanos`，去掉 `split`、`toRuneArray` 与 `Int64.parse`。
- **预期**：单次分配从 ~9 降到 1–2（仅 `DateTime`）；耗时降幅待测（无 profile 数据）。
- **代价**：手写字段拆分，需保留现有非法值用例（月/日越界仍由 `ofUTC` 抛错兜底，`MQMessageRecord_test.cj:177-180`）。
- **验证**：`cjpm bench -O2`，10M 次 `publishTime`，改前/改后中位数与离散度；再回服务端做一次端到端延迟对照。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 前缀解码合并：一条记录最多被顺序解码 3 次（topic / tags / body）

- **现状**：`MQMessageRecord.cj:153-158` 的注释已说明「每次调用都会从记录头顺序解码」；服务端匹配对同一 record 依次调 `topic()`（`fmq/src/queue/MQMatcher.cj:77`、`:93`）、`tags()`（`:100`）、`body()`（`:110`），因此一条记录最多 3 次全量顺序解码 + 3 次整记录拷贝。
- **方案**：匹配阶段改为一次 `decode(record)`（已有）取 4 段后传给 matcher；或新增 `decodePrefix(record, count)` 让「只要 tags」时只解 2 段。
- **预期**：匹配阶段解码次数 3 → 1（按调用次数估，端到端收益待测）。
- **代价**：改 `fmq` 侧调用方（跨模块），且要保留「topic 解不出 → 走 `MQMatcher.cj:93` 失败分支」的语义；`decode` 要求恰好用尽字节（更严格），对损坏记录的行为会从「前缀可解」变成「整体 `None」。
- **验证**：consume 稳态压测 + `cjprof record`（`MQMatcher` 自耗时占比），对比改前后吞吐与 P95。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `DefaultCodec` 的编码/解码缓冲是全局池，MQ 每次编解码都要借还，高并发下池锁成为串行段 | `f_mq/src/base/MQMessageRecord.cj:41`、`:169`；`f_mq/src/base/MQProtocol.cj:246`、`:276`；池定义 `f_codec/src/default/DefaultCodec.cj:49-53`、借池超时 `:128` | 池等待时长、BLOCKED/WAITING 线程占比、池耗尽的 `getOrThrow` 触发次数 | 32 线程持续编解码 10 分钟；线程状态采样 + 池等待计时埋点（CPU profile 看不出锁等待） |
| 2 | 每条消息 3 次全量顺序解码是 consume 路径的主要 CPU 段 | `f_mq/src/base/MQMessageRecord.cj:153-158`；调用 `fmq/src/queue/MQMatcher.cj:77/100/110` | `MQMatcher` / `decodeValues` 自耗时占比 | `cjprof record` 跑服务端 consume 稳态（1 主题 1 组 10 万条 1KB 记录） |
| 3 | `publishTime` 的 9 次分配在延迟投递判定里占比可观 | `f_mq/src/base/MQMessageRecord.cj:119-134` | 自耗时占比、GC 次数 | `cjpm bench -O2` 10M 次 + 服务端 `cjprof heap` 对照 |
| 4 | `consume` 一次只取 1 条（`once: true`），订阅吞吐上限 ≈ 1/RTT | `f_mq/src/base/MQProtocol.cj:55-57`；客户端轮询 `f_mq/src/client/MQClient.cj:229-256` | 每 RTT 消息数、P95 延迟、单订阅极限 QPS | 客户端压测：1 订阅 / 1 组 / 1 owner，记录 RTT 与 QPS 曲线；再试多 owner 分摊 |
| 5 | 大 BODY 解码峰值 ≈ 2×（64MB 记录 → ≥128MB），且随并发线性叠加 | `f_mq/src/base/MQMessageRecord.cj:171`；`f_mq/src/base/payload/MQBlob.cj:106` | `heapUsed` 峰值随并发 N 的变化 | 8 并发消费 64MB 记录，采样 `getAllocatedHeapSize()` + RSS |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `src/base/MQMessageRecord.cj` | .cj | ✅ | 见发现 #1 #4 #5 #6 #7，优化 #1 #3 |
| 2 | `src/base/MQMessageRecord_test.cj` | .cj | ✅ | 覆盖 4 段往返 / 截断 / 多余字节 / 大载荷临时文件清理；未覆盖「BODY 为大字节」 |
| 3 | `src/base/MQModel_test.cj` | .cj | ✅ | `MQMessage.get` 用例齐（空/异类/标量/集合），未覆盖 `DataString`→数值与漂移对象 |
| 4 | `src/base/MQPayload_test.cj` | .cj | ✅ | 各类载荷往返齐；`MQBackupCursor` 无独立往返用例（随 `MQBackupPayload` 走默认空数组） |
| 5 | `src/base/MQProtocol.cj` | .cj | ✅ | 见发现 #2 #4 #7，优化 #2 #4 |
| 6 | `src/base/MQProtocol_test.cj` | .cj | ✅ | 命令/载荷分派与严格闸门覆盖较好；`:110-112` 是重复构造（与上一行同一调用），无额外断言价值 |
| 7 | `src/base/MQTags.cj` | .cj | ✅ | 与 README 的 64 / 1..128 字节口径一致（`String.size` = UTF-8 字节数），无问题 |
| 8 | `src/base/MQTags_test.cj` | .cj | ✅ | 边界（64/65、128/129）与 Unicode 空白覆盖齐 |
| 9 | `src/base/MQTestSetup_test.cj` | .cj | ✅ | 顶层 `let` 在包初始化期写入 `protocol_hostId`，用法正确（`MessageID` 拒绝 `hostId == 0`） |
| 10 | `src/base/MQTopic.cj` | .cj | ✅ | 见发现 #3 |
| 11 | `src/base/MQTopic_test.cj` | .cj | ✅ | 未覆盖长度边界（与发现 #3 对应） |
| 12 | `src/base/model/MQMessage.cj` | .cj | ✅ | 见发现 #1 #2 |
| 13 | `src/base/model/MQMessageContent.cj` | .cj | ✅ | `toMessage` 直接搬 `DataAny`，是发现 #1 的放大点（`body` 形态不归一化） |
| 14 | `src/base/model/MQSubscribeGroupMeta.cj` | .cj | ✅ | 纯数据（topic / group / revision / origin），无校验需求，无问题 |
| 15 | `src/base/model/MQTopicMeta.cj` | .cj | ✅ | 纯数据；`queueNum >= 1` 的不变量在服务端校验（本文件不含），无问题 |
| 16 | `src/base/payload/MQAckPayload.cj` | .cj | ✅ | 位置三元组 + `subscribedId` 齐，与「多队列不串台」的 ack 语义一致 |
| 17 | `src/base/payload/MQBackupCursor.cj` | .cj | ✅ | 无 `queueIndex` 但所在 `MQBackupPayload` 自带 queueIndex，语义自洽；`cursors` 只被服务端 `MQCommandExecutor.cj:253` 消费 |
| 18 | `src/base/payload/MQBackupPayload.cj` | .cj | ✅ | 两个构造函数只差 `records` 元素类型（`Array<Array<Byte>>` 生产用 / `Array<MQBlob>` 仅测试用），属 API 便利而非重复逻辑 |
| 19 | `src/base/payload/MQBackupState.cj` | .cj | ✅ | `acked` / `deliverCount` 由发送端填、接收端只做长度对齐检查（`fmq/src/server/MQCommandExecutor.cj:245-257`），与 `doc/spec/fix-fmq-full-audit/design.md:203-231` 的自述一致 |
| 20 | `src/base/payload/MQBlob.cj` | .cj | ✅ | 见发现 #5 #8，优化 #2；`readWholeFile` 的 `out[got..size]` 是数组切片视图（`cangjie-doc/1.3.0` `core_package_structs.html` 的 `operator func [](Range<Int64>)` 示例：改原数组后切片内容同步变化），因此读到的是 `out` 本体，**不是**拷贝写丢 |

合计：`.cj` 20 个 / `.md` 0 个 / 共 20 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 5 | 正确性：#1 #2 #4；设计：`MQMessage` 与 `MQProtocol` 两套闸门（#2）；语言特性：`match` 的 `Option` 推断残留（#5）、`convert` 默认 `SILENCE` 的语义（#2）；可读性：#7；安全性：本部分无外部输入直接拼 SQL / 路径，`MQTopic`/`MQTags` 只做字符校验（#3 是边界而非注入） |
| §1 死代码 | 2 | 逐个符号搜引用：`MQMessageRecord.valueAt` / `decodeValues`、`MQProtocol.readPayload` / `scalarTypeMatches`、`MQBlob.readWholeFile` 均有调用者；`internal`/`protected` 符号本部分为 0；`public` 均为对外可达（`f_mq` 是库，`fmq` 服务端与下游都在用），不判。命中：`MQBlob.cj:92` + `MQMessageRecord.cj:211` 不可达分支、`MQMessageRecord.cj:19-20` 未使用 import |
| §2 重复逻辑 | 2 | 已把 20 个文件的函数体压成「输入→输出→副作用」两两比对：命中 `encode` 模板（#7）与两套类型闸门（#2）。已比对并排除：`MQModel_test.cj:43-60` 与 `MQPayload_test.cj:30-47` 的同名 `roundtrip` 辅助（测试准备代码）；`MQBackupPayload` 两个构造函数（元素类型不同，无法合并）；`MQMessageRecord.topic/tags/messageId/body` 四个前缀解码器（共用 `valueAt`，仅类型参数不同，属必要展开） |
| §3 空实现 | 1 | 无空函数体、无 `TODO`/`FIXME`、无「接口默认空实现未覆盖」；`MQProtocol_test.cj:352` 的 `set(...) {}` 是测试替身的有意 no-op。命中：`MQBlob.cj:136-143` 的空 `catch`（#8） |
| §4 栈溢出 | 0 | 唯一递归是 `MQProtocol.readPayload` 对 `DataAny` 的解包（`MQProtocol.cj:165`）与 `MQBlob.tryFromData` 对 `DataAny` 的解包（`MQBlob.cj:70`）：`DataAny` 只由进程内代码构造，编解码不会产出嵌套 `DataAny`（`DefaultCodec.cj:152` 编码时即拆包），可达深度为 1；其余全为循环 |
| §5 OOM | 1 | 全量物化路径都受硬上限约束：单条记录 ≤ 64MB（`fmq/src/queue/QueueLog.cj:48`）、单帧载荷默认 1GB（`f_protocol/src/default/ProtocolConfig.cj:32`），本部分无「随请求增长且 GC 后仍在」的容器、无按报文头 `Array(n)` 预分配（`MQBlob.cj:106` 的 `size` 来自已落盘的临时文件长度，仍受上述上限约束）；命中只为 #1 的「磁盘/inode 无界增长」（同一根因，合并计一条） |
| §6.1 热点瓶颈 | 0 | 本部分未提供 `cjprof` / `cjpm bench` 数据，热点结论不成立；相关线索（`publishTime` 分配、3 次全量解码）已写进「待验证假设」#2 #3 与优化 #3 #4 |
| §6.2 大粒度锁 | 0 | 本部分代码无 `synchronized` / `Mutex` / `Atomic`，全部是无状态静态方法；唯一的共享点是外部 `DefaultCodec` 全局缓冲池，写成「待验证假设」#1（CPU profile 看不出锁等待，需线程状态证据） |
| §6.3 并发串行 | 0 | 本部分无 `spawn` / `Future.get` / 批量提交；`consume` 一次一条的串行上限属调用方设计，写成「待验证假设」#4 |
| §6.4 低效算法 | 0 | 无嵌套循环、无 `remove(at: 0)` 当队列、无循环内字符串拼接、无热点 `contains`；`publishTime` 的 9 次分配与重复解码按「线索不是证据」处理，进「待验证假设」 |
| §7 降堆内存方案 | 2 | 见优化 #1（整记录拷贝）、#2（`copyBytes` 全量副本）；两条都无基线，已标「待验证，不进 tasks」 |
| §8 降 CPU 方案 | 2 | 见优化 #3（`publishTime` 分配）、#4（前缀解码合并）；同样无基线 |
| §9 local mode 可行性 | 0 | **不可行**：`encode` 返回 `Array<Byte>`、`decode`/`decodeValues` 返回 `Array<Data>`/`MQMessageContent`（均逃逸出函数），违反「`@ local!` 不能作为返回值」；`DefaultCodec` / `f_io.ByteBuffer` 也没有 local mode 重载（需逐个核对 std/f_* 签名，本部分未提供任何峰值内存数据），三条约束同时卡住 |
| §11 现有代码的 BUG（存量） | 8 | 本轮读到的 8 条发现全部为存量（快照无基线），集中在「BODY 形态未归一化」（#1）、「两套闸门结论不一」（#2）、「主题长度无上限」（#3）与 5 条工程卫生问题（#4–#8）；本部分 13 个非测试文件的分支与空值路径逐个核过 |
| §12 并发安全与锁粒度 | 0 | 结论：无线程共享的可变状态——本部分 13 个非测试文件里没有 `static var`、没有单例字段、没有可变容器成员（`MQBlob.bytes` 是每实例私有且无 setter，`MQBlob.log` 是 `static let`）；`MQMessage` 的字段由 `@DataAssist` 生成 setter，实例按消息构造后不再跨线程共享（`MQClient` 每条消息新建）。锁粒度无可谈对象，未命中也无「锁太大」可报 |
| §14 功能完备性与 README 覆盖 | 0 | 与本部分相关的 README 段落（`README.md:106`、`:129`、`:157-174`）已逐项对照：`MQMessageRecord` 的 `topic`/`tags`/`body` 漏登记在「其他公开 API」清单里，但该问题已由第 1 部分（`f_mq.part1.md` 第 3 条）登记，本条不重复计；`MQBlob`/`MQBytes` 的临时文件说明（`README.md:129`）只承诺「记录级」形态，BODY 级的缺口归 #1 |
| 文件覆盖（§13 等） | 20/20 | 本部分清单内 20 个文件全部读完（13 个 `.cj` + 7 个 `_test.cj`）；本部分不含 `.md`，文档一致性核对以「代码侧对照 README / `doc/详细设计.md` 的具体行」的形式落在 #3 与 §14 行 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 1（与第 3 部分 #1 同源，合并后计 1 条） |
| 一般 | 2 |
| 轻微 | 5 |
| 优化方案（堆内存 / CPU） | 2 / 2 |

存量缺陷 8 条（全部为存量），是否纳入修复待用户决定。

## 总评

本部分是 MQ 的线格式与载荷定义层：`MQMessageRecord`（四段记录编解码）、`MQProtocol`（命令/响应工厂 + 载荷类型闸门）、`MQTags`/`MQTopic`（入口校验）、`model`/`payload`（纯数据 + `MQBlob` 大载荷包装）。整体质量偏上——严格类型闸门、池缓冲「先拷贝再 release」的约束、截断/多余字节/类型不符的失败语义都有注释与用例兜底，`MQMessageRecord_test` 的边界覆盖（每个截断长度、多余字节、16KB 临时文件清理）在水准之上。

真正需要排期的是两件事：

1. **BODY 形态未归一化（#1，与第 3 部分 #1 同一条）**：解码出的文件形态只在「字节字段」上被 `MQBlob` 清理，BODY 走 `decode`/`body()` 时既泄漏 `/tmp` 文件与 fd，又让客户端读不出大字节 BODY。这是唯一会拖垮宿主（inode/磁盘耗尽）的问题，属阻塞项。
2. **同一段字节两套闸门（#2）**：`MQMessage.get` 与服务端 `asPayload` 对「字符串 BODY 读成数字」「结构漂移」给出相反结论，A03/A04 的严格化只落在一侧；客户端与服务端对「同一条消息的 BODY」认知不一致，是潜在的静默错值来源。

其余为工程卫生（不可达分支、未使用 import、重复编码模板、空 catch、`decodePayload` 缺少 exact 校验）与一个边界（主题长度），可按批次清理，风险低。性能与内存方面本部分没有任何实测数据，四条优化方案与五条假设都只是下一轮补数据的清单，不构成结论。
