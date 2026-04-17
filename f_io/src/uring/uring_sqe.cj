/*
Copyright (c) 2025 WuJingrun（吴京润）

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/
package fountain::f_io.uring

/**
 * SQE (Submission Queue Entry) 操作辅助函数
 * 
 * 这些函数对应 liburing 的 inline 函数，需要手动重实现。
 * 所有函数仅在 Linux 平台可用。
 */

// ==================== SQE 获取 ====================

/**
 * 获取一个空闲的 SQE
 * 
 * 从 SQ 环形队列中获取下一个可用的 SQE 槽位。
 * 返回的 SQE 可以用于准备 I/O 操作。
 * 
 * 注意：此函数是非线程安全的，多线程环境需要外部同步。
 * 
 * @param ring io_uring 结构体指针
 * @return SQE 指针，如果 SQ 满则返回 null
 */
@When[os == "Linux"]
public func ioUringGetSQE(ring: CPointer<IOUring>): ?CPointer<IOUringSQE> {
    unsafe {
        let ringVal = ring.read()
        let sq = ringVal.sq
        
        // 读取本地 tail（应用线程私有）
        let tail = sq.sqeTail
        let next = tail + 1
        
        // 读取内核 head（需要 acquire 语义）
        let head = if ((ringVal.flags & IORING_SETUP_SQPOLL) != 0) {
            // SQPOLL 模式：使用 acquire 语义读取
            ioUringSmpLoadAcquire(sq.khead)
        } else {
            // 非 SQPOLL 模式：直接读取
            sq.khead.read()
        }
        
        // 检查是否有空间
        if (next - head > sq.ringEntries) {
            return None  // SQ 满
        }
        
        // 计算 SQE 地址
        let shift = if ((ringVal.flags & IORING_SETUP_SQE128) != 0) { 1 } else { 0 }
        let index = (tail & sq.ringMask) << shift
        
        // 更新本地 tail
        // 注意：sqeTail 是值类型，需要通过指针修改
        // 这里我们返回 SQE 指针，调用者负责更新 tail
        
        Some(sq.sqes + Int64(index))
    }
}

/**
 * 获取 SQE 并更新 tail
 * 
 * 这是一个便捷函数，获取 SQE 后自动更新 sqeTail。
 * 适用于单次提交场景。
 * 
 * @param ring io_uring 结构体指针
 * @return SQE 指针，如果 SQ 满则返回 null
 */
@When[os == "Linux"]
public func ioUringGetSQEAndUpdate(ring: CPointer<IOUring>): ?CPointer<IOUringSQE> {
    unsafe {
        let sqeOpt = ioUringGetSQE(ring)
        if (let Some(sqe) <- sqeOpt) {
            // 更新 sqeTail — 通过 ioUringAdvanceSQETail 实现
            ioUringAdvanceSQETail(ring)
            
            sqeOpt
        } else {
            None
        }
    }
}

// ==================== SQE 数据设置 ====================

/**
 * 设置 SQE 的用户数据（64位整数形式）
 * 
 * 用户数据在请求完成时会原样返回到 CQE 中。
 * 常用于存储请求 ID 或槽位索引。
 * 
 * 注意：推荐使用此函数（整数形式）而非指针形式，
 * 因为仓颉无法安全地将 UInt64 重新解释为 CPointer。
 * 配合 ioUringCQEGetData64 使用。
 * 
 * @param sqe SQE 指针
 * @param data 用户数据（64位整数）
 */
@When[os == "Linux"]
public func ioUringSQESetData64(sqe: CPointer<IOUringSQE>, data: UInt64): Unit {
    unsafe {
        var entry = sqe.read()
        entry.userData = data
        sqe.write(entry)
    }
}

/**
 * 设置 SQE 的标志位
 * 
 * @param sqe SQE 指针
 * @param flags 标志位（IOSQE_* 组合）
 */
@When[os == "Linux"]
public func ioUringSQESetFlags(sqe: CPointer<IOUringSQE>, flags: UInt8): Unit {
    unsafe {
        var entry = sqe.read()
        entry.flags = flags
        sqe.write(entry)
    }
}

// ==================== SQE 准备函数 ====================

