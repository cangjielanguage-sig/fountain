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
public class EntityCounterIsolation_test {
    /** 展开 `times` 次、每次 `chunk` 个字符的实体文档。 */
    private func entityDoc(chunk: Int64, times: Int64): String {
        let payload = repeatText("x", chunk)
        "<!DOCTYPE r [<!ENTITY e \"${payload}\">]><r>${repeatText("&e;", times)}</r>"
    }

    private func parser(doc: String, limits!: EntityLimits = EntityLimits()): XmlPullParser {
        XmlPullParser(text: doc, options: XmlParserOptions(entityLimits: limits))
    }

    /** 交错驱动：两个解析器的 totalExpanded 只随自身推进变化。 */
    @TestCase
    public func interleavedParsersKeepCountersSeparate(): Unit {
        let doc = this.entityDoc(10, 3)
        let first = this.parser(doc)
        let second = this.parser(doc)
        var firstBefore: Int64 = 0
        var secondBefore: Int64 = 0
        while (true) {
            let e1 = first.nextEvent()
            let firstNow = first.totalExpanded()
            @Assert(firstNow >= firstBefore)
            let secondNow = second.totalExpanded()
            assertTrue(secondNow == secondBefore, "推进第一个解析器不应改变第二个的计数：${secondBefore} → ${secondNow}")

            let e2 = second.nextEvent()
            secondBefore = second.totalExpanded()
            assertTrue(first.totalExpanded() == firstNow, "推进第二个解析器不应改变第一个的计数")
            firstBefore = firstNow

            if (e1.isNone() && e2.isNone()) {
                break
            }
        }
        assertTrue(first.totalExpanded() == 30, "第一个解析器应展开 30 个字符，实际 ${first.totalExpanded()}")
        assertTrue(second.totalExpanded() == 30, "第二个解析器应展开 30 个字符，实际 ${second.totalExpanded()}")
    }

    /** 双线程：各解析 0.8 × maxExpandedTotal，两份都成功（全局计数会让第二份超限）。 */
    @TestCase
    public func concurrentParsersDoNotShareCounter(): Unit {
        let maxTotal: Int64 = 10000
        let limits = EntityLimits(maxExpandedTotal: maxTotal, overflowPolicy: EntityOverflowPolicy.Strict)
        let doc = this.entityDoc(1000, 8)
        let f1 = spawn {
            let parser = this.parser(doc, limits: limits)
            while (parser.nextEvent().isSome()) {}
            parser.totalExpanded()
        }
        let f2 = spawn {
            let parser = this.parser(doc, limits: limits)
            while (parser.nextEvent().isSome()) {}
            parser.totalExpanded()
        }
        let t1 = f1.get()
        let t2 = f2.get()
        assertTrue(t1 == 8000, "第一个线程应展开 8000 个字符，实际 ${t1}")
        assertTrue(t2 == 8000, "第二个线程应展开 8000 个字符，实际 ${t2}")
    }
}
