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
package fountain::f_chart

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_data.json.JsonObject

@Test
public class Chart_test {
    /** `Chart` 引用调用到具体实现，返回实现给出的 SVG 字符串。 */
    @TestCase
    public func dispatchesThroughInterface(): Unit {
        let chart: Chart = ProbeChart()
        let svg = chart.draw(JsonObject())
        @Assert(svg == "<svg></svg>")
    }

    /** 接口契约要求 `draw` 不修改入参。 */
    @TestCase
    public func drawDoesNotMutateInput(): Unit {
        let data = JsonObject()
        data.add("type", "probe")
        let chart: Chart = ProbeChart()
        chart.draw(data)
        @Assert(data.size == 1)
        @Assert(data["type"].asString().value == "probe")
    }
}

/** 仅用于验证接口可分派；不属于生产实现。 */
class ProbeChart <: Chart {
    public func draw(data: JsonObject): String {
        "<svg></svg>"
    }
}
