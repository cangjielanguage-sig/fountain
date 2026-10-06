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
package fountain::f_cache

import std.unittest.*
import std.unittest.testmacro.*

@Test
public class WeakHeapCache_test {
    @TestCase
    public func testSetGetRemoveSemantics(): Unit {
        let cache = WeakHeapCache<Test>()
        //首次 set：没有旧值
        @Assert(true, cache.set('k', Test(1)).isNone())
        //值仍被用例强引用 ⇒ 能读回（键已改强引用，条目不会因键被回收而消失）
        @Assert(1, cache.get('k')?.value ?? -1)
        @Assert(1, cache.getOrDefault('k', Test(-1)).value)
        //再次 set：返回旧值（覆盖语义）
        @Assert(1, cache.set('k', Test(2))?.value ?? -1)
        @Assert(2, cache.get('k')?.value ?? -1)
        @Assert(1, cache.size)
        //remove 返回被删除的值；再取为 None
        @Assert(2, cache.remove('k')?.value ?? -1)
        @Assert(true, cache.get('k').isNone())
        @Assert(0, cache.size)
    }

    @TestCase
    public func testGetOrComputeAndGetOrStore(): Unit {
        let cache = WeakHeapCache<Test>()
        //未命中 ⇒ 调 callable 并写入
        @Assert(7, cache.getOrCompute('g') {Some(Test(7))}?.value ?? -1)
        @Assert(7, cache.get('g')?.value ?? -1)
        //命中 ⇒ 直接返回已有值（若 callable 被调用会得到 8）
        @Assert(7, cache.getOrCompute('g') {Some(Test(8))}?.value ?? -1)
        //callable 返回 None ⇒ 不写入
        @Assert(true, cache.getOrCompute('n') {None<Test>}.isNone())
        @Assert(true, cache.get('n').isNone())
        //getOrStore：缺失则存默认值
        @Assert(9, cache.getOrStore('s', Test(9)).value)
        @Assert(9, cache.get('s')?.value ?? -1)
    }

    @TestCase
    public func testMissingGetDoesNotCreateAndRemoveIfAndClear(): Unit {
        let cache = WeakHeapCache<Test>()
        for (i in 0..5) {
            let _ = cache.set('k${i}', Test(i))
        }
        @Assert(5, cache.size)
        //get 未命中不建条目（纯读取），size 不受影响
        @Assert(true, cache.get('missing').isNone())
        @Assert(5, cache.size)
        //removeIf：谓词拿到的键是强引用、值是活着的那份
        cache.removeIf {_, v => v.value % 2 == 0}
        @Assert(2, cache.size)
        @Assert(1, cache.get('k1')?.value ?? -1)
        @Assert(3, cache.get('k3')?.value ?? -1)
        @Assert(true, cache.get('k0').isNone())
        //clear 清空
        cache.clear()
        @Assert(0, cache.size)
        @Assert(true, cache.get('k1').isNone())
    }

    @TestCase
    public func testOperationsAfterCloseThrow(): Unit {
        let cache = WeakHeapCache<Test>()
        let _ = cache.set('k', Test(1))
        cache.close()
        @Assert(true, cache.isClosed())
        try {
            let _ = cache.get('k')
            @Assert(false)
        } catch (e: IllegalStateException) {
            @Assert(true)
        }
        try {
            let _ = cache.set('k2', Test(2))
            @Assert(false)
        } catch (e: IllegalStateException) {
            @Assert(true)
        }
        //可重复调用
        cache.close()
        @Assert(true, cache.isClosed())
    }
}
