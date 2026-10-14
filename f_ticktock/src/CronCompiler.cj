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

import std.collection.ArrayList
import std.collection.concurrent.ConcurrentHashMap
import std.convert.Parsable
import std.regex.Regex

public class CronCompiler {
    /**
     * 四个字段语法正则提升为静态常量，并直接用标准库 Regex 构造：
     * 原实现每解析一个字段子表达式都要走一次 `String.regex(solid: true)`——
     * 它要拼 key 字符串并查一次全局 ConcurrentHashMap（SOLID 缓存）。
     * 静态常量只需在类加载时构造一次，运行期零查找。
     */
    private static let DURATION_RANGE = Regex("^(\\d{1,2}|\\*)?/(\\d{1,2}|\\*)?-(\\d{1,2}|\\*)?$")
    private static let DURATION = Regex("^(\\d{1,2}|\\*)?/(\\d{1,2}|\\*)?$")
    private static let RANGE = Regex("^(\\d{1,2}|\\*)?-(\\d{1,2}|\\*)?$")
    private static let SINGLE = Regex("^\\d{1,2}$")

    /** 表达式文本 -> 编译结果（只读共享），仅由 Ticktock 内部使用。 */
    private static let sharedCache = ConcurrentHashMap<String, Collection<CronDataCollection>>()
    private static let SHARED_CACHE_LIMIT = 4096

    /**
     * 驻留版编译：同一表达式文本在进程内只编译一份，多个任务共享同一份只读规则数据。
     *
     * 只由 Ticktock 内部调用，共享对象不对外暴露（使用处只读）；
     * 公开的 {@code compile} 行为不变，每次仍返回新建的对象。
     */
    @Frozen
    static func compileShared(cronExpr: String): Collection<CronDataCollection> {
        match (sharedCache.get(cronExpr)) {
            case Some(existing) => return existing
            case None => ()
        }
        let compiled = compile(cronExpr)
        if (sharedCache.size >= SHARED_CACHE_LIMIT) {
            return compiled
        }
        match (sharedCache.addIfAbsent(cronExpr, compiled)) {
            case Some(existing) => existing
            case None => compiled
        }
    }

    /**
     * 添加任务
     */
    /**  所有的表达式单元都可以统一成a/b-c这种格式，
       但是每种表达式都单独处理是为了给这些表达式单独的异常信息，
       为了方便编写表达式的人
     */
    @Frozen
    public static func compile(cronExpr: String): Collection<CronDataCollection> {
        if (cronExpr.isEmpty()) {
            throw IllegalArgumentException("arg cronExpr must not be null or empty string!!!")
        }
        let exprs = cronExpr.split("|")
        var datas = ArrayList<CronDataCollection>()
        for (expr in exprs) {
            let units = ArrayList<String>(expr.trimAscii().split(" "))//如果units不足覆盖全部时间单位，说明更大的时间单位都是*
            var cronc = CronDataCollection(expr)
            datas.add(cronc)
            for (i in 0..units.size) {
                var unit = units[i]
                let ticktockUnit = TicktockUnit.valueOf(i)
                unit = unit.replace("*/", "${ticktockUnit.min}/")
                if (unit == "*" || unit == '*/*' || unit == '*-*' || unit == '*/*-*' || unit == '*/1-*' || unit == '*/1' ||
                    unit == '${ticktockUnit.min}/*' || unit == '${ticktockUnit.min}/*-*' || unit == '${ticktockUnit.min}-*' || 
                    unit == '${ticktockUnit.min}/1' || unit == '${ticktockUnit.min}/1-*' || 
                    unit == '*/*-${ticktockUnit.max}' || unit == '*/1-${ticktockUnit.max}' || unit == '*-${ticktockUnit.max}' ||
                    unit == '${ticktockUnit.min}/*-${ticktockUnit.max}' || unit == '${ticktockUnit.min}/1-${ticktockUnit.max}' || 
                    unit == '${ticktockUnit.min}-${ticktockUnit.max}') {
                    //对于这些情况说明当前单位每个值都任意时间都匹配，为了减少运算量就忽略它们
                    continue
                }
                for (value in unit.split(",")) {
                    if (DURATION_RANGE.matches(value)) {
                        //value.contains("/") && value.contains("-")
                        var first = 0
                        var last = value.indexOf("/", first) ?? -1
                        var start = parsePart(value, first, last, ticktockUnit.min)
                        if (start == 0 && start < ticktockUnit.min) {
                            start = ticktockUnit.min
                        }
                        first = last + 1
                        last = value.indexOf("-", first) ?? -1
                        var duration = parsePart(value, first, last, 1)
                        first = last + 1
                        last = value.size
                        var end = parsePart(value, first, last, ticktockUnit.max)
                        putCronc(cronc, ticktockUnit, start, end, duration)
                    } else if (DURATION.matches(value)) {
                        var first = 0
                        var last = value.indexOf("/", first) ?? -1
                        var start = parsePart(value, first, last, ticktockUnit.min)
                        if (start == 0 && start < ticktockUnit.min) {
                            start = ticktockUnit.min
                        }
                        first = last + 1
                        last = value.size
                        var duration = parsePart(value, first, last, 1)
                        var end = ticktockUnit.max
                        putCronc(cronc, ticktockUnit, start, end, duration)
                    } else if (RANGE.matches(value)) {
                        var first = 0
                        var last = value.indexOf("-", first) ?? -1
                        var start = parsePart(value, first, last, ticktockUnit.min)
                        if (start == 0 && start < ticktockUnit.min) {
                            start = ticktockUnit.min
                        }
                        first = last + 1
                        last = value.size
                        var end = parsePart(value, first, last, ticktockUnit.max)
                        var range = ticktockUnit.convertRange(start, end)
                        cronc.put(ticktockUnit, range[0])
                        if (range.size == 3) {
                            cronc.put(ticktockUnit, range[1])
                        }
                    } else if (value == "L") {
                        cronc.putLast(ticktockUnit)
                    } else if (SINGLE.matches(value)) {
                        var single = Int64.parse(value)
                        cronc.put(ticktockUnit, ticktockUnit.convertSingle(single))
                    } else {
                        throw IllegalArgumentException("illegal cron expression part '${value}' for ${ticktockUnit}")
                    }
                }
            }
        }
        return datas
    }
    @Frozen
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
    @Frozen
    private static func putCronc(
        cronc: CronDataCollection,
        ticktockUnit: TicktockUnit,
        start: Int64,
        end: Int64,
        duration: Int64
    ): Unit {
        var converted = ticktockUnit.convertDuration(start, end, duration)
        cronc.put(ticktockUnit, converted[0])
        if (converted.size > 1) {
            cronc.put(ticktockUnit, converted[1])
        }
    }
}
