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

import std.sync.*
import fountain::f_uring.base.*

/**
 * 轻量级完成 Promise
 *
 * 针对 IOUringStream read 路径优化的 Promise 实现：
 * - completed 用 AtomicBool（无锁读取，短延迟场景直接返回）
 * - value 用 AtomicInt32（无锁写入，AtomicReference 只支持 class 泛型实参）
 * - 先自旋检查 completed（CQE 可能在 awaitResult 之前就完成）
 * - 自旋失败后才进入 Condition wait（减少线程唤醒开销）
 *
 * 与 IoUringPromise 的区别：
 * - IoUringPromise: 每次访问 completed/value 都需 lock/unlock mutex
 * - LockFreePromise: completed/value 用原子变量，仅在 wait 时使用 mutex+condition
 *
 * 不支持泛型，仅存储 Int32 结果（io_uring CQE 的 res 字段），
 * 避免泛型带来的类型擦除和堆分配开销。
 */
@When[os == "Linux"]
public class LockFreePromise <: CompletionCallback {
    /** 完成标志（原子变量，无锁读取） */
    private let completed: AtomicBool = AtomicBool(false)
    /** 结果值（原子变量，无锁写入） */
    private let value: AtomicInt32 = AtomicInt32(0)
    /** 等待用 mutex */
    private let mutex: Mutex = Mutex()
    /** 等待用 condition（在持有锁时创建） */
    private let cond: Condition

    public init() {
        synchronized(mutex) {
            this.cond = mutex.condition()
        }
    }

    /**
     * CQE 完成时调用（实现 CompletionCallback 接口）
     *
     * 从 CQE 提取 res 值，原子设置完成标志，唤醒等待线程。
     */
    public override func onComplete(cqe: CPointer<IOUringCQE>): Unit {
        let result = ioUringCQEGetRes(cqe)
        value.store(result)
        // 设置 completed 标志（必须在 value 之后，保证等待者看到值）
        completed.store(true)
        // 唤醒等待线程
        synchronized(mutex) {
            cond.notify()
        }
    }

    /**
     * 是否已完成（无锁读取）
     */
    public func isCompleted(): Bool {
        completed.load()
    }

    /**
     * 阻塞等待结果
     *
     * 先自旋检查 completed（短延迟场景直接返回，无需线程唤醒），
     * 自旋失败后进入 Condition wait。
     *
     * @return CQE 结果值（负值表示错误）
     */
    public func awaitResult(): Int32 {
        // 快速路径：自旋检查（CQE 可能在 awaitResult 调用前就完成）
        if (completed.load()) {
            return value.load()
        }
        // 短暂自旋（几轮即可覆盖 us 级延迟）
        var spins = 0
        while (spins < 100) {
            if (completed.load()) {
                return value.load()
            }
            spins += 1
        }
        // 自旋失败，进入 Condition wait
        synchronized(mutex) {
            while (!completed.load()) {
                cond.waitUntil({ => completed.load() })
            }
        }
        value.load()
    }
}
