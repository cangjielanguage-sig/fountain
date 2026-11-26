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
package fountain::f_tui.input

import fountain::f_tui.term.ByteSource

/// 带超时的按键读取器。
///
/// 首字节按调用方给定超时读取；ESC/UTF-8 的后续字节用较短的
/// `escapeTimeoutMs`，避免独立 ESC 卡住渲染循环。
public class KeyReader {
    private let source: ByteSource
    private let escapeTimeoutMs: Int64
    private let parser: EscapeParser = EscapeParser()

    public init(source: ByteSource, escapeTimeoutMs!: Int64 = 25) {
        this.source = source
        this.escapeTimeoutMs = escapeTimeoutMs
    }

    /// 未完成的字节数。
    public func pendingCount(): Int64 {
        parser.pendingCount()
    }

    /// 读取一个按键；超时 / EOF 返回 `None`。
    public func readKey(timeoutMs: Int64): Option<TerminalKey> {
        if (let Some(key) <- parser.next()) {
            return Some(key)
        }
        match (source.read(timeoutMs)) {
            case None => return finishPending()
            case Some(value) => parser.feed(value)
        }
        while (true) {
            if (let Some(key) <- parser.next()) {
                return Some(key)
            }
            if (parser.pendingCount() == 0) {
                return None
            }
            match (source.read(escapeTimeoutMs)) {
                case None => return finishPending()
                case Some(value) => parser.feed(value)
            }
        }
        None
    }

    private func finishPending(): Option<TerminalKey> {
        if (parser.isLoneEscape()) {
            parser.flushEscape()
        } else {
            None
        }
    }
}
