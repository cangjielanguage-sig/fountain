# f_codec 模块审查报告

- **审查日期**：2026-11-28
- **模块路径**：`f_codec/`（9 个 .cj + 2 个 .md，源文件合计 11 个）
- **基线**：工作区快照（`981dc3fdf`，无 diff 可比，全部问题来源记「存量」）
- **审查重点**：编解码正确性与边界、死代码、重复逻辑、空实现、存量 BUG、README 覆盖率
- **报告版本**：v1

## 发现

### [严重][存量] 负数 `Float16` / `Float32` 编码后无法解码（FLOAT 头低半字节被校验拒绝）

- **位置**：`f_codec/src/default/DefaultCodec.cj:425-454`（encode Float16/Float32/Float64）、`f_codec/src/default/DefaultCodec.cj:847-851`（decode FLOAT 校验）
- **来源**：存量（快照模式无基线，`git blame` 全量落在历史提交；FLOAT 分支自初始实现即如此）
- **判据**：review-checklist §11（语义与实现不符）/ §10 正确性
- **证据**：静态确定 —— encode 侧对负数把 `1 << 3` 或进长字段：`encode(DataType.FLOAT, value >= 0.0, value.toBits(), buffer)`（425-430/435-440），负数走到 `encode(dataType:sign:value:UInt64)` 的 `| (1 << 3)`（399-403）。以 `Float32(-1.0)` 为例：`toBits()=0xBF800000` ⇒ size=4 ⇒ head=`0x40|4|8=0x4C`，低半字节 12；decode 侧 `match (head & 0x0f) { case x where x >= 0 && x <= 8 => () case _ => throw CodecException('${toHex(head)} is illegal float head') }` 只放行 0..8，12 直接抛。
- **描述**：`Float16` 负数（bits ≥ 0x8000 ⇒ size=2 ⇒ 低半字节 10）与 `Float32` 负数（低半字节 12）**任何严格负数**都会解码失败（`-0.0` 例外：`-0.0 >= 0.0` 为真，走正数分支、bit3 不置位）。`Float64` 负数侥幸可用：其 bits 高位为 1 ⇒ size=8 ⇒ 低半字节恰为 8。即公开 API `Encoder.encode(Float16)/encode(Float32)` 承诺的能力对负数完全不成立，且这种失败发生在 decode 侧（发送端"成功"，接收端抛异常/断链）。decode 中 `let sign = (head & 0x08) == 0`（861）从未被使用，说明符号标记位根本没有被解码路径实现。
- **建议**：FLOAT 不要复用 bit3 做符号标记 —— 浮点符号已在尾数比特里。改法：新增 `encodeBits(dataType, bits, buffer)`，head 只用 3 bit 长度（1..7，0⇒8），不带符号位；同时把 decode 的校验条件改为 `x <= 8` 仍然成立并删除无用 `sign`。需补 `Float16/Float32` 正负值、`-0.0` 的往返用例。

### [严重][存量] `readBytes` 按线上长度直接分配，绕过 `SizeBoundedInput` 检查（远程可触发 TB 级分配）

- **位置**：`f_codec/src/default/DefaultCodec.cj:1114-1129`（`readBytes`），调用点 `:899`（BIGINT）、`:905`（DECIMAL2）、`:911`（DURATION2）、`:916`（DATETIME2）、`:960`（OBJECT murmur）
- **来源**：存量
- **判据**：review-checklist §5（按不可信长度预分配）、§11（错误处理缺失）
- **证据**：静态确定 —— `readBytes` 里 `s = parseInt64(head, true, bytes)` 后直接 `bytes = Array<Byte>(s, repeat: 0)`，**没有**走同文件已有的 `checkedBuffer`（766-777，该函数专门为此写了 `SizeBoundedInput.remainingBytes` 上限判定，STRING/INPUTSTREAM 分支都在用）。BIGINT/DECIMAL2/DURATION2/DATETIME2/OBJECT 五种类型全部经过 `readBytes`。
- **描述**：一条几十字节的帧（外层帧长上限只约束"可读字节数"，见 `f_protocol/src/default/Message.cj:295-299`）即可在载荷里声明 length=2^63-1，解码器立刻尝试 `Array<Byte>(2^63-1, repeat: 0)` ⇒ 立即 OOM 或 `OutOfMemory` 终止进程；`SizeBoundedInput` 明明已由 `f_protocol.FrameBodyStream` 实现（`f_protocol/src/default/Message.cj:101-110`），却在这条路径上被绕过。README 第 36-38 行的安全承诺（"按线上声明长度分配缓冲之前挡下超大长度"）因此在 5 种类型上不成立。
- **建议**：`readBytes` 内改为 `let bytes = checkedBuffer(input, s, 'bytes of ${head}')`；同时对 OBJECT 增加 `s == 16` 的显式校验（`UInt128.fromBytes` 依赖长度）。补一条"声明超大长度 + SizeBoundedInput"的负向用例。

### [严重][存量] `decodeData` 递归无深度上限，单帧可构造数十万层嵌套导致栈溢出

- **位置**：`f_codec/src/default/DefaultCodec.cj:917-938`（COLLECTION）、`:939-958`（MAP）、`:959-987`（OBJECT，`decodeData` 解字段名与字段值）
- **来源**：存量
- **判据**：review-checklist §4（无界递归 / 深度由输入决定）
- **证据**：静态确定 —— 三个分支都直接递归调用 `decodeData(input)`（935、953/954、979/984），全文件没有深度计数、没有 `HashSet` 环检测、没有迭代化；深度上界只由输入字节数决定。
- **描述**：一层嵌套只需 2 字节（`COLLECTION` head + 1 字节元素数），1 MB 载荷即可构造约 52 万层递归；按每帧几百字节栈帧估算，数万层即溢出（平台默认栈大小以官方文档为准，此处只给可达深度）。触发方只需发一条"合法长度"的帧，即造成解码线程栈溢出崩溃 —— 这是 §4 明确的"崩溃，不是慢"。
- **建议**：加 `depth` 参数（`decodeData(input, depth)`），超过常量上限（如 256/512）抛 `CodecException`；或改为显式栈迭代。上限值应与 `f_protocol` 的帧载荷上限一起写进 README「限制」。

