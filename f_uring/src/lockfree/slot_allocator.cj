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
import std.math.trailingZeros
import std.sync.AtomicUInt32

/**
 * 无锁原子槽位分配器
 *
 * 使用位图 + CAS 实现的固定容量槽位分配器。
 * 每个槽位用一个 bit 表示：0 = 空闲，1 = 已分配。
 * 通过 CAS 循环保证并发安全。
 *
 * 适用场景：为 io_uring 的 userData 分配唯一整数索引，
 * 配合 CompletionSlotArray 实现无锁完成回调。
 *
 * 使用示例：
 * ```cj
 * let allocator = AtomicSlotAllocator(64)
 * if (let Some(slotId) <- allocator.alloc()) {
 *     // 使用 slotId 作为 SQE userData
 *     // ...
 *     allocator.release(slotId) // 操作完成后释放
 * }
 * ```
 */
@When[os == "Linux"]
public class AtomicSlotAllocator {
    /** 槽位总容量 */
    private let capacity: UInt32
    /** 位图原子字数组，每个 UInt32 管理 32 个槽位 */
    private let bitmap: Array<AtomicUInt32>
    /** bitmap 数组长度 */
    private let wordCount: UInt32
    /** 已分配槽位数量缓存（O(1) 查询替代 O(n) 遍历） */
    private let allocatedCount: AtomicUInt32 = AtomicUInt32(0)

    /**
     * 初始化分配器
     * @param capacity 槽位数量（上限 32 * 1024 = 32768）
     * @throws IoUringException 容量超过上限时抛出
     */
    public init(capacity: UInt32) {
        if (capacity > 32768) {
            throw IoUringException("AtomicSlotAllocator capacity ${capacity} exceeds max 32768")
        }
        this.capacity = capacity
        // 向上对齐到 32 的倍数
        this.wordCount = (capacity + 31) / 32
        this.bitmap = Array<AtomicUInt32>(Int64(wordCount)) { _ =>
            AtomicUInt32(0)
        }
    }

    /**
     * 分配一个空闲槽位
     *
     * 遍历位图，找到第一个空闲 bit，通过 CAS 原子地将其标记为已分配。
     *
     * @return 槽位索引，所有槽位已满时返回 None
     */
    public func alloc(): ?UInt32 {
        var wordIdx: UInt32 = 0
        while (wordIdx < wordCount) {
            let atomicWord = bitmap[Int64(wordIdx)]
            var word = atomicWord.load()
            // 该 word 还有空闲位（未满 0xFFFFFFFF）
            while (word != 0xFFFFFFFF) {
                // 找到最低位的空闲 bit（标准库硬件指令加速）
                let invert = word ^ 0xFFFFFFFF
                let bitIdx = UInt32(trailingZeros(invert))  // std.math.countTrailingZeros
                let mask = UInt32(1) << bitIdx
                let newWord = word | mask
                if (atomicWord.compareAndSwap(word, newWord)) {
                    let slotId = wordIdx * 32 + bitIdx
                    // 超出容量的槽位不算
                    if (slotId < capacity) {
                        allocatedCount.fetchAdd(1)
                        return Some(slotId)
                    } else {
                        // CAS 成功但超出容量，回滚
                        atomicWord.fetchAnd(0xFFFFFFFF ^ mask)
                        return None
                    }
                }
                // CAS 失败，重载 word 重试
                word = atomicWord.load()
            }
            wordIdx += 1
        }
        None
    }

    /**
     * 释放一个已分配的槽位
     * @param slotId 槽位索引
     * @throws IoUringException slotId 越界时抛出
     */
    public func release(slotId: UInt32): Unit {
        if (slotId >= capacity) {
            throw IoUringException("AtomicSlotAllocator release: slotId ${slotId} out of range [0, ${capacity})")
        }
        let wordIdx = slotId / 32
        let bitIdx = slotId % 32
        let mask = UInt32(1) << bitIdx
        let invertMask = 0xFFFFFFFF ^ mask
        // 原子地清除该 bit
        bitmap[Int64(wordIdx)].fetchAnd(invertMask)
        allocatedCount.fetchSub(1)
    }

    /**
     * 获取当前已分配的槽位数（O(1) 查询）
     */
    public func getAllocatedCount(): UInt32 {
        allocatedCount.load()
    }

    /**
     * 检查槽位是否已分配
     * @param slotId 槽位索引
     * @return true 表示已分配
     */
    public func isAllocated(slotId: UInt32): Bool {
        if (slotId >= capacity) {
            return false
        }
        let wordIdx = slotId / 32
        let bitIdx = slotId % 32
        let mask = UInt32(1) << bitIdx
        (bitmap[Int64(wordIdx)].load() & mask) != 0
    }

    /**
     * 获取容量
     */
    public func getCapacity(): UInt32 {
        capacity
    }

    /**
     * 重置分配器（释放所有槽位）
     *
     * 非线程安全，仅在确定无并发访问时调用。
     */
    public func reset(): Unit {
        for (i in 0..Int64(wordCount)) {
            bitmap[i].store(0)
        }
        allocatedCount.store(0)
    }

    // ==================== 私有辅助 ====================
}
