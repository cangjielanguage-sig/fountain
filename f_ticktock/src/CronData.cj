/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_ticktock

import f_base.HashBuilder

public class CronData <: ToString & Hashable & Equatable<CronData> {
    private let unit_: TicktockUnit
    private let range_: Range<Int64>
    private let last_: Bool
    private let hash: Int64

    public init(unit: TicktockUnit, value: Int64) {
        this(unit, value ..= value)
    }
    public init(unit: TicktockUnit, range: Range<Int64>) {
        this(unit, range, false)
    }

    private init(unit: TicktockUnit, range: Range<Int64>, last: Bool) {
        this.unit_ = unit
        this.range_ = range
        this.last_ = last
        hash = HashBuilder().append(unit_).append(range_).append(last_).build()
    }
    public static func createLast(unit: TicktockUnit){
        if(unit == TicktockUnit.YEARLY) {
            throw IllegalArgumentException("L tag for YEARLY unit in cron expression is forbidden.")
        }
        CronData(unit, unit.lastRange, true)
    }
    public func hashCode(){
        hash
    }
    public operator func ==(other: CronData){
        hash == other.hash &&
        unit_ == other.unit_ &&
        range_ == other.range_ &&
        last_ == other.last_
    }
    public func toString(): String {
        "unit: ${unit}, start: ${start}, end: ${end}, duration: ${duration}, last: ${last}"
    }
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
    public prop range: Range<Int64>{
        get(){
            range_
        }
    }

    public prop last: Bool {
        get() {
            return last_
        }
    }
    public func matches(date: DateTime){
        if(last && unit.last(date)){//这一部分不能省，因为不同月份的最后一天不一样
            return true;
        }
        let current = unit.current(date)
        current >= start && current <= end && 
        (duration == 1 || ((current - start) % duration == 0))
    }
}
