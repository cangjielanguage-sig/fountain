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
package fountain::f_tui

/// 终端层错误分类。
public enum TuiErrorCode <: Equatable<TuiErrorCode> & ToString {
    /// 终端初始化失败。
    | Init
    /// 当前平台不支持终端能力。
    | Unsupported
    /// 写终端失败（管道关闭、EPIPE 等）。
    | Write
    /// 终端尺寸不可用。
    | Size

    public operator func ==(other: TuiErrorCode): Bool {
        match ((this, other)) {
            case (Init, Init) => true
            case (Unsupported, Unsupported) => true
            case (Write, Write) => true
            case (Size, Size) => true
            case _ => false
        }
    }

    public func toString(): String {
        match (this) {
            case Init => "init"
            case Unsupported => "unsupported"
            case Write => "write"
            case Size => "size"
        }
    }
}

/// `f_tui` 统一抛出的终端异常。
public class TuiException <: Exception {
    /// 错误分类。
    public let code: TuiErrorCode

    public init(code: TuiErrorCode, message: String) {
        super(message)
        this.code = code
    }
}
