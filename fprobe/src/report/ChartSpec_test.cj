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
package fountain::fprobe.report

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_data.*
import fountain::f_svg.SvgParser

/** 15.2：ChartSpec DTO → JSON → 真实 f_chart SVG。 */
@Test
public class ChartSpec_test {
    @TestCase
    public func valuesBecomeSeriesAndJsonPoints(): Unit {
        let values = Array<Float64>(10) {i => Float64(i) * 10.0}
        let spec = ChartSpec.fromValues("line", "web1 CPU", values)
        let root = spec.jsonObject()
        let series = root.get("series").getOrThrow().asArray()
        let first = series[0].asObject()
        let data = first.get("data").getOrThrow().asArray()

        @Assert(spec.chartType, "line")
        @Assert(spec.xAxis.labels.size, 10)
        @Assert(spec.series.size, 1)
        @Assert(spec.series[0].data.size, 10)
        @Assert(data.size, 10)
        @Assert(root.get("type").getOrThrow().asString().value, "line")
    }

    @TestCase
    public func renderedSvgIsCompleteAndParsable(): Unit {
        let values = Array<Float64>(10) {i => Float64(i) * 10.0}
        let spec = ChartSpec.fromValues("line", "web1 CPU", values)
        let svg = ChartRenderer().render(spec)

        @Assert(!svg.trimAscii().isEmpty())
        @Assert(svg.contains("<svg"))
        let parsed = SvgParser.parse(svg)
        @Assert(parsed.root.tag, "svg")
    }

    @TestCase
    public func barAndAreaAreSupported(): Unit {
        let values = [1.0, 2.0, 3.0]
        let bar = ChartRenderer().render(ChartSpec.fromValues("bar", "disk", values))
        let area = ChartRenderer().render(ChartSpec.fromValues("area", "memory", values))

        @Assert(bar.contains("<svg"))
        @Assert(area.contains("<svg"))
    }
}
