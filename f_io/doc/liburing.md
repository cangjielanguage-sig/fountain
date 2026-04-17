# liburing FFI 技术方案

## 概述

本文档描述如何在仓颉语言中为 liburing (Linux io_uring 用户态库) 提供 FFI 绑定和薄封装层，以实现极致性能的异步 I/O。

## 1. 极致性能技术方案

### 1.1 设计原则

1. **零拷贝语义**：所有数据传递通过指针直接操作，避免不必要的数据复制
2. **内联关键路径**：将高频调用的操作（如获取 SQE、提交请求）内联到仓颉侧
3. **内存预分配**：SQE/CQE 通过共享内存环形队列访问，避免动态分配
4. **批量操作**：支持批量提交和批量收割，减少系统调用次数
5. **无锁设计**：利用 io_uring 的单生产者单消费者 (SPSC) 特性，避免锁竞争

### 1.2 架构分层

```
┌─────────────────────────────────────────┐
│          应用层 (用户代码)               │
├─────────────────────────────────────────┤
│     高级封装 (IoUring class)            │
│   - 类型安全的 API                      │
│   - 资源管理 (RAII)                     │
│   - 异步 Future 集成                    │
├─────────────────────────────────────────┤
│     低级封装 (struct + helper func)     │
│   - 结构体操作                          │
│   - inline 函数的仓颉实现               │
├─────────────────────────────────────────┤
│     FFI 声明层 (foreign func/struct)    │
│   - 直接映射 C API                      │
├─────────────────────────────────────────┤
│          liburing.so / 内核             │
└─────────────────────────────────────────┘
```

### 1.3 关键优化点

#### 1.3.1 避免 SQE/CQE 复制

```cj
// 错误：复制整个结构体
let sqe = getSQE()
sqe.opcode = opcode

// 正确：直接操作共享内存中的 SQE
let sqePtr = getSQEPointer()  // 返回 CPointer<IOUringSQE>
sqePtr.write(sqe)  // 或直接用指针修改字段
```

#### 1.3.2 批量提交与收割

```cj
// 批量提交，减少 io_uring_enter 调用
for (i in 0..batchSize) {
    prepRead(sqePtr + i, fd, buffers[i], ...);
}
submit();  // 一次系统调用提交所有请求

// 批量收割，避免循环等待
var cqes = VArray<CPointer<IOUringCQE>, $BATCH_SIZE>(...)
let count = peekBatchCQE(cqes);
for (i in 0..count) {
    processCQE(cqes[i]);
}
cqAdvance(count);  // 一次更新 head
```

#### 1.3.3 使用 SQPOLL 模式

当使用 `IORING_SETUP_SQPOLL` 标志时，内核线程负责轮询 SQ，避免应用进程的系统调用：

```cj
let params = IOUringParams()
params.flags = IORING_SETUP_SQPOLL
params.sqThreadIdle = 2000  // 2秒空闲后休眠
```

### 1.4 内存布局对齐

确保仓颉侧结构体与 C 侧完全一致：

| 结构体 | 64字节模式 | 128字节模式 |
|--------|-----------|-------------|
| `io_uring_sqe` | 64 bytes | 128 bytes |
| `io_uring_cqe` | 16 bytes | 32 bytes |

使用 `sizeOf<T>()` 和 `alignOf<T>()` 在编译时验证。

---

## 2. FFI 声明

### 2.1 常量定义

