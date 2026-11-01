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

@Test
public class ParserError_test {
    @TestCase
    public func mismatchedEndTag(): Unit {
        let error = assertXmlError({=> parseEventLog("<a></b>")}, "不匹配")
        @Assert(error.line == 1)
    }

    @TestCase
    public func prematureEof(): Unit {
        assertXmlError({=> parseEventLog("<a><b>")}, "中间结束")
    }

    @TestCase
    public func missingWhitespaceBetweenAttributes(): Unit {
        assertXmlError({=> parseEventLog("<a b=\"1\"c=\"2\"/>")}, "缺少空白")
    }

    @TestCase
    public func bareLessThanInAttribute(): Unit {
        assertXmlError({=> parseEventLog("<a b=\"<\"/>")}, "&lt;")
    }

    @TestCase
    public func unterminatedQuote(): Unit {
        assertXmlError({=> parseEventLog("<a b=\"1'/>")}, "未闭合")
    }

    /** 重复属性按字面名。 */
    @TestCase
    public func duplicateAttributeLiteral(): Unit {
        assertXmlError({=> parseEventLog("<a x=\"1\" x=\"2\"/>")}, "重复的属性")
    }

    /** 重复属性按**展开名**（字面名不同、URI 相同）。 */
    @TestCase
    public func duplicateAttributeExpanded(): Unit {
        assertXmlError({=> parseEventLog("<a xmlns:p=\"u\" xmlns:q=\"u\" p:x=\"1\" q:x=\"2\"/>")}, "重复的属性")
    }

    /** 一万层嵌套不栈溢出，按上限报错。 */
    @TestCase
    public func deepNestingRejected(): Unit {
        let open = repeatText("<a>", 10000)
        assertXmlError({=> parseEventLog(open)}, "嵌套深度")
    }

    /** 深度恰好在边界内可以通过。 */
    @TestCase
    public func depthAtLimit(): Unit {
        let depth = 100
        let open = repeatText("<a>", depth)
        let close = repeatText("</a>", depth)
        let doc = parseText(open + close, options: XmlParserOptions(maxElementDepth: 100))
        @Assert(doc.root.isSome())
    }

    @TestCase
    public func attributeValueLengthLimit(): Unit {
        let value = repeatText("x", 100)
        let options = XmlParserOptions(maxAttributeValueLength: 50)
        assertXmlError({=> parseText("<a b=\"${value}\"/>", options: options)}, "超过上限")
    }

    /** version="1.1" 拒绝，消息含 1.1。 */
    @TestCase
    public func version11Rejected(): Unit {
        assertXmlError({=> parseEventLog("<?xml version=\"1.1\"?><a/>")}, "1.1")
    }

    @TestCase
    public func version20Rejected(): Unit {
        assertXmlError({=> parseEventLog("<?xml version=\"2.0\"?><a/>")}, "不支持的 XML 版本")
    }

    @TestCase
    public func version10AndOmitted(): Unit {
        @Assert(parseText("<?xml version=\"1.0\"?><a/>").root.isSome())
        @Assert(parseText("<a/>").root.isSome())
    }

    /** 注释里的 `--` 报错。 */
    @TestCase
    public func commentDoubleHyphen(): Unit {
        assertXmlError({=> parseEventLog("<!-- a -- b --><a/>")}, "注释")
    }

    /** 注释以 `-` 结尾报错。 */
    @TestCase
    public func commentTrailingHyphen(): Unit {
        assertXmlError({=> parseEventLog("<!-- a ---><a/>")}, "注释")
    }

    /** PI target 为 xml（任意大小写）报错。 */
    @TestCase
    public func piTargetXmlRejected(): Unit {
        assertXmlError({=> parseEventLog("<?XML x?><a/>")}, "xml")
    }

    /** `<a><1/></a>` 文本里的裸 `<` 后跟非法名字首字符。 */
    @TestCase
    public func bareLessThanInText(): Unit {
        assertXmlError({=> parseEventLog("<a><1/></a>")}, "名字")
    }

    /** 文本里的 `]]>` 报错。 */
    @TestCase
    public func cdataEndInText(): Unit {
        assertXmlError({=> parseEventLog("<a>]]></a>")}, "]]>")
    }

    /** 属性值里的 `<` 报错且消息提示 `&lt;`。 */
    @TestCase
    public func rawLessThanInAttributeValue(): Unit {
        let error = assertXmlError({=> parseEventLog("<a b=\"<\" />")}, "&lt;")
        @Assert(error.line == 1)
    }
}

/** `Name` 的字符集边界（设计文档 §12.2 B 的两条盲区）。 */
@Test
public class NameSyntax_test {
    /** 非 ASCII 名字合法：XML 1.0 的 `NameStartChar` 覆盖大量 Unicode 字母。 */
    @TestCase
    public func nonAsciiNames(): Unit {
        let doc = parseText("<根 属性=\"值\">文本</根>")
        let root = doc.root.getOrThrow()
        @Assert(root.name.local == "根")
        @Assert(root.attr("属性") == Some("值"))
        @Assert(root.text() == "文本")
    }

    /** 名字不能以数字开头（元素名与属性名都一样）。 */
    @TestCase
    public func nameMayNotStartWithDigit(): Unit {
        assertAnyXmlError({=> parseText("<1a/>")})
        assertAnyXmlError({=> parseText("<a 1x=\"v\"/>")})
        parseText("<a1/>")
    }

    /** 单行超长文档也能定位。 */
    @TestCase
    public func positionOnLongSingleLine(): Unit {
        let prefix = String(Array<Rune>(200000, repeat: r'a'))
        let error = assertAnyXmlError({=> parseEventLog("<a>" + prefix + "<>")})
        assertTrue(error.line == 1, "行号应为 1，实际 ${error.line}")
        assertTrue(error.column > 200000, "列号应超过 200000，实际 ${error.column}")
    }
}
