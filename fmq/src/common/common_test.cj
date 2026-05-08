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
package fountain::fmq.common

import std.unittest.*
import std.unittest.testmacro.*

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
    public func testConfigLoad(): Unit {
        let config = loadConfig()
        @Assert(config.dataDir == "/var/fmq/data/")
        @Assert(config.heartbeatIntervalSec == 5)
        @Assert(config.ackTimeoutMs == 30000)
    }

    @TestCase
    public func testMatchMode(): Unit {
        let exact = MatchMode.Exact("/order/create")
        let glob = MatchMode.Glob("/order/*")
        let prefix = MatchMode.Prefix("/order/")
        @Assert(MatchMode.Exact("/a") != MatchMode.Exact("/b"))
        @Assert(MatchMode.Glob("/a/*") != MatchMode.Glob("/b/*"))
        @Assert(MatchMode.Prefix("/a/") != MatchMode.Prefix("/b/"))
    }
}
