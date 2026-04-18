# f_io

仓颉 I/O 工具库，提供内存映射、io_uring、流式 I/O 等功能。

## 文档

### pipe / asyncPipe / copyToCType

[doc/pipe_asyncpipe_copytoctype.md](doc/pipe_asyncpipe_copytoctype.md)

顶级工具函数：数据管道、异步管道、InputStream 转 CType。

### BytePointerStream

[doc/BytePointerStream.md](doc/BytePointerStream.md)

基于原生内存指针的字节流，支持读写 CPointer<Byte> 和 Array<Byte>。

### DummyInputStream

[doc/DummyInputStream.md](doc/DummyInputStream.md)

空输入流，用于测试或占位。

### DummyOutputStream

[doc/DummyOutputStream.md](doc/DummyOutputStream.md)

空输出流，用于测试或占位。

### ExtendByteBuffer

[doc/ExtendByteBuffer.md](doc/ExtendByteBuffer.md)

ByteBuffer 的类型化读写接口，支持大端/小端字节序。

### MMapFile

[doc/MMapFile.md](doc/MMapFile.md)

内存映射文件，支持读写映射、同步、重映射。

### ToMMap

[doc/ToMMap.md](doc/ToMMap.md)

接口，std.fs.File 扩展此接口以创建 MMapFile。

### QueueInputStream / NonblockingQueueStream / BlockingQueueStream

[doc/QueueInputStream.md](doc/QueueInputStream.md)

队列式输入流，支持添加多个 InputStream 顺序读取。

### RotatableBuffer

[doc/RotatableBuffer.md](doc/RotatableBuffer.md)

可旋转缓冲区，支持按分隔符从 InputStream 中分段读取。

### MMapProt / MMapFlag / MSyncFlag / DEFAULT_MMAP_BYTES

[doc/MMapProt_MMapFlag_MSyncFlag.md](doc/MMapProt_MMapFlag_MSyncFlag.md)

内存映射相关的枚举类型和常量。

### BytePointerException / MMapException

[doc/BytePointerException_MMapException.md](doc/BytePointerException_MMapException.md)

fountain::f_io.exception 包的异常类。

### IOUringStream

[doc/IOUringStream.md](doc/IOUringStream.md)

基于 io_uring 的 IOStream 实现（双 ring 架构），Write 异步立即返回，Read 同线程阻塞等待。

### fountain::f_io.uring API 参考

[doc/uring_api.md](doc/uring_api.md)

fountain::f_io.uring 及 fountain::f_io.uring.lockfree 包的 API 文档，包括 IoUring、IoUringLockFree、RegisteredBuffers 等类、函数、结构体和常量。

### IOUringStream vs File 性能对比

[doc/liburing&file_perf.md](doc/liburing&file_perf.md)

IOUringStream 与 std.fs.File 的读写性能对比测试结果及分析。
