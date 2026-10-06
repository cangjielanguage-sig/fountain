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
import std.sync.{AtomicBool, AtomicInt64}
import std.collection.ArrayList
import fountain::f_base.BaseException
import fountain::f_pool.exception.UnknownKeyException

/** `BaseKeyPool` 的记账一致性（见 .autocode/bugs/bug-archived-on-20261004.md 7.2：size 与实际可借数不能脱钩）。 */
@Test
public class BaseKeyPoolTest {
    /** 键表里的键（快照成数组，便于断言）。 */
    private func keys(pool: BaseKeyPool<String, Object>): ArrayList<String> {
        let out = ArrayList<String>()
        for ((k, _) in pool.entries()) {
            out.add(k)
        }
        out
    }
    @TestCase
    public func closeMustSyncSize(){
        let running = AtomicBool(true)
        let pool = BaseKeyPool<String, Object>(Mode.Fifo, 10, running)
        pool.add('k', Object())
        pool.add('k', Object())
        pool.add('other', Object())
        @Assert(pool.size, 3)
        @Assert(pool.keyedSize('k'), 2)
        // 注意：捕获可变局部变量的 lambda 只能直接调用（仓颉限制）⇒ 用 AtomicInt64 记数
        let destroyed = AtomicInt64(0)
        // `destroy` 已删除（见 .autocode/bugs/bug-pool.md §2.6 POOL-11）：本层唯一的销毁入口是 close
        running.store(false)
        pool.close{_, _ => destroyed.fetchAdd(1)}
        @Assert(destroyed.load(), 3)
        // close 之后 size 必须归零：否则调用方会以为池已满，再也不新建池项，get 永久取不到东西
        @Assert(pool.size, 0)
        @Assert(pool.keyCount(), 0)
    }
    /**
     * `POOL-11`（§2.6）：`remove(key)` 必须**先关闭 + 销毁**那个键的池，再把它从键表里摘掉；
     * 键不存在时是空操作。修前没有 remove 入口 —— 键表只增不减，空池条目与巡检每轮 O(#keys) 的遍历是永久成本。
     */
    @TestCase
    public func removeMustDestroyAndForgetKey(){
        let running = AtomicBool(true)
        let pool = BaseKeyPool<String, Object>(Mode.Fifo, 10, running)
        pool.add('k1', Object())
        pool.add('k1', Object())
        pool.add('k2', Object())
        @Assert(pool.size, 3)
        @Assert(pool.keyCount(), 2)
        let destroyed = AtomicInt64(0)
        pool.remove('k1'){_, _ => destroyed.fetchAdd(1)}
        @Assert(destroyed.load(), 2)                       // k1 的池项被销毁
        @Assert(pool.size, 1)                              // 账本只剩 k2 的那一项
        @Assert(pool.keyCount(), 1)                        // k1 从键表里消失了
        let after = keys(pool)
        @Assert(after.size, 1)
        @Assert(after[0], 'k2')
        pool.remove('k1'){_, _ => destroyed.fetchAdd(1)}    // 幂等：键不存在 ⇒ 空操作
        @Assert(destroyed.load(), 2)
        @Assert(pool.keyCount(), 1)
        // 摘掉之后再 get 会**按需重建**这个键的池（应用又用起来了）：不是泄漏，是正常语义
        @Assert(pool.get('k1', {_, _ => true}, {_, _ => ()}).isNone())
        @Assert(pool.keyCount(), 2)
        @Assert(pool.keyedSize('k1'), 0)
    }
    /**
     * `POOL-11`（§2.6）第二面：`close()` 必须在返回前销毁**所有**键的池并清空键表
     * —— 修前 `KeyPool.close` 只清各池的项、**不删 map 条目**，键表与空池条目永久留着；
     * 而且关停之后仍然会「按需建池」，一个交错的 `get`/`keyedSize` 就能把键表重新长回来。
     */
    @TestCase
    public func closeMustClearKeyTableAndDestroyAll(){
        let running = AtomicBool(true)
        let pool = BaseKeyPool<String, Object>(Mode.Fifo, 10, running)
        pool.add('k1', Object())
        pool.add('k2', Object())
        pool.add('k2', Object())
        @Assert(pool.keyCount(), 2)
        let destroyed = AtomicInt64(0)
        running.store(false)                               // `KeyPool.close()` 是先置 running=false 再清
        pool.close{_, _ => destroyed.fetchAdd(1)}
        @Assert(destroyed.load(), 3)
        @Assert(pool.keyCount(), 0)                        // 键表清空
        @Assert(pool.size, 0)                              // 账本清零
        @Assert(keys(pool).size, 0)
        // 关停之后不再按需建池：get / keyedSize 都不许把键表长回来
        @Assert(pool.get('k1', {_, _ => true}, {_, _ => ()}).isNone())
        @Assert(pool.keyedSize('k1'), 0)
        @Assert(pool.keyCount(), 0)
    }
    /**
     * `POOL-10`（§2.5）：把值还给一个**从来没有过池的键**（= 还错了键）必须抛 `UnknownKeyException`，
     * 且**不做任何处置**：不归还、不销毁、也不替它建池。
     */
    @TestCase
    public func giveBackToUnknownKeyMustThrow(){
        let running = AtomicBool(true)
        let pool = BaseKeyPool<String, Object>(Mode.Fifo, 10, running)
        pool.add('k1', Object())                       // 只有 k1 有池
        let destroyed = AtomicInt64(0)
        var thrown = None<UnknownKeyException>
        try {
            pool.giveBack('k2', Object(), {_, _ => true}, {_, _ => destroyed.fetchAdd(1)})
        } catch (e: UnknownKeyException) {
            thrown = Some(e)
        }
        @Assert(thrown.isSome(), true)                 // 修前：不抛
        @Assert(destroyed.load(), 0)                   // 不替调用方销毁（所有权还在它手里）
        @Assert(pool.keyCount(), 1)                    // 也不偷偷建池：否则巡检会按 `p.size < max` 给它补池项
        let ks = keys(pool)
        @Assert(ks.size, 1)
        @Assert(ks[0], 'k1')
    }
    /**
     * `POOL-10` 的契约面：异常是 `f_base.BaseException` 子类、带出出错的那个键、可挂被顶掉的异常
     */
    @TestCase
    public func unknownKeyExceptionCarriesKeyAndSuppressed(){
        let running = AtomicBool(true)
        let pool = BaseKeyPool<String, Object>(Mode.Fifo, 10, running)
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
    /**
     * `POOL-11`（§2.6）第三面：**关停窗口里的归还**不许把项塞进死池，也不许抛错 ——
     * `running=false`（`close()` 已清空键表）之后 `giveBack` 直接销毁（口径同 `KeyPool.giveBack` 的 `!running` 分支）。
     */
    @TestCase
    public func giveBackAfterCloseMustDestroy(){
        let running = AtomicBool(true)
        let pool = BaseKeyPool<String, Object>(Mode.Fifo, 10, running)
        pool.add('k1', Object())
        let destroyed = AtomicInt64(0)
        running.store(false)
        pool.close{_, _ => destroyed.fetchAdd(1)}
        @Assert(destroyed.load(), 1)
        let after = AtomicInt64(0)
        pool.giveBack('k1', Object(), {_, _ => true}, {_, _ => after.fetchAdd(1)})
        @Assert(after.load(), 1)                       // 关停后归还 ⇒ 直接销毁（不是 UnknownKeyException）
        @Assert(pool.keyCount(), 0)                    // 也不重建池
    }
}
