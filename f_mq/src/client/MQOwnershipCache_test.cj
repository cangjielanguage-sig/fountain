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
package fountain::f_mq.client

import std.unittest.*
import std.unittest.testmacro.*
import std.time.DateTime

class TestClock {
    var value: DateTime = DateTime.now()
}

@Test
class MQOwnershipCacheTest {
    @TestCase
    public func hitWithinTtl(): Unit {
        let clock = TestClock()
        let cache = MQOwnershipCache(ttl: Duration.second * 10, now: {=> clock.value})
        @Assert(cache.ownersOf("/t").isNone())
        cache.put("/t", [1, 2])
        @Assert(cache.ownersOf("/t") == Some([1, 2]))
    }

    @TestCase
    public func expiredEntryReturnsNone(): Unit {
        let clock = TestClock()
        let cache = MQOwnershipCache(ttl: Duration.second, now: {=> clock.value})
        cache.put("/t", [0])
        clock.value = clock.value + Duration.second * 2
        @Assert(cache.ownersOf("/t").isNone())
    }

    @TestCase
    public func invalidateAndReplace(): Unit {
        let clock = TestClock()
        let cache = MQOwnershipCache(ttl: Duration.minute, now: {=> clock.value})
        cache.put("/t", [0])
        cache.put("/t", [1, 2])
        @Assert(cache.ownersOf("/t") == Some([1, 2]))
        cache.invalidate("/t")
        @Assert(cache.ownersOf("/t").isNone())
        // 失效后再取仍为 None
        @Assert(cache.ownersOf("/t").isNone())
    }
}
