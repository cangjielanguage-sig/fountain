# f_uring 模块审查报告

- **审查日期**：2026-11-28
- **模块路径**：`f_uring`（37 个文件：29 个 .cj + 8 个 .md）
- **基线**：工作区快照（sts/1.3.x 工作区，master 同提交 120fd2542，无分支差异）
- **审查重点**：见 scope.md（正确性、死代码、重复逻辑、空实现、栈溢出、OOM、热点、并发与锁、存量 BUG、内存/CPU 优化空间、local mode 可行性、README 覆盖）
- **报告版本**：v1（由 2 个分部分报告合并：`parts/f_uring.part1..2.md`）

## 发现

<!-- 第 1 部分 -->

### [严重][存量] IOUringBufferRing 的 tail 偏移写成 6，实际应为 14：provided buffer ring 完全不可用

- **位置**：`src/base/uring_flexible.cj:451-453`（`bufRingInit`）、`:466-467`（`bufRingGetTail`）、`:480-481`（`bufRingSetTail`）；消费方 `src/base/uring_buf_ring.cj:128-130`（`add`）、`:142-143`（`advance`）、`:187`（`getTail`）
- **来源**：存量（快照模式无基线；`git blame` 落全部为同一批 io_uring 封装提交）
- **判据**：review-checklist §11「边界差一 / 越界」「与规格（此处为内核 ABI）冲突」；§13 文档与实现一致（README.md:191 明确承诺 `getTail(): UInt16` 可用）
- **证据**：静态确定 —— 见下推导，两条独立证据同时成立
- **描述**：
  1. **内部自相矛盾（不依赖外部头文件）**：`bufRingBufsPtr`（`uring_flexible.cj:370-374`）把 `bufRingPtr` 本身当作 `IOUringBuf` 数组起点（`BUFS_OFFSET = 0`），而 `IOUringBuf` 是 `{addr: UInt64; len: UInt32; bid: UInt16; resv: UInt16}`＝ 16 字节（`uring_types.cj:193-198`）。因此 offset 6 落在 `bufs[0].addr` 的第 7、8 字节里：`add(..., bufOffset: 0)` 写满 16 字节 buf 条目会覆盖 tail；`advance(1)` 写 tail 又会破坏 `bufs[0].addr` 的高 16 位。
  2. **与 liburing 实际布局不符**：`struct io_uring_buf_ring` 为 `union { struct { __u64 resv1; __u32 resv2; __u16 resv3; __u16 tail; }; struct io_uring_buf bufs[0]; }`，`tail` 偏移 = 8+4+2 = **14**；liburing 的 `io_uring_buf_ring_add` 用 `br->bufs[(br->tail + buf_offset) & mask]`、`advance` 用 `io_uring_smp_store_release(&br->tail, ...)`（已按 liburing master `src/include/liburing.h` 现场核对，非凭记忆）。
  后果：`advance()` 永远写不到内核可见的 tail（真 tail 保持 0），内核看不到任何 provided buffer；`add()` 依据错误的 tail 计算下标，且首个条目地址被写坏 ⇒ 使用 `IOSQE_BUFFER_SELECT` 的读请求拿不到缓冲区或拿到非法地址。整条 buffer-ring 能力（README.md:169-195 对外承诺）实际不可用。
- **建议**：把三处 `CPointer<Byte>(bufRing) + 6` 改为 `+ 14`，并以常量（如 `BUF_RING_TAIL_OFFSET`）集中；`bufRingSetTail` 改成 release 语义（`__atomic_store_4` 的 16 位版本或 `ioUringStoreRelease64` 对齐写），`bufRingGetTail` 用 acquire 语义；`bufRingBufsPtr` 与 tail 访问分两套偏移常量，避免再混。补一条 `add + advance + 内核侧 CQE 带 IORING_CQE_F_BUFFER` 的用例。

### [严重][存量] `IOUringStream.close()` 不幂等：第二次调用重复 `free(fixedBufsPtr)`，堆破坏

- **位置**：`src/IOUringStream.cj:399-430`（关键 `:427-429`）
- **来源**：存量
- **判据**：review-checklist §11「资源不对称（打开未关 / 异常跳过释放）」「契约不符（`Resource.isClosed` 与 `close` 的幂等预期）」；专项要求「close 幂等」
- **证据**：静态确定
- **描述**：`close()` 用 `writeRing.isClosed()` / `readRing.isClosed()` 判断是否已关闭，但释放注册缓冲区内存的那一段只看 `useFixedBufs && !fixedBufsPtr.isNull()`。`fixedBufsPtr` 是 `let`（`IOUringStream.cj:77`），free 之后无法置空，`useFixedBufs` 也不会改。于是第二次 `close()`（try-with-resource 与显式 `close()` 并存、或调用方重试关闭）会再次 `LibC.free` 同一地址 —— 双重释放。启用注册缓冲区模式（`fixedBufCount > 0`）时必现。
- **建议**：加 `private var closed: Bool = false`（或 `AtomicBool`）做整体幂等门闩，`close()` 首行 `if (closed) { return }`；`isClosed()` 改为返回该门闩（顺带修掉此处只反映 writeRing 的问题）；`fixedBufsPtr` 改为 `var` 并在 free 后置 `CPointer<UInt8>()` 双保险。

### [严重][存量] `readOffset` / `writeOffset` 在锁外读改写：并发读/写会拿到相同偏移，数据互相覆盖

- **位置**：`src/IOUringStream.cj:192`（读 `readOffset`，锁外）、`:219`、`:256`（`readOffset +=`，锁内）；`:276-277`（`writeOffset` 读改写，锁外）、`:303`、`:307`、`:345`、`:350`（`writeOffset = currentOffset` 回滚，锁内）
- **来源**：存量
- **判据**：review-checklist §12.1「共享可变状态无保护」「检查-然后-写入」；§11「并发正确性」
- **证据**：静态确定（数据竞争形态）；实际覆盖范围取决于并发度 —— 两个写线程即触发
- **描述**：类里存在 `writeMutex` / `readMutex`，说明作者预期多线程调用；但两个互斥量只保护「`getSQE` + 提交」，不保护偏移分配：
  - 写：T1、T2 都在锁外执行 `let currentOffset = writeOffset; writeOffset += bufSize`，二者可读到同一 `currentOffset`，随后各自提交同一文件区间的写 ⇒ 后完成的覆盖先完成的（数据丢失）；`writeNormal`/`writeFixed` 失败回滚 `writeOffset = currentOffset` 更会把别的线程已经推进的偏移抹掉（`:303/:307/:345/:350`）。
  - 读：两个 reader 各自在锁外取 `readOffset`，进入 `readMutex` 后串行提交，但用的是同一个旧偏移 ⇒ 读到两份相同数据，且 `readOffset` 被推进两次，后续跳读一段数据。
  即便不谈并发，`writeOffset += bufSize` 发生在 I/O 成功之前，失败路径只能靠「回滚」补偿，回滚与并发推进天然冲突。
- **建议**：把偏移分配收进互斥区（`synchronized(writeMutex)` 内 `currentOffset = writeOffset; writeOffset += bufSize`，失败时在同一临界区内回滚），或把 `writeOffset` 改成 `AtomicUInt64.fetchAdd` 且失败路径改为「按完成的段回填空洞」；若契约就是单写者/单读者，必须在类文档与 README 显式声明非线程安全，并去掉误导性的两个 Mutex（否则调用方会以为可并发）。

### [严重][存量] `acquireArrayRawData` 与 `releaseArrayRawData` 全模块零配对：raw-data pin 永久泄漏

- **位置**：`src/IOUringStream.cj:205`（readNormal）、`:253`（readFixed）、`:293`（writeNormal）、`:318`（writeFixed）
- **来源**：存量
- **判据**：review-checklist §11「资源不对称（CFFI acquire 未 release）」；`mem §10.3`（raw-data 与回调）；项目内对照 `f_io/src/BytePointerStream.cj:131`、`f_io/src/f_io.cj:63`、`f_io/src/SegmentedLog.cj:768` 均成对释放
- **证据**：静态确定（`grep -rn "releaseArrayRawData" f_uring/src` 零命中，acquire 四处）
- **描述**：四处 `acquireArrayRawData(buffer)` 都没有对应的 `releaseArrayRawData`。该调用的契约是「钉住数组、期间不可移动/回收，用完必须 release」。后果：
  1. 每个被读/写过的 `Array<Byte>` 的 raw-data 句柄泄漏，数组在 GC 视角下长期不可回收；长跑流式读写下 RSS 持续上涨而仓颉堆稳定（`mem §10.3` 描述的典型形态）。
  2. 写路径把「pin 泄漏」当成了缓冲区生命周期保障：一旦按正确做法补上 release，异步写就必须另有强引用把 buffer 活到 CQE 到达（否则内核读已释放内存）。
- **建议**：读路径在 `waitCQE` 之后、`cqeSeen` 同级释放（`releaseArrayRawData(userBuf)` / `releaseArrayRawData(bufPtr)`）；写路径把 `ArrayData` 句柄（或 buffer 本身）存进该 slot 的回调闭包，在 `onComplete` 里 release —— 这也顺带给了异步写的缓冲区生命周期契约。`flush()` 之后必须保证所有在飞的写句柄都已释放。

### [严重][存量] 写路径完全丢弃完成结果：写失败、短写、超长截断都静默丢数据

- **位置**：`src/IOUringStream.cj:271-284`（`write` 无返回值、无错误通道）、`:296`（`setCallback(slotId, CompletionCallback.None)`）、`:315-319`（`writeLen = min(bufSize, fixedBufSize)`）、`:276-277`（offset 按 `bufSize` 推进）
- **来源**：存量
- **判据**：review-checklist §11「错误处理缺失或静默」「契约与实现不符」；§13（README.md:670 承诺「写入数据，立即返回」未提失败语义）；项目内 `f_io/src/MMapFile.cj:269-272` 的 `write` 在不可写/越界时抛异常
- **证据**：静态确定
- **描述**：
  - 普通模式用 `CompletionCallback.None`，收割器只调用回调、不检查 `ioUringCQEGetRes`；`write()` 也没有保存「上一次失败」。因此 `-ENOSPC`、`-EIO`、`-EBADF` 全部消失（`reap()` 在 `lockfree_uring.cj:196-203` 只看 `userData != 0`）。
  - 注册缓冲区模式 `writeLen` 被截断到 `fixedBufSize`（默认 4096），但 `writeOffset` 仍按完整 `bufSize` 推进 ⇒ 单次写入超过 4096 字节时后半段既不写、也不报错，后续写入还从错误的文件偏移继续。
  - 同理 `write()` 返回后内核仍可能在读用户缓冲区（异步语义），调用方复用同一 buffer 会造成撕裂写，README 未提示。
