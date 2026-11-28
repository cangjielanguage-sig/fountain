# f_io 模块审查报告（第 1/2 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_io`（全模块 18 个 `.cj` + 8 个 `.md`；**本报告为模块第 1/2 部分**，覆盖 `f_io.part1.txt` 的 12 个 `.cj` + 8 个 `.md`；`SegmentedLog_test.cj`、`f_io.cj`、`mmap_native.cj`、`exception/*.cj` 共 6 个 `.cj` 属第 2 部分，未纳入本报告统计）
- **基线**：工作区快照（sts/1.3.x 工作区，未对照远端目标分支；快照模式无 diff，所有问题来源一律记「存量」）
- **审查重点**：文件 / 流句柄生命周期、缓冲与刷盘、错误处理、死代码、重复逻辑、并发安全、存量 BUG
- **报告版本**：v1（第 1/2 部分）

## 发现

### [严重][存量] `ExtendByteBuffer` 的多字节读取从不读取缓冲区，全部返回 0 且不推进偏移

- **位置**：`f_io/src/ExtendByteBuffer.cj:55-65`（`read<T>`）；受影响入口 `f_io/src/ExtendByteBuffer.cj:76-106`（`readUInt16/32/64`、`readInt16/32/64`、`readFloat16/32/64`）
- **来源**：存量（工作区快照，无 diff 可比）
- **判据**：review-checklist §11（契约与实现不符）；§10 正确性
- **证据**：静态确定 —— `read<T>(len, endian)` 先 `let bytes = Array<Byte>(len, repeat: 0)`，然后直接 `T.readBigEndian(bytes[0..len])` / `readLittleEndian(...)`；函数体内**没有任何**从 `this`（`ByteBuffer`）取字节的调用，`len` 只用于决定临时数组长度。只有 `readBool`（:66-72）、`readUInt8`（:73-75）、`readInt8`（:85-87）走 `readByte()`，行为正常。
- **描述**：任何 `readUInt32()` / `readInt64()` / `readFloat32()` 之类的调用都返回 0（零字节数组按端序解释），同时不消费输入、不移动 `readOffset`。以该方法族做二进制协议解析的调用方会静默拿到全 0 字段，后续字段全部错位；当前仓库内没有调用者（`grep ExtendByteBuffer/readUInt32` 只命中 `f_io` 自身与 `f_hydra`、`f_store` 的同名私有函数），因此这是对外 API 的静默数据错误，而不是仓内已被触发的故障。
- **建议**：`read<T>` 里把 `len` 字节真正读进来并校验长度，例如 `if (this.read(bytes) != len) { return None }` 后再做端序转换；或把 `read(p: CPointer<Byte>)` 与端序转换组合，省掉中间数组（见「优化可行性方案」第 3 条）。补 2/4/8 字节读写往返用例，README 目前没有任何示例。

### [严重][存量] `MMapFile` 构造条件写反：只读映射与「文件已足够长」的映射一律抛异常

- **位置**：`f_io/src/MMapFile.cj:55-65`（构造器分支）；调用方 `f_io/src/MMapFile.cj:291-302`（`extend File <: ToMMap`）
- **来源**：存量
- **判据**：review-checklist §11（逻辑错误 / 契约与实现不符）
- **证据**：静态确定 —— 唯一不抛异常的分支是 `if (writable && offset + mapLength > file.length)`；`else` 分支无条件 `throw MMapException('file ... is not writable but the file length - offset ... is less than mapLength')`。因此：
  1. `writable == false`（只读 prot，`File.mmap` 对只读文件正是传 `[MMapProt.Read]`）→ 必抛，即使文件长度足够；
  2. `offset + mapLength <= file.length`（映射一个已足够长的大文件，`DEFAULT_MMAP_BYTES` 为 1 GiB，文件大于 1 GiB 时必然命中）→ 必抛，即使文件可写。
- **描述**：`MMapFile` 的对外契约是「读映射 / 写映射 / 长度不足时自动延长」（README.md:171、README_en.md:171），实现却只保留「可写且必须延长」这一条路径。只读映射 100% 不可用；映射大文件 100% 不可用；错误消息还把「文件够长」描述成「不可写且太短」。仓内目前没有 `MMapFile` 使用者（`grep "MMapFile\|\.mmap(" --exclude-dir=.worktrees` 只命中定义处），影响面是下游使用者。
- **建议**：
  ```
  if (offset + mapLength > file.length) {
      if (!writable) { throw MMapException('... not writable and too short ...') }
      file.setLength(offset + mapLength)
  }
  ```
  同时给只读 / 恰好等长 / 超长三种形状各加一条用例。

### [严重][存量] 全模块没有任何真实刷盘：`std.fs.File.flush()` 是空函数，mmap 脏页从不 `msync`

- **位置**：`f_io/src/SegmentedLog.cj:777-788`（`syncImpl`）、`:790-796`（`finishSegmentCreation`）；`f_io/src/SegmentBoundary.cj:117-130`（`publish`）、`:147-154`（`syncDirectory`）；`f_io/src/MMapFile.cj:149-164`（`sync`/`flush`）与 `:36-37`（`dirtyStart`/`dirtyBytes`）
- **来源**：存量
- **判据**：review-checklist §3（公开契约承诺有行为，实现为空）；§11（契约与实现不符）；§13
- **证据**：静态确定 ——
  1. 标准库文档 `cangjie_runtime/stdlib/doc/libs/std/fs/fs_package_api/fs_package_classes.md:1501`：「将缓冲区数据写入流。由于 `File` 不存在缓冲区，所以该函数没有具体作用。」；实现 `cangjie_runtime/stdlib/libs/std/fs/file.cj:298` 为 `public func flush(): Unit {}`。也就是说 `file.flush()` **不会**调用 `fsync`。
  2. `f_io` 侧所有「同步」都终止于 `file.flush()`：`SegmentedLog.syncImpl()`（:781）、`doRotate` durable 分支（:702）、`close()`（:460）、`SegmentBoundary.publish`（:121）、`syncDirectory`（:150，对目录 fd 调用同一个空函数）。全模块没有真实的 `fsync` 调用：`grep -n "msync\|fsync" *.cj` 除注释外只有 `MMapFile.cj:155` 一处 `msync` 调用（另有 `mmap_native.cj:40/73` 的声明），而它不可达（见下一条）；`msync` 的返回值也没有被检查。
  3. `MMapFile` 自己的 `msync` 路径不可达：`private func sync()`（:158-164）要求 `dirtyBytes > 0`，而 `dirtyBytes` / `dirtyStart` 在整个文件里**只有** `sync()` 自身读写，`write`/`writeByte`（:262-272）从不登记脏区，两个字段恒为 0。
- **描述**：README 的三处承诺均不成立——`log.sync()  // fsync 当前 segment`（README.md:452 / README_en.md:453）、`syncInterval` 控制 fsync 频率（README.md:614-619 / README_en.md:623-628）、`syncImpl() … 在 Linux 下等价于 msync() + fsync()`（README.md:619、:661 / README_en.md:628、:670）。实际后果：`durableBoundary` 模式在把边界文件标记为 `COMMITTED` 之前没有任何数据落盘动作，进程被杀或掉电后可以出现「边界宣称已提交 N 字节，数据页仍在 page cache 丢失」的状态，正是该模式存在的目的被架空；`MMapFile.flush()` 同样是无副作用的空操作（另见「一般」中的文档条目）。
- **建议**：把刷盘下沉到真正的系统调用——mmap 路径用 `msync(ptr, len, MS_SYNC)` 并检查返回值；非 mmap 路径对 `file.fileDescriptor.fileHandle` 调 `fsync`（`mmap_native.cj` 已经在声明 Linux syscall，可一并声明 `fsync`，非 Linux 分别走 `FlushFileBuffers` / `fcntl(F_FULLFSYNC)`）；目录同步必须单独 `open(dir, O_RDONLY|O_DIRECTORY)` 后 `fsync`，不能用 `File(...).flush()`。`durableBoundary` 的顺序应改为「msync 数据段 → fsync 数据文件 → 发布边界 → fsync 目录」。验收要给「写入后 `sync()` 再强杀进程，重启后 `readView()` 仍能读到 N 字节」的用例，而不是只看 `cjpm test` 绿色。