/**
 * 准备读写操作的 SQE
 * 
 * 这是所有 I/O 准备函数的基础实现。
 * 
 * @param op 操作码
 * @param sqe SQE 指针
 * @param fd 文件描述符
 * @param addr 缓冲区地址
 * @param len 缓冲区长度
 * @param offset 文件偏移
 */
@When[os == "Linux"]
public func ioUringPrepRW(
    op: UInt8,
    sqe: CPointer<IOUringSQE>,
    fd: Int32,
    addr: CPointer<Unit>,
    len: UInt32,
    offset: UInt64
): Unit {
    unsafe {
        var entry = sqe.read()
        entry.opcode = op
        entry.flags = 0
        entry.ioprio = 0
        entry.fd = fd
        entry.off = offset
        entry.addr = UInt64(addr.toUIntNative())
        entry.len = len
        entry.rwFlags = 0
        entry.bufIndex = 0
        entry.personality = 0
        entry.spliceFdIn = 0
        entry.addr3 = 0
        sqe.write(entry)
    }
}

/**
 * 准备读操作
 * 
 * @param sqe SQE 指针
 * @param fd 文件描述符
 * @param buf 缓冲区指针
 * @param nbytes 读取字节数
 * @param offset 文件偏移
 */
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

/**
 * 准备写操作
 * 
 * @param sqe SQE 指针
 * @param fd 文件描述符
 * @param buf 缓冲区指针
 * @param nbytes 写入字节数
 * @param offset 文件偏移
 */
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

/**
 * 准备向量读操作
 * 
 * @param sqe SQE 指针
 * @param fd 文件描述符
 * @param iovecs iovec 数组指针
 * @param nrVecs iovec 数量
 * @param offset 文件偏移
 */
@When[os == "Linux"]
public func ioUringPrepReadV(
    sqe: CPointer<IOUringSQE>,
    fd: Int32,
    iovecs: CPointer<IOVec>,
    nrVecs: UInt32,
    offset: UInt64
): Unit {
    ioUringPrepRW(IORING_OP_READV, sqe, fd, CPointer<Unit>(iovecs), nrVecs, offset)
}

/**
 * 准备向量写操作
 * 
 * @param sqe SQE 指针
 * @param fd 文件描述符
 * @param iovecs iovec 数组指针
 * @param nrVecs iovec 数量
 * @param offset 文件偏移
 */
@When[os == "Linux"]
public func ioUringPrepWriteV(
    sqe: CPointer<IOUringSQE>,
    fd: Int32,
    iovecs: CPointer<IOVec>,
    nrVecs: UInt32,
    offset: UInt64
): Unit {
    ioUringPrepRW(IORING_OP_WRITEV, sqe, fd, CPointer<Unit>(iovecs), nrVecs, offset)
}

/**
 * 准备文件同步操作
 * 
 * @param sqe SQE 指针
 * @param fd 文件描述符
 * @param flags 同步标志（IORING_FSYNC_DATASYNC）
 */
@When[os == "Linux"]
public func ioUringPrepFsync(
    sqe: CPointer<IOUringSQE>,
    fd: Int32,
    flags: UInt32
): Unit {
    unsafe {
        var entry = sqe.read()
        entry.opcode = IORING_OP_FSYNC
        entry.flags = 0
        entry.ioprio = 0
        entry.fd = fd
        entry.off = 0
        entry.addr = 0
        entry.len = 0
        entry.rwFlags = flags  // fsync_flags 使用 rwFlags 字段
        entry.bufIndex = 0
        entry.personality = 0
        entry.spliceFdIn = 0
        entry.addr3 = 0
        sqe.write(entry)
    }
}

/**
 * 准备轮询添加操作
 * 
 * @param sqe SQE 指针
 * @param fd 文件描述符
 * @param pollMask 轮询事件掩码（POLLIN, POLLOUT 等）
 */
@When[os == "Linux"]
public func ioUringPrepPollAdd(
    sqe: CPointer<IOUringSQE>,
    fd: Int32,
    pollMask: UInt32
): Unit {
    unsafe {
        var entry = sqe.read()
        entry.opcode = IORING_OP_POLL_ADD
        entry.flags = 0
        entry.ioprio = 0
        entry.fd = fd
        entry.off = 0
        entry.addr = 0
        entry.len = 0
        // poll32_events 存储在 rwFlags 字段
        entry.rwFlags = pollMask
        entry.bufIndex = 0
        entry.personality = 0
        entry.spliceFdIn = 0
        entry.addr3 = 0
        sqe.write(entry)
    }
}

