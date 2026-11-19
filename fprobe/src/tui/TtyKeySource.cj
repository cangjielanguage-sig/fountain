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
package fountain::fprobe.tui

import fountain::f_tui.input.{KeyReader, TerminalKey}
import fountain::f_tui.term.{RealPosixFfi, STDIN_FILENO, StdinByteSource}

/**
 * `f_tui` 按键读取面的抽象。
 *
 * 用例注入脚本化读取器，覆盖全部 `TerminalKey` 分支，不需要真实 stdin。
 */
public interface TerminalKeyReader {
    /** 在超时内读取一个终端按键；超时 / EOF 返回 `None`。 */
    func readKey(timeoutMs: Int64): Option<TerminalKey>
}

/** 生产读取器：直接委托 `f_tui` 的 `KeyReader`。 */
public class TuiTerminalKeyReader <: TerminalKeyReader {
    private let reader: KeyReader

    public init(reader: KeyReader) {
        this.reader = reader
    }

    public func readKey(timeoutMs: Int64): Option<TerminalKey> {
        reader.readKey(timeoutMs)
    }
}

/**
 * 把 `f_tui.TerminalKey` 翻译为 fprobe 的视图语义 `UiKey`（设计 D9）。
 *
 * 映射表固定：`q` 退出、`r` 刷新、`a` 告警页、`Tab`/`Shift+Tab` 翻页、
 * `↑`/`↓` 选择节点；其余字符与不可识别序列统一落 `Unknown`，保持无害。
 */
public class TtyKeySource <: KeySource {
    private let reader: TerminalKeyReader

    public init(reader: TerminalKeyReader) {
        this.reader = reader
    }

    public func readKey(timeoutMs: Int64): ?UiKey {
        match (reader.readKey(timeoutMs)) {
            case Some(key) => Some(TtyKeySource.map(key))
            case None => None<UiKey>
        }
    }

    public static func map(key: TerminalKey): UiKey {
        match (key) {
            case Char(value) =>
                if (value == r'q') {
                    UiKey.Quit
                } else if (value == r'r') {
                    UiKey.Refresh
                } else if (value == r'a') {
                    UiKey.AlarmPage
                } else {
                    UiKey.Unknown
                }
            case Enter => UiKey.Unknown
            case Tab => UiKey.NextPage
            case BackTab => UiKey.PreviousPage
            case Up => UiKey.Up
            case Down => UiKey.Down
            case Escape => UiKey.Unknown
            case Unknown => UiKey.Unknown
        }
    }
}

/** 生产按键来源：`stdin` 字节 → `KeyReader` → `TtyKeySource`。 */
public func systemKeySource(): KeySource {
    let ffi = RealPosixFfi()
    TtyKeySource(TuiTerminalKeyReader(KeyReader(StdinByteSource(ffi, STDIN_FILENO))))
}
