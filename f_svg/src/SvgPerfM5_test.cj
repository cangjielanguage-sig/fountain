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
package fountain::f_svg

import std.collection.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*

internal func m5ThousandElementSvg(): String {
    let out = StringBuilder()
    out.append("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"1000\" height=\"1000\"><g id=\"g\">")
    for (index in 0..1000) {
        out.append("<rect class=\"a\" x=\"")
        out.append((index % 100).toString())
        out.append("\" y=\"")
        out.append((index / 100).toString())
        out.append("\" width=\"5\" height=\"5\"/>")
    }
    out.append("</g></svg>")
    out.toString()
}

@Test
public class SvgBenchmarkM5_test {
    /** 1000 元素文档的查询与单次 getBBox 耗时（参考值，不设门禁）。 */
    @TestCase
    public func thousandElementQueries(): Unit {
        let document = SvgParser.parse(m5ThousandElementSvg())
        let group = document.elementById("g") ?? throw invalidValue("缺少 g")
        let queryStart = MonoTime.now()
        let queried = group.querySelectorAll("rect.a")
        let queryElapsed = MonoTime.now() - queryStart
        @Assert(queried.size == 1000)
        let target = queried[500]
        let bboxStart = MonoTime.now()
        let box = target.getBBox()
        let bboxElapsed = MonoTime.now() - bboxStart
        @Assert(box.isSome())
        println("M5_PERF query=${queryElapsed.toNanoseconds()}ns bbox=${bboxElapsed.toNanoseconds()}ns")
    }
}