- **建议**：给写路径加错误通道：`writeNormal`/`writeFixed` 用会检查 `res` 的回调（`res < 0` 时记录到 `private var lastWriteError: ?IoUringException`，并在下一次 `write()` / `flush()` 抛 `IoUringException`，或按 `std.io.IOException` 抛）；`write` 侧对 `bufSize > fixedBufSize` 直接拒绝（抛异常）或循环分片，二选一，不要静默截断；offset 推进改为「按完成字节数推进」。文档补「调用返回后 buffer 仍被内核引用，直到 `flush()` 返回」。

### [一般][存量] 收割线程静默吞异常退出后，`flush()` 会永久阻塞

- **位置**：`src/IOUringStream.cj:176-184`（`catch (_: Exception) { break }`）、`:386`（`promise.awaitResult()` 无超时）
- **来源**：存量
- **判据**：review-checklist §3「`catch (_: Exception) {}` 静默吞掉异常」；§12.1「异步语义：超时但任务继续跑 / 完成永不发生」
- **证据**：静态确定（吞异常）；触发概率需实测
- **描述**：`waitAndReap()` 一旦抛异常（如 `checkNotClosed` 之外的内部异常、FFI 返回错误被包装），收割线程直接 `break`，既不记录也不通知。此后 `flush()` 提交的 `LockFreePromise` 没有任何线程会完成它，`awaitResult()` 无超时 ⇒ 调用线程永久阻塞；所有后续写的 CQE 也不再收割、槽位耗尽后 `lf.allocSlot()` 进入 `reap + sleep` 死循环（`lockfree_uring.cj:102-115`）。
- **建议**：`catch` 里至少把异常存进字段（`private var reaperError: ?IoUringException`）并在 `flush()` / `write()` 入口检查后抛出；`flush()` 的等待改用 `promise.awaitResult(timeout: ...)` 并在超时抛 `IoUringException`；`allocSlot` 的忙等加最大轮次。

### [一般][存量] 注册缓冲区内存的分配未判空、尺寸乘法无溢出检查

- **位置**：`src/IOUringStream.cj:105`、`:109`、`:112`、`:123`、`:126`
- **来源**：存量
- **判据**：review-checklist §5「按不可信长度预分配」；§11「空值未处理 / 越界」
- **证据**：静态确定（缺检查）；触发取决于调用方传入的 `fixedBufCount` / `fixedBufSize`
- **描述**：`LibC.malloc<UInt8>(count: Int64(fixedBufCount) * Int64(fixedBufSize))`（`:105`）的乘积用 Int64 计算，`UInt32 × UInt32` 上界 2^64 量级可溢出为负/小值；返回指针不判空就进入 `:110-118` 的 `fixedBufsPtr + i * fixedBufSize` 写入循环。malloc 失败或乘积溢出时不是「用不了注册缓冲区」，而是向非法地址写 16×N 字节 —— 原生堆越界。
- **建议**：入参校验（`fixedBufCount` 必须 2 的幂且 ≤ 32768，`fixedBufSize > 0`，乘积 ≤ 某常量上限），`malloc` 结果判空并抛 `IoUringException`；`writeIOvecs`/`readIOvecs` 的 malloc 同样判空。

### [一般][存量] `IoUringPool` 不校验 `ringCount`：`ringCount == 0` 时 `getRing()` 取模除零

- **位置**：`src/uring_pool.cj:48-53`（构造）、`:65`（`nextIndex.fetchAdd(1) % ringCount`）
- **来源**：存量
- **判据**：review-checklist §11「边界 / 空集合未处理（除零）」；§3（文档承诺 `ringCount` 默认 4，未声明 0 合法）
- **证据**：静态确定
- **描述**：构造器直接用 `Array<IoUring>(ringCount)`；`ringCount = 0` 时能构造出空池（或先抛 Array 尺寸异常，取决于 std 行为），随后 `getRing()` 的 `% ringCount` 触发整数除零 panic；负数同理。`getRing(index:)` 有范围检查，无参版本没有。
- **建议**：构造器 `if (ringCount <= 0) throw IoUringException(...)`（或直接 `require`），并把 `ringCount` 收窄为 `UInt32` 语义。

### [一般][存量] README 把 `IOUringStream.flush()` 写成「无操作」，实现是 fsync + 等待

- **位置**：文档 `README.md:671`、`README_en.md:671`；实现 `src/IOUringStream.cj:358-393`
- **来源**：存量
- **判据**：review-checklist §13「API / 配置 / 默认值与源码不符」「文档过期」
- **证据**：静态确定（两边都已取证）
- **描述**：README 表格写 `flush | func flush(): Unit | 无操作（write 已立即返回）`，而实现提交 `IORING_OP_FSYNC` + `IOSQE_IO_DRAIN` 并 `promise.awaitResult()` 阻塞等待，失败还抛 `IoUringException`。中英两版同错。后果：调用方据文档认为 `flush()` 不阻塞、非必需，实际它是最慢的同步点（且是唯一的持久化点），性能与正确性判断都会被带偏。
- **建议**：两版同步改为「提交 IORING_OP_FSYNC（IOSQE_IO_DRAIN）并阻塞等待所有先前 write 落盘；失败抛 IoUringException」。

### [一般][存量] `IoUringPromise.tryGetResult()` 把「已完成但失败/已取消」也返回 `None`，错误被丢弃

- **位置**：`src/base/uring_future.cj:236-253`
- **来源**：存量
- **判据**：review-checklist §11「错误处理缺失或静默」「契约与实现不符」；§10「`Option`/`Result` 被静默丢弃」
- **证据**：静态确定
- **描述**：文档写「如果已完成返回结果，否则返回 None」，实现里 `completed == true` 且 `error` 非空（`completeWithError` 路径）或 `cancelled` 时都返回 `None<T>`，与「未完成」不可区分。调用方据此判空会把 I/O 失败当成「还没好」继续轮询，永远拿不到失败原因（`IoUringFuture.tryGet()` 同样继承该语义）。
- **建议**：`tryGetResult()` 在已完成且 `error` 非空时抛出该异常（或在文档里明确「返回 None 包含失败」，并另提供 `tryGetResultWithError()`）；`isCancelled()` 的读取已无锁，可作为先决判断。

### [一般][存量] 提交骨架与 iovec 构建在四/两处逐行重复，已出现行为漂移

- **位置**：`src/IOUringStream.cj:200-226` 与 `:228-269`（read 两版）；`:286-309` 与 `:311-356`（write 两版）；`:110-118` 与 `:124-132`（write/read 的 iovec 构建循环）；`:135-143` 与 `:159-165`（两个构造器的「无注册缓冲区」字段初始化块）
- **来源**：存量
- **判据**：review-checklist §2「表现形式不同的重复逻辑（只改类型名 / 近似重复）」；本节判据要求「点名语义差异」
- **证据**：静态确定
- **描述**：四个方法共享同一骨架 `getSQE → prep → setData64 → submit → waitCQE → cqeSeen`（读）/ `allocSlot → getSQE → prep → setCallback → encode → commit → flush`（写），差异只在 prep 内容、是否需要 memcpy、回调是否为 None。重复已导致实际漂移：`writeFixed` 计算并向回调传递 `writeLen` 截断，`writeNormal` 没有；`readFixed` 有回退到 `readNormal` 的分支，`writeFixed` 也有但释放顺序不同（`:344` 与 `:349`）；「补 `releaseArrayRawData`」「检查 `res`」这两处正确性修复将来必须改四遍，极易漏。
- **建议**：抽到模块内私有函数，例如 `submitRead(prep: (CPointer<IOUringSQE>) -> Unit): Int64` 与 `submitWrite(prep, callback)`，把「取 SQE / 提交 / 等待 / 释放」收拢一处；iovec 构建抽 `buildIOVecs(base: CPointer<UInt8>, count: UInt32, size: UInt32): CPointer<IOVec>`；构造器共用私有 `initNoFixedBufs(fd, entries, flags)`。差异点（截断、回调、回退）显式参数化，别用两份代码表达。

### [一般][存量] `readMutex` 临界区包住阻塞的 `waitCQE()`，多读者完全串行

- **位置**：`src/IOUringStream.cj:201-225`（`:214` 在锁内 `waitCQE`）；`readFixed` 同构 `:232-264`
- **来源**：存量
- **判据**：review-checklist §6.2「锁内做 I/O（临界区出现任何可能阻塞的动作）」；§12.2「临界区只保护不变量」
- **证据**：静态确定（临界区内容与持有时长上界＝一次 I/O 往返）；并发收益需实测
- **描述**：`readMutex` 真正需要保护的不变量只有「取一个 SQE 并把 SQE 内容写完+提交」（SQ 环不能并发写），但当前一直持有到 CQE 返回。N 个线程读同一 stream 时并行度上限为 1，且锁持有时间等于 I/O 延迟（README 微基准：tmpfs 单次 read ≈ 811ns/iter，真实存储为微秒~毫秒级）。若契约本是单读者，这把锁只增加开销；若是多读者，这里就是串行段。
- **建议**：临界区收缩到 `getSQE + prep + submit`，`waitCQE + cqeSeen + 偏移推进` 移到锁外（前提是先解决上面 S3 的偏移分配问题，否则锁外推进偏移会引入新竞争）；或者干脆声明单读者语义，删除 `readMutex`。

### [轻微][存量] `fixedBufCount` 字段写了从不读

