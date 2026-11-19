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

/** 在 `skipName` 的 StartElement 之后立即跳过，返回剩余事件日志。 */
internal func skipAt(text: String, skipName: String): Array<String> {
    let parser = XmlPullParser(text: text, options: XmlParserOptions())
    let log = ArrayList<String>()
    var done = false
    while (!done) {
        match (parser.nextEvent()) {
            case Some(event) =>
                log.add(event.toString())
                match (event) {
                    case XmlEvent.StartElement(name, _, selfClosing) =>
                        if (name.local == skipName && !selfClosing) {
                            parser.skipElement()
                        }
                    case _ => ()
                }
            case None => done = true
        }
    }
    log.toArray()
}

@Test
public class SkipScanner_test {
    /** 同名嵌套按深度配对。 */
    @TestCase
    public func nestedSameName(): Unit {
        let log = skipAt("<a><b><b/></b></a>", "a")
        assertTrue(
            logEquals(log, ["START document", "START QName(-,a,-) attrs=0 selfClosing=false",
                "END QName(-,a,-)", "END document"]),
            joinLog(log)
        )
    }

    /** 注释里的 `>` 不结束标签。 */
    @TestCase
    public func commentWithGt(): Unit {
        let log = skipAt("<a><!-- a > b --><c/></a>", "a")
        assertTrue(log.size == 4, joinLog(log))
    }

    /** 属性值里的 `>` 不结束标签。 */
    @TestCase
    public func attributeWithGt(): Unit {
        let log = skipAt("<a><b x=\"1 > 0\"/></a>", "a")
        assertTrue(log.size == 4, joinLog(log))
    }

    /** CDATA 里的 `>` 与 `]]` 不干扰。 */
    @TestCase
    public func cdataWithGt(): Unit {
        let log = skipAt("<a><![CDATA[ </a> > ]]><c/></a>", "a")
        assertTrue(log.size == 4, joinLog(log))
    }

    /** PI 里的 `>` 不干扰。 */
    @TestCase
    public func piWithGt(): Unit {
        let log = skipAt("<a><?p x > y ?><c/></a>", "a")
        assertTrue(log.size == 4, joinLog(log))
    }

    /** 跳过不解析实体：实体未声明也不报错。 */
    @TestCase
    public func skipDoesNotResolveEntities(): Unit {
        let log = skipAt("<a>&unknown;<b/></a>", "a")
        assertTrue(log.size == 4, joinLog(log))
    }

    /** 提前 EOF 报错。 */
    @TestCase
    public func eofWhileSkipping(): Unit {
        let parser = XmlPullParser(text: "<a><b>", options: XmlParserOptions())
        @Assert(parser.nextEvent().isSome()) // StartDocument
        @Assert(parser.nextEvent().isSome()) // StartElement a
        assertXmlError({=> parser.skipElement()}, "EOF")
    }
}
