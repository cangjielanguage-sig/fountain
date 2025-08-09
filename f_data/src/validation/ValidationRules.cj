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