- **位置**：`src/IOUringStream.cj:75`（声明）、`:104`、`:138`、`:161`（三处赋值）
- **来源**：存量
- **判据**：review-checklist §1「读了不用 / 死配置字段」
- **证据**：静态确定（`grep -n fixedBufCount f_uring/src` 仅命中声明、三处赋值与构造器形参；类内无任何读取点）
- **描述**：字段只保存不使用，真正用的是构造器形参与局部变量。留着会让读者以为容量可查询/可复用。
- **建议**：删除该字段（或补 `getFixedBufCount()` 对外查询并加入 README）。

### [轻微][存量] `ioUringCQEGetData64` 的文档注释整段重复

- **位置**：`src/base/uring_cqe.cj:27-49`（两段几乎逐字相同的 `/** ... */`）
- **来源**：存量
- **判据**：review-checklist §1「不可达 / 冗余声明」、可读性
- **证据**：静态确定
- **描述**：同一函数前挂了两份内容相同的 KDoc，第二份还把「推荐使用整数形式而非指针形式」这段解释丢掉了，读者无法判断哪份是准的。
- **建议**：保留一份，把「为什么不用指针形式」的解释合并进去。

### [轻微][存量] `SQECmdHelper.CMD_OFFSET` 的注释把「cmd 偏移」写成了「结构体大小」

- **位置**：`src/base/uring_flexible.cj:40-43`
- **来源**：存量
- **判据**：review-checklist §11「语义与命名 / 注释不符」
- **证据**：静态确定（`IOUringSQE` 字段累加为 56 字节，标准 SQE 为 64 字节，48 只是 `cmd[0]` 的起始偏移）
- **描述**：注释「IOUringSQE 结构体大小为 48 字节（标准模式）」错误。这类偏移常量本就靠人肉维护，错误注释会在下一次改 `IOUringSQE` 时直接误导出真实越界。
- **建议**：改为「cmd[0] 相对 SQE 起点的偏移（标准 SQE 64 字节，48 之后为 addr3/__pad2 与 cmd 共用区）」，并补一句「`CMD_MAX_SIZE=80` 仅在 `IORING_SETUP_SQE128` 下有效」。

### [轻微][存量] `isClosed()` 只反映 writeRing，与 `close()` 的实际范围不一致

- **位置**：`src/IOUringStream.cj:395-397`
- **来源**：存量
- **判据**：review-checklist §11「契约与实现不符」
- **证据**：静态确定
- **描述**：`close()` 同时关闭 writeRing 与 readRing，`isClosed()` 只看 writeRing；若 readRing 关闭失败、或未来两者状态分叉，`isClosed()` 会给出错误的「仍可用」信号。
- **建议**：改为返回统一门闩（与 S2 的幂等标志同一字段）。

<!-- 第 2 部分 -->

### [严重][存量] `IoUringLockFree.getSQE` 恒返回空指针：README 与类注释承诺的提交路径不可用

