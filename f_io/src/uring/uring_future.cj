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
package fountain::f_io.uring

import std.sync.*
import std.collection.concurrent.ConcurrentHashMap

/**
 * 异步操作完成槽接口
 *
 * 用于类型擦除：IoUringPromise<T> 实现此接口，
 * 使得 CompletionRegistry 可以存储不同泛型参数的 Promise。
 */
@When[os == "Linux"]
public interface CompletionSlot {
    /**
     * 用 CQE 完成此槽位
     * @param cqe 完成队列条目指针
     */
    func complete(cqe: CPointer<IOUringCQE>): Unit

    /**
     * 取消此槽位
     */
    func cancel(): Unit
}

/**
 * 完成槽位注册表
 *
 * 管理 slotId → CompletionSlot 的映射。
 * slotId 作为 SQE 的 userData 提交到内核，
 * CQE 返回时通过 userData 查找对应的槽位。
 *
 * Phase 3 使用 ConcurrentHashMap 实现；
 * Phase 4 将替换为无锁槽位数组。
 */
@When[os == "Linux"]
public class CompletionRegistry {
    private let slots: ConcurrentHashMap<UInt64, CompletionSlot> = ConcurrentHashMap<UInt64, CompletionSlot>()
    // 从 1 开始，0 保留给"无 userData"（waitAndProcess 跳过 userData==0 的 CQE）
    private let nextSlotId: AtomicUInt64 = AtomicUInt64(1)

    public init() {}

    /**
     * 分配一个新的槽位 ID
     * @return 唯一的 UInt64 ID
     */
    public func nextId(): UInt64 {
        nextSlotId.fetchAdd(1)
    }

    /**
     * 注册槽位
     * @param id 槽位 ID
     * @param slot 完成槽位
     */
    public func register(id: UInt64, slot: CompletionSlot): Unit {
        slots.add(id, slot)
    }

    /**
     * 完成指定槽位并从注册表中移除
     * @param id 槽位 ID
     * @param cqe 完成队列条目
     */
    public func completeSlot(id: UInt64, cqe: CPointer<IOUringCQE>): Unit {
        if (let Some(slot) <- slots.remove(id)) {
            slot.complete(cqe)
        }
    }

    /**
     * 取消指定槽位并从注册表中移除
     * @param id 槽位 ID
     */
    public func cancelSlot(id: UInt64): Unit {
        if (let Some(slot) <- slots.remove(id)) {
            slot.cancel()
        }
    }

    /**
     * 获取当前注册的槽位数量
     */
    public func size(): Int64 {
        slots.size
    }
}

/**
 * io_uring 异步操作的 Promise
 *
 * 持有 Mutex + Condition 实现阻塞等待语义。
 * 由 CQE 收割线程调用 complete() 设置结果，
 * 由用户线程调用 awaitResult() 阻塞等待。
 *
 * @param T 结果类型
 */
@When[os == "Linux"]
public class IoUringPromise<T> <: CompletionSlot {
    private let slotId: UInt64
    private let resultExtractor: (CPointer<IOUringCQE>) -> T
    private var value: ?T = None
    private var completed: Bool = false
    private var cancelled: Bool = false
    private var error: ?IoUringException = None
    private let mutex: Mutex = Mutex()
    private let cond: Condition

    public init(slotId: UInt64, resultExtractor: (CPointer<IOUringCQE>) -> T) {
        this.slotId = slotId
        this.resultExtractor = resultExtractor
        // Condition 必须在持有锁时创建
        synchronized(mutex) {
            this.cond = mutex.condition()
        }
    }

    /**
     * 获取槽位 ID
     */
    public func getSlotId(): UInt64 {
        slotId
    }

    /**
     * 用 CQE 完成此 Promise
     *
     * 由 CQE 收割线程调用。使用 resultExtractor 从 CQE 提取结果值。
     */
    public func complete(cqe: CPointer<IOUringCQE>): Unit {
        mutex.lock()
        if (completed || cancelled) {
            mutex.unlock()
            return
        }
        try {
            let result = resultExtractor(cqe)
            this.value = Some(result)
            this.completed = true
            cond.notifyAll()
        } catch (e: Exception) {
            this.error = Some(IoUringException("Result extraction failed", e))
            this.completed = true
            cond.notifyAll()
        }
        mutex.unlock()
    }

