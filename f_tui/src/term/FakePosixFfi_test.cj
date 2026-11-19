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

import std.collection.ArrayList

/// 记录调用序列的假 `PosixFfi`，测试中不触碰真实终端。
class FakePosixFfi <: PosixFfi {
    public var tty: Bool = true
    public var termiosValue: Termios = Termios()
    public var termiosAvailable: Bool = true
    public var windowValue: Option<WinSize> = Some(winSize(80, 24))
    public var readQueue: ArrayList<UInt8> = ArrayList<UInt8>()
    public var writeOk: Bool = true
    public var readTimeout: Option<UInt8> = None
    public var calls: ArrayList<String> = ArrayList<String>()
    public var written: ArrayList<Array<UInt8>> = ArrayList<Array<UInt8>>()

    public init() {}

    public func isTty(fd: Int32): Bool {
        calls.add("isatty")
        tty
    }

    public func getTermios(fd: Int32): Option<Termios> {
        calls.add("tcgetattr")
        if (termiosAvailable) {
            Some(termiosValue)
        } else {
            None
        }
    }

    public func setTermios(fd: Int32, value: Termios): Bool {
        calls.add("tcsetattr")
        termiosValue = value
        true
    }

    public func windowSize(fd: Int32): Option<WinSize> {
        calls.add("ioctl")
        windowValue
    }

    public func readByte(fd: Int32, timeoutMs: Int64): Option<UInt8> {
        calls.add("read")
        if (readQueue.isEmpty()) {
            readTimeout
        } else {
            Some(readQueue.remove(at: 0))
        }
    }

    public func writeBytes(fd: Int32, bytes: Array<UInt8>): Bool {
        calls.add("write")
        written.add(bytes)
        writeOk
    }
}

/// 构造 `WinSize` 的测试辅助。
func winSize(cols: UInt16, rows: UInt16): WinSize {
    var ws = WinSize()
    ws.ws_col = cols
    ws.ws_row = rows
    ws
}
