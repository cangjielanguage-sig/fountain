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
package fountain::fmq.cluster

import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_mq.base.*
import fountain::f_mq.base.model.{MQSubscribeGroupMeta, MQTopicMeta}
import fountain::f_mq.base.payload.*
import fountain::f_mq.exception.MQServiceException
import fountain::fmq.meta.{MetaApplyResult, MetaStore}
import fountain::f_protocol.default.Message

@Test
class MetaSyncerTest {
    private static func dirOf(name: String): String {
        "/tmp/fmq_test_meta_syncer/${name}"
    }

    private static func clean(dir: String): Unit {
        if (exists(dir)) {
            remove(dir, recursive: true)
        }
    }

    private static func fixture(name: String, nodes!: Int64 = 3, selfIndex!: Int64 = 0): (MetaStore,
        FakeTransport, MetaSyncer) {
        let dir = dirOf(name)
        clean(dir)
        let store = MetaStore(dir)
        store.load()
        let transport = FakeTransport(nodes, selfIndex)
        (store, transport, MetaSyncer(store, transport))
    }

    private static func shutdown(store: MetaStore, name: String): Unit {
        store.close()
        clean(dirOf(name))
    }

    @TestCase
    public func registerTopicAllocatesAndBroadcasts(): Unit {
        let (store, transport, syncer) = fixture("register")
        try {
            let assignment = syncer.registerTopic(MQTopicMeta("/topic1", 4))
            @Assert(assignment.owners == [0, 1, 2, 0])
            @Assert(store.nextStartNode == 1)
            // 广播给两个 peer
            @Assert(transport.sentCount() == 2)
            @Assert(transport.messagesSentTo(1).size == 1)
            @Assert(transport.messagesSentTo(2).size == 1)
            let internal = MQProtocol.asInternal(transport.messagesSentTo(1)[0]).getOrThrow()
            @Assert(internal.kind == MQInternalKind.META_SYNC)
            let payload = MQProtocol.decodePayload<MQTopicAssignment>(internal.payload).getOrThrow()
            @Assert(payload.topic == "/topic1")
            @Assert(payload.owners == [0, 1, 2, 0])
        } finally {
            shutdown(store, "register")
        }
    }

    @TestCase
    public func registerTopicRejectsInvalidAndDuplicate(): Unit {
        let (store, _, syncer) = fixture("reject_topic")
        try {
            var code = -1i64
            try {
                syncer.registerTopic(MQTopicMeta("order", 1))
            } catch (e: MQServiceException) {
                code = e.code
            }
            @Assert(code == MQErrorCode.INVALID_TOPIC)

            syncer.registerTopic(MQTopicMeta("/t", 1))
            code = -1
            try {
                syncer.registerTopic(MQTopicMeta("/t", 1))
            } catch (e: MQServiceException) {
                code = e.code
            }
            @Assert(code == MQErrorCode.TOPIC_ALREADY_EXIST)
        } finally {
            shutdown(store, "reject_topic")
        }
    }

    @TestCase
    public func registerGroupRequiresTopicAndBroadcasts(): Unit {
        let (store, transport, syncer) = fixture("register_group")
        try {
            var code = -1i64
            try {
                syncer.registerGroup(MQSubscribeGroupMeta("/missing", "g"))
            } catch (e: MQServiceException) {
                code = e.code
            }
            @Assert(code == MQErrorCode.TOPIC_NOT_EXIST)

            syncer.registerTopic(MQTopicMeta("/t", 1))
            transport.clear()
            @Assert(syncer.registerGroup(MQSubscribeGroupMeta("/t", "g1")).code == 0)
            @Assert(store.groupExists("/t", "g1"))
            @Assert(transport.sentCount() == 2)

            code = -1
            try {
                syncer.registerGroup(MQSubscribeGroupMeta("/t", "g1"))
            } catch (e: MQServiceException) {
                code = e.code
            }
            @Assert(code == MQErrorCode.GROUP_ALREADY_EXIST)
        } finally {
            shutdown(store, "register_group")
        }
    }

    @TestCase
    public func deregisterTopicAndGroup(): Unit {
        let (store, transport, syncer) = fixture("deregister")
        try {
            syncer.registerTopic(MQTopicMeta("/t", 1))
            syncer.registerGroup(MQSubscribeGroupMeta("/t", "g"))
            transport.clear()
            @Assert(syncer.deregister(MQDeregisterPayload("group", "/t", subscribeGroup: "g")).code == 0)
            @Assert(!store.groupExists("/t", "g"))
            @Assert(transport.sentCount() == 2)

            transport.clear()
            @Assert(syncer.deregister(MQDeregisterPayload("topic", "/t")).code == 0)
            @Assert(store.topicOf("/t").isNone())
            @Assert(transport.sentCount() == 2)

            var code = -1i64
            try {
                syncer.deregister(MQDeregisterPayload("topic", "/missing"))
            } catch (e: MQServiceException) {
                code = e.code
            }
            @Assert(code == MQErrorCode.TOPIC_NOT_EXIST)
        } finally {
            shutdown(store, "deregister")
        }
    }

