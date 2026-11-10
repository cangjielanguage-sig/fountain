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

@Test
public class WriterEncoding_test {
    private func writeBytes(element: XmlElement, options: XmlWriterOptions): Array<Byte> {
        let output = RecordingOutputStream()
        let writer = XmlWriter(output, options: options)
        writer.write(element)
        writer.close()
        output.bytes()
    }

    /** 默认无 BOM。 */
    @TestCase
    public func noBomByDefault(): Unit {
        let bytes = writeBytes(XmlElement("a"), XmlWriterOptions())
        @Assert(bytes[0] == 0x3C)
    }

    /** UTF-16LE 带 BOM，且能解析回来。 */
    @TestCase
    public func utf16leBom(): Unit {
        let element = XmlElement("a").withText("中文")
        let bytes = writeBytes(element, XmlWriterOptions(charset: Charsets.UTF16LE))
        @Assert(bytes[0] == 0xFF && bytes[1] == 0xFE)
        let doc = XmlParser.parse(bytes)
        @Assert(doc.root.getOrThrow().text() == "中文")
    }

    /** UTF-16BE 带 BOM。 */
    @TestCase
    public func utf16beBom(): Unit {
        let bytes = writeBytes(XmlElement("a"), XmlWriterOptions(charset: Charsets.UTF16BE))
        @Assert(bytes[0] == 0xFE && bytes[1] == 0xFF)
    }

    /** UTF-32BE 带 4 字节 BOM。 */
    @TestCase
    public func utf32beBom(): Unit {
        let bytes = writeBytes(XmlElement("a"), XmlWriterOptions(charset: Charsets.UTF32BE))
        @Assert(bytes[0] == 0x00 && bytes[1] == 0x00 && bytes[2] == 0xFE && bytes[3] == 0xFF)
    }

    /** GBK 输出可解回。 */
    @TestCase
    public func gbkRoundTrip(): Unit {
        let element = XmlElement("a").withText("中文测试")
        let bytes = writeBytes(element, XmlWriterOptions(charset: Charsets.GBK))
        let text = Charsets.GBK.newDecoder().decode(bytes)
        @Assert(text == "<a>中文测试</a>")
    }

    /** GBK 写 emoji：Throw 报错且消息带码点。 */
    @TestCase
    public func gbkEmojiThrows(): Unit {
        let element = XmlElement("a").withText("😀")
        let error = assertXmlError({=>
            let output = RecordingOutputStream()
            let writer = XmlWriter(output, options: XmlWriterOptions(charset: Charsets.GBK))
            writer.write(element)
            writer.close()
        }, "U+1F600")
        @Assert(error.message.contains("字符"))
    }

    /** GBK 写 emoji：Replace 用 `?` 且字符数不变。 */
    @TestCase
    public func gbkEmojiReplaced(): Unit {
        let element = XmlElement("a").withText("a😀b")
        let bytes = writeBytes(
            element,
            XmlWriterOptions(charset: Charsets.GBK, onInvalidChar: InvalidCharMode.Replace)
        )
        let text = Charsets.GBK.newDecoder().decode(bytes)
        @Assert(text == "<a>a?b</a>")
    }

    /** UTF-8 不做往返校验：任意 Unicode 都能写出，且计次为 0。 */
    @TestCase
    public func utf8NoRoundTripCheck(): Unit {
        let element = XmlElement("a").withText("😀中文")
        let output = RecordingOutputStream()
        let writer = XmlWriter(output, options: XmlWriterOptions())
        writer.write(element)
        writer.close()
        @Assert(String.fromUtf8(output.bytes()) == "<a>😀中文</a>")
        assertTrue(writer.roundTripChecks == 0, "UTF-8 不应执行往返校验")
    }

    /** GBK 会执行往返校验（计次 > 0）。 */
    @TestCase
    public func gbkDoesRoundTripCheck(): Unit {
        let output = RecordingOutputStream()
        let writer = XmlWriter(output, options: XmlWriterOptions(charset: Charsets.GBK))
        writer.write(XmlElement("a").withText("中文"))
        writer.close()
        @Assert(writer.roundTripChecks > 0)
    }

    /** 写次数远小于 token 数（缓冲生效）。 */
    @TestCase
    public func bufferedWrites(): Unit {
        let root = XmlElement("r")
        for (i in 0..5000) {
            root.appendChild(XmlNode.ElementNode(XmlElement("i").withText("v")))
        }
        let output = RecordingOutputStream()
        let writer = XmlWriter(output, options: XmlWriterOptions())
        writer.write(root)
        writer.close()
        assertTrue(output.writeCount < 100, "写次数 ${output.writeCount}")
    }
}

@Test
public class WriterEntity_test {
    private func companyDoctype(): Doctype {
        Doctype(
            "a",
            entities: [
                EntityDecl("company", value: Some("Acme")),
                EntityDecl("other", value: Some("X"))
            ]
        )
    }

    /** 已声明实体原样输出 `&name;`，并在开头输出 DOCTYPE。 */
    @TestCase
    public func declaredEntity(): Unit {
        let element = XmlElement("a")
        element.appendChild(XmlEntityRef("company"))
        let text = writeElementText(element, options: XmlWriterOptions(doctype: Some(this.companyDoctype())))
        @Assert(text.startsWith("<!DOCTYPE a ["))
        @Assert(text.contains("&company;"))
    }

