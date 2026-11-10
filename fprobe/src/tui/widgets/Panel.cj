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
import ratatui_style.{Color, Modifier, Style}

/**
 * 最小 panel：单线边框 + 顶部内嵌标题。
 *
 * 只操作 `Buffer` 单元格，不承担业务语义；内容区域由返回值给出，
 * 排布交给 `FprobePainter`。
 */
public class Panel {
    /** 绘制边框并返回内容区域；区域过小时返回空矩形。 */
    public static func draw(buffer: Buffer, area: Rect, title: String,
        accent!: Color = Color.Cyan): Rect {
        if (area.width < 2 || area.height < 2) {
            return Rect(area.x, area.y, 0, 0)
        }
        let borderStyle = Style().withFg(accent)
        put(buffer, area.x, area.y, "┌", borderStyle)
        put(buffer, area.right() - 1, area.y, "┐", borderStyle)
        put(buffer, area.x, area.bottom() - 1, "└", borderStyle)
        put(buffer, area.right() - 1, area.bottom() - 1, "┘", borderStyle)

        var x = area.x + 1
        while (x < area.right() - 1) {
            put(buffer, x, area.y, "─", borderStyle)
            put(buffer, x, area.bottom() - 1, "─", borderStyle)
            x += 1
        }
        var y = area.y + 1
        while (y < area.bottom() - 1) {
            put(buffer, area.x, y, "│", borderStyle)
            put(buffer, area.right() - 1, y, "│", borderStyle)
            y += 1
        }

        if (!title.isEmpty() && area.width > 4) {
            let titleStyle = Style().withFg(accent).withAddModifier(Modifier.BOLD)
            buffer.setStringn(area.x + 2, area.y, " ${title} ", area.width - 4, titleStyle)
        }
        Rect(area.x + 1, area.y + 1, area.width - 2, area.height - 2)
    }

    private static func put(buffer: Buffer, x: UInt16, y: UInt16, symbol: String,
        style: Style): Unit {
        buffer.setString(x, y, symbol, style)
    }
}
