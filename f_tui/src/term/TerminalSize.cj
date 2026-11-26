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

/// 终端行列数（单位为字符单元格）。
public struct TuiSize {
    /// 列数。
    public var width: UInt16
    /// 行数。
    public var height: UInt16

    public init(width: UInt16, height: UInt16) {
        this.width = width
        this.height = height
    }

    /// 行列任一为 0 即视为未知尺寸。
    public func isUnknown(): Bool {
        width == 0 || height == 0
    }

    public func toString(): String {
        "${width}x${height}"
    }
}

/// 终端尺寸来源。测试可注入固定值，生产实现走 `ioctl`。
public interface SizeProvider {
    /// 读取当前尺寸；不可用时返回 `None`。
    func size(): Option<TuiSize>
}

/// 基于 `ioctl(TIOCGWINSZ)` 的尺寸来源。
public class IoctlSizeProvider <: SizeProvider {
    private let ffi: PosixFfi
    private let fd: Int32

    public init(ffi: PosixFfi, fd: Int32) {
        this.ffi = ffi
        this.fd = fd
    }

    public func size(): Option<TuiSize> {
        match (ffi.windowSize(fd)) {
            case Some(ws) =>
                if (ws.ws_col == 0 || ws.ws_row == 0) {
                    None
                } else {
                    Some(TuiSize(ws.ws_col, ws.ws_row))
                }
            case None => None
        }
    }
}

/// 终端尺寸查询入口，每次调用都重新读取以响应窗口变化。
public class TerminalSize {
    private let provider: SizeProvider
    private var last: TuiSize = TuiSize(0, 0)

    public init(provider: SizeProvider) {
        this.provider = provider
    }

    /// 读取当前尺寸；失败或 `0x0` 时返回 `None`。
    public func size(): Option<TuiSize> {
        match (provider.size()) {
            case Some(value) =>
                if (value.isUnknown()) {
                    None
                } else {
                    last = value
                    Some(value)
                }
            case None => None
        }
    }

    /// 最近一次成功读取的尺寸；从未成功时为 `0x0`。
    public func lastKnown(): TuiSize {
        last
    }
}
