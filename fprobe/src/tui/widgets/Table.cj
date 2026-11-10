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
 * 最小两列 table：每个元素是一行，`row[0]` 为标签、`row[1]`（可选）为取值。
 *
 * 标签列宽固定或按区域一半计算，超宽文本由 `Buffer.setStringn` 裁剪；
 * 不做排序、分页或滚动，滚动由上层 ViewModel 决定。
 */
public class Table {
    /** 绘制行；`labelWidth` 为负时按区域宽度自动分配。 */
    public static func draw(buffer: Buffer, area: Rect, rows: Array<Array<String>>,
        labelWidth!: Int64 = -1, labelStyle!: ?Style = None<Style>,
        valueStyle!: ?Style = None<Style>): Unit {
        if (area.width == 0 || area.height == 0) {
            return
        }
        let totalWidth = Int64(area.width)
        var width = if (labelWidth >= 0) {
            labelWidth
        } else if (totalWidth > 1) {
            totalWidth / 2
        } else {
            totalWidth
        }
        if (width > totalWidth) {
            width = totalWidth
        }
        let labels = match (labelStyle) {
            case Some(value) => value
            case None => Style()
        }
        let values = match (valueStyle) {
            case Some(value) => value
            case None => Style().withFg(Color.Green)
        }

        var y = area.y
        for (row in rows) {
            if (y >= area.bottom()) {
                break
            }
            if (!row.isEmpty()) {
                buffer.setStringn(area.x, y, row[0], UInt16(width), labels)
            }
            if (row.size > 1 && width < totalWidth) {
                let start = area.x + UInt16(width) + 1
                buffer.setStringn(start, y, row[1], UInt16(totalWidth - width - 1), values)
            }
            y += 1
        }
    }
}
