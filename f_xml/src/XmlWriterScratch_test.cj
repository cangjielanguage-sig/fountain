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

import std.collection.ArrayList
import std.env.getVariable
import std.io.OutputStream
import std.runtime.{gc, getAllocatedHeapSize, getGCCount, getGCFreedSize}
import std.sync.AtomicInt64
import std.unittest.*
import std.unittest.testmacro.*
import cangjie_tpc::charset4cj.charset.Charsets
import fountain::f_base.StringGenerator

/** 丢弃内容、只累计长度的 sink：避免把输出复制开销算进基准。 */
private class DiscardSink <: OutputStream {
    var total: Int64 = 0

    public func write(buffer: Array<Byte>): Unit {
        this.total += buffer.size
    }

    public func flush(): Unit {}
}

/** 收集全部字节的 sink（行为用例用）。 */
private class ScratchSink <: OutputStream {
    private let sink = ArrayList<Byte>()

    public func write(buffer: Array<Byte>): Unit {
        this.sink.add(all: buffer)
    }

    public func flush(): Unit {}

    func bytes(): Array<Byte> {
        this.sink.toArray()
    }

    func text(): String {
        String.fromUtf8(this.sink.toArray())
    }
}

private func scratchBenchEnabled(): Bool {
    match (getVariable("F_XML_BENCH")) {
        case Some(v) => v == "1"
        case None => false
    }
}

private func scratchSettle(): Unit {
    for (_ in 0..3) {
        gc()
    }
}

/** 多次采样取最小值：GC 噪声只会抬高单次读数。 */
private func scratchMeasure(action: () -> Unit): (Int64, Int64) {
    let allocs = ArrayList<Int64>()
    var attempts = 0
    while (allocs.size < 5 && attempts < 20) {
        attempts++
        scratchSettle()
        let heap0 = getAllocatedHeapSize()
        let freed0 = getGCFreedSize()
        action()
        let alloc = (getAllocatedHeapSize() - heap0) + (getGCFreedSize() - freed0)
        if (alloc >= 0) {
            allocs.add(alloc)
        }
    }
    if (allocs.size == 0) {
        return (-1, 0)
    }
    var best = allocs[0]
    for (a in allocs) {
        if (a < best) {
            best = a
        }
    }
    (best, allocs.size)
}

@Test
public class XmlWriterScratch_test {
    /** 超过 16 KB 刷写门限的 UTF-8 文档：多段刷写后逐字节等于期望。 */
    @TestCase
    public func utf8MultiFlushMatchesExpected(): Unit {
        let sink = ScratchSink()
        let writer = XmlWriter(sink)
        writer.startElement(QName("r"))
        let expected = StringBuilder()
        expected.append("<r>")
        for (i in 0..1500) {
            writer.startElement(QName("i"))
            writer.text("汉字😀&<>")
            writer.endElement(QName("i"))
            expected.append("<i>汉字😀&amp;&lt;&gt;</i>")
        }
        writer.endElement(QName("r"))
        writer.close()
        expected.append("</r>")
        @Assert(expected.toString(), sink.text())
    }

    /** 属性值中的非 ASCII 与转义字符：输出保持既有规则。 */
    @TestCase
    public func nonAsciiAttributeEscaping(): Unit {
        let sink = ScratchSink()
        let writer = XmlWriter(sink)
        writer.startElement(QName("a"), attributes: [XmlAttribute(QName("v"), "中文\"&\r<>")])
        writer.text("中文😀")
        writer.endElement(QName("a"))
        writer.close()
        @Assert("<a v=\"中文&quot;&amp;&#13;&lt;&gt;\">中文😀</a>", sink.text())
    }

    /** CDATA 模式下的非 ASCII 与 `]]>` 拆分不变。 */
    @TestCase
    public func cdataSplitsNonAscii(): Unit {
        let sink = ScratchSink()
        let writer = XmlWriter(sink, options: XmlWriterOptions(cdata: CdataMode.Always))
        writer.startElement(QName("a"))
        writer.text("中]]>文😀")
        writer.endElement(QName("a"))
        writer.close()
        @Assert("<a><![CDATA[中]]]]><![CDATA[>文😀]]></a>", sink.text())
    }

    /** UTF-16LE 多段刷写：BOM 存在，去 BOM 后可解码回期望文本。 */
    @TestCase
    public func utf16leMultiFlushDecodes(): Unit {
        let sink = ScratchSink()
        let writer = XmlWriter(sink, options: XmlWriterOptions(charset: Charsets.UTF16LE))
        writer.startElement(QName("r"))
        let expected = StringBuilder()
        expected.append("<r>")
        for (i in 0..1200) {
            writer.startElement(QName("i"))
            writer.text("汉字😀")
            writer.endElement(QName("i"))
            expected.append("<i>汉字😀</i>")
        }
        writer.endElement(QName("r"))
        writer.close()
        expected.append("</r>")

        let bytes = sink.bytes()
        @Assert(bytes.size > 2)
        @Assert(bytes[0], 0xFFu8)
        @Assert(bytes[1], 0xFEu8)
        @Assert(expected.toString(), Charsets.UTF16LE.newDecoder().decode(bytes[2..]))
    }

    /** GBK 的不可映射字符仍按 Replace 策略写成 `?`。 */
    @TestCase
    public func gbkUnmappableStillReplaced(): Unit {
        let sink = ScratchSink()
        let writer = XmlWriter(sink, options: XmlWriterOptions(charset: Charsets.GBK, onInvalidChar: InvalidCharMode.Replace))
        writer.startElement(QName("a"))
        writer.text("中😀文")
        writer.endElement(QName("a"))
        writer.close()
        @Assert("<a>中?文</a>", Charsets.GBK.newDecoder().decode(sink.bytes()))
    }

    /**
     * 非 ASCII 追加基准：端到端写 20000 个汉字，对照 `StringGenerator.append(r)`。
     *
     * 断言：端到端 `<= 8 B/rune`，且基线总量高于端到端 8 倍。
     */
    @TestCase
    public func testBenchRuneAppendAllocation(): Unit {
        if (!scratchBenchEnabled()) {
            println("SKIP: 未设置 F_XML_BENCH=1，非 ASCII 追加基准不执行")
            return
        }
        let runes: Int64 = 20000
        let cjk = "中"
        let expectedText = StringBuilder()
        for (_ in 0..runes) {
            expectedText.append(cjk)
        }
        let content = expectedText.toString()
        let acc = AtomicInt64(0)

        let (writerAlloc, writerSamples) = scratchMeasure({ =>
            let sink = DiscardSink()
            let writer = XmlWriter(sink)
            writer.startElement(QName("a"))
            writer.text(content)
            writer.endElement(QName("a"))
            writer.close()
            acc.fetchAdd(sink.total)
        })

        let rune = Rune(0x4E2D)
        let (baseAlloc, baseSamples) = scratchMeasure({ =>
            let gen = StringGenerator()
            for (_ in 0..runes) {
                gen.append(rune)
            }
            acc.fetchAdd(gen.size)
        })

        let writerPerRune = writerAlloc / runes
        println('XML_WRITER_BENCH case=writer allocTotal=${writerAlloc} allocPerRune=${writerPerRune} ' +
            'samples=${writerSamples}')
        println('XML_WRITER_BENCH case=string_generator allocTotal=${baseAlloc} ' +
            'allocPerRune=${baseAlloc / runes} samples=${baseSamples}')
        @Assert(writerSamples > 0 && baseSamples > 0)
        @Assert(writerPerRune <= 8)
        @Assert(baseAlloc > writerAlloc * 8)
    }
}
