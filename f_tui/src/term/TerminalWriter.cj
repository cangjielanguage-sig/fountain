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

/// 终端输出接口。测试注入记录型假 writer 断言 ANSI 序列。
public interface TerminalWriter {
    /// 写出一段文本；失败返回 `false`。
    func write(text: String): Bool

    /// 刷新缓冲；失败返回 `false`。
    func flush(): Bool
}

/// 基于 `write(2)` 的 stdout 写入器，不做用户态缓冲。
public class StdoutTerminalWriter <: TerminalWriter {
    private let ffi: PosixFfi
    private let fd: Int32

    public init(ffi: PosixFfi, fd: Int32) {
        this.ffi = ffi
        this.fd = fd
    }

    public func write(text: String): Bool {
        ffi.writeBytes(fd, text.toArray())
    }

    public func flush(): Bool {
        true
    }
}
