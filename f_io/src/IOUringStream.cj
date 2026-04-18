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
package fountain::f_io

import std.io.IOStream
import std.sync.Mutex
import std.sync.AtomicBool
import std.core.Future
import fountain::f_io.uring.*
import fountain::f_io.uring.lockfree.*
import fountain::f_base.mcopy

/**
 * 基于 io_uring 的 IOStream 实现（双 ring 架构）
 *
 * 使用两个独立的 io_uring 实例分别处理读和写：
 * - writeRing: 后台收割线程收割 CQE，write() 提交后立即返回
 * - readRing: 调用线程内直接 submit + waitCQE，无跨线程通知开销
 *
 * 可选注册缓冲区（Registered Buffers）模式：
 * - 预注册一组固定大小缓冲区到内核，I/O 请求使用 READ_FIXED/WRITE_FIXED
 * - 内核跳过每次请求的地址验证，减少 ~0.3-1us/次的内核开销
 * - 代价：每次 read/write 需要额外一次 memcpy
 *
 * 使用示例：
 * ```cj
 * try(stream = IOUringStream(fd)) {
 *     stream.write("hello".unsafeBytes())
 *     let buf = Array<Byte>(64, repeat: 0)
 *     let n = stream.read(buf)
 * }
 * ```
 */
@When[os == "Linux"]
public class IOUringStream <: IOStream & Resource {
    /** 写 ring：无锁组件 + 后台收割线程 */
    private let lf: IoUringLockFree
    /** 写 ring 底层 IoUring 实例 */
    private let writeRing: IoUring
    /** 读 ring：调用线程直接 submit + waitCQE */
    private let readRing: IoUring
    /** 目标文件描述符 */
    private let fd: Int32
    /** 写偏移量 */
    private var writeOffset: UInt64 = 0
    /** 读偏移量 */
    private var readOffset: UInt64 = 0
    /** 提交锁（保护 writeRing 的 getSQE + flush） */
    private let writeMutex: Mutex = Mutex()
    /** 读提交锁（保护 readRing 的 getSQE + submit） */
    private let readMutex: Mutex = Mutex()
    /** 后台收割线程是否应该停止 */
    private let stopping: AtomicBool = AtomicBool(false)
    /** 后台收割线程的 Future */
    private var reaperFuture: ?Future<Unit> = None

    /** 是否使用注册缓冲区模式 */
    private let useFixedBufs: Bool
    /** 注册缓冲区大小（字节） */
    private let fixedBufSize: UInt32
    /** 注册缓冲区数量 */
    private let fixedBufCount: UInt32
    /** 注册缓冲区内存块（LibC.malloc 分配，连续存放） */
    private let fixedBufsPtr: CPointer<UInt8>
    /** 注册缓冲区索引分配器 */
    private let fixedBufAllocator: AtomicSlotAllocator
    /** 写 ring 的注册缓冲区 */
    private let writeRegBufs: ?RegisteredBuffers
    /** 读 ring 的注册缓冲区 */
    private let readRegBufs: ?RegisteredBuffers

    /**
     * 完整参数初始化
     *
     * @param fd 目标文件描述符
     * @param entries SQ 队列大小（必须是 2 的幂）
     * @param flags io_uring 初始化标志
     * @param fixedBufCount 注册缓冲区数量（0=不使用注册缓冲区，推荐 64）
     * @param fixedBufSize 注册缓冲区大小（字节，默认 4096）
     */
    public init(fd: Int32, entries: UInt32, flags!: UInt32 = 0, fixedBufCount!: UInt32 = 0, fixedBufSize!: UInt32 = 4096) {
        this.fd = fd
        this.writeRing = IoUring(entries, flags: flags)
        this.lf = IoUringLockFree(writeRing)
        this.readRing = IoUring(entries, flags: flags)

        // 注册缓冲区初始化
        if (fixedBufCount > 0) {
            this.useFixedBufs = true
            this.fixedBufSize = fixedBufSize
            this.fixedBufCount = fixedBufCount
            this.fixedBufsPtr = unsafe { LibC.malloc<UInt8>(count: Int64(fixedBufCount) * Int64(fixedBufSize)) }
            this.fixedBufAllocator = AtomicSlotAllocator(fixedBufCount)

            // 为写 ring 注册缓冲区
            let writeIOvecs = unsafe { LibC.malloc<IOVec>(count: Int64(fixedBufCount)) }
            unsafe {
                for (i in 0..Int64(fixedBufCount)) {
                    let base = fixedBufsPtr + (i * Int64(fixedBufSize))
                    var iov = IOVec()
                    iov.iovBase = CPointer<Unit>(base)
                    iov.iovLen = UIntNative(fixedBufSize)
                    (writeIOvecs + i).write(iov)
                }
            }
            this.writeRegBufs = RegisteredBuffers(writeRing, writeIOvecs, fixedBufCount)
            unsafe { LibC.free<IOVec>(writeIOvecs) }

            // 为读 ring 注册缓冲区
            let readIOvecs = unsafe { LibC.malloc<IOVec>(count: Int64(fixedBufCount)) }
            unsafe {
                for (i in 0..Int64(fixedBufCount)) {
                    let base = fixedBufsPtr + (i * Int64(fixedBufSize))
                    var iov = IOVec()
                    iov.iovBase = CPointer<Unit>(base)
                    iov.iovLen = UIntNative(fixedBufSize)
                    (readIOvecs + i).write(iov)
                }
            }
            this.readRegBufs = RegisteredBuffers(readRing, readIOvecs, fixedBufCount)
            unsafe { LibC.free<IOVec>(readIOvecs) }
        } else {
            this.useFixedBufs = false
            this.fixedBufSize = 0
            this.fixedBufCount = 0
            this.fixedBufsPtr = CPointer<UInt8>()
            this.fixedBufAllocator = AtomicSlotAllocator(1)
            this.writeRegBufs = None
            this.readRegBufs = None
        }

        startReaper()
    }

