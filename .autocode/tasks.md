# 前置任务
cd f_io

# 任务
在f_io/src/uring/ 添加仓颉的liburing ffi，并用仓颉class实现ffi的薄封装。
先不要实现代码，在f_io/doc创建一个liburing.md文档，详细介绍技术方案。

## 具体要求
1. 极致性能的技术方案
2. 文档列出liburing相关的仓颉侧ffi的函数和结构体声明
3. 指出仓颉现在尚无法实现的liburing特性
4. 对于柔性数组的可行替代方案

---

# 阶段一：基础设施与FFI声明

## 任务 1.1：创建目录结构与编译配置
- 在 `f_io/src/uring/` 创建目录
- 更新 `f_io/cjpm.toml`，为 Linux 目标添加 `-luring` 链接选项
- 创建 `f_io/src/uring/uring_constants.cj` 文件

## 任务 1.2：实现常量定义
- 在 `uring_constants.cj` 中定义所有 io_uring 常量：
  - `IORING_SETUP_*` 初始化标志
  - `IORING_ENTER_*` 进入标志
  - `IOSQE_*` SQE 标志
  - `IORING_CQE_F_*` CQE 标志
  - `IORING_OP_*` 操作码
  - `IORING_FEAT_*` 特性标志
- 使用 `@When[os == "Linux"]` 条件编译

## 任务 1.3：定义核心 FFI 结构体
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

## 任务 1.4：声明 FFI 函数
- 创建 `f_io/src/uring/uring_ffi.cj`
- 使用 `foreign` 声明 liburing 函数：
  - 初始化：`io_uring_queue_init`, `io_uring_queue_init_params`, `io_uring_queue_exit`
  - 提交：`io_uring_submit`, `io_uring_submit_and_wait`
  - CQE 操作：`io_uring_wait_cqe`, `io_uring_peek_batch_cqe`
  - 注册：`io_uring_register_buffers`, `io_uring_register_files`, `io_uring_register_buf_ring`
  - 系统调用：`io_uring_setup`, `io_uring_enter`, `io_uring_register`
- 添加 `unsafe` 注释说明

## 任务 1.5：添加内存屏障支持
- 创建 `f_io/src/uring/uring_barrier.cj`
- 实现内存屏障函数：
  - `ioUringSmpLoadAcquire(ptr: CPointer<UInt32>): UInt32`
  - `ioUringSmpStoreRelease(ptr: CPointer<UInt32>, value: UInt32): Unit`
- 若仓颉暂不支持，添加 TODO 注释和临时实现

---

# 阶段二：低级封装层

## 任务 2.1：实现 SQE 操作辅助函数
- 创建 `f_io/src/uring/uring_sqe.cj`
- 实现内联函数的仓颉版本：
  - `ioUringGetSQE(ring): ?CPointer<IOUringSQE>`
  - `ioUringSQESetData(sqe, data)`
  - `ioUringSQESetData64(sqe, data)`
  - `ioUringSQESetFlags(sqe, flags)`

## 任务 2.2：实现 SQE 准备函数
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

## 任务 2.3：实现 CQE 操作辅助函数
- 创建 `f_io/src/uring/uring_cqe.cj`
- 实现：
  - `ioUringCQEGetData(cqe): CPointer<Unit>`
  - `ioUringCQEGetData64(cqe): UInt64`
  - `ioUringCQAdvance(ring, nr)`
  - `ioUringCQESeen(ring, cqe)`
  - `ioUringCQReady(ring): UInt32`
  - `ioUringSQReady(ring): UInt32`

## 任务 2.4：实现柔性数组访问扩展
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

# 阶段三：高级封装类

## 任务 3.1：实现基础 IoUring 类
- 创建 `f_io/src/uring/uring.cj`
- 实现 `IoUring` 类（实现 `Resource` 接口）：
  - `init(entries, flags)` - 基本初始化
  - `init(entries, params)` - 带参数初始化
  - `close()` - 资源清理
  - `isClosed(): Bool`
  - `getSqe(): ?CPointer<IOUringSQE>`
  - `submit(): Int32`
  - `submitAndWait(waitNr): Int32`
  - `waitCQE(): ?CPointer<IOUringCQE>`
  - `cqeSeen(cqe)`
- 添加异常类 `IoUringException`

