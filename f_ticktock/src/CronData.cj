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
package fountain::f_ticktock

import fountain::f_base.HashBuilder
import fountain::f_ticktock.exception.*

public class CronData <: ToString & Hashable & Equatable<CronData> {
    private let unit_: TicktockUnit
    private let range_: Range<Int64>
    private let last_: Bool
    private let hash: Int64

    @Frozen
    public init(unit: TicktockUnit, value: Int64) {
        this(unit, value..=value)
    }
    @Frozen
    public init(unit: TicktockUnit, range: Range<Int64>) {
        this(unit, range, false)
    }
    @Frozen
    private init(unit: TicktockUnit, range: Range<Int64>, last: Bool) {
        if(unit == TicktockUnit.YEARLY && last){
            throw TicktockException('time unit of year must not be specified as last')
        }
        this.unit_ = unit
        this.range_ = range
        this.last_ = last
        hash = HashBuilder().append(unit_).append(range_).append(last_).build()
    }
    @Frozen
    public static func createLast(unit: TicktockUnit) {
        if (unit == TicktockUnit.YEARLY) {
            throw IllegalArgumentException("L tag for YEARLY unit in cron expression is forbidden.")
        }
        CronData(unit, unit.lastRange, true)
    }
    public func hashCode() {
        hash
    }
    @Frozen
    public operator func ==(other: CronData) {
        refEq(this, other) || (hash == other.hash && unit_ == other.unit_ && range_ == other.range_ && last_ == other.last_)
    }
    @Frozen
    public func toString(): String {
        "unit: ${unit}, start: ${start}, end: ${end}, duration: ${duration}, last: ${last}"
    }
    @Frozen
    public func convert(task: TicktockTask): TicktockTask {
        return unit.convert(task, last)
    }
    public prop unit: TicktockUnit {
        get() {
            unit_
        }
    }
    public prop start: Int64 {
        get() {
            return range.start
        }
    }

    public prop end: Int64 {
        get() {
            return range.end
        }
    }

    public prop duration: Int64 {
        get() {
            return range.step
        }
    }
    public prop range: Range<Int64> {
        get() {
            range_
        }
    }

    public prop last: Bool {
        get() {
            return last_
        }
    }
    public func matches(date: DateTime) {
        if (last) {
            // `L` 只匹配"该单位的最后一天"：日字段是当月最后一天（28/29/30/31 随月份变化，
            // 见 MonthDailyTicktockUnit.last），其余单位的 lastRange 是单值（59/23/12/7）。
            // 不能退化为对 [start, end] 区间的逐日判断——那会命中 28..=31 里每个存在的
            // 日子（"每月 28 号起每天都触发"），不等于"最后一天"。
            return unit.last(date)
        }
        let current = unit.current(date)
        (current > start && current <= end && (duration == 1 || ((current - start) % duration == 0))) || current == start
    }
}
