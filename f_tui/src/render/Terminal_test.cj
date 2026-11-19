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
package fountain::f_tui.render

import fountain::f_tui.{TuiErrorCode, TuiException}
import fountain::f_tui.ansi.AnsiRenderer
import fountain::f_tui.term.*
import std.collection.ArrayList
import std.unittest.*
import std.unittest.testmacro.*

class LifecycleFfi <: PosixFfi {
    public var tty: Bool = true
    public var termiosValue: Termios = Termios()
    public var calls: ArrayList<String> = ArrayList<String>()

    public init() {}

    public func isTty(fd: Int32): Bool {
        calls.add("isatty")
        tty
    }

    public func getTermios(fd: Int32): Option<Termios> {
        calls.add("tcgetattr")
        Some(termiosValue)
    }

    public func setTermios(fd: Int32, value: Termios): Bool {
        calls.add("tcsetattr")
        termiosValue = value
        true
    }

    public func windowSize(fd: Int32): Option<WinSize> {
        calls.add("ioctl")
        Some(winSize(80, 24))
    }

    public func readByte(fd: Int32, timeoutMs: Int64): Option<UInt8> {
        None
    }

    public func writeBytes(fd: Int32, bytes: Array<UInt8>): Bool {
        calls.add("write")
        true
    }

    private func winSize(cols: UInt16, rows: UInt16): WinSize {
        var ws = WinSize()
        ws.ws_col = cols
        ws.ws_row = rows
        ws
    }
}

class LifecycleWriter <: TerminalWriter {
    public var writes: ArrayList<String> = ArrayList<String>()
    public var failAt: Int64 = -1

    public init() {}

    public func write(text: String): Bool {
        let index = writes.size
        writes.add(text)
        failAt < 0 || index != failAt
    }

    public func flush(): Bool {
        true
    }

    public func last(): String {
        if (writes.isEmpty()) {
            ""
        } else {
            writes[writes.size - 1]
        }
    }
}

class LifecycleSizeProvider <: SizeProvider {
    public var value: Option<TuiSize> = Some(TuiSize(80, 24))

    public init() {}

    public func size(): Option<TuiSize> {
        value
    }
}

class RecordingExitHook <: ExitHook {
    public var callback: Option<() -> Unit> = None
    public var registrations: Int64 = 0

    public init() {}

    public func register(action: () -> Unit): Unit {
        callback = Some(action)
        registrations += 1
    }

    public func fire(): Unit {
        match (callback) {
            case Some(action) => action()
            case None => ()
        }
    }
}

func termiosHasEcho(ffi: LifecycleFfi): Bool {
    (ffi.termiosValue.c_lflag & ECHO) != 0
}

@Test
public class Terminal_test {
    /** 非 TTY 抛出 Unsupported，不进入 raw mode。 */
    @TestCase
    public func nonTtyThrowsUnsupported(): Unit {
        let ffi = LifecycleFfi()
        ffi.tty = false
        let terminal = Terminal(ffi, LifecycleWriter(), LifecycleSizeProvider(),
            exitHook: RecordingExitHook())
        var caught = false
        try {
            terminal.start()
        } catch (e: TuiException) {
            caught = e.code == TuiErrorCode.Unsupported
        }
        @Assert(caught)
        @Assert(terminal.isInitialized(), false)
        @Assert(ffi.calls.size, 1)
    }

