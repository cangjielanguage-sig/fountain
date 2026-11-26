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

import fountain::f_tui.{TuiErrorCode, TuiException}
import std.unittest.*
import std.unittest.testmacro.*

@Test
public class RawMode_test {
    /** 进入 raw mode 前保存快照，按「读→写」顺序应用。 */
    @TestCase
    public func enterSavesAndAppliesRaw(): Unit {
        let ffi = FakePosixFfi()
        var original = Termios()
        original.c_lflag = ICANON | ECHO | ISIG
        ffi.termiosValue = original
        let raw = RawMode(ffi, STDIN_FILENO)

        raw.enter()

        @Assert(raw.isActive())
        @Assert(ffi.calls.size, 2)
        @Assert(ffi.calls[0], "tcgetattr")
        @Assert(ffi.calls[1], "tcsetattr")
        @Assert((ffi.termiosValue.c_lflag & ICANON) == 0)
        @Assert((ffi.termiosValue.c_lflag & ECHO) == 0)
        @Assert((ffi.termiosValue.c_lflag & ISIG) != 0)
        @Assert(raw.snapshot().isSome())
        @Assert((raw.snapshot().getOrThrow().c_lflag & ECHO) != 0)
    }

    /** 恢复使用启动快照，连续两次 restore 不产生额外系统调用。 */
    @TestCase
    public func restoreIsIdempotent(): Unit {
        let ffi = FakePosixFfi()
        var original = Termios()
        original.c_lflag = ICANON | ECHO
        ffi.termiosValue = original
        let raw = RawMode(ffi, STDIN_FILENO)
        raw.enter()

        raw.restore()
        @Assert(!raw.isActive())
        @Assert((ffi.termiosValue.c_lflag & ICANON) != 0)
        @Assert((ffi.termiosValue.c_lflag & ECHO) != 0)
        @Assert(ffi.calls.size, 3)

        raw.restore()
        @Assert(ffi.calls.size, 3)
    }

    /** 未进入 raw mode 时 restore 是空操作。 */
    @TestCase
    public func restoreBeforeEnterIsNoop(): Unit {
        let ffi = FakePosixFfi()
        let raw = RawMode(ffi, STDIN_FILENO)
        raw.restore()
        @Assert(raw.isActive(), false)
        @Assert(ffi.calls.isEmpty())
    }

    /** 读取 termios 失败时抛出 INIT，不进入 raw mode。 */
    @TestCase
    public func enterWithoutTermiosThrows(): Unit {
        let ffi = FakePosixFfi()
        ffi.termiosAvailable = false
        let raw = RawMode(ffi, STDIN_FILENO)
        var caught = false
        try {
            raw.enter()
        } catch (e: TuiException) {
            caught = e.code == TuiErrorCode.Init
        }
        @Assert(caught)
        @Assert(raw.isActive(), false)
        @Assert(ffi.calls.size, 1)
        @Assert(ffi.calls[0], "tcgetattr")
    }

    /** 重复 enter 不重复保存或写入。 */
    @TestCase
    public func enterTwiceIsNoop(): Unit {
        let ffi = FakePosixFfi()
        let raw = RawMode(ffi, STDIN_FILENO)
        raw.enter()
        raw.enter()
        @Assert(ffi.calls.size, 2)
    }
}
