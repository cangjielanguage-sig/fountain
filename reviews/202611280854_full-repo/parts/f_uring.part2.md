# f_uring 模块审查报告

> **模块第 2/2 部分**：只覆盖 `files/f_uring.part2.txt` 列出的 17 个文件（`src/base/` 5 个：`uring_registered_buffers.cj`、`uring_registered_files.cj`、`uring_ring.cj`、`uring_sqe.cj`、`uring_types.cj`；`src/lockfree/` 6 个；`src/tests/` 6 个）。其余 `src/base/` 文件（`uring.cj`、`uring_ffi.cj`、`uring_cqe.cj`、`uring_barrier.cj`、`uring_buf_ring.cj`、`uring_flexible.cj`、`uring_future.cj`、`uring_pool.cj`、`uring_params_builder.cj`、`uring_constants.cj`、`uring_exception.cj`）与 `IOUringStream.cj`、`README*.md`、`doc/**` 由第 1 部分产出（`parts/f_uring.part1.md`），本报告只在需要判定本部分语义时把它们当上下文引用，不对其下结论。

- **审查日期**：2026-11-28
- **模块路径**：`f_uring`（本部分 17 个 `.cj` + 0 个 `.md`）
- **基线**：工作区快照（master 与 sts/1.3.x 同一提交 `120fd2542`，`git diff` 为空 ⇒ 全部记「存量」）
- **审查重点**：原生内存与数组固定、异步提交的并发正确性、close 幂等、错误路径回收（本模块专项）+ 死代码 / 重复逻辑 / 存量 BUG
- **报告版本**：v1（第 2/2 部分，与 `parts/f_uring.part1.md` 合并为 `docs/review/2026-11-28/f_uring_v2.md`）

## 发现

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

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `ioUringPrep*` 的整结构体 RMW 占 read 路径自耗时的主要部分 | `src/base/uring_sqe.cj:152-692` | 该段自耗时占比（现在只有测试里打印的分段 ns，无 profile、无改前改后对照） | `cjprof record` 跑 `microReadPathBreakdown`（1 MB / 4 KB / 256 轮），对比只写必要字段的版本，`-O2`，≥5 轮取中位数 |
| 2 | `ringPtr.read()` 的结构体拷贝让收割线程成为写路径瓶颈 | `src/lockfree/cqe_reaper.cj:57,113,147`、`:84` | 收割线程 CPU 占用与每 CQE 处理成本 | `cjprof` 采样收割线程；同时记录 `reap()` 返回值与 `allocSlot` 的 10 μs 轮询次数 |
| 3 | 槽位耗尽时 `allocSlot` 的 10 μs 轮询拉高写尾延迟（P99） | `src/lockfree/lockfree_uring.cj:105-113` | 写延迟 P50/P95/P99 与轮询次数 | 压测 4 写线程 × 固定 64 槽位，采集每次 `allocSlot` 的耗时分布 |
| 4 | 固定缓冲区路径的 `LambdaCompletionCallback` 每次写都新分配一个对象 | `src/IOUringStream.cj:326-328`（第 1 部分范围，仅作线索） | 分配量与 GC 次数 | `getAllocatedHeapSize()` 增量 + 写入 10 万块，对照预建回调数组 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `src/base/uring_registered_buffers.cj` | .cj | ✅ | 发现 1 条严重（`update` 的 `data` 恒指向首元素）、1 条一般（`!sparse` 分支）、1 条轻微（示例少传参） |
| 2 | `src/base/uring_registered_files.cj` | .cj | ✅ | 同形态的 `!sparse` 重复分支；`update` / `updateBatch` / `allocIndex` 逐条核对无误 |
| 3 | `src/base/uring_ring.cj` | .cj | ✅ | 死字段 `initFlags`；`peekCQE` 与 reaper 重复；`close` 幂等但无并发保护（文档已声明非线程安全，不计缺陷） |
| 4 | `src/base/uring_sqe.cj` | .cj | ✅ | 15 个 prep 函数逐条对照 liburing 字段语义（`timeout` / `accept` / `connect` / `openat` / `cancel` 均正确）；指针步长受 `IOUringSQE` 尺寸影响 |
| 5 | `src/base/uring_types.cj` | .cj | ✅ | 除 `IOUringSQE` 缺 8 字节外，其余 15 个结构体逐字段与 liburing 布局一致 |
| 6 | `src/lockfree/completion_slots.cj` | .cj | ✅ | 注释与布局不符、`slotBits`/`genShift` 冗余；`invokeAndRelease` 判重不足以抗重复收割 |
| 7 | `src/lockfree/cqe_reaper.cj` | .cj | ✅ | head 读-改-写非原子（严重项的一部分）；`advance`/`advanceBatch`/`peekCQE` 与 base 层重复 |
| 8 | `src/lockfree/lockfree_promise.cj` | .cj | ✅ | 无超时；`completed`/`value` 的写序正确，无丢失唤醒 |
| 9 | `src/lockfree/lockfree_uring.cj` | .cj | ✅ | 严重 2 条（`getSQE` 空指针、并发收割）+ 一般 3 条（submit 返回值、close、allocSlot 无退出） |
| 10 | `src/lockfree/slot_allocator.cj` | .cj | ✅ | CAS 分配逻辑正确（越界位在最高位，回滚返回 None 不会漏掉同 word 的低位空槽）；`release` 缺状态校验 |
| 11 | `src/lockfree/sqe_pool.cj` | .cj | ✅ | 索引分配/回滚与 flush 清零的复合操作问题；`commitSlot` 忽略 index |
| 12 | `src/tests/integration_test.cj` | .cj | ✅ | 并发用例本身会触发 `allocSlot → reap` 与主线程 `reap` 并行；`ok` 未断言 |
| 13 | `src/tests/iouring_stream_perf_test.cj` | .cj | ✅ | 计时口径含构造/析构；静默 `catch` |
| 14 | `src/tests/iouring_stream_read_micro_perf_test.cj` | .cj | ✅ | 两处 `acquireArrayRawData` 未释放 |
| 15 | `src/tests/iouring_stream_test.cj` | .cj | ✅ | 12 个用例与实现一致，未发现断言错误 |
| 16 | `src/tests/lockfree_test.cj` | .cj | ✅ | `testSQEPreallocatorConcurrent` 是唯一会调 `sqePool.allocSlot()` 的地方，因此测不到 `IoUringLockFree.getSQE` 的空指针问题 |
| 17 | `src/tests/uring_test.cj` | .cj | ✅ | `@Expect(a, b)` 两参形式已核对为「相等断言」（`std/unittest/unittest_samples/unittest_basics.md:144`），不是消息参数，无误用 |

