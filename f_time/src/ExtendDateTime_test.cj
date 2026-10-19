/*
Copyright (c) 2025 WuJingrun（吴京润）

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
package fountain::f_time

import std.time.Month
import std.unittest.*
import std.unittest.testmacro.*

@Test
public class ExtendDateTime_test {
    private static func time(year: Int64, month: Int64, day: Int64): DateTime {
        DateTime.of(year: year, month: Month.of(month), dayOfMonth: day, hour: 0, minute: 0, second: 0)
    }

    /** 月末判定：大月 31 / 小月 30 / 平年二月 28 / 闰年二月 29，且闰年 2 月 28 日不是最后一天。 */
    @TestCase
    public func testIsLastMonthDay(): Unit {
        // 大月（31 天）
        @Assert(!time(2026, 10, 30).isLastMonthDay)
        @Assert(time(2026, 10, 31).isLastMonthDay)
        // 小月（30 天）
        @Assert(!time(2026, 11, 29).isLastMonthDay)
        @Assert(time(2026, 11, 30).isLastMonthDay)
        // 平年二月
        @Assert(!time(2026, 2, 27).isLastMonthDay)
        @Assert(time(2026, 2, 28).isLastMonthDay)
        // 闰年二月：只有 29 日是最后一天（28 日不是）
        @Assert(!time(2028, 2, 28).isLastMonthDay)
        @Assert(time(2028, 2, 29).isLastMonthDay)
        // 世纪闰年规则：2000 闰年（29 日为最后一天）、1900 平年（28 日为最后一天）
        @Assert(!time(2000, 2, 28).isLastMonthDay)
        @Assert(time(2000, 2, 29).isLastMonthDay)
        @Assert(!time(1900, 2, 27).isLastMonthDay)
        @Assert(time(1900, 2, 28).isLastMonthDay)
    }
}
