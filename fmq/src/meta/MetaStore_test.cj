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

import std.collection.ArrayList
import std.fs.*
import std.sync.AtomicInt64
import fountain::f_mq.base.model.MQTopicMeta
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_mq.base.model.MQSubscribeGroupMeta
import fountain::f_mq.base.payload.{MQMetaSnapshot, MQMetaTombstone, MQTopicAssignment}
import fountain::f_mq.base.MQProtocol
import fountain::fmq.test.TestDirs

@Test
class MetaStoreTest {
    private static func dirOf(name: String): String {
        TestDirs.of("meta_store", name)
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
            let tombstones = store.removeTopic("/t")
            // 主题墓碑在首位，随后级联每个组的墓碑（A35 的墓碑传播侧）
            @Assert(tombstones.size == 3)
            @Assert(tombstones[0].isTopic())
            let groupNames = ArrayList<String>()
            for (tombstone in tombstones[1..]) {
                @Assert(!tombstone.isTopic())
                groupNames.add(tombstone.subscribeGroup)
            }
            @Assert(groupNames.contains("g1"))
            @Assert(groupNames.contains("g2"))
            @Assert(store.topicOf("/t").isNone())
            @Assert(store.groupsOf("/t").size == 0)
            @Assert(!store.groupExists("/t", "g1"))
            @Assert(!exists("${dir}/topics/%2Ft.meta"))
            // 墓碑随快照下发：对端据此丢弃组，不必依赖组快照缺失兜底
            @Assert(store.snapshot().tombstones.size == 3)
            store.close()
        } finally {
            clean(dir)
        }
    }

    /** 磁盘上 owners 数量与队列数不符的条目不得进入索引，更不能随快照扩散（A34）。 */
    @TestCase
    public func loadTopicsSkipsInvalidAssignment(): Unit {
        let dir = dirOf("load_invalid")
        clean(dir)
        try {
            Directory.create("${dir}/topics", recursive: true)
            let bad = MQTopicAssignment("/bad", 2, 0, [0])
            let path = "${dir}/topics/${MQFileNames.escape("/bad")}.meta"
            let file = File.create(path)
            file.write(MQProtocol.encodePayload<MQTopicAssignment>(bad))
            file.close()

            let store = MetaStore(dir)
            store.load()
            @Assert(store.topicOf("/bad").isNone())
            @Assert(store.topics().size == 0)
            @Assert(store.snapshot().topics.size == 0)
            store.close()

            // 节点数已知时，owner 越界同样拒绝
            let good = MQTopicAssignment("/bad", 1, 0, [3])
            remove(path)
            let file2 = File.create(path)
            file2.write(MQProtocol.encodePayload<MQTopicAssignment>(good))
            file2.close()
            let sized = MetaStore(dir, nodeCount: 2)
            sized.load()
            @Assert(sized.topicOf("/bad").isNone())
            sized.close()
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
            let tombstone = store.removeTopic("/t")[0]
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
            let tombstone = store.removeTopic("/t")[0]
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
            store.applyTopic(MQTopicAssignment("/t", 1, 0, [0], revision: 4, origin: 9))
            // 墓碑更旧：输给活条目，零副作用（不写墓碑、不删条目）
            @Assert(store.applyTombstone(MQMetaTombstone(MQMetaTombstone.KIND_TOPIC, "/t", "", 3, 0, 0)) ==
                MetaApplyResult.Duplicated)
            @Assert(store.topicOf("/t").isSome())
            @Assert(store.allTombstones().size == 0)
            // 同 revision、更低 origin：同样输
            @Assert(store.applyTombstone(MQMetaTombstone(MQMetaTombstone.KIND_TOPIC, "/t", "", 4, 2, 0)) ==
                MetaApplyResult.Duplicated)
            @Assert(store.topicOf("/t").isSome())
            // 同 revision、更高 origin：墓碑胜出
            @Assert(store.applyTombstone(MQMetaTombstone(MQMetaTombstone.KIND_TOPIC, "/t", "", 4, 10, 0)) ==
                MetaApplyResult.Applied)
            @Assert(store.topicOf("/t").isNone())
            @Assert(store.allTombstones().size == 1)
            store.close()
        } finally {
            clean(dir)
        }
    }

    // ===== 墓碑参与接受判定（R2-S1） =====

    /** 墓碑按版本挡住迟到的主题分配：不落盘、不复活；更高版本才允许复活并回收墓碑。 */
    @TestCase
    public func tombstoneBlocksLateTopicAssignment(): Unit {
        let dir = dirOf("tombstone_late_topic")
        clean(dir)
        try {
            let store = MetaStore(dir)
            store.load()
            store.applyTombstone(MQMetaTombstone(MQMetaTombstone.KIND_TOPIC, "/t", "", 7, 0, 0))
            @Assert(store.applyTopic(MQTopicAssignment("/t", 1, 0, [0], revision: 2, origin: 1)) ==
                MetaApplyResult.Tombstoned)
            @Assert(store.topicOf("/t").isNone())
            @Assert(!exists("${dir}/${MQFileNames.topicFile("/t")}"))
            // 同 revision、更低 origin 也算输
            @Assert(store.applyTopic(MQTopicAssignment("/t", 1, 0, [0], revision: 7, origin: 0)) ==
                MetaApplyResult.Tombstoned)
            // 更高 revision 胜出：落盘并回收墓碑
            @Assert(store.applyTopic(MQTopicAssignment("/t", 1, 0, [0], revision: 8, origin: 0)) ==
                MetaApplyResult.Applied)
            @Assert(store.topicOf("/t").isSome())
            @Assert(store.topicTombstone("/t").isNone())
            @Assert(store.allTombstones().size == 0)
            store.close()
        } finally {
            clean(dir)
        }
    }

    /** 组墓碑同样挡住迟到组：`groupExists` 保持为假。 */
    @TestCase
    public func tombstoneBlocksLateGroup(): Unit {
        let dir = dirOf("tombstone_late_group")
        clean(dir)
        try {
            let store = MetaStore(dir)
            store.load()
            store.applyTopic(MQTopicAssignment("/t", 1, 0, [0], revision: 1))
            store.applyTombstone(MQMetaTombstone(MQMetaTombstone.KIND_GROUP, "/t", "g", 7, 0, 0))
            @Assert(store.applyGroup(MQSubscribeGroupMeta("/t", "g", revision: 2, origin: 1)) ==
                MetaApplyResult.Tombstoned)
            @Assert(!store.groupExists("/t", "g"))
            // 更高版本可以重新恢复
            @Assert(store.applyGroup(MQSubscribeGroupMeta("/t", "g", revision: 8, origin: 1)) ==
                MetaApplyResult.Applied)
            @Assert(store.groupExists("/t", "g"))
            @Assert(store.allTombstones().size == 0)
            store.close()
        } finally {
            clean(dir)
        }
    }

    // ===== 墓碑删除判定（R2-S2） =====

    /** 墓碑输给「同 revision、更高 origin」的活条目：不写墓碑、不删条目、不留副作用。 */
    @TestCase
    public func tombstoneLosingToLiveEntryHasNoSideEffects(): Unit {
        let dir = dirOf("tombstone_lose")
        clean(dir)
        try {
            let store = MetaStore(dir)
            store.load()
            store.applyTopic(MQTopicAssignment("/t", 1, 0, [0], revision: 5, origin: 9))
            store.applyGroup(MQSubscribeGroupMeta("/t", "g", revision: 5, origin: 9))
            @Assert(store.applyTombstone(MQMetaTombstone(MQMetaTombstone.KIND_GROUP, "/t", "g", 5, 2, 0)) ==
                MetaApplyResult.Duplicated)
            @Assert(store.groupExists("/t", "g"))
            // 输掉的墓碑不得落盘：否则会挡住后续 revision 介于两者之间的条目
            @Assert(store.allTombstones().size == 0)
            @Assert(!exists("${dir}/tombstones/g_%2Ft_g.meta"))
            store.close()
        } finally {
            clean(dir)
        }
    }

    /** 墓碑 revision 更高时删除活条目并落盘。 */
    @TestCase
    public func newerTombstoneRemovesLiveEntry(): Unit {
        let dir = dirOf("tombstone_win")
        clean(dir)
        try {
            let store = MetaStore(dir)
            store.load()
            store.applyTopic(MQTopicAssignment("/t", 1, 0, [0], revision: 4, origin: 9))
            store.applyGroup(MQSubscribeGroupMeta("/t", "g", revision: 4, origin: 9))
            @Assert(store.applyTombstone(MQMetaTombstone(MQMetaTombstone.KIND_GROUP, "/t", "g", 5, 2, 0)) ==
                MetaApplyResult.Applied)
            @Assert(!store.groupExists("/t", "g"))
            @Assert(store.allTombstones().size == 1)
            // 重复到达：已被同 key 墓碑挡住
            @Assert(store.applyTombstone(MQMetaTombstone(MQMetaTombstone.KIND_GROUP, "/t", "g", 5, 2, 0)) ==
                MetaApplyResult.Duplicated)
            store.close()
        } finally {
            clean(dir)
        }
    }

    /** 主题墓碑胜出时级联删除该主题下的组，包括 revision 更高的组（主题已不存在）。 */
    @TestCase
    public func topicTombstoneCascadesAllGroups(): Unit {
        let dir = dirOf("tombstone_cascade_groups")
        clean(dir)
        try {
            let store = MetaStore(dir)
            store.load()
            store.applyTopic(MQTopicAssignment("/t", 1, 0, [0], revision: 4, origin: 0))
            store.applyGroup(MQSubscribeGroupMeta("/t", "old", revision: 3, origin: 0))
            store.applyGroup(MQSubscribeGroupMeta("/t", "new", revision: 9, origin: 0))
            @Assert(store.applyTombstone(MQMetaTombstone(MQMetaTombstone.KIND_TOPIC, "/t", "", 5, 0, 0)) ==
                MetaApplyResult.Applied)
            @Assert(store.topicOf("/t").isNone())
            @Assert(!store.groupExists("/t", "old"))
            @Assert(!store.groupExists("/t", "new"))
            @Assert(store.groupsOf("/t").size == 0)
            store.close()
        } finally {
            clean(dir)
        }
    }

    // ===== 注册的检查-执行原子化（A28） =====

    @TestCase
    public func concurrentRegisterTopicOnlyOneWins(): Unit {
        let dir = dirOf("atomic_register")
        clean(dir)
        try {
            let store = MetaStore(dir)
            store.load()
            let results = Array<Int64>(8, repeat: -1)
            let done = AtomicInt64(0)
            for (i in 0..8) {
                spawn {
                    let (result, _) = store.registerTopic(MQTopicMeta("/t", 4), 3)
                    results[i] = if (result == MetaApplyResult.Applied) {1} else {0}
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
            for (value in results) {
                if (value == 1) {
                    applied++
                }
            }
            @Assert(applied == 1)
            @Assert(store.topicOf("/t").getOrThrow().queueNum == 4)
            store.close()
        } finally {
            clean(dir)
        }
    }

    @TestCase
    public func concurrentDifferentTopicsGetDifferentStarts(): Unit {
        let dir = dirOf("atomic_register_starts")
        clean(dir)
        try {
            let store = MetaStore(dir)
            store.load()
            let starts = Array<Int64>(2, repeat: -1)
            let done = AtomicInt64(0)
            spawn {
                let (_, assignment) = store.registerTopic(MQTopicMeta("/a", 2), 3)
                starts[0] = assignment.getOrThrow().startNodeIndex
                done.fetchAdd(1)
            }
            spawn {
                let (_, assignment) = store.registerTopic(MQTopicMeta("/b", 2), 3)
                starts[1] = assignment.getOrThrow().startNodeIndex
                done.fetchAdd(1)
            }
            var waited = 0
            while (done.load() < 2 && waited < 3000) {
                sleep(Duration.millisecond * 1)
                waited++
            }
            @Assert(done.load() == 2)
            @Assert(starts[0] != starts[1])
            // 指针等于「最后注册的起点 + queueNum」，与到达顺序无关
            let next = store.nextStartNode
            @Assert(next == (starts[0] + 2) % 3 || next == (starts[1] + 2) % 3)
        } finally {
            clean(dir)
        }
    }

    @TestCase
    public func registerGroupRequiresTopicAndIsAtomic(): Unit {
        let dir = dirOf("atomic_group")
        clean(dir)
        try {
            let store = MetaStore(dir)
            store.load()
            @Assert(store.registerGroup(MQSubscribeGroupMeta("/t", "g")) == MetaApplyResult.TopicMissing)
            @Assert(store.registerTopic(MQTopicMeta("/t", 1), 1)[0] == MetaApplyResult.Applied)
            @Assert(store.registerGroup(MQSubscribeGroupMeta("/t", "g")) == MetaApplyResult.Applied)
            @Assert(store.registerGroup(MQSubscribeGroupMeta("/t", "g")) == MetaApplyResult.Duplicated)
            store.close()
        } finally {
            clean(dir)
        }
    }

    // ===== 删除顺序与孤儿组（A35/A36） =====

    @TestCase
    public func orphanGroupsAreDroppedOnLoad(): Unit {
        let dir = dirOf("orphan")
        clean(dir)
        try {
            let store = MetaStore(dir)
            store.load()
            store.applyTopic(MQTopicAssignment("/t", 1, 0, [0], revision: 1))
            store.applyGroup(MQSubscribeGroupMeta("/t", "g1", revision: 2))
            store.applyGroup(MQSubscribeGroupMeta("/t", "g2", revision: 3))
            store.close()

            // 模拟「删除中断」：主题文件已删、组文件残留
            let topicFile = "${dir}/${MQFileNames.topicFile("/t")}"
            remove(topicFile)

            let reloaded = MetaStore(dir)
            reloaded.load()
            @Assert(reloaded.topicOf("/t").isNone())
            @Assert(!reloaded.groupExists("/t", "g1"))
            @Assert(!reloaded.groupExists("/t", "g2"))
            @Assert(reloaded.snapshot().groups.size == 0)
            reloaded.close()
        } finally {
            clean(dir)
        }
    }

    @TestCase
    public func removeTopicDeletesGroupsBeforeTopicFile(): Unit {
        let dir = dirOf("delete_order")
        clean(dir)
        try {
            let store = MetaStore(dir)
            store.load()
            store.applyTopic(MQTopicAssignment("/t", 1, 0, [0], revision: 1))
            store.applyGroup(MQSubscribeGroupMeta("/t", "g", revision: 2))
            let tombstone = store.removeTopic("/t")[0]
            @Assert(tombstone.isTopic())
            @Assert(store.topicOf("/t").isNone())
            @Assert(!store.groupExists("/t", "g"))
            // 组目录已随主题一起删除
            @Assert(!exists("${dir}/groups/${MQFileNames.escape("/t")}"))
            store.close()
        } finally {
            clean(dir)
        }
    }

    // ===== 台账补齐（A42） =====

    /** 只删一个组：其它组与主题保留，重载后状态一致。 */
    @TestCase
    public func removeGroupKeepsOtherGroups(): Unit {
        let dir = dirOf("remove_group")
        clean(dir)
        try {
            let store = MetaStore(dir)
            store.load()
            store.applyTopic(MQTopicAssignment("/t", 1, 0, [0], revision: 1))
            store.applyGroup(MQSubscribeGroupMeta("/t", "g1", revision: 2))
            store.applyGroup(MQSubscribeGroupMeta("/t", "g2", revision: 3))
            let tombstone = store.removeGroup("/t", "g1").getOrThrow()
            @Assert(!tombstone.isTopic())
            @Assert(!store.groupExists("/t", "g1"))
            @Assert(store.groupExists("/t", "g2"))
            @Assert(!exists("${dir}/groups/${MQFileNames.escape("/t")}/${MQFileNames.escape("g1")}.meta"))
            let reloaded = MetaStore(dir)
            reloaded.load()
            @Assert(!reloaded.groupExists("/t", "g1"))
            @Assert(reloaded.groupExists("/t", "g2"))
            reloaded.close()
            store.close()
        } finally {
            clean(dir)
        }
    }

    /** 删除不存在的主题/组返回 `None`，不产生墓碑（A42）。 */
    @TestCase
    public func removingMissingEntriesReturnsNone(): Unit {
        let dir = dirOf("remove_missing")
        clean(dir)
        try {
            let store = MetaStore(dir)
            store.load()
            @Assert(store.removeTopic("/missing").size == 0)
            @Assert(store.removeGroup("/missing", "g").isNone())
            store.applyTopic(MQTopicAssignment("/t", 1, 0, [0], revision: 1))
            @Assert(store.removeGroup("/t", "missing").isNone())
            @Assert(store.allTombstones().size == 0)
            store.close()
        } finally {
            clean(dir)
        }
    }

    /** 坏的 `assign.meta` 不阻断启动，轮转指针从 0 重新起步（A42）。 */
    @TestCase
    public func corruptedAssignMetaFallsBackToZero(): Unit {
        let dir = dirOf("bad_assign")
        clean(dir)
        try {
            Directory.create(dir, recursive: true)
            let junk = File.create("${dir}/assign.meta")
            junk.write([0xFFu8, 0x00u8, 0xABu8])
            junk.close()
            let store = MetaStore(dir)
            store.load()
            @Assert(store.nextStartNode == 0)
            let (result, maybeAssignment) = store.registerTopic(MQTopicMeta("/t", 1), 1)
            @Assert(result == MetaApplyResult.Applied)
            @Assert(maybeAssignment.getOrThrow().startNodeIndex == 0)
            store.close()
        } finally {
            clean(dir)
        }
    }

    /** 坏组文件与孤儿组都不进入索引（A42）。 */
    @TestCase
    public func corruptedAndOrphanGroupsAreNotIndexed(): Unit {
        let dir = dirOf("bad_groups")
        clean(dir)
        try {
            let store = MetaStore(dir)
            store.load()
            store.applyTopic(MQTopicAssignment("/t", 1, 0, [0], revision: 1))
            store.close()

            let groupDir = "${dir}/groups/${MQFileNames.escape("/t")}"
            Directory.create(groupDir, recursive: true)
            let junk = File.create("${groupDir}/broken.meta")
            junk.write([0xFFu8, 0xFEu8])
            junk.close()
            // 主题文件不存在的组：加载时丢弃
            let orphanDir = "${dir}/groups/${MQFileNames.escape("/gone")}"
            Directory.create(orphanDir, recursive: true)
            let orphan = File.create("${orphanDir}/${MQFileNames.escape("g")}.meta")
            orphan.write(MQProtocol.encodePayload<MQSubscribeGroupMeta>(
                MQSubscribeGroupMeta("/gone", "g", revision: 2)))
            orphan.close()

            let reloaded = MetaStore(dir)
            reloaded.load()
            @Assert(reloaded.groupsOf("/t").size == 0)
            @Assert(reloaded.groupsOf("/gone").size == 0)
            @Assert(reloaded.snapshot().groups.size == 0)
            reloaded.close()
        } finally {
            clean(dir)
        }
    }
}