合计：`.cj` 17 个 / `.md` 0 个 / 共 17 个，全部读完。

## 覆盖自检

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
| 严重 | 3 |
| 一般 | 9 |
| 轻微 | 8 |
| 优化方案（堆内存 / CPU） | 1 / 1 |

（不含「待验证假设」4 条；本部分统计，最终以与第 1 部分合并后的模块统计为准。）

## 总评

本部分的风险集中在**无锁层的契约与并发**，不在基础封装：

三处阻塞项都是「看起来实现了、实际不成立」。`IoUringLockFree.getSQE` 返回空指针是最直接的一条——`README.md:495` 与类注释把 `allocSlot → getSQE → prep → commitSlot → flush` 写成主推提交流程，但 `SQEPreallocator.sqeSlots` 只在 `allocSlot()` 里被填充，而 `IoUringLockFree.allocSlot()` 用的是另一个分配器，这条路径从写下来那天起就走不通（生产路径 `IOUringStream.writeNormal` 恰好绕开了它，所以一直没暴露）。`RegisteredBuffers.update` 的 `data` 恒指向 `iovecs[0]`，注册 index>0 的缓冲区时内核拿到的是槽位 0 的描述，而本地副本是正确的、`getIOVec` 验证不出来——这类「校验路径与出错路径不一致」的 bug 最难在测试里发现。并发收割那条则是把「CQ 由单线程收割」的假设写进了注释，却在 `allocSlot` 里又让任意写线程去 `reap()`，两个线程同时读-改-写 CQ head 会让回调重复执行，固定缓冲区模式下直接是数据互相覆盖。

`base/` 部分的封装质量明显更好：15 个 `ioUringPrep*` 的字段映射逐条对照 liburing 只有 `IOUringSQE` 尺寸这一处 ABI 偏差（且唯一受影响的 `ioUringGetSQE` 目前无调用者），`RegisteredFiles` 的三条更新路径、`IoUring` 的 CQE 索引（含 CQE32 位移）都与内核/库语义一致，错误路径的 `malloc`/`free` 也都成对。

建议排期：三条严重项先定「修 / 收窄契约」二选一（`getSQE` 那条如果短期不修，应把 `getSQE/commitSlot/flush` 从 README 与类注释里删掉并标注 `@Deprecated`，否则下个使用者必踩）；`submitAsync` 吞 submit 返回值与 `allocSlot` 无退出条件这两条一起改（都是「错误路径把调用方挂死」）；其余一般项可随下一次无锁层重构一起处理。存量 12 条（3 严重 + 9 一般）是否纳入修复待用户决定。

**范围外提示**（`src/IOUringStream.cj`，第 1 部分）：`acquireArrayRawData` 在 `:205/:253/:293/:318` 四处同样未 `releaseArrayRawData`；`:300/:341` 丢弃 `writeRing.submit()` 的返回值，与本报告「submitAsync 吞返回值」同源。
