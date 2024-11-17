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

public interface DurationCategory {
    prop nanoseconds: TimeDuration
    prop nanosecond: TimeDuration
    prop microseconds: TimeDuration
    prop microsecond: TimeDuration
    prop milliseconds: TimeDuration
    prop millisecond: TimeDuration
    prop seconds: TimeDuration
    prop second: TimeDuration
    prop minutes: TimeDuration
    prop minute: TimeDuration
    prop hours: TimeDuration
    prop hour: TimeDuration
    prop days: TimeDuration
    prop day: TimeDuration
    prop weeks: TimeDuration
    prop week: TimeDuration
}
extend Int64 <: DurationCategory {
    public prop nanoseconds: TimeDuration {
        get() {
            return TimeDuration(this, NANOSECOND)
        }
    }
    public prop nanosecond: TimeDuration {
        get() {
            return nanoseconds
        }
    }

    public prop microseconds: TimeDuration {
        get() {
            return TimeDuration(this, MICROSECOND)
        }
    }
    public prop microsecond: TimeDuration {
        get() {
            return microseconds
        }
    }

    public prop milliseconds: TimeDuration {
        get() {
            return TimeDuration(this, MILLISECOND)
        }
    }
    public prop millisecond: TimeDuration {
        get() {
            return milliseconds
        }
    }

    public prop seconds: TimeDuration {
        get() {
            return TimeDuration(this, SECOND)
        }
    }
    public prop second: TimeDuration {
        get() {
            return seconds
        }
    }

    public prop minutes: TimeDuration {
        get() {
            return TimeDuration(this, MINUTE)
        }
    }
    public prop minute: TimeDuration {
        get() {
            return minutes
        }
    }

    public prop hours: TimeDuration {
        get() {
            return TimeDuration(this, HOUR)
        }
    }
    public prop hour: TimeDuration {
        get() {
            return hours
        }
    }

    public prop days: TimeDuration {
        get() {
            return TimeDuration(this, DAY)
        }
    }
    public prop day: TimeDuration {
        get() {
            return days
        }
    }
    public prop weeks: TimeDuration {
        get() {
            return TimeDuration(this, WEEK)
        }
    }
    public prop week: TimeDuration {
        get() {
            return weeks
        }
    }
}