- **位置**：`f_uring/src/lockfree/lockfree_uring.cj:135-138`（`getSQE`）→ `f_uring/src/lockfree/sqe_pool.cj:104-106`（`sqeSlots[index]`）；关键对照 `f_uring/src/lockfree/lockfree_uring.cj:102-115`（`allocSlot` 走的是 `AtomicSlotAllocator`，从不调用 `sqePool.allocSlot()`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11「契约与实现不符」、§3「接口给了默认空实现 / 开关打开后走进空分支」、§14.1「承诺了但没实现」
- **承诺源**：`f_uring/README.md:495`「`getSQE | func getSQE(slotIndex: UInt32): CPointer<IOUringSQE> | 获取 SQE」、`README.md:498-499`（`commitSlot` / `flush`）、类注释 `lockfree_uring.cj:28`「提交路径：allocSlot → getSQE → 填写 SQE → commitSlot → flush」
- **证据**：静态确定 —— `sqeSlots` 全文只有一处赋值：`sqe_pool.cj:92`（`sqeSlots[Int64(idx)] = sqe`），它只在 `SQEPreallocator.allocSlot()`（`sqe_pool.cj:75-96`）内执行。`IoUringLockFree` 对 `sqePool` 的调用只有 `getSQE`（`:137`）、`commitSlot`（`:171`）、`flush`（`:180`）、`reset` 无关，全仓 grep `sqePool.allocSlot` / `pool.allocSlot` 只命中 `src/tests/lockfree_test.cj:306`。因此 `sqeSlots` 每一项都是默认构造的 `CPointer<IOUringSQE>()`（`sqe_pool.cj:63-65`，即 null）。
- **描述**：按 README / 类注释写 `allocSlot → getSQE → ioUringPrep* → commitSlot → flush`，`getSQE` 给出 null，`ioUringPrep*` 内部 `sqe.read()`（`uring_sqe.cj:161`）直接段错误；即使不崩，`flush()` 也只把 `prepared` 当开关去 `io_uring_submit`，SQ tail 从未推进 ⇒ 返回 0（`sqe_pool.cj:126-128`），一个请求都发不出去，且返回 0 被当成正常。真正在用的生产路径（`IOUringStream.writeNormal`，`src/IOUringStream.cj:290`）绕开了 `lf.getSQE`、直接用 `writeRing.getSQE()`，所以这条公开 API 长期没人踩到。
- **建议**：`getSQE` 内部改调 `sqePool.allocSlot()` 并把「完成槽位索引」与「SQE 槽位索引」拆成两个值（现在 `slotIndex` 同时被当作两个索引用，语义已经混了）；或直接删掉 `SQEPreallocator` 这一层、让 `getSQE` 转发 `ring.getSQE()`（`submitAsync` 已有此实现），同时删掉 `commitSlot` 的索引参数与 `sqeSlots` 数组。选定一种后同步改 README 与类注释。

### [严重][存量] 收割路径被多线程并发进入：同一 CQE 可能被处理两次，固定缓冲区会被重复归还

- **位置**：`f_uring/src/lockfree/lockfree_uring.cj:102-115`（`allocSlot` 内直接 `reap()`）；`f_uring/src/lockfree/cqe_reaper.cj:110-135`（`reapAll` 的 head 读-改-写）、`:82-88`（`advance`）；`f_uring/src/lockfree/completion_slots.cj:175-189`（`invokeAndRelease` 的 generation 只在 `setCallback` 时递增）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §12.1「检查-然后-写入」「用并发容器就当复合操作原子」、§6.2 表同项（按正确性报严重）
- **证据**：静态确定（交错可推导）。`reapAll` 第 115 行 `ioUringSmpLoadAcquire(cq.khead)` 取 head、第 131 行 `ioUringSmpStoreRelease(cq.khead, head)` 写回，中间没有 CAS：T1、T2 同时读到 `head=h, tail=h+2`，两者都对 CQE h、h+1 调 `handler`，然后都把 head 写回 `h+2`。`invokeAndRelease` 用「当前 generation == 期望 generation」判重，但 generation 只在 `setCallback`（`completion_slots.cj:115`）递增、释放时不变，因此挡不住同一代的两个收割者。
- **生产可达性**：`IOUringStream.startReaper`（`src/IOUringStream.cj:173-184`）起后台线程无条件循环 `lf.waitAndReap()`；写线程在 `writeNormal` / `writeFixed` / `flush` 里先调用 `lf.allocSlot()`（`src/IOUringStream.cj:287,322,368`），槽位耗尽时 `allocSlot` 直接 `reap()` ⇒ 后台线程与写线程同时收割同一 CQ。`writeFixed` 的回调是 `allocator.release(bufIdx)`（`src/IOUringStream.cj:326-328`），重复执行会把仍在写的注册缓冲区提前放回 `fixedBufAllocator`，后续写复用同一块 → 数据互相覆盖；`reap` 里 `allocator.release(slotIndex)` 也会被调用两次（`lockfree_uring.cj:201,220,242`）。
- **建议**：① 收割收敛为单消费者——删掉 `allocSlot` 里的 `reap()`，槽位不足时只做有界等待（配 `reapMutex` 也比现在好，但那只是把无锁改回串行）；② `reapAll` 的 head 推进改 CAS 循环（`uring_barrier.cj:154` 已有 `ioUringCAS` 可用）；③ `invokeAndRelease` 用 `callbacks[slot].compareAndSwap(expected, None)` 做「抢占」，只有抢到的那一方才执行回调与释放。

### [严重][存量] `RegisteredBuffers.update` 把 iovec 起始地址写死成数组首元素：index>0 时内核注册的是槽位 0 的缓冲区

- **位置**：`f_uring/src/base/uring_registered_buffers.cj:158-188`，关键行 `:174`（`arg.data = UInt64(iovecsPtr.toUIntNative())`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11「契约与实现不符 / 数据错误」、§10 正确性
- **证据**：静态确定（对照 liburing `io_uring_register_buffers_update_tag` 的语义：`up.offset = off; up.data = (u64)(unsigned long)iov`，即 `data` 必须指向**本次待写入的那一个 iovec**，内核按 `offset + i` 定位槽位、按 `data[i]` 取新描述）
- **描述**：`update(index, iovec)` 先把 iovec 写进本地数组 `iovecsPtr[index]`（`:165`，这一步是对的），然后让内核从 `iovecsPtr` **基址**读描述、写进槽位 `index`。index>0 时内核把 `iovecs[0]` 的内容注册到槽位 index（地址与长度都是槽位 0 的）。本地数组正确、内核注册表错误，所以 `getIOVec(index)`（`:212-217`，读本地）验证不出来；后续 `ioUringPrepReadFixed/WriteFixed(bufIndex=index)` 会读写槽位 0 的缓冲区 ⇒ 静默数据错乱，缓冲区比请求短时还有内核侧越界风险。
- **建议**：`arg.data = UInt64((iovecsPtr + Int64(index)).toUIntNative())`；补用例「注册 2 个不同缓冲区 → update(1, 新 buffer) → 用 bufIndex=1 读写并校验内容」。顺带把每次 update 的 `LibC.malloc/free<IOUringRsrcUpdate>`（`:169-186`）换成复用的成员或栈上临时值。

### [一般][存量] `submitAsync` 丢弃 `ring.submit()` 的返回值，失败也返回 true

- **位置**：`f_uring/src/lockfree/lockfree_uring.cj:276-299`，关键行 `:288-289`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11「错误处理缺失或静默」、§1「读了不用」
- **证据**：静态确定 —— `let submitRet = ring.submit()` 之后紧跟 `true`，`submitRet` 之后再无引用（编译期未使用变量告警）。
- **描述**：`io_uring_submit` 返回负值（`-EBUSY` / `-EAGAIN` / `-ENOMEM`）时本次请求没有进内核，但函数报成功、槽位已 `setCallback` 且不会回收，回调永不触发；调用方随后 `waitAndReap()` 会永久等待。文档写的是「提交成功返回 true」。
- **建议**：`if (submitRet < 0) { allocator.release(slotId); /* 清掉刚设置的回调，需新增 clearCallback */ return false }`；若想保留 Bool 签名，至少在 `submitRet != 1` 时把错误码透出（改 `Result<Unit, IoUringException>` 或抛异常）。

### [一般][存量] `IoUringLockFree.close` 与在途提交 / 收割无任何同步，`ringPtr` 释放后仍被使用

- **位置**：`f_uring/src/lockfree/lockfree_uring.cj:331-339`（`close`），持有裸指针的组件 `:89`（`LockFreeCQEReaper`）、`:88`（`SQEPreallocator`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §12.1「跨线程资源 / 发布逸出」、§11「资源不对称」
- **证据**：静态确定（无同步点）；是否踩到取决于调用时序
- **描述**：`close()` 只置非原子的 `closed = true` 再 `ring.close()`（`uring_ring.cj:116-125` 释放 `ringPtr`、`cqeOutSlot`）。`checkNotClosed()` 只在每个方法**入口**检查一次，已进入 `reapAll`/`waitCQE`/`submitAsync` 的线程会继续用已释放的 `ringPtr`（`cqe_reaper.cj:57`、`:113`、`:130`）。这个类在类注释里被描述为可并发使用（`lockfree_uring.cj:28-31`），所以不属于「已声明非线程安全」的豁免。`IoUring.close`（`uring_ring.cj:116`）同形态，但 `uring.cj` 的模块注释已声明 `IoUring` 非线程安全，故不计为缺陷。
- **建议**：`close` 先置 `closed`、再 `synchronized(submitMutex)` 做一次「无在途提交」排空，并让调用方有能力 join 收割线程后再关 ring（`IOUringStream.close` 的 `stopping` + `f.get()` 就是正确样板，`src/IOUringStream.cj:399-419`）；否则在 README 里明确「close 前必须保证无并发调用者」。

### [一般][存量] `SQEPreallocator` 的索引分配、回滚与 `flush` 清零计数器不是复合原子操作

- **位置**：`f_uring/src/lockfree/sqe_pool.cj:75-96`（`idx = allocated.fetchAdd(1)` 后 `fetchSub(1)` 回滚）、`:113-115`（`commitSlot` 完全不看 `index`）、`:124-135`（`flush` 把 `allocated`/`prepared` 置 0）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §12.1「检查-然后-写入」、§2「近似重复导致的行为漂移」
- **证据**：静态确定（交错可推导）
- **描述**：三条独立问题，同一根因（计数器的复合语义）：(a) `allocated` 同时充当「下一个索引」和「在途数量」。A 拿到 `idx=N-1` 后，B 的 `fetchAdd` 得到 `N`（越界）再 `fetchSub(1)` 回 `N-1`，随后 C 又拿到 `N-1` ⇒ A、C 写同一个 `sqeSlots[N-1]`，A 之后 `getSQE(N-1)` 拿到 C 的 SQE，一个请求被串写/丢失；(b) `flush()` 在别的线程仍持有已分配但未提交的槽位时把 `allocated` 清零，之后的 `allocSlot` 会复用仍在使用的索引；(c) `commitSlot(index)` 丢弃 `index`，`prepared` 只当布尔开关，「已准备集合」并不存在——`flush` 提交的是 SQ tail 上所有 SQE，包括尚未填完的那些。
- **建议**：索引分配改成「失败不回滚」的单向 CAS（越界就返回 None，绝不减计数）；`flush` 只减「本次已提交数量」，不重置 `allocated`；`commitSlot` 要么记录索引集合，要么删掉参数改名为 `markSubmitted()`；`reset()` 保持「仅在无并发时调用」的文档约束并加断言（`getAllocatedCount() == 0`）。

### [一般][存量] `AtomicSlotAllocator.release` 不校验槽位是否已分配，重复释放会让计数下溢

- **位置**：`f_uring/src/lockfree/slot_allocator.cj:114-125`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11「边界 / 错误处理缺失」、§12.1（与上一条的重复释放叠加）
- **证据**：静态确定
- **描述**：只校验上界，不检查 bit 是否置位，直接 `fetchAnd(invertMask)` + `fetchSub(1)`。重复释放（并发收割时就可能发生，见「同一 CQE 被处理两次」）或对未分配槽位释放，会让 `allocatedCount` 从 0 下溢到 4294967295；`getAllocatedCount()` 是公开 API，`IoUringLockFree.allocatedSlotCount()`（`lockfree_uring.cj:320-323`）直接把它当监控指标暴露出去。
- **建议**：用 `compareAndSwap(word, word & invert, word)` 风格的循环，只有确认 bit=1 才清除并递减；清除失败返回 `false`，让调用方知道重复释放。

### [一般][存量] `IOUringSQE` 比 liburing 的 `io_uring_sqe` 少 8 字节：`sqes + index` 步长与 SQE128 偏移都不对

- **位置**：`f_uring/src/base/uring_types.cj:107-165`（结构体止于 `addr3`，缺尾部 `__pad2[1]` / `cmd[0]`）；受影响调用点 `f_uring/src/base/uring_sqe.cj:63-70`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11「契约与实现不符（ABI 布局）」；`CPointer<T> + Int64` 的语义见 `std/core/core_package_intrinsics.md:427-433`「同 C 语言的指针加法操作」（按 `sizeof(T)` 步进）
- **证据**：静态确定 —— 逐字段算：`opcode`1 + `flags`1 + `ioprio`2 + `fd`4 = 8；`off`8 → 16；`addr`8 → 24；`len`4 → 28；`rwFlags`4 → 32；`userData`8 → 40；`bufIndex`2 + `personality`2 → 44；`spliceFdIn`4 → 48；`addr3`8 → 56，8 字节对齐下 `sizeof = 56`。liburing 的 `struct io_uring_sqe` 是 64 字节（末尾 union 为 `addr3` + `__pad2[1]`，`cmd[0]` 占位）。
- **描述**：`sq.sqes + Int64(index)` 按 56 步进，`index > 0` 时指向真实 SQE 的中段；SQE128 分支 `<<1` 得到 112 而非 128。`sqe.write(entry)` 只写 56 字节，末尾 `cmd` 区保留上一轮的旧值（当前没有 `IORING_OP_URING_CMD` 的 prep 函数，暂时无害）。仓内唯一使用者 `ioUringGetSQE` / `ioUringGetSQEAndUpdate`（`uring_sqe.cj:39,84`）**无调用者**（全仓 grep 只命中定义与两者互调），所以现在炸不到生产，但这是对外公开函数，一旦被用就是写坏相邻 SQE。
- **建议**：补 `public var pad2: VArray<UInt64, $1> = VArray<UInt64, $1>(repeat: 0)` 使 `sizeof = 64`；加一条单元测试「连续 `ioUringGetSQE` 两次，断言两个指针相差 64（SQE128 时 128）」。

### [一般][存量] `RegisteredBuffers` 稀疏构造函数的 `!sparse` 分支注册的是一批全零 iovec（与三参构造函数近似重复但语义漂移）

- **位置**：`f_uring/src/base/uring_registered_buffers.cj:110-144`，分支体 `:115-129`；对照 `:79-97`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2「近似重复：一块少了边界判断——往往同时是缺陷」、§3「开关打开后走进空分支」、§11「语义与注释不符」
- **证据**：静态确定 —— 该分支把 `iovecsPtr` 填成 `IOVec()`（`iovBase = null`、`iovLen = 0`，`:120`）后调 `io_uring_register_buffers`，而三参构造函数注册的是调用方给的 iovec（`:86-92`）。文档 `:107` 自己写着「`sparse` 是否使用稀疏注册（**必须为 true**）」。
- **描述**：这是把三参构造函数的注册流程复制了一遍、却换了数据源。走到这里内核拿到 `iov_len == 0` 的数组（或直接 `-EINVAL`），抛出的消息还是 `io_uring_register_buffers failed`，与真实原因无关；`RegisteredFiles` 的同形态分支（`uring_registered_files.cj:112-126`）是纯复制（注册全 `IORING_REGISTER_FILES_SKIP`，与两参构造函数一致），无行为差异但重复。
- **建议**：两个类都把 `!sparse` 分支换成显式报错（`throw IoUringException("use RegisteredBuffers(ring, iovecs, nr) for dense registration")`），并让稠密注册只有一份实现（私有 init 或工厂函数）。

### [一般][存量] `allocSlot` 没有退出条件，`LockFreePromise.awaitResult` 没有超时：槽位/完成事件丢失时调用方永久阻塞

- **位置**：`f_uring/src/lockfree/lockfree_uring.cj:94-115`（注释「永不返回 None」、签名 `?UInt32`、`while (slotId.isNone()) { reap(); sleep(10μs) }`）；`f_uring/src/lockfree/lockfree_promise.cj:85-105`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11「契约与实现不符」、§12.1「有界性」
- **证据**：静态确定
- **描述**：槽位全占且 CQE 丢失（例如 `submitAsync` 吞掉 submit 失败、或收割线程已退出）时，`allocSlot` 无限轮询且无法取消；`close()` 之后也只是等到下一次 `waitCQE` 抛异常才跳出。`LockFreePromise.awaitResult` 同样无超时/取消，`IOUringStream.flush()`（`src/IOUringStream.cj:386`）依赖它 ⇒ 写入端可以永久挂住。文档「永不返回 None」与返回类型 `?UInt32` 自相矛盾。
- **建议**：`allocSlot(deadline!: Duration)` 到点返回 `None`；`awaitResult(timeout!: Duration)` 增加重载并在 `flush()` 里用有限超时；`close()` 里置一个停止标志让轮询循环退出。

### [一般][存量] 回调抛异常时 CQ head 不推进、收割线程被静默杀掉

- **位置**：`f_uring/src/lockfree/lockfree_uring.cj:193-205`、`:213-224`、`:233-265`（处理闭包）；`f_uring/src/lockfree/cqe_reaper.cj:119-133`（推进在 handler 之后）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11「错误处理缺失」、§3「静默吞异常」
- **证据**：静态确定
- **描述**：`reapAll` 在循环体内调用 `handler`，`ioUringSmpStoreRelease(cq.khead, head)` 在其后（`:130-132`）；handler 抛出时 head 停在上一次的值，已处理过的 CQE 会在下一轮被**重复**投递（且每次都抛）。`IOUringStream.startReaper` 用 `catch (_: Exception) { break }`（`src/IOUringStream.cj:178-182`）把异常吞掉并让收割线程永久退出，此后所有 `flush()` 卡在 `awaitResult`。
- **建议**：处理每个 CQE 单独 `try/catch`（记录后继续），head 推进放进 `finally`；收割线程不要因为一次回调异常退出，至少要把异常上报（日志 / 计数器）并继续。

### [一般][存量] 微基准测试里 `acquireArrayRawData` 从未配对 `releaseArrayRawData`

- **位置**：`f_uring/src/tests/iouring_stream_read_micro_perf_test.cj:85`、`:168`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11「资源不对称」；`std/core/core_package_api/core_package_funcs.md:1-17`「指针使用完后需要及时用 `releaseArrayRawData` 释放」
- **证据**：静态确定 —— 两处都只取 `bufPtr.pointer`，函数内没有任何 `releaseArrayRawData`（全仓 grep 该函数零命中）。
- **描述**：每个算例 256 轮，每轮给同一个 `Array<Byte>` 增一次 pin，测试进程结束前一直持有；更重要的是这段代码是给人抄的「read 路径怎么写」的样板，会把固定-释放不对称的写法扩散出去（`IOUringStream.cj` 的同名调用也有同样问题，属第 1 部分范围，此处只作提示）。
- **建议**：`let h = acquireArrayRawData(buf); ... ioUringPrepRead(...); releaseArrayRawData(h)`，把获取-释放窗口收到只有 FFI 调用。

### [轻微][存量] `IoUring.initFlags` 是只写不读的死字段

- **位置**：`f_uring/src/base/uring_ring.cj:45`（声明）、`:55`、`:82`（两处赋值）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §1「读了不用 / 死配置字段」
- **证据**：静态确定 —— 全仓 grep `initFlags` 只有这 3 行，无读取点。
- **建议**：删除字段；若要保留「创建时的 flags」语义，加 `public func getInitFlags(): UInt32` 供调用方判断 SQE128/CQE32（`peekCQE` 内部目前是现读 `ringVal.flags`）。

### [轻微][存量] 重复逻辑：`IoUringLockFree` 四处 CQE 处理闭包、reaper 内两处收割循环、两份 `peekCQE`

- **位置**：`f_uring/src/lockfree/lockfree_uring.cj:195-204` / `:215-223` / `:236-245` / `:252-259`（同一段「decode userData → invokeAndRelease → release」抄了 4 遍）；`f_uring/src/lockfree/cqe_reaper.cj:110-135` 与 `:144-168`（只差 `count < maxCount`）；`f_uring/src/lockfree/cqe_reaper.cj:82-88` 与 `src/base/uring_cqe.cj:108-120`（`advance` ≡ `ioUringCQAdvance`）；`f_uring/src/lockfree/cqe_reaper.cj:55-73` 与 `src/base/uring_ring.cj:199-217`（两份手写 `peekCQE`，前者用 acquire load、后者用普通 `read()`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2「换控制流 / 只改类型名」
- **证据**：静态确定（逐行比对）
- **描述**：4 份闭包里 `invoked` 的返回值处理已经出现两种写法（一处用 `if (invoked)`，一处内联 `if (...)`），是行为漂移的起点；两份 `peekCQE` 的内存序不同（reaper 用 `ioUringSmpLoadAcquire`，`IoUring.peekCQE` 用 `khead.read()`），后者在 SQPOLL/多线程场景语义更弱，但因为 `IoUring` 声明非线程安全而暂时不构成缺陷。
- **建议**：`IoUringLockFree` 抽一个 `private func handleCQE(cqe: CPointer<IOUringCQE>): Unit`（并在这里做 try/catch）；`reapAll = reapN(UInt32.Max)`；`advanceBatch` 与 `advance` 二选一；`peekCQE` 收敛到 `ioUringCQPeek` 一份实现、统一用 acquire load。

### [轻微][存量] 15 个 `ioUringPrep*` 各抄一遍 12 行字段清零

- **位置**：`f_uring/src/base/uring_sqe.cj:152-692`（`ioUringPrepRW` 之外的 13 个函数体逐行同构）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2「只改类型名 / 字面量复制」
- **证据**：静态确定（函数体两两比对：全部是「读 SQE → 置 opcode/fd → 其余字段置 0 → 写回」，差异只在 opcode 与 1-2 个字段的映射）
- **描述**：重复本身可读性尚可，但 13 份「字段映射表」里任何一处写错都很难被发现（例如 `ioUringPrepAccept` 把 `addrlen` 放 `off`、`ioUringPrepConnect` 把 `addrlen` 放 `off`，两处都正确，但靠人眼逐条比对 liburing 才确认）；也放大了「结构体 RMW」这种可以省掉的成本。
- **建议**：抽 `private func initSQE(sqe, opcode: UInt8, fd: Int32): Unit` 做清零+opcode+fd，其余字段由各 prep 函数直接写；顺带把「读整个结构体再写回」改成只写需要改的字段（见优化方案）。

### [轻微][存量] `CompletionSlotArray` 头部注释与实际布局不符，`slotBits` / `genShift` 是同一个值

- **位置**：`f_uring/src/lockfree/completion_slots.cj:61-68`（注释「generation 高 32 位 | callback 引用」）、`:55` 与 `:57`（两个字段恒等）、`:91`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11「语义与注释不符」、§1「重复声明」
- **证据**：静态确定 —— 实现是 `generations: Array<AtomicUInt64>` 与 `callbacks: Array<AtomicReference<CompletionCallback>>` 两个平行数组，注释描述的「一个槽位一个 word 同时装 generation 与 callback」并不存在；`slotBits = genShift = bits` 只被 `getSlotBits()` / `encode` 各用一次。
- **建议**：删掉 `slotBits`（`getSlotBits()` 返回 `genShift`），注释改成「generation 用独立的 64 位原子计数器，取低 32 位参与 userData 编码」。

### [轻微][存量] 文档示例与真实签名不符：`ioUringPrepReadFixed` 少传 `bufIndex`

- **位置**：`f_uring/src/base/uring_registered_buffers.cj:49`（`ioUringPrepReadFixed(sqe, fd, 0, 4096, 0)`，5 个实参）；实际签名 `uring_sqe.cj:232-239` 是 6 个形参（多了 `bufIndex: UInt16`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「示例代码不能用」（类注释里的示例同属对外说明）
- **证据**：静态确定 —— 形参个数对不上，照抄编译不过；顺带 `:42-43` 的 `IOVec(iovBase: CPointer<Unit>(buf1), iovLen: 4096)` 在 `LibC.malloc<IOVec>` 返回的指针上写入，生命周期也没交代。
- **建议**：补 `, 0` 作为 `bufIndex`，并把「iovecs / 缓冲区由谁释放」写进示例注释。

### [轻微][存量] 性能测试的计时区间包含 ring 构造、线程 spawn 与 close，和 `File` 对照组不等价

- **位置**：`f_uring/src/tests/iouring_stream_perf_test.cj:76-82`（`try(stream = IOUringStream(fd2)) { … }` 整体计时）、`:235-241`（固定缓冲区版本）；对照组 `:109-115` 只计 `File.write` 循环
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §6.1「对照」/ §13 示例可信度；fountain-baseline §8
- **证据**：静态确定 —— 被测区间包含 `io_uring_queue_init`、后台收割线程 `spawn`、`close` 排空与 fsync（`IOUringStream.close` 会提交 NOP 并 join 收割线程，`src/IOUringStream.cj:399-419`），对照组只有 256 次 `write`。
- **描述**：这些数字（`println` 打印的 ns）如果被当作「IOUringStream vs File」的结论会系统性偏向 File；仓库里没有改前/改后对照，也没有中位数与离散度，因此只能算打印型微基准，不构成性能证据。
- **建议**：把 stream 构造/析构移到计时区间外（先构造，再 `MonoTime.now()`，只包住 write 循环，最后单独计 close）；每项跑 ≥5 轮取中位数并打印 P50/P95。

### [轻微][存量] 测试里 `catch (_: FSException) {}` 静默吞异常

- **位置**：`f_uring/src/tests/iouring_stream_perf_test.cj:45-48`、`f_uring/src/tests/iouring_stream_read_micro_perf_test.cj:42-45`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §3「`catch (_: Exception) {}` 静默吞掉异常」
- **证据**：静态确定
- **描述**：`Directory.create(..., recursive: true)` 失败（权限、路径不可写）被完全吞掉，随后 `File.createTemp` 才以一个无关的错误炸出来。`iouring_stream_test.cj:41-45` 的同类 catch 带了注释说明「目录已存在，忽略」，可以接受。
- **建议**：注释说明只忽略「已存在」，或用 `if (!Directory.exists(tempDir)) { Directory.create(...) }`。

### [轻微][存量] `integration_test.cj` 里 `submitAsync` 的返回值未使用

- **位置**：`f_uring/src/tests/integration_test.cj:51-57`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §1「读了不用」
- **证据**：静态确定 —— `let ok = lf.submitAsync(...)`，`ok` 之后无引用（同函数末尾只断言 `completedCount`）。
- **建议**：`@Expect(ok)`；否则提交失败时会退化成「收割循环跑满 200 轮然后计数不符」，定位成本更高。

## 优化可行性方案

> 不是缺陷，是「还能更好」；无基线的方案只作待验证假设，不进 tasks。

<!-- 第 1 部分 -->

> 不是缺陷，是「还能更好」。两条都没有改后对照数据，仅作下一轮候选。

### [堆内存] 注册缓冲区模式下每次 write 都新建回调对象与闭包

- **现状**：`writeFixed`（`src/IOUringStream.cj:325-328`）每次调用创建 `LambdaCompletionCallback` + 捕获 `allocator`/`bufIdx` 的闭包，生命周期从提交到 CQE 收割；按 256 次 × 4KB 的测试规模即 256 个短命对象，长跑时是稳定分配源。普通模式已用 `CompletionCallback.None` 免分配，两条路径不对称。
- **方案**：预分配 `Array<LambdaCompletionCallback>`（长度 = `fixedBufCount`）或让回调对象持有可复用的 `AtomicInt32` 缓冲区索引字段，按 slot 复用而不是每次 new；回调内只做 `allocator.release(idx)`，无捕获。
- **预期**：减少每次 write 一次对象 + 一次闭包分配（数量级：每次 1~2 个对象，字节量取决于闭包捕获），GC 压力下降；对端到端延迟的收益取决于分配开销占比，未测。
- **代价**：回调对象需与 slot 生命周期绑定，`close()` 时要能安全停止复用；多一层索引映射。
- **验证**：`-O2` 下同输入（1MB = 256×4KB，tmpfs 与 NVMe 各一组）跑 `cjpm bench`，对照中位数；同时用 `cjprof heap` 看该类型分配次数与存活对象数是否归零。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 读路径把 256 次 submit 合并成批量提交

- **现状**：README.md:704-718 / `doc/iouring_optimization_lessons.md:31-41` 已有微基准：`submit` 占 read 路径 **58%**（467ns/811ns，256×4KB on tmpfs）。当前 `IOUringStream.read` 每次调用只提交 1 个 SQE 并立刻 `waitCQE`，调用方循环读 256 次就是 256 次 syscall。
- **方案**：新增批量读 API（如 `readBatch(buffers: Array<Array<Byte>>, offsets: Array<UInt64>): Array<Int64>`）：一次 `getSQE × N` + 一次 `submit`，再 `waitCQE` 收割 N 个；`read()` 单次语义保持不变。注意 `IOSQE_IO_LINK`/`IO_DRAIN` 的语义差异不要引入。
- **预期**：按 Amdahl 估算，若 submit 次数降到 1/256，read 路径理论可降 50% 上下（58% × 接近 100% 的 submit 消除），但 tmpfs 上 CQE 到达极快、批量收割是否反超需实测。
- **代价**：新 API 面；需要调用方提供 N 个缓冲区；顺序/部分完成（短读）语义要定义清楚；`readOffset` 必须一次性预留。
- **验证**：`cjpm bench -O2`，256×4KB 与 64×16KB 两组输入，中位数 ± 离散程度；同时用 `cjprof record` 确认 syscall 时间占比下降而不是转移。
- **证据状态**：`无基线（待验证，不进 tasks）`（现有微基准只证明 submit 占比，不含批量方案的改后对照）

<!-- 第 2 部分 -->

> 不是缺陷，是"还能更好"。以下两条都**没有**改前基线 + 改后对照数据，故只作为下一轮补数据的候选，不进 `tasks.md`。

### [堆内存] `CompletionSlotArray` 每槽两个独立的原子对象 + 两个数组对象

- **现状**：`slotCount` 个 `AtomicUInt64` 实例（每槽一个堆对象，8 字节载荷 + 对象头）+ `slotCount` 个 `AtomicReference` 实例（每槽一个堆对象 + 引用），外加两个 `Array` 的存储。`slotCount` 上限 2^24（`completion_slots.cj:79`） ⇒ 最坏情况约 1677 万 × 2 个对象，按每对象 16 字节估约 500 MB 级别；`IoUringLockFree` 默认取 `ring.sqSpaceLeft()`（`lockfree_uring.cj:82`）时通常只有 64/256 个槽位，实际占用可以忽略。
- **方案**：① generation 改成 `Array<UInt64>` + 原子读写（`AtomicUInt64` 数组每元素仍是独立对象，收益有限）——更实际的做法是把「generation 的低 32 位」与「callback 索引」合并进一个 `AtomicUInt64` 的槽位字（高 32 位放 callback 表的索引，低 32 位放 generation），callback 单独存一个 `Array<CompletionCallback>`；② 给 `IoUringLockFree` 的超大 `slotCount` 加显式上限（例如 4096）并抛异常，避免「配置写错就是几百 MB」。
- **预期**：槽位相关堆对象从 2N 降到 N，2^24 配置下的常驻内存从数百 MB 降到 ~130 MB（仅为估算，未测）。
- **代价**：合并字需要改 `setCallback` / `invokeAndRelease` / `encodeUserData` 三处协议，`getCallback`/`getGeneration` 语义要重新定义；并发语义（CAS 抢占用同一个字）必须重新验证。
- **验证**：`getAllocatedHeapSize()` + RSS 在 slotCount = 64/1024/2^20 三档下对照，配合 `lockfree_test.cj` 的并发用例回归。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 收割与 prep 路径的整结构体读改写

- **现状**：`LockFreeCQEReaper` 每次 `peekCQE` / `reapAll` / `reapN` / `advance` 都执行 `ringPtr.read()`（整个 `IOUring` 结构 ~200 字节的逐字段拷贝，再取 `.cq`），其中 `sq/cq/ringMask/flags` 在 ring 生命周期内不变；`ioUringPrep*` 每个请求都 `sqe.read()`（56 字节）+ `sqe.write()`（56 字节）整结构体 RMW，而实际只改 3-5 个字段。
- **方案**：① reaper / `IoUringLockFree` 在构造时缓存 `cq` 指针、`ringMask`、`CQE32` 标志（`lockfree_uring.cj:89` 已有构造点），热路径只做 `ioUringSmpLoadAcquire(cq.khead)`；② prep 函数直接对 `sqe` 指针写字段（`sqe.pointer.opcode = …`）或只读写必要字段，避免整结构体来回拷贝。
- **预期**：单次收割省掉约 200 字节拷贝 + 若干字段解引用；单次 prep 省掉约 112 字节拷贝。端到端收益取决于这两段在 read/write 路径中的占比，未测（`iouring_stream_read_micro_perf_test.cj:124-132` 里 `getSQE/prep/submit/waitCQE/cqeSeen` 的分段打印可作为采集入口）。
- **代价**：缓存 `cq`/`ringMask` 等于把「ring 初始化后不可变」这一假设写进代码，`IORING_SETUP_CQE32` 之类只能在构造时判定；prep 改为逐字段写会失去「一次 write 全量覆盖」的抗残留能力（现在本来也只覆盖 56 字节）。
- **验证**：`cjprof record` 跑 `microReadPathBreakdown` 场景（1 MB / 4 KB 块，256 轮，≥5 次取中位数），对照改前改后 `prepRead+sqe`、`cqeSeen`、`reap` 三段的 ns/iter。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

<!-- 第 1 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `readMutex`/`writeMutex` 在真实并发下已成竞争热点（多线程共享同一 stream） | `src/IOUringStream.cj:201`、`:289` | 锁等待时长、BLOCKED/WAITING 线程占比（CPU profile 看不到） | 8 线程并发读/写同一 fd，采线程状态 + 分段计时（锁等待 / I/O 等待分开） |
| 2 | raw-data pin 未释放导致的 RSS 增速与上限 | `src/IOUringStream.cj:205/253/293/318` | 长跑 RSS 曲线与 raw-data 句柄计数 | 连续 10 万次 4KB 读写，每万次记录 `getAllocatedHeapSize()`、`getUsedHeapSize()`、RSS；与修后版本对照 |
| 3 | 注册缓冲区模式下每次 write 的回调分配占端到端比例 | `src/IOUringStream.cj:326` | 该类型分配次数与自耗时占比 | `cjprof heap` 统计 `LambdaCompletionCallback` 分配次数；`cjprof record` 看分配器自耗时 |
| 4 | `IOUringSmpWMB/RMB` 用 `seq_cst` 全屏障在 aarch64 上的额外开销 | `src/base/uring_barrier.cj:206-222` | 每次调用的指令数/耗时；仓内当前零调用点 | 先确认是否有调用计划；有则 `-O2` aarch64 上跑 `atomic_thread_fence` 前后对照（当前仓内无引用，收益大概率为 0） |

<!-- 第 2 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `ioUringPrep*` 的整结构体 RMW 占 read 路径自耗时的主要部分 | `src/base/uring_sqe.cj:152-692` | 该段自耗时占比（现在只有测试里打印的分段 ns，无 profile、无改前改后对照） | `cjprof record` 跑 `microReadPathBreakdown`（1 MB / 4 KB / 256 轮），对比只写必要字段的版本，`-O2`，≥5 轮取中位数 |
| 2 | `ringPtr.read()` 的结构体拷贝让收割线程成为写路径瓶颈 | `src/lockfree/cqe_reaper.cj:57,113,147`、`:84` | 收割线程 CPU 占用与每 CQE 处理成本 | `cjprof` 采样收割线程；同时记录 `reap()` 返回值与 `allocSlot` 的 10 μs 轮询次数 |
| 3 | 槽位耗尽时 `allocSlot` 的 10 μs 轮询拉高写尾延迟（P99） | `src/lockfree/lockfree_uring.cj:105-113` | 写延迟 P50/P95/P99 与轮询次数 | 压测 4 写线程 × 固定 64 槽位，采集每次 `allocSlot` 的耗时分布 |
| 4 | 固定缓冲区路径的 `LambdaCompletionCallback` 每次写都新分配一个对象 | `src/IOUringStream.cj:326-328`（第 1 部分范围，仅作线索） | 分配量与 GC 次数 | `getAllocatedHeapSize()` 增量 + 写入 10 万块，对照预建回调数组 |

## 文件覆盖

> 与 `files/f_uring.txt` 一一对应；分部分报告逐文件确认已读。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_uring/README.md` | .md | ✅ | — |
| 2 | `f_uring/README_en.md` | .md | ✅ | — |
| 3 | `f_uring/doc/iouring_optimization_lessons.md` | .md | ✅ | — |
| 4 | `f_uring/doc/spec/fix-f-uring-tests/design.md` | .md | ✅ | — |
| 5 | `f_uring/doc/spec/fix-f-uring-tests/proposal.md` | .md | ✅ | — |
| 6 | `f_uring/doc/spec/fix-f-uring-tests/specs/uring-async-io/spec.md` | .md | ✅ | — |
| 7 | `f_uring/doc/spec/fix-f-uring-tests/tasks.md` | .md | ✅ | — |
| 8 | `f_uring/doc/优化方案.md` | .md | ✅ | — |
| 9 | `f_uring/src/IOUringStream.cj` | .cj | ✅ | — |
| 10 | `f_uring/src/base/uring.cj` | .cj | ✅ | — |
| 11 | `f_uring/src/base/uring_barrier.cj` | .cj | ✅ | — |
| 12 | `f_uring/src/base/uring_buf_ring.cj` | .cj | ✅ | — |
| 13 | `f_uring/src/base/uring_constants.cj` | .cj | ✅ | — |
| 14 | `f_uring/src/base/uring_cqe.cj` | .cj | ✅ | — |
| 15 | `f_uring/src/base/uring_exception.cj` | .cj | ✅ | — |
| 16 | `f_uring/src/base/uring_ffi.cj` | .cj | ✅ | — |
| 17 | `f_uring/src/base/uring_flexible.cj` | .cj | ✅ | — |
| 18 | `f_uring/src/base/uring_future.cj` | .cj | ✅ | — |
| 19 | `f_uring/src/base/uring_params_builder.cj` | .cj | ✅ | — |
| 20 | `f_uring/src/base/uring_pool.cj` | .cj | ✅ | — |
| 21 | `f_uring/src/base/uring_registered_buffers.cj` | .cj | ✅ | — |
| 22 | `f_uring/src/base/uring_registered_files.cj` | .cj | ✅ | — |
| 23 | `f_uring/src/base/uring_ring.cj` | .cj | ✅ | — |
| 24 | `f_uring/src/base/uring_sqe.cj` | .cj | ✅ | — |
| 25 | `f_uring/src/base/uring_types.cj` | .cj | ✅ | — |
| 26 | `f_uring/src/lockfree/completion_slots.cj` | .cj | ✅ | — |
| 27 | `f_uring/src/lockfree/cqe_reaper.cj` | .cj | ✅ | — |
| 28 | `f_uring/src/lockfree/lockfree_promise.cj` | .cj | ✅ | — |
| 29 | `f_uring/src/lockfree/lockfree_uring.cj` | .cj | ✅ | — |
| 30 | `f_uring/src/lockfree/slot_allocator.cj` | .cj | ✅ | — |
| 31 | `f_uring/src/lockfree/sqe_pool.cj` | .cj | ✅ | — |
| 32 | `f_uring/src/tests/integration_test.cj` | .cj | ✅ | — |
| 33 | `f_uring/src/tests/iouring_stream_perf_test.cj` | .cj | ✅ | — |
| 34 | `f_uring/src/tests/iouring_stream_read_micro_perf_test.cj` | .cj | ✅ | — |
| 35 | `f_uring/src/tests/iouring_stream_test.cj` | .cj | ✅ | — |
| 36 | `f_uring/src/tests/lockfree_test.cj` | .cj | ✅ | — |
| 37 | `f_uring/src/tests/uring_test.cj` | .cj | ✅ | — |

