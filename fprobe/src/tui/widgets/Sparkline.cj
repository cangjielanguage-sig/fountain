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
package fountain::fprobe.tui.widgets

import ratatui_buffer.Buffer
import ratatui_core.Rect
import ratatui_style.{Color, Style}

/**
 * 最小 sparkline：把数值序列映射为八级方块字符。
 *
 * 只取窗口末尾、宽度允许的采样点；最大值归一化到最高方块，
 * 全零序列按全零绘制而不是除零。
 */
public class Sparkline {
    private static let BLOCKS: Array<String> = ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]

    public static func draw(buffer: Buffer, area: Rect, values: Array<Float64>,
        style!: ?Style = None<Style>): Unit {
        if (values.isEmpty() || area.width == 0 || area.height == 0) {
            return
        }
        var maximum = 0.0
        for (value in values) {
            if (value > maximum) {
                maximum = value
            }
        }
        if (maximum <= 0.0) {
            maximum = 1.0
        }
        let blocks = match (style) {
            case Some(value) => value
            case None => Style().withFg(Color.Green)
        }
        let visible = if (Int64(values.size) < Int64(area.width)) {
            Int64(values.size)
        } else {
            Int64(area.width)
        }
        let start = Int64(values.size) - visible
        var x: Int64 = 0
        while (x < visible) {
            var ratio = values[start + x] / maximum
            if (ratio < 0.0) {
                ratio = 0.0
            }
            if (ratio > 1.0) {
                ratio = 1.0
            }
            var level = Int64(ratio * 7.0 + 0.5)
            if (level < 0) {
                level = 0
            }
            if (level > 7) {
                level = 7
            }
            buffer.setString(area.x + UInt16(x), area.y, BLOCKS[level], blocks)
            x += 1
        }
    }
}
