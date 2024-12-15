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
import std.convert.Parsable
import std.regex.Regex
import f_regex.RegexFromString

public class CronCompiler {
    /**
     * 添加任务
     */
    /**  所有的表达式单元都可以统一成a/b-c这种格式，
       但是每种表达式都单独处理是为了给这些表达式单独的异常信息，
       为了方便编写表达式的人
     */
    public static func compile(cronExpr: String): Collection<CronDataCollection> {
        if (cronExpr.isEmpty()) {
            throw IllegalArgumentException("arg cronExpr must not be null or empty string!!!")
        }
        let exprs = cronExpr.split("|")
        var datas = ArrayList<CronDataCollection>()
        for (expr in exprs) {
            let units = ArrayList<String>(expr.trimAscii().split(" "))
            var i = TicktockUnit.values.size - units.size
            while (i > 0) {
                units.append("*")
                i--
            }
            var cronc = CronDataCollection(expr)
            datas.append(cronc)
            i = 0
            let l = units.size
            while (i < l) {
                var unit = units[i]
                let wheelUnit = TicktockUnit.valueOf(i)
                unit = unit.replace("*/", "${wheelUnit.min}/")
                if (unit == "*") {
                    let range = wheelUnit.range
                    cronc.put(wheelUnit, range)
                } else {
                    for (value in unit.split(",")) {
                        if (let Some(_) <- "^(\\d{1,2}|\\*)?/(\\d{1,2}|\\*)?-(\\d{1,2}|\\*)?$".regex(solid: true).
                            matches(value)) { //value.contains("/") && value.contains("-")
                            var first = 0
                            var last = value.indexOf("/", first) ?? -1
                            var start = parsePart(value, first, last, wheelUnit.min)
                            if (start == 0 && start < wheelUnit.min) {
                                start = wheelUnit.min
                            }
                            first = last + 1
                            last = value.indexOf("-", first) ?? -1
                            var duration = parsePart(value, first, last, 1)
                            first = last + 1
                            last = value.size
                            var end = parsePart(value, first, last, wheelUnit.max)
                            putCronc(cronc, wheelUnit, start, end, duration)
                        } else if (let Some(_) <- "^(\\d{1,2}|\\*)?/(\\d{1,2}|\\*)?$".regex(solid: true).matches(value)) {
                            var first = 0
                            var last = value.indexOf("/", first) ?? -1
                            var start = parsePart(value, first, last, wheelUnit.min)
                            if (start == 0 && start < wheelUnit.min) {
                                start = wheelUnit.min
                            }
                            first = last + 1
                            last = value.size
                            var duration = parsePart(value, first, last, 1)
                            var end = wheelUnit.max
                            putCronc(cronc, wheelUnit, start, end, duration)
                        } else if (let Some(_) <- "^(\\d{1,2}|\\*)?-(\\d{1,2}|\\*)?$".regex(solid: true).matches(value)) {
                            var first = 0
                            var last = value.indexOf("-", first) ?? -1
                            var start = parsePart(value, first, last, wheelUnit.min)
                            if (start == 0 && start < wheelUnit.min) {
                                start = wheelUnit.min
                            }
                            first = last + 1
                            last = value.size
                            var end = parsePart(value, first, last, wheelUnit.max)
                            var range = wheelUnit.convertRange(start, end)
                            cronc.put(wheelUnit, range[0])
                            if (range.size == 3) {
                                cronc.put(wheelUnit, range[1])
                            }
                        } else if (value == "L") {
                            cronc.putLast(wheelUnit)
                        } else if (let Some(_) <- "^\\d{1,2}$".regex(solid: true).matches(value)) {
                            var single = Int64.parse(value)
                            cronc.put(wheelUnit, wheelUnit.convertSingle(single))
                        } else {
                            throw IllegalArgumentException("illegal cron expression part '${value}' for ${wheelUnit}")
                        }
                    }
                }
                i++
            }
        }
        return datas
    }

    private static func parsePart(value: String, first: Int64, last: Int64, defaultValue: Int64): Int64 {
        if (last == first) {
            return defaultValue
        } else {
            let part = value[first..last]
            if (part == "*") {
                return defaultValue
            } else {
                return Int64.parse(part)
            }
        }
    }

    private static func putCronc(
        cronc: CronDataCollection,
        wheelUnit: TicktockUnit,
        start: Int64,
        end: Int64,
        duration: Int64
    ): Unit {
        var converted = wheelUnit.convertDuration(start, end, duration)
        cronc.put(wheelUnit, converted[0])
        if (converted.size > 1) {
            cronc.put(wheelUnit, converted[1])
        }
    }
}