### [严重][存量] `ByteBuffer.write` 的扩容上限固定为 2.5×容量，一次写入更大的数组直接抛越界异常

- **位置**：`f_io/src/ByteBuffer.cj:135-137`（`grow`）、`:145-151`（`write`）、`:72-87`（`reserve`）
- **来源**：存量
- **判据**：review-checklist §11（边界 / 异常路径）
- **证据**：静态确定 —— `grow()` 只调用 `reserve(buffer.size + buffer.size / 2)`；`reserve` 的扩容分支固定分配 `buffer.size + addition`，即容量恒为 `2.5 × capacity`，与待写入长度无关。`write` 只 `grow()` 一次，随后 `buf.copyTo(buffer, 0, woffset, buf.size)`。当 `woffset + buf.size > 2.5 × capacity` 时目标数组装不下，`Array.copyTo` 按标准库文档抛 `IndexOutOfBoundsException`（`core_package_structs.md:472-490`）。
- **描述**：默认 `ByteBuffer()`（容量 32）一次 `write` 超过 80 字节即抛异常；`ByteBuffer(array)` 初始化时容量被抬到 `2.5n`，但之后任何单次写入超过 `2.5 × 当前容量 - woffset` 的块都会失败。这是「小缓冲 + 大块写」的常规用法，失败还是异常而非短写，调用方很难预期。README.md:732 / :776 写的「扩容 capacity/2 + buf.size」与实现也不一致（见「一般」文档条目）。
- **建议**：`write` 改为按需扩容 `reserve((woffset - roffset) + buf.size)`，或 `while (woffset + buf.size > buffer.size) { grow() }`；把 `if (woffset + buf.size >= buffer.size)` 的 `>=` 改成 `>`，避免「正好装满」也扩容。补一条 `ByteBuffer().write(Array<Byte>(4096))` 的用例。

### [严重][存量] `BytePointerStream.close()` 可重复 `free`，close 后仍可读写

- **位置**：`f_io/src/BytePointerStream.cj:46-53`（`close`）、`:24-27`（`closed` 字段）；读写入口 `:109-123`、`:145-161`
- **来源**：存量
- **判据**：review-checklist §11（资源不对称 / 释放后使用）；§12.1
- **证据**：静态确定 —— `close()` 的函数体是 `if (freeable) { LibC.free(pointer); closed = true }`，没有 `if (closed) return` 前置判断，也没有先置位再释放；`read`/`write`/`access` 完全不检查 `closed`。`MMapFile` 正好用非 freeable 的 `BytePointerStream` 包装映射区（`MMapFile.cj:73-74`），其 `isClosed()` 永远返回 false。
- **描述**：`try (let s = BytePointerStream(size)) { … }` 之外再调一次 `close()`（或 `Resource` 包装层与业务层各关一次）会 `free` 同一指针两次，堆元数据被破坏；`close()` 之后任何 `read`/`write` 都是对已释放内存的 `mcopy`（use-after-free）。`closed` 还是普通 `var`，与 `AtomicInt64` 的偏移量混用，多线程 close/read 时没有任何同步。
- **建议**：`close()` 用 CAS 或互斥保证只执行一次（先置 `closed = true`，再 `free`）；`read`/`write` 入口加 `checkOpen()`；非 freeable 的实例在 close 后也应把 `closed` 置为 true，否则 `Resource` 契约（`isClosed`）无意义。

### [严重][存量] `NonblockingQueueStream.read` 在 `closeOnEnd = false` 时对已耗尽流死循环

- **位置**：`f_io/src/QueueInputStream.cj:35-46`
- **来源**：存量
- **判据**：review-checklist §11（逻辑错误）；§3（有界性）
- **证据**：静态确定 —— `if (s == 0)` 分支里唯一的推进动作是 `if (closeOnEnd && let r: Resource <- queue.remove() && ...)`；当 `closeOnEnd == false` 时该 `if` 整体为假，随后 `continue`，队列头部仍是同一个流，`q.read(buffer)` 继续返回 0 → 永久自旋，**既不返回 0 也不抛异常**。
- **描述**：调用方按 README.md:257「非阻塞读取，无数据时返回 0」使用 `NonblockingQueueStream(size, closeOnEnd: false)` 时，一旦读到一个已经读完的流（例如嵌套的 `NonblockingQueueStream` 暂时没有数据），`read` 就卡在 100% CPU 的自旋里，请求线程永不返回。
- **建议**：`s == 0 && !closeOnEnd` 时直接 `return 0`（保留游标，下次继续）；或统一改用 `remove(Duration.Zero)` 显式拿到元素并区分「暂时空」与「已结束」。

### [严重][存量] `SyncByteBuffer.end()` 只唤醒一个等待线程，多个阻塞读者永久挂起

- **位置**：`f_io/src/ByteBuffer.cj:265-270`（`end`）；相关 `:214-229`、`:230-248`
- **来源**：存量
- **判据**：review-checklist §12.1（条件变量 / 异步语义）；§6.2（`synchronized` 内的等待）
- **证据**：静态确定 —— 标准库文档 `sync/sync_package_api/sync_package_classes.md:8395-8401`：`Condition.notify()`「唤醒**一个**等待在该 Monitor 上的线程」，`:8457-8463` 才是 `notifyAll()`。`end()` 调用的是 `condition.notify()`。读者侧只有在显式传入 `timeout`（如 `read(buf, timeout: Duration.Max)`、`readByte(timeout: Duration.Max)`）时才会进入 `condition.wait`；这类等待没有第二条退出路径（`SyncByteBuffer` 只实现 `IOStream`，不是 `Resource`，没有 `close()`）。
- **描述**：两个以上线程阻塞读同一个 `SyncByteBuffer` 时，`end()` 只放行一个，其余线程永久阻塞（`Duration.Max` 没有超时）。生产者侧 `write`/`writeByte` 用 `notify()` 是合理的（一字节只够一个读者），但「流结束」是全局事件，必须广播。
- **建议**：`end()` 内改 `condition.notifyAll()`；`read`/`readByte` 的等待循环在 `end_ == true` 时清空并返回 0/N。补一条「N 个读者 + end()」的并发用例。

### [严重][存量] durable 模式遇到残留 `*.boundary.tmp` 时启动必然失败，README 承诺的「改名保留」不可达

- **位置**：`f_io/src/SegmentedLog.cj:826-856`（`durableDirectory` 的临时文件分支）；`f_io/src/SegmentBoundary.cj:68-74`（`load` 的 `exists(path)` 校验）、`:111-116`（`publish` 先建 `.tmp`）、`:133-144`（`preserveTemporary`）
- **来源**：存量
- **判据**：review-checklist §11（错误处理 / 契约与实现不符）；§13
- **证据**：静态确定 —— 对 `wal_5.log.boundary.tmp`，`durableDirectory` 先去掉 `.tmp`、再去掉 `.boundary` 得到 `path = …/wal_5.log`，然后**无条件**调用 `SegmentBoundary.load(path, 5, maxFileSize)`；`load` 第一步就要求 `exists(path + ".boundary") && size == 44`。若崩溃发生在该段**第一次** `publish` 的 `File.create(tmp)`（`SegmentBoundary.cj:117`）与 `rename`（`:126`）之间——也就是 `beginSegment`（`SegmentedLog.cj:798-806`）刚写下初始化意图时——正式边界文件尚不存在，`load` 抛 `missing or invalid segment boundary`，该异常在 `durableDirectory` 内没有被捕获，直接让 `SegmentedLog.init` 失败。`preserveTemporary` 只在「正式边界已存在、又留下一个 tmp」时才走得到。
- **描述**：README.md:418 / README_en.md:418 明确承诺「启动先校验所有正式边界与数据，将同一受管段遗留的未提交临时边界排他改名保留并同步目录，不将临时文件当成提交」。实现把「临时文件」当成必须已有正式边界的附属物，于是最常见的崩溃点（首次发布中断）会让整个日志目录**永久打不开**：每次重启都在同一个 `load` 抛错，运维只能手工删文件。
- **建议**：`durableDirectory` 先分类再校验——识别 `*.tmp` 时按「临时文件自身」校验（长度为 0 或 44 都视为未提交证据），直接走 `preserveTemporary`，不要求正式边界存在；正式边界缺失且无 tmp 时才拒绝。补一条「只留 tmp、无正式边界」目录的启动用例。

