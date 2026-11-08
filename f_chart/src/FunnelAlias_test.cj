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
import fountain::f_data.json.*

@Test
public class FunnelAlias_test {
    private func draw(json: String): String {
        FunnelChart().draw(JsonValue.fromStr(json).asObject())
    }

    private func count(svg: String, needle: String): Int64 {
        var total = 0
        var from = 0
        while (let Some(index) <- svg.indexOf(needle, from)) {
            total++
            from = index + needle.toArray().size
        }
        total
    }

    private let sample: String = """
{
  "type": "funnel",
  "title": "注册转化",
  "width": 640,
  "height": 480,
  "gap": 2,
  "showConversion": true,
  "series": [
    {
      "name": "阶段",
      "data": [
        { "name": "访问", "value": 10000 },
        { "name": "注册", "value": 6200 },
        { "name": "激活", "value": 3800 },
        { "name": "付费", "value": 1200 }
      ]
    }
  ]
}
"""

    /** 四个阶段。 */
    @TestCase
    public func drawsStages(): Unit {
        @Assert(count(draw(sample), "class=\"funnel-stage\"") == 4)
    }

    /** 四个阶段名与三个转化率。 */
    @TestCase
    public func drawsLabels(): Unit {
        let svg = draw(sample)
        @Assert(count(svg, "class=\"stage-label\"") == 4)
        @Assert(count(svg, "class=\"conversion-label\"") == 3)
        @Assert(svg.contains("注册"))
    }

    /** 类型不匹配。 */
    @TestCase
    public func rejectsType(): Unit {
        let json = """
{
  "type": "pyramid",
  "series": [
    { "name": "阶段", "data": [ { "name": "访问", "value": 10 } ] }
  ]
}
"""
        try {
            draw(json)
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.UnsupportedChart)
        }
    }
}
