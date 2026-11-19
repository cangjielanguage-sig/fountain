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

/// 进入 / 恢复终端 raw mode。
///
/// 进入前保存 `termios` 快照，恢复时按快照写回，不按硬编码默认值重建。
public class RawMode {
    private let ffi: PosixFfi
    private let fd: Int32
    private var saved: Option<Termios> = None
    private var active: Bool = false

    public init(ffi: PosixFfi, fd: Int32) {
        this.ffi = ffi
        this.fd = fd
    }

    /// 是否处于 raw mode。
    public func isActive(): Bool {
        active
    }

    /// 进入 raw mode 前保存的原始设置。
    public func snapshot(): Option<Termios> {
        saved
    }

    /// 保存快照并进入 raw mode；重复调用是空操作。
    public func enter(): Unit {
        if (active) {
            return
        }
        let current = match (ffi.getTermios(fd)) {
            case Some(value) => value
            case None => throw TuiException(TuiErrorCode.Init, "tcgetattr failed on fd ${fd}")
        }
        saved = Some(current)
        if (!ffi.setTermios(fd, makeRaw(current))) {
            throw TuiException(TuiErrorCode.Init, "tcsetattr failed on fd ${fd}")
        }
        active = true
    }

    /// 按启动快照恢复终端；已恢复时直接返回。
    public func restore(): Unit {
        if (!active) {
            return
        }
        if (let Some(value) <- saved) {
            ffi.setTermios(fd, value)
        }
        active = false
    }
}
