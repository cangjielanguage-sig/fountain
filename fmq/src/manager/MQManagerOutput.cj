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
package fountain::fmq.manager


/** 管理端输出渲染：表格对齐（CJK 按显示宽度 2）与统一错误前缀。 */
public class MQManagerOutput {
    /** 错误输出统一前缀，便于脚本匹配。 */
    public static let ERROR_PREFIX = "错误："

    /** 空结果占位。 */
    public static let EMPTY = "（空）"

    public static func error(message: String): String {
        "${ERROR_PREFIX}${message}"
    }

    /** 按显示宽度计算（ASCII = 1，其余 = 2）。 */
    public static func width(text: String): Int64 {
        var total = 0i64
        for (r in text.toRuneArray()) {
            if (UInt32(r) < 0x80u32) {
                total += 1
            } else {
                total += 2
            }
        }
        total
    }

    private static func pad(text: String, target: Int64): String {
        let missing = target - width(text)
        if (missing <= 0) {
            text
        } else {
            let out = StringBuilder(text)
            for (_ in 0..missing) {
                out.append(' ')
            }
            out.toString()
        }
    }

    /** 渲染表格；`rows` 为空时返回「（空）」。 */
    public static func table(header: Array<String>, rows: Array<Array<String>>): String {
        if (rows.size == 0) {
            return EMPTY
        }
        let columns = header.size
        let widths = Array<Int64>(columns) {i => width(header[i])}
        for (row in rows) {
            for (i in 0..columns) {
                let w = if (i < row.size) {
                    width(row[i])
                } else {
                    0
                }
                if (w > widths[i]) {
                    widths[i] = w
                }
            }
        }
        let out = StringBuilder()
        out.append(renderRow(header, widths))
        for (row in rows) {
            out.append('\n')
            out.append(renderRow(row, widths))
        }
        out.toString()
    }

    private static func renderRow(row: Array<String>, widths: Array<Int64>): String {
        let out = StringBuilder()
        for (i in 0..widths.size) {
            if (i > 0) {
                out.append(" | ")
            }
            let cell = if (i < row.size) {
                row[i]
            } else {
                ""
            }
            out.append(pad(cell, widths[i]))
        }
        out.toString()
    }
}
