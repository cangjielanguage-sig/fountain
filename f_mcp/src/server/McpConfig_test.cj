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

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_config.Config

@Test
class McpConfig_test {
    @TestCase
    public func testCsvRateLimit(): Unit {
        Config.set([(McpConfig.RATE_LIMIT, '10,5,20,3,2')])
        try {
            let policy = McpConfig.rateLimit()
            @Assert(10, policy.perCallerRpm.getOrThrow())
            @Assert(5, policy.perCallerToolRpm.getOrThrow())
            @Assert(20, policy.perToolRpm.getOrThrow())
            @Assert(3, policy.maxConcurrency.getOrThrow())
            @Assert(2, policy.perCallerConcurrency.getOrThrow())
        } finally {
            Config.remove(McpConfig.RATE_LIMIT)
        }
    }

    @TestCase
    public func testJsonRateLimit(): Unit {
        Config.set([(McpConfig.RATE_LIMIT, '{"perCallerRpm":11,"perToolRpm":22}')])
        try {
            let policy = McpConfig.rateLimit()
            @Assert(11, policy.perCallerRpm.getOrThrow())
            @Assert(true, policy.perCallerToolRpm.isNone())
            @Assert(22, policy.perToolRpm.getOrThrow())
            @Assert(true, policy.maxConcurrency.isNone())
        } finally {
            Config.remove(McpConfig.RATE_LIMIT)
        }
    }

    static func expectRejected(raw: String, field: String): Unit {
        Config.set([(McpConfig.RATE_LIMIT, raw)])
        try {
            try {
                let _ = McpConfig.rateLimit()
                @Fail("expected IllegalArgumentException for '${raw}'")
            } catch (e: IllegalArgumentException) {
                @Assert(true, e.message.contains(field))
            }
        } finally {
            Config.remove(McpConfig.RATE_LIMIT)
        }
    }

    @TestCase
    public func testNegativeRateLimitIsRejected(): Unit {
        expectRejected('-1', 'perCallerRpm')
    }

    @TestCase
    public func testDecimalRateLimitIsRejected(): Unit {
        expectRejected('1.5', 'perCallerRpm')
    }

    @TestCase
    public func testTooManySegmentsAreRejected(): Unit {
        expectRejected('1,2,3,4,5,6', 'mcp_rateLimit')
    }

    @TestCase
    public func testUnknownJsonKeyIsRejected(): Unit {
        expectRejected('{"bogus":1}', 'bogus')
    }

    /** 中间空段：后面还有非空段时无法区分「省略」与「写错」，必须报错并指出字段。 */
    @TestCase
    public func testInnerEmptySegmentIsRejected(): Unit {
        expectRejected('1,,120', 'perCallerToolRpm')
        expectRejected(',1', 'perCallerRpm')
        expectRejected('1,2,,4', 'perToolRpm')
    }

    /** 尾部空段等价于省略：`1,,,` 与 `1` 同义。 */
    @TestCase
    public func testTrailingEmptySegmentsAreOmitted(): Unit {
        Config.set([(McpConfig.RATE_LIMIT, '1,,,')])
        let trailing = try {
            McpConfig.rateLimit()
        } finally {
            Config.remove(McpConfig.RATE_LIMIT)
        }
        @Assert(1, trailing.perCallerRpm.getOrThrow())
        @Assert(true, trailing.perCallerToolRpm.isNone())
        @Assert(true, trailing.perToolRpm.isNone())
        @Assert(true, trailing.maxConcurrency.isNone())
        @Assert(true, trailing.perCallerConcurrency.isNone())

        Config.set([(McpConfig.RATE_LIMIT, '1')])
        let single = try {
            McpConfig.rateLimit()
        } finally {
            Config.remove(McpConfig.RATE_LIMIT)
        }
        @Assert(single.perCallerRpm, trailing.perCallerRpm)

        Config.set([(McpConfig.RATE_LIMIT, '0,,,')])
        let zero = try {
            McpConfig.rateLimit()
        } finally {
            Config.remove(McpConfig.RATE_LIMIT)
        }
        @Assert(true, zero.perCallerRpm.isNone())
    }

    @TestCase
    public func testJsonDecimalIsRejected(): Unit {
        expectRejected('{"perCallerRpm":1.5}', 'perCallerRpm')
    }

    @TestCase
    public func testOutOfRangeRateLimitIsRejected(): Unit {
        expectRejected('1000001', 'perCallerRpm')
    }