### [一般][存量] `NonblockingQueueStream` 用 `peek` + 阻塞 `remove` 组合，「非阻塞」不成立且会静默丢弃非 `Resource` 流

- **位置**：`f_io/src/QueueInputStream.cj:36-42`
- **来源**：存量
- **判据**：review-checklist §12.1（检查-然后-写入 / 容器线程安全不等于组合原子）；§11（契约不符）
- **证据**：静态确定 —— 标准库文档 `collection_concurrent_class.md:529-539`：`peek()` 非阻塞、空队列返回 `None`；`:561-567`：`remove()` **阻塞**直到有元素。两个读者可以同时 `peek` 到同一个队首，先 `remove` 者成功，后者的 `remove()` 永久阻塞——「非阻塞读」被打破。另外 `if (closeOnEnd && let r: Resource <- queue.remove() && !r.isClosed())` 中 `queue.remove()` 在模式匹配之前就已求值：当队首流不实现 `Resource` 时条件为假，元素已被摘出并丢弃（既不 close 也不继续读），剩余数据静默丢失。
- **描述**：嵌套 `NonblockingQueueStream`（内层暂时无数据时 `read` 返回 0）是最常见的用法，正好命中「被当成结束、被丢弃」。README.md:257 只承诺「无数据时返回 0」，没有任何「不实现 Resource 的流会被丢弃」的说明。
- **建议**：用 `queue.remove(Duration.Zero)` 一次取到元素并保留引用，`None` 时返回 0；非 `Resource` 的流读完后再出队（需要双端队列或「当前流」字段，见下一条的合并建议）。

### [一般][存量] `BlockingQueueStream` 没有 EOF / close 语义，`closeOnEnd = false` 时把短读当结束并丢数据

- **位置**：`f_io/src/QueueInputStream.cj:53-64`
- **来源**：存量
- **判据**：review-checklist §11（契约 / 边界）；§12.1（异步语义）
- **证据**：静态确定 —— 函数是 `while (true)`，只在 `s > 0` 时返回；`queue.remove()` 在队列空时阻塞（同前引文档），没有 `closed`/`end` 标志，也没有 `close()` 方法。`input.read` 返回 0 且 `closeOnEnd == false` 时既不 close 也不保留 `current`，直接 `current = queue.remove()` 换下一个流，前一个流里可能剩下的数据被永久跳过。
- **描述**：`read` 永远不返回 0，因此调用方无法区分「暂时没有数据」和「全部读完」；关停时阻塞在 `remove()` 的线程无法被唤醒（没有 `close`/`end` 入口，类也不实现 `Resource`）。`closeOnEnd = false` 的语义（「由调用方负责关闭」）被实现成了「丢弃未读完的流」。
- **建议**：增加 `end()`/`close()` + `AtomicBool` 终止标志，`remove(Duration)` 轮询该标志后返回 0；`closeOnEnd == false` 时保留当前流引用直到它返回 0 之后再前进，并在 README 写清所有权。

### [一般][存量] `RotatableBuffer` 把「短读」当 EOF，且 `indexOf` 会搜到窗口里的陈旧字节

- **位置**：`f_io/src/RotatableBuffer.cj:24-32`（构造）、`:84`、`:121`、`:136-139`（换窗补读）、`:43-69`（`indexOf`）
- **来源**：存量
- **判据**：review-checklist §11（边界 / 空值）；§10 正确性
- **证据**：静态确定 —— 构造与每次换窗都写成 `bufferEnd = input.read(...)`；只有 `read(...) == halfBufferSize` 才继续补读第二半窗，否则后续所有分支按 `bufferEnd < bufferSize`（即「底层流已结束」）处理。标准库 `InputStream` 契约（`io/io_package_api/io_package_interfaces.md:13-27`）只承诺「返回读取的字节数」，不保证读满：socket、管道、`SyncByteBuffer` 的短读都是合法行为。`indexOf` 的扫描上界是 `bufferSize - bytes.size`，没有按 `bufferEnd` 截断，会在旧窗口残留字节里匹配出分隔符。
- **描述**：一次合法的短读会让 `RotatableBuffer` 认为输入结束，`read` 从此返回 0，剩余报文被判为 EOF；HTTPS/慢连接下的 multipart 请求可能因此解析出截断的内容（`f_http.MultipartFormDataParser` 是仓内唯一调用方，见「范围外提示」）。陈旧字节命中还会把 `sectionEnd` 指到有效数据之外。
- **建议**：读满一个半窗或读到 0 为止（`while (got < halfBufferSize) { let n = input.read(buf[got..]); if (n <= 0) break; got += n }`）；`indexOf` 的上界改为 `min(bufferSize, bufferEnd) - bytes.size`。

### [一般][存量] mmap 失败返回值未校验（非 durable 路径与 `MMapFile` 全局）

- **位置**：`f_io/src/MMapFile.cj:66-72`、`:83-85`；`f_io/src/SegmentedLog.cj:739-747`
- **来源**：存量
- **判据**：review-checklist §11（错误处理缺失）
- **证据**：静态确定 —— `SegmentedLog.initFileMapping` 只在 `config.durableBoundary` 为真时比较 `mmapPtr.toUIntNative() == UIntNative.Max`；`MMapFile` 构造器与默认模式 `SegmentedLog` 完全不检查 `mmap` 返回值。Linux 的失败返回值是 `MAP_FAILED`（`(void*)-1`），不是 `nullptr`；`MMapFile.isNullPointer`（:83-85）既从未被调用，比较的也是 `nullptr`。
- **描述**：`ftruncate`/`fallocate`/`mmap` 任一失败（磁盘满、权限、`vm.max_map_count`、地址空间不足）后，默认模式仍然 `mapped = true`，第一次 `write` 通过 `mcopy` 写 `(Byte*)-1` → 进程段错误；durable 模式则正确抛 `LogBoundaryException`。同一进程里两套行为不一致。
- **建议**：抽一个 `checkMapped(ptr)`（比较 `MAP_FAILED`）在两条初始化路径都调用；删除 `isNullPointer`（见「轻微」死代码条目）。

### [一般][存量] `MMapFile.close()` 非幂等，关闭后读写入口不设防

- **位置**：`f_io/src/MMapFile.cj:186-215`（`isClosed`/`close`）、`:248-272`（`read`/`write`）
- **来源**：存量
- **判据**：review-checklist §11（资源释放 / 释放后使用）
- **证据**：静态确定 —— `close()` 第一句是 `closed = true`，之后没有 `if (closed) return`；重复调用会第二次 `munmap`（返回值忽略）并再次 `file.close()`（可能抛 `FSException`）。`read`/`write` 只检查 `isReadable`/`isWritable`（prot 位），不检查 `closed`。
- **描述**：`syncAndUnmap()`（:136-139）之后调 `close()` 也是同一形态的双重 `munmap`。`close()` 之后继续 `read` 会 `mcopy` 已解除映射的地址，属于难以定位的段错误。
- **建议**：`close()` 加幂等判断与 `closed` 复检，`read`/`write`/`sync` 入口统一 `checkOpen()`；`syncAndUnmap` 也应置 `mapped` 状态位供后续判断。

