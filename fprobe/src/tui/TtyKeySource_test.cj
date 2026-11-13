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

import std.collection.ArrayList
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_tui.input.TerminalKey

/** 按脚本返回按键的假读取器；脚本耗尽后返回 `None`。 */
class ScriptedTerminalKeyReader <: TerminalKeyReader {
    private let keys: ArrayList<Option<TerminalKey>>
    private var index = 0

    init(keys: Array<Option<TerminalKey>>) {
        this.keys = ArrayList<Option<TerminalKey>>(keys)
    }

    public func readKey(_: Int64): Option<TerminalKey> {
        if (index >= keys.size) {
            return None<TerminalKey>
        }
        let value = keys[index]
        index += 1
        value
    }
}

func mappingRows(): Array<(TerminalKey, UiKey)> {
    [
        (TerminalKey.Char(r'q'), UiKey.Quit),
        (TerminalKey.Char(r'r'), UiKey.Refresh),
        (TerminalKey.Char(r'a'), UiKey.AlarmPage),
        (TerminalKey.Char(r'x'), UiKey.Unknown),
        (TerminalKey.Char(r'中'), UiKey.Unknown),
        (TerminalKey.Enter, UiKey.Unknown),
        (TerminalKey.Tab, UiKey.NextPage),
        (TerminalKey.BackTab, UiKey.PreviousPage),
        (TerminalKey.Up, UiKey.Up),
        (TerminalKey.Down, UiKey.Down),
        (TerminalKey.Escape, UiKey.Unknown),
        (TerminalKey.Unknown, UiKey.Unknown)
    ]
}

/** 13.7：`TerminalKey → UiKey` 表驱动，未知分支统一落 `Unknown`。 */
@Test
public class TtyKeySource_test {
    @TestCase
    public func mapsEveryTerminalKeyBranch(): Unit {
        for ((terminal, expected) in mappingRows()) {
            @Assert(TtyKeySource.map(terminal), expected)
        }
    }

    @TestCase
    public func readKeyDelegatesAndMaps(): Unit {
        let reader = ScriptedTerminalKeyReader([
            Some(TerminalKey.Char(r'q')),
            Some(TerminalKey.Tab),
            Some(TerminalKey.Char(r'z')),
            None<TerminalKey>
        ])
        let source = TtyKeySource(reader)

        @Assert(source.readKey(10).getOrThrow(), UiKey.Quit)
        @Assert(source.readKey(10).getOrThrow(), UiKey.NextPage)
        @Assert(source.readKey(10).getOrThrow(), UiKey.Unknown)
        @Assert(source.readKey(10).isNone())
    }
}
