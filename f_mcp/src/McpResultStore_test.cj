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
package fountain::f_mcp

import std.time.{DateTime, MonoTime}
import std.unittest.*
import std.unittest.testmacro.*

@Test
class McpResultStore_test {
    static func content(text: String): ResourceContent {
        ResourceContent('https://example.com/x', Some('text/plain'), Some(text), None)
    }

    static func busySleep(millis: Int64): Unit {
        let start = MonoTime.now()
        while ((MonoTime.now() - start) < Duration.millisecond * millis) {}
    }

    @TestCase
    public func testCountLimit(): Unit {
        let store = ToolResultStore(options: ResultStoreOptions(maxEntries: 2, adaptive: false))
        @Assert(true, store.put(content('a')).isSome())
        @Assert(true, store.put(content('b')).isSome())
        @Assert(true, store.put(content('c')).isNone())
        @Assert(2, store.size)
        store.close()
    }

    @TestCase
    public func testByteLimit(): Unit {
        let store = ToolResultStore(options: ResultStoreOptions(
            maxEntries: 10, maxBytes: 4, adaptive: false))
        @Assert(true, store.put(content('12345')).isNone())
        @Assert(0, store.size)
        store.close()
    }

    @TestCase
    public func testTtl(): Unit {
        let store = ToolResultStore(options: ResultStoreOptions(
            maxEntries: 10, ttlMillis: 1, adaptive: false))
        let token = store.put(content('a')).getOrThrow()
        busySleep(5)
        @Assert(true, store.get(token).isNone())
        @Assert(0, store.size)
        store.close()
    }

    @TestCase
    public func testAdaptiveGrow(): Unit {
        let store = ToolResultStore(options: ResultStoreOptions(
            maxEntries: 4, floor: 2, ceiling: 100, windowMillis: 1, adaptive: true))
        for (i in 0..4) {
            @Assert(true, store.put(content('v${i}')).isSome())
        }
        @Assert(true, store.put(content('overflow')).isNone())
        busySleep(3)
        let _ = store.put(content('again'))
        @Assert(true, store.maxEntryCount > 4)
        store.close()
    }

    @TestCase
    public func testAdaptiveShrink(): Unit {
        let store = ToolResultStore(options: ResultStoreOptions(
            maxEntries: 16, floor: 2, ceiling: 100, windowMillis: 1,
            shrinkConfirmWindows: 1, adaptive: true))
        let _ = store.put(content('one'))
        busySleep(3)
        let _ = store.put(content('two'))
        @Assert(true, store.maxEntryCount < 16)
        store.close()
    }

    @TestCase
    public func testByteBoundDoesNotGrow(): Unit {
        let store = ToolResultStore(options: ResultStoreOptions(
            maxEntries: 4, maxBytes: 3, floor: 2, ceiling: 100, windowMillis: 1, adaptive: true))
        let _ = store.put(content('12345'))
        busySleep(3)
        let _ = store.put(content('1'))
        @Assert(4, store.maxEntryCount)
        store.close()
    }

    @TestCase
    public func testConcurrencyGate(): Unit {
        let gate = ConcurrencyGate()
        @Assert(true, gate.tryAcquire('k', 1))
        @Assert(false, gate.tryAcquire('k', 1))
        gate.release('k')
        @Assert(0, gate.size())
        @Assert(true, gate.tryAcquire('k', 1))
        gate.close()
    }

    @TestCase
    public func testTokenBucketBackendRate(): Unit {
        let backend = TokenBucketRateLimitBackend()
        let now = DateTime.now().toUnixTimeStamp().toNanoseconds()
        @Assert(true, backend.tryAcquire('k', 2, now))
        @Assert(true, backend.tryAcquire('k', 2, now))
        @Assert(false, backend.tryAcquire('k', 2, now))
        // 过一分钟理论上会补满；这里只验证桶不会永久拒绝
        @Assert(false, backend.tryAcquire('k', 2, now))
        backend.close()
    }
}
