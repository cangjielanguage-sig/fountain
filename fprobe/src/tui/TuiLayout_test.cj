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

/** 右侧图表预算：高度按固定 chrome 与指标行数扣减。 */
@Test
public class TuiLayout_test {
    @TestCase
    public func innerHeightSubtractsChromeAndRows(): Unit {
        @Assert(TuiLayout.innerHeight(24, 6), 13)
        @Assert(TuiLayout.innerHeight(12, 6), 1)
        @Assert(TuiLayout.innerHeight(0, 6), 0)
        @Assert(TuiLayout.innerHeight(4, 10), 0)
    }

    @TestCase
    public func chartHeightOnlyWhenMinimumMet(): Unit {
        @Assert(TuiLayout.chartHeight(24, 6), 13)
        @Assert(TuiLayout.chartHeight(20, 6), 9)
        @Assert(TuiLayout.chartHeight(19, 6), 8)
        @Assert(TuiLayout.chartHeight(18, 6), 0)
        @Assert(TuiLayout.chartHeight(12, 6), 0)
        @Assert(TuiLayout.chartHeight(0, 0), 0)
    }
}
