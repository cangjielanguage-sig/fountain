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
package fountain::f_llm.llm

import std.collection.HashSet
import std.unittest.*
import std.unittest.testmacro.*

@Test
public class CircuitBreakerTest {

    @TestCase
    func testOpenAfterThreshold(): Unit {
        let breaker = CircuitBreaker(threshold: 3, cooldown: Duration.second * 30)
        breaker.recordRetryableFailure(1)
        breaker.recordRetryableFailure(1)
        @Expect(breaker.isOpen(1), false)
        breaker.recordRetryableFailure(1)
        @Expect(breaker.isOpen(1), true)
        @Expect(breaker.isOpen(2), false)
    }

    @TestCase
    func testSuccessResetsCounter(): Unit {
        let breaker = CircuitBreaker(threshold: 3, cooldown: Duration.second * 30)
        breaker.recordRetryableFailure(1)
        breaker.recordRetryableFailure(1)
        breaker.recordSuccess(1)
        breaker.recordRetryableFailure(1)
        breaker.recordRetryableFailure(1)
        @Expect(breaker.isOpen(1), false)
    }

    @TestCase
    func testCooldownReopens(): Unit {
        let breaker = CircuitBreaker(threshold: 2, cooldown: Duration.millisecond * 20)
        breaker.recordRetryableFailure(7)
        breaker.recordRetryableFailure(7)
        @Expect(breaker.isOpen(7), true)
        busyWait(Duration.millisecond * 40)
        @Expect(breaker.isOpen(7), false)
        // 冷却到期后计数清零：一次失败不足以再次下线
        breaker.recordRetryableFailure(7)
        @Expect(breaker.isOpen(7), false)
    }

    @TestCase
    func testCleanupRemovesDeadIds(): Unit {
        let breaker = CircuitBreaker(threshold: 5, cooldown: Duration.second * 30)
        breaker.recordRetryableFailure(1)
        breaker.recordRetryableFailure(2)
        @Expect(breaker.size(), 2)
        let alive = HashSet<Int64>([1])
        @Expect(breaker.cleanup(alive), 1)
        @Expect(breaker.size(), 1)
    }
}
