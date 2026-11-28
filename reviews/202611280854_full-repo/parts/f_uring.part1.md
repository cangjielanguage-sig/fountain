# f_uring 模块审查报告（第 1/2 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_uring`（本部分 20 个文件：12 个 `.cj` + 8 个 `.md`）
- **基线**：工作区快照（master 与 sts/1.3.x 同一提交 `120fd2542`，`git diff` 为空）⇒ 全部问题来源为「存量」
- **审查重点**：原生内存与数组固定（`acquireArrayRawData` / `malloc` 配对）、异步提交的并发正确性（offset / SQ tail / CQE 收割）、`close` 幂等、错误路径回收；另按公共维度过死代码、重复逻辑、文档一致性
- **报告版本**：分部分报告（模块第 1/2 部分，文件清单 `files/f_uring.part1.txt`），由主 Agent 合并进 `docs/review/2026-11-28/f_uring_v2.md`

## 发现

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

## 优化可行性方案

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

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `readMutex`/`writeMutex` 在真实并发下已成竞争热点（多线程共享同一 stream） | `src/IOUringStream.cj:201`、`:289` | 锁等待时长、BLOCKED/WAITING 线程占比（CPU profile 看不到） | 8 线程并发读/写同一 fd，采线程状态 + 分段计时（锁等待 / I/O 等待分开） |
| 2 | raw-data pin 未释放导致的 RSS 增速与上限 | `src/IOUringStream.cj:205/253/293/318` | 长跑 RSS 曲线与 raw-data 句柄计数 | 连续 10 万次 4KB 读写，每万次记录 `getAllocatedHeapSize()`、`getUsedHeapSize()`、RSS；与修后版本对照 |
| 3 | 注册缓冲区模式下每次 write 的回调分配占端到端比例 | `src/IOUringStream.cj:326` | 该类型分配次数与自耗时占比 | `cjprof heap` 统计 `LambdaCompletionCallback` 分配次数；`cjprof record` 看分配器自耗时 |
| 4 | `IOUringSmpWMB/RMB` 用 `seq_cst` 全屏障在 aarch64 上的额外开销 | `src/base/uring_barrier.cj:206-222` | 每次调用的指令数/耗时；仓内当前零调用点 | 先确认是否有调用计划；有则 `-O2` aarch64 上跑 `atomic_thread_fence` 前后对照（当前仓内无引用，收益大概率为 0） |

## 文件覆盖

