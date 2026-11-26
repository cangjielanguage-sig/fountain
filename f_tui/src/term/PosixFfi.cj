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

/// 标准输入文件描述符。
public const STDIN_FILENO: Int32 = 0
/// 标准输出文件描述符。
public const STDOUT_FILENO: Int32 = 1
/// `tcsetattr` 立即生效。
public const TCSANOW: Int32 = 0
/// 终端窗口变化信号（Linux / macOS 均为 28）。
public const SIGWINCH: Int32 = 28

/// `poll` 关注可读事件。
const POLLIN: Int16 = 1

// ---- termios 布局与常量（按平台） ----

@When[os == "macOS"]
/// `c_cc` 数组长度。
public const TERMIOS_CC_COUNT: Int64 = 20

@When[os != "macOS"]
/// `c_cc` 数组长度。
public const TERMIOS_CC_COUNT: Int64 = 32

@When[os == "macOS"]
/// `ioctl` 获取窗口尺寸的请求码。
public const TIOCGWINSZ: UIntNative = 0x4008_7468

@When[os != "macOS"]
/// `ioctl` 获取窗口尺寸的请求码。
public const TIOCGWINSZ: UIntNative = 0x5413

@When[os == "macOS"]
/// 关闭规范输入模式。
public const ICANON: UInt32 = 0x0000_0100

@When[os != "macOS"]
/// 关闭规范输入模式。
public const ICANON: UInt32 = 0x0000_0002

@When[os == "macOS"]
/// 关闭输入回显。
public const ECHO: UInt32 = 0x0000_0008

@When[os != "macOS"]
/// 关闭输入回显。
public const ECHO: UInt32 = 0x0000_0010

@When[os == "macOS"]
/// 关闭扩展输入处理。
public const IEXTEN: UInt32 = 0x0000_0400

@When[os != "macOS"]
/// 关闭扩展输入处理。
public const IEXTEN: UInt32 = 0x0008_0000

@When[os == "macOS"]
/// 信号字符处理（保留）。
public const ISIG: UInt32 = 0x0000_0080

@When[os != "macOS"]
/// 信号字符处理（保留）。
public const ISIG: UInt32 = 0x0000_0001

@When[os == "macOS"]
/// 将 CR 映射为 NL。
public const ICRNL: UInt32 = 0x0000_0100

@When[os != "macOS"]
/// 将 CR 映射为 NL。
public const ICRNL: UInt32 = 0x0000_0400

@When[os == "macOS"]
/// 输出软件流控。
public const IXON: UInt32 = 0x0000_0200

@When[os != "macOS"]
/// 输出软件流控。
public const IXON: UInt32 = 0x0000_2000

@When[os == "macOS"]
/// 输出后处理。
public const OPOST: UInt32 = 0x0000_0001

@When[os != "macOS"]
/// 输出后处理。
public const OPOST: UInt32 = 0x0000_0001

@When[os == "macOS"]
/// 8 位字符宽度。
public const CS8: UInt32 = 0x0000_0300

@When[os != "macOS"]
/// 8 位字符宽度。
public const CS8: UInt32 = 0x0000_0030

@When[os == "macOS"]
/// 中断字符。
public const BRKINT: UInt32 = 0x0000_0002

@When[os != "macOS"]
/// 中断字符。
public const BRKINT: UInt32 = 0x0000_0002

@When[os == "macOS"]
/// 校验错误标记。
public const INPCK: UInt32 = 0x0000_0010

@When[os != "macOS"]
/// 校验错误标记。
public const INPCK: UInt32 = 0x0000_0020

@When[os == "macOS"]
/// 剥离第 8 位。
public const ISTRIP: UInt32 = 0x0000_0020

@When[os != "macOS"]
/// 剥离第 8 位。
public const ISTRIP: UInt32 = 0x0000_0040

@When[os == "macOS"]
/// 最少读取字节数在 `c_cc` 中的下标。
public const VMIN: Int64 = 16

@When[os != "macOS"]
/// 最少读取字节数在 `c_cc` 中的下标。
public const VMIN: Int64 = 6

@When[os == "macOS"]
/// 读取超时在 `c_cc` 中的下标。
public const VTIME: Int64 = 17

@When[os != "macOS"]
/// 读取超时在 `c_cc` 中的下标。
public const VTIME: Int64 = 5

/// `ioctl(TIOCGWINSZ)` 的窗口尺寸结构。
@C
public struct WinSize {
    /// 行数。
    public var ws_row: UInt16 = 0
    /// 列数。
    public var ws_col: UInt16 = 0
    /// 横向像素数。
    public var ws_xpixel: UInt16 = 0
    /// 纵向像素数。
    public var ws_ypixel: UInt16 = 0

    public init() {}
}

@When[os == "macOS"]
/// POSIX `termios` 结构（macOS 布局：64 位标志、20 字节 `c_cc`）。
@C
public struct Termios {
    public var c_iflag: UInt64 = 0
    public var c_oflag: UInt64 = 0
    public var c_cflag: UInt64 = 0
    public var c_lflag: UInt64 = 0
    public var c_cc: VArray<UInt8, $20> = VArray<UInt8, $20>(repeat: 0)
    public var c_ispeed: UInt64 = 0
    public var c_ospeed: UInt64 = 0

    public init() {}
}