## 任务 3.2：实现 IoUringParams 构建器
- 创建 `f_io/src/uring/uring_params.cj`
- 实现 `IoUringParamsBuilder`：
  - `setSQPOLL()`
  - `setSQPOLLIdle(ms)`
  - `setCQSize(size)`
  - `setSingleIssuer()`
  - `setDeferTaskRun()`
  - `build(): IOUringParams`

## 任务 3.3：实现 IoUringPool（多实例池）
- 创建 `f_io/src/uring/uring_pool.cj`
- 实现 `IoUringPool` 类：
  - `init(entriesPerRing, ringCount, flags)`
  - `getRing(threadId): IoUring` - 获取线程对应实例
  - `close()` - 关闭所有实例
- 支持基于线程 ID 或轮询的分配策略

## 任务 3.4：实现异步 Future 集成
- 创建 `f_io/src/uring/uring_future.cj`
- 实现 `IoUringFuture<T>` 类：
  - 包装 io_uring 异步操作
  - 实现 `Future<T>` 接口
- 实现 `IoUringPromise<T>` 类：
  - 管理回调槽位
  - 完成时设置结果

---

# 阶段四：无锁并发支持

## 任务 4.1：实现原子槽位分配器
- 创建 `f_io/src/uring/lockfree/slot_allocator.cj`
- 实现 `AtomicSlotAllocator` 类：
  - `init(capacity)`
  - `alloc(): ?UInt32` - CAS 循环分配
  - `release(slot)` - CAS 循环释放
  - `reset()` - 重置分配器

## 任务 4.2：实现完成槽位数组
- 创建 `f_io/src/uring/lockfree/completion_slots.cj`
- 实现 `CompletionSlotArray` 类：
  - `init(slotCount)`
  - `alloc(callback): ?UInt32` - 分配槽位并设置回调
  - `get(slot): CompletionSlot`
  - `release(slot)` - 释放槽位
  - 使用 generation 计数器防止 ABA 问题

## 任务 4.3：实现无锁 SQE 预分配器
- 创建 `f_io/src/uring/lockfree/sqe_pool.cj`
- 实现 `SQEPreallocator` 类：
  - `init(ring, poolSize)`
  - `allocSlot(): ?UInt32`
  - `getSQE(slot): CPointer<IOUringSQE>`
  - `commitSlot(slot)` - 提交到内核 ring
  - `flush()` - 批量更新 tail

## 任务 4.4：实现无锁 CQE 收割器
- 创建 `f_io/src/uring/lockfree/cqe_reaper.cj`
- 实现 `LockFreeCQEReaper` 类：
  - `init(ring)`
  - `peekCQE(): ?CPointer<IOUringCQE>`
  - `advanceBatch(count)` - 单次 CAS 批量推进
  - `reapAll()` - 收割所有可用 CQE

## 任务 4.5：实现完整无锁 IoUring
- 创建 `f_io/src/uring/lockfree/lockfree_uring.cj`
- 实现 `IoUringLockFree` 类：
  - 整合槽位分配器、完成槽位数组、SQE预分配器、CQE收割器
  - `submitAsync(op, fd, buf, len, offset, callback): Int64`
  - `reap()` - 无锁收割
  - `close()`

---

# 阶段五：高级功能

## 任务 5.1：实现 Buffer Ring 支持
- 创建 `f_io/src/uring/uring_buf_ring.cj`
- 实现 `IOUringBufferRing` 类：
  - `init(ring, nentries, bgid)`
  - `add(addr, len, bid)` - 添加缓冲区
  - `advance(count)` - 推进 tail
  - `close()`

## 任务 5.2：实现固定文件描述符注册
- 创建 `f_io/src/uring/uring_registered_files.cj`
- 实现 `RegisteredFiles` 类：
  - `init(ring, nrFiles)`
  - `update(index, fd)` - 更新文件描述符
  - `close()`

## 任务 5.3：实现固定缓冲区注册
- 创建 `f_io/src/uring/uring_registered_buffers.cj`
- 实现 `RegisteredBuffers` 类：
  - `init(ring, iovecs)`
  - `update(index, iovec)`
  - `close()`

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

# 阶段七：导出与集成

## 任务 7.1：创建包导出文件
- 创建或更新 `f_io/src/uring/uring.cj`（主入口）
- 导出所有公开类型和函数

## 任务 7.2：更新 f_io 包导出
- 在 `f_io/src/f_io.cj` 中添加 uring 子包导出

## 任务 7.3：验证跨平台编译
- 确保非 Linux 平台编译通过（条件编译生效）
- 运行完整测试套件

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
