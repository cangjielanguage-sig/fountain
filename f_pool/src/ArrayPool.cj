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
package fountain::f_pool

import fountain::f_base.*
import fountain::f_exception.IllegalSizeException
import fountain::f_pool.diagnostics.PoolDiagnostics

public struct ArrayPool<T> {
    private let pool: Pool<Array<T>>
    public ArrayPool(
        initSize!: Int64 = 0, 
        minSize!: Int64 = 0, 
        maxSize!: Int64 = Int64.Max,
        elementLife!: Duration = Duration.Max, 
        checkInterval!: Duration = Duration.Zero,
        clearOnReturning!: Bool = false,
        /** 池耗尽且 `get(timeout: Duration.Max)` 时的等待上限；`Duration.Max` = 真无限等待。 */
        maxWaiting!: Duration = Duration.second * 30,
        private let arraySize!: Int64 = 128, 
        private let creator!: () -> T = {=> unsafeZeroValue<T>()}) {
        let initValue = creator()
        pool = Pool<Array<T>>(
            initSize: initSize,
            minSize: minSize,
            maxSize: maxSize,
            idleTimeout: elementLife,
            checkOnCreation: false,
            checkOnBorrowing: false,
            checkOnReturning: false,
            checkInterval: checkInterval,
            clearOnReturning: clearOnReturning,
            maxWaiting: maxWaiting,
            creator: {
                => Array<T>(arraySize) {_ => initValue}
            },
            checker: {_ => true},
            destroier: {_ =>},
            clear: {
                o => for (i in 0..o.size) {
                    o[i] = initValue
                }
            }
        )
    }
    public func get(timeout!: Duration = Duration.Max): ?Array<T> {
        pool.get(timeout: timeout)
    }
    /**
     * 归还数组：尺寸必须等于建池时的 `arraySize`，否则抛 `IllegalSizeException`
     * （`fountain::f_exception`，`f_base.BaseException` 的子类；消息里带期望/实际尺寸）。
     *
     * **抛出即表示这次没有归还**：数组仍在调用方手里（池无权销毁它），借出它的那个池的那份额度也不会结清
     * —— 与 `KeyPool.giveBack` 的口径一致（见 .autocode/bugs/bug-pool.md §2.5 `POOL-10`、
     * §2.7 `POOL-12`）。归还路径通常写在 `finally` / `release()` 里，若顶掉了正在传播的异常，用
     * `addSuppressed` 挂上再抛出。
     *
     * 尺寸不符是**应用层的 BUG**（把外来数组、或另一套 `arraySize` 的池的数组还了回来）；
     * 原来它只是 `return false` —— 调用方漏判返回值就等于无声无息地漏掉一份池容量（见 §3 `POOL-L7`）。
     */
    public func giveBack(array: Array<T>): Unit {
        if (array.size != arraySize) {
            // 异常必留痕：即使应用层把异常吞了，下一次 `reportIfChanged`/退出报告也会带出这个计数
            PoolDiagnostics.onReturnRejected()
            throw IllegalSizeException('ArrayPool.giveBack: expected an array of ${arraySize}, got ${array.size} — the array was NOT returned (it is still yours)')
        }
        pool.giveBack(array)
    }
}