@When[os != "macOS"]
/// POSIX `termios` 结构（Linux / 鸿蒙布局：32 位标志、32 字节 `c_cc`）。
@C
public struct Termios {
    public var c_iflag: UInt32 = 0
    public var c_oflag: UInt32 = 0
    public var c_cflag: UInt32 = 0
    public var c_lflag: UInt32 = 0
    public var c_line: UInt8 = 0
    public var c_cc: VArray<UInt8, $32> = VArray<UInt8, $32>(repeat: 0)
    public var c_ispeed: UInt32 = 0
    public var c_ospeed: UInt32 = 0

    public init() {}
}

@C
struct PollFd {
    var fd: Int32 = 0
    var events: Int16 = 0
    var revents: Int16 = 0

    init() {}
}

/// 计算 raw mode 下的 `termios`：关闭规范输入、回显、扩展处理与输出后处理，
/// 保留 `ISIG` 以便 `SIGINT`/`SIGTERM` 仍能触发退出恢复。
public func makeRaw(input: Termios): Termios {
    var t = input
    t.c_iflag = t.c_iflag & !BRKINT & !INPCK & !ISTRIP & !ICRNL & !IXON
    t.c_oflag = t.c_oflag & !OPOST
    t.c_cflag = t.c_cflag | CS8
    t.c_lflag = t.c_lflag & !(ICANON | ECHO | IEXTEN)
    t.c_cc[VMIN] = 1
    t.c_cc[VTIME] = 0
    t
}

/// 终端系统调用的全部入口。生产实现是 `RealPosixFfi`，测试注入假实现。
public interface PosixFfi {
    /// 判断文件描述符是否连接终端。
    func isTty(fd: Int32): Bool

    /// 读取当前 `termios` 快照。
    func getTermios(fd: Int32): Option<Termios>

    /// 写回 `termios`。
    func setTermios(fd: Int32, value: Termios): Bool

    /// 通过 `ioctl(TIOCGWINSZ)` 读取窗口尺寸；失败返回 `None`。
    func windowSize(fd: Int32): Option<WinSize>

    /// 在超时内读取一个字节；超时或 EOF 返回 `None`。
    func readByte(fd: Int32, timeoutMs: Int64): Option<UInt8>

    /// 写出一段字节；失败返回 `false`。
    func writeBytes(fd: Int32, bytes: Array<UInt8>): Bool
}

// ---- C 绑定 ----

foreign func isatty(fd: Int32): Int32

foreign func tcgetattr(fd: Int32, termios_p: CPointer<Termios>): Int32

foreign func tcsetattr(fd: Int32, optional_actions: Int32, termios_p: CPointer<Termios>): Int32

foreign func ioctl(fd: Int32, request: UIntNative, ...): Int32

foreign func read(fd: Int32, buffer: CPointer<UInt8>, count: UIntNative): IntNative

foreign func write(fd: Int32, buffer: CPointer<UInt8>, count: UIntNative): IntNative

foreign func poll(fds: CPointer<PollFd>, nfds: UIntNative, timeout: Int32): Int32

@When[os == "Windows"]
/// 非 Unix 平台的占位实现：所有终端能力返回 unsupported 语义。
public class RealPosixFfi <: PosixFfi {
    public init() {}

    public func isTty(fd: Int32): Bool {
        false
    }

    public func getTermios(fd: Int32): Option<Termios> {
        None
    }

    public func setTermios(fd: Int32, value: Termios): Bool {
        false
    }

    public func windowSize(fd: Int32): Option<WinSize> {
        None
    }

    public func readByte(fd: Int32, timeoutMs: Int64): Option<UInt8> {
        None
    }

    public func writeBytes(fd: Int32, bytes: Array<UInt8>): Bool {
        false
    }
}

@When[os != "Windows"]
/// Unix（Linux / macOS / 鸿蒙 POSIX）系统调用实现。
public class RealPosixFfi <: PosixFfi {
    public init() {}

    public func isTty(fd: Int32): Bool {
        unsafe { isatty(fd) != 0 }
    }

    public func getTermios(fd: Int32): Option<Termios> {
        var value = Termios()
        let rc = unsafe { tcgetattr(fd, inout value) }
        if (rc == 0) {
            Some(value)
        } else {
            None
        }
    }

    public func setTermios(fd: Int32, value: Termios): Bool {
        var copy = value
        unsafe { tcsetattr(fd, TCSANOW, inout copy) == 0 }
    }

    public func windowSize(fd: Int32): Option<WinSize> {
        var value = WinSize()
        let rc = unsafe { ioctl(fd, TIOCGWINSZ, inout value) }
        if (rc == 0) {
            Some(value)
        } else {
            None
        }
    }

    public func readByte(fd: Int32, timeoutMs: Int64): Option<UInt8> {
        var pfd = PollFd()
        pfd.fd = fd
        pfd.events = POLLIN
        let timeout = if (timeoutMs < 0) {
            -1i32
        } else if (timeoutMs > Int64(Int32.Max)) {
            Int32.Max
        } else {
            Int32(timeoutMs)
        }
        let ready = unsafe { poll(inout pfd, 1, timeout) }
        if (ready <= 0) {
            return None
        }
        var byte: UInt8 = 0
        let n = unsafe { read(fd, inout byte, 1) }
        if (n == 1) {
            Some(byte)
        } else {
            None
        }
    }

    public func writeBytes(fd: Int32, bytes: Array<UInt8>): Bool {
        if (bytes.isEmpty()) {
            return true
        }
        let handle = unsafe { acquireArrayRawData(bytes) }
        try {
            let n = unsafe { write(fd, handle.pointer, UIntNative(bytes.size)) }
            n == IntNative(bytes.size)
        } finally {
            unsafe { releaseArrayRawData(handle) }
        }
    }
}
