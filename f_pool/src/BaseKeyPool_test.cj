/*
Copyright (c) 2026 WuJingrun（吴京润）

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

import std.unittest.*
import std.unittest.testmacro.*
import std.sync.AtomicInt64
import std.collection.ArrayList
import fountain::f_base.BaseException
import fountain::f_pool.exception.UnknownKeyException

/** `BaseKeyPool` 的记账一致性（见 .autocode/bugs/bug-archived-on-20261004.md 7.2：size 与实际可借数不能脱钩）。 */
@Test
public class BaseKeyPoolTest {
    @TestCase
    public func destroyMustSyncSize(){
        let pool = BaseKeyPool<String, Object>(Mode.Fifo, 10)
        pool.add('k', Object())
        pool.add('k', Object())
        pool.add('other', Object())
        @Assert(pool.size, 3)
        @Assert(pool.keyedSize('k'), 2)
        // 注意：捕获可变局部变量的 lambda 只能直接调用（仓颉限制）⇒ 用 AtomicInt64 记数
        let destroyed = AtomicInt64(0)
        pool.destroy{_, _ => destroyed.fetchAdd(1)}
        @Assert(destroyed.load(), 3)
        // destroy 之后 size 必须归零：否则调用方会以为池已满，再也不新建池项，get 永久取不到东西
        @Assert(pool.size, 0)
        @Assert(pool.keyedSize('k'), 0)
    }
    /**
     * `POOL-10`（`.autocode/bugs/bug-pool.md` §2.5）：把值还给一个**从来没有过池的键**（= 还错了键）
     * 必须抛 `UnknownKeyException`，且**不做任何处置**：不归还、不销毁、也不替它建池。
     * 修前是 `map.get(key)?.` 静默跳过 —— 值被丢掉，来源键的那份额度永远回不来。
     */
    @TestCase
    public func giveBackToUnknownKeyMustThrow(){
        let pool = BaseKeyPool<String, Object>(Mode.Fifo, 10)
        pool.add('k1', Object())                       // 只有 k1 有池
        let destroyed = AtomicInt64(0)
        var thrown = None<UnknownKeyException>
        try {
            pool.giveBack('k2', Object(), {_, _ => true}, {_, _ => destroyed.fetchAdd(1)})
        } catch (e: UnknownKeyException) {
            thrown = Some(e)
        }
        @Assert(thrown.isSome())                       // 修前：不抛
        @Assert(destroyed.load(), 0)                   // 不替调用方销毁（所有权还在它手里）
        let keys = ArrayList<String>()
        for ((k, _) in pool.entries()) {
            keys.add(k)
        }
        @Assert(keys.size, 1)                          // 也不偷偷建池：否则巡检会按 `p.size < max` 给它补池项
        @Assert(keys[0], 'k1')
    }
    /**
     * `POOL-10` 的契约面：异常是 `f_base.BaseException` 子类、带出出错的那个键、可挂被顶掉的异常
     * （应用层在 `finally` / `release()` 里归还时用它保住原始异常，见 `UnknownKeyException` 的文档）。
     */
    @TestCase
    public func unknownKeyExceptionCarriesKeyAndSuppressed(){
        let pool = BaseKeyPool<String, Object>(Mode.Fifo, 10)
        pool.add('k1', Object())
        var caught = None<UnknownKeyException>
        try {
            pool.giveBack('k2', Object(), {_, _ => true}, {_, _ => ()})
        } catch (e: UnknownKeyException) {
            caught = Some(e)
        }
        @Assert(caught.isSome(), true)                 // 修前：不抛 ⇒ 这里是干净的失败（不是 getOrThrow 抛出来的 ERROR）
        let ex = caught.getOrThrow()
        // `key` 字段是 `Any`（键的类型只有 `Hashable & Equatable` 约束，没有 `ToString`）⇒ 应用层自己转文本
        match (ex.key) {
            case k: String => @Assert(k, 'k2')
            case _ => @Assert(false)
        }
        @Assert(ex is BaseException)                   // 应用层按 f_base 的异常根统一捕获
        ex.addSuppressed(Exception('displaced by giveBack in finally'))
        @Assert(ex.suppressed.size, 1)
    }
}