```cj
@When[os == "Linux"]
package fountain::f_io.uring

// io_uring_setup flags
public const IORING_SETUP_IOPOLL: UInt32 = 1U << 0
public const IORING_SETUP_SQPOLL: UInt32 = 1U << 1
public const IORING_SETUP_SQ_AFF: UInt32 = 1U << 2
public const IORING_SETUP_CQSIZE: UInt32 = 1U << 3
public const IORING_SETUP_CLAMP: UInt32 = 1U << 4
public const IORING_SETUP_ATTACH_WQ: UInt32 = 1U << 5
public const IORING_SETUP_R_DISABLED: UInt32 = 1U << 6
public const IORING_SETUP_SUBMIT_ALL: UInt32 = 1U << 7
public const IORING_SETUP_COOP_TASKRUN: UInt32 = 1U << 8
public const IORING_SETUP_TASKRUN_FLAG: UInt32 = 1U << 9
public const IORING_SETUP_SQE128: UInt32 = 1U << 10
public const IORING_SETUP_CQE32: UInt32 = 1U << 11
public const IORING_SETUP_SINGLE_ISSUER: UInt32 = 1U << 12
public const IORING_SETUP_DEFER_TASKRUN: UInt32 = 1U << 13
public const IORING_SETUP_NO_MMAP: UInt32 = 1U << 14
public const IORING_SETUP_REGISTERED_FD_ONLY: UInt32 = 1U << 15

// io_uring_enter flags
public const IORING_ENTER_GETEVENTS: UInt32 = 1U << 0
public const IORING_ENTER_SQ_WAKEUP: UInt32 = 1U << 1
public const IORING_ENTER_SQ_WAIT: UInt32 = 1U << 2
public const IORING_ENTER_EXT_ARG: UInt32 = 1U << 3
public const IORING_ENTER_REGISTERED_RING: UInt32 = 1U << 4

// SQE flags
public const IOSQE_FIXED_FILE: UInt8 = 1U << 0
public const IOSQE_IO_DRAIN: UInt8 = 1U << 1
public const IOSQE_IO_LINK: UInt8 = 1U << 2
public const IOSQE_IO_HARDLINK: UInt8 = 1U << 3
public const IOSQE_ASYNC: UInt8 = 1U << 4
public const IOSQE_BUFFER_SELECT: UInt8 = 1U << 5
public const IOSQE_CQE_SKIP_SUCCESS: UInt8 = 1U << 6

// CQE flags
public const IORING_CQE_F_BUFFER: UInt32 = 1U << 0
public const IORING_CQE_F_MORE: UInt32 = 1U << 1
public const IORING_CQE_F_SOCK_NONEMPTY: UInt32 = 1U << 2
public const IORING_CQE_F_NOTIF: UInt32 = 1U << 3

// opcodes
public const IORING_OP_NOP: UInt8 = 0
public const IORING_OP_READV: UInt8 = 1
public const IORING_OP_WRITEV: UInt8 = 2
public const IORING_OP_FSYNC: UInt8 = 3
public const IORING_OP_READ_FIXED: UInt8 = 4
public const IORING_OP_WRITE_FIXED: UInt8 = 5
public const IORING_OP_POLL_ADD: UInt8 = 6
public const IORING_OP_POLL_REMOVE: UInt8 = 7
public const IORING_OP_SYNC_FILE_RANGE: UInt8 = 8
public const IORING_OP_SENDMSG: UInt8 = 9
public const IORING_OP_RECVMSG: UInt8 = 10
public const IORING_OP_TIMEOUT: UInt8 = 11
public const IORING_OP_TIMEOUT_REMOVE: UInt8 = 12
public const IORING_OP_ACCEPT: UInt8 = 13
public const IORING_OP_ASYNC_CANCEL: UInt8 = 14
public const IORING_OP_LINK_TIMEOUT: UInt8 = 15
public const IORING_OP_CONNECT: UInt8 = 16
public const IORING_OP_FALLOCATE: UInt8 = 17
public const IORING_OP_OPENAT: UInt8 = 18
public const IORING_OP_CLOSE: UInt8 = 19
public const IORING_OP_FILES_UPDATE: UInt8 = 20
public const IORING_OP_STATX: UInt8 = 21
public const IORING_OP_READ: UInt8 = 22
public const IORING_OP_WRITE: UInt8 = 23
public const IORING_OP_FADVISE: UInt8 = 24
public const IORING_OP_MADVISE: UInt8 = 25
public const IORING_OP_SEND: UInt8 = 26
public const IORING_OP_RECV: UInt8 = 27
public const IORING_OP_OPENAT2: UInt8 = 28
public const IORING_OP_EPOLL_CTL: UInt8 = 29
public const IORING_OP_SPLICE: UInt8 = 30
public const IORING_OP_PROVIDE_BUFFERS: UInt8 = 31
public const IORING_OP_REMOVE_BUFFERS: UInt8 = 32
public const IORING_OP_TEE: UInt8 = 33
public const IORING_OP_SHUTDOWN: UInt8 = 34
public const IORING_OP_RENAMEAT: UInt8 = 35
public const IORING_OP_UNLINKAT: UInt8 = 36
public const IORING_OP_MKDIRAT: UInt8 = 37
public const IORING_OP_SYMLINKAT: UInt8 = 38
public const IORING_OP_LINKAT: UInt8 = 39
public const IORING_OP_MSG_RING: UInt8 = 40
public const IORING_OP_FSETXATTR: UInt8 = 41
public const IORING_OP_SETXATTR: UInt8 = 42
public const IORING_OP_FGETXATTR: UInt8 = 43
public const IORING_OP_GETXATTR: UInt8 = 44
public const IORING_OP_SOCKET: UInt8 = 45
public const IORING_OP_URING_CMD: UInt8 = 46
public const IORING_OP_SEND_ZC: UInt8 = 47
public const IORING_OP_SENDMSG_ZC: UInt8 = 48
```

### 2.2 核心结构体

#### 2.2.1 SQE (Submission Queue Entry)

