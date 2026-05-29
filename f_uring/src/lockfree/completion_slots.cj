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
import std.sync.AtomicUInt64
import std.sync.AtomicReference

/**
 * 无锁完成槽位数组
 *
 * 预分配固定大小的槽位数组，每个槽位包含 generation 计数器和回调引用。
 * 通过 generation 计数器防止 ABA 问题：分配时 generation 递增，
 * CQE 返回时比较 generation 确认槽位仍然有效。
 *
 * 与 AtomicSlotAllocator 配合使用：
 * - AtomicSlotAllocator 管理槽位的分配/释放
 * - CompletionSlotArray 管理槽位中的回调数据
 * - userData 编码为：(slotIndex) + (generation << SLOT_BITS)
 *
 * 使用示例：
 * ```cj
 * let allocator = AtomicSlotAllocator(64)
 * let slots = CompletionSlotArray(64)
 * if (let Some(slotId) <- allocator.alloc()) {
 *     let gen = slots.setCallback(slotId, myCallback)
 *     let userData = slots.encodeUserData(slotId, gen)
 *     ioUringSQESetData64(sqe, userData)
 *     // ... submit and reap ...
 *     // CQE returns, decode userData:
 *     let (idx, gen2) = slots.decodeUserData(userData)
 *     slots.invokeAndRelease(idx, gen2, cqe)
 *     allocator.release(idx)
 * }
 * ```
 */
@When[os == "Linux"]
public class CompletionSlotArray {
    /** 槽位数量 */
    private let slotCount: UInt32
    /** slotIndex 占用的 bit 数（向上取整 log2） */
    private let slotBits: UInt32
    /** generation 左移位数 */
    private let genShift: UInt32
    /** slotIndex 掩码 */
    private let slotMask: UInt64

    /**
     * 每个槽位的状态
     *
     * generation 高 32 位 | callback 引用
     * 使用 AtomicReference 保证回调设置的原子性。
     */
    private let generations: Array<AtomicUInt64>
    private let callbacks: Array<AtomicReference<CompletionCallback>>

    /**
     * 初始化槽位数组
     * @param slotCount 槽位数量（必须是 2 的幂，上限 2^24）
     * @throws IoUringException slotCount 不为 2 的幂或超过上限时抛出
     */
    public init(slotCount: UInt32) {
        if (slotCount == 0 || (slotCount & (slotCount - 1)) != 0) {
            throw IoUringException("CompletionSlotArray slotCount must be power of 2, got ${slotCount}")
        }
        if (slotCount > 0x01000000) {
            throw IoUringException("CompletionSlotArray slotCount ${slotCount} exceeds max 16777216")
        }
        this.slotCount = slotCount
        // 内联 ceilLog2：slotCount 是 2 的幂，log2 即为 bit 位置
        var bits: UInt32 = 0
        var v = slotCount
        while (v > 1) {
            bits += 1
            v >>= 1
        }
        this.slotBits = bits
        this.genShift = bits
        this.slotMask = (UInt64(1) << UInt64(bits)) - 1

        this.generations = Array<AtomicUInt64>(Int64(slotCount)) { _ =>
            AtomicUInt64(0)
        }
        this.callbacks = Array<AtomicReference<CompletionCallback>>(Int64(slotCount)) { _ =>
            AtomicReference<CompletionCallback>(CompletionCallback.None)
        }
    }

    /**
     * 设置槽位回调并递增 generation
     *
     * @param slotIndex 槽位索引（由 AtomicSlotAllocator 分配）
     * @param callback 完成回调
     * @return 当前 generation 值（用于编码 userData）
     */
    public func setCallback(slotIndex: UInt32, callback: CompletionCallback): UInt32 {
        checkIndex(slotIndex)
        // 先设置回调
        callbacks[Int64(slotIndex)].store(callback)
        // 再递增 generation（低 32 位存 generation）
        // fetchAdd 返回旧值，+1 得到递增后的值，即当前 generation
        let genWord = generations[Int64(slotIndex)].fetchAdd(1)
        UInt32((genWord + 1) & 0xFFFFFFFF)
    }