### [严重][存量] 解码文件名直接拼进路径（路径穿越写入任意文件）

- **位置**：`f_codec/src/default/DefaultCodec.cj:1021-1029`（小载荷分支）、`:1058-1071`（大载荷分支）
- **来源**：存量
- **判据**：review-checklist §10 安全性（外部输入未校验）、§11（契约与实现不符：文件名应只是名字）
- **证据**：静态确定 —— `let fileName = String.unsafeUtf8(bytes)`（1021/1066）直接来自报文；随后 `File.create('${dir}/${fileName}')`（1026）与 `rename(srcPath, to: Path('${dir}/${fileName}'))`（1070）没有任何 basename / `..` / 绝对路径校验。
- **描述**：对端在 `f != 0` 的 INPUTSTREAM 载荷里写 `../../../../home/<user>/.ssh/authorized_keys`（或任意可写路径）即可让**解码进程**以自身权限写/覆盖文件。`dir` 只是 `/tmp/tmpFile<UUID>`，不能阻止 `..` 逃逸；`unsafeUtf8` 还不校验 UTF-8 合法性，非法字节序列会让文件名进入未定义状态（具体行为待确认）。这是一条从网络报文直达文件系统的写通道。
- **建议**：`fileName` 只取 `Path(fileName).fileName`，并显式拒绝空串、`.`、`..`、含 `/` 与 `\` 的输入；写文件前校验最终绝对路径前缀仍是 `dir`。`String.unsafeUtf8` 换成带校验的 UTF-8 构造。补负向用例（`../x`、绝对路径）。

### [一般][存量] 0 字节 File 解码时提前返回，文件名留在流里导致后续字段错位

- **位置**：`f_codec/src/default/DefaultCodec.cj:1000-1003`；文件名读取在 `:1058-1071`
- **来源**：存量
- **判据**：review-checklist §11（边界/错误处理）、§10 正确性
- **证据**：静态确定 —— `if (size <= fileThreshold) { if (size == 0) { return (Array<Byte>()).toData() } ... }` 在判断 `f`（是否带文件名）之前就返回；而 encode 侧 `encode(data: File)`（561-570）即使文件为 0 字节也会写 head+`len=0`+文件名。
- **描述**：编码一个空文件后解码，返回的是"空 `Array<Byte>`"而不是 `File`，且**文件名字节仍留在输入流中**：下一字段会把文件名的长度前缀当 head 解析，通常抛 `Illegal serialization header`（`decodeData:787-788`），整帧后续字段全部失效。空文件是合法输入（日志轮转、空附件），不是理论边界。
- **建议**：`size == 0` 的短路只在 `f == 0` 时生效；`f != 0` 时继续读文件名并返回 0 字节文件。

### [一般][存量] 大载荷落盘的临时文件从不删除，长期运行磁盘无界增长

- **位置**：`f_codec/src/default/DefaultCodec.cj:1022`、`:1032-1036`（`/tmp/tmpFile<UUID>` 目录与 `File.createTemp`）
- **来源**：存量
- **判据**：review-checklist §5（无界增长）/ §7（资源释放不对称）
- **证据**：静态确定 —— 全仓搜索 `tmpFile` 只有上述两处创建点；`f_codec` 与 `f_protocol` 内没有任何 `remove` / 删除调用（`grep -rn "remove(\|delete()" f_codec f_protocol` 无命中）。返回的 `DataInputStream`/`File` 关闭时也没有注册清理回调。
- **描述**：每收到一条超过 `fileThreshold`（默认 4096）的载荷就留下一个临时文件与一个 UUID 目录，永不回收。RPC 长跑服务的磁盘占用随入站大载荷条数线性增长，最终写满 `/tmp`（随后 `File.create` 失败，decode 整体不可用）。
- **建议**：二选一并写进 README：① 解码方在 `DataInputStream` 关闭/释放时删除文件（需要 f_data 侧支持生命周期回调）；② 提供显式清理入口（如 `DefaultCodec.cleanupTempFiles(olderThan:)`）并由 `f_protocol`/`f_rpc` 的定时任务调用。至少要给出"落盘文件不会自动删除"的限制说明。

### [一般][存量] FLOAT 子类型靠"字节长度"推断，denormal 被解成更窄类型（数值错误）

- **位置**：`f_codec/src/default/DefaultCodec.cj:852-895`（decode 按 `s` 选 `Float16/Float32/Float64`），对照 `:376-407`（encode 按 bits 幅值取最短字节数）
- **来源**：存量
- **判据**：review-checklist §11（数据错误）/ §10 正确性
- **证据**：静态确定 —— 编码只写"bits 的最短大端字节"，解码用长度反推类型：`case 1|2 => Float16.fromBits`、`case 3|4 => Float32.fromBits`、`case 5..8 => Float64.fromBits`。`Float64(5e-324)` 的 bits=1 ⇒ 1 字节 ⇒ 被解成 `Float16.fromBits(1)=5.96e-8`；`Float32` 的次正规数 bits<0x10000 同样被解成 `Float16`。
- **描述**：任何 `Float64`/`Float32` 次正规数（|x| 分别小于约 1e-315 / 1e-40 的窄带）会被静默替换成完全不同的数值，而不是报错。类别信息在协议层丢失（FLOAT 只有一个类型号），精度靠"最长字节数"兜底，对 denormal 不成立。
- **建议**：FLOAT 至少拆成 `FLOAT1/FLOAT2`（或用 head 1 bit 标宽度）来携带"16/32/64 位"；若要保持单类型号，则编码侧固定写 8 字节并让解码只走 `Float64`（放弃紧凑编码换正确性）。补 denormal 用例（`Float64.Min` 级、`Float32` 次正规）。

### [一般][存量] 长度前缀 + head 编码有 5 份实现，且 `sign` 语义已经漂移

- **位置**：`f_codec/src/default/DefaultCodec.cj:298-317`（UInt16）、`:335-358`（UInt32）、`:376-407`（UInt64）、`:571-605`（`writeSizeOfValue`）、`:606-643`（`encodeSizeOfValue`）
- **来源**：存量
- **判据**：review-checklist §2（只改类型名 / 换写入方式，语义相同）
- **证据**：静态确定 —— 五处都是同一套「按值域取 1..7 字节、0⇒8、head=`type|UInt8(size)|signBit`、大端写字节」；差异仅是写入介质（`Array<Byte>` 构造 vs `writeByte`+`writeUInt64BE`）与整数宽度。语义已经漂移：`encodeBigInt2`（455-463）算出 `let sign = value >= ZERO_BIGINT` 传给 `encodeSizeOfValue(..., forInt: false)`，但后者 `if (!forInt || sign)` 在 `forInt == false` 时恒取 true，**sign 被静默丢弃**；`encode(value: Decimal)`（486）同样算了 `let sign = value >= ZERO_DECIMAL` 后从未使用。`encodeBytes`（464-470）与 `encodeBigInt2` 已经只差这个无效参数。
- **描述**：五份实现里三份构造临时 `Array<Byte>` 再 `write`（多一次分配 + 一次拷贝），两份走 `writeByte/writeUInt64BE`；"符号位只对 INT 生效"这条语义没有任何一处集中表达，读代码的人会以为 BIGINT/DECIMAL 也写了符号位（实际靠 `BigInt.toBytes()` 的补码，见 std 文档 `math_numeric_package_structs.md` `func toBytes()`）。修一处漏四处是可预期的。
- **建议**：只保留 `writeSizeOfValue` 一个实现（其余改成调用它或删掉），符号位改为显式参数名 `signInHead`；`encodeBigInt2` 去掉 `sign` 参数，`encodeBytes` 直接复用它。补字节级 golden 用例锁定 wire 格式。

### [一般][存量] README 对 head 低 4 位的描述与实现不符（6 类类型被混入同一行）

- **位置**：`f_codec/README.md:69-70`（及 `README_en.md:71-72`）；实现 `f_codec/src/default/DefaultCodec.cj:571-605`、`:1114-1121`
- **来源**：存量
- **判据**：review-checklist §13（文档与代码不一致）
- **证据**：静态确定 —— README 写 `STRING / COLLECTION / MAP` "长度字节数，**编码侧恒写 8（不写 0）**"，但 `encode(value: String)` 调 `writeSizeOfValue(STRING, true, ss, false, buffer)`，`forInt=false` 时 s 取自"值域阶梯"（1..7，或 8）⇒ `'hello'` 实际 head=`0x11`、宽度 1，不是 8。同一行还把 `BIGINT / DECIMAL* / DURATION* / DATETIME*` 与 INT 并列为"长度字节数（1..7）；0 表示 8 字节"，而这 6 类的低半字节是**长度前缀自身的字节宽度**（1..8，永不写 0，见 `encodeSizeOfValue` 的 `forInt: false` 分支与 `readBytes` 的 `head & 0x0f`）。
- **描述**：照 README 实现第二语言解码器的下游会恒按 8 字节宽度读字符串长度、并给 BIGINT 等类型套"0⇒8"，两边都不通。附带一个健壮性缺口：这 6 类的 head 低半字节若为 0（损坏输入），`readBytes` 会读 0 字节长度前缀后进入 `parseInt64` 的 `else` 分支索引空数组 ⇒ `IndexOutOfBoundsException`（不是 `CodecException`），低半字节 9..15 则只取前 8 字节静默误解。
- **建议**：把表拆成三行：① INT/FLOAT/INPUTSTREAM = 负载字节数（1..7，0⇒8）；② BIGINT/DECIMAL2/DURATION2/DATETIME2/OBJECT = 长度前缀宽度（1..8，不写 0）；③ STRING/COLLECTION/MAP = 长度前缀宽度（1..8，0 表示空值）。`readBytes` 增加 `s == 0 || s > 8` 抛 `CodecException`。

### [一般][存量] README 用法示例把 `release()` 放在写出之前，照抄会抛 `IllegalStateException`

- **位置**：`f_codec/README.md:124-129`（`README_en.md:127-132` 同）
- **来源**：存量
- **判据**：review-checklist §13（示例代码不能用）
- **证据**：静态确定 —— 示例是 `let bytes = codec....finish()` 后紧跟 `codec.release()`；`release()`（720-726）会对每个 `inputs` 元素调 `Releasable.release()`，`BytesListOutputStream.release()` 置 `released=true` 并归还池项（`f_pool/src/BytesListOutputStream.cj:211-219`），其 `copy`/`asBytes` 先 `checkNotReleased()` 抛 `IllegalStateException('bytes output stream is released')`（同文件 106-110、220-224）。
- **描述**：`bytes` 是 `ChainedBytesCopyTo`，只有 `copy(to:)` 时才真正写出并各自 `release()`；在 `codec.release()` 之后再写 `bytes` 必然抛异常。示例没有示范写出动作，读者很容易先 release 再 copy，得到一个"编码成功、写出崩"的路径。
- **建议**：示例改为 `finish()` → `copy(to: out)` → 需要时 `codec.release()`（注明"只解码/丢弃时才提前 release"），并补一句"`release()` 之后不得再 encode/finish"。

### [一般][存量] `encode(data: Data)` 未覆盖 `DataUnit` / `DataIterable`，落到 "Unsupported type"

- **位置**：`f_codec/src/default/DefaultCodec.cj:150-229`（分派），兜底 `:223-227`
- **来源**：存量
- **判据**：review-checklist §14.1（功能完备性：只做了一半的分支）；§11（契约与实现不符：`Data` 家族分派不完整）
- **证据**：静态确定 —— `f_data` 的 `Data` 实现共 12 个（`DataAny/DataBool/DataDateTime/DataDict/DataDuration/DataInputStream/DataList/DataNone/DataReal/DataString/DataTuples/DataUnit`，另有 `DataIterable`），`encode(data: Data)` 覆盖了除 `DataUnit`、`DataIterable` 外的全部；`Unit.toData()` 返回 `DataUnit.UNIT`（`f_data/src/base/DataUnit.cj:50-53`），是公开且常用的返回值。`DataUnit` 在 `f_mvc`/`f_rpc` 的响应路径存在（`f_mvc/src/RequestMeta.cj:322`、`f_rpc/src/base/LogMessage.cj:22`）。
- **描述**：把 `().toData()` 或 `DataUnit.UNIT` 交给 `encode` 会抛 `CodecException('Unsupported type')`。RPC 方法返回 `Unit` 时是否真的把 `DataUnit` 送进 codec，取决于 `f_rpc` 是否把 Unit 归一成 `DataNone`（本模块内无法判定，记待确认）；但**"Data 家族不完整覆盖"本身是模块内可判定的契约缺口**，README 也没有声明这个限制。
- **建议**：`DataUnit` 按 `DataNone` 处理（写 `NONE` head，解码得到 `DataNone`，`Unit.tryFromData` 已接受 `DataNone`，见 `DataUnit.cj:58`）；`DataIterable` 要么物化成 `DataList` 再编码，要么显式抛带类型名的 `CodecException`。补用例。

### [一般][存量] README 缺「限制与注意事项」，`CodecException` 与 `init()` 无文档

- **位置**：`f_codec/README.md:82-113`（默认实现段）、`:141-146`（相关文档段）
- **来源**：存量
- **判据**：review-checklist §14.2（缺关键段落 / 公开 API 未文档化）
- **证据**：静态确定 —— 以 `src/` 公开声明为基准对照：`public class CodecException`（`src/exception/CodecException.cj:20-32`，含 4 个 init）在 README 中只作为"抛 CodecException"出现，没有错误处理章节；`DefaultCodec` 的 `public init()`（58-60）未列进 README 的类签名块（只写了 `init(headroom!: Int64)`）。README 也没有任何段落说明：① 解码大载荷会在 `/tmp` 落盘且不自动删除；② `DefaultCodec` 实例有可变状态（`inputs`/`size`），不可跨线程共享；③ 一个实例只服务一帧（`release()` 后不可再用）；④ 解码递归深度无上限。
- **描述**：使用者按 README 接入，会在临时文件堆积、实例复用、异常类型捕获（`BaseException` 子类）三处踩坑；`CodecException` 属于对外契约（下游要 `catch`），却只能从源码猜。
- **建议**：增加「限制与注意事项」与「错误处理」两节：错误类型清单（`CodecException` / `UnreachableException` 不应外泄）、临时文件生命周期、实例线程模型、深度/长度上限、`release()` 时序。把 `init()` 补进类签名块。

### [轻微][存量] `DefaultCodec.size` 字段只写不读

- **位置**：`f_codec/src/default/DefaultCodec.cj:54`，写点 `:239/251/261/263/265/283/292/315/356/405/461/468/501/547/558/568`，另有 `:1104/1117/1124` 把 `input.read(...)` 写回该字段
- **来源**：存量
- **判据**：review-checklist §1（读了不用 / 兼容残留）
- **证据**：静态确定 —— 全文件检索：`size` 只有 `size++`、`size += …`、`this.size += …`、`size = input.read(...)`，没有任何读取表达式；`finish()` 用的是 `ChainedBytesCopyTo(inputs...)`，字节数由子项 `byteSize()` 汇总，字段已无用途。`decodeData` 内 `var size = input.read(bytes)`（781）还遮蔽了它。
- **描述**：字段被当作"已编码字节数"累加，但从不被读，且累加本身不完整（空集合/空映射/Object 字段头都没计）。这是重构后未清理的死状态，会误导后续维护者以为它是可信的长度来源。
- **建议**：删除字段与全部累加；需要总字节数时用 `ChainedBytesCopyTo.byteSize()`。同时消除 `decodeData` 里同名局部变量的遮蔽。

### [轻微][存量] 未使用的 import

- **位置**：`f_codec/src/default/imports.cj:18`（`Map`、`TreeMap`）、`f_codec/src/imports.cj:21`（`fountain::f_base.*`）
- **来源**：存量
- **判据**：review-checklist §1（未使用的 import）
- **证据**：静态确定 —— `grep -rn "TreeMap|\bMap\b" f_codec/src` 只命中 import 行本身；根包只有 `src/Codec.cj`，其中使用的 `BytesCopyTo` 来自 `f_pool`（`f_pool/src/BytesCopier.cj:20`）、`Data*` 来自 `f_data`、`File/InputStream` 来自 std，未引用 `f_base` 的任何符号。
- **描述**：`internal import` 会传递进本包所有文件，多余项遮蔽同名符号并增加编译依赖面。
- **建议**：删掉 `Map`、`TreeMap` 与 `f_base.*`；`SeekPosition` 若仍被 `Begin(0)` 依赖则保留。

### [轻微][存量] 注释掉的整段测试与残留注释

- **位置**：`f_codec/src/default/DefaultCodec_test.cj:388-424`（整段 `testFile` 被注释）、`f_codec/src/default/DefaultCodec.cj:779`（`// decodeSizeOfEncoded(input)`）
- **来源**：存量
- **判据**：review-checklist §1（死代码）/ §3（半成品）
- **证据**：静态确定 —— 38 行注释代码块无 `@TestCase`，不会被编译；779 行注释紧跟在 `decodeData` 的读 head 之后，功能已被 781-789 的内联实现取代。
- **描述**：`File` 编解码（尤其上一条"0 字节文件"缺陷所在的路径）完全没有用例，而 README 声称支持 `File`；注释块还容易被误认为"已禁用的历史用例"。
- **建议**：要么按新签名修好 `testFile`（含 0 字节、`fileThreshold` 上下、文件名非法字符），要么删除注释块；删掉 779 行注释。

