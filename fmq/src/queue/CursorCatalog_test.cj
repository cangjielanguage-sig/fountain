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
package fountain::fmq.queue

import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_mq.base.payload.MQTopicAssignment
import fountain::f_io.LogPosition
import fountain::f_mq.base.model.MQSubscribeGroupMeta
import fountain::fmq.meta.{MQFileNames, MetaApplyResult, MetaStore}
import fountain::fmq.test.TestDirs

/**
 * 段保留边界（A44）。
 *
 * 段 TTL 必须以**全部已注册组**的位点为边界：离线组只有磁盘位点，按内存游标删段
 * 会把慢组积压直接删掉。
 */
@Test
class CursorCatalogTest {
    /** 进程不再注册 `atExit`，整个类的临时目录在收尾时统一回收。 */
    @AfterAll
    static func removeTempDirs(): Unit {
        TestDirs.cleanNamespace("cursor_catalog")
    }

    private let root = TestDirs.of("cursor_catalog", "root")

    private func freshDir(name: String): String {
        TestDirs.of("cursor_catalog", name)
    }

    private static func clean(dir: String): Unit {
        if (exists(dir)) {
            remove(dir, recursive: true)
        }
    }

    @TestCase
    public func floorIsOneWhenGroupNeverConsumed(): Unit {
        let dir = freshDir("never")
        let meta = MetaStore("${dir}/metas")
        meta.load()
        meta.applyTopic(MQTopicAssignment("/t", 1, 0, [0]))
        let store = CursorStore("${dir}/metas")
        try {
            @Assert(meta.applyGroup(MQSubscribeGroupMeta("/t", "g")) == MetaApplyResult.Applied)
            let catalog = CursorCatalog(store, meta)
            // 无位点文件：视为从头开始
            @Assert(catalog.floorOf("/t", 0) == 1)
            // 无任何组：没有读者需要历史段
            @Assert(catalog.floorOf("/unknown", 0) == Int64.Max)
        } finally {
            meta.close()
            clean(dir)
        }
    }

    @TestCase
    public func floorUsesDurablePositionOfOfflineGroup(): Unit {
        let dir = freshDir("offline")
        let meta = MetaStore("${dir}/metas")
        meta.load()
        meta.applyTopic(MQTopicAssignment("/t", 1, 0, [0]))
        let store = CursorStore("${dir}/metas")
        try {
            @Assert(meta.applyGroup(MQSubscribeGroupMeta("/t", "g")) == MetaApplyResult.Applied)
            // 模拟「上一个进程消费到段 3 后停机」：只有磁盘位点，没有内存游标
            store.save("/t", 0, "g", LogPosition(3, 0))
            let catalog = CursorCatalog(store, meta)
            @Assert(catalog.floorOf("/t", 0) == 3)
        } finally {
            meta.close()
            clean(dir)
        }
    }

    @TestCase
    public func floorTakesMinimumAcrossGroups(): Unit {
        let dir = freshDir("multi")
        let meta = MetaStore("${dir}/metas")
        meta.load()
        meta.applyTopic(MQTopicAssignment("/t", 1, 0, [0]))
        let store = CursorStore("${dir}/metas")
        try {
            @Assert(meta.applyGroup(MQSubscribeGroupMeta("/t", "fast")) == MetaApplyResult.Applied)
            @Assert(meta.applyGroup(MQSubscribeGroupMeta("/t", "slow")) == MetaApplyResult.Applied)
            store.save("/t", 0, "fast", LogPosition(9, 0))
            store.save("/t", 0, "slow", LogPosition(2, 8))
            let catalog = CursorCatalog(store, meta)
            @Assert(catalog.floorOf("/t", 0) == 2)
        } finally {
            meta.close()
            clean(dir)
        }
    }

    @TestCase
    public func corruptCursorIsTreatedAsMissing(): Unit {
        let dir = freshDir("corrupt")
        let meta = MetaStore("${dir}/metas")
        meta.load()
        meta.applyTopic(MQTopicAssignment("/t", 1, 0, [0]))
        let store = CursorStore("${dir}/metas")
        try {
            @Assert(meta.applyGroup(MQSubscribeGroupMeta("/t", "g")) == MetaApplyResult.Applied)
            let path = "${dir}/metas/offsets/${MQFileNames.escape("/t")}/0/" +
                "${MQFileNames.escape("g")}.cursor"
            let parent = Path(path).parent
            Directory.create(parent, recursive: true)
            let file = File.create(path)
            file.write([0xFFu8, 0xFFu8, 0xFFu8])
            file.close()
            let catalog = CursorCatalog(store, meta)
            @Assert(catalog.floorOf("/t", 0) == 1)
        } finally {
            meta.close()
            clean(dir)
        }
    }

    @TestCase
    public func removingGroupLiftsFloor(): Unit {
        let dir = freshDir("remove_group")
        let meta = MetaStore("${dir}/metas")
        meta.load()
        meta.applyTopic(MQTopicAssignment("/t", 1, 0, [0]))
        let store = CursorStore("${dir}/metas")
        try {
            @Assert(meta.applyGroup(MQSubscribeGroupMeta("/t", "fast")) == MetaApplyResult.Applied)
            @Assert(meta.applyGroup(MQSubscribeGroupMeta("/t", "slow")) == MetaApplyResult.Applied)
            store.save("/t", 0, "fast", LogPosition(9, 0))
            store.save("/t", 0, "slow", LogPosition(2, 0))
            let catalog = CursorCatalog(store, meta)
            @Assert(catalog.floorOf("/t", 0) == 2)
            @Assert(meta.removeGroup("/t", "slow").isSome())
            @Assert(catalog.floorOf("/t", 0) == 9)
            catalog.removeGroup("/t", "slow")
            @Assert(catalog.positionOf("/t", 0, "slow").isNone())
        } finally {
            meta.close()
            clean(dir)
        }
    }
}