    /**
     * 获取槽位当前回调
     * @param slotIndex 槽位索引
     * @return 回调引用
     */
    public func getCallback(slotIndex: UInt32): CompletionCallback {
        checkIndex(slotIndex)
        callbacks[Int64(slotIndex)].load()
    }

    /**
     * 获取槽位当前 generation
     * @param slotIndex 槽位索引
     * @return generation 值
     */
    public func getGeneration(slotIndex: UInt32): UInt32 {
        checkIndex(slotIndex)
        UInt32(generations[Int64(slotIndex)].load() & 0xFFFFFFFF)
    }

    /**
     * 编码 userData：将 slotIndex 和 generation 打包为 UInt64
     *
     * 格式：[generation : slotIndex]
     *       高位         低位
     *
     * @param slotIndex 槽位索引
     * @param generation generation 值
     * @return 打包的 UInt64
     */
    public func encodeUserData(slotIndex: UInt32, generation: UInt32): UInt64 {
        (UInt64(generation) << UInt64(genShift)) | UInt64(slotIndex)
    }

    /**
     * 解码 userData：从 UInt64 拆出 slotIndex 和 generation
     * @param userData 打包的 UInt64
     * @return (slotIndex, generation) 元组
     */
    public func decodeUserData(userData: UInt64): (UInt32, UInt32) {
        let slotIndex = UInt32(userData & slotMask)
        let generation = UInt32(userData >> UInt64(genShift))
        (slotIndex, generation)
    }

    /**
     * 调用回调并释放槽位
     *
     * 先校验 generation 是否匹配，防止 ABA 问题。
     * 匹配则调用回调并清除回调引用。
     *
     * @param slotIndex 槽位索引
     * @param generation 预期的 generation
     * @param cqe 完成队列条目
     * @return true 表示成功调用，false 表示 generation 不匹配（槽位已被复用）
     */
    public func invokeAndRelease(slotIndex: UInt32, generation: UInt32, cqe: CPointer<IOUringCQE>): Bool {
        checkIndex(slotIndex)
        let currentGen = UInt32(generations[Int64(slotIndex)].load() & 0xFFFFFFFF)
        // generation 匹配检查：当前 generation 应该是 setCallback 时递增后的值
        // 如果 generation 不匹配，说明槽位已被释放并重新分配
        if (currentGen != generation) {
            return false
        }
        let callback = callbacks[Int64(slotIndex)].load()
        // 清除回调引用
        callbacks[Int64(slotIndex)].store(CompletionCallback.None)
        // 调用回调
        callback.onComplete(cqe)
        true
    }

    /**
     * 获取槽位数量
     */
    public func getSlotCount(): UInt32 {
        slotCount
    }

    /**
     * 获取 slotBits
     */
    public func getSlotBits(): UInt32 {
        slotBits
    }

    // ==================== 私有辅助 ====================

    private func checkIndex(index: UInt32): Unit {
        if (index >= slotCount) {
            throw IoUringException("CompletionSlotArray: index ${index} out of range [0, ${slotCount})")
        }
    }
}

/**
 * 完成回调接口
 *
 * 无锁路径中替代 CompletionSlot 接口。
 * 不使用泛型以避免类型擦除和堆分配开销。
 * 调用者通过闭包捕获结果处理逻辑。
 */
@When[os == "Linux"]
public open class CompletionCallback {
    /**
     * CQE 完成时调用
     * @param cqe 完成队列条目指针
     */
    public open func onComplete(cqe: CPointer<IOUringCQE>): Unit {
        // 默认空实现，子类覆盖。引用 cqe 避免编译器警告。
        if (cqe.isNull()) {
            return
        }
    }

    /**
     * 空回调（哨兵值）
     */
    public static let None: CompletionCallback = CompletionCallback()
}

/**
 * 基于 Lambda 的完成回调
 *
 * 将闭包包装为 CompletionCallback，
 * 避免为每种操作类型创建子类。
 */
@When[os == "Linux"]
public class LambdaCompletionCallback <: CompletionCallback {
    private let action: (CPointer<IOUringCQE>) -> Unit

    public init(action: (CPointer<IOUringCQE>) -> Unit) {
        this.action = action
    }

    public func onComplete(cqe: CPointer<IOUringCQE>): Unit {
        action(cqe)
    }
}