### [轻微][存量] 大端字节→整数装配有 3 份实现

- **位置**：`f_codec/src/default/DefaultCodec.cj:675-712`（`decodeSizeOfEncoded`）、`:728-760`（`parseInt64`）、`:827-841`（`decodeData` 的 INT 分支）
- **来源**：存量
- **判据**：review-checklist §2（换控制流/只改类型名）
- **证据**：静态确定 —— 三处都是 1..8 分支的 `Int64(bytes[0]) << (8*(n-1)) | …` 位移拼装；差异是返回值宽度（Int64 / UInt64）、头部半字节取法（`>>4` vs `&0x0f` vs `&0x07`）与符号检查。
- **描述**：三份手工展开的 8 分支极易改一处漏两处（例如新增 9 字节宽度时）；其中 INT 分支用 UInt64 是为了容纳 ≥2^63 的 `UInt64`，这个差异没有任何注释说明。
- **建议**：抽一个 `readUIntBE(bytes): UInt64` + 宽度/符号校验，三处调用；`parseInt64` 变成"装配 + 符号"的薄封装。

### [轻微][存量] `readDuration1` / `readDuration2` 仅差一行

- **位置**：`f_codec/src/default/DefaultCodec.cj:1086-1091`、`:1092-1097`
- **来源**：存量
- **判据**：review-checklist §2（只改类型名）
- **证据**：静态确定 —— 两函数逐行一致，唯一差异是 `readBigInt1(head, input)` 与 `readBigInt2(head, input)`；随后 `seconds/nanos` 拆分与 `Duration` 组合同字。
- **建议**：合并为 `readDuration(value: BigInt)`，两个入口只负责取 `BigInt`；DATETIME 分支同理可复用。

