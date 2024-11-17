/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_time

public import std.time.*

public interface ExtendDateTime {
    static prop currentDuration: Duration
    static prop yesterday: DateTime
    static prop today: DateTime
    static prop tomorrow: DateTime
    func addMilliseconds(millis: Int64): DateTime
    func addMicroseconds(micros: Int64): DateTime

    func setYear(year: Int64): DateTime
    func setMonth(month: Int64): DateTime
    func setMonth(month: Month): DateTime
    func setDay(day: Int64): DateTime
    func setHour(hour: Int64): DateTime
    func setMinute(minute: Int64): DateTime
    func setSecond(second: Int64): DateTime
    func setMillisecond(millis: Int64): DateTime
    func setMicrosecond(micros: Int64): DateTime
    func setNanosecond(nanos: Int64): DateTime
    prop isLeapYear: Bool
    prop isLastMonthDay: Bool
}
extend DateTime <: ExtendDateTime {
    public static prop currentDuration: Duration {
        get() {
            now().toUnixTimeStamp()
        }
    }
    public static prop today: DateTime {
        get() {
            let now = DateTime.now()
            DateTime.of(year: now.year, month: now.month, dayOfMonth: now.dayOfMonth)
        }
    }
    public static prop yesterday: DateTime {
        get() {
            today - Duration.day
        }
    }
    public static prop tomorrow: DateTime {
        get() {
            today + Duration.day
        }
    }
    public static func current(timeunit: TimeUnit): DateTime {
        timeunit.current
    }
    public func addMilliseconds(millis: Int64): DateTime {
        this + millis * Duration.millisecond
    }
    public func addMicroseconds(micros: Int64): DateTime {
        this + micros * Duration.microsecond
    }
    public func setYear(year: Int64): DateTime {
        DateTime.of(
            year: year,
            month: this.month,
            dayOfMonth: this.dayOfMonth,
            hour: this.hour,
            minute: this.minute,
            second: this.second,
            nanosecond: this.nanosecond
        )
    }
    public func setMonth(month: Int64): DateTime {
        setMonth(Month.of(month))
    }
    public func setMonth(month: Month): DateTime {
        DateTime.of(
            year: this.year,
            month: month,
            dayOfMonth: this.dayOfMonth,
            hour: this.hour,
            minute: this.minute,
            second: this.second,
            nanosecond: this.nanosecond
        )
    }
    public func setDay(day: Int64): DateTime {
        DateTime.of(
            year: this.year,
            month: this.month,
            dayOfMonth: day,
            hour: this.hour,
            minute: this.minute,
            second: this.second,
            nanosecond: this.nanosecond
        )
    }
    public func setHour(hour: Int64): DateTime {
        DateTime.of(
            year: this.year,
            month: this.month,
            dayOfMonth: this.dayOfMonth,
            hour: hour,
            minute: this.minute,
            second: this.second,
            nanosecond: this.nanosecond
        )
    }
    public func setMinute(minute: Int64): DateTime {
        DateTime.of(
            year: this.year,
            month: this.month,
            dayOfMonth: this.dayOfMonth,
            hour: this.hour,
            minute: minute,
            second: this.second,
            nanosecond: this.nanosecond
        )
    }
    public func setSecond(second: Int64): DateTime {
        DateTime.of(
            year: this.year,
            month: this.month,
            dayOfMonth: this.dayOfMonth,
            hour: this.hour,
            minute: this.minute,
            second: second,
            nanosecond: this.nanosecond
        )
    }
    public func setMillisecond(millis: Int64): DateTime {
        DateTime.of(
            year: this.year,
            month: this.month,
            dayOfMonth: this.dayOfMonth,
            hour: this.hour,
            minute: this.minute,
            second: this.second,
            nanosecond: millis * 1000_000
        )
    }
    public func setMicrosecond(micros: Int64): DateTime {
        DateTime.of(
            year: this.year,
            month: this.month,
            dayOfMonth: this.dayOfMonth,
            hour: this.hour,
            minute: this.minute,
            second: this.second,
            nanosecond: micros * 1000
        )
    }
    public func setNanosecond(nanos: Int64): DateTime {
        DateTime.of(
            year: this.year,
            month: this.month,
            dayOfMonth: this.dayOfMonth,
            hour: this.hour,
            minute: this.minute,
            second: this.second,
            nanosecond: nanos
        )
    }
    public prop isLeapYear: Bool {
        get() {
            let y = this.year
            (y & 3) == 0 && ((y % 100) != 0 || (y % 400) == 0)
        }
    }
    public prop isLastMonthDay: Bool {
        get() {
            match ((this.month, this.dayOfMonth)) {
                case (January, 31) | (February, 29) | (March, 31) | (April, 30) | (May, 31) | (June, 30) | (July, 31) | (August, 31) | (September, 30) | (October, 31) | (November, 30) | (December, 31) => true
                case (February, 28) => !isLeapYear
                case _ => false
            }
        }
    }
}
