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

import std.unittest.*
import std.unittest.testmacro.*
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

@Test
class McpRateLimit_test {
    @TestCase
    public func testFactoryNames(): Unit {
        @Assert(true, RateLimitBackends.of('token-bucket') is TokenBucketRateLimitBackend)
        @Assert(true, RateLimitBackends.of('leaking-bucket') is LeakingBucketRateLimitBackend)
        @Assert(true, RateLimitBackends.of('sliding-window') is SlidingWindowRateLimitBackend)
        @Assert(true, RateLimitBackends.of('any-moment') is AnyMomentRateLimitBackend)
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
    public func testAnyMoment(): Unit {
        let backend = AnyMomentRateLimitBackend()
        try {
            // 瞬时并发语义：顺序调用不会累积配额，所以永远放行。
            var passed = 0
            for (_ in 0..5) {
                if (backend.tryAcquire('k', 2, 0)) {
                    passed++
                }
            }
            @Assert(5, passed)
        } finally {
            backend.close()
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