合计：`.cj` 29 个 / `.md` 8 个 / 共 37 个，全部读完。

## 覆盖自检

### 第 1 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 8 | S1–S5 + G3 + G7 + M3。安全性方面本部分无外部输入解析、无 SQL/注入面；硬编码凭据无 |
| §1 死代码 | 2 | 已逐个 `private` 符号全仓搜引用：`IOUringStream` 的 22 个私有成员中仅 `fixedBufCount` 无读取（M1），其余（含 `startReaper/readNormal/readFixed/writeNormal/writeFixed/checkNotClosed`）均有调用；`uring_barrier.cj` 4 个私有内存序常量全部本文件使用；`public` 顶层声明（`ioUringAtomicCAS`、`ioUringLoadAcquire64/StoreRelease64`、`ioUringSmpWMB/RMB`、`bufRingInit`、`bufRingMask`、`sqeReadCmd`、`sqeWriteCmd`、`cqeSetBigCQE`、`probeGetSupportedOpcodes/GetOpsCount/GetLastOp`）按硬原则一判为对外可达契约、不算死代码，仅记录仓内零引用；`protected` 本部分无；另有 1 处不可达冗余（M2 重复注释块） |
| §2 重复逻辑 | 1 | 已把本部分所有带函数体的函数压成「输入→输出→副作用」摘要两两比对（4 个类的全部方法 + 21 个柔性数组辅助函数 + 14 个 CQE/SQE 辅助函数 + 内存屏障包装；其中 3 行内的 accessor 只按「读字段/写字段」归类比对）：确认 4 组同语义骨架（G6）；`ioUringSmpWMB/RMB` 与 `SmpMB` 同为全屏障属于有意别名，不计；三处 `checkNotClosed`（`uring_buf_ring.cj:225`、`uring_pool.cj:109`、`uring_future` 无）错误文案不同、各 3 行，未计 |
| §3 空实现 | 1 | G1（收割线程 `catch { break }`）。`CompletionCallback.None.onComplete` 是有注释的 Null Object，不计；无 `TODO`/`FIXME`/`UnsupportedException` 占位 |
| §4 栈溢出 | 0 | 本部分无递归：`probeGetSupportedOpcodes` 是单层循环、`IOUringStream` 全部为顺序调用；未发现自引用结构的深度遍历 |
| §5 OOM | 1 | G2（按 `fixedBufCount × fixedBufSize` 预分配且不判空/不防溢出）。`CompletionRegistry.slots` 只增不减但由调用方注册/移除，契约内使用下不无界（已在 `completeSlot/cancelSlot` 对称移除） |
| §6.1 热点瓶颈 | 0 | 未提供本模块 profile；README 的微基准是历史数据、且针对旧实现，未作为本轮缺陷证据。相关猜测进待验证假设 #1–#3 |
| §6.2 大粒度锁 | 1 | G7（`readMutex` 临界区含阻塞 `waitCQE`） |
| §6.3 并发串行 | 0 | 本部分无 `spawn().get()`、无批内单任务窗口；`writeMutex` 内是「取 SQE + 提交」短临界区，不构成串行段 |
| §6.4 低效算法 | 0 | 无嵌套循环匹配、无 `contains`/`indexOf` 热点、无 `remove(at: 0)`、无循环内字符串拼接；`probeGetSupportedOpcodes` 上界 256 次，非热点 |
| §7 降堆内存方案 | 1 | 见「优化可行性方案 / 堆内存」；证据状态为无基线 |
| §8 降 CPU 方案 | 1 | 见「优化可行性方案 / CPU」；证据状态为无基线 |
| §9 local mode 可行性 | 0 | 不适用：读写的中间对象（`LambdaCompletionCallback`、`IOUringBuf`、buffer 数组）都要逃逸到槽位数组 / 跨线程回调 / 调用方，`@ local!` 逃逸检查不通过；`doc/LocalMode*.md` 也未覆盖本模块 |
| §11 现有代码的 BUG（存量） | 10 | S1–S5、G2、G3、G5、M3、M4。全部为存量（快照无 diff）。已覆盖本部分读到的边界/空值（`:105` malloc、`:194` 空 buffer、`:230` 槽位耗尽、`uring_pool:65` 取模）、错误处理（`:296`、`:180`）、资源（`:205/253/293/318`、`:427`）、并发（`:192/219/276`）四类 |
| §12 并发安全与锁粒度 | 2 | S3（两个并发写者/读者 + 缺失同步手段：偏移无原子/无锁）、G7（临界区内容与持有时长）。已核对：`stopping` 为 AtomicBool、`nextIndex` 为 AtomicInt64、`slots` 为 ConcurrentHashMap、`rings` 不可变，属正确做法；`IOUringPool.closed`、`IOUringBufferRing.closed` 为非原子 Bool，但只在 `init` 后与 `close` 写、`close` 本身有幂等门闩，未列缺陷（若将来多线程 `close` 同池则需改原子） |
| §14 功能完备性与 README 覆盖 | 0 | 已把本部分 `public` 声明逐项对照 README：`IoUring*`、`CompletionSlot/Registry/Promise/Future`、`IOUringBufferRing`、`RegisteredBuffers/Files`、全部 `ioUring*` 函数、`sqe*/cqe*/probe*/bufRing*` 辅助函数与 4 个 Helper 类均已收录；未发现「承诺未实现」或「公开 API 完全无文档」。`IOUringPromise.getSlotId` 未进 README 方法表、`IOUringStream` 未说明线程安全，属次要遗漏，未达「一般」门槛 |
| 文件覆盖（§13 等） | 20/20 | 无缺文件；`.md` 逐份核对（README 两版、优化记录、3 份 spec 归档、优化方案） |