```cj
@When[os == "Linux"]
@C
public struct IOUringSQE {
    public var opcode: UInt8 = 0           // 操作码
    public var flags: UInt8 = 0            // IOSQE_* 标志
    public var ioprio: UInt16 = 0          // I/O 优先级
    public var fd: Int32 = 0               // 文件描述符

    // union: off / addr2 / {cmd_op, __pad1}
    public var off: UInt64 = 0             // 文件偏移
    // 注：union 其他成员通过 setter 方法访问

    // union: addr / splice_off_in
    public var addr: UInt64 = 0            // 缓冲区地址
    // 注：splice_off_in 通过 setter 方法访问

    public var len: UInt32 = 0             // 缓冲区长度或 iovec 数量

    // union: rw_flags / fsync_flags / poll32_events / ...
    public var rwFlags: UInt32 = 0         // 读/写标志

    public var userData: UInt64 = 0        // 用户数据，完成时返回

    // union: buf_index / buf_group
    public var bufIndex: UInt16 = 0        // 固定缓冲区索引
    public var personality: UInt16 = 0     // 凭证 ID

    // union: splice_fd_in / file_index / {addr_len, __pad3}
    public var spliceFdIn: Int32 = 0       // splice 输入 fd

    // union: {addr3, __pad2} / cmd[0]
    public var addr3: UInt64 = 0           // 第三个地址参数

    // 注：cmd 柔性数组通过指针访问，见 2.4 节
}
```

**注意事项**：
- C 结构体中的 union 在仓颉中无法直接表示，采用以下策略：
  1. 最常用字段作为主成员
  2. 提供扩展函数按需访问其他 union 成员
  3. 通过 `CPointer` 操作特定偏移量

#### 2.2.2 CQE (Completion Queue Entry)

```cj
@When[os == "Linux"]
@C
public struct IOUringCQE {
    public var userData: UInt64 = 0        // 对应 SQE 的 userData
    public var res: Int32 = 0              // 操作结果（返回值或负错误码）
    public var flags: UInt32 = 0           // IORING_CQE_F_* 标志

    // 注：big_cqe[] 柔性数组仅在 IORING_SETUP_CQE32 时存在
    // 通过指针访问，见 2.4 节
}
```

#### 2.2.3 io_uring_params

```cj
@When[os == "Linux"]
@C
public struct IOUringParams {
    public var sqEntries: UInt32 = 0
    public var cqEntries: UInt32 = 0
    public var flags: UInt32 = 0
    public var sqThreadCpu: UInt32 = 0
    public var sqThreadIdle: UInt32 = 0
    public var features: UInt32 = 0
    public var wqFd: UInt32 = 0
    public var resv: VArray<UInt32, $3> = VArray(repeat: 0)
    public var sqOff: IOSQRingOffsets = IOSQRingOffsets()
    public var cqOff: IOCQRingOffsets = IOCQRingOffsets()
}

@When[os == "Linux"]
@C
public struct IOSQRingOffsets {
    public var head: UInt32 = 0
    public var tail: UInt32 = 0
    public var ringMask: UInt32 = 0
    public var ringEntries: UInt32 = 0
    public var flags: UInt32 = 0
    public var dropped: UInt32 = 0
    public var array: UInt32 = 0
    public var resv1: UInt32 = 0
    public var userAddr: UInt64 = 0
}

@When[os == "Linux"]
@C
public struct IOCQRingOffsets {
    public var head: UInt32 = 0
    public var tail: UInt32 = 0
    public var ringMask: UInt32 = 0
    public var ringEntries: UInt32 = 0
    public var overflow: UInt32 = 0
    public var cqes: UInt32 = 0
    public var flags: UInt32 = 0
    public var resv1: UInt32 = 0
    public var userAddr: UInt64 = 0
}
```

#### 2.2.4 iovec

```cj
@When[os == "Linux"]
@C
public struct IOVec {
    public var iovBase: CPointer<Unit> = CPointer<Unit>()
    public var iovLen: UIntNative = 0
}
```

#### 2.2.5 __kernel_timespec

```cj
@When[os == "Linux"]
@C
public struct KernelTimespec {
    public var tvSec: Int64 = 0
    public var tvNsec: Int64 = 0
}
```

#### 2.2.6 io_uring_buf (用于 buffer ring)

```cj
@When[os == "Linux"]
@C
public struct IOUringBuf {
    public var addr: UInt64 = 0
    public var len: UInt32 = 0
    public var bid: UInt16 = 0
    public var resv: UInt16 = 0
}
```

#### 2.2.7 io_uring_buf_reg

```cj
@When[os == "Linux"]
@C
public struct IOUringBufReg {
    public var ringAddr: UInt64 = 0
    public var ringEntries: UInt32 = 0
    public var bgid: UInt16 = 0
    public var flags: UInt16 = 0
    public var resv: VArray<UInt64, $3> = VArray(repeat: 0)
}
```

#### 2.2.8 io_uring_probe (用于特性探测)

```cj
@When[os == "Linux"]
@C
public struct IOUringProbeOp {
    public var op: UInt8 = 0
    public var resv: UInt8 = 0
    public var flags: UInt16 = 0
    public var resv2: UInt32 = 0
}

// 注：io_uring_probe 包含柔性数组 ops[]，见 2.4 节处理方案
```

#### 2.2.9 io_uring_sq / io_uring_cq (liburing 内部结构)