    /**
     * 用错误完成此 Promise
     *
     * 当 CQE 的 res 为负值时调用。
     */
    public func completeWithError(err: IoUringException): Unit {
        mutex.lock()
        if (completed || cancelled) {
            mutex.unlock()
            return
        }
        this.error = Some(err)
        this.completed = true
        cond.notifyAll()
        mutex.unlock()
    }

    /**
     * 取消此 Promise
     */
    public func cancel(): Unit {
        mutex.lock()
        if (completed) {
            mutex.unlock()
            return
        }
        this.cancelled = true
        cond.notifyAll()
        mutex.unlock()
    }

    /**
     * 阻塞等待结果
     * @return 结果值
     * @throws IoUringException 如果操作被取消或失败
     */
    public func awaitResult(): T {
        mutex.lock()
        cond.waitUntil({ => completed || cancelled })
        mutex.unlock()

        if (cancelled) {
            throw IoUringException("Operation cancelled (slotId=${slotId})")
        }
        if (let Some(err) <- error) {
            throw err
        }
        value.getOrThrow()
    }

    /**
     * 带超时阻塞等待结果
     * @param timeout 超时时间
     * @return 结果值，超时返回 None
     * @throws IoUringException 如果操作被取消或失败
     */
    public func awaitResult(timeout!: Duration): ?T {
        mutex.lock()
        let timedOut = !cond.waitUntil({ => completed || cancelled }, timeout: timeout)
        mutex.unlock()

        if (timedOut) {
            return None
        }
        if (cancelled) {
            throw IoUringException("Operation cancelled (slotId=${slotId})")
        }
        if (let Some(err) <- error) {
            throw err
        }
        value
    }

    /**
     * 非阻塞获取结果
     * @return 如果已完成返回结果，否则返回 None
     */
    public func tryGetResult(): ?T {
        mutex.lock()
        let result = if (completed) { value } else { None<T> }
        mutex.unlock()
        result
    }

    /**
     * 是否已完成
     */
    public func isCompleted(): Bool {
        mutex.lock()
        let result = completed
        mutex.unlock()
        result
    }

    /**
     * 是否已取消
     */
    public func isCancelled(): Bool {
        mutex.lock()
        let result = cancelled
        mutex.unlock()
        result
    }
}

/**
 * io_uring 异步操作的 Future
 *
 * 包装 IoUringPromise，提供与 std.core.Future 类似的 API。
 * 由于 std.core.Future<T> 是 final 类无法继承，
 * 这里提供独立的 Future 实现。
 *
 * @param T 结果类型
 */
@When[os == "Linux"]
public class IoUringFuture<T> {
    private let promise: IoUringPromise<T>

    init(promise: IoUringPromise<T>) {
        this.promise = promise
    }

    /**
     * 阻塞等待结果
     * @return 结果值
     * @throws IoUringException 如果操作被取消或失败
     */
    public func get(): T {
        promise.awaitResult()
    }

    /**
     * 带超时阻塞等待结果
     * @param timeout 超时时间
     * @return 结果值，超时返回 None
     */
    public func get(timeout!: Duration): ?T {
        promise.awaitResult(timeout: timeout)
    }

    /**
     * 非阻塞获取结果
     * @return 如果已完成返回结果，否则返回 None
     */
    public func tryGet(): ?T {
        promise.tryGetResult()
    }

    /**
     * 是否已完成
     */
    public func isCompleted(): Bool {
        promise.isCompleted()
    }

    /**
     * 是否已取消
     */
    public func isCancelled(): Bool {
        promise.isCancelled()
    }

    /**
     * 获取槽位 ID
     */
    public func slotId(): UInt64 {
        promise.getSlotId()
    }
}
