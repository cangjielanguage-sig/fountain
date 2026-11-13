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
public class ControlChart_test {
    private func draw(json: String): String {
        ControlChart().draw(JsonValue.fromStr(json).asObject())
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
  "type": "control",
  "title": "过程控制图",
  "xAxis": { "type": "category", "labels": ["1", "2", "3", "4", "5", "6", "7", "8"] },
  "yAxis": { "type": "linear", "title": "测量值" },
  "legend": { "show": false },
  "series": [
    {
      "name": "测量值",
      "data": [50.2, 49.8, 50.5, 50.1, 51.2, 49.5, 50.0, 50.3],
      "center": 50.0,
      "ucl": 51.5,
      "lcl": 48.5
    }
  ]
}
"""

    /** 折线、八个点、三条参考线。 */
    @TestCase
    public func drawsLinePointsAndLimits(): Unit {
        let svg = draw(sample)
        @Assert(count(svg, "class=\"control-line\"") == 1)
        @Assert(count(svg, "class=\"control-point\"") == 8)
        @Assert(count(svg, "class=\"control-outlier\"") == 0)
        @Assert(count(svg, "class=\"control-center\"") == 1)
        @Assert(count(svg, "class=\"control-ucl\"") == 1)
        @Assert(count(svg, "class=\"control-lcl\"") == 1)
    }

    /** 越限点使用 control-outlier。 */
    @TestCase
    public func marksOutliers(): Unit {
        let svg = draw("""
{
  "type": "control",
  "xAxis": { "type": "category", "labels": ["1", "2", "3"] },
  "legend": { "show": false },
  "series": [
    { "name": "测量值", "data": [50.2, 49.8, 52.0], "center": 50.0, "ucl": 51.5, "lcl": 48.5 }
  ]
}
""")
        @Assert(count(svg, "class=\"control-outlier\"") == 1)
        @Assert(count(svg, "class=\"control-point\"") == 2)
    }

    /** 缺省标签使用序号。 */
    @TestCase
    public func usesIndexLabels(): Unit {
        let svg = draw("""
{
  "type": "control",
  "legend": { "show": false },
  "series": [ { "name": "测量值", "data": [1, 2, 3], "center": 2, "ucl": 3, "lcl": 1 } ]
}
""")
        @Assert(count(svg, "class=\"control-point\"") == 3)
    }

    /** 均值。 */
    @TestCase
    public func computesMean(): Unit {
        @Assert(abs(controlMean([3.0, 5.0, 7.0]) - 5.0) < 1e-9)
    }

    /** 样本标准差（分母 n−1）。 */
    @TestCase
    public func computesStdDev(): Unit {
        @Assert(abs(controlStdDev([3.0, 5.0, 7.0]) - 2.0) < 1e-9)
    }

    /** 自动控制限：均值 ± 3σ。 */
    @TestCase
    public func computesAutoLimits(): Unit {
        let limits = resolveControlLimits([3.0, 5.0, 7.0], None, None, None, None)
        @Assert(abs(limits.center - 5.0) < 1e-9)
        @Assert(abs(limits.ucl - 11.0) < 1e-9)
        @Assert(abs(limits.lcl - (-1.0)) < 1e-9)
    }

    /** sigma 覆盖样本标准差。 */
    @TestCase
    public func honorsSigma(): Unit {
        let limits = resolveControlLimits([3.0, 5.0, 7.0], None, None, None, Some(1.0))
        @Assert(abs(limits.ucl - 8.0) < 1e-9)
        @Assert(abs(limits.lcl - 2.0) < 1e-9)
    }

    /** 显式控制限优先。 */
    @TestCase
    public func honorsExplicitLimits(): Unit {
        let limits = resolveControlLimits([3.0, 5.0, 7.0], Some(4.0), Some(9.0), Some(0.5), None)
        @Assert(abs(limits.center - 4.0) < 1e-9)
        @Assert(abs(limits.ucl - 9.0) < 1e-9)
        @Assert(abs(limits.lcl - 0.5) < 1e-9)
    }

    /** 控制限倒置。 */
    @TestCase
    public func rejectsInvertedLimits(): Unit {
        try {
            draw("""
{
  "type": "control",
  "legend": { "show": false },
  "series": [ { "name": "测量值", "data": [1, 2, 3], "ucl": 1, "lcl": 3 } ]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** sigma 为负。 */
    @TestCase
    public func rejectsNegativeSigma(): Unit {
        try {
            draw("""
{
  "type": "control",
  "legend": { "show": false },
  "series": [ { "name": "测量值", "data": [1, 2, 3], "sigma": -1 } ]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 标签长度不一致。 */
    @TestCase
    public func rejectsLengthMismatch(): Unit {
        try {
            draw("""
{
  "type": "control",
  "xAxis": { "type": "category", "labels": ["1", "2", "3"] },
  "legend": { "show": false },
  "series": [ { "name": "测量值", "data": [1, 2, 3, 4] } ]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 空数据。 */
    @TestCase
    public func rejectsEmptyData(): Unit {
        try {
            draw("""
{
  "type": "control",
  "legend": { "show": false },
  "series": [ { "name": "测量值", "data": [] } ]
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
{ "type": "control" }
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
  "type": "bar",
  "series": [ { "name": "测量值", "data": [1] } ]
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