### [一般][存量] `BytePointerStream.read` 存在负长度路径：`UIntNative(size)` 变成巨大值传给 `mcopy`

- **位置**：`f_io/src/BytePointerStream.cj:89-95`（`opsize`）、`:109-123`（`read`）
- **来源**：存量
- **判据**：review-checklist §11（边界 / 越界）；§12.1（并发正确性）
- **证据**：静态确定 —— `opsize(size, offset, len)` 在 `len - offset < size` 时直接返回 `len - offset`；`read` 里 `len` 是 `writeOffset_`，`offset` 是 `readOffset_`。当 `readOffset_ > writeOffset_` 时返回负数，`if (size == 0)` 拦不住，`access()` 里 `UIntNative(size)` 把 -1 解释成 `UIntNative.Max` 并作为 `mcopy` 长度 → 越界读/写。可达路径有二：`readOffset`/`writeOffset` 是公开 `mut prop`（:55-70）且不校验范围；两个线程并发 `read` 时 `load()` 与 `fetchAdd()` 不是原子的，可能双双越过 `writeOffset_`。
- **描述**：字段用 `AtomicInt64` 暗示了并发安全，但「算长度 + 推进」不是原子复合操作；`MMapFile` 又通过公开 `readOffset`/`writeOffset` setter（`MMapFile.cj:114-132`）把越界值直接透传进来（`value - offset` 不做 0..mapLength 校验）。
- **建议**：`opsize` 返回 `max(0, …)`；`read` 用 CAS 循环推进 `readOffset_`（失败重算长度）；两个 setter 校验 `0 ≤ v ≤ size`，越界抛 `BytePointerException`。

### [一般][存量] durable 模式的目录创建拒绝单段相对路径

- **位置**：`f_io/src/SegmentBoundary.cj:157-169`（`ensureDirectory`）
- **来源**：存量
- **判据**：review-checklist §11（边界）
- **证据**：静态确定 —— 标准库 `fs_package_structs.md:1356-1379`：`Path("logs").parent` 返回 `Path("")`。`ensureDirectory` 在 `parent.isEmpty()` 时直接 `throw LogBoundaryException("cannot create log directory: ${path}")`，因此 `LogConfig(dir: "logs", …, durableBoundary: true)` 只要目录尚不存在就必然初始化失败（而绝对路径 `/tmp/logs` 正常）。
- **描述**：README 的配置示例用的是绝对路径，掩盖了这个问题；durable 模式（MQ 主队列 / 备份 / 死信都启用）用相对目录部署时直接起不来，报错信息还暗示「无法创建」，实际只是没处理无父目录的情况。
- **建议**：`parent` 为空时直接 `Directory.create(path)` 并对当前工作目录同步一次；只有 `Directory.create` 真的失败才抛。

### [一般][存量] `ExtendPath` 符号链接分支把 `base` 换成链接目标，路径切片可能越界

- **位置**：`f_io/src/ExtendPath.cj:88-95`（符号链接分支）、`:67-75`（`copyFile`）
- **来源**：存量
- **判据**：review-checklist §11（逻辑 / 边界）
- **证据**：静态确定 —— `symbolicTarget.copy(symbolicTarget, to: to, matched: matched)` 把递归的 `base` 从 `this`（已被 `canonicalize`）改成了链接目标路径。`copyFile` 里 `let sub = origin.parent.toString()[base.toString().size..]` 用 `base` 的**字符串长度**切 `origin.parent`；当 `base` 是链接目标、而 `origin` 来自对链接目标 `Directory.walk` 的路径时，两者长度关系不再有保证，`base.size > origin.parent.size` 会抛切片越界（`Range` 非法），小于时得到错误的相对子路径。
- **描述**：复制一个指向目录的符号链接（例如部署目录里的 `current -> releases/20261128`）会生成错误的目录层级或直接抛异常；常规的「指向文件的符号链接」不受影响（走 `copyFile`）。
- **建议**：递归时统一用 `canonicalize(this)` 作为 `base`，只把遍历根换成链接目标；`copyFile` 里改成先校验 `origin.parent` 以 `base` 为前缀（`startsWith`）再切片，否则抛带路径的 `FSException`。

### [一般][存量] `LogConfig` 只校验 durable 分支，默认模式允许非法容量 / 空目录 / 空前缀

- **位置**：`f_io/src/SegmentedLog.cj:72-84`
- **来源**：存量
- **判据**：review-checklist §11（缺少边界校验 / 错误信息误导）；§10 设计
- **证据**：静态确定 —— 校验只有 `if (durableBoundary && (maxFileSize <= 0 || startSeq < 0 || syncInterval > 1))`。默认模式下 `maxFileSize <= 0` 不报错，随后每个非空 `append` 都被 `LogRecordTooLargeException` 拒绝（`SegmentedLog.cj:281-283`），错误指向「记录太大」而不是「配置非法」；`dir` 为空串时 `Directory.create("")` 抛底层 `FSException`；`filePrefix` 为空串会生成 `_1.log`，与 `parseSegmentIndex` 的 `prefix + "_"` 规则叠加后可能扫描到不该扫的文件。
- **描述**：配置错误被推迟到第一笔业务写入才暴露，且错误类型与真实原因不符；`syncInterval` 为负在默认模式下是合法语义（每次同步），在 durable 模式下被单独拒绝，两套语义没有在 README 里并列说明。
- **建议**：构造器统一校验 `maxFileSize > 0`、`dir` 非空、`filePrefix` 非空、`fileExt` 为空或以 `.` 开头，失败抛 `IllegalArgumentException` 并带上字段名。

### [一般][存量] README 多处与实现不符（刷盘语义、SyncByteBuffer.capacity、扩容公式、自动关闭、中英不同步）

- **位置**：`f_io/README.md:205`、`:452`、`:526`、`:614-619`、`:661`、`:730-732`、`:747-748`、`:776`；`f_io/README_en.md:205`、`:453`、`:530`、`:623-628`、`:670`、`:742-744`、`:760`、`:788`
- **来源**：存量
- **判据**：review-checklist §13（文档与代码一致性）；§14（README 覆盖）
- **证据**：静态确定 —— 逐条对照：
  1. `MSyncFlag`/`flush` 语义：README.md:205「`flush` 等同于 `sync(MSyncFlag.Sync)`」，实现 `MMapFile.cj:276-278` 调的是 private `sync()`，在 `dirtyBytes == 0` 时静默返回，且不会像 `sync(flag:)`（:149-157）那样对不可同步映射抛异常。
  2. fsync 承诺：README.md:452 / :619 / :661 与 README_en.md:453 / :628 / :670 声称 `file.flush()` 等价于 `msync + fsync`，标准库实现是空函数（见「严重」第 3 条，`fs_package_classes.md:1501`）。
  3. `SyncByteBuffer` 的 `capacity`：README.md:748、README_en.md:760 列出 `public prop capacity: Int64`，`ByteBuffer.cj:155-275` 的 `SyncByteBuffer` 没有该属性（`ByteBuffer` 才有，:51-55）。
  4. 扩容公式：README.md:730/732/776、README_en.md:742/744/788 写「扩容 capacity/2 + buf.size」，实现固定扩容 `1.5 × capacity`（见「严重」第 4 条）。
  5. `openEntryStream` 返回的流「读完后自动关闭」（README.md:526 / README_en.md:530）：`ChainedSegmentStream` 读到末尾只 `closeCurrentFile()`，`closed` 恒为 false（`SegmentedLog.cj:899-953`），`isClosed()` 返回 false，需要调用方自己 `close`。
  6. 中英不同步：README.md:447 有「只有同步提交完成才可用于相应的确认。默认模式按 `syncInterval` 同步，持久有效长度模式每次追加同步提交。」，README_en.md:448 只有「a persistent token of the write position」，缺整段同步语义说明。
