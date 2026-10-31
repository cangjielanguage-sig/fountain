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
import std.fs.{exists, Path}
import std.env
import std.collection.ArrayList

@Test
public class Spill_test {
    private func spillLimits(maxPerEntity!: Int64 = 1024, maxTotal!: Int64 = 2048): EntityLimits {
        EntityLimits(
            maxExpandedPerEntity: maxPerEntity,
            maxExpandedTotal: maxTotal,
            overflowPolicy: EntityOverflowPolicy.Spill
        )
    }

    /** Spill 下 20 MB 展开成功，retainedBytes 不随展开量增长。 */
    @TestCase
    public func largeExpansionSpills(): Unit {
        let limits = this.spillLimits()
        let counter = EntityCounter()
        let sink = ExpandSink(limits, counter)
        let chunk = repeatText("abcdefghij", 64)
        var written: Int64 = 0
        for (_ in 0..20480) {
            sink.write(chunk)
            written += 640
        }
        assertTrue(written == 13_107_200, "实际 ${written}")
        @Assert(sink.isSpilled())
        assertTrue(sink.retainedBytes() == 0, "溢出后内存侧应为 0")

        let readBack = sink.readAll(4096)
        assertTrue(Int64(readBack.size) == written, "读回 ${readBack.size} 应与写入 ${written} 一致")

        let path = sink.spillPath()
        sink.close()
        match (path) {
            case Some(p) => assertTrue(!exists(p), "溢出文件应被删除")
            case None => assertTrue(false, "应有溢出文件")
        }
    }

    /** 读回内容与内存路径逐字节一致。 */
    @TestCase
    public func readBackMatchesMemory(): Unit {
        let limits = this.spillLimits(maxPerEntity: 64, maxTotal: 128)
        let counter = EntityCounter()
        let sink = ExpandSink(limits, counter)
        let parts = ["中文", "abc", "😀", repeatText("x", 200)]
        for (part in parts) {
            sink.write(part)
        }
        @Assert(sink.isSpilled())
        let out = sink.readAll(7)
        let expected = StringBuilder()
        for (part in parts) {
            expected.append(part)
        }
        @Assert(out == expected.toString())
        sink.close()
    }

    /** Strict 下软阈值直接抛。 */
    @TestCase
    public func strictThrowsAtSoftThreshold(): Unit {
        let limits = EntityLimits(
            maxExpandedPerEntity: 64,
            maxExpandedTotal: 128,
            overflowPolicy: EntityOverflowPolicy.Strict
        )
        let sink = ExpandSink(limits, EntityCounter())
        let error = assertXmlError({=> sink.write(repeatText("x", 100))}, "单实体")
        @Assert(error.entityLimitKind == Some(EntityLimitKind.PerEntity))
        sink.close()
    }

    /** 显式 spillDir 优先。 */
    @TestCase
    public func explicitSpillDirFirst(): Unit {
        let dir = env.getWorkingDirectory().join(".fountain_tmp")
        let limits = EntityLimits(spillDir: Some(dir))
        let candidates = SpillDir.candidates(limits)
        @Assert(candidates.size >= 1)
        @Assert(candidates[0].toString() == dir.toString())
    }

    /** 溢出文件落在显式 spillDir 里。 */
    @TestCase
    public func spillFileInExplicitDir(): Unit {
        let dir = env.getWorkingDirectory().join(".fountain_tmp")
        let limits = EntityLimits(
            maxExpandedPerEntity: 16,
            maxExpandedTotal: 32,
            spillDir: Some(dir),
            overflowPolicy: EntityOverflowPolicy.Spill
        )
        let sink = ExpandSink(limits, EntityCounter())
        sink.write(repeatText("y", 100))
        @Assert(sink.isSpilled())
        let path = sink.spillPath().getOrThrow()
        @Assert(path.toString().startsWith(dir.toString()))
        sink.close()
        @Assert(!exists(path))
    }
}

@Test
public class XmlException_test {
    /** 三个构造器。 */
    @TestCase
    public func constructors(): Unit {
        let plain = XmlException("消息")
        @Assert(plain.line == 0 && plain.column == 0)
        @Assert(plain.entityLimitKind.isNone())
        @Assert(plain.message.contains("消息"))

        let positioned = XmlException("消息", 3, 17)
        @Assert(positioned.line == 3 && positioned.column == 17)
        @Assert(positioned.message.contains("第 3 行第 17 列"))

        let limited = XmlException("消息", 3, 17, kind: EntityLimitKind.Total)
        @Assert(limited.entityLimitKind == Some(EntityLimitKind.Total))
    }

    /** 六种分类都能用，且互不相等。 */
    @TestCase
    public func sixKinds(): Unit {
        let kinds = [
            EntityLimitKind.PerEntity, EntityLimitKind.Total, EntityLimitKind.Depth,
            EntityLimitKind.Declarations, EntityLimitKind.HardLimit, EntityLimitKind.AttributeValue
        ]
        for (i in 0..kinds.size) {
            for (j in 0..kinds.size) {
                @Assert((kinds[i] == kinds[j]) == (i == j))
            }
        }
    }

    /** 溢出读回块的填充只走 `nextCp()`：不再逐字符包 `Option`。 */
    @TestCase
    public func sinkFeedFillsThroughCodePoints(): Unit {
        let reader = CountingExpandReader("溢出内容 abc")
        let feed = SinkFeed(reader, SourcePosition(1, 1))
        let out = ArrayList<Int64>()
        while (true) {
            let cp = feed.advanceCp()
            if (cp < 0) {
                break
            }
            out.add(cp)
        }
        assertTrue(reader.nextCalls == 0, "填充不应调用 next()，实际调用 ${reader.nextCalls} 次")
        assertTrue(reader.nextCpCalls >= out.size, "nextCp() 调用 ${reader.nextCpCalls} 次，码点 ${out.size} 个")
        assertTrue(reader.closed, "读到 EOF 后应关闭读回器")
    }
}

/** 统计 `next()` / `nextCp()` 调用的读回器。 */
internal class CountingExpandReader <: ExpandReader {
    private let cps: Array<Int32>
    private var pos: Int64 = 0
    var nextCalls: Int64 = 0
    var nextCpCalls: Int64 = 0
    var closed: Bool = false

    init(text: String) {
        let source = cpsOf(text)
        let converted = Array<Int32>(source.size, repeat: 0)
        for (i in 0..source.size) {
            converted[i] = Int32(source[i])
        }
        this.cps = converted
    }

    public func nextCp(): Int64 {
        this.nextCpCalls++
        if (this.pos >= this.cps.size) {
            return -1
        }
        let cp = Int64(this.cps[this.pos])
        this.pos++
        cp
    }

    public func next(): ?Rune {
        this.nextCalls++
        let cp = this.nextCp()
        if (cp < 0) {
            None
        } else {
            Some(Rune(cp))
        }
    }

    public func close(): Unit {
        this.closed = true
    }
}
