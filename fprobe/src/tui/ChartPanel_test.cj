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
package fountain::fprobe.tui

import std.unittest.*
import std.unittest.testmacro.*

/** `ChartPanel`：数据到 f_chart.tui 单元格矩阵的适配。 */
@Test
public class ChartPanel_test {
    private let values: Array<Float64> = [1.0, 3.0, 2.0, 5.0, 4.0, 6.0]

    @TestCase
    public func jsonCarriesTypeSizeAndSeries(): Unit {
        let json = ChartPanel.chartJson("line", "使用率", values, 40, 12).getOrThrow()
        @Assert(json.get("type").getOrThrow().asString().value, "line")
        @Assert(json.get("width").getOrThrow().asInt().toInt64(), 40)
        @Assert(json.get("height").getOrThrow().asInt().toInt64(), 12)
        @Assert(json.get("title").getOrThrow().asString().value, "")
        let series = json.get("series").getOrThrow().asArray()
        @Assert(series.size, 1)
        let first = series[0].asObject()
        @Assert(first.get("name").getOrThrow().asString().value, "使用率")
        @Assert(first.get("data").getOrThrow().asArray().size, 6)
        let axis = json.get("xAxis").getOrThrow().asObject()
        @Assert(axis.get("type").getOrThrow().asString().value, "category")
        @Assert(axis.get("labels").getOrThrow().asArray().isEmpty())
    }

    @TestCase
    public func invalidInputsReturnNone(): Unit {
        @Assert(ChartPanel.chartJson("line", "s", [], 40, 12).isNone())
        @Assert(ChartPanel.chartJson("line", "s", [Float64.NaN], 40, 12).isNone())
        @Assert(ChartPanel.chartJson("line", "s", values, 19, 12).isNone())
        @Assert(ChartPanel.chartJson("line", "s", values, 40, 7).isNone())
        @Assert(ChartPanel.chartJson("pie", "s", values, 40, 12).isNone())
    }

    @TestCase
    public func lineCellsHaveRequestedShape(): Unit {
        let cells = ChartPanel.render("line", "cpu", values, 40, 12).getOrThrow()
        @Assert(cells.size, 12)
        var hasMarker = false
        for (row in cells) {
            @Assert(row.size, 40)
            for (cell in row) {
                if (cell == "*" || cell == "o") {
                    hasMarker = true
                }
            }
        }
        @Assert(hasMarker)
    }

    @TestCase
    public func barCellsContainBlocks(): Unit {
        let cells = ChartPanel.render("bar", "disk", values, 40, 12).getOrThrow()
        @Assert(cells.size, 12)
        var hasBlock = false
        for (row in cells) {
            @Assert(row.size, 40)
            for (cell in row) {
                if (cell == "█") {
                    hasBlock = true
                }
            }
        }
        @Assert(hasBlock)
    }
}
