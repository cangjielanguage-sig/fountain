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
public class WaffleChart_test {
    private func draw(json: String): String {
        WaffleChart().draw(JsonValue.fromStr(json).asObject())
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
  "type": "waffle",
  "title": "预算分配",
  "width": 520,
  "height": 520,
  "cells": 100,
  "columns": 10,
  "series": [
    {
      "name": "预算",
      "data": [
        { "name": "研发", "value": 42 },
        { "name": "市场", "value": 28 },
        { "name": "运营", "value": 18 },
        { "name": "其他", "value": 12 }
      ]
    }
  ]
}
"""

    /** 一百个方格。 */
    @TestCase
    public func drawsCells(): Unit {
        @Assert(count(draw(sample), "class=\"waffle-cell\"") == 100)
    }

    /** 四个图例。 */
    @TestCase
    public func drawsLegend(): Unit {
        let svg = draw(sample)
        @Assert(count(svg, "class=\"waffle-legend\"") == 4)
        @Assert(svg.contains("研发"))
    }

    /** 整比取整。 */
    @TestCase
    public func keepsExactCounts(): Unit {
        let counts = waffleCellCounts([42.0, 28.0, 18.0, 12.0], 100)
        @Assert(counts.size == 4)
        @Assert(counts[0] == 42)
        @Assert(counts[1] == 28)
        @Assert(counts[2] == 18)
        @Assert(counts[3] == 12)
    }

    /** 均分余数。 */
    @TestCase
    public func distributesRemainder(): Unit {
        let counts = waffleCellCounts([1.0, 1.0, 1.0], 10)
        @Assert(counts.size == 3)
        @Assert(counts[0] == 4)
        @Assert(counts[1] == 3)
        @Assert(counts[2] == 3)
        var total = 0
        for (count in counts) {
            total += count
        }
        @Assert(total == 10)
    }

    /** 不整除的行数。 */
    @TestCase
    public func handlesPartialRow(): Unit {
        let json = """
{
  "type": "waffle",
  "cells": 10,
  "columns": 4,
  "series": [
    { "name": "A", "data": [ { "name": "a", "value": 1 }, { "name": "b", "value": 1 } ] }
  ]
}
"""
        @Assert(count(draw(json), "class=\"waffle-cell\"") == 10)
    }

    /** 格数为零。 */
    @TestCase
    public func rejectsZeroCells(): Unit {
        let json = """
{
  "type": "waffle",
  "cells": 0,
  "series": [
    { "name": "A", "data": [ { "name": "a", "value": 1 } ] }
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

    /** 列数为负。 */
    @TestCase
    public func rejectsNegativeColumns(): Unit {
        let json = """
{
  "type": "waffle",
  "columns": -2,
  "series": [
    { "name": "A", "data": [ { "name": "a", "value": 1 } ] }
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

    /** 全零数据。 */
    @TestCase
    public func rejectsZeroTotal(): Unit {
        let json = """
{
  "type": "waffle",
  "series": [
    { "name": "A", "data": [ { "name": "a", "value": 0 } ] }
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
  "type": "rose",
  "series": [
    { "name": "A", "data": [ { "name": "a", "value": 1 } ] }
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
