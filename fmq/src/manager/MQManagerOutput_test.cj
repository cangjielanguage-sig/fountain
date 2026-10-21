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

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_mq.base.payload.{MQMetaSnapshot, MQTopicAssignment}

@Test
class MQManagerOutputTest {
    @TestCase
    public func cjkWidthIsTwo(): Unit {
        @Assert(MQManagerOutput.width("abc") == 3)
        @Assert(MQManagerOutput.width("主题") == 4)
        @Assert(MQManagerOutput.width("a中") == 3)
    }

    @TestCase
    public func emptyTableShowsPlaceholder(): Unit {
        @Assert(MQManagerOutput.table(["topic"], []) == "（空）")
    }

    @TestCase
    public func tableColumnsAreAligned(): Unit {
        let text = MQManagerOutput.table(["topic", "分配"], [["/a", "0→0"], ["/订单", "1→2,3→0"]])
        let lines = text.split("\n")
        @Assert(lines.size == 3)
        // 每行的显示宽度一致（含分隔符）
        let first = MQManagerOutput.width(lines[0])
        @Assert(MQManagerOutput.width(lines[1]) == first)
        @Assert(MQManagerOutput.width(lines[2]) == first)
    }

    @TestCase
    public func errorUsesStablePrefix(): Unit {
        let text = MQManagerOutput.error("boom")
        @Assert(text.startsWith(MQManagerOutput.ERROR_PREFIX))
        @Assert(text.contains("boom"))
    }

    // ================================================================
    // 子命令输出内容（manager-cli「输出可断言」）
    // ================================================================

    /** 场景「注册主题输出」：文本含主题、队列数与每个队列的 owner。 */
    @TestCase
    public func registeredTopicOutputHasTopicCountAndOwners(): Unit {
        let text = MQManagerOutput.registeredTopic("/order", 4, 0, [0, 1, 2, 0])
        @Assert(text.contains("/order"))
        @Assert(text.contains("队列 0..3（共 4 个）"))
        @Assert(text.contains("0→0"))
        @Assert(text.contains("1→1"))
        @Assert(text.contains("2→2"))
        @Assert(text.contains("3→0"))
        @Assert(text.contains("0s"))
    }

    /** 场景「列表输出」：每条主题一行，含主题、队列数、延迟与分配。 */
    @TestCase
    public func topicListRendersOneRowPerTopic(): Unit {
        let snapshot = MQMetaSnapshot([
            MQTopicAssignment("/order", 2, 0, [0, 1], delayingMs: 61000),
            MQTopicAssignment("/audit", 1, 1, [1])
        ], [], 2)
        let lines = MQManagerOutput.topicList(snapshot).split("\n")
        @Assert(lines.size == 3)

        let header = lines[0].split(" | ")
        @Assert(header.size == 4)
        @Assert(header[0].startsWith("topic"))
        @Assert(header[1].startsWith("queueNum"))
        @Assert(header[2].startsWith("delaying"))
        @Assert(header[3].startsWith("分配"))

        @Assert(lines[1].contains("/order"))
        @Assert(lines[1].contains("2"))
        @Assert(lines[1].contains("1m1s"))
        @Assert(lines[1].contains("0→0,1→1"))

        @Assert(lines[2].contains("/audit"))
        @Assert(lines[2].contains("1"))
        @Assert(lines[2].contains("0s"))
        @Assert(lines[2].contains("0→1"))
    }

    /** 空快照走统一占位。 */
    @TestCase
    public func emptyTopicListShowsPlaceholder(): Unit {
        @Assert(MQManagerOutput.topicList(MQMetaSnapshot([], [], 0)) == MQManagerOutput.EMPTY)
    }

    /** 场景「统计输出」：2 行 R 记录 → 表头 + 2 行数据，列数与 metrics 规格一致。 */
    @TestCase
    public func statsRendersHeaderAndTwoRows(): Unit {
        let text = "#\t0\t1729500000000\n" +
            "R\t/order\tg1\t2\t61000\t5\t120\t9\t7\t1\t0\t2\t3\t4\n" +
            "R\t/audit\t\t1\t0\t0\t0\t3\t3\t0\t1\t0\t0\t0\n"
        let lines = MQManagerOutput.stats(text).split("\n")
        @Assert(lines.size == 3)

        let header = lines[0].split(" | ")
        @Assert(header.size == MQManagerOutput.STATS_HEADER.size)
        @Assert(header[0].startsWith("topic"))
        @Assert(header[1].startsWith("group"))
        @Assert(header[4].startsWith("backlog"))
        @Assert(header[9].startsWith("deadLettered"))
        @Assert(header[10].startsWith("skippedUnreadable"))
        @Assert(header[11].startsWith("skippedNoMatch"))
        @Assert(header[12].startsWith("skippedUnsupported"))

        @Assert(lines[1].contains("/order"))
        @Assert(lines[1].contains("g1"))
        @Assert(lines[1].contains("1m1s"))
        @Assert(lines[1].contains("5"))
        @Assert(lines[1].contains("120"))
        @Assert(lines[1].contains("2"))
        @Assert(lines[1].contains("4"))

        // 空组名渲染为「（无）」，不能留空格子
        @Assert(lines[2].contains("/audit"))
        @Assert(lines[2].contains("（无）"))
        @Assert(lines[2].contains("1"))
    }

    /** 旧服务端只给 11 列：新增的三个跳过计数按 0 渲染，不报格式错误（兼容）。 */
    @TestCase
    public func statsAcceptsLegacyElevenColumns(): Unit {
        let text = "R\t/order\tg1\t2\t61000\t5\t120\t9\t7\t1\t0\n"
        let lines = MQManagerOutput.stats(text).split("\n")
        @Assert(lines.size == 2)
        @Assert(lines[1].contains("/order"))
        @Assert(lines[1].contains("0"))
    }

    /**
     * 非 `R` 行被跳过；`R` 行列数不足属「响应格式不正确」，必须显式失败而不是静默丢弃。
     */
    @TestCase
    public func statsRejectsShortRowsAsProtocolError(): Unit {
        @Assert(MQManagerOutput.stats("#\t0\t1\nT\ttopic\tgroup\n") == MQManagerOutput.EMPTY)
        var failed = false
        try {
            MQManagerOutput.stats("#\t0\t1\nR\t/t\tg\t1\n")
        } catch (e: MQServiceFailure) {
            failed = e.message.contains("服务端响应格式不正确")
        }
        @Assert(failed)
    }

    /** 数值列不可解析同样是协议错误，不得静默产出空表。 */
    @TestCase
    public func statsRejectsNonNumericColumns(): Unit {
        var failed = false
        try {
            MQManagerOutput.stats("R\t/t\tg\t1\tabc\t0\t0\t0\t0\t0\t0\n")
        } catch (e: MQServiceFailure) {
            failed = e.message.contains("服务端响应格式不正确")
        }
        @Assert(failed)
    }
}
