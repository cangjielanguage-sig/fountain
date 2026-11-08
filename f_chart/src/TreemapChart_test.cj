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
public class TreemapChart_test {
    private func draw(json: String): String {
        TreemapChart().draw(JsonValue.fromStr(json).asObject())
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
  "type": "treemap",
  "tiling": "squarify",
  "nodes": [
    { "id": "root", "name": "根目录", "parent": null },
    { "id": "usr", "name": "usr", "parent": "root" },
    { "id": "var", "name": "var", "parent": "root" },
    { "id": "bin", "name": "bin", "parent": "usr", "value": 120 },
    { "id": "lib", "name": "lib", "parent": "usr", "value": 260 },
    { "id": "log", "name": "log", "parent": "var", "value": 90 },
    { "id": "cache", "name": "cache", "parent": "var", "value": 60 }
  ]
}
"""

    /** 四个叶子单元与标签。 */
    @TestCase
    public func drawsLeaves(): Unit {
        let svg = draw(sample)
        @Assert(count(svg, "class=\"treemap-cell\"") == 4)
        @Assert(count(svg, "class=\"treemap-label\"") == 4)
    }

    /** 权重归一化。 */
    @TestCase
    public func computesWeights(): Unit {
        let weights = treemapWeights([120.0, 260.0, 90.0, 60.0])
        @Assert(weights.size == 4)
        var total = 0.0
        for (weight in weights) {
            total += weight
        }
        @Assert(abs(total - 1.0) < 1e-9)
        @Assert(abs(weights[0] - 120.0 / 530.0) < 1e-9)
    }

    /** 悬空父节点。 */
    @TestCase
    public func rejectsMissingParent(): Unit {
        try {
            draw("""
{
  "type": "treemap",
  "nodes": [
    { "id": "root", "name": "根", "parent": null },
    { "id": "a", "name": "a", "parent": "ghost", "value": 10 }
  ]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 负值。 */
    @TestCase
    public func rejectsNegativeValue(): Unit {
        try {
            draw("""
{
  "type": "treemap",
  "nodes": [
    { "id": "root", "name": "根", "parent": null },
    { "id": "a", "name": "a", "parent": "root", "value": -5 }
  ]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 非法 tiling。 */
    @TestCase
    public func rejectsInvalidTiling(): Unit {
        try {
            draw("""
{
  "type": "treemap",
  "tiling": "binary",
  "nodes": [
    { "id": "root", "name": "根", "parent": null },
    { "id": "a", "name": "a", "parent": "root", "value": 10 }
  ]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 缺 nodes。 */
    @TestCase
    public func rejectsMissingNodes(): Unit {
        try {
            draw("""
{ "type": "treemap" }
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
  "type": "sunburst",
  "nodes": [
    { "id": "root", "name": "根", "parent": null },
    { "id": "a", "name": "a", "parent": "root", "value": 10 }
  ]
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
        @Assert(draw(sample) == draw(sample))
    }
}
