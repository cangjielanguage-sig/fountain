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
public class ParserState_test {
    /** 前导区允许注释与 PI 交替出现，且都在根之前。 */
    @TestCase
    public func prologCommentsAndPi(): Unit {
        let log = parseEventLog("<!--a--><?p d?><!--b--><root/>")
        let expected = [
            "START document",
            "COMMENT \"a\"",
            "PI p \"d\"",
            "COMMENT \"b\"",
            "START QName(-,root,-) attrs=0 selfClosing=true",
            "END QName(-,root,-)",
            "END document"
        ]
        assertTrue(logEquals(log, expected), joinLog(log))
    }

    /** 尾部注释在 EndElement 之后、EndDocument 之前。 */
    @TestCase
    public func epilogComment(): Unit {
        let log = parseEventLog("<a/><!--tail-->")
        assertTrue(
            logEquals(log, ["START document", "START QName(-,a,-) attrs=0 selfClosing=true",
                "END QName(-,a,-)", "COMMENT \"tail\"", "END document"]),
            joinLog(log)
        )
    }

    /** 声明最多一次。 */
    @TestCase
    public func declarationOnce(): Unit {
        assertXmlError({=> parseEventLog("<?xml version=\"1.0\"?><?xml version=\"1.0\"?><a/>")}, "只能出现一次")
    }

    /** 多根元素报错。 */
    @TestCase
    public func multipleRoots(): Unit {
        assertXmlError({=> parseEventLog("<a/><b/>")}, "只能有一个根元素")
    }

    /** 无根元素报错。 */
    @TestCase
    public func noRoot(): Unit {
        assertXmlError({=> parseEventLog("")}, "文档没有根元素")
        assertXmlError({=> parseEventLog("   \n ")}, "文档没有根元素")
        assertXmlError({=> parseEventLog("<!--only-->")}, "文档没有根元素")
    }

    /** 前导区的裸文本报错。 */
    @TestCase
    public func textBeforeRootRejected(): Unit {
        assertXmlError({=> parseEventLog("hello<a/>")}, "根元素之前不允许出现文本")
    }

    /** 尾部裸文本报错。 */
    @TestCase
    public func textAfterRootRejected(): Unit {
        assertXmlError({=> parseEventLog("<a/>tail")}, "根元素之后不允许出现文本")
    }

    /** 声明必须最靠前。 */
    @TestCase
    public func declarationMustBeFirst(): Unit {
        assertXmlError({=> parseEventLog("<!--c--><?xml version=\"1.0\"?><a/>")}, "最前面")
    }

    /** 正常文档的事件顺序。 */
    @TestCase
    public func standardOrder(): Unit {
        let log = parseEventLog("<?xml version=\"1.0\" encoding=\"UTF-8\"?><!--p--><a>x</a><!--e-->")
        let expected = [
            "START document",
            "DECL 1.0 encoding=UTF-8 standalone=-",
            "COMMENT \"p\"",
            "START QName(-,a,-) attrs=0 selfClosing=false",
            "TEXT \"x\" 1",
            "END QName(-,a,-)",
            "COMMENT \"e\"",
            "END document"
        ]
        assertTrue(logEquals(log, expected), joinLog(log))
    }
}
