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

/// `f_tui` 的中性按键枚举，不携带宿主视图语义。
public enum TerminalKey <: Equatable<TerminalKey> & ToString {
    /// 可打印字符（含 UTF-8 多字节字符）。
    | Char(Rune)
    /// 回车。
    | Enter
    /// Tab。
    | Tab
    /// Shift+Tab（`CSI Z`）。
    | BackTab
    /// 上方向键。
    | Up
    /// 下方向键。
    | Down
    /// 独立 ESC。
    | Escape
    /// 无法识别或不可打印的按键。
    | Unknown

    public operator func ==(other: TerminalKey): Bool {
        match ((this, other)) {
            case (Char(a), Char(b)) => a == b
            case (Enter, Enter) => true
            case (Tab, Tab) => true
            case (BackTab, BackTab) => true
            case (Up, Up) => true
            case (Down, Down) => true
            case (Escape, Escape) => true
            case (Unknown, Unknown) => true
            case _ => false
        }
    }

    public func toString(): String {
        match (this) {
            case Char(value) => "Char(${value})"
            case Enter => "Enter"
            case Tab => "Tab"
            case BackTab => "BackTab"
            case Up => "Up"
            case Down => "Down"
            case Escape => "Escape"
            case Unknown => "Unknown"
        }
    }
}