### [轻微][存量] `DataType` 的 16 分支表写了 3 遍

- **位置**：`f_codec/src/default/DataType.cj:57-76`（`toString`）、`:77-98`（`value`）、`:104-124`（`convert`）
- **来源**：存量
- **判据**：review-checklist §2（字面量复制）
- **证据**：静态确定 —— 三处各 16 个 case，`value` 与 `convert` 是同一张映射的正反两写；另有 20 行类型表注释在 `Codec.cj:18-38`、`DataType.cj:18-38`、`DefaultCodec.cj:18-38` 三份完全相同。
- **描述**：新增/调整类型号时要同步 3 处代码 + 3 处注释 + README 1 处，漂移概率高。
- **建议**：让 `value` 成为唯一真源（`match (this)`），`convert` 用 `value` 反查（或按 `byte & 0xf0` 匹配），`toString` 保留但由枚举名派生；注释表只放在 `Codec.cj`（对外契约）并由其余文件引用。

### [轻微][存量] `DataType.lowValue` 名不副实，`convert(byte)` 只接受低半字节为 0 的 head

- **位置**：`f_codec/src/default/DataType.cj:99-103`（`lowValue = value >> 4`）、`:104-124`（`convert`）
- **来源**：存量
- **判据**：review-checklist §10（语义与命名不符）
- **证据**：静态确定 —— `lowValue` 返回的是**高** 4 位（类型号），与"low"相反；`convert` 只匹配 `0x00/0x10/…/0xf0`，任何真实 head（如 `0x11`、`0x4a`）都抛 `CodecException`。全仓引用只有 `docs/fountain实现思想与应用…第10弹` 一处说明文字，无代码调用。
- **描述**：两个都是对外可达的 public 声明（不判死代码），但名字/契约会让使用者误用：`convert` 看起来能"把 head 转成类型"，实际只接受低半字节清零的形态。README 只列签名，未说明这个约束。
- **建议**：`lowValue` 改名 `typeValue`/`ordinal`（破坏性变更，需用户拍板）；`convert` 改为 `match (byte & 0xf0)` 并对未知高位抛错，README 注明"接受任意 head"。

