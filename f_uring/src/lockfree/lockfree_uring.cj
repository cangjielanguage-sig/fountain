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
import std.sync.Mutex

/**
 * 无锁 IoUring 封装
 *
 * 整合 AtomicSlotAllocator、CompletionSlotArray、SQEPreallocator、LockFreeCQEReaper，
 * 提供端到端的无锁并发提交和收割能力。
 *
 * 架构：
 * - 提交路径：allocSlot → getSQE → 填写 SQE → commitSlot → flush
 *   多线程可并发分配和填写 SQE，flush 串行化 tail 更新
 * - 收割路径：reap → 解码 userData → invokeAndRelease → release
 *   CQE 收割是单线程的（CQ 由单线程收割），回调内释放槽位
 * - userData 编码：[generation : slotIndex]，generation 防止 ABA
 *
 * 使用示例：
 * ```cj
 * try(ring = IoUring(64)) {
 *     let lf = IoUringLockFree(ring)
 *     // 提交异步操作
 *     let slotId = lf.allocSlot()
 *     if (let Some(id) <- slotId) {
 *         let sqe = lf.getSQE(id)
 *         ioUringPrepRead(sqe, fd, buf, len, 0)
 *         let gen = lf.setCallback(id, LambdaCompletionCallback({ cqe =>
 *             println("result: ${ioUringCQEGetRes(cqe)}")
 *         }))
 *         ioUringSQESetData64(sqe, lf.encodeUserData(id, gen))
 *         lf.commitSlot(id)
 *         lf.flush()
 *     }
 *     // 收割完成事件
 *     lf.reap()
 * }
 * ```
 */
@When[os == "Linux"]
public class IoUringLockFree <: Resource {
    /** 底层 IoUring 实例 */
    private let ring: IoUring
    /** 原子槽位分配器 */
    private let allocator: AtomicSlotAllocator
    /** 完成槽位数组 */
    private let slots: CompletionSlotArray
    /** SQE 预分配器 */
    private let sqePool: SQEPreallocator
    /** CQE 收割器 */
    private let reaper: LockFreeCQEReaper
    /** 提交互斥锁（保护 getSQE + submit 的原子性） */
    private let submitMutex: Mutex = Mutex()
    /** 是否已关闭 */
    private var closed: Bool = false

    /**
     * 初始化无锁 IoUring
     *
     * @param ring 已初始化的 IoUring 实例（调用者不负责关闭，由本类管理）
     * @param slotCount 槽位数量（必须是 2 的幂，默认与 ring 的 entries 相同）
     * @throws IoUringException slotCount 不合法时抛出
     */
    public init(ring: IoUring, slotCount!: UInt32 = 0) {
        this.ring = ring
        let actualSlotCount = if (slotCount == 0) {
            ring.sqSpaceLeft()
        } else {
            slotCount
        }
        this.allocator = AtomicSlotAllocator(actualSlotCount)
        this.slots = CompletionSlotArray(actualSlotCount)
        this.sqePool = SQEPreallocator(ring.unsafeRingPtr(), ring.sqSpaceLeft())
        this.reaper = LockFreeCQEReaper(ring.unsafeRingPtr())
    }

    // ==================== 提交路径 ====================

    /**
     * 分配一个完成槽位
     *
     * 当所有槽位被占用时，先尝试收割已完成的 CQE 来释放槽位。
     * 仍无可用槽位时短时等待后台收割线程处理，永不返回 None。
     *
     * @return 槽位索引
     */
    public func allocSlot(): ?UInt32 {
        checkNotClosed()
        var slotId = allocator.alloc()
        while (slotId.isNone()) {
            // 非阻塞收割已完成的 CQE 以释放槽位
            reap()
            slotId = allocator.alloc()
            if (slotId.isNone()) {
                // 让步给后台收割线程处理，避免忙等
                sleep(Duration.microsecond * 10)
            }
        }
        slotId
    }

    /**
     * 释放一个已分配的完成槽位
     *
     * 在提交失败等场景下手动释放槽位。
     * 正常完成路径由收割器在 invokeAndRelease 后自动释放。
     *
     * @param slotIndex 槽位索引（由 allocSlot 返回）
     */
    public func releaseSlot(slotIndex: UInt32): Unit {
        allocator.release(slotIndex)
    }

    /**
     * 获取指定索引的 SQE 指针
     *
     * @param slotIndex 槽位索引（由 allocSlot 返回）
     * @return SQE 指针
     */
    public func getSQE(slotIndex: UInt32): CPointer<IOUringSQE> {
        checkNotClosed()
        sqePool.getSQE(slotIndex)
    }

    /**
     * 设置槽位回调
     *
     * @param slotIndex 槽位索引
     * @param callback 完成回调
     * @return generation 值（用于编码 userData）
     */
    public func setCallback(slotIndex: UInt32, callback: CompletionCallback): UInt32 {
        checkNotClosed()
        slots.setCallback(slotIndex, callback)
    }

    /**
     * 编码 userData
     *
     * 将 slotIndex 和 generation 打包为可放入 SQE userData 的 UInt64。
     *
     * @param slotIndex 槽位索引
     * @param generation generation 值（由 setCallback 返回）
     * @return 打包的 UInt64
     */
    public func encodeUserData(slotIndex: UInt32, generation: UInt32): UInt64 {
        slots.encodeUserData(slotIndex, generation)
    }

