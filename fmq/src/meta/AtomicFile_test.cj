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
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_mq.base.payload.MQTopicAssignment

/** 原子写（A37/A51）：顺序、失败向上抛、无 `.tmp` 残留。 */
@Test
class AtomicFileTest {
    private static func dirOf(name: String): String {
        "/tmp/fmq_test_atomic_file/${name}"
    }

    private static func clean(dir: String): Unit {
        if (exists(dir)) {
            remove(dir, recursive: true)
        }
    }

    private static func countTmp(dir: String): Int64 {
        if (!exists(dir)) {
            return 0
        }
        let count = Array<Int64>(1, repeat: 0)
        Directory.walk(dir) {info: FileInfo =>
            if (!info.isDirectory() && info.name.endsWith(".tmp")) {
                count[0]++
            }
            true
        }
        count[0]
    }

    @TestCase
    public func writesInFsyncOrder(): Unit {
        let dir = dirOf("order")
        clean(dir)
        Directory.create(dir, recursive: true)
        let steps = ArrayList<String>()
        try {
            let atomic = AtomicFile(trace: {step => steps.add(step)})
            atomic.write("${dir}/a.meta", [1u8, 2u8, 3u8])
            let expected = ["create", "write", "fsync(file)", "close", "rename", "fsync(parent)"]
            @Assert(steps.size == expected.size)
            for (i in 0..expected.size) {
                @Assert(steps[i] == expected[i])
            }
            // 正式文件内容完整
            let file = File("${dir}/a.meta", OpenMode.Read)
            try {
                let bytes = Array<Byte>(3, repeat: 0u8)
                @Assert(file.read(bytes) == 3)
                @Assert(bytes == [1u8, 2u8, 3u8])
            } finally {
                file.close()
            }
        } finally {
            clean(dir)
        }
    }

    @TestCase
    public func fsyncFailurePropagates(): Unit {
        let dir = dirOf("failure")
        clean(dir)
        Directory.create(dir, recursive: true)
        try {
            let atomic = AtomicFile(trace: {step =>
                if (step == "fsync(file)") {
                    throw IllegalArgumentException("simulated fsync failure")
                }
            })
            var thrown = false
            try {
                atomic.write("${dir}/b.meta", [1u8])
            } catch (_: Exception) {
                thrown = true
            }
            @Assert(thrown)
            // 正式文件不应出现（只有可能残留 .tmp）
            @Assert(!exists("${dir}/b.meta"))
        } finally {
            clean(dir)
        }
    }

    @TestCase
    public func repeatedWritesLeaveNoTmpFiles(): Unit {
        let dir = dirOf("no_tmp")
        clean(dir)
        Directory.create(dir, recursive: true)
        try {
            let atomic = AtomicFile()
            for (i in 0..1000) {
                atomic.write("${dir}/c.meta", [UInt8(i % 251)])
            }
            @Assert(countTmp(dir) == 0)
            @Assert(exists("${dir}/c.meta"))
        } finally {
            clean(dir)
        }
    }

    /** 写入失败时 MetaStore 的内存索引不得前进。 */
    @TestCase
    public func metastoreKeepsMemoryWhenWriteFails(): Unit {
        let dir = dirOf("store_failure")
        clean(dir)
        Directory.create(dir, recursive: true)
        try {
            let store = MetaStore(dir)
            store.load()
            // 占位：让 rename 的目标是一个目录，写入必然失败
            let topicPath = "${dir}/${MQFileNames.topicFile("/t")}"
            Directory.create(Path(topicPath).parent, recursive: true)
            Directory.create(topicPath)
            var thrown = false
            try {
                store.applyTopic(MQTopicAssignment("/t", 1, 0, [0]))
            } catch (_: Exception) {
                thrown = true
            }
            @Assert(thrown)
            @Assert(store.topicOf("/t").isNone())
            store.close()
        } finally {
            clean(dir)
        }
    }
}
