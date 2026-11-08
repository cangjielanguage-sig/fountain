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
public class RaincloudChart_test {
    private func draw(json: String): String {
        RaincloudChart().draw(JsonValue.fromStr(json).asObject())
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
  "type": "raincloud",
  "title": "各组得分分布",
  "xAxis": { "type": "category", "labels": ["A 组", "B 组", "C 组"] },
  "yAxis": { "type": "linear", "title": "得分", "min": 0 },
  "series": [
    { "name": "得分", "data": [55, 60, 62, 65, 68, 70, 72, 75, 78, 82, 88, 92], "bandwidth": 4.0, "showCloud": true, "showRain": true, "showBox": true }
  ]
}
"""

    /** 一朵云。 */
    @TestCase
    public func drawsCloud(): Unit {
        @Assert(count(draw(sample), "class=\"raincloud-cloud\"") == 1)
    }

    /** 十二个雨点。 */
    @TestCase
    public func drawsRain(): Unit {
        @Assert(count(draw(sample), "class=\"raincloud-rain\"") == 12)
    }

    /** 箱体、中位线与两条须线。 */
    @TestCase
    public func drawsBox(): Unit {
        let svg = draw(sample)
        @Assert(count(svg, "raincloud-box") == 1)
        @Assert(count(svg, "raincloud-median") == 1)
        @Assert(count(svg, "raincloud-whisker") == 2)
    }

    /** 类目名。 */
    @TestCase
    public func drawsCategory(): Unit {
        @Assert(draw(sample).contains("A 组"))
    }

    /** 关闭雨点。 */
    @TestCase
    public func hidesRain(): Unit {
        let json = """
{
  "type": "raincloud",
  "xAxis": { "type": "category", "labels": ["A"] },
  "series": [
    { "name": "S", "data": [1, 2, 3], "showRain": false }
  ]
}
"""
        let svg = draw(json)
        @Assert(count(svg, "raincloud-rain") == 0)
        @Assert(count(svg, "raincloud-cloud") == 1)
    }

    /** 关闭云与箱。 */
    @TestCase
    public func hidesCloudAndBox(): Unit {
        let json = """
{
  "type": "raincloud",
  "xAxis": { "type": "category", "labels": ["A"] },
  "series": [
    { "name": "S", "data": [1, 2, 3], "showCloud": false, "showBox": false }
  ]
}
"""
        let svg = draw(json)
        @Assert(count(svg, "raincloud-cloud") == 0)
        @Assert(count(svg, "raincloud-box") == 0)
        @Assert(count(svg, "raincloud-rain") == 3)
    }

    /** 非法带宽。 */
    @TestCase
    public func rejectsBandwidth(): Unit {
        let json = """
{
  "type": "raincloud",
  "xAxis": { "type": "category", "labels": ["A"] },
  "series": [
    { "name": "S", "data": [1, 2, 3], "bandwidth": -1 }
  ]
}
"""
        try {
            draw(json)
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 空数据。 */
    @TestCase
    public func rejectsEmptyData(): Unit {
        let json = """
{
  "type": "raincloud",
  "xAxis": { "type": "category", "labels": ["A"] },
  "series": [
    { "name": "S", "data": [] }
  ]
}
"""
        try {
            draw(json)
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 类型不匹配。 */
    @TestCase
    public func rejectsType(): Unit {
        let json = """
{
  "type": "violin",
  "xAxis": { "type": "category", "labels": ["A"] },
  "series": [
    { "name": "S", "data": [1, 2, 3] }
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
