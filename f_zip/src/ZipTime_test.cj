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
package fountain::f_zip

import std.time.{DateTime, TimeZone}
import std.unittest.*
import std.unittest.testmacro.*

@Test
public class ZipTime_test {
    /** 场景「往返精度」。 */
    @TestCase
    public func roundTripEvenSecond(): Unit {
        let dt = DateTime.of(
            year: 2026,
            month: 10,
            dayOfMonth: 24,
            hour: 13,
            minute: 45,
            second: 30,
            timeZone: TimeZone.Local
        )
        let time = encodeDosTime(dt)
        let date = encodeDosDate(dt)
        let back = decodeDosDateTime(time, date).getOrThrow()
        @Assert(back.year, 2026)
        @Assert(back.month.toInteger(), 10)
        @Assert(back.dayOfMonth, 24)
        @Assert(back.hour, 13)
        @Assert(back.minute, 45)
        @Assert(back.second, 30)
    }

    /** 场景「奇数秒被截断」：向偶数秒截断，属格式限制。 */
    @TestCase
    public func oddSecondTruncated(): Unit {
        let dt = DateTime.of(
            year: 2026,
            month: 10,
            dayOfMonth: 24,
            hour: 13,
            minute: 45,
            second: 31,
            timeZone: TimeZone.Local
        )
        let back = decodeDosDateTime(encodeDosTime(dt), encodeDosDate(dt)).getOrThrow()
        @Assert(back.second, 30)
    }

    /** DOS 时间全 0 → 没有时间信息，返回 None 而不是伪造 1980-01-01。 */
    @TestCase
    public func zeroDateMeansNoTime(): Unit {
        @Assert(decodeDosDateTime(0, 0).isNone(), true)
    }

    @TestCase
    public func yearIsRelativeTo1980(): Unit {
        let dt = DateTime.of(year: 1980, month: 1, dayOfMonth: 1, timeZone: TimeZone.Local)
        @Assert(encodeDosDate(dt), 0x0021u16)
    }
}