```cj
@When[os == "Linux"]
@C
public struct IOUringSQ {
    public var khead: CPointer<UInt32> = CPointer<UInt32>()
    public var ktail: CPointer<UInt32> = CPointer<UInt32>()
    public var kringMask: CPointer<UInt32> = CPointer<UInt32>()
    public var kringEntries: CPointer<UInt32> = CPointer<UInt32>()
    public var kflags: CPointer<UInt32> = CPointer<UInt32>()
    public var kdropped: CPointer<UInt32> = CPointer<UInt32>()
    public var array: CPointer<UInt32> = CPointer<UInt32>()
    public var sqes: CPointer<IOUringSQE> = CPointer<IOUringSQE>()

    public var sqeHead: UInt32 = 0
    public var sqeTail: UInt32 = 0

    public var ringSz: UIntNative = 0
    public var ringPtr: CPointer<Unit> = CPointer<Unit>()

    public var ringMask: UInt32 = 0
    public var ringEntries: UInt32 = 0

    public var pad: VArray<UInt32, $2> = VArray(repeat: 0)
}

@When[os == "Linux"]
@C
public struct IOUringCQ {
    public var khead: CPointer<UInt32> = CPointer<UInt32>()
    public var ktail: CPointer<UInt32> = CPointer<UInt32>()
    public var kringMask: CPointer<UInt32> = CPointer<UInt32>()
    public var kringEntries: CPointer<UInt32> = CPointer<UInt32>()
    public var kflags: CPointer<UInt32> = CPointer<UInt32>()
    public var koverflow: CPointer<UInt32> = CPointer<UInt32>()
    public var cqes: CPointer<IOUringCQE> = CPointer<IOUringCQE>()

    public var ringSz: UIntNative = 0
    public var ringPtr: CPointer<Unit> = CPointer<Unit>()

    public var ringMask: UInt32 = 0
    public var ringEntries: UInt32 = 0

    public var pad: VArray<UInt32, $2> = VArray(repeat: 0)
}

@When[os == "Linux"]
@C
public struct IOUring {
    public var sq: IOUringSQ = IOUringSQ()
    public var cq: IOUringCQ = IOUringCQ()
    public var flags: UInt32 = 0
    public var ringFd: Int32 = 0

    public var features: UInt32 = 0
    public var enterRingFd: Int32 = 0
    public var intFlags: UInt8 = 0
    public var pad: VArray<UInt8, $3> = VArray(repeat: 0)
    public var pad2: UInt32 = 0
}
```

### 2.3 FFI 函数声明

#### 2.3.1 初始化与清理

```cj
@When[os == "Linux"]
foreign {
    // 基本初始化
    func io_uring_queue_init(
        entries: UInt32,
        ring: CPointer<IOUring>,
        flags: UInt32
    ): Int32

    // 带参数初始化
    func io_uring_queue_init_params(
        entries: UInt32,
        ring: CPointer<IOUring>,
        params: CPointer<IOUringParams>
    ): Int32

    // 自定义内存初始化
    func io_uring_queue_init_mem(
        entries: UInt32,
        ring: CPointer<IOUring>,
        params: CPointer<IOUringParams>,
        buf: CPointer<Unit>,
        bufSize: UIntNative
    ): Int32

    // mmap 方式初始化
    func io_uring_queue_mmap(
        fd: Int32,
        params: CPointer<IOUringParams>,
        ring: CPointer<IOUring>
    ): Int32

    // 清理
    func io_uring_queue_exit(ring: CPointer<IOUring>): Unit

    // 防止 fork 继承
    func io_uring_ring_dontfork(ring: CPointer<IOUring>): Int32
}
```

#### 2.3.2 提交与等待

```cj
@When[os == "Linux"]
foreign {
    // 提交 SQ 中的请求
    func io_uring_submit(ring: CPointer<IOUring>): Int32

    // 提交并等待指定数量完成
    func io_uring_submit_and_wait(
        ring: CPointer<IOUring>,
        waitNr: UInt32
    ): Int32

    // 提交并等待带超时
    func io_uring_submit_and_wait_timeout(
        ring: CPointer<IOUring>,
        cqePtr: CPointer<CPointer<IOUringCQE>>,
        waitNr: UInt32,
        ts: CPointer<KernelTimespec>,
        sigmask: CPointer<Unit>  // sigset_t*
    ): Int32

    // 获取事件（不等待）
    func io_uring_get_events(ring: CPointer<IOUring>): Int32

    // 提交并获取事件
    func io_uring_submit_and_get_events(ring: CPointer<IOUring>): Int32
}
```

#### 2.3.3 CQE 操作

```cj
@When[os == "Linux"]
foreign {
    // 等待单个 CQE
    func io_uring_wait_cqe(
        ring: CPointer<IOUring>,
        cqePtr: CPointer<CPointer<IOUringCQE>>
    ): Int32

    // 等待多个 CQE
    func io_uring_wait_cqes(
        ring: CPointer<IOUring>,
        cqePtr: CPointer<CPointer<IOUringCQE>>,
        waitNr: UInt32,
        ts: CPointer<KernelTimespec>,
        sigmask: CPointer<Unit>
    ): Int32

    // 带超时等待 CQE
    func io_uring_wait_cqe_timeout(
        ring: CPointer<IOUring>,
        cqePtr: CPointer<CPointer<IOUringCQE>>,
        ts: CPointer<KernelTimespec>
    ): Int32

    // 批量 peek CQE
    func io_uring_peek_batch_cqe(
        ring: CPointer<IOUring>,
        cqes: CPointer<CPointer<IOUringCQE>>,
        count: UInt32
    ): UInt32

    // 内部辅助函数
    func __io_uring_get_cqe(
        ring: CPointer<IOUring>,
        cqePtr: CPointer<CPointer<IOUringCQE>>,
        submit: UInt32,
        waitNr: UInt32,
        sigmask: CPointer<Unit>
    ): Int32
}
```

