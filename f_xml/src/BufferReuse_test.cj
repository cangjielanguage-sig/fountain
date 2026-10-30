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
import fountain::f_base.StringGenerator
import fountain::f_base.UnsafeBytes

/**
 * 复用缓冲与事件侧容器复用：不串内容、不产生跨事件别名、交付数组按长度精确分配。
 */
@Test
public class BufferReuse_test {
    private func pullEvents(text: String, options!: XmlParserOptions = XmlParserOptions()): Array<XmlEvent> {
        let parser = XmlPullParser(TextInputStream(text), options: options)
        let out = ArrayList<XmlEvent>()
        while (true) {
            match (parser.nextEvent()) {
                case Some(event) => out.add(event)
                case None => break
            }
        }
        out.toArray()
    }

    private func lexerOf(text: String, bufSize!: Int64 = 8192): Lexer {
        Lexer(LineWindow(Utf8RuneSource(TextInputStream(text), bufSize: bufSize)))
    }

    /** 相邻元素的名字 / 属性值 / 文本互不串内容。 */
    @TestCase
    public func consecutiveTokensDoNotLeak(): Unit {
        let events = this.pullEvents("<r><a x=\"1\">t1</a><b y=\"2\">t2</b></r>")
        let texts = ArrayList<String>()
        let values = ArrayList<String>()
        for (event in events) {
            match (event) {
                case XmlEvent.Text(v) => texts.add(v)
                case XmlEvent.StartElement(_, attrs, _) =>
                    for (attr in attrs) {
                        values.add("${attr.name}=${attr.value}")
                    }
                case _ => ()
            }
        }
        assertTrue(texts.size == 2 && texts[0] == "t1" && texts[1] == "t2", "文本串了：${texts}")
        assertTrue(
            values.size == 2 && values[0] == "x=1" && values[1] == "y=2",
            "属性值串了：${values}"
        )
    }

    /** 名字与值交替 1000 次，每次结果与单次解析一致。 */
    @TestCase
    public func alternatingNamesAndValues(): Unit {
        let count: Int64 = 1000
        var doc = "<root>"
        var i: Int64 = 0
        while (i < count) {
            doc += "<e v=\"${i}\">t${i}</e>"
            i++
        }
        doc += "</root>"
        let events = this.pullEvents(doc)
        var seen: Int64 = 0
        var expectText = false
        for (event in events) {
            match (event) {
                case XmlEvent.StartElement(name, attrs, _) =>
                    if (name.local == "e") {
                        assertTrue(attrs.size == 1, "第 ${seen} 个元素应有 1 个属性")
                        assertTrue(attrs[0].name.local == "v", "属性名应为 v")
                        assertTrue(attrs[0].value == "${seen}", "第 ${seen} 个值应为 ${seen}，实际 ${attrs[0].value}")
                        expectText = true
                    }
                case XmlEvent.Text(v) =>
                    if (expectText) {
                        assertTrue(v == "t${seen}", "第 ${seen} 段文本应为 t${seen}，实际 ${v}")
                        expectText = false
                        seen++
                    }
                case _ => ()
            }
        }
        assertTrue(seen == count, "应解析 ${count} 个元素，实际 ${seen}")
    }

    private func scratchIdsOf(lexer: Lexer): Array<Int64> {
        [lexer.nameScratchId, lexer.valueScratchId, lexer.textScratchId]
    }

    /** 复用缓冲实例数恒定：同一次解析内消费任意多 token，三条缓冲仍是同一实例。 */
    @TestCase
    public func scratchInstancesStayConstant(): Unit {
        let small = this.lexerOf("<a x=\"1\">t</a>")
        let before = scratchIdsOf(small)
        var tokens: Int64 = 0
        while (true) {
            let token = small.nextToken(ParserState.Content)
            tokens++
            match (token) {
                case Token.TEof => break
                case _ => ()
            }
        }
        let after = scratchIdsOf(small)
        assertTrue(tokens > 1, "应切出多个 token")
        assertTrue(before.size == 3, "复用缓冲应为 3 条，实际 ${before.size}")
        for (i in 0..3) {
            assertTrue(before[i] == after[i], "第 ${i} 条缓冲在解析期间被换掉了")
        }

        var doc = "<root>"
        var i: Int64 = 0
        while (i < 200) {
            doc += "<e v=\"${i}\">t${i}</e>"
            i++
        }
        doc += "</root>"
        let large = this.lexerOf(doc)
        let largeBefore = scratchIdsOf(large)
        while (true) {
            match (large.nextToken(ParserState.Content)) {
                case Token.TEof => break
                case _ => ()
            }
        }
        let largeAfter = scratchIdsOf(large)
        for (i in 0..3) {
            assertTrue(largeBefore[i] == largeAfter[i], "长文档里第 ${i} 条缓冲被换掉了")
        }
    }

