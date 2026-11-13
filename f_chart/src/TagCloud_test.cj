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
public class TagCloud_test {
    private func draw(json: String): String {
        WordCloudChart().draw(JsonValue.fromStr(json).asObject())
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
  "type": "tag-cloud",
  "title": "热门标签",
  "width": 760,
  "height": 480,
  "words": [
    { "text": "仓颉", "weight": 90 },
    { "text": "SVG", "weight": 70 },
    { "text": "JSON", "weight": 55 },
    { "text": "图表", "weight": 40 }
  ]
}
"""

    /** 文档示例输出四个词。 */
    @TestCase
    public func drawsDocumentedAlias(): Unit {
        @Assert(count(draw(sample), "word-cloud-word") == 4)
    }

    /** 默认字号边界。 */
    @TestCase
    public func appliesDefaultFontBounds(): Unit {
        let svg = draw(sample)
        @Assert(svg.contains("font-size=\"64\""))
        @Assert(svg.contains("font-size=\"12\""))
    }

    /** 其他类型仍被拒绝。 */
    @TestCase
    public func rejectsOtherType(): Unit {
        let json = """
{
  "type": "pdp",
  "words": [ { "text": "图", "weight": 1 } ]
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
