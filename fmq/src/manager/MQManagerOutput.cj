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

import std.collection.ArrayList
import std.convert.*
import fountain::f_mq.base.payload.MQMetaSnapshot

/** 管理端输出渲染：表格对齐（CJK 按显示宽度 2）与统一错误前缀。 */
public class MQManagerOutput {
    /** 错误输出统一前缀，便于脚本匹配。 */
    public static let ERROR_PREFIX = "错误："

    /** 空结果占位。 */
    public static let EMPTY = "（空）"

    /** `stats` 表格的表头；列口径与 metrics 规格一致。 */
    public static let STATS_HEADER: Array<String> = ["topic", "group", "queueNum", "delaying", "backlog",
        "lagMs", "delivered", "acked", "redelivered", "deadLettered", "skippedUnreadable", "skippedNoMatch",
        "skippedUnsupported"]

    public static func error(message: String): String {
        "${ERROR_PREFIX}${message}"
    }

    /**
     * `registerTopic` 成功文案。
     *
     * 场景要求文本含主题、队列数与每个队列的 owner，故队列总数显式写在「共 N 个」里。
     */
    public static func registeredTopic(topic: String, queueNum: Int64, delayingMs: Int64,
        owners: Array<Int64>): String {
        let delay = (Duration.millisecond * delayingMs).toString()
        "${topic} 已注册，队列 0..${queueNum - 1}（共 ${queueNum} 个），延迟：${delay}，分配：${assignments(owners)}"
    }

    /** `listTopics` 表格：topic / queueNum / delaying / 分配。 */
    public static func topicList(snapshot: MQMetaSnapshot): String {
        let rows = ArrayList<Array<String>>()
        for (assignment in snapshot.topics) {
            rows.add([assignment.topic, "${assignment.queueNum}",
                (Duration.millisecond * assignment.delayingMs).toString(), assignments(assignment.owners)])
        }
        table(["topic", "queueNum", "delaying", "分配"], rows.toArray())
    }

    /**
     * `stats` 表格：把服务端 TSV 里的 `R` 记录解析成表格。
     *
     * 服务端格式固定为 11 列（`R` + 10 个指标），列顺序见 `STATS_HEADER`；
     * 其它行（表头、分隔）与非 `R` 行一律跳过。`R` 行结构不符或数值列不可解析时抛
     * `MQServiceFailure`——这属于「服务端响应格式不正确」，不得被上层报成「无法连接」。
     */
    public static func stats(text: String): String {
        let rows = ArrayList<Array<String>>()
        for (line in text.split("\n")) {
            if (!line.startsWith("R\t")) {
                continue
            }
            let fields = line.split("\t")
            if (fields.size < 11) {
                throw MQServiceFailure(
                    "服务端响应格式不正确: stats 行列数 ${fields.size} < 11（'${line}'）")
            }
            let group = if (fields[2].size == 0) {
                "（无）"
            } else {
                fields[2]
            }
            let delayingMs = match (Int64.tryParse(fields[4])) {
                case Some(value) => value
                case None => throw MQServiceFailure(
                    "服务端响应格式不正确: stats 列 delaying='${fields[4]}' 不是整数")
            }
            let delay = (Duration.millisecond * delayingMs).toString()
            // 旧服务端只有 11 列：新增的跳过计数缺省为 0（向后兼容）
            rows.add([fields[1], group, fields[3], delay, fields[5], fields[6], fields[7], fields[8],
                fields[9], fields[10], columnOf(fields, 11), columnOf(fields, 12), columnOf(fields, 13)])
        }
        table(STATS_HEADER, rows.toArray())
    }

    /** 取第 `index` 列，缺列（旧服务端）按 `0` 处理。 */
    private static func columnOf(fields: Array<String>, index: Int64): String {
        if (index < fields.size) {
            fields[index]
        } else {
            "0"
        }
    }

    /** `0→0,1→2` 形式：队列下标 → owner 节点下标。 */
    public static func assignments(owners: Array<Int64>): String {
        let out = StringBuilder()
        for (i in 0..owners.size) {
            if (i > 0) {
                out.append(',')
            }
            out.append("${i}→${owners[i]}")
        }
        out.toString()
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
