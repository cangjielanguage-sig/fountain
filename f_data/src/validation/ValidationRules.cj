/*
    Copyright (c) 2022 WuJingrun（吴京润）
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_data.validation

import std.collection.concurrent.ConcurrentHashMap
import std.regex.*
import f_regex.*

//属性验证 整数 小数 电邮 手机号 整数值范围 正则 日期格式
let rules = {
    =>
    let map = ConcurrentHashMap<String, (String) -> Bool>()
    let integer = Regex.INTEGER
    let decimal = Regex.DECIMAL
    let email = Regex.EMAIL
    let chineseCellPhone = Regex(#"^1\d{10}$"#)
    let ints = Regex(#"^\d+(,\d+)*$"#)
    let pascals = Regex(#"[A-Z]+\w*(,[A-Z]+\w*)*"#)
    let camels = Regex(#"[a-z]+\w*(,[a-z]+\w*)*"#)
    let lowerUnderScores = Regex(#"[a-z]+[a-z_]*(,[a-z]+[a-z_]*)*"#)
    let upperUnderScores = Regex(#"[A-Z]+[A-Z_]*(,[A-Z]+[A-Z_]*)*"#)
    let lowerHyphens = Regex(#"[a-z]+[a-z-]*(,[a-z]+[a-z-]*)*"#)
    let upperHyphens = Regex(#"[A-Z]+[A-Z-]*(,[A-Z]+[A-Z-]*)*"#)

    map["Integer"] = {val => integer.matches(val)}
    map["Decimal"] = {val => decimal.matches(val)}
    map["Email"] = {val => email.matches(val)}
    map["ChineseCellPhone"] = {val => chineseCellPhone.matches(val)}
    map["Integers"] = {val => ints.matches(val)}
    map["Pascals"] = {val => pascals.matches(val)}
    map["Camels"] = {val => camels.matches(val)}
    map["LowerUnderScores"] = {val => lowerUnderScores.matches(val)}
    map["UpperUnderScores"] = {val => upperUnderScores.matches(val)}
    map["LowerHyphens"] = {val => lowerHyphens.matches(val)}
    map["UpperHyphens"] = {val => upperHyphens.matches(val)}

    map
}()

public func registgerRule(name: String, rule: (String) -> Bool): Unit {
    rules[name] = rule
}

public func validate(name: String, value: String): Bool {
    rules[name](value)
}