    @TestCase
    public func testZeroMeansUnlimited(): Unit {
        Config.set([(McpConfig.RATE_LIMIT, '0,0,0,0,0')])
        try {
            let policy = McpConfig.rateLimit()
            @Assert(true, policy.perCallerRpm.isNone())
            @Assert(true, policy.perToolRpm.isNone())
            @Assert(true, policy.maxConcurrency.isNone())
        } finally {
            Config.remove(McpConfig.RATE_LIMIT)
        }
    }

    @TestCase
    public func testCsvAndJsonAreEquivalent(): Unit {
        Config.set([(McpConfig.RATE_LIMIT, '11,12,13,14,15')])
        let csv = try {
            McpConfig.rateLimit()
        } finally {
            Config.remove(McpConfig.RATE_LIMIT)
        }
        Config.set([(McpConfig.RATE_LIMIT,
            '{"perCallerRpm":11,"perCallerToolRpm":12,"perToolRpm":13,"maxConcurrency":14,"perCallerConcurrency":15}')])
        let json = try {
            McpConfig.rateLimit()
        } finally {
            Config.remove(McpConfig.RATE_LIMIT)
        }
        @Assert(csv.perCallerRpm, json.perCallerRpm)
        @Assert(csv.perCallerToolRpm, json.perCallerToolRpm)
        @Assert(csv.perToolRpm, json.perToolRpm)
        @Assert(csv.maxConcurrency, json.maxConcurrency)
        @Assert(csv.perCallerConcurrency, json.perCallerConcurrency)
    }

    @TestCase
    public func testTrustForwardedForValidation(): Unit {
        Config.set([(McpConfig.TRUST_FORWARDED_FOR, 'yes')])
        try {
            @ExpectThrows[IllegalArgumentException](McpConfig.trustForwardedFor())
        } finally {
            Config.remove(McpConfig.TRUST_FORWARDED_FOR)
        }
        Config.set([(McpConfig.TRUST_FORWARDED_FOR, ' TRUE ')])
        try {
            @Assert(true, McpConfig.trustForwardedFor())
        } finally {
            Config.remove(McpConfig.TRUST_FORWARDED_FOR)
        }
        @Assert(false, McpConfig.trustForwardedFor())
    }

    @TestCase
    public func testRateLimitBackendName(): Unit {
        Config.set([(McpConfig.RATE_LIMIT_BACKEND, ' sliding-window ')])
        try {
            @Assert('sliding-window', McpConfig.rateLimitBackendName())
        } finally {
            Config.remove(McpConfig.RATE_LIMIT_BACKEND)
        }
        @Assert('', McpConfig.rateLimitBackendName())
    }

    @TestCase
    public func testPublicBaseUrl(): Unit {
        Config.set([(McpConfig.PUBLIC_BASE_URL, ' https://mcp.example.com/// ')])
        try {
            @Assert('https://mcp.example.com', McpConfig.publicBaseUrl().getOrThrow())
        } finally {
            Config.remove(McpConfig.PUBLIC_BASE_URL)
        }
        @Assert(true, McpConfig.publicBaseUrl().isNone())

        Config.set([(McpConfig.PUBLIC_BASE_URL, '   ')])
        try {
            @Assert(true, McpConfig.publicBaseUrl().isNone())
        } finally {
            Config.remove(McpConfig.PUBLIC_BASE_URL)
        }
    }

    @TestCase
    public func testVersion(): Unit {
        Config.remove(McpConfig.VERSION)
        @Assert('1.0.0', McpConfig.version())

        Config.set([(McpConfig.VERSION, ' 2.1.0 ')])
        try {
            @Assert('2.1.0', McpConfig.version())
        } finally {
            Config.remove(McpConfig.VERSION)
        }

        Config.set([(McpConfig.VERSION, '   ')])
        try {
            @Assert('1.0.0', McpConfig.version())
        } finally {
            Config.remove(McpConfig.VERSION)
        }
    }

    @TestCase
    public func testAbsentRateLimit(): Unit {
        Config.remove(McpConfig.RATE_LIMIT)
        let policy = McpConfig.rateLimit()
        @Assert(true, policy.perCallerRpm.isNone())
        @Assert(true, policy.perCallerToolRpm.isNone())
        @Assert(true, policy.perToolRpm.isNone())
    }
}