    /** 未声明实体默认报错，消息含名字。 */
    @TestCase
    public func undeclaredEntityThrows(): Unit {
        let element = XmlElement("a")
        element.appendChild(XmlEntityRef("missing"))
        assertXmlError({=> writeElementText(element)}, "missing")
    }

    /** `strictEntities = false` 只告警并输出。 */
    @TestCase
    public func nonStrictOutputs(): Unit {
        let element = XmlElement("a")
        element.appendChild(XmlEntityRef("missing"))
        let text = writeElementText(element, options: XmlWriterOptions(strictEntities: false))
        @Assert(text == "<a>&missing;</a>")
    }
}

@Test
public class WriterNamespace_test {
    /** 不重复声明。 */
    @TestCase
    public func noDuplicateDeclaration(): Unit {
        let doc = parseText("<a xmlns=\"A\"><b/></a>")
        let text = writeText(doc)
        @Assert(text == "<a xmlns=\"A\"><b/></a>")
    }

    /** 改绑定要重声明。 */
    @TestCase
    public func rebindDeclaration(): Unit {
        let doc = parseText("<a xmlns=\"A\"><b xmlns=\"B\"/></a>")
        let text = writeText(doc)
        @Assert(text == "<a xmlns=\"A\"><b xmlns=\"B\"/></a>")
    }

    /** 回到无命名空间要写 `xmlns=""`。 */
    @TestCase
    public func resetDeclaration(): Unit {
        let doc = parseText("<a xmlns=\"A\"><b xmlns=\"\"/></a>")
        let text = writeText(doc)
        @Assert(text == "<a xmlns=\"A\"><b xmlns=\"\"/></a>")
    }

    /**
     * 前缀在**首次使用处**声明。
     *
     * DOM 不保留原始的 `xmlns:x` 声明（它不是属性，属于命名空间信息），
     * 所以写侧只能把声明放在真正用到该前缀的元素上——这是可回溯的最小化口径。
     */
    @TestCase
    public func prefixDeclaredWhereUsed(): Unit {
        let doc = parseText("<r xmlns:x=\"u\"><x:a/><x:b/></r>")
        let text = writeText(doc)
        @Assert(text.contains("xmlns:x=\"u\""))
        let again = parseText(text)
        let root = again.root.getOrThrow()
        let a = root.childrenOf("a")[0]
        let b = root.childrenOf("b")[0]
        @Assert(a.name.uri == Some("u"))
        @Assert(b.name.uri == Some("u"))
    }
}

/** 语义比较：展开名 + 属性值 + 文本 + 节点顺序。 */
internal func semanticDump(node: XmlNode): String {
    match (node) {
        case XmlNode.ElementNode(e) =>
            let attrs = ArrayList<String>()
            for (attribute in e.attributes) {
                attrs.add("${attribute.name.local}=${attribute.value}")
            }
            var attrText = ""
            for (a in attrs) {
                attrText += " " + a
            }
            let children = ArrayList<String>()
            for (child in e.children) {
                children.add(semanticDump(child))
            }
            var childText = ""
            for (c in children) {
                childText += c + ";"
            }
            "E:${e.name.local}#${e.name.uri ?? "-"}${attrText}[${childText}]"
        case XmlNode.TextNode(t) => "T:${t}"
        case XmlNode.CDataNode(t) => "C:${t}"
        case XmlNode.CommentNode(t) => "M:${t}"
        case XmlNode.PiNode(target, data) => "P:${target}:${data}"
        case XmlNode.EntityRefNode(name) => "R:${name}"
    }
}

@Test
public class RoundTrip_test {
    private func roundTrip(input: String, options!: XmlWriterOptions = XmlWriterOptions()): String {
        let first = parseText(input)
        let text = writeText(first, options: options)
        let second = parseText(text)
        semanticDump(XmlNode.ElementNode(second.root.getOrThrow()))
    }

    /** 常见文档：命名空间、CDATA、注释、PI 往返语义一致。 */
    @TestCase
    public func commonDocument(): Unit {
        let input = "<r xmlns:x=\"u\" a=\"1\"><x:item>t</x:item><![CDATA[c]]><!--m--><?pi d?></r>"
        let first = semanticDump(XmlNode.ElementNode(parseText(input).root.getOrThrow()))
        @Assert(this.roundTrip(input) == first)
    }

    /** 文本里的回车往返后仍在。 */
    @TestCase
    public func carriageReturnPreserved(): Unit {
        let element = XmlElement("a").withText("x\ry")
        let text = writeElementText(element)
        @Assert(parseText(text).root.getOrThrow().text() == "x\ry")
    }

    /** 缩进模式往返仍语义一致（空白文本节点不参与比较）。 */
    @TestCase
    public func indentedRoundTrip(): Unit {
        let input = "<a><b>x</b><c/></a>"
        let first = parseText(input)
        let text = writeText(first, options: XmlWriterOptions(indent: Some("  ")))
        let second = parseText(text)
        @Assert(second.root.getOrThrow().child("b").getOrThrow().text() == "x")
        @Assert(second.root.getOrThrow().child("c").isSome())
    }
}
