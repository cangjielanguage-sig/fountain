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
package fountain::f_io.uring.lockfree

import fountain::f_io.uring.*
import std.sync.AtomicUInt32

/**
 * 无锁 SQE 预分配器
 *
 * 在多线程提交场景中，使用 io_uring_get_sqe 获取 SQE 并推进 tail，
 * 各线程独立填写 SQE 后，通过 flush 批量提交到内核。
 *
 * 工作流程：
 * 1. allocSlot() — 调用 io_uring_get_sqe 获取 SQE（tail 自动推进）
 * 2. getSQE(index) — 通过索引获取已分配的 SQE 指针
 * 3. commitSlot(index) — 标记该槽位已准备好提交
 * 4. flush() — 将所有已准备好的 SQE 提交到内核
 *
 * 注意：本预分配器不持有 IoUring 实例的引用，
 * 而是通过 ringPtr 操作，避免与 IoUring 类的生命周期耦合。
 */
@When[os == "Linux"]
public class SQEPreallocator {
    /** 底层 IOUring 指针 */
    private let ringPtr: CPointer<IOUring>
    /** SQ 队列大小 */
    private let sqEntries: UInt32
    /** 已分配的 SQE 指针数组 */
    private let sqeSlots: Array<CPointer<IOUringSQE>>
    /** 已填写完成待提交的 SQE 数量 */
    private let prepared: AtomicUInt32 = AtomicUInt32(0)
    /** 已分配的 SQE 数量 */
    private let allocated: AtomicUInt32 = AtomicUInt32(0)

    /**
     * 初始化预分配器
     * @param ringPtr 底层 IOUring 指针（由调用者保证生命周期）
     * @param sqEntries SQ 队列大小（即 ring 的 entries 参数）
     */
    public init(ringPtr: CPointer<IOUring>, sqEntries: UInt32) {
        this.ringPtr = ringPtr
        this.sqEntries = sqEntries
        this.sqeSlots = Array<CPointer<IOUringSQE>>(Int64(sqEntries)) { _ =>
            CPointer<IOUringSQE>()
        }
    }

    /**
     * 分配一个 SQE
     *
     * 通过 io_uring_get_sqe 获取空闲 SQE，tail 自动推进。
     *
     * @return SQE 索引，SQ 满时返回 None
     */
    public func allocSlot(): ?UInt32 {
        let idx = allocated.fetchAdd(1)
        if (idx >= sqEntries) {
            // 超出容量，回滚
            allocated.fetchSub(1)
            return None
        }
        // 使用 io_uring_get_sqe 获取 SQE（会正确推进 sqeTail）
        unsafe {
            let sqe = ioUringGetSQEFFI(ringPtr)
            if (sqe.isNull()) {
                // 无法获取 SQE，回滚
                allocated.fetchSub(1)
                return None
            }
            sqeSlots[Int64(idx)] = sqe
        }
        Some(idx)
    }

    /**
     * 通过索引获取 SQE 指针
     *
     * @param index SQE 索引（由 allocSlot 返回）
     * @return SQE 指针
     */
    public func getSQE(index: UInt32): CPointer<IOUringSQE> {
        sqeSlots[Int64(index)]
    }

    /**
     * 标记一个槽位已准备好提交
     *
     * @param index SQE 索引
     */
    public func commitSlot(index: UInt32): Unit {
        prepared.fetchAdd(1)
    }

    /**
     * 批量提交所有已准备好的 SQE
     *
     * io_uring_get_sqe 已推进 sqeTail，这里只需调用 io_uring_submit。
     *
     * @return 提交的 SQE 数量
     */
    public func flush(): Int32 {
        let count = prepared.load()
        if (count == 0) {
            return 0
        }
        // io_uring_get_sqe 已推进 sqeTail，直接提交
        let ret = unsafe { ioUringSubmitFFI(ringPtr) }
        // 重置计数器
        allocated.store(0)
        prepared.store(0)
        ret
    }

    /**
     * 获取已分配但未提交的 SQE 数量
     */
    public func pendingCount(): UInt32 {
        allocated.load()
    }

    /**
     * 获取已准备好待提交的 SQE 数量
     */
    public func preparedCount(): UInt32 {
        prepared.load()
    }

    /**
     * 重置预分配器状态
     *
     * 非线程安全，仅在确定无并发访问时调用。
     * 调用后所有已分配但未提交的 SQE 将被丢弃。
     */
    public func reset(): Unit {
        allocated.store(0)
        prepared.store(0)
    }
}