#### 2.3.4 注册操作

```cj
@When[os == "Linux"]
foreign {
    // 注册缓冲区
    func io_uring_register_buffers(
        ring: CPointer<IOUring>,
        iovecs: CPointer<IOVec>,
        nrIOvecs: UInt32
    ): Int32

    func io_uring_register_buffers_sparse(
        ring: CPointer<IOUring>,
        nr: UInt32
    ): Int32

    func io_uring_unregister_buffers(ring: CPointer<IOUring>): Int32

    // 注册文件描述符
    func io_uring_register_files(
        ring: CPointer<IOUring>,
        files: CPointer<Int32>,
        nrFiles: UInt32
    ): Int32

    func io_uring_register_files_sparse(
        ring: CPointer<IOUring>,
        nr: UInt32
    ): Int32

    func io_uring_unregister_files(ring: CPointer<IOUring>): Int32

    func io_uring_register_files_update(
        ring: CPointer<IOUring>,
        off: UInt32,
        files: CPointer<Int32>,
        nrFiles: UInt32
    ): Int32

    // 注册 eventfd
    func io_uring_register_eventfd(ring: CPointer<IOUring>, fd: Int32): Int32
    func io_uring_register_eventfd_async(ring: CPointer<IOUring>, fd: Int32): Int32
    func io_uring_unregister_eventfd(ring: CPointer<IOUring>): Int32

    // 注册 buffer ring
    func io_uring_register_buf_ring(
        ring: CPointer<IOUring>,
        reg: CPointer<IOUringBufReg>,
        flags: UInt32
    ): Int32

    func io_uring_unregister_buf_ring(ring: CPointer<IOUring>, bgid: Int32): Int32

    // 探测支持的特性
    func io_uring_get_probe(): CPointer<IOUringProbe>
    func io_uring_get_probe_ring(ring: CPointer<IOUring>): CPointer<IOUringProbe>
    func io_uring_free_probe(probe: CPointer<IOUringProbe>): Unit

    func io_uring_register_probe(
        ring: CPointer<IOUring>,
        p: CPointer<IOUringProbe>,
        nr: UInt32
    ): Int32
}
```

#### 2.3.5 Buffer Ring 操作

```cj
@When[os == "Linux"]
foreign {
    func io_uring_setup_buf_ring(
        ring: CPointer<IOUring>,
        nentries: UInt32,
        bgid: Int32,
        flags: UInt32,
        ret: CPointer<Int32>
    ): CPointer<IOUringBufRing>

    func io_uring_free_buf_ring(
        ring: CPointer<IOUring>,
        br: CPointer<IOUringBufRing>,
        nentries: UInt32,
        bgid: Int32
    ): Int32
}
```

#### 2.3.6 系统调用

```cj
@When[os == "Linux"]
foreign {
    func io_uring_setup(
        entries: UInt32,
        params: CPointer<IOUringParams>
    ): Int32

    func io_uring_enter(
        fd: UInt32,
        toSubmit: UInt32,
        minComplete: UInt32,
        flags: UInt32,
        sig: CPointer<Unit>  // sigset_t*
    ): Int32

    func io_uring_enter2(
        fd: UInt32,
        toSubmit: UInt32,
        minComplete: UInt32,
        flags: UInt32,
        sig: CPointer<Unit>,
        sz: UIntNative
    ): Int32

    func io_uring_register(
        fd: UInt32,
        opcode: UInt32,
        arg: CPointer<Unit>,
        nrArgs: UInt32
    ): Int32
}
```

#### 2.3.7 其他辅助函数

```cj
@When[os == "Linux"]
foreign {
    func io_uring_mlock_size(entries: UInt32, flags: UInt32): IntNative
    func io_uring_mlock_size_params(entries: UInt32, p: CPointer<IOUringParams>): IntNative

    func __io_uring_sqring_wait(ring: CPointer<IOUring>): Int32
    func io_uring_enable_rings(ring: CPointer<IOUring>): Int32
}
```

---

## 3. 仓颉尚无法实现的 liburing 特性

### 3.1 柔性数组 (Flexible Array Member)

**问题描述**：
C99 的柔性数组（如 `__u8 cmd[0]` 或 `struct io_uring_probe_op ops[]`）在仓颉 FFI 中无直接对应。

**受影响的结构体**：
- `io_uring_sqe.cmd[0]` - 用于 IORING_OP_URING_CMD
- `io_uring_cqe.big_cqe[]` - 用于 IORING_SETUP_CQE32 扩展
- `io_uring_probe.ops[]` - 用于特性探测

