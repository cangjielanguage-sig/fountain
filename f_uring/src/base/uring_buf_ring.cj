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
package fountain::f_uring.base

/**
 * Buffer Ring 高级封装
 *
 * io_uring 的 provided buffer ring 机制允许应用预注册一组缓冲区，
 * 内核在完成 I/O 时自动从 ring 中选取缓冲区，避免每次请求显式指定。
 *
 * Buffer Ring 本质上是一个由 IOUringBuf 条目组成的环形队列，
 * 应用向 ring 中添加缓冲区（add），内核消费后通过 CQE 的 flags
 * 返回所使用的缓冲区 ID（bid）。
 *
 * 线程安全：
 * - add + advance 的组合不是原子的，多线程并发添加需要外部同步
 * - 推荐模式：单线程添加缓冲区，或使用每线程独立的 bgid
 *
 * 使用示例：
 * ```cj
 * try(ring = IoUring(64)) {
 *     try(bufRing = IOUringBufferRing(ring, 16, 1)) {
 *         // 添加缓冲区
 *         bufRing.add(bufAddr, 4096, 0)
 *         bufRing.add(bufAddr2, 4096, 1)
 *         bufRing.advance(2)
 *
 *         // 提交使用 BUFFER_SELECT 的读请求
 *         if (let Some(sqe) <- ring.getSQE()) {
 *             ioUringPrepRead(sqe, fd, CPointer<Unit>(), 4096, 0)
 *             ioUringSQESetFlags(sqe, IOSQE_BUFFER_SELECT)
 *             sqe.read().bufGroup = 1  // bgid
 *             ring.submit()
 *         }
 *
 *         // 完成后 CQE flags 包含 bid
 *         if (let Some(cqe) <- ring.waitCQE()) {
 *             if ((cqe.read().flags & IORING_CQE_F_BUFFER) != 0) {
 *                 let bid = UInt16(cqe.read().flags >> IORING_CQE_BUFFER_SHIFT)
 *                 println("used buffer id: ${bid}")
 *             }
 *             ring.cqeSeen(cqe)
 *         }
 *     }
 * }
 * ```
 */
@When[os == "Linux"]
public class IOUringBufferRing <: Resource {
    /** 底层 IoUring 实例（不持有所有权） */
    private let ring: IoUring
    /** Buffer ring 共享内存指针 */
    private let bufRingPtr: CPointer<Unit>
    /** Ring 条目数量 */
    private let nentries: UInt32
    /** Buffer group ID */
    private let bgid: Int32
    /** Ring mask（nentries - 1） */
    private let mask: Int64
    /** 是否已关闭 */
    private var closed: Bool = false

    /**
     * 初始化 Buffer Ring
     *
     * 调用 io_uring_setup_buf_ring 注册 buffer ring。
     * 成功后 ring 中即可使用 IOSQE_BUFFER_SELECT 选择缓冲区。
     *
     * @param ring 已初始化的 IoUring 实例
     * @param nentries 条目数量（必须是 2 的幂，最大 32768）
     * @param bgid buffer group ID（0-65535），用于 SQE 的 buf_group 字段
     * @param flags 注册标志，目前支持 IOU_PBUF_RING_MMAP
     * @throws IoUringException 注册失败时抛出
     */
    public init(ring: IoUring, nentries: UInt32, bgid!: Int32 = 0, flags!: UInt32 = 0) {
        this.ring = ring
        this.nentries = nentries
        this.bgid = bgid
        this.mask = Int64(nentries - 1)

        let retSlot = unsafe { LibC.malloc<Int32>(count: 1) }
        unsafe { retSlot.write(0) }

        let brPtr = unsafe {
            io_uring_setup_buf_ring(ring.unsafeRingPtr(), nentries, bgid, flags, retSlot)
        }
        let retCode = unsafe { retSlot.read() }
        unsafe { LibC.free<Int32>(retSlot) }

        if (brPtr.isNull()) {
            throw IoUringException("io_uring_setup_buf_ring failed: ${retCode}")
        }

        this.bufRingPtr = unsafe { CPointer<Unit>(brPtr) }
    }

    // ==================== 缓冲区操作 ====================

    /**
     * 添加一个缓冲区到 ring
     *
     * 将缓冲区信息写入 ring 的指定位置，但不推进 tail。
     * 需要在调用 add 后调用 advance 使缓冲区对内核可见。
     *
     * 典型用法：先批量调用 add 添加多个缓冲区，再调用 advance 一次推进。
     *
     * @param addr 缓冲区起始地址
     * @param len 缓冲区长度（字节）
     * @param bid 缓冲区 ID，CQE 完成时通过此 ID 标识使用的缓冲区
     * @param bufOffset 相对当前 tail 的偏移（批量添加时递增：0, 1, 2, ...）
     */
    public func add(addr: UInt64, len: UInt32, bid: UInt16, bufOffset!: Int64 = 0): Unit {
        checkNotClosed()
        // 计算写入位置：(tail + bufOffset) & mask
        let tail = bufRingGetTail(bufRingPtr)
        let index = (Int64(tail) + bufOffset) & mask
        bufRingSetBuf(bufRingPtr, index, nentries, addr, len, bid)
    }

    /**
     * 推进 buffer ring 的 tail
     *
     * 使之前添加的缓冲区对内核可见。内核只能看到 tail 之前的缓冲区。
     *
     * @param count 推进的缓冲区数量（应与之前 add 的数量一致）
     */
    public func advance(count: UInt32): Unit {
        checkNotClosed()
        let tail = bufRingGetTail(bufRingPtr)
        bufRingSetTail(bufRingPtr, UInt16((Int64(tail) + Int64(count)) & 0xFFFF))
    }

    /**
     * 添加并推进一个缓冲区（便捷方法）
     *
     * 等价于 add(addr, len, bid) + advance(1)。
     *
     * @param addr 缓冲区起始地址
     * @param len 缓冲区长度
     * @param bid 缓冲区 ID
     */
    public func addAndAdvance(addr: UInt64, len: UInt32, bid: UInt16): Unit {
        add(addr, len, bid)
        advance(1)
    }

    // ==================== 状态查询 ====================

    /**
     * 获取 buffer group ID
     */
    public func getBgid(): Int32 {
        bgid
    }

    /**
     * 获取 ring 条目数量
     */
    public func getNentries(): UInt32 {
        nentries
    }

    /**
     * 获取 ring mask
     */
    public func getMask(): Int64 {
        mask
    }

    /**
     * 获取当前 tail 值
     */
    public func getTail(): UInt16 {
        bufRingGetTail(bufRingPtr)
    }

    /**
     * 获取指定索引的缓冲区信息
     *
     * @param index 缓冲区索引
     * @return IOUringBuf 实例
     */
    public func getBuf(index: Int64): IOUringBuf {
        checkNotClosed()
        bufRingGetBuf(bufRingPtr, index, nentries)
    }

    // ==================== Resource 接口 ====================

    public func isClosed(): Bool {
        closed
    }

    public func close(): Unit {
        if (!closed) {
            closed = true
            if (!ring.isClosed()) {
                unsafe {
                    io_uring_free_buf_ring(
                        ring.unsafeRingPtr(),
                        CPointer<IOUringBuf>(bufRingPtr),
                        nentries,
                        bgid
                    )
                }
            }
        }
    }

    // ==================== 私有辅助 ====================

    private func checkNotClosed(): Unit {
        if (closed) {
            throw IoUringException("IOUringBufferRing instance has been closed")
        }
    }
}
