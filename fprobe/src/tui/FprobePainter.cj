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

import fountain::f_probe.{ProbeErrorCode, ProbeException}
import fountain::f_tui.render.{ExitHook, Terminal}
import fountain::f_tui.term.{IoctlSizeProvider, RealPosixFfi, StdoutTerminalWriter, TuiSize}
import fountain::f_tui.term.STDOUT_FILENO as TERM_STDOUT_FILENO
import fountain::fprobe.tui.widgets.{Panel, Sparkline, Table}
import ratatui_buffer.Buffer
import ratatui_core.Rect
import ratatui_style.{Color, Modifier, Style}

/**
 * `FprobePainter` 唯一依赖的 `f_tui` 渲染面。
 *
 * 抽象出来是为了让用例注入假 renderer 断言 Buffer 内容与调用次数；
 * 生产实现是 [TerminalFrameRenderer]。
 */
public interface FrameRenderer {
    /** 进入备用屏 / raw mode；失败返回 `false`。 */
    func start(): Bool

    /** 恢复正常终端状态，必须幂等。 */
    func restore(): Unit

    /** 当前终端尺寸；未知时返回 `0x0`。 */
    func size(): TuiSize

    /** 提交一帧单元格数据。 */
    func draw(buffer: Buffer): Unit

    /** 输出差分帧。 */
    func flush(): Bool
}

/**
 * 生产 renderer：把 `f_tui.Terminal` 适配成 `FrameRenderer`。
 *
 * `Terminal.start()` 自己完成 raw mode、备用屏与光标隐藏，并在失败时抛
 * `TuiException`；这里不再额外捕获，让 `SupervisorApp` 统一记录并退出。
 */
public class TerminalFrameRenderer <: FrameRenderer {
    private let terminal: Terminal

    public init(terminal: Terminal) {
        this.terminal = terminal
    }

    public func start(): Bool {
        terminal.start()
        true
    }

    public func restore(): Unit {
        terminal.restore()
    }

    public func size(): TuiSize {
        match (terminal.size()) {
            case Some(value) => value
            case None => TuiSize(0, 0)
        }
    }

    public func draw(buffer: Buffer): Unit {
        terminal.bufferRenderer().draw(buffer)
    }

    public func flush(): Bool {
        terminal.bufferRenderer().flush()
    }
}

/**
 * 只负责 `RenderPlan → Buffer` 的机械映射（设计 D9 / D20）。
 *
 * 顶部标题条、左侧节点 panel、右侧指标 table + sparkline、底部告警条各占
 * 一个区域；panel/table/sparkline 均为自绘，不使用 `ratatui_widgets`。
 * 每帧只调用一次 `draw` 与一次 `flush`。
 */
public class FprobePainter <: Painter {
    private let renderer: FrameRenderer

    public init(renderer: FrameRenderer) {
        this.renderer = renderer
    }

    public func start(): Unit {
        if (!renderer.start()) {
            throw ProbeException(ProbeErrorCode.CONFIG, "无法进入备用屏，TUI 初始化失败")
        }
    }

    public func restore(): Unit {
        renderer.restore()
    }

    public func draw(plan: RenderPlan): Unit {
        let size = renderer.size()
        if (size.isUnknown()) {
            return
        }
        let buffer = Buffer.empty(Rect(0, 0, size.width, size.height))
        paint(buffer, plan)
        renderer.draw(buffer)
        renderer.flush()
    }

    /** 左侧节点列表宽度：约为总宽的三分之一，并夹在 16–32 列之间。 */
    private static func leftPanelWidth(width: UInt16): UInt16 {
        var value = Int64(width) / 3
        if (value < 16) {
            value = 16
        }
        if (value > 32) {
            value = 32
        }
        if (value > Int64(width) - 8) {
            value = Int64(width) / 2
        }
        if (value < 8) {
            value = 8
        }
        UInt16(value)
    }

    private func paint(buffer: Buffer, plan: RenderPlan): Unit {
        let width = buffer.area.width
        let height = buffer.area.height
        let titleStyle = Style().withFg(Color.Cyan).withAddModifier(Modifier.BOLD)
        buffer.setStringn(0, 0, plan.title, width, titleStyle)
        if (height < 4 || width < 8) {
            return
        }

        let bodyHeight = height - 2
        let leftWidth = FprobePainter.leftPanelWidth(width)
        let rightWidth = width - leftWidth
        paintNodes(buffer, Rect(0, 1, leftWidth, bodyHeight), plan)
        if (rightWidth >= 4) {
            paintMetrics(buffer, Rect(leftWidth, 1, rightWidth, bodyHeight), plan)
        }
        paintFooter(buffer, Rect(0, height - 1, width, 1), plan)
    }