**解决方案**：见第 4 节。

### 3.2 C Union

**问题描述**：
仓颉不支持 C 的 union 关键字，无法在同一内存位置存储不同类型。

**受影响的结构体**：
- `io_uring_sqe` 中的多个 union（off/addr2/cmd_op，addr/splice_off_in 等）
- `io_uring_buf_ring` 中的 union（resv 字段与 tail 重叠）

**解决方案**：
1. 对于 `io_uring_sqe`：只声明最常用字段，其他通过指针偏移访问
2. 对于 `io_uring_buf_ring`：使用指针操作访问重叠字段

### 3.3 inline 函数

**问题描述**：
liburing 大量使用 `static inline` 函数，这些函数不会被导出为符号，无法直接通过 FFI 调用。

**受影响的函数**：
- `io_uring_get_sqe()` - 获取空闲 SQE
- `io_uring_prep_read()` / `io_uring_prep_write()` - 准备 I/O 操作
- `io_uring_sq_ready()` / `io_uring_cq_ready()` - 查询队列状态
- `io_uring_cqe_seen()` / `io_uring_cq_advance()` - 标记 CQE 已处理
- `io_uring_sqe_set_data()` / `io_uring_cqe_get_data()` - 设置/获取用户数据
- 所有 `io_uring_prep_*` 系列函数

**解决方案**：
在仓颉侧重新实现这些函数，直接操作共享内存中的数据结构。

### 3.4 位域 (Bit-field)

**问题描述**：
C 的位域在仓颉中无直接支持。

**受影响位置**：
- liburing 内部使用位域进行标志位管理（但对外接口已用 `__u8`/`__u32` 替代）

**解决方案**：
当前 liburing 公共 API 已避免使用位域，无需特殊处理。

### 3.5 可变参数 (Variadic Arguments)

**问题描述**：
仓颉 FFI 支持可变参数（`...`），但需要 `unsafe` 块且类型安全性较差。

**受影响函数**：
- `printf` 等（非 liburing 核心）

**解决方案**：
liburing 核心函数不使用可变参数，无需特殊处理。

---

## 4. 柔性数组替代方案

### 4.1 方案一：固定大小数组 + 条件编译

```cj
// 对于已知最大尺寸的场景
@When[os == "Linux"]
@C
public struct IOUringSQE {
    // ... 常规字段 ...

    // cmd 数组：最大 80 字节 (128 - 48 标准字段)
    public var cmd: VArray<UInt8, $80> = VArray(repeat: 0)
}

@When[os == "Linux"]
@C
public struct IOUringCQE32 {
    public var userData: UInt64 = 0
    public var res: Int32 = 0
    public var flags: UInt32 = 0
    public var bigCQE: VArray<UInt64, $2> = VArray(repeat: 0)  // 额外 16 字节
}
```

**优点**：简单直接，类型安全
**缺点**：对于不使用扩展功能的场景浪费内存

### 4.2 方案二：指针操作 + 手动偏移（推荐）

```cj
// 定义不带柔性数组的结构体
@When[os == "Linux"]
@C
public struct IOUringSQEBase {
    public var opcode: UInt8 = 0
    public var flags: UInt8 = 0
    public var ioprio: UInt16 = 0
    public var fd: Int32 = 0
    public var off: UInt64 = 0
    public var addr: UInt64 = 0
    public var len: UInt32 = 0
    public var rwFlags: UInt32 = 0
    public var userData: UInt64 = 0
    public var bufIndex: UInt16 = 0
    public var personality: UInt16 = 0
    public var spliceFdIn: Int32 = 0
    public var addr3: UInt64 = 0
    // 不包含 cmd[]
}

// 扩展函数访问 cmd 数组
extend CPointer<IOUringSQEBase> {
    // 获取 cmd 数组起始指针
    public func cmdPtr(): CPointer<UInt8> {
        unsafe {
            // cmd 起始于结构体末尾
            let selfPtr = CPointer<UInt8>(this)
            selfPtr + sizeOf<IOUringSQEBase>()
        }
    }

    // 读取 cmd 字节
    public func getCmd(index: Int64): UInt8 {
        unsafe { (this.cmdPtr() + index).read() }
    }

    // 写入 cmd 字节
    public func setCmd(index: Int64, value: UInt8): Unit {
        unsafe { (this.cmdPtr() + index).write(value) }
    }
}
```

### 4.3 方案三：分离结构体

```cj
// 标准模式 SQE
@When[os == "Linux"]
@C
public struct IOUringSQE {
    // 64 字节，不包含 cmd
    // ...
}

// 128 字节模式 SQE
@When[os == "Linux"]
@C
public struct IOUringSQE128 {
    public var base: IOUringSQE = IOUringSQE()
    public var cmd: VArray<UInt8, $64> = VArray(repeat: 0)
}

// 标准模式 CQE
@When[os == "Linux"]
@C
public struct IOUringCQE {
    public var userData: UInt64 = 0
    public var res: Int32 = 0
    public var flags: UInt32 = 0
}

// 32 字节模式 CQE
@When[os == "Linux"]
@C
public struct IOUringCQE32 {
    public var base: IOUringCQE = IOUringCQE()
    public var bigCQE: VArray<UInt64, $2> = VArray(repeat: 0)
}
```

