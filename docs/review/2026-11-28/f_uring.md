# f_uring 模块审查报告

> **本文件是抽样版（v1）**：只读了部分文件，已被 `f_uring_v2.md`（全量、逐文件覆盖）取代；结论以 v2 为准。


- **审查日期**：2026-11-28
- **模块路径**：`f_uring`（37 个文件：29 个 .cj + 8 个 .md；全部声明带 `@When[os == "Linux"]`）
- **基线**：工作区快照（sts/1.3.x 工作区，master 同提交 120fd2542，无分支差异）
- **审查重点**：原生内存与数组固定的生命周期、异步提交的并发正确性、`close()` 幂等、错误路径的资源回收
- **报告版本**：v1（由主 Agent 直接审查；`IOUringStream.cj` 的构造/读写/关闭路径与 `RegisteredBuffers` 逐段读，FFI 常量与 SQE/CQE 声明为机械检索）

## 发现

### [严重][存量] 4 处 `acquireArrayRawData` 没有任何 `releaseArrayRawData` 配对

- **位置**：`f_uring/src/IOUringStream.cj:205`（`readNormal`）、`:253`（`readFixed` 读回）、`:293`（`writeNormal`）、`:318`（`writeFixed` 拷贝源）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §5（无界增长 → OOM）、§11（资源释放不对称）、`mem §`（原生内存与 GC pin）
- **证据**：静态确定 —— 全模块 `grep -rn "releaseArrayRawData" f_uring/` **零命中**，而 `acquireArrayRawData` 在 `IOUringStream.cj` 出现 4 次
- **描述**：`acquireArrayRawData` 会把数组固定（pin）并把裸指针交给内核；不 `release` 就等于**每次 read / write 泄漏一次固定**：数组对象既不能被 GC 回收也不能被移动，其内部存储永久驻留。一个长连接流按 1KB/次、10k 次/秒估算，几小时内就会把堆顶穿（且 `cjprof` 里表现为「Array 常驻」而非明显泄漏点）。写路径上更微妙：内核异步读这块内存，正确做法是「CQE 回收后再 release」，当前是「永不 release」——正确性没坏，但泄漏确定存在
- **建议**：把「固定句柄」随 SQE 的 `user_data` 一起带进完成回调，在 CQE 处理时 `releaseArrayRawData`；读路径同样在拷贝回用户 buffer 后立即释放

### [严重][存量] 读写偏移量在锁外做读-改-写，并发写会互相覆盖

- **位置**：`f_uring/src/IOUringStream.cj:276-277`（`write`：`let currentOffset = writeOffset; writeOffset += UInt64(bufSize)`）、`:192`（`read`：`let currentOffset = readOffset`）、`:219/:256/:303/:307/:345/:350`（回滚）
- **来源**：存量
- **判据**：review-checklist §12.1（检查-然后-写入 / 非原子自增）
- **证据**：静态确定 —— `synchronized(writeMutex)` 在 `writeNormal` / `writeFixed` **内部**（`:289`、`:330`），而偏移量的读取与自增发生在调用它们之前（`:276-277`），锁不覆盖这段
- **描述**：两个线程同时 `write` 时会读到同一个 `writeOffset`：两次 `io_uring_prep_write` 提交到**同一个文件偏移**，后完成的覆盖先完成的（数据丢失）；`writeOffset +=` 本身也是非原子的读-改-写，可能只前进一次。`read` 侧同理会把同一段文件内容读两遍
- **建议**：偏移量的「取号 + 前进」放进 `writeMutex` / `readMutex`；或改用 `AtomicUInt64.fetchAdd` 直接取号

### [严重][存量] `close()` 没有幂等标志，重复或并发关闭会 double free

- **位置**：`f_uring/src/IOUringStream.cj:399-431`（`close`）
- **来源**：存量
- **判据**：review-checklist §11（重复关闭）、§12.1（检查-然后-写入）
- **证据**：静态确定 —— 幂等性只靠 `if (!writeRing.isClosed())` / `if (!readRing.isClosed())` 两个**别处状态**做门；最后的 `if (useFixedBufs && !fixedBufsPtr.isNull()) { LibC.free(fixedBufsPtr) }` 在**任何**保护之外，且 `fixedBufsPtr` 释放后没有置空
- **描述**：try-with-resource 正常关闭 + 退出钩子再关一次（`f_tui`/`fprobe` 都有这种双路径），或两个线程同时 `close()`，都会让 `LibC.free(fixedBufsPtr)` 执行两次 → 堆破坏（表现为随机的 `SIGSEGV` / `malloc(): invalid size`），并且 `io_uring_queue_exit` 被重复调用
- **建议**：加 `AtomicBool closed` 做 CAS 门；`free` 后把指针置空（`fixedBufsPtr` 改为 `var`），`IoUring.close()` 自身也应幂等

