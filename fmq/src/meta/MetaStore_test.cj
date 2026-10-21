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
package fountain::fmq.meta

import std.fs.*
import std.sync.AtomicInt64
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_mq.base.model.MQSubscribeGroupMeta
import fountain::f_mq.base.payload.{MQMetaSnapshot, MQMetaTombstone, MQTopicAssignment}
import fountain::f_mq.base.MQProtocol

@Test
class MetaStoreTest {
    private static func dirOf(name: String): String {
        "/tmp/fmq_test_meta_store/${name}"
    }

    private static func clean(dir: String): Unit {
        if (exists(dir)) {
            remove(dir, recursive: true)
        }
    }

    @TestCase
    public func persistenceReloadsEverything(): Unit {
        let dir = dirOf("reload")
        clean(dir)
        try {
            let first = MetaStore(dir)
            first.load()
            @Assert(first.applyTopic(MQTopicAssignment("/t", 2, 0, [0, 1], delayingMs: 61000), nextStart: 1) ==
                MetaApplyResult.Applied)
            @Assert(first.applyGroup(MQSubscribeGroupMeta("/t", "")) == MetaApplyResult.Applied)
            @Assert(first.applyGroup(MQSubscribeGroupMeta("/t", "g1")) == MetaApplyResult.Applied)
            first.close()

            let second = MetaStore(dir)
            second.load()
            let assignment = second.topicOf("/t").getOrThrow()
            @Assert(assignment.queueNum == 2)
            @Assert(assignment.owners == [0, 1])
            @Assert(assignment.delayingMs == 61000)
            @Assert(second.groupsOf("/t").size == 2)
            @Assert(second.groupExists("/t", ""))
            @Assert(second.nextStartNode == 1)
            second.close()
        } finally {
            clean(dir)
        }
    }

    @TestCase
    public func duplicateAndConflictHandling(): Unit {
        let dir = dirOf("duplicate")
        clean(dir)
        try {
            let store = MetaStore(dir)
            store.load()
            let assignment = MQTopicAssignment("/t", 2, 0, [0, 1])
            @Assert(store.applyTopic(assignment) == MetaApplyResult.Applied)
            @Assert(store.applyTopic(assignment) == MetaApplyResult.Duplicated)
            let conflicting = MQTopicAssignment("/t", 3, 0, [0, 1, 2])
            @Assert(store.applyTopic(conflicting) == MetaApplyResult.Conflict)
            // 先到者保留
            @Assert(store.topicOf("/t").getOrThrow().queueNum == 2)

            let group = MQSubscribeGroupMeta("/t", "g")
            @Assert(store.applyGroup(group) == MetaApplyResult.Applied)
            @Assert(store.applyGroup(group) == MetaApplyResult.Duplicated)
            store.close()
        } finally {
            clean(dir)
        }
    }

    @TestCase
    public func deleteTopicCascadesGroups(): Unit {
        let dir = dirOf("cascade")
        clean(dir)
        try {
            let store = MetaStore(dir)
            store.load()
            store.applyTopic(MQTopicAssignment("/t", 1, 0, [0]))
            store.applyGroup(MQSubscribeGroupMeta("/t", "g1"))
            store.applyGroup(MQSubscribeGroupMeta("/t", "g2"))
            @Assert(store.removeTopic("/t").isSome())
            @Assert(store.topicOf("/t").isNone())
            @Assert(store.groupsOf("/t").size == 0)
            @Assert(!store.groupExists("/t", "g1"))
            @Assert(!exists("${dir}/topics/%2Ft.meta"))
            store.close()
        } finally {
            clean(dir)
        }
    }

    @TestCase
    public func snapshotContainsAllEntries(): Unit {
        let dir = dirOf("snapshot")
        clean(dir)
        try {
            let store = MetaStore(dir)
            store.load()
            store.applyTopic(MQTopicAssignment("/a", 2, 0, [0, 1]), nextStart: 2)
            store.applyTopic(MQTopicAssignment("/b", 1, 2, [0]))
            store.applyGroup(MQSubscribeGroupMeta("/a", "g"))
            let snapshot = store.snapshot()
            @Assert(snapshot.topics.size == 2)
            @Assert(snapshot.groups.size == 1)
            @Assert(snapshot.nextStartNode == 2)
            store.close()
        } finally {
            clean(dir)
        }
    }

