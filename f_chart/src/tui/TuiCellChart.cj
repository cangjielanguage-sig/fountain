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

import fountain::f_data.json.JsonObject

/**
 * 可逐单元格读取的 TUI 图表。
 *
 * 宿主（例如 fprobe 的 TUI）需要把字符画写进自己的缓冲时，解析 ANSI 既慢又容易
 * 在宽字符上错位；`drawCells` 直接返回符号矩阵：
 *
 * - 外层是行，每行恰好 `width` 个元素；
 * - 宽字符的后半格是空字符串，宿主跳过该列但列号继续前进；
 * - 元素不含任何 ANSI 转义。
 *
 * `draw` 的行为不变，仍返回 ANSI 字符串。
 */
public interface TuiCellChart {
    func drawCells(data: JsonObject): Array<Array<String>>
}