- **描述**：前两条会让使用者把「没有落盘的写入」当成已持久化（数据丢失级误导），第 3 条让使用者写出编译不过的代码，第 5 条影响 `try-with-resource` 的写法选择，第 6 条使英文读者拿不到 durability 的关键约束。
- **建议**：按实现重写这几段；`SyncByteBuffer` 补上 `capacity` 或从文档删除；`openEntryStream` 的「自动关闭」要么实现（EOF 时置 `closed`）要么删掉；中文那一段补齐到 `README_en.md`。

### [轻微][存量] 死代码：`MMapFile.isNullPointer` 无调用者，`dirtyStart`/`dirtyBytes` 只读不写

- **位置**：`f_io/src/MMapFile.cj:83-85`（`isNullPointer`）、`:36-37`、`:154-163`（`dirtyStart`/`dirtyBytes`）
- **来源**：存量
- **判据**：review-checklist §1（无调用者 / 读了不用）
- **证据**：静态确定 —— `grep -rn "isNullPointer" --include=*.cj .` 全仓（排除 `.worktrees`）只命中定义行 `MMapFile.cj:83`；`dirtyStart`/`dirtyBytes` 的赋值只出现在 `sync()` 内部（`dirtyStart += dirtyBytes`、`dirtyBytes = 0`），写入路径 `write`/`writeByte` 从不更新它们，因此 `dirtyBytes > 0` 恒假，`msync` 分支是死分支（与「严重」第 3 条同源，此处只记死代码事实）。
- **描述**：两个符号给人「已经做了脏区跟踪」的错觉，实际既没有被调用也没有被赋值；`isNullPointer` 的判断值还是错的（`mmap` 失败返回 `MAP_FAILED`，不是 `nullptr`）。
- **建议**：删除 `isNullPointer`；要么在 `write` 里正确登记脏区，要么删掉两个字段和依赖它们的 `sync()` 分支，避免同类误读。

### [轻微][存量] `ChainedSegmentStream` 读到 EOF 不置 `closed`，`openNextFile` 有重复赋值

- **位置**：`f_io/src/SegmentedLog.cj:899-953`（`read`/`isClosed`/`close`）、`:966-972`（`openNextFile`）
- **来源**：存量
- **判据**：review-checklist §1（冗余语句）；§11（语义与注释 / 文档不符）
- **证据**：静态确定 —— `openNextFile` 在 `strictRead` 时先 `currentFile = Some(f)`，紧接着 `currentFile = f`（同一对象写两次，前者只在 `seek` 抛异常时有可观察差异）；`read` 在 `openNextFile()` 返回 false 时 `break` 并返回 `written`，不设置 `closed`，所以读完后 `isClosed()` 仍为 false，与 `:874` 的类注释「读完之后自动关闭当前文件」以及 README.md:526 的「读完后自动关闭」都不一致（文件句柄确实按段关闭了，语义上的 `closed` 没有）。
- **描述**：调用方用 `isClosed()` 判断是否读完会永远得到 false；`try (let s = log.openEntryStream(...))` 之外的「读到 EOF 就自动关」不成立。
- **建议**：EOF 时 `closed = true` 并复用 `close()`；删除 `openNextFile` 里多余的 `currentFile = Some(f)`。

### [轻微][存量] 重复逻辑：两个队列流子类的「读空 → 关闭 → 前进」，以及两处目录扫描 + 边界校验

- **位置**：`f_io/src/QueueInputStream.cj:35-46` 与 `:53-64`；`f_io/src/SegmentedLog.cj:506-550`（`scanSegmentsUnchecked`）与 `:817-870`（`durableDirectory`）
- **来源**：存量
- **判据**：review-checklist §2（换控制流的同语义实现 / 跨层复制导致行为漂移）
- **证据**：静态确定 ——
  1. 两个 `read` 都是「取队首 → 读 → 返回 0 时按 `closeOnEnd` 关闭 → 前进到下一个流」，差异只有「是否阻塞」与「是否保留 `current` 字段」；语义差异（阻塞 / 非阻塞、是否 close）可以参数化，现在却各写一份，并且已经漂移：非阻塞版靠 `peek`+`remove`（不原子，见「一般」），阻塞版靠 `current` 字段（丢弃未读完的流）。
  2. `scanSegmentsUnchecked` 与 `durableDirectory` 都做「`Directory.walk` → 剥 `.boundary`/`.tmp` → `parseSegmentIndex` → `SegmentBoundary.load` → 校验长度」，但校验口径不同：`durableDirectory` 会检查「committed 段文件存在且 `boundary.length ≤ size ≤ capacity`」，`scanSegmentsUnchecked` 只取 `boundary.length` 不校验文件长度。同一份规则写两遍，后续修改很容易只改一处。
- **描述**：上述漂移已经产生实际缺陷（非阻塞版的阻塞/丢流、扫描口径不一致）；合并能让两处共享同一套「段文件合法性」定义。
- **建议**：队列流抽一个 `nextStream()` + `drain(buffer, blocking)` 模板放到 `QueueInputStream`；目录扫描抽 `collectSegments(config, validate: Bool)`，`scanSegmentsUnchecked` 与 `durableDirectory` 都调用它，把「扫描」与「启动校验 / 收尾删除」分开。

### [轻微][存量] `SyncByteBuffer.readByte(timeout)` 的控制流把一个 `?Byte` 再包一层 `Option` 来循环，超时/虚假唤醒语义不清

- **位置**：`f_io/src/ByteBuffer.cj:214-229`
- **来源**：存量
- **判据**：review-checklist §10（可读性 / 控制流）；§12.1（条件等待）
- **证据**：静态确定 —— `while (let b <- buffer.readByte())` 里的 `buffer.readByte()` 返回 `?Byte`，`let b <-` 绑定出的是**内层的 `?Byte`**（外层 `Option` 永远 `Some`），因此循环体第一轮必然进入；`if (b.isSome()) return b` 承担了「成功返回」与「返回 None」两种出口，后面的 `else if (!end_.load() && !waited)` 只有在 `b` 为 `None` 时才可达，`waited` 又把它限制成「最多等一次」。`condition.wait(timeout:)` 的 `Bool` 返回值被丢弃（`sync_package_classes.md:8531-8571` 返回「是否被唤醒」），因此无法区分「超时」与「被通知但读不到数据」，一次虚假唤醒就会提前返回 `None`。
- **描述**：行为上勉强正确（等待一次后重试），但「等一次就放弃」与 `timeout` 参数的字面语义不一致：`readByte(timeout: 5s)` 在 1ms 处被无关通知唤醒时立刻返回 `None`。同类写法在 `read(buf, timeout)`（:230-248）里也出现（`while (let bytes <- buffer.read(buf))` 对一个 `Int64` 做不可反驳匹配）。
- **建议**：改成显式循环——`while (true) { if (let Some(b) <- buffer.readByte()) { return b }; if (end_.load()) { return None }; if (!condition.wait(timeout: timeout)) { return None } }`，并保留「已等待超过 timeout」的时间计算（用 `DateTime.now()` 差值），而不是靠 `waited` 布尔值。

### [轻微][存量] `ExtendPath.copy` 按目录深度递归，`srcPattern` 只转义了 `.`，其余正则元字符会改变匹配语义