    @TestCase
    public func corruptedFilesAreSkipped(): Unit {
        let dir = dirOf("corrupted")
        clean(dir)
        try {
            Directory.create("${dir}/topics", recursive: true)
            let junk = File.create("${dir}/topics/broken.meta")
            junk.write([0xFFu8, 0xFEu8, 0x00u8])
            junk.close()
            let store = MetaStore(dir)
            store.load()
            // 坏文件跳过，仍可继续工作
            @Assert(store.applyTopic(MQTopicAssignment("/ok", 1, 0, [0])) == MetaApplyResult.Applied)
            @Assert(store.topicOf("/ok").isSome())
            store.close()
        } finally {
            clean(dir)
        }
    }

    @TestCase
    public func atomicWriteSurvivesStaleTmp(): Unit {
        let dir = dirOf("atomic")
        clean(dir)
        try {
            let topicFile = "${dir}/topics/%2Ft.meta"
            Directory.create("${dir}/topics", recursive: true)
            let stale = File.create("${topicFile}.tmp")
            stale.write([1u8, 2u8, 3u8])
            stale.close()
            let store = MetaStore(dir)
            store.load()
            store.applyTopic(MQTopicAssignment("/t", 1, 0, [0]))
            @Assert(store.topicOf("/t").isSome())
            // 重新加载仍然完整
            let reloaded = MetaStore(dir)
            reloaded.load()
            @Assert(reloaded.topicOf("/t").getOrThrow().owners == [0])
            reloaded.close()
            store.close()
        } finally {
            clean(dir)
        }
    }

    @TestCase
    public func concurrentAppliesKeepAllTopics(): Unit {
        let dir = dirOf("concurrent")
        clean(dir)
        try {
            let store = MetaStore(dir)
            store.load()
            let done = AtomicInt64(0)
            for (worker in 0..4) {
                spawn {
                    for (i in 0..20) {
                        let topic = "/t-${worker}-${i}"
                        store.applyTopic(MQTopicAssignment(topic, 1, 0, [0]))
                    }
                    done.fetchAdd(1)
                }
            }
            var waited = 0
            while (done.load() < 4 && waited < 500) {
                sleep(Duration.millisecond * 10)
                waited++
            }
            @Assert(done.load() == 4)
            @Assert(store.topics().size == 80)
            store.close()
        } finally {
            clean(dir)
        }
    }

    // ===== revision 与墓碑（A25/A31） =====

    @TestCase
    public func revisionIsMonotonicAndPersisted(): Unit {
        let dir = dirOf("revision")
        clean(dir)
        try {
            let first = MetaStore(dir)
            first.load()
            let r1 = first.nextRevision()
            let r2 = first.nextRevision()
            @Assert(r2 == r1 + 1)
            first.close()

            let second = MetaStore(dir)
            second.load()
            @Assert(second.nextRevision() > r2)
            second.close()
        } finally {
            clean(dir)
        }
    }

    @TestCase
    public func olderRevisionIsIgnored(): Unit {
        let dir = dirOf("revision_order")
        clean(dir)
        try {
            let store = MetaStore(dir)
            store.load()
            // revision 5 先到，revision 3 后到：必须保留 5
            @Assert(store.applyTopic(MQTopicAssignment("/t", 2, 0, [0, 1], revision: 5)) ==
                MetaApplyResult.Applied)
            @Assert(store.applyTopic(MQTopicAssignment("/t", 3, 0, [0, 1, 2], revision: 3)) ==
                MetaApplyResult.Duplicated)
            @Assert(store.topicOf("/t").getOrThrow().queueNum == 2)
            store.close()
        } finally {
            clean(dir)
        }
    }