### 第 2 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 5 | 正确性 3（S1-S3 契约与数据错误）、设计 1（`slotIndex` 一值两义、`SQEPreallocator` 层冗余）、可读性 2（注释与实现不符、示例不可用）、语言特性 1（`CPointer<T> + Int64` 步进按 56 字节）；无安全类命中（不解析外部输入、无注入面） |
| §1 死代码 | 2 | 机械动作已做：`private` 字段/函数逐个全仓 grep（`initFlags` 只写不读 → 命中；`checkNotClosed`、`ringPtr`、`slotCount`、`callbacks` 等均有读取点）；`internal`/`protected` 声明本部分为 0；对外可达 `public`（`ioUringGetSQE`、`ioUringGetSQEAndUpdate`、`reaper.peekCQE/advance/advanceBatch`、`getSlotBits`、`getGeneration`、`getCallback`、`pendingCount`、`preparedCount`、`getFd`、`getIOVec`、`isSparse`）仓内无引用但**不判**死代码，只记录；`submitRet`、`ok` 两个「读了不用」的局部变量命中 |
| §2 重复逻辑 | 5 | 已两两比对本部分全部函数体：`IoUringLockFree` 4 份 CQE 处理闭包、`reapAll`/`reapN`、`reaper.advance` vs `ioUringCQAdvance`、两份 `peekCQE`、15 个 prep 函数样板、`RegisteredBuffers` 稀疏构造的 `!sparse` 分支（近似重复且漂移）；`getIOVec`/`getFd`、`isSparse`/`getNrXxx` 这类只改类型的访问器按「为可读性刻意展开」不报 |
| §3 空实现 | 1 | `CompletionCallback.onComplete` 的默认空实现有注释、是 Null Object 哨兵，不算问题；命中的是 `RegisteredBuffers` `!sparse` 分支注册全零 iovec（走进功能不可用的分支）；`catch (_: FSException) {}` 见轻微项 |
| §4 栈溢出 | 0 | 本部分无递归、无自引用结构、无深度拷贝；`ioUringPrep*` 都是单层调用 |
| §5 OOM | 0 | 唯一候选是 `CompletionSlotArray(2^24)` 的预分配（计入优化方案，未达「无界增长」判据）；其余数组均按调用方显式容量分配，`LibC.malloc` 均有对应 `free`（`IOUringRsrcUpdate` 每调用一次成对释放；`RegisteredFiles.allocIndex` 成对释放） |
| §6.1 热点瓶颈 | 0 | 未提供 `cjprof` / `cjpm bench` 数据，仓库内只有 `println` 型微基准（且计时口径不等价），热点结论不成立，已全部写入「待验证假设」1-3 |
| §6.2 大粒度锁 | 0 | 本部分唯一的锁是 `SQEPreallocator.sqeMutex`（临界区仅一次 `io_uring_get_sqe`，无 I/O/日志）与 `LockFreePromise` 的 `mutex`（仅 `notify`/`wait`）；`submitAsync` 的 `submitMutex` 包住 submit 系统调用，属必要串行，未达「锁内 I/O 放大」判据 |
| §6.3 并发串行 | 0 | `submitAsync` 的 `getSQE+submit` 串行是 SQ tail 的正确性要求（不是形式并发）；未发现 `spawn().get()` 或批大小配成 1 的形态 |
| §6.4 低效算法 | 0 | `AtomicSlotAllocator.alloc` 是 O(wordCount) 位图扫描（≤1024 字），`reapAll` 是单趟；无嵌套循环、无 `remove(at: 0)`、无循环内字符串拼接 |
| §7 降堆内存方案 | 1 | 见「优化可行性方案 · 堆内存」（`CompletionSlotArray` 每槽两个原子对象）；无基线，标 `无基线（待验证）` |
| §8 降 CPU 方案 | 1 | 见「优化可行性方案 · CPU」（整结构体 RMW / 每轮 `ringPtr.read()`）；无基线 |
| §9 local mode 可行性 | 0 | 本部分无「函数内创建、函数内销毁的大临时对象」：prep 只写 SQE，reap 只遍历 CQE 指针，测试里的 4 KB `Array<Byte>` 会跨函数存活（作为 buffer 参数），不满足逃逸检查，收益无法用峰值内存证明 |
| §11 现有代码的 BUG（存量） | 8 | 已核对：`RegisteredBuffers`/`RegisteredFiles` 的 4 个构造函数错误路径（失败均 `free` 后抛）、`update`/`updateBatch`/`allocIndex` 的索引与指针、`IoUring` 的 `waitCQE`/`peekCQE` 索引计算（含 CQE32 位移，与 liburing 一致）、`AtomicSlotAllocator.alloc` 的位序与回滚、`LockFreePromise` 的写序与丢失唤醒、`SQEPreallocator` 三条计数路径、`reaper` 的 head 推进与异常路径、`ioUringGetSQE` 的容量判断（`next - head > ringEntries`，与 liburing 等价）；命中 8 条（3 严重 + 5 一般），另有 2 条一般属于并发维度，见下行 |
| §12 并发安全与锁粒度 | 5 | 已列出共享点与同步手段：`AtomicSlotAllocator`（CAS，安全）、`CompletionSlotArray`（原子，判重不足）、`SQEPreallocator`（`sqeMutex` 只保护 get_sqe，计数器无保护）、`CQ head`（读-改-写，不安全）、`IoUringLockFree.closed`（非原子，close 与在途操作竞争）；线程封闭无法证明的有 `IoUring`（已在文档声明非线程安全，按豁免不报）与测试内部对象 |
| §14 功能完备性与 README 覆盖 | 1 | README `:495-499` 承诺的 `getSQE/commitSlot/flush` 提交路径实际不可用（双证见 S1）；本部分不含 `.md`，README 其余段落归第 1 部分 |
| 文件覆盖（§13 等） | 17/17 | 无缺文件；`.md` 为 0，§13 的文档一致性以类注释/README 交叉引用方式核对（命中 2 条轻微） |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 8 |
| 一般 | 16 |
| 轻微 | 12 |
| 其中存量 | 36 |
| 优化方案 | 见「优化可行性方案」各条 |

