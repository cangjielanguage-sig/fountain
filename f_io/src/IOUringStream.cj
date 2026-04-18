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

/**
 * 基于 io_uring 的 IOStream 实现（双 ring 架构）
 *
 * 使用两个独立的 io_uring 实例分别处理读和写：
 * - writeRing: 后台收割线程收割 CQE，write() 提交后立即返回
 * - readRing: 调用线程内直接 submit + waitCQE，无跨线程通知开销
 *
 * 双 ring 架构消除了 read 路径的 Condition wait/notifyAll 线程同步开销，
 * 使 read 性能接近直接系统调用。
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

    /**
     * 完整参数初始化
     *
     * @param fd 目标文件描述符
     * @param entries SQ 队列大小（必须是 2 的幂）
     * @param flags io_uring 初始化标志
     */
    public init(fd: Int32, entries: UInt32, flags!: UInt32 = 0) {
        this.fd = fd
        this.writeRing = IoUring(entries, flags: flags)
        this.lf = IoUringLockFree(writeRing)
        this.readRing = IoUring(entries, flags: flags)
        startReaper()
    }

    /**
     * 简化初始化
     *
     * @param fd 目标文件描述符
     */
    public init(fd: Int32) {
        this.fd = fd
        this.writeRing = IoUring(64)
        this.lf = IoUringLockFree(writeRing)
        this.readRing = IoUring(64)
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

        synchronized(readMutex) {
            let sqeOpt = readRing.getSQE()
            if (let Some(sqe) <- sqeOpt) {
                unsafe {
                    let bufPtr = acquireArrayRawData(buffer)
                    ioUringPrepRead(sqe, fd, CPointer<Unit>(bufPtr.pointer), UInt32(bufSize), currentOffset)
                }
                ioUringSQESetData64(sqe, UInt64(1))  // userData != 0 标识这是read的SQE
                readRing.submit()
            } else {
                return -1
            }

            // 在同一线程内阻塞等待CQE（无跨线程通知开销）
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

    public func write(buffer: Array<Byte>): Unit {
        let bufSize = buffer.size
        if (bufSize == 0) {
            return
        }
        let currentOffset = writeOffset
        writeOffset += UInt64(bufSize)

        let slotIdOpt = lf.allocSlot()
        if (let Some(slotId) <- slotIdOpt) {
            synchronized(writeMutex) {
                let sqeOpt = writeRing.getSQE()
                if (let Some(sqe) <- sqeOpt) {
                    unsafe {
                        let bufPtr = acquireArrayRawData(buffer)
                        ioUringPrepWrite(sqe, fd, CPointer<Unit>(bufPtr.pointer), UInt32(bufSize), currentOffset)
                    }
                    // 设置 None 回调，收割器自动释放 slot，无需创建 LambdaCompletionCallback
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

    public func flush(): Unit {
        // write 已经立即返回，flush 不需要额外操作
    }

    public func isClosed(): Bool {
        writeRing.isClosed()
    }

    public func close(): Unit {
        if (!writeRing.isClosed()) {
            // 停止后台收割线程
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
            writeRing.close()
        }
        if (!readRing.isClosed()) {
            readRing.close()
        }
    }
}