    /**
     * 标记槽位已准备好提交
     * @param slotIndex 槽位索引
     */
    public func commitSlot(slotIndex: UInt32): Unit {
        checkNotClosed()
        sqePool.commitSlot(slotIndex)
    }

    /**
     * 批量提交所有已准备好的 SQE
     * @return 提交的 SQE 数量，负值表示错误
     */
    public func flush(): Int32 {
        checkNotClosed()
        sqePool.flush()
    }

    // ==================== 收割路径 ====================

    /**
     * 收割所有可用的 CQE
     *
     * 遍历 CQ 中的所有 CQE，解码 userData 查找对应槽位，
     * 调用回调并释放槽位。
     *
     * @return 收割的 CQE 数量
     */
    public func reap(): UInt32 {
        checkNotClosed()
        reaper.reapAll({ cqe, _ =>
            let userData = ioUringCQEGetData64(cqe)
            if (userData != 0) {
                let (slotIndex, generation) = slots.decodeUserData(userData)
                let invoked = slots.invokeAndRelease(slotIndex, generation, cqe)
                if (invoked) {
                    allocator.release(slotIndex)
                }
            }
        })
    }

    /**
     * 收割指定数量的 CQE
     *
     * @param maxCount 最多收割数量
     * @return 实际收割的 CQE 数量
     */
    public func reapN(maxCount: UInt32): UInt32 {
        checkNotClosed()
        reaper.reapN(maxCount, { cqe, _ =>
            let userData = ioUringCQEGetData64(cqe)
            if (userData != 0) {
                let (slotIndex, generation) = slots.decodeUserData(userData)
                if (slots.invokeAndRelease(slotIndex, generation, cqe)) {
                    allocator.release(slotIndex)
                }
            }
        })
    }

    /**
     * 阻塞等待并收割至少一个 CQE
     *
     * 先尝试非阻塞收割，如果 CQ 为空则调用 waitCQE 阻塞等待。
     *
     * @return 收割的 CQE 数量
     */
    public func waitAndReap(): UInt32 {
        checkNotClosed()
        // 先尝试非阻塞收割一个 CQE（避免一次处理所有，保证可被多次调用逐次收割）
        var count = reaper.reapN(1, { cqe, _ =>
            let userData = ioUringCQEGetData64(cqe)
            if (userData != 0) {
                let (slotIndex, generation) = slots.decodeUserData(userData)
                let invoked = slots.invokeAndRelease(slotIndex, generation, cqe)
                if (invoked) {
                    allocator.release(slotIndex)
                }
            }
        })
        if (count > 0) {
            return count
        }
        // 阻塞等待一个 CQE（SQE 已经由 submitAsync 提交，不再 re-submit）
        let cqeOpt = ring.waitCQE()
        if (let Some(cqe) <- cqeOpt) {
            let userData = ioUringCQEGetData64(cqe)
            if (userData != 0) {
                let (slotIndex, generation) = slots.decodeUserData(userData)
                let invoked = slots.invokeAndRelease(slotIndex, generation, cqe)
                if (invoked) {
                    allocator.release(slotIndex)
                }
            }
            ring.cqeSeen(cqe)
            count + 1
        } else {
            0
        }
    }

    // ==================== 便捷提交方法 ====================

    /**
     * 提交一个异步操作（完整流程：alloc → getSQE → setCallback → commit → flush）
     *
     * @param prepFn SQE 准备函数，参数为 SQE 指针
     * @param callback 完成回调
     * @return 提交成功返回 true，槽位不足或 SQ 满时返回 false
     */
    public func submitAsync(prepFn: (CPointer<IOUringSQE>) -> Unit, callback: CompletionCallback): Bool {
        checkNotClosed()
        let slotIdOpt = allocSlot()
        if (let Some(slotId) <- slotIdOpt) {
            // getSQE + submit 必须原子化，否则多线程并发会导致 SQ tail 竞争
            synchronized(submitMutex) {
                let sqeOpt = ring.getSQE()
                if (let Some(sqe) <- sqeOpt) {
                    prepFn(sqe)
                    let gen = setCallback(slotId, callback)
                    let ud = encodeUserData(slotId, gen)
                    ioUringSQESetData64(sqe, ud)
                    let submitRet = ring.submit()
                    true
                } else {
                    // SQE 不足，释放完成槽位
                    allocator.release(slotId)
                    false
                }
            }
        } else {
            false
        }
    }

    // ==================== 状态查询 ====================

    /**
     * 获取底层 IoUring 实例
     */
    public func getRing(): IoUring {
        ring
    }

    /**
     * 获取 CQ 中待处理的 CQE 数量
     */
    public func cqReady(): UInt32 {
        reaper.cqReady()
    }

    /**
     * 获取槽位分配器中已分配的槽位数量
     */
    public func allocatedSlotCount(): UInt32 {
        // 使用 O(1) 缓存计数，免遍历位图
        allocator.getAllocatedCount()
    }

    // ==================== Resource 接口 ====================

    public func isClosed(): Bool {
        closed
    }

    public func close(): Unit {
        if (!closed) {
            closed = true
            // 关闭底层 ring
            if (!ring.isClosed()) {
                ring.close()
            }
        }
    }

    // ==================== 私有辅助 ====================

    private func checkNotClosed(): Unit {
        if (closed) {
            throw IoUringException("IoUringLockFree instance has been closed")
        }
    }
}
