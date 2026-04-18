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
import fountain::f_io.uring.*
import fountain::f_io.uring.lockfree.*

/**
 * 基于 io_uring 的 IOStream 实现
 *
 * 通过 IoUringLockFree 异步提交读写请求，同步等待完成，实现指定文件描述符的读写。
 * 使用自定义 CompletionCallback 子类存储结果，避免仓颉 lambda 不可捕获可变变量的限制。
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
    /** 底层无锁 io_uring 实例 */
    private let lf: IoUringLockFree
    /** 目标文件描述符 */
    private let fd: Int32
    /** 当前读写偏移量 */
    private var offset: UInt64 = 0

    /**
     * 完整参数初始化
     *
     * @param fd 目标文件描述符
     * @param entries SQ 队列大小（必须是 2 的幂）
     * @param flags io_uring 初始化标志
     * @param slotCount 完成槽位数量（必须是 2 的幂，0 表示与 entries 相同）
     */
    public init(fd: Int32, entries: UInt32, flags!: UInt32 = 0, slotCount!: UInt32 = 0) {
        this.fd = fd
        let ring = IoUring(entries, flags: flags)
        this.lf = IoUringLockFree(ring, slotCount: slotCount)
    }

    /**
     * 最简初始化
     *
     * 使用默认队列大小 64，无特殊标志。
     *
     * @param fd 目标文件描述符
     */
    public init(fd: Int32) {
        this.fd = fd
        let ring = IoUring(64)
        this.lf = IoUringLockFree(ring)
    }

    public func read(buffer: Array<Byte>): Int64 {
        let bufSize = buffer.size
        if (bufSize == 0) {
            return 0
        }
        let callback = ResultCallback()
        let success = lf.submitAsync(
            { sqe =>
                unsafe {
                    let bufPtr = acquireArrayRawData(buffer)
                    ioUringPrepRead(sqe, fd, CPointer<Unit>(bufPtr.pointer), UInt32(bufSize), offset)
                }
            },
            callback
        )
        if (!success) {
            return -1
        }
        awaitCallback(callback)
        if (callback.result > 0) {
            offset += UInt64(callback.result)
        }
        Int64(callback.result)
    }

    public func write(buffer: Array<Byte>): Unit {
        let bufSize = buffer.size
        if (bufSize == 0) {
            return
        }
        let callback = ResultCallback()
        let success = lf.submitAsync(
            { sqe =>
                unsafe {
                    let bufPtr = acquireArrayRawData(buffer)
                    ioUringPrepWrite(sqe, fd, CPointer<Unit>(bufPtr.pointer), UInt32(bufSize), offset)
                }
            },
            callback
        )
        if (!success) {
            return
        }
        awaitCallback(callback)
        if (callback.result > 0) {
            offset += UInt64(callback.result)
        }
    }

    public func flush(): Unit {
        lf.reap()
    }

    public func isClosed(): Bool {
        lf.isClosed()
    }

    public func close(): Unit {
        lf.close()
    }

    /**
     * 轮询收割直到回调完成
     */
    private func awaitCallback(callback: ResultCallback): Unit {
        while (!callback.completed) {
            lf.reap()
            if (!callback.completed) {
                sleep(Duration.millisecond)
            }
        }
    }
}

/**
 * 读写结果回调
 *
 * 将 CQE 结果存储在自身字段中，绕过仓颉 lambda 不可捕获可变变量的限制。
 */
@When[os == "Linux"]
class ResultCallback <: CompletionCallback {
    public var result: Int32 = 0
    public var completed: Bool = false

    public func onComplete(cqe: CPointer<IOUringCQE>): Unit {
        result = ioUringCQEGetRes(cqe)
        completed = true
    }
}
