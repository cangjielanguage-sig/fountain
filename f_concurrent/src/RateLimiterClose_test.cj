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
package fountain::f_concurrent

import std.unittest.*
import std.unittest.testmacro.*

/** 只用于验证 `close()` 可被覆盖。 */
class CountingRateLimiter <: RateLimiter<Bool> {
    var closes = 0

    init() {
        super(Duration.millisecond)
    }

    public func exec(default: ?Bool, task: () -> ?Bool): ?Bool {
        task()
    }

    public override func close(): Unit {
        closes++
    }
}

@Test
class RateLimiterClose_test {
    @TestCase
    public func testBaseCloseIsOverridable(): Unit {
        let limiter = CountingRateLimiter()
        limiter.close()
        @Assert(1, limiter.closes)
    }

    @TestCase
    public func testTokenBucketCloseStopsRefill(): Unit {
        let limiter = TokenBucketRateLimiter<Bool>(tokens: 1, timeout: Duration.millisecond,
            populationPeriod: Duration.millisecond * 10)
        @Assert(true, limiter.exec(Some(false), {=> Some(true)}) ?? false)
        limiter.close()
        sleep(Duration.millisecond * 60)
        // 定时器已取消：不再补令牌
        @Assert(false, limiter.exec(Some(false), {=> Some(true)}) ?? false)
    }

    @TestCase
    public func testLeakingBucketCloseStopsLeaking(): Unit {
        let limiter = LeakingBucketRateLimiter<Bool>(timeout: Duration.millisecond * 5, maxWaitings: 1,
            leakingPerDuration: 1, leakingDuration: Duration.millisecond * 10)
        @Assert(true, limiter.exec(Some(false), {=> Some(true)}) ?? false)
        limiter.close()
        sleep(Duration.millisecond * 60)
        @Assert(false, limiter.exec(Some(false), {=> Some(true)}) ?? false)
    }

    @TestCase
    public func testSlidingWindowCloseIsIdempotent(): Unit {
        let limiter = SlidingWindowRateLimiter<Bool>(window: Duration.millisecond * 100,
            timeout: Duration.millisecond, limit: 1)
        @Assert(true, limiter.exec(Some(false), {=> Some(true)}) ?? false)
        // 滑动窗口的定时器本身就是消费端，close 的契约是「可重复调用且不抛异常」
        limiter.close()
        limiter.close()
        @Assert(true, true)
    }
}
