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
package fountain::f_tui.term

import fountain::f_base.OS
import std.unittest.*
import std.unittest.testmacro.*

@Test
public class PosixFfi_test {
    /** termios / winsize 的内存布局与目标平台一致。 */
    @TestCase
    public func layoutMatchesPlatform(): Unit {
        if (OS.current.isMacOS) {
            @Assert(sizeOf<Termios>(), 72)
            @Assert(alignOf<Termios>(), 8)
            @Assert(TERMIOS_CC_COUNT, 20)
            @Assert(TIOCGWINSZ, 0x4008_7468)
        } else {
            @Assert(sizeOf<Termios>(), 60)
            @Assert(alignOf<Termios>(), 4)
            @Assert(TERMIOS_CC_COUNT, 32)
            @Assert(TIOCGWINSZ, 0x5413)
        }
        @Assert(sizeOf<WinSize>(), 8)
        @Assert(alignOf<WinSize>(), 2)
    }

    /** 文件描述符与 termios 动作常量固定。 */
    @TestCase
    public func constantsMatchPlatform(): Unit {
        @Assert(STDIN_FILENO, 0)
        @Assert(STDOUT_FILENO, 1)
        @Assert(TCSANOW, 0)
        @Assert(SIGWINCH, 28)
    }

    /** 假实现可注入：尺寸、isatty、读写都只经过接口。 */
    @TestCase
    public func fakeFfiIsInjectable(): Unit {
        let ffi = FakePosixFfi()
        ffi.readQueue.add(0x71)
        @Assert(ffi.isTty(STDIN_FILENO))
        @Assert(ffi.getTermios(STDIN_FILENO).isSome())
        @Assert(ffi.windowSize(STDIN_FILENO).getOrThrow().ws_col, 80)
        @Assert(ffi.readByte(STDIN_FILENO, 10).getOrThrow(), 0x71)
        @Assert(ffi.readByte(STDIN_FILENO, 10).isNone())
        @Assert(ffi.writeBytes(STDOUT_FILENO, "hi".toArray()))
        @Assert(ffi.calls.size, 6)
    }

    /** raw 模式关闭规范输入、回显与扩展处理，保留信号。 */
    @TestCase
    public func makeRawKeepsSignals(): Unit {
        var t = Termios()
        t.c_iflag = ICRNL | IXON
        t.c_oflag = OPOST
        t.c_lflag = ICANON | ECHO | IEXTEN | ISIG
        let raw = makeRaw(t)
        @Assert((raw.c_iflag & ICRNL) == 0)
        @Assert((raw.c_iflag & IXON) == 0)
        @Assert((raw.c_oflag & OPOST) == 0)
        @Assert((raw.c_lflag & ICANON) == 0)
        @Assert((raw.c_lflag & ECHO) == 0)
        @Assert((raw.c_lflag & IEXTEN) == 0)
        @Assert((raw.c_lflag & ISIG) != 0)
        @Assert(raw.c_cc[VMIN], 1)
        @Assert(raw.c_cc[VTIME], 0)
    }
}
