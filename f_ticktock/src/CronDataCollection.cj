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

import std.collection.ArrayList
import std.collection.HashMap
import f_base.*

public class CronDataCollection <: Hashable & Equatable<CronDataCollection> {
    public CronDataCollection(private let cron: String) {}
    private var datas = HashMap<TicktockUnit, ArrayList<CronData>>()

    public func hashCode() {
        cron.hashCode()
    }
    public operator func ==(other: CronDataCollection) {
        this.cron == other.cron
    }

    public func put(unit: TicktockUnit, data: CronData): Unit {
        if (let Some(l) <- datas.get(unit)) {
            l
        } else {
            let list = ArrayList<CronData>()
            datas[unit] = list
            list
        }.add(data)
    }
    public func put(unit: TicktockUnit, range: Range<Int64>): Unit {
        put(unit, CronData(unit, range))
    }
    public func put(unit: TicktockUnit, value: Int64) {
        put(unit, CronData(unit, value))
    }
    public func putLast(unit: TicktockUnit) {
        var value = unit.lastRange
        put(unit, CronData.createLast(unit))
    }
    public func get(unit: TicktockUnit): Option<Collection<CronData>> {
        if (let Some(list) <- datas.get(unit)) {
            list as Collection<CronData>
        } else {
            None<Collection<CronData>>
        }
    }
    public func matches(date: DateTime) {
        for (crons in datas.values()) {
            var result = false
            for (cron in crons where cron.matches(date)) {
                result = true
                break
            }
            if (!result) {
                return false
            }
            result = false
        }
        true
    }
}