## 总评

**第 1 部分**：第 1 部分的代码分两层：`base/` 下的 liburing 绑定（常量、FFI 声明、CQE/SQE 辅助、内存屏障、参数构建器）质量明显好于 `IOUringStream`。绑定层逐条与 UAPI 比对未发现错值或签名错配，`@When[os == "Linux"]` 覆盖完整，注释齐全；唯一实质缺陷集中在柔性数组区（buffer ring 的 tail 偏移 6 应为 14），这一处让 README 承诺的 provided buffer ring 能力整体不可用，且会写坏首个缓冲区条目的地址，属于必须先修的阻塞项。

`IOUringStream` 是风险集中区，四个问题互相牵连：偏移分配在锁外（并发下读写错位、数据互相覆盖）、raw-data 句柄从不释放（长跑 RSS 无界增长）、`close()` 不幂等（第二次关闭重复 free 原生内存）、写路径不检查完成结果（失败/短写/超 4096 字节截断全部静默丢数据）。这四条都是「设计上只有单线程 + 只成功」的假设留下的，而类里又放了两个 Mutex 暗示支持并发，契约与实现不一致。收割线程 `catch { break }` 则把任何一次异常升级成 `flush()` 永久阻塞，属同一类「错误路径没有出口」的问题。

复用性方面：read/write 各有两份几乎逐行相同的提交骨架，已经出现「一个截断长度、一个不截断」「一个回退、一个不回退」的漂移；将来补 release、补 res 检查必须改四遍，建议在修缺陷时一并抽公共提交函数，避免修一半。