    private func paintNodes(buffer: Buffer, area: Rect, plan: RenderPlan): Unit {
        let inner = Panel.draw(buffer, area, "节点")
        if (inner.width == 0 || inner.height == 0) {
            return
        }
        var y = inner.y
        var index: Int64 = 0
        for (row in plan.nodeRows) {
            if (y >= inner.bottom()) {
                break
            }
            let style = if (index == plan.selectedIndex) {
                Style().withFg(Color.Cyan).withAddModifier(Modifier.BOLD)
            } else {
                Style()
            }
            buffer.setStringn(inner.x, y, row, inner.width, style)
            y += 1
            index += 1
        }
    }

    private func paintMetrics(buffer: Buffer, area: Rect, plan: RenderPlan): Unit {
        let inner = Panel.draw(buffer, area, plan.pageTitle)
        if (inner.width == 0 || inner.height == 0) {
            return
        }
        var y = inner.y
        for (row in plan.metricRows) {
            if (y >= inner.bottom()) {
                break
            }
            Table.draw(buffer, Rect(inner.x, y, inner.width, 1), [row])
            y += 1
        }
        if (plan.series.isEmpty() || y >= inner.bottom()) {
            return
        }
        // 指标表与 sparkline 之间保留一行空白，避免视觉粘连。
        if (y + 1 < inner.bottom()) {
            y += 1
        }
        for (series in plan.series) {
            if (y >= inner.bottom()) {
                break
            }
            paintSeries(buffer, Rect(inner.x, y, inner.width, 1), series)
            y += 1
        }
    }

    private func paintSeries(buffer: Buffer, area: Rect, series: SparkSeries): Unit {
        var labelWidth: UInt16 = 0
        if (area.width > 12) {
            labelWidth = 8
        }
        if (labelWidth > 0) {
            buffer.setStringn(area.x, area.y, series.name, labelWidth,
                Style().withFg(Color.Gray))
        }
        var offset: UInt16 = 0
        if (labelWidth > 0) {
            offset = labelWidth + 1
        }
        if (offset >= area.width) {
            return
        }
        Sparkline.draw(buffer, Rect(area.x + offset, area.y, area.width - offset, 1),
            series.values, style: Style().withFg(Color.Green))
    }

    private func paintFooter(buffer: Buffer, area: Rect, plan: RenderPlan): Unit {
        let text = if (!plan.alarmRows.isEmpty()) {
            "告警: " + join(plan.alarmRows, " | ")
        } else if (!plan.note.isEmpty()) {
            plan.note
        } else {
            "无告警"
        }
        let style = if (!plan.alarmRows.isEmpty()) {
            Style().withFg(Color.Yellow)
        } else {
            Style().withFg(Color.Gray)
        }
        buffer.setStringn(area.x, area.y, text, area.width, style)
    }

    private func join(values: Array<String>, separator: String): String {
        let builder = StringBuilder()
        var first = true
        for (value in values) {
            if (!first) {
                builder.append(separator)
            }
            builder.append(value)
            first = false
        }
        builder.toString()
    }
}

/**
 * `f_tui` 的 `SystemExitHook` 会覆盖 `f_base.ExitCallbacks` 注册的 SIGINT/SIGTERM
 * 处理器，只做终端恢复而不停后台组件；生产装配改用被动钩子，让
 * `SupervisorApp.shutdown()` 成为唯一退出路径。
 */
private class PassiveExitHook <: ExitHook {
    public init() {}

    public func register(_: () -> Unit): Unit {}
}

/** 生产 painter：真实终端 + `TerminalFrameRenderer`。 */
public func systemPainter(): Painter {
    let ffi = RealPosixFfi()
    let terminal = Terminal(ffi, StdoutTerminalWriter(ffi, TERM_STDOUT_FILENO),
        IoctlSizeProvider(ffi, TERM_STDOUT_FILENO), exitHook: PassiveExitHook())
    FprobePainter(TerminalFrameRenderer(terminal))
}
