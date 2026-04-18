# f_io

仓颉 I/O 工具库，提供内存映射、io_uring、流式 I/O 等功能。

## 文档

### [f_io API 参考](doc/f_io_api.md)

fountain::f_io 包的公共 API 文档，包括：

- BytePointerStream — 基于原生内存指针的字节流
- MMapFile — 内存映射文件
- IOUringStream — 基于 io_uring 的 IOStream 实现
- ExtendByteBuffer — ByteBuffer 类型化读写接口
- QueueInputStream / NonblockingQueueStream / BlockingQueueStream — 队列式输入流
- RotatableBuffer — 可旋转缓冲区
- DummyInputStream / DummyOutputStream — 空流（测试/占位）
- MMapProt / MMapFlag / MSyncFlag — mmap 枚举类型
- pipe / asyncPipe / copyToCType — 顶级工具函数

### [fountain::f_io.uring API 参考](doc/uring_api.md)

fountain::f_io.uring 及 fountain::f_io.uring.lockfree 包的公共 API 文档，包括：

- IoUring — io_uring 高层封装
- IoUringPool — io_uring 实例池
- IoUringParamsBuilder — 参数构建器
- RegisteredBuffers / RegisteredFiles — 注册缓冲区/文件描述符
- IOUringBufferRing — Provided Buffer Ring
- IoUringPromise / IoUringFuture — 异步操作支持
- IoUringLockFree — 无锁并发封装
- AtomicSlotAllocator / CompletionSlotArray / SQEPreallocator / LockFreeCQEReaper — 无锁组件
- SQE/CQE 操作函数、内存屏障函数、常量

### [IOUringStream vs File 性能对比](doc/liburing&file_perf.md)

IOUringStream 与 std.fs.File 的读写性能对比测试结果及分析，包括：

- 性能总览与优化历程
- Read 性能差距微基准拆解（submit syscall 占 58%）
- 注册缓冲区测试
- 已排除的优化方案