### [一般][存量] 构造失败路径不回收已分配资源，`LibC.malloc` 空指针也不检查

- **位置**：`f_uring/src/IOUringStream.cj:101-134`
- **来源**：存量
- **判据**：review-checklist §11（异常路径资源泄漏）、§4/§5（空指针）
- **证据**：静态确定 —— `fixedBufsPtr = LibC.malloc<UInt8>(...)` 后没有判空；`RegisteredBuffers(writeRing, …)` / `RegisteredBuffers(readRing, …)` 在注册失败时抛 `IoUringException`（`uring_registered_buffers.cj:93-96`），此时已创建的 `writeRing`、已 malloc 的 `fixedBufsPtr` 都不会释放（构造函数里没有 try/catch）
- **描述**：内核不允许注册（`RLIMIT_MEMLOCK` 不足、`io_uring` 被 seccomp 禁用）时，异常向上抛，但进程已经泄漏了两个 ring fd 与一块 `fixedBufCount × fixedBufSize` 的堆内存；若 `malloc` 返回空指针，`iovBase = CPointer(base)` 会拿空指针 + 偏移去注册，后续读写直接 SIGSEGV
- **建议**：构造期用 try/catch 逆序回收；malloc 结果判空并抛「内存不足」而不是继续

### [一般][存量] 写失败静默回滚偏移，调用方无法得知数据没写出去

- **位置**：`f_uring/src/IOUringStream.cj:286-309`（`writeNormal`：无 slot / 无 SQE 时 `writeOffset = currentOffset`）、`:311-355`（`writeFixed` 同型）
- **来源**：存量
- **判据**：review-checklist §3（静默失败）、§11
- **证据**：静态确定 —— `write` 返回 `Unit`；`allocSlot()` 返回 `None`、`getSQE()` 返回 `None` 时只把偏移量回退，没有日志、没有异常；`writeFixed` 还会先把用户数据 `mcopy` 到注册缓冲区再丢弃
- **描述**：队列满或 slot 耗尽时（高并发下的正常状态），这一次 `write` 什么都没做，但 `IOStream.write` 的签名让调用方以为已写入。上层若不自己核对文件长度，就会得到「少写一段」的文件
- **建议**：`write` 改为返回写入字节数或抛 `IoUringException`；至少 `WARN` 一次并带 slot/SQE 计数

### [轻微][存量] `close()` 静默吞掉注销失败

- **位置**：`f_uring/src/IOUringStream.cj:415-424`（两处 `try { rb.close() } catch (_: Exception) {}`）
- **来源**：存量
- **判据**：review-checklist §3（静默吞异常）
- **证据**：静态确定 —— 空 catch
- **描述**：`io_uring_unregister_buffers` 失败（ring 已退出）时无任何痕迹，如果失败原因是「ring 状态异常」，排查时没有任何线索
- **建议**：`catch` 里 `debug` 一条带 fd/errno 的日志

## 优化可行性方案

### [内存] 固定缓冲区的索引分配与失败回滚可以前置

