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
import fountain::f_tui.term.TuiSize
import ratatui_buffer.Buffer
import ratatui_text.unicodeWidth

/** 记录调用并把最近一帧 Buffer 留给用例断言的假 renderer。 */
class RecordingFrameRenderer <: FrameRenderer {
    private let width: UInt16
    private let height: UInt16
    private let startResult: Bool
    public var starts = 0
    public var draws = 0
    public var flushes = 0
    public var restores = 0
    public var lastBuffer: ?Buffer = None<Buffer>

    init(width!: UInt16 = 80, height!: UInt16 = 24, startResult!: Bool = true) {
        this.width = width
        this.height = height
        this.startResult = startResult
    }

    public func start(): Bool {
        starts += 1
        startResult
    }

    public func restore(): Unit {
        restores += 1
    }

    public func size(): TuiSize {
        TuiSize(width, height)
    }

    public func draw(buffer: Buffer): Unit {
        draws += 1
        lastBuffer = Some(buffer)
    }

    public func flush(): Bool {
        flushes += 1
        true
    }
}

/**
 * 按显示宽度读取一行，跳过宽字符的占位单元。
 *
 * `Buffer.line()` 会把宽字符的第二列也拼进字符串，中文断言会多出空格；
 * 这里按单元格符号宽度还原肉眼看到的一行。
 */
func displayRow(buffer: Buffer, row: Int64): String {
    var result = ""
    var x: UInt16 = 0
    var skipNext = false
    while (x < buffer.area.width) {
        if (skipNext) {
            skipNext = false
            x += 1
            continue
        }
        let symbol = buffer.get(x, UInt16(row)).symbol()
        result += symbol
        if (unicodeWidth(symbol) >= 2) {
            skipNext = true
        }
        x += 1
    }
    result
}

func samplePlan(): RenderPlan {
    RenderPlan(
        "fprobe  节点 2  告警 1  刷新 1000ms",
        ["▸ node-a  在线", "  node-b  离线"],
        "node-a",
        0,
        "CPU",
        [["使用率", "42%"], ["iowait", "1.5%"]],
        [SparkSeries("使用率", "%", [0.0, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0])],
        ["node-b 离线"],
        ""
    )
}

/** 13.4：Plan → Buffer → renderer 的机械映射与生命周期。 */
@Test
public class FprobePainter_test {
    @TestCase
    public func startDrawRestoreSmoke(): Unit {
        let renderer = RecordingFrameRenderer()
        let painter = FprobePainter(renderer)

        painter.start()
        painter.draw(samplePlan())
        painter.restore()

        @Assert(renderer.starts, 1)
        @Assert(renderer.draws, 1)
        @Assert(renderer.flushes, 1)
        @Assert(renderer.restores, 1)
    }

    @TestCase
    public func drawBuildsFullFrameWithAllRegions(): Unit {
        let renderer = RecordingFrameRenderer()
        let painter = FprobePainter(renderer)

        painter.draw(samplePlan())

        let buffer = renderer.lastBuffer.getOrThrow()
        @Assert(buffer.area.width, 80)
        @Assert(buffer.area.height, 24)
        @Assert(displayRow(buffer, 0).contains("fprobe"))
        // 左侧 panel 的左上角与标题
        @Assert(buffer.get(0, 1).symbol(), "┌")
        @Assert(displayRow(buffer, 1).contains("节点"))
        // 右侧 panel 的标题
        @Assert(displayRow(buffer, 1).contains("CPU"))
        // 指标表：标签与取值
        var sawMetric = false
        var sawValue = false
        for (row in 0..24) {
            let text = displayRow(buffer, row)
            if (text.contains("使用率")) {
                sawMetric = true
            }
            if (text.contains("42%")) {
                sawValue = true
            }
        }
        @Assert(sawMetric)
        @Assert(sawValue)
        // 底部告警行
        @Assert(displayRow(buffer, 23).contains("node-b 离线"))
    }

    @TestCase
    public func sparklineIsSampledFromSeries(): Unit {
        let renderer = RecordingFrameRenderer()
        let painter = FprobePainter(renderer)

        painter.draw(samplePlan())

        let buffer = renderer.lastBuffer.getOrThrow()
        var sawBlocks = false
        for (row in 0..24) {
            if (displayRow(buffer, row).contains("▁▂▃▄▅▆▇█")) {
                sawBlocks = true
            }
        }
        @Assert(sawBlocks)
    }

    @TestCase
    public func eachFrameDrawsAndFlushesOnce(): Unit {
        let renderer = RecordingFrameRenderer()
        let painter = FprobePainter(renderer)

        painter.draw(samplePlan())
        painter.draw(samplePlan())

        @Assert(renderer.draws, 2)
        @Assert(renderer.flushes, 2)
    }

    @TestCase
    public func unknownSizeSkipsRendering(): Unit {
        let renderer = RecordingFrameRenderer(width: 0, height: 0)
        let painter = FprobePainter(renderer)

        painter.draw(samplePlan())

        @Assert(renderer.draws, 0)
        @Assert(renderer.flushes, 0)
        @Assert(renderer.lastBuffer.isNone())
    }

    @TestCase
    public func startFailureSurfacesAsException(): Unit {
        let renderer = RecordingFrameRenderer(startResult: false)
        let painter = FprobePainter(renderer)

        var raised = false
        try {
            painter.start()
        } catch (e: Exception) {
            raised = true
        }
        @Assert(raised)
        @Assert(renderer.starts, 1)
    }
}
