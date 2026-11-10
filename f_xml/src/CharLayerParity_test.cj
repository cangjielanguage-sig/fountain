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
import std.io.InputStream

/**
 * 字符层等价性：同一份文档在不同 `bufSize` 与不同编码下必须产出完全相同的
 * 事件日志、文本与错误位置。块边界只能影响性能，不能影响语义。
 */
@Test
public class CharLayerParity_test {
    private static let sizes: Array<Int64> = [4, 8, 16, 64, 8192, 65536]

    private func eventLog(input: InputStream, bufSize: Int64, mode!: InvalidByteMode = InvalidByteMode.Strict): String {
        let parser = XmlPullParser(input, options: XmlParserOptions(bufSize: bufSize, onInvalidByte: mode))
        let out = ArrayList<String>()
        while (let Some(event) <- parser.nextEvent()) {
            out.add(event.toString())
        }
        joinLog(out.toArray())
    }

    private func assertSame(inputFactory: (Int64) -> InputStream, label: String, mode!: InvalidByteMode = InvalidByteMode.Strict): Unit {
        let base = this.eventLog(inputFactory(sizes[sizes.size - 1]), sizes[sizes.size - 1], mode: mode)
        for (size in sizes) {
            let actual = this.eventLog(inputFactory(size), size, mode: mode)
            assertTrue(actual == base, "${label} 在 bufSize=${size} 下事件日志不同：\n${actual}\n--- 期望 ---\n${base}")
        }
    }

    /** UTF-8 strict：含 2/3/4 字节字符与属性。 */
    @TestCase
    public func utf8StrictAcrossBufSizes(): Unit {
        let bytes = "<r a=\"中文\" b=\"😀\">x<b/>中文😀</r>".toArray()
        this.assertSame({size => MemoryInputStream(bytes)}, "utf8-strict")
    }

    /** UTF-8 replace：坏字节产出 U+FFFD，各块大小一致。 */
    @TestCase
    public func utf8ReplaceAcrossBufSizes(): Unit {
        var bytes = ArrayList<Byte>()
        for (b in "<r>ab".toArray()) {
            bytes.add(b)
        }
        bytes.add(0xFF)
        for (b in "cd😀</r>".toArray()) {
            bytes.add(b)
        }
        let data = bytes.toArray()
        this.assertSame({size => MemoryInputStream(data)}, "utf8-replace", mode: InvalidByteMode.Replace)
    }

    /** GBK：走 charset4cj 逐字符填充（已登记例外的路径）也要一致。 */
    @TestCase
    public func gbkAcrossBufSizes(): Unit {
        let bytes = gbkBytes("<?xml version=\"1.0\" encoding=\"GBK\"?><r a=\"中文\">测试文本</r>")
        this.assertSame({size => MemoryInputStream(bytes)}, "gbk")
    }

    /** UTF-16LE / BE 与 UTF-32LE：固定块解码 + 块尾回退。 */
    @TestCase
    public func utf16AndUtf32AcrossBufSizes(): Unit {
        let doc = "<r>中文😀abc</r>"
        let le = utf16leBytes(doc, withBom: true)
        let be = utf16beBytes(doc, withBom: true)
        let utf32 = utf32beBytes(doc, withBom: true)
        this.assertSame({size => MemoryInputStream(le)}, "utf16le")
        this.assertSame({size => MemoryInputStream(be)}, "utf16be")
        this.assertSame({size => MemoryInputStream(utf32)}, "utf32be")
    }

    /** 错误消息与行列号与块大小无关。 */
    @TestCase
    public func errorPositionAcrossBufSizes(): Unit {
        let doc = "<r>\n  <a>文本</a>\n  <b></c>\n</r>"
        var baseMessage = ""
        var baseLine: Int64 = 0
        var baseColumn: Int64 = 0
        for (size in sizes) {
            let parser = XmlPullParser(MemoryInputStream(doc.toArray()), options: XmlParserOptions(bufSize: size))
            let error = assertAnyXmlError({=>
                while (parser.nextEvent().isSome()) {}
            })
            if (baseMessage.isEmpty()) {
                baseMessage = error.message
                baseLine = error.line
                baseColumn = error.column
            } else {
                assertTrue(error.message == baseMessage, "bufSize=${size} 错误消息不同：${error.message}")
                assertTrue(error.line == baseLine && error.column == baseColumn,
                    "bufSize=${size} 错误位置不同：${error.line}:${error.column} vs ${baseLine}:${baseColumn}")
            }
        }
        @Assert(baseLine == 3)
    }
}
