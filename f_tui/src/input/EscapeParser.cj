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

import std.collection.ArrayList

/// ESC 序列与 UTF-8 的增量解析器。
///
/// 未完成的序列保留在内部缓冲区，下一次 `feed` 后继续拼装；
/// 超时或拆包不会抛异常。
public class EscapeParser {
    private var bytes: ArrayList<UInt8> = ArrayList<UInt8>()

    public init() {}

    /// 追加一个字节。
    public func feed(value: UInt8): Unit {
        bytes.add(value)
    }

    /// 追加一段字节。
    public func feed(values: Array<UInt8>): Unit {
        for (value in values) {
            bytes.add(value)
        }
    }

    /// 未完成的字节数。
    public func pendingCount(): Int64 {
        bytes.size
    }

    /// 是否只有一个待判定的 ESC。
    public func isLoneEscape(): Bool {
        bytes.size == 1 && bytes[0] == 0x1B
    }

    /// 解析下一个按键；序列不完整时返回 `None` 并保留字节。
    public func next(): Option<TerminalKey> {
        if (bytes.isEmpty()) {
            return None
        }
        let first = bytes[0]
        if (first == 0x1B) {
            return parseEscape()
        }
        if (first == 0x0D || first == 0x0A) {
            consume(1)
            return Some(TerminalKey.Enter)
        }
        if (first == 0x09) {
            consume(1)
            return Some(TerminalKey.Tab)
        }
        if (first < 0x20 || first == 0x7F) {
            consume(1)
            return Some(TerminalKey.Unknown)
        }
        if (first < 0x80) {
            consume(1)
            return Some(TerminalKey.Char(Rune(UInt32(first))))
        }
        parseUtf8()
    }

    /// 超时后把独立 ESC 判定为 Escape；多字节未完成序列原样保留。
    public func flushEscape(): Option<TerminalKey> {
        if (isLoneEscape()) {
            bytes.clear()
            Some(TerminalKey.Escape)
        } else {
            None
        }
    }

    private func parseEscape(): Option<TerminalKey> {
        if (bytes.size == 1) {
            return None
        }
        let second = bytes[1]
        if (second == 0x5B) {
            return parseCsi()
        }
        if (second == 0x4F) {
            if (bytes.size < 3) {
                return None
            }
            let third = bytes[2]
            consume(3)
            Some(mapSs3(third))
        } else {
            // ESC 后面不是 CSI/SS3：ESC 独立成键，后续字节留给下一次解析。
            consume(1)
            Some(TerminalKey.Escape)
        }
    }

    private func parseCsi(): Option<TerminalKey> {
        if (bytes.size < 3) {
            return None
        }
        var index: Int64 = 2
        while (index < bytes.size) {
            let value = bytes[index]
            if (value >= 0x40 && value <= 0x7E) {
                let key = mapCsi(value)
                consume(index + 1)
                return Some(key)
            }
            index += 1
        }
        None
    }

    private func parseUtf8(): Option<TerminalKey> {
        let first = bytes[0]
        let length = utf8Length(first)
        if (length <= 0) {
            consume(1)
            return Some(TerminalKey.Unknown)
        }
        if (bytes.size < length) {
            return None
        }
        let data = Array<UInt8>(length, repeat: 0)
        var index: Int64 = 0
        while (index < length) {
            data[index] = bytes[index]
            index += 1
        }
        consume(length)
        try {
            let (rune, _) = Rune.fromUtf8(data, 0)
            Some(TerminalKey.Char(rune))
        } catch (e: Exception) {
            Some(TerminalKey.Unknown)
        }
    }

    private func consume(count: Int64): Unit {
        var index: Int64 = 0
        while (index < count) {
            bytes.remove(at: 0)
            index += 1
        }
    }

    private func utf8Length(first: UInt8): Int64 {
        if (first < 0x80) {
            1
        } else if (first < 0xC0) {
            0
        } else if (first < 0xE0) {
            2
        } else if (first < 0xF0) {
            3
        } else if (first < 0xF8) {
            4
        } else {
            0
        }
    }

    private func mapCsi(final: UInt8): TerminalKey {
        match (final) {
            case 0x41 => TerminalKey.Up
            case 0x42 => TerminalKey.Down
            case 0x5A => TerminalKey.BackTab
            case _ => TerminalKey.Unknown
        }
    }

    private func mapSs3(final: UInt8): TerminalKey {
        match (final) {
            case 0x41 => TerminalKey.Up
            case 0x42 => TerminalKey.Down
            case _ => TerminalKey.Unknown
        }
    }
}
