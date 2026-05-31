/*
Copyright (c) 2026 WuJingrun（吴京润）

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain at the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
 */
package fountain::fmq.common

import std.unittest.*
import std.unittest.testmacro.*
import std.collection.ArrayList
import std.env.{setVariable, removeVariable}
import std.io.{ByteBuffer, SeekPosition}
import fountain::f_protocol.default.Message as ProtocolMessage


@Test
public class ConfigTest {
    @TestCase
    public func testReadEnvIntNoEnvReturnsNone(): Unit {
        let result = readEnvInt("MQ_TEST_NONEXIST_VAR")
        @Assert(result.isNone())
    }

    @TestCase
    public func testReadEnvInvalidIntReturnsNone(): Unit {
        setVariable("MQ_TEST_EMPTY_VAR", "")
        @Assert(readEnvInt("MQ_TEST_NONEXIST_VAR").isNone())
        @Assert(readEnvInt("MQ_TEST_EMPTY_VAR").isNone())
        removeVariable("MQ_TEST_EMPTY_VAR")
    }

    @TestCase
    public func testClampPositiveRejectsInvalid(): Unit {
        // 零值 → 返回默认值
        @Assert(clampPositive(Some(0i64), 10, "test") == 10)
        // 负值 → 返回默认值
        @Assert(clampPositive(Some(-5i64), 10, "test") == 10)
        // 正值 → 返回原值
        @Assert(clampPositive(Some(5i64), 10, "test") == 5)
        // None → 返回默认值
        @Assert(clampPositive(None, 10, "test") == 10)
    }
}
