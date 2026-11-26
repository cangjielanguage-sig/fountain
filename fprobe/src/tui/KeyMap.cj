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

/**
 * 与终端库无关的按键语义。
 *
 * 把 crossterm 的 `KeyCode` 翻译成该枚举的动作只发生在终端薄层，
 * `KeyMap` 与视图逻辑不依赖任何终端库。
 */
public enum UiKey <: Equatable<UiKey> {
    | Quit
    | Refresh
    | NextPage
    | PreviousPage
    | Up
    | Down
    | AlarmPage
    | Unknown

    public operator func ==(other: UiKey): Bool {
        match ((this, other)) {
            case (Quit, Quit) | (Refresh, Refresh) | (NextPage, NextPage) => true
            case (PreviousPage, PreviousPage) | (Up, Up) | (Down, Down) => true
            case (AlarmPage, AlarmPage) | (Unknown, Unknown) => true
            case _ => false
        }
    }
}

/** 按键最终触发的视图动作。 */
public enum UiAction <: Equatable<UiAction> {
    | Quit
    | Refresh
    | NextPage
    | PreviousPage
    | SelectPrevious
    | SelectNext
    | ShowAlarms
    | Ignore

    public operator func ==(other: UiAction): Bool {
        match ((this, other)) {
            case (Quit, Quit) | (Refresh, Refresh) | (NextPage, NextPage) => true
            case (PreviousPage, PreviousPage) | (SelectPrevious, SelectPrevious) => true
            case (SelectNext, SelectNext) | (ShowAlarms, ShowAlarms) | (Ignore, Ignore) => true
            case _ => false
        }
    }
}

/**
 * 固定按键表（spec「控制台模式」）。
 *
 * `q` 退出、`r` 刷新、`Tab`/`Shift+Tab` 翻页、方向键选择节点、`a` 打开告警页；
 * 其余按键保持无害。
 */
public class KeyMap {
    public static func action(key: UiKey): UiAction {
        match (key) {
            case UiKey.Quit => UiAction.Quit
            case UiKey.Refresh => UiAction.Refresh
            case UiKey.NextPage => UiAction.NextPage
            case UiKey.PreviousPage => UiAction.PreviousPage
            case UiKey.Up => UiAction.SelectPrevious
            case UiKey.Down => UiAction.SelectNext
            case UiKey.AlarmPage => UiAction.ShowAlarms
            case UiKey.Unknown => UiAction.Ignore
        }
    }
}