### [轻微][存量] 全局可变配置无同步，`pulledTypeCount` 读改写非原子

- **位置**：`f_codec/src/default/DefaultCodec.cj:49-53`（`byteListOutputBuilder` / `fileThreshold` / `bytesPool`）、`:65-84`（三个 setter）、`:98`+`:103-111`（`pulledTypeCount`）
- **来源**：存量
- **判据**：review-checklist §12.1（共享可变状态无保护、检查-然后-写入）
- **证据**：静态确定 —— 三个静态 `var` 由 `setBufferPool/setBytesPool` 直接赋值，编解码线程无同步读取；`setBytesPool` 还分两步写 `bytesPool` 与 `fileThreshold`，并发下可观察到"新池 + 旧阈值"。`pullRegisteredTypes` 的 `if (total == pulledTypeCount) return` 后 `pulledTypeCount = total` 是典型读改写，多线程首次解码同一新类型会重复遍历注册表。
- **描述**：现实约束是"配置只在启动期、任何请求之前做一次"（`f_rpc` 首次 `start()` 时配置，见 `f_rpc/src/base/PoolConfig.cj:86-96`），因此当前影响低；但这条约束只写在注释和 f_rpc README 里，`f_codec` 侧没有保护也没有断言。`pulledTypeCount` 的重复拉取是幂等的（`addIfAbsent`），只会浪费一次遍历。
- **建议**：把配置收进一个不可变 snapshot 结构，用单个 `var` 原子替换（一次赋值同时覆盖 pool 与阈值），并在 README 写明"必须在任何编解码调用前完成"；`pulledTypeCount` 改成 `Atomic` 或用 `typeMurmurCreators.size` 做保守判断。

