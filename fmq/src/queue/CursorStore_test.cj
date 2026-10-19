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
import std.sync.AtomicInt64
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_io.LogPosition
import fountain::fmq.meta.MQFileNames

@Test
class CursorStoreTest {
    private static func rootOf(name: String): String {
        "/tmp/fmq_test_cursor_store/${name}"
    }

    private static func clean(root: String): Unit {
        if (exists(root)) {
            remove(root, recursive: true)
        }
    }

    private static func countTmp(root: String): Int64 {
        if (!exists(root)) {
            return 0
        }
        let count = AtomicInt64(0)
        Directory.walk(root) {info: FileInfo =>
            if (!info.isDirectory() && info.name.endsWith(".tmp")) {
                count.fetchAdd(1)
            }
            true
        }
        count.load()
    }

    @TestCase
    public func saveAndLoadRoundtrip(): Unit {
        let root = rootOf("roundtrip")
        clean(root)
        try {
            let store = CursorStore(root)
            @Assert(store.load("/t", 0, "g").isNone())
            store.save("/t", 0, "g", LogPosition(7, 128))
            let loaded = store.load("/t", 0, "g").getOrThrow()
            @Assert(loaded.seq == 7)
            @Assert(loaded.offset == 128)
        } finally {
            clean(root)
        }
    }

    @TestCase
    public func overwriteHasNoTmpResidue(): Unit {
        let root = rootOf("overwrite")
        clean(root)
        try {
            let store = CursorStore(root)
            for (i in 0..1000) {
                store.save("/t", 2, "grp", LogPosition(1, i))
            }
            let loaded = store.load("/t", 2, "grp").getOrThrow()
            @Assert(loaded.seq == 1)
            @Assert(loaded.offset == 999)
            @Assert(countTmp(root) == 0)
        } finally {
            clean(root)
        }
    }

    @TestCase
    public func defaultGroupUsesEncodedName(): Unit {
        let root = rootOf("default_group")
        clean(root)
        try {
            let store = CursorStore(root)
            store.save("/t", 0, "", LogPosition(3, 4))
            let path = "${root}/${MQFileNames.cursorFile("/t", 0, "")}"
            @Assert(exists(path))
            @Assert(path.contains("%00.cursor"))
            @Assert(store.load("/t", 0, "").getOrThrow().seq == 3)
        } finally {
            clean(root)
        }
    }

    @TestCase
    public func removeAllOfDeletesWholeTopic(): Unit {
        let root = rootOf("remove_topic")
        clean(root)
        try {
            let store = CursorStore(root)
            store.save("/t", 0, "g1", LogPosition(1, 0))
            store.save("/t", 1, "g2", LogPosition(2, 0))
            @Assert(exists("${root}/offsets/%2Ft"))
            store.removeAllOf("/t")
            @Assert(!exists("${root}/offsets/%2Ft"))
            @Assert(store.load("/t", 0, "g1").isNone())
            // 其它主题不受影响
            store.save("/other", 0, "g", LogPosition(1, 1))
            store.removeAllOf("/t")
            @Assert(store.load("/other", 0, "g").isSome())
        } finally {
            clean(root)
        }
    }

    @TestCase
    public func removeGroupKeepsOtherGroups(): Unit {
        let root = rootOf("remove_group")
        clean(root)
        try {
            let store = CursorStore(root)
            store.save("/t", 0, "g1", LogPosition(1, 0))
            store.save("/t", 0, "g2", LogPosition(1, 1))
            store.save("/t", 1, "g1", LogPosition(1, 2))
            store.removeGroup("/t", "g1")
            @Assert(store.load("/t", 0, "g1").isNone())
            @Assert(store.load("/t", 1, "g1").isNone())
            @Assert(store.load("/t", 0, "g2").getOrThrow().offset == 1)
        } finally {
            clean(root)
        }
    }

    @TestCase
    public func corruptedFileReturnsNone(): Unit {
        let root = rootOf("corrupted")
        clean(root)
        try {
            let store = CursorStore(root)
            let path = "${root}/${MQFileNames.cursorFile("/t", 0, "g")}"
            let parent = Path(path).parent
            Directory.create(parent, recursive: true)
            let file = File.create(path)
            file.write([0xFFu8, 0xFEu8])
            file.close()
            @Assert(store.load("/t", 0, "g").isNone())
        } finally {
            clean(root)
        }
    }
}