    @TestCase
    public func sameRevisionKeepsFirstAndWarns(): Unit {
        let dir = dirOf("revision_conflict")
        clean(dir)
        try {
            let store = MetaStore(dir)
            store.load()
            @Assert(store.applyTopic(MQTopicAssignment("/t", 2, 0, [0, 1], revision: 5, origin: 1)) ==
                MetaApplyResult.Applied)
            // 同 revision 同 origin 但内容不同：保留先到者
            @Assert(store.applyTopic(MQTopicAssignment("/t", 9, 0, [0, 1, 2, 3, 4, 5, 6, 7, 8], revision: 5,
                origin: 1)) == MetaApplyResult.Conflict)
            @Assert(store.topicOf("/t").getOrThrow().queueNum == 2)
            // 同 revision、更高 origin：胜出
            @Assert(store.applyTopic(MQTopicAssignment("/t", 3, 0, [0, 1, 2], revision: 5, origin: 2)) ==
                MetaApplyResult.Applied)
            @Assert(store.topicOf("/t").getOrThrow().queueNum == 3)
            store.close()
        } finally {
            clean(dir)
        }
    }

    @TestCase
    public func legacyMetadataLoadsAtRevisionZero(): Unit {
        let dir = dirOf("legacy")
        clean(dir)
        try {
            // 直接写一个旧格式（无 revision）的主题文件
            let store0 = MetaStore(dir)
            store0.load()
            store0.applyTopic(MQTopicAssignment("/t", 1, 0, [0]))
            store0.close()

            let store = MetaStore(dir)
            store.load()
            @Assert(store.topicOf("/t").getOrThrow().revision == 0)
            // 旧数据不阻塞版本推进
            @Assert(store.nextRevision() == 1)
            store.close()
        } finally {
            clean(dir)
        }
    }

    @TestCase
    public func deleteWritesTombstoneThatSurvivesReload(): Unit {
        let dir = dirOf("tombstone")
        clean(dir)
        try {
            let store = MetaStore(dir, origin: 3)
            store.load()
            store.applyTopic(MQTopicAssignment("/t", 1, 0, [0], revision: 2))
            let tombstone = store.removeTopic("/t").getOrThrow()
            @Assert(tombstone.revision > 2)
            @Assert(tombstone.origin == 3)
            @Assert(store.topicOf("/t").isNone())
            store.close()

            let reloaded = MetaStore(dir, origin: 3)
            reloaded.load()
            @Assert(reloaded.topicOf("/t").isNone())
            @Assert(reloaded.allTombstones().size == 1)
            @Assert(reloaded.snapshot().tombstones.size == 1)
            @Assert(reloaded.snapshot().tombstoneFloor == tombstone.revision)
            reloaded.close()
        } finally {
            clean(dir)
        }
    }

    @TestCase
    public func tombstoneGcRespectsTtl(): Unit {
        let dir = dirOf("tombstone_gc")
        clean(dir)
        try {
            let store = MetaStore(dir)
            store.load()
            store.applyTopic(MQTopicAssignment("/t", 1, 0, [0], revision: 1))
            let tombstone = store.removeTopic("/t").getOrThrow()
            let now = tombstone.deletedAtMs
            // 未过期：不回收
            @Assert(store.gcTombstones(now + 1000, Duration.hour.toMilliseconds()) == 0)
            @Assert(store.allTombstones().size == 1)
            // 过期且无活跃条目：回收
            @Assert(store.gcTombstones(now + Duration.hour.toMilliseconds() + 1,
                Duration.hour.toMilliseconds()) == 1)
            @Assert(store.allTombstones().size == 0)
            store.close()
        } finally {
            clean(dir)
        }
    }

    @TestCase
    public func tombstoneRemovesLocalEntryOnlyWhenOlder(): Unit {
        let dir = dirOf("tombstone_apply")
        clean(dir)
        try {
            let store = MetaStore(dir)
            store.load()
            store.applyTopic(MQTopicAssignment("/t", 1, 0, [0], revision: 4))
            // 墓碑更旧：不能删掉更新的本地条目
            @Assert(store.applyTombstone(MQMetaTombstone(MQMetaTombstone.KIND_TOPIC, "/t", "", 3, 0, 0)) ==
                MetaApplyResult.Applied)
            @Assert(store.topicOf("/t").isSome())
            // 墓碑更新：删除本地
            @Assert(store.applyTombstone(MQMetaTombstone(MQMetaTombstone.KIND_TOPIC, "/t", "", 9, 0, 0)) ==
                MetaApplyResult.Applied)
            @Assert(store.topicOf("/t").isNone())
            store.close()
        } finally {
            clean(dir)
        }
    }
}
