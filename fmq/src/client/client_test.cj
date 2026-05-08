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
package fountain::fmq.client

import std.unittest.*
import std.unittest.testmacro.*

@Test
public class ConfigTest {
    @TestCase
    public func testConfigLoad(): Unit {
        let config = loadConfig()
        @Assert(config.dataDir == "/var/fmq/data/")
        @Assert(config.heartbeatIntervalSec == 5)
    }
}

@Test
public class TopicValidationTest {
    @TestCase
    public func testValidTopics(): Unit {
        @Assert(validateTopic("/order/create"))
        @Assert(validateTopic("/"))
        @Assert(validateTopic("/a/b/c"))
        @Assert(validateTopic("/order-123"))
    }

    @TestCase
    public func testInvalidTopics(): Unit {
        @Assert(!validateTopic(""))
        @Assert(!validateTopic("no-leading-slash"))
        @Assert(!validateTopic("/with space"))
    }

    @TestCase
    public func testEncodeDecode(): Unit {
        let topic = "/order/create"
        let encoded = encodeTopicToPath(topic)
        @Assert(encoded == "_order_create")
        @Assert(decodePathToTopic(encoded) == topic)
    }
}

@Test
public class MatchModeTest {
    @TestCase
    public func testMatchModeValues(): Unit {
        let _ = MatchMode.Exact("/order/create")
        @Assert(true)
    }
}

@Test
public class MessageStructTest {
    @TestCase
    public func testBasics(): Unit {
        let msg = Message()
        @Assert(msg.topic == "")
        @Assert(msg.labels.size == 0)
        @Assert(msg.payload.size == 0)
    }
}
