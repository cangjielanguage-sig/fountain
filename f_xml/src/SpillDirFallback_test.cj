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
package fountain::f_xml

import std.unittest.*
import std.unittest.testmacro.*
import std.collection.ArrayList
import std.env
import std.fs.{Directory, File, Path, exists, removeIfExists}

@Test
public class SpillDirFallback_test {
    /** 造一个「已存在的普通文件」，返回它的路径；四个这样的候选能让四级尝试全部失败。 */
    private func plainFile(dir: Path): Path {
        let file = File.createTemp(dir)
        let path = file.info.path
        file.close()
        path
    }

    /** 四级全失败：候选都是普通文件（含回落点）→ 抛 XmlException，不创建任何目录、不降级回内存。 */
    @TestCase
    public func allFourCandidatesFail(): Unit {
        let dir = Directory.createTemp(env.getTempDirectory())
        let fallbackDir = SpillDir.fallbackDirectory()
        let hadFallback = exists(fallbackDir)
        try {
            let candidates = ArrayList<Path>()
            for (_ in 0..4) {
                candidates.add(this.plainFile(dir))
            }
            let fallback = candidates[candidates.size - 1]
            let error = assertXmlError({=> let _ = SpillDir.createFileFrom(candidates, fallback) }, "spillDir")
            assertTrue(error.message.contains("spillDir"), "消息应含 spillDir：「${error.message}」")
            assertTrue(exists(fallbackDir) == hadFallback, "不应产生 .fountain_tmp 目录")

            let sink = ExpandSink(
                EntityLimits(maxExpandedPerEntity: 4, overflowPolicy: EntityOverflowPolicy.Spill),
                EntityCounter(),
                spillHook: Some({=> SpillDir.createFileFrom(candidates, fallback)})
            )
            assertXmlError({=> sink.write("123456789")}, "spillDir")
            assertTrue(!sink.isSpilled(), "四级全失败后不应降级回内存（isSpilled 必须为 false）")
            assertTrue(sink.size() == 0, "失败时不应把数据写入内存")
            sink.close()
        } finally {
            removeIfExists(dir, recursive: true)
        }
    }

    /** 非回落候选缺失时被跳过，文件落在下一个可用目录。 */
    @TestCase
    public func missingNonFallbackCandidateIsSkipped(): Unit {
        let dir = Directory.createTemp(env.getTempDirectory())
        try {
            let missing = dir.join("missing-first-candidate")
            let candidates = ArrayList<Path>()
            candidates.add(missing)
            candidates.add(dir)
            let fallback = dir.join("never-created")
            let file = SpillDir.createFileFrom(candidates, fallback)
            let path = file.info.path
            file.write("x".toArray())
            file.close()
            assertTrue(!exists(missing), "缺失的非回落候选不应被创建")
            assertTrue(!exists(fallback), "回落点不在候选里时不应被创建")
            assertTrue(path.toString().contains(dir.toString()), "文件应落在可用目录，实际 ${path}")
            removeIfExists(path)
        } finally {
            removeIfExists(dir, recursive: true)
        }
    }

    /** 回落目录缺失时被创建，文件可用。 */
    @TestCase
    public func missingFallbackDirectoryIsCreated(): Unit {
        let dir = Directory.createTemp(env.getTempDirectory())
        try {
            let fallback = dir.join("nested").join(".fountain_tmp")
            let candidates = ArrayList<Path>()
            candidates.add(dir.join("missing-first"))
            candidates.add(fallback)
            let file = SpillDir.createFileFrom(candidates, fallback)
            let path = file.info.path
            file.write("y".toArray())
            file.close()
            assertTrue(exists(fallback), "回落目录应被创建")
            removeIfExists(path)
            removeIfExists(fallback)
        } finally {
            removeIfExists(dir, recursive: true)
        }
    }

    /** 成功路径回归：候选可用时直接在其中建文件。 */
    @TestCase
    public func successPathUnchanged(): Unit {
        let dir = Directory.createTemp(env.getTempDirectory())
        try {
            let candidates = ArrayList<Path>()
            candidates.add(dir)
            let file = SpillDir.createFileFrom(candidates, dir.join("unused"))
            let path = file.info.path
            file.close()
            assertTrue(path.toString().contains(dir.toString()), "文件应落在候选目录，实际 ${path}")
            removeIfExists(path)
        } finally {
            removeIfExists(dir, recursive: true)
        }
    }
}
