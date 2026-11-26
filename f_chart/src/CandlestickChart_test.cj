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
public class CandlestickChart_test {
    private func draw(json: String): String {
        CandlestickChart().draw(JsonValue.fromStr(json).asObject())
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
  "type": "candlestick",
  "title": "日 K 线",
  "xAxis": { "type": "category", "labels": ["2026-01-05", "2026-01-06", "2026-01-07", "2026-01-08"] },
  "yAxis": { "type": "linear", "title": "价格", "min": 0 },
  "series": [
    {
      "name": "价格",
      "data": [
        { "date": "2026-01-05", "open": 100, "high": 108, "low": 98, "close": 105 },
        { "date": "2026-01-06", "open": 105, "high": 110, "low": 103, "close": 108 },
        { "date": "2026-01-07", "open": 108, "high": 109, "low": 101, "close": 103 },
        { "date": "2026-01-08", "open": 103, "high": 107, "low": 100, "close": 106 }
      ]
    }
  ]
}
"""

    /** 四根影线。 */
    @TestCase
    public func drawsWicks(): Unit {
        @Assert(count(draw(sample), "class=\"candlestick-wick\"") == 4)
    }

    /** 四个实体。 */
    @TestCase
    public func drawsBodies(): Unit {
        @Assert(count(draw(sample), "candlestick-body") == 4)
    }

    /** 涨跌标识。 */
    @TestCase
    public func drawsDirection(): Unit {
        let svg = draw(sample)
        @Assert(count(svg, "candlestick-up") == 3)
        @Assert(count(svg, "candlestick-down") == 1)
    }

    /** 涨跌判定。 */
    @TestCase
    public func comparesOpenClose(): Unit {
        @Assert(candlestickUp(100.0, 105.0))
        @Assert(!candlestickUp(108.0, 103.0))
        @Assert(candlestickUp(100.0, 100.0))
    }

    /** 轴与日期。 */
    @TestCase
    public func drawsAxes(): Unit {
        let svg = draw(sample)
        @Assert(svg.contains("2026-01-05"))
        @Assert(svg.contains("价格"))
    }

    /** 最高价过低。 */
    @TestCase
    public func rejectsBadHigh(): Unit {
        let json = """
{
  "type": "candlestick",
  "xAxis": { "type": "category", "labels": ["D1"] },
  "series": [
    { "name": "S", "data": [
      { "date": "D1", "open": 100, "high": 101, "low": 98, "close": 105 }
    ] }
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

    /** 缺少收盘价。 */
    @TestCase
    public func rejectsMissingClose(): Unit {
        let json = """
{
  "type": "candlestick",
  "xAxis": { "type": "category", "labels": ["D1"] },
  "series": [
    { "name": "S", "data": [
      { "date": "D1", "open": 100, "high": 108, "low": 98 }
    ] }
  ]
}
"""
        try {
            draw(json)
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.MissingField)
        }
    }

    /** 类目长度不匹配。 */
    @TestCase
    public func rejectsLabelMismatch(): Unit {
        let json = """
{
  "type": "candlestick",
  "xAxis": { "type": "category", "labels": ["D1", "D2"] },
  "series": [
    { "name": "S", "data": [
      { "date": "D1", "open": 100, "high": 108, "low": 98, "close": 105 }
    ] }
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
  "type": "line",
  "xAxis": { "type": "category", "labels": ["D1"] },
  "series": [
    { "name": "S", "data": [
      { "date": "D1", "open": 100, "high": 108, "low": 98, "close": 105 }
    ] }
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