> 与 `files/f_uring.part1.txt` 一一对应。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_uring/README.md` | .md | ✅ | 与实现有 1 处冲突：`flush` 描述（发现 G4）；其余 API 表逐项与源码核对一致 |
| 2 | `f_uring/README_en.md` | .md | ✅ | 与中文版逐节对应，`flush` 同错（发现 G4）；无中英缺节 |
| 3 | `f_uring/doc/iouring_optimization_lessons.md` | .md | ✅ | 历史优化记录，与 README 数据一致；`write 零分配` 的「收割器自动释放 slot」经 `lockfree_uring.cj:196-203` 核实成立 |
| 4 | `f_uring/doc/spec/fix-f-uring-tests/design.md` | .md | ✅ | 归档变更记录，按「当时结论自洽」核对：D2（构造器 public）与现状 `uring_future.cj:288` 一致 |
| 5 | `f_uring/doc/spec/fix-f-uring-tests/proposal.md` | .md | ✅ | 同上；声明的三项改动均已在代码中体现 |
| 6 | `f_uring/doc/spec/fix-f-uring-tests/specs/uring-async-io/spec.md` | .md | ✅ | 规格与实现一致（`isCompleted` 前 false/后 true、取消抛 `IoUringException` 均有对应实现） |
| 7 | `f_uring/doc/spec/fix-f-uring-tests/tasks.md` | .md | ✅ | 全部勾选项与现状一致（59→61 用例为历史数据，未复核） |
| 8 | `f_uring/doc/优化方案.md` | .md | ✅ | 2026-05-02 历史记录；文中「已修复」项经核实仍在（`uring_future.cj` AtomicBool、`sqe_pool.cj:53` sqeMutex、`slot_allocator.cj:130` getAllocatedCount）。路径写 `f_io/src/uring/**` 属历史命名，不做缺陷计 |
| 9 | `f_uring/src/IOUringStream.cj` | .cj | ✅ | 发现 S2/S3/S4/S5、G1/G2、G6/G7、M1、M4 |
| 10 | `f_uring/src/base/uring.cj` | .cj | ✅ | 包级文档，无代码；与 `base` 公共 API 名称一致 |
| 11 | `f_uring/src/base/uring_barrier.cj` | .cj | ✅ | 6 个 FFI + 4 个私有内存序常量（全部在本文件内使用）+ 8 个 public 函数（对外可达，仓内 `ioUringSmpMB` 3 处使用、其余 4 个零引用）；见待验证假设 #4 |
| 12 | `f_uring/src/base/uring_buf_ring.cj` | .cj | ✅ | 发现 S1（消费方）；`close` 有幂等门闩，`add/advance` 的线程不安全已在注释声明 |
| 13 | `f_uring/src/base/uring_constants.cj` | .cj | ✅ | 逐组与 UAPI 数值核对（setup/enter/IOSQE/CQE/opcode 0-48/feat/register/buf-ring flags），未发现错值 |
| 14 | `f_uring/src/base/uring_cqe.cj` | .cj | ✅ | 发现 M2；`ioUringCQAdvance`（release 存 head）、`ioUringSQReady`（SQPOLL 分支 acquire）与 liburing 语义一致 |
| 15 | `f_uring/src/base/uring_exception.cj` | .cj | ✅ | 两个构造器，无问题 |
| 16 | `f_uring/src/base/uring_ffi.cj` | .cj | ✅ | 逐条与 liburing/kernel 签名比对（`io_uring_enter` fd 为 `unsigned int`、`_setup_buf_ring` flags 为 `unsigned int` 等），未发现签名错配 |
| 17 | `f_uring/src/base/uring_flexible.cj` | .cj | ✅ | 发现 S1（tail 偏移）、M3；其余偏移常量（cmd 48、big_cqe 16、probe ops 16、bufs 0）核对正确 |
| 18 | `f_uring/src/base/uring_future.cj` | .cj | ✅ | 发现 G5；`CompletionRegistry` 用 ConcurrentHashMap + AtomicUInt64，组合操作无明显竞态 |
| 19 | `f_uring/src/base/uring_params_builder.cj` | .cj | ✅ | 13 个 setter 与 `uring_constants.cj` 常量、`IOUringParams` 字段一一对应，无死 setter |
| 20 | `f_uring/src/base/uring_pool.cj` | .cj | ✅ | 发现 G3；`nextIndex` 为原子轮询，`rings` 不可变，无锁化方向正确 |

合计：`.cj` 12 个 / `.md` 8 个 / 共 20 个，全部读完。

## 覆盖自检

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

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 5 |
| 一般 | 7 |
| 轻微 | 4 |
| 优化方案（堆内存 / CPU） | 1 / 1 |

存量 16 条（严重 5、一般 7、轻微 4），是否纳入修复待用户决定；本部分无「本次改动」引入的问题（快照模式无 diff）。

## 总评

第 1 部分的代码分两层：`base/` 下的 liburing 绑定（常量、FFI 声明、CQE/SQE 辅助、内存屏障、参数构建器）质量明显好于 `IOUringStream`。绑定层逐条与 UAPI 比对未发现错值或签名错配，`@When[os == "Linux"]` 覆盖完整，注释齐全；唯一实质缺陷集中在柔性数组区（buffer ring 的 tail 偏移 6 应为 14），这一处让 README 承诺的 provided buffer ring 能力整体不可用，且会写坏首个缓冲区条目的地址，属于必须先修的阻塞项。

`IOUringStream` 是风险集中区，四个问题互相牵连：偏移分配在锁外（并发下读写错位、数据互相覆盖）、raw-data 句柄从不释放（长跑 RSS 无界增长）、`close()` 不幂等（第二次关闭重复 free 原生内存）、写路径不检查完成结果（失败/短写/超 4096 字节截断全部静默丢数据）。这四条都是「设计上只有单线程 + 只成功」的假设留下的，而类里又放了两个 Mutex 暗示支持并发，契约与实现不一致。收割线程 `catch { break }` 则把任何一次异常升级成 `flush()` 永久阻塞，属同一类「错误路径没有出口」的问题。

复用性方面：read/write 各有两份几乎逐行相同的提交骨架，已经出现「一个截断长度、一个不截断」「一个回退、一个不回退」的漂移；将来补 release、补 res 检查必须改四遍，建议在修缺陷时一并抽公共提交函数，避免修一半。

文档层面整体可信（API 表与源码对得上、spec 归档自洽），唯一硬冲突是 `flush()` 被写成「无操作」而实现是带 DRAIN 的 fsync 阻塞等待，中英两版同错，需与上面的写路径改造一起更新。性能方面本模块已有历史微基准（submit 占读路径 58%），但那是旧实现的单点数据；本轮的优化候选（批量提交、回调复用）都没有改后对照，只作为待验证假设，不建议直接排期。