- **现状**：`writeFixed` 先 `fixedBufAllocator.alloc()` 再 `mcopy` 用户数据，最后才 `lf.allocSlot()`；slot 取不到时刚拷贝的数据被丢弃（`:312-351`）
- **方案**：先取 slot，再分配固定缓冲并拷贝，失败路径只剩「释放 slot」
- **预期**：高并发下省掉一次无用的整块 `mcopy`；收益取决于 slot 耗尽的频率
- **代价**：slot 持有时间略微变长
- **验证**：`cjpm bench -O2` 跑固定并发（如 8 线程 × 100k 次 4KB 写），比较 `write` 的 p50/p99 与 `mcopy` 调用次数
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 数组固定泄漏的实际增速 | `IOUringStream.cj:205/253/293/318` | 每次 read/write 的常驻字节增量 | 循环 100 万次 4KB 读写后读 `getUsedHeapSize()` / RSS，对比次数；或数 `acquireArrayRawData` 返回值是否被 GC 统计为常驻 |
| 2 | 注册缓冲区模式相对普通模式的吞吐收益是否仍成立 | `IOUringStream.cj:194-198` | 两种模式吞吐/延迟中位数 | `cjpm bench -O2`，4KB 与 64KB 两档，各 10 轮 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1–8 | `f_uring/README.md`、`README_en.md`、`doc/**`（6 个） | .md | 部分 | README 前 55 行（核心 API 表）已读；其余 7 个未读 |
| 9 | `f_uring/src/IOUringStream.cj` | .cj | ✅（主体） | 构造/read/write/close 逐段读；见发现 1–6 |
| 10 | `f_uring/src/base/uring_registered_buffers.cj` | .cj | ✅（部分） | 构造与 `close` 段；iovec 本地拷贝正确 |
| 11 | `f_uring/src/base/uring_buf_ring.cj` | .cj | 部分 | 抽查 `malloc/free` 配对（1:1） |
| 12 | `f_uring/src/base/uring_ring.cj` | .cj | 未读 | ring 创建/退出（`IoUring.close` 幂等性未核对） |
| 13 | `f_uring/src/lockfree/lockfree_uring.cj` | .cj | 未读 | 无锁收割器 |
| 14 | 其余 15 个 .cj（`uring_sqe` / `uring_cqe` / `uring_ffi` / `uring_constants` / `uring_types` / `uring_flexible` / `uring_barrier` / `uring_pool` / `uring_registered_files` / `tests/*` …） | .cj | 未读 | FFI 常量与 SQE/CQE 访问器，本轮只做 `unsafe` / `malloc` / `free` 的机械检索（`uring_barrier` 的原子序正确） |

合计：`.cj` 3 个逐段读完 + 1 个抽查 / 25 个未读；`.md` 1 读 7 未读。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 3 | 发现 1/2/3 |
| §1 死代码 | 0 | 仅对已读文件做了 `private` 符号调用检查（`checkNotClosed` / `indexOf` 等均有调用者）；未读文件未做 |
| §2 重复逻辑 | 1 | `readNormal`/`readFixed` 与 `writeNormal`/`writeFixed` 两两高度同构（未单列，属结构性重复） |
| §3 空实现 | 2 | 发现 5（静默丢写）、轻微 1（空 catch） |
| §4 栈溢出 | 0 | 无递归 |
| §5 OOM | 1 | 发现 1（数组固定泄漏） |
| §6.1 热点瓶颈 | 0 | 无 profile 数据；待验证假设 2 |
| §6.2 大粒度锁 | 0 | `writeMutex` 只包 SQE 操作，粒度合理 |
| §6.3 并发串行 | 0 | 写路径由一个锁串行，读路径每线程独立 ring |
| §6.4 低效算法 | 1 | `writeFixed` 先拷贝后取 slot（优化方案） |
| §7 降堆内存方案 | 0 | 主要问题是泄漏而非占用，已在发现 1 覆盖 |
| §8 降 CPU 方案 | 0 | 需 bench |
| §9 local mode 可行性 | 0 | 无函数内临时大对象（传的是用户 buffer 与注册缓冲区） |
| §11 现有代码的 BUG（存量） | 5 | 发现 1–5 |
| §12 并发安全与锁粒度 | 2 | 发现 2（偏移量）、3（close 竞态） |
| §14 功能完备性与 README 覆盖 | 0 | README 只读了前 55 行，未逐项对照 |
| 文件覆盖（§13 等） | 4/37 | 未读项见上表 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 3 |
| 一般 | 2 |
| 轻微 | 1 |
| 优化方案（堆内存 / CPU） | 1 / 0 |

## 总评

这层是对 liburing 的直接封装，结构清楚（双 ring、注册缓冲区、无锁收割器分层），但**生命周期纪律**不过关：数组固定只取不放、偏移量在锁外自增、`close()` 靠别人的状态做幂等——三条都属于「压测跑一会儿才炸」的类型，且都落在 `IOUringStream` 这一个类里。若 `IOUringStream` 只在 demo 里用，影响面有限；但只要它被当作通用 `IOStream` 交给 `f_io` 的流式 API，上述三条都会在生产暴露。存量 6 条（严重 3 / 一般 2），是否纳入修复待用户决定。