- **位置**：`f_io/src/ExtendPath.cj:76-97`（目录递归）、`:29-58`（模式转正则）
- **来源**：存量
- **判据**：review-checklist §4（无界递归，深度由输入目录树决定）；§11（外部输入未校验）
- **证据**：静态确定 —— `private func copy(base:to:matched:)` 在目录分支里对每个子项调用 `fi.path.copy(base, ...)`，递归深度等于源目录层数，没有任何深度上限或环检测（`Directory.walk` 的实现是否跟随符号链接由标准库决定，此处不做断言）；模式转换只做了 `replace('.', "\\.")` 与 `*`→`.*`，`+ ( ) [ ] { } ^ $ |` 等字符原样进入正则（`pattern.regex(solid: false)`）。
- **描述**：复制很深的目录树（`node_modules`、构建产物）时递归深度由数据决定，按每层若干帧估算存在栈溢出风险（具体阈值需实测，标 `待确认`）；`srcPattern` 里包含 `[` 或 `(` 时正则会编译失败或匹配到意外路径。
- **建议**：改成显式栈（`ArrayList<Path>`）迭代遍历并加最大深度保护；模式转换先把所有正则元字符转义，再替换 `*`/`**`。

## 优化可行性方案

> 不是缺陷，是「还能更好」。以下均无改前/改后对照数据，`证据状态` 一律为「无基线（待验证）」，不进 `tasks.md`。

### [堆内存] `ByteBuffer` 的扩容与克隆：容量固定跳成 2.5×，`ByteBuffer(array)` 双份拷贝

- **现状**：`grow()`（`ByteBuffer.cj:135-137`）不管待写长度，一律 `reserve(1.5 × capacity)` → 新数组大小恒为 `2.5 × capacity`；`reserve` 的「原地压缩」分支只在 `1.5c + 活跃字节 ≤ c` 时命中，实际永远不命中。`init(array:)`（:34-40）先按 `array.size` 建数组再 `write(array)`，`write` 因 `>=` 判断必然再扩一次；`clone()`（:66-71）把整个底层数组（含已消费前缀与空闲尾部）复制给新实例。一次 `ByteBuffer(64 KiB 数据)` 的实际驻留约为 `160 KiB + 临时 160 KiB`。
- **方案**：`grow()` 改为 `reserve((woffset - roffset) + 需求)`，或先尝试原地压缩再扩容；`init(array:)` 直接持有入参数组（或 `Array<Byte>(array.size)` + 一次 `copyTo`）而不走 `write`；`clone()` 只复制 `[roffset, woffset)`。
- **预期**：单次扩容的峰值从 3.5× 有效数据降到约 2×；`clone`/`ByteBuffer(array)` 的常驻减半（按字节量可静态推算，未测）。
- **代价**：扩容次数可能增加（若按需精确扩容），需要保留「至少 1.5×」的下界避免逐字节扩容；`clone()` 语义从「同容量副本」变为「仅含未读数据」，需确认无调用方依赖 `capacity`。
- **验证**：`cjpm bench -O2` 跑「写入 N 条 64 KiB 消息」的分配量对照（`getAllocatedHeapSize` / `getUsedHeapSize` 峰值 + RSS），N 取 1k/10k。
- **证据状态**：无基线（待验证，不进 tasks）

### [堆内存] `ExtendPath.copyFile` 整文件读入内存

- **现状**：`ExtendPath.cj:73-74` 用 `File.readFrom(src.path)` 把整个源文件物化成一个 `Array<Byte>` 再 `File.writeTo`，单文件峰值 = 文件大小 × 2（源数组 + 写缓冲），没有大小上限。
- **方案**：改为 64 KiB~1 MiB 固定块循环 `read`/`write`（`f_io` 已有 `pipe` 可直接复用）。
- **预期**：单文件复制峰值从 O(文件大小) 降到 O(块大小)；复制 1 GiB 文件时省约 2 GiB 堆。
- **代价**：多一次循环与 syscall 次数；大文件复制耗时基本不变（受 I/O 限制）。
- **验证**：复制 1 GiB 文件期间采样 `getUsedHeapSize()` 峰值与 RSS；对比 `cjpm bench -O2` 的耗时中位数。
- **证据状态**：无基线（待验证，不进 tasks）

### [CPU] `ExtendByteBuffer` 每次类型化读写都新建一个 `Array<Byte>(len)`

- **现状**：`ExtendByteBuffer.cj:56` 与 `:109` 在 `read<T>` / `write<T>` 里各分配一个 2/4/8 字节数组；一个 16 字段的协议头解析就是 16 次小数组分配 + 16 次端序转换 + 16 次 `copyTo`。
- **方案**：读侧直接从 `BytePointerStream`/缓冲区指针按端序取值（或复用一个 8 字节线程内缓冲）；写侧先拼进调用方提供的目标数组，避免中间数组。
- **预期**：每次类型化读写省 1 次分配；按每消息 16 字段、10 万消息估算约省 160 万次小对象分配（未测）。
- **代价**：需要 `unsafe` 指针读取或新增 `readInto(buf, offset)` API；端序处理要自己实现位拼接。
- **验证**：`cjpm bench -O2` 对「解析 1 万条 64 字节头」做改前后对照，给中位数与离散程度，并看 GC 次数。
- **证据状态**：无基线（待验证，不进 tasks）

### [CPU] `RotatableBuffer.read` 逐字节拷贝

- **现状**：`RotatableBuffer.cj:109-111` 用 `for (i in 0..size) { bytes[i] = this[offset + i] }`，每次下标访问都走 `operator[]`（含两次边界比较 + 半窗分支），窗口 8192 B 的整块搬运是「按字节 + 每次分支」。
- **方案**：按半窗边界拆成最多 2 段，用 `Array.copyTo` 整块搬运（`buffer[0]`/`buffer[1]` 直接作为源）。
- **预期**：单次 `read` 的循环开销从 O(n) 次分支降到 2 次 `memmove`；对 1 MiB 的 multipart part 效果最明显（未测）。
- **代价**：多写十几行边界处理；语义需保持 `partEnd`、`remainder`、旋转时机不变，必须用现有 7 条 `RotatableBuffer_test` 用例回归。
- **验证**：`cjpm bench -O2` 跑 8 KiB 窗口 + 1 MiB/10 MiB 输入，对比 `read` 总耗时；同时用 `cjprof` 确认 `operator[]` 的自耗时占比再决定是否值得改。
- **证据状态**：无基线（待验证，不进 tasks）

### [CPU] `appendLock` 内做刷盘与目录扫描（锁粒度）

