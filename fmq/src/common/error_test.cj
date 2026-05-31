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
public class ErrorTest {
    @TestCase
    public func testErrorCodeEquality(): Unit {
        @Assert(MqErrorCode.SUCCESS == MqErrorCode.SUCCESS)
        @Assert(!(MqErrorCode.SUCCESS == MqErrorCode.TOPIC_NOT_FOUND))
    }

    @TestCase
    public func testErrorCodeToString(): Unit {
        @Assert(MqErrorCode.SUCCESS.toString() == "SUCCESS")
        @Assert(MqErrorCode.INVALID_TOPIC_FORMAT.toString() == "INVALID_TOPIC_FORMAT")
    }

    @TestCase
    public func testMqExceptionConstructors(): Unit {
        let e2 = MqException("test error")
        let e4 = MqException("msg", Exception("cause"))
        @Assert(e2.message == "test error")
        @Assert(e4.message == "msg")
    }
}