### [轻微][存量] 不支持类型的分支自抛自捕，丢失具体类型信息

- **位置**：`f_codec/src/default/DefaultCodec.cj:223-227`
- **来源**：存量
- **判据**：review-checklist §10（可读性 / 异常控制流）
- **证据**：静态确定 —— `case x => try { throw CodecException("Unsupported type: ${TypeInfo.of(x)}") } catch (e: Exception) { throw CodecException('Unsupported type', e) }`：`try` 块内只有自己的 `throw`，catch 立刻重抛并丢掉外层消息里的类型名（下沉到 `cause`）。
- **描述**：异常类型/消息对定位帮助不大（`CodecException('Unsupported type')`），排查时必须展开 `cause`；同时这种写法暗示"这里可能在捕获别人的异常"，误导读者。
- **建议**：直接 `throw CodecException('Unsupported type: ${TypeInfo.of(x)}')`，不要在分支里做 try/catch。

### [轻微][存量] README 引用的 bug 档相对路径失效

- **位置**：`f_codec/README.md:77`、`f_codec/README_en.md:80`
- **来源**：存量
- **判据**：review-checklist §13（链接/路径失效）
- **证据**：静态确定 —— 链接写作 `.autocode/bugs/bug-archived-20261004-2.md`，从 `f_codec/README.md` 出发解析为 `f_codec/.autocode/...`（不存在）；实际文件在仓库根 `.autocode/bugs/`（`ls` 已确认），需写成 `../.autocode/bugs/...`。
- **建议**：改为 `../.autocode/bugs/...`，或直接把关键结论抄进 README（外部读者拿不到 `.autocode`）。

### [轻微][存量] 测试覆盖缺口：File/InputStream、Float16/Float32、SizeBoundedInput、损坏长度

- **位置**：`f_codec/src/default/DefaultCodec_test.cj`（整体）、`f_codec/src/default/release_test.cj:36-54`
- **来源**：存量
- **判据**：review-checklist §14.1（半成品）+ §10 可测试性
- **证据**：静态确定 —— 现有 `@TestCase` 覆盖 Bool/Int64/BigInt/Float64/Decimal/String/Duration/DateTime/Array/List/Map/Object/空集合；**没有** `Float16`、`Float32`、`File`（`testFile` 全部注释）、`InputStream+size`、`SizeBoundedInput`、超大/负数长度、空文件、路径穿越文件名。`release_test` 用 `sleep(200ms)` 等待池稳定并断言恰好 4 个槽位（41-45），对时序与 builder 的 `localCacheSize`（`f_pool/src/BytesListOutputStream.cj:260-266`：`maxSize < 64` 时强制为 0）有隐含依赖。
- **描述**：本报告 4 条严重缺陷全部落在无测试的区域（浮点负数、readBytes 长度、递归深度、文件名）。`release_test` 的 200ms 等待在慢机上可能 flaky。
- **建议**：按缺陷逐条补负向用例（见各条建议）；`release_test` 改成轮询直至稳定（带上限）而不是固定 sleep。

## 优化可行性方案

> 不是缺陷，是"还能更好"。**本模块没有任何改前/改后测量数据**，以下全部为 `无基线（待验证）`，不进 `tasks.md`。

### [堆内存] 解码侧的标量读取改为复用缓冲，去掉逐值小数组

- **现状**：`decodeData` 每读一个值就先分配 `Array<Byte>(1)`（780），每个长度前缀再分配 `Array<Byte>(s)`（797/821/856/928/946/994），`decodeSizeOfEncoded` 每次分配 ≤8 字节数组（685），`parseInt64`/`readBytes` 各自再分配。一条含 N 个字段的对象解码会产生 O(N) 次 1-8 字节的小数组分配，全部立即死亡。
- **方案**：`InputStream` 若有 `readByte()` 则直接读单字节；长度前缀用类内复用的 8 字节 `VArray<Byte>` 或栈缓冲；`decodeData` 的 `bytes` 变量改为可复用的固定 8 字节缓冲（注意 STRING/INPUTSTREAM 的 payload 仍需独立数组，不能复用）。
- **预期**：每字段减少 1-2 次分配与一次 GC 记账；具体降幅需测量（无法给百分比）。`docs/LocalMode.md:438` 已有同向定性结论（"`decodeSizeOfEncoded` 每次分配 ≤8 字节小数组…应改复用 `VArray`/直接读字节"），但同样没有基线数字。
- **代价**：`readByte` 的 EOF 语义（0/-1）要与现有 `read` 判定保持一致；payload 与缓冲必须严格区分，否则会引入内容串写。
- **验证**：`cjprof heap` 分配量与 `getAllocatedHeapSize()` 对照；输入 10 万帧、每帧 32 字段对象，`-O2`，取中位数与离散度。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 把 5 份长度/head 编码合并为单一路径，去掉临时数组

