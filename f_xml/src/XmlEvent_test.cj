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
public class XmlEvent_test {
    /** 每个分支的稳定文本格式。 */
    @TestCase
    public func stableText(): Unit {
        @Assert(XmlEvent.StartDocument.toString() == "START document")
        @Assert(XmlEvent.XmlDeclaration("1.0", Some("UTF-8"), Some(true)).toString() ==
            "DECL 1.0 encoding=UTF-8 standalone=yes")
        @Assert(XmlEvent.DocType("rss", None, Some("u")).toString() == "DOCTYPE rss - u")
        @Assert(XmlEvent.StartElement(QName("rss", uri: Some("u")), Array<XmlAttribute>(), false).toString() ==
            "START QName(-,rss,u) attrs=0 selfClosing=false")
        @Assert(XmlEvent.EndElement(QName("rss")).toString() == "END QName(-,rss,-)")
        @Assert(XmlEvent.Text("我的订阅").toString() == "TEXT \"我的订阅\" 4")
        @Assert(XmlEvent.CData("ab").toString() == "CDATA \"ab\" 2")
        @Assert(XmlEvent.Comment("c").toString() == "COMMENT \"c\"")
        @Assert(XmlEvent.ProcessingInstruction("p", "d").toString() == "PI p \"d\"")
        @Assert(XmlEvent.EndDocument.toString() == "END document")
    }

    /** 文本里的引号与换行被转义，日志一行一条。 */
    @TestCase
    public func textEscaped(): Unit {
        @Assert(XmlEvent.Text("a\"b\nc").toString() == "TEXT \"a\\\"b\\nc\" 5")
    }

    /** `XmlAction` 自反、互不相等、可比较。 */
    @TestCase
    public func actionEquality(): Unit {
        @Assert(XmlAction.Continue == XmlAction.Continue)
        @Assert(XmlAction.SkipSubtree == XmlAction.SkipSubtree)
        @Assert(XmlAction.Stop == XmlAction.Stop)
        @Assert(XmlAction.Continue != XmlAction.Stop)
        @Assert(XmlAction.SkipSubtree != XmlAction.Continue)
        @Assert(XmlAction.Continue.toString() == "Continue")
        @Assert(XmlAction.SkipSubtree.toString() == "SkipSubtree")
        @Assert(XmlAction.Stop.toString() == "Stop")
    }

    /** 枚举比较走显式实现（不是编译器派生）：新增分支会被 match 穷尽性拦住。 */
    @TestCase
    public func enumComparisonExplicit(): Unit {
        let values = [XmlAction.Continue, XmlAction.SkipSubtree, XmlAction.Stop]
        for (a in values) {
            for (b in values) {
                let same = a.toString() == b.toString()
                @Assert((a == b) == same)
            }
        }
    }

    /** 其它需要比较的枚举同样显式实现 `==`。 */
    @TestCase
    public func otherEnumsEquality(): Unit {
        @Assert(InvalidByteMode.Strict == InvalidByteMode.Strict)
        @Assert(InvalidByteMode.Strict != InvalidByteMode.Replace)
        @Assert(EntityOverflowPolicy.Spill == EntityOverflowPolicy.Spill)
        @Assert(EntityOverflowPolicy.Spill != EntityOverflowPolicy.Strict)
        @Assert(EntityLimitKind.PerEntity != EntityLimitKind.Total)
    }
}

/** 只覆盖一个方法的 handler：验证默认实现足够。 */
internal class OnlyEndElementHandler <: XmlEventHandler {
    let ends = ArrayList<String>()

    public func onEndElement(name: QName): XmlAction {
        this.ends.add(name.toString())
        XmlAction.Continue
    }
}

@Test
public class EventHandlerDefault_test {
    @TestCase
    public func overrideOneMethod(): Unit {
        let handler = OnlyEndElementHandler()
        parseWithHandler(TextInputStream("<a><b/></a>"), handler, XmlParserOptions())
        @Assert(handler.ends.size == 2)
        @Assert(handler.ends[0] == "b" && handler.ends[1] == "a")
    }
}
