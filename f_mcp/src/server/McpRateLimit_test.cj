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
package fountain::f_mcp.server

import std.collection.ArrayList
import std.sync.AtomicBool
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_concurrent.RateLimiter
import fountain::f_config.Config

/** 测试用自定义后端：始终放行，验证注册表 + 配置项能选中开发者实现。 */
class AlwaysAllowRateLimitBackend <: RateLimitBackend {
    public static prop name: String {
        get() {
            'always-allow'
        }
    }

    public static func new(): RateLimitBackend {
        AlwaysAllowRateLimitBackend()
    }

    public func tryAcquire(_: String, _: Int64, _: Int64): Bool {
        true
    }

    public func close(): Unit {}
}

/** 可观测的限流器：只用于确认池淘汰/关闭时真的调用了 `close()`。 */
class ObservableLimiter <: RateLimiter<Bool> {
    let closed = AtomicBool(false)

    init() {
        super(Duration.millisecond)
    }

    public func exec(default: ?Bool, task: () -> ?Bool): ?Bool {
        task()
    }

    public override func close(): Unit {
        closed.store(true)
    }
}

@Test
class McpRateLimit_test {
    @TestCase
    public func testLimiterPoolIsBounded(): Unit {
        let created = ArrayList<ObservableLimiter>()
        let pool = LimiterPool({_ => 
            let limiter = ObservableLimiter()
            created.add(limiter)
            limiter
        }, maxSize: 100, idleTtl: Duration.minute)
        for (i in 0..1000) {
            pool.acquire('caller-${i}', 60)
        }
        pool.sweepNow()
        @Assert(true, pool.size <= 100)
        var closed = 0
        for (limiter in created) {
            if (limiter.closed.load()) {
                closed++
            }
        }
        @Assert(true, closed >= created.size - 100)
        pool.close()
        @Assert(0, pool.size)
    }

    @TestCase
    public func testLimiterPoolReclaimsIdleEntries(): Unit {
        let created = ArrayList<ObservableLimiter>()
        let pool = LimiterPool({_ =>
            let limiter = ObservableLimiter()
            created.add(limiter)
            limiter
        }, maxSize: 100, idleTtl: Duration.millisecond * 20)
        for (i in 0..3) {
            pool.acquire('caller-${i}', 60)
        }
        @Assert(3, pool.size)
        sleep(Duration.millisecond * 60)
        pool.sweepNow()
        @Assert(0, pool.size)
        for (limiter in created) {
            @Assert(true, limiter.closed.load())
        }
        pool.close()
    }

    @TestCase
    public func testFactoryNames(): Unit {
        @Assert(true, RateLimitBackends.of('token-bucket') is TokenBucketRateLimitBackend)
        @Assert(true, RateLimitBackends.of('leaking-bucket') is LeakingBucketRateLimitBackend)
        @Assert(true, RateLimitBackends.of('sliding-window') is SlidingWindowRateLimitBackend)
        @Assert(true, RateLimitBackends.of('unlimited') is UnlimitedRateLimitBackend)
        @Assert(true, RateLimitBackends.of('Token_Bucket') is TokenBucketRateLimitBackend)
        @ExpectThrows[IllegalArgumentException](RateLimitBackends.of('nope'))
    }

    @TestCase
    public func testRegisterCustomBackend(): Unit {
        RateLimitBackends.register<AlwaysAllowRateLimitBackend>()
        @Assert(true, RateLimitBackends.of('Always_Allow') is AlwaysAllowRateLimitBackend)
    }

    @TestCase
    public func testConfigSelectsCustomBackend(): Unit {
        RateLimitBackends.register<AlwaysAllowRateLimitBackend>()
        Config.set([(McpConfig.RATE_LIMIT_BACKEND, 'always-allow')])
        try {
            @Assert(true, RateLimitBackends.fromConfig() is AlwaysAllowRateLimitBackend)
        } finally {
            Config.remove(McpConfig.RATE_LIMIT_BACKEND)
        }
    }

    @TestCase
    public func testTokenBucket(): Unit {
        let backend = TokenBucketRateLimitBackend()
        try {
            @Assert(true, backend.tryAcquire('k', 2, 0))
            @Assert(true, backend.tryAcquire('k', 2, 0))
            @Assert(false, backend.tryAcquire('k', 2, 0))
            @Assert(true, backend.tryAcquire('other', 2, 0))
        } finally {
            backend.close()
        }
    }

    @TestCase
    public func testLeakingBucket(): Unit {
        let backend = LeakingBucketRateLimitBackend()
        try {
            var passed = 0
            for (_ in 0..5) {
                if (backend.tryAcquire('k', 2, 0)) {
                    passed++
                }
            }
            @Assert(true, passed >= 2)
            @Assert(true, passed < 5)
        } finally {
            backend.close()
        }
    }

    @TestCase
    public func testSlidingWindow(): Unit {
        let backend = SlidingWindowRateLimitBackend()
        try {
            var passed = 0
            for (_ in 0..5) {
                if (backend.tryAcquire('k', 2, 0)) {
                    passed++
                }
            }
            @Assert(true, passed >= 2)
            @Assert(true, passed < 5)
        } finally {
            backend.close()
        }
    }

    @TestCase
    public func testAnyMomentBackendIsRemoved(): Unit {
        try {
            let _ = RateLimitBackends.of('any-moment')
            @Fail('expected IllegalArgumentException')
        } catch (e: IllegalArgumentException) {
            @Assert(true, e.message.contains('any-moment'))
        }
    }

    @TestCase
    public func testUnlimited(): Unit {
        let backend = UnlimitedRateLimitBackend()
        try {
            for (_ in 0..100) {
                @Assert(true, backend.tryAcquire('k', 1, 0))
            }
        } finally {
            backend.close()
        }
    }

    @TestCase
    public func testZeroRpmAlwaysPasses(): Unit {
        let backend = TokenBucketRateLimitBackend()
        try {
            @Assert(true, backend.tryAcquire('k', 0, 0))
        } finally {
            backend.close()
        }
    }
}