### 4.4 io_uring_probe 的特殊处理

```cj
@When[os == "Linux"]
@C
public struct IOUringProbeHeader {
    public var lastOp: UInt8 = 0
    public var opsLen: UInt8 = 0
    public var resv: UInt16 = 0
    public var resv2: VArray<UInt32, $3> = VArray(repeat: 0)
    // ops[] 柔性数组紧随其后
}

extend CPointer<IOUringProbeHeader> {
    // 获取 ops 数组起始指针
    public func opsPtr(): CPointer<IOUringProbeOp> {
        unsafe {
            let bytePtr = CPointer<Byte>(this)
            CPointer<IOUringProbeOp>(bytePtr + sizeOf<IOUringProbeHeader>())
        }
    }

    // 获取指定索引的 ops 元素
    public func getOp(index: Int64): IOUringProbeOp {
        unsafe { (this.opsPtr() + index).read() }
    }

    // 检查操作码是否支持
    public func isOpcodeSupported(op: UInt8): Bool {
        let opsLen = this.read().opsLen
        if (op > this.read().lastOp) {
            return false
        }
        unsafe {
            let opEntry = (this.opsPtr() + op).read()
            (opEntry.flags & IO_URING_OP_SUPPORTED) != 0
        }
    }
}
```

---

## 5. 仓颉侧 inline 函数实现

以下函数需要在仓颉侧重新实现，因为 C 的 `static inline` 函数不会被链接为符号：

### 5.1 获取 SQE

```cj
@When[os == "Linux"]
public func ioUringGetSQE(ring: CPointer<IOUring>): CPointer<IOUringSQE> {
    unsafe {
        let sq = CPointer<Byte>(ring) + 0  // sq 是第一个成员

        // 读取 sq.sqeTail 和 sq.sqeHead
        let sqeTail = ring.read().sq.sqeTail
        let sqeHead = if ((ring.read().flags & IORING_SETUP_SQPOLL) != 0) {
            // 需要使用 acquire 语义读取
            // 简化实现：直接读取 khead
            ring.read().sq.khead.read()
        } else {
            ring.read().sq.khead.read()
        }

        let next = sqeTail + 1
        let ringEntries = ring.read().sq.ringEntries

        if (next - sqeHead <= ringEntries) {
            let sqePtr = ring.read().sq.sqes
            let ringMask = ring.read().sq.ringMask
            let shift = if ((ring.read().flags & IORING_SETUP_SQE128) != 0) { 1 } else { 0 }
            let index = (sqeTail & ringMask) << shift

            // 更新 sqeTail (通过指针修改)
            // 注意：需要 mutable 访问，这里需要特殊处理

            sqePtr + index
        } else {
            CPointer<IOUringSQE>()  // null
        }
    }
}
```

### 5.2 设置/获取用户数据

```cj
@When[os == "Linux"]
public func ioUringSQESetData(sqe: CPointer<IOUringSQE>, data: CPointer<Unit>): Unit {
    unsafe {
        var entry = sqe.read()
        entry.userData = data.toUIntNative()
        sqe.write(entry)
    }
}

@When[os == "Linux"]
public func ioUringSQESetData64(sqe: CPointer<IOUringSQE>, data: UInt64): Unit {
    unsafe {
        var entry = sqe.read()
        entry.userData = data
        sqe.write(entry)
    }
}

@When[os == "Linux"]
public func ioUringCQEGetData(cqe: CPointer<IOUringCQE>): CPointer<Unit> {
    unsafe {
        CPointer<Unit>(cqe.read().userData)
    }
}

@When[os == "Linux"]
public func ioUringCQEGetData64(cqe: CPointer<IOUringCQE>): UInt64 {
    unsafe { cqe.read().userData }
}
```

### 5.3 准备 I/O 操作

```cj
@When[os == "Linux"]
public func ioUringPrepRW(
    op: Int32,
    sqe: CPointer<IOUringSQE>,
    fd: Int32,
    addr: CPointer<Unit>,
    len: UInt32,
    offset: UInt64
): Unit {
    unsafe {
        var entry = sqe.read()
        entry.opcode = UInt8(op)
        entry.flags = 0
        entry.ioprio = 0
        entry.fd = fd
        entry.off = offset
        entry.addr = addr.toUIntNative()
        entry.len = len
        entry.rwFlags = 0
        entry.bufIndex = 0
        entry.personality = 0
        entry.spliceFdIn = 0
        entry.addr3 = 0
        sqe.write(entry)
    }
}

@When[os == "Linux"]
public func ioUringPrepRead(
    sqe: CPointer<IOUringSQE>,
    fd: Int32,
    buf: CPointer<Unit>,
    nbytes: UInt32,
    offset: UInt64
): Unit {
    ioUringPrepRW(IORING_OP_READ, sqe, fd, buf, nbytes, offset)
}

@When[os == "Linux"]
public func ioUringPrepWrite(
    sqe: CPointer<IOUringSQE>,
    fd: Int32,
    buf: CPointer<Unit>,
    nbytes: UInt32,
    offset: UInt64
): Unit {
    ioUringPrepRW(IORING_OP_WRITE, sqe, fd, buf, nbytes, offset)
}
```

