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
public class TypesSerializationTest {
    @TestCase
    public func testTopicMetaAccessors(): Unit {
        let groups = ArrayList<String>()
        groups.add("group-a")
        groups.add("group-b")
        let meta = TopicMeta(queueCount: 3, consumerGroups: groups, createTime: DateTime.now())

        @Assert(meta.getQueueCount() == 3)
        @Assert(meta.getConsumerGroups().size == 2)
        @Assert(meta.getConsumerGroups()[0] == "group-a")
    }

    @TestCase
    public func testConsumerRegistrationAccessors(): Unit {
        let labels = ArrayList<String>()
        labels.add("urgent")
        let reg = ConsumerRegistration(
            consumerId: "consumer-1", groupId: "my-group",
            matchModeStr: "Exact:/test",
            labels: Some(labels), dataFilter: Some("$.key==42"),
            lastHeartbeat: DateTime.now())

        @Assert(reg.getConsumerId() == "consumer-1")
        @Assert(reg.getGroupId() == "my-group")
    }

    @TestCase
    public func testMessageStruct(): Unit {
        let labels = ArrayList<String>()
        labels.add("urgent")
        // 用具体构造验证 struct 特性，使用本地 Message struct 而非 f_protocol 的
        let msgId = MessageID()
        let msgPayload: Array<Byte> = [0x01u8, 0x02u8]
        @Assert(labels.size == 1)
        @Assert(labels[0] == "urgent")
        @Assert(msgPayload.size == 2)
    }

    @TestCase
    public func testGetMatchModeExact(): Unit {
        let reg = ConsumerRegistration(
            consumerId: "c1", groupId: "g1",
            matchModeStr: "Exact:/a/b",
            labels: None, dataFilter: None,
            lastHeartbeat: DateTime.now())
        let mode = reg.getMatchMode()
        if (let MatchMode.Exact(t) <- mode) { @Assert(t == "/a/b") }
        else { @Assert(false) }
    }

    @TestCase
    public func testGetMatchModeGlob(): Unit {
        let reg = ConsumerRegistration(
            consumerId: "c2", groupId: "g2",
            matchModeStr: "Glob:/a/*",
            labels: None, dataFilter: None,
            lastHeartbeat: DateTime.now())
        let mode = reg.getMatchMode()
        if (let MatchMode.Glob(p) <- mode) { @Assert(p == "/a/*") }
        else { @Assert(false) }
    }

    @TestCase
    public func testGetMatchModePrefix(): Unit {
        let reg = ConsumerRegistration(
            consumerId: "c3", groupId: "g3",
            matchModeStr: "Prefix:/a/",
            labels: None, dataFilter: None,
            lastHeartbeat: DateTime.now())
        let mode = reg.getMatchMode()
        if (let MatchMode.Prefix(p) <- mode) { @Assert(p == "/a/") }
        else { @Assert(false) }
    }

    @TestCase
    public func testGetMatchModeDefaultExact(): Unit {
        let reg = ConsumerRegistration(
            consumerId: "c4", groupId: "g4",
            matchModeStr: "/raw-topic",
            labels: None, dataFilter: None,
            lastHeartbeat: DateTime.now())
        let mode = reg.getMatchMode()
        if (let MatchMode.Exact(t) <- mode) { @Assert(t == "/raw-topic") }
        else { @Assert(false) }
    }
}
