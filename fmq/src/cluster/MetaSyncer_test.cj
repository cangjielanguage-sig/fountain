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
import std.sync.AtomicInt64
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
            let assignment = MQTopicAssignment("/t", 2, 0, [0, 1], delayingMs: 61000)
            @Assert(syncer.applyRemote(assignment) == MetaApplyResult.Applied)
            @Assert(syncer.applyRemote(assignment) == MetaApplyResult.Duplicated)
            @Assert(syncer.applyRemote(MQTopicAssignment("/t", 3, 0, [0, 1, 2])) == MetaApplyResult.Conflict)
            @Assert(store.topicOf("/t").getOrThrow().queueNum == 2)
            @Assert(store.topicOf("/t").getOrThrow().delayingMs == 61000)
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
            syncer.registerTopic(MQTopicMeta("/a", 2, delayingMs: 61000))
            syncer.registerGroup(MQSubscribeGroupMeta("/a", "g"))
            let snapshot = syncer.snapshotFor(1)
            @Assert(snapshot.topics.size == 1)
            @Assert(snapshot.topics[0].delayingMs == 61000)
            @Assert(snapshot.groups.size == 1)
            @Assert(snapshot.nextStartNode == 2)
        } finally {
            shutdown(store, "snapshot")
        }
    }
    @TestCase
    public func registerTopicRejectsNegativeDelaying(): Unit {
        let (store, _, syncer) = fixture("negative_delay")
        try {
            var rejected = false
            try {
                syncer.registerTopic(MQTopicMeta("/neg", 1, delayingMs: -1))
            } catch (_: Exception) {
                rejected = true
            }
            @Assert(rejected)
            @Assert(store.topicOf("/neg").isNone())
        } finally {
            shutdown(store, "negative_delay")
        }
    }

    // ===== 删除收敛（A25） =====

    /** 离线节点重启后，peer 的快照必须让它删掉「离线期间被删掉」的主题。 */
    @TestCase
    public func snapshotMergeDropsTopicDeletedWhileOffline(): Unit {
        let dir = dirOf("merge_topic")
        clean(dir)
        try {
            let store = MetaStore(dir)
            store.load()
            store.applyTopic(MQTopicAssignment("/t", 1, 0, [0], revision: 3))
            @Assert(store.topicOf("/t").isSome())

            let transport = FakeTransport(2, 1)
            let syncer = MetaSyncer(store, transport)
            let tombstone = MQMetaTombstone(MQMetaTombstone.KIND_TOPIC, "/t", "", 9, 0, 0)
            let snapshot = MQMetaSnapshot(Array<MQTopicAssignment>(), Array<MQSubscribeGroupMeta>(), 0,
                tombstones: [tombstone], revision: 9)
            transport.responder = {_, request => Some(MQProtocol.respond<MQMetaSnapshot>(request, snapshot))}
            syncer.syncFromPeers()

            @Assert(store.topicOf("/t").isNone())
            @Assert(store.allTombstones().size == 1)
            store.close()
        } finally {
            clean(dir)
        }
    }

    /** 组删除后重启不复活，且同主题重新注册同名组可以成功（墓碑被更高 revision 覆盖）。 */
    @TestCase
    public func deletedGroupCanBeRecreatedWithHigherRevision(): Unit {
        let dir = dirOf("merge_group")
        clean(dir)
        try {
            let store = MetaStore(dir)
            store.load()
            store.applyTopic(MQTopicAssignment("/t", 1, 0, [0], revision: 1))
            store.applyGroup(MQSubscribeGroupMeta("/t", "g", revision: 2))
            @Assert(store.groupExists("/t", "g"))

            let transport = FakeTransport(2, 1)
            let syncer = MetaSyncer(store, transport)
            let tombstone = MQMetaTombstone(MQMetaTombstone.KIND_GROUP, "/t", "g", 7, 0, 0)
            let snapshot = MQMetaSnapshot([MQTopicAssignment("/t", 1, 0, [0], revision: 1)],
                Array<MQSubscribeGroupMeta>(), 0, tombstones: [tombstone], revision: 7)
            transport.responder = {_, request => Some(MQProtocol.respond<MQMetaSnapshot>(request, snapshot))}
            syncer.syncFromPeers()
            @Assert(!store.groupExists("/t", "g"))

            // 重新注册同名组：更高 revision 覆盖墓碑
            @Assert(store.applyGroup(MQSubscribeGroupMeta("/t", "g", revision: 8)) == MetaApplyResult.Applied)
            @Assert(store.groupExists("/t", "g"))
            store.close()
        } finally {
            clean(dir)
        }
    }

    /** 快照不带版本（旧 peer）时不做「缺失即删除」，避免互相清空。 */
    @TestCase
    public func legacySnapshotDoesNotWipeLocalMetadata(): Unit {
        let dir = dirOf("merge_legacy")
        clean(dir)
        try {
            let store = MetaStore(dir)
            store.load()
            store.applyTopic(MQTopicAssignment("/t", 1, 0, [0]))

            let transport = FakeTransport(2, 1)
            let syncer = MetaSyncer(store, transport)
            let snapshot = MQMetaSnapshot(Array<MQTopicAssignment>(), Array<MQSubscribeGroupMeta>(), 0)
            transport.responder = {_, request => Some(MQProtocol.respond<MQMetaSnapshot>(request, snapshot))}
            syncer.syncFromPeers()

            @Assert(store.topicOf("/t").isSome())
            store.close()
        } finally {
            clean(dir)
        }
    }

    // ===== 注册原子性与广播（A28） =====

    @TestCase
    public func registeredAssignmentMatchesPersistedAndBroadcastsOnce(): Unit {
        let dir = dirOf("register_atomic")
        clean(dir)
        try {
            let store = MetaStore(dir)
            store.load()
            let transport = FakeTransport(3, 0)
            transport.responder = {_, message =>
                Some(MQProtocol.respond<MQResult>(message, MQResult(0, "ok")))
            }
            let syncer = MetaSyncer(store, transport)
            let returned = syncer.registerTopic(MQTopicMeta("/t", 2, delayingMs: 500))
            let persisted = store.topicOf("/t").getOrThrow()
            @Assert(returned.topic == persisted.topic)
            @Assert(returned.queueNum == persisted.queueNum)
            @Assert(returned.startNodeIndex == persisted.startNodeIndex)
            @Assert(returned.delayingMs == persisted.delayingMs)
            @Assert(returned.owners == persisted.owners)
            @Assert(returned.revision == persisted.revision)
            // 只广播一次，且内容是落盘结果
            @Assert(transport.messagesSentTo(1).size == 1)
            @Assert(transport.messagesSentTo(2).size == 1)
            // 重复注册抛「已存在」，且不再广播
            var thrown = false
            try {
                syncer.registerTopic(MQTopicMeta("/t", 2))
            } catch (_: MQServiceException) {
                thrown = true
            }
            @Assert(thrown)
            @Assert(transport.messagesSentTo(1).size == 1)
            store.close()
        } finally {
            clean(dir)
        }
    }

    @TestCase
    public func concurrentRegisterThemeThrowsAlreadyExist(): Unit {
        let dir = dirOf("register_concurrent")
        clean(dir)
        try {
            let store = MetaStore(dir)
            store.load()
            let transport = FakeTransport(1, 0)
            let syncer = MetaSyncer(store, transport)
            let successes = Array<Int64>(8, repeat: 0)
            let done = AtomicInt64(0)
            for (i in 0..8) {
                spawn {
                    try {
                        syncer.registerTopic(MQTopicMeta("/t", 4))
                        successes[i] = 1
                    } catch (_: MQServiceException) {
                        successes[i] = 0
                    }
                    done.fetchAdd(1)
                }
            }
            var waited = 0
            while (done.load() < 8 && waited < 3000) {
                sleep(Duration.millisecond * 1)
                waited++
            }
            @Assert(done.load() == 8)
            var applied = 0
            for (value in successes) {
                applied += value
            }
            @Assert(applied == 1)
            store.close()
        } finally {
            clean(dir)
        }
    }

    // ===== 组依赖与待应用队列（A36） =====

    @TestCase
    public func groupArrivingBeforeTopicIsAppliedLater(): Unit {
        let dir = dirOf("group_before_topic")
        clean(dir)
        try {
            let store = MetaStore(dir)
            store.load()
            let transport = FakeTransport(1, 0)
            let syncer = MetaSyncer(store, transport)

            // 组先到：进入待应用队列，不落盘
            @Assert(syncer.applyRemoteGroup(MQSubscribeGroupMeta("/t", "g", revision: 2)) ==
                MetaApplyResult.TopicMissing)
            @Assert(!store.groupExists("/t", "g"))

            // 主题到达后自动应用
            @Assert(syncer.applyRemote(MQTopicAssignment("/t", 1, 0, [0], revision: 1)) ==
                MetaApplyResult.Applied)
            @Assert(store.groupExists("/t", "g"))
            store.close()
        } finally {
            clean(dir)
        }
    }

    @TestCase
    public func groupIsRejectedWhenTopicIsDeleted(): Unit {
        let dir = dirOf("group_after_delete")
        clean(dir)
        try {
            let store = MetaStore(dir)
            store.load()
            let transport = FakeTransport(1, 0)
            let syncer = MetaSyncer(store, transport)
            syncer.applyRemote(MQTopicAssignment("/t", 1, 0, [0], revision: 1))
            @Assert(store.removeTopic("/t").isSome())

            @Assert(syncer.applyRemoteGroup(MQSubscribeGroupMeta("/t", "g", revision: 5)) ==
                MetaApplyResult.TopicMissing)
            @Assert(!store.groupExists("/t", "g"))
            store.close()
        } finally {
            clean(dir)
        }
    }
}
