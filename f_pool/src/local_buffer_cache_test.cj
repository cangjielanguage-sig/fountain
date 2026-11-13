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

/** `LocalBufferCache`：同线程复用、跨线程归还、关闭本地缓存三种语义。 */
@Test
public class LocalBufferCache_test {
    @TestCase
    public func sameThreadBorrowHitsLocalCache(): Unit {
        let pool = ArrayPool<Byte>(initSize: 1, minSize: 1, maxSize: 1, arraySize: 64)
        let cache = LocalBufferCache(pool, 1, 64)
        let first = cache.borrow(timeout: Duration.second).getOrThrow()
        @Assert(first.size == 64)
        cache.giveBack(first)
        let second = cache.borrow(timeout: Duration.second).getOrThrow()
        @Assert(second.size == 64)
        @Assert(cache.localHits == 1)
    }

    @TestCase
    public func zeroLocalCacheNeverHits(): Unit {
        let pool = ArrayPool<Byte>(initSize: 1, minSize: 1, maxSize: 1, arraySize: 64)
        let cache = LocalBufferCache(pool, 0, 64)
        let first = cache.borrow(timeout: Duration.second).getOrThrow()
        cache.giveBack(first)
        cache.borrow(timeout: Duration.second).getOrThrow()
        @Assert(cache.localHits == 0)
    }

    @TestCase
    public func crossThreadReturnStillHitsOnBorrower(): Unit {
        let pool = ArrayPool<Byte>(initSize: 0, minSize: 0, maxSize: 1, arraySize: 64)
        let cache = LocalBufferCache(pool, 1, 64)
        let first = cache.borrow(timeout: Duration.second).getOrThrow()
        let f = spawn {
            cache.giveBack(first)
        }
        f.get()
        cache.borrow(timeout: Duration.second).getOrThrow()
        @Assert(cache.localHits == 1)
    }
}
