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
package fountain::f_chart.tui

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_chart.*
import fountain::f_data.json.*

@Test
public class TuiFrame_test {
    private func config(json: String): ChartConfig {
        ChartConfig.parse(
            JsonValue.fromStr(json).asObject(), "bar",
            defaultWidth: 80.0, defaultHeight: 24.0
        )
    }

    private func text(canvas: TuiCanvas): String {
        let builder = StringBuilder()
        for (line in canvas.plainLines()) {
            builder.append(line)
            builder.append("\n")
        }
        builder.toString()
    }

    private let sample: String = """
{
  "type": "bar",
  "title": "月度销售额",
  "width": 40,
  "height": 12,
  "xAxis": { "type": "category", "labels": ["一月", "二月", "三月"] },
  "yAxis": { "type": "linear", "min": 0, "max": 100 },
  "series": [ { "name": "销售额", "data": [30, 60, 90] } ]
}
"""

    /** 标题与副标题占行。 */
    @TestCase
    public func drawsTitle(): Unit {
        let cfg = config(sample)
        let canvas = TuiCanvas(40, 12)
        let frame = TuiFrame(cfg, 4)
        frame.drawTitle(canvas)
        @Assert(text(canvas).contains("月度销售额"))
    }

    /** 图例包含色块与系列名。 */
    @TestCase
    public func drawsLegend(): Unit {
        let cfg = config(sample)
        let canvas = TuiCanvas(40, 12)
        let frame = TuiFrame(cfg, 4, legendVisible: true)
        frame.drawLegend(canvas, ["销售额", "利润"], ["#4e79a7", "#f28e2b"])
        let plain = text(canvas)
        @Assert(plain.contains("■"))
        @Assert(plain.contains("销售额"))
        @Assert(plain.contains("利润"))
    }

    /** 纵轴刻度、网格与轴线。 */
    @TestCase
    public func drawsYAxis(): Unit {
        let cfg = config(sample)
        let canvas = TuiCanvas(40, 12)
        let frame = TuiFrame(cfg, 4)
        let scale = LinearScale(0.0, 100.0, Float64(frame.plot.y), Float64(frame.plot.bottom()))
        frame.drawYAxis(canvas, [0.0, 50.0, 100.0], scale)
        let plain = text(canvas)
        @Assert(plain.contains("100"))
        @Assert(plain.contains("·"))
        @Assert(plain.contains("│"))
    }

    /** 类目横轴的轴角与标签。 */
    @TestCase
    public func drawsCategoryAxis(): Unit {
        let cfg = config(sample)
        let canvas = TuiCanvas(40, 12)
        let frame = TuiFrame(cfg, 4)
        let band = BandScale(
            Float64(frame.plot.x), Float64(frame.plot.right()),
            cfg.xAxis.labels.size
        )
        frame.drawXAxisCategory(canvas, cfg.xAxis.labels, band)
        let plain = text(canvas)
        @Assert(plain.contains("└"))
        @Assert(plain.contains("一月"))
        @Assert(plain.contains("三月"))
    }

    /** 画布过小。 */
    @TestCase
    public func rejectsTinyCanvas(): Unit {
        let cfg = config("""
{ "type": "bar", "width": 10, "height": 5, "series": [ { "name": "S", "data": [1] } ] }
""")
        try {
            TuiFrame(cfg, 4)
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }
}
