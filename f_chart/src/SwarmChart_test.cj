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

import std.math.*
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_data.json.*

@Test
public class SwarmChart_test {
    private func draw(json: String): String {
        SwarmChart().draw(JsonValue.fromStr(json).asObject())
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

    /** 两组六点。 */
    @TestCase
    public func drawsPoints(): Unit {
        let svg = draw("""
{
  "type": "swarm",
  "xAxis": { "type": "category", "labels": ["对照组", "低剂量"] },
  "series": [
    { "name": "测量值", "data": [[12, 14, 15], [22, 25, 30]] }
  ]
}
""")
        @Assert(count(svg, "class=\"swarm-point\"") == 6)
    }

    /** 扁平数据。 */
    @TestCase
    public func supportsFlatData(): Unit {
        let svg = draw("""
{
  "type": "swarm",
  "xAxis": { "type": "category", "labels": ["A"] },
  "series": [{ "name": "测量值", "data": [1, 2, 3, 4] }]
}
""")
        @Assert(count(svg, "class=\"swarm-point\"") == 4)
    }

    /** 双侧抖动交替正负且不超过 jitter。 */
    @TestCase
    public func alternatesOffsets(): Unit {
        let offsets = swarmOffsets(5, 0.4, "both")
        @Assert(offsets[0] == 0.0)
        @Assert(offsets[1] > 0.0)
        @Assert(offsets[2] < 0.0)
        for (offset in offsets) {
            @Assert(abs(offset) <= 0.4)
        }
    }

    /** 单侧抖动。 */
    @TestCase
    public func respectsSide(): Unit {
        let left = swarmOffsets(4, 0.4, "left")
        for (offset in left) {
            @Assert(offset <= 0.0)
        }
        let right = swarmOffsets(4, 0.4, "right")
        for (offset in right) {
            @Assert(offset >= 0.0)
        }
    }

    /** 非法 jitter。 */
    @TestCase
    public func rejectsInvalidJitter(): Unit {
        try {
            draw("""
{
  "type": "swarm",
  "xAxis": { "type": "category", "labels": ["A"] },
  "series": [{ "name": "测量值", "data": [1, 2, 3], "jitter": 1.5 }]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 非法 side。 */
    @TestCase
    public func rejectsInvalidSide(): Unit {
        try {
            draw("""
{
  "type": "swarm",
  "xAxis": { "type": "category", "labels": ["A"] },
  "series": [{ "name": "测量值", "data": [1, 2, 3], "side": "up" }]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 非数值。 */
    @TestCase
    public func rejectsNonNumeric(): Unit {
        try {
            draw("""
{
  "type": "swarm",
  "xAxis": { "type": "category", "labels": ["A"] },
  "series": [{ "name": "测量值", "data": [1, "2", 3] }]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 缺 series。 */
    @TestCase
    public func rejectsMissingSeries(): Unit {
        try {
            draw("""
{ "type": "swarm" }
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.MissingField)
        }
    }

    /** 类型不匹配。 */
    @TestCase
    public func rejectsTypeMismatch(): Unit {
        try {
            draw("""
{
  "type": "violin",
  "xAxis": { "type": "category", "labels": ["A"] },
  "series": [{ "name": "测量值", "data": [1, 2, 3] }]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.UnsupportedChart)
        }
    }

    /** 相同输入输出一致。 */
    @TestCase
    public func deterministic(): Unit {
        let json = """
{
  "type": "swarm",
  "xAxis": { "type": "category", "labels": ["A", "B"] },
  "series": [{ "name": "测量值", "data": [[1, 2, 3], [2, 3, 4]] }]
}
"""
        @Assert(draw(json) == draw(json))
    }
}
