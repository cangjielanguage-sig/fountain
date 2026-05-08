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
package fountain::f_uring.lockfree

import fountain::f_uring.base.*

/**
 * 无锁 CQE 收割器
 *
 * 直接操作 CQ 的 head 指针实现批量收割，
 * 避免逐个调用 cqeSeen 的开销。
 *
 * 收割流程：
 * 1. 读取 CQ head 和 tail，计算可用 CQE 数量
 * 2. 批量遍历 CQE，处理完成回调
 * 3. 一次性推进 head 指针（单次原子写）
 *
 * 注意：本收割器不持有 IoUring 实例的引用，
 * 而是通过 ringPtr 操作，避免与 IoUring 类的生命周期耦合。
 */
@When[os == "Linux"]
public class LockFreeCQEReaper {
    /** 底层 IOUring 指针 */
    private let ringPtr: CPointer<IOUring>

    /**
     * 初始化收割器
     * @param ringPtr 底层 IOUring 指针（由调用者保证生命周期）
     */
    public init(ringPtr: CPointer<IOUring>) {
        this.ringPtr = ringPtr
    }

    /**
     * 非阻塞获取一个 CQE
     *
     * 直接从 CQ ring buffer 读取，不通过 liburing。
     * 调用者需在处理完成后调用 advance(1) 或 advanceBatch。
     *
     * @return CQE 指针和 CQ head 值的元组，无可用 CQE 时返回 None
     */
    public func peekCQE(): ?(CPointer<IOUringCQE>, UInt32) {
        unsafe {
            let ringVal = ringPtr.read()
            let cq = ringVal.cq
            let head = ioUringSmpLoadAcquire(cq.khead)
            let tail = ioUringSmpLoadAcquire(cq.ktail)
            if (head == tail) {
                return None
            }
            let shift = if ((ringVal.flags & IORING_SETUP_CQE32) != 0) { 1 } else { 0 }
            let index = (head & cq.ringMask) << shift
            let cqe = cq.cqes + Int64(index)
            if (cqe.isNull()) {
                None
            } else {
                Some((cqe, head))
            }
        }
    }

    /**
     * 推进 CQ head 指针指定数量
     *
     * 使用 release 语义写入，确保之前的 CQE 读取不会被重排到写之后。
     *
     * @param count 推进数量
     */
    public func advance(count: UInt32): Unit {
        unsafe {
            let cq = ringPtr.read().cq
            let head = ioUringSmpLoadAcquire(cq.khead)
            ioUringSmpStoreRelease(cq.khead, head + count)
        }
    }

    /**
     * 批量推进 CQ head 指针
     *
     * 与 advance 相同，语义更明确。
     *
     * @param count 推进数量
     */
    public func advanceBatch(count: UInt32): Unit {
        advance(count)
    }

    /**
     * 收割所有可用的 CQE
     *
     * 遍历 CQ 中所有 CQE，对每个 CQE 调用回调函数，
     * 最后一次性推进 head 指针。
     *
     * @param handler CQE 处理函数，参数为 (cqe, headIndex)
     * @return 收割的 CQE 数量
     */
    public func reapAll(handler: (CPointer<IOUringCQE>, UInt32) -> Unit): UInt32 {
        var count: UInt32 = 0
        unsafe {
            let ringVal = ringPtr.read()
            let cq = ringVal.cq
            var head = ioUringSmpLoadAcquire(cq.khead)
            let tail = ioUringSmpLoadAcquire(cq.ktail)
            let shift = if ((ringVal.flags & IORING_SETUP_CQE32) != 0) { 1 } else { 0 }

            while (head != tail) {
                let index = (head & cq.ringMask) << shift
                let cqe = cq.cqes + Int64(index)
                if (!cqe.isNull()) {
                    handler(cqe, head)
                }
                head += 1
                count += 1
            }

            // 一次性推进 head
            if (count > 0) {
                ioUringSmpStoreRelease(cq.khead, head)
            }
        }
        count
    }

    /**
     * 收割指定数量的 CQE
     *
     * @param maxCount 最多收割数量
     * @param handler CQE 处理函数
     * @return 实际收割的 CQE 数量
     */
    public func reapN(maxCount: UInt32, handler: (CPointer<IOUringCQE>, UInt32) -> Unit): UInt32 {
        var count: UInt32 = 0
        unsafe {
            let ringVal = ringPtr.read()
            let cq = ringVal.cq
            var head = ioUringSmpLoadAcquire(cq.khead)
            let tail = ioUringSmpLoadAcquire(cq.ktail)
            let shift = if ((ringVal.flags & IORING_SETUP_CQE32) != 0) { 1 } else { 0 }

            while (head != tail && count < maxCount) {
                let index = (head & cq.ringMask) << shift
                let cqe = cq.cqes + Int64(index)
                if (!cqe.isNull()) {
                    handler(cqe, head)
                }
                head += 1
                count += 1
            }

            if (count > 0) {
                ioUringSmpStoreRelease(cq.khead, head)
            }
        }
        count
    }

    /**
     * 获取 CQ 中待处理的 CQE 数量
     */
    public func cqReady(): UInt32 {
        ioUringCQReady(ringPtr)
    }
}