    /** 已交付的 `StartElement` 在后续 `nextEvent()` 之后仍然完整（无跨事件别名）。 */
    @TestCase
    public func deliveredEventIsNotAliased(): Unit {
        let parser = XmlPullParser(text: "<a x=\"1\" y=\"2\"><b/></a>", options: XmlParserOptions())
        var saved: ?XmlEvent = None
        while (true) {
            match (parser.nextEvent()) {
                case Some(event) =>
                    match (event) {
                        case XmlEvent.StartElement(name, _, _) =>
                            if (name.local == "a" && saved.isNone()) {
                                saved = Some(event)
                            }
                        case _ => ()
                    }
                case None => break
            }
        }
        match (saved) {
            case Some(event) =>
                match (event) {
                    case XmlEvent.StartElement(_, attrs, _) =>
                        assertTrue(attrs.size == 2, "保存的事件应有 2 个属性，实际 ${attrs.size}")
                        assertTrue(attrs[0].value == "1" && attrs[1].value == "2", "属性值被后续事件改写")
                    case _ => assertTrue(false, "保存的事件不是 StartElement")
                }
            case None => assertTrue(false, "未取到 <a> 的 StartElement")
        }
    }

    /** 交付数组长度 == 属性个数（0 / 1 / 5）。 */
    @TestCase
    public func attributeArrayLengthIsExact(): Unit {
        let specs: Array<(String, Int64)> = [
            ("", 0), (" x=\"1\"", 1), (" a=\"1\" b=\"2\" c=\"3\" d=\"4\" e=\"5\"", 5)
        ]
        for (spec in specs) {
            let events = this.pullEvents("<r${spec[0]}/>")
            for (event in events) {
                match (event) {
                    case XmlEvent.StartElement(_, attrs, _) =>
                        assertTrue(attrs.size == spec[1], "属性数应为 ${spec[1]}，实际 ${attrs.size}")
                    case _ => ()
                }
            }
        }
    }

    /** 重复属性：消息与位置不变。 */
    @TestCase
    public func duplicateAttributeErrorUnchanged(): Unit {
        let error = assertXmlError({=> this.pullEvents("<a x=\"1\" x=\"2\"/>")}, "重复的属性「x」")
        assertTrue(error.line == 1 && error.column == 10, "位置应为 1:10，实际 ${error.line}:${error.column}")
    }

    /** 属性值长度上限：消息与位置不变。 */
    @TestCase
    public func attributeLengthLimitErrorUnchanged(): Unit {
        let options = XmlParserOptions(maxAttributeValueLength: 4)
        let error = assertXmlError({=> this.pullEvents("<a x=\"12345\"/>", options: options)}, "超过上限 4")
        assertTrue(error.line == 1 && error.column == 4, "位置应为 1:4，实际 ${error.line}:${error.column}")
    }

    /** `ByteScratch` 与 `StringGenerator` 逐字节一致（含非 ASCII 与边界长度）。 */
    @TestCase
    public func byteScratchMatchesStringGenerator(): Unit {
        let samples = ["", "a", "item", "日本:語", "a\u{0300}", "x\ty\nz", "𠀀"]
        for (sample in samples) {
            let scratch = ByteScratch()
            let generator = StringGenerator()
            for (r in sample.runes()) {
                scratch.putCp(r.position())
                generator.append(r)
            }
            let expected = generator.toString().unsafeBytes()
            assertTrue(Int64(expected.size) == scratch.size, "字节数不同：${scratch.size} vs ${expected.size}")
            let actual = scratch.toUtf8String().unsafeBytes()
            for (i in 0..expected.size) {
                assertTrue(actual[i] == expected[i], "第 ${i} 字节不同（样本「${sample}」）")
            }
        }
    }
}
