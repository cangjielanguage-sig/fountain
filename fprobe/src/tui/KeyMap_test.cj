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

import std.unittest.*
import std.unittest.testmacro.*

/** 12.5：按键到动作的映射用表驱动断言，不依赖终端。 */
@Test
public class KeyMap_test {
    @TestCase
    public func mapsEveryDocumentedKey(): Unit {
        let cases = [
            (UiKey.Quit, UiAction.Quit),
            (UiKey.Refresh, UiAction.Refresh),
            (UiKey.NextPage, UiAction.NextPage),
            (UiKey.PreviousPage, UiAction.PreviousPage),
            (UiKey.Up, UiAction.SelectPrevious),
            (UiKey.Down, UiAction.SelectNext),
            (UiKey.AlarmPage, UiAction.ShowAlarms),
            (UiKey.Unknown, UiAction.Ignore)
        ]
        for ((key, expected) in cases) {
            @Assert(KeyMap.action(key), expected)
        }
    }
}