文档层面整体可信（API 表与源码对得上、spec 归档自洽），唯一硬冲突是 `flush()` 被写成「无操作」而实现是带 DRAIN 的 fsync 阻塞等待，中英两版同错，需与上面的写路径改造一起更新。性能方面本模块已有历史微基准（submit 占读路径 58%），但那是旧实现的单点数据；本轮的优化候选（批量提交、回调复用）都没有改后对照，只作为待验证假设，不建议直接排期。

**第 2 部分**：本部分的风险集中在**无锁层的契约与并发**，不在基础封装：

三处阻塞项都是「看起来实现了、实际不成立」。`IoUringLockFree.getSQE` 返回空指针是最直接的一条——`README.md:495` 与类注释把 `allocSlot → getSQE → prep → commitSlot → flush` 写成主推提交流程，但 `SQEPreallocator.sqeSlots` 只在 `allocSlot()` 里被填充，而 `IoUringLockFree.allocSlot()` 用的是另一个分配器，这条路径从写下来那天起就走不通（生产路径 `IOUringStream.writeNormal` 恰好绕开了它，所以一直没暴露）。`RegisteredBuffers.update` 的 `data` 恒指向 `iovecs[0]`，注册 index>0 的缓冲区时内核拿到的是槽位 0 的描述，而本地副本是正确的、`getIOVec` 验证不出来——这类「校验路径与出错路径不一致」的 bug 最难在测试里发现。并发收割那条则是把「CQ 由单线程收割」的假设写进了注释，却在 `allocSlot` 里又让任意写线程去 `reap()`，两个线程同时读-改-写 CQ head 会让回调重复执行，固定缓冲区模式下直接是数据互相覆盖。

`base/` 部分的封装质量明显更好：15 个 `ioUringPrep*` 的字段映射逐条对照 liburing 只有 `IOUringSQE` 尺寸这一处 ABI 偏差（且唯一受影响的 `ioUringGetSQE` 目前无调用者），`RegisteredFiles` 的三条更新路径、`IoUring` 的 CQE 索引（含 CQE32 位移）都与内核/库语义一致，错误路径的 `malloc`/`free` 也都成对。

建议排期：三条严重项先定「修 / 收窄契约」二选一（`getSQE` 那条如果短期不修，应把 `getSQE/commitSlot/flush` 从 README 与类注释里删掉并标注 `@Deprecated`，否则下个使用者必踩）；`submitAsync` 吞 submit 返回值与 `allocSlot` 无退出条件这两条一起改（都是「错误路径把调用方挂死」）；其余一般项可随下一次无锁层重构一起处理。存量 12 条（3 严重 + 9 一般）是否纳入修复待用户决定。

**范围外提示**（`src/IOUringStream.cj`，第 1 部分）：`acquireArrayRawData` 在 `:205/:253/:293/:318` 四处同样未 `releaseArrayRawData`；`:300/:341` 丢弃 `writeRing.submit()` 的返回值，与本报告「submitAsync 吞返回值」同源。