    @TestCase
    public func registerTopicKeepsDelayingInAssignmentAndBroadcast(): Unit {
        let (store, transport, syncer) = fixture("delaying")
        try {
            let assignment = syncer.registerTopic(MQTopicMeta("/d", 2, delayingMs: 61000))
            @Assert(assignment.delayingMs == 61000)
            @Assert(store.topicOf("/d").getOrThrow().delayingMs == 61000)
            let sent = transport.messagesSentTo(1)
            @Assert(sent.size == 1)
            let internal = MQProtocol.asInternal(sent[0]).getOrThrow()
            let remote = MQProtocol.decodePayload<MQTopicAssignment>(internal.payload).getOrThrow()
            @Assert(remote.delayingMs == 61000)
        } finally {
            shutdown(store, "delaying")
        }
    }

    @TestCase
    public func remoteApplyIsIdempotentAndKeepsFirst(): Unit {
        let (store, _, syncer) = fixture("remote")
        try {
            let assignment = MQTopicAssignment("/t", 2, 0, [0, 1])
            @Assert(syncer.applyRemote(assignment) == MetaApplyResult.Applied)
            @Assert(syncer.applyRemote(assignment) == MetaApplyResult.Duplicated)
            @Assert(syncer.applyRemote(MQTopicAssignment("/t", 3, 0, [0, 1, 2])) == MetaApplyResult.Conflict)
            @Assert(store.topicOf("/t").getOrThrow().queueNum == 2)
            // 远端变更同步推进本地轮转指针：(0 + 2) % 3 = 2
            @Assert(store.nextStartNode == 2)
        } finally {
            shutdown(store, "remote")
        }
    }

    @TestCase
    public func remoteApplyAdvancesRoundRobinPointer(): Unit {
        let (store, _, syncer) = fixture("remote_pointer")
        try {
            // 4 队列、start = 0、3 节点 → 下一 start = 1
            @Assert(syncer.applyRemote(MQTopicAssignment("/a", 4, 0, [0, 1, 2, 0])) == MetaApplyResult.Applied)
            @Assert(store.nextStartNode == 1)
            // 本地后续注册的新主题必须沿用推进后的起点
            let next = syncer.registerTopic(MQTopicMeta("/b", 2))
            @Assert(next.owners == [1, 2])
        } finally {
            shutdown(store, "remote_pointer")
        }
    }

    @TestCase
    public func startupSyncMergesSnapshot(): Unit {
        let (store, transport, syncer) = fixture("sync")
        try {
            let snapshot = MQMetaSnapshot(
                [MQTopicAssignment("/a", 2, 0, [0, 1]), MQTopicAssignment("/b", 1, 2, [2])],
                [MQSubscribeGroupMeta("/a", "g")], 5)
            transport.responder = {index, message =>
                match (message.command) {
                    case REGISTER => Some(MQProtocol.respond<MQMetaSnapshot>(message, snapshot))
                    case _ => None<Message>
                }
            }
            syncer.syncFromPeers()
            @Assert(store.topicOf("/a").isSome())
            @Assert(store.topicOf("/b").isSome())
            @Assert(store.groupExists("/a", "g"))
            @Assert(store.nextStartNode == 5)
        } finally {
            shutdown(store, "sync")
        }
    }

    @TestCase
    public func startupSyncWithAllPeersDownKeepsLocal(): Unit {
        let (store, transport, syncer) = fixture("sync_down")
        try {
            transport.available[1] = false
            transport.available[2] = false
            // 不应抛异常
            syncer.syncFromPeers()
            @Assert(store.topics().size == 0)
        } finally {
            shutdown(store, "sync_down")
        }
    }

    @TestCase
    public func snapshotForReturnsAllMetadata(): Unit {
        let (store, _, syncer) = fixture("snapshot")
        try {
            syncer.registerTopic(MQTopicMeta("/a", 2))
            syncer.registerGroup(MQSubscribeGroupMeta("/a", "g"))
            let snapshot = syncer.snapshotFor(1)
            @Assert(snapshot.topics.size == 1)
            @Assert(snapshot.groups.size == 1)
            @Assert(snapshot.nextStartNode == 2)
        } finally {
            shutdown(store, "snapshot")
        }
    }
}