- **现状**：`encodeSizeOfValue`（606-643）每次先构造 `Array<Byte>(ss+1)` 再 `buffer.write(...)`（一次分配 + 一次拷贝）；`encode(dataType:sign:value:UInt16/UInt32/UInt64)`（298-317/335-358/376-407）各写一份阶梯 + 数组。`writeSizeOfValue`（571-605）已经是零临时数组版本（`writeByte` + `writeUInt64BE`），但只有 String 在用。
- **方案**：全部编码入口改走 `writeSizeOfValue`；`encodeSizeOfValue` 仅在需要"先算再写"的调用点（COLLECTION/MAP/OBJECT 的 head 与元素数）保留，并改为两次标量写。
- **预期**：每个标量少 1 次临时数组分配与 1 次 memcpy；编码端到端收益需测量（占比未知，可能低于 5% 噪声）。
- **代价**：改动面覆盖全部 `encode` 重载，必须用字节级 golden 用例锁死 wire 格式（现有测试只验证往返，不验证字节序列，往返一致不代表线上兼容）。
- **验证**：`cjpm bench -O2` 编码 100 万个小帧（4 个 ID + 1 个短 String），改前/改后同机同输入，中位数 + 离散度；并用 `f_protocol` 的 `FrameEncodeBench_test` 交叉验证。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [local mode] 本模块不适合 local mode 改造（结论：不可行）

- `decodeData` 产出的 `Data` 对象全部逃逸到调用方（返回值、集合元素、对象字段），`decode<T>` 又是泛型入口（`docs/LocalMode.md:275/985` 明确"泛型入口不可 local"）。
- 唯一候选是 `decodeSizeOfEncoded`/`parseInt64` 的 ≤8 字节临时数组，但 `docs/LocalMode.md:438/983` 已判定这类小对象 local 化"通常更慢"（local region 有固定头开销与记账成本），且需要 `--experimental --enable-local-mode` 全依赖同 SDK 编译、`cjLocalRegionMaxSize` 新 OOM 面。
- 没有峰值内存基线，收益无法证明 ⇒ 不建议做；若只为降分配，走上面的"复用缓冲"而不是 local mode。

## 待验证假设