/**
 * 准备超时操作
 * 
 * @param sqe SQE 指针
 * @param ts 超时时间规格
 * @param count 等待的完成数量（0 表示不等待）
 * @param flags 超时标志
 */
@When[os == "Linux"]
public func ioUringPrepTimeout(
    sqe: CPointer<IOUringSQE>,
    ts: CPointer<KernelTimespec>,
    count: UInt32,
    flags: UInt32
): Unit {
    unsafe {
        var entry = sqe.read()
        entry.opcode = IORING_OP_TIMEOUT
        entry.flags = 0
        entry.ioprio = 0
        entry.fd = -1
        entry.off = UInt64(count)  // count 存储在 off 字段
        entry.addr = UInt64(ts.toUIntNative())
        entry.len = 1
        entry.rwFlags = flags  // timeout_flags 使用 rwFlags 字段
        entry.bufIndex = 0
        entry.personality = 0
        entry.spliceFdIn = 0
        entry.addr3 = 0
        sqe.write(entry)
    }
}

/**
 * 准备 accept 操作
 * 
 * @param sqe SQE 指针
 * @param fd 监听套接字
 * @param addr 客户端地址缓冲区
 * @param addrlen 地址长度指针
 * @param flags accept 标志
 */
@When[os == "Linux"]
public func ioUringPrepAccept(
    sqe: CPointer<IOUringSQE>,
    fd: Int32,
    addr: CPointer<Unit>,
    addrlen: CPointer<UInt32>,
    flags: UInt32
): Unit {
    unsafe {
        var entry = sqe.read()
        entry.opcode = IORING_OP_ACCEPT
        entry.flags = 0
        entry.ioprio = 0
        entry.fd = fd
        entry.off = UInt64(addrlen.toUIntNative())  // addrlen 存储在 off 字段
        entry.addr = UInt64(addr.toUIntNative())
        entry.len = 0
        entry.rwFlags = flags  // accept_flags 使用 rwFlags 字段
        entry.bufIndex = 0
        entry.personality = 0
        entry.spliceFdIn = 0
        entry.addr3 = 0
        sqe.write(entry)
    }
}

/**
 * 准备 connect 操作
 * 
 * @param sqe SQE 指针
 * @param fd 套接字
 * @param addr 服务器地址
 * @param addrlen 地址长度
 */
@When[os == "Linux"]
public func ioUringPrepConnect(
    sqe: CPointer<IOUringSQE>,
    fd: Int32,
    addr: CPointer<Unit>,
    addrlen: UInt32
): Unit {
    unsafe {
        var entry = sqe.read()
        entry.opcode = IORING_OP_CONNECT
        entry.flags = 0
        entry.ioprio = 0
        entry.fd = fd
        entry.off = UInt64(addrlen)  // addrlen 存储在 off 字段
        entry.addr = UInt64(addr.toUIntNative())
        entry.len = 0
        entry.rwFlags = 0
        entry.bufIndex = 0
        entry.personality = 0
        entry.spliceFdIn = 0
        entry.addr3 = 0
        sqe.write(entry)
    }
}

/**
 * 准备 send 操作
 * 
 * @param sqe SQE 指针
 * @param sockfd 套接字
 * @param buf 发送缓冲区
 * @param len 发送长度
 * @param flags send 标志
 */
@When[os == "Linux"]
public func ioUringPrepSend(
    sqe: CPointer<IOUringSQE>,
    sockfd: Int32,
    buf: CPointer<Unit>,
    len: UInt32,
    flags: UInt32
): Unit {
    unsafe {
        var entry = sqe.read()
        entry.opcode = IORING_OP_SEND
        entry.flags = 0
        entry.ioprio = 0
        entry.fd = sockfd
        entry.off = 0
        entry.addr = UInt64(buf.toUIntNative())
        entry.len = len
        entry.rwFlags = flags  // msg_flags 使用 rwFlags 字段
        entry.bufIndex = 0
        entry.personality = 0
        entry.spliceFdIn = 0
        entry.addr3 = 0
        sqe.write(entry)
    }
}

/**
 * 准备 recv 操作
 * 
 * @param sqe SQE 指针
 * @param sockfd 套接字
 * @param buf 接收缓冲区
 * @param len 接收长度
 * @param flags recv 标志
 */