- **现状**：`SegmentedLog.append`（:276-303）在整个写入 + `syncImpl()` 期间持有 `appendLock`；`readView()`（:361-366）也在同一把锁内做 `Directory.walk` 与每段 44 B 边界读取（durable 模式还会再次 `durableBoundary` 校验整目录）。所有写线程与「打开读流」的线程串行在同一把锁上。
- **方案**：把刷盘移出临界区（锁内只完成 `mcopy` + `currentSize` 更新并记录「待提交位置」，由一个提交线程或批次调用方在锁外 `msync/fsync` 后发布边界）；`readView` 用「段列表快照 + 版本号」缓存，只在轮转/删除时失效，避免每次打开读流都全目录扫描。
- **预期**：多线程 append 的串行段从「mcopy + fsync」缩短为「mcopy」；`openEntryStream` 的每次调用从 O(段数) 次 `open/read` 降到 O(1)（未测）。
- **代价**：durable 模式的「提交顺序 = append 顺序」需要显式排队，否则会破坏「返回位置即已提交」的语义；段列表缓存要处理外部删除文件的情况（`scanSegments` 目前每次都重新读盘正是为了避免这个）。
- **验证**：`cjprof` 采线程状态（BLOCKED 占比）+ 8 线程 append 的吞吐对照；`openEntryStream` 用 1000 段目录测单次耗时 P50/P99。
- **证据状态**：无基线（待验证，不进 tasks）

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `appendLock` 内的 `file.flush()`（刷盘修复后会变成真实 `fsync`）成为写吞吐上限，多线程 append 完全串行 | `f_io/src/SegmentedLog.cj:276-303` | 单次 `append` 中 mcopy / sync 的耗时拆分、锁等待占比 | 8 线程各 append 10 万条 1 KiB，`cjprof` 采 self time + 线程 BLOCKED 时长；同时记录 `-O2` 下每秒条数 |
| 2 | `readView()` / `openEntryStream()` 每次全目录扫描 + 每段读边界，在段数上千时成为打开流的瓶颈 | `f_io/src/SegmentedLog.cj:361-366`、`:506-550` | 段数 100/1000/10000 时单次调用耗时 | 构造 1000 段目录，循环 `openEntryStream` 1000 次，分段计时取 P50/P99 |
| 3 | `RotatableBuffer.read` 的逐字节拷贝与 `indexOf` 的逐字节匹配在 1 MiB 以上 part 上占解析 CPU 的主要部分 | `f_io/src/RotatableBuffer.cj:43-69`、`:109-111` | `operator[]` / `indexOf` 的 self time 占比 | `cjprof record` 跑 10 MiB multipart 报文 100 次，看热点函数占比 |
| 4 | Linux 每段 `ftruncate + fallocate` 预分配 `maxFileSize`（默认 1 GiB）会让 RSS / 磁盘占用随段数线性上升 | `f_io/src/SegmentedLog.cj:729-748` | 预分配后 RSS 与磁盘实际占用、段数增长曲线 | 连续 rotate 100 段（每段 1 GiB 配置），采样 `RSS`、`du` 与 `/proc/<pid>/smaps` 的 mmap 区域 |
| 5 | `ByteBuffer` 的 2.5× 固定扩容使编解码场景堆峰值比有效数据高 1.5 倍以上 | `f_io/src/ByteBuffer.cj:135-151` | 实际分配量 / 峰值占比 | `cjpm bench -O2` 跑 10 万条消息编解码，采 `getAllocatedHeapSize` 与 `getUsedHeapSize` 峰值 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_io/README.md` | .md | ✅ | 见「一般」文档条目（flush/fsync、SyncByteBuffer.capacity、扩容公式、自动关闭） |
| 2 | `f_io/README_en.md` | .md | ✅ | 与中文版结构一致；`:448` 缺同步语义整段（见「一般」文档条目第 6 点） |
| 3 | `f_io/doc/spec/add-fmq-message-queue/specs/f-io/log-position-visibility/spec.md` | .md | ✅ | 归档变更规格；`LogPosition.seq/offset` 为 `public let`，与 `SegmentedLog.cj:43-53` 一致，自洽 |
| 4 | `f_io/doc/spec/fix-multipart-empty-part/design.md` | .md | ✅ | 归档设计；D1 代码片段与 `RotatableBuffer.cj:73-91` 逐行对应，D2/D3 的决策与当前实现一致 |
| 5 | `f_io/doc/spec/fix-multipart-empty-part/proposal.md` | .md | ✅ | 归档提案；「公开 API 不变」与实现一致（`read` 签名未变） |
| 6 | `f_io/doc/spec/fix-multipart-empty-part/specs/http-multipart/spec.md` | .md | ✅ | 归档规格；空 part 场景由 `RotatableBuffer_test` 的延迟跳过语义支撑 |
| 7 | `f_io/doc/spec/fix-multipart-empty-part/specs/io-rotatable-buffer/spec.md` | .md | ✅ | 归档规格；「读到 sectionEnd 当次不消费分隔符」与 `RotatableBuffer.cj:76-91` 一致 |
| 8 | `f_io/doc/spec/fix-multipart-empty-part/tasks.md` | .md | ✅ | 归档任务清单（全 `[x]`）；提到的 37 条测试为当时口径，当前 `RotatableBuffer_test.cj` 7 条用例 |
| 9 | `f_io/src/ByteBuffer.cj` | .cj | ✅ | `ByteBuffer` + `SyncByteBuffer`；见严重 #4、#7 与轻微 #4 |
| 10 | `f_io/src/BytePointerStream.cj` | .cj | ✅ | 见严重 #5、一般 #6 |
| 11 | `f_io/src/DummyInputStream.cj` | .cj | ✅ | 空实现为有意的 Null Object（README 已说明），不计 §3 |
| 12 | `f_io/src/DummyOutputStream.cj` | .cj | ✅ | 同上；`throwIfNeed` 由 `write`/`flush` 共用，无重复缺陷 |
| 13 | `f_io/src/ExtendByteBuffer.cj` | .cj | ✅ | 见严重 #1；12 读 12 写均为一行转发，属接口展开 |
| 14 | `f_io/src/ExtendPath.cj` | .cj | ✅ | 见一般 #8、轻微 #5 |
| 15 | `f_io/src/MMapFile.cj` | .cj | ✅ | 见严重 #2、#3，一般 #4、#5，轻微 #1 |
| 16 | `f_io/src/QueueInputStream.cj` | .cj | ✅ | 见严重 #6，一般 #1、#2，轻微 #3 |
| 17 | `f_io/src/RotatableBuffer.cj` | .cj | ✅ | 见一般 #3 |
| 18 | `f_io/src/RotatableBuffer_test.cj` | .cj | ✅ | 7 条用例覆盖 EOF / 空流 / 半窗 / 分隔符延迟跳过；不覆盖短读、`addOffset` 越界 |
| 19 | `f_io/src/SegmentBoundary.cj` | .cj | ✅ | 见严重 #3、#8，一般 #7 |
| 20 | `f_io/src/SegmentedLog.cj` | .cj | ✅ | 见严重 #3、#8，一般 #4、#9、#10，轻微 #2、#3 |

合计：`.cj` 12 个 / `.md` 8 个 / 共 20 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 15 | 正确性 9（严重 #1/#2/#4/#5/#6/#7/#8、一般 #3/#8）；设计 2（`LogConfig` 校验、`SegmentBoundary` 对目录的处理）；语言特性 3（`Option` 双层绑定、`AtomicInt64` 与普通 `var` 混用、`mut prop` 无校验）；可读性 1（`SyncByteBuffer.readByte`）；安全性 0（无外部输入拼 SQL / 无凭据；`ExtendPath` 正则元字符注入已并入轻微 #5） |
| §1 死代码 | 2 | `MMapFile.isNullPointer` 全仓 grep 仅命中定义行；`dirtyStart`/`dirtyBytes` 仅有自赋值、写入路径从不更新（轻微 #1）。其余 private/internal 符号逐个搜过：`ByteBuffer.grow/seek`、`ByteBuffer.reserve` 内 `copy`、`ExtendByteBuffer.read/write<T>`、`ExtendPath.copyFile/copy`、`BytePointerStream.opsize/access/pointerOffset/check*`、`MMapFile.isZeroFile/extract/check*/unmap`、`SegmentBoundary.put/get/checksum/MAGIC`、`SegmentedLog` 的 `scanSegments/removeIndexedFile/deleteSegmentFile/sortByIndex/maxSegmentIndex/nextSegmentIndex/currentSegmentIndex/parseSegmentIndex/truncateFile/releaseMapping/releaseAfterFailure/ensureHealthy` 均有调用者；`QueueInputStream` 的 `public add/queue` 虽在非 public 顶层类中，但被子类使用；`LogConfig`/`SegmentFile` 的 internal 字段均被读取；顶层 `public` 类型（`ByteBuffer`、`SyncByteBuffer`、`MMapFile`、`SegmentedLog`、`ChainedSegmentStream`、`RotatableBuffer` 等）对外可达，按硬原则一不判死代码 |
| §2 重复逻辑 | 2 | 两个队列流子类的「读空→关闭→前进」、两处目录扫描 + 边界校验（轻微 #3）。另逐对比较了 `ExtendByteBuffer` 的 24 个一行转发（刻意展开的 API 面，不算缺陷）、`MMapFile.checkWritable/checkReadable` 与 `BytePointerStream` 同名函数（异常类型与文案不同，属必要差异）、`removeCreatedBefore/After` 等 7 个谓词（共用 `removeSegmentsMatching`） |
| §3 空实现 | 2 | `MMapFile.flush()` 承诺同步但实际空转（严重 #3）；`SegmentBoundary.syncDirectory` 调用空 `flush`（同条）。有意的空实现不判：`ByteBuffer/SyncByteBuffer.flush(){}`（内存缓冲无下游）、`DummyInput/OutputStream` 的 close、`@When[os != "Linux"]` 的 `initFileMapping`/`unmapFile`、`truncateFile` 的吞异常（有注释与理由）、`durableStep` 与 `SegmentReadView.check` 的默认空闭包 |
| §4 栈溢出 | 1 | `ExtendPath.copy` 的目录递归深度由输入目录树决定（轻微 #5，阈值待实测）；`SegmentBoundary.ensureDirectory` 的递归深度 = 路径段数，用户配置量级，不判 |
| §5 OOM | 1 | `ExtendPath.copyFile` 整文件读入，峰值 = 文件大小 × 2（「优化可行性方案」第 2 条）；`ByteBuffer` 无上限扩容属其设计（文档写明自动扩容），`SegmentedLog.append` 有 `LogRecordTooLargeException` 与 `maxFileSize` 双重上界，`ChainedSegmentStream` 按段大小有界 |
| §6.1 热点瓶颈 | 0 | 本轮没有 `cjprof` / `cjpm bench` 数据；`append`、`readView`、`RotatableBuffer.read` 三处只作为「待验证假设」第 1/2/3 条，未计入发现 |
| §6.2 大粒度锁 | 1 | 结构命中：`appendLock` 临界区包含刷盘调用（当前是空转的 `file.flush()`，修复后将是真实 `fsync`）与目录扫描（优化方案第 5 条）。单次持有时长、竞争线程数缺失，不升级为缺陷 |
| §6.3 并发串行 | 0 | 单写者顺序日志的串行是本模块的设计前提（README.md:621-631 已声明），无「spawn 后立刻 get」形态；`readView` 的串行面已并入 §6.2 |
| §6.4 低效算法 | 2 | `RotatableBuffer.read` 逐字节拷贝 + `indexOf` 逐字节匹配（优化方案第 4 条）；`ByteBuffer.grow` 固定 1.5× 与「必然全量复制」（优化方案第 1 条）。`sortByIndex` 的 O(n²) 插入排序在段数级别可忽略，不计 |
| §7 降堆内存方案 | 2 | `ByteBuffer` 扩容/克隆、`ExtendPath.copyFile` 流式化（均无基线，标「待验证」） |
| §8 降 CPU 方案 | 3 | 类型化读写临时数组、`RotatableBuffer` 逐字节拷贝、锁内刷盘/扫描 |
| §9 local mode 可行性 | 1 | 唯一候选是 `SegmentBoundary.bytes()` 的 44 B 临时数组与 `ExtendByteBuffer` 的小数组，二者都在函数内创建且不逃逸，但收益量级太小、`getAllocatedLocalObjectSize` 的统计代价会盖过收益，判「不划算」；`SegmentBoundary.load` 的 44 B 缓冲同样可忽略。没有前后峰值数据，不作为方案 |
| §11 现有代码的 BUG（存量） | 18 | 严重 8 条 + 一般 10 条全部为存量缺陷；本轮读到的 20 个文件里，`ByteBuffer`、`BytePointerStream`、`QueueInputStream`、`RotatableBuffer`、`MMapFile`、`SegmentBoundary`、`SegmentedLog`、`ExtendByteBuffer`、`ExtendPath` 的边界与空值路径已逐函数核对 |
| §12 并发安全与锁粒度 | 3 | `SyncByteBuffer.end()` 的 `notify` 与多读者（严重 #7）；`BytePointerStream` 的 `load`→`fetchAdd` 竞态（一般 #6）；`NonblockingQueueStream` 的 `peek`→`remove` 非原子（一般 #1）。`SegmentedLog` 的 `closed` CAS + `appendLock` 双检、`oldFilesLock` 对称加锁核对后未发现新问题；`MMapFile` 类注释已声明非线程安全 |
| §14 功能完备性与 README 覆盖 | 3 | `SyncByteBuffer.capacity` 文档承诺但未实现；durable 模式的「临时边界改名保留」未实现（严重 #8）；`openEntryStream` 的「读完自动关闭」未实现（一般 #10 第 5 点）。`MMapProtArray`、`Array.combine()`、`DEFAULT_MMAP_BYTES` 等「其他公开 API」条目均存在 |
| 文件覆盖（§13 等） | 20/20 | 无缺失文件 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 8 |
| 一般 | 10 |
| 轻微 | 5 |
| 优化方案（堆内存 / CPU） | 2 / 3 |

## 总评

这部分的代码分成两类质量层次，风险也集中在两处。

**`SegmentedLog` / `SegmentBoundary` / `MMapFile`（持久化层）是目前最危险的区域。** 三个严重问题叠在一起：`File.flush()` 在仓颉标准库里根本是空函数，于是 `syncInterval`、`log.sync()`、`durableBoundary` 的「写完再发布边界」全部没有落盘保证，而 README 反复承诺 `msync + fsync`；`MMapFile` 的构造分支写反，只读映射和大文件映射 100% 抛异常；durable 模式一旦在首次发布边界的中途崩溃，残留的 `*.boundary.tmp` 会让日志目录永久打不开。再加上 mmap 失败返回值不校验、`close()` 非幂等，这一层的「持久」「可恢复」两个承诺都需要在修复后重新验证，不能只看单测绿色。修复优先级建议：刷盘语义 → 临时边界启动路径 → `MMapFile` 构造 → mmap 失败校验。

**`ByteBuffer` / `BytePointerStream` / `QueueInputStream` / `ExtendByteBuffer`（流与缓冲层）是「易触发但影响局部」的问题。** `ByteBuffer.write` 对大于 2.5× 容量的数组直接抛越界，是最可能被日常代码撞到的缺陷；`ExtendByteBuffer` 的多字节读全返回 0，是对外 API 的静默数据错误（仓内暂无人调用，危险在于下游会以为读到了真值）；`BytePointerStream` 重复 `free` 与 `SyncByteBuffer.end()` 只唤醒一个读者，分别对应堆损坏与线程永久挂起；两个队列流各有一个「非阻塞变成死循环 / 阻塞流丢数据」的语义缺陷，且 README 的描述会让使用者正好踩上。

文档面（`README.md` / `README_en.md`）的问题不是文笔，而是把「没有落盘的写入」写成「已 fsync」、把不存在的 `SyncByteBuffer.capacity` 写成公开属性——属于会把使用者带进数据丢失或编译失败的那一类，应与严重项一起修。归档的 `doc/spec/**` 四份规格与当前 `RotatableBuffer` 的延迟跳过实现逐行自洽，无需改动。

存量缺陷共 23 条（严重 8 / 一般 10 / 轻微 5），是否纳入修复由用户决定；本轮只给结论与修法，未改任何源码。性能类结论均无测试数据，全部停留在「优化可行性方案」与「待验证假设」，未写成收益结论。

（范围外提示：`f_http/src/MultipartFormDataParser.cj:81` 直接使用 `RotatableBuffer`，本报告发现的短读当 EOF 与分隔符搜索越界会通过该调用方影响 multipart 解析；`f_mvc/src/FileDownload.cj:36` 使用 `SyncByteBuffer` 作管道，受 `end()` 唤醒语义影响。两处不在本模块统计内。）
