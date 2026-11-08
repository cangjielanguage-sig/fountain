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
public class WordCloudChart_test {
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
  "type": "word-cloud",
  "title": "用户反馈关键词",
  "width": 760,
  "height": 480,
  "minFontSize": 14,
  "maxFontSize": 56,
  "rotate": [0, 90],
  "words": [
    { "text": "易用", "weight": 80 },
    { "text": "稳定", "weight": 65, "color": "#123456" },
    { "text": "快速", "weight": 60 },
    { "text": "界面", "weight": 45 },
    { "text": "文档", "weight": 35 },
    { "text": "价格", "weight": 25 }
  ]
}
"""

    /** 六个词项。 */
    @TestCase
    public func drawsWords(): Unit {
        @Assert(count(draw(sample), "word-cloud-word") == 6)
    }

    /** 字号映射到边界。 */
    @TestCase
    public func appliesFontBounds(): Unit {
        let svg = draw(sample)
        @Assert(svg.contains("font-size=\"56\""))
        @Assert(svg.contains("font-size=\"14\""))
    }

    /** 旋转按词序循环。 */
    @TestCase
    public func cyclesRotation(): Unit {
        @Assert(count(draw(sample), "rotate(90 ") == 3)
    }

    /** 词项颜色覆盖。 */
    @TestCase
    public func appliesCustomColor(): Unit {
        @Assert(draw(sample).contains("#123456"))
    }

    /** 开方映射数值。 */
    @TestCase
    public func mapsFontSize(): Unit {
        let maxSize = wordCloudFontSize(80.0, 20.0, 80.0, 12.0, 64.0)
        @Assert(maxSize == 64.0)
        let minSize = wordCloudFontSize(20.0, 20.0, 80.0, 12.0, 64.0)
        @Assert(minSize == 12.0)
        let middle = wordCloudFontSize(50.0, 20.0, 80.0, 12.0, 64.0)
        @Assert(abs(middle - (12.0 + 52.0 * sqrt(0.5))) < 1e-9)
    }

    /** 权重相同时取最小字号。 */
    @TestCase
    public func usesMinSizeForEqualWeights(): Unit {
        @Assert(wordCloudFontSize(10.0, 10.0, 10.0, 12.0, 64.0) == 12.0)
    }

    /** 空词表。 */
    @TestCase
    public func rejectsEmptyWords(): Unit {
        let json = """
{ "type": "word-cloud", "words": [] }
"""
        try {
            draw(json)
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 非法字号。 */
    @TestCase
    public func rejectsBadFontSize(): Unit {
        let json = """
{
  "type": "word-cloud",
  "minFontSize": 0,
  "words": [ { "text": "图", "weight": 1 } ]
}
"""
        try {
            draw(json)
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 非法权重。 */
    @TestCase
    public func rejectsBadWeight(): Unit {
        let json = """
{
  "type": "word-cloud",
  "words": [ { "text": "图", "weight": 0 } ]
}
"""
        try {
            draw(json)
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 非法旋转角度。 */
    @TestCase
    public func rejectsBadRotation(): Unit {
        let json = """
{
  "type": "word-cloud",
  "rotate": [45],
  "words": [ { "text": "图", "weight": 1 } ]
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
