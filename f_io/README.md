# f_io

仓颉 I/O 工具库，提供内存映射、io_uring、流式 I/O 等功能。

## 文档

### pipe / asyncPipe / copyToCType

[doc/pipe_asyncpipe_copytoctype.md](doc/pipe_asyncpipe_copytoctype.md)

顶级工具函数：数据管道、异步管道、InputStream 转 CType。

### BytePointerStream

[doc/BytePointerStream.md](doc/BytePointerStream.md)

基于原生内存指针的字节流，支持读写 `CPointer<Byte>` 和 `Array<Byte>`。

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

### SegmentedLog

[doc/SegmentedLog.md](doc/SegmentedLog.md)

固定大小分段、纯顺序追加的写日志。Linux 使用 mmap 零 syscall 写入，非 Linux 回退 file.write()。供 WAL 等模块复用。