    /** 初始化顺序：TTY 检查 → raw mode → 备用屏 → 隐藏光标；恢复幂等。 */
    @TestCase
    public func startOrderAndRestoreIdempotent(): Unit {
        let ffi = LifecycleFfi()
        let writer = LifecycleWriter()
        let hook = RecordingExitHook()
        ffi.termiosValue.c_lflag = ICANON | ECHO
        let terminal = Terminal(ffi, writer, LifecycleSizeProvider(), exitHook: hook)

        terminal.start()
        @Assert(terminal.isInitialized())
        @Assert(ffi.calls.size, 4)
        @Assert(ffi.calls[0], "isatty")
        @Assert(ffi.calls[1], "isatty")
        @Assert(ffi.calls[2], "tcgetattr")
        @Assert(ffi.calls[3], "tcsetattr")
        @Assert(writer.writes.size, 2)
        @Assert(hook.registrations, 1)
        @Assert(termiosHasEcho(ffi), false)

        terminal.restore()
        @Assert(terminal.isInitialized(), false)
        @Assert(termiosHasEcho(ffi), true)
        @Assert(ffi.calls.size, 5)
        @Assert(writer.writes.size, 3)
        terminal.restore()
        @Assert(ffi.calls.size, 5)
        @Assert(writer.writes.size, 3)
    }

    /** 中途写失败按逆序回滚 termios，不留下半初始化状态。 */
    @TestCase
    public func failureMidInitRollsBack(): Unit {
        let ffi = LifecycleFfi()
        let writer = LifecycleWriter()
        writer.failAt = 1
        ffi.termiosValue.c_lflag = ICANON | ECHO
        let terminal = Terminal(ffi, writer, LifecycleSizeProvider(),
            exitHook: RecordingExitHook())

        var caught = false
        try {
            terminal.start()
        } catch (e: TuiException) {
            caught = e.code == TuiErrorCode.Init
        }
        @Assert(caught)
        @Assert(terminal.isInitialized(), false)
        @Assert(termiosHasEcho(ffi), true)
        @Assert(ffi.calls[ffi.calls.size - 1], "tcsetattr")
        @Assert(ffi.calls.size, 5)
    }

    /** atExit 回调覆盖正常/异常/信号三条路径，恢复只执行一次。 */
    @TestCase
    public func exitHookCoversAllPaths(): Unit {
        let ffi = LifecycleFfi()
        let writer = LifecycleWriter()
        let hook = RecordingExitHook()
        let terminal = Terminal(ffi, writer, LifecycleSizeProvider(), exitHook: hook)
        terminal.start()
        let writesAfterStart = writer.writes.size
        let callsAfterStart = ffi.calls.size

        hook.fire()
        @Assert(writer.writes.size, writesAfterStart + 1)
        @Assert(ffi.calls.size, callsAfterStart + 1)

        hook.fire()
        hook.fire()
        @Assert(writer.writes.size, writesAfterStart + 1)
        @Assert(ffi.calls.size, callsAfterStart + 1)
    }

    /** 渲染写失败后停止后续输出，异常不穿透。 */
    @TestCase
    public func renderFailureStopsRendering(): Unit {
        let ffi = LifecycleFfi()
        let writer = LifecycleWriter()
        let terminal = Terminal(ffi, writer, LifecycleSizeProvider(),
            exitHook: RecordingExitHook())
        terminal.start()
        writer.failAt = writer.writes.size

        @Assert(terminal.bufferRenderer().flush(), false)
        let count = writer.writes.size
        @Assert(terminal.bufferRenderer().flush(), false)
        @Assert(writer.writes.size, count)
    }

    /** 尺寸未知时返回 None。 */
    @TestCase
    public func unknownSizeReturnsNone(): Unit {
        let ffi = LifecycleFfi()
        let provider = LifecycleSizeProvider()
        provider.value = None
        let terminal = Terminal(ffi, LifecycleWriter(), provider, exitHook: RecordingExitHook())
        @Assert(terminal.size().isNone())
    }

    /** 重复 start 不重复初始化。 */
    @TestCase
    public func startTwiceIsNoop(): Unit {
        let ffi = LifecycleFfi()
        let writer = LifecycleWriter()
        let hook = RecordingExitHook()
        let terminal = Terminal(ffi, writer, LifecycleSizeProvider(), exitHook: hook)
        terminal.start()
        let calls = ffi.calls.size
        let writes = writer.writes.size
        terminal.start()
        @Assert(ffi.calls.size, calls)
        @Assert(writer.writes.size, writes)
        @Assert(hook.registrations, 1)
    }
}
