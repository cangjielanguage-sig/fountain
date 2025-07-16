/*
    Copyright (c) 2022 WuJingrun（吴京润）
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_time

import std.unittest.*
import std.unittest.testmacro.*

@Test
public class TimeUnitTest {
    @TestCase
    public func test(): Unit {
        let fmt = 'yyyy-MM-dd HH:mm:ss.SSS'
        let date = DateTime.parse('2024-11-24 14:34:55.123456789', fmt)
        @Assert('2024-11-24 14:34:55.000000000', TU.SECOND.trim(date).toString(fmt))
        @Assert('2024-11-24 14:34:00.000000000', TU.MINUTE.trim(date).toString(fmt))
        @Assert('2024-11-24 14:00:00.000000000', TU.HOUR.trim(date).toString(fmt))
        @Assert('2024-11-24 00:00:00.000000000', TU.DAY.trim(date).toString(fmt))
        @Assert('2024-11-01 00:00:00.000000000', TU.MONTH.trim(date).toString(fmt))
        @Assert('2024-11-24 00:00:00.000000000', TU.WEEK.trim(date).toString(fmt))
        @Assert('2024-01-01 00:00:00.000000000', TU.YEAR.trim(date).toString(fmt))
    }
}
