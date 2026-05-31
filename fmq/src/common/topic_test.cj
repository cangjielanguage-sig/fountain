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
public class TopicTest {
    @TestCase
    public func testValidateValidTopics(): Unit {
        @Assert(validateTopic("/order/create"))
        @Assert(validateTopic("/"))
        @Assert(validateTopic("/a/b/c"))
        @Assert(validateTopic("/order-123"))
    }

    @TestCase
    public func testValidateInvalidTopics(): Unit {
        @Assert(!validateTopic(""))
        @Assert(!validateTopic("no-leading-slash"))
        @Assert(!validateTopic("/with space"))
        @Assert(!validateTopic("/特殊字符"))
    }

    @TestCase
    public func testEncodeDecodeRoundtrip(): Unit {
        let topic = "/order/create"
        let encoded = encodeTopicToPath(topic)
        @Assert(encoded == "_order_create")
        @Assert(decodePathToTopic(encoded) == topic)
    }

    @TestCase
    public func testEncodeDecodeWithUnderscore(): Unit {
        let topic = "/a_b/c_d"
        let encoded = encodeTopicToPath(topic)
        @Assert(encoded == "_a__b_c__d")
        @Assert(decodePathToTopic(encoded) == topic)
    }

    @TestCase
    public func testEncodeDecodeDoubleUnderscore(): Unit {
        let topic = "/a__b"
        let encoded = encodeTopicToPath(topic)
        @Assert(encoded == "_a____b")
        @Assert(decodePathToTopic(encoded) == topic)
    }

    @TestCase
    public func testEncodeDecodeLongPath(): Unit {
        // 长路径压力测试：验证 O(n) 字符串拼接正确性
        let parts = Array<String>(50, repeat: "segment")
        let topic = "/" + String.join(parts, delimiter: "_")
        let encoded = encodeTopicToPath(topic)
        @Assert(decodePathToTopic(encoded) == topic)
    }

    @TestCase
    public func testConfigLoad(): Unit {
        let config = MqConfig(mqHosts: ArrayList())
        @Assert(config.dataDir == "/var/fmq/data/")
        @Assert(config.heartbeatIntervalSec == 5)
        @Assert(config.healthcheckMaxRetry == 3)
    }

    @TestCase
    public func testMatchMode(): Unit {
        let exact = MatchMode.Exact("/order/create")
        let glob = MatchMode.Glob("/order/*")
        let prefix = MatchMode.Prefix("/order/")
        match (exact) {
            case MatchMode.Exact(t) => @Assert(t == "/order/create")
            case _ => @Assert(false)
        }
        match (glob) {
            case MatchMode.Glob(p) => @Assert(p == "/order/*")
            case _ => @Assert(false)
        }
        match (prefix) {
            case MatchMode.Prefix(p) => @Assert(p == "/order/")
            case _ => @Assert(false)
        }
    }
}
