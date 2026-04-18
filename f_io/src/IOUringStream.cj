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
 * 基于 io_uring 的 IOStream 实现
 *
 * 使用 IoUringLockFree 无锁组件 + 后台收割线程架构：
 * - 后台线程循环调用 waitAndReap 收割 CQE，触发回调完成 Promise
 * - read(): 提交读请求后阻塞等待 Promise 完成（无数据则一直阻塞）
 * - write(): 提交写请求后立即返回（不等待内核完成确认）
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
    /** 底层无锁 IoUring 封装 */
    private let lf: IoUringLockFree
    /** 底层 IoUring 实例（用于 nop 唤醒和关闭） */
    private let ring: IoUring
    /** 目标文件描述符 */
    private let fd: Int32
    /** 当前读写偏移量 */
    private var offset: UInt64 = 0
    /** 提交锁（保护 getSQE + submit 的原子性） */
    private let submitMutex: Mutex = Mutex()
    /** 后台收割线程是否应该停止 */
    private let stopping: AtomicBool = AtomicBool(false)
    /** 后台收割线程的 Future，用于 close 时等待线程退出 */
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
        this.ring = IoUring(entries, flags: flags)
        this.lf = IoUringLockFree(ring)
        startReaper()
    }

    /**
     * 简化初始化
     *
     * @param fd 目标文件描述符
     */
    public init(fd: Int32) {
        this.fd = fd
        this.ring = IoUring(64)
        this.lf = IoUringLockFree(ring)
        startReaper()
    }

    /**
     * 启动后台收割线程
     */
    private func startReaper(): Unit {
        let reaperLf = lf
        let reaperStopping = stopping
        reaperFuture = spawn {
            while (!reaperStopping.load()) {
                try {
                    reaperLf.waitAndReap()
                } catch (_: Exception) {
                    // ring 已关闭或出错，退出循环
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
        let currentOffset = offset
        offset += UInt64(bufSize)

        let slotIdOpt = lf.allocSlot()
        if (let Some(slotId) <- slotIdOpt) {
            // 创建 Promise 用于阻塞等待
            let promise = IoUringPromise<Int32>(UInt64(slotId), { cqe => ioUringCQEGetRes(cqe) })
            let callback = LambdaCompletionCallback({ cqe =>
                promise.complete(cqe)
            })

            synchronized(submitMutex) {
                let sqeOpt = ring.getSQE()
                if (let Some(sqe) <- sqeOpt) {
                    unsafe {
                        let bufPtr = acquireArrayRawData(buffer)
                        ioUringPrepRead(sqe, fd, CPointer<Unit>(bufPtr.pointer), UInt32(bufSize), currentOffset)
                    }
                    let gen = lf.setCallback(slotId, callback)
                    let ud = lf.encodeUserData(slotId, gen)
                    ioUringSQESetData64(sqe, ud)
                    lf.commitSlot(slotId)
                    lf.flush()
                } else {
                    lf.releaseSlot(slotId)
                    offset = currentOffset
                    return -1
                }
            }

            // 阻塞等待读完成
            let result = promise.awaitResult()
            if (result <= 0) {
                offset = currentOffset
            }
            Int64(result)
        } else {
            offset = currentOffset
            -1
        }
    }

    public func write(buffer: Array<Byte>): Unit {
        let bufSize = buffer.size
        if (bufSize == 0) {
            return
        }
        let currentOffset = offset
        offset += UInt64(bufSize)

        let slotIdOpt = lf.allocSlot()
        if (let Some(slotId) <- slotIdOpt) {
            // 写操作不需要阻塞等待，回调仅释放槽位
            let allocator = lf
            let callback = LambdaCompletionCallback({ _ =>
                allocator.releaseSlot(slotId)
            })

            synchronized(submitMutex) {
                let sqeOpt = ring.getSQE()
                if (let Some(sqe) <- sqeOpt) {
                    unsafe {
                        let bufPtr = acquireArrayRawData(buffer)
                        ioUringPrepWrite(sqe, fd, CPointer<Unit>(bufPtr.pointer), UInt32(bufSize), currentOffset)
                    }
                    let gen = lf.setCallback(slotId, callback)
                    let ud = lf.encodeUserData(slotId, gen)
                    ioUringSQESetData64(sqe, ud)
                    lf.commitSlot(slotId)
                    lf.flush()
                } else {
                    lf.releaseSlot(slotId)
                    offset = currentOffset
                }
            }
            // 写操作立即返回，不等待内核完成
        } else {
            offset = currentOffset
        }
    }

    public func flush(): Unit {
        // write 已经立即返回，flush 不需要额外操作
        // 如果需要确保数据落盘，调用者应使用 fsync
    }

    public func isClosed(): Bool {
        ring.isClosed()
    }

    public func close(): Unit {
        if (!ring.isClosed()) {
            // 通知后台线程停止
            stopping.store(true)
            // 提交一个 nop 请求唤醒后台线程（它可能在 waitCQE 中阻塞）
            synchronized(submitMutex) {
                let sqeOpt = ring.getSQE()
                if (let Some(sqe) <- sqeOpt) {
                    ioUringPrepNop(sqe)
                    ioUringSQESetData64(sqe, UInt64(0))
                    ring.submit()
                }
            }
            // 等待后台线程退出
            if (let Some(f) <- reaperFuture) {
                try {
                    f.get()
                } catch (_: Exception) {
                    // 后台线程异常退出，忽略
                }
            }
            ring.close()
        }
    }
}
