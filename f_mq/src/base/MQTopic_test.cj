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
package fountain::f_mq.base

import std.unittest.*
import std.unittest.testmacro.*

@Test
class MQTopicTest {
    @TestCase
    public func validTopics(): Unit {
        @Assert(MQTopic.isValid("/order"))
        @Assert(MQTopic.isValid("/order/create"))
        @Assert(MQTopic.isValid("/a.b-c_1"))
        @Assert(MQTopic.isValid("/订单"))
    }

    @TestCase
    public func invalidTopics(): Unit {
        @Assert(!MQTopic.isValid(""))
        @Assert(!MQTopic.isValid("order"))
        @Assert(!MQTopic.isValid("/order/"))
        @Assert(!MQTopic.isValid("//a"))
        @Assert(!MQTopic.isValid("/a b"))
        @Assert(!MQTopic.isValid("/a/"))
        @Assert(!MQTopic.isValid("/"))
        @Assert(!MQTopic.isValid("/a//b"))
        @Assert(!MQTopic.isValid("/a\tb"))
    }
}
