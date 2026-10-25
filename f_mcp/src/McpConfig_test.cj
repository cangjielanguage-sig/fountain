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

    @TestCase
    public func testAbsentRateLimit(): Unit {
        Config.remove(McpConfig.RATE_LIMIT)
        let policy = McpConfig.rateLimit()
        @Assert(true, policy.perCallerRpm.isNone())
        @Assert(true, policy.perCallerToolRpm.isNone())
        @Assert(true, policy.perToolRpm.isNone())
    }
}