    /**
     * 简化初始化（不使用注册缓冲区）
     *
     * @param fd 目标文件描述符
     */
    public init(fd: Int32) {
        this.fd = fd
        this.writeRing = IoUring(64)
        this.lf = IoUringLockFree(writeRing)
        this.readRing = IoUring(64)

        this.useFixedBufs = false
        this.fixedBufSize = 0
        this.fixedBufCount = 0
        this.fixedBufsPtr = CPointer<UInt8>()
        this.fixedBufAllocator = AtomicSlotAllocator(1)
        this.writeRegBufs = None
        this.readRegBufs = None

        startReaper()
    }

    /**
     * 启动后台收割线程（仅收割 writeRing 的 CQE）
     */
    private func startReaper(): Unit {
        let reaperLf = lf
        let reaperStopping = stopping
        reaperFuture = spawn {
            while (!reaperStopping.load()) {
                try {
                    reaperLf.waitAndReap()
                } catch (_: Exception) {
                    break
                }
            }
        }
    }

    public func read(buffer: Array<Byte>): Int64 {
        let bufSize = buffer.size
        if (bufSize == 0) {
            return 0
        }
        let currentOffset = readOffset

        if (useFixedBufs) {
            return readFixed(buffer, bufSize, currentOffset)
        }
        return readNormal(buffer, bufSize, currentOffset)
    }

    private func readNormal(buffer: Array<Byte>, bufSize: Int64, currentOffset: UInt64): Int64 {
        synchronized(readMutex) {
            let sqeOpt = readRing.getSQE()
            if (let Some(sqe) <- sqeOpt) {
                unsafe {
                    let bufPtr = acquireArrayRawData(buffer)
                    ioUringPrepRead(sqe, fd, CPointer<Unit>(bufPtr.pointer), UInt32(bufSize), currentOffset)
                }
                ioUringSQESetData64(sqe, UInt64(1))
                readRing.submit()
            } else {
                return -1
            }

            let cqeOpt = readRing.waitCQE()
            if (let Some(cqe) <- cqeOpt) {
                let result = ioUringCQEGetRes(cqe)
                readRing.cqeSeen(cqe)
                if (result > 0) {
                    readOffset += UInt64(result)
                }
                Int64(result)
            } else {
                -1
            }
        }
    }

    private func readFixed(buffer: Array<Byte>, bufSize: Int64, currentOffset: UInt64): Int64 {
        // 分配注册缓冲区索引
        let bufIdxOpt = fixedBufAllocator.alloc()
        if (let Some(bufIdx) <- bufIdxOpt) {
            synchronized(readMutex) {
                let sqeOpt = readRing.getSQE()
                if (let Some(sqe) <- sqeOpt) {
                    let readLen = if (UInt32(bufSize) < fixedBufSize) { UInt32(bufSize) } else { fixedBufSize }
                    let fixedBase = unsafe { fixedBufsPtr + (Int64(bufIdx) * Int64(fixedBufSize)) }
                    ioUringPrepReadFixed(sqe, fd, CPointer<Unit>(fixedBase), readLen, currentOffset, UInt16(bufIdx))
                    ioUringSQESetData64(sqe, UInt64(1))
                    readRing.submit()
                } else {
                    fixedBufAllocator.release(bufIdx)
                    return -1
                }

                let cqeOpt = readRing.waitCQE()
                if (let Some(cqe) <- cqeOpt) {
                    let result = ioUringCQEGetRes(cqe)
                    readRing.cqeSeen(cqe)
                    if (result > 0) {
                        // 从注册缓冲区复制到用户缓冲区
                        unsafe {
                            let fixedBase = fixedBufsPtr + (Int64(bufIdx) * Int64(fixedBufSize))
                            let userBuf = acquireArrayRawData(buffer)
                            mcopy(CPointer<Unit>(userBuf.pointer), CPointer<Unit>(fixedBase), UIntNative(result))
                        }
                        readOffset += UInt64(result)
                    }
                    fixedBufAllocator.release(bufIdx)
                    Int64(result)
                } else {
                    fixedBufAllocator.release(bufIdx)
                    -1
                }
            }
        } else {
            // 无可用注册缓冲区，降级为普通模式
            readNormal(buffer, bufSize, currentOffset)
        }
    }