### 5.4 CQE 处理

```cj
@When[os == "Linux"]
public func ioUringCQAdvance(ring: CPointer<IOUring>, nr: UInt32): Unit {
    if (nr != 0) {
        unsafe {
            let cq = ring.read().cq
            let oldHead = cq.khead.read()
            cq.khead.write(oldHead + nr)
        }
    }
}

@When[os == "Linux"]
public func ioUringCQESeen(ring: CPointer<IOUring>, cqe: CPointer<IOUringCQE>): Unit {
    if (!cqe.isNull()) {
        ioUringCQAdvance(ring, 1)
    }
}
```

### 5.5 队列状态查询

```cj
@When[os == "Linux"]
public func ioUringSQReady(ring: CPointer<IOUring>): UInt32 {
    unsafe {
        let sq = ring.read().sq
        var khead = sq.khead.read()

        if ((ring.read().flags & IORING_SETUP_SQPOLL) != 0) {
            // 需要使用 acquire 语义
            khead = sq.khead.read()  // 简化：实际需要 smp_load_acquire
        }

        sq.sqeTail - khead
    }
}

@When[os == "Linux"]
public func ioUringCQReady(ring: CPointer<IOUring>): UInt32 {
    unsafe {
        let cq = ring.read().cq
        // 需要使用 acquire 语义读取 ktail
        let ktail = cq.ktail.read()  // 简化
        let khead = cq.khead.read()
        ktail - khead
    }
}
```

---

## 6. 高级封装类设计

```cj
@When[os == "Linux"]
public class IoUring <: Resource {
    private let ring: IOUring
    private var closed = false

    public init(entries: UInt32, flags!: UInt32 = 0) {
        ring = IOUring()
        let ret = unsafe { io_uring_queue_init(entries, CPointer<IOUring>(ring), flags) }
        if (ret < 0) {
            throw IoUringException("io_uring_queue_init failed: ${ret}")
        }
    }

    public init(entries: UInt32, params: IOUringParams) {
        ring = IOUring()
        let ret = unsafe { io_uring_queue_init_params(entries, CPointer<IOUring>(ring), CPointer<IOUringParams>(params)) }
        if (ret < 0) {
            throw IoUringException("io_uring_queue_init_params failed: ${ret}")
        }
    }

    public func getSqe(): ?CPointer<IOUringSQE> {
        let sqe = ioUringGetSQE(CPointer<IOUring>(ring))
        if (sqe.isNull()) {
            None
        } else {
            Some(sqe)
        }
    }

    public func submit(): Int32 {
        unsafe { io_uring_submit(CPointer<IOUring>(ring)) }
    }

    public func submitAndWait(waitNr: UInt32): Int32 {
        unsafe { io_uring_submit_and_wait(CPointer<IOUring>(ring), waitNr) }
    }

    public func waitCQE(): ?CPointer<IOUringCQE> {
        var cqe: CPointer<IOUringCQE> = CPointer<IOUringCQE>()
        let ret = unsafe { io_uring_wait_cqe(CPointer<IOUring>(ring), inout cqe) }
        if (ret < 0 || cqe.isNull()) {
            None
        } else {
            Some(cqe)
        }
    }

    public func cqeSeen(cqe: CPointer<IOUringCQE>): Unit {
        ioUringCQESeen(CPointer<IOUring>(ring), cqe)
    }

    public func close(): Unit {
        if (!closed) {
            closed = true
            unsafe { io_uring_queue_exit(CPointer<IOUring>(ring)) }
        }
    }

    public func isClosed(): Bool { closed }
}
```

---

## 7. 编译配置

在 `cjpm.toml` 中添加 liburing 链接：

```toml
[target.x86_64-unknown-linux-gnu]
  compile-option = "--dy-std -ldl -luring"
  override-compile-option = "--dy-std -ldl -luring"

[target.aarch64-unknown-linux-gnu]
  compile-option = "--dy-std -ldl -luring"
  override-compile-option = "--dy-std -ldl -luring"
```

---

## 8. 总结

| 特性 | 实现方案 |
|------|----------|
| FFI 函数调用 | `foreign func` 声明 |
| FFI 结构体 | `@C struct` 声明 |
| 柔性数组 | 指针操作 + 手动偏移 |
| C union | 只声明最常用字段，其他通过指针访问 |
| inline 函数 | 仓颉侧重新实现 |
| 内存安全 | `unsafe` 块 + RAII 封装类 |
| 类型安全 | 高级封装类提供类型安全 API |

通过以上方案，可以在仓颉中实现接近原生 C 性能的 io_uring 绑定。
