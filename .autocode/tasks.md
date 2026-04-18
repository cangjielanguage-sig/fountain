# 前置任务
1. 确认当前路径
pwd
2. 确认工作路径
$(pwd)/f_io # 所有的编译工作都在这个路径
$(pwd)/f_io/src/uring # 本任务的代码都在这个路径

# 任务
在f_io/src/uring/ 添加仓颉的liburing ffi，并用仓颉class实现ffi的薄封装。
以极致性能为第一优先级，按照下面的阶段性任务实现liburing ffi，把代码添加到f_io/src/uring，包名是fountain::f_io.uring。
每个.cj文件开头都要添加版权声明，版权声明的具体内容可以参考项目中的其它.cj文件，照搬即可。
每完成一阶段任务都要在./f_io执行cjpm build`确认没有编译错误，并在相应阶段性任务的标题后面标记为已完成，然后总结经验教训
✅ 表示已经完成的任务，从第一个未完成的任务继续
---

# 阶段一：基础设施与FFI声明 ✅

## 任务 1.1：创建目录结构与编译配置 ✅
- 在 `f_io/src/uring/` 创建目录
- 更新 `f_io/cjpm.toml`，为 Linux 目标添加 `-luring` 链接选项
- 创建 `f_io/src/uring/uring_constants.cj` 文件

## 任务 1.2：实现常量定义 ✅
- 在 `uring_constants.cj` 中定义所有 io_uring 常量：
  - `IORING_SETUP_*` 初始化标志
  - `IORING_ENTER_*` 进入标志
  - `IOSQE_*` SQE 标志
  - `IORING_CQE_F_*` CQE 标志
  - `IORING_OP_*` 操作码
  - `IORING_FEAT_*` 特性标志
- 使用 `@When[os == "Linux"]` 条件编译

## 任务 1.3：定义核心 FFI 结构体 ✅
- 创建 `f_io/src/uring/uring_types.cj`
- 定义 `@C struct`：
  - `IOUringSQE` (提交队列条目)
  - `IOUringCQE` (完成队列条目)
  - `IOUringParams` (初始化参数)
  - `IOSQRingOffsets` / `IOCQRingOffsets`
  - `IOVec` (iovec)
  - `KernelTimespec` (时间规格)
  - `IOUringBuf` / `IOUringBufReg` (buffer ring)
  - `IOUringSQ` / `IOUringCQ` / `IOUring` (liburing 内部结构)
- 使用 `@When[os == "Linux"]` 条件编译

## 任务 1.4：声明 FFI 函数 ✅
- 创建 `f_io/src/uring/uring_ffi.cj`
- 使用 `foreign` 声明 liburing 函数：
  - 初始化：`io_uring_queue_init`, `io_uring_queue_init_params`, `io_uring_queue_exit`
  - 提交：`io_uring_submit`, `io_uring_submit_and_wait`
  - CQE 操作：`io_uring_wait_cqe`, `io_uring_peek_batch_cqe`
  - 注册：`io_uring_register_buffers`, `io_uring_register_files`, `io_uring_register_buf_ring`
  - 系统调用：`io_uring_setup`, `io_uring_enter`, `io_uring_register`
- 添加 `unsafe` 注释说明

## 任务 1.5：添加内存屏障支持 ✅
- 创建 `f_io/src/uring/uring_barrier.cj`
- 实现内存屏障函数：
  - `ioUringSmpLoadAcquire(ptr: CPointer<UInt32>): UInt32`
  - `ioUringSmpStoreRelease(ptr: CPointer<UInt32>, value: UInt32): Unit`
- 若仓颉暂不支持，添加 TODO 注释和临时实现

---

# 阶段二：低级封装层 ✅

## 任务 2.1：实现 SQE 操作辅助函数 ✅
- 创建 `f_io/src/uring/uring_sqe.cj`
- 实现内联函数的仓颉版本：
  - `ioUringGetSQE(ring): ?CPointer<IOUringSQE>`
  - `ioUringSQESetData64(sqe, data)` （仅整数形式，指针形式已删除）
  - `ioUringSQESetFlags(sqe, flags)`

## 任务 2.2：实现 SQE 准备函数 ✅
- 在 `uring_sqe.cj` 中添加：
  - `ioUringPrepRW(op, sqe, fd, addr, len, offset)` - 基础函数
  - `ioUringPrepRead(sqe, fd, buf, len, offset)`
  - `ioUringPrepWrite(sqe, fd, buf, len, offset)`
  - `ioUringPrepReadV(sqe, fd, iovecs, nrVecs, offset)`
  - `ioUringPrepWriteV(sqe, fd, iovecs, nrVecs, offset)`
  - `ioUringPrepFsync(sqe, fd, flags)`
  - `ioUringPrepPollAdd(sqe, fd, pollMask)`
  - `ioUringPrepTimeout(sqe, ts, count, flags)`
  - `ioUringPrepAccept(sqe, fd, addr, addrlen, flags)`
  - `ioUringPrepConnect(sqe, fd, addr, addrlen)`
  - `ioUringPrepSend(sqe, sockfd, buf, len, flags)`
  - `ioUringPrepRecv(sqe, sockfd, buf, len, flags)`
  - `ioUringPrepClose(sqe, fd)`

## 任务 2.3：实现 CQE 操作辅助函数 ✅
- 创建 `f_io/src/uring/uring_cqe.cj`
- 实现：
  - `ioUringCQEGetData64(cqe): UInt64` （仅整数形式，指针形式已删除）
  - `ioUringCQAdvance(ring, nr)`
  - `ioUringCQESeen(ring, cqe)`
  - `ioUringCQReady(ring): UInt32`
  - `ioUringSQReady(ring): UInt32`
  - `ioUringSQSpaceLeft(ring): UInt32`
  - `ioUringCQHasOverflow(ring): Bool`
  - `ioUringSQNeedWakeup(ring): Bool`
  - `ioUringSetSQETail(ring, newTail)`
  - `ioUringGetSQETail(ring): UInt32`
  - `ioUringAdvanceSQETail(ring, delta!)`

## 任务 2.4：实现柔性数组访问扩展 ✅
- 创建 `f_io/src/uring/uring_flexible.cj`
- 为 `IOUringSQE` 添加 cmd 数组访问：
  - `cmdPtr(): CPointer<UInt8>`
  - `getCmd(index): UInt8`
  - `setCmd(index, value)`
- 为 `IOUringProbeHeader` 添加 ops 数组访问：
  - `opsPtr(): CPointer<IOUringProbeOp>`
  - `getOp(index): IOUringProbeOp`
  - `isOpcodeSupported(op): Bool`

---

# 阶段三：高级封装类 ✅

## 任务 3.1：实现基础 IoUring 类 ✅
- 创建 `f_io/src/uring/uring_ring.cj`
- 实现 `IoUring` 类（实现 `Resource` 接口）：
  - `init(entries, flags)` - 基本初始化
  - `init(entries, params)` - 带参数初始化
  - `close()` - 资源清理
  - `isClosed(): Bool`
  - `getSQE(): ?CPointer<IOUringSQE>`
  - `submit(): Int32`
  - `submitAndWait(waitNr): Int32`
  - `waitCQE(): ?CPointer<IOUringCQE>`
  - `peekCQE(): ?CPointer<IOUringCQE>`
  - `cqeSeen(cqe)`
  - `cqAdvance(nr)`
  - `sqReady/sqSpaceLeft/cqReady` - 队列状态查询
  - `registerBuffers/unregisterBuffers` - 缓冲区注册
  - `registerFiles/unregisterFiles` - 文件描述符注册
  - `processCompletions/waitAndProcess` - 异步完成处理
- 异常类 `IoUringException` 在 `uring_exception.cj`

## 任务 3.2：实现 IoUringParams 构建器 ✅
- 创建 `f_io/src/uring/uring_params_builder.cj`
- 实现 `IoUringParamsBuilder`：
  - `setSQPOLL()`
  - `setSQPOLLIdle(ms)`
  - `setCQSize(size)`
  - `setSingleIssuer()`
  - `setDeferTaskRun()`
  - `setIOPoll()`
  - `setSQAff(cpu)`
  - `setClamp()`
  - `setAttachWQ(wqFd)`
  - `setSubmitAll()`
  - `setCoopTaskRun()`
  - `setSQE128()`
  - `setCQE32()`
  - `build(): IOUringParams`

## 任务 3.3：实现 IoUringPool（多实例池） ✅
- 创建 `f_io/src/uring/uring_pool.cj`
- 实现 `IoUringPool` 类：
  - `init(entriesPerRing, ringCount, flags)`
  - `getRing(): IoUring` - 轮询获取
  - `getRing(index): IoUring` - 按索引获取
  - `close()` - 关闭所有实例
- 使用 AtomicInt64 实现无锁轮询分配

## 任务 3.4：实现异步 Future 集成 ✅
- 创建 `f_io/src/uring/uring_future.cj`
- 实现 `CompletionSlot` 接口 — 类型擦除
- 实现 `CompletionRegistry` — ConcurrentHashMap<UInt64, CompletionSlot>
- 实现 `IoUringPromise<T>` — Mutex + Condition 阻塞等待
- 实现 `IoUringFuture<T>` — 包装 Promise，提供 get/tryGet/isCompleted API
- 注：std.core.Future<T> 是 final 类无法继承，提供独立实现

---

# 阶段四：无锁并发支持 ✅

## 任务 4.1：实现原子槽位分配器 ✅
- 创建 `f_io/src/uring/lockfree/slot_allocator.cj`
- 实现 `AtomicSlotAllocator` 类：位图 + CAS，上限 32768
  - `init(capacity)` / `alloc(): ?UInt32` / `release(slotId)` / `isAllocated()` / `reset()`
  - `countTrailingZeros(v)` - CTZ 辅助

## 任务 4.2：实现完成槽位数组 ✅
- 创建 `f_io/src/uring/lockfree/completion_slots.cj`
- 实现 `CompletionSlotArray`：generation 防止 ABA，userData 编解码
  - `setCallback()` / `encodeUserData()` / `decodeUserData()` / `invokeAndRelease()`
- 实现 `CompletionCallback` 开放类（替代接口，避免泛型类型擦除）
- 实现 `LambdaCompletionCallback <: CompletionCallback` - 闭包包装

## 任务 4.3：实现无锁SQE预分配器 ✅
- 创建 `f_io/src/uring/lockfree/sqe_pool.cj`
- 实现 `SQEPreallocator`：原子计数器 + readyFlags 数组
  - `allocSlot()` / `getSQE()` / `commitSlot()` / `flush()`

## 任务 4.4：实现无锁CQE收割器 ✅
- 创建 `f_io/src/uring/lockfree/cqe_reaper.cj`
- 实现 `LockFreeCQEReaper`：直接操作 CQ head 指针
  - `peekCQE()` / `advance()` / `reapAll()` / `reapN()`

## 任务 4.5：实现完整无锁IoUring ✅
- 创建 `f_io/src/uring/lockfree/lockfree_uring.cj`
- 实现 `IoUringLockFree <: Resource`：整合全部 lockfree 组件
  - 提交路径：allocSlot → getSQE → setCallback → commitSlot → flush
  - 收割路径：reap / reapN / waitAndReap
  - `submitAsync(prepFn, callback): Bool` - 便捷提交

---

# 阶段五：高级功能 ✅

## 任务 5.1：实现 Buffer Ring 支持 ✅
- 创建 `f_io/src/uring/uring_buf_ring.cj`
- 实现 `IOUringBufferRing <: Resource` 类：
  - `init(ring, nentries, bgid!, flags!)` - 注册 buffer ring
  - `add(addr, len, bid, bufOffset!)` - 添加缓冲区
  - `advance(count)` - 推进 tail
  - `addAndAdvance(addr, len, bid)` - 便捷方法
  - `getBgid/getNentries/getMask/getTail/getBuf` - 状态查询
  - `close()` - 注销并释放

## 任务 5.2：实现固定文件描述符注册 ✅
- 创建 `f_io/src/uring/uring_registered_files.cj`
- 实现 `RegisteredFiles <: Resource` 类：
  - `init(ring, nrFiles)` - 密集注册
  - `init(ring, nrFiles, sparse!)` - 稀疏注册
  - `update(index, fd)` - 更新文件描述符
  - `updateBatch(offset, fds, count)` - 批量更新
  - `allocIndex(fd)` - 自动分配索引
  - `getNrFiles/isSparse/getFd` - 状态查询
  - `close()` - 注销并释放

## 任务 5.3：实现固定缓冲区注册 ✅
- 创建 `f_io/src/uring/uring_registered_buffers.cj`
- 实现 `RegisteredBuffers <: Resource` 类：
  - `init(ring, iovecs, nrBuffers)` - 密集注册
  - `init(ring, nrBuffers, sparse!)` - 稀疏注册
  - `update(index, iovec)` - 更新缓冲区（通过 IORING_REGISTER_BUFFERS_UPDATE）
  - `getNrBuffers/isSparse/getIOVec` - 状态查询
  - `close()` - 注销并释放

---

# 阶段六：测试与文档

## 任务 6.1：编写单元测试
- 创建 `f_io/src/uring/tests/uring_test.cj`
- 测试用例：
  - `testQueueInitExit()` - 初始化与清理
  - `testSQEAllocation()` - SQE 分配
  - `testSubmitAndWait()` - 提交等待
  - `testReadWrite()` - 读写操作
  - `testPollAdd()` - 轮询操作
  - `testTimeout()` - 超时操作
  - `testLockFreeSlotAllocator()` - 无锁槽位分配
  - `testCompletionSlotArray()` - 完成槽位数组

## 任务 6.2：编写集成测试
- 创建 `f_io/src/uring/tests/integration_test.cj`
- 测试场景：
  - 文件异步读写
  - Socket 异步收发
  - 多线程并发提交
  - 高吞吐压力测试

## 任务 6.3：编写基准测试
- 创建 `f_io/src/uring/benchmarks/uring_bench.cj`
- 基准测试：
  - 单次 submit 延迟
  - 批量 submit 吞吐
  - CQE 收割吞吐
  - 无锁 vs 有锁对比

## 任务 6.4：完善 API 文档
- 为所有公开 API 添加文档注释
- 说明线程安全约束
- 提供使用示例

---

# 阶段七：导出与集成 ✅

## 任务 7.1：创建包导出文件 ✅
- 创建 `f_io/src/uring/uring.cj`（主入口），包含包文档和使用示例

## 任务 7.2：更新 f_io 包导出 ✅
- 在 `f_io/src/f_io.cj` 中添加 uring 子包使用说明

## 任务 7.3：验证跨平台编译 ✅
- `cjpm build` 通过（9 warnings, 0 errors）
- 全部 28 个测试通过：IoUringBasicTest(17) + LockFreeComponentTest(7) + IoUringIntegrationTest(4)

---

# 任务依赖关系

```
阶段一 (基础设施)
    ├── 1.1 → 1.2, 1.3, 1.4
    ├── 1.2, 1.3, 1.4 → 1.5
    └── 阶段一完成 → 阶段二

阶段二 (低级封装)
    ├── 2.1, 2.2 可并行
    ├── 2.3 可独立
    ├── 2.4 依赖 1.3
    └── 阶段二完成 → 阶段三

阶段三 (高级封装)
    ├── 3.1 依赖阶段二
    ├── 3.2, 3.3 可并行
    ├── 3.4 依赖 3.1
    └── 阶段三完成 → 阶段四

阶段四 (无锁并发)
    ├── 4.1, 4.2, 4.3, 4.4 可并行
    ├── 4.5 依赖 4.1, 4.2, 4.3, 4.4
    └── 阶段四完成 → 阶段五

阶段五 (高级功能)
    ├── 5.1, 5.2, 5.3 可并行
    └── 阶段五完成 → 阶段六

阶段六 (测试)
    ├── 6.1, 6.2 可并行
    ├── 6.3 依赖 6.1, 6.2
    ├── 6.4 可独立
    └── 阶段六完成 → 阶段七

阶段七 (导出集成)
    ├── 7.1, 7.2 顺序执行
    └── 7.3 最后验证
```