@When[os == "Linux"]
public func ioUringPrepRecv(
    sqe: CPointer<IOUringSQE>,
    sockfd: Int32,
    buf: CPointer<Unit>,
    len: UInt32,
    flags: UInt32
): Unit {
    unsafe {
        var entry = sqe.read()
        entry.opcode = IORING_OP_RECV
        entry.flags = 0
        entry.ioprio = 0
        entry.fd = sockfd
        entry.off = 0
        entry.addr = UInt64(buf.toUIntNative())
        entry.len = len
        entry.rwFlags = flags  // msg_flags 使用 rwFlags 字段
        entry.bufIndex = 0
        entry.personality = 0
        entry.spliceFdIn = 0
        entry.addr3 = 0
        sqe.write(entry)
    }
}

/**
 * 准备 close 操作
 * 
 * @param sqe SQE 指针
 * @param fd 要关闭的文件描述符
 */
@When[os == "Linux"]
public func ioUringPrepClose(
    sqe: CPointer<IOUringSQE>,
    fd: Int32
): Unit {
    unsafe {
        var entry = sqe.read()
        entry.opcode = IORING_OP_CLOSE
        entry.flags = 0
        entry.ioprio = 0
        entry.fd = fd
        entry.off = 0
        entry.addr = 0
        entry.len = 0
        entry.rwFlags = 0
        entry.bufIndex = 0
        entry.personality = 0
        entry.spliceFdIn = 0
        entry.addr3 = 0
        sqe.write(entry)
    }
}

/**
 * 准备 openat 操作
 * 
 * @param sqe SQE 指针
 * @param dfd 目录文件描述符（AT_FDCWD 表示当前目录）
 * @param path 文件路径
 * @param flags 打开标志
 * @param mode 文件模式
 */
@When[os == "Linux"]
public func ioUringPrepOpenAt(
    sqe: CPointer<IOUringSQE>,
    dfd: Int32,
    path: CString,
    flags: UInt32,
    mode: UInt32
): Unit {
    unsafe {
        var entry = sqe.read()
        entry.opcode = IORING_OP_OPENAT
        entry.flags = 0
        entry.ioprio = 0
        entry.fd = dfd
        entry.off = 0
        entry.addr = UInt64(CPointer<Unit>(path.getChars()).toUIntNative())
        entry.len = mode  // mode 存储在 len 字段
        entry.rwFlags = flags  // open_flags 使用 rwFlags 字段
        entry.bufIndex = 0
        entry.personality = 0
        entry.spliceFdIn = 0
        entry.addr3 = 0
        sqe.write(entry)
    }
}

/**
 * 准备取消异步操作
 * 
 * @param sqe SQE 指针
 * @param userData 要取消的请求的用户数据
 * @param flags 取消标志
 */
@When[os == "Linux"]
public func ioUringPrepCancel64(
    sqe: CPointer<IOUringSQE>,
    userData: UInt64,
    flags: UInt32
): Unit {
    unsafe {
        var entry = sqe.read()
        entry.opcode = IORING_OP_ASYNC_CANCEL
        entry.flags = 0
        entry.ioprio = 0
        entry.fd = -1
        entry.off = 0
        entry.addr = userData  // userData 存储在 addr 字段
        entry.len = 0
        entry.rwFlags = flags  // cancel_flags 使用 rwFlags 字段
        entry.bufIndex = 0
        entry.personality = 0
        entry.spliceFdIn = 0
        entry.addr3 = 0
        sqe.write(entry)
    }
}

/**
 * 准备 nop 操作（无操作）
 * 
 * 用于测试或测量延迟。
 * 
 * @param sqe SQE 指针
 */
@When[os == "Linux"]
public func ioUringPrepNop(sqe: CPointer<IOUringSQE>): Unit {
    unsafe {
        var entry = sqe.read()
        entry.opcode = IORING_OP_NOP
        entry.flags = 0
        entry.ioprio = 0
        entry.fd = -1
        entry.off = 0
        entry.addr = 0
        entry.len = 0
        entry.rwFlags = 0
        entry.bufIndex = 0
        entry.personality = 0
        entry.spliceFdIn = 0
        entry.addr3 = 0
        sqe.write(entry)
    }
}