    public func write(buffer: Array<Byte>): Unit {
        let bufSize = buffer.size
        if (bufSize == 0) {
            return
        }
        let currentOffset = writeOffset
        writeOffset += UInt64(bufSize)

        if (useFixedBufs) {
            writeFixed(buffer, bufSize, currentOffset)
        } else {
            writeNormal(buffer, bufSize, currentOffset)
        }
    }

    private func writeNormal(buffer: Array<Byte>, bufSize: Int64, currentOffset: UInt64): Unit {
        let slotIdOpt = lf.allocSlot()
        if (let Some(slotId) <- slotIdOpt) {
            synchronized(writeMutex) {
                let sqeOpt = writeRing.getSQE()
                if (let Some(sqe) <- sqeOpt) {
                    unsafe {
                        let bufPtr = acquireArrayRawData(buffer)
                        ioUringPrepWrite(sqe, fd, CPointer<Unit>(bufPtr.pointer), UInt32(bufSize), currentOffset)
                    }
                    let gen = lf.setCallback(slotId, CompletionCallback.None)
                    let ud = lf.encodeUserData(slotId, gen)
                    ioUringSQESetData64(sqe, ud)
                    lf.commitSlot(slotId)
                    lf.flush()
                } else {
                    lf.releaseSlot(slotId)
                    writeOffset = currentOffset
                }
            }
        } else {
            writeOffset = currentOffset
        }
    }

    private func writeFixed(buffer: Array<Byte>, bufSize: Int64, currentOffset: UInt64): Unit {
        let bufIdxOpt = fixedBufAllocator.alloc()
        if (let Some(bufIdx) <- bufIdxOpt) {
            // 复制用户数据到注册缓冲区
            let writeLen = if (UInt32(bufSize) < fixedBufSize) { UInt32(bufSize) } else { fixedBufSize }
            unsafe {
                let fixedBase = fixedBufsPtr + (Int64(bufIdx) * Int64(fixedBufSize))
                let userBuf = acquireArrayRawData(buffer)
                mcopy(CPointer<Unit>(fixedBase), CPointer<Unit>(userBuf.pointer), UIntNative(writeLen))
            }

            let slotIdOpt = lf.allocSlot()
            if (let Some(slotId) <- slotIdOpt) {
                // 回调：释放注册缓冲区索引
                let allocator = fixedBufAllocator
                let callback = LambdaCompletionCallback({ _ =>
                    allocator.release(bufIdx)
                })

                synchronized(writeMutex) {
                    let sqeOpt = writeRing.getSQE()
                    if (let Some(sqe) <- sqeOpt) {
                        unsafe {
                            let fixedBase = fixedBufsPtr + (Int64(bufIdx) * Int64(fixedBufSize))
                            ioUringPrepWriteFixed(sqe, fd, CPointer<Unit>(fixedBase), writeLen, currentOffset, UInt16(bufIdx))
                        }
                        let gen = lf.setCallback(slotId, callback)
                        let ud = lf.encodeUserData(slotId, gen)
                        ioUringSQESetData64(sqe, ud)
                        lf.commitSlot(slotId)
                        lf.flush()
                    } else {
                        lf.releaseSlot(slotId)
                        fixedBufAllocator.release(bufIdx)
                        writeOffset = currentOffset
                    }
                }
            } else {
                fixedBufAllocator.release(bufIdx)
                writeOffset = currentOffset
            }
        } else {
            // 无可用注册缓冲区，降级为普通模式
            writeNormal(buffer, bufSize, currentOffset)
        }
    }

    public func flush(): Unit {
        // write 已经立即返回，flush 不需要额外操作
    }

    public func isClosed(): Bool {
        writeRing.isClosed()
    }

    public func close(): Unit {
        if (!writeRing.isClosed()) {
            stopping.store(true)
            synchronized(writeMutex) {
                let sqeOpt = writeRing.getSQE()
                if (let Some(sqe) <- sqeOpt) {
                    ioUringPrepNop(sqe)
                    ioUringSQESetData64(sqe, UInt64(0))
                    writeRing.submit()
                }
            }
            if (let Some(f) <- reaperFuture) {
                try {
                    f.get()
                } catch (_: Exception) {}
            }
            if (let Some(rb) <- writeRegBufs) {
                try { rb.close() } catch (_: Exception) {}
            }
            writeRing.close()
        }
        if (!readRing.isClosed()) {
            if (let Some(rb) <- readRegBufs) {
                try { rb.close() } catch (_: Exception) {}
            }
            readRing.close()
        }
        // 释放注册缓冲区内存
        if (useFixedBufs && !fixedBufsPtr.isNull()) {
            unsafe { LibC.free<UInt8>(fixedBufsPtr) }
        }
    }
}