> 没有性能测试数据支撑，不进 `todo.md` / `tasks.md`。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 解码标量的小数组分配是 GC 压力主因 | `f_codec/src/default/DefaultCodec.cj:780/797/821/856/928/946/994` | 每秒分配次数、GC 次数与停顿 | `cjprof heap` + 10 万帧回放（每帧 32 字段对象），记录 `getAllocatedHeapSize()` 与 RSS |
| 2 | 5 份长度/head 编码路径的临时数组影响编码吞吐 | `DefaultCodec.cj:298-317/335-358/376-407/606-643` | 编码函数自耗时占比 | `cjprof record` 编码 100 万小帧（`-O2`），看 `encode*` self time 与分配量 |
| 3 | `decode` 路径的 `Array<Byte>` payload 拷贝（STRING/INPUTSTREAM）在 4KB-64KB 载荷上占端到端大头 | `DefaultCodec.cj:797-808/1005-1010` | 分段耗时（读 head / 读 payload / 构造 String 或 File） | 在 3 个位置插计时，跑 1KB/8KB/64KB 三档各 1 万次 |
| 4 | 大载荷落盘（`File.create` + `write` + `rename`）比内存路径慢一个量级 | `DefaultCodec.cj:1032-1073` | 落盘单次耗时与占比 | 对 4KB/64KB/1MB 各 1000 次解码计时，对比 `fileThreshold` 调大后的同输入 |
| 5 | 池借用/归还是编码路径的隐性串行点 | `DefaultCodec.cj:124-149` + `f_pool` 池实现 | 线程状态（BLOCKED/WAITING）与锁等待时长 | 8 线程并发编码压测，采线程状态采样；CPU profile 看不到锁竞争 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_codec/README.md` | .md | ✅ | 与实现不一致：低 4 位表、`release()` 示例顺序、缺「限制与注意事项」、bug 档相对链接失效 |
| 2 | `f_codec/README_en.md` | .md | ✅ | 与 README 同步（含同样四处问题）；无独立差异 |
| 3 | `f_codec/src/Codec.cj` | .cj | ✅ | 接口契约完整（Encoder/Decoder/SizeBoundedInput/Codec），含类型表注释 |
| 4 | `f_codec/src/default/DataType.cj` | .cj | ✅ | 16 分支表写 3 遍；`lowValue`/`convert` 语义与命名不符 |
| 5 | `f_codec/src/default/DefaultCodec.cj` | .cj | ✅ | 主实现 1130 行；4 条严重、5 条一般、5 条轻微集中在此 |
| 6 | `f_codec/src/default/DefaultCodec_test.cj` | .cj | ✅ | 覆盖缺口：Float16/32、File/InputStream、损坏长度；`testFile` 整段注释 |
| 7 | `f_codec/src/default/TestObject_test.cj` | .cj | ✅ | `@DataAssist` 测试对象，被 `testObject` 使用 |
| 8 | `f_codec/src/default/imports.cj` | .cj | ✅ | 含未使用 `Map`/`TreeMap` |
| 9 | `f_codec/src/default/release_test.cj` | .cj | ✅ | release 归还/幂等用例；固定 sleep 与时序耦合 |
| 10 | `f_codec/src/exception/CodecException.cj` | .cj | ✅ | 4 个 init 委托 `BaseException`，无空实现问题；README 未文档化 |
| 11 | `f_codec/src/imports.cj` | .cj | ✅ | `f_base.*` 未被根包使用 |

合计：`.cj` 9 个 / `.md` 2 个 / 共 11 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 4 | 正确性 2（FLOAT 负数、denormal 误判）、边界 1（0 字节 File）、安全性 1（文件名路径穿越）；分层与依赖方向无问题（纯编解码模块，未反向依赖上层） |
| §1 死代码 | 3 | `size` 字段只写不读、未使用 import（`Map`/`TreeMap`/`f_base.*`）、注释掉的 `testFile` 与残留注释。已逐个 `private`/`internal` 符号全仓搜引用：`lastBuffer/getBuf/encodeBigInt2/encodeBytes/writeSizeOfValue/encodeSizeOfValue/encodeSizeOfEncoded/decodeSizeOfEncoded/parseInt64/checkedBuffer/readDuration1/2/readBigInt1/2/readBytes/pullRegisteredTypes` 均有调用者；`codecReleaseTestAvail` 只被同包测试引用，按"可见性建议"处理（非死代码）；`public` 顶层声明（Encoder/Decoder/Codec/SizeBoundedInput/DataType/DefaultCodec/CodecException）对外可达，不判死代码，`lowValue`/`convert`/`setBufferPool` 仓内零引用仅作信息记录 |
| §2 重复逻辑 | 4 | 长度前缀+head 编码 5 份（一般）、大端装配 3 份、`readDuration1/2`、`DataType` 16 分支×3。已两两比对全部 encode/decode 函数体摘要，另比对重复的 20 行类型表注释 3 处 |
| §3 空实现 | 0 | 无空函数体、无 `TODO/FIXME`（`grep` 无命中）、无 `catch {}` 吞异常、无默认空实现未覆盖。`CodecException.init(){}` 是委托父类的正常空构造；`encode` 未覆盖 `DataUnit` 属功能缺口，计入 §14 而非本节 |
| §4 栈溢出 | 1 | `decodeData` 三段递归无深度上限（严重） |
| §5 OOM | 2 | `readBytes` 按线上长度无界分配（严重）；落盘临时文件永久累积（一般，磁盘面无界增长） |
| §6.1 热点瓶颈 | 0 | 未提供任何 profile/bench 数据（`docs/LocalMode.md` 只有定性分析），热点未成立，已全部转入「待验证假设」1-5 |
| §6.2 大粒度锁 | 0 | 模块内无 `synchronized`/`Mutex`；锁只在 `f_pool` 池内部（范围外），`lastBuffer` 的取池动作不在本模块锁内，未构成锁热点 |
| §6.3 并发串行 | 0 | 无 `spawn`、无 `Future`、无批量任务提交；`inputs` 是单帧顺序链，不是并发结构 |
| §6.4 低效算法 | 0 | 无嵌套循环匹配、无 `contains` 热点、无 `remove(at:0)` 队列；`for (_ in 0..size)` 为线性解码，复杂度与输入字节数同阶 |
| §7 降堆内存方案 | 1 | 标量读取复用缓冲（无基线，待验证）；另 §5 的临时文件问题同时是释放不对称缺陷 |
| §8 降 CPU 方案 | 1 | 合并 5 份长度编码、去临时数组（无基线，待验证） |
| §9 local mode 可行性 | 0 | 不可行：`Data` 结果逃逸、`decode<T>` 是泛型入口、小对象 local 化更慢（`docs/LocalMode.md:438/983/985`），且无峰值内存基线 |
| §11 现有代码的 BUG（存量） | 23 | 本报告全部 23 条均为存量（快照模式无 diff 可比）；已核对 INT/UInt/Int8/Float/Decimal/Duration/DateTime/BigInt/String/集合/Map/Object/InputStream 各分支的边界、符号、空值、截断与错误路径 |
| §12 并发安全与锁粒度 | 1 | 静态配置三件套无同步 + `pulledTypeCount` 读改写非原子（轻微，启动期约定缓解）；`DefaultCodec` 实例状态未声明线程模型（并入 §14 文档缺失）。锁粒度：本模块无锁，无细分空间 |
| §14 功能完备性与 README 覆盖 | 3 | `encode` 未覆盖 `DataUnit`/`DataIterable`（一般）、README 缺限制与错误处理段 + `CodecException`/`init()` 未文档化（一般）、测试覆盖缺口（轻微）。public 声明逐个对照 README：仅上述遗漏 |
| 文件覆盖（§13 等） | 11/11 | 无缺失文件；两个 `.md` 逐节对照实现与示例 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 4 |
| 一般 | 8 |
| 轻微 | 11 |
| 优化方案（堆内存 / CPU） | 1 / 1 |

存量缺陷共 23 条（本轮无 diff，全部为存量），是否纳入修复、以及 `lowValue` 改名这类破坏性变更是否执行，待用户决定。

## 总评

编解码主干（INT/BigInt/Decimal/Duration/DateTime/String/集合/Map/Object）的对称性做得扎实：符号位只作用于 INT 路径、空值有独立紧凑编码、时间走绝对时刻、大载荷落盘、池项借用与归还有专门用例，历史 BUG 的注释也把"为什么这样写"留在了代码里。**阻塞项集中在 4 条严重缺陷**：① FLOAT 用 bit3 兼作符号位，导致 `Float16/Float32` 负数编码成功后解码必抛异常；② `readBytes` 绕过 `SizeBoundedInput`，BIGINT/DECIMAL2/DURATION2/DATETIME2/OBJECT 可用一条小帧触发 TB 级分配；③ `decodeData` 递归无深度上限，一条 1 MB 帧即可打爆解码线程栈；④ 解码文件名未做 basename 校验，形成从报文到文件系统的任意写通道。这四条都落在无测试覆盖的区域，建议优先补负向用例再修。

一般项按"会静默出错"排序：0 字节 File 造成帧内错位、临时文件永不清理、FLOAT denormal 被解成更窄类型；其余是 README 与实现的三处不一致（低 4 位表、release 示例、缺限制段）、`DataUnit` 未覆盖，以及 5 份长度编码实现带来的漂移。轻微项以清理为主：死字段 `size`、未使用 import、注释残留、三份大端装配与三份 16 分支表；这些不影响线上行为，但直接抬高"改一处漏四处"的概率。

性能与内存方面本模块**没有任何测量数据**，`docs/LocalMode.md` 里的 f_codec 部分也只是定性判断，因此报告只给两条待验证方案（复用标量缓冲、合并长度编码）和 5 条待验证假设，不做收益承诺。local mode 明确不适合本模块（结果逃逸 + 泛型入口 + 小对象负收益）。
